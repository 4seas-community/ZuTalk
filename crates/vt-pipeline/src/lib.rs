//! Zulangue 管道编排层
//!
//! Notebook capture support, explicit async tasks, and session state.
//! 录音与转录的职责划分见 docs/architecture/ARCHITECTURE.md「录音与转录」。

pub mod import;
pub mod privacy;
pub mod recording;
pub mod task_queue;

pub use import::{import_audio_file, ImportError, ImportResult};
pub use privacy::{DestroyError, PrivacyDestroyer};
pub use recording::{
    legacy_session_audio_chunk_path, recover_capture_audio_journal,
    require_session_id_path_component, session_audio_chunk_path, session_audio_dir,
    session_capture_journal_path, write_encrypted_audio_chunks, CaptureAudioJournal,
    RecordingAudioChunk, RecordingConfig, RecordingError, RecordingResult, RecoveredCaptureAudio,
    SESSION_AUDIO_ROOT_DIR,
};
pub use task_queue::{
    RemoteTaskAuthorization, Task, TaskInfo, TaskPayload, TaskPriority, TaskQueue, TaskQueueError,
    TaskStatus,
};
