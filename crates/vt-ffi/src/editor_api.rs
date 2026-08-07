//! 编辑器 FFI API
//! 权威:D5 §7.5
//!
//! 富文本:Mark/Unmark 通过 key + JSON-encoded value 传递。
//! 客户端用 JSON 序列化属性值("true" / "1" / "\"#ff0000\""),
//! 服务端解析成 LoroValue(json_to_loro_value)。
//!
//! Delta 返回 Quill Delta 格式 JSON(供 NSAttributedString ↔ Loro mapping)。
//!
//! 持久化:每次 apply 成功后自动把 LoroDoc snapshot 存到
//! `{data_dir}/editor-docs/{session_id}.loro`,open_editor 时先尝试加载。
//! 让富文本笔记跨 App 重启存活。

use std::collections::HashMap;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};

use loro::{ExpandType, StyleConfig, StyleConfigMap};
use vt_store::{
    AsyncTaskState, BuiltinNotebookTab, EditOp, EditorBridge, NotebookTabRecord, ProjectionState,
};

use crate::{CoreError, ZulangueCore};

/// 文档变更回调（Rust → Swift push）。
///
/// 任何成功的 apply_edit 后 Rust 会查表找到注册了该 doc_id 的 callback,
/// 触发 on_doc_changed。Swift 侧在 LoroTextBridge 注册这个回调,
/// 收到通知后调 refreshFromDelta 把 NSTextView 同步成最新状态。
///
/// 典型场景:
///   · 确定性 transcript projection 往 transcript doc 写入 — Swift UI 实时看到增长
///   · Swift 自己的编辑也会触发此回调 — 幂等刷新,suppressLoroSync
///     保证不会产生反馈循环
#[uniffi::export(callback_interface)]
pub trait FfiEditorCallback: Send + Sync {
    /// doc 内容发生变化(插入/删除/mark/unmark/replace 等)
    ///
    /// generation 单调递增,Swift 可用来对齐"上次同步到的版本"。
    fn on_doc_changed(&self, doc_id: String, generation: u64);
}

/// Zulangue 的 mark schema — 每个 key 对应的 expand 行为。
/// Loro 强制要求 rich-text mark key 在 apply 前注册,否则返回
/// "Style configuration missing" 错误。
///
/// 规则:
///   - bold / italic / code / strikethrough → After
///     (选中后 bold,紧接着打字应该继续 bold — 符合直觉)
///   - heading → None
///     (H1 后回车另起一段,新段不应该继承 heading)
///   - list → None
///     (列表项是段落级别,不向外扩展)
pub(crate) fn voice_tool_style_config() -> StyleConfigMap {
    let mut map = StyleConfigMap::new();
    map.insert(
        "bold".into(),
        StyleConfig {
            expand: ExpandType::After,
        },
    );
    map.insert(
        "italic".into(),
        StyleConfig {
            expand: ExpandType::After,
        },
    );
    map.insert(
        "code".into(),
        StyleConfig {
            expand: ExpandType::After,
        },
    );
    map.insert(
        "strikethrough".into(),
        StyleConfig {
            expand: ExpandType::After,
        },
    );
    // heading / list 应保持段落级语义。
    // Swift 侧现在会根据 typingAttributes 把同段继续输入的新字符显式补 mark,
    // 所以这里可以回到 ExpandType::None,避免回车后的新段意外继承 heading/list。
    map.insert(
        "heading".into(),
        StyleConfig {
            expand: ExpandType::None,
        },
    );
    map.insert(
        "list".into(),
        StyleConfig {
            expand: ExpandType::None,
        },
    );
    // Loro-backed transcript 用的两个 segment 级 mark:
    //   - segment_id:数字, 同段内相邻 run 靠它合并
    //   - timestamp_ms: u64 毫秒, 段首时间戳
    // expand=After:AI 持续往段末追加 token 时,新 char 应继承当前段属性。
    // 用户在段内插字也是同一段。只有"新 utterance 起始"时 Swift 侧
    // 才手动 Insert 一个 `\n\n` + 换 segment_id(无 mark 的 \n 分隔符)。
    map.insert(
        "segment_id".into(),
        StyleConfig {
            expand: ExpandType::After,
        },
    );
    map.insert(
        "timestamp_ms".into(),
        StyleConfig {
            expand: ExpandType::After,
        },
    );
    // Ownership marks must never expand into adjacent user-authored text.
    // Projection code explicitly marks every owned range after insert/replace.
    for key in [
        "session_id",
        "utterance_id",
        "lane_language",
        "source_timestamp_ms",
        "utterance_revision",
        "content_owner",
    ] {
        map.insert(
            key.into(),
            StyleConfig {
                expand: ExpandType::None,
            },
        );
    }
    map
}

static SNAPSHOT_TEMP_COUNTER: AtomicU64 = AtomicU64::new(0);
static SNAPSHOT_FLUSH_LOCK: Mutex<()> = Mutex::new(());
static EDITOR_DOCUMENT_MUTATION_LOCK: Mutex<()> = Mutex::new(());

/// Serializes user edits, deterministic projections, purge mutations and
/// snapshot flushes. This prevents a rollback snapshot from overwriting a
/// concurrent Manual Note edit or a flusher from persisting a saga midpoint.
pub(crate) fn editor_document_mutation_guard() -> MutexGuard<'static, ()> {
    EDITOR_DOCUMENT_MUTATION_LOCK.lock().unwrap()
}

#[cfg(test)]
type SnapshotFlushTestHook = Arc<dyn Fn(&str) + Send + Sync>;

#[cfg(test)]
static SNAPSHOT_FLUSH_TEST_HOOK: Mutex<Option<SnapshotFlushTestHook>> = Mutex::new(None);

/// 返回 snapshot 文件路径:`{data_dir}/editor-docs/{session_id}.loro`
pub(crate) fn snapshot_path(data_dir: &std::path::Path, session_id: &str) -> PathBuf {
    data_dir
        .join("editor-docs")
        .join(format!("{session_id}.loro"))
}

fn snapshot_temp_path(data_dir: &std::path::Path, session_id: &str) -> PathBuf {
    let sequence = SNAPSHOT_TEMP_COUNTER.fetch_add(1, Ordering::Relaxed);
    snapshot_path(data_dir, session_id).with_extension(format!(
        "loro.tmp.{}.{}",
        std::process::id(),
        sequence
    ))
}

#[cfg(test)]
fn set_snapshot_flush_test_hook(hook: Option<SnapshotFlushTestHook>) {
    *SNAPSHOT_FLUSH_TEST_HOOK.lock().unwrap() = hook;
}

#[cfg(test)]
fn run_snapshot_flush_test_hook(session_id: &str) {
    let hook = SNAPSHOT_FLUSH_TEST_HOOK.lock().unwrap().clone();
    if let Some(hook) = hook {
        hook(session_id);
    }
}

#[cfg(not(test))]
fn run_snapshot_flush_test_hook(_session_id: &str) {}

