//! 共享 session 文档:分享 #9 的收端落库与协同编辑。
//!
//! 设计定案见 docs/architecture/share-p2p.md 第 11 节。要点:
//!
//! - 同步单元是**按 session 一份的 T2 块文档**,doc id = session_id。
//!   它不是转录稿 tab 文档的 fork,而是从 SQLite 可见事实独立投影出的
//!   第二份文档——tab 文档按 Notebook 一份、含全部 session,按单次录音
//!   共享时同步它会把别的录音也发出去。
//! - 文档在本模块自己的注册表与 EditorBridge **双挂载**(同一 LoroDoc,
//!   克隆共享状态):bridge 应答同步家族(version / updates_since /
//!   import)与纪元准入,注册表供动词与读取。不进块文档注册表,不与
//!   笔记/tab 的生命周期纠缠。
//! - 落盘 `block-documents/shared/<session_id>.loro`。**台账即目录**:
//!   收到过什么 = shared/ 下有什么文件,不设 SQLite 台账。
//! - 跨端的「机器让人」:宿主为每条车道记一份**机器影子**(机器最后
//!   写入的文本)。刷新时文档现文本 ≠ 影子 → 车道被人接管,机器让行。
//!   影子进程内存活;宿主重启后以文档现状重建——重启前观看端未同步的
//!   编辑可能被其后的机器修订覆盖,v1 声明接受。

