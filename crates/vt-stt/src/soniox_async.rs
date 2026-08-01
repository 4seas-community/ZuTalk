//! Soniox 异步文件转录 REST 客户端。
//!
//! 流程：上传文件 → 创建转录任务 → 轮询完成 → 拉取 transcript →
//! 删除远端转录任务和文件。
//!
//! Soniox 没有自动留存 TTL：远端"近零留存"由本模块强制执行。任何创建了
//! 远端状态的路径（成功、失败、取消、超时）都必须收敛到删除；且删除成功
//! 是返回转录成功的前置条件——远端还留着音频时不允许提交 terminal success。

use std::time::Duration;

use serde::Deserialize;
use tokio_util::sync::CancellationToken;
use vt_model::{Token, TranslationStatus};

use crate::error::{SonioxQuotaKind, SttError};

/// 生产轮询间隔。异步任务通常几秒到几十秒完成，2s 足够敏捷且不会触发限流。
pub const SONIOX_ASYNC_POLL_INTERVAL: Duration = Duration::from_secs(2);

const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
const REQUEST_TIMEOUT: Duration = Duration::from_secs(30);
const FILE_UPLOAD_TIMEOUT: Duration = Duration::from_secs(10 * 60);
/// 清理请求不受调用方 cancel/deadline 约束，但自身必须有界。
const CLEANUP_REQUEST_TIMEOUT: Duration = Duration::from_secs(10);
const CLEANUP_ATTEMPTS: usize = 3;
const CLEANUP_RETRY_BACKOFF: Duration = Duration::from_millis(500);

/// 一次异步文件转录请求。`base_url` 可注入以便测试指向本地 mock,
/// 或指向社区邀请服务的异步代理。
pub struct SonioxAsyncRequest<'a> {
    pub base_url: &'a str,
    pub api_key: &'a str,
    pub model: &'a str,
    pub language_hints: Vec<String>,
    pub enable_language_identification: bool,
    /// Exact Context snapshot frozen when the recording started. Keeping the
    /// serialized form avoids recompiling mutable knowledge-base contents for
    /// a later asynchronous transcription.
    pub context_json: Option<&'a str>,
    /// 稳定的工件标签(如 `zulangue-{task_id}`):作为上传文件名与转录任务的
    /// client_reference_id,启动扫尾据此识别崩溃遗留的远端工件。
    pub client_reference_id: Option<String>,
    /// 整体截止时间（上传 + 排队 + 处理 + 拉取）。在客户端内部执行，
    /// 保证超时后清理仍然运行，而不是被外层 timeout drop 掉。
    pub overall_deadline: Duration,
    pub poll_interval: Duration,
}

/// 远端工件生命周期回调,调用方用它把远端 id 落库(先记后用),
/// 并在远端确认删除后关闭日志行。回调必须快速返回且不可失败。
pub trait SonioxAsyncArtifactObserver: Send + Sync {
    fn remote_file_created(&self, remote_id: &str);
    fn remote_transcription_created(&self, remote_id: &str);
    /// 仅在文件与转录任务都确认删除(或确认不存在)后调用。
    fn remote_artifacts_cleaned(&self);
}

/// 已创建的远端对象。每拿到一个 id 立刻记录，clean-up 据此收敛。
#[derive(Default)]
struct RemoteArtifacts {
    file_id: Option<String>,
    transcription_id: Option<String>,
}

/// 把 16 kHz mono s16le PCM 包成最小 WAV（44 字节头），供文件上传使用。
pub fn wrap_pcm_s16le_in_wav(pcm: &[u8], sample_rate: u32, channels: u16) -> Vec<u8> {
    let byte_rate = sample_rate * channels as u32 * 2;
    let block_align = channels * 2;
    let data_len = pcm.len() as u32;
    let mut wav = Vec::with_capacity(44 + pcm.len());
    wav.extend_from_slice(b"RIFF");
    wav.extend_from_slice(&(36 + data_len).to_le_bytes());
    wav.extend_from_slice(b"WAVE");
    wav.extend_from_slice(b"fmt ");
    wav.extend_from_slice(&16u32.to_le_bytes());
    wav.extend_from_slice(&1u16.to_le_bytes()); // PCM
    wav.extend_from_slice(&channels.to_le_bytes());
    wav.extend_from_slice(&sample_rate.to_le_bytes());
    wav.extend_from_slice(&byte_rate.to_le_bytes());
    wav.extend_from_slice(&block_align.to_le_bytes());
    wav.extend_from_slice(&16u16.to_le_bytes()); // bits per sample
    wav.extend_from_slice(b"data");
    wav.extend_from_slice(&data_len.to_le_bytes());
    wav.extend_from_slice(pcm);
    wav
}

