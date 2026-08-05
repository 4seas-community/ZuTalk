//! Zulangue FFI 层
//!
//! UniFFI 绑定（Rust ↔ Swift 唯一通道）。proc-macro 模式。
//! 设计文档：docs/design/D5-uniffi-api.md
//! 权威 API 定义：docs/architecture/TYPE_SYSTEM.md §7

pub(crate) mod capture_erasure;
pub mod editor_api;
pub mod lane_credential_api;
pub mod notebook_api;
pub mod notebook_capture_api;
pub mod session_audio_api;
pub mod settings_api;
pub mod speaker_directory_api;
pub(crate) mod task_worker;
pub mod transcribe_api;

uniffi::setup_scaffolding!();

use std::cell::Cell;
use std::collections::{HashMap, HashSet};
use std::fs::File;
use std::os::fd::AsRawFd;
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use notebook_capture_api::{ActiveNotebookCapture, RealNotebookSonioxStreamFactory};
use vt_crypto::{
    ApiKeyProvider, CryptoError, FileKeyStore, KeyProvider, MemoryApiKeyStore, SessionKey, KEY_SIZE,
};
use vt_pipeline::{RecordingAudioChunk, TaskQueue};

use crate::transcribe_api::FfiTaskCallback;

/// 回调注册表: task_id → callback
/// worker 执行任务时查表找到对应 callback 上报进度 / 完成 / 错误。
/// 任务终止(complete/failed max_retries)时移除条目。
pub(crate) type TaskCallbackMap = Mutex<HashMap<String, Arc<dyn FfiTaskCallback>>>;

thread_local! {
    static FORCE_PROCESS_TEST_SECRET_STORES: Cell<bool> = const { Cell::new(false) };
    static DEFER_PROVIDER_CREDENTIAL_BOOTSTRAP: Cell<bool> = const { Cell::new(false) };
}

type ProcessTestSecretStores = Mutex<HashMap<String, HashMap<String, Vec<u8>>>>;

struct ProcessTestKeyStore {
    namespace: String,
}

impl ProcessTestKeyStore {
    fn new(path: &Path) -> Self {
        Self {
            namespace: secret_material_namespace(path),
        }
    }

    fn stores() -> &'static ProcessTestSecretStores {
        static STORES: OnceLock<ProcessTestSecretStores> = OnceLock::new();
        STORES.get_or_init(|| Mutex::new(HashMap::new()))
    }
}

impl KeyProvider for ProcessTestKeyStore {
    fn create_session_key(&self, session_id: &uuid::Uuid) -> Result<String, CryptoError> {
        let key = SessionKey::generate();
        let key_ref = format!("zulangue.audio.{session_id}");
        self.store_key(&key_ref, &key)?;
        Ok(key_ref)
    }

    fn load_key(&self, key_ref: &str) -> Result<SessionKey, CryptoError> {
        let stores = Self::stores().lock().unwrap();
        let namespace = stores
            .get(&self.namespace)
            .ok_or(CryptoError::KeyNotFound {
                key_ref: key_ref.to_string(),
            })?;
        let bytes = namespace.get(key_ref).ok_or(CryptoError::KeyNotFound {
            key_ref: key_ref.to_string(),
        })?;
        if bytes.len() != KEY_SIZE {
            return Err(CryptoError::InvalidKeyLength {
                expected: KEY_SIZE,
                actual: bytes.len(),
            });
        }
        let mut key = [0u8; KEY_SIZE];
        key.copy_from_slice(bytes);
        Ok(SessionKey::from_bytes(key))
    }

    fn store_key(&self, key_ref: &str, key: &SessionKey) -> Result<(), CryptoError> {
        let mut stores = Self::stores().lock().unwrap();
        stores
            .entry(self.namespace.clone())
            .or_default()
            .insert(key_ref.to_string(), key.as_bytes().to_vec());
        Ok(())
    }

    fn delete_key(&self, key_ref: &str) -> Result<(), CryptoError> {
        let mut stores = Self::stores().lock().unwrap();
        if let Some(namespace) = stores.get_mut(&self.namespace) {
            namespace.remove(key_ref);
        }
        Ok(())
    }

    fn key_exists(&self, key_ref: &str) -> bool {
        Self::stores()
            .lock()
            .unwrap()
            .get(&self.namespace)
            .is_some_and(|namespace| namespace.contains_key(key_ref))
    }
}

fn secret_material_namespace(path: &Path) -> String {
    path.canonicalize()
        .unwrap_or_else(|_| path.to_path_buf())
        .to_string_lossy()
        .into_owned()
}

fn acquire_data_dir_lock(path: &Path) -> Result<File, CoreError> {
    use std::io::{Seek, SeekFrom, Write};

    let lock_path = path.join(".zulangue-core.lock");
    let mut file = std::fs::OpenOptions::new()
        .create(true)
        .read(true)
        .write(true)
        .truncate(false)
        .mode(0o600)
        .open(&lock_path)
        .map_err(|error| CoreError::InitFailed {
            message: format!("open data directory lock: {error}"),
        })?;
    let result = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
    if result != 0 {
        return Err(CoreError::InitFailed {
            message: "Zulangue data directory is already owned by another app process".to_string(),
        });
    }
    file.set_len(0).map_err(|error| CoreError::InitFailed {
        message: format!("reset data directory lock: {error}"),
    })?;
    file.seek(SeekFrom::Start(0))
        .and_then(|_| writeln!(file, "{}", std::process::id()))
        .and_then(|_| file.sync_data())
        .map_err(|error| CoreError::InitFailed {
            message: format!("persist data directory lock owner: {error}"),
        })?;
    Ok(file)
}

use vt_store::context_pack_store::ContextPackStore;
use vt_store::notebook_capture_store::NotebookCaptureStore;
use vt_store::{
    EditorBridge, NotebookStore, SearchStore, SessionMeta, SessionMetaStore, SessionQueryStore,
    SessionRecord,
};

/// 初始化 tracing_subscriber,输出到 `<data_dir>/logs/rust.log`。
///
/// 之所以不写 stderr: macOS GUI app(`.app` bundle + `open`)的 stderr
/// 不被 launchd/Console.app 捕获,导致线上诊断完全盲视(看不到 Soniox
/// 原文、看不到 recv_handle 是否在跑)。文件日志则 `tail -f` 就能实时跟。
/// 打不开文件时兜底 stderr(tests / 命令行情况)。
///
/// 重复调用安全(tests 会多次 new ZulangueCore)。
fn init_tracing_once(data_dir: &std::path::Path) {
    use std::sync::Once;
    static INIT: Once = Once::new();
    INIT.call_once(|| {
        use std::fs::OpenOptions;
        use std::sync::Mutex;
        use tracing_subscriber::{fmt, fmt::writer::BoxMakeWriter, EnvFilter};

        let filter = EnvFilter::try_from_default_env().unwrap_or_else(|_| {
            // loro 内部 export{mode=Snapshot} diagnostics 会在每次落盘打 8 行 INFO,
            // 把 editor_trace 等真正信号淹没 —— 压到 warn。
            EnvFilter::new("info,hyper=warn,reqwest=warn,h2=warn,loro=warn")
        });

        let log_dir = data_dir.join("logs");
        let _ = std::fs::create_dir_all(&log_dir);
        let log_path = log_dir.join("rust.log");

        let (writer, opened): (BoxMakeWriter, bool) =
            match OpenOptions::new().create(true).append(true).open(&log_path) {
                Ok(file) => (BoxMakeWriter::new(Mutex::new(file)), true),
                Err(_) => (BoxMakeWriter::new(std::io::stderr), false),
            };

        let ok = fmt()
            .with_env_filter(filter)
            .with_writer(writer)
            .with_target(false)
            .with_thread_ids(false)
            .with_ansi(false)
            .try_init()
            .is_ok();

        if ok {
            if opened {
                tracing::info!("[init] tracing → {}", log_path.display());
            } else {
                tracing::warn!(
                    "[init] log file open failed ({}); falling back to stderr",
                    log_path.display()
                );
            }
        }
    });
}

fn privacy_default_path(data_dir: &std::path::Path) -> PathBuf {
    data_dir.join("privacy_default")
}

fn load_privacy_default(data_dir: &std::path::Path) -> Result<String, CoreError> {
    let path = privacy_default_path(data_dir);
    if !path.exists() {
        return Ok("standard".to_string());
    }
    let value = std::fs::read_to_string(&path).map_err(|e| CoreError::InitFailed {
        message: format!("read privacy default: {e}"),
    })?;
    let value = value.trim();
    if matches!(value, "standard" | "high" | "maximum") {
        Ok(value.to_string())
    } else {
        Ok("standard".to_string())
    }
}

