//! Zulangue STT 层
//!
//! Fixed Notebook capture engine contract + Soniox v5 WebSocket clients.
//! 设计文档：docs/design/D1-soniox-protocol.md
//! 权威 trait 签名：docs/architecture/TYPE_SYSTEM.md §2

pub mod capture_engine;
pub mod config;
pub mod error;
pub mod soniox_rt;
pub mod soniox_stream;

pub use capture_engine::{
    NotebookCaptureEngine, PostStopExecution, CURRENT_NOTEBOOK_CAPTURE_ENGINE,
};
pub use config::{ConnectionStatus, ContextConfig, SttConfig, TranslationConfig};
pub use error::{SonioxQuotaKind, SttError};
pub use soniox_rt::SonioxRtClient;
pub use soniox_stream::{
    soniox_stream_context_json, SonioxStreamClient, SonioxStreamRuntime, SttStreamControl,
    SttStreamError, SttStreamEvent, SttStreamProviderError, SttStreamToken,
    SttStreamTranslationStatus,
};
