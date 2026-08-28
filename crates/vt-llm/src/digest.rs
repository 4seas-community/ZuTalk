//! Turning a marked passage into something readable.
//!
//! What arrives from a realtime lane is not prose. It is fragments, split
//! wherever the provider heard a pause, punctuated by guesswork, half of it
//! machine-translated mid-sentence. A listener who marked that passage
//! because it mattered cannot reread it later — which is the whole problem
//! this solves.
//!
//! The job is **cleanup, not summary**. The listener marked these words; they
//! want these words, legible. Compressing them into a précis would throw away
//! the thing they reached for the key to keep.

use std::time::Duration;

use serde::Deserialize;

use crate::{classify, describe_transport_failure, LanguageModelEngine, LanguageModelError};

/// One transcript row on its way to being cleaned up.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PassageLine {
    /// Who said it, when the capture knows. A passage that changes speaker
    /// mid-way reads as nonsense without this.
    pub speaker: Option<String>,
    pub source_language: String,
    pub source_text: String,
    pub translated_text: Option<String>,
}

/// Everything the cleanup needs, and deliberately nothing else.
///
/// No session id, no notebook, no title, no speaker names beyond the labels
/// the capture already assigned. What leaves the device is the passage the
/// listener marked and nothing that would identify where it came from.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PassageDigestRequest {
    pub lines: Vec<PassageLine>,
    /// The language the listener reads. The passage comes back in this
    /// language whatever was spoken — that is the point in a room they cannot
    /// follow.
    pub target_language: String,
}

/// Whether this passage is worth sending at all.
///
/// An empty or near-empty passage costs a request and returns nothing useful,
/// and every avoided request is content that stayed on the device. A mark
/// dropped on silence is a legitimate thing to do and must not become a
/// network call.
pub fn is_worth_digesting(request: &PassageDigestRequest) -> bool {
    let total: usize = request
        .lines
        .iter()
        .map(|line| {
            line.translated_text
                .as_deref()
                .unwrap_or(&line.source_text)
                .trim()
                .chars()
                .count()
        })
        .sum();
    total >= MINIMUM_PASSAGE_CHARS
}

/// Below this a passage is a few words, which are already as legible as they
/// will get — an "uh huh", a "对". Counted in characters, and set low enough
/// that a real CJK sentence clears it: eleven characters can be a complete
/// thought in Chinese and barely two words in German, so a threshold tuned to
/// English would silently exclude half the languages this app is for.
const MINIMUM_PASSAGE_CHARS: usize = 8;

/// The instruction that decides what the model is allowed to do.
///
/// Pure, and tested: this text is the entire boundary between "my marked
/// passage, readable" and "a machine's impression of my marked passage".
pub fn system_prompt(target_language: &str) -> String {
    format!(
        "You repair live speech-to-text for a listener who marked this passage \
because it mattered to them.\n\n\
The input is fragmented: split at arbitrary pauses, mispunctuated, sometimes \
cut mid-word, sometimes machine-translated mid-sentence. Your job is to make \
it readable in {target_language}.\n\n\
Rules:\n\
- Repair only. Fix punctuation, sentence boundaries, and obvious \
transcription slips. Rejoin fragments that belong to one sentence.\n\
- Do not summarize, shorten, or reorganize. The listener wants these words, \
not an account of them.\n\
- Do not add anything that was not said. If a fragment is unrecoverable, \
leave it as a fragment rather than guessing what it meant.\n\
- If the passage begins or ends mid-sentence, leave it that way. It does.\n\
- Keep speaker changes where the input marks them.\n\
- Output the repaired passage in {target_language} and nothing else: no \
preamble, no notes about what you changed, no quotation marks around it."
    )
}

/// The passage, in the plainest form that survives the trip.
pub fn user_prompt(request: &PassageDigestRequest) -> String {
    let mut out = String::new();
    for line in &request.lines {
        if let Some(speaker) = line.speaker.as_deref().filter(|s| !s.trim().is_empty()) {
            out.push_str(speaker);
            out.push_str(": ");
        }
        // The translation is what the listener was reading in the room, so it
        // leads; the source rides along because a translation of a fragment is
        // often wrong in a way the original makes obvious.
        match line
            .translated_text
            .as_deref()
            .filter(|t| !t.trim().is_empty())
        {
            Some(translated) => {
                out.push_str(translated);
                if !line.source_text.trim().is_empty() {
                    out.push_str("  [");
                    out.push_str(&line.source_language);
                    out.push_str(": ");
                    out.push_str(line.source_text.trim());
                    out.push(']');
                }
            }
            None => out.push_str(line.source_text.trim()),
        }
        out.push('\n');
    }
    out
}

/// A stable fingerprint of what a digest was built from.
///
/// Compared rather than stored ranges, because a digest goes stale for two
/// different reasons — the listener moved the boundaries, or the transcript
/// underneath improved — and only the text itself catches both.
pub fn source_fingerprint(request: &PassageDigestRequest) -> String {
    use sha2::{Digest, Sha256};
    let mut hasher = Sha256::new();
    hasher.update(request.target_language.as_bytes());
    hasher.update([0u8]);
    hasher.update(user_prompt(request).as_bytes());
    format!("{:x}", hasher.finalize())
}

#[derive(Deserialize)]
struct MessagesResponse {
    content: Vec<ContentBlock>,
}

#[derive(Deserialize)]
struct ContentBlock {
    #[serde(default)]
    text: Option<String>,
}