use std::collections::{BTreeSet, HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use loro::LoroDoc;
use vt_share::ScopeId;
use vt_store::document_schema::{document_kind, new_block_document, DocumentKind};
use vt_store::transcript_projection::TranscriptProjection;

use crate::notebook_capture_api::{store_error, t2_insert_anchor, t2_machine_block_write};
use crate::{CoreError, ZulangueCore};

fn internal(message: impl std::fmt::Display) -> CoreError {
    CoreError::InternalError {
        message: message.to_string(),
    }
}

/// 一条车道在影子表里的键。源车道用固定哨兵,与八语车道键不冲突
/// (车道键都是小写语言码)。
const SOURCE_LANE_KEY: &str = "»text«";

type LaneShadow = HashMap<(String, String), String>;

/// 共享 session 文档的进程内状态。
#[derive(Default)]
pub(crate) struct SharedSessionState {
    /// session_id → 打开中的投影门面(与 bridge 共享同一底层文档)。
    open: Mutex<HashMap<String, TranscriptProjection>>,
    /// session_id → 车道机器影子。只有宿主刷新会写它。
    shadows: Mutex<HashMap<String, LaneShadow>>,
    /// session_id → 上次发布时的版本向量。发布导出以它为起点。
    published: Mutex<HashMap<String, loro::VersionVector>>,
    /// 观看端:本房间已入册的文档 id。Session 范围在加入时预置那一个。
    known: Mutex<HashSet<String>>,
}

impl SharedSessionState {
    pub(crate) fn register_known(&self, session_id: &str) {
        self.known.lock().unwrap().insert(session_id.to_string());
    }

    pub(crate) fn clear_room_state(&self) {
        self.known.lock().unwrap().clear();
    }
}

pub(crate) fn shared_documents_dir(data_dir: &Path) -> PathBuf {
    data_dir.join("block-documents").join("shared")
}

fn shared_document_path(data_dir: &Path, session_id: &str) -> Result<PathBuf, CoreError> {
    if session_id.is_empty() || session_id.contains(['/', '\\', '.']) {
        return Err(internal(format!("非法共享文档 id: {session_id:?}")));
    }
    Ok(shared_documents_dir(data_dir).join(format!("{session_id}.loro")))
}

/// 打开(或从盘装载,或按黄金起点新建)一份共享 session 文档,双挂载。
/// 幂等。返回投影门面。
pub(crate) fn ensure_shared_session_doc(
    state: &SharedSessionState,
    bridge: &vt_store::EditorBridge,
    data_dir: &Path,
    session_id: &str,
) -> Result<TranscriptProjection, CoreError> {
    {
        let open = state.open.lock().unwrap();
        if let Some(projection) = open.get(session_id) {
            return Ok(projection.clone());
        }
    }
    let path = shared_document_path(data_dir, session_id)?;
    let doc = if path.exists() {
        let bytes = fs::read(&path).map_err(|e| internal(format!("读共享文档: {e}")))?;
        let doc = LoroDoc::new();
        doc.set_record_timestamp(true);
        doc.import(&bytes)
            .map_err(|e| internal(format!("导入共享文档快照: {e}")))?;
        if document_kind(&doc) != Some(DocumentKind::Transcript) {
            return Err(internal(format!("共享文档 {session_id} 不是转录稿")));
        }
        doc
    } else {
        new_block_document(DocumentKind::Transcript)
    };

    let projection = TranscriptProjection::open(doc).map_err(internal)?;
    // bridge 键位占用防御:这个 id 已被本机**别的**文档占着(不是我们
    // 自己上次挂的)就拒绝——顶掉别人的句柄等于让远端内容冒名顶替本机
    // 文档。我们自己的旧句柄(注册表已失去引用)照常替换。
    if bridge.is_session_open(session_id) {
        return Err(internal(format!(
            "id {session_id} 已被本机其它文档占用,拒绝挂载共享文档"
        )));
    }
    bridge
        .open(session_id, projection.doc().clone())
        .map_err(|e| internal(format!("共享文档挂载 bridge: {e}")))?;
    state
        .open
        .lock()
        .unwrap()
        .insert(session_id.to_string(), projection.clone());
    Ok(projection)
}

/// 落盘。收端在成功合入后调用,宿主在刷新/编辑后调用。
pub(crate) fn persist_shared_session_doc(
    state: &SharedSessionState,
    data_dir: &Path,
    session_id: &str,
) -> Result<(), CoreError> {
    let projection = {
        let open = state.open.lock().unwrap();
        open.get(session_id)
            .cloned()
            .ok_or_else(|| internal(format!("共享文档 {session_id} 未打开")))?
    };
    fs::create_dir_all(shared_documents_dir(data_dir))
        .map_err(|e| internal(format!("建共享文档目录: {e}")))?;
    let bytes = projection
        .doc()
        .export(loro::ExportMode::Snapshot)
        .map_err(|e| internal(format!("导出共享文档快照: {e}")))?;
    fs::write(shared_document_path(data_dir, session_id)?, bytes)
        .map_err(|e| internal(format!("写共享文档快照: {e}")))
}

/// 宿主刷新:把 session 的可见事实差量投影进共享文档。
///
/// 「机器让人」按影子判定:文档现文本 ≠ 影子 → 车道被人(宿主或观看端)
/// 接管,机器不写;源车道无法按车道跳过(upsert 恒写 text),改写为
/// 「写回现值」——对状态 diff 是无操作。返回是否发生了实际写入。
pub(crate) fn refresh_shared_session_from_facts(
    state: &SharedSessionState,
    projection: &TranscriptProjection,
    session_id: &str,
    utterances: &[vt_store::notebook_capture_store::RealtimeUtterance],
) -> Result<bool, CoreError> {
    let mut shadows = state.shadows.lock().unwrap();
    let shadow = shadows.entry(session_id.to_string()).or_default();

    let sequence_by_id: HashMap<&str, u64> = utterances
        .iter()
        .map(|utterance| (utterance.id.as_str(), utterance.sequence))
        .collect();
    let before = projection.refresh();
    let mut changed = false;

    for utterance in utterances {
        let Some(mut write) = t2_machine_block_write(utterance) else {
            continue;
        };
        let blocks = projection.blocks();
        let current = blocks.iter().find(|block| block.id == write.id);

        let mut frozen = BTreeSet::new();
        if let Some(current) = current {
            // 影子首见(宿主重启后)以现状初始化:现状即视为机器所写。
            for (lane, incoming) in &write.lanes {
                let key = (write.id.clone(), lane.clone());
                let doc_text = current.lanes.get(lane);
                match (doc_text, shadow.get(&key)) {
                    (Some(doc_text), Some(shadowed)) if doc_text != shadowed => {
                        frozen.insert(lane.clone());
                    }
                    (Some(doc_text), None) if doc_text != incoming => {
                        shadow.insert(key, doc_text.clone());
                        frozen.insert(lane.clone());
                    }
                    _ => {}
                }
            }
            let text_key = (write.id.clone(), SOURCE_LANE_KEY.to_string());
            let text_taken = match shadow.get(&text_key) {
                Some(shadowed) => current.text != *shadowed,
                None => current.text != write.text,
            };
            if text_taken {
                // 源车道被人接管:写回现值,对 diff 是无操作。
                write.text = current.text.clone();
            }
        }

        let creates = current.is_none();
        let differs = match current {
            None => true,
            Some(current) => {
                current.text != write.text
                    || write.lanes.iter().any(|(lane, text)| {
                        !frozen.contains(lane) && current.lanes.get(lane) != Some(text)
                    })
            }
        };
        if !differs {
            continue;
        }
        let anchor = if creates {
            t2_insert_anchor(&before, session_id, &sequence_by_id, utterance.sequence)
        } else {
            None
        };
        // 记影子在写之前:写入值就是机器的最新笔迹。
        shadow.insert(
            (write.id.clone(), SOURCE_LANE_KEY.to_string()),
            write.text.clone(),
        );
        for (lane, text) in &write.lanes {
            if !frozen.contains(lane) {
                shadow.insert((write.id.clone(), lane.clone()), text.clone());
            }
        }
        projection
            .machine_upsert_block(write, &frozen, anchor.as_deref())
            .map_err(store_error)?;
        changed = true;
    }
    Ok(changed)
}

impl ZulangueCore {
    /// 宿主:物化共享范围内全部 session 的共享文档。`enable_document_sync`
    /// 时调用一次;之后活跃采集经 [`Self::refresh_shared_session_document`]
    /// 增量刷新。
    pub(crate) fn materialize_shared_sessions(&self, scope: &ScopeId) -> Result<(), CoreError> {
        let session_ids: Vec<String> = match scope {
            ScopeId::Session { session_id } => vec![session_id.clone()],
            ScopeId::Notebook { notebook_id } => self
                .notebook_capture_store
                .list_notebook_capture_history_summaries(notebook_id)
                .map_err(store_error)?
                .into_iter()
                .map(|run| run.session_id)
                .collect(),
        };
        for session_id in session_ids {
            let projection = ensure_shared_session_doc(
                &self.shared_sessions,
                &self.editor_bridge,
                &self.data_dir,
                &session_id,
            )?;
            let utterances = self
                .notebook_capture_store
                .list_utterances(&session_id)
                .map_err(store_error)?;
            let changed = refresh_shared_session_from_facts(
                &self.shared_sessions,
                &projection,
                &session_id,
                &utterances,
            )?;
            if changed {
                persist_shared_session_doc(&self.shared_sessions, &self.data_dir, &session_id)?;
            }
            self.publish_shared_session(&session_id);
        }
        Ok(())
    }

    /// 宿主:活跃采集的投影 ack 之后刷新共享文档并推送。未在共享、或
    /// session 不在共享范围内时是 no-op。绝不让共享侧的失败影响采集产线
    /// ——错误只记日志。
    pub(crate) fn refresh_shared_session_document(&self, session_id: &str) {
        if !self.session_in_hosted_share_scope(session_id) {
            return;
        }
        let result = (|| -> Result<(), CoreError> {
            let projection = ensure_shared_session_doc(
                &self.shared_sessions,
                &self.editor_bridge,
                &self.data_dir,
                session_id,
            )?;
            let utterances = self
                .notebook_capture_store
                .list_utterances(session_id)
                .map_err(store_error)?;
            let changed = refresh_shared_session_from_facts(
                &self.shared_sessions,
                &projection,
                session_id,
                &utterances,
            )?;
            if changed {
                persist_shared_session_doc(&self.shared_sessions, &self.data_dir, session_id)?;
                self.publish_shared_session(session_id);
            }
            Ok(())
        })();
        if let Err(error) = result {
            tracing::warn!(session_id, %error, "共享文档刷新失败;下一次投影 ack 会重试");
        }
    }

    /// 宿主:本机车道订正显式施加到共享文档(机器刷新按影子让行,不会
    /// 替宿主搬运订正)。best-effort,失败只记日志。
    pub(crate) fn propagate_lane_edit_to_shared_session(
        &self,
        session_id: &str,
        utterance_id: &str,
        lane_key: Option<&str>,
        text: &str,
    ) {
        if !self.session_in_hosted_share_scope(session_id) {
            return;
        }
        let result = (|| -> Result<(), CoreError> {
            let projection = ensure_shared_session_doc(
                &self.shared_sessions,
                &self.editor_bridge,
                &self.data_dir,
                session_id,
            )?;
            match lane_key {
                Some(lane) => projection
                    .user_replace_lane(utterance_id, lane, text)
                    .map_err(store_error)?,
                None => projection
                    .user_replace_text(utterance_id, text)
                    .map_err(store_error)?,
            }
            persist_shared_session_doc(&self.shared_sessions, &self.data_dir, session_id)?;
            self.publish_shared_session(session_id);
            Ok(())
        })();
        if let Err(error) = result {
            tracing::warn!(session_id, utterance_id, %error, "车道订正未能同步到共享文档");
        }
    }

    /// 把 session 自上次发布以来的增量推给房间。没连房间时是 no-op。
    pub(crate) fn publish_shared_session(&self, session_id: &str) {
        let projection = {
            let open = self.shared_sessions.open.lock().unwrap();
            match open.get(session_id) {
                Some(projection) => projection.clone(),
                None => return,
            }
        };
        let mut published = self.shared_sessions.published.lock().unwrap();
        let since = published.entry(session_id.to_string()).or_default();
        let now = projection.doc().oplog_vv();
        if *since == now {
            return;
        }
        let Ok(update) = projection.doc().export(loro::ExportMode::updates(since)) else {
            return;
        };
        *since = now;
        drop(published);

        let guard = self.share_runtime.lock().unwrap();
        if let Some(runtime) = guard.as_ref() {
            runtime
                .endpoint_handle()
                .publish_document_update(session_id.to_string(), update);
        }
    }

    /// 这个 session 是否落在当前主持的共享范围内(且文档同步已武装)。
    fn session_in_hosted_share_scope(&self, session_id: &str) -> bool {
        let guard = self.share_runtime.lock().unwrap();
        let Some(runtime) = guard.as_ref() else {
            return false;
        };
        if !runtime.is_hosting() {
            return false;
        }
        match runtime.roster_scope() {
            Some(ScopeId::Session { session_id: scoped }) => scoped == session_id,
            Some(ScopeId::Notebook { notebook_id }) => self
                .notebook_capture_store
                .get_run_for_session(session_id)
                .ok()
                .flatten()
                .is_some_and(|run| run.notebook_id == notebook_id),
            None => false,
        }
    }
}

// =========================================================================
// 文档同步 sink:宿主与观看端两种角色,一套准入
// =========================================================================

/// [`vt_share::DocumentSync`] 的实现。宿主按采集史回答「范围里有哪些
/// 文档」,观看端按已入册清单;其余问题都由 bridge 应答——共享文档在
/// 打开时已双挂载。
pub(crate) struct SharedDocSync {
    state: std::sync::Arc<SharedSessionState>,
    editor: vt_store::EditorBridge,
    capture_store: std::sync::Arc<vt_store::NotebookCaptureStore>,
    data_dir: PathBuf,
    /// 主持人角色。观看端的范围判定与开文档策略都不同。
    hosting: bool,
}

impl SharedDocSync {
    pub(crate) fn new(
        state: std::sync::Arc<SharedSessionState>,
        editor: vt_store::EditorBridge,
        capture_store: std::sync::Arc<vt_store::NotebookCaptureStore>,
        data_dir: PathBuf,
        hosting: bool,
    ) -> Self {
        Self {
            state,
            editor,
            capture_store,
            data_dir,
            hosting,
        }
    }
}

impl vt_share::DocumentSync for SharedDocSync {
    fn documents(&self, scope: &ScopeId) -> Vec<String> {
        if self.hosting {
            match scope {
                ScopeId::Session { session_id } => vec![session_id.clone()],
                ScopeId::Notebook { notebook_id } => self
                    .capture_store
                    .list_notebook_capture_history_summaries(notebook_id)
                    .map(|runs| runs.into_iter().map(|run| run.session_id).collect())
                    .unwrap_or_default(),
            }
        } else {
            let mut known: Vec<String> = self.state.known.lock().unwrap().iter().cloned().collect();
            known.sort();
            known
        }
    }

    fn document_in_scope(&self, scope: &ScopeId, document_id: &str) -> bool {
        if self.hosting {
            return match scope {
                ScopeId::Session { session_id } => session_id == document_id,
                ScopeId::Notebook { .. } => {
                    self.documents(scope).iter().any(|id| id == document_id)
                }
            };
        }
        // 观看端只认已入册的 id。Session 范围在加入时由分享码钉死那一个;
        // Notebook 范围 v1 不落库(named-set 为空 → 一切拒收,字幕照旧)
        // ——接受成员自报的 id 会打开 bridge 键位抢占面(顶掉本机同名
        // 文档),宿主签名的文档清单成形之前不冒这个险(设计文档 §11)。
        let _ = scope;
        self.state.known.lock().unwrap().contains(document_id)
    }

    fn version(&self, _scope: &ScopeId, document_id: &str) -> Vec<u8> {
        self.editor
            .document_version(document_id)
            .unwrap_or_default()
    }

    fn schema_epoch(&self, scope: &ScopeId, document_id: &str) -> Option<u64> {
        // 观看端:范围内但尚未打开的文档,先按黄金起点开进内存——否则
        // 第一笔更新会因 SchemaEpochUnknown 被拒之门外。只开内存不落盘;
        // 盘上只留成功合入过内容的文档。
        if !self.hosting
            && self.editor.schema_epoch(document_id).is_none()
            && self.document_in_scope(scope, document_id)
        {
            match ensure_shared_session_doc(&self.state, &self.editor, &self.data_dir, document_id)
            {
                Ok(_) => self.state.register_known(document_id),
                Err(error) => {
                    tracing::warn!(document_id, %error, "共享文档按需打开失败");
                }
            }
        }
        self.editor.schema_epoch(document_id)
    }

    fn updates_since(
        &self,
        _scope: &ScopeId,
        document_id: &str,
        version: &[u8],
    ) -> Option<Vec<u8>> {
        self.editor.updates_since(document_id, version)
    }

    fn apply(&self, _scope: &ScopeId, document_id: &str, update: &[u8]) -> bool {
        let applied = self.editor.import_remote_update(document_id, update);
        if applied {
            if let Err(error) = persist_shared_session_doc(&self.state, &self.data_dir, document_id)
            {
                tracing::warn!(document_id, %error, "共享文档落盘失败;内容仍在内存,下一笔合入重试");
            }
        }
        applied
    }
}

// =========================================================================
// FFI:观看端与宿主共用的共享 session 读写面
// =========================================================================

/// 一条收到(或正在共享)的 session 摘要。
#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiSharedSessionInfo {
    pub session_id: String,
    /// 首个句块的正文,给列表当标题;空文档为空串。
    pub preview: String,
    pub block_count: u32,
}

