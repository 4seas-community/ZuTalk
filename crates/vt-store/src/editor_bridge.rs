//! EditorBridge — Loro 文档编辑管理
//! 权威：D4 §6

use std::collections::HashMap;
use std::sync::Arc;

use loro::{LoroDoc, LoroValue, StyleConfigMap};
use std::sync::Mutex;
use tokio::sync::mpsc;

/// 编辑操作
#[derive(Debug, Clone)]
pub enum EditOp {
    Insert {
        pos: usize,
        text: String,
    },
    Delete {
        pos: usize,
        len: usize,
    },
    Replace {
        pos: usize,
        len: usize,
        text: String,
    },
    /// Rich text mark(e.g. bold / italic / heading)
    ///
    /// value_json:JSON 序列化后的属性值 — "true" / "1" / "\"#ff0000\"" 等。
    /// 交给桥解析成 LoroValue,UI 侧只需要懂 JSON 原语即可。
    Mark {
        pos: usize,
        len: usize,
        key: String,
        value_json: String,
    },
    /// 移除某段 range 上的 mark key
    Unmark {
        pos: usize,
        len: usize,
        key: String,
    },
}

/// 把 UI 层传来的 JSON 字符串转成 Loro 接受的 LoroValue。
/// 只处理常见原语:null / bool / i64 / f64 / string;其它降级为 string。
fn json_to_loro_value(s: &str) -> LoroValue {
    use serde_json::Value;
    let v: Value = match serde_json::from_str(s) {
        Ok(v) => v,
        Err(_) => return LoroValue::String(s.to_string().into()),
    };
    match v {
        Value::Null => LoroValue::Null,
        Value::Bool(b) => LoroValue::Bool(b),
        Value::Number(n) => {
            if let Some(i) = n.as_i64() {
                LoroValue::I64(i)
            } else if let Some(f) = n.as_f64() {
                LoroValue::Double(f)
            } else {
                LoroValue::String(n.to_string().into())
            }
        }
        Value::String(s) => LoroValue::String(s.into()),
        other => LoroValue::String(other.to_string().into()),
    }
}

/// 编辑器事件
#[derive(Debug)]
pub enum EditorEvent {
    Change { delta: Vec<u8>, generation: u64 },
}

/// 编辑器句柄
pub struct EditorHandle {
    session_id: String,
}

impl EditorHandle {
    pub fn is_open(&self) -> bool {
        !self.session_id.is_empty()
    }
}

struct OpenSession {
    doc: LoroDoc,
    generation: u64,
    callback: Option<mpsc::Sender<EditorEvent>>,
    /// 引用计数。SwiftUI NSViewRepresentable 在 view identity 变化时
    /// 顺序是 `makeNSView(new) → updateNSView(new) → dismantleNSView(old)`。
    /// 如果 new 和 old 是同一 docId(用户退出再进入同一 session),new 会
    /// 先 `open` → refcount=2,old 随后 dismantle `close` → refcount=1。
    /// 这样 new 持有的 session 不会被 old 的 close 误关。
    /// 只有 refcount 降到 0 才真从 HashMap 删除。
    refcount: u32,
}

/// Loro 文档编辑器桥接。
/// Clone 廉价(内部只含一个 Arc),用于把 handle 传给后台 tokio 任务。
#[derive(Clone)]
pub struct EditorBridge {
    sessions: Arc<Mutex<HashMap<String, OpenSession>>>,
}

/// 无纪元字段文档的补写值。T2 切换后,转录稿与笔记都是第 2 纪元块文档
/// (纪元由 `document_schema::new_block_document` 在创建时写入);仍以
/// 平文本存续的只有 Async Transcript 一族,它们按这里的第 1 纪元补章。
/// 新旧纪元不得混流 —— 两个纪元的 oplog 属于两个结构不同的文档,合并会
/// 同时损坏两边。见 docs/architecture/document-schema-decision.md「迁移」
/// 一节与 t2-capture-switchover.md。
pub const CURRENT_SCHEMA_EPOCH: u64 = 1;
/// 纪元字段引入之前的文档一律按第 1 纪元读。这个值永远是 1,不随
/// `CURRENT_SCHEMA_EPOCH` 演进 —— 「字段缺失」的含义在字段引入那一刻就
/// 冻结了。
const PRE_EPOCH_FIELD: u64 = 1;
pub(crate) const DOCUMENT_META: &str = "zulangue_document_meta";
pub(crate) const SCHEMA_EPOCH_KEY: &str = "schema_epoch";

/// 读一份文档声明的纪元。缺失或损坏都按 [`PRE_EPOCH_FIELD`] 读 —— 判定必须
/// 在每台机器上得出同一个答案,否则同一份文档会被两个对端读出两个纪元。
fn schema_epoch_of(doc: &LoroDoc) -> u64 {
    let Some(value) = doc.get_map(DOCUMENT_META).get(SCHEMA_EPOCH_KEY) else {
        return PRE_EPOCH_FIELD;
    };
    match value.get_deep_value() {
        LoroValue::I64(epoch) => u64::try_from(epoch).unwrap_or(PRE_EPOCH_FIELD),
        _ => PRE_EPOCH_FIELD,
    }
}

