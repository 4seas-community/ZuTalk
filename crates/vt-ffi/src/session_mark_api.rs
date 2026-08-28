//! Marks: the FFI face of "that mattered — remember where we are".
//!
//! The app calls exactly one verb while the room is still talking
//! (`session_mark_create`), and it must return fast enough to feel like a key
//! repeat. Everything expensive — resolving the passage, joining it against
//! the transcript — happens on read, where a few milliseconds cost nothing.
//!
//! Marks never touch the capture path. They read the same transcript rows the
//! transcript view already reads, and they write to a table nothing in the
//! capture pipeline consults. A mark cannot slow down, stall, or corrupt a
//! live lane, which is the property that lets the keypress be a global hotkey
//! the user hammers without thinking.

use std::sync::Arc;

use vt_llm::{PassageDigestRequest, PassageLine};
use vt_store::notebook_capture_store::RealtimeUtterance;
use vt_store::{
    anchor_is_in_mark, resolve_mark_end, resolve_mark_start, MarkAnchor, MarkDigest,
    MarkDigestState, MarkLookback, SessionMark, SessionMarkStore,
};

use crate::{CoreError, ZuTalkCore};

/// A mark plus the passage it currently resolves to.
///
/// The excerpt is derived on every read rather than stored: transcript rows
/// keep improving after a mark is dropped — a partial finalizes, the precision
/// pass replaces a line, a translation lands — and a stored copy would freeze
/// the worst version of the text the listener ever saw.
#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiSessionMark {
    pub id: String,
    pub session_id: String,
    /// When the key went down, in capture milliseconds.
    pub at_ms: u64,
    pub start_ms: u64,
    /// The resolved trailing edge, never null on the way out: the app should
    /// not have to reimplement "unset means the enclosing utterance".
    pub end_ms: u64,
    /// Whether that trailing edge is still tracking the enclosing utterance
    /// rather than a boundary the listener chose.
    pub end_is_auto: bool,
    /// The listener's own words about this moment.
    pub note: String,
    pub created_at: String,
    pub updated_at: String,
    /// Transcript rows overlapping the passage, in capture order.
    pub excerpt: Vec<FfiSessionMarkLine>,
    /// The passage made readable, once it comes back.
    ///
    /// Absent means one of several honest things — assistance is off, nothing
    /// has run yet, or the passage was too short to be worth sending — and the
    /// card shows the raw excerpt, which is never wrong, only harder to read.
    pub digest: Option<FfiMarkDigest>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiMarkDigest {
    pub text: String,
    pub language: String,
    /// False once the transcript underneath moved on or the listener dragged
    /// the boundaries. Stale text is shown, not hidden — it still describes
    /// most of the passage — but it is labelled so nobody quotes it as current.
    pub is_current: bool,
    pub failed: bool,
    pub error: Option<String>,
}

/// One transcript row inside a marked passage.
///
/// Source and translation both travel: in the room the listener was reading
/// the translation, and afterward they usually want the original next to it.
#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiSessionMarkLine {
    pub utterance_id: String,
    pub speaker_id: Option<String>,
    pub source_language: String,
    pub source_text: String,
    pub translated_language: Option<String>,
    pub translated_text: Option<String>,
    pub start_ms: u64,
    pub end_ms: u64,
}

#[uniffi::export]
impl ZuTalkCore {
    /// Drops a mark and resolves how far back it reaches.
    ///
    /// `at_ms` is normally omitted: the app's own elapsed timer is a wall
    /// clock, while transcript timestamps come off the capture clock, and a
    /// mark placed by the wrong clock points at the wrong words. Left unset,
    /// the instant is read from the frames this session has actually captured
    /// — the same clock the transcript is stamped in. It is passed explicitly
    /// only to mark a specific past moment, such as when replaying.
    ///
    /// The backward reach is computed here rather than in the app because only
    /// this side knows where the speech actually paused.
    pub fn session_mark_create(
        &self,
        session_id: String,
        at_ms: Option<u64>,
    ) -> Result<FfiSessionMark, CoreError> {
        let utterances = self.mark_utterances(&session_id)?;
        let at_ms = match at_ms {
            Some(at_ms) => at_ms,
            None => self.capture_position_ms(&session_id, &utterances)?,
        };
        let anchors = mark_anchors(&utterances);
        let start_ms = resolve_mark_start(&anchors, at_ms, MarkLookback::default());

        let id = uuid::Uuid::new_v4().to_string();
        let mark = self
            .session_marks
            .create(&id, &session_id, at_ms, start_ms)
            .map_err(mark_error("create mark"))?;

        // Fire and forget. The listener is still listening; the keypress
        // returns now and the readable version arrives on its own.
        self.spawn_digest(&mark, &utterances);
        Ok(hydrate_with(
            mark,
            &utterances,
            self.digests_for(&session_id),
        ))
    }

