//! Where an auxiliary lane's translation lands in the transcript.
//!
//! Each test is a case that went wrong on a live three-language recording:
//! a translation stuck on the wrong row, a withdrawn segment that emptied a
//! lane and then made the next source Final fail (which ended the whole
//! transcription group), or a revision that reported a live row as deleted.

use vt_store::notebook_capture_store::{
    CaptureProviderRole, SONIOX_PROVIDER_ID, SONIOX_STT_RT_V5_MODEL_ID,
};
use vt_store::*;

fn fixture(suffix: &str) -> (tempfile::TempDir, NotebookCaptureStore, String) {
    let temp = tempfile::tempdir().unwrap();
    let db = temp.path().join("capture.db");
    let notebook_store = NotebookStore::new(&db).unwrap();
    let notebook = notebook_store.create_notebook(Some("Capture")).unwrap();
    let store = NotebookCaptureStore::new(&db).unwrap();
    store.get_or_create_profile(&notebook.id).unwrap();
    let profile = store.get_profile(&notebook.id).unwrap().unwrap();
    let session_id = format!("session-{suffix}");
    let input = NewNotebookCaptureRun {
        id: format!("run-{suffix}"),
        notebook_id: notebook.id.clone(),
        session_id: session_id.clone(),
        remote_health: RemoteHealth::Off,
        audio_journal_path: format!("/tmp/{suffix}.journal"),
        audio_key_ref: format!("audio-key-{suffix}"),
        sample_rate: 16_000,
        sample_format: "s16".to_string(),
        channels: 1,
    };
    let session = SessionRecord {
        id: session_id.clone(),
        title: format!("Recording {suffix}"),
        session_type: "recording".into(),
        status: "recording".into(),
        duration_ms: 0,
        created_at: "2001-01-02T00:00:01Z".into(),
        deleted_at: None,
    };
    store
        .create_session_and_run(&session, &input, &profile)
        .unwrap();
    store
        .claim_provider_provenance(
            &session_id,
            CaptureProviderRole::Realtime,
            SONIOX_PROVIDER_ID,
            SONIOX_STT_RT_V5_MODEL_ID,
        )
        .unwrap();
    (temp, store, session_id)
}

#[allow(clippy::too_many_arguments)]
fn row(
    store: &NotebookCaptureStore,
    session: &str,
    sequence: u64,
    lang: &str,
    text: &str,
    start: u64,
    end: u64,
    completion: UtteranceCompletion,
) -> RealtimeUtterance {
    let expected = current(store, session, sequence).map(|row| row.revision);
    store
        .upsert_utterance(
            &NewRealtimeUtterance {
                id: format!("utt-{session}-{sequence}"),
                session_id: session.into(),
                sequence,
                session_speaker_id: None,
                source_language: lang.into(),
                source_text: text.into(),
                source_start_ms: Some(start),
                source_end_ms: Some(end),
                translated_language: None,
                translated_text: None,
                completion,
                alignment: UtteranceAlignment::TranslationPending,
            },
            expected,
        )
        .unwrap()
}

#[allow(clippy::too_many_arguments)]
fn fact(
    store: &NotebookCaptureStore,
    session: &str,
    seq: u64,
    target: &str,
    src_lang: &str,
    src: &str,
    start: u64,
    end: u64,
    translated: Option<&str>,
    completion: Option<UtteranceCompletion>,
) -> RealtimeTranslationInboxPersistence {
    store
        .upsert_translation_inbox_item(&NewRealtimeTranslationInboxItem {
            key: RealtimeTranslationInboxKey {
                session_id: session.into(),
                lane_index: 1,
                group_epoch: 0,
                provider_sequence: seq,
                target_language: target.into(),
            },
            source_language: src_lang.into(),
            source_text: src.into(),
            source_start_ms: Some(start),
            source_end_ms: Some(end),
            withdrawn: translated.is_none(),
            translated_text: translated.map(str::to_string),
            completion,
        })
        .unwrap()
}

fn current(
    store: &NotebookCaptureStore,
    session: &str,
    sequence: u64,
) -> Option<RealtimeUtterance> {
    store
        .list_utterances(session)
        .unwrap()
        .into_iter()
        .find(|row| row.sequence == sequence)
}

