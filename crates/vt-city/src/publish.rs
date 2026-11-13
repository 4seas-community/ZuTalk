//! A finished recording's transcript, as the records a city's archive reads.
//!
//! The city models a recording as a *take* (`tape/take`, linking the event)
//! and everything said in it as records that link the take: the sentences
//! (`tape/text`), per-language translations (`tape/tr`), speaker names
//! (`tape/who`), highlights (`tape/mark`), later corrections (`tape/fix`) and
//! the end (`tape/end`). The archive item people open is an `arc/block` of
//! kind `audio` that names the take, placed into the event's channel — and
//! any other channel — by an `arc/connect`.
//!
//! This device publishes **text only**: no audio segments (`tape/part`) and
//! no files. The archive page copes — it takes the length from the block and
//! shows the transcript, speakers, languages and highlights — but it has
//! nothing to play.
//!
//! A sentence's start time in milliseconds is its key. Translations and
//! corrections find their sentence by it, so two sentences may not share one.
//!
//! Records are chained: each depends on the one signed before it, the first
//! on the author's identity number. Their times step by a millisecond from
//! `now_ms`, which keeps "signed later" meaning "comes later" for readers
//! that break ties by time.

use std::collections::{BTreeMap, BTreeSet, HashSet};

use serde_json::{json, Value};

use crate::error::{CityError, Result};
use crate::identity::Identity;
use crate::record::{self, Signed};
use crate::text::{is_id, js_trim, utf16_len, utf16_prefix};

/// Readers keep this many UTF-16 units of a sentence and drop the rest.
pub const SENTENCE_MAX: usize = 2_000;
/// Readers keep this many UTF-16 units of a translated sentence.
pub const TRANSLATION_MAX: usize = 4_000;
/// Readers keep this many UTF-16 units of a speaker's label.
pub const SPEAKER_LABEL_MAX: usize = 8;
/// Readers keep this many UTF-16 units of a speaker's name.
pub const SPEAKER_NAME_MAX: usize = 40;
/// The city's own recorder titles an archive item with at most this many.
pub const TITLE_MAX: usize = 60;
/// Sentences per `tape/text` record. Readers accept ten times as many; the
/// city's recorder signs one such record a minute, and small records keep a
/// batch well inside the server's limit.
pub const SENTENCES_PER_RECORD: usize = 200;
/// Sentences per `tape/tr` record, as the city's own translator writes them.
pub const TRANSLATIONS_PER_RECORD: usize = 60;
/// A soft ceiling on the text carried by one record, so that even a run of
/// maximal sentences cannot produce a record too large to post.
const RECORD_TEXT_BYTES: usize = 200_000;

/// One sentence of the transcript.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Sentence {
    /// Start, in milliseconds from the start of the recording. The key.
    pub t_ms: i64,
    pub d_ms: i64,
    /// A stable label for who spoke (see [`speaker_label`]); empty when
    /// unknown.
    pub speaker: String,
    pub text: String,
}

/// One translated sentence.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Translated {
    pub t_ms: i64,
    /// The source sentence this was translated from. If the published
    /// sentence has since changed, readers mark the translation stale.
    pub source_text: String,
    pub text: String,
}

/// A finished recording to publish.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct TakeInput {
    pub event_id: String,
    pub title: String,
    /// When recording began, in milliseconds since the Unix epoch.
    pub started_ms: i64,
    pub duration_ms: i64,
    pub sentences: Vec<Sentence>,
    /// Per language (BCP 47), the translated sentences.
    pub translations: Vec<(String, Vec<Translated>)>,
    /// Speaker label (as in [`Sentence::speaker`]) to display name.
    pub speakers: Vec<(String, String)>,
    pub marks_ms: Vec<i64>,
    /// Channels, besides the event's own, to place the recording in.
    pub channel_ids: Vec<String>,
}

/// The signed records of one recording, in the order they were signed.
#[derive(Debug, Clone, PartialEq)]
pub struct BuiltTake {
    pub take_id: String,
    pub block_id: String,
    pub records: Vec<Value>,
}

/// A corrected sentence. An empty text hides the sentence.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Correction {
    pub t_ms: i64,
    pub text: String,
}

/// Signs records one after another, each depending on the last.
struct Chain<'a> {
    who: &'a Identity,
    at: i64,
    dep: String,
    out: Vec<Value>,
}

