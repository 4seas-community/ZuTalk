//! 第 2 纪元块文档的 FFI 面:T2 转录稿与 B 笔记的句柄与动词。
//!
//! 阶段 3 的接线层,纯增量:现有产线(第 1 纪元平文本编辑器、采集投影)
//! 一概不动,Swift 侧从这里开始能打开块文档做实验性表面。动词集合与
//! vt-store 两个门面一一对应——转录稿只有机器 upsert/用户订正/插批注,
//! 笔记只有「整份大纲行重放」;这层不新增任何能力,只做类型搬运与持久化。
//!
//! 持久化:`<data_dir>/block-documents/<doc_id>.loro`,每个动词成功后
//! 同步写盘。块文档以句块/大纲行为提交粒度(不是击键粒度),同步写的
//! 成本可接受;将来接进击键路径时再并入 500ms 合并写盘的 flusher。
//!
//! 笔记的「整份重放」有一条保真规则:重放只携带 (id, depth, text),
//! 既有节点 `$` 里 id 之外的元数据(将来的创建时间、样式等)按 id 原样
//! 保留——否则每次大纲编辑都会把元数据冲掉。

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use loro::{LoroDoc, UndoManager};
use serde_json::json;
use vt_mirror::mirror::{Mirror, MirrorOptions, SetStateOptions};
use vt_mirror::value::Value;
use vt_store::document_schema::{
    document_kind, new_block_document, note_schema, DocumentKind, NOTE_ROOT,
};
use vt_store::note_outline::{flatten_note, rebuild_note, OutlineRow};
use vt_store::transcript_projection::{MachineBlockWrite, TranscriptProjection, UtteranceBlock};

use crate::{CoreError, ZulangueCore};

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FfiDocumentKind {
    Transcript,
    Note,
}