/// 给尚无纪元字段的文档补上当前纪元。已带字段的文档原样保留 —— 未来第 2
/// 纪元的文档绝不能在这里被盖写回 1。写入失败不致命:读侧对缺失字段的
/// 解读(第 1 纪元)与今天要写的值一致。
fn stamp_schema_epoch(doc: &LoroDoc) {
    let meta = doc.get_map(DOCUMENT_META);
    if meta.get(SCHEMA_EPOCH_KEY).is_some() {
        return;
    }
    if meta
        .insert(SCHEMA_EPOCH_KEY, CURRENT_SCHEMA_EPOCH as i64)
        .is_ok()
    {
        doc.commit();
    }
}

fn apply_edit_op(doc: &LoroDoc, op: &EditOp) -> Result<(), EditorBridgeError> {
    let loro_text = doc.get_text("content");
    match op {
        EditOp::Insert { pos, text } => {
            loro_text
                .insert(*pos, text)
                .map_err(|error| EditorBridgeError::LoroError(error.to_string()))?;
        }
        EditOp::Delete { pos, len } => {
            loro_text
                .delete(*pos, *len)
                .map_err(|error| EditorBridgeError::LoroError(error.to_string()))?;
        }
        EditOp::Replace { pos, len, text } => {
            loro_text
                .delete(*pos, *len)
                .map_err(|error| EditorBridgeError::LoroError(error.to_string()))?;
            loro_text
                .insert(*pos, text)
                .map_err(|error| EditorBridgeError::LoroError(error.to_string()))?;
        }
        EditOp::Mark {
            pos,
            len,
            key,
            value_json,
        } => {
            let end = pos.saturating_add(*len);
            let value = json_to_loro_value(value_json);
            loro_text
                .mark(*pos..end, key, value)
                .map_err(|error| EditorBridgeError::LoroError(error.to_string()))?;
        }
        EditOp::Unmark { pos, len, key } => {
            let end = pos.saturating_add(*len);
            loro_text
                .unmark(*pos..end, key)
                .map_err(|error| EditorBridgeError::LoroError(error.to_string()))?;
        }
    }
    Ok(())
}

