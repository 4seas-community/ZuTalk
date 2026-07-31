//! Persistent ownership for the single active Notebook capture runtime.
//!
//! The store keeps provider state and transcript projection state separate so a
//! remote failure can never terminate or discard the local audio journal.

use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use rusqlite::{params, Connection, OptionalExtension, Row, TransactionBehavior};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use thiserror::Error;
use vt_model::Token;

use crate::session_query::SessionRecord;

pub const SONIOX_PROVIDER_ID: &str = "soniox";
pub const SONIOX_STT_RT_V5_MODEL_ID: &str = "stt-rt-v5";
pub const MAX_CAPTURE_LANGUAGES: usize = 3;

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
    pub realtime_loro_desired_revision: u64,
    pub realtime_loro_applied_revision: u64,
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
pub struct RealtimeTranslationLaneUpdate {
    pub language: String,
    pub text: Option<String>,
    pub state: UtteranceVariantState,
    pub completion: Option<UtteranceCompletion>,
}

/// Stable provider identity for one physically independent one-way
/// translation stream item.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct RealtimeTranslationInboxKey {
    pub session_id: String,
    pub lane_index: u64,
    pub group_epoch: u64,
    pub provider_sequence: u64,
    pub target_language: String,
}

/// Provider fact accepted into the durable auxiliary translation inbox.
///
/// A withdrawn item carries no translation payload and remains as a tombstone
/// so replay/restart cannot resurrect the previous Partial.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NewRealtimeTranslationInboxItem {
    pub key: RealtimeTranslationInboxKey,
    pub source_language: String,
    pub source_text: String,
    pub source_start_ms: Option<u64>,
    pub source_end_ms: Option<u64>,
    pub translated_text: Option<String>,
    pub completion: Option<UtteranceCompletion>,
    pub withdrawn: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RealtimeTranslationInboxItem {
    pub key: RealtimeTranslationInboxKey,
    pub source_language: String,
    pub source_text: String,
    pub source_start_ms: Option<u64>,
    pub source_end_ms: Option<u64>,
    pub translated_text: Option<String>,
    pub completion: Option<UtteranceCompletion>,
    pub withdrawn: bool,
    pub revision: u64,
    pub bound_utterance_id: Option<String>,
    pub bound_sequence: Option<u64>,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RealtimeTranslationInboxPersistence {
    pub item: RealtimeTranslationInboxItem,
    /// Present when an already-bound item changed its canonical lane.
    pub bound_utterance: Option<RealtimeUtterance>,
    /// Set when withdrawing the last machine fact deletes a translation-only
    /// shell. Delta consumers must rebuild so the removed row cannot ghost.
    pub removed_bound_sequence: Option<u64>,
    pub removed_bound_utterance_id: Option<String>,
    pub changed: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RealtimeTranslationInboxBinding {
    pub key: RealtimeTranslationInboxKey,
    pub canonical_sequence: u64,
    /// None when the target language is already the canonical source lane.
    pub utterance: Option<RealtimeUtterance>,
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
    /// Session desired revision at which this Final lane became projectable.
    /// Zero means the lane is still SQLite-only.
    pub projection_revision: u64,
    /// Lane-local revision of the user-visible override.
    ///
    /// This is independent of provider-owned `revision`: zero means no user
    /// edit has committed, and every successful override commit increments it.
    pub edit_revision: u64,
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
    /// Aggregate provider-machine revision, not a user-edit CAS token.
    pub revision: u64,
    pub completion: UtteranceCompletion,
    pub alignment: UtteranceAlignment,
    pub created_at: String,
    pub updated_at: String,
    /// Session desired revision at which the source lane became Final.
    /// Zero means the source remains SQLite-only.
    pub source_projection_revision: u64,
    /// Lane-local revision of the source's user-visible override.
    pub source_edit_revision: u64,
    pub variants: Vec<RealtimeUtteranceVariant>,
}

impl RealtimeUtterance {
    /// Whether the canonical provider has supplied source evidence for this
    /// utterance, independently of which producer currently owns the visible
    /// language lane.
    ///
    /// A Final auxiliary translation can win the per-language owner CAS while
    /// the aggregate source fact remains useful for correlation and immutable
    /// provider provenance. Source withdrawal is the only path that clears
    /// all of these aggregate presence signals.
    pub fn has_source_fact(&self) -> bool {
        self.completion == UtteranceCompletion::Complete
            || !self.source_text.is_empty()
            || self.source_start_ms.is_some()
            || self.source_end_ms.is_some()
            || self.variants.iter().any(|variant| {
                variant.role == UtteranceVariantRole::Source
                    && variant.state == UtteranceVariantState::Ready
                    && variant.text.is_some()
                    && variant.completion.is_some()
            })
    }

    /// Completion of the canonical provider fact, not ownership of a visible
    /// Loro lane. A same-language auxiliary Final may own the visible variant
    /// while this aggregate fact is still Final and therefore immutable.
    pub fn source_fact_is_complete(&self) -> bool {
        self.completion == UtteranceCompletion::Complete
    }

    /// The normalized source variant is the source-lane authority.
    ///
    /// Aggregate source columns are only a compatibility shadow; a translation
    /// Final can keep its utterance shell after a speculative source lane is
    /// withdrawn. Consumers must use this predicate before rendering or
    /// projecting those bytes.
    pub fn has_source_lane(&self) -> bool {
        let source_variant = self
            .variants
            .iter()
            .find(|variant| variant.role == UtteranceVariantRole::Source);
        source_variant.is_some_and(|variant| {
            variant.state == UtteranceVariantState::Ready
                && variant.text.is_some()
                && variant.completion.is_some()
        }) || (source_variant.is_none() && self.variants.is_empty() && self.has_source_fact())
    }

    pub fn source_lane_is_complete(&self) -> bool {
        let source_variant = self
            .variants
            .iter()
            .find(|variant| variant.role == UtteranceVariantRole::Source);
        source_variant.is_some_and(|variant| {
            variant.state == UtteranceVariantState::Ready
                && variant.text.is_some()
                && variant.completion == Some(UtteranceCompletion::Complete)
        }) || (source_variant.is_none()
            && self.variants.is_empty()
            && self.source_fact_is_complete())
    }
}

/// Durable per-session receipt for Final-only realtime projection into Loro.
///
/// `desired_revision` advances atomically with each new machine Final.
/// `applied_revision` advances only after the corresponding Loro write is
/// durable and never moves backwards.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RealtimeLoroProjection {
    pub session_id: String,
    pub desired_revision: u64,
    pub applied_revision: u64,
}

impl RealtimeLoroProjection {
    pub fn is_pending(&self) -> bool {
        self.desired_revision > self.applied_revision
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RealtimeLoroProjectionAck {
    pub session_id: String,
    pub desired_revision: u64,
    pub applied_revision: u64,
    /// True only when this acknowledgement moved the durable receipt forward.
    pub advanced: bool,
}

/// One transactionally consistent projector input.
///
/// The watermarks and machine utterances come from the same SQLite read
/// snapshot, so a receipt for revision R can never be paired with R+1 facts.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RealtimeLoroProjectionSnapshot {
    pub session_id: String,
    pub desired_revision: u64,
    pub applied_revision: u64,
    pub machine_utterances: Vec<RealtimeUtterance>,
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
    pub realtime_loro_desired_revision: u64,
    pub realtime_loro_applied_revision: u64,
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
            realtime_loro_desired_revision: run.realtime_loro_desired_revision,
            realtime_loro_applied_revision: run.realtime_loro_applied_revision,
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
    /// Lane-local user-visible edit revision observed by the caller.
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
        conn.busy_timeout(Duration::from_secs(1))?;
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
        if success {
            return Err(NotebookCaptureStoreError::Validation(
                "Ready search authority must be committed atomically with FTS content".into(),
            ));
        }
        let desired = AsyncSearchProjectionState::Failed;
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
        if input.translated_language.is_some() || input.translated_text.is_some() {
            return Err(NotebookCaptureStoreError::Validation(
                "source upsert cannot own a translation lane; use upsert_translation_variant"
                    .into(),
            ));
        }
        let mut source_language = canonical_language(&input.source_language);
        let input_translated_language =
            input.translated_language.as_deref().map(canonical_language);
        let mut stored_translated_language = input_translated_language.clone();
        let mut stored_translated_text = input.translated_text.clone();
        let mut stored_alignment = input.alignment;
        let now = chrono::Utc::now().to_rfc3339();
        let mut conn = self.conn.lock().unwrap();
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
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

        let existing_machine = get_machine_utterance_by_session_sequence_from_conn(
            &tx,
            &input.session_id,
            input.sequence,
        )?;
        // Source language is monotone over a flat lattice with `und` at the
        // bottom: a provider revision that carries no language claim must not
        // erase a language this row already learned (from its own earlier
        // tokens or from an adopted auxiliary identification).
        if source_language == "und" {
            if let Some(known) = existing_machine
                .as_ref()
                .map(|existing| canonical_language(&existing.source_language))
                .filter(|stored| stored != "und")
            {
                source_language = known;
            }
        }
        let mut preserve_final_translation_variant = false;
        let mut source_coalesces_with_final_translation = false;
        if let Some(existing) = existing_machine.as_ref() {
            // A source-only provider update must not erase the legacy
            // translation read shadow. Translation ownership lives in the
            // variant table; these aggregate columns exist only for older FFI
            // consumers and mirror whichever variant was selected earlier.
            let legacy_shadow_collides_with_source = existing
                .translated_language
                .as_deref()
                .is_some_and(|language| canonical_language(language) == source_language);
            if input.translated_language.is_none()
                && input.translated_text.is_none()
                && existing.translated_text.is_some()
                && !legacy_shadow_collides_with_source
            {
                stored_translated_language = existing
                    .translated_language
                    .as_deref()
                    .map(canonical_language);
                stored_translated_text = existing.translated_text.clone();
                stored_alignment = UtteranceAlignment::Paired;
            }
            if existing.source_fact_is_complete() {
                if !machine_utterance_matches_input(existing, input) {
                    return Err(NotebookCaptureStoreError::Conflict(format!(
                        "final machine source fact {}:{} is immutable",
                        input.session_id, input.sequence
                    )));
                }
                let mut visible = existing.clone();
                apply_utterance_overrides(&tx, &mut visible)?;
                tx.commit()?;
                return Ok(visible);
            }

            let input_translation = input
                .translated_text
                .as_deref()
                .zip(input_translated_language.as_ref())
                .map(|(text, language)| (language.clone(), text));
            for variant in existing.variants.iter().filter(|variant| {
                variant.state == UtteranceVariantState::Ready
                    && variant.completion == Some(UtteranceCompletion::Complete)
            }) {
                let variant_language = canonical_language(&variant.language);
                if variant.role == UtteranceVariantRole::Source {
                    return Err(NotebookCaptureStoreError::Conflict(format!(
                        "final machine source variant {}:{} is immutable",
                        input.session_id, input.sequence
                    )));
                }
                if variant_language == source_language {
                    // The language lane already has an immutable Final owner.
                    // Keep that translation variant byte-for-byte stable and
                    // store this later source revision only as aggregate
                    // machine evidence. This is the per-language
                    // first-Complete-wins rule.
                    source_coalesces_with_final_translation = true;
                    preserve_final_translation_variant = true;
                    stored_translated_language = Some(variant_language);
                    stored_translated_text = variant.text.clone();
                    stored_alignment = UtteranceAlignment::Paired;
                    continue;
                }

                let is_legacy_shadow = existing
                    .translated_language
                    .as_deref()
                    .is_some_and(|language| canonical_language(language) == variant_language);
                let replaces_variant = input_translation
                    .as_ref()
                    .is_some_and(|(language, _)| language == &variant_language);
                if is_legacy_shadow && input_translation.is_none() {
                    preserve_final_translation_variant = true;
                    stored_translated_language = existing
                        .translated_language
                        .as_deref()
                        .map(canonical_language);
                    stored_translated_text = existing.translated_text.clone();
                    continue;
                }
                if is_legacy_shadow || replaces_variant {
                    let is_exact_final =
                        input_translation.as_ref().is_some_and(|(language, text)| {
                            language == &variant_language && variant.text.as_deref() == Some(*text)
                        });
                    if !is_exact_final {
                        return Err(NotebookCaptureStoreError::Conflict(format!(
                            "Final translation variant {}:{}:{variant_language} is immutable",
                            input.session_id, input.sequence
                        )));
                    }
                    preserve_final_translation_variant = true;
                }
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
                        source_language,
                        input.source_text,
                        option_u64_to_i64(input.source_start_ms, "source_start_ms")?,
                        option_u64_to_i64(input.source_end_ms, "source_end_ms")?,
                        stored_translated_language,
                        stored_translated_text,
                        input.completion.as_str(),
                        stored_alignment.as_str(),
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
                        source_language,
                        input.source_text,
                        option_u64_to_i64(input.source_start_ms, "source_start_ms")?,
                        option_u64_to_i64(input.source_end_ms, "source_end_ms")?,
                        stored_translated_language,
                        stored_translated_text,
                        input.completion.as_str(),
                        stored_alignment.as_str(),
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
        let source_variant_language = source_language.clone();
        if source_coalesces_with_final_translation {
            tx.execute(
                "DELETE FROM realtime_utterance_variants
                 WHERE utterance_id = ?1 AND role = 'source'",
                [&utterance_id],
            )?;
            tx.execute(
                "UPDATE realtime_utterances
                 SET source_projection_revision = 0
                 WHERE id = ?1",
                [&utterance_id],
            )?;
        } else {
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
        }
        if !preserve_final_translation_variant {
            if let (Some(language), Some(text)) = (
                input_translated_language.as_deref(),
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
        }

        if input.completion == UtteranceCompletion::Complete
            && !source_coalesces_with_final_translation
        {
            let projection_revision = bump_realtime_loro_desired_revision(&tx, &input.session_id)?;
            tx.execute(
                "UPDATE realtime_utterances
                 SET source_projection_revision = ?1
                 WHERE id = ?2",
                params![
                    u64_to_i64(projection_revision, "source projection revision")?,
                    utterance_id
                ],
            )?;
            tx.execute(
                "UPDATE realtime_utterance_variants
                 SET projection_revision = ?1
                 WHERE utterance_id = ?2 AND role = 'source'",
                params![
                    u64_to_i64(projection_revision, "source projection revision")?,
                    utterance_id
                ],
            )?;
            if !preserve_final_translation_variant {
                if let Some(language) = input_translated_language.as_deref() {
                    tx.execute(
                        "UPDATE realtime_utterance_variants
                         SET projection_revision = ?1
                         WHERE utterance_id = ?2
                           AND lower(trim(language)) = ?3
                           AND role = 'translation'",
                        params![
                            u64_to_i64(projection_revision, "translation projection revision")?,
                            utterance_id,
                            language
                        ],
                    )?;
                }
            }
        }
        if !apply_bound_translation_inbox_items_from_conn(
            &tx,
            &input.session_id,
            &utterance_id,
            input.sequence,
        )? {
            return Err(NotebookCaptureStoreError::CorruptData(format!(
                "source update unexpectedly collected utterance {}:{}",
                input.session_id, input.sequence
            )));
        }

        let mut utterance = get_machine_utterance_by_session_sequence_from_conn(
            &tx,
            &input.session_id,
            input.sequence,
        )?
        .ok_or_else(|| {
            NotebookCaptureStoreError::NotFound(format!(
                "utterance {}:{}",
                input.session_id, input.sequence
            ))
        })?;
        apply_utterance_overrides(&tx, &mut utterance)?;
        tx.commit()?;
        Ok(utterance)
    }

    /// Durably accepts one auxiliary one-way stream fact before any
    /// cross-stream correlation is attempted.
    ///
    /// If the item was already bound, the inbox row and its visible variant
    /// (including a possible Final desired-revision bump) commit in this same
    /// SQLite transaction.
    pub fn upsert_translation_inbox_item(
        &self,
        input: &NewRealtimeTranslationInboxItem,
    ) -> Result<RealtimeTranslationInboxPersistence, NotebookCaptureStoreError> {
        validate_translation_inbox_input(input)?;
        let mut conn = self.conn.lock().unwrap();
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        ensure_active_realtime_session(&tx, &input.key.session_id)?;
        let persistence = upsert_translation_inbox_item_from_conn(&tx, input)?;
        tx.commit()?;
        Ok(persistence)
    }

    /// Rehydrates auxiliary provider facts after a collector/runtime restart.
    /// Withdrawn tombstones are intentionally included.
    pub fn list_translation_inbox(
        &self,
        session_id: &str,
    ) -> Result<Vec<RealtimeTranslationInboxItem>, NotebookCaptureStoreError> {
        require_nonempty("session_id", session_id)?;
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(
            "SELECT session_id, lane_index, group_epoch, provider_sequence,
                    target_language, source_language, source_text,
                    source_start_ms, source_end_ms, translated_text,
                    completion, state, revision, bound_utterance_id,
                    bound_sequence, created_at, updated_at
             FROM realtime_translation_inbox
             WHERE session_id = ?1
             ORDER BY group_epoch, lane_index, provider_sequence, target_language",
        )?;
        let rows = stmt.query_map([session_id], translation_inbox_item_from_row)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
    }

    /// Atomically binds a durable unbound auxiliary fact to one canonical
    /// utterance and applies the target lane. Callers must pass a uniquely
    /// selected candidate; this method independently checks identity
    /// compatibility and enforces one inbox item per canonical language lane.
    pub fn bind_translation_inbox_item(
        &self,
        key: &RealtimeTranslationInboxKey,
        canonical_sequence: u64,
    ) -> Result<Option<RealtimeUtterance>, NotebookCaptureStoreError> {
        validate_translation_inbox_key(key)?;
        let mut conn = self.conn.lock().unwrap();
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        ensure_active_realtime_session(&tx, &key.session_id)?;
        let visible = bind_translation_inbox_item_from_conn(&tx, key, canonical_sequence)?;
        tx.commit()?;
        Ok(visible)
    }

    /// Store-authoritative fallback for a late auxiliary fact whose canonical
    /// row has already fallen out of the bounded runtime correlation cache.
    pub fn bind_translation_inbox_item_if_unique(
        &self,
        key: &RealtimeTranslationInboxKey,
    ) -> Result<Option<RealtimeTranslationInboxBinding>, NotebookCaptureStoreError> {
        validate_translation_inbox_key(key)?;
        if key.group_epoch != 0 {
            // Multi-stream reconnect is fail-closed today. Until canonical
            // epochs are themselves durable, never guess across a recovered
            // discontinuity; keep the inbox fact for a future explicit repair.
            return Ok(None);
        }
        let mut conn = self.conn.lock().unwrap();
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        ensure_active_realtime_session(&tx, &key.session_id)?;
        let item = get_translation_inbox_item_from_conn(&tx, key)?.ok_or_else(|| {
            NotebookCaptureStoreError::NotFound(format!(
                "translation inbox {}:{}:{}:{}:{}",
                key.session_id,
                key.lane_index,
                key.group_epoch,
                key.provider_sequence,
                key.target_language
            ))
        })?;
        if item.withdrawn {
            tx.commit()?;
            return Ok(None);
        }
        let sequence = if let Some(sequence) = item.bound_sequence {
            sequence
        } else {
            let candidates = list_machine_utterances_from_conn(&tx, &key.session_id)?;
            let Some(sequence) = unique_translation_inbox_candidate(&item, candidates.iter())
            else {
                tx.commit()?;
                return Ok(None);
            };
            sequence
        };
        match bind_translation_inbox_item_from_conn(&tx, key, sequence) {
            Ok(utterance) => {
                tx.commit()?;
                Ok(Some(RealtimeTranslationInboxBinding {
                    key: item.key,
                    canonical_sequence: sequence,
                    utterance,
                }))
            }
            Err(NotebookCaptureStoreError::Conflict(_)) => {
                // Same policy as reconcile: an already-owned visible language
                // lane or contested identity keeps the durable fact unbound.
                // "Unique" is a best-effort guess, so a contested bind must
                // never escalate into a capture-fatal persistence error.
                tx.rollback()?;
                Ok(None)
            }
            Err(error) => Err(error),
        }
    }

    /// Reconciles every currently unbound epoch-zero auxiliary fact while the
    /// capture is active. This is the authoritative fallback after bounded
    /// process caches evict an old pending item before its canonical row
    /// arrives.
    pub fn reconcile_active_translation_inbox(
        &self,
        session_id: &str,
    ) -> Result<Vec<RealtimeTranslationInboxBinding>, NotebookCaptureStoreError> {
        require_nonempty("session_id", session_id)?;
        let mut conn = self.conn.lock().unwrap();
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        ensure_active_realtime_session(&tx, session_id)?;
        let bindings = reconcile_translation_inbox_from_conn(&tx, session_id)?;
        tx.commit()?;
        Ok(bindings)
    }

    /// Reconciles only provider facts that were durable before startup
    /// recovery made the run terminal. It never accepts a new provider write.
    ///
    /// Each item binds only when one canonical row has uniquely strongest
    /// identity evidence. Binding, variant materialization, and any Final
    /// desired-revision bump share this transaction.
    pub fn reconcile_translation_inbox_after_recovery(
        &self,
        session_id: &str,
    ) -> Result<usize, NotebookCaptureStoreError> {
        require_nonempty("session_id", session_id)?;
        let mut conn = self.conn.lock().unwrap();
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        ensure_realtime_session_provenance(&tx, session_id)?;
        let reconciled = reconcile_translation_inbox_from_conn(&tx, session_id)?.len();
        tx.commit()?;
        Ok(reconciled)
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
        let mut conn = self.conn.lock().unwrap();
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        ensure_active_realtime_session(&tx, session_id)?;
        let utterance = upsert_translation_variant_from_conn(
            &tx, session_id, sequence, language, text, state, completion,
        )?;
        tx.commit()?;
        Ok(utterance)
    }

    /// Marks every still-Waiting target in a session unavailable when the
    /// physical stream group ends. This scans SQLite rather than the bounded
    /// runtime correlation cache.
    pub fn mark_waiting_translation_variants_unavailable(
        &self,
        session_id: &str,
    ) -> Result<Vec<RealtimeUtterance>, NotebookCaptureStoreError> {
        require_nonempty("session_id", session_id)?;
        let mut conn = self.conn.lock().unwrap();
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        ensure_realtime_session_provenance(&tx, session_id)?;
        let waiting = {
            let mut stmt = tx.prepare(
                "SELECT u.sequence, v.language
                 FROM realtime_utterance_variants v
                 JOIN realtime_utterances u ON u.id = v.utterance_id
                 WHERE u.session_id = ?1
                   AND v.role = 'translation'
                   AND v.state = 'waiting'
                 ORDER BY u.sequence, v.language",
            )?;
            let rows = stmt.query_map([session_id], |row| {
                Ok((row.get::<_, i64>(0)?, row.get::<_, String>(1)?))
            })?;
            rows.collect::<Result<Vec<_>, _>>()?
        };
        let mut updates = Vec::new();
        for (sequence, language) in waiting {
            updates.push(upsert_translation_variant_from_conn(
                &tx,
                session_id,
                i64_to_u64(sequence, "waiting translation sequence")?,
                &language,
                None,
                UtteranceVariantState::Unavailable,
                None,
            )?);
        }
        tx.commit()?;
        Ok(updates)
    }

    /// Withdraws a speculative source lane that disappeared from the next
    /// provider response.
    ///
    /// If no translation fact depends on the utterance shell, the whole row is
    /// deleted. Otherwise only the normalized source variant is deleted and
    /// the shell revision advances; aggregate source columns remain inert
    /// compatibility bytes. The returned utterance is `Some` only when that
    /// translation-owned shell survives.
    pub fn remove_partial_utterance(
        &self,
        session_id: &str,
        sequence: u64,
        expected_revision: u64,
        translation_update: Option<&RealtimeTranslationLaneUpdate>,
    ) -> Result<Option<RealtimeUtterance>, NotebookCaptureStoreError> {
        require_nonempty("session_id", session_id)?;
        if let Some(update) = translation_update {
            validate_language(&update.language)?;
            validate_variant_payload(update.text.as_deref(), update.state, update.completion)?;
        }
        let mut conn = self.conn.lock().unwrap();
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        ensure_active_realtime_session(&tx, session_id)?;
        let Some(mut utterance) =
            get_machine_utterance_by_session_sequence_from_conn(&tx, session_id, sequence)?
        else {
            tx.commit()?;
            return Ok(None);
        };
        if utterance.revision != expected_revision {
            return Err(NotebookCaptureStoreError::Conflict(format!(
                "utterance {session_id}:{sequence} expected revision {expected_revision}"
            )));
        }
        if utterance.source_fact_is_complete() {
            return Err(NotebookCaptureStoreError::Conflict(format!(
                "final machine source fact {session_id}:{sequence} is immutable"
            )));
        }
        if utterance.has_source_fact() {
            if utterance.has_source_lane() {
                let removed = tx.execute(
                    "DELETE FROM realtime_utterance_variants
                     WHERE utterance_id = ?1 AND role = 'source'",
                    [&utterance.id],
                )?;
                if removed != 1 {
                    return Err(NotebookCaptureStoreError::CorruptData(format!(
                        "utterance {session_id}:{sequence} has {removed} source variants"
                    )));
                }
            }
            let now = chrono::Utc::now().to_rfc3339();
            let updated = tx.execute(
                "UPDATE realtime_utterances
                 SET source_text = '',
                     source_start_ms = NULL,
                     source_end_ms = NULL,
                     completion = 'partial',
                     alignment = CASE
                         WHEN translated_text IS NULL THEN 'source_only'
                         ELSE 'paired'
                     END,
                     source_projection_revision = 0,
                     revision = revision + 1,
                     updated_at = ?1
                 WHERE id = ?2 AND revision = ?3 AND completion = 'partial'",
                params![
                    now,
                    utterance.id,
                    u64_to_i64(expected_revision, "expected_revision")?
                ],
            )?;
            if updated != 1 {
                return Err(NotebookCaptureStoreError::Conflict(format!(
                    "utterance {session_id}:{sequence} changed before source withdrawal"
                )));
            }
        }
        if let Some(update) = translation_update {
            utterance = upsert_translation_variant_from_conn(
                &tx,
                session_id,
                sequence,
                &update.language,
                update.text.as_deref(),
                update.state,
                update.completion,
            )?;
        } else {
            utterance =
                get_machine_utterance_by_id_from_conn(&tx, &utterance.id)?.ok_or_else(|| {
                    NotebookCaptureStoreError::NotFound(format!("utterance {}", utterance.id))
                })?;
        }
        // Same-language auxiliary evidence binds while the provisional source
        // has display priority. With that source now withdrawn, materialize
        // any bound fallback before deciding whether the shell is empty.
        if !apply_bound_translation_inbox_items_from_conn(&tx, session_id, &utterance.id, sequence)?
        {
            tx.commit()?;
            return Ok(None);
        }
        // Also consume any older unbound fact whose identity becomes unique
        // only after this withdrawal.
        let _ = reconcile_translation_inbox_from_conn(&tx, session_id)?;
        utterance =
            get_machine_utterance_by_id_from_conn(&tx, &utterance.id)?.ok_or_else(|| {
                NotebookCaptureStoreError::NotFound(format!("utterance {}", utterance.id))
            })?;
        let has_translation_fact = utterance.variants.iter().any(|variant| {
            variant.role == UtteranceVariantRole::Translation
                && variant.state == UtteranceVariantState::Ready
                && variant.text.is_some()
                && variant.completion.is_some()
        });
        if has_translation_fact {
            apply_utterance_overrides(&tx, &mut utterance)?;
            tx.commit()?;
            return Ok(Some(utterance));
        }
        let removed = tx.execute(
            "DELETE FROM realtime_utterances
             WHERE session_id = ?1 AND sequence = ?2 AND revision = ?3
               AND completion = 'partial'",
            params![
                session_id,
                u64_to_i64(sequence, "sequence")?,
                u64_to_i64(utterance.revision, "current_revision")?
            ],
        )?;
        if removed == 0 {
            return Err(NotebookCaptureStoreError::Conflict(format!(
                "utterance {session_id}:{sequence} changed before partial removal"
            )));
        }
        tx.commit()?;
        Ok(None)
    }

    pub fn list_utterances(
        &self,
        session_id: &str,
    ) -> Result<Vec<RealtimeUtterance>, NotebookCaptureStoreError> {
        let conn = self.conn.lock().unwrap();
        list_utterances_with_overrides_from_conn(&conn, session_id)
    }

    /// Loads the run and exactly the rows needed for one callback publication
    /// from a single SQLite read transaction.
    ///
    /// Live deltas are keyed by the session-local sequence identity, so their
    /// cost is proportional to the changed rows rather than the length of the
    /// capture. Full snapshots remain intentionally O(session).
    pub fn load_capture_callback_snapshot(
        &self,
        session_id: &str,
        requested_sequences: &[u64],
        full_snapshot: bool,
    ) -> Result<Option<(NotebookCaptureRun, Vec<RealtimeUtterance>)>, NotebookCaptureStoreError>
    {
        require_nonempty("session_id", session_id)?;
        let mut conn = self.conn.lock().unwrap();
        let tx = conn.transaction_with_behavior(TransactionBehavior::Deferred)?;
        let run = tx
            .query_row(
                &format!("{RUN_SELECT} WHERE session_id = ?1"),
                [session_id],
                capture_run_from_row,
            )
            .optional()?;
        let Some(run) = run else {
            tx.commit()?;
            return Ok(None);
        };

        let utterances = if full_snapshot {
            list_utterances_with_overrides_from_conn(&tx, session_id)?
        } else {
            let mut by_sequence = std::collections::BTreeMap::new();
            for sequence in requested_sequences.iter().copied() {
                if by_sequence.contains_key(&sequence) {
                    continue;
                }
                let mut utterance =
                    get_machine_utterance_by_session_sequence_from_conn(&tx, session_id, sequence)?;
                if let Some(utterance) = utterance.as_mut() {
                    apply_utterance_overrides(&tx, utterance)?;
                }
                if let Some(utterance) = utterance {
                    by_sequence.insert(sequence, utterance);
                }
            }
            by_sequence.into_values().collect()
        };
        tx.commit()?;
        Ok(Some((run, utterances)))
    }

    /// Returns provider-owned machine facts without user-edit overlays.
    ///
    /// Loro projection, digests, provider CAS, and recovery code must use this
    /// machine view rather than [`Self::list_utterances`].
    pub fn list_machine_utterances(
        &self,
        session_id: &str,
    ) -> Result<Vec<RealtimeUtterance>, NotebookCaptureStoreError> {
        require_nonempty("session_id", session_id)?;
        list_machine_utterances_from_conn(&self.conn.lock().unwrap(), session_id)
    }

    /// Loads watermarks and machine facts from one SQLite read transaction.
    ///
    /// This is the projector entry point. Combining a standalone watermark
    /// read with [`Self::list_machine_utterances`] would permit revision R to
    /// be paired with R+1 facts.
    pub fn load_realtime_loro_projection(
        &self,
        session_id: &str,
    ) -> Result<RealtimeLoroProjectionSnapshot, NotebookCaptureStoreError> {
        require_nonempty("session_id", session_id)?;
        let mut conn = self.conn.lock().unwrap();
        let tx = conn.transaction_with_behavior(TransactionBehavior::Deferred)?;
        let watermark =
            get_realtime_loro_projection_from_conn(&tx, session_id)?.ok_or_else(|| {
                NotebookCaptureStoreError::NotFound(format!("capture session {session_id}"))
            })?;
        let machine_utterances = list_machine_utterances_from_conn(&tx, session_id)?;
        let snapshot = RealtimeLoroProjectionSnapshot {
            session_id: watermark.session_id,
            desired_revision: watermark.desired_revision,
            applied_revision: watermark.applied_revision,
            machine_utterances,
        };
        tx.commit()?;
        Ok(snapshot)
    }

    pub fn list_pending_realtime_loro_projections(
        &self,
    ) -> Result<Vec<RealtimeLoroProjection>, NotebookCaptureStoreError> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(
            "SELECT session_id, realtime_loro_desired_revision,
                    realtime_loro_applied_revision
             FROM notebook_capture_runs
             WHERE realtime_loro_desired_revision > realtime_loro_applied_revision
             ORDER BY created_at ASC, session_id ASC",
        )?;
        let projections = stmt
            .query_map([], realtime_loro_projection_from_row)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(NotebookCaptureStoreError::from)?;
        Ok(projections)
    }

    /// Monotonically acknowledges a durable Loro projection.
    ///
    /// Repeated or stale acknowledgements are idempotent. Acknowledging a
    /// revision that SQLite has not desired is rejected rather than allowing
    /// the receipt to get ahead of machine facts.
    pub fn ack_realtime_loro_projection(
        &self,
        session_id: &str,
        revision: u64,
    ) -> Result<RealtimeLoroProjectionAck, NotebookCaptureStoreError> {
        require_nonempty("session_id", session_id)?;
        let revision = u64_to_i64(revision, "realtime Loro projection revision")?;
        let mut conn = self.conn.lock().unwrap();
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let current =
            get_realtime_loro_projection_from_conn(&tx, session_id)?.ok_or_else(|| {
                NotebookCaptureStoreError::NotFound(format!("capture session {session_id}"))
            })?;
        if revision > u64_to_i64(current.desired_revision, "realtime Loro desired revision")? {
            return Err(NotebookCaptureStoreError::Conflict(format!(
                "realtime Loro projection {session_id} cannot acknowledge revision {revision} \
                 beyond desired revision {}",
                current.desired_revision
            )));
        }
        let advanced =
            revision > u64_to_i64(current.applied_revision, "realtime Loro applied revision")?;
        tx.execute(
            "UPDATE notebook_capture_runs
             SET realtime_loro_applied_revision =
                     max(realtime_loro_applied_revision, ?1)
             WHERE session_id = ?2",
            params![revision, session_id],
        )?;
        let acknowledged =
            get_realtime_loro_projection_from_conn(&tx, session_id)?.ok_or_else(|| {
                NotebookCaptureStoreError::NotFound(format!("capture session {session_id}"))
            })?;
        tx.commit()?;
        Ok(RealtimeLoroProjectionAck {
            session_id: acknowledged.session_id,
            desired_revision: acknowledged.desired_revision,
            applied_revision: acknowledged.applied_revision,
            advanced,
        })
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
                        r.realtime_loro_desired_revision,
                        r.realtime_loro_applied_revision,
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
                Ok((capture_run_from_row(row)?, row.get::<_, bool>(33)?))
            })?;
            rows.collect::<Result<Vec<_>, _>>()?
        };

        let mut history = Vec::with_capacity(visible_runs.len());
        for (run, has_audio) in visible_runs {
            let utterances = list_utterances_with_overrides_from_conn(&tx, &run.session_id)?;
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
        get_utterance_with_overrides_by_id_from_conn(&self.conn.lock().unwrap(), utterance_id)
    }

    /// Returns one provider-owned machine fact without user-edit overlays.
    pub fn get_machine_utterance_by_id(
        &self,
        utterance_id: &str,
    ) -> Result<Option<RealtimeUtterance>, NotebookCaptureStoreError> {
        require_nonempty("utterance_id", utterance_id)?;
        get_machine_utterance_by_id_from_conn(&self.conn.lock().unwrap(), utterance_id)
    }

    /// Durably stage a lane edit without changing the visible utterance.
    /// Loro must be synchronously updated before `commit_projection_mutation`
    /// performs the lane-local edit-revision CAS. Identical repeated staging
    /// is idempotent.
    pub fn stage_utterance_lane_replacement(
        &self,
        utterance_id: &str,
        lane: UtteranceLane,
        target_text: &str,
        expected_revision: u64,
    ) -> Result<NotebookProjectionMutation, NotebookCaptureStoreError> {
        require_nonempty("utterance_id", utterance_id)?;
        let utterance = self
            .get_machine_utterance_by_id(utterance_id)?
            .ok_or_else(|| {
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
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let utterance =
            get_machine_utterance_by_id_from_conn(&tx, utterance_id)?.ok_or_else(|| {
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
        if variant.state != UtteranceVariantState::Ready
            || variant.text.is_none()
            || variant.completion != Some(UtteranceCompletion::Complete)
        {
            return Err(NotebookCaptureStoreError::Conflict(format!(
                "utterance {utterance_id} variant {} is not Final and ready for editing",
                variant.language
            )));
        }
        let lane = match variant.role {
            UtteranceVariantRole::Source => UtteranceLane::Source,
            UtteranceVariantRole::Translation => UtteranceLane::Translated,
        };
        let lane_language = canonical_language(&variant.language);

        ensure_utterance_lane_is_editable(
            &tx,
            &utterance.session_id,
            variant.completion.unwrap_or(UtteranceCompletion::Partial),
            variant.projection_revision,
        )?;
        if session_purge_job_exists(&tx, &utterance.session_id)? {
            return Err(NotebookCaptureStoreError::Conflict(format!(
                "session {} is pending permanent deletion",
                utterance.session_id
            )));
        }
        let current_edit_revision = get_lane_edit_revision(&tx, utterance_id, &lane_language)?;
        if current_edit_revision != expected_revision {
            return Err(NotebookCaptureStoreError::Conflict(format!(
                "utterance {utterance_id} lane {lane_language} expected edit revision \
                 {expected_revision}, found {current_edit_revision}"
            )));
        }
        if let Some(existing) =
            get_projection_mutation_for_utterance_lane(&tx, utterance_id, &lane_language)?
        {
            let existing_variant_revision =
                get_projection_mutation_expected_variant_revision(&tx, &existing.id)?;
            if existing.session_id == utterance.session_id
                && existing.lane == lane
                && existing.lane_language == lane_language
                && existing.expected_revision == expected_revision
                && existing_variant_revision == variant.revision
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
             (id, session_id, utterance_id, lane, lane_language,
              expected_revision, expected_variant_revision,
              target_text, state, created_at, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?10)",
            params![
                id,
                utterance.session_id,
                utterance.id,
                lane.as_str(),
                lane_language,
                u64_to_i64(expected_revision, "expected_revision")?,
                u64_to_i64(variant.revision, "expected_variant_revision")?,
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

    /// Commit a staged Loro edit into the separate UI override read model.
    ///
    /// Both the lane-local machine revision and user-visible edit revision are
    /// revalidated. Unrelated source or translation lanes may advance
    /// independently. Provider-owned rows remain byte-for-byte machine facts.
    pub fn commit_projection_mutation(
        &self,
        mutation_id: &str,
    ) -> Result<RealtimeUtterance, NotebookCaptureStoreError> {
        require_nonempty("mutation_id", mutation_id)?;
        let mut conn = self.conn.lock().unwrap();
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let mutation = get_projection_mutation_from_conn(&tx, mutation_id)?.ok_or_else(|| {
            NotebookCaptureStoreError::NotFound(format!("projection mutation {mutation_id}"))
        })?;
        let expected_variant_revision =
            get_projection_mutation_expected_variant_revision(&tx, mutation_id)?;
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

        let current = get_machine_utterance_by_id_from_conn(&tx, &mutation.utterance_id)?
            .ok_or_else(|| {
                NotebookCaptureStoreError::NotFound(format!("utterance {}", mutation.utterance_id))
            })?;
        if current.session_id != mutation.session_id {
            return Err(NotebookCaptureStoreError::CorruptData(format!(
                "projection mutation {mutation_id} crosses capture sessions"
            )));
        }
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
        if variant.role != expected_role
            || variant.state != UtteranceVariantState::Ready
            || variant.completion != Some(UtteranceCompletion::Complete)
            || variant.revision != expected_variant_revision
        {
            return Err(NotebookCaptureStoreError::Conflict(format!(
                "utterance {} Final variant {} changed before commit",
                mutation.utterance_id, mutation.lane_language
            )));
        }
        ensure_utterance_lane_is_editable(
            &tx,
            &mutation.session_id,
            variant.completion.unwrap_or(UtteranceCompletion::Partial),
            variant.projection_revision,
        )?;
        let current_edit_revision =
            get_lane_edit_revision(&tx, &mutation.utterance_id, &mutation.lane_language)?;
        if current_edit_revision != mutation.expected_revision {
            return Err(NotebookCaptureStoreError::Conflict(format!(
                "utterance {} lane {} expected edit revision {}, found {}",
                mutation.utterance_id,
                mutation.lane_language,
                mutation.expected_revision,
                current_edit_revision
            )));
        }
        let next_edit_revision = current_edit_revision.checked_add(1).ok_or_else(|| {
            NotebookCaptureStoreError::Conflict(format!(
                "utterance {} lane {} edit revision overflow",
                mutation.utterance_id, mutation.lane_language
            ))
        })?;

        let now = chrono::Utc::now().to_rfc3339();
        tx.execute(
            "INSERT INTO realtime_utterance_overrides (
                 utterance_id, lane, lane_language, text,
                 machine_utterance_revision, machine_variant_revision,
                 edit_revision, created_at, updated_at
             ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?8)
             ON CONFLICT(utterance_id, lane_language) DO UPDATE SET
                 lane = excluded.lane,
                 text = excluded.text,
                 machine_utterance_revision = excluded.machine_utterance_revision,
                 machine_variant_revision = excluded.machine_variant_revision,
                 edit_revision = excluded.edit_revision,
                 updated_at = excluded.updated_at",
            params![
                mutation.utterance_id,
                mutation.lane.as_str(),
                canonical_language(&mutation.lane_language),
                mutation.target_text,
                u64_to_i64(current.revision, "machine utterance revision")?,
                u64_to_i64(expected_variant_revision, "expected_variant_revision")?,
                u64_to_i64(next_edit_revision, "lane edit revision")?,
                now,
            ],
        )?;
        tx.execute(
            "DELETE FROM notebook_projection_mutations WHERE id = ?1",
            [mutation_id],
        )?;
        let utterance = get_utterance_with_overrides_by_id_from_conn(&tx, &mutation.utterance_id)?
            .ok_or_else(|| {
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
            async_projection_state,
            realtime_loro_desired_revision, realtime_loro_applied_revision
     FROM notebook_capture_runs";

const UTTERANCE_SELECT: &str =
    "SELECT id, session_id, sequence, session_speaker_id, source_language, source_text,
            source_start_ms, source_end_ms, translated_language, translated_text, revision,
            completion, alignment, created_at, updated_at, source_projection_revision
     FROM realtime_utterances";

const UTTERANCE_VARIANT_SELECT: &str =
    "SELECT language, role, text, state, completion, revision, created_at, updated_at,
            projection_revision
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

fn validate_translation_inbox_key(
    key: &RealtimeTranslationInboxKey,
) -> Result<(), NotebookCaptureStoreError> {
    require_nonempty("session_id", &key.session_id)?;
    validate_language(&key.target_language)
}

fn validate_translation_inbox_input(
    input: &NewRealtimeTranslationInboxItem,
) -> Result<(), NotebookCaptureStoreError> {
    validate_translation_inbox_key(&input.key)?;
    validate_language(&input.source_language)?;
    if input
        .source_end_ms
        .zip(input.source_start_ms)
        .is_some_and(|(end, start)| end < start)
    {
        return Err(NotebookCaptureStoreError::Validation(
            "translation inbox source_end_ms precedes source_start_ms".into(),
        ));
    }
    match (
        input.withdrawn,
        input.translated_text.as_deref(),
        input.completion,
    ) {
        (false, Some(_), Some(_)) | (true, None, None) => Ok(()),
        _ => Err(NotebookCaptureStoreError::Validation(
            "present translation inbox items require text/completion; withdrawn items forbid both"
                .into(),
        )),
    }
}

fn translation_inbox_item_from_row(
    row: &Row<'_>,
) -> rusqlite::Result<RealtimeTranslationInboxItem> {
    let completion = row
        .get::<_, Option<String>>(10)?
        .map(|value| UtteranceCompletion::parse(&value).map_err(to_sql_conversion_error))
        .transpose()?;
    let state: String = row.get(11)?;
    let withdrawn = match state.as_str() {
        "present" => false,
        "withdrawn" => true,
        other => {
            return Err(to_sql_conversion_error(
                NotebookCaptureStoreError::CorruptData(format!(
                    "unknown translation inbox state '{other}'"
                )),
            ));
        }
    };
    Ok(RealtimeTranslationInboxItem {
        key: RealtimeTranslationInboxKey {
            session_id: row.get(0)?,
            lane_index: i64_to_u64(row.get(1)?, "translation lane index")
                .map_err(to_sql_conversion_error)?,
            group_epoch: i64_to_u64(row.get(2)?, "translation group epoch")
                .map_err(to_sql_conversion_error)?,
            provider_sequence: i64_to_u64(row.get(3)?, "translation provider sequence")
                .map_err(to_sql_conversion_error)?,
            target_language: row.get(4)?,
        },
        source_language: row.get(5)?,
        source_text: row.get(6)?,
        source_start_ms: row
            .get::<_, Option<i64>>(7)?
            .map(|value| i64_to_u64(value, "translation source start"))
            .transpose()
            .map_err(to_sql_conversion_error)?,
        source_end_ms: row
            .get::<_, Option<i64>>(8)?
            .map(|value| i64_to_u64(value, "translation source end"))
            .transpose()
            .map_err(to_sql_conversion_error)?,
        translated_text: row.get(9)?,
        completion,
        withdrawn,
        revision: i64_to_u64(row.get(12)?, "translation inbox revision")
            .map_err(to_sql_conversion_error)?,
        bound_utterance_id: row.get(13)?,
        bound_sequence: row
            .get::<_, Option<i64>>(14)?
            .map(|value| i64_to_u64(value, "bound canonical sequence"))
            .transpose()
            .map_err(to_sql_conversion_error)?,
        created_at: row.get(15)?,
        updated_at: row.get(16)?,
    })
}

fn get_translation_inbox_item_from_conn(
    conn: &Connection,
    key: &RealtimeTranslationInboxKey,
) -> Result<Option<RealtimeTranslationInboxItem>, NotebookCaptureStoreError> {
    conn.query_row(
        "SELECT session_id, lane_index, group_epoch, provider_sequence,
                target_language, source_language, source_text,
                source_start_ms, source_end_ms, translated_text,
                completion, state, revision, bound_utterance_id,
                bound_sequence, created_at, updated_at
         FROM realtime_translation_inbox
         WHERE session_id = ?1
           AND group_epoch = ?2
           AND provider_sequence = ?3
           AND target_language = ?4",
        params![
            key.session_id,
            u64_to_i64(key.group_epoch, "translation group epoch")?,
            u64_to_i64(key.provider_sequence, "translation provider sequence")?,
            canonical_language(&key.target_language),
        ],
        translation_inbox_item_from_row,
    )
    .optional()
    .map_err(Into::into)
}

fn list_translation_inbox_from_conn(
    conn: &Connection,
    session_id: &str,
) -> Result<Vec<RealtimeTranslationInboxItem>, NotebookCaptureStoreError> {
    let mut stmt = conn.prepare(
        "SELECT session_id, lane_index, group_epoch, provider_sequence,
                target_language, source_language, source_text,
                source_start_ms, source_end_ms, translated_text,
                completion, state, revision, bound_utterance_id,
                bound_sequence, created_at, updated_at
         FROM realtime_translation_inbox
         WHERE session_id = ?1
         ORDER BY group_epoch, lane_index, provider_sequence, target_language",
    )?;
    let rows = stmt.query_map([session_id], translation_inbox_item_from_row)?;
    rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
}

fn bind_translation_inbox_item_from_conn(
    conn: &Connection,
    key: &RealtimeTranslationInboxKey,
    canonical_sequence: u64,
) -> Result<Option<RealtimeUtterance>, NotebookCaptureStoreError> {
    let item = get_translation_inbox_item_from_conn(conn, key)?.ok_or_else(|| {
        NotebookCaptureStoreError::NotFound(format!(
            "translation inbox {}:{}:{}:{}:{}",
            key.session_id,
            key.lane_index,
            key.group_epoch,
            key.provider_sequence,
            key.target_language
        ))
    })?;
    if item.withdrawn {
        return Ok(None);
    }
    if let Some(bound_sequence) = item.bound_sequence {
        if bound_sequence != canonical_sequence {
            return Err(NotebookCaptureStoreError::Conflict(format!(
                "translation inbox item is already bound to sequence {bound_sequence}"
            )));
        }
    }
    let canonical = get_machine_utterance_by_session_sequence_from_conn(
        conn,
        &key.session_id,
        canonical_sequence,
    )?
    .ok_or_else(|| {
        NotebookCaptureStoreError::NotFound(format!(
            "utterance {}:{canonical_sequence}",
            key.session_id
        ))
    })?;
    if !translation_inbox_matches_utterance(&item, &canonical) {
        return Err(NotebookCaptureStoreError::Conflict(format!(
            "translation inbox identity does not match canonical utterance {}:{canonical_sequence}",
            key.session_id
        )));
    }
    let target_is_current_source = canonical.has_source_lane()
        && canonical_language(&canonical.source_language)
            == canonical_language(&key.target_language);
    let auxiliary_final_claims_owner = target_is_current_source
        && !canonical.source_lane_is_complete()
        && item.completion == Some(UtteranceCompletion::Complete);
    let evidence_only = target_is_current_source && !auxiliary_final_claims_owner;
    let occupied = conn
        .query_row(
            "SELECT 1
             FROM realtime_translation_inbox
             WHERE bound_utterance_id = ?1
               AND target_language = ?2
               AND NOT (
                   session_id = ?3
                   AND group_epoch = ?4
                   AND provider_sequence = ?5
               )
             LIMIT 1",
            params![
                canonical.id,
                canonical_language(&key.target_language),
                key.session_id,
                u64_to_i64(key.group_epoch, "translation group epoch")?,
                u64_to_i64(key.provider_sequence, "translation provider sequence")?,
            ],
            |_| Ok(()),
        )
        .optional()?
        .is_some();
    if occupied {
        return Err(NotebookCaptureStoreError::Conflict(format!(
            "canonical translation lane {}:{canonical_sequence}:{} is already bound",
            key.session_id, key.target_language
        )));
    }
    let now = chrono::Utc::now().to_rfc3339();
    let updated = conn.execute(
        "UPDATE realtime_translation_inbox
         SET bound_utterance_id = ?1, bound_sequence = ?2, updated_at = ?3
         WHERE session_id = ?4
           AND group_epoch = ?5
           AND provider_sequence = ?6
           AND target_language = ?7
           AND (bound_utterance_id IS NULL OR bound_utterance_id = ?1)",
        params![
            canonical.id,
            u64_to_i64(canonical_sequence, "canonical sequence")?,
            now,
            key.session_id,
            u64_to_i64(key.group_epoch, "translation group epoch")?,
            u64_to_i64(key.provider_sequence, "translation provider sequence")?,
            canonical_language(&key.target_language),
        ],
    )?;
    if updated != 1 {
        return Err(NotebookCaptureStoreError::Conflict(
            "translation inbox binding changed concurrently".into(),
        ));
    }
    if evidence_only {
        Ok(None)
    } else {
        apply_translation_inbox_to_bound_utterance(conn, &item, canonical_sequence)
    }
}

fn reconcile_translation_inbox_from_conn(
    conn: &Connection,
    session_id: &str,
) -> Result<Vec<RealtimeTranslationInboxBinding>, NotebookCaptureStoreError> {
    let items = list_translation_inbox_from_conn(conn, session_id)?;
    let candidates = list_machine_utterances_from_conn(conn, session_id)?;
    let mut bindings = Vec::new();
    for item in items.into_iter().filter(|item| {
        !item.withdrawn && item.bound_sequence.is_none() && item.key.group_epoch == 0
    }) {
        let Some(sequence) = unique_translation_inbox_candidate(&item, candidates.iter()) else {
            continue;
        };
        match bind_translation_inbox_item_from_conn(conn, &item.key, sequence) {
            Ok(utterance) => bindings.push(RealtimeTranslationInboxBinding {
                key: item.key,
                canonical_sequence: sequence,
                utterance,
            }),
            Err(NotebookCaptureStoreError::Conflict(_)) => {
                // Ambiguity or an already-owned visible language lane remains
                // durable and unbound instead of falling back to weaker
                // evidence.
            }
            Err(error) => return Err(error),
        }
    }
    Ok(bindings)
}

fn apply_bound_translation_inbox_items_from_conn(
    conn: &Connection,
    session_id: &str,
    utterance_id: &str,
    canonical_sequence: u64,
) -> Result<bool, NotebookCaptureStoreError> {
    let items = list_translation_inbox_from_conn(conn, session_id)?;
    // Materialize surviving evidence before processing tombstones so an
    // otherwise empty shell cannot be collected while another bound producer
    // fact still owns a fallback lane.
    for withdrawn in [false, true] {
        for item in items.iter().filter(|item| {
            item.bound_utterance_id.as_deref() == Some(utterance_id)
                && item.bound_sequence == Some(canonical_sequence)
                && item.withdrawn == withdrawn
        }) {
            let _ = apply_translation_inbox_to_bound_utterance(conn, item, canonical_sequence)?;
            if get_machine_utterance_by_id_from_conn(conn, utterance_id)?.is_none() {
                return Ok(false);
            }
        }
    }
    Ok(true)
}

fn upsert_translation_inbox_item_from_conn(
    conn: &Connection,
    input: &NewRealtimeTranslationInboxItem,
) -> Result<RealtimeTranslationInboxPersistence, NotebookCaptureStoreError> {
    let key = RealtimeTranslationInboxKey {
        target_language: canonical_language(&input.key.target_language),
        ..input.key.clone()
    };
    let source_language = canonical_language(&input.source_language);
    let existing = get_translation_inbox_item_from_conn(conn, &key)?;
    let changed = existing.as_ref().is_none_or(|current| {
        current.source_language != source_language
            || current.source_text != input.source_text
            || current.source_start_ms != input.source_start_ms
            || current.source_end_ms != input.source_end_ms
            || current.translated_text != input.translated_text
            || current.completion != input.completion
            || current.withdrawn != input.withdrawn
    });
    if let Some(existing) = existing.as_ref() {
        if !existing.withdrawn
            && existing.completion == Some(UtteranceCompletion::Complete)
            && changed
        {
            return Err(NotebookCaptureStoreError::Conflict(format!(
                "final translation inbox fact {}:{}:{}:{}:{} is immutable",
                key.session_id,
                key.lane_index,
                key.group_epoch,
                key.provider_sequence,
                key.target_language
            )));
        }
    }
    if changed {
        let now = chrono::Utc::now().to_rfc3339();
        conn.execute(
            "INSERT INTO realtime_translation_inbox (
                 session_id, lane_index, group_epoch, provider_sequence,
                 target_language, source_language, source_text,
                 source_start_ms, source_end_ms, translated_text,
                 completion, state, revision, bound_utterance_id,
                 bound_sequence, created_at, updated_at
             )
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10,
                     ?11, ?12, 0, NULL, NULL, ?13, ?13)
             ON CONFLICT DO UPDATE SET
                 lane_index = excluded.lane_index,
                 source_language = excluded.source_language,
                 source_text = excluded.source_text,
                 source_start_ms = excluded.source_start_ms,
                 source_end_ms = excluded.source_end_ms,
                 translated_text = excluded.translated_text,
                 completion = excluded.completion,
                 state = excluded.state,
                 revision = realtime_translation_inbox.revision + 1,
                 updated_at = excluded.updated_at",
            params![
                key.session_id,
                u64_to_i64(key.lane_index, "translation lane index")?,
                u64_to_i64(key.group_epoch, "translation group epoch")?,
                u64_to_i64(key.provider_sequence, "translation provider sequence")?,
                key.target_language,
                source_language,
                input.source_text,
                input
                    .source_start_ms
                    .map(|value| u64_to_i64(value, "translation source start"))
                    .transpose()?,
                input
                    .source_end_ms
                    .map(|value| u64_to_i64(value, "translation source end"))
                    .transpose()?,
                input.translated_text,
                input.completion.map(UtteranceCompletion::as_str),
                if input.withdrawn {
                    "withdrawn"
                } else {
                    "present"
                },
                now,
            ],
        )?;
    }

    let mut item = get_translation_inbox_item_from_conn(conn, &key)?.ok_or_else(|| {
        NotebookCaptureStoreError::NotFound(format!(
            "translation inbox {}:{}:{}:{}:{}",
            key.session_id,
            key.lane_index,
            key.group_epoch,
            key.provider_sequence,
            key.target_language
        ))
    })?;
    let mut removed_bound_sequence = None;
    let mut removed_bound_utterance_id = None;
    let mut bound_utterance = if changed {
        match (item.bound_utterance_id.as_deref(), item.bound_sequence) {
            (Some(_), Some(sequence)) => {
                if get_machine_utterance_by_session_sequence_from_conn(
                    conn,
                    &key.session_id,
                    sequence,
                )?
                .is_some()
                {
                    let visible =
                        apply_translation_inbox_to_bound_utterance(conn, &item, sequence)?;
                    if visible.is_none()
                        && get_machine_utterance_by_session_sequence_from_conn(
                            conn,
                            &key.session_id,
                            sequence,
                        )?
                        .is_none()
                    {
                        removed_bound_sequence = Some(sequence);
                        removed_bound_utterance_id = item.bound_utterance_id.clone();
                        item =
                            get_translation_inbox_item_from_conn(conn, &key)?.ok_or_else(|| {
                                NotebookCaptureStoreError::NotFound(
                                    "translation inbox disappeared after shell collection".into(),
                                )
                            })?;
                    }
                    visible
                } else {
                    conn.execute(
                        "UPDATE realtime_translation_inbox
                         SET bound_utterance_id = NULL, bound_sequence = NULL
                         WHERE session_id = ?1
                           AND group_epoch = ?2
                           AND provider_sequence = ?3
                           AND target_language = ?4",
                        params![
                            key.session_id,
                            u64_to_i64(key.group_epoch, "translation group epoch")?,
                            u64_to_i64(key.provider_sequence, "translation provider sequence")?,
                            key.target_language,
                        ],
                    )?;
                    item = get_translation_inbox_item_from_conn(conn, &key)?.ok_or_else(|| {
                        NotebookCaptureStoreError::NotFound(
                            "translation inbox disappeared while clearing stale binding".into(),
                        )
                    })?;
                    None
                }
            }
            (None, None) => None,
            _ => {
                return Err(NotebookCaptureStoreError::CorruptData(
                    "translation inbox has a partial canonical binding".into(),
                ));
            }
        }
    } else {
        None
    };
    if !item.withdrawn && item.bound_sequence.is_none() && item.key.group_epoch == 0 {
        let candidates = list_machine_utterances_from_conn(conn, &key.session_id)?;
        if let Some(sequence) = unique_translation_inbox_candidate(&item, candidates.iter()) {
            match bind_translation_inbox_item_from_conn(conn, &key, sequence) {
                Ok(visible) => {
                    bound_utterance = visible;
                    item = get_translation_inbox_item_from_conn(conn, &key)?.ok_or_else(|| {
                        NotebookCaptureStoreError::NotFound(
                            "translation inbox disappeared after automatic binding".into(),
                        )
                    })?;
                }
                Err(NotebookCaptureStoreError::Conflict(_)) => {
                    // Competing or ambiguous ownership keeps this provider
                    // fact durably unbound. A later canonical revision or
                    // startup reconciliation retries it.
                }
                Err(error) => return Err(error),
            }
        }
    }
    Ok(RealtimeTranslationInboxPersistence {
        item,
        bound_utterance,
        removed_bound_sequence,
        removed_bound_utterance_id,
        changed,
    })
}

/// Adopts a bound auxiliary fact's identified source language onto a
/// canonical utterance whose own lane never received language identification.
///
/// `und` is the bottom of a flat language lattice: it means "the canonical
/// stream made no claim", never "the language is officially unknown". An
/// auxiliary producer fact carries the provider's own identification of the
/// same audio, so binding it to an `und` canonical row is strictly stronger
/// evidence and upgrades the row in the same transaction as the bind. A
/// concrete language is never displaced (first evidence wins), and the
/// adopted language must not already be owned by a Ready translation variant
/// — that would be provider evidence that the source is a different language.
///
/// Language is the Loro lane key, so a completed source lane re-materializes
/// under its real language via a fresh desired revision.
fn adopt_translation_inbox_source_language(
    conn: &Connection,
    item: &RealtimeTranslationInboxItem,
    canonical: RealtimeUtterance,
) -> Result<RealtimeUtterance, NotebookCaptureStoreError> {
    if item.withdrawn {
        return Ok(canonical);
    }
    let adopted = canonical_language(&item.source_language);
    if adopted == "und" || canonical_language(&canonical.source_language) != "und" {
        return Ok(canonical);
    }
    let adopted_lane_is_occupied = canonical.variants.iter().any(|variant| {
        canonical_language(&variant.language) == adopted
            && variant.role == UtteranceVariantRole::Translation
            && variant.state == UtteranceVariantState::Ready
    });
    if adopted_lane_is_occupied {
        return Ok(canonical);
    }
    let now = chrono::Utc::now().to_rfc3339();
    // The adopted language stops being a translation target, so its
    // placeholder lane dissolves into the source lane instead of waiting for
    // a same-language translation that the provider will never produce.
    conn.execute(
        "DELETE FROM realtime_utterance_variants
         WHERE utterance_id = ?1
           AND role = 'translation'
           AND lower(trim(language)) = ?2
           AND state IN ('waiting', 'failed', 'unavailable')",
        params![canonical.id, adopted],
    )?;
    let renamed = conn.execute(
        "UPDATE realtime_utterance_variants
         SET language = ?1, revision = revision + 1, updated_at = ?2
         WHERE utterance_id = ?3
           AND role = 'source'
           AND lower(trim(language)) = 'und'",
        params![adopted, now, canonical.id],
    )?;
    conn.execute(
        "UPDATE realtime_utterances
         SET source_language = ?1, updated_at = ?2
         WHERE id = ?3",
        params![adopted, now, canonical.id],
    )?;
    if renamed == 1 {
        if canonical.source_lane_is_complete() {
            let projection_revision =
                bump_realtime_loro_desired_revision(conn, &canonical.session_id)?;
            conn.execute(
                "UPDATE realtime_utterances
                 SET source_projection_revision = ?1
                 WHERE id = ?2",
                params![
                    u64_to_i64(projection_revision, "source projection revision")?,
                    canonical.id
                ],
            )?;
            conn.execute(
                "UPDATE realtime_utterance_variants
                 SET projection_revision = ?1
                 WHERE utterance_id = ?2 AND role = 'source'",
                params![
                    u64_to_i64(projection_revision, "source projection revision")?,
                    canonical.id
                ],
            )?;
        } else {
            conn.execute(
                "UPDATE realtime_utterances
                 SET source_projection_revision = 0
                 WHERE id = ?1",
                [&canonical.id],
            )?;
            conn.execute(
                "UPDATE realtime_utterance_variants
                 SET projection_revision = 0
                 WHERE utterance_id = ?1 AND role = 'source'",
                [&canonical.id],
            )?;
        }
    }
    let mut visible =
        get_machine_utterance_by_id_from_conn(conn, &canonical.id)?.ok_or_else(|| {
            NotebookCaptureStoreError::NotFound(format!("utterance {}", canonical.id))
        })?;
    apply_utterance_overrides(conn, &mut visible)?;
    Ok(visible)
}

fn apply_translation_inbox_to_bound_utterance(
    conn: &Connection,
    item: &RealtimeTranslationInboxItem,
    canonical_sequence: u64,
) -> Result<Option<RealtimeUtterance>, NotebookCaptureStoreError> {
    let canonical = get_machine_utterance_by_session_sequence_from_conn(
        conn,
        &item.key.session_id,
        canonical_sequence,
    )?
    .ok_or_else(|| {
        NotebookCaptureStoreError::NotFound(format!(
            "utterance {}:{canonical_sequence}",
            item.key.session_id
        ))
    })?;
    let canonical = adopt_translation_inbox_source_language(conn, item, canonical)?;
    let target_is_current_source = canonical.has_source_lane()
        && canonical_language(&canonical.source_language)
            == canonical_language(&item.key.target_language);
    let auxiliary_final_claims_owner = target_is_current_source
        && !canonical.source_lane_is_complete()
        && !item.withdrawn
        && item.completion == Some(UtteranceCompletion::Complete);
    if target_is_current_source && !auxiliary_final_claims_owner {
        // Same-language aux Partial/withdrawal is durable evidence while the
        // provisional source retains display priority. A source Final is an
        // immutable owner, so every same-language aux fact is evidence-only.
        return Ok(None);
    }
    if item.withdrawn {
        if let Some(existing) = canonical.variants.iter().find(|variant| {
            variant.role == UtteranceVariantRole::Translation
                && canonical_language(&variant.language)
                    == canonical_language(&item.key.target_language)
        }) {
            if existing.completion == Some(UtteranceCompletion::Complete) {
                return Err(NotebookCaptureStoreError::Conflict(format!(
                    "final machine utterance variant {}:{canonical_sequence}:{} is immutable",
                    item.key.session_id, item.key.target_language
                )));
            }
            if existing.state == UtteranceVariantState::Waiting {
                let mut visible = canonical;
                apply_utterance_overrides(conn, &mut visible)?;
                return collect_empty_translation_shell_after_withdrawal(conn, visible);
            }
        }
        let visible = upsert_translation_variant_from_conn(
            conn,
            &item.key.session_id,
            canonical_sequence,
            &item.key.target_language,
            None,
            UtteranceVariantState::Waiting,
            None,
        )?;
        return collect_empty_translation_shell_after_withdrawal(conn, visible);
    }
    if auxiliary_final_claims_owner {
        return claim_auxiliary_final_from_provisional_source(conn, &canonical, item).map(Some);
    }
    upsert_translation_variant_from_conn(
        conn,
        &item.key.session_id,
        canonical_sequence,
        &item.key.target_language,
        item.translated_text.as_deref(),
        UtteranceVariantState::Ready,
        item.completion,
    )
    .map(Some)
}

/// The per-language owner CAS for `Partial(source) -> Final(auxiliary)`.
///
/// The aggregate source columns remain untouched provider evidence. The
/// normalized visible variant changes role exactly once and receives the
/// desired Loro revision in this same SQLite transaction.
fn claim_auxiliary_final_from_provisional_source(
    conn: &Connection,
    canonical: &RealtimeUtterance,
    item: &RealtimeTranslationInboxItem,
) -> Result<RealtimeUtterance, NotebookCaptureStoreError> {
    let language = canonical_language(&item.key.target_language);
    let text = item.translated_text.as_deref().ok_or_else(|| {
        NotebookCaptureStoreError::CorruptData(
            "auxiliary Final owner claim has no translated text".into(),
        )
    })?;
    let now = chrono::Utc::now().to_rfc3339();
    let claimed = conn.execute(
        "UPDATE realtime_utterance_variants
         SET role = 'translation',
             text = ?1,
             state = 'ready',
             completion = 'complete',
             revision = revision + 1,
             projection_revision = 0,
             updated_at = ?2
         WHERE utterance_id = ?3
           AND role = 'source'
           AND lower(trim(language)) = ?4
           AND state = 'ready'
           AND completion = 'partial'",
        params![text, now, canonical.id, language],
    )?;
    if claimed != 1 {
        return Err(NotebookCaptureStoreError::Conflict(format!(
            "provisional source owner {}:{}:{language} changed before auxiliary Final",
            canonical.session_id, canonical.sequence
        )));
    }
    conn.execute(
        "UPDATE realtime_utterances
         SET translated_language = ?1,
             translated_text = ?2,
             alignment = 'paired',
             source_projection_revision = 0,
             updated_at = ?3
         WHERE id = ?4",
        params![language, text, now, canonical.id],
    )?;
    let projection_revision = bump_realtime_loro_desired_revision(conn, &canonical.session_id)?;
    conn.execute(
        "UPDATE realtime_utterance_variants
         SET projection_revision = ?1
         WHERE utterance_id = ?2
           AND role = 'translation'
           AND lower(trim(language)) = ?3
           AND completion = 'complete'",
        params![
            u64_to_i64(projection_revision, "translation projection revision")?,
            canonical.id,
            language
        ],
    )?;
    let mut visible =
        get_machine_utterance_by_id_from_conn(conn, &canonical.id)?.ok_or_else(|| {
            NotebookCaptureStoreError::NotFound(format!("utterance {}", canonical.id))
        })?;
    apply_utterance_overrides(conn, &mut visible)?;
    Ok(visible)
}

fn collect_empty_translation_shell_after_withdrawal(
    conn: &Connection,
    utterance: RealtimeUtterance,
) -> Result<Option<RealtimeUtterance>, NotebookCaptureStoreError> {
    if utterance.has_source_fact()
        || utterance.variants.iter().any(|variant| {
            variant.role == UtteranceVariantRole::Translation
                && variant.state == UtteranceVariantState::Ready
                && variant.text.is_some()
                && variant.completion.is_some()
        })
    {
        return Ok(Some(utterance));
    }
    let has_user_state = conn.query_row(
        "SELECT
             EXISTS(
                 SELECT 1 FROM realtime_utterance_overrides
                 WHERE utterance_id = ?1
             )
             OR EXISTS(
                 SELECT 1 FROM notebook_projection_mutations
                 WHERE utterance_id = ?1
             )",
        [&utterance.id],
        |row| row.get::<_, bool>(0),
    )?;
    if has_user_state {
        return Ok(Some(utterance));
    }
    let removed = conn.execute(
        "DELETE FROM realtime_utterances WHERE id = ?1",
        [&utterance.id],
    )?;
    if removed != 1 {
        return Err(NotebookCaptureStoreError::Conflict(format!(
            "translation-only shell {} changed before withdrawal collection",
            utterance.id
        )));
    }
    Ok(None)
}

fn translation_inbox_matches_utterance(
    item: &RealtimeTranslationInboxItem,
    utterance: &RealtimeUtterance,
) -> bool {
    let normalize_text = |value: &str| {
        value
            .chars()
            .filter(|character| !character.is_whitespace())
            .flat_map(char::to_lowercase)
            .collect::<String>()
    };
    let source_text = normalize_text(&item.source_text);
    let exact_text =
        !source_text.is_empty() && source_text == normalize_text(&utterance.source_text);
    match (
        item.source_start_ms,
        item.source_end_ms,
        utterance.source_start_ms,
        utterance.source_end_ms,
    ) {
        (Some(left_start), Some(left_end), Some(right_start), Some(right_end)) => {
            left_start <= right_end && right_start <= left_end
        }
        _ => exact_text || item.key.provider_sequence == utterance.sequence,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct TranslationInboxAlignmentScore {
    exact_source_text: bool,
    overlap_per_mille: u16,
    source_language_matches: bool,
    midpoint_distance_ms: u64,
    sequence_distance: u64,
    sequence: u64,
}

fn translation_inbox_alignment_score(
    item: &RealtimeTranslationInboxItem,
    utterance: &RealtimeUtterance,
) -> Option<TranslationInboxAlignmentScore> {
    let normalize_text = |value: &str| {
        value
            .chars()
            .filter(|character| !character.is_whitespace())
            .flat_map(char::to_lowercase)
            .collect::<String>()
    };
    let source_text = normalize_text(&item.source_text);
    let exact_source_text =
        !source_text.is_empty() && source_text == normalize_text(&utterance.source_text);
    let source_language_matches =
        canonical_language(&item.source_language) == canonical_language(&utterance.source_language);
    let sequence_distance = item.key.provider_sequence.abs_diff(utterance.sequence);
    match (
        item.source_start_ms,
        item.source_end_ms,
        utterance.source_start_ms,
        utterance.source_end_ms,
    ) {
        (Some(left_start), Some(left_end), Some(right_start), Some(right_end)) => {
            if left_end < left_start || right_end < right_start {
                return None;
            }
            let intersection_start = left_start.max(right_start);
            let intersection_end = left_end.min(right_end);
            if intersection_end < intersection_start {
                return None;
            }
            let shorter = left_end
                .saturating_sub(left_start)
                .min(right_end.saturating_sub(right_start));
            let overlap_per_mille = if shorter == 0 {
                1_000
            } else {
                ((u128::from(intersection_end.saturating_sub(intersection_start)) * 1_000)
                    / u128::from(shorter))
                .min(1_000) as u16
            };
            Some(TranslationInboxAlignmentScore {
                exact_source_text,
                overlap_per_mille,
                source_language_matches,
                midpoint_distance_ms: left_start
                    .saturating_add(left_end)
                    .abs_diff(right_start.saturating_add(right_end))
                    / 2,
                sequence_distance,
                sequence: utterance.sequence,
            })
        }
        _ if exact_source_text || item.key.provider_sequence == utterance.sequence => {
            Some(TranslationInboxAlignmentScore {
                exact_source_text,
                overlap_per_mille: 0,
                source_language_matches,
                midpoint_distance_ms: u64::MAX,
                sequence_distance,
                sequence: utterance.sequence,
            })
        }
        _ => None,
    }
}

fn translation_inbox_evidence_eq(
    left: &TranslationInboxAlignmentScore,
    right: &TranslationInboxAlignmentScore,
) -> bool {
    left.exact_source_text == right.exact_source_text
        && left.overlap_per_mille == right.overlap_per_mille
        && left.source_language_matches == right.source_language_matches
        && left.midpoint_distance_ms == right.midpoint_distance_ms
        && left.sequence_distance == right.sequence_distance
}

fn unique_translation_inbox_candidate<'a>(
    item: &RealtimeTranslationInboxItem,
    candidates: impl Iterator<Item = &'a RealtimeUtterance>,
) -> Option<u64> {
    let mut ranked = candidates
        .filter_map(|candidate| {
            translation_inbox_alignment_score(item, candidate).map(|score| (score, candidate))
        })
        .collect::<Vec<_>>();
    ranked.sort_by(|(left, _), (right, _)| {
        right
            .exact_source_text
            .cmp(&left.exact_source_text)
            .then_with(|| right.overlap_per_mille.cmp(&left.overlap_per_mille))
            .then_with(|| {
                right
                    .source_language_matches
                    .cmp(&left.source_language_matches)
            })
            .then_with(|| left.midpoint_distance_ms.cmp(&right.midpoint_distance_ms))
            .then_with(|| left.sequence_distance.cmp(&right.sequence_distance))
            .then_with(|| left.sequence.cmp(&right.sequence))
    });
    let (best, candidate) = ranked.first()?;
    let equally_supported = ranked
        .iter()
        .take_while(|(score, _)| translation_inbox_evidence_eq(best, score))
        .map(|(_, candidate)| candidate.sequence)
        .collect::<std::collections::HashSet<_>>();
    (equally_supported.len() == 1).then_some(candidate.sequence)
}

fn upsert_translation_variant_from_conn(
    conn: &Connection,
    session_id: &str,
    sequence: u64,
    language: &str,
    text: Option<&str>,
    state: UtteranceVariantState,
    completion: Option<UtteranceCompletion>,
) -> Result<RealtimeUtterance, NotebookCaptureStoreError> {
    let language = canonical_language(language);
    let now = chrono::Utc::now().to_rfc3339();
    let utterance =
        get_machine_utterance_by_session_sequence_from_conn(conn, session_id, sequence)?
            .ok_or_else(|| {
                NotebookCaptureStoreError::NotFound(format!("utterance {session_id}:{sequence}"))
            })?;
    if utterance.has_source_lane() && canonical_language(&utterance.source_language) == language {
        return Err(NotebookCaptureStoreError::Validation(format!(
            "translation variant {language} duplicates the source language"
        )));
    }
    if let Some(existing) = utterance
        .variants
        .iter()
        .find(|variant| canonical_language(&variant.language) == language)
    {
        let is_identical_translation = existing.role == UtteranceVariantRole::Translation
            && existing.state == state
            && existing.text.as_deref() == text
            && existing.completion == completion;
        if is_identical_translation {
            let mut visible = utterance;
            apply_utterance_overrides(conn, &mut visible)?;
            return Ok(visible);
        }
        if existing.role == UtteranceVariantRole::Translation
            && existing.state == UtteranceVariantState::Ready
            && existing.completion == Some(UtteranceCompletion::Complete)
        {
            let incoming_is_final = state == UtteranceVariantState::Ready
                && completion == Some(UtteranceCompletion::Complete);
            if !incoming_is_final {
                // Complete is the absorbing owner state for one normalized
                // language lane. A later producer Partial, withdrawal, or
                // health-state downgrade is evidence only and cannot turn a
                // durable/editable Final back into speculative state.
                let mut visible = utterance;
                apply_utterance_overrides(conn, &mut visible)?;
                return Ok(visible);
            }
            return Err(NotebookCaptureStoreError::Conflict(format!(
                "final machine utterance variant {session_id}:{sequence}:{language} is immutable"
            )));
        }
    }

    conn.execute(
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
        && (utterance.translated_language.is_none()
            || utterance
                .translated_language
                .as_deref()
                .is_some_and(|legacy| canonical_language(legacy) == language));
    if updates_legacy_shadow {
        conn.execute(
            "UPDATE realtime_utterances
             SET translated_language = ?1, translated_text = ?2,
                 alignment = 'paired', updated_at = ?3
             WHERE id = ?4",
            params![language, text, now, utterance.id],
        )?;
    } else if state != UtteranceVariantState::Ready
        && utterance
            .translated_language
            .as_deref()
            .is_some_and(|legacy| canonical_language(legacy) == language)
    {
        let replacement = conn
            .query_row(
                "SELECT language, text
                 FROM realtime_utterance_variants
                 WHERE utterance_id = ?1
                   AND role = 'translation'
                   AND state = 'ready'
                 ORDER BY created_at ASC, lower(trim(language)) ASC
                 LIMIT 1",
                [&utterance.id],
                |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
            )
            .optional()?;
        if let Some((replacement_language, replacement_text)) = replacement {
            conn.execute(
                "UPDATE realtime_utterances
                 SET translated_language = ?1, translated_text = ?2,
                     alignment = 'paired', updated_at = ?3
                 WHERE id = ?4",
                params![
                    canonical_language(&replacement_language),
                    replacement_text,
                    now,
                    utterance.id
                ],
            )?;
        } else {
            let has_waiting = conn.query_row(
                "SELECT EXISTS(
                     SELECT 1 FROM realtime_utterance_variants
                     WHERE utterance_id = ?1
                       AND role = 'translation'
                       AND state = 'waiting'
                 )",
                [&utterance.id],
                |row| row.get::<_, bool>(0),
            )?;
            conn.execute(
                "UPDATE realtime_utterances
                 SET translated_language = NULL, translated_text = NULL,
                     alignment = ?1, updated_at = ?2
                 WHERE id = ?3",
                params![
                    if has_waiting {
                        UtteranceAlignment::TranslationPending.as_str()
                    } else {
                        UtteranceAlignment::SourceOnly.as_str()
                    },
                    now,
                    utterance.id
                ],
            )?;
        }
    }

    if state == UtteranceVariantState::Ready && completion == Some(UtteranceCompletion::Complete) {
        let projection_revision = bump_realtime_loro_desired_revision(conn, session_id)?;
        conn.execute(
            "UPDATE realtime_utterance_variants
             SET projection_revision = ?1
             WHERE utterance_id = ?2
               AND lower(trim(language)) = ?3
               AND role = 'translation'",
            params![
                u64_to_i64(projection_revision, "translation projection revision")?,
                utterance.id,
                language
            ],
        )?;
    }

    let mut utterance =
        get_machine_utterance_by_id_from_conn(conn, &utterance.id)?.ok_or_else(|| {
            NotebookCaptureStoreError::NotFound(format!("utterance {}", utterance.id))
        })?;
    apply_utterance_overrides(conn, &mut utterance)?;
    Ok(utterance)
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
        realtime_loro_desired_revision: i64_to_u64(row.get(31)?, "realtime Loro desired revision")
            .map_err(to_sql_conversion_error)?,
        realtime_loro_applied_revision: i64_to_u64(row.get(32)?, "realtime Loro applied revision")
            .map_err(to_sql_conversion_error)?,
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
        source_projection_revision: i64_to_u64(row.get(15)?, "source projection revision")
            .map_err(to_sql_conversion_error)?,
        source_edit_revision: 0,
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
        projection_revision: i64_to_u64(row.get(8)?, "variant projection revision")
            .map_err(to_sql_conversion_error)?,
        edit_revision: 0,
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

fn get_machine_utterance_by_id_from_conn(
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

fn get_utterance_with_overrides_by_id_from_conn(
    conn: &Connection,
    utterance_id: &str,
) -> Result<Option<RealtimeUtterance>, NotebookCaptureStoreError> {
    let mut utterance = get_machine_utterance_by_id_from_conn(conn, utterance_id)?;
    if let Some(utterance) = utterance.as_mut() {
        apply_utterance_overrides(conn, utterance)?;
    }
    Ok(utterance)
}

fn get_machine_utterance_by_session_sequence_from_conn(
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

fn list_machine_utterances_from_conn(
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

fn list_utterances_with_overrides_from_conn(
    conn: &Connection,
    session_id: &str,
) -> Result<Vec<RealtimeUtterance>, NotebookCaptureStoreError> {
    let mut utterances = list_machine_utterances_from_conn(conn, session_id)?;
    for utterance in &mut utterances {
        apply_utterance_overrides(conn, utterance)?;
    }
    Ok(utterances)
}

fn apply_utterance_overrides(
    conn: &Connection,
    utterance: &mut RealtimeUtterance,
) -> Result<(), NotebookCaptureStoreError> {
    let overrides = {
        let mut stmt = conn.prepare(
            "SELECT lane, lane_language, text,
                    machine_utterance_revision, machine_variant_revision,
                    edit_revision
             FROM realtime_utterance_overrides
             WHERE utterance_id = ?1
             ORDER BY lower(trim(lane_language)) ASC",
        )?;
        let collected = stmt
            .query_map([&utterance.id], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, i64>(3)?,
                    row.get::<_, i64>(4)?,
                    row.get::<_, i64>(5)?,
                ))
            })?
            .collect::<Result<Vec<_>, _>>()?;
        collected
    };

    for (
        lane,
        lane_language,
        text,
        machine_utterance_revision,
        machine_variant_revision,
        edit_revision,
    ) in overrides
    {
        let lane = UtteranceLane::parse(&lane)?;
        let base_utterance_revision = i64_to_u64(
            machine_utterance_revision,
            "override machine utterance revision",
        )?;
        let base_variant_revision = i64_to_u64(
            machine_variant_revision,
            "override machine variant revision",
        )?;
        let edit_revision = i64_to_u64(edit_revision, "override edit revision")?;
        if edit_revision == 0 {
            return Err(NotebookCaptureStoreError::CorruptData(format!(
                "utterance {} override has zero edit revision",
                utterance.id
            )));
        }
        if base_utterance_revision > utterance.revision {
            return Err(NotebookCaptureStoreError::CorruptData(format!(
                "utterance {} override is based on a future machine revision",
                utterance.id
            )));
        }

        let canonical_lane_language = canonical_language(&lane_language);
        let variant = utterance
            .variants
            .iter_mut()
            .find(|variant| canonical_language(&variant.language) == canonical_lane_language)
            .ok_or_else(|| {
                NotebookCaptureStoreError::CorruptData(format!(
                    "utterance {} override references missing language {}",
                    utterance.id, lane_language
                ))
            })?;
        if base_variant_revision > variant.revision {
            return Err(NotebookCaptureStoreError::CorruptData(format!(
                "utterance {} override is based on a future variant revision",
                utterance.id
            )));
        }

        match lane {
            UtteranceLane::Source
                if variant.role == UtteranceVariantRole::Source
                    && canonical_language(&utterance.source_language)
                        == canonical_lane_language =>
            {
                utterance.source_text = text.clone();
                utterance.source_edit_revision = edit_revision;
                variant.text = Some(text);
                variant.edit_revision = edit_revision;
            }
            UtteranceLane::Translated if variant.role == UtteranceVariantRole::Translation => {
                if utterance
                    .translated_language
                    .as_deref()
                    .is_some_and(|language| canonical_language(language) == canonical_lane_language)
                {
                    utterance.translated_text = Some(text.clone());
                }
                variant.text = Some(text);
                variant.edit_revision = edit_revision;
            }
            _ => {
                return Err(NotebookCaptureStoreError::CorruptData(format!(
                    "utterance {} override lane {} does not match machine language {}",
                    utterance.id,
                    lane.as_str(),
                    lane_language
                )));
            }
        }
    }
    Ok(())
}

fn get_lane_edit_revision(
    conn: &Connection,
    utterance_id: &str,
    lane_language: &str,
) -> Result<u64, NotebookCaptureStoreError> {
    let revision = conn
        .query_row(
            "SELECT edit_revision
             FROM realtime_utterance_overrides
             WHERE utterance_id = ?1 AND lane_language = ?2",
            params![utterance_id, canonical_language(lane_language)],
            |row| row.get::<_, i64>(0),
        )
        .optional()?
        .unwrap_or(0);
    i64_to_u64(revision, "lane edit revision")
}

fn machine_utterance_matches_input(
    utterance: &RealtimeUtterance,
    input: &NewRealtimeUtterance,
) -> bool {
    let source_only_update = input.translated_language.is_none() && input.translated_text.is_none();
    let explicit_translation_matches = match (
        input.translated_language.as_deref(),
        input.translated_text.as_deref(),
    ) {
        (None, None) => true,
        (Some(language), Some(text)) => {
            utterance
                .translated_language
                .as_deref()
                .is_some_and(|stored| canonical_language(stored) == canonical_language(language))
                && utterance.translated_text.as_deref() == Some(text)
        }
        _ => false,
    };
    // `und` is the absence of a language claim, so it can never contradict a
    // concrete language on the other side of an otherwise byte-identical
    // replay (an auxiliary identification may have upgraded the stored row
    // after the canonical Final was persisted without one).
    let source_language_matches = {
        let stored = canonical_language(&utterance.source_language);
        let incoming = canonical_language(&input.source_language);
        stored == incoming || stored == "und" || incoming == "und"
    };
    utterance.id == input.id
        && utterance.session_id == input.session_id
        && utterance.sequence == input.sequence
        && utterance.session_speaker_id == input.session_speaker_id
        && source_language_matches
        && utterance.source_text == input.source_text
        && utterance.source_start_ms == input.source_start_ms
        && utterance.source_end_ms == input.source_end_ms
        && explicit_translation_matches
        && utterance.completion == input.completion
        // `alignment` is a compatibility shadow once a translation variant
        // exists. A source-only replay must not conflict merely because that
        // independent lane made the aggregate presentation `paired`.
        && (source_only_update || utterance.alignment == input.alignment)
}

fn realtime_loro_projection_from_row(row: &Row<'_>) -> rusqlite::Result<RealtimeLoroProjection> {
    Ok(RealtimeLoroProjection {
        session_id: row.get(0)?,
        desired_revision: i64_to_u64(row.get(1)?, "realtime Loro desired revision")
            .map_err(to_sql_conversion_error)?,
        applied_revision: i64_to_u64(row.get(2)?, "realtime Loro applied revision")
            .map_err(to_sql_conversion_error)?,
    })
}

fn get_realtime_loro_projection_from_conn(
    conn: &Connection,
    session_id: &str,
) -> Result<Option<RealtimeLoroProjection>, NotebookCaptureStoreError> {
    conn.query_row(
        "SELECT session_id, realtime_loro_desired_revision,
                realtime_loro_applied_revision
         FROM notebook_capture_runs
         WHERE session_id = ?1",
        [session_id],
        realtime_loro_projection_from_row,
    )
    .optional()
    .map_err(Into::into)
}

fn bump_realtime_loro_desired_revision(
    conn: &Connection,
    session_id: &str,
) -> Result<u64, NotebookCaptureStoreError> {
    let updated = conn.execute(
        "UPDATE notebook_capture_runs
         SET realtime_loro_desired_revision =
                 realtime_loro_desired_revision + 1
         WHERE session_id = ?1",
        [session_id],
    )?;
    if updated == 0 {
        return Err(NotebookCaptureStoreError::NotFound(format!(
            "capture session {session_id}"
        )));
    }
    let revision = conn.query_row(
        "SELECT realtime_loro_desired_revision
         FROM notebook_capture_runs
         WHERE session_id = ?1",
        [session_id],
        |row| row.get::<_, i64>(0),
    )?;
    i64_to_u64(revision, "realtime Loro desired revision")
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

fn get_projection_mutation_for_utterance_lane(
    conn: &Connection,
    utterance_id: &str,
    lane_language: &str,
) -> Result<Option<NotebookProjectionMutation>, NotebookCaptureStoreError> {
    conn.query_row(
        &format!(
            "{PROJECTION_MUTATION_SELECT}
             WHERE utterance_id = ?1
               AND lower(trim(lane_language)) = lower(trim(?2))"
        ),
        params![utterance_id, lane_language],
        projection_mutation_from_row,
    )
    .optional()
    .map_err(Into::into)
}

fn get_projection_mutation_expected_variant_revision(
    conn: &Connection,
    mutation_id: &str,
) -> Result<u64, NotebookCaptureStoreError> {
    let revision = conn
        .query_row(
            "SELECT expected_variant_revision
             FROM notebook_projection_mutations
             WHERE id = ?1",
            [mutation_id],
            |row| row.get::<_, i64>(0),
        )
        .optional()?
        .ok_or_else(|| {
            NotebookCaptureStoreError::NotFound(format!("projection mutation {mutation_id}"))
        })?;
    i64_to_u64(revision, "expected variant revision")
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

fn ensure_realtime_session_provenance(
    conn: &Connection,
    session_id: &str,
) -> Result<(), NotebookCaptureStoreError> {
    let provenance = conn
        .query_row(
            "SELECT realtime_provider_id, realtime_model_id
             FROM notebook_capture_runs WHERE session_id = ?1",
            [session_id],
            |row| {
                Ok((
                    row.get::<_, Option<String>>(0)?,
                    row.get::<_, Option<String>>(1)?,
                ))
            },
        )
        .optional()?
        .ok_or_else(|| {
            NotebookCaptureStoreError::NotFound(format!("capture session {session_id}"))
        })?;
    match (provenance.0.as_deref(), provenance.1.as_deref()) {
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

fn ensure_utterance_lane_is_editable(
    conn: &Connection,
    session_id: &str,
    completion: UtteranceCompletion,
    projection_revision: u64,
) -> Result<(), NotebookCaptureStoreError> {
    if completion != UtteranceCompletion::Complete {
        return Err(NotebookCaptureStoreError::Conflict(
            "provisional utterance lanes remain machine-owned".into(),
        ));
    }
    let applied_revision = conn
        .query_row(
            "SELECT realtime_loro_applied_revision
             FROM notebook_capture_runs
             WHERE session_id = ?1",
            [session_id],
            |row| row.get::<_, i64>(0),
        )
        .optional()?
        .ok_or_else(|| {
            NotebookCaptureStoreError::NotFound(format!("capture session {session_id}"))
        })?;
    let applied_revision = i64_to_u64(applied_revision, "realtime Loro applied revision")?;
    if projection_revision == 0 || projection_revision > applied_revision {
        return Err(NotebookCaptureStoreError::Conflict(
            "Final utterance lanes are editable only after their Loro projection is durable".into(),
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
    value
        .trim()
        .split('-')
        .next()
        .unwrap_or(value)
        .trim()
        .to_ascii_lowercase()
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

    fn upsert_test_lanes(
        store: &NotebookCaptureStore,
        input: &NewRealtimeUtterance,
        expected_revision: Option<u64>,
    ) -> Result<RealtimeUtterance, NotebookCaptureStoreError> {
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

    fn ack_all_realtime_projection(store: &NotebookCaptureStore, session_id: &str) {
        let snapshot = store.load_realtime_loro_projection(session_id).unwrap();
        store
            .ack_realtime_loro_projection(session_id, snapshot.desired_revision)
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
    fn profile_validation_supports_one_language_and_caps_the_ordered_columns_at_three() {
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
            selected_languages: ["en", "zh", "th", "ja"]
                .into_iter()
                .map(str::to_string)
                .collect(),
            common_caption_language: None,
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

        let wrong_session = upsert_test_lanes(
            &store,
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

        let utterance = upsert_test_lanes(
            &store,
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
        let utterance = upsert_test_lanes(
            &store,
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
        assert!(matches!(
            store.stage_utterance_lane_replacement("utt-1", UtteranceLane::Translated, "您好", 0),
            Err(NotebookCaptureStoreError::Conflict(_))
        ));
        ack_all_realtime_projection(&store, "session-utterance");
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
        assert_eq!(edited.revision, 0);
        let machine = store.get_machine_utterance_by_id("utt-1").unwrap().unwrap();
        assert_eq!(machine.translated_text.as_deref(), Some("你好"));
        assert_eq!(machine.revision, 0);
    }

    #[test]
    fn realtime_loro_watermarks_track_only_new_finals_and_ack_monotonically() {
        let (_temp, store, notebook_id) = fixture();
        store.get_or_create_profile(&notebook_id).unwrap();
        create_run(&store, &new_run(&notebook_id, "watermark")).unwrap();
        claim_realtime(&store, "session-watermark");

        let mut source = NewRealtimeUtterance {
            id: "utt-watermark".into(),
            session_id: "session-watermark".into(),
            sequence: 0,
            session_speaker_id: None,
            source_language: "en".into(),
            source_text: "hel".into(),
            source_start_ms: Some(0),
            source_end_ms: Some(100),
            translated_language: None,
            translated_text: None,
            completion: UtteranceCompletion::Partial,
            alignment: UtteranceAlignment::TranslationPending,
        };
        let partial = store.upsert_utterance(&source, None).unwrap();
        assert_eq!(partial.source_text, "hel");
        store
            .upsert_translation_variant(
                "session-watermark",
                0,
                "zh",
                Some("你"),
                UtteranceVariantState::Ready,
                Some(UtteranceCompletion::Partial),
            )
            .unwrap();
        let initial = store
            .load_realtime_loro_projection("session-watermark")
            .unwrap();
        assert_eq!((initial.desired_revision, initial.applied_revision), (0, 0));
        assert_eq!(initial.machine_utterances[0].source_text, "hel");

        source.source_text = "hello".into();
        source.source_end_ms = Some(200);
        source.completion = UtteranceCompletion::Complete;
        assert!(matches!(
            store.upsert_utterance(&source, Some(99)),
            Err(NotebookCaptureStoreError::Conflict(_))
        ));
        assert_eq!(
            store
                .load_realtime_loro_projection("session-watermark")
                .unwrap()
                .desired_revision,
            0,
            "failed machine CAS and desired bump must roll back together"
        );

        let final_source = store.upsert_utterance(&source, Some(0)).unwrap();
        assert_eq!(final_source.revision, 1);
        assert_eq!(
            store
                .load_realtime_loro_projection("session-watermark")
                .unwrap()
                .desired_revision,
            1
        );
        let duplicate = store.upsert_utterance(&source, Some(0)).unwrap();
        assert_eq!(duplicate.revision, 1);
        assert_eq!(
            store
                .load_realtime_loro_projection("session-watermark")
                .unwrap()
                .desired_revision,
            1,
            "an identical repeated Final is an idempotent no-op"
        );
        let mut conflicting_source = source.clone();
        conflicting_source.source_text = "provider rewrite".into();
        assert!(matches!(
            store.upsert_utterance(&conflicting_source, Some(1)),
            Err(NotebookCaptureStoreError::Conflict(_))
        ));

        ack_all_realtime_projection(&store, "session-watermark");
        assert!(matches!(
            store.stage_utterance_variant_replacement("utt-watermark", "zh", "部分不得编辑", 1),
            Err(NotebookCaptureStoreError::Conflict(_))
        ));

        store
            .upsert_translation_variant(
                "session-watermark",
                0,
                "zh",
                Some("你好"),
                UtteranceVariantState::Ready,
                Some(UtteranceCompletion::Complete),
            )
            .unwrap();
        store
            .upsert_translation_variant(
                "session-watermark",
                0,
                "zh",
                Some("你好"),
                UtteranceVariantState::Ready,
                Some(UtteranceCompletion::Complete),
            )
            .unwrap();
        assert!(matches!(
            store.upsert_translation_variant(
                "session-watermark",
                0,
                "zh",
                Some("改写"),
                UtteranceVariantState::Ready,
                Some(UtteranceCompletion::Complete),
            ),
            Err(NotebookCaptureStoreError::Conflict(_))
        ));

        let pending = store.list_pending_realtime_loro_projections().unwrap();
        assert_eq!(pending.len(), 1);
        assert_eq!(
            (
                pending[0].session_id.as_str(),
                pending[0].desired_revision,
                pending[0].applied_revision,
            ),
            ("session-watermark", 2, 1)
        );
        let stale = store
            .ack_realtime_loro_projection("session-watermark", 0)
            .unwrap();
        assert_eq!(stale.applied_revision, 1);
        assert!(!stale.advanced);
        assert!(matches!(
            store.ack_realtime_loro_projection("session-watermark", 3),
            Err(NotebookCaptureStoreError::Conflict(_))
        ));
        let acknowledged = store
            .ack_realtime_loro_projection("session-watermark", 2)
            .unwrap();
        assert_eq!(
            (acknowledged.desired_revision, acknowledged.applied_revision),
            (2, 2)
        );
        assert!(acknowledged.advanced);
        assert!(
            !store
                .ack_realtime_loro_projection("session-watermark", 2)
                .unwrap()
                .advanced,
            "an exact repeated acknowledgement must report an idempotent no-op"
        );
        assert!(store
            .list_pending_realtime_loro_projections()
            .unwrap()
            .is_empty());
    }

    #[test]
    fn source_upsert_cannot_overwrite_or_delete_a_final_translation_variant() {
        let (_temp, store, notebook_id) = fixture();
        store.get_or_create_profile(&notebook_id).unwrap();
        create_run(&store, &new_run(&notebook_id, "cross-final")).unwrap();
        claim_realtime(&store, "session-cross-final");

        let mut source = NewRealtimeUtterance {
            id: "utt-cross-final".into(),
            session_id: "session-cross-final".into(),
            sequence: 0,
            session_speaker_id: None,
            source_language: "en".into(),
            source_text: "par".into(),
            source_start_ms: None,
            source_end_ms: None,
            translated_language: None,
            translated_text: None,
            completion: UtteranceCompletion::Partial,
            alignment: UtteranceAlignment::TranslationPending,
        };
        store.upsert_utterance(&source, None).unwrap();
        let translation_first = store
            .upsert_translation_variant(
                "session-cross-final",
                0,
                "zh",
                Some("最终译文"),
                UtteranceVariantState::Ready,
                Some(UtteranceCompletion::Complete),
            )
            .unwrap();
        assert_eq!(
            translation_first.translated_text.as_deref(),
            Some("最终译文"),
            "the first translation variant must maintain the legacy FFI shadow"
        );
        assert_eq!(translation_first.alignment, UtteranceAlignment::Paired);
        assert_eq!(
            translation_first.revision, 0,
            "translation writes must not advance the source-lane CAS"
        );

        source.source_text = "partial source may continue".into();
        let continued = store.upsert_utterance(&source, Some(0)).unwrap();
        assert_eq!(continued.revision, 1);
        assert_eq!(
            continued
                .variants
                .iter()
                .find(|variant| variant.language == "zh")
                .and_then(|variant| variant.text.as_deref()),
            Some("最终译文")
        );
        source.source_text = "partial source may continue again".into();
        let continued_again = store.upsert_utterance(&source, Some(1)).unwrap();
        assert_eq!(continued_again.revision, 2);

        let mut overwrite = source.clone();
        overwrite.translated_language = Some("zh".into());
        overwrite.translated_text = Some("被覆盖".into());
        overwrite.alignment = UtteranceAlignment::Paired;
        assert!(matches!(
            store.upsert_utterance(&overwrite, Some(2)),
            Err(NotebookCaptureStoreError::Validation(_))
        ));

        let mut collision = source.clone();
        collision.source_language = "ZH".into();
        collision.alignment = UtteranceAlignment::SourceOnly;
        let coalesced = store.upsert_utterance(&collision, Some(2)).unwrap();
        assert_eq!(coalesced.revision, 3);
        assert!(coalesced.has_source_fact());
        assert!(!coalesced.has_source_lane());
        let stable_translation = coalesced
            .variants
            .iter()
            .find(|variant| variant.language == "zh")
            .unwrap();
        assert_eq!(stable_translation.role, UtteranceVariantRole::Translation);
        assert_eq!(stable_translation.text.as_deref(), Some("最终译文"));
        assert_eq!(stable_translation.projection_revision, 1);
        assert_eq!(
            store
                .load_realtime_loro_projection("session-cross-final")
                .unwrap()
                .desired_revision,
            1,
            "same-language source evidence cannot replace or reschedule the Final owner"
        );

        let final_source = NewRealtimeUtterance {
            source_text: "final source".into(),
            completion: UtteranceCompletion::Complete,
            alignment: UtteranceAlignment::TranslationPending,
            ..source
        };
        let finalized = store.upsert_utterance(&final_source, Some(3)).unwrap();
        let translation = finalized
            .variants
            .iter()
            .find(|variant| variant.language == "zh")
            .unwrap();
        assert_eq!(translation.text.as_deref(), Some("最终译文"));
        assert_eq!(translation.completion, Some(UtteranceCompletion::Complete));
        assert_eq!(
            translation.revision, 0,
            "the exact repeated Final translation lane must be preserved as a no-op"
        );
        assert_eq!(
            store
                .load_realtime_loro_projection("session-cross-final")
                .unwrap()
                .desired_revision,
            2,
            "one translation Final and one source Final each schedule projection once"
        );
    }

    #[test]
    fn editability_and_cas_are_lane_local_across_pending_finals() {
        let (_temp, store, notebook_id) = fixture();
        store.get_or_create_profile(&notebook_id).unwrap();
        create_run(&store, &new_run(&notebook_id, "lane-watermark")).unwrap();
        claim_realtime(&store, "session-lane-watermark");

        let mut source = NewRealtimeUtterance {
            id: "utt-lane-watermark".into(),
            session_id: "session-lane-watermark".into(),
            sequence: 0,
            session_speaker_id: None,
            source_language: "EN-us".into(),
            source_text: "partial one".into(),
            source_start_ms: None,
            source_end_ms: None,
            translated_language: None,
            translated_text: None,
            completion: UtteranceCompletion::Partial,
            alignment: UtteranceAlignment::TranslationPending,
        };
        let partial = store.upsert_utterance(&source, None).unwrap();
        assert_eq!(partial.source_language, "en");
        assert_eq!(partial.source_projection_revision, 0);
        let translation = store
            .upsert_translation_variant(
                "session-lane-watermark",
                0,
                "ZH-Hant",
                Some("机器终稿"),
                UtteranceVariantState::Ready,
                Some(UtteranceCompletion::Complete),
            )
            .unwrap();
        let zh = translation
            .variants
            .iter()
            .find(|variant| variant.language == "zh")
            .unwrap();
        assert_eq!(zh.projection_revision, 1);
        store
            .ack_realtime_loro_projection("session-lane-watermark", 1)
            .unwrap();

        source.source_text = "partial two".into();
        let source_changed = store.upsert_utterance(&source, Some(0)).unwrap();
        assert_eq!(source_changed.revision, 1);
        let staged_translation = store
            .stage_utterance_variant_replacement("utt-lane-watermark", "zh-Hant", "用户终稿", 0)
            .unwrap();
        source.source_text = "partial three".into();
        store.upsert_utterance(&source, Some(1)).unwrap();
        let committed_translation = store
            .commit_projection_mutation(&staged_translation.id)
            .unwrap();
        assert_eq!(
            committed_translation
                .variants
                .iter()
                .find(|variant| variant.language == "zh")
                .and_then(|variant| variant.text.as_deref()),
            Some("用户终稿"),
            "unrelated source revisions must not fail the translation lane CAS"
        );
        let translation_edit_revision = committed_translation
            .variants
            .iter()
            .find(|variant| variant.language == "zh")
            .map(|variant| variant.edit_revision)
            .unwrap();
        assert_eq!(translation_edit_revision, 1);

        let final_source = NewRealtimeUtterance {
            source_text: "source final".into(),
            completion: UtteranceCompletion::Complete,
            ..source
        };
        let final_source = store.upsert_utterance(&final_source, Some(2)).unwrap();
        assert_eq!(final_source.source_projection_revision, 2);
        assert!(matches!(
            store.stage_utterance_lane_replacement(
                "utt-lane-watermark",
                UtteranceLane::Source,
                "source user edit",
                final_source.revision,
            ),
            Err(NotebookCaptureStoreError::Conflict(_))
        ));
        let still_editable_translation = store
            .stage_utterance_variant_replacement(
                "utt-lane-watermark",
                "ZH",
                "用户再次编辑",
                translation_edit_revision,
            )
            .unwrap();
        store
            .cancel_projection_mutation(&still_editable_translation.id)
            .unwrap();

        store
            .upsert_translation_variant(
                "session-lane-watermark",
                0,
                "th-TH",
                Some("บางส่วน"),
                UtteranceVariantState::Ready,
                Some(UtteranceCompletion::Partial),
            )
            .unwrap();
        assert!(matches!(
            store.stage_utterance_variant_replacement(
                "utt-lane-watermark",
                "th",
                "partial forbidden",
                final_source.revision,
            ),
            Err(NotebookCaptureStoreError::Conflict(_))
        ));
        store
            .ack_realtime_loro_projection("session-lane-watermark", 2)
            .unwrap();
        let source_edit = store
            .stage_utterance_lane_replacement(
                "utt-lane-watermark",
                UtteranceLane::Source,
                "source user edit",
                0,
            )
            .unwrap();
        assert_eq!(source_edit.lane_language, "en");
    }

    #[test]
    fn durable_lane_remains_editable_when_a_later_terminal_projection_fails() {
        let (_temp, store, notebook_id) = fixture();
        store.get_or_create_profile(&notebook_id).unwrap();
        create_run(&store, &new_run(&notebook_id, "terminal-lane-failure")).unwrap();
        claim_realtime(&store, "session-terminal-lane-failure");

        upsert_test_lanes(
            &store,
            &NewRealtimeUtterance {
                id: "utt-terminal-lane-failure".into(),
                session_id: "session-terminal-lane-failure".into(),
                sequence: 0,
                session_speaker_id: None,
                source_language: "en".into(),
                source_text: "durable source".into(),
                source_start_ms: None,
                source_end_ms: None,
                translated_language: None,
                translated_text: None,
                completion: UtteranceCompletion::Complete,
                alignment: UtteranceAlignment::TranslationPending,
            },
            None,
        )
        .unwrap();
        let source_ack = store
            .ack_realtime_loro_projection("session-terminal-lane-failure", 1)
            .unwrap();
        assert!(source_ack.advanced);

        let translation = store
            .upsert_translation_variant(
                "session-terminal-lane-failure",
                0,
                "zh",
                Some("pending translation"),
                UtteranceVariantState::Ready,
                Some(UtteranceCompletion::Complete),
            )
            .unwrap();
        assert_eq!(
            translation
                .variants
                .iter()
                .find(|variant| variant.language == "zh")
                .unwrap()
                .projection_revision,
            2
        );

        store
            .transition_capture(
                "run-terminal-lane-failure",
                CaptureState::Recording,
                CaptureState::Draining,
            )
            .unwrap();
        store
            .finalize_audio(
                "run-terminal-lane-failure",
                "/tmp/terminal-lane-failure.chunk.00000.enc",
                16_000,
            )
            .unwrap();
        store
            .transition_capture(
                "run-terminal-lane-failure",
                CaptureState::Draining,
                CaptureState::Completed,
            )
            .unwrap();
        store
            .set_projection_state(
                "run-terminal-lane-failure",
                ProjectionState::Pending,
                ProjectionState::Projecting,
            )
            .unwrap();
        store
            .set_projection_state(
                "run-terminal-lane-failure",
                ProjectionState::Projecting,
                ProjectionState::Failed,
            )
            .unwrap();

        let durable_source = store
            .stage_utterance_variant_replacement(
                "utt-terminal-lane-failure",
                "en",
                "user source",
                0,
            )
            .unwrap();
        assert_eq!(durable_source.lane, UtteranceLane::Source);
        assert!(matches!(
            store.stage_utterance_variant_replacement(
                "utt-terminal-lane-failure",
                "zh",
                "user translation",
                0,
            ),
            Err(NotebookCaptureStoreError::Conflict(_))
        ));
    }

    #[test]
    fn user_overrides_never_replace_machine_facts_or_projector_input() {
        let (_temp, store, notebook_id) = fixture();
        store.get_or_create_profile(&notebook_id).unwrap();
        create_run(&store, &new_run(&notebook_id, "override")).unwrap();
        claim_realtime(&store, "session-override");
        upsert_test_lanes(
            &store,
            &NewRealtimeUtterance {
                id: "utt-override".into(),
                session_id: "session-override".into(),
                sequence: 0,
                session_speaker_id: None,
                source_language: "en".into(),
                source_text: "machine source".into(),
                source_start_ms: Some(10),
                source_end_ms: Some(50),
                translated_language: Some("zh".into()),
                translated_text: Some("机器译文".into()),
                completion: UtteranceCompletion::Complete,
                alignment: UtteranceAlignment::Paired,
            },
            None,
        )
        .unwrap();
        ack_all_realtime_projection(&store, "session-override");
        let mutation = store
            .stage_utterance_lane_replacement(
                "utt-override",
                UtteranceLane::Translated,
                "用户译文",
                0,
            )
            .unwrap();
        let visible = store.commit_projection_mutation(&mutation.id).unwrap();
        assert_eq!(visible.translated_text.as_deref(), Some("用户译文"));
        assert_eq!(visible.revision, 0);
        assert_eq!(
            visible
                .variants
                .iter()
                .find(|variant| variant.language == "zh")
                .map(|variant| variant.edit_revision),
            Some(1)
        );

        let machine = store
            .get_machine_utterance_by_id("utt-override")
            .unwrap()
            .unwrap();
        assert_eq!(machine.translated_text.as_deref(), Some("机器译文"));
        assert_eq!(
            machine
                .variants
                .iter()
                .find(|variant| variant.language == "zh")
                .and_then(|variant| variant.text.as_deref()),
            Some("机器译文")
        );
        assert_eq!(machine.revision, 0);
        let snapshot = store
            .load_realtime_loro_projection("session-override")
            .unwrap();
        assert_eq!(
            snapshot.machine_utterances[0].translated_text.as_deref(),
            Some("机器译文")
        );
        let desired_before_retry = snapshot.desired_revision;

        let provider_retry = store
            .upsert_translation_variant(
                "session-override",
                0,
                "zh",
                Some("机器译文"),
                UtteranceVariantState::Ready,
                Some(UtteranceCompletion::Complete),
            )
            .unwrap();
        assert_eq!(
            provider_retry.translated_text.as_deref(),
            Some("用户译文"),
            "provider idempotence must compare machine facts, then return the UI overlay"
        );
        assert_eq!(
            store
                .load_realtime_loro_projection("session-override")
                .unwrap()
                .desired_revision,
            desired_before_retry
        );
    }

    #[test]
    fn projection_mutations_are_unique_and_serial_only_per_canonical_language() {
        let (_temp, store, notebook_id) = fixture();
        store.get_or_create_profile(&notebook_id).unwrap();
        create_run(&store, &new_run(&notebook_id, "lane-parallel")).unwrap();
        claim_realtime(&store, "session-lane-parallel");
        store
            .upsert_utterance(
                &NewRealtimeUtterance {
                    id: "utt-lane-parallel".into(),
                    session_id: "session-lane-parallel".into(),
                    sequence: 0,
                    session_speaker_id: None,
                    source_language: "zh".into(),
                    source_text: "原文".into(),
                    source_start_ms: None,
                    source_end_ms: None,
                    translated_language: None,
                    translated_text: None,
                    completion: UtteranceCompletion::Complete,
                    alignment: UtteranceAlignment::TranslationPending,
                },
                None,
            )
            .unwrap();
        for (language, text) in [("en", "machine en"), ("th", "machine th")] {
            store
                .upsert_translation_variant(
                    "session-lane-parallel",
                    0,
                    language,
                    Some(text),
                    UtteranceVariantState::Ready,
                    Some(UtteranceCompletion::Complete),
                )
                .unwrap();
        }
        ack_all_realtime_projection(&store, "session-lane-parallel");

        let en = store
            .stage_utterance_variant_replacement("utt-lane-parallel", " EN ", "user en", 0)
            .unwrap();
        let th = store
            .stage_utterance_variant_replacement("utt-lane-parallel", "th", "user th", 0)
            .unwrap();
        assert_ne!(en.id, th.id);
        assert_eq!(
            store
                .stage_utterance_variant_replacement("utt-lane-parallel", "en", "user en", 0,)
                .unwrap()
                .id,
            en.id
        );
        assert!(matches!(
            store.stage_utterance_variant_replacement("utt-lane-parallel", "En", "different", 0),
            Err(NotebookCaptureStoreError::Conflict(_))
        ));
        assert_eq!(store.list_pending_projection_mutations().unwrap().len(), 2);

        store.commit_projection_mutation(&th.id).unwrap();
        let visible = store.commit_projection_mutation(&en.id).unwrap();
        assert_eq!(
            visible
                .variants
                .iter()
                .find(|variant| variant.language == "en")
                .and_then(|variant| variant.text.as_deref()),
            Some("user en")
        );
        assert_eq!(
            visible
                .variants
                .iter()
                .find(|variant| variant.language == "th")
                .and_then(|variant| variant.text.as_deref()),
            Some("user th")
        );
        assert_eq!(
            visible
                .variants
                .iter()
                .filter(|variant| ["en", "th"].contains(&variant.language.as_str()))
                .map(|variant| (variant.language.as_str(), variant.edit_revision))
                .collect::<Vec<_>>(),
            vec![("en", 1), ("th", 1)],
            "each language lane advances its own visible edit revision"
        );
        let machine = store
            .get_machine_utterance_by_id("utt-lane-parallel")
            .unwrap()
            .unwrap();
        assert_eq!(
            machine
                .variants
                .iter()
                .find(|variant| variant.language == "en")
                .and_then(|variant| variant.text.as_deref()),
            Some("machine en")
        );
        assert_eq!(
            machine
                .variants
                .iter()
                .find(|variant| variant.language == "th")
                .and_then(|variant| variant.text.as_deref()),
            Some("machine th")
        );
    }

    #[test]
    fn concurrent_stale_edits_to_one_lane_have_a_single_winner() {
        let (temp, store, notebook_id) = fixture();
        store.get_or_create_profile(&notebook_id).unwrap();
        create_run(&store, &new_run(&notebook_id, "edit-race")).unwrap();
        claim_realtime(&store, "session-edit-race");
        store
            .upsert_utterance(
                &NewRealtimeUtterance {
                    id: "utt-edit-race".into(),
                    session_id: "session-edit-race".into(),
                    sequence: 0,
                    session_speaker_id: None,
                    source_language: "en".into(),
                    source_text: "machine".into(),
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
        ack_all_realtime_projection(&store, "session-edit-race");

        let db = temp.path().join("capture.db");
        let stores = [
            NotebookCaptureStore::new(&db).unwrap(),
            NotebookCaptureStore::new(&db).unwrap(),
        ];
        let barrier = Arc::new(std::sync::Barrier::new(2));
        let handles = stores
            .into_iter()
            .enumerate()
            .map(|(index, store)| {
                let barrier = Arc::clone(&barrier);
                std::thread::spawn(move || {
                    barrier.wait();
                    store
                        .stage_utterance_lane_replacement(
                            "utt-edit-race",
                            UtteranceLane::Source,
                            &format!("window-{index}"),
                            0,
                        )
                        .and_then(|mutation| store.commit_projection_mutation(&mutation.id))
                        .is_ok()
                })
            })
            .collect::<Vec<_>>();
        let winners = handles
            .into_iter()
            .map(|handle| handle.join().unwrap())
            .filter(|won| *won)
            .count();
        assert_eq!(winners, 1);

        let visible = store.get_utterance_by_id("utt-edit-race").unwrap().unwrap();
        assert!(["window-0", "window-1"].contains(&visible.source_text.as_str()));
        assert_eq!(visible.source_edit_revision, 1);
        assert!(matches!(
            store.stage_utterance_lane_replacement(
                "utt-edit-race",
                UtteranceLane::Source,
                "stale window retry",
                0,
            ),
            Err(NotebookCaptureStoreError::Conflict(_))
        ));
        let next = store
            .stage_utterance_lane_replacement(
                "utt-edit-race",
                UtteranceLane::Source,
                "next accepted edit",
                visible.source_edit_revision,
            )
            .unwrap();
        let next = store.commit_projection_mutation(&next.id).unwrap();
        assert_eq!(next.source_text, "next accepted edit");
        assert_eq!(next.source_edit_revision, 2);
    }

    #[test]
    fn pending_lane_edit_replays_after_reopen_and_advances_once() {
        let (temp, store, notebook_id) = fixture();
        store.get_or_create_profile(&notebook_id).unwrap();
        create_run(&store, &new_run(&notebook_id, "edit-replay")).unwrap();
        claim_realtime(&store, "session-edit-replay");
        store
            .upsert_utterance(
                &NewRealtimeUtterance {
                    id: "utt-edit-replay".into(),
                    session_id: "session-edit-replay".into(),
                    sequence: 0,
                    session_speaker_id: None,
                    source_language: "en".into(),
                    source_text: "machine".into(),
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
        ack_all_realtime_projection(&store, "session-edit-replay");
        let staged = store
            .stage_utterance_lane_replacement(
                "utt-edit-replay",
                UtteranceLane::Source,
                "durable user edit",
                0,
            )
            .unwrap();
        let mutation_id = staged.id.clone();
        drop(store);

        let reopened = NotebookCaptureStore::new(&temp.path().join("capture.db")).unwrap();
        let replayed = reopened.commit_projection_mutation(&mutation_id).unwrap();
        assert_eq!(replayed.source_text, "durable user edit");
        assert_eq!(replayed.source_edit_revision, 1);
        assert!(reopened
            .get_projection_mutation(&mutation_id)
            .unwrap()
            .is_none());
        assert!(matches!(
            reopened.commit_projection_mutation(&mutation_id),
            Err(NotebookCaptureStoreError::NotFound(_))
        ));
        assert_eq!(
            reopened
                .get_utterance_by_id("utt-edit-replay")
                .unwrap()
                .unwrap()
                .source_edit_revision,
            1,
            "replaying the same staged mutation cannot increment twice"
        );
    }

    #[test]
    fn projection_mutation_commit_checks_lane_local_machine_revision() {
        let (_temp, store, notebook_id) = fixture();
        store.get_or_create_profile(&notebook_id).unwrap();
        create_run(&store, &new_run(&notebook_id, "lane-cas")).unwrap();
        claim_realtime(&store, "session-lane-cas");
        store
            .upsert_utterance(
                &NewRealtimeUtterance {
                    id: "utt-lane-cas".into(),
                    session_id: "session-lane-cas".into(),
                    sequence: 0,
                    session_speaker_id: None,
                    source_language: "en".into(),
                    source_text: "machine".into(),
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
        ack_all_realtime_projection(&store, "session-lane-cas");
        let mutation = store
            .stage_utterance_lane_replacement("utt-lane-cas", UtteranceLane::Source, "user", 0)
            .unwrap();
        store
            .conn
            .lock()
            .unwrap()
            .execute(
                "UPDATE realtime_utterance_variants
                 SET revision = revision + 1
                 WHERE utterance_id = 'utt-lane-cas' AND role = 'source'",
                [],
            )
            .unwrap();
        assert!(matches!(
            store.commit_projection_mutation(&mutation.id),
            Err(NotebookCaptureStoreError::Conflict(_))
        ));
        assert!(store
            .get_projection_mutation(&mutation.id)
            .unwrap()
            .is_some());
        assert_eq!(
            store
                .get_machine_utterance_by_id("utt-lane-cas")
                .unwrap()
                .unwrap()
                .source_text,
            "machine"
        );
    }

    #[test]
    fn immediate_realtime_write_waits_for_short_competing_writer() {
        let (temp, store, notebook_id) = fixture();
        store.get_or_create_profile(&notebook_id).unwrap();
        create_run(&store, &new_run(&notebook_id, "busy")).unwrap();
        claim_realtime(&store, "session-busy");

        let blocker = Connection::open(temp.path().join("capture.db")).unwrap();
        blocker
            .busy_timeout(Duration::from_secs(1))
            .expect("configure competing connection");
        blocker.execute_batch("BEGIN IMMEDIATE").unwrap();

        let writer = store.clone();
        let handle = std::thread::spawn(move || {
            writer.upsert_utterance(
                &NewRealtimeUtterance {
                    id: "utt-busy".into(),
                    session_id: "session-busy".into(),
                    sequence: 0,
                    session_speaker_id: None,
                    source_language: "en".into(),
                    source_text: "waited".into(),
                    source_start_ms: None,
                    source_end_ms: None,
                    translated_language: None,
                    translated_text: None,
                    completion: UtteranceCompletion::Partial,
                    alignment: UtteranceAlignment::SourceOnly,
                },
                None,
            )
        });
        std::thread::sleep(Duration::from_millis(75));
        blocker.execute_batch("COMMIT").unwrap();

        let persisted = handle.join().unwrap().unwrap();
        assert_eq!(persisted.source_text, "waited");
    }

    #[test]
    fn auxiliary_translation_inbox_survives_reopen_and_withdrawal_is_a_tombstone() {
        let (temp, store, notebook_id) = fixture();
        store.get_or_create_profile(&notebook_id).unwrap();
        create_catalogued_run(&store, &notebook_id, "aux-inbox-reopen");
        claim_realtime(&store, "session-aux-inbox-reopen");
        let key = RealtimeTranslationInboxKey {
            session_id: "session-aux-inbox-reopen".into(),
            lane_index: 2,
            group_epoch: 0,
            provider_sequence: 7,
            target_language: "ZH-Hans".into(),
        };
        let partial = NewRealtimeTranslationInboxItem {
            key: key.clone(),
            source_language: "th".into(),
            source_text: "สวัสดี".into(),
            source_start_ms: Some(100),
            source_end_ms: Some(300),
            translated_text: Some("你".into()),
            completion: Some(UtteranceCompletion::Partial),
            withdrawn: false,
        };
        let accepted = store.upsert_translation_inbox_item(&partial).unwrap();
        assert!(accepted.changed);
        assert_eq!(accepted.item.key.target_language, "zh");
        assert_eq!(accepted.item.revision, 0);
        drop(store);

        let reopened = NotebookCaptureStore::new(&temp.path().join("capture.db")).unwrap();
        let durable = reopened
            .list_translation_inbox("session-aux-inbox-reopen")
            .unwrap();
        assert_eq!(durable.len(), 1);
        assert_eq!(durable[0].translated_text.as_deref(), Some("你"));
        assert!(!durable[0].withdrawn);

        let withdrawn = NewRealtimeTranslationInboxItem {
            key,
            source_language: "th".into(),
            source_text: "สวัสดี".into(),
            source_start_ms: Some(100),
            source_end_ms: Some(300),
            translated_text: None,
            completion: None,
            withdrawn: true,
        };
        reopened.upsert_translation_inbox_item(&withdrawn).unwrap();
        drop(reopened);
        let reopened = NotebookCaptureStore::new(&temp.path().join("capture.db")).unwrap();
        let tombstone = reopened
            .list_translation_inbox("session-aux-inbox-reopen")
            .unwrap()
            .remove(0);
        assert!(tombstone.withdrawn);
        assert_eq!(tombstone.translated_text, None);
        assert_eq!(tombstone.completion, None);
        assert_eq!(tombstone.revision, 1);
    }

    #[test]
    fn auxiliary_final_binding_is_atomic_and_replay_does_not_bump_projection() {
        let (_temp, store, notebook_id) = fixture();
        store.get_or_create_profile(&notebook_id).unwrap();
        create_catalogued_run(&store, &notebook_id, "aux-final-bind");
        claim_realtime(&store, "session-aux-final-bind");
        store
            .upsert_utterance(
                &NewRealtimeUtterance {
                    id: "utt-aux-final-bind".into(),
                    session_id: "session-aux-final-bind".into(),
                    sequence: 4,
                    session_speaker_id: None,
                    source_language: "th".into(),
                    source_text: "สวัสดี".into(),
                    source_start_ms: Some(90),
                    source_end_ms: Some(310),
                    translated_language: None,
                    translated_text: None,
                    completion: UtteranceCompletion::Partial,
                    alignment: UtteranceAlignment::TranslationPending,
                },
                None,
            )
            .unwrap();
        let key = RealtimeTranslationInboxKey {
            session_id: "session-aux-final-bind".into(),
            lane_index: 1,
            group_epoch: 0,
            provider_sequence: 7,
            target_language: "zh".into(),
        };
        let final_item = NewRealtimeTranslationInboxItem {
            key: key.clone(),
            source_language: "th".into(),
            source_text: "สวัสดี".into(),
            source_start_ms: Some(100),
            source_end_ms: Some(300),
            translated_text: Some("你好".into()),
            completion: Some(UtteranceCompletion::Complete),
            withdrawn: false,
        };
        let accepted = store.upsert_translation_inbox_item(&final_item).unwrap();
        assert_eq!(accepted.item.bound_sequence, Some(4));
        let bound = accepted
            .bound_utterance
            .expect("a uniquely matchable Final binds in its acceptance transaction");
        let zh = bound
            .variants
            .iter()
            .find(|variant| variant.language == "zh")
            .unwrap();
        assert_eq!(zh.completion, Some(UtteranceCompletion::Complete));
        assert_eq!(zh.projection_revision, 1);
        assert_eq!(
            store
                .load_realtime_loro_projection("session-aux-final-bind")
                .unwrap()
                .desired_revision,
            1
        );

        let duplicate = store.upsert_translation_inbox_item(&final_item).unwrap();
        assert!(!duplicate.changed);
        store.bind_translation_inbox_item(&key, 4).unwrap();
        assert_eq!(
            store
                .load_realtime_loro_projection("session-aux-final-bind")
                .unwrap()
                .desired_revision,
            1,
            "an identical provider Final replay must not create another Loro revision"
        );
        let durable = store
            .list_translation_inbox("session-aux-final-bind")
            .unwrap()
            .remove(0);
        assert_eq!(durable.bound_sequence, Some(4));
        assert_eq!(
            durable.bound_utterance_id.as_deref(),
            Some("utt-aux-final-bind")
        );
    }

    #[test]
    fn binding_auxiliary_fact_adopts_identified_source_language_onto_und_canonical() {
        let (_temp, store, notebook_id) = fixture();
        store.get_or_create_profile(&notebook_id).unwrap();
        create_catalogued_run(&store, &notebook_id, "aux-adopt-lang");
        claim_realtime(&store, "session-aux-adopt-lang");
        // The canonical lane finalized without any language identification.
        store
            .upsert_utterance(
                &NewRealtimeUtterance {
                    id: "utt-aux-adopt-lang".into(),
                    session_id: "session-aux-adopt-lang".into(),
                    sequence: 0,
                    session_speaker_id: None,
                    source_language: "und".into(),
                    source_text: "现在正在出发。".into(),
                    source_start_ms: Some(100),
                    source_end_ms: Some(900),
                    translated_language: None,
                    translated_text: None,
                    completion: UtteranceCompletion::Complete,
                    alignment: UtteranceAlignment::SourceOnly,
                },
                None,
            )
            .unwrap();
        // The runtime treated every selected language as a translation target
        // because the source claimed none of them.
        store
            .upsert_translation_variant(
                "session-aux-adopt-lang",
                0,
                "zh",
                None,
                UtteranceVariantState::Waiting,
                None,
            )
            .unwrap();
        let baseline_revision = store
            .load_realtime_loro_projection("session-aux-adopt-lang")
            .unwrap()
            .desired_revision;

        // An auxiliary one-way lane identified the same audio as zh.
        let accepted = store
            .upsert_translation_inbox_item(&NewRealtimeTranslationInboxItem {
                key: RealtimeTranslationInboxKey {
                    session_id: "session-aux-adopt-lang".into(),
                    lane_index: 2,
                    group_epoch: 0,
                    provider_sequence: 0,
                    target_language: "th".into(),
                },
                source_language: "zh".into(),
                source_text: "现在正在出发。".into(),
                source_start_ms: Some(100),
                source_end_ms: Some(900),
                translated_text: Some("ตอนนี้กำลังออกเดินทาง".into()),
                completion: Some(UtteranceCompletion::Complete),
                withdrawn: false,
            })
            .unwrap();
        assert_eq!(accepted.item.bound_sequence, Some(0));
        let bound = accepted
            .bound_utterance
            .expect("binding materializes the upgraded canonical row");

        assert_eq!(bound.source_language, "zh");
        let source = bound
            .variants
            .iter()
            .find(|variant| variant.role == UtteranceVariantRole::Source)
            .expect("source lane survives adoption");
        assert_eq!(source.language, "zh");
        assert_eq!(source.text.as_deref(), Some("现在正在出发。"));
        assert!(
            !bound.variants.iter().any(|variant| {
                variant.role == UtteranceVariantRole::Translation && variant.language == "zh"
            }),
            "the adopted language stops being a translation target"
        );
        let th = bound
            .variants
            .iter()
            .find(|variant| variant.language == "th")
            .expect("the auxiliary translation lane is materialized");
        assert_eq!(th.role, UtteranceVariantRole::Translation);
        assert_eq!(th.completion, Some(UtteranceCompletion::Complete));
        // The completed source lane re-materializes under its real language
        // key: adoption bumps once, the Final translation lane bumps again.
        assert_eq!(
            store
                .load_realtime_loro_projection("session-aux-adopt-lang")
                .unwrap()
                .desired_revision,
            baseline_revision + 2
        );
        assert!(source.projection_revision > baseline_revision);
    }

    #[test]
    fn und_source_replay_does_not_clobber_adopted_language() {
        let (_temp, store, notebook_id) = fixture();
        store.get_or_create_profile(&notebook_id).unwrap();
        create_catalogued_run(&store, &notebook_id, "aux-adopt-replay");
        claim_realtime(&store, "session-aux-adopt-replay");
        let partial = NewRealtimeUtterance {
            id: "utt-aux-adopt-replay".into(),
            session_id: "session-aux-adopt-replay".into(),
            sequence: 0,
            session_speaker_id: None,
            source_language: "und".into(),
            source_text: "说是中文".into(),
            source_start_ms: Some(0),
            source_end_ms: Some(400),
            translated_language: None,
            translated_text: None,
            completion: UtteranceCompletion::Partial,
            alignment: UtteranceAlignment::SourceOnly,
        };
        let persisted = store.upsert_utterance(&partial, None).unwrap();
        store
            .upsert_translation_inbox_item(&NewRealtimeTranslationInboxItem {
                key: RealtimeTranslationInboxKey {
                    session_id: "session-aux-adopt-replay".into(),
                    lane_index: 3,
                    group_epoch: 0,
                    provider_sequence: 0,
                    target_language: "en".into(),
                },
                source_language: "zh".into(),
                source_text: "说是中文".into(),
                source_start_ms: Some(0),
                source_end_ms: Some(400),
                translated_text: Some("He said it's Chinese".into()),
                completion: Some(UtteranceCompletion::Complete),
                withdrawn: false,
            })
            .unwrap();

        // The canonical assembler still believes `und` and revises the
        // partial; the learned language must survive monotonically.
        let mut revised = partial.clone();
        revised.source_text = "说是中文，为什么没有识别出来？".into();
        revised.completion = UtteranceCompletion::Complete;
        let revised = store
            .upsert_utterance(&revised, Some(persisted.revision))
            .unwrap();
        assert_eq!(revised.source_language, "zh");
        assert_eq!(revised.source_text, "说是中文，为什么没有识别出来？");
        let source = revised
            .variants
            .iter()
            .find(|variant| variant.role == UtteranceVariantRole::Source)
            .unwrap();
        assert_eq!(source.language, "zh");

        // A byte-identical replay of the now-Final fact that still carries no
        // language claim must be accepted as the same immutable fact.
        let mut replay = partial.clone();
        replay.source_text = "说是中文，为什么没有识别出来？".into();
        replay.completion = UtteranceCompletion::Complete;
        let replayed = store.upsert_utterance(&replay, None).unwrap();
        assert_eq!(replayed.source_language, "zh");
    }

    #[test]
    fn source_language_adoption_never_displaces_a_ready_translation_lane() {
        let (_temp, store, notebook_id) = fixture();
        store.get_or_create_profile(&notebook_id).unwrap();
        create_catalogued_run(&store, &notebook_id, "aux-adopt-occupied");
        claim_realtime(&store, "session-aux-adopt-occupied");
        store
            .upsert_utterance(
                &NewRealtimeUtterance {
                    id: "utt-aux-adopt-occupied".into(),
                    session_id: "session-aux-adopt-occupied".into(),
                    sequence: 0,
                    session_speaker_id: None,
                    source_language: "und".into(),
                    source_text: "ทดสอบ".into(),
                    source_start_ms: Some(0),
                    source_end_ms: Some(300),
                    translated_language: None,
                    translated_text: None,
                    completion: UtteranceCompletion::Complete,
                    alignment: UtteranceAlignment::SourceOnly,
                },
                None,
            )
            .unwrap();
        // A provider translation INTO th already owns that lane, so a later
        // fact claiming th as the source language is contested evidence.
        store
            .upsert_translation_variant(
                "session-aux-adopt-occupied",
                0,
                "th",
                Some("ทดสอบ"),
                UtteranceVariantState::Ready,
                Some(UtteranceCompletion::Complete),
            )
            .unwrap();
        let accepted = store
            .upsert_translation_inbox_item(&NewRealtimeTranslationInboxItem {
                key: RealtimeTranslationInboxKey {
                    session_id: "session-aux-adopt-occupied".into(),
                    lane_index: 3,
                    group_epoch: 0,
                    provider_sequence: 0,
                    target_language: "en".into(),
                },
                source_language: "th".into(),
                source_text: "ทดสอบ".into(),
                source_start_ms: Some(0),
                source_end_ms: Some(300),
                translated_text: Some("Test".into()),
                completion: Some(UtteranceCompletion::Complete),
                withdrawn: false,
            })
            .unwrap();
        let bound = accepted.bound_utterance.expect("binding still succeeds");
        assert_eq!(
            bound.source_language, "und",
            "a Ready translation lane blocks adoption of its language"
        );
        let th = bound
            .variants
            .iter()
            .find(|variant| variant.language == "th")
            .unwrap();
        assert_eq!(th.role, UtteranceVariantRole::Translation);
        assert_eq!(th.text.as_deref(), Some("ทดสอบ"));
    }

    #[test]
    fn contested_unique_binding_stays_unbound_instead_of_conflicting() {
        let (_temp, store, notebook_id) = fixture();
        store.get_or_create_profile(&notebook_id).unwrap();
        create_catalogued_run(&store, &notebook_id, "aux-occupied-lane");
        claim_realtime(&store, "session-aux-occupied-lane");
        store
            .upsert_utterance(
                &NewRealtimeUtterance {
                    id: "utt-aux-occupied-lane".into(),
                    session_id: "session-aux-occupied-lane".into(),
                    sequence: 0,
                    session_speaker_id: None,
                    source_language: "th".into(),
                    source_text: "ฝนตกหนัก".into(),
                    source_start_ms: Some(100),
                    source_end_ms: Some(300),
                    translated_language: None,
                    translated_text: None,
                    completion: UtteranceCompletion::Partial,
                    alignment: UtteranceAlignment::TranslationPending,
                },
                None,
            )
            .unwrap();
        let owner = store
            .upsert_translation_inbox_item(&NewRealtimeTranslationInboxItem {
                key: RealtimeTranslationInboxKey {
                    session_id: "session-aux-occupied-lane".into(),
                    lane_index: 1,
                    group_epoch: 0,
                    provider_sequence: 0,
                    target_language: "en".into(),
                },
                source_language: "th".into(),
                source_text: "ฝนตกหนัก".into(),
                source_start_ms: Some(100),
                source_end_ms: Some(300),
                translated_text: Some("Heavy rain".into()),
                completion: Some(UtteranceCompletion::Complete),
                withdrawn: false,
            })
            .unwrap();
        assert_eq!(owner.item.bound_sequence, Some(0));

        // A second auxiliary fact whose only alignment candidate is the same
        // canonical row. Its target lane is already owned, so the
        // store-authoritative fallback must keep the durable fact unbound for
        // a later pass instead of escalating the ownership conflict into a
        // capture-fatal persistence error.
        let late_key = RealtimeTranslationInboxKey {
            session_id: "session-aux-occupied-lane".into(),
            lane_index: 1,
            group_epoch: 0,
            provider_sequence: 1,
            target_language: "en".into(),
        };
        let accepted = store
            .upsert_translation_inbox_item(&NewRealtimeTranslationInboxItem {
                key: late_key.clone(),
                source_language: "th".into(),
                source_text: "แค่เริ่มต้น".into(),
                source_start_ms: Some(150),
                source_end_ms: Some(350),
                translated_text: Some("Just the beginning".into()),
                completion: Some(UtteranceCompletion::Complete),
                withdrawn: false,
            })
            .unwrap();
        assert_eq!(accepted.item.bound_sequence, None);

        let resolved = store
            .bind_translation_inbox_item_if_unique(&late_key)
            .unwrap();
        assert!(resolved.is_none());
        let inbox = store
            .list_translation_inbox("session-aux-occupied-lane")
            .unwrap();
        assert_eq!(inbox.len(), 2);
        assert_eq!(inbox[0].bound_sequence, Some(0));
        assert_eq!(inbox[1].bound_sequence, None);
    }

    #[test]
    fn auxiliary_final_claims_a_same_language_provisional_source_once() {
        let (_temp, store, notebook_id) = fixture();
        store.get_or_create_profile(&notebook_id).unwrap();
        create_catalogued_run(&store, &notebook_id, "aux-owner-first");
        claim_realtime(&store, "session-aux-owner-first");
        let source = store
            .upsert_utterance(
                &NewRealtimeUtterance {
                    id: "utt-aux-owner-first".into(),
                    session_id: "session-aux-owner-first".into(),
                    sequence: 0,
                    session_speaker_id: None,
                    source_language: "zh".into(),
                    source_text: "暂定源".into(),
                    source_start_ms: Some(0),
                    source_end_ms: Some(100),
                    translated_language: None,
                    translated_text: None,
                    completion: UtteranceCompletion::Partial,
                    alignment: UtteranceAlignment::SourceOnly,
                },
                None,
            )
            .unwrap();
        let accepted = store
            .upsert_translation_inbox_item(&NewRealtimeTranslationInboxItem {
                key: RealtimeTranslationInboxKey {
                    session_id: source.session_id.clone(),
                    lane_index: 1,
                    group_epoch: 0,
                    provider_sequence: 41,
                    target_language: "zh".into(),
                },
                source_language: "zh".into(),
                source_text: "暂定源".into(),
                source_start_ms: Some(0),
                source_end_ms: Some(100),
                translated_text: Some("辅助 Final".into()),
                completion: Some(UtteranceCompletion::Complete),
                withdrawn: false,
            })
            .unwrap();
        let claimed = accepted
            .bound_utterance
            .expect("the first bound Final must claim the language owner");
        assert!(claimed.has_source_fact());
        assert!(!claimed.has_source_lane());
        let owner = claimed
            .variants
            .iter()
            .find(|variant| variant.language == "zh")
            .unwrap();
        assert_eq!(owner.role, UtteranceVariantRole::Translation);
        assert_eq!(owner.completion, Some(UtteranceCompletion::Complete));
        assert_eq!(owner.projection_revision, 1);

        let later_source_final = store
            .upsert_utterance(
                &NewRealtimeUtterance {
                    id: claimed.id.clone(),
                    session_id: claimed.session_id.clone(),
                    sequence: claimed.sequence,
                    session_speaker_id: None,
                    source_language: "zh".into(),
                    source_text: "规范源 Final".into(),
                    source_start_ms: Some(0),
                    source_end_ms: Some(100),
                    translated_language: None,
                    translated_text: None,
                    completion: UtteranceCompletion::Complete,
                    alignment: UtteranceAlignment::SourceOnly,
                },
                Some(claimed.revision),
            )
            .unwrap();
        assert!(later_source_final.source_fact_is_complete());
        assert!(!later_source_final.has_source_lane());
        let stable_owner = later_source_final
            .variants
            .iter()
            .find(|variant| variant.language == "zh")
            .unwrap();
        assert_eq!(stable_owner.role, UtteranceVariantRole::Translation);
        assert_eq!(stable_owner.text.as_deref(), Some("辅助 Final"));
        assert_eq!(stable_owner.projection_revision, 1);
        assert_eq!(
            store
                .load_realtime_loro_projection("session-aux-owner-first")
                .unwrap()
                .desired_revision,
            1,
            "the evidence-only source Final cannot bump or replace the owner"
        );
    }

    #[test]
    fn source_final_owner_reduces_same_language_aux_final_to_evidence() {
        let (_temp, store, notebook_id) = fixture();
        store.get_or_create_profile(&notebook_id).unwrap();
        create_catalogued_run(&store, &notebook_id, "source-owner-first");
        claim_realtime(&store, "session-source-owner-first");
        let source = store
            .upsert_utterance(
                &NewRealtimeUtterance {
                    id: "utt-source-owner-first".into(),
                    session_id: "session-source-owner-first".into(),
                    sequence: 0,
                    session_speaker_id: None,
                    source_language: "zh".into(),
                    source_text: "源 Final".into(),
                    source_start_ms: Some(0),
                    source_end_ms: Some(100),
                    translated_language: None,
                    translated_text: None,
                    completion: UtteranceCompletion::Complete,
                    alignment: UtteranceAlignment::SourceOnly,
                },
                None,
            )
            .unwrap();
        let accepted = store
            .upsert_translation_inbox_item(&NewRealtimeTranslationInboxItem {
                key: RealtimeTranslationInboxKey {
                    session_id: source.session_id.clone(),
                    lane_index: 1,
                    group_epoch: 0,
                    provider_sequence: 0,
                    target_language: "zh".into(),
                },
                source_language: "zh".into(),
                source_text: "源 Final".into(),
                source_start_ms: Some(0),
                source_end_ms: Some(100),
                translated_text: Some("冗余辅助 Final".into()),
                completion: Some(UtteranceCompletion::Complete),
                withdrawn: false,
            })
            .unwrap();
        assert_eq!(accepted.item.bound_sequence, Some(0));
        assert_eq!(accepted.bound_utterance, None);
        let visible = store
            .get_machine_utterance_by_id(&source.id)
            .unwrap()
            .unwrap();
        assert!(visible.source_lane_is_complete());
        assert_eq!(visible.variants.len(), 1);
        assert_eq!(visible.variants[0].role, UtteranceVariantRole::Source);
        assert_eq!(visible.variants[0].text.as_deref(), Some("源 Final"));
        assert_eq!(
            store
                .load_realtime_loro_projection("session-source-owner-first")
                .unwrap()
                .desired_revision,
            1
        );
    }

    #[test]
    fn staged_aux_owner_edit_survives_later_same_language_source_final_evidence() {
        let (_temp, store, notebook_id) = fixture();
        store.get_or_create_profile(&notebook_id).unwrap();
        create_catalogued_run(&store, &notebook_id, "aux-owner-edit-interleave");
        claim_realtime(&store, "session-aux-owner-edit-interleave");
        let source = store
            .upsert_utterance(
                &NewRealtimeUtterance {
                    id: "utt-aux-owner-edit-interleave".into(),
                    session_id: "session-aux-owner-edit-interleave".into(),
                    sequence: 0,
                    session_speaker_id: None,
                    source_language: "zh".into(),
                    source_text: "暂定源".into(),
                    source_start_ms: Some(0),
                    source_end_ms: Some(100),
                    translated_language: None,
                    translated_text: None,
                    completion: UtteranceCompletion::Partial,
                    alignment: UtteranceAlignment::SourceOnly,
                },
                None,
            )
            .unwrap();
        let owner = store
            .upsert_translation_inbox_item(&NewRealtimeTranslationInboxItem {
                key: RealtimeTranslationInboxKey {
                    session_id: source.session_id.clone(),
                    lane_index: 1,
                    group_epoch: 0,
                    provider_sequence: 0,
                    target_language: "zh".into(),
                },
                source_language: "zh".into(),
                source_text: "暂定源".into(),
                source_start_ms: Some(0),
                source_end_ms: Some(100),
                translated_text: Some("辅助 Final".into()),
                completion: Some(UtteranceCompletion::Complete),
                withdrawn: false,
            })
            .unwrap()
            .bound_utterance
            .unwrap();
        let machine_owner = owner
            .variants
            .iter()
            .find(|variant| variant.language == "zh")
            .unwrap()
            .clone();
        ack_all_realtime_projection(&store, &source.session_id);
        let staged = store
            .stage_utterance_lane_replacement(
                &source.id,
                UtteranceLane::Translated,
                "用户编辑后的辅助 owner",
                0,
            )
            .unwrap();

        let evidence = store
            .upsert_utterance(
                &NewRealtimeUtterance {
                    id: owner.id.clone(),
                    session_id: owner.session_id.clone(),
                    sequence: owner.sequence,
                    session_speaker_id: None,
                    source_language: "zh".into(),
                    source_text: "后来到达的规范源 Final".into(),
                    source_start_ms: Some(0),
                    source_end_ms: Some(100),
                    translated_language: None,
                    translated_text: None,
                    completion: UtteranceCompletion::Complete,
                    alignment: UtteranceAlignment::SourceOnly,
                },
                Some(owner.revision),
            )
            .unwrap();
        let stable_owner = evidence
            .variants
            .iter()
            .find(|variant| variant.language == "zh")
            .unwrap();
        assert_eq!(stable_owner.role, UtteranceVariantRole::Translation);
        assert_eq!(stable_owner.revision, machine_owner.revision);
        assert_eq!(
            stable_owner.projection_revision,
            machine_owner.projection_revision
        );
        assert_eq!(
            store
                .load_realtime_loro_projection(&source.session_id)
                .unwrap()
                .desired_revision,
            machine_owner.projection_revision
        );

        let committed = store.commit_projection_mutation(&staged.id).unwrap();
        let visible = committed
            .variants
            .iter()
            .find(|variant| variant.language == "zh")
            .unwrap();
        assert_eq!(visible.text.as_deref(), Some("用户编辑后的辅助 owner"));
        assert_eq!(visible.edit_revision, 1);
        let machine = store
            .get_machine_utterance_by_id(&source.id)
            .unwrap()
            .unwrap();
        let machine = machine
            .variants
            .iter()
            .find(|variant| variant.language == "zh")
            .unwrap();
        assert_eq!(machine.text.as_deref(), Some("辅助 Final"));
        assert_eq!(machine.revision, machine_owner.revision);
    }

    #[test]
    fn staged_source_owner_edit_survives_later_same_language_aux_final_evidence() {
        let (_temp, store, notebook_id) = fixture();
        store.get_or_create_profile(&notebook_id).unwrap();
        create_catalogued_run(&store, &notebook_id, "source-owner-edit-interleave");
        claim_realtime(&store, "session-source-owner-edit-interleave");
        let owner = store
            .upsert_utterance(
                &NewRealtimeUtterance {
                    id: "utt-source-owner-edit-interleave".into(),
                    session_id: "session-source-owner-edit-interleave".into(),
                    sequence: 0,
                    session_speaker_id: None,
                    source_language: "zh".into(),
                    source_text: "源 Final".into(),
                    source_start_ms: Some(0),
                    source_end_ms: Some(100),
                    translated_language: None,
                    translated_text: None,
                    completion: UtteranceCompletion::Complete,
                    alignment: UtteranceAlignment::SourceOnly,
                },
                None,
            )
            .unwrap();
        let source_projection_revision = owner.source_projection_revision;
        ack_all_realtime_projection(&store, &owner.session_id);
        let staged = store
            .stage_utterance_lane_replacement(
                &owner.id,
                UtteranceLane::Source,
                "用户编辑后的 source owner",
                0,
            )
            .unwrap();

        let evidence = store
            .upsert_translation_inbox_item(&NewRealtimeTranslationInboxItem {
                key: RealtimeTranslationInboxKey {
                    session_id: owner.session_id.clone(),
                    lane_index: 1,
                    group_epoch: 0,
                    provider_sequence: 0,
                    target_language: "zh".into(),
                },
                source_language: "zh".into(),
                source_text: "源 Final".into(),
                source_start_ms: Some(0),
                source_end_ms: Some(100),
                translated_text: Some("冗余辅助 Final".into()),
                completion: Some(UtteranceCompletion::Complete),
                withdrawn: false,
            })
            .unwrap();
        assert_eq!(evidence.item.bound_sequence, Some(0));
        assert_eq!(evidence.bound_utterance, None);
        let stable = store
            .get_machine_utterance_by_id(&owner.id)
            .unwrap()
            .unwrap();
        assert!(stable.source_lane_is_complete());
        assert_eq!(stable.revision, owner.revision);
        assert_eq!(
            stable.source_projection_revision,
            source_projection_revision
        );
        assert_eq!(
            store
                .load_realtime_loro_projection(&owner.session_id)
                .unwrap()
                .desired_revision,
            source_projection_revision
        );

        let committed = store.commit_projection_mutation(&staged.id).unwrap();
        assert_eq!(committed.source_text, "用户编辑后的 source owner");
        assert_eq!(committed.source_edit_revision, 1);
        let machine = store
            .get_machine_utterance_by_id(&owner.id)
            .unwrap()
            .unwrap();
        assert_eq!(machine.source_text, "源 Final");
        assert_eq!(machine.revision, owner.revision);
    }

    #[test]
    fn later_source_final_in_another_language_keeps_aux_owner_editable() {
        let (_temp, store, notebook_id) = fixture();
        store.get_or_create_profile(&notebook_id).unwrap();
        create_catalogued_run(&store, &notebook_id, "independent-final-owners");
        claim_realtime(&store, "session-independent-final-owners");
        let source = store
            .upsert_utterance(
                &NewRealtimeUtterance {
                    id: "utt-independent-final-owners".into(),
                    session_id: "session-independent-final-owners".into(),
                    sequence: 0,
                    session_speaker_id: None,
                    source_language: "zh".into(),
                    source_text: "暂定".into(),
                    source_start_ms: Some(0),
                    source_end_ms: Some(100),
                    translated_language: None,
                    translated_text: None,
                    completion: UtteranceCompletion::Partial,
                    alignment: UtteranceAlignment::SourceOnly,
                },
                None,
            )
            .unwrap();
        let aux_owner = store
            .upsert_translation_inbox_item(&NewRealtimeTranslationInboxItem {
                key: RealtimeTranslationInboxKey {
                    session_id: source.session_id.clone(),
                    lane_index: 1,
                    group_epoch: 0,
                    provider_sequence: 0,
                    target_language: "zh".into(),
                },
                source_language: "zh".into(),
                source_text: "暂定".into(),
                source_start_ms: Some(0),
                source_end_ms: Some(100),
                translated_text: Some("中文 Final".into()),
                completion: Some(UtteranceCompletion::Complete),
                withdrawn: false,
            })
            .unwrap()
            .bound_utterance
            .unwrap();
        let source_owner = store
            .upsert_utterance(
                &NewRealtimeUtterance {
                    id: aux_owner.id.clone(),
                    session_id: aux_owner.session_id.clone(),
                    sequence: aux_owner.sequence,
                    session_speaker_id: None,
                    source_language: "th".into(),
                    source_text: "ภาษาไทย Final".into(),
                    source_start_ms: Some(0),
                    source_end_ms: Some(100),
                    translated_language: None,
                    translated_text: None,
                    completion: UtteranceCompletion::Complete,
                    alignment: UtteranceAlignment::SourceOnly,
                },
                Some(aux_owner.revision),
            )
            .unwrap();
        assert!(source_owner.source_lane_is_complete());
        let zh = source_owner
            .variants
            .iter()
            .find(|variant| variant.language == "zh")
            .unwrap();
        let th = source_owner
            .variants
            .iter()
            .find(|variant| variant.language == "th")
            .unwrap();
        assert_eq!(zh.role, UtteranceVariantRole::Translation);
        assert_eq!(zh.projection_revision, 1);
        assert_eq!(th.role, UtteranceVariantRole::Source);
        assert_eq!(th.projection_revision, 2);
        assert_eq!(
            store
                .load_realtime_loro_projection("session-independent-final-owners")
                .unwrap()
                .desired_revision,
            2
        );
    }

    #[test]
    fn source_language_revision_preserves_an_existing_translation_final_owner() {
        let (_temp, store, notebook_id) = fixture();
        store.get_or_create_profile(&notebook_id).unwrap();
        create_catalogued_run(&store, &notebook_id, "source-revises-to-owner");
        claim_realtime(&store, "session-source-revises-to-owner");
        let source = store
            .upsert_utterance(
                &NewRealtimeUtterance {
                    id: "utt-source-revises-to-owner".into(),
                    session_id: "session-source-revises-to-owner".into(),
                    sequence: 0,
                    session_speaker_id: None,
                    source_language: "th".into(),
                    source_text: "ชั่วคราว".into(),
                    source_start_ms: Some(0),
                    source_end_ms: Some(100),
                    translated_language: None,
                    translated_text: None,
                    completion: UtteranceCompletion::Partial,
                    alignment: UtteranceAlignment::TranslationPending,
                },
                None,
            )
            .unwrap();
        let translated = store
            .upsert_translation_inbox_item(&NewRealtimeTranslationInboxItem {
                key: RealtimeTranslationInboxKey {
                    session_id: source.session_id.clone(),
                    lane_index: 1,
                    group_epoch: 0,
                    provider_sequence: 0,
                    target_language: "zh".into(),
                },
                source_language: "th".into(),
                source_text: "ชั่วคราว".into(),
                source_start_ms: Some(0),
                source_end_ms: Some(100),
                translated_text: Some("既有 Final".into()),
                completion: Some(UtteranceCompletion::Complete),
                withdrawn: false,
            })
            .unwrap()
            .bound_utterance
            .unwrap();
        let revised = store
            .upsert_utterance(
                &NewRealtimeUtterance {
                    id: translated.id.clone(),
                    session_id: translated.session_id.clone(),
                    sequence: translated.sequence,
                    session_speaker_id: None,
                    source_language: "zh".into(),
                    source_text: "后来识别的源".into(),
                    source_start_ms: Some(0),
                    source_end_ms: Some(100),
                    translated_language: None,
                    translated_text: None,
                    completion: UtteranceCompletion::Complete,
                    alignment: UtteranceAlignment::SourceOnly,
                },
                Some(translated.revision),
            )
            .unwrap();
        assert!(revised.source_fact_is_complete());
        assert!(!revised.has_source_lane());
        assert_eq!(revised.variants.len(), 1);
        assert_eq!(revised.variants[0].role, UtteranceVariantRole::Translation);
        assert_eq!(revised.variants[0].text.as_deref(), Some("既有 Final"));
        assert_eq!(revised.variants[0].projection_revision, 1);
        assert_eq!(
            store
                .load_realtime_loro_projection("session-source-revises-to-owner")
                .unwrap()
                .desired_revision,
            1
        );
    }

    #[test]
    fn source_withdrawal_falls_back_to_same_language_aux_partial_atomically() {
        let (_temp, store, notebook_id) = fixture();
        store.get_or_create_profile(&notebook_id).unwrap();
        create_catalogued_run(&store, &notebook_id, "source-withdraw-aux-fallback");
        claim_realtime(&store, "session-source-withdraw-aux-fallback");
        let source = store
            .upsert_utterance(
                &NewRealtimeUtterance {
                    id: "utt-source-withdraw-aux-fallback".into(),
                    session_id: "session-source-withdraw-aux-fallback".into(),
                    sequence: 0,
                    session_speaker_id: None,
                    source_language: "zh".into(),
                    source_text: "暂定".into(),
                    source_start_ms: Some(0),
                    source_end_ms: Some(100),
                    translated_language: None,
                    translated_text: None,
                    completion: UtteranceCompletion::Partial,
                    alignment: UtteranceAlignment::SourceOnly,
                },
                None,
            )
            .unwrap();
        let accepted = store
            .upsert_translation_inbox_item(&NewRealtimeTranslationInboxItem {
                key: RealtimeTranslationInboxKey {
                    session_id: source.session_id.clone(),
                    lane_index: 1,
                    group_epoch: 0,
                    provider_sequence: 41,
                    target_language: "zh".into(),
                },
                source_language: "zh".into(),
                source_text: "暂定".into(),
                source_start_ms: Some(0),
                source_end_ms: Some(100),
                translated_text: Some("辅助 Partial".into()),
                completion: Some(UtteranceCompletion::Partial),
                withdrawn: false,
            })
            .unwrap();
        assert_eq!(
            accepted.item.bound_sequence,
            Some(0),
            "identity binds while the source Partial retains display priority"
        );

        let fallback = store
            .remove_partial_utterance(&source.session_id, source.sequence, source.revision, None)
            .unwrap()
            .expect("durable auxiliary Partial keeps the shell alive");
        assert!(!fallback.has_source_fact());
        assert!(!fallback.has_source_lane());
        let lane = fallback
            .variants
            .iter()
            .find(|variant| variant.language == "zh")
            .unwrap();
        assert_eq!(lane.role, UtteranceVariantRole::Translation);
        assert_eq!(lane.completion, Some(UtteranceCompletion::Partial));
        assert_eq!(lane.text.as_deref(), Some("辅助 Partial"));
        assert_eq!(lane.projection_revision, 0);
        assert_eq!(
            store
                .list_translation_inbox(&source.session_id)
                .unwrap()
                .remove(0)
                .bound_sequence,
            Some(0)
        );
        assert_eq!(
            store
                .load_realtime_loro_projection(&source.session_id)
                .unwrap()
                .desired_revision,
            0
        );
    }

    #[test]
    fn source_partial_revisions_do_not_advance_an_unchanged_bound_aux_lane() {
        let (_temp, store, notebook_id) = fixture();
        store.get_or_create_profile(&notebook_id).unwrap();
        create_catalogued_run(&store, &notebook_id, "source-replay-aux-noop");
        claim_realtime(&store, "session-source-replay-aux-noop");
        let source = store
            .upsert_utterance(
                &NewRealtimeUtterance {
                    id: "utt-source-replay-aux-noop".into(),
                    session_id: "session-source-replay-aux-noop".into(),
                    sequence: 0,
                    session_speaker_id: None,
                    source_language: "th".into(),
                    source_text: "ร่างแรก".into(),
                    source_start_ms: Some(0),
                    source_end_ms: Some(100),
                    translated_language: None,
                    translated_text: None,
                    completion: UtteranceCompletion::Partial,
                    alignment: UtteranceAlignment::TranslationPending,
                },
                None,
            )
            .unwrap();
        let accepted = store
            .upsert_translation_inbox_item(&NewRealtimeTranslationInboxItem {
                key: RealtimeTranslationInboxKey {
                    session_id: source.session_id.clone(),
                    lane_index: 1,
                    group_epoch: 0,
                    provider_sequence: 0,
                    target_language: "zh".into(),
                },
                source_language: "th".into(),
                source_text: "ร่างแรก".into(),
                source_start_ms: Some(0),
                source_end_ms: Some(100),
                translated_text: Some("辅助草稿".into()),
                completion: Some(UtteranceCompletion::Partial),
                withdrawn: false,
            })
            .unwrap();
        let first_visible = accepted
            .bound_utterance
            .expect("different-language auxiliary Partial materializes immediately");
        let first_aux_revision = first_visible
            .variants
            .iter()
            .find(|variant| variant.language == "zh")
            .unwrap()
            .revision;

        let revised = store
            .upsert_utterance(
                &NewRealtimeUtterance {
                    source_text: "ร่างที่สอง".into(),
                    ..NewRealtimeUtterance {
                        id: source.id.clone(),
                        session_id: source.session_id.clone(),
                        sequence: source.sequence,
                        session_speaker_id: None,
                        source_language: source.source_language.clone(),
                        source_text: source.source_text.clone(),
                        source_start_ms: source.source_start_ms,
                        source_end_ms: source.source_end_ms,
                        translated_language: None,
                        translated_text: None,
                        completion: UtteranceCompletion::Partial,
                        alignment: UtteranceAlignment::TranslationPending,
                    }
                },
                Some(source.revision),
            )
            .unwrap();
        let replayed_aux = revised
            .variants
            .iter()
            .find(|variant| variant.language == "zh")
            .unwrap();
        assert_eq!(replayed_aux.text.as_deref(), Some("辅助草稿"));
        assert_eq!(
            replayed_aux.revision, first_aux_revision,
            "replaying unchanged bound evidence cannot mutate that lane's CAS"
        );
        assert_eq!(
            store
                .load_realtime_loro_projection(&source.session_id)
                .unwrap()
                .desired_revision,
            0
        );
    }

    #[test]
    fn aux_withdrawal_then_source_withdrawal_collects_same_language_partial_shell() {
        let (_temp, store, notebook_id) = fixture();
        store.get_or_create_profile(&notebook_id).unwrap();
        create_catalogued_run(&store, &notebook_id, "withdraw-order-shell-gc");
        claim_realtime(&store, "session-withdraw-order-shell-gc");
        let source = store
            .upsert_utterance(
                &NewRealtimeUtterance {
                    id: "utt-withdraw-order-shell-gc".into(),
                    session_id: "session-withdraw-order-shell-gc".into(),
                    sequence: 0,
                    session_speaker_id: None,
                    source_language: "zh".into(),
                    source_text: "暂定".into(),
                    source_start_ms: Some(0),
                    source_end_ms: Some(100),
                    translated_language: None,
                    translated_text: None,
                    completion: UtteranceCompletion::Partial,
                    alignment: UtteranceAlignment::SourceOnly,
                },
                None,
            )
            .unwrap();
        let key = RealtimeTranslationInboxKey {
            session_id: source.session_id.clone(),
            lane_index: 1,
            group_epoch: 0,
            provider_sequence: 0,
            target_language: "zh".into(),
        };
        let accepted = store
            .upsert_translation_inbox_item(&NewRealtimeTranslationInboxItem {
                key: key.clone(),
                source_language: "zh".into(),
                source_text: "暂定".into(),
                source_start_ms: Some(0),
                source_end_ms: Some(100),
                translated_text: Some("辅助 Partial".into()),
                completion: Some(UtteranceCompletion::Partial),
                withdrawn: false,
            })
            .unwrap();
        assert_eq!(accepted.item.bound_sequence, Some(0));
        assert_eq!(accepted.bound_utterance, None);

        let withdrawn = store
            .upsert_translation_inbox_item(&NewRealtimeTranslationInboxItem {
                key,
                source_language: "zh".into(),
                source_text: "暂定".into(),
                source_start_ms: Some(0),
                source_end_ms: Some(100),
                translated_text: None,
                completion: None,
                withdrawn: true,
            })
            .unwrap();
        assert_eq!(
            withdrawn.removed_bound_sequence, None,
            "the source-owned shell still exists after the evidence tombstone"
        );
        assert_eq!(withdrawn.item.bound_sequence, Some(0));

        assert!(store
            .remove_partial_utterance(&source.session_id, source.sequence, source.revision, None,)
            .unwrap()
            .is_none());
        assert!(store
            .list_utterances(&source.session_id)
            .unwrap()
            .is_empty());
        let tombstone = store
            .list_translation_inbox(&source.session_id)
            .unwrap()
            .remove(0);
        assert!(tombstone.withdrawn);
        assert_eq!(tombstone.bound_sequence, None);
        assert_eq!(tombstone.bound_utterance_id, None);
    }

    #[test]
    fn recovered_terminal_run_binds_precrash_aux_final_once() {
        let (temp, store, notebook_id) = fixture();
        store.get_or_create_profile(&notebook_id).unwrap();
        create_catalogued_run(&store, &notebook_id, "aux-recovery");
        claim_realtime(&store, "session-aux-recovery");
        store
            .upsert_translation_inbox_item(&NewRealtimeTranslationInboxItem {
                key: RealtimeTranslationInboxKey {
                    session_id: "session-aux-recovery".into(),
                    lane_index: 2,
                    group_epoch: 0,
                    provider_sequence: 3,
                    target_language: "zh".into(),
                },
                source_language: "th".into(),
                source_text: "สวัสดี".into(),
                source_start_ms: Some(100),
                source_end_ms: Some(300),
                translated_text: Some("你好".into()),
                completion: Some(UtteranceCompletion::Complete),
                withdrawn: false,
            })
            .unwrap();
        store
            .upsert_utterance(
                &NewRealtimeUtterance {
                    id: "utt-aux-recovery".into(),
                    session_id: "session-aux-recovery".into(),
                    sequence: 3,
                    session_speaker_id: None,
                    source_language: "th".into(),
                    source_text: "สวัสดี".into(),
                    source_start_ms: Some(100),
                    source_end_ms: Some(300),
                    translated_language: None,
                    translated_text: None,
                    completion: UtteranceCompletion::Partial,
                    alignment: UtteranceAlignment::TranslationPending,
                },
                None,
            )
            .unwrap();
        drop(store);

        let reopened = NotebookCaptureStore::new(&temp.path().join("capture.db")).unwrap();
        assert_eq!(reopened.recover_unfinished_runs().unwrap(), 1);
        assert_eq!(
            reopened
                .get_run_for_session("session-aux-recovery")
                .unwrap()
                .unwrap()
                .capture_state,
            CaptureState::Interrupted
        );
        assert_eq!(
            reopened
                .reconcile_translation_inbox_after_recovery("session-aux-recovery")
                .unwrap(),
            1
        );
        let recovered = reopened
            .list_utterances("session-aux-recovery")
            .unwrap()
            .remove(0);
        let zh = recovered
            .variants
            .iter()
            .find(|variant| variant.language == "zh")
            .unwrap();
        assert_eq!(zh.completion, Some(UtteranceCompletion::Complete));
        assert_eq!(zh.projection_revision, 1);
        assert_eq!(
            reopened
                .load_realtime_loro_projection("session-aux-recovery")
                .unwrap()
                .desired_revision,
            1
        );
        assert_eq!(
            reopened
                .reconcile_translation_inbox_after_recovery("session-aux-recovery")
                .unwrap(),
            0
        );
        assert_eq!(
            reopened
                .load_realtime_loro_projection("session-aux-recovery")
                .unwrap()
                .desired_revision,
            1
        );
    }

    #[test]
    fn recovery_leaves_ambiguous_or_nonzero_epoch_aux_facts_unbound() {
        let (_temp, store, notebook_id) = fixture();
        store.get_or_create_profile(&notebook_id).unwrap();
        create_catalogued_run(&store, &notebook_id, "aux-ambiguous");
        claim_realtime(&store, "session-aux-ambiguous");
        for sequence in [0, 2] {
            store
                .upsert_utterance(
                    &NewRealtimeUtterance {
                        id: format!("utt-aux-ambiguous-{sequence}"),
                        session_id: "session-aux-ambiguous".into(),
                        sequence,
                        session_speaker_id: None,
                        source_language: "th".into(),
                        source_text: "ซ้ำ".into(),
                        source_start_ms: Some(100),
                        source_end_ms: Some(300),
                        translated_language: None,
                        translated_text: None,
                        completion: UtteranceCompletion::Partial,
                        alignment: UtteranceAlignment::TranslationPending,
                    },
                    None,
                )
                .unwrap();
        }
        for (group_epoch, provider_sequence, text) in [(0, 1, "歧义"), (9, 0, "不连续")] {
            store
                .upsert_translation_inbox_item(&NewRealtimeTranslationInboxItem {
                    key: RealtimeTranslationInboxKey {
                        session_id: "session-aux-ambiguous".into(),
                        lane_index: 1,
                        group_epoch,
                        provider_sequence,
                        target_language: "zh".into(),
                    },
                    source_language: "th".into(),
                    source_text: "ซ้ำ".into(),
                    source_start_ms: Some(100),
                    source_end_ms: Some(300),
                    translated_text: Some(text.into()),
                    completion: Some(UtteranceCompletion::Complete),
                    withdrawn: false,
                })
                .unwrap();
        }
        store.recover_unfinished_runs().unwrap();
        assert_eq!(
            store
                .reconcile_translation_inbox_after_recovery("session-aux-ambiguous")
                .unwrap(),
            0
        );
        let inbox = store
            .list_translation_inbox("session-aux-ambiguous")
            .unwrap();
        assert_eq!(inbox.len(), 2);
        assert!(inbox.iter().all(|item| item.bound_sequence.is_none()));
        assert_eq!(
            store
                .load_realtime_loro_projection("session-aux-ambiguous")
                .unwrap()
                .desired_revision,
            0
        );
    }

    #[test]
    fn withdrawn_bound_partial_clears_lane_and_shell_delete_releases_binding() {
        let (_temp, store, notebook_id) = fixture();
        store.get_or_create_profile(&notebook_id).unwrap();
        create_catalogued_run(&store, &notebook_id, "aux-withdraw");
        claim_realtime(&store, "session-aux-withdraw");
        let source = store
            .upsert_utterance(
                &NewRealtimeUtterance {
                    id: "utt-aux-withdraw".into(),
                    session_id: "session-aux-withdraw".into(),
                    sequence: 0,
                    session_speaker_id: None,
                    source_language: "th".into(),
                    source_text: "ชั่วคราว".into(),
                    source_start_ms: Some(0),
                    source_end_ms: Some(100),
                    translated_language: None,
                    translated_text: None,
                    completion: UtteranceCompletion::Partial,
                    alignment: UtteranceAlignment::TranslationPending,
                },
                None,
            )
            .unwrap();
        let key = RealtimeTranslationInboxKey {
            session_id: "session-aux-withdraw".into(),
            lane_index: 1,
            group_epoch: 0,
            provider_sequence: 0,
            target_language: "zh".into(),
        };
        store
            .upsert_translation_inbox_item(&NewRealtimeTranslationInboxItem {
                key: key.clone(),
                source_language: "th".into(),
                source_text: "ชั่วคราว".into(),
                source_start_ms: Some(0),
                source_end_ms: Some(100),
                translated_text: Some("临时".into()),
                completion: Some(UtteranceCompletion::Partial),
                withdrawn: false,
            })
            .unwrap();
        let shell = store
            .remove_partial_utterance("session-aux-withdraw", 0, source.revision, None)
            .unwrap()
            .expect("the bound auxiliary Partial keeps the shell alive");
        assert!(!shell.has_source_lane());

        let withdrawn = store
            .upsert_translation_inbox_item(&NewRealtimeTranslationInboxItem {
                key,
                source_language: "th".into(),
                source_text: "ชั่วคราว".into(),
                source_start_ms: Some(0),
                source_end_ms: Some(100),
                translated_text: None,
                completion: None,
                withdrawn: true,
            })
            .unwrap();
        assert_eq!(withdrawn.bound_utterance, None);
        assert_eq!(withdrawn.removed_bound_sequence, Some(0));
        assert_eq!(
            withdrawn.removed_bound_utterance_id.as_deref(),
            Some("utt-aux-withdraw")
        );
        assert!(store
            .list_utterances("session-aux-withdraw")
            .unwrap()
            .is_empty());
        let tombstone = store
            .list_translation_inbox("session-aux-withdraw")
            .unwrap()
            .remove(0);
        assert!(tombstone.withdrawn);
        assert_eq!(tombstone.bound_utterance_id, None);
        assert_eq!(tombstone.bound_sequence, None);
    }

    #[test]
    fn stream_end_marks_waiting_variants_outside_runtime_cache_unavailable() {
        let (_temp, store, notebook_id) = fixture();
        store.get_or_create_profile(&notebook_id).unwrap();
        create_catalogued_run(&store, &notebook_id, "waiting-session-wide");
        claim_realtime(&store, "session-waiting-session-wide");
        for sequence in 0..140 {
            store
                .upsert_utterance(
                    &NewRealtimeUtterance {
                        id: format!("utt-waiting-session-wide-{sequence}"),
                        session_id: "session-waiting-session-wide".into(),
                        sequence,
                        session_speaker_id: None,
                        source_language: "th".into(),
                        source_text: format!("source-{sequence}"),
                        source_start_ms: Some(sequence * 100),
                        source_end_ms: Some(sequence * 100 + 50),
                        translated_language: None,
                        translated_text: None,
                        completion: UtteranceCompletion::Partial,
                        alignment: UtteranceAlignment::TranslationPending,
                    },
                    None,
                )
                .unwrap();
            store
                .upsert_translation_variant(
                    "session-waiting-session-wide",
                    sequence,
                    "zh",
                    None,
                    UtteranceVariantState::Waiting,
                    None,
                )
                .unwrap();
        }
        let updates = store
            .mark_waiting_translation_variants_unavailable("session-waiting-session-wide")
            .unwrap();
        assert_eq!(updates.len(), 140);
        let utterances = store
            .list_utterances("session-waiting-session-wide")
            .unwrap();
        assert_eq!(utterances.len(), 140);
        assert!(utterances.iter().all(|utterance| {
            utterance.variants.iter().any(|variant| {
                variant.language == "zh" && variant.state == UtteranceVariantState::Unavailable
            })
        }));
    }

    #[test]
    fn active_reconcile_binds_old_durable_aux_after_process_cache_eviction() {
        let (_temp, store, notebook_id) = fixture();
        store.get_or_create_profile(&notebook_id).unwrap();
        create_catalogued_run(&store, &notebook_id, "aux-bounded-reconcile");
        claim_realtime(&store, "session-aux-bounded-reconcile");
        for provider_sequence in 0..385 {
            store
                .upsert_translation_inbox_item(&NewRealtimeTranslationInboxItem {
                    key: RealtimeTranslationInboxKey {
                        session_id: "session-aux-bounded-reconcile".into(),
                        lane_index: 1,
                        group_epoch: 0,
                        provider_sequence,
                        target_language: "zh".into(),
                    },
                    source_language: "th".into(),
                    source_text: format!("source-{provider_sequence}"),
                    source_start_ms: Some(provider_sequence * 100),
                    source_end_ms: Some(provider_sequence * 100 + 50),
                    translated_text: Some(format!("译文-{provider_sequence}")),
                    completion: Some(UtteranceCompletion::Partial),
                    withdrawn: false,
                })
                .unwrap();
        }
        store
            .upsert_utterance(
                &NewRealtimeUtterance {
                    id: "utt-aux-bounded-reconcile-0".into(),
                    session_id: "session-aux-bounded-reconcile".into(),
                    sequence: 0,
                    session_speaker_id: None,
                    source_language: "th".into(),
                    source_text: "source-0".into(),
                    source_start_ms: Some(0),
                    source_end_ms: Some(50),
                    translated_language: None,
                    translated_text: None,
                    completion: UtteranceCompletion::Partial,
                    alignment: UtteranceAlignment::TranslationPending,
                },
                None,
            )
            .unwrap();
        let bindings = store
            .reconcile_active_translation_inbox("session-aux-bounded-reconcile")
            .unwrap();
        assert_eq!(bindings.len(), 1);
        assert_eq!(bindings[0].key.provider_sequence, 0);
        assert_eq!(bindings[0].canonical_sequence, 0);
        let inbox = store
            .list_translation_inbox("session-aux-bounded-reconcile")
            .unwrap();
        assert_eq!(inbox.len(), 385);
        assert_eq!(inbox[0].bound_sequence, Some(0));
        assert_eq!(
            store
                .list_utterances("session-aux-bounded-reconcile")
                .unwrap()[0]
                .variants
                .iter()
                .find(|variant| variant.language == "zh")
                .and_then(|variant| variant.text.as_deref()),
            Some("译文-0")
        );
    }

    #[test]
    fn multilingual_variants_track_waiting_ready_failures_and_language_edits() {
        let (_temp, store, notebook_id) = fixture();
        store.get_or_create_profile(&notebook_id).unwrap();
        create_catalogued_run(&store, &notebook_id, "variants");
        claim_realtime(&store, "session-variants");
        let canonical = upsert_test_lanes(
            &store,
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
        ack_all_realtime_projection(&store, "session-variants");
        let staged = store
            .stage_utterance_variant_replacement("utt-variants", "EN", "Welcome!", 0)
            .unwrap();
        assert_eq!(staged.lane, UtteranceLane::Translated);
        assert_eq!(staged.lane_language, "en");
        let edited = store.commit_projection_mutation(&staged.id).unwrap();
        assert_eq!(edited.revision, 0);
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

        let initial = upsert_test_lanes(
            &store,
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

        let revised = upsert_test_lanes(
            &store,
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

        assert_eq!(revised.source_language, "zh");
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
    fn withdrawn_partial_source_keeps_a_final_translation_shell_without_a_source_lane() {
        let (_temp, store, notebook_id) = fixture();
        store.get_or_create_profile(&notebook_id).unwrap();
        create_catalogued_run(&store, &notebook_id, "source-shell");
        claim_realtime(&store, "session-source-shell");

        let source = store
            .upsert_utterance(
                &NewRealtimeUtterance {
                    id: "utt-source-shell".into(),
                    session_id: "session-source-shell".into(),
                    sequence: 0,
                    session_speaker_id: None,
                    source_language: "en".into(),
                    source_text: "speculative".into(),
                    source_start_ms: Some(0),
                    source_end_ms: Some(100),
                    translated_language: None,
                    translated_text: None,
                    completion: UtteranceCompletion::Partial,
                    alignment: UtteranceAlignment::TranslationPending,
                },
                None,
            )
            .unwrap();
        let translated = store
            .upsert_translation_variant(
                "session-source-shell",
                0,
                "zh",
                Some("已完成"),
                UtteranceVariantState::Ready,
                Some(UtteranceCompletion::Complete),
            )
            .unwrap();
        assert!(translated.has_source_lane());
        assert_eq!(
            store
                .load_realtime_loro_projection("session-source-shell")
                .unwrap()
                .desired_revision,
            1
        );

        let shell = store
            .remove_partial_utterance("session-source-shell", 0, source.revision, None)
            .unwrap()
            .expect("the Final translation must retain its utterance shell");
        assert!(!shell.has_source_lane());
        assert_eq!(shell.revision, source.revision + 1);
        assert!(shell.source_text.is_empty());
        assert_eq!(shell.source_start_ms, None);
        assert_eq!(shell.source_end_ms, None);
        assert!(shell.variants.iter().any(|variant| {
            variant.role == UtteranceVariantRole::Translation
                && variant.language == "zh"
                && variant.text.as_deref() == Some("已完成")
                && variant.completion == Some(UtteranceCompletion::Complete)
        }));

        let restored = store
            .upsert_utterance(
                &NewRealtimeUtterance {
                    id: shell.id.clone(),
                    session_id: shell.session_id.clone(),
                    sequence: shell.sequence,
                    session_speaker_id: None,
                    source_language: "en".into(),
                    source_text: "returned".into(),
                    source_start_ms: Some(0),
                    source_end_ms: Some(120),
                    translated_language: None,
                    translated_text: None,
                    completion: UtteranceCompletion::Partial,
                    alignment: UtteranceAlignment::TranslationPending,
                },
                Some(shell.revision),
            )
            .unwrap();
        assert!(restored.has_source_lane());
        assert!(restored.variants.iter().any(|variant| {
            variant.role == UtteranceVariantRole::Translation
                && variant.language == "zh"
                && variant.completion == Some(UtteranceCompletion::Complete)
        }));
    }

    #[test]
    fn source_withdrawal_and_translation_final_commit_as_one_lane_delta() {
        let (_temp, store, notebook_id) = fixture();
        store.get_or_create_profile(&notebook_id).unwrap();
        create_catalogued_run(&store, &notebook_id, "atomic-lane-delta");
        claim_realtime(&store, "session-atomic-lane-delta");
        let source = store
            .upsert_utterance(
                &NewRealtimeUtterance {
                    id: "utt-atomic-lane-delta".into(),
                    session_id: "session-atomic-lane-delta".into(),
                    sequence: 0,
                    session_speaker_id: None,
                    source_language: "en".into(),
                    source_text: "temporary".into(),
                    source_start_ms: Some(10),
                    source_end_ms: Some(90),
                    translated_language: None,
                    translated_text: None,
                    completion: UtteranceCompletion::Partial,
                    alignment: UtteranceAlignment::TranslationPending,
                },
                None,
            )
            .unwrap();
        store
            .upsert_translation_variant(
                &source.session_id,
                source.sequence,
                "zh",
                Some("临时"),
                UtteranceVariantState::Ready,
                Some(UtteranceCompletion::Partial),
            )
            .unwrap();

        let shell = store
            .remove_partial_utterance(
                &source.session_id,
                source.sequence,
                source.revision,
                Some(&RealtimeTranslationLaneUpdate {
                    language: "zh".into(),
                    text: Some("终稿".into()),
                    state: UtteranceVariantState::Ready,
                    completion: Some(UtteranceCompletion::Complete),
                }),
            )
            .unwrap()
            .expect("the newly Final translation must retain the shell");
        assert!(!shell.has_source_lane());
        let zh = shell
            .variants
            .iter()
            .find(|variant| variant.language == "zh")
            .unwrap();
        assert_eq!(zh.text.as_deref(), Some("终稿"));
        assert_eq!(zh.completion, Some(UtteranceCompletion::Complete));
        assert!(zh.projection_revision > 0);
        let projection = store
            .load_realtime_loro_projection(&source.session_id)
            .unwrap();
        assert_eq!(projection.desired_revision, zh.projection_revision);
    }

    #[test]
    fn durable_lane_mutation_stages_without_editing_then_commits_text_only() {
        let (_temp, store, notebook_id) = fixture();
        store.get_or_create_profile(&notebook_id).unwrap();
        create_run(&store, &new_run(&notebook_id, "saga")).unwrap();
        claim_realtime(&store, "session-saga");
        upsert_test_lanes(
            &store,
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
        ack_all_realtime_projection(&store, "session-saga");

        let staged = store
            .stage_utterance_lane_replacement("utt-saga", UtteranceLane::Translated, "您好", 0)
            .unwrap();
        assert_eq!(staged.session_id, "session-saga");
        assert_eq!(staged.lane, UtteranceLane::Translated);
        assert_eq!(staged.lane_language, "zh");
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
        assert_eq!(committed.translated_language.as_deref(), Some("zh"));
        assert_eq!(committed.source_language, "en");
        assert_eq!(committed.source_start_ms, Some(10));
        assert_eq!(committed.revision, 0);
        let machine = store
            .get_machine_utterance_by_id("utt-saga")
            .unwrap()
            .unwrap();
        assert_eq!(machine.translated_text.as_deref(), Some("你好"));
        assert_eq!(machine.revision, 0);
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
        ack_all_realtime_projection(&store, "session-saga-conflict");
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
        let committed = store.commit_projection_mutation(&staged.id).unwrap();
        assert_eq!(committed.source_text, "new");
        assert_eq!(committed.source_edit_revision, 1);
        assert!(store.get_projection_mutation(&staged.id).unwrap().is_none());
        let cancelled = store
            .stage_utterance_lane_replacement(
                "utt-saga-conflict",
                UtteranceLane::Source,
                "cancel me",
                committed.source_edit_revision,
            )
            .unwrap();
        assert!(store.cancel_projection_mutation(&cancelled.id).unwrap());
        assert!(!store.cancel_projection_mutation(&cancelled.id).unwrap());
        assert_eq!(
            store
                .get_machine_utterance_by_id("utt-saga-conflict")
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
        ack_all_realtime_projection(&store, "session-purge");
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
