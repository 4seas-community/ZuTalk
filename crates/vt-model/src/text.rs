//! Text as the provider sends it, set the way people write it.
//!
//! Soniox spells two things differently from how they are typed:
//!
//! - Thai SARA AM arrives decomposed, as NIKHAHIT (U+0E4D) followed by SARA AA
//!   (U+0E32), on every occurrence and sometimes split across two tokens.
//!   Every keyboard types the single U+0E33. The two look the same on screen,
//!   so nobody notices until a search, a copy into another app or a
//!   comparison finds nothing.
//! - Chinese and Japanese carry spaces beside full-width punctuation — after
//!   `。` and `，` — where the punctuation already is the pause. A space
//!   between two characters stays: the provider puts one where it heard a
//!   pause and wrote no punctuation, and without it two sentences run
//!   together.
//!
//! Machine text is normalized where it enters the system — the realtime
//! segment assembler and the post-stop token stream — and never afterwards:
//! stored text is provider evidence that later reads compare byte for byte,
//! and a user's own edit is theirs.

use std::borrow::Cow;

const NIKHAHIT: char = '\u{0E4D}';
const SARA_AA: char = '\u{0E32}';
const SARA_AM: char = '\u{0E33}';

fn is_thai_tone_mark(character: char) -> bool {
    matches!(character, '\u{0E48}'..='\u{0E4B}')
}

/// Han ideographs and kana: scripts set without spaces between words.
pub fn is_han_or_kana(character: char) -> bool {
    matches!(character as u32,
        0x3040..=0x30FF     // kana
        | 0x3400..=0x9FFF   // CJK extension A through unified ideographs
        | 0xF900..=0xFAFF   // compatibility ideographs
    )
}

/// Thai, which sets words without spaces but uses a space between phrases
/// and sentences — so a space in Thai is text, not noise.
pub fn is_thai(character: char) -> bool {
    matches!(character as u32, 0x0E00..=0x0E7F)
}

/// Every script whose words run together, so that a word can begin anywhere
/// inside a run: Han and kana, Thai, Lao, Myanmar and Khmer. Word-based
/// full-text tokenizers cannot find the edges of a word in these.
pub fn is_unspaced_script(character: char) -> bool {
    is_han_or_kana(character)
        || matches!(character as u32,
            0x0E00..=0x0E7F     // Thai
            | 0x0E80..=0x0EFF   // Lao
            | 0x1000..=0x109F   // Myanmar
            | 0x1780..=0x17FF   // Khmer
        )
}

/// Punctuation drawn on a full-width body: it carries its own sidebearing, so
/// a space beside it reads as a gap rather than as word separation.
pub fn is_wide_punctuation(character: char) -> bool {
    matches!(character as u32,
        0x3000..=0x303F     // CJK symbols and punctuation, incl. the ideographic space
        | 0xFF01..=0xFF20   // fullwidth ASCII punctuation and digits' neighbours
        | 0xFF3B..=0xFF40
        | 0xFF5B..=0xFF65
    )
}

/// A space the provider put between tokens. The ideographic space is a
/// character of the text and newlines are structure; neither is removed.
fn is_provider_space(character: char) -> bool {
    matches!(character, ' ' | '\t' | '\u{00A0}' | '\u{202F}')
}

/// Whether a run of provider spaces between `previous` and `next` belongs to
/// the text. It does not beside full-width punctuation, which carries its own
/// space, or before the first character of a Chinese or Japanese text. Between
/// two Han or kana characters it does: it is the only mark of a pause the
/// provider heard and did not punctuate.
fn space_is_noise(previous: Option<char>, next: Option<char>) -> bool {
    match (previous, next) {
        (_, None) => false,
        (None, Some(next)) => is_han_or_kana(next) || is_wide_punctuation(next),
        (Some(previous), Some(next)) => is_wide_punctuation(previous) || is_wide_punctuation(next),
    }
}

/// Writes NIKHAHIT + SARA AA as SARA AM, including where a tone mark sits
/// between the two.
pub fn compose_thai_sara_am(text: &str) -> Cow<'_, str> {
    if !text.contains(NIKHAHIT) {
        return Cow::Borrowed(text);
    }
    Cow::Owned(normalize_pieces(&[text], false).remove(0))
}

/// The provider's spelling of `text`: SARA AM as NIKHAHIT + SARA AA, after
/// any tone mark. Lets a search find text stored before normalization.
pub fn decompose_thai_sara_am(text: &str) -> Cow<'_, str> {
    if !text.contains(SARA_AM) {
        return Cow::Borrowed(text);
    }
    let mut decomposed = String::with_capacity(text.len() + 4);
    for character in text.chars() {
        if character == SARA_AM {
            decomposed.push(NIKHAHIT);
            decomposed.push(SARA_AA);
        } else {
            decomposed.push(character);
        }
    }
    Cow::Owned(decomposed)
}

/// Provider text set the way it is written: SARA AM composed, and the spaces
/// beside Chinese and Japanese full-width punctuation taken out.
pub fn normalize_provider_text(text: &str) -> String {
    if !text.contains(NIKHAHIT) && !text.contains(is_provider_space) {
        return text.to_string();
    }
    normalize_pieces(&[text], true).remove(0)
}

/// [`normalize_provider_text`] over a sequence of tokens, keeping every
/// token's boundary: the result has one entry per input, and joining it is
/// the normalized join. A NIKHAHIT that ends one token and the SARA AA that
/// starts the next compose into the first; a space that opens a token after
/// `。` leaves that token shorter, possibly empty.
pub fn normalize_provider_pieces<S: AsRef<str>>(pieces: &[S]) -> Vec<String> {
    normalize_pieces(pieces, true)
}

