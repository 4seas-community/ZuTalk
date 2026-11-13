//! Signed records: the only thing a city stores.
//!
//! A record is an entry `e = { v, type, by, key, deps, links, body, at }`
//! and a detached signature over the entry's canonical bytes. `by` is who it
//! speaks for, `key` the `did:key` that signed it, `links` what it is about,
//! `deps` the author's own earlier records. Its name is the fingerprint of
//! `e` alone, so re-signing never renames it.
//!
//! Two envelopes exist. Version 2 (`{ e, s }`) survives only for the
//! inception record and the spoken "this is me, now"; everything else is
//! version 3 (`{ e, proof }`), a W3C Data Integrity proof set whose author
//! entry is `eddsa-jcs-2022`. `{ ...e, proof }` is then a standard signed
//! document, which is why the city chose it.
//!
//! [`verify`] answers only what a record can prove about itself: shape, key
//! and signature. It does **not** say the key belongs to `by` — anyone can
//! sign a record that claims to be by someone else. That second question
//! needs the author's inception (or DID log), and the reducers in
//! [`crate::calendar`] and [`crate::channels`] answer it before they believe
//! a record.

use serde_json::{json, Map, Value};
use sha2::{Digest, Sha256};

use crate::error::{CityError, Result};
use crate::identity::{own_controller, Identity};
use crate::text::{b64url, base58, unb64url_strict, unbase58, utf16_len, utf16_prefix};
use crate::{ed, jcs};

pub const INCEPTION: &str = "id/inception";
pub const PRESENT: &str = "id/present";

/// A whole record is at most this deep (the server parses a posted batch to
/// 400 levels and the array is one of them). Deeper ones are refused by every
/// reader before the signature is even looked at.
pub const RECORD_DEPTH: usize = jcs::MAX_DEPTH - 1;

const TYPE_MAX: usize = 64;
const REFS_MAX: usize = 64;
const REF_MAX: usize = 128;
/// The last instant whose ISO form still has a four-digit year, which is the
/// only form the city's readers accept in a proof's `created`.
const AT_MAX: i64 = 253_402_300_799_999;

/// A record this device signed, with its name.
#[derive(Debug, Clone, PartialEq)]
pub struct Signed {
    pub id: String,
    pub rec: Value,
}

/// Signs one record as `who`.
///
/// `deps` must name at least one of the author's own earlier records (the
/// identity number itself will do for a first record): browsers refuse
/// anything but an inception that arrives without them.
pub fn make(
    who: &Identity,
    kind: &str,
    body: Value,
    links: &[String],
    deps: &[String],
    at_ms: i64,
) -> Result<Signed> {
    if kind.is_empty() || utf16_len(kind) > TYPE_MAX {
        return Err(CityError::malformed("record type is empty or too long"));
    }
    if kind == INCEPTION {
        // An inception is fixed by its key; it is read off the identity, not
        // made to order.
        return Err(CityError::malformed("an inception cannot be signed again"));
    }
    for refs in [links, deps] {
        if refs.len() > REFS_MAX || refs.iter().any(|one| utf16_len(one) > REF_MAX) {
            return Err(CityError::malformed("too many links or dependencies"));
        }
    }
    if !(0..=AT_MAX).contains(&at_ms) {
        return Err(CityError::malformed("record time is out of range"));
    }
    let spoken = kind == PRESENT;
    if !spoken && deps.is_empty() {
        return Err(CityError::malformed("a record needs a dependency"));
    }
    let entry = json!({
        "v": if spoken { 2 } else { 3 },
        "type": kind,
        "by": who.id(),
        "key": who.did_key(),
        "deps": deps,
        "links": links,
        "body": body,
        "at": at_ms,
    });
    if deeper(&json!({ "e": &entry }), RECORD_DEPTH) {
        return Err(CityError::malformed("record body is nested too deep"));
    }
    let id = jcs::fingerprint(&entry)?;
    if spoken {
        let signature = who.sign(jcs::canonical(&entry)?.as_bytes());
        return Ok(Signed {
            id,
            rec: json!({ "e": entry, "s": b64url(&signature) }),
        });
    }
    // The key is always named by its own multikey; what stands in front of
    // the `#` is the person's DID when they have one that is plainly theirs,
    // and the bare key otherwise.
    let multikey = &who.did_key()["did:key:".len()..];
    let controller = match who.controller() {
        Some(did) if own_controller(did, who.id()) => did.to_string(),
        _ => format!("did:key:{multikey}"),
    };
    let mut config = Map::new();
    config.insert("type".into(), json!("DataIntegrityProof"));
    config.insert("cryptosuite".into(), json!("eddsa-jcs-2022"));
    config.insert(
        "verificationMethod".into(),
        json!(format!("{controller}#{multikey}")),
    );
    config.insert("created".into(), json!(iso_ms(at_ms)));
    config.insert("proofPurpose".into(), json!("assertionMethod"));
    let signature = who.sign(&proof_bytes(&Value::Object(config.clone()), &entry)?);
    config.insert(
        "proofValue".into(),
        json!(format!("z{}", base58(&signature))),
    );
    Ok(Signed {
        id,
        rec: json!({ "e": entry, "proof": [Value::Object(config)] }),
    })
}

