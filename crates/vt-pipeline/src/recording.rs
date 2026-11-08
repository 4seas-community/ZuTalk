//! Notebook capture 的本地加密音频存储与导入音频分块工具。
//!
//! 麦克风帧在推送线程上逐帧加密，直接追加进它所属的那一分钟音频块；块的格式
//! 就是读取方一直在解的那种记录流，所以录音中写下的就是最终文件，音频只落盘
//! 一次。该模块不拥有录音 session 生命周期，唯一的状态机位于
//! `vt-ffi::notebook_capture_api::ActiveNotebookCapture`。

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
/// Journal that holds no audio: the recording's audio is in its minute chunks,
/// appended as it arrives. The file marks a capture whose audio has not been
/// committed yet; recovery reads the chunks. Builds before this one do not know
/// the magic and refuse to recover it, leaving every file in place.
const CAPTURE_JOURNAL_MAGIC_CHUNKS: &[u8; 8] = b"VTCAPJ3\0";
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

/// Crash-resilient encrypted audio store for the single Notebook capture runtime.
///
/// Each microphone push is encrypted on its own with AES-256-GCM and appended,
/// as a length-delimited record, to the minute chunk it belongs to. That is the
/// chunk format every reader already decodes: `encrypt_to_file` writes the same
/// `[u32 length | nonce ‖ ciphertext ‖ tag]` records, only larger. So the chunks
/// are final the moment they are written, and the audio reaches the disk once.
///
/// It used to reach it twice. Every push went into a separate journal file, and
/// each finished minute was encrypted again into its chunk — a second copy of
/// every recording, about 32 KB a second, which together with the database was
/// enough for macOS to report a three-hour recording for heavy disk writes.
///
/// The journal file remains, holding only a header: while it exists the
/// recording has not been committed, which is what startup recovery and the
/// stop path key on. A crash leaves the chunks as written; recovery reads them,
/// drops a record the crash cut short, and indexes what is there. No plaintext
/// audio is ever written to disk.
pub struct CaptureAudioJournal {
    session_id: String,
    config: RecordingConfig,
    journal_path: PathBuf,
    key: SessionKey,
    state: Mutex<CaptureAudioJournalState>,
    syncer: JournalSyncer,
}

struct CaptureAudioJournalState {
    /// The minute being written; opened when its first audio arrives, so a
    /// recording that stops on a minute boundary leaves no empty chunk.
    chunk: Option<File>,
    chunk_index: usize,
    /// Plaintext bytes already in `chunk`.
    chunk_bytes: usize,
    captured_frames: u64,
    records_since_sync: u64,
}

/// Flushes written chunks to stable storage on its own thread.
///
/// Pushes arrive on the audio path, which has a bounded queue in front of it
/// and ends the recording when that queue fills. On macOS `sync_data` is
/// `F_FULLFSYNC`, which waits for the drive's own cache — usually a few
/// milliseconds, and hundreds when the disk is busy with anything else. Issued
/// inline, every one of those waits would be a wait the audio thread paid for.
///
/// Moving it changes nothing a crash can observe. A `write` that returned is
/// already in the kernel and survives the process dying; the flush only
/// matters for power loss, and it still runs about once a second, and for each
/// minute as it is completed. A flush that fails is reported by the next push.
struct JournalSyncer {
    files: Option<std::sync::mpsc::SyncSender<File>>,
    failure: std::sync::Arc<Mutex<Option<String>>>,
    thread: Option<std::thread::JoinHandle<()>>,
}

impl JournalSyncer {
    fn start() -> Self {
        let (files, to_sync) = std::sync::mpsc::sync_channel::<File>(4);
        let failure = std::sync::Arc::new(Mutex::new(None));
        let thread_failure = failure.clone();
        let thread = std::thread::Builder::new()
            .name("zutalk-journal-sync".to_string())
            .spawn(move || {
                while let Ok(file) = to_sync.recv() {
                    if let Err(error) = file.sync_data() {
                        if let Ok(mut slot) = thread_failure.lock() {
                            *slot = Some(error.to_string());
                        }
                        break;
                    }
                }
            })
            .ok();
        Self {
            files: thread.as_ref().map(|_| files),
            failure,
            thread,
        }
    }

    /// Asks for a flush of the chunk being written without waiting for it.
    /// A full queue already holds a flush that covers these writes.
    fn request(&self, file: &File) {
        if let (Some(files), Ok(handle)) = (&self.files, file.try_clone()) {
            let _ = files.try_send(handle);
        }
    }

    /// Hands over a completed minute. Waits only if four flushes are already
    /// queued, so a finished chunk is never skipped.
    fn complete(&self, file: File) {
        if let Some(files) = &self.files {
            let _ = files.send(file);
        }
    }

    fn failure(&self) -> Option<String> {
        self.failure.lock().ok().and_then(|slot| slot.clone())
    }

