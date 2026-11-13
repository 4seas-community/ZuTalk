//! Canonical JSON (RFC 8785) exactly as the city's browsers write it.
//!
//! A record's name is the SHA-256 of these bytes and its signature is made
//! over them, so "nearly the same" is the same as wrong: one differently
//! formatted number and a record this device signed is a record nobody else
//! can verify. The city's JavaScript leans on `JSON.stringify` for numbers
//! and strings and on `Array.prototype.sort` for keys; this reproduces those
//! three behaviours and nothing else.

use serde_json::Value;
use sha2::{Digest, Sha256};

use crate::error::{CityError, Result};

/// The deepest nesting the city canonicalises (the outermost value is depth
/// zero). Deeper values are refused by every reader, so there is no point
/// producing bytes for them.
pub const MAX_DEPTH: usize = 400;

/// The canonical text of a JSON value.
pub fn canonical(value: &Value) -> Result<String> {
    let mut out = String::new();
    write(value, 0, &mut out)?;
    Ok(out)
}

/// The name of a value: lowercase hex SHA-256 of its canonical text.
pub fn fingerprint(value: &Value) -> Result<String> {
    Ok(hex::encode(digest(value)?))
}

pub(crate) fn digest(value: &Value) -> Result<[u8; 32]> {
    Ok(Sha256::digest(canonical(value)?.as_bytes()).into())
}

fn write(value: &Value, depth: usize, out: &mut String) -> Result<()> {
    if depth > MAX_DEPTH {
        return Err(CityError::malformed("nested deeper than the city reads"));
    }
    match value {
        Value::Null => out.push_str("null"),
        Value::Bool(true) => out.push_str("true"),
        Value::Bool(false) => out.push_str("false"),
        Value::Number(number) => write_number(number, out),
        Value::String(text) => write_string(text, out),
        Value::Array(items) => {
            out.push('[');
            for (index, item) in items.iter().enumerate() {
                if index > 0 {
                    out.push(',');
                }
                write(item, depth + 1, out)?;
            }
            out.push(']');
        }
        Value::Object(map) => {
            // JavaScript sorts strings by UTF-16 code unit. That is not the
            // order of the bytes: a character outside the basic plane is
            // written as surrogates (0xD800..) and so sorts before U+E000,
            // while its UTF-8 bytes sort after.
            let mut keys: Vec<&String> = map.keys().collect();
            keys.sort_by(|a, b| a.encode_utf16().cmp(b.encode_utf16()));
            out.push('{');
            for (index, key) in keys.into_iter().enumerate() {
                if index > 0 {
                    out.push(',');
                }
                write_string(key, out);
                out.push(':');
                write(&map[key], depth + 1, out)?;
            }
            out.push('}');
        }
    }
    Ok(())
}

/// Every JavaScript number is a double. An integer too large for one is
/// rounded on the way in (`JSON.parse`), so it must be rounded the same way
/// here before it is written, or the two sides hash different digits.
fn write_number(number: &serde_json::Number, out: &mut String) {
    const EXACT: u64 = 1 << 53;
    if let Some(unsigned) = number.as_u64() {
        if unsigned <= EXACT {
            out.push_str(&unsigned.to_string());
            return;
        }
    } else if let Some(signed) = number.as_i64() {
        if signed.unsigned_abs() <= EXACT {
            out.push_str(&signed.to_string());
            return;
        }
    }
    match number.as_f64() {
        // ECMAScript `Number::toString`: shortest digits that round-trip,
        // plain notation up to 1e21, `-0` written as `0`.
        Some(float) if float.is_finite() => {
            out.push_str(ryu_js::Buffer::new().format_finite(float))
        }
        // `JSON.stringify` writes what it cannot represent as `null`.
        _ => out.push_str("null"),
    }
}

fn write_string(text: &str, out: &mut String) {
    out.push('"');
    for ch in text.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\u{08}' => out.push_str("\\b"),
            '\u{0C}' => out.push_str("\\f"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            control if (control as u32) < 0x20 => {
                out.push_str(&format!("\\u{:04x}", control as u32));
            }
            other => out.push(other),
        }
    }
    out.push('"');
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn keys_sort_by_utf16_code_unit_not_by_byte() {
        // U+1F600 is D83D DE00 in UTF-16 and so sorts before U+FB01, although
        // its UTF-8 bytes (F0..) sort after (EF..).
        let value = json!({"\u{FB01}": 1, "\u{1F600}": 2, "a": 3});
        assert_eq!(
            canonical(&value).unwrap(),
            "{\"a\":3,\"\u{1F600}\":2,\"\u{FB01}\":1}"
        );
    }

    #[test]
    fn numbers_are_written_as_javascript_writes_them() {
        let text = r#"[0, -0, -0.0, 1.0, 100, 1e21, 1e-7, 0.000001, 1.5e300, 9007199254740993, 18446744073709551615, -9223372036854775808, 0.1, 123456789012345680000]"#;
        let value: Value = serde_json::from_str(text).unwrap();
        assert_eq!(
            canonical(&value).unwrap(),
            "[0,0,0,1,100,1e+21,1e-7,0.000001,1.5e+300,9007199254740992,18446744073709552000,-9223372036854776000,0.1,123456789012345680000]"
        );
    }

    #[test]
    fn strings_escape_only_what_json_stringify_escapes() {
        let value = json!("a\"b\\c\u{08}\u{0C}\n\r\t\u{01}\u{1f}\u{7f}\u{2028}é");
        assert_eq!(
            canonical(&value).unwrap(),
            "\"a\\\"b\\\\c\\b\\f\\n\\r\\t\\u0001\\u001f\u{7f}\u{2028}é\""
        );
    }

    #[test]
    fn refuses_what_is_nested_too_deep() {
        let mut value = json!(1);
        for _ in 0..MAX_DEPTH {
            value = json!([value]);
        }
        assert!(canonical(&value).is_ok());
        assert!(canonical(&json!([value])).is_err());
    }
}
