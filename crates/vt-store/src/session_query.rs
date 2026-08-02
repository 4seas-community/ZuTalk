//! 会话查询/过滤/排序/分页
//! 权威：D5 §10

use std::path::Path;
use std::sync::Mutex;

use rusqlite::Connection;

/// 查询参数
#[derive(Debug, Clone, Default)]
pub struct SessionQuery {
    pub session_type: Option<String>,
    pub status: Option<String>,
    pub search_text: Option<String>,
    pub limit: Option<u32>,
    pub offset: Option<u32>,
    pub sort_field: SortField,
    pub sort_order: SortOrder,
    /// 垃圾箱维度:默认 ActiveOnly(deleted_at IS NULL)。
    /// TrashedOnly 给 TrashPage 列已软删 session。
    /// All 两者全拿(目前不用,预留)。
    pub trash_filter: TrashFilter,
}

/// 软删筛选
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub enum TrashFilter {
    #[default]
    ActiveOnly,
    TrashedOnly,
    All,
}

/// 排序字段
#[derive(Debug, Clone, Default)]
pub enum SortField {
    #[default]
    CreatedAt,
    Title,
    Duration,
}

impl SortField {
    fn sql_column(&self) -> &str {
        match self {
            Self::CreatedAt => "created_at",
            Self::Title => "title",
            Self::Duration => "duration_ms",
        }
    }
}

/// 排序方向
#[derive(Debug, Clone, Default)]
pub enum SortOrder {
    #[default]
    Desc,
    Asc,
}

impl SortOrder {
    fn sql(&self) -> &str {
        match self {
            Self::Desc => "DESC",
            Self::Asc => "ASC",
        }
    }
}

/// 查询结果
#[derive(Debug, Clone)]
pub struct SessionRecord {
    pub id: String,
    pub title: String,
    pub session_type: String,
    pub status: String,
    pub duration_ms: u64,
    pub created_at: String,
    /// 软删时间;None 表示未删
    pub deleted_at: Option<String>,
}

/// 分页结果
#[derive(Debug)]
pub struct QueryResult {
    pub sessions: Vec<SessionRecord>,
    pub total_count: u64,
}

/// 会话查询存储
pub struct SessionQueryStore {
    conn: Mutex<Connection>,
}

impl SessionQueryStore {
    pub fn new(db_path: &Path) -> Result<Self, SessionQueryError> {
        let conn = Connection::open(db_path)?;
        crate::migration::run_migrations(&conn)?;
        Ok(Self {
            conn: Mutex::new(conn),
        })
    }

    /// 插入会话记录
    pub fn insert_session(&self, record: &SessionRecord) -> Result<(), SessionQueryError> {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "INSERT INTO session_records
             (id, title, session_type, status, duration_ms, created_at, deleted_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
             ON CONFLICT(id) DO UPDATE SET
                 title = excluded.title,
                 session_type = excluded.session_type,
                 status = excluded.status,
                 duration_ms = excluded.duration_ms,
                 created_at = excluded.created_at,
                 deleted_at = excluded.deleted_at",
            rusqlite::params![
                record.id,
                record.title,
                record.session_type,
                record.status,
                record.duration_ms as i64,
                record.created_at,
                record.deleted_at,
            ],
        )?;
        Ok(())
    }

    /// 按 id 读取单条 session 记录。包含已软删记录,供状态更新时保留原始字段。
    pub fn get_session(&self, id: &str) -> Result<SessionRecord, SessionQueryError> {
        let conn = self.conn.lock().unwrap();
        conn.query_row(
            "SELECT id, title, session_type, status, duration_ms, created_at, deleted_at
               FROM session_records
              WHERE id = ?1",
            rusqlite::params![id],
            |row| {
                Ok(SessionRecord {
                    id: row.get(0)?,
                    title: row.get(1)?,
                    session_type: row.get(2)?,
                    status: row.get(3)?,
                    duration_ms: row.get::<_, i64>(4)? as u64,
                    created_at: row.get(5)?,
                    deleted_at: row.get(6)?,
                })
            },
        )
        .map_err(|e| match e {
            rusqlite::Error::QueryReturnedNoRows => SessionQueryError::NotFound(id.to_string()),
            other => SessionQueryError::DbError(other.to_string()),
        })
    }

