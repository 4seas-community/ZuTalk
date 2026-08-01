//! 转录 FFI API
//!
//! Provider execution is crate-internal. Authorized post-recording
//! transcription is created only from an immutable Notebook capture/import run
//! and consumed by the durable task worker.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use tokio_util::sync::CancellationToken;
use vt_audio::{canonicalize_for_soniox, SONIOX_CANONICAL_SAMPLE_RATE};
use vt_crypto::{KeyProvider, SessionKey};
use vt_model::Token;
use vt_store::{AsyncProviderReceipt, NotebookCaptureStore, SearchStore, SessionMetaStore};
use vt_stt::{
    soniox_async_transcribe_wav, wrap_pcm_s16le_in_wav, SonioxAsyncArtifactObserver,
    SonioxAsyncRequest, SttError, CURRENT_NOTEBOOK_CAPTURE_ENGINE, SONIOX_ASYNC_POLL_INTERVAL,
};

pub(crate) type ProviderDispatchGate = Arc<dyn Fn() -> Result<(), (String, String)> + Send + Sync>;

const SONIOX_ASYNC_TASK_MIN_TIMEOUT: Duration = Duration::from_secs(90);
const SONIOX_ASYNC_TASK_MAX_TIMEOUT: Duration = Duration::from_secs(60 * 60);
/// 上传 + 排队裕量。异步 API 支持最长 5 小时的文件，处理速度远快于实时。
const SONIOX_ASYNC_TASK_BASE_ALLOWANCE: Duration = Duration::from_secs(5 * 60);

/// 远端工件标签。上传文件名与转录任务的 `client_reference_id` 都用它，
/// 启动扫尾据此在远端清单里认出本机遗留的工件。
pub(crate) fn provider_artifact_reference(task_id: &str) -> String {
    format!("zulangue-{task_id}")
}

/// 把 `soniox_async` 的远端工件生命周期落到 `provider_remote_artifacts` 日志。
///
/// 回调不能失败：此刻远端已经有工件，中断反而把它留得更久。写库失败只记
/// WARN，兜底仍是启动扫尾——claim 行在任何远端调用之前就已落库，扫尾即使
/// 没有具体 id 也能按标签在远端清单里找回。
struct RemoteArtifactJournal {
    store: NotebookCaptureStore,
    task_id: String,
}

impl SonioxAsyncArtifactObserver for RemoteArtifactJournal {
    fn remote_file_created(&self, remote_id: &str) {
        if let Err(error) = self
            .store
            .record_provider_remote_file(&self.task_id, remote_id)
        {
            tracing::warn!(
                task_id = %self.task_id,
                error = %error,
                "failed to journal remote provider file id; startup sweep will fall back to the reference tag"
            );
        }
    }

    fn remote_transcription_created(&self, remote_id: &str) {
        if let Err(error) = self
            .store
            .record_provider_remote_transcription(&self.task_id, remote_id)
        {
            tracing::warn!(
                task_id = %self.task_id,
                error = %error,
                "failed to journal remote provider transcription id; startup sweep will fall back to the reference tag"
            );
        }
    }

    fn remote_artifacts_cleaned(&self) {
        if let Err(error) = self
            .store
            .close_provider_remote_artifact_claim(&self.task_id)
        {
            tracing::warn!(
                task_id = %self.task_id,
                error = %error,
                "failed to close remote provider artifact claim; startup sweep will re-confirm deletion"
            );
        }
    }
}

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
enum SonioxTranscriptionError {
    #[error("Soniox async transcription cancelled")]
    Cancelled,
    #[error("{0}")]
    Failed(String),
}

fn transcription_cancelled_error() -> (String, String) {
    (
        "cancelled".to_string(),
        SonioxTranscriptionError::Cancelled.to_string(),
    )
}

fn ensure_transcription_not_cancelled(cancel: &CancellationToken) -> Result<(), (String, String)> {
    if cancel.is_cancelled() {
        Err(transcription_cancelled_error())
    } else {
        Ok(())
    }
}

fn soniox_async_task_timeout(audio_bytes: usize) -> Duration {
    // 异步 API 的处理明显快于实时；预算 = 上传/排队裕量 + 音频时长的一半，
    // 上限保护 5 小时量级的长文件不会被过早判死。
    let audio_duration_ms = (audio_bytes as u64).saturating_mul(1000)
        / (SONIOX_CANONICAL_SAMPLE_RATE as u64 * 2).max(1);
    Duration::from_millis(audio_duration_ms / 2)
        .saturating_add(SONIOX_ASYNC_TASK_BASE_ALLOWANCE)
        .clamp(SONIOX_ASYNC_TASK_MIN_TIMEOUT, SONIOX_ASYNC_TASK_MAX_TIMEOUT)
}

#[cfg(test)]
async fn within_soniox_whole_task_deadline<F, T>(deadline: Duration, future: F) -> Option<T>
where
    F: std::future::Future<Output = T>,
{
    tokio::time::timeout(deadline, future).await.ok()
}

/// This string crosses the durable task/error logging boundary. Do not use the
/// `Display` implementation here: provider error messages and close reasons are
/// untrusted and may echo credential-shaped content.
fn safe_soniox_task_error(error: &SttError) -> String {
    match error {
        SttError::AuthFailed { .. } => "Soniox authentication failed".to_string(),
        SttError::QuotaExhausted { .. } => "Soniox quota exhausted".to_string(),
        SttError::RateLimited => "Soniox rate limited the request".to_string(),
        SttError::ServerClosed { code, .. } => {
            format!("Soniox closed the connection (status={code})")
        }
        SttError::ApiError { status, .. } | SttError::ServerError { status, .. } => {
            format!("Soniox provider request failed (status={status})")
        }
        SttError::ReadTimeout(_) | SttError::Timeout { .. } => {
            "Soniox provider request timed out".to_string()
        }
        SttError::Cancelled => "Soniox provider request cancelled".to_string(),
        SttError::ParseError(_) => "Soniox provider response was invalid".to_string(),
        SttError::ConnectionFailed(_) | SttError::HttpError(_) => {
            "Soniox connection failed".to_string()
        }
        SttError::TranscriptionFailed { .. } => "Soniox transcription failed".to_string(),
        SttError::UploadFailed { .. } => "Soniox audio upload failed".to_string(),
    }
}

/// Internal provider result consumed by the durable task worker.
pub struct TranscribeSessionResult {
    pub session_id: String,
    pub token_count: u32,
    pub full_text: String,
    pub duration_ms: u64,
}

/// Internal task progress sink. The Notebook UI reads durable task/run state;
/// this trait is deliberately not part of the UniFFI ABI.
pub trait FfiTaskCallback: Send + Sync {
    /// 进度通知
    /// - stage: "decrypting" | "uploading" | "transcribing" | "indexing" | ...
    /// - percent: 0.0 ~ 100.0
    fn on_progress(&self, task_id: String, stage: String, percent: f32);

    /// 完成通知
    /// - result_json: 序列化后的任务结果
    fn on_complete(&self, task_id: String, result_json: String);

    /// 错误通知
    /// - code: "validation_failed" | "not_found" | "internal_error" | ...
    fn on_error(&self, task_id: String, code: String, message: String);
}

