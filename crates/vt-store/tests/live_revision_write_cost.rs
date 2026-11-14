//! What one live revision of a transcript row costs on disk.
//!
//! A recording revises its newest row several times a second: Soniox sends
//! Chinese one or two characters at a time. Each revision commits a SQLite
//! transaction, and in write-ahead-log mode a commit appends every page it
//! touched (4 KiB each) however little of the page changed.
//!
//! A three-hour, three-language recording wrote 2.1 GB and tripped macOS's
//! disk-writes report. A revision then touched six pages: the row, its
//! source variant, and four index pages that did not need to change — the
//! speaker index, rewritten because the speaker column was re-assigned the
//! same value, and the variant's three indexes, rewritten because the
//! variant was deleted and inserted again. These tests hold a revision to
//! the two pages that actually change.

use std::path::{Path, PathBuf};

use rusqlite::Connection;
use vt_store::notebook_capture_store::{
    CaptureProviderRole, SONIOX_PROVIDER_ID, SONIOX_REALTIME_MODEL_IDS,
};
use vt_store::*;

const SENTENCE: &str = "我们今天主要讨论一下这个项目接下来三个月的安排以及每个人负责的部分";

struct Fixture {
    _temp: tempfile::TempDir,
    db: PathBuf,
    store: NotebookCaptureStore,
    session: String,
    speaker: String,
}

fn fixture() -> Fixture {
    let temp = tempfile::tempdir().unwrap();
    let db = temp.path().join("capture.db");
    let notebook_store = NotebookStore::new(&db).unwrap();
    let notebook = notebook_store.create_notebook(Some("Capture")).unwrap();
    let store = NotebookCaptureStore::new(&db).unwrap();
    store.get_or_create_profile(&notebook.id).unwrap();
    let profile = store.get_profile(&notebook.id).unwrap().unwrap();
    let session = "session-write-cost".to_string();
    store
        .create_session_and_run(
            &SessionRecord {
                id: session.clone(),
                title: "Recording".into(),
                session_type: "recording".into(),
                status: "recording".into(),
                duration_ms: 0,
                created_at: "2001-01-02T00:00:01Z".into(),
                deleted_at: None,
            },
            &NewNotebookCaptureRun {
                id: "run-write-cost".into(),
                notebook_id: notebook.id.clone(),
                session_id: session.clone(),
                remote_health: RemoteHealth::Off,
                audio_journal_path: "/tmp/write-cost.journal".into(),
                audio_key_ref: "audio-key-write-cost".into(),
                sample_rate: 16_000,
                sample_format: "s16".to_string(),
                channels: 1,
            },
            &profile,
        )
        .unwrap();
    store
        .claim_provider_provenance(
            &session,
            CaptureProviderRole::Realtime,
            SONIOX_PROVIDER_ID,
            SONIOX_REALTIME_MODEL_IDS.last().unwrap(),
        )
        .unwrap();
    let speaker = store
        .ensure_session_speaker(&session, 0, "soniox", "1")
        .unwrap()
        .id;
    Fixture {
        _temp: temp,
        db,
        store,
        session,
        speaker,
    }
}

/// Pages written to the log since the last call; empties the log after.
fn pages_written(db: &Path) -> u64 {
    let wal = db.with_extension("db-wal");
    let bytes = std::fs::metadata(&wal).map(|meta| meta.len()).unwrap_or(0);
    // A 32-byte file header, then one 24-byte header plus the page per frame.
    let pages = bytes.saturating_sub(32) / (4096 + 24);
    let conn = Connection::open(db).unwrap();
    let busy: i64 = conn
        .query_row("PRAGMA wal_checkpoint(TRUNCATE)", [], |row| row.get(0))
        .unwrap();
    assert_eq!(busy, 0, "the log could not be emptied");
    pages
}

fn revision(
    fixture: &Fixture,
    sequence: u64,
    language: &str,
    text: &str,
    speaker: Option<&str>,
    completion: UtteranceCompletion,
    expected_revision: Option<u64>,
) -> RealtimeUtterance {
    fixture
        .store
        .upsert_utterance(
            &NewRealtimeUtterance {
                id: format!("utt-{sequence}"),
                session_id: fixture.session.clone(),
                sequence,
                session_speaker_id: speaker.map(str::to_string),
                source_language: language.into(),
                source_text: text.into(),
                source_start_ms: Some(sequence * 5_000),
                source_end_ms: Some(sequence * 5_000 + 4_000),
                translated_language: None,
                translated_text: None,
                completion,
                alignment: UtteranceAlignment::TranslationPending,
            },
            expected_revision,
        )
        .unwrap()
}

