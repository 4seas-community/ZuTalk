//! Notebook session audio import, playback, task status, and retention support.

use std::path::PathBuf;

use vt_audio::decode_file;
use vt_crypto::decrypt::{decrypt_range, DecryptRange};
use vt_pipeline::recording::{
    f32_samples_to_bytes, write_encrypted_audio_chunks, RecordingAudioChunk,
};
use vt_pipeline::{AudioRetentionMode, AudioRetentionPolicy};
use vt_store::{AudioChunkRetentionRecord, SessionRecord};

use crate::{CoreError, ZulangueCore};

/// 导入结果 (FFI DTO)
#[derive(uniffi::Record)]
pub struct ImportResultInfo {
    pub session_id: String,
    pub source_format: String,
    pub duration_ms: u64,
    pub sample_rate: u32,
    pub channels: u16,
}

pub(crate) struct ImportedAudioMaterialization {
    pub result: ImportResultInfo,
    pub audio_path: String,
    pub audio_key_ref: String,
    pub captured_frames: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ImportMetadataStep {
    AudioPath,
    AudioFormat,
    RetentionLedger,
    PrivacyLevel,
}

/// 任务信息 (FFI DTO)
#[derive(uniffi::Record, Debug)]
pub struct TaskInfoDto {
    pub id: String,
    pub payload_json: String,
    pub status: String,
    pub retry_count: i32,
    pub error_msg: Option<String>,
    pub lease_expires_at_ms: Option<i64>,
    pub last_heartbeat_at_ms: Option<i64>,
}

#[derive(Debug, Clone)]
pub struct AudioRetentionStatusInfo {
    pub delete_after_transcription: bool,
    pub audio_deleted: bool,
    pub chunk_ms: u64,
    pub expected_chunks: u32,
    pub max_retained_chunks: u32,
}

#[derive(Debug, Clone)]
pub struct AudioRetentionChunkInfo {
    pub session_id: String,
    pub chunk_id: String,
    pub start_ms: u64,
    pub end_ms: u64,
    pub local_path: String,
    pub encrypted: bool,
    pub deleted: bool,
    pub retention_deadline_ms: i64,
    pub delete_error: Option<String>,
    pub deleted_at_ms: Option<i64>,
}

#[derive(Debug, Clone)]
pub struct AudioRetentionRunInfo {
    pub scanned_count: u32,
    pub deleted_count: u32,
    pub failed_count: u32,
    pub failure_messages: Vec<String>,
}

#[derive(Debug, Clone)]
pub struct AudioRetentionWorkerStatusInfo {
    pub mode: String,
    pub due_count: u64,
    pub failed_count: u64,
    pub deleted_count: u64,
}

#[derive(Debug, Clone)]
pub struct TranscriptionSourceStatusInfo {
    pub state: String,
    pub message: Option<String>,
}

impl From<AudioChunkRetentionRecord> for AudioRetentionChunkInfo {
    fn from(record: AudioChunkRetentionRecord) -> Self {
        Self {
            session_id: record.session_id,
            chunk_id: record.chunk_id,
            start_ms: record.start_ms,
            end_ms: record.end_ms,
            local_path: record.local_path,
            encrypted: record.encrypted,
            deleted: record.deleted,
            retention_deadline_ms: record.retention_deadline_ms,
            delete_error: record.delete_error,
            deleted_at_ms: record.deleted_at_ms,
        }
    }
}

impl ZulangueCore {
    pub(crate) fn record_source_audio_retention_chunks_strict(
        &self,
        session_id: &str,
        chunks: &[RecordingAudioChunk],
    ) -> Result<(), CoreError> {
        for chunk in chunks {
            let record = AudioChunkRetentionRecord {
                session_id: session_id.to_string(),
                chunk_id: chunk.chunk_id.clone(),
                start_ms: chunk.start_ms,
                end_ms: chunk.end_ms.max(chunk.start_ms + 1),
                local_path: chunk.path.to_string_lossy().to_string(),
                encrypted: true,
                deleted: false,
                retention_deadline_ms: i64::MAX,
                delete_error: None,
                deleted_at_ms: None,
            };
            self.session_meta
                .upsert_audio_retention_chunk(&record)
                .map_err(|error| CoreError::InternalError {
                    message: format!(
                        "record source audio retention chunk {}: {error}",
                        chunk.chunk_id
                    ),
                })?;
        }
        Ok(())
    }