    /// Every live mark on a session, in capture order, each with its passage.
    pub fn session_mark_list(&self, session_id: String) -> Result<Vec<FfiSessionMark>, CoreError> {
        let utterances = self.mark_utterances(&session_id)?;
        let marks = self
            .session_marks
            .list(&session_id)
            .map_err(mark_error("list marks"))?;
        let digests = self.digests_for(&session_id);
        Ok(marks
            .into_iter()
            .map(|mark| hydrate_with(mark, &utterances, digests.clone()))
            .collect())
    }

    /// Replaces the listener's own text on a mark.
    pub fn session_mark_set_note(
        &self,
        mark_id: String,
        note: String,
    ) -> Result<FfiSessionMark, CoreError> {
        let mark = self
            .session_marks
            .set_note(&mark_id, &note)
            .map_err(mark_error("set mark note"))?;
        let utterances = self.mark_utterances(&mark.session_id)?;
        let digests = self.digests_for(&mark.session_id);
        Ok(hydrate_with(mark, &utterances, digests))
    }

    /// Moves a mark's passage boundaries after the listener drags them.
    pub fn session_mark_set_bounds(
        &self,
        mark_id: String,
        start_ms: u64,
        end_ms: u64,
    ) -> Result<FfiSessionMark, CoreError> {
        let mark = self
            .session_marks
            .set_bounds(&mark_id, start_ms, end_ms)
            .map_err(mark_error("set mark bounds"))?;
        let utterances = self.mark_utterances(&mark.session_id)?;
        // Dragging a boundary changes what the passage is, so whatever was
        // cleaned up before now describes different words.
        self.spawn_digest(&mark, &utterances);
        let digests = self.digests_for(&mark.session_id);
        Ok(hydrate_with(mark, &utterances, digests))
    }

    pub fn session_mark_delete(&self, mark_id: String) -> Result<(), CoreError> {
        self.session_marks
            .delete(&mark_id)
            .map_err(mark_error("delete mark"))
    }
}

impl ZuTalkCore {
    /// Cleans up a marked passage in the background, if it should happen at all.
    ///
    /// Every reason not to send is checked here, in one place, before anything
    /// is spawned: assistance off, no credential, nothing substantial in the
    /// passage. The check is deliberately not spread across call sites — a gate
    /// that decides whether someone's words leave their machine has to be
    /// somewhere a reader can find all of it.
    fn spawn_digest(&self, mark: &SessionMark, utterances: &[RealtimeUtterance]) {
        if !self.is_language_model_enabled() {
            return;
        }
        let engine = vt_llm::CURRENT_LANGUAGE_MODEL_ENGINE;
        let Ok(api_key) = self.api_key_store.get(engine.credential_scope) else {
            return;
        };
        let request = passage_request(mark, utterances, &vt_i18n::current_locale());
        if !vt_llm::is_worth_digesting(&request) {
            return;
        }

        let fingerprint = vt_llm::source_fingerprint(&request);
        let store: Arc<SessionMarkStore> = self.session_marks.clone();
        let mark_id = mark.id.clone();
        let language = request.target_language.clone();
        self.runtime.spawn(async move {
            let outcome = vt_llm::digest_passage(engine, &api_key, &request).await;
            // A failure is recorded, not swallowed. A card that silently keeps
            // showing fragments reads as "the feature is off", and the listener
            // has no way to tell the difference or to ask again.
            let digest = match outcome {
                Ok(text) => MarkDigest {
                    mark_id,
                    language,
                    text,
                    model_id: engine.model_id.to_string(),
                    source_fingerprint: fingerprint,
                    state: MarkDigestState::Ready,
                    error: None,
                    created_at: String::new(),
                },
                Err(error) => {
                    // The message describes the failure kind only; the crate
                    // never puts credential material or passage text in it.
                    tracing::warn!(%error, "cleaning up a marked passage failed");
                    MarkDigest {
                        mark_id,
                        language,
                        text: String::new(),
                        model_id: engine.model_id.to_string(),
                        source_fingerprint: fingerprint,
                        state: MarkDigestState::Failed,
                        error: Some(error.to_string()),
                        created_at: String::new(),
                    }
                }
            };
            if let Err(error) = store.put_digest(&digest) {
                tracing::warn!(%error, "storing a cleaned-up passage failed");
            }
        });
    }