impl EditorBridge {
    pub fn new() -> Self {
        Self {
            sessions: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    /// 打开文档进行编辑。
    ///
    /// 语义:幂等 + 引用计数。如果同 `session_id` 已开,只递增 refcount,
    /// **不覆盖** 内存中的 LoroDoc —— 这保护了用户尚未落盘的编辑不被
    /// "同 docId 二次 open 路径带入的空 doc" 冲掉。
    pub fn open(&self, session_id: &str, doc: LoroDoc) -> Result<EditorHandle, EditorBridgeError> {
        let mut sessions = self.sessions.lock().unwrap();
        if let Some(existing) = sessions.get_mut(session_id) {
            existing.refcount = existing.refcount.saturating_add(1);
        } else {
            stamp_schema_epoch(&doc);
            sessions.insert(
                session_id.to_string(),
                OpenSession {
                    doc,
                    generation: 0,
                    callback: None,
                    refcount: 1,
                },
            );
        }
        Ok(EditorHandle {
            session_id: session_id.to_string(),
        })
    }

    /// 打开文档并注册回调
    pub fn open_with_callback(
        &self,
        session_id: &str,
        doc: LoroDoc,
        callback: mpsc::Sender<EditorEvent>,
    ) -> Result<EditorHandle, EditorBridgeError> {
        let mut sessions = self.sessions.lock().unwrap();
        if let Some(existing) = sessions.get_mut(session_id) {
            existing.refcount = existing.refcount.saturating_add(1);
            // 有人明确传新 callback 就更新(后注册覆盖前) —— 旧 callback
            // 语义上已过期(对应的 EditorHandle 持有者不再活跃)。
            existing.callback = Some(callback);
        } else {
            stamp_schema_epoch(&doc);
            sessions.insert(
                session_id.to_string(),
                OpenSession {
                    doc,
                    generation: 0,
                    callback: Some(callback),
                    refcount: 1,
                },
            );
        }
        Ok(EditorHandle {
            session_id: session_id.to_string(),
        })
    }

    /// 应用编辑操作
    pub fn apply(&self, session_id: &str, op: EditOp) -> Result<(), EditorBridgeError> {
        let mut sessions = self.sessions.lock().unwrap();
        let session = sessions
            .get_mut(session_id)
            .ok_or(EditorBridgeError::SessionNotOpen)?;

        apply_edit_op(&session.doc, &op)?;

        session.generation += 1;
        if let Some(cb) = &session.callback {
            let snapshot = session
                .doc
                .export(loro::ExportMode::Snapshot)
                .unwrap_or_default();
            let _ = cb.try_send(EditorEvent::Change {
                delta: snapshot,
                generation: session.generation,
            });
        }

        Ok(())
    }

    /// UI 侧回写，附带 generation 防回环
    pub fn apply_from_ui(
        &self,
        session_id: &str,
        op: EditOp,
        from_generation: u64,
    ) -> Result<(), EditorBridgeError> {
        let sessions = self.sessions.lock().unwrap();
        let session = sessions
            .get(session_id)
            .ok_or(EditorBridgeError::SessionNotOpen)?;

        if from_generation == session.generation {
            return Ok(());
        }
        drop(sessions);
        self.apply(session_id, op)
    }

    /// 获取文档内容(纯文本,丢弃所有 mark 属性)
    pub fn get_content(&self, session_id: &str) -> Result<String, EditorBridgeError> {
        let sessions = self.sessions.lock().unwrap();
        let session = sessions
            .get(session_id)
            .ok_or(EditorBridgeError::SessionNotOpen)?;

        let text = session.doc.get_text("content");
        Ok(text.to_string())
    }

    /// 获取文档的 Quill Delta 格式(含 mark 属性),序列化为 JSON string。
    ///
    /// 返回:形如 `[{"insert":"Hello","attributes":{"bold":true}},{"insert":" world"}]`
    /// 的 JSON 数组,每个元素一个 Delta segment。
    ///
    /// Swift 侧解析 JSON 即可构建 NSAttributedString。
    pub fn get_delta(&self, session_id: &str) -> Result<String, EditorBridgeError> {
        let sessions = self.sessions.lock().unwrap();
        let session = sessions
            .get(session_id)
            .ok_or(EditorBridgeError::SessionNotOpen)?;

        let text = session.doc.get_text("content");
        let delta = text.to_delta();
        serde_json::to_string(&delta).map_err(|e| EditorBridgeError::LoroError(e.to_string()))
    }

    /// Stores an idempotency receipt inside the same Loro snapshot as a
    /// Delete Forever text mutation. This closes the crash window between a
    /// successful snapshot rename and the SQLite purge-job phase update.
    pub fn set_session_purge_receipt(
        &self,
        document_id: &str,
        session_id: &str,
    ) -> Result<(), EditorBridgeError> {
        let sessions = self.sessions.lock().unwrap();
        let session = sessions
            .get(document_id)
            .ok_or(EditorBridgeError::SessionNotOpen)?;
        session
            .doc
            .get_map("zulangue_session_purge_receipts")
            .insert(session_id, true)
            .map_err(|error| EditorBridgeError::LoroError(error.to_string()))
    }

    pub fn has_session_purge_receipt(
        &self,
        document_id: &str,
        session_id: &str,
    ) -> Result<bool, EditorBridgeError> {
        let sessions = self.sessions.lock().unwrap();
        let session = sessions
            .get(document_id)
            .ok_or(EditorBridgeError::SessionNotOpen)?;
        Ok(session
            .doc
            .get_map("zulangue_session_purge_receipts")
            .get(session_id)
            .is_some_and(|value| value.get_deep_value() == LoroValue::Bool(true)))
    }

    pub fn clear_session_purge_receipt(
        &self,
        document_id: &str,
        session_id: &str,
    ) -> Result<(), EditorBridgeError> {
        let sessions = self.sessions.lock().unwrap();
        let session = sessions
            .get(document_id)
            .ok_or(EditorBridgeError::SessionNotOpen)?;
        session
            .doc
            .get_map("zulangue_session_purge_receipts")
            .delete(session_id)
            .map_err(|error| EditorBridgeError::LoroError(error.to_string()))
    }

    /// 关闭文档。配合 `open` 的 refcount:仅当 refcount 降到 0 才真从
    /// HashMap 移除内存状态。
    ///
    /// 返回 `true` 表示 session 已被真正移除(所有 owner 都 close 完),
    /// 调用方(FFI 层)此时可以清理 per-session 资源(如 editor_callbacks
    /// 注册表 / pending_snapshot_saves 条目)。`false` 表示还有其它 owner
    /// 在用,不应清理。不存在的 session 返回 `true`(幂等)。
    pub fn close(&self, session_id: &str) -> Result<bool, EditorBridgeError> {
        let mut sessions = self.sessions.lock().unwrap();
        match sessions.get_mut(session_id) {
            Some(session) if session.refcount > 1 => {
                session.refcount -= 1;
                Ok(false)
            }
            Some(_) => {
                sessions.remove(session_id);
                Ok(true)
            }
            None => Ok(true),
        }
    }

    /// Permanently removes an open document regardless of UI refcount.
    /// Delete Forever uses this only after its durable purge tombstone exists,
    /// preventing a stale owner or background flusher from recreating content.
    pub fn evict(&self, session_id: &str) {
        self.sessions.lock().unwrap().remove(session_id);
    }

    /// 检查 session 是否已打开
    pub fn is_session_open(&self, session_id: &str) -> bool {
        self.sessions.lock().unwrap().contains_key(session_id)
    }

    /// 列出所有当前打开的 session_id。
    ///
    /// 用途:App quit 前批量 flush —— 后台 500ms flusher 可能还没 drain
    /// `pending_snapshot_saves`,runtime 就被切断了。需要一条同步路径遍历
    /// 所有打开的 editor 把内存 LoroDoc 一次性落盘。
    pub fn list_open_sessions(&self) -> Vec<String> {
        self.sessions.lock().unwrap().keys().cloned().collect()
    }

    /// 导出当前 LoroDoc 的快照。
    pub fn export_snapshot(&self, session_id: &str) -> Result<Vec<u8>, EditorBridgeError> {
        let sessions = self.sessions.lock().unwrap();
        let session = sessions
            .get(session_id)
            .ok_or(EditorBridgeError::SessionNotOpen)?;
        session
            .doc
            .export(loro::ExportMode::Snapshot)
            .map_err(|e| EditorBridgeError::LoroError(e.to_string()))
    }

    /// 用 Loro snapshot 字节替换当前文档。
    ///
    /// 用于 revert_to_version：把 active editor 的 LoroDoc 重置为快照状态。
    /// 如果 session 已打开，保留原 callback；否则创建新的 OpenSession。
    /// generation 递增以触发回调通知前端。
    ///
    /// 实现约束：
    /// - 锁外完成 LoroDoc::import (重活)
    /// - 锁外完成 try_send (避免在锁内调外部 channel)
    /// - 不重复 export — 直接复用入参 snapshot 字节传给 callback
    pub fn replace_document(
        &self,
        snapshot_owner: &str,
        snapshot: &[u8],
    ) -> Result<(), EditorBridgeError> {
        self.replace_document_inner(snapshot_owner, snapshot, None)
    }

    /// Replaces a document while installing the caller's complete rich-text
    /// style schema before importing the snapshot. Rollback/revert paths that
    /// will accept later Mark operations must use this variant.
    pub fn replace_document_with_styles(
        &self,
        snapshot_owner: &str,
        snapshot: &[u8],
        styles: StyleConfigMap,
    ) -> Result<(), EditorBridgeError> {
        self.replace_document_inner(snapshot_owner, snapshot, Some(styles))
    }

    fn replace_document_inner(
        &self,
        snapshot_owner: &str,
        snapshot: &[u8],
        styles: Option<StyleConfigMap>,
    ) -> Result<(), EditorBridgeError> {
        // 1. 锁外解码 snapshot（重活）
        let new_doc = LoroDoc::new();
        if let Some(styles) = styles {
            new_doc.config_text_style(styles);
        }
        new_doc
            .import(snapshot)
            .map_err(|e| EditorBridgeError::LoroError(e.to_string()))?;
        // 换入的快照可能来自纪元字段引入之前的备份。
        stamp_schema_epoch(&new_doc);

        // 2. 持锁只做 swap + generation++ + clone callback handle
        let (new_generation, callback_for_notify) = {
            let mut sessions = self.sessions.lock().unwrap();
            match sessions.get_mut(snapshot_owner) {
                Some(existing) => {
                    existing.doc = new_doc;
                    existing.generation += 1;
                    (existing.generation, existing.callback.clone())
                }
                None => {
                    sessions.insert(
                        snapshot_owner.to_string(),
                        OpenSession {
                            doc: new_doc,
                            generation: 1,
                            callback: None,
                            refcount: 1,
                        },
                    );
                    (1, None)
                }
            }
        };

        // 3. 锁外通知 callback（用入参 snapshot，不需再 export）
        if let Some(cb) = callback_for_notify {
            let _ = cb.try_send(EditorEvent::Change {
                delta: snapshot.to_vec(),
                generation: new_generation,
            });
        }
        Ok(())
    }
}

impl Default for EditorBridge {
    fn default() -> Self {
        Self::new()
    }
}

#[derive(Debug, thiserror::Error)]
pub enum EditorBridgeError {
    #[error("session not open")]
    SessionNotOpen,

    #[error("Loro error: {0}")]
    LoroError(String),

    #[error("invalid capture anchor: {0}")]
    InvalidCaptureAnchor(String),

    #[error("invalid projection receipt: {0}")]
    InvalidProjectionReceipt(String),

    #[error("invalid durable editor receipt: {0}")]
    InvalidDurableReceipt(String),

    #[error(
        "projection receipt conflict for session {session_id} at fact revision {fact_revision}"
    )]
    ProjectionReceiptConflict {
        session_id: String,
        fact_revision: u64,
    },

