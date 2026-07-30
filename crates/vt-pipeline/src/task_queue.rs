//! Local durable task queue for explicitly authorized post-recording
//! transcription.
//!
//! The queue has one process-local worker. It deliberately has no peer event
//! protocol, device actor, signature, replica reconciliation, or AI payload.

use std::path::Path;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use rusqlite::OptionalExtension;
use serde::{Deserialize, Serialize};
use tokio::sync::{Mutex, OwnedSemaphorePermit, Semaphore};

const TASK_QUEUE_SCHEMA_VERSION: i32 = 1;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum TaskPayload {
    Transcribe {
        session_id: String,
        #[serde(default)]
        language_hint: Option<String>,
        #[serde(default)]
        remote_authorization: Option<RemoteTaskAuthorization>,
    },
}

pub const REMOTE_TASK_AUTHORIZATION_SCHEMA_V1: &str = "zulangue.remote_processing_authorization.v1";
pub const REMOTE_TASK_AUTHORIZATION_PROVIDER_SONIOX: &str = "soniox";
pub const REMOTE_TASK_AUTHORIZATION_DATA_RECORDED_AUDIO: &str = "recorded_audio";
pub const REMOTE_TASK_AUTHORIZATION_PURPOSE_POST_RECORDING_TRANSCRIPTION: &str =
    "post_recording_transcription";

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct RemoteTaskAuthorization {
    pub schema: String,
    pub provider: String,
    pub data_class: String,
    pub purpose: String,
    pub authorized: bool,
    pub authorized_at_ms: i64,
}

impl RemoteTaskAuthorization {
    pub fn soniox_post_recording() -> Self {
        Self::soniox_post_recording_at(now_ms())
    }

    pub fn soniox_post_recording_at(authorized_at_ms: i64) -> Self {
        Self {
            schema: REMOTE_TASK_AUTHORIZATION_SCHEMA_V1.to_string(),
            provider: REMOTE_TASK_AUTHORIZATION_PROVIDER_SONIOX.to_string(),
            data_class: REMOTE_TASK_AUTHORIZATION_DATA_RECORDED_AUDIO.to_string(),
            purpose: REMOTE_TASK_AUTHORIZATION_PURPOSE_POST_RECORDING_TRANSCRIPTION.to_string(),
            authorized: true,
            authorized_at_ms,
        }
    }

    fn validate(&self) -> Result<(), TaskQueueError> {
        let valid = self.schema == REMOTE_TASK_AUTHORIZATION_SCHEMA_V1
            && self.provider == REMOTE_TASK_AUTHORIZATION_PROVIDER_SONIOX
            && self.data_class == REMOTE_TASK_AUTHORIZATION_DATA_RECORDED_AUDIO
            && self.purpose == REMOTE_TASK_AUTHORIZATION_PURPOSE_POST_RECORDING_TRANSCRIPTION
            && self.authorized
            && self.authorized_at_ms > 0;
        if valid {
            Ok(())
        } else {
            Err(TaskQueueError::ValidationFailed(
                "remote_authorization_invalid: transcription requires an explicit Soniox authorization snapshot"
                    .to_string(),
            ))
        }
    }
}

impl TaskPayload {
    pub fn session_id(&self) -> &str {
        match self {
            Self::Transcribe { session_id, .. } => session_id,
        }
    }

    pub fn type_tag(&self) -> &'static str {
        match self {
            Self::Transcribe { .. } => "transcribe",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TaskStatus {
    Pending,
    Running,
    Completed,
    Failed,
}

impl TaskStatus {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Pending => "pending",
            Self::Running => "running",
            Self::Completed => "completed",
            Self::Failed => "failed",
        }
    }