    /// 软删一个 session。deleted_at 设为当前时间(UTC ISO-8601 风格)。
    /// 已删过的再软删是 no-op(不覆盖时间)。不存在的 id 返回 NotFound。
    pub fn soft_delete(&self, id: &str) -> Result<(), SessionQueryError> {
        let conn = self.conn.lock().unwrap();
        let affected = conn.execute(
            "UPDATE session_records
               SET deleted_at = datetime('now')
             WHERE id = ?1 AND deleted_at IS NULL",
            rusqlite::params![id],
        )?;
        if affected == 0 {
            // 可能 id 不存在,也可能已经软删过 — 查一下区分
            let exists: i64 = conn
                .query_row(
                    "SELECT COUNT(*) FROM session_records WHERE id = ?1",
                    rusqlite::params![id],
                    |row| row.get(0),
                )
                .unwrap_or(0);
            if exists == 0 {
                return Err(SessionQueryError::NotFound(id.to_string()));
            }
            // 已软删 — no-op 算成功
        }
        Ok(())
    }

    /// 批量软删。部分不存在的 id 视为成功(已经不在了, idempotent)。
    pub fn soft_delete_many(&self, ids: &[String]) -> Result<(), SessionQueryError> {
        if ids.is_empty() {
            return Ok(());
        }
        let mut conn = self.conn.lock().unwrap();
        let tx = conn.transaction()?;
        {
            let mut stmt = tx.prepare(
                "UPDATE session_records
                   SET deleted_at = datetime('now')
                 WHERE id = ?1 AND deleted_at IS NULL",
            )?;
            for id in ids {
                stmt.execute(rusqlite::params![id])?;
            }
        }
        tx.commit()?;
        Ok(())
    }

    /// 从垃圾箱恢复 — 清掉 deleted_at。
    pub fn restore(&self, id: &str) -> Result<(), SessionQueryError> {
        let conn = self.conn.lock().unwrap();
        let affected = conn.execute(
            "UPDATE session_records SET deleted_at = NULL WHERE id = ?1",
            rusqlite::params![id],
        )?;
        if affected == 0 {
            return Err(SessionQueryError::NotFound(id.to_string()));
        }
        Ok(())
    }

    /// 启动自愈:把仍为 `recording` 且非软删的 session 标成 failed,
    /// 并返回**被改动**的 session id 列表（供上层记录/诊断）。
    /// 这种 session 上次 app 进程没走完 stop 流程(crash / 强杀 / 忘按停)→ 重启后
    /// 已失去进程内 capture owner，
    /// 只能视为失败让 UI 提示用户(而不是永远"转录中..."误导)。
    pub fn mark_stale_as_failed(&self) -> Result<Vec<String>, SessionQueryError> {
        let conn = self.conn.lock().unwrap();
        // 1. 先查 ids (用于返回)
        let mut stmt = conn.prepare(
            "SELECT id FROM session_records
             WHERE status = 'recording'
               AND deleted_at IS NULL",
        )?;
        let ids: Vec<String> = stmt
            .query_map([], |row| row.get::<_, String>(0))?
            .collect::<Result<Vec<_>, _>>()?;
        drop(stmt);
        // 2. 批量改 status
        if !ids.is_empty() {
            conn.execute(
                "UPDATE session_records
                   SET status = 'failed'
                 WHERE status = 'recording'
                   AND deleted_at IS NULL",
                [],
            )?;
        }
        Ok(ids)
    }