/// Whether a record stands on its own: well-formed, signed by a real Ed25519
/// `did:key`, and the signature is over exactly this entry.
///
/// This is the city's `intrinsic(rec) === "ok"`. It is deliberately not a
/// statement about authorship; see the module documentation.
pub fn verify(rec: &Value) -> bool {
    if deeper(rec, RECORD_DEPTH) {
        return false;
    }
    let Some(entry) = rec.get("e").and_then(Value::as_object) else {
        return false;
    };
    let version = entry.get("v").and_then(Value::as_f64);
    let kind = entry.get("type").and_then(Value::as_str).unwrap_or("");
    let signed_shape = if version == Some(3.0) {
        author_proof(rec).is_some_and(proof_shape_ok)
            && kind != INCEPTION
            && kind != PRESENT
            && rec.get("s").is_none()
    } else {
        version == Some(2.0)
            && rec
                .get("s")
                .and_then(Value::as_str)
                .is_some_and(signature_spelling_ok)
    };
    let by_ok = matches!(entry.get("by"), Some(Value::Null | Value::String(_)));
    let Some(key) = entry.get("key").and_then(Value::as_str) else {
        return false;
    };
    if !signed_shape
        || kind.is_empty()
        || utf16_len(kind) > TYPE_MAX
        || !by_ok
        || !refs_ok(entry.get("deps"))
        || !refs_ok(entry.get("links"))
        || entry.get("at").and_then(Value::as_f64).is_none()
        || !entry.contains_key("body")
    {
        return false;
    }
    let Ok(public) = ed::did_key_bytes(key) else {
        return false;
    };
    let entry = &rec["e"];
    if version == Some(3.0) {
        let Some(proof) = author_proof(rec) else {
            return false;
        };
        // Everything in the proof but the signature is signed, including
        // members this client has never heard of.
        let mut config = proof.clone();
        let Some(Value::String(value)) = config.remove("proofValue") else {
            return false;
        };
        let (Ok(signature), Ok(message)) = (
            unbase58(&value[1..]),
            proof_bytes(&Value::Object(config), entry),
        ) else {
            return false;
        };
        return ed::verify(&public, &message, &signature);
    }
    let (Some(Ok(signature)), Ok(message)) = (
        rec.get("s").and_then(Value::as_str).map(unb64url_strict),
        jcs::canonical(entry),
    ) else {
        return false;
    };
    ed::verify(&public, message.as_bytes(), &signature)
}

/// A record's name: the fingerprint of its entry.
pub fn record_id(rec: &Value) -> Result<String> {
    let entry = rec
        .get("e")
        .filter(|entry| entry.is_object())
        .ok_or_else(|| CityError::malformed("not a record"))?;
    jcs::fingerprint(entry)
}

/// The string a city uses to tell us which records it did not keep: `s` for
/// version 2, the author proof's `proofValue` for version 3.
pub fn signature_of(rec: &Value) -> Option<String> {
    let version = rec
        .get("e")
        .and_then(|entry| entry.get("v"))
        .and_then(Value::as_f64);
    if version != Some(3.0) {
        if let Some(signature) = rec.get("s").and_then(Value::as_str) {
            return Some(signature.to_string());
        }
    }
    author_proof(rec)?
        .get("proofValue")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
}

