//! 内存密钥存储（仅用于隔离测试）。
//! 生产环境使用 `FileKeyStore` 的应用私有持久文件后端。

use std::collections::HashMap;
use std::sync::Mutex;
use uuid::Uuid;
use zeroize::Zeroize;

use crate::session_key::{SessionKey, KEY_SIZE};
use crate::CryptoError;

/// 内存密钥存储
pub struct MemoryKeyStore {
    store: Mutex<HashMap<String, Vec<u8>>>,
}

impl MemoryKeyStore {
    pub fn new() -> Self {
        Self {
            store: Mutex::new(HashMap::new()),
        }
    }

    pub fn create_session_key(&self, session_id: &Uuid) -> Result<String, CryptoError> {
        let key = SessionKey::generate();
        let key_ref = format!("zulangue.audio.{session_id}");
        let mut store = self.store.lock().unwrap();
        store.insert(key_ref.clone(), key.as_bytes().to_vec());
        Ok(key_ref)
    }

    pub fn load_key(&self, key_ref: &str) -> Result<SessionKey, CryptoError> {
        let store = self.store.lock().unwrap();
        let bytes = store.get(key_ref).ok_or(CryptoError::KeyNotFound {
            key_ref: key_ref.to_string(),
        })?;
        if bytes.len() != KEY_SIZE {
            return Err(CryptoError::InvalidKeyLength {
                expected: KEY_SIZE,
                actual: bytes.len(),
            });
        }
        let mut arr = [0u8; KEY_SIZE];
        arr.copy_from_slice(bytes);
        Ok(SessionKey::from_bytes(arr))
    }

    pub fn delete_key(&self, key_ref: &str) -> Result<(), CryptoError> {
        let mut store = self.store.lock().unwrap();
        if let Some(mut v) = store.remove(key_ref) {
            v.zeroize();
        }
        Ok(())
    }

    pub fn key_exists(&self, key_ref: &str) -> bool {
        self.store.lock().unwrap().contains_key(key_ref)
    }

    /// 直接存储原始密钥字节
    pub fn store_raw(&self, key_ref: &str, key_bytes: &[u8; KEY_SIZE]) -> Result<(), CryptoError> {
        let mut store = self.store.lock().unwrap();
        store.insert(key_ref.to_string(), key_bytes.to_vec());
        Ok(())
    }
}

impl Default for MemoryKeyStore {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_key_roundtrip() {
        let store = MemoryKeyStore::new();
        let session_id = Uuid::new_v4();
        let key_ref = store.create_session_key(&session_id).unwrap();
        let loaded = store.load_key(&key_ref).unwrap();
        assert_eq!(loaded.as_bytes().len(), 32);
        store.delete_key(&key_ref).unwrap();
    }

    #[test]
    fn test_delete_then_load_fails() {
        let store = MemoryKeyStore::new();
        let session_id = Uuid::new_v4();
        let key_ref = store.create_session_key(&session_id).unwrap();
        store.delete_key(&key_ref).unwrap();
        assert!(store.load_key(&key_ref).is_err());
    }

    #[test]
    fn test_delete_idempotent() {
        let store = MemoryKeyStore::new();
        let session_id = Uuid::new_v4();
        let key_ref = store.create_session_key(&session_id).unwrap();
        store.delete_key(&key_ref).unwrap();
        store.delete_key(&key_ref).unwrap(); // 幂等
    }

    #[test]
    fn test_key_exists() {
        let store = MemoryKeyStore::new();
        let session_id = Uuid::new_v4();
        let key_ref = store.create_session_key(&session_id).unwrap();
        assert!(store.key_exists(&key_ref));
        store.delete_key(&key_ref).unwrap();
        assert!(!store.key_exists(&key_ref));
    }

    #[test]
    fn test_unique_keys() {
        let store = MemoryKeyStore::new();
        let ref1 = store.create_session_key(&Uuid::new_v4()).unwrap();
        let ref2 = store.create_session_key(&Uuid::new_v4()).unwrap();
        let k1 = store.load_key(&ref1).unwrap();
        let k2 = store.load_key(&ref2).unwrap();
        assert_ne!(k1.as_bytes(), k2.as_bytes());
    }
}