    /// 删除 session catalogue 行。完整 Delete Forever 由 Notebook Capture
    /// purge 协调器负责，必须先清音频、key、run、utterance、投影和任务。
    pub fn purge(&self, id: &str) -> Result<(), SessionQueryError> {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "DELETE FROM session_records WHERE id = ?1",
            rusqlite::params![id],
        )?;
        Ok(())
    }

    /// 查询会话
    pub fn query_sessions(&self, query: &SessionQuery) -> Result<QueryResult, SessionQueryError> {
        let conn = self.conn.lock().unwrap();

        let mut where_clauses = Vec::new();
        let mut params: Vec<Box<dyn rusqlite::types::ToSql>> = Vec::new();

        if let Some(ref st) = query.session_type {
            where_clauses.push(format!("session_type = ?{}", params.len() + 1));
            params.push(Box::new(st.clone()));
        }

        if let Some(ref status) = query.status {
            where_clauses.push(format!("status = ?{}", params.len() + 1));
            params.push(Box::new(status.clone()));
        }

        if let Some(ref text) = query.search_text {
            where_clauses.push(format!("title LIKE ?{}", params.len() + 1));
            params.push(Box::new(format!("%{text}%")));
        }

        match query.trash_filter {
            TrashFilter::ActiveOnly => {
                where_clauses.push("deleted_at IS NULL".to_string());
            }
            TrashFilter::TrashedOnly => {
                where_clauses.push("deleted_at IS NOT NULL".to_string());
            }
            TrashFilter::All => {}
        }

        let where_sql = if where_clauses.is_empty() {
            String::new()
        } else {
            format!("WHERE {}", where_clauses.join(" AND "))
        };

        // Count
        let count_sql = format!("SELECT COUNT(*) FROM session_records {where_sql}");
        let total_count: i64 = conn
            .query_row(
                &count_sql,
                rusqlite::params_from_iter(params.iter().map(|p| p.as_ref())),
                |row| row.get(0),
            )
            .unwrap_or(0);
        let total_count = total_count as u64;

        // Query
        let limit = query.limit.unwrap_or(50);
        let offset = query.offset.unwrap_or(0);
        let order_col = query.sort_field.sql_column();
        let order_dir = query.sort_order.sql();

        let select_sql = format!(
            "SELECT id, title, session_type, status, duration_ms, created_at, deleted_at
             FROM session_records {where_sql}
             ORDER BY {order_col} {order_dir}
             LIMIT {limit} OFFSET {offset}"
        );

        let mut stmt = conn.prepare(&select_sql)?;
        let sessions = stmt
            .query_map(
                rusqlite::params_from_iter(params.iter().map(|p| p.as_ref())),
                |row| {
                    Ok(SessionRecord {
                        id: row.get(0)?,
                        title: row.get(1)?,
                        session_type: row.get(2)?,
                        status: row.get(3)?,
                        duration_ms: row.get::<_, i64>(4)? as u64,
                        created_at: row.get(5)?,
                        deleted_at: row.get(6)?,
                    })
                },
            )?
            .filter_map(|r| r.ok())
            .collect();

        Ok(QueryResult {
            sessions,
            total_count,
        })
    }
}

#[derive(Debug, thiserror::Error)]
pub enum SessionQueryError {
    #[error("database error: {0}")]
    DbError(String),
    #[error("session not found: {0}")]
    NotFound(String),
}