/// Whether an entry is the one inception a key may have: time zero, nothing
/// linked, nothing said. Any other form would let one key open a second
/// account that verifies just as well.
pub(crate) fn canonical_inception(entry: &Value) -> bool {
    let empty_list = |name: &str| {
        entry
            .get(name)
            .and_then(Value::as_array)
            .is_some_and(Vec::is_empty)
    };
    entry.get("type").and_then(Value::as_str) == Some(INCEPTION)
        && entry.get("by") == Some(&Value::Null)
        && entry.get("at").and_then(Value::as_f64) == Some(0.0)
        && empty_list("deps")
        && empty_list("links")
        && entry
            .get("body")
            .and_then(Value::as_object)
            .is_some_and(Map::is_empty)
}

/// The author's own entry in a version 3 proof set: the one whose
/// verification method ends in the entry's key and is fronted either by that
/// same key or by a `did:webvh` whose path is the author's account number.
/// The other entries are witnesses' receipts.
pub(crate) fn author_proof(rec: &Value) -> Option<&Map<String, Value>> {
    let entry = rec.get("e")?;
    if entry.get("v").and_then(Value::as_f64) != Some(3.0) {
        return None;
    }
    let multikey = entry.get("key")?.as_str()?.strip_prefix("did:key:")?;
    let suffix = format!("#{multikey}");
    rec.get("proof")?
        .as_array()?
        .iter()
        .take(8)
        .find_map(|proof| {
            let proof = proof.as_object()?;
            let did = proof
                .get("verificationMethod")?
                .as_str()?
                .strip_suffix(&suffix)?;
            let bare = did.strip_prefix("did:key:") == Some(multikey);
            let own = did.starts_with("did:webvh:")
                && entry
                    .get("by")
                    .and_then(Value::as_str)
                    .is_some_and(|by| did.ends_with(&format!(":u:{}", utf16_prefix(by, 16))));
            (bare || own).then_some(proof)
        })
}

/// The bytes an `eddsa-jcs-2022` proof signs: the hash of the proof options
/// followed by the hash of the document.
pub(crate) fn proof_bytes(config: &Value, document: &Value) -> Result<[u8; 64]> {
    let mut out = [0u8; 64];
    out[..32].copy_from_slice(&Sha256::digest(jcs::canonical(config)?.as_bytes()));
    out[32..].copy_from_slice(&Sha256::digest(jcs::canonical(document)?.as_bytes()));
    Ok(out)
}

/// Whether a value nests deeper than `max` levels, the outermost being the
/// first. Iterative, so a hostile record cannot spend the stack.
pub(crate) fn deeper(value: &Value, max: usize) -> bool {
    let mut todo = vec![(value, 1usize)];
    while let Some((value, depth)) = todo.pop() {
        let children: Box<dyn Iterator<Item = &Value>> = match value {
            Value::Array(items) => Box::new(items.iter()),
            Value::Object(map) => Box::new(map.values()),
            _ => continue,
        };
        if depth > max {
            return true;
        }
        todo.extend(
            children
                .filter(|child| child.is_array() || child.is_object())
                .map(|child| (child, depth + 1)),
        );
    }
    false
}

fn refs_ok(value: Option<&Value>) -> bool {
    value.and_then(Value::as_array).is_some_and(|items| {
        items.len() <= REFS_MAX
            && items
                .iter()
                .all(|item| item.as_str().is_some_and(|text| utf16_len(text) <= REF_MAX))
    })
}

/// A 64-byte signature has exactly one accepted base64url spelling: 86
/// characters, the last one carrying no stray low bits. Any other spelling of
/// the same bytes would pass for a different record wherever records are told
/// apart by signature.
fn signature_spelling_ok(text: &str) -> bool {
    let bytes = text.as_bytes();
    bytes.len() == 86
        && bytes[..85]
            .iter()
            .all(|byte| byte.is_ascii_alphanumeric() || *byte == b'_' || *byte == b'-')
        && matches!(bytes[85], b'A' | b'Q' | b'g' | b'w')
}