fn persist_privacy_default(data_dir: &std::path::Path, level: &str) -> Result<(), CoreError> {
    std::fs::write(privacy_default_path(data_dir), format!("{level}\n")).map_err(|e| {
        CoreError::InternalError {
            message: format!("write privacy default: {e}"),
        }
    })
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FfiProviderConnectionStatus {
    Ready,
    InvalidCredential,
    OrganizationBalanceExhausted,
    OrganizationMonthlyBudgetExhausted,
    ProjectMonthlyBudgetExhausted,
    QuotaExhausted,
    NetworkUnavailable,
    RateLimited,
    ServiceUnavailable,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiProviderConnectionCheck {
    pub status: FfiProviderConnectionStatus,
    pub checked_at_ms: u64,
}

fn provider_connection_check(
    result: Result<(), vt_stt::SttError>,
    checked_at_ms: u64,
) -> FfiProviderConnectionCheck {
    use vt_stt::{SonioxQuotaKind, SttError};

    let status = match result {
        Ok(()) => FfiProviderConnectionStatus::Ready,
        Err(SttError::AuthFailed { .. })
        | Err(SttError::ApiError {
            status: 401 | 403, ..
        }) => FfiProviderConnectionStatus::InvalidCredential,
        Err(SttError::QuotaExhausted { kind, .. }) => match kind {
            SonioxQuotaKind::OrganizationBalance => {
                FfiProviderConnectionStatus::OrganizationBalanceExhausted
            }
            SonioxQuotaKind::OrganizationMonthlyBudget => {
                FfiProviderConnectionStatus::OrganizationMonthlyBudgetExhausted
            }
            SonioxQuotaKind::ProjectMonthlyBudget => {
                FfiProviderConnectionStatus::ProjectMonthlyBudgetExhausted
            }
            SonioxQuotaKind::Other => FfiProviderConnectionStatus::QuotaExhausted,
        },
        Err(SttError::ApiError { status: 402, .. }) => FfiProviderConnectionStatus::QuotaExhausted,
        Err(SttError::RateLimited) | Err(SttError::ApiError { status: 429, .. }) => {
            FfiProviderConnectionStatus::RateLimited
        }
        Err(
            SttError::ConnectionFailed(_) | SttError::ReadTimeout(_) | SttError::Timeout { .. },
        ) => FfiProviderConnectionStatus::NetworkUnavailable,
        Err(_) => FfiProviderConnectionStatus::ServiceUnavailable,
    };

    FfiProviderConnectionCheck {
        status,
        checked_at_ms,
    }
}

/// Zulangue 核心入口
#[derive(uniffi::Object)]
pub struct ZulangueCore {
    /// Held for the full lifetime of the core. It must be acquired before any
    /// startup recovery so a second app process cannot steal capture/task
    /// ownership from the first.
    _data_dir_lock: File,
    data_dir: PathBuf,
    editor_bridge: EditorBridge,
    pub(crate) runtime: tokio::runtime::Runtime,
    pub(crate) session_store: SessionQueryStore,
    search_store: SearchStore,
    pub(crate) session_meta: SessionMetaStore,
    pub(crate) notebook_store: NotebookStore,
    pub(crate) notebook_capture_store: NotebookCaptureStore,
    pub(crate) context_pack_store: ContextPackStore,
    /// doc_id → FfiEditorCallback。replace_document 等外部更新成功后
    /// 查表通知 Swift（用户路径不通知——Swift 自己是事件源，再回灌会造成
    /// 全量 setAttributedString + 光标抖动 + 主线程卡顿）。
    pub(crate) editor_callbacks:
        Arc<Mutex<HashMap<String, Arc<dyn crate::editor_api::FfiEditorCallback>>>>,
    /// Installed while a community invitation is the credential source. When
    /// present, capture lanes ask the app for a single-use key per
    /// connection instead of reading one saved key from the store.
    pub(crate) lane_credential_broker:
        Arc<Mutex<Option<Arc<crate::lane_credential_api::LaneCredentialBroker>>>>,
    /// 待写盘的 editor session 集合。apply_edit 只 enqueue，后台 flusher
    /// 每 ~500ms drain 一次。这样单字符输入不再每次都阻塞主线程做 fs::write,
    /// 同一 session 连敲也只合并成一次 snapshot 写入。
    pub(crate) pending_snapshot_saves: Arc<Mutex<HashSet<String>>>,
    pub(crate) task_queue: Arc<TaskQueue>,
    /// Session-scoped cancellation/late-writer barrier used by Delete Forever.
    pub(crate) session_task_registry: Arc<task_worker::SessionTaskRegistry>,
    /// worker 循环的 cancel token; shutdown 时触发
    worker_cancel: tokio_util::sync::CancellationToken,
    /// The worker is spawned during construction but cannot claim any durable
    /// task until this one-shot bootstrap gate is complete.
    provider_credential_bootstrap: Arc<task_worker::ProviderCredentialBootstrapGate>,
    /// task_id → FfiTaskCallback (worker 按 task 进度触发回调)
    pub(crate) task_callbacks: Arc<TaskCallbackMap>,
    /// Durable local encryption keys for capture audio and Context Packs.
    pub(crate) key_store: Arc<dyn KeyProvider>,
    /// Soniox API Key 的进程内运行时；生产固定使用
    /// MemoryApiKeyStore。Swift 的本机私有文件负责跨启动持久化，并通过
    /// `set_api_key` 在启动时注入。
    /// Swift 通过 `set_api_key` / `has_api_key` / `clear_api_key` FFI 操作,
    /// get 只内部使用(不跨 FFI 暴露明文)。
    pub(crate) api_key_store: Arc<dyn ApiKeyProvider>,
    /// The single mutable Notebook capture runtime. Floating and Caption Mirror
    /// surfaces are read-only and never receive this handle.
    pub(crate) active_notebook_capture: Mutex<Option<ActiveNotebookCapture>>,
    /// Runs whose in-process owner and provider runtime were torn down, but
    /// whose neutral durable recovery was temporarily blocked. Only IDs
    /// observed by this process are retried before its next capture start, so
    /// a second process can never steal a genuinely active database owner.
    pub(crate) detached_notebook_capture_runs: Mutex<HashSet<String>>,
    /// Internal construction/send seam for Notebook Soniox streaming. The
    /// production core always uses the real implementation; unit tests replace
    /// it only to prove privacy-off paths perform zero remote operations.
    pub(crate) notebook_soniox_stream_factory:
        Arc<dyn notebook_capture_api::NotebookSonioxStreamFactory>,
    /// Serializes ownership publication/removal for the single capture runtime.
    pub(crate) capture_ownership_gate: Mutex<()>,
    /// 默认隐私等级（"standard" | "high" | "maximum"）
    /// 应用到新建的 session，可用 set_privacy_default 修改
    default_privacy_level: Mutex<String>,
}

impl ZulangueCore {
    pub(crate) fn ensure_capture_ownership_available(&self) -> Result<(), CoreError> {
        if let Some((session_id, notebook_id)) = self
            .active_notebook_capture
            .lock()
            .unwrap()
            .as_ref()
            .map(|active| (active.session_id.clone(), active.notebook_id.clone()))
        {
            return Err(CoreError::ValidationFailed {
                message: format!(
                    "capture_already_active: Notebook capture session {session_id} belongs to notebook {notebook_id}"
                ),
            });
        }
        Ok(())
    }

    pub(crate) fn privacy_level_for_session(&self, session_id: &str) -> Result<String, CoreError> {
        let meta =
            self.session_meta
                .get_meta(session_id)
                .map_err(|_| {
                    CoreError::ValidationFailed {
                message:
                    "privacy_state_unavailable: session privacy metadata is missing or unreadable"
                        .to_string(),
            }
                })?;
        validate_frozen_session_privacy_level(meta.privacy_level)
    }

    pub(crate) fn ensure_remote_provider_allowed_for_session(
        &self,
        session_id: &str,
        provider: &str,
    ) -> Result<(), CoreError> {
        let privacy_level = self.privacy_level_for_session(session_id)?;
        ensure_remote_provider_allowed(&privacy_level, provider)
    }

    fn build_secret_material_stores(
        path: &std::path::Path,
    ) -> Result<Arc<dyn KeyProvider>, CoreError> {
        #[cfg(test)]
        {
            Self::build_process_test_secret_material_stores(path)
        }

        #[cfg(not(test))]
        {
            if FORCE_PROCESS_TEST_SECRET_STORES.with(|flag| flag.get()) {
                return Self::build_process_test_secret_material_stores(path);
            }

            Self::build_production_secret_material_stores(path)
        }
    }

    fn build_production_secret_material_stores(
        path: &std::path::Path,
    ) -> Result<Arc<dyn KeyProvider>, CoreError> {
        // Zulangue treats the signed-in Mac as the local trust boundary. Keep
        // durable capture/Context keys in the app-private Secrets directory.
        let secrets_dir = path.join("Secrets");
        let key_store = Arc::new(
            FileKeyStore::new(secrets_dir.join("content-keys.json")).map_err(|error| {
                CoreError::InitFailed {
                    message: format!("local content key store: {error}"),
                }
            })?,
        );
        let key_provider: Arc<dyn KeyProvider> = key_store;
        Ok(key_provider)
    }

    fn build_process_test_secret_material_stores(
        path: &std::path::Path,
    ) -> Result<Arc<dyn KeyProvider>, CoreError> {
        Ok(Arc::new(ProcessTestKeyStore::new(path)))
    }

    /// Creates the durable catalogue row owned by a Notebook capture run.
    /// Import has a separate receipt-backed constructor and never enters here.
    #[cfg(test)]
    pub(crate) fn create_notebook_capture_session(&self) -> Result<SessionInfo, CoreError> {
        let id = uuid::Uuid::new_v4().to_string();
        let record = SessionRecord {
            id: id.clone(),
            title: String::new(),
            session_type: "recording".to_string(),
            status: "recording".to_string(),
            duration_ms: 0,
            created_at: chrono::Utc::now().format("%Y-%m-%d %H:%M:%S").to_string(),
            deleted_at: None,
        };
        self.session_store
            .insert_session(&record)
            .map_err(|e| CoreError::InternalError {
                message: e.to_string(),
            })?;
        let privacy_level = self.get_privacy_default();
        if let Err(error) = self.session_meta.set_privacy_level(&id, &privacy_level) {
            if let Err(rollback_error) = self.session_store.purge(&id) {
                tracing::error!(session_id = id, %rollback_error, "rollback incomplete session create");
            }
            return Err(CoreError::InternalError {
                message: error.to_string(),
            });
        }

        tracing::info!("Created Notebook capture session: {id}");
        Ok(self.build_session_info(&record))
    }

    #[doc(hidden)]
    pub fn new_for_test(data_dir: String) -> Result<Self, CoreError> {
        FORCE_PROCESS_TEST_SECRET_STORES.with(|flag| {
            let previous = flag.replace(true);
            let result = Self::new(data_dir);
            flag.set(previous);
            result
        })
    }
}

#[uniffi::export]
impl ZulangueCore {
    /// Production macOS constructor.  The durable task worker remains behind a
    /// one-shot gate until Swift has restored provider credentials into the
    /// process-local Rust store and calls `complete_provider_credential_bootstrap`.
    #[uniffi::constructor]
    pub fn new_deferred(data_dir: String) -> Result<Self, CoreError> {
        DEFER_PROVIDER_CREDENTIAL_BOOTSTRAP.with(|flag| {
            let previous = flag.replace(true);
            let result = Self::new(data_dir);
            flag.set(previous);
            result
        })
    }
}

impl ZulangueCore {
    /// 初始化核心
    pub fn new(data_dir: String) -> Result<Self, CoreError> {
        let path = PathBuf::from(&data_dir);
        if !path.exists() {
            std::fs::create_dir_all(&path).map_err(|e| CoreError::InitFailed {
                message: e.to_string(),
            })?;
        }

        let data_dir_lock = acquire_data_dir_lock(&path)?;

        // 一次性初始化 tracing subscriber → `<data_dir>/logs/rust.log`。
        // GUI app 的 stderr 被 launchd 吞,必须落盘才能诊断 Soniox 沉默等 bug。
        // 多次 new(tests) 用 Once + try_init 防止重复注册 panic。
        init_tracing_once(&path);

        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .map_err(|e| CoreError::InitFailed {
                message: format!("tokio runtime: {e}"),
            })?;

        // 初始化所有 SQLite stores（共用 data_dir）
        let db_path = path.join("zulangue.db");

        // Validate/install the single supported schema before any store gets a
        // chance to create an auxiliary table. Unsupported pre-v22 databases
        // therefore fail closed without partially initializing the new model.
        let notebook_store = NotebookStore::new(&db_path).map_err(|e| CoreError::InitFailed {
            message: format!("main database schema: {e}"),
        })?;

        let session_store =
            SessionQueryStore::new(&db_path).map_err(|e| CoreError::InitFailed {
                message: format!("session store: {e}"),
            })?;

        // Recover process-local sessions that cannot remain active after an app
        // restart. Notebook capture runs have their own interrupted recovery.
        match session_store.mark_stale_as_failed() {
            Ok(ids) if !ids.is_empty() => {
                tracing::warn!(
                    "startup self-heal: marked {} stale session(s) as failed",
                    ids.len()
                );
            }
            Ok(_) => {}
            Err(e) => {
                tracing::warn!("startup self-heal failed (non-fatal): {e}");
            }
        }

        let search_store = SearchStore::new(&db_path).map_err(|e| CoreError::InitFailed {
            message: format!("search store: {e}"),
        })?;

        let session_meta = SessionMetaStore::new(&db_path).map_err(|e| CoreError::InitFailed {
            message: format!("session meta: {e}"),
        })?;

        let notebook_capture_store =
            NotebookCaptureStore::new(&db_path).map_err(|e| CoreError::InitFailed {
                message: format!("notebook capture store: {e}"),
            })?;
        notebook_capture_store
            .recover_unfinished_runs()
            .map_err(|e| CoreError::InitFailed {
                message: format!("notebook capture recovery: {e}"),
            })?;
        let task_db_path = path.join("tasks.db");
        let task_queue = runtime
            .block_on(TaskQueue::new(&task_db_path))
            .map_err(|e| CoreError::InitFailed {
                message: format!("task queue: {e}"),
            })?;
        runtime
            .block_on(task_queue.recover_abandoned_tasks())
            .map_err(|e| CoreError::InitFailed {
                message: format!("task queue recovery: {e}"),
            })?;
        let task_queue = Arc::new(task_queue);
        let task_callbacks: Arc<TaskCallbackMap> = Arc::new(Mutex::new(HashMap::new()));
        let worker_cancel = tokio_util::sync::CancellationToken::new();
        let provider_credential_bootstrap =
            Arc::new(if DEFER_PROVIDER_CREDENTIAL_BOOTSTRAP.with(Cell::get) {
                task_worker::ProviderCredentialBootstrapGate::deferred()
            } else {
                task_worker::ProviderCredentialBootstrapGate::completed()
            });
        let key_store = Self::build_secret_material_stores(&path)?;
        let context_pack_store =
            ContextPackStore::new(&db_path, key_store.clone()).map_err(|e| {
                CoreError::InitFailed {
                    message: format!("Context Pack store: {e}"),
                }
            })?;
        recover_interrupted_capture_audio(
            &path,
            &notebook_capture_store,
            key_store.as_ref(),
            &session_meta,
            &session_store,
        );
        let api_key_store: Arc<dyn ApiKeyProvider> = Arc::new(MemoryApiKeyStore::new());
        let default_privacy_level = load_privacy_default(&path)?;
        let editor_callbacks: Arc<
            Mutex<HashMap<String, Arc<dyn crate::editor_api::FfiEditorCallback>>>,
        > = Arc::new(Mutex::new(HashMap::new()));

        // 后台 snapshot 落盘 flusher：每 500ms 把 pending_snapshot_saves 里积攒的
        // session_id 一次性 drain 写盘。目的是让 apply_edit 不在主线程阻塞
        // fs::write（见 editor_api.rs 的 schedule_snapshot_save）。
        let pending_snapshot_saves: Arc<Mutex<HashSet<String>>> =
            Arc::new(Mutex::new(HashSet::new()));
        let editor_bridge = EditorBridge::new();
        {
            let pending = pending_snapshot_saves.clone();
            let bridge = editor_bridge.clone();
            let data_dir_for_flusher = path.clone();
            // 150ms:balance between "主线程不阻塞 fs::write" 和 "用户 ⌘Q
            // 丢数据窗口"，避免极端退出路径吞掉输入；
            // 150ms 把暴露窗口压到 1/3, 单线程 macOS 上 fs::write 几 KB 的
            // LoroDoc snapshot 成本可忽略.
            runtime.spawn(async move {
                let mut tick = tokio::time::interval(Duration::from_millis(150));
                tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
                loop {
                    tick.tick().await;
                    let _mutation_guard = crate::editor_api::editor_document_mutation_guard();
                    let sessions: Vec<String> = {
                        let mut set = pending.lock().unwrap();
                        if set.is_empty() {
                            continue;
                        }
                        set.drain().collect()
                    };
                    for sid in sessions {
                        crate::editor_api::flush_snapshot_to_disk(
                            &data_dir_for_flusher,
                            &bridge,
                            &sid,
                        );
                    }
                }
            });
        }

        let session_task_registry = Arc::new(task_worker::SessionTaskRegistry::new());
        let core = Self {
            _data_dir_lock: data_dir_lock,
            data_dir: path,
            editor_bridge,
            runtime,
            session_store,
            search_store,
            session_meta,
            notebook_store,
            notebook_capture_store,
            context_pack_store,
            editor_callbacks,
            lane_credential_broker: Arc::new(Mutex::new(None)),
            pending_snapshot_saves,
            task_queue,
            session_task_registry,
            worker_cancel,
            provider_credential_bootstrap,
            task_callbacks,
            key_store,
            api_key_store,
            active_notebook_capture: Mutex::new(None),
            detached_notebook_capture_runs: Mutex::new(HashSet::new()),
            notebook_soniox_stream_factory: Arc::new(RealNotebookSonioxStreamFactory),
            capture_ownership_gate: Mutex::new(()),
            default_privacy_level: Mutex::new(default_privacy_level),
        };

        // Durable recovery runs before the task worker can claim remote work.
        // Purges win over pending lane edits and async intents for the same
        // immutable session id.
        core.resume_pending_session_purges()?;
        core.resume_pending_notebook_projection_mutations()?;
        core.resume_pending_async_search_projections()?;
        core.compensate_completed_notebook_async_tasks()?;
        core.resume_pending_notebook_async_projections()?;

        // 启动 task worker 循环 —— 持久队列真正"通电"
        task_worker::spawn_worker(
            &core.runtime,
            core.task_queue.clone(),
            core.task_callbacks.clone(),
            core.key_store.clone(),
            core.api_key_store.clone(),
            core.data_dir.clone(),
            db_path.clone(),
            Some(crate::notebook_api::NotebookTranscriptProjector::new(
                core.data_dir.clone(),
                db_path,
                core.notebook_store.clone(),
                core.editor_bridge.clone(),
                core.editor_callbacks.clone(),
            )),
            core.notebook_capture_store.clone(),
            core.session_task_registry.clone(),
            core.provider_credential_bootstrap.clone(),
            core.worker_cancel.clone(),
        );

        tracing::info!("Zulangue Core initialized at {data_dir}");
        Ok(core)
    }
}

#[uniffi::export]
impl ZulangueCore {
    /// Opens the one-shot durable task-worker gate after provider credentials
    /// have either been restored successfully or cleared fail-closed.  This is
    /// idempotent; it never exposes credential values.
    pub fn complete_provider_credential_bootstrap(&self) {
        self.provider_credential_bootstrap.complete();
    }

    /// 关闭核心，释放资源;停掉 task worker 循环。
    /// 在 flight 任务的状态会被 TaskQueue::new 启动时恢复为 pending。
    ///
    /// **先同步 flush 所有 editor snapshot 再 cancel worker** —— 兜底
    /// `applicationWillTerminate` 漏调的情况。flush 自身失败不阻止 shutdown
    /// (I/O 异常时 fs::write 只 log 不 propagate)。
    pub fn shutdown(&self) -> Result<(), CoreError> {
        tracing::info!("Zulangue Core shutting down");
        let _ = self.flush_all_editors_sync();
        self.worker_cancel.cancel();
        Ok(())
    }

    /// 返回 API 版本号
    pub fn api_version(&self) -> String {
        env!("CARGO_PKG_VERSION").to_string()
    }

    /// 切换 Rust 端运行时 locale，影响所有 `CoreError` 文本。
    ///
    /// 传入 BCP-47 标签(`"zh-Hans"` / `"en"` / `"ja"` / `"zh-CN"` 等),
    /// 经 [`vt_i18n::set_locale`] 规范化后生效。
    ///
    /// Swift 侧应在:
    /// - 每次 App 启动时调用一次(根据 AppLanguage 设置)
    /// - 用户在设置里切语言后立即调用
    pub fn set_locale(&self, tag: String) {
        vt_i18n::set_locale(&tag);
    }

    /// 当前 locale。用于诊断/验证桥接。
    pub fn current_locale(&self) -> String {
        vt_i18n::current_locale()
    }

    /// 支持的 locale 列表。UI 用这个填语言 picker,避免 Swift 硬编码。
    pub fn available_locales(&self) -> Vec<String> {
        vt_i18n::available_locales()
            .iter()
            .map(|s| s.to_string())
            .collect()
    }

    /// 获取会话信息（从 SQLite 查询）
    pub fn get_session(&self, id: String) -> Result<SessionInfo, CoreError> {
        let query = vt_store::SessionQuery {
            search_text: None,
            session_type: None,
            status: None,
            limit: Some(500),
            offset: None,
            sort_field: Default::default(),
            sort_order: Default::default(),
            // get_session 无视垃圾箱 — 删了也能 read(比如 undo 路径)
            trash_filter: vt_store::TrashFilter::All,
        };
        let result =
            self.session_store
                .query_sessions(&query)
                .map_err(|e| CoreError::InternalError {
                    message: e.to_string(),
                })?;

        for s in &result.sessions {
            if s.id == id {
                return Ok(self.build_session_info(s));
            }
        }

        Err(CoreError::NotFound {
            message: format!("session not found: {id}"),
        })
    }

    /// 设置默认隐私等级。
    ///
    /// 影响后续导入和 Notebook Capture 创建的 session。
    /// 取值："standard" | "high" | "maximum"。无效值返回 ValidationFailed。
    pub fn set_privacy_default(&self, level: String) -> Result<(), CoreError> {
        if !matches!(level.as_str(), "standard" | "high" | "maximum") {
            return Err(CoreError::ValidationFailed {
                message: format!("invalid privacy level: {level}"),
            });
        }
        persist_privacy_default(&self.data_dir, &level)?;
        *self.default_privacy_level.lock().unwrap() = level;
        Ok(())
    }

    /// 获取默认隐私等级。
    pub fn get_privacy_default(&self) -> String {
        self.default_privacy_level.lock().unwrap().clone()
    }

    /// 销毁某个 session 的加密音频。
    ///
    /// 流程：
    /// 1. 安全覆写 + 删除 .enc 文件
    /// 2. 清除 session_meta.encrypted_path
    /// 3. 如果 session 隐私等级是 maximum，同时删除密钥
    pub fn destroy_session_audio(&self, session_id: String) -> Result<(), CoreError> {
        self.enforce_destroy(&session_id, /*force_max=*/ false)
    }

    /// 完全销毁，不论 privacy_level：删除音频和密钥。
    pub fn destroy_session_audio_and_key(&self, session_id: String) -> Result<(), CoreError> {
        self.enforce_destroy(&session_id, /*force_max=*/ true)
    }

    // ─────────────────────────────────────────────────
    // 软删 / 垃圾箱 FFI
    // ─────────────────────────────────────────────────
    //
    // 语义:
    //   - list_sessions 默认不返回已删的(trash_filter=ActiveOnly)
    //   - soft_delete_session 把 deleted_at 设成 now;记录还在表里
    //   - list_trashed_sessions 给 TrashPage 列已软删的
    //   - restore_session 把 deleted_at 清掉 → 恢复到 Home
    //   - purge_session 硬删:先 destroy_session_audio(清加密音频 + 密钥),
    //     再从 session_records 表删行。不可撤销。

    /// 软删单个 session。幂等:已软删再调是 no-op。
    pub fn soft_delete_session(&self, session_id: String) -> Result<(), CoreError> {
        self.session_store
            .soft_delete(&session_id)
            .map_err(|e| match e {
                vt_store::SessionQueryError::NotFound(_) => CoreError::NotFound {
                    message: format!("session not found: {session_id}"),
                },
                other => CoreError::InternalError {
                    message: other.to_string(),
                },
            })
    }

    /// 批量软删。部分不存在的 id 视为成功(幂等)。
    pub fn soft_delete_sessions(&self, session_ids: Vec<String>) -> Result<(), CoreError> {
        self.session_store
            .soft_delete_many(&session_ids)
            .map_err(|e| CoreError::InternalError {
                message: e.to_string(),
            })
    }

    /// 列出垃圾箱里的 session。TrashPage 专用。
    pub fn list_trashed_sessions(&self) -> Result<Vec<SessionInfo>, CoreError> {
        let query = vt_store::SessionQuery {
            trash_filter: vt_store::TrashFilter::TrashedOnly,
            limit: Some(500),
            ..Default::default()
        };
        let result =
            self.session_store
                .query_sessions(&query)
                .map_err(|e| CoreError::InternalError {
                    message: e.to_string(),
                })?;
        Ok(result
            .sessions
            .iter()
            .map(|r| self.build_session_info(r))
            .collect())
    }

    /// 从垃圾箱恢复 session。
    pub fn restore_session(&self, session_id: String) -> Result<(), CoreError> {
        self.session_store
            .restore(&session_id)
            .map_err(|e| match e {
                vt_store::SessionQueryError::NotFound(_) => CoreError::NotFound {
                    message: format!("session not found: {session_id}"),
                },
                other => CoreError::InternalError {
                    message: other.to_string(),
                },
            })
    }

    /// 永久删除 session:清加密音频 + 密钥 + 从 session_records 删行。
    /// 不可撤销。TrashPage 的 "Delete forever" 按钮调这个。
    pub fn purge_session(&self, session_id: String) -> Result<(), CoreError> {
        self.purge_session_forever(&session_id)
    }

    /// 全文搜索会话
    pub fn search_sessions(
        &self,
        query: String,
        limit: u32,
    ) -> Result<Vec<SearchResultInfo>, CoreError> {
        let results = self
            .search_store
            .search(&query, limit as usize)
            .map_err(|e| CoreError::InternalError {
                message: e.to_string(),
            })?;

        Ok(results
            .into_iter()
            .map(|r| SearchResultInfo {
                session_id: r.session_id,
                snippet: r.snippet,
            })
            .collect())
    }

    /// 设置进程内 API Key。
    ///
    /// 唯一支持的 scope 是 `soniox`。
    ///
    /// 空 value 视为 clear。
    pub fn set_api_key(&self, scope: String, value: String) -> Result<(), CoreError> {
        if !is_valid_scope(&scope) {
            return Err(CoreError::ValidationFailed {
                message: format!("invalid api key scope: {scope}"),
            });
        }
        if value.trim().is_empty() {
            return self
                .api_key_store
                .clear(&scope)
                .map_err(|e| CoreError::InternalError {
                    message: format!("clear api key: {e}"),
                });
        }
        self.api_key_store
            .set(&scope, &value)
            .map_err(|e| CoreError::InternalError {
                message: format!("set api key: {e}"),
            })
    }

    /// 检查某 scope 是否有 API Key(供 UI 显示"未配置"标记,不泄露 key 本身)。
    pub fn has_api_key(&self, scope: String) -> bool {
        is_valid_scope(&scope) && self.api_key_store.has(&scope)
    }

    /// 删除 API Key(用户"移除配置"时调)。幂等。
    pub fn clear_api_key(&self, scope: String) -> Result<(), CoreError> {
        if !is_valid_scope(&scope) {
            return Err(CoreError::ValidationFailed {
                message: format!("invalid api key scope: {scope}"),
            });
        }
        self.api_key_store
            .clear(&scope)
            .map_err(|e| CoreError::InternalError {
                message: format!("clear api key: {e}"),
            })
    }

    /// Verify a Soniox credential against the fixed realtime endpoint.
    ///
    /// A candidate value is verified before Settings or onboarding persists it.
    /// Passing `None` verifies the active in-memory credential without exposing
    /// that credential back across FFI. Credential material is never logged.
    pub async fn verify_api_key(
        &self,
        scope: String,
        candidate: Option<String>,
    ) -> Result<FfiProviderConnectionCheck, CoreError> {
        if !is_valid_scope(&scope) {
            return Err(CoreError::ValidationFailed {
                message: format!("invalid api key scope: {scope}"),
            });
        }

        let api_key = match candidate {
            Some(value) => {
                let normalized = value.trim();
                if normalized.is_empty() {
                    return Err(CoreError::ValidationFailed {
                        message: "API key is empty".to_string(),
                    });
                }
                normalized.to_string()
            }
            None => self
                .api_key_store
                .get(&scope)
                .map_err(|_| CoreError::ValidationFailed {
                    message: "No active API key is available to verify".to_string(),
                })?,
        };
        let endpoint = vt_stt::CURRENT_NOTEBOOK_CAPTURE_ENGINE.realtime_endpoint;
        let verification = self
            .runtime
            .spawn(async move { vt_stt::SonioxRtClient::test_key(endpoint, &api_key).await });

        let result = verification.await.map_err(|_| CoreError::InternalError {
            message: "API key verification task did not complete".to_string(),
        })?;
        let checked_at_ms = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis()
            .try_into()
            .unwrap_or(u64::MAX);
        Ok(provider_connection_check(result, checked_at_ms))
    }

    /// 查询会话列表（带过滤/分页）
    pub fn query_sessions(
        &self,
        session_type: Option<String>,
        status: Option<String>,
        search_text: Option<String>,
        limit: Option<u32>,
        offset: Option<u32>,
    ) -> Result<SessionQueryResultInfo, CoreError> {
        let query = vt_store::SessionQuery {
            session_type,
            status,
            search_text,
            limit,
            offset,
            sort_field: Default::default(),
            sort_order: Default::default(),
            // list_sessions 默认过滤垃圾箱(软删的不显示)。
            // Trash page 用单独的 list_trashed_sessions FFI。
            trash_filter: vt_store::TrashFilter::ActiveOnly,
        };

        let result =
            self.session_store
                .query_sessions(&query)
                .map_err(|e| CoreError::InternalError {
                    message: e.to_string(),
                })?;

        Ok(SessionQueryResultInfo {
            sessions: result
                .sessions
                .iter()
                .map(|s| self.build_session_info(s))
                .collect(),
            total_count: result.total_count,
        })
    }
}

fn recover_interrupted_capture_audio(
    data_dir: &Path,
    capture_store: &NotebookCaptureStore,
    key_store: &dyn KeyProvider,
    session_meta: &SessionMetaStore,
    session_store: &SessionQueryStore,
) {
    let Ok(runs) = capture_store.list_interrupted_runs() else {
        tracing::warn!("list interrupted Notebook capture runs failed");
        return;
    };
    for run in runs {
        if let Err(error) = recover_interrupted_capture_audio_run(
            data_dir,
            capture_store,
            key_store,
            session_meta,
            session_store,
            &run.id,
        ) {
            tracing::warn!(run_id = run.id, %error, "recover interrupted capture audio");
        }
    }
}

/// Recovers and indexes one interrupted capture. The journal is removed only
/// after every durable audio index commits, so callers can retain an in-memory
/// retry marker whenever this function returns an error.
pub(crate) fn recover_interrupted_capture_audio_run(
    data_dir: &Path,
    capture_store: &NotebookCaptureStore,
    key_store: &dyn KeyProvider,
    session_meta: &SessionMetaStore,
    session_store: &SessionQueryStore,
    run_id: &str,
) -> Result<(), String> {
    let run = capture_store
        .get_run(run_id)
        .map_err(|error| format!("load interrupted capture run: {error}"))?
        .ok_or_else(|| format!("interrupted capture run {run_id} was not found"))?;
    if run.capture_state != vt_store::notebook_capture_store::CaptureState::Interrupted {
        return Err(format!(
            "capture run {run_id} is not interrupted: {:?}",
            run.capture_state
        ));
    }
    let journal_path = run
        .audio_journal_path
        .as_deref()
        .map(PathBuf::from)
        .ok_or_else(|| "interrupted capture has no journal path".to_string())?;
    let key_ref = run
        .audio_key_ref
        .as_deref()
        .ok_or_else(|| "interrupted capture key reference is missing".to_string())?;
    let sample_rate = run
        .sample_rate
        .ok_or_else(|| "interrupted capture sample rate is missing".to_string())?;
    let channels = run
        .channels
        .ok_or_else(|| "interrupted capture channel count is missing".to_string())?;

    let (audio_path, chunks, captured_frames) = if journal_path.exists() {
        let key = key_store
            .load_key(key_ref)
            .map_err(|error| format!("interrupted capture key unavailable: {error}"))?;
        let recovered = vt_pipeline::recover_capture_audio_journal(
            &journal_path,
            data_dir,
            &run.session_id,
            &key,
            sample_rate,
            channels,
        )
        .map_err(|error| format!("recover interrupted capture journal: {error}"))?;
        let audio_path = recovered.encrypted_path.to_string_lossy().into_owned();
        capture_store
            .finalize_interrupted_audio(&run.id, &audio_path, recovered.captured_frames)
            .map_err(|error| format!("persist recovered capture audio: {error}"))?;
        (
            audio_path,
            recovered.audio_chunks,
            recovered.captured_frames,
        )
    } else if let Some(audio_path) = run
        .audio_path
        .as_deref()
        .filter(|path| Path::new(path).exists())
    {
        let chunks =
            indexed_capture_chunks(data_dir, &run.session_id, run.captured_frames, sample_rate)
                .map_err(|error| format!("rebuild recovered capture chunk index: {error}"))?;
        (audio_path.to_string(), chunks, run.captured_frames)
    } else {
        return Err("interrupted capture has no recoverable audio".to_string());
    };

    let recovered_index = RecoveredCaptureIndex {
        session_id: &run.session_id,
        audio_path: &audio_path,
        key_ref,
        sample_rate,
        channels,
        captured_frames,
        chunks: &chunks,
    };
    persist_recovered_capture_indexes(session_meta, session_store, &recovered_index)
        .map_err(|error| format!("persist recovered capture indexes: {error}"))?;
    if journal_path.exists() {
        std::fs::remove_file(&journal_path)
            .map_err(|error| format!("remove committed capture journal: {error}"))?;
    }
    tracing::info!(
        run_id = run.id,
        session_id = run.session_id,
        "recovered interrupted encrypted capture audio"
    );
    Ok(())
}

fn indexed_capture_chunks(
    data_dir: &Path,
    session_id: &str,
    captured_frames: u64,
    sample_rate: u32,
) -> Result<Vec<RecordingAudioChunk>, String> {
    let frames_per_chunk = u64::from(sample_rate.max(1)).saturating_mul(60);
    let chunk_count = if captured_frames == 0 {
        1
    } else {
        captured_frames.div_ceil(frames_per_chunk)
    };
    let mut chunks = Vec::with_capacity(chunk_count as usize);
    for index in 0..chunk_count {
        let start_frame = index.saturating_mul(frames_per_chunk);
        let end_frame = captured_frames.min(start_frame.saturating_add(frames_per_chunk));
        let path = data_dir.join(format!("{session_id}.chunk.{index:05}.enc"));
        if !path.exists() {
            return Err(format!(
                "missing finalized capture chunk {}",
                path.display()
            ));
        }
        chunks.push(RecordingAudioChunk {
            chunk_id: format!("{session_id}:audio:{index:05}"),
            path,
            start_ms: start_frame.saturating_mul(1000) / u64::from(sample_rate.max(1)),
            end_ms: end_frame.saturating_mul(1000) / u64::from(sample_rate.max(1)),
        });
    }
    Ok(chunks)
}

struct RecoveredCaptureIndex<'a> {
    session_id: &'a str,
    audio_path: &'a str,
    key_ref: &'a str,
    sample_rate: u32,
    channels: u16,
    captured_frames: u64,
    chunks: &'a [RecordingAudioChunk],
}

fn persist_recovered_capture_indexes(
    session_meta: &SessionMetaStore,
    session_store: &SessionQueryStore,
    recovered: &RecoveredCaptureIndex<'_>,
) -> Result<(), String> {
    session_meta
        .set_encrypted_path(
            recovered.session_id,
            recovered.audio_path,
            recovered.key_ref,
        )
        .map_err(|error| format!("set recovered encrypted path: {error}"))?;
    session_meta
        .set_audio_format(
            recovered.session_id,
            recovered.sample_rate,
            recovered.channels,
        )
        .map_err(|error| format!("set recovered audio format: {error}"))?;
    for chunk in recovered.chunks {
        session_meta
            .upsert_audio_retention_chunk(&vt_store::AudioChunkRetentionRecord {
                session_id: recovered.session_id.to_string(),
                chunk_id: chunk.chunk_id.clone(),
                start_ms: chunk.start_ms,
                end_ms: chunk.end_ms.max(chunk.start_ms + 1),
                local_path: chunk.path.to_string_lossy().into_owned(),
                encrypted: true,
                deleted: false,
                retention_deadline_ms: i64::MAX,
                delete_error: None,
                deleted_at_ms: None,
            })
            .map_err(|error| format!("index recovered chunk {}: {error}", chunk.chunk_id))?;
    }
    let duration_ms =
        recovered.captured_frames.saturating_mul(1_000) / u64::from(recovered.sample_rate.max(1));
    let mut record = session_store
        .get_session(recovered.session_id)
        .map_err(|error| format!("load recovered session record: {error}"))?;
    record.status = "interrupted".to_string();
    record.duration_ms = duration_ms;
    session_store
        .insert_session(&record)
        .map_err(|error| format!("persist recovered session record: {error}"))?;
    Ok(())
}

impl ZulangueCore {
    /// 集成测试 helper：暴露 SessionMetaStore 引用以便注入 token / 元数据。
    /// 仅供 vt-ffi/tests 使用，UniFFI 不会导出。
    #[doc(hidden)]
    pub fn session_meta_for_test(&self) -> &SessionMetaStore {
        &self.session_meta
    }

    /// Integration-test visibility for destructive privacy assertions. The key
    /// material is never exposed; callers can only verify current ownership or
    /// confirmed deletion by its opaque reference.
    #[doc(hidden)]
    pub fn key_exists_for_test(&self, key_ref: &str) -> bool {
        self.key_store.key_exists(key_ref)
    }

    /// 实际执行销毁
    fn enforce_destroy(&self, session_id: &str, force_max: bool) -> Result<(), CoreError> {
        let meta = self
            .session_meta
            .get_meta(session_id)
            .map_err(|_| CoreError::NotFound {
                message: format!("session not found: {session_id}"),
            })?;

        // 1. 安全删除由 capture/import run 登记的物理音频 chunk。
        let now_ms = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as i64;
        let chunks = self
            .session_meta
            .list_audio_retention_chunks(session_id)
            .unwrap_or_default();
        for chunk in chunks.iter().filter(|chunk| !chunk.deleted) {
            let path = std::path::PathBuf::from(&chunk.local_path);
            if path.exists() {
                vt_pipeline::privacy::PrivacyDestroyer::destroy_file(&path).map_err(|e| {
                    let message = e.to_string();
                    let _ = self.session_meta.mark_audio_retention_chunk_delete_failed(
                        session_id,
                        &chunk.chunk_id,
                        &message,
                    );
                    CoreError::InternalError {
                        message: format!("destroy chunk file: {message}"),
                    }
                })?;
            }
            self.session_meta
                .mark_audio_retention_chunk_deleted(session_id, &chunk.chunk_id, now_ms)
                .map_err(|e| CoreError::InternalError {
                    message: format!("mark audio chunk deleted: {e}"),
                })?;
        }

        // 2. 决定是否删 key（force_max 或 session 等级是 maximum）
        let should_delete_key = force_max
            || meta
                .privacy_level
                .as_deref()
                .map(|l| l == "maximum")
                .unwrap_or(false);
        if should_delete_key {
            if let Some(key_id) = meta.key_id.as_deref() {
                if !key_id.is_empty() {
                    let _ = self.key_store.delete_key(key_id);
                }
            }
        }

        // 3. 清空 session_meta 里的引用
        let _ = self.session_meta.clear_encrypted_path(session_id);
        Ok(())
    }

    /// 构造完整 SessionInfo —— 从 SessionRecord + SessionMeta 拼装
    pub(crate) fn build_session_info(&self, record: &SessionRecord) -> SessionInfo {
        let meta = self
            .session_meta
            .get_meta(&record.id)
            .unwrap_or_else(|_| SessionMeta {
                session_id: record.id.clone(),
                ..SessionMeta::default()
            });
        let (source_language, target_languages) = self
            .notebook_capture_store
            .get_run_for_session(&record.id)
            .ok()
            .flatten()
            .and_then(|run| {
                serde_json::from_str::<vt_store::notebook_capture_store::NotebookCaptureProfile>(
                    &run.profile_snapshot_json,
                )
                .ok()
            })
            .map(|profile| {
                let mut languages = profile.selected_languages;
                if languages.is_empty() {
                    languages.push(profile.left_language);
                    if !profile.right_language.is_empty()
                        && !languages
                            .iter()
                            .any(|language| language == &profile.right_language)
                    {
                        languages.push(profile.right_language);
                    }
                }
                if languages.len() <= 1 {
                    (languages.into_iter().next().unwrap_or_default(), Vec::new())
                } else {
                    // A multilingual capture has no configured source language:
                    // every selected language is an equal display/output lane.
                    (String::new(), languages)
                }
            })
            .unwrap_or_default();
        // Preview is a derived read model. Realtime capture uses its durable
        // utterances; only an explicitly async transcript uses provider tokens.
        let preview = self.build_preview(&record.id);
        SessionInfo {
            id: record.id.clone(),
            session_type: record.session_type.clone(),
            status: record.status.clone(),
            title: record.title.clone(),
            duration_ms: record.duration_ms,
            source_language,
            target_languages,
            created_at_unix_ms: parse_created_at_to_unix_ms(&record.created_at),
            has_encrypted_audio: meta
                .encrypted_path
                .as_deref()
                .map(|p| !p.is_empty())
                .unwrap_or(false),
            preview,
            is_trashed: record.deleted_at.is_some(),
        }
    }

    /// 从 session 的事实源取前若干字符。Capture utterances always win over
    /// provider tokens so a two-way run can never show a stale async preview.
    fn build_preview(&self, session_id: &str) -> String {
        const MAX_CHARS: usize = 120;
        let capture_run = self
            .notebook_capture_store
            .get_run_for_session(session_id)
            .ok()
            .flatten();
        let mut buf = if let Some(run) = capture_run {
            let utterances = self
                .notebook_capture_store
                .list_utterances(session_id)
                .unwrap_or_default();
            if !utterances.is_empty() {
                capture_utterance_search_content(&utterances)
            } else {
                let async_is_fact_source = run.async_task_state
                    == vt_store::notebook_capture_store::AsyncTaskState::Completed;
                if async_is_fact_source {
                    self.session_meta
                        .get_tokens(session_id)
                        .unwrap_or_default()
                        .into_iter()
                        .map(|token| token.text)
                        .collect::<String>()
                } else {
                    String::new()
                }
            }
        } else {
            self.session_meta
                .get_tokens(session_id)
                .unwrap_or_default()
                .into_iter()
                .map(|token| token.text)
                .collect::<String>()
        };
        // 按字符(不是字节)截断,末尾加省略号
        if buf.chars().count() > MAX_CHARS {
            buf = format!("{}…", buf.chars().take(MAX_CHARS).collect::<String>());
        }
        buf
    }
}

/// Deterministic, rebuildable text used by both Home previews and FTS. The
/// language labels keep equal text in different lanes distinguishable while
/// preserving source/translation order. No projection/editor state is read.
pub(crate) fn capture_utterance_search_content(
    utterances: &[vt_store::notebook_capture_store::RealtimeUtterance],
) -> String {
    use vt_store::notebook_capture_store::{
        UtteranceCompletion, UtteranceVariantRole, UtteranceVariantState,
    };

    let lane_id = |language: &str| {
        language
            .trim()
            .to_lowercase()
            .split('-')
            .next()
            .unwrap_or_default()
            .to_string()
    };
    let mut out = String::new();
    let mut append_lane = |language: &str, text: &str| {
        if text.is_empty() {
            return;
        }
        if !out.is_empty() {
            out.push(' ');
        }
        out.push('[');
        out.push_str(&lane_id(language));
        out.push_str("] ");
        out.push_str(text);
    };

    for utterance in utterances {
        if utterance.completion == UtteranceCompletion::Complete {
            append_lane(&utterance.source_language, &utterance.source_text);
        }

        let mut translations = utterance
            .variants
            .iter()
            .filter(|variant| {
                variant.role == UtteranceVariantRole::Translation
                    && variant.state == UtteranceVariantState::Ready
                    && variant.completion == Some(UtteranceCompletion::Complete)
                    && variant.text.as_deref().is_some_and(|text| !text.is_empty())
            })
            .collect::<Vec<_>>();
        translations.sort_by_key(|variant| lane_id(&variant.language));
        if translations.is_empty() && utterance.variants.is_empty() {
            // Compatibility for snapshots created before language variants.
            if utterance.completion == UtteranceCompletion::Complete {
                if let (Some(language), Some(text)) = (
                    utterance.translated_language.as_deref(),
                    utterance.translated_text.as_deref(),
                ) {
                    append_lane(language, text);
                }
            }
            continue;
        }
        for variant in translations {
            append_lane(
                &variant.language,
                variant.text.as_deref().unwrap_or_default(),
            );
        }
    }
    out
}

impl ZulangueCore {
    /// Test seam for rebuilding the disposable FTS projection from durable
    /// realtime facts.
    #[cfg(test)]
    pub(crate) fn rebuild_capture_search_index(
        &self,
        session_id: &str,
        utterances: &[vt_store::notebook_capture_store::RealtimeUtterance],
    ) -> Result<(), CoreError> {
        self.search_store
            .index_session(session_id, &capture_utterance_search_content(utterances))
            .map_err(|error| CoreError::InternalError {
                message: format!("rebuild capture search index: {error}"),
            })
    }
}

/// 解析 SessionRecord.created_at（"%Y-%m-%d %H:%M:%S" 格式，UTC）
/// 为 Unix epoch 毫秒。失败时返回当前时间。
fn parse_created_at_to_unix_ms(s: &str) -> u64 {
    use chrono::{NaiveDateTime, TimeZone, Utc};
    if let Ok(dt) = NaiveDateTime::parse_from_str(s, "%Y-%m-%d %H:%M:%S") {
        let utc = Utc.from_utc_datetime(&dt);
        return utc.timestamp_millis().max(0) as u64;
    }
    Utc::now().timestamp_millis().max(0) as u64
}

/// API Key scope 白名单(防误传任意字符串污染 provider 命名空间)。
pub(crate) fn is_valid_scope(scope: &str) -> bool {
    scope == vt_stt::CURRENT_NOTEBOOK_CAPTURE_ENGINE.credential_scope
}

pub(crate) fn validate_frozen_session_privacy_level(
    level: Option<String>,
) -> Result<String, CoreError> {
    match level {
        Some(level) if matches!(level.as_str(), "standard" | "high" | "maximum") => Ok(level),
        _ => Err(CoreError::ValidationFailed {
            message: "privacy_state_invalid: session privacy level is missing or invalid"
                .to_string(),
        }),
    }
}

pub(crate) fn ensure_remote_provider_allowed(
    privacy_level: &str,
    _provider: &str,
) -> Result<(), CoreError> {
    // Audio retention and remote-data authorization are orthogonal. The
    // Notebook's remote toggle or explicit Async "Transcribe" command owns
    // egress consent; this frozen value only controls how long encrypted audio
    // remains after durable transcript facts exist.
    match privacy_level {
        "standard" | "high" | "maximum" => Ok(()),
        _ => Err(CoreError::ValidationFailed {
            message: "privacy_state_invalid: session privacy level is missing or invalid"
                .to_string(),
        }),
    }
}

/// FFI 层错误类型
///
/// Display 走 [`vt_i18n`] — 切换 locale 后,用户看到的错误消息会跟着变。
#[derive(Debug, uniffi::Error)]
pub enum CoreError {
    InitFailed { message: String },
    ValidationFailed { message: String },
    NotFound { message: String },
    InternalError { message: String },
}

impl std::fmt::Display for CoreError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let s = match self {
            Self::InitFailed { message } => {
                vt_i18n::t_args("error.core.init_failed", &[("detail", message)])
            }
            Self::ValidationFailed { message } => {
                vt_i18n::t_args("error.core.validation_failed", &[("detail", message)])
            }
            Self::NotFound { message } => {
                vt_i18n::t_args("error.core.not_found", &[("detail", message)])
            }
            Self::InternalError { message } => {
                vt_i18n::t_args("error.core.internal", &[("detail", message)])
            }
        };
        f.write_str(&s)
    }
}

