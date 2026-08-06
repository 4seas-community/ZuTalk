//! EditorBridge — Loro 文档编辑管理
//! 权威：D4 §6

use std::collections::HashMap;
use std::sync::Arc;

use loro::{
    cursor::{Cursor, Side},
    event::Diff,
    ContainerID, ContainerTrait, ContainerType, LoroDoc, LoroValue, StyleConfigMap, TextDelta,
};
use serde::{Deserialize, Serialize};
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

/// Durable proof that one finalized SQLite fact revision has been projected
/// into this Loro document.
///
/// The receipt is stored inside the Loro snapshot. A projector must persist
/// the snapshot returned by [`EditorBridge::apply_projection_batch`] before it
/// acknowledges the corresponding SQLite outbox revision.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProjectionReceipt {
    pub session_id: String,
    pub fact_revision: u64,
    pub digest: String,
}

/// Exact-once receipt for an editable user mutation.
///
/// `namespace` separates mutation producers that may otherwise reuse the same
/// opaque `mutation_id`. Unlike projection revisions, mutation receipts do not
/// supersede one another: every `(namespace, mutation_id)` is retained.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UserMutationReceipt {
    pub namespace: String,
    pub mutation_id: String,
    pub digest: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProjectionBatchOutcome {
    /// The operations and receipt were applied by this call.
    Applied,
    /// This revision, or a newer revision for the same session, was already
    /// present. No edit, generation advance, or callback occurred.
    AlreadyApplied,
}

/// The exact snapshot that callers should durably persist before acknowledging
/// the projected SQLite revision.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProjectionBatchResult {
    pub outcome: ProjectionBatchOutcome,
    pub generation: u64,
    pub snapshot: Vec<u8>,
}

/// User mutation batches have the same snapshot/generation result contract as
/// projection batches.
pub type UserMutationBatchResult = ProjectionBatchResult;

#[derive(Debug, Clone, PartialEq, Eq)]
struct DurableReceipt {
    namespace: String,
    id: String,
    sequence: Option<u64>,
    digest: String,
}

#[derive(Debug, Serialize, Deserialize)]
struct StoredDurableReceipt {
    schema_version: u8,
    namespace: String,
    id: String,
    sequence: Option<u64>,
    digest: String,
}

/// Compatibility decoder for projection receipts written by the initial
/// session/revision-specific implementation.
#[derive(Debug, Deserialize)]
struct LegacyStoredProjectionReceipt {
    schema_version: u8,
    session_id: String,
    fact_revision: u64,
    digest: String,
}

#[derive(Debug, Deserialize)]
#[serde(untagged)]
enum StoredReceiptCompatibility {
    Durable(StoredDurableReceipt),
    LegacyProjection(LegacyStoredProjectionReceipt),
}

#[derive(Debug, Clone, Copy)]
enum ReceiptPolicy {
    ProjectionLatestWins,
    UserMutationExactOnce,
}

