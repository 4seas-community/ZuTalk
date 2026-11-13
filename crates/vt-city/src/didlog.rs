//! Which keys may sign for a person who moved to a `did:webvh` identifier.
//!
//! After that move the recovery key leaves the person's devices and each
//! device signs with a derived key. Readers accept those keys because the
//! person's DID log names them, and they accept the log because its first
//! entry is signed by the key that opened the account and every later entry
//! by a key the entry before it authorised. This module walks that chain.
//!
//! It answers one question — "is this log rooted in this person's inception
//! key, and which keys does it name now?" — because that is what stands
//! between a reader and a stranger who signs records that claim to be by
//! someone else. A city's event tag checks signatures and nothing more, so
//! such records can be sitting in it.
//!
//! What is not re-checked here is everything that guards a person against
//! their *own* lost keys: witness thresholds, clocks in the future, the exact
//! shape of host names. The city's servers and browsers enforce those; a log
//! that fails them is rare, and accepting it here cannot let a third party
//! speak for anyone.

use std::collections::BTreeSet;

use serde_json::{Map, Value};
use sha2::{Digest, Sha256};

use crate::text::{base58, is_base58, unbase58};
use crate::{ed, jcs};

const METHOD: &str = "did:webvh:1.0";
/// Longer logs are not read by the city either; they exist to waste time.
const MAX_ENTRIES: usize = 200;
const MAX_PROOFS: usize = 16;
const PARAMS: [&str; 9] = [
    "method",
    "scid",
    "updateKeys",
    "nextKeyHashes",
    "witness",
    "watchers",
    "portable",
    "deactivated",
    "ttl",
];

/// A DID log that checked out as one person's.
pub(crate) struct VerifiedLog {
    pub scid: String,
    /// When pre-rotation was first switched on. A log that never did so is
    /// not yet the person's canonical identifier and changes nothing.
    pub armed_at: Option<i64>,
    pub versions: usize,
    pub last_version_id: String,
    /// Keys named for `assertionMethod` in any version: any of them may have
    /// signed the record that carries this log.
    pub ever: BTreeSet<String>,
    /// Keys named in the latest version, empty once deactivated: the ones
    /// that sign for the person now.
    pub now: BTreeSet<String>,
}

#[derive(Clone, Default)]
struct Params {
    update_keys: Vec<String>,
    next_key_hashes: Vec<String>,
    portable: bool,
    deactivated: bool,
}