impl std::error::Error for CoreError {}

/// 会话信息（FFI DTO）
///
/// 给 Library UI 渲染使用 — 字段从 SessionQueryStore + SessionMetaStore 拼装。
/// 见 D5-uniffi-api §SessionInfo。
#[derive(uniffi::Record)]
pub struct SessionInfo {
    pub id: String,
    pub session_type: String,
    pub status: String,
    /// 显示标题（导入音频时来自文件名 stem，新会话默认空字符串）
    pub title: String,
    /// 时长（毫秒）
    pub duration_ms: u64,
    /// 源语言代码（如 "en"）；尚未设置时为空字符串
    pub source_language: String,
    /// 目标翻译语言代码列表；空表示无翻译
    pub target_languages: Vec<String>,
    /// 创建时间，Unix 时间戳毫秒（Swift 用 `Date(timeIntervalSince1970:)`）
    pub created_at_unix_ms: u64,
    /// 是否还有加密音频文件（隐私销毁后可能为 false）
    pub has_encrypted_audio: bool,
    /// Library 列表预览:transcript 首 ~120 字符(空 = 还没转录 / 没内容)。
    /// UI 用来回答"这个 session 在说什么"。
    pub preview: String,
    /// 是否在垃圾箱里(TrashPage 用 list_trashed_sessions 专门拿,
    /// Home 用 list_sessions 不会返回 trashed 的)。
    pub is_trashed: bool,
}