impl<'a> Chain<'a> {
    fn new(who: &'a Identity, now_ms: i64, first_dep: &str) -> Self {
        Chain {
            who,
            at: now_ms,
            dep: first_dep.to_string(),
            out: Vec::new(),
        }
    }

    fn sign(&mut self, kind: &str, body: Value, links: &[&str]) -> Result<String> {
        let links: Vec<String> = links.iter().map(|link| link.to_string()).collect();
        let Signed { id, rec } = record::make(
            self.who,
            kind,
            body,
            &links,
            std::slice::from_ref(&self.dep),
            self.at,
        )?;
        self.at += 1;
        self.dep = id.clone();
        self.out.push(rec);
        Ok(id)
    }
}

/// Builds every record of a recording. The same input and `now_ms` always
/// produce the same records, byte for byte, so a publish that was cut short
/// can be built again and re-posted without duplicating anything.
pub fn build_take(who: &Identity, input: &TakeInput, now_ms: i64) -> Result<BuiltTake> {
    if !is_id(&input.event_id) {
        return Err(CityError::malformed("not an event"));
    }
    if input.started_ms < 0 || input.duration_ms < 0 {
        return Err(CityError::malformed(
            "a recording cannot start or last a negative time",
        ));
    }
    let mut channels: Vec<&str> = Vec::new();
    for channel in &input.channel_ids {
        if !is_id(channel) {
            return Err(CityError::malformed("not a channel"));
        }
        // The event is its own channel and is always connected.
        if channel != &input.event_id && !channels.contains(&channel.as_str()) {
            channels.push(channel);
        }
    }

    let sentences = clean_sentences(&input.sentences)?;
    let spoken: HashSet<i64> = sentences.iter().map(|sentence| sentence.t_ms).collect();
    let languages = clean_translations(&input.translations)?;
    if languages
        .values()
        .flat_map(BTreeMap::keys)
        .any(|t_ms| !spoken.contains(t_ms))
    {
        return Err(CityError::malformed(
            "a translation is for a sentence the take does not have",
        ));
    }
    let mut marks = BTreeSet::new();
    for mark in &input.marks_ms {
        if *mark < 0 {
            return Err(CityError::malformed(
                "a highlight cannot come before the start",
            ));
        }
        marks.insert(*mark);
    }

    let mut chain = Chain::new(who, now_ms, who.id());
    let take_id = chain.sign(
        "tape/take",
        json!({ "mime": "", "started": input.started_ms }),
        &[input.event_id.as_str()],
    )?;
    for chunk in chunks(&sentences, SENTENCES_PER_RECORD, |sentence| {
        sentence.text.len()
    }) {
        let segs: Vec<Value> = chunk
            .iter()
            .map(|sentence| {
                json!({
                    "t": sentence.t_ms,
                    "d": sentence.d_ms,
                    "sp": speaker_label(sentence.speaker),
                    "text": sentence.text,
                })
            })
            .collect();
        chain.sign("tape/text", json!({ "segs": segs }), &[take_id.as_str()])?;
    }
    // One name per label, in label order, so the output does not depend on
    // the order the caller listed them in.
    let mut named: BTreeMap<String, &str> = BTreeMap::new();
    for (speaker, name) in &input.speakers {
        let (label, name) = (
            speaker_label(speaker),
            utf16_prefix(js_trim(name), SPEAKER_NAME_MAX),
        );
        if !label.is_empty() && !name.is_empty() {
            named.insert(label, name);
        }
    }
    for (label, name) in named {
        chain.sign(
            "tape/who",
            json!({ "sp": label, "name": name }),
            &[take_id.as_str()],
        )?;
    }
    for mark in marks {
        chain.sign("tape/mark", json!({ "t": mark }), &[take_id.as_str()])?;
    }
    sign_translations(&mut chain, &take_id, &languages)?;
    chain.sign("tape/end", json!({}), &[take_id.as_str()])?;
    let block_id = chain.sign(
        "arc/block",
        json!({
            "kind": "audio",
            "title": utf16_prefix(js_trim(&input.title), TITLE_MAX),
            "take": take_id,
            "dur": input.duration_ms,
        }),
        &[take_id.as_str()],
    )?;
    chain.sign(
        "arc/connect",
        json!({}),
        &[input.event_id.as_str(), block_id.as_str()],
    )?;
    for channel in channels {
        chain.sign("arc/connect", json!({}), &[channel, block_id.as_str()])?;
    }
    Ok(BuiltTake {
        take_id,
        block_id,
        records: chain.out,
    })
}