    fn from_str(value: &str) -> Self {
        match value {
            "running" => Self::Running,
            "completed" => Self::Completed,
            "failed" => Self::Failed,
            _ => Self::Pending,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TaskPriority {
    Low = 0,
    Normal = 5,
    High = 10,
}

pub struct Task {
    pub id: String,
    pub payload: TaskPayload,
    pub status: TaskStatus,
    pub retry_count: i32,
    _permit: Option<OwnedSemaphorePermit>,
}

#[derive(Debug)]
pub struct TaskInfo {
    pub id: String,
    pub payload_json: String,
    pub status: String,
    pub retry_count: i32,
    pub error_msg: Option<String>,
    pub lease_expires_at_ms: Option<i64>,
    pub last_heartbeat_at_ms: Option<i64>,
}

#[derive(Debug, thiserror::Error)]
pub enum TaskQueueError {
    #[error("database error: {0}")]
    DbError(String),
    #[error("serialization error: {0}")]
    SerializeError(String),
    #[error("task not found: {0}")]
    NotFound(String),
    #[error("validation error: {0}")]
    ValidationFailed(String),
}

impl From<rusqlite::Error> for TaskQueueError {
    fn from(error: rusqlite::Error) -> Self {
        Self::DbError(error.to_string())
    }
}

impl From<serde_json::Error> for TaskQueueError {
    fn from(error: serde_json::Error) -> Self {
        Self::SerializeError(error.to_string())
    }
}

pub struct TaskQueue {
    conn: Arc<Mutex<rusqlite::Connection>>,
    semaphore: Arc<Semaphore>,
}

impl TaskQueue {
    pub async fn new(db_path: &Path) -> Result<Self, TaskQueueError> {
        let mut conn = rusqlite::Connection::open(db_path)?;
        initialize_task_schema(&mut conn)?;
        Ok(Self {
            conn: Arc::new(Mutex::new(conn)),
            semaphore: Arc::new(Semaphore::new(2)),
        })
    }

    /// Recovers process-owned leases exactly once after the caller has
    /// acquired the data-directory owner lock. Opening a read connection must
    /// never mutate another process's running tasks.
    pub async fn recover_abandoned_tasks(&self) -> Result<usize, TaskQueueError> {
        let conn = self.conn.lock().await;
        conn.execute(
            "UPDATE tasks
             SET status = 'pending', lease_expires_at_ms = NULL,
                 last_heartbeat_at_ms = NULL, updated_at = datetime('now')
             WHERE status = 'running'",
            [],
        )
        .map_err(Into::into)
    }

    pub async fn enqueue(&self, payload: TaskPayload) -> Result<String, TaskQueueError> {
        self.enqueue_with_priority(payload, TaskPriority::Normal)
            .await
    }

    pub async fn enqueue_with_priority(
        &self,
        payload: TaskPayload,
        priority: TaskPriority,
    ) -> Result<String, TaskQueueError> {
        let id = uuid::Uuid::new_v4().to_string();
        let (id, _) = self.enqueue_with_stable_id(&id, payload, priority).await?;
        Ok(id)
    }

    pub async fn enqueue_with_stable_id(
        &self,
        stable_id: &str,
        payload: TaskPayload,
        priority: TaskPriority,
    ) -> Result<(String, bool), TaskQueueError> {
        self.enqueue_with_stable_id_and_max_retries(stable_id, payload, priority, 3)
            .await
    }

    /// Enqueue remote work whose explicit user authorization permits exactly
    /// one provider attempt. Reopening the app may recover an unclaimed task,
    /// but a claimed provider failure becomes terminal instead of silently
    /// uploading the same audio again.
    pub async fn enqueue_once_with_stable_id(
        &self,
        stable_id: &str,
        payload: TaskPayload,
        priority: TaskPriority,
    ) -> Result<(String, bool), TaskQueueError> {
        self.enqueue_with_stable_id_and_max_retries(stable_id, payload, priority, 1)
            .await
    }

    async fn enqueue_with_stable_id_and_max_retries(
        &self,
        stable_id: &str,
        payload: TaskPayload,
        priority: TaskPriority,
        max_retries: i32,
    ) -> Result<(String, bool), TaskQueueError> {
        let stable_id = stable_id.trim();
        if stable_id.is_empty() {
            return Err(TaskQueueError::ValidationFailed(
                "stable task id must not be empty".to_string(),
            ));
        }
        if !(1..=20).contains(&max_retries) {
            return Err(TaskQueueError::ValidationFailed(
                "max retries must be between 1 and 20".to_string(),
            ));
        }
        validate_payload(&payload)?;
        let payload_json = serde_json::to_string(&payload)?;
        let conn = self.conn.lock().await;
        let inserted = conn.execute(
            "INSERT INTO tasks
             (id, payload, status, priority, retry_count, max_retries, created_at, updated_at)
             VALUES (?1, ?2, 'pending', ?3, 0, ?4, datetime('now'), datetime('now'))
             ON CONFLICT(id) DO NOTHING",
            rusqlite::params![stable_id, payload_json, priority as i32, max_retries],
        )? == 1;
        if !inserted {
            let existing: (String, i32) = conn.query_row(
                "SELECT payload, max_retries FROM tasks WHERE id = ?1",
                [stable_id],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )?;
            if existing.0 != payload_json || existing.1 != max_retries {
                return Err(TaskQueueError::ValidationFailed(format!(
                    "stable task id {stable_id} is already bound to another payload or retry policy"
                )));
            }
        }
        Ok((stable_id.to_string(), inserted))
    }

    pub async fn claim_next(&self, lease_seconds: u64) -> Result<Option<Task>, TaskQueueError> {
        let permit = match self.semaphore.clone().try_acquire_owned() {
            Ok(permit) => permit,
            Err(_) => return Ok(None),
        };
        let conn = self.conn.lock().await;
        loop {
            let selected_at_ms = now_ms();
            let row = conn
                .query_row(
                    "SELECT id, payload, retry_count FROM tasks
                     WHERE status = 'pending'
                        OR (status = 'running' AND lease_expires_at_ms <= ?1)
                     ORDER BY priority DESC, created_at ASC LIMIT 1",
                    [selected_at_ms],
                    |row| {
                        Ok((
                            row.get::<_, String>(0)?,
                            row.get::<_, String>(1)?,
                            row.get::<_, i32>(2)?,
                        ))
                    },
                )
                .optional()?;
            let Some((id, payload_json, retry_count)) = row else {
                drop(permit);
                return Ok(None);
            };
            let payload = match serde_json::from_str::<TaskPayload>(&payload_json)
                .map_err(TaskQueueError::from)
                .and_then(|payload| {
                    validate_payload(&payload)?;
                    Ok(payload)
                }) {
                Ok(payload) => payload,
                Err(error) => {
                    conn.execute(
                        "UPDATE tasks SET status = 'failed', retry_count = retry_count + 1,
                         error_msg = ?1, lease_expires_at_ms = NULL,
                         last_heartbeat_at_ms = NULL, updated_at = datetime('now')
                         WHERE id = ?2",
                        rusqlite::params![format!("unsupported_task_payload: {error}"), id],
                    )?;
                    continue;
                }
            };
            let lease_expires_at_ms =
                selected_at_ms.saturating_add((lease_seconds as i64).saturating_mul(1_000));
            let updated = conn.execute(
                "UPDATE tasks SET status = 'running', lease_expires_at_ms = ?1,
                 last_heartbeat_at_ms = ?2, updated_at = datetime('now')
                 WHERE id = ?3 AND (status = 'pending'
                    OR (status = 'running' AND lease_expires_at_ms <= ?2))",
                rusqlite::params![lease_expires_at_ms, selected_at_ms, id],
            )?;
            if updated == 0 {
                continue;
            }
            return Ok(Some(Task {
                id,
                payload,
                status: TaskStatus::Running,
                retry_count,
                _permit: Some(permit),
            }));
        }
    }

    /// Claim one exact durable task without allowing another queued task to
    /// jump ahead of it.
    ///
    /// Provider-result recovery uses this path after the main database proves
    /// that the provider output is already durable.  That recovery must be
    /// able to run without a provider credential and must never accidentally
    /// claim unrelated provider work while doing so.
    pub async fn claim_by_id(
        &self,
        task_id: &str,
        lease_seconds: u64,
    ) -> Result<Option<Task>, TaskQueueError> {
        let permit = match self.semaphore.clone().try_acquire_owned() {
            Ok(permit) => permit,
            Err(_) => return Ok(None),
        };
        let selected_at_ms = now_ms();
        let conn = self.conn.lock().await;
        let row = conn
            .query_row(
                "SELECT id, payload, retry_count FROM tasks
                 WHERE id = ?1 AND (status = 'pending'
                    OR (status = 'running' AND lease_expires_at_ms <= ?2))",
                rusqlite::params![task_id, selected_at_ms],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, i32>(2)?,
                    ))
                },
            )
            .optional()?;
        let Some((id, payload_json, retry_count)) = row else {
            drop(permit);
            return Ok(None);
        };
        let payload = serde_json::from_str::<TaskPayload>(&payload_json)?;
        validate_payload(&payload)?;
        let lease_expires_at_ms =
            selected_at_ms.saturating_add((lease_seconds as i64).saturating_mul(1_000));
        let updated = conn.execute(
            "UPDATE tasks SET status = 'running', lease_expires_at_ms = ?1,
             last_heartbeat_at_ms = ?2, updated_at = datetime('now')
             WHERE id = ?3 AND (status = 'pending'
                OR (status = 'running' AND lease_expires_at_ms <= ?2))",
            rusqlite::params![lease_expires_at_ms, selected_at_ms, id],
        )?;
        if updated == 0 {
            drop(permit);
            return Ok(None);
        }
        Ok(Some(Task {
            id,
            payload,
            status: TaskStatus::Running,
            retry_count,
            _permit: Some(permit),
        }))
    }

