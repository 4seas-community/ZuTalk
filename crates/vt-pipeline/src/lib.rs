//! Zulangue 管道编排层
//!
//! Notebook capture support, explicit async tasks, and session state.
//! 设计文档：docs/design/D3-pipeline-state.md

pub mod import;
pub mod privacy;
pub mod recording;
pub mod task_queue;

pub use import::{import_audio_file, ImportError, ImportResult};
pub use privacy::{
    AudioRetentionChunkPlan, AudioRetentionMode, AudioRetentionPlan, AudioRetentionPolicy,
    DestroyError, DestroyResult, KeyDestroyer, PrivacyDestroyer,
};
pub use recording::{
    recover_capture_audio_journal, write_encrypted_audio_chunks, CaptureAudioJournal,
    RecordingAudioChunk, RecordingConfig, RecordingError, RecordingResult, RecoveredCaptureAudio,
};
pub use task_queue::{
    RemoteTaskAuthorization, Task, TaskInfo, TaskPayload, TaskPriority, TaskQueue, TaskQueueError,
    TaskStatus,
};
