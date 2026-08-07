use rusqlite::{params, Connection, OptionalExtension, TransactionBehavior};
use serde::{Deserialize, Serialize};
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use thiserror::Error;

/// The only durable Notebook tabs in the MVP.
///
/// The serialized form matches [`BuiltinNotebookTab::as_str`], so a durable
/// move plan stays readable by the same names the database column uses.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
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

/// One builtin tab's share of a session move: the document the section leaves
/// and the document it joins.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionMoveTarget {
    pub builtin_kind: BuiltinNotebookTab,
    pub source_tab_id: String,
    pub source_doc_id: String,
    pub target_tab_id: String,
    pub target_doc_id: String,
    /// Every session in the target tab recorded after the moved one, earliest
    /// first. The moved content lands in front of the first of these that
    /// actually has content in this document — a section can be empty (an async
    /// transcript that was never produced still owns a projection row), so a
    /// single anchor would sometimes be unresolvable. Empty means the moved
    /// session is the most recent one and its content appends.
    pub later_session_ids: Vec<String>,
}

/// A validated session move. Building the plan proves the move is legal;
/// [`NotebookStore::commit_session_move`] re-proves it under the write lock
/// before flipping any pointer.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionMovePlan {
    pub session_id: String,
    pub source_notebook_id: String,
    pub target_notebook_id: String,
    /// `session_records.created_at` — the recording time the ordering uses.
    pub recorded_at: String,
    pub targets: Vec<SessionMoveTarget>,
}

#[derive(Clone)]
pub struct NotebookStore {
    conn: Arc<Mutex<Connection>>,
}

