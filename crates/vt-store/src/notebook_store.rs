use rusqlite::{params, Connection, OptionalExtension};
use std::path::Path;
use std::sync::{Arc, Mutex};
use thiserror::Error;

/// The only durable Notebook tabs in the MVP.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BuiltinNotebookTab {
    RealtimeTranscript,
    AsyncTranscript,
    ManualNote,
}

impl BuiltinNotebookTab {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::RealtimeTranscript => "realtime_transcript",
            Self::AsyncTranscript => "async_transcript",
            Self::ManualNote => "manual_note",
        }
    }

    pub fn default_title(&self) -> &'static str {
        match self {
            Self::RealtimeTranscript => "实时转录",
            Self::AsyncTranscript => "异步转录",
            Self::ManualNote => "手写笔记",
        }
    }

    fn from_str(value: &str) -> Option<Self> {
        match value {
            "realtime_transcript" => Some(Self::RealtimeTranscript),
            "async_transcript" => Some(Self::AsyncTranscript),
            "manual_note" => Some(Self::ManualNote),
            _ => None,
        }
    }

    fn bootstrap_order() -> [Self; 3] {
        [
            Self::RealtimeTranscript,
            Self::AsyncTranscript,
            Self::ManualNote,
        ]
    }
}

#[derive(Debug, Clone)]
pub struct NotebookRecord {
    pub id: String,
    pub title: String,
    pub created_at: String,
    pub updated_at: String,
    pub deleted_at: Option<String>,
}

#[derive(Debug, Clone)]
pub struct NotebookTabRecord {
    pub id: String,
    pub notebook_id: String,
    pub builtin_kind: BuiltinNotebookTab,
    pub title: String,
    pub doc_id: String,
    pub position: i64,
    pub created_at: String,
    pub updated_at: String,
    pub deleted_at: Option<String>,
}

#[derive(Debug, Clone)]
pub struct NotebookSessionProjectionRecord {
    pub id: String,
    pub notebook_id: String,
    pub tab_id: String,
    pub session_id: String,
    pub section_title: Option<String>,
    pub created_at: String,
    pub updated_at: String,
    pub deleted_at: Option<String>,
}

#[derive(Debug, Clone)]
pub struct NotebookSessionLinkRecord {
    pub notebook_id: String,
    pub session_id: String,
    pub created_at: String,
}

#[derive(Clone)]
pub struct NotebookStore {
    conn: Arc<Mutex<Connection>>,
}

impl NotebookStore {
    pub fn new(db_path: &Path) -> Result<Self, NotebookStoreError> {
        let conn = Connection::open(db_path).map_err(NotebookStoreError::Sqlite)?;
        crate::migration::run_migrations(&conn).map_err(NotebookStoreError::Sqlite)?;
        Ok(Self {
            conn: Arc::new(Mutex::new(conn)),
        })
    }

    pub fn create_notebook(
        &self,
        title: Option<&str>,
    ) -> Result<NotebookRecord, NotebookStoreError> {
        let now = chrono::Utc::now().to_rfc3339();
        let title = title.unwrap_or("Untitled Notebook").trim();
        let notebook = NotebookRecord {
            id: uuid::Uuid::new_v4().to_string(),
            title: if title.is_empty() {
                "Untitled Notebook".to_string()
            } else {
                title.to_string()
            },
            created_at: now.clone(),
            updated_at: now.clone(),
            deleted_at: None,
        };

        let mut conn = self.conn.lock().unwrap();
        let tx = conn.transaction()?;
        tx.execute(
            "INSERT INTO notebooks (id, title, created_at, updated_at)
             VALUES (?1, ?2, ?3, ?3)",
            params![notebook.id, notebook.title, notebook.created_at],
        )?;
        for (position, builtin) in BuiltinNotebookTab::bootstrap_order()
            .into_iter()
            .enumerate()
        {
            self.insert_builtin_tab_tx(&tx, &notebook.id, builtin, position as i64, &now)?;
        }

        tx.commit()?;
        Ok(notebook)
    }

    pub fn get_notebook(
        &self,
        notebook_id: &str,
    ) -> Result<Option<NotebookRecord>, NotebookStoreError> {
        let conn = self.conn.lock().unwrap();
        Ok(conn
            .query_row(
                "SELECT id, title, created_at, updated_at, deleted_at
                 FROM notebooks WHERE id = ?1",
                params![notebook_id],
                Self::row_to_notebook,
            )
            .optional()?)
    }

