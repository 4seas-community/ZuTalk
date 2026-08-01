//! Erasure baseline for the live caption channels.
//!
//! Erasure is the number of already-presented characters that a later update
//! removes or rewrites — the caption-stability metric used by MeetDot
//! (normalized erasure, m erased per n final) and by Google's live-translation
//! work (erasure / lag / quality). Every stabilization lever planned for the
//! subtitle canvas (mask-k, equivalence suppression, line locking) trades
//! something for erasure, so the number has to exist before any lever does.
//!
//! The meter observes exactly what crosses the FFI boundary: the durable
//! capture events and the live preview channel, after mailbox coalescing.
//! What it observes is therefore what Swift receives, not what the provider
//! sent — dropped intermediate frames never flickered on screen and are
//! deliberately not counted.
//!
//! Output is counts and language codes only. No transcript text is retained
//! beyond the last presented revision per lane, and none is ever logged.

use std::collections::HashMap;

use crate::notebook_capture_api::{FfiNotebookCaptureLivePreview, FfiNotebookCaptureUtterance};

/// A source lane is keyed by role, not by language: a `und → zh` identity
/// commit re-homes the same text to another column, and that move must not
/// be scored as one lane erasing everything while another appends it.
const SOURCE_ROLE_KEY: &str = "#source";

#[derive(Debug, Default, Clone, Copy)]
struct LaneTotals {
    updates: u64,
    erased_chars: u64,
    appended_chars: u64,
    presented_chars: u64,
}

#[derive(Debug, Default)]
pub(crate) struct ErasureMeter {
    session_id: Option<String>,
    /// Last presented text per (utterance sequence, lane role).
    presented: HashMap<(u64, String), String>,
    /// Which language the lane's erasure is attributed to. Follows the most
    /// recent identity, so a re-homed source lane keeps one history.
    lane_language: HashMap<(u64, String), String>,
    totals: HashMap<String, LaneTotals>,
}

impl ErasureMeter {
    /// Durable capture event: deltas carry changed rows, snapshots carry all.
    /// Both revise the same keyed lanes, so one absorption rule serves both.
    pub(crate) fn absorb_event_utterances(
        &mut self,
        session_id: &str,
        utterances: &[FfiNotebookCaptureUtterance],
    ) {
        self.roll_session(session_id);
        for utterance in utterances {
            self.absorb_utterance(utterance);
        }
    }

    pub(crate) fn absorb_preview(&mut self, preview: &FfiNotebookCaptureLivePreview) {
        self.roll_session(&preview.session_id);
        for utterance in &preview.utterances {
            self.absorb_utterance(utterance);
        }
    }

    /// Logs and clears the current session's totals. Safe to call on a
    /// session that never produced captions; it stays silent.
    pub(crate) fn finish_session(&mut self) {
        let Some(session_id) = self.session_id.take() else {
            return;
        };
        let mut languages: Vec<_> = self.totals.iter().collect();
        languages.sort_by(|left, right| left.0.cmp(right.0));
        for (language, totals) in languages {
            // Normalized erasure in the MeetDot sense: erased ÷ finally
            // presented. Logged as raw integers so the ratio can be recomputed
            // without float formatting drift.
            tracing::info!(
                session_id = %session_id,
                language = %language,
                updates = totals.updates,
                erased_chars = totals.erased_chars,
                appended_chars = totals.appended_chars,
                presented_chars = totals.presented_chars,
                "caption erasure baseline"
            );
        }
        self.presented.clear();
        self.lane_language.clear();
        self.totals.clear();
    }

    fn roll_session(&mut self, session_id: &str) {
        if self.session_id.as_deref() != Some(session_id) {
            self.finish_session();
            self.session_id = Some(session_id.to_string());
        }
    }

    /// A row carries the same text twice: once in `language_variants` and
    /// once in the aggregate source/translated shadow fields kept for legacy
    /// rows. Scoring both would count every character of every lane twice.
    /// The variants are authoritative wherever they exist; the shadow fields
    /// are read only for a row that has none.
    fn absorb_utterance(&mut self, utterance: &FfiNotebookCaptureUtterance) {
        if utterance.language_variants.is_empty() {
            let source_language = utterance
                .provisional_source_language
                .clone()
                .unwrap_or_else(|| utterance.source_language.clone());
            if !utterance.source_text.is_empty() {
                self.record(
                    utterance.sequence,
                    SOURCE_ROLE_KEY,
                    &source_language,
                    &utterance.source_text,
                );
            }
            if let (Some(language), Some(text)) = (
                utterance.translated_language.as_deref(),
                utterance.translated_text.as_deref(),
            ) {
                if !text.is_empty() {
                    self.record(utterance.sequence, language, language, text);
                }
            }
            return;
        }

        for variant in &utterance.language_variants {
            let Some(text) = variant.text.as_deref() else {
                continue;
            };
            if text.is_empty() {
                continue;
            }
            // The source lane keeps the role key so a `und -> zh` identity
            // commit stays one lane and migrates instead of reading as one
            // language erasing everything while another appends it. Its
            // display language follows the live provisional hint, which is
            // what the canvas actually shows.
            if variant.role == "source" {
                let language = utterance
                    .provisional_source_language
                    .as_deref()
                    .unwrap_or(&variant.language);
                self.record(utterance.sequence, SOURCE_ROLE_KEY, language, text);
            } else {
                self.record(
                    utterance.sequence,
                    &variant.language,
                    &variant.language,
                    text,
                );
            }
        }
    }