/// 搜索结果（FFI DTO）
#[derive(uniffi::Record)]
pub struct SearchResultInfo {
    pub session_id: String,
    pub snippet: String,
}

/// 会话查询结果（FFI DTO）
#[derive(uniffi::Record)]
pub struct SessionQueryResultInfo {
    pub sessions: Vec<SessionInfo>,
    pub total_count: u64,
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    struct NoopNotebookCaptureCallback;

    impl crate::notebook_capture_api::FfiNotebookCaptureCallback for NoopNotebookCaptureCallback {
        fn on_capture_event(&self, _event: crate::notebook_capture_api::FfiNotebookCaptureEvent) {}

        fn on_live_preview(
            &self,
            _preview: crate::notebook_capture_api::FfiNotebookCaptureLivePreview,
        ) {
        }
    }

    fn process_test_key_refs(data_dir: &Path) -> Vec<String> {
        let namespace = secret_material_namespace(data_dir);
        let mut refs = ProcessTestKeyStore::stores()
            .lock()
            .unwrap()
            .get(&namespace)
            .map(|keys| keys.keys().cloned().collect::<Vec<_>>())
            .unwrap_or_default();
        refs.sort();
        refs
    }

    #[test]
    fn production_content_key_store_reopens_from_secrets_directory() {
        let tmp = TempDir::new().unwrap();
        let key_ref = "zulangue.audio.current";
        let key = SessionKey::from_bytes([0x42; KEY_SIZE]);

        let first = ZulangueCore::build_production_secret_material_stores(tmp.path()).unwrap();
        first.store_key(key_ref, &key).unwrap();
        drop(first);

        let reopened = ZulangueCore::build_production_secret_material_stores(tmp.path()).unwrap();
        assert_eq!(
            reopened.load_key(key_ref).unwrap().as_bytes(),
            key.as_bytes()
        );
        assert!(tmp.path().join("Secrets/content-keys.json").is_file());
    }

