//! Soniox RT WebSocket 客户端
//! 设计引用：D1 §1

use futures::{SinkExt, StreamExt};
use serde::{Deserialize, Serialize};
use std::future::Future;
use std::time::Duration;
use tokio::sync::{broadcast, mpsc, watch};
use tokio_tungstenite::{connect_async, tungstenite::Message};
use tokio_util::sync::CancellationToken;
use vt_model::{AudioChunk, Token, TranslationStatus};

use crate::{
    ConnectionStatus, ContextConfig, SonioxQuotaKind, SttConfig, SttError, TranslationConfig,
    CURRENT_NOTEBOOK_CAPTURE_ENGINE,
};

const SONIOX_CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
const SONIOX_WRITE_TIMEOUT: Duration = Duration::from_secs(10);
const SONIOX_RECEIVE_IDLE_TIMEOUT: Duration = Duration::from_secs(5 * 60);
const SONIOX_DRAIN_TIMEOUT: Duration = Duration::from_secs(20);
const SONIOX_SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(2);

#[derive(Clone, Copy)]
struct SonioxRtTimeouts {
    connect: Duration,
    write: Duration,
    receive_idle: Duration,
    drain: Duration,
    shutdown: Duration,
}

impl Default for SonioxRtTimeouts {
    fn default() -> Self {
        Self {
            connect: SONIOX_CONNECT_TIMEOUT,
            write: SONIOX_WRITE_TIMEOUT,
            receive_idle: SONIOX_RECEIVE_IDLE_TIMEOUT,
            drain: SONIOX_DRAIN_TIMEOUT,
            shutdown: SONIOX_SHUTDOWN_TIMEOUT,
        }
    }
}

async fn timed_operation<F, T>(
    operation: &'static str,
    elapsed: Duration,
    future: F,
) -> Result<T, SttError>
where
    F: Future<Output = T>,
{
    tokio::time::timeout(elapsed, future)
        .await
        .map_err(|_| SttError::Timeout {
            operation: operation.to_string(),
            elapsed,
        })
}

fn join_result(
    operation: &'static str,
    result: Result<Result<(), SttError>, tokio::task::JoinError>,
) -> Result<(), SttError> {
    result.map_err(|error| {
        SttError::ConnectionFailed(format!("{operation} task join failed: {error}"))
    })?
}

const MAX_SAFE_PROVIDER_REQUEST_ID_BYTES: usize = 64;

/// Provider metadata is untrusted input. Only retain conventional request IDs
/// that are useful for support and cannot be mistaken for a copied credential.
/// Everything else is dropped instead of being reflected into logs or durable
/// task errors.
pub(crate) fn safe_soniox_request_id(value: Option<&str>) -> Option<String> {
    let value = value?.trim();
    if !(4..=MAX_SAFE_PROVIDER_REQUEST_ID_BYTES).contains(&value.len())
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.'))
    {
        return None;
    }

    let lower = value.to_ascii_lowercase();
    if [
        "api_key",
        "apikey",
        "credential",
        "secret",
        "bearer",
        "token",
    ]
    .iter()
    .any(|marker| lower.contains(marker))
    {
        return None;
    }

    // Long uninterrupted hexadecimal strings are credential-shaped. UUIDs
    // remain accepted because their longest hex component is only 12 bytes.
    let mut consecutive_hex = 0_usize;
    for byte in value.bytes() {
        if byte.is_ascii_hexdigit() {
            consecutive_hex += 1;
            if consecutive_hex >= 24 {
                return None;
            }
        } else {
            consecutive_hex = 0;
        }
    }

    let conventional_prefix = lower.starts_with("req-")
        || lower.starts_with("req_")
        || lower.starts_with("request-")
        || lower.starts_with("request_");
    let uuid_shape = value.len() == 36
        && value.bytes().enumerate().all(|(index, byte)| match index {
            8 | 13 | 18 | 23 => byte == b'-',
            _ => byte.is_ascii_hexdigit(),
        });
    (conventional_prefix || uuid_shape).then(|| value.to_string())
}

/// Reduce arbitrary provider error types to a small stable vocabulary. Raw
/// provider strings are used only for classification and are never returned.
pub(crate) fn canonical_soniox_error_type(status: u16, raw: Option<&str>) -> &'static str {
    let normalized = raw.unwrap_or_default().to_ascii_lowercase();
    if matches!(status, 401 | 403)
        || normalized.contains("auth")
        || normalized.contains("api_key")
        || normalized.contains("unauthor")
        || normalized.contains("credential")
    {
        "authentication_error"
    } else if status == 402
        || normalized.contains("quota")
        || normalized.contains("balance_exhausted")
        || normalized.contains("budget_exhausted")
    {
        "quota_exhausted"
    } else if status == 429 || normalized.contains("rate") || normalized.contains("limit_exceeded")
    {
        "rate_limited"
    } else if status == 400 || normalized.contains("invalid_request") {
        "invalid_request"
    } else if status >= 500 || normalized.contains("service_unavailable") {
        "service_unavailable"
    } else {
        "provider_error"
    }
}

pub(crate) fn safe_soniox_provider_detail(
    status: u16,
    error_type: &str,
    request_id: Option<&str>,
) -> String {
    let status_label = if status == 0 {
        "unknown".to_string()
    } else {
        status.to_string()
    };
    let request_suffix = safe_soniox_request_id(request_id)
        .map(|value| format!(" request_id={value}"))
        .unwrap_or_default();
    format!("{error_type} (status={status_label}){request_suffix}")
}