/// 异步任务完成后应用隐私 enforcement，独立函数避免持有 &self。
///
/// high / maximum 的音频销毁是 terminal success 的前置条件；任何删除、
/// ledger 标记或 key 清理失败都必须返回 Err，不能发成功回调后再 warn。
pub(crate) fn enforce_privacy_after_task(
    session_id: &str,
    db_path: &std::path::Path,
    key_store: &dyn KeyProvider,
) -> Result<(), String> {
    let session_meta =
        SessionMetaStore::new(db_path).map_err(|e| format!("open session_meta: {e}"))?;
    let meta = session_meta
        .get_meta(session_id)
        .map_err(|e| format!("session meta not found or unreadable: {e}"))?;
    let level = crate::validate_frozen_session_privacy_level(meta.privacy_level).map_err(|_| {
        "privacy_state_invalid: session privacy level is missing or invalid".to_string()
    })?;
    if level == "standard" {
        return Ok(()); // 不销毁
    }

    let now_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64;
    let chunks = session_meta
        .list_audio_retention_chunks(session_id)
        .map_err(|e| format!("list audio retention chunks: {e}"))?;

    for chunk in chunks.iter().filter(|chunk| !chunk.deleted) {
        let p = std::path::PathBuf::from(&chunk.local_path);
        if p.exists() {
            if let Err(e) = vt_pipeline::privacy::PrivacyDestroyer::destroy_file(&p) {
                let message = e.to_string();
                session_meta
                    .mark_audio_retention_chunk_delete_failed(session_id, &chunk.chunk_id, &message)
                    .map_err(|mark_error| {
                        format!("destroy chunk file: {message}; mark delete failure: {mark_error}")
                    })?;
                return Err(format!("destroy chunk file: {message}"));
            }
        }
        session_meta
            .mark_audio_retention_chunk_deleted(session_id, &chunk.chunk_id, now_ms)
            .map_err(|e| format!("mark audio chunk deleted: {e}"))?;
    }

    // Both retention policies delete the corresponding encryption key. Keeping
    // an orphan key after destroying the ciphertext adds no recovery value and
    // makes the retention receipt dishonest.
    if let Some(key_id) = meta.key_id.as_deref() {
        if !key_id.is_empty() {
            key_store
                .delete_key(key_id)
                .map_err(|e| format!("delete key: {e}"))?;
        }
    }

    // Clear both metadata owners only after the ledger, files, and key have
    // converged. History retains chronology/transcript facts but can no longer
    // claim that audio is available for replay or another remote request.
    session_meta
        .clear_encrypted_path(session_id)
        .map_err(|e| format!("clear encrypted path: {e}"))?;
    let capture_store = NotebookCaptureStore::new(db_path)
        .map_err(|e| format!("open capture store for retention cleanup: {e}"))?;
    if capture_store
        .get_run_for_session(session_id)
        .map_err(|e| format!("load capture audio references: {e}"))?
        .is_some()
    {
        capture_store
            .clear_retained_audio_references(session_id)
            .map_err(|e| format!("clear capture audio references: {e}"))?;
    }
    Ok(())
}

#[allow(clippy::too_many_arguments)]
pub(crate) async fn run_transcribe_chunked_task_async(
    task_id: &str,
    session_id: &str,
    soniox_api_key: &str,
    language: Option<&str>,
    context_json: Option<&str>,
    chunk_paths: Vec<PathBuf>,
    key: SessionKey,
    source_sample_rate: u32,
    source_channels: u16,
    expected_source_frames: u64,
    db_path: PathBuf,
    callback: Arc<dyn FfiTaskCallback>,
    cancel: CancellationToken,
    provider_dispatch_gate: ProviderDispatchGate,
) -> Result<String, (String, String)> {
    ensure_transcription_not_cancelled(&cancel)?;
    callback.on_progress(task_id.to_string(), "decrypting".to_string(), 5.0);
    use std::io::Read;
    let mut pcm_f32_bytes = Vec::new();
    for path in chunk_paths {
        ensure_transcription_not_cancelled(&cancel)?;
        let mut reader = vt_crypto::DecryptReader::new(&path, &key).map_err(|e| {
            (
                "internal_error".to_string(),
                format!("decrypt chunk reader: {e}"),
            )
        })?;
        reader.read_to_end(&mut pcm_f32_bytes).map_err(|e| {
            (
                "internal_error".to_string(),
                format!("decrypt chunk read: {e}"),
            )
        })?;
    }
    ensure_transcription_not_cancelled(&cancel)?;

    run_transcribe_pcm_f32_bytes_async(
        task_id,
        session_id,
        soniox_api_key,
        language,
        context_json,
        pcm_f32_bytes,
        source_sample_rate,
        source_channels,
        expected_source_frames,
        db_path,
        callback,
        cancel,
        provider_dispatch_gate,
    )
    .await
}

#[allow(clippy::too_many_arguments)]
async fn run_transcribe_pcm_f32_bytes_async(
    task_id: &str,
    session_id: &str,
    soniox_api_key: &str,
    language: Option<&str>,
    context_json: Option<&str>,
    pcm_f32_bytes: Vec<u8>,
    source_sample_rate: u32,
    source_channels: u16,
    expected_source_frames: u64,
    db_path: PathBuf,
    callback: Arc<dyn FfiTaskCallback>,
    cancel: CancellationToken,
    provider_dispatch_gate: ProviderDispatchGate,
) -> Result<String, (String, String)> {
    ensure_transcription_not_cancelled(&cancel)?;
    callback.on_progress(task_id.to_string(), "encoding".to_string(), 15.0);

    // 2. Stored audio keeps its decoded source format. Provider upload is
    // always canonical 16 kHz mono s16le and is rebuilt solely from the
    // immutable capture-run/session format snapshot loaded by the worker.
    let prepared = prepare_soniox_audio(&pcm_f32_bytes, source_sample_rate, source_channels)
        .map_err(|message| ("validation_failed".to_string(), message))?;
    if prepared.source_frames != expected_source_frames {
        return Err((
            "validation_failed".to_string(),
            format!(
                "capture audio frame count {} does not match immutable run snapshot {expected_source_frames}",
                prepared.source_frames
            ),
        ));
    }
    ensure_transcription_not_cancelled(&cancel)?;

    // The worker supplies the durable provider-provenance claim. Running the
    // gate here keeps decrypt/format/frame validation local-only while still
    // guaranteeing the claim commits before Soniox is constructed or called.
    provider_dispatch_gate()?;

    // Journal the remote-artifact claim before Soniox is contacted: the row is
    // the only durable record that this machine may have left audio on the
    // provider, so it must exist even if the process dies mid-upload.
    let artifact_reference = provider_artifact_reference(task_id);
    let journal = open_remote_artifact_journal(&db_path, task_id, session_id, &artifact_reference)?;

    callback.on_progress(task_id.to_string(), "transcribing".to_string(), 25.0);

    // 3. Soniox async file API
    let raw_tokens = run_soniox_transcription(
        soniox_api_key,
        language,
        context_json,
        prepared.s16le,
        cancel.clone(),
        &artifact_reference,
        Some(&journal),
    )
    .await
    .map_err(|error| match error {
        SonioxTranscriptionError::Cancelled => transcription_cancelled_error(),
        SonioxTranscriptionError::Failed(message) => {
            ("internal_error".to_string(), format!("soniox: {message}"))
        }
    })?;
    ensure_transcription_not_cancelled(&cancel)?;

    callback.on_progress(task_id.to_string(), "deduping".to_string(), 80.0);

    let deduped = dedupe_soniox_tokens(raw_tokens);
    let full_text: String = deduped.iter().map(|t| t.text.as_str()).collect();
    let token_count = deduped.len() as u32;

    ensure_transcription_not_cancelled(&cancel)?;
    callback.on_progress(task_id.to_string(), "indexing".to_string(), 90.0);
    ensure_transcription_not_cancelled(&cancel)?;

    finish_transcribe_task_output(
        task_id,
        session_id,
        &deduped,
        &full_text,
        token_count,
        prepared.duration_ms,
        &db_path,
        callback.as_ref(),
    )
}

