//! Zulangue STT 层
//!
//! Fixed Notebook capture engine contract + Soniox v5 WebSocket clients.
//! 分层职责见 docs/architecture/ARCHITECTURE.md「代码边界」。

pub mod capture_engine;
pub mod config;
pub mod error;
pub mod soniox_async;
pub mod soniox_rt;
pub mod soniox_stream;

pub use capture_engine::{
    NotebookCaptureEngine, PostStopExecution, CURRENT_NOTEBOOK_CAPTURE_ENGINE,
};
pub use config::{ConnectionStatus, ContextConfig, SttConfig, TranslationConfig};
pub use error::{SonioxQuotaKind, SttError};
pub use soniox_async::{
    delete_remote_file as soniox_async_delete_remote_file,
    delete_remote_transcription as soniox_async_delete_remote_transcription,
    list_remote_files as soniox_async_list_remote_files,
    list_remote_transcriptions as soniox_async_list_remote_transcriptions,
    transcribe_wav as soniox_async_transcribe_wav, wrap_pcm_s16le_in_wav,
    SonioxAsyncArtifactObserver, SonioxAsyncRequest, SonioxRemoteEndpoint,
    SonioxRemoteInventoryEntry, SONIOX_ASYNC_POLL_INTERVAL,
};
pub use soniox_rt::SonioxRtClient;
pub use soniox_stream::{
    soniox_stream_context_json, BoxedCredentialFuture, LaneCredentialSource, SonioxStreamClient,
    SonioxStreamRuntime, StaticLaneCredential, SttStreamControl, SttStreamError, SttStreamEvent,
    SttStreamProviderError, SttStreamToken, SttStreamTranslationStatus,
};