fn provider_error(
    code: &SonioxErrorCode,
    error_type: Option<&str>,
    request_id: Option<&str>,
) -> SttError {
    let status = code.status();
    let code_label = code.label();
    let quota_kind = SonioxQuotaKind::from_error_type(error_type);
    let classification_input = match error_type {
        Some(error_type) => format!("{code_label} {error_type}"),
        None => code_label,
    };
    let error_type = canonical_soniox_error_type(status, Some(&classification_input));
    let detail = safe_soniox_provider_detail(status, error_type, request_id);
    let normalized = classification_input.to_ascii_lowercase();
    if normalized.contains("auth")
        || normalized.contains("api_key")
        || normalized.contains("unauthor")
        || matches!(status, 401 | 403)
    {
        SttError::AuthFailed { message: detail }
    } else if status == 402
        || normalized.contains("quota")
        || normalized.contains("balance_exhausted")
        || normalized.contains("budget_exhausted")
    {
        SttError::QuotaExhausted {
            kind: quota_kind,
            message: detail,
        }
    } else if status == 429 || normalized.contains("rate") || normalized.contains("limit_exceeded")
    {
        SttError::RateLimited
    } else {
        SttError::ApiError {
            status,
            error_type: error_type.to_string(),
            message: detail,
        }
    }
}

fn close_frame_error(
    frame: Option<tokio_tungstenite::tungstenite::protocol::CloseFrame>,
) -> SttError {
    match frame {
        Some(frame) => {
            let code: u16 = frame.code.into();
            let reason = frame.reason.to_string();
            let normalized = reason.to_ascii_lowercase();
            if code == 1008
                || code == 4001
                || code == 4003
                || normalized.contains("auth")
                || normalized.contains("api_key")
            {
                SttError::AuthFailed {
                    message: format!("authentication_error (close_status={code})"),
                }
            } else {
                SttError::ServerClosed {
                    code,
                    reason: "provider closed the connection".to_string(),
                }
            }
        }
        None => SttError::ConnectionFailed(
            "Soniox WebSocket closed before finished without a close frame".to_string(),
        ),
    }
}

/// Soniox RT WebSocket 配置消息
///
/// 权威字段：D1-soniox-protocol.md §1
#[derive(Debug, Serialize)]
struct SonioxRtConfig {
    api_key: String,
    model: String,
    audio_format: String,
    sample_rate: u32,
    num_channels: u8,
    /// 预期语言 ISO 639-1 codes (e.g. ["en", "zh"]).
    /// 空数组 = 自动检测.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    language_hints: Vec<String>,
    /// 严格模式 — true 时只识别 hints 列表中的语言.
    #[serde(skip_serializing_if = "Option::is_none")]
    language_hints_strict: Option<bool>,
    /// 启用逐 token 语言识别.
    /// 不设 language_hints 时必须开启，否则服务可能回退到英文模型。
    #[serde(skip_serializing_if = "Option::is_none")]
    enable_language_identification: Option<bool>,
    /// 启用匿名说话人分离。标签仅在当前 Soniox session 内有意义。
    #[serde(skip_serializing_if = "Option::is_none")]
    enable_speaker_diarization: Option<bool>,
    /// 启用端点检测 — 在语音停顿时自动 finalize token.
    #[serde(skip_serializing_if = "Option::is_none")]
    enable_endpoint_detection: Option<bool>,
    /// 端点检测延迟/质量调整级别 (0..=3). 0 为平衡默认值。
    #[serde(skip_serializing_if = "Option::is_none")]
    endpoint_latency_adjustment_level: Option<u8>,
    /// 端点检测敏感度 (-1.0..=1.0). 0.0 为平衡默认值。
    #[serde(skip_serializing_if = "Option::is_none")]
    endpoint_sensitivity: Option<f32>,
    /// 端点检测最大延迟 (ms).
    #[serde(skip_serializing_if = "Option::is_none")]
    max_endpoint_delay_ms: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    context: Option<SonioxContext>,
    #[serde(skip_serializing_if = "Option::is_none")]
    translation: Option<SonioxTranslation>,
}

#[derive(Debug, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub(crate) enum SonioxTranslation {
    OneWay {
        target_language: String,
    },
    TwoWay {
        language_a: String,
        language_b: String,
    },
}

#[derive(Debug, Serialize)]
struct SonioxContext {
    #[serde(skip_serializing_if = "Vec::is_empty")]
    general: Vec<SonioxContextEntry>,
    #[serde(skip_serializing_if = "Option::is_none")]
    text: Option<String>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    terms: Vec<String>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    translation_terms: Vec<SonioxTranslationTerm>,
}

#[derive(Debug, Serialize)]
struct SonioxContextEntry {
    key: String,
    value: String,
}

#[derive(Debug, Serialize)]
struct SonioxTranslationTerm {
    source: String,
    target: String,
}

