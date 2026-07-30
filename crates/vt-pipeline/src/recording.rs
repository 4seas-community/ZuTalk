//! Notebook capture 的本地加密音频日志与导入音频分块工具。
//!
//! 麦克风帧在回调线程上逐帧加密后追加到 crash-resilient journal；停止录音时
//! 再恢复为正式的加密音频块。该模块不拥有录音 session 生命周期，唯一的状态机
//! 位于 `vt-ffi::notebook_capture_api::ActiveNotebookCapture`。

use std::fs::{File, OpenOptions};
use std::io::{ErrorKind, Read, Write};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use vt_crypto::decrypt::encrypt_to_file;
use vt_crypto::SessionKey;
use vt_crypto::{decrypt_chunk, encrypt_chunk};

const CAPTURE_JOURNAL_MAGIC: &[u8; 8] = b"VTCAPJ1\0";
const CAPTURE_JOURNAL_SYNC_INTERVAL: u64 = 10;
const MAX_CAPTURE_FRAME_BYTES: usize = 8 * 1024 * 1024;

/// 录音配置
#[derive(Debug, Clone)]
pub struct RecordingConfig {
    pub data_dir: PathBuf,
    pub sample_rate: u32,
    pub channels: u16,
}

/// 录音结果
pub struct RecordingResult {
    pub session_id: String,
    pub encrypted_path: PathBuf,
    pub audio_chunks: Vec<RecordingAudioChunk>,
    pub encryption_key: SessionKey,
    pub duration_ms: u64,
    pub sample_rate: u32,
    pub channels: u16,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RecordingAudioChunk {
    pub chunk_id: String,
    pub path: PathBuf,
    pub start_ms: u64,
    pub end_ms: u64,
}

/// Crash-resilient encrypted audio journal used by the single Notebook capture runtime.
///
/// Each microphone callback is converted to the canonical local f32 PCM representation,
/// encrypted independently with AES-256-GCM, then appended as a length-delimited record.
/// No plaintext audio is ever written to disk. A truncated final record is ignored during
/// recovery, so a process crash preserves every fully written frame instead of losing the
/// entire in-memory recording.
pub struct CaptureAudioJournal {
    session_id: String,
    config: RecordingConfig,
    journal_path: PathBuf,
    key: SessionKey,
    state: Mutex<CaptureAudioJournalState>,
}

struct CaptureAudioJournalState {
    file: File,
    captured_frames: u64,
    records_since_sync: u64,
}

#[derive(Debug, Clone)]
pub struct RecoveredCaptureAudio {
    pub session_id: String,
    pub encrypted_path: PathBuf,
    pub audio_chunks: Vec<RecordingAudioChunk>,
    pub duration_ms: u64,
    pub sample_rate: u32,
    pub channels: u16,
    pub captured_frames: u64,
}

impl CaptureAudioJournal {
    pub fn start(
        session_id: String,
        config: RecordingConfig,
        key: SessionKey,
    ) -> Result<Self, RecordingError> {
        std::fs::create_dir_all(&config.data_dir).map_err(|error| RecordingError::WriteFailed {
            message: error.to_string(),
        })?;
        let journal_path = config
            .data_dir
            .join(format!("{session_id}.capture-journal.enc"));
        let file = create_capture_journal_file(&journal_path, |file| {
            file.write_all(CAPTURE_JOURNAL_MAGIC)?;
            file.sync_data()
        })?;

        Ok(Self {
            session_id,
            config,
            journal_path,
            key,
            state: Mutex::new(CaptureAudioJournalState {
                file,
                captured_frames: 0,
                records_since_sync: 0,
            }),
        })
    }

    pub fn journal_path(&self) -> &Path {
        &self.journal_path
    }

    pub fn captured_frames(&self) -> u64 {
        self.state
            .lock()
            .map(|state| state.captured_frames)
            .unwrap_or_default()
    }