fn normalize_pieces<S: AsRef<str>>(pieces: &[S], collapse_spaces: bool) -> Vec<String> {
    let flat: Vec<(char, usize)> = pieces
        .iter()
        .enumerate()
        .flat_map(|(index, piece)| piece.as_ref().chars().map(move |c| (c, index)))
        .collect();
    let mut output: Vec<String> = pieces
        .iter()
        .map(|piece| String::with_capacity(piece.as_ref().len()))
        .collect();
    let mut previous: Option<char> = None;
    let mut index = 0;
    while index < flat.len() {
        let (character, piece) = flat[index];
        let at = |offset: usize| flat.get(index + offset).map(|(c, _)| *c);
        if character == NIKHAHIT {
            if at(1) == Some(SARA_AA) {
                output[piece].push(SARA_AM);
                previous = Some(SARA_AM);
                index += 2;
                continue;
            }
            if let (Some(tone), Some(SARA_AA)) = (at(1), at(2)) {
                if is_thai_tone_mark(tone) {
                    output[piece].push(tone);
                    output[piece].push(SARA_AM);
                    previous = Some(SARA_AM);
                    index += 3;
                    continue;
                }
            }
        }
        if collapse_spaces && is_provider_space(character) {
            let end = flat[index..]
                .iter()
                .position(|(c, _)| !is_provider_space(*c))
                .map_or(flat.len(), |offset| index + offset);
            let next = flat.get(end).map(|(c, _)| *c);
            if !space_is_noise(previous, next) {
                for &(space, space_piece) in &flat[index..end] {
                    output[space_piece].push(space);
                }
                previous = Some(flat[end - 1].0);
            }
            index = end;
            continue;
        }
        output[piece].push(character);
        previous = Some(character);
        index += 1;
    }
    output
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sara_am_is_composed_in_both_tone_mark_orders() {
        // ทำงาน, น้ำ with the tone before and after NIKHAHIT.
        assert_eq!(compose_thai_sara_am("ท\u{0E4D}\u{0E32}งาน"), "ทำงาน");
        assert_eq!(compose_thai_sara_am("น\u{0E49}\u{0E4D}\u{0E32}"), "น้ำ");
        assert_eq!(compose_thai_sara_am("น\u{0E4D}\u{0E49}\u{0E32}"), "น้ำ");
        // A NIKHAHIT that is not followed by SARA AA is left alone.
        assert_eq!(compose_thai_sara_am("สํ"), "สํ");
        assert!(matches!(compose_thai_sara_am("ทำงาน"), Cow::Borrowed(_)));
    }

    #[test]
    fn sara_am_split_across_two_tokens_composes_into_the_first() {
        assert_eq!(
            normalize_provider_pieces(&["ท\u{0E4D}", "\u{0E32}งาน", " ครับ"]),
            vec!["ทำ", "งาน", " ครับ"]
        );
    }

    #[test]
    fn decomposing_reverses_composing_for_the_provider_order() {
        for word in ["ทำงาน", "น้ำ", "จำได้"] {
            let decomposed = decompose_thai_sara_am(word);
            assert!(decomposed.contains(NIKHAHIT));
            assert_eq!(compose_thai_sara_am(&decomposed), word);
        }
    }

    /// Spellings taken from a real three-language recording.
    #[test]
    fn chinese_loses_the_spaces_beside_full_width_punctuation() {
        assert_eq!(
            normalize_provider_text("清迈的数字社区。 以及来自多个国家的人"),
            "清迈的数字社区。以及来自多个国家的人"
        );
        assert_eq!(
            normalize_provider_text("在我们结束之前， 请记住 下周的课程将重点关注"),
            "在我们结束之前，请记住 下周的课程将重点关注"
        );
        assert_eq!(
            normalize_provider_text("支持 已分配的记录。 Mei。"),
            "支持 已分配的记录。Mei。"
        );
        assert_eq!(normalize_provider_text(" 以及"), "以及");
    }

    #[test]
    fn spaces_that_belong_to_the_text_stay() {
        // Mixed-script spacing, the pause between two Chinese sentences the
        // provider did not punctuate, Thai phrase spacing, Korean and Latin.
        for text in [
            "一起合作工作 我认为最重要的是成员之间的信任",
            "これは テスト",
            "他说 ZuTalk 很好用",
            "ผมคิดว่า เราควรเริ่มใหม่",
            "안녕하세요 반갑습니다",
            "we should start over",
            " start over",
            "trailing ",
            "第 3 章",
        ] {
            assert_eq!(normalize_provider_text(text), text, "{text}");
        }
    }

    #[test]
    fn a_token_that_is_only_a_space_after_a_full_stop_becomes_empty() {
        assert_eq!(
            normalize_provider_pieces(&["社区。", " ", "以及"]),
            vec!["社区。", "", "以及"]
        );
        assert_eq!(
            normalize_provider_pieces(&["社区。", " 以及"]),
            vec!["社区。", "以及"]
        );
    }

    #[test]
    fn unspaced_scripts_cover_thai_and_its_neighbours_but_not_korean() {
        for character in ['中', 'か', 'ท', 'ລ', 'က', 'ក'] {
            assert!(is_unspaced_script(character), "{character}");
        }
        for character in ['한', 'a', ' ', '。'] {
            assert!(!is_unspaced_script(character), "{character}");
        }
    }
}