struct BatchReceiptSpec {
    map_name: &'static str,
    map_key: String,
    receipt: DurableReceipt,
    policy: ReceiptPolicy,
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
const PROJECTION_RECEIPTS: &str = "zulangue_realtime_projection_receipts";
const USER_MUTATION_RECEIPTS: &str = "zulangue_user_mutation_receipts";
const PROJECTION_RECEIPT_NAMESPACE: &str = "realtime_projection";
const DURABLE_RECEIPT_SCHEMA_VERSION: u8 = 1;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum CaptureAnchorWrite {
    Start,
    End,
    Session,
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

fn user_mutation_receipt_key(namespace: &str, mutation_id: &str) -> String {
    // The namespace byte length makes this collision-free even when either
    // component itself contains ':' or arbitrary user-provided text.
    format!("v1:{}:{namespace}{mutation_id}", namespace.len())
}

fn encode_durable_receipt(receipt: &DurableReceipt) -> Result<String, EditorBridgeError> {
    serde_json::to_string(&StoredDurableReceipt {
        schema_version: DURABLE_RECEIPT_SCHEMA_VERSION,
        namespace: receipt.namespace.clone(),
        id: receipt.id.clone(),
        sequence: receipt.sequence,
        digest: receipt.digest.clone(),
    })
    .map_err(|error| EditorBridgeError::InvalidDurableReceipt(error.to_string()))
}

fn get_durable_receipt_from_doc(
    doc: &LoroDoc,
    map_name: &str,
    map_key: &str,
    expected_namespace: &str,
    expected_id: &str,
) -> Result<Option<DurableReceipt>, EditorBridgeError> {
    let Some(value) = doc.get_map(map_name).get(map_key) else {
        return Ok(None);
    };
    let LoroValue::String(encoded) = value.get_deep_value() else {
        return Err(EditorBridgeError::InvalidDurableReceipt(format!(
            "receipt {expected_namespace}/{expected_id} is not a string"
        )));
    };
    let stored: StoredReceiptCompatibility = serde_json::from_str(&encoded).map_err(|error| {
        EditorBridgeError::InvalidDurableReceipt(format!(
            "decode receipt {expected_namespace}/{expected_id}: {error}"
        ))
    })?;
    let (schema_version, stored) = match stored {
        StoredReceiptCompatibility::Durable(stored) => (
            stored.schema_version,
            DurableReceipt {
                namespace: stored.namespace,
                id: stored.id,
                sequence: stored.sequence,
                digest: stored.digest,
            },
        ),
        StoredReceiptCompatibility::LegacyProjection(stored) => {
            if expected_namespace != PROJECTION_RECEIPT_NAMESPACE {
                return Err(EditorBridgeError::InvalidDurableReceipt(format!(
                    "legacy projection receipt found at {expected_namespace}/{expected_id}"
                )));
            }
            (
                stored.schema_version,
                DurableReceipt {
                    namespace: PROJECTION_RECEIPT_NAMESPACE.to_string(),
                    id: stored.session_id,
                    sequence: Some(stored.fact_revision),
                    digest: stored.digest,
                },
            )
        }
    };
    if schema_version != DURABLE_RECEIPT_SCHEMA_VERSION {
        return Err(EditorBridgeError::InvalidDurableReceipt(format!(
            "unsupported receipt schema {schema_version} for {expected_namespace}/{expected_id}"
        )));
    }
    if stored.namespace != expected_namespace || stored.id != expected_id {
        return Err(EditorBridgeError::InvalidDurableReceipt(format!(
            "receipt key/payload mismatch for {expected_namespace}/{expected_id}"
        )));
    }
    Ok(Some(stored))
}

fn get_projection_receipt_from_doc(
    doc: &LoroDoc,
    session_id: &str,
) -> Result<Option<ProjectionReceipt>, EditorBridgeError> {
    let Some(receipt) = get_durable_receipt_from_doc(
        doc,
        PROJECTION_RECEIPTS,
        session_id,
        PROJECTION_RECEIPT_NAMESPACE,
        session_id,
    )?
    else {
        return Ok(None);
    };
    let fact_revision = receipt.sequence.ok_or_else(|| {
        EditorBridgeError::InvalidDurableReceipt(format!(
            "projection receipt has no revision for session {session_id}"
        ))
    })?;
    Ok(Some(ProjectionReceipt {
        session_id: receipt.id,
        fact_revision,
        digest: receipt.digest,
    }))
}

fn get_user_mutation_receipt_from_doc(
    doc: &LoroDoc,
    namespace: &str,
    mutation_id: &str,
) -> Result<Option<UserMutationReceipt>, EditorBridgeError> {
    let Some(receipt) = get_durable_receipt_from_doc(
        doc,
        USER_MUTATION_RECEIPTS,
        &user_mutation_receipt_key(namespace, mutation_id),
        namespace,
        mutation_id,
    )?
    else {
        return Ok(None);
    };
    if receipt.sequence.is_some() {
        return Err(EditorBridgeError::InvalidDurableReceipt(format!(
            "user mutation receipt unexpectedly has a sequence for {namespace}/{mutation_id}"
        )));
    }
    Ok(Some(UserMutationReceipt {
        namespace: receipt.namespace,
        mutation_id: receipt.id,
        digest: receipt.digest,
    }))
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

    /// Atomically applies a finalized machine projection and its durable
    /// receipt under one open-session lock.
    ///
    /// All operations plus the receipt form one Loro auto-commit group. The
    /// bridge advances `generation` once and attempts one callback regardless
    /// of operation count. If any operation, receipt write, or snapshot export
    /// fails, the pre-batch document is restored and neither generation nor the
    /// callback advances.
    ///
    /// Replaying the same revision and digest is a no-op. A lower revision is
    /// also a no-op because a newer receipt subsumes it. Reusing a revision with
    /// a different digest fails closed as nondeterministic projection input.
    pub fn apply_projection_batch(
        &self,
        document_id: &str,
        operations: Vec<EditOp>,
        receipt: ProjectionReceipt,
    ) -> Result<ProjectionBatchResult, EditorBridgeError> {
        if receipt.session_id.is_empty() {
            return Err(EditorBridgeError::InvalidDurableReceipt(
                "session_id must not be empty".to_string(),
            ));
        }
        if receipt.digest.is_empty() {
            return Err(EditorBridgeError::InvalidDurableReceipt(
                "digest must not be empty".to_string(),
            ));
        }
        let session_id = receipt.session_id;
        self.apply_batch_with_receipt(
            document_id,
            operations,
            BatchReceiptSpec {
                map_name: PROJECTION_RECEIPTS,
                map_key: session_id.clone(),
                receipt: DurableReceipt {
                    namespace: PROJECTION_RECEIPT_NAMESPACE.to_string(),
                    id: session_id,
                    sequence: Some(receipt.fact_revision),
                    digest: receipt.digest,
                },
                policy: ReceiptPolicy::ProjectionLatestWins,
            },
        )
    }

    /// Atomically applies one editable user mutation with an exact-once
    /// durable receipt.
    ///
    /// Replaying the same `(namespace, mutation_id, digest)` is a no-op.
    /// Reusing `(namespace, mutation_id)` with a different digest fails closed.
    /// Different mutation IDs never supersede or overwrite one another.
    pub fn apply_user_mutation_batch(
        &self,
        document_id: &str,
        operations: Vec<EditOp>,
        receipt: UserMutationReceipt,
    ) -> Result<UserMutationBatchResult, EditorBridgeError> {
        if receipt.namespace.is_empty() {
            return Err(EditorBridgeError::InvalidDurableReceipt(
                "namespace must not be empty".to_string(),
            ));
        }
        if receipt.mutation_id.is_empty() {
            return Err(EditorBridgeError::InvalidDurableReceipt(
                "mutation_id must not be empty".to_string(),
            ));
        }
        if receipt.digest.is_empty() {
            return Err(EditorBridgeError::InvalidDurableReceipt(
                "digest must not be empty".to_string(),
            ));
        }
        let namespace = receipt.namespace;
        let mutation_id = receipt.mutation_id;
        self.apply_batch_with_receipt(
            document_id,
            operations,
            BatchReceiptSpec {
                map_name: USER_MUTATION_RECEIPTS,
                map_key: user_mutation_receipt_key(&namespace, &mutation_id),
                receipt: DurableReceipt {
                    namespace,
                    id: mutation_id,
                    sequence: None,
                    digest: receipt.digest,
                },
                policy: ReceiptPolicy::UserMutationExactOnce,
            },
        )
    }

    fn apply_batch_with_receipt(
        &self,
        document_id: &str,
        operations: Vec<EditOp>,
        spec: BatchReceiptSpec,
    ) -> Result<ProjectionBatchResult, EditorBridgeError> {
        let stored_receipt = encode_durable_receipt(&spec.receipt)?;

        let mut sessions = self.sessions.lock().unwrap();
        let session = sessions
            .get_mut(document_id)
            .ok_or(EditorBridgeError::SessionNotOpen)?;

        if let Some(existing) = get_durable_receipt_from_doc(
            &session.doc,
            spec.map_name,
            &spec.map_key,
            &spec.receipt.namespace,
            &spec.receipt.id,
        )? {
            let already_applied = match spec.policy {
                ReceiptPolicy::ProjectionLatestWins => {
                    let existing_revision = existing.sequence.ok_or_else(|| {
                        EditorBridgeError::InvalidDurableReceipt(format!(
                            "projection receipt has no revision for session {}",
                            spec.receipt.id
                        ))
                    })?;
                    let requested_revision = spec.receipt.sequence.ok_or_else(|| {
                        EditorBridgeError::InvalidDurableReceipt(format!(
                            "requested projection receipt has no revision for session {}",
                            spec.receipt.id
                        ))
                    })?;
                    if existing_revision == requested_revision
                        && existing.digest != spec.receipt.digest
                    {
                        return Err(EditorBridgeError::ProjectionReceiptConflict {
                            session_id: spec.receipt.id,
                            fact_revision: requested_revision,
                        });
                    }
                    existing_revision >= requested_revision
                }
                ReceiptPolicy::UserMutationExactOnce => {
                    if existing.sequence.is_some() {
                        return Err(EditorBridgeError::InvalidDurableReceipt(format!(
                            "user mutation receipt unexpectedly has a sequence for {}/{}",
                            spec.receipt.namespace, spec.receipt.id
                        )));
                    }
                    if existing.digest != spec.receipt.digest {
                        return Err(EditorBridgeError::UserMutationReceiptConflict {
                            namespace: spec.receipt.namespace,
                            mutation_id: spec.receipt.id,
                        });
                    }
                    true
                }
            };
            if already_applied {
                let snapshot = session
                    .doc
                    .export(loro::ExportMode::Snapshot)
                    .map_err(|error| EditorBridgeError::LoroError(error.to_string()))?;
                return Ok(ProjectionBatchResult {
                    outcome: ProjectionBatchOutcome::AlreadyApplied,
                    generation: session.generation,
                    snapshot,
                });
            }
        }

        // Loro transactions group history/events but do not roll back. Keep an
        // isolated pre-batch copy so a later failing operation cannot leak a
        // partially projected lane to readers.
        let rollback_doc = session.doc.fork();
        let batch_result = (|| {
            for operation in &operations {
                apply_edit_op(&session.doc, operation)?;
            }
            session
                .doc
                .get_map(spec.map_name)
                .insert(&spec.map_key, stored_receipt)
                .map_err(|error| EditorBridgeError::LoroError(error.to_string()))?;
            session
                .doc
                .export(loro::ExportMode::Snapshot)
                .map_err(|error| EditorBridgeError::LoroError(error.to_string()))
        })();
        let snapshot = match batch_result {
            Ok(snapshot) => snapshot,
            Err(error) => {
                session.doc = rollback_doc;
                return Err(error);
            }
        };

        session.generation += 1;
        if let Some(callback) = &session.callback {
            let _ = callback.try_send(EditorEvent::Change {
                delta: snapshot.clone(),
                generation: session.generation,
            });
        }

        Ok(ProjectionBatchResult {
            outcome: ProjectionBatchOutcome::Applied,
            generation: session.generation,
            snapshot,
        })
    }

    /// Returns the latest durable projection receipt stored for a capture
    /// session in this open Loro document.
    pub fn get_projection_receipt(
        &self,
        document_id: &str,
        session_id: &str,
    ) -> Result<Option<ProjectionReceipt>, EditorBridgeError> {
        let sessions = self.sessions.lock().unwrap();
        let session = sessions
            .get(document_id)
            .ok_or(EditorBridgeError::SessionNotOpen)?;
        get_projection_receipt_from_doc(&session.doc, session_id)
    }

    /// Exact receipt check for the common crash-replay path. Call
    /// [`Self::get_projection_receipt`] when a newer revision may subsume the
    /// revision awaiting SQLite acknowledgement.
    pub fn has_projection_receipt(
        &self,
        document_id: &str,
        receipt: &ProjectionReceipt,
    ) -> Result<bool, EditorBridgeError> {
        Ok(self
            .get_projection_receipt(document_id, &receipt.session_id)?
            .as_ref()
            == Some(receipt))
    }

    pub fn get_user_mutation_receipt(
        &self,
        document_id: &str,
        namespace: &str,
        mutation_id: &str,
    ) -> Result<Option<UserMutationReceipt>, EditorBridgeError> {
        let sessions = self.sessions.lock().unwrap();
        let session = sessions
            .get(document_id)
            .ok_or(EditorBridgeError::SessionNotOpen)?;
        get_user_mutation_receipt_from_doc(&session.doc, namespace, mutation_id)
    }

    pub fn has_user_mutation_receipt(
        &self,
        document_id: &str,
        receipt: &UserMutationReceipt,
    ) -> Result<bool, EditorBridgeError> {
        Ok(self
            .get_user_mutation_receipt(document_id, &receipt.namespace, &receipt.mutation_id)?
            .as_ref()
            == Some(receipt))
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
        self.set_capture_owned_range_with_before_write(
            document_id,
            owner_key,
            capture_session_id,
            start,
            end,
            |_| Ok(()),
        )
    }

    fn set_capture_owned_range_with_before_write<F>(
        &self,
        document_id: &str,
        owner_key: &str,
        capture_session_id: &str,
        start: usize,
        end: usize,
        mut before_write: F,
    ) -> Result<(), EditorBridgeError>
    where
        F: FnMut(CaptureAnchorWrite) -> Result<(), EditorBridgeError>,
    {
        let mut sessions = self.sessions.lock().unwrap();
        let session = sessions
            .get_mut(document_id)
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

        // Loro auto-commit groups history but does not roll back a partially
        // failed sequence. Preserve the entire pre-call document so the three
        // anchor maps are exposed either together or not at all.
        let rollback_doc = session.doc.fork();
        let result = (|| {
            before_write(CaptureAnchorWrite::Start)?;
            session
                .doc
                .get_map(CAPTURE_ANCHOR_STARTS)
                .insert(owner_key, LoroValue::Binary(start_cursor.encode().into()))
                .map_err(|error| EditorBridgeError::LoroError(error.to_string()))?;

            before_write(CaptureAnchorWrite::End)?;
            session
                .doc
                .get_map(CAPTURE_ANCHOR_ENDS)
                .insert(owner_key, LoroValue::Binary(end_cursor.encode().into()))
                .map_err(|error| EditorBridgeError::LoroError(error.to_string()))?;

            before_write(CaptureAnchorWrite::Session)?;
            session
                .doc
                .get_map(CAPTURE_ANCHOR_SESSIONS)
                .insert(owner_key, capture_session_id)
                .map_err(|error| EditorBridgeError::LoroError(error.to_string()))
        })();
        if let Err(error) = result {
            session.doc = rollback_doc;
            return Err(error);
        }
        Ok(())
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

    fn projection_receipt(fact_revision: u64, digest: &str) -> ProjectionReceipt {
        ProjectionReceipt {
            session_id: "capture-session".to_string(),
            fact_revision,
            digest: digest.to_string(),
        }
    }

    fn user_mutation_receipt(mutation_id: &str, digest: &str) -> UserMutationReceipt {
        UserMutationReceipt {
            namespace: "user_edit".to_string(),
            mutation_id: mutation_id.to_string(),
            digest: digest.to_string(),
        }
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
    async fn projection_batch_applies_all_operations_and_receipt_once() {
        let bridge = EditorBridge::new();
        let (tx, mut rx) = mpsc::channel::<EditorEvent>(10);
        bridge
            .open_with_callback("document", load_test_doc(), tx)
            .unwrap();
        let receipt = projection_receipt(7, "sha256:final-seven");

        let result = bridge
            .apply_projection_batch(
                "document",
                vec![
                    EditOp::Replace {
                        pos: 0,
                        len: "initial".chars().count(),
                        text: "batched".to_string(),
                    },
                    EditOp::Insert {
                        pos: "batched".chars().count(),
                        text: " final".to_string(),
                    },
                ],
                receipt.clone(),
            )
            .unwrap();

        assert_eq!(result.outcome, ProjectionBatchOutcome::Applied);
        assert_eq!(result.generation, 1);
        assert_eq!(
            bridge.get_content("document").unwrap(),
            "batched final content"
        );
        assert_eq!(
            bridge
                .get_projection_receipt("document", "capture-session")
                .unwrap(),
            Some(receipt.clone())
        );
        assert!(bridge.has_projection_receipt("document", &receipt).unwrap());

        let event = rx.recv().await.unwrap();
        match event {
            EditorEvent::Change { delta, generation } => {
                assert_eq!(generation, 1);
                assert_eq!(delta, result.snapshot);
            }
        }
        assert!(
            tokio::time::timeout(tokio::time::Duration::from_millis(50), rx.recv())
                .await
                .is_err(),
            "one batch must emit only one callback"
        );

        // The receipt travels with the returned Loro snapshot, so a restarted
        // projector can acknowledge SQLite without replaying text operations.
        let reopened_doc = LoroDoc::new();
        reopened_doc.import(&result.snapshot).unwrap();
        let reopened = EditorBridge::new();
        reopened.open("document", reopened_doc).unwrap();
        assert_eq!(
            reopened
                .get_projection_receipt("document", "capture-session")
                .unwrap(),
            Some(receipt)
        );
        assert_eq!(
            reopened.get_content("document").unwrap(),
            "batched final content"
        );
    }

    #[tokio::test]
    async fn projection_batch_replay_is_idempotent_and_conflicts_fail_closed() {
        let bridge = EditorBridge::new();
        let (tx, mut rx) = mpsc::channel::<EditorEvent>(10);
        bridge
            .open_with_callback("document", load_test_doc(), tx)
            .unwrap();
        let receipt = projection_receipt(7, "sha256:stable");
        let operations = vec![EditOp::Insert {
            pos: 0,
            text: "once ".to_string(),
        }];

        let first = bridge
            .apply_projection_batch("document", operations.clone(), receipt.clone())
            .unwrap();
        assert_eq!(first.outcome, ProjectionBatchOutcome::Applied);
        let _ = rx.recv().await.unwrap();

        let replay = bridge
            .apply_projection_batch("document", operations, receipt.clone())
            .unwrap();
        assert_eq!(replay.outcome, ProjectionBatchOutcome::AlreadyApplied);
        assert_eq!(replay.generation, first.generation);
        assert_eq!(
            bridge.get_content("document").unwrap(),
            "once initial content"
        );

        let stale = bridge
            .apply_projection_batch(
                "document",
                vec![EditOp::Insert {
                    pos: 0,
                    text: "stale ".to_string(),
                }],
                projection_receipt(6, "sha256:older"),
            )
            .unwrap();
        assert_eq!(stale.outcome, ProjectionBatchOutcome::AlreadyApplied);
        assert_eq!(stale.generation, first.generation);
        assert_eq!(
            bridge.get_content("document").unwrap(),
            "once initial content"
        );

        let conflict = bridge.apply_projection_batch(
            "document",
            vec![EditOp::Insert {
                pos: 0,
                text: "conflict ".to_string(),
            }],
            projection_receipt(7, "sha256:different"),
        );
        assert!(matches!(
            conflict,
            Err(EditorBridgeError::ProjectionReceiptConflict {
                fact_revision: 7,
                ..
            })
        ));
        assert_eq!(
            bridge.get_content("document").unwrap(),
            "once initial content"
        );
        assert!(
            tokio::time::timeout(tokio::time::Duration::from_millis(50), rx.recv())
                .await
                .is_err(),
            "replay, stale input, and receipt conflict must not notify"
        );
    }

    #[tokio::test]
    async fn projection_batch_rolls_back_partial_operations_on_error() {
        let bridge = EditorBridge::new();
        let (tx, mut rx) = mpsc::channel::<EditorEvent>(10);
        bridge
            .open_with_callback("document", load_test_doc(), tx)
            .unwrap();

        let result = bridge.apply_projection_batch(
            "document",
            vec![
                EditOp::Insert {
                    pos: 0,
                    text: "must roll back ".to_string(),
                },
                EditOp::Delete { pos: 999, len: 1 },
            ],
            projection_receipt(1, "sha256:failed"),
        );

        assert!(matches!(result, Err(EditorBridgeError::LoroError(_))));
        assert_eq!(bridge.get_content("document").unwrap(), "initial content");
        assert_eq!(
            bridge
                .get_projection_receipt("document", "capture-session")
                .unwrap(),
            None
        );
        assert!(
            tokio::time::timeout(tokio::time::Duration::from_millis(50), rx.recv())
                .await
                .is_err(),
            "failed batch must not notify"
        );

        bridge
            .apply(
                "document",
                EditOp::Insert {
                    pos: 0,
                    text: "next ".to_string(),
                },
            )
            .unwrap();
        match rx.recv().await.unwrap() {
            EditorEvent::Change { generation, .. } => assert_eq!(generation, 1),
        }
    }

    #[tokio::test]
    async fn user_mutation_receipts_are_exact_once_and_do_not_overwrite_each_other() {
        let bridge = EditorBridge::new();
        let (tx, mut rx) = mpsc::channel::<EditorEvent>(10);
        bridge
            .open_with_callback("document", load_test_doc(), tx)
            .unwrap();
        let first_receipt = user_mutation_receipt("mutation-1", "sha256:first");
        let first_operations = vec![EditOp::Insert {
            pos: 0,
            text: "one ".to_string(),
        }];

        let first = bridge
            .apply_user_mutation_batch("document", first_operations.clone(), first_receipt.clone())
            .unwrap();
        assert_eq!(first.outcome, ProjectionBatchOutcome::Applied);
        assert_eq!(first.generation, 1);
        let _ = rx.recv().await.unwrap();

        let replay = bridge
            .apply_user_mutation_batch("document", first_operations, first_receipt.clone())
            .unwrap();
        assert_eq!(replay.outcome, ProjectionBatchOutcome::AlreadyApplied);
        assert_eq!(replay.generation, 1);
        assert_eq!(
            bridge.get_content("document").unwrap(),
            "one initial content"
        );

        let conflict = bridge.apply_user_mutation_batch(
            "document",
            vec![EditOp::Insert {
                pos: 0,
                text: "conflict ".to_string(),
            }],
            user_mutation_receipt("mutation-1", "sha256:different"),
        );
        assert!(matches!(
            conflict,
            Err(EditorBridgeError::UserMutationReceiptConflict {
                ref namespace,
                ref mutation_id,
            }) if namespace == "user_edit" && mutation_id == "mutation-1"
        ));
        assert_eq!(
            bridge.get_content("document").unwrap(),
            "one initial content"
        );

        let second_receipt = user_mutation_receipt("mutation-2", "sha256:second");
        let second = bridge
            .apply_user_mutation_batch(
                "document",
                vec![EditOp::Insert {
                    pos: 0,
                    text: "two ".to_string(),
                }],
                second_receipt.clone(),
            )
            .unwrap();
        assert_eq!(second.outcome, ProjectionBatchOutcome::Applied);
        assert_eq!(second.generation, 2);
        match rx.recv().await.unwrap() {
            EditorEvent::Change { generation, .. } => assert_eq!(generation, 2),
        }
        assert_eq!(
            bridge.get_content("document").unwrap(),
            "two one initial content"
        );
        assert!(bridge
            .has_user_mutation_receipt("document", &first_receipt)
            .unwrap());
        assert!(bridge
            .has_user_mutation_receipt("document", &second_receipt)
            .unwrap());
        assert_eq!(
            bridge
                .get_user_mutation_receipt("document", "user_edit", "mutation-1")
                .unwrap(),
            Some(first_receipt.clone())
        );
        assert_eq!(
            bridge
                .get_user_mutation_receipt("document", "user_edit", "mutation-2")
                .unwrap(),
            Some(second_receipt.clone())
        );
        assert!(
            tokio::time::timeout(tokio::time::Duration::from_millis(50), rx.recv())
                .await
                .is_err(),
            "replay and digest conflict must not emit callbacks"
        );

        let reopened_doc = LoroDoc::new();
        reopened_doc.import(&second.snapshot).unwrap();
        let reopened = EditorBridge::new();
        reopened.open("document", reopened_doc).unwrap();
        assert!(reopened
            .has_user_mutation_receipt("document", &first_receipt)
            .unwrap());
        assert!(reopened
            .has_user_mutation_receipt("document", &second_receipt)
            .unwrap());
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
    fn capture_anchor_second_write_failure_leaves_no_partial_metadata() {
        let bridge = EditorBridge::new();
        let doc = LoroDoc::new();
        let mut styles = StyleConfigMap::new();
        styles.insert(
            "session_id".into(),
            loro::StyleConfig {
                expand: loro::ExpandType::None,
            },
        );
        doc.config_text_style(styles);
        doc.get_text("content").insert(0, "capture").unwrap();
        bridge.open("doc", doc).unwrap();
        bridge
            .apply(
                "doc",
                EditOp::Mark {
                    pos: 0,
                    len: 7,
                    key: "session_id".into(),
                    value_json: "\"session-a\"".into(),
                },
            )
            .unwrap();
        let fallback_delta = bridge.get_delta("doc").unwrap();

        let result = bridge.set_capture_owned_range_with_before_write(
            "doc",
            "section",
            "session-a",
            0,
            7,
            |write| {
                if write == CaptureAnchorWrite::End {
                    Err(EditorBridgeError::LoroError(
                        "injected second anchor write failure".into(),
                    ))
                } else {
                    Ok(())
                }
            },
        );

        assert!(matches!(result, Err(EditorBridgeError::LoroError(_))));
        assert_eq!(
            bridge
                .resolve_capture_owned_range("doc", "section", "session-a")
                .unwrap(),
            None
        );

        // A later flusher must not be able to persist the successful first
        // write. After export/import the mark-based fallback is unchanged and
        // no partial anchor can make resolution fail closed.
        let snapshot = bridge.export_snapshot("doc").unwrap();
        let reopened_doc = LoroDoc::new();
        reopened_doc.import(&snapshot).unwrap();
        assert!(reopened_doc.get_map(CAPTURE_ANCHOR_STARTS).is_empty());
        assert!(reopened_doc.get_map(CAPTURE_ANCHOR_ENDS).is_empty());
        assert!(reopened_doc.get_map(CAPTURE_ANCHOR_SESSIONS).is_empty());
        let reopened = EditorBridge::new();
        reopened.open("doc", reopened_doc).unwrap();
        assert_eq!(
            reopened
                .resolve_capture_owned_range("doc", "section", "session-a")
                .unwrap(),
            None
        );
        assert_eq!(reopened.get_delta("doc").unwrap(), fallback_delta);
    }

    #[test]
    fn capture_anchor_second_write_failure_restores_existing_anchor() {
        let bridge = EditorBridge::new();
        let doc = LoroDoc::new();
        doc.get_text("content")
            .insert(0, "prefix capture suffix")
            .unwrap();
        bridge.open("doc", doc).unwrap();
        bridge
            .set_capture_owned_range("doc", "section", "session-a", 7, 14)
            .unwrap();
        let original = bridge
            .resolve_capture_owned_range("doc", "section", "session-a")
            .unwrap();

        let result = bridge.set_capture_owned_range_with_before_write(
            "doc",
            "section",
            "session-a",
            0,
            6,
            |write| {
                if write == CaptureAnchorWrite::End {
                    Err(EditorBridgeError::LoroError(
                        "injected second anchor write failure".into(),
                    ))
                } else {
                    Ok(())
                }
            },
        );

        assert!(matches!(result, Err(EditorBridgeError::LoroError(_))));
        assert_eq!(
            bridge
                .resolve_capture_owned_range("doc", "section", "session-a")
                .unwrap(),
            original
        );

        let snapshot = bridge.export_snapshot("doc").unwrap();
        let reopened_doc = LoroDoc::new();
        reopened_doc.import(&snapshot).unwrap();
        let reopened = EditorBridge::new();
        reopened.open("doc", reopened_doc).unwrap();
        assert_eq!(
            reopened
                .resolve_capture_owned_range("doc", "section", "session-a")
                .unwrap(),
            original
        );
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

/// 采集拥有区间的探测:一份远端更新是否碰了不属于它的东西。
///
/// CRDT 的前提是所有副本平权、最终收敛,它不认「这段归采集投影所有」。所以在
/// 合入之前必须先问一遍。判定需要真的把更新应用一次才知道它动了哪里,因此这一步
/// 跑在 fork 出来的副本上,真实文档不受影响。
///
/// 设计见 `docs/architecture/share-p2p.md` 第 4.2 节。
impl EditorBridge {
    /// 列出文档里所有采集拥有的区间,按当前文本下标返回 `[start, end)`。
    ///
    /// 与 `resolve_capture_owned_range` 不同,这里不校验 owner 的 session 归属 ——
    /// 准入判定关心的是「这段有没有主」,不是「归哪一次采集」。
    fn capture_owned_spans(doc: &LoroDoc) -> Vec<(usize, usize)> {
        let starts = doc.get_map(CAPTURE_ANCHOR_STARTS);
        let ends = doc.get_map(CAPTURE_ANCHOR_ENDS);
        let document_len = doc.get_text("content").len_unicode();

        let resolve = |value: Option<loro::ValueOrContainer>, is_start: bool| -> Option<usize> {
            let bytes = value.and_then(|value| match value.get_deep_value() {
                LoroValue::Binary(value) => Some(value),
                _ => None,
            })?;
            let cursor = Cursor::decode(&bytes).ok()?;
            let pos = doc.get_cursor_pos(&cursor).ok()?.current.pos;
            Some(if is_start {
                pos.saturating_add(usize::from(
                    cursor.id.is_some() && cursor.side == Side::Right,
                ))
            } else {
                pos
            })
        };

        let mut spans = Vec::new();
        for owner_key in starts.keys() {
            let Some(start) = resolve(starts.get(&owner_key), true) else {
                continue;
            };
            let Some(end) = resolve(ends.get(&owner_key), false) else {
                // 半个锚点是坏数据。失败关闭:当作整篇都被保护,而不是当作没保护。
                return vec![(0, document_len)];
            };
            if end >= start {
                spans.push((start, end));
            }
        }
        spans
    }

    /// 一份远端 Loro 更新是否触碰了采集投影拥有的区间。
    ///
    /// 返回 `true` 表示必须拒收。任何无法判定的情况也返回 `true` —— 判不出来时
    /// 放行,等于这道门不存在。
    pub fn remote_update_touches_capture_owned_range(
        &self,
        document_id: &str,
        update: &[u8],
    ) -> bool {
        let sessions = self.sessions.lock().unwrap();
        let Some(session) = sessions.get(document_id) else {
            // 文档没开就没有可保护的投影,也没有可合入的目标。
            return false;
        };

        // 在副本上试应用。真实文档不受这次探测影响。
        let probe = session.doc.fork();
        let owned = Self::capture_owned_spans(&probe);
        let before = probe.state_frontiers();
        if probe.import(update).is_err() {
            // 连导入都失败的更新不该进入真实文档。
            return true;
        }
        let after = probe.state_frontiers();
        let Ok(batch) = probe.diff(&before, &after) else {
            return true;
        };

        for (container, diff) in batch.iter() {
            let ContainerID::Root {
                name,
                container_type,
            } = container
            else {
                continue;
            };

            // 远端不得改写锚点本身。允许它就等于允许对方先挪开边界再改内容。
            if matches!(
                name.as_str(),
                CAPTURE_ANCHOR_STARTS
                    | CAPTURE_ANCHOR_ENDS
                    | CAPTURE_ANCHOR_SESSIONS
                    | PROJECTION_RECEIPTS
                    | USER_MUTATION_RECEIPTS
            ) {
                return true;
            }

            if name.as_str() != "content" || *container_type != ContainerType::Text {
                continue;
            }
            let Diff::Text(deltas) = diff else { continue };

            // Quill 语义:Retain / Delete 在**旧文档**上前进,Insert 不前进。
            // 采集区间也是旧文档的下标,两者同一坐标系。
            let mut cursor = 0usize;
            for delta in deltas {
                match delta {
                    TextDelta::Retain { retain, .. } => cursor += retain,
                    TextDelta::Delete { delete } => {
                        let touched = (cursor, cursor + delete);
                        if owned.iter().any(|span| spans_overlap(*span, touched)) {
                            return true;
                        }
                        cursor += delete;
                    }
                    TextDelta::Insert { .. } => {
                        // 严格落在区间内部才算触碰。恰好在 start 或 end 上是紧邻,
                        // 不是修改被保护的内容 —— 否则用户永远无法在转录稿后面接着写。
                        if owned.iter().any(|(s, e)| *s < cursor && cursor < *e) {
                            return true;
                        }
                    }
                }
            }
        }
        false
    }
}

/// 两个半开区间是否相交。空区间不与任何东西相交。
fn spans_overlap(a: (usize, usize), b: (usize, usize)) -> bool {
    a.0 < b.1 && b.0 < a.1
}

#[cfg(test)]
mod capture_boundary_probe_tests {
    use super::*;

    /// 建一份带采集拥有区间的文档,返回 bridge 与一个可以独立编辑的远端副本。
    ///
    /// 远端副本从同一份快照 fork 而来,所以它产生的更新是真正可合入的 —— 这些
    /// 测试走的是真实的 Loro 更新字节,不是构造出来的假数据。
    fn bridge_with_owned_range(text: &str, start: usize, end: usize) -> (EditorBridge, LoroDoc) {
        let doc = LoroDoc::new();
        doc.get_text("content").insert(0, text).unwrap();
        doc.commit();

        let bridge = EditorBridge::new();
        bridge.open("doc", doc).unwrap();
        bridge
            .set_capture_owned_range("doc", "owner", "session-a", start, end)
            .unwrap();

        // 远端从当前状态分叉,之后各自编辑。
        let snapshot = bridge.export_snapshot("doc").unwrap();
        let remote = LoroDoc::new();
        remote.import(&snapshot).unwrap();
        (bridge, remote)
    }

    /// 远端产生一份只含自己改动的更新。
    fn update_from(remote: &LoroDoc, edit: impl FnOnce(&LoroDoc)) -> Vec<u8> {
        let before = remote.oplog_vv();
        edit(remote);
        remote.commit();
        remote.export(loro::ExportMode::updates(&before)).unwrap()
    }

    #[test]
    fn edit_outside_the_owned_range_is_allowed() {
        // "0123456789",采集拥有 [2, 6)。改动落在尾部。
        let (bridge, remote) = bridge_with_owned_range("0123456789", 2, 6);
        let update = update_from(&remote, |doc| {
            doc.get_text("content").insert(9, "尾巴").unwrap();
        });
        assert!(!bridge.remote_update_touches_capture_owned_range("doc", &update));
    }

    #[test]
    fn insert_strictly_inside_the_owned_range_is_refused() {
        let (bridge, remote) = bridge_with_owned_range("0123456789", 2, 6);
        let update = update_from(&remote, |doc| {
            doc.get_text("content").insert(4, "插进来").unwrap();
        });
        assert!(bridge.remote_update_touches_capture_owned_range("doc", &update));
    }

    /// 恰好贴在区间末尾之后接着写,是允许的 —— 否则用户永远无法在转录稿后面续写。
    #[test]
    fn insert_at_the_boundary_is_allowed() {
        let (bridge, remote) = bridge_with_owned_range("0123456789", 2, 6);
        let update = update_from(&remote, |doc| {
            doc.get_text("content").insert(6, "紧接着").unwrap();
        });
        assert!(!bridge.remote_update_touches_capture_owned_range("doc", &update));
    }

    #[test]
    fn delete_overlapping_the_owned_range_is_refused() {
        let (bridge, remote) = bridge_with_owned_range("0123456789", 2, 6);
        let update = update_from(&remote, |doc| {
            // 删 [5, 8) —— 只有前一半压在采集区间上,依然要拒。
            doc.get_text("content").delete(5, 3).unwrap();
        });
        assert!(bridge.remote_update_touches_capture_owned_range("doc", &update));
    }

    #[test]
    fn delete_entirely_outside_is_allowed() {
        let (bridge, remote) = bridge_with_owned_range("0123456789", 2, 6);
        let update = update_from(&remote, |doc| {
            doc.get_text("content").delete(7, 2).unwrap();
        });
        assert!(!bridge.remote_update_touches_capture_owned_range("doc", &update));
    }

    /// 远端不得改写锚点本身 —— 允许它就等于允许对方先挪开边界再改内容。
    #[test]
    fn rewriting_the_anchors_themselves_is_refused() {
        let (bridge, remote) = bridge_with_owned_range("0123456789", 2, 6);
        let update = update_from(&remote, |doc| {
            doc.get_map(CAPTURE_ANCHOR_STARTS)
                .insert("owner", LoroValue::Binary(vec![0u8; 4].into()))
                .unwrap();
        });
        assert!(bridge.remote_update_touches_capture_owned_range("doc", &update));
    }

    /// 判不出来时必须拒收。放行等于这道门不存在。
    #[test]
    fn undecodable_update_is_refused() {
        let (bridge, _remote) = bridge_with_owned_range("0123456789", 2, 6);
        assert!(bridge.remote_update_touches_capture_owned_range("doc", b"not-a-loro-update"));
    }

    /// 探测跑在副本上,真实文档不能被它改变。
    #[test]
    fn probing_never_mutates_the_live_document() {
        let (bridge, remote) = bridge_with_owned_range("0123456789", 2, 6);
        let before = bridge.get_content("doc").unwrap();
        let update = update_from(&remote, |doc| {
            doc.get_text("content").insert(4, "偷偷改").unwrap();
        });
        assert!(bridge.remote_update_touches_capture_owned_range("doc", &update));
        assert_eq!(bridge.get_content("doc").unwrap(), before);

        // 被允许的更新同样不该在探测阶段就生效。
        let allowed = update_from(&remote, |doc| {
            doc.get_text("content").insert(0, "").unwrap();
        });
        bridge.remote_update_touches_capture_owned_range("doc", &allowed);
        assert_eq!(bridge.get_content("doc").unwrap(), before);
    }

    /// 没有采集区间的文档,任何改动都不该被这道门拦下。
    #[test]
    fn document_without_capture_anchors_allows_everything() {
        let doc = LoroDoc::new();
        doc.get_text("content").insert(0, "自由编辑").unwrap();
        doc.commit();
        let bridge = EditorBridge::new();
        bridge.open("free", doc).unwrap();

        let snapshot = bridge.export_snapshot("free").unwrap();
        let remote = LoroDoc::new();
        remote.import(&snapshot).unwrap();
        let update = update_from(&remote, |doc| {
            doc.get_text("content").insert(2, "随便插").unwrap();
        });
        assert!(!bridge.remote_update_touches_capture_owned_range("free", &update));
    }

    /// 文档没打开时没有可保护的东西,也没有可合入的目标。
    #[test]
    fn unopened_document_is_not_guarded() {
        let bridge = EditorBridge::new();
        assert!(!bridge.remote_update_touches_capture_owned_range("missing", b"anything"));
    }
}
