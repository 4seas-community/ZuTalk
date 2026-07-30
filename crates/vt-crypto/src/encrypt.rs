//! 流式 AES-256-GCM 加密/解密
//! 设计引用：D2 §3

use aes_gcm::aead::{Aead, KeyInit, OsRng};
use aes_gcm::{AeadCore, Aes256Gcm, Nonce};

use crate::session_key::SessionKey;
use crate::CryptoError;

/// 加密单个 chunk（nonce || ciphertext || tag）
pub fn encrypt_chunk(plaintext: &[u8], key: &SessionKey) -> Result<Vec<u8>, CryptoError> {
    let cipher =
        Aes256Gcm::new_from_slice(key.as_bytes()).map_err(|e| CryptoError::EncryptionFailed {
            message: e.to_string(),
        })?;

    let nonce = Aes256Gcm::generate_nonce(&mut OsRng);
    let ciphertext =
        cipher
            .encrypt(&nonce, plaintext)
            .map_err(|e| CryptoError::EncryptionFailed {
                message: e.to_string(),
            })?;

    // 格式: nonce (12 bytes) || ciphertext+tag
    let mut result = Vec::with_capacity(12 + ciphertext.len());
    result.extend_from_slice(&nonce);
    result.extend_from_slice(&ciphertext);
    Ok(result)
}

/// 解密单个 chunk（输入格式: nonce || ciphertext || tag）
pub fn decrypt_chunk(data: &[u8], key: &SessionKey) -> Result<Vec<u8>, CryptoError> {
    if data.len() < 12 {
        return Err(CryptoError::DecryptionFailed {
            message: "data too short for nonce".to_string(),
        });
    }

    let cipher =
        Aes256Gcm::new_from_slice(key.as_bytes()).map_err(|e| CryptoError::DecryptionFailed {
            message: e.to_string(),
        })?;

    let nonce = Nonce::from_slice(&data[..12]);
    let ciphertext = &data[12..];

    cipher
        .decrypt(nonce, ciphertext)
        .map_err(|e| CryptoError::DecryptionFailed {
            message: e.to_string(),
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_encrypt_decrypt_roundtrip() {
        let key = SessionKey::generate();
        let plaintext = b"sensitive audio data for testing";
        let encrypted = encrypt_chunk(plaintext, &key).unwrap();
        let decrypted = decrypt_chunk(&encrypted, &key).unwrap();
        assert_eq!(plaintext.as_slice(), decrypted.as_slice());
    }

    #[test]
    fn test_empty_data_roundtrip() {
        let key = SessionKey::generate();
        let encrypted = encrypt_chunk(b"", &key).unwrap();
        let decrypted = decrypt_chunk(&encrypted, &key).unwrap();
        assert!(decrypted.is_empty());
    }

    #[test]
    fn test_wrong_key_fails() {
        let key1 = SessionKey::generate();
        let key2 = SessionKey::generate();
        let encrypted = encrypt_chunk(b"secret", &key1).unwrap();
        let result = decrypt_chunk(&encrypted, &key2);
        assert!(result.is_err());
    }

    #[test]
    fn test_tamper_detection() {
        let key = SessionKey::generate();
        let mut encrypted = encrypt_chunk(b"data", &key).unwrap();
        // 翻转密文中间的一个 bit
        if encrypted.len() > 15 {
            encrypted[15] ^= 0x01;
        }
        let result = decrypt_chunk(&encrypted, &key);
        assert!(result.is_err());
    }

    #[test]
    fn test_ciphertext_differs_from_plaintext() {
        let key = SessionKey::generate();
        let plaintext = b"hello world test data";
        let encrypted = encrypt_chunk(plaintext, &key).unwrap();
        // 密文（跳过 12 字节 nonce）不等于明文
        assert_ne!(&encrypted[12..], plaintext.as_slice());
    }

    #[test]
    fn test_different_nonces_produce_different_ciphertext() {
        let key = SessionKey::generate();
        let plaintext = b"same data";
        let enc1 = encrypt_chunk(plaintext, &key).unwrap();
        let enc2 = encrypt_chunk(plaintext, &key).unwrap();
        // 同一密钥同一明文，因为随机 nonce，密文不同
        assert_ne!(enc1, enc2);
    }

    #[test]
    fn test_data_too_short() {
        let key = SessionKey::generate();
        let result = decrypt_chunk(&[0u8; 5], &key);
        assert!(result.is_err());
    }
}