/// Builds the records for changes made after publishing: corrected sentences
/// and new or re-done translations. A correction makes that sentence's
/// earlier translations stale until one made from the corrected text is sent.
///
/// Only the author of the take is believed for corrections; these records
/// belong on the event's tag.
pub fn build_update(
    who: &Identity,
    take_id: &str,
    fixes: &[Correction],
    translations: &[(String, Vec<Translated>)],
    now_ms: i64,
) -> Result<Vec<Value>> {
    if !is_id(take_id) {
        return Err(CityError::malformed("not a take"));
    }
    let languages = clean_translations(translations)?;
    let mut chain = Chain::new(who, now_ms, take_id);
    let mut fixed = BTreeMap::new();
    for fix in fixes {
        if fix.t_ms < 0 {
            return Err(CityError::malformed(
                "a sentence cannot start before the recording",
            ));
        }
        fixed.insert(fix.t_ms, clean_text(&fix.text, SENTENCE_MAX));
    }
    for (t_ms, text) in fixed {
        chain.sign("tape/fix", json!({ "t": t_ms, "text": text }), &[take_id])?;
    }
    sign_translations(&mut chain, take_id, &languages)?;
    Ok(chain.out)
}

/// Builds the record that withdraws an archive item. The city's server
/// deletes the item's content when it accepts this from the item's author and
/// refuses to take the item back; it belongs on every tag the item was sent
/// to.
///
/// The transcript records of the take are not items and are not deleted by
/// this: a city's log is append-only, and what was said in it stays said.
pub fn build_withdraw(who: &Identity, block_id: &str, now_ms: i64) -> Result<Vec<Value>> {
    if !is_id(block_id) {
        return Err(CityError::malformed("not an archive item"));
    }
    let mut chain = Chain::new(who, now_ms, block_id);
    chain.sign("arc/mark", json!({ "to": "drop" }), &[block_id])?;
    Ok(chain.out)
}

/// Splits records into batches a server will take: each starts with the
/// author's card, and written out as JSON no batch exceeds `max_bytes`
/// (unless a single record does on its own, which the server will refuse
/// whatever is done here). The order is kept, so an earlier batch never
/// needs a later one to be understood.
pub fn batches(card: &[Value], records: &[Value], max_bytes: usize) -> Vec<Vec<Value>> {
    let size = |rec: &Value| serde_json::to_vec(rec).map_or(0, |bytes| bytes.len());
    let key = |rec: &Value| record::signature_of(rec).unwrap_or_else(|| rec.to_string());
    let mut seen = HashSet::new();
    let head: Vec<&Value> = card.iter().filter(|rec| seen.insert(key(rec))).collect();
    let rest: Vec<&Value> = records.iter().filter(|rec| seen.insert(key(rec))).collect();
    if rest.is_empty() {
        return Vec::new();
    }
    // A JSON array: two brackets, and a comma after every record but the last.
    let head_bytes: usize = 2 + head.iter().map(|rec| size(rec) + 1).sum::<usize>();
    let mut out: Vec<Vec<Value>> = Vec::new();
    let mut current: Vec<Value> = Vec::new();
    let mut bytes = head_bytes;
    for rec in rest {
        let add = size(rec) + 1;
        if !current.is_empty() && bytes + add > max_bytes.saturating_add(1) {
            out.push(std::mem::take(&mut current));
            bytes = head_bytes;
        }
        if current.is_empty() {
            current.extend(head.iter().map(|rec| (*rec).clone()));
        }
        current.push(rec.clone());
        bytes += add;
    }
    out.push(current);
    out
}

/// The records of a build that belong on one tag, as the city's own apps
/// divide them: a city tag gets the archive item and its placements; an
/// event tag gets the take and everything said in it, the item, and its
/// placement in that event — but not placements into other channels, which
/// are the city's business.
pub fn for_tag(tag: &str, records: &[Value]) -> Vec<Value> {
    let event = tag.strip_prefix("ev:");
    let city = tag.starts_with("polis:");
    records
        .iter()
        .filter(|rec| {
            let kind = rec["e"]["type"].as_str().unwrap_or("");
            let target = rec["e"]["links"][0].as_str().unwrap_or("");
            match (city, event) {
                (true, _) => kind.starts_with("arc/"),
                (false, Some(prefix)) => kind != "arc/connect" || target.starts_with(prefix),
                (false, None) => true,
            }
        })
        .cloned()
        .collect()
}