    pub fn list_notebooks(&self) -> Result<Vec<NotebookRecord>, NotebookStoreError> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(
            "SELECT id, title, created_at, updated_at, deleted_at
             FROM notebooks
             WHERE deleted_at IS NULL
             ORDER BY updated_at DESC, created_at DESC",
        )?;
        let notebooks = stmt
            .query_map([], Self::row_to_notebook)?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(notebooks)
    }

    pub fn list_tabs(
        &self,
        notebook_id: &str,
    ) -> Result<Vec<NotebookTabRecord>, NotebookStoreError> {
        self.ensure_notebook_exists(notebook_id)?;
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(
            "SELECT id, notebook_id, builtin_kind, title, doc_id, position,
                    created_at, updated_at, deleted_at
             FROM notebook_tabs
             WHERE notebook_id = ?1 AND deleted_at IS NULL
             ORDER BY position ASC, created_at ASC",
        )?;
        let tabs = stmt
            .query_map(params![notebook_id], Self::row_to_tab)?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(tabs)
    }

    /// Resolve a product-facing tab identity to its authoritative builtin
    /// document. The editor boundary uses this instead of accepting a caller
    /// supplied `doc_id`.
    ///
    /// The exact three-tab invariant is checked on every resolution. A
    /// partially deleted or otherwise corrupt Notebook therefore fails closed
    /// instead of opening an unrelated/empty Loro document.
    pub fn resolve_builtin_tab(
        &self,
        notebook_id: &str,
        tab_id: &str,
    ) -> Result<NotebookTabRecord, NotebookStoreError> {
        let tabs = self.list_tabs(notebook_id)?;
        if tabs.len() != 3 {
            return Err(NotebookStoreError::Validation(format!(
                "notebook {notebook_id} must contain exactly three builtin tabs"
            )));
        }

        let mut has_realtime = false;
        let mut has_async = false;
        let mut has_manual = false;
        for tab in &tabs {
            let seen = match tab.builtin_kind {
                BuiltinNotebookTab::RealtimeTranscript => &mut has_realtime,
                BuiltinNotebookTab::AsyncTranscript => &mut has_async,
                BuiltinNotebookTab::ManualNote => &mut has_manual,
            };
            if *seen {
                return Err(NotebookStoreError::Validation(format!(
                    "notebook {notebook_id} has duplicate builtin tabs"
                )));
            }
            *seen = true;
        }
        if !(has_realtime && has_async && has_manual) {
            return Err(NotebookStoreError::Validation(format!(
                "notebook {notebook_id} builtin tab set is incomplete"
            )));
        }

        tabs.into_iter()
            .find(|tab| tab.id == tab_id)
            .ok_or_else(|| NotebookStoreError::NotFound(format!("notebook tab {tab_id}")))
    }

    pub fn ensure_session_projection(
        &self,
        notebook_id: &str,
        builtin_kind: BuiltinNotebookTab,
        session_id: &str,
        section_title: Option<&str>,
    ) -> Result<NotebookSessionProjectionRecord, NotebookStoreError> {
        self.ensure_notebook_exists(notebook_id)?;
        self.attach_session(notebook_id, session_id)?;
        let tab = self
            .get_builtin_tab(notebook_id, builtin_kind.clone())?
            .ok_or_else(|| {
                NotebookStoreError::Validation(format!(
                    "builtin tab {} missing for notebook {notebook_id}",
                    builtin_kind.as_str()
                ))
            })?;
        let title = section_title
            .map(str::trim)
            .filter(|value| !value.is_empty());
        let now = chrono::Utc::now().to_rfc3339();

        let mut conn = self.conn.lock().unwrap();
        let tx = conn.transaction()?;
        let existing = tx
            .query_row(
                "SELECT id, notebook_id, tab_id, session_id, section_title,
                        created_at, updated_at, deleted_at
                 FROM notebook_session_projections
                 WHERE tab_id = ?1 AND session_id = ?2",
                params![tab.id, session_id],
                Self::row_to_session_projection,
            )
            .optional()?;

        let projection = if let Some(existing) = existing {
            tx.execute(
                "UPDATE notebook_session_projections
                 SET section_title = ?1, updated_at = ?2, deleted_at = NULL
                 WHERE id = ?3",
                params![title, now, existing.id],
            )?;
            NotebookSessionProjectionRecord {
                id: existing.id,
                notebook_id: existing.notebook_id,
                tab_id: existing.tab_id,
                session_id: existing.session_id,
                section_title: title.map(str::to_string),
                created_at: existing.created_at,
                updated_at: now.clone(),
                deleted_at: None,
            }
        } else {
            let projection = NotebookSessionProjectionRecord {
                id: uuid::Uuid::new_v4().to_string(),
                notebook_id: notebook_id.to_string(),
                tab_id: tab.id,
                session_id: session_id.to_string(),
                section_title: title.map(str::to_string),
                created_at: now.clone(),
                updated_at: now.clone(),
                deleted_at: None,
            };
            tx.execute(
                "INSERT INTO notebook_session_projections
                 (id, notebook_id, tab_id, session_id, section_title, created_at, updated_at, deleted_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?6, NULL)",
                params![
                    projection.id,
                    projection.notebook_id,
                    projection.tab_id,
                    projection.session_id,
                    projection.section_title,
                    projection.created_at,
                ],
            )?;
            projection
        };

        self.touch_notebook_tx(&tx, notebook_id, &now)?;
        tx.commit()?;
        Ok(projection)
    }

    pub fn list_session_projections(
        &self,
        tab_id: &str,
    ) -> Result<Vec<NotebookSessionProjectionRecord>, NotebookStoreError> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(
            "SELECT id, notebook_id, tab_id, session_id, section_title,
                    created_at, updated_at, deleted_at
             FROM notebook_session_projections
             WHERE tab_id = ?1 AND deleted_at IS NULL
             ORDER BY created_at ASC, rowid ASC",
        )?;
        let projections = stmt
            .query_map(params![tab_id], Self::row_to_session_projection)?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(projections)
    }

    pub fn get_linked_notebook_id(
        &self,
        session_id: &str,
    ) -> Result<Option<String>, NotebookStoreError> {
        let conn = self.conn.lock().unwrap();
        Ok(conn
            .query_row(
                "SELECT notebook_id FROM notebook_sessions WHERE session_id = ?1",
                params![session_id],
                |row| row.get::<_, String>(0),
            )
            .optional()?)
    }

    pub fn list_linked_sessions(
        &self,
        notebook_id: &str,
    ) -> Result<Vec<NotebookSessionLinkRecord>, NotebookStoreError> {
        self.ensure_notebook_exists(notebook_id)?;
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(
            "SELECT notebook_id, session_id, created_at
             FROM notebook_sessions
             WHERE notebook_id = ?1
             ORDER BY created_at ASC, rowid ASC",
        )?;
        let sessions = stmt
            .query_map(params![notebook_id], |row| {
                Ok(NotebookSessionLinkRecord {
                    notebook_id: row.get(0)?,
                    session_id: row.get(1)?,
                    created_at: row.get(2)?,
                })
            })?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(sessions)
    }

    pub fn attach_session(
        &self,
        notebook_id: &str,
        session_id: &str,
    ) -> Result<(), NotebookStoreError> {
        self.ensure_notebook_exists(notebook_id)?;
        let mut conn = self.conn.lock().unwrap();
        let tx = conn.transaction()?;
        let existing = tx
            .query_row(
                "SELECT notebook_id FROM notebook_sessions WHERE session_id = ?1",
                params![session_id],
                |row| row.get::<_, String>(0),
            )
            .optional()?;
        if let Some(existing_notebook_id) = existing {
            if existing_notebook_id == notebook_id {
                return Ok(());
            }
            return Err(NotebookStoreError::SessionAlreadyLinked {
                session_id: session_id.to_string(),
                notebook_id: existing_notebook_id,
            });
        }

        let now = chrono::Utc::now().to_rfc3339();
        tx.execute(
            "INSERT INTO notebook_sessions (notebook_id, session_id, created_at)
             VALUES (?1, ?2, ?3)",
            params![notebook_id, session_id, now],
        )?;
        self.touch_notebook_tx(&tx, notebook_id, &now)?;
        tx.commit()?;
        Ok(())
    }

    fn ensure_notebook_exists(&self, notebook_id: &str) -> Result<(), NotebookStoreError> {
        if self.get_notebook(notebook_id)?.is_some() {
            Ok(())
        } else {
            Err(NotebookStoreError::NotFound(notebook_id.to_string()))
        }
    }

    fn get_builtin_tab(
        &self,
        notebook_id: &str,
        builtin_kind: BuiltinNotebookTab,
    ) -> Result<Option<NotebookTabRecord>, NotebookStoreError> {
        let conn = self.conn.lock().unwrap();
        Ok(conn
            .query_row(
                "SELECT id, notebook_id, builtin_kind, title, doc_id, position,
                        created_at, updated_at, deleted_at
                 FROM notebook_tabs
                 WHERE notebook_id = ?1 AND builtin_kind = ?2 AND deleted_at IS NULL",
                params![notebook_id, builtin_kind.as_str()],
                Self::row_to_tab,
            )
            .optional()?)
    }

    fn insert_builtin_tab_tx(
        &self,
        tx: &rusqlite::Transaction<'_>,
        notebook_id: &str,
        builtin: BuiltinNotebookTab,
        position: i64,
        now: &str,
    ) -> Result<NotebookTabRecord, NotebookStoreError> {
        let title = builtin.default_title().to_string();
        let tab = NotebookTabRecord {
            id: uuid::Uuid::new_v4().to_string(),
            notebook_id: notebook_id.to_string(),
            builtin_kind: builtin,
            title,
            doc_id: uuid::Uuid::new_v4().to_string(),
            position,
            created_at: now.to_string(),
            updated_at: now.to_string(),
            deleted_at: None,
        };
        tx.execute(
            "INSERT INTO notebook_tabs
             (id, notebook_id, builtin_kind, title, doc_id, position, created_at, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?7)",
            params![
                tab.id,
                tab.notebook_id,
                tab.builtin_kind.as_str(),
                tab.title,
                tab.doc_id,
                tab.position,
                tab.created_at,
            ],
        )?;
        Ok(tab)
    }

    fn touch_notebook_tx(
        &self,
        tx: &rusqlite::Transaction<'_>,
        notebook_id: &str,
        now: &str,
    ) -> Result<(), NotebookStoreError> {
        tx.execute(
            "UPDATE notebooks SET updated_at = ?1 WHERE id = ?2",
            params![now, notebook_id],
        )?;
        Ok(())
    }

    fn row_to_notebook(row: &rusqlite::Row<'_>) -> rusqlite::Result<NotebookRecord> {
        Ok(NotebookRecord {
            id: row.get(0)?,
            title: row.get(1)?,
            created_at: row.get(2)?,
            updated_at: row.get(3)?,
            deleted_at: row.get(4)?,
        })
    }

    fn row_to_tab(row: &rusqlite::Row<'_>) -> rusqlite::Result<NotebookTabRecord> {
        let raw_kind = row.get::<_, String>(2)?;
        let builtin_kind = BuiltinNotebookTab::from_str(&raw_kind).ok_or_else(|| {
            rusqlite::Error::FromSqlConversionFailure(
                2,
                rusqlite::types::Type::Text,
                format!("invalid builtin notebook tab kind: {raw_kind}").into(),
            )
        })?;
        Ok(NotebookTabRecord {
            id: row.get(0)?,
            notebook_id: row.get(1)?,
            builtin_kind,
            title: row.get(3)?,
            doc_id: row.get(4)?,
            position: row.get(5)?,
            created_at: row.get(6)?,
            updated_at: row.get(7)?,
            deleted_at: row.get(8)?,
        })
    }

    fn row_to_session_projection(
        row: &rusqlite::Row<'_>,
    ) -> rusqlite::Result<NotebookSessionProjectionRecord> {
        Ok(NotebookSessionProjectionRecord {
            id: row.get(0)?,
            notebook_id: row.get(1)?,
            tab_id: row.get(2)?,
            session_id: row.get(3)?,
            section_title: row.get(4)?,
            created_at: row.get(5)?,
            updated_at: row.get(6)?,
            deleted_at: row.get(7)?,
        })
    }
}