    pub async fn heartbeat(&self, task_id: &str, lease_seconds: u64) -> Result<(), TaskQueueError> {
        let heartbeat_at_ms = now_ms();
        let expires_at_ms =
            heartbeat_at_ms.saturating_add((lease_seconds as i64).saturating_mul(1_000));
        let conn = self.conn.lock().await;
        let updated = conn.execute(
            "UPDATE tasks SET lease_expires_at_ms = ?1, last_heartbeat_at_ms = ?2,
             updated_at = datetime('now') WHERE id = ?3 AND status = 'running'",
            rusqlite::params![expires_at_ms, heartbeat_at_ms, task_id],
        )?;
        require_updated(&conn, task_id, updated, "heartbeat")
    }

    pub async fn complete(&self, task_id: &str) -> Result<(), TaskQueueError> {
        let conn = self.conn.lock().await;
        let updated = conn.execute(
            "UPDATE tasks SET status = 'completed', lease_expires_at_ms = NULL,
             last_heartbeat_at_ms = NULL, error_msg = NULL, updated_at = datetime('now')
             WHERE id = ?1 AND status = 'running'",
            [task_id],
        )?;
        require_updated(&conn, task_id, updated, "complete")
    }

    /// Close a task whose provider output is already proven durable in the
    /// main database. Startup calls this after validating the stable task
    /// identity and receipt, so a crash-reset Pending row never needs to call
    /// the provider again. The operation is idempotent for Completed rows.
    pub async fn complete_from_durable_provider_receipt(
        &self,
        task_id: &str,
    ) -> Result<(), TaskQueueError> {
        let conn = self.conn.lock().await;
        let updated = conn.execute(
            "UPDATE tasks SET status = 'completed', lease_expires_at_ms = NULL,
             last_heartbeat_at_ms = NULL, error_msg = NULL, updated_at = datetime('now')
             WHERE id = ?1 AND status IN ('pending', 'running', 'failed')",
            [task_id],
        )?;
        if updated == 1 {
            return Ok(());
        }
        match conn
            .query_row("SELECT status FROM tasks WHERE id = ?1", [task_id], |row| {
                row.get::<_, String>(0)
            })
            .optional()?
        {
            Some(status) if status == "completed" => Ok(()),
            Some(status) => Err(TaskQueueError::ValidationFailed(format!(
                "cannot complete task {task_id} from durable provider receipt while status is {status}"
            ))),
            None => Err(TaskQueueError::NotFound(task_id.to_string())),
        }
    }