/// 确保 `{data_dir}/editor-docs/` 存在
fn ensure_snapshot_dir(data_dir: &std::path::Path) -> std::io::Result<()> {
    let dir = data_dir.join("editor-docs");
    if dir.exists() && !dir.is_dir() {
        return Err(std::io::Error::new(
            std::io::ErrorKind::AlreadyExists,
            format!(
                "snapshot path {} exists but is not a directory",
                dir.display()
            ),
        ));
    }
    if !dir.exists() {
        fs::create_dir_all(&dir)?;
    }
    Ok(())
}

/// 把单个 session 的当前 LoroDoc 快照同步写到磁盘。
///
/// 被两条路径调用:
///   · 后台 flusher task(500ms 合并 drain,不阻塞 FFI 主线程)
///   · close_editor(final flush,保证关闭前一定落盘)
pub(crate) fn flush_snapshot_to_disk_result(
    data_dir: &Path,
    bridge: &EditorBridge,
    session_id: &str,
) -> Result<(), String> {
    let temp_path = snapshot_temp_path(data_dir, session_id);
    flush_snapshot_to_disk_result_with_temp_path(data_dir, bridge, session_id, temp_path)
}

fn flush_snapshot_to_disk_result_with_temp_path(
    data_dir: &Path,
    bridge: &EditorBridge,
    session_id: &str,
    temp_path: PathBuf,
) -> Result<(), String> {
    let _flush_guard = SNAPSHOT_FLUSH_LOCK
        .lock()
        .map_err(|_| "snapshot flush lock poisoned".to_string())?;
    let bytes = bridge
        .export_snapshot(session_id)
        .map_err(|e| format!("export_snapshot failed for {session_id}: {e}"))?;
    persist_snapshot_bytes_unlocked(data_dir, session_id, &bytes, temp_path)
}

fn persist_snapshot_bytes_unlocked(
    data_dir: &Path,
    session_id: &str,
    bytes: &[u8],
    temp_path: PathBuf,
) -> Result<(), String> {
    ensure_snapshot_dir(data_dir).map_err(|e| format!("mkdir snapshot dir failed: {e}"))?;
    let path = snapshot_path(data_dir, session_id);
    {
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temp_path)
            .map_err(|e| format!("snapshot temp write failed for {session_id}: {e}"))?;
        file.write_all(bytes)
            .map_err(|e| format!("snapshot temp write failed for {session_id}: {e}"))?;
        file.sync_all()
            .map_err(|e| format!("snapshot temp sync failed for {session_id}: {e}"))?;
    }
    run_snapshot_flush_test_hook(session_id);
    fs::rename(&temp_path, &path).map_err(|e| {
        let _ = fs::remove_file(&temp_path);
        format!("snapshot rename failed for {session_id}: {e}")
    })?;
    let parent = path
        .parent()
        .ok_or_else(|| format!("snapshot path has no parent for {session_id}"))?;
    let dir = fs::File::open(parent)
        .map_err(|e| format!("snapshot directory open failed for {session_id}: {e}"))?;
    dir.sync_all()
        .map_err(|e| format!("snapshot directory sync failed for {session_id}: {e}"))?;
    Ok(())
}

/// Best-effort wrapper for non-terminal background flush paths.
pub(crate) fn flush_snapshot_to_disk(data_dir: &Path, bridge: &EditorBridge, session_id: &str) {
    if let Err(error) = flush_snapshot_to_disk_result(data_dir, bridge, session_id) {
        eprintln!("[editor_api] {error}");
    }
}

pub(crate) fn open_editor_session(
    data_dir: &Path,
    bridge: &EditorBridge,
    session_id: &str,
) -> Result<(), CoreError> {
    open_editor_session_strict(data_dir, bridge, session_id)
}

/// Strict variant for privacy-sensitive destructive operations. A corrupt or
/// unreadable snapshot must keep the durable purge job pending; silently
/// substituting an empty document would orphan the original user content.
pub(crate) fn open_editor_session_strict(
    data_dir: &Path,
    bridge: &EditorBridge,
    session_id: &str,
) -> Result<(), CoreError> {
    tracing::info!(target: "editor_trace", session_id = %session_id, "open_editor");
    let doc = loro::LoroDoc::new();
    doc.config_text_style(voice_tool_style_config());
    let path = snapshot_path(data_dir, session_id);
    if path.exists() {
        let bytes = fs::read(&path).map_err(|error| CoreError::InternalError {
            message: format!("read Loro snapshot {}: {error}", path.display()),
        })?;
        doc.import(&bytes)
            .map_err(|error| CoreError::InternalError {
                message: format!("import Loro snapshot {}: {error}", path.display()),
            })?;
    }
    // Validate the authoritative on-disk snapshot even when a permissive UI
    // open already created an in-memory session. Privacy-sensitive writers must
    // never overwrite corrupt durable bytes with that substituted document.
    if bridge.is_session_open(session_id) {
        return Ok(());
    }
    bridge
        .open(session_id, doc)
        .map_err(|error| CoreError::InternalError {
            message: error.to_string(),
        })?;
    Ok(())
}

/// Opens one product editor owner after validating the authoritative snapshot.
/// Unlike the internal ensure-open helper, every successful call retains one
/// owner and therefore requires one matching `close_editor`.
fn open_editor_session_strict_retained(
    data_dir: &Path,
    bridge: &EditorBridge,
    session_id: &str,
) -> Result<(), CoreError> {
    tracing::info!(target: "editor_trace", session_id = %session_id, "open_editor retained");
    let doc = loro::LoroDoc::new();
    doc.config_text_style(voice_tool_style_config());
    let path = snapshot_path(data_dir, session_id);
    if path.exists() {
        let bytes = fs::read(&path).map_err(|error| CoreError::InternalError {
            message: format!("read Loro snapshot {}: {error}", path.display()),
        })?;
        doc.import(&bytes)
            .map_err(|error| CoreError::InternalError {
                message: format!("import Loro snapshot {}: {error}", path.display()),
            })?;
    }
    bridge
        .open(session_id, doc)
        .map_err(|error| CoreError::InternalError {
            message: error.to_string(),
        })?;
    Ok(())
}

fn notebook_store_error(error: vt_store::NotebookStoreError) -> CoreError {
    match error {
        vt_store::NotebookStoreError::NotFound(message) => CoreError::NotFound { message },
        vt_store::NotebookStoreError::Validation(message) => {
            CoreError::ValidationFailed { message }
        }
        other => CoreError::InternalError {
            message: other.to_string(),
        },
    }
}

impl ZulangueCore {
    pub(crate) fn resolve_product_editor_tab(
        &self,
        notebook_id: &str,
        tab_id: &str,
    ) -> Result<NotebookTabRecord, CoreError> {
        self.notebook_store
            .resolve_builtin_tab(notebook_id, tab_id)
            .map_err(notebook_store_error)
    }