#[test]
fn a_partial_revision_writes_only_the_row_and_its_source_variant() {
    let fixture = fixture();
    let speaker = Some(fixture.speaker.as_str());
    let chars: Vec<char> = SENTENCE.chars().collect();
    // Some earlier rows, so the session is not a single-page toy.
    for sequence in 0..200 {
        revision(
            &fixture,
            sequence,
            "zh",
            SENTENCE,
            speaker,
            UtteranceCompletion::Complete,
            None,
        );
    }
    let sequence = 200;
    let mut row = revision(
        &fixture,
        sequence,
        "zh",
        "我们",
        speaker,
        UtteranceCompletion::Partial,
        None,
    );
    pages_written(&fixture.db);

    for step in 1..=12 {
        let text: String = chars[..(2 + step * 2).min(chars.len())].iter().collect();
        row = revision(
            &fixture,
            sequence,
            "zh",
            &text,
            speaker,
            UtteranceCompletion::Partial,
            Some(row.revision),
        );
        assert_eq!(
            pages_written(&fixture.db),
            2,
            "partial revision {step} rewrote pages beyond the row and its source variant"
        );
    }
    assert_eq!(row.source_text.chars().count(), 26);

    revision(
        &fixture,
        sequence,
        "zh",
        SENTENCE,
        speaker,
        UtteranceCompletion::Complete,
        Some(row.revision),
    );
    // The Final also records the row's projection revision.
    assert!(
        pages_written(&fixture.db) <= 3,
        "a Final revision rewrote index pages"
    );
}

#[test]
fn a_revision_still_applies_speaker_and_language_changes() {
    let fixture = fixture();
    let other = fixture
        .store
        .ensure_session_speaker(&fixture.session, 0, "soniox", "2")
        .unwrap()
        .id;
    let first = revision(
        &fixture,
        0,
        "en",
        "We",
        Some(&fixture.speaker),
        UtteranceCompletion::Partial,
        None,
    );
    // Language identification revises en -> zh and diarization the speaker.
    let second = revision(
        &fixture,
        0,
        "zh",
        "我们",
        Some(&other),
        UtteranceCompletion::Partial,
        Some(first.revision),
    );
    assert_eq!(second.revision, first.revision + 1);
    assert_eq!(second.session_speaker_id.as_deref(), Some(other.as_str()));
    assert_eq!(second.source_language, "zh");
    let sources: Vec<_> = second
        .variants
        .iter()
        .filter(|variant| variant.role == UtteranceVariantRole::Source)
        .collect();
    assert_eq!(sources.len(), 1, "exactly one source variant survives");
    assert_eq!(sources[0].language, "zh");
    assert_eq!(sources[0].text.as_deref(), Some("我们"));
    assert_eq!(sources[0].revision, second.revision);

    // Back to no speaker: the change is applied, not skipped as "unchanged".
    let third = revision(
        &fixture,
        0,
        "zh",
        "我们今天",
        None,
        UtteranceCompletion::Partial,
        Some(second.revision),
    );
    assert_eq!(third.session_speaker_id, None);
    assert_eq!(third.revision, second.revision + 1);

    // A stale revision still conflicts.
    let stale = fixture.store.upsert_utterance(
        &NewRealtimeUtterance {
            id: "utt-0".into(),
            session_id: fixture.session.clone(),
            sequence: 0,
            session_speaker_id: Some(fixture.speaker.clone()),
            source_language: "zh".into(),
            source_text: "我们今天开会".into(),
            source_start_ms: Some(0),
            source_end_ms: Some(4_000),
            translated_language: None,
            translated_text: None,
            completion: UtteranceCompletion::Partial,
            alignment: UtteranceAlignment::TranslationPending,
        },
        Some(first.revision),
    );
    assert!(matches!(stale, Err(NotebookCaptureStoreError::Conflict(_))));
    let current = fixture
        .store
        .list_utterances(&fixture.session)
        .unwrap()
        .into_iter()
        .find(|row| row.sequence == 0)
        .unwrap();
    assert_eq!(
        current.session_speaker_id, None,
        "a conflicting revision must not have moved the speaker"
    );
    assert_eq!(current.source_text, "我们今天");
}