    /// Return a claimed task to the pending queue without consuming a retry.
    ///
    /// This is reserved for worker-readiness races, such as a provider
    /// credential being removed between the pre-claim readiness check and the
    /// post-claim credential load. No provider attempt happened in that case,
    /// so counting it as a retry would incorrectly exhaust durable work while
    /// the user is merely reconfiguring credentials.
    pub async fn release_without_retry(&self, task_id: &str) -> Result<(), TaskQueueError> {
        let conn = self.conn.lock().await;
        let updated = conn.execute(
            "UPDATE tasks SET status = 'pending', lease_expires_at_ms = NULL,
             last_heartbeat_at_ms = NULL, updated_at = datetime('now')
             WHERE id = ?1 AND status = 'running'",
            [task_id],
        )?;
        require_updated(&conn, task_id, updated, "release without retry")
    }

    pub async fn fail(&self, task_id: &str, error: &str) -> Result<(), TaskQueueError> {
        let conn = self.conn.lock().await;
        let retries: Option<(i32, i32)> = conn
            .query_row(
                "SELECT retry_count, max_retries FROM tasks WHERE id = ?1",
                [task_id],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .optional()?;
        let (retry_count, max_retries) =
            retries.ok_or_else(|| TaskQueueError::NotFound(task_id.to_string()))?;
        let status = if retry_count + 1 >= max_retries {
            "failed"
        } else {
            "pending"
        };
        let updated = conn.execute(
            "UPDATE tasks SET status = ?1, retry_count = retry_count + 1,
             lease_expires_at_ms = NULL, last_heartbeat_at_ms = NULL,
             error_msg = ?2, updated_at = datetime('now')
             WHERE id = ?3 AND status = 'running'",
            rusqlite::params![status, error, task_id],
        )?;
        require_updated(&conn, task_id, updated, "fail")
    }

    pub async fn fail_terminal(&self, task_id: &str, error: &str) -> Result<(), TaskQueueError> {
        let conn = self.conn.lock().await;
        let updated = conn.execute(
            "UPDATE tasks SET status = 'failed', retry_count = retry_count + 1,
             lease_expires_at_ms = NULL, last_heartbeat_at_ms = NULL,
             error_msg = ?1, updated_at = datetime('now') WHERE id = ?2",
            rusqlite::params![error, task_id],
        )?;
        require_updated(&conn, task_id, updated, "fail terminal")
    }

    /// Quarantine claimed work for a permanent local preflight failure.
    ///
    /// No provider request occurred, so the provider retry counter is left
    /// untouched even though the task is terminally failed closed.
    pub async fn fail_local_preflight(
        &self,
        task_id: &str,
        error: &str,
    ) -> Result<(), TaskQueueError> {
        let conn = self.conn.lock().await;
        let updated = conn.execute(
            "UPDATE tasks SET status = 'failed', lease_expires_at_ms = NULL,
             last_heartbeat_at_ms = NULL, error_msg = ?1, updated_at = datetime('now')
             WHERE id = ?2 AND status = 'running'",
            rusqlite::params![error, task_id],
        )?;
        require_updated(&conn, task_id, updated, "fail local preflight")
    }

    pub async fn purge_task(&self, task_id: &str) -> Result<bool, TaskQueueError> {
        let conn = self.conn.lock().await;
        Ok(conn.execute("DELETE FROM tasks WHERE id = ?1", [task_id])? == 1)
    }

    pub async fn purge_session(&self, session_id: &str) -> Result<usize, TaskQueueError> {
        let mut conn = self.conn.lock().await;
        let task_ids = matching_task_ids(&conn, session_id)?;
        let transaction = conn.transaction()?;
        for task_id in &task_ids {
            transaction.execute("DELETE FROM tasks WHERE id = ?1", [task_id])?;
        }
        transaction.commit()?;
        Ok(task_ids.len())
    }

    pub async fn list_session_task_ids(
        &self,
        session_id: &str,
    ) -> Result<Vec<String>, TaskQueueError> {
        let conn = self.conn.lock().await;
        matching_task_ids(&conn, session_id)
    }

    pub async fn get_status(&self, task_id: &str) -> Result<TaskStatus, TaskQueueError> {
        let conn = self.conn.lock().await;
        let status = conn
            .query_row("SELECT status FROM tasks WHERE id = ?1", [task_id], |row| {
                row.get::<_, String>(0)
            })
            .optional()?
            .ok_or_else(|| TaskQueueError::NotFound(task_id.to_string()))?;
        Ok(TaskStatus::from_str(&status))
    }

    pub async fn get_task(&self, task_id: &str) -> Result<TaskInfo, TaskQueueError> {
        let conn = self.conn.lock().await;
        conn.query_row(
            "SELECT id, payload, status, retry_count, error_msg,
                    lease_expires_at_ms, last_heartbeat_at_ms
             FROM tasks WHERE id = ?1",
            [task_id],
            task_info_from_row,
        )
        .optional()?
        .ok_or_else(|| TaskQueueError::NotFound(task_id.to_string()))
    }

    pub async fn list_tasks(
        &self,
        status_filter: Option<&str>,
    ) -> Result<Vec<TaskInfo>, TaskQueueError> {
        if let Some(status) = status_filter {
            if !matches!(status, "pending" | "running" | "completed" | "failed") {
                return Err(TaskQueueError::ValidationFailed(format!(
                    "invalid task status filter: {status}"
                )));
            }
        }
        let conn = self.conn.lock().await;
        let sql = if status_filter.is_some() {
            "SELECT id, payload, status, retry_count, error_msg,
                    lease_expires_at_ms, last_heartbeat_at_ms
             FROM tasks WHERE status = ?1 ORDER BY created_at DESC"
        } else {
            "SELECT id, payload, status, retry_count, error_msg,
                    lease_expires_at_ms, last_heartbeat_at_ms
             FROM tasks ORDER BY created_at DESC"
        };
        let mut statement = conn.prepare(sql)?;
        let rows = if let Some(status) = status_filter {
            statement.query_map([status], task_info_from_row)?
        } else {
            statement.query_map([], task_info_from_row)?
        };
        rows.collect::<Result<Vec<_>, _>>()
            .map_err(TaskQueueError::from)
    }
}

fn initialize_task_schema(conn: &mut rusqlite::Connection) -> Result<(), TaskQueueError> {
    let version = conn.pragma_query_value(None, "user_version", |row| row.get::<_, i32>(0))?;
    match version {
        0 if database_has_user_objects(conn)? => {
            return Err(TaskQueueError::ValidationFailed(
                "unsupported task schema 0; reset required".to_string(),
            ));
        }
        0 => {
            let transaction = conn.transaction()?;
            transaction.execute_batch(
                "CREATE TABLE tasks (
                    id TEXT PRIMARY KEY,
                    payload TEXT NOT NULL,
                    status TEXT NOT NULL DEFAULT 'pending'
                        CHECK (status IN ('pending', 'running', 'completed', 'failed')),
                    priority INTEGER NOT NULL DEFAULT 0
                        CHECK (priority BETWEEN -100 AND 100),
                    retry_count INTEGER NOT NULL DEFAULT 0
                        CHECK (retry_count >= 0),
                    max_retries INTEGER NOT NULL DEFAULT 3
                        CHECK (max_retries BETWEEN 1 AND 20),
                    lease_expires_at_ms INTEGER,
                    last_heartbeat_at_ms INTEGER,
                    error_msg TEXT,
                    created_at TEXT NOT NULL DEFAULT (datetime('now')),
                    updated_at TEXT NOT NULL DEFAULT (datetime('now'))
                );
                CREATE INDEX idx_tasks_status_priority
                    ON tasks(status, priority DESC, created_at ASC);",
            )?;
            transaction.pragma_update(None, "user_version", TASK_QUEUE_SCHEMA_VERSION)?;
            transaction.commit()?;
        }
        TASK_QUEUE_SCHEMA_VERSION => validate_task_schema(conn)?,
        unsupported => {
            return Err(TaskQueueError::ValidationFailed(format!(
                "unsupported task schema {unsupported}; reset required"
            )));
        }
    }
    Ok(())
}