/// Soniox RT 响应中的 Token
#[derive(Debug, Deserialize)]
struct SonioxRtToken {
    text: String,
    #[serde(default)]
    start_ms: u64,
    #[serde(default)]
    end_ms: u64,
    #[serde(default)]
    is_final: bool,
    #[serde(default)]
    confidence: f32,
    #[serde(default)]
    translation_status: Option<String>,
    /// Soniox RT 在每个 token 上带语言代码（原文 = 检测到的语言,
    /// 译文 = target_language）。之前 deserialize 直接丢，导致下游
    /// 无法区分原文和译文。
    #[serde(default)]
    language: Option<String>,
    /// 匿名说话人标签，仅在当前 Soniox session 内稳定。
    #[serde(default)]
    speaker: Option<String>,
}

/// Soniox RT 响应消息
///
/// 文档 D1-soniox-protocol §2.3 + Soniox 官方 doc:
/// 正常响应:`{tokens: [...], finished: false}`
/// 错误响应:`{error_code: 400, error_type: "...", error_message: "...", request_id: "..."}`
///
/// 关键: `error_code` / `error_message` 字段**必须存在**,否则 serde 默认忽略未知字段,
/// 会导致错误响应被 parse 成"空 token 列表",服务端挂起时我们完全看不到错。
/// 这是之前 "tokens=0 + 无 error + chunks 一直涨" bug 的根因。
#[derive(Debug, Deserialize)]
struct SonioxRtResponse {
    #[serde(default)]
    tokens: Vec<SonioxRtToken>,
    #[serde(default)]
    finished: bool,
    /// Soniox normally emits a numeric code. String codes are decoded only so
    /// malformed provider responses fail safely without exposing raw text.
    #[serde(default)]
    error_code: Option<SonioxErrorCode>,
    /// 稳定、可编程处理的 provider 错误类型。
    #[serde(default)]
    error_type: Option<String>,
    /// Human-readable provider text is deliberately decoded and discarded. It
    /// is untrusted and must never cross into Display, durable errors, or logs.
    #[serde(default, rename = "error_message", alias = "message")]
    _error_message: Option<String>,
    /// Soniox request ID，用于审计/支持，不包含转录内容。
    #[serde(default)]
    request_id: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(untagged)]
enum SonioxErrorCode {
    Numeric(u16),
    Text(String),
}

impl SonioxErrorCode {
    fn status(&self) -> u16 {
        match self {
            Self::Numeric(value) => *value,
            Self::Text(_) => 0,
        }
    }

    fn label(&self) -> String {
        match self {
            Self::Numeric(value) => value.to_string(),
            Self::Text(value) => value.clone(),
        }
    }
}

impl SonioxRtToken {
    fn into_model_token(self) -> Token {
        let ts = match self.translation_status.as_deref() {
            Some("original") => TranslationStatus::Original,
            Some("translation") => TranslationStatus::Translation,
            _ => TranslationStatus::None,
        };
        Token {
            text: self.text,
            start_ms: self.start_ms,
            end_ms: self.end_ms,
            is_final: self.is_final,
            language: self.language.unwrap_or_default(),
            speaker: self.speaker,
            confidence: self.confidence,
            translation_status: ts,
        }
    }
}

fn build_soniox_context(context: Option<&ContextConfig>) -> Option<SonioxContext> {
    let context = context?;

    let general: Vec<SonioxContextEntry> = context
        .general
        .iter()
        .filter_map(|(key, value)| {
            let key = key.trim();
            let value = value.trim();
            if key.is_empty() || value.is_empty() {
                None
            } else {
                Some(SonioxContextEntry {
                    key: key.to_string(),
                    value: value.to_string(),
                })
            }
        })
        .collect();

    let text = context.text.as_ref().and_then(|t| {
        let trimmed = t.trim();
        if trimmed.is_empty() {
            None
        } else {
            Some(trimmed.to_string())
        }
    });

    let terms: Vec<String> = context
        .terms
        .iter()
        .filter_map(|term| {
            let trimmed = term.trim();
            if trimmed.is_empty() {
                None
            } else {
                Some(trimmed.to_string())
            }
        })
        .collect();

    let translation_terms: Vec<SonioxTranslationTerm> = context
        .translation_terms
        .iter()
        .filter_map(|(source, target)| {
            let source = source.trim();
            let target = target.trim();
            if source.is_empty() || target.is_empty() {
                None
            } else {
                Some(SonioxTranslationTerm {
                    source: source.to_string(),
                    target: target.to_string(),
                })
            }
        })
        .collect();

    if general.is_empty() && text.is_none() && terms.is_empty() && translation_terms.is_empty() {
        None
    } else {
        Some(SonioxContext {
            general,
            text,
            terms,
            translation_terms,
        })
    }
}

/// Soniox RT WebSocket 客户端
pub struct SonioxRtClient;