    /// Transcript documents are immutable while any corresponding capture or
    /// post-stop projection is incomplete. Manual Note is the only document
    /// that is writable before a capture exists.
    fn product_editor_is_writable(
        &self,
        notebook_id: &str,
        tab: &NotebookTabRecord,
    ) -> Result<bool, CoreError> {
        if tab.builtin_kind == BuiltinNotebookTab::ManualNote {
            return Ok(true);
        }

        let links = self
            .notebook_store
            .list_linked_sessions(notebook_id)
            .map_err(notebook_store_error)?;
        let mut runs = Vec::new();
        for link in links {
            if let Some(run) = self
                .notebook_capture_store
                .get_run_for_session(&link.session_id)
                .map_err(|error| CoreError::InternalError {
                    message: error.to_string(),
                })?
            {
                runs.push(run);
            }
        }

        let writable = match tab.builtin_kind {
            BuiltinNotebookTab::ManualNote => true,
            BuiltinNotebookTab::RealtimeTranscript => {
                !runs.is_empty()
                    && runs.iter().all(|run| {
                        !run.capture_state.is_active()
                            && run.projection_state == ProjectionState::Ready
                    })
            }
            BuiltinNotebookTab::AsyncTranscript => {
                let async_runs = runs
                    .iter()
                    .filter(|run| run.async_task_state != AsyncTaskState::None)
                    .collect::<Vec<_>>();
                if async_runs.is_empty() {
                    false
                } else {
                    let projected_sessions = self
                        .notebook_store
                        .list_session_projections(&tab.id)
                        .map_err(notebook_store_error)?
                        .into_iter()
                        .map(|projection| projection.session_id)
                        .collect::<std::collections::HashSet<_>>();
                    async_runs.iter().all(|run| {
                        run.async_task_state == AsyncTaskState::Completed
                            && projected_sessions.contains(&run.session_id)
                    })
                }
            }
        };

        Ok(writable)
    }

    fn ensure_product_editor_writable(
        &self,
        notebook_id: &str,
        tab: &NotebookTabRecord,
    ) -> Result<(), CoreError> {
        if self.product_editor_is_writable(notebook_id, tab)? {
            return Ok(());
        }
        Err(CoreError::ValidationFailed {
            message: format!(
                "builtin transcript tab {} is read-only until its projection is ready",
                tab.builtin_kind.as_str()
            ),
        })
    }
}

pub(crate) fn notify_editor_callback(
    editor_callbacks: &Arc<Mutex<HashMap<String, Arc<dyn FfiEditorCallback>>>>,
    session_id: &str,
) {
    let cb_opt = {
        let map = editor_callbacks.lock().unwrap();
        map.get(session_id).cloned()
    };
    if let Some(cb) = cb_opt {
        cb.on_doc_changed(session_id.to_string(), 0);
    }
}

/// FFI 编辑操作
#[derive(Debug, Clone, uniffi::Enum)]
pub enum FfiEditOp {
    Insert {
        pos: u64,
        text: String,
    },
    Delete {
        pos: u64,
        len: u64,
    },
    Replace {
        pos: u64,
        len: u64,
        text: String,
    },
    /// 富文本标记:在 [pos, pos+len) 范围加 key=value 的属性
    /// value_json 是 JSON 序列化的属性值("true" / "1" / "\"#ff0000\"")
    Mark {
        pos: u64,
        len: u64,
        key: String,
        value_json: String,
    },
    /// 移除 [pos, pos+len) 范围上的 key 属性
    Unmark {
        pos: u64,
        len: u64,
        key: String,
    },
}

#[derive(Debug, Clone, Copy)]
pub(crate) struct DeltaMarkSelector<'a> {
    pub session_id: Option<&'a str>,
    pub utterance_id: Option<&'a str>,
    pub lane_language: Option<&'a str>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct TextRange {
    pub pos: usize,
    pub len: usize,
}

/// Finds only contiguous text ranges whose ownership marks match every
/// selector field. Malformed ownership data fails closed instead of guessing
/// a broad envelope that could delete user-authored text.
pub(crate) fn find_marked_ranges(
    delta_json: &str,
    selector: DeltaMarkSelector<'_>,
) -> Result<Vec<TextRange>, CoreError> {
    if selector.session_id.is_none()
        && selector.utterance_id.is_none()
        && selector.lane_language.is_none()
    {
        return Err(CoreError::ValidationFailed {
            message: "at least one ownership mark selector is required".to_string(),
        });
    }
    let value: serde_json::Value =
        serde_json::from_str(delta_json).map_err(|error| CoreError::ValidationFailed {
            message: format!("invalid editor Delta JSON: {error}"),
        })?;
    let segments = value
        .as_array()
        .ok_or_else(|| CoreError::ValidationFailed {
            message: "editor Delta must be an array".to_string(),
        })?;
    let mut cursor = 0_usize;
    let mut ranges: Vec<TextRange> = Vec::new();
    for segment in segments {
        let text = segment
            .get("insert")
            .and_then(serde_json::Value::as_str)
            .ok_or_else(|| CoreError::ValidationFailed {
                message: "editor Delta text insert must be a string".to_string(),
            })?;
        let len = text.chars().count();
        let attributes = match segment.get("attributes") {
            None | Some(serde_json::Value::Null) => None,
            Some(value) => Some(
                value
                    .as_object()
                    .ok_or_else(|| CoreError::ValidationFailed {
                        message: "editor Delta attributes must be an object".to_string(),
                    })?,
            ),
        };
        let mut matches = true;
        for (key, expected) in [
            ("session_id", selector.session_id),
            ("utterance_id", selector.utterance_id),
            ("lane_language", selector.lane_language),
        ] {
            let Some(expected) = expected else {
                continue;
            };
            match attributes.and_then(|attrs| attrs.get(key)) {
                None => matches = false,
                Some(value) => {
                    let actual = value.as_str().ok_or_else(|| CoreError::ValidationFailed {
                        message: format!("editor ownership attribute {key} must be a string"),
                    })?;
                    matches &= actual == expected;
                }
            }
        }
        if matches && len > 0 {
            if let Some(previous) = ranges
                .last_mut()
                .filter(|range| range.pos + range.len == cursor)
            {
                previous.len += len;
            } else {
                ranges.push(TextRange { pos: cursor, len });
            }
        }
        cursor = cursor.saturating_add(len);
    }
    Ok(ranges)
}

pub(crate) fn find_unique_marked_range(
    delta_json: &str,
    selector: DeltaMarkSelector<'_>,
) -> Result<Option<TextRange>, CoreError> {
    let mut ranges = find_marked_ranges(delta_json, selector)?;
    match ranges.len() {
        0 => Ok(None),
        1 => Ok(ranges.pop()),
        count => Err(CoreError::ValidationFailed {
            message: format!("ownership marks are split across {count} disjoint ranges"),
        }),
    }
}

impl From<FfiEditOp> for EditOp {
    fn from(op: FfiEditOp) -> Self {
        match op {
            FfiEditOp::Insert { pos, text } => EditOp::Insert {
                pos: pos as usize,
                text,
            },
            FfiEditOp::Delete { pos, len } => EditOp::Delete {
                pos: pos as usize,
                len: len as usize,
            },
            FfiEditOp::Replace { pos, len, text } => EditOp::Replace {
                pos: pos as usize,
                len: len as usize,
                text,
            },
            FfiEditOp::Mark {
                pos,
                len,
                key,
                value_json,
            } => EditOp::Mark {
                pos: pos as usize,
                len: len as usize,
                key,
                value_json,
            },
            FfiEditOp::Unmark { pos, len, key } => EditOp::Unmark {
                pos: pos as usize,
                len: len as usize,
                key,
            },
        }
    }
}

