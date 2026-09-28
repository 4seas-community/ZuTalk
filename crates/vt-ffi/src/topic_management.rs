//! Naming recordings and topics, and deleting a topic without losing what
//! was recorded in it.
//!
//! Neither could be renamed, and a topic could not be deleted at all — a
//! mistyped name or an abandoned topic stayed forever.

use crate::notebook_api::FfiNotebook;
use crate::notebook_api::QUICK_CAPTURE_NOTEBOOK_INTERNAL_TITLE;
use crate::notebook_capture_api::store_error;
use crate::share_api::SHARED_INBOX_NOTEBOOK_INTERNAL_TITLE;
use crate::{CoreError, ZuTalkCore};

/// Long enough for any real title, short enough to stay one line.
const MAX_TITLE_CHARS: usize = 200;

fn is_internal_title(title: &str) -> bool {
    title == QUICK_CAPTURE_NOTEBOOK_INTERNAL_TITLE || title == SHARED_INBOX_NOTEBOOK_INTERNAL_TITLE
}

fn checked_title(title: &str) -> Result<String, CoreError> {
    let title = title.trim();
    if title.chars().count() > MAX_TITLE_CHARS {
        return Err(CoreError::ValidationFailed {
            message: format!("title is longer than {MAX_TITLE_CHARS} characters"),
        });
    }
    Ok(title.to_string())
}

impl ZuTalkCore {
    fn user_topic(&self, notebook_id: &str) -> Result<vt_store::NotebookRecord, CoreError> {
        let notebook = self
            .notebook_store
            .get_notebook(notebook_id)
            .map_err(store_error)?
            .filter(|notebook| notebook.deleted_at.is_none())
            .ok_or_else(|| CoreError::NotFound {
                message: format!("topic not found: {notebook_id}"),
            })?;
        if is_internal_title(&notebook.title) {
            return Err(CoreError::ValidationFailed {
                message: "this collection is not a topic and cannot be changed".to_string(),
            });
        }
        Ok(notebook)
    }
}

#[uniffi::export]
impl ZuTalkCore {
    /// Names a recording. An empty title makes it untitled again, and lists
    /// go back to showing its first words.
    pub fn rename_session(&self, session_id: String, title: String) -> Result<(), CoreError> {
        let title = checked_title(&title)?;
        self.session_store
            .set_title(&session_id, &title)
            .map_err(|error| match error {
                vt_store::SessionQueryError::NotFound(_) => CoreError::NotFound {
                    message: format!("recording not found: {session_id}"),
                },
                other => CoreError::InternalError {
                    message: other.to_string(),
                },
            })
    }

    pub fn rename_notebook(
        &self,
        notebook_id: String,
        title: String,
    ) -> Result<FfiNotebook, CoreError> {
        let title = checked_title(&title)?;
        if title.is_empty() || is_internal_title(&title) {
            return Err(CoreError::ValidationFailed {
                message: "a topic needs a name".to_string(),
            });
        }
        self.user_topic(&notebook_id)?;
        self.notebook_store
            .rename_notebook(&notebook_id, &title)
            .map(Into::into)
            .map_err(store_error)
    }

    /// Deletes a topic. Its recordings are kept: each moves, with its
    /// transcripts and notes, to the recordings that belong to no topic — the
    /// same place a recording started from Home goes. Only the topic's own
    /// notes go with it. Refused while one of its recordings is recording.
    ///
    /// Returns how many recordings were moved out.
    pub fn delete_notebook(&self, notebook_id: String) -> Result<u32, CoreError> {
        self.user_topic(&notebook_id)?;
        let unfiled = self.get_quick_capture_notebook()?.id;
        let linked = self
            .notebook_store
            .list_linked_sessions(&notebook_id)
            .map_err(store_error)?;
        for link in &linked {
            self.move_session_to_notebook_inner(&link.session_id, &unfiled)?;
        }
        self.notebook_store
            .soft_delete_empty_notebook(&notebook_id)
            .map_err(store_error)?;
        Ok(linked.len() as u32)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    fn core() -> (TempDir, ZuTalkCore) {
        let tmp = TempDir::new().unwrap();
        let core = ZuTalkCore::new(tmp.path().to_string_lossy().into_owned()).unwrap();
        (tmp, core)
    }

    fn filed_recording(core: &ZuTalkCore, id: &str, notebook_id: &str) {
        core.session_store
            .insert_session(&vt_store::SessionRecord {
                id: id.into(),
                title: String::new(),
                session_type: "recording".into(),
                status: "completed".into(),
                duration_ms: 1_000,
                created_at: chrono::Utc::now().format("%Y-%m-%d %H:%M:%S").to_string(),
                deleted_at: None,
            })
            .unwrap();
        core.assign_orphan_session_to_notebook(id.into(), notebook_id.into())
            .unwrap();
    }

    #[test]
    fn a_recording_can_be_named_and_unnamed() {
        let (_tmp, core) = core();
        let topic = core.create_notebook(Some("周会".into())).unwrap();
        filed_recording(&core, "r1", &topic.id);

        core.rename_session("r1".into(), "  预算讨论  ".into())
            .unwrap();
        assert_eq!(core.get_session("r1".into()).unwrap().title, "预算讨论");
        core.rename_session("r1".into(), "".into()).unwrap();
        assert_eq!(core.get_session("r1".into()).unwrap().title, "");
        assert!(matches!(
            core.rename_session("missing".into(), "x".into()),
            Err(CoreError::NotFound { .. })
        ));
    }

    #[test]
    fn a_topic_can_be_renamed_but_not_to_nothing() {
        let (_tmp, core) = core();
        let topic = core.create_notebook(Some("周会".into())).unwrap();

        let renamed = core
            .rename_notebook(topic.id.clone(), " 产品周会 ".into())
            .unwrap();
        assert_eq!(renamed.title, "产品周会");
        assert!(core
            .rename_notebook(topic.id.clone(), "   ".into())
            .is_err());
        assert!(core
            .rename_notebook(topic.id, QUICK_CAPTURE_NOTEBOOK_INTERNAL_TITLE.into())
            .is_err());
    }

    #[test]
    fn the_unfiled_collection_is_not_a_topic_to_rename_or_delete() {
        let (_tmp, core) = core();
        let unfiled = core.get_quick_capture_notebook().unwrap();
        assert!(core
            .rename_notebook(unfiled.id.clone(), "Mine".into())
            .is_err());
        assert!(core.delete_notebook(unfiled.id).is_err());
    }

    #[test]
    fn deleting_a_topic_keeps_its_recordings_as_unfiled() {
        let (_tmp, core) = core();
        let topic = core.create_notebook(Some("旧项目".into())).unwrap();
        filed_recording(&core, "r1", &topic.id);
        filed_recording(&core, "r2", &topic.id);
        let unfiled = core.get_quick_capture_notebook().unwrap();

        assert_eq!(core.delete_notebook(topic.id.clone()).unwrap(), 2);

        assert!(core
            .list_notebooks()
            .unwrap()
            .iter()
            .all(|notebook| notebook.id != topic.id));
        let mut moved = core
            .list_notebook_sessions(unfiled.id)
            .unwrap()
            .into_iter()
            .map(|link| link.session_id)
            .collect::<Vec<_>>();
        moved.sort();
        assert_eq!(moved, ["r1", "r2"]);
        assert!(
            core.get_session("r1".into()).is_ok(),
            "the recording itself remains"
        );
    }
}