    #[error("user mutation receipt conflict for {namespace}/{mutation_id}")]
    UserMutationReceiptConflict {
        namespace: String,
        mutation_id: String,
    },
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    fn load_test_doc() -> LoroDoc {
        let doc = LoroDoc::new();
        let text = doc.get_text("content");
        text.insert(0, "initial content").unwrap();
        doc
    }

    #[tokio::test]
    async fn test_open_and_close() {
        let bridge = EditorBridge::new();

        let handle = bridge.open("test-session", load_test_doc()).unwrap();
        assert!(handle.is_open());

        bridge.close("test-session").unwrap();
        bridge.close("test-session").unwrap(); // idempotent
    }

    #[tokio::test]
    async fn test_apply_edit() {
        let bridge = EditorBridge::new();

        let _handle = bridge.open("test-session", load_test_doc()).unwrap();

        bridge
            .apply(
                "test-session",
                EditOp::Insert {
                    pos: 0,
                    text: "Hello ".to_string(),
                },
            )
            .unwrap();

        let content = bridge.get_content("test-session").unwrap();
        assert!(content.starts_with("Hello "));
    }

    #[tokio::test]
    async fn test_concurrent_edit() {
        let bridge = Arc::new(EditorBridge::new());

        let _handle = bridge.open("test-session", load_test_doc()).unwrap();

        let b1 = bridge.clone();
        let b2 = bridge.clone();

        let (r1, r2) = tokio::join!(
            async move {
                b1.apply(
                    "test-session",
                    EditOp::Insert {
                        pos: 0,
                        text: "AAA".to_string(),
                    },
                )
            },
            async move {
                b2.apply(
                    "test-session",
                    EditOp::Insert {
                        pos: 0,
                        text: "BBB".to_string(),
                    },
                )
            },
        );

        assert!(r1.is_ok());
        assert!(r2.is_ok());

        let content = bridge.get_content("test-session").unwrap();
        assert!(content.contains("AAA"));
        assert!(content.contains("BBB"));
    }