    /// Moves a lane's already-counted characters to the language it now
    /// belongs to, so the per-language totals describe where the text ended
    /// up rather than where it first appeared.
    fn migrate_lane_language(&mut self, key: &(u64, String), language: &str, lane_chars: u64) {
        let Some(previous_language) = self
            .lane_language
            .get(key)
            .cloned()
            .filter(|previous_language| previous_language != language)
        else {
            return;
        };
        let moved = self
            .totals
            .get(&previous_language)
            .map(|totals| totals.presented_chars.min(lane_chars))
            .unwrap_or(0);
        if let Some(totals) = self.totals.get_mut(&previous_language) {
            totals.presented_chars -= moved;
        }
        self.totals
            .entry(language.to_string())
            .or_default()
            .presented_chars += moved;
        self.lane_language.insert(key.clone(), language.to_string());
    }

    fn record(&mut self, sequence: u64, role: &str, language: &str, text: &str) {
        let key = (sequence, role.to_string());
        let previous = self.presented.get(&key).cloned().unwrap_or_default();
        let previous_chars = previous.chars().count() as u64;
        // Identity can commit without the words changing at all — `und -> zh`
        // on settled text is the common case — so the migration has to run
        // before the unchanged-text shortcut, or the lane's characters stay
        // filed under a language the canvas is no longer showing.
        self.migrate_lane_language(&key, language, previous_chars);
        if previous == text {
            return;
        }
        let previous = previous.as_str();
        let common = common_prefix_chars(previous, text);
        let next_chars = text.chars().count() as u64;
        let erased = previous_chars - common;
        let appended = next_chars - common;

        // presented_chars tracks the sum of the language's current lane
        // lengths; replace this lane's contribution.
        let totals = self.totals.entry(language.to_string()).or_default();
        totals.updates += 1;
        totals.erased_chars += erased;
        totals.appended_chars += appended;
        totals.presented_chars = totals
            .presented_chars
            .saturating_sub(previous_chars)
            .saturating_add(next_chars);
        self.presented.insert(key.clone(), text.to_string());
        self.lane_language.insert(key, language.to_string());
    }
}

fn common_prefix_chars(left: &str, right: &str) -> u64 {
    left.chars()
        .zip(right.chars())
        .take_while(|(left, right)| left == right)
        .count() as u64
}

#[cfg(test)]
mod tests {
    use super::*;

    fn utterance(sequence: u64, language: &str, text: &str) -> FfiNotebookCaptureUtterance {
        FfiNotebookCaptureUtterance {
            id: format!("session:{sequence}"),
            session_id: "session".to_string(),
            sequence,
            revision: 0,
            session_speaker_id: None,
            source_language: language.to_string(),
            provisional_source_language: None,
            source_text: text.to_string(),
            source_start_ms: None,
            source_end_ms: None,
            translated_language: None,
            translated_text: None,
            completion: "partial".to_string(),
            alignment: "source_only".to_string(),
            source_projection_revision: 0,
            source_edit_revision: 0,
            language_variants: Vec::new(),
        }
    }

    #[test]
    fn pure_append_scores_zero_erasure() {
        let mut meter = ErasureMeter::default();
        meter.absorb_event_utterances("session", &[utterance(0, "zh", "你好")]);
        meter.absorb_event_utterances("session", &[utterance(0, "zh", "你好世界")]);
        let totals = meter.totals.get("zh").copied().unwrap();
        assert_eq!(totals.erased_chars, 0);
        assert_eq!(totals.appended_chars, 4);
        assert_eq!(totals.updates, 2);
    }

    #[test]
    fn tail_rewrite_scores_only_the_rewritten_chars() {
        let mut meter = ErasureMeter::default();
        meter.absorb_event_utterances("session", &[utterance(0, "en", "hello wor")]);
        meter.absorb_event_utterances("session", &[utterance(0, "en", "hello word")]);
        let totals = meter.totals.get("en").copied().unwrap();
        // "hello wor" is a prefix of "hello word": nothing was erased.
        assert_eq!(totals.erased_chars, 0);
        meter.absorb_event_utterances("session", &[utterance(0, "en", "hello world")]);
        let totals = meter.totals.get("en").copied().unwrap();
        // "word" -> "world": the final d is rewritten.
        assert_eq!(totals.erased_chars, 1);
    }

    #[test]
    fn identical_redelivery_is_not_an_update() {
        let mut meter = ErasureMeter::default();
        meter.absorb_event_utterances("session", &[utterance(0, "zh", "你好")]);
        meter.absorb_event_utterances("session", &[utterance(0, "zh", "你好")]);
        assert_eq!(meter.totals.get("zh").copied().unwrap().updates, 1);
    }