    fn digests_for(&self, session_id: &str) -> Arc<Vec<MarkDigest>> {
        Arc::new(
            self.session_marks
                .list_digests(session_id)
                .unwrap_or_default(),
        )
    }

    /// Not exported: its signature speaks in store types, and it is a read
    /// helper rather than a verb the app should be able to call.
    /// Where this session's capture clock stands right now.
    ///
    /// Captured frames are the authority: they advance through silence, which
    /// the transcript does not, and a mark dropped during a pause has to land
    /// after the last thing said rather than on top of it. Transcript is the
    /// fallback for a run whose frame count is unavailable — an import, or a
    /// row that predates the counter.
    fn capture_position_ms(
        &self,
        session_id: &str,
        utterances: &[RealtimeUtterance],
    ) -> Result<u64, CoreError> {
        let run = self
            .notebook_capture_store
            .get_run_for_session(session_id)
            .map_err(|e| CoreError::InternalError {
                message: format!("read capture position: {e}"),
            })?;
        let from_frames = run.and_then(|run| {
            let sample_rate = u64::from(run.sample_rate.filter(|rate| *rate > 0)?);
            Some(run.captured_frames.saturating_mul(1_000) / sample_rate)
        });
        let from_transcript = utterances
            .iter()
            .filter_map(|utterance| utterance.source_end_ms.or(utterance.source_start_ms))
            .max();
        Ok(from_frames
            .into_iter()
            .chain(from_transcript)
            .max()
            .unwrap_or(0))
    }

    fn mark_utterances(&self, session_id: &str) -> Result<Vec<RealtimeUtterance>, CoreError> {
        self.notebook_capture_store
            .list_utterances(session_id)
            .map_err(|e| CoreError::InternalError {
                message: format!("read transcript for marks: {e}"),
            })
    }
}

/// A store failure keeps its shape across the boundary: a mark the app thinks
/// exists but does not is an app-state bug worth telling apart from a disk
/// problem, and the app can only tell them apart if the variant survives.
fn mark_error(context: &'static str) -> impl Fn(vt_store::SessionMarkError) -> CoreError {
    move |error| {
        let message = format!("{context}: {error}");
        match error {
            vt_store::SessionMarkError::NotFound(_) => CoreError::NotFound { message },
            vt_store::SessionMarkError::MissingField(_)
            | vt_store::SessionMarkError::InvalidRange { .. } => {
                CoreError::ValidationFailed { message }
            }
            vt_store::SessionMarkError::DbError(_) => CoreError::InternalError { message },
        }
    }
}

/// Transcript rows the range math can use.
///
/// Rows the provider never timestamped are dropped rather than guessed at: a
/// mark placed on an invented timestamp would point at the wrong words, which
/// is worse than a mark that falls back to its fixed reach.
fn mark_anchors(utterances: &[RealtimeUtterance]) -> Vec<MarkAnchor> {
    utterances.iter().filter_map(anchor_of).collect()
}

fn anchor_of(utterance: &RealtimeUtterance) -> Option<MarkAnchor> {
    let start_ms = utterance.source_start_ms?;
    // A row still being spoken has no end yet; treat it as ending where it
    // began so it can still bound a reach without claiming duration.
    let end_ms = utterance.source_end_ms.unwrap_or(start_ms).max(start_ms);
    Some(MarkAnchor { start_ms, end_ms })
}