#[derive(Debug, Error)]
pub enum NotebookStoreError {
    #[error("sqlite error: {0}")]
    Sqlite(#[from] rusqlite::Error),

    #[error("record not found: {0}")]
    NotFound(String),

    #[error("session {session_id} already linked to notebook {notebook_id}")]
    SessionAlreadyLinked {
        session_id: String,
        notebook_id: String,
    },

    #[error("validation failed: {0}")]
    Validation(String),
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    #[test]
    fn local_notebook_has_exactly_three_builtin_tabs() {
        let temp = TempDir::new().unwrap();
        let store = NotebookStore::new(&temp.path().join("notebook.db")).unwrap();
        let notebook = store.create_notebook(Some("Field Notes")).unwrap();

        let tabs = store.list_tabs(&notebook.id).unwrap();
        assert_eq!(tabs.len(), 3);
        assert_eq!(
            tabs.into_iter()
                .map(|tab| tab.builtin_kind)
                .collect::<Vec<_>>(),
            vec![
                BuiltinNotebookTab::RealtimeTranscript,
                BuiltinNotebookTab::AsyncTranscript,
                BuiltinNotebookTab::ManualNote,
            ]
        );
    }

    #[test]
    fn builtin_tab_resolution_is_scoped_to_its_notebook() {
        let temp = TempDir::new().unwrap();
        let store = NotebookStore::new(&temp.path().join("notebook.db")).unwrap();
        let first = store.create_notebook(Some("First")).unwrap();
        let second = store.create_notebook(Some("Second")).unwrap();
        let first_tab = store.list_tabs(&first.id).unwrap().remove(0);
        let second_tab = store.list_tabs(&second.id).unwrap().remove(0);

        let resolved = store.resolve_builtin_tab(&first.id, &first_tab.id).unwrap();
        assert_eq!(resolved.doc_id, first_tab.doc_id);
        assert!(matches!(
            store.resolve_builtin_tab(&first.id, &second_tab.id),
            Err(NotebookStoreError::NotFound(_))
        ));
        assert!(matches!(
            store.resolve_builtin_tab(&first.id, &first_tab.doc_id),
            Err(NotebookStoreError::NotFound(_))
        ));
    }
}
