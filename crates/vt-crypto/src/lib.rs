//! Zulangue 加密层
//!
//! AES-256-GCM 加密 + 本机私有文件密钥存储 + zeroize 内存清零。
//! 当前持久化边界见 `docs/architecture/ARCHITECTURE.md`。

pub mod api_key_store;
pub mod decrypt;
pub mod encrypt;
pub mod error;
pub mod file_key_store;
pub mod key_provider;
pub mod memory_store;
mod private_file_store;
pub mod session_key;

pub use api_key_store::{ApiKeyProvider, MemoryApiKeyStore};
pub use decrypt::{decrypt_range, encrypt_to_file, DecryptRange, DecryptReader};
pub use encrypt::{decrypt_chunk, encrypt_chunk};
pub use error::CryptoError;
pub use file_key_store::FileKeyStore;
pub use key_provider::KeyProvider;
pub use memory_store::MemoryKeyStore;
pub use session_key::{SessionKey, KEY_SIZE};
