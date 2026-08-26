//! Notebook FFI API for the single-owner Notebook capture architecture.

use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use vt_model::Token;
use vt_store::{
    AsyncProjectionState, BuiltinNotebookTab, EditOp, NotebookCaptureStore, NotebookRecord,
    NotebookSessionLinkRecord, NotebookSessionProjectionRecord, NotebookStore, NotebookTabRecord,
    SessionMetaError, SessionMetaStore, SessionQueryStore,
};

use crate::{CoreError, ZuTalkCore};

/// 新装好的 App 里落笔的第一个家。
///
/// 随核心启动幂等创建 —— 第一次录音不该以「先学会新建 Notebook」为前提。
pub const DEFAULT_NOTEBOOK_TITLE: &str = "默认";
pub(crate) const QUICK_CAPTURE_NOTEBOOK_INTERNAL_TITLE: &str = "__zutalk_internal_quick_capture__";

/// Version 1 was the implicit, unmarked projection that grouped tokens only on
/// provider pauses. Version 2 added provider metadata but could still aggregate
/// a long run of anonymous tokens into one paragraph. Version 3 bounds those
/// paragraphs to utterance-sized rows. The mark covers the complete owned
/// Session section so repair can distinguish a current projection from a
/// legacy candidate without relying on UI state.
const ASYNC_PROJECTION_SCHEMA_MARK: &str = "async_projection_schema_version";
const ASYNC_PROJECTION_SCHEMA_VERSION: u64 = 3;
const ASYNC_PROJECTION_PREVIOUS_SCHEMA_VERSION: u64 = 2;
const ASYNC_SEGMENT_GAP_MS: u64 = 2_000;
const ASYNC_SENTENCE_BOUNDARY_MIN_MS: u64 = 4_000;
/// Bounds aggregation across provider tokens. A single provider token retains
/// its exact source time range even when that atomic range exceeds 20 seconds.
const ASYNC_MAX_AGGREGATED_SEGMENT_DURATION_MS: u64 = 20_000;
const ASYNC_MAX_SEGMENT_CHARS: usize = 240;

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiNotebook {
    pub id: String,
    pub title: String,
    pub created_at: String,
    pub updated_at: String,
    pub deleted_at: Option<String>,
}

