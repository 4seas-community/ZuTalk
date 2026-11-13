//! A city resident, as this device holds them.
//!
//! A person in the city is the fingerprint of their inception record. What a
//! device holds is a key that may sign for that person, and there are two
//! shapes of that:
//!
//! - **version 1**: the recovery key itself. The inception record was signed
//!   by this very key, so the key proves the identity on its own.
//! - **version 2**: after the person moved to a `did:webvh` identifier, the
//!   recovery key leaves their devices. A device holds a derived signing key
//!   instead; the inception record is carried alongside, and readers accept
//!   the signing key because the person's DID log names it.
//!
//! Either way the seed is the whole of someone's standing in their city, so
//! it never appears in `Debug` output or an error and is wiped when dropped.

use std::sync::Arc;

use ed25519_dalek::SigningKey;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use zeroize::{Zeroize, ZeroizeOnDrop, Zeroizing};

use crate::error::{CityError, Result};
use crate::text::{
    b64url, is_base58, js_trim, strip_js_space, unb64url, unbase58, utf16_prefix, B58_MAX,
};
use crate::{ed, jcs, record};

/// What the city prints in front of a recovery key.
pub const KEY_PREFIX: &str = "sibian-key-1:";

/// A person's name on another device is cut to this many UTF-16 units before
/// it is shown, so a name crafted to push the account number off a
/// confirmation sheet cannot.
const NAME_MAX: usize = 40;

/// A resident and the key this device signs with on their behalf.
#[derive(Clone)]
pub struct Identity {
    inner: Arc<Inner>,
}

struct Inner {
    version: u8,
    id: String,
    did_key: String,
    controller: Option<String>,
    inception: Value,
    // Wiped on drop by ed25519-dalek itself.
    signing: SigningKey,
}

impl std::fmt::Debug for Identity {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // Everything here is already public in the city's log. The seed has
        // no business in a log line, including one printed by a failed
        // assertion.
        f.debug_struct("Identity")
            .field("id", &self.inner.id)
            .field("did_key", &self.inner.did_key)
            .field("controller", &self.inner.controller)
            .finish_non_exhaustive()
    }
}

/// An identity in the form the caller keeps in its own secret store.
#[derive(Clone, Serialize, Deserialize, Zeroize, ZeroizeOnDrop)]
pub struct StoredIdentity {
    /// 1 when `seed` is the recovery key that signed `inception`; 2 when it
    /// is a signing key the person's DID log vouches for.
    #[zeroize(skip)]
    pub version: u8,
    #[zeroize(skip)]
    pub id: String,
    /// The 32-byte Ed25519 seed, base64url without padding.
    pub seed: String,
    #[zeroize(skip)]
    pub controller: Option<String>,
    #[zeroize(skip)]
    pub inception: Value,
}

impl std::fmt::Debug for StoredIdentity {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("StoredIdentity")
            .field("version", &self.version)
            .field("id", &self.id)
            .field("seed", &"<redacted>")
            .field("controller", &self.controller)
            .finish_non_exhaustive()
    }
}

impl Identity {
    /// Restores a version 1 identity from its recovery key, as typed or
    /// pasted: whitespace anywhere is ignored and the prefix may be missing
    /// (the printed sheet groups the characters in fours and people copy only
    /// the part that looks like a code).
    pub fn from_key_string(text: &str) -> Result<Identity> {
        let seed = seed_of_key_string(text)?;
        Self::from_recovery_seed(&seed)
    }

    /// Reads the identity an already signed-in device handed over at the end
    /// of the link flow, and the name that device said the person goes by
    /// (possibly empty).
    ///
    /// The name is the other side's claim and nothing more: whoever reached
    /// the room first can hand over their own identity under any name, which
    /// is why the city's own sheet shows the account before switching to it.
    pub fn from_link_payload(payload: &Value) -> Result<(Identity, String)> {
        let name = payload
            .get("name")
            .and_then(Value::as_str)
            .map(|name| utf16_prefix(js_trim(name), NAME_MAX).to_string())
            .unwrap_or_default();
        let bundle = payload
            .get("v2")
            .filter(|bundle| crate::facts::truthy(Some(bundle)));
        let identity = match bundle {
            Some(bundle) => Self::from_bundle(bundle)?,
            None => {
                let key = payload
                    .get("key")
                    .and_then(Value::as_str)
                    .ok_or_else(|| CityError::malformed("the handover carries no key"))?;
                Self::from_key_string(key)?
            }
        };
        Ok((identity, name))
    }