#[uniffi::export]
impl ZulangueCore {
    /// shared/ 目录台账:收到过与共享过的全部 session 文档。
    pub fn list_shared_sessions(&self) -> Vec<FfiSharedSessionInfo> {
        let dir = shared_documents_dir(&self.data_dir);
        let Ok(entries) = fs::read_dir(&dir) else {
            return Vec::new();
        };
        let mut sessions = Vec::new();
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            let Some(session_id) = name.strip_suffix(".loro") else {
                continue;
            };
            let Ok(projection) = ensure_shared_session_doc(
                &self.shared_sessions,
                &self.editor_bridge,
                &self.data_dir,
                session_id,
            ) else {
                continue;
            };
            let blocks = projection.refresh();
            sessions.push(FfiSharedSessionInfo {
                session_id: session_id.to_string(),
                preview: blocks
                    .iter()
                    .find(|block| !block.text.is_empty())
                    .map(|block| block.text.chars().take(80).collect())
                    .unwrap_or_default(),
                block_count: blocks.len() as u32,
            });
        }
        sessions.sort_by(|a, b| a.session_id.cmp(&b.session_id));
        sessions
    }

    /// 一份共享 session 的句块(文档序)。
    pub fn shared_session_blocks(
        &self,
        session_id: String,
    ) -> Result<Vec<crate::block_document_api::FfiUtteranceBlock>, CoreError> {
        let projection = ensure_shared_session_doc(
            &self.shared_sessions,
            &self.editor_bridge,
            &self.data_dir,
            &session_id,
        )?;
        Ok(projection.refresh().into_iter().map(Into::into).collect())
    }

    /// 订正共享 session 的一条译文车道,并把增量推给房间。
    pub fn shared_session_replace_lane(
        &self,
        session_id: String,
        block_id: String,
        lane: String,
        text: String,
    ) -> Result<(), CoreError> {
        self.shared_session_edit(&session_id, |projection| {
            projection
                .user_replace_lane(&block_id, &lane, &text)
                .map_err(store_error)
        })
    }

    /// 订正共享 session 的原文车道。
    pub fn shared_session_replace_text(
        &self,
        session_id: String,
        block_id: String,
        text: String,
    ) -> Result<(), CoreError> {
        self.shared_session_edit(&session_id, |projection| {
            projection
                .user_replace_text(&block_id, &text)
                .map_err(store_error)
        })
    }

    /// 在共享 session 的句块之间插批注。
    pub fn shared_session_insert_annotation(
        &self,
        session_id: String,
        index: u32,
        annotation_id: String,
        text: String,
    ) -> Result<(), CoreError> {
        self.shared_session_edit(&session_id, |projection| {
            projection
                .insert_annotation(index as usize, &annotation_id, &text)
                .map_err(store_error)
        })
    }
}