/// 上传 WAV、转录、取回 token，并在返回前删除远端文件与转录任务。
///
/// 取消与超时都在内部处理：先中止业务流程，再无条件跑清理，最后才返回。
/// 调用方不得再用外层 `tokio::time::timeout`/`select!` 包裹本调用，否则
/// future 被 drop 时清理不会执行。
pub async fn transcribe_wav(
    request: &SonioxAsyncRequest<'_>,
    wav_bytes: Vec<u8>,
    cancel: &CancellationToken,
    observer: Option<&dyn SonioxAsyncArtifactObserver>,
) -> Result<Vec<Token>, SttError> {
    if request.api_key.trim().is_empty() {
        return Err(SttError::AuthFailed {
            message: "API key is empty".to_string(),
        });
    }
    if cancel.is_cancelled() {
        return Err(SttError::Cancelled);
    }

    let client = reqwest::Client::builder()
        .connect_timeout(CONNECT_TIMEOUT)
        .build()
        .map_err(|error| SttError::HttpError(error.to_string()))?;

    let mut remote = RemoteArtifacts::default();
    let result = {
        let flow = run_flow(&client, request, wav_bytes, &mut remote, observer);
        tokio::pin!(flow);
        let deadline = tokio::time::sleep(request.overall_deadline);
        tokio::pin!(deadline);
        tokio::select! {
            biased;
            _ = cancel.cancelled() => Err(SttError::Cancelled),
            _ = &mut deadline => Err(SttError::Timeout {
                operation: "Soniox async transcription".to_string(),
                elapsed: request.overall_deadline,
            }),
            result = &mut flow => result,
        }
    };

    // 清理无条件运行，且不观察 cancel token：取消的任务同样不允许把音频
    // 留在 Soniox。清理错误只由 HTTP 状态码构成，不含 provider 正文。
    let cleanup = cleanup_remote(&client, request, &remote).await;
    if cleanup.is_ok() {
        if let Some(observer) = observer {
            observer.remote_artifacts_cleaned();
        }
    }
    match (result, cleanup) {
        (Ok(tokens), Ok(())) => Ok(tokens),
        // 留存收敛是成功的前置条件：transcript 已到手但远端没删干净时，
        // 必须报失败，避免 durable task 在远端仍有音频的情况下提交成功。
        (Ok(_), Err(cleanup_error)) => Err(cleanup_error),
        (Err(error), Ok(())) => Err(error),
        (Err(error), Err(cleanup_error)) => {
            tracing::warn!(
                cleanup_error = %cleanup_status_summary(&cleanup_error),
                "Soniox async cleanup failed after transcription error; remote artifacts may remain"
            );
            Err(error)
        }
    }
}

async fn run_flow(
    client: &reqwest::Client,
    request: &SonioxAsyncRequest<'_>,
    wav_bytes: Vec<u8>,
    remote: &mut RemoteArtifacts,
    observer: Option<&dyn SonioxAsyncArtifactObserver>,
) -> Result<Vec<Token>, SttError> {
    let file_id = upload_file(client, request, wav_bytes).await?;
    remote.file_id = Some(file_id.clone());
    if let Some(observer) = observer {
        observer.remote_file_created(&file_id);
    }

    let transcription_id = create_transcription(client, request, &file_id).await?;
    remote.transcription_id = Some(transcription_id.clone());
    if let Some(observer) = observer {
        observer.remote_transcription_created(&transcription_id);
    }

    wait_until_completed(client, request, &transcription_id).await?;
    fetch_transcript_tokens(client, request, &transcription_id).await
}

#[derive(Debug, Deserialize)]
struct CreatedObject {
    id: String,
}

