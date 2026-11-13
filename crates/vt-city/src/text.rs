//! Encodings the city writes by hand, and its habit of measuring text in
//! UTF-16 code units.
//!
//! The city's readers are JavaScript: a "2000 character" cap is 2000 UTF-16
//! units, and a hash over a sentence walks its `charCodeAt` values. Getting
//! any of that wrong does not fail loudly — a translation just shows up as
//! stale, or a title is cut one character differently — so the conversions
//! live in one place.

use base64::engine::general_purpose::{GeneralPurpose, GeneralPurposeConfig, URL_SAFE_NO_PAD};
use base64::engine::DecodePaddingMode;
use base64::Engine;

use crate::error::{CityError, Result};

const B58: &[u8; 58] = b"123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";

/// The longest base58 text the city will decode (a 64-byte signature is 88
/// characters). Decoding is quadratic, so the city refuses longer text
/// outright instead of letting one hostile record stall a reader; so do we.
pub(crate) const B58_MAX: usize = 128;

pub(crate) fn is_base58(byte: u8) -> bool {
    B58.contains(&byte)
}

pub(crate) fn base58(bytes: &[u8]) -> String {
    let zeros = bytes.iter().take_while(|byte| **byte == 0).count();
    // Repeated division of the big-endian number by 58, least significant
    // digit first.
    let mut digits: Vec<u8> = Vec::with_capacity(bytes.len() * 138 / 100 + 1);
    for byte in &bytes[zeros..] {
        let mut carry = u32::from(*byte);
        for digit in digits.iter_mut() {
            carry += u32::from(*digit) << 8;
            *digit = (carry % 58) as u8;
            carry /= 58;
        }
        while carry > 0 {
            digits.push((carry % 58) as u8);
            carry /= 58;
        }
    }
    let mut out = String::with_capacity(zeros + digits.len());
    out.extend(std::iter::repeat_n('1', zeros));
    out.extend(
        digits
            .iter()
            .rev()
            .map(|digit| B58[*digit as usize] as char),
    );
    out
}

pub(crate) fn unbase58(text: &str) -> Result<Vec<u8>> {
    if text.len() > B58_MAX {
        return Err(CityError::malformed(
            "base58 text is longer than the city reads",
        ));
    }
    let zeros = text.bytes().take_while(|byte| *byte == b'1').count();
    let mut bytes: Vec<u8> = Vec::with_capacity(text.len());
    for ch in text.bytes() {
        let value = B58
            .iter()
            .position(|candidate| *candidate == ch)
            .ok_or_else(|| CityError::malformed("not base58"))?;
        let mut carry = value as u32;
        for byte in bytes.iter_mut() {
            carry += u32::from(*byte) * 58;
            *byte = (carry & 0xff) as u8;
            carry >>= 8;
        }
        while carry > 0 {
            bytes.push((carry & 0xff) as u8);
            carry >>= 8;
        }
    }
    let mut out = vec![0u8; zeros];
    out.extend(bytes.iter().rev());
    Ok(out)
}

pub(crate) fn b64url(bytes: &[u8]) -> String {
    URL_SAFE_NO_PAD.encode(bytes)
}

/// Decodes what the city's `atob`-based reader would: unpadded is the norm,
/// but a padded or loosely terminated string from another implementation is
/// not a reason to refuse a box that would otherwise open.
pub(crate) fn unb64url(text: &str) -> Result<Vec<u8>> {
    const LENIENT: GeneralPurpose = GeneralPurpose::new(
        &base64::alphabet::URL_SAFE,
        GeneralPurposeConfig::new()
            .with_decode_padding_mode(DecodePaddingMode::Indifferent)
            .with_decode_allow_trailing_bits(true),
    );
    LENIENT
        .decode(text)
        .map_err(|_| CityError::malformed("not base64url"))
}

/// Decodes only the one canonical spelling, for places where the city insists
/// on it (a v2 signature: a second spelling of the same bytes would count as
/// a second record wherever records are told apart by signature).
pub(crate) fn unb64url_strict(text: &str) -> Result<Vec<u8>> {
    URL_SAFE_NO_PAD
        .decode(text)
        .map_err(|_| CityError::malformed("not canonical base64url"))
}

/// A string's length the way the city counts it.
pub(crate) fn utf16_len(text: &str) -> usize {
    text.chars().map(char::len_utf16).sum()
}

/// `text.slice(0, max)` without splitting a character the city would have
/// split: a pair cut in half is not text anyone can read, so the cut lands
/// before it.
pub(crate) fn utf16_prefix(text: &str, max: usize) -> &str {
    let mut units = 0;
    for (at, ch) in text.char_indices() {
        units += ch.len_utf16();
        if units > max {
            return &text[..at];
        }
    }
    text
}

/// Sixty-four lowercase hex digits: the name of a record or a person.
pub(crate) fn is_id(text: &str) -> bool {
    text.len() == 64
        && text
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

/// Characters the JavaScript `String.prototype.trim` removes. Rust's
/// `char::is_whitespace` differs on one (U+FEFF counts in JS, U+0085 does
/// not), and a trim that disagrees changes a sentence's mark.
fn is_js_space(ch: char) -> bool {
    matches!(
        ch,
        '\u{0009}'..='\u{000D}'
            | '\u{0020}'
            | '\u{00A0}'
            | '\u{1680}'
            | '\u{2000}'..='\u{200A}'
            | '\u{2028}'
            | '\u{2029}'
            | '\u{202F}'
            | '\u{205F}'
            | '\u{3000}'
            | '\u{FEFF}'
    )
}

pub(crate) fn js_trim(text: &str) -> &str {
    text.trim_matches(is_js_space)
}

/// Removes everything the city's `\s` matches, the way it prepares a pasted
/// key before reading it.
pub(crate) fn strip_js_space(text: &str) -> String {
    text.chars().filter(|ch| !is_js_space(*ch)).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn base58_round_trips_leading_zeros() {
        for bytes in [
            &[][..],
            &[0][..],
            &[0, 0, 1][..],
            &[0xed, 0x01, 0xff][..],
            &[255; 64][..],
        ] {
            assert_eq!(unbase58(&base58(bytes)).unwrap(), bytes);
        }
        assert_eq!(base58(&[0, 0, 1]), "112");
        assert!(unbase58("0").is_err());
        assert!(unbase58(&"1".repeat(B58_MAX + 1)).is_err());
    }

    #[test]
    fn utf16_prefix_never_splits_a_pair() {
        assert_eq!(utf16_prefix("a😀b", 1), "a");
        assert_eq!(utf16_prefix("a😀b", 2), "a");
        assert_eq!(utf16_prefix("a😀b", 3), "a😀");
        assert_eq!(utf16_len("a😀b"), 4);
    }

    #[test]
    fn trim_follows_javascript() {
        assert_eq!(js_trim("\u{FEFF} hi \u{3000}"), "hi");
        assert_eq!(js_trim("\u{0085}hi"), "\u{0085}hi");
    }
}