    /// The person's identity number: the fingerprint of their inception.
    pub fn id(&self) -> &str {
        &self.inner.id
    }

    /// The `did:key` of the key this device signs with. For a version 2
    /// identity this is not the key in the inception record.
    pub fn did_key(&self) -> &str {
        &self.inner.did_key
    }

    /// The person's `did:webvh` identifier, when they have one that is
    /// plainly theirs. Records then name it as the controller of the key.
    pub fn controller(&self) -> Option<&str> {
        self.inner.controller.as_deref()
    }

    /// The inception record. Every batch sent to a city starts with it.
    pub fn inception(&self) -> &Value {
        &self.inner.inception
    }

    /// Whether the signing key is the one that opened the account. When it is
    /// not, readers need the person's DID log to accept what it signs.
    pub fn signs_with_inception_key(&self) -> bool {
        self.inner.inception["e"]["key"].as_str() == Some(self.inner.did_key.as_str())
    }

    pub fn to_stored(&self) -> StoredIdentity {
        let seed = Zeroizing::new(self.inner.signing.to_bytes());
        StoredIdentity {
            version: self.inner.version,
            id: self.inner.id.clone(),
            seed: b64url(seed.as_slice()),
            controller: self.inner.controller.clone(),
            inception: self.inner.inception.clone(),
        }
    }

    pub fn from_stored(stored: &StoredIdentity) -> Result<Identity> {
        let seed = seed_from_b64(&stored.seed)?;
        match stored.version {
            1 => {
                let identity = Self::from_recovery_seed(&seed)?;
                // A stored blob whose parts disagree was edited or mixed up;
                // signing under the wrong account is worse than refusing.
                if identity.inner.id != stored.id {
                    return Err(CityError::malformed(
                        "stored identity does not match its own key",
                    ));
                }
                Ok(identity)
            }
            2 => Self::from_signing_seed(
                &seed,
                &stored.id,
                stored.controller.as_deref().unwrap_or(""),
                &stored.inception,
            ),
            _ => Err(CityError::malformed(
                "stored identity has an unknown version",
            )),
        }
    }

    pub(crate) fn sign(&self, message: &[u8]) -> [u8; 64] {
        ed::sign(&self.inner.signing, message)
    }

    fn from_recovery_seed(seed: &[u8; 32]) -> Result<Identity> {
        let signing = SigningKey::from_bytes(seed);
        let did_key = ed::did_key(&signing.verifying_key().to_bytes());
        // The inception is fixed down to the byte (time zero, nothing else),
        // so one key can only ever open one account.
        let entry = json!({
            "v": 2, "type": record::INCEPTION, "by": null, "key": did_key,
            "deps": [], "links": [], "body": {}, "at": 0,
        });
        let signature = ed::sign(&signing, jcs::canonical(&entry)?.as_bytes());
        let id = jcs::fingerprint(&entry)?;
        Ok(Identity {
            inner: Arc::new(Inner {
                version: 1,
                id,
                did_key,
                controller: None,
                inception: json!({ "e": entry, "s": b64url(&signature) }),
                signing,
            }),
        })
    }

