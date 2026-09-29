//! 设备之间直接同步。设计见 docs/architecture/local-first-sync.md。
//!
//! 这里把四样东西接起来:
//!
//! - **vt-sync 的引擎**:谁能连、连上之后怎么对账、字节怎么送到;
//! - **同步文档**:录音、主题、资料库、名单这几类事实文档存在主库的
//!   `sync_documents` 里;笔记与精修稿这类本来就是 Loro 的文档原地同步;
//! - **SQLite**:收到的事实经 vt-store 的物化写回界面读的表,本机的改动经
//!   触发器记进 `sync_changes`,由这里的泵写进文档;
//! - **核心**:写回之后要做的事 —— 投影实时转录、建搜索、永久删除、通知界面。
//!
//! 两个方向在同一把闸里、同一个数据库事务里:
//!
//! - 导出(本机改了):读事实 → 写进文档(只写不同的)→ 存快照 → 清掉待导出;
//! - 导入(对方改了):先把本机还没导出的改动写进文档 → 合入对方的更新 →
//!   物化 → 清掉物化时触发器记下的待导出 → 存快照。
//!
//! 所以文档与表永远是一起提交的:崩溃不会留下「文档有、表没有」的状态,
//! 下一次导出也就不会把对方的内容误当成本机删除。
//!
//! **音频不在这里。** 这个模块只搬文字事实与文档字节;事实的列清单在
//! vt-store 里是封闭的,见 `scripts/test_share_no_audio_gate.sh`。

use std::collections::{BTreeSet, HashMap};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, RwLock, Weak};
use std::time::Duration;

use loro::{ExportMode, LoroDoc, VersionVector};
use sha2::{Digest, Sha256};
use vt_crypto::SessionKey;
use vt_store::library_replica::{
    self as facts, ApplyContext, ChangedScope, ReplicaConnection, ReplicaError, ReplicaStore,
    ReplicaTransaction, SpaceRow,
};
use vt_store::replica_docs as docs;
use vt_sync::{
    DeviceIdentity, DocId, DocumentStore, EndpointId, InvitePurpose, Membership, PairingTicket,
    RelayUrl, SpaceId, StoreError, SyncConfig, SyncEngine, VersionDigest,
};

use crate::notebook_api::QUICK_CAPTURE_NOTEBOOK_INTERNAL_TITLE;
use crate::{CoreError, ZuTalkCore};

/// 设备身份在密钥库里的名字。它只是一把设备签名密钥,与音频的密钥无关。
pub(crate) const IDENTITY_KEY_REF: &str = "sync-device-identity";
/// 自建中继。跨网络时两台设备打不通洞,密文经它转发。
const DEFAULT_RELAY_URL: &str = "https://zulangue-relay.exe.xyz";
const LIBRARY_DOC: &str = "library";
const SESSION_NOTE_PREFIX: &str = "session-note-v1-";
const DOC_CACHE_LIMIT: usize = 64;
const PUMP_INTERVAL: Duration = Duration::from_millis(700);
const PUMP_BATCH: usize = 32;
const INITIAL_EXPORT_STATE: &str = "initial_export";

fn internal(message: impl std::fmt::Display) -> CoreError {
    CoreError::InternalError {
        message: message.to_string(),
    }
}

/// 给界面的错误:消息是一个稳定的代码(`sync.error.*`),App 按它查各语言的
/// 说法。代码之外不带任何细节 —— 细节在日志里。
fn sync_error(code: &str) -> CoreError {
    CoreError::ValidationFailed {
        message: format!("sync.error.{code}"),
    }
}

fn pair_error_code(error: &vt_sync::PairError) -> &'static str {
    match error {
        vt_sync::PairError::Unreachable(_) => "unreachable",
        vt_sync::PairError::Rejected(vt_sync::PairRejection::InvalidOrExpired) => {
            "invalid_or_expired"
        }
        vt_sync::PairError::Rejected(vt_sync::PairRejection::Unavailable) => "unavailable",
        vt_sync::PairError::Interrupted(_) => "interrupted",
    }
}

fn other(message: impl std::fmt::Display) -> ReplicaError {
    ReplicaError::Other(message.to_string())
}

fn now() -> String {
    chrono::Utc::now().to_rfc3339()
}

// ── 文档 id ───────────────────────────────────────────────────────────────

fn recording_doc(session_id: &str) -> String {
    format!("recording/{session_id}")
}

fn topic_doc(notebook_id: &str) -> String {
    format!("topic/{notebook_id}")
}

fn roster_doc(space: &SpaceId) -> String {
    format!("roster/{}", space.to_hex())
}