/// The mark the city keeps of the sentence a translation was made from:
/// 32-bit FNV-1a over the sentence's UTF-16 code units, eight hex digits. It
/// detects a later correction; it is not a commitment (the signature is).
pub fn text_mark(text: &str) -> String {
    let mut hash: u32 = 0x811c_9dc5;
    for unit in text.encode_utf16() {
        hash ^= u32::from(unit);
        hash = hash.wrapping_mul(0x0100_0193);
    }
    format!("{hash:08x}")
}

/// The label a speaker is published under. Readers keep eight UTF-16 units
/// of a label, show an unnamed speaker as "Speaker <label>", and match names
/// to sentences by it — so a label that fits is used as given, and a longer
/// one is replaced by a short stable digest rather than cut (two speakers
/// whose labels share a prefix would otherwise become one).
///
/// Anything that signs a sentence's `sp` or a `tape/who` outside this module
/// must use the same function, or names stop matching.
pub fn speaker_label(speaker: &str) -> String {
    if utf16_len(speaker) <= SPEAKER_LABEL_MAX {
        speaker.to_string()
    } else {
        text_mark(speaker)
    }
}

/// A language tag in the city's vocabulary. The city writes Simplified
/// Chinese as `zh` and Traditional as `zh-Hant`, and its readers pick a
/// transcript language by the bare primary subtag, so `zh-Hans` or `pt-BR`
/// published as given would sit unselected behind the original. `None` when
/// the tag is not one the city's readers accept at all.
pub fn city_language(tag: &str) -> Option<String> {
    let mut parts = tag.split(['-', '_']);
    let primary = parts.next()?.to_ascii_lowercase();
    if !(2..=3).contains(&primary.len()) || !primary.bytes().all(|byte| byte.is_ascii_lowercase()) {
        return None;
    }
    let rest: Vec<String> = parts.map(str::to_ascii_lowercase).collect();
    if rest.len() > 3
        || rest.iter().any(|part| {
            !(2..=8).contains(&part.len()) || !part.bytes().all(|byte| byte.is_ascii_alphanumeric())
        })
    {
        return None;
    }
    let traditional = rest
        .iter()
        .any(|part| matches!(part.as_str(), "hant" | "tw" | "hk" | "mo"));
    Some(match (primary.as_str(), traditional) {
        ("zh", true) => "zh-Hant".to_string(),
        _ => primary,
    })
}

struct CleanSentence<'a> {
    t_ms: i64,
    d_ms: i64,
    speaker: &'a str,
    text: &'a str,
}

/// Trims and caps text the way readers would, so that the mark computed
/// here is the mark they compute.
fn clean_text(text: &str, max: usize) -> &str {
    utf16_prefix(js_trim(text), max)
}

fn clean_sentences(sentences: &[Sentence]) -> Result<Vec<CleanSentence<'_>>> {
    let mut seen = HashSet::new();
    let mut out = Vec::with_capacity(sentences.len());
    for sentence in sentences {
        if sentence.t_ms < 0 {
            return Err(CityError::malformed(
                "a sentence cannot start before the recording",
            ));
        }
        if !seen.insert(sentence.t_ms) {
            return Err(CityError::malformed(
                "two sentences start at the same millisecond",
            ));
        }
        let text = clean_text(&sentence.text, SENTENCE_MAX);
        // Readers skip a sentence with nothing in it; so nothing is signed.
        if text.is_empty() {
            continue;
        }
        out.push(CleanSentence {
            t_ms: sentence.t_ms,
            d_ms: sentence.d_ms.max(0),
            speaker: sentence.speaker.as_str(),
            text,
        });
    }
    out.sort_by_key(|sentence| sentence.t_ms);
    Ok(out)
}

type Languages<'a> = BTreeMap<String, BTreeMap<i64, (String, &'a str)>>;

