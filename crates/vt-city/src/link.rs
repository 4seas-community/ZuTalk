//! Signing in by the city's "link a new device" flow.
//!
//! This device shows a code: a one-time room number and an ephemeral P-256
//! public key. A device that is already signed in scans it, answers with its
//! own ephemeral key, and both derive the same AES key and the same six
//! digits. The person compares the digits on the two screens; only then does
//! the old device seal the identity and pass it through the city's relay.
//!
//! The relay sees the room number and ciphertext. If it swapped the old
//! device's key for its own, the digits would differ and nothing would be
//! sent; if it swapped nothing, it cannot open the box. What the digits do
//! *not* protect against is someone photographing the code and answering
//! first with an identity of their own — so the caller must show whose
//! account arrived (see [`LinkStep::Done`]) before adopting it, as the city's
//! own sheet does.
//!
//! [`LinkSession`] is the state machine without the network: the caller
//! long-polls the relay (`Hub::relay_get`) and feeds what comes back to
//! [`LinkSession::absorb`].

use aes_gcm::aead::{Aead, KeyInit};
use aes_gcm::{Aes256Gcm, Nonce};
use hkdf::Hkdf;
use p256::elliptic_curve::sec1::ToSec1Point;
use p256::{PublicKey, SecretKey};
use rand::RngCore;
use serde_json::Value;
use sha2::Sha256;
use zeroize::{Zeroize, ZeroizeOnDrop, Zeroizing};

use crate::error::{CityError, Result};
use crate::identity::Identity;
use crate::text::{b64url, unb64url};

const KEY_INFO: &[u8] = b"sibian-link-1 key";
const CHECK_INFO: &[u8] = b"sibian-link-1 check";
const IV_LEN: usize = 12;

/// The key both devices derived. Wiped on drop; prints as nothing.
#[derive(Clone, Zeroize, ZeroizeOnDrop)]
pub struct SharedKey([u8; 32]);

impl std::fmt::Debug for SharedKey {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("SharedKey(<redacted>)")
    }
}

impl SharedKey {
    /// Wraps raw key bytes. Outside tests the only source is [`agree`].
    pub fn from_bytes(bytes: [u8; 32]) -> Self {
        SharedKey(bytes)
    }
}

/// What two devices agree on: the key that seals the handover, and the
/// digits a person compares across the two screens (`"123 456"`).
#[derive(Debug, Clone)]
pub struct Agreement {
    pub key: SharedKey,
    pub check: String,
}

/// One side's ephemeral key for a single link attempt.
pub struct LinkKey {
    secret: SecretKey,
    public: String,
}

impl LinkKey {
    pub fn generate() -> Result<LinkKey> {
        // A uniformly random 32-byte string is a valid P-256 scalar with
        // overwhelming probability; the loop covers the remainder instead of
        // biasing it away.
        for _ in 0..64 {
            let mut bytes = Zeroizing::new([0u8; 32]);
            rand::rng().fill_bytes(bytes.as_mut_slice());
            if let Ok(key) = Self::from_scalar(&bytes) {
                return Ok(key);
            }
        }
        Err(CityError::Crypto)
    }

    /// A key from a fixed scalar, so that tests can pin both sides.
    pub fn from_scalar(scalar: &[u8; 32]) -> Result<LinkKey> {
        let secret = SecretKey::from_slice(scalar).map_err(|_| CityError::Crypto)?;
        // The city exchanges the raw uncompressed point, base64url.
        let public = b64url(secret.public_key().to_sec1_point(false).as_bytes());
        Ok(LinkKey { secret, public })
    }

    pub fn public(&self) -> &str {
        &self.public
    }
}

/// Derives the shared key and check digits from our key and the other
/// device's public key.
///
/// Both public keys go into the salt, sorted, so the two sides compute the
/// same thing without agreeing on who is first, and so the digits commit to
/// the keys that were actually exchanged.
pub fn agree(mine: &LinkKey, theirs: &str) -> Result<Agreement> {
    let other = PublicKey::from_sec1_bytes(&unb64url(theirs)?).map_err(|_| CityError::Crypto)?;
    let shared = p256::ecdh::diffie_hellman(mine.secret.to_nonzero_scalar(), other.as_affine());
    let mut names = [mine.public.as_str(), theirs];
    names.sort_unstable();
    let salt = names.join(".");
    let kdf = Hkdf::<Sha256>::new(Some(salt.as_bytes()), shared.raw_secret_bytes());
    let mut key = Zeroizing::new([0u8; 32]);
    let mut check = [0u8; 4];
    kdf.expand(KEY_INFO, key.as_mut_slice())
        .and_then(|()| kdf.expand(CHECK_INFO, &mut check))
        .map_err(|_| CityError::Crypto)?;
    let digits = format!("{:06}", u32::from_be_bytes(check) % 1_000_000);
    Ok(Agreement {
        key: SharedKey(*key),
        check: format!("{} {}", &digits[..3], &digits[3..]),
    })
}