/// The passage as the model will see it: what the listener was reading, with
/// the original alongside, and nothing that says where it came from.
fn passage_request(
    mark: &SessionMark,
    utterances: &[RealtimeUtterance],
    target_language: &str,
) -> PassageDigestRequest {
    let anchors = mark_anchors(utterances);
    let end_ms = resolve_mark_end(mark, &anchors);
    let lines = utterances
        .iter()
        .filter_map(|utterance| {
            let anchor = anchor_of(utterance)?;
            anchor_is_in_mark(anchor, mark.start_ms, end_ms).then(|| PassageLine {
                speaker: utterance.session_speaker_id.clone(),
                source_language: utterance.source_language.clone(),
                source_text: utterance.source_text.clone(),
                translated_text: utterance.translated_text.clone(),
            })
        })
        .collect();
    PassageDigestRequest {
        lines,
        target_language: target_language.to_string(),
    }
}

fn hydrate_with(
    mark: SessionMark,
    utterances: &[RealtimeUtterance],
    digests: Arc<Vec<MarkDigest>>,
) -> FfiSessionMark {
    let stored = digests.iter().find(|digest| digest.mark_id == mark.id);
    let digest = stored.map(|stored| {
        let current = passage_request(&mark, utterances, &stored.language);
        FfiMarkDigest {
            text: stored.text.clone(),
            language: stored.language.clone(),
            is_current: vt_llm::source_fingerprint(&current) == stored.source_fingerprint,
            failed: stored.state == MarkDigestState::Failed,
            error: stored.error.clone(),
        }
    });
    let mut hydrated = hydrate(mark, utterances);
    hydrated.digest = digest;
    hydrated
}

