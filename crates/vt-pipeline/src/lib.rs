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
    recover_capture_audio_journal, write_encrypted_audio_chunks, CaptureAudioJournal,
    RecordingAudioChunk, RecordingConfig, RecordingError, RecordingResult, RecoveredCaptureAudio,
};
pub use task_queue::{
    RemoteTaskAuthorization, Task, TaskInfo, TaskPayload, TaskPriority, TaskQueue, TaskQueueError,
    TaskStatus,
};