#[derive(Debug)]
struct PreparedSonioxAudio {
    s16le: Vec<u8>,
    duration_ms: u64,
    source_frames: u64,
}

fn prepare_soniox_audio(
    pcm_f32le: &[u8],
    source_sample_rate: u32,
    source_channels: u16,
) -> Result<PreparedSonioxAudio, String> {
    if source_sample_rate == 0 || source_channels == 0 {
        return Err("capture audio format must have a positive sample rate and channels".into());
    }
    let bytes_per_frame = source_channels as usize * std::mem::size_of::<f32>();
    if !pcm_f32le.len().is_multiple_of(bytes_per_frame) {
        return Err(format!(
            "capture audio byte count {} is not aligned to {source_channels} f32 channels",
            pcm_f32le.len()
        ));
    }
    let source_frames = pcm_f32le.len() / bytes_per_frame;
    if source_frames == 0 {
        return Err("capture audio has no PCM frames".into());
    }
    let samples = pcm_f32le
        .chunks_exact(std::mem::size_of::<f32>())
        .map(|bytes| f32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]))
        .collect::<Vec<_>>();
    let canonical = canonicalize_for_soniox(&samples, source_sample_rate, source_channels)
        .map_err(|error| format!("canonicalize capture audio: {error}"))?;
    let duration_ms_u128 =
        (source_frames as u128).saturating_mul(1000) / source_sample_rate as u128;
    let duration_ms = u64::try_from(duration_ms_u128).unwrap_or(u64::MAX);
    let mut s16le = Vec::with_capacity(canonical.len() * 2);
    for sample in canonical {
        let value = if sample <= -1.0 {
            i16::MIN
        } else {
            (sample.clamp(-1.0, 1.0) * i16::MAX as f32).round() as i16
        };
        s16le.extend_from_slice(&value.to_le_bytes());
    }
    debug_assert_eq!(
        s16le.len() / 2,
        ((source_frames as u128 * SONIOX_CANONICAL_SAMPLE_RATE as u128
            + (source_sample_rate / 2) as u128)
            / source_sample_rate as u128) as usize
    );

    Ok(PreparedSonioxAudio {
        s16le,
        duration_ms,
        source_frames: u64::try_from(source_frames).unwrap_or(u64::MAX),
    })
}

#[allow(clippy::too_many_arguments)]
fn finish_transcribe_task_output(
    task_id: &str,
    session_id: &str,
    tokens: &[Token],
    full_text: &str,
    token_count: u32,
    duration_ms: u64,
    db_path: &Path,
    callback: &dyn FfiTaskCallback,
) -> Result<String, (String, String)> {
    finish_transcribe_task_output_with_projection(
        task_id,
        session_id,
        tokens,
        full_text,
        token_count,
        duration_ms,
        db_path,
        callback,
        |receipt| project_transcribe_search_receipt(db_path, receipt),
    )
}

#[allow(clippy::too_many_arguments)]
fn finish_transcribe_task_output_with_projection<P>(
    task_id: &str,
    session_id: &str,
    tokens: &[Token],
    full_text: &str,
    token_count: u32,
    duration_ms: u64,
    db_path: &Path,
    callback: &dyn FfiTaskCallback,
    project_search: P,
) -> Result<String, (String, String)>
where
    P: FnOnce(&AsyncProviderReceipt) -> Result<(), String>,
{
    let json = transcribe_result_json(session_id, full_text, token_count, duration_ms);
    let receipt = persist_transcribe_task_output(db_path, task_id, session_id, tokens, &json)?;
    if let Err(error) = project_search(&receipt) {
        tracing::warn!(
            session_id,
            task_id,
            error = %error,
            "provider output is durable; local FTS projection remains retryable"
        );
    }
    callback.on_progress(task_id.to_string(), "finalizing".to_string(), 95.0);
    Ok(json)
}

fn transcribe_result_json(
    session_id: &str,
    full_text: &str,
    token_count: u32,
    duration_ms: u64,
) -> String {
    let result = TranscribeSessionResult {
        session_id: session_id.to_string(),
        token_count,
        full_text: full_text.to_string(),
        duration_ms,
    };
    serde_json::json!({
        "session_id": result.session_id,
        "token_count": result.token_count,
        "full_text": result.full_text,
        "duration_ms": result.duration_ms,
    })
    .to_string()
}

/// 落 claim 行并返回观察者。失败必须中止本次派发：日志写不下去时，任何
/// 远端调用都会产生我们无法保证删除的留存。
fn open_remote_artifact_journal(
    db_path: &Path,
    task_id: &str,
    session_id: &str,
    artifact_reference: &str,
) -> Result<RemoteArtifactJournal, (String, String)> {
    let store = NotebookCaptureStore::new(db_path).map_err(|error| {
        (
            "internal_error".to_string(),
            format!("open capture store for remote artifact journal: {error}"),
        )
    })?;
    store
        .open_provider_remote_artifact_claim(task_id, session_id, artifact_reference)
        .map_err(|error| {
            (
                "internal_error".to_string(),
                format!("journal remote provider artifact claim: {error}"),
            )
        })?;
    Ok(RemoteArtifactJournal {
        store,
        task_id: task_id.to_string(),
    })
}

fn persist_transcribe_task_output(
    db_path: &Path,
    task_id: &str,
    session_id: &str,
    tokens: &[Token],
    result_json: &str,
) -> Result<AsyncProviderReceipt, (String, String)> {
    let capture_store = NotebookCaptureStore::new(db_path).map_err(|error| {
        (
            "internal_error".to_string(),
            format!("open capture store for provider receipt: {error}"),
        )
    })?;
    capture_store
        .commit_async_provider_success(session_id, task_id, tokens, result_json)
        .map_err(|error| {
            (
                "internal_error".to_string(),
                format!("commit provider transcript receipt: {error}"),
            )
        })
}

/// Rebuild the disposable FTS projection from an immutable provider receipt.
/// Failure is recorded in the main database and must never be reported as a
/// provider failure or cause another Soniox request.
pub(crate) fn project_transcribe_search_receipt(
    db_path: &Path,
    receipt: &AsyncProviderReceipt,
) -> Result<(), String> {
    project_transcribe_search_receipt_with(db_path, receipt, |_, _| Ok(()))
}

