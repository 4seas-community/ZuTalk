//! Durable app-private storage for content encryption keys.

use std::collections::BTreeMap;
use std::path::Path;

use serde::{Deserialize, Serialize};
use uuid::Uuid;
use zeroize::{Zeroize, Zeroizing};

use crate::key_provider::KeyProvider;
use crate::private_file_store::{validate_identifier, PrivateJsonFile};
use crate::session_key::{SessionKey, KEY_SIZE};
use crate::CryptoError;

const CONTENT_KEY_STORE_VERSION: u32 = 1;

#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct PersistedFileKeys {
    version: u32,
    keys: BTreeMap<String, String>,
}

impl Default for PersistedFileKeys {
    fn default() -> Self {
        Self {
            version: CONTENT_KEY_STORE_VERSION,
            keys: BTreeMap::new(),
        }
    }
}

impl Drop for PersistedFileKeys {
    fn drop(&mut self) {
        for encoded in self.keys.values_mut() {
            encoded.zeroize();
        }
    }
}

pub struct FileKeyStore {
    file: PrivateJsonFile,
}

impl FileKeyStore {
    pub fn new(path: impl AsRef<Path>) -> Result<Self, CryptoError> {
        let store = Self {
            file: PrivateJsonFile::new(path)?,
        };
        // Fail closed at startup if an existing document cannot be decoded in
        // full. A missing document is a valid empty store.
        store.read_document()?;
        Ok(store)
    }

    fn decode_key(encoded: &str) -> Result<SessionKey, CryptoError> {
        let decoded =
            Zeroizing::new(
                hex::decode(encoded).map_err(|_| CryptoError::KeyStoreIntegrity {
                    message: "content key encoding is malformed".to_string(),
                })?,
            );
        if decoded.len() != KEY_SIZE {
            return Err(CryptoError::InvalidKeyLength {
                expected: KEY_SIZE,
                actual: decoded.len(),
            });
        }
        let mut bytes = [0u8; KEY_SIZE];
        bytes.copy_from_slice(&decoded);
        Ok(SessionKey::from_bytes(bytes))
    }

    fn validate_document(document: &PersistedFileKeys) -> Result<(), CryptoError> {
        if document.version != CONTENT_KEY_STORE_VERSION {
            return Err(CryptoError::KeyStoreIntegrity {
                message: "unsupported content key store version".to_string(),
            });
        }
        for (key_ref, encoded) in &document.keys {
            validate_identifier(key_ref, "key reference")?;
            drop(Self::decode_key(encoded)?);
        }
        Ok(())
    }

    fn read_document(&self) -> Result<PersistedFileKeys, CryptoError> {
        let transaction = self.file.shared()?;
        let document = transaction.read_json()?.unwrap_or_default();
        Self::validate_document(&document)?;
        Ok(document)
    }

    /// Return key references in deterministic order without exposing key bytes.
    pub fn list_key_refs(&self) -> Result<Vec<String>, CryptoError> {
        Ok(self.read_document()?.keys.keys().cloned().collect())
    }
}

impl KeyProvider for FileKeyStore {
    fn create_session_key(&self, session_id: &Uuid) -> Result<String, CryptoError> {
        let key = SessionKey::generate();
        let key_ref = format!("zulangue.audio.{session_id}");
        self.store_key(&key_ref, &key)?;
        Ok(key_ref)
    }

    fn load_key(&self, key_ref: &str) -> Result<SessionKey, CryptoError> {
        validate_identifier(key_ref, "key reference")?;
        let document = self.read_document()?;
        let encoded = document
            .keys
            .get(key_ref)
            .ok_or_else(|| CryptoError::KeyNotFound {
                key_ref: key_ref.to_string(),
            })?;
        Self::decode_key(encoded)
    }

    fn delete_key(&self, key_ref: &str) -> Result<(), CryptoError> {
        validate_identifier(key_ref, "key reference")?;
        let transaction = self.file.exclusive()?;
        let mut document: PersistedFileKeys = transaction.read_json()?.unwrap_or_default();
        Self::validate_document(&document)?;
        let Some(mut removed) = document.keys.remove(key_ref) else {
            return Ok(());
        };
        removed.zeroize();
        document.version = CONTENT_KEY_STORE_VERSION;
        transaction.write_json(&document)
    }