    /// Push canonical Soniox microphone PCM (s16le, mono, 16 kHz).
    pub fn push_s16_pcm(&self, pcm_s16le: &[u8]) -> Result<(), RecordingError> {
        if !pcm_s16le.len().is_multiple_of(2) {
            return Err(RecordingError::InvalidAudio {
                message: "s16le audio must contain complete 2-byte samples".to_string(),
            });
        }
        let mut f32_bytes = Vec::with_capacity(pcm_s16le.len() * 2);
        for sample in pcm_s16le.chunks_exact(2) {
            let value = i16::from_le_bytes([sample[0], sample[1]]) as f32 / 32768.0;
            f32_bytes.extend_from_slice(&value.to_le_bytes());
        }
        self.push_f32_pcm(&f32_bytes)
    }
    pub fn push_f32_pcm(&self, pcm_f32le: &[u8]) -> Result<(), RecordingError> {
        let bytes_per_frame = self.config.channels.max(1) as usize * 4;
        if !pcm_f32le.len().is_multiple_of(bytes_per_frame) {
            return Err(RecordingError::InvalidAudio {
                message: format!(
                    "f32 audio byte count {} is not aligned to {bytes_per_frame}",
                    pcm_f32le.len()
                ),
            });
        }
        if pcm_f32le.len() > MAX_CAPTURE_FRAME_BYTES {
            return Err(RecordingError::InvalidAudio {
                message: format!(
                    "audio callback exceeds {} byte safety limit",
                    MAX_CAPTURE_FRAME_BYTES
                ),
            });
        }

        let encrypted =
            encrypt_chunk(pcm_f32le, &self.key).map_err(|error| RecordingError::WriteFailed {
                message: format!("encrypt capture frame: {error}"),
            })?;
        let encrypted_len =
            u32::try_from(encrypted.len()).map_err(|_| RecordingError::InvalidAudio {
                message: "encrypted capture frame is too large".to_string(),
            })?;
        let frame_count = (pcm_f32le.len() / bytes_per_frame) as u64;

        let mut state = self.state.lock().map_err(|_| RecordingError::WriteFailed {
            message: "capture journal mutex poisoned".to_string(),
        })?;
        state
            .file
            .write_all(&encrypted_len.to_le_bytes())
            .and_then(|_| state.file.write_all(&encrypted))
            .and_then(|_| state.file.flush())
            .map_err(|error| RecordingError::WriteFailed {
                message: error.to_string(),
            })?;
        state.captured_frames = state.captured_frames.saturating_add(frame_count);
        state.records_since_sync += 1;
        if state.records_since_sync >= CAPTURE_JOURNAL_SYNC_INTERVAL {
            state
                .file
                .sync_data()
                .map_err(|error| RecordingError::WriteFailed {
                    message: error.to_string(),
                })?;
            state.records_since_sync = 0;
        }
        Ok(())
    }