fn project_transcribe_search_receipt_with<P>(
    db_path: &Path,
    receipt: &AsyncProviderReceipt,
    preflight: P,
) -> Result<(), String>
where
    P: FnOnce(&str, &str) -> Result<(), String>,
{
    let capture_store = NotebookCaptureStore::new(db_path)
        .map_err(|error| format!("open capture store for search projection: {error}"))?;
    let receipt = capture_store
        .get_async_provider_receipt(&receipt.session_id, &receipt.task_id)
        .map_err(|error| format!("validate provider receipt before search projection: {error}"))?
        .ok_or_else(|| "provider receipt disappeared before search projection".to_string())?;
    let full_text = serde_json::from_str::<serde_json::Value>(&receipt.result_json)
        .map_err(|error| format!("decode provider receipt result: {error}"))?
        .get("full_text")
        .and_then(serde_json::Value::as_str)
        .ok_or_else(|| "provider receipt result has no full_text".to_string())?
        .to_string();
    let projection = preflight(&receipt.session_id, &full_text).and_then(|()| {
        SearchStore::new(db_path)
            .map_err(|error| format!("open search projection: {error}"))?
            .replace_session_from_async_receipt(
                &receipt.session_id,
                &receipt.task_id,
                &receipt.output_sha256,
                &full_text,
            )
            .map_err(|error| format!("atomically index transcript and publish Ready: {error}"))
    });
    if projection.is_err() {
        capture_store
            .mark_async_search_projection(&receipt.session_id, &receipt.task_id, false)
            .map_err(|error| format!("persist failed search projection state: {error}"))?;
    }
    projection
}

/// 内部辅助：用 Soniox 异步文件 API 转录 PCM 数据
///
/// - Some("en") = 提示 Soniox 语言
/// - None       = 让 Soniox 自动识别 (enable_language_identification)
///
/// 上传 → 转录 → 取回 → 删除远端文件与转录任务，全部在
/// `soniox_async::transcribe_wav` 内完成；取消与整体超时也在其内部处理，
/// 保证任何路径都先跑完远端清理再返回（Soniox 无自动 TTL）。
async fn run_soniox_transcription(
    api_key: &str,
    language: Option<&str>,
    context_json: Option<&str>,
    s16_pcm: Vec<u8>,
    cancel: CancellationToken,
    artifact_reference: &str,
    observer: Option<&dyn SonioxAsyncArtifactObserver>,
) -> Result<Vec<Token>, SonioxTranscriptionError> {
    if cancel.is_cancelled() {
        return Err(SonioxTranscriptionError::Cancelled);
    }

    let language_hints: Vec<String> = match language {
        Some(lang) if !lang.trim().is_empty() => vec![lang.to_string()],
        _ => Vec::new(),
    };
    // 没有 hint 时强制开启 language identification, 否则 Soniox 用 fallback en 解码非英文音频
    let enable_lang_id = language_hints.is_empty();

    let engine = CURRENT_NOTEBOOK_CAPTURE_ENGINE;
    let overall_deadline = soniox_async_task_timeout(s16_pcm.len());
    let wav_bytes = wrap_pcm_s16le_in_wav(&s16_pcm, engine.sample_rate, engine.channels as u16);
    drop(s16_pcm);
    let request = SonioxAsyncRequest {
        base_url: engine.async_api_base_url,
        api_key,
        model: engine.post_stop_model_id,
        language_hints,
        enable_language_identification: enable_lang_id,
        context_json,
        client_reference_id: Some(artifact_reference.to_string()),
        overall_deadline,
        poll_interval: SONIOX_ASYNC_POLL_INTERVAL,
    };

    match soniox_async_transcribe_wav(&request, wav_bytes, &cancel, observer).await {
        Ok(tokens) => Ok(tokens),
        Err(SttError::Cancelled) => Err(SonioxTranscriptionError::Cancelled),
        Err(error) => Err(SonioxTranscriptionError::Failed(safe_soniox_task_error(
            &error,
        ))),
    }
}

