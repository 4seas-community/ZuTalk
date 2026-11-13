//! Ed25519 the way the city judges it.
//!
//! RFC 8032 leaves verification loose enough that engines disagree on
//! small-order points and non-canonical encodings, and a record that verifies
//! on one device but not another splits the city's data. The city therefore
//! fixes one rule (its `edShape`, after libsodium's rejection list) in front
//! of the cofactorless equation, in the browser and on the server alike. A
//! reader that is more lenient than that would list records no browser shows;
//! one that is stricter would hide records everyone else sees.

use ed25519_dalek::{Signature, Signer, SigningKey, Verifier, VerifyingKey};

use crate::error::{CityError, Result};
use crate::text::{base58, unbase58};

/// The order of the base point's group, little-endian.
const L: [u8; 32] = [
    0xed, 0xd3, 0xf5, 0x5c, 0x1a, 0x63, 0x12, 0x58, 0xd6, 0x9c, 0xf7, 0xa2, 0xde, 0xf9, 0xde, 0x14,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10,
];

/// The field prime 2^255 - 19, little-endian.
const P: [u8; 32] = [
    0xed, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x7f,
];

/// Encodings of the points of small order, sign bit cleared. A key of small
/// order paired with `S = 0` verifies for every message.
const SMALL_ORDER: [[u8; 32]; 7] = [
    [0; 32],
    [
        1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0,
    ],
    [
        0x26, 0xe8, 0x95, 0x8f, 0xc2, 0xb2, 0x27, 0xb0, 0x45, 0xc3, 0xf4, 0x89, 0xf2, 0xef, 0x98,
        0xf0, 0xd5, 0xdf, 0xac, 0x05, 0xd3, 0xc6, 0x33, 0x39, 0xb1, 0x38, 0x02, 0x88, 0x6d, 0x53,
        0xfc, 0x05,
    ],
    [
        0xc7, 0x17, 0x6a, 0x70, 0x3d, 0x4d, 0xd8, 0x4f, 0xba, 0x3c, 0x0b, 0x76, 0x0d, 0x10, 0x67,
        0x0f, 0x2a, 0x20, 0x53, 0xfa, 0x2c, 0x39, 0xcc, 0xc6, 0x4e, 0xc7, 0xfd, 0x77, 0x92, 0xac,
        0x03, 0x7a,
    ],
    [
        0xec, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0x7f,
    ],
    [
        0xed, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0x7f,
    ],
    [
        0xee, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0x7f,
    ],
];

/// `a < b` for 32-byte little-endian integers.
fn less(a: &[u8; 32], b: &[u8; 32]) -> bool {
    for index in (0..32).rev() {
        if a[index] != b[index] {
            return a[index] < b[index];
        }
    }
    false
}

fn small_order(point: &[u8; 32]) -> bool {
    let mut cleared = *point;
    cleared[31] &= 0x7f;
    SMALL_ORDER.contains(&cleared)
}

/// The city's shape rule: `S` below the group order, the key canonically
/// encoded, and neither the key nor `R` a point of small order.
pub(crate) fn shape_ok(public: &[u8; 32], signature: &[u8; 64]) -> bool {
    let mut r = [0u8; 32];
    let mut s = [0u8; 32];
    r.copy_from_slice(&signature[..32]);
    s.copy_from_slice(&signature[32..]);
    let mut y = *public;
    y[31] &= 0x7f;
    less(&s, &L) && less(&y, &P) && !small_order(public) && !small_order(&r)
}

/// Verifies as the city does: the shape rule, then the cofactorless equation
/// with `R` compared byte for byte (what OpenSSL, BoringSSL and the city's
/// fallback all compute). Anything that cannot be decoded is simply `false`.
pub(crate) fn verify(public: &[u8], message: &[u8], signature: &[u8]) -> bool {
    let (Ok(public), Ok(signature)) = (
        <&[u8; 32]>::try_from(public),
        <&[u8; 64]>::try_from(signature),
    ) else {
        return false;
    };
    if !shape_ok(public, signature) {
        return false;
    }
    let Ok(key) = VerifyingKey::from_bytes(public) else {
        return false;
    };
    key.verify(message, &Signature::from_bytes(signature))
        .is_ok()
}

pub(crate) fn sign(key: &SigningKey, message: &[u8]) -> [u8; 64] {
    key.sign(message).to_bytes()
}

/// `did:key` of an Ed25519 public key: multibase base58btc of the multicodec
/// prefix `0xed 0x01` and the 32 key bytes.
pub(crate) fn did_key(public: &[u8; 32]) -> String {
    let mut bytes = Vec::with_capacity(34);
    bytes.extend_from_slice(&[0xed, 0x01]);
    bytes.extend_from_slice(public);
    format!("did:key:z{}", base58(&bytes))
}

/// The 32 key bytes inside a multikey (`z…`). The prefix is checked, not
/// skipped: the same key under another prefix would otherwise be a second
/// identifier that verifies the same signatures.
pub(crate) fn multikey_bytes(multikey: &str) -> Result<[u8; 32]> {
    let body = multikey
        .strip_prefix('z')
        .ok_or_else(|| CityError::malformed("key is not multibase base58btc"))?;
    let bytes = unbase58(body)?;
    if bytes.len() != 34 || bytes[0] != 0xed || bytes[1] != 0x01 {
        return Err(CityError::malformed("key is not an Ed25519 public key"));
    }
    let mut out = [0u8; 32];
    out.copy_from_slice(&bytes[2..]);
    Ok(out)
}

/// The key bytes of an Ed25519 `did:key`.
pub(crate) fn did_key_bytes(did: &str) -> Result<[u8; 32]> {
    let multikey = did
        .strip_prefix("did:key:")
        .ok_or_else(|| CityError::malformed("not a did:key"))?;
    multikey_bytes(multikey)
}