impl SonioxRtClient {
    /// 测试 API key 的有效性 — 用当前 realtime contract 连接 + 发配置 + 立即关闭
    ///
    /// 流程：
    /// 1. 连接到 wss://stt-rt.soniox.com/transcribe-websocket
    /// 2. 发送最小配置消息（含 api_key）
    /// 3. 等待第一个响应（最多 3 秒）
    ///    - 如果是 close frame with auth error → invalid key
    ///    - 如果是 normal text response → valid key
    ///    - 如果超时 → 视为 valid（连接成功，服务在等音频）
    /// 4. 主动关闭连接
    ///
    /// 总耗时：~200-3000ms
    pub async fn test_key(endpoint: &str, api_key: &str) -> Result<(), SttError> {
        use std::time::Duration;
        if api_key.trim().is_empty() {
            return Err(SttError::AuthFailed {
                message: "API key is empty".to_string(),
            });
        }

        // 连接（最多 5 秒）
        let connect_fut = connect_async(endpoint);
        let (ws_stream, _) = tokio::time::timeout(Duration::from_secs(5), connect_fut)
            .await
            .map_err(|_| SttError::ConnectionFailed("connect timeout".to_string()))?
            .map_err(|e| SttError::ConnectionFailed(e.to_string()))?;

        let (mut write, mut read) = ws_stream.split();

        // 发最小配置（当前 realtime contract）
        let engine = CURRENT_NOTEBOOK_CAPTURE_ENGINE;
        let config = SonioxRtConfig {
            api_key: api_key.to_string(),
            model: engine.realtime_model_id.to_string(),
            audio_format: engine.audio_format.to_string(),
            sample_rate: engine.sample_rate,
            num_channels: engine.channels,
            language_hints: Vec::new(),
            language_hints_strict: None,
            enable_language_identification: None,
            enable_speaker_diarization: None,
            enable_endpoint_detection: None,
            endpoint_latency_adjustment_level: None,
            endpoint_sensitivity: None,
            max_endpoint_delay_ms: None,
            context: None,
            translation: None,
        };
        let config_json =
            serde_json::to_string(&config).map_err(|e| SttError::ParseError(e.to_string()))?;
        write
            .send(Message::Text(config_json.into()))
            .await
            .map_err(|e| SttError::ConnectionFailed(e.to_string()))?;

        // 等第一个响应（3 秒），区分 close-frame / text / 超时
        let recv = tokio::time::timeout(Duration::from_secs(3), read.next()).await;

        // 主动关闭
        let _ = write.send(Message::Close(None)).await;

        match recv {
            Ok(Some(Ok(Message::Text(text)))) => {
                let response: SonioxRtResponse = serde_json::from_str(&text)
                    .map_err(|error| SttError::ParseError(error.to_string()))?;
                if let Some(code) = response.error_code.as_ref() {
                    return Err(provider_error(
                        code,
                        response.error_type.as_deref(),
                        response.request_id.as_deref(),
                    ));
                }
                Ok(())
            }
            Ok(Some(Ok(Message::Close(close_frame)))) => Err(close_frame_error(close_frame)),
            Ok(Some(Ok(_))) => Ok(()),
            Ok(Some(Err(e))) => {
                let msg = e.to_string();
                let lower = msg.to_lowercase();
                if lower.contains("401") || lower.contains("unauthor") {
                    Err(SttError::AuthFailed {
                        message: "authentication_error (transport)".to_string(),
                    })
                } else {
                    Err(SttError::ConnectionFailed(
                        "Soniox WebSocket operation failed".to_string(),
                    ))
                }
            }
            Ok(None) => Err(SttError::ConnectionFailed(
                "stream ended before any response".to_string(),
            )),
            Err(_) => {
                // 3 秒超时但无错误 → 连接成功且服务在等音频，视为 valid
                Ok(())
            }
        }
    }

    /// 连接到 Soniox RT WebSocket 并处理音频/token 流
    pub async fn run(
        endpoint: &str,
        api_key: &str,
        config: &SttConfig,
        audio_rx: mpsc::Receiver<AudioChunk>,
        token_tx: broadcast::Sender<Token>,
        status_tx: watch::Sender<ConnectionStatus>,
        cancel: CancellationToken,
    ) -> Result<(), SttError> {
        Self::run_for_model(
            endpoint,
            api_key,
            CURRENT_NOTEBOOK_CAPTURE_ENGINE.realtime_model_id,
            config,
            audio_rx,
            token_tx,
            status_tx,
            cancel,
            SonioxRtTimeouts::default(),
        )
        .await
    }

    #[allow(clippy::too_many_arguments)]
    #[cfg(test)]
    async fn run_with_timeouts(
        endpoint: &str,
        api_key: &str,
        config: &SttConfig,
        audio_rx: mpsc::Receiver<AudioChunk>,
        token_tx: broadcast::Sender<Token>,
        status_tx: watch::Sender<ConnectionStatus>,
        cancel: CancellationToken,
        timeouts: SonioxRtTimeouts,
    ) -> Result<(), SttError> {
        Self::run_for_model(
            endpoint,
            api_key,
            CURRENT_NOTEBOOK_CAPTURE_ENGINE.realtime_model_id,
            config,
            audio_rx,
            token_tx,
            status_tx,
            cancel,
            timeouts,
        )
        .await
    }

    #[allow(clippy::too_many_arguments)]
    async fn run_for_model(
        endpoint: &str,
        api_key: &str,
        model_id: &str,
        config: &SttConfig,
        audio_rx: mpsc::Receiver<AudioChunk>,
        token_tx: broadcast::Sender<Token>,
        status_tx: watch::Sender<ConnectionStatus>,
        cancel: CancellationToken,
        timeouts: SonioxRtTimeouts,
    ) -> Result<(), SttError> {
        let failure_status = status_tx.clone();
        let result = Self::run_inner(
            endpoint, api_key, model_id, config, audio_rx, token_tx, status_tx, cancel, timeouts,
        )
        .await;

        if let Err(error) = &result {
            if !matches!(error, SttError::Cancelled) {
                let _ = failure_status.send(ConnectionStatus::Failed {
                    error: error.to_string(),
                });
            }
        }

        result
    }