/// Sends one marked passage and returns it legible.
///
/// The only call in this crate that transmits user content. Everything about
/// whether it should happen — the setting, the credential, whether the passage
/// is even worth sending — is settled before control reaches here.
pub async fn digest_passage(
    engine: LanguageModelEngine,
    api_key: &str,
    request: &PassageDigestRequest,
) -> Result<String, LanguageModelError> {
    let api_key = api_key.trim();
    if api_key.is_empty() {
        return Err(LanguageModelError::EmptyCredential);
    }

    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(60))
        .build()
        .map_err(|error| LanguageModelError::NetworkUnavailable(error.to_string()))?;

    let body = serde_json::json!({
        "model": engine.model_id,
        // A repair cannot be much longer than its input, and an unbounded
        // ceiling turns one runaway response into a bill nobody expected.
        "max_tokens": 2048,
        "system": system_prompt(&request.target_language),
        "messages": [{ "role": "user", "content": user_prompt(request) }],
    });

    let response = client
        .post(format!("{}/v1/messages", engine.api_base_url))
        .header("x-api-key", api_key)
        .header("anthropic-version", engine.api_version)
        .json(&body)
        .send()
        .await
        .map_err(|error| {
            LanguageModelError::NetworkUnavailable(describe_transport_failure(&error))
        })?;

    classify(response.status().as_u16())?;

    let parsed: MessagesResponse = response.json().await.map_err(|error| {
        LanguageModelError::NetworkUnavailable(describe_transport_failure(&error))
    })?;

    let text = parsed
        .content
        .into_iter()
        .filter_map(|block| block.text)
        .collect::<Vec<_>>()
        .join("")
        .trim()
        .to_string();

    if text.is_empty() {
        return Err(LanguageModelError::EmptyResponse);
    }
    Ok(text)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn line(source: &str, translated: Option<&str>) -> PassageLine {
        PassageLine {
            speaker: None,
            source_language: "en".into(),
            source_text: source.into(),
            translated_text: translated.map(str::to_string),
        }
    }

    fn request(lines: Vec<PassageLine>) -> PassageDigestRequest {
        PassageDigestRequest {
            lines,
            target_language: "zh-Hans".into(),
        }
    }

    /// Marking a silence is a legitimate thing to do — "something happened
    /// here" — and it must not turn into a request. Every avoided call is
    /// content that stayed on the machine.
    #[test]
    fn a_passage_with_nothing_in_it_is_never_sent() {
        assert!(!is_worth_digesting(&request(vec![])));
        assert!(!is_worth_digesting(&request(vec![line("   ", None)])));
        assert!(!is_worth_digesting(&request(vec![line("yes", None)])));
        assert!(is_worth_digesting(&request(vec![line(
            "and that is the crux of the issue",
            None
        )])));
    }

    /// A threshold tuned to English would exclude languages that pack more
    /// meaning per character — half the languages this app exists for.
    #[test]
    fn a_short_cjk_sentence_still_counts_as_a_passage() {
        assert!(is_worth_digesting(&request(vec![line(
            "",
            Some("这才是问题的核心所在啊")
        )])));
        assert!(!is_worth_digesting(&request(vec![line(
            "",
            Some("对，是这样")
        )])));
    }

    /// The instruction is the entire boundary between a repaired passage and a
    /// machine's impression of one. If it ever stops forbidding summary, the
    /// feature quietly becomes something the listener did not ask for.
    #[test]
    fn the_instruction_forbids_summarising_and_inventing() {
        let prompt = system_prompt("zh-Hans").to_lowercase();
        assert!(prompt.contains("do not summarize"));
        assert!(prompt.contains("do not add anything that was not said"));
        assert!(prompt.contains("repair only"));
        assert!(prompt.contains("zh-hans"), "the reading language is named");
    }

    /// The listener read the translation in the room, so that leads; the
    /// original rides along because a translated fragment is often wrong in a
    /// way the source makes obvious.
    #[test]
    fn the_passage_leads_with_what_the_listener_read() {
        let prompt = user_prompt(&request(vec![
            line("and that is the crux", Some("这才是问题的核心")),
            line("so if we look at the data", None),
        ]));
        assert!(prompt.starts_with("这才是问题的核心"));
        assert!(prompt.contains("[en: and that is the crux]"));
        assert!(prompt.contains("so if we look at the data"));
    }

    #[test]
    fn a_speaker_label_survives_into_the_passage() {
        let mut spoken = line("we disagree", None);
        spoken.speaker = Some("Speaker 2".into());
        let prompt = user_prompt(&request(vec![spoken]));
        assert!(prompt.starts_with("Speaker 2: we disagree"));
    }

    /// Staleness has two causes — the listener moved the boundaries, or the
    /// transcript underneath improved. Only the text catches both.
    #[test]
    fn the_fingerprint_changes_with_the_text_and_with_the_language() {
        let base = request(vec![line("and that is the crux", None)]);
        let improved = request(vec![line("and that is the crux of it", None)]);
        let mut other_language = base.clone();
        other_language.target_language = "ja".into();

        assert_eq!(source_fingerprint(&base), source_fingerprint(&base.clone()));
        assert_ne!(source_fingerprint(&base), source_fingerprint(&improved));
        assert_ne!(
            source_fingerprint(&base),
            source_fingerprint(&other_language)
        );
    }

    #[tokio::test]
    async fn an_empty_credential_never_becomes_a_request() {
        let result = digest_passage(
            crate::CURRENT_LANGUAGE_MODEL_ENGINE,
            "",
            &request(vec![line("and that is the crux of the issue", None)]),
        )
        .await;
        assert!(matches!(result, Err(LanguageModelError::EmptyCredential)));
    }
}