/// Seals a JSON value the way the city does: a random 12-byte IV and the
/// AES-256-GCM ciphertext with its tag, each base64url, joined by a dot.
pub fn seal_box(key: &SharedKey, value: &Value) -> Result<String> {
    let mut iv = [0u8; IV_LEN];
    rand::rng().fill_bytes(&mut iv);
    let plain = Zeroizing::new(
        serde_json::to_vec(value).map_err(|_| CityError::malformed("value cannot be sealed"))?,
    );
    let sealed = cipher(key)?
        .encrypt(Nonce::from_slice(&iv), plain.as_slice())
        .map_err(|_| CityError::Crypto)?;
    Ok(format!("{}.{}", b64url(&iv), b64url(&sealed)))
}

/// Opens a sealed box. A box sealed with another key, or altered on the way,
/// is [`CityError::Crypto`]; the plaintext is never part of an error.
pub fn open_box(key: &SharedKey, sealed: &str) -> Result<Value> {
    let mut parts = sealed.split('.');
    let (Some(iv), Some(body)) = (parts.next(), parts.next()) else {
        return Err(CityError::malformed("not a sealed box"));
    };
    let (iv, body) = (unb64url(iv)?, unb64url(body)?);
    if iv.len() != IV_LEN || body.is_empty() {
        return Err(CityError::malformed("not a sealed box"));
    }
    let plain = Zeroizing::new(
        cipher(key)?
            .decrypt(Nonce::from_slice(&iv), body.as_slice())
            .map_err(|_| CityError::Crypto)?,
    );
    serde_json::from_slice(&plain).map_err(|_| CityError::malformed("the box held no JSON"))
}

fn cipher(key: &SharedKey) -> Result<Aes256Gcm> {
    Aes256Gcm::new_from_slice(&key.0).map_err(|_| CityError::Crypto)
}

/// Where a link attempt stands after the latest messages.
#[derive(Debug, Clone)]
pub enum LinkStep {
    /// Nobody has scanned the code yet.
    Waiting,
    /// Another device answered. Show these digits; the person confirms on the
    /// other device that both screens agree.
    Check(String),
    /// An identity arrived. `name` is what the sending device calls the
    /// person and may be empty or untrue; show `identity.id()` and let the
    /// person confirm before keeping it.
    Done { identity: Identity, name: String },
    /// The person said the digits differ, and the other device called it off.
    Cancelled,
}

enum Phase {
    Waiting,
    Checking(Agreement),
    Done(Identity, String),
    Cancelled,
    Failed(CityError),
}

/// One attempt to receive an identity from another device.
pub struct LinkSession {
    room: String,
    key: LinkKey,
    since: u64,
    phase: Phase,
}

impl std::fmt::Debug for LinkSession {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // The room number is half of the code on screen; leave it out of logs.
        f.debug_struct("LinkSession")
            .field("since", &self.since)
            .finish_non_exhaustive()
    }
}

impl LinkSession {
    pub fn new() -> Result<LinkSession> {
        let mut room = [0u8; 16];
        rand::rng().fill_bytes(&mut room);
        Ok(Self::with_key(hex::encode(room), LinkKey::generate()?))
    }

    /// A session with a chosen room and key, so that tests can script both
    /// sides of the exchange.
    pub fn with_key(room: String, key: LinkKey) -> LinkSession {
        LinkSession {
            room,
            key,
            since: 0,
            phase: Phase::Waiting,
        }
    }

    /// The relay room to poll.
    pub fn room(&self) -> &str {
        &self.room
    }

    /// The code to show (as text or a QR code) for the other device to scan.
    pub fn code(&self) -> String {
        format!("os:link:{}.{}", self.room, self.key.public)
    }

    /// How many relay messages have been absorbed: the `since` of the next
    /// poll.
    pub fn since(&self) -> u64 {
        self.since
    }

    /// Takes the messages of one relay poll and the relay's new position.
    ///
    /// Returns where the attempt now stands. With nothing new it repeats the
    /// current standing, so after the digits are known an idle poll answers
    /// [`LinkStep::Check`] again rather than falling back to `Waiting`.
    pub fn absorb(&mut self, msgs: &[Value], n: u64) -> Result<LinkStep> {
        // The relay counts from the start of the room; a zero means it has
        // nothing for us (or forgot the room), not that we should rewind.
        if n > 0 {
            self.since = n;
        }
        for msg in msgs {
            if matches!(self.phase, Phase::Waiting | Phase::Checking(_)) {
                self.take(msg);
            }
        }
        match &self.phase {
            Phase::Waiting => Ok(LinkStep::Waiting),
            Phase::Checking(agreement) => Ok(LinkStep::Check(agreement.check.clone())),
            Phase::Done(identity, name) => Ok(LinkStep::Done {
                identity: identity.clone(),
                name: name.clone(),
            }),
            Phase::Cancelled => Ok(LinkStep::Cancelled),
            Phase::Failed(error) => Err(error.clone()),
        }
    }