    #[tokio::test]
    async fn test_no_infinite_loop() {
        let bridge = Arc::new(EditorBridge::new());

        let (tx, mut rx) = mpsc::channel::<EditorEvent>(100);

        let _handle = bridge
            .open_with_callback("test-session", load_test_doc(), tx)
            .unwrap();

        bridge
            .apply(
                "test-session",
                EditOp::Insert {
                    pos: 0,
                    text: "test".to_string(),
                },
            )
            .unwrap();

        let event = tokio::time::timeout(tokio::time::Duration::from_millis(100), rx.recv())
            .await
            .unwrap()
            .unwrap();

        match event {
            EditorEvent::Change { generation, .. } => {
                let result = bridge.apply_from_ui(
                    "test-session",
                    EditOp::Insert {
                        pos: 0,
                        text: "loop".to_string(),
                    },
                    generation,
                );
                assert!(result.is_ok());

                // Should NOT trigger another event (same generation = skip)
                let timeout =
                    tokio::time::timeout(tokio::time::Duration::from_millis(50), rx.recv()).await;
                assert!(timeout.is_err(), "should not trigger another event");
            }
        }
    }

    #[tokio::test]
    async fn test_subscribe_events() {
        let bridge = Arc::new(EditorBridge::new());

        let (tx, mut rx) = mpsc::channel::<EditorEvent>(100);

        let _handle = bridge
            .open_with_callback("test-session", load_test_doc(), tx)
            .unwrap();

        bridge
            .apply(
                "test-session",
                EditOp::Insert {
                    pos: 0,
                    text: "hello".to_string(),
                },
            )
            .unwrap();

        let event = rx.recv().await.unwrap();
        match event {
            EditorEvent::Change { delta, .. } => {
                assert!(!delta.is_empty());
            }
        }
    }

    #[tokio::test]
    async fn test_apply_to_closed_session_fails() {
        let bridge = EditorBridge::new();

        let result = bridge.apply(
            "nonexistent",
            EditOp::Insert {
                pos: 0,
                text: "test".to_string(),
            },
        );

        assert!(result.is_err());
    }

    // ===================== replace_document =====================

    fn snapshot_with_text(text: &str) -> Vec<u8> {
        let doc = LoroDoc::new();
        doc.get_text("content").insert(0, text).unwrap();
        doc.export(loro::ExportMode::Snapshot).unwrap()
    }

    #[test]
    fn test_replace_document_into_open_session() {
        let bridge = EditorBridge::new();
        bridge.open("s1", load_test_doc()).unwrap();

        // 起始内容是 "initial content"
        assert_eq!(bridge.get_content("s1").unwrap(), "initial content");

        let v1_snapshot = snapshot_with_text("version 1 text");
        bridge.replace_document("s1", &v1_snapshot).unwrap();

        assert_eq!(bridge.get_content("s1").unwrap(), "version 1 text");
        assert!(bridge.is_session_open("s1"));
    }

    #[test]
    fn test_replace_document_creates_session_if_not_open() {
        let bridge = EditorBridge::new();
        assert!(!bridge.is_session_open("s2"));

        let snapshot = snapshot_with_text("loaded from snapshot");
        bridge.replace_document("s2", &snapshot).unwrap();

        assert!(bridge.is_session_open("s2"));
        assert_eq!(bridge.get_content("s2").unwrap(), "loaded from snapshot");
    }

    #[test]
    fn test_replace_document_invalid_snapshot_returns_error() {
        let bridge = EditorBridge::new();
        bridge.open("s1", load_test_doc()).unwrap();

        let result = bridge.replace_document("s1", b"not a real snapshot");
        assert!(result.is_err());
        // 原文档应该没动
        assert_eq!(bridge.get_content("s1").unwrap(), "initial content");
    }