#[derive(Debug, Deserialize)]
struct TranscriptionStatus {
    #[serde(default)]
    status: String,
    /// 稳定、可编程处理的 provider 错误类型。
    #[serde(default)]
    error_type: Option<String>,
    /// Provider 的人类可读文本是不可信内容，解码后仅丢弃，绝不能进入
    /// Display、durable error 或日志。
    #[serde(default, rename = "error_message")]
    _error_message: Option<String>,
}

#[derive(Debug, Deserialize)]
struct TranscriptResponse {
    #[serde(default)]
    tokens: Vec<AsyncTranscriptToken>,
}

/// 异步 transcript token。字段名与 RT 一致；speaker 兼容数字与字符串标签。
#[derive(Debug, Deserialize)]
struct AsyncTranscriptToken {
    text: String,
    #[serde(default)]
    start_ms: u64,
    #[serde(default)]
    end_ms: u64,
    #[serde(default)]
    confidence: f32,
    #[serde(default)]
    language: Option<String>,
    #[serde(default)]
    speaker: Option<SpeakerLabel>,
    #[serde(default)]
    translation_status: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(untagged)]
enum SpeakerLabel {
    Text(String),
    Number(i64),
}

impl AsyncTranscriptToken {
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
            // 异步 transcript 是定稿结果，没有 interim 修订。
            is_final: true,
            language: self.language.unwrap_or_default(),
            speaker: self.speaker.map(|label| match label {
                SpeakerLabel::Text(value) => value,
                SpeakerLabel::Number(value) => value.to_string(),
            }),
            confidence: self.confidence,
            translation_status: ts,
        }
    }
}

#[derive(Debug, Deserialize)]
struct ProviderErrorBody {
    #[serde(default)]
    error_type: Option<String>,
}

async fn upload_file(
    client: &reqwest::Client,
    request: &SonioxAsyncRequest<'_>,
    wav_bytes: Vec<u8>,
) -> Result<String, SttError> {
    // 文件列表接口只回 filename 不回 client_reference_id,所以标签同时
    // 写进文件名,启动扫尾才能识别"id 未及落库"的孤儿文件。
    let file_name = match request.client_reference_id.as_deref() {
        Some(reference) => format!("{reference}.wav"),
        None => "audio.wav".to_string(),
    };
    let part = reqwest::multipart::Part::bytes(wav_bytes)
        .file_name(file_name)
        .mime_str("audio/wav")
        .map_err(|error| SttError::UploadFailed {
            message: error.to_string(),
        })?;
    let form = reqwest::multipart::Form::new().part("file", part);
    let response = client
        .post(format!("{}/v1/files", request.base_url))
        .bearer_auth(request.api_key)
        .multipart(form)
        .timeout(FILE_UPLOAD_TIMEOUT)
        .send()
        .await
        .map_err(transport_error)?;
    let created: CreatedObject = decode_response("Soniox file upload", response).await?;
    Ok(created.id)
}

async fn create_transcription(
    client: &reqwest::Client,
    request: &SonioxAsyncRequest<'_>,
    file_id: &str,
) -> Result<String, SttError> {
    let mut body = serde_json::json!({
        "model": request.model,
        "file_id": file_id,
    });
    if !request.language_hints.is_empty() {
        body["language_hints"] = serde_json::json!(request.language_hints);
    }
    if request.enable_language_identification {
        body["enable_language_identification"] = serde_json::json!(true);
    }
    if let Some(context_json) = request.context_json {
        let context = serde_json::from_str(context_json).map_err(|error| {
            SttError::ParseError(format!("invalid frozen Soniox context: {error}"))
        })?;
        body["context"] = context;
    }
    if let Some(reference) = request.client_reference_id.as_deref() {
        body["client_reference_id"] = serde_json::json!(reference);
    }
    let response = client
        .post(format!("{}/v1/transcriptions", request.base_url))
        .bearer_auth(request.api_key)
        .json(&body)
        .timeout(REQUEST_TIMEOUT)
        .send()
        .await
        .map_err(transport_error)?;
    let created: CreatedObject = decode_response("Soniox create transcription", response).await?;
    Ok(created.id)
}