    pub fn stop(self) -> Result<RecordingResult, RecordingError> {
        {
            let mut state = self
                .state
                .into_inner()
                .map_err(|_| RecordingError::WriteFailed {
                    message: "capture journal mutex poisoned".to_string(),
                })?;
            state
                .file
                .flush()
                .and_then(|_| state.file.sync_all())
                .map_err(|error| RecordingError::WriteFailed {
                    message: error.to_string(),
                })?;
        }

        let recovered = recover_capture_audio_journal(
            &self.journal_path,
            &self.config.data_dir,
            &self.session_id,
            &self.key,
            self.config.sample_rate,
            self.config.channels,
        )?;
        Ok(RecordingResult {
            session_id: recovered.session_id,
            encrypted_path: recovered.encrypted_path,
            audio_chunks: recovered.audio_chunks,
            encryption_key: self.key,
            duration_ms: recovered.duration_ms,
            sample_rate: recovered.sample_rate,
            channels: recovered.channels,
        })
    }
}

fn create_capture_journal_file(
    journal_path: &Path,
    initialize: impl FnOnce(&mut File) -> std::io::Result<()>,
) -> Result<File, RecordingError> {
    let mut file = OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .open(journal_path)
        .map_err(|error| RecordingError::WriteFailed {
            message: error.to_string(),
        })?;
    if let Err(error) = initialize(&mut file) {
        drop(file);
        // This canonical path belongs solely to the new immutable session. A
        // partially initialized header cannot be recovered and must not survive
        // as an unindexed privacy residue.
        let _ = std::fs::remove_file(journal_path);
        return Err(RecordingError::WriteFailed {
            message: error.to_string(),
        });
    }
    Ok(file)
}

/// Recover every complete encrypted journal record and finalize the normal encrypted audio
/// chunks. A partially written final record is ignored; authenticated-record corruption fails
/// closed. The journal is retained even after successful recovery so the orchestration layer can
/// commit its database and retention indexes before deleting the last durable recovery source.
pub fn recover_capture_audio_journal(
    journal_path: &Path,
    data_dir: &Path,
    session_id: &str,
    key: &SessionKey,
    sample_rate: u32,
    channels: u16,
) -> Result<RecoveredCaptureAudio, RecordingError> {
    let mut file = File::open(journal_path).map_err(|error| RecordingError::WriteFailed {
        message: error.to_string(),
    })?;
    let mut magic = [0_u8; CAPTURE_JOURNAL_MAGIC.len()];
    file.read_exact(&mut magic)
        .map_err(|error| RecordingError::JournalCorrupt {
            message: format!("capture journal header: {error}"),
        })?;
    if &magic != CAPTURE_JOURNAL_MAGIC {
        return Err(RecordingError::JournalCorrupt {
            message: "capture journal magic mismatch".to_string(),
        });
    }

    let bytes_per_frame = channels.max(1) as usize * 4;
    let frames_per_chunk = sample_rate.max(1) as usize * 60;
    let chunk_byte_limit = (frames_per_chunk * bytes_per_frame).max(bytes_per_frame);
    let mut chunk_plaintext = Vec::with_capacity(chunk_byte_limit);
    let mut audio_chunks = Vec::new();
    let mut captured_frames = 0_u64;
    let mut chunk_start_frame = 0_u64;
    let chunk_writer = RecoveredCaptureChunkWriter {
        data_dir,
        session_id,
        key,
        sample_rate,
        bytes_per_frame,
    };
    loop {
        let mut length_bytes = [0_u8; 4];
        match file.read_exact(&mut length_bytes) {
            Ok(()) => {}
            Err(error) if error.kind() == ErrorKind::UnexpectedEof => break,
            Err(error) => {
                return Err(RecordingError::JournalCorrupt {
                    message: format!("capture journal frame length: {error}"),
                })
            }
        }
        let encrypted_len = u32::from_le_bytes(length_bytes) as usize;
        if !(28..=MAX_CAPTURE_FRAME_BYTES + 64).contains(&encrypted_len) {
            return Err(RecordingError::JournalCorrupt {
                message: format!("invalid encrypted frame length: {encrypted_len}"),
            });
        }
        let mut encrypted = vec![0_u8; encrypted_len];
        match file.read_exact(&mut encrypted) {
            Ok(()) => {}
            Err(error) if error.kind() == ErrorKind::UnexpectedEof => break,
            Err(error) => {
                return Err(RecordingError::JournalCorrupt {
                    message: format!("capture journal frame: {error}"),
                })
            }
        }
        let frame =
            decrypt_chunk(&encrypted, key).map_err(|error| RecordingError::JournalCorrupt {
                message: format!("authenticate capture journal frame: {error}"),
            })?;
        if frame.len() % bytes_per_frame != 0 {
            return Err(RecordingError::JournalCorrupt {
                message: "recovered f32 audio is not frame-aligned".to_string(),
            });
        }
        captured_frames = captured_frames.saturating_add((frame.len() / bytes_per_frame) as u64);
        let mut offset = 0_usize;
        while offset < frame.len() {
            let available = chunk_byte_limit - chunk_plaintext.len();
            let take = available.min(frame.len() - offset);
            chunk_plaintext.extend_from_slice(&frame[offset..offset + take]);
            offset += take;
            if chunk_plaintext.len() == chunk_byte_limit {
                audio_chunks.push(chunk_writer.write(
                    &chunk_plaintext,
                    chunk_start_frame,
                    audio_chunks.len(),
                )?);
                chunk_start_frame = chunk_start_frame
                    .saturating_add((chunk_plaintext.len() / bytes_per_frame) as u64);
                chunk_plaintext.clear();
            }
        }
    }

    if !chunk_plaintext.is_empty() || audio_chunks.is_empty() {
        audio_chunks.push(chunk_writer.write(
            &chunk_plaintext,
            chunk_start_frame,
            audio_chunks.len(),
        )?);
    }
    let duration_ms = if sample_rate > 0 {
        captured_frames.saturating_mul(1000) / sample_rate as u64
    } else {
        0
    };
    let encrypted_path = audio_chunks
        .first()
        .map(|chunk| chunk.path.clone())
        .unwrap_or_else(|| data_dir.join(format!("{session_id}.chunk.00000.enc")));
    Ok(RecoveredCaptureAudio {
        session_id: session_id.to_string(),
        encrypted_path,
        audio_chunks,
        duration_ms,
        sample_rate,
        channels,
        captured_frames,
    })
}

struct RecoveredCaptureChunkWriter<'a> {
    data_dir: &'a Path,
    session_id: &'a str,
    key: &'a SessionKey,
    sample_rate: u32,
    bytes_per_frame: usize,
}

