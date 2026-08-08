//! Notebook FFI API for the single-owner Notebook capture architecture.

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use vt_model::Token;
use vt_store::{
    AsyncProjectionState, BuiltinNotebookTab, EditOp, NotebookCaptureStore, NotebookRecord,
    NotebookSessionLinkRecord, NotebookSessionProjectionRecord, NotebookStore, NotebookTabRecord,
    SessionMetaStore, SessionQuery, SessionQueryStore,
};

use crate::{CoreError, ZulangueCore};

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
        let tokens = session_meta.get_tokens(session_id).unwrap_or_default();
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
impl ZulangueCore {
    pub fn create_notebook(&self, title: Option<String>) -> Result<FfiNotebook, CoreError> {
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
        Ok(notebooks.into_iter().map(Into::into).collect())
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

impl ZulangueCore {
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

impl ZulangueCore {
    pub(crate) fn notebook_transcript_projector(&self) -> NotebookTranscriptProjector {
        NotebookTranscriptProjector::new(
            self.data_dir.clone(),
            self.data_dir.join("zulangue.db"),
            self.notebook_store.clone(),
            self.editor_bridge.clone(),
            self.editor_callbacks.clone(),
        )
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
    segments: &[FfiNotebookTranscriptSegment],
) -> Result<String, CoreError> {
    let _mutation_guard = crate::editor_api::editor_document_mutation_guard();
    let projection = notebook_store
        .ensure_session_projection(notebook_id, builtin_kind.clone(), session_id, section_title)
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
        .query_sessions(&SessionQuery {
            limit: Some(1000),
            ..Default::default()
        })
        .ok()
        .and_then(|result| {
            result
                .sessions
                .into_iter()
                .find(|session| session.id == session_id)
        })
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
) -> Vec<FfiNotebookTranscriptSegment> {
    const GAP_MS: u64 = 2000;
    let mut segments: Vec<FfiNotebookTranscriptSegment> = Vec::new();
    let mut last_end_ms = 0u64;

    for token in tokens {
        let needs_new_segment = match segments.last() {
            None => true,
            Some(_) => token.start_ms.saturating_sub(last_end_ms) > GAP_MS,
        };

        if needs_new_segment {
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

fn render_transcript_section(
    session_id: &str,
    section_title: Option<&str>,
    segments: &[FfiNotebookTranscriptSegment],
    include_leading_separator: bool,
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
        text.push_str(&format!(
            "[{}]\n{}",
            format_timestamp(segment.timestamp_ms),
            segment.text
        ));
        let block_len = text.chars().count() - block_start;
        if block_len > 0 {
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
    }

    let section_len = text.chars().count() - section_start;
    if section_len > 0 {
        marks.push(RenderedMark {
            pos: section_start,
            len: section_len,
            key: "session_id".to_string(),
            value_json: json_string(session_id),
        });
    }

    RenderedSection { text, marks }
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

    fn setup() -> (TempDir, ZulangueCore) {
        let temp = TempDir::new().unwrap();
        let core = ZulangueCore::new_for_test(temp.path().to_str().unwrap().to_string()).unwrap();
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

    fn set_profile_privacy(
        core: &ZulangueCore,
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
        let connection = rusqlite::Connection::open(temp.path().join("zulangue.db")).unwrap();
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
        let connection = rusqlite::Connection::open(temp.path().join("zulangue.db")).unwrap();
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