async fn wait_until_completed(
    client: &reqwest::Client,
    request: &SonioxAsyncRequest<'_>,
    transcription_id: &str,
) -> Result<(), SttError> {
    loop {
        let response = client
            .get(format!(
                "{}/v1/transcriptions/{transcription_id}",
                request.base_url
            ))
            .bearer_auth(request.api_key)
            .timeout(REQUEST_TIMEOUT)
            .send()
            .await
            .map_err(transport_error)?;
        let status: TranscriptionStatus =
            decode_response("Soniox transcription status", response).await?;
        match status.status.as_str() {
            "completed" => return Ok(()),
            "error" => {
                return Err(SttError::TranscriptionFailed {
                    error_type: status.error_type.unwrap_or_default(),
                    message: "Soniox async transcription failed".to_string(),
                })
            }
            // queued / pending / processing 以及未来新增的中间态。
            _ => tokio::time::sleep(request.poll_interval).await,
        }
    }
}

async fn fetch_transcript_tokens(
    client: &reqwest::Client,
    request: &SonioxAsyncRequest<'_>,
    transcription_id: &str,
) -> Result<Vec<Token>, SttError> {
    let response = client
        .get(format!(
            "{}/v1/transcriptions/{transcription_id}/transcript",
            request.base_url
        ))
        .bearer_auth(request.api_key)
        .timeout(REQUEST_TIMEOUT)
        .send()
        .await
        .map_err(transport_error)?;
    let transcript: TranscriptResponse =
        decode_response("Soniox transcript fetch", response).await?;
    Ok(transcript
        .tokens
        .into_iter()
        .map(AsyncTranscriptToken::into_model_token)
        .collect())
}

/// 先删转录任务，再删文件（文件可能被仍存在的转录任务引用）。
/// 404 视为已删除。任何一项最终失败都返回错误。
async fn cleanup_remote(
    client: &reqwest::Client,
    request: &SonioxAsyncRequest<'_>,
    remote: &RemoteArtifacts,
) -> Result<(), SttError> {
    let endpoint = SonioxRemoteEndpoint {
        base_url: request.base_url,
        api_key: request.api_key,
    };
    let mut first_error: Option<SttError> = None;
    if let Some(id) = remote.transcription_id.as_deref() {
        if let Err(error) = delete_with_retry(client, &endpoint, "transcriptions", id).await {
            first_error.get_or_insert(error);
        }
    }
    if let Some(id) = remote.file_id.as_deref() {
        if let Err(error) = delete_with_retry(client, &endpoint, "files", id).await {
            first_error.get_or_insert(error);
        }
    }
    match first_error {
        None => Ok(()),
        Some(error) => Err(error),
    }
}

/// 扫尾/清理共用的最小远端定位。
pub struct SonioxRemoteEndpoint<'a> {
    pub base_url: &'a str,
    pub api_key: &'a str,
}

/// 删除远端文件(404 视为已删除,带重试)。启动扫尾使用。
pub async fn delete_remote_file(
    endpoint: &SonioxRemoteEndpoint<'_>,
    remote_id: &str,
) -> Result<(), SttError> {
    let client = sweep_client()?;
    delete_with_retry(&client, endpoint, "files", remote_id).await
}

/// 删除远端转录任务(404 视为已删除,带重试)。启动扫尾使用。
pub async fn delete_remote_transcription(
    endpoint: &SonioxRemoteEndpoint<'_>,
    remote_id: &str,
) -> Result<(), SttError> {
    let client = sweep_client()?;
    delete_with_retry(&client, endpoint, "transcriptions", remote_id).await
}

/// 远端清单条目。文件带 filename,转录任务带 client_reference_id。
#[derive(Debug, Clone, Deserialize)]
pub struct SonioxRemoteInventoryEntry {
    pub id: String,
    #[serde(default)]
    pub filename: Option<String>,
    #[serde(default)]
    pub client_reference_id: Option<String>,
}

#[derive(Debug, Deserialize)]
struct RemoteFileList {
    #[serde(default)]
    files: Vec<SonioxRemoteInventoryEntry>,
    #[serde(default)]
    next_page_cursor: Option<String>,
}