    fn finish(&mut self) {
        self.files.take();
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

impl Drop for JournalSyncer {
    fn drop(&mut self) {
        // Detach rather than join: dropping the sender ends the thread after
        // the flushes already queued.
        self.files.take();
    }
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
        create_capture_journal_file(&journal_path, |file| {
            file.write_all(CAPTURE_JOURNAL_MAGIC_CHUNKS)?;
            file.sync_data()
        })?;
        Ok(Self {
            session_id,
            config,
            journal_path,
            key,
            state: Mutex::new(CaptureAudioJournalState {
                chunk: None,
                chunk_index: 0,
                chunk_bytes: 0,
                captured_frames: 0,
                records_since_sync: 0,
            }),
            syncer: JournalSyncer::start(),
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
        if let Some(message) = self.syncer.failure() {
            return Err(RecordingError::WriteFailed { message });
        }

        let minute_bytes = chunk_byte_limit(self.config.sample_rate, bytes_per_frame);
        let mut state = self.state.lock().map_err(|_| RecordingError::WriteFailed {
            message: "capture journal mutex poisoned".to_string(),
        })?;
        let mut offset = 0_usize;
        while offset < pcm.len() {
            // A push that straddles a minute boundary is split, so every
            // chunk holds exactly one minute and its index stays its time.
            let take = (minute_bytes - state.chunk_bytes).min(pcm.len() - offset);
            let record = sealed_record(&pcm[offset..offset + take], &self.key)?;
            if state.chunk.is_none() {
                state.chunk = Some(open_live_chunk(
                    &self.config.data_dir,
                    &self.session_id,
                    state.chunk_index,
                )?);
            }
            let chunk = state.chunk.as_mut().expect("chunk opened above");
            chunk
                .write_all(&record)
                .and_then(|_| chunk.flush())
                .map_err(|error| RecordingError::WriteFailed {
                    message: format!("append capture audio: {error}"),
                })?;
            offset += take;
            state.chunk_bytes += take;
            state.captured_frames = state
                .captured_frames
                .saturating_add((take / bytes_per_frame) as u64);
            if state.chunk_bytes == minute_bytes {
                if let Some(finished) = state.chunk.take() {
                    self.syncer.complete(finished);
                }
                state.chunk_index += 1;
                state.chunk_bytes = 0;
                state.records_since_sync = 0;
            }
        }
        state.records_since_sync += 1;
        if state.records_since_sync >= CAPTURE_JOURNAL_SYNC_INTERVAL {
            if let Some(chunk) = &state.chunk {
                self.syncer.request(chunk);
            }
            state.records_since_sync = 0;
        }
        Ok(())
    }

    pub fn stop(self) -> Result<RecordingResult, RecordingError> {
        let Self {
            session_id,
            config,
            journal_path: _,
            key,
            state,
            mut syncer,
        } = self;
        let CaptureAudioJournalState {
            chunk,
            chunk_index,
            captured_frames,
            ..
        } = state
            .into_inner()
            .map_err(|_| RecordingError::WriteFailed {
                message: "capture journal mutex poisoned".to_string(),
            })?;
        // The minute in progress is the last one; nothing will be added.
        let last_open = chunk.is_some();
        if let Some(mut chunk) = chunk {
            chunk
                .flush()
                .and_then(|_| chunk.sync_all())
                .map_err(|error| RecordingError::WriteFailed {
                    message: format!("sync final capture chunk: {error}"),
                })?;
        }
        syncer.finish();
        if let Some(message) = syncer.failure() {
            return Err(RecordingError::WriteFailed { message });
        }

        let chunk_count = if last_open {
            chunk_index + 1
        } else if chunk_index == 0 {
            // Nothing was recorded. A session still owns one (empty) chunk.
            encrypt_to_file(
                session_audio_chunk_path(&config.data_dir, &session_id, 0),
                &key,
                &[],
            )
            .map_err(|error| RecordingError::WriteFailed {
                message: format!("write empty capture chunk: {error}"),
            })?;
            1
        } else {
            chunk_index
        };
        let bytes_per_frame =
            config.channels.max(1) as usize * StoredSampleFormat::S16.bytes_per_sample();
        let audio_chunks = minute_chunk_index(
            &config.data_dir,
            &session_id,
            chunk_count,
            captured_frames,
            config.sample_rate,
            bytes_per_frame,
        );
        // The index about to be committed must point at the chunks it names.
        // A chunk that is gone or replaced fails the stop; the journal stays,
        // and recovery indexes whatever is really there.
        if let Some(missing) = audio_chunks
            .iter()
            .find(|chunk| !std::fs::metadata(&chunk.path).is_ok_and(|meta| meta.is_file()))
        {
            return Err(RecordingError::WriteFailed {
                message: format!("capture chunk {} is missing", missing.path.display()),
            });
        }
        remove_chunks_from(&config.data_dir, &session_id, chunk_count);
        seal_chunks(&config.data_dir, &session_id, &audio_chunks)?;
        Ok(RecordingResult {
            session_id,
            encrypted_path: audio_chunks[0].path.clone(),
            audio_chunks,
            encryption_key: key,
            duration_ms: duration_ms(captured_frames, config.sample_rate),
            sample_rate: config.sample_rate,
            channels: config.channels,
            sample_format: StoredSampleFormat::S16,
        })
    }
}

/// One push as a chunk record: `u32` length, then the sealed plaintext — the
/// framing `encrypt_to_file` writes and `DecryptReader` reads. Built in one
/// buffer so it reaches the file in a single write.
fn sealed_record(plaintext: &[u8], key: &SessionKey) -> Result<Vec<u8>, RecordingError> {
    let encrypted = encrypt_chunk(plaintext, key).map_err(|error| RecordingError::WriteFailed {
        message: format!("encrypt capture frame: {error}"),
    })?;
    let length = u32::try_from(encrypted.len()).map_err(|_| RecordingError::InvalidAudio {
        message: "encrypted capture frame is too large".to_string(),
    })?;
    let mut record = Vec::with_capacity(4 + encrypted.len());
    record.extend_from_slice(&length.to_le_bytes());
    record.extend_from_slice(&encrypted);
    Ok(record)
}

/// Opens a minute chunk for appending. A file left at this index by an
/// earlier, abandoned attempt holds nothing of this recording and is
/// replaced.
fn open_live_chunk(
    data_dir: &Path,
    session_id: &str,
    index: usize,
) -> Result<File, RecordingError> {
    OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .open(session_audio_chunk_path(data_dir, session_id, index))
        .map_err(|error| RecordingError::WriteFailed {
            message: format!("open capture chunk {index}: {error}"),
        })
}

/// The index of `chunk_count` minute chunks holding `captured_frames`: full
/// minutes, then whatever the last one holds.
fn minute_chunk_index(
    data_dir: &Path,
    session_id: &str,
    chunk_count: usize,
    captured_frames: u64,
    sample_rate: u32,
    bytes_per_frame: usize,
) -> Vec<RecordingAudioChunk> {
    let frames_per_chunk =
        (chunk_byte_limit(sample_rate, bytes_per_frame) / bytes_per_frame) as u64;
    (0..chunk_count)
        .map(|index| {
            let start_frame = index as u64 * frames_per_chunk;
            let end_frame = (start_frame + frames_per_chunk).min(captured_frames.max(start_frame));
            RecordingAudioChunk {
                chunk_id: format!("{session_id}:audio:{index:05}"),
                path: session_audio_chunk_path(data_dir, session_id, index),
                start_ms: start_frame.saturating_mul(1000) / sample_rate.max(1) as u64,
                end_ms: end_frame.saturating_mul(1000) / sample_rate.max(1) as u64,
            }
        })
        .collect()
}

fn chunk_byte_limit(sample_rate: u32, bytes_per_frame: usize) -> usize {
    let frames_per_chunk = sample_rate.max(1) as usize * 60;
    (frames_per_chunk * bytes_per_frame).max(bytes_per_frame)
}

fn duration_ms(frames: u64, sample_rate: u32) -> u64 {
    if sample_rate > 0 {
        frames.saturating_mul(1000) / sample_rate as u64
    } else {
        0
    }
}

/// One flush of the drive's own cache makes every chunk, and the renames
/// that installed them, durable together.
fn seal_chunks(
    data_dir: &Path,
    session_id: &str,
    chunks: &[RecordingAudioChunk],
) -> Result<(), RecordingError> {
    if let Some(last) = chunks.last() {
        File::open(&last.path)
            .and_then(|file| file.sync_all())
            .map_err(|error| RecordingError::WriteFailed {
                message: format!("sync recovered capture chunks: {error}"),
            })?;
    }
    if let Ok(directory) = File::open(session_audio_dir(data_dir, session_id)) {
        let _ = directory.sync_all();
    }
    Ok(())
}

/// Chunks past the end of what the journal holds can only be left from a
/// power loss that kept a live chunk the journal had not yet reached the
/// disk with. Nothing refers to them; they are this session's audio, so
/// they go.
fn remove_chunks_from(data_dir: &Path, session_id: &str, first_unused: usize) {
    let mut index = first_unused;
    loop {
        let path = session_audio_chunk_path(data_dir, session_id, index);
        match std::fs::remove_file(&path) {
            Ok(()) => index += 1,
            Err(_) => break,
        }
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

/// Recover a capture the app did not get to finish. For a current journal the
/// audio is already in its minute chunks and recovery makes them whole (see
/// `recover_streamed_capture_chunks`). An older journal holds the audio itself:
/// every complete encrypted record is read back into minute chunks. Either
/// way a partially written final record is ignored; authenticated-record
/// corruption fails closed. The journal is retained even after successful
/// recovery so the orchestration layer can commit its database and retention
/// indexes before deleting the last durable recovery source.
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
    if &magic == CAPTURE_JOURNAL_MAGIC_CHUNKS {
        return recover_streamed_capture_chunks(data_dir, session_id, key, sample_rate, channels);
    }
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
    let chunk_byte_limit = chunk_byte_limit(sample_rate, bytes_per_frame);
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
    remove_chunks_from(data_dir, session_id, audio_chunks.len());
    // One flush of the drive's own cache makes every chunk above, and the
    // renames that installed them, durable together. Flushing per chunk
    // (twice: file and directory) cost two full cache flushes a minute of
    // audio — over a second of "Finishing" for a two-hour recording. The
    // journal is kept until the caller has committed these chunks, so a
    // crash before this point recovers from the journal again.
    seal_chunks(data_dir, session_id, &audio_chunks)?;
    let duration_ms = duration_ms(captured_frames, sample_rate);
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

/// Recovers a capture whose audio went straight into its minute chunks (a
/// `VTCAPJ3` journal). The chunks are already in their final format; recovery
/// only has to make each one whole and index them.
///
/// - A record the crash cut short at the end of the last chunk is dropped and
///   the file truncated to the last whole record, so every reader sees a
///   well-formed chunk. A final record that is there in full but does not
///   authenticate is a write the crash tore, and is dropped the same way.
/// - A chunk short of a full minute with a later chunk after it can only come
///   from a power loss that kept a later write and lost an earlier one. The
///   missing stretch is gone either way; it is filled with silence so every
///   later chunk stays at its true time. A chunk whose file is missing
///   altogether before the last one becomes a minute of silence likewise.
/// - Anything else that fails to authenticate fails the recovery and leaves
///   every file as it was.
fn recover_streamed_capture_chunks(
    data_dir: &Path,
    session_id: &str,
    key: &SessionKey,
    sample_rate: u32,
    channels: u16,
) -> Result<RecoveredCaptureAudio, RecordingError> {
    let bytes_per_frame = channels.max(1) as usize * StoredSampleFormat::S16.bytes_per_sample();
    let minute_bytes = chunk_byte_limit(sample_rate, bytes_per_frame);
    // Every chunk this recording created, found by listing rather than by
    // counting up from zero: a power loss can drop the directory entry of one
    // minute and keep the next.
    let last_index = highest_chunk_index(data_dir, session_id);
    let mut chunk_count = 0_usize;
    let mut captured_frames = 0_u64;
    while let Some(last_index) = last_index {
        if chunk_count > last_index {
            break;
        }
        let path = session_audio_chunk_path(data_dir, session_id, chunk_count);
        let is_last = chunk_count == last_index;
        if !path.exists() {
            tracing::warn!(
                session_id,
                chunk = chunk_count,
                "capture chunk lost to a power loss; replacing it with a minute of silence"
            );
            append_silence(&path, key, minute_bytes)?;
        }
        let scan = scan_streamed_chunk(&path, key, bytes_per_frame, is_last)?;
        if scan.whole_bytes < scan.file_bytes {
            truncate_chunk(&path, scan.whole_bytes)?;
        }
        let mut plaintext_bytes = scan.plaintext_bytes;
        if !is_last && plaintext_bytes < minute_bytes {
            tracing::warn!(
                session_id,
                chunk = chunk_count,
                missing_bytes = minute_bytes - plaintext_bytes,
                "capture chunk lost its tail to a power loss; filling it with silence"
            );
            append_silence(&path, key, minute_bytes - plaintext_bytes)?;
            plaintext_bytes = minute_bytes;
        }
        if is_last && plaintext_bytes == 0 && chunk_count > 0 {
            // Opened for the next minute just before the crash, nothing in it.
            let _ = std::fs::remove_file(&path);
            break;
        }
        captured_frames =
            captured_frames.saturating_add((plaintext_bytes / bytes_per_frame) as u64);
        chunk_count += 1;
        if is_last {
            break;
        }
    }
    if chunk_count == 0 {
        encrypt_to_file(session_audio_chunk_path(data_dir, session_id, 0), key, &[]).map_err(
            |error| RecordingError::WriteFailed {
                message: format!("write empty capture chunk: {error}"),
            },
        )?;
        chunk_count = 1;
    }
    let audio_chunks = minute_chunk_index(
        data_dir,
        session_id,
        chunk_count,
        captured_frames,
        sample_rate,
        bytes_per_frame,
    );
    remove_chunks_from(data_dir, session_id, chunk_count);
    seal_chunks(data_dir, session_id, &audio_chunks)?;
    Ok(RecoveredCaptureAudio {
        session_id: session_id.to_string(),
        encrypted_path: audio_chunks[0].path.clone(),
        duration_ms: duration_ms(captured_frames, sample_rate),
        sample_rate,
        channels,
        captured_frames,
        sample_format: StoredSampleFormat::S16,
        audio_chunks,
    })
}

struct StreamedChunkScan {
    file_bytes: usize,
    /// Length of the prefix made of whole, authentic records.
    whole_bytes: usize,
    plaintext_bytes: usize,
}

fn scan_streamed_chunk(
    path: &Path,
    key: &SessionKey,
    bytes_per_frame: usize,
    is_last_chunk: bool,
) -> Result<StreamedChunkScan, RecordingError> {
    let data = std::fs::read(path).map_err(|error| RecordingError::JournalCorrupt {
        message: format!("read capture chunk {}: {error}", path.display()),
    })?;
    let mut offset = 0_usize;
    let mut plaintext_bytes = 0_usize;
    while offset < data.len() {
        let Some(length_bytes) = data.get(offset..offset + 4) else {
            break; // A length the crash cut short.
        };
        let length = u32::from_le_bytes(length_bytes.try_into().expect("four bytes")) as usize;
        if !(28..=MAX_CAPTURE_FRAME_BYTES + 64).contains(&length) {
            if is_last_chunk {
                break; // Unwritten tail space the crash left behind.
            }
            return Err(RecordingError::JournalCorrupt {
                message: format!("invalid record length {length} in {}", path.display()),
            });
        }
        let Some(record) = data.get(offset + 4..offset + 4 + length) else {
            break; // A record the crash cut short.
        };
        let ends_file = offset + 4 + length == data.len();
        match decrypt_chunk(record, key) {
            Ok(plaintext) => {
                if !plaintext.len().is_multiple_of(bytes_per_frame) {
                    return Err(RecordingError::JournalCorrupt {
                        message: "recovered audio is not frame-aligned".to_string(),
                    });
                }
                plaintext_bytes += plaintext.len();
                offset += 4 + length;
            }
            Err(_) if is_last_chunk && ends_file => break, // A torn final write.
            Err(error) => {
                return Err(RecordingError::JournalCorrupt {
                    message: format!("authenticate capture chunk {}: {error}", path.display()),
                })
            }
        }
    }
    Ok(StreamedChunkScan {
        file_bytes: data.len(),
        whole_bytes: offset,
        plaintext_bytes,
    })
}

fn truncate_chunk(path: &Path, length: usize) -> Result<(), RecordingError> {
    OpenOptions::new()
        .write(true)
        .open(path)
        .and_then(|file| file.set_len(length as u64))
        .map_err(|error| RecordingError::WriteFailed {
            message: format!("truncate capture chunk {}: {error}", path.display()),
        })
}

/// The highest `chunk.NNNNN.enc` index in the session's directory, if any.
fn highest_chunk_index(data_dir: &Path, session_id: &str) -> Option<usize> {
    std::fs::read_dir(session_audio_dir(data_dir, session_id))
        .ok()?
        .filter_map(|entry| {
            let name = entry.ok()?.file_name().into_string().ok()?;
            let digits = name.strip_prefix("chunk.")?.strip_suffix(".enc")?;
            (digits.len() == 5 && digits.bytes().all(|byte| byte.is_ascii_digit()))
                .then(|| digits.parse::<usize>().ok())
                .flatten()
        })
        .max()
}

fn append_silence(path: &Path, key: &SessionKey, bytes: usize) -> Result<(), RecordingError> {
    let mut file = OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .map_err(|error| RecordingError::WriteFailed {
            message: format!("open capture chunk {}: {error}", path.display()),
        })?;
    let silence = vec![0_u8; 64 * 1024];
    let mut remaining = bytes;
    while remaining > 0 {
        let take = remaining.min(silence.len());
        file.write_all(&sealed_record(&silence[..take], key)?)
            .map_err(|error| RecordingError::WriteFailed {
                message: format!("fill capture chunk {}: {error}", path.display()),
            })?;
        remaining -= take;
    }
    file.flush().map_err(|error| RecordingError::WriteFailed {
        message: error.to_string(),
    })
}

/// Passes a file's written data to the drive without waiting for the
/// drive's cache. On Apple platforms `File::sync_all` is `F_FULLFSYNC`, a full
/// cache flush; plain `fsync` is the cheap half, and one full flush after the
/// last chunk covers them all.
fn hand_to_drive(file: &File) -> std::io::Result<()> {
    #[cfg(unix)]
    {
        use std::os::fd::AsRawFd;
        // SAFETY: the descriptor is owned by `file` and stays open for the call.
        if unsafe { libc::fsync(file.as_raw_fd()) } == 0 {
            Ok(())
        } else {
            Err(std::io::Error::last_os_error())
        }
    }
    #[cfg(not(unix))]
    {
        file.sync_all()
    }
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
            hand_to_drive(&file).map_err(|error| RecordingError::WriteFailed {
                message: format!("sync recovered capture chunk: {error}"),
            })?;
        }
        if let Err(error) = std::fs::rename(&temporary, &path) {
            let _ = std::fs::remove_file(&temporary);
            return Err(RecordingError::WriteFailed {
                message: format!("install recovered capture chunk: {error}"),
            });
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
        assert_eq!(
            journal_bytes, CAPTURE_JOURNAL_MAGIC_CHUNKS,
            "the journal marks the capture and holds no audio of its own"
        );
        let chunk_bytes =
            std::fs::read(session_audio_chunk_path(tmp.path(), "capture-1", 0)).unwrap();
        assert!(
            !chunk_bytes
                .windows(64)
                .any(|window| s16.windows(64).any(|raw| raw == window)),
            "a chunk must never contain raw microphone PCM"
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

        let chunk = session_audio_chunk_path(tmp.path(), "capture-crash", 0);
        let whole = std::fs::metadata(&chunk).unwrap().len();
        let mut file = OpenOptions::new().append(true).open(&chunk).unwrap();
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
        assert_eq!(
            std::fs::metadata(&chunk).unwrap().len(),
            whole,
            "the cut-short record is truncated away, leaving a well-formed chunk"
        );
        assert_eq!(
            read_chunks(&recovered.audio_chunks, &SessionKey::from_bytes(key_bytes)).concat(),
            s16
        );
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

    fn read_chunks(chunks: &[RecordingAudioChunk], key: &SessionKey) -> Vec<Vec<u8>> {
        chunks
            .iter()
            .map(|chunk| {
                let mut plaintext = Vec::new();
                DecryptReader::new(&chunk.path, key)
                    .unwrap()
                    .read_to_end(&mut plaintext)
                    .unwrap();
                plaintext
            })
            .collect()
    }

    /// 2 minutes and 17 seconds at 100 Hz, pushed in 37-frame callbacks so
    /// pushes straddle every minute boundary; each sample is distinct.
    fn record_two_and_a_bit_minutes(journal: &CaptureAudioJournal) -> Vec<u8> {
        let total_frames = 100 * 137;
        let audio: Vec<u8> = (0..total_frames)
            .flat_map(|frame| (frame as i16).to_le_bytes())
            .collect();
        for push in audio.chunks(37 * 2) {
            journal.push_s16_pcm(push).unwrap();
        }
        audio
    }

    fn start_small(tmp: &TempDir, session: &str, key_bytes: [u8; 32]) -> CaptureAudioJournal {
        CaptureAudioJournal::start(
            session.to_string(),
            RecordingConfig {
                data_dir: tmp.path().to_path_buf(),
                sample_rate: 100,
                channels: 1,
            },
            SessionKey::from_bytes(key_bytes),
        )
        .unwrap()
    }

    #[test]
    fn minutes_written_during_recording_match_a_recovery_from_the_journal_exactly() {
        let tmp = TempDir::new().unwrap();
        let key_bytes = *SessionKey::generate().as_bytes();
        let journal = start_small(&tmp, "live", key_bytes);
        let audio = record_two_and_a_bit_minutes(&journal);
        let journal_path = journal.journal_path().to_path_buf();
        let result = journal.stop().unwrap();

        assert_eq!(result.duration_ms, 137_000);
        assert_eq!(result.audio_chunks.len(), 3);
        let live = read_chunks(&result.audio_chunks, &result.encryption_key);
        assert_eq!(live.concat(), audio, "no sample lost, moved or duplicated");

        // The journal is still the source of truth, and rebuilding from it
        // gives the same chunks, boundaries and bytes.
        let recovered = recover_capture_audio_journal(
            &journal_path,
            tmp.path(),
            "live",
            &result.encryption_key,
            100,
            1,
        )
        .unwrap();
        assert_eq!(recovered.audio_chunks, result.audio_chunks);
        assert_eq!(
            read_chunks(&recovered.audio_chunks, &result.encryption_key),
            live
        );
    }

    #[test]
    fn a_chunk_that_cannot_be_written_fails_the_push_and_keeps_what_came_before() {
        let tmp = TempDir::new().unwrap();
        let key_bytes = *SessionKey::generate().as_bytes();
        // A directory where the second minute's chunk must go makes opening
        // it fail at the minute boundary.
        let blocked = session_audio_chunk_path(tmp.path(), "blocked", 1);
        std::fs::create_dir_all(blocked.join("in-the-way")).unwrap();
        let journal = start_small(&tmp, "blocked", key_bytes);
        let first_minute: Vec<u8> = (0..6_000_i16).flat_map(i16::to_le_bytes).collect();
        journal.push_s16_pcm(&first_minute).unwrap();
        assert!(matches!(
            journal.push_s16_pcm(&[1, 0, 2, 0]),
            Err(RecordingError::WriteFailed { .. })
        ));
        let journal_path = journal.journal_path().to_path_buf();
        drop(journal);
        std::fs::remove_dir_all(&blocked).unwrap();

        let recovered = recover_capture_audio_journal(
            &journal_path,
            tmp.path(),
            "blocked",
            &SessionKey::from_bytes(key_bytes),
            100,
            1,
        )
        .unwrap();
        assert_eq!(recovered.audio_chunks.len(), 1);
        assert_eq!(
            read_chunks(&recovered.audio_chunks, &SessionKey::from_bytes(key_bytes)).concat(),
            first_minute
        );
    }

    #[test]
    fn a_chunk_beyond_what_the_journal_holds_is_removed_at_stop() {
        let tmp = TempDir::new().unwrap();
        let key_bytes = *SessionKey::generate().as_bytes();
        let journal = start_small(&tmp, "stray", key_bytes);
        let stray = session_audio_chunk_path(tmp.path(), "stray", 3);
        std::fs::write(&stray, b"left by a power loss").unwrap();
        record_two_and_a_bit_minutes(&journal);
        let result = journal.stop().unwrap();

        assert_eq!(result.audio_chunks.len(), 3);
        assert!(!stray.exists());
    }

    #[test]
    fn a_recording_shorter_than_a_minute_still_ends_in_one_chunk() {
        let tmp = TempDir::new().unwrap();
        let key_bytes = *SessionKey::generate().as_bytes();
        let journal = start_small(&tmp, "short", key_bytes);
        journal.push_s16_pcm(&[1, 0, 2, 0, 3, 0]).unwrap();
        let result = journal.stop().unwrap();
        assert_eq!(result.audio_chunks.len(), 1);
        assert_eq!(result.duration_ms, 30);
        assert_eq!(
            read_chunks(&result.audio_chunks, &result.encryption_key).concat(),
            [1, 0, 2, 0, 3, 0]
        );

        let silent = start_small(&tmp, "silent", key_bytes);
        let result = silent.stop().unwrap();
        assert_eq!(
            result.audio_chunks.len(),
            1,
            "an empty recording still has its chunk"
        );
        assert_eq!(result.duration_ms, 0);
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

    fn recover_small(
        tmp: &TempDir,
        session: &str,
        key_bytes: [u8; 32],
    ) -> Result<RecoveredCaptureAudio, RecordingError> {
        recover_capture_audio_journal(
            &session_capture_journal_path(tmp.path(), session),
            tmp.path(),
            session,
            &SessionKey::from_bytes(key_bytes),
            100,
            1,
        )
    }

    /// The point of the streaming chunks: a recording reaches the disk once.
    /// The journal stays a header, and the chunks hold the audio plus the
    /// per-record envelope (4 + 12 + 16 bytes per 100 ms push, 1%).
    #[test]
    fn a_recording_reaches_the_disk_once() {
        let tmp = TempDir::new().unwrap();
        let journal = CaptureAudioJournal::start(
            "once".to_string(),
            RecordingConfig {
                data_dir: tmp.path().to_path_buf(),
                sample_rate: 16_000,
                channels: 1,
            },
            SessionKey::generate(),
        )
        .unwrap();
        let push = vec![7_u8; 3_200]; // 100 ms, as the microphone delivers it
        let pushes = 1_500; // 2.5 minutes
        for _ in 0..pushes {
            journal.push_s16_pcm(&push).unwrap();
        }
        let journal_path = journal.journal_path().to_path_buf();
        let result = journal.stop().unwrap();

        let audio_bytes = (push.len() * pushes) as u64;
        assert_eq!(std::fs::metadata(&journal_path).unwrap().len(), 8);
        let stored: u64 = result
            .audio_chunks
            .iter()
            .map(|chunk| std::fs::metadata(&chunk.path).unwrap().len())
            .sum();
        assert!(stored >= audio_bytes);
        assert!(
            stored <= audio_bytes + audio_bytes / 100 + 64,
            "stored {stored} bytes for {audio_bytes} bytes of audio"
        );
        let files: Vec<_> = std::fs::read_dir(session_audio_dir(tmp.path(), "once"))
            .unwrap()
            .map(|entry| entry.unwrap().file_name().into_string().unwrap())
            .collect();
        assert_eq!(
            files.len(),
            4,
            "three chunks and the journal, nothing else: {files:?}"
        );
        assert_eq!(result.audio_chunks.len(), 3);
        assert_eq!(result.duration_ms, 150_000);
        assert_eq!(
            read_chunks(&result.audio_chunks, &result.encryption_key)
                .concat()
                .len() as u64,
            audio_bytes
        );
    }

    #[test]
    fn a_crash_mid_recording_recovers_every_pushed_frame_at_its_time() {
        let tmp = TempDir::new().unwrap();
        let key_bytes = *SessionKey::generate().as_bytes();
        let journal = start_small(&tmp, "crash", key_bytes);
        let audio = record_two_and_a_bit_minutes(&journal);
        drop(journal); // No stop: the process died.

        let recovered = recover_small(&tmp, "crash", key_bytes).unwrap();
        assert_eq!(recovered.captured_frames, 13_700);
        assert_eq!(recovered.duration_ms, 137_000);
        let bounds: Vec<_> = recovered
            .audio_chunks
            .iter()
            .map(|chunk| (chunk.start_ms, chunk.end_ms))
            .collect();
        assert_eq!(bounds, [(0, 60_000), (60_000, 120_000), (120_000, 137_000)]);
        assert_eq!(
            read_chunks(&recovered.audio_chunks, &SessionKey::from_bytes(key_bytes)).concat(),
            audio
        );
    }

    #[test]
    fn a_torn_final_write_is_dropped_and_the_chunk_left_readable() {
        let tmp = TempDir::new().unwrap();
        let key_bytes = *SessionKey::generate().as_bytes();
        let journal = start_small(&tmp, "torn", key_bytes);
        let audio = record_two_and_a_bit_minutes(&journal);
        drop(journal);
        // The last write reached the file at full length, but its bytes did
        // not: it fails to authenticate.
        let last = session_audio_chunk_path(tmp.path(), "torn", 2);
        let whole = std::fs::metadata(&last).unwrap().len();
        let mut file = OpenOptions::new().append(true).open(&last).unwrap();
        file.write_all(&60_u32.to_le_bytes()).unwrap();
        file.write_all(&[0_u8; 60]).unwrap();
        drop(file);

        let recovered = recover_small(&tmp, "torn", key_bytes).unwrap();
        assert_eq!(std::fs::metadata(&last).unwrap().len(), whole);
        assert_eq!(
            read_chunks(&recovered.audio_chunks, &SessionKey::from_bytes(key_bytes)).concat(),
            audio
        );
    }

    #[test]
    fn a_lost_tail_in_an_earlier_minute_is_filled_with_silence_and_later_minutes_keep_their_time() {
        let tmp = TempDir::new().unwrap();
        let key_bytes = *SessionKey::generate().as_bytes();
        let journal = start_small(&tmp, "gap", key_bytes);
        let audio = record_two_and_a_bit_minutes(&journal);
        drop(journal);
        // A power loss kept minute two but not the end of minute one.
        let first = session_audio_chunk_path(tmp.path(), "gap", 0);
        let length = std::fs::metadata(&first).unwrap().len();
        OpenOptions::new()
            .write(true)
            .open(&first)
            .unwrap()
            .set_len(length / 2)
            .unwrap();

        let recovered = recover_small(&tmp, "gap", key_bytes).unwrap();
        assert_eq!(recovered.captured_frames, 13_700, "the timeline is intact");
        let chunks = read_chunks(&recovered.audio_chunks, &SessionKey::from_bytes(key_bytes));
        assert_eq!(chunks[0].len(), 12_000, "minute one is a full minute again");
        assert!(
            chunks[0].ends_with(&[0, 0, 0, 0]),
            "its lost tail is silence"
        );
        assert_eq!(chunks[0][..2], audio[..2], "what survived is unchanged");
        assert_eq!(chunks[1], audio[12_000..24_000], "minute two is untouched");
        assert_eq!(chunks[2], audio[24_000..]);
    }

    #[test]
    fn a_minute_whose_file_vanished_becomes_silence_and_later_minutes_are_kept() {
        let tmp = TempDir::new().unwrap();
        let key_bytes = *SessionKey::generate().as_bytes();
        let journal = start_small(&tmp, "vanished", key_bytes);
        let audio = record_two_and_a_bit_minutes(&journal);
        drop(journal);
        // A power loss dropped minute two's directory entry, kept minute three.
        std::fs::remove_file(session_audio_chunk_path(tmp.path(), "vanished", 1)).unwrap();

        let recovered = recover_small(&tmp, "vanished", key_bytes).unwrap();
        assert_eq!(recovered.audio_chunks.len(), 3);
        assert_eq!(recovered.captured_frames, 13_700);
        let chunks = read_chunks(&recovered.audio_chunks, &SessionKey::from_bytes(key_bytes));
        assert_eq!(chunks[0], audio[..12_000]);
        assert!(chunks[1].iter().all(|byte| *byte == 0) && chunks[1].len() == 12_000);
        assert_eq!(
            chunks[2],
            audio[24_000..],
            "the minute after the gap is kept"
        );
    }

    #[test]
    fn corruption_inside_a_recording_fails_recovery_and_changes_nothing() {
        let tmp = TempDir::new().unwrap();
        let key_bytes = *SessionKey::generate().as_bytes();
        let journal = start_small(&tmp, "corrupt", key_bytes);
        record_two_and_a_bit_minutes(&journal);
        drop(journal);
        let middle = session_audio_chunk_path(tmp.path(), "corrupt", 1);
        let mut bytes = std::fs::read(&middle).unwrap();
        let at = bytes.len() / 2;
        bytes[at] ^= 0xFF;
        std::fs::write(&middle, &bytes).unwrap();
        let before: Vec<_> = (0..3)
            .map(|index| {
                std::fs::read(session_audio_chunk_path(tmp.path(), "corrupt", index)).unwrap()
            })
            .collect();

        assert!(matches!(
            recover_small(&tmp, "corrupt", key_bytes),
            Err(RecordingError::JournalCorrupt { .. })
        ));
        let after: Vec<_> = (0..3)
            .map(|index| {
                std::fs::read(session_audio_chunk_path(tmp.path(), "corrupt", index)).unwrap()
            })
            .collect();
        assert_eq!(before, after);
    }

    #[test]
    fn a_crash_on_a_minute_boundary_leaves_no_empty_chunk() {
        let tmp = TempDir::new().unwrap();
        let key_bytes = *SessionKey::generate().as_bytes();
        let journal = start_small(&tmp, "edge", key_bytes);
        let two_minutes: Vec<u8> = (0..12_000_i16).flat_map(i16::to_le_bytes).collect();
        journal.push_s16_pcm(&two_minutes).unwrap();
        drop(journal);
        // The next minute's chunk was created a moment before the crash.
        std::fs::write(session_audio_chunk_path(tmp.path(), "edge", 2), b"").unwrap();

        let recovered = recover_small(&tmp, "edge", key_bytes).unwrap();
        assert_eq!(recovered.audio_chunks.len(), 2);
        assert_eq!(recovered.duration_ms, 120_000);
        assert!(!session_audio_chunk_path(tmp.path(), "edge", 2).exists());

        // Stopping exactly on the boundary ends with two chunks as well.
        let journal = start_small(&tmp, "edge-stop", key_bytes);
        journal.push_s16_pcm(&two_minutes).unwrap();
        let result = journal.stop().unwrap();
        assert_eq!(result.audio_chunks.len(), 2);
        assert!(!session_audio_chunk_path(tmp.path(), "edge-stop", 2).exists());
    }
}
