//! Shared data primitives used by the active capture and transcription paths.

use serde::{Deserialize, Serialize};

/// Local privacy policy applied before any remote provider is used.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum PrivacyLevel {
    Standard,
    High,
    Maximum,
}

/// Timestamped token emitted by the post-recording transcription adapter.
///
/// Live bilingual capture uses `vt_stt::SttStreamToken`, whose timestamps are
/// optional. Provider speaker labels are anonymous and scoped to the provider
/// session; they do not contain a persistent identity or voiceprint.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Token {
    pub text: String,
    pub start_ms: u64,
    pub end_ms: u64,
    pub is_final: bool,
    pub language: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub speaker: Option<String>,
    pub confidence: f32,
    pub translation_status: TranslationStatus,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum TranslationStatus {
    None,
    Original,
    Translation,
}

/// PCM S16LE, 16 kHz, mono audio pushed into an STT adapter.
#[derive(Debug, Clone)]
pub struct AudioChunk {
    pub pcm_data: Vec<u8>,
    pub channel: AudioChannel,
    pub captured_at_ns: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum AudioChannel {
    Microphone,
}

/// How an auxiliary stream's transcript of a segment relates to a canonical
/// row's transcript of the same speech.
///
/// A multilingual capture runs one canonical transcription connection plus one
/// translating connection per selected language, all fed the identical PCM.
/// The connections agree on the words and on nothing else: they punctuate
/// differently, they place their segment boundaries differently, and their
/// token timestamps drift apart over a long session (measured: same sentence
/// reported 1.7s apart four minutes in, 4.0s apart a minute later). The words
/// are therefore the only evidence that stays true for a whole run, and this
/// is the ordering key that says so.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SourceTextAlignment {
    /// The auxiliary segment transcribes exactly this row's words.
    Exact,
    /// The auxiliary segment's words are a contiguous run inside this row's.
    /// `canonical_chars` is the normalized length of the containing row, so a
    /// caller can prefer the tightest container over a long row that merely
    /// happens to swallow the same phrase.
    Contained { canonical_chars: usize },
    /// No usable word evidence. Only timestamps are left to align by.
    Unrelated,
}

/// Below this length a containment hit is coincidence rather than evidence:
/// a single character recurs throughout a conversation, so it would bind to
/// whichever long row happened to be shortest.
pub const MINIMUM_CONTAINED_ALIGNMENT_CHARS: usize = 2;

/// Comparison form for cross-stream source text: case folded, with whitespace
/// and punctuation removed. Punctuation is exactly what two connections
/// disagree about most, and dropping it costs no discrimination because the
/// remaining words already identify the segment.
pub fn normalized_alignment_text(value: &str) -> String {
    value
        .chars()
        .filter(|character| !is_alignment_noise(*character))
        .flat_map(char::to_lowercase)
        .collect()
}

/// Explicit ranges rather than a general category lookup: `char::is_alphanumeric`
/// would be shorter but drops Thai vowel signs and tone marks, which are
/// nonspacing marks and carry real lexical content in a Thai source lane.
fn is_alignment_noise(character: char) -> bool {
    if character.is_whitespace() {
        return true;
    }
    if character.is_ascii() {
        return character.is_ascii_punctuation();
    }
    matches!(
        character,
        '\u{00A1}' | '\u{00A7}' | '\u{00B6}' | '\u{00B7}' | '\u{00BF}'
            | '\u{2000}'..='\u{206F}'
            | '\u{3000}'..='\u{303F}'
            | '\u{FF01}'..='\u{FF0F}'
            | '\u{FF1A}'..='\u{FF20}'
            | '\u{FF3B}'..='\u{FF40}'
            | '\u{FF5B}'..='\u{FF65}'
    )
}