/// Per city language, per sentence time: the source mark and the text.
fn clean_translations(translations: &[(String, Vec<Translated>)]) -> Result<Languages<'_>> {
    let mut out: Languages<'_> = BTreeMap::new();
    for (language, lines) in translations {
        let language = city_language(language)
            .ok_or_else(|| CityError::malformed("not a language the city reads"))?;
        let entry = out.entry(language).or_default();
        for line in lines {
            if line.t_ms < 0 {
                return Err(CityError::malformed(
                    "a sentence cannot start before the recording",
                ));
            }
            let text = clean_text(&line.text, TRANSLATION_MAX);
            if text.is_empty() {
                continue;
            }
            let mark = text_mark(clean_text(&line.source_text, SENTENCE_MAX));
            entry.insert(line.t_ms, (mark, text));
        }
    }
    out.retain(|_, lines| !lines.is_empty());
    Ok(out)
}

fn sign_translations(
    chain: &mut Chain<'_>,
    take_id: &str,
    languages: &Languages<'_>,
) -> Result<()> {
    for (language, lines) in languages {
        let lines: Vec<(&i64, &(String, &str))> = lines.iter().collect();
        for chunk in chunks(&lines, TRANSLATIONS_PER_RECORD, |(_, (_, text))| text.len()) {
            let segs: Vec<Value> = chunk
                .iter()
                .map(|(t_ms, (mark, text))| json!({ "t": t_ms, "of": mark, "text": text }))
                .collect();
            chain.sign(
                "tape/tr",
                json!({ "lang": language, "segs": segs }),
                &[take_id],
            )?;
        }
    }
    Ok(())
}

/// Consecutive runs of at most `count` items whose text adds up to at most
/// the per-record ceiling (a single oversized item still gets a run).
fn chunks<T>(items: &[T], count: usize, text_bytes: impl Fn(&T) -> usize) -> Vec<&[T]> {
    let mut out = Vec::new();
    let (mut start, mut bytes) = (0, 0);
    for (index, item) in items.iter().enumerate() {
        let add = text_bytes(item);
        if index > start && (index - start >= count || bytes + add > RECORD_TEXT_BYTES) {
            out.push(&items[start..index]);
            (start, bytes) = (index, 0);
        }
        bytes += add;
    }
    if start < items.len() {
        out.push(&items[start..]);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mark_hashes_utf16_units() {
        assert_eq!(text_mark(""), "811c9dc5");
        assert_eq!(text_mark("a"), "e40c292c");
        // One astral character is two units (D83D DE00), not four bytes.
        let mut hash = 0x811c_9dc5u32;
        for unit in [0xd83du32, 0xde00] {
            hash = (hash ^ unit).wrapping_mul(0x0100_0193);
        }
        assert_eq!(text_mark("😀"), format!("{hash:08x}"));
        assert_eq!(utf16_len("😀"), 2);
    }

    #[test]
    fn languages_are_written_as_the_city_writes_them() {
        for (given, want) in [
            ("zh-Hans", "zh"),
            ("zh-CN", "zh"),
            ("zh", "zh"),
            ("zh-Hant-TW", "zh-Hant"),
            ("zh_HK", "zh-Hant"),
            ("en-US", "en"),
            ("TH", "th"),
            ("pt-BR", "pt"),
            ("yue", "yue"),
        ] {
            assert_eq!(city_language(given).as_deref(), Some(want), "{given}");
        }
        for bad in ["", "e", "english", "en-", "en-x", "12", "en-US-a-b-c"] {
            assert_eq!(city_language(bad), None, "{bad}");
        }
    }

    #[test]
    fn speaker_labels_fit_what_readers_keep() {
        assert_eq!(speaker_label(""), "");
        assert_eq!(speaker_label("1"), "1");
        assert_eq!(speaker_label("12345678"), "12345678");
        let long = speaker_label("speaker-0001");
        assert_eq!(long.len(), 8);
        assert_eq!(long, speaker_label("speaker-0001"));
        assert_ne!(long, speaker_label("speaker-0002"));
    }

    #[test]
    fn chunks_respect_count_and_size() {
        let items: Vec<usize> = vec![1; 7];
        let runs = chunks(&items, 3, |_| 1);
        assert_eq!(
            runs.iter().map(|run| run.len()).collect::<Vec<_>>(),
            [3, 3, 1]
        );
        let heavy = [RECORD_TEXT_BYTES, 10, RECORD_TEXT_BYTES + 5, 1];
        let runs = chunks(&heavy, 10, |bytes| *bytes);
        assert_eq!(
            runs.iter().map(|run| run.len()).collect::<Vec<_>>(),
            [1, 1, 1, 1]
        );
        assert!(chunks(&[] as &[usize], 3, |_| 1).is_empty());
    }
}
