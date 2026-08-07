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

use loro::LoroDoc;
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

/// 打开中的块文档。
pub(crate) enum BlockDocumentHandle {
    Transcript(TranscriptProjection),
    Note(Mirror),
}

impl BlockDocumentHandle {
    fn doc(&self) -> &LoroDoc {
        match self {
            Self::Transcript(projection) => projection.doc(),
            Self::Note(mirror) => mirror.doc(),
        }
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
            DocumentKind::Note => BlockDocumentHandle::Note(
                Mirror::new(doc, Some(note_schema()), MirrorOptions::default())
                    .map_err(internal)?,
            ),
        };
        registry.insert(doc_id, handle);
        Ok(())
    }

    /// 落盘并关闭。未打开时幂等成功。
    pub fn block_document_close(&self, doc_id: String) -> Result<(), CoreError> {
        let handle = self.block_documents.lock().unwrap().remove(&doc_id);
        match handle {
            Some(handle) => self.save_block_document(&doc_id, &handle),
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
}

impl ZulangueCore {
    fn with_transcript<T>(
        &self,
        doc_id: &str,
        run: impl FnOnce(&TranscriptProjection) -> Result<T, CoreError>,
    ) -> Result<T, CoreError> {
        let registry = self.block_documents.lock().unwrap();
        match registry.get(doc_id) {
            Some(BlockDocumentHandle::Transcript(projection)) => run(projection),
            Some(BlockDocumentHandle::Note(_)) => {
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
        let registry = self.block_documents.lock().unwrap();
        match registry.get(doc_id) {
            Some(BlockDocumentHandle::Note(mirror)) => run(mirror),
            Some(BlockDocumentHandle::Transcript(_)) => {
                Err(internal(format!("块文档 {doc_id} 是转录稿,不接受笔记动词")))
            }
            None => Err(internal(format!("块文档 {doc_id} 未打开"))),
        }
    }

    fn persist_block_document(&self, doc_id: &str) -> Result<(), CoreError> {
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
            let Some(BlockDocumentHandle::Note(mirror)) = registry.get("n1") else {
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
        let Some(BlockDocumentHandle::Note(mirror)) = registry.get("n1") else {
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
