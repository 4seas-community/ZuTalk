//! Text as the provider sends it, set the way people write it.
//!
//! Soniox spells Thai SARA AM decomposed, as NIKHAHIT (U+0E4D) followed by
//! SARA AA (U+0E32), on every occurrence and sometimes split across two
//! tokens. Every keyboard types the single U+0E33. The two look the same on
//! screen, so nobody notices until a search, a copy into another app or a
//! comparison finds nothing.

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

/// Writes NIKHAHIT + SARA AA as SARA AM, including where a tone mark sits
/// between the two.
pub fn compose_thai_sara_am(text: &str) -> Cow<'_, str> {
    if !text.contains(NIKHAHIT) {
        return Cow::Borrowed(text);
    }
    let characters: Vec<char> = text.chars().collect();
    let mut composed = String::with_capacity(text.len());
    let mut index = 0;
    while index < characters.len() {
        let character = characters[index];
        let at = |offset: usize| characters.get(index + offset).copied();
        if character == NIKHAHIT {
            if at(1) == Some(SARA_AA) {
                composed.push(SARA_AM);
                index += 2;
                continue;
            }
            if let (Some(tone), Some(SARA_AA)) = (at(1), at(2)) {
                if is_thai_tone_mark(tone) {
                    composed.push(tone);
                    composed.push(SARA_AM);
                    index += 3;
                    continue;
                }
            }
        }
        composed.push(character);
        index += 1;
    }
    Cow::Owned(composed)
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
    fn decomposing_reverses_composing_for_the_provider_order() {
        for word in ["ทำงาน", "น้ำ", "จำได้"] {
            let decomposed = decompose_thai_sara_am(word);
            assert!(decomposed.contains(NIKHAHIT));
            assert_eq!(compose_thai_sara_am(&decomposed), word);
        }
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