impl From<rusqlite::Error> for SessionQueryError {
    fn from(e: rusqlite::Error) -> Self {
        SessionQueryError::DbError(e.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    fn setup() -> (TempDir, SessionQueryStore) {
        let tmp = TempDir::new().unwrap();
        let store = SessionQueryStore::new(&tmp.path().join("sessions.db")).unwrap();
        (tmp, store)
    }

    fn insert_test_sessions(store: &SessionQueryStore) {
        for i in 0..10 {
            store
                .insert_session(&SessionRecord {
                    id: format!("s{i}"),
                    title: format!("Session {i}"),
                    session_type: if i % 2 == 0 { "recording" } else { "import" }.to_string(),
                    status: "completed".to_string(),
                    duration_ms: (i + 1) * 60_000,
                    created_at: format!("2000-04-{:02} 10:00:00", i + 1),
                    deleted_at: None,
                })
                .unwrap();
        }
    }

    #[test]
    fn test_soft_delete_hides_from_active_list() {
        let (_tmp, store) = setup();
        insert_test_sessions(&store);

        store.soft_delete("s3").unwrap();
        let active = store.query_sessions(&SessionQuery::default()).unwrap();
        assert_eq!(active.total_count, 9);
        assert!(!active.sessions.iter().any(|s| s.id == "s3"));

        let trashed = store
            .query_sessions(&SessionQuery {
                trash_filter: TrashFilter::TrashedOnly,
                ..Default::default()
            })
            .unwrap();
        assert_eq!(trashed.total_count, 1);
        assert_eq!(trashed.sessions[0].id, "s3");
    }

    #[test]
    fn test_soft_delete_many_and_restore() {
        let (_tmp, store) = setup();
        insert_test_sessions(&store);

        store
            .soft_delete_many(&["s1".to_string(), "s2".to_string(), "s3".to_string()])
            .unwrap();
        let active = store.query_sessions(&SessionQuery::default()).unwrap();
        assert_eq!(active.total_count, 7);

        store.restore("s2").unwrap();
        let active = store.query_sessions(&SessionQuery::default()).unwrap();
        assert_eq!(active.total_count, 8);
        assert!(active.sessions.iter().any(|s| s.id == "s2"));
    }

    #[test]
    fn test_purge_removes_row() {
        let (_tmp, store) = setup();
        insert_test_sessions(&store);

        store.soft_delete("s4").unwrap();
        store.purge("s4").unwrap();
        let all = store
            .query_sessions(&SessionQuery {
                trash_filter: TrashFilter::All,
                ..Default::default()
            })
            .unwrap();
        assert_eq!(all.total_count, 9);
        assert!(!all.sessions.iter().any(|s| s.id == "s4"));
    }

    #[test]
    fn test_soft_delete_nonexistent_returns_not_found() {
        let (_tmp, store) = setup();
        insert_test_sessions(&store);

        let err = store.soft_delete("nonexistent").unwrap_err();
        assert!(matches!(err, SessionQueryError::NotFound(_)));
    }

    #[test]
    fn test_query_all() {
        let (_tmp, store) = setup();
        insert_test_sessions(&store);

        let result = store.query_sessions(&SessionQuery::default()).unwrap();
        assert_eq!(result.total_count, 10);
        assert_eq!(result.sessions.len(), 10);
    }

    #[test]
    fn test_query_by_type() {
        let (_tmp, store) = setup();
        insert_test_sessions(&store);

        let result = store
            .query_sessions(&SessionQuery {
                session_type: Some("import".to_string()),
                ..Default::default()
            })
            .unwrap();
        assert_eq!(result.total_count, 5);
    }

    #[test]
    fn test_query_pagination() {
        let (_tmp, store) = setup();
        insert_test_sessions(&store);

        let result = store
            .query_sessions(&SessionQuery {
                limit: Some(3),
                offset: Some(0),
                ..Default::default()
            })
            .unwrap();
        assert_eq!(result.sessions.len(), 3);
        assert_eq!(result.total_count, 10);
    }

    #[test]
    fn test_query_sort_by_date_asc() {
        let (_tmp, store) = setup();
        insert_test_sessions(&store);

        let result = store
            .query_sessions(&SessionQuery {
                sort_field: SortField::CreatedAt,
                sort_order: SortOrder::Asc,
                ..Default::default()
            })
            .unwrap();
        assert!(result.sessions[0].created_at < result.sessions[9].created_at);
    }

    #[test]
    fn test_query_search_text() {
        let (_tmp, store) = setup();
        insert_test_sessions(&store);

        let result = store
            .query_sessions(&SessionQuery {
                search_text: Some("Session 5".to_string()),
                ..Default::default()
            })
            .unwrap();
        assert_eq!(result.total_count, 1);
        assert_eq!(result.sessions[0].id, "s5");
    }

    #[test]
    fn test_query_combined_filters() {
        let (_tmp, store) = setup();
        insert_test_sessions(&store);

        let result = store
            .query_sessions(&SessionQuery {
                session_type: Some("recording".to_string()),
                status: Some("completed".to_string()),
                limit: Some(2),
                ..Default::default()
            })
            .unwrap();
        assert!(result.sessions.len() <= 2);
        assert_eq!(result.total_count, 5);
    }

    #[test]
    fn test_query_empty_result() {
        let (_tmp, store) = setup();

        let result = store.query_sessions(&SessionQuery::default()).unwrap();
        assert_eq!(result.total_count, 0);
        assert!(result.sessions.is_empty());
    }
}
