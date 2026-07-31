//! FTS5 全文搜索
//! 权威：D4 §5

use std::path::Path;
use std::sync::Mutex;
use std::time::Duration;

use rusqlite::{params, Connection, OptionalExtension, TransactionBehavior};

/// 搜索结果
#[derive(Debug, Clone)]
pub struct SearchResult {
    pub session_id: String,
    pub snippet: String,
    pub rank: f64,
}

/// 搜索存储
pub struct SearchStore {
    conn: Mutex<Connection>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RealtimeSearchProjectionOutcome {
    Replaced,
    SkippedAsyncReady,
}

impl SearchStore {
    pub fn new(db_path: &Path) -> Result<Self, SearchStoreError> {
        let conn = Connection::open(db_path)?;
        conn.busy_timeout(Duration::from_secs(1))?;
        crate::migration::run_migrations(&conn)?;
        Ok(Self {
            conn: Mutex::new(conn),
        })
    }

    /// 索引会话内容
    pub fn index_session(&self, session_id: &str, content: &str) -> Result<(), SearchStoreError> {
        let mut conn = self.conn.lock().unwrap();
        let tx = conn.transaction()?;
        tx.execute(
            "DELETE FROM search_index WHERE session_id = ?1",
            [session_id],
        )?;
        tx.execute(
            "INSERT INTO search_index (session_id, content) VALUES (?1, ?2)",
            rusqlite::params![session_id, content],
        )?;
        tx.commit()?;
        Ok(())
    }

    /// Atomically installs the post-stop transcript and publishes the Ready
    /// authority bit in the same main-database transaction. Revalidating the
    /// exact immutable receipt under `BEGIN IMMEDIATE` prevents a realtime
    /// writer from slipping between the FTS replace and the Ready transition.
    pub fn replace_session_from_async_receipt(
        &self,
        session_id: &str,
        task_id: &str,
        output_sha256: &str,
        content: &str,
    ) -> Result<(), SearchStoreError> {
        let mut conn = self.conn.lock().unwrap();
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let purge_exists = tx.query_row(
            "SELECT EXISTS(
                 SELECT 1 FROM session_purge_jobs WHERE session_id = ?1
             )",
            [session_id],
            |row| row.get::<_, bool>(0),
        )?;
        if purge_exists {
            return Err(SearchStoreError::ProjectionConflict(format!(
                "session {session_id} is pending permanent deletion"
            )));
        }
        let receipt = tx
            .query_row(
                "SELECT async_task_id, async_provider_output_sha256,
                        async_search_projection_state
                 FROM notebook_capture_runs
                 WHERE session_id = ?1
                   AND async_provider_output_sha256 IS NOT NULL",
                [session_id],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, String>(2)?,
                    ))
                },
            )
            .optional()?
            .ok_or_else(|| {
                SearchStoreError::ProjectionConflict(format!(
                    "provider success receipt for session {session_id} is missing"
                ))
            })?;
        if receipt.0 != task_id || receipt.1 != output_sha256 {
            return Err(SearchStoreError::ProjectionConflict(format!(
                "provider success receipt for session {session_id} changed"
            )));
        }
        if !matches!(receipt.2.as_str(), "pending" | "failed" | "ready") {
            return Err(SearchStoreError::ProjectionConflict(format!(
                "session {session_id} search projection is {}",
                receipt.2
            )));
        }
        replace_session_in_transaction(&tx, session_id, content)?;
        tx.execute(
            "UPDATE notebook_capture_runs
             SET async_search_projection_state = 'ready', updated_at = ?1
             WHERE session_id = ?2
               AND async_task_id = ?3
               AND async_provider_output_sha256 = ?4
               AND async_search_projection_state IN ('pending', 'failed', 'ready')",
            params![
                chrono::Utc::now().to_rfc3339(),
                session_id,
                task_id,
                output_sha256
            ],
        )?;
        tx.commit()?;
        Ok(())
    }

    /// Replaces the realtime search document only while post-stop search has
    /// not become authoritative. The Ready check and FTS replace share one
    /// `BEGIN IMMEDIATE`, so every serialization order converges to async
    /// content once Ready is visible.
    pub fn replace_session_from_realtime_unless_async_ready(
        &self,
        session_id: &str,
        content: &str,
    ) -> Result<RealtimeSearchProjectionOutcome, SearchStoreError> {
        let mut conn = self.conn.lock().unwrap();
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let state = tx
            .query_row(
                "SELECT async_search_projection_state
                 FROM notebook_capture_runs
                 WHERE session_id = ?1
                   AND NOT EXISTS (
                       SELECT 1 FROM session_purge_jobs
                       WHERE session_id = notebook_capture_runs.session_id
                   )",
                [session_id],
                |row| row.get::<_, String>(0),
            )
            .optional()?
            .ok_or_else(|| {
                SearchStoreError::ProjectionConflict(format!(
                    "capture session {session_id} is missing or pending permanent deletion"
                ))
            })?;
        if state == "ready" {
            tx.commit()?;
            return Ok(RealtimeSearchProjectionOutcome::SkippedAsyncReady);
        }
        replace_session_in_transaction(&tx, session_id, content)?;
        tx.commit()?;
        Ok(RealtimeSearchProjectionOutcome::Replaced)
    }

    /// 全文搜索
    ///
    /// 英文使用 FTS5 MATCH（带排名和高亮）。
    /// CJK 降级为 LIKE 子串匹配——unicode61 对无空格语言分词不可靠。
    pub fn search(&self, query: &str, limit: usize) -> Result<Vec<SearchResult>, SearchStoreError> {
        let conn = self.conn.lock().unwrap();

        let has_cjk = query.chars().any(|c| {
            matches!(c,
                '\u{4E00}'..='\u{9FFF}'
                | '\u{3040}'..='\u{309F}'
                | '\u{30A0}'..='\u{30FF}'
                | '\u{AC00}'..='\u{D7AF}'
            )
        });

        if has_cjk {
            let pattern = format!("%{query}%");
            let mut stmt = conn.prepare(
                "SELECT session_id, content, 0.0
                 FROM search_index
                 WHERE content LIKE ?1
                 LIMIT ?2",
            )?;
            let results = stmt
                .query_map(rusqlite::params![pattern, limit as i64], |row| {
                    Ok(SearchResult {
                        session_id: row.get(0)?,
                        snippet: row.get(1)?,
                        rank: row.get(2)?,
                    })
                })?
                .filter_map(|r| r.ok())
                .collect();
            Ok(results)
        } else {
            let mut stmt = conn.prepare(
                "SELECT session_id, snippet(search_index, 1, '<b>', '</b>', '...', 32), rank
                 FROM search_index
                 WHERE search_index MATCH ?1
                 ORDER BY rank
                 LIMIT ?2",
            )?;
            let results = stmt
                .query_map(rusqlite::params![query, limit as i64], |row| {
                    Ok(SearchResult {
                        session_id: row.get(0)?,
                        snippet: row.get(1)?,
                        rank: row.get(2)?,
                    })
                })?
                .filter_map(|r| r.ok())
                .collect();
            Ok(results)
        }
    }

    /// 删除索引
    pub fn remove_session(&self, session_id: &str) -> Result<(), SearchStoreError> {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "DELETE FROM search_index WHERE session_id = ?1",
            [session_id],
        )?;
        Ok(())
    }
}