fn note_doc(doc_id: &str) -> String {
    format!("note/{doc_id}")
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum DocRef<'a> {
    Library,
    Roster(&'a str),
    Recording(&'a str),
    Topic(&'a str),
    Note(&'a str),
}

fn parse_doc(doc: &str) -> Option<DocRef<'_>> {
    if doc == LIBRARY_DOC {
        return Some(DocRef::Library);
    }
    let (prefix, rest) = doc.split_once('/')?;
    if rest.is_empty() || rest.contains(['/', '\\']) {
        return None;
    }
    match prefix {
        "roster" => Some(DocRef::Roster(rest)),
        "recording" => Some(DocRef::Recording(rest)),
        "topic" => Some(DocRef::Topic(rest)),
        "note" => Some(DocRef::Note(rest)),
        _ => None,
    }
}

/// 版本向量的规范摘要:按 peer 排序后哈希,两台设备对同一版本算出同一个值。
fn vv_digest(vv: &VersionVector) -> VersionDigest {
    let mut entries: Vec<(u64, i32)> = vv
        .iter()
        .filter(|(_, counter)| **counter > 0)
        .map(|(peer, counter)| (*peer, *counter))
        .collect();
    entries.sort_unstable();
    let mut hasher = Sha256::new();
    for (peer, counter) in entries {
        hasher.update(peer.to_le_bytes());
        hasher.update(counter.to_le_bytes());
    }
    hasher.finalize().into()
}

fn snapshot_vv(bytes: &[u8]) -> Option<VersionVector> {
    LoroDoc::decode_import_blob_meta(bytes, false)
        .ok()
        .map(|meta| meta.partial_end_vv)
}

fn device_hex(id: &EndpointId) -> String {
    hex::encode(id.as_bytes())
}

fn parse_device(hex_id: &str) -> Option<EndpointId> {
    let bytes: [u8; 32] = hex::decode(hex_id).ok()?.try_into().ok()?;
    EndpointId::from_bytes(&bytes).ok()
}

// ── 空间 ──────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq, Eq)]
enum SpaceKind {
    /// 自己的设备组:整个资料库。
    Devices,
    /// 与别人协作的一个主题:只有这个主题和它的录音、笔记。
    Topic(String),
}

/// 一份笔记类文档存在哪。
#[derive(Debug, Clone, PartialEq, Eq)]
enum NoteHome {
    /// 第 2 纪元块文档:录音笔记、主题笔记。
    Block {
        /// 主题笔记要按标签页打开(可能要先从旧格式迁移);录音笔记为 `None`。
        tab: Option<(String, String)>,
    },
    /// 第 1 纪元编辑器文档:主题的精修稿。
    Editor,
}

/// 写回之后要做的事。事务提交之后才做:它们会打开文档、写文件、叫界面。
#[derive(Default)]
struct Aftermath {
    project: BTreeSet<String>,
    moved: Vec<(String, String, String)>,
    search: bool,
    purge: BTreeSet<String>,
    refresh: bool,
    members: BTreeSet<SpaceId>,
    changed_docs: BTreeSet<String>,
    library_changed: bool,
    notes_changed: BTreeSet<String>,
}

pub(crate) struct LibrarySync {
    core: Weak<ZuTalkCore>,
    replica: Arc<ReplicaStore>,
    data_dir: PathBuf,
    device_hex: String,
    device_name: Mutex<String>,
    engine: SyncEngine,
    unfiled: String,
    runtime: tokio::runtime::Handle,
    /// 事实文档的内存副本。LoroDoc 的 clone 共享状态。
    cache: Mutex<HashMap<String, LoroDoc>>,
    digests: Mutex<HashMap<String, (VersionDigest, Vec<u8>)>>,
    /// 录音笔记的文档 id → 录音 id。按需重建。
    session_notes: Mutex<Option<HashMap<String, String>>>,
    spaces: RwLock<HashMap<SpaceId, SpaceKind>>,
    /// 导出与物化一次只做一件。
    gate: Mutex<()>,
    wake: tokio::sync::Notify,
    stopping: AtomicBool,
    listener: Mutex<Option<Arc<dyn FfiSyncListener>>>,
}

/// 测试与开发时覆盖的引擎设置。
#[derive(Debug, Clone, Default)]
pub(crate) struct SyncOptions {
    pub(crate) relay_urls: Option<Vec<RelayUrl>>,
    pub(crate) local_discovery: Option<bool>,
    pub(crate) loopback_only: bool,
}

impl LibrarySync {
    fn start(
        core: &Arc<ZuTalkCore>,
        device_name: String,
        options: SyncOptions,
    ) -> Result<Arc<Self>, CoreError> {
        let identity = load_or_create_identity(core)?;
        let unfiled = core
            .notebook_store
            .ensure_internal_notebook(QUICK_CAPTURE_NOTEBOOK_INTERNAL_TITLE, "")
            .map_err(internal)?
            .id;
        let relay_urls = match options.relay_urls {
            Some(urls) => urls,
            None => default_relays(),
        };
        let config = SyncConfig {
            relay_urls,
            local_discovery: options.local_discovery.unwrap_or_else(default_local_discovery),
            device_name: device_name.clone(),
            loopback_only: options.loopback_only,
            ..SyncConfig::default()
        };
        let engine = core
            .runtime
            .block_on(SyncEngine::start(identity.clone(), config))
            .map_err(internal)?;
        let sync = Arc::new(Self {
            core: Arc::downgrade(core),
            replica: core.replica.clone(),
            data_dir: core.data_dir.clone(),
            device_hex: device_hex(&identity.id()),
            device_name: Mutex::new(device_name),
            engine,
            unfiled,
            runtime: core.runtime.handle().clone(),
            cache: Mutex::default(),
            digests: Mutex::default(),
            session_notes: Mutex::default(),
            spaces: RwLock::default(),
            gate: Mutex::new(()),
            wake: tokio::sync::Notify::new(),
            stopping: AtomicBool::new(false),
            listener: Mutex::new(None),
        });
        sync.ensure_device_group().map_err(internal)?;
        for row in sync.replica.read(facts::spaces).map_err(internal)? {
            sync.register_space(&row);
        }
        sync.runtime.spawn(pump(Arc::downgrade(&sync)));
        Ok(sync)
    }

    fn stop(&self) {
        self.stopping.store(true, Ordering::SeqCst);
        self.wake.notify_waiters();
        self.runtime.block_on(self.engine.shutdown());
    }

    fn register_space(self: &Arc<Self>, row: &SpaceRow) {
        let Some(space) = SpaceId::from_hex(&row.space_id) else {
            return;
        };
        let kind = match (row.kind.as_str(), &row.notebook_id) {
            ("devices", _) => SpaceKind::Devices,
            ("topic", Some(notebook)) => SpaceKind::Topic(notebook.clone()),
            _ => return,
        };
        self.spaces.write().unwrap().insert(space, kind);
        self.engine.add_space(
            space,
            Arc::new(SpaceStore {
                sync: Arc::downgrade(self),
                space,
            }),
            Arc::new(SpaceRoster {
                sync: Arc::downgrade(self),
                space,
            }),
        );
    }

    fn device_group(&self) -> Option<SpaceId> {
        self.spaces
            .read()
            .unwrap()
            .iter()
            .find(|(_, kind)| **kind == SpaceKind::Devices)
            .map(|(id, _)| *id)
    }

    /// 每台设备生来就有一个只有自己的设备组。
    fn ensure_device_group(&self) -> Result<(), ReplicaError> {
        let _gate = self.gate.lock().unwrap();
        self.replica.write(|tx| {
            if facts::spaces(tx)?.iter().any(|row| row.kind == "devices") {
                return Ok(());
            }
            let space = SpaceId::generate();
            facts::insert_space(
                tx,
                &SpaceRow {
                    space_id: space.to_hex(),
                    kind: "devices".into(),
                    role: "owner".into(),
                    notebook_id: None,
                    label: String::new(),
                },
            )?;
            let roster = self.fact_doc_or_new(tx, &roster_doc(&space))?;
            docs::put_member(&roster, &self.device_hex, &self.device_name.lock().unwrap())?;
            self.save_fact_doc(tx, &roster_doc(&space), &roster)
        })
    }

    // ── 事实文档 ─────────────────────────────────────────────────────────

    fn fact_doc(
        &self,
        conn: &ReplicaConnection,
        id: &str,
    ) -> Result<Option<LoroDoc>, ReplicaError> {
        if let Some(doc) = self.cache.lock().unwrap().get(id) {
            return Ok(Some(doc.clone()));
        }
        let Some(bytes) = facts::load_document(conn, id)? else {
            return Ok(None);
        };
        let doc = LoroDoc::new();
        doc.import(&bytes).map_err(other)?;
        self.cache_put(id, doc.clone());
        Ok(Some(doc))
    }

    fn fact_doc_or_new(&self, conn: &ReplicaConnection, id: &str) -> Result<LoroDoc, ReplicaError> {
        if let Some(doc) = self.fact_doc(conn, id)? {
            return Ok(doc);
        }
        let doc = LoroDoc::new();
        self.cache_put(id, doc.clone());
        Ok(doc)
    }

    fn cache_put(&self, id: &str, doc: LoroDoc) {
        let mut cache = self.cache.lock().unwrap();
        if cache.len() >= DOC_CACHE_LIMIT && !cache.contains_key(id) {
            if let Some(evict) = cache.keys().next().cloned() {
                cache.remove(&evict);
            }
        }
        cache.insert(id.to_string(), doc);
    }

    fn save_fact_doc(
        &self,
        tx: &ReplicaTransaction,
        id: &str,
        doc: &LoroDoc,
    ) -> Result<(), ReplicaError> {
        let snapshot = doc.export(ExportMode::Snapshot).map_err(other)?;
        facts::save_document(tx, id, &snapshot)?;
        self.digests.lock().unwrap().remove(id);
        Ok(())
    }

    fn forget_fact_doc(&self, tx: &ReplicaTransaction, id: &str) -> Result<(), ReplicaError> {
        facts::delete_document(tx, id)?;
        self.cache.lock().unwrap().remove(id);
        self.digests.lock().unwrap().remove(id);
        Ok(())
    }

    /// 事务失败后,内存里的文档可能已经合进了没落盘的东西:整个丢掉重读。
    fn drop_cache(&self) {
        self.cache.lock().unwrap().clear();
        self.digests.lock().unwrap().clear();
    }

    fn tombstoned(&self, conn: &ReplicaConnection, session_id: &str) -> Result<bool, ReplicaError> {
        Ok(self
            .fact_doc(conn, LIBRARY_DOC)?
            .is_some_and(|library| docs::tombstones(&library).contains_key(session_id)))
    }

    // ── 版本 ─────────────────────────────────────────────────────────────

    fn version_of(&self, doc: &str) -> Option<(VersionDigest, Vec<u8>)> {
        if let Some(cached) = self.digests.lock().unwrap().get(doc) {
            return Some(cached.clone());
        }
        let vv = match parse_doc(doc)? {
            DocRef::Note(id) => self.note_vv(id)?,
            _ => {
                if let Some(cached) = self.cache.lock().unwrap().get(doc) {
                    cached.oplog_vv()
                } else {
                    let bytes = self
                        .replica
                        .read(|conn| facts::load_document(conn, doc))
                        .ok()??;
                    snapshot_vv(&bytes)?
                }
            }
        };
        let entry = (vv_digest(&vv), vv.encode());
        // 笔记随时会被本机改,它的版本不缓存。
        if !matches!(parse_doc(doc), Some(DocRef::Note(_))) {
            self.digests
                .lock()
                .unwrap()
                .insert(doc.to_string(), entry.clone());
        }
        Some(entry)
    }

    // ── 空间里有哪些文档 ─────────────────────────────────────────────────

    fn space_kind(&self, space: &SpaceId) -> Option<SpaceKind> {
        self.spaces.read().unwrap().get(space).cloned()
    }

    /// 这份文档属不属于这个空间。收到之前按 id 判断;录音要等读出它的主题才
    /// 知道是不是这个协作主题的,那一步在物化时把关。
    fn in_space(&self, space: &SpaceId, doc: &str) -> bool {
        let Some(kind) = self.space_kind(space) else {
            return false;
        };
        let Some(doc_ref) = parse_doc(doc) else {
            return false;
        };
        match (kind, doc_ref) {
            (_, DocRef::Roster(hex)) => hex == space.to_hex(),
            (SpaceKind::Devices, _) => true,
            (SpaceKind::Topic(_), DocRef::Library) => false,
            (SpaceKind::Topic(notebook), DocRef::Topic(id)) => id == notebook,
            (SpaceKind::Topic(notebook), DocRef::Recording(session)) => self
                .replica
                .read(|conn| facts::read_recording(conn, session, &self.unfiled))
                .ok()
                .flatten()
                .is_none_or(|recording| recording.topic.as_deref() == Some(notebook.as_str())),
            (SpaceKind::Topic(notebook), DocRef::Note(id)) => {
                self.note_belongs_to_topic(id, &notebook)
            }
        }
    }

    fn note_belongs_to_topic(&self, doc_id: &str, notebook: &str) -> bool {
        if let Some(session) = self.session_for_note(doc_id) {
            return self
                .replica
                .read(|conn| facts::read_recording(conn, &session, &self.unfiled))
                .ok()
                .flatten()
                .is_some_and(|recording| recording.topic.as_deref() == Some(notebook));
        }
        let Some(core) = self.core.upgrade() else {
            return false;
        };
        core.notebook_store
            .list_tabs(notebook)
            .map(|tabs| tabs.iter().any(|tab| tab.doc_id == doc_id))
            .unwrap_or(false)
    }

    /// 一个空间此刻的全部文档 id。
    fn space_docs(&self, space: &SpaceId) -> Vec<String> {
        let mut out = BTreeSet::new();
        if let Ok(ids) = self.replica.read(facts::document_ids) {
            out.extend(ids.into_iter().filter(|id| self.in_space(space, id)));
        }
        for id in self.note_doc_ids() {
            let doc = note_doc(&id);
            if self.in_space(space, &doc) {
                out.insert(doc);
            }
        }
        out.into_iter().collect()
    }

    /// 本机所有在同步范围内、并且确实存在的笔记类文档(不含前缀)。
    fn note_doc_ids(&self) -> Vec<String> {
        let Some(core) = self.core.upgrade() else {
            return Vec::new();
        };
        let mut ids = Vec::new();
        let block_dir = crate::block_document_api::block_documents_dir(&self.data_dir);
        for doc_id in self.session_note_map().keys() {
            if block_dir.join(format!("{doc_id}.loro")).exists() {
                ids.push(doc_id.clone());
            }
        }
        if let Ok(notebooks) = core.notebook_store.list_notebooks() {
            for notebook in notebooks {
                if notebook.id == self.unfiled {
                    continue;
                }
                let Ok(tabs) = core.notebook_store.list_tabs(&notebook.id) else {
                    continue;
                };
                for tab in tabs {
                    use vt_store::BuiltinNotebookTab as Kind;
                    let exists = match tab.builtin_kind {
                        Kind::ManualNote => {
                            block_dir.join(format!("{}.loro", tab.doc_id)).exists()
                                || crate::editor_api::snapshot_path(&self.data_dir, &tab.doc_id)
                                    .exists()
                        }
                        Kind::AsyncTranscript => {
                            crate::editor_api::snapshot_path(&self.data_dir, &tab.doc_id).exists()
                        }
                        Kind::RealtimeTranscript => false,
                    };
                    if exists {
                        ids.push(tab.doc_id);
                    }
                }
            }
        }
        ids
    }

    fn session_note_map(&self) -> HashMap<String, String> {
        let mut cached = self.session_notes.lock().unwrap();
        if let Some(map) = cached.as_ref() {
            return map.clone();
        }
        let ids = self
            .replica
            .read(facts::all_recording_ids)
            .unwrap_or_default();
        let map: HashMap<String, String> = ids
            .into_iter()
            .filter_map(|session| {
                crate::block_document_api::session_note_document_id(&session)
                    .ok()
                    .map(|doc| (doc, session))
            })
            .collect();
        *cached = Some(map.clone());
        map
    }

    fn session_for_note(&self, doc_id: &str) -> Option<String> {
        if !doc_id.starts_with(SESSION_NOTE_PREFIX) {
            return None;
        }
        self.session_note_map().get(doc_id).cloned()
    }

    /// 一份笔记类文档在本机住哪;不在同步范围里时为 `None`。
    fn note_home(&self, doc_id: &str) -> Option<NoteHome> {
        if doc_id.starts_with(SESSION_NOTE_PREFIX) {
            return self
                .session_for_note(doc_id)
                .map(|_| NoteHome::Block { tab: None });
        }
        let core = self.core.upgrade()?;
        let (notebook_id, tab) = core
            .notebook_store
            .list_notebooks()
            .ok()?
            .into_iter()
            .filter(|notebook| notebook.id != self.unfiled)
            .find_map(|notebook| {
                core.notebook_store
                    .list_tabs(&notebook.id)
                    .ok()?
                    .into_iter()
                    .find(|tab| tab.doc_id == doc_id)
                    .map(|tab| (notebook.id, tab))
            })?;
        use vt_store::BuiltinNotebookTab as Kind;
        match tab.builtin_kind {
            Kind::ManualNote => Some(NoteHome::Block {
                tab: Some((notebook_id, tab.id)),
            }),
            Kind::AsyncTranscript => Some(NoteHome::Editor),
            Kind::RealtimeTranscript => None,
        }
    }

    fn note_vv(&self, doc_id: &str) -> Option<VersionVector> {
        let core = self.core.upgrade()?;
        match self.note_home(doc_id)? {
            NoteHome::Block { .. } => {
                if let Some(vv) = core.with_open_block_document(doc_id, |doc| doc.oplog_vv()) {
                    return Some(vv);
                }
                let path =
                    crate::block_document_api::block_document_path(&self.data_dir, doc_id).ok()?;
                snapshot_vv(&std::fs::read(path).ok()?)
            }
            NoteHome::Editor => {
                if let Some(bytes) = core.editor_bridge.document_version(doc_id) {
                    return VersionVector::decode(&bytes).ok();
                }
                let path = crate::editor_api::snapshot_path(&self.data_dir, doc_id);
                snapshot_vv(&std::fs::read(path).ok()?)
            }
        }
    }

    fn note_updates_since(&self, doc_id: &str, from: &[u8]) -> Option<Vec<u8>> {
        let core = self.core.upgrade()?;
        let from_vv = VersionVector::decode(from).unwrap_or_default();
        let export = |doc: &LoroDoc| {
            if from_vv.includes_vv(&doc.oplog_vv()) {
                None
            } else {
                doc.export(ExportMode::updates(&from_vv)).ok()
            }
        };
        match self.note_home(doc_id)? {
            NoteHome::Block { .. } => {
                if let Some(updates) = core.with_open_block_document(doc_id, export) {
                    return updates;
                }
                let path =
                    crate::block_document_api::block_document_path(&self.data_dir, doc_id).ok()?;
                let doc = LoroDoc::new();
                doc.import(&std::fs::read(path).ok()?).ok()?;
                export(&doc)
            }
            NoteHome::Editor => {
                if core.editor_bridge.is_session_open(doc_id) {
                    return core.editor_bridge.updates_since(doc_id, from);
                }
                let path = crate::editor_api::snapshot_path(&self.data_dir, doc_id);
                let doc = LoroDoc::new();
                doc.config_text_style(crate::editor_api::voice_tool_style_config());
                doc.import(&std::fs::read(path).ok()?).ok()?;
                export(&doc)
            }
        }
    }

    /// 把对方的更新合进一份笔记类文档。
    fn apply_note(&self, doc_id: &str, update: &[u8]) -> Result<bool, CoreError> {
        let core = self.core.upgrade().ok_or_else(|| internal("核心已关闭"))?;
        let home = self
            .note_home(doc_id)
            .ok_or_else(|| internal(format!("不收这份笔记: {doc_id}")))?;
        let changed = match home {
            NoteHome::Block { tab } => {
                match tab {
                    Some((notebook, tab)) => {
                        core.note_block_document_open(notebook, tab)?;
                    }
                    None => core.block_document_open(
                        doc_id.to_string(),
                        crate::block_document_api::FfiDocumentKind::Note,
                    )?,
                }
                core.import_into_open_block_document(doc_id, update)
                    .unwrap_or_else(|| Err(internal(format!("块文档 {doc_id} 未打开"))))?
            }
            NoteHome::Editor => {
                crate::editor_api::open_editor_session_strict(
                    &core.data_dir,
                    &core.editor_bridge,
                    doc_id,
                )?;
                let before = core.editor_bridge.document_version(doc_id);
                if !core.editor_bridge.import_remote_update(doc_id, update) {
                    return Err(internal(format!("合入精修稿更新失败: {doc_id}")));
                }
                let changed = core.editor_bridge.document_version(doc_id) != before;
                if changed {
                    crate::editor_api::flush_snapshot_to_disk_result(
                        &core.data_dir,
                        &core.editor_bridge,
                        doc_id,
                    )
                    .map_err(internal)?;
                    crate::editor_api::notify_editor_callback(&core.editor_callbacks, doc_id);
                }
                changed
            }
        };
        if changed {
            if let Some(listener) = self.listener() {
                listener.on_note_changed(doc_id.to_string());
            }
        }
        Ok(changed)
    }

    fn listener(&self) -> Option<Arc<dyn FfiSyncListener>> {
        self.listener.lock().unwrap().clone()
    }

    // ── 导出 ─────────────────────────────────────────────────────────────

    /// 有没有别的设备要同步。只有自己时什么也不导出:从没配对过的资料库不会
    /// 平白多出一份文档副本。
    fn has_peers(&self) -> bool {
        let spaces: Vec<SpaceId> = self.spaces.read().unwrap().keys().copied().collect();
        spaces
            .iter()
            .any(|space| self.roster_members(space).len() > 1)
    }

    /// 第一次有了别的设备:把整个资料库记成待导出。
    fn ensure_initial_export(&self) -> Result<(), ReplicaError> {
        if self
            .replica
            .read(|conn| facts::state(conn, INITIAL_EXPORT_STATE))?
            .is_some()
        {
            return Ok(());
        }
        self.replica.write(|tx| {
            for session in facts::all_recording_ids(tx)? {
                facts::mark_changed(tx, &ChangedScope::Recording(session))?;
            }
            for topic in facts::all_topic_ids(tx, &self.unfiled)? {
                facts::mark_changed(tx, &ChangedScope::Topic(topic))?;
            }
            facts::mark_changed(tx, &ChangedScope::Library)?;
            facts::set_state(tx, INITIAL_EXPORT_STATE, Some(&now()))
        })
    }

    fn pump_once(&self) {
        if !self.has_peers() {
            return;
        }
        if let Err(error) = self.ensure_initial_export() {
            tracing::warn!(%error, "同步:全量导出登记失败");
            return;
        }
        let changes = match self
            .replica
            .read(|conn| facts::pending_changes(conn, PUMP_BATCH))
        {
            Ok(changes) => changes,
            Err(error) => {
                tracing::warn!(%error, "同步:读待导出失败");
                return;
            }
        };
        for scope in changes {
            let mut after = Aftermath::default();
            let result = {
                let _gate = self.gate.lock().unwrap();
                self.replica
                    .write(|tx| self.export_into(tx, &scope, &mut after))
            };
            match result {
                Ok(()) => self.run_aftermath(after, None),
                Err(error) => {
                    self.drop_cache();
                    tracing::warn!(?scope, %error, "同步:导出失败");
                }
            }
        }
    }

    fn export_into(
        &self,
        tx: &ReplicaTransaction,
        scope: &ChangedScope,
        after: &mut Aftermath,
    ) -> Result<(), ReplicaError> {
        match scope {
            ChangedScope::Recording(session) => {
                if !facts::is_exportable(tx, session)? {
                    // 还在录:留在队列里,录完再导。
                    return Ok(());
                }
                let id = recording_doc(session);
                match facts::read_recording(tx, session, &self.unfiled)? {
                    None => {
                        // 本机永久删除了它:留一块墓碑,所有设备跟着删。
                        if self.fact_doc(tx, &id)?.is_some() {
                            let library = self.fact_doc_or_new(tx, LIBRARY_DOC)?;
                            if docs::add_tombstone(&library, session, &now())? {
                                self.save_fact_doc(tx, LIBRARY_DOC, &library)?;
                                after.changed_docs.insert(LIBRARY_DOC.to_string());
                            }
                            self.forget_fact_doc(tx, &id)?;
                        }
                        *self.session_notes.lock().unwrap() = None;
                    }
                    Some(recording) => {
                        let is_origin = facts::recording_origin(tx, session)?.is_none();
                        let doc = if is_origin {
                            Some(self.fact_doc_or_new(tx, &id)?)
                        } else {
                            self.fact_doc(tx, &id)?
                        };
                        if let Some(doc) = doc {
                            if docs::write_recording(&doc, &recording, &self.device_hex, is_origin)?
                            {
                                self.save_fact_doc(tx, &id, &doc)?;
                                after.changed_docs.insert(id);
                            }
                        }
                        *self.session_notes.lock().unwrap() = None;
                    }
                }
            }
            ChangedScope::Topic(notebook) => {
                if notebook != &self.unfiled {
                    if let Some(topic) = facts::read_topic(tx, notebook)? {
                        let id = topic_doc(notebook);
                        let doc = self.fact_doc_or_new(tx, &id)?;
                        if docs::write_topic(&doc, &topic)? {
                            self.save_fact_doc(tx, &id, &doc)?;
                            after.changed_docs.insert(id);
                        }
                    }
                }
            }
            ChangedScope::Library => {
                let doc = self.fact_doc_or_new(tx, LIBRARY_DOC)?;
                let library = facts::read_library(tx)?;
                if docs::write_library(&doc, &library, |speaker, link| {
                    facts::speaker_link_applicable(tx, speaker, link).unwrap_or(false)
                })? {
                    self.save_fact_doc(tx, LIBRARY_DOC, &doc)?;
                    after.changed_docs.insert(LIBRARY_DOC.to_string());
                }
            }
        }
        facts::clear_change(tx, scope)
    }

    // ── 导入 ─────────────────────────────────────────────────────────────

    fn apply(&self, space: SpaceId, doc_id: &str, update: &[u8]) -> Result<bool, StoreError> {
        match parse_doc(doc_id) {
            None => Err(StoreError::NotAccepted(doc_id.to_string())),
            Some(DocRef::Note(id)) => {
                let changed = self
                    .apply_note(id, update)
                    .map_err(|e| StoreError::Rejected(e.to_string()))?;
                if changed {
                    let mut after = Aftermath::default();
                    after.changed_docs.insert(doc_id.to_string());
                    self.run_aftermath(after, Some(space));
                }
                Ok(changed)
            }
            Some(doc_ref) => {
                let mut after = Aftermath::default();
                let result = {
                    let _gate = self.gate.lock().unwrap();
                    self.replica.write(|tx| {
                        // 先把本机还没导出的改动写进文档,合并时才有它们的份。
                        let scope = match doc_ref {
                            DocRef::Recording(session) => {
                                Some(ChangedScope::Recording(session.to_string()))
                            }
                            DocRef::Topic(notebook) => {
                                Some(ChangedScope::Topic(notebook.to_string()))
                            }
                            DocRef::Library => Some(ChangedScope::Library),
                            _ => None,
                        };
                        if let Some(scope) = &scope {
                            let pending = facts::pending_changes(tx, usize::MAX)?;
                            if pending.contains(scope) {
                                self.export_into(tx, scope, &mut after)?;
                            }
                        }
                        let doc = self.fact_doc_or_new(tx, doc_id)?;
                        let before = doc.oplog_vv();
                        doc.import(update).map_err(other)?;
                        if doc.oplog_vv() == before {
                            return Ok(false);
                        }
                        if let DocRef::Recording(session) = doc_ref {
                            if !self.recording_fits_space(&space, &doc)? {
                                return Err(other(format!("录音 {session} 不属于这个协作主题")));
                            }
                        }
                        self.materialize(tx, doc_id, &doc, &mut after)?;
                        self.save_fact_doc(tx, doc_id, &doc)?;
                        Ok(true)
                    })
                };
                match result {
                    Ok(changed) => {
                        if changed {
                            after.changed_docs.insert(doc_id.to_string());
                        }
                        self.run_aftermath(after, Some(space));
                        Ok(changed)
                    }
                    Err(error) => {
                        self.drop_cache();
                        Err(StoreError::Rejected(error.to_string()))
                    }
                }
            }
        }
    }

    /// 协作主题里收到的录音必须是这个主题的:同事不能借一个主题往我的资料库
    /// 里塞别的东西。
    fn recording_fits_space(&self, space: &SpaceId, doc: &LoroDoc) -> Result<bool, ReplicaError> {
        match self.space_kind(space) {
            Some(SpaceKind::Topic(notebook)) => {
                Ok(docs::read_recording(doc)?.is_none_or(|(recording, _)| {
                    recording.topic.as_deref() == Some(notebook.as_str())
                }))
            }
            _ => Ok(true),
        }
    }

    fn materialize(
        &self,
        tx: &ReplicaTransaction,
        doc_id: &str,
        doc: &LoroDoc,
        after: &mut Aftermath,
    ) -> Result<(), ReplicaError> {
        match parse_doc(doc_id) {
            Some(DocRef::Recording(session)) => {
                if self.tombstoned(tx, session)? {
                    return Ok(());
                }
                let Some((recording, origin)) = docs::read_recording(doc)? else {
                    return Ok(());
                };
                let links = match self.fact_doc(tx, LIBRARY_DOC)? {
                    Some(library) => Some(docs::read_library(&library)?.speaker_links),
                    None => None,
                };
                let outcome = facts::apply_recording(
                    tx,
                    &recording,
                    &ApplyContext {
                        local_device: &self.device_hex,
                        origin_device: &origin,
                        unfiled_notebook: &self.unfiled,
                        speaker_links: links.as_ref(),
                    },
                )?;
                if outcome.skipped {
                    return Ok(());
                }
                if outcome.created || outcome.transcript_changed {
                    after.project.insert(session.to_string());
                }
                if let Some(from) = outcome.moved_from {
                    after
                        .moved
                        .push((session.to_string(), from, outcome.notebook.clone()));
                }
                if outcome.refined_arrived {
                    after.search = true;
                }
                if outcome.created {
                    after.refresh = true;
                    *self.session_notes.lock().unwrap() = None;
                }
                after.library_changed = true;
                facts::clear_change(tx, &ChangedScope::Recording(session.to_string()))
            }
            Some(DocRef::Topic(notebook)) => {
                let Some(topic) = docs::read_topic(doc)? else {
                    return Ok(());
                };
                let outcome = facts::apply_topic(tx, &topic)?;
                for waiting in outcome.waiting_recordings {
                    let id = recording_doc(&waiting);
                    if let Some(recording) = self.fact_doc(tx, &id)? {
                        self.materialize(tx, &id, &recording, after)?;
                    }
                }
                if outcome.created {
                    after.refresh = true;
                }
                after.library_changed = true;
                facts::clear_change(tx, &ChangedScope::Topic(notebook.to_string()))
            }
            Some(DocRef::Library) => {
                facts::apply_library(tx, &docs::read_library(doc)?)?;
                for session in docs::tombstones(doc).into_keys() {
                    let here: bool = tx.query_row(
                        "SELECT EXISTS(SELECT 1 FROM session_records WHERE id = ?1)",
                        [&session],
                        |row| row.get(0),
                    )?;
                    if here {
                        after.purge.insert(session);
                    }
                }
                after.library_changed = true;
                facts::clear_change(tx, &ChangedScope::Library)
            }
            Some(DocRef::Roster(hex)) => {
                if let Some(space) = SpaceId::from_hex(hex) {
                    after.members.insert(space);
                }
                Ok(())
            }
            Some(DocRef::Note(_)) | None => Ok(()),
        }
    }

    fn run_aftermath(&self, after: Aftermath, source: Option<SpaceId>) {
        let Some(core) = self.core.upgrade() else {
            return;
        };
        for session in &after.purge {
            if let Err(error) = core.purge_session_forever(session) {
                tracing::warn!(session_id = %session, %error, "同步:按墓碑永久删除失败");
                continue;
            }
            let id = recording_doc(session);
            let _gate = self.gate.lock().unwrap();
            let _ = self.replica.write(|tx| {
                self.forget_fact_doc(tx, &id)?;
                facts::clear_change(tx, &ChangedScope::Recording(session.clone()))
            });
        }
        for (session, from, to) in &after.moved {
            if let Err(error) = core.move_realtime_slice_locally(session, from, to) {
                tracing::warn!(session_id = %session, %error, "同步:挪实时转录投影失败");
            }
            // 从本机的「未归入主题」挪走:那两份文档不同步,本机那一节自己清掉。
            if from == &self.unfiled {
                core.clear_unfiled_sections(session, from);
            }
        }
        for session in &after.project {
            match core.notebook_capture_store.get_run_for_session(session) {
                Ok(Some(run)) => {
                    if let Err(error) = core.sync_capture_into_t2_transcript(&run, true) {
                        tracing::warn!(session_id = %session, %error, "同步:投影实时转录失败");
                    }
                }
                Ok(None) => {}
                Err(error) => tracing::warn!(session_id = %session, %error, "同步:读 run 失败"),
            }
        }
        if after.search {
            if let Err(error) = core.resume_pending_async_search_projections() {
                tracing::warn!(%error, "同步:建精修稿搜索失败");
            }
        }
        for space in &after.members {
            self.engine.members_changed(space);
        }
        if after.refresh {
            let spaces: Vec<SpaceId> = self.spaces.read().unwrap().keys().copied().collect();
            for space in spaces {
                self.engine.refresh(&space);
            }
        }
        if !after.changed_docs.is_empty() {
            let spaces: Vec<SpaceId> = self.spaces.read().unwrap().keys().copied().collect();
            for doc in &after.changed_docs {
                self.digests.lock().unwrap().remove(doc);
                for space in &spaces {
                    // 收到它的那个空间由引擎自己转发(除了来源那条连接)。
                    if Some(*space) != source && self.in_space(space, doc) {
                        self.engine.notify_changed(space, doc);
                    }
                }
            }
        }
        if let Some(listener) = self.listener() {
            if after.library_changed {
                listener.on_library_changed();
            }
            for doc in &after.notes_changed {
                listener.on_note_changed(doc.clone());
            }
        }
    }

    // ── 名单 ─────────────────────────────────────────────────────────────

    fn roster(&self, space: &SpaceId) -> docs::Roster {
        let removed = self
            .replica
            .read(|conn| facts::removed_devices(conn, &space.to_hex()))
            .unwrap_or_default();
        let mut roster = self
            .replica
            .read(|conn| self.fact_doc(conn, &roster_doc(space)))
            .ok()
            .flatten()
            .map(|doc| docs::read_roster(&doc))
            .unwrap_or_default();
        for device in removed {
            roster.removed.entry(device).or_default();
        }
        roster
    }

    fn roster_members(&self, space: &SpaceId) -> Vec<EndpointId> {
        self.roster(space)
            .members()
            .filter_map(|(hex, _)| parse_device(hex))
            .collect()
    }

    fn admit(&self, space: &SpaceId, device: EndpointId, name: &str) -> Result<(), String> {
        let id = roster_doc(space);
        let result = {
            let _gate = self.gate.lock().unwrap();
            self.replica.write(|tx| {
                let doc = self.fact_doc_or_new(tx, &id)?;
                docs::put_member(&doc, &device_hex(&device), name)?;
                self.save_fact_doc(tx, &id, &doc)
            })
        };
        result.map_err(|error| {
            self.drop_cache();
            error.to_string()
        })?;
        self.engine.notify_changed(space, &id);
        self.wake.notify_one();
        Ok(())
    }

    // ── 界面要的 ─────────────────────────────────────────────────────────

    fn status(&self) -> FfiSyncStatus {
        let group = self.device_group();
        let mut devices = Vec::new();
        if let Some(space) = group {
            let roster = self.roster(&space);
            let peers: HashMap<String, vt_sync::PeerStatus> = self
                .engine
                .peers(&space)
                .into_iter()
                .map(|peer| (device_hex(&peer.device), peer))
                .collect();
            for (hex, name) in roster.members() {
                let peer = peers.get(hex);
                devices.push(FfiSyncDevice {
                    device_id: hex.clone(),
                    name: name.clone(),
                    is_this_device: *hex == self.device_hex,
                    connected: peer.is_some_and(|p| p.connected),
                    via_relay: peer.is_some_and(|p| p.via_relay),
                    last_synced_unix_ms: peer.and_then(|p| p.last_synced_unix_ms),
                });
            }
        }
        FfiSyncStatus {
            running: true,
            device_id: self.device_hex.clone(),
            device_name: self.device_name.lock().unwrap().clone(),
            devices,
        }
    }

    /// 本机的名字变了:名单上改掉,别的设备跟着看到。
    fn rename(&self, name: String) {
        *self.device_name.lock().unwrap() = name.clone();
        let spaces: Vec<SpaceId> = self.spaces.read().unwrap().keys().copied().collect();
        for space in spaces {
            let id = roster_doc(&space);
            let written = {
                let _gate = self.gate.lock().unwrap();
                self.replica.write(|tx| {
                    let doc = self.fact_doc_or_new(tx, &id)?;
                    let changed = docs::put_member(&doc, &self.device_hex, &name)?;
                    if changed {
                        self.save_fact_doc(tx, &id, &doc)?;
                    }
                    Ok(changed)
                })
            };
            if matches!(written, Ok(true)) {
                self.engine.notify_changed(&space, &id);
            }
        }
    }

    fn create_device_invite(&self) -> Result<String, CoreError> {
        let space = self
            .device_group()
            .ok_or_else(|| internal("本机还没有设备组"))?;
        let ticket = self
            .runtime
            .block_on(self.engine.create_invite(&space, InvitePurpose::Device, ""))
            .map_err(internal)?;
        Ok(ticket.to_string())
    }

    fn cancel_invites(&self) {
        if let Some(space) = self.device_group() {
            self.engine.revoke_invites(&space);
        }
    }

    /// 用别人给的配对码加入。现在只处理加自己的 Mac;协作主题与备份各有入口。
    fn join(self: &Arc<Self>, code: &str) -> Result<FfiSyncJoinResult, CoreError> {
        let ticket: PairingTicket = code.parse().map_err(|_| sync_error("not_a_code"))?;
        if ticket.inviter.id == parse_device(&self.device_hex).expect("本机 id 合法") {
            return Err(sync_error("own_code"));
        }
        if ticket.purpose != InvitePurpose::Device {
            return Err(sync_error("wrong_purpose"));
        }
        let joined = self
            .runtime
            .block_on(self.engine.join(&ticket))
            .map_err(|error| {
                tracing::info!(%error, "同步:配对没有成功");
                sync_error(pair_error_code(&error))
            })?;
        match joined.purpose {
            InvitePurpose::Device => self.adopt_device_group(&joined)?,
            InvitePurpose::Topic | InvitePurpose::Backup => return Err(sync_error("wrong_purpose")),
        }
        Ok(FfiSyncJoinResult {
            purpose: joined.purpose.into(),
            label: joined.label,
            inviter_name: joined.inviter_name,
        })
    }

    /// 换上对方的设备组。本机的录音与主题原样留着,稍后全部导出给新组;
    /// 旧组的资料库文档丢掉重建,免得旧组的墓碑、名单混进新组。
    fn adopt_device_group(self: &Arc<Self>, joined: &vt_sync::Joined) -> Result<(), CoreError> {
        let old = self.device_group();
        {
            let _gate = self.gate.lock().unwrap();
            self.replica
                .write(|tx| {
                    if let Some(old) = old {
                        facts::delete_space(tx, &old.to_hex())?;
                        self.forget_fact_doc(tx, &roster_doc(&old))?;
                    }
                    self.forget_fact_doc(tx, LIBRARY_DOC)?;
                    facts::insert_space(
                        tx,
                        &SpaceRow {
                            space_id: joined.space.to_hex(),
                            kind: "devices".into(),
                            role: "member".into(),
                            notebook_id: None,
                            label: String::new(),
                        },
                    )?;
                    let roster = self.fact_doc_or_new(tx, &roster_doc(&joined.space))?;
                    docs::put_member(&roster, &self.device_hex, &self.device_name.lock().unwrap())?;
                    docs::put_member(&roster, &device_hex(&joined.inviter), &joined.inviter_name)?;
                    self.save_fact_doc(tx, &roster_doc(&joined.space), &roster)?;
                    facts::set_state(tx, INITIAL_EXPORT_STATE, None)
                })
                .map_err(internal)?;
        }
        if let Some(old) = old {
            self.engine.remove_space(&old);
            self.spaces.write().unwrap().remove(&old);
        }
        self.register_space(&SpaceRow {
            space_id: joined.space.to_hex(),
            kind: "devices".into(),
            role: "member".into(),
            notebook_id: None,
            label: String::new(),
        });
        self.wake.notify_one();
        Ok(())
    }

    /// 从设备组里移除一台设备。永久:同一个设备身份再也进不来。
    fn remove_device(&self, device: &str) -> Result<(), CoreError> {
        if device == self.device_hex {
            return Err(sync_error("cannot_remove_self"));
        }
        let space = self
            .device_group()
            .ok_or_else(|| internal("本机还没有设备组"))?;
        let id = roster_doc(&space);
        {
            let _gate = self.gate.lock().unwrap();
            self.replica
                .write(|tx| {
                    let doc = self.fact_doc_or_new(tx, &id)?;
                    docs::remove_member(&doc, device, &now())?;
                    self.save_fact_doc(tx, &id, &doc)?;
                    facts::mark_removed(tx, &space.to_hex(), device)
                })
                .map_err(internal)?;
        }
        self.engine.members_changed(&space);
        self.engine.notify_changed(&space, &id);
        Ok(())
    }

    /// 本机改了一份笔记类文档。
    fn note_changed(&self, doc_id: &str) {
        let doc = note_doc(doc_id);
        let spaces: Vec<SpaceId> = self.spaces.read().unwrap().keys().copied().collect();
        for space in spaces {
            // 引擎向写循环要摘要时再按空间过滤,这里不查库。
            self.engine.notify_changed(&space, &doc);
        }
    }
}

async fn pump(sync: Weak<LibrarySync>) {
    loop {
        let Some(strong) = sync.upgrade() else {
            return;
        };
        if strong.stopping.load(Ordering::SeqCst) {
            return;
        }
        let worker = strong.clone();
        let _ = tokio::task::spawn_blocking(move || worker.pump_once()).await;
        tokio::select! {
            _ = tokio::time::sleep(PUMP_INTERVAL) => {}
            _ = strong.wake.notified() => {}
        }
    }
}

fn default_relays() -> Vec<RelayUrl> {
    // 开发构建可以用 ZUTALK_SYNC_RELAY 指向别的中继,空串表示不用中继。
    #[cfg(debug_assertions)]
    if let Ok(value) = std::env::var("ZUTALK_SYNC_RELAY") {
        return value
            .split(',')
            .filter(|s| !s.trim().is_empty())
            .filter_map(|s| s.trim().parse().ok())
            .collect();
    }
    DEFAULT_RELAY_URL.parse().into_iter().collect()
}

fn default_local_discovery() -> bool {
    // 开发构建可以用 ZUTALK_SYNC_MDNS=0 关掉局域网发现:同机起两个开发版联调时,
    // 系统的「本地网络」授权框会卡住无人值守的测试。
    #[cfg(debug_assertions)]
    if std::env::var("ZUTALK_SYNC_MDNS").is_ok_and(|value| value == "0") {
        return false;
    }
    true
}

fn load_or_create_identity(core: &ZuTalkCore) -> Result<DeviceIdentity, CoreError> {
    if core.key_store.key_exists(IDENTITY_KEY_REF) {
        let key = core
            .key_store
            .load_key(IDENTITY_KEY_REF)
            .map_err(|e| internal(format!("读设备身份: {e}")))?;
        return Ok(DeviceIdentity::from_secret_bytes(key.as_bytes()));
    }
    let identity = DeviceIdentity::generate();
    core.key_store
        .store_key(
            IDENTITY_KEY_REF,
            &SessionKey::from_bytes(identity.to_secret_bytes()),
        )
        .map_err(|e| internal(format!("存设备身份: {e}")))?;
    Ok(identity)
}

// ── 引擎看到的空间 ────────────────────────────────────────────────────────

struct SpaceStore {
    sync: Weak<LibrarySync>,
    space: SpaceId,
}

impl DocumentStore for SpaceStore {
    fn summary(&self) -> Vec<(DocId, VersionDigest)> {
        let Some(sync) = self.sync.upgrade() else {
            return Vec::new();
        };
        sync.space_docs(&self.space)
            .into_iter()
            .filter_map(|doc| {
                let (digest, _) = sync.version_of(&doc)?;
                Some((doc, digest))
            })
            .collect()
    }

    fn digest(&self, doc: &DocId) -> Option<VersionDigest> {
        let sync = self.sync.upgrade()?;
        if !sync.in_space(&self.space, doc) {
            return None;
        }
        sync.version_of(doc).map(|(digest, _)| digest)
    }

    fn version(&self, doc: &DocId) -> Option<Vec<u8>> {
        let sync = self.sync.upgrade()?;
        if !sync.in_space(&self.space, doc) {
            return None;
        }
        sync.version_of(doc).map(|(_, vv)| vv)
    }

    fn updates_since(&self, doc: &DocId, from: &[u8]) -> Option<Vec<u8>> {
        let sync = self.sync.upgrade()?;
        if !sync.in_space(&self.space, doc) {
            return None;
        }
        match parse_doc(doc)? {
            DocRef::Note(id) => sync.note_updates_since(id, from),
            _ => {
                let loaded = sync.replica.read(|conn| sync.fact_doc(conn, doc)).ok()??;
                let from = VersionVector::decode(from).unwrap_or_default();
                if from.includes_vv(&loaded.oplog_vv()) {
                    return None;
                }
                loaded.export(ExportMode::updates(&from)).ok()
            }
        }
    }

    fn apply(&self, doc: &DocId, update: &[u8]) -> Result<bool, StoreError> {
        let sync = self
            .sync
            .upgrade()
            .ok_or_else(|| StoreError::Storage("同步已停止".into()))?;
        if !sync.accepts(&self.space, doc) {
            return Err(StoreError::NotAccepted(doc.clone()));
        }
        sync.apply(self.space, doc, update)
    }

    fn accepts(&self, doc: &DocId) -> bool {
        self.sync
            .upgrade()
            .is_some_and(|sync| sync.accepts(&self.space, doc))
    }
}

impl LibrarySync {
    fn accepts(&self, space: &SpaceId, doc: &str) -> bool {
        if !self.in_space(space, doc) {
            return false;
        }
        match parse_doc(doc) {
            Some(DocRef::Recording(session)) => !self
                .replica
                .read(|conn| self.tombstoned(conn, session))
                .unwrap_or(true),
            Some(DocRef::Note(id)) => self.note_home(id).is_some(),
            Some(_) => true,
            None => false,
        }
    }
}

struct SpaceRoster {
    sync: Weak<LibrarySync>,
    space: SpaceId,
}

impl Membership for SpaceRoster {
    fn members(&self) -> Vec<EndpointId> {
        self.sync
            .upgrade()
            .map(|sync| sync.roster_members(&self.space))
            .unwrap_or_default()
    }

    fn admit(&self, device: EndpointId, name: &str) -> Result<(), String> {
        let sync = self.sync.upgrade().ok_or("同步已停止")?;
        sync.admit(&self.space, device, name)
    }
}

// ── 核心这一侧 ────────────────────────────────────────────────────────────

/// 核心持有的同步入口。同步没开时是空的,钩子什么也不做。
#[derive(Clone, Default)]
pub(crate) struct SyncSlot(Arc<RwLock<Option<Arc<LibrarySync>>>>);

impl SyncSlot {
    fn get(&self) -> Option<Arc<LibrarySync>> {
        self.0.read().unwrap().clone()
    }

    fn set(&self, sync: Option<Arc<LibrarySync>>) -> Option<Arc<LibrarySync>> {
        std::mem::replace(&mut *self.0.write().unwrap(), sync)
    }

    /// 本机改了一份笔记类文档。
    pub(crate) fn note_changed(&self, doc_id: &str) {
        if let Some(sync) = self.get() {
            sync.note_changed(doc_id);
        }
    }
}

impl ZuTalkCore {
    pub(crate) fn library_sync_note_changed(&self, doc_id: &str) {
        self.library_sync.note_changed(doc_id);
    }

    fn builtin_tab(
        &self,
        notebook: &str,
        kind: vt_store::BuiltinNotebookTab,
    ) -> Result<Option<vt_store::NotebookTabRecord>, CoreError> {
        Ok(self
            .notebook_store
            .list_tabs(notebook)
            .map_err(internal)?
            .into_iter()
            .find(|tab| tab.builtin_kind == kind && tab.deleted_at.is_none()))
    }

    /// 另一台设备挪了一场录音:本机只挪自己投影的实时转录那一节。精修稿与
    /// 笔记在同步的文档里,挪的那台已经搬好了。
    pub(crate) fn move_realtime_slice_locally(
        &self,
        session_id: &str,
        from_notebook: &str,
        to_notebook: &str,
    ) -> Result<(), CoreError> {
        use vt_store::BuiltinNotebookTab;
        let tab_of = |notebook: &str| -> Result<Option<String>, CoreError> {
            Ok(self
                .builtin_tab(notebook, BuiltinNotebookTab::RealtimeTranscript)?
                .map(|tab| tab.doc_id))
        };
        let (Some(source), Some(target)) = (tab_of(from_notebook)?, tab_of(to_notebook)?) else {
            return Ok(());
        };
        let _guard = crate::editor_api::editor_document_mutation_guard();
        self.open_transcript_block_document(&source)?;
        let slice = self.with_transcript(&source, |projection| {
            projection
                .session_slice(session_id)
                .map_err(crate::notebook_capture_api::store_error)
        })?;
        if slice.is_empty() {
            return Ok(());
        }
        self.open_transcript_block_document(&target)?;
        self.with_transcript(&target, |projection| {
            projection
                .splice_session_slice(&slice, None)
                .map_err(crate::notebook_capture_api::store_error)
        })?;
        self.persist_block_document(&target)?;
        self.with_transcript(&source, |projection| {
            projection
                .remove_session_slice(session_id)
                .map_err(crate::notebook_capture_api::store_error)
        })?;
        self.persist_block_document(&source)
    }

    /// 录音从本机的「未归入主题」被别的设备挪走:清掉本机那两份不同步的
    /// 文档里的这一节。
    pub(crate) fn clear_unfiled_sections(&self, session_id: &str, unfiled: &str) {
        use vt_store::BuiltinNotebookTab;
        for kind in [
            BuiltinNotebookTab::AsyncTranscript,
            BuiltinNotebookTab::ManualNote,
        ] {
            let Ok(Some(tab)) = self.builtin_tab(unfiled, kind) else {
                continue;
            };
            if !crate::editor_api::snapshot_path(&self.data_dir, &tab.doc_id).exists() {
                continue;
            }
            if let Err(error) = self.remove_flat_section(&tab.doc_id, session_id) {
                tracing::warn!(session_id, %error, "同步:清本机未归入的旧节失败");
            }
        }
    }

    /// 这场录音是不是另一台设备录的。是的话返回那台设备的名字(不知道名字时为
    /// 空串)。
    pub(crate) fn recorded_elsewhere(&self, session_id: &str) -> Option<String> {
        let origin = self
            .replica
            .read(|conn| facts::recording_origin(conn, session_id))
            .ok()??;
        let name = self
            .library_sync
            .get()
            .and_then(|sync| {
                let space = sync.device_group()?;
                sync.roster(&space).devices.get(&origin).cloned()
            })
            .unwrap_or_default();
        Some(name)
    }

    pub(crate) fn start_library_sync(
        self: &Arc<Self>,
        device_name: String,
        options: SyncOptions,
    ) -> Result<FfiSyncStatus, CoreError> {
        if let Some(sync) = self.library_sync.get() {
            sync.rename(device_name);
            return Ok(sync.status());
        }
        let sync = LibrarySync::start(self, device_name, options)?;
        let status = sync.status();
        self.library_sync.set(Some(sync));
        Ok(status)
    }

    fn running_sync(&self) -> Result<Arc<LibrarySync>, CoreError> {
        self.library_sync
            .get()
            .ok_or_else(|| sync_error("not_running"))
    }
}

// ── FFI ──────────────────────────────────────────────────────────────────

/// 同步有了变化,界面该刷新了。
#[uniffi::export(callback_interface)]
pub trait FfiSyncListener: Send + Sync {
    /// 录音、主题、人名等资料库内容变了。
    fn on_library_changed(&self);
    /// 一份笔记或精修稿收到了别的设备的改动。
    fn on_note_changed(&self, doc_id: String);
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiSyncDevice {
    pub device_id: String,
    pub name: String,
    pub is_this_device: bool,
    pub connected: bool,
    pub via_relay: bool,
    pub last_synced_unix_ms: Option<i64>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiSyncStatus {
    pub running: bool,
    pub device_id: String,
    pub device_name: String,
    /// 设备组里的全部设备,含本机。
    pub devices: Vec<FfiSyncDevice>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FfiSyncInvitePurpose {
    Device,
    Topic,
    Backup,
}

impl From<InvitePurpose> for FfiSyncInvitePurpose {
    fn from(purpose: InvitePurpose) -> Self {
        match purpose {
            InvitePurpose::Device => Self::Device,
            InvitePurpose::Topic => Self::Topic,
            InvitePurpose::Backup => Self::Backup,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiSyncJoinResult {
    pub purpose: FfiSyncInvitePurpose,
    pub label: String,
    pub inviter_name: String,
}

#[uniffi::export]
impl ZuTalkCore {
    /// 打开设备同步。已经打开时只更新本机名字。
    pub fn sync_start(self: Arc<Self>, device_name: String) -> Result<FfiSyncStatus, CoreError> {
        self.start_library_sync(device_name, SyncOptions::default())
    }

    /// 关掉设备同步:断开所有连接。本机的资料原样留着。
    pub fn sync_stop(&self) {
        if let Some(sync) = self.library_sync.set(None) {
            sync.stop();
        }
    }

    pub fn sync_status(&self) -> FfiSyncStatus {
        match self.library_sync.get() {
            Some(sync) => sync.status(),
            None => FfiSyncStatus {
                running: false,
                device_id: String::new(),
                device_name: String::new(),
                devices: Vec::new(),
            },
        }
    }

    pub fn sync_set_listener(&self, listener: Box<dyn FfiSyncListener>) -> Result<(), CoreError> {
        let sync = self.running_sync()?;
        *sync.listener.lock().unwrap() = Some(Arc::from(listener));
        Ok(())
    }

    pub fn sync_rename_device(&self, name: String) -> Result<(), CoreError> {
        self.running_sync()?.rename(name);
        Ok(())
    }

    /// 生成一张「添加 Mac」的配对码。十分钟内有效,只能用一次。
    pub fn sync_create_device_invite(&self) -> Result<String, CoreError> {
        self.running_sync()?.create_device_invite()
    }

    /// 作废还没用掉的配对码。
    pub fn sync_cancel_invites(&self) -> Result<(), CoreError> {
        self.running_sync()?.cancel_invites();
        Ok(())
    }

    /// 看一眼配对码是干什么用的,不连接对方。
    pub fn sync_describe_code(&self, code: String) -> Result<FfiSyncInvitePurpose, CoreError> {
        let ticket: PairingTicket = code.parse().map_err(|_| sync_error("not_a_code"))?;
        Ok(ticket.purpose.into())
    }

    /// 用另一台 Mac 给的配对码加入它的设备组。
    pub fn sync_join(&self, code: String) -> Result<FfiSyncJoinResult, CoreError> {
        self.running_sync()?.join(&code)
    }

    /// 从设备组里移除一台 Mac。它自己留着已经同步到的资料,但再也连不进来。
    pub fn sync_remove_device(&self, device_id: String) -> Result<(), CoreError> {
        self.running_sync()?.remove_device(&device_id)
    }

    /// 这场录音是在哪台 Mac 上录的;本机录的为空。
    pub fn session_recorded_on(&self, session_id: String) -> Option<String> {
        self.recorded_elsewhere(&session_id)
    }
}

impl std::fmt::Debug for LibrarySync {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("LibrarySync")
            .field("device", &self.device_hex)
            .finish_non_exhaustive()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Instant;
    use vt_store::notebook_capture_store::{
        CaptureMode, CaptureState, NewNotebookCaptureRun, NewRealtimeUtterance,
        NotebookCaptureProfileUpdate, RemoteHealth, UtteranceAlignment, UtteranceCompletion,
    };

    fn core() -> (tempfile::TempDir, Arc<ZuTalkCore>) {
        let dir = tempfile::tempdir().unwrap();
        let core = Arc::new(ZuTalkCore::new(dir.path().to_string_lossy().into_owned()).unwrap());
        (dir, core)
    }

    /// 进程内:不走中继、不开 mDNS,只绑回环。
    fn start(core: &Arc<ZuTalkCore>, name: &str) {
        core.start_library_sync(
            name.into(),
            SyncOptions {
                relay_urls: Some(Vec::new()),
                local_discovery: Some(false),
                loopback_only: true,
            },
        )
        .unwrap();
    }

    fn eventually(what: &str, mut check: impl FnMut() -> bool) {
        let deadline = Instant::now() + Duration::from_secs(20);
        while Instant::now() < deadline {
            if check() {
                return;
            }
            std::thread::sleep(Duration::from_millis(100));
        }
        panic!("等了 20 秒还没有:{what}");
    }

    /// 在一台 Mac 上录完一场:一个主题、一场录完的录音、两句话。
    fn record(core: &ZuTalkCore, sid: &str) -> String {
        let notebook = core.create_notebook(Some("周会".into())).unwrap();
        let initial = core
            .notebook_capture_store
            .get_or_create_profile(&notebook.id)
            .unwrap();
        let profile = core
            .notebook_capture_store
            .update_profile(
                &notebook.id,
                initial.revision,
                &NotebookCaptureProfileUpdate {
                    remote_realtime_enabled: true,
                    capture_mode: CaptureMode::TranscriptionOnly,
                    language_a: "zh".into(),
                    language_b: "en".into(),
                    left_language: "zh".into(),
                    right_language: "en".into(),
                    selected_languages: vec!["zh".into()],
                    common_caption_language: None,
                    subtitle_only_languages: Vec::new(),
                    privacy_level: "standard".into(),
                    send_context_to_soniox: false,
                },
            )
            .unwrap();
        core.session_store
            .insert_session(&vt_store::SessionRecord {
                id: sid.into(),
                title: "周一例会".into(),
                session_type: "recording".into(),
                status: "recording".into(),
                duration_ms: 0,
                created_at: chrono::Utc::now().format("%Y-%m-%d %H:%M:%S").to_string(),
                deleted_at: None,
            })
            .unwrap();
        let run = core
            .notebook_capture_store
            .create_run(
                &NewNotebookCaptureRun {
                    id: format!("run-{sid}"),
                    notebook_id: notebook.id.clone(),
                    session_id: sid.into(),
                    remote_health: RemoteHealth::Connecting,
                    audio_journal_path: core
                        .data_dir
                        .join("audio")
                        .join(sid)
                        .join("capture.journal")
                        .to_string_lossy()
                        .into_owned(),
                    audio_key_ref: format!("key-{sid}"),
                    sample_rate: 16_000,
                    sample_format: "s16".to_string(),
                    channels: 1,
                },
                &profile,
            )
            .unwrap();
        // 真正录音时开录的事务里就挂进了主题;这里补上这一步。
        core.notebook_store
            .attach_session_with_builtin_projections(&notebook.id, sid)
            .unwrap();
        core.notebook_capture_store
            .claim_provider_provenance(
                sid,
                vt_store::notebook_capture_store::CaptureProviderRole::Realtime,
                vt_stt::CURRENT_NOTEBOOK_CAPTURE_ENGINE.provider_id,
                vt_stt::CURRENT_NOTEBOOK_CAPTURE_ENGINE.realtime_model_id,
            )
            .unwrap();
        for (sequence, text) in [(0u64, "大家早上好"), (1, "今天先过一下进度")] {
            core.notebook_capture_store
                .upsert_utterance(
                    &NewRealtimeUtterance {
                        id: format!("utterance-{sid}-{sequence}"),
                        session_id: sid.into(),
                        sequence,
                        session_speaker_id: None,
                        source_language: "zh".into(),
                        source_text: text.into(),
                        source_start_ms: Some(sequence * 2_000),
                        source_end_ms: Some(sequence * 2_000 + 1_500),
                        translated_language: None,
                        translated_text: None,
                        completion: UtteranceCompletion::Complete,
                        alignment: UtteranceAlignment::SourceOnly,
                    },
                    None,
                )
                .unwrap();
        }
        core.notebook_capture_store
            .transition_capture(&run.id, CaptureState::Recording, CaptureState::Draining)
            .unwrap();
        core.notebook_capture_store
            .transition_capture(&run.id, CaptureState::Draining, CaptureState::Completed)
            .unwrap();
        core.session_store
            .insert_session(&vt_store::SessionRecord {
                id: sid.into(),
                title: "周一例会".into(),
                session_type: "recording".into(),
                status: "completed".into(),
                duration_ms: 4_000,
                created_at: chrono::Utc::now().format("%Y-%m-%d %H:%M:%S").to_string(),
                deleted_at: None,
            })
            .unwrap();
        notebook.id
    }

    fn pair(inviter: &Arc<ZuTalkCore>, joiner: &Arc<ZuTalkCore>) {
        let code = inviter.sync_create_device_invite().unwrap();
        assert_eq!(
            joiner.sync_describe_code(code.clone()).unwrap(),
            FfiSyncInvitePurpose::Device
        );
        let joined = joiner.sync_join(code).unwrap();
        assert_eq!(joined.purpose, FfiSyncInvitePurpose::Device);
    }

    fn title_of(core: &ZuTalkCore, sid: &str) -> Option<String> {
        core.get_session(sid.into())
            .ok()
            .map(|session| session.title)
    }

    fn texts(core: &ZuTalkCore, notebook: &str, sid: &str) -> Vec<String> {
        core.list_notebook_capture_history_utterances(notebook.into(), sid.into())
            .map(|rows| rows.into_iter().map(|row| row.source_text).collect())
            .unwrap_or_default()
    }

    #[test]
    fn a_recording_made_on_one_mac_appears_on_the_other_and_edits_flow_both_ways() {
        let (_a_dir, studio) = core();
        let (_b_dir, laptop) = core();
        let sid = "sync-session-1";
        let notebook = record(&studio, sid);
        studio
            .session_mark_create(sid.into(), Some(1_000))
            .expect("录完的录音可以加标记");

        start(&studio, "工作室");
        start(&laptop, "笔记本");
        pair(&studio, &laptop);

        eventually("笔记本上出现这场录音的句子", || {
            texts(&laptop, &notebook, sid) == ["大家早上好", "今天先过一下进度"]
        });
        assert_eq!(title_of(&laptop, sid).as_deref(), Some("周一例会"));
        assert_eq!(laptop.session_mark_list(sid.into()).unwrap().len(), 1);
        // 音频在工作室那台上。
        assert_eq!(
            laptop.session_recorded_on(sid.into()).as_deref(),
            Some("工作室")
        );
        assert_eq!(studio.session_recorded_on(sid.into()), None);
        let refine = laptop.request_notebook_async_transcription(sid.into());
        assert!(
            matches!(refine, Err(CoreError::ValidationFailed { ref message }) if message == "sync.error.audio_elsewhere"),
            "{refine:?}"
        );
        // 名单两边都是两台。
        eventually("两边都看到两台设备", || {
            [&studio, &laptop]
                .iter()
                .all(|core| core.sync_status().devices.len() == 2)
        });

        // 笔记本上改标题,工作室上收到。
        laptop
            .rename_session(sid.into(), "周一例会(改)".into())
            .unwrap();
        eventually("工作室收到新标题", || {
            title_of(&studio, sid).as_deref() == Some("周一例会(改)")
        });

        // 工作室放进回收站,笔记本上也进了回收站。
        studio.soft_delete_session(sid.into()).unwrap();
        eventually("笔记本上也进了回收站", || {
            laptop
                .get_session(sid.into())
                .is_ok_and(|session| session.is_trashed)
        });

        // 笔记本上永久删除,工作室跟着删。
        laptop.purge_session(sid.into()).unwrap();
        eventually("工作室上也删掉了", || {
            studio.get_session(sid.into()).is_err()
        });

        studio.sync_stop();
        laptop.sync_stop();
    }

    #[test]
    fn a_session_note_written_on_one_mac_arrives_on_the_other() {
        let (_a_dir, studio) = core();
        let (_b_dir, laptop) = core();
        let sid = "sync-session-note";
        record(&studio, sid);
        start(&studio, "工作室");
        start(&laptop, "笔记本");
        pair(&studio, &laptop);
        eventually("笔记本上有这场录音", || {
            title_of(&laptop, sid).is_some()
        });

        let doc = studio.session_note_block_document_open(sid.into()).unwrap();
        studio
            .note_apply_outline(
                doc.clone(),
                vec![crate::block_document_api::FfiOutlineRow {
                    id: "row-1".into(),
                    depth: 0,
                    text: "会后把进度表发给大家".into(),
                    kind: crate::block_document_api::FfiOutlineKind::Paragraph,
                    checked: false,
                }],
            )
            .unwrap();

        eventually("笔记本上的录音笔记有了这一行", || {
            laptop
                .session_note_block_document_open(sid.into())
                .and_then(|doc| laptop.note_outline_rows(doc))
                .is_ok_and(|rows| rows.iter().any(|row| row.text == "会后把进度表发给大家"))
        });

        studio.sync_stop();
        laptop.sync_stop();
    }
}
