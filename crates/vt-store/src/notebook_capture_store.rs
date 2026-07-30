//! Persistent ownership for the single active Notebook capture runtime.
//!
//! The store keeps provider state and transcript projection state separate so a
//! remote failure can never terminate or discard the local audio journal.

use std::path::Path;
use std::sync::{Arc, Mutex};

use rusqlite::{params, Connection, OptionalExtension, Row, TransactionBehavior};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use thiserror::Error;
use vt_model::Token;

use crate::session_query::SessionRecord;

pub const SONIOX_PROVIDER_ID: &str = "soniox";
pub const SONIOX_STT_RT_V5_MODEL_ID: &str = "stt-rt-v5";
pub const MAX_CAPTURE_LANGUAGES: usize = 4;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CaptureMode {
    TranscriptionOnly,
    TwoWay,
    MultilingualOneWay,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CaptureProviderRole {
    Realtime,
    PostStop,
}

impl CaptureMode {
    fn as_str(self) -> &'static str {
        match self {
            Self::TranscriptionOnly => "transcription_only",
            Self::TwoWay => "two_way",
            Self::MultilingualOneWay => "multilingual_one_way",
        }
    }

    fn parse(value: &str) -> Result<Self, NotebookCaptureStoreError> {
        match value {
            "transcription_only" => Ok(Self::TranscriptionOnly),
            "two_way" => Ok(Self::TwoWay),
            "multilingual_one_way" => Ok(Self::MultilingualOneWay),
            other => Err(NotebookCaptureStoreError::CorruptData(format!(
                "unknown capture mode '{other}'"
            ))),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CaptureState {
    Recording,
    Paused,
    Draining,
    Completed,
    Interrupted,
    Failed,
}

impl CaptureState {
    pub fn is_active(self) -> bool {
        matches!(self, Self::Recording | Self::Paused | Self::Draining)
    }

    pub fn is_terminal(self) -> bool {
        !self.is_active()
    }

    fn as_str(self) -> &'static str {
        match self {
            Self::Recording => "recording",
            Self::Paused => "paused",
            Self::Draining => "draining",
            Self::Completed => "completed",
            Self::Interrupted => "interrupted",
            Self::Failed => "failed",
        }
    }

    fn parse(value: &str) -> Result<Self, NotebookCaptureStoreError> {
        match value {
            "recording" => Ok(Self::Recording),
            "paused" => Ok(Self::Paused),
            "draining" => Ok(Self::Draining),
            "completed" => Ok(Self::Completed),
            "interrupted" => Ok(Self::Interrupted),
            "failed" => Ok(Self::Failed),
            other => Err(NotebookCaptureStoreError::CorruptData(format!(
                "unknown capture state '{other}'"
            ))),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RemoteHealth {
    Off,
    Connecting,
    Live,
    Degraded,
    Unavailable,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RealtimeTranscriptGap {
    pub id: String,
    pub session_id: String,
    pub start_frame: u64,
    pub end_frame: u64,
    pub reason: String,
    pub repair_state: String,
    pub created_at: String,
    pub updated_at: String,
}

impl RemoteHealth {
    fn as_str(self) -> &'static str {
        match self {
            Self::Off => "off",
            Self::Connecting => "connecting",
            Self::Live => "live",
            Self::Degraded => "degraded",
            Self::Unavailable => "unavailable",
        }
    }

    fn parse(value: &str) -> Result<Self, NotebookCaptureStoreError> {
        match value {
            "off" => Ok(Self::Off),
            "connecting" => Ok(Self::Connecting),
            "live" => Ok(Self::Live),
            "degraded" => Ok(Self::Degraded),
            "unavailable" => Ok(Self::Unavailable),
            other => Err(NotebookCaptureStoreError::CorruptData(format!(
                "unknown remote health '{other}'"
            ))),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ProjectionState {
    Pending,
    Projecting,
    Ready,
    Failed,
}

impl ProjectionState {
    fn as_str(self) -> &'static str {
        match self {
            Self::Pending => "pending",
            Self::Projecting => "projecting",
            Self::Ready => "ready",
            Self::Failed => "failed",
        }
    }

    fn parse(value: &str) -> Result<Self, NotebookCaptureStoreError> {
        match value {
            "pending" => Ok(Self::Pending),
            "projecting" => Ok(Self::Projecting),
            "ready" => Ok(Self::Ready),
            "failed" => Ok(Self::Failed),
            other => Err(NotebookCaptureStoreError::CorruptData(format!(
                "unknown projection state '{other}'"
            ))),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AsyncTaskState {
    None,
    Pending,
    Reserved,
    Enqueued,
    Completed,
    Failed,
}

/// Local materialization state for the provider's durable async transcript.
/// This is intentionally independent from [`AsyncTaskState`]: provider work
/// may be completed while the Loro projection is retryably failed.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AsyncProjectionState {
    None,
    Pending,
    Projecting,
    Ready,
    Failed,
}

/// Retryable local FTS materialization of an already durable provider result.
/// This state never controls whether provider audio may be uploaded.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AsyncSearchProjectionState {
    None,
    Pending,
    Ready,
    Failed,
}

impl AsyncSearchProjectionState {
    fn as_str(self) -> &'static str {
        match self {
            Self::None => "none",
            Self::Pending => "pending",
            Self::Ready => "ready",
            Self::Failed => "failed",
        }
    }

    fn parse(value: &str) -> Result<Self, NotebookCaptureStoreError> {
        match value {
            "none" => Ok(Self::None),
            "pending" => Ok(Self::Pending),
            "ready" => Ok(Self::Ready),
            "failed" => Ok(Self::Failed),
            other => Err(NotebookCaptureStoreError::CorruptData(format!(
                "unknown async search projection state '{other}'"
            ))),
        }
    }
}

impl AsyncProjectionState {
    fn as_str(self) -> &'static str {
        match self {
            Self::None => "none",
            Self::Pending => "pending",
            Self::Projecting => "projecting",
            Self::Ready => "ready",
            Self::Failed => "failed",
        }
    }

    fn parse(value: &str) -> Result<Self, NotebookCaptureStoreError> {
        match value {
            "none" => Ok(Self::None),
            "pending" => Ok(Self::Pending),
            "projecting" => Ok(Self::Projecting),
            "ready" => Ok(Self::Ready),
            "failed" => Ok(Self::Failed),
            other => Err(NotebookCaptureStoreError::CorruptData(format!(
                "unknown async projection state '{other}'"
            ))),
        }
    }
}

impl AsyncTaskState {
    fn as_str(self) -> &'static str {
        match self {
            Self::None => "none",
            Self::Pending => "pending",
            Self::Reserved => "reserved",
            Self::Enqueued => "enqueued",
            Self::Completed => "completed",
            Self::Failed => "failed",
        }
    }

    fn parse(value: &str) -> Result<Self, NotebookCaptureStoreError> {
        match value {
            "none" => Ok(Self::None),
            "pending" => Ok(Self::Pending),
            "reserved" => Ok(Self::Reserved),
            "enqueued" => Ok(Self::Enqueued),
            "completed" => Ok(Self::Completed),
            "failed" => Ok(Self::Failed),
            other => Err(NotebookCaptureStoreError::CorruptData(format!(
                "unknown async task state '{other}'"
            ))),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum UtteranceCompletion {
    Partial,
    Complete,
}

impl UtteranceCompletion {
    fn as_str(self) -> &'static str {
        match self {
            Self::Partial => "partial",
            Self::Complete => "complete",
        }
    }

    fn parse(value: &str) -> Result<Self, NotebookCaptureStoreError> {
        match value {
            "partial" => Ok(Self::Partial),
            "complete" => Ok(Self::Complete),
            other => Err(NotebookCaptureStoreError::CorruptData(format!(
                "unknown utterance completion '{other}'"
            ))),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum UtteranceAlignment {
    Paired,
    SourceOnly,
    TranslationPending,
    OutsideLanguagePair,
}

impl UtteranceAlignment {
    fn as_str(self) -> &'static str {
        match self {
            Self::Paired => "paired",
            Self::SourceOnly => "source_only",
            Self::TranslationPending => "translation_pending",
            Self::OutsideLanguagePair => "outside_language_pair",
        }
    }

    fn parse(value: &str) -> Result<Self, NotebookCaptureStoreError> {
        match value {
            "paired" => Ok(Self::Paired),
            "source_only" => Ok(Self::SourceOnly),
            "translation_pending" => Ok(Self::TranslationPending),
            "outside_language_pair" => Ok(Self::OutsideLanguagePair),
            other => Err(NotebookCaptureStoreError::CorruptData(format!(
                "unknown utterance alignment '{other}'"
            ))),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum UtteranceLane {
    Source,
    Translated,
}

impl UtteranceLane {
    fn as_str(self) -> &'static str {
        match self {
            Self::Source => "source",
            Self::Translated => "translated",
        }
    }

    fn parse(value: &str) -> Result<Self, NotebookCaptureStoreError> {
        match value {
            "source" => Ok(Self::Source),
            "translated" => Ok(Self::Translated),
            other => Err(NotebookCaptureStoreError::CorruptData(format!(
                "unknown utterance lane '{other}'"
            ))),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum UtteranceVariantRole {
    Source,
    Translation,
}

impl UtteranceVariantRole {
    fn as_str(self) -> &'static str {
        match self {
            Self::Source => "source",
            Self::Translation => "translation",
        }
    }

    fn parse(value: &str) -> Result<Self, NotebookCaptureStoreError> {
        match value {
            "source" => Ok(Self::Source),
            "translation" => Ok(Self::Translation),
            other => Err(NotebookCaptureStoreError::CorruptData(format!(
                "unknown utterance variant role '{other}'"
            ))),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum UtteranceVariantState {
    Waiting,
    Ready,
    Failed,
    Unavailable,
}

impl UtteranceVariantState {
    fn as_str(self) -> &'static str {
        match self {
            Self::Waiting => "waiting",
            Self::Ready => "ready",
            Self::Failed => "failed",
            Self::Unavailable => "unavailable",
        }
    }

    fn parse(value: &str) -> Result<Self, NotebookCaptureStoreError> {
        match value {
            "waiting" => Ok(Self::Waiting),
            "ready" => Ok(Self::Ready),
            "failed" => Ok(Self::Failed),
            "unavailable" => Ok(Self::Unavailable),
            other => Err(NotebookCaptureStoreError::CorruptData(format!(
                "unknown utterance variant state '{other}'"
            ))),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ProjectionMutationState {
    Pending,
}

impl ProjectionMutationState {
    fn as_str(self) -> &'static str {
        match self {
            Self::Pending => "pending",
        }
    }

    fn parse(value: &str) -> Result<Self, NotebookCaptureStoreError> {
        match value {
            "pending" => Ok(Self::Pending),
            other => Err(NotebookCaptureStoreError::CorruptData(format!(
                "unknown projection mutation state '{other}'"
            ))),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct NotebookCaptureProfile {
    pub notebook_id: String,
    pub remote_realtime_enabled: bool,
    pub capture_mode: CaptureMode,
    pub language_a: String,
    pub language_b: String,
    pub left_language: String,
    pub right_language: String,
    /// Ordered language columns selected before capture.
    ///
    /// Old immutable run snapshots deserialize to an empty vector so history
    /// can report their missing configuration without inventing columns.
    #[serde(default)]
    pub selected_languages: Vec<String>,
    /// Explicit shared caption target for 3+ language one-way translation.
    #[serde(default)]
    pub common_caption_language: Option<String>,
    pub privacy_level: String,
    pub send_context_to_soniox: bool,
    pub revision: u64,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NotebookCaptureProfileUpdate {
    pub remote_realtime_enabled: bool,
    pub capture_mode: CaptureMode,
    pub language_a: String,
    pub language_b: String,
    pub left_language: String,
    pub right_language: String,
    pub selected_languages: Vec<String>,
    pub common_caption_language: Option<String>,
    pub privacy_level: String,
    pub send_context_to_soniox: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NewNotebookCaptureRun {
    pub id: String,
    pub notebook_id: String,
    pub session_id: String,
    pub remote_health: RemoteHealth,
    pub audio_journal_path: String,
    pub audio_key_ref: String,
    pub sample_rate: u32,
    pub channels: u16,
}

/// Finalized local audio imported directly into a Notebook.
///
/// Imports never occupy the process-wide active capture slot and never have a
/// recording journal. They still receive the same immutable profile snapshot
/// and async-task receipt state as a microphone capture stopped normally.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NewCompletedNotebookImportRun {
    pub id: String,
    pub notebook_id: String,
    pub session_id: String,
    pub audio_path: String,
    pub audio_key_ref: String,
    pub sample_rate: u32,
    pub channels: u16,
    pub captured_frames: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NotebookCaptureRun {
    pub id: String,
    pub notebook_id: String,
    pub session_id: String,
    pub profile_revision: u64,
    pub profile_snapshot_json: String,
    pub realtime_provider_id: Option<String>,
    pub realtime_model_id: Option<String>,
    pub post_stop_provider_id: Option<String>,
    pub post_stop_model_id: Option<String>,
    pub context_receipt_json: Option<String>,
    pub context_applied_at: Option<String>,
    pub capture_state: CaptureState,
    pub remote_health: RemoteHealth,
    pub projection_state: ProjectionState,
    pub async_task_state: AsyncTaskState,
    pub async_authorized_at_ms: Option<i64>,
    pub async_language_hint: Option<String>,
    pub async_projection_state: AsyncProjectionState,
    pub async_task_id: Option<String>,
    pub async_task_payload_sha256: Option<String>,
    pub provider_error_type: Option<String>,
    pub provider_request_id: Option<String>,
    pub audio_journal_path: Option<String>,
    pub audio_path: Option<String>,
    pub audio_key_ref: Option<String>,
    pub sample_rate: Option<u32>,
    pub channels: Option<u16>,
    pub captured_frames: u64,
    pub created_at: String,
    pub updated_at: String,
    pub completed_at: Option<String>,
}

/// Immutable proof that one stable async task has already received and
/// durably committed its provider output. `tokens_json` lives in
/// `session_meta` in the same SQLite transaction; this receipt lets a reclaimed
/// tasks.db row finish locally without constructing or calling Soniox again.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AsyncProviderReceipt {
    pub session_id: String,
    pub task_id: String,
    pub provider_id: String,
    pub model_id: String,
    pub output_sha256: String,
    pub result_json: String,
    pub search_projection_state: AsyncSearchProjectionState,
    pub completed_at: String,
}

/// One corrupt receipt discovered while scanning startup/worker recovery.
///
/// Scans keep this identity separate from validated receipts so one damaged
/// session cannot prevent the Core from opening or block recovery for unrelated
/// sessions. Callers must quarantine the exact task and must never treat this as
/// an absent receipt (which could otherwise cause a second provider request).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CorruptAsyncProviderReceipt {
    pub session_id: String,
    pub task_id: Option<String>,
    pub reason: String,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct AsyncProviderReceiptScan {
    pub receipts: Vec<AsyncProviderReceipt>,
    pub corrupt: Vec<CorruptAsyncProviderReceipt>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProviderFailure {
    pub error_type: String,
    pub request_id: Option<String>,
}

/// A user-managed person record used only for names and manual indexing.
///
/// It intentionally contains no audio, embedding, prototype, or other
/// biometric material.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Participant {
    pub id: String,
    pub display_name: String,
    pub created_at: String,
    pub updated_at: String,
}

/// One anonymous provider speaker label scoped to a single connection epoch.
///
/// Provider labels are not stable identities. `participant_id` is populated
/// only through an explicit user action and is never inferred from audio.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SessionSpeaker {
    pub id: String,
    pub session_id: String,
    pub provider_session_epoch: u64,
    pub provider: String,
    pub provider_label: String,
    pub local_display_name: Option<String>,
    pub participant_id: Option<String>,
    pub participant_linked_at: Option<String>,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NewRealtimeUtterance {
    pub id: String,
    pub session_id: String,
    pub sequence: u64,
    pub session_speaker_id: Option<String>,
    pub source_language: String,
    pub source_text: String,
    pub source_start_ms: Option<u64>,
    pub source_end_ms: Option<u64>,
    pub translated_language: Option<String>,
    pub translated_text: Option<String>,
    pub completion: UtteranceCompletion,
    pub alignment: UtteranceAlignment,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RealtimeUtteranceVariant {
    pub language: String,
    pub role: UtteranceVariantRole,
    pub text: Option<String>,
    pub state: UtteranceVariantState,
    pub completion: Option<UtteranceCompletion>,
    pub revision: u64,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RealtimeUtterance {
    pub id: String,
    pub session_id: String,
    pub sequence: u64,
    pub session_speaker_id: Option<String>,
    pub source_language: String,
    pub source_text: String,
    pub source_start_ms: Option<u64>,
    pub source_end_ms: Option<u64>,
    pub translated_language: Option<String>,
    pub translated_text: Option<String>,
    pub revision: u64,
    pub completion: UtteranceCompletion,
    pub alignment: UtteranceAlignment,
    pub created_at: String,
    pub updated_at: String,
    pub variants: Vec<RealtimeUtteranceVariant>,
}

/// Notebook-scoped capture history safe for presentation-layer consumers.
///
/// Audio paths, journal paths, key references, and async task receipts remain
/// private to [`NotebookCaptureRun`]. History exposes only whether durable
/// metadata says that at least one encrypted audio artifact is still retained.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NotebookCaptureHistoryRun {
    pub id: String,
    pub notebook_id: String,
    pub session_id: String,
    pub profile_revision: u64,
    pub profile_snapshot_json: String,
    pub realtime_provider_id: Option<String>,
    pub realtime_model_id: Option<String>,
    pub post_stop_provider_id: Option<String>,
    pub post_stop_model_id: Option<String>,
    pub capture_state: CaptureState,
    pub remote_health: RemoteHealth,
    pub projection_state: ProjectionState,
    pub async_task_state: AsyncTaskState,
    pub async_projection_state: AsyncProjectionState,
    pub provider_error_type: Option<String>,
    pub provider_request_id: Option<String>,
    pub sample_rate: Option<u32>,
    pub channels: Option<u16>,
    pub captured_frames: u64,
    pub created_at: String,
    pub updated_at: String,
    pub completed_at: Option<String>,
    pub has_audio: bool,
    pub utterances: Vec<RealtimeUtterance>,
}

impl NotebookCaptureHistoryRun {
    fn from_run(
        run: NotebookCaptureRun,
        has_audio: bool,
        utterances: Vec<RealtimeUtterance>,
    ) -> Self {
        Self {
            id: run.id,
            notebook_id: run.notebook_id,
            session_id: run.session_id,
            profile_revision: run.profile_revision,
            profile_snapshot_json: run.profile_snapshot_json,
            realtime_provider_id: run.realtime_provider_id,
            realtime_model_id: run.realtime_model_id,
            post_stop_provider_id: run.post_stop_provider_id,
            post_stop_model_id: run.post_stop_model_id,
            capture_state: run.capture_state,
            remote_health: run.remote_health,
            projection_state: run.projection_state,
            async_task_state: run.async_task_state,
            async_projection_state: run.async_projection_state,
            provider_error_type: run.provider_error_type,
            provider_request_id: run.provider_request_id,
            sample_rate: run.sample_rate,
            channels: run.channels,
            captured_frames: run.captured_frames,
            created_at: run.created_at,
            updated_at: run.updated_at,
            completed_at: run.completed_at,
            has_audio,
            utterances,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct NotebookProjectionMutation {
    pub id: String,
    pub session_id: String,
    pub utterance_id: String,
    pub lane: UtteranceLane,
    pub lane_language: String,
    pub expected_revision: u64,
    pub target_text: String,
    pub state: ProjectionMutationState,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProjectionPurgeTarget {
    pub projection_id: String,
    pub notebook_id: String,
    pub tab_id: String,
    pub doc_id: String,
}

/// External file/local-key/Loro work that surrounds the SQLite purge. Callers
/// should clear each `projection_target` from its Loro document before calling
/// `purge_session_artifacts`, then delete returned paths/keys after commit.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionPurgePlan {
    pub session_id: String,
    pub run_id: Option<String>,
    pub projection_targets: Vec<ProjectionPurgeTarget>,
    pub file_paths: Vec<String>,
    pub key_refs: Vec<String>,
    /// Canonical filenames relative to the Zulangue data directory. The FFI
    /// layer owns directory enumeration because SQLite intentionally stores no
    /// global data-directory path.
    #[serde(default)]
    pub canonical_artifact_names: Vec<String>,
    /// Canonical filename prefixes relative to the Zulangue data directory.
    /// This covers both committed chunks (`{session}.chunk.`) and interrupted
    /// recovery temp files (`.{session}.chunk.`).
    #[serde(default)]
    pub canonical_artifact_prefixes: Vec<String>,
    pub utterance_count: u64,
}

impl SessionPurgePlan {
    /// Exact document ids whose persisted content can contain data owned by
    /// this session. All current documents are Notebook-scoped Loro
    /// projection targets; there is no legacy session-document namespace.
    pub fn frozen_document_ids(&self) -> Vec<String> {
        let mut document_ids = self
            .projection_targets
            .iter()
            .map(|target| target.doc_id.clone())
            .collect::<Vec<_>>();
        document_ids.sort();
        document_ids.dedup();
        document_ids
    }

    pub fn contains_frozen_document(&self, document_id: &str) -> bool {
        self.projection_targets
            .iter()
            .any(|target| target.doc_id == document_id)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionPurgeJob {
    pub session_id: String,
    pub plan: SessionPurgePlan,
    pub phase: String,
    pub last_error: Option<String>,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Error)]
pub enum NotebookCaptureStoreError {
    #[error("SQLite error: {0}")]
    Sqlite(#[from] rusqlite::Error),
    #[error("JSON error: {0}")]
    Json(#[from] serde_json::Error),
    #[error("capture record not found: {0}")]
    NotFound(String),
    #[error("capture revision or state conflict: {0}")]
    Conflict(String),
    #[error("invalid capture input: {0}")]
    Validation(String),
    #[error("corrupt capture data: {0}")]
    CorruptData(String),
}

#[derive(Clone)]
pub struct NotebookCaptureStore {
    conn: Arc<Mutex<Connection>>,
}

impl NotebookCaptureStore {
    /// Opens the capture store without mutating capture ownership.
    ///
    /// Startup recovery is an explicit call reserved for the single Core that
    /// already owns the data-directory lock. Read-only helpers and workers may
    /// safely open another connection without interrupting a live capture.
    pub fn new(db_path: &Path) -> Result<Self, NotebookCaptureStoreError> {
        let conn = Connection::open(db_path)?;
        conn.pragma_update(None, "foreign_keys", "ON")?;
        crate::migration::run_migrations(&conn)?;
        Ok(Self {
            conn: Arc::new(Mutex::new(conn)),
        })
    }

    pub fn recover_unfinished_runs(&self) -> Result<usize, NotebookCaptureStoreError> {
        let now = chrono::Utc::now().to_rfc3339();
        let updated = self.conn.lock().unwrap().execute(
            "UPDATE notebook_capture_runs
             SET capture_state = CASE
                     WHEN capture_state IN ('recording', 'paused', 'draining')
                         THEN 'interrupted'
                     ELSE capture_state
                 END,
                 remote_health = CASE
                     WHEN capture_state IN ('recording', 'paused', 'draining')
                         THEN 'off'
                     ELSE remote_health
                 END,
                 projection_state = CASE
                     WHEN projection_state = 'projecting' THEN 'failed'
                     ELSE projection_state
                 END,
                 async_projection_state = CASE
                     WHEN async_projection_state = 'projecting' THEN 'failed'
                     ELSE async_projection_state
                 END,
                 async_task_state = CASE
                     WHEN capture_state IN ('recording', 'paused', 'draining')
                          AND async_task_state = 'pending'
                         THEN 'none'
                     ELSE async_task_state
                 END,
                 async_task_id = CASE
                     WHEN capture_state IN ('recording', 'paused', 'draining')
                          AND async_task_state = 'pending'
                         THEN NULL
                     ELSE async_task_id
                 END,
                 async_task_payload_sha256 = CASE
                     WHEN capture_state IN ('recording', 'paused', 'draining')
                          AND async_task_state = 'pending'
                         THEN NULL
                     ELSE async_task_payload_sha256
                 END,
                 updated_at = ?1,
                 completed_at = CASE
                     WHEN capture_state IN ('recording', 'paused', 'draining')
                         THEN COALESCE(completed_at, ?1)
                     ELSE completed_at
                 END
             WHERE capture_state IN ('recording', 'paused', 'draining')
                OR projection_state = 'projecting'
                OR async_projection_state = 'projecting'",
            [&now],
        )?;
        Ok(updated)
    }

    /// Converts one capture whose process owner has already been torn down
    /// into the same neutral `interrupted` state used by startup recovery.
    ///
    /// This is deliberately separate from [`Self::interrupt_capture`]: it
    /// does not persist the caller's requested interruption reason. It is a
    /// last-resort convergence path for an orchestration failure after the
    /// remote writer and in-memory owner are gone, so an unfinished row cannot
    /// keep the global capture slot wedged until the next app launch.
    pub fn recover_detached_unfinished_run(
        &self,
        run_id: &str,
    ) -> Result<NotebookCaptureRun, NotebookCaptureStoreError> {
        require_nonempty("run_id", run_id)?;
        let now = chrono::Utc::now().to_rfc3339();
        let updated = self.conn.lock().unwrap().execute(
            "UPDATE notebook_capture_runs
             SET capture_state = 'interrupted', remote_health = 'off',
                 projection_state = CASE
                     WHEN projection_state = 'projecting' THEN 'failed'
                     ELSE projection_state
                 END,
                 async_projection_state = CASE
                     WHEN async_projection_state = 'projecting' THEN 'failed'
                     ELSE async_projection_state
                 END,
                 updated_at = ?1, completed_at = COALESCE(completed_at, ?1)
             WHERE id = ?2 AND capture_state IN ('recording', 'paused', 'draining')",
            params![now, run_id],
        )?;
        let run = self.require_run(run_id)?;
        if updated == 0
            && matches!(
                run.capture_state,
                CaptureState::Recording | CaptureState::Paused | CaptureState::Draining
            )
        {
            return Err(NotebookCaptureStoreError::Conflict(format!(
                "run {run_id} remains an unfinished capture"
            )));
        }
        Ok(run)
    }

    pub fn get_or_create_profile(
        &self,
        notebook_id: &str,
    ) -> Result<NotebookCaptureProfile, NotebookCaptureStoreError> {
        require_nonempty("notebook_id", notebook_id)?;
        let now = chrono::Utc::now().to_rfc3339();
        let conn = self.conn.lock().unwrap();
        let exists = conn.query_row(
            "SELECT EXISTS(SELECT 1 FROM notebooks WHERE id = ?1 AND deleted_at IS NULL)",
            [notebook_id],
            |row| row.get::<_, bool>(0),
        )?;
        if !exists {
            return Err(NotebookCaptureStoreError::NotFound(format!(
                "notebook {notebook_id}"
            )));
        }
        conn.execute(
            "INSERT INTO notebook_capture_profiles
             (notebook_id, remote_realtime_enabled, capture_mode, language_a, language_b,
              left_language, right_language, selected_languages_json,
              common_caption_language, privacy_level,
              send_context_to_soniox, revision, created_at, updated_at)
             VALUES (?1, 0, 'transcription_only', 'en', 'zh', 'en', 'zh',
                     '[\"en\",\"zh\"]', NULL, 'standard', 0, 0, ?2, ?2)
             ON CONFLICT(notebook_id) DO NOTHING",
            params![notebook_id, now],
        )?;
        drop(conn);
        self.get_profile(notebook_id)?.ok_or_else(|| {
            NotebookCaptureStoreError::NotFound(format!("capture profile {notebook_id}"))
        })
    }

    pub fn get_profile(
        &self,
        notebook_id: &str,
    ) -> Result<Option<NotebookCaptureProfile>, NotebookCaptureStoreError> {
        self.conn
            .lock()
            .unwrap()
            .query_row(
                "SELECT notebook_id, remote_realtime_enabled, capture_mode, language_a,
                        language_b, left_language, right_language,
                        selected_languages_json, common_caption_language,
                        privacy_level, send_context_to_soniox, revision,
                        created_at, updated_at
                 FROM notebook_capture_profiles WHERE notebook_id = ?1",
                [notebook_id],
                profile_from_row,
            )
            .optional()
            .map_err(Into::into)
    }

    pub fn update_profile(
        &self,
        notebook_id: &str,
        expected_revision: u64,
        update: &NotebookCaptureProfileUpdate,
    ) -> Result<NotebookCaptureProfile, NotebookCaptureStoreError> {
        validate_profile_update(update)?;
        let selected_languages_json = serde_json::to_string(&update.selected_languages)?;
        let now = chrono::Utc::now().to_rfc3339();
        let updated = self.conn.lock().unwrap().execute(
            "UPDATE notebook_capture_profiles
             SET remote_realtime_enabled = ?1, capture_mode = ?2, language_a = ?3,
                 language_b = ?4, left_language = ?5, right_language = ?6,
                 selected_languages_json = ?7, common_caption_language = ?8,
                 privacy_level = ?9, send_context_to_soniox = ?10,
                 revision = revision + 1, updated_at = ?11
             WHERE notebook_id = ?12 AND revision = ?13",
            params![
                update.remote_realtime_enabled,
                update.capture_mode.as_str(),
                update.language_a,
                update.language_b,
                update.left_language,
                update.right_language,
                selected_languages_json,
                update.common_caption_language,
                update.privacy_level,
                update.send_context_to_soniox,
                now,
                notebook_id,
                u64_to_i64(expected_revision, "expected_revision")?,
            ],
        )?;
        if updated == 0 {
            return Err(NotebookCaptureStoreError::Conflict(format!(
                "profile {notebook_id} expected revision {expected_revision}"
            )));
        }
        self.get_profile(notebook_id)?.ok_or_else(|| {
            NotebookCaptureStoreError::NotFound(format!("capture profile {notebook_id}"))
        })
    }

    pub fn create_run(
        &self,
        input: &NewNotebookCaptureRun,
        profile_snapshot: &NotebookCaptureProfile,
    ) -> Result<NotebookCaptureRun, NotebookCaptureStoreError> {
        validate_new_run(input)?;
        validate_authorized_profile_snapshot(input, profile_snapshot)?;
        if !profile_snapshot.remote_realtime_enabled && input.remote_health != RemoteHealth::Off {
            return Err(NotebookCaptureStoreError::Validation(
                "remote health must be off when remote realtime processing is disabled".into(),
            ));
        }
        let profile_snapshot_json = serde_json::to_string(profile_snapshot)?;
        let selected_languages_json = serde_json::to_string(&profile_snapshot.selected_languages)?;
        let now = chrono::Utc::now().to_rfc3339();
        let mut conn = self.conn.lock().unwrap();
        // Acquire the writer lock before checking the authorization snapshot.
        // The conditional INSERT is the revision CAS: a concurrent profile
        // update can either commit before this transaction (and make the
        // INSERT affect zero rows) or after the run snapshot is committed.
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let inserted = tx.execute(
            "INSERT INTO notebook_capture_runs
             (id, notebook_id, session_id, profile_revision, profile_snapshot_json,
              capture_state, remote_health, projection_state, audio_journal_path,
              audio_key_ref, sample_rate, channels, captured_frames, created_at, updated_at,
              async_task_state)
             SELECT ?1, ?2, ?3, ?4, ?5, 'recording', ?6, 'pending', ?7, ?8, ?9, ?10,
                    0, ?11, ?11, 'none'
             FROM notebook_capture_profiles
             WHERE notebook_id = ?2 AND revision = ?4
               AND remote_realtime_enabled = ?12 AND capture_mode = ?13
               AND language_a = ?14 AND language_b = ?15
               AND left_language = ?16 AND right_language = ?17
               AND selected_languages_json = ?18
               AND common_caption_language IS ?19
               AND privacy_level = ?20
               AND send_context_to_soniox = ?21
               AND created_at = ?22 AND updated_at = ?23",
            params![
                input.id,
                input.notebook_id,
                input.session_id,
                u64_to_i64(profile_snapshot.revision, "profile_revision")?,
                profile_snapshot_json,
                input.remote_health.as_str(),
                input.audio_journal_path,
                input.audio_key_ref,
                input.sample_rate,
                input.channels,
                now,
                profile_snapshot.remote_realtime_enabled,
                profile_snapshot.capture_mode.as_str(),
                profile_snapshot.language_a,
                profile_snapshot.language_b,
                profile_snapshot.left_language,
                profile_snapshot.right_language,
                selected_languages_json,
                profile_snapshot.common_caption_language,
                profile_snapshot.privacy_level,
                profile_snapshot.send_context_to_soniox,
                profile_snapshot.created_at,
                profile_snapshot.updated_at,
            ],
        )?;
        if inserted == 0 {
            let profile_exists = tx.query_row(
                "SELECT EXISTS(
                    SELECT 1 FROM notebook_capture_profiles WHERE notebook_id = ?1
                 )",
                [&input.notebook_id],
                |row| row.get::<_, bool>(0),
            )?;
            return if profile_exists {
                Err(NotebookCaptureStoreError::Conflict(format!(
                    "profile {} expected authorized revision {}",
                    input.notebook_id, profile_snapshot.revision
                )))
            } else {
                Err(NotebookCaptureStoreError::NotFound(format!(
                    "capture profile {}",
                    input.notebook_id
                )))
            };
        }
        tx.commit()?;
        drop(conn);
        self.get_run(&input.id)?
            .ok_or_else(|| NotebookCaptureStoreError::NotFound(format!("capture run {}", input.id)))
    }

    /// Atomically creates the catalogue row, immutable privacy snapshot, and
    /// capture run that owns all deterministic external refs. No key or audio
    /// file should be created before this transaction commits.
    pub fn create_session_and_run(
        &self,
        session: &SessionRecord,
        input: &NewNotebookCaptureRun,
        profile_snapshot: &NotebookCaptureProfile,
    ) -> Result<NotebookCaptureRun, NotebookCaptureStoreError> {
        validate_new_run(input)?;
        validate_authorized_profile_snapshot(input, profile_snapshot)?;
        if session.id != input.session_id
            || session.session_type != "recording"
            || session.status != "recording"
            || session.duration_ms != 0
            || session.deleted_at.is_some()
        {
            return Err(NotebookCaptureStoreError::Validation(
                "capture catalogue row does not match a new recording session".into(),
            ));
        }
        if !profile_snapshot.remote_realtime_enabled && input.remote_health != RemoteHealth::Off {
            return Err(NotebookCaptureStoreError::Validation(
                "remote health must be off when remote realtime processing is disabled".into(),
            ));
        }
        let profile_snapshot_json = serde_json::to_string(profile_snapshot)?;
        let selected_languages_json = serde_json::to_string(&profile_snapshot.selected_languages)?;
        let now = chrono::Utc::now().to_rfc3339();
        let mut conn = self.conn.lock().unwrap();
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        tx.execute(
            "INSERT INTO session_records
             (id, title, session_type, status, duration_ms, created_at, deleted_at)
             VALUES (?1, ?2, 'recording', 'recording', 0, ?3, NULL)",
            params![session.id, session.title, session.created_at],
        )?;
        tx.execute(
            "INSERT INTO session_meta (session_id, privacy_level) VALUES (?1, ?2)",
            params![session.id, profile_snapshot.privacy_level],
        )?;
        let inserted = tx.execute(
            "INSERT INTO notebook_capture_runs
             (id, notebook_id, session_id, profile_revision, profile_snapshot_json,
              capture_state, remote_health, projection_state, audio_journal_path,
              audio_key_ref, sample_rate, channels, captured_frames, created_at, updated_at,
              async_task_state)
             SELECT ?1, ?2, ?3, ?4, ?5, 'recording', ?6, 'pending', ?7, ?8, ?9, ?10,
                    0, ?11, ?11, 'none'
             FROM notebook_capture_profiles
             WHERE notebook_id = ?2 AND revision = ?4
               AND remote_realtime_enabled = ?12 AND capture_mode = ?13
               AND language_a = ?14 AND language_b = ?15
               AND left_language = ?16 AND right_language = ?17
               AND selected_languages_json = ?18
               AND common_caption_language IS ?19
               AND privacy_level = ?20
               AND send_context_to_soniox = ?21
               AND created_at = ?22 AND updated_at = ?23",
            params![
                input.id,
                input.notebook_id,
                input.session_id,
                u64_to_i64(profile_snapshot.revision, "profile_revision")?,
                profile_snapshot_json,
                input.remote_health.as_str(),
                input.audio_journal_path,
                input.audio_key_ref,
                input.sample_rate,
                input.channels,
                now,
                profile_snapshot.remote_realtime_enabled,
                profile_snapshot.capture_mode.as_str(),
                profile_snapshot.language_a,
                profile_snapshot.language_b,
                profile_snapshot.left_language,
                profile_snapshot.right_language,
                selected_languages_json,
                profile_snapshot.common_caption_language,
                profile_snapshot.privacy_level,
                profile_snapshot.send_context_to_soniox,
                profile_snapshot.created_at,
                profile_snapshot.updated_at,
            ],
        )?;
        if inserted == 0 {
            let profile_exists = tx.query_row(
                "SELECT EXISTS(
                    SELECT 1 FROM notebook_capture_profiles WHERE notebook_id = ?1
                 )",
                [&input.notebook_id],
                |row| row.get::<_, bool>(0),
            )?;
            return if profile_exists {
                Err(NotebookCaptureStoreError::Conflict(format!(
                    "profile {} expected authorized revision {}",
                    input.notebook_id, profile_snapshot.revision
                )))
            } else {
                Err(NotebookCaptureStoreError::NotFound(format!(
                    "capture profile {}",
                    input.notebook_id
                )))
            };
        }
        tx.commit()?;
        drop(conn);
        self.get_run(&input.id)?
            .ok_or_else(|| NotebookCaptureStoreError::NotFound(format!("capture run {}", input.id)))
    }

    /// Inserts a finalized Notebook import without passing through an active
    /// recording state. The profile comparison is the same revision CAS used
    /// by live capture, so the durable async intent is exactly the setting the
    /// user authorized before import materialization began.
    pub fn create_completed_import_run(
        &self,
        input: &NewCompletedNotebookImportRun,
        profile_snapshot: &NotebookCaptureProfile,
    ) -> Result<NotebookCaptureRun, NotebookCaptureStoreError> {
        validate_completed_import_run(input)?;
        if profile_snapshot.notebook_id != input.notebook_id {
            return Err(NotebookCaptureStoreError::Validation(format!(
                "capture profile {} does not authorize notebook {}",
                profile_snapshot.notebook_id, input.notebook_id
            )));
        }
        validate_profile_update(&NotebookCaptureProfileUpdate {
            remote_realtime_enabled: profile_snapshot.remote_realtime_enabled,
            capture_mode: profile_snapshot.capture_mode,
            language_a: profile_snapshot.language_a.clone(),
            language_b: profile_snapshot.language_b.clone(),
            left_language: profile_snapshot.left_language.clone(),
            right_language: profile_snapshot.right_language.clone(),
            selected_languages: profile_snapshot.selected_languages.clone(),
            common_caption_language: profile_snapshot.common_caption_language.clone(),
            privacy_level: profile_snapshot.privacy_level.clone(),
            send_context_to_soniox: profile_snapshot.send_context_to_soniox,
        })?;
        require_nonempty("profile created_at", &profile_snapshot.created_at)?;
        require_nonempty("profile updated_at", &profile_snapshot.updated_at)?;

        let profile_snapshot_json = serde_json::to_string(profile_snapshot)?;
        let selected_languages_json = serde_json::to_string(&profile_snapshot.selected_languages)?;
        let now = chrono::Utc::now().to_rfc3339();
        let mut conn = self.conn.lock().unwrap();
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let inserted = tx.execute(
            "INSERT INTO notebook_capture_runs
             (id, notebook_id, session_id, profile_revision, profile_snapshot_json,
              capture_state, remote_health, projection_state, audio_path, audio_key_ref,
              sample_rate, channels, captured_frames, created_at, updated_at, completed_at,
              async_task_state)
             SELECT ?1, ?2, ?3, ?4, ?5, 'completed', 'off', 'ready', ?6, ?7, ?8, ?9,
                    ?10, ?11, ?11, ?11, 'none'
             FROM notebook_capture_profiles
             WHERE notebook_id = ?2 AND revision = ?4
               AND remote_realtime_enabled = ?12 AND capture_mode = ?13
               AND language_a = ?14 AND language_b = ?15
               AND left_language = ?16 AND right_language = ?17
               AND selected_languages_json = ?18
               AND common_caption_language IS ?19
               AND privacy_level = ?20
               AND send_context_to_soniox = ?21
               AND created_at = ?22 AND updated_at = ?23",
            params![
                input.id,
                input.notebook_id,
                input.session_id,
                u64_to_i64(profile_snapshot.revision, "profile_revision")?,
                profile_snapshot_json,
                input.audio_path,
                input.audio_key_ref,
                input.sample_rate,
                input.channels,
                u64_to_i64(input.captured_frames, "captured_frames")?,
                now,
                profile_snapshot.remote_realtime_enabled,
                profile_snapshot.capture_mode.as_str(),
                profile_snapshot.language_a,
                profile_snapshot.language_b,
                profile_snapshot.left_language,
                profile_snapshot.right_language,
                selected_languages_json,
                profile_snapshot.common_caption_language,
                profile_snapshot.privacy_level,
                profile_snapshot.send_context_to_soniox,
                profile_snapshot.created_at,
                profile_snapshot.updated_at,
            ],
        )?;
        if inserted == 0 {
            let profile_exists = tx.query_row(
                "SELECT EXISTS(
                    SELECT 1 FROM notebook_capture_profiles WHERE notebook_id = ?1
                 )",
                [&input.notebook_id],
                |row| row.get::<_, bool>(0),
            )?;
            return if profile_exists {
                Err(NotebookCaptureStoreError::Conflict(format!(
                    "profile {} expected authorized revision {}",
                    input.notebook_id, profile_snapshot.revision
                )))
            } else {
                Err(NotebookCaptureStoreError::NotFound(format!(
                    "capture profile {}",
                    input.notebook_id
                )))
            };
        }
        tx.commit()?;
        drop(conn);
        self.get_run(&input.id)?
            .ok_or_else(|| NotebookCaptureStoreError::NotFound(format!("capture run {}", input.id)))
    }

    pub fn get_run(
        &self,
        run_id: &str,
    ) -> Result<Option<NotebookCaptureRun>, NotebookCaptureStoreError> {
        self.conn
            .lock()
            .unwrap()
            .query_row(
                &format!("{RUN_SELECT} WHERE id = ?1"),
                [run_id],
                capture_run_from_row,
            )
            .optional()
            .map_err(Into::into)
    }

    pub fn get_run_for_session(
        &self,
        session_id: &str,
    ) -> Result<Option<NotebookCaptureRun>, NotebookCaptureStoreError> {
        self.conn
            .lock()
            .unwrap()
            .query_row(
                &format!("{RUN_SELECT} WHERE session_id = ?1"),
                [session_id],
                capture_run_from_row,
            )
            .optional()
            .map_err(Into::into)
    }

    /// Claims the immutable provider/model provenance for one remote role.
    ///
    /// The claim must commit before any provider client is constructed or any
    /// provider-derived fact is persisted. Repeating the exact claim is
    /// idempotent while the role is still legal for the run state; changing or
    /// clearing a committed claim is forbidden by both this API and SQLite.
    pub fn claim_provider_provenance(
        &self,
        session_id: &str,
        role: CaptureProviderRole,
        provider_id: &str,
        model_id: &str,
    ) -> Result<NotebookCaptureRun, NotebookCaptureStoreError> {
        require_nonempty("session_id", session_id)?;
        require_nonempty("provider_id", provider_id)?;
        require_nonempty("model_id", model_id)?;
        if provider_id != SONIOX_PROVIDER_ID || model_id != SONIOX_STT_RT_V5_MODEL_ID {
            return Err(NotebookCaptureStoreError::Validation(format!(
                "unsupported capture provider/model pair {provider_id}/{model_id}"
            )));
        }

        let mut conn = self.conn.lock().unwrap();
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let run = tx
            .query_row(
                &format!("{RUN_SELECT} WHERE session_id = ?1"),
                [session_id],
                capture_run_from_row,
            )
            .optional()?
            .ok_or_else(|| {
                NotebookCaptureStoreError::NotFound(format!("capture session {session_id}"))
            })?;
        if session_purge_job_exists(&tx, session_id)? {
            return Err(NotebookCaptureStoreError::Conflict(format!(
                "session {session_id} is pending permanent deletion"
            )));
        }

        let (current_provider, current_model, state_is_eligible) = match role {
            CaptureProviderRole::Realtime => (
                run.realtime_provider_id.as_deref(),
                run.realtime_model_id.as_deref(),
                run.capture_state.is_active(),
            ),
            CaptureProviderRole::PostStop => (
                run.post_stop_provider_id.as_deref(),
                run.post_stop_model_id.as_deref(),
                run.capture_state == CaptureState::Completed,
            ),
        };
        if !state_is_eligible {
            return Err(NotebookCaptureStoreError::Conflict(format!(
                "session {session_id} cannot claim {role:?} provider provenance while capture is {}",
                run.capture_state.as_str()
            )));
        }
        match (current_provider, current_model) {
            (Some(current_provider), Some(current_model))
                if current_provider == provider_id && current_model == model_id =>
            {
                tx.commit()?;
                return Ok(run);
            }
            (Some(_), Some(_)) => {
                return Err(NotebookCaptureStoreError::Conflict(format!(
                    "session {session_id} already claimed different {role:?} provider provenance"
                )));
            }
            (Some(_), None) | (None, Some(_)) => {
                return Err(NotebookCaptureStoreError::CorruptData(format!(
                    "session {session_id} has partial {role:?} provider provenance"
                )));
            }
            (None, None) => {}
        }

        let now = chrono::Utc::now().to_rfc3339();
        let updated = match role {
            CaptureProviderRole::Realtime => tx.execute(
                "UPDATE notebook_capture_runs
                 SET realtime_provider_id = ?1, realtime_model_id = ?2, updated_at = ?3
                 WHERE session_id = ?4
                   AND capture_state IN ('recording', 'paused', 'draining')
                   AND realtime_provider_id IS NULL AND realtime_model_id IS NULL",
                params![provider_id, model_id, now, session_id],
            )?,
            CaptureProviderRole::PostStop => tx.execute(
                "UPDATE notebook_capture_runs
                 SET post_stop_provider_id = ?1, post_stop_model_id = ?2, updated_at = ?3
                 WHERE session_id = ?4 AND capture_state = 'completed'
                   AND post_stop_provider_id IS NULL AND post_stop_model_id IS NULL",
                params![provider_id, model_id, now, session_id],
            )?,
        };
        if updated == 0 {
            return Err(NotebookCaptureStoreError::Conflict(format!(
                "session {session_id} {role:?} provider provenance claim raced with another writer"
            )));
        }
        let claimed = tx.query_row(
            &format!("{RUN_SELECT} WHERE session_id = ?1"),
            [session_id],
            capture_run_from_row,
        )?;
        tx.commit()?;
        Ok(claimed)
    }

    pub fn get_active_run(&self) -> Result<Option<NotebookCaptureRun>, NotebookCaptureStoreError> {
        self.conn
            .lock()
            .unwrap()
            .query_row(
                &format!(
                    "{RUN_SELECT} WHERE capture_state IN ('recording', 'paused', 'draining') LIMIT 1"
                ),
                [],
                capture_run_from_row,
            )
            .optional()
            .map_err(Into::into)
    }

    pub fn list_interrupted_runs(
        &self,
    ) -> Result<Vec<NotebookCaptureRun>, NotebookCaptureStoreError> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(&format!(
            "{RUN_SELECT} WHERE capture_state = 'interrupted' ORDER BY updated_at ASC, id ASC"
        ))?;
        let rows = stmt.query_map([], capture_run_from_row)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
    }

    /// Completed captures are replay candidates for explicit post-stop
    /// compensation (for example, restoring a missing async task after a
    /// process crash). The store does not infer or enqueue any remote work.
    pub fn list_completed_runs(
        &self,
    ) -> Result<Vec<NotebookCaptureRun>, NotebookCaptureStoreError> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(&format!(
            "{RUN_SELECT} WHERE capture_state = 'completed'
             ORDER BY COALESCE(completed_at, updated_at) ASC, id ASC"
        ))?;
        let rows = stmt.query_map([], capture_run_from_row)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
    }

    /// Startup compensation only needs completed runs whose durable async
    /// receipt has not reached a terminal state. Filtering in SQLite avoids
    /// decoding every historical capture profile on every app launch.
    pub fn list_completed_runs_requiring_async_compensation(
        &self,
    ) -> Result<Vec<NotebookCaptureRun>, NotebookCaptureStoreError> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(&format!(
            "{RUN_SELECT} WHERE capture_state = 'completed'
             AND async_task_state IN ('pending', 'reserved', 'enqueued')
             ORDER BY COALESCE(completed_at, updated_at) ASC, id ASC"
        ))?;
        let rows = stmt.query_map([], capture_run_from_row)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
    }

    /// Freezes one explicit post-recording transcription authorization.
    ///
    /// The first command performs the `none -> pending` CAS. Repeated clicks,
    /// callback retries, and reopen recovery return the already-authorized run
    /// without changing its timestamp or language hint. Provider failures are
    /// terminal; this method never turns `failed` back into `pending`.
    pub fn authorize_async_transcription(
        &self,
        session_id: &str,
        authorized_at_ms: i64,
        language_hint: Option<&str>,
    ) -> Result<NotebookCaptureRun, NotebookCaptureStoreError> {
        require_nonempty("session_id", session_id)?;
        if authorized_at_ms <= 0 {
            return Err(NotebookCaptureStoreError::Validation(
                "async authorization time must be positive".into(),
            ));
        }
        let language_hint = language_hint
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(str::to_string);
        if let Some(language) = language_hint.as_deref() {
            validate_language(language)?;
        }

        let mut conn = self.conn.lock().unwrap();
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let run = tx
            .query_row(
                &format!("{RUN_SELECT} WHERE session_id = ?1"),
                [session_id],
                capture_run_from_row,
            )
            .optional()?
            .ok_or_else(|| {
                NotebookCaptureStoreError::NotFound(format!("capture session {session_id}"))
            })?;
        if session_purge_job_exists(&tx, session_id)? {
            return Err(NotebookCaptureStoreError::Conflict(format!(
                "session {session_id} is pending permanent deletion"
            )));
        }
        if run.async_task_state != AsyncTaskState::None {
            tx.commit()?;
            return Ok(run);
        }
        if run.capture_state != CaptureState::Completed {
            return Err(NotebookCaptureStoreError::Conflict(format!(
                "session {session_id} must be completed before async transcription"
            )));
        }
        let has_retained_audio: bool = tx.query_row(
            "SELECT CASE
                 WHEN EXISTS (
                     SELECT 1 FROM audio_retention_chunks
                     WHERE session_id = ?1
                 ) THEN EXISTS (
                     SELECT 1 FROM audio_retention_chunks
                     WHERE session_id = ?1 AND deleted = 0
                 )
                 ELSE EXISTS (
                     SELECT 1 FROM notebook_capture_runs
                     WHERE session_id = ?1 AND audio_path IS NOT NULL
                       AND audio_key_ref IS NOT NULL
                 )
             END",
            [session_id],
            |row| row.get(0),
        )?;
        if !has_retained_audio {
            return Err(NotebookCaptureStoreError::Conflict(format!(
                "session {session_id} has no retained audio to transcribe"
            )));
        }

        let now = chrono::Utc::now().to_rfc3339();
        let updated = tx.execute(
            "UPDATE notebook_capture_runs
             SET async_task_state = 'pending', async_authorized_at_ms = ?1,
                 async_language_hint = ?2, updated_at = ?3
             WHERE session_id = ?4 AND capture_state = 'completed'
               AND async_task_state = 'none'
               AND async_authorized_at_ms IS NULL
               AND async_language_hint IS NULL
               AND async_task_id IS NULL
               AND async_task_payload_sha256 IS NULL",
            params![authorized_at_ms, language_hint, now, session_id],
        )?;
        if updated == 0 {
            let raced = tx.query_row(
                &format!("{RUN_SELECT} WHERE session_id = ?1"),
                [session_id],
                capture_run_from_row,
            )?;
            if raced.async_task_state != AsyncTaskState::None {
                tx.commit()?;
                return Ok(raced);
            }
            return Err(NotebookCaptureStoreError::Conflict(format!(
                "session {session_id} async authorization raced with another writer"
            )));
        }
        let authorized = tx.query_row(
            &format!("{RUN_SELECT} WHERE session_id = ?1"),
            [session_id],
            capture_run_from_row,
        )?;
        tx.commit()?;
        Ok(authorized)
    }

    /// Clears durable capture references only after the retention ledger and
    /// session metadata have confirmed local audio destruction. Transcript
    /// facts and capture chronology remain intact and rebuildable.
    pub fn clear_retained_audio_references(
        &self,
        session_id: &str,
    ) -> Result<NotebookCaptureRun, NotebookCaptureStoreError> {
        require_nonempty("session_id", session_id)?;
        let now = chrono::Utc::now().to_rfc3339();
        let updated = self.conn.lock().unwrap().execute(
            "UPDATE notebook_capture_runs
             SET audio_path = NULL, audio_key_ref = NULL, updated_at = ?1
             WHERE session_id = ?2",
            params![now, session_id],
        )?;
        if updated == 0 {
            return Err(NotebookCaptureStoreError::NotFound(format!(
                "capture session {session_id}"
            )));
        }
        self.get_run_for_session(session_id)?.ok_or_else(|| {
            NotebookCaptureStoreError::NotFound(format!("capture session {session_id}"))
        })
    }

    /// Reserve a deterministic TaskQueue identity before touching `tasks.db`.
    /// A reserved receipt is intentionally never reset on reopen: if the task
    /// database write is lost, recovery must fail closed rather than upload the
    /// same local audio under a newly-guessed task identity.
    pub fn reserve_async_task(
        &self,
        run_id: &str,
        stable_task_id: &str,
        payload_sha256: &str,
    ) -> Result<NotebookCaptureRun, NotebookCaptureStoreError> {
        require_nonempty("run_id", run_id)?;
        require_nonempty("stable_task_id", stable_task_id)?;
        validate_sha256_hex("async task payload digest", payload_sha256)?;

        let mut conn = self.conn.lock().unwrap();
        let tx = conn.transaction()?;
        let run = tx
            .query_row(
                &format!("{RUN_SELECT} WHERE id = ?1"),
                [run_id],
                capture_run_from_row,
            )
            .optional()?
            .ok_or_else(|| NotebookCaptureStoreError::NotFound(format!("capture run {run_id}")))?;
        if session_purge_job_exists(&tx, &run.session_id)? {
            return Err(NotebookCaptureStoreError::Conflict(format!(
                "session {} is pending permanent deletion",
                run.session_id
            )));
        }
        if run.capture_state != CaptureState::Completed {
            return Err(NotebookCaptureStoreError::Conflict(format!(
                "run {run_id} must be completed before reserving async transcription"
            )));
        }

        match run.async_task_state {
            AsyncTaskState::Pending => {}
            AsyncTaskState::Reserved
                if run.async_task_id.as_deref() == Some(stable_task_id)
                    && run.async_task_payload_sha256.as_deref() == Some(payload_sha256) =>
            {
                tx.commit()?;
                return Ok(run);
            }
            _ => {
                return Err(NotebookCaptureStoreError::Conflict(format!(
                    "run {run_id} async task is {}",
                    run.async_task_state.as_str()
                )));
            }
        }

        let now = chrono::Utc::now().to_rfc3339();
        let updated = tx.execute(
            "UPDATE notebook_capture_runs
             SET async_task_state = 'reserved', async_task_id = ?1,
                 async_task_payload_sha256 = ?2, updated_at = ?3
             WHERE id = ?4 AND capture_state = 'completed'
               AND async_task_state = 'pending'
               AND async_task_id IS NULL AND async_task_payload_sha256 IS NULL",
            params![stable_task_id, payload_sha256, now, run_id],
        )?;
        if updated == 0 {
            return Err(NotebookCaptureStoreError::Conflict(format!(
                "run {run_id} async task reservation raced with another writer"
            )));
        }
        let reserved = tx.query_row(
            &format!("{RUN_SELECT} WHERE id = ?1"),
            [run_id],
            capture_run_from_row,
        )?;
        tx.commit()?;
        Ok(reserved)
    }

    /// Record that the deterministic task row now exists in `tasks.db`.
    /// Repeating the same receipt is idempotent; a different task identity is
    /// always a conflict.
    pub fn mark_async_task_enqueued(
        &self,
        run_id: &str,
        task_id: &str,
    ) -> Result<NotebookCaptureRun, NotebookCaptureStoreError> {
        require_nonempty("run_id", run_id)?;
        require_nonempty("task_id", task_id)?;

        let mut conn = self.conn.lock().unwrap();
        let tx = conn.transaction()?;
        let run = tx
            .query_row(
                &format!("{RUN_SELECT} WHERE id = ?1"),
                [run_id],
                capture_run_from_row,
            )
            .optional()?
            .ok_or_else(|| NotebookCaptureStoreError::NotFound(format!("capture run {run_id}")))?;
        if session_purge_job_exists(&tx, &run.session_id)? {
            return Err(NotebookCaptureStoreError::Conflict(format!(
                "session {} is pending permanent deletion",
                run.session_id
            )));
        }

        match run.async_task_state {
            AsyncTaskState::Reserved
                if run.async_task_id.as_deref() == Some(task_id)
                    && run.async_task_payload_sha256.is_some() => {}
            AsyncTaskState::Enqueued if run.async_task_id.as_deref() == Some(task_id) => {
                tx.commit()?;
                return Ok(run);
            }
            _ => {
                return Err(NotebookCaptureStoreError::Conflict(format!(
                    "run {run_id} has no matching reserved async task"
                )));
            }
        }

        let now = chrono::Utc::now().to_rfc3339();
        let updated = tx.execute(
            "UPDATE notebook_capture_runs
             SET async_task_state = 'enqueued', updated_at = ?1
             WHERE id = ?2 AND async_task_state = 'reserved' AND async_task_id = ?3
               AND async_task_payload_sha256 IS NOT NULL",
            params![now, run_id, task_id],
        )?;
        if updated == 0 {
            return Err(NotebookCaptureStoreError::Conflict(format!(
                "run {run_id} async task enqueue receipt raced with another writer"
            )));
        }
        let enqueued = tx.query_row(
            &format!("{RUN_SELECT} WHERE id = ?1"),
            [run_id],
            capture_run_from_row,
        )?;
        tx.commit()?;
        Ok(enqueued)
    }

    /// Atomically commits the authoritative provider tokens and an immutable
    /// success receipt in the main database. A crash after this transaction
    /// may leave tasks.db Running/Pending, but the exact stable task can be
    /// completed from this receipt without another provider request.
    pub fn commit_async_provider_success(
        &self,
        session_id: &str,
        task_id: &str,
        tokens: &[Token],
        result_json: &str,
    ) -> Result<AsyncProviderReceipt, NotebookCaptureStoreError> {
        self.commit_async_provider_success_with_hook(
            session_id,
            task_id,
            tokens,
            result_json,
            || Ok(()),
        )
    }

    fn commit_async_provider_success_with_hook<F>(
        &self,
        session_id: &str,
        task_id: &str,
        tokens: &[Token],
        result_json: &str,
        before_receipt_update: F,
    ) -> Result<AsyncProviderReceipt, NotebookCaptureStoreError>
    where
        F: FnOnce() -> Result<(), NotebookCaptureStoreError>,
    {
        require_nonempty("session_id", session_id)?;
        require_nonempty("task_id", task_id)?;
        let tokens_json = serde_json::to_string(tokens)?;
        validate_provider_result_shape(session_id, tokens.len(), result_json)
            .map_err(NotebookCaptureStoreError::Validation)?;

        let mut conn = self.conn.lock().unwrap();
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let (task_state, recorded_task_id, provider_id, model_id) = tx
            .query_row(
                "SELECT async_task_state, async_task_id,
                        post_stop_provider_id, post_stop_model_id
                 FROM notebook_capture_runs WHERE session_id = ?1",
                [session_id],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, Option<String>>(1)?,
                        row.get::<_, Option<String>>(2)?,
                        row.get::<_, Option<String>>(3)?,
                    ))
                },
            )
            .optional()?
            .ok_or_else(|| {
                NotebookCaptureStoreError::NotFound(format!("capture session {session_id}"))
            })?;
        if session_purge_job_exists(&tx, session_id)? {
            return Err(NotebookCaptureStoreError::Conflict(format!(
                "session {session_id} is pending permanent deletion"
            )));
        }
        if recorded_task_id.as_deref() != Some(task_id) {
            return Err(NotebookCaptureStoreError::Conflict(format!(
                "session {session_id} provider result does not match its stable async task"
            )));
        }
        let (provider_id, model_id) = match (provider_id, model_id) {
            (Some(provider_id), Some(model_id))
                if provider_id == SONIOX_PROVIDER_ID && model_id == SONIOX_STT_RT_V5_MODEL_ID =>
            {
                (provider_id, model_id)
            }
            (None, None) => {
                return Err(NotebookCaptureStoreError::Conflict(format!(
                    "session {session_id} has no claimed post-stop provider provenance"
                )));
            }
            (Some(_), Some(_)) => {
                return Err(NotebookCaptureStoreError::CorruptData(format!(
                    "session {session_id} has unsupported post-stop provider provenance"
                )));
            }
            _ => {
                return Err(NotebookCaptureStoreError::CorruptData(format!(
                    "session {session_id} has partial post-stop provider provenance"
                )));
            }
        };
        let output_sha256 = async_provider_output_digest(
            session_id,
            task_id,
            &provider_id,
            &model_id,
            &tokens_json,
            result_json,
        );

        if let Some(existing) = get_async_provider_receipt_from_conn(&tx, session_id)? {
            if existing.task_id != task_id
                || existing.provider_id != provider_id
                || existing.model_id != model_id
                || existing.output_sha256 != output_sha256
                || existing.result_json != result_json
            {
                return Err(NotebookCaptureStoreError::Conflict(format!(
                    "session {session_id} already has a different provider success receipt"
                )));
            }
            let stored_tokens: Option<String> = tx
                .query_row(
                    "SELECT tokens_json FROM session_meta WHERE session_id = ?1",
                    [session_id],
                    |row| row.get(0),
                )
                .optional()?
                .flatten();
            if stored_tokens.as_deref() != Some(tokens_json.as_str()) {
                return Err(NotebookCaptureStoreError::CorruptData(format!(
                    "session {session_id} provider receipt is not paired with its authoritative tokens"
                )));
            }
            tx.commit()?;
            return Ok(existing);
        }

        if task_state != AsyncTaskState::Enqueued.as_str() {
            return Err(NotebookCaptureStoreError::Conflict(format!(
                "session {session_id} async task is {task_state}, expected enqueued"
            )));
        }

        tx.execute(
            "INSERT INTO session_meta (session_id, tokens_json)
             VALUES (?1, ?2)
             ON CONFLICT(session_id) DO UPDATE SET tokens_json = excluded.tokens_json",
            params![session_id, tokens_json],
        )?;
        before_receipt_update()?;
        let now = chrono::Utc::now().to_rfc3339();
        let updated = tx.execute(
            "UPDATE notebook_capture_runs
             SET async_provider_output_sha256 = ?1,
                 async_provider_result_json = ?2,
                 async_provider_completed_at = ?3,
                 async_search_projection_state = 'pending',
                 updated_at = ?3
             WHERE session_id = ?4 AND async_task_state = 'enqueued'
               AND async_task_id = ?5 AND async_provider_output_sha256 IS NULL",
            params![output_sha256, result_json, now, session_id, task_id],
        )?;
        if updated == 0 {
            return Err(NotebookCaptureStoreError::Conflict(format!(
                "session {session_id} provider success receipt raced with another writer"
            )));
        }
        let receipt = get_async_provider_receipt_from_conn(&tx, session_id)?.ok_or_else(|| {
            NotebookCaptureStoreError::CorruptData(format!(
                "session {session_id} provider success receipt disappeared"
            ))
        })?;
        tx.commit()?;
        Ok(receipt)
    }

    pub fn get_async_provider_receipt(
        &self,
        session_id: &str,
        task_id: &str,
    ) -> Result<Option<AsyncProviderReceipt>, NotebookCaptureStoreError> {
        require_nonempty("session_id", session_id)?;
        require_nonempty("task_id", task_id)?;
        let receipt = get_async_provider_receipt_from_conn(&self.conn.lock().unwrap(), session_id)?;
        if receipt
            .as_ref()
            .is_some_and(|receipt| receipt.task_id != task_id)
        {
            return Err(NotebookCaptureStoreError::Conflict(format!(
                "session {session_id} provider receipt belongs to another async task"
            )));
        }
        Ok(receipt)
    }

    pub fn list_async_search_projections_requiring_retry(
        &self,
    ) -> Result<AsyncProviderReceiptScan, NotebookCaptureStoreError> {
        let conn = self.conn.lock().unwrap();
        scan_async_provider_receipts(
            &conn,
            "SELECT r.session_id, r.async_task_id,
                    r.post_stop_provider_id, r.post_stop_model_id,
                    r.async_provider_output_sha256, r.async_provider_result_json,
                    r.async_search_projection_state, r.async_provider_completed_at,
                    m.tokens_json
             FROM notebook_capture_runs r
             LEFT JOIN session_meta m ON m.session_id = r.session_id
             WHERE r.async_provider_output_sha256 IS NOT NULL
               AND r.async_search_projection_state IN ('pending', 'failed')
               AND NOT (
                   r.async_search_projection_state = 'failed'
                   AND r.async_task_id IS NULL
               )
               AND NOT EXISTS (
                   SELECT 1 FROM session_purge_jobs p WHERE p.session_id = r.session_id
               )
             ORDER BY r.async_provider_completed_at ASC, r.session_id ASC",
        )
    }

    pub fn list_async_provider_receipts(
        &self,
    ) -> Result<AsyncProviderReceiptScan, NotebookCaptureStoreError> {
        let conn = self.conn.lock().unwrap();
        scan_async_provider_receipts(
            &conn,
            "SELECT r.session_id, r.async_task_id,
                    r.post_stop_provider_id, r.post_stop_model_id,
                    r.async_provider_output_sha256, r.async_provider_result_json,
                    r.async_search_projection_state, r.async_provider_completed_at,
                    m.tokens_json
             FROM notebook_capture_runs r
             LEFT JOIN session_meta m ON m.session_id = r.session_id
             WHERE r.async_provider_output_sha256 IS NOT NULL
               AND r.async_task_state IN ('reserved', 'enqueued')
               AND NOT (
                   r.async_search_projection_state = 'failed'
                   AND r.async_task_id IS NULL
               )
               AND NOT EXISTS (
                   SELECT 1 FROM session_purge_jobs p WHERE p.session_id = r.session_id
               )
             ORDER BY r.async_provider_completed_at ASC, r.session_id ASC",
        )
    }

    /// Records only the disposable local search projection as failed. This
    /// deliberately does not consume, delete, or reinterpret a corrupt provider
    /// receipt; the worker separately fail-closes the exact scheduler task so it
    /// can never be re-uploaded.
    pub fn fail_corrupt_async_search_projection(
        &self,
        session_id: &str,
        task_id: Option<&str>,
    ) -> Result<(), NotebookCaptureStoreError> {
        require_nonempty("session_id", session_id)?;
        let now = chrono::Utc::now().to_rfc3339();
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "UPDATE notebook_capture_runs
             SET async_search_projection_state = 'failed', updated_at = ?1
             WHERE session_id = ?2
               AND async_provider_output_sha256 IS NOT NULL
               AND async_search_projection_state IN ('pending', 'failed')
               AND (?3 IS NULL OR async_task_id = ?3)",
            params![now, session_id, task_id],
        )?;
        Ok(())
    }

    pub fn mark_async_search_projection(
        &self,
        session_id: &str,
        task_id: &str,
        success: bool,
    ) -> Result<AsyncProviderReceipt, NotebookCaptureStoreError> {
        require_nonempty("session_id", session_id)?;
        require_nonempty("task_id", task_id)?;
        let desired = if success {
            AsyncSearchProjectionState::Ready
        } else {
            AsyncSearchProjectionState::Failed
        };
        let mut conn = self.conn.lock().unwrap();
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        if session_purge_job_exists(&tx, session_id)? {
            return Err(NotebookCaptureStoreError::Conflict(format!(
                "session {session_id} is pending permanent deletion"
            )));
        }
        let current = get_async_provider_receipt_from_conn(&tx, session_id)?.ok_or_else(|| {
            NotebookCaptureStoreError::NotFound(format!(
                "provider success receipt for session {session_id}"
            ))
        })?;
        if current.task_id != task_id {
            return Err(NotebookCaptureStoreError::Conflict(format!(
                "session {session_id} provider receipt belongs to another async task"
            )));
        }
        if current.search_projection_state == desired {
            tx.commit()?;
            return Ok(current);
        }
        if !matches!(
            current.search_projection_state,
            AsyncSearchProjectionState::Pending | AsyncSearchProjectionState::Failed
        ) {
            return Err(NotebookCaptureStoreError::Conflict(format!(
                "session {session_id} search projection is {}",
                current.search_projection_state.as_str()
            )));
        }
        let now = chrono::Utc::now().to_rfc3339();
        let updated = tx.execute(
            "UPDATE notebook_capture_runs
             SET async_search_projection_state = ?1, updated_at = ?2
             WHERE session_id = ?3 AND async_task_id = ?4
               AND async_provider_output_sha256 IS NOT NULL
               AND async_search_projection_state IN ('pending', 'failed')",
            params![desired.as_str(), now, session_id, task_id],
        )?;
        if updated == 0 {
            return Err(NotebookCaptureStoreError::Conflict(format!(
                "session {session_id} search projection raced with another writer"
            )));
        }
        let receipt = get_async_provider_receipt_from_conn(&tx, session_id)?.ok_or_else(|| {
            NotebookCaptureStoreError::CorruptData(format!(
                "session {session_id} provider receipt disappeared after search projection"
            ))
        })?;
        tx.commit()?;
        Ok(receipt)
    }

    /// Close the durable receipt after TaskQueue reports a terminal outcome.
    /// Task ID matching prevents an obsolete callback from completing a newer
    /// task associated with the same session.
    ///
    /// Startup recovery may also fail-close an exact `Reserved` receipt when
    /// its tasks.db row is missing or corrupt. SQLite sees the two legal state
    /// transitions (`Reserved -> Enqueued -> Failed`) inside this one
    /// transaction, while other connections can observe only the committed
    /// `Failed` state. Successful completion still requires a previously
    /// visible `Enqueued` receipt.
    pub fn mark_async_task_terminal_for_session(
        &self,
        session_id: &str,
        task_id: &str,
        success: bool,
    ) -> Result<NotebookCaptureRun, NotebookCaptureStoreError> {
        require_nonempty("session_id", session_id)?;
        require_nonempty("task_id", task_id)?;
        let desired = if success {
            AsyncTaskState::Completed
        } else {
            AsyncTaskState::Failed
        };

        let mut conn = self.conn.lock().unwrap();
        let tx = conn.transaction()?;
        let run = tx
            .query_row(
                &format!("{RUN_SELECT} WHERE session_id = ?1"),
                [session_id],
                capture_run_from_row,
            )
            .optional()?
            .ok_or_else(|| {
                NotebookCaptureStoreError::NotFound(format!("capture session {session_id}"))
            })?;
        if session_purge_job_exists(&tx, session_id)? {
            return Err(NotebookCaptureStoreError::Conflict(format!(
                "session {session_id} is pending permanent deletion"
            )));
        }

        if run.async_task_state == desired && run.async_task_id.as_deref() == Some(task_id) {
            tx.commit()?;
            return Ok(run);
        }
        let exact_reserved_failure = !success
            && run.async_task_state == AsyncTaskState::Reserved
            && run.async_task_id.as_deref() == Some(task_id)
            && run.async_task_payload_sha256.is_some();
        let exact_enqueued = run.async_task_state == AsyncTaskState::Enqueued
            && run.async_task_id.as_deref() == Some(task_id)
            && run.async_task_payload_sha256.is_some();
        if !exact_reserved_failure && !exact_enqueued {
            return Err(NotebookCaptureStoreError::Conflict(format!(
                "session {session_id} has no matching enqueued async task"
            )));
        }

        if exact_reserved_failure {
            let now = chrono::Utc::now().to_rfc3339();
            let promoted = tx.execute(
                "UPDATE notebook_capture_runs
                 SET async_task_state = 'enqueued', updated_at = ?1
                 WHERE session_id = ?2 AND async_task_state = 'reserved'
                   AND async_task_id = ?3 AND async_task_payload_sha256 IS NOT NULL",
                params![now, session_id, task_id],
            )?;
            if promoted == 0 {
                return Err(NotebookCaptureStoreError::Conflict(format!(
                    "session {session_id} reserved async task failure raced with another writer"
                )));
            }
        }

        let now = chrono::Utc::now().to_rfc3339();
        let updated = tx.execute(
            "UPDATE notebook_capture_runs
             SET async_task_state = ?1,
                 async_projection_state = CASE
                     WHEN ?1 = 'completed' THEN 'pending'
                     ELSE async_projection_state
                 END,
                 updated_at = ?2
             WHERE session_id = ?3 AND async_task_state = 'enqueued'
               AND async_task_id = ?4 AND async_task_payload_sha256 IS NOT NULL",
            params![desired.as_str(), now, session_id, task_id],
        )?;
        if updated == 0 {
            return Err(NotebookCaptureStoreError::Conflict(format!(
                "session {session_id} async task terminal receipt raced with another writer"
            )));
        }
        let terminal = tx.query_row(
            &format!("{RUN_SELECT} WHERE session_id = ?1"),
            [session_id],
            capture_run_from_row,
        )?;
        tx.commit()?;
        Ok(terminal)
    }

    pub fn transition_capture(
        &self,
        run_id: &str,
        expected: CaptureState,
        next: CaptureState,
    ) -> Result<NotebookCaptureRun, NotebookCaptureStoreError> {
        if !valid_capture_transition(expected, next) {
            return Err(NotebookCaptureStoreError::Validation(format!(
                "invalid capture transition {} -> {}",
                expected.as_str(),
                next.as_str()
            )));
        }
        let now = chrono::Utc::now().to_rfc3339();
        let completed_at = next.is_terminal().then_some(now.as_str());
        let remote_health = next.is_terminal().then_some(RemoteHealth::Off.as_str());
        let updated = self.conn.lock().unwrap().execute(
            "UPDATE notebook_capture_runs
             SET capture_state = ?1, updated_at = ?2,
                 completed_at = COALESCE(?3, completed_at),
                 remote_health = COALESCE(?4, remote_health)
             WHERE id = ?5 AND capture_state = ?6",
            params![
                next.as_str(),
                now,
                completed_at,
                remote_health,
                run_id,
                expected.as_str()
            ],
        )?;
        if updated == 0 {
            return Err(NotebookCaptureStoreError::Conflict(format!(
                "run {run_id} is not {}",
                expected.as_str()
            )));
        }
        self.require_run(run_id)
    }

    /// Atomically terminates a still-active capture after a local audio-path
    /// failure. Any post-stop async intent that has not been enqueued is
    /// abandoned in the same transaction. A reserved/enqueued task or a
    /// projecting/ready document is impossible for an active run and fails
    /// closed instead of producing a partial interruption state.
    pub fn interrupt_capture(
        &self,
        run_id: &str,
        expected: CaptureState,
        failure: &ProviderFailure,
    ) -> Result<NotebookCaptureRun, NotebookCaptureStoreError> {
        if !matches!(expected, CaptureState::Recording | CaptureState::Paused) {
            return Err(NotebookCaptureStoreError::Validation(format!(
                "capture interruption requires recording or paused, found {}",
                expected.as_str()
            )));
        }
        if !matches!(
            failure.error_type.as_str(),
            "local_audio_overflow" | "local_audio_unavailable" | "local_persistence"
        ) {
            return Err(NotebookCaptureStoreError::Validation(
                "capture interruption failure type is not permitted".into(),
            ));
        }
        let now = chrono::Utc::now().to_rfc3339();
        let updated = self.conn.lock().unwrap().execute(
            "UPDATE notebook_capture_runs
             SET capture_state = 'interrupted', remote_health = 'off',
                 provider_error_type = ?1, provider_request_id = ?2,
                 async_task_state = 'none',
                 async_task_id = NULL, async_task_payload_sha256 = NULL,
                 updated_at = ?3, completed_at = ?3
             WHERE id = ?4 AND capture_state = ?5
               AND async_task_state IN ('none', 'pending')
               AND projection_state IN ('pending', 'failed')",
            params![
                failure.error_type,
                failure.request_id,
                now,
                run_id,
                expected.as_str(),
            ],
        )?;
        if updated == 0 {
            return Err(NotebookCaptureStoreError::Conflict(format!(
                "run {run_id} cannot be atomically interrupted from {}",
                expected.as_str()
            )));
        }
        self.require_run(run_id)
    }

    /// Atomically records a local durability failure from any capture state
    /// that still owns uncommitted local audio. Only an unmaterialized
    /// `pending` async intent is abandoned. Reserved/enqueued receipts are
    /// preserved verbatim so already materialized work can never be silently
    /// rolled back by capture cleanup.
    pub fn interrupt_local_persistence(
        &self,
        run_id: &str,
        expected: CaptureState,
        failure: &ProviderFailure,
    ) -> Result<NotebookCaptureRun, NotebookCaptureStoreError> {
        if !matches!(
            expected,
            CaptureState::Recording | CaptureState::Paused | CaptureState::Draining
        ) {
            return Err(NotebookCaptureStoreError::Validation(format!(
                "local persistence interruption requires recording, paused, or draining; found {}",
                expected.as_str()
            )));
        }
        if failure.error_type != "local_persistence" {
            return Err(NotebookCaptureStoreError::Validation(
                "local persistence interruption requires local_persistence failure".into(),
            ));
        }
        let now = chrono::Utc::now().to_rfc3339();
        let updated = self.conn.lock().unwrap().execute(
            "UPDATE notebook_capture_runs
             SET capture_state = 'interrupted', remote_health = 'off',
                 provider_error_type = ?1, provider_request_id = ?2,
                 async_task_state = CASE
                     WHEN async_task_state = 'pending' THEN 'none'
                     ELSE async_task_state
                 END,
                 async_task_id = CASE
                     WHEN async_task_state = 'pending' THEN NULL
                     ELSE async_task_id
                 END,
                 async_task_payload_sha256 = CASE
                     WHEN async_task_state = 'pending' THEN NULL
                     ELSE async_task_payload_sha256
                 END,
                 updated_at = ?3, completed_at = ?3
             WHERE id = ?4 AND capture_state = ?5",
            params![
                failure.error_type,
                failure.request_id,
                now,
                run_id,
                expected.as_str(),
            ],
        )?;
        if updated == 0 {
            return Err(NotebookCaptureStoreError::Conflict(format!(
                "run {run_id} cannot be interrupted from {} after local persistence failure",
                expected.as_str()
            )));
        }
        self.require_run(run_id)
    }

    /// Updates only provider state. This intentionally cannot change the local
    /// capture state, so a Soniox failure cannot stop local recording.
    pub fn update_remote_health(
        &self,
        run_id: &str,
        health: RemoteHealth,
        failure: Option<&ProviderFailure>,
    ) -> Result<NotebookCaptureRun, NotebookCaptureStoreError> {
        let now = chrono::Utc::now().to_rfc3339();
        let (error_type, request_id) = failure
            .map(|value| (Some(value.error_type.as_str()), value.request_id.as_deref()))
            .unwrap_or((None, None));
        let updated = self.conn.lock().unwrap().execute(
            "UPDATE notebook_capture_runs
             SET remote_health = ?1, provider_error_type = ?2, provider_request_id = ?3,
                 updated_at = ?4
             WHERE id = ?5",
            params![health.as_str(), error_type, request_id, now, run_id],
        )?;
        if updated == 0 {
            return Err(NotebookCaptureStoreError::NotFound(format!(
                "capture run {run_id}"
            )));
        }
        self.require_run(run_id)
    }

    pub fn update_audio_progress(
        &self,
        run_id: &str,
        captured_frames: u64,
    ) -> Result<NotebookCaptureRun, NotebookCaptureStoreError> {
        let now = chrono::Utc::now().to_rfc3339();
        let updated = self.conn.lock().unwrap().execute(
            "UPDATE notebook_capture_runs SET captured_frames = ?1, updated_at = ?2
             WHERE id = ?3 AND capture_state IN ('recording', 'paused', 'draining')
                   AND captured_frames <= ?1",
            params![u64_to_i64(captured_frames, "captured_frames")?, now, run_id],
        )?;
        if updated == 0 {
            return Err(NotebookCaptureStoreError::Conflict(format!(
                "run {run_id} is not writable or frame count moved backwards"
            )));
        }
        self.require_run(run_id)
    }

    /// Durably records audio that was accepted locally but deliberately not
    /// sent into a new realtime epoch after a discontinuity.
    pub fn preserve_network_transcript_gap(
        &self,
        session_id: &str,
        start_frame: u64,
        end_frame: u64,
    ) -> Result<RealtimeTranscriptGap, NotebookCaptureStoreError> {
        if end_frame <= start_frame {
            return Err(NotebookCaptureStoreError::Conflict(format!(
                "invalid transcript gap [{start_frame}, {end_frame})"
            )));
        }
        let now = chrono::Utc::now().to_rfc3339();
        let id = uuid::Uuid::new_v4().to_string();
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "INSERT INTO realtime_transcript_gaps
                (id, session_id, start_frame, end_frame, reason, repair_state,
                 created_at, updated_at)
             VALUES (?1, ?2, ?3, ?4, 'network_discontinuity', 'preserved', ?5, ?5)
             ON CONFLICT(session_id, start_frame, end_frame, reason) DO NOTHING",
            params![
                id,
                session_id,
                u64_to_i64(start_frame, "start_frame")?,
                u64_to_i64(end_frame, "end_frame")?,
                now
            ],
        )?;
        conn.query_row(
            "SELECT id, session_id, start_frame, end_frame, reason, repair_state,
                    created_at, updated_at
             FROM realtime_transcript_gaps
             WHERE session_id = ?1 AND start_frame = ?2 AND end_frame = ?3
                   AND reason = 'network_discontinuity'",
            params![
                session_id,
                u64_to_i64(start_frame, "start_frame")?,
                u64_to_i64(end_frame, "end_frame")?
            ],
            |row| {
                Ok(RealtimeTranscriptGap {
                    id: row.get(0)?,
                    session_id: row.get(1)?,
                    start_frame: i64_to_u64(row.get(2)?, "start_frame")
                        .map_err(|_| rusqlite::Error::IntegralValueOutOfRange(2, -1))?,
                    end_frame: i64_to_u64(row.get(3)?, "end_frame")
                        .map_err(|_| rusqlite::Error::IntegralValueOutOfRange(3, -1))?,
                    reason: row.get(4)?,
                    repair_state: row.get(5)?,
                    created_at: row.get(6)?,
                    updated_at: row.get(7)?,
                })
            },
        )
        .map_err(Into::into)
    }

    pub fn has_unrepaired_transcript_gaps(
        &self,
        session_id: &str,
    ) -> Result<bool, NotebookCaptureStoreError> {
        Ok(self
            .conn
            .lock()
            .unwrap()
            .query_row(
                "SELECT 1 FROM realtime_transcript_gaps
                 WHERE session_id = ?1 AND repair_state <> 'repaired' LIMIT 1",
                [session_id],
                |_| Ok(()),
            )
            .optional()?
            .is_some())
    }

    pub fn finalize_audio(
        &self,
        run_id: &str,
        audio_path: &str,
        captured_frames: u64,
    ) -> Result<NotebookCaptureRun, NotebookCaptureStoreError> {
        require_nonempty("audio_path", audio_path)?;
        let now = chrono::Utc::now().to_rfc3339();
        let updated = self.conn.lock().unwrap().execute(
            "UPDATE notebook_capture_runs
             SET audio_path = ?1, captured_frames = ?2, updated_at = ?3
             WHERE id = ?4 AND capture_state = 'draining' AND captured_frames <= ?2",
            params![
                audio_path,
                u64_to_i64(captured_frames, "captured_frames")?,
                now,
                run_id
            ],
        )?;
        if updated == 0 {
            return Err(NotebookCaptureStoreError::Conflict(format!(
                "run {run_id} must be draining before audio finalization"
            )));
        }
        self.require_run(run_id)
    }

    /// Records the recovered encrypted audio after a crash without changing
    /// the terminal `interrupted` state or its pending projection.
    pub fn finalize_interrupted_audio(
        &self,
        run_id: &str,
        audio_path: &str,
        captured_frames: u64,
    ) -> Result<NotebookCaptureRun, NotebookCaptureStoreError> {
        require_nonempty("audio_path", audio_path)?;
        let now = chrono::Utc::now().to_rfc3339();
        let updated = self.conn.lock().unwrap().execute(
            "UPDATE notebook_capture_runs
             SET audio_path = ?1, captured_frames = ?2, updated_at = ?3
             WHERE id = ?4 AND capture_state = 'interrupted' AND captured_frames <= ?2",
            params![
                audio_path,
                u64_to_i64(captured_frames, "captured_frames")?,
                now,
                run_id
            ],
        )?;
        if updated == 0 {
            return Err(NotebookCaptureStoreError::Conflict(format!(
                "run {run_id} is not interrupted or frame count moved backwards"
            )));
        }
        self.require_run(run_id)
    }

    pub fn set_projection_state(
        &self,
        run_id: &str,
        expected: ProjectionState,
        next: ProjectionState,
    ) -> Result<NotebookCaptureRun, NotebookCaptureStoreError> {
        if !valid_projection_transition(expected, next) {
            return Err(NotebookCaptureStoreError::Validation(format!(
                "invalid projection transition {} -> {}",
                expected.as_str(),
                next.as_str()
            )));
        }
        let now = chrono::Utc::now().to_rfc3339();
        let updated = self.conn.lock().unwrap().execute(
            "UPDATE notebook_capture_runs SET projection_state = ?1, updated_at = ?2
             WHERE id = ?3 AND projection_state = ?4
               AND capture_state IN ('completed', 'interrupted', 'failed')",
            params![next.as_str(), now, run_id, expected.as_str()],
        )?;
        if updated == 0 {
            return Err(NotebookCaptureStoreError::Conflict(format!(
                "run {run_id} projection is not {}",
                expected.as_str()
            )));
        }
        self.require_run(run_id)
    }

    pub fn retry_projection(
        &self,
        run_id: &str,
    ) -> Result<NotebookCaptureRun, NotebookCaptureStoreError> {
        self.set_projection_state(run_id, ProjectionState::Failed, ProjectionState::Pending)
    }

    pub fn set_async_projection_state(
        &self,
        run_id: &str,
        expected: AsyncProjectionState,
        next: AsyncProjectionState,
    ) -> Result<NotebookCaptureRun, NotebookCaptureStoreError> {
        if !valid_async_projection_transition(expected, next) {
            return Err(NotebookCaptureStoreError::Validation(format!(
                "invalid async projection transition {} -> {}",
                expected.as_str(),
                next.as_str()
            )));
        }
        let now = chrono::Utc::now().to_rfc3339();
        let updated = self.conn.lock().unwrap().execute(
            "UPDATE notebook_capture_runs
             SET async_projection_state = ?1, updated_at = ?2
             WHERE id = ?3 AND async_projection_state = ?4
               AND async_task_state = 'completed' AND capture_state = 'completed'",
            params![next.as_str(), now, run_id, expected.as_str()],
        )?;
        if updated == 0 {
            return Err(NotebookCaptureStoreError::Conflict(format!(
                "run {run_id} async projection is not {} or provider work is incomplete",
                expected.as_str()
            )));
        }
        self.require_run(run_id)
    }

    pub fn retry_async_projection(
        &self,
        run_id: &str,
    ) -> Result<NotebookCaptureRun, NotebookCaptureStoreError> {
        self.set_async_projection_state(
            run_id,
            AsyncProjectionState::Failed,
            AsyncProjectionState::Pending,
        )
    }

    pub fn list_pending_async_projections(
        &self,
    ) -> Result<Vec<NotebookCaptureRun>, NotebookCaptureStoreError> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(&format!(
            "{RUN_SELECT} WHERE capture_state = 'completed'
             AND async_task_state = 'completed' AND async_projection_state = 'pending'
             ORDER BY COALESCE(completed_at, updated_at) ASC, id ASC"
        ))?;
        let rows = stmt.query_map([], capture_run_from_row)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
    }

    /// Commits the local async transcript projection only if Delete Forever
    /// has not already published its durable tombstone.
    pub fn complete_async_projection_unless_purging(
        &self,
        run_id: &str,
    ) -> Result<(), NotebookCaptureStoreError> {
        require_nonempty("run_id", run_id)?;
        let mut conn = self.conn.lock().unwrap();
        let tx = conn.transaction()?;
        let session_id = tx
            .query_row(
                "SELECT session_id FROM notebook_capture_runs WHERE id = ?1",
                [run_id],
                |row| row.get::<_, String>(0),
            )
            .optional()?
            .ok_or_else(|| NotebookCaptureStoreError::NotFound(format!("capture run {run_id}")))?;
        if session_purge_job_exists(&tx, &session_id)? {
            return Err(NotebookCaptureStoreError::Conflict(format!(
                "capture session {session_id} is being permanently deleted"
            )));
        }
        let now = chrono::Utc::now().to_rfc3339();
        let updated = tx.execute(
            "UPDATE notebook_capture_runs
             SET async_projection_state = 'ready', updated_at = ?1
             WHERE id = ?2 AND async_projection_state = 'projecting'
               AND async_task_state = 'completed' AND capture_state = 'completed'",
            params![now, run_id],
        )?;
        if updated == 0 {
            return Err(NotebookCaptureStoreError::Conflict(format!(
                "run {run_id} async projection is not projecting"
            )));
        }
        tx.execute(
            "UPDATE realtime_transcript_gaps
             SET repair_state = 'repaired', updated_at = ?1
             WHERE session_id = ?2 AND repair_state <> 'repaired'",
            params![now, session_id],
        )?;
        tx.commit()?;
        Ok(())
    }

    /// Atomically commits a completed Loro projection only while the owning
    /// session has no durable Delete Forever tombstone.
    ///
    /// The projection writer performs its Loro rollback if this transaction
    /// fails. Keeping the tombstone check and Projecting -> Ready CAS in the
    /// same SQLite transaction closes the last-commit race with
    /// `begin_session_purge`.
    pub fn complete_projection_unless_purging(
        &self,
        run_id: &str,
    ) -> Result<(), NotebookCaptureStoreError> {
        require_nonempty("run_id", run_id)?;
        let mut conn = self.conn.lock().unwrap();
        let tx = conn.transaction()?;
        let session_id = tx
            .query_row(
                "SELECT session_id FROM notebook_capture_runs WHERE id = ?1",
                [run_id],
                |row| row.get::<_, String>(0),
            )
            .optional()?
            .ok_or_else(|| NotebookCaptureStoreError::NotFound(format!("capture run {run_id}")))?;
        if session_purge_job_exists(&tx, &session_id)? {
            return Err(NotebookCaptureStoreError::Conflict(format!(
                "capture session {session_id} is being permanently deleted"
            )));
        }
        let now = chrono::Utc::now().to_rfc3339();
        let updated = tx.execute(
            "UPDATE notebook_capture_runs SET projection_state = 'ready', updated_at = ?1
             WHERE id = ?2 AND projection_state = 'projecting'
               AND capture_state IN ('completed', 'interrupted', 'failed')",
            params![now, run_id],
        )?;
        if updated == 0 {
            return Err(NotebookCaptureStoreError::Conflict(format!(
                "run {run_id} projection is not projecting"
            )));
        }
        tx.commit()?;
        Ok(())
    }

    /// Freeze every currently-known deletion target before any external
    /// filesystem, local-key, task database, or Loro mutation is attempted.
    /// Repeated calls are idempotent and always return the original plan.
    pub fn begin_session_purge(
        &self,
        session_id: &str,
    ) -> Result<SessionPurgeJob, NotebookCaptureStoreError> {
        self.begin_session_purge_with_extras(session_id, &[], &[])
    }

    /// Start the same durable Delete Forever saga for a capture that failed
    /// before every newly-created file/key reference reached SQLite. Extras
    /// are frozen into the first plan, so restart recovery can finish cleanup
    /// even when the original `start` caller is gone.
    pub fn begin_session_purge_with_extras(
        &self,
        session_id: &str,
        extra_file_paths: &[String],
        extra_key_refs: &[String],
    ) -> Result<SessionPurgeJob, NotebookCaptureStoreError> {
        require_nonempty("session_id", session_id)?;
        for path in extra_file_paths {
            require_nonempty("extra purge file path", path)?;
        }
        for key_ref in extra_key_refs {
            require_nonempty("extra purge key ref", key_ref)?;
        }
        let mut conn = self.conn.lock().unwrap();
        let tx = conn.transaction()?;
        if let Some(existing) = get_session_purge_job_from_conn(&tx, session_id)? {
            tx.commit()?;
            return Ok(existing);
        }

        let active_state = tx
            .query_row(
                "SELECT capture_state FROM notebook_capture_runs WHERE session_id = ?1",
                [session_id],
                |row| row.get::<_, String>(0),
            )
            .optional()?;
        if active_state
            .as_deref()
            .map(CaptureState::parse)
            .transpose()?
            .is_some_and(CaptureState::is_active)
        {
            return Err(NotebookCaptureStoreError::Conflict(format!(
                "capture session {session_id} is still active"
            )));
        }

        let mut plan = build_session_purge_plan(&tx, session_id)?;
        plan.file_paths.extend_from_slice(extra_file_paths);
        plan.key_refs.extend_from_slice(extra_key_refs);
        deduplicate_preserving_order(&mut plan.file_paths);
        deduplicate_preserving_order(&mut plan.key_refs);
        let plan_json = serde_json::to_string(&plan)?;
        let now = chrono::Utc::now().to_rfc3339();
        tx.execute(
            "INSERT INTO session_purge_jobs
             (session_id, plan_json, phase, last_error, created_at, updated_at)
             VALUES (?1, ?2, 'prepared', NULL, ?3, ?3)",
            params![session_id, plan_json, now],
        )?;
        let job = get_session_purge_job_from_conn(&tx, session_id)?.ok_or_else(|| {
            NotebookCaptureStoreError::NotFound(format!("session purge job {session_id}"))
        })?;
        tx.commit()?;
        Ok(job)
    }

    pub fn get_session_purge_job(
        &self,
        session_id: &str,
    ) -> Result<Option<SessionPurgeJob>, NotebookCaptureStoreError> {
        require_nonempty("session_id", session_id)?;
        get_session_purge_job_from_conn(&self.conn.lock().unwrap(), session_id)
    }

    /// Lightweight tombstone check for task workers and artifact writers.
    /// Once true, no new session-owned work may be started or committed.
    pub fn has_session_purge_job(
        &self,
        session_id: &str,
    ) -> Result<bool, NotebookCaptureStoreError> {
        require_nonempty("session_id", session_id)?;
        session_purge_job_exists(&self.conn.lock().unwrap(), session_id)
    }

    pub fn list_session_purge_jobs(
        &self,
    ) -> Result<Vec<SessionPurgeJob>, NotebookCaptureStoreError> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(
            "SELECT session_id, plan_json, phase, last_error, created_at, updated_at
             FROM session_purge_jobs ORDER BY created_at ASC, session_id ASC",
        )?;
        let rows = stmt.query_map([], session_purge_job_from_row)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
    }

    pub fn update_session_purge_job(
        &self,
        session_id: &str,
        phase: &str,
        last_error: Option<&str>,
    ) -> Result<SessionPurgeJob, NotebookCaptureStoreError> {
        require_nonempty("session_id", session_id)?;
        require_nonempty("purge phase", phase)?;
        if phase.len() > 64 {
            return Err(NotebookCaptureStoreError::Validation(
                "purge phase exceeds 64 bytes".into(),
            ));
        }
        let now = chrono::Utc::now().to_rfc3339();
        let updated = self.conn.lock().unwrap().execute(
            "UPDATE session_purge_jobs
             SET phase = ?1, last_error = ?2, updated_at = ?3
             WHERE session_id = ?4",
            params![phase, last_error, now, session_id],
        )?;
        if updated == 0 {
            return Err(NotebookCaptureStoreError::NotFound(format!(
                "session purge job {session_id}"
            )));
        }
        self.get_session_purge_job(session_id)?.ok_or_else(|| {
            NotebookCaptureStoreError::NotFound(format!("session purge job {session_id}"))
        })
    }

    /// Remove the durable tombstone only after the orchestration layer has
    /// completed every frozen external and main-database deletion target.
    pub fn complete_session_purge_job(
        &self,
        session_id: &str,
    ) -> Result<bool, NotebookCaptureStoreError> {
        require_nonempty("session_id", session_id)?;
        let deleted = self.conn.lock().unwrap().execute(
            "DELETE FROM session_purge_jobs WHERE session_id = ?1",
            [session_id],
        )?;
        Ok(deleted > 0)
    }

    pub fn preview_session_purge(
        &self,
        session_id: &str,
    ) -> Result<SessionPurgePlan, NotebookCaptureStoreError> {
        require_nonempty("session_id", session_id)?;
        build_session_purge_plan(&self.conn.lock().unwrap(), session_id)
    }

    /// Deletes all capture/session artifacts that live in the shared main
    /// SQLite database in one transaction. Context Packs and bindings are never
    /// touched. TaskQueue is a separate store and must be purged by the caller.
    pub fn purge_session_artifacts(
        &self,
        session_id: &str,
    ) -> Result<SessionPurgePlan, NotebookCaptureStoreError> {
        require_nonempty("session_id", session_id)?;
        let mut conn = self.conn.lock().unwrap();
        let tx = conn.transaction()?;
        let plan = build_session_purge_plan(&tx, session_id)?;

        tx.execute(
            "DELETE FROM notebook_projection_mutations WHERE session_id = ?1",
            [session_id],
        )?;
        tx.execute(
            "DELETE FROM realtime_utterances WHERE session_id = ?1",
            [session_id],
        )?;
        tx.execute(
            "DELETE FROM session_speakers WHERE session_id = ?1",
            [session_id],
        )?;
        tx.execute(
            "DELETE FROM search_index WHERE session_id = ?1",
            [session_id],
        )?;
        tx.execute(
            "DELETE FROM audio_retention_chunks WHERE session_id = ?1",
            [session_id],
        )?;
        tx.execute(
            "DELETE FROM session_meta WHERE session_id = ?1",
            [session_id],
        )?;
        tx.execute(
            "DELETE FROM notebook_session_projections WHERE session_id = ?1",
            [session_id],
        )?;
        tx.execute(
            "DELETE FROM notebook_sessions WHERE session_id = ?1",
            [session_id],
        )?;
        tx.execute("DELETE FROM session_records WHERE id = ?1", [session_id])?;
        tx.execute(
            "DELETE FROM notebook_capture_runs WHERE session_id = ?1",
            [session_id],
        )?;
        tx.commit()?;
        Ok(plan)
    }

    pub fn create_participant(
        &self,
        display_name: &str,
    ) -> Result<Participant, NotebookCaptureStoreError> {
        require_nonempty("participant display_name", display_name)?;
        let id = uuid::Uuid::new_v4().to_string();
        let now = chrono::Utc::now().to_rfc3339();
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "INSERT INTO participants (id, display_name, created_at, updated_at)
             VALUES (?1, ?2, ?3, ?3)",
            params![id, display_name, now],
        )?;
        get_participant_from_conn(&conn, &id)?
            .ok_or_else(|| NotebookCaptureStoreError::NotFound(format!("participant {id}")))
    }

    pub fn list_participants(&self) -> Result<Vec<Participant>, NotebookCaptureStoreError> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(
            "SELECT id, display_name, created_at, updated_at
             FROM participants
             ORDER BY display_name COLLATE NOCASE ASC, id ASC",
        )?;
        let rows = stmt.query_map([], participant_from_row)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
    }

    pub fn get_participant(
        &self,
        participant_id: &str,
    ) -> Result<Option<Participant>, NotebookCaptureStoreError> {
        require_nonempty("participant_id", participant_id)?;
        get_participant_from_conn(&self.conn.lock().unwrap(), participant_id)
    }

    pub fn rename_participant(
        &self,
        participant_id: &str,
        display_name: &str,
    ) -> Result<Participant, NotebookCaptureStoreError> {
        require_nonempty("participant_id", participant_id)?;
        require_nonempty("participant display_name", display_name)?;
        let now = chrono::Utc::now().to_rfc3339();
        let conn = self.conn.lock().unwrap();
        let updated = conn.execute(
            "UPDATE participants
             SET display_name = ?1, updated_at = ?2
             WHERE id = ?3",
            params![display_name, now, participant_id],
        )?;
        if updated == 0 {
            return Err(NotebookCaptureStoreError::NotFound(format!(
                "participant {participant_id}"
            )));
        }
        get_participant_from_conn(&conn, participant_id)?.ok_or_else(|| {
            NotebookCaptureStoreError::NotFound(format!("participant {participant_id}"))
        })
    }

    /// Delete only the human-managed index record. Any linked anonymous
    /// session speakers remain and become unlinked through the foreign key.
    pub fn delete_participant(
        &self,
        participant_id: &str,
    ) -> Result<bool, NotebookCaptureStoreError> {
        require_nonempty("participant_id", participant_id)?;
        let mut conn = self.conn.lock().unwrap();
        let tx = conn.transaction()?;
        tx.execute(
            "UPDATE session_speakers
             SET participant_id = NULL, participant_linked_at = NULL,
                 updated_at = ?1
             WHERE participant_id = ?2",
            params![chrono::Utc::now().to_rfc3339(), participant_id],
        )?;
        let deleted = tx.execute("DELETE FROM participants WHERE id = ?1", [participant_id])? > 0;
        tx.commit()?;
        Ok(deleted)
    }

    /// Return the stable local row for one provider label in one connection
    /// epoch, creating it if this is the first observation.
    pub fn ensure_session_speaker(
        &self,
        session_id: &str,
        provider_session_epoch: u64,
        provider: &str,
        provider_label: &str,
    ) -> Result<SessionSpeaker, NotebookCaptureStoreError> {
        for (field, value) in [
            ("session_id", session_id),
            ("speaker provider", provider),
            ("provider speaker label", provider_label),
        ] {
            require_nonempty(field, value)?;
        }
        let epoch = u64_to_i64(provider_session_epoch, "provider_session_epoch")?;
        let id = uuid::Uuid::new_v4().to_string();
        let now = chrono::Utc::now().to_rfc3339();
        let conn = self.conn.lock().unwrap();
        if !capture_session_exists(&conn, session_id)? {
            return Err(NotebookCaptureStoreError::NotFound(format!(
                "capture session {session_id}"
            )));
        }
        conn.execute(
            "INSERT INTO session_speakers
             (id, session_id, provider_session_epoch, provider, provider_label,
              created_at, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?6)
             ON CONFLICT(session_id, provider_session_epoch, provider, provider_label)
             DO NOTHING",
            params![id, session_id, epoch, provider, provider_label, now],
        )?;
        get_session_speaker_by_provider_key(
            &conn,
            session_id,
            provider_session_epoch,
            provider,
            provider_label,
        )?
        .ok_or_else(|| {
            NotebookCaptureStoreError::NotFound(format!(
                "session speaker {session_id}:{provider_session_epoch}:{provider}:{provider_label}"
            ))
        })
    }

    pub fn list_session_speakers(
        &self,
        session_id: &str,
    ) -> Result<Vec<SessionSpeaker>, NotebookCaptureStoreError> {
        require_nonempty("session_id", session_id)?;
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(
            "SELECT id, session_id, provider_session_epoch, provider, provider_label,
                    local_display_name, participant_id, participant_linked_at,
                    created_at, updated_at
             FROM session_speakers
             WHERE session_id = ?1
             ORDER BY provider_session_epoch ASC, provider ASC, provider_label ASC, id ASC",
        )?;
        let rows = stmt.query_map([session_id], session_speaker_from_row)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
    }

    pub fn get_session_speaker(
        &self,
        session_speaker_id: &str,
    ) -> Result<Option<SessionSpeaker>, NotebookCaptureStoreError> {
        require_nonempty("session_speaker_id", session_speaker_id)?;
        get_session_speaker_from_conn(&self.conn.lock().unwrap(), session_speaker_id)
    }

    pub fn rename_session_speaker(
        &self,
        session_speaker_id: &str,
        local_display_name: Option<&str>,
    ) -> Result<SessionSpeaker, NotebookCaptureStoreError> {
        require_nonempty("session_speaker_id", session_speaker_id)?;
        if let Some(display_name) = local_display_name {
            require_nonempty("local speaker display_name", display_name)?;
        }
        let now = chrono::Utc::now().to_rfc3339();
        let conn = self.conn.lock().unwrap();
        let updated = conn.execute(
            "UPDATE session_speakers
             SET local_display_name = ?1, updated_at = ?2
             WHERE id = ?3",
            params![local_display_name, now, session_speaker_id],
        )?;
        if updated == 0 {
            return Err(NotebookCaptureStoreError::NotFound(format!(
                "session speaker {session_speaker_id}"
            )));
        }
        get_session_speaker_from_conn(&conn, session_speaker_id)?.ok_or_else(|| {
            NotebookCaptureStoreError::NotFound(format!("session speaker {session_speaker_id}"))
        })
    }

    pub fn link_session_speaker(
        &self,
        session_speaker_id: &str,
        participant_id: &str,
    ) -> Result<SessionSpeaker, NotebookCaptureStoreError> {
        require_nonempty("session_speaker_id", session_speaker_id)?;
        require_nonempty("participant_id", participant_id)?;
        let mut conn = self.conn.lock().unwrap();
        let tx = conn.transaction()?;
        if get_participant_from_conn(&tx, participant_id)?.is_none() {
            return Err(NotebookCaptureStoreError::NotFound(format!(
                "participant {participant_id}"
            )));
        }
        let now = chrono::Utc::now().to_rfc3339();
        let updated = tx.execute(
            "UPDATE session_speakers
             SET participant_id = ?1, participant_linked_at = ?2, updated_at = ?2
             WHERE id = ?3",
            params![participant_id, now, session_speaker_id],
        )?;
        if updated == 0 {
            return Err(NotebookCaptureStoreError::NotFound(format!(
                "session speaker {session_speaker_id}"
            )));
        }
        let speaker = get_session_speaker_from_conn(&tx, session_speaker_id)?.ok_or_else(|| {
            NotebookCaptureStoreError::NotFound(format!("session speaker {session_speaker_id}"))
        })?;
        tx.commit()?;
        Ok(speaker)
    }

    pub fn unlink_session_speaker(
        &self,
        session_speaker_id: &str,
    ) -> Result<SessionSpeaker, NotebookCaptureStoreError> {
        require_nonempty("session_speaker_id", session_speaker_id)?;
        let now = chrono::Utc::now().to_rfc3339();
        let conn = self.conn.lock().unwrap();
        let updated = conn.execute(
            "UPDATE session_speakers
             SET participant_id = NULL, participant_linked_at = NULL, updated_at = ?1
             WHERE id = ?2",
            params![now, session_speaker_id],
        )?;
        if updated == 0 {
            return Err(NotebookCaptureStoreError::NotFound(format!(
                "session speaker {session_speaker_id}"
            )));
        }
        get_session_speaker_from_conn(&conn, session_speaker_id)?.ok_or_else(|| {
            NotebookCaptureStoreError::NotFound(format!("session speaker {session_speaker_id}"))
        })
    }

    /// Delete one provider-label row. Existing utterances remain and become
    /// anonymous through the nullable foreign key.
    pub fn delete_session_speaker(
        &self,
        session_speaker_id: &str,
    ) -> Result<bool, NotebookCaptureStoreError> {
        require_nonempty("session_speaker_id", session_speaker_id)?;
        Ok(self.conn.lock().unwrap().execute(
            "DELETE FROM session_speakers WHERE id = ?1",
            [session_speaker_id],
        )? > 0)
    }

    pub fn upsert_utterance(
        &self,
        input: &NewRealtimeUtterance,
        expected_revision: Option<u64>,
    ) -> Result<RealtimeUtterance, NotebookCaptureStoreError> {
        validate_utterance(input)?;
        let now = chrono::Utc::now().to_rfc3339();
        let mut conn = self.conn.lock().unwrap();
        let tx = conn.transaction()?;
        ensure_active_realtime_session(&tx, &input.session_id)?;
        if let Some(session_speaker_id) = input.session_speaker_id.as_deref() {
            let speaker_session_id = tx
                .query_row(
                    "SELECT session_id FROM session_speakers WHERE id = ?1",
                    [session_speaker_id],
                    |row| row.get::<_, String>(0),
                )
                .optional()?
                .ok_or_else(|| {
                    NotebookCaptureStoreError::NotFound(format!(
                        "session speaker {session_speaker_id}"
                    ))
                })?;
            if speaker_session_id != input.session_id {
                return Err(NotebookCaptureStoreError::Validation(format!(
                    "session speaker {session_speaker_id} belongs to a different capture session"
                )));
            }
        }

        match expected_revision {
            None => {
                tx.execute(
                    "INSERT INTO realtime_utterances
                     (id, session_id, sequence, session_speaker_id, source_language, source_text,
                      source_start_ms, source_end_ms, translated_language, translated_text,
                      revision, completion, alignment, created_at, updated_at)
                     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, 0, ?11, ?12, ?13, ?13)",
                    params![
                        input.id,
                        input.session_id,
                        u64_to_i64(input.sequence, "sequence")?,
                        input.session_speaker_id,
                        input.source_language,
                        input.source_text,
                        option_u64_to_i64(input.source_start_ms, "source_start_ms")?,
                        option_u64_to_i64(input.source_end_ms, "source_end_ms")?,
                        input.translated_language,
                        input.translated_text,
                        input.completion.as_str(),
                        input.alignment.as_str(),
                        now,
                    ],
                )?;
            }
            Some(revision) => {
                let updated = tx.execute(
                    "UPDATE realtime_utterances
                     SET session_speaker_id = ?1, source_language = ?2, source_text = ?3,
                         source_start_ms = ?4, source_end_ms = ?5, translated_language = ?6,
                         translated_text = ?7, revision = revision + 1, completion = ?8,
                         alignment = ?9, updated_at = ?10
                     WHERE session_id = ?11 AND sequence = ?12 AND revision = ?13",
                    params![
                        input.session_speaker_id,
                        input.source_language,
                        input.source_text,
                        option_u64_to_i64(input.source_start_ms, "source_start_ms")?,
                        option_u64_to_i64(input.source_end_ms, "source_end_ms")?,
                        input.translated_language,
                        input.translated_text,
                        input.completion.as_str(),
                        input.alignment.as_str(),
                        now,
                        input.session_id,
                        u64_to_i64(input.sequence, "sequence")?,
                        u64_to_i64(revision, "expected_revision")?,
                    ],
                )?;
                if updated == 0 {
                    return Err(NotebookCaptureStoreError::Conflict(format!(
                        "utterance {}:{} expected revision {revision}",
                        input.session_id, input.sequence
                    )));
                }
            }
        }

        let (utterance_id, revision, created_at) = tx
            .query_row(
                "SELECT id, revision, created_at FROM realtime_utterances
                 WHERE session_id = ?1 AND sequence = ?2",
                params![input.session_id, u64_to_i64(input.sequence, "sequence")?],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, i64>(1)?,
                        row.get::<_, String>(2)?,
                    ))
                },
            )
            .optional()?
            .ok_or_else(|| {
                NotebookCaptureStoreError::NotFound(format!(
                    "utterance {}:{}",
                    input.session_id, input.sequence
                ))
            })?;

        // Language identification can legitimately revise a partial source
        // (for example en -> zh). Remove both the previous source and any
        // translation occupying the newly identified language before the
        // source row is inserted, otherwise the per-utterance language key
        // would abort the whole realtime stream group.
        let source_variant_language = canonical_language(&input.source_language);
        tx.execute(
            "DELETE FROM realtime_utterance_variants
             WHERE utterance_id = ?1
               AND (role = 'source' OR lower(trim(language)) = ?2)",
            params![utterance_id, source_variant_language],
        )?;
        tx.execute(
            "INSERT INTO realtime_utterance_variants
             (utterance_id, language, role, text, state, completion,
              revision, created_at, updated_at)
             VALUES (?1, ?2, 'source', ?3, 'ready', ?4, ?5, ?6, ?7)",
            params![
                utterance_id,
                source_variant_language,
                input.source_text,
                input.completion.as_str(),
                revision,
                created_at,
                now,
            ],
        )?;
        if let (Some(language), Some(text)) = (
            input.translated_language.as_deref(),
            input.translated_text.as_deref(),
        ) {
            tx.execute(
                "INSERT INTO realtime_utterance_variants
                 (utterance_id, language, role, text, state, completion,
                  revision, created_at, updated_at)
                 VALUES (?1, ?2, 'translation', ?3, 'ready', ?4, ?5, ?6, ?7)
                 ON CONFLICT DO UPDATE SET
                     role = 'translation',
                     text = excluded.text,
                     state = 'ready',
                     completion = excluded.completion,
                     revision = excluded.revision,
                     updated_at = excluded.updated_at",
                params![
                    utterance_id,
                    language,
                    text,
                    input.completion.as_str(),
                    revision,
                    created_at,
                    now,
                ],
            )?;
        }

        let utterance =
            get_utterance_by_session_sequence_from_conn(&tx, &input.session_id, input.sequence)?
                .ok_or_else(|| {
                    NotebookCaptureStoreError::NotFound(format!(
                        "utterance {}:{}",
                        input.session_id, input.sequence
                    ))
                })?;
        tx.commit()?;
        Ok(utterance)
    }

    /// Insert or update one non-source language column for an active realtime
    /// utterance. Waiting/error states carry no text; a ready state carries
    /// both text and completion. The legacy translated columns are updated
    /// only when this language is their historical compatibility lane.
    pub fn upsert_translation_variant(
        &self,
        session_id: &str,
        sequence: u64,
        language: &str,
        text: Option<&str>,
        state: UtteranceVariantState,
        completion: Option<UtteranceCompletion>,
    ) -> Result<RealtimeUtterance, NotebookCaptureStoreError> {
        require_nonempty("session_id", session_id)?;
        validate_language(language)?;
        validate_variant_payload(text, state, completion)?;
        let language = canonical_language(language);
        let now = chrono::Utc::now().to_rfc3339();
        let mut conn = self.conn.lock().unwrap();
        let tx = conn.transaction()?;
        ensure_active_realtime_session(&tx, session_id)?;
        let utterance = get_utterance_by_session_sequence_from_conn(&tx, session_id, sequence)?
            .ok_or_else(|| {
                NotebookCaptureStoreError::NotFound(format!("utterance {session_id}:{sequence}"))
            })?;
        if canonical_language(&utterance.source_language) == language {
            return Err(NotebookCaptureStoreError::Validation(format!(
                "translation variant {language} duplicates the source language"
            )));
        }

        tx.execute(
            "INSERT INTO realtime_utterance_variants
             (utterance_id, language, role, text, state, completion,
              revision, created_at, updated_at)
             VALUES (?1, ?2, 'translation', ?3, ?4, ?5, 0, ?6, ?6)
             ON CONFLICT DO UPDATE SET
                 role = 'translation',
                 text = excluded.text,
                 state = excluded.state,
                 completion = excluded.completion,
                 revision = realtime_utterance_variants.revision + 1,
                 updated_at = excluded.updated_at",
            params![
                utterance.id,
                language,
                text,
                state.as_str(),
                completion.map(UtteranceCompletion::as_str),
                now,
            ],
        )?;

        let updates_legacy_shadow = state == UtteranceVariantState::Ready
            && utterance
                .translated_language
                .as_deref()
                .is_some_and(|legacy| canonical_language(legacy) == language);
        if updates_legacy_shadow {
            tx.execute(
                "UPDATE realtime_utterances
                 SET translated_text = ?1, revision = revision + 1, updated_at = ?2
                 WHERE id = ?3",
                params![text, now, utterance.id],
            )?;
        }

        let utterance = get_utterance_by_id_from_conn(&tx, &utterance.id)?.ok_or_else(|| {
            NotebookCaptureStoreError::NotFound(format!("utterance {}", utterance.id))
        })?;
        tx.commit()?;
        Ok(utterance)
    }

    pub fn list_utterances(
        &self,
        session_id: &str,
    ) -> Result<Vec<RealtimeUtterance>, NotebookCaptureStoreError> {
        let conn = self.conn.lock().unwrap();
        list_utterances_from_conn(&conn, session_id)
    }

    /// Returns every visible capture for one Notebook in recording chronology.
    ///
    /// A run remains in this read model even when it has no realtime
    /// utterances, allowing local-only recordings to render as recorded but
    /// not-yet-transcribed history. Session and Notebook soft deletes, plus the
    /// durable Delete Forever tombstone, hide a run before external cleanup is
    /// attempted. The read transaction keeps each run and its utterance list
    /// from crossing revisions while this snapshot is assembled.
    pub fn list_notebook_capture_history(
        &self,
        notebook_id: &str,
    ) -> Result<Vec<NotebookCaptureHistoryRun>, NotebookCaptureStoreError> {
        require_nonempty("notebook_id", notebook_id)?;

        let mut conn = self.conn.lock().unwrap();
        let tx = conn.transaction()?;
        let visible_runs = {
            let mut stmt = tx.prepare(
                "SELECT r.id, r.notebook_id, r.session_id, r.profile_revision,
                        r.profile_snapshot_json, r.realtime_provider_id,
                        r.realtime_model_id, r.post_stop_provider_id,
                        r.post_stop_model_id, r.context_receipt_json,
                        r.context_applied_at, r.capture_state, r.remote_health,
                        r.projection_state, r.provider_error_type,
                        r.provider_request_id, r.audio_journal_path, r.audio_path,
                        r.audio_key_ref, r.sample_rate, r.channels,
                        r.captured_frames, r.created_at, r.updated_at,
                        r.completed_at, r.async_task_state,
                        r.async_authorized_at_ms, r.async_language_hint,
                        r.async_task_id, r.async_task_payload_sha256,
                        r.async_projection_state,
                        CASE
                            WHEN EXISTS (
                                SELECT 1 FROM audio_retention_chunks retained
                                WHERE retained.session_id = r.session_id
                            ) THEN EXISTS (
                                SELECT 1 FROM audio_retention_chunks retained
                                WHERE retained.session_id = r.session_id
                                  AND retained.deleted = 0
                            )
                            ELSE (
                                r.audio_key_ref IS NOT NULL
                                AND (
                                    r.audio_journal_path IS NOT NULL
                                    OR r.audio_path IS NOT NULL
                                )
                            )
                        END AS has_audio
                 FROM notebook_capture_runs r
                 JOIN notebooks n ON n.id = r.notebook_id
                 JOIN session_records s ON s.id = r.session_id
                 WHERE r.notebook_id = ?1
                   AND n.deleted_at IS NULL
                   AND s.deleted_at IS NULL
                   AND NOT EXISTS (
                       SELECT 1 FROM session_purge_jobs purge
                       WHERE purge.session_id = r.session_id
                   )
                 ORDER BY r.created_at ASC, r.id ASC",
            )?;
            let rows = stmt.query_map([notebook_id], |row| {
                Ok((capture_run_from_row(row)?, row.get::<_, bool>(31)?))
            })?;
            rows.collect::<Result<Vec<_>, _>>()?
        };

        let mut history = Vec::with_capacity(visible_runs.len());
        for (run, has_audio) in visible_runs {
            let utterances = list_utterances_from_conn(&tx, &run.session_id)?;
            history.push(NotebookCaptureHistoryRun::from_run(
                run, has_audio, utterances,
            ));
        }
        tx.commit()?;
        Ok(history)
    }

    pub fn get_utterance_by_id(
        &self,
        utterance_id: &str,
    ) -> Result<Option<RealtimeUtterance>, NotebookCaptureStoreError> {
        require_nonempty("utterance_id", utterance_id)?;
        get_utterance_by_id_from_conn(&self.conn.lock().unwrap(), utterance_id)
    }

    /// Durably stage a lane edit without changing the visible utterance.
    /// Loro must be synchronously updated before `commit_projection_mutation`
    /// performs the revision CAS. Identical repeated staging is idempotent.
    pub fn stage_utterance_lane_replacement(
        &self,
        utterance_id: &str,
        lane: UtteranceLane,
        target_text: &str,
        expected_revision: u64,
    ) -> Result<NotebookProjectionMutation, NotebookCaptureStoreError> {
        require_nonempty("utterance_id", utterance_id)?;
        let utterance = self.get_utterance_by_id(utterance_id)?.ok_or_else(|| {
            NotebookCaptureStoreError::NotFound(format!("utterance {utterance_id}"))
        })?;
        let lane_language = match lane {
            UtteranceLane::Source => utterance.source_language,
            UtteranceLane::Translated => utterance.translated_language.ok_or_else(|| {
                NotebookCaptureStoreError::Conflict(format!(
                    "utterance {utterance_id} has no translated lane"
                ))
            })?,
        };
        self.stage_utterance_variant_replacement(
            utterance_id,
            &lane_language,
            target_text,
            expected_revision,
        )
    }

    /// Durably stage an edit to a specific language variant. This is the
    /// language-addressed form used by multilingual history and supports every
    /// ready translation variant, not only the legacy translated shadow.
    pub fn stage_utterance_variant_replacement(
        &self,
        utterance_id: &str,
        lane_language: &str,
        target_text: &str,
        expected_revision: u64,
    ) -> Result<NotebookProjectionMutation, NotebookCaptureStoreError> {
        require_nonempty("utterance_id", utterance_id)?;
        validate_language(lane_language)?;
        let canonical_lane_language = canonical_language(lane_language);
        let mut conn = self.conn.lock().unwrap();
        let tx = conn.transaction()?;
        let utterance = get_utterance_by_id_from_conn(&tx, utterance_id)?.ok_or_else(|| {
            NotebookCaptureStoreError::NotFound(format!("utterance {utterance_id}"))
        })?;
        let variant = utterance
            .variants
            .iter()
            .find(|variant| canonical_language(&variant.language) == canonical_lane_language)
            .ok_or_else(|| {
                NotebookCaptureStoreError::Conflict(format!(
                    "utterance {utterance_id} has no {canonical_lane_language} variant"
                ))
            })?;
        if variant.state != UtteranceVariantState::Ready || variant.text.is_none() {
            return Err(NotebookCaptureStoreError::Conflict(format!(
                "utterance {utterance_id} variant {} is not ready for editing",
                variant.language
            )));
        }
        let lane = match variant.role {
            UtteranceVariantRole::Source => UtteranceLane::Source,
            UtteranceVariantRole::Translation => UtteranceLane::Translated,
        };
        let lane_language = variant.language.clone();

        ensure_utterance_is_editable(&tx, &utterance.session_id, utterance.completion)?;
        if session_purge_job_exists(&tx, &utterance.session_id)? {
            return Err(NotebookCaptureStoreError::Conflict(format!(
                "session {} is pending permanent deletion",
                utterance.session_id
            )));
        }
        if utterance.revision != expected_revision {
            return Err(NotebookCaptureStoreError::Conflict(format!(
                "utterance {utterance_id} expected revision {expected_revision}"
            )));
        }
        if let Some(existing) = get_projection_mutation_for_utterance(&tx, utterance_id)? {
            if existing.session_id == utterance.session_id
                && existing.lane == lane
                && existing.lane_language == lane_language
                && existing.expected_revision == expected_revision
                && existing.target_text == target_text
                && existing.state == ProjectionMutationState::Pending
            {
                tx.commit()?;
                return Ok(existing);
            }
            return Err(NotebookCaptureStoreError::Conflict(format!(
                "utterance {utterance_id} already has a pending projection mutation"
            )));
        }

        let id = uuid::Uuid::new_v4().to_string();
        let now = chrono::Utc::now().to_rfc3339();
        tx.execute(
            "INSERT INTO notebook_projection_mutations
             (id, session_id, utterance_id, lane, lane_language, expected_revision,
              target_text, state, created_at, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?9)",
            params![
                id,
                utterance.session_id,
                utterance.id,
                lane.as_str(),
                lane_language,
                u64_to_i64(expected_revision, "expected_revision")?,
                target_text,
                ProjectionMutationState::Pending.as_str(),
                now,
            ],
        )?;
        let mutation = get_projection_mutation_from_conn(&tx, &id)?.ok_or_else(|| {
            NotebookCaptureStoreError::NotFound(format!("projection mutation {id}"))
        })?;
        tx.commit()?;
        Ok(mutation)
    }

    /// Commit a staged edit with one revision CAS and delete its journal row in
    /// the same SQLite transaction. Language and timing metadata are immutable.
    pub fn commit_projection_mutation(
        &self,
        mutation_id: &str,
    ) -> Result<RealtimeUtterance, NotebookCaptureStoreError> {
        require_nonempty("mutation_id", mutation_id)?;
        let mut conn = self.conn.lock().unwrap();
        let tx = conn.transaction()?;
        let mutation = get_projection_mutation_from_conn(&tx, mutation_id)?.ok_or_else(|| {
            NotebookCaptureStoreError::NotFound(format!("projection mutation {mutation_id}"))
        })?;
        if mutation.state != ProjectionMutationState::Pending {
            return Err(NotebookCaptureStoreError::Conflict(format!(
                "projection mutation {mutation_id} is not pending"
            )));
        }
        if session_purge_job_exists(&tx, &mutation.session_id)? {
            return Err(NotebookCaptureStoreError::Conflict(format!(
                "session {} is pending permanent deletion",
                mutation.session_id
            )));
        }

        let current =
            get_utterance_by_id_from_conn(&tx, &mutation.utterance_id)?.ok_or_else(|| {
                NotebookCaptureStoreError::NotFound(format!("utterance {}", mutation.utterance_id))
            })?;
        ensure_utterance_is_editable(&tx, &mutation.session_id, current.completion)?;
        let variant = current
            .variants
            .iter()
            .find(|variant| {
                canonical_language(&variant.language) == canonical_language(&mutation.lane_language)
            })
            .ok_or_else(|| {
                NotebookCaptureStoreError::Conflict(format!(
                    "utterance {} has no {} variant",
                    mutation.utterance_id, mutation.lane_language
                ))
            })?;
        let expected_role = match mutation.lane {
            UtteranceLane::Source => UtteranceVariantRole::Source,
            UtteranceLane::Translated => UtteranceVariantRole::Translation,
        };
        if variant.role != expected_role || variant.state != UtteranceVariantState::Ready {
            return Err(NotebookCaptureStoreError::Conflict(format!(
                "utterance {} variant {} changed before commit",
                mutation.utterance_id, mutation.lane_language
            )));
        }

        let now = chrono::Utc::now().to_rfc3339();
        let updates_legacy_translation = mutation.lane == UtteranceLane::Translated
            && current
                .translated_language
                .as_deref()
                .is_some_and(|language| {
                    canonical_language(language) == canonical_language(&mutation.lane_language)
                });
        let sql = match (mutation.lane, updates_legacy_translation) {
            (UtteranceLane::Source, _) => {
                "UPDATE realtime_utterances
                 SET source_text = ?1, revision = revision + 1, updated_at = ?2
                 WHERE id = ?3 AND session_id = ?4 AND revision = ?5"
            }
            (UtteranceLane::Translated, true) => {
                "UPDATE realtime_utterances
                 SET translated_text = ?1, revision = revision + 1, updated_at = ?2
                 WHERE id = ?3 AND session_id = ?4 AND revision = ?5
                   AND translated_language IS NOT NULL AND translated_text IS NOT NULL"
            }
            (UtteranceLane::Translated, false) => {
                "UPDATE realtime_utterances
                 SET revision = revision + 1, updated_at = ?2
                 WHERE id = ?3 AND session_id = ?4 AND revision = ?5"
            }
        };
        let updated = tx.execute(
            sql,
            params![
                mutation.target_text,
                now,
                mutation.utterance_id,
                mutation.session_id,
                u64_to_i64(mutation.expected_revision, "expected_revision")?,
            ],
        )?;
        if updated == 0 {
            return Err(NotebookCaptureStoreError::Conflict(format!(
                "utterance {} expected revision {}",
                mutation.utterance_id, mutation.expected_revision
            )));
        }
        let variant_updated = tx.execute(
            "UPDATE realtime_utterance_variants
             SET text = ?1, revision = revision + 1, updated_at = ?2
             WHERE utterance_id = ?3
               AND lower(trim(language)) = lower(trim(?4))
               AND role = ?5 AND state = 'ready'",
            params![
                mutation.target_text,
                now,
                mutation.utterance_id,
                mutation.lane_language,
                expected_role.as_str(),
            ],
        )?;
        if variant_updated == 0 {
            return Err(NotebookCaptureStoreError::Conflict(format!(
                "utterance {} variant {} changed before commit",
                mutation.utterance_id, mutation.lane_language
            )));
        }
        tx.execute(
            "DELETE FROM notebook_projection_mutations WHERE id = ?1",
            [mutation_id],
        )?;
        let utterance =
            get_utterance_by_id_from_conn(&tx, &mutation.utterance_id)?.ok_or_else(|| {
                NotebookCaptureStoreError::NotFound(format!("utterance {}", mutation.utterance_id))
            })?;
        tx.commit()?;
        Ok(utterance)
    }

    pub fn cancel_projection_mutation(
        &self,
        mutation_id: &str,
    ) -> Result<bool, NotebookCaptureStoreError> {
        require_nonempty("mutation_id", mutation_id)?;
        let deleted = self.conn.lock().unwrap().execute(
            "DELETE FROM notebook_projection_mutations
             WHERE id = ?1 AND state = 'pending'",
            [mutation_id],
        )?;
        Ok(deleted > 0)
    }

    pub fn get_projection_mutation(
        &self,
        mutation_id: &str,
    ) -> Result<Option<NotebookProjectionMutation>, NotebookCaptureStoreError> {
        require_nonempty("mutation_id", mutation_id)?;
        get_projection_mutation_from_conn(&self.conn.lock().unwrap(), mutation_id)
    }

    pub fn list_pending_projection_mutations(
        &self,
    ) -> Result<Vec<NotebookProjectionMutation>, NotebookCaptureStoreError> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(&format!(
            "{PROJECTION_MUTATION_SELECT} WHERE state = 'pending'
             ORDER BY created_at ASC, id ASC"
        ))?;
        let rows = stmt.query_map([], projection_mutation_from_row)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
    }

    fn require_run(&self, run_id: &str) -> Result<NotebookCaptureRun, NotebookCaptureStoreError> {
        self.get_run(run_id)?
            .ok_or_else(|| NotebookCaptureStoreError::NotFound(format!("capture run {run_id}")))
    }
}

const RUN_SELECT: &str =
    "SELECT id, notebook_id, session_id, profile_revision, profile_snapshot_json,
            realtime_provider_id, realtime_model_id,
            post_stop_provider_id, post_stop_model_id,
            context_receipt_json, context_applied_at, capture_state, remote_health, projection_state,
            provider_error_type, provider_request_id,
            audio_journal_path, audio_path, audio_key_ref, sample_rate, channels,
            captured_frames, created_at, updated_at, completed_at,
            async_task_state, async_authorized_at_ms, async_language_hint,
            async_task_id, async_task_payload_sha256,
            async_projection_state
     FROM notebook_capture_runs";

const UTTERANCE_SELECT: &str =
    "SELECT id, session_id, sequence, session_speaker_id, source_language, source_text,
            source_start_ms, source_end_ms, translated_language, translated_text, revision,
            completion, alignment, created_at, updated_at
     FROM realtime_utterances";

const UTTERANCE_VARIANT_SELECT: &str =
    "SELECT language, role, text, state, completion, revision, created_at, updated_at
     FROM realtime_utterance_variants";

const PROJECTION_MUTATION_SELECT: &str =
    "SELECT id, session_id, utterance_id, lane, lane_language, expected_revision,
            target_text, state, created_at, updated_at
     FROM notebook_projection_mutations";

fn profile_from_row(row: &Row<'_>) -> rusqlite::Result<NotebookCaptureProfile> {
    let capture_mode: String = row.get(2)?;
    let selected_languages_json: String = row.get(7)?;
    // Consume and validate the legacy column type, but never revive it as
    // active product state. `run_migrations` clears persisted values; this
    // read-side normalization is defense in depth for externally restored or
    // partially migrated databases.
    let _legacy_common_caption_language: Option<String> = row.get(8)?;
    let selected_languages = serde_json::from_str(&selected_languages_json)
        .map_err(NotebookCaptureStoreError::from)
        .map_err(to_sql_conversion_error)?;
    Ok(NotebookCaptureProfile {
        notebook_id: row.get(0)?,
        remote_realtime_enabled: row.get(1)?,
        capture_mode: CaptureMode::parse(&capture_mode).map_err(to_sql_conversion_error)?,
        language_a: row.get(3)?,
        language_b: row.get(4)?,
        left_language: row.get(5)?,
        right_language: row.get(6)?,
        selected_languages,
        common_caption_language: None,
        privacy_level: row.get(9)?,
        send_context_to_soniox: row.get(10)?,
        revision: i64_to_u64(row.get(11)?, "profile revision").map_err(to_sql_conversion_error)?,
        created_at: row.get(12)?,
        updated_at: row.get(13)?,
    })
}

fn capture_run_from_row(row: &Row<'_>) -> rusqlite::Result<NotebookCaptureRun> {
    let capture_state: String = row.get(11)?;
    let remote_health: String = row.get(12)?;
    let projection_state: String = row.get(13)?;
    let async_task_state: String = row.get(25)?;
    let async_projection_state: String = row.get(30)?;
    Ok(NotebookCaptureRun {
        id: row.get(0)?,
        notebook_id: row.get(1)?,
        session_id: row.get(2)?,
        profile_revision: i64_to_u64(row.get(3)?, "profile revision")
            .map_err(to_sql_conversion_error)?,
        profile_snapshot_json: row.get(4)?,
        realtime_provider_id: row.get(5)?,
        realtime_model_id: row.get(6)?,
        post_stop_provider_id: row.get(7)?,
        post_stop_model_id: row.get(8)?,
        context_receipt_json: row.get(9)?,
        context_applied_at: row.get(10)?,
        capture_state: CaptureState::parse(&capture_state).map_err(to_sql_conversion_error)?,
        remote_health: RemoteHealth::parse(&remote_health).map_err(to_sql_conversion_error)?,
        projection_state: ProjectionState::parse(&projection_state)
            .map_err(to_sql_conversion_error)?,
        async_task_state: AsyncTaskState::parse(&async_task_state)
            .map_err(to_sql_conversion_error)?,
        async_authorized_at_ms: row.get(26)?,
        async_language_hint: row.get(27)?,
        async_projection_state: AsyncProjectionState::parse(&async_projection_state)
            .map_err(to_sql_conversion_error)?,
        async_task_id: row.get(28)?,
        async_task_payload_sha256: row.get(29)?,
        provider_error_type: row.get(14)?,
        provider_request_id: row.get(15)?,
        audio_journal_path: row.get(16)?,
        audio_path: row.get(17)?,
        audio_key_ref: row.get(18)?,
        sample_rate: option_i64_to_u32(row.get(19)?, "sample_rate")
            .map_err(to_sql_conversion_error)?,
        channels: option_i64_to_u16(row.get(20)?, "channels").map_err(to_sql_conversion_error)?,
        captured_frames: i64_to_u64(row.get(21)?, "captured_frames")
            .map_err(to_sql_conversion_error)?,
        created_at: row.get(22)?,
        updated_at: row.get(23)?,
        completed_at: row.get(24)?,
    })
}

fn realtime_utterance_from_row(row: &Row<'_>) -> rusqlite::Result<RealtimeUtterance> {
    let completion: String = row.get(11)?;
    let alignment: String = row.get(12)?;
    Ok(RealtimeUtterance {
        id: row.get(0)?,
        session_id: row.get(1)?,
        sequence: i64_to_u64(row.get(2)?, "sequence").map_err(to_sql_conversion_error)?,
        session_speaker_id: row.get(3)?,
        source_language: row.get(4)?,
        source_text: row.get(5)?,
        source_start_ms: option_i64_to_u64(row.get(6)?, "source_start_ms")
            .map_err(to_sql_conversion_error)?,
        source_end_ms: option_i64_to_u64(row.get(7)?, "source_end_ms")
            .map_err(to_sql_conversion_error)?,
        translated_language: row.get(8)?,
        translated_text: row.get(9)?,
        revision: i64_to_u64(row.get(10)?, "revision").map_err(to_sql_conversion_error)?,
        completion: UtteranceCompletion::parse(&completion).map_err(to_sql_conversion_error)?,
        alignment: UtteranceAlignment::parse(&alignment).map_err(to_sql_conversion_error)?,
        created_at: row.get(13)?,
        updated_at: row.get(14)?,
        variants: Vec::new(),
    })
}

fn realtime_utterance_variant_from_row(
    row: &Row<'_>,
) -> rusqlite::Result<RealtimeUtteranceVariant> {
    let role: String = row.get(1)?;
    let state: String = row.get(3)?;
    let completion: Option<String> = row.get(4)?;
    Ok(RealtimeUtteranceVariant {
        language: row.get(0)?,
        role: UtteranceVariantRole::parse(&role).map_err(to_sql_conversion_error)?,
        text: row.get(2)?,
        state: UtteranceVariantState::parse(&state).map_err(to_sql_conversion_error)?,
        completion: completion
            .map(|value| UtteranceCompletion::parse(&value))
            .transpose()
            .map_err(to_sql_conversion_error)?,
        revision: i64_to_u64(row.get(5)?, "variant revision").map_err(to_sql_conversion_error)?,
        created_at: row.get(6)?,
        updated_at: row.get(7)?,
    })
}

fn hydrate_utterance_variants(
    conn: &Connection,
    utterance: &mut RealtimeUtterance,
) -> Result<(), NotebookCaptureStoreError> {
    let mut stmt = conn.prepare(&format!(
        "{UTTERANCE_VARIANT_SELECT}
         WHERE utterance_id = ?1
         ORDER BY CASE role WHEN 'source' THEN 0 ELSE 1 END,
                  lower(trim(language)) ASC, language ASC"
    ))?;
    utterance.variants = stmt
        .query_map([&utterance.id], realtime_utterance_variant_from_row)?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(())
}

fn get_utterance_by_id_from_conn(
    conn: &Connection,
    utterance_id: &str,
) -> Result<Option<RealtimeUtterance>, NotebookCaptureStoreError> {
    let mut utterance = conn
        .query_row(
            &format!("{UTTERANCE_SELECT} WHERE id = ?1"),
            [utterance_id],
            realtime_utterance_from_row,
        )
        .optional()?;
    if let Some(utterance) = utterance.as_mut() {
        hydrate_utterance_variants(conn, utterance)?;
    }
    Ok(utterance)
}

fn get_utterance_by_session_sequence_from_conn(
    conn: &Connection,
    session_id: &str,
    sequence: u64,
) -> Result<Option<RealtimeUtterance>, NotebookCaptureStoreError> {
    let mut utterance = conn
        .query_row(
            &format!("{UTTERANCE_SELECT} WHERE session_id = ?1 AND sequence = ?2"),
            params![session_id, u64_to_i64(sequence, "sequence")?],
            realtime_utterance_from_row,
        )
        .optional()?;
    if let Some(utterance) = utterance.as_mut() {
        hydrate_utterance_variants(conn, utterance)?;
    }
    Ok(utterance)
}

fn list_utterances_from_conn(
    conn: &Connection,
    session_id: &str,
) -> Result<Vec<RealtimeUtterance>, NotebookCaptureStoreError> {
    let mut utterances = {
        let mut stmt = conn.prepare(&format!(
            "{UTTERANCE_SELECT} WHERE session_id = ?1 ORDER BY sequence ASC"
        ))?;
        let rows = stmt.query_map([session_id], realtime_utterance_from_row)?;
        rows.collect::<Result<Vec<_>, _>>()?
    };
    for utterance in &mut utterances {
        hydrate_utterance_variants(conn, utterance)?;
    }
    Ok(utterances)
}

fn participant_from_row(row: &Row<'_>) -> rusqlite::Result<Participant> {
    Ok(Participant {
        id: row.get(0)?,
        display_name: row.get(1)?,
        created_at: row.get(2)?,
        updated_at: row.get(3)?,
    })
}

fn session_speaker_from_row(row: &Row<'_>) -> rusqlite::Result<SessionSpeaker> {
    Ok(SessionSpeaker {
        id: row.get(0)?,
        session_id: row.get(1)?,
        provider_session_epoch: i64_to_u64(row.get(2)?, "provider_session_epoch")
            .map_err(to_sql_conversion_error)?,
        provider: row.get(3)?,
        provider_label: row.get(4)?,
        local_display_name: row.get(5)?,
        participant_id: row.get(6)?,
        participant_linked_at: row.get(7)?,
        created_at: row.get(8)?,
        updated_at: row.get(9)?,
    })
}

fn get_participant_from_conn(
    conn: &Connection,
    participant_id: &str,
) -> Result<Option<Participant>, NotebookCaptureStoreError> {
    conn.query_row(
        "SELECT id, display_name, created_at, updated_at
         FROM participants WHERE id = ?1",
        [participant_id],
        participant_from_row,
    )
    .optional()
    .map_err(Into::into)
}

fn get_session_speaker_from_conn(
    conn: &Connection,
    session_speaker_id: &str,
) -> Result<Option<SessionSpeaker>, NotebookCaptureStoreError> {
    conn.query_row(
        "SELECT id, session_id, provider_session_epoch, provider, provider_label,
                local_display_name, participant_id, participant_linked_at,
                created_at, updated_at
         FROM session_speakers WHERE id = ?1",
        [session_speaker_id],
        session_speaker_from_row,
    )
    .optional()
    .map_err(Into::into)
}

fn get_session_speaker_by_provider_key(
    conn: &Connection,
    session_id: &str,
    provider_session_epoch: u64,
    provider: &str,
    provider_label: &str,
) -> Result<Option<SessionSpeaker>, NotebookCaptureStoreError> {
    conn.query_row(
        "SELECT id, session_id, provider_session_epoch, provider, provider_label,
                local_display_name, participant_id, participant_linked_at,
                created_at, updated_at
         FROM session_speakers
         WHERE session_id = ?1 AND provider_session_epoch = ?2
           AND provider = ?3 AND provider_label = ?4",
        params![
            session_id,
            u64_to_i64(provider_session_epoch, "provider_session_epoch")?,
            provider,
            provider_label
        ],
        session_speaker_from_row,
    )
    .optional()
    .map_err(Into::into)
}

fn capture_session_exists(
    conn: &Connection,
    session_id: &str,
) -> Result<bool, NotebookCaptureStoreError> {
    Ok(conn
        .query_row(
            "SELECT 1 FROM notebook_capture_runs WHERE session_id = ?1",
            [session_id],
            |_| Ok(()),
        )
        .optional()?
        .is_some())
}

fn projection_mutation_from_row(row: &Row<'_>) -> rusqlite::Result<NotebookProjectionMutation> {
    let lane: String = row.get(3)?;
    let state: String = row.get(7)?;
    Ok(NotebookProjectionMutation {
        id: row.get(0)?,
        session_id: row.get(1)?,
        utterance_id: row.get(2)?,
        lane: UtteranceLane::parse(&lane).map_err(to_sql_conversion_error)?,
        lane_language: row.get(4)?,
        expected_revision: i64_to_u64(row.get(5)?, "expected revision")
            .map_err(to_sql_conversion_error)?,
        target_text: row.get(6)?,
        state: ProjectionMutationState::parse(&state).map_err(to_sql_conversion_error)?,
        created_at: row.get(8)?,
        updated_at: row.get(9)?,
    })
}

fn session_purge_job_from_row(row: &Row<'_>) -> rusqlite::Result<SessionPurgeJob> {
    let plan_json: String = row.get(1)?;
    let plan = serde_json::from_str(&plan_json).map_err(|error| {
        rusqlite::Error::FromSqlConversionFailure(1, rusqlite::types::Type::Text, Box::new(error))
    })?;
    Ok(SessionPurgeJob {
        session_id: row.get(0)?,
        plan,
        phase: row.get(2)?,
        last_error: row.get(3)?,
        created_at: row.get(4)?,
        updated_at: row.get(5)?,
    })
}

fn get_projection_mutation_from_conn(
    conn: &Connection,
    mutation_id: &str,
) -> Result<Option<NotebookProjectionMutation>, NotebookCaptureStoreError> {
    conn.query_row(
        &format!("{PROJECTION_MUTATION_SELECT} WHERE id = ?1"),
        [mutation_id],
        projection_mutation_from_row,
    )
    .optional()
    .map_err(Into::into)
}

fn get_projection_mutation_for_utterance(
    conn: &Connection,
    utterance_id: &str,
) -> Result<Option<NotebookProjectionMutation>, NotebookCaptureStoreError> {
    conn.query_row(
        &format!("{PROJECTION_MUTATION_SELECT} WHERE utterance_id = ?1"),
        [utterance_id],
        projection_mutation_from_row,
    )
    .optional()
    .map_err(Into::into)
}

fn get_session_purge_job_from_conn(
    conn: &Connection,
    session_id: &str,
) -> Result<Option<SessionPurgeJob>, NotebookCaptureStoreError> {
    conn.query_row(
        "SELECT session_id, plan_json, phase, last_error, created_at, updated_at
         FROM session_purge_jobs WHERE session_id = ?1",
        [session_id],
        session_purge_job_from_row,
    )
    .optional()
    .map_err(Into::into)
}

fn session_purge_job_exists(
    conn: &Connection,
    session_id: &str,
) -> Result<bool, NotebookCaptureStoreError> {
    conn.query_row(
        "SELECT EXISTS(SELECT 1 FROM session_purge_jobs WHERE session_id = ?1)",
        [session_id],
        |row| row.get(0),
    )
    .map_err(Into::into)
}

fn ensure_active_realtime_session(
    conn: &Connection,
    session_id: &str,
) -> Result<(), NotebookCaptureStoreError> {
    let (run_state, realtime_provider_id, realtime_model_id) = conn
        .query_row(
            "SELECT capture_state, realtime_provider_id, realtime_model_id
             FROM notebook_capture_runs WHERE session_id = ?1",
            [session_id],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, Option<String>>(1)?,
                    row.get::<_, Option<String>>(2)?,
                ))
            },
        )
        .optional()?
        .ok_or_else(|| {
            NotebookCaptureStoreError::NotFound(format!("capture session {session_id}"))
        })?;
    if !CaptureState::parse(&run_state)?.is_active() {
        return Err(NotebookCaptureStoreError::Conflict(
            "utterances are read-only after capture finalization".into(),
        ));
    }
    match (
        realtime_provider_id.as_deref(),
        realtime_model_id.as_deref(),
    ) {
        (Some(SONIOX_PROVIDER_ID), Some(SONIOX_STT_RT_V5_MODEL_ID)) => Ok(()),
        (None, None) => Err(NotebookCaptureStoreError::Conflict(
            "realtime utterance requires claimed provider provenance".into(),
        )),
        (Some(_), Some(_)) => Err(NotebookCaptureStoreError::CorruptData(
            "realtime utterance has unsupported provider provenance".into(),
        )),
        _ => Err(NotebookCaptureStoreError::CorruptData(
            "realtime utterance has partial provider provenance".into(),
        )),
    }
}

fn ensure_utterance_is_editable(
    conn: &Connection,
    session_id: &str,
    completion: UtteranceCompletion,
) -> Result<(), NotebookCaptureStoreError> {
    if completion != UtteranceCompletion::Complete {
        return Err(NotebookCaptureStoreError::Conflict(
            "provisional utterance lanes remain machine-owned".into(),
        ));
    }
    let editable = conn
        .query_row(
            "SELECT capture_state, projection_state FROM notebook_capture_runs
             WHERE session_id = ?1",
            [session_id],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
        )
        .optional()?
        .ok_or_else(|| {
            NotebookCaptureStoreError::NotFound(format!("capture session {session_id}"))
        })?;
    let capture_state = CaptureState::parse(&editable.0)?;
    let projection_state = ProjectionState::parse(&editable.1)?;
    if capture_state.is_terminal() && projection_state != ProjectionState::Ready {
        return Err(NotebookCaptureStoreError::Conflict(
            "terminal utterance lanes are editable only after projection is ready".into(),
        ));
    }
    Ok(())
}

fn validate_provider_result_shape(
    session_id: &str,
    token_count: usize,
    result_json: &str,
) -> Result<(), String> {
    let result: serde_json::Value = serde_json::from_str(result_json)
        .map_err(|_| "provider result JSON is malformed".to_string())?;
    let object = result
        .as_object()
        .ok_or_else(|| "provider result JSON must be an object".to_string())?;
    if object.get("session_id").and_then(serde_json::Value::as_str) != Some(session_id) {
        return Err("provider result session_id does not match its capture session".to_string());
    }
    if object
        .get("token_count")
        .and_then(serde_json::Value::as_u64)
        != Some(token_count as u64)
    {
        return Err("provider result token_count does not match authoritative tokens".to_string());
    }
    if object
        .get("full_text")
        .and_then(serde_json::Value::as_str)
        .is_none()
    {
        return Err("provider result has no full_text".to_string());
    }
    if object
        .get("duration_ms")
        .and_then(serde_json::Value::as_u64)
        .is_none()
    {
        return Err("provider result has no duration_ms".to_string());
    }
    Ok(())
}

fn async_provider_output_digest(
    session_id: &str,
    task_id: &str,
    provider_id: &str,
    model_id: &str,
    tokens_json: &str,
    result_json: &str,
) -> String {
    let mut digest = Sha256::new();
    for value in [
        session_id,
        task_id,
        provider_id,
        model_id,
        tokens_json,
        result_json,
    ] {
        digest.update((value.len() as u64).to_be_bytes());
        digest.update(value.as_bytes());
    }
    digest
        .finalize()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

#[derive(Debug, Clone)]
struct RawAsyncProviderReceipt {
    session_id: String,
    task_id: Option<String>,
    provider_id: Option<String>,
    model_id: Option<String>,
    output_sha256: Option<String>,
    result_json: Option<String>,
    search_projection_state: String,
    completed_at: Option<String>,
    tokens_json: Option<String>,
}

impl RawAsyncProviderReceipt {
    fn corrupt_identity(&self, reason: impl Into<String>) -> CorruptAsyncProviderReceipt {
        CorruptAsyncProviderReceipt {
            session_id: self.session_id.clone(),
            task_id: self.task_id.clone(),
            reason: reason.into(),
        }
    }
}

fn raw_async_provider_receipt_from_row(row: &Row<'_>) -> rusqlite::Result<RawAsyncProviderReceipt> {
    Ok(RawAsyncProviderReceipt {
        session_id: row.get(0)?,
        task_id: row.get(1)?,
        provider_id: row.get(2)?,
        model_id: row.get(3)?,
        output_sha256: row.get(4)?,
        result_json: row.get(5)?,
        search_projection_state: row.get(6)?,
        completed_at: row.get(7)?,
        tokens_json: row.get(8)?,
    })
}

fn validate_async_provider_receipt(
    raw: RawAsyncProviderReceipt,
) -> Result<AsyncProviderReceipt, NotebookCaptureStoreError> {
    if raw.session_id.trim().is_empty() {
        return Err(NotebookCaptureStoreError::CorruptData(
            "provider receipt has an empty session id".to_string(),
        ));
    }
    let task_id = raw.task_id.ok_or_else(|| {
        NotebookCaptureStoreError::CorruptData(format!(
            "provider receipt for session {} has no stable task id",
            raw.session_id
        ))
    })?;
    if task_id.trim().is_empty() {
        return Err(NotebookCaptureStoreError::CorruptData(format!(
            "provider receipt for session {} has an empty stable task id",
            raw.session_id
        )));
    }
    let provider_id = raw.provider_id.ok_or_else(|| {
        NotebookCaptureStoreError::CorruptData(format!(
            "provider receipt for session {} has no provider id",
            raw.session_id
        ))
    })?;
    let model_id = raw.model_id.ok_or_else(|| {
        NotebookCaptureStoreError::CorruptData(format!(
            "provider receipt for session {} has no model id",
            raw.session_id
        ))
    })?;
    if provider_id != SONIOX_PROVIDER_ID || model_id != SONIOX_STT_RT_V5_MODEL_ID {
        return Err(NotebookCaptureStoreError::CorruptData(format!(
            "provider receipt for session {} has unsupported provider provenance",
            raw.session_id
        )));
    }
    let output_sha256 = raw.output_sha256.ok_or_else(|| {
        NotebookCaptureStoreError::CorruptData(format!(
            "provider receipt for session {} has no output digest",
            raw.session_id
        ))
    })?;
    if output_sha256.len() != 64
        || output_sha256
            .bytes()
            .any(|byte| !byte.is_ascii_hexdigit() || byte.is_ascii_uppercase())
    {
        return Err(NotebookCaptureStoreError::CorruptData(format!(
            "provider receipt for session {} has an invalid output digest",
            raw.session_id
        )));
    }
    let result_json = raw.result_json.ok_or_else(|| {
        NotebookCaptureStoreError::CorruptData(format!(
            "provider receipt for session {} has no result JSON",
            raw.session_id
        ))
    })?;
    let tokens_json = raw.tokens_json.ok_or_else(|| {
        NotebookCaptureStoreError::CorruptData(format!(
            "provider receipt for session {} has no authoritative tokens",
            raw.session_id
        ))
    })?;
    let tokens: Vec<Token> = serde_json::from_str(&tokens_json).map_err(|_| {
        NotebookCaptureStoreError::CorruptData(format!(
            "provider receipt for session {} has malformed authoritative tokens JSON",
            raw.session_id
        ))
    })?;
    validate_provider_result_shape(&raw.session_id, tokens.len(), &result_json).map_err(
        |reason| {
            NotebookCaptureStoreError::CorruptData(format!(
                "provider receipt for session {} is invalid: {reason}",
                raw.session_id
            ))
        },
    )?;
    let expected_digest = async_provider_output_digest(
        &raw.session_id,
        &task_id,
        &provider_id,
        &model_id,
        &tokens_json,
        &result_json,
    );
    if output_sha256 != expected_digest {
        return Err(NotebookCaptureStoreError::CorruptData(format!(
            "provider receipt for session {} failed output digest verification",
            raw.session_id
        )));
    }
    let search_projection_state = AsyncSearchProjectionState::parse(&raw.search_projection_state)
        .map_err(|_| {
        NotebookCaptureStoreError::CorruptData(format!(
            "provider receipt for session {} has an invalid search projection state",
            raw.session_id
        ))
    })?;
    let completed_at = raw.completed_at.ok_or_else(|| {
        NotebookCaptureStoreError::CorruptData(format!(
            "provider receipt for session {} has no completion time",
            raw.session_id
        ))
    })?;
    if completed_at.trim().is_empty() {
        return Err(NotebookCaptureStoreError::CorruptData(format!(
            "provider receipt for session {} has an empty completion time",
            raw.session_id
        )));
    }

    Ok(AsyncProviderReceipt {
        session_id: raw.session_id,
        task_id,
        provider_id,
        model_id,
        output_sha256,
        result_json,
        search_projection_state,
        completed_at,
    })
}

fn scan_async_provider_receipts(
    conn: &Connection,
    sql: &str,
) -> Result<AsyncProviderReceiptScan, NotebookCaptureStoreError> {
    let mut stmt = conn.prepare(sql)?;
    let rows = stmt.query_map([], raw_async_provider_receipt_from_row)?;
    let mut scan = AsyncProviderReceiptScan::default();
    for row in rows {
        let raw = row?;
        let corrupt_identity = raw.clone();
        match validate_async_provider_receipt(raw) {
            Ok(receipt) => scan.receipts.push(receipt),
            Err(error) => scan
                .corrupt
                .push(corrupt_identity.corrupt_identity(error.to_string())),
        }
    }
    Ok(scan)
}

fn get_async_provider_receipt_from_conn(
    conn: &Connection,
    session_id: &str,
) -> Result<Option<AsyncProviderReceipt>, NotebookCaptureStoreError> {
    let raw = conn
        .query_row(
            "SELECT r.session_id, r.async_task_id,
                r.post_stop_provider_id, r.post_stop_model_id,
                r.async_provider_output_sha256, r.async_provider_result_json,
                r.async_search_projection_state, r.async_provider_completed_at,
                m.tokens_json
         FROM notebook_capture_runs r
         LEFT JOIN session_meta m ON m.session_id = r.session_id
         WHERE r.session_id = ?1 AND r.async_provider_output_sha256 IS NOT NULL",
            [session_id],
            raw_async_provider_receipt_from_row,
        )
        .optional()?;
    raw.map(validate_async_provider_receipt).transpose()
}

fn build_session_purge_plan(
    conn: &Connection,
    session_id: &str,
) -> Result<SessionPurgePlan, NotebookCaptureStoreError> {
    let run = conn
        .query_row(
            "SELECT id, audio_journal_path, audio_path, audio_key_ref,
                    context_snapshot_key_ref
             FROM notebook_capture_runs WHERE session_id = ?1",
            [session_id],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, Option<String>>(1)?,
                    row.get::<_, Option<String>>(2)?,
                    row.get::<_, Option<String>>(3)?,
                    row.get::<_, Option<String>>(4)?,
                ))
            },
        )
        .optional()?;
    let mut plan = SessionPurgePlan {
        session_id: session_id.to_string(),
        key_refs: vec![format!("zulangue.audio.{session_id}")],
        canonical_artifact_names: vec![format!("{session_id}.capture-journal.enc")],
        canonical_artifact_prefixes: vec![
            format!("{session_id}.chunk."),
            format!(".{session_id}.chunk."),
        ],
        ..SessionPurgePlan::default()
    };
    if let Some((run_id, journal, audio, audio_key, context_key)) = run {
        plan.run_id = Some(run_id);
        plan.file_paths.extend(journal);
        plan.file_paths.extend(audio);
        plan.key_refs.extend(audio_key);
        plan.key_refs.extend(context_key);
    }

    let mut stmt = conn.prepare(
        "SELECT p.id, p.notebook_id, p.tab_id, t.doc_id
         FROM notebook_session_projections p
         JOIN notebook_tabs t ON t.id = p.tab_id
         WHERE p.session_id = ?1
         ORDER BY p.created_at ASC, p.id ASC",
    )?;
    plan.projection_targets = stmt
        .query_map([session_id], |row| {
            Ok(ProjectionPurgeTarget {
                projection_id: row.get(0)?,
                notebook_id: row.get(1)?,
                tab_id: row.get(2)?,
                doc_id: row.get(3)?,
            })
        })?
        .collect::<Result<Vec<_>, _>>()?;

    plan.utterance_count = i64_to_u64(
        conn.query_row(
            "SELECT COUNT(*) FROM realtime_utterances WHERE session_id = ?1",
            [session_id],
            |row| row.get(0),
        )?,
        "utterance count",
    )?;

    if let Some((path, key)) = conn
        .query_row(
            "SELECT encrypted_path, key_id FROM session_meta WHERE session_id = ?1",
            [session_id],
            |row| {
                Ok((
                    row.get::<_, Option<String>>(0)?,
                    row.get::<_, Option<String>>(1)?,
                ))
            },
        )
        .optional()?
    {
        plan.file_paths.extend(path);
        plan.key_refs.extend(key);
    }
    let mut stmt = conn.prepare(
        "SELECT local_path FROM audio_retention_chunks WHERE session_id = ?1
         ORDER BY start_ms ASC, chunk_id ASC",
    )?;
    plan.file_paths.extend(
        stmt.query_map([session_id], |row| row.get::<_, String>(0))?
            .collect::<Result<Vec<_>, _>>()?,
    );
    deduplicate_preserving_order(&mut plan.file_paths);
    deduplicate_preserving_order(&mut plan.key_refs);
    deduplicate_preserving_order(&mut plan.canonical_artifact_names);
    deduplicate_preserving_order(&mut plan.canonical_artifact_prefixes);
    Ok(plan)
}

fn deduplicate_preserving_order(values: &mut Vec<String>) {
    let mut seen = std::collections::HashSet::new();
    values.retain(|value| seen.insert(value.clone()));
}

fn validate_profile_update(
    update: &NotebookCaptureProfileUpdate,
) -> Result<(), NotebookCaptureStoreError> {
    if update.selected_languages.is_empty()
        || update.selected_languages.len() > MAX_CAPTURE_LANGUAGES
    {
        return Err(NotebookCaptureStoreError::Validation(format!(
            "selected capture languages must contain 1..={MAX_CAPTURE_LANGUAGES} entries"
        )));
    }
    let mut selected = std::collections::HashSet::new();
    for language in &update.selected_languages {
        validate_language(language)?;
        if canonical_language(language) != *language {
            return Err(NotebookCaptureStoreError::Validation(format!(
                "capture language '{language}' must be trimmed lowercase canonical form"
            )));
        }
        if !selected.insert(language.as_str()) {
            return Err(NotebookCaptureStoreError::Validation(format!(
                "duplicate selected capture language '{language}'"
            )));
        }
    }
    let (legacy_a, legacy_b) = legacy_capture_language_pair(&update.selected_languages);
    if update.language_a != legacy_a
        || update.language_b != legacy_b
        || update.left_language != legacy_a
        || update.right_language != legacy_b
    {
        return Err(NotebookCaptureStoreError::Validation(
            "legacy capture language fields must mirror the first two selected languages".into(),
        ));
    }
    for language in [
        &update.language_a,
        &update.language_b,
        &update.left_language,
        &update.right_language,
    ] {
        validate_language(language)?;
    }
    if update.common_caption_language.is_some() {
        return Err(NotebookCaptureStoreError::Validation(
            "capture profiles must use equal selected-language lanes".into(),
        ));
    }
    let expected_mode = capture_mode_for_selection(
        update.remote_realtime_enabled,
        update.selected_languages.len(),
    );
    if update.capture_mode != expected_mode {
        return Err(NotebookCaptureStoreError::Validation(format!(
            "capture mode must be {} for {} selected language(s) with remote realtime {}",
            expected_mode.as_str(),
            update.selected_languages.len(),
            if update.remote_realtime_enabled {
                "enabled"
            } else {
                "disabled"
            }
        )));
    }
    if !matches!(
        update.privacy_level.as_str(),
        "standard" | "high" | "maximum"
    ) {
        return Err(NotebookCaptureStoreError::Validation(
            "capture privacy level must be standard, high, or maximum".into(),
        ));
    }
    if update.send_context_to_soniox && !update.remote_realtime_enabled {
        return Err(NotebookCaptureStoreError::Validation(
            "sending Context to Soniox requires explicit remote realtime processing".into(),
        ));
    }
    Ok(())
}

pub fn canonical_language(value: &str) -> String {
    value.trim().to_ascii_lowercase()
}

/// Compatibility projection for old two-lane clients and snapshots.
///
/// A one-language profile keeps a stable, hidden second language solely to
/// satisfy the legacy SQLite/FFI pair contract.
pub fn legacy_capture_language_pair(selected_languages: &[String]) -> (String, String) {
    let language_a = selected_languages
        .first()
        .cloned()
        .unwrap_or_else(|| "en".to_string());
    let language_b = selected_languages.get(1).cloned().unwrap_or_else(|| {
        if language_a == "en" {
            "zh".to_string()
        } else {
            "en".to_string()
        }
    });
    (language_a, language_b)
}

pub fn capture_mode_for_selection(
    remote_realtime_enabled: bool,
    selected_language_count: usize,
) -> CaptureMode {
    if !remote_realtime_enabled || selected_language_count <= 1 {
        CaptureMode::TranscriptionOnly
    } else if selected_language_count == 2 {
        CaptureMode::TwoWay
    } else {
        CaptureMode::MultilingualOneWay
    }
}

fn validate_new_run(input: &NewNotebookCaptureRun) -> Result<(), NotebookCaptureStoreError> {
    for (field, value) in [
        ("id", input.id.as_str()),
        ("notebook_id", input.notebook_id.as_str()),
        ("session_id", input.session_id.as_str()),
        ("audio_journal_path", input.audio_journal_path.as_str()),
        ("audio_key_ref", input.audio_key_ref.as_str()),
    ] {
        require_nonempty(field, value)?;
    }
    if input.sample_rate == 0 || input.channels == 0 {
        return Err(NotebookCaptureStoreError::Validation(
            "sample_rate and channels must be positive".into(),
        ));
    }
    Ok(())
}

fn validate_completed_import_run(
    input: &NewCompletedNotebookImportRun,
) -> Result<(), NotebookCaptureStoreError> {
    for (field, value) in [
        ("id", input.id.as_str()),
        ("notebook_id", input.notebook_id.as_str()),
        ("session_id", input.session_id.as_str()),
        ("audio_path", input.audio_path.as_str()),
        ("audio_key_ref", input.audio_key_ref.as_str()),
    ] {
        require_nonempty(field, value)?;
    }
    if input.sample_rate == 0 || input.channels == 0 {
        return Err(NotebookCaptureStoreError::Validation(
            "sample_rate and channels must be positive".into(),
        ));
    }
    Ok(())
}

fn validate_authorized_profile_snapshot(
    input: &NewNotebookCaptureRun,
    profile: &NotebookCaptureProfile,
) -> Result<(), NotebookCaptureStoreError> {
    if profile.notebook_id != input.notebook_id {
        return Err(NotebookCaptureStoreError::Validation(format!(
            "capture profile {} does not authorize notebook {}",
            profile.notebook_id, input.notebook_id
        )));
    }
    require_nonempty("profile created_at", &profile.created_at)?;
    require_nonempty("profile updated_at", &profile.updated_at)?;
    validate_profile_update(&NotebookCaptureProfileUpdate {
        remote_realtime_enabled: profile.remote_realtime_enabled,
        capture_mode: profile.capture_mode,
        language_a: profile.language_a.clone(),
        language_b: profile.language_b.clone(),
        left_language: profile.left_language.clone(),
        right_language: profile.right_language.clone(),
        selected_languages: profile.selected_languages.clone(),
        common_caption_language: profile.common_caption_language.clone(),
        privacy_level: profile.privacy_level.clone(),
        send_context_to_soniox: profile.send_context_to_soniox,
    })
}

fn validate_utterance(input: &NewRealtimeUtterance) -> Result<(), NotebookCaptureStoreError> {
    for (field, value) in [
        ("utterance id", input.id.as_str()),
        ("session id", input.session_id.as_str()),
        ("source language", input.source_language.as_str()),
    ] {
        require_nonempty(field, value)?;
    }
    validate_language(&input.source_language)?;
    if let Some(language) = &input.translated_language {
        validate_language(language)?;
    }
    if input.translated_language.is_some() != input.translated_text.is_some() {
        return Err(NotebookCaptureStoreError::Validation(
            "translated language and text must be present together".into(),
        ));
    }
    if input
        .translated_language
        .as_deref()
        .is_some_and(|language| {
            canonical_language(language) == canonical_language(&input.source_language)
        })
    {
        return Err(NotebookCaptureStoreError::Validation(
            "translated language must differ from the source language".into(),
        ));
    }
    if matches!(input.alignment, UtteranceAlignment::Paired) != input.translated_text.is_some() {
        return Err(NotebookCaptureStoreError::Validation(
            "only paired utterances may contain a translated lane".into(),
        ));
    }
    if let (Some(start), Some(end)) = (input.source_start_ms, input.source_end_ms) {
        if end < start {
            return Err(NotebookCaptureStoreError::Validation(
                "source timestamp range is reversed".into(),
            ));
        }
    }
    Ok(())
}

fn validate_variant_payload(
    text: Option<&str>,
    state: UtteranceVariantState,
    completion: Option<UtteranceCompletion>,
) -> Result<(), NotebookCaptureStoreError> {
    let is_ready = state == UtteranceVariantState::Ready;
    if is_ready != text.is_some() || is_ready != completion.is_some() {
        return Err(NotebookCaptureStoreError::Validation(
            "ready variants require text and completion; non-ready variants require neither".into(),
        ));
    }
    Ok(())
}

fn valid_capture_transition(from: CaptureState, to: CaptureState) -> bool {
    matches!(
        (from, to),
        (CaptureState::Recording, CaptureState::Paused)
            | (CaptureState::Paused, CaptureState::Recording)
            | (
                CaptureState::Recording | CaptureState::Paused,
                CaptureState::Draining
            )
            | (
                CaptureState::Recording | CaptureState::Paused | CaptureState::Draining,
                CaptureState::Interrupted | CaptureState::Failed
            )
            | (CaptureState::Draining, CaptureState::Completed)
    )
}

fn valid_projection_transition(from: ProjectionState, to: ProjectionState) -> bool {
    matches!(
        (from, to),
        (
            ProjectionState::Pending,
            ProjectionState::Projecting | ProjectionState::Failed
        ) | (
            ProjectionState::Projecting,
            ProjectionState::Ready | ProjectionState::Failed
        ) | (ProjectionState::Failed, ProjectionState::Pending)
    )
}

fn valid_async_projection_transition(from: AsyncProjectionState, to: AsyncProjectionState) -> bool {
    matches!(
        (from, to),
        (
            AsyncProjectionState::Pending,
            AsyncProjectionState::Projecting
        ) | (
            AsyncProjectionState::Projecting,
            AsyncProjectionState::Ready | AsyncProjectionState::Failed
        ) | (AsyncProjectionState::Failed, AsyncProjectionState::Pending)
    )
}

fn validate_language(value: &str) -> Result<(), NotebookCaptureStoreError> {
    let value = value.trim();
    if value.is_empty() || value.len() > 32 || !value.is_ascii() {
        return Err(NotebookCaptureStoreError::Validation(format!(
            "invalid language code '{value}'"
        )));
    }
    let mut parts = value.split('-');
    let primary = parts.next().unwrap_or_default();
    if !(2..=3).contains(&primary.len()) || !primary.bytes().all(|byte| byte.is_ascii_alphabetic())
    {
        return Err(NotebookCaptureStoreError::Validation(format!(
            "invalid language code '{value}'"
        )));
    }
    if parts.any(|part| {
        !(2..=8).contains(&part.len()) || !part.bytes().all(|byte| byte.is_ascii_alphanumeric())
    }) {
        return Err(NotebookCaptureStoreError::Validation(format!(
            "invalid language code '{value}'"
        )));
    }
    Ok(())
}

fn require_nonempty(field: &str, value: &str) -> Result<(), NotebookCaptureStoreError> {
    if value.trim().is_empty() {
        return Err(NotebookCaptureStoreError::Validation(format!(
            "{field} cannot be empty"
        )));
    }
    Ok(())
}

fn validate_sha256_hex(field: &str, value: &str) -> Result<(), NotebookCaptureStoreError> {
    if value.len() != 64
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    {
        return Err(NotebookCaptureStoreError::Validation(format!(
            "{field} must be 64 lowercase hexadecimal characters"
        )));
    }
    Ok(())
}

fn u64_to_i64(value: u64, field: &str) -> Result<i64, NotebookCaptureStoreError> {
    i64::try_from(value).map_err(|_| {
        NotebookCaptureStoreError::Validation(format!("{field} exceeds SQLite integer range"))
    })
}

fn option_u64_to_i64(
    value: Option<u64>,
    field: &str,
) -> Result<Option<i64>, NotebookCaptureStoreError> {
    value.map(|value| u64_to_i64(value, field)).transpose()
}

fn i64_to_u64(value: i64, field: &str) -> Result<u64, NotebookCaptureStoreError> {
    u64::try_from(value).map_err(|_| {
        NotebookCaptureStoreError::CorruptData(format!("{field} is negative in SQLite"))
    })
}

fn option_i64_to_u64(
    value: Option<i64>,
    field: &str,
) -> Result<Option<u64>, NotebookCaptureStoreError> {
    value.map(|value| i64_to_u64(value, field)).transpose()
}

fn option_i64_to_u32(
    value: Option<i64>,
    field: &str,
) -> Result<Option<u32>, NotebookCaptureStoreError> {
    value
        .map(|value| {
            u32::try_from(value).map_err(|_| {
                NotebookCaptureStoreError::CorruptData(format!("{field} is outside the u32 range"))
            })
        })
        .transpose()
}

fn option_i64_to_u16(
    value: Option<i64>,
    field: &str,
) -> Result<Option<u16>, NotebookCaptureStoreError> {
    value
        .map(|value| {
            u16::try_from(value).map_err(|_| {
                NotebookCaptureStoreError::CorruptData(format!("{field} is outside the u16 range"))
            })
        })
        .transpose()
}

fn to_sql_conversion_error(error: NotebookCaptureStoreError) -> rusqlite::Error {
    rusqlite::Error::FromSqlConversionFailure(0, rusqlite::types::Type::Text, Box::new(error))
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    fn fixture() -> (TempDir, NotebookCaptureStore, String) {
        let temp = tempfile::tempdir().unwrap();
        let db = temp.path().join("capture.db");
        let notebook_store = crate::NotebookStore::new(&db).unwrap();
        let notebook = notebook_store.create_notebook(Some("Capture")).unwrap();
        let capture_store = NotebookCaptureStore::new(&db).unwrap();
        (temp, capture_store, notebook.id)
    }

    fn new_run(notebook_id: &str, suffix: &str) -> NewNotebookCaptureRun {
        NewNotebookCaptureRun {
            id: format!("run-{suffix}"),
            notebook_id: notebook_id.into(),
            session_id: format!("session-{suffix}"),
            remote_health: RemoteHealth::Off,
            audio_journal_path: format!("/tmp/{suffix}.journal"),
            audio_key_ref: format!("audio-key-{suffix}"),
            sample_rate: 16_000,
            channels: 1,
        }
    }

    fn new_import_run(notebook_id: &str, suffix: &str) -> NewCompletedNotebookImportRun {
        NewCompletedNotebookImportRun {
            id: format!("import-run-{suffix}"),
            notebook_id: notebook_id.into(),
            session_id: format!("import-session-{suffix}"),
            audio_path: format!("/tmp/{suffix}.chunk.00000.enc"),
            audio_key_ref: format!("import-audio-key-{suffix}"),
            sample_rate: 48_000,
            channels: 2,
            captured_frames: 96_000,
        }
    }

    fn create_run(
        store: &NotebookCaptureStore,
        input: &NewNotebookCaptureRun,
    ) -> Result<NotebookCaptureRun, NotebookCaptureStoreError> {
        let profile = store.get_or_create_profile(&input.notebook_id)?;
        store.create_run(input, &profile)
    }

    fn create_catalogued_run(
        store: &NotebookCaptureStore,
        notebook_id: &str,
        suffix: &str,
    ) -> NotebookCaptureRun {
        let profile = store.get_profile(notebook_id).unwrap().unwrap();
        let input = new_run(notebook_id, suffix);
        let session = SessionRecord {
            id: input.session_id.clone(),
            title: format!("Recording {suffix}"),
            session_type: "recording".into(),
            status: "recording".into(),
            duration_ms: 0,
            created_at: format!("2001-01-02T00:00:{suffix}Z"),
            deleted_at: None,
        };
        store
            .create_session_and_run(&session, &input, &profile)
            .unwrap()
    }

    fn claim_realtime(store: &NotebookCaptureStore, session_id: &str) -> NotebookCaptureRun {
        store
            .claim_provider_provenance(
                session_id,
                CaptureProviderRole::Realtime,
                SONIOX_PROVIDER_ID,
                SONIOX_STT_RT_V5_MODEL_ID,
            )
            .unwrap()
    }

    fn claim_post_stop(store: &NotebookCaptureStore, session_id: &str) -> NotebookCaptureRun {
        store
            .claim_provider_provenance(
                session_id,
                CaptureProviderRole::PostStop,
                SONIOX_PROVIDER_ID,
                SONIOX_STT_RT_V5_MODEL_ID,
            )
            .unwrap()
    }

    fn finish_run_ready(store: &NotebookCaptureStore, suffix: &str) {
        let run_id = format!("run-{suffix}");
        store
            .transition_capture(&run_id, CaptureState::Recording, CaptureState::Draining)
            .unwrap();
        store
            .finalize_audio(&run_id, &format!("/tmp/{suffix}.chunk.00000.enc"), 16_000)
            .unwrap();
        store
            .transition_capture(&run_id, CaptureState::Draining, CaptureState::Completed)
            .unwrap();
        store
            .set_projection_state(
                &run_id,
                ProjectionState::Pending,
                ProjectionState::Projecting,
            )
            .unwrap();
        store
            .set_projection_state(&run_id, ProjectionState::Projecting, ProjectionState::Ready)
            .unwrap();
    }

    fn authorize_async_transcription(
        store: &NotebookCaptureStore,
        suffix: &str,
    ) -> NotebookCaptureRun {
        store
            .authorize_async_transcription(
                &format!("session-{suffix}"),
                1_700_000_000_000,
                Some("en"),
            )
            .unwrap();
        store.get_run(&format!("run-{suffix}")).unwrap().unwrap()
    }

    fn commit_provider_receipt_fixture(
        store: &NotebookCaptureStore,
        notebook_id: &str,
        suffix: &str,
    ) -> AsyncProviderReceipt {
        create_run(store, &new_run(notebook_id, suffix)).unwrap();
        finish_run_ready(store, suffix);
        authorize_async_transcription(store, suffix);
        let session_id = format!("session-{suffix}");
        let run_id = format!("run-{suffix}");
        let task_id = format!("provider-task-{suffix}");
        claim_post_stop(store, &session_id);
        store
            .reserve_async_task(&run_id, &task_id, &"a".repeat(64))
            .unwrap();
        store.mark_async_task_enqueued(&run_id, &task_id).unwrap();
        let token = Token {
            text: suffix.into(),
            start_ms: 0,
            end_ms: 100,
            is_final: true,
            language: "en".into(),
            speaker: None,
            confidence: 1.0,
            translation_status: vt_model::TranslationStatus::None,
        };
        let result_json = serde_json::json!({
            "session_id": session_id,
            "token_count": 1,
            "full_text": suffix,
            "duration_ms": 100,
        })
        .to_string();
        store
            .commit_async_provider_success(&session_id, &task_id, &[token], &result_json)
            .unwrap()
    }

    #[derive(Debug, Clone, Copy)]
    enum ProviderReceiptTamper {
        Digest,
        ResultSession,
        Tokens,
        ProviderModel,
    }

    fn tamper_provider_receipt(
        store: &NotebookCaptureStore,
        receipt: &AsyncProviderReceipt,
        tamper: ProviderReceiptTamper,
    ) {
        let conn = store.conn.lock().unwrap();
        match tamper {
            ProviderReceiptTamper::Digest => {
                conn.execute_batch(
                    "DROP TRIGGER notebook_capture_runs_provider_receipt_immutable;",
                )
                .unwrap();
                conn.execute(
                    "UPDATE notebook_capture_runs
                     SET async_provider_output_sha256 = ?1
                     WHERE session_id = ?2",
                    params!["0".repeat(64), receipt.session_id],
                )
                .unwrap();
            }
            ProviderReceiptTamper::ResultSession => {
                let tokens_json: String = conn
                    .query_row(
                        "SELECT tokens_json FROM session_meta WHERE session_id = ?1",
                        [&receipt.session_id],
                        |row| row.get(0),
                    )
                    .unwrap();
                let result_json = serde_json::json!({
                    "session_id": "another-session",
                    "token_count": 1,
                    "full_text": "tampered",
                    "duration_ms": 100,
                })
                .to_string();
                let digest = async_provider_output_digest(
                    &receipt.session_id,
                    &receipt.task_id,
                    &receipt.provider_id,
                    &receipt.model_id,
                    &tokens_json,
                    &result_json,
                );
                conn.execute_batch(
                    "DROP TRIGGER notebook_capture_runs_provider_receipt_immutable;",
                )
                .unwrap();
                conn.execute(
                    "UPDATE notebook_capture_runs
                     SET async_provider_result_json = ?1,
                         async_provider_output_sha256 = ?2
                     WHERE session_id = ?3",
                    params![result_json, digest, receipt.session_id],
                )
                .unwrap();
            }
            ProviderReceiptTamper::Tokens => {
                let rejected = conn.execute(
                    "UPDATE session_meta SET tokens_json = '[]' WHERE session_id = ?1",
                    [&receipt.session_id],
                );
                assert!(
                    rejected.is_err(),
                    "authoritative tokens must be immutable after receipt commit"
                );
                conn.execute_batch("DROP TRIGGER session_meta_provider_tokens_immutable;")
                    .unwrap();
                conn.execute(
                    "UPDATE session_meta SET tokens_json = '[]' WHERE session_id = ?1",
                    [&receipt.session_id],
                )
                .unwrap();
            }
            ProviderReceiptTamper::ProviderModel => {
                let (tokens_json, result_json): (String, String) = conn
                    .query_row(
                        "SELECT m.tokens_json, r.async_provider_result_json
                         FROM notebook_capture_runs r
                         JOIN session_meta m ON m.session_id = r.session_id
                         WHERE r.session_id = ?1",
                        [&receipt.session_id],
                        |row| Ok((row.get(0)?, row.get(1)?)),
                    )
                    .unwrap();
                let model_id = "tampered-model";
                let digest = async_provider_output_digest(
                    &receipt.session_id,
                    &receipt.task_id,
                    &receipt.provider_id,
                    model_id,
                    &tokens_json,
                    &result_json,
                );
                conn.execute_batch(
                    "PRAGMA ignore_check_constraints = ON;
                     DROP TRIGGER notebook_capture_runs_post_stop_provenance_immutable;
                     DROP TRIGGER notebook_capture_runs_provider_receipt_immutable;",
                )
                .unwrap();
                conn.execute(
                    "UPDATE notebook_capture_runs
                     SET post_stop_model_id = ?1,
                         async_provider_output_sha256 = ?2
                     WHERE session_id = ?3",
                    params![model_id, digest, receipt.session_id],
                )
                .unwrap();
            }
        }
    }

    #[test]
    fn profile_defaults_are_local_only() {
        let (_temp, store, notebook_id) = fixture();
        let profile = store.get_or_create_profile(&notebook_id).unwrap();
        assert!(!profile.remote_realtime_enabled);
        assert_eq!(profile.privacy_level, "standard");
        assert!(!profile.send_context_to_soniox);
        assert_eq!(profile.capture_mode, CaptureMode::TranscriptionOnly);
        assert_eq!(
            (profile.language_a.as_str(), profile.language_b.as_str()),
            ("en", "zh")
        );
        assert_eq!(profile.selected_languages, ["en", "zh"]);
        assert_eq!(profile.common_caption_language, None);
    }

    #[test]
    fn notebook_capture_history_is_stable_scoped_and_keeps_empty_runs() {
        let (temp, store, notebook_id) = fixture();
        store.get_or_create_profile(&notebook_id).unwrap();

        create_catalogued_run(&store, &notebook_id, "b");
        claim_realtime(&store, "session-b");
        for sequence in [2, 0] {
            store
                .upsert_utterance(
                    &NewRealtimeUtterance {
                        id: format!("utterance-b-{sequence}"),
                        session_id: "session-b".into(),
                        sequence,
                        session_speaker_id: None,
                        source_language: "en".into(),
                        source_text: format!("source {sequence}"),
                        source_start_ms: Some(sequence * 100),
                        source_end_ms: Some(sequence * 100 + 50),
                        translated_language: None,
                        translated_text: None,
                        completion: UtteranceCompletion::Complete,
                        alignment: UtteranceAlignment::SourceOnly,
                    },
                    None,
                )
                .unwrap();
        }
        finish_run_ready(&store, "b");

        create_catalogued_run(&store, &notebook_id, "a");
        finish_run_ready(&store, "a");

        create_catalogued_run(&store, &notebook_id, "soft-deleted");
        finish_run_ready(&store, "soft-deleted");

        create_catalogued_run(&store, &notebook_id, "purging");
        finish_run_ready(&store, "purging");
        store.begin_session_purge("session-purging").unwrap();

        let other_notebook = crate::NotebookStore::new(&temp.path().join("capture.db"))
            .unwrap()
            .create_notebook(Some("Other"))
            .unwrap();
        store.get_or_create_profile(&other_notebook.id).unwrap();
        create_catalogued_run(&store, &other_notebook.id, "other");
        finish_run_ready(&store, "other");

        {
            let conn = store.conn.lock().unwrap();
            conn.execute(
                "UPDATE notebook_capture_runs
                 SET created_at = '2001-01-02T12:00:00Z'
                 WHERE id IN ('run-a', 'run-b')",
                [],
            )
            .unwrap();
            conn.execute(
                "UPDATE session_records SET deleted_at = '2001-01-02T13:00:00Z'
                 WHERE id = 'session-soft-deleted'",
                [],
            )
            .unwrap();
            conn.execute(
                "INSERT INTO audio_retention_chunks
                 (session_id, chunk_id, start_ms, end_ms, local_path, encrypted,
                  deleted, retention_deadline_ms, deleted_at_ms)
                 VALUES ('session-a', 'session-a:audio:00000', 0, 1,
                         '/tmp/deleted.enc', 1, 1, 0, 1)",
                [],
            )
            .unwrap();
        }

        let history = store.list_notebook_capture_history(&notebook_id).unwrap();
        assert_eq!(
            history
                .iter()
                .map(|run| run.id.as_str())
                .collect::<Vec<_>>(),
            vec!["run-a", "run-b"]
        );
        assert!(history[0].utterances.is_empty());
        assert!(!history[0].has_audio);
        assert_eq!(
            history[1]
                .utterances
                .iter()
                .map(|utterance| utterance.sequence)
                .collect::<Vec<_>>(),
            vec![0, 2]
        );
        assert!(history[1].has_audio);
        assert!(history.iter().all(|run| run.notebook_id == notebook_id));
    }

    #[test]
    fn run_provider_provenance_defaults_null_and_claims_are_role_scoped() {
        let (_temp, store, notebook_id) = fixture();
        store.get_or_create_profile(&notebook_id).unwrap();
        let run = create_run(&store, &new_run(&notebook_id, "provenance")).unwrap();
        assert_eq!(run.realtime_provider_id, None);
        assert_eq!(run.realtime_model_id, None);
        assert_eq!(run.post_stop_provider_id, None);
        assert_eq!(run.post_stop_model_id, None);

        assert!(matches!(
            store.upsert_utterance(
                &NewRealtimeUtterance {
                    id: "utterance-before-provenance".into(),
                    session_id: "session-provenance".into(),
                    sequence: 0,
                    session_speaker_id: None,
                    source_language: "en".into(),
                    source_text: "must be rejected".into(),
                    source_start_ms: None,
                    source_end_ms: None,
                    translated_language: None,
                    translated_text: None,
                    completion: UtteranceCompletion::Complete,
                    alignment: UtteranceAlignment::SourceOnly,
                },
                None,
            ),
            Err(NotebookCaptureStoreError::Conflict(_))
        ));

        assert!(matches!(
            store.claim_provider_provenance(
                "session-provenance",
                CaptureProviderRole::Realtime,
                "soniox",
                "stt-rt-v4",
            ),
            Err(NotebookCaptureStoreError::Validation(_))
        ));
        assert!(matches!(
            store.claim_provider_provenance(
                "session-provenance",
                CaptureProviderRole::PostStop,
                SONIOX_PROVIDER_ID,
                SONIOX_STT_RT_V5_MODEL_ID,
            ),
            Err(NotebookCaptureStoreError::Conflict(_))
        ));

        let claimed = claim_realtime(&store, "session-provenance");
        assert_eq!(
            claimed.realtime_provider_id.as_deref(),
            Some(SONIOX_PROVIDER_ID)
        );
        assert_eq!(
            claimed.realtime_model_id.as_deref(),
            Some(SONIOX_STT_RT_V5_MODEL_ID)
        );
        assert_eq!(
            claim_realtime(&store, "session-provenance").realtime_model_id,
            claimed.realtime_model_id
        );

        store
            .transition_capture(
                "run-provenance",
                CaptureState::Recording,
                CaptureState::Draining,
            )
            .unwrap();
        store
            .transition_capture(
                "run-provenance",
                CaptureState::Draining,
                CaptureState::Completed,
            )
            .unwrap();
        assert!(matches!(
            store.claim_provider_provenance(
                "session-provenance",
                CaptureProviderRole::Realtime,
                SONIOX_PROVIDER_ID,
                SONIOX_STT_RT_V5_MODEL_ID,
            ),
            Err(NotebookCaptureStoreError::Conflict(_))
        ));
        let claimed = claim_post_stop(&store, "session-provenance");
        assert_eq!(
            claimed.post_stop_provider_id.as_deref(),
            Some(SONIOX_PROVIDER_ID)
        );
        assert_eq!(
            claimed.post_stop_model_id.as_deref(),
            Some(SONIOX_STT_RT_V5_MODEL_ID)
        );
        assert_eq!(
            claim_post_stop(&store, "session-provenance").post_stop_model_id,
            claimed.post_stop_model_id
        );
    }

    #[test]
    fn provider_provenance_claim_fails_closed_after_delete_forever_begins() {
        let (_temp, store, notebook_id) = fixture();
        store.get_or_create_profile(&notebook_id).unwrap();
        create_run(&store, &new_run(&notebook_id, "provenance-purge")).unwrap();
        store
            .transition_capture(
                "run-provenance-purge",
                CaptureState::Recording,
                CaptureState::Draining,
            )
            .unwrap();
        store
            .transition_capture(
                "run-provenance-purge",
                CaptureState::Draining,
                CaptureState::Completed,
            )
            .unwrap();
        store
            .begin_session_purge("session-provenance-purge")
            .unwrap();

        assert!(matches!(
            store.claim_provider_provenance(
                "session-provenance-purge",
                CaptureProviderRole::PostStop,
                SONIOX_PROVIDER_ID,
                SONIOX_STT_RT_V5_MODEL_ID,
            ),
            Err(NotebookCaptureStoreError::Conflict(_))
        ));
    }

    #[test]
    fn profile_update_is_revision_checked_and_validates_privacy() {
        let (_temp, store, notebook_id) = fixture();
        store.get_or_create_profile(&notebook_id).unwrap();
        let invalid = NotebookCaptureProfileUpdate {
            remote_realtime_enabled: true,
            capture_mode: CaptureMode::TwoWay,
            language_a: "en".into(),
            language_b: "zh".into(),
            left_language: "en".into(),
            right_language: "zh".into(),
            selected_languages: vec!["en".into(), "zh".into()],
            common_caption_language: None,
            privacy_level: "invalid".into(),
            send_context_to_soniox: false,
        };
        assert!(matches!(
            store.update_profile(&notebook_id, 0, &invalid),
            Err(NotebookCaptureStoreError::Validation(_))
        ));

        let mut valid = invalid;
        valid.privacy_level = "maximum".into();
        let updated = store.update_profile(&notebook_id, 0, &valid).unwrap();
        assert_eq!(updated.revision, 1);
        assert!(matches!(
            store.update_profile(&notebook_id, 0, &valid),
            Err(NotebookCaptureStoreError::Conflict(_))
        ));
    }

    #[test]
    fn multilingual_profile_requires_unique_ordered_languages_without_common_caption() {
        let (_temp, store, notebook_id) = fixture();
        store.get_or_create_profile(&notebook_id).unwrap();
        let valid = NotebookCaptureProfileUpdate {
            remote_realtime_enabled: true,
            capture_mode: CaptureMode::MultilingualOneWay,
            language_a: "en".into(),
            language_b: "zh".into(),
            left_language: "en".into(),
            right_language: "zh".into(),
            selected_languages: vec!["en".into(), "zh".into(), "th".into()],
            common_caption_language: None,
            privacy_level: "standard".into(),
            send_context_to_soniox: false,
        };

        let mut invalid = valid.clone();
        invalid.selected_languages.push("th".into());
        assert!(matches!(
            store.update_profile(&notebook_id, 0, &invalid),
            Err(NotebookCaptureStoreError::Validation(_))
        ));

        let mut invalid = valid.clone();
        invalid.common_caption_language = Some("en".into());
        assert!(matches!(
            store.update_profile(&notebook_id, 0, &invalid),
            Err(NotebookCaptureStoreError::Validation(_))
        ));

        let mut invalid = valid.clone();
        invalid.language_a = "zh".into();
        assert!(matches!(
            store.update_profile(&notebook_id, 0, &invalid),
            Err(NotebookCaptureStoreError::Validation(_))
        ));

        let updated = store.update_profile(&notebook_id, 0, &valid).unwrap();
        assert_eq!(updated.capture_mode, CaptureMode::MultilingualOneWay);
        assert_eq!(updated.selected_languages, ["en", "zh", "th"]);
        assert_eq!(updated.common_caption_language, None);
    }

    #[test]
    fn profile_validation_supports_one_language_and_caps_the_ordered_columns_at_four() {
        let (_temp, store, notebook_id) = fixture();
        store.get_or_create_profile(&notebook_id).unwrap();
        let one_language = NotebookCaptureProfileUpdate {
            remote_realtime_enabled: true,
            capture_mode: CaptureMode::TranscriptionOnly,
            language_a: "th".into(),
            language_b: "en".into(),
            left_language: "th".into(),
            right_language: "en".into(),
            selected_languages: vec!["th".into()],
            common_caption_language: None,
            privacy_level: "standard".into(),
            send_context_to_soniox: false,
        };
        let updated = store
            .update_profile(&notebook_id, 0, &one_language)
            .unwrap();
        assert_eq!(updated.selected_languages, ["th"]);
        assert_eq!(
            (updated.language_a.as_str(), updated.language_b.as_str()),
            ("th", "en")
        );

        let (_temp, store, notebook_id) = fixture();
        store.get_or_create_profile(&notebook_id).unwrap();
        let too_many = NotebookCaptureProfileUpdate {
            remote_realtime_enabled: true,
            capture_mode: CaptureMode::MultilingualOneWay,
            language_a: "en".into(),
            language_b: "zh".into(),
            left_language: "en".into(),
            right_language: "zh".into(),
            selected_languages: ["en", "zh", "th", "ja", "ko"]
                .into_iter()
                .map(str::to_string)
                .collect(),
            common_caption_language: Some("en".into()),
            privacy_level: "standard".into(),
            send_context_to_soniox: false,
        };
        assert!(matches!(
            store.update_profile(&notebook_id, 0, &too_many),
            Err(NotebookCaptureStoreError::Validation(_))
        ));
    }

    #[test]
    fn completed_import_run_is_terminal_and_does_not_claim_active_capture() {
        let (_temp, store, notebook_id) = fixture();
        let profile = store.get_or_create_profile(&notebook_id).unwrap();
        let imported = new_import_run(&notebook_id, "local-default");

        let run = store
            .create_completed_import_run(&imported, &profile)
            .unwrap();

        assert_eq!(run.capture_state, CaptureState::Completed);
        assert_eq!(run.remote_health, RemoteHealth::Off);
        assert_eq!(run.projection_state, ProjectionState::Ready);
        assert_eq!(run.async_task_state, AsyncTaskState::None);
        assert_eq!(run.audio_journal_path, None);
        assert_eq!(
            run.audio_path.as_deref(),
            Some(imported.audio_path.as_str())
        );
        assert_eq!(
            run.audio_key_ref.as_deref(),
            Some(imported.audio_key_ref.as_str())
        );
        assert_eq!(run.sample_rate, Some(48_000));
        assert_eq!(run.channels, Some(2));
        assert_eq!(run.captured_frames, 96_000);
        assert!(run.completed_at.is_some());
        assert!(store.get_active_run().unwrap().is_none());
    }

    #[test]
    fn completed_import_run_requires_explicit_async_authorization() {
        let (_temp, store, notebook_id) = fixture();
        let profile = store.get_or_create_profile(&notebook_id).unwrap();

        let run = store
            .create_completed_import_run(&new_import_run(&notebook_id, "async-enabled"), &profile)
            .unwrap();

        assert_eq!(run.async_task_state, AsyncTaskState::None);
        let authorized = store
            .authorize_async_transcription(
                "import-session-async-enabled",
                1_700_000_000_001,
                Some("en"),
            )
            .unwrap();
        assert_eq!(authorized.async_task_state, AsyncTaskState::Pending);
        assert_eq!(authorized.async_authorized_at_ms, Some(1_700_000_000_001));
        assert_eq!(authorized.async_language_hint.as_deref(), Some("en"));
        assert_eq!(
            serde_json::from_str::<NotebookCaptureProfile>(&run.profile_snapshot_json).unwrap(),
            profile
        );
    }

    #[test]
    fn create_run_rejects_a_stale_authorized_profile_snapshot() {
        let (_temp, store, notebook_id) = fixture();
        let authorized = store.get_or_create_profile(&notebook_id).unwrap();
        assert_eq!(authorized.revision, 0);
        assert_eq!(authorized.privacy_level, "standard");

        let current = store
            .update_profile(
                &notebook_id,
                authorized.revision,
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

        let input = new_run(&notebook_id, "stale-profile");
        assert!(matches!(
            store.create_run(&input, &authorized),
            Err(NotebookCaptureStoreError::Conflict(_))
        ));
        assert!(store.get_run(&input.id).unwrap().is_none());

        let run = store.create_run(&input, &current).unwrap();
        assert_eq!(run.profile_revision, current.revision);
        assert_eq!(
            run.profile_snapshot_json,
            serde_json::to_string(&current).unwrap()
        );
        assert_eq!(run.async_task_state, AsyncTaskState::None);
    }

    #[test]
    fn atomic_session_and_run_creation_rolls_back_catalogue_and_privacy_on_run_failure() {
        let (temp, store, notebook_id) = fixture();
        let profile = store.get_or_create_profile(&notebook_id).unwrap();
        store
            .create_run(&new_run(&notebook_id, "existing-active"), &profile)
            .unwrap();
        let input = new_run(&notebook_id, "atomic-conflict");
        let session = SessionRecord {
            id: input.session_id.clone(),
            title: String::new(),
            session_type: "recording".into(),
            status: "recording".into(),
            duration_ms: 0,
            created_at: "2001-01-01 12:00:00".into(),
            deleted_at: None,
        };

        assert!(store
            .create_session_and_run(&session, &input, &profile)
            .is_err());

        let conn = rusqlite::Connection::open(temp.path().join("capture.db")).unwrap();
        let catalogue_count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM session_records WHERE id = ?1",
                [&session.id],
                |row| row.get(0),
            )
            .unwrap();
        let privacy_count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM session_meta WHERE session_id = ?1",
                [&session.id],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!((catalogue_count, privacy_count), (0, 0));
        assert!(store.get_run(&input.id).unwrap().is_none());
    }

    #[test]
    fn async_provider_receipt_requires_and_binds_post_stop_provenance() {
        let (_temp, store, notebook_id) = fixture();
        create_run(&store, &new_run(&notebook_id, "provider-binding")).unwrap();
        finish_run_ready(&store, "provider-binding");
        authorize_async_transcription(&store, "provider-binding");
        store
            .reserve_async_task(
                "run-provider-binding",
                "provider-binding-task",
                &"b".repeat(64),
            )
            .unwrap();
        store
            .mark_async_task_enqueued("run-provider-binding", "provider-binding-task")
            .unwrap();
        let token = Token {
            text: "bound".into(),
            start_ms: 0,
            end_ms: 100,
            is_final: true,
            language: "en".into(),
            speaker: None,
            confidence: 1.0,
            translation_status: vt_model::TranslationStatus::None,
        };
        let tokens = [token];
        let tokens_json = serde_json::to_string(&tokens).unwrap();
        let result_json = serde_json::json!({
            "session_id": "session-provider-binding",
            "token_count": 1,
            "full_text": "bound",
            "duration_ms": 100,
        })
        .to_string();

        assert!(matches!(
            store.commit_async_provider_success(
                "session-provider-binding",
                "provider-binding-task",
                &tokens,
                &result_json,
            ),
            Err(NotebookCaptureStoreError::Conflict(_))
        ));

        claim_post_stop(&store, "session-provider-binding");
        let receipt = store
            .commit_async_provider_success(
                "session-provider-binding",
                "provider-binding-task",
                &tokens,
                &result_json,
            )
            .unwrap();
        assert_eq!(receipt.provider_id, SONIOX_PROVIDER_ID);
        assert_eq!(receipt.model_id, SONIOX_STT_RT_V5_MODEL_ID);
        assert_eq!(
            receipt.output_sha256,
            async_provider_output_digest(
                "session-provider-binding",
                "provider-binding-task",
                SONIOX_PROVIDER_ID,
                SONIOX_STT_RT_V5_MODEL_ID,
                &tokens_json,
                &result_json,
            )
        );
        assert_ne!(
            receipt.output_sha256,
            async_provider_output_digest(
                "session-provider-binding",
                "provider-binding-task",
                SONIOX_PROVIDER_ID,
                "different-model",
                &tokens_json,
                &result_json,
            )
        );
        assert_eq!(
            store
                .get_async_provider_receipt("session-provider-binding", "provider-binding-task")
                .unwrap(),
            Some(receipt)
        );
    }

    #[test]
    fn provider_receipt_reads_fail_closed_for_every_bound_field() {
        for tamper in [
            ProviderReceiptTamper::Digest,
            ProviderReceiptTamper::ResultSession,
            ProviderReceiptTamper::Tokens,
            ProviderReceiptTamper::ProviderModel,
        ] {
            let (_temp, store, notebook_id) = fixture();
            let receipt = commit_provider_receipt_fixture(
                &store,
                &notebook_id,
                &format!("tamper-{tamper:?}"),
            );
            tamper_provider_receipt(&store, &receipt, tamper);

            let error = store
                .get_async_provider_receipt(&receipt.session_id, &receipt.task_id)
                .unwrap_err();
            assert!(
                matches!(error, NotebookCaptureStoreError::CorruptData(_)),
                "{tamper:?} must surface as corrupt data, got {error}"
            );

            let scan = store.list_async_provider_receipts().unwrap();
            assert!(scan.receipts.is_empty(), "{tamper:?} leaked as valid");
            assert_eq!(scan.corrupt.len(), 1, "{tamper:?} was not isolated");
            assert_eq!(scan.corrupt[0].session_id, receipt.session_id);
        }
    }

    #[test]
    fn provider_receipt_scan_keeps_unrelated_valid_sessions_recoverable() {
        let (_temp, store, notebook_id) = fixture();
        let corrupt = commit_provider_receipt_fixture(&store, &notebook_id, "scan-corrupt");
        let valid = commit_provider_receipt_fixture(&store, &notebook_id, "scan-valid");
        tamper_provider_receipt(&store, &corrupt, ProviderReceiptTamper::Digest);

        let scan = store.list_async_provider_receipts().unwrap();
        assert_eq!(scan.corrupt.len(), 1);
        assert_eq!(scan.corrupt[0].session_id, corrupt.session_id);
        assert_eq!(scan.receipts, vec![valid]);
    }

    #[test]
    fn provider_receipt_and_tokens_roll_back_as_one_transaction() {
        let (temp, store, notebook_id) = fixture();
        create_run(&store, &new_run(&notebook_id, "provider-atomic")).unwrap();
        store
            .transition_capture(
                "run-provider-atomic",
                CaptureState::Recording,
                CaptureState::Draining,
            )
            .unwrap();
        store
            .finalize_audio(
                "run-provider-atomic",
                "/tmp/provider-atomic.chunk.00000.enc",
                16_000,
            )
            .unwrap();
        store
            .transition_capture(
                "run-provider-atomic",
                CaptureState::Draining,
                CaptureState::Completed,
            )
            .unwrap();
        authorize_async_transcription(&store, "provider-atomic");
        claim_post_stop(&store, "session-provider-atomic");
        store
            .reserve_async_task("run-provider-atomic", "provider-task", &"a".repeat(64))
            .unwrap();
        store
            .mark_async_task_enqueued("run-provider-atomic", "provider-task")
            .unwrap();
        crate::SessionMetaStore::new(&temp.path().join("capture.db"))
            .unwrap()
            .set_privacy_level("session-provider-atomic", "standard")
            .unwrap();
        let token = Token {
            text: "hello".into(),
            start_ms: 0,
            end_ms: 100,
            is_final: true,
            language: "en".into(),
            speaker: None,
            confidence: 1.0,
            translation_status: vt_model::TranslationStatus::None,
        };
        let result_json = serde_json::json!({
            "session_id": "session-provider-atomic",
            "token_count": 1,
            "full_text": "hello",
            "duration_ms": 100,
        })
        .to_string();

        assert!(store
            .commit_async_provider_success_with_hook(
                "session-provider-atomic",
                "provider-task",
                &[token],
                &result_json,
                || Err(NotebookCaptureStoreError::Validation(
                    "injected receipt failure".into()
                )),
            )
            .is_err());
        assert!(store
            .get_async_provider_receipt("session-provider-atomic", "provider-task")
            .unwrap()
            .is_none());
        assert!(
            crate::SessionMetaStore::new(&temp.path().join("capture.db"))
                .unwrap()
                .get_meta("session-provider-atomic")
                .unwrap()
                .tokens_json
                .is_none()
        );
    }

    #[test]
    fn local_persistence_interruption_never_creates_async_authorization() {
        let (_temp, store, notebook_id) = fixture();
        store.get_or_create_profile(&notebook_id).unwrap();
        create_run(&store, &new_run(&notebook_id, "local-failure")).unwrap();

        let interrupted = store
            .interrupt_local_persistence(
                "run-local-failure",
                CaptureState::Recording,
                &ProviderFailure {
                    error_type: "local_persistence".into(),
                    request_id: None,
                },
            )
            .unwrap();
        assert_eq!(interrupted.capture_state, CaptureState::Interrupted);
        assert_eq!(interrupted.async_task_state, AsyncTaskState::None);
        assert!(interrupted.async_authorized_at_ms.is_none());
        assert!(interrupted.async_language_hint.is_none());
        assert!(interrupted.async_task_id.is_none());
        assert!(interrupted.async_task_payload_sha256.is_none());
    }

    #[test]
    fn startup_recovery_never_invents_async_authorization() {
        let (temp, store, notebook_id) = fixture();
        let db = temp.path().join("capture.db");
        store.get_or_create_profile(&notebook_id).unwrap();
        create_run(&store, &new_run(&notebook_id, "recovery-async")).unwrap();
        drop(store);

        let reopened = NotebookCaptureStore::new(&db).unwrap();
        reopened.recover_unfinished_runs().unwrap();
        let recovered = reopened.get_run("run-recovery-async").unwrap().unwrap();
        assert_eq!(recovered.capture_state, CaptureState::Interrupted);
        assert_eq!(recovered.async_task_state, AsyncTaskState::None);
        assert!(recovered.async_authorized_at_ms.is_none());
        assert!(recovered.async_task_id.is_none());
    }

    #[test]
    fn globally_allows_only_one_active_capture() {
        let (_temp, store, notebook_id) = fixture();
        store.get_or_create_profile(&notebook_id).unwrap();
        create_run(&store, &new_run(&notebook_id, "a")).unwrap();
        assert!(create_run(&store, &new_run(&notebook_id, "b")).is_err());
        store
            .transition_capture("run-a", CaptureState::Recording, CaptureState::Draining)
            .unwrap();
        store
            .transition_capture("run-a", CaptureState::Draining, CaptureState::Completed)
            .unwrap();
        create_run(&store, &new_run(&notebook_id, "b")).unwrap();
    }

    #[test]
    fn async_task_outbox_is_explicit_idempotent_and_durable_across_reopen() {
        let (temp, store, notebook_id) = fixture();
        let db = temp.path().join("capture.db");
        store.get_or_create_profile(&notebook_id).unwrap();

        let local_only = create_run(&store, &new_run(&notebook_id, "async-off")).unwrap();
        assert_eq!(local_only.async_task_state, AsyncTaskState::None);
        assert!(local_only.async_task_id.is_none());
        assert!(local_only.async_task_payload_sha256.is_none());
        store
            .transition_capture(
                "run-async-off",
                CaptureState::Recording,
                CaptureState::Draining,
            )
            .unwrap();
        store
            .transition_capture(
                "run-async-off",
                CaptureState::Draining,
                CaptureState::Completed,
            )
            .unwrap();
        assert!(matches!(
            store.reserve_async_task("run-async-off", "task-off", &"a".repeat(64)),
            Err(NotebookCaptureStoreError::Conflict(_))
        ));

        let pending = create_run(&store, &new_run(&notebook_id, "async-outbox")).unwrap();
        assert_eq!(pending.async_task_state, AsyncTaskState::None);
        assert!(matches!(
            store.reserve_async_task("run-async-outbox", "stable-task", &"a".repeat(64)),
            Err(NotebookCaptureStoreError::Conflict(_))
        ));
        store
            .transition_capture(
                "run-async-outbox",
                CaptureState::Recording,
                CaptureState::Draining,
            )
            .unwrap();
        store
            .finalize_audio(
                "run-async-outbox",
                "/tmp/async-outbox.chunk.00000.enc",
                16_000,
            )
            .unwrap();
        store
            .transition_capture(
                "run-async-outbox",
                CaptureState::Draining,
                CaptureState::Completed,
            )
            .unwrap();
        let pending = authorize_async_transcription(&store, "async-outbox");
        assert_eq!(pending.async_task_state, AsyncTaskState::Pending);
        assert_eq!(pending.async_authorized_at_ms, Some(1_700_000_000_000));
        assert!(matches!(
            store.reserve_async_task("run-async-outbox", "stable-task", "not-a-digest"),
            Err(NotebookCaptureStoreError::Validation(_))
        ));

        drop(store);
        let store = NotebookCaptureStore::new(&db).unwrap();
        assert_eq!(
            store
                .get_run("run-async-outbox")
                .unwrap()
                .unwrap()
                .async_task_state,
            AsyncTaskState::Pending,
            "a completed pending run remains safe for explicit compensation"
        );

        let digest = "a".repeat(64);
        let reserved = store
            .reserve_async_task("run-async-outbox", "stable-task", &digest)
            .unwrap();
        assert_eq!(reserved.async_task_state, AsyncTaskState::Reserved);
        assert_eq!(reserved.async_task_id.as_deref(), Some("stable-task"));
        assert_eq!(
            reserved.async_task_payload_sha256.as_deref(),
            Some(digest.as_str())
        );
        assert_eq!(
            store
                .reserve_async_task("run-async-outbox", "stable-task", &digest)
                .unwrap(),
            reserved
        );
        assert!(matches!(
            store.reserve_async_task("run-async-outbox", "other-task", &digest),
            Err(NotebookCaptureStoreError::Conflict(_))
        ));

        drop(store);
        let store = NotebookCaptureStore::new(&db).unwrap();
        assert_eq!(
            store
                .get_run("run-async-outbox")
                .unwrap()
                .unwrap()
                .async_task_state,
            AsyncTaskState::Reserved,
            "a reserved receipt must not be reset and implicitly re-enqueued"
        );
        assert!(matches!(
            store.mark_async_task_enqueued("run-async-outbox", "other-task"),
            Err(NotebookCaptureStoreError::Conflict(_))
        ));
        let enqueued = store
            .mark_async_task_enqueued("run-async-outbox", "stable-task")
            .unwrap();
        assert_eq!(enqueued.async_task_state, AsyncTaskState::Enqueued);
        assert_eq!(
            store
                .mark_async_task_enqueued("run-async-outbox", "stable-task")
                .unwrap(),
            enqueued
        );

        drop(store);
        let store = NotebookCaptureStore::new(&db).unwrap();
        assert_eq!(
            store
                .get_run("run-async-outbox")
                .unwrap()
                .unwrap()
                .async_task_state,
            AsyncTaskState::Enqueued,
            "an enqueued receipt must not be reset when tasks.db is unavailable"
        );
        assert!(matches!(
            store.mark_async_task_terminal_for_session("session-async-outbox", "other-task", true),
            Err(NotebookCaptureStoreError::Conflict(_))
        ));
        let completed = store
            .mark_async_task_terminal_for_session("session-async-outbox", "stable-task", true)
            .unwrap();
        assert_eq!(completed.async_task_state, AsyncTaskState::Completed);
        assert_eq!(
            completed.async_projection_state,
            AsyncProjectionState::Pending,
            "provider completion schedules only the independent local projection"
        );
        assert_eq!(
            store
                .mark_async_task_terminal_for_session("session-async-outbox", "stable-task", true,)
                .unwrap(),
            completed
        );
        assert!(matches!(
            store.mark_async_task_terminal_for_session(
                "session-async-outbox",
                "stable-task",
                false
            ),
            Err(NotebookCaptureStoreError::Conflict(_))
        ));
    }

    #[test]
    fn async_task_terminal_failure_keeps_the_stable_receipt() {
        let (_temp, store, notebook_id) = fixture();
        create_run(&store, &new_run(&notebook_id, "async-failed")).unwrap();
        store
            .transition_capture(
                "run-async-failed",
                CaptureState::Recording,
                CaptureState::Draining,
            )
            .unwrap();
        store
            .finalize_audio(
                "run-async-failed",
                "/tmp/async-failed.chunk.00000.enc",
                16_000,
            )
            .unwrap();
        store
            .transition_capture(
                "run-async-failed",
                CaptureState::Draining,
                CaptureState::Completed,
            )
            .unwrap();
        authorize_async_transcription(&store, "async-failed");
        let digest = "b".repeat(64);
        store
            .reserve_async_task("run-async-failed", "failed-task", &digest)
            .unwrap();
        store
            .mark_async_task_enqueued("run-async-failed", "failed-task")
            .unwrap();
        let failed = store
            .mark_async_task_terminal_for_session("session-async-failed", "failed-task", false)
            .unwrap();
        assert_eq!(failed.async_task_state, AsyncTaskState::Failed);
        assert_eq!(
            failed.async_projection_state,
            AsyncProjectionState::None,
            "failed provider work must not create local projection work"
        );
        assert_eq!(failed.async_task_id.as_deref(), Some("failed-task"));
        assert_eq!(
            failed.async_task_payload_sha256.as_deref(),
            Some(digest.as_str())
        );
    }

    #[test]
    fn async_projection_failure_and_retry_never_reopen_completed_provider_work() {
        let (_temp, store, notebook_id) = fixture();
        create_run(&store, &new_run(&notebook_id, "async-projection-retry")).unwrap();
        finish_run_ready(&store, "async-projection-retry");
        authorize_async_transcription(&store, "async-projection-retry");

        let digest = "c".repeat(64);
        store
            .reserve_async_task("run-async-projection-retry", "provider-task", &digest)
            .unwrap();
        store
            .mark_async_task_enqueued("run-async-projection-retry", "provider-task")
            .unwrap();
        let provider_complete = store
            .mark_async_task_terminal_for_session(
                "session-async-projection-retry",
                "provider-task",
                true,
            )
            .unwrap();
        assert_eq!(
            (
                provider_complete.async_task_state,
                provider_complete.async_projection_state,
            ),
            (AsyncTaskState::Completed, AsyncProjectionState::Pending)
        );

        store
            .set_async_projection_state(
                "run-async-projection-retry",
                AsyncProjectionState::Pending,
                AsyncProjectionState::Projecting,
            )
            .unwrap();
        let failed_projection = store
            .set_async_projection_state(
                "run-async-projection-retry",
                AsyncProjectionState::Projecting,
                AsyncProjectionState::Failed,
            )
            .unwrap();
        assert_eq!(
            failed_projection.async_task_state,
            AsyncTaskState::Completed
        );
        assert_eq!(
            failed_projection.async_projection_state,
            AsyncProjectionState::Failed
        );

        let pending_retry = store
            .retry_async_projection("run-async-projection-retry")
            .unwrap();
        assert_eq!(pending_retry.async_task_state, AsyncTaskState::Completed);
        assert_eq!(
            pending_retry.async_task_id.as_deref(),
            Some("provider-task"),
            "a local retry preserves the one completed provider receipt"
        );
        assert_eq!(
            store
                .list_pending_async_projections()
                .unwrap()
                .into_iter()
                .map(|run| run.id)
                .collect::<Vec<_>>(),
            vec!["run-async-projection-retry"]
        );

        store
            .set_async_projection_state(
                "run-async-projection-retry",
                AsyncProjectionState::Pending,
                AsyncProjectionState::Projecting,
            )
            .unwrap();
        store
            .complete_async_projection_unless_purging("run-async-projection-retry")
            .unwrap();
        let ready = store
            .get_run("run-async-projection-retry")
            .unwrap()
            .unwrap();
        assert_eq!(ready.async_task_state, AsyncTaskState::Completed);
        assert_eq!(ready.async_projection_state, AsyncProjectionState::Ready);
    }

    #[test]
    fn startup_marks_stale_async_projection_failed_without_reopening_provider_work() {
        let (temp, store, notebook_id) = fixture();
        let db = temp.path().join("capture.db");
        create_run(&store, &new_run(&notebook_id, "async-projecting-recover")).unwrap();
        finish_run_ready(&store, "async-projecting-recover");
        authorize_async_transcription(&store, "async-projecting-recover");
        let digest = "d".repeat(64);
        store
            .reserve_async_task("run-async-projecting-recover", "provider-task", &digest)
            .unwrap();
        store
            .mark_async_task_enqueued("run-async-projecting-recover", "provider-task")
            .unwrap();
        store
            .mark_async_task_terminal_for_session(
                "session-async-projecting-recover",
                "provider-task",
                true,
            )
            .unwrap();
        store
            .set_async_projection_state(
                "run-async-projecting-recover",
                AsyncProjectionState::Pending,
                AsyncProjectionState::Projecting,
            )
            .unwrap();
        drop(store);

        let reopened = NotebookCaptureStore::new(&db).unwrap();
        reopened.recover_unfinished_runs().unwrap();
        let recovered = reopened
            .get_run("run-async-projecting-recover")
            .unwrap()
            .unwrap();
        assert_eq!(recovered.capture_state, CaptureState::Completed);
        assert_eq!(recovered.async_task_state, AsyncTaskState::Completed);
        assert_eq!(
            recovered.async_projection_state,
            AsyncProjectionState::Failed
        );
        assert!(reopened
            .list_pending_async_projections()
            .unwrap()
            .is_empty());
    }

    #[test]
    fn reopening_marks_unfinished_run_interrupted_without_losing_audio_references() {
        let (temp, store, notebook_id) = fixture();
        let db = temp.path().join("capture.db");
        store.get_or_create_profile(&notebook_id).unwrap();
        create_run(&store, &new_run(&notebook_id, "recover")).unwrap();
        drop(store);

        let reopened = NotebookCaptureStore::new(&db).unwrap();
        assert_eq!(
            reopened
                .get_run("run-recover")
                .unwrap()
                .unwrap()
                .capture_state,
            CaptureState::Recording,
            "opening a store connection must not steal capture ownership"
        );
        reopened.recover_unfinished_runs().unwrap();
        let run = reopened.get_run("run-recover").unwrap().unwrap();
        assert_eq!(run.capture_state, CaptureState::Interrupted);
        assert_eq!(run.remote_health, RemoteHealth::Off);
        assert_eq!(
            run.audio_journal_path.as_deref(),
            Some("/tmp/recover.journal")
        );
        assert_eq!(run.audio_key_ref.as_deref(), Some("audio-key-recover"));
    }

    #[test]
    fn reopening_marks_stale_projection_failed_and_lists_completed_runs() {
        let (temp, store, notebook_id) = fixture();
        let db = temp.path().join("capture.db");
        store.get_or_create_profile(&notebook_id).unwrap();
        create_run(&store, &new_run(&notebook_id, "projecting-recover")).unwrap();
        store
            .transition_capture(
                "run-projecting-recover",
                CaptureState::Recording,
                CaptureState::Draining,
            )
            .unwrap();
        store
            .transition_capture(
                "run-projecting-recover",
                CaptureState::Draining,
                CaptureState::Completed,
            )
            .unwrap();
        store
            .set_projection_state(
                "run-projecting-recover",
                ProjectionState::Pending,
                ProjectionState::Projecting,
            )
            .unwrap();
        drop(store);

        let reopened = NotebookCaptureStore::new(&db).unwrap();
        reopened.recover_unfinished_runs().unwrap();
        let run = reopened.get_run("run-projecting-recover").unwrap().unwrap();
        assert_eq!(run.capture_state, CaptureState::Completed);
        assert_eq!(run.projection_state, ProjectionState::Failed);
        assert_eq!(
            reopened
                .list_completed_runs()
                .unwrap()
                .into_iter()
                .map(|run| run.id)
                .collect::<Vec<_>>(),
            vec!["run-projecting-recover"]
        );
    }

    #[test]
    fn startup_async_compensation_query_excludes_terminal_history() {
        let (_temp, store, notebook_id) = fixture();

        create_run(&store, &new_run(&notebook_id, "async-pending")).unwrap();
        finish_run_ready(&store, "async-pending");
        authorize_async_transcription(&store, "async-pending");

        create_run(&store, &new_run(&notebook_id, "async-completed")).unwrap();
        finish_run_ready(&store, "async-completed");
        authorize_async_transcription(&store, "async-completed");
        let digest = "a".repeat(64);
        store
            .reserve_async_task("run-async-completed", "task-completed", &digest)
            .unwrap();
        store
            .mark_async_task_enqueued("run-async-completed", "task-completed")
            .unwrap();
        let completed = store
            .mark_async_task_terminal_for_session("session-async-completed", "task-completed", true)
            .unwrap();
        assert_eq!(completed.async_task_state, AsyncTaskState::Completed);

        let candidates = store
            .list_completed_runs_requiring_async_compensation()
            .unwrap()
            .into_iter()
            .map(|run| run.id)
            .collect::<Vec<_>>();
        assert_eq!(candidates, vec!["run-async-pending"]);
    }

    #[test]
    fn remote_failure_does_not_end_local_capture() {
        let (_temp, store, notebook_id) = fixture();
        store.get_or_create_profile(&notebook_id).unwrap();
        create_run(&store, &new_run(&notebook_id, "remote")).unwrap();
        let run = store
            .update_remote_health(
                "run-remote",
                RemoteHealth::Degraded,
                Some(&ProviderFailure {
                    error_type: "provider_unavailable".into(),
                    request_id: Some("req-1".into()),
                }),
            )
            .unwrap();
        assert_eq!(run.capture_state, CaptureState::Recording);
        assert_eq!(run.remote_health, RemoteHealth::Degraded);
        assert_eq!(run.provider_request_id.as_deref(), Some("req-1"));
    }

    #[test]
    fn anonymous_speakers_are_epoch_scoped_and_manually_linkable_across_sessions() {
        let (_temp, store, notebook_id) = fixture();
        store.get_or_create_profile(&notebook_id).unwrap();
        create_run(&store, &new_run(&notebook_id, "speaker-a")).unwrap();

        let first = store
            .ensure_session_speaker("session-speaker-a", 0, "soniox", "1")
            .unwrap();
        let repeated = store
            .ensure_session_speaker("session-speaker-a", 0, "soniox", "1")
            .unwrap();
        assert_eq!(repeated.id, first.id);
        let after_reconnect = store
            .ensure_session_speaker("session-speaker-a", 1, "soniox", "1")
            .unwrap();
        assert_ne!(after_reconnect.id, first.id);

        let renamed = store
            .rename_session_speaker(&first.id, Some("现场主持人"))
            .unwrap();
        assert_eq!(renamed.local_display_name.as_deref(), Some("现场主持人"));
        let participant = store.create_participant("主持人").unwrap();
        let participant = store.rename_participant(&participant.id, "主持人").unwrap();
        assert_eq!(
            store.list_participants().unwrap(),
            vec![participant.clone()]
        );
        let first = store
            .link_session_speaker(&first.id, &participant.id)
            .unwrap();
        assert_eq!(
            first.participant_id.as_deref(),
            Some(participant.id.as_str())
        );
        assert!(first.participant_linked_at.is_some());
        let first = store.unlink_session_speaker(&first.id).unwrap();
        assert_eq!(first.participant_id, None);
        assert_eq!(first.participant_linked_at, None);
        let first = store
            .link_session_speaker(&first.id, &participant.id)
            .unwrap();

        finish_run_ready(&store, "speaker-a");
        create_run(&store, &new_run(&notebook_id, "speaker-b")).unwrap();
        claim_realtime(&store, "session-speaker-b");
        let second = store
            .ensure_session_speaker("session-speaker-b", 0, "soniox", "2")
            .unwrap();
        let second = store
            .link_session_speaker(&second.id, &participant.id)
            .unwrap();
        assert_eq!(
            second.participant_id.as_deref(),
            Some(participant.id.as_str())
        );

        let wrong_session = store.upsert_utterance(
            &NewRealtimeUtterance {
                id: "speaker-cross-session".into(),
                session_id: "session-speaker-b".into(),
                sequence: 0,
                session_speaker_id: Some(first.id.clone()),
                source_language: "th".into(),
                source_text: "สวัสดี".into(),
                source_start_ms: Some(0),
                source_end_ms: Some(100),
                translated_language: Some("zh".into()),
                translated_text: Some("你好".into()),
                completion: UtteranceCompletion::Complete,
                alignment: UtteranceAlignment::Paired,
            },
            None,
        );
        assert!(matches!(
            wrong_session,
            Err(NotebookCaptureStoreError::Validation(_))
        ));

        let utterance = store
            .upsert_utterance(
                &NewRealtimeUtterance {
                    id: "speaker-language-agnostic".into(),
                    session_id: "session-speaker-b".into(),
                    sequence: 0,
                    session_speaker_id: Some(second.id.clone()),
                    source_language: "th".into(),
                    source_text: "สวัสดี".into(),
                    source_start_ms: Some(0),
                    source_end_ms: Some(100),
                    translated_language: Some("zh".into()),
                    translated_text: Some("你好".into()),
                    completion: UtteranceCompletion::Complete,
                    alignment: UtteranceAlignment::Paired,
                },
                None,
            )
            .unwrap();
        assert_eq!(
            utterance.session_speaker_id.as_deref(),
            Some(second.id.as_str())
        );
        assert_eq!(utterance.source_language, "th");

        store.purge_session_artifacts("session-speaker-a").unwrap();
        assert!(store.get_session_speaker(&first.id).unwrap().is_none());
        assert!(store
            .get_session_speaker(&after_reconnect.id)
            .unwrap()
            .is_none());
        assert!(store.get_participant(&participant.id).unwrap().is_some());
        assert_eq!(
            store
                .get_session_speaker(&second.id)
                .unwrap()
                .unwrap()
                .participant_id
                .as_deref(),
            Some(participant.id.as_str())
        );

        assert!(store.delete_participant(&participant.id).unwrap());
        assert!(!store.delete_participant(&participant.id).unwrap());
        let unlinked = store.get_session_speaker(&second.id).unwrap().unwrap();
        assert_eq!(unlinked.participant_id, None);
        assert_eq!(unlinked.participant_linked_at, None);

        assert!(store.delete_session_speaker(&second.id).unwrap());
        assert!(!store.delete_session_speaker(&second.id).unwrap());
        let retained = store
            .get_utterance_by_id("speaker-language-agnostic")
            .unwrap()
            .unwrap();
        assert_eq!(retained.session_speaker_id, None);
    }

    #[test]
    fn completed_translated_lane_is_editable_while_capture_remains_active() {
        let (_temp, store, notebook_id) = fixture();
        store.get_or_create_profile(&notebook_id).unwrap();
        create_run(&store, &new_run(&notebook_id, "utterance")).unwrap();
        claim_realtime(&store, "session-utterance");
        let utterance = store
            .upsert_utterance(
                &NewRealtimeUtterance {
                    id: "utt-1".into(),
                    session_id: "session-utterance".into(),
                    sequence: 0,
                    session_speaker_id: None,
                    source_language: "en".into(),
                    source_text: "hello".into(),
                    source_start_ms: Some(10),
                    source_end_ms: Some(50),
                    translated_language: Some("zh".into()),
                    translated_text: Some("你好".into()),
                    completion: UtteranceCompletion::Complete,
                    alignment: UtteranceAlignment::Paired,
                },
                None,
            )
            .unwrap();
        assert_eq!(utterance.source_start_ms, Some(10));
        assert_eq!(utterance.variants.len(), 2);
        assert_eq!(
            utterance
                .variants
                .iter()
                .map(|variant| (
                    variant.language.as_str(),
                    variant.role,
                    variant.text.as_deref(),
                    variant.state,
                ))
                .collect::<Vec<_>>(),
            vec![
                (
                    "en",
                    UtteranceVariantRole::Source,
                    Some("hello"),
                    UtteranceVariantState::Ready,
                ),
                (
                    "zh",
                    UtteranceVariantRole::Translation,
                    Some("你好"),
                    UtteranceVariantState::Ready,
                ),
            ]
        );
        let active_edit = store
            .stage_utterance_lane_replacement("utt-1", UtteranceLane::Translated, "您好", 0)
            .unwrap();
        store.cancel_projection_mutation(&active_edit.id).unwrap();

        store
            .transition_capture(
                "run-utterance",
                CaptureState::Recording,
                CaptureState::Draining,
            )
            .unwrap();
        store
            .transition_capture(
                "run-utterance",
                CaptureState::Draining,
                CaptureState::Completed,
            )
            .unwrap();
        store
            .set_projection_state(
                "run-utterance",
                ProjectionState::Pending,
                ProjectionState::Projecting,
            )
            .unwrap();
        store
            .set_projection_state(
                "run-utterance",
                ProjectionState::Projecting,
                ProjectionState::Ready,
            )
            .unwrap();
        let mutation = store
            .stage_utterance_lane_replacement("utt-1", UtteranceLane::Translated, "您好", 0)
            .unwrap();
        assert_eq!(mutation.lane_language, "zh");
        let edited = store.commit_projection_mutation(&mutation.id).unwrap();
        assert_eq!(edited.translated_text.as_deref(), Some("您好"));
        assert_eq!(
            edited
                .variants
                .iter()
                .find(|variant| variant.language == "zh")
                .and_then(|variant| variant.text.as_deref()),
            Some("您好")
        );
        assert_eq!(edited.source_start_ms, Some(10));
        assert_eq!(edited.revision, 1);
    }

    #[test]
    fn multilingual_variants_track_waiting_ready_failures_and_language_edits() {
        let (_temp, store, notebook_id) = fixture();
        store.get_or_create_profile(&notebook_id).unwrap();
        create_catalogued_run(&store, &notebook_id, "variants");
        claim_realtime(&store, "session-variants");
        let canonical = store
            .upsert_utterance(
                &NewRealtimeUtterance {
                    id: "utt-variants".into(),
                    session_id: "session-variants".into(),
                    sequence: 7,
                    session_speaker_id: None,
                    source_language: "zh".into(),
                    source_text: "欢迎".into(),
                    source_start_ms: Some(100),
                    source_end_ms: Some(500),
                    translated_language: Some("th".into()),
                    translated_text: Some("ยินดีต้อนรับ".into()),
                    completion: UtteranceCompletion::Complete,
                    alignment: UtteranceAlignment::Paired,
                },
                None,
            )
            .unwrap();
        assert_eq!(canonical.revision, 0);

        let waiting = store
            .upsert_translation_variant(
                "session-variants",
                7,
                "EN",
                None,
                UtteranceVariantState::Waiting,
                None,
            )
            .unwrap();
        assert_eq!(waiting.revision, 0, "extra target revisions are isolated");
        let en = waiting
            .variants
            .iter()
            .find(|variant| variant.language == "en")
            .unwrap();
        assert_eq!(en.state, UtteranceVariantState::Waiting);
        assert_eq!(en.text, None);
        assert_eq!(en.completion, None);

        assert!(matches!(
            store.upsert_translation_variant(
                "session-variants",
                7,
                "en",
                None,
                UtteranceVariantState::Ready,
                Some(UtteranceCompletion::Complete),
            ),
            Err(NotebookCaptureStoreError::Validation(_))
        ));

        let failed = store
            .upsert_translation_variant(
                "session-variants",
                7,
                "en",
                None,
                UtteranceVariantState::Failed,
                None,
            )
            .unwrap();
        assert_eq!(
            failed
                .variants
                .iter()
                .find(|variant| variant.language == "en")
                .unwrap()
                .state,
            UtteranceVariantState::Failed
        );
        let ready = store
            .upsert_translation_variant(
                "session-variants",
                7,
                "en",
                Some("Welcome"),
                UtteranceVariantState::Ready,
                Some(UtteranceCompletion::Complete),
            )
            .unwrap();
        let en = ready
            .variants
            .iter()
            .find(|variant| variant.language == "en")
            .unwrap();
        assert_eq!(en.text.as_deref(), Some("Welcome"));
        assert_eq!(en.revision, 2);
        let unavailable = store
            .upsert_translation_variant(
                "session-variants",
                7,
                "ja",
                None,
                UtteranceVariantState::Unavailable,
                None,
            )
            .unwrap();
        assert_eq!(
            unavailable
                .variants
                .iter()
                .find(|variant| variant.language == "ja")
                .unwrap()
                .state,
            UtteranceVariantState::Unavailable
        );

        assert_eq!(
            store.list_utterances("session-variants").unwrap()[0]
                .variants
                .len(),
            4
        );
        assert_eq!(
            store
                .get_utterance_by_id("utt-variants")
                .unwrap()
                .unwrap()
                .variants
                .len(),
            4
        );
        assert_eq!(
            store.list_notebook_capture_history(&notebook_id).unwrap()[0].utterances[0]
                .variants
                .len(),
            4
        );

        finish_run_ready(&store, "variants");
        let staged = store
            .stage_utterance_variant_replacement("utt-variants", "EN", "Welcome!", 0)
            .unwrap();
        assert_eq!(staged.lane, UtteranceLane::Translated);
        assert_eq!(staged.lane_language, "en");
        let edited = store.commit_projection_mutation(&staged.id).unwrap();
        assert_eq!(edited.revision, 1);
        assert_eq!(
            edited
                .variants
                .iter()
                .find(|variant| variant.language == "en")
                .and_then(|variant| variant.text.as_deref()),
            Some("Welcome!")
        );
        assert_eq!(
            edited.translated_text.as_deref(),
            Some("ยินดีต้อนรับ"),
            "editing an extra target must not overwrite the legacy translated shadow"
        );
        assert!(matches!(
            store.stage_utterance_variant_replacement(
                "utt-variants",
                "ja",
                "利用不可",
                edited.revision,
            ),
            Err(NotebookCaptureStoreError::Conflict(_))
        ));
    }

    #[test]
    fn source_language_revision_replaces_a_colliding_translation_variant() {
        let (_temp, store, notebook_id) = fixture();
        store.get_or_create_profile(&notebook_id).unwrap();
        create_catalogued_run(&store, &notebook_id, "language-revision");
        claim_realtime(&store, "session-language-revision");

        let initial = store
            .upsert_utterance(
                &NewRealtimeUtterance {
                    id: "utt-language-revision".into(),
                    session_id: "session-language-revision".into(),
                    sequence: 0,
                    session_speaker_id: None,
                    source_language: "en".into(),
                    source_text: "partial".into(),
                    source_start_ms: Some(0),
                    source_end_ms: Some(200),
                    translated_language: Some("zh".into()),
                    translated_text: Some("片段".into()),
                    completion: UtteranceCompletion::Partial,
                    alignment: UtteranceAlignment::Paired,
                },
                None,
            )
            .unwrap();

        let revised = store
            .upsert_utterance(
                &NewRealtimeUtterance {
                    id: initial.id.clone(),
                    session_id: initial.session_id.clone(),
                    sequence: initial.sequence,
                    session_speaker_id: None,
                    source_language: "ZH".into(),
                    source_text: "这是中文".into(),
                    source_start_ms: Some(0),
                    source_end_ms: Some(500),
                    translated_language: Some("th".into()),
                    translated_text: Some("นี่คือภาษาจีน".into()),
                    completion: UtteranceCompletion::Complete,
                    alignment: UtteranceAlignment::Paired,
                },
                Some(initial.revision),
            )
            .unwrap();

        assert_eq!(revised.source_language, "ZH");
        assert_eq!(revised.translated_language.as_deref(), Some("th"));
        assert_eq!(revised.variants.len(), 2);
        assert!(revised.variants.iter().any(|variant| {
            variant.language == "zh"
                && variant.role == UtteranceVariantRole::Source
                && variant.text.as_deref() == Some("这是中文")
        }));
        assert!(revised.variants.iter().any(|variant| {
            variant.language == "th"
                && variant.role == UtteranceVariantRole::Translation
                && variant.text.as_deref() == Some("นี่คือภาษาจีน")
        }));
        assert!(!revised
            .variants
            .iter()
            .any(|variant| variant.language == "en"));
    }

    #[test]
    fn durable_lane_mutation_stages_without_editing_then_commits_text_only() {
        let (_temp, store, notebook_id) = fixture();
        store.get_or_create_profile(&notebook_id).unwrap();
        create_run(&store, &new_run(&notebook_id, "saga")).unwrap();
        claim_realtime(&store, "session-saga");
        store
            .upsert_utterance(
                &NewRealtimeUtterance {
                    id: "utt-saga".into(),
                    session_id: "session-saga".into(),
                    sequence: 0,
                    session_speaker_id: None,
                    source_language: "en-US".into(),
                    source_text: "hello".into(),
                    source_start_ms: Some(10),
                    source_end_ms: Some(50),
                    translated_language: Some("zh-Hant".into()),
                    translated_text: Some("你好".into()),
                    completion: UtteranceCompletion::Complete,
                    alignment: UtteranceAlignment::Paired,
                },
                None,
            )
            .unwrap();
        finish_run_ready(&store, "saga");

        let staged = store
            .stage_utterance_lane_replacement("utt-saga", UtteranceLane::Translated, "您好", 0)
            .unwrap();
        assert_eq!(staged.session_id, "session-saga");
        assert_eq!(staged.lane, UtteranceLane::Translated);
        assert_eq!(staged.lane_language, "zh-Hant");
        assert_eq!(staged.state, ProjectionMutationState::Pending);
        let unchanged = store.get_utterance_by_id("utt-saga").unwrap().unwrap();
        assert_eq!(unchanged.translated_text.as_deref(), Some("你好"));
        assert_eq!(unchanged.revision, 0);

        let idempotent = store
            .stage_utterance_lane_replacement("utt-saga", UtteranceLane::Translated, "您好", 0)
            .unwrap();
        assert_eq!(idempotent.id, staged.id);
        assert!(matches!(
            store.stage_utterance_lane_replacement(
                "utt-saga",
                UtteranceLane::Translated,
                "不同目标",
                0
            ),
            Err(NotebookCaptureStoreError::Conflict(_))
        ));

        let committed = store.commit_projection_mutation(&staged.id).unwrap();
        assert_eq!(committed.translated_text.as_deref(), Some("您好"));
        assert_eq!(committed.translated_language.as_deref(), Some("zh-Hant"));
        assert_eq!(committed.source_language, "en-US");
        assert_eq!(committed.source_start_ms, Some(10));
        assert_eq!(committed.revision, 1);
        assert!(store
            .list_pending_projection_mutations()
            .unwrap()
            .is_empty());
    }

    #[test]
    fn durable_lane_mutation_conflicts_are_fail_closed_and_cancel_is_idempotent() {
        let (_temp, store, notebook_id) = fixture();
        store.get_or_create_profile(&notebook_id).unwrap();
        create_run(&store, &new_run(&notebook_id, "saga-conflict")).unwrap();
        claim_realtime(&store, "session-saga-conflict");
        store
            .upsert_utterance(
                &NewRealtimeUtterance {
                    id: "utt-saga-conflict".into(),
                    session_id: "session-saga-conflict".into(),
                    sequence: 0,
                    session_speaker_id: None,
                    source_language: "en".into(),
                    source_text: "old".into(),
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
        let active_edit = store
            .stage_utterance_lane_replacement("utt-saga-conflict", UtteranceLane::Source, "new", 0)
            .unwrap();
        store.cancel_projection_mutation(&active_edit.id).unwrap();
        finish_run_ready(&store, "saga-conflict");
        assert!(matches!(
            store.stage_utterance_lane_replacement(
                "utt-saga-conflict",
                UtteranceLane::Translated,
                "missing",
                0
            ),
            Err(NotebookCaptureStoreError::Conflict(_))
        ));
        assert!(matches!(
            store.stage_utterance_lane_replacement(
                "utt-saga-conflict",
                UtteranceLane::Source,
                "new",
                9
            ),
            Err(NotebookCaptureStoreError::Conflict(_))
        ));

        let staged = store
            .stage_utterance_lane_replacement("utt-saga-conflict", UtteranceLane::Source, "new", 0)
            .unwrap();
        {
            let conn = store.conn.lock().unwrap();
            conn.execute(
                "UPDATE realtime_utterances SET revision = 1
                 WHERE id = 'utt-saga-conflict'",
                [],
            )
            .unwrap();
        }
        assert!(matches!(
            store.commit_projection_mutation(&staged.id),
            Err(NotebookCaptureStoreError::Conflict(_))
        ));
        assert!(store.get_projection_mutation(&staged.id).unwrap().is_some());
        assert!(store.cancel_projection_mutation(&staged.id).unwrap());
        assert!(!store.cancel_projection_mutation(&staged.id).unwrap());
        assert_eq!(
            store
                .get_utterance_by_id("utt-saga-conflict")
                .unwrap()
                .unwrap()
                .source_text,
            "old"
        );
        store.begin_session_purge("session-saga-conflict").unwrap();
        assert!(matches!(
            store.stage_utterance_lane_replacement(
                "utt-saga-conflict",
                UtteranceLane::Source,
                "must not resurrect",
                1
            ),
            Err(NotebookCaptureStoreError::Conflict(_))
        ));
    }

    #[test]
    fn projection_ready_commit_is_atomic_with_delete_forever_tombstone() {
        let (_temp, store, notebook_id) = fixture();
        store.get_or_create_profile(&notebook_id).unwrap();
        create_run(&store, &new_run(&notebook_id, "projection-purge-cas")).unwrap();
        store
            .transition_capture(
                "run-projection-purge-cas",
                CaptureState::Recording,
                CaptureState::Draining,
            )
            .unwrap();
        store
            .transition_capture(
                "run-projection-purge-cas",
                CaptureState::Draining,
                CaptureState::Completed,
            )
            .unwrap();
        store
            .set_projection_state(
                "run-projection-purge-cas",
                ProjectionState::Pending,
                ProjectionState::Projecting,
            )
            .unwrap();
        store
            .begin_session_purge("session-projection-purge-cas")
            .unwrap();

        assert!(matches!(
            store.complete_projection_unless_purging("run-projection-purge-cas"),
            Err(NotebookCaptureStoreError::Conflict(_))
        ));
        assert_eq!(
            store
                .get_run("run-projection-purge-cas")
                .unwrap()
                .unwrap()
                .projection_state,
            ProjectionState::Projecting
        );
    }

    #[test]
    fn async_projection_ready_commit_is_atomic_with_delete_forever_tombstone() {
        let (_temp, store, notebook_id) = fixture();
        create_run(&store, &new_run(&notebook_id, "async-projection-purge-cas")).unwrap();
        finish_run_ready(&store, "async-projection-purge-cas");
        authorize_async_transcription(&store, "async-projection-purge-cas");
        let digest = "e".repeat(64);
        store
            .reserve_async_task("run-async-projection-purge-cas", "provider-task", &digest)
            .unwrap();
        store
            .mark_async_task_enqueued("run-async-projection-purge-cas", "provider-task")
            .unwrap();
        store
            .mark_async_task_terminal_for_session(
                "session-async-projection-purge-cas",
                "provider-task",
                true,
            )
            .unwrap();
        store
            .set_async_projection_state(
                "run-async-projection-purge-cas",
                AsyncProjectionState::Pending,
                AsyncProjectionState::Projecting,
            )
            .unwrap();
        store
            .begin_session_purge("session-async-projection-purge-cas")
            .unwrap();

        assert!(matches!(
            store.complete_async_projection_unless_purging("run-async-projection-purge-cas"),
            Err(NotebookCaptureStoreError::Conflict(_))
        ));
        let blocked = store
            .get_run("run-async-projection-purge-cas")
            .unwrap()
            .unwrap();
        assert_eq!(blocked.async_task_state, AsyncTaskState::Completed);
        assert_eq!(
            blocked.async_projection_state,
            AsyncProjectionState::Projecting
        );
    }

    #[test]
    fn purge_plan_freezes_only_notebook_projection_documents() {
        let plan = SessionPurgePlan {
            session_id: "session-doc-union".into(),
            projection_targets: vec![ProjectionPurgeTarget {
                projection_id: "projection-a".into(),
                notebook_id: "notebook-a".into(),
                tab_id: "tab-a".into(),
                doc_id: "shared-projection-doc".into(),
            }],
            ..SessionPurgePlan::default()
        };

        assert_eq!(plan.frozen_document_ids(), vec!["shared-projection-doc"]);
        assert!(plan.contains_frozen_document("shared-projection-doc"));
        assert!(!plan.contains_frozen_document("unrelated-doc"));
    }

    #[test]
    fn ready_projection_cannot_be_retried_or_overwritten() {
        let (_temp, store, notebook_id) = fixture();
        store.get_or_create_profile(&notebook_id).unwrap();
        create_run(&store, &new_run(&notebook_id, "projection")).unwrap();
        store
            .transition_capture(
                "run-projection",
                CaptureState::Recording,
                CaptureState::Draining,
            )
            .unwrap();
        store
            .transition_capture(
                "run-projection",
                CaptureState::Draining,
                CaptureState::Completed,
            )
            .unwrap();
        store
            .set_projection_state(
                "run-projection",
                ProjectionState::Pending,
                ProjectionState::Projecting,
            )
            .unwrap();
        store
            .set_projection_state(
                "run-projection",
                ProjectionState::Projecting,
                ProjectionState::Ready,
            )
            .unwrap();
        assert!(matches!(
            store.retry_projection("run-projection"),
            Err(NotebookCaptureStoreError::Conflict(_))
        ));
    }

    #[test]
    fn interrupted_audio_can_be_finalized_without_changing_projection() {
        let (temp, store, notebook_id) = fixture();
        let db = temp.path().join("capture.db");
        store.get_or_create_profile(&notebook_id).unwrap();
        create_run(&store, &new_run(&notebook_id, "journal")).unwrap();
        drop(store);
        let reopened = NotebookCaptureStore::new(&db).unwrap();
        reopened.recover_unfinished_runs().unwrap();
        assert_eq!(reopened.list_interrupted_runs().unwrap().len(), 1);
        let finalized = reopened
            .finalize_interrupted_audio("run-journal", "/tmp/recovered.vtaudio", 42_000)
            .unwrap();
        assert_eq!(finalized.capture_state, CaptureState::Interrupted);
        assert_eq!(finalized.projection_state, ProjectionState::Pending);
        assert_eq!(
            finalized.audio_path.as_deref(),
            Some("/tmp/recovered.vtaudio")
        );
        assert_eq!(finalized.captured_frames, 42_000);
    }

    #[test]
    fn context_consent_requires_remote_processing() {
        let (_temp, store, notebook_id) = fixture();
        store.get_or_create_profile(&notebook_id).unwrap();
        let update = NotebookCaptureProfileUpdate {
            remote_realtime_enabled: false,
            capture_mode: CaptureMode::TranscriptionOnly,
            language_a: "en".into(),
            language_b: "zh".into(),
            left_language: "en".into(),
            right_language: "zh".into(),
            selected_languages: vec!["en".into(), "zh".into()],
            common_caption_language: None,
            privacy_level: "standard".into(),
            send_context_to_soniox: true,
        };
        assert!(matches!(
            store.update_profile(&notebook_id, 0, &update),
            Err(NotebookCaptureStoreError::Validation(_))
        ));
    }

    #[test]
    fn session_purge_job_freezes_plan_tracks_phase_and_survives_main_purge() {
        let (temp, store, notebook_id) = fixture();
        store.get_or_create_profile(&notebook_id).unwrap();
        create_run(&store, &new_run(&notebook_id, "purge-job")).unwrap();
        assert!(matches!(
            store.begin_session_purge("session-purge-job"),
            Err(NotebookCaptureStoreError::Conflict(_))
        ));
        store
            .transition_capture(
                "run-purge-job",
                CaptureState::Recording,
                CaptureState::Draining,
            )
            .unwrap();
        store
            .transition_capture(
                "run-purge-job",
                CaptureState::Draining,
                CaptureState::Completed,
            )
            .unwrap();

        assert!(!store.has_session_purge_job("session-purge-job").unwrap());
        let begun = store.begin_session_purge("session-purge-job").unwrap();
        assert!(store.has_session_purge_job("session-purge-job").unwrap());
        assert_eq!(begun.phase, "prepared");
        assert_eq!(begun.plan.run_id.as_deref(), Some("run-purge-job"));
        assert!(begun.plan.projection_targets.is_empty());
        assert!(begun
            .plan
            .key_refs
            .contains(&"zulangue.audio.session-purge-job".into()));
        assert_eq!(
            begun.plan.canonical_artifact_names,
            vec!["session-purge-job.capture-journal.enc"]
        );
        assert_eq!(
            begun.plan.canonical_artifact_prefixes,
            vec!["session-purge-job.chunk.", ".session-purge-job.chunk."]
        );

        let notebook_store = crate::NotebookStore::new(&temp.path().join("capture.db")).unwrap();
        notebook_store
            .ensure_session_projection(
                &notebook_id,
                crate::BuiltinNotebookTab::RealtimeTranscript,
                "session-purge-job",
                None,
            )
            .unwrap();
        let repeated = store.begin_session_purge("session-purge-job").unwrap();
        assert_eq!(repeated.plan, begun.plan, "purge plan must remain frozen");

        let updated = store
            .update_session_purge_job(
                "session-purge-job",
                "projections_failed",
                Some("disk unavailable"),
            )
            .unwrap();
        assert_eq!(updated.phase, "projections_failed");
        assert_eq!(updated.last_error.as_deref(), Some("disk unavailable"));
        assert_eq!(store.list_session_purge_jobs().unwrap().len(), 1);

        store.purge_session_artifacts("session-purge-job").unwrap();
        assert!(
            store
                .get_session_purge_job("session-purge-job")
                .unwrap()
                .is_some(),
            "main DB purge must not delete the cross-store retry tombstone"
        );
        assert!(store
            .complete_session_purge_job("session-purge-job")
            .unwrap());
        assert!(!store.has_session_purge_job("session-purge-job").unwrap());
        assert!(!store
            .complete_session_purge_job("session-purge-job")
            .unwrap());
    }

    #[test]
    fn network_gap_is_idempotent_and_blocks_complete_coverage() {
        let (_temp, store, notebook_id) = fixture();
        store.get_or_create_profile(&notebook_id).unwrap();
        let run = create_catalogued_run(&store, &notebook_id, "network-gap");

        let first = store
            .preserve_network_transcript_gap(&run.session_id, 80_000, 320_000)
            .unwrap();
        let repeated = store
            .preserve_network_transcript_gap(&run.session_id, 80_000, 320_000)
            .unwrap();

        assert_eq!(first.id, repeated.id);
        assert_eq!((first.start_frame, first.end_frame), (80_000, 320_000));
        assert!(store
            .has_unrepaired_transcript_gaps(&run.session_id)
            .unwrap());
        assert!(store
            .preserve_network_transcript_gap(&run.session_id, 10, 10)
            .is_err());
    }

    #[test]
    fn purge_session_artifacts_is_transactional_and_keeps_context_packs() {
        let (temp, store, notebook_id) = fixture();
        store.get_or_create_profile(&notebook_id).unwrap();
        create_run(&store, &new_run(&notebook_id, "purge")).unwrap();
        claim_realtime(&store, "session-purge");
        store
            .upsert_utterance(
                &NewRealtimeUtterance {
                    id: "utt-purge".into(),
                    session_id: "session-purge".into(),
                    sequence: 0,
                    session_speaker_id: None,
                    source_language: "en".into(),
                    source_text: "remove".into(),
                    source_start_ms: Some(0),
                    source_end_ms: Some(10),
                    translated_language: None,
                    translated_text: None,
                    completion: UtteranceCompletion::Complete,
                    alignment: UtteranceAlignment::SourceOnly,
                },
                None,
            )
            .unwrap();
        finish_run_ready(&store, "purge");
        store
            .stage_utterance_lane_replacement(
                "utt-purge",
                UtteranceLane::Source,
                "pending replacement",
                0,
            )
            .unwrap();
        let notebook_store = crate::NotebookStore::new(&temp.path().join("capture.db")).unwrap();
        notebook_store
            .ensure_session_projection(
                &notebook_id,
                crate::BuiltinNotebookTab::RealtimeTranscript,
                "session-purge",
                None,
            )
            .unwrap();
        {
            let conn = store.conn.lock().unwrap();
            conn.execute(
                "INSERT INTO search_index(session_id, content) VALUES ('session-purge', 'remove')",
                [],
            )
            .unwrap();
            conn.execute(
                "INSERT INTO session_meta(session_id, encrypted_path, key_id)
                 VALUES ('session-purge', '/tmp/meta.audio', 'meta-key')",
                [],
            )
            .unwrap();
            conn.execute(
                "INSERT INTO audio_retention_chunks
                 (session_id, chunk_id, start_ms, end_ms, local_path, encrypted,
                  retention_deadline_ms)
                 VALUES ('session-purge', 'chunk', 0, 100, '/tmp/chunk.audio', 1, 0)",
                [],
            )
            .unwrap();
            conn.execute(
                "INSERT INTO session_records(id) VALUES ('session-purge')",
                [],
            )
            .unwrap();
            conn.execute(
                "INSERT INTO context_packs
                 (id, scope, owner_notebook_id, title, key_ref, created_at, updated_at)
                 VALUES ('private-purge', 'private', ?1, 'Private', 'pack-key', 't', 't')",
                [&notebook_id],
            )
            .unwrap();
            conn.execute(
                "UPDATE notebook_capture_runs
                 SET context_receipt_json = '{}', context_snapshot_ciphertext = X'01',
                     context_snapshot_key_ref = 'context-key', context_snapshot_sha256 = 'digest'
                 WHERE id = 'run-purge'",
                [],
            )
            .unwrap();
        }

        let preview = store.preview_session_purge("session-purge").unwrap();
        assert_eq!(preview.utterance_count, 1);
        assert_eq!(preview.projection_targets.len(), 1);
        assert!(preview.key_refs.contains(&"audio-key-purge".into()));
        assert!(preview.key_refs.contains(&"context-key".into()));
        assert!(preview.key_refs.contains(&"meta-key".into()));
        assert!(preview.file_paths.contains(&"/tmp/meta.audio".into()));
        assert!(preview.file_paths.contains(&"/tmp/chunk.audio".into()));

        let result = store.purge_session_artifacts("session-purge").unwrap();
        assert_eq!(result, preview);
        let conn = store.conn.lock().unwrap();
        for (table, column) in [
            ("notebook_capture_runs", "session_id"),
            ("realtime_utterances", "session_id"),
            ("notebook_session_projections", "session_id"),
            ("notebook_sessions", "session_id"),
            ("session_meta", "session_id"),
            ("audio_retention_chunks", "session_id"),
            ("search_index", "session_id"),
            ("notebook_projection_mutations", "session_id"),
        ] {
            let count: i64 = conn
                .query_row(
                    &format!("SELECT COUNT(*) FROM {table} WHERE {column} = ?1"),
                    ["session-purge"],
                    |row| row.get(0),
                )
                .unwrap();
            assert_eq!(count, 0, "{table} retained session data");
        }
        let session_record_count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM session_records WHERE id = 'session-purge'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(session_record_count, 0);
        // The session purge never deletes reusable or private Context Packs.
        let pack_count: i64 = conn
            .query_row("SELECT COUNT(*) FROM context_packs", [], |row| row.get(0))
            .unwrap();
        assert_eq!(pack_count, 1, "session purge must preserve Context Packs");
    }
}