fn database_has_user_objects(conn: &rusqlite::Connection) -> Result<bool, TaskQueueError> {
    Ok(conn
        .query_row(
            "SELECT 1 FROM sqlite_schema
             WHERE name NOT LIKE 'sqlite_%'
               AND type IN ('table', 'index', 'trigger', 'view')
             LIMIT 1",
            [],
            |_| Ok(()),
        )
        .optional()?
        .is_some())
}

fn validate_task_schema(conn: &rusqlite::Connection) -> Result<(), TaskQueueError> {
    conn.prepare(
        "SELECT id, payload, status, priority, retry_count, max_retries,
                lease_expires_at_ms, last_heartbeat_at_ms, error_msg,
                created_at, updated_at
         FROM tasks LIMIT 0",
    )
    .map(|_| ())
    .map_err(|_| {
        TaskQueueError::ValidationFailed("task schema 1 is incomplete; reset required".to_string())
    })
}

fn validate_payload(payload: &TaskPayload) -> Result<(), TaskQueueError> {
    match payload {
        TaskPayload::Transcribe {
            session_id,
            remote_authorization,
            ..
        } => {
            if session_id.trim().is_empty() {
                return Err(TaskQueueError::ValidationFailed(
                    "transcribe session_id must not be empty".to_string(),
                ));
            }
            remote_authorization
                .as_ref()
                .ok_or_else(|| {
                    TaskQueueError::ValidationFailed(
                        "remote_authorization_required: transcription requires explicit authorization"
                            .to_string(),
                    )
                })?
                .validate()
        }
    }
}