    #[allow(clippy::too_many_arguments)]
    async fn run_inner(
        endpoint: &str,
        api_key: &str,
        model_id: &str,
        config: &SttConfig,
        mut audio_rx: mpsc::Receiver<AudioChunk>,
        token_tx: broadcast::Sender<Token>,
        status_tx: watch::Sender<ConnectionStatus>,
        cancel: CancellationToken,
        timeouts: SonioxRtTimeouts,
    ) -> Result<(), SttError> {
        tracing::info!(
            "[soniox-rt] connecting: endpoint={} key_len={} lang_hints={:?}",
            endpoint,
            api_key.len(),
            config.language_hints
        );

        let connect_result = tokio::select! {
            biased;
            _ = cancel.cancelled() => return Ok(()),
            result = timed_operation(
                "Soniox WebSocket connect",
                timeouts.connect,
                connect_async(endpoint),
            ) => result,
        };
        let (ws_stream, _) = connect_result?.map_err(|e| {
            tracing::error!("[soniox-rt] WebSocket connect failed: {e}");
            SttError::ConnectionFailed(e.to_string())
        })?;

        tracing::info!("[soniox-rt] WebSocket connected");
        let _ = status_tx.send(ConnectionStatus::Connected);
        let (mut write, mut read) = ws_stream.split();

        // 发送完整配置，确保未提供语言提示时启用自动语言识别。
        let language_hints_strict = if config.language_hints_strict {
            Some(true)
        } else {
            None
        };
        // 当用户没有指定 language_hints 时, 强制开启 enable_language_identification,
        // 这样 Soniox 会自动识别语言. 用户已经显式开启时也保留.
        let enable_lang_id =
            if config.enable_language_identification || config.language_hints.is_empty() {
                Some(true)
            } else {
                None
            };
        let enable_speaker_diarization = config.enable_speaker_diarization.then_some(true);
        // 始终启用 endpoint detection (D1 §1 建议), 让 token 在停顿时及时 finalize
        let enable_endpoint = Some(true);
        let context = build_soniox_context(config.context.as_ref());

        let engine = CURRENT_NOTEBOOK_CAPTURE_ENGINE;
        let rt_config = SonioxRtConfig {
            api_key: api_key.to_string(),
            model: model_id.to_string(),
            audio_format: engine.audio_format.to_string(),
            sample_rate: engine.sample_rate,
            num_channels: engine.channels,
            language_hints: config.language_hints.clone(),
            language_hints_strict,
            enable_language_identification: enable_lang_id,
            enable_speaker_diarization,
            enable_endpoint_detection: enable_endpoint,
            endpoint_latency_adjustment_level: Some(config.endpoint_latency_adjustment_level),
            endpoint_sensitivity: Some(config.endpoint_sensitivity),
            max_endpoint_delay_ms: Some(config.resolved_max_endpoint_delay_ms()),
            context,
            translation: config.translation.as_ref().map(|t| match t {
                TranslationConfig::OneWay { target_language } => SonioxTranslation::OneWay {
                    target_language: target_language.clone(),
                },
                TranslationConfig::TwoWay {
                    language_a,
                    language_b,
                } => SonioxTranslation::TwoWay {
                    language_a: language_a.clone(),
                    language_b: language_b.clone(),
                },
            }),
        };

        let config_json =
            serde_json::to_string(&rt_config).map_err(|e| SttError::ParseError(e.to_string()))?;
        tracing::info!(
            "[soniox-rt] sending config: {} chars (lang_id={:?}, endpoint_detect={:?}, has_context={})",
            config_json.len(),
            enable_lang_id,
            enable_endpoint,
            rt_config.context.is_some()
        );
        let config_send_result = tokio::select! {
            biased;
            _ = cancel.cancelled() => return Ok(()),
            result = timed_operation(
                "Soniox configuration send",
                timeouts.write,
                write.send(Message::Text(config_json.into())),
            ) => result,
        };
        config_send_result?.map_err(|e| {
            tracing::error!("[soniox-rt] send config failed: {e}");
            SttError::ConnectionFailed(e.to_string())
        })?;
        tracing::info!("[soniox-rt] config sent, entering audio + token loops");

        // 启动发送和接收任务
        let cancel_send = cancel.clone();
        let cancel_recv = cancel.clone();

        // 发送音频 task
        let mut send_handle: tokio::task::JoinHandle<Result<(), SttError>> = tokio::spawn(
            async move {
                let mut chunks_sent: u64 = 0;
                let mut bytes_sent: u64 = 0;
                loop {
                    tokio::select! {
                        biased;
                        _ = cancel_send.cancelled() => {
                            tracing::info!(
                                "[soniox-rt] send task cancelled after {chunks_sent} chunks / {bytes_sent} bytes"
                            );
                            break Ok(());
                        },
                        chunk = audio_rx.recv() => {
                            match chunk {
                                Some(c) => {
                                    let size = c.pcm_data.len();
                                    let send_result = tokio::select! {
                                        biased;
                                        _ = cancel_send.cancelled() => break Ok(()),
                                        result = timed_operation(
                                            "Soniox audio send",
                                            timeouts.write,
                                            write.send(Message::Binary(c.pcm_data.into())),
                                        ) => result,
                                    };
                                    send_result?.map_err(|error| {
                                        tracing::warn!(
                                            "[soniox-rt] audio send failed after {chunks_sent} chunks: {error}"
                                        );
                                        SttError::ConnectionFailed(error.to_string())
                                    })?;
                                    chunks_sent += 1;
                                    bytes_sent += size as u64;
                                    // 每 100 chunks 打一次,不淹没日志
                                    if chunks_sent.is_multiple_of(100) {
                                        tracing::info!(
                                            "[soniox-rt] sent {chunks_sent} audio chunks / {bytes_sent} bytes"
                                        );
                                    }
                                }
                                None => {
                                    tracing::info!(
                                        "[soniox-rt] audio_rx closed after {chunks_sent} chunks, sending EOF"
                                    );
                                    let eof_result = tokio::select! {
                                        biased;
                                        _ = cancel_send.cancelled() => break Ok(()),
                                        result = timed_operation(
                                            "Soniox EOF send",
                                            timeouts.write,
                                            write.send(Message::Binary(Vec::new().into())),
                                        ) => result,
                                    };
                                    eof_result?.map_err(|error| {
                                        SttError::ConnectionFailed(format!(
                                            "failed to send Soniox EOF: {error}"
                                        ))
                                    })?;
                                    break Ok(());
                                }
                            }
                        }
                    }
                }
            },
        );

        // 接收 token task。所有 provider / transport / timeout 错误都必须返回给调用者。
        let mut recv_handle: tokio::task::JoinHandle<Result<(), SttError>> = tokio::spawn(
            async move {
                let mut tokens_seen: u64 = 0;
                let recv_result = loop {
                    tokio::select! {
                        biased;
                        _ = cancel_recv.cancelled() => {
                            tracing::info!(
                                "[soniox-rt] recv task cancelled after {tokens_seen} tokens"
                            );
                            break Ok(());
                        },
                        receive_result = timed_operation(
                            "Soniox response receive",
                            timeouts.receive_idle,
                            read.next(),
                        ) => {
                            let msg = match receive_result {
                                Ok(msg) => msg,
                                Err(error) => break Err(error),
                            };
                            match msg {
                                Some(Ok(Message::Text(text))) => {
                                    match serde_json::from_str::<SonioxRtResponse>(&text) {
                                        Ok(response) => {
                                            // 优先检测错误 — 错误响应可能带空 tokens 数组
                                            if let Some(code) = response.error_code.as_ref() {
                                                let status = code.status();
                                                tracing::error!(
                                                    provider_status = status,
                                                    "[soniox-rt] server returned an error"
                                                );
                                                break Err(provider_error(
                                                    code,
                                                    response.error_type.as_deref(),
                                                    response.request_id.as_deref(),
                                                ));
                                            }
                                            if response.finished {
                                                tracing::info!(
                                                    "[soniox-rt] server sent finished=true after {tokens_seen} tokens"
                                                );
                                                break Ok(());
                                            }
                                            for st in response.tokens {
                                                // Soniox RT 端点标记:`text="<end>"` start/end=0 is_final=true。
                                                // 只用于内部 segment 边界,不是真 transcript,拼进 UI 会看到"<end>"。
                                                if st.text == "<end>" {
                                                    continue;
                                                }
                                                tokens_seen += 1;
                                                let _ = token_tx.send(st.into_model_token());
                                            }
                                        }
                                        Err(e) => {
                                            tracing::warn!(
                                                "[soniox-rt] JSON parse failed: {e}"
                                            );
                                            break Err(SttError::ParseError(e.to_string()));
                                        }
                                    }
                                }
                                Some(Ok(Message::Close(frame))) => {
                                    let close_code = frame
                                        .as_ref()
                                        .map(|close| u16::from(close.code));
                                    tracing::info!(
                                        close_code,
                                        "[soniox-rt] WebSocket closed by server"
                                    );
                                    break Err(close_frame_error(frame));
                                }
                                Some(Err(e)) => {
                                    tracing::warn!("[soniox-rt] WebSocket read error: {e}");
                                    break Err(SttError::ConnectionFailed(e.to_string()));
                                }
                                None => {
                                    tracing::info!("[soniox-rt] WebSocket stream ended");
                                    break Err(SttError::ConnectionFailed(
                                        "Soniox WebSocket stream ended before finished".to_string(),
                                    ));
                                }
                                _ => {}
                            }
                        }
                    }
                };
                tracing::info!("[soniox-rt] recv loop exit: total tokens = {tokens_seen}");
                recv_result
            },
        );

        let result = tokio::select! {
            send_join = &mut send_handle => {
                match join_result("Soniox audio sender", send_join) {
                    Err(error) => {
                        cancel.cancel();
                        if tokio::time::timeout(timeouts.shutdown, &mut recv_handle).await.is_err() {
                            recv_handle.abort();
                            let _ = recv_handle.await;
                        }
                        Err(error)
                    }
                    Ok(()) => {
                        match tokio::time::timeout(timeouts.drain, &mut recv_handle).await {
                            Ok(recv_join) => join_result("Soniox receiver", recv_join),
                            Err(_) => {
                                cancel.cancel();
                                recv_handle.abort();
                                let _ = recv_handle.await;
                                Err(SttError::ReadTimeout(timeouts.drain))
                            }
                        }
                    }
                }
            }
            recv_join = &mut recv_handle => {
                let recv_result = join_result("Soniox receiver", recv_join);
                cancel.cancel();
                let send_result = match tokio::time::timeout(timeouts.shutdown, &mut send_handle).await {
                    Ok(send_join) => join_result("Soniox audio sender", send_join),
                    Err(_) => {
                        send_handle.abort();
                        let _ = send_handle.await;
                        Err(SttError::Timeout {
                            operation: "Soniox audio sender shutdown".to_string(),
                            elapsed: timeouts.shutdown,
                        })
                    }
                };
                match recv_result {
                    Err(error) => Err(error),
                    Ok(()) => send_result,
                }
            }
        };

        result?;

        tracing::info!("[soniox-rt] run() complete");
        Ok(())
    }
}

