//! Bulk repair of the recorded absolute paths of session audio.
//!
//! Three tables independently record where a session's encrypted audio lives on
//! disk. When the on-disk layout changes, all three have to be rewritten
//! together or a session becomes partially unreadable. This module owns the SQL
//! for that rewrite; the caller owns the filesystem layout and decides, per row,
//! what the new path should be.

use std::path::Path;

use rusqlite::Connection;

/// Applies `relocate` to every recorded audio path. `relocate` receives
/// `(session_id, recorded_path)` and returns the replacement path, or `None` to
/// leave the row untouched. All rewrites commit in one transaction, so a
/// session never ends up with some tables pointing at the old location and
/// others at the new one.
///
/// Returns the number of rewritten rows.
pub fn repair_recorded_audio_paths(
    db_path: &Path,
    relocate: impl Fn(&str, &str) -> Option<String>,
) -> Result<u64, rusqlite::Error> {
    const REWRITES: [(&str, &str); 4] = [
        (
            "SELECT session_id, chunk_id, local_path FROM audio_retention_chunks
             WHERE local_path IS NOT NULL",
            "UPDATE audio_retention_chunks SET local_path = ?2 WHERE chunk_id = ?1",
        ),
        (
            "SELECT session_id, session_id, encrypted_path FROM session_meta
             WHERE encrypted_path IS NOT NULL",
            "UPDATE session_meta SET encrypted_path = ?2 WHERE session_id = ?1",
        ),
        (
            "SELECT session_id, id, audio_path FROM notebook_capture_runs
             WHERE audio_path IS NOT NULL",
            "UPDATE notebook_capture_runs SET audio_path = ?2 WHERE id = ?1",
        ),
        (
            "SELECT session_id, id, audio_journal_path FROM notebook_capture_runs
             WHERE audio_journal_path IS NOT NULL",
            "UPDATE notebook_capture_runs SET audio_journal_path = ?2 WHERE id = ?1",
        ),
    ];

    let mut conn = Connection::open(db_path)?;
    let transaction = conn.transaction()?;
    let mut rewritten = 0_u64;
    for (select, update) in REWRITES {
        let pending = {
            let mut statement = transaction.prepare(select)?;
            let rows = statement.query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                ))
            })?;
            let mut pending = Vec::new();
            for row in rows {
                let (session_id, key, recorded) = row?;
                if let Some(relocated) = relocate(&session_id, &recorded) {
                    pending.push((key, relocated));
                }
            }
            pending
        };
        for (key, relocated) in pending {
            rewritten += transaction.execute(update, rusqlite::params![key, relocated])? as u64;
        }
    }
    transaction.commit()?;
    Ok(rewritten)
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    fn seed(db_path: &Path, session_id: &str, recorded: &str) {
        let connection = Connection::open(db_path).unwrap();
        crate::migration::run_migrations(&connection).unwrap();
        connection
            .execute(
                "INSERT INTO session_meta (session_id, encrypted_path, key_id)
                 VALUES (?1, ?2, 'audio-key')",
                rusqlite::params![session_id, recorded],
            )
            .unwrap();
        connection
            .execute(
                "INSERT INTO audio_retention_chunks (
                     session_id, chunk_id, start_ms, end_ms, local_path, encrypted,
                     deleted, retention_deadline_ms
                 ) VALUES (?1, ?2, 0, 1, ?3, 1, 0, 0)",
                rusqlite::params![session_id, format!("{session_id}:audio:00000"), recorded],
            )
            .unwrap();
    }

    #[test]
    fn every_recorded_path_of_a_session_is_rewritten_together() {
        let temp = TempDir::new().unwrap();
        let db_path = temp.path().join("zulangue.db");
        seed(&db_path, "session-a", "/data/session-a.chunk.00000.enc");

        let rewritten = repair_recorded_audio_paths(&db_path, |session_id, recorded| {
            assert_eq!(session_id, "session-a");
            Some(recorded.replace("session-a.chunk.", "audio/session-a/chunk."))
        })
        .unwrap();

        assert_eq!(rewritten, 2);
        let connection = Connection::open(&db_path).unwrap();
        assert_eq!(
            connection
                .query_row("SELECT encrypted_path FROM session_meta", [], |row| row
                    .get::<_, String>(
                    0
                ))
                .unwrap(),
            "/data/audio/session-a/chunk.00000.enc"
        );
        assert_eq!(
            connection
                .query_row("SELECT local_path FROM audio_retention_chunks", [], |row| {
                    row.get::<_, String>(0)
                })
                .unwrap(),
            "/data/audio/session-a/chunk.00000.enc"
        );
    }

    #[test]
    fn declining_a_row_leaves_it_untouched() {
        let temp = TempDir::new().unwrap();
        let db_path = temp.path().join("zulangue.db");
        seed(&db_path, "session-b", "/data/already/canonical.enc");

        let rewritten = repair_recorded_audio_paths(&db_path, |_, _| None).unwrap();

        assert_eq!(rewritten, 0);
        assert_eq!(
            Connection::open(&db_path)
                .unwrap()
                .query_row("SELECT encrypted_path FROM session_meta", [], |row| row
                    .get::<_, String>(
                    0
                ))
                .unwrap(),
            "/data/already/canonical.enc"
        );
    }
}