    #[test]
    fn test_core_init_and_shutdown() {
        let tmp = TempDir::new().unwrap();
        let core = ZulangueCore::new(tmp.path().to_str().unwrap().to_string());
        assert!(core.is_ok());
        assert!(core.unwrap().shutdown().is_ok());
    }

    #[test]
    fn failed_capture_run_insert_rolls_back_session_link_journal_and_key() {
        let tmp = TempDir::new().unwrap();
        let core = ZulangueCore::new_for_test(tmp.path().to_string_lossy().to_string()).unwrap();
        let notebook = core
            .create_notebook(Some("Rollback injection".into()))
            .unwrap();
        let profile = core
            .get_notebook_capture_profile(notebook.id.clone())
            .unwrap();
        let keys_before = process_test_key_refs(tmp.path());
        let connection = rusqlite::Connection::open(tmp.path().join("zulangue.db")).unwrap();
        connection
            .execute_batch(
                "CREATE TRIGGER fail_notebook_capture_run
                 BEFORE INSERT ON notebook_capture_runs
                 BEGIN
                   SELECT RAISE(FAIL, 'injected notebook capture run insert failure');
                 END;",
            )
            .unwrap();

        let error = core
            .start_notebook_capture_session(
                notebook.id.clone(),
                profile.revision,
                None,
                Box::new(NoopNotebookCaptureCallback),
            )
            .unwrap_err();
        assert!(error.to_string().contains("injected notebook capture run"));
        assert_eq!(
            core.query_sessions(None, None, None, None, None)
                .unwrap()
                .total_count,
            0,
            "the provisional session must be purged"
        );
        assert!(core
            .list_notebook_sessions(notebook.id.clone())
            .unwrap()
            .is_empty());
        assert_eq!(
            connection
                .query_row("SELECT COUNT(*) FROM notebook_capture_runs", [], |row| {
                    row.get::<_, i64>(0)
                })
                .unwrap(),
            0
        );
        assert_eq!(process_test_key_refs(tmp.path()), keys_before);
        assert!(
            std::fs::read_dir(tmp.path())
                .unwrap()
                .filter_map(Result::ok)
                .all(|entry| {
                    !entry
                        .file_name()
                        .to_string_lossy()
                        .ends_with(".capture-journal.enc")
                }),
            "create_run rollback must delete the journal even without a durable run row"
        );

        connection
            .execute("DROP TRIGGER fail_notebook_capture_run", [])
            .unwrap();
        let capture = core
            .start_notebook_capture_session(
                notebook.id,
                profile.revision,
                None,
                Box::new(NoopNotebookCaptureCallback),
            )
            .expect("failed start must release capture ownership");
        core.stop_notebook_capture_session(capture.session_id)
            .unwrap();
    }