/// Verifies a log end to end and binds it to a person: `inception_key` is the
/// multikey that opened their account, `account` the first 16 digits of
/// their identity number. `None` when any entry fails.
pub(crate) fn verify(log: &[Value], inception_key: &str, account: &str) -> Option<VerifiedLog> {
    if log.is_empty() || log.len() > MAX_ENTRIES {
        return None;
    }
    let mut params: Option<Params> = None;
    let mut scid = String::new();
    let mut prev_id = String::new();
    let mut prev_time = i64::MIN;
    let mut prev_state_id = String::new();
    let mut armed_at = None;
    let mut ever = BTreeSet::new();
    let mut now = BTreeSet::new();

    for (index, entry) in log.iter().enumerate() {
        let entry = entry.as_object()?;
        let known = ["versionId", "versionTime", "parameters", "state", "proof"];
        if entry.keys().any(|key| !known.contains(&key.as_str())) {
            return None;
        }
        let first = index == 0;
        let prev = params.clone().unwrap_or_default();
        if prev.deactivated {
            return None;
        }
        let given = entry.get("parameters")?.as_object()?;
        let next = merge_params(&prev, given, first)?;

        // Who may sign this entry: the first names its own keys; later ones
        // are signed by the keys already in force, unless pre-rotation is on,
        // in which case the entry brings new keys whose hashes the previous
        // entry committed to.
        let rotating = !first && !prev.next_key_hashes.is_empty();
        let authorized: &[String] = if first {
            &next.update_keys
        } else if rotating {
            if !given.contains_key("updateKeys") || !given.contains_key("nextKeyHashes") {
                return None;
            }
            if next
                .update_keys
                .iter()
                .any(|key| !prev.next_key_hashes.contains(&key_hash(key)))
            {
                return None;
            }
            &next.update_keys
        } else {
            &prev.update_keys
        };

        let mut body = entry.clone();
        let proofs = body.remove("proof")?;
        let proofs = proofs.as_array()?;
        if proofs.is_empty() || proofs.len() > MAX_PROOFS {
            return None;
        }
        let body = Value::Object(body);
        let mut signer = None;
        for proof in proofs {
            let key = proven(&body, proof)?;
            if !authorized.contains(&key) {
                return None;
            }
            signer.get_or_insert(key);
        }

        let version_id = entry.get("versionId")?.as_str()?;
        let (number, entry_hash) = version_id.split_once('-')?;
        if number != (index + 1).to_string() || entry_hash.is_empty() {
            return None;
        }
        let time = time_of(entry.get("versionTime")?.as_str()?)?;
        if time <= prev_time {
            return None;
        }

        if first {
            scid = given.get("scid")?.as_str()?.to_string();
            if scid.len() != 46 || !scid.bytes().all(is_base58) {
                return None;
            }
            // The identifier is the hash of the first entry written with a
            // placeholder wherever the identifier itself appears.
            let text = serde_json::to_string(&with_version_id(&body, "{SCID}")).ok()?;
            let blank: Value = serde_json::from_str(&text.replace(&scid, "{SCID}")).ok()?;
            if hash_jcs(&blank)? != scid {
                return None;
            }
            prev_id = scid.clone();
        }
        if hash_jcs(&with_version_id(&body, &prev_id))? != entry_hash {
            return None;
        }

        let state = entry.get("state")?.as_object()?;
        let state_id = state.get("id")?.as_str()?;
        let mut parts = state_id.split(':');
        if (parts.next(), parts.next(), parts.next()) != (Some("did"), Some("webvh"), Some(&scid)) {
            return None;
        }
        if first {
            // The log is this person's only if the key that opened their
            // account signed the first entry and is its sole update key —
            // "among the update keys" is not enough, since anyone can list
            // someone else's key next to their own and sign with theirs —
            // and the identifier's path is the person's account number.
            let path: Vec<&str> = parts.skip(1).collect();
            let sole = next.update_keys.len() == 1 && next.update_keys[0] == inception_key;
            if signer.as_deref() != Some(inception_key) || !sole || path != ["u", account] {
                return None;
            }
        } else if state_id != prev_state_id {
            let moved = state
                .get("alsoKnownAs")
                .and_then(Value::as_array)
                .is_some_and(|names| {
                    names
                        .iter()
                        .any(|name| name.as_str() == Some(&prev_state_id))
                });
            if !next.portable || !moved {
                return None;
            }
        }

        if armed_at.is_none() && !next.next_key_hashes.is_empty() {
            armed_at = Some(time);
        }
        let keys = relation_keys(state, "assertionMethod");
        ever.extend(keys.iter().cloned());
        now = if next.deactivated {
            BTreeSet::new()
        } else {
            keys
        };

        prev_id = version_id.to_string();
        prev_time = time;
        prev_state_id = state_id.to_string();
        params = Some(next);
    }

    Some(VerifiedLog {
        scid,
        armed_at,
        versions: log.len(),
        last_version_id: prev_id,
        ever,
        now,
    })
}

