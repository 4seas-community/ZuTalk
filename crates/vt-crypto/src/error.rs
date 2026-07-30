//! vt-crypto 错误类型

#[derive(Debug, thiserror::Error)]
pub enum CryptoError {
    #[error("key not found: {key_ref}")]
    KeyNotFound { key_ref: String },

    #[error("secret store access error: {message}")]
    SecretStoreAccess { message: String },

    #[error("invalid {kind} identifier")]
    InvalidIdentifier { kind: &'static str },

    #[error("private key store integrity check failed: {message}")]
    KeyStoreIntegrity { message: String },

    #[error("invalid key length: expected {expected}, got {actual}")]
    InvalidKeyLength { expected: usize, actual: usize },

    #[error("encryption failed: {message}")]
    EncryptionFailed { message: String },

    #[error("decryption failed: {message}")]
    DecryptionFailed { message: String },

    #[error("serialization failed: {message}")]
    Serialization { message: String },

    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),
}