    #[test]
    fn test_api_version() {
        let tmp = TempDir::new().unwrap();
        let core = ZulangueCore::new(tmp.path().to_str().unwrap().to_string()).unwrap();
        let version = core.api_version();
        assert!(version.starts_with("0."));
    }

    // ========== API Key 管理 (Step 1) ==========

    #[test]
    fn test_set_has_clear_api_key_roundtrip() {
        let tmp = TempDir::new().unwrap();
        let core = ZulangueCore::new(tmp.path().to_str().unwrap().to_string()).unwrap();
        assert!(!core.has_api_key("soniox".to_string()));
        core.set_api_key("soniox".to_string(), "sk-xyz".to_string())
            .unwrap();
        assert!(core.has_api_key("soniox".to_string()));
        core.clear_api_key("soniox".to_string()).unwrap();
        assert!(!core.has_api_key("soniox".to_string()));
    }

    #[test]
    fn test_set_api_key_rejects_invalid_scope() {
        let tmp = TempDir::new().unwrap();
        let core = ZulangueCore::new(tmp.path().to_str().unwrap().to_string()).unwrap();
        let err = core
            .set_api_key("random_scope".to_string(), "v".to_string())
            .unwrap_err();
        assert!(format!("{err:?}").to_lowercase().contains("invalid"));
    }