#[uniffi::export]
impl ZulangueCore {
    /// Open one of the Notebook's exact three builtin documents. Callers never
    /// choose a Loro `doc_id`; Rust resolves it from the Notebook/tab identity.
    pub fn open_editor(&self, notebook_id: String, tab_id: String) -> Result<(), CoreError> {
        let tab = self.resolve_product_editor_tab(&notebook_id, &tab_id)?;
        open_editor_session_strict_retained(&self.data_dir, &self.editor_bridge, &tab.doc_id)
    }

    /// Returns the Rust-owned editability decision used by the UI. Mutation is
    /// still re-checked atomically at `apply_edit`; this method is presentation
    /// state, not an authorization token.
    pub fn is_editor_writable(
        &self,
        notebook_id: String,
        tab_id: String,
    ) -> Result<bool, CoreError> {
        let tab = self.resolve_product_editor_tab(&notebook_id, &tab_id)?;
        self.product_editor_is_writable(&notebook_id, &tab)
    }

    /// 应用用户编辑。apply 成功后:
    ///   1. 把 snapshot 存到磁盘(跨进程持久)
    ///   2. 查找注册的 FfiEditorCallback，通知 Swift 文档已变化。
    pub fn apply_edit(
        &self,
        notebook_id: String,
        tab_id: String,
        op: FfiEditOp,
    ) -> Result<(), CoreError> {
        let tab = self.resolve_product_editor_tab(&notebook_id, &tab_id)?;
        self.ensure_product_editor_writable(&notebook_id, &tab)?;
        let session_id = tab.doc_id;
        let _mutation_guard = editor_document_mutation_guard();
        let op_tag = match &op {
            FfiEditOp::Insert { pos, text } => format!("Insert@{pos} +{}ch", text.chars().count()),
            FfiEditOp::Delete { pos, len } => format!("Delete@{pos} -{len}ch"),
            FfiEditOp::Replace { pos, len, text } => {
                format!("Replace@{pos} -{len} +{}ch", text.chars().count())
            }
            FfiEditOp::Mark { pos, len, key, .. } => format!("Mark@{pos}+{len} {key}"),
            FfiEditOp::Unmark { pos, len, key } => format!("Unmark@{pos}+{len} {key}"),
        };
        tracing::info!(target: "editor_trace", session_id = %session_id, op = %op_tag, "apply_edit IN");

        self.editor_bridge
            .apply(&session_id, op.into())
            .map_err(|e| {
                tracing::warn!(target: "editor_trace", session_id = %session_id, error = %e, "apply_edit FAIL");
                CoreError::InternalError {
                    message: e.to_string(),
                }
            })?;
        tracing::info!(target: "editor_trace", session_id = %session_id, "apply_edit OK");

        // 只 enqueue,后台 flusher 500ms 合并写盘 — 避免每次按键都 fs::write 阻塞主线程。
        self.enqueue_snapshot_save(&session_id);
        // NSTextView and the rebuildable Notebook transcript projection observe
        // the same document callback. Consumers suppress their own edit echo.
        self.notify_editor_changed(&session_id);

        Ok(())
    }
}

#[uniffi::export]
impl ZulangueCore {
    /// Register a callback for a resolved builtin document.
    pub fn register_editor_callback(
        &self,
        notebook_id: String,
        tab_id: String,
        callback: Box<dyn FfiEditorCallback>,
    ) -> Result<(), CoreError> {
        let doc_id = self
            .resolve_product_editor_tab(&notebook_id, &tab_id)?
            .doc_id;
        let cb: Arc<dyn FfiEditorCallback> = Arc::from(callback);
        self.editor_callbacks.lock().unwrap().insert(doc_id, cb);
        Ok(())
    }

    /// Unregister a callback for a resolved builtin document.
    pub fn unregister_editor_callback(
        &self,
        notebook_id: String,
        tab_id: String,
    ) -> Result<(), CoreError> {
        let doc_id = self
            .resolve_product_editor_tab(&notebook_id, &tab_id)?
            .doc_id;
        self.editor_callbacks.lock().unwrap().remove(&doc_id);
        Ok(())
    }
}

impl ZulangueCore {
    /// 内部:查 callback 并触发。找不到就静默。
    pub(crate) fn notify_editor_changed(&self, session_id: &str) {
        notify_editor_callback(&self.editor_callbacks, session_id);
    }

    /// 把 session 标记为"待写盘"，后台 flusher(lib.rs::new 里启动的 tokio task)
    /// 每 500ms drain 一次实际写 fs::write。**不阻塞主线程**。
    ///
    /// 同一 session 连敲多次只会合并成一次写盘(HashSet 语义)。
    pub(crate) fn enqueue_snapshot_save(&self, session_id: &str) {
        self.pending_snapshot_saves
            .lock()
            .unwrap()
            .insert(session_id.to_string());
    }
}

#[uniffi::export]
impl ZulangueCore {
    /// 获取编辑器内容(纯文本,丢所有 mark)
    pub fn get_editor_content(
        &self,
        notebook_id: String,
        tab_id: String,
    ) -> Result<String, CoreError> {
        let session_id = self
            .resolve_product_editor_tab(&notebook_id, &tab_id)?
            .doc_id;
        self.editor_bridge
            .get_content(&session_id)
            .map_err(|e| CoreError::InternalError {
                message: e.to_string(),
            })
    }

    /// 获取编辑器 Quill Delta(JSON string,含所有 mark 属性)
    ///
    /// 返回:形如 `[{"insert":"Hello","attributes":{"bold":true}},{"insert":" world"}]`
    /// 的 JSON。Swift 侧解析后构造 NSAttributedString。
    pub fn get_editor_delta(
        &self,
        notebook_id: String,
        tab_id: String,
    ) -> Result<String, CoreError> {
        let session_id = self
            .resolve_product_editor_tab(&notebook_id, &tab_id)?
            .doc_id;
        self.editor_bridge
            .get_delta(&session_id)
            .map_err(|e| CoreError::InternalError {
                message: e.to_string(),
            })
    }

