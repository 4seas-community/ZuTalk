//! 隐私自动销毁
//! 权威：D2 §5, PRD §0.1 #21

use std::path::Path;

use vt_model::PrivacyLevel;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AudioRetentionMode {
    KeepEncrypted,
    DeleteAfterTranscription,
    RollingChunks,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AudioRetentionPolicy {
    pub mode: AudioRetentionMode,
    pub chunk_ms: u64,
    pub max_retained_chunks: u32,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AudioRetentionPlan {
    pub delete_after_transcription: bool,
    pub chunk_ms: u64,
    pub expected_chunks: u32,
    pub max_retained_chunks: u32,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AudioRetentionChunkPlan {
    pub chunk_id: String,
    pub start_ms: u64,
    pub end_ms: u64,
    pub retention_deadline_ms: i64,
}

impl AudioRetentionPolicy {
    pub fn default_ephemeral_chunks() -> Self {
        Self {
            mode: AudioRetentionMode::RollingChunks,
            chunk_ms: 60_000,
            max_retained_chunks: 1,
        }
    }

    pub fn plan_for_session(&self, duration_ms: u64) -> AudioRetentionPlan {
        let chunk_ms = self.chunk_ms.max(1);
        let expected_chunks = duration_ms.div_ceil(chunk_ms).max(1) as u32;
        AudioRetentionPlan {
            delete_after_transcription: matches!(
                self.mode,
                AudioRetentionMode::DeleteAfterTranscription | AudioRetentionMode::RollingChunks
            ),
            chunk_ms,
            expected_chunks,
            max_retained_chunks: self.max_retained_chunks,
        }
    }

    pub fn chunk_plan_for_session(
        &self,
        session_id: &str,
        duration_ms: u64,
        session_start_ms: i64,
    ) -> Vec<AudioRetentionChunkPlan> {
        let plan = self.plan_for_session(duration_ms);
        let retain_from = plan
            .expected_chunks
            .saturating_sub(plan.max_retained_chunks)
            .min(plan.expected_chunks);
        (0..plan.expected_chunks)
            .map(|idx| {
                let start_ms = idx as u64 * plan.chunk_ms;
                let end_ms = (start_ms + plan.chunk_ms).min(duration_ms.max(1));
                let retention_deadline_ms =
                    if matches!(self.mode, AudioRetentionMode::KeepEncrypted) || idx >= retain_from
                    {
                        i64::MAX
                    } else {
                        session_start_ms.saturating_add(end_ms as i64)
                    };
                AudioRetentionChunkPlan {
                    chunk_id: format!("{session_id}:audio:{idx:05}"),
                    start_ms,
                    end_ms,
                    retention_deadline_ms,
                }
            })
            .collect()
    }
}

/// 隐私销毁器
pub struct PrivacyDestroyer;

/// 销毁结果
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DestroyResult {
    pub audio_destroyed: bool,
    pub key_destroyed: bool,
}

/// 销毁错误
#[derive(Debug, thiserror::Error)]
pub enum DestroyError {
    #[error("file destroy failed: {0}")]
    FileDestroyFailed(String),

    #[error("key destroy failed: {0}")]
    KeyDestroyFailed(String),
}

impl PrivacyDestroyer {
    /// 转录完成后根据隐私等级执行销毁
    pub fn on_transcription_completed(
        privacy_level: &PrivacyLevel,
        audio_path: &Path,
        key_id: &str,
        key_store: &mut dyn KeyDestroyer,
    ) -> Result<DestroyResult, DestroyError> {
        match privacy_level {
            PrivacyLevel::Maximum => {
                // 销毁音频 + 销毁密钥
                Self::destroy_file(audio_path)?;
                key_store.destroy_key(key_id)?;
                Ok(DestroyResult {
                    audio_destroyed: true,
                    key_destroyed: true,
                })
            }
            PrivacyLevel::High => {
                // 仅销毁音频，保留密钥（允许手动导出）
                Self::destroy_file(audio_path)?;
                Ok(DestroyResult {
                    audio_destroyed: true,
                    key_destroyed: false,
                })
            }
            PrivacyLevel::Standard => {
                // 不自动销毁
                Ok(DestroyResult {
                    audio_destroyed: false,
                    key_destroyed: false,
                })
            }
        }
    }

    /// 安全销毁文件：覆写零后删除。
    pub fn destroy_file(path: &Path) -> Result<(), DestroyError> {
        if !path.exists() {
            return Ok(()); // 幂等：已不存在
        }

        // 覆写零
        let len = std::fs::metadata(path)
            .map_err(|e| DestroyError::FileDestroyFailed(e.to_string()))?
            .len() as usize;

        let zeros = vec![0u8; len.min(64 * 1024)]; // 分块覆写
        let file = std::fs::OpenOptions::new()
            .write(true)
            .open(path)
            .map_err(|e| DestroyError::FileDestroyFailed(e.to_string()))?;

        use std::io::Write;
        let mut writer = std::io::BufWriter::new(file);
        let mut remaining = len;
        while remaining > 0 {
            let to_write = remaining.min(zeros.len());
            writer
                .write_all(&zeros[..to_write])
                .map_err(|e| DestroyError::FileDestroyFailed(e.to_string()))?;
            remaining -= to_write;
        }
        writer
            .flush()
            .map_err(|e| DestroyError::FileDestroyFailed(e.to_string()))?;
        drop(writer);

        // 删除文件
        std::fs::remove_file(path).map_err(|e| DestroyError::FileDestroyFailed(e.to_string()))?;

        Ok(())
    }
}

/// 密钥销毁接口
pub trait KeyDestroyer {
    fn destroy_key(&mut self, key_id: &str) -> Result<(), DestroyError>;
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;
    use tempfile::NamedTempFile;

    struct MockKeyStore {
        keys: HashMap<String, Vec<u8>>,
    }

    impl MockKeyStore {
        fn new() -> Self {
            Self {
                keys: HashMap::new(),
            }
        }

        fn add_key(&mut self, id: &str) {
            self.keys.insert(id.to_string(), vec![0xAB; 32]);
        }

        fn has_key(&self, id: &str) -> bool {
            self.keys.contains_key(id)
        }
    }

    impl KeyDestroyer for MockKeyStore {
        fn destroy_key(&mut self, key_id: &str) -> Result<(), DestroyError> {
            self.keys.remove(key_id);
            Ok(())
        }
    }

    #[test]
    fn test_maximum_privacy_destroys_all() {
        let tmp = NamedTempFile::new().unwrap();
        std::fs::write(tmp.path(), vec![0xABu8; 1024]).unwrap();

        let mut store = MockKeyStore::new();
        store.add_key("key-1");

        let result = PrivacyDestroyer::on_transcription_completed(
            &PrivacyLevel::Maximum,
            tmp.path(),
            "key-1",
            &mut store,
        )
        .unwrap();

        assert!(result.audio_destroyed);
        assert!(result.key_destroyed);
        assert!(!tmp.path().exists(), "file should be deleted");
        assert!(!store.has_key("key-1"), "key should be destroyed");
    }

    #[test]
    fn test_high_privacy_destroys_audio_only() {
        let tmp = NamedTempFile::new().unwrap();
        std::fs::write(tmp.path(), vec![0xABu8; 1024]).unwrap();

        let mut store = MockKeyStore::new();
        store.add_key("key-1");

        let result = PrivacyDestroyer::on_transcription_completed(
            &PrivacyLevel::High,
            tmp.path(),
            "key-1",
            &mut store,
        )
        .unwrap();

        assert!(result.audio_destroyed);
        assert!(!result.key_destroyed);
        assert!(!tmp.path().exists());
        assert!(store.has_key("key-1"), "key should be preserved");
    }

    #[test]
    fn test_standard_no_auto_destroy() {
        let tmp = NamedTempFile::new().unwrap();
        std::fs::write(tmp.path(), vec![0xABu8; 1024]).unwrap();

        let mut store = MockKeyStore::new();
        store.add_key("key-1");

        let result = PrivacyDestroyer::on_transcription_completed(
            &PrivacyLevel::Standard,
            tmp.path(),
            "key-1",
            &mut store,
        )
        .unwrap();

        assert!(!result.audio_destroyed);
        assert!(!result.key_destroyed);
        assert!(tmp.path().exists(), "file should not be deleted");
    }

    #[test]
    fn test_destroy_idempotent() {
        let tmp = NamedTempFile::new().unwrap();
        let path = tmp.path().to_path_buf();
        std::fs::write(&path, vec![0xABu8; 512]).unwrap();

        let mut store = MockKeyStore::new();
        store.add_key("key-1");

        // First destroy
        PrivacyDestroyer::on_transcription_completed(
            &PrivacyLevel::Maximum,
            &path,
            "key-1",
            &mut store,
        )
        .unwrap();

        // Second destroy (file already gone) — should not error
        let result = PrivacyDestroyer::on_transcription_completed(
            &PrivacyLevel::Maximum,
            &path,
            "key-1",
            &mut store,
        );
        assert!(result.is_ok(), "idempotent destroy should succeed");
    }

    // 审计结论（docs/audit/tests/01-vt-pipeline.md #37）：
    // test_file_actually_deleted 删除——和 test_maximum_privacy_destroys_all 几乎重复，
    // 只是多加了一行 "assert path.exists() before"。已被 #33 完整覆盖。

    #[test]
    fn test_audio_retention_policy_defaults_to_unsynced_one_minute_delete_after_transcript() {
        let policy = AudioRetentionPolicy::default_ephemeral_chunks();
        let plan = policy.plan_for_session(125_000);

        assert!(plan.delete_after_transcription);
        assert_eq!(plan.chunk_ms, 60_000);
        assert_eq!(plan.expected_chunks, 3);
        assert_eq!(plan.max_retained_chunks, 1);
    }

    #[test]
    fn rolling_retention_plan_marks_old_minute_chunks_due() {
        let policy = AudioRetentionPolicy::default_ephemeral_chunks();

        let chunks = policy.chunk_plan_for_session("session-a", 185_000, 1_000);

        assert_eq!(chunks.len(), 4);
        assert_eq!(chunks[0].chunk_id, "session-a:audio:00000");
        assert_eq!((chunks[0].start_ms, chunks[0].end_ms), (0, 60_000));
        assert_eq!(chunks[0].retention_deadline_ms, 61_000);
        assert_eq!((chunks[2].start_ms, chunks[2].end_ms), (120_000, 180_000));
        assert_eq!(chunks[2].retention_deadline_ms, 181_000);
        assert_eq!((chunks[3].start_ms, chunks[3].end_ms), (180_000, 185_000));
        assert_eq!(chunks[3].retention_deadline_ms, i64::MAX);
    }
}