/// The lane's text and completion, or None when the row has no ready lane
/// in that language.
fn lane(
    store: &NotebookCaptureStore,
    session: &str,
    sequence: u64,
    language: &str,
) -> Option<(String, Option<UtteranceCompletion>)> {
    current(store, session, sequence)?
        .variants
        .into_iter()
        .find(|variant| {
            variant.language == language && variant.state == UtteranceVariantState::Ready
        })
        .and_then(|variant| variant.text.map(|text| (text, variant.completion)))
}

const COMPLETE: UtteranceCompletion = UtteranceCompletion::Complete;
const PARTIAL: UtteranceCompletion = UtteranceCompletion::Partial;

/// The auxiliary lane runs ahead of the canonical one. A translation whose
/// audio has barely begun on the previous row must not settle there: that
/// row is final, so the translation could never move to the row it belongs
/// to once that row arrives.
#[test]
fn a_translation_heard_before_its_row_lands_on_that_row() {
    let (_t, store, s) = fixture("ahead");
    row(&store, &s, 0, "zh", "前一句话", 0, 2_000, COMPLETE);
    let early = fact(
        &store,
        &s,
        0,
        "en",
        "zh",
        "后一句话",
        1_990,
        4_000,
        Some("next"),
        Some(PARTIAL),
    );
    assert_eq!(
        early.item.bound_sequence, None,
        "only 10 ms of it is on row 0"
    );

    row(&store, &s, 1, "zh", "后一句话", 2_000, 4_000, PARTIAL);
    store
        .reconcile_active_translation_inbox_near(&s, Some((2_000, 4_000)))
        .unwrap();
    let settled = fact(
        &store,
        &s,
        0,
        "en",
        "zh",
        "后一句话",
        1_990,
        4_000,
        Some("next sentence"),
        Some(COMPLETE),
    );
    assert_eq!(settled.item.bound_sequence, Some(1));
    assert_eq!(
        lane(&store, &s, 1, "en").map(|lane| lane.0),
        Some("next sentence".into())
    );
    assert_eq!(lane(&store, &s, 0, "en"), None);
}

/// A translation already on a row moves when a revision of it says another
/// row holds most of its audio, as long as the lane it sits in is not final.
#[test]
fn a_bound_translation_moves_to_the_row_that_holds_most_of_it() {
    let (_t, store, s) = fixture("rerank");
    row(&store, &s, 0, "en", "We meet at", 0, 2_000, COMPLETE);
    let first = fact(
        &store,
        &s,
        0,
        "zh",
        "en",
        "We meet",
        0,
        1_500,
        Some("我们见面"),
        Some(PARTIAL),
    );
    assert_eq!(first.item.bound_sequence, Some(0));
    row(
        &store,
        &s,
        1,
        "en",
        "the hall on Friday.",
        2_000,
        6_000,
        COMPLETE,
    );
    let grown = fact(
        &store,
        &s,
        0,
        "zh",
        "en",
        "the hall on Friday",
        1_800,
        6_000,
        Some("周五在大厅"),
        Some(PARTIAL),
    );
    assert_eq!(grown.item.bound_sequence, Some(1));
    assert_eq!(lane(&store, &s, 0, "zh"), None);
    assert_eq!(grown.removed_bound_sequence, None, "row 0 is still there");
    assert_eq!(
        grown.detached_utterance.as_ref().map(|row| row.sequence),
        Some(0),
        "the row it left is reported as changed"
    );
}

/// One of a row's segments withdrawn leaves the others' words in the lane,
/// and the row can still become Final. The withdrawal used to empty the
/// lane, and the next canonical Final then failed as a rewrite of a final
/// lane, which stopped the transcription group.
#[test]
fn withdrawing_one_segment_keeps_its_siblings_and_the_row_still_settles() {
    let (_t, store, s) = fixture("withdraw");
    row(&store, &s, 0, "zh", "甲乙丙丁", 0, 5_000, PARTIAL);
    fact(
        &store,
        &s,
        0,
        "en",
        "zh",
        "甲乙",
        0,
        2_000,
        Some("AAA"),
        Some(COMPLETE),
    );
    fact(
        &store,
        &s,
        1,
        "en",
        "zh",
        "丙丁",
        2_000,
        4_000,
        Some("BBB"),
        Some(PARTIAL),
    );
    assert_eq!(
        lane(&store, &s, 0, "en").map(|lane| lane.0),
        Some("AAA BBB".into())
    );

    fact(&store, &s, 1, "en", "zh", "丙丁", 2_000, 4_000, None, None);
    assert_eq!(
        lane(&store, &s, 0, "en").map(|lane| lane.0),
        Some("AAA".into())
    );

    row(&store, &s, 0, "zh", "甲乙丙丁", 0, 5_000, COMPLETE);
    assert_eq!(
        lane(&store, &s, 0, "en"),
        Some(("AAA".into(), Some(COMPLETE)))
    );
}