    #[tokio::test]
    async fn test_replace_document_notifies_callback() {
        let bridge = EditorBridge::new();
        let (tx, mut rx) = mpsc::channel::<EditorEvent>(10);

        bridge
            .open_with_callback("s1", load_test_doc(), tx)
            .unwrap();

        let snapshot = snapshot_with_text("after revert");
        bridge.replace_document("s1", &snapshot).unwrap();

        let event = tokio::time::timeout(tokio::time::Duration::from_millis(200), rx.recv())
            .await
            .unwrap()
            .unwrap();
        match event {
            EditorEvent::Change { delta, generation } => {
                assert!(!delta.is_empty());
                assert!(generation >= 1);
            }
        }
    }

    // ========================== Property tests ==========================
    // 1000 个并发 apply 不能死锁不能丢内容

    #[tokio::test]
    async fn test_1000_concurrent_edits() {
        let bridge = Arc::new(EditorBridge::new());
        bridge.open("stress", load_test_doc()).unwrap();

        let n = 1000usize;
        let mut handles = Vec::with_capacity(n);
        for i in 0..n {
            let b = bridge.clone();
            handles.push(tokio::spawn(async move {
                b.apply(
                    "stress",
                    EditOp::Insert {
                        pos: 0,
                        text: format!("[{i}]"),
                    },
                )
            }));
        }

        for h in handles {
            h.await.unwrap().unwrap();
        }

        let content = bridge.get_content("stress").unwrap();
        // 应当包含初始 "initial content" + 1000 个 [N] 段
        assert!(content.contains("initial content"));
        // 检查所有 1000 个 marker 都出现过
        for i in 0..n {
            let marker = format!("[{i}]");
            assert!(
                content.contains(&marker),
                "marker {marker} 必须出现在最终内容里"
            );
        }
    }

    #[test]
    fn test_replace_document_increments_generation() {
        let bridge = EditorBridge::new();
        bridge.open("s1", load_test_doc()).unwrap();

        let s1 = snapshot_with_text("a");
        let s2 = snapshot_with_text("b");

        bridge.replace_document("s1", &s1).unwrap();
        bridge.replace_document("s1", &s2).unwrap();
        // 不直接暴露 generation，但 apply_from_ui 用 generation 防回环
        // 用一个旧 generation 调用 apply_from_ui 应该忽略；新的会执行
        // 这里只验证两次 replace 都成功并且最终内容是 "b"
        assert_eq!(bridge.get_content("s1").unwrap(), "b");
    }
}

/// 远端更新的准入裁决。
///
/// T2 切换完成后,本机所有转录稿文档都是第 2 纪元块文档,按 kind 规则
/// 手册静态判定。第 1 纪元的 fork+重放守卫(锚点区间探测)已随切换退役;
/// 判不出纪元/种类的文档一律拒收——失败关闭,放行等于这道门不存在。
///
/// 设计见 `docs/architecture/share-p2p.md` 第 4.2 节与
/// `docs/architecture/t2-capture-switchover.md`。
impl EditorBridge {
    /// 第 2 纪元文档的准入裁决。
    ///
    /// - 文档未打开或不是第 2 纪元(kind 缺失) → `None`,调用方按
    ///   失败关闭处理(拒收);
    /// - 第 2 纪元 → `Some(拒收与否)`:按 kind 规则手册静态判定,拒收
    ///   理由记 tracing。
    pub fn epoch2_admission_refuses(&self, document_id: &str, update: &[u8]) -> Option<bool> {
        let sessions = self.sessions.lock().unwrap();
        let session = sessions.get(document_id)?;
        let kind = crate::document_schema::document_kind(&session.doc)?;
        match crate::block_guard::admit_block_update(&session.doc, kind, update) {
            Ok(()) => Some(false),
            Err(denial) => {
                tracing::info!(
                    document_id = %document_id,
                    kind = %kind.as_str(),
                    %denial,
                    "第 2 纪元准入拒收"
                );
                Some(true)
            }
        }
    }
}

/// 文档同步要用到的三件事:我是什么版本、对方缺什么、把这份更新合进来。
///
/// 这些方法故意不做准入判定 —— 那是分享层的事,顺序也必须是「先判后合」。
/// 见 `docs/architecture/share-p2p.md` 第 4.2 节。
impl EditorBridge {
    /// 本机版本,编码成不透明字节交给对端。
    pub fn document_version(&self, document_id: &str) -> Option<Vec<u8>> {
        let sessions = self.sessions.lock().unwrap();
        Some(sessions.get(document_id)?.doc.oplog_vv().encode())
    }

    /// 对方停在 `version` 时缺的那些更新。
    ///
    /// 版本解不开时返回**全部历史**而不是空 —— 宁可多发一次,不能让对方以为自己
    /// 已经追平。
    pub fn updates_since(&self, document_id: &str, version: &[u8]) -> Option<Vec<u8>> {
        let sessions = self.sessions.lock().unwrap();
        let session = sessions.get(document_id)?;
        let from = loro::VersionVector::decode(version).unwrap_or_default();

        // 「有没有要发的」必须按版本判,不能按导出字节是否为空判 ——
        // Loro 的 export 即使无内容也会写出一个头部,那串字节永远不是空的。
        if from.includes_vv(&session.doc.oplog_vv()) {
            return None;
        }
        session.doc.export(loro::ExportMode::updates(&from)).ok()
    }