    fn from_bundle(bundle: &Value) -> Result<Identity> {
        const INCOMPLETE: &str = "the handover is incomplete";
        // The city's own receiver insists on all of these before it trusts a
        // bundle; a bundle it would turn away is not one to sign in with.
        let index_ok = bundle
            .get("j")
            .and_then(Value::as_f64)
            .is_some_and(|index| index >= 1.0 && index.fract() == 0.0);
        let id = bundle.get("id").and_then(Value::as_str);
        let inception = bundle.get("inc");
        let (Some(id), Some(inception), true) = (id, inception, index_ok) else {
            return Err(CityError::malformed(INCOMPLETE));
        };
        let seed = bundle
            .get("sign")
            .and_then(Value::as_str)
            .ok_or_else(|| CityError::malformed(INCOMPLETE))
            .and_then(seed_from_b64)?;
        // The device root travels with the bundle; this client has no use for
        // it, but a bundle without one was not packed by the city.
        let root_ok = bundle
            .get("root")
            .and_then(Value::as_str)
            .and_then(|root| unb64url(root).ok())
            .is_some_and(|root| root.len() == 32);
        if !root_ok {
            return Err(CityError::malformed(INCOMPLETE));
        }
        let controller = bundle.get("webvh").and_then(Value::as_str).unwrap_or("");
        Self::from_signing_seed(&seed, id, controller, inception)
    }

    fn from_signing_seed(
        seed: &[u8; 32],
        id: &str,
        controller: &str,
        inception: &Value,
    ) -> Result<Identity> {
        let entry = inception
            .get("e")
            .ok_or_else(|| CityError::malformed("the inception record is missing"))?;
        if !record::canonical_inception(entry) || !record::verify(inception) {
            return Err(CityError::malformed(
                "the inception record is not a valid inception",
            ));
        }
        // The identity number is nothing but the inception's fingerprint. If
        // they disagree, the key would sign under an account the inception
        // does not open.
        if jcs::fingerprint(entry)? != id {
            return Err(CityError::malformed(
                "the identity does not match its inception record",
            ));
        }
        let signing = SigningKey::from_bytes(seed);
        let did_key = ed::did_key(&signing.verifying_key().to_bytes());
        Ok(Identity {
            inner: Arc::new(Inner {
                version: 2,
                id: id.to_string(),
                did_key,
                controller: Some(controller)
                    .filter(|did| own_controller(did, id))
                    .map(str::to_string),
                inception: inception.clone(),
                signing,
            }),
        })
    }
}

/// Whether a `did:webvh` identifier is, by its own path, this person's: the
/// city only honours a controller whose last segment is the account number.
pub(crate) fn own_controller(did: &str, id: &str) -> bool {
    did.starts_with("did:webvh:") && did.ends_with(&format!(":u:{}", utf16_prefix(id, 16)))
}

fn seed_from_b64(text: &str) -> Result<Zeroizing<[u8; 32]>> {
    let bytes = Zeroizing::new(unb64url(text)?);
    let mut seed = Zeroizing::new([0u8; 32]);
    if bytes.len() != 32 {
        return Err(CityError::malformed("a key seed must be 32 bytes"));
    }
    seed.copy_from_slice(&bytes);
    Ok(seed)
}

fn checksum(prefix: &[u8], seed: &[u8]) -> [u8; 4] {
    let digest = Sha256::new()
        .chain_update(prefix)
        .chain_update(seed)
        .finalize();
    [digest[0], digest[1], digest[2], digest[3]]
}

/// The 32-byte seed inside a recovery key string, checksum verified.
fn seed_of_key_string(text: &str) -> Result<Zeroizing<[u8; 32]>> {
    let stripped = Zeroizing::new(strip_js_space(text));
    let body = stripped
        .strip_prefix(KEY_PREFIX)
        .unwrap_or(stripped.as_str());
    if body.is_empty() {
        return Err(CityError::malformed("no recovery key was given"));
    }
    if let Some(seed) = seed_of_person_os_code(body)? {
        return Ok(seed);
    }
    if body.len() > B58_MAX {
        return Err(CityError::malformed(
            "the recovery key has the wrong length",
        ));
    }
    let bytes = Zeroizing::new(
        unbase58(body)
            .map_err(|_| CityError::malformed("the recovery key has an invalid character"))?,
    );
    if bytes.len() != 36 {
        return Err(CityError::malformed(
            "the recovery key has the wrong length",
        ));
    }
    // A mistyped character must be caught here: without the check it would
    // quietly become some other, empty, account.
    if checksum(KEY_PREFIX.as_bytes(), &bytes[..32]) != bytes[32..] {
        return Err(CityError::Crypto);
    }
    let mut seed = Zeroizing::new([0u8; 32]);
    seed.copy_from_slice(&bytes[..32]);
    Ok(seed)
}