/// 内部辅助：去重 Soniox 累积式 interim token
///
/// Soniox 行为：每个 message 可能重发之前的 interim token（带更新的 text）。
/// 策略：按 (start_ms, translation_status) 分组,每组只保留最后一次。
///
/// Original 和 Translation token 可能有相同的 start_ms，因此去重键同时包含
/// translation_status，以保留两条结果。
fn dedupe_soniox_tokens(tokens: Vec<Token>) -> Vec<Token> {
    use vt_model::TranslationStatus;
    type Key = (u64, TranslationStatus);
    let mut by_key: HashMap<Key, Token> = HashMap::new();
    let mut order: Vec<Key> = Vec::new();

    for t in tokens {
        let k: Key = (t.start_ms, t.translation_status);
        if !by_key.contains_key(&k) {
            order.push(k);
        }
        // 总是用最新版本覆盖
        by_key.insert(k, t);
    }

    order
        .into_iter()
        .filter_map(|k| by_key.remove(&k))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{
        atomic::{AtomicBool, Ordering},
        Mutex,
    };
    use vt_crypto::{CryptoError, SessionKey};
    use vt_model::TranslationStatus;

    #[test]
    fn async_soniox_deadline_is_bounded_and_scales_with_audio_duration() {
        assert_eq!(
            soniox_async_task_timeout(0),
            SONIOX_ASYNC_TASK_BASE_ALLOWANCE
        );

        let ten_minutes_of_s16_mono = 16_000 * 2 * 10 * 60;
        let ten_minute_timeout = soniox_async_task_timeout(ten_minutes_of_s16_mono);
        assert_eq!(
            ten_minute_timeout,
            SONIOX_ASYNC_TASK_BASE_ALLOWANCE + Duration::from_secs(5 * 60),
            "deadline must cover the upload allowance plus half the audio duration"
        );

        // 5 小时（异步 API 单文件上限）也必须落在上限之内，不被过早判死。
        let five_hours_of_s16_mono = 16_000 * 2 * 5 * 60 * 60;
        let five_hour_timeout = soniox_async_task_timeout(five_hours_of_s16_mono);
        assert!(five_hour_timeout <= SONIOX_ASYNC_TASK_MAX_TIMEOUT);
        assert!(five_hour_timeout >= Duration::from_secs(60 * 60));

        assert_eq!(
            soniox_async_task_timeout(usize::MAX),
            SONIOX_ASYNC_TASK_MAX_TIMEOUT
        );
    }

    #[test]
    fn imported_48k_stereo_is_uploaded_as_16k_mono_with_source_duration() {
        let mut pcm_f32le = Vec::with_capacity(48_000 * 2 * 4);
        for frame in 0..48_000 {
            let phase = frame as f32 / 48_000.0;
            let left = phase;
            let right = phase * 0.5;
            pcm_f32le.extend_from_slice(&left.to_le_bytes());
            pcm_f32le.extend_from_slice(&right.to_le_bytes());
        }

        let prepared = prepare_soniox_audio(&pcm_f32le, 48_000, 2).unwrap();

        assert_eq!(prepared.duration_ms, 1_000);
        assert_eq!(prepared.s16le.len(), 16_000 * 2);
        let midpoint =
            i16::from_le_bytes([prepared.s16le[8_000 * 2], prepared.s16le[8_000 * 2 + 1]]);
        assert!(
            (midpoint as i32 - 12_288).abs() <= 2,
            "stereo downmix must be resampled instead of reinterpreted: {midpoint}"
        );
    }

    #[test]
    fn provider_preparation_rejects_partial_source_frames() {
        let error = prepare_soniox_audio(&[0; 4], 48_000, 2).unwrap_err();
        assert!(error.contains("not aligned"));
    }

    #[tokio::test]
    async fn whole_soniox_task_deadline_terminates_pending_work() {
        let result = within_soniox_whole_task_deadline(
            Duration::from_millis(10),
            std::future::pending::<()>(),
        )
        .await;
        assert!(result.is_none());
    }

    #[test]
    fn soniox_provider_error_is_redacted_at_durable_task_boundary() {
        const HOSTILE_REMOTE_MESSAGE: &str =
            "credential-shaped provider detail api_key=async-fixture-never-log";
        let error = safe_soniox_task_error(&SttError::AuthFailed {
            message: HOSTILE_REMOTE_MESSAGE.to_string(),
        });
        assert_eq!(error, "Soniox authentication failed");
        assert!(!error.contains(HOSTILE_REMOTE_MESSAGE));
        assert!(!error.contains("async-fixture-never-log"));

        let failed = safe_soniox_task_error(&SttError::TranscriptionFailed {
            error_type: "content_policy".to_string(),
            message: HOSTILE_REMOTE_MESSAGE.to_string(),
        });
        assert_eq!(failed, "Soniox transcription failed");
        assert!(!failed.contains(HOSTILE_REMOTE_MESSAGE));

        let closed = safe_soniox_task_error(&SttError::ServerClosed {
            code: 1008,
            reason: HOSTILE_REMOTE_MESSAGE.to_string(),
        });
        assert_eq!(closed, "Soniox closed the connection (status=1008)");
        assert!(!closed.contains(HOSTILE_REMOTE_MESSAGE));
    }

    #[tokio::test]
    async fn cancelled_soniox_transcription_returns_explicit_cancelled_error() {
        let cancel = CancellationToken::new();
        cancel.cancel();

        let result = run_soniox_transcription(
            "unused",
            None,
            None,
            Vec::new(),
            cancel,
            "zulangue-t1",
            None,
        )
        .await;
        assert!(matches!(result, Err(SonioxTranscriptionError::Cancelled)));
    }

    fn make_token(text: &str, start_ms: u64, end_ms: u64, is_final: bool) -> Token {
        Token {
            text: text.to_string(),
            start_ms,
            end_ms,
            is_final,
            language: "en".to_string(),
            speaker: None,
            confidence: 1.0,
            translation_status: TranslationStatus::None,
        }
    }

    #[test]
    fn test_dedupe_keeps_latest_version() {
        let tokens = vec![
            make_token("H", 0, 60, false),
            make_token("Hello", 0, 480, false),
            make_token(" world", 480, 960, false),
            make_token(" world.", 480, 1000, false), // updated
        ];
        let result = dedupe_soniox_tokens(tokens);
        assert_eq!(result.len(), 2);
        assert_eq!(result[0].text, "Hello"); // latest at start_ms=0
        assert_eq!(result[1].text, " world."); // latest at start_ms=480
    }

    #[test]
    fn test_dedupe_preserves_order() {
        let tokens = vec![
            make_token("a", 0, 100, true),
            make_token("b", 100, 200, true),
            make_token("c", 200, 300, true),
        ];
        let result = dedupe_soniox_tokens(tokens);
        assert_eq!(result.len(), 3);
        assert_eq!(result[0].text, "a");
        assert_eq!(result[1].text, "b");
        assert_eq!(result[2].text, "c");
    }

    #[test]
    fn test_dedupe_empty() {
        let result = dedupe_soniox_tokens(vec![]);
        assert!(result.is_empty());
    }

    /// 翻译模式下 Original 和 Translation token 可能共享 start_ms；去重必须
    /// 使用 (start_ms, translation_status)。
    #[test]
    fn test_dedupe_keeps_original_and_translation_with_same_start_ms() {
        let mut original = make_token("Hello", 0, 500, true);
        original.translation_status = TranslationStatus::Original;
        original.language = "en".to_string();
        let mut translation = make_token("你好", 0, 500, true);
        translation.translation_status = TranslationStatus::Translation;
        translation.language = "zh".to_string();

        let result = dedupe_soniox_tokens(vec![original, translation]);
        assert_eq!(result.len(), 2, "both must survive");
        let texts: Vec<&str> = result.iter().map(|t| t.text.as_str()).collect();
        assert!(texts.contains(&"Hello"));
        assert!(texts.contains(&"你好"));
    }

    #[derive(Default)]
    struct RecordingTaskCallback {
        progress: Mutex<Vec<String>>,
        complete: Mutex<Vec<String>>,
        errors: Mutex<Vec<String>>,
    }

    impl RecordingTaskCallback {
        fn progress_stages(&self) -> Vec<String> {
            self.progress.lock().unwrap().clone()
        }

        fn complete_count(&self) -> usize {
            self.complete.lock().unwrap().len()
        }
    }

    impl FfiTaskCallback for RecordingTaskCallback {
        fn on_progress(&self, _: String, stage: String, _: f32) {
            self.progress.lock().unwrap().push(stage);
        }

        fn on_complete(&self, task_id: String, _: String) {
            self.complete.lock().unwrap().push(task_id);
        }

        fn on_error(&self, task_id: String, code: String, message: String) {
            self.errors
                .lock()
                .unwrap()
                .push(format!("{task_id}:{code}:{message}"));
        }
    }

    fn provider_output_fixture() -> (tempfile::TempDir, std::path::PathBuf, NotebookCaptureStore) {
        let temp = tempfile::tempdir().unwrap();
        let db = temp.path().join("zulangue.db");
        let notebook = vt_store::NotebookStore::new(&db)
            .unwrap()
            .create_notebook(Some("Provider receipt"))
            .unwrap();
        let store = NotebookCaptureStore::new(&db).unwrap();
        let profile = store.get_or_create_profile(&notebook.id).unwrap();
        let profile = store
            .update_profile(
                &notebook.id,
                profile.revision,
                &vt_store::NotebookCaptureProfileUpdate {
                    remote_realtime_enabled: false,
                    capture_mode: vt_store::CaptureMode::TranscriptionOnly,
                    language_a: "en".into(),
                    language_b: "zh".into(),
                    left_language: "en".into(),
                    right_language: "zh".into(),
                    selected_languages: vec!["en".into(), "zh".into()],
                    common_caption_language: None,
                    privacy_level: "standard".into(),
                    send_context_to_soniox: false,
                },
            )
            .unwrap();
        store
            .create_run(
                &vt_store::NewNotebookCaptureRun {
                    id: "provider-run".into(),
                    notebook_id: notebook.id,
                    session_id: "provider-session".into(),
                    remote_health: vt_store::RemoteHealth::Off,
                    audio_journal_path: temp
                        .path()
                        .join("provider.capture-journal.enc")
                        .to_string_lossy()
                        .into_owned(),
                    audio_key_ref: "provider-key".into(),
                    sample_rate: 16_000,
                    channels: 1,
                },
                &profile,
            )
            .unwrap();
        store
            .transition_capture(
                "provider-run",
                vt_store::CaptureState::Recording,
                vt_store::CaptureState::Draining,
            )
            .unwrap();
        store
            .finalize_audio(
                "provider-run",
                &temp
                    .path()
                    .join("provider.chunk.00000.enc")
                    .to_string_lossy(),
                16_000,
            )
            .unwrap();
        store
            .transition_capture(
                "provider-run",
                vt_store::CaptureState::Draining,
                vt_store::CaptureState::Completed,
            )
            .unwrap();
        store
            .authorize_async_transcription("provider-session", 1_700_000_000_000, Some("en"))
            .unwrap();
        store
            .claim_provider_provenance(
                "provider-session",
                vt_store::notebook_capture_store::CaptureProviderRole::PostStop,
                CURRENT_NOTEBOOK_CAPTURE_ENGINE.provider_id,
                CURRENT_NOTEBOOK_CAPTURE_ENGINE.post_stop_model_id,
            )
            .unwrap();
        store
            .reserve_async_task("provider-run", "provider-task", &"a".repeat(64))
            .unwrap();
        store
            .mark_async_task_enqueued("provider-run", "provider-task")
            .unwrap();
        SessionMetaStore::new(&db)
            .unwrap()
            .set_privacy_level("provider-session", "standard")
            .unwrap();
        (temp, db, store)
    }

    #[derive(Debug, Clone, Copy)]
    enum ProjectionReceiptTamper {
        Digest,
        Result,
        Tokens,
        ProviderModel,
    }

    fn tamper_provider_output_for_projection(db: &Path, tamper: ProjectionReceiptTamper) {
        let conn = rusqlite::Connection::open(db).unwrap();
        let suspend_trigger = |name: &str| -> String {
            let sql = conn
                .query_row(
                    "SELECT sql FROM sqlite_schema WHERE type = 'trigger' AND name = ?1",
                    [name],
                    |row| row.get(0),
                )
                .unwrap();
            conn.execute_batch(&format!("DROP TRIGGER {name};"))
                .unwrap();
            sql
        };
        match tamper {
            ProjectionReceiptTamper::Digest => {
                let trigger = suspend_trigger("notebook_capture_runs_provider_receipt_immutable");
                conn.execute(
                    "UPDATE notebook_capture_runs
                     SET async_provider_output_sha256 = ?1
                     WHERE session_id = 'provider-session'",
                    ["0".repeat(64)],
                )
                .unwrap();
                conn.execute_batch(&trigger).unwrap();
            }
            ProjectionReceiptTamper::Result => {
                let trigger = suspend_trigger("notebook_capture_runs_provider_receipt_immutable");
                conn.execute(
                    "UPDATE notebook_capture_runs
                     SET async_provider_result_json = '{\"session_id\":\"wrong\"}'
                     WHERE session_id = 'provider-session'",
                    [],
                )
                .unwrap();
                conn.execute_batch(&trigger).unwrap();
            }
            ProjectionReceiptTamper::Tokens => {
                let trigger = suspend_trigger("session_meta_provider_tokens_immutable");
                conn.execute(
                    "UPDATE session_meta SET tokens_json = '[]'
                     WHERE session_id = 'provider-session'",
                    [],
                )
                .unwrap();
                conn.execute_batch(&trigger).unwrap();
            }
            ProjectionReceiptTamper::ProviderModel => {
                let trigger =
                    suspend_trigger("notebook_capture_runs_post_stop_provenance_immutable");
                conn.execute_batch("PRAGMA ignore_check_constraints = ON;")
                    .unwrap();
                conn.execute(
                    "UPDATE notebook_capture_runs SET post_stop_model_id = 'tampered-model'
                     WHERE session_id = 'provider-session'",
                    [],
                )
                .unwrap();
                conn.execute_batch(&trigger).unwrap();
            }
        }
    }

    struct FailingDeleteKeyStore;

    impl KeyProvider for FailingDeleteKeyStore {
        fn create_session_key(&self, _: &uuid::Uuid) -> Result<String, CryptoError> {
            Ok("key-1".to_string())
        }

        fn load_key(&self, _: &str) -> Result<SessionKey, CryptoError> {
            Ok(SessionKey::generate())
        }

        fn delete_key(&self, key_ref: &str) -> Result<(), CryptoError> {
            Err(CryptoError::SecretStoreAccess {
                message: format!("delete denied for {key_ref}"),
            })
        }

        fn key_exists(&self, _: &str) -> bool {
            true
        }

        fn store_key(&self, _: &str, _: &SessionKey) -> Result<(), CryptoError> {
            Ok(())
        }
    }

    #[test]
    fn provider_receipt_failure_never_writes_authoritative_tokens() {
        let (_temp, db, store) = provider_output_fixture();
        store
            .mark_async_task_terminal_for_session("provider-session", "provider-task", true)
            .unwrap();
        let result_json = transcribe_result_json("provider-session", "hello", 1, 100);
        let error = persist_transcribe_task_output(
            &db,
            "provider-task",
            "provider-session",
            &[make_token("hello", 0, 100, true)],
            &result_json,
        )
        .unwrap_err();

        assert!(error.1.contains("commit provider transcript receipt"));
        assert!(store
            .get_async_provider_receipt("provider-session", "provider-task")
            .unwrap()
            .is_none());
        assert!(SessionMetaStore::new(&db)
            .unwrap()
            .get_meta("provider-session")
            .unwrap()
            .tokens_json
            .is_none());
    }

    #[test]
    fn search_projection_failure_keeps_provider_receipt_and_is_locally_retryable() {
        let (_temp, db, store) = provider_output_fixture();
        let callback = RecordingTaskCallback::default();
        let json = finish_transcribe_task_output_with_projection(
            "provider-task",
            "provider-session",
            &[make_token("hello", 0, 100, true)],
            "hello",
            1,
            100,
            &db,
            &callback,
            |receipt| {
                project_transcribe_search_receipt_with(&db, receipt, |_, _| {
                    Err("forced local FTS failure".into())
                })
            },
        )
        .expect("a local FTS failure must not fail provider success");
        assert!(json.contains("\"full_text\":\"hello\""));
        let failed = store
            .get_async_provider_receipt("provider-session", "provider-task")
            .unwrap()
            .unwrap();
        assert_eq!(
            failed.search_projection_state,
            vt_store::AsyncSearchProjectionState::Failed
        );
        assert!(SessionMetaStore::new(&db)
            .unwrap()
            .get_meta("provider-session")
            .unwrap()
            .tokens_json
            .is_some());

        project_transcribe_search_receipt(&db, &failed).unwrap();
        let ready = store
            .get_async_provider_receipt("provider-session", "provider-task")
            .unwrap()
            .unwrap();
        assert_eq!(
            ready.search_projection_state,
            vt_store::AsyncSearchProjectionState::Ready
        );
        assert_eq!(
            SearchStore::new(&db)
                .unwrap()
                .search("hello", 10)
                .unwrap()
                .len(),
            1
        );
    }

    #[test]
    fn async_fts_replace_and_ready_publish_roll_back_together() {
        let (_temp, db, store) = provider_output_fixture();
        let result_json = transcribe_result_json("provider-session", "async authority", 1, 100);
        let receipt = store
            .commit_async_provider_success(
                "provider-session",
                "provider-task",
                &[make_token("async authority", 0, 100, true)],
                &result_json,
            )
            .unwrap();
        let search = SearchStore::new(&db).unwrap();
        search
            .index_session("provider-session", "old realtime content")
            .unwrap();
        assert!(
            store
                .mark_async_search_projection("provider-session", "provider-task", true)
                .is_err(),
            "Ready must not be publishable without the atomic FTS API"
        );

        let conn = rusqlite::Connection::open(&db).unwrap();
        conn.execute_batch(
            "CREATE TRIGGER fail_atomic_async_ready
             BEFORE UPDATE OF async_search_projection_state ON notebook_capture_runs
             WHEN NEW.async_search_projection_state = 'ready'
             BEGIN
                 SELECT RAISE(FAIL, 'injected Ready failure');
             END;",
        )
        .unwrap();
        let error = search
            .replace_session_from_async_receipt(
                &receipt.session_id,
                &receipt.task_id,
                &receipt.output_sha256,
                "async authority",
            )
            .unwrap_err()
            .to_string();
        assert!(
            error.contains("injected Ready failure"),
            "unexpected atomic projection error: {error}"
        );
        assert_eq!(search.search("old", 10).unwrap().len(), 1);
        assert!(
            search.search("authority", 10).unwrap().is_empty(),
            "the FTS replacement must roll back when Ready cannot commit"
        );
        assert_ne!(
            store
                .get_async_provider_receipt("provider-session", "provider-task")
                .unwrap()
                .unwrap()
                .search_projection_state,
            vt_store::AsyncSearchProjectionState::Ready
        );

        conn.execute_batch("DROP TRIGGER fail_atomic_async_ready;")
            .unwrap();
        project_transcribe_search_receipt(&db, &receipt).unwrap();
        assert_eq!(search.search("authority", 10).unwrap().len(), 1);
        assert!(search.search("old", 10).unwrap().is_empty());
    }

    #[test]
    fn async_and_realtime_fts_serial_orders_both_converge_to_async_content() {
        for realtime_first in [true, false] {
            let (_temp, db, store) = provider_output_fixture();
            let result_json = transcribe_result_json("provider-session", "async authority", 1, 100);
            let receipt = store
                .commit_async_provider_success(
                    "provider-session",
                    "provider-task",
                    &[make_token("async authority", 0, 100, true)],
                    &result_json,
                )
                .unwrap();
            let search = SearchStore::new(&db).unwrap();
            if realtime_first {
                search
                    .replace_session_from_realtime_unless_async_ready(
                        "provider-session",
                        "realtime draft",
                    )
                    .unwrap();
                project_transcribe_search_receipt(&db, &receipt).unwrap();
            } else {
                project_transcribe_search_receipt(&db, &receipt).unwrap();
                assert_eq!(
                    search
                        .replace_session_from_realtime_unless_async_ready(
                            "provider-session",
                            "realtime draft",
                        )
                        .unwrap(),
                    vt_store::RealtimeSearchProjectionOutcome::SkippedAsyncReady
                );
            }
            assert_eq!(search.search("authority", 10).unwrap().len(), 1);
            assert!(search.search("draft", 10).unwrap().is_empty());
            assert_eq!(
                store
                    .get_async_provider_receipt("provider-session", "provider-task")
                    .unwrap()
                    .unwrap()
                    .search_projection_state,
                vt_store::AsyncSearchProjectionState::Ready
            );
        }
    }

    #[test]
    fn corrupt_provider_receipts_never_reach_fts_projection() {
        for tamper in [
            ProjectionReceiptTamper::Digest,
            ProjectionReceiptTamper::Result,
            ProjectionReceiptTamper::Tokens,
            ProjectionReceiptTamper::ProviderModel,
        ] {
            let (_temp, db, store) = provider_output_fixture();
            let result_json = transcribe_result_json("provider-session", "hello", 1, 100);
            let stale_receipt = store
                .commit_async_provider_success(
                    "provider-session",
                    "provider-task",
                    &[make_token("hello", 0, 100, true)],
                    &result_json,
                )
                .unwrap();
            tamper_provider_output_for_projection(&db, tamper);

            let indexed = AtomicBool::new(false);
            let error = project_transcribe_search_receipt_with(&db, &stale_receipt, |_, _| {
                indexed.store(true, Ordering::SeqCst);
                Ok(())
            })
            .unwrap_err();

            assert!(!indexed.load(Ordering::SeqCst), "{tamper:?} reached FTS");
            assert!(
                error.contains("validate provider receipt"),
                "{tamper:?} returned an inaccurate error: {error}"
            );
            let state: String = rusqlite::Connection::open(&db)
                .unwrap()
                .query_row(
                    "SELECT async_search_projection_state
                     FROM notebook_capture_runs WHERE session_id = 'provider-session'",
                    [],
                    |row| row.get(0),
                )
                .unwrap();
            assert_eq!(state, "pending", "{tamper:?} mutated projection state");
        }
    }

    #[test]
    fn test_enforce_privacy_after_task_returns_err_when_key_delete_fails() {
        let tmp = tempfile::TempDir::new().unwrap();
        let db = tmp.path().join("zulangue.db");
        let session_meta = SessionMetaStore::new(&db).unwrap();
        session_meta
            .set_encrypted_path("s1", tmp.path().join("s1.enc").to_str().unwrap(), "key-1")
            .unwrap();
        session_meta.set_privacy_level("s1", "maximum").unwrap();

        let err = enforce_privacy_after_task("s1", &db, &FailingDeleteKeyStore).unwrap_err();

        assert!(
            err.contains("delete key"),
            "maximum privacy must surface key deletion failure, got: {err}"
        );
    }

    #[test]
    fn test_enforce_privacy_after_task_returns_err_when_meta_missing() {
        let tmp = tempfile::TempDir::new().unwrap();
        let db = tmp.path().join("zulangue.db");
        let _session_meta = SessionMetaStore::new(&db).unwrap();
        let key_store = vt_crypto::MemoryKeyStore::new();

        let err = enforce_privacy_after_task("missing-session", &db, &key_store).unwrap_err();

        assert!(
            err.contains("session meta not found"),
            "missing privacy metadata must block terminal success, got: {err}"
        );
    }

    #[test]
    fn test_enforce_privacy_after_task_rejects_missing_or_invalid_level() {
        let tmp = tempfile::TempDir::new().unwrap();
        let db = tmp.path().join("zulangue.db");
        let session_meta = SessionMetaStore::new(&db).unwrap();
        let sessions = vt_store::SessionQueryStore::new(&db).unwrap();
        for id in ["missing-level", "invalid-level"] {
            sessions
                .insert_session(&vt_store::SessionRecord {
                    id: id.to_string(),
                    title: String::new(),
                    session_type: "recording".to_string(),
                    status: "completed".to_string(),
                    duration_ms: 0,
                    created_at: "2001-01-01 00:00:00".to_string(),
                    deleted_at: None,
                })
                .unwrap();
        }
        session_meta
            .set_encrypted_path("missing-level", "audio.enc", "key")
            .unwrap();
        session_meta
            .set_privacy_level("invalid-level", "unexpected")
            .unwrap();
        let key_store = vt_crypto::MemoryKeyStore::new();

        for id in ["missing-level", "invalid-level"] {
            let error = enforce_privacy_after_task(id, &db, &key_store).unwrap_err();
            assert!(error.contains("privacy_state_invalid"));
        }
    }

    #[test]
    fn test_enforce_privacy_after_task_deletes_retention_chunks() {
        let tmp = tempfile::TempDir::new().unwrap();
        let db = tmp.path().join("zulangue.db");
        let chunk_path = tmp.path().join("chunk-000.enc");
        std::fs::write(&chunk_path, b"encrypted chunk").unwrap();

        let session_meta = SessionMetaStore::new(&db).unwrap();
        session_meta.set_privacy_level("s1", "high").unwrap();
        session_meta
            .upsert_audio_retention_chunk(&vt_store::AudioChunkRetentionRecord {
                session_id: "s1".to_string(),
                chunk_id: "s1:audio:00000".to_string(),
                start_ms: 0,
                end_ms: 1_000,
                local_path: chunk_path.to_str().unwrap().to_string(),
                encrypted: true,
                deleted: false,
                retention_deadline_ms: 0,
                delete_error: None,
                deleted_at_ms: None,
            })
            .unwrap();
        let key_store = vt_crypto::MemoryKeyStore::new();

        enforce_privacy_after_task("s1", &db, &key_store).unwrap();

        assert!(
            !chunk_path.exists(),
            "high privacy must delete retained audio chunks"
        );
        let chunks = session_meta.list_audio_retention_chunks("s1").unwrap();
        assert_eq!(chunks.len(), 1);
        assert!(
            chunks[0].deleted,
            "retention ledger must mark chunk deleted"
        );
    }

    #[test]
    fn finish_does_not_advance_when_provider_receipt_commit_fails() {
        let (_temp, db, store) = provider_output_fixture();
        store
            .mark_async_task_terminal_for_session("provider-session", "provider-task", true)
            .unwrap();
        let callback = RecordingTaskCallback::default();
        let error = finish_transcribe_task_output(
            "provider-task",
            "provider-session",
            &[make_token("hello", 0, 100, true)],
            "hello",
            1,
            100,
            &db,
            &callback,
        )
        .unwrap_err();

        assert!(error.1.contains("commit provider transcript receipt"));
        assert!(
            !callback
                .progress_stages()
                .contains(&"finalizing".to_string()),
            "finalization must wait until provider output and tokens commit atomically"
        );
        assert_eq!(callback.complete_count(), 0);
    }

    #[test]
    fn finish_advances_after_retryable_search_projection_failure() {
        let (_temp, db, _store) = provider_output_fixture();
        let callback = RecordingTaskCallback::default();
        let json = finish_transcribe_task_output_with_projection(
            "provider-task",
            "provider-session",
            &[make_token("hello", 0, 100, true)],
            "hello",
            1,
            100,
            &db,
            &callback,
            |receipt| {
                project_transcribe_search_receipt_with(&db, receipt, |_, _| {
                    Err("forced local FTS failure".into())
                })
            },
        )
        .unwrap();

        assert!(json.contains("\"full_text\":\"hello\""));
        assert!(
            callback
                .progress_stages()
                .contains(&"finalizing".to_string()),
            "provider success must advance independently of local FTS"
        );
        assert_eq!(callback.complete_count(), 0);
    }

    #[test]
    fn test_finish_transcribe_task_output_waits_for_terminal_cleanup_before_complete_progress() {
        let (_temp, db, _store) = provider_output_fixture();

        let callback = RecordingTaskCallback::default();
        let json = finish_transcribe_task_output(
            "provider-task",
            "provider-session",
            &[make_token("hello", 0, 100, true)],
            "hello",
            1,
            100,
            &db,
            &callback,
        )
        .unwrap();

        assert!(json.contains("\"session_id\":\"provider-session\""));
        let stages = callback.progress_stages();
        assert!(
            stages.contains(&"finalizing".to_string()),
            "transcribe task should report finalization after output persistence, got: {stages:?}"
        );
        assert!(
            !stages.contains(&"complete".to_string()),
            "complete progress must wait until privacy cleanup and task completion"
        );
    }

    // 异步任务完成后执行与同步路径一致的隐私 enforcement。

    use tempfile::TempDir;
    use vt_crypto::MemoryKeyStore;

    fn setup_session_with_enc(
        level: &str,
    ) -> (
        TempDir,
        std::path::PathBuf,
        std::path::PathBuf,
        String,
        String,
        Arc<dyn KeyProvider>,
    ) {
        let tmp = TempDir::new().unwrap();
        let db = tmp.path().join("zulangue.db");
        let enc = tmp.path().join("session.enc");

        // 写一个假的 .enc 文件（内容不重要，enforce 只看存在）
        std::fs::write(&enc, b"fake encrypted data").unwrap();

        // 初始化 SessionMetaStore + 写元数据
        let session_meta = SessionMetaStore::new(&db).unwrap();
        let sid = "test-session";
        session_meta
            .set_encrypted_path(sid, enc.to_str().unwrap(), "key-1")
            .unwrap();
        session_meta.set_privacy_level(sid, level).unwrap();

        // 创建一个 KeyProvider 并存 key-1
        let key_store: Arc<dyn KeyProvider> = Arc::new(MemoryKeyStore::new());
        let session_uuid = uuid::Uuid::new_v4();
        let key_ref = key_store.create_session_key(&session_uuid).unwrap();
        let _ = session_meta.set_encrypted_path(sid, enc.to_str().unwrap(), &key_ref);
        session_meta
            .upsert_audio_retention_chunk(&vt_store::AudioChunkRetentionRecord {
                session_id: sid.to_string(),
                chunk_id: format!("{sid}:audio:00000"),
                start_ms: 0,
                end_ms: 1,
                local_path: enc.to_string_lossy().to_string(),
                encrypted: true,
                deleted: false,
                retention_deadline_ms: i64::MAX,
                delete_error: None,
                deleted_at_ms: None,
            })
            .unwrap();

        (tmp, db, enc, sid.to_string(), key_ref, key_store)
    }

    #[test]
    fn test_enforce_privacy_standard_keeps_everything() {
        let (_tmp, db, enc, sid, _key_ref, key_store) = setup_session_with_enc("standard");
        enforce_privacy_after_task(&sid, &db, key_store.as_ref()).unwrap();
        // standard → 文件应该保留
        assert!(enc.exists(), "standard should preserve enc");
    }

    #[test]
    fn test_enforce_privacy_high_removes_enc() {
        let (_tmp, db, enc, sid, key_ref, key_store) = setup_session_with_enc("high");
        assert!(enc.exists());
        // Ciphertext and its key are one retention unit.
        assert!(key_store.key_exists(&key_ref));

        enforce_privacy_after_task(&sid, &db, key_store.as_ref()).unwrap();

        assert!(!enc.exists(), "high level must delete enc");
        assert!(
            !key_store.key_exists(&key_ref),
            "high must not retain an orphan encryption key"
        );
    }

    #[test]
    fn test_enforce_privacy_maximum_removes_enc_and_key() {
        let (_tmp, db, enc, sid, key_ref, key_store) = setup_session_with_enc("maximum");
        assert!(enc.exists());
        assert!(key_store.key_exists(&key_ref));

        enforce_privacy_after_task(&sid, &db, key_store.as_ref()).unwrap();

        assert!(!enc.exists(), "maximum must delete enc");
        assert!(
            !key_store.key_exists(&key_ref),
            "maximum must delete key from KeyStore"
        );
    }

    #[test]
    fn test_enforce_privacy_clears_meta_path() {
        let (_tmp, db, _enc, sid, _key_ref, key_store) = setup_session_with_enc("high");
        enforce_privacy_after_task(&sid, &db, key_store.as_ref()).unwrap();

        // 重新打开 SessionMetaStore 验证 encrypted_path 已被清空
        let session_meta = SessionMetaStore::new(&db).unwrap();
        let meta = session_meta.get_meta(&sid).unwrap();
        assert!(meta.encrypted_path.is_none());
    }

    #[test]
    fn test_enforce_privacy_missing_session_is_err_for_async_terminal_path() {
        let tmp = TempDir::new().unwrap();
        let db = tmp.path().join("zulangue.db");
        let _ = SessionMetaStore::new(&db).unwrap(); // 创建空 db
        let key_store: Arc<dyn KeyProvider> = Arc::new(MemoryKeyStore::new());

        let err = enforce_privacy_after_task("nonexistent", &db, key_store.as_ref()).unwrap_err();
        assert!(
            err.contains("session meta not found"),
            "async terminal privacy enforcement must fail closed, got: {err}"
        );
    }
}