/// Applies one entry's parameters over those in force. Only the parameters
/// that decide who may sign are kept; the rest are checked for shape.
fn merge_params(prev: &Params, given: &Map<String, Value>, first: bool) -> Option<Params> {
    if given.keys().any(|key| !PARAMS.contains(&key.as_str())) {
        return None;
    }
    let method = given.get("method");
    if first {
        if method.and_then(Value::as_str) != Some(METHOD) || !given.contains_key("updateKeys") {
            return None;
        }
    } else if given.contains_key("scid")
        || method.is_some_and(|value| value.as_str() != Some(METHOD))
    {
        return None;
    }
    let strings = |name: &str| -> Option<Option<Vec<String>>> {
        match given.get(name) {
            None => Some(None),
            // A null means "back to the default".
            Some(Value::Null) => Some(Some(Vec::new())),
            Some(Value::Array(items)) => items
                .iter()
                .map(|item| {
                    item.as_str()
                        .filter(|text| !text.is_empty())
                        .map(str::to_string)
                })
                .collect::<Option<Vec<_>>>()
                .map(Some),
            Some(_) => None,
        }
    };
    let flag = |name: &str| -> Option<Option<bool>> {
        match given.get(name) {
            None => Some(None),
            Some(Value::Null) => Some(Some(false)),
            Some(Value::Bool(value)) => Some(Some(*value)),
            Some(_) => None,
        }
    };
    let mut next = prev.clone();
    if let Some(keys) = strings("updateKeys")? {
        if keys.iter().any(|key| ed::multikey_bytes(key).is_err()) {
            return None;
        }
        next.update_keys = keys;
    }
    if let Some(hashes) = strings("nextKeyHashes")? {
        next.next_key_hashes = hashes;
    }
    if let Some(portable) = flag("portable")? {
        // Portability is a promise made at creation or never.
        if portable && !first {
            return None;
        }
        next.portable = portable;
    }
    if let Some(deactivated) = flag("deactivated")? {
        next.deactivated = deactivated;
    }
    Some(next)
}

/// Checks one Data Integrity proof over a log entry and returns the multikey
/// that made it. The verification method must be a `did:key` whose fragment
/// repeats the key byte for byte.
fn proven(document: &Value, proof: &Value) -> Option<String> {
    let mut config = proof.as_object()?.clone();
    let value = config.remove("proofValue")?;
    let text = |name: &str| config.get(name).and_then(Value::as_str);
    if text("type") != Some("DataIntegrityProof")
        || text("cryptosuite") != Some("eddsa-jcs-2022")
        || text("proofPurpose") != Some("assertionMethod")
    {
        return None;
    }
    let (did, fragment) = text("verificationMethod")?.split_once('#')?;
    let key = did.strip_prefix("did:key:")?;
    if key != fragment || !key.starts_with('z') || !key.bytes().skip(1).all(is_base58) {
        return None;
    }
    let key = key.to_string();
    let signature = unbase58(value.as_str()?.strip_prefix('z')?).ok()?;
    // A log entry has no `@context`, and the options are hashed without one.
    config.remove("@context");
    let mut message = [0u8; 64];
    message[..32].copy_from_slice(&jcs::digest(&Value::Object(config)).ok()?);
    message[32..].copy_from_slice(&jcs::digest(document).ok()?);
    ed::verify(&ed::multikey_bytes(&key).ok()?, &message, &signature).then_some(key)
}

/// The multikeys a DID document names under one verification relationship,
/// whether by reference into `verificationMethod` or embedded.
pub(crate) fn relation_keys(state: &Map<String, Value>, relation: &str) -> BTreeSet<String> {
    let own = state.get("id").and_then(Value::as_str).unwrap_or("");
    let full = |id: &str| match id.strip_prefix('#') {
        Some(_) => format!("{own}{id}"),
        None => id.to_string(),
    };
    let methods = state.get("verificationMethod").and_then(Value::as_array);
    let mut out = BTreeSet::new();
    for reference in state
        .get(relation)
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
    {
        let method = match reference {
            Value::String(reference) => methods.into_iter().flatten().find(|method| {
                method.get("id").and_then(Value::as_str).map(&full) == Some(full(reference))
            }),
            other => Some(other),
        };
        let Some(method) = method else { continue };
        if method.get("type").and_then(Value::as_str) == Some("Multikey") {
            if let Some(key) = method.get("publicKeyMultibase").and_then(Value::as_str) {
                out.insert(key.to_string());
            }
        }
    }
    out
}

fn with_version_id(body: &Value, version_id: &str) -> Value {
    let mut body = body.clone();
    if let Some(map) = body.as_object_mut() {
        map.insert("versionId".into(), Value::String(version_id.to_string()));
    }
    body
}

