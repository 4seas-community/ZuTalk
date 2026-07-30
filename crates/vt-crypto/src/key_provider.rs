//! 统一密钥管理接口
//! 生产用 FileKeyStore（应用私有文件）
//! 测试用 MemoryKeyStore（内存 HashMap）

use uuid::Uuid;

use crate::session_key::SessionKey;
use crate::CryptoError;

/// 密钥提供者 trait — 抽象持久文件和内存存储
pub trait KeyProvider: Send + Sync {
    fn create_session_key(&self, session_id: &Uuid) -> Result<String, CryptoError>;
    fn load_key(&self, key_ref: &str) -> Result<SessionKey, CryptoError>;
    fn delete_key(&self, key_ref: &str) -> Result<(), CryptoError>;
    fn key_exists(&self, key_ref: &str) -> bool;

    /// 直接存储一个已有的 key（用于录音完成后存入）
    fn store_key(&self, key_ref: &str, key: &SessionKey) -> Result<(), CryptoError>;
}

/// 内存密钥提供者（测试用）
impl KeyProvider for crate::MemoryKeyStore {
    fn create_session_key(&self, session_id: &Uuid) -> Result<String, CryptoError> {
        self.create_session_key(session_id)
    }

    fn load_key(&self, key_ref: &str) -> Result<SessionKey, CryptoError> {
        self.load_key(key_ref)
    }

    fn delete_key(&self, key_ref: &str) -> Result<(), CryptoError> {
        self.delete_key(key_ref)
    }

    fn key_exists(&self, key_ref: &str) -> bool {
        self.key_exists(key_ref)
    }

    fn store_key(&self, key_ref: &str, key: &SessionKey) -> Result<(), CryptoError> {
        // MemoryKeyStore 需要一个 insert 方法
        // 用内部 store 直接插入
        self.store_raw(key_ref, key.as_bytes())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::MemoryKeyStore;

    #[test]
    fn test_key_provider_trait() {
        let store = MemoryKeyStore::new();
        let provider: &dyn KeyProvider = &store;

        let key_ref = provider.create_session_key(&Uuid::new_v4()).unwrap();
        assert!(provider.key_exists(&key_ref));

        let key = provider.load_key(&key_ref).unwrap();
        assert_eq!(key.as_bytes().len(), 32);

        provider.delete_key(&key_ref).unwrap();
        assert!(!provider.key_exists(&key_ref));
    }

    #[test]
    fn test_store_key() {
        let store = MemoryKeyStore::new();
        let provider: &dyn KeyProvider = &store;

        let key = SessionKey::generate();
        provider.store_key("test-ref", &key).unwrap();

        let loaded = provider.load_key("test-ref").unwrap();
        assert_eq!(loaded.as_bytes(), key.as_bytes());
    }
}