    #[test]
    fn test_set_api_key_empty_value_clears() {
        let tmp = TempDir::new().unwrap();
        let core = ZulangueCore::new(tmp.path().to_str().unwrap().to_string()).unwrap();
        core.set_api_key("soniox".to_string(), "v".to_string())
            .unwrap();
        core.set_api_key("soniox".to_string(), "".to_string())
            .unwrap();
        assert!(!core.has_api_key("soniox".to_string()));
    }

    #[test]
    fn test_all_valid_scopes_accepted() {
        let tmp = TempDir::new().unwrap();
        let core = ZulangueCore::new(tmp.path().to_str().unwrap().to_string()).unwrap();
        core.set_api_key("soniox".to_string(), "k".to_string())
            .unwrap();
        assert!(core.has_api_key("soniox".to_string()));
    }

    #[test]
    fn test_verify_api_key_rejects_invalid_scope_without_network_access() {
        let tmp = TempDir::new().unwrap();
        let core = ZulangueCore::new(tmp.path().to_str().unwrap().to_string()).unwrap();
        let result = core.runtime.block_on(
            core.verify_api_key("unsupported".to_string(), Some("candidate".to_string())),
        );
        assert!(matches!(result, Err(CoreError::ValidationFailed { .. })));
    }

    #[test]
    fn test_verify_api_key_requires_candidate_or_active_credential() {
        let tmp = TempDir::new().unwrap();
        let core = ZulangueCore::new(tmp.path().to_str().unwrap().to_string()).unwrap();
        let result = core
            .runtime
            .block_on(core.verify_api_key("soniox".to_string(), None));
        assert!(matches!(result, Err(CoreError::ValidationFailed { .. })));
    }

    #[test]
    fn provider_connection_check_classifies_safe_user_actions() {
        use vt_stt::{SonioxQuotaKind, SttError};

        assert_eq!(
            provider_connection_check(Ok(()), 1).status,
            FfiProviderConnectionStatus::Ready
        );
        assert_eq!(
            provider_connection_check(
                Err(SttError::AuthFailed {
                    message: "redacted".to_string(),
                }),
                2,
            )
            .status,
            FfiProviderConnectionStatus::InvalidCredential
        );
        assert_eq!(
            provider_connection_check(
                Err(SttError::QuotaExhausted {
                    kind: SonioxQuotaKind::OrganizationMonthlyBudget,
                    message: "redacted".to_string(),
                }),
                3,
            )
            .status,
            FfiProviderConnectionStatus::OrganizationMonthlyBudgetExhausted
        );
        assert_eq!(
            provider_connection_check(Err(SttError::ConnectionFailed("redacted".to_string())), 4,)
                .status,
            FfiProviderConnectionStatus::NetworkUnavailable
        );
    }