    fn mark_missing_audio_retention_chunks_deleted(&self, session_id: &str) {
        let now_ms = chrono::Utc::now().timestamp_millis();
        let Ok(chunks) = self.session_meta.list_audio_retention_chunks(session_id) else {
            return;
        };
        for chunk in chunks {
            if !chunk.deleted && !std::path::Path::new(&chunk.local_path).exists() {
                if let Err(e) = self.session_meta.mark_audio_retention_chunk_deleted(
                    &chunk.session_id,
                    &chunk.chunk_id,
                    now_ms,
                ) {
                    tracing::warn!(
                        session_id,
                        chunk_id = %chunk.chunk_id,
                        error = %e,
                        "mark missing audio retention chunk deleted failed"
                    );
                }
            }
        }
    }
}

impl ZulangueCore {
    /// Notebook 导入路径使用的 crate-private 音频物化 helper。
    ///
    /// 该函数会创建 session，因此不能直接暴露给 Swift；公开入口必须先
    /// 明确 Notebook 所有权，再由 `import_audio_into_notebook` 完成绑定。
    pub(crate) fn import_audio(
        &self,
        path: String,
    ) -> Result<ImportedAudioMaterialization, CoreError> {
        self.import_audio_with_metadata_guard(path, |_| Ok(()))
    }

    fn import_audio_with_metadata_guard<F>(
        &self,
        path: String,
        mut before_metadata_step: F,
    ) -> Result<ImportedAudioMaterialization, CoreError>
    where
        F: FnMut(ImportMetadataStep) -> Result<(), CoreError>,
    {
        let source = PathBuf::from(&path);
        if !source.exists() {
            return Err(CoreError::NotFound {
                message: format!("file not found: {path}"),
            });
        }

        let decoded = decode_file(&source).map_err(|e| CoreError::InternalError {
            message: e.to_string(),
        })?;

        let total_samples = decoded.samples.len() / decoded.channels as usize;
        let captured_frames = total_samples as u64;
        let duration_ms = if decoded.sample_rate > 0 {
            (total_samples as u64 * 1000) / decoded.sample_rate as u64
        } else {
            0
        };

        let ext = source
            .extension()
            .and_then(|e| e.to_str())
            .unwrap_or("unknown")
            .to_string();

        // 创建 session 记录，并使用文件名 stem 作为 title。
        let session_id = uuid::Uuid::new_v4().to_string();
        let title = source
            .file_stem()
            .and_then(|s| s.to_str())
            .filter(|s| !s.is_empty())
            .unwrap_or("Imported Audio")
            .to_string();

        let record = SessionRecord {
            id: session_id.clone(),
            title: title.clone(),
            session_type: "import".to_string(),
            status: "imported".to_string(),
            duration_ms,
            created_at: chrono::Utc::now().format("%Y-%m-%d %H:%M:%S").to_string(),
            deleted_at: None,
        };

        self.session_store
            .insert_session(&record)
            .map_err(|e| CoreError::InternalError {
                message: e.to_string(),
            })?;

        let materialized = (|| -> Result<ImportedAudioMaterialization, CoreError> {
            // 加密音频 PCM 并存储
            let pcm_bytes = f32_samples_to_bytes(&decoded.samples);
            let sid_uuid =
                uuid::Uuid::parse_str(&session_id).unwrap_or_else(|_| uuid::Uuid::new_v4());
            let key_ref = self.key_store.create_session_key(&sid_uuid).map_err(|e| {
                CoreError::InternalError {
                    message: format!("key creation: {e}"),
                }
            })?;
            // Publish both the key reference and the canonical first-chunk path
            // before any later fallible operation. An empty placeholder path
            // would make permanent-delete attempt to remove the data directory;
            // the canonical path remains safe and discoverable even when audio
            // materialization fails before the retention ledger is written.
            let prospective_audio_path = self
                .data_dir
                .join(format!("{session_id}.chunk.00000.enc"))
                .to_string_lossy()
                .into_owned();
            self.session_meta
                .set_encrypted_path(&session_id, &prospective_audio_path, &key_ref)
                .map_err(|e| CoreError::InternalError {
                    message: format!("record import key reference: {e}"),
                })?;

            let key = self
                .key_store
                .load_key(&key_ref)
                .map_err(|e| CoreError::InternalError {
                    message: format!("key load: {e}"),
                })?;
            let audio_chunks = write_encrypted_audio_chunks(
                &self.data_dir,
                &session_id,
                &key,
                &pcm_bytes,
                decoded.sample_rate,
                decoded.channels,
            )
            .map_err(|e| CoreError::InternalError {
                message: format!("write audio chunks: {e}"),
            })?;

            // 存储元数据
            let encrypted_path = audio_chunks
                .first()
                .map(|chunk| chunk.path.to_string_lossy().to_string())
                .unwrap_or_default();
            before_metadata_step(ImportMetadataStep::AudioPath)?;
            self.session_meta
                .set_encrypted_path(&session_id, &encrypted_path, &key_ref)
                .map_err(|error| CoreError::InternalError {
                    message: format!("record authoritative import audio path: {error}"),
                })?;

            // 记录真实 sample_rate 和 channels，确保导出能重建可播放的 WAV。
            before_metadata_step(ImportMetadataStep::AudioFormat)?;
            self.session_meta
                .set_audio_format(&session_id, decoded.sample_rate, decoded.channels)
                .map_err(|error| CoreError::InternalError {
                    message: format!("record authoritative import audio format: {error}"),
                })?;
            before_metadata_step(ImportMetadataStep::RetentionLedger)?;
            self.record_source_audio_retention_chunks_strict(&session_id, &audio_chunks)?;

            // 把当前默认隐私等级写入该 session。
            let level = self.get_privacy_default();
            before_metadata_step(ImportMetadataStep::PrivacyLevel)?;
            self.session_meta
                .set_privacy_level(&session_id, &level)
                .map_err(|error| CoreError::InternalError {
                    message: format!("record authoritative import privacy level: {error}"),
                })?;

            // FTS is a disposable projection. Import success is owned by the
            // encrypted audio and its authoritative metadata above; search can
            // be rebuilt later and must not trigger destructive rollback.
            if let Err(error) = self.search_store.index_session(&session_id, &title) {
                tracing::warn!(session_id, %error, "import completed; FTS projection failed");
            }

            tracing::info!("Imported audio: {session_id} from {path}");

            Ok(ImportedAudioMaterialization {
                result: ImportResultInfo {
                    session_id: session_id.clone(),
                    source_format: ext,
                    duration_ms,
                    sample_rate: decoded.sample_rate,
                    channels: decoded.channels,
                },
                audio_path: encrypted_path,
                audio_key_ref: key_ref,
                captured_frames,
            })
        })();

        match materialized {
            Ok(imported) => Ok(imported),
            Err(error) => {
                let rollback = self.purge_session_forever(&session_id);
                if let Err(rollback_error) = rollback {
                    return Err(CoreError::InternalError {
                        message: format!(
                            "import audio failed ({error}); permanent rollback failed ({rollback_error})"
                        ),
                    });
                }
                Err(error)
            }
        }
    }
}

#[uniffi::export]
impl ZulangueCore {
    /// 列出任务（从 TaskQueue SQLite 查询）
    pub fn list_tasks(&self, status_filter: Option<String>) -> Result<Vec<TaskInfoDto>, CoreError> {
        let tasks = self
            .runtime
            .block_on(self.task_queue.list_tasks(status_filter.as_deref()))
            .map_err(|e| CoreError::InternalError {
                message: e.to_string(),
            })?;

        Ok(tasks
            .into_iter()
            .map(|t| TaskInfoDto {
                id: t.id,
                payload_json: t.payload_json,
                status: t.status,
                retry_count: t.retry_count,
                error_msg: t.error_msg,
                lease_expires_at_ms: t.lease_expires_at_ms,
                last_heartbeat_at_ms: t.last_heartbeat_at_ms,
            })
            .collect())
    }