impl RecoveredCaptureChunkWriter<'_> {
    fn write(
        &self,
        plaintext: &[u8],
        start_frame: u64,
        index: usize,
    ) -> Result<RecordingAudioChunk, RecordingError> {
        std::fs::create_dir_all(self.data_dir).map_err(|error| RecordingError::WriteFailed {
            message: error.to_string(),
        })?;
        let path = self
            .data_dir
            .join(format!("{}.chunk.{index:05}.enc", self.session_id));
        let temporary = self.data_dir.join(format!(
            ".{}.chunk.{index:05}.{}.recovering",
            self.session_id,
            uuid::Uuid::new_v4()
        ));
        if let Err(error) = encrypt_to_file(&temporary, self.key, plaintext) {
            let _ = std::fs::remove_file(&temporary);
            return Err(RecordingError::WriteFailed {
                message: error.to_string(),
            });
        }
        if let Ok(file) = File::open(&temporary) {
            file.sync_all()
                .map_err(|error| RecordingError::WriteFailed {
                    message: format!("sync recovered capture chunk: {error}"),
                })?;
        }
        if let Err(error) = std::fs::rename(&temporary, &path) {
            let _ = std::fs::remove_file(&temporary);
            return Err(RecordingError::WriteFailed {
                message: format!("install recovered capture chunk: {error}"),
            });
        }
        if let Ok(directory) = File::open(self.data_dir) {
            let _ = directory.sync_all();
        }
        let frame_count = (plaintext.len() / self.bytes_per_frame) as u64;
        let end_frame = start_frame.saturating_add(frame_count);
        let (start_ms, end_ms) = if self.sample_rate > 0 {
            (
                start_frame.saturating_mul(1000) / self.sample_rate as u64,
                end_frame.saturating_mul(1000) / self.sample_rate as u64,
            )
        } else {
            (0, 0)
        };
        Ok(RecordingAudioChunk {
            chunk_id: format!("{}:audio:{index:05}", self.session_id),
            path,
            start_ms,
            end_ms,
        })
    }
}

pub fn write_encrypted_audio_chunks(
    data_dir: &std::path::Path,
    session_id: &str,
    key: &SessionKey,
    pcm_f32_bytes: &[u8],
    sample_rate: u32,
    channels: u16,
) -> Result<Vec<RecordingAudioChunk>, RecordingError> {
    if !data_dir.exists() {
        std::fs::create_dir_all(data_dir).map_err(|e| RecordingError::WriteFailed {
            message: e.to_string(),
        })?;
    }

    let bytes_per_frame = channels.max(1) as usize * 4;
    let frames_per_chunk = sample_rate.max(1) as usize * 60;
    let chunk_bytes = (frames_per_chunk * bytes_per_frame).max(bytes_per_frame);
    let mut chunks: Vec<RecordingAudioChunk> = Vec::new();
    let mut offset = 0_usize;
    let mut index = 0_usize;

    while offset < pcm_f32_bytes.len() || (pcm_f32_bytes.is_empty() && index == 0) {
        let end = (offset + chunk_bytes).min(pcm_f32_bytes.len());
        let chunk_bytes_slice = &pcm_f32_bytes[offset..end];
        let start_frame = offset / bytes_per_frame;
        let end_frame = end / bytes_per_frame;
        let start_ms = if sample_rate > 0 {
            (start_frame as u64 * 1000) / sample_rate as u64
        } else {
            0
        };
        let end_ms = if sample_rate > 0 {
            (end_frame as u64 * 1000) / sample_rate as u64
        } else {
            start_ms
        };
        let chunk_id = format!("{session_id}:audio:{index:05}");
        let path = data_dir.join(format!("{session_id}.chunk.{index:05}.enc"));
        if let Err(error) = encrypt_to_file(&path, key, chunk_bytes_slice) {
            // Import/capture materialization is all-or-nothing at this layer.
            // A later chunk failure must not leave earlier encrypted chunks
            // that no durable retention ledger can discover.
            let _ = std::fs::remove_file(&path);
            for written in &chunks {
                let _ = std::fs::remove_file(&written.path);
            }
            return Err(RecordingError::WriteFailed {
                message: error.to_string(),
            });
        }
        chunks.push(RecordingAudioChunk {
            chunk_id,
            path,
            start_ms,
            end_ms,
        });
        if end == pcm_f32_bytes.len() {
            break;
        }
        offset = end;
        index += 1;
    }

    Ok(chunks)
}