    // ========== Step 2: task_queue worker ==========

    #[test]
    fn startup_capture_recovery_preserves_created_at_and_sets_interrupted_duration() {
        let tmp = TempDir::new().unwrap();
        let data_dir = tmp.path().to_str().unwrap().to_string();
        let (session_id, created_at) = {
            let core = ZulangueCore::new(data_dir.clone()).unwrap();
            let notebook = core.create_notebook(Some("Recovery".into())).unwrap();
            let profile = core
                .notebook_capture_store
                .get_or_create_profile(&notebook.id)
                .unwrap();
            let session = core.create_notebook_capture_session().unwrap();
            let created_at = core
                .session_store
                .get_session(&session.id)
                .unwrap()
                .created_at;
            let key_ref = format!("zulangue.audio.{}", session.id);
            let key = SessionKey::generate();
            core.key_store.store_key(&key_ref, &key).unwrap();
            let journal = vt_pipeline::CaptureAudioJournal::start(
                session.id.clone(),
                vt_pipeline::RecordingConfig {
                    data_dir: tmp.path().to_path_buf(),
                    sample_rate: 16_000,
                    channels: 1,
                },
                SessionKey::from_bytes(*key.as_bytes()),
            )
            .unwrap();
            journal.push_s16_pcm(&vec![0_u8; 16_000 * 2]).unwrap();
            core.notebook_capture_store
                .create_run(
                    &vt_store::notebook_capture_store::NewNotebookCaptureRun {
                        id: "run-recovery-status".to_string(),
                        notebook_id: notebook.id,
                        session_id: session.id.clone(),
                        remote_health: vt_store::notebook_capture_store::RemoteHealth::Off,
                        audio_journal_path: journal.journal_path().to_string_lossy().into_owned(),
                        audio_key_ref: key_ref,
                        sample_rate: 16_000,
                        channels: 1,
                    },
                    &profile,
                )
                .unwrap();
            drop(journal); // Simulate process loss before stop/final projection.
            (session.id, created_at)
        };

        let recovered = ZulangueCore::new(data_dir).unwrap();
        let session = recovered.session_store.get_session(&session_id).unwrap();
        assert_eq!(session.status, "interrupted");
        assert_eq!(session.duration_ms, 1_000);
        assert_eq!(session.created_at, created_at);
        let run = recovered
            .notebook_capture_store
            .get_run_for_session(&session_id)
            .unwrap()
            .unwrap();
        assert_eq!(
            run.capture_state,
            vt_store::notebook_capture_store::CaptureState::Interrupted
        );
        assert!(run.audio_path.is_some());
    }

    #[test]
    fn test_privacy_default_persists_across_restart() {
        let tmp = TempDir::new().unwrap();
        let first = ZulangueCore::new(tmp.path().to_str().unwrap().to_string()).unwrap();
        first.set_privacy_default("high".to_string()).unwrap();
        drop(first);

        let second = ZulangueCore::new(tmp.path().to_str().unwrap().to_string()).unwrap();
        assert_eq!(second.get_privacy_default(), "high");
    }

    #[test]
    fn session_remote_authorization_never_falls_back_to_global_privacy_default() {
        let tmp = TempDir::new().unwrap();
        let core = ZulangueCore::new(tmp.path().to_str().unwrap().to_string()).unwrap();
        core.set_privacy_default("standard".to_string()).unwrap();

        let missing = core
            .ensure_remote_provider_allowed_for_session("missing-session", "soniox")
            .unwrap_err()
            .to_string();
        assert!(missing.contains("privacy_state_unavailable"));

        core.session_meta
            .set_encrypted_path("missing-level", "audio.enc", "audio-key")
            .unwrap();
        let absent = core
            .ensure_remote_provider_allowed_for_session("missing-level", "soniox")
            .unwrap_err()
            .to_string();
        assert!(absent.contains("privacy_state_invalid"));

        core.session_meta
            .set_privacy_level("invalid-level", "unexpected")
            .unwrap();
        let invalid = core
            .ensure_remote_provider_allowed_for_session("invalid-level", "soniox")
            .unwrap_err()
            .to_string();
        assert!(invalid.contains("privacy_state_invalid"));

        core.session_meta
            .set_privacy_level("standard-session", "standard")
            .unwrap();
        core.ensure_remote_provider_allowed_for_session("standard-session", "soniox")
            .unwrap();

        core.session_meta
            .set_privacy_level("maximum-session", "maximum")
            .unwrap();
        core.ensure_remote_provider_allowed_for_session("maximum-session", "soniox")
            .unwrap();
    }

    #[test]
    fn deferred_provider_bootstrap_prevents_pending_remote_task_claims() {
        let tmp = TempDir::new().unwrap();
        let core = ZulangueCore::new_deferred(tmp.path().to_str().unwrap().to_string()).unwrap();
        let session = core.create_notebook_capture_session().unwrap();
        core.session_meta
            .set_privacy_level(&session.id, "standard")
            .unwrap();

        let task_id = core
            .runtime
            .block_on(core.task_queue.enqueue_with_priority(
                vt_pipeline::TaskPayload::Transcribe {
                    session_id: session.id,
                    language_hint: Some("en".to_string()),
                    remote_authorization: Some(
                        vt_pipeline::RemoteTaskAuthorization::soniox_post_recording(),
                    ),
                },
                vt_pipeline::TaskPriority::Normal,
            ))
            .unwrap();

        // Three normal 200 ms polling intervals must pass without a claim,
        // retry-budget mutation, or lease publication while bootstrap is closed.
        std::thread::sleep(Duration::from_millis(750));
        let waiting = core.get_task_status(task_id.clone()).unwrap();
        assert_eq!(waiting.status, "pending");
        assert_eq!(waiting.retry_count, 0);

        // Opening the gate is idempotent. A missing key is a readiness wait,
        // not a provider failure: it must not claim the row, publish a lease,
        // or consume retry budget.
        core.complete_provider_credential_bootstrap();
        core.complete_provider_credential_bootstrap();
        std::thread::sleep(Duration::from_millis(750));
        let no_key = core.get_task_status(task_id.clone()).unwrap();
        assert_eq!(no_key.status, "pending");
        assert_eq!(no_key.retry_count, 0);
        assert!(no_key.lease_expires_at_ms.is_none());

        // Saving a key is observed by the normal worker poll. This fixture has
        // no capture-run receipt, so it is quarantined before any provider
        // dispatch, proving automatic resume without making a network call.
        core.set_api_key("soniox".to_string(), "configured-test-key".to_string())
            .unwrap();
        let start = std::time::Instant::now();
        loop {
            let claimed = core.get_task_status(task_id.clone()).unwrap();
            if claimed.status == "failed" {
                assert_eq!(claimed.retry_count, 0);
                break;
            }
            assert!(
                start.elapsed() < Duration::from_secs(5),
                "saved key did not resume the durable worker"
            );
            std::thread::sleep(Duration::from_millis(50));
        }

        core.shutdown().unwrap();
        drop(core);
        let reopened = ZulangueCore::new(tmp.path().to_str().unwrap().to_string()).unwrap();
        let durable = reopened.get_task_status(task_id).unwrap();
        assert_eq!(durable.status, "failed");
        assert_eq!(durable.retry_count, 0);
    }

    #[test]
    fn test_init_with_invalid_path_fails() {
        // Point data_dir at a regular file; create_dir_all must reject this
        // because a non-directory already exists at that path. Cross-platform;
        // previous "/System/..." assumption was macOS-SIP-specific.
        let tmp = tempfile::NamedTempFile::new().unwrap();
        let path = tmp.path().to_str().unwrap().to_string();
        let result = ZulangueCore::new(path);
        assert!(result.is_err());
    }

    #[test]
    fn test_double_init_same_dir() {
        let tmp = TempDir::new().unwrap();
        let path = tmp.path().to_str().unwrap().to_string();
        let core1 = ZulangueCore::new(path.clone());
        assert!(core1.is_ok());
        let core2 = ZulangueCore::new(path);
        assert!(core2.is_err());
    }

    #[test]
    fn test_create_session_persists() {
        let tmp = TempDir::new().unwrap();
        let core = ZulangueCore::new(tmp.path().to_str().unwrap().to_string()).unwrap();

        let session = core.create_notebook_capture_session().unwrap();
        assert!(!session.id.is_empty());
        assert_eq!(session.session_type, "recording");
        assert_eq!(session.status, "recording");

        // Verify it's queryable
        let result = core
            .query_sessions(None, None, None, Some(100), None)
            .unwrap();
        assert_eq!(result.total_count, 1);
        assert_eq!(result.sessions[0].id, session.id);
    }

    #[test]
    fn test_search_sessions() {
        let tmp = TempDir::new().unwrap();
        let core = ZulangueCore::new(tmp.path().to_str().unwrap().to_string()).unwrap();

        // Index some content
        core.search_store
            .index_session("s1", "Today we reviewed notebook transcription")
            .unwrap();
        core.search_store
            .index_session("s2", "The weather is nice")
            .unwrap();

        let results = core
            .search_sessions("transcription".to_string(), 10)
            .unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].session_id, "s1");
    }

    #[test]
    fn test_get_session_not_found_returns_error() {
        let tmp = TempDir::new().unwrap();
        let core = ZulangueCore::new(tmp.path().to_str().unwrap().to_string()).unwrap();

        // get_session 对未知 id 返回 NotFound，而不是默认值。
        // 否则 Library UI 会显示假的会话条目。
        let result = core.get_session("nonexistent".to_string());
        assert!(matches!(result, Err(CoreError::NotFound { .. })));
    }
}
