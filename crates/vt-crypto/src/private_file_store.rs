//! Shared primitives for app-private JSON secret stores.
//!
//! The data file is protected by a stable sibling lock file. Writers always
//! reload the latest document while holding an exclusive cross-process lock,
//! then replace the data file atomically. The helper intentionally never logs
//! paths, identifiers, serialized documents, or secret material.

use std::collections::HashMap;
use std::ffi::OsString;
use std::fs::{File, OpenOptions};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock, Weak};

use serde::de::DeserializeOwned;
use serde::Serialize;
use uuid::Uuid;
use zeroize::Zeroizing;

use crate::CryptoError;

const MAX_PRIVATE_DOCUMENT_BYTES: u64 = 16 * 1024 * 1024;
const MAX_IDENTIFIER_BYTES: usize = 512;

pub(crate) struct PrivateJsonFile {
    path: PathBuf,
    lock_path: PathBuf,
    process_gate: Arc<Mutex<()>>,
}

pub(crate) struct PrivateJsonTransaction<'a> {
    store: &'a PrivateJsonFile,
    lock_file: File,
    exclusive: bool,
    _process_guard: MutexGuard<'a, ()>,
}

impl PrivateJsonFile {
    pub(crate) fn new(path: impl AsRef<Path>) -> Result<Self, CryptoError> {
        let path = absolute_path(path.as_ref())?;
        let parent = path
            .parent()
            .ok_or_else(|| integrity_error("missing parent directory"))?;
        ensure_private_directory(parent)?;

        let file_name = path
            .file_name()
            .ok_or_else(|| integrity_error("missing private store file name"))?;
        let mut lock_name = OsString::from(file_name);
        lock_name.push(".lock");
        let lock_path = path.with_file_name(lock_name);

        // Create and normalize the stable lock file before publishing the
        // store. Each transaction reopens it with O_NOFOLLOW.
        let lock_file = open_private_lock_file(&lock_path)?;
        drop(lock_file);

        let store = Self {
            process_gate: process_gate_for(&lock_path)?,
            path,
            lock_path,
        };

        // A process can be killed after the private temporary document is
        // fsynced but before it is renamed. Sweep only artifacts that exactly
        // match this store's own temporary-file contract, while holding the
        // same cross-process lock used by writers. Cleanup decisions use
        // metadata only; symlinks, non-regular files, widened permissions,
        // foreign owners, and hard links are deliberately left untouched.
        {
            let transaction = store.exclusive()?;
            transaction.remove_safe_stale_temporary_files()?;
        }

        Ok(store)
    }

    pub(crate) fn shared(&self) -> Result<PrivateJsonTransaction<'_>, CryptoError> {
        self.transaction(false)
    }

    pub(crate) fn exclusive(&self) -> Result<PrivateJsonTransaction<'_>, CryptoError> {
        self.transaction(true)
    }

    fn transaction(&self, exclusive: bool) -> Result<PrivateJsonTransaction<'_>, CryptoError> {
        let process_guard = self
            .process_gate
            .lock()
            .map_err(|_| integrity_error("private store process lock poisoned"))?;
        let lock_file = open_private_lock_file(&self.lock_path)?;
        acquire_file_lock(&lock_file, exclusive)?;
        Ok(PrivateJsonTransaction {
            store: self,
            lock_file,
            exclusive,
            _process_guard: process_guard,
        })
    }
}