    /// 获取任务状态（从 TaskQueue SQLite 查询）
    pub fn get_task_status(&self, task_id: String) -> Result<TaskInfoDto, CoreError> {
        let task = self
            .runtime
            .block_on(self.task_queue.get_task(&task_id))
            .map_err(|e| CoreError::NotFound {
                message: e.to_string(),
            })?;

        Ok(TaskInfoDto {
            id: task.id,
            payload_json: task.payload_json,
            status: task.status,
            retry_count: task.retry_count,
            error_msg: task.error_msg,
            lease_expires_at_ms: task.lease_expires_at_ms,
            last_heartbeat_at_ms: task.last_heartbeat_at_ms,
        })
    }

    /// 获取音频片段（解密指定时间范围的 PCM）
    pub fn get_audio_segment(
        &self,
        session_id: String,
        start_ms: u64,
        end_ms: u64,
    ) -> Result<Vec<u8>, CoreError> {
        if end_ms <= start_ms {
            return Err(CoreError::ValidationFailed {
                message: "end_ms must be greater than start_ms".to_string(),
            });
        }

        // 从 meta 获取加密文件路径和 key_id
        let meta = self
            .session_meta
            .get_meta(&session_id)
            .map_err(|_| CoreError::NotFound {
                message: format!("session audio not found: {session_id}"),
            })?;

        let enc_path = match &meta.encrypted_path {
            Some(p) if !p.is_empty() => p.clone(),
            _ => {
                return Err(CoreError::NotFound {
                    message: format!("session audio not found: {session_id}"),
                })
            }
        };

        let key_id = match &meta.key_id {
            Some(k) if !k.is_empty() => k.clone(),
            _ => {
                return Err(CoreError::NotFound {
                    message: format!("session audio key not found: {session_id}"),
                })
            }
        };

        // 从 key store 加载密钥
        let key = self
            .key_store
            .load_key(&key_id)
            .map_err(|e| CoreError::InternalError {
                message: format!("key load: {e}"),
            })?;
        let sample_rate = meta.sample_rate.unwrap_or(16000);
        let channels = meta.channels.unwrap_or(1);

        let mut chunks = self
            .session_meta
            .list_audio_retention_chunks(&session_id)
            .unwrap_or_default()
            .into_iter()
            .filter(|chunk| chunk.encrypted && !chunk.deleted)
            .collect::<Vec<_>>();
        chunks.sort_by_key(|chunk| (chunk.start_ms, chunk.chunk_id.clone()));
        if !chunks.is_empty() {
            let bytes_per_frame = channels.max(1) as usize * 4;
            let mut out = Vec::new();
            for chunk in chunks {
                if chunk.end_ms <= start_ms || chunk.start_ms >= end_ms {
                    continue;
                }
                let path = std::path::PathBuf::from(&chunk.local_path);
                if !path.exists() {
                    continue;
                }
                let mut reader = vt_crypto::DecryptReader::new(&path, &key).map_err(|e| {
                    CoreError::InternalError {
                        message: format!("decrypt chunk: {e}"),
                    }
                })?;
                let mut decrypted = Vec::new();
                use std::io::Read;
                reader
                    .read_to_end(&mut decrypted)
                    .map_err(|e| CoreError::InternalError {
                        message: format!("read chunk: {e}"),
                    })?;
                let local_start_ms = start_ms.saturating_sub(chunk.start_ms);
                let local_end_ms = end_ms.min(chunk.end_ms).saturating_sub(chunk.start_ms);
                let start_frame = (local_start_ms as usize * sample_rate as usize) / 1000;
                let end_frame = (local_end_ms as usize * sample_rate as usize) / 1000;
                let byte_start = (start_frame * bytes_per_frame).min(decrypted.len());
                let byte_end = (end_frame * bytes_per_frame).min(decrypted.len());
                if byte_end > byte_start {
                    out.extend_from_slice(&decrypted[byte_start..byte_end]);
                }
            }
            if !out.is_empty() {
                return Ok(out);
            }
        }

        // 解密指定时间范围
        let range = DecryptRange {
            start_ms,
            end_ms,
            sample_rate,
            channels,
            bytes_per_sample: 4, // f32
        };

        decrypt_range(&enc_path, &key, &range).map_err(|e| CoreError::InternalError {
            message: format!("decrypt: {e}"),
        })
    }
}

impl ZulangueCore {
    pub fn apply_audio_retention_policy(
        &self,
        session_id: String,
        policy: String,
        duration_ms: u64,
    ) -> Result<AudioRetentionStatusInfo, CoreError> {
        let retention = match policy.as_str() {
            "keep_encrypted" => AudioRetentionPolicy {
                mode: AudioRetentionMode::KeepEncrypted,
                chunk_ms: 60_000,
                max_retained_chunks: u32::MAX,
            },
            "delete_after_transcript" | "rolling_chunks" => {
                AudioRetentionPolicy::default_ephemeral_chunks()
            }
            _ => {
                return Err(CoreError::ValidationFailed {
                    message: format!("invalid audio retention policy: {policy}"),
                });
            }
        };
        let plan = retention.plan_for_session(duration_ms);
        let should_delete_audio = matches!(
            retention.mode,
            AudioRetentionMode::DeleteAfterTranscription | AudioRetentionMode::RollingChunks
        );
        if should_delete_audio {
            self.enforce_destroy(&session_id, false)?;
            self.mark_missing_audio_retention_chunks_deleted(&session_id);
        } else {
            self.session_meta
                .get_meta(&session_id)
                .map_err(|_| CoreError::NotFound {
                    message: format!("session not found: {session_id}"),
                })?;
        }
        Ok(AudioRetentionStatusInfo {
            delete_after_transcription: plan.delete_after_transcription,
            audio_deleted: should_delete_audio,
            chunk_ms: plan.chunk_ms,
            expected_chunks: plan.expected_chunks,
            max_retained_chunks: plan.max_retained_chunks,
        })
    }

