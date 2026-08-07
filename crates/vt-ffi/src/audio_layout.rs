//! Relocation of flat data-directory-root audio into per-session directories.
//!
//! Encrypted audio used to be written as `<data_dir>/<session>.chunk.NNNNN.enc`,
//! which left every session's artifacts interleaved in one directory and forced
//! deletion to enumerate that directory by filename prefix. The canonical layout
//! is now `<data_dir>/audio/<session>/chunk.NNNNN.enc` (see
//! `vt_pipeline::recording`), so a session owns exactly one directory.
//!
//! This runs on every startup and is idempotent. It moves whatever legacy files
//! remain, then repairs the recorded absolute paths **from what is actually on
//! disk** rather than from an assumption about what the move phase achieved. A
//! process loss part-way through therefore converges on the next launch, and a
//! move that fails for one session never strands the others.

use std::path::{Path, PathBuf};

/// Splits a legacy root-level audio file name into the session that owns it and
/// the name it takes inside that session's directory. Session ids are UUIDs and
/// contain no `.`, so the first `.chunk.` is an unambiguous separator.
fn classify_legacy_audio_file(name: &str) -> Option<(&str, String)> {
    let (session_id, relocated) = if let Some(rest) = name.strip_prefix('.') {
        // `.{session}.chunk.{index}.{uuid}.recovering`
        let tail = rest.strip_suffix(".recovering")?;
        let (session_id, chunk_tail) = tail.split_once(".chunk.")?;
        (session_id, format!(".chunk.{chunk_tail}.recovering"))
    } else if let Some(session_id) = name.strip_suffix(".capture-journal.enc") {
        (session_id, "capture-journal.enc".to_string())
    } else if name.ends_with(".enc") {
        let (session_id, chunk_tail) = name.split_once(".chunk.")?;
        (session_id, format!("chunk.{chunk_tail}"))
    } else {
        return None;
    };
    vt_pipeline::require_session_id_path_component(session_id).ok()?;
    Some((session_id, relocated))
}

/// The canonical location of a recorded path, or `None` when the path is not a
/// legacy root-level artifact of `session_id`.
fn relocated_legacy_path(data_dir: &Path, session_id: &str, recorded: &str) -> Option<PathBuf> {
    let recorded_path = Path::new(recorded);
    if recorded_path.parent() != Some(data_dir) {
        return None;
    }
    let (owner, relocated) = classify_legacy_audio_file(recorded_path.file_name()?.to_str()?)?;
    if owner != session_id {
        return None;
    }
    Some(vt_pipeline::session_audio_dir(data_dir, session_id).join(relocated))
}

/// Best-effort: a relocation failure is logged and retried next launch rather
/// than blocking startup, because the readers still resolve legacy paths.
pub(crate) fn relocate_legacy_session_audio(data_dir: &Path, db_path: &Path) {
    let moved = move_legacy_files(data_dir);
    if moved > 0 {
        tracing::info!(
            moved,
            "relocated legacy session audio into per-session directories"
        );
    }
    if let Err(error) = repair_recorded_audio_paths(data_dir, db_path) {
        tracing::warn!(%error, "repair relocated session audio paths");
    }
}

fn move_legacy_files(data_dir: &Path) -> u64 {
    let Ok(entries) = std::fs::read_dir(data_dir) else {
        return 0;
    };
    let mut moved = 0_u64;
    for entry in entries.filter_map(Result::ok) {
        if entry.file_type().is_ok_and(|kind| kind.is_dir()) {
            continue;
        }
        let name = entry.file_name();
        let Some(name) = name.to_str() else {
            continue;
        };
        let Some((session_id, relocated)) = classify_legacy_audio_file(name) else {
            continue;
        };
        let destination = vt_pipeline::session_audio_dir(data_dir, session_id).join(&relocated);
        if destination.exists() {
            // A rename is atomic, so the source and destination cannot both be
            // the same committed artifact. Refuse to guess which one is real.
            tracing::warn!(
                session_id,
                artifact = relocated,
                "legacy audio artifact conflicts with an already relocated one; leaving both"
            );
            continue;
        }
        if let Err(error) =
            std::fs::create_dir_all(vt_pipeline::session_audio_dir(data_dir, session_id))
        {
            tracing::warn!(session_id, %error, "create session audio directory");
            continue;
        }
        match std::fs::rename(entry.path(), &destination) {
            Ok(()) => moved += 1,
            Err(error) => {
                tracing::warn!(session_id, %error, "relocate legacy session audio artifact");
            }
        }
    }
    moved
}