/// Relates one auxiliary segment's source text to one canonical row's.
///
/// Deliberately one-directional. The reverse relation — a canonical row
/// contained in a coarser auxiliary segment — is not evidence for *this* row
/// over the next one, because the same segment contains both; that case stays
/// with the timestamp fallback.
pub fn align_source_text(auxiliary: &str, canonical: &str) -> SourceTextAlignment {
    let auxiliary = normalized_alignment_text(auxiliary);
    if auxiliary.is_empty() {
        return SourceTextAlignment::Unrelated;
    }
    let canonical = normalized_alignment_text(canonical);
    if auxiliary == canonical {
        return SourceTextAlignment::Exact;
    }
    if auxiliary.chars().count() >= MINIMUM_CONTAINED_ALIGNMENT_CHARS
        && canonical.contains(&auxiliary)
    {
        return SourceTextAlignment::Contained {
            canonical_chars: canonical.chars().count(),
        };
    }
    SourceTextAlignment::Unrelated
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn token_roundtrip_preserves_anonymous_speaker_label() {
        let token = Token {
            text: "Hello".into(),
            start_ms: 1_000,
            end_ms: 1_500,
            is_final: true,
            language: "en".into(),
            speaker: Some("1".into()),
            confidence: 0.95,
            translation_status: TranslationStatus::Original,
        };

        let json = serde_json::to_string(&token).unwrap();
        assert!(json.contains(r#""speaker":"1""#));
        let decoded: Token = serde_json::from_str(&json).unwrap();
        assert_eq!(decoded.text, token.text);
        assert_eq!(decoded.start_ms, token.start_ms);
        assert_eq!(decoded.speaker, token.speaker);
    }

    #[test]
    fn token_without_speaker_remains_backward_compatible() {
        let decoded: Token = serde_json::from_str(
            r#"{
                "text":"Hello",
                "start_ms":1000,
                "end_ms":1500,
                "is_final":true,
                "language":"en",
                "confidence":0.95,
                "translation_status":"Original"
            }"#,
        )
        .unwrap();

        assert_eq!(decoded.speaker, None);
    }

    #[test]
    fn punctuation_and_spacing_differences_do_not_break_an_exact_alignment() {
        // The canonical connection and the translating connection heard the
        // same sentence and punctuated it differently.
        assert_eq!(
            align_source_text(" 是，是，是。 然后。", "是,是,是 然后"),
            SourceTextAlignment::Exact
        );
        assert_eq!(
            align_source_text("Not important.", "not important"),
            SourceTextAlignment::Exact
        );
    }

    #[test]
    fn a_finer_auxiliary_segment_is_contained_in_the_row_that_holds_its_words() {
        let alignment = align_source_text(
            "因为他觉得重要的是要超越这个东西。",
            "不重要，因为他觉得重要的是要超越这个东西。",
        );
        assert_eq!(
            alignment,
            SourceTextAlignment::Contained {
                canonical_chars: "不重要因为他觉得重要的是要超越这个东西".chars().count()
            }
        );
    }

    #[test]
    fn thai_vowel_signs_and_tone_marks_survive_normalization() {
        // These are nonspacing marks; dropping them would collapse distinct
        // Thai words onto the same comparison form.
        assert_eq!(normalized_alignment_text("ไม่สำคัญ"), "ไม่สำคัญ");
        assert_eq!(
            align_source_text("ไม่สำคัญ", "ไม่สำคัญ"),
            SourceTextAlignment::Exact
        );
    }

    #[test]
    fn a_single_character_is_never_contained_evidence() {
        assert_eq!(
            align_source_text("对", "对，这个与其说是矛盾，不能说是分裂。"),
            SourceTextAlignment::Unrelated
        );
        // It is still exact evidence against a row that is only that word.
        assert_eq!(align_source_text("对", "对。"), SourceTextAlignment::Exact);
    }

    #[test]
    fn an_empty_or_punctuation_only_segment_carries_no_evidence() {
        assert_eq!(align_source_text("", "anything"), SourceTextAlignment::Unrelated);
        assert_eq!(
            align_source_text("。 ", "anything"),
            SourceTextAlignment::Unrelated
        );
    }

    #[test]
    fn a_coarser_auxiliary_segment_is_not_contained_evidence() {
        // The row's words sit inside the segment, not the other way round; the
        // very next row's words do too, so this cannot pick between them.
        assert_eq!(
            align_source_text("对，这个与其说是矛盾。", "对。"),
            SourceTextAlignment::Unrelated
        );
    }

    #[test]
    fn privacy_level_values_remain_stable() {
        assert_eq!(
            serde_json::to_string(&PrivacyLevel::Maximum).unwrap(),
            "\"Maximum\""
        );
    }
}
