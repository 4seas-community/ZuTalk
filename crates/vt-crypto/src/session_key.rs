//! Session key material kept in zeroizing memory.

use zeroize::Zeroize;

pub const KEY_SIZE: usize = 32; // AES-256

/// AES-256 session key.
pub struct SessionKey {
    bytes: [u8; KEY_SIZE],
}

impl SessionKey {
    /// Generate a new key from the operating system random source.
    pub fn generate() -> Self {
        use rand::RngCore;
        let mut bytes = [0u8; KEY_SIZE];
        rand::rng().fill_bytes(&mut bytes);
        Self { bytes }
    }

    /// Construct a key from an already validated byte array.
    pub fn from_bytes(bytes: [u8; KEY_SIZE]) -> Self {
        Self { bytes }
    }

    /// Borrow key bytes only for cryptographic operations or persistence.
    pub fn as_bytes(&self) -> &[u8; KEY_SIZE] {
        &self.bytes
    }
}

impl Drop for SessionKey {
    fn drop(&mut self) {
        self.bytes.zeroize();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn session_key_generate_is_32_bytes() {
        let key = SessionKey::generate();
        assert_eq!(key.as_bytes().len(), KEY_SIZE);
    }

    #[test]
    fn session_key_from_bytes_roundtrips() {
        for byte in [0u8, 1, 127, 128, 254, 255] {
            let bytes = [byte; KEY_SIZE];
            let key = SessionKey::from_bytes(bytes);
            assert_eq!(key.as_bytes(), &bytes, "byte {byte}");
        }
    }

    #[test]
    fn session_key_generate_is_unique() {
        let first = SessionKey::generate();
        let second = SessionKey::generate();
        assert_ne!(first.as_bytes(), second.as_bytes());
    }

    #[test]
    fn session_key_drop_zeroizes_without_panicking() {
        drop(SessionKey::generate());
    }
}