/// base58btc of the sha2-256 multihash of a value's canonical bytes.
fn hash_jcs(value: &Value) -> Option<String> {
    Some(multihash(&jcs::digest(value).ok()?))
}

/// The commitment an entry makes to a key it will rotate to.
fn key_hash(multikey: &str) -> String {
    multihash(&Sha256::digest(multikey.as_bytes()))
}

fn multihash(digest: &[u8]) -> String {
    let mut bytes = vec![0x12, 0x20];
    bytes.extend_from_slice(digest);
    base58(&bytes)
}

/// Milliseconds of a UTC ISO 8601 instant (`…Z` or `…+00:00`), which is all
/// the method allows.
fn time_of(text: &str) -> Option<i64> {
    let body = text
        .strip_suffix('Z')
        .or_else(|| text.strip_suffix("+00:00"))?;
    let (clock, fraction) = match body.split_once('.') {
        Some((clock, fraction)) => (clock, fraction),
        None => (body, "0"),
    };
    let bytes = clock.as_bytes();
    let shape = b"dddd-dd-ddTdd:dd:dd";
    let shaped = bytes.len() == shape.len()
        && shape
            .iter()
            .zip(bytes)
            .all(|(pattern, byte)| match pattern {
                b'd' => byte.is_ascii_digit(),
                other => other == byte,
            });
    if !shaped || fraction.is_empty() || !fraction.bytes().all(|byte| byte.is_ascii_digit()) {
        return None;
    }
    let number = |range: std::ops::Range<usize>| clock[range].parse::<i64>().ok();
    let (year, month, day) = (number(0..4)?, number(5..7)?, number(8..10)?);
    let (hour, minute, second) = (number(11..13)?, number(14..16)?, number(17..19)?);
    if !(1..=12).contains(&month)
        || !(1..=31).contains(&day)
        || hour > 24
        || minute > 59
        || second > 59
    {
        return None;
    }
    let millis = format!("{fraction:0<3}")[..3].parse::<i64>().ok()?;
    // Civil date to days since 1970-01-01 (Howard Hinnant's algorithm).
    let shifted_year = if month <= 2 { year - 1 } else { year };
    let era = shifted_year.div_euclid(400);
    let year_of_era = shifted_year.rem_euclid(400);
    let month_index = (month + 9) % 12;
    let day_of_year = (153 * month_index + 2) / 5 + day - 1;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    let days = era * 146_097 + day_of_era - 719_468;
    Some(((days * 24 + hour) * 60 + minute) * 60_000 + second * 1_000 + millis)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::record::iso_ms;

    #[test]
    fn times_round_trip_through_the_proof_spelling() {
        for at in [0, 951_782_400_000, 1_794_528_000_123, 4_102_444_799_999] {
            assert_eq!(time_of(&iso_ms(at)), Some(at));
        }
        assert_eq!(
            time_of("2026-11-13T00:00:00+00:00"),
            Some(1_794_528_000_000)
        );
        assert_eq!(time_of("2026-11-13T00:00:00.5Z"), Some(1_794_528_000_500));
        assert_eq!(time_of("2026-11-13T00:00:00+01:00"), None);
        assert_eq!(time_of("2026-13-13T00:00:00Z"), None);
    }

    #[test]
    fn relation_keys_follow_references_and_embeds() {
        let state: Value = serde_json::json!({
            "id": "did:webvh:x:host:u:a",
            "verificationMethod": [
                {"id": "did:webvh:x:host:u:a#k1", "type": "Multikey", "publicKeyMultibase": "zOne"},
                {"id": "#k2", "type": "Multikey", "publicKeyMultibase": "zTwo"},
                {"id": "#k3", "type": "Other", "publicKeyMultibase": "zThree"},
            ],
            "assertionMethod": ["#k1", "did:webvh:x:host:u:a#k2", "#k3", "#missing",
                {"type": "Multikey", "publicKeyMultibase": "zFour"}],
        });
        let keys = relation_keys(state.as_object().unwrap(), "assertionMethod");
        assert_eq!(
            keys.into_iter().collect::<Vec<_>>(),
            ["zFour", "zOne", "zTwo"]
        );
    }
}