impl ZulangueCore {
    /// 编辑流水线:动词 → 落盘 → 推送。写入策略的裁决在接收端(HostOnly
    /// 房间宿主会拒收观看端的推送);本地文档先行是乐观编辑,与房间收敛
    /// 由 CRDT 保证——被拒的编辑不会回流,只存在于本机副本里,UI 按
    /// host_only 禁入口避免造出这种孤儿编辑。
    fn shared_session_edit(
        &self,
        session_id: &str,
        verb: impl FnOnce(&TranscriptProjection) -> Result<(), CoreError>,
    ) -> Result<(), CoreError> {
        let projection = ensure_shared_session_doc(
            &self.shared_sessions,
            &self.editor_bridge,
            &self.data_dir,
            session_id,
        )?;
        verb(&projection)?;
        persist_shared_session_doc(&self.shared_sessions, &self.data_dir, session_id)?;
        self.publish_shared_session(session_id);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use vt_store::EditorBridge;

    fn utterance(
        id: &str,
        sequence: u64,
        text: &str,
        zh: &str,
    ) -> vt_store::notebook_capture_store::RealtimeUtterance {
        use vt_store::notebook_capture_store::*;
        RealtimeUtterance {
            id: id.into(),
            session_id: "session-s".into(),
            sequence,
            session_speaker_id: None,
            source_language: "en".into(),
            source_text: text.into(),
            source_start_ms: None,
            source_end_ms: None,
            translated_language: Some("zh".into()),
            translated_text: Some(zh.into()),
            revision: 0,
            completion: UtteranceCompletion::Complete,
            alignment: UtteranceAlignment::Paired,
            created_at: String::new(),
            updated_at: String::new(),
            source_projection_revision: 1,
            source_edit_revision: 0,
            variants: vec![
                RealtimeUtteranceVariant {
                    language: "zh".into(),
                    role: UtteranceVariantRole::Translation,
                    text: Some(zh.into()),
                    state: UtteranceVariantState::Ready,
                    completion: Some(UtteranceCompletion::Complete),
                    revision: 0,
                    created_at: String::new(),
                    updated_at: String::new(),
                    projection_revision: 1,
                    edit_revision: 0,
                },
                RealtimeUtteranceVariant {
                    language: "en".into(),
                    role: UtteranceVariantRole::Source,
                    text: Some(text.into()),
                    state: UtteranceVariantState::Ready,
                    completion: Some(UtteranceCompletion::Complete),
                    revision: 0,
                    created_at: String::new(),
                    updated_at: String::new(),
                    projection_revision: 1,
                    edit_revision: 0,
                },
            ],
        }
    }

    fn refresh_with(
        state: &SharedSessionState,
        projection: &TranscriptProjection,
        utterances: &[vt_store::notebook_capture_store::RealtimeUtterance],
    ) -> bool {
        refresh_shared_session_from_facts(state, projection, "session-s", utterances).unwrap()
    }

    fn open_pair(dir: &Path) -> (SharedSessionState, EditorBridge, TranscriptProjection) {
        let state = SharedSessionState::default();
        let bridge = EditorBridge::new();
        let projection = ensure_shared_session_doc(&state, &bridge, dir, "session-s").unwrap();
        (state, bridge, projection)
    }

    #[test]
    fn machine_refresh_yields_to_a_viewer_edited_lane() {
        let dir = tempfile::tempdir().unwrap();
        let (state, _bridge, projection) = open_pair(dir.path());
        assert!(refresh_with(
            &state,
            &projection,
            &[utterance("u1", 0, "hello", "你好")]
        ));

        // 观看端订正 zh 车道(同一底层文档:动词直接施加)。
        projection
            .user_replace_lane("u1", "zh", "你好(人工)")
            .unwrap();

        // 机器带修订回来:zh 被接管,原文照常推进。
        assert!(refresh_with(
            &state,
            &projection,
            &[utterance("u1", 0, "hello again", "你好v2")]
        ));
        let blocks = projection.blocks();
        assert_eq!(blocks[0].text, "hello again");
        assert_eq!(blocks[0].lanes["zh"], "你好(人工)", "机器让人");
    }

    #[test]
    fn machine_refresh_yields_to_an_edited_source_text() {
        let dir = tempfile::tempdir().unwrap();
        let (state, _bridge, projection) = open_pair(dir.path());
        refresh_with(&state, &projection, &[utterance("u1", 0, "hello", "你好")]);
        projection.user_replace_text("u1", "hello(人工)").unwrap();

        refresh_with(
            &state,
            &projection,
            &[utterance("u1", 0, "hello v2", "你好v2")],
        );
        let blocks = projection.blocks();
        assert_eq!(blocks[0].text, "hello(人工)", "被接管的源车道机器不动");
        assert_eq!(blocks[0].lanes["zh"], "你好v2", "未接管的车道照常推进");
    }

    #[test]
    fn identical_refresh_is_a_no_op() {
        let dir = tempfile::tempdir().unwrap();
        let (state, _bridge, projection) = open_pair(dir.path());
        let facts = [utterance("u1", 0, "hello", "你好")];
        assert!(refresh_with(&state, &projection, &facts));
        assert!(
            !refresh_with(&state, &projection, &facts),
            "无变化不产生写入"
        );
    }

    /// 端到端同步链(不含传输,传输由 vt-share 自己的测试盖):宿主物化
    /// → 观看端按需开+落盘 → 观看端订正 → 宿主收敛且机器让行;
    /// HostOnly 房间观看端的推送被拒。
    #[test]
    fn sync_chain_persists_on_viewer_and_converges_edits_back_to_host() {
        use std::sync::Arc;
        use vt_share::{
            handle_incoming_update, seal_update, IncomingOutcome, RoomRoster, WritePolicy,
        };

        let host_key = iroh::SecretKey::generate();
        let viewer_key = iroh::SecretKey::generate();
        let scope = ScopeId::Session {
            session_id: "session-s".into(),
        };
        let store = Arc::new(
            vt_store::notebook_capture_store::NotebookCaptureStore::new(&std::path::PathBuf::from(
                ":memory:",
            ))
            .unwrap(),
        );

        // 宿主世界:物化 + 首个 Final。
        let host_dir = tempfile::tempdir().unwrap();
        let host_state = Arc::new(SharedSessionState::default());
        let host_bridge = vt_store::EditorBridge::new();
        let host_doc =
            ensure_shared_session_doc(&host_state, &host_bridge, host_dir.path(), "session-s")
                .unwrap();
        refresh_shared_session_from_facts(
            &host_state,
            &host_doc,
            "session-s",
            &[utterance("u1", 0, "hello", "你好")],
        )
        .unwrap();
        let host_sink = SharedDocSync::new(
            host_state.clone(),
            host_bridge.clone(),
            store.clone(),
            host_dir.path().to_path_buf(),
            true,
        );

        // 观看端世界:预先入册,一无所有。
        let viewer_dir = tempfile::tempdir().unwrap();
        let viewer_state = Arc::new(SharedSessionState::default());
        let viewer_bridge = vt_store::EditorBridge::new();
        viewer_state.register_known("session-s");
        let viewer_sink = SharedDocSync::new(
            viewer_state.clone(),
            viewer_bridge.clone(),
            store,
            viewer_dir.path().to_path_buf(),
            false,
        );

        // 宿主全量推给观看端(相当于催缺响应)。
        let mut roster = RoomRoster::new(scope.clone(), host_key.public(), WritePolicy::Everyone);
        roster.admit(viewer_key.public());
        let guard_host = crate::share_api::LoroCaptureBoundaryGuard::new(host_bridge.clone());
        let guard_viewer = crate::share_api::LoroCaptureBoundaryGuard::new(viewer_bridge.clone());
        let full = host_doc
            .doc()
            .export(loro::ExportMode::updates(&loro::VersionVector::default()))
            .unwrap();
        let envelope = seal_update(&scope, "session-s", 2, full, &host_key).unwrap();
        assert_eq!(
            handle_incoming_update(&envelope, &roster, &guard_viewer, &viewer_sink),
            IncomingOutcome::Applied,
            "观看端按需开黄金起点文档并合入"
        );
        // 台账即目录:落了盘。
        assert!(viewer_dir
            .path()
            .join("block-documents/shared/session-s.loro")
            .exists());
        let viewer_doc = ensure_shared_session_doc(
            &viewer_state,
            &viewer_bridge,
            viewer_dir.path(),
            "session-s",
        )
        .unwrap();
        assert_eq!(viewer_doc.refresh()[0].lanes["zh"], "你好");

        // 观看端订正 → 推回宿主 → 宿主收敛。
        let before = viewer_doc.doc().oplog_vv();
        viewer_doc
            .user_replace_lane("u1", "zh", "你好(观看端订正)")
            .unwrap();
        let edit = viewer_doc
            .doc()
            .export(loro::ExportMode::updates(&before))
            .unwrap();
        let envelope = seal_update(&scope, "session-s", 2, edit.clone(), &viewer_key).unwrap();
        assert_eq!(
            handle_incoming_update(&envelope, &roster, &guard_host, &host_sink),
            IncomingOutcome::Applied
        );
        assert_eq!(host_doc.refresh()[0].lanes["zh"], "你好(观看端订正)");

        // 机器带修订回来:被观看端接管的车道,宿主机器让行。
        refresh_shared_session_from_facts(
            &host_state,
            &host_doc,
            "session-s",
            &[utterance("u1", 0, "hello", "你好v2")],
        )
        .unwrap();
        assert_eq!(host_doc.refresh()[0].lanes["zh"], "你好(观看端订正)");

        // HostOnly 房间:同一笔观看端编辑被写入策略拒收。
        roster.set_policy(WritePolicy::HostOnly);
        let envelope = seal_update(&scope, "session-s", 2, edit, &viewer_key).unwrap();
        assert!(matches!(
            handle_incoming_update(&envelope, &roster, &guard_host, &host_sink),
            IncomingOutcome::Denied(_)
        ));
    }

    #[test]
    fn doc_survives_reopen_and_bridge_import_reaches_the_projection() {
        let dir = tempfile::tempdir().unwrap();
        let (state, bridge, projection) = open_pair(dir.path());
        refresh_with(&state, &projection, &[utterance("u1", 0, "hello", "你好")]);
        persist_shared_session_doc(&state, dir.path(), "session-s").unwrap();

        // 观看端:另一个状态世界从盘装载,经 bridge 合入远端更新。
        let (_state2, bridge2, projection2) = open_pair(dir.path());
        assert_eq!(projection2.refresh().len(), 1);

        // 远端(原世界)新增批注,增量经 bridge 导入。
        let before = projection2.doc().oplog_vv();
        projection.insert_annotation(1, "n1", "远端批注").unwrap();
        let update = projection
            .doc()
            .export(loro::ExportMode::updates(&before))
            .unwrap();
        assert!(bridge2.import_remote_update("session-s", &update));
        let blocks = projection2.refresh();
        assert_eq!(blocks.len(), 2);
        assert_eq!(blocks[1].id, "n1");
        drop((state, bridge));
    }
}