/// 将 f32 samples 转为字节
pub fn f32_samples_to_bytes(samples: &[f32]) -> Vec<u8> {
    samples.iter().flat_map(|s| s.to_le_bytes()).collect()
}

/// 将字节转为 f32 samples
pub fn bytes_to_f32_samples(bytes: &[u8]) -> Vec<f32> {
    bytes
        .chunks_exact(4)
        .map(|b| f32::from_le_bytes([b[0], b[1], b[2], b[3]]))
        .collect()
}

/// 生成测试用 PCM 数据（正弦波）
pub fn generate_test_pcm(sample_rate: u32, duration_secs: f64) -> Vec<f32> {
    let num_samples = (sample_rate as f64 * duration_secs) as usize;
    (0..num_samples)
        .map(|i| {
            let t = i as f64 / sample_rate as f64;
            (2.0 * std::f64::consts::PI * 440.0 * t).sin() as f32
        })
        .collect()
}

#[derive(Debug, thiserror::Error)]
pub enum RecordingError {
    #[error("write failed: {message}")]
    WriteFailed { message: String },
    #[error("invalid audio: {message}")]
    InvalidAudio { message: String },
    #[error("capture journal corrupt: {message}")]
    JournalCorrupt { message: String },
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Read;
    use tempfile::TempDir;
    use vt_crypto::decrypt::DecryptReader;

    #[test]
    fn capture_journal_header_failure_removes_partial_file() {
        let tmp = TempDir::new().unwrap();
        let path = tmp.path().join("failed.capture-journal.enc");
        let result = create_capture_journal_file(&path, |file| {
            file.write_all(b"partial")?;
            Err(std::io::Error::other("injected sync failure"))
        });

        assert!(matches!(result, Err(RecordingError::WriteFailed { .. })));
        assert!(
            !path.exists(),
            "partially initialized encrypted journal must not survive start failure"
        );
    }

    #[test]
    fn capture_audio_journal_encrypts_and_finalizes_s16_audio() {
        let tmp = TempDir::new().unwrap();
        let config = RecordingConfig {
            data_dir: tmp.path().to_path_buf(),
            sample_rate: 16_000,
            channels: 1,
        };
        let key = SessionKey::generate();
        let journal = CaptureAudioJournal::start("capture-1".to_string(), config, key).unwrap();
        let samples: Vec<i16> = (0..1_600).map(|index| (index as i16) - 800).collect();
        let s16: Vec<u8> = samples
            .iter()
            .flat_map(|value| value.to_le_bytes())
            .collect();

        journal.push_s16_pcm(&s16).unwrap();
        assert_eq!(journal.captured_frames(), 1_600);
        let journal_bytes = std::fs::read(journal.journal_path()).unwrap();
        assert!(journal_bytes.starts_with(CAPTURE_JOURNAL_MAGIC));
        assert_ne!(
            journal_bytes, s16,
            "journal must never contain raw microphone PCM"
        );

        let result = journal.stop().unwrap();
        assert_eq!(result.duration_ms, 100);
        assert!(
            tmp.path().join("capture-1.capture-journal.enc").exists(),
            "orchestration must retain the journal until durable indexes commit"
        );

        let mut reader =
            DecryptReader::new(&result.encrypted_path, &result.encryption_key).unwrap();
        let mut recovered = Vec::new();
        reader.read_to_end(&mut recovered).unwrap();
        let expected: Vec<u8> = samples
            .iter()
            .flat_map(|sample| ((*sample as f32) / 32768.0).to_le_bytes())
            .collect();
        assert_eq!(recovered, expected);
    }

