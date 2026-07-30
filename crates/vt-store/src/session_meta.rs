//! Session 本地音频与转录 token 元数据存储。

use std::path::Path;
use std::sync::Mutex;

use rusqlite::Connection;
use vt_model::Token;

/// Session 元数据
#[derive(Debug, Clone, Default)]
pub struct SessionMeta {
    pub session_id: String,
    pub encrypted_path: Option<String>,
    pub key_id: Option<String>,
    pub tokens_json: Option<String>,
    /// "standard" | "high" | "maximum"
    pub privacy_level: Option<String>,
    /// 加密音频 PCM 的采样率 (Hz)。
    pub sample_rate: Option<u32>,
    /// 加密音频 PCM 的声道数。
    pub channels: Option<u16>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AudioChunkRetentionRecord {
    pub session_id: String,
    pub chunk_id: String,
    pub start_ms: u64,
    pub end_ms: u64,
    pub local_path: String,
    pub encrypted: bool,
    pub deleted: bool,
    pub retention_deadline_ms: i64,
    pub delete_error: Option<String>,
    pub deleted_at_ms: Option<i64>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct AudioRetentionCounts {
    pub due_count: u64,
    pub failed_count: u64,
    pub deleted_count: u64,
}

/// Session 元数据存储
pub struct SessionMetaStore {
    conn: Mutex<Connection>,
}

impl SessionMetaStore {
    pub fn new(db_path: &Path) -> Result<Self, SessionMetaError> {
        let conn = Connection::open(db_path)?;
        crate::migration::run_migrations(&conn)?;
        Ok(Self {
            conn: Mutex::new(conn),
        })
    }

    pub fn set_encrypted_path(
        &self,
        session_id: &str,
        path: &str,
        key_id: &str,
    ) -> Result<(), SessionMetaError> {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "INSERT INTO session_meta (session_id, encrypted_path, key_id)
             VALUES (?1, ?2, ?3)
             ON CONFLICT(session_id) DO UPDATE SET encrypted_path=?2, key_id=?3",
            rusqlite::params![session_id, path, key_id],
        )?;
        Ok(())
    }

    pub fn set_tokens(&self, session_id: &str, tokens: &[Token]) -> Result<(), SessionMetaError> {
        let json = serde_json::to_string(tokens)
            .map_err(|e| SessionMetaError::SerializeError(e.to_string()))?;
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "INSERT INTO session_meta (session_id, tokens_json)
             VALUES (?1, ?2)
             ON CONFLICT(session_id) DO UPDATE SET tokens_json=?2",
            rusqlite::params![session_id, json],
        )?;
        Ok(())
    }