    /// 一篇打开中的文档声明的结构纪元。未打开返回 `None` —— 同步家族的
    /// 问题只对打开的文档有答案,与 `document_version` 一致;上层把
    /// `None` 按拒收处理。
    pub fn schema_epoch(&self, document_id: &str) -> Option<u64> {
        let sessions = self.sessions.lock().unwrap();
        Some(schema_epoch_of(&sessions.get(document_id)?.doc))
    }

    /// 合入一份**已经通过准入**的远端更新。
    pub fn import_remote_update(&self, document_id: &str, update: &[u8]) -> bool {
        let mut sessions = self.sessions.lock().unwrap();
        let Some(session) = sessions.get_mut(document_id) else {
            return false;
        };
        session.doc.import(update).is_ok()
    }
}

#[cfg(test)]
mod document_sync_tests {
    use super::*;

    fn opened(text: &str) -> EditorBridge {
        let doc = LoroDoc::new();
        doc.get_text("content").insert(0, text).unwrap();
        doc.commit();
        let bridge = EditorBridge::new();
        bridge.open("doc", doc).unwrap();
        bridge
    }

    #[test]
    fn a_peer_at_our_version_needs_nothing() {
        let bridge = opened("已有内容");
        let version = bridge.document_version("doc").unwrap();
        assert!(bridge.updates_since("doc", &version).is_none());
    }

    #[test]
    fn a_peer_at_zero_receives_the_whole_history() {
        let bridge = opened("已有内容");
        let empty = loro::VersionVector::default().encode();
        assert!(bridge.updates_since("doc", &empty).is_some());
    }

    /// 版本解不开时宁可多发,不能让对方以为自己已经追平。
    #[test]
    fn an_undecodable_version_falls_back_to_everything() {
        let bridge = opened("已有内容");
        assert!(bridge.updates_since("doc", b"garbage").is_some());
    }

    /// 补齐历史真的能把两端拉齐。
    #[test]
    fn catch_up_makes_a_fresh_peer_converge() {
        let bridge = opened("主持人写的内容");
        let empty = loro::VersionVector::default().encode();
        let catch_up = bridge.updates_since("doc", &empty).unwrap();

        let peer = EditorBridge::new();
        peer.open("doc", LoroDoc::new()).unwrap();
        assert!(peer.import_remote_update("doc", &catch_up));
        assert_eq!(peer.get_content("doc").unwrap(), "主持人写的内容");

        // 追平之后就没有新东西可要了。
        let peer_version = peer.document_version("doc").unwrap();
        assert!(bridge.updates_since("doc", &peer_version).is_none());
    }

    #[test]
    fn a_corrupt_update_is_refused_without_touching_the_document() {
        let bridge = opened("原文");
        assert!(!bridge.import_remote_update("doc", b"not-a-loro-update"));
        assert_eq!(bridge.get_content("doc").unwrap(), "原文");
    }

    #[test]
    fn an_unopened_document_has_no_version_and_takes_no_update() {
        let bridge = EditorBridge::new();
        assert!(bridge.document_version("missing").is_none());
        assert!(bridge.updates_since("missing", b"").is_none());
        assert!(!bridge.import_remote_update("missing", b"anything"));
    }
}

#[cfg(test)]
mod schema_epoch_tests {
    use super::*;

    /// 打开即盖章:新文档与纪元字段引入前的旧文档,离开 open 时都带上
    /// 当前纪元。
    #[test]
    fn opening_stamps_the_current_epoch() {
        let bridge = EditorBridge::new();
        bridge.open("doc", LoroDoc::new()).unwrap();
        assert_eq!(bridge.schema_epoch("doc"), Some(CURRENT_SCHEMA_EPOCH));
    }

    /// 纪元随快照落盘,重开不再补写 —— 第二次 open 读到的是持久化的值。
    #[test]
    fn the_epoch_survives_a_snapshot_round_trip() {
        let bridge = EditorBridge::new();
        bridge.open("doc", LoroDoc::new()).unwrap();
        let snapshot = bridge.export_snapshot("doc").unwrap();

        let reopened = LoroDoc::new();
        reopened.import(&snapshot).unwrap();
        let vv_before = reopened.oplog_vv();
        let second = EditorBridge::new();
        second.open("doc", reopened).unwrap();
        assert_eq!(second.schema_epoch("doc"), Some(CURRENT_SCHEMA_EPOCH));

        // 已带字段的文档不该再产生一笔盖章 op。
        let sessions = second.sessions.lock().unwrap();
        assert_eq!(sessions.get("doc").unwrap().doc.oplog_vv(), vv_before);
    }