    #[allow(clippy::too_many_arguments)]
    pub fn record_audio_retention_chunk(
        &self,
        session_id: String,
        chunk_id: String,
        start_ms: u64,
        end_ms: u64,
        local_path: String,
        encrypted: bool,
        retention_deadline_ms: i64,
    ) -> Result<(), CoreError> {
        if chunk_id.trim().is_empty() {
            return Err(CoreError::ValidationFailed {
                message: "chunk_id must not be empty".to_string(),
            });
        }
        if local_path.trim().is_empty() {
            return Err(CoreError::ValidationFailed {
                message: "local_path must not be empty".to_string(),
            });
        }
        if end_ms <= start_ms {
            return Err(CoreError::ValidationFailed {
                message: "end_ms must be greater than start_ms".to_string(),
            });
        }
        self.session_meta
            .upsert_audio_retention_chunk(&AudioChunkRetentionRecord {
                session_id,
                chunk_id,
                start_ms,
                end_ms,
                local_path,
                encrypted,
                deleted: false,
                retention_deadline_ms,
                delete_error: None,
                deleted_at_ms: None,
            })
            .map_err(|e| CoreError::InternalError {
                message: format!("record audio retention chunk: {e}"),
            })
    }

    pub fn list_audio_retention_chunks(
        &self,
        session_id: String,
    ) -> Result<Vec<AudioRetentionChunkInfo>, CoreError> {
        self.session_meta
            .list_audio_retention_chunks(&session_id)
            .map(|chunks| chunks.into_iter().map(Into::into).collect())
            .map_err(|e| CoreError::InternalError {
                message: format!("list audio retention chunks: {e}"),
            })
    }