fn hydrate(mark: SessionMark, utterances: &[RealtimeUtterance]) -> FfiSessionMark {
    let anchors = mark_anchors(utterances);
    let end_ms = resolve_mark_end(&mark, &anchors);
    let excerpt = utterances
        .iter()
        .filter_map(|utterance| {
            let anchor = anchor_of(utterance)?;
            anchor_is_in_mark(anchor, mark.start_ms, end_ms).then(|| FfiSessionMarkLine {
                utterance_id: utterance.id.clone(),
                speaker_id: utterance.session_speaker_id.clone(),
                source_language: utterance.source_language.clone(),
                source_text: utterance.source_text.clone(),
                translated_language: utterance.translated_language.clone(),
                translated_text: utterance.translated_text.clone(),
                start_ms: anchor.start_ms,
                end_ms: anchor.end_ms,
            })
        })
        .collect();

    FfiSessionMark {
        id: mark.id,
        session_id: mark.session_id,
        at_ms: mark.at_ms,
        start_ms: mark.start_ms,
        end_ms,
        end_is_auto: mark.end_ms.is_none(),
        note: mark.note,
        created_at: mark.created_at,
        updated_at: mark.updated_at,
        excerpt,
        digest: None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use vt_store::notebook_capture_store::{
        NewNotebookCaptureRun, NewRealtimeUtterance, RemoteHealth, UtteranceAlignment,
        UtteranceCompletion,
    };
    use vt_store::SessionRecord;

    /// A session whose transcript looks like the room actually sounded: a
    /// passage, a real silence, then the passage the listener will mark.
    fn core_with_transcript() -> (tempfile::TempDir, ZuTalkCore, String) {
        let temp = tempfile::tempdir().unwrap();
        let core = ZuTalkCore::new_for_test(temp.path().to_string_lossy().to_string()).unwrap();
        let notebook = core.create_notebook(Some("Marks".into())).unwrap();
        let profile = core
            .notebook_capture_store
            .get_or_create_profile(&notebook.id)
            .unwrap();
        let session = SessionRecord {
            id: "mark-session".into(),
            title: "Lecture".into(),
            session_type: "recording".into(),
            status: "recording".into(),
            duration_ms: 0,
            created_at: "2026-08-28T12:00:00Z".into(),
            deleted_at: None,
        };
        core.notebook_capture_store
            .create_session_and_run(
                &session,
                &NewNotebookCaptureRun {
                    id: "mark-run".into(),
                    notebook_id: notebook.id.clone(),
                    session_id: session.id.clone(),
                    remote_health: RemoteHealth::Off,
                    audio_journal_path: "/private/marks.journal".into(),
                    audio_key_ref: "private-marks-key".into(),
                    sample_rate: 16_000,
                    sample_format: "s16".to_string(),
                    channels: 1,
                },
                &profile,
            )
            .unwrap();

        // Realtime rows are refused without provider provenance; the trigger
        // that enforces it is the same one a live lane satisfies.
        core.notebook_capture_store
            .claim_provider_provenance(
                &session.id,
                vt_store::notebook_capture_store::CaptureProviderRole::Realtime,
                vt_stt::capture_engine::CURRENT_NOTEBOOK_CAPTURE_ENGINE.provider_id,
                vt_stt::capture_engine::CURRENT_NOTEBOOK_CAPTURE_ENGINE.realtime_model_id,
            )
            .unwrap();

        let rows = [
            (
                "u1",
                0u64,
                0u64,
                4_000u64,
                "an earlier topic",
                UtteranceCompletion::Complete,
            ),
            // Eight seconds of silence: a topic boundary.
            (
                "u2",
                1,
                12_000,
                16_000,
                "and that is the crux of it",
                UtteranceCompletion::Complete,
            ),
            // Still being spoken when the listener reaches for the key, which
            // is the ordinary case rather than an edge one.
            (
                "u3",
                2,
                16_200,
                20_000,
                "so if we look at the dat",
                UtteranceCompletion::Partial,
            ),
            // Spoken after the keypress.
            (
                "u4",
                3,
                26_000,
                30_000,
                "moving on to the next section",
                UtteranceCompletion::Complete,
            ),
        ];
        for (id, sequence, start_ms, end_ms, text, completion) in rows {
            core.notebook_capture_store
                .upsert_utterance(
                    &NewRealtimeUtterance {
                        id: id.into(),
                        session_id: session.id.clone(),
                        sequence,
                        session_speaker_id: None,
                        source_language: "en".into(),
                        source_text: text.into(),
                        source_start_ms: Some(start_ms),
                        source_end_ms: Some(end_ms),
                        translated_language: None,
                        translated_text: None,
                        completion,
                        alignment: UtteranceAlignment::SourceOnly,
                    },
                    None,
                )
                .unwrap();
        }
        (temp, core, session.id)
    }

    /// The whole point of the feature: press the key once, get back the
    /// passage that just finished — not a stopwatch window, and not the topic
    /// before the silence.
    #[test]
    fn a_mark_captures_the_passage_that_just_finished() {
        let (_temp, core, session_id) = core_with_transcript();

        let mark = core.session_mark_create(session_id, Some(21_000)).unwrap();

        assert_eq!(
            mark.start_ms, 12_000,
            "the reach stops at the silence, so the earlier topic stays out"
        );
        assert_eq!(
            mark.excerpt
                .iter()
                .map(|line| line.utterance_id.as_str())
                .collect::<Vec<_>>(),
            vec!["u2", "u3"],
            "the marked passage is what was being said, bounded on both sides"
        );
        assert!(mark.end_is_auto);
        assert!(mark.note.is_empty());
    }

    /// A mark dropped mid-sentence holds the whole sentence rather than
    /// cutting it where the finger landed.
    #[test]
    fn a_mark_pressed_mid_sentence_keeps_the_whole_sentence() {
        let (_temp, core, session_id) = core_with_transcript();

        let mark = core.session_mark_create(session_id, Some(18_000)).unwrap();

        assert_eq!(
            mark.end_ms, 20_000,
            "the enclosing utterance finishes first"
        );
        assert!(mark.excerpt.iter().any(|line| line.utterance_id == "u3"));
    }

    /// Notes and boundaries are edited independently, and the excerpt tracks
    /// the boundaries without the note ever being at risk.
    #[test]
    fn a_note_and_a_drag_do_not_interfere() {
        let (_temp, core, session_id) = core_with_transcript();
        let mark = core
            .session_mark_create(session_id.clone(), Some(21_000))
            .unwrap();

        let annotated = core
            .session_mark_set_note(mark.id.clone(), "他把三条路径混着说".into())
            .unwrap();
        assert_eq!(annotated.note, "他把三条路径混着说");

        let widened = core
            .session_mark_set_bounds(mark.id.clone(), 0, 30_000)
            .unwrap();
        assert_eq!(widened.note, "他把三条路径混着说");
        assert_eq!(widened.excerpt.len(), 4, "a wider passage holds more rows");
        assert!(!widened.end_is_auto, "a dragged edge stops tracking");

        let listed = core.session_mark_list(session_id).unwrap();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].note, "他把三条路径混着说");
    }

    /// The excerpt is derived, so text that improves after the keypress shows
    /// up in the mark — a partial that finalizes, a translation that lands.
    #[test]
    fn an_excerpt_reflects_transcript_that_improved_after_the_keypress() {
        let (_temp, core, session_id) = core_with_transcript();
        let mark = core
            .session_mark_create(session_id.clone(), Some(21_000))
            .unwrap();
        assert_eq!(mark.excerpt[1].source_text, "so if we look at the dat");

        // Finalizing is a compare-and-set against the partial's revision, the
        // same path the live lane takes.
        let partial_revision = core
            .notebook_capture_store
            .get_utterance_by_id("u3")
            .unwrap()
            .unwrap()
            .revision;
        core.notebook_capture_store
            .upsert_utterance(
                &NewRealtimeUtterance {
                    id: "u3".into(),
                    session_id: session_id.clone(),
                    sequence: 2,
                    session_speaker_id: None,
                    source_language: "en".into(),
                    source_text: "so if we look at the data".into(),
                    source_start_ms: Some(16_200),
                    source_end_ms: Some(20_000),
                    translated_language: None,
                    translated_text: None,
                    completion: UtteranceCompletion::Complete,
                    alignment: UtteranceAlignment::SourceOnly,
                },
                Some(partial_revision),
            )
            .unwrap();

        let reread = core.session_mark_list(session_id).unwrap();
        assert_eq!(
            reread[0].excerpt[1].source_text, "so if we look at the data",
            "a mark points at the transcript, it does not photograph it"
        );
    }

    /// Pressing the key before anyone has said anything must still produce a
    /// usable mark rather than an error the app has to explain.
    #[test]
    fn a_mark_on_an_empty_transcript_still_lands() {
        let temp = tempfile::tempdir().unwrap();
        let core = ZuTalkCore::new_for_test(temp.path().to_string_lossy().to_string()).unwrap();
        let notebook = core.create_notebook(Some("Empty".into())).unwrap();
        let profile = core
            .notebook_capture_store
            .get_or_create_profile(&notebook.id)
            .unwrap();
        let session = SessionRecord {
            id: "empty-session".into(),
            title: "Silence".into(),
            session_type: "recording".into(),
            status: "recording".into(),
            duration_ms: 0,
            created_at: "2026-08-28T12:00:00Z".into(),
            deleted_at: None,
        };
        core.notebook_capture_store
            .create_session_and_run(
                &session,
                &NewNotebookCaptureRun {
                    id: "empty-run".into(),
                    notebook_id: notebook.id.clone(),
                    session_id: session.id.clone(),
                    remote_health: RemoteHealth::Off,
                    audio_journal_path: "/private/empty.journal".into(),
                    audio_key_ref: "private-empty-key".into(),
                    sample_rate: 16_000,
                    sample_format: "s16".to_string(),
                    channels: 1,
                },
                &profile,
            )
            .unwrap();

        let mark = core.session_mark_create(session.id, Some(5_000)).unwrap();
        assert_eq!(mark.start_ms, 0);
        assert_eq!(mark.end_ms, 5_000);
        assert!(mark.excerpt.is_empty());
    }

    /// The clock the app must not supply itself. Frames advance through
    /// silence; the transcript stops at the last thing said. A mark dropped in
    /// a pause has to land after that, not on top of it.
    #[test]
    fn an_unspecified_instant_comes_from_the_capture_clock_not_the_transcript() {
        let (_temp, core, session_id) = core_with_transcript();
        // 16 kHz: 45 seconds of audio, well past the last utterance at 30s.
        core.notebook_capture_store
            .update_audio_progress("mark-run", 720_000)
            .unwrap();

        let mark = core.session_mark_create(session_id, None).unwrap();

        assert_eq!(mark.at_ms, 45_000, "silence still moves the capture clock");
        assert_eq!(
            mark.start_ms, 26_000,
            "the reach still lands on the last thing actually said"
        );
        assert_eq!(
            mark.excerpt
                .iter()
                .map(|line| line.utterance_id.as_str())
                .collect::<Vec<_>>(),
            vec!["u4"]
        );
    }

    /// The gate that decides whether anyone's words leave their machine.
    ///
    /// Off must mean no request is made from anywhere in the process, not
    /// merely that the app refrains from asking — and with no credential there
    /// is nothing to make a request with either. Both are checked in one place
    /// so this test can stand over the whole rule.
    #[test]
    fn nothing_is_sent_while_assistance_is_off_or_unconfigured() {
        let (_temp, core, session_id) = core_with_transcript();

        assert!(
            !core.is_language_model_enabled(),
            "assistance is off until the listener turns it on"
        );

        // Off: a mark still lands, with the raw passage and no digest.
        let mark = core
            .session_mark_create(session_id.clone(), Some(21_000))
            .unwrap();
        assert!(mark.digest.is_none());
        assert!(!mark.excerpt.is_empty(), "the mark itself is unaffected");

        // On but unconfigured: still nothing to send with.
        core.set_language_model_enabled(true).unwrap();
        assert!(core.is_language_model_enabled());
        let unconfigured = core.session_mark_create(session_id, Some(21_000)).unwrap();
        assert!(unconfigured.digest.is_none());
    }

    /// Turning assistance off has to mean "and forget what came back". Leaving
    /// the returned text on disk would let someone believe they had removed
    /// something they had not.
    #[test]
    fn turning_assistance_off_discards_the_text_it_produced() {
        let (_temp, core, session_id) = core_with_transcript();
        let mark = core
            .session_mark_create(session_id.clone(), Some(21_000))
            .unwrap();

        // Stand in for a returned passage; the network path cannot run here.
        core.session_marks
            .put_digest(&MarkDigest {
                mark_id: mark.id.clone(),
                language: "zh-Hans".into(),
                text: "这才是问题的核心。所以如果我们看数据……".into(),
                model_id: "test-model".into(),
                source_fingerprint: "fixture".into(),
                state: MarkDigestState::Ready,
                error: None,
                created_at: String::new(),
            })
            .unwrap();
        assert!(core.session_mark_list(session_id.clone()).unwrap()[0]
            .digest
            .is_some());

        core.set_language_model_enabled(false).unwrap();

        let after = core.session_mark_list(session_id).unwrap();
        assert!(after[0].digest.is_none(), "the returned text is gone");
        assert_eq!(after.len(), 1, "the mark itself was never the model's");
    }

    /// A digest describes the exact words it was built from. When the listener
    /// drags the boundaries or the transcript improves underneath, it is stale
    /// — shown, because it still describes most of the passage, but labelled,
    /// so nobody quotes it as current.
    #[test]
    fn a_digest_goes_stale_when_the_passage_moves_under_it() {
        let (_temp, core, session_id) = core_with_transcript();
        let mark = core
            .session_mark_create(session_id.clone(), Some(21_000))
            .unwrap();
        let request = {
            let utterances = core.mark_utterances(&session_id).unwrap();
            let stored = core.session_marks.get(&mark.id).unwrap();
            passage_request(&stored, &utterances, "zh-Hans")
        };
        core.session_marks
            .put_digest(&MarkDigest {
                mark_id: mark.id.clone(),
                language: "zh-Hans".into(),
                text: "这才是问题的核心。".into(),
                model_id: "test-model".into(),
                source_fingerprint: vt_llm::source_fingerprint(&request),
                state: MarkDigestState::Ready,
                error: None,
                created_at: String::new(),
            })
            .unwrap();

        let fresh = core.session_mark_list(session_id.clone()).unwrap();
        assert!(fresh[0].digest.as_ref().unwrap().is_current);

        let widened = core.session_mark_set_bounds(mark.id, 0, 30_000).unwrap();
        let digest = widened.digest.expect("stale text is kept, not hidden");
        assert!(!digest.is_current);
        assert_eq!(digest.text, "这才是问题的核心。");
    }

    #[test]
    fn a_deleted_mark_leaves_the_session_listing() {
        let (_temp, core, session_id) = core_with_transcript();
        let mark = core
            .session_mark_create(session_id.clone(), Some(21_000))
            .unwrap();

        core.session_mark_delete(mark.id.clone()).unwrap();

        assert!(core.session_mark_list(session_id).unwrap().is_empty());
        assert!(matches!(
            core.session_mark_delete(mark.id),
            Err(CoreError::NotFound { .. })
        ));
    }
}
