//! Single-owner Notebook capture FFI.
//!
//! Rust owns capture state, encrypted audio durability, ordered Soniox v5
//! aggregation, and the final Loro projection. Swift supplies one microphone
//! stream and renders callbacks; it never owns a second capture state machine.

use std::io::Read;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex as StdMutex};

use sha2::{Digest, Sha256};
use vt_crypto::SessionKey;
use vt_pipeline::{
    CaptureAudioJournal, RecordingConfig, RecordingResult, RemoteTaskAuthorization, TaskPayload,
    TaskPriority,
};
use vt_store::notebook_capture_store::{
    canonical_language, capture_mode_for_selection, legacy_capture_language_pair,
    AsyncProjectionState, AsyncTaskState, CaptureMode, CaptureProviderRole, CaptureState,
    NewRealtimeUtterance, NotebookCaptureHistoryRun, NotebookCaptureProfile,
    NotebookCaptureProfileUpdate, NotebookCaptureRun, NotebookCaptureStore,
    NotebookProjectionMutation, ProjectionState, ProviderFailure, RealtimeUtterance, RemoteHealth,
    SessionPurgeJob, SessionPurgePlan, UtteranceAlignment, UtteranceCompletion, UtteranceLane,
    UtteranceVariantRole, UtteranceVariantState,
};
use vt_store::{
    ContextCompilation, ContextContentKind, ContextOmissionReason, ContextPackRecord,
    ContextPackScope, ContextPackSourceRecord, ContextPackStore, ContextReceipt,
    ContextSourceFormat, NewContextSource,
};
use vt_stt::{
    soniox_stream_context_json, ContextConfig, SonioxStreamClient, SonioxStreamRuntime, SttConfig,
    SttStreamControl, SttStreamError, SttStreamEvent, SttStreamToken, SttStreamTranslationStatus,
    TranslationConfig, CURRENT_NOTEBOOK_CAPTURE_ENGINE,
};

use crate::task_worker::{
    reconcile_capture_async_task_receipt_on_startup, StartupCaptureAsyncReceiptOutcome,
};
use crate::{CoreError, ZulangueCore};

const CONTEXT_TEXT_FILE_MAX_BYTES: u64 = 256 * 1024;
// 1,000 rows × two 256-scalar cells at four UTF-8 bytes/scalar, plus CSV
// delimiters and headers. The semantic row/cell limits remain authoritative.
const CONTEXT_CSV_FILE_MAX_BYTES: u64 = 2 * 1024 * 1024 + 16 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FfiNotebookCaptureMode {
    TranscriptionOnly,
    TwoWay,
    MultilingualOneWay,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FfiNotebookCaptureState {
    Recording,
    Paused,
    Draining,
    Completed,
    Interrupted,
    Failed,
}

/// Controlled local-only interruption reasons. Using a UniFFI enum prevents
/// arbitrary UI text, filenames, or other sensitive diagnostics from entering
/// the durable provider-error field.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FfiNotebookCaptureInterruptReason {
    LocalAudioOverflow,
    LocalAudioUnavailable,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FfiNotebookRemoteHealth {
    Off,
    Connecting,
    Live,
    Degraded,
    Unavailable,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FfiNotebookProjectionState {
    Pending,
    Projecting,
    Ready,
    Failed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FfiNotebookAsyncProjectionState {
    None,
    Pending,
    Projecting,
    Ready,
    Failed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FfiNotebookPostStopExecution {
    RealtimeRestream,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiNotebookCaptureEngineDescriptor {
    pub provider_id: String,
    pub provider_display_name: String,
    pub realtime_model_id: String,
    pub post_stop_model_id: String,
    pub supports_realtime_transcription: bool,
    pub supports_two_way_translation: bool,
    pub supports_context: bool,
    pub supports_post_stop_transcription: bool,
    pub post_stop_execution: FfiNotebookPostStopExecution,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiNotebookCaptureProfile {
    pub notebook_id: String,
    pub remote_realtime_enabled: bool,
    pub mode: FfiNotebookCaptureMode,
    pub language_a: String,
    pub language_b: String,
    pub left_language: String,
    pub right_language: String,
    pub selected_languages: Vec<String>,
    pub common_caption_language: Option<String>,
    pub privacy_level: String,
    pub send_context_to_soniox: bool,
    pub revision: u64,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiNotebookCaptureContextSource {
    pub id: String,
    pub title: String,
    pub pack_kind: String,
    pub scalar_count: u64,
    pub included: bool,
    pub reason: Option<String>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiNotebookCaptureContextPreview {
    pub notebook_id: String,
    /// Exact JSON that will be supplied as Soniox `context` after confirmation.
    pub serialized_context: String,
    pub sources: Vec<FfiNotebookCaptureContextSource>,
    pub omitted_reasons: Vec<String>,
    pub digest: String,
    pub scalar_count: u64,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiContextPackInfo {
    pub id: String,
    pub scope: String,
    pub owner_notebook_id: Option<String>,
    pub title: String,
    pub revision: u64,
    pub bound_position: Option<u64>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiContextPackSourceInfo {
    pub id: String,
    pub pack_id: String,
    pub title: String,
    pub format: String,
    pub content_kind: String,
    pub plaintext_sha256: String,
    pub plaintext_bytes: u64,
    pub trusted: bool,
    pub revision: u64,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct FfiNotebookCaptureContextReceipt {
    pub digest: String,
    pub applied: bool,
    pub provider: String,
    pub model: String,
    pub applied_at: String,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiNotebookCaptureLanguageVariant {
    pub language: String,
    pub role: String,
    pub text: Option<String>,
    pub state: String,
    pub completion: Option<String>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiNotebookCaptureUtterance {
    pub id: String,
    pub session_id: String,
    pub sequence: u64,
    pub revision: u64,
    pub session_speaker_id: Option<String>,
    pub source_language: String,
    pub source_text: String,
    pub source_start_ms: Option<u64>,
    pub source_end_ms: Option<u64>,
    pub translated_language: Option<String>,
    pub translated_text: Option<String>,
    pub completion: String,
    pub alignment: String,
    pub language_variants: Vec<FfiNotebookCaptureLanguageVariant>,
}

/// One immutable recording block in a Notebook's chronological transcript.
///
/// The record intentionally exposes only `has_audio`; encrypted paths, journal
/// paths, key references, and task receipts never cross the FFI boundary.
#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiNotebookCaptureHistoryRun {
    pub run_id: String,
    pub notebook_id: String,
    pub session_id: String,
    pub profile_revision: u64,
    pub created_at: String,
    pub updated_at: String,
    pub completed_at: Option<String>,
    pub capture_state: FfiNotebookCaptureState,
    pub remote_health: FfiNotebookRemoteHealth,
    pub projection_state: FfiNotebookProjectionState,
    pub mode: Option<FfiNotebookCaptureMode>,
    pub language_a: Option<String>,
    pub language_b: Option<String>,
    pub left_language: Option<String>,
    pub right_language: Option<String>,
    pub selected_languages: Vec<String>,
    pub common_caption_language: Option<String>,
    pub privacy_level: Option<String>,
    pub post_stop_async_state: String,
    pub post_stop_async_projection_state: FfiNotebookAsyncProjectionState,
    pub realtime_provider_id: Option<String>,
    pub realtime_model_id: Option<String>,
    pub post_stop_provider_id: Option<String>,
    pub post_stop_model_id: Option<String>,
    pub provider_error_type: Option<String>,
    pub provider_request_id: Option<String>,
    pub sample_rate: Option<u32>,
    pub channels: Option<u16>,
    pub captured_frames: u64,
    pub has_audio: bool,
    pub utterances: Vec<FfiNotebookCaptureUtterance>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiNotebookCaptureEvent {
    pub session_id: String,
    /// Monotonic within one capture callback subscription. A gap means the
    /// callback mailbox coalesced one or more intermediate deltas, so clients
    /// must rebuild utterances once through `list_notebook_capture_utterances`.
    pub event_revision: u64,
    /// When true, `utterances` replaces the client's session view. Otherwise
    /// it contains only utterances changed by this event and is applied by
    /// `(session_id, sequence)` upsert.
    pub is_full_snapshot: bool,
    pub capture_state: FfiNotebookCaptureState,
    pub remote_health: FfiNotebookRemoteHealth,
    pub projection_state: FfiNotebookProjectionState,
    /// Immutable per-run display configuration. `None` means the durable
    /// profile snapshot is corrupt; clients must show an error instead of
    /// guessing en/zh or reading the Notebook's newer profile.
    pub mode: Option<FfiNotebookCaptureMode>,
    pub language_a: Option<String>,
    pub language_b: Option<String>,
    pub left_language: Option<String>,
    pub right_language: Option<String>,
    pub selected_languages: Vec<String>,
    pub common_caption_language: Option<String>,
    pub privacy_level: Option<String>,
    pub post_stop_async_state: String,
    pub post_stop_async_projection_state: FfiNotebookAsyncProjectionState,
    /// Immutable provider/model truth claimed before each remote role begins.
    /// These fields are absent for a local-only run or a role that never crossed
    /// its durable provider boundary.
    pub realtime_provider_id: Option<String>,
    pub realtime_model_id: Option<String>,
    pub post_stop_provider_id: Option<String>,
    pub post_stop_model_id: Option<String>,
    pub utterances: Vec<FfiNotebookCaptureUtterance>,
    pub context_receipt: Option<FfiNotebookCaptureContextReceipt>,
    pub provider_error_type: Option<String>,
    pub provider_request_id: Option<String>,
}

/// Process-local, replace-in-full presentation state for the current Soniox
/// speculative tail. These utterances are never persisted and never advance
/// the durable capture-event revision.
#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiNotebookCaptureLivePreview {
    pub session_id: String,
    /// Monotonic only within the transient preview channel. A skipped revision
    /// is harmless because every callback carries the complete current tail.
    pub preview_revision: u64,
    pub utterances: Vec<FfiNotebookCaptureUtterance>,
}

#[uniffi::export(callback_interface)]
pub trait FfiNotebookCaptureCallback: Send + Sync {
    fn on_capture_event(&self, event: FfiNotebookCaptureEvent);
    fn on_live_preview(&self, preview: FfiNotebookCaptureLivePreview);
}

impl From<CaptureMode> for FfiNotebookCaptureMode {
    fn from(value: CaptureMode) -> Self {
        match value {
            CaptureMode::TranscriptionOnly => Self::TranscriptionOnly,
            CaptureMode::TwoWay => Self::TwoWay,
            CaptureMode::MultilingualOneWay => Self::MultilingualOneWay,
        }
    }
}

impl From<FfiNotebookCaptureMode> for CaptureMode {
    fn from(value: FfiNotebookCaptureMode) -> Self {
        match value {
            FfiNotebookCaptureMode::TranscriptionOnly => Self::TranscriptionOnly,
            FfiNotebookCaptureMode::TwoWay => Self::TwoWay,
            FfiNotebookCaptureMode::MultilingualOneWay => Self::MultilingualOneWay,
        }
    }
}

impl From<CaptureState> for FfiNotebookCaptureState {
    fn from(value: CaptureState) -> Self {
        match value {
            CaptureState::Recording => Self::Recording,
            CaptureState::Paused => Self::Paused,
            CaptureState::Draining => Self::Draining,
            CaptureState::Completed => Self::Completed,
            CaptureState::Interrupted => Self::Interrupted,
            CaptureState::Failed => Self::Failed,
        }
    }
}

impl From<RemoteHealth> for FfiNotebookRemoteHealth {
    fn from(value: RemoteHealth) -> Self {
        match value {
            RemoteHealth::Off => Self::Off,
            RemoteHealth::Connecting => Self::Connecting,
            RemoteHealth::Live => Self::Live,
            RemoteHealth::Degraded => Self::Degraded,
            RemoteHealth::Unavailable => Self::Unavailable,
        }
    }
}

impl From<ProjectionState> for FfiNotebookProjectionState {
    fn from(value: ProjectionState) -> Self {
        match value {
            ProjectionState::Pending => Self::Pending,
            ProjectionState::Projecting => Self::Projecting,
            ProjectionState::Ready => Self::Ready,
            ProjectionState::Failed => Self::Failed,
        }
    }
}

impl From<AsyncProjectionState> for FfiNotebookAsyncProjectionState {
    fn from(value: AsyncProjectionState) -> Self {
        match value {
            AsyncProjectionState::None => Self::None,
            AsyncProjectionState::Pending => Self::Pending,
            AsyncProjectionState::Projecting => Self::Projecting,
            AsyncProjectionState::Ready => Self::Ready,
            AsyncProjectionState::Failed => Self::Failed,
        }
    }
}

impl From<NotebookCaptureProfile> for FfiNotebookCaptureProfile {
    fn from(value: NotebookCaptureProfile) -> Self {
        Self {
            notebook_id: value.notebook_id,
            remote_realtime_enabled: value.remote_realtime_enabled,
            mode: value.capture_mode.into(),
            language_a: value.language_a,
            language_b: value.language_b,
            left_language: value.left_language,
            right_language: value.right_language,
            selected_languages: value.selected_languages,
            common_caption_language: value.common_caption_language,
            privacy_level: value.privacy_level,
            send_context_to_soniox: value.send_context_to_soniox,
            revision: value.revision,
        }
    }
}

impl From<vt_stt::NotebookCaptureEngine> for FfiNotebookCaptureEngineDescriptor {
    fn from(value: vt_stt::NotebookCaptureEngine) -> Self {
        Self {
            provider_id: value.provider_id.to_string(),
            provider_display_name: value.provider_display_name.to_string(),
            realtime_model_id: value.realtime_model_id.to_string(),
            post_stop_model_id: value.post_stop_model_id.to_string(),
            supports_realtime_transcription: value.supports_realtime_transcription,
            supports_two_way_translation: value.supports_two_way_translation,
            supports_context: value.supports_context,
            supports_post_stop_transcription: value.supports_post_stop_transcription,
            post_stop_execution: match value.post_stop_execution {
                vt_stt::PostStopExecution::RealtimeRestream => {
                    FfiNotebookPostStopExecution::RealtimeRestream
                }
            },
        }
    }
}

impl From<RealtimeUtterance> for FfiNotebookCaptureUtterance {
    fn from(value: RealtimeUtterance) -> Self {
        let language_variants = value
            .variants
            .into_iter()
            .map(|variant| FfiNotebookCaptureLanguageVariant {
                language: variant.language,
                role: match variant.role {
                    UtteranceVariantRole::Source => "source",
                    UtteranceVariantRole::Translation => "translation",
                }
                .to_string(),
                text: variant.text,
                state: match variant.state {
                    UtteranceVariantState::Waiting => "waiting",
                    UtteranceVariantState::Ready => "ready",
                    UtteranceVariantState::Failed => "failed",
                    UtteranceVariantState::Unavailable => "unavailable",
                }
                .to_string(),
                completion: variant.completion.map(|completion| {
                    match completion {
                        UtteranceCompletion::Partial => "partial",
                        UtteranceCompletion::Complete => "complete",
                    }
                    .to_string()
                }),
            })
            .collect();
        Self {
            id: value.id,
            session_id: value.session_id,
            sequence: value.sequence,
            revision: value.revision,
            session_speaker_id: value.session_speaker_id,
            source_language: value.source_language,
            source_text: value.source_text,
            source_start_ms: value.source_start_ms,
            source_end_ms: value.source_end_ms,
            translated_language: value.translated_language,
            translated_text: value.translated_text,
            completion: match value.completion {
                UtteranceCompletion::Partial => "partial",
                UtteranceCompletion::Complete => "complete",
            }
            .to_string(),
            alignment: match value.alignment {
                UtteranceAlignment::Paired => "paired",
                UtteranceAlignment::SourceOnly => "source_only",
                UtteranceAlignment::TranslationPending => "translation_pending",
                UtteranceAlignment::OutsideLanguagePair => "outside_language_pair",
            }
            .to_string(),
            language_variants,
        }
    }
}

fn ffi_live_preview(value: AssembledRealtimeUtterance) -> FfiNotebookCaptureUtterance {
    let value = value.utterance;
    FfiNotebookCaptureUtterance {
        id: value.id,
        session_id: value.session_id,
        sequence: value.sequence,
        // A preview revision is intentionally not a store row revision. The
        // enclosing preview event owns transient replacement ordering.
        revision: 0,
        session_speaker_id: None,
        source_language: value.source_language,
        source_text: value.source_text,
        source_start_ms: value.source_start_ms,
        source_end_ms: value.source_end_ms,
        translated_language: value.translated_language,
        translated_text: value.translated_text,
        completion: "partial".to_string(),
        alignment: match value.alignment {
            UtteranceAlignment::Paired => "paired",
            UtteranceAlignment::SourceOnly => "source_only",
            UtteranceAlignment::TranslationPending => "translation_pending",
            UtteranceAlignment::OutsideLanguagePair => "outside_language_pair",
        }
        .to_string(),
        // Live previews reuse the legacy shadow fields above. Durable language
        // variants remain a store-owned fact and are never synthesized here.
        language_variants: Vec::new(),
    }
}

impl From<NotebookCaptureHistoryRun> for FfiNotebookCaptureHistoryRun {
    fn from(value: NotebookCaptureHistoryRun) -> Self {
        let profile = serde_json::from_str::<NotebookCaptureProfile>(&value.profile_snapshot_json);
        let (
            mode,
            language_a,
            language_b,
            left_language,
            right_language,
            selected_languages,
            common_caption_language,
            privacy_level,
            profile_error,
        ) = match profile {
            Ok(profile) => (
                Some(profile.capture_mode.into()),
                Some(profile.language_a),
                Some(profile.language_b),
                Some(profile.left_language),
                Some(profile.right_language),
                profile.selected_languages,
                profile.common_caption_language,
                Some(profile.privacy_level),
                None,
            ),
            Err(error) => {
                tracing::error!(
                    run_id = %value.id,
                    error = %error,
                    "capture history profile snapshot is corrupt; refusing display-language fallback"
                );
                (
                    None,
                    None,
                    None,
                    None,
                    None,
                    Vec::new(),
                    None,
                    None,
                    Some("profile_snapshot_corrupt".to_string()),
                )
            }
        };
        Self {
            run_id: value.id,
            notebook_id: value.notebook_id,
            session_id: value.session_id,
            profile_revision: value.profile_revision,
            created_at: value.created_at,
            updated_at: value.updated_at,
            completed_at: value.completed_at,
            capture_state: value.capture_state.into(),
            remote_health: value.remote_health.into(),
            projection_state: value.projection_state.into(),
            mode,
            language_a,
            language_b,
            left_language,
            right_language,
            selected_languages,
            common_caption_language,
            privacy_level,
            post_stop_async_state: match value.async_task_state {
                AsyncTaskState::None => "none",
                AsyncTaskState::Pending => "pending",
                AsyncTaskState::Reserved => "reserved",
                AsyncTaskState::Enqueued => "enqueued",
                AsyncTaskState::Completed => "completed",
                AsyncTaskState::Failed => "failed",
            }
            .to_string(),
            post_stop_async_projection_state: value.async_projection_state.into(),
            realtime_provider_id: value.realtime_provider_id,
            realtime_model_id: value.realtime_model_id,
            post_stop_provider_id: value.post_stop_provider_id,
            post_stop_model_id: value.post_stop_model_id,
            provider_error_type: profile_error.or(value.provider_error_type),
            provider_request_id: value.provider_request_id,
            sample_rate: value.sample_rate,
            channels: value.channels,
            captured_frames: value.captured_frames,
            has_audio: value.has_audio,
            utterances: value.utterances.into_iter().map(Into::into).collect(),
        }
    }
}

fn context_pack_info(value: ContextPackRecord, bound_position: Option<u64>) -> FfiContextPackInfo {
    FfiContextPackInfo {
        id: value.id,
        scope: match value.scope {
            ContextPackScope::Private => "private",
            ContextPackScope::Library => "library",
        }
        .to_string(),
        owner_notebook_id: value.owner_notebook_id,
        title: value.title,
        revision: value.revision,
        bound_position,
    }
}

fn context_source_info(value: ContextPackSourceRecord) -> FfiContextPackSourceInfo {
    FfiContextPackSourceInfo {
        id: value.id,
        pack_id: value.pack_id,
        title: value.title,
        format: match value.format {
            ContextSourceFormat::Text => "text",
            ContextSourceFormat::Markdown => "markdown",
            ContextSourceFormat::TranslationCsv => "translation_csv",
        }
        .to_string(),
        content_kind: context_kind_name(value.content_kind).to_string(),
        plaintext_sha256: value.plaintext_sha256,
        plaintext_bytes: value.plaintext_bytes,
        trusted: value.trusted,
        revision: value.revision,
    }
}

fn context_kind_name(value: ContextContentKind) -> &'static str {
    match value {
        ContextContentKind::TranslationTerms => "translation_terms",
        ContextContentKind::Terms => "terms",
        ContextContentKind::General => "general",
        ContextContentKind::Text => "text",
    }
}

fn parse_context_kind(value: &str) -> Result<ContextContentKind, CoreError> {
    match value {
        "translation_terms" => Ok(ContextContentKind::TranslationTerms),
        "terms" => Ok(ContextContentKind::Terms),
        "general" => Ok(ContextContentKind::General),
        "text" => Ok(ContextContentKind::Text),
        _ => Err(CoreError::ValidationFailed {
            message: format!("invalid Context content kind: {value}"),
        }),
    }
}

fn require_context_pack_access(
    store: &ContextPackStore,
    notebook_id: &str,
    pack_id: &str,
) -> Result<ContextPackRecord, CoreError> {
    let pack = store
        .get_pack(pack_id)
        .map_err(store_error)?
        .filter(|pack| pack.deleted_at.is_none())
        .ok_or_else(|| CoreError::NotFound {
            message: format!("Context Pack {pack_id}"),
        })?;
    if pack.scope == ContextPackScope::Private
        && pack.owner_notebook_id.as_deref() != Some(notebook_id)
    {
        return Err(CoreError::ValidationFailed {
            message: format!(
                "private Context Pack {pack_id} does not belong to notebook {notebook_id}"
            ),
        });
    }
    Ok(pack)
}

fn format_context_omission(value: &vt_store::ContextOmission) -> String {
    let reason = match value.reason {
        ContextOmissionReason::Duplicate => "duplicate",
        ContextOmissionReason::BudgetExceeded => "budget_exceeded",
        ContextOmissionReason::Truncated => "truncated",
    };
    format!(
        "{}:{}:{} items={} scalars={}",
        value.source_id,
        context_kind_name(value.section),
        reason,
        value.omitted_items,
        value.omitted_scalars
    )
}

fn profile_update_from_ffi(value: &FfiNotebookCaptureProfile) -> NotebookCaptureProfileUpdate {
    let selected_languages = value
        .selected_languages
        .iter()
        .map(|language| canonical_language(language))
        .collect::<Vec<_>>();
    let (language_a, language_b) = legacy_capture_language_pair(&selected_languages);
    NotebookCaptureProfileUpdate {
        remote_realtime_enabled: value.remote_realtime_enabled,
        capture_mode: capture_mode_for_selection(
            value.remote_realtime_enabled,
            selected_languages.len(),
        ),
        language_a: language_a.clone(),
        language_b: language_b.clone(),
        left_language: language_a,
        right_language: language_b,
        selected_languages,
        // Compatibility field only. Every selected language is now an equal
        // output target; column order must never choose one privileged caption.
        common_caption_language: None,
        privacy_level: value.privacy_level.clone(),
        send_context_to_soniox: value.send_context_to_soniox,
    }
}

fn store_error(error: impl std::fmt::Display) -> CoreError {
    CoreError::InternalError {
        message: error.to_string(),
    }
}

#[derive(serde::Serialize)]
struct ContextConfirmation<'a> {
    context_json: &'a str,
    receipt: &'a ContextReceipt,
}

fn context_confirmation_digest(compilation: &ContextCompilation) -> Result<String, CoreError> {
    let canonical = serde_json::to_vec(&ContextConfirmation {
        context_json: &compilation.context_json,
        receipt: &compilation.receipt,
    })
    .map_err(|error| CoreError::InternalError {
        message: format!("serialize Context confirmation: {error}"),
    })?;
    Ok(hex::encode(Sha256::digest(canonical)))
}

fn parse_context_receipt(run: &NotebookCaptureRun) -> Option<FfiNotebookCaptureContextReceipt> {
    let applied_at = run.context_applied_at.clone()?;
    let provider = run.realtime_provider_id.clone()?;
    let model = run.realtime_model_id.clone()?;
    let receipt: ContextReceipt = run
        .context_receipt_json
        .as_deref()
        .and_then(|json| serde_json::from_str(json).ok())?;
    Some(FfiNotebookCaptureContextReceipt {
        digest: receipt.context_sha256,
        applied: true,
        provider,
        model,
        applied_at,
    })
}

fn event_from_run(
    mut run: NotebookCaptureRun,
    utterances: Vec<RealtimeUtterance>,
    is_full_snapshot: bool,
) -> FfiNotebookCaptureEvent {
    let profile = serde_json::from_str::<NotebookCaptureProfile>(&run.profile_snapshot_json);
    let (
        mode,
        language_a,
        language_b,
        left_language,
        right_language,
        selected_languages,
        common_caption_language,
        privacy_level,
    ) = match profile {
        Ok(profile) => (
            Some(profile.capture_mode.into()),
            Some(profile.language_a),
            Some(profile.language_b),
            Some(profile.left_language),
            Some(profile.right_language),
            profile.selected_languages,
            profile.common_caption_language,
            Some(profile.privacy_level),
        ),
        Err(error) => {
            run.provider_error_type = Some("profile_snapshot_corrupt".to_string());
            run.provider_request_id = None;
            tracing::error!(
                run_id = %run.id,
                error = %error,
                "capture profile snapshot is corrupt; refusing display-language fallback"
            );
            (None, None, None, None, None, Vec::new(), None, None)
        }
    };
    FfiNotebookCaptureEvent {
        session_id: run.session_id.clone(),
        event_revision: 0,
        is_full_snapshot,
        capture_state: run.capture_state.into(),
        remote_health: run.remote_health.into(),
        projection_state: run.projection_state.into(),
        mode,
        language_a,
        language_b,
        left_language,
        right_language,
        selected_languages,
        common_caption_language,
        privacy_level,
        post_stop_async_state: match run.async_task_state {
            AsyncTaskState::None => "none",
            AsyncTaskState::Pending => "pending",
            AsyncTaskState::Reserved => "reserved",
            AsyncTaskState::Enqueued => "enqueued",
            AsyncTaskState::Completed => "completed",
            AsyncTaskState::Failed => "failed",
        }
        .to_string(),
        post_stop_async_projection_state: run.async_projection_state.into(),
        realtime_provider_id: run.realtime_provider_id.clone(),
        realtime_model_id: run.realtime_model_id.clone(),
        post_stop_provider_id: run.post_stop_provider_id.clone(),
        post_stop_model_id: run.post_stop_model_id.clone(),
        utterances: utterances.into_iter().map(Into::into).collect(),
        context_receipt: parse_context_receipt(&run),
        provider_error_type: run.provider_error_type,
        provider_request_id: run.provider_request_id,
    }
}

#[derive(Debug, Default)]
struct LaneRevision {
    committed: String,
    pending: String,
    committed_language: Option<String>,
    pending_language: Option<String>,
    pending_language_ambiguous: bool,
}

impl LaneRevision {
    fn begin_response_revision(&mut self) -> bool {
        let changed = !self.pending.is_empty()
            || self.pending_language.is_some()
            || self.pending_language_ambiguous;
        self.pending.clear();
        self.pending_language = None;
        self.pending_language_ambiguous = false;
        changed
    }

    fn push(&mut self, token: &SttStreamToken, language: Option<String>) {
        if token.is_final {
            self.committed.push_str(&token.text);
            if language.is_some() {
                self.committed_language = language;
            }
        } else {
            self.pending.push_str(&token.text);
            if let Some(language) = language {
                match self.pending_language.as_deref() {
                    Some(current) if current != language => {
                        self.pending_language_ambiguous = true;
                    }
                    None => self.pending_language = Some(language),
                    Some(_) => {}
                }
            }
        }
    }

    fn unambiguous_pending_language(&self) -> Option<&str> {
        (!self.pending_language_ambiguous)
            .then_some(self.pending_language.as_deref())
            .flatten()
    }

    fn take_pending(&mut self) -> Self {
        Self {
            committed: String::new(),
            pending: std::mem::take(&mut self.pending),
            committed_language: None,
            pending_language: self.pending_language.take(),
            pending_language_ambiguous: std::mem::take(&mut self.pending_language_ambiguous),
        }
    }

    fn text(&self, include_pending: bool) -> String {
        if include_pending {
            format!("{}{}", self.committed, self.pending)
        } else {
            self.committed.clone()
        }
    }

    fn is_empty(&self) -> bool {
        self.committed.is_empty() && self.pending.is_empty()
    }
}

#[derive(Debug)]
struct RealtimeSegmentRevision {
    id: String,
    sequence: u64,
    source: LaneRevision,
    translated: LaneRevision,
    committed_provider_speaker: Option<String>,
    pending_provider_speaker: Option<String>,
    pending_provider_speaker_ambiguous: bool,
    committed_source_language_hint: Option<String>,
    pending_source_language_hint: Option<String>,
    committed_provider_speaker_hint: Option<String>,
    pending_provider_speaker_hint: Option<String>,
    committed_source_start_ms: Option<u64>,
    committed_source_end_ms: Option<u64>,
    pending_source_start_ms: Option<u64>,
    pending_source_end_ms: Option<u64>,
    revision: Option<u64>,
    complete: bool,
    dirty: bool,
}

impl RealtimeSegmentRevision {
    fn new(session_id: &str, sequence: u64) -> Self {
        Self {
            id: format!("{session_id}:{sequence}"),
            sequence,
            source: LaneRevision::default(),
            translated: LaneRevision::default(),
            committed_provider_speaker: None,
            pending_provider_speaker: None,
            pending_provider_speaker_ambiguous: false,
            committed_source_language_hint: None,
            pending_source_language_hint: None,
            committed_provider_speaker_hint: None,
            pending_provider_speaker_hint: None,
            committed_source_start_ms: None,
            committed_source_end_ms: None,
            pending_source_start_ms: None,
            pending_source_end_ms: None,
            revision: None,
            complete: false,
            dirty: false,
        }
    }

    fn begin_response_revision(&mut self) {
        let changed = self.source.begin_response_revision()
            | self.translated.begin_response_revision()
            | self.pending_provider_speaker.take().is_some()
            | self.pending_provider_speaker_ambiguous
            | self.pending_source_language_hint.take().is_some()
            | self.pending_provider_speaker_hint.take().is_some()
            | self.pending_source_start_ms.take().is_some()
            | self.pending_source_end_ms.take().is_some();
        self.pending_provider_speaker_ambiguous = false;
        self.dirty |= changed;
    }

    fn stable_source_language(&self) -> Option<&str> {
        self.source
            .committed_language
            .as_deref()
            .or(self.committed_source_language_hint.as_deref())
    }

    fn matching_source_language(&self) -> Option<&str> {
        self.source
            .committed_language
            .as_deref()
            .or(self.committed_source_language_hint.as_deref())
            .or(self.source.unambiguous_pending_language())
            .or(self.pending_source_language_hint.as_deref())
    }

    fn stable_provider_speaker(&self) -> Option<&str> {
        self.committed_provider_speaker.as_deref()
    }

    fn matching_provider_speaker(&self) -> Option<&str> {
        self.committed_provider_speaker
            .as_deref()
            .or(self.committed_provider_speaker_hint.as_deref())
            .or((!self.pending_provider_speaker_ambiguous)
                .then_some(self.pending_provider_speaker.as_deref())
                .flatten())
            .or(self.pending_provider_speaker_hint.as_deref())
    }

    fn durable_provider_speaker(&self) -> Option<&str> {
        self.committed_provider_speaker.as_deref()
    }

    fn source_language(&self) -> String {
        self.stable_source_language().unwrap_or("und").to_string()
    }

    fn pending_source_matches_committed_identity(&self) -> bool {
        let stable_language = self.stable_source_language();
        let pending_language = self.source.unambiguous_pending_language();
        let language_is_safe = if stable_language.is_some() {
            !self.source.pending_language_ambiguous
                && !identity_conflicts(stable_language, pending_language)
        } else {
            true
        };
        let stable_speaker = self
            .committed_provider_speaker
            .as_deref()
            .or(self.committed_provider_speaker_hint.as_deref());
        let speaker_is_safe = if stable_speaker.is_some() {
            !self.pending_provider_speaker_ambiguous
                && !identity_conflicts(stable_speaker, self.pending_provider_speaker.as_deref())
        } else {
            true
        };
        language_is_safe && speaker_is_safe
    }

    fn has_source_text(&self) -> bool {
        !self.source.is_empty()
    }

    fn is_empty(&self) -> bool {
        self.source.is_empty() && self.translated.is_empty()
    }
}

#[derive(Debug)]
struct AssembledRealtimeUtterance {
    utterance: NewRealtimeUtterance,
    provider_speaker: Option<String>,
    expected_revision: Option<u64>,
}

/// Response-order utterance assembler. It keeps provider speaker and language
/// orthogonal, splits only on final source-token identity changes, and never
/// correlates translation tokens by timestamp.
#[derive(Debug)]
struct RealtimeUtteranceAssembler {
    session_id: String,
    selected_languages: std::collections::HashSet<String>,
    capture_mode: CaptureMode,
    common_caption_language: Option<String>,
    next_sequence: u64,
    segments: Vec<RealtimeSegmentRevision>,
    latest_original_segment: Option<usize>,
    /// Response-order cursor for translation tokens. Soniox translation
    /// tokens do not carry timestamps, so repeated language/speaker identities
    /// must advance through source segments in provider order instead of
    /// requiring a globally unique identity match.
    latest_translation_segment: Option<usize>,
    unattached_translation_tokens: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct RemoteStreamLane {
    target_language: Option<String>,
    canonical: bool,
}

type RemoteStreamPlanEntry = (Option<String>, Option<TranslationConfig>);

fn remote_stream_plan(
    selected_languages: &[String],
) -> Result<Vec<RemoteStreamPlanEntry>, CoreError> {
    match selected_languages {
        [] => Err(CoreError::ValidationFailed {
            message: "remote realtime capture requires at least one selected language".to_string(),
        }),
        [_] => Ok(vec![(None, None)]),
        [language_a, language_b] => Ok(vec![(
            None,
            Some(TranslationConfig::TwoWay {
                language_a: language_a.clone(),
                language_b: language_b.clone(),
            }),
        )]),
        selected => Ok(std::iter::once((None, None))
            .chain(selected.iter().map(|target_language| {
                (
                    Some(target_language.clone()),
                    Some(TranslationConfig::OneWay {
                        target_language: target_language.clone(),
                    }),
                )
            }))
            .collect()),
    }
}

#[derive(Debug)]
struct TaggedStreamEvent {
    lane_index: usize,
    event: SttStreamEvent,
}

struct CancelRemoteGroupOnDrop(tokio_util::sync::CancellationToken);

impl Drop for CancelRemoteGroupOnDrop {
    fn drop(&mut self) {
        self.0.cancel();
    }
}

#[derive(Debug)]
struct StreamAggregationLane {
    descriptor: RemoteStreamLane,
    assembler: RealtimeUtteranceAssembler,
    provider_session_epoch: u64,
    /// Cross-stream alignment epoch. All streams begin in epoch zero. A
    /// reconnect receives a globally unique epoch so independently restarted
    /// WebSockets can never be paired merely because their local retry counts
    /// happen to match.
    group_epoch: u64,
    awaiting_reconnect: bool,
    connected: bool,
    ever_connected: bool,
    provider_accepted_configuration: bool,
}

#[derive(Debug, Clone)]
struct CanonicalUtteranceMatch {
    group_epoch: u64,
    utterance: RealtimeUtterance,
}

#[derive(Debug)]
struct PendingTranslationVariant {
    group_epoch: u64,
    source_sequence: u64,
    source_language: String,
    source_text: String,
    source_start_ms: Option<u64>,
    source_end_ms: Option<u64>,
    target_language: String,
    translated_text: String,
    completion: UtteranceCompletion,
}

/// Keep enough finalized alignment history for late provider revisions without
/// retaining an entire lecture in the in-memory cross-stream indexes.
const STREAM_AGGREGATION_RECENT_UTTERANCE_WINDOW: usize = 128;

#[allow(clippy::too_many_arguments)]
async fn collect_stream_events(
    store: NotebookCaptureStore,
    context_store: ContextPackStore,
    run_id: String,
    profile: NotebookCaptureProfile,
    context_digest: Option<String>,
    lane_descriptors: Vec<RemoteStreamLane>,
    mut event_rx: tokio::sync::mpsc::Receiver<TaggedStreamEvent>,
    group_cancel: tokio_util::sync::CancellationToken,
    callback: CaptureCallbackSink,
) -> Result<(), ProviderFailure> {
    // Any persistence/protocol return path must stop every sibling WebSocket;
    // otherwise the central writer could disappear while provider I/O keeps
    // running and billing until a later audio push notices backpressure.
    let _cancel_on_exit = CancelRemoteGroupOnDrop(group_cancel.clone());
    let session_id = store
        .get_run(&run_id)
        .map_err(|error| local_persistence_failure("load Soniox capture run", error))?
        .map(|run| run.session_id)
        .unwrap_or_else(|| profile.notebook_id.clone());
    let mut lanes = lane_descriptors
        .into_iter()
        .map(|descriptor| {
            // `common_caption_language` is retired as product state, but the
            // response-order assembler still needs one explicit expected
            // one-way target per WebSocket. Keep that compatibility detail
            // private to this lane; it never escapes into the capture profile.
            let mut lane_profile = profile.clone();
            if let Some(target_language) = descriptor.target_language.as_ref() {
                lane_profile.common_caption_language = Some(target_language.clone());
            }
            StreamAggregationLane {
                assembler: RealtimeUtteranceAssembler::new(session_id.clone(), &lane_profile),
                descriptor,
                provider_session_epoch: 0,
                group_epoch: 0,
                awaiting_reconnect: false,
                connected: false,
                ever_connected: false,
                provider_accepted_configuration: false,
            }
        })
        .collect::<Vec<_>>();
    if lanes.is_empty()
        || lanes
            .iter()
            .filter(|lane| lane.descriptor.canonical)
            .count()
            != 1
    {
        return Err(ProviderFailure {
            error_type: "invalid_stream_group".to_string(),
            request_id: None,
        });
    }
    let canonical_lane_index = lanes
        .iter()
        .position(|lane| lane.descriptor.canonical)
        .expect("validated one canonical Soniox stream");
    let selected_languages = profile
        .selected_languages
        .iter()
        .map(|language| normalize_language(language))
        .collect::<Vec<_>>();
    let mut context_applied = false;
    let mut next_group_epoch = 0_u64;
    let mut canonical_matches =
        std::collections::HashMap::<(u64, u64), CanonicalUtteranceMatch>::new();
    let mut pending_variants =
        std::collections::HashMap::<(usize, u64, u64), PendingTranslationVariant>::new();
    let mut variant_bindings = std::collections::HashMap::<(usize, u64, u64), u64>::new();
    let mut reverse_variant_bindings =
        std::collections::HashMap::<(u64, u64, String), (usize, u64, u64)>::new();
    let mut initialized_variants = std::collections::HashSet::<(u64, String)>::new();

    while let Some(tagged) = event_rx.recv().await {
        let Some(lane) = lanes.get_mut(tagged.lane_index) else {
            group_cancel.cancel();
            return Err(ProviderFailure {
                error_type: "invalid_stream_lane".to_string(),
                request_id: None,
            });
        };
        let provider_accepted_configuration = matches!(
            &tagged.event,
            SttStreamEvent::Tokens(_)
                | SttStreamEvent::Endpoint
                | SttStreamEvent::Finalized
                | SttStreamEvent::Finished
        );
        if provider_accepted_configuration {
            lane.provider_accepted_configuration = true;
        }
        if !context_applied
            && lanes
                .iter()
                .all(|lane| lane.provider_accepted_configuration)
        {
            if let Some(digest) = context_digest.as_deref() {
                match context_store.mark_context_applied(&run_id, digest) {
                    Ok(_) => {
                        context_applied = true;
                        if let Ok(Some(run)) = store.get_run(&run_id) {
                            emit_capture_delta(run, Vec::new(), &callback);
                        }
                    }
                    Err(error) => {
                        return Err(local_persistence_failure(
                            "persist applied Context receipt",
                            error,
                        ));
                    }
                }
            }
        }
        let lane_index = tagged.lane_index;
        let publishes_canonical_preview = lane_index == canonical_lane_index
            && matches!(
                &tagged.event,
                SttStreamEvent::Tokens(_)
                    | SttStreamEvent::Endpoint
                    | SttStreamEvent::Finalized
                    | SttStreamEvent::Finished
                    | SttStreamEvent::Reconnecting { .. }
                    | SttStreamEvent::Error(_)
            );
        let persisted = match tagged.event {
            SttStreamEvent::Connected => {
                let reconnected = lanes[lane_index].awaiting_reconnect;
                {
                    let lane = &mut lanes[lane_index];
                    record_provider_connected(
                        &mut lane.provider_session_epoch,
                        &mut lane.awaiting_reconnect,
                    );
                    if reconnected {
                        next_group_epoch = next_group_epoch.saturating_add(1);
                        lane.group_epoch = next_group_epoch;
                    }
                    lane.connected = true;
                    lane.ever_connected = true;
                }
                if lanes.iter().all(|lane| lane.connected) {
                    let run = store
                        .update_remote_health(&run_id, RemoteHealth::Live, None)
                        .map_err(|error| {
                            local_persistence_failure("persist Soniox live state", error)
                        })?;
                    emit_capture_delta(run, Vec::new(), &callback);
                }
                Vec::new()
            }
            SttStreamEvent::Reconnecting { .. } => {
                let finalized = lanes[lane_index].assembler.finalize();
                let persisted = persist_stream_lane_updates(
                    &store,
                    &mut lanes,
                    canonical_lane_index,
                    lane_index,
                    finalized,
                    &selected_languages,
                    &mut canonical_matches,
                    &mut pending_variants,
                    &mut variant_bindings,
                    &mut reverse_variant_bindings,
                    &mut initialized_variants,
                )?;
                lanes[lane_index].assembler.advance();
                lanes[lane_index].connected = false;
                let group_reconnect_failure = (lanes.len() > 1).then(|| ProviderFailure {
                    error_type: "stream_group_reconnect_required".to_string(),
                    request_id: None,
                });
                if group_reconnect_failure.is_some() {
                    // Independent Soniox reconnects reset timestamps, anonymous
                    // speaker labels, and audio origins. Until vt-stt exposes a
                    // coordinated reconnect barrier, fail the multi-target
                    // group closed instead of letting one lane silently drift.
                    group_cancel.cancel();
                } else {
                    lanes[lane_index].awaiting_reconnect = true;
                }
                let run = store
                    .update_remote_health(
                        &run_id,
                        if group_reconnect_failure.is_some() {
                            RemoteHealth::Degraded
                        } else {
                            RemoteHealth::Connecting
                        },
                        group_reconnect_failure.as_ref(),
                    )
                    .map_err(|error| {
                        local_persistence_failure("persist Soniox reconnecting state", error)
                    })?;
                emit_capture_delta(run, Vec::new(), &callback);
                persisted
            }
            SttStreamEvent::Tokens(tokens) => {
                let updates = lanes[lane_index].assembler.apply_tokens(&tokens);
                persist_stream_lane_updates(
                    &store,
                    &mut lanes,
                    canonical_lane_index,
                    lane_index,
                    updates,
                    &selected_languages,
                    &mut canonical_matches,
                    &mut pending_variants,
                    &mut variant_bindings,
                    &mut reverse_variant_bindings,
                    &mut initialized_variants,
                )?
            }
            SttStreamEvent::Endpoint | SttStreamEvent::Finalized | SttStreamEvent::Finished => {
                let finalized = lanes[lane_index].assembler.finalize();
                let persisted = persist_stream_lane_updates(
                    &store,
                    &mut lanes,
                    canonical_lane_index,
                    lane_index,
                    finalized,
                    &selected_languages,
                    &mut canonical_matches,
                    &mut pending_variants,
                    &mut variant_bindings,
                    &mut reverse_variant_bindings,
                    &mut initialized_variants,
                )?;
                lanes[lane_index].assembler.advance();
                persisted
            }
            SttStreamEvent::Error(error) => {
                // `Error` is terminal for this stream runtime. Preserve any
                // source text held behind the provisional publication gate
                // before the event channel closes.
                let finalized = lanes[lane_index].assembler.finalize();
                let persisted = persist_stream_lane_updates(
                    &store,
                    &mut lanes,
                    canonical_lane_index,
                    lane_index,
                    finalized,
                    &selected_languages,
                    &mut canonical_matches,
                    &mut pending_variants,
                    &mut variant_bindings,
                    &mut reverse_variant_bindings,
                    &mut initialized_variants,
                )?;
                lanes[lane_index].assembler.advance();
                lanes[lane_index].connected = false;
                let failure = provider_failure(&error);
                let health = if lanes.iter().any(|lane| lane.ever_connected) {
                    RemoteHealth::Degraded
                } else {
                    RemoteHealth::Unavailable
                };
                // A target-specific terminal failure invalidates the remote
                // column set as a whole. Local capture remains authoritative,
                // while every sibling WebSocket is stopped to prevent silently
                // diverging audio windows.
                group_cancel.cancel();
                let run = store
                    .update_remote_health(&run_id, health, Some(&failure))
                    .map_err(|error| local_persistence_failure("persist Soniox failure", error))?;
                emit_capture_delta(run, Vec::new(), &callback);
                persisted
            }
        };

        if !persisted.is_empty() {
            if let Ok(Some(run)) = store.get_run(&run_id) {
                emit_capture_delta(run, persisted, &callback);
            }
        }
        if publishes_canonical_preview {
            emit_live_preview(
                &session_id,
                lanes[canonical_lane_index].assembler.live_previews(),
                &callback,
            );
        }
    }
    let unavailable =
        mark_waiting_translation_variants_unavailable(&store, &mut canonical_matches)?;
    if !unavailable.is_empty() {
        if let Ok(Some(run)) = store.get_run(&run_id) {
            emit_capture_delta(run, unavailable, &callback);
        }
    }
    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn persist_stream_lane_updates(
    store: &NotebookCaptureStore,
    lanes: &mut [StreamAggregationLane],
    canonical_lane_index: usize,
    lane_index: usize,
    updates: Vec<AssembledRealtimeUtterance>,
    selected_languages: &[String],
    canonical_matches: &mut std::collections::HashMap<(u64, u64), CanonicalUtteranceMatch>,
    pending_variants: &mut std::collections::HashMap<(usize, u64, u64), PendingTranslationVariant>,
    variant_bindings: &mut std::collections::HashMap<(usize, u64, u64), u64>,
    reverse_variant_bindings: &mut std::collections::HashMap<(u64, u64, String), (usize, u64, u64)>,
    initialized_variants: &mut std::collections::HashSet<(u64, String)>,
) -> Result<Vec<RealtimeUtterance>, ProviderFailure> {
    let group_epoch = lanes[lane_index].group_epoch;
    if lanes[lane_index].descriptor.canonical {
        let provider_session_epoch = lanes[lane_index].provider_session_epoch;
        // The timeline is durable product state, not Soniox's speculative
        // tail. Keep partial revisions inside the assembler and publish only
        // after an identity split or endpoint seals the segment. With the
        // balanced 2s endpoint this gives the UI its intended short stability
        // delay and prevents translations from chasing rows that later move.
        let updates = updates
            .into_iter()
            .filter(|update| update.utterance.completion == UtteranceCompletion::Complete)
            .collect();
        let mut persisted = persist_assembled_utterances(
            store,
            &mut lanes[lane_index].assembler,
            updates,
            provider_session_epoch,
        )?;
        for utterance in &persisted {
            let source_language_changed = canonical_matches
                .get(&(group_epoch, utterance.sequence))
                .is_some_and(|previous| {
                    normalize_language(&previous.utterance.source_language)
                        != normalize_language(&utterance.source_language)
                });
            if source_language_changed {
                // The store removes a translation variant when that language
                // becomes the revised source. If language identification later
                // changes back, its former source language needs a fresh
                // Waiting variant instead of being suppressed by stale
                // initialization memory.
                initialized_variants
                    .retain(|(sequence, _language)| *sequence != utterance.sequence);
            }
            canonical_matches.insert(
                (group_epoch, utterance.sequence),
                CanonicalUtteranceMatch {
                    group_epoch,
                    utterance: utterance.clone(),
                },
            );
        }
        let initialized = initialize_waiting_translation_variants(
            store,
            &mut lanes[canonical_lane_index].assembler,
            selected_languages,
            canonical_matches,
            initialized_variants,
            group_epoch,
            &persisted,
        )?;
        persisted.extend(initialized);
        let matched = flush_pending_translation_variants(
            store,
            &mut lanes[canonical_lane_index].assembler,
            canonical_matches,
            pending_variants,
            variant_bindings,
            reverse_variant_bindings,
        )?;
        persisted.extend(matched);
        prune_resolved_stream_aggregation_history(
            selected_languages,
            canonical_matches,
            variant_bindings,
            reverse_variant_bindings,
            initialized_variants,
        );
        return Ok(latest_utterance_revisions(persisted));
    }

    let Some(target_language) = lanes[lane_index].descriptor.target_language.clone() else {
        return Ok(Vec::new());
    };
    for update in updates {
        let utterance = update.utterance;
        let translated_language = utterance
            .translated_language
            .as_deref()
            .map(normalize_language);
        let Some(translated_text) = utterance.translated_text else {
            continue;
        };
        if translated_language.as_deref() != Some(target_language.as_str()) {
            continue;
        }
        pending_variants.insert(
            (lane_index, group_epoch, utterance.sequence),
            PendingTranslationVariant {
                group_epoch,
                source_sequence: utterance.sequence,
                source_language: normalize_language(&utterance.source_language),
                source_text: utterance.source_text,
                source_start_ms: utterance.source_start_ms,
                source_end_ms: utterance.source_end_ms,
                target_language: target_language.clone(),
                translated_text,
                completion: utterance.completion,
            },
        );
    }
    let persisted = flush_pending_translation_variants(
        store,
        &mut lanes[canonical_lane_index].assembler,
        canonical_matches,
        pending_variants,
        variant_bindings,
        reverse_variant_bindings,
    )?;
    prune_resolved_stream_aggregation_history(
        selected_languages,
        canonical_matches,
        variant_bindings,
        reverse_variant_bindings,
        initialized_variants,
    );
    Ok(persisted)
}

fn initialize_waiting_translation_variants(
    store: &NotebookCaptureStore,
    canonical_assembler: &mut RealtimeUtteranceAssembler,
    selected_languages: &[String],
    canonical_matches: &mut std::collections::HashMap<(u64, u64), CanonicalUtteranceMatch>,
    initialized_variants: &mut std::collections::HashSet<(u64, String)>,
    group_epoch: u64,
    persisted: &[RealtimeUtterance],
) -> Result<Vec<RealtimeUtterance>, ProviderFailure> {
    let mut updates = Vec::new();
    for utterance in persisted {
        let source_language = normalize_language(&utterance.source_language);
        for language in selected_languages {
            if language == &source_language
                || utterance
                    .variants
                    .iter()
                    .any(|variant| normalize_language(&variant.language) == *language)
                || !initialized_variants.insert((utterance.sequence, language.clone()))
            {
                continue;
            }
            let updated = store
                .upsert_translation_variant(
                    &utterance.session_id,
                    utterance.sequence,
                    language,
                    None,
                    UtteranceVariantState::Waiting,
                    None,
                )
                .map_err(|error| {
                    local_persistence_failure(
                        &format!(
                            "persist waiting translation variant {}:{}:{language}",
                            utterance.session_id, utterance.sequence
                        ),
                        error,
                    )
                })?;
            canonical_assembler.record_persisted(&updated.id, updated.revision);
            canonical_matches.insert(
                (group_epoch, updated.sequence),
                CanonicalUtteranceMatch {
                    group_epoch,
                    utterance: updated.clone(),
                },
            );
            updates.push(updated);
        }
    }
    Ok(updates)
}

fn mark_waiting_translation_variants_unavailable(
    store: &NotebookCaptureStore,
    canonical_matches: &mut std::collections::HashMap<(u64, u64), CanonicalUtteranceMatch>,
) -> Result<Vec<RealtimeUtterance>, ProviderFailure> {
    let mut pending = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for ((group_epoch, sequence), candidate) in canonical_matches.iter() {
        for variant in &candidate.utterance.variants {
            if variant.state == UtteranceVariantState::Waiting
                && seen.insert((
                    *group_epoch,
                    *sequence,
                    normalize_language(&variant.language),
                ))
            {
                pending.push((
                    *group_epoch,
                    candidate.utterance.session_id.clone(),
                    *sequence,
                    normalize_language(&variant.language),
                ));
            }
        }
    }

    let mut updates = Vec::new();
    for (group_epoch, session_id, sequence, language) in pending {
        let updated = store
            .upsert_translation_variant(
                &session_id,
                sequence,
                &language,
                None,
                UtteranceVariantState::Unavailable,
                None,
            )
            .map_err(|error| {
                local_persistence_failure(
                    &format!(
                        "persist unavailable translation variant {session_id}:{sequence}:{language}"
                    ),
                    error,
                )
            })?;
        canonical_matches.insert(
            (group_epoch, sequence),
            CanonicalUtteranceMatch {
                group_epoch,
                utterance: updated.clone(),
            },
        );
        updates.push(updated);
    }
    Ok(latest_utterance_revisions(updates))
}

fn prune_resolved_stream_aggregation_history(
    selected_languages: &[String],
    canonical_matches: &mut std::collections::HashMap<(u64, u64), CanonicalUtteranceMatch>,
    variant_bindings: &mut std::collections::HashMap<(usize, u64, u64), u64>,
    reverse_variant_bindings: &mut std::collections::HashMap<(u64, u64, String), (usize, u64, u64)>,
    initialized_variants: &mut std::collections::HashSet<(u64, String)>,
) -> usize {
    let mut resolved = canonical_matches
        .iter()
        .filter_map(|(key, candidate)| {
            canonical_match_has_final_selected_languages(candidate, selected_languages)
                .then_some(*key)
        })
        .collect::<Vec<_>>();
    if resolved.len() <= STREAM_AGGREGATION_RECENT_UTTERANCE_WINDOW {
        return 0;
    }

    resolved.sort_unstable();
    resolved.truncate(resolved.len() - STREAM_AGGREGATION_RECENT_UTTERANCE_WINDOW);
    let recycled = resolved
        .into_iter()
        .collect::<std::collections::HashSet<_>>();
    canonical_matches.retain(|key, _| !recycled.contains(key));

    let recycled_sequences = recycled
        .iter()
        .map(|(_, sequence)| *sequence)
        .collect::<std::collections::HashSet<_>>();
    initialized_variants.retain(|(sequence, _)| !recycled_sequences.contains(sequence));
    variant_bindings
        .retain(|(_, group_epoch, _), sequence| !recycled.contains(&(*group_epoch, *sequence)));
    reverse_variant_bindings
        .retain(|(group_epoch, sequence, _), _| !recycled.contains(&(*group_epoch, *sequence)));
    recycled.len()
}

fn canonical_match_has_final_selected_languages(
    candidate: &CanonicalUtteranceMatch,
    selected_languages: &[String],
) -> bool {
    if candidate.utterance.completion != UtteranceCompletion::Complete {
        return false;
    }
    let source_language = normalize_language(&candidate.utterance.source_language);
    selected_languages.iter().all(|language| {
        let language = normalize_language(language);
        language == source_language
            || candidate.utterance.variants.iter().any(|variant| {
                normalize_language(&variant.language) == language
                    && variant.state == UtteranceVariantState::Ready
                    && variant.completion == Some(UtteranceCompletion::Complete)
            })
    })
}

fn flush_pending_translation_variants(
    store: &NotebookCaptureStore,
    canonical_assembler: &mut RealtimeUtteranceAssembler,
    canonical_matches: &mut std::collections::HashMap<(u64, u64), CanonicalUtteranceMatch>,
    pending_variants: &mut std::collections::HashMap<(usize, u64, u64), PendingTranslationVariant>,
    variant_bindings: &mut std::collections::HashMap<(usize, u64, u64), u64>,
    reverse_variant_bindings: &mut std::collections::HashMap<(u64, u64, String), (usize, u64, u64)>,
) -> Result<Vec<RealtimeUtterance>, ProviderFailure> {
    let pending_keys = pending_variants.keys().cloned().collect::<Vec<_>>();
    let mut persisted = Vec::new();
    for pending_key in pending_keys {
        let Some(pending) = pending_variants.get(&pending_key) else {
            continue;
        };
        let Some(sequence) = resolve_canonical_sequence(
            pending_key,
            pending,
            canonical_matches,
            variant_bindings,
            reverse_variant_bindings,
        ) else {
            continue;
        };
        let candidate_key = (pending.group_epoch, sequence);
        let Some(candidate) = canonical_matches.get(&candidate_key) else {
            continue;
        };
        if normalize_language(&candidate.utterance.source_language) == pending.target_language {
            pending_variants.remove(&pending_key);
            continue;
        }
        let reverse_key = (
            pending.group_epoch,
            sequence,
            pending.target_language.clone(),
        );
        if candidate.utterance.variants.iter().any(|variant| {
            normalize_language(&variant.language) == pending.target_language
                && variant.state == UtteranceVariantState::Ready
                && variant.text.as_deref() == Some(pending.translated_text.as_str())
                && variant.completion == Some(pending.completion)
        }) {
            // Soniox may repeat the same complete partial response. Preserve
            // its stable binding, but avoid a no-op SQLite revision and UI
            // callback when the visible language lane is byte-for-byte equal.
            variant_bindings.insert(pending_key, sequence);
            reverse_variant_bindings.insert(reverse_key, pending_key);
            pending_variants.remove(&pending_key);
            continue;
        }
        let updated = store
            .upsert_translation_variant(
                &candidate.utterance.session_id,
                sequence,
                &pending.target_language,
                Some(&pending.translated_text),
                UtteranceVariantState::Ready,
                Some(pending.completion),
            )
            .map_err(|error| {
                local_persistence_failure(
                    &format!(
                        "persist paired translation variant {}:{}:{}",
                        candidate.utterance.session_id, sequence, pending.target_language
                    ),
                    error,
                )
            })?;
        canonical_assembler.record_persisted(&updated.id, updated.revision);
        canonical_matches.insert(
            candidate_key,
            CanonicalUtteranceMatch {
                group_epoch: pending.group_epoch,
                utterance: updated.clone(),
            },
        );
        variant_bindings.insert(pending_key, sequence);
        reverse_variant_bindings.insert(reverse_key, pending_key);
        pending_variants.remove(&pending_key);
        persisted.push(updated);
    }
    Ok(latest_utterance_revisions(persisted))
}

fn resolve_canonical_sequence(
    pending_key: (usize, u64, u64),
    pending: &PendingTranslationVariant,
    canonical_matches: &std::collections::HashMap<(u64, u64), CanonicalUtteranceMatch>,
    variant_bindings: &mut std::collections::HashMap<(usize, u64, u64), u64>,
    reverse_variant_bindings: &mut std::collections::HashMap<(u64, u64, String), (usize, u64, u64)>,
) -> Option<u64> {
    let existing_binding = variant_bindings
        .get(&pending_key)
        .copied()
        .filter(|sequence| {
            canonical_matches
                .get(&(pending.group_epoch, *sequence))
                .is_some_and(|candidate| pending_matches_candidate_identity(pending, candidate))
        });
    if let Some(sequence) = existing_binding {
        return Some(sequence);
    }

    if let Some(stale_sequence) = variant_bindings.remove(&pending_key) {
        let reverse_key = (
            pending.group_epoch,
            stale_sequence,
            pending.target_language.clone(),
        );
        if reverse_variant_bindings.get(&reverse_key) == Some(&pending_key) {
            reverse_variant_bindings.remove(&reverse_key);
        }
    }

    for sequence in ranked_canonical_sequences(pending, canonical_matches.values()) {
        let reverse_key = (
            pending.group_epoch,
            sequence,
            pending.target_language.clone(),
        );
        if reverse_variant_bindings
            .get(&reverse_key)
            .is_none_or(|bound| bound == &pending_key)
        {
            return Some(sequence);
        }
    }
    None
}

#[cfg(test)]
fn match_canonical_sequence<'a>(
    pending: &PendingTranslationVariant,
    candidates: impl Iterator<Item = &'a CanonicalUtteranceMatch>,
) -> Option<u64> {
    ranked_canonical_sequences(pending, candidates)
        .into_iter()
        .next()
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct TimelineAlignmentScore {
    exact_source_text: bool,
    overlap_per_mille: u16,
    source_language_matches: bool,
    midpoint_distance_ms: u64,
    sequence_distance: u64,
    sequence: u64,
}

fn ranked_canonical_sequences<'a>(
    pending: &PendingTranslationVariant,
    candidates: impl Iterator<Item = &'a CanonicalUtteranceMatch>,
) -> Vec<u64> {
    let mut ranked = candidates
        .filter_map(|candidate| {
            timeline_alignment_score(pending, candidate).map(|score| (score, candidate))
        })
        .collect::<Vec<_>>();
    ranked.sort_by(|(left_score, _), (right_score, _)| {
        right_score
            .exact_source_text
            .cmp(&left_score.exact_source_text)
            .then_with(|| {
                right_score
                    .overlap_per_mille
                    .cmp(&left_score.overlap_per_mille)
            })
            .then_with(|| {
                right_score
                    .source_language_matches
                    .cmp(&left_score.source_language_matches)
            })
            .then_with(|| {
                left_score
                    .midpoint_distance_ms
                    .cmp(&right_score.midpoint_distance_ms)
            })
            .then_with(|| {
                left_score
                    .sequence_distance
                    .cmp(&right_score.sequence_distance)
            })
            .then_with(|| left_score.sequence.cmp(&right_score.sequence))
    });
    ranked
        .into_iter()
        .map(|(_, candidate)| candidate.utterance.sequence)
        .collect()
}

fn timeline_alignment_score(
    pending: &PendingTranslationVariant,
    candidate: &CanonicalUtteranceMatch,
) -> Option<TimelineAlignmentScore> {
    if candidate.group_epoch != pending.group_epoch {
        return None;
    }
    let exact_source_text =
        source_texts_match(&pending.source_text, &candidate.utterance.source_text);
    let source_language_matches =
        normalize_language(&candidate.utterance.source_language) == pending.source_language;
    let sequence_distance = candidate
        .utterance
        .sequence
        .abs_diff(pending.source_sequence);

    match (
        pending.source_start_ms,
        pending.source_end_ms,
        candidate.utterance.source_start_ms,
        candidate.utterance.source_end_ms,
    ) {
        (Some(left_start), Some(left_end), Some(right_start), Some(right_end)) => {
            let overlap_per_mille =
                timestamp_overlap_per_mille(left_start, left_end, right_start, right_end)?;
            let left_midpoint = left_start.saturating_add(left_end) / 2;
            let right_midpoint = right_start.saturating_add(right_end) / 2;
            Some(TimelineAlignmentScore {
                exact_source_text,
                overlap_per_mille,
                source_language_matches,
                midpoint_distance_ms: left_midpoint.abs_diff(right_midpoint),
                sequence_distance,
                sequence: candidate.utterance.sequence,
            })
        }
        _ if exact_source_text || candidate.utterance.sequence == pending.source_sequence => {
            Some(TimelineAlignmentScore {
                exact_source_text,
                overlap_per_mille: 0,
                source_language_matches,
                midpoint_distance_ms: u64::MAX,
                sequence_distance,
                sequence: candidate.utterance.sequence,
            })
        }
        _ => None,
    }
}

fn pending_matches_candidate_identity(
    pending: &PendingTranslationVariant,
    candidate: &CanonicalUtteranceMatch,
) -> bool {
    timeline_alignment_score(pending, candidate).is_some()
}

fn source_texts_match(left: &str, right: &str) -> bool {
    let normalize = |value: &str| {
        value
            .chars()
            .filter(|character| !character.is_whitespace())
            .flat_map(char::to_lowercase)
            .collect::<String>()
    };
    let left = normalize(left);
    !left.is_empty() && left == normalize(right)
}

fn timestamp_overlap_per_mille(
    left_start: u64,
    left_end: u64,
    right_start: u64,
    right_end: u64,
) -> Option<u16> {
    if left_end < left_start || right_end < right_start {
        return None;
    }
    let intersection_start = left_start.max(right_start);
    let intersection_end = left_end.min(right_end);
    if intersection_end < intersection_start {
        return None;
    }
    let shorter_duration = left_end
        .saturating_sub(left_start)
        .min(right_end.saturating_sub(right_start));
    if shorter_duration == 0 {
        return Some(1_000);
    }
    let intersection_duration = intersection_end.saturating_sub(intersection_start);
    Some(
        ((u128::from(intersection_duration) * 1_000) / u128::from(shorter_duration)).min(1_000)
            as u16,
    )
}

fn latest_utterance_revisions(updates: Vec<RealtimeUtterance>) -> Vec<RealtimeUtterance> {
    let mut latest = std::collections::HashMap::<u64, RealtimeUtterance>::new();
    for update in updates {
        let replace = latest
            .get(&update.sequence)
            .is_none_or(|current| update.revision >= current.revision);
        if replace {
            latest.insert(update.sequence, update);
        }
    }
    let mut updates = latest.into_values().collect::<Vec<_>>();
    updates.sort_by_key(|utterance| utterance.sequence);
    updates
}

fn record_provider_connected(provider_session_epoch: &mut u64, awaiting_reconnect: &mut bool) {
    if *awaiting_reconnect {
        *provider_session_epoch = provider_session_epoch.saturating_add(1);
        *awaiting_reconnect = false;
    }
}

fn persist_assembled_utterances(
    store: &NotebookCaptureStore,
    assembler: &mut RealtimeUtteranceAssembler,
    updates: Vec<AssembledRealtimeUtterance>,
    provider_session_epoch: u64,
) -> Result<Vec<RealtimeUtterance>, ProviderFailure> {
    let mut persisted_updates = Vec::with_capacity(updates.len());
    for mut update in updates {
        if let Some(provider_label) = update.provider_speaker.as_deref() {
            let speaker = store
                .ensure_session_speaker(
                    &update.utterance.session_id,
                    provider_session_epoch,
                    CURRENT_NOTEBOOK_CAPTURE_ENGINE.provider_id,
                    provider_label,
                )
                .map_err(|error| {
                    local_persistence_failure("persist Soniox session speaker", error)
                })?;
            update.utterance.session_speaker_id = Some(speaker.id);
        }
        let persisted = match store.upsert_utterance(&update.utterance, update.expected_revision) {
            Ok(persisted) => persisted,
            Err(vt_store::NotebookCaptureStoreError::Conflict(_))
                if update.expected_revision.is_some() =>
            {
                // A completed lane may have advanced because the user edited
                // its Loro-backed projection while capture continued. Provider
                // replay is stale in that case: retain the newer durable row
                // instead of turning a valid capture into local_persistence
                // failure. The expected revision still prevents silent writes.
                let current = store
                    .get_utterance_by_id(&update.utterance.id)
                    .map_err(|error| {
                        local_persistence_failure(
                            "reload user-owned utterance after stale provider revision",
                            error,
                        )
                    })?
                    .filter(|current| {
                        current.completion == UtteranceCompletion::Complete
                            && update
                                .expected_revision
                                .is_some_and(|expected| current.revision > expected)
                    })
                    .ok_or_else(|| ProviderFailure {
                        error_type: "local_persistence".to_string(),
                        request_id: None,
                    })?;
                current
            }
            Err(error) => {
                return Err(local_persistence_failure(
                    &format!(
                        "persist ordered Soniox utterance {}:{}",
                        update.utterance.session_id, update.utterance.sequence
                    ),
                    error,
                ));
            }
        };
        assembler.record_persisted(&persisted.id, persisted.revision);
        persisted_updates.push(persisted);
    }
    Ok(persisted_updates)
}

fn local_persistence_failure(operation: &str, error: impl std::fmt::Display) -> ProviderFailure {
    tracing::warn!(
        operation,
        "local capture persistence failed; error detail suppressed from durable state"
    );
    let _ = error;
    ProviderFailure {
        error_type: "local_persistence".to_string(),
        request_id: None,
    }
}

fn prefer_provider_failure(
    current: Option<ProviderFailure>,
    incoming: ProviderFailure,
) -> Option<ProviderFailure> {
    match current {
        None => Some(incoming),
        Some(existing)
            if incoming.error_type == "local_persistence"
                && existing.error_type != "local_persistence" =>
        {
            Some(incoming)
        }
        Some(existing) => Some(existing),
    }
}

fn emit_capture_delta(
    run: NotebookCaptureRun,
    changed_utterances: Vec<RealtimeUtterance>,
    callback: &CaptureCallbackSink,
) {
    // The callback mailbox may coalesce an intermediate delta while Swift is
    // busy. `CaptureCallbackSink` revisions make that loss explicit so Swift
    // performs one bounded full rebuild instead of receiving O(n^2) snapshots.
    callback.send(event_from_run(run, changed_utterances, false));
}

fn emit_live_preview(
    session_id: &str,
    previews: Vec<AssembledRealtimeUtterance>,
    callback: &CaptureCallbackSink,
) {
    callback.send_preview(FfiNotebookCaptureLivePreview {
        session_id: session_id.to_string(),
        preview_revision: 0,
        utterances: previews.into_iter().map(ffi_live_preview).collect(),
    });
}

fn event_full_snapshot_from_run(
    store: &NotebookCaptureStore,
    run: NotebookCaptureRun,
) -> Result<FfiNotebookCaptureEvent, CoreError> {
    let utterances = store
        .list_utterances(&run.session_id)
        .map_err(store_error)?;
    Ok(event_from_run(run, utterances, true))
}

pub(crate) struct CaptureCallbackSink {
    mailbox: Arc<CaptureCallbackMailbox>,
}

struct CaptureCallbackMailbox {
    pending: StdMutex<PendingCaptureCallbacks>,
    wake: Condvar,
    closed: AtomicBool,
    sender_count: AtomicUsize,
    next_revision: AtomicU64,
    next_preview_revision: AtomicU64,
}

#[derive(Default)]
struct PendingCaptureCallbacks {
    event: Option<FfiNotebookCaptureEvent>,
    preview: Option<FfiNotebookCaptureLivePreview>,
}

impl Clone for CaptureCallbackSink {
    fn clone(&self) -> Self {
        self.mailbox.sender_count.fetch_add(1, Ordering::Relaxed);
        Self {
            mailbox: self.mailbox.clone(),
        }
    }
}

impl Drop for CaptureCallbackSink {
    fn drop(&mut self) {
        if self.mailbox.sender_count.fetch_sub(1, Ordering::AcqRel) == 1 {
            self.mailbox.closed.store(true, Ordering::Release);
            self.mailbox.wake.notify_one();
        }
    }
}

impl CaptureCallbackSink {
    fn new(callback: Arc<dyn FfiNotebookCaptureCallback>) -> Result<Self, CoreError> {
        let mailbox = Arc::new(CaptureCallbackMailbox {
            pending: StdMutex::new(PendingCaptureCallbacks::default()),
            wake: Condvar::new(),
            closed: AtomicBool::new(false),
            sender_count: AtomicUsize::new(1),
            next_revision: AtomicU64::new(1),
            next_preview_revision: AtomicU64::new(1),
        });
        let worker_mailbox = mailbox.clone();
        std::thread::Builder::new()
            .name("zulangue-capture-callback".to_string())
            .spawn(move || loop {
                let (event, preview) = {
                    let mut pending = worker_mailbox.pending.lock().unwrap();
                    while pending.event.is_none()
                        && pending.preview.is_none()
                        && !worker_mailbox.closed.load(Ordering::Acquire)
                    {
                        pending = worker_mailbox.wake.wait(pending).unwrap();
                    }
                    let event = pending.event.take();
                    let preview = pending.preview.take();
                    if event.is_none()
                        && preview.is_none()
                        && worker_mailbox.closed.load(Ordering::Acquire)
                    {
                        break;
                    }
                    (event, preview)
                };
                if std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                    if let Some(event) = event {
                        callback.on_capture_event(event);
                    }
                    if let Some(preview) = preview {
                        callback.on_live_preview(preview);
                    }
                }))
                .is_err()
                {
                    tracing::error!("Notebook capture callback panicked; dispatcher stopped");
                    worker_mailbox.closed.store(true, Ordering::Release);
                    break;
                }
            })
            .map_err(|error| CoreError::InternalError {
                message: format!("start capture callback dispatcher: {error}"),
            })?;
        Ok(Self { mailbox })
    }

    fn send(&self, mut event: FfiNotebookCaptureEvent) -> FfiNotebookCaptureEvent {
        let mut pending = self.mailbox.pending.lock().unwrap();
        event.event_revision = self.mailbox.next_revision.fetch_add(1, Ordering::Relaxed);
        if self.mailbox.closed.load(Ordering::Acquire) {
            tracing::warn!("Notebook capture callback dispatcher is closed");
            return event;
        }
        pending.event = Some(event.clone());
        drop(pending);
        self.mailbox.wake.notify_one();
        event
    }

    fn send_preview(
        &self,
        mut preview: FfiNotebookCaptureLivePreview,
    ) -> FfiNotebookCaptureLivePreview {
        let mut pending = self.mailbox.pending.lock().unwrap();
        preview.preview_revision = self
            .mailbox
            .next_preview_revision
            .fetch_add(1, Ordering::Relaxed);
        if self.mailbox.closed.load(Ordering::Acquire) {
            tracing::warn!("Notebook capture callback dispatcher is closed");
            return preview;
        }
        // The speculative tail is a complete replacement snapshot, so keeping
        // only the newest value is lossless and provides natural backpressure.
        pending.preview = Some(preview.clone());
        drop(pending);
        self.mailbox.wake.notify_one();
        preview
    }
}

fn provider_failure(error: &SttStreamError) -> ProviderFailure {
    match error {
        SttStreamError::Provider(error) => ProviderFailure {
            error_type: sanitize_provider_metadata(&error.error_type, "provider_error"),
            request_id: error
                .request_id
                .as_deref()
                .map(|value| sanitize_provider_metadata(value, "unknown")),
        },
        SttStreamError::Transport { .. } => ProviderFailure {
            error_type: "transport".to_string(),
            request_id: None,
        },
        SttStreamError::Protocol { .. } => ProviderFailure {
            error_type: "protocol".to_string(),
            request_id: None,
        },
        SttStreamError::Timeout { .. } => ProviderFailure {
            error_type: "timeout".to_string(),
            request_id: None,
        },
        SttStreamError::Closed { .. } => ProviderFailure {
            error_type: "closed".to_string(),
            request_id: None,
        },
    }
}

fn sanitize_provider_metadata(value: &str, fallback: &str) -> String {
    let sanitized: String = value
        .chars()
        .take(128)
        .map(|character| {
            if character.is_ascii_alphanumeric() || matches!(character, '-' | '_' | '.') {
                character
            } else {
                '_'
            }
        })
        .collect();
    if sanitized.is_empty() {
        fallback.to_string()
    } else {
        sanitized
    }
}

impl RealtimeUtteranceAssembler {
    fn new(session_id: String, profile: &NotebookCaptureProfile) -> Self {
        Self {
            session_id,
            selected_languages: profile
                .selected_languages
                .iter()
                .map(|language| normalize_language(language))
                .collect(),
            capture_mode: profile.capture_mode,
            common_caption_language: profile
                .common_caption_language
                .as_deref()
                .map(normalize_language),
            next_sequence: 0,
            segments: Vec::new(),
            latest_original_segment: None,
            latest_translation_segment: None,
            unattached_translation_tokens: 0,
        }
    }

    fn apply_tokens(&mut self, tokens: &[SttStreamToken]) -> Vec<AssembledRealtimeUtterance> {
        // Soniox non-final tokens are a complete revision for the current
        // response, not per-lane deltas. Clear every speculative tail before
        // applying the replacement response while retaining final tokens.
        for segment in &mut self.segments {
            segment.begin_response_revision();
        }

        // Build every source candidate first. Translation tokens do not carry
        // source timing, so response order alone is not a safe attachment key
        // when several speakers overlap.
        for token in tokens {
            match &token.translation_status {
                SttStreamTranslationStatus::Original | SttStreamTranslationStatus::None => {
                    self.apply_original_token(token);
                }
                SttStreamTranslationStatus::Translation
                // An invalid provider role must not silently become
                // source speech. The next recognized response can still revise
                // the speculative tails cleared above.
                | SttStreamTranslationStatus::Unknown(_) => {}
            }
        }

        for token in tokens {
            if matches!(
                token.translation_status,
                SttStreamTranslationStatus::Translation
            ) {
                self.apply_translation_token(token);
            }
        }

        self.take_dirty_updates()
    }

    fn apply_original_token(&mut self, token: &SttStreamToken) {
        let language = normalized_optional_language(
            token
                .language
                .as_deref()
                .or(token.source_language.as_deref()),
        );
        let provider_speaker = normalized_provider_speaker(token.speaker.as_deref());
        let segment_index = self.source_segment_for_token(
            token.is_final,
            language.as_deref(),
            provider_speaker.as_deref(),
        );
        let segment = &mut self.segments[segment_index];
        segment.source.push(token, language);
        if token.is_final {
            if provider_speaker.is_some() {
                segment.committed_provider_speaker = provider_speaker;
            }
        } else if let Some(provider_speaker) = provider_speaker {
            match segment.pending_provider_speaker.as_deref() {
                Some(current) if current != provider_speaker => {
                    segment.pending_provider_speaker_ambiguous = true;
                }
                None => segment.pending_provider_speaker = Some(provider_speaker),
                Some(_) => {}
            }
        }
        let (start, end) = if token.is_final {
            (
                &mut segment.committed_source_start_ms,
                &mut segment.committed_source_end_ms,
            )
        } else {
            (
                &mut segment.pending_source_start_ms,
                &mut segment.pending_source_end_ms,
            )
        };
        if let Some(next) = token.start_ms {
            *start = Some(start.map_or(next, |current| current.min(next)));
        }
        if let Some(next) = token.end_ms {
            *end = Some(end.map_or(next, |current| current.max(next)));
        }
        segment.dirty = true;
        self.latest_original_segment = Some(segment_index);
    }

    fn source_segment_for_token(
        &mut self,
        is_final: bool,
        language: Option<&str>,
        provider_speaker: Option<&str>,
    ) -> usize {
        let current = self
            .latest_original_segment
            .filter(|index| !self.segments[*index].complete);
        let Some(current) = current else {
            if let Some(provider_speaker) = provider_speaker {
                if let Some(index) = self.segments.iter().rposition(|segment| {
                    !segment.complete
                        && !segment.has_source_text()
                        && segment.matching_provider_speaker() == Some(provider_speaker)
                }) {
                    return index;
                }
            }
            return self.create_segment();
        };

        if is_final
            && self.segments[current].has_source_text()
            && (identity_conflicts(self.segments[current].stable_source_language(), language)
                || identity_conflicts(
                    self.segments[current].stable_provider_speaker(),
                    provider_speaker,
                ))
        {
            self.segments[current].complete = true;
            self.segments[current].dirty = true;
            return self.create_segment();
        }

        current
    }

    fn apply_translation_token(&mut self, token: &SttStreamToken) {
        let provider_speaker = normalized_provider_speaker(token.speaker.as_deref());
        let source_language = normalized_optional_language(token.source_language.as_deref());
        let Some(segment_index) =
            self.translation_segment(provider_speaker.as_deref(), source_language.as_deref())
        else {
            self.unattached_translation_tokens =
                self.unattached_translation_tokens.saturating_add(1);
            // Truly anonymous tokens can still be ambiguous during overlapping
            // speech. Do not invent an utterance, but retain a content-free
            // counter so this path is observable instead of silently failing.
            return;
        };
        self.latest_translation_segment = Some(segment_index);
        let segment = &mut self.segments[segment_index];
        let translated_language = normalized_optional_language(token.language.as_deref());
        segment.translated.push(token, translated_language);

        if let Some(source_language) = source_language {
            if token.is_final {
                segment.committed_source_language_hint = Some(source_language);
            } else {
                segment.pending_source_language_hint = Some(source_language);
            }
        }
        if let Some(provider_speaker) = provider_speaker {
            if token.is_final {
                segment.committed_provider_speaker_hint = Some(provider_speaker);
            } else {
                segment.pending_provider_speaker_hint = Some(provider_speaker);
            }
        }
        segment.dirty = true;
    }

    fn translation_segment(
        &self,
        provider_speaker: Option<&str>,
        source_language: Option<&str>,
    ) -> Option<usize> {
        let compatible = self
            .segments
            .iter()
            .enumerate()
            .filter_map(|(index, segment)| {
                if !segment.has_source_text()
                    || !optional_identity_compatible(
                        segment.matching_provider_speaker(),
                        provider_speaker,
                    )
                    || !optional_identity_compatible(
                        segment.matching_source_language(),
                        source_language,
                    )
                {
                    return None;
                }
                Some(index)
            })
            .collect::<Vec<_>>();
        match compatible.as_slice() {
            [] => None,
            [only] => Some(*only),
            _ if provider_speaker.is_none() || source_language.is_none() => None,
            _ => {
                if let Some(current) = self.latest_translation_segment {
                    if compatible.contains(&current) {
                        return Some(current);
                    }
                    if let Some(next) = compatible.iter().find(|index| **index > current) {
                        return Some(*next);
                    }
                }
                // With complete speaker and source-language identity, provider
                // response order is the remaining association signal. This
                // handles one speaker switching en -> zh -> en inside one
                // endpoint without discarding the second English translation.
                compatible.first().copied()
            }
        }
    }

    fn create_segment(&mut self) -> usize {
        let sequence = self.next_sequence;
        self.next_sequence = self.next_sequence.saturating_add(1);
        self.segments
            .push(RealtimeSegmentRevision::new(&self.session_id, sequence));
        self.segments.len() - 1
    }

    fn finalize(&mut self) -> Vec<AssembledRealtimeUtterance> {
        if self.unattached_translation_tokens > 0 {
            tracing::warn!(
                count = self.unattached_translation_tokens,
                "Soniox translation tokens could not be attached to the authoritative timeline"
            );
        }
        let mut detached_pending = Vec::new();
        for segment in &mut self.segments {
            if segment.source.pending.is_empty()
                || segment.pending_source_matches_committed_identity()
            {
                continue;
            }
            detached_pending.push((
                segment.source.take_pending(),
                segment.translated.take_pending(),
                segment.pending_provider_speaker.take(),
                std::mem::take(&mut segment.pending_provider_speaker_ambiguous),
                segment.pending_source_language_hint.take(),
                segment.pending_provider_speaker_hint.take(),
                segment.pending_source_start_ms.take(),
                segment.pending_source_end_ms.take(),
            ));
            segment.dirty = true;
        }
        for (
            source,
            translated,
            pending_provider_speaker,
            pending_provider_speaker_ambiguous,
            pending_source_language_hint,
            pending_provider_speaker_hint,
            pending_source_start_ms,
            pending_source_end_ms,
        ) in detached_pending
        {
            let index = self.create_segment();
            let segment = &mut self.segments[index];
            segment.source = source;
            segment.translated = translated;
            segment.pending_provider_speaker = pending_provider_speaker;
            segment.pending_provider_speaker_ambiguous = pending_provider_speaker_ambiguous;
            segment.pending_source_language_hint = pending_source_language_hint;
            segment.pending_provider_speaker_hint = pending_provider_speaker_hint;
            segment.pending_source_start_ms = pending_source_start_ms;
            segment.pending_source_end_ms = pending_source_end_ms;
            segment.complete = true;
            segment.dirty = true;
        }
        for segment in &mut self.segments {
            if !segment.is_empty() && !segment.complete {
                segment.complete = true;
                segment.dirty = true;
            }
        }
        self.take_dirty_updates()
    }

    fn advance(&mut self) {
        self.segments.clear();
        self.latest_original_segment = None;
        self.latest_translation_segment = None;
        self.unattached_translation_tokens = 0;
    }

    fn record_persisted(&mut self, id: &str, revision: u64) {
        if let Some(segment) = self.segments.iter_mut().find(|segment| segment.id == id) {
            segment.revision = Some(revision);
        }
    }

    fn take_dirty_updates(&mut self) -> Vec<AssembledRealtimeUtterance> {
        let session_id = self.session_id.clone();
        let selected_languages = self.selected_languages.clone();
        let capture_mode = self.capture_mode;
        let common_caption_language = self.common_caption_language.clone();
        self.segments
            .iter_mut()
            .filter_map(|segment| {
                if !segment.dirty {
                    return None;
                }
                segment.dirty = false;
                // Keep a pure provisional run out of the language columns.
                // It will use the same segment ID once final source evidence
                // arrives, or be emitted as a neutral `und` fact if an
                // endpoint/reconnect forces finalization first.
                if !segment.complete && segment.stable_source_language().is_none() {
                    return None;
                }
                if segment.is_empty() && segment.revision.is_none() {
                    return None;
                }
                Some(assemble_segment(
                    &session_id,
                    &selected_languages,
                    capture_mode,
                    common_caption_language.as_deref(),
                    segment,
                ))
            })
            .collect()
    }

    /// Complete process-local replacement view of every unfinished canonical
    /// segment. This never mutates the assembler and never crosses into the
    /// durable utterance store.
    fn live_previews(&self) -> Vec<AssembledRealtimeUtterance> {
        let session_id = self.session_id.clone();
        let selected_languages = self.selected_languages.clone();
        let capture_mode = self.capture_mode;
        let common_caption_language = self.common_caption_language.clone();
        self.segments
            .iter()
            .filter(|segment| !segment.complete && !segment.is_empty())
            .map(|segment| {
                assemble_segment(
                    &session_id,
                    &selected_languages,
                    capture_mode,
                    common_caption_language.as_deref(),
                    segment,
                )
            })
            .collect()
    }
}

fn assemble_segment(
    session_id: &str,
    selected_languages: &std::collections::HashSet<String>,
    capture_mode: CaptureMode,
    common_caption_language: Option<&str>,
    segment: &RealtimeSegmentRevision,
) -> AssembledRealtimeUtterance {
    let include_pending_source = segment.pending_source_matches_committed_identity();
    let source_language = segment.source_language();
    let source_is_unknown = source_language == "und";
    let source_is_selected = selected_languages.contains(&source_language);
    let outside_pair = !source_is_unknown && !source_is_selected;
    let include_pending_translation = !identity_conflicts(
        segment.translated.committed_language.as_deref(),
        segment.translated.unambiguous_pending_language(),
    );
    let translated_language_candidate = segment
        .translated
        .committed_language
        .as_deref()
        .or(segment.translated.unambiguous_pending_language());
    let translation_is_expected = match capture_mode {
        CaptureMode::TranscriptionOnly => false,
        CaptureMode::TwoWay => source_is_selected && !source_is_unknown,
        CaptureMode::MultilingualOneWay => {
            source_is_selected
                && !source_is_unknown
                && common_caption_language.is_some_and(|target| target != source_language)
        }
    };
    let translation_is_pairable = translation_is_expected
        && translated_language_candidate.is_some_and(|language| match capture_mode {
            CaptureMode::TranscriptionOnly => false,
            CaptureMode::TwoWay => {
                language != source_language && selected_languages.contains(language)
            }
            CaptureMode::MultilingualOneWay => common_caption_language == Some(language),
        });
    let translated_text = translation_is_pairable
        .then(|| segment.translated.text(include_pending_translation))
        .filter(|text| !text.is_empty());
    let translated_language = translated_text
        .as_ref()
        .and(translated_language_candidate)
        .map(str::to_string);
    let alignment = if translated_text.is_some() {
        UtteranceAlignment::Paired
    } else if outside_pair {
        UtteranceAlignment::OutsideLanguagePair
    } else if translation_is_expected && !segment.complete {
        UtteranceAlignment::TranslationPending
    } else {
        UtteranceAlignment::SourceOnly
    };
    let pending_start = include_pending_source
        .then_some(segment.pending_source_start_ms)
        .flatten();
    let pending_end = include_pending_source
        .then_some(segment.pending_source_end_ms)
        .flatten();
    let source_start_ms = match (segment.committed_source_start_ms, pending_start) {
        (Some(committed), Some(pending)) => Some(committed.min(pending)),
        (committed, pending) => committed.or(pending),
    };
    let source_end_ms = match (segment.committed_source_end_ms, pending_end) {
        (Some(committed), Some(pending)) => Some(committed.max(pending)),
        (committed, pending) => committed.or(pending),
    };
    AssembledRealtimeUtterance {
        utterance: NewRealtimeUtterance {
            id: segment.id.clone(),
            session_id: session_id.to_string(),
            sequence: segment.sequence,
            session_speaker_id: None,
            source_language,
            source_text: segment.source.text(include_pending_source),
            source_start_ms,
            source_end_ms,
            translated_language,
            translated_text,
            completion: if segment.complete {
                UtteranceCompletion::Complete
            } else {
                UtteranceCompletion::Partial
            },
            alignment,
        },
        provider_speaker: segment.durable_provider_speaker().map(str::to_string),
        expected_revision: segment.revision,
    }
}

fn identity_conflicts(current: Option<&str>, incoming: Option<&str>) -> bool {
    matches!(
        (current.filter(|value| *value != "und"), incoming.filter(|value| *value != "und")),
        (Some(current), Some(incoming)) if current != incoming
    )
}

fn optional_identity_compatible(current: Option<&str>, incoming: Option<&str>) -> bool {
    !identity_conflicts(current, incoming)
}

fn normalized_optional_language(value: Option<&str>) -> Option<String> {
    value
        .map(normalize_language)
        .filter(|language| !language.is_empty() && language != "und")
}

fn normalized_provider_speaker(value: Option<&str>) -> Option<String> {
    value
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
}

fn normalize_language(value: &str) -> String {
    value
        .split('-')
        .next()
        .unwrap_or(value)
        .trim()
        .to_ascii_lowercase()
}

fn require_single_file_name(value: &str) -> Result<(), CoreError> {
    let path = std::path::Path::new(value);
    if value.is_empty()
        || path.components().count() != 1
        || path.file_name().and_then(|name| name.to_str()) != Some(value)
    {
        return Err(CoreError::ValidationFailed {
            message: format!("invalid canonical capture artifact name: {value}"),
        });
    }
    Ok(())
}

fn require_single_file_prefix(value: &str) -> Result<(), CoreError> {
    if value.is_empty()
        || value.contains(std::path::MAIN_SEPARATOR)
        || value == "."
        || value == ".."
    {
        return Err(CoreError::ValidationFailed {
            message: format!("invalid canonical capture artifact prefix: {value}"),
        });
    }
    Ok(())
}

fn require_path_within_data_dir(
    data_dir: &std::path::Path,
    candidate: &std::path::Path,
) -> Result<(), CoreError> {
    if candidate
        .components()
        .any(|component| component == std::path::Component::ParentDir)
        || !candidate.starts_with(data_dir)
    {
        return Err(CoreError::ValidationFailed {
            message: format!(
                "refusing to delete capture artifact outside Zulangue data directory: {}",
                candidate.display()
            ),
        });
    }
    Ok(())
}

fn purge_phase_rank(phase: &str) -> Result<u8, CoreError> {
    match phase {
        "prepared" => Ok(0),
        "task_handlers_stopped" => Ok(1),
        "loro_removed" => Ok(2),
        "tasks_removed" => Ok(3),
        "external_artifacts_removed" => Ok(4),
        "main_database_removed" => Ok(5),
        "purge_receipts_removed" => Ok(6),
        other => Err(CoreError::ValidationFailed {
            message: format!("unknown durable session purge phase: {other}"),
        }),
    }
}

#[allow(dead_code)]
pub(crate) struct ActiveNotebookCapture {
    pub(crate) notebook_id: String,
    pub(crate) session_id: String,
    pub(crate) run_id: String,
    pub(crate) profile: NotebookCaptureProfile,
    pub(crate) state: CaptureState,
    pub(crate) callback: CaptureCallbackSink,
    pub(crate) journal: vt_pipeline::CaptureAudioJournal,
    pub(crate) last_persisted_frames: u64,
    pub(crate) remote: Option<ActiveRemoteCapture>,
    /// Backpressure cancels the provider writer immediately, but the sole
    /// event persistence task may need bounded time to drain. Keeping its join
    /// handle on the capture prevents a late writer from crossing stop,
    /// interrupt, push-failure teardown, or final projection.
    pub(crate) remote_cleanup: Option<tokio::task::JoinHandle<Option<ProviderFailure>>>,
}

/// Injectable boundary around construction and PCM delivery for the Notebook
/// Soniox stream. Production always installs [`RealNotebookSonioxStreamFactory`];
/// tests can replace it without changing the public UniFFI surface or making a
/// network connection.
pub(crate) trait NotebookSonioxStreamFactory: Send + Sync {
    fn start(
        &self,
        endpoint: &str,
        api_key: String,
        config: SttConfig,
        cancel: tokio_util::sync::CancellationToken,
    ) -> SonioxStreamRuntime;

    fn try_send_pcm(
        &self,
        audio_tx: &tokio::sync::mpsc::Sender<Vec<u8>>,
        audio_data: Vec<u8>,
    ) -> Result<(), String>;
}

pub(crate) struct RealNotebookSonioxStreamFactory;

impl NotebookSonioxStreamFactory for RealNotebookSonioxStreamFactory {
    fn start(
        &self,
        endpoint: &str,
        api_key: String,
        config: SttConfig,
        cancel: tokio_util::sync::CancellationToken,
    ) -> SonioxStreamRuntime {
        SonioxStreamClient::start(endpoint, api_key, config, cancel)
    }

    fn try_send_pcm(
        &self,
        audio_tx: &tokio::sync::mpsc::Sender<Vec<u8>>,
        audio_data: Vec<u8>,
    ) -> Result<(), String> {
        audio_tx
            .try_send(audio_data)
            .map_err(|error| error.to_string())
    }
}

#[allow(dead_code)]
pub(crate) struct ActiveRemoteStream {
    descriptor: RemoteStreamLane,
    pub(crate) audio_tx: tokio::sync::mpsc::Sender<Vec<u8>>,
    pub(crate) control_tx: tokio::sync::mpsc::Sender<vt_stt::SttStreamControl>,
    pub(crate) stream_task: tokio::task::JoinHandle<Result<(), vt_stt::SttError>>,
    pub(crate) forward_task: tokio::task::JoinHandle<()>,
}

#[allow(dead_code)]
pub(crate) struct ActiveRemoteCapture {
    pub(crate) stream_factory: Arc<dyn NotebookSonioxStreamFactory>,
    pub(crate) streams: Vec<ActiveRemoteStream>,
    pub(crate) cancel: tokio_util::sync::CancellationToken,
    pub(crate) event_task: tokio::task::JoinHandle<Result<(), ProviderFailure>>,
}

impl ActiveRemoteCapture {
    fn try_fanout_pcm(&self, audio_data: &[u8]) -> Result<(), String> {
        if self.streams.is_empty()
            || self
                .streams
                .iter()
                .any(|stream| stream.audio_tx.is_closed() || stream.audio_tx.capacity() == 0)
        {
            return Err("Soniox stream group audio unavailable".to_string());
        }
        for stream in &self.streams {
            self.stream_factory
                .try_send_pcm(&stream.audio_tx, audio_data.to_vec())?;
        }
        Ok(())
    }

    fn try_fanout_control(&self, control: SttStreamControl) -> Result<(), String> {
        if self.streams.is_empty()
            || self
                .streams
                .iter()
                .any(|stream| stream.control_tx.is_closed() || stream.control_tx.capacity() == 0)
        {
            return Err("Soniox stream group control unavailable".to_string());
        }
        for stream in &self.streams {
            stream
                .control_tx
                .try_send(control)
                .map_err(|error| error.to_string())?;
        }
        Ok(())
    }
}

async fn forward_stream_events(
    lane_index: usize,
    mut event_rx: tokio::sync::mpsc::Receiver<SttStreamEvent>,
    tagged_tx: tokio::sync::mpsc::Sender<TaggedStreamEvent>,
) {
    while let Some(event) = event_rx.recv().await {
        if tagged_tx
            .send(TaggedStreamEvent { lane_index, event })
            .await
            .is_err()
        {
            break;
        }
    }
}

async fn join_cancelled_remote_group(
    mut streams: Vec<ActiveRemoteStream>,
    mut event_task: tokio::task::JoinHandle<Result<(), ProviderFailure>>,
    timeout: std::time::Duration,
) -> Option<ProviderFailure> {
    let deadline = tokio::time::Instant::now() + timeout;
    for stream in &streams {
        stream.stream_task.abort();
    }
    for stream in &mut streams {
        let _ = (&mut stream.stream_task).await;
    }

    let forward_result = tokio::time::timeout_at(
        deadline,
        futures::future::join_all(streams.iter_mut().map(|stream| &mut stream.forward_task)),
    )
    .await;
    let mut failure = match forward_result {
        Ok(results) if results.iter().all(Result::is_ok) => None,
        Ok(_) => Some(ProviderFailure {
            error_type: "event_forward_task_failed".to_string(),
            request_id: None,
        }),
        Err(_) => {
            for stream in &streams {
                stream.forward_task.abort();
            }
            for stream in &mut streams {
                let _ = (&mut stream.forward_task).await;
            }
            Some(ProviderFailure {
                error_type: "event_forward_drain_timeout".to_string(),
                request_id: None,
            })
        }
    };

    match tokio::time::timeout_at(deadline, &mut event_task).await {
        Ok(Ok(Ok(()))) => {}
        Ok(Ok(Err(event_failure))) => {
            failure = prefer_provider_failure(failure, event_failure);
        }
        Ok(Err(_error)) => {
            failure.get_or_insert_with(|| ProviderFailure {
                error_type: "event_task_failed".to_string(),
                request_id: None,
            });
        }
        Err(_) => {
            event_task.abort();
            let _ = event_task.await;
            failure.get_or_insert_with(|| ProviderFailure {
                error_type: "event_drain_timeout".to_string(),
                request_id: None,
            });
        }
    }
    failure
}

#[uniffi::export]
impl ZulangueCore {
    pub fn get_notebook_capture_engine_descriptor(&self) -> FfiNotebookCaptureEngineDescriptor {
        CURRENT_NOTEBOOK_CAPTURE_ENGINE.into()
    }

    pub fn get_notebook_capture_profile(
        &self,
        notebook_id: String,
    ) -> Result<FfiNotebookCaptureProfile, CoreError> {
        self.notebook_capture_store
            .get_or_create_profile(&notebook_id)
            .map(Into::into)
            .map_err(store_error)
    }

    pub fn update_notebook_capture_profile(
        &self,
        profile: FfiNotebookCaptureProfile,
    ) -> Result<FfiNotebookCaptureProfile, CoreError> {
        let update = profile_update_from_ffi(&profile);
        self.notebook_capture_store
            .update_profile(&profile.notebook_id, profile.revision, &update)
            .map(Into::into)
            .map_err(store_error)
    }

    pub fn preview_notebook_capture_context(
        &self,
        notebook_id: String,
    ) -> Result<FfiNotebookCaptureContextPreview, CoreError> {
        let compilation = self
            .context_pack_store
            .compile_notebook_context(&notebook_id)
            .map_err(store_error)?;
        let confirmation_digest = context_confirmation_digest(&compilation)?;
        let sources = compilation
            .receipt
            .sources
            .iter()
            .map(|source| {
                let source_omissions = compilation
                    .receipt
                    .omissions
                    .iter()
                    .filter(|omission| omission.source_id == source.source_id)
                    .map(format_context_omission)
                    .collect::<Vec<_>>();
                FfiNotebookCaptureContextSource {
                    id: source.source_id.clone(),
                    title: source.source_title.clone(),
                    pack_kind: match source.pack_scope {
                        ContextPackScope::Private => "private",
                        ContextPackScope::Library => "library",
                    }
                    .to_string(),
                    scalar_count: source.included_scalars,
                    included: source.included_items > 0,
                    reason: (!source_omissions.is_empty()).then(|| source_omissions.join("; ")),
                }
            })
            .collect();
        let omitted_reasons = compilation
            .receipt
            .omissions
            .iter()
            .map(format_context_omission)
            .collect();
        Ok(FfiNotebookCaptureContextPreview {
            notebook_id,
            serialized_context: compilation.context_json,
            sources,
            omitted_reasons,
            digest: confirmation_digest,
            scalar_count: compilation.receipt.serialized_scalars,
        })
    }

    /// Private Pack first, followed by all Library Packs with their current
    /// binding position (or `None` when available but unbound).
    pub fn list_notebook_context_packs(
        &self,
        notebook_id: String,
    ) -> Result<Vec<FfiContextPackInfo>, CoreError> {
        let private = self
            .context_pack_store
            .ensure_private_pack(&notebook_id, None)
            .map_err(store_error)?;
        let bound = self
            .context_pack_store
            .list_bound_library_packs(&notebook_id)
            .map_err(store_error)?
            .into_iter()
            .map(|value| (value.pack.id, value.position))
            .collect::<std::collections::HashMap<_, _>>();
        let mut result = vec![context_pack_info(private, None)];
        result.extend(
            self.context_pack_store
                .list_library_packs()
                .map_err(store_error)?
                .into_iter()
                .map(|pack| {
                    let position = bound.get(&pack.id).copied();
                    context_pack_info(pack, position)
                }),
        );
        Ok(result)
    }

    pub fn create_library_context_pack(
        &self,
        title: String,
    ) -> Result<FfiContextPackInfo, CoreError> {
        self.context_pack_store
            .create_library_pack(&title)
            .map(|pack| context_pack_info(pack, None))
            .map_err(store_error)
    }

    pub fn copy_notebook_private_context_to_library(
        &self,
        notebook_id: String,
        title: String,
    ) -> Result<FfiContextPackInfo, CoreError> {
        let private = self
            .context_pack_store
            .ensure_private_pack(&notebook_id, None)
            .map_err(store_error)?;
        self.context_pack_store
            .copy_pack_to_library(&private.id, &title)
            .map(|pack| context_pack_info(pack, None))
            .map_err(store_error)
    }

    pub fn set_notebook_context_pack_binding(
        &self,
        notebook_id: String,
        pack_id: String,
        position: Option<u64>,
    ) -> Result<(), CoreError> {
        match position {
            Some(position) => self
                .context_pack_store
                .bind_library_pack(&notebook_id, &pack_id, position)
                .map_err(store_error),
            None => self
                .context_pack_store
                .unbind_library_pack(&notebook_id, &pack_id)
                .map(|_| ())
                .map_err(store_error),
        }
    }

    pub fn list_context_pack_sources(
        &self,
        notebook_id: String,
        pack_id: String,
    ) -> Result<Vec<FfiContextPackSourceInfo>, CoreError> {
        require_context_pack_access(&self.context_pack_store, &notebook_id, &pack_id)?;
        self.context_pack_store
            .list_sources(&pack_id)
            .map(|sources| sources.into_iter().map(context_source_info).collect())
            .map_err(store_error)
    }

    pub fn import_context_pack_text(
        &self,
        notebook_id: String,
        pack_id: String,
        title: String,
        text: String,
        content_kind: String,
    ) -> Result<FfiContextPackSourceInfo, CoreError> {
        require_context_pack_access(&self.context_pack_store, &notebook_id, &pack_id)?;
        let kind = parse_context_kind(&content_kind)?;
        if kind == ContextContentKind::TranslationTerms {
            return Err(CoreError::ValidationFailed {
                message: "translation_terms must be imported from a bilingual CSV".to_string(),
            });
        }
        self.context_pack_store
            .import_source(
                &pack_id,
                &NewContextSource {
                    title,
                    format: ContextSourceFormat::Text,
                    content_kind: kind,
                    content: text.into_bytes(),
                    metadata: serde_json::json!({"origin": "paste"}),
                },
            )
            .map(context_source_info)
            .map_err(store_error)
    }

    pub fn import_context_pack_file(
        &self,
        notebook_id: String,
        pack_id: String,
        path: String,
        content_kind: String,
    ) -> Result<FfiContextPackSourceInfo, CoreError> {
        require_context_pack_access(&self.context_pack_store, &notebook_id, &pack_id)?;
        let path = std::path::PathBuf::from(path);
        let extension = path
            .extension()
            .and_then(|value| value.to_str())
            .unwrap_or_default()
            .to_ascii_lowercase();
        let (format, kind) = match extension.as_str() {
            "txt" => (
                ContextSourceFormat::Text,
                parse_context_kind(&content_kind)?,
            ),
            "md" => (
                ContextSourceFormat::Markdown,
                parse_context_kind(&content_kind)?,
            ),
            "csv" => (
                ContextSourceFormat::TranslationCsv,
                ContextContentKind::TranslationTerms,
            ),
            _ => {
                return Err(CoreError::ValidationFailed {
                    message: "Context Pack files must be UTF-8 .txt, .md, or bilingual .csv"
                        .to_string(),
                })
            }
        };
        if format != ContextSourceFormat::TranslationCsv
            && kind == ContextContentKind::TranslationTerms
        {
            return Err(CoreError::ValidationFailed {
                message: "translation_terms require .csv".to_string(),
            });
        }
        let byte_limit = if format == ContextSourceFormat::TranslationCsv {
            CONTEXT_CSV_FILE_MAX_BYTES
        } else {
            CONTEXT_TEXT_FILE_MAX_BYTES
        };
        let file = std::fs::File::open(&path).map_err(|error| CoreError::ValidationFailed {
            message: format!("open Context Pack file: {error}"),
        })?;
        let metadata = file
            .metadata()
            .map_err(|error| CoreError::ValidationFailed {
                message: format!("inspect Context Pack file: {error}"),
            })?;
        if !metadata.is_file() || metadata.len() > byte_limit {
            return Err(CoreError::ValidationFailed {
                message: format!("Context Pack file exceeds the {byte_limit}-byte safety limit"),
            });
        }
        let mut content = Vec::with_capacity(metadata.len() as usize);
        file.take(byte_limit + 1)
            .read_to_end(&mut content)
            .map_err(|error| CoreError::ValidationFailed {
                message: format!("read Context Pack file: {error}"),
            })?;
        if content.len() as u64 > byte_limit {
            return Err(CoreError::ValidationFailed {
                message: format!("Context Pack file exceeds the {byte_limit}-byte safety limit"),
            });
        }
        let title = path
            .file_name()
            .and_then(|value| value.to_str())
            .unwrap_or("Imported Context")
            .to_string();
        self.context_pack_store
            .import_source(
                &pack_id,
                &NewContextSource {
                    title,
                    format,
                    content_kind: kind,
                    content,
                    metadata: serde_json::json!({"origin": "file"}),
                },
            )
            .map(context_source_info)
            .map_err(store_error)
    }

    pub fn delete_context_pack_source(
        &self,
        notebook_id: String,
        source_id: String,
    ) -> Result<bool, CoreError> {
        let source = self
            .context_pack_store
            .get_source(&source_id)
            .map_err(store_error)?
            .ok_or_else(|| CoreError::NotFound {
                message: format!("Context source {source_id}"),
            })?;
        require_context_pack_access(&self.context_pack_store, &notebook_id, &source.pack_id)?;
        self.context_pack_store
            .delete_source(&source_id)
            .map_err(store_error)
    }

    pub fn delete_library_context_pack(
        &self,
        pack_id: String,
        expected_revision: u64,
    ) -> Result<bool, CoreError> {
        self.context_pack_store
            .delete_library_pack(&pack_id, expected_revision)
            .map_err(store_error)
    }

    pub fn start_notebook_capture_session(
        &self,
        notebook_id: String,
        profile_revision: u64,
        confirmed_context_digest: Option<String>,
        callback: Box<dyn FfiNotebookCaptureCallback>,
    ) -> Result<FfiNotebookCaptureEvent, CoreError> {
        let _ownership_guard = self.capture_ownership_gate.lock().unwrap();
        // Hold the shared gate until publication so concurrent entrypoints
        // cannot both pass the global microphone-owner check.
        self.ensure_capture_ownership_available()?;
        self.retry_detached_notebook_capture_recovery()?;

        let profile = self
            .notebook_capture_store
            .get_or_create_profile(&notebook_id)
            .map_err(store_error)?;
        if profile.revision != profile_revision {
            return Err(CoreError::ValidationFailed {
                message: format!(
                    "capture_profile_revision_conflict: expected {profile_revision}, current {}",
                    profile.revision
                ),
            });
        }
        if profile.capture_mode != CaptureMode::TranscriptionOnly
            && !profile.remote_realtime_enabled
        {
            return Err(CoreError::ValidationFailed {
                message: "translation_requires_remote_realtime".to_string(),
            });
        }
        if profile.send_context_to_soniox && !profile.remote_realtime_enabled {
            return Err(CoreError::ValidationFailed {
                message: "context_egress_requires_remote_realtime".to_string(),
            });
        }
        let context_compilation = if profile.send_context_to_soniox {
            let compilation = self
                .context_pack_store
                .compile_notebook_context(&notebook_id)
                .map_err(store_error)?;
            let confirmed = confirmed_context_digest.as_deref().ok_or_else(|| {
                CoreError::ValidationFailed {
                    message: "context_confirmation_required: preview and confirm the exact Context Pack snapshot"
                        .to_string(),
                }
            })?;
            let current_confirmation = context_confirmation_digest(&compilation)?;
            if current_confirmation != confirmed {
                return Err(CoreError::ValidationFailed {
                    message: format!(
                        "context_preview_changed: confirmed {confirmed}, current {}",
                        current_confirmation
                    ),
                });
            }
            if compilation.context_json == "{}" {
                return Err(CoreError::ValidationFailed {
                    message: "context_pack_empty: add content before enabling Context egress"
                        .to_string(),
                });
            }
            Some(compilation)
        } else {
            None
        };

        // Spawn the bounded callback dispatcher before creating any durable
        // session state, eliminating a rollback-only failure point after attach.
        let callback: Arc<dyn FfiNotebookCaptureCallback> = Arc::from(callback);
        let callback = CaptureCallbackSink::new(callback)?;

        let session_id = uuid::Uuid::new_v4().to_string();
        let session_record = vt_store::SessionRecord {
            id: session_id.clone(),
            title: String::new(),
            session_type: "recording".into(),
            status: "recording".into(),
            duration_ms: 0,
            created_at: chrono::Utc::now().format("%Y-%m-%d %H:%M:%S").to_string(),
            deleted_at: None,
        };
        let engine = CURRENT_NOTEBOOK_CAPTURE_ENGINE;

        // Persist catalogue, privacy snapshot, and deterministic ownership
        // refs in one main-DB transaction before creating any external key or
        // journal. There is no crash window containing an orphan catalogue row
        // or an undiscoverable external artifact.
        let key_ref = format!("zulangue.audio.{session_id}");
        let journal_path = self
            .data_dir
            .join(format!("{session_id}.capture-journal.enc"));
        let run_id = uuid::Uuid::new_v4().to_string();
        let requested_remote = profile.remote_realtime_enabled;
        let run = match self.notebook_capture_store.create_session_and_run(
            &session_record,
            &vt_store::notebook_capture_store::NewNotebookCaptureRun {
                id: run_id.clone(),
                notebook_id: notebook_id.clone(),
                session_id: session_id.clone(),
                remote_health: if requested_remote {
                    RemoteHealth::Connecting
                } else {
                    RemoteHealth::Off
                },
                audio_journal_path: journal_path.to_string_lossy().into_owned(),
                audio_key_ref: key_ref.clone(),
                sample_rate: engine.sample_rate,
                channels: u16::from(engine.channels),
            },
            &profile,
        ) {
            Ok(run) => run,
            Err(error) => {
                return Err(match error {
                    vt_store::notebook_capture_store::NotebookCaptureStoreError::Conflict(_) => {
                        CoreError::ValidationFailed {
                            message: format!(
                                "capture_profile_revision_conflict: expected {}, profile changed before run creation",
                                profile.revision
                            ),
                        }
                    }
                    other => store_error(other),
                });
            }
        };
        tracing::info!(session_id, "created atomic Notebook capture session/run");

        let key = SessionKey::generate();
        if let Err(error) = self.key_store.store_key(&key_ref, &key) {
            // Deletion is idempotent and also covers providers that report an
            // error after partially publishing the new key.
            let _ = self.notebook_capture_store.transition_capture(
                &run_id,
                CaptureState::Recording,
                CaptureState::Failed,
            );
            self.rollback_failed_capture_start(
                &session_id,
                std::slice::from_ref(&journal_path),
                std::slice::from_ref(&key_ref),
            );
            return Err(CoreError::InternalError {
                message: format!("store capture audio key: {error}"),
            });
        }
        let journal = match CaptureAudioJournal::start(
            session_id.clone(),
            RecordingConfig {
                data_dir: self.data_dir.clone(),
                sample_rate: engine.sample_rate,
                channels: u16::from(engine.channels),
            },
            SessionKey::from_bytes(*key.as_bytes()),
        ) {
            Ok(journal) => journal,
            Err(error) => {
                let _ = self.notebook_capture_store.transition_capture(
                    &run_id,
                    CaptureState::Recording,
                    CaptureState::Failed,
                );
                self.rollback_failed_capture_start(
                    &session_id,
                    std::slice::from_ref(&journal_path),
                    std::slice::from_ref(&key_ref),
                );
                return Err(CoreError::InternalError {
                    message: format!("start encrypted capture journal: {error}"),
                });
            }
        };
        debug_assert_eq!(journal.journal_path(), journal_path.as_path());
        if let Some(compilation) = context_compilation.as_ref() {
            if let Err(error) = self
                .context_pack_store
                .persist_run_snapshot(&run_id, compilation)
            {
                let _ = self.notebook_capture_store.transition_capture(
                    &run_id,
                    CaptureState::Recording,
                    CaptureState::Failed,
                );
                self.rollback_failed_capture_start(
                    &session_id,
                    &[journal.journal_path().to_path_buf()],
                    std::slice::from_ref(&key_ref),
                );
                return Err(store_error(error));
            }
        }
        if let Err(error) = self.attach_session_to_notebook(notebook_id.clone(), session_id.clone())
        {
            let _ = self.notebook_capture_store.transition_capture(
                &run_id,
                CaptureState::Recording,
                CaptureState::Failed,
            );
            // Keep direct fallbacks even though the durable run normally owns
            // these refs. If the rollback plan itself cannot be loaded, start
            // failure must still delete the just-created journal and key.
            self.rollback_failed_capture_start(
                &session_id,
                &[journal.journal_path().to_path_buf()],
                std::slice::from_ref(&key_ref),
            );
            return Err(error);
        }
        let remote = if requested_remote {
            match self.start_soniox_capture_runtime(
                &run_id,
                &session_id,
                &profile,
                context_compilation.as_ref(),
                callback.clone(),
            ) {
                Ok(remote) => Some(remote),
                Err(error) => {
                    tracing::warn!(session_id, %error, "Soniox unavailable; local capture continues");
                    let failure = ProviderFailure {
                        error_type: "unavailable".to_string(),
                        request_id: None,
                    };
                    let _ = self.notebook_capture_store.update_remote_health(
                        &run_id,
                        RemoteHealth::Unavailable,
                        Some(&failure),
                    );
                    None
                }
            }
        } else {
            // Privacy invariant: do not load an API key and do not construct a
            // Soniox client when the explicit profile switch is off.
            None
        };

        let active = ActiveNotebookCapture {
            notebook_id,
            session_id: session_id.clone(),
            run_id: run_id.clone(),
            profile,
            state: CaptureState::Recording,
            callback: callback.clone(),
            journal,
            last_persisted_frames: 0,
            remote,
            remote_cleanup: None,
        };
        *self.active_notebook_capture.lock().unwrap() = Some(active);

        let latest_run = self
            .notebook_capture_store
            .get_run(&run_id)
            .ok()
            .flatten()
            .unwrap_or(run);
        let event = callback.send(event_from_run(latest_run, Vec::new(), true));
        Ok(event)
    }

    pub fn push_notebook_capture_session(
        &self,
        session_id: String,
        audio_data: Vec<u8>,
    ) -> Result<(), CoreError> {
        let mut active_guard = self.active_notebook_capture.lock().unwrap();
        {
            let active = active_guard
                .as_ref()
                .filter(|active| active.session_id == session_id)
                .ok_or_else(|| CoreError::ValidationFailed {
                    message: format!("capture_not_active: {session_id}"),
                })?;
            if active.state != CaptureState::Recording {
                return Err(CoreError::ValidationFailed {
                    message: format!("capture is not recording: {:?}", active.state),
                });
            }
        }

        let push_result = active_guard
            .as_mut()
            .expect("active capture was checked above")
            .journal
            .push_s16_pcm(&audio_data);
        if let Err(error) = push_result {
            // Audio durability is the primary capture contract. Once a frame
            // cannot be journaled, stop accepting input and tear down remote
            // processing; continuing would create a transcript for audio that
            // the user cannot recover locally.
            let failed = active_guard
                .take()
                .expect("active capture was checked above");
            // Keep the active mutex locked with `None` through durable
            // teardown. Long ownership-gate sagas cannot block healthy pushes,
            // while a concurrent start/delete (gate -> active) waits until this
            // failed owner has fully converged. This never acquires the gate
            // while holding active, so the global lock order has no cycle.
            let terminal_error = self.terminate_capture_after_push_error(
                &session_id,
                failed,
                "persist capture audio",
                error,
            );
            drop(active_guard);
            return Err(terminal_error);
        }

        let frames = active_guard
            .as_ref()
            .expect("active capture was checked above")
            .journal
            .captured_frames();
        let last_persisted_frames = active_guard
            .as_ref()
            .expect("active capture was checked above")
            .last_persisted_frames;
        if frames.saturating_sub(last_persisted_frames) >= 16_000 {
            let run_id = active_guard
                .as_ref()
                .expect("active capture was checked above")
                .run_id
                .clone();
            if let Err(error) = self
                .notebook_capture_store
                .update_audio_progress(&run_id, frames)
            {
                let failed = active_guard
                    .take()
                    .expect("active capture was checked above");
                let terminal_error = self.terminate_capture_after_push_error(
                    &session_id,
                    failed,
                    "persist capture audio progress",
                    error,
                );
                drop(active_guard);
                return Err(terminal_error);
            }
            active_guard
                .as_mut()
                .expect("active capture was checked above")
                .last_persisted_frames = frames;
        }

        let remote = active_guard
            .as_mut()
            .expect("active capture was checked above")
            .remote
            .take();
        if let Some(remote) = remote {
            if let Err(_error) = remote.try_fanout_pcm(&audio_data) {
                let backpressure_failure = ProviderFailure {
                    error_type: "audio_backpressure".to_string(),
                    request_id: None,
                };
                let cleanup = self.begin_failed_remote_capture_cleanup(remote);
                let active = active_guard
                    .as_mut()
                    .expect("active capture was checked above");
                debug_assert!(active.remote_cleanup.is_none());
                active.remote_cleanup = Some(cleanup);
                let run_id = active_guard
                    .as_ref()
                    .expect("active capture was checked above")
                    .run_id
                    .clone();
                let (remote_health, failure) = self
                    .notebook_capture_store
                    .get_run(&run_id)
                    .ok()
                    .flatten()
                    .and_then(|run| {
                        run.provider_error_type.map(|error_type| {
                            (
                                run.remote_health,
                                ProviderFailure {
                                    error_type,
                                    request_id: run.provider_request_id,
                                },
                            )
                        })
                    })
                    .unwrap_or((RemoteHealth::Degraded, backpressure_failure));
                if let Err(persist_error) = self.notebook_capture_store.update_remote_health(
                    &run_id,
                    remote_health,
                    Some(&failure),
                ) {
                    let failed = active_guard
                        .take()
                        .expect("active capture was checked above");
                    let terminal_error = self.terminate_capture_after_push_error(
                        &session_id,
                        failed,
                        "persist remote health after Soniox audio backpressure",
                        persist_error,
                    );
                    drop(active_guard);
                    return Err(terminal_error);
                }
            } else {
                active_guard
                    .as_mut()
                    .expect("active capture was checked above")
                    .remote = Some(remote);
            }
        }
        Ok(())
    }

    pub fn pause_notebook_capture_session(
        &self,
        session_id: String,
        paused: bool,
    ) -> Result<FfiNotebookCaptureEvent, CoreError> {
        let mut active_guard = self.active_notebook_capture.lock().unwrap();
        let active = active_guard
            .as_mut()
            .filter(|active| active.session_id == session_id)
            .ok_or_else(|| CoreError::ValidationFailed {
                message: format!("capture_not_active: {session_id}"),
            })?;
        let (expected, next, control) = if paused {
            (
                CaptureState::Recording,
                CaptureState::Paused,
                SttStreamControl::Pause,
            )
        } else {
            (
                CaptureState::Paused,
                CaptureState::Recording,
                SttStreamControl::Resume,
            )
        };
        if active.state != expected {
            return Err(CoreError::ValidationFailed {
                message: format!("capture pause transition requires {expected:?}"),
            });
        }
        let mut run = self
            .notebook_capture_store
            .transition_capture(&active.run_id, expected, next)
            .map_err(store_error)?;
        active.state = next;
        if let Some(remote) = active.remote.take() {
            if let Err(_error) = remote.try_fanout_control(control) {
                let mut failure = ProviderFailure {
                    error_type: "control_unavailable".to_string(),
                    request_id: None,
                };
                if let Some(shutdown_failure) = self.shutdown_failed_remote_capture(remote) {
                    failure = prefer_provider_failure(Some(failure), shutdown_failure)
                        .expect("a provider failure was supplied");
                }
                run = self
                    .notebook_capture_store
                    .update_remote_health(&active.run_id, RemoteHealth::Degraded, Some(&failure))
                    .map_err(store_error)?;
            } else {
                active.remote = Some(remote);
            }
        }
        let event = active.callback.send(event_from_run(run, Vec::new(), false));
        Ok(event)
    }

    pub fn stop_notebook_capture_session(
        &self,
        session_id: String,
    ) -> Result<FfiNotebookCaptureEvent, CoreError> {
        let _ownership_guard = self.capture_ownership_gate.lock().unwrap();
        let (mut active, draining) = {
            let mut guard = self.active_notebook_capture.lock().unwrap();
            let Some(active) = guard
                .as_mut()
                .filter(|active| active.session_id == session_id)
            else {
                return Err(CoreError::ValidationFailed {
                    message: format!("capture_not_active: {session_id}"),
                });
            };
            let draining = self
                .notebook_capture_store
                .transition_capture(&active.run_id, active.state, CaptureState::Draining)
                .map_err(store_error)?;
            active.state = CaptureState::Draining;
            (
                guard.take().expect("active capture checked above"),
                draining,
            )
        };
        active
            .callback
            .send(event_from_run(draining, Vec::new(), false));

        let mut remote_failure_persistence_error = None;
        if let Some(remote) = active.remote.take() {
            if let Some(failure) = self.finish_remote_capture(remote) {
                remote_failure_persistence_error =
                    self.persist_remote_shutdown_failure(&active.run_id, &failure);
            }
        }
        if let Some(cleanup) = active.remote_cleanup.take() {
            if let Some(failure) = self.join_pending_remote_capture_cleanup(cleanup) {
                if let Some(error) = self.persist_remote_shutdown_failure(&active.run_id, &failure)
                {
                    remote_failure_persistence_error =
                        Some(match remote_failure_persistence_error {
                            Some(existing) => format!("{existing}; {error}"),
                            None => error,
                        });
                }
            }
        }

        let frames = active.journal.captured_frames();
        let journal_path = active.journal.journal_path().to_path_buf();
        let result = match active.journal.stop() {
            Ok(result) => result,
            Err(error) => {
                return Err(self.record_local_persistence_interruption(
                    &active.run_id,
                    CaptureState::Draining,
                    &active.callback,
                    "finalize encrypted capture audio",
                    error,
                ));
            }
        };
        let durability_result = (|| -> Result<(), CoreError> {
            let audio_path = result.encrypted_path.to_string_lossy().into_owned();
            self.notebook_capture_store
                .finalize_audio(&active.run_id, &audio_path, frames)
                .map_err(store_error)?;
            self.session_meta
                .set_encrypted_path(
                    &session_id,
                    &audio_path,
                    &format!("zulangue.audio.{session_id}"),
                )
                .map_err(store_error)?;
            self.session_meta
                .set_audio_format(&session_id, result.sample_rate, result.channels)
                .map_err(store_error)?;
            self.record_source_audio_retention_chunks_strict(&session_id, &result.audio_chunks)?;
            let current = self
                .session_store
                .get_session(&session_id)
                .map_err(store_error)?;
            self.session_store
                .insert_session(&vt_store::SessionRecord {
                    id: current.id,
                    title: current.title,
                    session_type: current.session_type,
                    status: "completed".to_string(),
                    duration_ms: result.duration_ms,
                    created_at: current.created_at,
                    deleted_at: current.deleted_at,
                })
                .map_err(store_error)?;
            self.notebook_capture_store
                .transition_capture(
                    &active.run_id,
                    CaptureState::Draining,
                    CaptureState::Completed,
                )
                .map_err(store_error)?;
            if let Err(error) = std::fs::remove_file(&journal_path) {
                if error.kind() != std::io::ErrorKind::NotFound {
                    tracing::warn!(
                        session_id,
                        path = %journal_path.display(),
                        %error,
                        "remove finalized capture journal; Delete Forever will retry"
                    );
                }
            }
            Ok(())
        })();
        if let Err(error) = durability_result {
            return Err(self.record_local_persistence_interruption(
                &active.run_id,
                CaptureState::Draining,
                &active.callback,
                "persist finalized capture audio",
                error,
            ));
        }

        let completed_run = self
            .notebook_capture_store
            .get_run(&active.run_id)
            .map_err(store_error)?
            .ok_or_else(|| CoreError::NotFound {
                message: format!("capture run {}", active.run_id),
            })?;
        let projection_result = match remote_failure_persistence_error {
            Some(message) => Err(CoreError::InternalError { message }),
            None => self.project_notebook_capture_with_ownership(&active.run_id),
        };
        let retention_result = self.enforce_realtime_capture_retention(&completed_run);

        let run = self
            .notebook_capture_store
            .get_run(&active.run_id)
            .map_err(store_error)?
            .ok_or_else(|| CoreError::NotFound {
                message: format!("capture run {}", active.run_id),
            })?;
        let utterances = self
            .notebook_capture_store
            .list_utterances(&session_id)
            .map_err(store_error)?;
        let event = active.callback.send(event_from_run(run, utterances, true));
        match (projection_result, retention_result) {
            (Ok(()), Ok(())) => Ok(event),
            (Err(projection_error), Ok(())) => Err(projection_error),
            (Ok(()), Err(retention_error)) => Err(retention_error),
            (Err(projection_error), Err(retention_error)) => Err(CoreError::InternalError {
                message: format!(
                    "capture projection failed ({projection_error}); audio retention enforcement failed ({retention_error})"
                ),
            }),
        }
    }

    /// Immediately stops a Notebook capture after the bounded Swift audio
    /// ring overflows or the microphone becomes unavailable. Only the
    /// controlled enum reason crosses FFI; arbitrary diagnostics are never
    /// persisted. Already accepted local audio is finalized, while remote
    /// processing, post-stop async work, and normal projection are skipped.
    pub fn interrupt_notebook_capture_session(
        &self,
        session_id: String,
        reason: FfiNotebookCaptureInterruptReason,
    ) -> Result<FfiNotebookCaptureEvent, CoreError> {
        let _ownership_guard = self.capture_ownership_gate.lock().unwrap();
        let (mut active, mut failure) = {
            let mut guard = self.active_notebook_capture.lock().unwrap();
            let active = guard
                .as_ref()
                .filter(|active| active.session_id == session_id)
                .ok_or_else(|| CoreError::ValidationFailed {
                    message: format!("capture_not_active: {session_id}"),
                })?;
            if !matches!(active.state, CaptureState::Recording | CaptureState::Paused) {
                return Err(CoreError::ValidationFailed {
                    message: format!(
                        "capture interruption requires recording or paused, found {:?}",
                        active.state
                    ),
                });
            }

            let failure = match reason {
                FfiNotebookCaptureInterruptReason::LocalAudioOverflow => ProviderFailure {
                    error_type: "local_audio_overflow".to_string(),
                    request_id: None,
                },
                FfiNotebookCaptureInterruptReason::LocalAudioUnavailable => ProviderFailure {
                    error_type: "local_audio_unavailable".to_string(),
                    request_id: None,
                },
            };
            (guard.take().expect("active capture checked above"), failure)
        };

        // Ownership is removed before any fallible teardown. From this point
        // every return path must leave no process-local capture or detached
        // provider writer, even when SQLite cannot record the requested
        // interruption. Already accepted provider events are drained first.
        if let Some(remote) = active.remote.take() {
            if let Some(shutdown_failure) = self.shutdown_failed_remote_capture(remote) {
                failure = prefer_provider_failure(Some(failure), shutdown_failure)
                    .expect("an interruption failure was supplied");
            }
        }
        if let Some(cleanup) = active.remote_cleanup.take() {
            if let Some(cleanup_failure) = self.join_pending_remote_capture_cleanup(cleanup) {
                failure = prefer_provider_failure(Some(failure), cleanup_failure)
                    .expect("an interruption failure was supplied");
            }
        }

        if let Err(interrupt_error) =
            self.notebook_capture_store
                .interrupt_capture(&active.run_id, active.state, &failure)
        {
            return Err(self.teardown_after_interrupt_persistence_failure(
                &session_id,
                active,
                interrupt_error,
            ));
        }
        active.state = CaptureState::Interrupted;

        let run_id = active.run_id.clone();
        let callback = active.callback.clone();
        let frames = active.journal.captured_frames();
        let journal_path = active.journal.journal_path().to_path_buf();
        let result = match active.journal.stop() {
            Ok(result) => result,
            Err(error) => {
                return Err(self.report_capture_interrupt_persistence_failure(
                    &run_id,
                    &callback,
                    "finalize encrypted capture audio",
                    error,
                ));
            }
        };
        if let Err(error) = self.persist_interrupted_capture_audio(
            &session_id,
            &run_id,
            frames,
            &journal_path,
            &result,
        ) {
            return Err(self.report_capture_interrupt_persistence_failure(
                &run_id,
                &callback,
                "persist interrupted capture audio",
                error,
            ));
        }

        let event = callback.send(self.capture_event_for_run(&run_id)?);
        Ok(event)
    }

    pub fn list_notebook_capture_utterances(
        &self,
        session_id: String,
    ) -> Result<Vec<FfiNotebookCaptureUtterance>, CoreError> {
        self.notebook_capture_store
            .list_utterances(&session_id)
            .map(|values| values.into_iter().map(Into::into).collect())
            .map_err(store_error)
    }

    /// Rebuilds the complete visible recording history for one Notebook.
    /// Ordering is stable by capture `created_at`, then run ID; a selected
    /// session in Swift is therefore a focus hint rather than the read scope.
    pub fn list_notebook_capture_history(
        &self,
        notebook_id: String,
    ) -> Result<Vec<FfiNotebookCaptureHistoryRun>, CoreError> {
        self.notebook_capture_store
            .list_notebook_capture_history(&notebook_id)
            .map(|runs| runs.into_iter().map(Into::into).collect())
            .map_err(store_error)
    }

    /// Explicitly authorizes one stopped/imported local recording for remote
    /// post-recording transcription. The first click freezes the authorization
    /// time and language hint; repeats are idempotent and a provider failure is
    /// terminal so this entrypoint can never silently upload the audio again.
    pub fn request_notebook_async_transcription(
        &self,
        session_id: String,
    ) -> Result<FfiNotebookCaptureEvent, CoreError> {
        let _ownership_guard = self.capture_ownership_gate.lock().unwrap();
        let run = self
            .notebook_capture_store
            .get_run_for_session(&session_id)
            .map_err(store_error)?
            .ok_or_else(|| CoreError::NotFound {
                message: format!("capture session {session_id}"),
            })?;
        let profile: NotebookCaptureProfile = serde_json::from_str(&run.profile_snapshot_json)
            .map_err(|error| CoreError::InternalError {
                message: format!(
                    "decode capture profile snapshot for run {}: {error}",
                    run.id
                ),
            })?;
        if profile.capture_mode != CaptureMode::TranscriptionOnly {
            return Err(CoreError::ValidationFailed {
                message: "async_transcription_requires_transcription_only_run".to_string(),
            });
        }
        let authorized = self
            .notebook_capture_store
            .authorize_async_transcription(
                &session_id,
                chrono::Utc::now().timestamp_millis().max(1),
                Some(&profile.language_a),
            )
            .map_err(store_error)?;
        self.ensure_post_stop_async_task_for_run(&authorized)?;
        self.capture_event_for_run(&authorized.id)
    }

    /// Returns the durable run state together with all persisted utterances.
    /// Swift uses this after relaunch instead of guessing `completed/ready`
    /// from an utterance-only response.
    pub fn get_notebook_capture_session_event(
        &self,
        session_id: String,
    ) -> Result<FfiNotebookCaptureEvent, CoreError> {
        let run = self
            .notebook_capture_store
            .get_run_for_session(&session_id)
            .map_err(store_error)?
            .ok_or_else(|| CoreError::NotFound {
                message: format!("capture session {session_id}"),
            })?;
        self.capture_event_for_run(&run.id)
    }

    pub fn retry_notebook_capture_projection(
        &self,
        session_id: String,
    ) -> Result<FfiNotebookCaptureEvent, CoreError> {
        let _ownership_guard = self.capture_ownership_gate.lock().unwrap();
        let run = self
            .notebook_capture_store
            .get_run_for_session(&session_id)
            .map_err(store_error)?
            .ok_or_else(|| CoreError::NotFound {
                message: format!("capture session {session_id}"),
            })?;
        self.ensure_capture_projection_not_purging(&run.session_id)?;
        match run.projection_state {
            ProjectionState::Failed => {
                self.notebook_capture_store
                    .retry_projection(&run.id)
                    .map_err(store_error)?;
            }
            ProjectionState::Pending => {}
            ProjectionState::Ready => {
                return self.capture_event_for_run(&run.id);
            }
            ProjectionState::Projecting => {
                return Err(CoreError::ValidationFailed {
                    message: "capture projection is already in progress".to_string(),
                });
            }
        }
        self.project_notebook_capture_with_ownership(&run.id)?;
        self.capture_event_for_run(&run.id)
    }

    /// Retries only the local Async Transcript Loro materialization. The
    /// provider task must already be durably completed; this path has no
    /// credential, audio, TaskQueue, or Soniox access.
    pub fn retry_notebook_async_projection(
        &self,
        session_id: String,
    ) -> Result<FfiNotebookCaptureEvent, CoreError> {
        let _ownership_guard = self.capture_ownership_gate.lock().unwrap();
        let run = self
            .notebook_capture_store
            .get_run_for_session(&session_id)
            .map_err(store_error)?
            .ok_or_else(|| CoreError::NotFound {
                message: format!("capture session {session_id}"),
            })?;
        self.ensure_capture_projection_not_purging(&run.session_id)?;
        match run.async_projection_state {
            AsyncProjectionState::Failed => {
                self.notebook_capture_store
                    .retry_async_projection(&run.id)
                    .map_err(store_error)?;
            }
            AsyncProjectionState::Pending => {}
            AsyncProjectionState::Ready => return self.capture_event_for_run(&run.id),
            AsyncProjectionState::Projecting => {
                return Err(CoreError::ValidationFailed {
                    message: "async transcript projection is already in progress".to_string(),
                });
            }
            AsyncProjectionState::None => {
                return Err(CoreError::ValidationFailed {
                    message: "async provider result is not available for local projection"
                        .to_string(),
                });
            }
        }
        self.notebook_transcript_projector()
            .project_persisted_async_transcript(&self.notebook_capture_store, &session_id)?;
        self.capture_event_for_run(&run.id)
    }

    pub fn replace_notebook_utterance_lane(
        &self,
        utterance_id: String,
        lane_language: String,
        text: String,
        expected_revision: u64,
    ) -> Result<FfiNotebookCaptureUtterance, CoreError> {
        let _mutation_guard = crate::editor_api::editor_document_mutation_guard();
        let current = self
            .notebook_capture_store
            .get_utterance_by_id(&utterance_id)
            .map_err(store_error)?;
        let current = current.ok_or_else(|| CoreError::NotFound {
            message: format!("utterance {utterance_id}"),
        })?;
        let lane = if normalize_language(&current.source_language)
            == normalize_language(&lane_language)
        {
            UtteranceLane::Source
        } else if current
            .translated_language
            .as_deref()
            .is_some_and(|language| {
                normalize_language(language) == normalize_language(&lane_language)
            })
        {
            UtteranceLane::Translated
        } else {
            return Err(CoreError::ValidationFailed {
                message: format!("lane language {lane_language} is not present on {utterance_id}"),
            });
        };
        let mutation = self
            .notebook_capture_store
            .stage_utterance_lane_replacement(&utterance_id, lane, &text, expected_revision)
            .map_err(store_error)?;
        self.apply_notebook_projection_mutation(&mutation)
            .map(Into::into)
    }
}

impl ZulangueCore {
    fn persist_remote_shutdown_failure(
        &self,
        run_id: &str,
        failure: &ProviderFailure,
    ) -> Option<String> {
        let current = self.notebook_capture_store.get_run(run_id).ok().flatten();
        let should_persist = failure.error_type == "local_persistence"
            || match current.as_ref() {
                Some(run) => run.provider_error_type.is_none(),
                None => true,
            };
        if !should_persist {
            return None;
        }
        let health = if current
            .as_ref()
            .is_some_and(|run| run.remote_health == RemoteHealth::Connecting)
        {
            RemoteHealth::Unavailable
        } else {
            RemoteHealth::Degraded
        };
        self.notebook_capture_store
            .update_remote_health(run_id, health, Some(failure))
            .err()
            .map(|error| format!("persist {} capture failure: {error}", failure.error_type))
    }

    fn begin_failed_remote_capture_cleanup(
        &self,
        remote: ActiveRemoteCapture,
    ) -> tokio::task::JoinHandle<Option<ProviderFailure>> {
        let ActiveRemoteCapture {
            cancel,
            streams,
            event_task,
            ..
        } = remote;
        // Stop every provider lane synchronously so a failed target cannot leave
        // sibling WebSockets running and billing on a different audio window.
        // Only joining the already-cancelled tasks is deferred.
        cancel.cancel();
        for stream in &streams {
            stream.stream_task.abort();
        }
        self.runtime.spawn(join_cancelled_remote_group(
            streams,
            event_task,
            std::time::Duration::from_secs(1),
        ))
    }

    fn join_pending_remote_capture_cleanup(
        &self,
        mut cleanup: tokio::task::JoinHandle<Option<ProviderFailure>>,
    ) -> Option<ProviderFailure> {
        self.runtime.block_on(async move {
            match tokio::time::timeout(std::time::Duration::from_millis(1_200), &mut cleanup).await
            {
                Ok(Ok(failure)) => failure,
                Ok(Err(_error)) => Some(ProviderFailure {
                    error_type: "remote_cleanup_task_failed".to_string(),
                    request_id: None,
                }),
                Err(_) => {
                    cleanup.abort();
                    let _ = cleanup.await;
                    Some(ProviderFailure {
                        error_type: "remote_cleanup_join_timeout".to_string(),
                        request_id: None,
                    })
                }
            }
        })
    }

    fn terminate_capture_after_push_error(
        &self,
        session_id: &str,
        mut active: ActiveNotebookCapture,
        operation: &str,
        error: impl std::fmt::Display,
    ) -> CoreError {
        let original_detail = format!("{operation}: {error}");
        let mut shutdown_detail = None;
        if let Some(remote) = active.remote.take() {
            if let Some(failure) = self.shutdown_failed_remote_capture(remote) {
                shutdown_detail = Some(failure.error_type);
            }
        }
        if let Some(cleanup) = active.remote_cleanup.take() {
            if let Some(failure) = self.join_pending_remote_capture_cleanup(cleanup) {
                let detail = failure.error_type;
                shutdown_detail = Some(match shutdown_detail {
                    Some(existing) => format!("{existing}; {detail}"),
                    None => detail,
                });
            }
        }

        let failure = local_persistence_failure(operation, &error);
        if let Err(state_error) = self.notebook_capture_store.interrupt_local_persistence(
            &active.run_id,
            active.state,
            &failure,
        ) {
            let mut detail = format!(
                "{original_detail}; persist local_persistence interruption state: {state_error}"
            );
            if let Some(shutdown_detail) = shutdown_detail {
                detail.push_str(&format!("; stop remote capture: {shutdown_detail}"));
            }
            return self.teardown_after_interrupt_persistence_failure(session_id, active, detail);
        }
        active.state = CaptureState::Interrupted;

        let run_id = active.run_id.clone();
        let callback = active.callback.clone();
        let frames = active.journal.captured_frames();
        let journal_path = active.journal.journal_path().to_path_buf();
        let result = match active.journal.stop() {
            Ok(result) => result,
            Err(finalize_error) => {
                let cleanup = self.report_capture_interrupt_persistence_failure(
                    &run_id,
                    &callback,
                    "finalize capture after push failure",
                    finalize_error,
                );
                return CoreError::InternalError {
                    message: format!("{original_detail}; {cleanup}"),
                };
            }
        };
        if let Err(persist_error) = self.persist_interrupted_capture_audio(
            session_id,
            &run_id,
            frames,
            &journal_path,
            &result,
        ) {
            let cleanup = self.report_capture_interrupt_persistence_failure(
                &run_id,
                &callback,
                "persist capture audio after push failure",
                persist_error,
            );
            return CoreError::InternalError {
                message: format!("{original_detail}; {cleanup}"),
            };
        }
        match self.capture_event_for_run(&run_id) {
            Ok(event) => {
                callback.send(event);
            }
            Err(event_error) => {
                return CoreError::InternalError {
                    message: format!("{original_detail}; load interrupted capture: {event_error}"),
                };
            }
        }

        let message = match shutdown_detail {
            Some(detail) => format!("{original_detail}; stop remote capture: {detail}"),
            None => original_detail,
        };
        CoreError::InternalError { message }
    }

    fn retry_detached_notebook_capture_recovery(&self) -> Result<(), CoreError> {
        let run_ids = self
            .detached_notebook_capture_runs
            .lock()
            .unwrap()
            .iter()
            .cloned()
            .collect::<Vec<_>>();
        for run_id in run_ids {
            let should_recover_audio = match self
                .notebook_capture_store
                .recover_detached_unfinished_run(&run_id)
            {
                Ok(_) => true,
                Err(vt_store::notebook_capture_store::NotebookCaptureStoreError::NotFound(_)) => {
                    false
                }
                Err(error) => {
                    return Err(CoreError::InternalError {
                        message: format!(
                            "detached_capture_recovery_pending: run {run_id} remains unavailable: {error}"
                        ),
                    });
                }
            };
            self.detached_notebook_capture_runs
                .lock()
                .unwrap()
                .remove(&run_id);
            // A previous teardown may have synced the encrypted journal but
            // failed before indexing it. Reuse the startup recovery path now
            // that the neutral durable state is committed; failures retain the
            // journal and are retried on the next launch.
            if should_recover_audio {
                crate::recover_interrupted_capture_audio(
                    &self.data_dir,
                    &self.notebook_capture_store,
                    self.key_store.as_ref(),
                    &self.session_meta,
                    &self.session_store,
                );
            }
        }
        Ok(())
    }

    fn teardown_after_interrupt_persistence_failure(
        &self,
        session_id: &str,
        active: ActiveNotebookCapture,
        interrupt_error: impl std::fmt::Display,
    ) -> CoreError {
        let run_id = active.run_id.clone();
        let callback = active.callback.clone();
        let frames = active.journal.captured_frames();
        let journal_path = active.journal.journal_path().to_path_buf();
        let mut details = vec![format!(
            "persist requested capture interruption: {interrupt_error}"
        )];

        // `stop` consumes the live journal handle and syncs every accepted
        // frame. The journal itself is retained until all recovery indexes
        // commit, so either this process or startup recovery can finish it.
        let finalized = match active.journal.stop() {
            Ok(result) => Some(result),
            Err(error) => {
                details.push(format!(
                    "finalize encrypted capture audio during teardown: {error}"
                ));
                None
            }
        };

        // Do not retry the requested reason under a different name. Mark the
        // now-ownerless row with the neutral startup-recovery transition, and
        // keep returning the original persistence error to the caller.
        self.detached_notebook_capture_runs
            .lock()
            .unwrap()
            .insert(run_id.clone());
        let recovered = match self
            .notebook_capture_store
            .recover_detached_unfinished_run(&run_id)
        {
            Ok(_) => {
                self.detached_notebook_capture_runs
                    .lock()
                    .unwrap()
                    .remove(&run_id);
                true
            }
            Err(error) => {
                details.push(format!("recover detached capture row: {error}"));
                false
            }
        };

        if recovered {
            if let Some(result) = finalized.as_ref() {
                if let Err(error) = self.persist_interrupted_capture_audio(
                    session_id,
                    &run_id,
                    frames,
                    &journal_path,
                    result,
                ) {
                    details.push(format!("persist recovered capture audio: {error}"));
                }
            }
            match self.capture_event_for_run(&run_id) {
                Ok(event) => {
                    callback.send(event);
                }
                Err(error) => details.push(format!("load recovered capture event: {error}")),
            }
        }

        CoreError::InternalError {
            message: details.join("; "),
        }
    }

    fn shutdown_failed_remote_capture(
        &self,
        remote: ActiveRemoteCapture,
    ) -> Option<ProviderFailure> {
        self.runtime.block_on(async move {
            let ActiveRemoteCapture {
                cancel,
                streams,
                event_task,
                ..
            } = remote;
            cancel.cancel();
            join_cancelled_remote_group(streams, event_task, std::time::Duration::from_secs(1))
                .await
        })
    }

    fn persist_interrupted_capture_audio(
        &self,
        session_id: &str,
        run_id: &str,
        frames: u64,
        journal_path: &std::path::Path,
        result: &RecordingResult,
    ) -> Result<(), CoreError> {
        if result.session_id != session_id {
            return Err(CoreError::InternalError {
                message: "interrupted capture audio belongs to a different session".to_string(),
            });
        }
        let audio_path = result.encrypted_path.to_string_lossy().into_owned();
        self.notebook_capture_store
            .finalize_interrupted_audio(run_id, &audio_path, frames)
            .map_err(store_error)?;
        self.session_meta
            .set_encrypted_path(
                session_id,
                &audio_path,
                &format!("zulangue.audio.{session_id}"),
            )
            .map_err(store_error)?;
        self.session_meta
            .set_audio_format(session_id, result.sample_rate, result.channels)
            .map_err(store_error)?;
        self.record_source_audio_retention_chunks_strict(session_id, &result.audio_chunks)?;
        let current = self
            .session_store
            .get_session(session_id)
            .map_err(store_error)?;
        self.session_store
            .insert_session(&vt_store::SessionRecord {
                id: current.id,
                title: current.title,
                session_type: current.session_type,
                status: "interrupted".to_string(),
                duration_ms: result.duration_ms,
                created_at: current.created_at,
                deleted_at: current.deleted_at,
            })
            .map_err(store_error)?;
        if let Err(error) = std::fs::remove_file(journal_path) {
            if error.kind() != std::io::ErrorKind::NotFound {
                tracing::warn!(
                    session_id,
                    path = %journal_path.display(),
                    %error,
                    "remove finalized interrupted capture journal; Delete Forever will retry"
                );
            }
        }
        Ok(())
    }

    fn report_capture_interrupt_persistence_failure(
        &self,
        run_id: &str,
        callback: &CaptureCallbackSink,
        operation: &str,
        error: impl std::fmt::Display,
    ) -> CoreError {
        let detail = format!("{operation}: {error}");
        let failure = local_persistence_failure(operation, error);
        match self.notebook_capture_store.update_remote_health(
            run_id,
            RemoteHealth::Off,
            Some(&failure),
        ) {
            Ok(run) => {
                callback.send(event_from_run(run, Vec::new(), false));
            }
            Err(state_error) => {
                return CoreError::InternalError {
                    message: format!(
                        "{detail}; persist local_persistence interruption state: {state_error}"
                    ),
                };
            }
        }
        CoreError::InternalError { message: detail }
    }

    fn record_local_persistence_interruption(
        &self,
        run_id: &str,
        expected: CaptureState,
        callback: &CaptureCallbackSink,
        operation: &str,
        error: impl std::fmt::Display,
    ) -> CoreError {
        let detail = format!("{operation}: {error}");
        let failure = local_persistence_failure(operation, error);
        match self
            .notebook_capture_store
            .interrupt_local_persistence(run_id, expected, &failure)
        {
            Ok(run) => {
                callback.send(event_from_run(run, Vec::new(), false));
            }
            Err(state_error) => {
                return CoreError::InternalError {
                    message: format!(
                        "{detail}; persist local_persistence interruption state: {state_error}"
                    ),
                };
            }
        }
        CoreError::InternalError { message: detail }
    }

    pub(crate) fn purge_session_forever(&self, session_id: &str) -> Result<(), CoreError> {
        let _ownership_guard = self.capture_ownership_gate.lock().unwrap();
        self.reject_active_session_purge(session_id)?;
        let job = self
            .notebook_capture_store
            .begin_session_purge(session_id)
            .map_err(store_error)?;
        self.resume_session_purge_job(job)
    }

    pub(crate) fn resume_pending_session_purges(&self) -> Result<(), CoreError> {
        let jobs = self
            .notebook_capture_store
            .list_session_purge_jobs()
            .map_err(store_error)?;
        for job in jobs {
            let session_id = job.session_id.clone();
            let result = {
                let _ownership_guard = self.capture_ownership_gate.lock().unwrap();
                self.reject_active_session_purge(&session_id)
                    .and_then(|_| self.resume_session_purge_job(job))
            };
            if let Err(error) = result {
                // A session-scoped file/Loro/key problem must quarantine only
                // this purge job. Keep the tombstone and latest phase/error so
                // the next launch can retry, while the rest of Core starts.
                let durable_error = error.to_string();
                match self
                    .notebook_capture_store
                    .get_session_purge_job(&session_id)
                {
                    Ok(Some(current))
                        if current.last_error.as_deref() != Some(durable_error.as_str()) =>
                    {
                        if let Err(state_error) =
                            self.notebook_capture_store.update_session_purge_job(
                                &session_id,
                                &current.phase,
                                Some(&durable_error),
                            )
                        {
                            tracing::error!(
                                session_id,
                                error = %state_error,
                                "failed to retain isolated purge recovery error"
                            );
                        }
                    }
                    Ok(_) => {}
                    Err(state_error) => {
                        tracing::error!(
                            session_id,
                            error = %state_error,
                            "failed to reload isolated purge recovery state"
                        );
                    }
                }
                tracing::warn!(
                    session_id,
                    error = %error,
                    "session purge remains quarantined; Core startup continues"
                );
            }
        }
        Ok(())
    }

    fn reject_active_session_purge(&self, session_id: &str) -> Result<(), CoreError> {
        let active_capture = self
            .active_notebook_capture
            .lock()
            .unwrap()
            .as_ref()
            .is_some_and(|capture| capture.session_id == session_id);
        if active_capture {
            return Err(CoreError::ValidationFailed {
                message: format!("cannot permanently delete active session {session_id}"),
            });
        }
        Ok(())
    }

    fn resume_session_purge_job(&self, job: SessionPurgeJob) -> Result<(), CoreError> {
        let session_id = job.session_id.as_str();
        let plan = &job.plan;
        let mut phase_rank = purge_phase_rank(&job.phase)?;

        // Rebuild this exact session-task barrier on every saga resume,
        // including after process restart. The caller holds
        // capture_ownership_gate, preventing a new capture task enqueue
        // between this audit and the later task-row deletion.
        let mut task_owner_ids = match self
            .runtime
            .block_on(self.task_queue.list_session_task_ids(session_id))
        {
            Ok(task_ids) => task_ids,
            Err(error) => {
                return Err(self.persist_session_purge_error(
                    session_id,
                    &job.phase,
                    store_error(error),
                ));
            }
        };
        task_owner_ids.push(session_id.to_string());
        task_owner_ids.sort();
        task_owner_ids.dedup();
        for owner_id in task_owner_ids {
            if let Err(error) = self
                .session_task_registry
                .cancel_and_wait(&owner_id, std::time::Duration::from_secs(5))
                .map_err(store_error)
            {
                return Err(self.persist_session_purge_error(session_id, &job.phase, error));
            }
        }

        if phase_rank < 1 {
            self.notebook_capture_store
                .update_session_purge_job(session_id, "task_handlers_stopped", None)
                .map_err(store_error)?;
            phase_rank = 1;
        }

        if phase_rank < 2 {
            if let Err(error) = self.purge_loro_session_ranges(plan) {
                return Err(self.persist_session_purge_error(
                    session_id,
                    "task_handlers_stopped",
                    error,
                ));
            }
            self.notebook_capture_store
                .update_session_purge_job(session_id, "loro_removed", None)
                .map_err(store_error)?;
            phase_rank = 2;
        }

        if phase_rank < 3 {
            if let Err(error) = self
                .runtime
                .block_on(self.task_queue.purge_session(session_id))
                .map_err(store_error)
            {
                return Err(self.persist_session_purge_error(session_id, "loro_removed", error));
            }
            self.notebook_capture_store
                .update_session_purge_job(session_id, "tasks_removed", None)
                .map_err(store_error)?;
            phase_rank = 3;
        }

        if phase_rank < 4 {
            if let Err(error) = self.delete_session_purge_external_artifacts(plan) {
                return Err(self.persist_session_purge_error(session_id, "tasks_removed", error));
            }
            self.notebook_capture_store
                .update_session_purge_job(session_id, "external_artifacts_removed", None)
                .map_err(store_error)?;
            phase_rank = 4;
        }

        if phase_rank < 5 {
            if let Err(error) = self
                .notebook_capture_store
                .purge_session_artifacts(session_id)
                .map(|_| ())
                .map_err(store_error)
            {
                return Err(self.persist_session_purge_error(
                    session_id,
                    "external_artifacts_removed",
                    error,
                ));
            }
            self.notebook_capture_store
                .update_session_purge_job(session_id, "main_database_removed", None)
                .map_err(store_error)?;
            phase_rank = 5;
        }

        if phase_rank < 6 {
            if let Err(error) = self.clear_session_purge_loro_receipts(plan) {
                return Err(self.persist_session_purge_error(
                    session_id,
                    "main_database_removed",
                    error,
                ));
            }
            self.notebook_capture_store
                .update_session_purge_job(session_id, "purge_receipts_removed", None)
                .map_err(store_error)?;
        }

        self.finish_session_purge_memory_cleanup(plan);
        self.notebook_capture_store
            .complete_session_purge_job(session_id)
            .map_err(store_error)?;
        Ok(())
    }

    fn persist_session_purge_error(
        &self,
        session_id: &str,
        phase: &str,
        error: CoreError,
    ) -> CoreError {
        if let Err(state_error) = self.notebook_capture_store.update_session_purge_job(
            session_id,
            phase,
            Some(&error.to_string()),
        ) {
            return CoreError::InternalError {
                message: format!(
                    "session purge failed during {phase} ({error}); persist retry state failed ({state_error})"
                ),
            };
        }
        error
    }

    fn purge_loro_session_ranges(&self, plan: &SessionPurgePlan) -> Result<(), CoreError> {
        use vt_store::EditOp;
        let _mutation_guard = crate::editor_api::editor_document_mutation_guard();
        for target in &plan.projection_targets {
            crate::editor_api::open_editor_session_strict(
                &self.data_dir,
                &self.editor_bridge,
                &target.doc_id,
            )?;
            if self
                .editor_bridge
                .has_session_purge_receipt(&target.doc_id, &plan.session_id)
                .map_err(store_error)?
            {
                crate::editor_api::flush_snapshot_to_disk_result(
                    &self.data_dir,
                    &self.editor_bridge,
                    &target.doc_id,
                )
                .map_err(|message| CoreError::InternalError { message })?;
                continue;
            }
            let delta = self
                .editor_bridge
                .get_delta(&target.doc_id)
                .map_err(store_error)?;
            let range = resolve_capture_section_range(
                &self.editor_bridge,
                &target.doc_id,
                &plan.session_id,
                &delta,
            )?
            .ok_or_else(|| CoreError::ValidationFailed {
                message: format!(
                    "session {} has a projection row in document {} but no durable section anchor, ownership marks, or purge receipt",
                    plan.session_id, target.doc_id
                ),
            })?;
            let rollback_snapshot = self
                .editor_bridge
                .export_snapshot(&target.doc_id)
                .map_err(store_error)?;
            let apply_result = (|| -> Result<(), CoreError> {
                if range.len > 0 {
                    self.editor_bridge
                        .apply(
                            &target.doc_id,
                            EditOp::Delete {
                                pos: range.pos,
                                len: range.len,
                            },
                        )
                        .map_err(store_error)?;
                }
                self.editor_bridge
                    .clear_capture_owned_ranges_for_session(&target.doc_id, &plan.session_id)
                    .map_err(store_error)?;
                self.editor_bridge
                    .set_session_purge_receipt(&target.doc_id, &plan.session_id)
                    .map_err(store_error)?;
                crate::editor_api::flush_snapshot_to_disk_result(
                    &self.data_dir,
                    &self.editor_bridge,
                    &target.doc_id,
                )
                .map_err(|message| CoreError::InternalError { message })?;
                Ok(())
            })();
            if let Err(error) = apply_result {
                let rollback_result = self
                    .editor_bridge
                    .replace_document_with_styles(
                        &target.doc_id,
                        &rollback_snapshot,
                        crate::editor_api::voice_tool_style_config(),
                    )
                    .map_err(|rollback_error| rollback_error.to_string())
                    .and_then(|_| {
                        crate::editor_api::flush_snapshot_to_disk_result(
                            &self.data_dir,
                            &self.editor_bridge,
                            &target.doc_id,
                        )
                    });
                if let Err(rollback_error) = rollback_result {
                    return Err(CoreError::InternalError {
                        message: format!(
                            "session purge Loro mutation failed ({error}); durable rollback failed ({rollback_error})"
                        ),
                    });
                }
                return Err(error);
            }
            crate::editor_api::notify_editor_callback(&self.editor_callbacks, &target.doc_id);
        }
        Ok(())
    }

    fn delete_session_purge_external_artifacts(
        &self,
        plan: &SessionPurgePlan,
    ) -> Result<(), CoreError> {
        let mut paths = plan
            .file_paths
            .iter()
            .map(std::path::PathBuf::from)
            .collect::<Vec<_>>();
        for name in &plan.canonical_artifact_names {
            require_single_file_name(name)?;
            paths.push(self.data_dir.join(name));
        }
        if !plan.canonical_artifact_prefixes.is_empty() {
            let entries =
                std::fs::read_dir(&self.data_dir).map_err(|error| CoreError::InternalError {
                    message: format!("enumerate capture artifacts: {error}"),
                })?;
            for entry in entries {
                let entry = entry.map_err(|error| CoreError::InternalError {
                    message: format!("enumerate capture artifact: {error}"),
                })?;
                let name = entry.file_name().to_string_lossy().into_owned();
                if plan.canonical_artifact_prefixes.iter().any(|prefix| {
                    require_single_file_prefix(prefix).is_ok() && name.starts_with(prefix)
                }) {
                    paths.push(entry.path());
                }
            }
            for prefix in &plan.canonical_artifact_prefixes {
                require_single_file_prefix(prefix)?;
            }
        }
        paths.sort();
        paths.dedup();
        for path in paths {
            let path = if path.is_absolute() {
                path
            } else {
                self.data_dir.join(path)
            };
            require_path_within_data_dir(&self.data_dir, &path)?;
            match std::fs::remove_file(&path) {
                Ok(()) => {}
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                Err(error) => {
                    return Err(CoreError::InternalError {
                        message: format!("delete capture artifact {}: {error}", path.display()),
                    });
                }
            }
        }
        for key_ref in &plan.key_refs {
            match self.key_store.delete_key(key_ref) {
                Ok(()) | Err(vt_crypto::CryptoError::KeyNotFound { .. }) => {}
                Err(error) => {
                    return Err(CoreError::InternalError {
                        message: format!("destroy capture key {key_ref}: {error}"),
                    });
                }
            }
        }
        Ok(())
    }

    fn clear_session_purge_loro_receipts(&self, plan: &SessionPurgePlan) -> Result<(), CoreError> {
        let _mutation_guard = crate::editor_api::editor_document_mutation_guard();
        for target in &plan.projection_targets {
            crate::editor_api::open_editor_session_strict(
                &self.data_dir,
                &self.editor_bridge,
                &target.doc_id,
            )?;
            if self
                .editor_bridge
                .has_session_purge_receipt(&target.doc_id, &plan.session_id)
                .map_err(store_error)?
            {
                self.editor_bridge
                    .clear_session_purge_receipt(&target.doc_id, &plan.session_id)
                    .map_err(store_error)?;
                crate::editor_api::flush_snapshot_to_disk_result(
                    &self.data_dir,
                    &self.editor_bridge,
                    &target.doc_id,
                )
                .map_err(|message| CoreError::InternalError { message })?;
            }
        }
        Ok(())
    }

    fn finish_session_purge_memory_cleanup(&self, plan: &SessionPurgePlan) {
        for target in &plan.projection_targets {
            self.pending_snapshot_saves
                .lock()
                .unwrap()
                .remove(&target.doc_id);
            crate::editor_api::notify_editor_callback(&self.editor_callbacks, &target.doc_id);
        }
    }

    fn rollback_failed_capture_start(
        &self,
        session_id: &str,
        extra_file_paths: &[std::path::PathBuf],
        extra_key_refs: &[String],
    ) {
        let extra_file_paths = extra_file_paths
            .iter()
            .map(|path| path.to_string_lossy().into_owned())
            .collect::<Vec<_>>();
        let job = match self.notebook_capture_store.begin_session_purge_with_extras(
            session_id,
            &extra_file_paths,
            extra_key_refs,
        ) {
            Ok(job) => job,
            Err(error) => {
                tracing::error!(
                    session_id,
                    %error,
                    "failed to persist capture-start rollback purge job"
                );
                return;
            }
        };
        if let Err(error) = self.resume_session_purge_job(job) {
            // resume_session_purge_job persists the exact phase/last_error.
            // Startup recovery will retry this same frozen plan.
            tracing::warn!(
                session_id,
                error = %error,
                "capture-start rollback remains pending in durable purge saga"
            );
        }
    }

    fn start_soniox_capture_runtime(
        &self,
        run_id: &str,
        session_id: &str,
        profile: &NotebookCaptureProfile,
        context: Option<&ContextCompilation>,
        callback: CaptureCallbackSink,
    ) -> Result<ActiveRemoteCapture, CoreError> {
        let engine = CURRENT_NOTEBOOK_CAPTURE_ENGINE;
        self.ensure_remote_provider_allowed_for_session(session_id, engine.provider_id)?;
        let api_key = self
            .api_key_store
            .get(engine.credential_scope)
            .map_err(|error| CoreError::ValidationFailed {
                message: format!("soniox_key_unavailable: {error}"),
            })?;
        let context_config = context.map(context_config_for_soniox);
        if let (Some(compilation), Some(config)) = (context, context_config.as_ref()) {
            let wire_context =
                soniox_stream_context_json(config).map_err(|error| CoreError::InternalError {
                    message: format!("serialize Soniox Context: {error}"),
                })?;
            if wire_context.as_deref() != Some(compilation.context_json.as_str()) {
                return Err(CoreError::ValidationFailed {
                    message: "confirmed Context preview does not match Soniox wire context"
                        .to_string(),
                });
            }
        }
        let claimed_run = self
            .notebook_capture_store
            .claim_provider_provenance(
                session_id,
                CaptureProviderRole::Realtime,
                engine.provider_id,
                engine.realtime_model_id,
            )
            .map_err(store_error)?;
        debug_assert_eq!(
            claimed_run.realtime_provider_id.as_deref(),
            Some(engine.provider_id)
        );
        debug_assert_eq!(
            claimed_run.realtime_model_id.as_deref(),
            Some(engine.realtime_model_id)
        );

        let lane_translations = remote_stream_plan(&profile.selected_languages)?;

        let cancel = tokio_util::sync::CancellationToken::new();
        let stream_factory = self.notebook_soniox_stream_factory.clone();
        let tagged_capacity = lane_translations.len().saturating_mul(64).clamp(64, 512);
        let (tagged_tx, tagged_rx) = tokio::sync::mpsc::channel(tagged_capacity);
        let mut streams = Vec::with_capacity(lane_translations.len());
        {
            let _guard = self.runtime.enter();
            for (index, (target_language, translation)) in lane_translations.into_iter().enumerate()
            {
                let descriptor = RemoteStreamLane {
                    target_language: target_language.as_deref().map(normalize_language),
                    // Multilingual capture owns one source-only timeline lane.
                    // Translation lanes are projections onto that timeline, so
                    // changing column order can never change authoritative
                    // utterance IDs, boundaries, speakers, or source language.
                    canonical: index == 0 && target_language.is_none(),
                };
                let client_reference_id = target_language
                    .as_deref()
                    .map(|target| format!("{session_id}:rt:{target}"))
                    .or_else(|| Some(session_id.to_string()));
                let config = SttConfig {
                    language_hints: profile.selected_languages.clone(),
                    // Hints improve the selected columns, but strict restriction
                    // would suppress an unselected-language original.
                    language_hints_strict: false,
                    enable_language_identification: true,
                    enable_speaker_diarization: true,
                    translation,
                    context: context_config.clone(),
                    client_reference_id,
                    ..Default::default()
                };
                let stream = stream_factory.start(
                    engine.realtime_endpoint,
                    api_key.clone(),
                    config,
                    cancel.clone(),
                );
                let vt_stt::SonioxStreamRuntime {
                    audio_tx,
                    control_tx,
                    event_rx,
                    task: stream_task,
                } = stream;
                let forward_task =
                    tokio::spawn(forward_stream_events(index, event_rx, tagged_tx.clone()));
                streams.push(ActiveRemoteStream {
                    descriptor,
                    audio_tx,
                    control_tx,
                    stream_task,
                    forward_task,
                });
            }
        }
        drop(tagged_tx);
        let lane_descriptors = streams
            .iter()
            .map(|stream| stream.descriptor.clone())
            .collect::<Vec<_>>();
        let store = self.notebook_capture_store.clone();
        let context_store = self.context_pack_store.clone();
        let profile = profile.clone();
        let context_digest = context.map(|value| value.receipt.context_sha256.clone());
        let run_id_owned = run_id.to_string();
        let event_cancel = cancel.clone();
        let event_task = self.runtime.spawn(async move {
            collect_stream_events(
                store,
                context_store,
                run_id_owned,
                profile,
                context_digest,
                lane_descriptors,
                tagged_rx,
                event_cancel,
                callback,
            )
            .await
        });
        Ok(ActiveRemoteCapture {
            stream_factory,
            streams,
            cancel,
            event_task,
        })
    }

    fn finish_remote_capture(&self, remote: ActiveRemoteCapture) -> Option<ProviderFailure> {
        self.runtime.block_on(async move {
            let ActiveRemoteCapture {
                cancel,
                mut streams,
                mut event_task,
                ..
            } = remote;
            let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(5);
            let finish_senders = streams
                .iter()
                .map(|stream| stream.control_tx.clone())
                .collect::<Vec<_>>();
            let finish_result = tokio::time::timeout_at(
                deadline,
                futures::future::join_all(
                    finish_senders
                        .into_iter()
                        .map(|sender| async move { sender.send(SttStreamControl::Finish).await }),
                ),
            )
            .await;
            let finish_control_failure = match finish_result {
                Ok(results) if results.iter().all(Result::is_ok) => None,
                Ok(_) => Some(ProviderFailure {
                    error_type: "finish_control_closed".to_string(),
                    request_id: None,
                }),
                Err(_) => Some(ProviderFailure {
                    error_type: "finish_control_timeout".to_string(),
                    request_id: None,
                }),
            };
            if let Some(failure) = finish_control_failure {
                cancel.cancel();
                let cleanup = join_cancelled_remote_group(
                    streams,
                    event_task,
                    std::time::Duration::from_secs(1),
                )
                .await;
                return match cleanup {
                    Some(cleanup_failure) => {
                        prefer_provider_failure(Some(failure), cleanup_failure)
                    }
                    None => Some(failure),
                };
            }

            let mut failure = None;
            match tokio::time::timeout_at(
                deadline,
                futures::future::join_all(streams.iter_mut().map(|stream| &mut stream.stream_task)),
            )
            .await
            {
                Ok(results) => {
                    for result in results {
                        match result {
                            Ok(Ok(())) => {}
                            Ok(Err(_error)) => {
                                failure.get_or_insert_with(|| ProviderFailure {
                                    error_type: "stream_terminated".to_string(),
                                    request_id: None,
                                });
                            }
                            Err(_error) => {
                                failure.get_or_insert_with(|| ProviderFailure {
                                    error_type: "stream_task_failed".to_string(),
                                    request_id: None,
                                });
                            }
                        }
                    }
                }
                Err(_) => {
                    cancel.cancel();
                    for stream in &streams {
                        stream.stream_task.abort();
                    }
                    for stream in &mut streams {
                        let _ = (&mut stream.stream_task).await;
                    }
                    failure = Some(ProviderFailure {
                        error_type: "finish_timeout".to_string(),
                        request_id: None,
                    });
                }
            }

            match tokio::time::timeout_at(
                deadline,
                futures::future::join_all(
                    streams.iter_mut().map(|stream| &mut stream.forward_task),
                ),
            )
            .await
            {
                Ok(results) if results.iter().all(Result::is_ok) => {}
                Ok(_) => {
                    failure.get_or_insert_with(|| ProviderFailure {
                        error_type: "event_forward_task_failed".to_string(),
                        request_id: None,
                    });
                }
                Err(_) => {
                    for stream in &streams {
                        stream.forward_task.abort();
                    }
                    for stream in &mut streams {
                        let _ = (&mut stream.forward_task).await;
                    }
                    failure.get_or_insert_with(|| ProviderFailure {
                        error_type: "event_forward_drain_timeout".to_string(),
                        request_id: None,
                    });
                }
            }

            // The event collector is the sole utterance writer. It must be
            // joined before projection so a detached tail cannot write after
            // the Loro snapshot was rendered. Give it a small independent
            // drain budget: stream shutdown and event forwarding may have
            // legitimately consumed the shared provider-finish deadline.
            let event_drain_deadline =
                tokio::time::Instant::now() + std::time::Duration::from_secs(2);
            match tokio::time::timeout_at(event_drain_deadline, &mut event_task).await {
                Ok(Ok(Ok(()))) => {}
                Ok(Ok(Err(event_failure))) => {
                    failure = prefer_provider_failure(failure, event_failure);
                }
                Ok(Err(_error)) => {
                    failure.get_or_insert_with(|| ProviderFailure {
                        error_type: "event_task_failed".to_string(),
                        request_id: None,
                    });
                }
                Err(_) => {
                    event_task.abort();
                    let _ = event_task.await;
                    failure.get_or_insert_with(|| ProviderFailure {
                        error_type: "event_drain_timeout".to_string(),
                        request_id: None,
                    });
                }
            }
            failure
        })
    }

    fn capture_event_for_run(&self, run_id: &str) -> Result<FfiNotebookCaptureEvent, CoreError> {
        let run = self
            .notebook_capture_store
            .get_run(run_id)
            .map_err(store_error)?
            .ok_or_else(|| CoreError::NotFound {
                message: format!("capture run {run_id}"),
            })?;
        event_full_snapshot_from_run(&self.notebook_capture_store, run)
    }

    pub(crate) fn resume_pending_notebook_projection_mutations(&self) -> Result<(), CoreError> {
        let _mutation_guard = crate::editor_api::editor_document_mutation_guard();
        let pending = self
            .notebook_capture_store
            .list_pending_projection_mutations()
            .map_err(store_error)?;
        for mutation in pending {
            self.apply_notebook_projection_mutation(&mutation)?;
        }
        Ok(())
    }

    pub(crate) fn compensate_completed_notebook_async_tasks(&self) -> Result<(), CoreError> {
        for run in self
            .notebook_capture_store
            .list_completed_runs_requiring_async_compensation()
            .map_err(store_error)?
        {
            self.ensure_post_stop_async_task_for_run(&run)?;
        }
        Ok(())
    }

    pub(crate) fn resume_pending_async_search_projections(&self) -> Result<(), CoreError> {
        let scan = self
            .notebook_capture_store
            .list_async_search_projections_requiring_retry()
            .map_err(store_error)?;
        for corrupt in scan.corrupt {
            tracing::warn!(
                session_id = %corrupt.session_id,
                task_id = corrupt.task_id.as_deref().unwrap_or("<missing>"),
                error_code = "capture_provider_receipt_invalid",
                reason = %corrupt.reason,
                "startup isolated a corrupt provider receipt; refusing every local projection and provider retry"
            );
            if let Err(error) = self
                .notebook_capture_store
                .fail_corrupt_async_search_projection(
                    &corrupt.session_id,
                    corrupt.task_id.as_deref(),
                )
            {
                tracing::warn!(
                    session_id = %corrupt.session_id,
                    error = %error,
                    "failed to persist corrupt provider receipt projection failure"
                );
            }
        }
        for receipt in scan.receipts {
            if let Err(error) = crate::transcribe_api::project_transcribe_search_receipt(
                &self.data_dir.join("zulangue.db"),
                &receipt,
            ) {
                tracing::warn!(
                    session_id = %receipt.session_id,
                    task_id = %receipt.task_id,
                    error = %error,
                    "startup FTS projection remains retryable; provider receipt is unchanged"
                );
            }
        }
        Ok(())
    }

    pub(crate) fn resume_pending_notebook_async_projections(&self) -> Result<(), CoreError> {
        let projector = self.notebook_transcript_projector();
        for run in self
            .notebook_capture_store
            .list_pending_async_projections()
            .map_err(store_error)?
        {
            if self
                .notebook_capture_store
                .get_session_purge_job(&run.session_id)
                .map_err(store_error)?
                .is_some()
            {
                continue;
            }
            if let Err(error) = projector
                .project_persisted_async_transcript(&self.notebook_capture_store, &run.session_id)
            {
                tracing::warn!(
                    session_id = %run.session_id,
                    error = %error,
                    "startup local async projection failed; explicit retry remains available"
                );
            }
        }
        Ok(())
    }

    pub(crate) fn ensure_post_stop_async_task_for_run(
        &self,
        run: &NotebookCaptureRun,
    ) -> Result<(), CoreError> {
        if self
            .notebook_capture_store
            .get_session_purge_job(&run.session_id)
            .map_err(store_error)?
            .is_some()
        {
            return Ok(());
        }
        let Some(authorized_at_ms) = run.async_authorized_at_ms else {
            if run.async_task_state != AsyncTaskState::None {
                return Err(CoreError::InternalError {
                    message: format!(
                        "capture run {} has async state {:?} without frozen authorization",
                        run.id, run.async_task_state
                    ),
                });
            }
            return Ok(());
        };
        let payload = TaskPayload::Transcribe {
            session_id: run.session_id.clone(),
            language_hint: run.async_language_hint.clone(),
            remote_authorization: Some(RemoteTaskAuthorization::soniox_post_recording_at(
                authorized_at_ms,
            )),
        };
        let payload_json =
            serde_json::to_string(&payload).map_err(|error| CoreError::InternalError {
                message: format!("serialize async task for capture run {}: {error}", run.id),
            })?;
        let payload_sha256 = hex::encode(Sha256::digest(payload_json.as_bytes()));
        let stable_task_id = format!("capture-async-{}", run.id);

        match run.async_task_state {
            AsyncTaskState::None | AsyncTaskState::Completed | AsyncTaskState::Failed => Ok(()),
            AsyncTaskState::Pending => {
                self.notebook_capture_store
                    .reserve_async_task(&run.id, &stable_task_id, &payload_sha256)
                    .map_err(store_error)?;
                let (task_id, _) = self
                    .runtime
                    .block_on(self.task_queue.enqueue_once_with_stable_id(
                        &stable_task_id,
                        payload,
                        TaskPriority::Normal,
                    ))
                    .map_err(store_error)?;
                self.notebook_capture_store
                    .mark_async_task_enqueued(&run.id, &task_id)
                    .map_err(store_error)?;
                Ok(())
            }
            AsyncTaskState::Reserved | AsyncTaskState::Enqueued => {
                let outcome = self
                    .runtime
                    .block_on(reconcile_capture_async_task_receipt_on_startup(
                        &self.notebook_capture_store,
                        self.task_queue.as_ref(),
                        run,
                        &stable_task_id,
                        &payload,
                        &payload_sha256,
                    ))
                    .map_err(|message| CoreError::InternalError { message })?;
                match outcome {
                    StartupCaptureAsyncReceiptOutcome::ProviderReceiptReady => {
                        if let Err(error) =
                            self.complete_recovered_provider_receipt(run, &stable_task_id)
                        {
                            tracing::warn!(
                                run_id = %run.id,
                                session_id = %run.session_id,
                                error = %error,
                                "durable provider result remains locally retryable; no provider request was made"
                            );
                        }
                    }
                    StartupCaptureAsyncReceiptOutcome::FailedClosed { reason } => {
                        tracing::warn!(
                            run_id = %run.id,
                            session_id = %run.session_id,
                            reason = %reason,
                            "capture async task receipt failed closed during startup; refusing re-upload"
                        );
                    }
                    StartupCaptureAsyncReceiptOutcome::ProviderReceiptBlocked { reason } => {
                        tracing::warn!(
                            run_id = %run.id,
                            session_id = %run.session_id,
                            reason = %reason,
                            "durable provider result is preserved but local recovery is blocked; refusing re-upload"
                        );
                    }
                    StartupCaptureAsyncReceiptOutcome::Claimable
                    | StartupCaptureAsyncReceiptOutcome::Completed => {}
                }
                Ok(())
            }
        }
    }

    /// Applies the immutable per-run audio-retention policy after a stopped
    /// realtime capture has durable transcript facts. `high` waits for the
    /// user's explicit async transcription; `maximum` removes audio as soon as
    /// any persisted realtime utterance can rebuild the Notebook. A local-only
    /// recording with no transcript intentionally keeps its only source.
    fn enforce_realtime_capture_retention(
        &self,
        run: &NotebookCaptureRun,
    ) -> Result<(), CoreError> {
        let profile: NotebookCaptureProfile = serde_json::from_str(&run.profile_snapshot_json)
            .map_err(|error| CoreError::InternalError {
                message: format!(
                    "decode capture privacy snapshot for run {}: {error}",
                    run.id
                ),
            })?;
        if profile.privacy_level != "maximum" {
            return Ok(());
        }
        if self
            .notebook_capture_store
            .list_utterances(&run.session_id)
            .map_err(store_error)?
            .is_empty()
        {
            tracing::info!(
                session_id = %run.session_id,
                "maximum privacy retained audio because no durable transcript facts exist"
            );
            return Ok(());
        }
        crate::transcribe_api::enforce_privacy_after_task(
            &run.session_id,
            &self.data_dir.join("zulangue.db"),
            self.key_store.as_ref(),
        )
        .map_err(|message| CoreError::InternalError {
            message: format!("maximum privacy cleanup after realtime capture: {message}"),
        })
    }

    fn complete_recovered_provider_receipt(
        &self,
        run: &NotebookCaptureRun,
        task_id: &str,
    ) -> Result<(), CoreError> {
        let receipt = self
            .notebook_capture_store
            .get_async_provider_receipt(&run.session_id, task_id)
            .map_err(store_error)?
            .ok_or_else(|| CoreError::InternalError {
                message: format!(
                    "capture session {} lost its durable provider receipt during recovery",
                    run.session_id
                ),
            })?;
        if let Err(error) = crate::transcribe_api::project_transcribe_search_receipt(
            &self.data_dir.join("zulangue.db"),
            &receipt,
        ) {
            tracing::warn!(
                session_id = %run.session_id,
                task_id,
                error = %error,
                "provider task recovery continues while FTS remains locally retryable"
            );
        }
        crate::transcribe_api::enforce_privacy_after_task(
            &run.session_id,
            &self.data_dir.join("zulangue.db"),
            self.key_store.as_ref(),
        )
        .map_err(|message| CoreError::InternalError {
            message: format!("privacy cleanup for recovered provider receipt: {message}"),
        })?;
        self.runtime
            .block_on(
                self.task_queue
                    .complete_from_durable_provider_receipt(task_id),
            )
            .map_err(store_error)?;
        self.notebook_capture_store
            .mark_async_task_terminal_for_session(&run.session_id, task_id, true)
            .map_err(store_error)?;
        Ok(())
    }

    /// Forward-replays one durable lane mutation. The caller must hold the
    /// global editor mutation lock so purge, user edits, projections, and the
    /// snapshot flusher cannot interleave with the Loro/SQLite commit boundary.
    fn apply_notebook_projection_mutation(
        &self,
        mutation: &NotebookProjectionMutation,
    ) -> Result<RealtimeUtterance, CoreError> {
        use vt_store::{BuiltinNotebookTab, EditOp};

        let current = self
            .notebook_capture_store
            .get_utterance_by_id(&mutation.utterance_id)
            .map_err(store_error)?
            .ok_or_else(|| CoreError::NotFound {
                message: format!("utterance {}", mutation.utterance_id),
            })?;
        if current.revision != mutation.expected_revision {
            let error = CoreError::ValidationFailed {
                message: format!(
                    "utterance {} expected revision {}",
                    mutation.utterance_id, mutation.expected_revision
                ),
            };
            self.cancel_projection_mutation_after_error(mutation, &error)?;
            return Err(error);
        }
        let lane_language = match mutation.lane {
            UtteranceLane::Source => current.source_language.as_str(),
            UtteranceLane::Translated => {
                current.translated_language.as_deref().ok_or_else(|| {
                    CoreError::ValidationFailed {
                        message: format!("utterance {} has no translated lane", current.id),
                    }
                })?
            }
        };
        let run = self
            .notebook_capture_store
            .get_run_for_session(&mutation.session_id)
            .map_err(store_error)?
            .ok_or_else(|| CoreError::NotFound {
                message: format!("capture session {}", mutation.session_id),
            })?;
        let tab = self
            .notebook_store
            .list_tabs(&run.notebook_id)
            .map_err(store_error)?
            .into_iter()
            .find(|tab| tab.builtin_kind == BuiltinNotebookTab::RealtimeTranscript)
            .ok_or_else(|| CoreError::NotFound {
                message: format!("Realtime Transcript tab for notebook {}", run.notebook_id),
            });
        let tab = match tab {
            Ok(tab) => tab,
            Err(error) => {
                self.cancel_projection_mutation_after_error(mutation, &error)?;
                return Err(error);
            }
        };
        if let Err(error) = crate::editor_api::open_editor_session_strict(
            &self.data_dir,
            &self.editor_bridge,
            &tab.doc_id,
        ) {
            self.cancel_projection_mutation_after_error(mutation, &error)?;
            return Err(error);
        }
        let rollback_snapshot = match self.editor_bridge.export_snapshot(&tab.doc_id) {
            Ok(snapshot) => snapshot,
            Err(error) => {
                let error = store_error(error);
                self.cancel_projection_mutation_after_error(mutation, &error)?;
                return Err(error);
            }
        };

        let apply_result = (|| -> Result<RealtimeUtterance, CoreError> {
            let delta = self
                .editor_bridge
                .get_delta(&tab.doc_id)
                .map_err(store_error)?;
            let range = crate::editor_api::find_unique_marked_range(
                &delta,
                crate::editor_api::DeltaMarkSelector {
                    session_id: Some(&mutation.session_id),
                    utterance_id: Some(&mutation.utterance_id),
                    lane_language: Some(lane_language),
                },
            )?
            .ok_or_else(|| CoreError::ValidationFailed {
                message: format!(
                    "Loro lane ownership marks are missing for utterance {} ({lane_language})",
                    mutation.utterance_id
                ),
            })?;
            let rendered = render_replacement_lane(&current, mutation);
            let rendered_len = rendered.text.chars().count();
            self.editor_bridge
                .apply(
                    &tab.doc_id,
                    EditOp::Replace {
                        pos: range.pos,
                        len: range.len,
                        text: rendered.text,
                    },
                )
                .map_err(store_error)?;
            for mark in rendered.marks {
                self.editor_bridge
                    .apply(
                        &tab.doc_id,
                        EditOp::Mark {
                            pos: range.pos + mark.pos,
                            len: mark.len,
                            key: mark.key,
                            value_json: mark.value_json,
                        },
                    )
                    .map_err(store_error)?;
            }
            self.editor_bridge
                .apply(
                    &tab.doc_id,
                    EditOp::Mark {
                        pos: range.pos,
                        len: rendered_len,
                        key: "content_owner".to_string(),
                        value_json: "\"user\"".to_string(),
                    },
                )
                .map_err(store_error)?;
            crate::editor_api::flush_snapshot_to_disk_result(
                &self.data_dir,
                &self.editor_bridge,
                &tab.doc_id,
            )
            .map_err(|message| CoreError::InternalError { message })?;
            self.notebook_capture_store
                .commit_projection_mutation(&mutation.id)
                .map_err(store_error)
        })();

        match apply_result {
            Ok(updated) => {
                crate::editor_api::notify_editor_callback(&self.editor_callbacks, &tab.doc_id);
                Ok(updated)
            }
            Err(error) => {
                let rollback_result = self
                    .editor_bridge
                    .replace_document_with_styles(
                        &tab.doc_id,
                        &rollback_snapshot,
                        crate::editor_api::voice_tool_style_config(),
                    )
                    .map_err(|rollback_error| rollback_error.to_string())
                    .and_then(|_| {
                        crate::editor_api::flush_snapshot_to_disk_result(
                            &self.data_dir,
                            &self.editor_bridge,
                            &tab.doc_id,
                        )
                    });
                if let Err(rollback_error) = rollback_result {
                    return Err(CoreError::InternalError {
                        message: format!(
                            "lane mutation failed ({error}); durable Loro rollback failed ({rollback_error}); pending mutation retained for recovery"
                        ),
                    });
                }
                self.cancel_projection_mutation_after_error(mutation, &error)?;
                Err(error)
            }
        }
    }

    fn cancel_projection_mutation_after_error(
        &self,
        mutation: &NotebookProjectionMutation,
        original_error: &CoreError,
    ) -> Result<(), CoreError> {
        match self
            .notebook_capture_store
            .cancel_projection_mutation(&mutation.id)
        {
            Ok(true) => Ok(()),
            Ok(false) => Err(CoreError::InternalError {
                message: format!(
                    "{original_error}; projection mutation {} could not be cancelled",
                    mutation.id
                ),
            }),
            Err(cancel_error) => Err(CoreError::InternalError {
                message: format!(
                    "{original_error}; cancel projection mutation {} failed: {cancel_error}",
                    mutation.id
                ),
            }),
        }
    }

    fn ensure_capture_projection_not_purging(&self, session_id: &str) -> Result<(), CoreError> {
        if self
            .notebook_capture_store
            .has_session_purge_job(session_id)
            .map_err(store_error)?
        {
            return Err(CoreError::ValidationFailed {
                message: format!("capture session {session_id} is being permanently deleted"),
            });
        }
        Ok(())
    }

    #[cfg(test)]
    fn project_notebook_capture(&self, run_id: &str) -> Result<(), CoreError> {
        let _ownership_guard = self.capture_ownership_gate.lock().unwrap();
        self.project_notebook_capture_with_ownership(run_id)
    }

    /// Projects while the caller holds `capture_ownership_gate`. Stop already
    /// owns the gate across audio finalization; retry and direct recovery enter
    /// through gate-taking wrappers.
    fn project_notebook_capture_with_ownership(&self, run_id: &str) -> Result<(), CoreError> {
        let run = self
            .notebook_capture_store
            .get_run(run_id)
            .map_err(store_error)?
            .ok_or_else(|| CoreError::NotFound {
                message: format!("capture run {run_id}"),
            })?;
        self.ensure_capture_projection_not_purging(&run.session_id)?;
        if run.projection_state == ProjectionState::Ready {
            // A ready Loro document may already contain user edits. Never
            // replace it, including from a crash-recovery retry.
            return Ok(());
        }
        if run.projection_state != ProjectionState::Pending {
            return Err(CoreError::ValidationFailed {
                message: format!(
                    "capture projection must be pending, found {:?}",
                    run.projection_state
                ),
            });
        }
        if run.provider_error_type.as_deref() == Some("local_persistence") {
            self.notebook_capture_store
                .set_projection_state(run_id, ProjectionState::Pending, ProjectionState::Failed)
                .map_err(store_error)?;
            return Err(CoreError::InternalError {
                message:
                    "realtime utterance persistence failed; local encrypted audio was preserved"
                        .to_string(),
            });
        }
        self.notebook_capture_store
            .set_projection_state(
                run_id,
                ProjectionState::Pending,
                ProjectionState::Projecting,
            )
            .map_err(store_error)?;
        let projection_result = (|| -> Result<(), CoreError> {
            let utterances = self
                .notebook_capture_store
                .list_utterances(&run.session_id)
                .map_err(store_error)?;
            self.sync_bilingual_capture_into_realtime_tab(&run, &utterances)?;
            Ok(())
        })();
        match projection_result {
            Ok(()) => Ok(()),
            Err(error) => {
                if let Err(state_error) = self.notebook_capture_store.set_projection_state(
                    run_id,
                    ProjectionState::Projecting,
                    ProjectionState::Failed,
                ) {
                    // The Ready transition may have committed before its
                    // readback failed. Preserve that terminal state; otherwise
                    // surface both errors so restart recovery can repair a
                    // genuinely stale Projecting row.
                    if !self
                        .notebook_capture_store
                        .get_run(run_id)
                        .ok()
                        .flatten()
                        .is_some_and(|run| run.projection_state == ProjectionState::Ready)
                    {
                        return Err(CoreError::InternalError {
                            message: format!(
                                "projection failed ({error}); mark failed also failed ({state_error})"
                            ),
                        });
                    }
                }
                Err(error)
            }
        }
    }

    fn sync_bilingual_capture_into_realtime_tab(
        &self,
        run: &NotebookCaptureRun,
        utterances: &[RealtimeUtterance],
    ) -> Result<(), CoreError> {
        if utterances.is_empty() {
            self.rebuild_capture_search_index(&run.session_id, utterances)?;
            return self
                .notebook_capture_store
                .complete_projection_unless_purging(&run.id)
                .map_err(store_error);
        }
        use vt_store::{BuiltinNotebookTab, EditOp};
        let _mutation_guard = crate::editor_api::editor_document_mutation_guard();

        self.notebook_store
            .ensure_session_projection(
                &run.notebook_id,
                BuiltinNotebookTab::RealtimeTranscript,
                &run.session_id,
                None,
            )
            .map_err(store_error)?;
        let tab = self
            .notebook_store
            .list_tabs(&run.notebook_id)
            .map_err(store_error)?
            .into_iter()
            .find(|tab| tab.builtin_kind == BuiltinNotebookTab::RealtimeTranscript)
            .ok_or_else(|| CoreError::NotFound {
                message: format!("Realtime Transcript tab for notebook {}", run.notebook_id),
            })?;
        crate::editor_api::open_editor_session_strict(
            &self.data_dir,
            &self.editor_bridge,
            &tab.doc_id,
        )?;
        let rollback_snapshot = self
            .editor_bridge
            .export_snapshot(&tab.doc_id)
            .map_err(store_error)?;
        let apply_result = (|| -> Result<(), CoreError> {
            let delta = self
                .editor_bridge
                .get_delta(&tab.doc_id)
                .map_err(store_error)?;
            let user_owned_lanes = user_owned_lanes(&delta, &run.session_id)?;
            let existing_range = resolve_capture_section_range(
                &self.editor_bridge,
                &tab.doc_id,
                &run.session_id,
                &delta,
            )?;
            let current_len = self
                .editor_bridge
                .get_content(&tab.doc_id)
                .map_err(store_error)?
                .chars()
                .count();
            let insert_pos = if let Some(range) = existing_range {
                if range.len > 0 {
                    self.editor_bridge
                        .apply(
                            &tab.doc_id,
                            EditOp::Delete {
                                pos: range.pos,
                                len: range.len,
                            },
                        )
                        .map_err(store_error)?;
                }
                range.pos
            } else {
                current_len
            };
            self.editor_bridge
                .clear_capture_owned_ranges_for_session(&tab.doc_id, &run.session_id)
                .map_err(store_error)?;
            let rendered =
                render_bilingual_capture_section(&run.session_id, utterances, insert_pos > 0);
            let rendered_len = rendered.text.chars().count();
            self.editor_bridge
                .apply(
                    &tab.doc_id,
                    EditOp::Insert {
                        pos: insert_pos,
                        text: rendered.text,
                    },
                )
                .map_err(store_error)?;
            for mark in rendered.marks {
                self.editor_bridge
                    .apply(
                        &tab.doc_id,
                        EditOp::Mark {
                            pos: insert_pos + mark.pos,
                            len: mark.len,
                            key: mark.key,
                            value_json: mark.value_json,
                        },
                    )
                    .map_err(store_error)?;
            }
            if !user_owned_lanes.is_empty() {
                let projected_delta = self
                    .editor_bridge
                    .get_delta(&tab.doc_id)
                    .map_err(store_error)?;
                for (utterance_id, lane_language) in user_owned_lanes {
                    if let Some(range) = crate::editor_api::find_unique_marked_range(
                        &projected_delta,
                        crate::editor_api::DeltaMarkSelector {
                            session_id: Some(&run.session_id),
                            utterance_id: Some(&utterance_id),
                            lane_language: Some(&lane_language),
                        },
                    )? {
                        self.editor_bridge
                            .apply(
                                &tab.doc_id,
                                EditOp::Mark {
                                    pos: range.pos,
                                    len: range.len,
                                    key: "content_owner".to_string(),
                                    value_json: "\"user\"".to_string(),
                                },
                            )
                            .map_err(store_error)?;
                    }
                }
            }
            self.editor_bridge
                .set_capture_owned_range(
                    &tab.doc_id,
                    &capture_section_owner_key(&run.session_id),
                    &run.session_id,
                    insert_pos,
                    insert_pos + rendered_len,
                )
                .map_err(store_error)?;
            crate::editor_api::flush_snapshot_to_disk_result(
                &self.data_dir,
                &self.editor_bridge,
                &tab.doc_id,
            )
            .map_err(|message| CoreError::InternalError { message })?;
            // This is the final projection commit. Its transaction checks the
            // durable purge tombstone and performs Projecting -> Ready as one
            // CAS. Any rejection bubbles into the Loro rollback below.
            self.rebuild_capture_search_index(&run.session_id, utterances)?;
            self.notebook_capture_store
                .complete_projection_unless_purging(&run.id)
                .map_err(store_error)?;
            Ok(())
        })();
        if let Err(error) = apply_result {
            let rollback_result = self
                .editor_bridge
                .replace_document_with_styles(
                    &tab.doc_id,
                    &rollback_snapshot,
                    crate::editor_api::voice_tool_style_config(),
                )
                .map_err(|rollback_error| rollback_error.to_string())
                .and_then(|_| {
                    crate::editor_api::flush_snapshot_to_disk_result(
                        &self.data_dir,
                        &self.editor_bridge,
                        &tab.doc_id,
                    )
                });
            if let Err(rollback_error) = rollback_result {
                tracing::error!(
                    doc_id = tab.doc_id,
                    %rollback_error,
                    "capture projection rollback failed"
                );
                return Err(CoreError::InternalError {
                    message: format!(
                        "capture projection failed ({error}); durable rollback failed ({rollback_error})"
                    ),
                });
            }
            return Err(error);
        }
        crate::editor_api::notify_editor_callback(&self.editor_callbacks, &tab.doc_id);
        Ok(())
    }
}

fn context_config_for_soniox(compilation: &ContextCompilation) -> ContextConfig {
    ContextConfig {
        general: compilation
            .context
            .general
            .iter()
            .map(|value| (value.key.clone(), value.value.clone()))
            .collect(),
        text: (!compilation.context.text.is_empty()).then(|| compilation.context.text.clone()),
        terms: compilation.context.terms.clone(),
        translation_terms: compilation
            .context
            .translation_terms
            .iter()
            .map(|value| (value.source.clone(), value.target.clone()))
            .collect(),
    }
}

struct CaptureRenderedSection {
    text: String,
    marks: Vec<CaptureRenderedMark>,
}

struct CaptureRenderedMark {
    pos: usize,
    len: usize,
    key: String,
    value_json: String,
}

fn capture_section_owner_key(session_id: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(b"zulangue:capture-section:v1\0");
    hasher.update((session_id.len() as u64).to_le_bytes());
    hasher.update(session_id.as_bytes());
    format!("section-{}", hex::encode(hasher.finalize()))
}

/// Prefers the durable CRDT-relative section boundary and validates that all
/// surviving ownership marks remain inside it. Snapshots created before the
/// anchor schema retain the strict unique-mark fallback.
fn resolve_capture_section_range(
    bridge: &vt_store::EditorBridge,
    document_id: &str,
    session_id: &str,
    delta_json: &str,
) -> Result<Option<crate::editor_api::TextRange>, CoreError> {
    let selector = crate::editor_api::DeltaMarkSelector {
        session_id: Some(session_id),
        utterance_id: None,
        lane_language: None,
    };
    let marked_ranges = crate::editor_api::find_marked_ranges(delta_json, selector)?;
    let anchored = bridge
        .resolve_capture_owned_range(
            document_id,
            &capture_section_owner_key(session_id),
            session_id,
        )
        .map_err(store_error)?;
    let Some((pos, len)) = anchored else {
        return crate::editor_api::find_unique_marked_range(delta_json, selector);
    };
    let end = pos
        .checked_add(len)
        .ok_or_else(|| CoreError::ValidationFailed {
            message: format!("capture section anchor overflow for session {session_id}"),
        })?;
    if marked_ranges.iter().any(|range| {
        range.pos < pos
            || range
                .pos
                .checked_add(range.len)
                .is_none_or(|range_end| range_end > end)
    }) {
        return Err(CoreError::ValidationFailed {
            message: format!(
                "capture ownership marks escape the durable section anchor for session {session_id}"
            ),
        });
    }
    Ok(Some(crate::editor_api::TextRange { pos, len }))
}

fn render_replacement_lane(
    current: &RealtimeUtterance,
    mutation: &NotebookProjectionMutation,
) -> CaptureRenderedSection {
    let mut prospective = current.clone();
    prospective.revision = mutation.expected_revision.saturating_add(1);
    let text = match mutation.lane {
        UtteranceLane::Source => {
            prospective.source_text = mutation.target_text.clone();
            let time = prospective
                .source_start_ms
                .map(format_capture_timestamp)
                .map(|value| format!("[{value}] "))
                .unwrap_or_default();
            if prospective.alignment == UtteranceAlignment::OutsideLanguagePair {
                format!(
                    "【超出当前语言对】{}{}: {}\n",
                    time, prospective.source_language, prospective.source_text
                )
            } else {
                format!(
                    "{}{}: {}\n",
                    time, prospective.source_language, prospective.source_text
                )
            }
        }
        UtteranceLane::Translated => {
            prospective.translated_text = Some(mutation.target_text.clone());
            format!(
                "{}: {}\n",
                prospective
                    .translated_language
                    .as_deref()
                    .unwrap_or_default(),
                mutation.target_text
            )
        }
    };
    let len = text.chars().count();
    let mut marks = Vec::new();
    let language = match mutation.lane {
        UtteranceLane::Source => prospective.source_language.as_str(),
        UtteranceLane::Translated => prospective
            .translated_language
            .as_deref()
            .unwrap_or_default(),
    };
    let timestamp = (mutation.lane == UtteranceLane::Source)
        .then_some(prospective.source_start_ms)
        .flatten();
    push_lane_marks(&mut marks, 0, len, &prospective, language, timestamp);
    CaptureRenderedSection { text, marks }
}

fn render_bilingual_capture_section(
    session_id: &str,
    utterances: &[RealtimeUtterance],
    leading_separator: bool,
) -> CaptureRenderedSection {
    let mut text = String::new();
    let mut marks = Vec::new();
    let section_start = 0;
    if leading_separator {
        text.push_str("\n\n");
    }
    text.push_str(&format!("## {session_id}\n"));

    for utterance in utterances {
        if !text.ends_with('\n') {
            text.push('\n');
        }
        let outside_pair = utterance.alignment == UtteranceAlignment::OutsideLanguagePair;
        let source_start = text.chars().count();
        let time = utterance
            .source_start_ms
            .map(format_capture_timestamp)
            .map(|value| format!("[{value}] "))
            .unwrap_or_default();
        if outside_pair {
            text.push_str(&format!(
                "【超出当前语言对】{}{}: {}\n",
                time, utterance.source_language, utterance.source_text
            ));
        } else {
            text.push_str(&format!(
                "{}{}: {}\n",
                time, utterance.source_language, utterance.source_text
            ));
        }
        let source_len = text.chars().count() - source_start;
        push_lane_marks(
            &mut marks,
            source_start,
            source_len,
            utterance,
            &utterance.source_language,
            utterance.source_start_ms,
        );

        if let (Some(language), Some(translated)) = (
            utterance.translated_language.as_deref(),
            utterance.translated_text.as_deref(),
        ) {
            let translated_start = text.chars().count();
            text.push_str(&format!("{language}: {translated}\n"));
            let translated_len = text.chars().count() - translated_start;
            // Deliberately None: Soniox translation tokens have no source
            // audio timestamp and must never inherit one.
            push_lane_marks(
                &mut marks,
                translated_start,
                translated_len,
                utterance,
                language,
                None,
            );
        }
        text.push('\n');
    }

    let section_len = text.chars().count() - section_start;
    marks.push(CaptureRenderedMark {
        pos: section_start,
        len: section_len,
        key: "session_id".to_string(),
        value_json: serde_json::to_string(session_id).unwrap_or_else(|_| "\"\"".to_string()),
    });
    CaptureRenderedSection { text, marks }
}

fn push_lane_marks(
    marks: &mut Vec<CaptureRenderedMark>,
    pos: usize,
    len: usize,
    utterance: &RealtimeUtterance,
    lane_language: &str,
    source_timestamp_ms: Option<u64>,
) {
    for (key, value_json) in [
        (
            "session_id",
            serde_json::to_string(&utterance.session_id).unwrap_or_else(|_| "\"\"".to_string()),
        ),
        (
            "utterance_id",
            serde_json::to_string(&utterance.id).unwrap_or_else(|_| "\"\"".to_string()),
        ),
        (
            "lane_language",
            serde_json::to_string(lane_language).unwrap_or_else(|_| "\"\"".to_string()),
        ),
        ("utterance_revision", utterance.revision.to_string()),
        ("content_owner", "\"machine\"".to_string()),
    ] {
        marks.push(CaptureRenderedMark {
            pos,
            len,
            key: key.to_string(),
            value_json,
        });
    }
    if let Some(timestamp) = source_timestamp_ms {
        marks.push(CaptureRenderedMark {
            pos,
            len,
            key: "source_timestamp_ms".to_string(),
            value_json: timestamp.to_string(),
        });
    }
}

fn user_owned_lanes(
    delta_json: &str,
    session_id: &str,
) -> Result<std::collections::HashSet<(String, String)>, CoreError> {
    let delta: serde_json::Value =
        serde_json::from_str(delta_json).map_err(|error| CoreError::ValidationFailed {
            message: format!("invalid editor Delta JSON: {error}"),
        })?;
    let operations = delta
        .as_array()
        .ok_or_else(|| CoreError::ValidationFailed {
            message: "editor Delta must be an array".to_string(),
        })?;
    let mut result = std::collections::HashSet::new();
    for operation in operations {
        let Some(attributes) = operation
            .get("attributes")
            .and_then(serde_json::Value::as_object)
        else {
            continue;
        };
        if attributes
            .get("session_id")
            .and_then(serde_json::Value::as_str)
            != Some(session_id)
            || attributes
                .get("content_owner")
                .and_then(serde_json::Value::as_str)
                != Some("user")
        {
            continue;
        }
        let Some(utterance_id) = attributes
            .get("utterance_id")
            .and_then(serde_json::Value::as_str)
        else {
            continue;
        };
        let Some(lane_language) = attributes
            .get("lane_language")
            .and_then(serde_json::Value::as_str)
        else {
            continue;
        };
        result.insert((utterance_id.to_string(), lane_language.to_string()));
    }
    Ok(result)
}

fn format_capture_timestamp(milliseconds: u64) -> String {
    let seconds = milliseconds / 1_000;
    let hours = seconds / 3_600;
    let minutes = (seconds % 3_600) / 60;
    let seconds = seconds % 60;
    if hours > 0 {
        format!("{hours:02}:{minutes:02}:{seconds:02}")
    } else {
        format!("{minutes:02}:{seconds:02}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn claim_current_realtime_provider(store: &NotebookCaptureStore, session_id: &str) {
        store
            .claim_provider_provenance(
                session_id,
                CaptureProviderRole::Realtime,
                CURRENT_NOTEBOOK_CAPTURE_ENGINE.provider_id,
                CURRENT_NOTEBOOK_CAPTURE_ENGINE.realtime_model_id,
            )
            .unwrap();
    }

    fn claim_current_post_stop_provider(store: &NotebookCaptureStore, session_id: &str) {
        store
            .claim_provider_provenance(
                session_id,
                CaptureProviderRole::PostStop,
                CURRENT_NOTEBOOK_CAPTURE_ENGINE.provider_id,
                CURRENT_NOTEBOOK_CAPTURE_ENGINE.post_stop_model_id,
            )
            .unwrap();
    }

    #[test]
    fn notebook_capture_engine_descriptor_matches_current_rust_engine() {
        let temp = tempfile::tempdir().unwrap();
        let core = ZulangueCore::new_for_test(temp.path().to_string_lossy().to_string()).unwrap();
        let descriptor = core.get_notebook_capture_engine_descriptor();
        let engine = CURRENT_NOTEBOOK_CAPTURE_ENGINE;

        assert_eq!(descriptor.provider_id, engine.provider_id);
        assert_eq!(
            descriptor.provider_display_name,
            engine.provider_display_name
        );
        assert_eq!(descriptor.realtime_model_id, engine.realtime_model_id);
        assert_eq!(descriptor.post_stop_model_id, engine.post_stop_model_id);
        assert_eq!(
            descriptor.supports_realtime_transcription,
            engine.supports_realtime_transcription
        );
        assert_eq!(
            descriptor.supports_two_way_translation,
            engine.supports_two_way_translation
        );
        assert_eq!(descriptor.supports_context, engine.supports_context);
        assert_eq!(
            descriptor.supports_post_stop_transcription,
            engine.supports_post_stop_transcription
        );
        assert_eq!(
            descriptor.post_stop_execution,
            FfiNotebookPostStopExecution::RealtimeRestream
        );
    }

    #[test]
    fn notebook_capture_history_ffi_keeps_empty_runs_and_exposes_only_audio_presence() {
        let temp = tempfile::tempdir().unwrap();
        let core = ZulangueCore::new_for_test(temp.path().to_string_lossy().to_string()).unwrap();
        let notebook = core.create_notebook(Some("History FFI".into())).unwrap();
        let profile = core
            .notebook_capture_store
            .get_or_create_profile(&notebook.id)
            .unwrap();
        let session = vt_store::SessionRecord {
            id: "history-ffi-session".into(),
            title: "Local recording".into(),
            session_type: "recording".into(),
            status: "recording".into(),
            duration_ms: 0,
            created_at: "2001-01-02T12:00:00Z".into(),
            deleted_at: None,
        };
        core.notebook_capture_store
            .create_session_and_run(
                &session,
                &vt_store::notebook_capture_store::NewNotebookCaptureRun {
                    id: "history-ffi-run".into(),
                    notebook_id: notebook.id.clone(),
                    session_id: session.id.clone(),
                    remote_health: RemoteHealth::Off,
                    audio_journal_path: "/private/history-ffi.journal".into(),
                    audio_key_ref: "private-history-ffi-key".into(),
                    sample_rate: 16_000,
                    channels: 1,
                },
                &profile,
            )
            .unwrap();

        let history = core
            .list_notebook_capture_history(notebook.id.clone())
            .unwrap();
        assert_eq!(history.len(), 1);
        let run = &history[0];
        assert_eq!(run.run_id, "history-ffi-run");
        assert_eq!(run.notebook_id, notebook.id);
        assert_eq!(run.session_id, session.id);
        assert_eq!(run.mode, Some(FfiNotebookCaptureMode::TranscriptionOnly));
        assert_eq!(run.selected_languages, ["en", "zh"]);
        assert_eq!(run.common_caption_language, None);
        assert!(run.has_audio);
        assert!(run.utterances.is_empty());
    }

    struct CaptureEventSender(std::sync::mpsc::Sender<FfiNotebookCaptureEvent>);

    impl FfiNotebookCaptureCallback for CaptureEventSender {
        fn on_capture_event(&self, event: FfiNotebookCaptureEvent) {
            let _ = self.0.send(event);
        }

        fn on_live_preview(&self, _preview: FfiNotebookCaptureLivePreview) {}
    }

    #[derive(Default)]
    struct CountingNotebookSonioxStreamFactory {
        constructor_count: AtomicUsize,
        pcm_send_count: AtomicUsize,
    }

    impl NotebookSonioxStreamFactory for CountingNotebookSonioxStreamFactory {
        fn start(
            &self,
            _endpoint: &str,
            _api_key: String,
            _config: SttConfig,
            _cancel: tokio_util::sync::CancellationToken,
        ) -> SonioxStreamRuntime {
            self.constructor_count.fetch_add(1, Ordering::SeqCst);
            panic!("remote-off capture constructed a Soniox stream")
        }

        fn try_send_pcm(
            &self,
            _audio_tx: &tokio::sync::mpsc::Sender<Vec<u8>>,
            _audio_data: Vec<u8>,
        ) -> Result<(), String> {
            self.pcm_send_count.fetch_add(1, Ordering::SeqCst);
            Err("remote-off capture sent PCM to Soniox".to_string())
        }
    }

    struct RemoteLifetimeGuard(Arc<AtomicUsize>);

    impl Drop for RemoteLifetimeGuard {
        fn drop(&mut self) {
            self.0.fetch_sub(1, Ordering::SeqCst);
        }
    }

    #[derive(Default)]
    struct TeardownTrackingNotebookSonioxStreamFactory {
        constructor_count: AtomicUsize,
        active_stream_count: Arc<AtomicUsize>,
        last_cancel: StdMutex<Option<tokio_util::sync::CancellationToken>>,
        last_config: StdMutex<Option<SttConfig>>,
        configs: StdMutex<Vec<SttConfig>>,
        pcm_send_count: AtomicUsize,
        fail_pcm_send: AtomicBool,
        hold_event_sender: AtomicBool,
        held_event_sender: StdMutex<Option<tokio::sync::mpsc::Sender<SttStreamEvent>>>,
    }

    impl NotebookSonioxStreamFactory for TeardownTrackingNotebookSonioxStreamFactory {
        fn start(
            &self,
            _endpoint: &str,
            _api_key: String,
            config: SttConfig,
            cancel: tokio_util::sync::CancellationToken,
        ) -> SonioxStreamRuntime {
            self.constructor_count.fetch_add(1, Ordering::SeqCst);
            *self.last_cancel.lock().unwrap() = Some(cancel.clone());
            self.configs.lock().unwrap().push(config.clone());
            *self.last_config.lock().unwrap() = Some(config);

            let (audio_tx, audio_rx) = tokio::sync::mpsc::channel(4);
            let (control_tx, control_rx) = tokio::sync::mpsc::channel(4);
            let (event_tx, event_rx) = tokio::sync::mpsc::channel(4);
            if self.hold_event_sender.load(Ordering::SeqCst) {
                *self.held_event_sender.lock().unwrap() = Some(event_tx.clone());
            }
            self.active_stream_count.fetch_add(1, Ordering::SeqCst);
            let lifetime = RemoteLifetimeGuard(self.active_stream_count.clone());
            let task = tokio::spawn(async move {
                let _lifetime = lifetime;
                let _event_tx = event_tx;
                let _audio_rx = audio_rx;
                let _control_rx = control_rx;
                cancel.cancelled().await;
                Ok(())
            });
            SonioxStreamRuntime {
                audio_tx,
                control_tx,
                event_rx,
                task,
            }
        }

        fn try_send_pcm(
            &self,
            audio_tx: &tokio::sync::mpsc::Sender<Vec<u8>>,
            audio_data: Vec<u8>,
        ) -> Result<(), String> {
            if self.fail_pcm_send.load(Ordering::SeqCst) {
                return Err("injected Soniox PCM backpressure".to_string());
            }
            self.pcm_send_count.fetch_add(1, Ordering::SeqCst);
            audio_tx
                .try_send(audio_data)
                .map_err(|error| error.to_string())
        }
    }

    #[test]
    fn default_remote_off_constructs_no_soniox_stream_and_sends_no_pcm() {
        let temp = tempfile::tempdir().unwrap();
        let mut core =
            ZulangueCore::new_for_test(temp.path().to_string_lossy().to_string()).unwrap();
        let factory = Arc::new(CountingNotebookSonioxStreamFactory::default());
        core.notebook_soniox_stream_factory = factory.clone();
        // A configured key rules out "missing credentials" as the reason the
        // provider path was skipped. The explicit profile switch is the gate.
        core.set_api_key("soniox".to_string(), "configured-test-key".to_string())
            .unwrap();

        let notebook = core
            .create_notebook(Some("Remote-off counter".into()))
            .unwrap();
        let profile = core
            .get_notebook_capture_profile(notebook.id.clone())
            .unwrap();
        assert!(!profile.remote_realtime_enabled);

        let started = core
            .start_notebook_capture_session(
                notebook.id,
                profile.revision,
                None,
                Box::new(CaptureEventSender(std::sync::mpsc::channel().0)),
            )
            .unwrap();
        assert_eq!(started.remote_health, FfiNotebookRemoteHealth::Off);
        assert_eq!(factory.constructor_count.load(Ordering::SeqCst), 0);

        core.push_notebook_capture_session(started.session_id.clone(), vec![0_u8; 3_200])
            .unwrap();
        assert_eq!(factory.pcm_send_count.load(Ordering::SeqCst), 0);
        assert_eq!(factory.constructor_count.load(Ordering::SeqCst), 0);

        core.stop_notebook_capture_session(started.session_id)
            .unwrap();
        assert_eq!(factory.pcm_send_count.load(Ordering::SeqCst), 0);
        assert_eq!(factory.constructor_count.load(Ordering::SeqCst), 0);
    }

    #[test]
    fn multilingual_profile_starts_one_authoritative_timeline_and_one_stream_per_target() {
        let temp = tempfile::tempdir().unwrap();
        let mut core =
            ZulangueCore::new_for_test(temp.path().to_string_lossy().to_string()).unwrap();
        let factory = Arc::new(TeardownTrackingNotebookSonioxStreamFactory::default());
        core.notebook_soniox_stream_factory = factory.clone();
        core.set_api_key("soniox".to_string(), "configured-test-key".to_string())
            .unwrap();

        let notebook = core
            .create_notebook(Some("Multilingual config".into()))
            .unwrap();
        let mut profile = core
            .get_notebook_capture_profile(notebook.id.clone())
            .unwrap();
        profile.remote_realtime_enabled = true;
        profile.selected_languages = vec!["en".into(), "zh".into(), "th".into()];
        profile.common_caption_language = None;
        let profile = core.update_notebook_capture_profile(profile).unwrap();
        assert_eq!(profile.mode, FfiNotebookCaptureMode::MultilingualOneWay);

        let started = core
            .start_notebook_capture_session(
                notebook.id,
                profile.revision,
                None,
                Box::new(CaptureEventSender(std::sync::mpsc::channel().0)),
            )
            .unwrap();
        assert_eq!(
            started.mode,
            Some(FfiNotebookCaptureMode::MultilingualOneWay)
        );
        assert_eq!(started.selected_languages, ["en", "zh", "th"]);
        assert_eq!(started.common_caption_language, None);
        assert_eq!(factory.constructor_count.load(Ordering::SeqCst), 4);
        {
            let configs = factory.configs.lock().unwrap();
            assert_eq!(configs.len(), 4);
            assert!(
                configs[0].translation.is_none(),
                "the authoritative timeline must not depend on a display-language target"
            );
            let targets = configs
                .iter()
                .skip(1)
                .map(|config| {
                    assert_eq!(config.language_hints, ["en", "zh", "th"]);
                    match config.translation.as_ref() {
                        Some(TranslationConfig::OneWay { target_language }) => {
                            target_language.as_str()
                        }
                        _ => panic!("expected one-way translation per selected language"),
                    }
                })
                .collect::<Vec<_>>();
            assert_eq!(targets, ["en", "zh", "th"]);
        }
        core.push_notebook_capture_session(started.session_id.clone(), vec![0_u8; 3_200])
            .unwrap();
        assert_eq!(
            factory.pcm_send_count.load(Ordering::SeqCst),
            4,
            "one local PCM ingress must reach the timeline and every target stream"
        );
        core.interrupt_notebook_capture_session(
            started.session_id,
            FfiNotebookCaptureInterruptReason::LocalAudioUnavailable,
        )
        .unwrap();
    }

    #[test]
    fn selected_language_order_changes_targets_but_not_the_authoritative_timeline() {
        for selected in [
            vec!["en".to_string(), "zh".to_string(), "th".to_string()],
            vec!["th".to_string(), "en".to_string(), "zh".to_string()],
            vec!["zh".to_string(), "th".to_string(), "en".to_string()],
        ] {
            let plan = remote_stream_plan(&selected).unwrap();
            assert_eq!(plan.len(), 4);
            assert!(
                plan[0].0.is_none() && plan[0].1.is_none(),
                "the first plan entry is a language-free timeline, not the first display column"
            );
            let targets = plan
                .iter()
                .skip(1)
                .map(|(target, translation)| {
                    let target = target.as_deref().expect("target lane");
                    assert!(matches!(
                        translation,
                        Some(TranslationConfig::OneWay { target_language })
                            if target_language == target
                    ));
                    target.to_string()
                })
                .collect::<Vec<_>>();
            assert_eq!(targets, selected);
        }
    }

    #[test]
    fn realtime_provenance_claim_failure_constructs_no_soniox_stream() {
        let temp = tempfile::tempdir().unwrap();
        let mut core =
            ZulangueCore::new_for_test(temp.path().to_string_lossy().to_string()).unwrap();
        let factory = Arc::new(CountingNotebookSonioxStreamFactory::default());
        core.notebook_soniox_stream_factory = factory.clone();
        core.set_api_key("soniox".to_string(), "configured-test-key".to_string())
            .unwrap();

        let notebook = core
            .create_notebook(Some("Provider claim fault".into()))
            .unwrap();
        let mut profile = core
            .get_notebook_capture_profile(notebook.id.clone())
            .unwrap();
        profile.remote_realtime_enabled = true;
        let profile = core.update_notebook_capture_profile(profile).unwrap();
        let db = rusqlite::Connection::open(temp.path().join("zulangue.db")).unwrap();
        db.execute_batch(
            "CREATE TRIGGER fail_realtime_provider_provenance
             BEFORE UPDATE OF realtime_provider_id, realtime_model_id
             ON notebook_capture_runs
             WHEN NEW.realtime_provider_id IS NOT NULL
             BEGIN
               SELECT RAISE(ABORT, 'injected realtime provenance failure');
             END;",
        )
        .unwrap();

        let started = core
            .start_notebook_capture_session(
                notebook.id,
                profile.revision,
                None,
                Box::new(CaptureEventSender(std::sync::mpsc::channel().0)),
            )
            .expect("local capture must continue when the durable remote claim fails");

        assert_eq!(started.remote_health, FfiNotebookRemoteHealth::Unavailable);
        assert_eq!(factory.constructor_count.load(Ordering::SeqCst), 0);
        assert_eq!(factory.pcm_send_count.load(Ordering::SeqCst), 0);
        let run = core
            .notebook_capture_store
            .get_run_for_session(&started.session_id)
            .unwrap()
            .unwrap();
        assert!(run.realtime_provider_id.is_none());
        assert!(run.realtime_model_id.is_none());

        core.interrupt_notebook_capture_session(
            started.session_id,
            FfiNotebookCaptureInterruptReason::LocalAudioUnavailable,
        )
        .unwrap();
    }

    #[test]
    fn interrupt_persistence_failure_tears_down_remote_owner_and_recoverable_journal() {
        let temp = tempfile::tempdir().unwrap();
        let mut core =
            ZulangueCore::new_for_test(temp.path().to_string_lossy().to_string()).unwrap();
        let factory = Arc::new(TeardownTrackingNotebookSonioxStreamFactory::default());
        core.notebook_soniox_stream_factory = factory.clone();
        core.set_api_key("soniox".to_string(), "configured-test-key".to_string())
            .unwrap();

        let notebook = core
            .create_notebook(Some("Interrupt persistence fault".into()))
            .unwrap();
        let mut profile = core
            .get_notebook_capture_profile(notebook.id.clone())
            .unwrap();
        profile.remote_realtime_enabled = true;
        let profile = core.update_notebook_capture_profile(profile).unwrap();
        let started = core
            .start_notebook_capture_session(
                notebook.id.clone(),
                profile.revision,
                None,
                Box::new(CaptureEventSender(std::sync::mpsc::channel().0)),
            )
            .unwrap();
        core.push_notebook_capture_session(started.session_id.clone(), vec![0_u8; 3_200])
            .unwrap();
        let run = core
            .notebook_capture_store
            .get_run_for_session(&started.session_id)
            .unwrap()
            .unwrap();
        let journal_path = std::path::PathBuf::from(run.audio_journal_path.as_ref().unwrap());
        assert!(journal_path.exists());
        assert_eq!(factory.constructor_count.load(Ordering::SeqCst), 1);
        assert_eq!(factory.active_stream_count.load(Ordering::SeqCst), 1);

        let db = rusqlite::Connection::open(temp.path().join("zulangue.db")).unwrap();
        db.execute_batch(
            "CREATE TRIGGER fail_all_capture_interrupt_recovery
             BEFORE UPDATE OF capture_state ON notebook_capture_runs
             WHEN NEW.capture_state = 'interrupted'
             BEGIN
                 SELECT RAISE(FAIL, 'injected interrupt and recovery persistence failure');
             END;",
        )
        .unwrap();

        let error = core
            .interrupt_notebook_capture_session(
                started.session_id.clone(),
                FfiNotebookCaptureInterruptReason::LocalAudioUnavailable,
            )
            .unwrap_err();
        assert!(error
            .to_string()
            .contains("injected interrupt and recovery persistence failure"));
        assert!(
            core.active_notebook_capture.lock().unwrap().is_none(),
            "a failed durable interrupt must still release the process owner"
        );
        assert!(factory
            .last_cancel
            .lock()
            .unwrap()
            .as_ref()
            .unwrap()
            .is_cancelled());
        assert_eq!(
            factory.active_stream_count.load(Ordering::SeqCst),
            0,
            "no Soniox writer may remain detached after interrupt returns"
        );

        let still_unfinished = core
            .notebook_capture_store
            .get_run(&run.id)
            .unwrap()
            .unwrap();
        assert_eq!(still_unfinished.capture_state, CaptureState::Recording);
        assert_ne!(
            still_unfinished.provider_error_type.as_deref(),
            Some("local_audio_unavailable"),
            "fallback recovery must not pretend the requested interruption was durably recorded"
        );
        assert!(
            journal_path.exists(),
            "a journal without durable recovery indexes must remain recoverable"
        );
        assert!(core
            .detached_notebook_capture_runs
            .lock()
            .unwrap()
            .contains(&run.id));

        db.execute_batch("DROP TRIGGER fail_all_capture_interrupt_recovery;")
            .unwrap();
        let next = core
            .start_notebook_capture_session(
                notebook.id,
                profile.revision,
                None,
                Box::new(CaptureEventSender(std::sync::mpsc::channel().0)),
            )
            .expect("interrupt persistence failure must not block the next capture");
        let recovered = core
            .notebook_capture_store
            .get_run(&run.id)
            .unwrap()
            .unwrap();
        assert_eq!(recovered.capture_state, CaptureState::Interrupted);
        assert_eq!(recovered.remote_health, RemoteHealth::Off);
        assert!(recovered
            .audio_path
            .as_deref()
            .is_some_and(|path| std::path::Path::new(path).exists()));
        assert!(
            !journal_path.exists(),
            "the next start must recover, index, and clean the detached journal"
        );
        assert!(core
            .detached_notebook_capture_runs
            .lock()
            .unwrap()
            .is_empty());
        core.interrupt_notebook_capture_session(
            next.session_id,
            FfiNotebookCaptureInterruptReason::LocalAudioUnavailable,
        )
        .unwrap();
        assert_eq!(factory.active_stream_count.load(Ordering::SeqCst), 0);
    }

    #[test]
    fn purged_detached_capture_marker_does_not_block_the_next_capture() {
        let temp = tempfile::tempdir().unwrap();
        let core = ZulangueCore::new_for_test(temp.path().to_string_lossy().to_string()).unwrap();
        let notebook = core
            .create_notebook(Some("Purged detached marker".into()))
            .unwrap();
        let profile = core
            .get_notebook_capture_profile(notebook.id.clone())
            .unwrap();
        core.detached_notebook_capture_runs
            .lock()
            .unwrap()
            .insert("run-already-removed-by-delete-forever".into());

        let started = core
            .start_notebook_capture_session(
                notebook.id,
                profile.revision,
                None,
                Box::new(CaptureEventSender(std::sync::mpsc::channel().0)),
            )
            .expect("a Delete Forever-converged marker must not wedge capture ownership");
        assert!(core
            .detached_notebook_capture_runs
            .lock()
            .unwrap()
            .is_empty());
        core.interrupt_notebook_capture_session(
            started.session_id,
            FfiNotebookCaptureInterruptReason::LocalAudioUnavailable,
        )
        .unwrap();
    }

    fn start_remote_tracking_capture(
        title: &str,
    ) -> (
        tempfile::TempDir,
        ZulangueCore,
        Arc<TeardownTrackingNotebookSonioxStreamFactory>,
        String,
        FfiNotebookCaptureProfile,
        FfiNotebookCaptureEvent,
    ) {
        let temp = tempfile::tempdir().unwrap();
        let mut core =
            ZulangueCore::new_for_test(temp.path().to_string_lossy().to_string()).unwrap();
        let factory = Arc::new(TeardownTrackingNotebookSonioxStreamFactory::default());
        core.notebook_soniox_stream_factory = factory.clone();
        core.set_api_key("soniox".to_string(), "configured-test-key".to_string())
            .unwrap();
        let notebook = core.create_notebook(Some(title.into())).unwrap();
        let mut profile = core
            .get_notebook_capture_profile(notebook.id.clone())
            .unwrap();
        profile.remote_realtime_enabled = true;
        let profile = core.update_notebook_capture_profile(profile).unwrap();
        let started = core
            .start_notebook_capture_session(
                notebook.id.clone(),
                profile.revision,
                None,
                Box::new(CaptureEventSender(std::sync::mpsc::channel().0)),
            )
            .unwrap();
        (temp, core, factory, notebook.id, profile, started)
    }

    #[test]
    fn successful_audio_push_does_not_wait_for_the_long_running_ownership_gate() {
        let temp = tempfile::tempdir().unwrap();
        let core = ZulangueCore::new_for_test(temp.path().to_string_lossy().to_string()).unwrap();
        let notebook = core
            .create_notebook(Some("Nonblocking push".into()))
            .unwrap();
        let profile = core
            .get_notebook_capture_profile(notebook.id.clone())
            .unwrap();
        let started = core
            .start_notebook_capture_session(
                notebook.id,
                profile.revision,
                None,
                Box::new(CaptureEventSender(std::sync::mpsc::channel().0)),
            )
            .unwrap();

        let ownership_guard = core.capture_ownership_gate.lock().unwrap();
        let (tx, rx) = std::sync::mpsc::channel();
        std::thread::scope(|scope| {
            let session_id = started.session_id.clone();
            let handle = scope.spawn(|| {
                let result = core
                    .push_notebook_capture_session(session_id, vec![0_u8; 3_200])
                    .map_err(|error| error.to_string());
                tx.send(result).unwrap();
            });
            let quick = rx.recv_timeout(std::time::Duration::from_millis(300));
            let returned_while_gate_was_held = quick.is_ok();
            drop(ownership_guard);
            let result = quick.unwrap_or_else(|_| {
                rx.recv_timeout(std::time::Duration::from_secs(2))
                    .expect("push must finish after the test releases the ownership gate")
            });
            handle.join().unwrap();
            assert!(
                returned_while_gate_was_held,
                "successful audio push must not wait behind a long purge/projection gate"
            );
            result.unwrap();
        });

        let frames = core
            .active_notebook_capture
            .lock()
            .unwrap()
            .as_ref()
            .unwrap()
            .journal
            .captured_frames();
        assert_eq!(frames, 1_600, "the unblocked push must still journal audio");
        core.interrupt_notebook_capture_session(
            started.session_id,
            FfiNotebookCaptureInterruptReason::LocalAudioUnavailable,
        )
        .unwrap();
    }

    #[test]
    fn remote_backpressure_drain_does_not_consume_the_nine_block_local_queue_budget() {
        let temp = tempfile::tempdir().unwrap();
        let mut core =
            ZulangueCore::new_for_test(temp.path().to_string_lossy().to_string()).unwrap();
        let factory = Arc::new(TeardownTrackingNotebookSonioxStreamFactory::default());
        factory.fail_pcm_send.store(true, Ordering::SeqCst);
        factory.hold_event_sender.store(true, Ordering::SeqCst);
        core.notebook_soniox_stream_factory = factory.clone();
        core.set_api_key("soniox".to_string(), "configured-test-key".to_string())
            .unwrap();
        let notebook = core
            .create_notebook(Some("Slow remote drain".into()))
            .unwrap();
        let mut profile = core
            .get_notebook_capture_profile(notebook.id.clone())
            .unwrap();
        profile.remote_realtime_enabled = true;
        let profile = core.update_notebook_capture_profile(profile).unwrap();
        let started = core
            .start_notebook_capture_session(
                notebook.id,
                profile.revision,
                None,
                Box::new(CaptureEventSender(std::sync::mpsc::channel().0)),
            )
            .unwrap();

        let began = std::time::Instant::now();
        for _ in 0..9 {
            core.push_notebook_capture_session(started.session_id.clone(), vec![0_u8; 3_200])
                .unwrap();
        }
        let elapsed = began.elapsed();
        let active_run = core
            .notebook_capture_store
            .get_run_for_session(&started.session_id)
            .unwrap()
            .unwrap();
        assert_eq!(active_run.capture_state, CaptureState::Recording);
        assert_eq!(active_run.remote_health, RemoteHealth::Degraded);
        let paused = core
            .pause_notebook_capture_session(started.session_id.clone(), true)
            .unwrap();
        assert_eq!(paused.capture_state, FfiNotebookCaptureState::Paused);
        assert_eq!(paused.remote_health, FfiNotebookRemoteHealth::Degraded);
        let resumed = core
            .pause_notebook_capture_session(started.session_id.clone(), false)
            .unwrap();
        assert_eq!(resumed.capture_state, FfiNotebookCaptureState::Recording);
        assert_eq!(resumed.remote_health, FfiNotebookRemoteHealth::Degraded);
        assert_eq!(
            factory.constructor_count.load(Ordering::SeqCst),
            1,
            "FFI backpressure teardown must not create a second stream owner"
        );
        let stop_began = std::time::Instant::now();
        let stopped = core
            .stop_notebook_capture_session(started.session_id)
            .unwrap();
        let stop_elapsed = stop_began.elapsed();
        factory.held_event_sender.lock().unwrap().take();

        assert!(
            elapsed < std::time::Duration::from_millis(800),
            "nine local journal pushes took {elapsed:?}; remote event drain exhausted the Swift queue budget"
        );
        assert_eq!(stopped.capture_state, FfiNotebookCaptureState::Completed);
        assert!(
            stop_elapsed < std::time::Duration::from_millis(1_500),
            "stop did not bounded-join the pending remote cleanup: {stop_elapsed:?}"
        );
    }

    #[test]
    fn closed_audio_channel_does_not_mask_a_persisted_provider_failure() {
        let (_temp, core, factory, _notebook_id, _profile, started) =
            start_remote_tracking_capture("Preserve provider failure");
        let run = core
            .notebook_capture_store
            .get_run_for_session(&started.session_id)
            .unwrap()
            .unwrap();
        core.notebook_capture_store
            .update_remote_health(
                &run.id,
                RemoteHealth::Degraded,
                Some(&ProviderFailure {
                    error_type: "quota_exhausted".into(),
                    request_id: Some("safe-request-id".into()),
                }),
            )
            .unwrap();
        factory.fail_pcm_send.store(true, Ordering::SeqCst);

        core.push_notebook_capture_session(started.session_id.clone(), vec![0_u8; 3_200])
            .unwrap();

        let after_push = core
            .notebook_capture_store
            .get_run(&run.id)
            .unwrap()
            .unwrap();
        assert_eq!(
            after_push.provider_error_type.as_deref(),
            Some("quota_exhausted")
        );
        assert_eq!(
            after_push.provider_request_id.as_deref(),
            Some("safe-request-id")
        );
        core.stop_notebook_capture_session(started.session_id)
            .unwrap();
    }

    #[test]
    fn audio_progress_persistence_failure_cannot_leave_a_silent_recording_owner() {
        let (temp, core, factory, notebook_id, profile, started) =
            start_remote_tracking_capture("Audio progress fault");
        let run = core
            .notebook_capture_store
            .get_run_for_session(&started.session_id)
            .unwrap()
            .unwrap();
        let journal_path = std::path::PathBuf::from(run.audio_journal_path.as_ref().unwrap());
        let db = rusqlite::Connection::open(temp.path().join("zulangue.db")).unwrap();
        db.execute_batch(
            "CREATE TRIGGER fail_capture_audio_progress
             BEFORE UPDATE OF captured_frames ON notebook_capture_runs
             WHEN OLD.id IS NOT NULL AND NEW.capture_state = 'recording'
             BEGIN
                 SELECT RAISE(FAIL, 'injected audio progress persistence failure');
             END;",
        )
        .unwrap();

        let error = core
            .push_notebook_capture_session(started.session_id.clone(), vec![0_u8; 32_000])
            .unwrap_err();
        assert!(error
            .to_string()
            .contains("injected audio progress persistence failure"));
        assert!(core.active_notebook_capture.lock().unwrap().is_none());
        assert_eq!(factory.active_stream_count.load(Ordering::SeqCst), 0);
        let interrupted = core
            .notebook_capture_store
            .get_run(&run.id)
            .unwrap()
            .unwrap();
        assert_eq!(interrupted.capture_state, CaptureState::Interrupted);
        assert_eq!(interrupted.remote_health, RemoteHealth::Off);
        assert!(interrupted
            .audio_path
            .as_deref()
            .is_some_and(|path| std::path::Path::new(path).exists()));
        assert!(!journal_path.exists());

        db.execute_batch("DROP TRIGGER fail_capture_audio_progress;")
            .unwrap();
        let next = core
            .start_notebook_capture_session(
                notebook_id,
                profile.revision,
                None,
                Box::new(CaptureEventSender(std::sync::mpsc::channel().0)),
            )
            .expect("post-journal progress failure must release capture ownership");
        core.interrupt_notebook_capture_session(
            next.session_id,
            FfiNotebookCaptureInterruptReason::LocalAudioUnavailable,
        )
        .unwrap();
    }

    #[test]
    fn remote_health_persistence_failure_cannot_leave_a_silent_recording_owner() {
        let (temp, core, factory, notebook_id, profile, started) =
            start_remote_tracking_capture("Remote health fault");
        factory.fail_pcm_send.store(true, Ordering::SeqCst);
        let run = core
            .notebook_capture_store
            .get_run_for_session(&started.session_id)
            .unwrap()
            .unwrap();
        let journal_path = std::path::PathBuf::from(run.audio_journal_path.as_ref().unwrap());
        let db = rusqlite::Connection::open(temp.path().join("zulangue.db")).unwrap();
        db.execute_batch(
            "CREATE TRIGGER fail_capture_remote_health
             BEFORE UPDATE OF remote_health ON notebook_capture_runs
             WHEN NEW.remote_health = 'degraded'
             BEGIN
                 SELECT RAISE(FAIL, 'injected remote health persistence failure');
             END;",
        )
        .unwrap();

        let error = core
            .push_notebook_capture_session(started.session_id.clone(), vec![0_u8; 3_200])
            .unwrap_err();
        assert!(error
            .to_string()
            .contains("injected remote health persistence failure"));
        assert!(core.active_notebook_capture.lock().unwrap().is_none());
        assert_eq!(factory.active_stream_count.load(Ordering::SeqCst), 0);
        let interrupted = core
            .notebook_capture_store
            .get_run(&run.id)
            .unwrap()
            .unwrap();
        assert_eq!(interrupted.capture_state, CaptureState::Interrupted);
        assert_eq!(interrupted.remote_health, RemoteHealth::Off);
        assert!(interrupted
            .audio_path
            .as_deref()
            .is_some_and(|path| std::path::Path::new(path).exists()));
        assert!(!journal_path.exists());

        db.execute_batch("DROP TRIGGER fail_capture_remote_health;")
            .unwrap();
        factory.fail_pcm_send.store(false, Ordering::SeqCst);
        let next = core
            .start_notebook_capture_session(
                notebook_id,
                profile.revision,
                None,
                Box::new(CaptureEventSender(std::sync::mpsc::channel().0)),
            )
            .expect("post-journal remote-health failure must release capture ownership");
        core.interrupt_notebook_capture_session(
            next.session_id,
            FfiNotebookCaptureInterruptReason::LocalAudioUnavailable,
        )
        .unwrap();
    }

    fn profile() -> NotebookCaptureProfile {
        NotebookCaptureProfile {
            notebook_id: "notebook-a".into(),
            remote_realtime_enabled: true,
            capture_mode: CaptureMode::TwoWay,
            language_a: "en".into(),
            language_b: "zh".into(),
            left_language: "en".into(),
            right_language: "zh".into(),
            selected_languages: vec!["en".into(), "zh".into()],
            common_caption_language: None,
            privacy_level: "standard".into(),
            send_context_to_soniox: false,
            revision: 0,
            created_at: String::new(),
            updated_at: String::new(),
        }
    }

    fn token(
        text: &str,
        status: SttStreamTranslationStatus,
        language: &str,
        start_ms: Option<u64>,
        end_ms: Option<u64>,
        is_final: bool,
    ) -> SttStreamToken {
        SttStreamToken {
            text: text.into(),
            start_ms,
            end_ms,
            is_final,
            confidence: None,
            translation_status: status,
            language: Some(language.into()),
            source_language: None,
            speaker: None,
        }
    }

    fn attributed_token(
        text: &str,
        status: SttStreamTranslationStatus,
        language: Option<&str>,
        source_language: Option<&str>,
        speaker: Option<&str>,
        is_final: bool,
    ) -> SttStreamToken {
        SttStreamToken {
            text: text.into(),
            start_ms: None,
            end_ms: None,
            is_final,
            confidence: None,
            translation_status: status,
            language: language.map(str::to_string),
            source_language: source_language.map(str::to_string),
            speaker: speaker.map(str::to_string),
        }
    }

    fn only_utterance(mut updates: Vec<AssembledRealtimeUtterance>) -> NewRealtimeUtterance {
        assert_eq!(updates.len(), 1);
        updates.remove(0).utterance
    }

    fn assert_store_valid_alignment_shape(utterance: &NewRealtimeUtterance) {
        assert_eq!(
            utterance.translated_text.is_some(),
            utterance.alignment == UtteranceAlignment::Paired
        );
        assert_eq!(
            utterance.translated_text.is_some(),
            utterance.translated_language.is_some()
        );
    }

    #[test]
    fn assembler_publication_shapes_upsert_without_local_persistence_failure() {
        let temp = tempfile::tempdir().unwrap();
        let core = ZulangueCore::new_for_test(temp.path().to_string_lossy().to_string()).unwrap();
        let notebook = core
            .create_notebook(Some("Assembler store shape".into()))
            .unwrap();
        let stored_profile = core
            .notebook_capture_store
            .get_or_create_profile(&notebook.id)
            .unwrap();
        let session = vt_store::SessionRecord {
            id: "assembler-store-shape-session".into(),
            title: "Assembler store shape".into(),
            session_type: "recording".into(),
            status: "recording".into(),
            duration_ms: 0,
            created_at: "2001-01-03T00:00:00Z".into(),
            deleted_at: None,
        };
        core.notebook_capture_store
            .create_session_and_run(
                &session,
                &vt_store::notebook_capture_store::NewNotebookCaptureRun {
                    id: "assembler-store-shape-run".into(),
                    notebook_id: notebook.id,
                    session_id: session.id.clone(),
                    remote_health: RemoteHealth::Off,
                    audio_journal_path: "/private/assembler-store-shape.journal".into(),
                    audio_key_ref: "assembler-store-shape-key".into(),
                    sample_rate: 16_000,
                    channels: 1,
                },
                &stored_profile,
            )
            .unwrap();
        claim_current_realtime_provider(&core.notebook_capture_store, &session.id);

        let mut assembler = RealtimeUtteranceAssembler::new(session.id.clone(), &profile());
        let paired = assembler.apply_tokens(&[
            attributed_token(
                "hello",
                SttStreamTranslationStatus::Original,
                Some("en"),
                None,
                Some("speaker-a"),
                true,
            ),
            attributed_token(
                "你好",
                SttStreamTranslationStatus::Translation,
                Some("zh"),
                Some("en"),
                Some("speaker-a"),
                true,
            ),
        ]);
        let persisted =
            persist_assembled_utterances(&core.notebook_capture_store, &mut assembler, paired, 0)
                .unwrap();
        assert_eq!(persisted.len(), 1);
        assert_eq!(persisted[0].alignment, UtteranceAlignment::Paired);
        let completed = assembler.finalize();
        persist_assembled_utterances(&core.notebook_capture_store, &mut assembler, completed, 0)
            .unwrap();
        assembler.advance();

        assert!(assembler
            .apply_tokens(&[attributed_token(
                "ภาษาไม่แน่นอน",
                SttStreamTranslationStatus::Original,
                Some("th"),
                None,
                Some("speaker-b"),
                false,
            )])
            .is_empty());
        let forced_neutral = assembler.finalize();
        assert_eq!(forced_neutral.len(), 1);
        assert_eq!(forced_neutral[0].utterance.source_language, "und");
        persist_assembled_utterances(
            &core.notebook_capture_store,
            &mut assembler,
            forced_neutral,
            0,
        )
        .unwrap();
        assembler.advance();

        assert!(assembler
            .apply_tokens(&[attributed_token(
                "temporary",
                SttStreamTranslationStatus::Original,
                Some("en"),
                None,
                Some("speaker-a"),
                false,
            )])
            .is_empty());
        assert!(assembler
            .apply_tokens(&[attributed_token(
                "临时译文",
                SttStreamTranslationStatus::Translation,
                Some("zh"),
                Some("en"),
                None,
                true,
            )])
            .is_empty());
        assert_eq!(
            core.notebook_capture_store
                .list_utterances(&session.id)
                .unwrap()
                .len(),
            2
        );
        assembler.advance();

        let overlap = assembler.apply_tokens(&[
            attributed_token(
                "first",
                SttStreamTranslationStatus::Original,
                Some("en"),
                None,
                Some("speaker-a"),
                true,
            ),
            attributed_token(
                "second",
                SttStreamTranslationStatus::Original,
                Some("en"),
                None,
                Some("speaker-b"),
                true,
            ),
            attributed_token(
                "不得误挂",
                SttStreamTranslationStatus::Translation,
                Some("zh"),
                Some("en"),
                None,
                true,
            ),
        ]);
        assert_eq!(overlap.len(), 2);
        assert!(overlap
            .iter()
            .all(|update| update.utterance.translated_text.is_none()));
        persist_assembled_utterances(&core.notebook_capture_store, &mut assembler, overlap, 0)
            .unwrap();
        let overlap_finalized = assembler.finalize();
        assert_eq!(overlap_finalized.len(), 1);
        assert_eq!(
            overlap_finalized[0].utterance.alignment,
            UtteranceAlignment::SourceOnly
        );
        persist_assembled_utterances(
            &core.notebook_capture_store,
            &mut assembler,
            overlap_finalized,
            0,
        )
        .unwrap();

        let stored = core
            .notebook_capture_store
            .list_utterances(&session.id)
            .unwrap();
        assert_eq!(stored.len(), 4);
        assert!(stored.iter().all(|utterance| {
            utterance.translated_text.is_some()
                == (utterance.alignment == UtteranceAlignment::Paired)
        }));
    }

    #[test]
    fn translation_is_ordered_without_synthetic_timestamp_or_one_to_one_alignment() {
        let mut assembler = RealtimeUtteranceAssembler::new("session-a".into(), &profile());
        let utterance = only_utterance(assembler.apply_tokens(&[
            token(
                "good morning",
                SttStreamTranslationStatus::Original,
                "en",
                Some(100),
                Some(900),
                true,
            ),
            token(
                "早上",
                SttStreamTranslationStatus::Translation,
                "zh",
                None,
                None,
                true,
            ),
            token(
                "好",
                SttStreamTranslationStatus::Translation,
                "zh",
                None,
                None,
                true,
            ),
        ]));

        assert_eq!(utterance.source_text, "good morning");
        assert_eq!(utterance.translated_text.as_deref(), Some("早上好"));
        assert_eq!(utterance.source_start_ms, Some(100));
        assert_eq!(utterance.source_end_ms, Some(900));
        assert_eq!(utterance.alignment, UtteranceAlignment::Paired);
    }

    #[test]
    fn speculative_tail_is_replaced_instead_of_duplicated() {
        let mut assembler = RealtimeUtteranceAssembler::new("session-a".into(), &profile());
        assert!(assembler
            .apply_tokens(&[token(
                "hel",
                SttStreamTranslationStatus::Original,
                "en",
                Some(0),
                Some(100),
                false,
            )])
            .is_empty());
        assert!(assembler
            .apply_tokens(&[token(
                "hello",
                SttStreamTranslationStatus::Original,
                "en",
                Some(0),
                Some(200),
                false,
            )])
            .is_empty());
        let finalized = only_utterance(assembler.apply_tokens(&[token(
            "hello",
            SttStreamTranslationStatus::Original,
            "en",
            Some(0),
            Some(200),
            true,
        )]));
        assert_eq!(finalized.source_text, "hello");
    }

    #[test]
    fn speculative_timing_is_rewritten_while_final_timing_remains_committed() {
        let mut assembler = RealtimeUtteranceAssembler::new("session-a".into(), &profile());
        assert!(assembler
            .apply_tokens(&[token(
                "hel",
                SttStreamTranslationStatus::Original,
                "en",
                Some(100),
                Some(900),
                false,
            )])
            .is_empty());
        assert!(assembler
            .apply_tokens(&[token(
                "hello",
                SttStreamTranslationStatus::Original,
                "en",
                Some(200),
                Some(500),
                false,
            )])
            .is_empty());

        let committed = only_utterance(assembler.apply_tokens(&[token(
            "hello",
            SttStreamTranslationStatus::Original,
            "en",
            Some(220),
            Some(520),
            true,
        )]));
        assert_eq!(committed.source_start_ms, Some(220));
        assert_eq!(committed.source_end_ms, Some(520));
        assembler.apply_tokens(&[token(
            " world",
            SttStreamTranslationStatus::Original,
            "en",
            Some(600),
            Some(800),
            false,
        )]);
        let pending_rewrite = only_utterance(assembler.apply_tokens(&[token(
            " world!",
            SttStreamTranslationStatus::Original,
            "en",
            Some(650),
            Some(750),
            false,
        )]));
        assert_eq!(pending_rewrite.source_text, "hello world!");
        assert_eq!(pending_rewrite.source_start_ms, Some(220));
        assert_eq!(pending_rewrite.source_end_ms, Some(750));
    }

    #[test]
    fn missing_lane_retracts_its_previous_speculative_tail_in_both_directions() {
        let mut assembler = RealtimeUtteranceAssembler::new("session-a".into(), &profile());
        assembler.apply_tokens(&[
            token(
                "hel",
                SttStreamTranslationStatus::Original,
                "en",
                Some(0),
                Some(100),
                false,
            ),
            token(
                "你",
                SttStreamTranslationStatus::Translation,
                "zh",
                None,
                None,
                false,
            ),
        ]);
        let source_only = only_utterance(assembler.apply_tokens(&[token(
            "hello",
            SttStreamTranslationStatus::Original,
            "en",
            Some(0),
            Some(200),
            true,
        )]));
        assert_eq!(source_only.source_text, "hello");
        assert_eq!(source_only.translated_text, None);
        assert_eq!(
            source_only.alignment,
            UtteranceAlignment::TranslationPending
        );

        let mut assembler = RealtimeUtteranceAssembler::new("session-b".into(), &profile());
        let first = assembler.apply_tokens(&[
            token(
                "good",
                SttStreamTranslationStatus::Original,
                "en",
                Some(0),
                Some(100),
                false,
            ),
            token(
                "早",
                SttStreamTranslationStatus::Translation,
                "zh",
                None,
                None,
                false,
            ),
        ]);
        assert!(first.is_empty());
        let translation_only = assembler.apply_tokens(&[token(
            "早上好",
            SttStreamTranslationStatus::Translation,
            "zh",
            None,
            None,
            true,
        )]);
        assert!(translation_only.is_empty());
    }

    #[test]
    fn third_language_is_preserved_without_forced_translation() {
        let mut assembler = RealtimeUtteranceAssembler::new("session-a".into(), &profile());
        let utterance = only_utterance(assembler.apply_tokens(&[token(
            "bonjour",
            SttStreamTranslationStatus::Original,
            "fr",
            Some(20),
            Some(300),
            true,
        )]));
        assert_eq!(utterance.source_text, "bonjour");
        assert_eq!(utterance.translated_text, None);
        assert_eq!(utterance.alignment, UtteranceAlignment::OutsideLanguagePair);
    }

    #[test]
    fn multilingual_one_way_waits_only_for_sources_outside_the_common_caption_language() {
        let mut multilingual = profile();
        multilingual.capture_mode = CaptureMode::MultilingualOneWay;
        multilingual.selected_languages = vec!["en".into(), "zh".into(), "th".into()];
        multilingual.common_caption_language = Some("en".into());

        let mut assembler =
            RealtimeUtteranceAssembler::new("session-multilingual".into(), &multilingual);
        let source = only_utterance(assembler.apply_tokens(&[attributed_token(
            "สวัสดี",
            SttStreamTranslationStatus::Original,
            Some("th"),
            None,
            Some("speaker-0"),
            true,
        )]));
        assert_eq!(source.alignment, UtteranceAlignment::TranslationPending);

        let paired = only_utterance(assembler.apply_tokens(&[
            attributed_token(
                "สวัสดี",
                SttStreamTranslationStatus::Original,
                Some("th"),
                None,
                Some("speaker-0"),
                true,
            ),
            attributed_token(
                "hello",
                SttStreamTranslationStatus::Translation,
                Some("en"),
                Some("th"),
                Some("speaker-0"),
                true,
            ),
        ]));
        assert_eq!(paired.translated_language.as_deref(), Some("en"));
        assert_eq!(paired.translated_text.as_deref(), Some("hello"));
        assert_eq!(paired.alignment, UtteranceAlignment::Paired);

        let mut assembler = RealtimeUtteranceAssembler::new("session-common".into(), &multilingual);
        let common = only_utterance(assembler.apply_tokens(&[attributed_token(
            "hello",
            SttStreamTranslationStatus::Original,
            Some("en"),
            None,
            Some("speaker-0"),
            true,
        )]));
        assert_eq!(common.alignment, UtteranceAlignment::SourceOnly);
    }

    #[test]
    fn provisional_language_and_speaker_are_revised_without_changing_segment_identity() {
        let mut profile = profile();
        profile.language_a = "th".into();
        profile.language_b = "zh".into();
        profile.left_language = "th".into();
        profile.right_language = "zh".into();
        profile.selected_languages = vec!["th".into(), "zh".into()];
        let mut assembler = RealtimeUtteranceAssembler::new("session-a".into(), &profile);

        let first = assembler.apply_tokens(&[attributed_token(
            "สวัส",
            SttStreamTranslationStatus::Original,
            Some("zh"),
            None,
            Some("speaker-0"),
            false,
        )]);
        assert!(first.is_empty());

        let revised = assembler.apply_tokens(&[
            attributed_token(
                "สวัสดี",
                SttStreamTranslationStatus::Original,
                Some("th"),
                None,
                Some("speaker-1"),
                false,
            ),
            attributed_token(
                "你好",
                SttStreamTranslationStatus::Translation,
                Some("zh"),
                Some("th"),
                Some("speaker-1"),
                false,
            ),
        ]);
        assert!(revised.is_empty());

        let finalized = assembler.apply_tokens(&[
            attributed_token(
                "สวัสดี",
                SttStreamTranslationStatus::Original,
                Some("th"),
                None,
                Some("speaker-1"),
                true,
            ),
            attributed_token(
                "你好",
                SttStreamTranslationStatus::Translation,
                Some("zh"),
                Some("th"),
                Some("speaker-1"),
                true,
            ),
        ]);
        assert_eq!(finalized.len(), 1);
        assert_eq!(finalized[0].utterance.source_language, "th");
        assert_eq!(
            finalized[0].utterance.translated_text.as_deref(),
            Some("你好")
        );
        assert_store_valid_alignment_shape(&finalized[0].utterance);
        assert_eq!(finalized[0].provider_speaker.as_deref(), Some("speaker-1"));
    }

    #[test]
    fn live_preview_replaces_the_speculative_tail_without_persisting_it() {
        let mut assembler = RealtimeUtteranceAssembler::new("session-preview".into(), &profile());

        assert!(assembler
            .apply_tokens(&[attributed_token(
                "hel",
                SttStreamTranslationStatus::Original,
                Some("en"),
                None,
                None,
                false,
            )])
            .is_empty());
        let first = assembler.live_previews();
        assert_eq!(first.len(), 1);
        assert_eq!(first[0].utterance.id, "session-preview:0");
        assert_eq!(first[0].utterance.source_language, "und");
        assert_eq!(first[0].utterance.source_text, "hel");
        assert_eq!(first[0].utterance.completion, UtteranceCompletion::Partial);

        assert!(assembler
            .apply_tokens(&[attributed_token(
                "hello",
                SttStreamTranslationStatus::Original,
                Some("en"),
                None,
                None,
                false,
            )])
            .is_empty());
        let revised = assembler.live_previews();
        assert_eq!(revised.len(), 1);
        assert_eq!(revised[0].utterance.id, "session-preview:0");
        assert_eq!(revised[0].utterance.source_text, "hello");

        let finalized = assembler.finalize();
        assert_eq!(finalized.len(), 1);
        assert_eq!(
            finalized[0].utterance.completion,
            UtteranceCompletion::Complete
        );
        assert!(assembler.live_previews().is_empty());
    }

    #[test]
    fn mixed_provisional_languages_stay_neutral_until_final_runs_split() {
        let mut assembler = RealtimeUtteranceAssembler::new("session-a".into(), &profile());

        let provisional = assembler.apply_tokens(&[
            attributed_token(
                "你好",
                SttStreamTranslationStatus::Original,
                Some("zh"),
                None,
                Some("speaker-0"),
                false,
            ),
            attributed_token(
                " hello",
                SttStreamTranslationStatus::Original,
                Some("en"),
                None,
                Some("speaker-0"),
                false,
            ),
        ]);
        assert!(provisional.is_empty());

        let finalized = assembler.apply_tokens(&[
            attributed_token(
                "你好",
                SttStreamTranslationStatus::Original,
                Some("zh"),
                None,
                Some("speaker-0"),
                true,
            ),
            attributed_token(
                "hello",
                SttStreamTranslationStatus::Original,
                Some("en"),
                None,
                Some("speaker-0"),
                true,
            ),
        ]);
        assert_eq!(finalized.len(), 2);
        assert_eq!(finalized[0].utterance.sequence, 0);
        assert_eq!(finalized[0].utterance.source_language, "zh");
        assert_eq!(finalized[0].utterance.source_text, "你好");
        assert_eq!(finalized[1].utterance.sequence, 1);
        assert_eq!(finalized[1].utterance.source_language, "en");
        assert_eq!(finalized[1].utterance.source_text, "hello");
        for update in &finalized {
            assert_store_valid_alignment_shape(&update.utterance);
        }
    }

    #[test]
    fn forced_finalize_preserves_unstable_source_as_a_neutral_fact() {
        let mut provisional_only =
            RealtimeUtteranceAssembler::new("session-provisional".into(), &profile());
        assert!(provisional_only
            .apply_tokens(&[
                attributed_token(
                    "你好",
                    SttStreamTranslationStatus::Original,
                    Some("zh"),
                    None,
                    Some("speaker-a"),
                    false,
                ),
                attributed_token(
                    " hello",
                    SttStreamTranslationStatus::Original,
                    Some("en"),
                    None,
                    Some("speaker-b"),
                    false,
                ),
            ])
            .is_empty());
        let neutral = only_utterance(provisional_only.finalize());
        assert_eq!(neutral.source_language, "und");
        assert_eq!(neutral.source_text, "你好 hello");
        assert_eq!(neutral.completion, UtteranceCompletion::Complete);
        assert_eq!(neutral.alignment, UtteranceAlignment::SourceOnly);
        assert_store_valid_alignment_shape(&neutral);

        for (session_id, pending_language, pending_speaker, pending_text) in [
            ("session-language-conflict", "zh", "speaker-a", " 你好"),
            ("session-speaker-conflict", "en", "speaker-b", " goodbye"),
        ] {
            let mut assembler = RealtimeUtteranceAssembler::new(session_id.into(), &profile());
            let stable = assembler.apply_tokens(&[
                attributed_token(
                    "hello",
                    SttStreamTranslationStatus::Original,
                    Some("en"),
                    None,
                    Some("speaker-a"),
                    true,
                ),
                attributed_token(
                    pending_text,
                    SttStreamTranslationStatus::Original,
                    Some(pending_language),
                    None,
                    Some(pending_speaker),
                    false,
                ),
            ]);
            assert_eq!(stable.len(), 1);
            assert_eq!(stable[0].utterance.source_text, "hello");

            let finalized = assembler.finalize();
            assert_eq!(finalized.len(), 2);
            assert_eq!(finalized[0].utterance.source_language, "en");
            assert_eq!(finalized[0].utterance.source_text, "hello");
            assert_eq!(finalized[1].utterance.source_language, "und");
            assert_eq!(finalized[1].utterance.source_text, pending_text);
            assert_eq!(
                finalized[1].utterance.completion,
                UtteranceCompletion::Complete
            );
            assert_eq!(
                finalized[1].utterance.alignment,
                UtteranceAlignment::SourceOnly
            );
            for update in &finalized {
                assert_store_valid_alignment_shape(&update.utterance);
            }
        }
    }

    #[test]
    fn mixed_provisional_speakers_do_not_extend_a_stable_speaker_segment() {
        let mut assembler = RealtimeUtteranceAssembler::new("session-a".into(), &profile());
        let stable = assembler.apply_tokens(&[attributed_token(
            "hello",
            SttStreamTranslationStatus::Original,
            Some("en"),
            None,
            Some("speaker-a"),
            true,
        )]);
        assert_eq!(stable.len(), 1);
        assert_eq!(stable[0].utterance.source_text, "hello");

        let provisional = assembler.apply_tokens(&[
            attributed_token(
                " from B",
                SttStreamTranslationStatus::Original,
                Some("en"),
                None,
                Some("speaker-b"),
                false,
            ),
            attributed_token(
                " and A",
                SttStreamTranslationStatus::Original,
                Some("en"),
                None,
                Some("speaker-a"),
                false,
            ),
        ]);
        assert_eq!(provisional.len(), 1);
        assert_eq!(provisional[0].utterance.sequence, 0);
        assert_eq!(provisional[0].utterance.source_language, "en");
        assert_eq!(provisional[0].utterance.source_text, "hello");
        assert_eq!(
            provisional[0].provider_speaker.as_deref(),
            Some("speaker-a")
        );
        assert_store_valid_alignment_shape(&provisional[0].utterance);
    }

    #[test]
    fn source_language_evidence_prefers_original_tokens_at_each_finality() {
        let mut segment = RealtimeSegmentRevision::new("session-a", 0);
        segment.pending_source_language_hint = Some("th".into());
        segment.source.pending_language = Some("zh".into());
        assert_eq!(segment.matching_source_language(), Some("zh"));
        assert_eq!(segment.source_language(), "und");

        segment.committed_source_language_hint = Some("fr".into());
        assert_eq!(segment.matching_source_language(), Some("fr"));
        assert_eq!(segment.source_language(), "fr");

        segment.source.committed_language = Some("en".into());
        assert_eq!(segment.matching_source_language(), Some("en"));
        assert_eq!(segment.source_language(), "en");
    }

    #[test]
    fn same_speaker_can_switch_languages_more_than_once_inside_one_endpoint() {
        let mut assembler = RealtimeUtteranceAssembler::new("session-a".into(), &profile());
        let updates = assembler.apply_tokens(&[
            attributed_token(
                "你好",
                SttStreamTranslationStatus::Original,
                Some("zh"),
                None,
                Some("speaker-0"),
                true,
            ),
            attributed_token(
                "hello",
                SttStreamTranslationStatus::Original,
                Some("en"),
                None,
                Some("speaker-0"),
                true,
            ),
            attributed_token(
                "再见",
                SttStreamTranslationStatus::Original,
                Some("zh"),
                None,
                Some("speaker-0"),
                true,
            ),
            attributed_token(
                "hello-en",
                SttStreamTranslationStatus::Translation,
                Some("en"),
                Some("zh"),
                Some("speaker-0"),
                true,
            ),
            attributed_token(
                "hello-zh",
                SttStreamTranslationStatus::Translation,
                Some("zh"),
                Some("en"),
                Some("speaker-0"),
                true,
            ),
            attributed_token(
                "goodbye-en",
                SttStreamTranslationStatus::Translation,
                Some("en"),
                Some("zh"),
                Some("speaker-0"),
                true,
            ),
        ]);

        assert_eq!(updates.len(), 3);
        assert_eq!(
            updates
                .iter()
                .map(|update| update.utterance.source_language.as_str())
                .collect::<Vec<_>>(),
            vec!["zh", "en", "zh"]
        );
        assert_eq!(
            updates
                .iter()
                .map(|update| update.utterance.source_text.as_str())
                .collect::<Vec<_>>(),
            vec!["你好", "hello", "再见"]
        );
        assert_eq!(
            updates
                .iter()
                .map(|update| update.utterance.translated_text.as_deref())
                .collect::<Vec<_>>(),
            vec![Some("hello-en"), Some("hello-zh"), Some("goodbye-en")],
            "response order must attach both repeated-language translations instead of dropping one"
        );
        assert!(updates
            .iter()
            .all(|update| update.provider_speaker.as_deref() == Some("speaker-0")));
        for update in &updates {
            assert_store_valid_alignment_shape(&update.utterance);
        }
        let finalized = assembler.finalize();
        assert_eq!(finalized.len(), 1);
        assert_eq!(finalized[0].utterance.source_text, "再见");
        assert_eq!(finalized[0].utterance.alignment, UtteranceAlignment::Paired);
        assert_eq!(
            finalized[0].utterance.translated_text.as_deref(),
            Some("goodbye-en")
        );
        assert_store_valid_alignment_shape(&finalized[0].utterance);
    }

    #[test]
    fn stable_language_change_splits_same_speaker_inside_one_endpoint() {
        let mut profile = profile();
        profile.language_a = "th".into();
        profile.language_b = "zh".into();
        profile.left_language = "th".into();
        profile.right_language = "zh".into();
        profile.selected_languages = vec!["th".into(), "zh".into()];
        let mut assembler = RealtimeUtteranceAssembler::new("session-a".into(), &profile);

        let updates = assembler.apply_tokens(&[
            attributed_token(
                "你好",
                SttStreamTranslationStatus::Original,
                Some("zh"),
                None,
                Some("speaker-0"),
                true,
            ),
            attributed_token(
                "สวัสดี",
                SttStreamTranslationStatus::Translation,
                Some("th"),
                Some("zh"),
                Some("speaker-0"),
                true,
            ),
            attributed_token(
                "ขอบคุณ",
                SttStreamTranslationStatus::Original,
                Some("th"),
                None,
                Some("speaker-0"),
                true,
            ),
            attributed_token(
                "谢谢",
                SttStreamTranslationStatus::Translation,
                Some("zh"),
                Some("th"),
                Some("speaker-0"),
                true,
            ),
        ]);

        assert_eq!(updates.len(), 2);
        assert_eq!(updates[0].utterance.sequence, 0);
        assert_eq!(updates[0].utterance.source_language, "zh");
        assert_eq!(updates[0].utterance.source_text, "你好");
        assert_eq!(
            updates[0].utterance.translated_text.as_deref(),
            Some("สวัสดี")
        );
        assert_eq!(updates[1].utterance.sequence, 1);
        assert_eq!(updates[1].utterance.source_language, "th");
        assert_eq!(updates[1].utterance.source_text, "ขอบคุณ");
        assert_eq!(
            updates[1].utterance.translated_text.as_deref(),
            Some("谢谢")
        );
        assert_eq!(updates[0].provider_speaker, updates[1].provider_speaker);
    }

    #[test]
    fn grouped_originals_then_translations_match_by_speaker_and_source_language() {
        let mut profile = profile();
        profile.language_a = "th".into();
        profile.language_b = "zh".into();
        profile.left_language = "th".into();
        profile.right_language = "zh".into();
        profile.selected_languages = vec!["th".into(), "zh".into()];
        let mut assembler = RealtimeUtteranceAssembler::new("session-a".into(), &profile);

        let updates = assembler.apply_tokens(&[
            attributed_token(
                "你好",
                SttStreamTranslationStatus::Original,
                Some("zh"),
                None,
                Some("speaker-a"),
                true,
            ),
            attributed_token(
                "ขอบคุณ",
                SttStreamTranslationStatus::Original,
                Some("th"),
                None,
                Some("speaker-a"),
                true,
            ),
            attributed_token(
                "สวัสดี",
                SttStreamTranslationStatus::Translation,
                Some("th"),
                Some("zh"),
                Some("speaker-a"),
                true,
            ),
            attributed_token(
                "谢谢",
                SttStreamTranslationStatus::Translation,
                Some("zh"),
                Some("th"),
                Some("speaker-a"),
                true,
            ),
        ]);

        assert_eq!(updates.len(), 2);
        assert_eq!(updates[0].utterance.source_language, "zh");
        assert_eq!(updates[0].utterance.source_text, "你好");
        assert_eq!(
            updates[0].utterance.translated_language.as_deref(),
            Some("th")
        );
        assert_eq!(
            updates[0].utterance.translated_text.as_deref(),
            Some("สวัสดี")
        );
        assert_eq!(updates[1].utterance.source_language, "th");
        assert_eq!(updates[1].utterance.source_text, "ขอบคุณ");
        assert_eq!(
            updates[1].utterance.translated_language.as_deref(),
            Some("zh")
        );
        assert_eq!(
            updates[1].utterance.translated_text.as_deref(),
            Some("谢谢")
        );
    }

    #[test]
    fn translation_requires_a_unique_compatible_original_segment() {
        let mut assembler = RealtimeUtteranceAssembler::new("session-a".into(), &profile());
        let updates = assembler.apply_tokens(&[
            attributed_token(
                "first",
                SttStreamTranslationStatus::Original,
                Some("en"),
                None,
                Some("speaker-a"),
                true,
            ),
            attributed_token(
                "second",
                SttStreamTranslationStatus::Original,
                Some("en"),
                None,
                Some("speaker-b"),
                true,
            ),
            attributed_token(
                "甲",
                SttStreamTranslationStatus::Translation,
                Some("zh"),
                Some("en"),
                Some("speaker-a"),
                true,
            ),
            attributed_token(
                "乙",
                SttStreamTranslationStatus::Translation,
                Some("zh"),
                Some("en"),
                None,
                true,
            ),
        ]);

        assert_eq!(updates.len(), 2);
        assert_eq!(updates[0].provider_speaker.as_deref(), Some("speaker-a"));
        assert_eq!(updates[0].utterance.source_text, "first");
        assert_eq!(updates[0].utterance.translated_text.as_deref(), Some("甲"));
        assert_eq!(updates[1].provider_speaker.as_deref(), Some("speaker-b"));
        assert_eq!(updates[1].utterance.source_text, "second");
        assert_eq!(updates[1].utterance.translated_text, None);
        for update in &updates {
            assert_store_valid_alignment_shape(&update.utterance);
        }
        let finalized = assembler.finalize();
        assert_eq!(finalized.len(), 1);
        assert_eq!(finalized[0].utterance.source_text, "second");
        assert_eq!(
            finalized[0].utterance.alignment,
            UtteranceAlignment::SourceOnly
        );
        assert_store_valid_alignment_shape(&finalized[0].utterance);
    }

    #[test]
    fn unknown_role_and_missing_languages_fail_closed() {
        let mut assembler = RealtimeUtteranceAssembler::new("session-a".into(), &profile());
        assert!(assembler
            .apply_tokens(&[attributed_token(
                "not source",
                SttStreamTranslationStatus::Unknown("future".into()),
                Some("en"),
                None,
                Some("speaker-a"),
                true,
            )])
            .is_empty());

        assert!(assembler
            .apply_tokens(&[
                attributed_token(
                    "spoken",
                    SttStreamTranslationStatus::Original,
                    None,
                    None,
                    Some("speaker-a"),
                    true,
                ),
                attributed_token(
                    "translated",
                    SttStreamTranslationStatus::Translation,
                    None,
                    None,
                    Some("speaker-a"),
                    true,
                ),
            ])
            .is_empty());
        let utterance = only_utterance(assembler.finalize());
        assert_eq!(utterance.source_language, "und");
        assert_eq!(utterance.translated_language, None);
        assert_eq!(utterance.translated_text, None);
        assert_eq!(utterance.alignment, UtteranceAlignment::SourceOnly);
        assert_store_valid_alignment_shape(&utterance);
    }

    #[test]
    fn provider_speaker_epoch_advances_only_after_a_successful_reconnect() {
        let mut epoch = 0;
        let mut awaiting_reconnect = false;
        record_provider_connected(&mut epoch, &mut awaiting_reconnect);
        assert_eq!(epoch, 0);

        awaiting_reconnect = true;
        record_provider_connected(&mut epoch, &mut awaiting_reconnect);
        assert_eq!(epoch, 1);
        assert!(!awaiting_reconnect);

        record_provider_connected(&mut epoch, &mut awaiting_reconnect);
        assert_eq!(epoch, 1);
    }

    #[test]
    fn cross_stream_pairing_uses_authoritative_time_before_language_or_column_order() {
        let candidate = |sequence, group_epoch, start_ms, end_ms| {
            let mut utterance = projected_utterance();
            utterance.sequence = sequence;
            utterance.source_language = "th".into();
            utterance.source_start_ms = start_ms;
            utterance.source_end_ms = end_ms;
            CanonicalUtteranceMatch {
                group_epoch,
                utterance,
            }
        };
        let pending = PendingTranslationVariant {
            group_epoch: 0,
            source_sequence: 99,
            source_language: "th".into(),
            source_text: "good morning 🌏".into(),
            source_start_ms: Some(120),
            source_end_ms: Some(220),
            target_language: "zh".into(),
            translated_text: "你好".into(),
            completion: UtteranceCompletion::Complete,
        };
        let candidates = [
            candidate(0, 0, Some(0), Some(100)),
            candidate(1, 0, Some(110), Some(230)),
            candidate(2, 1, Some(110), Some(230)),
        ];
        assert_eq!(
            match_canonical_sequence(&pending, candidates.iter()),
            Some(1),
            "group epoch, source language, and a unique overlap identify the canonical row"
        );

        let ambiguous = [
            candidate(1, 0, Some(110), Some(230)),
            candidate(2, 0, Some(150), Some(260)),
        ];
        assert_eq!(
            match_canonical_sequence(&pending, ambiguous.iter()),
            Some(1),
            "the strongest temporal overlap must win deterministically"
        );
        let mut different_text = candidate(1, 0, Some(110), Some(230));
        different_text.utterance.source_text = "คนละประโยค".into();
        let text_disambiguated = [different_text, candidate(2, 0, Some(150), Some(260))];
        assert_eq!(
            match_canonical_sequence(&pending, text_disambiguated.iter()),
            Some(2),
            "source text may disambiguate otherwise overlapping time windows"
        );

        let contradictory = [candidate(99, 0, Some(300), Some(400))];
        assert_eq!(
            match_canonical_sequence(&pending, contradictory.iter()),
            None,
            "an equal sequence must not override contradictory timestamps"
        );

        let mut language_drift = candidate(4, 0, Some(110), Some(230));
        language_drift.utterance.source_language = "und".into();
        assert_eq!(
            match_canonical_sequence(&pending, std::iter::once(&language_drift)),
            Some(4),
            "a target stream language disagreement must not veto the shared audio time"
        );
    }

    #[test]
    fn cross_stream_pairing_uses_sequence_only_when_timestamps_are_unavailable() {
        let candidate = |sequence| {
            let mut utterance = projected_utterance();
            utterance.sequence = sequence;
            utterance.source_language = "th".into();
            utterance.source_start_ms = None;
            utterance.source_end_ms = None;
            CanonicalUtteranceMatch {
                group_epoch: 4,
                utterance,
            }
        };
        let pending = PendingTranslationVariant {
            group_epoch: 4,
            source_sequence: 7,
            source_language: "th".into(),
            source_text: "good morning 🌏".into(),
            source_start_ms: None,
            source_end_ms: None,
            target_language: "en".into(),
            translated_text: "hello".into(),
            completion: UtteranceCompletion::Partial,
        };
        let candidates = [candidate(6), candidate(7)];
        assert_eq!(
            match_canonical_sequence(&pending, candidates.iter()),
            Some(7)
        );

        let repeated = [candidate(7), candidate(7)];
        assert_eq!(
            match_canonical_sequence(&pending, repeated.iter()),
            Some(7),
            "equivalent candidates have the same authoritative sequence"
        );
    }

    #[test]
    fn stable_aux_binding_survives_timeline_language_identification_revision() {
        let pending_key = (1, 0, 7);
        let pending = PendingTranslationVariant {
            group_epoch: 0,
            source_sequence: 7,
            source_language: "th".into(),
            source_text: "สวัสดี".into(),
            source_start_ms: Some(100),
            source_end_ms: Some(300),
            target_language: "zh".into(),
            translated_text: "你好".into(),
            completion: UtteranceCompletion::Complete,
        };
        let mut utterance = projected_utterance();
        utterance.sequence = 4;
        utterance.source_language = "th".into();
        utterance.source_text = "สวัสดี".into();
        utterance.source_start_ms = Some(90);
        utterance.source_end_ms = Some(310);
        let mut candidates = std::collections::HashMap::from([(
            (0, 4),
            CanonicalUtteranceMatch {
                group_epoch: 0,
                utterance,
            },
        )]);
        let mut bindings = std::collections::HashMap::from([(pending_key, 4)]);
        let mut reverse =
            std::collections::HashMap::from([((0, 4, "zh".to_string()), pending_key)]);
        assert_eq!(
            resolve_canonical_sequence(
                pending_key,
                &pending,
                &candidates,
                &mut bindings,
                &mut reverse,
            ),
            Some(4)
        );

        candidates
            .get_mut(&(0, 4))
            .unwrap()
            .utterance
            .source_language = "en".into();
        assert_eq!(
            resolve_canonical_sequence(
                pending_key,
                &pending,
                &candidates,
                &mut bindings,
                &mut reverse,
            ),
            Some(4)
        );
        assert_eq!(bindings.get(&pending_key), Some(&4));
        assert_eq!(reverse.get(&(0, 4, "zh".to_string())), Some(&pending_key));
    }

    #[test]
    fn resolved_stream_history_keeps_a_recent_window_and_every_unfinished_candidate() {
        let selected_languages = vec!["en".to_string(), "zh".to_string(), "th".to_string()];
        let candidate = |sequence: u64, thai_completion| {
            let mut utterance = projected_utterance();
            utterance.id = format!("utterance-{sequence}");
            utterance.sequence = sequence;
            utterance.translated_language = None;
            utterance.translated_text = None;
            utterance.variants = vec![
                vt_store::notebook_capture_store::RealtimeUtteranceVariant {
                    language: "zh".into(),
                    role: UtteranceVariantRole::Translation,
                    text: Some("早上好".into()),
                    state: UtteranceVariantState::Ready,
                    completion: Some(UtteranceCompletion::Complete),
                    revision: 1,
                    created_at: String::new(),
                    updated_at: String::new(),
                },
                vt_store::notebook_capture_store::RealtimeUtteranceVariant {
                    language: "th".into(),
                    role: UtteranceVariantRole::Translation,
                    text: Some("สวัสดี".into()),
                    state: UtteranceVariantState::Ready,
                    completion: Some(thai_completion),
                    revision: 1,
                    created_at: String::new(),
                    updated_at: String::new(),
                },
            ];
            CanonicalUtteranceMatch {
                group_epoch: 0,
                utterance,
            }
        };

        let resolved_count = STREAM_AGGREGATION_RECENT_UTTERANCE_WINDOW + 12;
        let mut canonical_matches = std::collections::HashMap::new();
        let mut variant_bindings = std::collections::HashMap::new();
        let mut reverse_variant_bindings = std::collections::HashMap::new();
        let mut initialized_variants = std::collections::HashSet::new();
        for sequence in 0..resolved_count as u64 {
            canonical_matches.insert(
                (0, sequence),
                candidate(sequence, UtteranceCompletion::Complete),
            );
            for (lane_index, language) in [(1, "zh"), (2, "th")] {
                let pending_key = (lane_index, 0, sequence);
                variant_bindings.insert(pending_key, sequence);
                reverse_variant_bindings.insert((0, sequence, language.to_string()), pending_key);
                initialized_variants.insert((sequence, language.to_string()));
            }
        }

        // An old or delayed candidate is never recycled until both its source
        // and every selected target are final.
        let unfinished_sequence = resolved_count as u64;
        canonical_matches.insert(
            (0, unfinished_sequence),
            candidate(unfinished_sequence, UtteranceCompletion::Partial),
        );
        for (lane_index, language) in [(1, "zh"), (2, "th")] {
            let pending_key = (lane_index, 0, unfinished_sequence);
            variant_bindings.insert(pending_key, unfinished_sequence);
            reverse_variant_bindings
                .insert((0, unfinished_sequence, language.to_string()), pending_key);
            initialized_variants.insert((unfinished_sequence, language.to_string()));
        }

        let recycled = prune_resolved_stream_aggregation_history(
            &selected_languages,
            &mut canonical_matches,
            &mut variant_bindings,
            &mut reverse_variant_bindings,
            &mut initialized_variants,
        );

        assert_eq!(recycled, 12);
        assert_eq!(
            canonical_matches.len(),
            STREAM_AGGREGATION_RECENT_UTTERANCE_WINDOW + 1
        );
        assert!(!canonical_matches.contains_key(&(0, 0)));
        assert!(canonical_matches.contains_key(&(0, 12)));
        assert!(canonical_matches.contains_key(&(0, unfinished_sequence)));
        assert_eq!(
            variant_bindings.len(),
            (STREAM_AGGREGATION_RECENT_UTTERANCE_WINDOW + 1) * 2
        );
        assert_eq!(
            reverse_variant_bindings.len(),
            (STREAM_AGGREGATION_RECENT_UTTERANCE_WINDOW + 1) * 2
        );
        assert_eq!(
            initialized_variants.len(),
            (STREAM_AGGREGATION_RECENT_UTTERANCE_WINDOW + 1) * 2
        );
    }

    #[test]
    fn aux_translation_waits_for_canonical_and_partial_final_reuses_its_binding() {
        let temp = tempfile::tempdir().unwrap();
        let core = ZulangueCore::new_for_test(temp.path().to_string_lossy().to_string()).unwrap();
        let notebook = core
            .create_notebook(Some("Aux before canonical".into()))
            .unwrap();
        let stored_profile = core
            .notebook_capture_store
            .get_or_create_profile(&notebook.id)
            .unwrap();
        let session = vt_store::SessionRecord {
            id: "aux-before-canonical-session".into(),
            title: "Aux before canonical".into(),
            session_type: "recording".into(),
            status: "recording".into(),
            duration_ms: 0,
            created_at: "2001-01-04T00:00:00Z".into(),
            deleted_at: None,
        };
        core.notebook_capture_store
            .create_session_and_run(
                &session,
                &vt_store::notebook_capture_store::NewNotebookCaptureRun {
                    id: "aux-before-canonical-run".into(),
                    notebook_id: notebook.id.clone(),
                    session_id: session.id.clone(),
                    remote_health: RemoteHealth::Off,
                    audio_journal_path: "/private/aux-before-canonical.journal".into(),
                    audio_key_ref: "aux-before-canonical-key".into(),
                    sample_rate: 16_000,
                    channels: 1,
                },
                &stored_profile,
            )
            .unwrap();
        claim_current_realtime_provider(&core.notebook_capture_store, &session.id);

        let mut runtime_profile = profile();
        runtime_profile.notebook_id = notebook.id;
        runtime_profile.capture_mode = CaptureMode::MultilingualOneWay;
        runtime_profile.selected_languages = vec!["en".into(), "zh".into(), "th".into()];
        let make_lane = |target_language: &str, canonical: bool| {
            let mut lane_profile = runtime_profile.clone();
            lane_profile.common_caption_language = Some(target_language.to_string());
            StreamAggregationLane {
                descriptor: RemoteStreamLane {
                    target_language: Some(target_language.to_string()),
                    canonical,
                },
                assembler: RealtimeUtteranceAssembler::new(session.id.clone(), &lane_profile),
                provider_session_epoch: 0,
                group_epoch: 0,
                awaiting_reconnect: false,
                connected: true,
                ever_connected: true,
                provider_accepted_configuration: true,
            }
        };
        let mut lanes = vec![make_lane("en", true), make_lane("zh", false)];
        let selected_languages = runtime_profile
            .selected_languages
            .iter()
            .map(|language| normalize_language(language))
            .collect::<Vec<_>>();
        let mut canonical_matches = std::collections::HashMap::new();
        let mut pending_variants = std::collections::HashMap::new();
        let mut variant_bindings = std::collections::HashMap::new();
        let mut reverse_variant_bindings = std::collections::HashMap::new();
        let mut initialized_variants = std::collections::HashSet::new();
        let update = |id: &str, translated_text: Option<&str>, completion: UtteranceCompletion| {
            AssembledRealtimeUtterance {
                utterance: NewRealtimeUtterance {
                    id: id.to_string(),
                    session_id: session.id.clone(),
                    sequence: 0,
                    session_speaker_id: None,
                    source_language: "th".into(),
                    source_text: "สวัสดี".into(),
                    source_start_ms: Some(100),
                    source_end_ms: Some(300),
                    translated_language: translated_text.map(|_| "zh".to_string()),
                    translated_text: translated_text.map(str::to_string),
                    completion,
                    alignment: if translated_text.is_some() {
                        UtteranceAlignment::Paired
                    } else {
                        UtteranceAlignment::SourceOnly
                    },
                },
                provider_speaker: None,
                expected_revision: None,
            }
        };

        let aux_partial = persist_stream_lane_updates(
            &core.notebook_capture_store,
            &mut lanes,
            0,
            1,
            vec![update(
                "aux-utterance",
                Some("你"),
                UtteranceCompletion::Partial,
            )],
            &selected_languages,
            &mut canonical_matches,
            &mut pending_variants,
            &mut variant_bindings,
            &mut reverse_variant_bindings,
            &mut initialized_variants,
        )
        .unwrap();
        assert!(aux_partial.is_empty());
        assert_eq!(pending_variants.len(), 1);
        assert!(core
            .notebook_capture_store
            .list_utterances(&session.id)
            .unwrap()
            .is_empty());

        let timeline_partial = persist_stream_lane_updates(
            &core.notebook_capture_store,
            &mut lanes,
            0,
            0,
            vec![update(
                "canonical-utterance",
                None,
                UtteranceCompletion::Partial,
            )],
            &selected_languages,
            &mut canonical_matches,
            &mut pending_variants,
            &mut variant_bindings,
            &mut reverse_variant_bindings,
            &mut initialized_variants,
        )
        .unwrap();
        assert!(
            timeline_partial.is_empty(),
            "a speculative source revision must stay outside the durable timeline"
        );
        assert!(core
            .notebook_capture_store
            .list_utterances(&session.id)
            .unwrap()
            .is_empty());

        let canonical = persist_stream_lane_updates(
            &core.notebook_capture_store,
            &mut lanes,
            0,
            0,
            vec![update(
                "canonical-utterance",
                None,
                UtteranceCompletion::Complete,
            )],
            &selected_languages,
            &mut canonical_matches,
            &mut pending_variants,
            &mut variant_bindings,
            &mut reverse_variant_bindings,
            &mut initialized_variants,
        )
        .unwrap();
        assert_eq!(canonical.len(), 1);
        assert!(pending_variants.is_empty());
        assert_eq!(variant_bindings.get(&(1, 0, 0)), Some(&0));
        assert_eq!(
            reverse_variant_bindings.get(&(0, 0, "zh".to_string())),
            Some(&(1, 0, 0))
        );
        let utterances = core
            .notebook_capture_store
            .list_utterances(&session.id)
            .unwrap();
        assert_eq!(utterances.len(), 1);
        assert_eq!(utterances[0].source_language, "th");
        assert_eq!(utterances[0].source_text, "สวัสดี");
        let zh = utterances[0]
            .variants
            .iter()
            .find(|variant| variant.language == "zh")
            .unwrap();
        assert_eq!(zh.text.as_deref(), Some("你"));
        assert_eq!(zh.state, UtteranceVariantState::Ready);
        assert_eq!(zh.completion, Some(UtteranceCompletion::Partial));
        let partial_revision = zh.revision;

        let duplicate_partial = persist_stream_lane_updates(
            &core.notebook_capture_store,
            &mut lanes,
            0,
            1,
            vec![update(
                "aux-utterance",
                Some("你"),
                UtteranceCompletion::Partial,
            )],
            &selected_languages,
            &mut canonical_matches,
            &mut pending_variants,
            &mut variant_bindings,
            &mut reverse_variant_bindings,
            &mut initialized_variants,
        )
        .unwrap();
        assert!(
            duplicate_partial.is_empty(),
            "an unchanged partial must not produce a redundant UI delta"
        );
        let duplicate_partial_revision = core
            .notebook_capture_store
            .list_utterances(&session.id)
            .unwrap()[0]
            .variants
            .iter()
            .find(|variant| variant.language == "zh")
            .unwrap()
            .revision;
        assert_eq!(
            duplicate_partial_revision, partial_revision,
            "an unchanged partial must not amplify SQLite revisions"
        );

        let aux_final = persist_stream_lane_updates(
            &core.notebook_capture_store,
            &mut lanes,
            0,
            1,
            vec![update(
                "aux-utterance",
                Some("你好"),
                UtteranceCompletion::Complete,
            )],
            &selected_languages,
            &mut canonical_matches,
            &mut pending_variants,
            &mut variant_bindings,
            &mut reverse_variant_bindings,
            &mut initialized_variants,
        )
        .unwrap();
        assert_eq!(aux_final.len(), 1);
        let utterances = core
            .notebook_capture_store
            .list_utterances(&session.id)
            .unwrap();
        assert_eq!(utterances.len(), 1);
        let zh = utterances[0]
            .variants
            .iter()
            .find(|variant| variant.language == "zh")
            .unwrap();
        assert_eq!(zh.text.as_deref(), Some("你好"));
        assert_eq!(zh.state, UtteranceVariantState::Ready);
        assert_eq!(zh.completion, Some(UtteranceCompletion::Complete));

        let source_revision = |source_language: &str, source_text: &str, expected_revision: u64| {
            AssembledRealtimeUtterance {
                utterance: NewRealtimeUtterance {
                    id: "canonical-utterance".into(),
                    session_id: session.id.clone(),
                    sequence: 0,
                    session_speaker_id: None,
                    source_language: source_language.to_string(),
                    source_text: source_text.to_string(),
                    source_start_ms: Some(100),
                    source_end_ms: Some(300),
                    translated_language: None,
                    translated_text: None,
                    completion: UtteranceCompletion::Complete,
                    alignment: UtteranceAlignment::SourceOnly,
                },
                provider_speaker: None,
                expected_revision: Some(expected_revision),
            }
        };
        let revised_to_zh = persist_stream_lane_updates(
            &core.notebook_capture_store,
            &mut lanes,
            0,
            0,
            vec![source_revision("zh", "你好", utterances[0].revision)],
            &selected_languages,
            &mut canonical_matches,
            &mut pending_variants,
            &mut variant_bindings,
            &mut reverse_variant_bindings,
            &mut initialized_variants,
        )
        .unwrap();
        assert_eq!(revised_to_zh.len(), 1);
        let revised_to_zh = core
            .notebook_capture_store
            .list_utterances(&session.id)
            .unwrap()
            .remove(0);
        assert_eq!(revised_to_zh.source_language, "zh");
        assert!(revised_to_zh
            .variants
            .iter()
            .any(|variant| variant.language == "th"
                && variant.state == UtteranceVariantState::Waiting));

        let revised_back_to_th = persist_stream_lane_updates(
            &core.notebook_capture_store,
            &mut lanes,
            0,
            0,
            vec![source_revision("th", "สวัสดี", revised_to_zh.revision)],
            &selected_languages,
            &mut canonical_matches,
            &mut pending_variants,
            &mut variant_bindings,
            &mut reverse_variant_bindings,
            &mut initialized_variants,
        )
        .unwrap();
        assert_eq!(revised_back_to_th.len(), 1);
        let revised_back_to_th = core
            .notebook_capture_store
            .list_utterances(&session.id)
            .unwrap()
            .remove(0);
        assert_eq!(revised_back_to_th.source_language, "th");
        let zh = revised_back_to_th
            .variants
            .iter()
            .find(|variant| variant.language == "zh")
            .expect("former source language must be reinitialized as a target");
        assert_eq!(zh.text, None);
        assert_eq!(zh.state, UtteranceVariantState::Waiting);
    }

    #[test]
    fn compiler_context_mapping_matches_exact_soniox_wire_json() {
        let context = vt_store::SonioxContext {
            translation_terms: vec![vt_store::SonioxTranslationTerm {
                source: "Zulangue".into(),
                target: "语音工具".into(),
            }],
            terms: vec!["  exact term  ".into()],
            general: vec![vt_store::SonioxGeneralContext {
                key: "project".into(),
                value: "  Sample Project  ".into(),
            }],
            text: " leading text ".into(),
        };
        let expected = serde_json::to_string(&context).unwrap();
        let compilation = ContextCompilation {
            context,
            context_json: expected.clone(),
            receipt: ContextReceipt {
                notebook_id: "notebook-a".into(),
                context_sha256: "digest".into(),
                serialized_scalars: expected.chars().count() as u64,
                sources: Vec::new(),
                omissions: Vec::new(),
            },
        };
        let config = context_config_for_soniox(&compilation);
        assert_eq!(
            soniox_stream_context_json(&config).unwrap().as_deref(),
            Some(expected.as_str())
        );
    }

    #[test]
    fn context_confirmation_binds_sources_even_when_wire_text_is_identical() {
        let context = vt_store::SonioxContext {
            text: "same exact wire text".into(),
            ..Default::default()
        };
        let context_json = serde_json::to_string(&context).unwrap();
        let source = vt_store::ContextReceiptSource {
            pack_id: "pack-a".into(),
            pack_scope: ContextPackScope::Library,
            source_id: "source-a".into(),
            source_title: "A".into(),
            source_revision: 1,
            plaintext_sha256: "same-content-hash".into(),
            included_items: 1,
            included_scalars: 20,
        };
        let make = |source: vt_store::ContextReceiptSource| ContextCompilation {
            context: context.clone(),
            context_json: context_json.clone(),
            receipt: ContextReceipt {
                notebook_id: "notebook-a".into(),
                context_sha256: "same-wire-hash".into(),
                serialized_scalars: context_json.chars().count() as u64,
                sources: vec![source],
                omissions: Vec::new(),
            },
        };
        let first = make(source.clone());
        let mut replacement_source = source;
        replacement_source.pack_id = "pack-b".into();
        replacement_source.source_id = "source-b".into();
        let second = make(replacement_source);

        assert_eq!(first.context_json, second.context_json);
        assert_ne!(
            context_confirmation_digest(&first).unwrap(),
            context_confirmation_digest(&second).unwrap()
        );
    }

    fn projected_utterance() -> RealtimeUtterance {
        RealtimeUtterance {
            id: "utterance-a".into(),
            session_id: "session-a".into(),
            sequence: 0,
            session_speaker_id: None,
            source_language: "en".into(),
            source_text: "good morning 🌏".into(),
            source_start_ms: Some(1_250),
            source_end_ms: Some(2_500),
            translated_language: Some("zh".into()),
            translated_text: Some("早上好".into()),
            revision: 0,
            completion: UtteranceCompletion::Complete,
            alignment: UtteranceAlignment::Paired,
            created_at: String::new(),
            updated_at: String::new(),
            variants: Vec::new(),
        }
    }

    #[test]
    fn ffi_utterance_preserves_session_speaker_id() {
        let mut utterance = projected_utterance();
        utterance.session_speaker_id = Some("speaker-a".into());

        let ffi: FfiNotebookCaptureUtterance = utterance.into();

        assert_eq!(ffi.session_speaker_id.as_deref(), Some("speaker-a"));
    }

    fn projection_mutation(
        lane: UtteranceLane,
        expected_revision: u64,
        target_text: &str,
    ) -> NotebookProjectionMutation {
        NotebookProjectionMutation {
            id: format!("mutation-{expected_revision}"),
            session_id: "session-a".into(),
            utterance_id: "utterance-a".into(),
            lane,
            lane_language: match lane {
                UtteranceLane::Source => "en",
                UtteranceLane::Translated => "zh",
            }
            .into(),
            expected_revision,
            target_text: target_text.into(),
            state: vt_store::notebook_capture_store::ProjectionMutationState::Pending,
            created_at: String::new(),
            updated_at: String::new(),
        }
    }

    fn apply_rendered(
        bridge: &vt_store::EditorBridge,
        document_id: &str,
        pos: usize,
        rendered: CaptureRenderedSection,
    ) {
        bridge
            .apply(
                document_id,
                vt_store::EditOp::Insert {
                    pos,
                    text: rendered.text,
                },
            )
            .unwrap();
        for mark in rendered.marks {
            bridge
                .apply(
                    document_id,
                    vt_store::EditOp::Mark {
                        pos: pos + mark.pos,
                        len: mark.len,
                        key: mark.key,
                        value_json: mark.value_json,
                    },
                )
                .unwrap();
        }
    }

    #[test]
    fn two_sequential_unicode_lane_edits_keep_translation_timestamp_free() {
        let bridge = vt_store::EditorBridge::new();
        let doc = loro::LoroDoc::new();
        doc.config_text_style(crate::editor_api::voice_tool_style_config());
        bridge.open("realtime-doc", doc).unwrap();
        let mut utterance = projected_utterance();
        apply_rendered(
            &bridge,
            "realtime-doc",
            0,
            render_bilingual_capture_section("session-a", &[utterance.clone()], false),
        );

        for (revision, text) in [(0, "第一次编辑 🧭\n第二行"), (1, "第二次编辑 你好🌏")]
        {
            let delta = bridge.get_delta("realtime-doc").unwrap();
            let range = crate::editor_api::find_unique_marked_range(
                &delta,
                crate::editor_api::DeltaMarkSelector {
                    session_id: Some("session-a"),
                    utterance_id: Some("utterance-a"),
                    lane_language: Some("zh"),
                },
            )
            .unwrap()
            .unwrap();
            let mutation = projection_mutation(UtteranceLane::Translated, revision, text);
            let rendered = render_replacement_lane(&utterance, &mutation);
            bridge
                .apply(
                    "realtime-doc",
                    vt_store::EditOp::Replace {
                        pos: range.pos,
                        len: range.len,
                        text: rendered.text,
                    },
                )
                .unwrap();
            for mark in rendered.marks {
                bridge
                    .apply(
                        "realtime-doc",
                        vt_store::EditOp::Mark {
                            pos: range.pos + mark.pos,
                            len: mark.len,
                            key: mark.key,
                            value_json: mark.value_json,
                        },
                    )
                    .unwrap();
            }
            utterance.translated_text = Some(text.into());
            utterance.revision = revision + 1;
        }

        let content = bridge.get_content("realtime-doc").unwrap();
        assert!(content.contains("zh: 第二次编辑 你好🌏\n"));
        assert!(!content.contains("第一次编辑"));
        let delta: serde_json::Value =
            serde_json::from_str(&bridge.get_delta("realtime-doc").unwrap()).unwrap();
        for segment in delta.as_array().unwrap().iter().filter(|segment| {
            segment
                .get("attributes")
                .and_then(|value| value.get("utterance_id"))
                .and_then(serde_json::Value::as_str)
                == Some("utterance-a")
                && segment
                    .get("attributes")
                    .and_then(|value| value.get("lane_language"))
                    .and_then(serde_json::Value::as_str)
                    == Some("zh")
        }) {
            assert!(segment
                .get("attributes")
                .and_then(|value| value.get("source_timestamp_ms"))
                .is_none());
        }
    }

    #[test]
    fn section_anchor_encloses_unmarked_user_edits_and_purges_all_marks() {
        let bridge = vt_store::EditorBridge::new();
        let doc = loro::LoroDoc::new();
        doc.config_text_style(crate::editor_api::voice_tool_style_config());
        doc.get_text("content")
            .insert(0, "manual-before\n")
            .unwrap();
        bridge.open("realtime-doc", doc).unwrap();
        let insert_pos = "manual-before\n".chars().count();
        let rendered =
            render_bilingual_capture_section("session-a", &[projected_utterance()], true);
        let rendered_len = rendered.text.chars().count();
        apply_rendered(&bridge, "realtime-doc", insert_pos, rendered);
        bridge
            .set_capture_owned_range(
                "realtime-doc",
                &capture_section_owner_key("session-a"),
                "session-a",
                insert_pos,
                insert_pos + rendered_len,
            )
            .unwrap();

        // Ownership styles use ExpandType::None, so these edits split marks.
        bridge
            .apply(
                "realtime-doc",
                vt_store::EditOp::Insert {
                    pos: insert_pos,
                    text: "用户首行\n".into(),
                },
            )
            .unwrap();
        let (_, len) = bridge
            .resolve_capture_owned_range(
                "realtime-doc",
                &capture_section_owner_key("session-a"),
                "session-a",
            )
            .unwrap()
            .unwrap();
        bridge
            .apply(
                "realtime-doc",
                vt_store::EditOp::Insert {
                    pos: insert_pos + len,
                    text: "用户尾行\n".into(),
                },
            )
            .unwrap();
        let inside_pos = insert_pos + "用户首行\n".chars().count() + 6;
        let inside_text = "内部\n插入";
        bridge
            .apply(
                "realtime-doc",
                vt_store::EditOp::Insert {
                    pos: inside_pos,
                    text: inside_text.into(),
                },
            )
            .unwrap();
        for key in [
            "session_id",
            "utterance_id",
            "lane_language",
            "source_timestamp_ms",
            "utterance_revision",
        ] {
            bridge
                .apply(
                    "realtime-doc",
                    vt_store::EditOp::Unmark {
                        pos: inside_pos,
                        len: inside_text.chars().count(),
                        key: key.into(),
                    },
                )
                .unwrap();
        }

        let delta = bridge.get_delta("realtime-doc").unwrap();
        assert!(crate::editor_api::find_unique_marked_range(
            &delta,
            crate::editor_api::DeltaMarkSelector {
                session_id: Some("session-a"),
                utterance_id: None,
                lane_language: None,
            },
        )
        .is_err());
        let range = resolve_capture_section_range(&bridge, "realtime-doc", "session-a", &delta)
            .unwrap()
            .unwrap();
        bridge
            .apply(
                "realtime-doc",
                vt_store::EditOp::Delete {
                    pos: range.pos,
                    len: range.len,
                },
            )
            .unwrap();
        bridge
            .clear_capture_owned_ranges_for_session("realtime-doc", "session-a")
            .unwrap();

        assert_eq!(
            bridge.get_content("realtime-doc").unwrap(),
            "manual-before\n"
        );
        let delta = bridge.get_delta("realtime-doc").unwrap();
        assert!(!delta.contains("session-a"));
        assert!(!delta.contains("utterance-a"));
        assert!(!delta.contains("lane_language"));
    }

    #[test]
    fn local_persistence_failure_has_priority_over_provider_failure() {
        let provider = ProviderFailure {
            error_type: "provider_error".into(),
            request_id: Some("request-a".into()),
        };
        let local = local_persistence_failure("persist utterance", "disk full");

        assert_eq!(
            prefer_provider_failure(Some(provider.clone()), local.clone())
                .unwrap()
                .error_type,
            "local_persistence"
        );
        assert_eq!(
            prefer_provider_failure(Some(local), provider)
                .unwrap()
                .error_type,
            "local_persistence"
        );
    }

    #[test]
    fn capture_failure_metadata_is_typed_and_sanitized() {
        let provider =
            provider_failure(&SttStreamError::Provider(vt_stt::SttStreamProviderError {
                error_code: 400,
                error_type: "bad type\nsecret=value".into(),
                error_message: "remote payload must not persist".into(),
                request_id: Some("request\nvalue".into()),
            }));
        assert_eq!(provider.error_type, "bad_type_secret_value");
        assert_eq!(provider.request_id.as_deref(), Some("request_value"));
        assert!(!format!("{provider:?}").contains("remote payload must not persist"));

        let transport = provider_failure(&SttStreamError::Transport {
            operation: "read".into(),
            message: "credential-shaped remote transport detail".into(),
        });
        assert_eq!(transport.error_type, "transport");
        assert!(!format!("{transport:?}").contains("credential-shaped"));

        let local = local_persistence_failure("persist utterance", "private database detail");
        assert_eq!(local.error_type, "local_persistence");
        assert!(!format!("{local:?}").contains("private database detail"));
    }

    #[test]
    fn live_callback_payload_stays_constant_as_the_durable_session_grows() {
        let temp = tempfile::tempdir().unwrap();
        let core = ZulangueCore::new_for_test(temp.path().to_string_lossy().to_string()).unwrap();
        let notebook = core
            .create_notebook(Some("Incremental callback".into()))
            .unwrap();
        let profile = core
            .notebook_capture_store
            .get_or_create_profile(&notebook.id)
            .unwrap();
        let run = core
            .notebook_capture_store
            .create_run(
                &vt_store::notebook_capture_store::NewNotebookCaptureRun {
                    id: "incremental-run".into(),
                    notebook_id: notebook.id,
                    session_id: "session-a".into(),
                    remote_health: RemoteHealth::Off,
                    audio_journal_path: "incremental.journal".into(),
                    audio_key_ref: "incremental-key".into(),
                    sample_rate: 16_000,
                    channels: 1,
                },
                &profile,
            )
            .unwrap();
        claim_current_realtime_provider(&core.notebook_capture_store, &run.session_id);
        let mut changed = None;
        for sequence in 0..128_u64 {
            changed = Some(
                core.notebook_capture_store
                    .upsert_utterance(
                        &NewRealtimeUtterance {
                            id: format!("utterance-{sequence}"),
                            session_id: "session-a".into(),
                            sequence,
                            session_speaker_id: None,
                            source_language: "en".into(),
                            source_text: format!("source-{sequence}"),
                            source_start_ms: Some(sequence * 100),
                            source_end_ms: Some(sequence * 100 + 50),
                            translated_language: Some("zh".into()),
                            translated_text: Some(format!("translated-{sequence}")),
                            completion: UtteranceCompletion::Complete,
                            alignment: UtteranceAlignment::Paired,
                        },
                        None,
                    )
                    .unwrap(),
            );
        }
        let run = core
            .notebook_capture_store
            .get_run(&run.id)
            .unwrap()
            .unwrap();
        let (callback_tx, _callback_rx) = std::sync::mpsc::channel();
        let callback = CaptureCallbackSink::new(Arc::new(CaptureEventSender(callback_tx))).unwrap();

        let first_preview = callback.send_preview(FfiNotebookCaptureLivePreview {
            session_id: run.session_id.clone(),
            preview_revision: 0,
            utterances: Vec::new(),
        });
        let second_preview = callback.send_preview(FfiNotebookCaptureLivePreview {
            session_id: run.session_id.clone(),
            preview_revision: 0,
            utterances: Vec::new(),
        });
        let first = callback.send(event_from_run(
            run.clone(),
            vec![changed.expect("the final changed utterance")],
            false,
        ));
        let second = callback.send(event_from_run(run.clone(), Vec::new(), false));

        assert_eq!(first_preview.preview_revision, 1);
        assert_eq!(second_preview.preview_revision, 2);
        assert_eq!(first.event_revision, 1);
        assert_eq!(second.event_revision, 2);
        assert!(!first.is_full_snapshot);
        assert_eq!(first.utterances.len(), 1);
        assert!(second.utterances.is_empty());
        assert_eq!(
            first.realtime_provider_id.as_deref(),
            Some(CURRENT_NOTEBOOK_CAPTURE_ENGINE.provider_id)
        );
        assert_eq!(
            first.realtime_model_id.as_deref(),
            Some(CURRENT_NOTEBOOK_CAPTURE_ENGINE.realtime_model_id)
        );
        assert!(first.post_stop_provider_id.is_none());
        assert!(first.post_stop_model_id.is_none());

        // Full materialization remains available only at explicit boundaries
        // such as stop/reopen, never once per live token batch.
        let full = event_full_snapshot_from_run(&core.notebook_capture_store, run).unwrap();
        assert!(full.is_full_snapshot);
        assert_eq!(full.utterances.len(), 128);
    }

    fn projected_core_fixture() -> (tempfile::TempDir, ZulangueCore, String, String, String) {
        let temp = tempfile::tempdir().unwrap();
        let core = ZulangueCore::new_for_test(temp.path().to_string_lossy().to_string()).unwrap();
        let notebook = core
            .create_notebook(Some("Projection test".into()))
            .unwrap();
        let profile = core
            .notebook_capture_store
            .get_or_create_profile(&notebook.id)
            .unwrap();
        let run = core
            .notebook_capture_store
            .create_run(
                &vt_store::notebook_capture_store::NewNotebookCaptureRun {
                    id: "run-a".into(),
                    notebook_id: notebook.id.clone(),
                    session_id: "session-a".into(),
                    remote_health: RemoteHealth::Off,
                    audio_journal_path: "capture-a.journal".into(),
                    audio_key_ref: "capture-key-a".into(),
                    sample_rate: 16_000,
                    channels: 1,
                },
                &profile,
            )
            .unwrap();
        claim_current_realtime_provider(&core.notebook_capture_store, &run.session_id);
        core.notebook_capture_store
            .upsert_utterance(
                &NewRealtimeUtterance {
                    id: "utterance-a".into(),
                    session_id: "session-a".into(),
                    sequence: 0,
                    session_speaker_id: None,
                    source_language: "en".into(),
                    source_text: "hello".into(),
                    source_start_ms: Some(0),
                    source_end_ms: Some(500),
                    translated_language: Some("zh".into()),
                    translated_text: Some("你好".into()),
                    completion: UtteranceCompletion::Complete,
                    alignment: UtteranceAlignment::Paired,
                },
                None,
            )
            .unwrap();
        core.notebook_capture_store
            .transition_capture(&run.id, CaptureState::Recording, CaptureState::Draining)
            .unwrap();
        core.notebook_capture_store
            .transition_capture(&run.id, CaptureState::Draining, CaptureState::Completed)
            .unwrap();
        let doc_id = core
            .list_notebook_tabs(notebook.id.clone())
            .unwrap()
            .into_iter()
            .find(|tab| tab.builtin_kind == "realtime_transcript")
            .unwrap()
            .doc_id;
        (temp, core, notebook.id, run.id, doc_id)
    }

    #[derive(Debug, Clone, Copy)]
    enum StopDurabilityFault {
        FinalizeRun,
        SessionMeta,
        RetentionChunk,
        SessionRecord,
    }

    impl StopDurabilityFault {
        fn trigger_sql(self) -> &'static str {
            match self {
                Self::FinalizeRun => {
                    "CREATE TRIGGER fail_notebook_stop_durability
                     BEFORE UPDATE OF audio_path ON notebook_capture_runs
                     WHEN NEW.audio_path IS NOT NULL
                     BEGIN
                         SELECT RAISE(FAIL, 'injected finalize_audio failure');
                     END;"
                }
                Self::SessionMeta => {
                    "CREATE TRIGGER fail_notebook_stop_durability
                     BEFORE UPDATE OF encrypted_path ON session_meta
                     WHEN NEW.encrypted_path IS NOT NULL
                     BEGIN
                         SELECT RAISE(FAIL, 'injected session_meta failure');
                     END;"
                }
                Self::RetentionChunk => {
                    "CREATE TRIGGER fail_notebook_stop_durability
                     BEFORE INSERT ON audio_retention_chunks
                     BEGIN
                         SELECT RAISE(FAIL, 'injected retention chunk failure');
                     END;"
                }
                Self::SessionRecord => {
                    "CREATE TRIGGER fail_notebook_stop_durability
                     BEFORE INSERT ON session_records
                     WHEN NEW.status = 'completed'
                     BEGIN
                         SELECT RAISE(FAIL, 'injected session record failure');
                     END;"
                }
            }
        }
    }

    fn start_async_local_capture(
        core: &ZulangueCore,
        notebook_id: &str,
    ) -> (FfiNotebookCaptureProfile, FfiNotebookCaptureEvent) {
        let profile = core
            .get_notebook_capture_profile(notebook_id.to_string())
            .unwrap();
        let started = core
            .start_notebook_capture_session(
                notebook_id.to_string(),
                profile.revision,
                None,
                Box::new(CaptureEventSender(std::sync::mpsc::channel().0)),
            )
            .unwrap();
        (profile, started)
    }

    fn assert_journal_contains_recoverable_audio(
        core: &ZulangueCore,
        data_dir: &std::path::Path,
        run: &NotebookCaptureRun,
    ) {
        let key = core
            .key_store
            .load_key(run.audio_key_ref.as_deref().unwrap())
            .unwrap();
        let recovered = vt_pipeline::recover_capture_audio_journal(
            std::path::Path::new(run.audio_journal_path.as_deref().unwrap()),
            data_dir,
            &run.session_id,
            &key,
            run.sample_rate.unwrap(),
            run.channels.unwrap(),
        )
        .unwrap();
        assert_eq!(recovered.captured_frames, 1_600);
        assert_eq!(recovered.duration_ms, 100);
        assert!(!recovered.audio_chunks.is_empty());
        let mut reader =
            vt_crypto::DecryptReader::new(&recovered.audio_chunks[0].path, &key).unwrap();
        let mut plaintext = Vec::new();
        std::io::Read::read_to_end(&mut reader, &mut plaintext).unwrap();
        assert_eq!(plaintext.len(), 1_600 * 4);
    }

    #[test]
    fn stop_durability_failures_interrupt_pending_async_without_losing_audio_or_owner() {
        for fault in [
            StopDurabilityFault::FinalizeRun,
            StopDurabilityFault::SessionMeta,
            StopDurabilityFault::RetentionChunk,
            StopDurabilityFault::SessionRecord,
        ] {
            let temp = tempfile::tempdir().unwrap();
            let core =
                ZulangueCore::new_for_test(temp.path().to_string_lossy().to_string()).unwrap();
            let notebook = core
                .create_notebook(Some(format!("Stop fault {fault:?}")))
                .unwrap();
            let (profile, started) = start_async_local_capture(&core, &notebook.id);
            let mut original_session = core.session_store.get_session(&started.session_id).unwrap();
            original_session.title = format!("Preserved title {fault:?}");
            original_session.session_type = "import".into();
            original_session.created_at = "2001-02-03 04:05:06".into();
            core.session_store
                .insert_session(&original_session)
                .unwrap();
            core.push_notebook_capture_session(started.session_id.clone(), vec![0_u8; 3_200])
                .unwrap();

            let db = rusqlite::Connection::open(temp.path().join("zulangue.db")).unwrap();
            db.execute_batch(fault.trigger_sql()).unwrap();
            let error = core
                .stop_notebook_capture_session(started.session_id.clone())
                .unwrap_err();
            assert!(error
                .to_string()
                .contains("persist finalized capture audio"));

            let interrupted = core
                .notebook_capture_store
                .get_run_for_session(&started.session_id)
                .unwrap()
                .unwrap();
            assert_eq!(interrupted.capture_state, CaptureState::Interrupted);
            assert_eq!(interrupted.remote_health, RemoteHealth::Off);
            assert_eq!(
                interrupted.provider_error_type.as_deref(),
                Some("local_persistence")
            );
            assert_eq!(interrupted.async_task_state, AsyncTaskState::None);
            assert!(interrupted.async_task_id.is_none());
            assert!(interrupted.async_task_payload_sha256.is_none());
            assert!(
                std::path::Path::new(interrupted.audio_journal_path.as_deref().unwrap()).exists()
            );
            assert_journal_contains_recoverable_audio(&core, temp.path(), &interrupted);

            let preserved = core.session_store.get_session(&started.session_id).unwrap();
            assert_eq!(preserved.title, original_session.title);
            assert_eq!(preserved.session_type, original_session.session_type);
            assert_eq!(preserved.created_at, original_session.created_at);
            assert!(core
                .runtime
                .block_on(core.task_queue.list_tasks(None))
                .unwrap()
                .is_empty());

            db.execute_batch("DROP TRIGGER fail_notebook_stop_durability;")
                .unwrap();
            let next = core
                .start_notebook_capture_session(
                    notebook.id,
                    profile.revision,
                    None,
                    Box::new(CaptureEventSender(std::sync::mpsc::channel().0)),
                )
                .expect("a failed stop must release the sole capture owner");
            core.interrupt_notebook_capture_session(
                next.session_id,
                FfiNotebookCaptureInterruptReason::LocalAudioUnavailable,
            )
            .unwrap();
        }
    }

    #[test]
    fn journal_stop_failure_interrupts_pending_async_and_retains_recoverable_audio() {
        let temp = tempfile::tempdir().unwrap();
        let core = ZulangueCore::new_for_test(temp.path().to_string_lossy().to_string()).unwrap();
        let notebook = core
            .create_notebook(Some("Journal stop fault".into()))
            .unwrap();
        let (profile, started) = start_async_local_capture(&core, &notebook.id);
        let mut original_session = core.session_store.get_session(&started.session_id).unwrap();
        original_session.title = "Preserve journal failure title".into();
        original_session.created_at = "2002-03-04 05:06:07".into();
        core.session_store
            .insert_session(&original_session)
            .unwrap();
        core.push_notebook_capture_session(started.session_id.clone(), vec![0_u8; 3_200])
            .unwrap();
        let active_run = core
            .notebook_capture_store
            .get_run_for_session(&started.session_id)
            .unwrap()
            .unwrap();
        let chunk_path = temp
            .path()
            .join(format!("{}.chunk.00000.enc", started.session_id));
        std::fs::create_dir(&chunk_path).unwrap();

        let error = core
            .stop_notebook_capture_session(started.session_id.clone())
            .unwrap_err();
        assert!(error
            .to_string()
            .contains("finalize encrypted capture audio"));
        let interrupted = core
            .notebook_capture_store
            .get_run(&active_run.id)
            .unwrap()
            .unwrap();
        assert_eq!(interrupted.capture_state, CaptureState::Interrupted);
        assert_eq!(interrupted.async_task_state, AsyncTaskState::None);
        assert_eq!(
            interrupted.provider_error_type.as_deref(),
            Some("local_persistence")
        );
        assert!(std::path::Path::new(interrupted.audio_journal_path.as_deref().unwrap()).exists());
        let preserved = core.session_store.get_session(&started.session_id).unwrap();
        assert_eq!(preserved.title, original_session.title);
        assert_eq!(preserved.created_at, original_session.created_at);
        assert!(core
            .runtime
            .block_on(core.task_queue.list_tasks(None))
            .unwrap()
            .is_empty());

        std::fs::remove_dir(&chunk_path).unwrap();
        assert_journal_contains_recoverable_audio(&core, temp.path(), &interrupted);
        let next = core
            .start_notebook_capture_session(
                notebook.id,
                profile.revision,
                None,
                Box::new(CaptureEventSender(std::sync::mpsc::channel().0)),
            )
            .expect("a journal stop failure must release the sole capture owner");
        core.interrupt_notebook_capture_session(
            next.session_id,
            FfiNotebookCaptureInterruptReason::LocalAudioUnavailable,
        )
        .unwrap();
    }

    #[test]
    fn successful_stop_preserves_session_identity_fields_and_updates_only_completion_fields() {
        let temp = tempfile::tempdir().unwrap();
        let core = ZulangueCore::new_for_test(temp.path().to_string_lossy().to_string()).unwrap();
        let notebook = core
            .create_notebook(Some("Session identity".into()))
            .unwrap();
        let profile = core
            .get_notebook_capture_profile(notebook.id.clone())
            .unwrap();
        let started = core
            .start_notebook_capture_session(
                notebook.id,
                profile.revision,
                None,
                Box::new(CaptureEventSender(std::sync::mpsc::channel().0)),
            )
            .unwrap();
        let mut original = core.session_store.get_session(&started.session_id).unwrap();
        original.title = "User title must survive".into();
        original.session_type = "import".into();
        original.created_at = "2003-04-05 06:07:08".into();
        core.session_store.insert_session(&original).unwrap();
        core.push_notebook_capture_session(started.session_id.clone(), vec![0_u8; 3_200])
            .unwrap();

        core.stop_notebook_capture_session(started.session_id.clone())
            .unwrap();
        let completed = core.session_store.get_session(&started.session_id).unwrap();
        assert_eq!(completed.title, original.title);
        assert_eq!(completed.session_type, original.session_type);
        assert_eq!(completed.created_at, original.created_at);
        assert_eq!(completed.deleted_at, original.deleted_at);
        assert_eq!(completed.status, "completed");
        assert_eq!(completed.duration_ms, 100);
    }

    #[test]
    fn controlled_audio_interrupt_preserves_audio_and_skips_async_projection() {
        let temp = tempfile::tempdir().unwrap();
        let core = ZulangueCore::new_for_test(temp.path().to_string_lossy().to_string()).unwrap();
        let notebook = core.create_notebook(Some("Interrupt test".into())).unwrap();
        let profile = core
            .get_notebook_capture_profile(notebook.id.clone())
            .unwrap();
        let (callback_tx, callback_rx) = std::sync::mpsc::channel();
        let started = core
            .start_notebook_capture_session(
                notebook.id.clone(),
                profile.revision,
                None,
                Box::new(CaptureEventSender(callback_tx)),
            )
            .unwrap();
        let original_session = core.session_store.get_session(&started.session_id).unwrap();
        core.push_notebook_capture_session(started.session_id.clone(), vec![0_u8; 3_200])
            .unwrap();
        assert!(core
            .interrupt_notebook_capture_session(
                "wrong-session".into(),
                FfiNotebookCaptureInterruptReason::LocalAudioOverflow,
            )
            .is_err());
        // A mismatched request must not remove or poison the real owner.
        core.push_notebook_capture_session(started.session_id.clone(), vec![1_u8; 3_200])
            .unwrap();

        let interrupted = core
            .interrupt_notebook_capture_session(
                started.session_id.clone(),
                FfiNotebookCaptureInterruptReason::LocalAudioOverflow,
            )
            .unwrap();
        assert_eq!(
            interrupted.capture_state,
            FfiNotebookCaptureState::Interrupted
        );
        assert_eq!(
            interrupted.provider_error_type.as_deref(),
            Some("local_audio_overflow")
        );
        assert_eq!(interrupted.post_stop_async_state, "none");
        assert_ne!(
            interrupted.projection_state,
            FfiNotebookProjectionState::Ready
        );

        let run = core
            .notebook_capture_store
            .get_run_for_session(&started.session_id)
            .unwrap()
            .unwrap();
        assert_eq!(run.capture_state, CaptureState::Interrupted);
        assert_eq!(run.async_task_state, AsyncTaskState::None);
        assert_ne!(run.projection_state, ProjectionState::Ready);
        assert!(run.captured_frames > 0);
        let audio_path = std::path::PathBuf::from(run.audio_path.unwrap());
        assert!(audio_path.exists());
        assert!(std::fs::metadata(&audio_path).unwrap().len() > 0);
        let chunks = core
            .session_meta
            .list_audio_retention_chunks(&started.session_id)
            .unwrap();
        assert!(!chunks.is_empty());
        assert!(chunks
            .iter()
            .all(|chunk| chunk.encrypted && std::path::Path::new(&chunk.local_path).exists()));
        let session = core.session_store.get_session(&started.session_id).unwrap();
        assert_eq!(session.created_at, original_session.created_at);
        assert_eq!(session.title, original_session.title);
        assert_eq!(session.session_type, original_session.session_type);
        assert_eq!(session.status, "interrupted");
        assert!(core
            .runtime
            .block_on(core.task_queue.list_tasks(None))
            .unwrap()
            .is_empty());
        let recovered_event = core
            .get_notebook_capture_session_event(started.session_id.clone())
            .unwrap();
        assert_eq!(recovered_event.capture_state, interrupted.capture_state);
        assert_eq!(
            recovered_event.provider_error_type,
            interrupted.provider_error_type
        );
        let callback_event = (0..4)
            .filter_map(|_| {
                callback_rx
                    .recv_timeout(std::time::Duration::from_secs(1))
                    .ok()
            })
            .find(|event| event.capture_state == FfiNotebookCaptureState::Interrupted)
            .expect("callback must publish the durable interrupted snapshot");
        assert_eq!(
            callback_event.provider_error_type,
            interrupted.provider_error_type
        );
        assert!(core
            .interrupt_notebook_capture_session(
                started.session_id,
                FfiNotebookCaptureInterruptReason::LocalAudioOverflow,
            )
            .is_err());

        // The second controlled reason and Paused -> Interrupted CAS share the
        // same fail-closed durability path.
        let second = core
            .start_notebook_capture_session(
                notebook.id,
                profile.revision,
                None,
                Box::new(CaptureEventSender(std::sync::mpsc::channel().0)),
            )
            .unwrap();
        core.pause_notebook_capture_session(second.session_id.clone(), true)
            .unwrap();
        let unavailable = core
            .interrupt_notebook_capture_session(
                second.session_id,
                FfiNotebookCaptureInterruptReason::LocalAudioUnavailable,
            )
            .unwrap();
        assert_eq!(
            unavailable.provider_error_type.as_deref(),
            Some("local_audio_unavailable")
        );
        assert_eq!(unavailable.post_stop_async_state, "none");
    }

    #[test]
    fn corrupt_snapshot_never_commits_projection_lane_mutation_or_purge() {
        let (temp, core, _notebook_id, run_id, doc_id) = projected_core_fixture();
        let path = crate::editor_api::snapshot_path(temp.path(), &doc_id);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        let corrupt = b"corrupt-loro-snapshot\0private-user-bytes";
        std::fs::write(&path, corrupt).unwrap();

        assert!(core.project_notebook_capture(&run_id).is_err());
        let failed = core
            .notebook_capture_store
            .get_run(&run_id)
            .unwrap()
            .unwrap();
        assert_eq!(failed.projection_state, ProjectionState::Failed);
        assert_eq!(std::fs::read(&path).unwrap(), corrupt);

        // Build a valid Ready projection, then corrupt only its authoritative
        // durable snapshot before staging a lane edit.
        std::fs::remove_file(&path).unwrap();
        core.editor_bridge.evict(&doc_id);
        core.notebook_capture_store
            .retry_projection(&run_id)
            .unwrap();
        core.project_notebook_capture(&run_id).unwrap();
        std::fs::write(&path, corrupt).unwrap();
        let original = core
            .notebook_capture_store
            .get_utterance_by_id("utterance-a")
            .unwrap()
            .unwrap();
        assert!(core
            .replace_notebook_utterance_lane(
                "utterance-a".into(),
                "zh".into(),
                "损坏快照不得提交".into(),
                original.revision,
            )
            .is_err());
        let after_lane = core
            .notebook_capture_store
            .get_utterance_by_id("utterance-a")
            .unwrap()
            .unwrap();
        assert_eq!(after_lane.revision, original.revision);
        assert_eq!(after_lane.translated_text, original.translated_text);
        assert!(core
            .notebook_capture_store
            .list_pending_projection_mutations()
            .unwrap()
            .is_empty());
        assert_eq!(std::fs::read(&path).unwrap(), corrupt);

        assert!(core.purge_session_forever("session-a").is_err());
        assert!(core
            .notebook_capture_store
            .get_run(&run_id)
            .unwrap()
            .is_some());
        assert!(core
            .notebook_capture_store
            .get_session_purge_job("session-a")
            .unwrap()
            .is_some());
        assert_eq!(std::fs::read(&path).unwrap(), corrupt);
    }

    #[test]
    fn failed_capture_start_cleanup_is_a_restartable_purge_saga() {
        let temp = tempfile::tempdir().unwrap();
        let core = ZulangueCore::new_for_test(temp.path().to_string_lossy().to_string()).unwrap();
        let session = core.create_notebook_capture_session().unwrap();
        let blocked_path = temp.path().join("blocked-capture-artifact");
        std::fs::create_dir(&blocked_path).unwrap();
        let key_ref = format!("zulangue.audio.{}", session.id);
        core.key_store
            .store_key(&key_ref, &SessionKey::generate())
            .unwrap();

        core.rollback_failed_capture_start(
            &session.id,
            std::slice::from_ref(&blocked_path),
            std::slice::from_ref(&key_ref),
        );

        let pending = core
            .notebook_capture_store
            .get_session_purge_job(&session.id)
            .unwrap()
            .expect("failed external cleanup must retain its durable tombstone");
        assert_eq!(pending.phase, "tasks_removed");
        assert!(pending
            .last_error
            .as_deref()
            .is_some_and(|message| { message.contains("delete capture artifact") }));
        assert!(pending
            .plan
            .file_paths
            .contains(&blocked_path.to_string_lossy().into_owned()));
        assert!(pending.plan.key_refs.contains(&key_ref));
        assert!(core.key_store.key_exists(&key_ref));

        std::fs::remove_dir(&blocked_path).unwrap();
        core.resume_pending_session_purges().unwrap();
        assert!(core
            .notebook_capture_store
            .get_session_purge_job(&session.id)
            .unwrap()
            .is_none());
        assert!(!core.key_store.key_exists(&key_ref));
        assert!(core.session_store.get_session(&session.id).is_err());
    }

    #[test]
    fn one_failed_pending_purge_does_not_block_core_reopen() {
        let (temp, core, _notebook_id, run_id, doc_id) = projected_core_fixture();
        core.project_notebook_capture(&run_id).unwrap();
        let path = crate::editor_api::snapshot_path(temp.path(), &doc_id);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, b"corrupt-purge-snapshot").unwrap();
        core.editor_bridge.evict(&doc_id);
        assert!(core.purge_session_forever("session-a").is_err());
        let before = core
            .notebook_capture_store
            .get_session_purge_job("session-a")
            .unwrap()
            .unwrap();
        assert!(before.last_error.is_some());
        core.shutdown().unwrap();
        drop(core);

        let reopened = ZulangueCore::new_for_test(temp.path().to_string_lossy().to_string())
            .expect("a session-scoped purge error must not abort Core startup");
        let quarantined = reopened
            .notebook_capture_store
            .get_session_purge_job("session-a")
            .unwrap()
            .expect("the failed purge must remain retryable");
        assert!(quarantined.last_error.as_deref().is_some_and(|message| {
            message.contains("snapshot") || message.contains("Loro") || message.contains("loro")
        }));
    }

    #[test]
    fn durable_provider_receipt_recovers_after_privacy_and_queue_completion_faults() {
        let temp = tempfile::tempdir().unwrap();
        let core = ZulangueCore::new_for_test(temp.path().to_string_lossy().to_string()).unwrap();
        let notebook = core
            .create_notebook(Some("Receipt-only recovery".into()))
            .unwrap();
        let current = core
            .notebook_capture_store
            .get_or_create_profile(&notebook.id)
            .unwrap();
        let profile = core
            .notebook_capture_store
            .update_profile(
                &notebook.id,
                current.revision,
                &NotebookCaptureProfileUpdate {
                    remote_realtime_enabled: false,
                    capture_mode: CaptureMode::TranscriptionOnly,
                    language_a: "en".into(),
                    language_b: "zh".into(),
                    left_language: "en".into(),
                    right_language: "zh".into(),
                    selected_languages: vec!["en".into(), "zh".into()],
                    common_caption_language: None,
                    privacy_level: "high".into(),
                    send_context_to_soniox: false,
                },
            )
            .unwrap();
        let run = core
            .notebook_capture_store
            .create_completed_import_run(
                &vt_store::notebook_capture_store::NewCompletedNotebookImportRun {
                    id: "receipt-recovery-run".into(),
                    notebook_id: notebook.id.clone(),
                    session_id: "receipt-recovery-session".into(),
                    audio_path: temp
                        .path()
                        .join("intentionally-missing-audio.enc")
                        .to_string_lossy()
                        .into_owned(),
                    audio_key_ref: "intentionally-missing-key".into(),
                    sample_rate: 16_000,
                    channels: 1,
                    captured_frames: 16_000,
                },
                &profile,
            )
            .unwrap();
        core.session_meta
            .set_privacy_level(&run.session_id, "high")
            .unwrap();
        core.notebook_store
            .ensure_session_projection(
                &notebook.id,
                vt_store::BuiltinNotebookTab::AsyncTranscript,
                &run.session_id,
                Some("Recovered transcript"),
            )
            .unwrap();
        let authorized = core
            .notebook_capture_store
            .authorize_async_transcription(&run.session_id, 1, Some("en"))
            .unwrap();
        core.ensure_post_stop_async_task_for_run(&authorized)
            .unwrap();
        let enqueued = core
            .notebook_capture_store
            .get_run(&run.id)
            .unwrap()
            .unwrap();
        let task_id = enqueued.async_task_id.clone().unwrap();
        let token = vt_model::Token {
            text: "already remote once".into(),
            start_ms: 0,
            end_ms: 500,
            is_final: true,
            language: "en".into(),
            confidence: 1.0,
            translation_status: vt_model::TranslationStatus::None,
            speaker: None,
        };
        let result_json = serde_json::json!({
            "session_id": run.session_id,
            "token_count": 1,
            "full_text": "already remote once",
            "duration_ms": 500,
        })
        .to_string();
        claim_current_post_stop_provider(&core.notebook_capture_store, &enqueued.session_id);
        core.notebook_capture_store
            .commit_async_provider_success(&enqueued.session_id, &task_id, &[token], &result_json)
            .unwrap();
        let blocked_audio_path = temp.path().join("privacy-cleanup-blocked-directory");
        std::fs::create_dir(&blocked_audio_path).unwrap();
        core.session_meta
            .upsert_audio_retention_chunk(&vt_store::AudioChunkRetentionRecord {
                session_id: enqueued.session_id.clone(),
                chunk_id: "receipt-recovery-blocked-chunk".into(),
                start_ms: 0,
                end_ms: 500,
                local_path: blocked_audio_path.to_string_lossy().into_owned(),
                encrypted: true,
                deleted: false,
                retention_deadline_ms: 0,
                delete_error: None,
                deleted_at_ms: None,
            })
            .unwrap();

        let privacy_error = core
            .complete_recovered_provider_receipt(&enqueued, &task_id)
            .unwrap_err();
        assert!(privacy_error.to_string().contains("privacy cleanup"));
        assert_eq!(
            core.notebook_capture_store
                .get_run(&run.id)
                .unwrap()
                .unwrap()
                .async_task_state,
            AsyncTaskState::Enqueued
        );
        assert!(matches!(
            core.runtime
                .block_on(core.task_queue.get_status(&task_id))
                .unwrap(),
            vt_pipeline::TaskStatus::Pending | vt_pipeline::TaskStatus::Running
        ));

        core.shutdown().unwrap();
        std::thread::sleep(std::time::Duration::from_millis(50));
        std::fs::remove_dir(&blocked_audio_path).unwrap();
        assert!(core
            .runtime
            .block_on(core.task_queue.purge_task(&task_id))
            .unwrap());
        let queue_error = core
            .complete_recovered_provider_receipt(&enqueued, &task_id)
            .unwrap_err();
        assert!(queue_error.to_string().contains(&task_id));
        assert!(!core.api_key_store.has("soniox"));
        assert!(core
            .runtime
            .block_on(core.task_queue.get_task(&task_id))
            .is_err());
        assert_eq!(
            core.notebook_capture_store
                .get_run(&run.id)
                .unwrap()
                .unwrap()
                .async_task_state,
            AsyncTaskState::Enqueued,
            "local faults must not rewrite the immutable provider success"
        );
        core.shutdown().unwrap();
        drop(core);

        let reopened = ZulangueCore::new_for_test(temp.path().to_string_lossy().to_string())
            .expect("receipt recovery must not require a provider credential");
        assert!(!reopened.api_key_store.has("soniox"));
        assert_eq!(
            reopened
                .runtime
                .block_on(reopened.task_queue.get_status(&task_id))
                .unwrap(),
            vt_pipeline::TaskStatus::Completed
        );
        let recovered = reopened
            .notebook_capture_store
            .get_run(&run.id)
            .unwrap()
            .unwrap();
        assert_eq!(recovered.async_task_state, AsyncTaskState::Completed);
        assert_eq!(
            recovered.async_projection_state,
            AsyncProjectionState::Ready,
            "Loro projection must rebuild locally from persisted tokens"
        );
        assert!(reopened
            .search_store
            .search("already", 10)
            .unwrap()
            .iter()
            .any(|result| result.session_id == recovered.session_id));
    }

    #[test]
    fn main_terminal_write_fault_converges_to_ready_in_the_same_process() {
        let temp = tempfile::tempdir().unwrap();
        let core = ZulangueCore::new_for_test(temp.path().to_string_lossy().to_string()).unwrap();
        let notebook = core
            .create_notebook(Some("Same-process receipt recovery".into()))
            .unwrap();
        let current = core
            .notebook_capture_store
            .get_or_create_profile(&notebook.id)
            .unwrap();
        let profile = core
            .notebook_capture_store
            .update_profile(
                &notebook.id,
                current.revision,
                &NotebookCaptureProfileUpdate {
                    remote_realtime_enabled: false,
                    capture_mode: CaptureMode::TranscriptionOnly,
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
        let run = core
            .notebook_capture_store
            .create_completed_import_run(
                &vt_store::notebook_capture_store::NewCompletedNotebookImportRun {
                    id: "same-process-receipt-run".into(),
                    notebook_id: notebook.id.clone(),
                    session_id: "same-process-receipt-session".into(),
                    audio_path: temp
                        .path()
                        .join("missing-after-provider-success.enc")
                        .to_string_lossy()
                        .into_owned(),
                    audio_key_ref: "missing-after-provider-success-key".into(),
                    sample_rate: 16_000,
                    channels: 1,
                    captured_frames: 16_000,
                },
                &profile,
            )
            .unwrap();
        core.session_meta
            .set_privacy_level(&run.session_id, "standard")
            .unwrap();
        core.notebook_store
            .ensure_session_projection(
                &notebook.id,
                vt_store::BuiltinNotebookTab::AsyncTranscript,
                &run.session_id,
                Some("Same-process transcript"),
            )
            .unwrap();
        let authorized = core
            .notebook_capture_store
            .authorize_async_transcription(&run.session_id, 1, Some("en"))
            .unwrap();
        core.ensure_post_stop_async_task_for_run(&authorized)
            .unwrap();
        let enqueued = core
            .notebook_capture_store
            .get_run(&run.id)
            .unwrap()
            .unwrap();
        let task_id = enqueued.async_task_id.clone().unwrap();

        // Stop the background loop so the two injected terminal-write attempts
        // below are deterministic; all recovery still occurs in this Core and
        // runtime, without reopening either database.
        core.shutdown().unwrap();
        std::thread::sleep(std::time::Duration::from_millis(50));
        let token = vt_model::Token {
            text: "same process ready".into(),
            start_ms: 0,
            end_ms: 500,
            is_final: true,
            language: "en".into(),
            confidence: 1.0,
            translation_status: vt_model::TranslationStatus::None,
            speaker: None,
        };
        let result_json = serde_json::json!({
            "session_id": run.session_id,
            "token_count": 1,
            "full_text": "same process ready",
            "duration_ms": 500,
        })
        .to_string();
        claim_current_post_stop_provider(&core.notebook_capture_store, &enqueued.session_id);
        let receipt = core
            .notebook_capture_store
            .commit_async_provider_success(&enqueued.session_id, &task_id, &[token], &result_json)
            .unwrap();
        core.runtime
            .block_on(
                core.task_queue
                    .complete_from_durable_provider_receipt(&task_id),
            )
            .unwrap();

        let first = core.runtime.block_on(
            crate::task_worker::reconcile_completed_provider_receipt_with(
                core.task_queue.as_ref(),
                &receipt,
                |_| Err("injected main terminal write failure".to_string()),
            ),
        );
        assert!(first.is_err());
        assert_eq!(
            core.notebook_capture_store
                .get_run(&run.id)
                .unwrap()
                .unwrap()
                .async_task_state,
            AsyncTaskState::Enqueued
        );

        let callback_count = AtomicUsize::new(0);
        let recovery = core
            .runtime
            .block_on(crate::task_worker::recover_completed_provider_receipt_with(
                core.task_queue.as_ref(),
                &core.notebook_capture_store,
                &core.session_task_registry,
                &receipt,
                |receipt| {
                    core.notebook_capture_store
                        .mark_async_task_terminal_for_session(
                            &receipt.session_id,
                            &receipt.task_id,
                            true,
                        )
                        .map(|_| ())
                        .map_err(|error| error.to_string())
                },
                |receipt| {
                    crate::transcribe_api::project_transcribe_search_receipt(
                        &temp.path().join("zulangue.db"),
                        receipt,
                    )
                },
                |receipt| {
                    core.notebook_transcript_projector()
                        .project_persisted_async_transcript(
                            &core.notebook_capture_store,
                            &receipt.session_id,
                        )
                        .map(|_| ())
                        .map_err(|error| error.to_string())
                },
                |_| {
                    callback_count.fetch_add(1, Ordering::SeqCst);
                },
            ))
            .unwrap();
        assert_eq!(
            recovery,
            crate::task_worker::CompletedProviderReceiptRecoveryOutcome::Completed
        );
        assert_eq!(callback_count.load(Ordering::SeqCst), 1);

        let recovered = core
            .notebook_capture_store
            .get_run(&run.id)
            .unwrap()
            .unwrap();
        assert_eq!(recovered.async_task_state, AsyncTaskState::Completed);
        assert_eq!(
            recovered.async_projection_state,
            AsyncProjectionState::Ready
        );
        assert!(core
            .search_store
            .search("same process", 10)
            .unwrap()
            .iter()
            .any(|result| result.session_id == recovered.session_id));
        assert!(!core.api_key_store.has("soniox"));
        assert!(!temp
            .path()
            .join("missing-after-provider-success.enc")
            .exists());
    }

    #[test]
    fn delete_forever_cancels_completed_receipt_recovery_without_resurrection() {
        let temp = tempfile::tempdir().unwrap();
        let core = ZulangueCore::new_for_test(temp.path().to_string_lossy().to_string()).unwrap();
        let notebook = core
            .create_notebook(Some("Purge receipt race".into()))
            .unwrap();
        let current = core
            .notebook_capture_store
            .get_or_create_profile(&notebook.id)
            .unwrap();
        let profile = core
            .notebook_capture_store
            .update_profile(
                &notebook.id,
                current.revision,
                &NotebookCaptureProfileUpdate {
                    remote_realtime_enabled: false,
                    capture_mode: CaptureMode::TranscriptionOnly,
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
        let session_id = "purge-receipt-race-session".to_string();
        let run = core
            .notebook_capture_store
            .create_completed_import_run(
                &vt_store::notebook_capture_store::NewCompletedNotebookImportRun {
                    id: "purge-receipt-race-run".into(),
                    notebook_id: notebook.id.clone(),
                    session_id: session_id.clone(),
                    audio_path: temp
                        .path()
                        .join("purge-race-missing-audio.enc")
                        .to_string_lossy()
                        .into_owned(),
                    audio_key_ref: "purge-race-missing-key".into(),
                    sample_rate: 16_000,
                    channels: 1,
                    captured_frames: 16_000,
                },
                &profile,
            )
            .unwrap();
        core.session_meta
            .set_privacy_level(&session_id, "standard")
            .unwrap();
        let authorized = core
            .notebook_capture_store
            .authorize_async_transcription(&run.session_id, 1, Some("en"))
            .unwrap();
        core.ensure_post_stop_async_task_for_run(&authorized)
            .unwrap();
        let enqueued = core
            .notebook_capture_store
            .get_run(&run.id)
            .unwrap()
            .unwrap();
        let task_id = enqueued.async_task_id.clone().unwrap();

        core.shutdown().unwrap();
        std::thread::sleep(std::time::Duration::from_millis(50));
        let token = vt_model::Token {
            text: "purge race transcript".into(),
            start_ms: 0,
            end_ms: 500,
            is_final: true,
            language: "en".into(),
            confidence: 1.0,
            translation_status: vt_model::TranslationStatus::None,
            speaker: None,
        };
        let result_json = serde_json::json!({
            "session_id": session_id,
            "token_count": 1,
            "full_text": "purge race transcript",
            "duration_ms": 500,
        })
        .to_string();
        claim_current_post_stop_provider(&core.notebook_capture_store, &session_id);
        let receipt = core
            .notebook_capture_store
            .commit_async_provider_success(&session_id, &task_id, &[token], &result_json)
            .unwrap();
        core.runtime
            .block_on(
                core.task_queue
                    .complete_from_durable_provider_receipt(&task_id),
            )
            .unwrap();

        let core = Arc::new(core);
        let provider_calls = Arc::new(AtomicUsize::new(0));
        let loro_calls = Arc::new(AtomicUsize::new(0));
        let callback_calls = Arc::new(AtomicUsize::new(0));
        let (fts_started_tx, fts_started_rx) = std::sync::mpsc::channel();
        let release_fts = Arc::new((StdMutex::new(false), std::sync::Condvar::new()));
        let recovery_core = Arc::clone(&core);
        let recovery_receipt = receipt.clone();
        let recovery_loro_calls = Arc::clone(&loro_calls);
        let recovery_callback_calls = Arc::clone(&callback_calls);
        let recovery_release_fts = Arc::clone(&release_fts);
        let db_path = temp.path().join("zulangue.db");
        let recovery = core.runtime.spawn(async move {
            crate::task_worker::recover_completed_provider_receipt_with(
                recovery_core.task_queue.as_ref(),
                &recovery_core.notebook_capture_store,
                &recovery_core.session_task_registry,
                &recovery_receipt,
                |receipt| {
                    recovery_core
                        .notebook_capture_store
                        .mark_async_task_terminal_for_session(
                            &receipt.session_id,
                            &receipt.task_id,
                            true,
                        )
                        .map(|_| ())
                        .map_err(|error| error.to_string())
                },
                |receipt| {
                    fts_started_tx.send(()).unwrap();
                    let (released, changed) = &*recovery_release_fts;
                    let mut released = released.lock().unwrap();
                    while !*released {
                        released = changed.wait(released).unwrap();
                    }
                    crate::transcribe_api::project_transcribe_search_receipt(&db_path, receipt)
                },
                |_| {
                    recovery_loro_calls.fetch_add(1, Ordering::SeqCst);
                    Ok(())
                },
                |_| {
                    recovery_callback_calls.fetch_add(1, Ordering::SeqCst);
                },
            )
            .await
        });
        fts_started_rx
            .recv_timeout(std::time::Duration::from_secs(2))
            .unwrap();
        assert_eq!(core.session_task_registry.active_count(&session_id), 1);

        let purge_core = Arc::clone(&core);
        let purge_session_id = session_id.clone();
        let (purge_done_tx, purge_done_rx) = std::sync::mpsc::channel();
        let purge = std::thread::spawn(move || {
            let result = purge_core.purge_session_forever(&purge_session_id);
            purge_done_tx.send(result).unwrap();
        });
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
        while !core.session_task_registry.is_blocked(&session_id)
            && std::time::Instant::now() < deadline
        {
            std::thread::yield_now();
        }
        assert!(core.session_task_registry.is_blocked(&session_id));
        assert!(matches!(
            purge_done_rx.try_recv(),
            Err(std::sync::mpsc::TryRecvError::Empty)
        ));

        {
            let (released, changed) = &*release_fts;
            *released.lock().unwrap() = true;
            changed.notify_all();
        }
        let recovery_outcome = core.runtime.block_on(recovery).unwrap().unwrap();
        assert_eq!(
            recovery_outcome,
            crate::task_worker::CompletedProviderReceiptRecoveryOutcome::Cancelled
        );
        purge_done_rx
            .recv_timeout(std::time::Duration::from_secs(2))
            .unwrap()
            .unwrap();
        purge.join().unwrap();

        assert_eq!(provider_calls.load(Ordering::SeqCst), 0);
        assert_eq!(loro_calls.load(Ordering::SeqCst), 0);
        assert_eq!(callback_calls.load(Ordering::SeqCst), 0);
        assert!(core
            .runtime
            .block_on(core.task_queue.get_task(&task_id))
            .is_err());
        assert!(core
            .notebook_capture_store
            .get_run(&run.id)
            .unwrap()
            .is_none());
        assert!(core
            .notebook_capture_store
            .get_async_provider_receipt(&session_id, &task_id)
            .unwrap()
            .is_none());
        assert!(core
            .search_store
            .search("purge race", 10)
            .unwrap()
            .is_empty());
        assert!(core.session_store.get_session(&session_id).is_err());
    }

    #[test]
    fn retry_projection_waits_for_capture_ownership_and_rejects_frozen_purge() {
        let (_temp, core, _notebook_id, run_id, doc_id) = projected_core_fixture();
        core.notebook_capture_store
            .set_projection_state(&run_id, ProjectionState::Pending, ProjectionState::Failed)
            .unwrap();
        let core = Arc::new(core);
        let ownership_guard = core.capture_ownership_gate.lock().unwrap();
        let (attempting_tx, attempting_rx) = std::sync::mpsc::channel();
        let retry_core = Arc::clone(&core);
        let retry = std::thread::spawn(move || {
            attempting_tx.send(()).unwrap();
            retry_core.retry_notebook_capture_projection("session-a".into())
        });
        attempting_rx.recv().unwrap();

        // This direct durable-store call models recovery discovering a purge
        // tombstone while another process still has stale retry intent. The
        // public retry must be waiting on the same ownership gate as purge.
        core.notebook_capture_store
            .begin_session_purge("session-a")
            .unwrap();
        drop(ownership_guard);

        let error = retry.join().unwrap().unwrap_err();
        assert!(error.to_string().contains("being permanently deleted"));
        let run = core
            .notebook_capture_store
            .get_run(&run_id)
            .unwrap()
            .unwrap();
        assert_eq!(run.projection_state, ProjectionState::Failed);
        assert!(!core.editor_bridge.is_session_open(&doc_id));
    }

    #[test]
    fn async_projection_retry_uses_persisted_tokens_without_reopening_provider_receipt() {
        let temp = tempfile::tempdir().unwrap();
        let core = ZulangueCore::new_for_test(temp.path().to_string_lossy().to_string()).unwrap();
        let notebook = core
            .create_notebook(Some("Async projection retry".into()))
            .unwrap();
        let current = core
            .notebook_capture_store
            .get_or_create_profile(&notebook.id)
            .unwrap();
        let profile = core
            .notebook_capture_store
            .update_profile(
                &notebook.id,
                current.revision,
                &NotebookCaptureProfileUpdate {
                    remote_realtime_enabled: false,
                    capture_mode: CaptureMode::TranscriptionOnly,
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
        let run = core
            .notebook_capture_store
            .create_run(
                &vt_store::NewNotebookCaptureRun {
                    id: "run-async-local-retry".into(),
                    notebook_id: notebook.id.clone(),
                    session_id: "session-async-local-retry".into(),
                    remote_health: RemoteHealth::Off,
                    audio_journal_path: "capture-async-local-retry.journal".into(),
                    audio_key_ref: "capture-key-async-local-retry".into(),
                    sample_rate: 16_000,
                    channels: 1,
                },
                &profile,
            )
            .unwrap();
        core.notebook_capture_store
            .transition_capture(&run.id, CaptureState::Recording, CaptureState::Draining)
            .unwrap();
        core.notebook_capture_store
            .finalize_audio(
                &run.id,
                &temp
                    .path()
                    .join("capture-async-local-retry.chunk.00000.enc")
                    .to_string_lossy(),
                16_000,
            )
            .unwrap();
        core.notebook_capture_store
            .transition_capture(&run.id, CaptureState::Draining, CaptureState::Completed)
            .unwrap();
        core.notebook_capture_store
            .authorize_async_transcription(&run.session_id, 1, Some("en"))
            .unwrap();
        let task_id = "provider-task-once";
        let digest = "f".repeat(64);
        core.notebook_capture_store
            .reserve_async_task(&run.id, task_id, &digest)
            .unwrap();
        core.notebook_capture_store
            .mark_async_task_enqueued(&run.id, task_id)
            .unwrap();
        let token = vt_model::Token {
            text: "provider result".into(),
            start_ms: 0,
            end_ms: 500,
            is_final: true,
            language: "en".into(),
            confidence: 0.99,
            translation_status: vt_model::TranslationStatus::Original,
            speaker: None,
        };
        let result_json = serde_json::json!({
            "session_id": run.session_id,
            "token_count": 1,
            "full_text": "provider result",
            "duration_ms": 500,
        })
        .to_string();
        claim_current_post_stop_provider(&core.notebook_capture_store, &run.session_id);
        let provider_receipt = core
            .notebook_capture_store
            .commit_async_provider_success(&run.session_id, task_id, &[token], &result_json)
            .unwrap();
        let provider_complete = core
            .notebook_capture_store
            .mark_async_task_terminal_for_session(&run.session_id, task_id, true)
            .unwrap();
        assert_eq!(
            provider_complete.async_task_state,
            AsyncTaskState::Completed
        );
        assert_eq!(
            provider_complete.async_projection_state,
            AsyncProjectionState::Pending
        );

        let first_error = core
            .retry_notebook_async_projection(run.session_id.clone())
            .unwrap_err();
        assert!(first_error
            .to_string()
            .contains("has no projection source or Notebook link"));
        let locally_failed = core
            .notebook_capture_store
            .get_run(&run.id)
            .unwrap()
            .unwrap();
        assert_eq!(locally_failed.async_task_state, AsyncTaskState::Completed);
        assert_eq!(
            locally_failed.async_projection_state,
            AsyncProjectionState::Failed
        );
        assert_eq!(locally_failed.async_task_id.as_deref(), Some(task_id));
        assert_eq!(
            locally_failed.async_task_payload_sha256.as_deref(),
            Some(digest.as_str())
        );

        core.notebook_store
            .ensure_session_projection(
                &notebook.id,
                vt_store::BuiltinNotebookTab::AsyncTranscript,
                &run.session_id,
                Some("Async result"),
            )
            .unwrap();
        let ready = core
            .retry_notebook_async_projection(run.session_id.clone())
            .unwrap();
        assert_eq!(
            ready.post_stop_async_projection_state,
            FfiNotebookAsyncProjectionState::Ready
        );
        let after_retry = core
            .notebook_capture_store
            .get_run(&run.id)
            .unwrap()
            .unwrap();
        assert_eq!(after_retry.async_task_state, AsyncTaskState::Completed);
        assert_eq!(
            after_retry.async_projection_state,
            AsyncProjectionState::Ready
        );
        assert_eq!(after_retry.async_task_id.as_deref(), Some(task_id));
        assert_eq!(
            after_retry.async_task_payload_sha256.as_deref(),
            Some(digest.as_str()),
            "local retry must not reserve or dispatch a second provider task"
        );
        assert_eq!(
            core.notebook_capture_store
                .get_async_provider_receipt(&run.session_id, task_id)
                .unwrap()
                .unwrap(),
            provider_receipt,
            "local projection retry must preserve the one immutable provider receipt"
        );
    }

    #[test]
    fn retry_projection_rolls_back_loro_when_purge_tombstone_appears_before_commit() {
        let (_temp, core, _notebook_id, run_id, doc_id) = projected_core_fixture();
        core.notebook_capture_store
            .set_projection_state(&run_id, ProjectionState::Pending, ProjectionState::Failed)
            .unwrap();
        let core = Arc::new(core);

        // Pause after the durable Projecting transition but before any Loro
        // mutation. This makes the final-commit race deterministic without a
        // timing-only sleep or a production test hook.
        let mutation_guard = crate::editor_api::editor_document_mutation_guard();
        let retry_core = Arc::clone(&core);
        let retry = std::thread::spawn(move || {
            retry_core.retry_notebook_capture_projection("session-a".into())
        });
        for _ in 0..1_000 {
            if core
                .notebook_capture_store
                .get_run(&run_id)
                .unwrap()
                .is_some_and(|run| run.projection_state == ProjectionState::Projecting)
            {
                break;
            }
            std::thread::yield_now();
        }
        assert_eq!(
            core.notebook_capture_store
                .get_run(&run_id)
                .unwrap()
                .unwrap()
                .projection_state,
            ProjectionState::Projecting
        );
        core.notebook_capture_store
            .begin_session_purge("session-a")
            .unwrap();
        drop(mutation_guard);

        let error = retry.join().unwrap().unwrap_err();
        assert!(error.to_string().contains("being permanently deleted"));
        assert_eq!(
            core.notebook_capture_store
                .get_run(&run_id)
                .unwrap()
                .unwrap()
                .projection_state,
            ProjectionState::Failed
        );
        crate::editor_api::open_editor_session_strict(&core.data_dir, &core.editor_bridge, &doc_id)
            .unwrap();
        let content = core.editor_bridge.get_content(&doc_id).unwrap();
        assert!(!content.contains("hello"));
        assert!(!content.contains("session-a"));
    }

    #[test]
    fn purge_removes_only_the_deleted_sessions_transcription_task() {
        let (_temp, core, _notebook_id, _run_id, _projection_doc_id) = projected_core_fixture();
        let removed_session_task = core
            .runtime
            .block_on(core.task_queue.enqueue(TaskPayload::Transcribe {
                session_id: "session-a".into(),
                language_hint: Some("en".into()),
                remote_authorization: Some(RemoteTaskAuthorization::soniox_post_recording_at(1)),
            }))
            .unwrap();
        let retained_task = core
            .runtime
            .block_on(core.task_queue.enqueue(TaskPayload::Transcribe {
                session_id: "session-b".into(),
                language_hint: Some("zh".into()),
                remote_authorization: Some(RemoteTaskAuthorization::soniox_post_recording_at(1)),
            }))
            .unwrap();

        // Model this session's explicit post-stop transcription being claimed
        // before Delete Forever. Purge must cancel that owner without touching
        // another session's independently authorized transcription.
        let in_flight = core
            .session_task_registry
            .register(&removed_session_task)
            .unwrap();
        let cancelled = in_flight.cancellation_token();
        let core = Arc::new(core);
        let purge_core = Arc::clone(&core);
        let (purge_tx, purge_rx) = std::sync::mpsc::channel();
        let purge = std::thread::spawn(move || {
            let result = purge_core.purge_session_forever("session-a");
            purge_tx.send(result).unwrap();
        });
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
        let mut purge_result = None;
        while !cancelled.is_cancelled() && std::time::Instant::now() < deadline {
            match purge_rx.try_recv() {
                Ok(result) => {
                    purge_result = Some(result);
                    break;
                }
                Err(std::sync::mpsc::TryRecvError::Empty) => std::thread::yield_now(),
                Err(std::sync::mpsc::TryRecvError::Disconnected) => break,
            }
        }
        let was_cancelled = cancelled.is_cancelled();
        let completed_before_cancellation = purge_result.is_some();
        drop(in_flight);
        let purge_result = match purge_result {
            Some(result) => result,
            None => purge_rx
                .recv_timeout(std::time::Duration::from_secs(2))
                .unwrap(),
        };
        purge_result.unwrap();
        purge.join().unwrap();
        assert!(was_cancelled);
        assert!(!completed_before_cancellation);

        assert!(matches!(
            core.runtime
                .block_on(core.task_queue.get_task(&removed_session_task)),
            Err(vt_pipeline::TaskQueueError::NotFound(_))
        ));
        assert!(core
            .runtime
            .block_on(core.task_queue.get_task(&retained_task))
            .is_ok());
    }
}
