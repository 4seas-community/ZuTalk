//! Soniox API Key 进程内存储
//!
//! 和持久化 AES session-key store 分离是有意的:
//! - session key: 32 bytes 随机,per-session,数量多
//! - api key: 用户输入的 Soniox 字符串,单一长期凭据
//!
//! 产品层唯一允许的 scope 是 `soniox`。
//!
//! UI 层(Swift)只应该调 set/has/clear,从不 get(get 只内部用)。
//! 这样 api key 明文不跨 FFI 泄露。

use std::collections::HashMap;
use std::sync::Mutex;

use crate::CryptoError;

/// API key 存储后端抽象
pub trait ApiKeyProvider: Send + Sync {
    fn set(&self, scope: &str, value: &str) -> Result<(), CryptoError>;
    fn get(&self, scope: &str) -> Result<String, CryptoError>;
    fn has(&self, scope: &str) -> bool;
    fn clear(&self, scope: &str) -> Result<(), CryptoError>;
}

/// 进程内实现。生产运行时也固定使用它；持久化由 Swift 的本机私有文件边界
/// 负责，并在 App 启动时通过 FFI 注入。
pub struct MemoryApiKeyStore {
    store: Mutex<HashMap<String, String>>,
}

impl MemoryApiKeyStore {
    pub fn new() -> Self {
        Self {
            store: Mutex::new(HashMap::new()),
        }
    }
}

impl Default for MemoryApiKeyStore {
    fn default() -> Self {
        Self::new()
    }
}

impl ApiKeyProvider for MemoryApiKeyStore {
    fn set(&self, scope: &str, value: &str) -> Result<(), CryptoError> {
        self.store
            .lock()
            .unwrap()
            .insert(scope.to_string(), value.to_string());
        Ok(())
    }

    fn get(&self, scope: &str) -> Result<String, CryptoError> {
        self.store
            .lock()
            .unwrap()
            .get(scope)
            .cloned()
            .ok_or_else(|| CryptoError::KeyNotFound {
                key_ref: format!("api_key:{scope}"),
            })
    }

    fn has(&self, scope: &str) -> bool {
        self.store.lock().unwrap().contains_key(scope)
    }

    fn clear(&self, scope: &str) -> Result<(), CryptoError> {
        let mut s = self.store.lock().unwrap();
        s.remove(scope);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_memory_set_get_roundtrip() {
        let store = MemoryApiKeyStore::new();
        store.set("soniox", "sk-xyz").unwrap();
        assert_eq!(store.get("soniox").unwrap(), "sk-xyz");
    }

    #[test]
    fn test_memory_has_reports_presence() {
        let store = MemoryApiKeyStore::new();
        assert!(!store.has("soniox"));
        store.set("soniox", "k").unwrap();
        assert!(store.has("soniox"));
    }

    #[test]
    fn test_memory_clear_removes() {
        let store = MemoryApiKeyStore::new();
        store.set("soniox", "v").unwrap();
        store.clear("soniox").unwrap();
        assert!(!store.has("soniox"));
        assert!(store.get("soniox").is_err());
    }

    #[test]
    fn test_memory_clear_idempotent() {
        let store = MemoryApiKeyStore::new();
        store.clear("never-set").unwrap(); // 不应 panic
    }

    #[test]
    fn test_memory_overwrite() {
        let store = MemoryApiKeyStore::new();
        store.set("soniox", "v1").unwrap();
        store.set("soniox", "v2").unwrap();
        assert_eq!(store.get("soniox").unwrap(), "v2");
    }

    #[test]
    fn test_get_missing_returns_not_found() {
        let store = MemoryApiKeyStore::new();
        match store.get("nope") {
            Err(CryptoError::KeyNotFound { key_ref }) => {
                assert!(key_ref.contains("nope"));
            }
            other => panic!("expected KeyNotFound, got {other:?}"),
        }
    }
}