fn proof_shape_ok(proof: &Map<String, Value>) -> bool {
    let text = |name: &str| proof.get(name).and_then(Value::as_str);
    text("type") == Some("DataIntegrityProof")
        && text("cryptosuite") == Some("eddsa-jcs-2022")
        && text("proofPurpose") == Some("assertionMethod")
        && text("created").is_some_and(created_shape_ok)
        && text("proofValue").is_some_and(|value| {
            let body = value.strip_prefix('z').unwrap_or("");
            value.starts_with('z')
                && (80..=90).contains(&body.len())
                && body.bytes().all(crate::text::is_base58)
        })
}

/// `YYYY-MM-DDTHH:MM:SS(.f{1,3})?Z`, the only timestamp spelling accepted.
fn created_shape_ok(text: &str) -> bool {
    let bytes = text.as_bytes();
    const HEAD: &[u8; 19] = b"dddd-dd-ddTdd:dd:dd";
    if bytes.len() < HEAD.len() + 1 || bytes[bytes.len() - 1] != b'Z' {
        return false;
    }
    let head_ok = HEAD.iter().zip(bytes).all(|(pattern, byte)| match pattern {
        b'd' => byte.is_ascii_digit(),
        other => other == byte,
    });
    let fraction = &bytes[HEAD.len()..bytes.len() - 1];
    head_ok
        && (fraction.is_empty()
            || (fraction[0] == b'.'
                && (2..=4).contains(&fraction.len())
                && fraction[1..].iter().all(u8::is_ascii_digit)))
}

/// `new Date(ms).toISOString()` for the years a proof may carry.
pub(crate) fn iso_ms(at_ms: i64) -> String {
    let days = at_ms.div_euclid(86_400_000);
    let in_day = at_ms.rem_euclid(86_400_000);
    // Days since 1970-01-01 to a civil date (Howard Hinnant's algorithm),
    // which is exact over the whole proleptic Gregorian calendar.
    let shifted = days + 719_468;
    let era = shifted.div_euclid(146_097);
    let day_of_era = shifted.rem_euclid(146_097);
    let year_of_era =
        (day_of_era - day_of_era / 1_460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let month_index = (5 * day_of_year + 2) / 153;
    let day = day_of_year - (153 * month_index + 2) / 5 + 1;
    let month = if month_index < 10 {
        month_index + 3
    } else {
        month_index - 9
    };
    let year = year_of_era + era * 400 + i64::from(month <= 2);
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}.{:03}Z",
        in_day / 3_600_000,
        in_day / 60_000 % 60,
        in_day / 1_000 % 60,
        in_day % 1_000
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn iso_matches_the_calendar() {
        assert_eq!(iso_ms(0), "1970-01-01T00:00:00.000Z");
        assert_eq!(iso_ms(951_782_400_000), "2000-02-29T00:00:00.000Z");
        assert_eq!(iso_ms(1_794_528_000_123), "2026-11-13T00:00:00.123Z");
        assert_eq!(iso_ms(4_102_444_799_999), "2099-12-31T23:59:59.999Z");
        assert_eq!(iso_ms(AT_MAX), "9999-12-31T23:59:59.999Z");
    }

    #[test]
    fn created_spelling() {
        for good in [
            "2026-11-13T00:00:00Z",
            "2026-11-13T00:00:00.1Z",
            "2026-11-13T00:00:00.123Z",
        ] {
            assert!(created_shape_ok(good), "{good}");
        }
        for bad in [
            "2026-11-13T00:00:00.1234Z",
            "2026-11-13T00:00:00.Z",
            "2026-11-13T00:00:00",
            "2026-11-13 00:00:00Z",
            "12026-11-13T00:00:00Z",
            "",
        ] {
            assert!(!created_shape_ok(bad), "{bad}");
        }
    }

    #[test]
    fn depth_counts_containers_only() {
        assert!(!deeper(&json!({"e": {"body": {}}}), 3));
        assert!(deeper(&json!({"e": {"body": {"x": []}}}), 3));
        assert!(!deeper(&json!([1, "a", null]), 1));
    }
}