    /// 已声明更高纪元的文档绝不能被降级盖写 —— stamp 只补缺,不覆盖。
    #[test]
    fn a_future_epoch_is_never_stamped_back_down() {
        let doc = LoroDoc::new();
        doc.get_map(DOCUMENT_META)
            .insert(SCHEMA_EPOCH_KEY, (CURRENT_SCHEMA_EPOCH + 1) as i64)
            .unwrap();
        doc.commit();
        let bridge = EditorBridge::new();
        bridge.open("doc", doc).unwrap();
        assert_eq!(bridge.schema_epoch("doc"), Some(CURRENT_SCHEMA_EPOCH + 1));
    }

    /// 换入纪元字段引入前的备份快照,也要在换入时补上字段。
    #[test]
    fn replacing_with_a_pre_epoch_snapshot_stamps_it() {
        let legacy = LoroDoc::new();
        legacy.get_text("content").insert(0, "旧内容").unwrap();
        legacy.commit();
        let snapshot = legacy.export(loro::ExportMode::Snapshot).unwrap();

        let bridge = EditorBridge::new();
        bridge.open("doc", LoroDoc::new()).unwrap();
        bridge.replace_document("doc", &snapshot).unwrap();
        assert_eq!(bridge.schema_epoch("doc"), Some(CURRENT_SCHEMA_EPOCH));
    }

    /// 损坏的纪元值必须在每台机器上读出同一个答案。
    #[test]
    fn a_corrupt_epoch_value_reads_deterministically() {
        let doc = LoroDoc::new();
        doc.get_map(DOCUMENT_META)
            .insert(SCHEMA_EPOCH_KEY, "not-a-number")
            .unwrap();
        doc.commit();
        assert_eq!(schema_epoch_of(&doc), PRE_EPOCH_FIELD);

        let negative = LoroDoc::new();
        negative
            .get_map(DOCUMENT_META)
            .insert(SCHEMA_EPOCH_KEY, -5i64)
            .unwrap();
        negative.commit();
        assert_eq!(schema_epoch_of(&negative), PRE_EPOCH_FIELD);
    }

    #[test]
    fn an_unopened_document_has_no_epoch() {
        assert_eq!(EditorBridge::new().schema_epoch("missing"), None);
    }
}

#[cfg(test)]
mod epoch2_admission_tests {
    use super::*;
    use crate::document_schema::{new_block_document, DocumentKind};
    use crate::transcript_projection::TranscriptProjection;

    /// 建一份带内容的 T2 文档开进 bridge,并造一份远端更新。
    fn t2_with_remote_edit(edit_user_block: bool) -> (EditorBridge, Vec<u8>) {
        let projection =
            TranscriptProjection::open(new_block_document(DocumentKind::Transcript)).unwrap();
        projection
            .machine_upsert_block(
                crate::transcript_projection::MachineBlockWrite {
                    id: "u1".into(),
                    owner: "capture:s1".into(),
                    text: "机器句".into(),
                    lanes: Default::default(),
                },
                &Default::default(),
                None,
            )
            .unwrap();
        projection.insert_annotation(1, "n1", "批注").unwrap();

        let remote = new_block_document(DocumentKind::Transcript);
        remote
            .import(&projection.doc().export(loro::ExportMode::Snapshot).unwrap())
            .unwrap();
        let remote_projection = TranscriptProjection::open(remote).unwrap();
        let base_vv = projection.doc().oplog_vv();
        if edit_user_block {
            remote_projection
                .user_replace_text("n1", "批注(远端)")
                .unwrap();
        } else {
            remote_projection
                .user_replace_text("u1", "篡改机器句")
                .unwrap();
        }
        let update = remote_projection
            .doc()
            .export(loro::ExportMode::updates(&base_vv))
            .unwrap();

        let bridge = EditorBridge::new();
        bridge.open("t2-doc", projection.doc().fork()).unwrap();
        (bridge, update)
    }

    #[test]
    fn epoch2_capture_block_edit_is_refused_by_the_dispatch() {
        let (bridge, update) = t2_with_remote_edit(false);
        assert_eq!(
            bridge.epoch2_admission_refuses("t2-doc", &update),
            Some(true)
        );
    }

    #[test]
    fn epoch2_annotation_edit_is_admitted_by_the_dispatch() {
        let (bridge, update) = t2_with_remote_edit(true);
        assert_eq!(
            bridge.epoch2_admission_refuses("t2-doc", &update),
            Some(false)
        );
    }

    /// 第 1 纪元文档不在本分发的辖区:返回 None,调用方走 fork+重放守卫。
    #[test]
    fn epoch1_documents_are_out_of_jurisdiction() {
        let bridge = EditorBridge::new();
        let legacy = LoroDoc::new();
        legacy.get_text("content").insert(0, "平文本").unwrap();
        legacy.commit();
        bridge.open("legacy", legacy).unwrap();
        assert_eq!(bridge.epoch2_admission_refuses("legacy", b"x"), None);
        assert_eq!(bridge.epoch2_admission_refuses("missing", b"x"), None);
    }
}