#[derive(Debug, Deserialize)]
struct RemoteTranscriptionList {
    #[serde(default)]
    transcriptions: Vec<SonioxRemoteInventoryEntry>,
    #[serde(default)]
    next_page_cursor: Option<String>,
}

const SWEEP_LIST_PAGE_LIMIT: usize = 20;

/// 列出远端全部文件(分页,页数有上限防御)。启动扫尾用它按文件名标签
/// 找回"id 未及落库"的孤儿。
pub async fn list_remote_files(
    endpoint: &SonioxRemoteEndpoint<'_>,
) -> Result<Vec<SonioxRemoteInventoryEntry>, SttError> {
    let client = sweep_client()?;
    let mut entries = Vec::new();
    let mut cursor: Option<String> = None;
    for _ in 0..SWEEP_LIST_PAGE_LIMIT {
        let mut url = format!("{}/v1/files?limit=1000", endpoint.base_url);
        if let Some(cursor) = cursor.as_deref() {
            url.push_str(&format!("&cursor={cursor}"));
        }
        let response = client
            .get(url)
            .bearer_auth(endpoint.api_key)
            .timeout(REQUEST_TIMEOUT)
            .send()
            .await
            .map_err(transport_error)?;
        let page: RemoteFileList = decode_response("Soniox file list", response).await?;
        entries.extend(page.files);
        match page.next_page_cursor {
            Some(next) if !next.is_empty() => cursor = Some(next),
            _ => break,
        }
    }
    Ok(entries)
}

/// 列出远端全部转录任务(分页,页数有上限防御)。
pub async fn list_remote_transcriptions(
    endpoint: &SonioxRemoteEndpoint<'_>,
) -> Result<Vec<SonioxRemoteInventoryEntry>, SttError> {
    let client = sweep_client()?;
    let mut entries = Vec::new();
    let mut cursor: Option<String> = None;
    for _ in 0..SWEEP_LIST_PAGE_LIMIT {
        let mut url = format!("{}/v1/transcriptions?limit=1000", endpoint.base_url);
        if let Some(cursor) = cursor.as_deref() {
            url.push_str(&format!("&cursor={cursor}"));
        }
        let response = client
            .get(url)
            .bearer_auth(endpoint.api_key)
            .timeout(REQUEST_TIMEOUT)
            .send()
            .await
            .map_err(transport_error)?;
        let page: RemoteTranscriptionList =
            decode_response("Soniox transcription list", response).await?;
        entries.extend(page.transcriptions);
        match page.next_page_cursor {
            Some(next) if !next.is_empty() => cursor = Some(next),
            _ => break,
        }
    }
    Ok(entries)
}

fn sweep_client() -> Result<reqwest::Client, SttError> {
    reqwest::Client::builder()
        .connect_timeout(CONNECT_TIMEOUT)
        .build()
        .map_err(|error| SttError::HttpError(error.to_string()))
}

async fn delete_with_retry(
    client: &reqwest::Client,
    endpoint: &SonioxRemoteEndpoint<'_>,
    resource: &str,
    id: &str,
) -> Result<(), SttError> {
    let mut last_status: Option<u16> = None;
    for attempt in 0..CLEANUP_ATTEMPTS {
        if attempt > 0 {
            tokio::time::sleep(CLEANUP_RETRY_BACKOFF).await;
        }
        let response = client
            .delete(format!("{}/v1/{resource}/{id}", endpoint.base_url))
            .bearer_auth(endpoint.api_key)
            .timeout(CLEANUP_REQUEST_TIMEOUT)
            .send()
            .await;
        match response {
            Ok(response) => {
                let status = response.status();
                if status.is_success() || status.as_u16() == 404 {
                    return Ok(());
                }
                last_status = Some(status.as_u16());
            }
            Err(_) => last_status = None,
        }
    }
    Err(SttError::ApiError {
        status: last_status.unwrap_or(0),
        error_type: format!("soniox_async_{resource}_delete_failed"),
        message: String::new(),
    })
}

/// 清理错误的日志摘要：只反映资源与状态码，不含 provider 正文。
fn cleanup_status_summary(error: &SttError) -> String {
    match error {
        SttError::ApiError {
            status, error_type, ..
        } => format!("{error_type} (status={status})"),
        _ => "cleanup request failed".to_string(),
    }
}