#[cfg(test)]
mod run_tests {
    use super::*;
    use futures::{SinkExt, StreamExt};
    use tokio::net::TcpListener;
    use tokio_tungstenite::accept_async;
    use tokio_tungstenite::tungstenite::protocol::frame::coding::CloseCode;
    use tokio_tungstenite::tungstenite::protocol::CloseFrame;

    fn short_timeouts() -> SonioxRtTimeouts {
        SonioxRtTimeouts {
            connect: Duration::from_millis(80),
            write: Duration::from_millis(80),
            receive_idle: Duration::from_millis(80),
            drain: Duration::from_millis(50),
            shutdown: Duration::from_millis(50),
        }
    }

    struct ClientChannels {
        audio_tx: mpsc::Sender<AudioChunk>,
        audio_rx: mpsc::Receiver<AudioChunk>,
        token_tx: broadcast::Sender<Token>,
        status_tx: watch::Sender<ConnectionStatus>,
        status_rx: watch::Receiver<ConnectionStatus>,
    }

    fn client_channels() -> ClientChannels {
        let (audio_tx, audio_rx) = mpsc::channel(4);
        let (token_tx, _) = broadcast::channel(4);
        let (status_tx, status_rx) = watch::channel(ConnectionStatus::Reconnecting { attempt: 0 });
        ClientChannels {
            audio_tx,
            audio_rx,
            token_tx,
            status_tx,
            status_rx,
        }
    }

