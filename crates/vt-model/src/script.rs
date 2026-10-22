//! Which writing system a piece of text is in, for the languages whose
//! script alone says which language it can be.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Script {
    Latin,
    Han,
    Kana,
    Hangul,
    Thai,
    Lao,
    Khmer,
    Myanmar,
    Cyrillic,
    Greek,
    Arabic,
    Hebrew,
    Devanagari,
}

fn script_of(character: char) -> Option<Script> {
    let code = character as u32;
    Some(match code {
        0x0041..=0x005A | 0x0061..=0x007A | 0x00C0..=0x024F | 0x1E00..=0x1EFF => Script::Latin,
        0x0370..=0x03FF => Script::Greek,
        0x0400..=0x052F => Script::Cyrillic,
        0x0590..=0x05FF => Script::Hebrew,
        0x0600..=0x06FF | 0x0750..=0x077F => Script::Arabic,
        0x0900..=0x097F => Script::Devanagari,
        0x0E00..=0x0E7F => Script::Thai,
        0x0E80..=0x0EFF => Script::Lao,
        0x1000..=0x109F => Script::Myanmar,
        0x1780..=0x17FF => Script::Khmer,
        0x1100..=0x11FF | 0x3130..=0x318F | 0xAC00..=0xD7AF => Script::Hangul,
        0x3040..=0x30FF | 0x31F0..=0x31FF => Script::Kana,
        0x3400..=0x4DBF | 0x4E00..=0x9FFF | 0xF900..=0xFAFF => Script::Han,
        _ => return None,
    })
}

/// The scripts a language is written in, for languages identified by it.
fn scripts_of_language(language: &str) -> Option<&'static [Script]> {
    let primary = language
        .trim()
        .split(['-', '_'])
        .next()
        .unwrap_or_default()
        .to_ascii_lowercase();
    Some(match primary.as_str() {
        "zh" | "yue" => &[Script::Han],
        "ja" => &[Script::Han, Script::Kana],
        "ko" => &[Script::Hangul, Script::Han],
        "th" => &[Script::Thai],
        "lo" => &[Script::Lao],
        "km" => &[Script::Khmer],
        "my" => &[Script::Myanmar],
        "ru" | "uk" | "bg" | "sr" | "mk" | "be" | "kk" => &[Script::Cyrillic],
        "el" => &[Script::Greek],
        "ar" | "fa" | "ur" => &[Script::Arabic],
        "he" => &[Script::Hebrew],
        "hi" | "mr" | "ne" => &[Script::Devanagari],
        "en" | "fr" | "de" | "es" | "it" | "pt" | "nl" | "sv" | "da" | "no" | "nb" | "fi"
        | "pl" | "cs" | "sk" | "hu" | "ro" | "tr" | "id" | "ms" | "vi" | "tl" | "ca" | "hr"
        | "sl" | "et" | "lv" | "lt" | "sw" => &[Script::Latin],
        _ => return None,
    })
}

/// Whether `text` is plainly not written in `language`: it has letters, and
/// none of them are in a script the language uses.
///
/// False whenever it cannot tell — a language it does not know, or text with
/// no letters — and for any mix, since speakers switch languages inside a
/// sentence. A caller only ever acts on a clear contradiction.
pub fn script_contradicts_language(text: &str, language: &str) -> bool {
    let Some(expected) = scripts_of_language(language) else {
        return false;
    };
    let mut letters = 0usize;
    let mut in_expected = 0usize;
    for character in text.chars() {
        let Some(script) = script_of(character) else {
            continue;
        };
        letters += 1;
        if expected.contains(&script) {
            in_expected += 1;
        }
    }
    letters > 0 && in_expected == 0
}

/// The one language among `candidates` whose writing `text` is in, when its
/// letters are all in one script other than Latin and only that language
/// uses it — Thai letters with Thai selected, Chinese characters with
/// Chinese and not Japanese. Latin letters say nothing: they are the English
/// words people put into Thai and Chinese speech as often as they are
/// English.
pub fn language_written_in<'a>(
    text: &str,
    candidates: impl IntoIterator<Item = &'a str>,
) -> Option<&'a str> {
    let mut script = None;
    for character in text.chars() {
        let Some(found) = script_of(character) else {
            continue;
        };
        match script {
            None => script = Some(found),
            Some(current) if current == found => {}
            Some(_) => return None,
        }
    }
    let script = script.filter(|script| *script != Script::Latin)?;
    let mut writers = candidates.into_iter().filter(|language| {
        scripts_of_language(language).is_some_and(|scripts| scripts.contains(&script))
    });
    let only = writers.next()?;
    writers.next().is_none().then_some(only)
}

/// Whether every letter of `text` is Latin, and there is at least one.
pub fn is_latin_text(text: &str) -> bool {
    let mut letters = text.chars().filter_map(script_of).peekable();
    letters.peek().is_some() && letters.all(|script| script == Script::Latin)
}

#[cfg(test)]
mod tests {
    use super::{is_latin_text, language_written_in, script_contradicts_language};

    #[test]
    fn a_label_is_contradicted_only_by_text_with_none_of_its_script() {
        assert!(script_contradicts_language("我们走吧", "th"));
        assert!(!script_contradicts_language("我们走吧", "zh"));
        assert!(!script_contradicts_language("我们走吧", "ja"));
        assert!(script_contradicts_language("ไปกันเถอะ", "zh"));
        assert!(!script_contradicts_language("ไปกันเถอะ", "th"));
        assert!(script_contradicts_language("ไปกันเถอะ", "en"));
        assert!(!script_contradicts_language("Okay, ไปกันเถอะ ครับ", "th"));
        assert!(!script_contradicts_language("ZuTalk 很好用", "zh"));
        // Nothing to go on: never a contradiction.
        assert!(!script_contradicts_language("123 …", "th"));
        assert!(!script_contradicts_language("我们走吧", "und"));
        assert!(!script_contradicts_language("我们走吧", "xx"));
        assert!(!script_contradicts_language("我们走吧", "zh-Hant"));
    }

    #[test]
    fn letters_of_one_language_name_it_and_latin_letters_name_none() {
        let three = ["th", "zh", "en"];
        assert_eq!(language_written_in(" ภาษาไทย.", three), Some("th"));
        assert_eq!(language_written_in("我们", three), Some("zh"));
        assert_eq!(language_written_in(" Class", three), None);
        assert_eq!(language_written_in("我们 ok", three), None);
        assert_eq!(
            language_written_in("我们", ["zh", "ja"]),
            None,
            "both write Han"
        );
        assert_eq!(language_written_in("123 ", three), None);
        assert!(is_latin_text(" Class"));
        assert!(!is_latin_text(" ภาษา"));
        assert!(!is_latin_text(" 2026"));
    }
}