    #[test]
    fn capture_audio_journal_recovery_ignores_truncated_final_record() {
        let tmp = TempDir::new().unwrap();
        let config = RecordingConfig {
            data_dir: tmp.path().to_path_buf(),
            sample_rate: 16_000,
            channels: 1,
        };
        let key_bytes = *SessionKey::generate().as_bytes();
        let journal = CaptureAudioJournal::start(
            "capture-crash".to_string(),
            config,
            SessionKey::from_bytes(key_bytes),
        )
        .unwrap();
        let s16 = vec![0_u8; 3_200]; // 100 ms
        journal.push_s16_pcm(&s16).unwrap();
        let journal_path = journal.journal_path().to_path_buf();
        drop(journal); // Simulate process loss after a complete encrypted record.

        let mut file = OpenOptions::new().append(true).open(&journal_path).unwrap();
        file.write_all(&128_u32.to_le_bytes()).unwrap();
        file.write_all(&[1, 2, 3, 4]).unwrap();
        file.sync_all().unwrap();
        drop(file);

        let recovered = recover_capture_audio_journal(
            &journal_path,
            tmp.path(),
            "capture-crash",
            &SessionKey::from_bytes(key_bytes),
            16_000,
            1,
        )
        .unwrap();
        assert_eq!(recovered.duration_ms, 100);
        assert_eq!(recovered.captured_frames, 1_600);
        assert!(recovered.encrypted_path.exists());
        assert!(
            journal_path.exists(),
            "standalone recovery must retain the journal until durable metadata commits"
        );
    }

    #[test]
    fn capture_audio_journal_recovery_streams_into_minute_chunks() {
        let tmp = TempDir::new().unwrap();
        let key_bytes = *SessionKey::generate().as_bytes();
        let journal = CaptureAudioJournal::start(
            "capture-long".to_string(),
            RecordingConfig {
                data_dir: tmp.path().to_path_buf(),
                sample_rate: 16_000,
                channels: 1,
            },
            SessionKey::from_bytes(key_bytes),
        )
        .unwrap();
        // 61 seconds of s16 mono remains below the per-callback safety cap
        // after conversion, while crossing the physical 60-second boundary.
        journal.push_s16_pcm(&vec![0_u8; 16_000 * 2 * 61]).unwrap();
        let journal_path = journal.journal_path().to_path_buf();
        drop(journal);

        let recovered = recover_capture_audio_journal(
            &journal_path,
            tmp.path(),
            "capture-long",
            &SessionKey::from_bytes(key_bytes),
            16_000,
            1,
        )
        .unwrap();
        assert_eq!(recovered.duration_ms, 61_000);
        assert_eq!(recovered.audio_chunks.len(), 2);
        assert_eq!(recovered.audio_chunks[0].start_ms, 0);
        assert_eq!(recovered.audio_chunks[0].end_ms, 60_000);
        assert_eq!(recovered.audio_chunks[1].start_ms, 60_000);
        assert_eq!(recovered.audio_chunks[1].end_ms, 61_000);
        assert!(journal_path.exists());
    }

    #[test]
    fn capture_audio_journal_rejects_partial_s16_samples() {
        let tmp = TempDir::new().unwrap();
        let journal = CaptureAudioJournal::start(
            "capture-invalid".to_string(),
            RecordingConfig {
                data_dir: tmp.path().to_path_buf(),
                sample_rate: 16_000,
                channels: 1,
            },
            SessionKey::generate(),
        )
        .unwrap();
        assert!(matches!(
            journal.push_s16_pcm(&[0]),
            Err(RecordingError::InvalidAudio { .. })
        ));
    }
}