    /// 关闭编辑器。关闭前同步 flush 一次 snapshot,确保最后的编辑一定落盘
    /// (后台 flusher 可能还没来得及处理 pending_snapshot_saves 里的这条)。
    ///
    /// `editor_bridge.close` 走 refcount —— 返回 `true` 表示最后一个 owner 已
    /// 关闭(session 真从内存移除),此时才清理 per-session 的 callback 注册表。
    /// `false` 表示还有 owner(比如同 docId 的新 bridge 刚 open),啥都不清,
    /// 避免把新 bridge 的 callback 误删 → on_doc_changed push 彻底失效。
    pub fn close_editor(&self, notebook_id: String, tab_id: String) -> Result<(), CoreError> {
        let session_id = self
            .resolve_product_editor_tab(&notebook_id, &tab_id)?
            .doc_id;
        let _mutation_guard = editor_document_mutation_guard();
        tracing::info!(target: "editor_trace", session_id = %session_id, "close_editor IN");
        // 从 pending 集合里移除(马上要同步 flush,不让后台再重复写一次)
        self.pending_snapshot_saves
            .lock()
            .unwrap()
            .remove(&session_id);
        flush_snapshot_to_disk(&self.data_dir, &self.editor_bridge, &session_id);

        let fully_closed =
            self.editor_bridge
                .close(&session_id)
                .map_err(|e| CoreError::InternalError {
                    message: e.to_string(),
                })?;
        if fully_closed {
            self.editor_callbacks.lock().unwrap().remove(&session_id);
            tracing::info!(target: "editor_trace", session_id = %session_id, "close_editor FULLY closed");
        } else {
            tracing::info!(target: "editor_trace", session_id = %session_id, "close_editor refcount--");
        }
        Ok(())
    }