    #[test]
    fn invalid_request_is_not_misreported_as_bad_api_key() {
        let error = provider_error(
            &SonioxErrorCode::Numeric(400),
            Some("invalid_request"),
            Some("req-400"),
        );

        assert!(matches!(
            error,
            SttError::ApiError {
                status: 400,
                error_type,
                message,
            } if error_type == "invalid_request" && message.contains("req-400")
        ));
    }

    #[test]
    fn current_quota_and_rate_limit_types_are_classified_by_status() {
        for (error_type, expected_kind) in [
            (
                "organization_balance_exhausted",
                SonioxQuotaKind::OrganizationBalance,
            ),
            (
                "organization_monthly_budget_exhausted",
                SonioxQuotaKind::OrganizationMonthlyBudget,
            ),
            (
                "project_monthly_budget_exhausted",
                SonioxQuotaKind::ProjectMonthlyBudget,
            ),
        ] {
            let quota = provider_error(
                &SonioxErrorCode::Numeric(402),
                Some(error_type),
                Some("req-402"),
            );
            assert!(matches!(
                quota,
                SttError::QuotaExhausted { kind, message }
                    if kind == expected_kind && message.contains("req-402")
            ));
        }

        let rate_limit = provider_error(
            &SonioxErrorCode::Numeric(429),
            Some("limit_exceeded"),
            Some("req-429"),
        );
        assert!(matches!(rate_limit, SttError::RateLimited));
    }

    #[test]
    fn provider_request_id_rejects_credential_shaped_metadata() {
        let credential_shaped = format!("req-{}", "a".repeat(40));
        assert_eq!(safe_soniox_request_id(Some(&credential_shaped)), None);
        assert_eq!(safe_soniox_request_id(Some("req-api_key-fixture")), None);
        assert_eq!(
            safe_soniox_request_id(Some("req-support-123")),
            Some("req-support-123".to_string())
        );
    }