    /// 记录加密音频 PCM 的格式 (sample_rate, channels)。
    /// 用于 get_audio_segment / export_session_zip 重建可播放 WAV。
    pub fn set_audio_format(
        &self,
        session_id: &str,
        sample_rate: u32,
        channels: u16,
    ) -> Result<(), SessionMetaError> {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "INSERT INTO session_meta (session_id, sample_rate, channels)
             VALUES (?1, ?2, ?3)
             ON CONFLICT(session_id) DO UPDATE SET sample_rate=?2, channels=?3",
            rusqlite::params![session_id, sample_rate, channels],
        )?;
        Ok(())
    }

    pub fn set_privacy_level(&self, session_id: &str, level: &str) -> Result<(), SessionMetaError> {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "INSERT INTO session_meta (session_id, privacy_level)
             VALUES (?1, ?2)
             ON CONFLICT(session_id) DO UPDATE SET privacy_level=?2",
            rusqlite::params![session_id, level],
        )?;
        Ok(())
    }

    pub fn clear_encrypted_path(&self, session_id: &str) -> Result<(), SessionMetaError> {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "UPDATE session_meta SET encrypted_path=NULL, key_id=NULL WHERE session_id=?1",
            [session_id],
        )?;
        Ok(())
    }

    pub fn upsert_audio_retention_chunk(
        &self,
        record: &AudioChunkRetentionRecord,
    ) -> Result<(), SessionMetaError> {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "INSERT INTO audio_retention_chunks (
                session_id, chunk_id, start_ms, end_ms, local_path, encrypted,
                deleted, retention_deadline_ms, delete_error, deleted_at_ms
             ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
             ON CONFLICT(session_id, chunk_id) DO UPDATE SET
                start_ms=?3,
                end_ms=?4,
                local_path=?5,
                encrypted=?6,
                deleted=?7,
                retention_deadline_ms=?8,
                delete_error=?9,
                deleted_at_ms=?10",
            rusqlite::params![
                &record.session_id,
                &record.chunk_id,
                record.start_ms as i64,
                record.end_ms as i64,
                &record.local_path,
                if record.encrypted { 1_i64 } else { 0_i64 },
                if record.deleted { 1_i64 } else { 0_i64 },
                record.retention_deadline_ms,
                record.delete_error.as_deref(),
                record.deleted_at_ms,
            ],
        )?;
        Ok(())
    }

    pub fn list_audio_retention_chunks(
        &self,
        session_id: &str,
    ) -> Result<Vec<AudioChunkRetentionRecord>, SessionMetaError> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(
            "SELECT session_id, chunk_id, start_ms, end_ms, local_path, encrypted,
                    deleted, retention_deadline_ms, delete_error, deleted_at_ms
             FROM audio_retention_chunks
             WHERE session_id = ?1
             ORDER BY start_ms ASC, chunk_id ASC",
        )?;
        let rows = stmt.query_map([session_id], Self::map_audio_retention_chunk)?;
        let mut out = Vec::new();
        for row in rows {
            out.push(row?);
        }
        Ok(out)
    }

    pub fn list_due_audio_retention_chunks(
        &self,
        now_ms: i64,
    ) -> Result<Vec<AudioChunkRetentionRecord>, SessionMetaError> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(
            "SELECT session_id, chunk_id, start_ms, end_ms, local_path, encrypted,
                    deleted, retention_deadline_ms, delete_error, deleted_at_ms
             FROM audio_retention_chunks
             WHERE deleted = 0 AND retention_deadline_ms <= ?1
             ORDER BY retention_deadline_ms ASC, session_id ASC, start_ms ASC",
        )?;
        let rows = stmt.query_map([now_ms], Self::map_audio_retention_chunk)?;
        let mut out = Vec::new();
        for row in rows {
            out.push(row?);
        }
        Ok(out)
    }

    pub fn get_audio_retention_counts(
        &self,
        now_ms: i64,
    ) -> Result<AudioRetentionCounts, SessionMetaError> {
        let conn = self.conn.lock().unwrap();
        let due_count = conn.query_row(
            "SELECT COUNT(*)
             FROM audio_retention_chunks
             WHERE deleted = 0 AND retention_deadline_ms <= ?1",
            [now_ms],
            |row| row.get::<_, i64>(0),
        )?;
        let failed_count = conn.query_row(
            "SELECT COUNT(*)
             FROM audio_retention_chunks
             WHERE deleted = 0 AND delete_error IS NOT NULL",
            [],
            |row| row.get::<_, i64>(0),
        )?;
        let deleted_count = conn.query_row(
            "SELECT COUNT(*)
             FROM audio_retention_chunks
             WHERE deleted = 1",
            [],
            |row| row.get::<_, i64>(0),
        )?;
        Ok(AudioRetentionCounts {
            due_count: due_count as u64,
            failed_count: failed_count as u64,
            deleted_count: deleted_count as u64,
        })
    }

    pub fn mark_audio_retention_chunk_deleted(
        &self,
        session_id: &str,
        chunk_id: &str,
        deleted_at_ms: i64,
    ) -> Result<(), SessionMetaError> {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "UPDATE audio_retention_chunks
             SET deleted = 1, deleted_at_ms = ?3, delete_error = NULL
             WHERE session_id = ?1 AND chunk_id = ?2",
            rusqlite::params![session_id, chunk_id, deleted_at_ms],
        )?;
        Ok(())
    }

    pub fn mark_audio_retention_chunk_delete_failed(
        &self,
        session_id: &str,
        chunk_id: &str,
        error: &str,
    ) -> Result<(), SessionMetaError> {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "UPDATE audio_retention_chunks
             SET deleted = 0, delete_error = ?3
             WHERE session_id = ?1 AND chunk_id = ?2",
            rusqlite::params![session_id, chunk_id, error],
        )?;
        Ok(())
    }

    fn map_audio_retention_chunk(
        row: &rusqlite::Row<'_>,
    ) -> rusqlite::Result<AudioChunkRetentionRecord> {
        Ok(AudioChunkRetentionRecord {
            session_id: row.get(0)?,
            chunk_id: row.get(1)?,
            start_ms: row.get::<_, i64>(2)? as u64,
            end_ms: row.get::<_, i64>(3)? as u64,
            local_path: row.get(4)?,
            encrypted: row.get::<_, i64>(5)? != 0,
            deleted: row.get::<_, i64>(6)? != 0,
            retention_deadline_ms: row.get(7)?,
            delete_error: row.get(8)?,
            deleted_at_ms: row.get(9)?,
        })
    }

    pub fn get_meta(&self, session_id: &str) -> Result<SessionMeta, SessionMetaError> {
        let conn = self.conn.lock().unwrap();
        conn.query_row(
            "SELECT session_id, encrypted_path, key_id, tokens_json,
                    privacy_level, sample_rate, channels
             FROM session_meta WHERE session_id = ?1",
            [session_id],
            |row| {
                // channels 是 u16,SQLite 里存 INTEGER,读出 i64 再窄化
                let channels_i: Option<i64> = row.get(6)?;
                let channels: Option<u16> = channels_i.map(|v| v as u16);
                let sample_rate_i: Option<i64> = row.get(5)?;
                let sample_rate: Option<u32> = sample_rate_i.map(|v| v as u32);
                Ok(SessionMeta {
                    session_id: row.get(0)?,
                    encrypted_path: row.get(1)?,
                    key_id: row.get(2)?,
                    tokens_json: row.get(3)?,
                    privacy_level: row.get(4)?,
                    sample_rate,
                    channels,
                })
            },
        )
        .map_err(|e| match e {
            rusqlite::Error::QueryReturnedNoRows => {
                SessionMetaError::NotFound(session_id.to_string())
            }
            other => SessionMetaError::DbError(other.to_string()),
        })
    }

    pub fn get_tokens(&self, session_id: &str) -> Result<Vec<Token>, SessionMetaError> {
        let meta = self.get_meta(session_id)?;
        match meta.tokens_json {
            Some(json) => serde_json::from_str(&json)
                .map_err(|e| SessionMetaError::SerializeError(e.to_string())),
            None => Ok(vec![]),
        }
    }
}