impl PrivateJsonTransaction<'_> {
    fn remove_safe_stale_temporary_files(&self) -> Result<(), CryptoError> {
        if !self.exclusive {
            return Err(integrity_error(
                "private store cleanup requires an exclusive transaction",
            ));
        }
        let parent = self
            .store
            .path
            .parent()
            .ok_or_else(|| integrity_error("missing parent directory"))?;
        let mut removed_any = false;

        for entry in std::fs::read_dir(parent)? {
            let entry = entry?;
            if !is_temporary_name_for_store(&self.store.path, &entry.file_name())? {
                continue;
            }

            let candidate = entry.path();
            let metadata = match std::fs::symlink_metadata(&candidate) {
                Ok(metadata) => metadata,
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
                Err(error) => return Err(error.into()),
            };
            if !is_safe_stale_temporary_metadata(&metadata) {
                continue;
            }

            match std::fs::remove_file(&candidate) {
                Ok(()) => removed_any = true,
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                Err(error) => return Err(error.into()),
            }
        }

        if removed_any {
            let _ = sync_parent_directory(&self.store.path);
        }
        Ok(())
    }

    pub(crate) fn read_json<T: DeserializeOwned>(&self) -> Result<Option<T>, CryptoError> {
        let Some(file) = open_private_data_file(&self.store.path)? else {
            return Ok(None);
        };
        let mut bytes = Zeroizing::new(Vec::new());
        let mut limited = file.take(MAX_PRIVATE_DOCUMENT_BYTES + 1);
        limited.read_to_end(&mut bytes)?;
        if bytes.is_empty() {
            return Err(integrity_error("private store document is empty"));
        }
        if bytes.len() as u64 > MAX_PRIVATE_DOCUMENT_BYTES {
            return Err(integrity_error("private store document exceeds size limit"));
        }

        serde_json::from_slice(&bytes)
            .map(Some)
            .map_err(|_| integrity_error("private store document is malformed"))
    }

    pub(crate) fn write_json<T: Serialize>(&self, value: &T) -> Result<(), CryptoError> {
        if !self.exclusive {
            return Err(integrity_error(
                "private store write requires an exclusive transaction",
            ));
        }
        let bytes = Zeroizing::new(serde_json::to_vec_pretty(value).map_err(|_| {
            CryptoError::Serialization {
                message: "private store serialization failed".to_string(),
            }
        })?);
        if bytes.len() as u64 > MAX_PRIVATE_DOCUMENT_BYTES {
            return Err(integrity_error("private store document exceeds size limit"));
        }

        reject_unsafe_existing_path(&self.store.path)?;
        let temp_path = temporary_path(&self.store.path)?;
        let result = (|| {
            let mut temp_file = create_private_temp_file(&temp_path)?;
            temp_file.write_all(&bytes)?;
            temp_file.sync_all()?;

            // Recheck immediately before rename so a symlink or non-regular
            // destination is never knowingly replaced.
            reject_unsafe_existing_path(&self.store.path)?;
            commit_private_temp_file(&temp_path, &self.store.path)?;
            Ok(())
        })();

        if result.is_err() {
            let _ = std::fs::remove_file(&temp_path);
        }
        result
    }
}

impl Drop for PrivateJsonTransaction<'_> {
    fn drop(&mut self) {
        release_file_lock(&self.lock_file);
    }
}

pub(crate) fn validate_identifier(identifier: &str, kind: &'static str) -> Result<(), CryptoError> {
    let valid = !identifier.is_empty()
        && identifier.len() <= MAX_IDENTIFIER_BYTES
        && !identifier.contains("..")
        && identifier.bytes().all(|byte| {
            byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-' | b':' | b'@' | b'+')
        });
    if valid {
        Ok(())
    } else {
        Err(CryptoError::InvalidIdentifier { kind })
    }
}

fn absolute_path(path: &Path) -> Result<PathBuf, CryptoError> {
    if path.is_absolute() {
        Ok(path.to_path_buf())
    } else {
        Ok(std::env::current_dir()?.join(path))
    }
}

fn process_gate_for(path: &Path) -> Result<Arc<Mutex<()>>, CryptoError> {
    static PROCESS_GATES: OnceLock<Mutex<HashMap<PathBuf, Weak<Mutex<()>>>>> = OnceLock::new();
    let mut gates = PROCESS_GATES
        .get_or_init(|| Mutex::new(HashMap::new()))
        .lock()
        .map_err(|_| integrity_error("private store lock registry poisoned"))?;
    gates.retain(|_, gate| gate.strong_count() > 0);
    if let Some(gate) = gates.get(path).and_then(Weak::upgrade) {
        return Ok(gate);
    }
    let gate = Arc::new(Mutex::new(()));
    gates.insert(path.to_path_buf(), Arc::downgrade(&gate));
    Ok(gate)
}

fn ensure_private_directory(path: &Path) -> Result<(), CryptoError> {
    std::fs::create_dir_all(path)?;
    let metadata = std::fs::symlink_metadata(path)?;
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        return Err(integrity_error("private store parent is not a directory"));
    }
    ensure_current_user_owns(&metadata)?;

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700))?;
    }
    Ok(())
}

fn temporary_path(path: &Path) -> Result<PathBuf, CryptoError> {
    let file_name = path
        .file_name()
        .ok_or_else(|| integrity_error("missing private store file name"))?;
    let mut temp_name = OsString::from(".");
    temp_name.push(file_name);
    temp_name.push(format!(".tmp-{}-{}", std::process::id(), Uuid::new_v4()));
    Ok(path.with_file_name(temp_name))
}