fn matching_task_ids(
    conn: &rusqlite::Connection,
    session_id: &str,
) -> Result<Vec<String>, TaskQueueError> {
    let mut statement = conn.prepare("SELECT id, payload FROM tasks ORDER BY id")?;
    let rows = statement.query_map([], |row| {
        Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
    })?;
    let mut matching = Vec::new();
    for row in rows {
        let (task_id, payload_json) = row?;
        let payload: TaskPayload = serde_json::from_str(&payload_json).map_err(|error| {
            TaskQueueError::SerializeError(format!(
                "cannot audit task {task_id} during session purge: {error}"
            ))
        })?;
        let belongs = payload.session_id() == session_id;
        if belongs {
            matching.push(task_id);
        }
    }
    Ok(matching)
}

fn require_updated(
    conn: &rusqlite::Connection,
    task_id: &str,
    updated: usize,
    action: &str,
) -> Result<(), TaskQueueError> {
    if updated == 1 {
        return Ok(());
    }
    let exists = conn
        .query_row("SELECT 1 FROM tasks WHERE id = ?1", [task_id], |row| {
            row.get::<_, i64>(0)
        })
        .optional()?
        .is_some();
    if exists {
        Err(TaskQueueError::ValidationFailed(format!(
            "task {task_id} cannot {action} from its current state"
        )))
    } else {
        Err(TaskQueueError::NotFound(task_id.to_string()))
    }
}

fn task_info_from_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<TaskInfo> {
    Ok(TaskInfo {
        id: row.get(0)?,
        payload_json: row.get(1)?,
        status: row.get(2)?,
        retry_count: row.get(3)?,
        error_msg: row.get(4)?,
        lease_expires_at_ms: row.get(5)?,
        last_heartbeat_at_ms: row.get(6)?,
    })
}

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64
}

#[cfg(test)]
mod tests {
    use super::*;

    async fn queue() -> (tempfile::TempDir, TaskQueue) {
        let temp = tempfile::TempDir::new().unwrap();
        let queue = TaskQueue::new(&temp.path().join("tasks.db")).await.unwrap();
        (temp, queue)
    }

    fn transcribe(session_id: &str) -> TaskPayload {
        TaskPayload::Transcribe {
            session_id: session_id.to_string(),
            language_hint: None,
            remote_authorization: Some(RemoteTaskAuthorization::soniox_post_recording_at(1)),
        }
    }

    #[tokio::test]
    async fn fresh_queue_installs_only_schema_v1() {
        let (temp, _queue) = queue().await;
        let conn = rusqlite::Connection::open(temp.path().join("tasks.db")).unwrap();
        let version: i32 = conn
            .pragma_query_value(None, "user_version", |row| row.get(0))
            .unwrap();
        assert_eq!(version, TASK_QUEUE_SCHEMA_VERSION);
        let objects: Vec<String> = conn
            .prepare(
                "SELECT name FROM sqlite_schema
                 WHERE name NOT LIKE 'sqlite_%' ORDER BY name",
            )
            .unwrap()
            .query_map([], |row| row.get(0))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        assert_eq!(objects, vec!["idx_tasks_status_priority", "tasks"]);
    }