impl From<NotebookRecord> for FfiNotebook {
    fn from(record: NotebookRecord) -> Self {
        Self {
            id: record.id,
            title: record.title,
            created_at: record.created_at,
            updated_at: record.updated_at,
            deleted_at: record.deleted_at,
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiNotebookTab {
    pub id: String,
    pub notebook_id: String,
    pub builtin_kind: String,
    pub title: String,
    pub doc_id: String,
    pub position: i64,
    pub created_at: String,
    pub updated_at: String,
    pub deleted_at: Option<String>,
}

impl From<NotebookTabRecord> for FfiNotebookTab {
    fn from(record: NotebookTabRecord) -> Self {
        Self {
            id: record.id,
            notebook_id: record.notebook_id,
            builtin_kind: record.builtin_kind.as_str().to_string(),
            title: record.title,
            doc_id: record.doc_id,
            position: record.position,
            created_at: record.created_at,
            updated_at: record.updated_at,
            deleted_at: record.deleted_at,
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiNotebookSessionProjection {
    pub id: String,
    pub notebook_id: String,
    pub tab_id: String,
    pub session_id: String,
    pub section_title: Option<String>,
    pub created_at: String,
    pub updated_at: String,
    pub deleted_at: Option<String>,
}

impl From<NotebookSessionProjectionRecord> for FfiNotebookSessionProjection {
    fn from(record: NotebookSessionProjectionRecord) -> Self {
        Self {
            id: record.id,
            notebook_id: record.notebook_id,
            tab_id: record.tab_id,
            session_id: record.session_id,
            section_title: record.section_title,
            created_at: record.created_at,
            updated_at: record.updated_at,
            deleted_at: record.deleted_at,
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiNotebookSessionLink {
    pub notebook_id: String,
    pub session_id: String,
    pub created_at: String,
}

/// Result of filing a previously unassigned Session into a research Topic.
///
/// Ownership is the primary transaction. Transcript materialization happens
/// after that commit because the Loro document is a separate durable store.
/// A deferred projection therefore never means the filing itself failed.
#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiSessionFilingResult {
    pub transcript_projection_deferred: bool,
}

impl From<NotebookSessionLinkRecord> for FfiNotebookSessionLink {
    fn from(record: NotebookSessionLinkRecord) -> Self {
        Self {
            notebook_id: record.notebook_id,
            session_id: record.session_id,
            created_at: record.created_at,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, uniffi::Record)]
pub struct FfiNotebookTranscriptSegment {
    pub segment_id: String,
    pub timestamp_ms: u64,
    pub text: String,
}

/// Internal projection shape for processed/provider transcripts.
///
/// This deliberately does not cross UniFFI: Swift observes these values from
/// marked Loro Delta. Keeping the provider speaker under an explicitly
/// anonymous name prevents it from being mistaken for a realtime
/// `SessionSpeaker` identity.
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct NotebookTranscriptSegment {
    segment_id: String,
    start_ms: Option<u64>,
    end_ms: Option<u64>,
    text: String,
    source_language: Option<String>,
    provider_speaker_label: Option<String>,
    translation_status: vt_model::TranslationStatus,
}

#[derive(Clone)]
pub(crate) struct NotebookTranscriptProjector {
    data_dir: PathBuf,
    db_path: PathBuf,
    notebook_store: NotebookStore,
    editor_bridge: vt_store::EditorBridge,
    editor_callbacks: Arc<Mutex<HashMap<String, Arc<dyn crate::editor_api::FfiEditorCallback>>>>,
}

impl NotebookTranscriptProjector {
    pub(crate) fn new(
        data_dir: PathBuf,
        db_path: PathBuf,
        notebook_store: NotebookStore,
        editor_bridge: vt_store::EditorBridge,
        editor_callbacks: Arc<
            Mutex<HashMap<String, Arc<dyn crate::editor_api::FfiEditorCallback>>>,
        >,
    ) -> Self {
        Self {
            data_dir,
            db_path,
            notebook_store,
            editor_bridge,
            editor_callbacks,
        }
    }

    pub(crate) fn sync_linked_session_transcript_from_store(
        &self,
        session_id: &str,
        builtin_kind: BuiltinNotebookTab,
    ) -> Result<Option<String>, CoreError> {
        self.project_linked_session_transcript_from_store(session_id, builtin_kind, true)
    }

    /// Materializes persisted tokens when the Session section is absent, or
    /// migrates a canonical prior-schema/legacy Delta. Missing derived legacy
    /// segment marks are repairable; any text, formatting, annotation, or
    /// non-derived mark difference is treated as a durable user edit.
    pub(crate) fn ensure_linked_session_transcript_from_store(
        &self,
        session_id: &str,
        builtin_kind: BuiltinNotebookTab,
    ) -> Result<Option<String>, CoreError> {
        self.project_linked_session_transcript_from_store(session_id, builtin_kind, false)
    }

    fn project_linked_session_transcript_from_store(
        &self,
        session_id: &str,
        builtin_kind: BuiltinNotebookTab,
        replace_existing: bool,
    ) -> Result<Option<String>, CoreError> {
        validate_async_projection_tab(&builtin_kind)?;
        let notebook_id = match self
            .notebook_store
            .get_linked_notebook_id(session_id)
            .map_err(|e| CoreError::InternalError {
                message: e.to_string(),
            })? {
            Some(notebook_id) => notebook_id,
            None => return Ok(None),
        };

        let session_meta =
            SessionMetaStore::new(&self.db_path).map_err(|e| CoreError::InternalError {
                message: format!("open session meta: {e}"),
            })?;
        let tokens = match session_meta.get_tokens(session_id) {
            Ok(tokens) => tokens,
            // Legacy and audio-only Sessions may never have created a
            // session_meta row. That is an honest empty transcript, while DB
            // and JSON failures must remain recoverable errors.
            Err(SessionMetaError::NotFound(_)) => Vec::new(),
            Err(error) => {
                return Err(CoreError::InternalError {
                    message: format!("load persisted transcript tokens: {error}"),
                });
            }
        };
        if tokens.is_empty() {
            return Ok(None);
        }

        let session_store =
            SessionQueryStore::new(&self.db_path).map_err(|e| CoreError::InternalError {
                message: format!("open session store: {e}"),
            })?;
        let section_title = load_session_section_title(&session_store, session_id)
            .unwrap_or_else(|| session_id.to_string());
        let segments = build_notebook_segments_from_tokens(&tokens);
        let previous_schema_segments = build_schema_v2_segments_from_tokens(&tokens);
        let legacy_segments = build_unversioned_legacy_segments_from_tokens(&tokens);
        let doc_id = sync_session_transcript_into_tab(
            &self.data_dir,
            &self.editor_bridge,
            &self.editor_callbacks,
            &self.notebook_store,
            &notebook_id,
            builtin_kind,
            session_id,
            Some(section_title.as_str()),
            &segments,
            &previous_schema_segments,
            &legacy_segments,
            replace_existing,
        )?;
        Ok(Some(doc_id))
    }

    /// Materializes an already-persisted provider result into the Async
    /// Transcript document. This method never reads credentials, audio, or the
    /// task queue, so retrying it cannot dispatch a second provider request.
    pub(crate) fn project_persisted_async_transcript(
        &self,
        capture_store: &NotebookCaptureStore,
        session_id: &str,
    ) -> Result<Option<String>, CoreError> {
        let run = capture_store
            .get_run_for_session(session_id)
            .map_err(|error| CoreError::InternalError {
                message: format!("load async projection run: {error}"),
            })?
            .ok_or_else(|| CoreError::NotFound {
                message: format!("capture session {session_id}"),
            })?;
        let receipt_validation = (|| {
            let task_id = run.async_task_id.as_deref().ok_or_else(|| {
                CoreError::InternalError {
                    message: format!(
                        "capture session {session_id} has no stable async task for transcript projection"
                    ),
                }
            })?;
            capture_store
                .get_async_provider_receipt(session_id, task_id)
                .map_err(|error| CoreError::InternalError {
                    message: format!(
                        "validate provider receipt before async transcript projection: {error}"
                    ),
                })?
                .ok_or_else(|| CoreError::InternalError {
                    message: format!(
                        "capture session {session_id} has no provider receipt for async transcript projection"
                    ),
                })?;
            Ok::<(), CoreError>(())
        })();
        if let Err(error) = receipt_validation {
            if run.async_projection_state == AsyncProjectionState::Pending
                && capture_store
                    .set_async_projection_state(
                        &run.id,
                        AsyncProjectionState::Pending,
                        AsyncProjectionState::Projecting,
                    )
                    .is_ok()
            {
                let _ = capture_store.set_async_projection_state(
                    &run.id,
                    AsyncProjectionState::Projecting,
                    AsyncProjectionState::Failed,
                );
            }
            return Err(error);
        }
        capture_store
            .set_async_projection_state(
                &run.id,
                AsyncProjectionState::Pending,
                AsyncProjectionState::Projecting,
            )
            .map_err(|error| CoreError::InternalError {
                message: format!("begin async transcript projection: {error}"),
            })?;

        let projection = self
            .sync_linked_session_transcript_from_store(
                session_id,
                BuiltinNotebookTab::AsyncTranscript,
            )
            .and_then(|doc_id| {
                doc_id.ok_or_else(|| CoreError::InternalError {
                    message: format!(
                        "persisted async transcript for session {session_id} has no projection source or Notebook link"
                    ),
                })
            });

        match projection {
            Ok(doc_id) => {
                if let Err(error) = capture_store.complete_async_projection_unless_purging(&run.id)
                {
                    let original = CoreError::InternalError {
                        message: format!("commit async transcript projection: {error}"),
                    };
                    let _ = capture_store.set_async_projection_state(
                        &run.id,
                        AsyncProjectionState::Projecting,
                        AsyncProjectionState::Failed,
                    );
                    return Err(original);
                }
                Ok(Some(doc_id))
            }
            Err(error) => {
                if let Err(state_error) = capture_store.set_async_projection_state(
                    &run.id,
                    AsyncProjectionState::Projecting,
                    AsyncProjectionState::Failed,
                ) {
                    return Err(CoreError::InternalError {
                        message: format!(
                            "async transcript projection failed ({error}); marking retryable failure also failed ({state_error})"
                        ),
                    });
                }
                Err(error)
            }
        }
    }
}

struct RenderedMark {
    pos: usize,
    len: usize,
    key: String,
    value_json: String,
}

struct RenderedSection {
    text: String,
    marks: Vec<RenderedMark>,
}

#[uniffi::export]
impl ZuTalkCore {
    pub fn create_notebook(&self, title: Option<String>) -> Result<FfiNotebook, CoreError> {
        let normalized_title = title.as_deref().map(str::trim);
        if normalized_title == Some(QUICK_CAPTURE_NOTEBOOK_INTERNAL_TITLE)
            || normalized_title == Some(crate::share_api::SHARED_INBOX_NOTEBOOK_INTERNAL_TITLE)
        {
            return Err(CoreError::ValidationFailed {
                message: "reserved internal Topic title".to_string(),
            });
        }
        let notebook = self
            .notebook_store
            .create_notebook(title.as_deref())
            .map_err(|e| CoreError::InternalError {
                message: e.to_string(),
            })?;
        Ok(notebook.into())
    }

    pub fn list_notebooks(&self) -> Result<Vec<FfiNotebook>, CoreError> {
        let notebooks =
            self.notebook_store
                .list_notebooks()
                .map_err(|e| CoreError::InternalError {
                    message: e.to_string(),
                })?;
        Ok(notebooks
            .into_iter()
            .filter(|record| {
                record.title != QUICK_CAPTURE_NOTEBOOK_INTERNAL_TITLE
                    && record.title != crate::share_api::SHARED_INBOX_NOTEBOOK_INTERNAL_TITLE
            })
            .map(Into::into)
            .collect())
    }

    /// Returns the durable technical owner used by Home's one-click capture.
    /// Product UI presents Sessions in this Notebook as unfiled; the hidden
    /// owner keeps capture profiles, encrypted audio, and crash recovery on the
    /// same proven Notebook pipeline until the user files a Session elsewhere.
    pub fn get_quick_capture_notebook(&self) -> Result<FfiNotebook, CoreError> {
        self.notebook_store
            .list_notebooks()
            .map_err(|error| CoreError::InternalError {
                message: error.to_string(),
            })?
            .into_iter()
            .find(|notebook| notebook.title == QUICK_CAPTURE_NOTEBOOK_INTERNAL_TITLE)
            .map(|record| {
                let mut notebook: FfiNotebook = record.into();
                notebook.title = DEFAULT_NOTEBOOK_TITLE.to_string();
                notebook
            })
            .ok_or_else(|| CoreError::NotFound {
                message: "quick capture notebook is unavailable".to_string(),
            })
    }

    pub fn list_notebook_tabs(
        &self,
        notebook_id: String,
    ) -> Result<Vec<FfiNotebookTab>, CoreError> {
        let tabs =
            self.notebook_store
                .list_tabs(&notebook_id)
                .map_err(|e| CoreError::InternalError {
                    message: e.to_string(),
                })?;
        Ok(tabs.into_iter().map(Into::into).collect())
    }

    /// 这个 Notebook 里有哪些录音。
    ///
    /// 垃圾箱里的不算 —— Home 的列表(`query_sessions`,默认 ActiveOnly)
    /// 与 Notebook 的「几段录音」读的是同一件事实,两边给出不同的数,
    /// 用户只能猜哪个是真的。关联行本身留着不动:恢复之后要原样回来。
    pub fn list_notebook_sessions(
        &self,
        notebook_id: String,
    ) -> Result<Vec<FfiNotebookSessionLink>, CoreError> {
        let sessions = self
            .notebook_store
            .list_linked_sessions(&notebook_id)
            .map_err(|e| CoreError::InternalError {
                message: e.to_string(),
            })?;
        let ids: Vec<String> = sessions.iter().map(|s| s.session_id.clone()).collect();
        let trashed =
            self.session_store
                .trashed_among(&ids)
                .map_err(|e| CoreError::InternalError {
                    message: e.to_string(),
                })?;
        Ok(sessions
            .into_iter()
            .filter(|s| !trashed.contains(&s.session_id))
            .map(Into::into)
            .collect())
    }

    /// Moves a recording, and everything it owns, into another Notebook.
    ///
    /// The session's realtime transcript, async transcript, manual note, and
    /// the annotations written alongside them all travel together; its audio
    /// needs no move because no Notebook owns it. The sections land in the
    /// target ordered by when the recording happened, not by when it was moved.
    ///
    /// Refused while the session is being captured or permanently deleted.
    pub fn move_session_to_notebook(
        &self,
        session_id: String,
        target_notebook_id: String,
    ) -> Result<(), CoreError> {
        self.move_session_to_notebook_inner(&session_id, &target_notebook_id)
    }

    /// Files one legacy/unassigned Session into a Topic without pretending it
    /// is a move. The store creates the ownership link and all three builtin
    /// projections in one transaction and refuses an existing owner.
    ///
    /// Active and trashed Sessions are deliberately excluded: capture routing
    /// owns the former, while restore/purge owns the latter.
    pub fn assign_orphan_session_to_notebook(
        &self,
        session_id: String,
        notebook_id: String,
    ) -> Result<FfiSessionFilingResult, CoreError> {
        // Lock order intentionally matches permanent purge:
        // capture_ownership_gate -> editor_document_mutation_guard.
        let _ownership_guard = self.capture_ownership_gate.lock().unwrap();
        self.ensure_capture_projection_not_purging(&session_id)?;
        let session = self
            .session_store
            .get_session(&session_id)
            .map_err(|error| match error {
                vt_store::SessionQueryError::NotFound(_) => CoreError::NotFound {
                    message: format!("session not found: {session_id}"),
                },
                other => CoreError::InternalError {
                    message: other.to_string(),
                },
            })?;
        if session.deleted_at.is_some() {
            return Err(CoreError::ValidationFailed {
                message: format!("trashed session cannot be filed: {session_id}"),
            });
        }
        if session.status.eq_ignore_ascii_case("recording") {
            return Err(CoreError::ValidationFailed {
                message: format!("active recording cannot be filed: {session_id}"),
            });
        }

        // A capture run already records its authoritative Topic even if a
        // damaged/legacy membership link is absent. Never let recovery assign
        // that run to a different Topic.
        if let Some(run) = self
            .notebook_capture_store
            .get_run_for_session(&session_id)
            .map_err(|error| CoreError::InternalError {
                message: format!("load capture ownership before filing: {error}"),
            })?
        {
            if run.notebook_id != notebook_id {
                return Err(CoreError::ValidationFailed {
                    message: format!(
                        "session {session_id} is owned by notebook {}",
                        run.notebook_id
                    ),
                });
            }
        }

        self.notebook_store
            .attach_session_with_builtin_projections(&notebook_id, &session_id)
            .map_err(|error| match error {
                vt_store::NotebookStoreError::NotFound(_) => CoreError::NotFound {
                    message: error.to_string(),
                },
                vt_store::NotebookStoreError::SessionAlreadyLinked { .. }
                | vt_store::NotebookStoreError::SessionNotMovable { .. }
                | vt_store::NotebookStoreError::Validation(_) => CoreError::ValidationFailed {
                    message: error.to_string(),
                },
                vt_store::NotebookStoreError::Sqlite(_) => CoreError::InternalError {
                    message: error.to_string(),
                },
            })?;

        // Legacy imports may already own persisted async tokens. Materialize
        // them into the newly reachable Topic document now; an empty token set
        // is a valid audio-only Session and needs no synthetic content.
        let transcript_projection_deferred = match self
            .notebook_transcript_projector()
            .ensure_linked_session_transcript_from_store(
                &session_id,
                BuiltinNotebookTab::AsyncTranscript,
            ) {
            Ok(_) => false,
            Err(error) => {
                // The ownership transaction is already durable. Returning an
                // overall error here would make Swift retain a stale
                // "unfiled" projection even though Core has filed the Session.
                // Resources retries this idempotently without replacing an
                // existing transcript section.
                tracing::warn!(
                    session_id,
                    notebook_id,
                    %error,
                    "Session filed; async transcript projection deferred"
                );
                true
            }
        };
        Ok(FfiSessionFilingResult {
            transcript_projection_deferred,
        })
    }

    /// Repairs the split-store async transcript projection after a Session has
    /// already been filed. Returns false when the Session has no persisted
    /// async transcript tokens, which is a valid audio-only state.
    ///
    /// Existing current, edited, unknown, or malformed sections are untouched.
    /// Only canonical older output (including legacy output missing derived
    /// technical marks) is eligible for migration, making this safe to run on
    /// every Resources refresh.
    pub fn repair_session_transcript_projection(
        &self,
        session_id: String,
    ) -> Result<bool, CoreError> {
        let _ownership_guard = self.capture_ownership_gate.lock().unwrap();
        self.ensure_capture_projection_not_purging(&session_id)?;
        let session = self
            .session_store
            .get_session(&session_id)
            .map_err(|error| match error {
                vt_store::SessionQueryError::NotFound(_) => CoreError::NotFound {
                    message: format!("session not found: {session_id}"),
                },
                other => CoreError::InternalError {
                    message: other.to_string(),
                },
            })?;
        if session.deleted_at.is_some() {
            return Err(CoreError::ValidationFailed {
                message: format!("trashed session cannot repair transcript: {session_id}"),
            });
        }
        Ok(self
            .notebook_transcript_projector()
            .ensure_linked_session_transcript_from_store(
                &session_id,
                BuiltinNotebookTab::AsyncTranscript,
            )?
            .is_some())
    }

    pub fn import_audio_into_notebook(
        &self,
        path: String,
        notebook_id: String,
    ) -> Result<crate::session_audio_api::ImportResultInfo, CoreError> {
        // Authorize one immutable profile snapshot before creating any session
        // state. A concurrent settings change makes the run insert fail its
        // revision CAS and the whole import is permanently rolled back.
        let profile = self
            .notebook_capture_store
            .get_or_create_profile(&notebook_id)
            .map_err(|e| CoreError::InternalError {
                message: format!("load Notebook import profile: {e}"),
            });
        let profile = profile?;

        let import = self.import_audio(path)?;
        let session_id = import.result.session_id.clone();
        if let Err(error) = self
            .session_meta
            .set_privacy_level(&session_id, &profile.privacy_level)
            .map_err(|error| CoreError::InternalError {
                message: format!("apply Notebook import privacy snapshot: {error}"),
            })
        {
            return Err(self.rollback_notebook_import(&session_id, error));
        }
        if let Err(error) = self
            .notebook_capture_store
            .create_completed_import_run(
                &vt_store::notebook_capture_store::NewCompletedNotebookImportRun {
                    id: uuid::Uuid::new_v4().to_string(),
                    notebook_id: notebook_id.clone(),
                    session_id: session_id.clone(),
                    audio_path: import.audio_path,
                    audio_key_ref: import.audio_key_ref,
                    sample_rate: import.result.sample_rate,
                    channels: import.result.channels,
                    captured_frames: import.captured_frames,
                },
                &profile,
            )
            .map_err(|error| CoreError::InternalError {
                message: format!("create completed Notebook import run: {error}"),
            })
        {
            return Err(self.rollback_notebook_import(&session_id, error));
        }
        if let Err(error) = self.attach_session_to_notebook(notebook_id, session_id.clone()) {
            return Err(self.rollback_notebook_import(&session_id, error));
        }
        Ok(import.result)
    }

    /// 这个 tab 上有哪些段落。
    ///
    /// 与 `list_notebook_sessions` 同一条纪律:录音进了垃圾箱,它的段落
    /// 就不该还挂在 tab 上 —— 采集历史(`list_notebook_capture_history`)
    /// 早就按 `s.deleted_at IS NULL` 过滤,同一个界面的几条数据路要给
    /// 同一个答案。投影行本身不动,恢复之后段落原样回来。
    pub fn list_notebook_session_projections(
        &self,
        tab_id: String,
    ) -> Result<Vec<FfiNotebookSessionProjection>, CoreError> {
        let projections = self
            .notebook_store
            .list_session_projections(&tab_id)
            .map_err(|e| CoreError::InternalError {
                message: e.to_string(),
            })?;
        let ids: Vec<String> = projections.iter().map(|p| p.session_id.clone()).collect();
        let trashed =
            self.session_store
                .trashed_among(&ids)
                .map_err(|e| CoreError::InternalError {
                    message: e.to_string(),
                })?;
        Ok(projections
            .into_iter()
            .filter(|p| !trashed.contains(&p.session_id))
            .map(Into::into)
            .collect())
    }

    /// Names the complete personal note associated with one recording time.
    /// This only updates projection metadata; it never mutates note text,
    /// session ownership, or the session timestamp.
    pub fn rename_notebook_manual_note(
        &self,
        notebook_id: String,
        session_id: String,
        title: Option<String>,
    ) -> Result<FfiNotebookSessionProjection, CoreError> {
        let projection = self
            .notebook_store
            .ensure_session_projection(
                &notebook_id,
                BuiltinNotebookTab::ManualNote,
                &session_id,
                title.as_deref(),
            )
            .map_err(|e| CoreError::InternalError {
                message: e.to_string(),
            })?;
        Ok(projection.into())
    }
}

impl ZuTalkCore {
    pub(crate) fn attach_session_to_notebook(
        &self,
        notebook_id: String,
        session_id: String,
    ) -> Result<(), CoreError> {
        self.session_store
            .get_session(&session_id)
            .map_err(|_| CoreError::NotFound {
                message: format!("session not found: {session_id}"),
            })?;
        // Every recording gets one stable resource entry in all three views.
        // The store commits the ownership link and projections together so a
        // failure cannot leave a partial Notebook attachment behind.
        self.notebook_store
            .attach_session_with_builtin_projections(&notebook_id, &session_id)
            .map_err(|e| CoreError::InternalError {
                message: e.to_string(),
            })
    }

    fn rollback_notebook_import(&self, session_id: &str, error: CoreError) -> CoreError {
        match self.purge_session_forever(session_id) {
            Ok(()) => error,
            Err(rollback_error) => CoreError::InternalError {
                message: format!(
                    "Notebook import failed ({error}); permanent rollback failed ({rollback_error})"
                ),
            },
        }
    }
}

impl ZuTalkCore {
    pub(crate) fn notebook_transcript_projector(&self) -> NotebookTranscriptProjector {
        NotebookTranscriptProjector::new(
            self.data_dir.clone(),
            self.data_dir.join("zutalk.db"),
            self.notebook_store.clone(),
            self.editor_bridge.clone(),
            self.editor_callbacks.clone(),
        )
    }
}

fn validate_async_projection_tab(builtin_kind: &BuiltinNotebookTab) -> Result<(), CoreError> {
    if builtin_kind == &BuiltinNotebookTab::AsyncTranscript {
        Ok(())
    } else {
        Err(CoreError::ValidationFailed {
            message: format!(
                "processed transcript projection requires async_transcript, got {}",
                builtin_kind.as_str()
            ),
        })
    }
}

#[allow(clippy::too_many_arguments)]
pub(crate) fn sync_session_transcript_into_tab(
    data_dir: &std::path::Path,
    editor_bridge: &vt_store::EditorBridge,
    editor_callbacks: &Arc<Mutex<HashMap<String, Arc<dyn crate::editor_api::FfiEditorCallback>>>>,
    notebook_store: &NotebookStore,
    notebook_id: &str,
    builtin_kind: BuiltinNotebookTab,
    session_id: &str,
    section_title: Option<&str>,
    segments: &[NotebookTranscriptSegment],
    previous_schema_segments: &[NotebookTranscriptSegment],
    legacy_segments: &[FfiNotebookTranscriptSegment],
    replace_existing: bool,
) -> Result<String, CoreError> {
    validate_async_projection_tab(&builtin_kind)?;
    let _mutation_guard = crate::editor_api::editor_document_mutation_guard();
    let projection = if replace_existing {
        notebook_store.ensure_session_projection(
            notebook_id,
            builtin_kind.clone(),
            session_id,
            section_title,
        )
    } else {
        notebook_store.require_session_projection(notebook_id, builtin_kind.clone(), session_id)
    }
    .map_err(|e| CoreError::InternalError {
        message: e.to_string(),
    })?;
    let tab = notebook_store
        .list_tabs(notebook_id)
        .map_err(|e| CoreError::InternalError {
            message: e.to_string(),
        })?
        .into_iter()
        .find(|tab| tab.builtin_kind == builtin_kind)
        .ok_or_else(|| CoreError::NotFound {
            message: format!(
                "builtin tab {} not found for notebook {notebook_id}",
                builtin_kind.as_str()
            ),
        })?;

    crate::editor_api::open_editor_session(data_dir, editor_bridge, &tab.doc_id)?;
    let delta = editor_bridge
        .get_delta(&tab.doc_id)
        .map_err(|error| CoreError::InternalError {
            message: format!("get notebook transcript Delta: {error}"),
        })?;
    if let Some(existing_range) = crate::editor_api::find_unique_marked_range(
        &delta,
        crate::editor_api::DeltaMarkSelector {
            session_id: Some(session_id),
            utterance_id: None,
            lane_language: None,
        },
    )? {
        match projection_schema_state(&delta, existing_range)? {
            ProjectionSchemaState::Version(ASYNC_PROJECTION_SCHEMA_VERSION) => {
                return Ok(tab.doc_id);
            }
            ProjectionSchemaState::Version(ASYNC_PROJECTION_PREVIOUS_SCHEMA_VERSION) => {
                let content = editor_bridge.get_content(&tab.doc_id).map_err(|error| {
                    CoreError::InternalError {
                        message: format!(
                            "get previous-schema notebook transcript content: {error}"
                        ),
                    }
                })?;
                let canonical_previous = render_transcript_section_for_schema(
                    &projection.session_id,
                    projection.section_title.as_deref(),
                    previous_schema_segments,
                    existing_range.pos > 0,
                    ASYNC_PROJECTION_PREVIOUS_SCHEMA_VERSION,
                );
                if !delta_range_matches_rendered_section(
                    &delta,
                    existing_range,
                    &content,
                    &canonical_previous,
                )? {
                    // Version 2 is understood, so a mismatch is a durable user
                    // edit rather than an unknown provider result. Preserve it
                    // both during repair and provider-receipt retries.
                    return Ok(tab.doc_id);
                }
            }
            ProjectionSchemaState::Unversioned => {
                if !replace_existing {
                    let content = editor_bridge.get_content(&tab.doc_id).map_err(|error| {
                        CoreError::InternalError {
                            message: format!("get legacy notebook transcript content: {error}"),
                        }
                    })?;
                    let canonical_legacy = render_unversioned_legacy_transcript_section(
                        &projection.session_id,
                        projection.section_title.as_deref(),
                        legacy_segments,
                        existing_range.pos > 0,
                    );
                    if !delta_range_matches_rendered_section(
                        &delta,
                        existing_range,
                        &content,
                        &canonical_legacy,
                    )? && !delta_range_matches_legacy_with_missing_technical_marks(
                        &delta,
                        existing_range,
                        &content,
                        &canonical_legacy,
                    )? {
                        // Text, formatting and annotations are all durable
                        // edits. Repair accepts the exact legacy Delta shape,
                        // plus legacy documents that lost only old segment ID
                        // or timestamp marks during earlier Loro round-trips.
                        return Ok(tab.doc_id);
                    }
                }
            }
            // A future version, partial mark, or malformed value is not a safe
            // migration target for this binary.
            ProjectionSchemaState::Version(_) | ProjectionSchemaState::Malformed => {
                if replace_existing {
                    return Err(CoreError::ValidationFailed {
                        message: format!(
                            "refusing to replace unknown async projection schema for session {session_id}"
                        ),
                    });
                }
                return Ok(tab.doc_id);
            }
        }
    }
    let rollback_snapshot = editor_bridge
        .export_snapshot(&tab.doc_id)
        .map_err(|error| CoreError::InternalError {
            message: format!("snapshot notebook transcript before projection: {error}"),
        })?;
    let mutation_result = (|| -> Result<(), CoreError> {
        let delta =
            editor_bridge
                .get_delta(&tab.doc_id)
                .map_err(|error| CoreError::InternalError {
                    message: format!("get notebook transcript Delta: {error}"),
                })?;
        let existing_range = crate::editor_api::find_unique_marked_range(
            &delta,
            crate::editor_api::DeltaMarkSelector {
                session_id: Some(session_id),
                utterance_id: None,
                lane_language: None,
            },
        )?;
        let current_len = editor_bridge
            .get_content(&tab.doc_id)
            .map_err(|e| CoreError::InternalError {
                message: format!("get notebook transcript content: {e}"),
            })?
            .chars()
            .count();
        let insert_pos = if let Some(range) = existing_range {
            editor_bridge
                .apply(
                    &tab.doc_id,
                    EditOp::Delete {
                        pos: range.pos,
                        len: range.len,
                    },
                )
                .map_err(|e| CoreError::InternalError {
                    message: format!("delete old session section: {e}"),
                })?;
            range.pos
        } else {
            current_len
        };

        let rendered = render_transcript_section(
            &projection.session_id,
            projection.section_title.as_deref(),
            segments,
            insert_pos > 0,
        );
        editor_bridge
            .apply(
                &tab.doc_id,
                EditOp::Insert {
                    pos: insert_pos,
                    text: rendered.text,
                },
            )
            .map_err(|e| CoreError::InternalError {
                message: format!("insert notebook transcript section: {e}"),
            })?;
        for mark in rendered.marks {
            editor_bridge
                .apply(
                    &tab.doc_id,
                    EditOp::Mark {
                        pos: insert_pos + mark.pos,
                        len: mark.len,
                        key: mark.key,
                        value_json: mark.value_json,
                    },
                )
                .map_err(|e| CoreError::InternalError {
                    message: format!("mark notebook transcript section: {e}"),
                })?;
        }
        crate::editor_api::flush_snapshot_to_disk_result(data_dir, editor_bridge, &tab.doc_id)
            .map_err(|message| CoreError::InternalError { message })?;
        Ok(())
    })();
    if let Err(error) = mutation_result {
        let rollback = editor_bridge
            .replace_document_with_styles(
                &tab.doc_id,
                &rollback_snapshot,
                crate::editor_api::voice_tool_style_config(),
            )
            .map_err(|rollback_error| rollback_error.to_string())
            .and_then(|_| {
                crate::editor_api::flush_snapshot_to_disk_result(
                    data_dir,
                    editor_bridge,
                    &tab.doc_id,
                )
            });
        if let Err(rollback_error) = rollback {
            return Err(CoreError::InternalError {
                message: format!(
                    "transcript projection failed ({error}); durable rollback failed ({rollback_error})"
                ),
            });
        }
        return Err(error);
    }

    crate::editor_api::notify_editor_callback(editor_callbacks, &tab.doc_id);
    Ok(tab.doc_id)
}

fn load_session_section_title(
    session_store: &SessionQueryStore,
    session_id: &str,
) -> Option<String> {
    session_store
        .get_session(session_id)
        .ok()
        .and_then(|session| {
            let title = session.title.trim().to_string();
            if title.is_empty() {
                None
            } else {
                Some(title)
            }
        })
}

pub(crate) fn build_notebook_segments_from_tokens(
    tokens: &[Token],
) -> Vec<NotebookTranscriptSegment> {
    let mut segments: Vec<NotebookTranscriptSegment> = Vec::new();
    let mut last_end_ms: Option<u64> = None;
    let mut last_token_ended_sentence = false;

    for token in tokens {
        for (piece_index, piece_text) in split_provider_token_text(&token.text)
            .into_iter()
            .enumerate()
        {
            let source_language = non_empty_metadata(&token.language);
            let provider_speaker_label = token.speaker.as_deref().and_then(non_empty_metadata);
            let needs_new_segment = piece_index > 0
                || match segments.last() {
                    None => true,
                    Some(last) => {
                        let segment_elapsed_ms = last
                            .start_ms
                            .zip(last_end_ms)
                            .map_or(0, |(start, end)| end.saturating_sub(start));
                        let projected_duration_ms = last
                            .start_ms
                            .map_or(0, |start| token.end_ms.saturating_sub(start));
                        let projected_chars = last
                            .text
                            .chars()
                            .count()
                            .saturating_add(piece_text.chars().count());
                        last_end_ms.is_some_and(|end_ms| {
                            token.start_ms.saturating_sub(end_ms) > ASYNC_SEGMENT_GAP_MS
                        }) || last.source_language != source_language
                            || last.provider_speaker_label != provider_speaker_label
                            || last.translation_status != token.translation_status
                            || (last_token_ended_sentence
                                && segment_elapsed_ms >= ASYNC_SENTENCE_BOUNDARY_MIN_MS)
                            || projected_duration_ms > ASYNC_MAX_AGGREGATED_SEGMENT_DURATION_MS
                            || projected_chars > ASYNC_MAX_SEGMENT_CHARS
                    }
                };
            let piece_ended_sentence = ends_strong_sentence(&piece_text);

            if needs_new_segment {
                segments.push(NotebookTranscriptSegment {
                    // Multiple provider lanes and split atomic tokens can
                    // legitimately share start_ms. The deterministic ordinal
                    // keeps segment ownership unique without inventing timing.
                    segment_id: format!("{:016x}-{:04x}", token.start_ms, segments.len()),
                    start_ms: Some(token.start_ms),
                    end_ms: Some(token.end_ms),
                    text: piece_text,
                    source_language,
                    provider_speaker_label,
                    translation_status: token.translation_status,
                });
            } else if let Some(last) = segments.last_mut() {
                last.text.push_str(&piece_text);
                last.end_ms = Some(last.end_ms.unwrap_or(token.end_ms).max(token.end_ms));
            }
            last_end_ms = Some(token.end_ms);
            last_token_ended_sentence = piece_ended_sentence;
        }
    }

    segments
}

/// Reconstructs the exact version-2 projector output so an installed document
/// can be migrated only when it is still byte-for-byte and mark-for-mark
/// canonical. Version 2 split on provider discontinuities and metadata changes
/// but had no sentence, duration, or character bound.
fn build_schema_v2_segments_from_tokens(tokens: &[Token]) -> Vec<NotebookTranscriptSegment> {
    let mut segments: Vec<NotebookTranscriptSegment> = Vec::new();
    let mut last_end_ms: Option<u64> = None;

    for token in tokens {
        let source_language = non_empty_metadata(&token.language);
        let provider_speaker_label = token.speaker.as_deref().and_then(non_empty_metadata);
        let needs_new_segment = match segments.last() {
            None => true,
            Some(last) => {
                last_end_ms.is_some_and(|end_ms| {
                    token.start_ms.saturating_sub(end_ms) > ASYNC_SEGMENT_GAP_MS
                }) || last.source_language != source_language
                    || last.provider_speaker_label != provider_speaker_label
                    || last.translation_status != token.translation_status
            }
        };

        if needs_new_segment {
            segments.push(NotebookTranscriptSegment {
                segment_id: format!("{:016x}", token.start_ms),
                start_ms: Some(token.start_ms),
                end_ms: Some(token.end_ms),
                text: token.text.clone(),
                source_language,
                provider_speaker_label,
                translation_status: token.translation_status,
            });
        } else if let Some(last) = segments.last_mut() {
            last.text.push_str(&token.text);
            last.end_ms = Some(last.end_ms.unwrap_or(token.end_ms).max(token.end_ms));
        }
        last_end_ms = Some(token.end_ms);
    }

    segments
}

fn split_provider_token_text(text: &str) -> Vec<String> {
    if text.chars().count() <= ASYNC_MAX_SEGMENT_CHARS {
        return vec![text.to_string()];
    }
    let mut pieces = Vec::new();
    let mut piece = String::new();
    let mut piece_chars = 0_usize;
    for character in text.chars() {
        if piece_chars == ASYNC_MAX_SEGMENT_CHARS {
            pieces.push(std::mem::take(&mut piece));
            piece_chars = 0;
        }
        piece.push(character);
        piece_chars += 1;
    }
    if !piece.is_empty() {
        pieces.push(piece);
    }
    pieces
}

fn build_unversioned_legacy_segments_from_tokens(
    tokens: &[Token],
) -> Vec<FfiNotebookTranscriptSegment> {
    const GAP_MS: u64 = 2_000;
    let mut segments: Vec<FfiNotebookTranscriptSegment> = Vec::new();
    let mut last_end_ms = 0_u64;

    for token in tokens {
        if segments.is_empty() || token.start_ms.saturating_sub(last_end_ms) > GAP_MS {
            segments.push(FfiNotebookTranscriptSegment {
                segment_id: format!("{:016x}", token.start_ms),
                timestamp_ms: token.start_ms,
                text: token.text.clone(),
            });
        } else if let Some(last) = segments.last_mut() {
            last.text.push_str(&token.text);
        }
        last_end_ms = token.end_ms;
    }

    segments
}

fn ends_strong_sentence(text: &str) -> bool {
    let trimmed = text.trim_end().trim_end_matches(|character| {
        matches!(
            character,
            '"' | '\'' | '”' | '’' | '」' | '』' | ')' | '）' | ']' | '】'
        )
    });
    matches!(
        trimmed.chars().next_back(),
        Some('.' | '?' | '!' | '。' | '？' | '！' | '…')
    )
}

fn non_empty_metadata(value: &str) -> Option<String> {
    let normalized = value.trim();
    (!normalized.is_empty()).then(|| normalized.to_string())
}

fn render_transcript_section(
    session_id: &str,
    section_title: Option<&str>,
    segments: &[NotebookTranscriptSegment],
    include_leading_separator: bool,
) -> RenderedSection {
    render_transcript_section_for_schema(
        session_id,
        section_title,
        segments,
        include_leading_separator,
        ASYNC_PROJECTION_SCHEMA_VERSION,
    )
}

fn render_transcript_section_for_schema(
    session_id: &str,
    section_title: Option<&str>,
    segments: &[NotebookTranscriptSegment],
    include_leading_separator: bool,
    schema_version: u64,
) -> RenderedSection {
    let mut text = String::new();
    let mut marks = Vec::new();
    let section_start = 0;
    if include_leading_separator {
        text.push_str("\n\n");
    }
    let title = section_title.unwrap_or(session_id);
    text.push_str(&format!("## {title}\n"));

    for (index, segment) in segments.iter().enumerate() {
        if index > 0 {
            text.push_str("\n\n");
        }
        let block_start = text.chars().count();
        if let Some(start_ms) = segment.start_ms {
            text.push_str(&format!("[{}]\n", format_timestamp(start_ms)));
        }
        text.push_str(&segment.text);
        let block_len = text.chars().count() - block_start;
        if block_len > 0 {
            marks.push(RenderedMark {
                pos: block_start,
                len: block_len,
                key: "segment_id".to_string(),
                value_json: json_string(&segment.segment_id),
            });
            if let Some(start_ms) = segment.start_ms {
                marks.push(RenderedMark {
                    pos: block_start,
                    len: block_len,
                    key: "timestamp_ms".to_string(),
                    value_json: start_ms.to_string(),
                });
            }
            if let Some(end_ms) = segment.end_ms {
                marks.push(RenderedMark {
                    pos: block_start,
                    len: block_len,
                    key: "end_ms".to_string(),
                    value_json: end_ms.to_string(),
                });
            }
            if let Some(source_language) = segment.source_language.as_deref() {
                marks.push(RenderedMark {
                    pos: block_start,
                    len: block_len,
                    key: "source_language".to_string(),
                    value_json: json_string(source_language),
                });
            }
            if let Some(provider_speaker_label) = segment.provider_speaker_label.as_deref() {
                marks.push(RenderedMark {
                    pos: block_start,
                    len: block_len,
                    key: "provider_speaker_label".to_string(),
                    value_json: json_string(provider_speaker_label),
                });
            }
        }
    }

    let section_len = text.chars().count() - section_start;
    if section_len > 0 {
        marks.push(RenderedMark {
            pos: section_start,
            len: section_len,
            key: "session_id".to_string(),
            value_json: json_string(session_id),
        });
        marks.push(RenderedMark {
            pos: section_start,
            len: section_len,
            key: ASYNC_PROJECTION_SCHEMA_MARK.to_string(),
            value_json: schema_version.to_string(),
        });
    }

    RenderedSection { text, marks }
}

fn render_unversioned_legacy_transcript_section(
    session_id: &str,
    section_title: Option<&str>,
    segments: &[FfiNotebookTranscriptSegment],
    include_leading_separator: bool,
) -> RenderedSection {
    let mut text = String::new();
    let mut marks = Vec::new();
    if include_leading_separator {
        text.push_str("\n\n");
    }
    text.push_str(&format!("## {}\n", section_title.unwrap_or(session_id)));
    for (index, segment) in segments.iter().enumerate() {
        if index > 0 {
            text.push_str("\n\n");
        }
        let block_start = text.chars().count();
        text.push_str(&format!(
            "[{}]\n{}",
            format_timestamp(segment.timestamp_ms),
            segment.text
        ));
        let block_len = text.chars().count() - block_start;
        marks.push(RenderedMark {
            pos: block_start,
            len: block_len,
            key: "segment_id".to_string(),
            value_json: json_string(&segment.segment_id),
        });
        marks.push(RenderedMark {
            pos: block_start,
            len: block_len,
            key: "timestamp_ms".to_string(),
            value_json: segment.timestamp_ms.to_string(),
        });
    }
    marks.push(RenderedMark {
        pos: 0,
        len: text.chars().count(),
        key: "session_id".to_string(),
        value_json: json_string(session_id),
    });
    RenderedSection { text, marks }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ProjectionSchemaState {
    Unversioned,
    Version(u64),
    Malformed,
}

#[derive(Debug, Clone, PartialEq)]
struct DeltaAttributeRun {
    len: usize,
    attributes: BTreeMap<String, serde_json::Value>,
}

fn projection_schema_state(
    delta_json: &str,
    range: crate::editor_api::TextRange,
) -> Result<ProjectionSchemaState, CoreError> {
    let value: serde_json::Value =
        serde_json::from_str(delta_json).map_err(|error| CoreError::ValidationFailed {
            message: format!("invalid editor Delta JSON: {error}"),
        })?;
    let segments = value
        .as_array()
        .ok_or_else(|| CoreError::ValidationFailed {
            message: "editor Delta must be an array".to_string(),
        })?;
    let range_end =
        range
            .pos
            .checked_add(range.len)
            .ok_or_else(|| CoreError::ValidationFailed {
                message: "editor projection range overflow".to_string(),
            })?;
    let mut cursor = 0_usize;
    let mut covered = 0_usize;
    let mut saw_missing = false;
    let mut version: Option<u64> = None;
    let mut malformed = false;

    for segment in segments {
        let text = segment
            .get("insert")
            .and_then(serde_json::Value::as_str)
            .ok_or_else(|| CoreError::ValidationFailed {
                message: "editor Delta text insert must be a string".to_string(),
            })?;
        let segment_len = text.chars().count();
        let segment_end = cursor.saturating_add(segment_len);
        let overlap_start = cursor.max(range.pos);
        let overlap_end = segment_end.min(range_end);
        if overlap_start < overlap_end {
            covered = covered.saturating_add(overlap_end - overlap_start);
            let attribute = segment
                .get("attributes")
                .and_then(serde_json::Value::as_object)
                .and_then(|attributes| attributes.get(ASYNC_PROJECTION_SCHEMA_MARK));
            match attribute {
                None => saw_missing = true,
                Some(value) => match value.as_u64() {
                    Some(found) => {
                        if version.is_some_and(|expected| expected != found) {
                            malformed = true;
                        }
                        version = Some(found);
                    }
                    None => malformed = true,
                },
            }
        }
        cursor = segment_end;
    }

    if covered != range.len {
        return Err(CoreError::ValidationFailed {
            message: "editor projection range is outside Delta content".to_string(),
        });
    }
    Ok(match (version, saw_missing, malformed) {
        (None, true, false) => ProjectionSchemaState::Unversioned,
        (Some(version), false, false) => ProjectionSchemaState::Version(version),
        _ => ProjectionSchemaState::Malformed,
    })
}

fn delta_range_matches_rendered_section(
    delta_json: &str,
    range: crate::editor_api::TextRange,
    content: &str,
    rendered: &RenderedSection,
) -> Result<bool, CoreError> {
    if range.len != rendered.text.chars().count()
        || text_for_range(content, range)? != rendered.text
    {
        return Ok(false);
    }
    Ok(actual_delta_attribute_runs(delta_json, range)?
        == rendered_section_attribute_runs(rendered)?)
}

/// Some early Loro snapshots retained the Session ownership mark and exact
/// canonical legacy text but dropped technical `segment_id`/`timestamp_ms`
/// marks (observed most often on the first block). Those marks are derived from
/// immutable provider tokens, not user content. Permit only their absence:
/// changed values, missing ownership, or any extra formatting/annotation mark
/// still makes the document ineligible for automatic migration.
fn delta_range_matches_legacy_with_missing_technical_marks(
    delta_json: &str,
    range: crate::editor_api::TextRange,
    content: &str,
    rendered: &RenderedSection,
) -> Result<bool, CoreError> {
    if range.len != rendered.text.chars().count()
        || text_for_range(content, range)? != rendered.text
    {
        return Ok(false);
    }

    let actual = actual_delta_attribute_runs(delta_json, range)?;
    let expected = rendered_section_attribute_runs(rendered)?;
    let mut actual_index = 0_usize;
    let mut expected_index = 0_usize;
    let mut actual_remaining = actual.first().map_or(0, |run| run.len);
    let mut expected_remaining = expected.first().map_or(0, |run| run.len);

    while actual_index < actual.len() && expected_index < expected.len() {
        let actual_attributes = &actual[actual_index].attributes;
        let expected_attributes = &expected[expected_index].attributes;
        if actual_attributes
            .iter()
            .any(|(key, value)| expected_attributes.get(key) != Some(value))
            || expected_attributes.keys().any(|key| {
                !actual_attributes.contains_key(key) && key != "segment_id" && key != "timestamp_ms"
            })
        {
            return Ok(false);
        }

        let consumed = actual_remaining.min(expected_remaining);
        actual_remaining -= consumed;
        expected_remaining -= consumed;
        if actual_remaining == 0 {
            actual_index += 1;
            actual_remaining = actual.get(actual_index).map_or(0, |run| run.len);
        }
        if expected_remaining == 0 {
            expected_index += 1;
            expected_remaining = expected.get(expected_index).map_or(0, |run| run.len);
        }
    }

    Ok(actual_index == actual.len() && expected_index == expected.len())
}

fn actual_delta_attribute_runs(
    delta_json: &str,
    range: crate::editor_api::TextRange,
) -> Result<Vec<DeltaAttributeRun>, CoreError> {
    let value: serde_json::Value =
        serde_json::from_str(delta_json).map_err(|error| CoreError::ValidationFailed {
            message: format!("invalid editor Delta JSON: {error}"),
        })?;
    let segments = value
        .as_array()
        .ok_or_else(|| CoreError::ValidationFailed {
            message: "editor Delta must be an array".to_string(),
        })?;
    let range_end =
        range
            .pos
            .checked_add(range.len)
            .ok_or_else(|| CoreError::ValidationFailed {
                message: "editor projection range overflow".to_string(),
            })?;
    let mut cursor = 0_usize;
    let mut covered = 0_usize;
    let mut runs = Vec::new();

    for segment in segments {
        let text = segment
            .get("insert")
            .and_then(serde_json::Value::as_str)
            .ok_or_else(|| CoreError::ValidationFailed {
                message: "editor Delta text insert must be a string".to_string(),
            })?;
        let segment_len = text.chars().count();
        let segment_end =
            cursor
                .checked_add(segment_len)
                .ok_or_else(|| CoreError::ValidationFailed {
                    message: "editor Delta length overflow".to_string(),
                })?;
        let overlap_start = cursor.max(range.pos);
        let overlap_end = segment_end.min(range_end);
        if overlap_start < overlap_end {
            let overlap_len = overlap_end - overlap_start;
            covered = covered.saturating_add(overlap_len);
            let attributes = match segment.get("attributes") {
                None | Some(serde_json::Value::Null) => BTreeMap::new(),
                Some(value) => value
                    .as_object()
                    .ok_or_else(|| CoreError::ValidationFailed {
                        message: "editor Delta attributes must be an object".to_string(),
                    })?
                    .iter()
                    .map(|(key, value)| (key.clone(), value.clone()))
                    .collect(),
            };
            push_attribute_run(&mut runs, overlap_len, attributes);
        }
        cursor = segment_end;
    }

    if covered != range.len {
        return Err(CoreError::ValidationFailed {
            message: "editor projection range is outside Delta content".to_string(),
        });
    }
    Ok(runs)
}

fn rendered_section_attribute_runs(
    rendered: &RenderedSection,
) -> Result<Vec<DeltaAttributeRun>, CoreError> {
    let text_len = rendered.text.chars().count();
    let mut starts: BTreeMap<usize, Vec<(String, serde_json::Value)>> = BTreeMap::new();
    let mut ends: BTreeMap<usize, Vec<String>> = BTreeMap::new();
    let mut boundaries = BTreeSet::from([0_usize, text_len]);
    for mark in &rendered.marks {
        let end = mark
            .pos
            .checked_add(mark.len)
            .filter(|end| *end <= text_len)
            .ok_or_else(|| CoreError::ValidationFailed {
                message: format!("rendered mark {} is outside section text", mark.key),
            })?;
        let value = serde_json::from_str(&mark.value_json).map_err(|error| {
            CoreError::ValidationFailed {
                message: format!("invalid rendered mark {} value: {error}", mark.key),
            }
        })?;
        starts
            .entry(mark.pos)
            .or_default()
            .push((mark.key.clone(), value));
        ends.entry(end).or_default().push(mark.key.clone());
        boundaries.insert(mark.pos);
        boundaries.insert(end);
    }

    let boundaries = boundaries.into_iter().collect::<Vec<_>>();
    let mut active = BTreeMap::new();
    let mut runs = Vec::new();
    for window in boundaries.windows(2) {
        let pos = window[0];
        let next = window[1];
        if let Some(keys) = ends.get(&pos) {
            for key in keys {
                active.remove(key);
            }
        }
        if let Some(marks) = starts.get(&pos) {
            for (key, value) in marks {
                if active.insert(key.clone(), value.clone()).is_some() {
                    return Err(CoreError::ValidationFailed {
                        message: format!("overlapping rendered mark key {key}"),
                    });
                }
            }
        }
        if next > pos {
            push_attribute_run(&mut runs, next - pos, active.clone());
        }
    }
    Ok(runs)
}

fn push_attribute_run(
    runs: &mut Vec<DeltaAttributeRun>,
    len: usize,
    attributes: BTreeMap<String, serde_json::Value>,
) {
    if len == 0 {
        return;
    }
    if let Some(last) = runs.last_mut().filter(|last| last.attributes == attributes) {
        last.len = last.len.saturating_add(len);
    } else {
        runs.push(DeltaAttributeRun { len, attributes });
    }
}

fn text_for_range(content: &str, range: crate::editor_api::TextRange) -> Result<String, CoreError> {
    let range_end =
        range
            .pos
            .checked_add(range.len)
            .ok_or_else(|| CoreError::ValidationFailed {
                message: "editor projection range overflow".to_string(),
            })?;
    if range_end > content.chars().count() {
        return Err(CoreError::ValidationFailed {
            message: "editor projection range is outside document content".to_string(),
        });
    }
    Ok(content.chars().skip(range.pos).take(range.len).collect())
}

fn format_timestamp(timestamp_ms: u64) -> String {
    let total_seconds = timestamp_ms / 1000;
    let hours = total_seconds / 3600;
    let minutes = (total_seconds % 3600) / 60;
    let seconds = total_seconds % 60;
    if hours > 0 {
        format!("{hours:02}:{minutes:02}:{seconds:02}")
    } else {
        format!("{minutes:02}:{seconds:02}")
    }
}

fn json_string(value: &str) -> String {
    serde_json::to_string(value).unwrap_or_else(|_| "\"\"".to_string())
}

#[cfg(test)]
mod import_tests {
    use super::*;
    use tempfile::TempDir;
    use vt_store::notebook_capture_store::{
        AsyncTaskState, CaptureMode, CaptureState, NotebookCaptureProfile,
        NotebookCaptureProfileUpdate, ProjectionState, RemoteHealth,
    };

    fn setup() -> (TempDir, ZuTalkCore) {
        let temp = TempDir::new().unwrap();
        let core = ZuTalkCore::new_for_test(temp.path().to_str().unwrap().to_string()).unwrap();
        // Keep task rows deterministic; these tests cover the durable import
        // intent/receipt boundary, not provider execution.
        core.worker_cancel.cancel();
        (temp, core)
    }

    fn fixture_wav() -> String {
        std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../vt-audio/tests/fixtures/test_16k_mono.wav")
            .to_str()
            .unwrap()
            .to_string()
    }

    fn provider_token(
        text: &str,
        start_ms: u64,
        end_ms: u64,
        language: &str,
        speaker: Option<&str>,
        translation_status: vt_model::TranslationStatus,
    ) -> Token {
        Token {
            text: text.to_string(),
            start_ms,
            end_ms,
            is_final: true,
            language: language.to_string(),
            speaker: speaker.map(str::to_string),
            confidence: 1.0,
            translation_status,
        }
    }

    /// Reproduces the unversioned projection format shipped before processed
    /// transcript metadata and utterance-sized segmentation were introduced.
    /// Keep this test fixture independent from the production migration
    /// renderer so a format drift cannot make a destructive migration pass by
    /// comparing one implementation with itself.
    fn render_unversioned_legacy_projection_for_test(
        session_id: &str,
        section_title: Option<&str>,
        tokens: &[Token],
    ) -> RenderedSection {
        const LEGACY_GAP_MS: u64 = 2_000;
        let mut segments: Vec<FfiNotebookTranscriptSegment> = Vec::new();
        let mut last_end_ms = 0_u64;
        for token in tokens {
            if segments.is_empty() || token.start_ms.saturating_sub(last_end_ms) > LEGACY_GAP_MS {
                segments.push(FfiNotebookTranscriptSegment {
                    segment_id: format!("{:016x}", token.start_ms),
                    timestamp_ms: token.start_ms,
                    text: token.text.clone(),
                });
            } else if let Some(last) = segments.last_mut() {
                last.text.push_str(&token.text);
            }
            last_end_ms = token.end_ms;
        }

        let mut text = format!("## {}\n", section_title.unwrap_or(session_id));
        let mut marks = Vec::new();
        for (index, segment) in segments.iter().enumerate() {
            if index > 0 {
                text.push_str("\n\n");
            }
            let block_start = text.chars().count();
            text.push_str(&format!(
                "[{}]\n{}",
                format_timestamp(segment.timestamp_ms),
                segment.text
            ));
            let block_len = text.chars().count() - block_start;
            marks.push(RenderedMark {
                pos: block_start,
                len: block_len,
                key: "segment_id".to_string(),
                value_json: json_string(&segment.segment_id),
            });
            marks.push(RenderedMark {
                pos: block_start,
                len: block_len,
                key: "timestamp_ms".to_string(),
                value_json: segment.timestamp_ms.to_string(),
            });
        }
        marks.push(RenderedMark {
            pos: 0,
            len: text.chars().count(),
            key: "session_id".to_string(),
            value_json: json_string(session_id),
        });
        RenderedSection { text, marks }
    }

    /// Independent fixture for the shipped schema-v2 layout. Do not call the
    /// production v2 reconstruction helpers here: this test must catch a drift
    /// that could otherwise make the migration compare an implementation with
    /// itself and overwrite edited content.
    fn render_schema_v2_projection_for_test(
        session_id: &str,
        section_title: Option<&str>,
        tokens: &[Token],
    ) -> RenderedSection {
        let mut segments: Vec<NotebookTranscriptSegment> = Vec::new();
        let mut last_end_ms: Option<u64> = None;
        for token in tokens {
            let language =
                (!token.language.trim().is_empty()).then(|| token.language.trim().into());
            let speaker = token
                .speaker
                .as_deref()
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .map(str::to_string);
            let starts_new = match segments.last() {
                None => true,
                Some(last) => {
                    last_end_ms.is_some_and(|end| token.start_ms.saturating_sub(end) > 2_000)
                        || last.source_language != language
                        || last.provider_speaker_label != speaker
                        || last.translation_status != token.translation_status
                }
            };
            if starts_new {
                segments.push(NotebookTranscriptSegment {
                    segment_id: format!("{:016x}", token.start_ms),
                    start_ms: Some(token.start_ms),
                    end_ms: Some(token.end_ms),
                    text: token.text.clone(),
                    source_language: language,
                    provider_speaker_label: speaker,
                    translation_status: token.translation_status,
                });
            } else if let Some(last) = segments.last_mut() {
                last.text.push_str(&token.text);
                last.end_ms = Some(last.end_ms.unwrap_or(token.end_ms).max(token.end_ms));
            }
            last_end_ms = Some(token.end_ms);
        }

        let mut text = format!("## {}\n", section_title.unwrap_or(session_id));
        let mut marks = Vec::new();
        for (index, segment) in segments.iter().enumerate() {
            if index > 0 {
                text.push_str("\n\n");
            }
            let block_start = text.chars().count();
            text.push_str(&format!(
                "[{}]\n{}",
                format_timestamp(segment.start_ms.unwrap()),
                segment.text
            ));
            let block_len = text.chars().count() - block_start;
            for (key, value_json) in [
                ("segment_id", json_string(&segment.segment_id)),
                ("timestamp_ms", segment.start_ms.unwrap().to_string()),
                ("end_ms", segment.end_ms.unwrap().to_string()),
            ] {
                marks.push(RenderedMark {
                    pos: block_start,
                    len: block_len,
                    key: key.into(),
                    value_json,
                });
            }
            if let Some(language) = segment.source_language.as_deref() {
                marks.push(RenderedMark {
                    pos: block_start,
                    len: block_len,
                    key: "source_language".into(),
                    value_json: json_string(language),
                });
            }
            if let Some(speaker) = segment.provider_speaker_label.as_deref() {
                marks.push(RenderedMark {
                    pos: block_start,
                    len: block_len,
                    key: "provider_speaker_label".into(),
                    value_json: json_string(speaker),
                });
            }
        }
        let len = text.chars().count();
        marks.push(RenderedMark {
            pos: 0,
            len,
            key: "session_id".into(),
            value_json: json_string(session_id),
        });
        marks.push(RenderedMark {
            pos: 0,
            len,
            key: ASYNC_PROJECTION_SCHEMA_MARK.into(),
            value_json: "2".into(),
        });
        RenderedSection { text, marks }
    }

    fn seed_unversioned_legacy_projection(
        tokens: &[Token],
    ) -> (TempDir, ZuTalkCore, FfiNotebookTab, String) {
        let (temp, core) = setup();
        let notebook = core
            .create_notebook(Some("Legacy research".into()))
            .unwrap();
        let session_id = "legacy-async-projection".to_string();
        core.session_store
            .insert_session(&vt_store::SessionRecord {
                id: session_id.clone(),
                title: "Legacy interview".into(),
                session_type: "recording".into(),
                status: "completed".into(),
                duration_ms: 60_000,
                created_at: "2024-01-02 03:04:05".into(),
                deleted_at: None,
            })
            .unwrap();
        core.assign_orphan_session_to_notebook(session_id.clone(), notebook.id.clone())
            .unwrap();
        let projection = core
            .notebook_store
            .ensure_session_projection(
                &notebook.id,
                BuiltinNotebookTab::AsyncTranscript,
                &session_id,
                Some("Legacy interview"),
            )
            .unwrap();
        core.session_meta.set_tokens(&session_id, tokens).unwrap();
        let async_tab = core
            .list_notebook_tabs(notebook.id)
            .unwrap()
            .into_iter()
            .find(|tab| tab.builtin_kind == BuiltinNotebookTab::AsyncTranscript.as_str())
            .unwrap();
        crate::editor_api::open_editor_session(temp.path(), &core.editor_bridge, &async_tab.doc_id)
            .unwrap();
        let rendered = render_unversioned_legacy_projection_for_test(
            &session_id,
            projection.section_title.as_deref(),
            tokens,
        );
        core.editor_bridge
            .apply(
                &async_tab.doc_id,
                EditOp::Insert {
                    pos: 0,
                    text: rendered.text,
                },
            )
            .unwrap();
        for mark in rendered.marks {
            core.editor_bridge
                .apply(
                    &async_tab.doc_id,
                    EditOp::Mark {
                        pos: mark.pos,
                        len: mark.len,
                        key: mark.key,
                        value_json: mark.value_json,
                    },
                )
                .unwrap();
        }
        (temp, core, async_tab, session_id)
    }

    fn seed_current_projection(tokens: &[Token]) -> (TempDir, ZuTalkCore, FfiNotebookTab, String) {
        let (temp, core) = setup();
        let notebook = core
            .create_notebook(Some("Current research".into()))
            .unwrap();
        let session_id = "current-async-projection".to_string();
        core.session_store
            .insert_session(&vt_store::SessionRecord {
                id: session_id.clone(),
                title: "Current interview".into(),
                session_type: "recording".into(),
                status: "completed".into(),
                duration_ms: 60_000,
                created_at: "2024-01-02 03:04:05".into(),
                deleted_at: None,
            })
            .unwrap();
        core.assign_orphan_session_to_notebook(session_id.clone(), notebook.id.clone())
            .unwrap();
        core.notebook_store
            .ensure_session_projection(
                &notebook.id,
                BuiltinNotebookTab::AsyncTranscript,
                &session_id,
                Some("Current interview"),
            )
            .unwrap();
        core.session_meta.set_tokens(&session_id, tokens).unwrap();
        core.notebook_transcript_projector()
            .sync_linked_session_transcript_from_store(
                &session_id,
                BuiltinNotebookTab::AsyncTranscript,
            )
            .unwrap();
        let async_tab = core
            .list_notebook_tabs(notebook.id)
            .unwrap()
            .into_iter()
            .find(|tab| tab.builtin_kind == BuiltinNotebookTab::AsyncTranscript.as_str())
            .unwrap();
        (temp, core, async_tab, session_id)
    }

    fn seed_schema_v2_projection(
        tokens: &[Token],
    ) -> (TempDir, ZuTalkCore, FfiNotebookTab, String) {
        let (temp, core, async_tab, session_id) = seed_current_projection(tokens);
        let range = session_range(&core, &async_tab, &session_id);
        core.editor_bridge
            .apply(
                &async_tab.doc_id,
                EditOp::Delete {
                    pos: range.pos,
                    len: range.len,
                },
            )
            .unwrap();
        let rendered =
            render_schema_v2_projection_for_test(&session_id, Some("Current interview"), tokens);
        core.editor_bridge
            .apply(
                &async_tab.doc_id,
                EditOp::Insert {
                    pos: 0,
                    text: rendered.text,
                },
            )
            .unwrap();
        for mark in rendered.marks {
            core.editor_bridge
                .apply(
                    &async_tab.doc_id,
                    EditOp::Mark {
                        pos: mark.pos,
                        len: mark.len,
                        key: mark.key,
                        value_json: mark.value_json,
                    },
                )
                .unwrap();
        }
        (temp, core, async_tab, session_id)
    }

    fn session_range(
        core: &ZuTalkCore,
        tab: &FfiNotebookTab,
        session_id: &str,
    ) -> crate::editor_api::TextRange {
        let delta = core.editor_bridge.get_delta(&tab.doc_id).unwrap();
        crate::editor_api::find_unique_marked_range(
            &delta,
            crate::editor_api::DeltaMarkSelector {
                session_id: Some(session_id),
                utterance_id: None,
                lane_language: None,
            },
        )
        .unwrap()
        .unwrap()
    }

    fn legacy_projection_tokens() -> Vec<Token> {
        vec![
            provider_token(
                "First answer.",
                0,
                4_100,
                "en",
                Some("spk-a"),
                vt_model::TranslationStatus::Original,
            ),
            provider_token(
                " Second answer.",
                4_200,
                8_300,
                "en",
                Some("spk-b"),
                vt_model::TranslationStatus::Original,
            ),
        ]
    }

    #[test]
    fn processed_tokens_split_on_gap_speaker_language_or_translation_status() {
        use vt_model::TranslationStatus::{Original, Translation};

        let segments = build_notebook_segments_from_tokens(&[
            provider_token("a", 0, 500, "en", Some("spk-a"), Original),
            // Exactly 2 seconds is still the same segment.
            provider_token("b", 2_500, 2_700, "en", Some("spk-a"), Original),
            // More than 2 seconds starts a new segment.
            provider_token("gap", 4_701, 4_800, "en", Some("spk-a"), Original),
            provider_token("speaker", 4_800, 4_900, "en", Some("spk-b"), Original),
            provider_token("language", 4_900, 5_000, "fr", Some("spk-b"), Original),
            provider_token(
                "translation",
                5_000,
                5_100,
                "fr",
                Some("spk-b"),
                Translation,
            ),
        ]);

        assert_eq!(segments.len(), 5);
        assert_eq!(segments[0].text, "ab");
        assert_eq!(segments[0].start_ms, Some(0));
        assert_eq!(segments[0].end_ms, Some(2_700));
        assert_eq!(segments[0].source_language.as_deref(), Some("en"));
        assert_eq!(segments[0].provider_speaker_label.as_deref(), Some("spk-a"));
        assert_eq!(segments[1].text, "gap");
        assert_eq!(segments[2].text, "speaker");
        assert_eq!(segments[3].text, "language");
        assert_eq!(segments[4].text, "translation");
        let unique_ids: std::collections::HashSet<_> =
            segments.iter().map(|segment| &segment.segment_id).collect();
        assert_eq!(unique_ids.len(), segments.len());
    }

    #[test]
    fn processed_multi_token_paragraphs_respect_aggregation_bounds() {
        let tokens = (0..18)
            .map(|index| {
                provider_token(
                    if index % 3 == 2 {
                        "一句结束。"
                    } else {
                        "连续内容"
                    },
                    index * 1_500,
                    index * 1_500 + 1_000,
                    "",
                    None,
                    vt_model::TranslationStatus::None,
                )
            })
            .collect::<Vec<_>>();

        let segments = build_notebook_segments_from_tokens(&tokens);

        assert!(segments.len() > 1);
        assert!(segments.iter().all(|segment| {
            segment.end_ms.unwrap() - segment.start_ms.unwrap() <= 20_000
                && segment.text.chars().count() <= 240
        }));
        assert!(segments
            .iter()
            .take(segments.len().saturating_sub(1))
            .all(|segment| segment.text.ends_with('。')));
    }

    #[test]
    fn oversized_unicode_provider_token_splits_without_text_or_timing_loss() {
        let source = "你🙂e\u{301}界".repeat(80);
        assert!(source.chars().count() > 240);
        let segments = build_notebook_segments_from_tokens(&[provider_token(
            &source,
            1_000,
            31_000,
            "zh",
            None,
            vt_model::TranslationStatus::None,
        )]);

        assert!(segments.len() > 1);
        assert!(segments
            .iter()
            .all(|segment| segment.text.chars().count() <= 240));
        assert_eq!(
            segments
                .iter()
                .map(|segment| segment.text.as_str())
                .collect::<String>(),
            source
        );
        assert!(segments
            .iter()
            .all(|segment| segment.start_ms == Some(1_000) && segment.end_ms == Some(31_000)));

        // Provider timing is atomic. A token with no safe text boundary keeps
        // its honest range even when it exceeds the multi-token 20s boundary.
        let atomic = build_notebook_segments_from_tokens(&[provider_token(
            "字",
            2_000,
            102_000,
            "zh",
            None,
            vt_model::TranslationStatus::None,
        )]);
        assert_eq!(atomic.len(), 1);
        assert_eq!(atomic[0].text, "字");
        assert_eq!(atomic[0].start_ms, Some(2_000));
        assert_eq!(atomic[0].end_ms, Some(102_000));
    }

    #[test]
    fn exact_schema_v2_projection_migrates_to_bounded_schema_v3() {
        let tokens = (0..12)
            .map(|index| {
                provider_token(
                    if index % 3 == 2 {
                        "一句结束。"
                    } else {
                        "连续内容"
                    },
                    index * 1_500,
                    index * 1_500 + 1_000,
                    "",
                    None,
                    vt_model::TranslationStatus::None,
                )
            })
            .collect::<Vec<_>>();
        let (_temp, core, async_tab, session_id) = seed_schema_v2_projection(&tokens);
        let before = core.editor_bridge.get_content(&async_tab.doc_id).unwrap();
        let before_delta = core.editor_bridge.get_delta(&async_tab.doc_id).unwrap();
        assert_eq!(before.matches("[").count(), 1);
        assert!(before_delta.contains("\"async_projection_schema_version\":2"));

        assert!(core
            .repair_session_transcript_projection(session_id.clone())
            .unwrap());

        let after = core.editor_bridge.get_content(&async_tab.doc_id).unwrap();
        let after_delta = core.editor_bridge.get_delta(&async_tab.doc_id).unwrap();
        assert!(after.matches("[").count() > 1, "{after}");
        assert!(after_delta.contains("\"async_projection_schema_version\":3"));
        assert_eq!(
            build_notebook_segments_from_tokens(&tokens)
                .iter()
                .map(|segment| segment.text.as_str())
                .collect::<String>(),
            tokens
                .iter()
                .map(|token| token.text.as_str())
                .collect::<String>()
        );

        let migrated_once = after_delta;
        assert!(core
            .repair_session_transcript_projection(session_id)
            .unwrap());
        assert_eq!(
            core.editor_bridge.get_delta(&async_tab.doc_id).unwrap(),
            migrated_once
        );
    }

    #[test]
    fn edited_schema_v2_text_or_formatting_is_never_migrated() {
        let tokens = (0..6)
            .map(|index| {
                provider_token(
                    "Long answer. ",
                    index * 1_500,
                    index * 1_500 + 1_000,
                    "en",
                    None,
                    vt_model::TranslationStatus::Original,
                )
            })
            .collect::<Vec<_>>();

        let (_temp, core, async_tab, session_id) = seed_schema_v2_projection(&tokens);
        let content = core.editor_bridge.get_content(&async_tab.doc_id).unwrap();
        let edit_pos = content.find("Long answer").unwrap();
        core.editor_bridge
            .apply(
                &async_tab.doc_id,
                EditOp::Replace {
                    pos: edit_pos,
                    len: "Long".chars().count(),
                    text: "Edited".into(),
                },
            )
            .unwrap();
        let edited_text_delta = core.editor_bridge.get_delta(&async_tab.doc_id).unwrap();
        assert!(core
            .repair_session_transcript_projection(session_id.clone())
            .unwrap());
        assert_eq!(
            core.editor_bridge.get_delta(&async_tab.doc_id).unwrap(),
            edited_text_delta
        );
        core.notebook_transcript_projector()
            .sync_linked_session_transcript_from_store(
                &session_id,
                BuiltinNotebookTab::AsyncTranscript,
            )
            .unwrap();
        assert_eq!(
            core.editor_bridge.get_delta(&async_tab.doc_id).unwrap(),
            edited_text_delta
        );

        let (_temp, core, async_tab, session_id) = seed_schema_v2_projection(&tokens);
        let content = core.editor_bridge.get_content(&async_tab.doc_id).unwrap();
        let format_pos = content.find("Long answer").unwrap();
        core.editor_bridge
            .apply(
                &async_tab.doc_id,
                EditOp::Mark {
                    pos: format_pos,
                    len: "Long answer".chars().count(),
                    key: "bold".into(),
                    value_json: "true".into(),
                },
            )
            .unwrap();
        let formatted_delta = core.editor_bridge.get_delta(&async_tab.doc_id).unwrap();
        assert!(core
            .repair_session_transcript_projection(session_id)
            .unwrap());
        assert_eq!(
            core.editor_bridge.get_delta(&async_tab.doc_id).unwrap(),
            formatted_delta
        );
    }

    #[test]
    fn unedited_unversioned_projection_migrates_to_current_schema() {
        let tokens = legacy_projection_tokens();
        let (_temp, core, async_tab, session_id) = seed_unversioned_legacy_projection(&tokens);
        let legacy = core.editor_bridge.get_content(&async_tab.doc_id).unwrap();
        assert!(legacy.contains("First answer. Second answer."));
        assert!(!legacy.contains("\n\n[00:04]"));

        assert!(core
            .repair_session_transcript_projection(session_id)
            .unwrap());

        let migrated = core.editor_bridge.get_content(&async_tab.doc_id).unwrap();
        let delta = core.editor_bridge.get_delta(&async_tab.doc_id).unwrap();
        assert!(migrated.contains("First answer.\n\n[00:04]\n Second answer."));
        assert!(
            delta.contains("\"async_projection_schema_version\":3"),
            "{delta}"
        );
        assert!(delta.contains("\"provider_speaker_label\":\"spk-a\""));
        assert!(delta.contains("\"provider_speaker_label\":\"spk-b\""));
    }

    #[test]
    fn canonical_legacy_text_with_missing_first_block_technical_marks_migrates() {
        let tokens = vec![
            provider_token(
                "First answer.",
                0,
                1_000,
                "en",
                None,
                vt_model::TranslationStatus::Original,
            ),
            provider_token(
                "Second answer.",
                4_001,
                5_000,
                "en",
                None,
                vt_model::TranslationStatus::Original,
            ),
        ];
        let (_temp, core, async_tab, session_id) = seed_unversioned_legacy_projection(&tokens);
        let content = core.editor_bridge.get_content(&async_tab.doc_id).unwrap();
        let block_start = content.find("[00:00]").unwrap();
        let block_len = content[block_start..].find("\n\n").unwrap();
        for key in ["segment_id", "timestamp_ms"] {
            core.editor_bridge
                .apply(
                    &async_tab.doc_id,
                    EditOp::Unmark {
                        pos: block_start,
                        len: block_len,
                        key: key.into(),
                    },
                )
                .unwrap();
        }
        let damaged = core.editor_bridge.get_delta(&async_tab.doc_id).unwrap();
        assert!(!damaged.contains("\"timestamp_ms\":0"), "{damaged}");

        assert!(core
            .repair_session_transcript_projection(session_id)
            .unwrap());

        let migrated = core.editor_bridge.get_delta(&async_tab.doc_id).unwrap();
        assert!(migrated.contains("\"async_projection_schema_version\":3"));
        assert!(migrated.contains("\"timestamp_ms\":0"));
    }

    #[test]
    fn missing_legacy_technical_marks_do_not_hide_user_formatting() {
        let tokens = vec![
            provider_token(
                "First answer.",
                0,
                1_000,
                "en",
                None,
                vt_model::TranslationStatus::Original,
            ),
            provider_token(
                "Second answer.",
                4_001,
                5_000,
                "en",
                None,
                vt_model::TranslationStatus::Original,
            ),
        ];
        let (_temp, core, async_tab, session_id) = seed_unversioned_legacy_projection(&tokens);
        let content = core.editor_bridge.get_content(&async_tab.doc_id).unwrap();
        let block_start = content.find("[00:00]").unwrap();
        let block_len = content[block_start..].find("\n\n").unwrap();
        for key in ["segment_id", "timestamp_ms"] {
            core.editor_bridge
                .apply(
                    &async_tab.doc_id,
                    EditOp::Unmark {
                        pos: block_start,
                        len: block_len,
                        key: key.into(),
                    },
                )
                .unwrap();
        }
        let answer_start = content.find("First answer").unwrap();
        core.editor_bridge
            .apply(
                &async_tab.doc_id,
                EditOp::Mark {
                    pos: answer_start,
                    len: "First answer".chars().count(),
                    key: "bold".into(),
                    value_json: "true".into(),
                },
            )
            .unwrap();
        let before = core.editor_bridge.get_delta(&async_tab.doc_id).unwrap();

        assert!(core
            .repair_session_transcript_projection(session_id)
            .unwrap());

        assert_eq!(
            core.editor_bridge.get_delta(&async_tab.doc_id).unwrap(),
            before
        );
        assert!(!before.contains(ASYNC_PROJECTION_SCHEMA_MARK));
    }

    #[test]
    fn edited_unversioned_projection_is_never_migrated() {
        let tokens = legacy_projection_tokens();
        let (_temp, core, async_tab, session_id) = seed_unversioned_legacy_projection(&tokens);
        let content = core.editor_bridge.get_content(&async_tab.doc_id).unwrap();
        let edit_pos = content.find("First answer").unwrap();
        core.editor_bridge
            .apply(
                &async_tab.doc_id,
                EditOp::Replace {
                    pos: edit_pos,
                    len: "First answer".chars().count(),
                    text: "Edited answer".into(),
                },
            )
            .unwrap();
        let edited = core.editor_bridge.get_content(&async_tab.doc_id).unwrap();

        assert!(core
            .repair_session_transcript_projection(session_id)
            .unwrap());

        assert_eq!(
            core.editor_bridge.get_content(&async_tab.doc_id).unwrap(),
            edited
        );
        let delta = core.editor_bridge.get_delta(&async_tab.doc_id).unwrap();
        assert!(!delta.contains("async_projection_schema_version"));
    }

    #[test]
    fn formatting_only_legacy_edit_is_not_migrated() {
        let tokens = legacy_projection_tokens();
        let (_temp, core, async_tab, session_id) = seed_unversioned_legacy_projection(&tokens);
        let content = core.editor_bridge.get_content(&async_tab.doc_id).unwrap();
        let format_pos = content.find("First answer").unwrap();
        core.editor_bridge
            .apply(
                &async_tab.doc_id,
                EditOp::Mark {
                    pos: format_pos,
                    len: "First answer".chars().count(),
                    key: "bold".into(),
                    value_json: "true".into(),
                },
            )
            .unwrap();
        let before = core.editor_bridge.get_delta(&async_tab.doc_id).unwrap();

        assert!(core
            .repair_session_transcript_projection(session_id)
            .unwrap());

        assert_eq!(
            core.editor_bridge.get_delta(&async_tab.doc_id).unwrap(),
            before
        );
        assert!(!before.contains("async_projection_schema_version"));
    }

    #[test]
    fn stripped_schema_v3_is_not_misclassified_as_legacy() {
        let tokens = vec![provider_token(
            "Same visible text",
            0,
            1_000,
            "",
            None,
            vt_model::TranslationStatus::None,
        )];
        let (_temp, core, async_tab, session_id) = seed_current_projection(&tokens);
        let range = session_range(&core, &async_tab, &session_id);
        core.editor_bridge
            .apply(
                &async_tab.doc_id,
                EditOp::Unmark {
                    pos: range.pos,
                    len: range.len,
                    key: ASYNC_PROJECTION_SCHEMA_MARK.into(),
                },
            )
            .unwrap();
        let before = core.editor_bridge.get_delta(&async_tab.doc_id).unwrap();
        assert!(!before.contains(ASYNC_PROJECTION_SCHEMA_MARK));

        assert!(core
            .repair_session_transcript_projection(session_id)
            .unwrap());

        assert_eq!(
            core.editor_bridge.get_delta(&async_tab.doc_id).unwrap(),
            before
        );
    }

    #[test]
    fn provider_retry_preserves_complete_v3_and_fails_closed_after_partial_schema_edit() {
        let tokens = legacy_projection_tokens();
        let (_temp, core, async_tab, session_id) = seed_current_projection(&tokens);
        let before_retry = core.editor_bridge.get_delta(&async_tab.doc_id).unwrap();

        core.notebook_transcript_projector()
            .sync_linked_session_transcript_from_store(
                &session_id,
                BuiltinNotebookTab::AsyncTranscript,
            )
            .unwrap();
        assert_eq!(
            core.editor_bridge.get_delta(&async_tab.doc_id).unwrap(),
            before_retry
        );

        // Simulates: document flush succeeded, the DB Ready transition failed,
        // the user edited, and the immutable provider receipt was retried.
        let content = core.editor_bridge.get_content(&async_tab.doc_id).unwrap();
        let edit_pos = content.find("First answer").unwrap();
        core.editor_bridge
            .apply(
                &async_tab.doc_id,
                EditOp::Replace {
                    pos: edit_pos,
                    len: "First answer".chars().count(),
                    text: "Edited after flush".into(),
                },
            )
            .unwrap();
        let edited_v3_content = core.editor_bridge.get_content(&async_tab.doc_id).unwrap();
        let edited_v3_delta = core.editor_bridge.get_delta(&async_tab.doc_id).unwrap();
        core.notebook_transcript_projector()
            .sync_linked_session_transcript_from_store(
                &session_id,
                BuiltinNotebookTab::AsyncTranscript,
            )
            .unwrap();
        assert_eq!(
            core.editor_bridge.get_content(&async_tab.doc_id).unwrap(),
            edited_v3_content
        );
        assert_eq!(
            core.editor_bridge.get_delta(&async_tab.doc_id).unwrap(),
            edited_v3_delta
        );

        let range = session_range(&core, &async_tab, &session_id);
        core.editor_bridge
            .apply(
                &async_tab.doc_id,
                EditOp::Unmark {
                    pos: range.pos,
                    len: 1,
                    key: ASYNC_PROJECTION_SCHEMA_MARK.into(),
                },
            )
            .unwrap();
        let edited_content = core.editor_bridge.get_content(&async_tab.doc_id).unwrap();
        let edited_delta = core.editor_bridge.get_delta(&async_tab.doc_id).unwrap();

        let retry = core
            .notebook_transcript_projector()
            .sync_linked_session_transcript_from_store(
                &session_id,
                BuiltinNotebookTab::AsyncTranscript,
            );
        assert!(
            matches!(retry, Err(CoreError::ValidationFailed { .. })),
            "retry={retry:?}\n{edited_delta}"
        );
        assert_eq!(
            core.editor_bridge.get_content(&async_tab.doc_id).unwrap(),
            edited_content
        );
        assert_eq!(
            core.editor_bridge.get_delta(&async_tab.doc_id).unwrap(),
            edited_delta
        );
    }

    #[test]
    fn first_provider_completion_can_replace_a_noncanonical_unversioned_projection() {
        let old_tokens = legacy_projection_tokens();
        let (_temp, core, async_tab, session_id) = seed_unversioned_legacy_projection(&old_tokens);
        core.session_meta
            .set_tokens(
                &session_id,
                &[provider_token(
                    "Immutable provider result",
                    10_000,
                    12_000,
                    "en",
                    Some("spk-final"),
                    vt_model::TranslationStatus::Original,
                )],
            )
            .unwrap();

        core.notebook_transcript_projector()
            .sync_linked_session_transcript_from_store(
                &session_id,
                BuiltinNotebookTab::AsyncTranscript,
            )
            .unwrap();

        let content = core.editor_bridge.get_content(&async_tab.doc_id).unwrap();
        let delta = core.editor_bridge.get_delta(&async_tab.doc_id).unwrap();
        assert!(content.contains("Immutable provider result"));
        assert!(!content.contains("First answer"));
        assert!(delta.contains("\"async_projection_schema_version\":3"));
    }

    #[test]
    fn provider_retry_fails_closed_for_future_projection_schema() {
        let tokens = legacy_projection_tokens();
        let (_temp, core, async_tab, session_id) = seed_current_projection(&tokens);
        let range = session_range(&core, &async_tab, &session_id);
        core.editor_bridge
            .apply(
                &async_tab.doc_id,
                EditOp::Mark {
                    pos: range.pos,
                    len: range.len,
                    key: ASYNC_PROJECTION_SCHEMA_MARK.into(),
                    value_json: "99".into(),
                },
            )
            .unwrap();
        let before_content = core.editor_bridge.get_content(&async_tab.doc_id).unwrap();
        let before_delta = core.editor_bridge.get_delta(&async_tab.doc_id).unwrap();

        assert!(matches!(
            core.notebook_transcript_projector()
                .sync_linked_session_transcript_from_store(
                    &session_id,
                    BuiltinNotebookTab::AsyncTranscript,
                ),
            Err(CoreError::ValidationFailed { .. })
        ));
        assert_eq!(
            core.editor_bridge.get_content(&async_tab.doc_id).unwrap(),
            before_content
        );
        assert_eq!(
            core.editor_bridge.get_delta(&async_tab.doc_id).unwrap(),
            before_delta
        );
    }

    #[test]
    fn async_projection_api_rejects_non_async_tabs() {
        let tokens = legacy_projection_tokens();
        let (_temp, core, _async_tab, session_id) = seed_current_projection(&tokens);

        assert!(matches!(
            core.notebook_transcript_projector()
                .sync_linked_session_transcript_from_store(
                    &session_id,
                    BuiltinNotebookTab::RealtimeTranscript,
                ),
            Err(CoreError::ValidationFailed { .. })
        ));
    }

    #[test]
    fn migrated_projection_repair_is_idempotent() {
        let tokens = legacy_projection_tokens();
        let (_temp, core, async_tab, session_id) = seed_unversioned_legacy_projection(&tokens);
        assert!(core
            .repair_session_transcript_projection(session_id.clone())
            .unwrap());
        let once_content = core.editor_bridge.get_content(&async_tab.doc_id).unwrap();
        let once_delta = core.editor_bridge.get_delta(&async_tab.doc_id).unwrap();

        assert!(core
            .repair_session_transcript_projection(session_id)
            .unwrap());

        assert_eq!(
            core.editor_bridge.get_content(&async_tab.doc_id).unwrap(),
            once_content
        );
        assert_eq!(
            core.editor_bridge.get_delta(&async_tab.doc_id).unwrap(),
            once_delta
        );
    }

    #[test]
    fn processed_segment_marks_roundtrip_optional_provider_metadata_without_identity() {
        let rendered = render_transcript_section(
            "session-a",
            Some("Interview"),
            &[NotebookTranscriptSegment {
                segment_id: "segment-a".to_string(),
                start_ms: Some(1_250),
                end_ms: Some(2_750),
                text: "Provider result".to_string(),
                source_language: Some("en".to_string()),
                provider_speaker_label: Some("spk-2".to_string()),
                translation_status: vt_model::TranslationStatus::None,
            }],
            false,
        );
        let mark_value = |key: &str| {
            rendered
                .marks
                .iter()
                .find(|mark| mark.key == key)
                .map(|mark| mark.value_json.as_str())
        };

        assert_eq!(mark_value("timestamp_ms"), Some("1250"));
        assert_eq!(mark_value("end_ms"), Some("2750"));
        assert_eq!(mark_value("source_language"), Some("\"en\""));
        assert_eq!(mark_value("provider_speaker_label"), Some("\"spk-2\""));
        assert!(mark_value("session_speaker_id").is_none());
        assert!(mark_value("speaker_id").is_none());

        let legacy = render_transcript_section(
            "session-legacy",
            None,
            &[NotebookTranscriptSegment {
                segment_id: "segment-legacy".to_string(),
                start_ms: None,
                end_ms: None,
                text: "Legacy result".to_string(),
                source_language: None,
                provider_speaker_label: None,
                translation_status: vt_model::TranslationStatus::None,
            }],
            false,
        );
        assert!(!legacy.text.contains("[00:00]"));
        for key in [
            "timestamp_ms",
            "end_ms",
            "source_language",
            "provider_speaker_label",
        ] {
            assert!(legacy.marks.iter().all(|mark| mark.key != key));
        }
    }

    fn set_profile_privacy(
        core: &ZuTalkCore,
        notebook_id: &str,
        privacy_level: &str,
    ) -> NotebookCaptureProfile {
        let current = core
            .notebook_capture_store
            .get_or_create_profile(notebook_id)
            .unwrap();
        core.notebook_capture_store
            .update_profile(
                notebook_id,
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
                    privacy_level: privacy_level.into(),
                    send_context_to_soniox: false,
                },
            )
            .unwrap()
    }

    #[test]
    fn orphan_session_assignment_creates_one_owner_and_all_builtin_projections() {
        let (_temp, core) = setup();
        let target = core
            .create_notebook(Some("Recovered interviews".into()))
            .unwrap();
        let other = core.create_notebook(Some("Other topic".into())).unwrap();
        core.session_store
            .insert_session(&vt_store::SessionRecord {
                id: "legacy-orphan".into(),
                title: "Legacy interview".into(),
                session_type: "recording".into(),
                status: "completed".into(),
                duration_ms: 42_000,
                created_at: "2024-01-02 03:04:05".into(),
                deleted_at: None,
            })
            .unwrap();

        let filing = core
            .assign_orphan_session_to_notebook("legacy-orphan".into(), target.id.clone())
            .unwrap();
        assert!(!filing.transcript_projection_deferred);

        let links = core.list_notebook_sessions(target.id.clone()).unwrap();
        assert_eq!(links.len(), 1);
        assert_eq!(links[0].session_id, "legacy-orphan");
        for tab in core.list_notebook_tabs(target.id).unwrap() {
            let projections = core.list_notebook_session_projections(tab.id).unwrap();
            assert_eq!(projections.len(), 1);
            assert_eq!(projections[0].session_id, "legacy-orphan");
        }

        assert!(matches!(
            core.assign_orphan_session_to_notebook("legacy-orphan".into(), other.id),
            Err(CoreError::ValidationFailed { .. })
        ));
    }

    #[test]
    fn orphan_session_assignment_refuses_active_or_trashed_rows() {
        let (_temp, core) = setup();
        let target = core.create_notebook(Some("Research".into())).unwrap();
        for (id, status, deleted_at) in [
            ("active-orphan", "recording", None),
            (
                "trashed-orphan",
                "completed",
                Some("2026-01-01T00:00:00Z".to_string()),
            ),
        ] {
            core.session_store
                .insert_session(&vt_store::SessionRecord {
                    id: id.into(),
                    title: String::new(),
                    session_type: "recording".into(),
                    status: status.into(),
                    duration_ms: 0,
                    created_at: "2024-01-02 03:04:05".into(),
                    deleted_at,
                })
                .unwrap();
            assert!(matches!(
                core.assign_orphan_session_to_notebook(id.into(), target.id.clone()),
                Err(CoreError::ValidationFailed { .. })
            ));
        }
        assert!(core.list_notebook_sessions(target.id).unwrap().is_empty());
    }

    #[test]
    fn orphan_filing_commits_ownership_and_repairs_a_deferred_transcript_without_overwrite() {
        let (temp, core) = setup();
        let target = core
            .create_notebook(Some("Recovered research".into()))
            .unwrap();
        let session_id = "legacy-corrupt-transcript";
        core.session_store
            .insert_session(&vt_store::SessionRecord {
                id: session_id.into(),
                title: "Evidence interview".into(),
                session_type: "recording".into(),
                status: "completed".into(),
                duration_ms: 10_000,
                created_at: "2024-01-02 03:04:05".into(),
                deleted_at: None,
            })
            .unwrap();
        rusqlite::Connection::open(temp.path().join("zutalk.db"))
            .unwrap()
            .execute(
                "INSERT INTO session_meta (session_id, tokens_json)
                 VALUES (?1, '{broken-json')",
                rusqlite::params![session_id],
            )
            .unwrap();

        let filing = core
            .assign_orphan_session_to_notebook(session_id.into(), target.id.clone())
            .unwrap();

        assert!(filing.transcript_projection_deferred);
        assert_eq!(
            core.list_notebook_sessions(target.id.clone())
                .unwrap()
                .len(),
            1
        );

        core.session_meta
            .set_tokens(
                session_id,
                &[Token {
                    text: "Original evidence".into(),
                    start_ms: 0,
                    end_ms: 1_000,
                    is_final: true,
                    language: "en".into(),
                    speaker: None,
                    confidence: 1.0,
                    translation_status: vt_model::TranslationStatus::None,
                }],
            )
            .unwrap();
        assert!(core
            .repair_session_transcript_projection(session_id.into())
            .unwrap());

        let async_tab = core
            .list_notebook_tabs(target.id)
            .unwrap()
            .into_iter()
            .find(|tab| tab.builtin_kind == BuiltinNotebookTab::AsyncTranscript.as_str())
            .unwrap();
        let content = core.editor_bridge.get_content(&async_tab.doc_id).unwrap();
        let edit_pos = content.find("Original evidence").unwrap();
        core.editor_bridge
            .apply(
                &async_tab.doc_id,
                EditOp::Delete {
                    pos: edit_pos,
                    len: "Original evidence".chars().count(),
                },
            )
            .unwrap();
        core.editor_bridge
            .apply(
                &async_tab.doc_id,
                EditOp::Insert {
                    pos: edit_pos,
                    text: "Edited evidence".into(),
                },
            )
            .unwrap();

        assert!(core
            .repair_session_transcript_projection(session_id.into())
            .unwrap());
        let repaired = core.editor_bridge.get_content(&async_tab.doc_id).unwrap();
        assert!(repaired.contains("Edited evidence"));
        assert!(!repaired.contains("Original evidence"));
    }

    #[test]
    fn transcript_repair_refuses_a_session_with_a_durable_purge_tombstone() {
        let (_temp, core) = setup();
        let target = core.create_notebook(Some("Purge race".into())).unwrap();
        let session_id = "legacy-being-purged";
        core.session_store
            .insert_session(&vt_store::SessionRecord {
                id: session_id.into(),
                title: "Purging interview".into(),
                session_type: "recording".into(),
                status: "completed".into(),
                duration_ms: 1_000,
                created_at: "2024-01-02 03:04:05".into(),
                deleted_at: None,
            })
            .unwrap();
        core.session_meta
            .set_tokens(
                session_id,
                &[Token {
                    text: "must not return".into(),
                    start_ms: 0,
                    end_ms: 1_000,
                    is_final: true,
                    language: "en".into(),
                    speaker: None,
                    confidence: 1.0,
                    translation_status: vt_model::TranslationStatus::None,
                }],
            )
            .unwrap();
        core.assign_orphan_session_to_notebook(session_id.into(), target.id.clone())
            .unwrap();
        let async_tab = core
            .list_notebook_tabs(target.id)
            .unwrap()
            .into_iter()
            .find(|tab| tab.builtin_kind == BuiltinNotebookTab::AsyncTranscript.as_str())
            .unwrap();
        let content_len = core
            .editor_bridge
            .get_content(&async_tab.doc_id)
            .unwrap()
            .chars()
            .count();
        core.editor_bridge
            .apply(
                &async_tab.doc_id,
                EditOp::Delete {
                    pos: 0,
                    len: content_len,
                },
            )
            .unwrap();
        core.notebook_capture_store
            .begin_session_purge(session_id)
            .unwrap();

        assert!(matches!(
            core.repair_session_transcript_projection(session_id.into()),
            Err(CoreError::ValidationFailed { .. })
        ));
        assert!(core
            .editor_bridge
            .get_content(&async_tab.doc_id)
            .unwrap()
            .is_empty());
    }

    #[test]
    fn quick_capture_notebook_is_a_stable_core_owned_destination() {
        let (_temp, core) = setup();

        let first = core.get_quick_capture_notebook().unwrap();
        let same_visible_title = core
            .create_notebook(Some(DEFAULT_NOTEBOOK_TITLE.to_string()))
            .unwrap();
        let second = core.get_quick_capture_notebook().unwrap();

        assert_eq!(first.id, second.id);
        assert_ne!(first.id, same_visible_title.id);
        assert_eq!(first.title, DEFAULT_NOTEBOOK_TITLE);
        assert!(first.deleted_at.is_none());
        assert!(core
            .list_notebooks()
            .unwrap()
            .iter()
            .any(|notebook| notebook.id == same_visible_title.id));
        assert!(matches!(
            core.create_notebook(Some(QUICK_CAPTURE_NOTEBOOK_INTERNAL_TITLE.to_string())),
            Err(CoreError::ValidationFailed { .. })
        ));
    }

    #[test]
    fn default_notebook_import_creates_completed_local_run_without_task() {
        let (_temp, core) = setup();
        let notebook = core.create_notebook(Some("Local import".into())).unwrap();
        let profile = core
            .notebook_capture_store
            .get_or_create_profile(&notebook.id)
            .unwrap();

        let imported = core
            .import_audio_into_notebook(fixture_wav(), notebook.id.clone())
            .unwrap();
        let run = core
            .notebook_capture_store
            .get_run_for_session(&imported.session_id)
            .unwrap()
            .expect("every imported session has one durable run");

        assert_eq!(run.notebook_id, notebook.id);
        assert_eq!(run.capture_state, CaptureState::Completed);
        assert_eq!(run.remote_health, RemoteHealth::Off);
        assert_eq!(run.projection_state, ProjectionState::Ready);
        assert_eq!(run.async_task_state, AsyncTaskState::None);
        assert!(run.audio_journal_path.is_none());
        assert!(run
            .audio_path
            .as_deref()
            .is_some_and(|path| { path.ends_with(".enc") && std::path::Path::new(path).exists() }));
        assert!(run
            .audio_key_ref
            .as_deref()
            .is_some_and(|key| core.key_store.key_exists(key)));
        assert_eq!(run.sample_rate, Some(imported.sample_rate));
        assert_eq!(run.channels, Some(imported.channels));
        assert!(run.captured_frames > 0);
        assert_eq!(
            serde_json::from_str::<NotebookCaptureProfile>(&run.profile_snapshot_json).unwrap(),
            profile
        );
        assert_eq!(
            core.session_meta
                .get_meta(&imported.session_id)
                .unwrap()
                .privacy_level
                .as_deref(),
            Some(profile.privacy_level.as_str())
        );
        assert!(core.list_tasks(None).unwrap().is_empty());
    }

    #[test]
    fn notebook_import_uses_profile_privacy_snapshot_without_enqueuing_async_work() {
        let (_temp, core) = setup();
        let notebook = core.create_notebook(Some("Private import".into())).unwrap();
        let profile = set_profile_privacy(&core, &notebook.id, "high");

        let imported = core
            .import_audio_into_notebook(fixture_wav(), notebook.id)
            .unwrap();
        let run = core
            .notebook_capture_store
            .get_run_for_session(&imported.session_id)
            .unwrap()
            .unwrap();

        assert_eq!(run.async_task_state, AsyncTaskState::None);
        assert_eq!(
            serde_json::from_str::<NotebookCaptureProfile>(&run.profile_snapshot_json).unwrap(),
            profile
        );
        assert_eq!(
            core.session_meta
                .get_meta(&imported.session_id)
                .unwrap()
                .privacy_level
                .as_deref(),
            Some("high")
        );
        assert!(core.list_tasks(None).unwrap().is_empty());
    }

    #[test]
    fn failed_import_privacy_snapshot_permanently_rolls_back_session_and_audio() {
        let (temp, core) = setup();
        let notebook = core
            .create_notebook(Some("Private rollback import".into()))
            .unwrap();
        set_profile_privacy(&core, &notebook.id, "high");
        let connection = rusqlite::Connection::open(temp.path().join("zutalk.db")).unwrap();
        connection
            .execute_batch(
                "CREATE TRIGGER fail_notebook_import_privacy_snapshot
                 BEFORE UPDATE OF privacy_level ON session_meta
                 WHEN NEW.privacy_level = 'high'
                 BEGIN
                   SELECT RAISE(ABORT, 'forced Notebook privacy snapshot failure');
                 END;",
            )
            .unwrap();

        let result = core.import_audio_into_notebook(fixture_wav(), notebook.id.clone());

        assert!(result.is_err());
        assert_eq!(
            core.query_sessions(None, None, None, None, None)
                .unwrap()
                .total_count,
            0
        );
        assert!(core.list_notebook_sessions(notebook.id).unwrap().is_empty());
        assert!(core.list_tasks(None).unwrap().is_empty());
        let run_count: i64 = connection
            .query_row("SELECT COUNT(*) FROM notebook_capture_runs", [], |row| {
                row.get(0)
            })
            .unwrap();
        assert_eq!(run_count, 0);
        let encrypted_files = std::fs::read_dir(temp.path())
            .unwrap()
            .filter_map(Result::ok)
            .filter(|entry| entry.path().extension().is_some_and(|ext| ext == "enc"))
            .count();
        assert_eq!(encrypted_files, 0);
    }

    #[test]
    fn failed_import_run_insert_permanently_rolls_back_session_link_and_audio() {
        let (temp, core) = setup();
        let notebook = core
            .create_notebook(Some("Rollback import".into()))
            .unwrap();
        let connection = rusqlite::Connection::open(temp.path().join("zutalk.db")).unwrap();
        connection
            .execute_batch(
                "CREATE TRIGGER fail_import_run
                 BEFORE INSERT ON notebook_capture_runs
                 BEGIN
                   SELECT RAISE(ABORT, 'forced import run failure');
                 END;",
            )
            .unwrap();

        let result = core.import_audio_into_notebook(fixture_wav(), notebook.id.clone());

        assert!(result.is_err());
        assert_eq!(
            core.query_sessions(None, None, None, None, None)
                .unwrap()
                .total_count,
            0
        );
        assert!(core.list_notebook_sessions(notebook.id).unwrap().is_empty());
        assert!(core.list_tasks(None).unwrap().is_empty());
        let run_count: i64 = connection
            .query_row("SELECT COUNT(*) FROM notebook_capture_runs", [], |row| {
                row.get(0)
            })
            .unwrap();
        assert_eq!(run_count, 0);
        let encrypted_files = std::fs::read_dir(temp.path())
            .unwrap()
            .filter_map(Result::ok)
            .filter(|entry| entry.path().extension().is_some_and(|ext| ext == "enc"))
            .count();
        assert_eq!(encrypted_files, 0);
    }
}