#[derive(Debug, thiserror::Error)]
pub enum SearchStoreError {
    #[error("database error: {0}")]
    DbError(String),
    #[error("search projection conflict: {0}")]
    ProjectionConflict(String),
}

impl From<rusqlite::Error> for SearchStoreError {
    fn from(e: rusqlite::Error) -> Self {
        SearchStoreError::DbError(e.to_string())
    }
}

fn replace_session_in_transaction(
    tx: &rusqlite::Transaction<'_>,
    session_id: &str,
    content: &str,
) -> Result<(), rusqlite::Error> {
    tx.execute(
        "DELETE FROM search_index WHERE session_id = ?1",
        [session_id],
    )?;
    tx.execute(
        "INSERT INTO search_index (session_id, content) VALUES (?1, ?2)",
        params![session_id, content],
    )?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    fn setup() -> (TempDir, SearchStore) {
        let tmp = TempDir::new().unwrap();
        let store = SearchStore::new(&tmp.path().join("search.db")).unwrap();
        (tmp, store)
    }

    #[test]
    fn test_search_english() {
        let (_tmp, store) = setup();
        store
            .index_session(
                "s1",
                "Today we reviewed notebook transcription and audio quality",
            )
            .unwrap();
        store
            .index_session("s2", "The weather is nice today for a picnic")
            .unwrap();

        let results = store.search("transcription", 10).unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].session_id, "s1");
    }

    #[test]
    fn test_search_chinese() {
        let (_tmp, store) = setup();
        // FTS5 unicode61 tokenizes CJK as individual characters
        // Search for individual character or use phrase query
        store
            .index_session("s1", "今天 讨论了 产品 路线图")
            .unwrap();
        store.index_session("s2", "明天 去 野餐").unwrap();

        let results = store.search("产品", 10).unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].session_id, "s1");
    }

    #[test]
    fn test_search_with_highlight() {
        let (_tmp, store) = setup();
        store
            .index_session("s1", "We need to finalize the MVP before next sprint")
            .unwrap();

        let results = store.search("MVP", 10).unwrap();
        assert_eq!(results.len(), 1);
        assert!(results[0].snippet.contains("<b>"));
    }

    #[test]
    fn test_search_no_results() {
        let (_tmp, store) = setup();
        store.index_session("s1", "Hello world").unwrap();

        let results = store.search("nonexistent", 10).unwrap();
        assert!(results.is_empty());
    }

    #[test]
    fn test_search_update_on_edit() {
        let (_tmp, store) = setup();
        store.index_session("s1", "Original content").unwrap();

        // Update
        store
            .index_session("s1", "Updated content with MVP")
            .unwrap();

        let results = store.search("Original", 10).unwrap();
        assert!(results.is_empty(), "old content should be gone");

        let results = store.search("MVP", 10).unwrap();
        assert_eq!(results.len(), 1);
    }
}