    #[tokio::test]
    async fn unversioned_old_queue_is_rejected_without_mutation() {
        let temp = tempfile::TempDir::new().unwrap();
        let path = temp.path().join("tasks.db");
        let conn = rusqlite::Connection::open(&path).unwrap();
        conn.execute_batch(
            "CREATE TABLE tasks (id TEXT PRIMARY KEY, payload TEXT NOT NULL);
             INSERT INTO tasks (id, payload) VALUES ('retired-task', '{}');",
        )
        .unwrap();
        drop(conn);

        let error = TaskQueue::new(&path).await.err().unwrap();
        assert!(error.to_string().contains("reset required"));

        let conn = rusqlite::Connection::open(path).unwrap();
        let count: i64 = conn
            .query_row("SELECT COUNT(*) FROM tasks", [], |row| row.get(0))
            .unwrap();
        assert_eq!(count, 1);
        let version: i32 = conn
            .pragma_query_value(None, "user_version", |row| row.get(0))
            .unwrap();
        assert_eq!(version, 0);
    }

    #[tokio::test]
    async fn schema_v1_reopen_recovers_only_process_local_running_tasks() {
        let temp = tempfile::TempDir::new().unwrap();
        let path = temp.path().join("tasks.db");
        let queue = TaskQueue::new(&path).await.unwrap();
        let id = queue.enqueue(transcribe("s1")).await.unwrap();
        let task = queue.claim_next(30).await.unwrap().unwrap();
        assert_eq!(task.id, id);
        drop(task);
        drop(queue);

        let reopened = TaskQueue::new(&path).await.unwrap();
        assert_eq!(reopened.get_status(&id).await.unwrap(), TaskStatus::Running);
        reopened.recover_abandoned_tasks().await.unwrap();
        assert_eq!(reopened.get_status(&id).await.unwrap(), TaskStatus::Pending);
    }

    #[tokio::test]
    async fn unknown_queue_schema_is_rejected() {
        let temp = tempfile::TempDir::new().unwrap();
        let path = temp.path().join("tasks.db");
        let conn = rusqlite::Connection::open(&path).unwrap();
        conn.pragma_update(None, "user_version", 9).unwrap();
        drop(conn);

        let error = TaskQueue::new(&path).await.err().unwrap();
        assert!(error.to_string().contains("unsupported task schema 9"));
    }

    #[tokio::test]
    async fn stable_enqueue_is_idempotent_and_cannot_rebind() {
        let (_temp, queue) = queue().await;
        assert_eq!(
            queue
                .enqueue_with_stable_id("stable", transcribe("s1"), TaskPriority::Normal)
                .await
                .unwrap(),
            ("stable".to_string(), true)
        );
        assert!(
            !queue
                .enqueue_with_stable_id("stable", transcribe("s1"), TaskPriority::High)
                .await
                .unwrap()
                .1
        );
        assert!(queue
            .enqueue_with_stable_id("stable", transcribe("s2"), TaskPriority::Normal)
            .await
            .is_err());
    }

    #[tokio::test]
    async fn single_attempt_stable_enqueue_is_terminal_after_one_failure() {
        let (_temp, queue) = queue().await;
        assert_eq!(
            queue
                .enqueue_once_with_stable_id(
                    "single-attempt",
                    transcribe("s1"),
                    TaskPriority::Normal,
                )
                .await
                .unwrap(),
            ("single-attempt".to_string(), true)
        );
        assert!(!queue
            .enqueue_once_with_stable_id(
                "single-attempt",
                transcribe("s1"),
                TaskPriority::High,
            )
            .await
            .unwrap()
            .1);
        assert!(queue
            .enqueue_with_stable_id("single-attempt", transcribe("s1"), TaskPriority::Normal,)
            .await
            .is_err());

        let task = queue.claim_next(30).await.unwrap().unwrap();
        assert_eq!(task.id, "single-attempt");
        queue.fail(&task.id, "provider unavailable").await.unwrap();
        assert_eq!(
            queue.get_status(&task.id).await.unwrap(),
            TaskStatus::Failed
        );
        assert!(queue.claim_next(30).await.unwrap().is_none());
    }

    #[tokio::test]
    async fn remote_work_requires_exact_authorization() {
        let (_temp, queue) = queue().await;
        let missing = TaskPayload::Transcribe {
            session_id: "s1".to_string(),
            language_hint: None,
            remote_authorization: None,
        };
        assert!(queue.enqueue(missing).await.is_err());
    }