impl From<FfiDocumentKind> for DocumentKind {
    fn from(value: FfiDocumentKind) -> Self {
        match value {
            FfiDocumentKind::Transcript => Self::Transcript,
            FfiDocumentKind::Note => Self::Note,
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiUtteranceBlock {
    pub id: String,
    pub owner: String,
    pub text: String,
    /// 车道语言 → 文本,只含实际存在的车道。
    pub lanes: HashMap<String, String>,
}

impl From<UtteranceBlock> for FfiUtteranceBlock {
    fn from(block: UtteranceBlock) -> Self {
        Self {
            id: block.id,
            owner: block.owner,
            text: block.text,
            lanes: block.lanes.into_iter().collect(),
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiMachineBlockWrite {
    pub id: String,
    pub owner: String,
    pub text: String,
    pub lanes: HashMap<String, String>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiOutlineRow {
    pub id: String,
    pub depth: u32,
    pub text: String,
}

/// 一次撤销/重做动词的结果快照。
#[derive(Debug, Clone, Copy, uniffi::Record)]
pub struct FfiNoteUndoState {
    /// 这次调用真的回退/重做了一步(false = 栈空,no-op)。
    pub performed: bool,
    pub can_undo: bool,
    pub can_redo: bool,
}

/// 打开中的块文档。
pub(crate) enum BlockDocumentHandle {
    Transcript(TranscriptProjection),
    Note {
        mirror: Mirror,
        /// 本机会话内的撤销栈。Loro 的 UndoManager 只回退本 peer 的提交,
        /// 我们「一次手势一次提交」的动词模型让它天然以手势为撤销单元
        /// (merge interval 保持 0,不做击键合并——草稿层已经合并过了)。
        /// 不落盘:撤销栈是会话状态,重开文档从空栈开始。
        undo: Mutex<UndoManager>,
    },
}

impl BlockDocumentHandle {
    fn doc(&self) -> &LoroDoc {
        match self {
            Self::Transcript(projection) => projection.doc(),
            Self::Note { mirror, .. } => mirror.doc(),
        }
    }

    fn for_note(mirror: Mirror) -> Self {
        let undo = Mutex::new(UndoManager::new(mirror.doc()));
        Self::Note { mirror, undo }
    }
}

/// doc_id → 打开中的句柄。
pub(crate) type BlockDocumentRegistry = Mutex<HashMap<String, BlockDocumentHandle>>;

fn internal(message: impl std::fmt::Display) -> CoreError {
    CoreError::InternalError {
        message: message.to_string(),
    }
}

fn block_documents_dir(data_dir: &Path) -> PathBuf {
    data_dir.join("block-documents")
}

fn block_document_path(data_dir: &Path, doc_id: &str) -> Result<PathBuf, CoreError> {
    // doc_id 进文件名,拒绝路径分隔符——与其它 store 的防穿越纪律一致。
    if doc_id.is_empty() || doc_id.contains(['/', '\\', '.']) {
        return Err(internal(format!("非法块文档 id: {doc_id:?}")));
    }
    Ok(block_documents_dir(data_dir).join(format!("{doc_id}.loro")))
}

#[uniffi::export]
impl ZulangueCore {
    /// 打开(或按黄金祖先新建)一份块文档。幂等:已打开时校验 kind 后
    /// 原样返回。
    pub fn block_document_open(
        &self,
        doc_id: String,
        kind: FfiDocumentKind,
    ) -> Result<(), CoreError> {
        let kind: DocumentKind = kind.into();
        let path = block_document_path(&self.data_dir, &doc_id)?;

        let mut registry = self.block_documents.lock().unwrap();
        if let Some(existing) = registry.get(&doc_id) {
            let existing_kind = document_kind(existing.doc());
            if existing_kind != Some(kind) {
                return Err(internal(format!(
                    "块文档 {doc_id} 已按 {existing_kind:?} 打开,不能改按 {kind:?}"
                )));
            }
            return Ok(());
        }

        let doc = if path.exists() {
            let bytes = fs::read(&path).map_err(|e| internal(format!("读块文档: {e}")))?;
            let doc = LoroDoc::new();
            doc.set_record_timestamp(true);
            doc.import(&bytes)
                .map_err(|e| internal(format!("导入块文档快照: {e}")))?;
            // 纪元/种类混流在打开时就大声拒绝,不等到分享层。
            if document_kind(&doc) != Some(kind) {
                return Err(internal(format!(
                    "块文档 {doc_id} 声明的 kind 与请求不符(声明 {:?},请求 {kind:?})",
                    document_kind(&doc)
                )));
            }
            doc
        } else {
            new_block_document(kind)
        };

        let handle = match kind {
            DocumentKind::Transcript => {
                BlockDocumentHandle::Transcript(TranscriptProjection::open(doc).map_err(internal)?)
            }
            DocumentKind::Note => BlockDocumentHandle::for_note(
                Mirror::new(doc, Some(note_schema()), MirrorOptions::default())
                    .map_err(internal)?,
            ),
        };
        registry.insert(doc_id, handle);
        Ok(())
    }

    /// 落盘并关闭。未打开时幂等成功。转录稿同时从 EditorBridge 撤下
    /// ——bridge 挂载的生命周期与注册表句柄绑定,防止两边各持一份
    /// 漂移的文档。
    pub fn block_document_close(&self, doc_id: String) -> Result<(), CoreError> {
        let handle = self.block_documents.lock().unwrap().remove(&doc_id);
        match handle {
            Some(handle) => {
                if matches!(handle, BlockDocumentHandle::Transcript(_)) {
                    self.editor_bridge.evict(&doc_id);
                }
                self.save_block_document(&doc_id, &handle)
            }
            None => Ok(()),
        }
    }

    /// 当前句块序列(文档序)。
    pub fn transcript_blocks(&self, doc_id: String) -> Result<Vec<FfiUtteranceBlock>, CoreError> {
        self.with_transcript(&doc_id, |projection| {
            Ok(projection
                .refresh()
                .into_iter()
                .map(FfiUtteranceBlock::from)
                .collect())
        })
    }

    /// 机器投影:追加或更新一个采集句块。`frozen_lanes` 是用户已接管的
    /// 车道(事实来自 SQLite 车道 edit revision),机器绝不覆盖。
    pub fn transcript_machine_upsert(
        &self,
        doc_id: String,
        write: FfiMachineBlockWrite,
        frozen_lanes: Vec<String>,
    ) -> Result<(), CoreError> {
        self.with_transcript(&doc_id, |projection| {
            let frozen: BTreeSet<String> = frozen_lanes.iter().cloned().collect();
            projection
                .machine_upsert_block(
                    MachineBlockWrite {
                        id: write.id.clone(),
                        owner: write.owner.clone(),
                        text: write.text.clone(),
                        lanes: write.lanes.clone().into_iter().collect::<BTreeMap<_, _>>(),
                    },
                    &frozen,
                    None,
                )
                .map_err(internal)
        })?;
        self.persist_block_document(&doc_id)
    }

    /// 用户订正一条译文车道。
    pub fn transcript_user_replace_lane(
        &self,
        doc_id: String,
        block_id: String,
        lane: String,
        text: String,
    ) -> Result<(), CoreError> {
        self.with_transcript(&doc_id, |projection| {
            projection
                .user_replace_lane(&block_id, &lane, &text)
                .map_err(internal)
        })?;
        self.persist_block_document(&doc_id)
    }

    /// 用户订正原文车道。
    pub fn transcript_user_replace_text(
        &self,
        doc_id: String,
        block_id: String,
        text: String,
    ) -> Result<(), CoreError> {
        self.with_transcript(&doc_id, |projection| {
            projection
                .user_replace_text(&block_id, &text)
                .map_err(internal)
        })?;
        self.persist_block_document(&doc_id)
    }

    /// 用户在句块之间插批注块。
    pub fn transcript_insert_annotation(
        &self,
        doc_id: String,
        index: u32,
        annotation_id: String,
        text: String,
    ) -> Result<(), CoreError> {
        self.with_transcript(&doc_id, |projection| {
            projection
                .insert_annotation(index as usize, &annotation_id, &text)
                .map_err(internal)
        })?;
        self.persist_block_document(&doc_id)
    }

    /// 笔记的大纲行(先序)。
    pub fn note_outline_rows(&self, doc_id: String) -> Result<Vec<FfiOutlineRow>, CoreError> {
        self.with_note(&doc_id, |mirror| {
            let state = mirror.sync_from_loro();
            let root = state.get(NOTE_ROOT).cloned().unwrap_or(Value::Null);
            Ok(flatten_note(&root)
                .into_iter()
                .map(|row| FfiOutlineRow {
                    id: row.id,
                    depth: row.depth as u32,
                    text: row.text,
                })
                .collect())
        })
    }

    /// 用整份大纲行重放笔记结构(一次编辑手势一次调用)。
    ///
    /// 注意蓝本已知局限:同一次重放里「删行」与「跨删除位的移动」不能
    /// 混——单一手势天然满足;批量导入请拆多次调用。
    pub fn note_apply_outline(
        &self,
        doc_id: String,
        rows: Vec<FfiOutlineRow>,
    ) -> Result<(), CoreError> {
        self.with_note(&doc_id, |mirror| {
            let rows: Vec<OutlineRow> = rows
                .iter()
                .map(|row| OutlineRow {
                    id: row.id.clone(),
                    depth: row.depth as usize,
                    text: row.text.clone(),
                })
                .collect();

            let state = mirror.get_state();
            let current_root = state.get(NOTE_ROOT).cloned().unwrap_or(Value::Null);
            let root_id = current_root
                .get("$")
                .and_then(|meta| meta.get("id"))
                .and_then(Value::as_str)
                .unwrap_or("root")
                .to_string();

            let mut rebuilt = rebuild_note(&root_id, &rows);
            preserve_node_metadata(&current_root, &mut rebuilt);

            mirror
                .set_state(
                    |state| {
                        let mut next = state.clone();
                        next[NOTE_ROOT] = rebuilt.clone();
                        next
                    },
                    SetStateOptions {
                        tags: Some(vec!["user".to_string()]),
                    },
                )
                .map_err(internal)
        })?;
        self.persist_block_document(&doc_id)
    }

    /// 撤销最近一次本机编辑手势。`performed=false` 表示栈已空(不是错误)。
    ///
    /// 撤销由 Loro 的 UndoManager 以逆操作提交实现——它也是一次普通的
    /// 本地提交,mirror 经根订阅自动跟进,这里再显式 sync 一次只为把
    /// 「读到的行必是撤销后的行」写成代码里的事实而不是订阅时序的巧合。
    pub fn note_undo(&self, doc_id: String) -> Result<FfiNoteUndoState, CoreError> {
        let state = self.with_note_undo(&doc_id, |mirror, undo| {
            let mut undo = undo.lock().unwrap();
            let performed = undo.undo().map_err(internal)?;
            mirror.sync_from_loro();
            Ok(FfiNoteUndoState {
                performed,
                can_undo: undo.can_undo(),
                can_redo: undo.can_redo(),
            })
        })?;
        if state.performed {
            self.persist_block_document(&doc_id)?;
        }
        Ok(state)
    }

    /// 重做最近一次被撤销的手势。语义同 [`Self::note_undo`]。
    pub fn note_redo(&self, doc_id: String) -> Result<FfiNoteUndoState, CoreError> {
        let state = self.with_note_undo(&doc_id, |mirror, undo| {
            let mut undo = undo.lock().unwrap();
            let performed = undo.redo().map_err(internal)?;
            mirror.sync_from_loro();
            Ok(FfiNoteUndoState {
                performed,
                can_undo: undo.can_undo(),
                can_redo: undo.can_redo(),
            })
        })?;
        if state.performed {
            self.persist_block_document(&doc_id)?;
        }
        Ok(state)
    }

    /// 当前撤销栈状态(不执行任何操作,`performed` 恒 false)。
    pub fn note_undo_state(&self, doc_id: String) -> Result<FfiNoteUndoState, CoreError> {
        self.with_note_undo(&doc_id, |_, undo| {
            let undo = undo.lock().unwrap();
            Ok(FfiNoteUndoState {
                performed: false,
                can_undo: undo.can_undo(),
                can_redo: undo.can_redo(),
            })
        })
    }
}

#[uniffi::export]
impl ZulangueCore {
    /// 笔记 tab 的块文档入口:打开(必要时**从第 1 纪元迁移**)并返回
    /// doc_id。这是新大纲编辑器的唯一打开路径。
    ///
    /// 迁移规则(决定记录:笔记侧「可以宽松些」——内容迁移,历史归备份):
    /// - 已有块文档:直接打开;
    /// - 只有第 1 纪元平文本快照:逐行拆成深度 0 的大纲行(空行保留,
    ///   行即段落),写成 B 文档,旧快照改名 `<file>.pre-epoch2` 留档,
    ///   **不删除**;
    /// - 两者都无:按黄金祖先新建。
    ///
    /// 只接受 ManualNote tab:转录稿文档是证据,走阶段 4 的严格重放
    /// 迁移,绝不从这条宽松通道过。
    pub fn note_block_document_open(
        &self,
        notebook_id: String,
        tab_id: String,
    ) -> Result<String, CoreError> {
        let tab = self.resolve_product_editor_tab(&notebook_id, &tab_id)?;
        if tab.builtin_kind != vt_store::notebook_store::BuiltinNotebookTab::ManualNote {
            return Err(internal(format!(
                "只有笔记 tab 走块文档;{:?} 不是",
                tab.builtin_kind
            )));
        }
        let doc_id = tab.doc_id;

        let block_path = block_document_path(&self.data_dir, &doc_id)?;
        if !block_path.exists() {
            let legacy_path = crate::editor_api::snapshot_path(&self.data_dir, &doc_id);
            if legacy_path.exists() {
                self.migrate_legacy_note(&doc_id, &legacy_path)?;
            }
        }
        self.block_document_open(doc_id.clone(), FfiDocumentKind::Note)?;
        Ok(doc_id)
    }
}

impl ZulangueCore {
    /// 转录稿产线的块文档入口:打开(必要时**从第 1 纪元严格迁移**),
    /// 并把同一份 LoroDoc 挂进 EditorBridge。
    ///
    /// bridge 挂载就是 T2 转录稿在本机的全部「读端」:本机 UI 读 SQLite
    /// 历史与帧字幕,从不读文档;分享同步、纪元准入、销毁收据一家子都
    /// 从 bridge 应答。挂载的是同一份底层文档(LoroDoc 克隆共享状态),
    /// 所以远端 update 经 bridge 导入后,投影门面的下一次 refresh 就能
    /// 看到。
    ///
    /// 迁移规则(宪章阶段 4:转录稿是证据,严格重放):
    /// - 已有块文档:直接打开;
    /// - 只有第 1 纪元快照:`migrate_transcript_history` 逐 frontier
    ///   验证重放,成功后新文档落盘、旧快照改名 `<file>.pre-epoch2`
    ///   留档;**非线性历史拒迁**,旧文件不动,错误上抛(调用方决定把
    ///   投影态标 failed);
    /// - 两者都无:按黄金祖先新建。
    pub(crate) fn open_transcript_block_document(&self, doc_id: &str) -> Result<(), CoreError> {
        let block_path = block_document_path(&self.data_dir, doc_id)?;
        if !block_path.exists() {
            let legacy_path = crate::editor_api::snapshot_path(&self.data_dir, doc_id);
            if legacy_path.exists() {
                self.migrate_legacy_transcript(doc_id, &legacy_path)?;
            }
        }
        self.block_document_open(doc_id.to_string(), FfiDocumentKind::Transcript)?;
        self.register_transcript_in_bridge(doc_id)
    }

    /// 第 1 纪元转录稿 → T2 的严格迁移。先落新文档再改名旧文件,顺序
    /// 与笔记通道同一纪律:改名后崩溃会丢内容,落盘后崩溃只是下次重迁
    /// 一遍(块文档已存在则不再走这里)。
    fn migrate_legacy_transcript(&self, doc_id: &str, legacy_path: &Path) -> Result<(), CoreError> {
        let bytes =
            fs::read(legacy_path).map_err(|e| internal(format!("读第 1 纪元转录稿: {e}")))?;
        let legacy = LoroDoc::new();
        legacy
            .import(&bytes)
            .map_err(|e| internal(format!("导入第 1 纪元转录稿: {e}")))?;
        let migrated = vt_store::replay_migration::migrate_transcript_history(&legacy)
            .map_err(|e| internal(format!("严格迁移转录稿 {doc_id}: {e}")))?;
        let handle = BlockDocumentHandle::Transcript(
            TranscriptProjection::open(migrated).map_err(internal)?,
        );
        self.save_block_document(doc_id, &handle)?;
        let backup = legacy_path.with_extension("loro.pre-epoch2");
        fs::rename(legacy_path, &backup).map_err(|e| internal(format!("留档旧转录稿: {e}")))?;
        Ok(())
    }

    /// 把注册表里的 T2 转录稿挂进 EditorBridge(同一底层文档)。bridge
    /// 里同 key 的旧句柄(第 1 纪元的内存文档)先驱逐——块文档打开后,
    /// bridge 这个 key 的唯一合法身份就是这份 T2 文档。
    fn register_transcript_in_bridge(&self, doc_id: &str) -> Result<(), CoreError> {
        let doc = {
            let registry = self.block_documents.lock().unwrap();
            match registry.get(doc_id) {
                Some(BlockDocumentHandle::Transcript(projection)) => projection.doc().clone(),
                _ => return Err(internal(format!("块文档 {doc_id} 不是打开中的转录稿"))),
            }
        };
        self.editor_bridge.evict(doc_id);
        self.editor_bridge
            .open(doc_id, doc)
            .map_err(|e| internal(format!("转录稿挂载 bridge: {e}")))?;
        Ok(())
    }

    /// 第 1 纪元笔记 → B 块文档的内容迁移。旧文件改名留档,失败时不动
    /// 旧文件(下次打开重试)。
    fn migrate_legacy_note(&self, doc_id: &str, legacy_path: &Path) -> Result<(), CoreError> {
        let bytes = fs::read(legacy_path).map_err(|e| internal(format!("读第 1 纪元笔记: {e}")))?;
        let legacy = LoroDoc::new();
        legacy
            .import(&bytes)
            .map_err(|e| internal(format!("导入第 1 纪元笔记: {e}")))?;
        let content = legacy.get_text("content").to_string();

        // 逐行成行:行即段落,空行保留(内容逐字节可还原,深度全 0)。
        let rows: Vec<OutlineRow> = content
            .split('\n')
            .map(|line| OutlineRow {
                id: uuid::Uuid::new_v4().to_string(),
                depth: 0,
                text: line.to_string(),
            })
            .collect();

        let doc = new_block_document(DocumentKind::Note);
        let mirror =
            Mirror::new(doc, Some(note_schema()), MirrorOptions::default()).map_err(internal)?;
        let rebuilt = rebuild_note("root", &rows);
        mirror
            .set_state(
                |state| {
                    let mut next = state.clone();
                    next[NOTE_ROOT] = rebuilt.clone();
                    next
                },
                SetStateOptions {
                    tags: Some(vec!["migration".to_string()]),
                },
            )
            .map_err(internal)?;

        // 先落新文档,再给旧文件改名——顺序不能反:改名后崩溃会丢内容,
        // 落盘后崩溃只是下次多迁一遍(幂等,块文档已存在则不再走这里)。
        let handle = BlockDocumentHandle::for_note(mirror);
        self.save_block_document(doc_id, &handle)?;
        let backup = legacy_path.with_extension("loro.pre-epoch2");
        fs::rename(legacy_path, &backup).map_err(|e| internal(format!("留档旧笔记: {e}")))?;
        Ok(())
    }

    /// T2 产线(notebook_capture_api)与本模块共用的句柄访问器。
    pub(crate) fn with_transcript<T>(
        &self,
        doc_id: &str,
        run: impl FnOnce(&TranscriptProjection) -> Result<T, CoreError>,
    ) -> Result<T, CoreError> {
        let registry = self.block_documents.lock().unwrap();
        match registry.get(doc_id) {
            Some(BlockDocumentHandle::Transcript(projection)) => run(projection),
            Some(BlockDocumentHandle::Note { .. }) => {
                Err(internal(format!("块文档 {doc_id} 是笔记,不接受转录稿动词")))
            }
            None => Err(internal(format!("块文档 {doc_id} 未打开"))),
        }
    }

    fn with_note<T>(
        &self,
        doc_id: &str,
        run: impl FnOnce(&Mirror) -> Result<T, CoreError>,
    ) -> Result<T, CoreError> {
        self.with_note_undo(doc_id, |mirror, _| run(mirror))
    }

    /// 同 `with_note`,但连撤销栈一起交给闭包(撤销动词要它)。
    fn with_note_undo<T>(
        &self,
        doc_id: &str,
        run: impl FnOnce(&Mirror, &Mutex<UndoManager>) -> Result<T, CoreError>,
    ) -> Result<T, CoreError> {
        let registry = self.block_documents.lock().unwrap();
        match registry.get(doc_id) {
            Some(BlockDocumentHandle::Note { mirror, undo }) => run(mirror, undo),
            Some(BlockDocumentHandle::Transcript(_)) => {
                Err(internal(format!("块文档 {doc_id} 是转录稿,不接受笔记动词")))
            }
            None => Err(internal(format!("块文档 {doc_id} 未打开"))),
        }
    }

    pub(crate) fn persist_block_document(&self, doc_id: &str) -> Result<(), CoreError> {
        let registry = self.block_documents.lock().unwrap();
        let Some(handle) = registry.get(doc_id) else {
            return Err(internal(format!("块文档 {doc_id} 未打开")));
        };
        self.save_block_document(doc_id, handle)
    }

    fn save_block_document(
        &self,
        doc_id: &str,
        handle: &BlockDocumentHandle,
    ) -> Result<(), CoreError> {
        let path = block_document_path(&self.data_dir, doc_id)?;
        fs::create_dir_all(block_documents_dir(&self.data_dir))
            .map_err(|e| internal(format!("建块文档目录: {e}")))?;
        let bytes = handle
            .doc()
            .export(loro::ExportMode::Snapshot)
            .map_err(|e| internal(format!("导出块文档快照: {e}")))?;
        fs::write(&path, bytes).map_err(|e| internal(format!("写块文档快照: {e}")))
    }
}

/// 重放保真:既有节点 `$` 里 id 之外的键按 id 拷回重建的树。
fn preserve_node_metadata(current_root: &Value, rebuilt_root: &mut Value) {
    let mut metadata_by_id: HashMap<String, Value> = HashMap::new();
    collect_metadata(current_root, &mut metadata_by_id);
    restore_metadata(rebuilt_root, &metadata_by_id);
}

fn collect_metadata(node: &Value, sink: &mut HashMap<String, Value>) {
    if let Some(meta) = node.get("$") {
        if let Some(id) = meta.get("id").and_then(Value::as_str) {
            if meta.as_object().is_some_and(|m| m.len() > 1) {
                sink.insert(id.to_string(), meta.clone());
            }
        }
    }
    if let Some(children) = node.get("children").and_then(Value::as_array) {
        for child in children {
            collect_metadata(child, sink);
        }
    }
}

fn restore_metadata(node: &mut Value, metadata_by_id: &HashMap<String, Value>) {
    let id = node
        .get("$")
        .and_then(|meta| meta.get("id"))
        .and_then(Value::as_str)
        .map(|s| s.to_string());
    if let Some(id) = id {
        if let Some(saved) = metadata_by_id.get(&id) {
            let mut merged = saved.clone();
            merged["id"] = json!(id);
            node["$"] = merged;
        }
    }
    if let Some(children) = node.get_mut("children").and_then(Value::as_array_mut) {
        for child in children {
            restore_metadata(child, metadata_by_id);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    fn core() -> (TempDir, ZulangueCore) {
        let dir = TempDir::new().unwrap();
        let core = ZulangueCore::new_for_test(dir.path().to_string_lossy().to_string()).unwrap();
        (dir, core)
    }

    fn machine(id: &str, text: &str) -> FfiMachineBlockWrite {
        FfiMachineBlockWrite {
            id: id.to_string(),
            owner: "capture:s1".to_string(),
            text: text.to_string(),
            lanes: HashMap::new(),
        }
    }

    #[test]
    fn transcript_verbs_round_trip_through_the_ffi() {
        let (_dir, core) = core();
        core.block_document_open("t1".into(), FfiDocumentKind::Transcript)
            .unwrap();
        core.transcript_machine_upsert("t1".into(), machine("u1", "一"), vec![])
            .unwrap();
        core.transcript_user_replace_lane("t1".into(), "u1".into(), "zh".into(), "壹".into())
            .unwrap();
        core.transcript_insert_annotation("t1".into(), 1, "n1".into(), "批注".into())
            .unwrap();

        let blocks = core.transcript_blocks("t1".into()).unwrap();
        assert_eq!(blocks.len(), 2);
        assert_eq!(blocks[0].lanes["zh"], "壹");
        assert_eq!(blocks[1].owner, "user");
    }

    #[test]
    fn block_documents_survive_close_and_reopen() {
        let (_dir, core) = core();
        core.block_document_open("t1".into(), FfiDocumentKind::Transcript)
            .unwrap();
        core.transcript_machine_upsert("t1".into(), machine("u1", "一"), vec![])
            .unwrap();
        core.block_document_close("t1".into()).unwrap();

        core.block_document_open("t1".into(), FfiDocumentKind::Transcript)
            .unwrap();
        let blocks = core.transcript_blocks("t1".into()).unwrap();
        assert_eq!(blocks.len(), 1);
        assert_eq!(blocks[0].text, "一");
    }

    #[test]
    fn reopening_with_the_wrong_kind_is_refused_loudly() {
        let (_dir, core) = core();
        core.block_document_open("t1".into(), FfiDocumentKind::Transcript)
            .unwrap();
        core.transcript_machine_upsert("t1".into(), machine("u1", "一"), vec![])
            .unwrap();
        core.block_document_close("t1".into()).unwrap();
        assert!(core
            .block_document_open("t1".into(), FfiDocumentKind::Note)
            .is_err());
    }

    #[test]
    fn kind_mismatched_verbs_are_refused() {
        let (_dir, core) = core();
        core.block_document_open("n1".into(), FfiDocumentKind::Note)
            .unwrap();
        assert!(core.transcript_blocks("n1".into()).is_err());
        assert!(core.note_outline_rows("missing".into()).is_err());
    }

    #[test]
    fn note_outline_applies_and_reads_back() {
        let (_dir, core) = core();
        core.block_document_open("n1".into(), FfiDocumentKind::Note)
            .unwrap();
        let rows = vec![
            FfiOutlineRow {
                id: "a".into(),
                depth: 0,
                text: "一".into(),
            },
            FfiOutlineRow {
                id: "a1".into(),
                depth: 1,
                text: "一之一".into(),
            },
            FfiOutlineRow {
                id: "b".into(),
                depth: 0,
                text: "二".into(),
            },
        ];
        core.note_apply_outline("n1".into(), rows.clone()).unwrap();
        let read_back = core.note_outline_rows("n1".into()).unwrap();
        assert_eq!(read_back.len(), 3);
        assert_eq!(read_back[1].id, "a1");
        assert_eq!(read_back[1].depth, 1);
    }

    fn outline_row(id: &str, text: &str) -> FfiOutlineRow {
        FfiOutlineRow {
            id: id.into(),
            depth: 0,
            text: text.into(),
        }
    }

    #[test]
    fn undo_reverts_one_gesture_and_redo_restores_it() {
        let (_dir, core) = core();
        core.block_document_open("n1".into(), FfiDocumentKind::Note)
            .unwrap();

        // 两次独立手势 = 两个撤销单元。
        core.note_apply_outline("n1".into(), vec![outline_row("a", "一")])
            .unwrap();
        core.note_apply_outline("n1".into(), vec![outline_row("a", "一改")])
            .unwrap();

        let state = core.note_undo("n1".into()).unwrap();
        assert!(state.performed);
        assert!(state.can_redo);
        assert_eq!(core.note_outline_rows("n1".into()).unwrap()[0].text, "一");

        let state = core.note_redo("n1".into()).unwrap();
        assert!(state.performed);
        assert_eq!(core.note_outline_rows("n1".into()).unwrap()[0].text, "一改");
    }

    #[test]
    fn undo_on_an_empty_stack_is_a_calm_no_op() {
        let (_dir, core) = core();
        core.block_document_open("n1".into(), FfiDocumentKind::Note)
            .unwrap();
        let state = core.note_undo("n1".into()).unwrap();
        assert!(!state.performed);
        assert!(!state.can_undo);
        assert!(!state.can_redo);
    }

    #[test]
    fn undo_survives_persistence_and_stack_resets_on_reopen() {
        let (_dir, core) = core();
        core.block_document_open("n1".into(), FfiDocumentKind::Note)
            .unwrap();
        core.note_apply_outline("n1".into(), vec![outline_row("a", "一")])
            .unwrap();
        core.note_apply_outline("n1".into(), vec![outline_row("a", "一改")])
            .unwrap();
        assert!(core.note_undo("n1".into()).unwrap().performed);

        // 撤销后的状态落盘;重开后内容是撤销后的,撤销栈从空开始。
        core.block_document_close("n1".into()).unwrap();
        core.block_document_open("n1".into(), FfiDocumentKind::Note)
            .unwrap();
        assert_eq!(core.note_outline_rows("n1".into()).unwrap()[0].text, "一");
        let state = core.note_undo_state("n1".into()).unwrap();
        assert!(!state.can_undo);
        assert!(!state.can_redo);
    }

    #[test]
    fn legacy_note_migrates_on_first_open_and_keeps_a_backup() {
        let (dir, core) = core();
        let notebook = core.create_notebook(Some("迁移".into())).unwrap();
        let tabs = core.list_notebook_tabs(notebook.id.clone()).unwrap();
        let note_tab = tabs
            .iter()
            .find(|tab| tab.builtin_kind == "manual_note")
            .expect("Notebook 应有笔记 tab");

        // 伪造一份第 1 纪元平文本笔记快照。
        let legacy = LoroDoc::new();
        legacy
            .get_text("content")
            .insert(0, "第一段\n\n第三行")
            .unwrap();
        legacy.commit();
        let legacy_path = crate::editor_api::snapshot_path(dir.path(), &note_tab.doc_id);
        fs::create_dir_all(legacy_path.parent().unwrap()).unwrap();
        fs::write(
            &legacy_path,
            legacy.export(loro::ExportMode::Snapshot).unwrap(),
        )
        .unwrap();

        let doc_id = core
            .note_block_document_open(notebook.id.clone(), note_tab.id.clone())
            .unwrap();
        let rows = core.note_outline_rows(doc_id.clone()).unwrap();
        assert_eq!(
            rows.iter().map(|r| r.text.as_str()).collect::<Vec<_>>(),
            vec!["第一段", "", "第三行"],
            "逐行成行,空行保留"
        );
        assert!(rows.iter().all(|r| r.depth == 0));

        // 旧文件留档,原路径腾空;再次打开不再迁移(幂等)。
        assert!(!legacy_path.exists());
        assert!(legacy_path.with_extension("loro.pre-epoch2").exists());
        core.block_document_close(doc_id.clone()).unwrap();
        let reopened = core
            .note_block_document_open(notebook.id, note_tab.id.clone())
            .unwrap();
        assert_eq!(core.note_outline_rows(reopened).unwrap().len(), 3);
    }

    #[test]
    fn transcript_open_or_migrate_creates_opens_and_migrates() {
        let (dir, core) = core();

        // 两者都无:按黄金祖先新建,并挂进 bridge。
        core.open_transcript_block_document("t-fresh").unwrap();
        assert!(core.transcript_blocks("t-fresh".into()).unwrap().is_empty());
        assert_eq!(core.editor_bridge.schema_epoch("t-fresh"), Some(2));

        // 已有块文档:关掉重开,直接打开。
        core.transcript_machine_upsert("t-fresh".into(), machine("u1", "一"), vec![])
            .unwrap();
        core.block_document_close("t-fresh".into()).unwrap();
        assert!(
            !core.editor_bridge.is_session_open("t-fresh"),
            "关闭同时撤下 bridge 挂载"
        );
        core.open_transcript_block_document("t-fresh").unwrap();
        assert_eq!(core.transcript_blocks("t-fresh".into()).unwrap().len(), 1);

        // 只有第 1 纪元快照:严格重放迁移 + 留档。
        let legacy = LoroDoc::new();
        legacy
            .get_text("content")
            .insert(0, "## session-a\n机器句\n")
            .unwrap();
        legacy.commit();
        let legacy_path = crate::editor_api::snapshot_path(dir.path(), "t-legacy");
        fs::create_dir_all(legacy_path.parent().unwrap()).unwrap();
        fs::write(
            &legacy_path,
            legacy.export(loro::ExportMode::Snapshot).unwrap(),
        )
        .unwrap();

        core.open_transcript_block_document("t-legacy").unwrap();
        let blocks = core.transcript_blocks("t-legacy".into()).unwrap();
        assert_eq!(
            blocks.iter().map(|b| b.text.as_str()).collect::<Vec<_>>(),
            vec!["## session-a", "机器句", ""],
            "行块保真:每行一块(末尾换行产生空尾行)"
        );
        assert_eq!(blocks[1].owner, "capture:session-a");
        assert!(!legacy_path.exists());
        assert!(legacy_path.with_extension("loro.pre-epoch2").exists());
    }

    #[test]
    fn transcript_migration_refuses_non_linear_history_and_keeps_the_original() {
        let (dir, core) = core();
        let a = LoroDoc::new();
        a.get_text("content").insert(0, "共同起点\n").unwrap();
        a.commit();
        let b = LoroDoc::new();
        b.import(&a.export(loro::ExportMode::Snapshot).unwrap())
            .unwrap();
        a.get_text("content").insert(0, "甲 ").unwrap();
        a.commit();
        b.get_text("content").insert(0, "乙 ").unwrap();
        b.commit();
        a.import(&b.export(loro::ExportMode::Snapshot).unwrap())
            .unwrap();

        let legacy_path = crate::editor_api::snapshot_path(dir.path(), "t-forked");
        fs::create_dir_all(legacy_path.parent().unwrap()).unwrap();
        fs::write(&legacy_path, a.export(loro::ExportMode::Snapshot).unwrap()).unwrap();

        let error = core.open_transcript_block_document("t-forked").unwrap_err();
        assert!(
            error.to_string().contains("非线性"),
            "拒迁要报出原因: {error}"
        );
        assert!(legacy_path.exists(), "旧文件不动");
        assert!(
            !block_document_path(dir.path(), "t-forked")
                .unwrap()
                .exists(),
            "不留半成品块文档"
        );
    }

    /// bridge 挂载与注册表共享同一份底层文档:经 bridge 导入的远端
    /// update,投影门面 refresh 后立即可见——这是分享同步在 T2 上继续
    /// 工作的前提。
    #[test]
    fn bridge_registration_shares_the_same_document_state() {
        let (_dir, core) = core();
        core.open_transcript_block_document("t-share").unwrap();
        core.transcript_machine_upsert("t-share".into(), machine("u1", "一"), vec![])
            .unwrap();

        // 远端:从 bridge 导出的快照分叉出一份,插一个批注块。
        let remote = LoroDoc::new();
        remote
            .import(&core.editor_bridge.export_snapshot("t-share").unwrap())
            .unwrap();
        let remote_projection = TranscriptProjection::open(remote).unwrap();
        remote_projection
            .insert_annotation(1, "n1", "远端批注")
            .unwrap();
        let update = remote_projection
            .doc()
            .export(loro::ExportMode::Snapshot)
            .unwrap();

        assert!(core.editor_bridge.import_remote_update("t-share", &update));
        let blocks = core.transcript_blocks("t-share".into()).unwrap();
        assert_eq!(
            blocks.iter().map(|b| b.id.as_str()).collect::<Vec<_>>(),
            vec!["u1", "n1"],
            "bridge 导入对投影门面立即可见"
        );
    }

    #[test]
    fn transcript_tabs_are_refused_by_the_note_entry() {
        let (_dir, core) = core();
        let notebook = core.create_notebook(Some("拒".into())).unwrap();
        let tabs = core.list_notebook_tabs(notebook.id.clone()).unwrap();
        let async_tab = tabs
            .iter()
            .find(|tab| tab.builtin_kind == "async_transcript")
            .expect("Notebook 应有 async tab");
        assert!(core
            .note_block_document_open(notebook.id, async_tab.id.clone())
            .is_err());
    }

    #[test]
    fn outline_replay_preserves_node_metadata() {
        let (_dir, core) = core();
        core.block_document_open("n1".into(), FfiDocumentKind::Note)
            .unwrap();
        core.note_apply_outline(
            "n1".into(),
            vec![FfiOutlineRow {
                id: "a".into(),
                depth: 0,
                text: "一".into(),
            }],
        )
        .unwrap();

        // 直接往节点 $ 里塞一个未来的元数据键(模拟创建时间)。
        {
            let registry = core.block_documents.lock().unwrap();
            let Some(BlockDocumentHandle::Note { mirror, .. }) = registry.get("n1") else {
                panic!("n1 应当是笔记");
            };
            let mut state = mirror.get_state();
            state[NOTE_ROOT]["children"][0]["$"]["created_at"] = json!("2026-08-07");
            mirror
                .set_state(|_| state.clone(), SetStateOptions::default())
                .unwrap();
        }

        // 重放一次纯文本编辑:元数据必须原样保留。
        core.note_apply_outline(
            "n1".into(),
            vec![FfiOutlineRow {
                id: "a".into(),
                depth: 0,
                text: "一(改)".into(),
            }],
        )
        .unwrap();

        let registry = core.block_documents.lock().unwrap();
        let Some(BlockDocumentHandle::Note { mirror, .. }) = registry.get("n1") else {
            panic!("n1 应当是笔记");
        };
        let state = mirror.get_state();
        assert_eq!(
            state[NOTE_ROOT]["children"][0]["$"]["created_at"],
            json!("2026-08-07")
        );
        assert_eq!(state[NOTE_ROOT]["children"][0]["text"], json!("一(改)"));
    }
}
