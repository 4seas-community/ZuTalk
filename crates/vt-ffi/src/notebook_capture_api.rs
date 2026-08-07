//! Single-owner Notebook capture FFI.
//!
//! Rust owns capture state, encrypted audio durability, ordered Soniox v5
//! aggregation, and the final Loro projection. Swift supplies one microphone
//! stream and renders callbacks; it never owns a second capture state machine.

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::io::Read;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex as StdMutex};

use sha2::{Digest, Sha256};
use vt_crypto::SessionKey;
use vt_pipeline::{
    CaptureAudioJournal, RecordingConfig, RecordingResult, RemoteTaskAuthorization, TaskPayload,
    TaskPriority,
};
#[cfg(test)]
use vt_store::notebook_capture_store::AsyncSearchProjectionState;
use vt_store::notebook_capture_store::{
    canonical_language, capture_mode_for_selection, legacy_capture_language_pair,
    AsyncProjectionState, AsyncTaskState, CaptureMode, CaptureProviderRole, CaptureState,
    NewRealtimeTranslationInboxItem, NewRealtimeUtterance, NotebookCaptureHistoryRun,
    NotebookCaptureProfile, NotebookCaptureProfileUpdate, NotebookCaptureRun, NotebookCaptureStore,
    NotebookProjectionMutation, ProjectionState, ProviderFailure, RealtimeLoroProjection,
    RealtimeLoroProjectionAck, RealtimeLoroProjectionLoad, RealtimeTranslationInboxItem,
    RealtimeTranslationInboxKey, RealtimeTranslationLaneUpdate, RealtimeUtterance,
    RealtimeUtteranceVariant, RemoteHealth, SessionPurgeJob, SessionPurgePlan, UtteranceAlignment,
    UtteranceCompletion, UtteranceLane, UtteranceVariantRole, UtteranceVariantState,
};
use vt_store::transcript_projection::{MachineBlockWrite, TranscriptProjection, UtteranceBlock};
#[cfg(test)]
use vt_store::ContextPackDocumentSource;
use vt_store::{
    ContextCompilation, ContextContentKind, ContextOmissionReason, ContextPackDocument,
    ContextPackRecord, ContextPackScope, ContextPackSourceRecord, ContextPackStore, ContextReceipt,
    ContextSourceFormat, NewContextSource, CONTEXT_PACK_DOCUMENT_MAX_BYTES,
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
    AsyncFileApi,
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
    /// Session Final watermark that makes this lane safe to show from Loro.
    /// Zero means the lane is still SQLite-only.
    pub projection_revision: u64,
    /// Lane-local revision of the user-visible override.
    pub edit_revision: u64,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiNotebookCaptureUtterance {
    pub id: String,
    pub session_id: String,
    pub sequence: u64,
    pub revision: u64,
    pub session_speaker_id: Option<String>,
    pub source_language: String,
    /// Display-only hint for a live speculative tail whose durable source
    /// language is still `und`. Carries the unambiguous pending provider
    /// language so clients can place the text in its lane immediately.
    /// Never persisted; always absent on durable rows.
    pub provisional_source_language: Option<String>,
    pub source_text: String,
    pub source_start_ms: Option<u64>,
    pub source_end_ms: Option<u64>,
    pub translated_language: Option<String>,
    pub translated_text: Option<String>,
    pub completion: String,
    pub alignment: String,
    /// Session Final watermark that makes the source lane safe to show from
    /// Loro. Zero means the source is still SQLite-only.
    pub source_projection_revision: u64,
    /// Lane-local revision of the source's user-visible override.
    pub source_edit_revision: u64,
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
    /// Highest session Final watermark whose receipt-bearing Loro snapshot is
    /// durably fsynced and acknowledged.
    pub realtime_loro_applied_revision: u64,
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
    /// Process-local provider lag. Present only on live progress callbacks;
    /// durable snapshots leave it absent.
    pub realtime_lag_ms: Option<u64>,
    pub projection_state: FfiNotebookProjectionState,
    /// Highest session Final watermark whose receipt-bearing Loro snapshot is
    /// durably fsynced and acknowledged.
    pub realtime_loro_applied_revision: u64,
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
    /// Auxiliary translation facts as time-anchored cues, independent of any
    /// canonical row binding. On a full snapshot this replaces the client's
    /// cue view with every present cue of the session; on a delta it carries
    /// only cues changed by this event, applied by
    /// `(group_epoch, provider_sequence, target_language)` upsert, where a
    /// `withdrawn` cue removes the entry. Coalescing gaps heal through the
    /// same full-snapshot rebuild as `utterances`.
    pub translation_cues: Vec<FfiNotebookCaptureTranslationCue>,
    /// Current health of every lane in the running stream group, carried on
    /// every event of a live capture — state, not an edge. A lane fails once
    /// per session, and the single-slot callback mailbox coalesces, so an
    /// edge-triggered payload would be silently dropped exactly when it
    /// mattered most. Empty means there is no running group.
    pub lane_health: Vec<FfiNotebookCaptureLaneHealth>,
    pub context_receipt: Option<FfiNotebookCaptureContextReceipt>,
    pub provider_error_type: Option<String>,
    pub provider_request_id: Option<String>,
}

/// Process-local health of one stream lane inside the active capture group.
///
/// Operator chrome only: the audience canvas never explains a lane, it just
/// stops showing the waiting ellipsis for a lane that will never fill again.
/// Absent on durable snapshots — after a process restart the old group is
/// gone and lane health starts over with the next stream group.
#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiNotebookCaptureLaneHealth {
    /// `None` is the canonical transcription lane.
    pub target_language: Option<String>,
    /// "live" | "connecting" | "failed"
    pub state: String,
    /// Cross-stream correlation epoch currently owned by this lane.
    pub group_epoch: u64,
    /// Provider-confirmed capture-timeline progress for finalized audio.
    pub final_audio_proc_ms: Option<u64>,
    /// Provider-confirmed capture-timeline progress for all processed audio.
    pub total_audio_proc_ms: Option<u64>,
    /// Provider processing plus local queued-audio lag for this lane.
    pub lag_ms: Option<u64>,
    /// True when this lane was stopped because local PCM could no longer be
    /// appended contiguously. It must not be resumed on the same timeline.
    pub input_discontinuous: bool,
}

/// One auxiliary translation segment, anchored to the capture-wide audio
/// timeline it inherited from its own source tokens.
///
/// A cue never references a canonical utterance: which row's words it
/// translates is a read-time question answered by time overlap, not a stored
/// relationship. This is what lets a translation be visible the moment the
/// provider produces it instead of waiting for the slower canonical lane.
#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiNotebookCaptureTranslationCue {
    pub target_language: String,
    pub group_epoch: u64,
    pub provider_sequence: u64,
    pub source_language: String,
    /// Capture-timeline range of the segment's source tokens. Translation
    /// tokens carry no provider timestamps, so this inherited range is the
    /// cue's only — and deliberately segment-grained — time anchor.
    pub source_start_ms: Option<u64>,
    pub source_end_ms: Option<u64>,
    pub text: String,
    /// "partial" while the segment is still being revised, "complete" once
    /// the provider finalized it.
    pub completion: String,
    /// A withdrawn cue is a removal instruction: the provider retracted the
    /// speculative segment and nothing replaces it.
    pub withdrawn: bool,
    pub revision: u64,
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
    /// Replace-in-full, bounded target-language tail. Unlike durable capture
    /// event deltas, this state is safe to coalesce at both callback hops: the
    /// newest preview always describes every language the live canvas needs.
    pub translation_cues: Vec<FfiNotebookCaptureTranslationCue>,
    /// Replace-in-full health for the same live frame. A skipped transition is
    /// harmless because the next frame repeats the complete lane state.
    pub lane_health: Vec<FfiNotebookCaptureLaneHealth>,
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
                vt_stt::PostStopExecution::AsyncFileApi => {
                    FfiNotebookPostStopExecution::AsyncFileApi
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
                projection_revision: variant.projection_revision,
                edit_revision: variant.edit_revision,
            })
            .collect();
        Self {
            id: value.id,
            session_id: value.session_id,
            sequence: value.sequence,
            revision: value.revision,
            session_speaker_id: value.session_speaker_id,
            source_language: value.source_language,
            provisional_source_language: None,
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
            source_projection_revision: value.source_projection_revision,
            source_edit_revision: value.source_edit_revision,
            language_variants,
        }
    }
}

fn ffi_live_preview(value: AssembledRealtimeUtterance) -> FfiNotebookCaptureUtterance {
    let provisional_source_language = value.provisional_source_language;
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
        provisional_source_language,
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
        source_projection_revision: 0,
        source_edit_revision: 0,
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
            realtime_loro_applied_revision: value.realtime_loro_applied_revision,
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
        realtime_lag_ms: None,
        projection_state: run.projection_state.into(),
        realtime_loro_applied_revision: run.realtime_loro_applied_revision,
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
        // Cues are attached at the three re-materialization points (delta
        // emission, refresh, full snapshot), not here: most events carry none
        // and the builder has no store access.
        translation_cues: Vec::new(),
        lane_health: Vec::new(),
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
    persisted_translation_language: Option<String>,
    revision: Option<u64>,
    complete: bool,
    source_dirty: bool,
    translation_dirty: bool,
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
            persisted_translation_language: None,
            revision: None,
            complete: false,
            source_dirty: false,
            translation_dirty: false,
        }
    }

    fn begin_response_revision(&mut self) {
        let source_changed = self.source.begin_response_revision()
            | self.pending_source_start_ms.take().is_some()
            | self.pending_source_end_ms.take().is_some();
        self.pending_provider_speaker.take();
        self.pending_source_language_hint.take();
        self.pending_provider_speaker_hint.take();
        let translation_changed = self.translated.begin_response_revision();
        self.pending_provider_speaker_ambiguous = false;
        self.source_dirty |= source_changed;
        // Inline translation pairing depends on the canonical source
        // identity. If that source tail is replaced, re-evaluate the inline
        // lane even when its own provider tokens were already committed.
        // External auxiliary lanes are not stored in this assembler and are
        // therefore never cleared through this dependency.
        self.translation_dirty |=
            translation_changed || (source_changed && !self.translated.is_empty());
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
    /// Unambiguous pending provider language while the durable source language
    /// is still `und`. Presentation-only; never persisted.
    provisional_source_language: Option<String>,
    source_dirty: bool,
    translation_dirty: bool,
    translation_completion: Option<UtteranceCompletion>,
    translation_clear_language: Option<String>,
    remove_partial: bool,
    provider_speaker: Option<String>,
    expected_revision: Option<u64>,
}

#[derive(Debug, Default)]
struct PersistedCaptureChanges {
    utterances: Vec<RealtimeUtterance>,
    removed_sequences: Vec<u64>,
    requires_full_snapshot: bool,
    /// Auxiliary cue facts changed by this batch, including withdrawal
    /// tombstones. Emitted on the durable delta channel alongside utterances.
    translation_cues: Vec<FfiNotebookCaptureTranslationCue>,
}

impl std::ops::Deref for PersistedCaptureChanges {
    type Target = Vec<RealtimeUtterance>;

    fn deref(&self) -> &Self::Target {
        &self.utterances
    }
}

impl std::ops::DerefMut for PersistedCaptureChanges {
    fn deref_mut(&mut self) -> &mut Self::Target {
        &mut self.utterances
    }
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

/// Bounded round-robin staging in front of the collector.
///
/// Stream forwarders still share one Tokio channel, but the collector drains
/// that bounded FIFO into per-lane queues before choosing the next event. A
/// noisy source can therefore occupy backpressure capacity without receiving
/// a second turn while a sibling already has work ready.
struct FairTaggedEventQueue {
    pending: Vec<std::collections::VecDeque<TaggedStreamEvent>>,
    pending_count: usize,
    pending_limit: usize,
    next_lane: usize,
}

impl FairTaggedEventQueue {
    fn new(lane_count: usize, pending_limit: usize) -> Self {
        Self {
            pending: (0..lane_count)
                .map(|_| std::collections::VecDeque::new())
                .collect(),
            pending_count: 0,
            pending_limit: pending_limit.max(1),
            next_lane: 0,
        }
    }

    fn enqueue(&mut self, tagged: TaggedStreamEvent) -> Result<(), TaggedStreamEvent> {
        let Some(queue) = self.pending.get_mut(tagged.lane_index) else {
            return Err(tagged);
        };
        queue.push_back(tagged);
        self.pending_count += 1;
        Ok(())
    }

    fn pop_round_robin(&mut self) -> Option<TaggedStreamEvent> {
        if self.pending_count == 0 || self.pending.is_empty() {
            return None;
        }
        for offset in 0..self.pending.len() {
            let lane_index = (self.next_lane + offset) % self.pending.len();
            if let Some(tagged) = self.pending[lane_index].pop_front() {
                self.pending_count -= 1;
                self.next_lane = (lane_index + 1) % self.pending.len();
                return Some(tagged);
            }
        }
        debug_assert_eq!(self.pending_count, 0);
        None
    }