    #[tokio::test]
    async fn provider_auth_error_is_returned_and_published() {
        const HOSTILE_REMOTE_MESSAGE: &str =
            "credential-shaped provider detail api_key=fixture-value-never-log";
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let endpoint = format!("ws://{}", listener.local_addr().unwrap());
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let mut websocket = accept_async(stream).await.unwrap();
            let _ = websocket.next().await;
            websocket
                .send(Message::Text(
                    serde_json::json!({
                        "error_code": 401,
                        "error_type": "authentication_error",
                        "error_message": HOSTILE_REMOTE_MESSAGE,
                        "request_id": "req-auth-1"
                    })
                    .to_string()
                    .into(),
                ))
                .await
                .unwrap();
        });

        let ClientChannels {
            audio_tx: _audio_tx,
            audio_rx,
            token_tx,
            status_tx,
            status_rx,
        } = client_channels();
        let result = SonioxRtClient::run_with_timeouts(
            &endpoint,
            "bad-key",
            &SttConfig::default(),
            audio_rx,
            token_tx,
            status_tx,
            CancellationToken::new(),
            short_timeouts(),
        )
        .await;

        let error = result.expect_err("provider auth response must fail");
        let visible_error = error.to_string();
        assert!(matches!(error, SttError::AuthFailed { .. }));
        assert!(visible_error.contains("req-auth-1"));
        assert!(!visible_error.contains(HOSTILE_REMOTE_MESSAGE));
        assert!(!visible_error.contains("fixture-value-never-log"));
        let ConnectionStatus::Failed {
            error: status_error,
        } = &*status_rx.borrow()
        else {
            panic!("provider error must be published as failed status");
        };
        assert!(!status_error.contains(HOSTILE_REMOTE_MESSAGE));
        assert!(!status_error.contains("fixture-value-never-log"));
        server.await.unwrap();
    }

    #[tokio::test]
    async fn auth_close_frame_is_returned() {
        const HOSTILE_CLOSE_REASON: &str =
            "invalid api key credential-shaped-close-fixture-never-log";
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let endpoint = format!("ws://{}", listener.local_addr().unwrap());
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let mut websocket = accept_async(stream).await.unwrap();
            let _ = websocket.next().await;
            websocket
                .close(Some(CloseFrame {
                    code: CloseCode::Policy,
                    reason: HOSTILE_CLOSE_REASON.into(),
                }))
                .await
                .unwrap();
        });

        let ClientChannels {
            audio_tx: _audio_tx,
            audio_rx,
            token_tx,
            status_tx,
            status_rx: _status_rx,
        } = client_channels();
        let result = SonioxRtClient::run_with_timeouts(
            &endpoint,
            "bad-key",
            &SttConfig::default(),
            audio_rx,
            token_tx,
            status_tx,
            CancellationToken::new(),
            short_timeouts(),
        )
        .await;

        let error = result.expect_err("auth close frame must fail");
        let visible_error = error.to_string();
        assert!(matches!(error, SttError::AuthFailed { .. }));
        assert!(!visible_error.contains(HOSTILE_CLOSE_REASON));
        assert!(!visible_error.contains("credential-shaped-close-fixture-never-log"));
        server.await.unwrap();
    }

    #[tokio::test]
    async fn websocket_handshake_has_connect_timeout() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let endpoint = format!("ws://{}", listener.local_addr().unwrap());
        let server = tokio::spawn(async move {
            let (_stream, _) = listener.accept().await.unwrap();
            tokio::time::sleep(Duration::from_millis(300)).await;
        });

        let ClientChannels {
            audio_tx: _audio_tx,
            audio_rx,
            token_tx,
            status_tx,
            status_rx: _status_rx,
        } = client_channels();
        let result = SonioxRtClient::run_with_timeouts(
            &endpoint,
            "key",
            &SttConfig::default(),
            audio_rx,
            token_tx,
            status_tx,
            CancellationToken::new(),
            short_timeouts(),
        )
        .await;

        assert!(matches!(
            result,
            Err(SttError::Timeout { operation, .. })
                if operation == "Soniox WebSocket connect"
        ));
        server.abort();
    }

    #[tokio::test]
    async fn silent_server_has_receive_idle_timeout() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let endpoint = format!("ws://{}", listener.local_addr().unwrap());
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let mut websocket = accept_async(stream).await.unwrap();
            let _ = websocket.next().await;
            tokio::time::sleep(Duration::from_millis(300)).await;
        });

        let ClientChannels {
            audio_tx: _audio_tx,
            audio_rx,
            token_tx,
            status_tx,
            status_rx: _status_rx,
        } = client_channels();
        let result = SonioxRtClient::run_with_timeouts(
            &endpoint,
            "key",
            &SttConfig::default(),
            audio_rx,
            token_tx,
            status_tx,
            CancellationToken::new(),
            short_timeouts(),
        )
        .await;

        assert!(matches!(
            result,
            Err(SttError::Timeout { operation, .. })
                if operation == "Soniox response receive"
        ));
        server.abort();
    }

    #[tokio::test]
    async fn eof_waits_only_for_bounded_drain() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let endpoint = format!("ws://{}", listener.local_addr().unwrap());
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let mut websocket = accept_async(stream).await.unwrap();
            let _ = websocket.next().await;
            let _ = websocket.next().await;
            tokio::time::sleep(Duration::from_millis(300)).await;
        });

        let ClientChannels {
            audio_tx,
            audio_rx,
            token_tx,
            status_tx,
            status_rx: _status_rx,
        } = client_channels();
        drop(audio_tx);
        let mut timeouts = short_timeouts();
        timeouts.receive_idle = Duration::from_secs(1);
        let result = SonioxRtClient::run_with_timeouts(
            &endpoint,
            "key",
            &SttConfig::default(),
            audio_rx,
            token_tx,
            status_tx,
            CancellationToken::new(),
            timeouts,
        )
        .await;

        assert!(matches!(
            result,
            Err(SttError::ReadTimeout(elapsed)) if elapsed == timeouts.drain
        ));
        server.abort();
    }

    #[tokio::test]
    async fn websocket_write_operations_use_bounded_timeout_errors() {
        for operation in [
            "Soniox configuration send",
            "Soniox audio send",
            "Soniox EOF send",
        ] {
            let result = timed_operation(
                operation,
                Duration::from_millis(20),
                std::future::pending::<()>(),
            )
            .await;

            assert!(matches!(
                result,
                Err(SttError::Timeout {
                    operation: timed_out_operation,
                    ..
                }) if timed_out_operation == operation
            ));
        }
    }
}