/// Rewrites every recorded absolute path whose canonical relocation now exists
/// on disk. A row whose file is still at the legacy location is left untouched,
/// so a partially completed move phase never points the database at a file that
/// is not there.
fn repair_recorded_audio_paths(data_dir: &Path, db_path: &Path) -> Result<u64, String> {
    vt_store::repair_recorded_audio_paths(db_path, |session_id, recorded| {
        let relocated = relocated_legacy_path(data_dir, session_id, recorded)?;
        relocated
            .exists()
            .then(|| relocated.to_string_lossy().into_owned())
    })
    .map_err(|error| error.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    #[test]
    fn legacy_names_map_to_their_session_directory() {
        assert_eq!(
            classify_legacy_audio_file("session-a.chunk.00007.enc"),
            Some(("session-a", "chunk.00007.enc".to_string()))
        );
        assert_eq!(
            classify_legacy_audio_file("session-a.capture-journal.enc"),
            Some(("session-a", "capture-journal.enc".to_string()))
        );
        assert_eq!(
            classify_legacy_audio_file(".session-a.chunk.00000.abcd.recovering"),
            Some(("session-a", ".chunk.00000.abcd.recovering".to_string()))
        );
    }

    #[test]
    fn unrelated_data_directory_files_are_never_relocated() {
        for name in [
            "zulangue.db",
            "tasks.db",
            "debug.log",
            "editor-docs",
            "notes.enc",
            ".zulangue-core.lock",
        ] {
            assert_eq!(
                classify_legacy_audio_file(name),
                None,
                "{name} must not be treated as legacy session audio"
            );
        }
    }

    #[test]
    fn a_session_id_that_escapes_the_data_directory_is_rejected() {
        assert_eq!(
            classify_legacy_audio_file("../escape.chunk.00000.enc"),
            None
        );
    }

    fn install_schema(db_path: &Path) -> rusqlite::Connection {
        let connection = rusqlite::Connection::open(db_path).unwrap();
        vt_store::migration::run_migrations(&connection).unwrap();
        connection
            .execute(
                "INSERT INTO notebooks (id, title, created_at, updated_at)
                 VALUES ('nb-1', 'Relocation', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')",
                [],
            )
            .unwrap();
        connection
    }

    fn record_paths(
        connection: &rusqlite::Connection,
        session_id: &str,
        chunk: &str,
        journal: &str,
    ) {
        connection
            .execute(
                "INSERT INTO audio_retention_chunks (
                     session_id, chunk_id, start_ms, end_ms, local_path, encrypted,
                     deleted, retention_deadline_ms
                 ) VALUES (?1, ?2, 0, 1, ?3, 1, 0, 0)",
                rusqlite::params![session_id, format!("{session_id}:audio:00000"), chunk],
            )
            .unwrap();
        connection
            .execute(
                "INSERT INTO session_meta (session_id, encrypted_path, key_id)
                 VALUES (?1, ?2, 'audio-key')",
                rusqlite::params![session_id, chunk],
            )
            .unwrap();
        connection
            .execute(
                "INSERT INTO notebook_capture_runs (
                     id, notebook_id, session_id, profile_revision, profile_snapshot_json,
                     capture_state, audio_path, audio_journal_path, created_at, updated_at
                 ) VALUES ('run-1', 'nb-1', ?1, 0, '{}', 'completed', ?2, ?3,
                           '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')",
                rusqlite::params![session_id, chunk, journal],
            )
            .unwrap();
    }

    fn single_value(db_path: &Path, query: &str) -> String {
        rusqlite::Connection::open(db_path)
            .unwrap()
            .query_row(query, [], |row| row.get::<_, String>(0))
            .unwrap()
    }

    #[test]
    fn relocation_moves_files_and_repairs_every_recorded_path() {
        let temp = TempDir::new().unwrap();
        let data_dir = temp.path();
        let db_path = data_dir.join("zulangue.db");
        let session_id = "0e6635be-db2d-4dbd-af11-b5ad84caabfe";
        let legacy_chunk = data_dir.join(format!("{session_id}.chunk.00000.enc"));
        let legacy_journal = data_dir.join(format!("{session_id}.capture-journal.enc"));
        std::fs::write(&legacy_chunk, b"chunk").unwrap();
        std::fs::write(&legacy_journal, b"journal").unwrap();
        std::fs::write(data_dir.join("unrelated.txt"), b"keep").unwrap();

        let connection = install_schema(&db_path);
        record_paths(
            &connection,
            session_id,
            legacy_chunk.to_str().unwrap(),
            legacy_journal.to_str().unwrap(),
        );
        drop(connection);

        relocate_legacy_session_audio(data_dir, &db_path);

        let session_dir = vt_pipeline::session_audio_dir(data_dir, session_id);
        let expected_chunk = session_dir.join("chunk.00000.enc");
        let expected_journal = session_dir.join("capture-journal.enc");
        assert!(expected_chunk.exists());
        assert!(expected_journal.exists());
        assert!(!legacy_chunk.exists());
        assert!(!legacy_journal.exists());
        assert!(
            data_dir.join("unrelated.txt").exists(),
            "relocation must not touch unrelated data directory files"
        );

        let expected_chunk = expected_chunk.to_string_lossy().into_owned();
        assert_eq!(
            single_value(&db_path, "SELECT local_path FROM audio_retention_chunks"),
            expected_chunk
        );
        assert_eq!(
            single_value(&db_path, "SELECT encrypted_path FROM session_meta"),
            expected_chunk
        );
        assert_eq!(
            single_value(&db_path, "SELECT audio_path FROM notebook_capture_runs"),
            expected_chunk
        );
        assert_eq!(
            single_value(
                &db_path,
                "SELECT audio_journal_path FROM notebook_capture_runs"
            ),
            expected_journal.to_string_lossy()
        );
    }

    #[test]
    fn relocation_is_idempotent() {
        let temp = TempDir::new().unwrap();
        let data_dir = temp.path();
        let db_path = data_dir.join("zulangue.db");
        let session_id = "2cb1f645-96b5-4825-97c3-59eb66a869f5";
        let legacy_chunk = data_dir.join(format!("{session_id}.chunk.00000.enc"));
        let legacy_journal = data_dir.join(format!("{session_id}.capture-journal.enc"));
        std::fs::write(&legacy_chunk, b"chunk").unwrap();
        std::fs::write(&legacy_journal, b"journal").unwrap();
        let connection = install_schema(&db_path);
        record_paths(
            &connection,
            session_id,
            legacy_chunk.to_str().unwrap(),
            legacy_journal.to_str().unwrap(),
        );
        drop(connection);

        relocate_legacy_session_audio(data_dir, &db_path);
        let after_first = single_value(&db_path, "SELECT local_path FROM audio_retention_chunks");
        relocate_legacy_session_audio(data_dir, &db_path);
        let after_second = single_value(&db_path, "SELECT local_path FROM audio_retention_chunks");

        assert_eq!(after_first, after_second);
        assert!(vt_pipeline::session_audio_dir(data_dir, session_id)
            .join("chunk.00000.enc")
            .exists());
    }

    #[test]
    fn a_row_whose_file_is_already_gone_keeps_its_recorded_path() {
        let temp = TempDir::new().unwrap();
        let data_dir = temp.path();
        let db_path = data_dir.join("zulangue.db");
        let session_id = "44cac720-8ea8-4bd1-8e61-45e3a8d53dc8";
        let legacy_chunk = data_dir.join(format!("{session_id}.chunk.00000.enc"));
        let legacy_journal = data_dir.join(format!("{session_id}.capture-journal.enc"));
        let connection = install_schema(&db_path);
        record_paths(
            &connection,
            session_id,
            legacy_chunk.to_str().unwrap(),
            legacy_journal.to_str().unwrap(),
        );
        drop(connection);

        // Retention already destroyed the audio, so there is nothing to move and
        // no recorded path may be rewritten to a file that does not exist.
        relocate_legacy_session_audio(data_dir, &db_path);

        assert_eq!(
            single_value(&db_path, "SELECT local_path FROM audio_retention_chunks"),
            legacy_chunk.to_string_lossy()
        );
    }
}