    async fn recv(
        &mut self,
        receiver: &mut tokio::sync::mpsc::Receiver<TaggedStreamEvent>,
        discontinuities: &mut tokio::sync::mpsc::UnboundedReceiver<TaggedStreamEvent>,
    ) -> Option<TaggedStreamEvent> {
        loop {
            while self.pending_count < self.pending_limit {
                let next = discontinuities
                    .try_recv()
                    .ok()
                    .or_else(|| receiver.try_recv().ok());
                let Some(tagged) = next else {
                    break;
                };
                if let Err(invalid) = self.enqueue(tagged) {
                    return Some(invalid);
                }
            }
            if let Some(tagged) = self.pop_round_robin() {
                return Some(tagged);
            }
            let tagged = tokio::select! {
                biased;
                tagged = discontinuities.recv(), if !discontinuities.is_closed() => tagged,
                tagged = receiver.recv(), if !receiver.is_closed() => tagged,
                else => None,
            }?;
            if let Err(invalid) = self.enqueue(tagged) {
                return Some(invalid);
            }
        }
    }
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
    /// Terminal: this lane's stream runtime exhausted its own retries and
    /// exited. A failed auxiliary lane stays in the group as a tombstone —
    /// its column stops updating — while every sibling keeps running.
    failed: bool,
    input_discontinuous: bool,
    final_audio_proc_ms: Option<u64>,
    total_audio_proc_ms: Option<u64>,
    lag_ms: Option<u64>,
    provider_accepted_configuration: bool,
    disconnected_at_frame: Option<u64>,
}

const REALTIME_CONTINUITY_WINDOW_MS: u64 = 15_000;

#[derive(Debug, Clone)]
struct CanonicalUtteranceMatch {
    group_epoch: u64,
    utterance: RealtimeUtterance,
}

#[derive(Debug, Clone)]
struct PendingTranslationVariant {
    session_id: String,
    group_epoch: u64,
    source_sequence: u64,
    source_language: String,
    source_text: String,
    source_start_ms: Option<u64>,
    source_end_ms: Option<u64>,
    target_language: String,
    completion: UtteranceCompletion,
    /// One-shot latch for the reverse-divergence WARN: a Final auxiliary
    /// segment whose best row is already owned by a sibling segment stays
    /// durably pending and is re-examined on every flush, so without this
    /// flag the observation log would drown in repeats of one fact.
    reverse_conflict_warned: bool,
}

fn pending_translation_from_inbox(
    item: &RealtimeTranslationInboxItem,
) -> Option<PendingTranslationVariant> {
    if item.withdrawn || item.bound_sequence.is_some() {
        return None;
    }
    item.translated_text.as_ref()?;
    let completion = item.completion?;
    Some(PendingTranslationVariant {
        session_id: item.key.session_id.clone(),
        group_epoch: item.key.group_epoch,
        source_sequence: item.key.provider_sequence,
        source_language: normalize_language(&item.source_language),
        source_text: item.source_text.clone(),
        source_start_ms: item.source_start_ms,
        source_end_ms: item.source_end_ms,
        target_language: normalize_language(&item.key.target_language),
        completion,
        reverse_conflict_warned: false,
    })
}

/// Keep enough finalized alignment history for late provider revisions without
/// retaining an entire lecture in the in-memory cross-stream indexes.
const STREAM_AGGREGATION_RECENT_UTTERANCE_WINDOW: usize = 128;

/// Minimum spacing between segmentation-barrier broadcasts. Provider `<end>`
/// markers arrive at natural speech pauses (seconds apart); this only guards
/// against a pathological burst flooding the auxiliary control channels.
const SEGMENT_BOUNDARY_BROADCAST_MIN_INTERVAL: std::time::Duration =
    std::time::Duration::from_millis(750);

/// One auxiliary provider segment overlapping a second canonical row by at
/// least this much means provider endpointing diverged across sibling streams
/// and whole-segment binding is degrading into cross-row content.
const CROSS_ROW_OVERLAP_WARN_PER_MILLE: u16 = 500;

/// The canonical stream is the segmentation authority. Its semantic endpoint
/// closes the current row, so every connected auxiliary stream is told to
/// finalize at the same audio position; auxiliary endpoint detection stays
/// enabled purely as a fallback, and a finalize racing a natural `<end>`
/// merely finalizes an empty tail. Best-effort by design: a full or closed
/// control channel skips the lane instead of stalling the event loop, because
/// the next canonical endpoint repeats the barrier.
fn broadcast_segment_boundary_to_auxiliary_lanes(
    lanes: &[StreamAggregationLane],
    lane_controls: &[Option<tokio::sync::mpsc::Sender<SttStreamControl>>],
    last_broadcast: &mut Option<tokio::time::Instant>,
) {
    let now = tokio::time::Instant::now();
    if last_broadcast.is_some_and(|previous| {
        now.duration_since(previous) < SEGMENT_BOUNDARY_BROADCAST_MIN_INTERVAL
    }) {
        return;
    }
    let mut broadcast = false;
    for (lane, control) in lanes.iter().zip(lane_controls.iter()) {
        let Some(control) = control else { continue };
        if lane.descriptor.canonical || !lane.connected || lane.awaiting_reconnect {
            // A disconnected or reconnecting lane would apply the finalize to
            // a stale audio position once its socket returns; skipping keeps
            // the barrier tied to live streams only.
            continue;
        }
        match control.try_send(SttStreamControl::Finalize) {
            Ok(()) => broadcast = true,
            Err(error) => {
                tracing::debug!(
                    target_language = lane.descriptor.target_language.as_deref().unwrap_or("und"),
                    %error,
                    "segmentation barrier skipped an auxiliary lane"
                );
            }
        }
    }
    if broadcast {
        *last_broadcast = Some(now);
    }
}

#[allow(clippy::too_many_arguments)]
async fn collect_stream_events(
    store: NotebookCaptureStore,
    context_store: ContextPackStore,
    run_id: String,
    profile: NotebookCaptureProfile,
    context_digest: Option<String>,
    lane_descriptors: Vec<RemoteStreamLane>,
    lane_controls: Vec<Option<tokio::sync::mpsc::Sender<SttStreamControl>>>,
    mut event_rx: tokio::sync::mpsc::Receiver<TaggedStreamEvent>,
    mut discontinuity_rx: tokio::sync::mpsc::UnboundedReceiver<TaggedStreamEvent>,
    group_cancel: tokio_util::sync::CancellationToken,
    captured_frames: Arc<AtomicU64>,
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
                failed: false,
                input_discontinuous: false,
                final_audio_proc_ms: None,
                total_audio_proc_ms: None,
                lag_ms: None,
                provider_accepted_configuration: false,
                disconnected_at_frame: None,
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
    let mut live_translation_cues =
        std::collections::HashMap::<LiveTranslationCueKey, FfiNotebookCaptureTranslationCue>::new();
    for item in store.list_translation_inbox(&session_id).map_err(|error| {
        local_persistence_failure("rehydrate durable auxiliary translation inbox", error)
    })? {
        reconcile_live_translation_cues(
            &mut live_translation_cues,
            std::slice::from_ref(&translation_cue_from_inbox_item(&item)),
        );
        let stored_lane_index =
            usize::try_from(item.key.lane_index).map_err(|_| ProviderFailure {
                error_type: "invalid_stream_lane".to_string(),
                request_id: None,
            })?;
        let stored_target = lanes
            .get(stored_lane_index)
            .and_then(|lane| lane.descriptor.target_language.as_deref())
            .map(normalize_language);
        let lane_index = if stored_target.as_deref() == Some(item.key.target_language.as_str()) {
            stored_lane_index
        } else {
            let matching = lanes
                .iter()
                .enumerate()
                .filter(|(_, lane)| {
                    lane.descriptor
                        .target_language
                        .as_deref()
                        .map(normalize_language)
                        .as_deref()
                        == Some(item.key.target_language.as_str())
                })
                .map(|(index, _)| index)
                .collect::<Vec<_>>();
            let [only] = matching.as_slice() else {
                return Err(ProviderFailure {
                    error_type: "invalid_stream_lane".to_string(),
                    request_id: None,
                });
            };
            *only
        };
        if lanes[lane_index].descriptor.canonical {
            return Err(ProviderFailure {
                error_type: "invalid_stream_lane".to_string(),
                request_id: None,
            });
        }
        let pending_key = (lane_index, item.key.group_epoch, item.key.provider_sequence);
        if let Some(sequence) = item.bound_sequence {
            variant_bindings.insert(pending_key, sequence);
            reverse_variant_bindings.insert(
                (
                    item.key.group_epoch,
                    sequence,
                    item.key.target_language.clone(),
                ),
                pending_key,
            );
        } else if let Some(pending) = pending_translation_from_inbox(&item) {
            pending_variants.insert(pending_key, pending);
        }
    }

    let mut last_boundary_broadcast: Option<tokio::time::Instant> = None;
    let fair_pending_limit = lanes.len().saturating_mul(64).clamp(64, 512);
    let mut fair_events = FairTaggedEventQueue::new(lanes.len(), fair_pending_limit);
    while let Some(tagged) = fair_events.recv(&mut event_rx, &mut discontinuity_rx).await {
        let Some(lane) = lanes.get_mut(tagged.lane_index) else {
            group_cancel.cancel();
            return Err(ProviderFailure {
                error_type: "invalid_stream_lane".to_string(),
                request_id: None,
            });
        };
        if lane.failed && !matches!(&tagged.event, SttStreamEvent::InputDiscontinuity) {
            // A local PCM discontinuity is terminal for this generation. The
            // provider task may still have responses buffered when its child
            // cancellation is observed; those late events cannot resurrect
            // or append to a lane whose timeline is already known to contain
            // a hole.
            continue;
        }
        let provider_accepted_configuration = matches!(
            &tagged.event,
            SttStreamEvent::Tokens(_)
                | SttStreamEvent::AudioProgress { .. }
                | SttStreamEvent::RecoveryStarted { .. }
                | SttStreamEvent::Endpoint
                | SttStreamEvent::Finalized
                | SttStreamEvent::Finished
        );
        if provider_accepted_configuration {
            lane.provider_accepted_configuration = true;
        }
        // A lane that died before ever accepting its configuration can never
        // accept it; letting the tombstone gate the receipt would leave the
        // Context marked un-applied for the whole session even though every
        // surviving connection is using it. At least one real acceptance is
        // still required so a group that never connected claims nothing.
        if !context_applied
            && lanes
                .iter()
                .all(|lane| lane.provider_accepted_configuration || lane.failed)
            && lanes
                .iter()
                .any(|lane| lane.provider_accepted_configuration)
        {
            if let Some(digest) = context_digest.as_deref() {
                match context_store.mark_context_applied(&run_id, digest) {
                    Ok(_) => {
                        context_applied = true;
                        if let Ok(Some(run)) = store.get_run(&run_id) {
                            emit_capture_delta(run, Vec::new(), Vec::new(), &callback);
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
        if lane_index == canonical_lane_index && matches!(&tagged.event, SttStreamEvent::Endpoint) {
            broadcast_segment_boundary_to_auxiliary_lanes(
                &lanes,
                &lane_controls,
                &mut last_boundary_broadcast,
            );
        }
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
        let publishes_lane_state = matches!(
            &tagged.event,
            SttStreamEvent::Connected
                | SttStreamEvent::Reconnecting { .. }
                | SttStreamEvent::InputDiscontinuity
                | SttStreamEvent::Error(_)
        );
        let publishes_lane_progress = matches!(&tagged.event, SttStreamEvent::AudioProgress { .. });
        let persisted = match tagged.event {
            SttStreamEvent::Connected => {
                {
                    let lane = &mut lanes[lane_index];
                    record_provider_connected(
                        &mut lane.provider_session_epoch,
                        &mut lane.awaiting_reconnect,
                    );
                    lane.connected = true;
                    lane.ever_connected = true;
                }
                // A dead auxiliary lane never reconnects; it must not hold
                // the group's health at Connecting forever. Live requires
                // every lane that can still connect to be connected, and an
                // existing tombstone keeps the group honestly Degraded.
                if lanes.iter().all(|lane| lane.failed || lane.connected) {
                    let health = if lanes.iter().any(|lane| lane.failed) {
                        RemoteHealth::Degraded
                    } else {
                        RemoteHealth::Live
                    };
                    let run =
                        store
                            .update_remote_health(&run_id, health, None)
                            .map_err(|error| {
                                local_persistence_failure("persist Soniox live state", error)
                            })?;
                    emit_capture_lane_transition(run, &lanes, &callback);
                }
                PersistedCaptureChanges::default()
            }
            SttStreamEvent::RecoveryStarted { outage_ms } => {
                let lane = &mut lanes[lane_index];
                let reconnected = lane.awaiting_reconnect;
                record_provider_connected(
                    &mut lane.provider_session_epoch,
                    &mut lane.awaiting_reconnect,
                );
                // The durable gap record says "captured audio went
                // untranscribed here". That is only true when the canonical
                // lane — the transcript authority — lost the window; an
                // auxiliary outage costs one translation column a stretch,
                // which its own epoch bump already accounts for, and must
                // not make the session claim audio was lost when the
                // transcription never stopped.
                let writes_gap = lane_index == canonical_lane_index;
                if reconnected && !outage_is_continuous(outage_ms) {
                    let end_frame = captured_frames.load(Ordering::Acquire);
                    if let Some(start_frame) = lane.disconnected_at_frame.take() {
                        if writes_gap && end_frame > start_frame {
                            store
                                .preserve_network_transcript_gap(
                                    &session_id,
                                    start_frame,
                                    end_frame,
                                )
                                .map_err(|error| {
                                    local_persistence_failure(
                                        "preserve network transcript gap",
                                        error,
                                    )
                                })?;
                        }
                    }
                    next_group_epoch = next_group_epoch.saturating_add(1);
                    lane.group_epoch = next_group_epoch;
                } else if reconnected {
                    lane.disconnected_at_frame = None;
                }
                PersistedCaptureChanges::default()
            }
            SttStreamEvent::Reconnecting { .. } => {
                lanes[lane_index]
                    .disconnected_at_frame
                    .get_or_insert_with(|| captured_frames.load(Ordering::Acquire));
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
                // One lane reconnecting no longer fails the group. The old
                // fail-closed rule existed because a replacement session's
                // token timestamps restarted at zero and the row binding
                // could not survive the jump; tokens are now projected onto
                // the capture-wide timeline through connection_origin_ms
                // (sibling agreement measured at p95 ≤ one PCM block), and
                // translation visibility is time-anchored rather than bound.
                // The lane's own runtime replays and re-anchors; a canonical
                // outage degrades every column and reports Connecting, an
                // auxiliary outage degrades one column and the group stays
                // on the air.
                lanes[lane_index].awaiting_reconnect = true;
                let health = if lane_index == canonical_lane_index {
                    RemoteHealth::Connecting
                } else {
                    RemoteHealth::Degraded
                };
                let run = store
                    .update_remote_health(&run_id, health, None)
                    .map_err(|error| {
                        local_persistence_failure("persist Soniox reconnecting state", error)
                    })?;
                emit_capture_lane_transition(run, &lanes, &callback);
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
            SttStreamEvent::AudioProgress {
                final_audio_proc_ms,
                total_audio_proc_ms,
                lag_ms,
            } => {
                lanes[lane_index].final_audio_proc_ms = Some(final_audio_proc_ms);
                lanes[lane_index].total_audio_proc_ms = Some(total_audio_proc_ms);
                lanes[lane_index].lag_ms = Some(lag_ms);
                if lane_index == canonical_lane_index {
                    if let Ok(Some(run)) = store.get_run(&run_id) {
                        emit_realtime_progress(run, lag_ms, &callback);
                    }
                }
                PersistedCaptureChanges::default()
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
            SttStreamEvent::InputDiscontinuity => {
                if lanes[lane_index].failed {
                    PersistedCaptureChanges::default()
                } else {
                    // Audio accepted before the failed block is still a
                    // contiguous prefix and may be finalized. This lane is
                    // then a terminal tombstone; no future PCM is appended to
                    // its old provider timeline.
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
                    lanes[lane_index].failed = true;
                    lanes[lane_index].input_discontinuous = true;
                    let failure = ProviderFailure {
                        error_type: "audio_backpressure".to_string(),
                        request_id: None,
                    };
                    let canonical_failed = lane_index == canonical_lane_index;
                    if canonical_failed {
                        group_cancel.cancel();
                    }
                    let health = if canonical_failed {
                        RemoteHealth::Unavailable
                    } else {
                        RemoteHealth::Degraded
                    };
                    let run = store
                        .update_remote_health(&run_id, health, Some(&failure))
                        .map_err(|error| {
                            local_persistence_failure("persist Soniox input discontinuity", error)
                        })?;
                    emit_capture_lane_transition(run, &lanes, &callback);
                    persisted
                }
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
                lanes[lane_index].failed = true;
                let failure = provider_failure(&error);
                let canonical_failed = lane_index == canonical_lane_index;
                let health = if canonical_failed {
                    if lanes.iter().any(|lane| lane.ever_connected) {
                        RemoteHealth::Degraded
                    } else {
                        RemoteHealth::Unavailable
                    }
                } else {
                    // One translation column went dark; transcription and
                    // every other column keep running. The persisted failure
                    // gives the operator the cause without stopping the room.
                    RemoteHealth::Degraded
                };
                if canonical_failed {
                    // The canonical lane is the transcript authority: without
                    // it there is no timeline to anchor to, so the remote
                    // column set ends as a whole. Local capture remains
                    // authoritative either way.
                    group_cancel.cancel();
                }
                let run = store
                    .update_remote_health(&run_id, health, Some(&failure))
                    .map_err(|error| local_persistence_failure("persist Soniox failure", error))?;
                emit_capture_lane_transition(run, &lanes, &callback);
                persisted
            }
        };

        let publishes_translation_preview = !persisted.translation_cues.is_empty();
        if publishes_translation_preview {
            reconcile_live_translation_cues(
                &mut live_translation_cues,
                &persisted.translation_cues,
            );
        }
        let publishes_live_preview = publishes_canonical_preview
            || publishes_translation_preview
            || publishes_lane_state
            || publishes_lane_progress;
        let live_preview_cues =
            publishes_live_preview.then(|| live_translation_cue_snapshot(&live_translation_cues));

        if persisted.requires_full_snapshot {
            if let Ok(Some(run)) = store.get_run(&run_id) {
                let mut event = event_full_snapshot_from_run(&store, run).map_err(|error| {
                    local_persistence_failure(
                        "load full callback snapshot after partial removal",
                        error,
                    )
                })?;
                event.lane_health = lane_health_snapshot(&lanes);
                callback.send(event);
            }
        } else if !persisted.is_empty() || !persisted.translation_cues.is_empty() {
            // A cue-only batch is a real delta: an auxiliary partial can grow
            // for seconds before the slower canonical lane persists any row.
            if let Ok(Some(run)) = store.get_run(&run_id) {
                emit_capture_delta(
                    run,
                    persisted.utterances,
                    persisted.translation_cues,
                    &callback,
                );
            }
        }
        if let Some(live_preview_cues) = live_preview_cues {
            emit_live_preview(
                &session_id,
                lanes[canonical_lane_index].assembler.live_previews(),
                live_preview_cues,
                lane_health_snapshot(&lanes),
                &callback,
            );
        }
    }
    let unavailable =
        mark_waiting_translation_variants_unavailable(&store, &session_id, &mut canonical_matches)?;
    if !unavailable.is_empty() {
        if let Ok(Some(run)) = store.get_run(&run_id) {
            emit_capture_delta(run, unavailable, Vec::new(), &callback);
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
) -> Result<PersistedCaptureChanges, ProviderFailure> {
    let group_epoch = lanes[lane_index].group_epoch;
    if lanes[lane_index].descriptor.canonical {
        let provider_session_epoch = lanes[lane_index].provider_session_epoch;
        // SQLite is the authoritative machine-fact ledger and therefore keeps
        // both Partial and Complete revisions. The Loro projector below is the
        // stability boundary: it selects finalized lanes independently and
        // never materializes speculative text.
        let mut persisted = persist_assembled_utterances(
            store,
            &mut lanes[lane_index].assembler,
            updates,
            provider_session_epoch,
        )?;
        for sequence in &persisted.removed_sequences {
            forget_canonical_sequence(
                group_epoch,
                *sequence,
                canonical_matches,
                variant_bindings,
                reverse_variant_bindings,
                initialized_variants,
            );
        }
        for utterance in &persisted.utterances {
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
        let durable_bindings = store
            .reconcile_active_translation_inbox(&lanes[canonical_lane_index].assembler.session_id)
            .map_err(|error| {
                local_persistence_failure("reconcile bounded auxiliary translation inbox", error)
            })?;
        for binding in durable_bindings {
            let lane_index =
                usize::try_from(binding.key.lane_index).map_err(|_| ProviderFailure {
                    error_type: "invalid_stream_lane".to_string(),
                    request_id: None,
                })?;
            let pending_key = (
                lane_index,
                binding.key.group_epoch,
                binding.key.provider_sequence,
            );
            variant_bindings.insert(pending_key, binding.canonical_sequence);
            reverse_variant_bindings.insert(
                (
                    binding.key.group_epoch,
                    binding.canonical_sequence,
                    binding.key.target_language.clone(),
                ),
                pending_key,
            );
            pending_variants.retain(|(pending_lane, epoch, provider_sequence), pending| {
                !(*epoch == binding.key.group_epoch
                    && *provider_sequence == binding.key.provider_sequence
                    && normalize_language(&pending.target_language) == binding.key.target_language
                    && (*pending_lane == lane_index
                        || pending.session_id == binding.key.session_id))
            });
            if let Some(updated) = binding.utterance {
                canonical_assembler_record_external_state(
                    &mut lanes[canonical_lane_index].assembler,
                    &updated,
                    &binding.key.target_language,
                );
                canonical_matches.insert(
                    (binding.key.group_epoch, binding.canonical_sequence),
                    CanonicalUtteranceMatch {
                        group_epoch: binding.key.group_epoch,
                        utterance: updated.clone(),
                    },
                );
                persisted.push(updated);
            }
        }
        prune_resolved_stream_aggregation_history(
            selected_languages,
            canonical_matches,
            pending_variants,
            variant_bindings,
            reverse_variant_bindings,
            initialized_variants,
        );
        persisted.utterances = latest_utterance_revisions(persisted.utterances);
        return Ok(persisted);
    }

    let Some(target_language) = lanes[lane_index]
        .descriptor
        .target_language
        .as_deref()
        .map(normalize_language)
    else {
        return Ok(PersistedCaptureChanges::default());
    };
    let mut persisted = Vec::new();
    let mut removed_sequences = Vec::new();
    let mut translation_cues = Vec::new();
    for update in updates {
        let translation_completion = update.translation_completion;
        let translation_clear_language = update
            .translation_clear_language
            .as_deref()
            .map(normalize_language);
        let remove_partial = update.remove_partial;
        let utterance = update.utterance;
        let provider_utterance_id = utterance.id.clone();
        let translated_language = utterance
            .translated_language
            .as_deref()
            .map(normalize_language);
        let is_present = translated_language.as_deref() == Some(target_language.as_str())
            && utterance.translated_text.is_some();
        let is_withdrawn = utterance.translated_text.is_none()
            && (remove_partial
                || translation_clear_language.as_deref() == Some(target_language.as_str()));
        if !is_present && !is_withdrawn {
            continue;
        }
        if is_present && translation_completion.is_none() {
            return Err(ProviderFailure {
                error_type: "invalid_stream_lane".to_string(),
                request_id: None,
            });
        }
        let pending_key = (lane_index, group_epoch, utterance.sequence);
        let persistence = match store.upsert_translation_inbox_item(
            &NewRealtimeTranslationInboxItem {
                key: RealtimeTranslationInboxKey {
                    session_id: utterance.session_id.clone(),
                    lane_index: u64::try_from(lane_index).map_err(|_| ProviderFailure {
                        error_type: "invalid_stream_lane".to_string(),
                        request_id: None,
                    })?,
                    group_epoch,
                    provider_sequence: utterance.sequence,
                    target_language: target_language.clone(),
                },
                source_language: {
                    let normalized = normalize_language(&utterance.source_language);
                    if normalized.is_empty() {
                        "und".to_string()
                    } else {
                        normalized
                    }
                },
                source_text: utterance.source_text,
                source_start_ms: utterance.source_start_ms,
                source_end_ms: utterance.source_end_ms,
                translated_text: is_present.then_some(utterance.translated_text).flatten(),
                completion: if is_present {
                    translation_completion
                } else {
                    None
                },
                withdrawn: is_withdrawn,
            },
        ) {
            Ok(persistence) => persistence,
            Err(vt_store::NotebookCaptureStoreError::Conflict(conflict)) => {
                // A non-withdrawn Complete inbox fact is immutable, so a late
                // provider revision for the same key can never be applied; the
                // durable final translation already owns this lane. Dropping
                // the revision keeps the live capture healthy instead of
                // interrupting every sibling stream.
                tracing::warn!(
                    session_id = %utterance.session_id,
                    group_epoch,
                    sequence = utterance.sequence,
                    target_language = %target_language,
                    conflict = %conflict,
                    "late translation revision rejected by final inbox fact; live capture continues"
                );
                lanes[lane_index].assembler.record_translation_persisted(
                    &provider_utterance_id,
                    Some(target_language.as_str()),
                );
                continue;
            }
            Err(error) => {
                return Err(local_persistence_failure(
                    &format!(
                        "persist auxiliary translation inbox {}:{}:{}:{}",
                        utterance.session_id, group_epoch, utterance.sequence, target_language
                    ),
                    error,
                ));
            }
        };
        lanes[lane_index].assembler.record_translation_persisted(
            &provider_utterance_id,
            (!persistence.item.withdrawn).then_some(target_language.as_str()),
        );
        // Every accepted revision of the durable cue fact — partial growth,
        // finalization, withdrawal — goes out on the delta channel. Binding
        // is not consulted: cue visibility no longer waits for the slower
        // canonical lane to produce a row.
        if persistence.changed {
            translation_cues.push(translation_cue_from_inbox_item(&persistence.item));
        }
        if let Some(sequence) = persistence.removed_bound_sequence {
            removed_sequences.push(sequence);
            forget_canonical_sequence(
                group_epoch,
                sequence,
                canonical_matches,
                variant_bindings,
                reverse_variant_bindings,
                initialized_variants,
            );
            if let Some(id) = persistence.removed_bound_utterance_id.as_deref() {
                lanes[canonical_lane_index]
                    .assembler
                    .record_partial_removed(id);
            }
        }

        if let Some(sequence) = persistence.item.bound_sequence {
            variant_bindings.insert(pending_key, sequence);
            reverse_variant_bindings.insert(
                (group_epoch, sequence, target_language.clone()),
                pending_key,
            );
            pending_variants.remove(&pending_key);
            if let Some(updated) = persistence.bound_utterance {
                canonical_assembler_record_external_state(
                    &mut lanes[canonical_lane_index].assembler,
                    &updated,
                    &target_language,
                );
                canonical_matches.insert(
                    (group_epoch, sequence),
                    CanonicalUtteranceMatch {
                        group_epoch,
                        utterance: updated.clone(),
                    },
                );
                persisted.push(updated);
            }
        } else if let Some(pending) = pending_translation_from_inbox(&persistence.item) {
            pending_variants.insert(pending_key, pending);
        } else {
            pending_variants.remove(&pending_key);
        }
    }
    persisted.extend(flush_pending_translation_variants(
        store,
        &mut lanes[canonical_lane_index].assembler,
        canonical_matches,
        pending_variants,
        variant_bindings,
        reverse_variant_bindings,
    )?);
    prune_resolved_stream_aggregation_history(
        selected_languages,
        canonical_matches,
        pending_variants,
        variant_bindings,
        reverse_variant_bindings,
        initialized_variants,
    );
    Ok(PersistedCaptureChanges {
        utterances: latest_utterance_revisions(persisted),
        requires_full_snapshot: !removed_sequences.is_empty(),
        removed_sequences,
        translation_cues,
    })
}

fn canonical_assembler_record_external_state(
    assembler: &mut RealtimeUtteranceAssembler,
    utterance: &RealtimeUtterance,
    language: &str,
) {
    assembler.record_persisted(&utterance.id, utterance.revision);
    assembler.relinquish_inline_translation_lane(&utterance.id, language);
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
        let source_language = utterance
            .has_source_lane()
            .then(|| normalize_language(&utterance.source_language));
        for language in selected_languages {
            if source_language.as_ref() == Some(language)
                || utterance
                    .variants
                    .iter()
                    .any(|variant| normalize_language(&variant.language) == *language)
                || !initialized_variants.insert((utterance.sequence, language.clone()))
            {
                continue;
            }
            let updated = match store.upsert_translation_variant(
                &utterance.session_id,
                utterance.sequence,
                language,
                None,
                UtteranceVariantState::Waiting,
                None,
            ) {
                Ok(updated) => updated,
                Err(
                    error @ (vt_store::NotebookCaptureStoreError::Conflict(_)
                    | vt_store::NotebookCaptureStoreError::Validation(_)
                    | vt_store::NotebookCaptureStoreError::NotFound(_)),
                ) => {
                    // The Waiting placeholder is cosmetic. A semantic
                    // rejection means the lane's durable state moved past
                    // this snapshot (source revised to this language, lane
                    // already final, utterance withdrawn); none of those may
                    // interrupt the live capture. Only real storage failures
                    // stay fatal.
                    tracing::warn!(
                        session_id = %utterance.session_id,
                        sequence = utterance.sequence,
                        language = %language,
                        error = %error,
                        "waiting translation variant rejected; lane state is newer than snapshot"
                    );
                    continue;
                }
                Err(error) => {
                    return Err(local_persistence_failure(
                        &format!(
                            "persist waiting translation variant {}:{}:{language}",
                            utterance.session_id, utterance.sequence
                        ),
                        error,
                    ));
                }
            };
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
    session_id: &str,
    canonical_matches: &mut std::collections::HashMap<(u64, u64), CanonicalUtteranceMatch>,
) -> Result<Vec<RealtimeUtterance>, ProviderFailure> {
    let updates = store
        .mark_waiting_translation_variants_unavailable(session_id)
        .map_err(|error| {
            local_persistence_failure(
                &format!("persist unavailable translation variants for {session_id}"),
                error,
            )
        })?;
    for updated in &updates {
        for candidate in canonical_matches.values_mut().filter(|candidate| {
            candidate.utterance.session_id == updated.session_id
                && candidate.utterance.sequence == updated.sequence
        }) {
            candidate.utterance = updated.clone();
        }
    }
    Ok(latest_utterance_revisions(updates))
}

fn forget_canonical_sequence(
    group_epoch: u64,
    sequence: u64,
    canonical_matches: &mut std::collections::HashMap<(u64, u64), CanonicalUtteranceMatch>,
    variant_bindings: &mut std::collections::HashMap<(usize, u64, u64), u64>,
    reverse_variant_bindings: &mut std::collections::HashMap<(u64, u64, String), (usize, u64, u64)>,
    initialized_variants: &mut std::collections::HashSet<(u64, String)>,
) {
    canonical_matches.remove(&(group_epoch, sequence));
    initialized_variants.retain(|(candidate_sequence, _)| *candidate_sequence != sequence);
    variant_bindings.retain(|(_, epoch, _), bound| !(*epoch == group_epoch && *bound == sequence));
    reverse_variant_bindings
        .retain(|(epoch, bound, _), _| !(*epoch == group_epoch && *bound == sequence));
}

fn prune_resolved_stream_aggregation_history(
    selected_languages: &[String],
    canonical_matches: &mut std::collections::HashMap<(u64, u64), CanonicalUtteranceMatch>,
    pending_variants: &mut std::collections::HashMap<(usize, u64, u64), PendingTranslationVariant>,
    variant_bindings: &mut std::collections::HashMap<(usize, u64, u64), u64>,
    reverse_variant_bindings: &mut std::collections::HashMap<(u64, u64, String), (usize, u64, u64)>,
    initialized_variants: &mut std::collections::HashSet<(u64, String)>,
) -> usize {
    let mut canonical_keys = canonical_matches.keys().copied().collect::<Vec<_>>();
    canonical_keys.sort_unstable();
    let recycle_count = canonical_keys
        .len()
        .saturating_sub(STREAM_AGGREGATION_RECENT_UTTERANCE_WINDOW);
    canonical_keys.truncate(recycle_count);
    let recycled = canonical_keys
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

    // Unbound provider facts are already durable in SQLite, so the process
    // cache can be bounded independently. A late item outside this window is
    // resolved by the store-authoritative unique matcher.
    let pending_limit =
        STREAM_AGGREGATION_RECENT_UTTERANCE_WINDOW.saturating_mul(selected_languages.len().max(1));
    if pending_variants.len() > pending_limit {
        let mut pending_keys = pending_variants.keys().copied().collect::<Vec<_>>();
        pending_keys.sort_unstable();
        pending_keys.truncate(pending_keys.len() - pending_limit);
        for key in pending_keys {
            pending_variants.remove(&key);
        }
    }
    recycled.len()
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
        let Some(pending) = pending_variants.get(&pending_key).cloned() else {
            continue;
        };
        let key = RealtimeTranslationInboxKey {
            session_id: pending.session_id.clone(),
            lane_index: u64::try_from(pending_key.0).map_err(|_| ProviderFailure {
                error_type: "invalid_stream_lane".to_string(),
                request_id: None,
            })?,
            group_epoch: pending_key.1,
            provider_sequence: pending_key.2,
            target_language: pending.target_language.clone(),
        };
        let cached_sequence = resolve_canonical_sequence(
            pending_key,
            &pending,
            canonical_matches,
            variant_bindings,
            reverse_variant_bindings,
        );
        if cached_sequence.is_some_and(|sequence| {
            canonical_matches
                .get(&(pending.group_epoch, sequence))
                .is_some_and(|candidate| {
                    candidate.utterance.has_source_lane()
                        && !candidate.utterance.source_lane_is_complete()
                        && normalize_language(&candidate.utterance.source_language)
                            == pending.target_language
                        && pending.completion != UtteranceCompletion::Complete
                })
        }) {
            // A provisional source-language guess cannot durably satisfy an
            // independent aux Final. Keep it unbound until the source lane is
            // itself Final or revises to another language.
            continue;
        }
        let (sequence, updated) = if let Some(sequence) = cached_sequence {
            let updated = match store.bind_translation_inbox_item(&key, sequence) {
                Ok(updated) => updated,
                Err(vt_store::NotebookCaptureStoreError::Conflict(conflict)) => {
                    // SQLite is the authority on lane ownership; a contested
                    // bind invalidates this cached correlation. The provider
                    // fact is already durable in the inbox, so it stays
                    // pending for a later better-evidenced pass instead of
                    // interrupting the live capture.
                    tracing::warn!(
                        session_id = %pending.session_id,
                        sequence,
                        target_language = %pending.target_language,
                        conflict = %conflict,
                        "cached translation inbox binding rejected; fact remains unbound"
                    );
                    variant_bindings.remove(&pending_key);
                    let reverse_key = (
                        pending.group_epoch,
                        sequence,
                        pending.target_language.clone(),
                    );
                    if reverse_variant_bindings.get(&reverse_key) == Some(&pending_key) {
                        reverse_variant_bindings.remove(&reverse_key);
                    }
                    continue;
                }
                Err(error) => {
                    return Err(local_persistence_failure(
                        &format!(
                            "bind durable translation inbox {}:{}:{}",
                            pending.session_id, sequence, pending.target_language
                        ),
                        error,
                    ));
                }
            };
            (sequence, updated)
        } else {
            let Some(binding) =
                store
                    .bind_translation_inbox_item_if_unique(&key)
                    .map_err(|error| {
                        local_persistence_failure(
                            &format!(
                                "resolve durable translation inbox {}:{}:{}",
                                pending.session_id,
                                pending.source_sequence,
                                pending.target_language
                            ),
                            error,
                        )
                    })?
            else {
                warn_unbound_auxiliary_final(&pending_key, pending_variants, canonical_matches);
                continue;
            };
            (binding.canonical_sequence, binding.utterance)
        };
        warn_cross_row_translation_span(&pending, sequence, canonical_matches);
        let candidate_key = (pending.group_epoch, sequence);
        let reverse_key = (
            pending.group_epoch,
            sequence,
            pending.target_language.clone(),
        );
        variant_bindings.insert(pending_key, sequence);
        reverse_variant_bindings.insert(reverse_key, pending_key);
        pending_variants.remove(&pending_key);
        if let Some(updated) = updated {
            canonical_assembler_record_external_state(
                canonical_assembler,
                &updated,
                &pending.target_language,
            );
            canonical_matches.insert(
                candidate_key,
                CanonicalUtteranceMatch {
                    group_epoch: pending.group_epoch,
                    utterance: updated.clone(),
                },
            );
            persisted.push(updated);
        }
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

    // A row already holding a sibling segment of this language is not a
    // blocker: the store concatenates the segments into one lane, so the best
    // row by evidence is still the right answer.
    ranked_canonical_sequences(pending, canonical_matches.values())
        .into_iter()
        .next()
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
    contained_source_text: bool,
    /// Length of the containing row; smaller is a tighter fit. Only compared
    /// between two rows that both contain the segment.
    canonical_text_chars: usize,
    overlap_per_mille: u16,
    source_language_matches: bool,
    midpoint_distance_ms: u64,
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
                    .contained_source_text
                    .cmp(&left_score.contained_source_text)
            })
            .then_with(|| {
                left_score
                    .canonical_text_chars
                    .cmp(&right_score.canonical_text_chars)
            })
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
            .then_with(|| left_score.sequence.cmp(&right_score.sequence))
    });
    let Some((best_score, _)) = ranked.first() else {
        return Vec::new();
    };
    let equally_supported_sequences = ranked
        .iter()
        .take_while(|(score, _)| timeline_alignment_evidence_eq(best_score, score))
        .map(|(_, candidate)| candidate.utterance.sequence)
        .collect::<std::collections::HashSet<_>>();
    if equally_supported_sequences.len() > 1 {
        // Canonical sequence is an arbitrary local identifier, not alignment
        // evidence. Equal best evidence for two different rows must remain
        // durably unbound until a later provider revision disambiguates it.
        return Vec::new();
    }
    ranked
        .into_iter()
        .map(|(_, candidate)| candidate.utterance.sequence)
        .collect()
}

fn timeline_alignment_evidence_eq(
    left: &TimelineAlignmentScore,
    right: &TimelineAlignmentScore,
) -> bool {
    left.exact_source_text == right.exact_source_text
        && left.contained_source_text == right.contained_source_text
        && left.canonical_text_chars == right.canonical_text_chars
        && left.overlap_per_mille == right.overlap_per_mille
        && left.source_language_matches == right.source_language_matches
        && left.midpoint_distance_ms == right.midpoint_distance_ms
}

fn timeline_alignment_score(
    pending: &PendingTranslationVariant,
    candidate: &CanonicalUtteranceMatch,
) -> Option<TimelineAlignmentScore> {
    if candidate.group_epoch != pending.group_epoch {
        return None;
    }
    let alignment =
        vt_model::align_source_text(&pending.source_text, &candidate.utterance.source_text);
    let exact_source_text = alignment == vt_model::SourceTextAlignment::Exact;
    let contained_source_text =
        matches!(alignment, vt_model::SourceTextAlignment::Contained { .. });
    let has_text_evidence = exact_source_text || contained_source_text;
    let source_language_matches =
        normalize_language(&candidate.utterance.source_language) == pending.source_language;
    let mut score = TimelineAlignmentScore {
        exact_source_text,
        contained_source_text,
        canonical_text_chars: match alignment {
            vt_model::SourceTextAlignment::Contained { canonical_chars } => canonical_chars,
            _ => usize::MAX,
        },
        overlap_per_mille: 0,
        source_language_matches,
        midpoint_distance_ms: u64::MAX,
        sequence: candidate.utterance.sequence,
    };

    match (
        pending.source_start_ms,
        pending.source_end_ms,
        candidate.utterance.source_start_ms,
        candidate.utterance.source_end_ms,
    ) {
        (Some(left_start), Some(left_end), Some(right_start), Some(right_end)) => {
            if left_end < left_start || right_end < right_start {
                return None;
            }
            score.midpoint_distance_ms = (left_start.saturating_add(left_end) / 2)
                .abs_diff(right_start.saturating_add(right_end) / 2);
            match timestamp_overlap_per_mille(left_start, left_end, right_start, right_end) {
                Some(overlap_per_mille) => {
                    score.overlap_per_mille = overlap_per_mille;
                    Some(score)
                }
                // Both intervals describe the shared capture timeline. Exact
                // or contained words rank overlapping candidates, but cannot
                // resurrect even a nearby disjoint repeated filler. The live
                // cue remains visible without a row while the matching
                // canonical interval has not arrived yet.
                None => None,
            }
        }
        _ if has_text_evidence => Some(score),
        _ => None,
    }
}

fn pending_matches_candidate_identity(
    pending: &PendingTranslationVariant,
    candidate: &CanonicalUtteranceMatch,
) -> bool {
    timeline_alignment_score(pending, candidate).is_some()
}

/// Returns the other canonical rows this auxiliary segment materially overlaps.
/// A non-empty result means sibling-stream endpointing diverged: the provider
/// packed audio from several canonical rows into one segment, and whole-segment
/// binding is about to place cross-row content into a single row.
fn cross_row_translation_spans(
    pending: &PendingTranslationVariant,
    bound_sequence: u64,
    candidates: impl Iterator<Item = impl std::borrow::Borrow<CanonicalUtteranceMatch>>,
) -> Vec<u64> {
    let mut spanning = candidates
        .filter_map(|candidate| {
            let candidate = candidate.borrow();
            if candidate.group_epoch != pending.group_epoch
                || candidate.utterance.sequence == bound_sequence
            {
                return None;
            }
            timeline_alignment_score(pending, candidate)
                .filter(|score| score.overlap_per_mille >= CROSS_ROW_OVERLAP_WARN_PER_MILLE)
                .map(|_| candidate.utterance.sequence)
        })
        .collect::<Vec<_>>();
    spanning.sort_unstable();
    spanning.dedup();
    spanning
}

/// A Final auxiliary segment the store could not place on any canonical row.
///
/// A row already holding a sibling segment is no longer a reason for this: the
/// lane concatenates them. What remains is genuinely unplaceable evidence —
/// two rows with equal claim on the words, or a row that has not arrived — so
/// this is now a real gap in the translated text rather than a known-lossy
/// path. Warns exactly once per segment and carries no transcript text.
fn warn_unbound_auxiliary_final(
    pending_key: &(usize, u64, u64),
    pending_variants: &mut std::collections::HashMap<(usize, u64, u64), PendingTranslationVariant>,
    canonical_matches: &std::collections::HashMap<(u64, u64), CanonicalUtteranceMatch>,
) {
    let Some(pending) = pending_variants.get_mut(pending_key) else {
        return;
    };
    if pending.reverse_conflict_warned || pending.completion != UtteranceCompletion::Complete {
        return;
    }
    let candidate_rows = canonical_matches
        .values()
        .filter(|candidate| timeline_alignment_score(pending, candidate).is_some())
        .count();
    pending.reverse_conflict_warned = true;
    tracing::warn!(
        target_language = %pending.target_language,
        source_language = %pending.source_language,
        candidate_rows,
        provider_sequence = pending.source_sequence,
        source_start_ms = pending.source_start_ms,
        source_end_ms = pending.source_end_ms,
        "auxiliary translation segment matched no unique canonical row; fact stays durably unbound"
    );
}

/// Observability only; carries no transcript text. Finals only, because a live
/// Partial legitimately sweeps across rows while its segment is still open.
fn warn_cross_row_translation_span(
    pending: &PendingTranslationVariant,
    bound_sequence: u64,
    canonical_matches: &std::collections::HashMap<(u64, u64), CanonicalUtteranceMatch>,
) {
    if pending.completion != UtteranceCompletion::Complete {
        return;
    }
    let spanning = cross_row_translation_spans(pending, bound_sequence, canonical_matches.values());
    if spanning.is_empty() {
        return;
    }
    tracing::warn!(
        target_language = %pending.target_language,
        source_language = %pending.source_language,
        bound_sequence,
        spanning_sequences = ?spanning,
        source_start_ms = pending.source_start_ms,
        source_end_ms = pending.source_end_ms,
        "auxiliary translation segment spans multiple canonical rows; sibling-stream endpointing diverged"
    );
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
    let both_have_duration = left_end > left_start && right_end > right_start;
    if intersection_end < intersection_start
        || (both_have_duration && intersection_end == intersection_start)
    {
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

fn outage_is_continuous(outage_ms: u64) -> bool {
    outage_ms <= REALTIME_CONTINUITY_WINDOW_MS
}

fn persist_assembled_utterances(
    store: &NotebookCaptureStore,
    assembler: &mut RealtimeUtteranceAssembler,
    updates: Vec<AssembledRealtimeUtterance>,
    provider_session_epoch: u64,
) -> Result<PersistedCaptureChanges, ProviderFailure> {
    let mut persisted_updates = Vec::with_capacity(updates.len());
    let mut removed_sequences = Vec::new();
    for mut update in updates {
        if update.remove_partial {
            let expected_revision = update.expected_revision.ok_or_else(|| ProviderFailure {
                error_type: "local_persistence".to_string(),
                request_id: None,
            })?;
            let translation_update = if update.translation_dirty {
                match (
                    update.utterance.translated_language.as_ref(),
                    update.utterance.translated_text.as_ref(),
                    update.translation_completion,
                ) {
                    (Some(language), Some(text), Some(completion)) => {
                        Some(RealtimeTranslationLaneUpdate {
                            language: language.clone(),
                            text: Some(text.clone()),
                            state: UtteranceVariantState::Ready,
                            completion: Some(completion),
                        })
                    }
                    _ => update.translation_clear_language.as_ref().map(|language| {
                        RealtimeTranslationLaneUpdate {
                            language: language.clone(),
                            text: None,
                            state: UtteranceVariantState::Waiting,
                            completion: None,
                        }
                    }),
                }
            } else {
                None
            };
            let surviving_shell = store
                .remove_partial_utterance(
                    &update.utterance.session_id,
                    update.utterance.sequence,
                    expected_revision,
                    translation_update.as_ref(),
                )
                .map_err(|error| {
                    local_persistence_failure(
                        &format!(
                            "remove withdrawn Soniox partial {}:{}",
                            update.utterance.session_id, update.utterance.sequence
                        ),
                        error,
                    )
                })?;
            if let Some(surviving_shell) = surviving_shell {
                let has_final_translation_owner = surviving_shell.variants.iter().any(|variant| {
                    variant.role == UtteranceVariantRole::Translation
                        && variant.state == UtteranceVariantState::Ready
                        && variant.completion == Some(UtteranceCompletion::Complete)
                });
                if has_final_translation_owner {
                    // The translation-only shell is now an immutable historical
                    // row. Retire its source segment from the assembler so a
                    // later canonical response allocates a fresh sequence
                    // instead of trying to revise the Final owner's row and
                    // turning a normal provider tail replacement into a
                    // capture-wide persistence failure.
                    assembler.retire_source_segment(&surviving_shell.id);
                } else {
                    assembler.record_translation_persisted(
                        &surviving_shell.id,
                        translation_update
                            .as_ref()
                            .filter(|update| update.state == UtteranceVariantState::Ready)
                            .map(|update| update.language.as_str()),
                    );
                    assembler.record_persisted(&surviving_shell.id, surviving_shell.revision);
                }
                persisted_updates.push(surviving_shell);
            } else {
                assembler.record_partial_removed(&update.utterance.id);
            }
            removed_sequences.push(update.utterance.sequence);
            continue;
        }
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
        // The aggregate row is the source-lane compatibility record. A
        // translation must never participate in its completion decision or
        // source CAS, so canonical persistence strips the legacy shadow and
        // writes the translation through its lane-local variant API below.
        let mut persisted = if update.source_dirty || update.expected_revision.is_none() {
            let mut source = update.utterance.clone();
            source.translated_language = None;
            source.translated_text = None;
            source.alignment = match source.alignment {
                UtteranceAlignment::OutsideLanguagePair => UtteranceAlignment::OutsideLanguagePair,
                UtteranceAlignment::TranslationPending => UtteranceAlignment::TranslationPending,
                _ if update.utterance.translated_text.is_some() => {
                    UtteranceAlignment::TranslationPending
                }
                _ => UtteranceAlignment::SourceOnly,
            };
            match store.upsert_utterance(&source, update.expected_revision) {
                Ok(persisted) => persisted,
                Err(vt_store::NotebookCaptureStoreError::Conflict(_))
                    if update.expected_revision.is_some() =>
                {
                    // A later source fact may already have advanced this lane.
                    // Retain only an immutable newer source Final; translation
                    // revisions use their own CAS and cannot satisfy this
                    // fallback.
                    store
                        .get_machine_utterance_by_id(&source.id)
                        .map_err(|error| {
                            local_persistence_failure(
                                "reload source utterance after stale provider revision",
                                error,
                            )
                        })?
                        .filter(|current| {
                            current.source_fact_is_complete()
                                && update
                                    .expected_revision
                                    .is_some_and(|expected| current.revision > expected)
                        })
                        .ok_or_else(|| ProviderFailure {
                            error_type: "local_persistence".to_string(),
                            request_id: None,
                        })?
                }
                Err(error) => {
                    return Err(local_persistence_failure(
                        &format!(
                            "persist ordered Soniox source {}:{}",
                            source.session_id, source.sequence
                        ),
                        error,
                    ));
                }
            }
        } else {
            store
                .get_machine_utterance_by_id(&update.utterance.id)
                .map_err(|error| {
                    local_persistence_failure("reload translation parent utterance", error)
                })?
                .ok_or_else(|| ProviderFailure {
                    error_type: "local_persistence".to_string(),
                    request_id: None,
                })?
        };

        if update.translation_dirty {
            if let (Some(language), Some(text), Some(completion)) = (
                update.utterance.translated_language.as_deref(),
                update.utterance.translated_text.as_deref(),
                update.translation_completion,
            ) {
                persisted = store
                    .upsert_translation_variant(
                        &update.utterance.session_id,
                        update.utterance.sequence,
                        language,
                        Some(text),
                        UtteranceVariantState::Ready,
                        Some(completion),
                    )
                    .map_err(|error| {
                        local_persistence_failure(
                            &format!(
                                "persist ordered Soniox translation {}:{}:{language}",
                                update.utterance.session_id, update.utterance.sequence
                            ),
                            error,
                        )
                    })?;
                assembler.record_translation_persisted(&persisted.id, Some(language));
            } else if let Some(language) = update.translation_clear_language.as_deref() {
                persisted = store
                    .upsert_translation_variant(
                        &update.utterance.session_id,
                        update.utterance.sequence,
                        language,
                        None,
                        UtteranceVariantState::Waiting,
                        None,
                    )
                    .map_err(|error| {
                        local_persistence_failure(
                            &format!(
                                "withdraw Soniox partial translation {}:{}:{language}",
                                update.utterance.session_id, update.utterance.sequence
                            ),
                            error,
                        )
                    })?;
                assembler.record_translation_persisted(&persisted.id, None);
            }
        }
        assembler.record_persisted(&persisted.id, persisted.revision);
        persisted_updates.push(persisted);
    }
    Ok(PersistedCaptureChanges {
        utterances: persisted_updates,
        requires_full_snapshot: !removed_sequences.is_empty(),
        removed_sequences,
        translation_cues: Vec::new(),
    })
}

fn local_persistence_failure(operation: &str, error: impl std::fmt::Display) -> ProviderFailure {
    tracing::warn!(
        operation,
        error = %error,
        "local capture persistence failed; error detail suppressed from durable state"
    );
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

fn missing_remote_truth(run: &NotebookCaptureRun) -> (RemoteHealth, ProviderFailure) {
    let health = match run.remote_health {
        RemoteHealth::Live | RemoteHealth::Degraded => RemoteHealth::Degraded,
        RemoteHealth::Off | RemoteHealth::Connecting | RemoteHealth::Unavailable => {
            RemoteHealth::Unavailable
        }
    };
    let failure = ProviderFailure {
        error_type: run
            .provider_error_type
            .clone()
            .unwrap_or_else(|| "remote_runtime_unavailable".to_string()),
        request_id: run.provider_request_id.clone(),
    };
    (health, failure)
}

fn emit_capture_delta(
    run: NotebookCaptureRun,
    changed_utterances: Vec<RealtimeUtterance>,
    changed_translation_cues: Vec<FfiNotebookCaptureTranslationCue>,
    callback: &CaptureCallbackSink,
) {
    // The callback mailbox may coalesce an intermediate delta while Swift is
    // busy. `CaptureCallbackSink` revisions make that loss explicit so Swift
    // performs one bounded full rebuild instead of receiving O(n^2) snapshots.
    let mut event = event_from_run(run, changed_utterances, false);
    event.translation_cues = changed_translation_cues;
    callback.send(event);
}

/// A lane transition delta: carries the whole group's current lane health so
/// the operator surface never has to reconstruct state from event order.
fn emit_capture_lane_transition(
    run: NotebookCaptureRun,
    lanes: &[StreamAggregationLane],
    callback: &CaptureCallbackSink,
) {
    let mut event = event_from_run(run, Vec::new(), false);
    event.lane_health = lane_health_snapshot(lanes);
    callback.send(event);
}

fn lane_health_snapshot(lanes: &[StreamAggregationLane]) -> Vec<FfiNotebookCaptureLaneHealth> {
    lanes
        .iter()
        .map(|lane| FfiNotebookCaptureLaneHealth {
            target_language: lane.descriptor.target_language.clone(),
            state: if lane.failed {
                "failed"
            } else if lane.connected {
                "live"
            } else {
                "connecting"
            }
            .to_string(),
            group_epoch: lane.group_epoch,
            final_audio_proc_ms: lane.final_audio_proc_ms,
            total_audio_proc_ms: lane.total_audio_proc_ms,
            lag_ms: lane.lag_ms,
            input_discontinuous: lane.input_discontinuous,
        })
        .collect()
}

fn translation_cue_from_inbox_item(
    item: &RealtimeTranslationInboxItem,
) -> FfiNotebookCaptureTranslationCue {
    FfiNotebookCaptureTranslationCue {
        target_language: item.key.target_language.clone(),
        group_epoch: item.key.group_epoch,
        provider_sequence: item.key.provider_sequence,
        source_language: item.source_language.clone(),
        source_start_ms: item.source_start_ms,
        source_end_ms: item.source_end_ms,
        text: item.translated_text.clone().unwrap_or_default(),
        completion: match item.completion {
            Some(UtteranceCompletion::Complete) => "complete".to_string(),
            // A withdrawn tombstone has no completion; "partial" keeps the
            // field total without inventing a third state.
            Some(UtteranceCompletion::Partial) | None => "partial".to_string(),
        },
        withdrawn: item.withdrawn,
        revision: item.revision,
    }
}

/// Every present cue of a session, for full-snapshot events. Partial cues are
/// included: they are durable inbox facts and the client's only view of a
/// translation whose canonical row has not caught up yet.
fn list_present_translation_cues(
    store: &NotebookCaptureStore,
    session_id: &str,
) -> Result<
    Vec<FfiNotebookCaptureTranslationCue>,
    vt_store::notebook_capture_store::NotebookCaptureStoreError,
> {
    Ok(store
        .list_translation_inbox(session_id)?
        .iter()
        .filter(|item| !item.withdrawn && item.translated_text.is_some())
        .map(translation_cue_from_inbox_item)
        .collect())
}

/// The audience canvas renders at most eight rows. Keeping the same bounded
/// tail per language makes live callbacks level-triggered without letting a
/// stalled UI turn the callback mailbox into a session-length queue.
const LIVE_TRANSLATION_CUES_PER_LANGUAGE: usize = 8;

type LiveTranslationCueKey = (u64, u64, String);

fn live_translation_cue_key(cue: &FfiNotebookCaptureTranslationCue) -> LiveTranslationCueKey {
    (
        cue.group_epoch,
        cue.provider_sequence,
        cue.target_language.clone(),
    )
}

fn reconcile_live_translation_cues(
    current: &mut std::collections::HashMap<
        LiveTranslationCueKey,
        FfiNotebookCaptureTranslationCue,
    >,
    changes: &[FfiNotebookCaptureTranslationCue],
) {
    for cue in changes {
        let key = live_translation_cue_key(cue);
        if current
            .get(&key)
            .is_some_and(|existing| existing.revision > cue.revision)
        {
            continue;
        }
        if cue.withdrawn {
            current.remove(&key);
        } else if !cue.text.is_empty() {
            current.insert(key, cue.clone());
        }
    }

    let mut keys_by_language =
        std::collections::HashMap::<String, Vec<LiveTranslationCueKey>>::new();
    for key in current.keys() {
        keys_by_language
            .entry(key.2.clone())
            .or_default()
            .push(key.clone());
    }
    for keys in keys_by_language.values_mut() {
        keys.sort_by(|left, right| {
            let left_cue = &current[left];
            let right_cue = &current[right];
            left_cue
                .group_epoch
                .cmp(&right_cue.group_epoch)
                .then_with(|| left_cue.provider_sequence.cmp(&right_cue.provider_sequence))
                .then_with(|| left_cue.source_start_ms.cmp(&right_cue.source_start_ms))
        });
        let remove_count = keys
            .len()
            .saturating_sub(LIVE_TRANSLATION_CUES_PER_LANGUAGE);
        for key in keys.iter().take(remove_count) {
            current.remove(key);
        }
    }
}

fn live_translation_cue_snapshot(
    current: &std::collections::HashMap<LiveTranslationCueKey, FfiNotebookCaptureTranslationCue>,
) -> Vec<FfiNotebookCaptureTranslationCue> {
    let mut cues = current.values().cloned().collect::<Vec<_>>();
    cues.sort_by(|left, right| {
        left.target_language
            .cmp(&right.target_language)
            .then_with(|| left.group_epoch.cmp(&right.group_epoch))
            .then_with(|| left.provider_sequence.cmp(&right.provider_sequence))
            .then_with(|| left.source_start_ms.cmp(&right.source_start_ms))
    });
    cues
}

fn emit_realtime_progress(run: NotebookCaptureRun, lag_ms: u64, callback: &CaptureCallbackSink) {
    let mut event = event_from_run(run, Vec::new(), false);
    event.realtime_lag_ms = Some(lag_ms);
    callback.send(event);
}

fn emit_live_preview(
    session_id: &str,
    previews: Vec<AssembledRealtimeUtterance>,
    translation_cues: Vec<FfiNotebookCaptureTranslationCue>,
    lane_health: Vec<FfiNotebookCaptureLaneHealth>,
    callback: &CaptureCallbackSink,
) {
    callback.send_preview(FfiNotebookCaptureLivePreview {
        session_id: session_id.to_string(),
        preview_revision: 0,
        utterances: previews.into_iter().map(ffi_live_preview).collect(),
        translation_cues,
        lane_health,
    });
}

fn event_full_snapshot_from_run(
    store: &NotebookCaptureStore,
    run: NotebookCaptureRun,
) -> Result<FfiNotebookCaptureEvent, CoreError> {
    let utterances = store
        .list_utterances(&run.session_id)
        .map_err(store_error)?;
    let translation_cues =
        list_present_translation_cues(store, &run.session_id).map_err(store_error)?;
    let mut event = event_from_run(run, utterances, true);
    event.translation_cues = translation_cues;
    Ok(event)
}

pub(crate) struct CaptureCallbackSink {
    mailbox: Arc<CaptureCallbackMailbox>,
    store: NotebookCaptureStore,
}

struct CaptureCallbackMailbox {
    pending: StdMutex<PendingCaptureCallbacks>,
    wake: Condvar,
    closed: AtomicBool,
    sender_count: AtomicUsize,
    next_revision: AtomicU64,
    next_preview_revision: AtomicU64,
    last_enqueued_applied_revision: AtomicU64,
}

#[derive(Default)]
struct PendingCaptureCallbacks {
    event: Option<FfiNotebookCaptureEvent>,
    preview: Option<FfiNotebookCaptureLivePreview>,
    remote_truth: Option<CaptureRemoteTruthOverlay>,
    /// Sticky, like `remote_truth`: the mailbox holds one event slot, so a
    /// transition published as a one-shot payload is lost whenever the next
    /// delta overwrites it before the dispatcher drains. A lane can fail
    /// exactly once in a session, and that single edge is precisely what the
    /// operator must not miss, so lane health is carried as current state on
    /// every outgoing event instead of as an edge.
    lane_health: Vec<FfiNotebookCaptureLaneHealth>,
}

#[derive(Debug, Clone)]
struct CaptureRemoteTruthOverlay {
    session_id: String,
    health: RemoteHealth,
    failure: ProviderFailure,
}

impl Clone for CaptureCallbackSink {
    fn clone(&self) -> Self {
        self.mailbox.sender_count.fetch_add(1, Ordering::Relaxed);
        Self {
            mailbox: self.mailbox.clone(),
            store: self.store.clone(),
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
    fn new(
        callback: Arc<dyn FfiNotebookCaptureCallback>,
        store: NotebookCaptureStore,
        share_tap: Option<crate::share_api::ShareCaptionTap>,
    ) -> Result<Self, CoreError> {
        let mailbox = Arc::new(CaptureCallbackMailbox {
            pending: StdMutex::new(PendingCaptureCallbacks::default()),
            wake: Condvar::new(),
            closed: AtomicBool::new(false),
            sender_count: AtomicUsize::new(1),
            next_revision: AtomicU64::new(1),
            next_preview_revision: AtomicU64::new(1),
            last_enqueued_applied_revision: AtomicU64::new(0),
        });
        let worker_mailbox = mailbox.clone();
        std::thread::Builder::new()
            .name("zulangue-capture-callback".to_string())
            .spawn(move || {
                // Post-coalescing delivery is the one point where what Swift
                // will present is known exactly, so the erasure baseline is
                // metered here. Counts and language codes only.
                let mut erasure = crate::capture_erasure::ErasureMeter::default();
                loop {
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
                    if let Some(event) = &event {
                        erasure.absorb_event_utterances(&event.session_id, &event.utterances);
                        if matches!(
                            event.capture_state,
                            FfiNotebookCaptureState::Completed
                                | FfiNotebookCaptureState::Interrupted
                                | FfiNotebookCaptureState::Failed
                        ) {
                            erasure.finish_session();
                        }
                    }
                    if let Some(preview) = &preview {
                        erasure.absorb_preview(preview);
                        // 广播与本机呈现同一帧。放在 catch_unwind 之外是刻意的:
                        // Swift 回调 panic 不该顺带让房间里的人失去字幕,反过来也一样。
                        if let Some(tap) = &share_tap {
                            tap.broadcast(preview);
                        }
                    }
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
                }
                erasure.finish_session();
            })
            .map_err(|error| CoreError::InternalError {
                message: format!("start capture callback dispatcher: {error}"),
            })?;
        Ok(Self { mailbox, store })
    }

    fn send(&self, event: FfiNotebookCaptureEvent) -> FfiNotebookCaptureEvent {
        self.send_with_refresh_hook(event, || {})
    }

    fn send_with_refresh_hook<H>(
        &self,
        mut event: FfiNotebookCaptureEvent,
        after_refresh: H,
    ) -> FfiNotebookCaptureEvent
    where
        H: FnOnce(),
    {
        let mut pending = self.mailbox.pending.lock().unwrap();
        // Allocate before the fallible refresh. Even if the stale callback is
        // deliberately not enqueued, a synchronous pause/stop caller receives
        // a monotonic revision and the next delivered callback exposes a gap
        // that forces the client to reload.
        let event_revision = self.mailbox.next_revision.fetch_add(1, Ordering::Relaxed);
        if self.mailbox.closed.load(Ordering::Acquire) {
            tracing::warn!("Notebook capture callback dispatcher is closed");
            let mut direct = event;
            direct.event_revision = event_revision;
            return direct;
        }

        // `event` may have been assembled from a run snapshot immediately
        // before a concurrent pause/resume/health transaction committed. The
        // mailbox is the publication order boundary: refresh every
        // run-derived field while holding its lock. SQLite materializes the
        // run plus only the changed sequence rows in one read transaction;
        // only an explicit full event scans the whole session.
        let requested_sequences = event
            .utterances
            .iter()
            .map(|utterance| utterance.sequence)
            .collect::<Vec<_>>();
        let mut refreshed = match self.store.load_capture_callback_snapshot(
            &event.session_id,
            &requested_sequences,
            event.is_full_snapshot,
        ) {
            Ok(Some((run, utterances))) => {
                let mut refreshed = event_from_run(run, utterances, event.is_full_snapshot);
                // A full snapshot re-reads every present cue; a delta keeps
                // the cue payload it was emitted with. A cue delta can only
                // be stale toward a lower per-key revision, which the client
                // upsert ignores; coalescing losses heal through the same
                // gap-repair snapshot as utterances.
                refreshed.translation_cues = if event.is_full_snapshot {
                    match list_present_translation_cues(&self.store, &event.session_id) {
                        Ok(translation_cues) => translation_cues,
                        Err(error) => {
                            tracing::warn!(
                                session_id = %event.session_id,
                                error = %error,
                                "capture snapshot cue load failed; snapshot sent without cues"
                            );
                            Vec::new()
                        }
                    }
                } else {
                    std::mem::take(&mut event.translation_cues)
                };
                refreshed.realtime_lag_ms = event.realtime_lag_ms;
                if matches!(
                    refreshed.capture_state,
                    FfiNotebookCaptureState::Completed
                        | FfiNotebookCaptureState::Interrupted
                        | FfiNotebookCaptureState::Failed
                ) {
                    pending.remote_truth = None;
                    // The stream group is gone; there are no lanes to describe.
                    pending.lane_health.clear();
                } else {
                    Self::apply_remote_truth_overlay(&mut refreshed, pending.remote_truth.as_ref());
                    if !event.lane_health.is_empty() {
                        pending.lane_health = std::mem::take(&mut event.lane_health);
                    }
                }
                refreshed.lane_health = pending.lane_health.clone();
                refreshed
            }
            Ok(None) => {
                tracing::warn!(
                    session_id = %event.session_id,
                    "capture callback refresh found no durable run; stale event was not enqueued"
                );
                let mut direct = event;
                direct.event_revision = event_revision;
                return direct;
            }
            Err(error) => {
                tracing::warn!(
                    session_id = %event.session_id,
                    error = %error,
                    "capture callback refresh failed; stale event was not enqueued"
                );
                let mut direct = event;
                direct.event_revision = event_revision;
                return direct;
            }
        };
        after_refresh();
        refreshed.event_revision = event_revision;
        self.mailbox
            .last_enqueued_applied_revision
            .fetch_max(refreshed.realtime_loro_applied_revision, Ordering::Release);
        pending.event = Some(refreshed.clone());
        drop(pending);
        self.mailbox.wake.notify_one();
        refreshed
    }

    fn set_remote_truth_overlay(
        &self,
        session_id: &str,
        health: RemoteHealth,
        failure: ProviderFailure,
    ) {
        let mut pending = self.mailbox.pending.lock().unwrap();
        let overlay = CaptureRemoteTruthOverlay {
            session_id: session_id.to_string(),
            health,
            failure,
        };
        if let Some(event) = pending.event.as_mut() {
            Self::apply_remote_truth_overlay(event, Some(&overlay));
        }
        pending.remote_truth = Some(overlay);
    }

    fn clear_remote_truth_overlay(&self, session_id: &str) {
        let mut pending = self.mailbox.pending.lock().unwrap();
        if pending
            .remote_truth
            .as_ref()
            .is_some_and(|overlay| overlay.session_id == session_id)
        {
            pending.remote_truth = None;
        }
    }

    fn remote_truth_overlay(&self, session_id: &str) -> Option<CaptureRemoteTruthOverlay> {
        self.mailbox
            .pending
            .lock()
            .unwrap()
            .remote_truth
            .as_ref()
            .filter(|overlay| overlay.session_id == session_id)
            .cloned()
    }

    fn full_snapshot_with_remote_truth(
        &self,
        session_id: &str,
    ) -> Result<FfiNotebookCaptureEvent, CoreError> {
        let mut pending = self.mailbox.pending.lock().unwrap();
        let (run, utterances) = self
            .store
            .load_capture_callback_snapshot(session_id, &[], true)
            .map_err(store_error)?
            .ok_or_else(|| CoreError::NotFound {
                message: format!("capture session {session_id}"),
            })?;
        let mut event = event_from_run(run, utterances, true);
        event.translation_cues =
            list_present_translation_cues(&self.store, session_id).map_err(store_error)?;
        if matches!(
            event.capture_state,
            FfiNotebookCaptureState::Completed
                | FfiNotebookCaptureState::Interrupted
                | FfiNotebookCaptureState::Failed
        ) {
            pending.remote_truth = None;
            pending.lane_health.clear();
        } else {
            Self::apply_remote_truth_overlay(&mut event, pending.remote_truth.as_ref());
        }
        // A snapshot is the client's rebuild path after a coalescing gap, so
        // it has to carry lane health too or a lost transition never heals.
        event.lane_health = pending.lane_health.clone();
        // `send_with_refresh_hook` allocates callback revisions while holding
        // this same mailbox lock. Stamping the read here therefore makes the
        // full snapshot an exact coverage checkpoint: every callback revision
        // at or below this value is represented by the authoritative store
        // snapshot (or by the process-local state copied above), while a later
        // callback is guaranteed to receive a larger revision. Swift can
        // install this snapshot and replay later deltas without waiting for a
        // quiet interval in a continuous stream.
        event.event_revision = self
            .mailbox
            .next_revision
            .load(Ordering::Acquire)
            .saturating_sub(1);
        Ok(event)
    }

    fn apply_remote_truth_overlay(
        event: &mut FfiNotebookCaptureEvent,
        overlay: Option<&CaptureRemoteTruthOverlay>,
    ) {
        let Some(overlay) = overlay.filter(|overlay| overlay.session_id == event.session_id) else {
            return;
        };
        event.remote_health = overlay.health.into();
        event.provider_error_type = Some(overlay.failure.error_type.clone());
        event.provider_request_id = overlay.failure.request_id.clone();
    }

    /// Commits a durable projection ACK without letting an older run snapshot
    /// overwrite a newer capture-state event in the latest-wins mailbox.
    ///
    /// The mailbox lock is deliberately held while selecting the fallback
    /// event and committing the SQLite ACK:
    ///
    /// - if pause/resume already queued an event, only its applied watermark is
    ///   raised;
    /// - if no event is pending, the latest run is read before the ACK and
    ///   queued while later state events are blocked on this same lock;
    /// - a fallback read failure occurs before the ACK, so an advanced receipt
    ///   can never lose its only UI notification.
    fn commit_projection_ack<C>(
        &self,
        session_id: &str,
        commit_ack: C,
    ) -> Result<RealtimeLoroProjectionAck, CoreError>
    where
        C: FnOnce() -> Result<RealtimeLoroProjectionAck, CoreError>,
    {
        let mut pending = self.mailbox.pending.lock().unwrap();
        if let Some(event) = pending.event.as_ref() {
            if event.session_id != session_id {
                return Err(CoreError::InternalError {
                    message: format!(
                        "capture callback mailbox for {} contains event for {}",
                        session_id, event.session_id
                    ),
                });
            }
        }
        let closed = self.mailbox.closed.load(Ordering::Acquire);
        let fallback = if !closed && pending.event.is_none() {
            let run = self
                .store
                .get_run_for_session(session_id)
                .map_err(store_error)?
                .ok_or_else(|| CoreError::NotFound {
                    message: format!("capture session {session_id}"),
                })?;
            let mut event = event_from_run(run, Vec::new(), false);
            Self::apply_remote_truth_overlay(&mut event, pending.remote_truth.as_ref());
            if event.session_id != session_id {
                return Err(CoreError::InternalError {
                    message: format!(
                        "capture projection ACK fallback for {} loaded event for {}",
                        session_id, event.session_id
                    ),
                });
            }
            Some(event)
        } else {
            None
        };

        let acknowledgement = commit_ack()?;
        if acknowledgement.session_id != session_id {
            return Err(CoreError::InternalError {
                message: format!(
                    "capture projection ACK for {} returned receipt for {}",
                    session_id, acknowledgement.session_id
                ),
            });
        }
        let mut notify = false;
        if acknowledgement.advanced && !closed {
            if let Some(event) = pending.event.as_mut() {
                event.realtime_loro_applied_revision = event
                    .realtime_loro_applied_revision
                    .max(acknowledgement.applied_revision);
                self.mailbox
                    .last_enqueued_applied_revision
                    .fetch_max(acknowledgement.applied_revision, Ordering::Release);
                notify = true;
            } else {
                let mut event =
                    fallback.expect("an open empty mailbox loaded its fallback before ACK");
                event.realtime_loro_applied_revision = event
                    .realtime_loro_applied_revision
                    .max(acknowledgement.applied_revision);
                event.event_revision = self.mailbox.next_revision.fetch_add(1, Ordering::Relaxed);
                self.mailbox
                    .last_enqueued_applied_revision
                    .fetch_max(event.realtime_loro_applied_revision, Ordering::Release);
                pending.event = Some(event);
                notify = true;
            }
        }
        drop(pending);
        if notify {
            self.mailbox.wake.notify_one();
        }
        Ok(acknowledgement)
    }

    fn last_enqueued_applied_revision(&self) -> u64 {
        self.mailbox
            .last_enqueued_applied_revision
            .load(Ordering::Acquire)
    }

    fn is_closed(&self) -> bool {
        self.mailbox.closed.load(Ordering::Acquire)
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
        segment.source_dirty = true;
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
            self.segments[current].source_dirty = true;
            self.segments[current].translation_dirty = true;
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
                let changes_durable_source_language = segment.source.committed_language.is_none()
                    && segment.committed_source_language_hint.as_deref()
                        != Some(source_language.as_str());
                segment.committed_source_language_hint = Some(source_language);
                segment.source_dirty |= changes_durable_source_language;
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
        segment.translation_dirty = true;
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
            segment.source_dirty = true;
            segment.translation_dirty = true;
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
            segment.source_dirty = true;
            segment.translation_dirty = true;
        }
        for segment in &mut self.segments {
            if !segment.is_empty() && !segment.complete {
                segment.complete = true;
                segment.source_dirty = true;
                segment.translation_dirty = true;
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

    fn record_translation_persisted(&mut self, id: &str, language: Option<&str>) {
        if let Some(segment) = self.segments.iter_mut().find(|segment| segment.id == id) {
            segment.persisted_translation_language = language.map(normalize_language);
        }
    }

    fn relinquish_inline_translation_lane(&mut self, id: &str, language: &str) {
        let language = normalize_language(language);
        if let Some(segment) = self.segments.iter_mut().find(|segment| segment.id == id) {
            if segment.persisted_translation_language.as_deref() == Some(language.as_str()) {
                segment.persisted_translation_language = None;
            }
        }
    }

    fn record_partial_removed(&mut self, id: &str) {
        if let Some(segment) = self.segments.iter_mut().find(|segment| segment.id == id) {
            segment.revision = None;
            segment.persisted_translation_language = None;
        }
    }

    /// Stops a withdrawn canonical source from ever reusing a row now owned by
    /// an immutable Final translation. The durable shell stays in SQLite; only
    /// the process-local source identity is retired. `next_sequence` is already
    /// past this segment, so the next provider response creates a distinct row.
    fn retire_source_segment(&mut self, id: &str) {
        let Some(index) = self.segments.iter().position(|segment| segment.id == id) else {
            return;
        };
        let segment = &mut self.segments[index];
        segment.revision = None;
        segment.persisted_translation_language = None;
        segment.complete = true;
        segment.source_dirty = false;
        segment.translation_dirty = false;
        if self.latest_original_segment == Some(index) {
            self.latest_original_segment = None;
        }
        if self.latest_translation_segment == Some(index) {
            self.latest_translation_segment = None;
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
                if !segment.source_dirty && !segment.translation_dirty {
                    return None;
                }
                let source_dirty = std::mem::take(&mut segment.source_dirty);
                let translation_dirty = std::mem::take(&mut segment.translation_dirty);
                // Keep a pure provisional run out of the language columns.
                // It will use the same segment ID once final source evidence
                // arrives, or be emitted as a neutral `und` fact if an
                // endpoint/reconnect forces finalization first.
                if !segment.complete
                    && segment.stable_source_language().is_none()
                    && segment.persisted_translation_language.is_none()
                    && segment.revision.is_none()
                {
                    return None;
                }
                let has_publishable_source = !segment
                    .source
                    .text(segment.pending_source_matches_committed_identity())
                    .is_empty();
                if !has_publishable_source
                    && segment.revision.is_none()
                    && segment.persisted_translation_language.is_none()
                {
                    return None;
                }
                Some(assemble_segment(
                    &session_id,
                    &selected_languages,
                    capture_mode,
                    common_caption_language.as_deref(),
                    segment,
                    source_dirty,
                    translation_dirty,
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
                    false,
                    false,
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
    source_dirty: bool,
    translation_dirty: bool,
) -> AssembledRealtimeUtterance {
    let include_pending_source = segment.pending_source_matches_committed_identity();
    let source_text = segment.source.text(include_pending_source);
    let source_language = segment.source_language();
    let source_is_unknown = source_language == "und";
    // Identity commitment stays strict: the durable language remains `und`
    // until the provider commits it. The unambiguous pending language is only
    // surfaced as a display hint so live captions can enter their lane
    // without waiting for that commitment.
    let provisional_source_language = source_is_unknown
        .then(|| normalized_optional_language(segment.matching_source_language()))
        .flatten();
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
    // Inline translation is causally attached to this canonical source
    // segment. A provider replacement that withdraws the entire speculative
    // source must withdraw its still-Partial inline translation in the same
    // transaction. Independent auxiliary lanes live outside this assembler.
    let translated_text = (!source_text.is_empty() && translation_is_pairable)
        .then(|| segment.translated.text(include_pending_translation))
        .filter(|text| !text.is_empty());
    let translated_language = translated_text
        .as_ref()
        .and(translated_language_candidate)
        .map(str::to_string);
    let source_completion = if segment.complete
        && !segment.source.committed.is_empty()
        && segment.source.pending.is_empty()
    {
        UtteranceCompletion::Complete
    } else {
        UtteranceCompletion::Partial
    };
    let translation_completion = translated_text.as_ref().map(|_| {
        if !source_text.is_empty()
            && segment.complete
            && !segment.translated.committed.is_empty()
            && segment.translated.pending.is_empty()
        {
            UtteranceCompletion::Complete
        } else {
            UtteranceCompletion::Partial
        }
    });
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
    let translation_clear_language = (translation_dirty && translated_text.is_none())
        .then(|| segment.persisted_translation_language.clone())
        .flatten();
    let remove_partial = segment.revision.is_some() && source_text.is_empty();
    AssembledRealtimeUtterance {
        utterance: NewRealtimeUtterance {
            id: segment.id.clone(),
            session_id: session_id.to_string(),
            sequence: segment.sequence,
            session_speaker_id: None,
            source_language,
            source_text,
            source_start_ms,
            source_end_ms,
            translated_language,
            translated_text,
            completion: source_completion,
            alignment,
        },
        provisional_source_language,
        source_dirty,
        translation_dirty,
        translation_completion,
        translation_clear_language,
        remove_partial,
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

/// A purge directory is a relative, non-escaping path whose final component is
/// the purged session id, such as `audio/<session_id>`. Rejecting absolute
/// paths, `..`, and any directory that is not session-scoped keeps a corrupted
/// or hand-edited durable purge plan from escalating a recursive removal into
/// deleting a shared parent like `audio`.
fn require_session_scoped_artifact_dir(value: &str, session_id: &str) -> Result<(), CoreError> {
    let path = std::path::Path::new(value);
    let is_safe = !value.is_empty()
        && path.is_relative()
        && path.components().all(
            |component| matches!(component, std::path::Component::Normal(name) if !name.is_empty()),
        )
        && path.file_name().and_then(|name| name.to_str()) == Some(session_id);
    if !is_safe {
        return Err(CoreError::ValidationFailed {
            message: format!("invalid canonical capture artifact directory: {value}"),
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

pub(crate) struct ActiveNotebookCapture {
    pub(crate) notebook_id: String,
    pub(crate) session_id: String,
    pub(crate) run_id: String,
    pub(crate) profile: NotebookCaptureProfile,
    pub(crate) state: CaptureState,
    pub(crate) callback: CaptureCallbackSink,
    pub(crate) journal: vt_pipeline::CaptureAudioJournal,
    pub(crate) last_persisted_frames: u64,
    pub(crate) captured_frames: Arc<AtomicU64>,
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
    /// Lanes receive a credential source rather than a key so the stream can
    /// resolve one per connection. A saved personal key answers from memory;
    /// a community invitation answers with a single-use key per connection.
    fn start(
        &self,
        endpoint: &str,
        credential: std::sync::Arc<dyn vt_stt::LaneCredentialSource>,
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
        credential: std::sync::Arc<dyn vt_stt::LaneCredentialSource>,
        config: SttConfig,
        cancel: tokio_util::sync::CancellationToken,
    ) -> SonioxStreamRuntime {
        SonioxStreamClient::start_with_credential(endpoint, credential, config, cancel)
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

pub(crate) struct ActiveRemoteStream {
    descriptor: RemoteStreamLane,
    pub(crate) audio_tx: tokio::sync::mpsc::Sender<Vec<u8>>,
    pub(crate) control_tx: tokio::sync::mpsc::Sender<vt_stt::SttStreamControl>,
    pub(crate) stream_task: tokio::task::JoinHandle<Result<(), vt_stt::SttError>>,
    pub(crate) forward_task: tokio::task::JoinHandle<()>,
    lane_cancel: tokio_util::sync::CancellationToken,
    input_discontinuity_reported: std::sync::atomic::AtomicBool,
}

#[derive(Debug, Default, PartialEq, Eq)]
struct PcmFanoutReport {
    auxiliary_discontinuities: Vec<String>,
}

pub(crate) struct ActiveRemoteCapture {
    pub(crate) stream_factory: Arc<dyn NotebookSonioxStreamFactory>,
    pub(crate) streams: Vec<ActiveRemoteStream>,
    pub(crate) cancel: tokio_util::sync::CancellationToken,
    pub(crate) event_task: tokio::task::JoinHandle<Result<(), ProviderFailure>>,
    discontinuity_tx: tokio::sync::mpsc::UnboundedSender<TaggedStreamEvent>,
}

impl ActiveRemoteCapture {
    /// Audio keeps flowing as long as the canonical lane can take it.
    ///
    /// A dead auxiliary lane is stopped and reported as discontinuous without
    /// stopping the room. It is never allowed to resume on the same provider
    /// timeline after missing a block, which would silently compress time.
    fn try_fanout_pcm(&self, audio_data: &[u8]) -> Result<PcmFanoutReport, String> {
        if self.streams.is_empty() {
            return Err("Soniox stream group audio unavailable".to_string());
        }
        if self.cancel.is_cancelled() {
            return Err("Soniox stream group audio unavailable".to_string());
        }
        let mut report = PcmFanoutReport::default();
        let mut canonical_failure = None;
        for (lane_index, stream) in self.streams.iter().enumerate() {
            if stream.lane_cancel.is_cancelled() {
                continue;
            }
            let unusable = stream.audio_tx.is_closed() || stream.audio_tx.capacity() == 0;
            let send_failure = if unusable {
                Some("Soniox stream audio channel unavailable".to_string())
            } else {
                self.stream_factory
                    .try_send_pcm(&stream.audio_tx, audio_data.to_vec())
                    .err()
            };
            let Some(send_failure) = send_failure else {
                continue;
            };
            if stream.descriptor.canonical {
                canonical_failure.get_or_insert(send_failure);
                // Keep iterating: every later healthy sibling must still get
                // this exact block even though the group will then fail.
                continue;
            }
            match self.isolate_auxiliary_discontinuity(lane_index, stream) {
                Ok(Some(target_language)) => {
                    report
                        .auxiliary_discontinuities
                        .push(target_language.clone());
                    tracing::warn!(
                        target_language,
                        error = %send_failure,
                        "auxiliary PCM lane became discontinuous and was stopped at the live edge"
                    );
                }
                Ok(None) => {}
                Err(error) => {
                    canonical_failure.get_or_insert(error);
                }
            }
        }
        match canonical_failure {
            Some(error) => Err(error),
            None => Ok(report),
        }
    }

    fn try_fanout_control(&self, control: SttStreamControl) -> Result<(), String> {
        if self.streams.is_empty() {
            return Err("Soniox stream group control unavailable".to_string());
        }
        if self.cancel.is_cancelled() {
            return Err("Soniox stream group control unavailable".to_string());
        }
        let mut canonical_failure = None;
        for (lane_index, stream) in self.streams.iter().enumerate() {
            if stream.lane_cancel.is_cancelled() {
                continue;
            }
            let unusable = stream.control_tx.is_closed() || stream.control_tx.capacity() == 0;
            let send_failure = if unusable {
                Some("Soniox stream control channel unavailable".to_string())
            } else {
                stream
                    .control_tx
                    .try_send(control)
                    .err()
                    .map(|error| error.to_string())
            };
            let Some(send_failure) = send_failure else {
                continue;
            };
            if stream.descriptor.canonical {
                canonical_failure.get_or_insert(send_failure);
                continue;
            }
            match self.isolate_auxiliary_discontinuity(lane_index, stream) {
                Ok(Some(target_language)) => tracing::warn!(
                    target_language,
                    control = ?control,
                    error = %send_failure,
                    "auxiliary control failure stopped the lane before its timeline could diverge"
                ),
                Ok(None) => {}
                Err(error) => {
                    canonical_failure.get_or_insert(error);
                }
            }
        }
        match canonical_failure {
            Some(error) => Err(error),
            None => Ok(()),
        }
    }

    fn isolate_auxiliary_discontinuity(
        &self,
        lane_index: usize,
        stream: &ActiveRemoteStream,
    ) -> Result<Option<String>, String> {
        debug_assert!(!stream.descriptor.canonical);
        let first_report = !stream
            .input_discontinuity_reported
            .swap(true, Ordering::AcqRel);
        stream.lane_cancel.cancel();
        if !first_report {
            return Ok(None);
        }
        let target_language = stream
            .descriptor
            .target_language
            .clone()
            .unwrap_or_else(|| "und".to_string());
        // An unbounded control channel is deliberate: this is one terminal
        // fact per lane, not transcript data, and it must be deliverable
        // precisely when the bounded data path is full.
        self.discontinuity_tx
            .send(TaggedStreamEvent {
                lane_index,
                event: SttStreamEvent::InputDiscontinuity,
            })
            .map_err(|_| {
                "Soniox collector unavailable while reporting auxiliary discontinuity".to_string()
            })?;
        Ok(Some(target_language))
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

    /// Routes capture lanes through the app for a single-use credential per
    /// connection. Install this while a community invitation is the credential
    /// source; clear it to go back to the saved personal key.
    pub fn set_lane_credential_requester(
        &self,
        requester: Option<Box<dyn crate::lane_credential_api::FfiLaneCredentialRequester>>,
    ) {
        let broker = requester.map(|requester| {
            crate::lane_credential_api::LaneCredentialBroker::new(Arc::from(requester))
        });
        *self.lane_credential_broker.lock().unwrap() = broker;
    }

    /// Answers a pending credential request with a freshly fetched key.
    pub fn fulfill_lane_credential(&self, request_id: String, api_key: String) {
        let broker = self.lane_credential_broker.lock().unwrap().clone();
        if let Some(broker) = broker {
            broker.fulfill(&request_id, api_key);
        }
    }

    /// Reports that a credential request cannot be answered. `terminal` marks
    /// a refusal the lane must not retry (invitation spent, budget exhausted)
    /// as opposed to a transient failure worth a reconnect.
    pub fn fail_lane_credential(&self, request_id: String, message: String, terminal: bool) {
        let broker = self.lane_credential_broker.lock().unwrap().clone();
        if let Some(broker) = broker {
            broker.fail(&request_id, message, terminal);
        }
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

    /// Lists active Library Packs without requiring a Notebook selection.
    pub fn list_library_context_packs(&self) -> Result<Vec<FfiContextPackInfo>, CoreError> {
        self.context_pack_store
            .list_library_packs()
            .map(|packs| {
                packs
                    .into_iter()
                    .map(|pack| context_pack_info(pack, None))
                    .collect()
            })
            .map_err(store_error)
    }

    /// Reads one active Library Pack as editable, human-readable JSON. Empty
    /// `sources` are valid here even though explicit file export rejects them.
    pub fn read_library_context_pack(&self, pack_id: String) -> Result<String, CoreError> {
        let document = self
            .context_pack_store
            .read_library_pack_document(&pack_id)
            .map_err(store_error)?;
        serde_json::to_string_pretty(&document).map_err(|error| CoreError::InternalError {
            message: format!("serialize editable Context Pack document: {error}"),
        })
    }

    /// Replaces one active Library Pack's title and sources from editable JSON
    /// while retaining its identity and Notebook bindings.
    pub fn replace_library_context_pack(
        &self,
        pack_id: String,
        expected_revision: u64,
        document_json: String,
    ) -> Result<FfiContextPackInfo, CoreError> {
        if document_json.len() > CONTEXT_PACK_DOCUMENT_MAX_BYTES {
            return Err(CoreError::ValidationFailed {
                message: format!(
                    "Context Pack document exceeds the {}-byte safety limit",
                    CONTEXT_PACK_DOCUMENT_MAX_BYTES
                ),
            });
        }
        let document: ContextPackDocument =
            serde_json::from_str(&document_json).map_err(|error| CoreError::ValidationFailed {
                message: format!("this is not a Zulangue Context Pack document: {error}"),
            })?;
        self.context_pack_store
            .replace_library_pack_document(&pack_id, expected_revision, &document)
            .map(|pack| context_pack_info(pack, None))
            .map_err(store_error)
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

    /// Writes a whole Context Pack to one shareable JSON file. The file is
    /// plaintext — it has left the Pack's encryption boundary — so this only
    /// runs on an explicit user export.
    pub fn export_context_pack(
        &self,
        notebook_id: String,
        pack_id: String,
        destination_path: String,
    ) -> Result<u32, CoreError> {
        require_context_pack_access(&self.context_pack_store, &notebook_id, &pack_id)?;
        let document = self
            .context_pack_store
            .export_pack_document(&pack_id)
            .map_err(store_error)?;
        let serialized =
            serde_json::to_string_pretty(&document).map_err(|error| CoreError::InternalError {
                message: format!("serialize Context Pack document: {error}"),
            })?;
        std::fs::write(&destination_path, serialized).map_err(|error| {
            CoreError::ValidationFailed {
                message: format!("write Context Pack file: {error}"),
            }
        })?;
        u32::try_from(document.sources.len()).map_err(|_| CoreError::InternalError {
            message: "Context Pack source count overflowed".to_string(),
        })
    }

    /// Reads a Pack file exported by `export_context_pack` and materializes it
    /// as a new Library Pack with a fresh ID and a fresh key.
    pub fn import_context_pack(
        &self,
        source_path: String,
        title_override: Option<String>,
    ) -> Result<FfiContextPackInfo, CoreError> {
        let path = std::path::PathBuf::from(&source_path);
        let file = std::fs::File::open(&path).map_err(|error| CoreError::ValidationFailed {
            message: format!("open Context Pack file: {error}"),
        })?;
        let metadata = file
            .metadata()
            .map_err(|error| CoreError::ValidationFailed {
                message: format!("inspect Context Pack file: {error}"),
            })?;
        let limit = CONTEXT_PACK_DOCUMENT_MAX_BYTES as u64;
        if !metadata.is_file() || metadata.len() > limit {
            return Err(CoreError::ValidationFailed {
                message: format!("Context Pack file exceeds the {limit}-byte safety limit"),
            });
        }
        let mut raw = Vec::with_capacity(metadata.len() as usize);
        file.take(limit + 1)
            .read_to_end(&mut raw)
            .map_err(|error| CoreError::ValidationFailed {
                message: format!("read Context Pack file: {error}"),
            })?;
        if raw.len() as u64 > limit {
            return Err(CoreError::ValidationFailed {
                message: format!("Context Pack file exceeds the {limit}-byte safety limit"),
            });
        }
        let document: ContextPackDocument =
            serde_json::from_slice(&raw).map_err(|error| CoreError::ValidationFailed {
                message: format!("this is not a Zulangue Context Pack file: {error}"),
            })?;
        let title_override = title_override
            .as_deref()
            .map(str::trim)
            .filter(|value| !value.is_empty());
        self.context_pack_store
            .import_pack_document(&document, title_override)
            .map(|pack| context_pack_info(pack, None))
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
        let callback = CaptureCallbackSink::new(
            callback,
            (*self.notebook_capture_store).clone(),
            Some(crate::share_api::ShareCaptionTap::new(
                self.share_runtime.clone(),
            )),
        )?;

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
        let journal_path = vt_pipeline::session_capture_journal_path(&self.data_dir, &session_id);
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
        let captured_frames = Arc::new(AtomicU64::new(0));
        let remote = if requested_remote {
            match self.start_soniox_capture_runtime(
                &run_id,
                &session_id,
                &profile,
                context_compilation.as_ref(),
                captured_frames.clone(),
                callback.clone(),
            ) {
                Ok(remote) => Some(remote),
                Err(error) => {
                    tracing::warn!(session_id, %error, "Soniox unavailable; local capture continues");
                    let failure = ProviderFailure {
                        error_type: "unavailable".to_string(),
                        request_id: None,
                    };
                    if let Err(persistence_error) = self
                        .notebook_capture_store
                        .update_remote_health(&run_id, RemoteHealth::Unavailable, Some(&failure))
                    {
                        // Without either a provider owner or a durable
                        // Unavailable fact, installing an active capture would
                        // create `remote=None + Connecting`. Fail the start
                        // before publishing ownership and use the existing
                        // durable rollback saga.
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
                        return Err(CoreError::InternalError {
                            message: format!(
                                "Soniox unavailable ({error}); persist unavailable remote truth: {persistence_error}"
                            ),
                        });
                    }
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
            captured_frames,
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
        active_guard
            .as_ref()
            .expect("active capture was checked above")
            .captured_frames
            .store(frames, Ordering::Release);
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
            let fanout_result = remote.try_fanout_pcm(&audio_data);
            match fanout_result {
                Err(_) => {
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
                }
                Ok(report) => {
                    if !report.auxiliary_discontinuities.is_empty() {
                        tracing::warn!(
                            languages = ?report.auxiliary_discontinuities,
                            "capture remains live after isolating discontinuous translation lanes"
                        );
                    }
                    active_guard
                        .as_mut()
                        .expect("active capture was checked above")
                        .remote = Some(remote);
                }
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

        {
            let active = active_guard
                .as_ref()
                .filter(|active| active.session_id == session_id)
                .ok_or_else(|| CoreError::ValidationFailed {
                    message: format!("capture_not_active: {session_id}"),
                })?;
            if active.state != expected {
                return Err(CoreError::ValidationFailed {
                    message: format!("capture pause transition requires {expected:?}"),
                });
            }
        }

        // A requested remote profile with no process-local provider owner must
        // never silently cross Paused -> Recording while SQLite still says
        // Live/Connecting. Persist the missing-provider truth first. A failed
        // resume preflight leaves the already-durable Paused state untouched;
        // a pause still commits locally and keeps a process-only UI overlay.
        let missing_remote = {
            let active = active_guard
                .as_ref()
                .expect("active capture was checked above");
            active.profile.remote_realtime_enabled && active.remote.is_none()
        };
        if missing_remote {
            let (run_id, callback) = {
                let active = active_guard
                    .as_ref()
                    .expect("active capture was checked above");
                (active.run_id.clone(), active.callback.clone())
            };
            let durable = self
                .notebook_capture_store
                .get_run(&run_id)
                .map_err(store_error)?
                .ok_or_else(|| CoreError::NotFound {
                    message: format!("capture run {run_id}"),
                })?;
            if matches!(
                durable.remote_health,
                RemoteHealth::Degraded | RemoteHealth::Unavailable
            ) {
                callback.clear_remote_truth_overlay(&session_id);
            } else {
                let overlay = callback
                    .remote_truth_overlay(&session_id)
                    .unwrap_or_else(|| {
                        let (health, failure) = missing_remote_truth(&durable);
                        CaptureRemoteTruthOverlay {
                            session_id: session_id.clone(),
                            health,
                            failure,
                        }
                    });
                callback.set_remote_truth_overlay(
                    &session_id,
                    overlay.health,
                    overlay.failure.clone(),
                );
                match self.notebook_capture_store.update_remote_health(
                    &run_id,
                    overlay.health,
                    Some(&overlay.failure),
                ) {
                    Ok(_) => callback.clear_remote_truth_overlay(&session_id),
                    Err(persistence_error) if !paused => {
                        tracing::warn!(
                            session_id,
                            run_id,
                            error = %persistence_error,
                            "resume remains paused until missing remote truth is durable"
                        );
                        return Err(CoreError::InternalError {
                            message: format!(
                                "persist missing remote health before resume: {persistence_error}"
                            ),
                        });
                    }
                    Err(persistence_error) => {
                        tracing::warn!(
                            session_id,
                            run_id,
                            error = %persistence_error,
                            "pause will use process-local remote truth until durable reconciliation"
                        );
                    }
                }
            }
        }

        let run_id = active_guard
            .as_ref()
            .expect("active capture was checked above")
            .run_id
            .clone();
        let mut run = self
            .notebook_capture_store
            .transition_capture(&run_id, expected, next)
            .map_err(store_error)?;
        active_guard
            .as_mut()
            .expect("active capture was checked above")
            .state = next;
        let remote = active_guard
            .as_mut()
            .expect("active capture was checked above")
            .remote
            .take();
        if let Some(remote) = remote {
            if let Err(control_error) = remote.try_fanout_control(control) {
                let mut failure = ProviderFailure {
                    error_type: "control_unavailable".to_string(),
                    request_id: None,
                };
                if let Some(shutdown_failure) = self.shutdown_failed_remote_capture(remote) {
                    failure = prefer_provider_failure(Some(failure), shutdown_failure)
                        .expect("a provider failure was supplied");
                }
                let callback = active_guard
                    .as_ref()
                    .expect("active capture was checked above")
                    .callback
                    .clone();
                callback.set_remote_truth_overlay(
                    &session_id,
                    RemoteHealth::Degraded,
                    failure.clone(),
                );
                match self.notebook_capture_store.update_remote_health(
                    &run_id,
                    RemoteHealth::Degraded,
                    Some(&failure),
                ) {
                    Ok(updated) => {
                        callback.clear_remote_truth_overlay(&session_id);
                        run = updated;
                    }
                    Err(persistence_error) if !paused => {
                        // Resume already crossed its state CAS before the
                        // provider control failure was known. Roll it back so
                        // missing remote truth can be retried while Paused.
                        match self.notebook_capture_store.transition_capture(
                            &run_id,
                            CaptureState::Recording,
                            CaptureState::Paused,
                        ) {
                            Ok(rolled_back) => {
                                active_guard
                                    .as_mut()
                                    .expect("active capture was checked above")
                                    .state = CaptureState::Paused;
                                callback.send(event_from_run(rolled_back, Vec::new(), false));
                                return Err(CoreError::InternalError {
                                    message: format!(
                                        "resume provider control failed ({control_error}); persist degraded remote health: {persistence_error}"
                                    ),
                                });
                            }
                            Err(rollback_error) => {
                                let failed = active_guard
                                    .take()
                                    .expect("active capture was checked above");
                                let terminal_error = self.terminate_capture_after_push_error(
                                    &session_id,
                                    failed,
                                    "rollback resume after remote truth persistence failure",
                                    format!(
                                        "control={control_error}; health={persistence_error}; rollback={rollback_error}"
                                    ),
                                );
                                drop(active_guard);
                                return Err(terminal_error);
                            }
                        }
                    }
                    Err(persistence_error) => {
                        // The capture-state CAS above is the pause/resume
                        // command's commit point. Keep Pause successful and
                        // surface Degraded through the process-only callback
                        // overlay until a later preflight can persist it.
                        tracing::warn!(
                            session_id,
                            run_id,
                            error = %persistence_error,
                            control_error = %control_error,
                            "pause control degraded after state commit; using process-local remote truth"
                        );
                    }
                }
            } else {
                active_guard
                    .as_mut()
                    .expect("active capture was checked above")
                    .remote = Some(remote);
            }
        }
        let callback = active_guard
            .as_ref()
            .expect("active capture was checked above")
            .callback
            .clone();
        let event = callback.send(event_from_run(run, Vec::new(), false));
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
            let active = guard.take().expect("active capture checked above");
            // Atomically hand the process-local owner to the detached-recovery
            // registry before releasing the active-capture mutex. A second
            // Core may read the same database, so durable `draining` alone is
            // not sufficient proof that this process owns recovery.
            self.detached_notebook_capture_runs
                .lock()
                .unwrap()
                .insert(active.run_id.clone());
            (active, draining)
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
        self.detached_notebook_capture_runs
            .lock()
            .unwrap()
            .remove(&active.run_id);

        let completed_run = self
            .notebook_capture_store
            .get_run(&active.run_id)
            .map_err(store_error)?
            .ok_or_else(|| CoreError::NotFound {
                message: format!("capture run {}", active.run_id),
            })?;
        if let Some(error) = remote_failure_persistence_error {
            // The remote-health write is diagnostic metadata in a separate
            // error domain. Audio and Final machine facts are already durable,
            // so it must never suppress their independent Loro projection.
            tracing::warn!(
                session_id,
                error,
                "capture stopped; remote shutdown diagnostics were not persisted"
            );
        }
        // Auxiliary translation facts that lost their binding while the
        // capture was live (ambiguity, contested lane) get one final
        // best-evidence pass now that every canonical Final row is durable.
        // The run is already terminal, so ambiguity keeps facts unbound
        // rather than delaying the stop.
        match self
            .notebook_capture_store
            .reconcile_translation_inbox_after_recovery(&session_id)
        {
            Ok(0) => {}
            Ok(bound) => tracing::info!(
                session_id,
                bound,
                "stop bound remaining auxiliary translation facts"
            ),
            Err(error) => tracing::warn!(
                session_id,
                error = %error,
                "stop left ambiguous auxiliary translation facts durably unbound"
            ),
        }
        let projection_result = self.project_notebook_capture_with_ownership(&active.run_id);
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
        if let Err(projection_error) = projection_result {
            // Audio, capture state, and transcript facts are already durable.
            // A Loro failure is a separately retryable projection outcome, not
            // a failed stop command. The terminal event carries Failed so the
            // UI can offer retry without lying about recording state.
            tracing::warn!(
                session_id,
                error = %projection_error,
                "capture stopped durably; realtime Loro projection remains retryable"
            );
        }
        retention_result?;
        Ok(event)
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
        let active = {
            let mut guard = self.active_notebook_capture.lock().unwrap();
            let Some(active) = guard.as_ref() else {
                drop(guard);
                // A failed Stop can remove its process owner after committing
                // `draining`. The internal helper requires this Core's atomic
                // handoff marker and never attributes the caller's reason.
                return self.recover_ownerless_notebook_capture_after_stop_failure(&session_id);
            };
            if active.session_id != session_id {
                return Err(CoreError::ValidationFailed {
                    message: format!("capture_not_active: {session_id}"),
                });
            }
            if !matches!(active.state, CaptureState::Recording | CaptureState::Paused) {
                return Err(CoreError::ValidationFailed {
                    message: format!(
                        "capture interruption requires recording or paused, found {:?}",
                        active.state
                    ),
                });
            }
            guard.take().expect("active capture checked above")
        };
        let mut active = active;
        let mut failure = match reason {
            FfiNotebookCaptureInterruptReason::LocalAudioOverflow => ProviderFailure {
                error_type: "local_audio_overflow".to_string(),
                request_id: None,
            },
            FfiNotebookCaptureInterruptReason::LocalAudioUnavailable => ProviderFailure {
                error_type: "local_audio_unavailable".to_string(),
                request_id: None,
            },
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

    /// Lists recording blocks without crossing every transcript row over FFI.
    /// A selected block is hydrated separately through
    /// `list_notebook_capture_history_utterances`.
    pub fn list_notebook_capture_history_summaries(
        &self,
        notebook_id: String,
    ) -> Result<Vec<FfiNotebookCaptureHistoryRun>, CoreError> {
        self.notebook_capture_store
            .list_notebook_capture_history_summaries(&notebook_id)
            .map(|runs| runs.into_iter().map(Into::into).collect())
            .map_err(store_error)
    }

    /// Hydrates one selected history block while revalidating that the session
    /// still belongs to a visible, non-purging run in this Notebook.
    pub fn list_notebook_capture_history_utterances(
        &self,
        notebook_id: String,
        session_id: String,
    ) -> Result<Vec<FfiNotebookCaptureUtterance>, CoreError> {
        self.notebook_capture_store
            .list_visible_notebook_utterances(&notebook_id, &session_id)
            .map(|values| values.into_iter().map(Into::into).collect())
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
        // Post-stop transcription is also the repair path for locally
        // preserved network gaps. Capture mode controls realtime presentation,
        // not whether durable source audio may later be converted to text.
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
        let active_callback = self
            .active_notebook_capture
            .lock()
            .unwrap()
            .as_ref()
            .filter(|active| active.session_id == session_id)
            .map(|active| active.callback.clone());
        if let Some(callback) = active_callback {
            // Serialize this explicit read with callback publication and the
            // process-local remote-truth overlay. The overlay is not durable;
            // it only prevents an acknowledged Paused owner whose provider
            // teardown outlived a failed diagnostic write from being reported
            // as Live before startup recovery or a later retry converges it.
            return callback.full_snapshot_with_remote_truth(&session_id);
        }
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

    /// Incrementally materializes every durable completed utterance into the
    /// realtime transcript document without completing the capture projection.
    /// Since the cutover this writes the epoch-2 block document.
    pub fn project_notebook_realtime_incremental(
        &self,
        session_id: String,
    ) -> Result<(), CoreError> {
        let run = self
            .notebook_capture_store
            .get_run_for_session(&session_id)
            .map_err(store_error)?
            .ok_or_else(|| CoreError::NotFound {
                message: format!("capture session {session_id}"),
            })?;
        self.ensure_capture_projection_not_purging(&run.session_id)?;
        self.sync_capture_into_t2_transcript(&run, false)
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
        self.validated_utterance_for_lane_replacement(&utterance_id, &lane_language)?;
        // Do not synchronously chase unrelated pending Finals here. The store
        // authorizes this exact target lane only when its projection revision
        // is already <= the durable applied watermark. A newer language lane
        // may remain pending/failed without re-locking this editable lane or
        // forcing the UI edit path through a projection fsync.
        let _mutation_guard = crate::editor_api::editor_document_mutation_guard();
        let mutation = self
            .notebook_capture_store
            .stage_utterance_variant_replacement(
                &utterance_id,
                &lane_language,
                &text,
                expected_revision,
            )
            .map_err(store_error)?;
        self.apply_notebook_projection_mutation_t2(&mutation)
            .map(Into::into)
    }
}

impl ZulangueCore {
    /// Shared pre-staging validation for a user lane replacement: the
    /// utterance and its run must exist and the target lane must be a
    /// complete, Ready variant. Both document epochs use this unchanged —
    /// editability is a SQLite fact, not a document-shape fact.
    fn validated_utterance_for_lane_replacement(
        &self,
        utterance_id: &str,
        lane_language: &str,
    ) -> Result<RealtimeUtterance, CoreError> {
        let current = self
            .notebook_capture_store
            .get_machine_utterance_by_id(utterance_id)
            .map_err(store_error)?;
        let current = current.ok_or_else(|| CoreError::NotFound {
            message: format!("utterance {utterance_id}"),
        })?;
        let normalized_lane_language = normalize_language(lane_language);
        let source_variant = current.variants.iter().find(|variant| {
            variant.role == UtteranceVariantRole::Source
                && normalize_language(&variant.language) == normalized_lane_language
        });
        if let Some(source_variant) = source_variant {
            if source_variant.state != UtteranceVariantState::Ready
                || source_variant.completion != Some(UtteranceCompletion::Complete)
                || source_variant.text.is_none()
            {
                return Err(CoreError::ValidationFailed {
                    message: format!(
                        "source lane {lane_language} on {utterance_id} is partial and cannot be edited"
                    ),
                });
            }
        } else if let Some(variant) = current.variants.iter().find(|variant| {
            variant.role == UtteranceVariantRole::Translation
                && normalize_language(&variant.language) == normalized_lane_language
        }) {
            if variant.state != UtteranceVariantState::Ready
                || variant.completion != Some(UtteranceCompletion::Complete)
                || variant.text.is_none()
            {
                return Err(CoreError::ValidationFailed {
                    message: format!(
                        "translation lane {lane_language} on {utterance_id} is not complete and cannot be edited"
                    ),
                });
            }
        } else {
            return Err(CoreError::ValidationFailed {
                message: format!("lane language {lane_language} is not present on {utterance_id}"),
            });
        }
        self.notebook_capture_store
            .get_run_for_session(&current.session_id)
            .map_err(store_error)?
            .ok_or_else(|| CoreError::NotFound {
                message: format!("capture session {}", current.session_id),
            })?;
        Ok(current)
    }
}

impl ZulangueCore {
    /// Converges a run whose Stop command has already removed every
    /// process-local owner but failed before its terminal state was durable.
    /// Holding `capture_ownership_gate` and requiring the atomic detached
    /// marker prevents an in-flight Stop or another Core from being mistaken
    /// for an ownerless run.
    fn recover_ownerless_notebook_capture_after_stop_failure(
        &self,
        session_id: &str,
    ) -> Result<FfiNotebookCaptureEvent, CoreError> {
        let run = self
            .notebook_capture_store
            .get_run_for_session(session_id)
            .map_err(store_error)?
            .ok_or_else(|| CoreError::ValidationFailed {
                message: format!("capture_not_active: {session_id}"),
            })?;
        let was_registered = self
            .detached_notebook_capture_runs
            .lock()
            .unwrap()
            .contains(&run.id);
        if !was_registered {
            return Err(CoreError::ValidationFailed {
                message: format!("capture_not_active: {session_id}"),
            });
        }

        self.recover_registered_detached_notebook_capture(&run.id)?;
        self.capture_event_for_run(&run.id)
    }

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
            self.recover_registered_detached_notebook_capture(&run_id)?;
        }
        Ok(())
    }

    fn recover_registered_detached_notebook_capture(&self, run_id: &str) -> Result<(), CoreError> {
        let recovered = match self
            .notebook_capture_store
            .recover_detached_unfinished_run(run_id)
        {
            Ok(run) => run,
            Err(vt_store::notebook_capture_store::NotebookCaptureStoreError::NotFound(_)) => {
                self.detached_notebook_capture_runs
                    .lock()
                    .unwrap()
                    .remove(run_id);
                return Ok(());
            }
            Err(error) => {
                return Err(CoreError::InternalError {
                    message: format!(
                        "detached_capture_recovery_pending: run {run_id} remains unavailable: {error}"
                    ),
                });
            }
        };

        // A previous teardown may have synced the encrypted journal but
        // failed before indexing it. Once Interrupted is durable, an audio
        // recovery failure must not keep the capture slot wedged: retain the
        // marker, return the terminal event, and retry later.
        if recovered.capture_state == CaptureState::Interrupted {
            if let Err(error) = crate::recover_interrupted_capture_audio_run(
                &self.data_dir,
                &self.notebook_capture_store,
                self.key_store.as_ref(),
                &self.session_meta,
                &self.session_store,
                run_id,
            ) {
                tracing::warn!(
                    run_id,
                    %error,
                    "detached capture is terminal; audio recovery remains retryable"
                );
                return Ok(());
            }
        }
        self.detached_notebook_capture_runs
            .lock()
            .unwrap()
            .remove(run_id);
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
                // Stop has already removed the journal/provider owner. Keep a
                // process-local recovery marker so either the Swift fallback
                // or the next Start can neutrally converge the durable row.
                self.detached_notebook_capture_runs
                    .lock()
                    .unwrap()
                    .insert(run_id.to_string());
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
                if let Err(recovery_error) =
                    self.recover_registered_detached_notebook_capture(run_id)
                {
                    return CoreError::InternalError {
                        message: format!(
                            "{detail}; recover detached interrupted capture: {recovery_error}"
                        ),
                    };
                }
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

    /// Whether a purge target is the Realtime Transcript tab — the one
    /// document family the T2 cutover moved to epoch-2 blocks. Async
    /// transcript and note targets keep the legacy flat-text purge route
    /// byte-for-byte. A tab that can no longer be resolved falls back to
    /// the legacy route, which fails closed on missing anchors.
    fn is_realtime_transcript_purge_target(
        &self,
        target: &vt_store::notebook_capture_store::ProjectionPurgeTarget,
    ) -> Result<bool, CoreError> {
        use vt_store::BuiltinNotebookTab;
        Ok(self
            .notebook_store
            .list_tabs(&target.notebook_id)
            .map_err(store_error)?
            .into_iter()
            .any(|tab| {
                tab.id == target.tab_id
                    && tab.builtin_kind == BuiltinNotebookTab::RealtimeTranscript
            }))
    }

    /// T2 destroy chain for one realtime transcript target: open-or-migrate
    /// (a refused migration keeps the durable purge job pending — the strict
    /// channel's fail-closed twin of "a corrupt snapshot never absorbs a
    /// purge"), then delete the session's machine blocks and set the purge
    /// receipt on the same document. Deletion and receipt are two commits;
    /// a crash between them replays as a zero-block deletion plus the
    /// receipt write, so the pair converges without a rollback point.
    fn purge_t2_transcript_target(
        &self,
        plan: &SessionPurgePlan,
        target: &vt_store::notebook_capture_store::ProjectionPurgeTarget,
    ) -> Result<(), CoreError> {
        self.open_transcript_block_document(&target.doc_id)?;
        if self
            .editor_bridge
            .has_session_purge_receipt(&target.doc_id, &plan.session_id)
            .map_err(store_error)?
        {
            self.persist_block_document(&target.doc_id)?;
            return Ok(());
        }
        self.with_transcript(&target.doc_id, |projection| {
            projection
                .purge_session_blocks(&plan.session_id)
                .map_err(store_error)
        })?;
        self.editor_bridge
            .set_session_purge_receipt(&target.doc_id, &plan.session_id)
            .map_err(store_error)?;
        self.persist_block_document(&target.doc_id)
    }

    fn purge_loro_session_ranges(&self, plan: &SessionPurgePlan) -> Result<(), CoreError> {
        use vt_store::EditOp;
        let _mutation_guard = crate::editor_api::editor_document_mutation_guard();
        for target in &plan.projection_targets {
            if self.is_realtime_transcript_purge_target(target)? {
                self.purge_t2_transcript_target(plan, target)?;
                continue;
            }
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
            let range = legacy_session_section_range(&delta, &plan.session_id)?;
            let range = match range {
                Some(range) => range,
                None if self
                    .editor_bridge
                    .get_content(&target.doc_id)
                    .map_err(store_error)?
                    .is_empty() =>
                {
                    // A projection row is created before the first Final lane.
                    // An entirely empty document therefore proves there are no
                    // target bytes to delete; still persist the purge receipt
                    // so crash replay remains exact-once.
                    crate::editor_api::TextRange { pos: 0, len: 0 }
                }
                None => {
                    return Err(CoreError::ValidationFailed {
                        message: format!(
                            "session {} has a projection row in document {} but no durable ownership marks or purge receipt",
                            plan.session_id, target.doc_id
                        ),
                    });
                }
            };
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
        // Every remaining artifact this session owns lives under its own audio
        // directory, so one recursive removal replaces per-file bookkeeping and
        // also takes any abandoned `.recovering` temp file with it.
        for dir in &plan.canonical_artifact_dirs {
            require_session_scoped_artifact_dir(dir, &plan.session_id)?;
            let path = self.data_dir.join(dir);
            require_path_within_data_dir(&self.data_dir, &path)?;
            match std::fs::remove_dir_all(&path) {
                Ok(()) => {}
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                Err(error) => {
                    return Err(CoreError::InternalError {
                        message: format!(
                            "delete capture artifact directory {}: {error}",
                            path.display()
                        ),
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
            if self.is_realtime_transcript_purge_target(target)? {
                self.open_transcript_block_document(&target.doc_id)?;
                if self
                    .editor_bridge
                    .has_session_purge_receipt(&target.doc_id, &plan.session_id)
                    .map_err(store_error)?
                {
                    self.editor_bridge
                        .clear_session_purge_receipt(&target.doc_id, &plan.session_id)
                        .map_err(store_error)?;
                    self.persist_block_document(&target.doc_id)?;
                }
                continue;
            }
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
        captured_frames: Arc<AtomicU64>,
        callback: CaptureCallbackSink,
    ) -> Result<ActiveRemoteCapture, CoreError> {
        let engine = CURRENT_NOTEBOOK_CAPTURE_ENGINE;
        self.ensure_remote_provider_allowed_for_session(session_id, engine.provider_id)?;
        // A community invitation supplies a single-use key per connection
        // through the app, so there is no saved key to read. Everyone else
        // reads the one they configured, and its absence still fails the
        // start rather than opening keyless lanes.
        let lane_credential: Arc<dyn vt_stt::LaneCredentialSource> =
            match self.lane_credential_broker.lock().unwrap().clone() {
                Some(broker) => broker,
                None => vt_stt::StaticLaneCredential::new(
                    self.api_key_store
                        .get(engine.credential_scope)
                        .map_err(|error| CoreError::ValidationFailed {
                            message: format!("soniox_key_unavailable: {error}"),
                        })?,
                ),
            };
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
        let (discontinuity_tx, discontinuity_rx) = tokio::sync::mpsc::unbounded_channel();
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
                let lane_cancel = cancel.child_token();
                let stream = stream_factory.start(
                    engine.realtime_endpoint,
                    lane_credential.clone(),
                    config,
                    lane_cancel.clone(),
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
                    lane_cancel,
                    input_discontinuity_reported: std::sync::atomic::AtomicBool::new(false),
                });
            }
        }
        drop(tagged_tx);
        let lane_descriptors = streams
            .iter()
            .map(|stream| stream.descriptor.clone())
            .collect::<Vec<_>>();
        let lane_controls = streams
            .iter()
            .map(|stream| (!stream.descriptor.canonical).then(|| stream.control_tx.clone()))
            .collect::<Vec<_>>();
        let store = (*self.notebook_capture_store).clone();
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
                lane_controls,
                tagged_rx,
                discontinuity_rx,
                event_cancel,
                captured_frames,
                callback,
            )
            .await
        });
        Ok(ActiveRemoteCapture {
            stream_factory,
            streams,
            cancel,
            event_task,
            discontinuity_tx,
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
                .map(|stream| (stream.descriptor.canonical, stream.control_tx.clone()))
                .collect::<Vec<_>>();
            let finish_result = tokio::time::timeout_at(
                deadline,
                futures::future::join_all(finish_senders.into_iter().map(
                    |(canonical, sender)| async move {
                        (canonical, sender.send(SttStreamControl::Finish).await)
                    },
                )),
            )
            .await;
            // An auxiliary lane that already died cannot take a Finish and
            // has nothing left to drain; refusing to stop over it would
            // truncate the transcript tail of every lane that is still
            // healthy. Only the canonical control channel decides whether
            // the graceful drain can proceed.
            let finish_control_failure = match finish_result {
                Ok(results)
                    if results
                        .iter()
                        .all(|(canonical, result)| result.is_ok() || !*canonical) =>
                {
                    None
                }
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
        // Recover the machine projection watermark first. User mutations may
        // target a lane whose Final machine fact was committed immediately
        // before a crash but whose receipt was not yet acknowledged.
        let terminal_runs = self
            .notebook_capture_store
            .list_completed_runs()
            .map_err(store_error)?
            .into_iter()
            .chain(
                self.notebook_capture_store
                    .list_interrupted_runs()
                    .map_err(store_error)?,
            )
            .collect::<Vec<_>>();
        // The collector may crash after accepting an auxiliary Final into its
        // durable inbox but before the canonical binding transaction. Recovery
        // has already made these runs terminal, so consume only the pre-crash
        // inbox facts before discovering pending Loro watermarks.
        for run in &terminal_runs {
            if let Err(error) = self
                .notebook_capture_store
                .reconcile_translation_inbox_after_recovery(&run.session_id)
            {
                tracing::warn!(
                    session_id = %run.session_id,
                    error = %error,
                    "startup left ambiguous auxiliary translation facts durably unbound"
                );
            }
        }
        let mut realtime_sessions = std::collections::BTreeSet::new();
        for projection in self
            .notebook_capture_store
            .list_pending_realtime_loro_projections()
            .map_err(store_error)?
        {
            realtime_sessions.insert(projection.session_id);
        }
        let terminal_sessions = terminal_runs
            .iter()
            .map(|run| run.session_id.clone())
            .collect::<std::collections::BTreeSet<_>>();
        // A crash after the applied-watermark ACK but before Projecting ->
        // Ready leaves no pending outbox row. Include every recoverable
        // terminal run whose projection state is not yet Ready.
        for run in terminal_runs
            .iter()
            .filter(|run| run.projection_state != ProjectionState::Ready)
        {
            realtime_sessions.insert(run.session_id.clone());
        }
        for session_id in realtime_sessions {
            if let Err(error) = self.recover_notebook_realtime_projection(&session_id) {
                tracing::warn!(
                    session_id,
                    error = %error,
                    "startup isolated a failed realtime Loro projection; recovery continues"
                );
            }
        }

        let _mutation_guard = crate::editor_api::editor_document_mutation_guard();
        let pending = self
            .notebook_capture_store
            .list_pending_projection_mutations()
            .map_err(store_error)?;
        for mutation in pending {
            if let Err(error) = self.apply_notebook_projection_mutation_t2(&mutation) {
                tracing::warn!(
                    session_id = %mutation.session_id,
                    mutation_id = %mutation.id,
                    error = %error,
                    "startup isolated a failed capture lane mutation; recovery continues"
                );
            }
        }
        drop(_mutation_guard);

        // FTS is intentionally disposable, so it has no per-edit outbox. A
        // crash after the SQLite override commit but before its synchronous
        // rebuild is repaired here from the visible overlay. Limit the repair
        // to lanes at or below the durable applied watermark so an unrelated
        // async transcript index is never replaced by speculative realtime
        // text.
        for session_id in terminal_sessions {
            let repair_result = (|| -> Result<(), CoreError> {
                let run = self
                    .notebook_capture_store
                    .get_run_for_session(&session_id)
                    .map_err(store_error)?
                    .ok_or_else(|| CoreError::NotFound {
                        message: format!("capture session {session_id}"),
                    })?;
                let visible = self
                    .notebook_capture_store
                    .list_utterances(&session_id)
                    .map_err(store_error)?;
                let has_projected_lane = finalized_capture_lanes(&visible).iter().any(|lane| {
                    lane.revision > 0 && lane.revision <= run.realtime_loro_applied_revision
                });
                if has_projected_lane {
                    self.rebuild_finalized_capture_search_index_through(
                        &session_id,
                        &visible,
                        run.realtime_loro_applied_revision,
                    )?;
                }
                Ok(())
            })();
            if let Err(error) = repair_result {
                tracing::warn!(
                    session_id,
                    error = %error,
                    "startup isolated a failed capture FTS repair; recovery continues"
                );
            }
        }
        Ok(())
    }

    fn recover_notebook_realtime_projection(&self, session_id: &str) -> Result<(), CoreError> {
        let _ownership_guard = self.capture_ownership_gate.lock().unwrap();
        let mut run = self
            .notebook_capture_store
            .get_run_for_session(session_id)
            .map_err(store_error)?
            .ok_or_else(|| CoreError::NotFound {
                message: format!("capture session {session_id}"),
            })?;
        self.ensure_capture_projection_not_purging(session_id)?;

        if run.capture_state.is_active() {
            return self.sync_capture_into_t2_transcript(&run, false);
        }

        match run.projection_state {
            ProjectionState::Ready => {
                // A terminal run can already be Ready while a later durable
                // Final still has an unacknowledged realtime watermark.
                self.sync_capture_into_t2_transcript(&run, false)
            }
            ProjectionState::Failed => {
                run = self
                    .notebook_capture_store
                    .retry_projection(&run.id)
                    .map_err(store_error)?;
                self.project_notebook_capture_with_ownership(&run.id)
            }
            ProjectionState::Pending => self.project_notebook_capture_with_ownership(&run.id),
            ProjectionState::Projecting => Err(CoreError::ValidationFailed {
                message: format!(
                    "capture projection {} remained Projecting after startup recovery",
                    run.id
                ),
            }),
        }
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
            .has_unrepaired_transcript_gaps(&run.session_id)
            .map_err(store_error)?
        {
            tracing::info!(
                session_id = %run.session_id,
                "maximum privacy retained audio because durable transcript gaps remain"
            );
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
            // Capture completeness and committed lane durability are separate
            // domains. A run interrupted by a local persistence failure still
            // projects every Final fact that reached the SQLite ledger and
            // lands Ready so the transcript stays visible and editable; the
            // run keeps provider_error_type as the quality signal for the
            // missing suffix.
            tracing::info!(
                session_id = %run.session_id,
                "projecting committed Final facts of an interrupted capture; provider_error_type retains the run-quality signal"
            );
        }
        self.notebook_capture_store
            .set_projection_state(
                run_id,
                ProjectionState::Pending,
                ProjectionState::Projecting,
            )
            .map_err(store_error)?;
        let projection_result = (|| -> Result<(), CoreError> {
            self.sync_capture_into_t2_transcript(&run, true)?;
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

    fn rebuild_finalized_capture_search_index_through(
        &self,
        session_id: &str,
        utterances: &[RealtimeUtterance],
        applied_revision: u64,
    ) -> Result<(), CoreError> {
        // SearchStore has one replace-in-full row per session. The post-stop
        // transcript is the later authority, so its Ready check and this
        // realtime replacement must serialize inside one SQLite write
        // transaction. A read here followed by `index_session` is a TOCTOU:
        // async can publish Ready between them and leave Ready + stale
        // realtime content.
        self.search_store
            .replace_session_from_realtime_unless_async_ready(
                session_id,
                &finalized_capture_search_content_through(utterances, applied_revision),
            )
            .map(|_| ())
            .map_err(|error| CoreError::InternalError {
                message: format!("rebuild finalized capture search index: {error}"),
            })
    }

    /// The projector wake found the durable watermark already applied.
    /// Notify a live callback that may have missed the ACK, repair the
    /// disposable search index, and (for a terminal projection) land Ready.
    /// Shared verbatim by both document epochs: nothing here touches
    /// document bytes.
    fn finish_up_to_date_realtime_projection(
        &self,
        run: &NotebookCaptureRun,
        projection: &RealtimeLoroProjection,
        complete_projection: bool,
    ) -> Result<(), CoreError> {
        let callback = self
            .active_notebook_capture
            .lock()
            .unwrap()
            .as_ref()
            .filter(|active| active.session_id == run.session_id)
            .map(|active| active.callback.clone());
        if let Some(callback) = callback.filter(|callback| {
            !callback.is_closed()
                && callback.last_enqueued_applied_revision() < projection.applied_revision
        }) {
            callback.send(event_from_run(run.clone(), Vec::new(), false));
            if callback.last_enqueued_applied_revision() < projection.applied_revision {
                return Err(CoreError::InternalError {
                    message: format!(
                        "durable realtime projection {} callback notification remains retryable",
                        projection.applied_revision
                    ),
                });
            }
        }
        if complete_projection {
            let search_result = (|| -> Result<(), CoreError> {
                let visible = self
                    .notebook_capture_store
                    .list_utterances(&run.session_id)
                    .map_err(store_error)?;
                self.rebuild_finalized_capture_search_index_through(
                    &run.session_id,
                    &visible,
                    projection.applied_revision,
                )
            })();
            if let Err(error) = search_result {
                tracing::warn!(
                    session_id = %run.session_id,
                    applied_revision = projection.applied_revision,
                    error = %error,
                    "durable realtime projection is editable; disposable search repair remains retryable"
                );
            }
            self.notebook_capture_store
                .complete_projection_unless_purging(&run.id)
                .map_err(store_error)?;
        }
        Ok(())
    }

    fn realtime_transcript_tab(
        &self,
        notebook_id: &str,
    ) -> Result<vt_store::notebook_store::NotebookTabRecord, CoreError> {
        use vt_store::BuiltinNotebookTab;
        self.notebook_store
            .list_tabs(notebook_id)
            .map_err(store_error)?
            .into_iter()
            .find(|tab| tab.builtin_kind == BuiltinNotebookTab::RealtimeTranscript)
            .ok_or_else(|| CoreError::NotFound {
                message: format!("Realtime Transcript tab for notebook {notebook_id}"),
            })
    }

    fn require_single_realtime_transcript_projection(
        &self,
        tab_id: &str,
        run: &NotebookCaptureRun,
    ) -> Result<(), CoreError> {
        let projection_count = self
            .notebook_store
            .list_session_projections(tab_id)
            .map_err(store_error)?
            .into_iter()
            .filter(|projection| {
                projection.notebook_id == run.notebook_id && projection.session_id == run.session_id
            })
            .count();
        match projection_count {
            1 => Ok(()),
            0 => Err(CoreError::NotFound {
                message: format!(
                    "Realtime Transcript projection for capture session {} in notebook {}",
                    run.session_id, run.notebook_id
                ),
            }),
            count => Err(CoreError::ValidationFailed {
                message: format!(
                    "capture session {} has {count} active Realtime Transcript projections",
                    run.session_id
                ),
            }),
        }
    }
}

// =========================================================================
// T2 capture pipeline (switchover charter shard 2, see
// docs/architecture/t2-capture-switchover.md).
//
// Parallel implementation of the three transcript write protocols against
// the epoch-2 block document. Nothing in production calls these until the
// shard-4 cutover flips the open path and the write path in one commit, so
// landing this shard changes no behavior. The SQLite side — pending-snapshot
// selection, watermark ACK, optimistic-lock staging, search rebuild, purge
// refusal — is reused verbatim; only the document verbs differ:
//
// - Machine projection: `machine_upsert_block` per Final utterance. Upsert
//   by id is naturally idempotent, so the whole in-document projection
//   receipt family retires — crash replay is "run the upserts again",
//   terminating in the identical state before the watermark ACK.
// - User correction: `user_replace_lane`/`user_replace_text` by block id.
//   No delta parsing, no range resolution, no user-mutation receipt; the
//   pending SQLite mutation row alone drives startup replay.
// - No rollback snapshots: a partially applied batch is not corruption,
//   because the next wake replays it and lane editability is gated by the
//   SQLite applied watermark, never by document bytes.
// =========================================================================

fn t2_capture_owner(session_id: &str) -> String {
    format!("capture:{session_id}")
}

/// The T2 write for one utterance, derived purely from SQLite machine facts:
/// `text` carries the complete source lane (user overrides are already merged
/// into the read by the store, so re-upserting an edited source writes the
/// identical user-visible bytes), `lanes` carry every complete translation
/// variant. Returns `None` while the utterance has no Final lane at all — a
/// block appears only once it has projectable content, mirroring the old
/// Final-only render.
fn t2_machine_block_write(utterance: &RealtimeUtterance) -> Option<MachineBlockWrite> {
    let source_final = utterance.source_lane_is_complete();
    let mut lanes = BTreeMap::new();
    for variant in finalized_translation_variants(utterance) {
        lanes.insert(
            capture_lane_id(&variant.language),
            variant.text.clone().unwrap_or_default(),
        );
    }
    if !source_final && lanes.is_empty() {
        return None;
    }
    Some(MachineBlockWrite {
        id: utterance.id.clone(),
        owner: t2_capture_owner(&utterance.session_id),
        text: if source_final {
            utterance.source_text.clone()
        } else {
            String::new()
        },
        lanes,
    })
}

/// Lanes the user has taken over: SQLite lane edit revision > 0. The machine
/// never writes these again, even with identical bytes.
fn t2_frozen_lanes(utterance: &RealtimeUtterance) -> BTreeSet<String> {
    utterance
        .variants
        .iter()
        .filter(|variant| {
            variant.role == UtteranceVariantRole::Translation && variant.edit_revision > 0
        })
        .map(|variant| capture_lane_id(&variant.language))
        .collect()
}

/// Where a NEW block for this utterance must be inserted so the session's
/// blocks stay in utterance-sequence order regardless of Final arrival order
/// (the T2 analog of the old sequence-sorted section render, which the
/// out-of-order-finals convergence test pins down):
///
/// - inside the session's region: before the first same-session machine
///   block with a greater sequence;
/// - past the region's end: annotations stay anchored where the user put
///   them, so skip trailing user blocks and insert before the next
///   session's first machine block — a late line lands at its own
///   section's end, never inside a later session;
/// - no region yet: append at the document end, exactly where the old
///   renderer placed a brand-new session section.
fn t2_insert_anchor(
    blocks: &[UtteranceBlock],
    session_id: &str,
    sequence_by_id: &HashMap<&str, u64>,
    sequence: u64,
) -> Option<String> {
    let owner = t2_capture_owner(session_id);
    let mut last_region_index = None;
    for (index, block) in blocks.iter().enumerate() {
        if block.owner != owner {
            continue;
        }
        if sequence_by_id
            .get(block.id.as_str())
            .is_some_and(|existing| *existing > sequence)
        {
            return Some(block.id.clone());
        }
        last_region_index = Some(index);
    }
    blocks[last_region_index? + 1..]
        .iter()
        .find(|block| block.owner != vt_store::transcript_projection::USER_OWNER)
        .map(|block| block.id.clone())
}

/// Replays every Final fact of the snapshot into the block document. Pure
/// function of (document state, machine facts): running it twice, or across
/// a crash, terminates in the identical block list — this replaces the
/// epoch-1 projection receipt as the idempotence proof.
fn t2_upsert_finalized_utterances(
    projection: &TranscriptProjection,
    session_id: &str,
    utterances: &[RealtimeUtterance],
) -> Result<(), CoreError> {
    let sequence_by_id: HashMap<&str, u64> = utterances
        .iter()
        .map(|utterance| (utterance.id.as_str(), utterance.sequence))
        .collect();
    // Converge remote imports once so anchors resolve against the full list.
    projection.refresh();
    for utterance in utterances {
        let Some(write) = t2_machine_block_write(utterance) else {
            continue;
        };
        let frozen = t2_frozen_lanes(utterance);
        // Re-read per utterance: each anchor decision must see the block
        // inserted for the previous one.
        let blocks = projection.blocks();
        let anchor = t2_insert_anchor(&blocks, session_id, &sequence_by_id, utterance.sequence);
        projection
            .machine_upsert_block(write, &frozen, anchor.as_deref())
            .map_err(store_error)?;
    }
    Ok(())
}

impl ZulangueCore {
    /// T2 twin of [`Self::sync_bilingual_capture_into_realtime_tab`]: the
    /// same critical section, pending-snapshot selection, watermark ACK,
    /// search rebuild, and Ready completion, with the document side swapped
    /// from delta-planned flat text to idempotent block upserts. Until the
    /// shard-4 cutover the block document lives in `block-documents/` next
    /// to the epoch-1 snapshot, keyed by the doc_id the tab will adopt.
    fn sync_capture_into_t2_transcript(
        &self,
        run: &NotebookCaptureRun,
        complete_projection: bool,
    ) -> Result<(), CoreError> {
        // Snapshot selection, document mutation, fsync, and SQLite ACK
        // serialize as one projection critical section, exactly like the
        // epoch-1 projector: a stale R loaded outside the guard could
        // otherwise overwrite a concurrent R+1's durable bytes.
        let _mutation_guard = crate::editor_api::editor_document_mutation_guard();
        self.ensure_capture_projection_not_purging(&run.session_id)?;
        // The visible variant of the pending load: user overrides are merged
        // in, so frozen lanes carry their real edit revisions and an
        // overridden source lane re-upserts its own bytes.
        let projection = match self
            .notebook_capture_store
            .load_realtime_loro_projection_if_pending_visible(&run.session_id)
            .map_err(store_error)?
        {
            RealtimeLoroProjectionLoad::Pending(projection) => projection,
            RealtimeLoroProjectionLoad::UpToDate(watermark) => {
                return self.finish_up_to_date_realtime_projection(
                    run,
                    &watermark,
                    complete_projection,
                );
            }
        };
        debug_assert!(projection.desired_revision > projection.applied_revision);
        let tab = self.realtime_transcript_tab(&run.notebook_id)?;
        self.require_single_realtime_transcript_projection(&tab.id, run)?;

        // Open-or-migrate: a legacy epoch-1 snapshot goes through the strict
        // replay migration here; refusal (non-linear history) fails the
        // projection loudly and the caller's state machine marks it Failed.
        self.open_transcript_block_document(&tab.doc_id)?;
        self.with_transcript(&tab.doc_id, |handle| {
            t2_upsert_finalized_utterances(handle, &run.session_id, &projection.machine_utterances)
        })?;
        self.persist_block_document(&tab.doc_id)?;

        // The upserted snapshot is durable. Advance the SQLite watermark so
        // each Final lane becomes editable — this ACK protocol is shared
        // byte-for-byte with the epoch-1 projector. On failure past this
        // point (or anywhere above) there is nothing to roll back: replaying
        // the upserts is the recovery path.
        let callback = self
            .active_notebook_capture
            .lock()
            .unwrap()
            .as_ref()
            .filter(|active| active.session_id == run.session_id)
            .map(|active| active.callback.clone());
        if let Some(callback) = callback {
            callback.commit_projection_ack(&run.session_id, || {
                self.notebook_capture_store
                    .ack_realtime_loro_projection(&run.session_id, projection.desired_revision)
                    .map_err(store_error)
            })?;
        } else {
            self.notebook_capture_store
                .ack_realtime_loro_projection(&run.session_id, projection.desired_revision)
                .map_err(store_error)?;
        }

        let search_result = (|| -> Result<(), CoreError> {
            let visible = self
                .notebook_capture_store
                .list_utterances(&run.session_id)
                .map_err(store_error)?;
            self.rebuild_finalized_capture_search_index_through(
                &run.session_id,
                &visible,
                projection.desired_revision,
            )
        })();
        if let Err(error) = search_result {
            tracing::warn!(
                session_id = %run.session_id,
                applied_revision = projection.desired_revision,
                error = %error,
                "durable realtime projection is editable; disposable search rebuild remains retryable"
            );
        }
        if complete_projection {
            self.notebook_capture_store
                .complete_projection_unless_purging(&run.id)
                .map_err(store_error)?;
        }
        Ok(())
    }

    /// T2 twin of [`Self::apply_notebook_projection_mutation`]. Forward-
    /// replays one durable lane mutation; the caller holds the editor
    /// mutation guard. The receipt machinery is gone: the verb targets the
    /// block by id and is idempotent, so startup replay of a pending
    /// mutation re-applies it and finishes only the SQLite override commit.
    fn apply_notebook_projection_mutation_t2(
        &self,
        mutation: &NotebookProjectionMutation,
    ) -> Result<RealtimeUtterance, CoreError> {
        let run = self
            .notebook_capture_store
            .get_run_for_session(&mutation.session_id)
            .map_err(store_error)?
            .ok_or_else(|| CoreError::NotFound {
                message: format!("capture session {}", mutation.session_id),
            })?;
        let tab = match self.realtime_transcript_tab(&run.notebook_id) {
            Ok(tab) => tab,
            Err(error) => {
                self.cancel_projection_mutation_after_error(mutation, &error)?;
                return Err(error);
            }
        };
        if let Err(error) = self.open_transcript_block_document(&tab.doc_id) {
            self.cancel_projection_mutation_after_error(mutation, &error)?;
            return Err(error);
        }

        let lane_key = capture_lane_id(&mutation.lane_language);
        let mut previous: Option<String> = None;
        let mut document_durable = false;
        let apply_result = (|| -> Result<RealtimeUtterance, CoreError> {
            self.with_transcript(&tab.doc_id, |projection| {
                let blocks = projection.refresh();
                let block = blocks
                    .iter()
                    .find(|block| block.id == mutation.utterance_id)
                    .ok_or_else(|| CoreError::ValidationFailed {
                        message: format!(
                            "T2 block for utterance {} is missing",
                            mutation.utterance_id
                        ),
                    })?;
                // The pre-verb value is the rollback material; its absence
                // for a translated lane means the lane was never projected
                // (the T2 analog of missing ownership marks).
                let rollback_value = match mutation.lane {
                    UtteranceLane::Source => block.text.clone(),
                    UtteranceLane::Translated => {
                        block.lanes.get(&lane_key).cloned().ok_or_else(|| {
                            CoreError::ValidationFailed {
                                message: format!(
                                    "T2 lane {lane_key} is missing on block {}",
                                    mutation.utterance_id
                                ),
                            }
                        })?
                    }
                };
                previous = Some(rollback_value);
                match mutation.lane {
                    UtteranceLane::Source => {
                        projection.user_replace_text(&mutation.utterance_id, &mutation.target_text)
                    }
                    UtteranceLane::Translated => projection.user_replace_lane(
                        &mutation.utterance_id,
                        &lane_key,
                        &mutation.target_text,
                    ),
                }
                .map_err(store_error)
            })?;
            self.persist_block_document(&tab.doc_id)?;
            document_durable = true;

            let updated = self
                .notebook_capture_store
                .commit_projection_mutation(&mutation.id)
                .map_err(store_error)?;
            match self
                .notebook_capture_store
                .list_utterances(&mutation.session_id)
                .map_err(store_error)
                .and_then(|visible| {
                    self.rebuild_finalized_capture_search_index_through(
                        &mutation.session_id,
                        &visible,
                        run.realtime_loro_applied_revision,
                    )
                }) {
                Ok(()) => {}
                Err(error) => {
                    // The block edit and SQLite override are already
                    // committed. FTS is disposable and startup/retry can
                    // rebuild it; do not turn a successful edit into a
                    // false UI failure.
                    tracing::warn!(
                        session_id = %mutation.session_id,
                        mutation_id = %mutation.id,
                        error = %error,
                        "capture lane edit committed; search projection remains retryable"
                    );
                }
            }
            Ok(updated)
        })();

        match apply_result {
            Ok(updated) => Ok(updated),
            Err(error) if document_durable => {
                // The user's bytes are durable but the SQLite override
                // commit is not. Keep the mutation pending so startup
                // replays the idempotent verb and finishes only the
                // override commit.
                Err(error)
            }
            Err(error) => {
                if let Some(previous) = previous.as_deref() {
                    // The verb may have applied in memory without reaching
                    // disk. Restore the pre-verb value so a cancelled
                    // mutation leaves the document exactly as it found it.
                    let rollback = self.with_transcript(&tab.doc_id, |projection| {
                        match mutation.lane {
                            UtteranceLane::Source => {
                                projection.user_replace_text(&mutation.utterance_id, previous)
                            }
                            UtteranceLane::Translated => projection.user_replace_lane(
                                &mutation.utterance_id,
                                &lane_key,
                                previous,
                            ),
                        }
                        .map_err(store_error)
                    });
                    if let Err(rollback_error) = rollback {
                        return Err(CoreError::InternalError {
                            message: format!(
                                "lane mutation failed ({error}); T2 block rollback failed ({rollback_error}); pending mutation retained for recovery"
                            ),
                        });
                    }
                }
                self.cancel_projection_mutation_after_error(mutation, &error)?;
                Err(error)
            }
        }
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

#[derive(Clone, Copy)]
enum FinalizedCaptureLaneKind {
    Source,
    Translation,
}

struct FinalizedCaptureLane<'a> {
    utterance: &'a RealtimeUtterance,
    /// Stable identity shared by marks, selectors, receipts, ordering, and
    /// display labels. Provider casing and BCP-47 region/script suffixes must
    /// never create a second logical lane.
    language: String,
    text: &'a str,
    revision: u64,
    kind: FinalizedCaptureLaneKind,
}

fn capture_lane_id(language: &str) -> String {
    normalize_language(language)
}

fn push_capture_text_range(ranges: &mut Vec<crate::editor_api::TextRange>, pos: usize, len: usize) {
    if let Some(previous) = ranges
        .last_mut()
        .filter(|range| range.pos + range.len == pos)
    {
        previous.len += len;
    } else {
        ranges.push(crate::editor_api::TextRange { pos, len });
    }
}

/// The legacy purge route's section resolver, serving the flat-text targets
/// that stayed on epoch 1 after the T2 cutover (async transcript and note
/// documents). One pass over the editor Delta: the contiguous character
/// range of runs whose `session_id` attribute names the purged session.
/// A session split across disjoint ranges fails closed, exactly like the
/// retired delta index it distills.
fn legacy_session_section_range(
    delta_json: &str,
    session_id: &str,
) -> Result<Option<crate::editor_api::TextRange>, CoreError> {
    let value: serde_json::Value =
        serde_json::from_str(delta_json).map_err(|error| CoreError::ValidationFailed {
            message: format!("invalid editor Delta JSON: {error}"),
        })?;
    let segments = value
        .as_array()
        .ok_or_else(|| CoreError::ValidationFailed {
            message: "editor Delta must be an array".to_string(),
        })?;
    let mut cursor = 0_usize;
    let mut session_ranges = Vec::new();
    for segment in segments {
        let text = segment
            .get("insert")
            .and_then(serde_json::Value::as_str)
            .ok_or_else(|| CoreError::ValidationFailed {
                message: "editor Delta text insert must be a string".to_string(),
            })?;
        let len = text.chars().count();
        let marked_session = segment
            .get("attributes")
            .filter(|attributes| !attributes.is_null())
            .map(|attributes| {
                attributes
                    .get("session_id")
                    .map(|value| {
                        value.as_str().ok_or_else(|| CoreError::ValidationFailed {
                            message: "editor ownership attribute session_id must be a string"
                                .to_string(),
                        })
                    })
                    .transpose()
            })
            .transpose()?
            .flatten();
        if marked_session == Some(session_id) && len > 0 {
            push_capture_text_range(&mut session_ranges, cursor, len);
        }
        cursor = cursor.saturating_add(len);
    }
    match session_ranges.len() {
        0 => Ok(None),
        1 => Ok(session_ranges.first().copied()),
        count => Err(CoreError::ValidationFailed {
            message: format!("ownership marks are split across {count} disjoint ranges"),
        }),
    }
}

fn finalized_capture_lanes(utterances: &[RealtimeUtterance]) -> Vec<FinalizedCaptureLane<'_>> {
    let mut lanes = Vec::new();
    for utterance in utterances {
        if utterance.source_lane_is_complete() {
            lanes.push(FinalizedCaptureLane {
                utterance,
                language: capture_lane_id(&utterance.source_language),
                text: &utterance.source_text,
                revision: utterance.source_projection_revision,
                kind: FinalizedCaptureLaneKind::Source,
            });
        }
        for variant in finalized_translation_variants(utterance) {
            lanes.push(FinalizedCaptureLane {
                utterance,
                language: capture_lane_id(&variant.language),
                text: variant.text.as_deref().unwrap_or_default(),
                revision: variant.projection_revision,
                kind: FinalizedCaptureLaneKind::Translation,
            });
        }
    }
    lanes.sort_by(|left, right| {
        let left_rank = matches!(left.kind, FinalizedCaptureLaneKind::Translation) as u8;
        let right_rank = matches!(right.kind, FinalizedCaptureLaneKind::Translation) as u8;
        left.utterance
            .sequence
            .cmp(&right.utterance.sequence)
            .then_with(|| left_rank.cmp(&right_rank))
            .then_with(|| left.language.cmp(&right.language))
            .then_with(|| left.utterance.id.cmp(&right.utterance.id))
    });
    lanes
}

fn finalized_translation_variants(
    utterance: &RealtimeUtterance,
) -> impl Iterator<Item = &RealtimeUtteranceVariant> {
    utterance.variants.iter().filter(|variant| {
        variant.role == UtteranceVariantRole::Translation
            && variant.state == UtteranceVariantState::Ready
            && variant.completion == Some(UtteranceCompletion::Complete)
            && variant.text.is_some()
    })
}

#[cfg(test)]
fn finalized_capture_search_content(utterances: &[RealtimeUtterance]) -> String {
    finalized_capture_search_content_through(utterances, u64::MAX)
}

fn finalized_capture_search_content_through(
    utterances: &[RealtimeUtterance],
    applied_revision: u64,
) -> String {
    let mut content = String::new();
    for lane in finalized_capture_lanes(utterances)
        .into_iter()
        .filter(|lane| lane.revision > 0 && lane.revision <= applied_revision)
    {
        if lane.text.is_empty() {
            continue;
        }
        if !content.is_empty() {
            content.push(' ');
        }
        content.push('[');
        content.push_str(&lane.language);
        content.push_str("] ");
        content.push_str(lane.text);
    }
    content
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
            FfiNotebookPostStopExecution::AsyncFileApi
        );
    }

    #[test]
    fn library_context_pack_document_ffi_lists_reads_and_replaces_json() {
        let temp = tempfile::tempdir().unwrap();
        let core = ZulangueCore::new_for_test(temp.path().to_string_lossy().to_string()).unwrap();
        let notebook = core
            .create_notebook(Some("Knowledge settings".into()))
            .unwrap();
        let pack = core
            .create_library_context_pack("New knowledge base".into())
            .unwrap();
        core.set_notebook_context_pack_binding(notebook.id.clone(), pack.id.clone(), Some(4))
            .unwrap();

        let notebook_packs = core
            .list_notebook_context_packs(notebook.id.clone())
            .unwrap();
        assert_eq!(notebook_packs.len(), 2);
        let library_packs = core.list_library_context_packs().unwrap();
        assert_eq!(library_packs.len(), 1);
        assert_eq!(library_packs[0].id, pack.id);
        assert_eq!(library_packs[0].scope, "library");
        assert_eq!(library_packs[0].bound_position, None);

        let empty_document: ContextPackDocument =
            serde_json::from_str(&core.read_library_context_pack(pack.id.clone()).unwrap())
                .unwrap();
        assert_eq!(
            empty_document.schema,
            vt_store::CONTEXT_PACK_DOCUMENT_SCHEMA
        );
        assert_eq!(empty_document.title, "New knowledge base");
        assert!(empty_document.sources.is_empty());

        let content = "Humanity Forum field context".to_string();
        let document = ContextPackDocument {
            schema: vt_store::CONTEXT_PACK_DOCUMENT_SCHEMA.into(),
            title: "人类学论坛".into(),
            sources: vec![ContextPackDocumentSource {
                title: "Background".into(),
                format: ContextSourceFormat::Markdown,
                content_kind: ContextContentKind::Text,
                sha256: format!("{:x}", Sha256::digest(content.as_bytes())),
                content,
            }],
        };
        let replaced = core
            .replace_library_context_pack(
                pack.id.clone(),
                pack.revision,
                serde_json::to_string_pretty(&document).unwrap(),
            )
            .unwrap();
        assert_eq!(replaced.id, pack.id);
        assert_eq!(replaced.title, "人类学论坛");
        assert_eq!(replaced.revision, pack.revision + 1);
        let round_trip: ContextPackDocument =
            serde_json::from_str(&core.read_library_context_pack(pack.id.clone()).unwrap())
                .unwrap();
        assert_eq!(round_trip, document);
        let bound_pack = core
            .list_notebook_context_packs(notebook.id)
            .unwrap()
            .into_iter()
            .find(|candidate| candidate.id == pack.id)
            .unwrap();
        assert_eq!(bound_pack.bound_position, Some(4));

        assert!(matches!(
            core.replace_library_context_pack(
                pack.id.clone(),
                replaced.revision,
                "not JSON".into()
            ),
            Err(CoreError::ValidationFailed { .. })
        ));
        let after_rejection: ContextPackDocument =
            serde_json::from_str(&core.read_library_context_pack(pack.id).unwrap()).unwrap();
        assert_eq!(after_rejection, document);
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

        let summaries = core
            .list_notebook_capture_history_summaries(notebook.id.clone())
            .unwrap();
        assert_eq!(summaries.len(), 1);
        assert_eq!(summaries[0].session_id, session.id);
        assert!(summaries[0].utterances.is_empty());

        let selected = core
            .list_notebook_capture_history_utterances(notebook.id.clone(), session.id.clone())
            .unwrap();
        assert!(selected.is_empty());
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
            _credential: std::sync::Arc<dyn vt_stt::LaneCredentialSource>,
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
            _credential: std::sync::Arc<dyn vt_stt::LaneCredentialSource>,
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
    fn failed_remote_start_cannot_install_connecting_owner_when_unavailable_write_fails() {
        let temp = tempfile::tempdir().unwrap();
        let core = ZulangueCore::new_for_test(temp.path().to_string_lossy().to_string()).unwrap();
        let notebook = core
            .create_notebook(Some("Unavailable truth failure".into()))
            .unwrap();
        let mut profile = core
            .get_notebook_capture_profile(notebook.id.clone())
            .unwrap();
        profile.remote_realtime_enabled = true;
        let profile = core.update_notebook_capture_profile(profile).unwrap();
        // Deliberately leave the Soniox key absent so construction fails after
        // the run is created but before a provider owner exists.
        let db = rusqlite::Connection::open(temp.path().join("zulangue.db")).unwrap();
        db.execute_batch(
            "CREATE TRIGGER fail_start_unavailable_health
             BEFORE UPDATE OF remote_health ON notebook_capture_runs
             WHEN NEW.remote_health = 'unavailable'
             BEGIN
                 SELECT RAISE(FAIL, 'injected unavailable health persistence failure');
             END;",
        )
        .unwrap();

        let error = core
            .start_notebook_capture_session(
                notebook.id,
                profile.revision,
                None,
                Box::new(CaptureEventSender(std::sync::mpsc::channel().0)),
            )
            .expect_err("remote=None + Connecting must never become an active owner");
        assert!(error
            .to_string()
            .contains("injected unavailable health persistence failure"));
        assert!(core.active_notebook_capture.lock().unwrap().is_none());
        let active_rows: i64 = db
            .query_row(
                "SELECT COUNT(*) FROM notebook_capture_runs
                 WHERE capture_state IN ('recording', 'paused', 'draining')",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(active_rows, 0);
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
        let durable_resumed = core
            .notebook_capture_store
            .get_run_for_session(&started.session_id)
            .unwrap()
            .unwrap();
        assert_eq!(durable_resumed.capture_state, CaptureState::Recording);
        assert_eq!(durable_resumed.remote_health, RemoteHealth::Degraded);
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

    #[test]
    fn pause_state_commit_is_success_even_when_degraded_health_write_fails() {
        let (temp, core, factory, _notebook_id, _profile, started) =
            start_remote_tracking_capture("Pause commit point");
        {
            let active = core.active_notebook_capture.lock().unwrap();
            let remote = active.as_ref().unwrap().remote.as_ref().unwrap();
            for stream in &remote.streams {
                while stream.control_tx.capacity() > 0 {
                    stream.control_tx.try_send(SttStreamControl::Pause).unwrap();
                }
            }
        }
        let db = rusqlite::Connection::open(temp.path().join("zulangue.db")).unwrap();
        db.execute_batch(
            "CREATE TRIGGER fail_pause_remote_health
             BEFORE UPDATE OF remote_health ON notebook_capture_runs
             WHEN NEW.remote_health = 'degraded'
             BEGIN
                 SELECT RAISE(FAIL, 'injected pause remote health persistence failure');
             END;",
        )
        .unwrap();

        let paused = core
            .pause_notebook_capture_session(started.session_id.clone(), true)
            .expect("the already-committed pause must not be reported as a failed command");
        assert_eq!(paused.capture_state, FfiNotebookCaptureState::Paused);
        assert_eq!(paused.remote_health, FfiNotebookRemoteHealth::Degraded);
        let durable = core
            .notebook_capture_store
            .get_run_for_session(&started.session_id)
            .unwrap()
            .unwrap();
        assert_eq!(durable.capture_state, CaptureState::Paused);
        assert!(core
            .active_notebook_capture
            .lock()
            .unwrap()
            .as_ref()
            .unwrap()
            .remote
            .is_none());
        assert_eq!(factory.active_stream_count.load(Ordering::SeqCst), 0);

        let reconciled = core
            .get_notebook_capture_session_event(started.session_id.clone())
            .unwrap();
        assert_eq!(reconciled.capture_state, FfiNotebookCaptureState::Paused);
        assert_eq!(reconciled.remote_health, FfiNotebookRemoteHealth::Degraded);

        let resume_error = core
            .pause_notebook_capture_session(started.session_id.clone(), false)
            .expect_err("resume must stay Paused until Degraded is durable");
        assert!(resume_error
            .to_string()
            .contains("injected pause remote health persistence failure"));
        let still_paused = core
            .notebook_capture_store
            .get_run_for_session(&started.session_id)
            .unwrap()
            .unwrap();
        assert_eq!(still_paused.capture_state, CaptureState::Paused);

        db.execute_batch("DROP TRIGGER fail_pause_remote_health;")
            .unwrap();
        let resumed = core
            .pause_notebook_capture_session(started.session_id.clone(), false)
            .expect("resume may continue local-only once Degraded is durable");
        assert_eq!(resumed.capture_state, FfiNotebookCaptureState::Recording);
        assert_eq!(resumed.remote_health, FfiNotebookRemoteHealth::Degraded);
        let durable_resumed = core
            .notebook_capture_store
            .get_run_for_session(&started.session_id)
            .unwrap()
            .unwrap();
        assert_eq!(durable_resumed.capture_state, CaptureState::Recording);
        assert_eq!(durable_resumed.remote_health, RemoteHealth::Degraded);
        assert_eq!(
            factory.constructor_count.load(Ordering::SeqCst),
            1,
            "local-only resume must not rebuild an assembler/provider owner"
        );
        core.interrupt_notebook_capture_session(
            started.session_id,
            FfiNotebookCaptureInterruptReason::LocalAudioUnavailable,
        )
        .unwrap();
    }

    #[test]
    fn stop_projects_final_lanes_even_when_remote_diagnostic_persistence_fails() {
        let (temp, core, _factory, notebook_id, _profile, started) =
            start_remote_tracking_capture("Stop projection error domains");
        let final_utterance = upsert_test_lanes(
            &core.notebook_capture_store,
            &NewRealtimeUtterance {
                id: "stop-projection-utterance".into(),
                session_id: started.session_id.clone(),
                sequence: 0,
                session_speaker_id: None,
                source_language: "en".into(),
                source_text: "durable stop transcript".into(),
                source_start_ms: Some(0),
                source_end_ms: Some(100),
                translated_language: Some("zh".into()),
                translated_text: Some("持久停止转录".into()),
                completion: UtteranceCompletion::Complete,
                alignment: UtteranceAlignment::Paired,
            },
            None,
        )
        .unwrap();
        {
            let active = core.active_notebook_capture.lock().unwrap();
            for stream in &active.as_ref().unwrap().remote.as_ref().unwrap().streams {
                stream.stream_task.abort();
            }
        }
        let db = rusqlite::Connection::open(temp.path().join("zulangue.db")).unwrap();
        db.execute_batch(
            "CREATE TRIGGER fail_stop_remote_diagnostic
             BEFORE UPDATE OF remote_health ON notebook_capture_runs
             WHEN NEW.remote_health IN ('degraded', 'unavailable')
             BEGIN
                 SELECT RAISE(FAIL, 'injected stop diagnostic failure');
             END;",
        )
        .unwrap();

        let stopped = core
            .stop_notebook_capture_session(started.session_id.clone())
            .expect("remote diagnostic persistence must not suppress independent Loro projection");
        assert_eq!(stopped.capture_state, FfiNotebookCaptureState::Completed);
        assert_eq!(stopped.projection_state, FfiNotebookProjectionState::Ready);
        assert!(
            stopped.realtime_loro_applied_revision >= final_utterance.source_projection_revision
        );
        let doc_id = core
            .list_notebook_tabs(notebook_id)
            .unwrap()
            .into_iter()
            .find(|tab| tab.builtin_kind == "realtime_transcript")
            .unwrap()
            .doc_id;
        let blocks = core
            .with_transcript(&doc_id, |projection| Ok(projection.refresh()))
            .unwrap();
        let block = blocks
            .iter()
            .find(|block| block.id == "stop-projection-utterance")
            .expect("stop must project the Final utterance into the T2 document");
        assert_eq!(block.text, "durable stop transcript");
        assert_eq!(block.lanes["zh"], "持久停止转录");
        db.execute_batch("DROP TRIGGER fail_stop_remote_diagnostic;")
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

    fn assembler_store_fixture(
        session_id: &str,
    ) -> (tempfile::TempDir, ZulangueCore, NotebookCaptureProfile) {
        let temp = tempfile::tempdir().unwrap();
        let core = ZulangueCore::new_for_test(temp.path().to_string_lossy().to_string()).unwrap();
        let notebook = core
            .create_notebook(Some("Independent assembler lanes".into()))
            .unwrap();
        let stored_profile = core
            .notebook_capture_store
            .get_or_create_profile(&notebook.id)
            .unwrap();
        let session = vt_store::SessionRecord {
            id: session_id.into(),
            title: "Independent assembler lanes".into(),
            session_type: "recording".into(),
            status: "recording".into(),
            duration_ms: 0,
            created_at: "2001-01-05T00:00:00Z".into(),
            deleted_at: None,
        };
        core.notebook_capture_store
            .create_session_and_run(
                &session,
                &vt_store::notebook_capture_store::NewNotebookCaptureRun {
                    id: format!("{session_id}-run"),
                    notebook_id: notebook.id.clone(),
                    session_id: session.id.clone(),
                    remote_health: RemoteHealth::Off,
                    audio_journal_path: format!("/private/{session_id}.journal"),
                    audio_key_ref: format!("{session_id}-key"),
                    sample_rate: 16_000,
                    channels: 1,
                },
                &stored_profile,
            )
            .unwrap();
        claim_current_realtime_provider(&core.notebook_capture_store, session_id);
        let mut runtime_profile = profile();
        runtime_profile.notebook_id = notebook.id;
        (temp, core, runtime_profile)
    }

    fn upsert_test_lanes(
        store: &NotebookCaptureStore,
        input: &NewRealtimeUtterance,
        expected_revision: Option<u64>,
    ) -> Result<RealtimeUtterance, vt_store::NotebookCaptureStoreError> {
        let translation = input
            .translated_language
            .as_deref()
            .zip(input.translated_text.as_deref())
            .map(|(language, text)| (language.to_string(), text.to_string(), input.completion));
        let mut source = input.clone();
        source.translated_language = None;
        source.translated_text = None;
        source.alignment = match source.alignment {
            UtteranceAlignment::OutsideLanguagePair => UtteranceAlignment::OutsideLanguagePair,
            _ if translation.is_some() => UtteranceAlignment::TranslationPending,
            _ => UtteranceAlignment::SourceOnly,
        };
        let mut persisted = store.upsert_utterance(&source, expected_revision)?;
        if let Some((language, text, completion)) = translation {
            persisted = store.upsert_translation_variant(
                &source.session_id,
                source.sequence,
                &language,
                Some(&text),
                UtteranceVariantState::Ready,
                Some(completion),
            )?;
        }
        Ok(persisted)
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
    fn canonical_source_final_and_late_translation_final_are_lane_independent() {
        let (_temp, core, runtime_profile) = assembler_store_fixture("lane-source-first-session");
        let mut assembler =
            RealtimeUtteranceAssembler::new("lane-source-first-session".into(), &runtime_profile);

        let initial = assembler.apply_tokens(&[
            attributed_token(
                "hello",
                SttStreamTranslationStatus::Original,
                Some("en"),
                None,
                Some("speaker-a"),
                true,
            ),
            attributed_token(
                "你",
                SttStreamTranslationStatus::Translation,
                Some("zh"),
                Some("en"),
                Some("speaker-a"),
                false,
            ),
        ]);
        assert_eq!(initial.len(), 1);
        persist_assembled_utterances(&core.notebook_capture_store, &mut assembler, initial, 0)
            .unwrap();

        let closed = assembler.finalize();
        assert_eq!(closed.len(), 1);
        assert_eq!(
            closed[0].utterance.completion,
            UtteranceCompletion::Complete
        );
        assert_eq!(
            closed[0].translation_completion,
            Some(UtteranceCompletion::Partial)
        );
        let source_final =
            persist_assembled_utterances(&core.notebook_capture_store, &mut assembler, closed, 0)
                .unwrap()
                .remove(0);
        let partial_translation = source_final
            .variants
            .iter()
            .find(|variant| variant.language == "zh")
            .unwrap();
        assert!(source_final.source_projection_revision > 0);
        assert_eq!(partial_translation.projection_revision, 0);
        assert_eq!(
            partial_translation.completion,
            Some(UtteranceCompletion::Partial)
        );
        let source_revision = source_final.revision;

        let late_translation = assembler.apply_tokens(&[attributed_token(
            "你好",
            SttStreamTranslationStatus::Translation,
            Some("zh"),
            Some("en"),
            Some("speaker-a"),
            true,
        )]);
        assert_eq!(late_translation.len(), 1);
        assert!(!late_translation[0].source_dirty);
        assert_eq!(
            late_translation[0].translation_completion,
            Some(UtteranceCompletion::Complete)
        );
        let completed = persist_assembled_utterances(
            &core.notebook_capture_store,
            &mut assembler,
            late_translation,
            0,
        )
        .unwrap()
        .remove(0);
        let final_translation = completed
            .variants
            .iter()
            .find(|variant| variant.language == "zh")
            .unwrap();
        assert_eq!(
            completed.revision, source_revision,
            "translation must not advance the source-lane CAS"
        );
        assert_eq!(
            final_translation.completion,
            Some(UtteranceCompletion::Complete)
        );
        assert!(
            final_translation.projection_revision > completed.source_projection_revision,
            "the late translation Final must receive its own projection revision"
        );
        assert_eq!(completed.translated_text.as_deref(), Some("你好"));
        assert_eq!(completed.alignment, UtteranceAlignment::Paired);
    }

    #[test]
    fn canonical_translation_can_finalize_before_the_source_lane() {
        let (_temp, core, runtime_profile) =
            assembler_store_fixture("lane-translation-first-session");
        let mut assembler = RealtimeUtteranceAssembler::new(
            "lane-translation-first-session".into(),
            &runtime_profile,
        );
        let initial = assembler.apply_tokens(&[
            attributed_token(
                "hel",
                SttStreamTranslationStatus::Original,
                Some("en"),
                None,
                Some("speaker-a"),
                false,
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
        assert_eq!(initial.len(), 1);
        persist_assembled_utterances(&core.notebook_capture_store, &mut assembler, initial, 0)
            .unwrap();

        let closed = assembler.finalize();
        assert_eq!(closed.len(), 1);
        assert_eq!(closed[0].utterance.completion, UtteranceCompletion::Partial);
        assert_eq!(
            closed[0].translation_completion,
            Some(UtteranceCompletion::Complete)
        );
        let translation_final =
            persist_assembled_utterances(&core.notebook_capture_store, &mut assembler, closed, 0)
                .unwrap()
                .remove(0);
        let zh = translation_final
            .variants
            .iter()
            .find(|variant| variant.language == "zh")
            .unwrap();
        assert_eq!(translation_final.source_projection_revision, 0);
        assert_eq!(
            zh.completion,
            Some(UtteranceCompletion::Complete),
            "translation closure must not depend on source closure stability"
        );
        assert!(zh.projection_revision > 0);
        assert_eq!(translation_final.source_text, "hel");
    }

    #[test]
    fn replacement_response_withdraws_partial_translation_and_legacy_shadow() {
        let (_temp, core, runtime_profile) =
            assembler_store_fixture("lane-withdraw-translation-session");
        let mut assembler = RealtimeUtteranceAssembler::new(
            "lane-withdraw-translation-session".into(),
            &runtime_profile,
        );
        let initial = assembler.apply_tokens(&[
            attributed_token(
                "hello",
                SttStreamTranslationStatus::Original,
                Some("en"),
                None,
                Some("speaker-a"),
                true,
            ),
            attributed_token(
                "临时",
                SttStreamTranslationStatus::Translation,
                Some("zh"),
                Some("en"),
                Some("speaker-a"),
                false,
            ),
        ]);
        persist_assembled_utterances(&core.notebook_capture_store, &mut assembler, initial, 0)
            .unwrap();
        let withdrawn = assembler.apply_tokens(&[]);
        assert_eq!(withdrawn.len(), 1);
        persist_assembled_utterances(&core.notebook_capture_store, &mut assembler, withdrawn, 0)
            .unwrap();

        let stored = core
            .notebook_capture_store
            .list_machine_utterances("lane-withdraw-translation-session")
            .unwrap()
            .remove(0);
        let zh = stored
            .variants
            .iter()
            .find(|variant| variant.language == "zh")
            .unwrap();
        assert_eq!(zh.state, UtteranceVariantState::Waiting);
        assert_eq!(zh.text, None);
        assert_eq!(zh.completion, None);
        assert_eq!(zh.projection_revision, 0);
        assert_eq!(stored.translated_language, None);
        assert_eq!(stored.translated_text, None);
        assert_eq!(stored.alignment, UtteranceAlignment::TranslationPending);
    }

    #[test]
    fn replacement_response_removes_a_wholly_speculative_source_row() {
        let (_temp, core, runtime_profile) =
            assembler_store_fixture("lane-withdraw-source-session");
        let mut assembler = RealtimeUtteranceAssembler::new(
            "lane-withdraw-source-session".into(),
            &runtime_profile,
        );
        let initial = assembler.apply_tokens(&[
            attributed_token(
                "ghost",
                SttStreamTranslationStatus::Original,
                Some("en"),
                None,
                Some("speaker-a"),
                false,
            ),
            attributed_token(
                "临时译文",
                SttStreamTranslationStatus::Translation,
                Some("zh"),
                Some("en"),
                Some("speaker-a"),
                true,
            ),
        ]);
        assert_eq!(initial.len(), 1);
        persist_assembled_utterances(&core.notebook_capture_store, &mut assembler, initial, 0)
            .unwrap();
        assert_eq!(
            core.notebook_capture_store
                .list_machine_utterances("lane-withdraw-source-session")
                .unwrap()
                .len(),
            1
        );

        let withdrawn = assembler.apply_tokens(&[]);
        assert_eq!(withdrawn.len(), 1);
        assert!(withdrawn[0].remove_partial);
        let removal = persist_assembled_utterances(
            &core.notebook_capture_store,
            &mut assembler,
            withdrawn,
            0,
        )
        .unwrap();
        assert!(
            removal.requires_full_snapshot,
            "a durable deletion must force a replace-in-full callback"
        );
        assert!(
            core.notebook_capture_store
                .list_machine_utterances("lane-withdraw-source-session")
                .unwrap()
                .is_empty(),
            "a replacement response must not leave an empty or stale source row"
        );
        let run = core
            .notebook_capture_store
            .get_run_for_session("lane-withdraw-source-session")
            .unwrap()
            .unwrap();
        let event = event_full_snapshot_from_run(&core.notebook_capture_store, run).unwrap();
        assert!(event.is_full_snapshot);
        assert!(event.utterances.is_empty());
    }

    struct RecordingFanoutFactory {
        sent: std::sync::Mutex<Vec<usize>>,
    }

    struct FailSecondFanoutFactory {
        calls: std::sync::atomic::AtomicUsize,
    }

    impl NotebookSonioxStreamFactory for RecordingFanoutFactory {
        fn start(
            &self,
            _endpoint: &str,
            _credential: std::sync::Arc<dyn vt_stt::LaneCredentialSource>,
            _config: SttConfig,
            _cancel: tokio_util::sync::CancellationToken,
        ) -> SonioxStreamRuntime {
            unreachable!("fan-out tests never construct a stream")
        }

        fn try_send_pcm(
            &self,
            audio_tx: &tokio::sync::mpsc::Sender<Vec<u8>>,
            audio_data: Vec<u8>,
        ) -> Result<(), String> {
            self.sent.lock().unwrap().push(audio_data.len());
            audio_tx
                .try_send(audio_data)
                .map_err(|error| error.to_string())
        }
    }

    impl NotebookSonioxStreamFactory for FailSecondFanoutFactory {
        fn start(
            &self,
            _endpoint: &str,
            _credential: std::sync::Arc<dyn vt_stt::LaneCredentialSource>,
            _config: SttConfig,
            _cancel: tokio_util::sync::CancellationToken,
        ) -> SonioxStreamRuntime {
            unreachable!("fan-out tests never construct a stream")
        }

        fn try_send_pcm(
            &self,
            audio_tx: &tokio::sync::mpsc::Sender<Vec<u8>>,
            audio_data: Vec<u8>,
        ) -> Result<(), String> {
            let call = self.calls.fetch_add(1, Ordering::AcqRel);
            if call == 1 {
                return Err("injected auxiliary try_send race".to_string());
            }
            audio_tx
                .try_send(audio_data)
                .map_err(|error| error.to_string())
        }
    }

    #[tokio::test]
    async fn fanout_reports_and_stops_a_dead_auxiliary_without_starving_siblings() {
        let factory = Arc::new(RecordingFanoutFactory {
            sent: std::sync::Mutex::new(Vec::new()),
        });
        let make_stream = |canonical: bool, target: Option<&str>, closed: bool| {
            let (audio_tx, audio_rx) = tokio::sync::mpsc::channel::<Vec<u8>>(4);
            let (control_tx, control_rx) = tokio::sync::mpsc::channel(4);
            if closed {
                drop(audio_rx);
                drop(control_rx);
            } else {
                // Keep receivers alive for the duration of the test.
                std::mem::forget(audio_rx);
                std::mem::forget(control_rx);
            }
            ActiveRemoteStream {
                descriptor: RemoteStreamLane {
                    target_language: target.map(str::to_string),
                    canonical,
                },
                audio_tx,
                control_tx,
                stream_task: tokio::spawn(async { Ok(()) }),
                forward_task: tokio::spawn(async {}),
                lane_cancel: tokio_util::sync::CancellationToken::new(),
                input_discontinuity_reported: std::sync::atomic::AtomicBool::new(false),
            }
        };

        // A dead auxiliary lane becomes an explicit terminal discontinuity;
        // the later healthy sibling still receives the same block.
        let (discontinuity_tx, mut discontinuity_rx) = tokio::sync::mpsc::unbounded_channel();
        let capture = ActiveRemoteCapture {
            stream_factory: factory.clone(),
            streams: vec![
                make_stream(true, None, false),
                make_stream(false, Some("en"), true),
                make_stream(false, Some("th"), false),
            ],
            cancel: tokio_util::sync::CancellationToken::new(),
            event_task: tokio::spawn(async { Ok(()) }),
            discontinuity_tx,
        };
        let report = capture
            .try_fanout_pcm(&[7u8; 64])
            .expect("a dead auxiliary lane must not stop capture audio");
        assert_eq!(report.auxiliary_discontinuities, ["en"]);
        assert_eq!(factory.sent.lock().unwrap().len(), 2);
        let discontinuity = discontinuity_rx.try_recv().unwrap();
        assert_eq!(discontinuity.lane_index, 1);
        assert!(matches!(
            discontinuity.event,
            SttStreamEvent::InputDiscontinuity
        ));
        let second = capture.try_fanout_pcm(&[8u8; 64]).unwrap();
        assert!(second.auxiliary_discontinuities.is_empty());
        assert_eq!(factory.sent.lock().unwrap().len(), 4);
        assert!(discontinuity_rx.try_recv().is_err());
        capture
            .try_fanout_control(SttStreamControl::Keepalive)
            .expect("a dead auxiliary lane must not stop group control");

        // A dead canonical lane is group-wide unavailability, exactly as before.
        let (canonical_discontinuity_tx, _canonical_discontinuity_rx) =
            tokio::sync::mpsc::unbounded_channel();
        let canonical_down = ActiveRemoteCapture {
            stream_factory: factory.clone(),
            streams: vec![
                make_stream(true, None, true),
                make_stream(false, Some("en"), false),
            ],
            cancel: tokio_util::sync::CancellationToken::new(),
            event_task: tokio::spawn(async { Ok(()) }),
            discontinuity_tx: canonical_discontinuity_tx,
        };
        assert!(canonical_down.try_fanout_pcm(&[7u8; 64]).is_err());
        assert!(canonical_down
            .try_fanout_control(SttStreamControl::Keepalive)
            .is_err());

        // The collector cancels the shared group before the owning capture is
        // removed from process state. That interval must fail closed instead
        // of treating every canceled child as a successful no-op fanout.
        let canceled_group = tokio_util::sync::CancellationToken::new();
        let (canceled_discontinuity_tx, _canceled_discontinuity_rx) =
            tokio::sync::mpsc::unbounded_channel();
        let canceled_capture = ActiveRemoteCapture {
            stream_factory: factory,
            streams: vec![
                make_stream(true, None, false),
                make_stream(false, Some("en"), false),
            ],
            cancel: canceled_group.clone(),
            event_task: tokio::spawn(async { Ok(()) }),
            discontinuity_tx: canceled_discontinuity_tx,
        };
        canceled_group.cancel();
        assert!(canceled_capture.try_fanout_pcm(&[7u8; 64]).is_err());
        assert!(canceled_capture
            .try_fanout_control(SttStreamControl::Keepalive)
            .is_err());
    }

    #[tokio::test]
    async fn fanout_auxiliary_send_race_still_delivers_to_the_later_sibling() {
        let factory = Arc::new(FailSecondFanoutFactory {
            calls: std::sync::atomic::AtomicUsize::new(0),
        });
        let make_stream = |canonical: bool, target: Option<&str>| {
            let (audio_tx, audio_rx) = tokio::sync::mpsc::channel::<Vec<u8>>(4);
            let (control_tx, control_rx) = tokio::sync::mpsc::channel(4);
            let stream = ActiveRemoteStream {
                descriptor: RemoteStreamLane {
                    target_language: target.map(str::to_string),
                    canonical,
                },
                audio_tx,
                control_tx,
                stream_task: tokio::spawn(async { Ok(()) }),
                forward_task: tokio::spawn(async {}),
                lane_cancel: tokio_util::sync::CancellationToken::new(),
                input_discontinuity_reported: std::sync::atomic::AtomicBool::new(false),
            };
            (stream, audio_rx, control_rx)
        };
        let (canonical, mut canonical_rx, canonical_control_rx) = make_stream(true, None);
        let (failed_aux, mut failed_aux_rx, failed_control_rx) = make_stream(false, Some("zh"));
        let (later_aux, mut later_aux_rx, later_control_rx) = make_stream(false, Some("th"));
        let (discontinuity_tx, mut discontinuity_rx) = tokio::sync::mpsc::unbounded_channel();
        let capture = ActiveRemoteCapture {
            stream_factory: factory.clone(),
            streams: vec![canonical, failed_aux, later_aux],
            cancel: tokio_util::sync::CancellationToken::new(),
            event_task: tokio::spawn(async { Ok(()) }),
            discontinuity_tx,
        };

        let block = vec![9_u8; 64];
        let report = capture.try_fanout_pcm(&block).unwrap();
        assert_eq!(factory.calls.load(Ordering::Acquire), 3);
        assert_eq!(report.auxiliary_discontinuities, ["zh"]);
        assert_eq!(canonical_rx.try_recv().unwrap(), block);
        assert!(failed_aux_rx.try_recv().is_err());
        assert_eq!(later_aux_rx.try_recv().unwrap(), block);
        assert_eq!(discontinuity_rx.try_recv().unwrap().lane_index, 1);
        drop((canonical_control_rx, failed_control_rx, later_control_rx));
    }

    #[tokio::test]
    async fn fair_event_queue_services_each_ready_lane_before_revisiting_noise() {
        let (event_tx, mut event_rx) = tokio::sync::mpsc::channel(8);
        let (discontinuity_tx, mut discontinuity_rx) = tokio::sync::mpsc::unbounded_channel();
        for _ in 0..3 {
            event_tx
                .send(TaggedStreamEvent {
                    lane_index: 0,
                    event: SttStreamEvent::Connected,
                })
                .await
                .unwrap();
        }
        event_tx
            .send(TaggedStreamEvent {
                lane_index: 1,
                event: SttStreamEvent::Connected,
            })
            .await
            .unwrap();

        let mut fair = FairTaggedEventQueue::new(2, 8);
        assert_eq!(
            fair.recv(&mut event_rx, &mut discontinuity_rx)
                .await
                .unwrap()
                .lane_index,
            0
        );
        assert_eq!(
            fair.recv(&mut event_rx, &mut discontinuity_rx)
                .await
                .unwrap()
                .lane_index,
            1,
            "a ready sibling gets the next turn before noisy lane zero"
        );
        drop(discontinuity_tx);
    }

    #[test]
    fn a_lane_failure_survives_callback_coalescing_and_reaches_a_snapshot() {
        // A lane fails exactly once in a session. The callback mailbox holds a
        // single event slot, so if that one transition were published as an
        // edge it would be dropped by the very next token delta and the
        // operator would never learn a column had gone dark.
        let (_temp, core, _profile) = assembler_store_fixture("lane-health-coalescing");
        let (tx, rx) = std::sync::mpsc::channel();
        let callback = CaptureCallbackSink::new(
            Arc::new(CaptureEventSender(tx)),
            (*core.notebook_capture_store).clone(),
            None,
        )
        .unwrap();
        let run = core
            .notebook_capture_store
            .get_run_for_session("lane-health-coalescing")
            .unwrap()
            .unwrap();

        let lanes = [
            StreamAggregationLane {
                descriptor: RemoteStreamLane {
                    target_language: None,
                    canonical: true,
                },
                assembler: RealtimeUtteranceAssembler::new(
                    "lane-health-coalescing".into(),
                    &profile(),
                ),
                provider_session_epoch: 0,
                group_epoch: 0,
                awaiting_reconnect: false,
                connected: true,
                ever_connected: true,
                failed: false,
                input_discontinuous: false,
                final_audio_proc_ms: None,
                total_audio_proc_ms: None,
                lag_ms: None,
                provider_accepted_configuration: true,
                disconnected_at_frame: None,
            },
            StreamAggregationLane {
                descriptor: RemoteStreamLane {
                    target_language: Some("th".to_string()),
                    canonical: false,
                },
                assembler: RealtimeUtteranceAssembler::new(
                    "lane-health-coalescing".into(),
                    &profile(),
                ),
                provider_session_epoch: 0,
                group_epoch: 0,
                awaiting_reconnect: false,
                connected: false,
                ever_connected: true,
                failed: true,
                input_discontinuous: false,
                final_audio_proc_ms: None,
                total_audio_proc_ms: None,
                lag_ms: None,
                provider_accepted_configuration: true,
                disconnected_at_frame: None,
            },
        ];

        let mut transition = event_from_run(run.clone(), Vec::new(), false);
        transition.lane_health = lane_health_snapshot(&lanes);
        let published = callback.send(transition);
        assert_eq!(published.lane_health.len(), 2);

        // The next ordinary delta carries no lane payload of its own. It is
        // what overwrites the single mailbox slot, so it has to keep
        // describing the lanes or the failure is gone for good.
        let plain = callback.send(event_from_run(run.clone(), Vec::new(), false));
        let failed = plain
            .lane_health
            .iter()
            .find(|lane| lane.target_language.as_deref() == Some("th"))
            .expect("a plain delta still describes the failed lane");
        assert_eq!(failed.state, "failed");
        assert!(plain
            .lane_health
            .iter()
            .any(|lane| lane.target_language.is_none() && lane.state == "live"));

        // And the client's rebuild path after a coalescing gap sees it too.
        let snapshot = callback
            .full_snapshot_with_remote_truth("lane-health-coalescing")
            .unwrap();
        assert!(snapshot
            .lane_health
            .iter()
            .any(|lane| lane.target_language.as_deref() == Some("th") && lane.state == "failed"));
        drop(rx);
    }

    #[test]
    fn full_snapshot_revision_is_the_exact_callback_mailbox_checkpoint() {
        let (_temp, core, _profile) = assembler_store_fixture("snapshot-revision-checkpoint");
        let (tx, rx) = std::sync::mpsc::channel();
        let callback = CaptureCallbackSink::new(
            Arc::new(CaptureEventSender(tx)),
            (*core.notebook_capture_store).clone(),
            None,
        )
        .unwrap();
        let run = core
            .notebook_capture_store
            .get_run_for_session("snapshot-revision-checkpoint")
            .unwrap()
            .unwrap();

        let before_callbacks = callback
            .full_snapshot_with_remote_truth("snapshot-revision-checkpoint")
            .unwrap();
        assert_eq!(before_callbacks.event_revision, 0);

        let first = callback.send(event_from_run(run.clone(), Vec::new(), false));
        let second = callback.send(event_from_run(run, Vec::new(), false));
        assert_eq!(first.event_revision, 1);
        assert_eq!(second.event_revision, 2);

        let checkpoint = callback
            .full_snapshot_with_remote_truth("snapshot-revision-checkpoint")
            .unwrap();
        assert!(checkpoint.is_full_snapshot);
        assert_eq!(
            checkpoint.event_revision, second.event_revision,
            "the mailbox-locked snapshot must cover every allocated callback revision"
        );
        drop(rx);
    }

    #[test]
    fn lane_health_snapshot_reports_failed_over_connecting_over_live() {
        let lane = |canonical: bool, target: Option<&str>, connected: bool, failed: bool| {
            StreamAggregationLane {
                descriptor: RemoteStreamLane {
                    target_language: target.map(str::to_string),
                    canonical,
                },
                assembler: RealtimeUtteranceAssembler::new("health-session".into(), &profile()),
                provider_session_epoch: 0,
                group_epoch: 0,
                awaiting_reconnect: !connected && !failed,
                connected,
                ever_connected: true,
                failed,
                input_discontinuous: false,
                final_audio_proc_ms: None,
                total_audio_proc_ms: None,
                lag_ms: None,
                provider_accepted_configuration: true,
                disconnected_at_frame: None,
            }
        };
        let mut thai = lane(false, Some("th"), false, true);
        thai.group_epoch = 3;
        thai.final_audio_proc_ms = Some(4_100);
        thai.total_audio_proc_ms = Some(4_500);
        thai.lag_ms = Some(900);
        thai.input_discontinuous = true;
        let snapshot = lane_health_snapshot(&[
            lane(true, None, true, false),
            lane(false, Some("en"), false, false),
            thai,
        ]);
        assert_eq!(snapshot[0].target_language, None);
        assert_eq!(snapshot[0].state, "live");
        assert_eq!(snapshot[1].target_language.as_deref(), Some("en"));
        assert_eq!(snapshot[2].group_epoch, 3);
        assert_eq!(snapshot[2].final_audio_proc_ms, Some(4_100));
        assert_eq!(snapshot[2].total_audio_proc_ms, Some(4_500));
        assert_eq!(snapshot[2].lag_ms, Some(900));
        assert!(snapshot[2].input_discontinuous);
        assert_eq!(snapshot[1].state, "connecting");
        assert_eq!(snapshot[2].target_language.as_deref(), Some("th"));
        assert_eq!(snapshot[2].state, "failed");
    }

    #[test]
    fn live_translation_cue_snapshot_is_bounded_per_language_and_revision_safe() {
        let cue = |target: &str, sequence: u64, revision: u64, withdrawn: bool| {
            FfiNotebookCaptureTranslationCue {
                target_language: target.to_string(),
                group_epoch: 0,
                provider_sequence: sequence,
                source_language: "en".to_string(),
                source_start_ms: Some(sequence * 100),
                source_end_ms: Some(sequence * 100 + 80),
                text: if withdrawn {
                    String::new()
                } else {
                    format!("{target}-{sequence}-r{revision}")
                },
                completion: "partial".to_string(),
                withdrawn,
                revision,
            }
        };
        let mut current = std::collections::HashMap::new();
        let mut initial = (0..9)
            .map(|sequence| cue("th", sequence, 1, false))
            .collect::<Vec<_>>();
        initial[0].source_start_ms = None;
        initial[0].source_end_ms = None;
        initial.extend((0..2).map(|sequence| cue("zh", sequence, 1, false)));
        reconcile_live_translation_cues(&mut current, &initial);

        let snapshot = live_translation_cue_snapshot(&current);
        assert_eq!(
            snapshot
                .iter()
                .filter(|cue| cue.target_language == "th")
                .count(),
            LIVE_TRANSLATION_CUES_PER_LANGUAGE
        );
        assert!(snapshot
            .iter()
            .all(|cue| { cue.target_language != "th" || cue.provider_sequence != 0 }));
        assert_eq!(
            snapshot
                .iter()
                .filter(|cue| cue.target_language == "zh")
                .count(),
            2
        );

        reconcile_live_translation_cues(&mut current, &[cue("th", 8, 2, false)]);
        reconcile_live_translation_cues(&mut current, &[cue("th", 8, 1, true)]);
        assert_eq!(
            current
                .get(&(0, 8, "th".to_string()))
                .expect("stale withdrawal cannot remove the newer partial")
                .revision,
            2
        );
        reconcile_live_translation_cues(&mut current, &[cue("th", 8, 3, true)]);
        assert!(!current.contains_key(&(0, 8, "th".to_string())));
    }

    #[test]
    fn translation_cues_flow_through_deltas_and_snapshots_without_binding() {
        let (_temp, core, _profile) = assembler_store_fixture("cue-flow-session");
        let key = |provider_sequence: u64, target_language: &str| RealtimeTranslationInboxKey {
            session_id: "cue-flow-session".into(),
            lane_index: 1,
            group_epoch: 0,
            provider_sequence,
            target_language: target_language.into(),
        };

        // A partial auxiliary segment is durable and publishable immediately —
        // its canonical row does not exist yet and never has to.
        let partial = core
            .notebook_capture_store
            .upsert_translation_inbox_item(&NewRealtimeTranslationInboxItem {
                key: key(0, "th"),
                source_language: "zh".into(),
                source_text: "你好".into(),
                source_start_ms: Some(1_000),
                source_end_ms: Some(1_600),
                translated_text: Some("สวัส".into()),
                completion: Some(UtteranceCompletion::Partial),
                withdrawn: false,
            })
            .unwrap();
        assert!(partial.changed);
        let cue = translation_cue_from_inbox_item(&partial.item);
        assert_eq!(cue.target_language, "th");
        assert_eq!(cue.completion, "partial");
        assert_eq!(cue.source_start_ms, Some(1_000));
        assert!(!cue.withdrawn);

        let finalized = core
            .notebook_capture_store
            .upsert_translation_inbox_item(&NewRealtimeTranslationInboxItem {
                key: key(0, "th"),
                source_language: "zh".into(),
                source_text: "你好".into(),
                source_start_ms: Some(1_000),
                source_end_ms: Some(1_600),
                translated_text: Some("สวัสดี".into()),
                completion: Some(UtteranceCompletion::Complete),
                withdrawn: false,
            })
            .unwrap();
        assert!(finalized.changed);
        let final_cue = translation_cue_from_inbox_item(&finalized.item);
        assert_eq!(final_cue.completion, "complete");
        assert!(final_cue.revision > cue.revision);

        // A second segment is withdrawn: the tombstone instructs removal.
        core.notebook_capture_store
            .upsert_translation_inbox_item(&NewRealtimeTranslationInboxItem {
                key: key(1, "th"),
                source_language: "zh".into(),
                source_text: "再见".into(),
                source_start_ms: Some(2_000),
                source_end_ms: Some(2_400),
                translated_text: Some("ลาก่อน".into()),
                completion: Some(UtteranceCompletion::Partial),
                withdrawn: false,
            })
            .unwrap();
        let withdrawn = core
            .notebook_capture_store
            .upsert_translation_inbox_item(&NewRealtimeTranslationInboxItem {
                key: key(1, "th"),
                source_language: "zh".into(),
                source_text: "再见".into(),
                source_start_ms: Some(2_000),
                source_end_ms: Some(2_400),
                translated_text: None,
                completion: None,
                withdrawn: true,
            })
            .unwrap();
        assert!(withdrawn.changed);
        let tombstone = translation_cue_from_inbox_item(&withdrawn.item);
        assert!(tombstone.withdrawn);
        assert!(tombstone.text.is_empty());

        // The full snapshot carries every present cue — the still-partial and
        // the complete alike — and never a withdrawn tombstone. A canonical
        // utterance row was never created in this test.
        let run = core
            .notebook_capture_store
            .get_run_for_session("cue-flow-session")
            .unwrap()
            .unwrap();
        let event = event_full_snapshot_from_run(&core.notebook_capture_store, run).unwrap();
        assert!(event.utterances.is_empty());
        assert_eq!(event.translation_cues.len(), 1);
        assert_eq!(event.translation_cues[0].text, "สวัสดี");
        assert_eq!(event.translation_cues[0].completion, "complete");
        assert_eq!(event.translation_cues[0].group_epoch, 0);
        assert_eq!(event.translation_cues[0].provider_sequence, 0);
    }

    #[test]
    fn source_withdrawal_preserves_an_independently_final_translation_lane() {
        let (_temp, core, runtime_profile) =
            assembler_store_fixture("lane-withdraw-source-final-translation");
        let mut assembler = RealtimeUtteranceAssembler::new(
            "lane-withdraw-source-final-translation".into(),
            &runtime_profile,
        );
        let initial = assembler.apply_tokens(&[
            attributed_token(
                "ghost",
                SttStreamTranslationStatus::Original,
                Some("en"),
                None,
                Some("speaker-a"),
                false,
            ),
            attributed_token(
                "临时",
                SttStreamTranslationStatus::Translation,
                Some("zh"),
                Some("en"),
                Some("speaker-a"),
                true,
            ),
        ]);
        let source =
            persist_assembled_utterances(&core.notebook_capture_store, &mut assembler, initial, 0)
                .unwrap()
                .remove(0);
        core.notebook_capture_store
            .upsert_translation_variant(
                &source.session_id,
                source.sequence,
                "zh",
                Some("独立终稿"),
                UtteranceVariantState::Ready,
                Some(UtteranceCompletion::Complete),
            )
            .unwrap();

        let withdrawn = assembler.apply_tokens(&[]);
        assert_eq!(withdrawn.len(), 1);
        assert!(withdrawn[0].remove_partial);
        let removal = persist_assembled_utterances(
            &core.notebook_capture_store,
            &mut assembler,
            withdrawn,
            0,
        )
        .unwrap();
        assert!(removal.requires_full_snapshot);

        let shell = core
            .notebook_capture_store
            .list_machine_utterances(&source.session_id)
            .unwrap()
            .remove(0);
        assert!(!shell.has_source_lane());
        let lanes = finalized_capture_lanes(std::slice::from_ref(&shell));
        assert_eq!(lanes.len(), 1);
        assert!(matches!(
            lanes[0].kind,
            FinalizedCaptureLaneKind::Translation
        ));
        assert_eq!(lanes[0].language, "zh");
        assert_eq!(lanes[0].text, "独立终稿");
    }

    #[test]
    fn final_auxiliary_shell_retires_canonical_identity_before_source_returns() {
        for (suffix, source_language, target_language) in
            [("different", "en", "zh"), ("same", "zh", "zh")]
        {
            let session_id = format!("lane-final-shell-source-return-{suffix}");
            let (_temp, core, runtime_profile) = assembler_store_fixture(&session_id);
            let mut assembler =
                RealtimeUtteranceAssembler::new(session_id.clone(), &runtime_profile);

            assert!(assembler
                .apply_tokens(&[token(
                    "mutable source",
                    SttStreamTranslationStatus::Original,
                    source_language,
                    Some(100),
                    Some(900),
                    false,
                )])
                .is_empty());
            let preview = assembler.live_previews().remove(0);
            let source = persist_assembled_utterances(
                &core.notebook_capture_store,
                &mut assembler,
                vec![AssembledRealtimeUtterance {
                    utterance: NewRealtimeUtterance {
                        source_language: source_language.into(),
                        ..preview.utterance
                    },
                    provisional_source_language: None,
                    source_dirty: true,
                    translation_dirty: false,
                    translation_completion: None,
                    translation_clear_language: None,
                    remove_partial: false,
                    provider_speaker: None,
                    expected_revision: None,
                }],
                0,
            )
            .unwrap()
            .utterances
            .remove(0);
            assert_eq!(source.sequence, 0);

            let accepted = core
                .notebook_capture_store
                .upsert_translation_inbox_item(&NewRealtimeTranslationInboxItem {
                    key: RealtimeTranslationInboxKey {
                        session_id: session_id.clone(),
                        lane_index: 1,
                        group_epoch: 0,
                        provider_sequence: 0,
                        target_language: target_language.into(),
                    },
                    source_language: source_language.into(),
                    source_text: source.source_text.clone(),
                    source_start_ms: source.source_start_ms,
                    source_end_ms: source.source_end_ms,
                    translated_text: Some(format!("{suffix} auxiliary Final")),
                    completion: Some(UtteranceCompletion::Complete),
                    withdrawn: false,
                })
                .unwrap();
            assert_eq!(accepted.item.bound_sequence, Some(0));

            let withdrawn = assembler.apply_tokens(&[]);
            assert_eq!(withdrawn.len(), 1);
            assert!(withdrawn[0].remove_partial);
            let removal = persist_assembled_utterances(
                &core.notebook_capture_store,
                &mut assembler,
                withdrawn,
                0,
            )
            .unwrap();
            let shell = removal.utterances.first().unwrap();
            assert_eq!(shell.sequence, 0);
            assert!(!shell.has_source_lane());
            assert!(shell.variants.iter().any(|variant| {
                variant.role == UtteranceVariantRole::Translation
                    && variant.language == target_language
                    && variant.completion == Some(UtteranceCompletion::Complete)
            }));
            assert!(assembler.segments[0].complete);
            assert_eq!(assembler.latest_original_segment, None);

            // Canonical speech can return immediately, but it is a new source
            // identity. It must never revise or detach the immutable shell.
            assert!(assembler
                .apply_tokens(&[token(
                    "returned source",
                    SttStreamTranslationStatus::Original,
                    source_language,
                    Some(2_000),
                    Some(2_800),
                    false,
                )])
                .is_empty());
            let returned_preview = assembler.live_previews().remove(0);
            assert_eq!(returned_preview.utterance.sequence, 1);
            assert_ne!(returned_preview.utterance.id, shell.id);
            let returned = persist_assembled_utterances(
                &core.notebook_capture_store,
                &mut assembler,
                vec![AssembledRealtimeUtterance {
                    utterance: NewRealtimeUtterance {
                        source_language: source_language.into(),
                        ..returned_preview.utterance
                    },
                    provisional_source_language: None,
                    source_dirty: true,
                    translation_dirty: false,
                    translation_completion: None,
                    translation_clear_language: None,
                    remove_partial: false,
                    provider_speaker: None,
                    expected_revision: None,
                }],
                0,
            )
            .unwrap()
            .utterances
            .remove(0);
            assert_eq!(returned.sequence, 1);

            let inline_target_language = if source_language == "en" { "zh" } else { "en" };
            let routed_translation = format!("{suffix} routed inline translation");
            let routed = assembler.apply_tokens(&[
                token(
                    "returned source",
                    SttStreamTranslationStatus::Original,
                    source_language,
                    Some(2_000),
                    Some(2_800),
                    false,
                ),
                SttStreamToken {
                    text: routed_translation.clone(),
                    start_ms: None,
                    end_ms: None,
                    is_final: false,
                    confidence: None,
                    translation_status: SttStreamTranslationStatus::Translation,
                    language: Some(inline_target_language.into()),
                    source_language: Some(source_language.into()),
                    speaker: None,
                },
            ]);
            assert_eq!(assembler.latest_translation_segment, Some(1));
            assert!(routed.iter().all(|update| update.utterance.sequence == 1));
            assert!(assembler.segments[0].translated.is_empty());
            assert_eq!(assembler.segments[1].translated.pending, routed_translation);
            let routed = persist_assembled_utterances(
                &core.notebook_capture_store,
                &mut assembler,
                routed,
                0,
            )
            .unwrap()
            .utterances
            .remove(0);
            assert_eq!(routed.sequence, 1);

            let replacement = assembler.apply_tokens(&[token(
                "replacement identity",
                SttStreamTranslationStatus::Original,
                source_language,
                Some(4_000),
                Some(4_900),
                false,
            )]);
            let replaced = persist_assembled_utterances(
                &core.notebook_capture_store,
                &mut assembler,
                replacement,
                0,
            )
            .expect("a returned canonical Partial must revise its own row, not the Final shell")
            .utterances
            .remove(0);
            assert_eq!(replaced.sequence, 1);
            assert_eq!(replaced.source_text, "replacement identity");
            assert_eq!(replaced.source_start_ms, Some(4_000));
            assert_eq!(replaced.source_end_ms, Some(4_900));

            let rows = core
                .notebook_capture_store
                .list_machine_utterances(&session_id)
                .unwrap();
            assert_eq!(rows.len(), 2);
            let stable_shell = rows.iter().find(|row| row.sequence == 0).unwrap();
            assert!(!stable_shell.has_source_lane());
            assert!(stable_shell.variants.iter().any(|variant| {
                variant.language == target_language
                    && variant.completion == Some(UtteranceCompletion::Complete)
            }));

            let finalized = assembler.finalize();
            assert!(!finalized.is_empty());
            assert!(finalized
                .iter()
                .all(|update| update.utterance.sequence == 1));
        }
    }

    #[test]
    fn hidden_same_language_aux_partial_survives_source_language_revision_and_withdrawal() {
        let session_id = "lane-hidden-aux-source-withdrawal";
        let (_temp, core, mut runtime_profile) = assembler_store_fixture(session_id);
        runtime_profile.language_a = "zh".into();
        runtime_profile.language_b = "th".into();
        runtime_profile.left_language = "zh".into();
        runtime_profile.right_language = "th".into();
        runtime_profile.selected_languages = vec!["zh".into(), "th".into()];
        let mut assembler =
            RealtimeUtteranceAssembler::new(session_id.to_string(), &runtime_profile);

        assert!(assembler
            .apply_tokens(&[token(
                "暂定",
                SttStreamTranslationStatus::Original,
                "zh",
                Some(100),
                Some(300),
                false,
            )])
            .is_empty());
        let preview = assembler.live_previews().remove(0);
        let initial = AssembledRealtimeUtterance {
            utterance: NewRealtimeUtterance {
                source_language: "zh".into(),
                ..preview.utterance
            },
            provisional_source_language: None,
            source_dirty: true,
            translation_dirty: false,
            translation_completion: None,
            translation_clear_language: None,
            remove_partial: false,
            provider_speaker: None,
            expected_revision: None,
        };
        let source = persist_assembled_utterances(
            &core.notebook_capture_store,
            &mut assembler,
            vec![initial],
            0,
        )
        .unwrap()
        .utterances
        .remove(0);
        assert!(source.has_source_lane());
        assert_eq!(source.completion, UtteranceCompletion::Partial);

        let accepted = core
            .notebook_capture_store
            .upsert_translation_inbox_item(&NewRealtimeTranslationInboxItem {
                key: RealtimeTranslationInboxKey {
                    session_id: session_id.into(),
                    lane_index: 1,
                    group_epoch: 0,
                    provider_sequence: 0,
                    target_language: "zh".into(),
                },
                source_language: "zh".into(),
                source_text: "暂定".into(),
                source_start_ms: Some(100),
                source_end_ms: Some(300),
                translated_text: Some("辅助 Partial".into()),
                completion: Some(UtteranceCompletion::Partial),
                withdrawn: false,
            })
            .unwrap();
        assert_eq!(accepted.item.bound_sequence, Some(0));
        assert_eq!(
            accepted.bound_utterance, None,
            "the provisional source retains same-language display priority"
        );

        let mut revised = assembler.apply_tokens(&[token(
            "ภาษาไทยชั่วคราว",
            SttStreamTranslationStatus::Original,
            "th",
            Some(100),
            Some(300),
            false,
        )]);
        assert_eq!(
            revised.len(),
            1,
            "a segment already durable in SQLite must publish its replacement"
        );
        revised[0].utterance.source_language = "th".into();
        let revised =
            persist_assembled_utterances(&core.notebook_capture_store, &mut assembler, revised, 0)
                .unwrap()
                .utterances
                .remove(0);
        assert!(revised.has_source_lane());
        let auxiliary = revised
            .variants
            .iter()
            .find(|variant| variant.language == "zh")
            .expect("source language revision materializes the bound auxiliary lane");
        assert_eq!(auxiliary.role, UtteranceVariantRole::Translation);
        assert_eq!(auxiliary.text.as_deref(), Some("辅助 Partial"));
        assert_eq!(
            assembler
                .segments
                .iter()
                .find(|segment| segment.id == revised.id)
                .and_then(|segment| segment.persisted_translation_language.as_deref()),
            None,
            "external lanes must not become the canonical inline-translation clear target"
        );

        let withdrawn = assembler.apply_tokens(&[]);
        assert_eq!(withdrawn.len(), 1);
        assert!(withdrawn[0].remove_partial);
        let removal = persist_assembled_utterances(
            &core.notebook_capture_store,
            &mut assembler,
            withdrawn,
            0,
        )
        .unwrap();
        assert!(removal.requires_full_snapshot);
        let shell = removal
            .utterances
            .first()
            .expect("the bound auxiliary Partial keeps the shell alive");
        assert!(!shell.has_source_fact());
        assert!(!shell.has_source_lane());
        let auxiliary = shell
            .variants
            .iter()
            .find(|variant| variant.language == "zh")
            .unwrap();
        assert_eq!(auxiliary.role, UtteranceVariantRole::Translation);
        assert_eq!(auxiliary.completion, Some(UtteranceCompletion::Partial));
        assert_eq!(auxiliary.text.as_deref(), Some("辅助 Partial"));
        assert_eq!(auxiliary.projection_revision, 0);
    }

    #[test]
    fn canonical_finalize_never_clears_bound_external_partial_or_final() {
        for (suffix, completion, text) in [
            ("partial", UtteranceCompletion::Partial, "辅助 Partial"),
            ("final", UtteranceCompletion::Complete, "辅助 Final"),
        ] {
            let session_id = format!("lane-external-survives-finalize-{suffix}");
            let (_temp, core, runtime_profile) = assembler_store_fixture(&session_id);
            let mut assembler =
                RealtimeUtteranceAssembler::new(session_id.clone(), &runtime_profile);
            let initial = assembler.apply_tokens(&[attributed_token(
                "hello",
                SttStreamTranslationStatus::Original,
                Some("en"),
                None,
                Some("speaker-a"),
                true,
            )]);
            assert_eq!(initial.len(), 1);
            let source = persist_assembled_utterances(
                &core.notebook_capture_store,
                &mut assembler,
                initial,
                0,
            )
            .unwrap()
            .utterances
            .remove(0);
            assert_eq!(source.completion, UtteranceCompletion::Partial);

            let accepted = core
                .notebook_capture_store
                .upsert_translation_inbox_item(&NewRealtimeTranslationInboxItem {
                    key: RealtimeTranslationInboxKey {
                        session_id: session_id.clone(),
                        lane_index: 1,
                        group_epoch: 0,
                        provider_sequence: 0,
                        target_language: "zh".into(),
                    },
                    source_language: "en".into(),
                    source_text: "hello".into(),
                    source_start_ms: None,
                    source_end_ms: None,
                    translated_text: Some(text.into()),
                    completion: Some(completion),
                    withdrawn: false,
                })
                .unwrap();
            let visible = accepted
                .bound_utterance
                .expect("different-language auxiliary fact materializes");
            canonical_assembler_record_external_state(&mut assembler, &visible, "zh");
            assert_eq!(
                assembler
                    .segments
                    .iter()
                    .find(|segment| segment.id == source.id)
                    .and_then(|segment| segment.persisted_translation_language.as_deref()),
                None
            );

            let finalized = assembler.finalize();
            assert_eq!(finalized.len(), 1);
            assert_eq!(finalized[0].translation_clear_language, None);
            let finalized = persist_assembled_utterances(
                &core.notebook_capture_store,
                &mut assembler,
                finalized,
                0,
            )
            .unwrap()
            .utterances
            .remove(0);
            assert!(finalized.source_lane_is_complete());
            let auxiliary = finalized
                .variants
                .iter()
                .find(|variant| variant.language == "zh")
                .unwrap();
            assert_eq!(auxiliary.text.as_deref(), Some(text));
            assert_eq!(auxiliary.completion, Some(completion));
        }
    }

    #[test]
    fn one_assembled_delta_can_withdraw_source_and_finalize_translation_atomically() {
        let (_temp, core, runtime_profile) = assembler_store_fixture("lane-atomic-withdraw-final");
        let mut assembler =
            RealtimeUtteranceAssembler::new("lane-atomic-withdraw-final".into(), &runtime_profile);
        let initial = assembler.apply_tokens(&[
            attributed_token(
                "temporary",
                SttStreamTranslationStatus::Original,
                Some("en"),
                None,
                Some("speaker-a"),
                false,
            ),
            attributed_token(
                "临时",
                SttStreamTranslationStatus::Translation,
                Some("zh"),
                Some("en"),
                Some("speaker-a"),
                true,
            ),
        ]);
        persist_assembled_utterances(&core.notebook_capture_store, &mut assembler, initial, 0)
            .unwrap();

        let mut delta = assembler.apply_tokens(&[]);
        assert_eq!(delta.len(), 1);
        assert!(delta[0].remove_partial);
        delta[0].translation_dirty = true;
        delta[0].translation_clear_language = None;
        delta[0].utterance.translated_language = Some("zh".into());
        delta[0].utterance.translated_text = Some("终稿".into());
        delta[0].translation_completion = Some(UtteranceCompletion::Complete);
        let persisted =
            persist_assembled_utterances(&core.notebook_capture_store, &mut assembler, delta, 0)
                .unwrap();
        assert!(persisted.requires_full_snapshot);
        let shell = persisted.utterances.first().unwrap();
        assert!(!shell.has_source_lane());
        let zh = shell
            .variants
            .iter()
            .find(|variant| variant.language == "zh")
            .unwrap();
        assert_eq!(zh.text.as_deref(), Some("终稿"));
        assert_eq!(zh.completion, Some(UtteranceCompletion::Complete));
        assert!(zh.projection_revision > 0);
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
            UtteranceCompletion::Partial,
            "provider-pending text remains SQLite-only when the stream is forced closed"
        );
        assert!(assembler.live_previews().is_empty());
    }

    #[test]
    fn live_preview_carries_provisional_language_before_identity_commit() {
        let mut assembler =
            RealtimeUtteranceAssembler::new("session-provisional".into(), &profile());

        assert!(assembler
            .apply_tokens(&[attributed_token(
                "你好",
                SttStreamTranslationStatus::Original,
                Some("zh"),
                None,
                None,
                false,
            )])
            .is_empty());
        let pending = assembler.live_previews();
        assert_eq!(pending.len(), 1);
        assert_eq!(pending[0].utterance.source_language, "und");
        assert_eq!(
            pending[0].provisional_source_language.as_deref(),
            Some("zh"),
            "the unambiguous pending provider language surfaces as a display hint"
        );
        let ffi = ffi_live_preview(pending.into_iter().next().unwrap());
        assert_eq!(ffi.source_language, "und");
        assert_eq!(ffi.provisional_source_language.as_deref(), Some("zh"));

        let committed = assembler.apply_tokens(&[attributed_token(
            "你好",
            SttStreamTranslationStatus::Original,
            Some("zh"),
            None,
            None,
            true,
        )]);
        let committed_previews = assembler.live_previews();
        assert_eq!(committed_previews.len(), 1);
        assert_eq!(committed_previews[0].utterance.source_language, "zh");
        assert_eq!(
            committed_previews[0].provisional_source_language, None,
            "a committed identity never needs the display hint"
        );
        for update in committed {
            assert_eq!(update.provisional_source_language, None);
        }
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
        assert_eq!(neutral.completion, UtteranceCompletion::Partial);
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
                UtteranceCompletion::Partial
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
    fn realtime_continuity_window_includes_exactly_fifteen_seconds() {
        assert!(outage_is_continuous(1_000));
        assert!(outage_is_continuous(5_000));
        assert!(outage_is_continuous(15_000));
        assert!(!outage_is_continuous(15_001));
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
            session_id: "matching-session".into(),
            group_epoch: 0,
            source_sequence: 99,
            source_language: "th".into(),
            source_text: "good morning 🌏".into(),
            source_start_ms: Some(120),
            source_end_ms: Some(220),
            target_language: "zh".into(),
            completion: UtteranceCompletion::Partial,
            reverse_conflict_warned: false,
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
        let equal_evidence = [
            candidate(98, 0, Some(110), Some(230)),
            candidate(100, 0, Some(110), Some(230)),
        ];
        assert_eq!(
            match_canonical_sequence(&pending, equal_evidence.iter()),
            None,
            "canonical sequence is not evidence; equal best rows stay durably unbound"
        );
        let mut different_text = candidate(1, 0, Some(110), Some(230));
        different_text.utterance.source_text = "คนละประโยค".into();
        let text_disambiguated = [different_text, candidate(2, 0, Some(150), Some(260))];
        assert_eq!(
            match_canonical_sequence(&pending, text_disambiguated.iter()),
            Some(2),
            "source text may disambiguate otherwise overlapping time windows"
        );

        let mut contradictory = candidate(99, 0, Some(300), Some(400));
        contradictory.utterance.source_text = "คนละประโยค".into();
        assert_eq!(
            match_canonical_sequence(&pending, std::iter::once(&contradictory)),
            None,
            "an equal sequence must not override contradictory timestamps"
        );

        // A repeated phrase much later in the capture must not bind back to an
        // earlier row just because its normalized text is identical.
        let disjoint_same_text = [candidate(7, 0, Some(4_300), Some(4_400))];
        assert_eq!(
            match_canonical_sequence(&pending, disjoint_same_text.iter()),
            None,
            "identical source text cannot override disjoint capture time"
        );

        let mut repeated_filler = pending.clone();
        repeated_filler.source_sequence = 8;
        repeated_filler.source_text = "okay".into();
        repeated_filler.source_start_ms = Some(4_300);
        repeated_filler.source_end_ms = Some(4_400);
        let mut stale_filler = candidate(7, 0, Some(4_100), Some(4_200));
        stale_filler.utterance.source_text = "okay".into();
        assert_eq!(
            match_canonical_sequence(&repeated_filler, std::iter::once(&stale_filler)),
            None,
            "a nearby earlier filler stays unbound until a truly overlapping row exists"
        );
        stale_filler.utterance.source_end_ms = Some(4_300);
        assert_eq!(
            match_canonical_sequence(&repeated_filler, std::iter::once(&stale_filler)),
            None,
            "positive-duration intervals that only touch at an endpoint share no audio"
        );
        let mut current_window = candidate(8, 0, Some(4_250), Some(4_450));
        current_window.utterance.source_text = "different partial words".into();
        assert_eq!(
            match_canonical_sequence(&repeated_filler, [stale_filler, current_window].iter()),
            Some(8),
            "an overlapping current row outranks an exact but stale repeated filler"
        );

        let mut missing_time = pending.clone();
        missing_time.source_start_ms = None;
        missing_time.source_end_ms = None;
        missing_time.source_text = "okay".into();
        let mut first_missing = candidate(98, 0, None, None);
        first_missing.utterance.source_text = "okay".into();
        let mut second_missing = candidate(100, 0, None, None);
        second_missing.utterance.source_text = "okay".into();
        assert_eq!(
            match_canonical_sequence(&missing_time, [first_missing, second_missing].iter()),
            None,
            "cross-stream sequence distance cannot disambiguate repeated text without time"
        );
        let mut sequence_only = candidate(99, 0, None, None);
        sequence_only.utterance.source_text = "different words".into();
        assert_eq!(
            match_canonical_sequence(&missing_time, std::iter::once(&sequence_only)),
            None,
            "an equal cross-stream sequence number is not alignment evidence"
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
    fn cross_row_spans_flag_only_material_overlap_within_the_bound_epoch() {
        let candidate = |sequence, group_epoch, start_ms, end_ms| {
            let mut utterance = projected_utterance();
            utterance.sequence = sequence;
            utterance.source_language = "zh".into();
            utterance.source_start_ms = start_ms;
            utterance.source_end_ms = end_ms;
            CanonicalUtteranceMatch {
                group_epoch,
                utterance,
            }
        };
        // The observed field failure: one auxiliary segment swallowing the
        // first canonical row plus most of the second.
        let pending = PendingTranslationVariant {
            session_id: "cross-row-session".into(),
            group_epoch: 0,
            source_sequence: 0,
            source_language: "zh".into(),
            source_text: "跨行的辅助段".into(),
            source_start_ms: Some(600),
            source_end_ms: Some(28_920),
            target_language: "th".into(),
            completion: UtteranceCompletion::Complete,
            reverse_conflict_warned: false,
        };
        let rows = [
            candidate(0, 0, Some(600), Some(5_160)),
            candidate(1, 0, Some(6_180), Some(56_640)),
            candidate(2, 1, Some(6_180), Some(56_640)),
        ];
        assert_eq!(
            cross_row_translation_spans(&pending, 0, rows.iter()),
            vec![1],
            "a segment covering most of a second row is a divergence signal; \
             another epoch's identical window is not comparable evidence"
        );

        // Aligned endpointing: the segment matches its own row and only grazes
        // the neighbor across the boundary silence.
        let aligned = PendingTranslationVariant {
            source_start_ms: Some(600),
            source_end_ms: Some(6_500),
            ..pending.clone()
        };
        assert_eq!(
            cross_row_translation_spans(&aligned, 0, rows.iter()),
            Vec::<u64>::new(),
            "boundary skew from network lag must not raise the divergence flag"
        );
    }

    #[test]
    fn an_unbound_auxiliary_final_latches_one_warning_and_a_partial_latches_none() {
        let row = |sequence, start_ms, end_ms| {
            let mut utterance = projected_utterance();
            utterance.sequence = sequence;
            utterance.source_language = "zh".into();
            utterance.source_start_ms = Some(start_ms);
            utterance.source_end_ms = Some(end_ms);
            (
                (0, sequence),
                CanonicalUtteranceMatch {
                    group_epoch: 0,
                    utterance,
                },
            )
        };
        let canonical_matches = std::collections::HashMap::from([row(0, 0, 10_000)]);
        let pending_key = (3, 0, 1);
        // A Final segment the store refused to place on any row.
        let pending = PendingTranslationVariant {
            session_id: "reverse-session".into(),
            group_epoch: 0,
            source_sequence: 1,
            source_language: "zh".into(),
            source_text: "后半段".into(),
            source_start_ms: Some(5_000),
            source_end_ms: Some(10_000),
            target_language: "th".into(),
            completion: UtteranceCompletion::Complete,
            reverse_conflict_warned: false,
        };
        let mut pending_variants = std::collections::HashMap::from([(pending_key, pending)]);

        warn_unbound_auxiliary_final(&pending_key, &mut pending_variants, &canonical_matches);
        assert!(
            pending_variants[&pending_key].reverse_conflict_warned,
            "an unplaceable Final segment must latch the warning"
        );

        let mut partial_variants = pending_variants.clone();
        partial_variants
            .get_mut(&pending_key)
            .unwrap()
            .reverse_conflict_warned = false;
        partial_variants.get_mut(&pending_key).unwrap().completion = UtteranceCompletion::Partial;
        warn_unbound_auxiliary_final(&pending_key, &mut partial_variants, &canonical_matches);
        assert!(
            !partial_variants[&pending_key].reverse_conflict_warned,
            "a still-open Partial legitimately waits and must not raise the flag"
        );
    }

    #[test]
    fn segmentation_barrier_reaches_only_live_auxiliary_lanes_and_debounces() {
        let lane = |canonical: bool, target: Option<&str>, connected, awaiting_reconnect| {
            StreamAggregationLane {
                descriptor: RemoteStreamLane {
                    target_language: target.map(str::to_string),
                    canonical,
                },
                assembler: RealtimeUtteranceAssembler::new("barrier-session".into(), &profile()),
                provider_session_epoch: 0,
                group_epoch: 0,
                awaiting_reconnect,
                connected,
                ever_connected: connected,
                failed: false,
                input_discontinuous: false,
                final_audio_proc_ms: None,
                total_audio_proc_ms: None,
                lag_ms: None,
                provider_accepted_configuration: connected,
                disconnected_at_frame: None,
            }
        };
        let lanes = vec![
            lane(true, None, true, false),
            lane(false, Some("en"), true, false),
            lane(false, Some("th"), false, false),
            lane(false, Some("ja"), true, true),
        ];
        let (canonical_tx, mut canonical_rx) = tokio::sync::mpsc::channel(4);
        let (en_tx, mut en_rx) = tokio::sync::mpsc::channel(4);
        let (th_tx, mut th_rx) = tokio::sync::mpsc::channel(4);
        let (ja_tx, mut ja_rx) = tokio::sync::mpsc::channel(4);
        // The canonical lane keeps `None` in production; a live sender here
        // proves the guard on the descriptor, not just on the caller.
        let controls = vec![Some(canonical_tx), Some(en_tx), Some(th_tx), Some(ja_tx)];

        let mut last_broadcast = None;
        broadcast_segment_boundary_to_auxiliary_lanes(&lanes, &controls, &mut last_broadcast);
        assert_eq!(
            en_rx.try_recv(),
            Ok(SttStreamControl::Finalize),
            "a connected auxiliary lane finalizes at the canonical boundary"
        );
        assert!(
            th_rx.try_recv().is_err(),
            "a disconnected lane must not queue a finalize for a stale audio position"
        );
        assert!(
            ja_rx.try_recv().is_err(),
            "a lane awaiting reconnect must not queue a finalize either"
        );
        assert!(
            canonical_rx.try_recv().is_err(),
            "the segmentation authority never finalizes itself"
        );
        assert!(last_broadcast.is_some());

        broadcast_segment_boundary_to_auxiliary_lanes(&lanes, &controls, &mut last_broadcast);
        assert!(
            en_rx.try_recv().is_err(),
            "a second endpoint inside the debounce window must not repeat the barrier"
        );
    }

    #[test]
    fn cross_stream_pairing_requires_unique_text_when_timestamps_are_unavailable() {
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
            session_id: "matching-session".into(),
            group_epoch: 4,
            source_sequence: 7,
            source_language: "th".into(),
            source_text: "good morning 🌏".into(),
            source_start_ms: None,
            source_end_ms: None,
            target_language: "en".into(),
            completion: UtteranceCompletion::Partial,
            reverse_conflict_warned: false,
        };
        let unique = [candidate(6)];
        assert_eq!(
            match_canonical_sequence(&pending, unique.iter()),
            Some(6),
            "unique exact words remain a valid missing-time fallback"
        );

        let candidates = [candidate(6), candidate(7)];
        assert_eq!(
            match_canonical_sequence(&pending, candidates.iter()),
            None,
            "cross-stream sequence distance cannot choose between equal word evidence"
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
            session_id: "matching-session".into(),
            group_epoch: 0,
            source_sequence: 7,
            source_language: "th".into(),
            source_text: "สวัสดี".into(),
            source_start_ms: Some(100),
            source_end_ms: Some(300),
            target_language: "zh".into(),
            completion: UtteranceCompletion::Partial,
            reverse_conflict_warned: false,
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
                    projection_revision: 1,
                    edit_revision: 0,
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
                    projection_revision: u64::from(
                        thai_completion == UtteranceCompletion::Complete,
                    ),
                    edit_revision: 0,
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
        let mut pending_variants = std::collections::HashMap::new();

        let recycled = prune_resolved_stream_aggregation_history(
            &selected_languages,
            &mut canonical_matches,
            &mut pending_variants,
            &mut variant_bindings,
            &mut reverse_variant_bindings,
            &mut initialized_variants,
        );

        assert_eq!(recycled, 13);
        assert_eq!(
            canonical_matches.len(),
            STREAM_AGGREGATION_RECENT_UTTERANCE_WINDOW
        );
        assert!(!canonical_matches.contains_key(&(0, 0)));
        assert!(!canonical_matches.contains_key(&(0, 12)));
        assert!(canonical_matches.contains_key(&(0, unfinished_sequence)));
        assert_eq!(
            variant_bindings.len(),
            STREAM_AGGREGATION_RECENT_UTTERANCE_WINDOW * 2
        );
        assert_eq!(
            reverse_variant_bindings.len(),
            STREAM_AGGREGATION_RECENT_UTTERANCE_WINDOW * 2
        );
        assert_eq!(
            initialized_variants.len(),
            STREAM_AGGREGATION_RECENT_UTTERANCE_WINDOW * 2
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
                failed: false,
                input_discontinuous: false,
                final_audio_proc_ms: None,
                total_audio_proc_ms: None,
                lag_ms: None,
                provider_accepted_configuration: true,
                disconnected_at_frame: None,
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
                provisional_source_language: None,
                source_dirty: true,
                translation_dirty: translated_text.is_some(),
                translation_completion: translated_text.map(|_| completion),
                translation_clear_language: None,
                remove_partial: false,
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
        assert_eq!(timeline_partial.len(), 1);
        let durable_partial = core
            .notebook_capture_store
            .list_utterances(&session.id)
            .unwrap()
            .remove(0);
        assert_eq!(durable_partial.completion, UtteranceCompletion::Partial);
        assert_eq!(durable_partial.source_text, "สวัสดี");
        let durable_partial_translation = durable_partial
            .variants
            .iter()
            .find(|variant| variant.language == "zh")
            .expect("the pending auxiliary partial should bind durably");
        assert_eq!(
            durable_partial_translation.completion,
            Some(UtteranceCompletion::Partial)
        );

        let mut canonical_final =
            update("canonical-utterance", None, UtteranceCompletion::Complete);
        canonical_final.expected_revision = Some(durable_partial.revision);
        let canonical = persist_stream_lane_updates(
            &core.notebook_capture_store,
            &mut lanes,
            0,
            0,
            vec![canonical_final],
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

        // A late provider revision for the same key after its inbox fact went
        // Complete is rejected by the immutable fact, and that rejection must
        // stay non-fatal to the live capture.
        let late_revision = persist_stream_lane_updates(
            &core.notebook_capture_store,
            &mut lanes,
            0,
            1,
            vec![update(
                "aux-utterance",
                Some("你们好"),
                UtteranceCompletion::Complete,
            )],
            &selected_languages,
            &mut canonical_matches,
            &mut pending_variants,
            &mut variant_bindings,
            &mut reverse_variant_bindings,
            &mut initialized_variants,
        )
        .expect("a late revision of a final inbox fact must not interrupt the capture");
        assert!(late_revision.is_empty());
        let zh_after = core
            .notebook_capture_store
            .list_utterances(&session.id)
            .unwrap()
            .remove(0)
            .variants
            .into_iter()
            .find(|variant| variant.language == "zh")
            .unwrap();
        assert_eq!(
            zh_after.text.as_deref(),
            Some("你好"),
            "the durable final translation stays authoritative"
        );
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
            source_projection_revision: 1,
            source_edit_revision: 0,
            variants: vec![
                RealtimeUtteranceVariant {
                    language: "zh".into(),
                    role: UtteranceVariantRole::Translation,
                    text: Some("早上好".into()),
                    state: UtteranceVariantState::Ready,
                    completion: Some(UtteranceCompletion::Complete),
                    revision: 0,
                    created_at: String::new(),
                    updated_at: String::new(),
                    projection_revision: 2,
                    edit_revision: 0,
                },
                RealtimeUtteranceVariant {
                    language: "en".into(),
                    role: UtteranceVariantRole::Source,
                    text: Some("good morning 🌏".into()),
                    state: UtteranceVariantState::Ready,
                    completion: Some(UtteranceCompletion::Complete),
                    revision: 0,
                    created_at: String::new(),
                    updated_at: String::new(),
                    projection_revision: 1,
                    edit_revision: 0,
                },
            ],
        }
    }

    fn projected_translation_variant(
        language: &str,
        text: &str,
        projection_revision: u64,
    ) -> RealtimeUtteranceVariant {
        RealtimeUtteranceVariant {
            language: language.into(),
            role: UtteranceVariantRole::Translation,
            text: Some(text.into()),
            state: UtteranceVariantState::Ready,
            completion: Some(UtteranceCompletion::Complete),
            revision: 0,
            created_at: String::new(),
            updated_at: String::new(),
            projection_revision,
            edit_revision: 0,
        }
    }

    fn projected_source_variant(
        language: &str,
        text: &str,
        projection_revision: u64,
    ) -> RealtimeUtteranceVariant {
        RealtimeUtteranceVariant {
            language: language.into(),
            role: UtteranceVariantRole::Source,
            text: Some(text.into()),
            state: UtteranceVariantState::Ready,
            completion: Some(UtteranceCompletion::Complete),
            revision: 0,
            created_at: String::new(),
            updated_at: String::new(),
            projection_revision,
            edit_revision: 0,
        }
    }

    fn two_multilingual_final_utterances() -> Vec<RealtimeUtterance> {
        let mut first = projected_utterance();
        first.id = "utterance-0".into();
        first.sequence = 0;
        first.source_text = "source zero".into();
        first.source_start_ms = None;
        first.source_end_ms = None;
        first.source_projection_revision = 1;
        first.translated_language = Some("zh".into());
        first.translated_text = Some("零".into());
        first.variants = vec![
            projected_translation_variant("ZH-Hans", "零", 3),
            projected_translation_variant("th-TH", "ศูนย์", 5),
            projected_source_variant("en", "source zero", 1),
        ];

        let mut second = projected_utterance();
        second.id = "utterance-1".into();
        second.sequence = 1;
        second.source_text = "source one".into();
        second.source_start_ms = None;
        second.source_end_ms = None;
        second.source_projection_revision = 2;
        second.translated_language = Some("zh".into());
        second.translated_text = Some("一".into());
        second.variants = vec![
            projected_translation_variant("zh", "一", 4),
            projected_translation_variant("TH", "หนึ่ง", 6),
            projected_source_variant("en", "source one", 2),
        ];
        vec![first, second]
    }

    #[test]
    fn finalized_search_content_matches_projectable_lanes_and_visible_overrides() {
        let mut utterance = projected_utterance();
        utterance.source_language = "EN-us".into();
        utterance.completion = UtteranceCompletion::Partial;
        utterance.source_text = "speculative source".into();
        utterance.translated_text = Some("legacy speculative shadow".into());
        let source = utterance
            .variants
            .iter_mut()
            .find(|variant| variant.role == UtteranceVariantRole::Source)
            .unwrap();
        source.text = Some("speculative source".into());
        source.completion = Some(UtteranceCompletion::Partial);
        source.projection_revision = 0;
        utterance.variants[0].language = "ZH-Hans".into();
        utterance.variants[0].text = Some("speculative variant".into());
        utterance.variants[0].completion = Some(UtteranceCompletion::Partial);
        assert_eq!(finalized_capture_search_content(&[utterance.clone()]), "");

        utterance.variants[0].completion = Some(UtteranceCompletion::Complete);
        utterance.variants[0].text = Some("visible translated override".into());
        assert_eq!(
            finalized_capture_search_content(&[utterance.clone()]),
            "[zh] visible translated override"
        );

        utterance.completion = UtteranceCompletion::Complete;
        utterance.source_text = "visible source override".into();
        let source = utterance
            .variants
            .iter_mut()
            .find(|variant| variant.role == UtteranceVariantRole::Source)
            .unwrap();
        source.text = Some("visible source override".into());
        source.completion = Some(UtteranceCompletion::Complete);
        source.projection_revision = 1;
        assert_eq!(
            finalized_capture_search_content(&[utterance.clone()]),
            "[en] visible source override [zh] visible translated override"
        );
        assert_eq!(
            finalized_capture_search_content_through(&[utterance], 1),
            "[en] visible source override",
            "an R snapshot must not index the concurrently committed R+1 lane"
        );
    }

    #[test]
    fn ffi_utterance_preserves_session_speaker_id() {
        let mut utterance = projected_utterance();
        utterance.session_speaker_id = Some("speaker-a".into());

        let ffi: FfiNotebookCaptureUtterance = utterance.into();

        assert_eq!(ffi.session_speaker_id.as_deref(), Some("speaker-a"));
        assert_eq!(ffi.source_projection_revision, 1);
        assert_eq!(ffi.source_edit_revision, 0);
        assert_eq!(ffi.language_variants[0].projection_revision, 2);
        assert_eq!(ffi.language_variants[0].edit_revision, 0);
    }

    #[test]
    fn applied_lane_edit_does_not_wait_for_or_project_a_newer_pending_lane() {
        let temp = tempfile::tempdir().unwrap();
        let core = ZulangueCore::new_for_test(temp.path().to_string_lossy().to_string()).unwrap();
        let notebook = core
            .create_notebook(Some("Lane-local editability".into()))
            .unwrap();
        let profile = core
            .get_notebook_capture_profile(notebook.id.clone())
            .unwrap();
        let started = core
            .start_notebook_capture_session(
                notebook.id.clone(),
                profile.revision,
                None,
                Box::new(CaptureEventSender(std::sync::mpsc::channel().0)),
            )
            .unwrap();
        claim_current_realtime_provider(&core.notebook_capture_store, &started.session_id);
        let source = core
            .notebook_capture_store
            .upsert_utterance(
                &NewRealtimeUtterance {
                    id: "lane-local-utterance".into(),
                    session_id: started.session_id.clone(),
                    sequence: 0,
                    session_speaker_id: None,
                    source_language: "en".into(),
                    source_text: "applied source".into(),
                    source_start_ms: None,
                    source_end_ms: None,
                    translated_language: None,
                    translated_text: None,
                    completion: UtteranceCompletion::Complete,
                    alignment: UtteranceAlignment::SourceOnly,
                },
                None,
            )
            .unwrap();
        core.project_notebook_realtime_incremental(started.session_id.clone())
            .unwrap();
        core.notebook_capture_store
            .upsert_translation_variant(
                &started.session_id,
                0,
                "zh",
                Some("newer pending lane"),
                UtteranceVariantState::Ready,
                Some(UtteranceCompletion::Complete),
            )
            .unwrap();
        let before = core
            .notebook_capture_store
            .get_run_for_session(&started.session_id)
            .unwrap()
            .unwrap();
        assert_eq!(
            (
                before.realtime_loro_applied_revision,
                before.realtime_loro_desired_revision
            ),
            (
                source.source_projection_revision,
                source.source_projection_revision + 1
            )
        );
        let db = rusqlite::Connection::open(temp.path().join("zulangue.db")).unwrap();
        db.execute_batch(
            "CREATE TRIGGER fail_unrelated_projection_ack
             BEFORE UPDATE OF realtime_loro_applied_revision ON notebook_capture_runs
             WHEN NEW.realtime_loro_applied_revision > OLD.realtime_loro_applied_revision
             BEGIN
                 SELECT RAISE(FAIL, 'unrelated pending lane must not be projected by edit');
             END;",
        )
        .unwrap();

        let edited = core
            .replace_notebook_utterance_lane(
                "lane-local-utterance".into(),
                "en".into(),
                "user edits already applied lane".into(),
                source.source_edit_revision,
            )
            .expect("lane A edit must not depend on pending lane B projection");
        assert_eq!(edited.source_text, "user edits already applied lane");
        let after = core
            .notebook_capture_store
            .get_run_for_session(&started.session_id)
            .unwrap()
            .unwrap();
        assert_eq!(
            after.realtime_loro_applied_revision,
            before.realtime_loro_applied_revision
        );
        assert_eq!(
            after.realtime_loro_desired_revision,
            before.realtime_loro_desired_revision
        );
        assert!(core
            .search_sessions("newer pending lane".into(), 10)
            .unwrap()
            .is_empty());

        db.execute_batch("DROP TRIGGER fail_unrelated_projection_ack;")
            .unwrap();
        core.interrupt_notebook_capture_session(
            started.session_id,
            FfiNotebookCaptureInterruptReason::LocalAudioUnavailable,
        )
        .unwrap();
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
                upsert_test_lanes(
                    &core.notebook_capture_store,
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
        // Corrupt an unrelated row's edit overlay. A callback implementation
        // that scans all 128 rows will fail before enqueueing sequence 127;
        // the O(delta) snapshot never touches sequence 0.
        let db = rusqlite::Connection::open(temp.path().join("zulangue.db")).unwrap();
        db.pragma_update(None, "ignore_check_constraints", true)
            .unwrap();
        db.execute(
            "INSERT INTO realtime_utterance_overrides
             (utterance_id, lane, lane_language, text,
              machine_utterance_revision, machine_variant_revision,
              edit_revision, created_at, updated_at)
             VALUES (?1, 'invalid_lane', 'en', 'corrupt unrelated row',
                     0, 0, 1, ?2, ?2)",
            rusqlite::params!["utterance-0", chrono::Utc::now().to_rfc3339()],
        )
        .unwrap();

        let (callback_tx, callback_rx) = std::sync::mpsc::channel();
        let callback = CaptureCallbackSink::new(
            Arc::new(CaptureEventSender(callback_tx)),
            (*core.notebook_capture_store).clone(),
            None,
        )
        .unwrap();

        let first_preview = callback.send_preview(FfiNotebookCaptureLivePreview {
            session_id: run.session_id.clone(),
            preview_revision: 0,
            utterances: Vec::new(),
            translation_cues: Vec::new(),
            lane_health: Vec::new(),
        });
        let second_preview = callback.send_preview(FfiNotebookCaptureLivePreview {
            session_id: run.session_id.clone(),
            preview_revision: 0,
            utterances: Vec::new(),
            translation_cues: Vec::new(),
            lane_health: Vec::new(),
        });
        let first = callback.send(event_from_run(
            run.clone(),
            vec![changed.expect("the final changed utterance")],
            false,
        ));
        let delivered = callback_rx
            .recv_timeout(std::time::Duration::from_secs(1))
            .expect("the changed row must enqueue without scanning corrupt unrelated history");
        assert_eq!(delivered.utterances.len(), 1);
        assert_eq!(delivered.utterances[0].sequence, 127);
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
        db.execute(
            "DELETE FROM realtime_utterance_overrides
             WHERE utterance_id = 'utterance-0' AND lane = 'invalid_lane'",
            [],
        )
        .unwrap();
        let full = event_full_snapshot_from_run(&core.notebook_capture_store, run).unwrap();
        assert!(full.is_full_snapshot);
        assert_eq!(full.utterances.len(), 128);
    }

    #[test]
    fn callback_publication_refreshes_stale_recording_state_after_pause_commit() {
        let temp = tempfile::tempdir().unwrap();
        let core = ZulangueCore::new_for_test(temp.path().to_string_lossy().to_string()).unwrap();
        let notebook = core.create_notebook(Some("Callback order".into())).unwrap();
        let profile = core
            .notebook_capture_store
            .get_or_create_profile(&notebook.id)
            .unwrap();
        let recording = core
            .notebook_capture_store
            .create_run(
                &vt_store::NewNotebookCaptureRun {
                    id: "callback-order-run".into(),
                    notebook_id: notebook.id,
                    session_id: "callback-order-session".into(),
                    remote_health: RemoteHealth::Off,
                    audio_journal_path: "callback-order.journal".into(),
                    audio_key_ref: "callback-order-key".into(),
                    sample_rate: 16_000,
                    channels: 1,
                },
                &profile,
            )
            .unwrap();
        let paused = core
            .notebook_capture_store
            .transition_capture(&recording.id, CaptureState::Recording, CaptureState::Paused)
            .unwrap();
        let (callback_tx, callback_rx) = std::sync::mpsc::channel();
        let callback = CaptureCallbackSink::new(
            Arc::new(CaptureEventSender(callback_tx)),
            (*core.notebook_capture_store).clone(),
            None,
        )
        .unwrap();

        // Models a delta that captured Recording before the pause transaction
        // committed, but reached the publication boundary afterwards.
        let published = callback.send(event_from_run(recording, Vec::new(), false));

        assert_eq!(published.capture_state, FfiNotebookCaptureState::Paused);
        assert_eq!(
            callback_rx
                .recv_timeout(std::time::Duration::from_secs(1))
                .unwrap()
                .capture_state,
            FfiNotebookCaptureState::Paused
        );
        assert_eq!(paused.capture_state, CaptureState::Paused);
    }

    #[test]
    fn remote_truth_overlay_survives_full_reconcile_and_projection_ack_fallback() {
        let temp = tempfile::tempdir().unwrap();
        let core = ZulangueCore::new_for_test(temp.path().to_string_lossy().to_string()).unwrap();
        let notebook = core
            .create_notebook(Some("Remote truth overlay".into()))
            .unwrap();
        let profile = core
            .notebook_capture_store
            .get_or_create_profile(&notebook.id)
            .unwrap();
        let run = core
            .notebook_capture_store
            .create_run(
                &vt_store::NewNotebookCaptureRun {
                    id: "remote-overlay-run".into(),
                    notebook_id: notebook.id,
                    session_id: "remote-overlay-session".into(),
                    remote_health: RemoteHealth::Off,
                    audio_journal_path: "remote-overlay.journal".into(),
                    audio_key_ref: "remote-overlay-key".into(),
                    sample_rate: 16_000,
                    channels: 1,
                },
                &profile,
            )
            .unwrap();
        let (callback_tx, callback_rx) = std::sync::mpsc::channel();
        let callback = CaptureCallbackSink::new(
            Arc::new(CaptureEventSender(callback_tx)),
            (*core.notebook_capture_store).clone(),
            None,
        )
        .unwrap();
        callback.set_remote_truth_overlay(
            &run.session_id,
            RemoteHealth::Degraded,
            ProviderFailure {
                error_type: "control_unavailable".into(),
                request_id: None,
            },
        );

        let reconciled = callback
            .full_snapshot_with_remote_truth(&run.session_id)
            .unwrap();
        assert_eq!(reconciled.remote_health, FfiNotebookRemoteHealth::Degraded);
        assert_eq!(
            reconciled.provider_error_type.as_deref(),
            Some("control_unavailable")
        );

        callback
            .commit_projection_ack(&run.session_id, || {
                Ok(RealtimeLoroProjectionAck {
                    session_id: run.session_id.clone(),
                    desired_revision: 1,
                    applied_revision: 1,
                    advanced: true,
                })
            })
            .unwrap();
        let delivered = callback_rx
            .recv_timeout(std::time::Duration::from_secs(1))
            .unwrap();
        assert_eq!(delivered.remote_health, FfiNotebookRemoteHealth::Degraded);
        assert_eq!(
            delivered.provider_error_type.as_deref(),
            Some("control_unavailable")
        );
    }

    #[test]
    fn pause_event_orders_after_a_send_that_read_recording_before_the_commit() {
        let temp = tempfile::tempdir().unwrap();
        let core = ZulangueCore::new_for_test(temp.path().to_string_lossy().to_string()).unwrap();
        let notebook = core
            .create_notebook(Some("Linearized pause".into()))
            .unwrap();
        let profile = core
            .notebook_capture_store
            .get_or_create_profile(&notebook.id)
            .unwrap();
        let recording = core
            .notebook_capture_store
            .create_run(
                &vt_store::NewNotebookCaptureRun {
                    id: "linearized-pause-run".into(),
                    notebook_id: notebook.id,
                    session_id: "linearized-pause-session".into(),
                    remote_health: RemoteHealth::Off,
                    audio_journal_path: "linearized-pause.journal".into(),
                    audio_key_ref: "linearized-pause-key".into(),
                    sample_rate: 16_000,
                    channels: 1,
                },
                &profile,
            )
            .unwrap();
        let (callback_tx, _callback_rx) = std::sync::mpsc::channel();
        let callback = CaptureCallbackSink::new(
            Arc::new(CaptureEventSender(callback_tx)),
            (*core.notebook_capture_store).clone(),
            None,
        )
        .unwrap();
        let (read_tx, read_rx) = std::sync::mpsc::channel();
        let (release_tx, release_rx) = std::sync::mpsc::channel();
        let stale_callback = callback.clone();
        let stale_recording = recording.clone();
        let stale = std::thread::spawn(move || {
            stale_callback.send_with_refresh_hook(
                event_from_run(stale_recording, Vec::new(), false),
                || {
                    read_tx.send(()).unwrap();
                    release_rx.recv().unwrap();
                },
            )
        });
        read_rx.recv().unwrap();

        // The stale sender has read Recording and still owns the mailbox.
        // Pause may durably commit now, but its mandatory send must wait and
        // therefore receives the next event revision.
        let paused = core
            .notebook_capture_store
            .transition_capture(&recording.id, CaptureState::Recording, CaptureState::Paused)
            .unwrap();
        let pause_callback = callback.clone();
        let pause = std::thread::spawn(move || {
            pause_callback.send(event_from_run(paused, Vec::new(), false))
        });
        release_tx.send(()).unwrap();

        let stale = stale.join().unwrap();
        let pause = pause.join().unwrap();
        assert_eq!(stale.capture_state, FfiNotebookCaptureState::Recording);
        assert_eq!(pause.capture_state, FfiNotebookCaptureState::Paused);
        assert!(pause.event_revision > stale.event_revision);
    }

    #[test]
    fn pause_direct_result_keeps_monotonic_revision_when_refresh_cannot_enqueue() {
        let temp = tempfile::tempdir().unwrap();
        let core = ZulangueCore::new_for_test(temp.path().to_string_lossy().to_string()).unwrap();
        let notebook = core
            .create_notebook(Some("Direct pause revision".into()))
            .unwrap();
        let profile = core
            .notebook_capture_store
            .get_or_create_profile(&notebook.id)
            .unwrap();
        let recording = core
            .notebook_capture_store
            .create_run(
                &vt_store::NewNotebookCaptureRun {
                    id: "direct-pause-run".into(),
                    notebook_id: notebook.id,
                    session_id: "direct-pause-session".into(),
                    remote_health: RemoteHealth::Off,
                    audio_journal_path: "direct-pause.journal".into(),
                    audio_key_ref: "direct-pause-key".into(),
                    sample_rate: 16_000,
                    channels: 1,
                },
                &profile,
            )
            .unwrap();
        let paused = core
            .notebook_capture_store
            .transition_capture(&recording.id, CaptureState::Recording, CaptureState::Paused)
            .unwrap();
        let (callback_tx, callback_rx) = std::sync::mpsc::channel();
        let callback = CaptureCallbackSink::new(
            Arc::new(CaptureEventSender(callback_tx)),
            (*core.notebook_capture_store).clone(),
            None,
        )
        .unwrap();
        rusqlite::Connection::open(temp.path().join("zulangue.db"))
            .unwrap()
            .execute(
                "DELETE FROM notebook_capture_runs WHERE id = 'direct-pause-run'",
                [],
            )
            .unwrap();

        let direct = callback.send(event_from_run(paused, Vec::new(), false));

        assert_eq!(direct.capture_state, FfiNotebookCaptureState::Paused);
        assert_eq!(direct.event_revision, 1);
        assert!(callback_rx
            .recv_timeout(std::time::Duration::from_millis(50))
            .is_err());
    }

    #[test]
    fn projection_ack_after_queued_pause_only_raises_its_watermark() {
        let temp = tempfile::tempdir().unwrap();
        let core = ZulangueCore::new_for_test(temp.path().to_string_lossy().to_string()).unwrap();
        let notebook = core.create_notebook(Some("ACK order".into())).unwrap();
        let profile = core
            .notebook_capture_store
            .get_or_create_profile(&notebook.id)
            .unwrap();
        let recording = core
            .notebook_capture_store
            .create_run(
                &vt_store::NewNotebookCaptureRun {
                    id: "ack-order-run".into(),
                    notebook_id: notebook.id,
                    session_id: "ack-order-session".into(),
                    remote_health: RemoteHealth::Off,
                    audio_journal_path: "ack-order.journal".into(),
                    audio_key_ref: "ack-order-key".into(),
                    sample_rate: 16_000,
                    channels: 1,
                },
                &profile,
            )
            .unwrap();
        let mut paused = core
            .notebook_capture_store
            .transition_capture(&recording.id, CaptureState::Recording, CaptureState::Paused)
            .unwrap();
        paused.remote_health = RemoteHealth::Degraded;
        let (callback_tx, callback_rx) = std::sync::mpsc::channel();
        let callback = CaptureCallbackSink::new(
            Arc::new(CaptureEventSender(callback_tx)),
            (*core.notebook_capture_store).clone(),
            None,
        )
        .unwrap();
        {
            // Install the already-queued pause without waking the worker until
            // the ACK merge completes, making the critical ordering exact.
            let mut pending = callback.mailbox.pending.lock().unwrap();
            let mut event = event_from_run(paused, Vec::new(), false);
            event.event_revision = 41;
            pending.event = Some(event);
        }

        let receipt = callback
            .commit_projection_ack("ack-order-session", || {
                Ok(RealtimeLoroProjectionAck {
                    session_id: "ack-order-session".into(),
                    desired_revision: 7,
                    applied_revision: 7,
                    advanced: true,
                })
            })
            .unwrap();
        assert!(receipt.advanced);
        let delivered = callback_rx
            .recv_timeout(std::time::Duration::from_secs(1))
            .unwrap();
        assert_eq!(delivered.event_revision, 41);
        assert_eq!(delivered.capture_state, FfiNotebookCaptureState::Paused);
        assert_eq!(delivered.remote_health, FfiNotebookRemoteHealth::Degraded);
        assert_eq!(delivered.realtime_loro_applied_revision, 7);
    }

    #[test]
    fn callback_delta_refresh_preserves_a_concurrent_user_lane_override() {
        let (_temp, core, _notebook_id, run_id, _doc_id) = projected_core_fixture();
        core.project_notebook_capture(&run_id).unwrap();
        let stale_run = core
            .notebook_capture_store
            .get_run(&run_id)
            .unwrap()
            .unwrap();
        let stale_utterance = core
            .notebook_capture_store
            .list_utterances("session-a")
            .unwrap()
            .remove(0);
        let expected_revision = stale_utterance
            .variants
            .iter()
            .find(|variant| variant.language == "zh")
            .map(|variant| variant.edit_revision)
            .unwrap_or(0);
        core.replace_notebook_utterance_lane(
            "utterance-a".into(),
            "zh".into(),
            "用户 A 在 B delta 发布前已提交".into(),
            expected_revision,
        )
        .unwrap();

        let (callback_tx, callback_rx) = std::sync::mpsc::channel();
        let callback = CaptureCallbackSink::new(
            Arc::new(CaptureEventSender(callback_tx)),
            (*core.notebook_capture_store).clone(),
            None,
        )
        .unwrap();
        let published = callback.send(event_from_run(stale_run, vec![stale_utterance], false));
        assert_eq!(
            published.utterances[0].translated_text.as_deref(),
            Some("用户 A 在 B delta 发布前已提交")
        );
        let delivered = callback_rx
            .recv_timeout(std::time::Duration::from_secs(1))
            .unwrap();
        assert_eq!(
            delivered.utterances[0].translated_text.as_deref(),
            Some("用户 A 在 B delta 发布前已提交")
        );
    }

    fn projected_core_fixture_with_projection(
        attach_projection: bool,
    ) -> (tempfile::TempDir, ZulangueCore, String, String, String) {
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
        if attach_projection {
            core.notebook_store
                .attach_session_with_builtin_projections(&notebook.id, &run.session_id)
                .unwrap();
        }
        claim_current_realtime_provider(&core.notebook_capture_store, &run.session_id);
        upsert_test_lanes(
            &core.notebook_capture_store,
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

    fn projected_core_fixture() -> (tempfile::TempDir, ZulangueCore, String, String, String) {
        projected_core_fixture_with_projection(true)
    }

    #[test]
    fn up_to_date_incremental_projection_skips_machine_fact_hydration() {
        let (temp, core, _notebook_id, _run_id, _doc_id) = projected_core_fixture();
        core.project_notebook_realtime_incremental("session-a".into())
            .unwrap();
        let projected = core
            .notebook_capture_store
            .load_realtime_loro_projection("session-a")
            .unwrap();
        assert_eq!(projected.applied_revision, projected.desired_revision);

        let conn = rusqlite::Connection::open(temp.path().join("zulangue.db")).unwrap();
        conn.pragma_update(None, "ignore_check_constraints", "ON")
            .unwrap();
        conn.execute(
            "UPDATE realtime_utterances
             SET completion = 'invalid-test-value'
             WHERE id = 'utterance-a'",
            [],
        )
        .unwrap();
        conn.pragma_update(None, "ignore_check_constraints", "OFF")
            .unwrap();
        assert!(core
            .notebook_capture_store
            .load_realtime_loro_projection("session-a")
            .is_err());

        core.project_notebook_realtime_incremental("session-a".into())
            .expect("an up-to-date wake must not hydrate the full machine-fact ledger");
    }

    #[test]
    fn terminal_projection_keeps_search_and_ready_semantics_after_incremental_ack() {
        let (_temp, core, _notebook_id, run_id, _doc_id) = projected_core_fixture();
        core.project_notebook_realtime_incremental("session-a".into())
            .unwrap();
        core.search_store
            .index_session("session-a", "stale disposable index")
            .unwrap();
        assert!(core.search_sessions("hello".into(), 10).unwrap().is_empty());

        core.project_notebook_capture(&run_id).unwrap();

        let run = core
            .notebook_capture_store
            .get_run(&run_id)
            .unwrap()
            .unwrap();
        assert_eq!(run.projection_state, ProjectionState::Ready);
        assert!(core
            .search_sessions("hello".into(), 10)
            .unwrap()
            .iter()
            .any(|result| result.session_id == "session-a"));
    }

    #[test]
    fn local_persistence_failure_projects_committed_final_facts_and_lands_ready() {
        let (temp, core, _notebook_id, run_id, doc_id) = projected_core_fixture();
        let before = core
            .notebook_capture_store
            .load_realtime_loro_projection("session-a")
            .unwrap();
        assert!(before.desired_revision > 0);
        assert_eq!(before.applied_revision, 0);
        rusqlite::Connection::open(temp.path().join("zulangue.db"))
            .unwrap()
            .execute(
                "UPDATE notebook_capture_runs
                 SET provider_error_type = 'local_persistence'
                 WHERE id = ?1",
                [&run_id],
            )
            .unwrap();

        core.project_notebook_capture(&run_id)
            .expect("an interrupted run still projects its committed Final facts");
        let projected = core
            .notebook_capture_store
            .get_run(&run_id)
            .unwrap()
            .unwrap();
        assert_eq!(projected.projection_state, ProjectionState::Ready);
        assert_eq!(
            projected.provider_error_type.as_deref(),
            Some("local_persistence"),
            "the run keeps its quality signal for the missing suffix"
        );
        let after = core
            .notebook_capture_store
            .load_realtime_loro_projection("session-a")
            .unwrap();
        assert_eq!(after.applied_revision, after.desired_revision);
        assert_eq!(after.desired_revision, before.desired_revision);
        let blocks = core
            .with_transcript(&doc_id, |projection| Ok(projection.refresh()))
            .unwrap();
        assert!(blocks
            .iter()
            .any(|block| block.lanes.get("zh").is_some_and(|lane| lane == "你好")));

        let machine = core
            .notebook_capture_store
            .get_machine_utterance_by_id("utterance-a")
            .unwrap()
            .unwrap();
        let zh = machine
            .variants
            .iter()
            .find(|variant| variant.language == "zh")
            .unwrap();
        assert!(zh.projection_revision <= after.applied_revision);
        core.replace_notebook_utterance_lane(
            machine.id,
            "zh".into(),
            "失败前已提交的 Final 仍可编辑".into(),
            zh.edit_revision,
        )
        .unwrap();
        let edited = core
            .notebook_capture_store
            .get_utterance_by_id("utterance-a")
            .unwrap()
            .unwrap();
        let zh = edited
            .variants
            .iter()
            .find(|variant| variant.language == "zh")
            .unwrap();
        assert_eq!(zh.text.as_deref(), Some("失败前已提交的 Final 仍可编辑"));
        assert_eq!(zh.edit_revision, 1);
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
            let journal_path =
                std::path::Path::new(interrupted.audio_journal_path.as_deref().unwrap());
            match fault {
                StopDurabilityFault::SessionRecord => {
                    assert!(
                        !journal_path.exists(),
                        "interrupted session recovery removes the journal only after every audio index commits"
                    );
                    let audio_path = interrupted
                        .audio_path
                        .as_deref()
                        .expect("neutral recovery persists the finalized encrypted audio path");
                    assert!(std::path::Path::new(audio_path).exists());
                    let audio_meta = core.session_meta.get_meta(&started.session_id).unwrap();
                    assert_eq!(audio_meta.encrypted_path.as_deref(), Some(audio_path));
                    assert_eq!(audio_meta.sample_rate, interrupted.sample_rate);
                    assert_eq!(audio_meta.channels, interrupted.channels);
                    assert!(!core
                        .session_meta
                        .list_audio_retention_chunks(&started.session_id)
                        .unwrap()
                        .is_empty());
                    assert_eq!(
                        core.session_store
                            .get_session(&started.session_id)
                            .unwrap()
                            .status,
                        "interrupted"
                    );
                    assert!(!core
                        .detached_notebook_capture_runs
                        .lock()
                        .unwrap()
                        .contains(&interrupted.id));
                }
                StopDurabilityFault::FinalizeRun
                | StopDurabilityFault::SessionMeta
                | StopDurabilityFault::RetentionChunk => {
                    assert!(journal_path.exists());
                    assert_journal_contains_recoverable_audio(&core, temp.path(), &interrupted);
                    assert!(core
                        .detached_notebook_capture_runs
                        .lock()
                        .unwrap()
                        .contains(&interrupted.id));
                }
            }

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
        let chunk_path = vt_pipeline::session_audio_chunk_path(temp.path(), &started.session_id, 0);
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
    fn ownerless_draining_stop_failure_recovers_without_restart_or_fabricated_reason() {
        let temp = tempfile::tempdir().unwrap();
        let core = ZulangueCore::new_for_test(temp.path().to_string_lossy().to_string()).unwrap();
        let notebook = core
            .create_notebook(Some("Ownerless stop recovery".into()))
            .unwrap();
        let (profile, started) = start_async_local_capture(&core, &notebook.id);
        core.push_notebook_capture_session(started.session_id.clone(), vec![0_u8; 3_200])
            .unwrap();
        let active_run = core
            .notebook_capture_store
            .get_run_for_session(&started.session_id)
            .unwrap()
            .unwrap();
        let journal_path = std::path::PathBuf::from(
            active_run
                .audio_journal_path
                .as_deref()
                .expect("active capture has a recovery journal"),
        );
        let chunk_path = vt_pipeline::session_audio_chunk_path(temp.path(), &started.session_id, 0);
        std::fs::create_dir(&chunk_path).unwrap();

        let db = rusqlite::Connection::open(temp.path().join("zulangue.db")).unwrap();
        db.execute_batch(
            "CREATE TRIGGER fail_stop_interruption_state
             BEFORE UPDATE OF capture_state ON notebook_capture_runs
             WHEN NEW.capture_state = 'interrupted'
             BEGIN
                 SELECT RAISE(FAIL, 'injected stop interruption persistence failure');
             END;",
        )
        .unwrap();

        let error = core
            .stop_notebook_capture_session(started.session_id.clone())
            .unwrap_err();
        assert!(error
            .to_string()
            .contains("finalize encrypted capture audio"));
        assert!(error
            .to_string()
            .contains("injected stop interruption persistence failure"));
        assert!(
            core.active_notebook_capture.lock().unwrap().is_none(),
            "Stop returned after releasing the process-local owner"
        );
        let draining = core
            .notebook_capture_store
            .get_run(&active_run.id)
            .unwrap()
            .unwrap();
        assert_eq!(draining.capture_state, CaptureState::Draining);
        assert!(journal_path.exists());
        assert!(core
            .detached_notebook_capture_runs
            .lock()
            .unwrap()
            .contains(&active_run.id));

        // Durable `draining` without this process's atomic handoff marker is
        // not sufficient authority to recover a run owned by another Core.
        core.detached_notebook_capture_runs
            .lock()
            .unwrap()
            .remove(&active_run.id);
        let unowned_error = core
            .interrupt_notebook_capture_session(
                started.session_id.clone(),
                FfiNotebookCaptureInterruptReason::LocalAudioUnavailable,
            )
            .unwrap_err();
        assert!(unowned_error.to_string().contains("capture_not_active"));
        assert_eq!(
            core.notebook_capture_store
                .get_run(&active_run.id)
                .unwrap()
                .unwrap()
                .capture_state,
            CaptureState::Draining
        );
        core.detached_notebook_capture_runs
            .lock()
            .unwrap()
            .insert(active_run.id.clone());

        db.execute_batch("DROP TRIGGER fail_stop_interruption_state;")
            .unwrap();
        std::fs::remove_dir(&chunk_path).unwrap();
        let recovered_event = core
            .interrupt_notebook_capture_session(
                started.session_id.clone(),
                FfiNotebookCaptureInterruptReason::LocalAudioUnavailable,
            )
            .unwrap();
        assert_eq!(
            recovered_event.capture_state,
            FfiNotebookCaptureState::Interrupted
        );
        assert_ne!(
            recovered_event.provider_error_type.as_deref(),
            Some("local_audio_unavailable"),
            "ownerless Stop recovery must not persist the fallback caller's reason"
        );

        let recovered = core
            .notebook_capture_store
            .get_run(&active_run.id)
            .unwrap()
            .unwrap();
        assert_eq!(recovered.capture_state, CaptureState::Interrupted);
        assert_eq!(recovered.remote_health, RemoteHealth::Off);
        assert_eq!(recovered.async_task_state, AsyncTaskState::None);
        assert!(recovered
            .audio_path
            .as_deref()
            .is_some_and(|path| std::path::Path::new(path).exists()));
        assert!(!journal_path.exists());
        assert!(core
            .detached_notebook_capture_runs
            .lock()
            .unwrap()
            .is_empty());
        assert_eq!(
            core.session_store
                .get_session(&started.session_id)
                .unwrap()
                .status,
            "interrupted"
        );
        assert!(!core
            .session_meta
            .list_audio_retention_chunks(&started.session_id)
            .unwrap()
            .is_empty());

        let next = core
            .start_notebook_capture_session(
                notebook.id,
                profile.revision,
                None,
                Box::new(CaptureEventSender(std::sync::mpsc::channel().0)),
            )
            .expect("ownerless recovery must release the global capture slot");
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
        assert!(core
            .detached_notebook_capture_runs
            .lock()
            .unwrap()
            .is_empty());
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
    fn realtime_projection_requires_preexisting_notebook_resource_and_never_repairs_it() {
        let (_temp, core, notebook_id, run_id, _doc_id) =
            projected_core_fixture_with_projection(false);
        let realtime_tab = core
            .notebook_store
            .list_tabs(&notebook_id)
            .unwrap()
            .into_iter()
            .find(|tab| tab.builtin_kind == vt_store::BuiltinNotebookTab::RealtimeTranscript)
            .unwrap();
        assert!(core
            .notebook_store
            .list_session_projections(&realtime_tab.id)
            .unwrap()
            .is_empty());

        let error = core.project_notebook_capture(&run_id).unwrap_err();
        assert!(error.to_string().contains("Realtime Transcript projection"));
        assert!(core
            .notebook_store
            .list_session_projections(&realtime_tab.id)
            .unwrap()
            .is_empty());
    }

    #[test]
    fn ffi_events_history_and_lanes_expose_durable_projection_watermarks() {
        let (_temp, core, notebook_id, run_id, _doc_id) = projected_core_fixture();
        core.project_notebook_capture(&run_id).unwrap();
        let run = core
            .notebook_capture_store
            .get_run(&run_id)
            .unwrap()
            .unwrap();
        assert!(run.realtime_loro_applied_revision > 0);

        let event = core.capture_event_for_run(&run_id).unwrap();
        assert_eq!(
            event.realtime_loro_applied_revision,
            run.realtime_loro_applied_revision
        );
        assert!(event.utterances[0].source_projection_revision > 0);
        assert!(event.utterances[0]
            .language_variants
            .iter()
            .all(|variant| variant.projection_revision > 0));

        core.session_store
            .insert_session(&vt_store::SessionRecord {
                id: "session-a".into(),
                title: "Projection mapping".into(),
                session_type: "recording".into(),
                status: "completed".into(),
                duration_ms: 0,
                created_at: "2001-01-01 00:00:00".into(),
                deleted_at: None,
            })
            .unwrap();
        let history = core.list_notebook_capture_history(notebook_id).unwrap();
        assert_eq!(
            history[0].realtime_loro_applied_revision,
            run.realtime_loro_applied_revision
        );
    }

    #[test]
    fn failed_fts_after_loro_fsync_does_not_block_ack_or_lane_editability() {
        let (temp, core, _notebook_id, run_id, _doc_id) = projected_core_fixture();
        rusqlite::Connection::open(temp.path().join("zulangue.db"))
            .unwrap()
            .execute_batch("DROP TABLE search_index;")
            .unwrap();

        core.project_notebook_capture(&run_id)
            .expect("disposable FTS failure must not fail durable projection");
        let projected = core
            .notebook_capture_store
            .get_run(&run_id)
            .unwrap()
            .unwrap();
        assert!(projected.realtime_loro_desired_revision > 0);
        assert_eq!(
            projected.realtime_loro_applied_revision,
            projected.realtime_loro_desired_revision
        );
        assert_eq!(projected.projection_state, ProjectionState::Ready);

        let visible = core
            .notebook_capture_store
            .get_utterance_by_id("utterance-a")
            .unwrap()
            .unwrap();
        let expected_edit_revision = visible
            .variants
            .iter()
            .find(|variant| variant.language == "zh")
            .map(|variant| variant.edit_revision)
            .unwrap_or(0);
        let edited = core
            .replace_notebook_utterance_lane(
                "utterance-a".into(),
                "zh".into(),
                "FTS 故障后仍可编辑".into(),
                expected_edit_revision,
            )
            .expect("applied watermark must open the exact projected lane");
        assert_eq!(
            edited.translated_text.as_deref(),
            Some("FTS 故障后仍可编辑")
        );
    }

    #[test]
    fn durable_user_lane_receipt_replays_only_the_sqlite_commit_after_crash() {
        let (temp, core, _notebook_id, run_id, doc_id) = projected_core_fixture();
        core.project_notebook_capture(&run_id).unwrap();
        let visible = core
            .notebook_capture_store
            .get_utterance_by_id("utterance-a")
            .unwrap()
            .unwrap();
        let expected_edit_revision = visible
            .variants
            .iter()
            .find(|variant| variant.language == "zh")
            .map(|variant| variant.edit_revision)
            .unwrap_or(0);
        let mutation = core
            .notebook_capture_store
            .stage_utterance_variant_replacement(
                "utterance-a",
                "zh",
                "用户崩溃重放",
                expected_edit_revision,
            )
            .unwrap();
        let db = rusqlite::Connection::open(temp.path().join("zulangue.db")).unwrap();
        db.execute_batch(
            "CREATE TRIGGER fail_lane_override_commit
             BEFORE INSERT ON realtime_utterance_overrides
             BEGIN
                 SELECT RAISE(FAIL, 'injected override commit failure');
             END;",
        )
        .unwrap();

        {
            let _guard = crate::editor_api::editor_document_mutation_guard();
            core.apply_notebook_projection_mutation_t2(&mutation)
                .expect_err("SQLite failure must leave the durable mutation pending");
        }
        assert!(core
            .notebook_capture_store
            .get_projection_mutation(&mutation.id)
            .unwrap()
            .is_some());
        let lane_text = |core: &ZulangueCore| {
            core.with_transcript(&doc_id, |projection| Ok(projection.refresh()))
                .unwrap()
                .into_iter()
                .find(|block| block.id == "utterance-a")
                .unwrap()
                .lanes["zh"]
                .clone()
        };
        assert_eq!(
            lane_text(&core),
            "用户崩溃重放",
            "文档字节先于 SQLite 提交持久"
        );

        // Drop the live handles without saving so replay must reopen the
        // exact bytes persisted before the injected SQLite failure.
        core.block_documents.lock().unwrap().remove(&doc_id);
        core.editor_bridge.evict(&doc_id);
        db.execute_batch("DROP TRIGGER fail_lane_override_commit;")
            .unwrap();
        let updated = {
            let _guard = crate::editor_api::editor_document_mutation_guard();
            core.apply_notebook_projection_mutation_t2(&mutation)
                .unwrap()
        };
        assert_eq!(updated.translated_text.as_deref(), Some("用户崩溃重放"));
        assert_eq!(
            updated
                .variants
                .iter()
                .find(|variant| variant.language == "zh")
                .map(|variant| variant.edit_revision),
            Some(1)
        );
        assert!(core
            .notebook_capture_store
            .get_projection_mutation(&mutation.id)
            .unwrap()
            .is_none());
        assert_eq!(
            lane_text(&core),
            "用户崩溃重放",
            "idempotent verb replay converges to the same lane bytes"
        );
        let machine_after = core
            .notebook_capture_store
            .get_machine_utterance_by_id("utterance-a")
            .unwrap()
            .unwrap();
        assert_eq!(machine_after.translated_text.as_deref(), Some("你好"));
        assert!(core
            .search_sessions("用户崩溃重放".into(), 10)
            .unwrap()
            .iter()
            .any(|result| result.session_id == "session-a"));

        // Simulate the smaller crash window after the SQLite override commit
        // but before its disposable FTS rebuild. No pending mutation remains;
        // startup must repair from the visible overlay and applied watermark.
        core.search_store
            .index_session("session-a", "[zh] stale machine index")
            .unwrap();
        assert!(core
            .search_sessions("用户崩溃重放".into(), 10)
            .unwrap()
            .is_empty());
        drop(db);
        drop(core);
        let reopened =
            ZulangueCore::new_for_test(temp.path().to_string_lossy().to_string()).unwrap();
        assert!(reopened
            .search_sessions("用户崩溃重放".into(), 10)
            .unwrap()
            .iter()
            .any(|result| result.session_id == "session-a"));
    }

    /// Every recording made before composition existed still holds the
    /// segments that were rejected at the time, so startup recovery is the
    /// backfill: it binds them and the projection grows the lane.
    #[test]
    fn startup_recovery_recovers_a_previously_rejected_segment_into_the_projected_lane() {
        let (temp, core, _notebook_id, run_id, doc_id) = projected_core_fixture();
        core.project_notebook_capture(&run_id).unwrap();
        let projected_lane = |core: &ZulangueCore| {
            core.with_transcript(&doc_id, |projection| Ok(projection.refresh()))
                .unwrap()
                .into_iter()
                .find(|block| block.id == "utterance-a")
                .unwrap()
                .lanes["zh"]
                .clone()
        };
        assert_eq!(projected_lane(&core), "你好");

        // The row's translation as an old build left it: the head segment bound
        // and projected, the tail durably in the inbox but rejected from the
        // lane, and both now beyond the active-session API this recording has
        // long since left behind.
        rusqlite::Connection::open(temp.path().join("zulangue.db"))
            .unwrap()
            .execute(
                "INSERT INTO realtime_translation_inbox
                 (session_id, lane_index, group_epoch, provider_sequence,
                  target_language, source_language, source_text,
                  source_start_ms, source_end_ms, translated_text,
                  completion, state, revision, bound_utterance_id, bound_sequence,
                  created_at, updated_at)
                 VALUES
                 ('session-a', 1, 0, 0, 'zh', 'en', 'hello', 0, 500,
                  '你好', 'complete', 'present', 0, 'utterance-a', 0, '', ''),
                 ('session-a', 1, 0, 1, 'zh', 'en', 'hello', 0, 500,
                  '世界', 'complete', 'present', 0, NULL, NULL, '', '')",
                [],
            )
            .unwrap();

        core.resume_pending_notebook_projection_mutations().unwrap();

        let machine = core
            .notebook_capture_store
            .get_machine_utterance_by_id("utterance-a")
            .unwrap()
            .unwrap();
        let lane = machine
            .variants
            .iter()
            .find(|variant| variant.language == "zh")
            .unwrap();
        assert_eq!(lane.text.as_deref(), Some("你好 世界"));
        assert_eq!(
            projected_lane(&core),
            "你好 世界",
            "recovery grows the projected lane in place (one zh lane per block by construction)"
        );
    }

    #[test]
    fn startup_realtime_fts_repair_preserves_ready_async_search_authority() {
        let (temp, core, _notebook_id, run_id, _doc_id) = projected_core_fixture();
        core.project_notebook_capture(&run_id).unwrap();
        let run = core
            .notebook_capture_store
            .get_run(&run_id)
            .unwrap()
            .unwrap();
        rusqlite::Connection::open(temp.path().join("zulangue.db"))
            .unwrap()
            .execute(
                "UPDATE notebook_capture_runs
                 SET audio_path = ?1, captured_frames = 16000
                 WHERE id = ?2",
                rusqlite::params![
                    temp.path()
                        .join("ready-async-search-retained.enc")
                        .to_string_lossy()
                        .into_owned(),
                    run.id,
                ],
            )
            .unwrap();
        core.notebook_capture_store
            .authorize_async_transcription(&run.session_id, 1, Some("en"))
            .unwrap();
        let task_id = "ready-async-search-task";
        core.notebook_capture_store
            .reserve_async_task(&run.id, task_id, &"a".repeat(64))
            .unwrap();
        core.notebook_capture_store
            .mark_async_task_enqueued(&run.id, task_id)
            .unwrap();
        claim_current_post_stop_provider(&core.notebook_capture_store, &run.session_id);
        let token = vt_model::Token {
            text: "async authority only".into(),
            start_ms: 0,
            end_ms: 500,
            is_final: true,
            language: "en".into(),
            confidence: 1.0,
            translation_status: vt_model::TranslationStatus::Original,
            speaker: None,
        };
        let result_json = serde_json::json!({
            "session_id": run.session_id,
            "token_count": 1,
            "full_text": "async authority only",
            "duration_ms": 500,
        })
        .to_string();
        let receipt = core
            .notebook_capture_store
            .commit_async_provider_success(&run.session_id, task_id, &[token], &result_json)
            .unwrap();
        crate::transcribe_api::project_transcribe_search_receipt(
            &temp.path().join("zulangue.db"),
            &receipt,
        )
        .unwrap();
        assert_eq!(
            core.notebook_capture_store
                .get_async_provider_receipt(&run.session_id, task_id)
                .unwrap()
                .unwrap()
                .search_projection_state,
            AsyncSearchProjectionState::Ready
        );
        assert_eq!(
            core.search_sessions("authority".into(), 10).unwrap().len(),
            1
        );
        assert!(core.search_sessions("hello".into(), 10).unwrap().is_empty());

        // Exercise the startup repair routine directly. SearchStore has replace
        // semantics, so a realtime-only rebuild here would erase the already
        // Ready post-stop transcript and it would never be replayed.
        core.resume_pending_notebook_projection_mutations().unwrap();

        assert_eq!(
            core.search_sessions("authority".into(), 10).unwrap().len(),
            1
        );
        assert!(core.search_sessions("hello".into(), 10).unwrap().is_empty());
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
        // durable block document before staging a lane edit. Dropping the
        // live handles forces the edit path to reopen the corrupt bytes.
        std::fs::remove_file(&path).unwrap();
        core.editor_bridge.evict(&doc_id);
        core.notebook_capture_store
            .retry_projection(&run_id)
            .unwrap();
        core.project_notebook_capture(&run_id).unwrap();
        let block_path = temp
            .path()
            .join("block-documents")
            .join(format!("{doc_id}.loro"));
        std::fs::write(&block_path, corrupt).unwrap();
        core.block_documents.lock().unwrap().remove(&doc_id);
        core.editor_bridge.evict(&doc_id);
        let original = core
            .notebook_capture_store
            .get_utterance_by_id("utterance-a")
            .unwrap()
            .unwrap();
        let original_edit_revision = original
            .variants
            .iter()
            .find(|variant| variant.language == "zh")
            .map(|variant| variant.edit_revision)
            .unwrap_or(0);
        assert!(core
            .replace_notebook_utterance_lane(
                "utterance-a".into(),
                "zh".into(),
                "损坏快照不得提交".into(),
                original_edit_revision,
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
        assert_eq!(std::fs::read(&block_path).unwrap(), corrupt);

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
        assert_eq!(std::fs::read(&block_path).unwrap(), corrupt);
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
        let block_path = temp
            .path()
            .join("block-documents")
            .join(format!("{doc_id}.loro"));
        std::fs::write(&block_path, b"corrupt-purge-snapshot").unwrap();
        core.block_documents.lock().unwrap().remove(&doc_id);
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
        assert!(
            quarantined.last_error.as_deref().is_some_and(|message| {
                message.contains("snapshot")
                    || message.contains("Loro")
                    || message.contains("loro")
                    || message.contains("块文档")
            }),
            "unexpected durable purge error: {:?}",
            quarantined.last_error
        );
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

    /// Mirror suite for the T2 capture pipeline (switchover charter shard 2):
    /// every test here shadows an epoch-1 protocol test above, with the
    /// document assertions moved from rendered flat text to typed blocks.
    mod t2 {
        use super::*;

        fn t2_projection() -> TranscriptProjection {
            TranscriptProjection::open(vt_store::document_schema::new_block_document(
                vt_store::document_schema::DocumentKind::Transcript,
            ))
            .unwrap()
        }

        /// T2 twin of `project_test_snapshots`: replays each SQLite snapshot
        /// through the production upsert loop and returns the block list.
        fn t2_project_test_snapshots(
            snapshots: Vec<Vec<RealtimeUtterance>>,
        ) -> Vec<UtteranceBlock> {
            let projection = t2_projection();
            for snapshot in &snapshots {
                t2_upsert_finalized_utterances(&projection, "session-a", snapshot).unwrap();
            }
            projection.blocks()
        }

        fn t2_final_source(
            session_id: &str,
            id: &str,
            sequence: u64,
            text: &str,
        ) -> RealtimeUtterance {
            let mut utterance = projected_utterance();
            utterance.session_id = session_id.into();
            utterance.id = id.into();
            utterance.sequence = sequence;
            utterance.source_text = text.into();
            utterance.translated_language = None;
            utterance.translated_text = None;
            utterance.variants = vec![projected_source_variant("en", text, 1)];
            utterance
        }

        fn t2_block_doc_path(temp: &tempfile::TempDir, doc_id: &str) -> std::path::PathBuf {
            temp.path()
                .join("block-documents")
                .join(format!("{doc_id}.loro"))
        }

        fn t2_blocks(core: &ZulangueCore, doc_id: &str) -> Vec<UtteranceBlock> {
            core.with_transcript(doc_id, |projection| Ok(projection.refresh()))
                .unwrap()
        }

        /// 用户可见覆盖层里的一条车道(裸机器行永远不带 edit revision)。
        fn t2_visible_lane(
            core: &ZulangueCore,
            utterance_id: &str,
            lane_language: &str,
        ) -> RealtimeUtteranceVariant {
            core.notebook_capture_store
                .list_utterances("session-a")
                .unwrap()
                .into_iter()
                .find(|utterance| utterance.id == utterance_id)
                .unwrap()
                .variants
                .into_iter()
                .find(|variant| normalize_language(&variant.language) == lane_language)
                .unwrap()
        }

        // ---- projection write path (mirror of the incremental render tests) ----

        #[test]
        fn t2_projection_converges_to_identical_blocks_for_out_of_order_finals() {
            let finals = two_multilingual_final_utterances();
            let expected = t2_project_test_snapshots(vec![finals.clone()]);
            assert_eq!(
                expected.iter().map(|b| b.id.as_str()).collect::<Vec<_>>(),
                vec!["utterance-0", "utterance-1"],
                "块序=句序"
            );
            assert_eq!(expected[0].text, "source zero");
            assert_eq!(expected[0].owner, "capture:session-a");
            assert_eq!(expected[0].lanes["zh"], "零");
            assert_eq!(expected[0].lanes["th"], "ศูนย์");
            assert_eq!(expected[1].lanes["zh"], "一");

            let sources_first = finals
                .iter()
                .cloned()
                .map(|mut utterance| {
                    utterance
                        .variants
                        .retain(|variant| variant.role == UtteranceVariantRole::Source);
                    utterance.translated_language = None;
                    utterance.translated_text = None;
                    utterance
                })
                .collect::<Vec<_>>();

            let mut translation_first = finals.clone();
            for utterance in &mut translation_first {
                utterance.completion = UtteranceCompletion::Partial;
                utterance.source_projection_revision = 0;
                utterance.variants.clear();
            }
            translation_first[1].variants = vec![projected_translation_variant("ZH-hans", "一", 4)];

            let mut first_sparse = translation_first.clone();
            first_sparse[1].variants = vec![projected_translation_variant("TH-th", "หนึ่ง", 6)];
            let mut second_sparse = first_sparse.clone();
            second_sparse[0].variants = vec![projected_translation_variant("zh-Hans", "零", 3)];
            let mut sources_with_sparse_translations = finals.clone();
            sources_with_sparse_translations[0]
                .variants
                .retain(|variant| {
                    variant.role == UtteranceVariantRole::Source
                        || capture_lane_id(&variant.language) == "zh"
                });
            sources_with_sparse_translations[1]
                .variants
                .retain(|variant| {
                    variant.role == UtteranceVariantRole::Source
                        || capture_lane_id(&variant.language) == "th"
                });

            for projected in [
                t2_project_test_snapshots(vec![sources_first, finals.clone()]),
                t2_project_test_snapshots(vec![translation_first, finals.clone()]),
                t2_project_test_snapshots(vec![
                    first_sparse,
                    second_sparse,
                    sources_with_sparse_translations,
                    finals.clone(),
                ]),
            ] {
                assert_eq!(projected, expected);
            }
        }

        #[test]
        fn t2_projection_ignores_partial_lanes_until_each_lane_is_final() {
            let projection = t2_projection();
            let mut utterance = projected_utterance();
            utterance.variants[0].completion = Some(UtteranceCompletion::Partial);
            t2_upsert_finalized_utterances(&projection, "session-a", &[utterance.clone()]).unwrap();
            let blocks = projection.blocks();
            assert_eq!(blocks.len(), 1);
            assert_eq!(blocks[0].text, "good morning 🌏", "源 Final 照常落块");
            assert!(blocks[0].lanes.is_empty(), "Partial 译文车道不落块");

            // 全推测的句子连块都不产生。
            let mut speculative = projected_utterance();
            speculative.id = "utterance-spec".into();
            speculative.sequence = 1;
            speculative.completion = UtteranceCompletion::Partial;
            speculative.variants[0].completion = Some(UtteranceCompletion::Partial);
            speculative.variants[1].completion = Some(UtteranceCompletion::Partial);
            t2_upsert_finalized_utterances(
                &projection,
                "session-a",
                &[utterance.clone(), speculative],
            )
            .unwrap();
            assert_eq!(projection.blocks().len(), 1);

            // 车道 Final 之后才落地。
            utterance.variants[0].completion = Some(UtteranceCompletion::Complete);
            t2_upsert_finalized_utterances(&projection, "session-a", &[utterance]).unwrap();
            assert_eq!(projection.blocks()[0].lanes["zh"], "早上好");
        }

        #[test]
        fn t2_machine_never_rewrites_a_user_frozen_lane() {
            let projection = t2_projection();
            let mut utterance = projected_utterance();
            t2_upsert_finalized_utterances(&projection, "session-a", &[utterance.clone()]).unwrap();
            projection
                .user_replace_lane("utterance-a", "zh", "早上好(人工)")
                .unwrap();

            // 机器带着修订回来,但 SQLite 车道 edit revision 已经 > 0。
            utterance.variants[0].text = Some("早上好(机器v2)".into());
            utterance.variants[0].edit_revision = 1;
            utterance.source_text = "good morning (revised)".into();
            utterance.variants[1].text = Some("good morning (revised)".into());
            t2_upsert_finalized_utterances(&projection, "session-a", &[utterance]).unwrap();

            let blocks = projection.blocks();
            assert_eq!(blocks[0].text, "good morning (revised)", "源车道照常推进");
            assert_eq!(
                blocks[0].lanes["zh"], "早上好(人工)",
                "冻结车道机器绝不覆盖"
            );
        }

        #[test]
        fn t2_translation_only_shell_projects_without_source_and_fills_in_later() {
            let projection = t2_projection();
            let mut utterance = projected_utterance();
            utterance.completion = UtteranceCompletion::Partial;
            utterance.source_projection_revision = 0;
            // 源变体尚未 Final,译文已 Final(译文先于原文的既有语义)。
            utterance.variants[1].completion = Some(UtteranceCompletion::Partial);
            t2_upsert_finalized_utterances(&projection, "session-a", &[utterance.clone()]).unwrap();
            let blocks = projection.blocks();
            assert_eq!(blocks.len(), 1);
            assert_eq!(blocks[0].text, "", "源未 Final,text 留白");
            assert_eq!(blocks[0].lanes["zh"], "早上好");

            // 源随后 Final:text 补上,车道不动。
            utterance.completion = UtteranceCompletion::Complete;
            utterance.variants[1].completion = Some(UtteranceCompletion::Complete);
            t2_upsert_finalized_utterances(&projection, "session-a", &[utterance]).unwrap();
            let blocks = projection.blocks();
            assert_eq!(blocks[0].text, "good morning 🌏");
            assert_eq!(blocks[0].lanes["zh"], "早上好");
        }

        #[test]
        fn t2_late_finals_insert_in_sequence_order_across_annotations_and_sessions() {
            let projection = t2_projection();
            let u0 = t2_final_source("session-a", "a0", 0, "零");
            let mut u1 = t2_final_source("session-a", "a1", 1, "一");
            u1.completion = UtteranceCompletion::Partial;
            u1.variants[0].completion = Some(UtteranceCompletion::Partial);
            let u2 = t2_final_source("session-a", "a2", 2, "二");
            t2_upsert_finalized_utterances(
                &projection,
                "session-a",
                &[u0.clone(), u1.clone(), u2.clone()],
            )
            .unwrap();
            // 用户在当前区域尾插批注,然后 session-b 开始。
            projection.insert_annotation(2, "n1", "备注").unwrap();
            let b0 = t2_final_source("session-b", "b0", 0, "乙零");
            t2_upsert_finalized_utterances(&projection, "session-b", &[b0]).unwrap();

            // 迟到的 a1 Final:插回 a0 与 a2 之间。
            let mut u1_final = u1.clone();
            u1_final.completion = UtteranceCompletion::Complete;
            u1_final.variants[0].completion = Some(UtteranceCompletion::Complete);
            t2_upsert_finalized_utterances(
                &projection,
                "session-a",
                &[u0.clone(), u1_final, u2.clone()],
            )
            .unwrap();

            // 迟到的 a3(序号最大):跳过尾随批注,停在 session-b 区域之前。
            let u3 = t2_final_source("session-a", "a3", 3, "三");
            t2_upsert_finalized_utterances(&projection, "session-a", &[u0, u2, u3]).unwrap();

            let ids: Vec<_> = projection.blocks().into_iter().map(|b| b.id).collect();
            assert_eq!(ids, vec!["a0", "a1", "a2", "n1", "a3", "b0"]);
        }

        // ---- full-core integration (mirror of the projected_core_fixture tests) ----

        #[test]
        fn t2_incremental_projection_acks_watermark_and_persists_blocks() {
            let (temp, core, _notebook_id, _run_id, doc_id) = projected_core_fixture();
            core.project_notebook_realtime_incremental("session-a".into())
                .unwrap();
            let projected = core
                .notebook_capture_store
                .load_realtime_loro_projection("session-a")
                .unwrap();
            assert_eq!(projected.applied_revision, projected.desired_revision);
            assert!(t2_block_doc_path(&temp, &doc_id).exists());

            // 关句柄、从磁盘重开:块在,形状完整。
            core.block_document_close(doc_id.clone()).unwrap();
            core.block_document_open(
                doc_id.clone(),
                crate::block_document_api::FfiDocumentKind::Transcript,
            )
            .unwrap();
            let blocks = t2_blocks(&core, &doc_id);
            assert_eq!(blocks.len(), 1);
            assert_eq!(blocks[0].id, "utterance-a");
            assert_eq!(blocks[0].owner, "capture:session-a");
            assert_eq!(blocks[0].text, "hello");
            assert_eq!(blocks[0].lanes["zh"], "你好");
        }

        #[test]
        fn t2_up_to_date_incremental_projection_skips_machine_fact_hydration() {
            let (temp, core, _notebook_id, _run_id, _doc_id) = projected_core_fixture();
            core.project_notebook_realtime_incremental("session-a".into())
                .unwrap();

            let conn = rusqlite::Connection::open(temp.path().join("zulangue.db")).unwrap();
            conn.pragma_update(None, "ignore_check_constraints", "ON")
                .unwrap();
            conn.execute(
                "UPDATE realtime_utterances
                 SET completion = 'invalid-test-value'
                 WHERE id = 'utterance-a'",
                [],
            )
            .unwrap();
            conn.pragma_update(None, "ignore_check_constraints", "OFF")
                .unwrap();
            assert!(core
                .notebook_capture_store
                .load_realtime_loro_projection("session-a")
                .is_err());

            core.project_notebook_realtime_incremental("session-a".into())
                .expect("an up-to-date wake must not hydrate the full machine-fact ledger");
        }

        #[test]
        fn t2_terminal_projection_keeps_search_and_ready_semantics_after_incremental_ack() {
            let (_temp, core, _notebook_id, run_id, _doc_id) = projected_core_fixture();
            core.project_notebook_realtime_incremental("session-a".into())
                .unwrap();
            core.search_store
                .index_session("session-a", "stale disposable index")
                .unwrap();
            assert!(core.search_sessions("hello".into(), 10).unwrap().is_empty());

            core.project_notebook_capture(&run_id).unwrap();

            let run = core
                .notebook_capture_store
                .get_run(&run_id)
                .unwrap()
                .unwrap();
            assert_eq!(run.projection_state, ProjectionState::Ready);
            assert!(core
                .search_sessions("hello".into(), 10)
                .unwrap()
                .iter()
                .any(|result| result.session_id == "session-a"));
        }

        /// 收据整族退役的核心证明:ACK 之前中断的重放(把同一份快照原样
        /// 再 upsert 一遍)终态逐字相同。
        #[test]
        fn t2_replaying_an_applied_snapshot_is_idempotent() {
            let (_temp, core, _notebook_id, _run_id, doc_id) = projected_core_fixture();
            core.project_notebook_realtime_incremental("session-a".into())
                .unwrap();
            let before = t2_blocks(&core, &doc_id);
            assert_eq!(before.len(), 1);

            // 第二次唤醒:UpToDate,无变化。
            core.project_notebook_realtime_incremental("session-a".into())
                .unwrap();
            assert_eq!(t2_blocks(&core, &doc_id), before);

            // 崩溃重放:绕过水位,直接重放整份快照。
            let snapshot = core
                .notebook_capture_store
                .load_realtime_loro_projection("session-a")
                .unwrap();
            core.with_transcript(&doc_id, |projection| {
                t2_upsert_finalized_utterances(
                    projection,
                    "session-a",
                    &snapshot.machine_utterances,
                )
            })
            .unwrap();
            assert_eq!(t2_blocks(&core, &doc_id), before);
        }

        // ---- user correction path (mirror of the lane mutation tests) ----

        #[test]
        fn t2_two_sequential_unicode_lane_edits_commit_override_and_block() {
            let (_temp, core, _notebook_id, _run_id, doc_id) = projected_core_fixture();
            core.project_notebook_realtime_incremental("session-a".into())
                .unwrap();

            core.replace_notebook_utterance_lane(
                "utterance-a".into(),
                "zh".into(),
                "第一次编辑 🧭\n第二行".into(),
                0,
            )
            .unwrap();
            core.replace_notebook_utterance_lane(
                "utterance-a".into(),
                "zh".into(),
                "第二次编辑 你好🌏".into(),
                1,
            )
            .unwrap();

            let blocks = t2_blocks(&core, &doc_id);
            assert_eq!(blocks[0].lanes["zh"], "第二次编辑 你好🌏");
            // 覆盖层是可见事实:裸机器行保持原文本,edit revision 记在
            // 可见变体上。
            let variant = t2_visible_lane(&core, "utterance-a", "zh");
            assert_eq!(variant.edit_revision, 2);
            assert_eq!(variant.text.as_deref(), Some("第二次编辑 你好🌏"));

            // 过期的 expectedRevision:逐字不变的乐观锁拒绝,文档不动。
            let error = core
                .replace_notebook_utterance_lane(
                    "utterance-a".into(),
                    "zh".into(),
                    "过期编辑".into(),
                    0,
                )
                .unwrap_err();
            assert!(
                error.to_string().contains("0"),
                "冲突错误报出期望修订: {error}"
            );
            assert_eq!(
                t2_blocks(&core, &doc_id)[0].lanes["zh"],
                "第二次编辑 你好🌏"
            );
            assert!(core
                .notebook_capture_store
                .list_pending_projection_mutations()
                .unwrap()
                .is_empty());

            // 机器重放绝不覆盖已接管车道:用可见事实整卷重放(生产的
            // 崩溃重放语义),frozen 来自真实的车道 edit revision。
            let visible = core
                .notebook_capture_store
                .list_utterances("session-a")
                .unwrap();
            core.with_transcript(&doc_id, |projection| {
                t2_upsert_finalized_utterances(projection, "session-a", &visible)
            })
            .unwrap();
            assert_eq!(
                t2_blocks(&core, &doc_id)[0].lanes["zh"],
                "第二次编辑 你好🌏",
                "重放绝不覆盖用户车道"
            );
        }

        /// 镜像 durable_user_lane_receipt_replays_only_the_sqlite_commit_after_crash:
        /// 文档动词 + 落盘已完成、SQLite 覆盖提交缺席的崩溃窗口,启动重放
        /// 只补提交,车道修订恰好 +1。
        #[test]
        fn t2_pending_mutation_replays_only_the_sqlite_commit_after_crash() {
            let (_temp, core, _notebook_id, _run_id, doc_id) = projected_core_fixture();
            core.project_notebook_realtime_incremental("session-a".into())
                .unwrap();

            let mutation = core
                .notebook_capture_store
                .stage_utterance_variant_replacement("utterance-a", "zh", "人工订正 ✍️", 0)
                .unwrap();
            core.with_transcript(&doc_id, |projection| {
                projection
                    .user_replace_lane("utterance-a", "zh", "人工订正 ✍️")
                    .map_err(store_error)
            })
            .unwrap();
            core.persist_block_document(&doc_id).unwrap();

            // 启动重放:幂等动词重放 + 只补 SQLite 提交。
            core.apply_notebook_projection_mutation_t2(&mutation)
                .unwrap();

            assert_eq!(t2_blocks(&core, &doc_id)[0].lanes["zh"], "人工订正 ✍️");
            let variant = t2_visible_lane(&core, "utterance-a", "zh");
            assert_eq!(variant.edit_revision, 1, "重放不能二次递增");
            assert_eq!(variant.text.as_deref(), Some("人工订正 ✍️"));
            assert!(core
                .notebook_capture_store
                .list_pending_projection_mutations()
                .unwrap()
                .is_empty());
        }

        /// 镜像 corrupt_snapshot_never_commits_projection_lane_mutation_or_purge
        /// 的取消语义:文档动词失败必须取消暂存行,SQLite 车道不动。
        #[test]
        fn t2_missing_block_cancels_the_staged_mutation() {
            let (temp, core, _notebook_id, _run_id, doc_id) = projected_core_fixture();
            core.project_notebook_realtime_incremental("session-a".into())
                .unwrap();
            // 弄丢块文档(极端损坏情形):关句柄、删文件。
            core.block_document_close(doc_id.clone()).unwrap();
            std::fs::remove_file(t2_block_doc_path(&temp, &doc_id)).unwrap();

            let error = core
                .replace_notebook_utterance_lane(
                    "utterance-a".into(),
                    "zh".into(),
                    "编辑".into(),
                    0,
                )
                .unwrap_err();
            assert!(
                error.to_string().contains("is missing"),
                "缺块要报得出名字: {error}"
            );
            assert!(core
                .notebook_capture_store
                .list_pending_projection_mutations()
                .unwrap()
                .is_empty());
            let variant = t2_visible_lane(&core, "utterance-a", "zh");
            assert_eq!(variant.edit_revision, 0);
            assert_eq!(variant.text.as_deref(), Some("你好"));
        }
    }
}