    fn take(&mut self, msg: &Value) {
        let kind = msg.get("t").and_then(Value::as_str).unwrap_or("");
        match (kind, &self.phase) {
            // Only the first answer counts. A second device saying hello
            // later does not get to replace the key the digits were shown
            // for.
            ("hi", Phase::Waiting) => {
                let agreed = msg
                    .get("pub")
                    .and_then(Value::as_str)
                    .and_then(|theirs| agree(&self.key, theirs).ok());
                // A key that is not a point on the curve is noise in the
                // room; keep waiting for a real answer.
                if let Some(agreement) = agreed {
                    self.phase = Phase::Checking(agreement);
                }
            }
            ("no", _) => self.phase = Phase::Cancelled,
            // The old device also offers the person's record history in
            // sealed chunks. A recorder that only publishes has no use for
            // it, so the chunks are left unopened.
            ("recs", _) => {}
            ("key", Phase::Checking(agreement)) => {
                let Some(sealed) = msg.get("box").and_then(Value::as_str) else {
                    return;
                };
                // A box we cannot open was not sealed by the device whose
                // digits are on screen. The city's own receiver keeps
                // listening, and so do we.
                let Ok(payload) = open_box(&agreement.key, sealed) else {
                    return;
                };
                self.phase = match Identity::from_link_payload(&payload) {
                    Ok((identity, name)) => Phase::Done(identity, name),
                    Err(error) => Phase::Failed(error),
                };
            }
            _ => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn pair() -> (LinkKey, LinkKey) {
        (
            LinkKey::from_scalar(&[0x11; 32]).unwrap(),
            LinkKey::from_scalar(&[0x22; 32]).unwrap(),
        )
    }

    #[test]
    fn both_sides_agree_and_a_third_does_not() {
        let (new_device, old_device) = pair();
        let ours = agree(&new_device, old_device.public()).unwrap();
        let theirs = agree(&old_device, new_device.public()).unwrap();
        assert_eq!(ours.check, theirs.check);
        assert_eq!(ours.check.len(), 7);
        let sealed = seal_box(&theirs.key, &json!({"hello": "世界"})).unwrap();
        assert_eq!(
            open_box(&ours.key, &sealed).unwrap(),
            json!({"hello": "世界"})
        );

        let stranger = LinkKey::from_scalar(&[0x33; 32]).unwrap();
        let wrong = agree(&stranger, new_device.public()).unwrap();
        assert_eq!(
            open_box(&wrong.key, &sealed).unwrap_err(),
            CityError::Crypto
        );
        assert!(agree(&new_device, "AAAA").is_err());
    }

    #[test]
    fn a_tampered_box_does_not_open() {
        let (new_device, old_device) = pair();
        let key = agree(&new_device, old_device.public()).unwrap().key;
        let sealed = seal_box(&key, &json!([1, 2, 3])).unwrap();
        // Not the last character: its low bits are padding, and a decoder as
        // forgiving as the city's ignores them.
        let mut bytes = sealed.into_bytes();
        let middle = bytes.len() - 8;
        bytes[middle] = if bytes[middle] == b'A' { b'B' } else { b'A' };
        let tampered = String::from_utf8(bytes).unwrap();
        assert!(open_box(&key, &tampered).is_err());
        assert!(open_box(&key, "no-dot").is_err());
    }

    #[test]
    fn session_walks_from_waiting_to_cancelled() {
        let (new_device, old_device) = pair();
        let mut session = LinkSession::with_key("00".repeat(16), new_device);
        assert!(session
            .code()
            .starts_with("os:link:00000000000000000000000000000000."));
        assert!(matches!(session.absorb(&[], 0).unwrap(), LinkStep::Waiting));
        // Noise before a real answer changes nothing.
        let noise = [
            json!({"t": "hi", "pub": "AAAA"}),
            json!({"t": "key", "box": "x.y"}),
            json!(7),
        ];
        assert!(matches!(
            session.absorb(&noise, 3).unwrap(),
            LinkStep::Waiting
        ));
        assert_eq!(session.since(), 3);
        let hello = [json!({"t": "hi", "pub": old_device.public()})];
        let LinkStep::Check(digits) = session.absorb(&hello, 4).unwrap() else {
            panic!("expected the check digits");
        };
        // An idle poll repeats the digits.
        assert!(
            matches!(session.absorb(&[], 4).unwrap(), LinkStep::Check(again) if again == digits)
        );
        assert!(matches!(
            session.absorb(&[json!({"t": "no"})], 5).unwrap(),
            LinkStep::Cancelled
        ));
        // Nothing after a cancellation revives the attempt.
        assert!(matches!(
            session.absorb(&hello, 6).unwrap(),
            LinkStep::Cancelled
        ));
    }

    #[test]
    fn session_is_send_and_prints_no_secret() {
        fn assert_send<T: Send>() {}
        assert_send::<LinkSession>();
        let session = LinkSession::new().unwrap();
        let shown = format!("{session:?}");
        assert!(!shown.contains(session.room()));
        assert_eq!(session.room().len(), 32);
    }
}