fn is_temporary_name_for_store(
    path: &Path,
    candidate_name: &std::ffi::OsStr,
) -> Result<bool, CryptoError> {
    let file_name = path
        .file_name()
        .ok_or_else(|| integrity_error("missing private store file name"))?;
    let Some(file_name) = file_name.to_str() else {
        return Ok(false);
    };
    let Some(candidate_name) = candidate_name.to_str() else {
        return Ok(false);
    };
    let prefix = format!(".{file_name}.tmp-");
    let Some(suffix) = candidate_name.strip_prefix(&prefix) else {
        return Ok(false);
    };
    let Some((process_id, uuid)) = suffix.split_once('-') else {
        return Ok(false);
    };
    if process_id.is_empty()
        || !process_id.bytes().all(|byte| byte.is_ascii_digit())
        || process_id.parse::<u32>().is_err()
    {
        return Ok(false);
    }
    let Ok(parsed_uuid) = Uuid::parse_str(uuid) else {
        return Ok(false);
    };
    Ok(parsed_uuid.to_string() == uuid)
}

#[cfg(unix)]
fn is_safe_stale_temporary_metadata(metadata: &std::fs::Metadata) -> bool {
    use std::os::unix::fs::{MetadataExt, PermissionsExt};

    // SAFETY: geteuid takes no pointers and has no preconditions.
    let effective_user = unsafe { libc::geteuid() };
    metadata.is_file()
        && metadata.uid() == effective_user
        && metadata.nlink() == 1
        && metadata.permissions().mode() & 0o7777 == 0o600
}

#[cfg(not(unix))]
fn is_safe_stale_temporary_metadata(metadata: &std::fs::Metadata) -> bool {
    metadata.is_file()
}

fn reject_unsafe_existing_path(path: &Path) -> Result<(), CryptoError> {
    match std::fs::symlink_metadata(path) {
        Ok(metadata) => {
            if metadata.file_type().is_symlink() || !metadata.is_file() {
                return Err(integrity_error(
                    "private store target is not a regular file",
                ));
            }
            ensure_current_user_owns(&metadata)?;
            reject_hard_linked_file(&metadata)?;
            Ok(())
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error.into()),
    }
}

#[cfg(unix)]
fn open_private_lock_file(path: &Path) -> Result<File, CryptoError> {
    use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};

    reject_symlink_if_present(path)?;
    let file = OpenOptions::new()
        .create(true)
        .read(true)
        .write(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)?;
    ensure_regular_descriptor(&file)?;
    file.set_permissions(std::fs::Permissions::from_mode(0o600))?;
    Ok(file)
}

#[cfg(not(unix))]
fn open_private_lock_file(path: &Path) -> Result<File, CryptoError> {
    reject_symlink_if_present(path)?;
    let file = OpenOptions::new()
        .create(true)
        .read(true)
        .write(true)
        .open(path)?;
    ensure_regular_descriptor(&file)?;
    Ok(file)
}

#[cfg(unix)]
fn open_private_data_file(path: &Path) -> Result<Option<File>, CryptoError> {
    use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};

    let metadata = match std::fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error.into()),
    };
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return Err(integrity_error(
            "private store source is not a regular file",
        ));
    }
    reject_hard_linked_file(&metadata)?;

    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)?;
    ensure_regular_descriptor(&file)?;
    // Normalize existing regular files before reading them. Writes use a new
    // 0600 inode and atomic replacement.
    file.set_permissions(std::fs::Permissions::from_mode(0o600))?;
    Ok(Some(file))
}

#[cfg(not(unix))]
fn open_private_data_file(path: &Path) -> Result<Option<File>, CryptoError> {
    let metadata = match std::fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error.into()),
    };
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return Err(integrity_error(
            "private store source is not a regular file",
        ));
    }
    let file = OpenOptions::new().read(true).open(path)?;
    ensure_regular_descriptor(&file)?;
    Ok(Some(file))
}

#[cfg(unix)]
fn create_private_temp_file(path: &Path) -> Result<File, CryptoError> {
    use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};

    let file = OpenOptions::new()
        .create_new(true)
        .read(true)
        .write(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)?;
    ensure_regular_descriptor(&file)?;
    file.set_permissions(std::fs::Permissions::from_mode(0o600))?;
    Ok(file)
}

#[cfg(not(unix))]
fn create_private_temp_file(path: &Path) -> Result<File, CryptoError> {
    let file = OpenOptions::new()
        .create_new(true)
        .read(true)
        .write(true)
        .open(path)?;
    ensure_regular_descriptor(&file)?;
    Ok(file)
}

fn reject_symlink_if_present(path: &Path) -> Result<(), CryptoError> {
    match std::fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_symlink() => {
            Err(integrity_error("private store path is a symlink"))
        }
        Ok(metadata) if !metadata.is_file() => {
            Err(integrity_error("private store path is not a regular file"))
        }
        Ok(_) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error.into()),
    }
}