fn transport_error(error: reqwest::Error) -> SttError {
    if error.is_timeout() {
        SttError::Timeout {
            operation: "Soniox async request".to_string(),
            elapsed: REQUEST_TIMEOUT,
        }
    } else if error.is_connect() {
        SttError::ConnectionFailed("Soniox HTTP connect failed".to_string())
    } else {
        SttError::HttpError("Soniox HTTP request failed".to_string())
    }
}

async fn decode_response<T: serde::de::DeserializeOwned>(
    operation: &str,
    response: reqwest::Response,
) -> Result<T, SttError> {
    let status = response.status();
    if !status.is_success() {
        let error_type = response
            .json::<ProviderErrorBody>()
            .await
            .ok()
            .and_then(|body| body.error_type)
            .unwrap_or_default();
        return Err(http_status_error(status.as_u16(), error_type));
    }
    response
        .json::<T>()
        .await
        .map_err(|error| SttError::ParseError(format!("{operation}: {error}")))
}

fn http_status_error(status: u16, error_type: String) -> SttError {
    match status {
        401 | 403 => SttError::AuthFailed {
            message: format!("authentication_error (status={status})"),
        },
        402 => SttError::QuotaExhausted {
            kind: SonioxQuotaKind::from_error_type(Some(&error_type)),
            message: "quota exhausted".to_string(),
        },
        429 => SttError::RateLimited,
        500..=599 => SttError::ServerError {
            status,
            message: error_type,
        },
        _ => SttError::ApiError {
            status,
            error_type,
            message: String::new(),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wav_wrapper_writes_canonical_16k_mono_header() {
        let pcm = vec![0u8; 32_000]; // 1 秒 16k mono s16le
        let wav = wrap_pcm_s16le_in_wav(&pcm, 16_000, 1);
        assert_eq!(wav.len(), 44 + 32_000);
        assert_eq!(&wav[0..4], b"RIFF");
        assert_eq!(&wav[8..12], b"WAVE");
        assert_eq!(u16::from_le_bytes([wav[22], wav[23]]), 1); // channels
        assert_eq!(
            u32::from_le_bytes([wav[24], wav[25], wav[26], wav[27]]),
            16_000
        );
        assert_eq!(
            u32::from_le_bytes([wav[28], wav[29], wav[30], wav[31]]),
            32_000
        ); // byte rate
        assert_eq!(
            u32::from_le_bytes([wav[40], wav[41], wav[42], wav[43]]),
            32_000
        ); // data size
    }

    #[test]
    fn async_token_maps_language_speaker_and_translation_status() {
        let token: AsyncTranscriptToken = serde_json::from_str(
            r#"{"text":"你好","start_ms":10,"end_ms":250,"confidence":0.9,
                "language":"zh","speaker":2,"translation_status":"translation"}"#,
        )
        .unwrap();
        let token = token.into_model_token();
        assert_eq!(token.text, "你好");
        assert!(token.is_final);
        assert_eq!(token.language, "zh");
        assert_eq!(token.speaker.as_deref(), Some("2"));
        assert_eq!(token.translation_status, TranslationStatus::Translation);

        let bare: AsyncTranscriptToken = serde_json::from_str(r#"{"text":"hi"}"#).unwrap();
        let bare = bare.into_model_token();
        assert_eq!(bare.language, "");
        assert_eq!(bare.speaker, None);
        assert_eq!(bare.translation_status, TranslationStatus::None);
    }

    #[test]
    fn http_status_errors_map_to_provider_error_taxonomy() {
        assert!(matches!(
            http_status_error(401, String::new()),
            SttError::AuthFailed { .. }
        ));
        assert!(matches!(
            http_status_error(402, "organization_balance_exhausted".into()),
            SttError::QuotaExhausted {
                kind: SonioxQuotaKind::OrganizationBalance,
                ..
            }
        ));
        assert!(matches!(
            http_status_error(429, String::new()),
            SttError::RateLimited
        ));
        assert!(matches!(
            http_status_error(503, String::new()),
            SttError::ServerError { status: 503, .. }
        ));
        assert!(matches!(
            http_status_error(400, String::new()),
            SttError::ApiError { status: 400, .. }
        ));
    }
}