    pub fn run_audio_retention_once(
        &self,
        now_ms: i64,
    ) -> Result<AudioRetentionRunInfo, CoreError> {
        let due = self
            .session_meta
            .list_due_audio_retention_chunks(now_ms)
            .map_err(|e| CoreError::InternalError {
                message: format!("list due audio retention chunks: {e}"),
            })?;
        let mut deleted_count = 0_u32;
        let mut failed_count = 0_u32;
        let mut failure_messages = Vec::new();
        let mut changed_sessions = std::collections::HashSet::new();

        for chunk in &due {
            let path = std::path::PathBuf::from(&chunk.local_path);
            match vt_pipeline::privacy::PrivacyDestroyer::destroy_file(&path) {
                Ok(()) => {
                    self.session_meta
                        .mark_audio_retention_chunk_deleted(
                            &chunk.session_id,
                            &chunk.chunk_id,
                            now_ms,
                        )
                        .map_err(|e| CoreError::InternalError {
                            message: format!("mark audio retention chunk deleted: {e}"),
                        })?;
                    changed_sessions.insert(chunk.session_id.clone());
                    deleted_count += 1;
                }
                Err(e) => {
                    let message = e.to_string();
                    self.session_meta
                        .mark_audio_retention_chunk_delete_failed(
                            &chunk.session_id,
                            &chunk.chunk_id,
                            &message,
                        )
                        .map_err(|e| CoreError::InternalError {
                            message: format!("mark audio retention chunk failed: {e}"),
                        })?;
                    failed_count += 1;
                    failure_messages.push(format!("{}: {message}", chunk.chunk_id));
                }
            }
        }

        for session_id in changed_sessions {
            let chunks = self
                .session_meta
                .list_audio_retention_chunks(&session_id)
                .map_err(|e| CoreError::InternalError {
                    message: format!("reload audio retention chunks: {e}"),
                })?;
            if !chunks.is_empty()
                && chunks.iter().all(|chunk| chunk.deleted)
                && chunks.iter().all(|chunk| chunk.delete_error.is_none())
            {
                let _ = self.session_meta.clear_encrypted_path(&session_id);
            }
        }

        Ok(AudioRetentionRunInfo {
            scanned_count: due.len() as u32,
            deleted_count,
            failed_count,
            failure_messages,
        })
    }

    pub fn get_audio_retention_worker_status(
        &self,
        now_ms: i64,
    ) -> Result<AudioRetentionWorkerStatusInfo, CoreError> {
        let counts = self
            .session_meta
            .get_audio_retention_counts(now_ms)
            .map_err(|e| CoreError::InternalError {
                message: format!("get audio retention counts: {e}"),
            })?;
        Ok(AudioRetentionWorkerStatusInfo {
            mode: "embedded".to_string(),
            due_count: counts.due_count,
            failed_count: counts.failed_count,
            deleted_count: counts.deleted_count,
        })
    }