    /// 同步批量落盘所有打开的 editor。App quit 前必调。
    ///
    /// 为什么必须:`apply_edit` 只把 session_id 塞进 `pending_snapshot_saves`,
    /// 真正的 `fs::write` 交给后台 tokio task 每 ~150ms drain 一次。用户 ⌘Q 时
    /// tokio runtime 被切断,那一批 pending 永远写不到磁盘 → 用户最后几秒的
    /// 编辑全丢。
    ///
    /// 实现:pending_saves ∪ 所有 open sessions(兜底没 enqueue 的情况),
    /// 每个同步 `flush_snapshot_to_disk`。清空 pending 集合(后面就算 flusher
    /// 又跑一轮也 no-op)。
    ///
    /// Swift 侧在 `applicationWillTerminate` 里调它。调完再 `shutdown()` 停 worker。
    pub fn flush_all_editors_sync(&self) -> Result<(), CoreError> {
        let _mutation_guard = editor_document_mutation_guard();
        use std::collections::HashSet;
        let pending: HashSet<String> = {
            let mut set = self.pending_snapshot_saves.lock().unwrap();
            set.drain().collect()
        };
        let open: Vec<String> = self.editor_bridge.list_open_sessions();
        let all: HashSet<String> = pending.into_iter().chain(open).collect();
        let n = all.len();
        for sid in all {
            flush_snapshot_to_disk(&self.data_dir, &self.editor_bridge, &sid);
        }
        tracing::info!("flush_all_editors_sync: flushed {n} editor session(s)");
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    #[derive(Clone)]
    struct EditorTarget {
        notebook_id: String,
        tab_id: String,
        doc_id: String,
    }

    fn builtin_target(
        core: &ZulangueCore,
        title: &str,
        builtin_kind: BuiltinNotebookTab,
    ) -> EditorTarget {
        let notebook = core.create_notebook(Some(title.to_string())).unwrap();
        let tab = core
            .notebook_store
            .list_tabs(&notebook.id)
            .unwrap()
            .into_iter()
            .find(|tab| tab.builtin_kind == builtin_kind)
            .unwrap();
        EditorTarget {
            notebook_id: notebook.id,
            tab_id: tab.id,
            doc_id: tab.doc_id,
        }
    }

    fn manual_target(core: &ZulangueCore, title: &str) -> EditorTarget {
        builtin_target(core, title, BuiltinNotebookTab::ManualNote)
    }

    fn open(core: &ZulangueCore, target: &EditorTarget) {
        core.open_editor(target.notebook_id.clone(), target.tab_id.clone())
            .unwrap();
    }

    fn apply(core: &ZulangueCore, target: &EditorTarget, op: FfiEditOp) {
        core.apply_edit(target.notebook_id.clone(), target.tab_id.clone(), op)
            .unwrap();
    }

    fn content(core: &ZulangueCore, target: &EditorTarget) -> String {
        core.get_editor_content(target.notebook_id.clone(), target.tab_id.clone())
            .unwrap()
    }

    fn delta(core: &ZulangueCore, target: &EditorTarget) -> String {
        core.get_editor_delta(target.notebook_id.clone(), target.tab_id.clone())
            .unwrap()
    }

    fn close(core: &ZulangueCore, target: &EditorTarget) {
        core.close_editor(target.notebook_id.clone(), target.tab_id.clone())
            .unwrap();
    }

    #[test]
    fn test_editor_ops_roundtrip() {
        let tmp = TempDir::new().unwrap();
        let core = ZulangueCore::new(tmp.path().to_str().unwrap().to_string()).unwrap();
        let target = manual_target(&core, "Roundtrip");

        open(&core, &target);
        assert!(core
            .is_editor_writable(target.notebook_id.clone(), target.tab_id.clone())
            .unwrap());

        apply(
            &core,
            &target,
            FfiEditOp::Insert {
                pos: 0,
                text: "Hello".to_string(),
            },
        );

        let content = content(&core, &target);
        assert!(content.contains("Hello"));

        close(&core, &target);
    }

    #[test]
    fn product_open_rejects_caller_supplied_or_cross_notebook_tab_identity() {
        let tmp = TempDir::new().unwrap();
        let core = ZulangueCore::new(tmp.path().to_str().unwrap().to_string()).unwrap();
        let first = manual_target(&core, "First");
        let second = manual_target(&core, "Second");

        assert!(core
            .open_editor(first.notebook_id.clone(), "raw-doc-id".to_string())
            .is_err());
        assert!(core.open_editor(first.notebook_id, second.tab_id).is_err());
    }

    #[test]
    fn product_open_rejects_corrupt_snapshot_without_overwriting_it() {
        let tmp = TempDir::new().unwrap();
        let core = ZulangueCore::new(tmp.path().to_str().unwrap().to_string()).unwrap();
        let target = manual_target(&core, "Corrupt");
        let path = snapshot_path(tmp.path(), &target.doc_id);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        let corrupt = b"not-a-loro-snapshot\0private-user-bytes";
        std::fs::write(&path, corrupt).unwrap();

        let error = core
            .open_editor(target.notebook_id, target.tab_id)
            .unwrap_err();

        assert!(error.to_string().contains("import Loro snapshot"));
        assert_eq!(std::fs::read(path).unwrap(), corrupt);
        assert!(!core.editor_bridge.is_session_open(&target.doc_id));
    }

    struct NoopCaptureCallback;

    impl crate::notebook_capture_api::FfiNotebookCaptureCallback for NoopCaptureCallback {
        fn on_capture_event(&self, _event: crate::notebook_capture_api::FfiNotebookCaptureEvent) {}

        fn on_live_preview(
            &self,
            _preview: crate::notebook_capture_api::FfiNotebookCaptureLivePreview,
        ) {
        }
    }

    #[test]
    fn realtime_transcript_is_read_only_until_capture_projection_is_ready() {
        let tmp = TempDir::new().unwrap();
        let core = ZulangueCore::new(tmp.path().to_str().unwrap().to_string()).unwrap();
        let target = builtin_target(&core, "Capture", BuiltinNotebookTab::RealtimeTranscript);
        open(&core, &target);
        assert!(!core
            .is_editor_writable(target.notebook_id.clone(), target.tab_id.clone())
            .unwrap());

        let before_capture = core.apply_edit(
            target.notebook_id.clone(),
            target.tab_id.clone(),
            FfiEditOp::Insert {
                pos: 0,
                text: "must stay locked".to_string(),
            },
        );
        assert!(before_capture.is_err());

        let profile = core
            .get_notebook_capture_profile(target.notebook_id.clone())
            .unwrap();
        let started = core
            .start_notebook_capture_session(
                target.notebook_id.clone(),
                profile.revision,
                None,
                Box::new(NoopCaptureCallback),
            )
            .unwrap();
        let while_recording = core.apply_edit(
            target.notebook_id.clone(),
            target.tab_id.clone(),
            FfiEditOp::Insert {
                pos: 0,
                text: "still locked".to_string(),
            },
        );
        assert!(while_recording.is_err());

        core.push_notebook_capture_session(started.session_id.clone(), vec![0_u8; 3_200])
            .unwrap();
        let stopped = core
            .stop_notebook_capture_session(started.session_id)
            .unwrap();
        assert_eq!(
            stopped.projection_state,
            crate::notebook_capture_api::FfiNotebookProjectionState::Ready
        );
        assert!(core
            .is_editor_writable(target.notebook_id.clone(), target.tab_id.clone())
            .unwrap());

        core.apply_edit(
            target.notebook_id,
            target.tab_id,
            FfiEditOp::Insert {
                pos: 0,
                text: "ready edit".to_string(),
            },
        )
        .unwrap();
    }

    // ========== flush_all_editors_sync ==========

    #[test]
    fn test_flush_all_editors_sync_persists_unsaved_edits() {
        // 模拟"用户打字 → 500ms flusher 还没 drain → App 被 ⌘Q"场景:
        // 不调 close_editor、也不等 flusher,直接 flush_all_editors_sync 应该落盘。
        let tmp = TempDir::new().unwrap();
        let data_dir = tmp.path().to_str().unwrap().to_string();

        let target = {
            let core = ZulangueCore::new(data_dir.clone()).unwrap();
            let target = manual_target(&core, "Quit");
            open(&core, &target);
            apply(
                &core,
                &target,
                FfiEditOp::Insert {
                    pos: 0,
                    text: "unsaved keystrokes".to_string(),
                },
            );

            // ⚠️ 关键:不 close_editor、不 sleep — 直接 flush_all
            core.flush_all_editors_sync().unwrap();
            // 模拟进程被切断:drop core(tokio runtime 随之销毁)
            target
        };

        // 新进程打开同一 data_dir,读回来必须有之前打的字
        let core2 = ZulangueCore::new(data_dir).unwrap();
        open(&core2, &target);
        let content = content(&core2, &target);
        assert_eq!(
            content, "unsaved keystrokes",
            "flush_all_editors_sync must persist in-memory LoroDoc synchronously"
        );
    }

    #[test]
    fn test_shutdown_flushes_editors_too() {
        // 兜底:即便 Swift 没调 flush_all_editors_sync,只调 shutdown
        // 也应该把所有 open editor 落盘 —— 避免历史代码漏调 quit hook。
        let tmp = TempDir::new().unwrap();
        let data_dir = tmp.path().to_str().unwrap().to_string();

        let target = {
            let core = ZulangueCore::new(data_dir.clone()).unwrap();
            let target = manual_target(&core, "Shutdown");
            open(&core, &target);
            apply(
                &core,
                &target,
                FfiEditOp::Insert {
                    pos: 0,
                    text: "via shutdown only".to_string(),
                },
            );
            core.shutdown().unwrap();
            target
        };

        let core2 = ZulangueCore::new(data_dir).unwrap();
        open(&core2, &target);
        let content = content(&core2, &target);
        assert_eq!(content, "via shutdown only");
    }

    #[test]
    fn test_flush_all_editors_sync_handles_multiple_sessions() {
        let tmp = TempDir::new().unwrap();
        let core = ZulangueCore::new(tmp.path().to_str().unwrap().to_string()).unwrap();
        let targets = ["a", "b", "c"]
            .into_iter()
            .map(|title| manual_target(&core, title))
            .collect::<Vec<_>>();
        for (i, target) in targets.iter().enumerate() {
            open(&core, target);
            apply(
                &core,
                target,
                FfiEditOp::Insert {
                    pos: 0,
                    text: format!("n={i}"),
                },
            );
        }
        core.flush_all_editors_sync().unwrap();

        // 三个 snapshot 都应在磁盘上(非空)
        for target in targets {
            let p = snapshot_path(tmp.path(), &target.doc_id);
            assert!(p.exists(), "{} snapshot missing", target.doc_id);
            let bytes = std::fs::read(&p).unwrap();
            assert!(
                bytes.len() > 100,
                "{} snapshot too small: {} bytes",
                target.doc_id,
                bytes.len()
            );
        }
    }

    #[test]
    fn test_snapshot_flush_preserves_existing_file_when_temp_write_fails() {
        let tmp = TempDir::new().unwrap();
        let bridge = EditorBridge::new();
        let session_id = "atomic-snapshot";
        open_editor_session(tmp.path(), &bridge, session_id).unwrap();
        bridge
            .apply(
                session_id,
                EditOp::Insert {
                    pos: 0,
                    text: "durable base".to_string(),
                },
            )
            .unwrap();
        flush_snapshot_to_disk_result(tmp.path(), &bridge, session_id).unwrap();
        let snapshot = snapshot_path(tmp.path(), session_id);
        let previous = std::fs::read(&snapshot).unwrap();

        bridge
            .apply(
                session_id,
                EditOp::Insert {
                    pos: "durable base".chars().count(),
                    text: " volatile edit".to_string(),
                },
            )
            .unwrap();
        let temp_path = snapshot_path(tmp.path(), session_id).with_extension("loro.tmp.blocked");
        std::fs::create_dir(&temp_path).unwrap();

        let error = flush_snapshot_to_disk_result_with_temp_path(
            tmp.path(),
            &bridge,
            session_id,
            temp_path,
        )
        .unwrap_err();

        assert!(
            error.contains("snapshot temp write failed"),
            "expected temp write failure, got {error}"
        );
        assert_eq!(
            std::fs::read(snapshot).unwrap(),
            previous,
            "failed flush must leave the previous durable snapshot intact"
        );
    }

    #[test]
    fn test_snapshot_temp_paths_are_unique_per_flush() {
        let tmp = TempDir::new().unwrap();
        let session_id = "concurrent-snapshot";

        let first = snapshot_temp_path(tmp.path(), session_id);
        let second = snapshot_temp_path(tmp.path(), session_id);

        assert_ne!(
            first, second,
            "concurrent flushes for the same session must not share a temp file"
        );
        assert_eq!(
            first.parent(),
            snapshot_path(tmp.path(), session_id).parent()
        );
        assert_eq!(
            second.parent(),
            snapshot_path(tmp.path(), session_id).parent()
        );
    }

    struct SnapshotFlushTestHookGuard;

    impl Drop for SnapshotFlushTestHookGuard {
        fn drop(&mut self) {
            set_snapshot_flush_test_hook(None);
        }
    }

    #[test]
    fn test_same_session_flushes_cannot_rename_stale_snapshot_after_newer_flush() {
        use std::sync::atomic::AtomicUsize;
        use std::sync::Condvar;
        use std::thread;
        use std::time::Duration;

        #[derive(Default)]
        struct FlushOrderState {
            stale_ready: bool,
            release_stale: bool,
            fresh_reached: bool,
        }

        let tmp = TempDir::new().unwrap();
        let data_dir = tmp.path().to_path_buf();
        let bridge = EditorBridge::new();
        let session_id = "ordered-snapshot";
        open_editor_session(&data_dir, &bridge, session_id).unwrap();
        bridge
            .apply(
                session_id,
                EditOp::Insert {
                    pos: 0,
                    text: "old".to_string(),
                },
            )
            .unwrap();

        let state = Arc::new((Mutex::new(FlushOrderState::default()), Condvar::new()));
        let call_count = Arc::new(AtomicUsize::new(0));
        let hook_session_id = session_id.to_string();
        let hook_state = state.clone();
        let hook_call_count = call_count.clone();
        set_snapshot_flush_test_hook(Some(Arc::new(move |sid| {
            if sid != hook_session_id {
                return;
            }
            match hook_call_count.fetch_add(1, Ordering::SeqCst) {
                0 => {
                    let (lock, cvar) = &*hook_state;
                    let mut state = lock.lock().unwrap();
                    state.stale_ready = true;
                    cvar.notify_all();
                    while !state.release_stale {
                        state = cvar.wait(state).unwrap();
                    }
                }
                1 => {
                    let (lock, cvar) = &*hook_state;
                    let mut state = lock.lock().unwrap();
                    state.fresh_reached = true;
                    cvar.notify_all();
                }
                _ => {}
            }
        })));
        let _hook_guard = SnapshotFlushTestHookGuard;

        let stale_bridge = bridge.clone();
        let stale_data_dir = data_dir.clone();
        let stale_session_id = session_id.to_string();
        let stale_flush = thread::spawn(move || {
            flush_snapshot_to_disk_result(&stale_data_dir, &stale_bridge, &stale_session_id)
                .unwrap();
        });

        {
            let (lock, cvar) = &*state;
            let state = lock.lock().unwrap();
            let (state, timeout) = cvar
                .wait_timeout_while(state, Duration::from_secs(5), |state| !state.stale_ready)
                .unwrap();
            assert!(
                state.stale_ready && !timeout.timed_out(),
                "stale flush did not reach the pre-rename hook"
            );
        }

        bridge
            .apply(
                session_id,
                EditOp::Insert {
                    pos: "old".chars().count(),
                    text: " new".to_string(),
                },
            )
            .unwrap();

        let fresh_bridge = bridge.clone();
        let fresh_data_dir = data_dir.clone();
        let fresh_session_id = session_id.to_string();
        let mut fresh_flush = Some(thread::spawn(move || {
            flush_snapshot_to_disk_result(&fresh_data_dir, &fresh_bridge, &fresh_session_id)
                .unwrap();
        }));

        let fresh_reached_before_release = {
            let (lock, cvar) = &*state;
            let state = lock.lock().unwrap();
            let (state, _) = cvar
                .wait_timeout_while(state, Duration::from_millis(500), |state| {
                    !state.fresh_reached
                })
                .unwrap();
            state.fresh_reached
        };
        if fresh_reached_before_release {
            fresh_flush.take().unwrap().join().unwrap();
        }

        {
            let (lock, cvar) = &*state;
            let mut state = lock.lock().unwrap();
            state.release_stale = true;
            cvar.notify_all();
        }
        stale_flush.join().unwrap();
        if !fresh_reached_before_release {
            fresh_flush.take().unwrap().join().unwrap();
        }

        set_snapshot_flush_test_hook(None);
        let reopened = EditorBridge::new();
        open_editor_session(&data_dir, &reopened, session_id).unwrap();
        assert_eq!(
            reopened.get_content(session_id).unwrap(),
            "old new",
            "a stale flush must not be able to rename over a newer same-session flush"
        );
    }

    // ========== refcount-aware open/close ==========
    //
    // SwiftUI NSViewRepresentable 的 lifecycle 是 make(new) → update(new)
    // → dismantle(old)。同 docId 重建时,new 先 open (refcount=2),old 随后
    // close (refcount=1)。用户在 new bridge 上打字必须能继续 applyEdit。

    #[test]
    fn test_open_same_session_twice_preserves_content_after_one_close() {
        let tmp = TempDir::new().unwrap();
        let core = ZulangueCore::new(tmp.path().to_str().unwrap().to_string()).unwrap();
        let target = manual_target(&core, "Refcount");

        open(&core, &target);
        apply(
            &core,
            &target,
            FfiEditOp::Insert {
                pos: 0,
                text: "user typed".to_string(),
            },
        );

        // 模拟 SwiftUI 同 docId 重开:new 先 open,old 随后 close
        open(&core, &target); // refcount=2
        close(&core, &target); // refcount=1,内存保留

        // 用户继续打字 —— 必须成功(修复前这里会 "session not open")
        core.apply_edit(
            target.notebook_id.clone(),
            target.tab_id.clone(),
            FfiEditOp::Insert {
                pos: 10,
                text: " more".to_string(),
            },
        )
        .expect("apply_edit must succeed after one close on doubly-opened session");

        let content = content(&core, &target);
        assert_eq!(content, "user typed more");
    }

    #[test]
    fn test_final_close_actually_frees_session() {
        let tmp = TempDir::new().unwrap();
        let core = ZulangueCore::new(tmp.path().to_str().unwrap().to_string()).unwrap();
        let target = manual_target(&core, "Final close");

        open(&core, &target);
        open(&core, &target); // refcount=2
        close(&core, &target); // refcount=1
        close(&core, &target); // refcount=0,真释放

        // 此时 apply_edit 应当 "session not open" —— session 真释放了
        let err = core
            .apply_edit(
                target.notebook_id,
                target.tab_id,
                FfiEditOp::Insert {
                    pos: 0,
                    text: "x".to_string(),
                },
            )
            .unwrap_err();
        assert!(format!("{err:?}").contains("session not open"));
    }

    #[test]
    fn test_second_open_preserves_in_memory_edits_not_reimport_snapshot() {
        // 关键保护:用户打字后 snapshot 尚未落盘(flusher 未 drain),此时
        // 同 docId 第二次 open_editor(比如 SwiftUI 重建 view)触发从磁盘
        // 读旧(或空)snapshot —— 如果无条件覆盖内存,用户的编辑就没了。
        // refcount open 语义:已存在 session 只 ++,不动 LoroDoc。
        let tmp = TempDir::new().unwrap();
        let core = ZulangueCore::new(tmp.path().to_str().unwrap().to_string()).unwrap();
        let target = manual_target(&core, "In-memory");

        open(&core, &target);
        apply(
            &core,
            &target,
            FfiEditOp::Insert {
                pos: 0,
                text: "unflushed".to_string(),
            },
        );

        // 第二次 open（不 close 第一次）—— LoroDoc 应保留 "unflushed"
        open(&core, &target);

        let content = content(&core, &target);
        assert_eq!(
            content, "unflushed",
            "second open must not wipe in-memory edits"
        );
    }

    #[test]
    fn test_flush_all_editors_sync_no_sessions_is_noop() {
        let tmp = TempDir::new().unwrap();
        let core = ZulangueCore::new(tmp.path().to_str().unwrap().to_string()).unwrap();
        // 没 open 任何 editor,flush 应当 ok 且不 panic
        core.flush_all_editors_sync().unwrap();
    }

    #[test]
    fn test_snapshot_persistence_across_reopen() {
        let tmp = TempDir::new().unwrap();
        let data_dir = tmp.path().to_str().unwrap().to_string();

        // Round 1:打开 / 编辑 / 关闭
        let target = {
            let core = ZulangueCore::new(data_dir.clone()).unwrap();
            let target = manual_target(&core, "Persist");
            open(&core, &target);
            apply(
                &core,
                &target,
                FfiEditOp::Insert {
                    pos: 0,
                    text: "Hello persistent world".to_string(),
                },
            );
            apply(
                &core,
                &target,
                FfiEditOp::Mark {
                    pos: 0,
                    len: 5,
                    key: "bold".to_string(),
                    value_json: "true".to_string(),
                },
            );
            close(&core, &target);
            target
        };

        // Round 2:重新 new ZulangueCore(模拟 App 重启),打开同一 session
        {
            let core = ZulangueCore::new(data_dir).unwrap();
            open(&core, &target);

            let content = content(&core, &target);
            assert_eq!(content, "Hello persistent world", "content should persist");

            let delta = delta(&core, &target);
            assert!(
                delta.contains("\"bold\":true"),
                "bold mark should persist, got: {delta}"
            );
        }
    }

    #[test]
    fn test_heading_mark_roundtrip() {
        let tmp = TempDir::new().unwrap();
        let core = ZulangueCore::new(tmp.path().to_str().unwrap().to_string()).unwrap();
        let target = manual_target(&core, "Heading");

        open(&core, &target);
        apply(
            &core,
            &target,
            FfiEditOp::Insert {
                pos: 0,
                text: "Hello world".to_string(),
            },
        );

        // Heading = 1(之前 UI 就是这里报 Style configuration missing 错)
        core.apply_edit(
            target.notebook_id.clone(),
            target.tab_id.clone(),
            FfiEditOp::Mark {
                pos: 0,
                len: 5,
                key: "heading".to_string(),
                value_json: "1".to_string(),
            },
        )
        .expect("heading mark must succeed after config_text_style");

        let delta = delta(&core, &target);
        assert!(
            delta.contains("\"heading\":1"),
            "delta should contain heading=1, got: {delta}"
        );
    }

    #[test]
    fn test_strikethrough_mark_roundtrip() {
        let tmp = TempDir::new().unwrap();
        let core = ZulangueCore::new(tmp.path().to_str().unwrap().to_string()).unwrap();
        let target = manual_target(&core, "Strikethrough");

        open(&core, &target);
        apply(
            &core,
            &target,
            FfiEditOp::Insert {
                pos: 0,
                text: "oldtext".to_string(),
            },
        );

        core.apply_edit(
            target.notebook_id,
            target.tab_id,
            FfiEditOp::Mark {
                pos: 0,
                len: 7,
                key: "strikethrough".to_string(),
                value_json: "true".to_string(),
            },
        )
        .expect("strikethrough mark must succeed after config_text_style");
    }

    #[test]
    fn test_rich_text_mark_roundtrip() {
        let tmp = TempDir::new().unwrap();
        let core = ZulangueCore::new(tmp.path().to_str().unwrap().to_string()).unwrap();
        let target = manual_target(&core, "Rich text");

        open(&core, &target);

        // Insert "Hello world"
        apply(
            &core,
            &target,
            FfiEditOp::Insert {
                pos: 0,
                text: "Hello world".to_string(),
            },
        );

        // Mark "Hello" as bold
        apply(
            &core,
            &target,
            FfiEditOp::Mark {
                pos: 0,
                len: 5,
                key: "bold".to_string(),
                value_json: "true".to_string(),
            },
        );

        // Delta 应该拆成 ["Hello"(bold) | " world"]
        let delta_json = delta(&core, &target);
        assert!(
            delta_json.contains("\"bold\":true"),
            "delta should carry bold attribute, got: {delta_json}"
        );
        assert!(
            delta_json.contains("Hello"),
            "delta should contain Hello, got: {delta_json}"
        );

        // Unmark bold
        apply(
            &core,
            &target,
            FfiEditOp::Unmark {
                pos: 0,
                len: 5,
                key: "bold".to_string(),
            },
        );

        let delta_after = delta(&core, &target);
        assert!(
            !delta_after.contains("\"bold\":true"),
            "bold should be gone after unmark, got: {delta_after}"
        );

        close(&core, &target);
    }

    #[test]
    fn strict_open_rejects_corrupt_snapshot_without_replacing_bytes() {
        let tmp = TempDir::new().unwrap();
        let session_id = "corrupt-projection";
        let path = snapshot_path(tmp.path(), session_id);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        let corrupt = b"not-a-loro-snapshot\0private-user-bytes";
        std::fs::write(&path, corrupt).unwrap();
        let bridge = EditorBridge::new();

        let error = open_editor_session_strict(tmp.path(), &bridge, session_id).unwrap_err();

        assert!(error.to_string().contains("import Loro snapshot"));
        assert_eq!(std::fs::read(&path).unwrap(), corrupt);
        assert!(!bridge.is_session_open(session_id));
    }

    #[test]
    fn strict_open_validates_disk_even_when_an_in_memory_session_is_open() {
        let tmp = TempDir::new().unwrap();
        let session_id = "corrupt-already-open";
        let path = snapshot_path(tmp.path(), session_id);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        let corrupt = b"corrupt-authoritative-snapshot";
        std::fs::write(&path, corrupt).unwrap();
        let bridge = EditorBridge::new();
        let doc = loro::LoroDoc::new();
        doc.config_text_style(voice_tool_style_config());
        bridge.open(session_id, doc).unwrap();
        assert!(bridge.is_session_open(session_id));

        let error = open_editor_session_strict(tmp.path(), &bridge, session_id).unwrap_err();

        assert!(error.to_string().contains("import Loro snapshot"));
        assert_eq!(std::fs::read(&path).unwrap(), corrupt);
    }

    #[test]
    fn test_editor_closed_session_error() {
        let tmp = TempDir::new().unwrap();
        let core = ZulangueCore::new(tmp.path().to_str().unwrap().to_string()).unwrap();
        let target = manual_target(&core, "Closed");

        let result = core.apply_edit(
            target.notebook_id,
            target.tab_id,
            FfiEditOp::Insert {
                pos: 0,
                text: "test".to_string(),
            },
        );
        assert!(result.is_err());
    }
}
