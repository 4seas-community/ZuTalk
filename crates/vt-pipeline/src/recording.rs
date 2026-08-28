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

/// Journal whose records are f32le samples — every journal written before
/// sample storage narrowed to s16. Still fully readable: startup recovery of
/// a crash that predates the update must not lose the recording.
const CAPTURE_JOURNAL_MAGIC_F32: &[u8; 8] = b"VTCAPJ1\0";
/// Journal whose records are s16le samples. The microphone delivers 16-bit
/// samples; widening them to f32 for storage doubled every recording's disk
/// footprint while adding no information — the provider upload narrows back
/// to s16 anyway.
const CAPTURE_JOURNAL_MAGIC_S16: &[u8; 8] = b"VTCAPJ2\0";
const CAPTURE_JOURNAL_SYNC_INTERVAL: u64 = 10;

/// How one session's stored PCM encodes a sample. Recorded durably next to
/// sample rate and channel count: the bytes themselves are opaque ciphertext,
/// so every reader needs the format from the same snapshot that gave it the
/// rate.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StoredSampleFormat {
    F32,
    S16,
}

impl StoredSampleFormat {
    pub fn bytes_per_sample(self) -> usize {
        match self {
            Self::F32 => 4,
            Self::S16 => 2,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::F32 => "f32",
            Self::S16 => "s16",
        }
    }

    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "f32" => Some(Self::F32),
            "s16" => Some(Self::S16),
            _ => None,
        }
    }
}

/// Widens stored s16le bytes to the f32le the in-memory pipeline works in.
pub fn s16le_bytes_to_f32le(pcm_s16le: &[u8]) -> Vec<u8> {
    let mut f32_bytes = Vec::with_capacity(pcm_s16le.len() * 2);
    for sample in pcm_s16le.chunks_exact(2) {
        let value = i16::from_le_bytes([sample[0], sample[1]]) as f32 / 32768.0;
        f32_bytes.extend_from_slice(&value.to_le_bytes());
    }
    f32_bytes
}

/// Narrows f32le interchange bytes to the s16le the store keeps.
pub fn f32le_bytes_to_s16le(pcm_f32le: &[u8]) -> Vec<u8> {
    let mut s16_bytes = Vec::with_capacity(pcm_f32le.len() / 2);
    for sample in pcm_f32le.chunks_exact(4) {
        let value = f32::from_le_bytes([sample[0], sample[1], sample[2], sample[3]]);
        let scaled = (value.clamp(-1.0, 1.0) * 32767.0).round() as i16;
        s16_bytes.extend_from_slice(&scaled.to_le_bytes());
    }
    s16_bytes
}
const MAX_CAPTURE_FRAME_BYTES: usize = 8 * 1024 * 1024;

/// Container for every per-session audio directory, relative to the data dir.
pub const SESSION_AUDIO_ROOT_DIR: &str = "audio";

/// `<data_dir>/audio/<session_id>` — the canonical home of one session's
/// encrypted audio. Every artifact a session owns on disk lives here, so
/// destroying the audio is a single directory removal rather than a filename
/// prefix scan of the data directory root.
pub fn session_audio_dir(data_dir: &Path, session_id: &str) -> PathBuf {
    data_dir.join(SESSION_AUDIO_ROOT_DIR).join(session_id)
}

/// The chunk index stays in the file name: recovery rebuilds the chunk list by
/// deriving each path from the session id and the chunk ordinal, so the name
/// must remain a pure function of those two values.
pub fn session_audio_chunk_path(data_dir: &Path, session_id: &str, index: usize) -> PathBuf {
    session_audio_dir(data_dir, session_id).join(format!("chunk.{index:05}.enc"))
}

pub fn session_capture_journal_path(data_dir: &Path, session_id: &str) -> PathBuf {
    session_audio_dir(data_dir, session_id).join("capture-journal.enc")
}

/// Flat data-directory-root layout used before per-session audio directories.
/// Retained so a database written by an older build stays readable until the
/// startup relocation finishes.
pub fn legacy_session_audio_chunk_path(data_dir: &Path, session_id: &str, index: usize) -> PathBuf {
    data_dir.join(format!("{session_id}.chunk.{index:05}.enc"))
}

/// A session id becomes a directory name, so anything that could escape the
/// data directory has to fail before a path is built from it.
pub fn require_session_id_path_component(session_id: &str) -> Result<(), RecordingError> {
    let is_single_component = !session_id.is_empty()
        && session_id != "."
        && session_id != ".."
        && !session_id.contains('/')
        && !session_id.contains('\\')
        && !session_id.contains('\0')
        && Path::new(session_id).components().count() == 1;
    if !is_single_component {
        return Err(RecordingError::InvalidAudio {
            message: format!("session id is not a usable directory name: {session_id}"),
        });
    }
    Ok(())
}