/// The backup code of the city's upstream software: the same seed under a
/// different wrapper (`0x96 0x01`, seed, four checksum bytes; 52 characters
/// starting `PC`). The city accepts it wherever it accepts its own key.
fn seed_of_person_os_code(body: &str) -> Result<Option<Zeroizing<[u8; 32]>>> {
    const HEAD: [u8; 2] = [0x96, 0x01];
    let shaped = body.len() == 52 && body.starts_with("PC") && body.bytes().all(is_base58);
    if !shaped {
        return Ok(None);
    }
    let Ok(bytes) = unbase58(body).map(Zeroizing::new) else {
        return Ok(None);
    };
    if bytes.len() != 38 || bytes[..2] != HEAD {
        return Ok(None);
    }
    if checksum(&HEAD, &bytes[2..34]) != bytes[34..] {
        return Err(CityError::Crypto);
    }
    let mut seed = Zeroizing::new([0u8; 32]);
    seed.copy_from_slice(&bytes[2..34]);
    Ok(Some(seed))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::text::base58;

    fn key_string(seed: &[u8; 32]) -> String {
        let mut bytes = seed.to_vec();
        bytes.extend_from_slice(&checksum(KEY_PREFIX.as_bytes(), seed));
        format!("{KEY_PREFIX}{}", base58(&bytes))
    }

    #[test]
    fn restores_the_same_identity_however_the_key_was_typed() {
        let key = key_string(&[7u8; 32]);
        let whole = Identity::from_key_string(&key).unwrap();
        let bare = &key[KEY_PREFIX.len()..];
        let spaced: String = bare
            .as_bytes()
            .chunks(4)
            .map(|chunk| std::str::from_utf8(chunk).unwrap())
            .collect::<Vec<_>>()
            .join(" \n");
        assert_eq!(Identity::from_key_string(&spaced).unwrap().id(), whole.id());
        assert!(whole.signs_with_inception_key());
        assert!(whole.controller().is_none());
        assert!(record::verify(whole.inception()));
        assert_eq!(whole.inception()["e"]["key"], whole.did_key());
    }

    #[test]
    fn a_mistyped_key_is_caught_not_turned_into_another_account() {
        let key = key_string(&[7u8; 32]);
        let mut typo = key.clone().into_bytes();
        let last = typo.len() - 1;
        typo[last] = if typo[last] == b'2' { b'3' } else { b'2' };
        assert_eq!(
            Identity::from_key_string(std::str::from_utf8(&typo).unwrap()).unwrap_err(),
            CityError::Crypto
        );
        assert!(Identity::from_key_string("").is_err());
        assert!(Identity::from_key_string("sibian-key-1:0OIl").is_err());
    }

    #[test]
    fn nothing_printable_reveals_the_seed() {
        let seed = [9u8; 32];
        let identity = Identity::from_key_string(&key_string(&seed)).unwrap();
        let stored = identity.to_stored();
        let shown = format!("{identity:?} {stored:?}");
        assert!(!shown.contains(&stored.seed));
        assert!(!shown.contains(&key_string(&seed)[KEY_PREFIX.len()..]));
        assert!(shown.contains("<redacted>"));
    }

    #[test]
    fn stored_form_round_trips_and_refuses_a_mismatch() {
        let identity = Identity::from_key_string(&key_string(&[3u8; 32])).unwrap();
        let stored = identity.to_stored();
        let text = serde_json::to_string(&stored).unwrap();
        let back: StoredIdentity = serde_json::from_str(&text).unwrap();
        assert_eq!(Identity::from_stored(&back).unwrap().id(), identity.id());

        let other = Identity::from_key_string(&key_string(&[4u8; 32])).unwrap();
        let mut mixed = identity.to_stored();
        mixed.id = other.id().to_string();
        assert!(Identity::from_stored(&mixed).is_err());
        let mut unknown = identity.to_stored();
        unknown.version = 9;
        assert!(Identity::from_stored(&unknown).is_err());
    }
}