    fn key_exists(&self, key_ref: &str) -> bool {
        self.load_key(key_ref).is_ok()
    }

    fn store_key(&self, key_ref: &str, key: &SessionKey) -> Result<(), CryptoError> {
        validate_identifier(key_ref, "key reference")?;
        let transaction = self.file.exclusive()?;
        let mut document: PersistedFileKeys = transaction.read_json()?.unwrap_or_default();
        Self::validate_document(&document)?;
        document.version = CONTENT_KEY_STORE_VERSION;
        let encoded = hex::encode(key.as_bytes());
        if let Some(mut replaced) = document.keys.insert(key_ref.to_string(), encoded) {
            replaced.zeroize();
        }
        transaction.write_json(&document)
    }
}

#[cfg(test)]
mod tests {
    #[cfg(unix)]
    use std::process::{Command, Stdio};
    use std::sync::{Arc, Barrier};
    #[cfg(unix)]
    use std::time::{Duration, Instant};

    use tempfile::TempDir;

    use super::*;

    #[test]
    fn file_key_store_supports_store_then_load() {
        let tmp = TempDir::new().unwrap();
        let store = FileKeyStore::new(tmp.path().join("Secrets/content-keys.json")).unwrap();
        let key = SessionKey::from_bytes([7; KEY_SIZE]);

        store.store_key("zulangue.audio.current", &key).unwrap();

        assert_eq!(
            store.load_key("zulangue.audio.current").unwrap().as_bytes(),
            key.as_bytes()
        );
    }

    #[test]
    fn file_key_store_persists_keys_across_reopen() {
        let tmp = TempDir::new().unwrap();
        let path = tmp.path().join("Secrets/content-keys.json");
        let key = SessionKey::from_bytes([11; KEY_SIZE]);

        FileKeyStore::new(&path)
            .unwrap()
            .store_key("zulangue.audio.reopen", &key)
            .unwrap();

        let reopened = FileKeyStore::new(&path).unwrap();
        assert_eq!(
            reopened
                .load_key("zulangue.audio.reopen")
                .unwrap()
                .as_bytes(),
            key.as_bytes()
        );
    }

    #[test]
    fn file_key_store_delete_is_persistent_and_idempotent() {
        let tmp = TempDir::new().unwrap();
        let path = tmp.path().join("Secrets/content-keys.json");
        let store = FileKeyStore::new(&path).unwrap();
        store
            .store_key(
                "zulangue.audio.deleted",
                &SessionKey::from_bytes([13; KEY_SIZE]),
            )
            .unwrap();

        store.delete_key("zulangue.audio.deleted").unwrap();
        store.delete_key("zulangue.audio.deleted").unwrap();

        let reopened = FileKeyStore::new(&path).unwrap();
        assert!(!reopened.key_exists("zulangue.audio.deleted"));
        assert!(matches!(
            reopened.load_key("zulangue.audio.deleted"),
            Err(CryptoError::KeyNotFound { .. })
        ));
    }

    #[test]
    fn file_key_store_lists_in_deterministic_order() {
        let tmp = TempDir::new().unwrap();
        let store = FileKeyStore::new(tmp.path().join("Secrets/content-keys.json")).unwrap();
        for (key_ref, byte) in [
            ("zulangue.audio.z", 3),
            ("zulangue.audio.a", 1),
            ("zulangue.audio.m", 2),
        ] {
            store
                .store_key(key_ref, &SessionKey::from_bytes([byte; KEY_SIZE]))
                .unwrap();
        }

        assert_eq!(
            store.list_key_refs().unwrap(),
            vec!["zulangue.audio.a", "zulangue.audio.m", "zulangue.audio.z"]
        );
    }