fn create_session_audio_dir(data_dir: &Path, session_id: &str) -> Result<PathBuf, RecordingError> {
    require_session_id_path_component(session_id)?;
    let dir = session_audio_dir(data_dir, session_id);
    std::fs::create_dir_all(&dir).map_err(|error| RecordingError::WriteFailed {
        message: error.to_string(),
    })?;
    Ok(dir)
}

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
    pub sample_format: StoredSampleFormat,
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
    /// The width the journal's records — and therefore the recovered chunks —
    /// encode a sample in. Comes from the journal magic, so a crash journal
    /// written before the s16 change recovers as the f32 it is.
    pub sample_format: StoredSampleFormat,
}

impl CaptureAudioJournal {
    pub fn start(
        session_id: String,
        config: RecordingConfig,
        key: SessionKey,
    ) -> Result<Self, RecordingError> {
        create_session_audio_dir(&config.data_dir, &session_id)?;
        let journal_path = session_capture_journal_path(&config.data_dir, &session_id);
        let file = create_capture_journal_file(&journal_path, |file| {
            file.write_all(CAPTURE_JOURNAL_MAGIC_S16)?;
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
    ///
    /// Stored as-is: the samples are already the 16-bit width the store
    /// keeps, so the former widen-to-f32 round trip is gone.
    pub fn push_s16_pcm(&self, pcm_s16le: &[u8]) -> Result<(), RecordingError> {
        if !pcm_s16le.len().is_multiple_of(2) {
            return Err(RecordingError::InvalidAudio {
                message: "s16le audio must contain complete 2-byte samples".to_string(),
            });
        }
        self.push_stored_pcm(pcm_s16le)
    }

    /// Push f32le PCM. Narrowed to the stored s16 width; the microphone is a
    /// 16-bit source, so nothing real is lost.
    pub fn push_f32_pcm(&self, pcm_f32le: &[u8]) -> Result<(), RecordingError> {
        if !pcm_f32le.len().is_multiple_of(4) {
            return Err(RecordingError::InvalidAudio {
                message: "f32le audio must contain complete 4-byte samples".to_string(),
            });
        }
        self.push_stored_pcm(&f32le_bytes_to_s16le(pcm_f32le))
    }

    fn push_stored_pcm(&self, pcm: &[u8]) -> Result<(), RecordingError> {
        let bytes_per_frame =
            self.config.channels.max(1) as usize * StoredSampleFormat::S16.bytes_per_sample();
        if !pcm.len().is_multiple_of(bytes_per_frame) {
            return Err(RecordingError::InvalidAudio {
                message: format!(
                    "audio byte count {} is not aligned to {bytes_per_frame}",
                    pcm.len()
                ),
            });
        }
        if pcm.len() > MAX_CAPTURE_FRAME_BYTES {
            return Err(RecordingError::InvalidAudio {
                message: format!(
                    "audio callback exceeds {} byte safety limit",
                    MAX_CAPTURE_FRAME_BYTES
                ),
            });
        }

        let encrypted =
            encrypt_chunk(pcm, &self.key).map_err(|error| RecordingError::WriteFailed {
                message: format!("encrypt capture frame: {error}"),
            })?;
        let encrypted_len =
            u32::try_from(encrypted.len()).map_err(|_| RecordingError::InvalidAudio {
                message: "encrypted capture frame is too large".to_string(),
            })?;
        let frame_count = (pcm.len() / bytes_per_frame) as u64;

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
            sample_format: recovered.sample_format,
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
    let mut magic = [0_u8; CAPTURE_JOURNAL_MAGIC_S16.len()];
    file.read_exact(&mut magic)
        .map_err(|error| RecordingError::JournalCorrupt {
            message: format!("capture journal header: {error}"),
        })?;
    let sample_format = if &magic == CAPTURE_JOURNAL_MAGIC_S16 {
        StoredSampleFormat::S16
    } else if &magic == CAPTURE_JOURNAL_MAGIC_F32 {
        StoredSampleFormat::F32
    } else {
        return Err(RecordingError::JournalCorrupt {
            message: "capture journal magic mismatch".to_string(),
        });
    };

    let bytes_per_frame = channels.max(1) as usize * sample_format.bytes_per_sample();
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
                message: "recovered audio is not frame-aligned".to_string(),
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
        .unwrap_or_else(|| session_audio_chunk_path(data_dir, session_id, 0));
    Ok(RecoveredCaptureAudio {
        sample_format,
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
        let session_dir = create_session_audio_dir(self.data_dir, self.session_id)?;
        let path = session_audio_chunk_path(self.data_dir, self.session_id, index);
        // The temp name stays inside the session directory so an abandoned
        // recovery attempt is destroyed by the same directory removal that
        // destroys the session's committed chunks.
        let temporary = session_dir.join(format!(
            ".chunk.{index:05}.{}.recovering",
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
        if let Ok(directory) = File::open(&session_dir) {
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
    pcm_bytes: &[u8],
    sample_rate: u32,
    channels: u16,
    sample_format: StoredSampleFormat,
) -> Result<Vec<RecordingAudioChunk>, RecordingError> {
    create_session_audio_dir(data_dir, session_id)?;

    let bytes_per_frame = channels.max(1) as usize * sample_format.bytes_per_sample();
    let frames_per_chunk = sample_rate.max(1) as usize * 60;
    let chunk_bytes = (frames_per_chunk * bytes_per_frame).max(bytes_per_frame);
    let mut chunks: Vec<RecordingAudioChunk> = Vec::new();
    let mut offset = 0_usize;
    let mut index = 0_usize;

    while offset < pcm_bytes.len() || (pcm_bytes.is_empty() && index == 0) {
        let end = (offset + chunk_bytes).min(pcm_bytes.len());
        let chunk_bytes_slice = &pcm_bytes[offset..end];
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
        let path = session_audio_chunk_path(data_dir, session_id, index);
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
        if end == pcm_bytes.len() {
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
        assert!(journal_bytes.starts_with(CAPTURE_JOURNAL_MAGIC_S16));
        assert_ne!(
            journal_bytes, s16,
            "journal must never contain raw microphone PCM"
        );

        let result = journal.stop().unwrap();
        assert_eq!(result.duration_ms, 100);
        assert!(
            session_capture_journal_path(tmp.path(), "capture-1").exists(),
            "orchestration must retain the journal until durable indexes commit"
        );
        assert_eq!(
            result.encrypted_path,
            session_audio_chunk_path(tmp.path(), "capture-1", 0),
            "capture audio must land in the session's own directory"
        );

        let mut reader =
            DecryptReader::new(&result.encrypted_path, &result.encryption_key).unwrap();
        let mut recovered = Vec::new();
        reader.read_to_end(&mut recovered).unwrap();
        assert_eq!(
            recovered, s16,
            "stored samples keep the microphone's own 16-bit width"
        );
        assert_eq!(result.sample_format, StoredSampleFormat::S16);
    }

    /// A journal written before the s16 change — f32 records under the V1
    /// magic — still recovers, as f32, so a crash that straddles the update
    /// loses nothing.
    #[test]
    fn a_legacy_f32_journal_still_recovers_as_f32() {
        let tmp = TempDir::new().unwrap();
        let key = SessionKey::generate();
        let session_dir = session_audio_dir(tmp.path(), "legacy-f32");
        std::fs::create_dir_all(&session_dir).unwrap();
        let journal_path = session_capture_journal_path(tmp.path(), "legacy-f32");
        let samples: Vec<f32> = (0..1_600).map(|index| (index as f32) / 3_200.0).collect();
        let f32_bytes = f32_samples_to_bytes(&samples);
        let record = encrypt_chunk(&f32_bytes, &key).unwrap();
        let mut file = File::create(&journal_path).unwrap();
        file.write_all(CAPTURE_JOURNAL_MAGIC_F32).unwrap();
        file.write_all(&(record.len() as u32).to_le_bytes())
            .unwrap();
        file.write_all(&record).unwrap();
        file.sync_all().unwrap();
        drop(file);

        let recovered =
            recover_capture_audio_journal(&journal_path, tmp.path(), "legacy-f32", &key, 16_000, 1)
                .unwrap();
        assert_eq!(recovered.sample_format, StoredSampleFormat::F32);
        assert_eq!(recovered.captured_frames, 1_600);
        assert_eq!(recovered.duration_ms, 100);

        let mut reader = DecryptReader::new(&recovered.encrypted_path, &key).unwrap();
        let mut chunk_bytes = Vec::new();
        reader.read_to_end(&mut chunk_bytes).unwrap();
        assert_eq!(
            chunk_bytes, f32_bytes,
            "legacy chunks keep their f32 width end to end"
        );
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
