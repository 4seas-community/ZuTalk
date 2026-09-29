//! What startup recovery already did, so a launch only does new work.
//!
//! Recovery runs inside the core constructor, and the app builds the core on
//! its main thread before the first window can draw. Recovery used to redo
//! everything on every launch — reconcile every recording's translation inbox,
//! re-index every recording's search text, re-index every interrupted
//! recording's audio — and the same handful of recordings failed the same way
//! each time. On a library of a hundred recordings that was nearly three
//! seconds of a frozen app, every launch, for no new result.
//!
//! Each entry maps a recording to a fingerprint of the inputs its recovery ran
//! against. A matching fingerprint means that recovery already ran, succeeded
//! or failed deterministically, on exactly these inputs, so it is skipped.
//!
//! This is a cache, not a record: losing the file costs one slow launch and
//! nothing else. That is also why it lives in a file rather than a schema
//! migration. A new core version discards it, because a new version may fix a
//! recovery that used to fail, and those recordings deserve another try.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

const FILE_NAME: &str = "startup-recovery.json";

/// The core version recovery results were produced by.
pub(crate) const CORE_VERSION: &str = env!("CARGO_PKG_VERSION");

#[derive(Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
pub(crate) struct StartupRecoveryCache {
    #[serde(default)]
    core_version: String,
    /// Session id → fingerprint of the rows its inbox reconcile ran against.
    #[serde(default)]
    pub(crate) translation_inbox: BTreeMap<String, String>,
    /// Session id → fingerprint of the rows its search index was built from.
    #[serde(default)]
    pub(crate) search_index: BTreeMap<String, String>,
    /// Interrupted run id → fingerprint of the audio its index was built from.
    #[serde(default)]
    pub(crate) capture_audio: BTreeMap<String, String>,
}

impl StartupRecoveryCache {
    /// Reads the cache, or starts empty when it is missing, unreadable, or
    /// written by another core version.
    pub(crate) fn load(data_dir: &Path) -> Self {
        let Ok(bytes) = std::fs::read(path(data_dir)) else {
            return Self::default();
        };
        match serde_json::from_slice::<Self>(&bytes) {
            Ok(cache) if cache.core_version == CORE_VERSION => cache,
            _ => Self::default(),
        }
    }

    /// Writes the cache atomically. A failure is logged and otherwise
    /// ignored: the only cost is redoing the work on the next launch.
    pub(crate) fn save(&mut self, data_dir: &Path) {
        self.core_version = CORE_VERSION.to_string();
        let target = path(data_dir);
        let temporary = target.with_extension("json.tmp");
        let result = serde_json::to_vec(self)
            .map_err(|error| error.to_string())
            .and_then(|bytes| std::fs::write(&temporary, bytes).map_err(|error| error.to_string()))
            .and_then(|()| std::fs::rename(&temporary, &target).map_err(|error| error.to_string()));
        if let Err(error) = result {
            tracing::warn!(%error, "startup recovery cache not saved; next launch redoes it");
        }
    }
}

fn path(data_dir: &Path) -> PathBuf {
    data_dir.join(FILE_NAME)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_saved_cache_reads_back() {
        let temp = tempfile::tempdir().unwrap();
        let mut cache = StartupRecoveryCache::default();
        cache
            .translation_inbox
            .insert("session-a".into(), "fingerprint".into());
        cache.save(temp.path());

        let loaded = StartupRecoveryCache::load(temp.path());
        assert_eq!(
            loaded
                .translation_inbox
                .get("session-a")
                .map(String::as_str),
            Some("fingerprint")
        );
    }

    /// A newer core may fix a recovery that used to fail; its recordings
    /// deserve another try rather than being skipped on an old verdict.
    #[test]
    fn another_core_version_starts_over() {
        let temp = tempfile::tempdir().unwrap();
        std::fs::write(
            temp.path().join(FILE_NAME),
            r#"{"core_version":"0.0.0-older","translation_inbox":{"session-a":"f"}}"#,
        )
        .unwrap();

        let loaded = StartupRecoveryCache::load(temp.path());
        assert!(loaded.translation_inbox.is_empty());
    }

    #[test]
    fn a_missing_or_corrupt_cache_is_empty_not_an_error() {
        let temp = tempfile::tempdir().unwrap();
        assert_eq!(
            StartupRecoveryCache::load(temp.path()),
            StartupRecoveryCache::default()
        );
        std::fs::write(temp.path().join(FILE_NAME), b"{not json").unwrap();
        assert_eq!(
            StartupRecoveryCache::load(temp.path()),
            StartupRecoveryCache::default()
        );
    }
}