impl NotebookStore {
    pub fn new(db_path: &Path) -> Result<Self, NotebookStoreError> {
        let conn = Connection::open(db_path).map_err(NotebookStoreError::Sqlite)?;
        // Realtime capture and Loro projection use independent connections to
        // the same main database. A short busy wait turns momentary
        // single-writer overlap into bounded backpressure instead of a
        // user-visible projection/capture failure.
        conn.busy_timeout(Duration::from_secs(1))
            .map_err(NotebookStoreError::Sqlite)?;
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
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
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

    /// Atomically links a recording and creates its three stable resource
    /// projections. A failure cannot leave a partial link or projection set.
    pub fn attach_session_with_builtin_projections(
        &self,
        notebook_id: &str,
        session_id: &str,
    ) -> Result<(), NotebookStoreError> {
        let mut conn = self.conn.lock().unwrap();
        let tx = conn.transaction()?;
        let notebook_exists = tx
            .query_row(
                "SELECT 1 FROM notebooks WHERE id = ?1 AND deleted_at IS NULL",
                params![notebook_id],
                |_| Ok(()),
            )
            .optional()?
            .is_some();
        if !notebook_exists {
            return Err(NotebookStoreError::NotFound(notebook_id.to_string()));
        }

        let existing_notebook_id = tx
            .query_row(
                "SELECT notebook_id FROM notebook_sessions WHERE session_id = ?1",
                params![session_id],
                |row| row.get::<_, String>(0),
            )
            .optional()?;
        if let Some(existing_notebook_id) = existing_notebook_id.as_deref() {
            if existing_notebook_id != notebook_id {
                return Err(NotebookStoreError::SessionAlreadyLinked {
                    session_id: session_id.to_string(),
                    notebook_id: existing_notebook_id.to_string(),
                });
            }
        }

        let now = chrono::Utc::now().to_rfc3339();
        if existing_notebook_id.is_none() {
            tx.execute(
                "INSERT INTO notebook_sessions (notebook_id, session_id, created_at)
                 VALUES (?1, ?2, ?3)",
                params![notebook_id, session_id, now],
            )?;
        }

        let tabs = {
            let mut stmt = tx.prepare(
                "SELECT id, builtin_kind
                 FROM notebook_tabs
                 WHERE notebook_id = ?1 AND deleted_at IS NULL
                 ORDER BY position ASC, created_at ASC, id ASC",
            )?;
            let rows = stmt
                .query_map(params![notebook_id], |row| {
                    Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
                })?
                .collect::<Result<Vec<_>, _>>()?;
            rows
        };
        let expected = BuiltinNotebookTab::bootstrap_order();
        if tabs.len() != expected.len()
            || expected.iter().any(|kind| {
                tabs.iter()
                    .filter(|(_, raw_kind)| raw_kind == kind.as_str())
                    .count()
                    != 1
            })
        {
            return Err(NotebookStoreError::Validation(format!(
                "notebook {notebook_id} must contain exactly three builtin tabs"
            )));
        }

        for (tab_id, _) in tabs {
            tx.execute(
                "INSERT INTO notebook_session_projections
                 (id, notebook_id, tab_id, session_id, section_title,
                  created_at, updated_at, deleted_at)
                 VALUES (?1, ?2, ?3, ?4, NULL, ?5, ?5, NULL)
                 ON CONFLICT(tab_id, session_id) DO UPDATE SET
                     updated_at = excluded.updated_at,
                     deleted_at = NULL",
                params![
                    uuid::Uuid::new_v4().to_string(),
                    notebook_id,
                    tab_id,
                    session_id,
                    now,
                ],
            )?;
        }

        self.touch_notebook_tx(&tx, notebook_id, &now)?;
        tx.commit()?;
        Ok(())
    }

    /// Proves a session can move to `target_notebook_id` and resolves where its
    /// content lands in each of the target's three documents.
    ///
    /// A session owns four resources — realtime transcript, async transcript,
    /// manual note, and its audio — and all four follow it. Audio needs no plan
    /// entry: it lives in `audio/<session_id>/`, which no notebook owns.
    pub fn plan_session_move(
        &self,
        session_id: &str,
        target_notebook_id: &str,
    ) -> Result<SessionMovePlan, NotebookStoreError> {
        let conn = self.conn.lock().unwrap();
        Self::build_session_move_plan(&conn, session_id, target_notebook_id)
    }

    /// Flips the three durable pointers that say which Notebook owns a session:
    /// the catalogue link, the capture run, and the per-tab projection rows.
    ///
    /// The capture run matters as much as the link — the projection writers
    /// resolve their target tab through `notebook_capture_runs.notebook_id`,
    /// so a link that moved without its run would send new transcript content
    /// to the Notebook the session just left.
    ///
    /// The plan is re-derived under the write lock. A plan built before a
    /// concurrent capture start, purge, or notebook deletion is refused here
    /// rather than committed against changed facts.
    pub fn commit_session_move(&self, plan: &SessionMovePlan) -> Result<(), NotebookStoreError> {
        let mut conn = self.conn.lock().unwrap();
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let current =
            Self::build_session_move_plan_tx(&tx, &plan.session_id, &plan.target_notebook_id)?;
        if &current != plan {
            return Err(NotebookStoreError::Validation(format!(
                "session {} move plan is stale; rebuild it before committing",
                plan.session_id
            )));
        }

        let now = chrono::Utc::now().to_rfc3339();
        tx.execute(
            "UPDATE notebook_sessions SET notebook_id = ?1 WHERE session_id = ?2",
            params![plan.target_notebook_id, plan.session_id],
        )?;
        tx.execute(
            "UPDATE notebook_capture_runs SET notebook_id = ?1 WHERE session_id = ?2",
            params![plan.target_notebook_id, plan.session_id],
        )?;
        for target in &plan.targets {
            // section_title and created_at ride along: the title is the user's,
            // and created_at means "when this section appeared in this tab",
            // which a move does not reset. Recording time lives in
            // session_records and is never touched.
            tx.execute(
                "UPDATE notebook_session_projections
                 SET notebook_id = ?1, tab_id = ?2, updated_at = ?3
                 WHERE tab_id = ?4 AND session_id = ?5",
                params![
                    plan.target_notebook_id,
                    target.target_tab_id,
                    now,
                    target.source_tab_id,
                    plan.session_id,
                ],
            )?;
        }
        self.touch_notebook_tx(&tx, &plan.source_notebook_id, &now)?;
        self.touch_notebook_tx(&tx, &plan.target_notebook_id, &now)?;
        tx.commit()?;
        Ok(())
    }

    fn build_session_move_plan(
        conn: &Connection,
        session_id: &str,
        target_notebook_id: &str,
    ) -> Result<SessionMovePlan, NotebookStoreError> {
        let source_notebook_id = conn
            .query_row(
                "SELECT notebook_id FROM notebook_sessions WHERE session_id = ?1",
                params![session_id],
                |row| row.get::<_, String>(0),
            )
            .optional()?
            .ok_or_else(|| {
                NotebookStoreError::NotFound(format!("notebook link for session {session_id}"))
            })?;
        if source_notebook_id == target_notebook_id {
            return Err(NotebookStoreError::Validation(format!(
                "session {session_id} already belongs to notebook {target_notebook_id}"
            )));
        }
        for notebook_id in [source_notebook_id.as_str(), target_notebook_id] {
            let live = conn
                .query_row(
                    "SELECT 1 FROM notebooks WHERE id = ?1 AND deleted_at IS NULL",
                    params![notebook_id],
                    |_| Ok(()),
                )
                .optional()?
                .is_some();
            if !live {
                return Err(NotebookStoreError::NotFound(notebook_id.to_string()));
            }
        }

        // A capture still owns its audio journal and writes new utterances into
        // the document the run points at. Moving that pointer mid-capture would
        // split one recording across two Notebooks.
        if let Some(state) = conn
            .query_row(
                "SELECT capture_state FROM notebook_capture_runs WHERE session_id = ?1",
                params![session_id],
                |row| row.get::<_, String>(0),
            )
            .optional()?
        {
            if matches!(state.as_str(), "recording" | "paused" | "draining") {
                return Err(NotebookStoreError::SessionNotMovable {
                    session_id: session_id.to_string(),
                    reason: format!("capture is {state}"),
                });
            }
        }
        // A pending purge is already committed to destroying this session.
        if conn
            .query_row(
                "SELECT 1 FROM session_purge_jobs WHERE session_id = ?1",
                params![session_id],
                |_| Ok(()),
            )
            .optional()?
            .is_some()
        {
            return Err(NotebookStoreError::SessionNotMovable {
                session_id: session_id.to_string(),
                reason: "a permanent deletion is already in progress".to_string(),
            });
        }

        let recorded_at = conn
            .query_row(
                "SELECT created_at FROM session_records WHERE id = ?1",
                params![session_id],
                |row| row.get::<_, String>(0),
            )
            .optional()?
            .ok_or_else(|| NotebookStoreError::NotFound(format!("session record {session_id}")))?;

        let source_tabs = Self::builtin_tabs_by_kind_conn(conn, &source_notebook_id)?;
        let target_tabs = Self::builtin_tabs_by_kind_conn(conn, target_notebook_id)?;
        let mut targets = Vec::with_capacity(BuiltinNotebookTab::bootstrap_order().len());
        for builtin in BuiltinNotebookTab::bootstrap_order() {
            let source = source_tabs
                .iter()
                .find(|(kind, _, _)| kind == &builtin)
                .ok_or_else(|| {
                    NotebookStoreError::Validation(format!(
                        "notebook {source_notebook_id} is missing its {} tab",
                        builtin.as_str()
                    ))
                })?;
            let target = target_tabs
                .iter()
                .find(|(kind, _, _)| kind == &builtin)
                .ok_or_else(|| {
                    NotebookStoreError::Validation(format!(
                        "notebook {target_notebook_id} is missing its {} tab",
                        builtin.as_str()
                    ))
                })?;
            targets.push(SessionMoveTarget {
                builtin_kind: builtin,
                source_tab_id: source.1.clone(),
                source_doc_id: source.2.clone(),
                target_tab_id: target.1.clone(),
                target_doc_id: target.2.clone(),
                later_session_ids: Self::later_sections_conn(
                    conn,
                    &target.1,
                    session_id,
                    &recorded_at,
                )?,
            });
        }

        Ok(SessionMovePlan {
            session_id: session_id.to_string(),
            source_notebook_id,
            target_notebook_id: target_notebook_id.to_string(),
            recorded_at,
            targets,
        })
    }

    fn build_session_move_plan_tx(
        tx: &rusqlite::Transaction<'_>,
        session_id: &str,
        target_notebook_id: &str,
    ) -> Result<SessionMovePlan, NotebookStoreError> {
        Self::build_session_move_plan(tx, session_id, target_notebook_id)
    }

    /// The sections in `tab_id` recorded strictly after `recorded_at`, earliest
    /// first. Sections are ordered by when their session was recorded, so the
    /// first of these that has content is the anchor the moved content goes in
    /// front of.
    ///
    /// Recording times have one-second resolution, so two sessions can tie —
    /// several files imported together, most often. A tie is deliberately *not*
    /// counted as later: the arriving section joins the end of its own second
    /// rather than cutting in at a position decided by comparing random uuids.
    fn later_sections_conn(
        conn: &Connection,
        tab_id: &str,
        session_id: &str,
        recorded_at: &str,
    ) -> Result<Vec<String>, NotebookStoreError> {
        let mut stmt = conn.prepare(
            "SELECT p.session_id
             FROM notebook_session_projections p
             JOIN session_records s ON s.id = p.session_id
             WHERE p.tab_id = ?1
               AND p.deleted_at IS NULL
               AND p.session_id <> ?2
               AND s.created_at > ?3
             ORDER BY s.created_at ASC, p.session_id ASC",
        )?;
        let later = stmt
            .query_map(params![tab_id, session_id, recorded_at], |row| {
                row.get::<_, String>(0)
            })?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(later)
    }

    fn builtin_tabs_by_kind_conn(
        conn: &Connection,
        notebook_id: &str,
    ) -> Result<Vec<(BuiltinNotebookTab, String, String)>, NotebookStoreError> {
        let mut stmt = conn.prepare(
            "SELECT builtin_kind, id, doc_id
             FROM notebook_tabs
             WHERE notebook_id = ?1 AND deleted_at IS NULL
             ORDER BY position ASC, created_at ASC, id ASC",
        )?;
        let rows = stmt
            .query_map(params![notebook_id], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                ))
            })?
            .collect::<Result<Vec<_>, _>>()?;
        let mut tabs = Vec::with_capacity(rows.len());
        for (raw_kind, tab_id, doc_id) in rows {
            let kind = BuiltinNotebookTab::from_str(&raw_kind).ok_or_else(|| {
                NotebookStoreError::Validation(format!(
                    "notebook {notebook_id} has an unknown builtin tab kind {raw_kind}"
                ))
            })?;
            tabs.push((kind, tab_id, doc_id));
        }
        if tabs.len() != BuiltinNotebookTab::bootstrap_order().len() {
            return Err(NotebookStoreError::Validation(format!(
                "notebook {notebook_id} must contain exactly three builtin tabs"
            )));
        }
        Ok(tabs)
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

    #[error("session {session_id} cannot move right now: {reason}")]
    SessionNotMovable { session_id: String, reason: String },

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

    #[test]
    fn linking_with_builtin_projections_rolls_back_atomically() {
        let temp = TempDir::new().unwrap();
        let db_path = temp.path().join("notebook.db");
        let store = NotebookStore::new(&db_path).unwrap();
        let notebook = store.create_notebook(Some("Atomic resources")).unwrap();
        let connection = Connection::open(&db_path).unwrap();
        connection
            .execute_batch(
                "CREATE TRIGGER fail_second_resource_projection
                 BEFORE INSERT ON notebook_session_projections
                 WHEN (
                     SELECT COUNT(*) FROM notebook_session_projections
                     WHERE session_id = NEW.session_id
                 ) = 1
                 BEGIN
                   SELECT RAISE(ABORT, 'forced resource projection failure');
                 END;",
            )
            .unwrap();

        let result = store.attach_session_with_builtin_projections(&notebook.id, "session-atomic");

        assert!(result.is_err());
        assert!(store.list_linked_sessions(&notebook.id).unwrap().is_empty());
        for tab in store.list_tabs(&notebook.id).unwrap() {
            assert!(store.list_session_projections(&tab.id).unwrap().is_empty());
        }
    }

    /// Seeds a session that exists as a real catalogue row and capture run, so
    /// the move's ordering and liveness checks have something to read.
    fn seed_session(
        db_path: &std::path::Path,
        notebook_id: &str,
        session_id: &str,
        recorded_at: &str,
        capture_state: &str,
    ) {
        let connection = Connection::open(db_path).unwrap();
        connection
            .execute(
                "INSERT INTO session_records (id, title, session_type, status, created_at)
                 VALUES (?1, '', 'recording', 'completed', ?2)",
                params![session_id, recorded_at],
            )
            .unwrap();
        connection
            .execute(
                "INSERT INTO notebook_capture_runs (
                     id, notebook_id, session_id, profile_revision, profile_snapshot_json,
                     capture_state, created_at, updated_at
                 ) VALUES (?1, ?2, ?3, 0, '{}', ?4, ?5, ?5)",
                params![
                    format!("run-{session_id}"),
                    notebook_id,
                    session_id,
                    capture_state,
                    recorded_at
                ],
            )
            .unwrap();
    }

    fn linked_notebook_of(db_path: &std::path::Path, session_id: &str) -> String {
        Connection::open(db_path)
            .unwrap()
            .query_row(
                "SELECT notebook_id FROM notebook_sessions WHERE session_id = ?1",
                params![session_id],
                |row| row.get::<_, String>(0),
            )
            .unwrap()
    }

    fn run_notebook_of(db_path: &std::path::Path, session_id: &str) -> String {
        Connection::open(db_path)
            .unwrap()
            .query_row(
                "SELECT notebook_id FROM notebook_capture_runs WHERE session_id = ?1",
                params![session_id],
                |row| row.get::<_, String>(0),
            )
            .unwrap()
    }

    #[test]
    fn moving_a_session_carries_its_link_run_and_every_tab_projection() {
        let temp = TempDir::new().unwrap();
        let db_path = temp.path().join("notebook.db");
        let store = NotebookStore::new(&db_path).unwrap();
        let source = store.create_notebook(Some("Source")).unwrap();
        let target = store.create_notebook(Some("Target")).unwrap();
        seed_session(
            &db_path,
            &source.id,
            "session-a",
            "2026-03-01 09:00:00",
            "completed",
        );
        store
            .attach_session_with_builtin_projections(&source.id, "session-a")
            .unwrap();

        let plan = store.plan_session_move("session-a", &target.id).unwrap();
        store.commit_session_move(&plan).unwrap();

        assert_eq!(linked_notebook_of(&db_path, "session-a"), target.id);
        assert_eq!(
            run_notebook_of(&db_path, "session-a"),
            target.id,
            "the capture run must follow the link, or new content would be written back into the old notebook"
        );
        for tab in store.list_tabs(&source.id).unwrap() {
            assert!(
                store.list_session_projections(&tab.id).unwrap().is_empty(),
                "the source notebook must keep no section for a moved session"
            );
        }
        let moved = store
            .list_tabs(&target.id)
            .unwrap()
            .into_iter()
            .map(|tab| store.list_session_projections(&tab.id).unwrap())
            .collect::<Vec<_>>();
        assert_eq!(moved.len(), 3);
        for projections in moved {
            assert_eq!(projections.len(), 1);
            assert_eq!(projections[0].session_id, "session-a");
            assert_eq!(projections[0].notebook_id, target.id);
        }
        assert!(store.list_linked_sessions(&source.id).unwrap().is_empty());
        assert_eq!(store.list_linked_sessions(&target.id).unwrap().len(), 1);
    }

    #[test]
    fn a_moved_section_lands_in_recording_time_order_not_at_the_end() {
        let temp = TempDir::new().unwrap();
        let db_path = temp.path().join("notebook.db");
        let store = NotebookStore::new(&db_path).unwrap();
        let source = store.create_notebook(Some("Source")).unwrap();
        let target = store.create_notebook(Some("Target")).unwrap();
        // The target already holds a January and a March recording; the moved
        // session was recorded in February and belongs between them.
        seed_session(
            &db_path,
            &target.id,
            "january",
            "2026-01-05 10:00:00",
            "completed",
        );
        seed_session(
            &db_path,
            &target.id,
            "march",
            "2026-03-05 10:00:00",
            "completed",
        );
        store
            .attach_session_with_builtin_projections(&target.id, "january")
            .unwrap();
        store
            .attach_session_with_builtin_projections(&target.id, "march")
            .unwrap();
        seed_session(
            &db_path,
            &source.id,
            "february",
            "2026-02-05 10:00:00",
            "completed",
        );
        store
            .attach_session_with_builtin_projections(&source.id, "february")
            .unwrap();

        let plan = store.plan_session_move("february", &target.id).unwrap();

        assert_eq!(plan.recorded_at, "2026-02-05 10:00:00");
        assert_eq!(plan.targets.len(), 3);
        for target_plan in &plan.targets {
            assert_eq!(
                target_plan.later_session_ids,
                vec!["march".to_string()],
                "content must land in front of the next later recording"
            );
        }
    }

    #[test]
    fn the_most_recent_recording_appends_instead_of_anchoring() {
        let temp = TempDir::new().unwrap();
        let db_path = temp.path().join("notebook.db");
        let store = NotebookStore::new(&db_path).unwrap();
        let source = store.create_notebook(Some("Source")).unwrap();
        let target = store.create_notebook(Some("Target")).unwrap();
        seed_session(
            &db_path,
            &target.id,
            "january",
            "2026-01-05 10:00:00",
            "completed",
        );
        store
            .attach_session_with_builtin_projections(&target.id, "january")
            .unwrap();
        seed_session(
            &db_path,
            &source.id,
            "december",
            "2026-12-05 10:00:00",
            "completed",
        );
        store
            .attach_session_with_builtin_projections(&source.id, "december")
            .unwrap();

        let plan = store.plan_session_move("december", &target.id).unwrap();

        for target_plan in &plan.targets {
            assert!(target_plan.later_session_ids.is_empty());
        }
    }

    #[test]
    fn a_live_capture_and_a_pending_purge_both_refuse_the_move() {
        let temp = TempDir::new().unwrap();
        let db_path = temp.path().join("notebook.db");
        let store = NotebookStore::new(&db_path).unwrap();
        let source = store.create_notebook(Some("Source")).unwrap();
        let target = store.create_notebook(Some("Target")).unwrap();
        seed_session(
            &db_path,
            &source.id,
            "recording-now",
            "2026-03-01 09:00:00",
            "recording",
        );
        store
            .attach_session_with_builtin_projections(&source.id, "recording-now")
            .unwrap();

        assert!(matches!(
            store.plan_session_move("recording-now", &target.id),
            Err(NotebookStoreError::SessionNotMovable { .. })
        ));

        let connection = Connection::open(&db_path).unwrap();
        connection
            .execute(
                "UPDATE notebook_capture_runs SET capture_state = 'completed'
                 WHERE session_id = 'recording-now'",
                [],
            )
            .unwrap();
        assert!(store.plan_session_move("recording-now", &target.id).is_ok());

        connection
            .execute(
                "INSERT INTO session_purge_jobs
                 (session_id, plan_json, phase, created_at, updated_at)
                 VALUES ('recording-now', '{}', 'prepared', '2026-03-02', '2026-03-02')",
                [],
            )
            .unwrap();
        assert!(
            matches!(
                store.plan_session_move("recording-now", &target.id),
                Err(NotebookStoreError::SessionNotMovable { .. })
            ),
            "a session already being destroyed must not be movable"
        );
    }

    #[test]
    fn moving_into_the_notebook_it_already_belongs_to_is_refused() {
        let temp = TempDir::new().unwrap();
        let db_path = temp.path().join("notebook.db");
        let store = NotebookStore::new(&db_path).unwrap();
        let notebook = store.create_notebook(Some("Only")).unwrap();
        seed_session(
            &db_path,
            &notebook.id,
            "session-a",
            "2026-03-01 09:00:00",
            "completed",
        );
        store
            .attach_session_with_builtin_projections(&notebook.id, "session-a")
            .unwrap();

        assert!(matches!(
            store.plan_session_move("session-a", &notebook.id),
            Err(NotebookStoreError::Validation(_))
        ));
    }

    #[test]
    fn a_plan_built_before_the_facts_changed_is_refused_at_commit() {
        let temp = TempDir::new().unwrap();
        let db_path = temp.path().join("notebook.db");
        let store = NotebookStore::new(&db_path).unwrap();
        let source = store.create_notebook(Some("Source")).unwrap();
        let target = store.create_notebook(Some("Target")).unwrap();
        seed_session(
            &db_path,
            &source.id,
            "session-a",
            "2026-03-01 09:00:00",
            "completed",
        );
        store
            .attach_session_with_builtin_projections(&source.id, "session-a")
            .unwrap();
        let plan = store.plan_session_move("session-a", &target.id).unwrap();

        // A capture starts between planning and committing.
        Connection::open(&db_path)
            .unwrap()
            .execute(
                "UPDATE notebook_capture_runs SET capture_state = 'recording'
                 WHERE session_id = 'session-a'",
                [],
            )
            .unwrap();

        assert!(store.commit_session_move(&plan).is_err());
        assert_eq!(
            linked_notebook_of(&db_path, "session-a"),
            source.id,
            "a refused commit must leave every pointer where it was"
        );
    }

    #[test]
    fn a_later_section_arriving_first_still_anchors_correctly() {
        let temp = TempDir::new().unwrap();
        let db_path = temp.path().join("notebook.db");
        let store = NotebookStore::new(&db_path).unwrap();
        let source = store.create_notebook(Some("Source")).unwrap();
        let target = store.create_notebook(Some("Target")).unwrap();
        // Linked in reverse chronological order: link order must not decide
        // placement, recording time must.
        seed_session(
            &db_path,
            &target.id,
            "late",
            "2026-06-01 10:00:00",
            "completed",
        );
        store
            .attach_session_with_builtin_projections(&target.id, "late")
            .unwrap();
        seed_session(
            &db_path,
            &target.id,
            "early",
            "2026-01-01 10:00:00",
            "completed",
        );
        store
            .attach_session_with_builtin_projections(&target.id, "early")
            .unwrap();
        seed_session(
            &db_path,
            &source.id,
            "middle",
            "2026-03-01 10:00:00",
            "completed",
        );
        store
            .attach_session_with_builtin_projections(&source.id, "middle")
            .unwrap();

        let plan = store.plan_session_move("middle", &target.id).unwrap();

        for target_plan in &plan.targets {
            assert_eq!(target_plan.later_session_ids, vec!["late".to_string()]);
        }
    }
}