    #[tokio::test]
    async fn local_lifecycle_retries_then_completes() {
        let (_temp, queue) = queue().await;
        let id = queue.enqueue(transcribe("s1")).await.unwrap();
        let first = queue.claim_next(30).await.unwrap().unwrap();
        assert_eq!(first.id, id);
        drop(first);
        queue.fail(&id, "retry").await.unwrap();
        assert_eq!(queue.get_status(&id).await.unwrap(), TaskStatus::Pending);

        let second = queue.claim_next(30).await.unwrap().unwrap();
        drop(second);
        queue.complete(&id).await.unwrap();
        assert_eq!(queue.get_status(&id).await.unwrap(), TaskStatus::Completed);
    }

    #[tokio::test]
    async fn readiness_race_release_preserves_retry_budget_and_clears_lease() {
        let (_temp, queue) = queue().await;
        let id = queue.enqueue(transcribe("s1")).await.unwrap();
        let claimed = queue.claim_next(30).await.unwrap().unwrap();
        assert_eq!(claimed.id, id);

        queue.release_without_retry(&id).await.unwrap();
        drop(claimed);

        let released = queue.get_task(&id).await.unwrap();
        assert_eq!(released.status, "pending");
        assert_eq!(released.retry_count, 0);
        assert!(released.error_msg.is_none());
        assert!(released.lease_expires_at_ms.is_none());
        assert!(released.last_heartbeat_at_ms.is_none());

        let reclaimed = queue.claim_next(30).await.unwrap().unwrap();
        assert_eq!(reclaimed.id, id);
        assert_eq!(reclaimed.retry_count, 0);

        queue.fail(&id, "previous provider failure").await.unwrap();
        drop(reclaimed);
        let claimed_after_retry = queue.claim_next(30).await.unwrap().unwrap();
        queue.release_without_retry(&id).await.unwrap();
        drop(claimed_after_retry);
        let released_after_retry = queue.get_task(&id).await.unwrap();
        assert_eq!(released_after_retry.status, "pending");
        assert_eq!(released_after_retry.retry_count, 1);
        assert_eq!(
            released_after_retry.error_msg.as_deref(),
            Some("previous provider failure")
        );
    }

    #[tokio::test]
    async fn exact_claim_does_not_take_unrelated_provider_work() {
        let (_temp, queue) = queue().await;
        let first = queue.enqueue(transcribe("first")).await.unwrap();
        let receipt_task = queue.enqueue(transcribe("receipt")).await.unwrap();

        let claimed = queue.claim_by_id(&receipt_task, 30).await.unwrap().unwrap();
        assert_eq!(claimed.id, receipt_task);
        assert_eq!(queue.get_status(&first).await.unwrap(), TaskStatus::Pending);
    }

    #[tokio::test]
    async fn durable_provider_receipt_repairs_a_failed_local_queue_row() {
        let (_temp, queue) = queue().await;
        let id = queue.enqueue(transcribe("s1")).await.unwrap();
        let claimed = queue.claim_next(30).await.unwrap().unwrap();
        queue
            .fail_terminal(&id, "local finalization failed")
            .await
            .unwrap();
        drop(claimed);

        queue
            .complete_from_durable_provider_receipt(&id)
            .await
            .unwrap();
        let repaired = queue.get_task(&id).await.unwrap();
        assert_eq!(repaired.status, "completed");
        assert!(repaired.error_msg.is_none());
    }

    #[tokio::test]
    async fn local_preflight_failure_is_terminal_without_provider_retry() {
        let (_temp, queue) = queue().await;
        let id = queue.enqueue(transcribe("s1")).await.unwrap();
        let claimed = queue.claim_next(30).await.unwrap().unwrap();

        queue
            .fail_local_preflight(&id, "source metadata unavailable")
            .await
            .unwrap();
        drop(claimed);

        let failed = queue.get_task(&id).await.unwrap();
        assert_eq!(failed.status, "failed");
        assert_eq!(failed.retry_count, 0);
        assert_eq!(
            failed.error_msg.as_deref(),
            Some("source metadata unavailable")
        );
        assert!(failed.lease_expires_at_ms.is_none());
        assert!(failed.last_heartbeat_at_ms.is_none());
    }

    #[tokio::test]
    async fn purge_matches_only_the_immutable_session() {
        let (_temp, queue) = queue().await;
        queue.enqueue(transcribe("s1")).await.unwrap();
        queue.enqueue(transcribe("s2")).await.unwrap();
        assert_eq!(queue.purge_session("s1").await.unwrap(), 1);
        let remaining = queue.list_tasks(None).await.unwrap();
        assert_eq!(remaining.len(), 1);
        assert!(remaining[0].payload_json.contains("\"session_id\":\"s2\""));
    }
}