#[derive(Debug, thiserror::Error)]
pub enum SessionMetaError {
    #[error("session not found: {0}")]
    NotFound(String),

    #[error("database error: {0}")]
    DbError(String),

    #[error("serialization error: {0}")]
    SerializeError(String),
}

impl From<rusqlite::Error> for SessionMetaError {
    fn from(e: rusqlite::Error) -> Self {
        SessionMetaError::DbError(e.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;
    use vt_model::TranslationStatus;

    fn setup() -> (TempDir, SessionMetaStore) {
        let tmp = TempDir::new().unwrap();
        let store = SessionMetaStore::new(&tmp.path().join("meta.db")).unwrap();
        (tmp, store)
    }

    #[test]
    fn test_set_and_get_encrypted_path() {
        let (_tmp, store) = setup();
        store
            .set_encrypted_path("s1", "/data/s1.enc", "key-abc")
            .unwrap();

        let meta = store.get_meta("s1").unwrap();
        assert_eq!(meta.encrypted_path.as_deref(), Some("/data/s1.enc"));
        assert_eq!(meta.key_id.as_deref(), Some("key-abc"));
    }

    #[test]
    fn test_set_and_get_tokens() {
        let (_tmp, store) = setup();

        let tokens = vec![
            Token {
                text: "Hello".to_string(),
                start_ms: 0,
                end_ms: 500,
                is_final: true,
                language: "en".to_string(),
                speaker: None,
                confidence: 1.0,
                translation_status: TranslationStatus::None,
            },
            Token {
                text: " world".to_string(),
                start_ms: 500,
                end_ms: 1000,
                is_final: true,
                language: "en".to_string(),
                speaker: None,
                confidence: 1.0,
                translation_status: TranslationStatus::None,
            },
        ];

        store.set_tokens("s1", &tokens).unwrap();

        let loaded = store.get_tokens("s1").unwrap();
        assert_eq!(loaded.len(), 2);
        assert_eq!(loaded[0].text, "Hello");
        assert_eq!(loaded[1].start_ms, 500);
    }

    #[test]
    fn test_not_found() {
        let (_tmp, store) = setup();
        assert!(store.get_meta("nonexistent").is_err());
    }

    #[test]
    fn test_empty_tokens() {
        let (_tmp, store) = setup();
        store.set_encrypted_path("s1", "/path", "key").unwrap();
        let tokens = store.get_tokens("s1").unwrap();
        assert!(tokens.is_empty());
    }

    #[test]
    fn test_set_privacy_level() {
        let (_tmp, store) = setup();

        store.set_privacy_level("s1", "high").unwrap();
        let meta = store.get_meta("s1").unwrap();
        assert_eq!(meta.privacy_level.as_deref(), Some("high"));
    }

    #[test]
    fn test_clear_encrypted_path() {
        let (_tmp, store) = setup();
        store
            .set_encrypted_path("s1", "/data/s1.enc", "key-abc")
            .unwrap();

        store.clear_encrypted_path("s1").unwrap();

        let meta = store.get_meta("s1").unwrap();
        assert!(meta.encrypted_path.is_none());
        assert!(meta.key_id.is_none());
    }

    #[test]
    fn test_audio_retention_chunks_record_delete_and_failures_are_queryable() {
        let (_tmp, store) = setup();
        store
            .upsert_audio_retention_chunk(&AudioChunkRetentionRecord {
                session_id: "s1".to_string(),
                chunk_id: "s1:audio:00000".to_string(),
                start_ms: 0,
                end_ms: 60_000,
                local_path: "/data/s1.chunk0.enc".to_string(),
                encrypted: true,
                deleted: false,
                retention_deadline_ms: 1_234,
                delete_error: None,
                deleted_at_ms: None,
            })
            .unwrap();

        let chunks = store.list_audio_retention_chunks("s1").unwrap();
        assert_eq!(chunks.len(), 1);
        assert_eq!(chunks[0].chunk_id, "s1:audio:00000");
        assert_eq!(chunks[0].retention_deadline_ms, 1_234);
        assert!(chunks[0].encrypted);
        assert!(!chunks[0].deleted);
        assert_eq!(
            store.get_audio_retention_counts(1_234).unwrap(),
            AudioRetentionCounts {
                due_count: 1,
                failed_count: 0,
                deleted_count: 0,
            }
        );

        store
            .mark_audio_retention_chunk_delete_failed("s1", "s1:audio:00000", "permission denied")
            .unwrap();
        let failed = store.list_audio_retention_chunks("s1").unwrap();
        assert_eq!(failed[0].delete_error.as_deref(), Some("permission denied"));
        assert!(!failed[0].deleted);
        assert_eq!(
            store.get_audio_retention_counts(1_234).unwrap(),
            AudioRetentionCounts {
                due_count: 1,
                failed_count: 1,
                deleted_count: 0,
            }
        );

        store
            .mark_audio_retention_chunk_deleted("s1", "s1:audio:00000", 2_000)
            .unwrap();
        let deleted = store.list_audio_retention_chunks("s1").unwrap();
        assert!(deleted[0].deleted);
        assert_eq!(deleted[0].deleted_at_ms, Some(2_000));
        assert!(deleted[0].delete_error.is_none());
        assert_eq!(
            store.get_audio_retention_counts(1_234).unwrap(),
            AudioRetentionCounts {
                due_count: 0,
                failed_count: 0,
                deleted_count: 1,
            }
        );
    }
}