/// Recovery after Stop replays every bound row. A row that cannot be
/// replayed keeps what it has; the rest of the recording is still placed.
#[test]
fn one_row_that_cannot_replay_does_not_stop_recovery_placing_the_rest() {
    let (t, store, s) = fixture("recovery");
    row(&store, &s, 0, "zh", "甲乙", 0, 2_000, PARTIAL);
    fact(
        &store,
        &s,
        0,
        "en",
        "zh",
        "甲乙",
        0,
        2_000,
        Some("first"),
        Some(COMPLETE),
    );
    // A lane an older build settled with different words.
    store
        .upsert_translation_variant(
            &s,
            0,
            "en",
            Some("older words"),
            UtteranceVariantState::Ready,
            Some(COMPLETE),
        )
        .unwrap();
    row(&store, &s, 1, "zh", "后面", 10_000, 12_000, COMPLETE);
    // Between rows: only the after-stop settlement places it.
    fact(
        &store,
        &s,
        2,
        "en",
        "zh",
        "嗯",
        12_300,
        12_600,
        Some("Mm."),
        Some(COMPLETE),
    );

    let path = t.path().join("capture.db");
    drop(store);
    let reopened = NotebookCaptureStore::new(&path).unwrap();
    reopened.recover_unfinished_runs().unwrap();
    reopened
        .reconcile_translation_inbox_after_recovery(&s)
        .unwrap();
    let placed = reopened
        .list_translation_inbox(&s)
        .unwrap()
        .into_iter()
        .find(|item| item.key.provider_sequence == 2)
        .unwrap();
    assert_eq!(placed.bound_sequence, Some(1));
    assert_eq!(
        lane(&reopened, &s, 0, "en").map(|lane| lane.0),
        Some("older words".into())
    );
}

/// A one-word filler just before a sentence shares a little of a long
/// translation's audio; the sentence holds most of it.
#[test]
fn a_short_filler_does_not_take_the_translation_of_the_sentence_after_it() {
    let (_t, store, s) = fixture("filler");
    row(&store, &s, 0, "en", "Okay.", 10_000, 10_400, COMPLETE);
    row(
        &store,
        &s,
        1,
        "en",
        "So the plan is to ship on Friday.",
        10_500,
        14_000,
        COMPLETE,
    );
    let placed = fact(
        &store,
        &s,
        0,
        "zh",
        "en",
        "Okay, so the plan is to ship",
        10_000,
        13_000,
        Some("好，计划是发布"),
        Some(COMPLETE),
    );
    assert_eq!(placed.item.bound_sequence, Some(1));
    assert_eq!(lane(&store, &s, 0, "zh"), None);
}

/// Language identification called a Chinese row Thai. The Thai lane's
/// translation says the audio was Chinese; the row's own script agrees, so
/// the row takes the Chinese label and the Thai translation.
#[test]
fn a_row_labelled_in_the_wrong_language_takes_the_translation_into_its_label() {
    let (_t, store, s) = fixture("label");
    row(&store, &s, 0, "th", "我们走吧", 0, 2_000, COMPLETE);
    fact(
        &store,
        &s,
        0,
        "th",
        "zh",
        "我们走吧",
        0,
        2_000,
        Some("ไปกันเถอะ"),
        Some(COMPLETE),
    );
    let relabelled = current(&store, &s, 0).unwrap();
    assert_eq!(relabelled.source_language, "zh");
    assert_eq!(
        lane(&store, &s, 0, "th").map(|lane| lane.0),
        Some("ไปกันเถอะ".into())
    );
}

/// Thai text labelled Thai keeps its label whatever another lane heard.
#[test]
fn a_row_whose_script_matches_its_label_keeps_it() {
    let (_t, store, s) = fixture("label-kept");
    row(&store, &s, 0, "th", "ไปกันเถอะ", 0, 2_000, COMPLETE);
    fact(
        &store,
        &s,
        0,
        "th",
        "zh",
        "ไปกันเถอะ",
        0,
        2_000,
        Some("ไปกันเถอะ"),
        Some(COMPLETE),
    );
    assert_eq!(current(&store, &s, 0).unwrap().source_language, "th");
}