fn ensure_regular_descriptor(file: &File) -> Result<(), CryptoError> {
    let metadata = file.metadata()?;
    if !metadata.is_file() {
        return Err(integrity_error(
            "private store descriptor is not a regular file",
        ));
    }
    ensure_current_user_owns(&metadata)?;
    reject_hard_linked_file(&metadata)
}

#[cfg(unix)]
fn ensure_current_user_owns(metadata: &std::fs::Metadata) -> Result<(), CryptoError> {
    use std::os::unix::fs::MetadataExt;

    // SAFETY: geteuid takes no pointers and has no preconditions.
    let effective_user = unsafe { libc::geteuid() };
    if !owner_matches(metadata.uid(), effective_user) {
        return Err(integrity_error(
            "private store path is not owned by the current user",
        ));
    }
    Ok(())
}

#[cfg(unix)]
const fn owner_matches(actual_user: u32, effective_user: u32) -> bool {
    actual_user == effective_user
}

#[cfg(not(unix))]
fn ensure_current_user_owns(_metadata: &std::fs::Metadata) -> Result<(), CryptoError> {
    Ok(())
}

#[cfg(unix)]
fn reject_hard_linked_file(metadata: &std::fs::Metadata) -> Result<(), CryptoError> {
    use std::os::unix::fs::MetadataExt;
    if metadata.nlink() != 1 {
        return Err(integrity_error(
            "private store file has multiple hard links",
        ));
    }
    Ok(())
}

#[cfg(not(unix))]
fn reject_hard_linked_file(_metadata: &std::fs::Metadata) -> Result<(), CryptoError> {
    Ok(())
}

#[cfg(unix)]
fn acquire_file_lock(file: &File, exclusive: bool) -> Result<(), CryptoError> {
    use std::os::fd::AsRawFd;

    let operation = if exclusive {
        libc::LOCK_EX
    } else {
        libc::LOCK_SH
    };
    loop {
        // SAFETY: `file` owns a valid descriptor for the duration of this call.
        let result = unsafe { libc::flock(file.as_raw_fd(), operation) };
        if result == 0 {
            return Ok(());
        }
        let error = std::io::Error::last_os_error();
        if error.kind() != std::io::ErrorKind::Interrupted {
            return Err(error.into());
        }
    }
}

#[cfg(not(unix))]
fn acquire_file_lock(_file: &File, _exclusive: bool) -> Result<(), CryptoError> {
    Ok(())
}

#[cfg(unix)]
fn release_file_lock(file: &File) {
    use std::os::fd::AsRawFd;
    // SAFETY: `file` remains open until after this transaction is dropped.
    let _ = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_UN) };
}

#[cfg(not(unix))]
fn release_file_lock(_file: &File) {}

fn commit_private_temp_file(temp_path: &Path, destination: &Path) -> Result<(), CryptoError> {
    commit_private_temp_file_with_sync(temp_path, destination, sync_parent_directory)
}

fn commit_private_temp_file_with_sync<F>(
    temp_path: &Path,
    destination: &Path,
    sync_parent: F,
) -> Result<(), CryptoError>
where
    F: FnOnce(&Path) -> std::io::Result<()>,
{
    std::fs::rename(temp_path, destination)?;

    // rename is the commit point. The destination now names the already-
    // fsynced 0600 inode. Parent-directory fsync can improve sudden-power-loss
    // durability, but is explicitly best effort and cannot turn a committed
    // replacement into an error reported to the caller.
    let _ = sync_parent(destination);
    Ok(())
}

fn sync_parent_directory(path: &Path) -> std::io::Result<()> {
    let parent = path.parent().ok_or_else(|| {
        std::io::Error::new(std::io::ErrorKind::InvalidInput, "missing parent directory")
    })?;
    File::open(parent)?.sync_all()
}

fn integrity_error(message: &'static str) -> CryptoError {
    CryptoError::KeyStoreIntegrity {
        message: message.to_string(),
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::{commit_private_temp_file_with_sync, owner_matches};
    use tempfile::TempDir;

    #[test]
    fn owner_check_rejects_a_different_login() {
        assert!(owner_matches(501, 501));
        assert!(!owner_matches(502, 501));
    }

    #[test]
    fn rename_remains_committed_when_parent_sync_fails() {
        let tmp = TempDir::new().unwrap();
        let temp_path = tmp.path().join(".content-keys.json.tmp-fixture");
        let destination = tmp.path().join("content-keys.json");
        std::fs::write(&temp_path, b"committed fixture").unwrap();

        let result = commit_private_temp_file_with_sync(&temp_path, &destination, |_| {
            Err(std::io::Error::other("injected directory fsync failure"))
        });

        assert!(result.is_ok());
        assert_eq!(std::fs::read(&destination).unwrap(), b"committed fixture");
        assert!(!temp_path.exists());
    }
}
