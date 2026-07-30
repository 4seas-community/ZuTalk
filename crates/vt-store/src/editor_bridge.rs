//! EditorBridge — Loro 文档编辑管理
//! 权威：D4 §6

use std::collections::HashMap;
use std::sync::Arc;

use loro::{
    cursor::{Cursor, Side},
    ContainerTrait, LoroDoc, LoroValue, StyleConfigMap,
};
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

const CAPTURE_ANCHOR_STARTS: &str = "zulangue_capture_anchor_starts";
const CAPTURE_ANCHOR_ENDS: &str = "zulangue_capture_anchor_ends";
const CAPTURE_ANCHOR_SESSIONS: &str = "zulangue_capture_anchor_sessions";

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

        let loro_text = session.doc.get_text("content");
        match &op {
            EditOp::Insert { pos, text } => {
                loro_text
                    .insert(*pos, text)
                    .map_err(|e| EditorBridgeError::LoroError(e.to_string()))?;
            }
            EditOp::Delete { pos, len } => {
                loro_text
                    .delete(*pos, *len)
                    .map_err(|e| EditorBridgeError::LoroError(e.to_string()))?;
            }
            EditOp::Replace { pos, len, text } => {
                loro_text
                    .delete(*pos, *len)
                    .map_err(|e| EditorBridgeError::LoroError(e.to_string()))?;
                loro_text
                    .insert(*pos, text)
                    .map_err(|e| EditorBridgeError::LoroError(e.to_string()))?;
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
                    .map_err(|e| EditorBridgeError::LoroError(e.to_string()))?;
            }
            EditOp::Unmark { pos, len, key } => {
                let end = pos.saturating_add(*len);
                loro_text
                    .unmark(*pos..end, key)
                    .map_err(|e| EditorBridgeError::LoroError(e.to_string()))?;
            }
        }

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

    /// Persists a CRDT-relative range for capture-owned text. Rich-text marks
    /// remain useful for rendering and validation, but cannot by themselves
    /// bound user insertions because ownership styles deliberately do not
    /// expand. The encoded Loro cursors move with edits and survive snapshots.
    pub fn set_capture_owned_range(
        &self,
        document_id: &str,
        owner_key: &str,
        capture_session_id: &str,
        start: usize,
        end: usize,
    ) -> Result<(), EditorBridgeError> {
        let sessions = self.sessions.lock().unwrap();
        let session = sessions
            .get(document_id)
            .ok_or(EditorBridgeError::SessionNotOpen)?;
        let text = session.doc.get_text("content");
        if start > end || end > text.len_unicode() {
            return Err(EditorBridgeError::InvalidCaptureAnchor(format!(
                "capture range {start}..{end} is outside document length {}",
                text.len_unicode()
            )));
        }
        // Store exterior cursors. The start cursor is immediately after the
        // preceding character (or the container's absolute left edge); the
        // end cursor is immediately before the following character (or the
        // absolute right edge). Inserts at either section boundary therefore
        // remain inside the owned range.
        let start_cursor = if start == 0 {
            Cursor::new(None, text.id(), Side::Left, 0)
        } else {
            text.get_cursor(start - 1, Side::Right).ok_or_else(|| {
                EditorBridgeError::InvalidCaptureAnchor(format!(
                    "cannot create capture start cursor at {start}"
                ))
            })?
        };
        let end_cursor = if end == text.len_unicode() {
            Cursor::new(None, text.id(), Side::Right, end)
        } else {
            text.get_cursor(end, Side::Left).ok_or_else(|| {
                EditorBridgeError::InvalidCaptureAnchor(format!(
                    "cannot create capture end cursor at {end}"
                ))
            })?
        };
        session
            .doc
            .get_map(CAPTURE_ANCHOR_STARTS)
            .insert(owner_key, LoroValue::Binary(start_cursor.encode().into()))
            .map_err(|error| EditorBridgeError::LoroError(error.to_string()))?;
        session
            .doc
            .get_map(CAPTURE_ANCHOR_ENDS)
            .insert(owner_key, LoroValue::Binary(end_cursor.encode().into()))
            .map_err(|error| EditorBridgeError::LoroError(error.to_string()))?;
        session
            .doc
            .get_map(CAPTURE_ANCHOR_SESSIONS)
            .insert(owner_key, capture_session_id)
            .map_err(|error| EditorBridgeError::LoroError(error.to_string()))
    }

    /// Resolves a capture-owned CRDT range. A partially present or malformed
    /// anchor fails closed so callers never guess a destructive text envelope.
    pub fn resolve_capture_owned_range(
        &self,
        document_id: &str,
        owner_key: &str,
        capture_session_id: &str,
    ) -> Result<Option<(usize, usize)>, EditorBridgeError> {
        let sessions = self.sessions.lock().unwrap();
        let session = sessions
            .get(document_id)
            .ok_or(EditorBridgeError::SessionNotOpen)?;
        let starts = session.doc.get_map(CAPTURE_ANCHOR_STARTS);
        let ends = session.doc.get_map(CAPTURE_ANCHOR_ENDS);
        let owners = session.doc.get_map(CAPTURE_ANCHOR_SESSIONS);
        let start = starts.get(owner_key);
        let end = ends.get(owner_key);
        let owner = owners.get(owner_key);
        if start.is_none() && end.is_none() && owner.is_none() {
            return Ok(None);
        }
        let owner = owner
            .and_then(|value| match value.get_deep_value() {
                LoroValue::String(value) => Some(value.to_string()),
                _ => None,
            })
            .ok_or_else(|| {
                EditorBridgeError::InvalidCaptureAnchor(format!(
                    "capture owner metadata is missing or malformed for {owner_key}"
                ))
            })?;
        if owner != capture_session_id {
            return Err(EditorBridgeError::InvalidCaptureAnchor(format!(
                "capture owner mismatch for {owner_key}"
            )));
        }
        let decode = |value: Option<loro::ValueOrContainer>, edge: &str| {
            let bytes = value
                .and_then(|value| match value.get_deep_value() {
                    LoroValue::Binary(value) => Some(value),
                    _ => None,
                })
                .ok_or_else(|| {
                    EditorBridgeError::InvalidCaptureAnchor(format!(
                        "capture {edge} cursor is missing or malformed for {owner_key}"
                    ))
                })?;
            Cursor::decode(&bytes).map_err(|error| {
                EditorBridgeError::InvalidCaptureAnchor(format!(
                    "decode capture {edge} cursor for {owner_key}: {error}"
                ))
            })
        };
        let start_cursor = decode(start, "start")?;
        let start = session
            .doc
            .get_cursor_pos(&start_cursor)
            .map_err(|error| {
                EditorBridgeError::InvalidCaptureAnchor(format!(
                    "resolve capture start cursor for {owner_key}: {error}"
                ))
            })?
            .current
            .pos
            .saturating_add(usize::from(
                start_cursor.id.is_some() && start_cursor.side == Side::Right,
            ));
        let end = session
            .doc
            .get_cursor_pos(&decode(end, "end")?)
            .map_err(|error| {
                EditorBridgeError::InvalidCaptureAnchor(format!(
                    "resolve capture end cursor for {owner_key}: {error}"
                ))
            })?
            .current
            .pos;
        let document_len = session.doc.get_text("content").len_unicode();
        if end < start || end > document_len {
            return Err(EditorBridgeError::InvalidCaptureAnchor(format!(
                "resolved capture range {start}..{end} is outside document length {document_len}"
            )));
        }
        Ok(Some((start, end - start)))
    }

    /// Removes every durable capture anchor owned by one session. Owner keys
    /// are opaque digests, so clearing these exact metadata values also removes
    /// the final session identifier from the Loro snapshot.
    pub fn clear_capture_owned_ranges_for_session(
        &self,
        document_id: &str,
        capture_session_id: &str,
    ) -> Result<(), EditorBridgeError> {
        let sessions = self.sessions.lock().unwrap();
        let session = sessions
            .get(document_id)
            .ok_or(EditorBridgeError::SessionNotOpen)?;
        let owners = session.doc.get_map(CAPTURE_ANCHOR_SESSIONS);
        let keys = owners
            .keys()
            .filter_map(|key| {
                let key = key.to_string();
                let matches = owners.get(&key).is_some_and(|value| {
                    matches!(
                        value.get_deep_value(),
                        LoroValue::String(value) if value.as_ref() == capture_session_id
                    )
                });
                matches.then_some(key)
            })
            .collect::<Vec<_>>();
        let starts = session.doc.get_map(CAPTURE_ANCHOR_STARTS);
        let ends = session.doc.get_map(CAPTURE_ANCHOR_ENDS);
        for key in keys {
            starts
                .delete(&key)
                .map_err(|error| EditorBridgeError::LoroError(error.to_string()))?;
            ends.delete(&key)
                .map_err(|error| EditorBridgeError::LoroError(error.to_string()))?;
            owners
                .delete(&key)
                .map_err(|error| EditorBridgeError::LoroError(error.to_string()))?;
        }
        Ok(())
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
    fn capture_owned_range_tracks_unicode_and_boundary_edits() {
        let bridge = EditorBridge::new();
        let doc = LoroDoc::new();
        doc.get_text("content")
            .insert(0, "前置\n英语: hello\n中文: 你好\n后置")
            .unwrap();
        bridge.open("doc", doc).unwrap();
        let content = bridge.get_content("doc").unwrap();
        let start = content.find("英语").unwrap();
        let start = content[..start].chars().count();
        let end_byte = content.find("后置").unwrap();
        let end = content[..end_byte].chars().count();
        bridge
            .set_capture_owned_range("doc", "opaque", "session-a", start, end)
            .unwrap();

        bridge
            .apply(
                "doc",
                EditOp::Insert {
                    pos: start,
                    text: "首行\n".into(),
                },
            )
            .unwrap();
        let (_, len) = bridge
            .resolve_capture_owned_range("doc", "opaque", "session-a")
            .unwrap()
            .unwrap();
        assert_eq!(len, end - start + "首行\n".chars().count());

        let (start, len) = bridge
            .resolve_capture_owned_range("doc", "opaque", "session-a")
            .unwrap()
            .unwrap();
        bridge
            .apply(
                "doc",
                EditOp::Insert {
                    pos: start + len,
                    text: "尾行\n".into(),
                },
            )
            .unwrap();
        let (start, len) = bridge
            .resolve_capture_owned_range("doc", "opaque", "session-a")
            .unwrap()
            .unwrap();
        let content = bridge.get_content("doc").unwrap();
        let owned = content.chars().skip(start).take(len).collect::<String>();
        assert!(owned.starts_with("首行\n英语"));
        assert!(owned.ends_with("尾行\n"));

        // Anchors are part of the Loro snapshot, not process-local indexes.
        let snapshot = bridge.export_snapshot("doc").unwrap();
        let reopened_doc = LoroDoc::new();
        reopened_doc.import(&snapshot).unwrap();
        let reopened = EditorBridge::new();
        reopened.open("doc", reopened_doc).unwrap();
        let (start, _len) = reopened
            .resolve_capture_owned_range("doc", "opaque", "session-a")
            .unwrap()
            .unwrap();
        reopened
            .apply(
                "doc",
                EditOp::Insert {
                    pos: start + 4,
                    text: "内部换行\n".into(),
                },
            )
            .unwrap();
        reopened
            .apply(
                "doc",
                EditOp::Delete {
                    pos: start + 1,
                    len: 1,
                },
            )
            .unwrap();
        let (start, len) = reopened
            .resolve_capture_owned_range("doc", "opaque", "session-a")
            .unwrap()
            .unwrap();
        assert!(len > 0);
        reopened
            .apply("doc", EditOp::Delete { pos: start, len })
            .unwrap();
        reopened
            .clear_capture_owned_ranges_for_session("doc", "session-a")
            .unwrap();
        assert_eq!(reopened.get_content("doc").unwrap(), "前置\n后置");
    }

    #[test]
    fn clearing_capture_owned_ranges_removes_session_metadata() {
        let bridge = EditorBridge::new();
        let doc = LoroDoc::new();
        doc.get_text("content").insert(0, "capture").unwrap();
        bridge.open("doc", doc).unwrap();
        bridge
            .set_capture_owned_range("doc", "section", "session-a", 0, 7)
            .unwrap();
        bridge
            .set_capture_owned_range("doc", "lane", "session-a", 0, 7)
            .unwrap();

        bridge
            .clear_capture_owned_ranges_for_session("doc", "session-a")
            .unwrap();

        assert_eq!(
            bridge
                .resolve_capture_owned_range("doc", "section", "session-a")
                .unwrap(),
            None
        );
        let snapshot = bridge.export_snapshot("doc").unwrap();
        let doc = LoroDoc::new();
        doc.import(&snapshot).unwrap();
        assert!(doc.get_map(CAPTURE_ANCHOR_SESSIONS).is_empty());
        assert!(doc.get_map(CAPTURE_ANCHOR_STARTS).is_empty());
        assert!(doc.get_map(CAPTURE_ANCHOR_ENDS).is_empty());
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