    #[cfg(unix)]
    #[test]
    fn file_key_store_enforces_private_directory_and_file_permissions() {
        use std::os::unix::fs::{MetadataExt, PermissionsExt};

        let tmp = TempDir::new().unwrap();
        let secrets = tmp.path().join("Secrets");
        let path = secrets.join("content-keys.json");
        let store = FileKeyStore::new(&path).unwrap();
        store
            .store_key(
                "zulangue.audio.permissions",
                &SessionKey::from_bytes([17; KEY_SIZE]),
            )
            .unwrap();

        assert_eq!(
            std::fs::metadata(&secrets).unwrap().permissions().mode() & 0o777,
            0o700
        );
        assert_eq!(
            std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        assert_eq!(
            std::fs::metadata(path.with_file_name("content-keys.json.lock"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
        // The final data inode is the atomically renamed temp inode, so these
        // assertions cover directory, lock, data, and temp-file ownership.
        // SAFETY: geteuid takes no pointers and has no preconditions.
        let effective_user = unsafe { libc::geteuid() };
        assert_eq!(std::fs::metadata(&secrets).unwrap().uid(), effective_user);
        assert_eq!(std::fs::metadata(&path).unwrap().uid(), effective_user);
        assert_eq!(
            std::fs::metadata(path.with_file_name("content-keys.json.lock"))
                .unwrap()
                .uid(),
            effective_user
        );
    }

    #[test]
    fn file_key_store_rejects_traversal_like_key_references() {
        let tmp = TempDir::new().unwrap();
        let path = tmp.path().join("Secrets/content-keys.json");
        let outside = tmp.path().join("outside");
        std::fs::write(&outside, b"unchanged").unwrap();
        let store = FileKeyStore::new(&path).unwrap();

        assert!(matches!(
            store.store_key("../outside", &SessionKey::from_bytes([19; KEY_SIZE])),
            Err(CryptoError::InvalidIdentifier { .. })
        ));
        assert_eq!(std::fs::read(&outside).unwrap(), b"unchanged");
        assert!(!path.exists());
    }

    #[test]
    fn file_key_store_fails_closed_on_malformed_or_invalid_documents() {
        for contents in [
            Vec::new(),
            b"not-json".to_vec(),
            br#"{"version":1,"keys":{"zulangue.audio.bad":"00"}}"#.to_vec(),
            br#"{"version":1,"keys":{},"unexpected":true}"#.to_vec(),
            br#"{"version":99,"keys":{}}"#.to_vec(),
        ] {
            let tmp = TempDir::new().unwrap();
            let secrets = tmp.path().join("Secrets");
            std::fs::create_dir_all(&secrets).unwrap();
            let path = secrets.join("content-keys.json");
            std::fs::write(&path, contents).unwrap();

            assert!(FileKeyStore::new(&path).is_err());
        }
    }

    #[cfg(unix)]
    #[test]
    fn file_key_store_rejects_symlink_data_files() {
        use std::os::unix::fs::symlink;

        let tmp = TempDir::new().unwrap();
        let secrets = tmp.path().join("Secrets");
        std::fs::create_dir_all(&secrets).unwrap();
        let outside = tmp.path().join("outside.json");
        std::fs::write(&outside, br#"{"keys":{}}"#).unwrap();
        let path = secrets.join("content-keys.json");
        symlink(&outside, &path).unwrap();

        assert!(matches!(
            FileKeyStore::new(&path),
            Err(CryptoError::KeyStoreIntegrity { .. })
        ));
    }

    #[cfg(unix)]
    #[test]
    fn file_key_store_open_sweeps_only_safe_exact_stale_temps() {
        use std::os::unix::fs::{symlink, PermissionsExt};

        let tmp = TempDir::new().unwrap();
        let secrets = tmp.path().join("Secrets");
        std::fs::create_dir_all(&secrets).unwrap();
        let path = secrets.join("content-keys.json");

        let safe = secrets.join(".content-keys.json.tmp-101-00000000-0000-4000-8000-000000000001");
        std::fs::write(&safe, b"stale secret fixture").unwrap();
        std::fs::set_permissions(&safe, std::fs::Permissions::from_mode(0o600)).unwrap();

        let malformed_name = secrets.join(".content-keys.json.tmp-102-not-a-uuid");
        std::fs::write(&malformed_name, b"unrelated fixture").unwrap();
        std::fs::set_permissions(&malformed_name, std::fs::Permissions::from_mode(0o600)).unwrap();

        let other_store =
            secrets.join(".other-secrets.json.tmp-103-00000000-0000-4000-8000-000000000002");
        std::fs::write(&other_store, b"other store fixture").unwrap();
        std::fs::set_permissions(&other_store, std::fs::Permissions::from_mode(0o600)).unwrap();

        let widened =
            secrets.join(".content-keys.json.tmp-104-00000000-0000-4000-8000-000000000003");
        std::fs::write(&widened, b"widened fixture").unwrap();
        std::fs::set_permissions(&widened, std::fs::Permissions::from_mode(0o644)).unwrap();

        let outside = tmp.path().join("outside");
        std::fs::write(&outside, b"outside fixture").unwrap();
        let linked =
            secrets.join(".content-keys.json.tmp-105-00000000-0000-4000-8000-000000000004");
        symlink(&outside, &linked).unwrap();

        let directory =
            secrets.join(".content-keys.json.tmp-106-00000000-0000-4000-8000-000000000005");
        std::fs::create_dir(&directory).unwrap();

        let hard_link_source = tmp.path().join("hard-link-source");
        std::fs::write(&hard_link_source, b"hard-linked fixture").unwrap();
        std::fs::set_permissions(&hard_link_source, std::fs::Permissions::from_mode(0o600))
            .unwrap();
        let hard_link =
            secrets.join(".content-keys.json.tmp-107-00000000-0000-4000-8000-000000000006");
        std::fs::hard_link(&hard_link_source, &hard_link).unwrap();

        FileKeyStore::new(&path).unwrap();

        assert!(!safe.exists());
        for preserved in [
            &malformed_name,
            &other_store,
            &widened,
            &linked,
            &directory,
            &hard_link,
        ] {
            assert!(std::fs::symlink_metadata(preserved).is_ok());
        }
        assert_eq!(std::fs::read(&outside).unwrap(), b"outside fixture");
        assert_eq!(
            std::fs::read(&hard_link_source).unwrap(),
            b"hard-linked fixture"
        );
    }

    #[test]
    fn concurrent_file_key_store_instances_do_not_lose_updates() {
        const WRITERS: usize = 12;
        let tmp = TempDir::new().unwrap();
        let path = Arc::new(tmp.path().join("Secrets/content-keys.json"));
        let barrier = Arc::new(Barrier::new(WRITERS));

        std::thread::scope(|scope| {
            for index in 0..WRITERS {
                let path = Arc::clone(&path);
                let barrier = Arc::clone(&barrier);
                scope.spawn(move || {
                    let store = FileKeyStore::new(path.as_ref()).unwrap();
                    barrier.wait();
                    store
                        .store_key(
                            &format!("zulangue.audio.concurrent-{index}"),
                            &SessionKey::from_bytes([index as u8; KEY_SIZE]),
                        )
                        .unwrap();
                });
            }
        });

        let reopened = FileKeyStore::new(path.as_ref()).unwrap();
        assert_eq!(reopened.list_key_refs().unwrap().len(), WRITERS);
        for index in 0..WRITERS {
            assert_eq!(
                reopened
                    .load_key(&format!("zulangue.audio.concurrent-{index}"))
                    .unwrap()
                    .as_bytes(),
                &[index as u8; KEY_SIZE]
            );
        }
    }

    #[cfg(unix)]
    #[test]
    fn cross_process_writer_helper() {
        let Some(path) = std::env::var_os("VT_FILE_KEY_STORE_PROCESS_PATH") else {
            return;
        };
        let barrier_dir = std::path::PathBuf::from(
            std::env::var_os("VT_FILE_KEY_STORE_PROCESS_BARRIER").unwrap(),
        );
        let index: usize = std::env::var("VT_FILE_KEY_STORE_PROCESS_INDEX")
            .unwrap()
            .parse()
            .unwrap();
        let writer_count: usize = std::env::var("VT_FILE_KEY_STORE_PROCESS_COUNT")
            .unwrap()
            .parse()
            .unwrap();
        let store = FileKeyStore::new(path).unwrap();
        std::fs::write(barrier_dir.join(format!("ready-{index}")), b"ready").unwrap();

        let deadline = Instant::now() + Duration::from_secs(10);
        while std::fs::read_dir(&barrier_dir).unwrap().count() < writer_count {
            assert!(Instant::now() < deadline, "cross-process barrier timed out");
            std::thread::sleep(Duration::from_millis(5));
        }

        store
            .store_key(
                &format!("zulangue.audio.process-{index}"),
                &SessionKey::from_bytes([index as u8 + 31; KEY_SIZE]),
            )
            .unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn separate_processes_reload_under_the_stable_file_lock() {
        const WRITERS: usize = 4;
        let tmp = TempDir::new().unwrap();
        let path = tmp.path().join("Secrets/content-keys.json");
        let barrier_dir = tmp.path().join("process-barrier");
        std::fs::create_dir(&barrier_dir).unwrap();
        let executable = std::env::current_exe().unwrap();

        let children = (0..WRITERS)
            .map(|index| {
                Command::new(&executable)
                    .arg("--exact")
                    .arg("file_key_store::tests::cross_process_writer_helper")
                    .arg("--nocapture")
                    .env("VT_FILE_KEY_STORE_PROCESS_PATH", &path)
                    .env("VT_FILE_KEY_STORE_PROCESS_BARRIER", &barrier_dir)
                    .env("VT_FILE_KEY_STORE_PROCESS_INDEX", index.to_string())
                    .env("VT_FILE_KEY_STORE_PROCESS_COUNT", WRITERS.to_string())
                    .stdout(Stdio::null())
                    .stderr(Stdio::piped())
                    .spawn()
                    .unwrap()
            })
            .collect::<Vec<_>>();

        for child in children {
            let output = child.wait_with_output().unwrap();
            assert!(
                output.status.success(),
                "writer failed: {}",
                String::from_utf8_lossy(&output.stderr)
            );
        }

        let reopened = FileKeyStore::new(&path).unwrap();
        assert_eq!(reopened.list_key_refs().unwrap().len(), WRITERS);
        for index in 0..WRITERS {
            assert_eq!(
                reopened
                    .load_key(&format!("zulangue.audio.process-{index}"))
                    .unwrap()
                    .as_bytes(),
                &[index as u8 + 31; KEY_SIZE]
            );
        }
    }

    #[test]
    fn stale_instance_delete_reloads_and_preserves_other_updates() {
        let tmp = TempDir::new().unwrap();
        let path = tmp.path().join("Secrets/content-keys.json");
        let first = FileKeyStore::new(&path).unwrap();
        let second = FileKeyStore::new(&path).unwrap();
        first
            .store_key(
                "zulangue.audio.first",
                &SessionKey::from_bytes([1; KEY_SIZE]),
            )
            .unwrap();
        second
            .store_key(
                "zulangue.audio.second",
                &SessionKey::from_bytes([2; KEY_SIZE]),
            )
            .unwrap();

        first.delete_key("zulangue.audio.first").unwrap();

        assert!(!second.key_exists("zulangue.audio.first"));
        assert!(second.key_exists("zulangue.audio.second"));
    }

    #[test]
    fn atomic_writes_leave_no_temporary_files() {
        let tmp = TempDir::new().unwrap();
        let secrets = tmp.path().join("Secrets");
        let store = FileKeyStore::new(secrets.join("content-keys.json")).unwrap();
        store
            .store_key(
                "zulangue.audio.clean",
                &SessionKey::from_bytes([23; KEY_SIZE]),
            )
            .unwrap();

        let names = std::fs::read_dir(&secrets)
            .unwrap()
            .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
            .collect::<Vec<_>>();
        assert!(!names.iter().any(|name| name.contains(".tmp-")));
    }
}