    pub fn get_transcription_source_status(
        &self,
        session_id: String,
    ) -> Result<TranscriptionSourceStatusInfo, CoreError> {
        let chunks = self
            .session_meta
            .list_audio_retention_chunks(&session_id)
            .unwrap_or_default();
        if let Some(failed) = chunks.iter().find(|chunk| chunk.delete_error.is_some()) {
            return Ok(TranscriptionSourceStatusInfo {
                state: "delete_failed".to_string(),
                message: failed.delete_error.clone(),
            });
        }

        let meta = self
            .session_meta
            .get_meta(&session_id)
            .map_err(|_| CoreError::NotFound {
                message: format!("session not found: {session_id}"),
            })?;
        let tokens_present = self
            .session_meta
            .get_tokens(&session_id)
            .map(|tokens| !tokens.is_empty())
            .unwrap_or(false);

        if !chunks.is_empty() && chunks.iter().all(|chunk| chunk.deleted) {
            return Ok(TranscriptionSourceStatusInfo {
                state: if tokens_present {
                    "audio_deleted_after_transcript".to_string()
                } else {
                    "audio_deleted".to_string()
                },
                message: Some("all retained audio chunks have been deleted".to_string()),
            });
        }

        match meta.encrypted_path.as_deref() {
            Some(path) if !path.is_empty() && std::path::Path::new(path).exists() => {
                Ok(TranscriptionSourceStatusInfo {
                    state: "audio_retained".to_string(),
                    message: None,
                })
            }
            _ => Ok(TranscriptionSourceStatusInfo {
                state: if tokens_present {
                    "audio_deleted_after_transcript".to_string()
                } else {
                    "audio_deleted".to_string()
                },
                message: Some("session has no retained source audio".to_string()),
            }),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    #[test]
    fn test_import_audio_not_found() {
        let tmp = TempDir::new().unwrap();
        let core = ZulangueCore::new(tmp.path().to_str().unwrap().to_string()).unwrap();
        let notebook = core.create_notebook(Some("Import test".into())).unwrap();

        let result =
            core.import_audio_into_notebook("/nonexistent/file.mp3".to_string(), notebook.id);
        assert!(result.is_err());
    }

    #[test]
    fn test_import_audio_persists_session() {
        let tmp = TempDir::new().unwrap();
        let core = ZulangueCore::new(tmp.path().to_str().unwrap().to_string()).unwrap();

        let fixture = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../vt-audio/tests/fixtures/test_16k_mono.wav");

        if fixture.exists() {
            let notebook = core.create_notebook(Some("Import test".into())).unwrap();
            let result = core
                .import_audio_into_notebook(fixture.to_str().unwrap().to_string(), notebook.id)
                .unwrap();
            assert_eq!(result.source_format, "wav");
            assert_eq!(result.sample_rate, 16000);

            // Session should be queryable
            let sessions = core
                .query_sessions(Some("import".to_string()), None, None, None, None)
                .unwrap();
            assert_eq!(sessions.total_count, 1);
            assert_eq!(sessions.sessions[0].id, result.session_id);

            // Should be searchable by filename
            let search = core
                .search_sessions("test_16k_mono".to_string(), 10)
                .unwrap();
            assert_eq!(search.len(), 1);
        }
    }

    #[test]
    fn authoritative_import_metadata_failures_roll_back_audio_key_and_catalogue() {
        let fixture = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../vt-audio/tests/fixtures/test_16k_mono.wav");
        assert!(fixture.exists(), "checked-in import fixture is required");

        for failing_step in [
            ImportMetadataStep::AudioPath,
            ImportMetadataStep::AudioFormat,
            ImportMetadataStep::RetentionLedger,
            ImportMetadataStep::PrivacyLevel,
        ] {
            let tmp = TempDir::new().unwrap();
            let core = ZulangueCore::new(tmp.path().to_str().unwrap().to_string()).unwrap();
            let mut created_session_id = None;
            let result = core.import_audio_with_metadata_guard(
                fixture.to_string_lossy().into_owned(),
                |step| {
                    if step != failing_step {
                        return Ok(());
                    }
                    let sessions = core.query_sessions(None, None, None, None, None).unwrap();
                    created_session_id =
                        sessions.sessions.first().map(|session| session.id.clone());
                    Err(CoreError::InternalError {
                        message: format!("injected authoritative metadata failure: {step:?}"),
                    })
                },
            );

            assert!(result.is_err(), "{failing_step:?} must abort the import");
            let session_id = created_session_id.expect("session existed before injected failure");
            assert_eq!(
                core.query_sessions(None, None, None, None, None)
                    .unwrap()
                    .total_count,
                0,
                "{failing_step:?} left a catalogue row"
            );
            assert!(core.session_meta.get_meta(&session_id).is_err());
            assert!(!core.key_exists_for_test(&format!("zulangue.audio.{session_id}")));
            let encrypted_files = std::fs::read_dir(tmp.path())
                .unwrap()
                .filter_map(Result::ok)
                .filter(|entry| entry.path().extension().is_some_and(|ext| ext == "enc"))
                .count();
            assert_eq!(
                encrypted_files, 0,
                "{failing_step:?} left encrypted source audio behind"
            );
        }
    }

    #[test]
    fn test_list_tasks_via_task_queue() {
        let tmp = TempDir::new().unwrap();
        let core = ZulangueCore::new(tmp.path().to_str().unwrap().to_string()).unwrap();
        // These assertions cover the queue read model, not the background worker.
        // Stop the worker so its 200 ms polling loop cannot race the pending state.
        core.worker_cancel.cancel();

        // Initially empty
        let tasks = core.list_tasks(None).unwrap();
        assert!(tasks.is_empty());

        // Enqueue a task via runtime
        use vt_pipeline::TaskPayload;
        core.runtime
            .block_on(core.task_queue.enqueue(TaskPayload::Transcribe {
                session_id: "s1".to_string(),
                language_hint: None,
                remote_authorization: Some(
                    vt_pipeline::RemoteTaskAuthorization::soniox_post_recording_at(1),
                ),
            }))
            .unwrap();

        // Now list should have one
        let tasks = core.list_tasks(None).unwrap();
        assert_eq!(tasks.len(), 1);
        assert_eq!(tasks[0].status, "pending");
        assert!(tasks[0].lease_expires_at_ms.is_none());
        assert!(tasks[0].last_heartbeat_at_ms.is_none());
    }

    #[test]
    fn test_get_task_status_found() {
        let tmp = TempDir::new().unwrap();
        let core = ZulangueCore::new(tmp.path().to_str().unwrap().to_string()).unwrap();
        // Keep this test focused on lookup semantics instead of racing the worker.
        core.worker_cancel.cancel();

        use vt_pipeline::TaskPayload;
        let task_id = core
            .runtime
            .block_on(core.task_queue.enqueue(TaskPayload::Transcribe {
                session_id: "s1".to_string(),
                language_hint: None,
                remote_authorization: Some(
                    vt_pipeline::RemoteTaskAuthorization::soniox_post_recording_at(1),
                ),
            }))
            .unwrap();

        let info = core.get_task_status(task_id.clone()).unwrap();
        assert_eq!(info.id, task_id);
        assert_eq!(info.status, "pending");
    }

    #[test]
    fn test_get_task_status_exposes_claimed_lease_metadata() {
        let tmp = TempDir::new().unwrap();
        let core = ZulangueCore::new(tmp.path().to_str().unwrap().to_string()).unwrap();

        use vt_pipeline::TaskPayload;
        let task_id = core
            .runtime
            .block_on(core.task_queue.enqueue(TaskPayload::Transcribe {
                session_id: "s-lease".to_string(),
                language_hint: None,
                remote_authorization: Some(
                    vt_pipeline::RemoteTaskAuthorization::soniox_post_recording_at(1),
                ),
            }))
            .unwrap();

        core.runtime
            .block_on(core.task_queue.claim_next(5))
            .unwrap()
            .unwrap();

        let info = core.get_task_status(task_id.clone()).unwrap();
        assert_eq!(info.id, task_id);
        assert_eq!(info.status, "running");
        assert!(info.lease_expires_at_ms.is_some());
        assert!(info.last_heartbeat_at_ms.is_some());
    }

    #[test]
    fn test_get_task_status_not_found() {
        let tmp = TempDir::new().unwrap();
        let core = ZulangueCore::new(tmp.path().to_str().unwrap().to_string()).unwrap();
        let result = core.get_task_status("nonexistent".to_string());
        assert!(result.is_err());
    }

    #[test]
    fn test_get_audio_segment_validation() {
        let tmp = TempDir::new().unwrap();
        let core = ZulangueCore::new(tmp.path().to_str().unwrap().to_string()).unwrap();

        // Invalid range
        let result = core.get_audio_segment("s1".to_string(), 2000, 1000);
        assert!(result.is_err());

        // Missing source audio must fail closed rather than fabricate silence.
        assert!(core
            .get_audio_segment("s1".to_string(), 1000, 2000)
            .is_err());
    }

    #[test]
    fn test_get_audio_segment_reads_across_physical_chunks() {
        let tmp = TempDir::new().unwrap();
        let core = ZulangueCore::new(tmp.path().to_str().unwrap().to_string()).unwrap();
        let key = vt_crypto::SessionKey::generate();
        core.key_store.store_key("chunk-key", &key).unwrap();
        core.session_meta
            .set_encrypted_path("chunked-session", "compat-first-chunk", "chunk-key")
            .unwrap();
        core.session_meta
            .set_audio_format("chunked-session", 1000, 1)
            .unwrap();

        let chunk0 = tmp.path().join("chunked-session.chunk.00000.enc");
        let chunk1 = tmp.path().join("chunked-session.chunk.00001.enc");
        let first_second = f32_samples_to_bytes(&vec![1.0_f32; 1000]);
        let second_second = f32_samples_to_bytes(&vec![2.0_f32; 1000]);
        vt_crypto::encrypt_to_file(&chunk0, &key, &first_second).unwrap();
        vt_crypto::encrypt_to_file(&chunk1, &key, &second_second).unwrap();
        core.record_audio_retention_chunk(
            "chunked-session".into(),
            "chunked-session:audio:00000".into(),
            0,
            1000,
            chunk0.to_string_lossy().to_string(),
            true,
            i64::MAX,
        )
        .unwrap();
        core.record_audio_retention_chunk(
            "chunked-session".into(),
            "chunked-session:audio:00001".into(),
            1000,
            2000,
            chunk1.to_string_lossy().to_string(),
            true,
            i64::MAX,
        )
        .unwrap();

        let segment = core
            .get_audio_segment("chunked-session".into(), 500, 1500)
            .unwrap();
        let samples = vt_pipeline::recording::bytes_to_f32_samples(&segment);
        assert_eq!(samples.len(), 1000);
        assert_eq!(samples[0], 1.0);
        assert_eq!(samples[499], 1.0);
        assert_eq!(samples[500], 2.0);
        assert_eq!(samples[999], 2.0);
    }

    #[test]
    fn test_audio_retention_policy_deletes_audio_but_keeps_transcript() {
        use vt_model::{Token, TranslationStatus};
        let tmp = TempDir::new().unwrap();
        let core = ZulangueCore::new(tmp.path().to_str().unwrap().to_string()).unwrap();
        let audio_path = tmp.path().join("session.enc");
        std::fs::write(&audio_path, vec![1_u8; 64]).unwrap();
        core.session_meta
            .set_encrypted_path("s-retain", audio_path.to_str().unwrap(), "key-retain")
            .unwrap();
        core.record_audio_retention_chunk(
            "s-retain".to_string(),
            "s-retain:audio:00000".to_string(),
            0,
            125_000,
            audio_path.to_string_lossy().to_string(),
            true,
            i64::MAX,
        )
        .unwrap();
        core.session_meta
            .set_tokens(
                "s-retain",
                &[Token {
                    text: "keep transcript".to_string(),
                    start_ms: 0,
                    end_ms: 1000,
                    is_final: true,
                    language: "en".to_string(),
                    speaker: None,
                    confidence: 1.0,
                    translation_status: TranslationStatus::None,
                }],
            )
            .unwrap();

        let status = core
            .apply_audio_retention_policy(
                "s-retain".to_string(),
                "delete_after_transcript".to_string(),
                125_000,
            )
            .unwrap();

        assert!(status.audio_deleted);
        assert!(status.delete_after_transcription);
        assert_eq!(status.chunk_ms, 60_000);
        assert_eq!(status.expected_chunks, 3);
        assert!(!audio_path.exists());
        assert!(core
            .session_meta
            .get_meta("s-retain")
            .unwrap()
            .encrypted_path
            .is_none());
        let tokens = core.session_meta.get_tokens("s-retain").unwrap();
        assert_eq!(tokens.len(), 1);
        assert_eq!(tokens[0].text, "keep transcript");
    }

    #[test]
    fn test_import_then_get_audio_segment_roundtrip() {
        let tmp = TempDir::new().unwrap();
        let core = ZulangueCore::new(tmp.path().to_str().unwrap().to_string()).unwrap();

        let fixture = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../vt-audio/tests/fixtures/test_16k_mono.wav");

        if !fixture.exists() {
            return; // skip if no fixture
        }

        // Import encrypts audio and stores key
        let notebook = core.create_notebook(Some("Import test".into())).unwrap();
        let import_result = core
            .import_audio_into_notebook(fixture.to_str().unwrap().to_string(), notebook.id)
            .unwrap();

        // Get audio segment should decrypt real data (not silence)
        let segment = core
            .get_audio_segment(import_result.session_id.clone(), 0, 1000)
            .unwrap();

        // Should have actual data (not all zeros for 1 second of sine wave)
        assert!(!segment.is_empty());

        let chunks = core
            .list_audio_retention_chunks(import_result.session_id.clone())
            .unwrap();
        assert_eq!(chunks.len(), 1);
        assert!(PathBuf::from(&chunks[0].local_path).exists());
        assert!(chunks[0].local_path.ends_with(".chunk.00000.enc"));
        let legacy_path = tmp.path().join(format!("{}.enc", import_result.session_id));
        assert!(
            !legacy_path.exists(),
            "import should not create legacy full-session encrypted file"
        );
    }
}
