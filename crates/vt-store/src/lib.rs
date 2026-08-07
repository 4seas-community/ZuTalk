//! Zulangue 存储层
//!
//! SQLite (rusqlite) + Loro CRDT 文档存储 + 文件系统管理。
//! SQLite 事实与 Loro 可编辑投影的所有权划分见
//! docs/architecture/ARCHITECTURE.md「转录编辑所有权」。

pub mod context_pack_store;
pub mod document_schema;
pub mod editor_bridge;
pub mod migration;
pub mod notebook_capture_store;
pub mod notebook_store;
pub mod search;
pub mod session_meta;
pub mod session_query;

pub use context_pack_store::{
    BoundContextPack, ContextCompilation, ContextContentKind, ContextOmission,
    ContextOmissionReason, ContextPackDocument, ContextPackDocumentSource, ContextPackRecord,
    ContextPackScope, ContextPackSourceRecord, ContextPackStore, ContextPackStoreError,
    ContextReceipt, ContextReceiptSource, ContextSourceFormat, NewContextSource, SonioxContext,
    SonioxGeneralContext, SonioxTranslationTerm, CONTEXT_CSV_MAX_CELL_SCALARS,
    CONTEXT_CSV_MAX_ROWS, CONTEXT_PACK_DOCUMENT_MAX_BYTES, CONTEXT_PACK_DOCUMENT_SCHEMA,
    CONTEXT_TEXT_MAX_BYTES, SONIOX_CONTEXT_MAX_SCALARS,
};
pub use editor_bridge::{EditOp, EditorBridge, EditorBridgeError, EditorEvent, EditorHandle};
pub use notebook_capture_store::{
    AsyncProjectionState, AsyncProviderReceipt, AsyncSearchProjectionState, AsyncTaskState,
    CaptureMode, CaptureState, NewNotebookCaptureRun, NewRealtimeTranslationInboxItem,
    NewRealtimeUtterance, NotebookCaptureProfile, NotebookCaptureProfileUpdate, NotebookCaptureRun,
    NotebookCaptureStore, NotebookCaptureStoreError, NotebookProjectionMutation, Participant,
    ProjectionMutationState, ProjectionPurgeTarget, ProjectionState, ProviderFailure,
    ProviderRemoteArtifactClaim, RealtimeTranscriptGap, RealtimeTranslationInboxBinding,
    RealtimeTranslationInboxItem, RealtimeTranslationInboxKey, RealtimeTranslationInboxPersistence,
    RealtimeTranslationLaneUpdate, RealtimeUtterance, RealtimeUtteranceVariant, RemoteHealth,
    SessionPurgeJob, SessionPurgePlan, SessionSpeaker, UtteranceAlignment, UtteranceCompletion,
    UtteranceLane, UtteranceVariantRole, UtteranceVariantState,
};
pub use notebook_store::{
    BuiltinNotebookTab, NotebookRecord, NotebookSessionLinkRecord, NotebookSessionProjectionRecord,
    NotebookStore, NotebookStoreError, NotebookTabRecord,
};
pub use search::{RealtimeSearchProjectionOutcome, SearchResult, SearchStore, SearchStoreError};
pub use session_meta::{
    AudioChunkRetentionRecord, AudioRetentionCounts, SessionMeta, SessionMetaError,
    SessionMetaStore,
};
pub use session_query::{
    QueryResult, SessionQuery, SessionQueryError, SessionQueryStore, SessionRecord, SortField,
    SortOrder, TrashFilter,
};