    #[test]
    fn identity_rehoming_is_not_erasure() {
        let mut meter = ErasureMeter::default();
        let mut unknown = utterance(0, "und", "สวัสดี");
        unknown.provisional_source_language = Some("th".to_string());
        meter.absorb_event_utterances("session", &[unknown]);
        // The durable commit later lands the same text under its real language.
        meter.absorb_event_utterances("session", &[utterance(0, "th", "สวัสดี")]);
        let totals = meter.totals.get("th").copied().unwrap();
        assert_eq!(totals.erased_chars, 0);
    }

    #[test]
    fn variant_lanes_are_scored_per_language() {
        let mut meter = ErasureMeter::default();
        let mut row = utterance(0, "zh", "你好");
        row.language_variants = vec![
            crate::notebook_capture_api::FfiNotebookCaptureLanguageVariant {
                language: "en".to_string(),
                role: "translation".to_string(),
                text: Some("Hel".to_string()),
                state: "ready".to_string(),
                completion: Some("partial".to_string()),
                projection_revision: 0,
                edit_revision: 0,
            },
        ];
        meter.absorb_event_utterances("session", &[row.clone()]);
        row.language_variants[0].text = Some("Hi there".to_string());
        meter.absorb_event_utterances("session", &[row]);
        let totals = meter.totals.get("en").copied().unwrap();
        // "Hel" -> "Hi there": common prefix "H", two chars erased.
        assert_eq!(totals.erased_chars, 2);
        assert_eq!(totals.updates, 2);
    }

    #[test]
    fn a_row_carrying_both_variants_and_shadow_fields_is_counted_once() {
        let mut meter = ErasureMeter::default();
        let mut row = utterance(0, "zh", "你好");
        // A live row carries the same words in both representations.
        row.language_variants = vec![
            crate::notebook_capture_api::FfiNotebookCaptureLanguageVariant {
                language: "zh".to_string(),
                role: "source".to_string(),
                text: Some("你好".to_string()),
                state: "ready".to_string(),
                completion: Some("complete".to_string()),
                projection_revision: 0,
                edit_revision: 0,
            },
            crate::notebook_capture_api::FfiNotebookCaptureLanguageVariant {
                language: "en".to_string(),
                role: "translation".to_string(),
                text: Some("Hello".to_string()),
                state: "ready".to_string(),
                completion: Some("complete".to_string()),
                projection_revision: 0,
                edit_revision: 0,
            },
        ];
        row.translated_language = Some("en".to_string());
        row.translated_text = Some("Hello".to_string());
        meter.absorb_event_utterances("session", &[row]);

        let zh = meter.totals.get("zh").copied().unwrap();
        assert_eq!(zh.appended_chars, 2, "the source words are scored once");
        assert_eq!(zh.updates, 1);
        let en = meter.totals.get("en").copied().unwrap();
        assert_eq!(en.appended_chars, 5, "the translation is scored once");
        assert_eq!(en.updates, 1);
    }

    #[test]
    fn an_identity_commit_migrates_the_lane_even_when_the_words_do_not_change() {
        let mut meter = ErasureMeter::default();
        let mut pending = utterance(0, "und", "สวัสดี");
        pending.provisional_source_language = Some("th".to_string());
        meter.absorb_event_utterances("session", &[pending]);
        assert_eq!(meter.totals.get("th").copied().unwrap().presented_chars, 6);

        // The durable commit lands the identical text under `und` with no
        // provisional hint left: the identity is settled, the words never
        // changed, and the lane must stop being filed under Thai only if it
        // really moved. Here it moves to the committed language.
        let settled = utterance(0, "th", "สวัสดี");
        meter.absorb_event_utterances("session", &[settled]);
        let th = meter.totals.get("th").copied().unwrap();
        assert_eq!(th.erased_chars, 0);
        assert_eq!(th.presented_chars, 6, "the lane stayed with its language");

        // And a lane whose language genuinely changes carries its characters
        // across without inventing erasure.
        let mut moved = ErasureMeter::default();
        let mut guessed = utterance(1, "und", "hello");
        guessed.provisional_source_language = Some("de".to_string());
        moved.absorb_event_utterances("session", &[guessed]);
        assert_eq!(moved.totals.get("de").copied().unwrap().presented_chars, 5);
        moved.absorb_event_utterances("session", &[utterance(1, "en", "hello")]);
        assert_eq!(moved.totals.get("de").copied().unwrap().presented_chars, 0);
        let en = moved.totals.get("en").copied().unwrap();
        assert_eq!(en.presented_chars, 5);
        assert_eq!(en.erased_chars, 0, "re-homing is not erasure");
    }

    #[test]
    fn session_change_resets_the_meter() {
        let mut meter = ErasureMeter::default();
        meter.absorb_event_utterances("session-a", &[utterance(0, "zh", "你好")]);
        meter.absorb_event_utterances("session-b", &[utterance(0, "zh", "再见")]);
        let totals = meter.totals.get("zh").copied().unwrap();
        assert_eq!(totals.updates, 1);
        assert_eq!(totals.erased_chars, 0);
    }
}
