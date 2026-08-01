//! Task worker loop
//!
//! `ZulangueCore` 构造时 spawn 一个后台 worker；macOS 生产构造器先把它
//! 挡在 provider credential bootstrap gate 后，凭据恢复完成后才允许从
//! `TaskQueue` 拿任务执行。普通 Rust 构造器保持立即启动语义。
//! Durable task queue、retry 与崩溃恢复都由这里统一执行。
//!
//! ## Worker 行为
//!
//! 循环:
//!
//! ```text
//! select! {
//!   worker_cancel.cancelled() => break
//!   sleep 200ms => try dequeue:
//!     Some(task) => dispatch + await handler + queue.complete/fail
//!     None       => 回到 sleep(轻量 polling,够用了,任务不是秒级场景)
//! }
//! ```
//!
//! ## 回调路由
//!
//! `TaskCallbackMap`: task_id → Arc<FfiTaskCallback>
//! 由 `submit_*_task` 在 enqueue 后立即 insert;worker 在执行到该 task 时
//! 查表找 callback 调 on_progress/on_complete/on_error。
//!
//! 终止时(complete 或 fail 到 max_retries)从 map 移除条目,防止泄漏。
//! 重试时(fail 但 retry_count < max)保留 callback 让下一轮执行继续用。
//!
//! ## 隐私
//!
//! transcribe 的 `enforce_privacy_after_task` 是 terminal success 的前置条件；
//! high/maximum 销毁完成后才允许 queue complete 和 on_complete。

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex, Weak};
use std::time::{Duration, Instant};

use crate::notebook_api::NotebookTranscriptProjector;
use crate::transcribe_api::{
    run_transcribe_chunked_task_async, FfiTaskCallback, ProviderDispatchGate,
};
use sha2::{Digest, Sha256};
use tokio::runtime::Runtime;
use tokio_util::sync::CancellationToken;
use vt_crypto::{ApiKeyProvider, KeyProvider};
use vt_pipeline::{Task, TaskPayload, TaskQueue, TaskQueueError, TaskStatus};
use vt_store::notebook_capture_store::CaptureProviderRole;
use vt_store::{
    AsyncProviderReceipt, AsyncTaskState, AudioChunkRetentionRecord, ContextPackStore,
    NotebookCaptureStore, NotebookCaptureStoreError, SessionMeta, SessionMetaStore,
};
use vt_stt::{
    soniox_async_delete_remote_file, soniox_async_delete_remote_transcription,
    soniox_async_list_remote_files, soniox_async_list_remote_transcriptions, SonioxRemoteEndpoint,
    SonioxRemoteInventoryEntry, CURRENT_NOTEBOOK_CAPTURE_ENGINE,
};

/// One-shot gate that prevents the durable worker from claiming provider work
/// until the app has restored (or explicitly failed closed) its persisted
/// provider credentials.  The normal Rust constructor opens this gate before
/// returning; the macOS production constructor leaves it closed until Swift
/// completes the credential bootstrap.
#[derive(Default)]
pub(crate) struct ProviderCredentialBootstrapGate {
    completed: AtomicBool,
    changed: tokio::sync::Notify,
}

impl ProviderCredentialBootstrapGate {
    pub(crate) fn completed() -> Self {
        Self {
            completed: AtomicBool::new(true),
            changed: tokio::sync::Notify::new(),
        }
    }

    pub(crate) fn deferred() -> Self {
        Self::default()
    }

    pub(crate) fn complete(&self) {
        if !self.completed.swap(true, Ordering::AcqRel) {
            self.changed.notify_waiters();
        }
    }

    async fn wait_or_cancelled(&self, cancel: &CancellationToken) -> bool {
        loop {
            if self.completed.load(Ordering::Acquire) {
                return true;
            }

            // Register the waiter before re-checking the atomic so a complete
            // racing with this boundary cannot be missed.
            let changed = self.changed.notified();
            tokio::pin!(changed);
            if self.completed.load(Ordering::Acquire) {
                return true;
            }
            tokio::select! {
                _ = cancel.cancelled() => return false,
                _ = &mut changed => {}
            }
        }
    }
}

/// Process-local ownership of handlers that may still write durable artifacts.
///
/// A Delete Forever saga first writes its durable `session_purge_jobs`
/// tombstone, then calls [`SessionTaskRegistry::cancel_and_wait`]. The registry
/// permanently blocks that ownership id for this process, cancels every
/// registered handler, and does not return until the handlers have dropped
/// their registrations (or the bounded timeout expires). Capture work uses its
/// immutable session id. Keeping the blocked marker closes the
/// race where a task was claimed before the durable purge but was not scheduled
/// until after the purge job itself had completed.
#[derive(Default)]
pub struct SessionTaskRegistry {
    state: Mutex<SessionTaskRegistryState>,
    changed: Condvar,
}

#[derive(Default)]
struct SessionTaskRegistryState {
    next_registration_id: u64,
    blocked_sessions: HashSet<String>,
    active: HashMap<String, HashMap<u64, CancellationToken>>,
}

pub(crate) struct SessionTaskRegistration {
    registry: Weak<SessionTaskRegistry>,
    session_id: String,
    registration_id: u64,
    cancel: CancellationToken,
}

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum SessionTaskWaitError {
    #[error("timed out waiting for session task handlers to stop: {session_id}")]
    Timeout { session_id: String },
}

impl SessionTaskRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    pub(crate) fn register(self: &Arc<Self>, session_id: &str) -> Option<SessionTaskRegistration> {
        let mut state = self.state.lock().unwrap();
        if state.blocked_sessions.contains(session_id) {
            return None;
        }
        state.next_registration_id = state.next_registration_id.wrapping_add(1).max(1);
        let registration_id = state.next_registration_id;
        let cancel = CancellationToken::new();
        state
            .active
            .entry(session_id.to_string())
            .or_default()
            .insert(registration_id, cancel.clone());
        Some(SessionTaskRegistration {
            registry: Arc::downgrade(self),
            session_id: session_id.to_string(),
            registration_id,
            cancel,
        })
    }

    /// Cancel all in-flight handlers for an ownership id and synchronously wait
    /// until their abort/join boundary has completed.
    ///
    /// The id stays blocked for the lifetime of this registry. Callers use only
    /// immutable session ids or unique task ids, never shared document ids.
    pub fn cancel_and_wait(
        &self,
        session_id: &str,
        timeout: Duration,
    ) -> Result<(), SessionTaskWaitError> {
        let deadline = Instant::now() + timeout;
        let tokens = {
            let mut state = self.state.lock().unwrap();
            state.blocked_sessions.insert(session_id.to_string());
            state
                .active
                .get(session_id)
                .map(|entries| entries.values().cloned().collect::<Vec<_>>())
                .unwrap_or_default()
        };
        for token in tokens {
            token.cancel();
        }

        let mut state = self.state.lock().unwrap();
        while state
            .active
            .get(session_id)
            .is_some_and(|entries| !entries.is_empty())
        {
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                return Err(SessionTaskWaitError::Timeout {
                    session_id: session_id.to_string(),
                });
            }
            let (next_state, wait_result) = self.changed.wait_timeout(state, remaining).unwrap();
            state = next_state;
            if wait_result.timed_out()
                && state
                    .active
                    .get(session_id)
                    .is_some_and(|entries| !entries.is_empty())
            {
                return Err(SessionTaskWaitError::Timeout {
                    session_id: session_id.to_string(),
                });
            }
        }
        Ok(())
    }

    #[cfg(test)]
    pub(crate) fn active_count(&self, session_id: &str) -> usize {
        self.state
            .lock()
            .unwrap()
            .active
            .get(session_id)
            .map(HashMap::len)
            .unwrap_or(0)
    }

    #[cfg(test)]
    pub(crate) fn is_blocked(&self, session_id: &str) -> bool {
        self.state
            .lock()
            .unwrap()
            .blocked_sessions
            .contains(session_id)
    }
}

impl SessionTaskRegistration {
    pub(crate) fn cancellation_token(&self) -> CancellationToken {
        self.cancel.clone()
    }
}

impl Drop for SessionTaskRegistration {
    fn drop(&mut self) {
        let Some(registry) = self.registry.upgrade() else {
            return;
        };
        let mut state = registry.state.lock().unwrap();
        if let Some(entries) = state.active.get_mut(&self.session_id) {
            entries.remove(&self.registration_id);
            if entries.is_empty() {
                state.active.remove(&self.session_id);
            }
        }
        drop(state);
        registry.changed.notify_all();
    }
}

type TaskHandlerResult = Result<String, (String, String)>;

enum TaskHandlerJoinOutcome {
    Finished(TaskHandlerResult),
    SessionCancelled,
}

#[derive(Clone, Copy)]
enum HandlerCancellationPolicy {
    /// The handler owns no detached child task, so aborting and joining its
    /// outer JoinHandle proves that it has stopped.
    AbortOuter,
    /// The post-stop transcription helper owns a nested Soniox
    /// JoinHandle. Until that helper has consumed its cancellation token and
    /// joined the client, dropping/aborting only this outer future would detach
    /// remote work. Wait cooperatively instead; the synchronous purge caller is
    /// still bounded by SessionTaskRegistry::cancel_and_wait and will retry the
    /// durable purge job rather than delete under a live provider.
    AwaitOwnedChildren,
}

/// Stop and *join* the handler before reporting cancellation. Waiting for the
/// JoinHandle is what makes Delete Forever safe around synchronous SQLite/file
/// writes and handler-owned child tasks. Handlers without detached ownership
/// can be aborted; handlers with owned child tasks must unwind cooperatively.
async fn await_handler_or_session_cancel(
    mut handle: tokio::task::JoinHandle<TaskHandlerResult>,
    session_cancel: CancellationToken,
    cancellation_policy: HandlerCancellationPolicy,
) -> TaskHandlerJoinOutcome {
    tokio::select! {
        biased;
        _ = session_cancel.cancelled() => {
            match cancellation_policy {
                HandlerCancellationPolicy::AbortOuter => {
                    handle.abort();
                    let _ = handle.await;
                }
                HandlerCancellationPolicy::AwaitOwnedChildren => {
                    let _ = handle.await;
                }
            }
            TaskHandlerJoinOutcome::SessionCancelled
        }
        joined = &mut handle => {
            let result = match joined {
                Ok(result) => result,
                Err(join_error) => {
                    let message = if join_error.is_panic() {
                        format!("task panicked: {join_error}")
                    } else {
                        format!("task aborted: {join_error}")
                    };
                    Err(("internal_error".to_string(), message))
                }
            };
            TaskHandlerJoinOutcome::Finished(result)
        }
    }
}

/// Fail closed on an unreadable purge gate. A tombstoned session also removes
/// every matching durable task/event row idempotently before dispatch or commit.
async fn session_task_may_continue(
    capture_store: &NotebookCaptureStore,
    task_queue: &TaskQueue,
    session_id: &str,
    task_id: &str,
) -> bool {
    match capture_store.has_session_purge_job(session_id) {
        Ok(true) => {
            if let Err(error) = task_queue.purge_session(session_id).await {
                tracing::warn!(
                    session_id,
                    error = %error,
                    "failed to remove tombstoned session tasks"
                );
            }
            false
        }
        Ok(false) => {
            // A completed purge removes its durable tombstone last. The task
            // row check catches a task that was claimed into memory immediately
            // before that purge deleted tasks.db and completed the job.
            if task_queue.get_task(task_id).await.is_ok() {
                true
            } else {
                tracing::debug!(
                    session_id,
                    task_id,
                    "claimed task was deleted before handler dispatch/finalization"
                );
                false
            }
        }
        Err(error) => {
            tracing::warn!(
                session_id,
                task_id,
                error = %error,
                "purge tombstone check failed; refusing session work"
            );
            false
        }
    }
}

fn task_registry_owner_id(_task_id: &str, payload: &TaskPayload) -> String {
    payload.session_id().to_string()
}

/// Bind every post-stop upload to an immutable Notebook capture/import receipt.
/// The run must have the same stable task id and byte-exact payload digest; an
/// exact `Reserved` receipt is atomically promoted by the actual claimant, and
/// provider dispatch requires the rechecked `Enqueued` state.
async fn verify_capture_async_task_receipt(
    capture_store: &NotebookCaptureStore,
    task_queue: &TaskQueue,
    payload: &TaskPayload,
    task_id: &str,
    provider_receipt_ready: bool,
) -> Result<(), (String, String)> {
    let TaskPayload::Transcribe { session_id, .. } = payload;
    let run = capture_store
        .get_run_for_session(session_id)
        .map_err(|error| {
            (
                "capture_async_receipt_unavailable".to_string(),
                format!("cannot verify capture async task receipt: {error}"),
            )
        })?;
    let Some(mut run) = run else {
        return Err((
            "capture_async_receipt_missing".to_string(),
            format!(
                "transcription task {task_id} has no durable Notebook capture/import run for session {session_id}"
            ),
        ));
    };

    if !provider_receipt_ready {
        match capture_store.get_async_provider_receipt(session_id, task_id) {
            Ok(None) => {}
            Ok(Some(_)) => {
                return Err((
                    "capture_provider_receipt_invalid".to_string(),
                    format!(
                        "capture session {session_id} already has provider output; refusing a second provider dispatch"
                    ),
                ));
            }
            Err(error) => {
                return Err((
                    "capture_provider_receipt_invalid".to_string(),
                    format!(
                        "capture session {session_id} has a corrupt provider receipt; refusing a second provider dispatch: {error}"
                    ),
                ));
            }
        }
    }

    if !matches!(
        run.async_task_state,
        AsyncTaskState::Reserved | AsyncTaskState::Enqueued
    ) {
        return Err((
            "capture_async_receipt_invalid".to_string(),
            format!(
                "capture run {} async task is {:?}, expected a durable enqueue receipt",
                run.id, run.async_task_state
            ),
        ));
    }
    if run.async_task_id.as_deref() != Some(task_id) {
        return Err((
            "capture_async_receipt_invalid".to_string(),
            format!(
                "capture run {} async task id does not match claimed task",
                run.id
            ),
        ));
    }
    let expected_digest = run.async_task_payload_sha256.clone().ok_or_else(|| {
        (
            "capture_async_receipt_invalid".to_string(),
            format!("capture run {} has no async payload digest", run.id),
        )
    })?;
    let claimed_json = serde_json::to_string(payload).map_err(|error| {
        (
            "capture_async_receipt_invalid".to_string(),
            format!("cannot serialize claimed capture task payload: {error}"),
        )
    })?;
    let claimed_digest = hex::encode(Sha256::digest(claimed_json.as_bytes()));
    if claimed_digest != expected_digest {
        return Err((
            "capture_async_receipt_invalid".to_string(),
            format!(
                "capture run {} claimed payload does not match its durable receipt",
                run.id
            ),
        ));
    }

    let durable_task = task_queue.get_task(task_id).await.map_err(|error| {
        (
            "capture_async_receipt_invalid".to_string(),
            format!("cannot read durable capture task {task_id}: {error}"),
        )
    })?;
    let durable_digest = hex::encode(Sha256::digest(durable_task.payload_json.as_bytes()));
    if durable_digest != expected_digest {
        return Err((
            "capture_async_receipt_invalid".to_string(),
            format!(
                "capture run {} durable task payload does not match its receipt",
                run.id
            ),
        ));
    }

    if run.async_task_state == AsyncTaskState::Reserved {
        // Cross-database enqueue order is main Reserved -> tasks.db insert ->
        // main Enqueued. A worker can legitimately claim in that final narrow
        // window, or after a crash immediately after the tasks.db commit. The
        // exact stable id plus both payload digests prove this is the reserved
        // intent, so atomically reconcile it before provider dispatch. Missing
        // or mismatched rows never reach this transition.
        run = capture_store
            .mark_async_task_enqueued(&run.id, task_id)
            .map_err(|error| {
                (
                    "capture_async_receipt_invalid".to_string(),
                    format!("cannot reconcile reserved capture async task: {error}"),
                )
            })?;
    }
    if run.async_task_state != AsyncTaskState::Enqueued
        || run.async_task_id.as_deref() != Some(task_id)
        || run.async_task_payload_sha256.as_deref() != Some(expected_digest.as_str())
    {
        return Err((
            "capture_async_receipt_invalid".to_string(),
            format!(
                "capture run {} did not reach an exact Enqueued receipt",
                run.id
            ),
        ));
    }
    Ok(())
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum StartupCaptureAsyncReceiptOutcome {
    Claimable,
    ProviderReceiptReady,
    ProviderReceiptBlocked { reason: String },
    Completed,
    FailedClosed { reason: String },
}

fn fail_close_startup_capture_receipt(
    capture_store: &NotebookCaptureStore,
    run: &vt_store::NotebookCaptureRun,
    reason: impl Into<String>,
) -> Result<StartupCaptureAsyncReceiptOutcome, String> {
    let reason = reason.into();
    let recorded_task_id = run.async_task_id.as_deref().ok_or_else(|| {
        format!(
            "capture run {} has no task id to fail-close its async receipt",
            run.id
        )
    })?;
    capture_store
        .mark_async_task_terminal_for_session(&run.session_id, recorded_task_id, false)
        .map_err(|error| {
            format!(
                "cannot fail-close capture run {} async receipt: {error}",
                run.id
            )
        })?;
    Ok(StartupCaptureAsyncReceiptOutcome::FailedClosed { reason })
}

/// Reconcile the cross-database async receipt before the worker starts.
///
/// `Pending` is handled by the explicit intent-enqueue path. Before consulting
/// tasks.db, startup inspects the main-database provider receipt. Once that
/// immutable receipt exists, tasks.db is only a rebuildable local scheduler:
/// a missing row is recreated with the same stable id and a failed row may be
/// completed locally. Neither case is allowed to call the provider again or
/// rewrite the capture run as failed.
pub(crate) async fn reconcile_capture_async_task_receipt_on_startup(
    capture_store: &NotebookCaptureStore,
    task_queue: &TaskQueue,
    run: &vt_store::NotebookCaptureRun,
    expected_task_id: &str,
    expected_payload: &TaskPayload,
    expected_payload_sha256: &str,
) -> Result<StartupCaptureAsyncReceiptOutcome, String> {
    if !matches!(
        run.async_task_state,
        AsyncTaskState::Reserved | AsyncTaskState::Enqueued
    ) {
        return Err(format!(
            "capture run {} async receipt is {:?}, expected Reserved or Enqueued",
            run.id, run.async_task_state
        ));
    }

    let provider_receipt = match run.async_task_id.as_deref() {
        Some(recorded_task_id) => {
            match capture_store.get_async_provider_receipt(&run.session_id, recorded_task_id) {
                Ok(receipt) => receipt,
                Err(error) => {
                    return Ok(StartupCaptureAsyncReceiptOutcome::ProviderReceiptBlocked {
                        reason: format!(
                            "capture_provider_receipt_invalid: capture run {} receipt failed integrity verification: {error}",
                            run.id
                        ),
                    });
                }
            }
        }
        None => None,
    };

    if run.async_task_id.as_deref() != Some(expected_task_id)
        || run.async_task_payload_sha256.as_deref() != Some(expected_payload_sha256)
    {
        if provider_receipt.is_some() {
            return Ok(StartupCaptureAsyncReceiptOutcome::ProviderReceiptBlocked {
                reason: "provider receipt exists but its immutable task intent no longer matches"
                    .to_string(),
            });
        }
        return fail_close_startup_capture_receipt(
            capture_store,
            run,
            "receipt identity or payload digest does not match the immutable capture intent",
        );
    }

    let durable_task = match task_queue.get_task(expected_task_id).await {
        Ok(task) => task,
        Err(TaskQueueError::NotFound(_)) if provider_receipt.is_some() => {
            task_queue
                .enqueue_with_stable_id(
                    expected_task_id,
                    expected_payload.clone(),
                    vt_pipeline::TaskPriority::Normal,
                )
                .await
                .map_err(|error| {
                    format!(
                        "cannot rebuild local task {} from durable provider receipt: {error}",
                        run.id
                    )
                })?;
            task_queue
                .get_task(expected_task_id)
                .await
                .map_err(|error| {
                    format!(
                        "rebuilt local task {} is unavailable after enqueue: {error}",
                        run.id
                    )
                })?
        }
        Err(error) if provider_receipt.is_some() => {
            return Ok(StartupCaptureAsyncReceiptOutcome::ProviderReceiptBlocked {
                reason: format!(
                    "provider receipt is durable but the local task queue is unavailable: {error}"
                ),
            });
        }
        Err(error) => {
            return fail_close_startup_capture_receipt(
                capture_store,
                run,
                format!("stable tasks.db row is unavailable: {error}"),
            );
        }
    };
    let durable_digest = hex::encode(Sha256::digest(durable_task.payload_json.as_bytes()));
    if durable_task.id != expected_task_id || durable_digest != expected_payload_sha256 {
        if provider_receipt.is_some() {
            return Ok(StartupCaptureAsyncReceiptOutcome::ProviderReceiptBlocked {
                reason: "provider receipt is durable but the local task row has another payload"
                    .to_string(),
            });
        }
        return fail_close_startup_capture_receipt(
            capture_store,
            run,
            "stable tasks.db row has a different identity or payload digest",
        );
    }

    if run.async_task_state == AsyncTaskState::Reserved {
        capture_store
            .mark_async_task_enqueued(&run.id, expected_task_id)
            .map_err(|error| {
                format!(
                    "cannot reconcile exact reserved capture async task {}: {error}",
                    run.id
                )
            })?;
    }

    match durable_task.status.as_str() {
        "pending" | "running" | "failed" if provider_receipt.is_some() => {
            Ok(StartupCaptureAsyncReceiptOutcome::ProviderReceiptReady)
        }
        "pending" | "running" => Ok(StartupCaptureAsyncReceiptOutcome::Claimable),
        "completed" => {
            capture_store
                .mark_async_task_terminal_for_session(&run.session_id, expected_task_id, true)
                .map_err(|error| {
                    format!(
                        "cannot close completed capture async receipt {}: {error}",
                        run.id
                    )
                })?;
            Ok(StartupCaptureAsyncReceiptOutcome::Completed)
        }
        "failed" => fail_close_startup_capture_receipt(
            capture_store,
            &capture_store
                .get_run(&run.id)
                .map_err(|error| error.to_string())?
                .ok_or_else(|| format!("capture run {} disappeared during recovery", run.id))?,
            "stable tasks.db row is terminal failed",
        ),
        other => fail_close_startup_capture_receipt(
            capture_store,
            &capture_store
                .get_run(&run.id)
                .map_err(|error| error.to_string())?
                .ok_or_else(|| format!("capture run {} disappeared during recovery", run.id))?,
            format!("stable tasks.db row has unsupported status {other}"),
        ),
    }
}

/// Close the main-DB receipt only after tasks.db itself is genuinely terminal.
/// A retryable failure leaves the receipt Enqueued so the same stable task can
/// retry without manufacturing a second upload intent.
async fn close_capture_async_receipt_if_queue_terminal(
    capture_store: &NotebookCaptureStore,
    task_queue: &TaskQueue,
    payload: &TaskPayload,
    task_id: &str,
) -> Result<(), String> {
    let TaskPayload::Transcribe { session_id, .. } = payload;
    if capture_store
        .get_run_for_session(session_id)
        .map_err(|error| error.to_string())?
        .is_none()
    {
        return Ok(());
    }
    let success = match task_queue
        .get_status(task_id)
        .await
        .map_err(|error| error.to_string())?
    {
        vt_pipeline::TaskStatus::Completed => true,
        vt_pipeline::TaskStatus::Failed => false,
        vt_pipeline::TaskStatus::Pending | vt_pipeline::TaskStatus::Running => return Ok(()),
    };
    capture_store
        .mark_async_task_terminal_for_session(session_id, task_id, success)
        .map(|_| ())
        .map_err(|error| error.to_string())
}

#[allow(clippy::enum_variant_names)]
#[derive(Debug)]
enum TaskFinalizationError {
    PrivacyCleanupFailed(String),
    QueueCompletionFailed(String),
}

impl TaskFinalizationError {
    fn code(&self) -> &'static str {
        match self {
            Self::PrivacyCleanupFailed(_) => "privacy_cleanup_failed",
            Self::QueueCompletionFailed(_) => "queue_completion_failed",
        }
    }

    fn message(&self) -> String {
        match self {
            Self::PrivacyCleanupFailed(message) => {
                format!("privacy cleanup before task completion: {message}")
            }
            Self::QueueCompletionFailed(message) => {
                format!("persist task completion: {message}")
            }
        }
    }
}

async fn finalize_successful_task(
    task_queue: &TaskQueue,
    task_id: &str,
    payload_tag: &str,
    session_id: &str,
    db_path: &Path,
    key_store: &dyn KeyProvider,
) -> Result<(), TaskFinalizationError> {
    match task_queue.get_status(task_id).await {
        Ok(TaskStatus::Running) => {}
        Ok(status) => {
            return Err(TaskFinalizationError::QueueCompletionFailed(format!(
                "task {task_id} cannot complete from {}",
                status.as_str()
            )));
        }
        Err(error) => {
            return Err(TaskFinalizationError::QueueCompletionFailed(
                error.to_string(),
            ));
        }
    }

    if payload_tag == "transcribe" {
        crate::transcribe_api::enforce_privacy_after_task(session_id, db_path, key_store)
            .map_err(TaskFinalizationError::PrivacyCleanupFailed)?;
    }

    task_queue
        .complete(task_id)
        .await
        .map_err(|e| TaskFinalizationError::QueueCompletionFailed(e.to_string()))?;

    Ok(())
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct ProviderWorkerPlan {
    slot: String,
    provider_id: String,
    key_scope: Option<String>,
    model_id: Option<String>,
}

fn provider_worker_plan_for_task(
    payload: &TaskPayload,
    privacy_level: &str,
) -> Result<ProviderWorkerPlan, (String, String)> {
    let TaskPayload::Transcribe { .. } = payload;
    let engine = CURRENT_NOTEBOOK_CAPTURE_ENGINE;
    ProviderWorkerPlan {
        slot: "async_stt".to_string(),
        provider_id: engine.provider_id.to_string(),
        key_scope: Some(engine.credential_scope.to_string()),
        model_id: Some(engine.post_stop_model_id.to_string()),
    }
    .ensure_privacy(privacy_level)
}

impl ProviderWorkerPlan {
    fn ensure_privacy(self, privacy_level: &str) -> Result<Self, (String, String)> {
        match privacy_level {
            // Retention and egress are separate controls. Reaching the worker
            // already proves an explicit frozen remote authorization; this
            // value only controls cleanup after durable transcript facts.
            "standard" | "high" | "maximum" => Ok(self),
            _ => Err((
                "privacy_state_invalid".to_string(),
                "privacy_state_invalid: session privacy level is missing or invalid".to_string(),
            )),
        }
    }
}

fn payload_privacy_level(
    payload: &TaskPayload,
    db_path: &Path,
) -> Result<String, (String, String)> {
    let TaskPayload::Transcribe { session_id, .. } = payload;
    session_privacy_level_strict(db_path, session_id)
}

fn session_privacy_level_strict(
    db_path: &Path,
    session_id: &str,
) -> Result<String, (String, String)> {
    let store = SessionMetaStore::new(db_path).map_err(|_| {
        (
            "privacy_state_unavailable".to_string(),
            "privacy_state_unavailable: cannot open durable session privacy metadata".to_string(),
        )
    })?;
    let meta = store.get_meta(session_id).map_err(|_| {
        (
            "privacy_state_unavailable".to_string(),
            "privacy_state_unavailable: session privacy metadata is missing or unreadable"
                .to_string(),
        )
    })?;
    crate::validate_frozen_session_privacy_level(meta.privacy_level).map_err(|_| {
        (
            "privacy_state_invalid".to_string(),
            "privacy_state_invalid: session privacy level is missing or invalid".to_string(),
        )
    })
}

async fn claim_next_with_provider_credential(
    task_queue: &TaskQueue,
    api_key_store: &dyn ApiKeyProvider,
    lease_seconds: u64,
) -> Result<Option<(Task, String)>, TaskQueueError> {
    // All durable MVP provider tasks are Soniox transcription tasks. Do not
    // publish a lease or consume queue ownership while the credential is
    // absent; the worker's normal polling loop automatically observes a key
    // saved later in Settings.
    let credential_scope = CURRENT_NOTEBOOK_CAPTURE_ENGINE.credential_scope;
    if !api_key_store.has(credential_scope) {
        return Ok(None);
    }

    let Some(task) = task_queue.claim_next(lease_seconds).await? else {
        return Ok(None);
    };
    let api_key = match api_key_store.get(credential_scope) {
        Ok(value) if !value.trim().is_empty() => value,
        Ok(_) | Err(_) => {
            // The key was removed between has() and get(). No provider attempt
            // occurred, so release the claim without spending retry budget.
            task_queue.release_without_retry(&task.id).await?;
            drop(task);
            return Ok(None);
        }
    };
    Ok(Some((task, api_key)))
}

struct WorkerTaskClaim {
    task: Task,
    soniox_api_key: Option<String>,
    provider_receipt_ready: bool,
}

enum WorkerPollResult {
    Claimed(WorkerTaskClaim),
    ReconciledProviderReceipt(AsyncProviderReceipt),
}

pub(crate) async fn reconcile_completed_provider_receipt_with<C>(
    task_queue: &TaskQueue,
    receipt: &AsyncProviderReceipt,
    close_main_receipt: C,
) -> Result<bool, String>
where
    C: FnOnce(&AsyncProviderReceipt) -> Result<(), String>,
{
    let task = match task_queue.get_task(&receipt.task_id).await {
        Ok(task) => task,
        Err(TaskQueueError::NotFound(_)) => return Ok(false),
        Err(error) => return Err(format!("inspect provider receipt task: {error}")),
    };
    if task.status != "completed" {
        return Ok(false);
    }
    close_main_receipt(receipt)?;
    Ok(true)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum CompletedProviderReceiptRecoveryOutcome {
    Completed,
    Cancelled,
    NotReady,
}

async fn completed_receipt_recovery_may_continue(
    task_queue: &TaskQueue,
    capture_store: &NotebookCaptureStore,
    session_cancel: &CancellationToken,
    receipt: &AsyncProviderReceipt,
) -> bool {
    !session_cancel.is_cancelled()
        && session_task_may_continue(
            capture_store,
            task_queue,
            &receipt.session_id,
            &receipt.task_id,
        )
        .await
}

/// Finish a queue-completed provider receipt while holding the same immutable
/// session ownership used by provider handlers. Delete Forever writes its
/// tombstone before cancelling this registration, then waits for it to drop;
/// consequently no FTS/Loro/callback work can outlive a completed purge.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn recover_completed_provider_receipt_with<C, F, L, K>(
    task_queue: &TaskQueue,
    capture_store: &NotebookCaptureStore,
    session_task_registry: &Arc<SessionTaskRegistry>,
    receipt: &AsyncProviderReceipt,
    close_main_receipt: C,
    project_fts: F,
    project_loro: L,
    complete_callback: K,
) -> Result<CompletedProviderReceiptRecoveryOutcome, String>
where
    C: FnOnce(&AsyncProviderReceipt) -> Result<(), String>,
    F: FnOnce(&AsyncProviderReceipt) -> Result<(), String>,
    L: FnOnce(&AsyncProviderReceipt) -> Result<(), String>,
    K: FnOnce(&AsyncProviderReceipt),
{
    let validated_receipt = capture_store
        .get_async_provider_receipt(&receipt.session_id, &receipt.task_id)
        .map_err(|error| format!("validate provider receipt before local recovery: {error}"))?
        .ok_or_else(|| "provider receipt disappeared before local recovery".to_string())?;
    let receipt = &validated_receipt;
    let Some(registration) = session_task_registry.register(&receipt.session_id) else {
        return Ok(CompletedProviderReceiptRecoveryOutcome::Cancelled);
    };
    let session_cancel = registration.cancellation_token();

    if !completed_receipt_recovery_may_continue(task_queue, capture_store, &session_cancel, receipt)
        .await
    {
        return Ok(CompletedProviderReceiptRecoveryOutcome::Cancelled);
    }
    let closed =
        match reconcile_completed_provider_receipt_with(task_queue, receipt, close_main_receipt)
            .await
        {
            Ok(closed) => closed,
            Err(error) => {
                if !completed_receipt_recovery_may_continue(
                    task_queue,
                    capture_store,
                    &session_cancel,
                    receipt,
                )
                .await
                {
                    return Ok(CompletedProviderReceiptRecoveryOutcome::Cancelled);
                }
                return Err(error);
            }
        };
    if !closed {
        return Ok(CompletedProviderReceiptRecoveryOutcome::NotReady);
    }
    if !completed_receipt_recovery_may_continue(task_queue, capture_store, &session_cancel, receipt)
        .await
    {
        return Ok(CompletedProviderReceiptRecoveryOutcome::Cancelled);
    }

    if let Err(error) = project_fts(receipt) {
        tracing::warn!(
            session_id = %receipt.session_id,
            task_id = %receipt.task_id,
            error = %error,
            "completed provider receipt closed; FTS projection remains locally retryable"
        );
    }
    if !completed_receipt_recovery_may_continue(task_queue, capture_store, &session_cancel, receipt)
        .await
    {
        return Ok(CompletedProviderReceiptRecoveryOutcome::Cancelled);
    }

    if let Err(error) = project_loro(receipt) {
        tracing::warn!(
            session_id = %receipt.session_id,
            task_id = %receipt.task_id,
            error = %error,
            "completed provider receipt closed; Loro projection remains locally retryable"
        );
    }
    if !completed_receipt_recovery_may_continue(task_queue, capture_store, &session_cancel, receipt)
        .await
    {
        return Ok(CompletedProviderReceiptRecoveryOutcome::Cancelled);
    }

    complete_callback(receipt);
    if !completed_receipt_recovery_may_continue(task_queue, capture_store, &session_cancel, receipt)
        .await
    {
        return Ok(CompletedProviderReceiptRecoveryOutcome::Cancelled);
    }
    Ok(CompletedProviderReceiptRecoveryOutcome::Completed)
}

/// Prefer locally recoverable provider receipts before credential-gated
/// provider work. A receipt recovery has no reason to read a key or retained
/// audio, so it remains runnable after privacy cleanup and after the user
/// removes the provider credential.
async fn claim_next_worker_task<F>(
    task_queue: &TaskQueue,
    capture_store: &NotebookCaptureStore,
    api_key_store: &dyn ApiKeyProvider,
    lease_seconds: u64,
    mut on_quarantined_task: F,
) -> Result<Option<WorkerPollResult>, String>
where
    F: FnMut(&str),
{
    let scan = capture_store
        .list_async_provider_receipts()
        .map_err(|error| format!("list durable provider receipts: {error}"))?;
    for corrupt in scan.corrupt {
        let reason = format!("capture_provider_receipt_invalid: {}", corrupt.reason);
        tracing::warn!(
            session_id = %corrupt.session_id,
            task_id = corrupt.task_id.as_deref().unwrap_or("<missing>"),
            error_code = "capture_provider_receipt_invalid",
            reason = %corrupt.reason,
            "worker quarantining corrupt provider receipt without reading credentials or retrying provider work"
        );
        if let Err(error) = capture_store
            .fail_corrupt_async_search_projection(&corrupt.session_id, corrupt.task_id.as_deref())
        {
            tracing::warn!(
                session_id = %corrupt.session_id,
                error = %error,
                "failed to persist corrupt provider receipt search projection failure"
            );
        }
        if let Some(task_id) = corrupt.task_id.as_deref() {
            on_quarantined_task(task_id);
            if let Some(_claimed) = task_queue
                .claim_by_id(task_id, lease_seconds)
                .await
                .map_err(|error| format!("claim corrupt provider receipt task: {error}"))?
            {
                task_queue
                    .fail_local_preflight(task_id, &reason)
                    .await
                    .map_err(|error| {
                        format!("quarantine corrupt provider receipt task: {error}")
                    })?;
            }
            if let Err(error) = capture_store.mark_async_task_terminal_for_session(
                &corrupt.session_id,
                task_id,
                false,
            ) {
                tracing::debug!(
                    session_id = %corrupt.session_id,
                    task_id,
                    error = %error,
                    "corrupt provider receipt main task was already terminal or concurrently purged"
                );
            }
        }
    }
    for receipt in scan.receipts {
        let Some(run) = capture_store
            .get_run_for_session(&receipt.session_id)
            .map_err(|error| format!("load provider receipt capture run: {error}"))?
        else {
            continue;
        };
        if !matches!(
            run.async_task_state,
            AsyncTaskState::Reserved | AsyncTaskState::Enqueued
        ) || run.async_task_id.as_deref() != Some(receipt.task_id.as_str())
        {
            continue;
        }
        match task_queue.get_task(&receipt.task_id).await {
            Ok(task) if task.status == "completed" => {
                return Ok(Some(WorkerPollResult::ReconciledProviderReceipt(receipt)));
            }
            Ok(_) | Err(TaskQueueError::NotFound(_)) => {}
            Err(error) => {
                return Err(format!("inspect provider receipt task: {error}"));
            }
        }
        if let Some(task) = task_queue
            .claim_by_id(&receipt.task_id, lease_seconds)
            .await
            .map_err(|error| format!("claim provider receipt task: {error}"))?
        {
            return Ok(Some(WorkerPollResult::Claimed(WorkerTaskClaim {
                task,
                soniox_api_key: None,
                provider_receipt_ready: true,
            })));
        }
    }

    let Some((task, soniox_api_key)) =
        claim_next_with_provider_credential(task_queue, api_key_store, lease_seconds)
            .await
            .map_err(|error| error.to_string())?
    else {
        return Ok(None);
    };
    Ok(Some(WorkerPollResult::Claimed(WorkerTaskClaim {
        task,
        soniox_api_key: Some(soniox_api_key),
        provider_receipt_ready: false,
    })))
}

async fn persist_task_handler_failure(
    task_queue: &TaskQueue,
    task_id: &str,
    code: &str,
    message: &str,
) -> Result<(), TaskQueueError> {
    if is_local_preflight_failure(code) {
        task_queue.fail_local_preflight(task_id, message).await
    } else {
        task_queue.fail(task_id, message).await
    }
}

fn is_local_preflight_failure(code: &str) -> bool {
    matches!(
        code,
        "capture_metadata_unavailable"
            | "capture_provider_receipt_invalid"
            | "source_audio_metadata_unavailable"
            | "source_audio_key_unavailable"
            | "source_audio_missing"
    ) || code.starts_with("capture_audio_format_")
}

/// 远端清单快照。只在有 claim 缺 id 时才拉取。
struct RemoteArtifactInventory {
    files: Vec<SonioxRemoteInventoryEntry>,
    transcriptions: Vec<SonioxRemoteInventoryEntry>,
}

impl RemoteArtifactInventory {
    /// 文件列表接口不回 client_reference_id，标签只能从文件名认。
    fn file_ids_for(&self, reference: &str) -> Vec<String> {
        let expected = format!("{reference}.wav");
        self.files
            .iter()
            .filter(|entry| entry.filename.as_deref() == Some(expected.as_str()))
            .map(|entry| entry.id.clone())
            .collect()
    }

    fn transcription_ids_for(&self, reference: &str) -> Vec<String> {
        self.transcriptions
            .iter()
            .filter(|entry| entry.client_reference_id.as_deref() == Some(reference))
            .map(|entry| entry.id.clone())
            .collect()
    }
}

/// 启动扫尾。进程被杀、断电、崩溃都会让一次转录失去删除远端工件的时机；
/// `provider_remote_artifacts` 的行是"远端可能还留着这次录音"的唯一权威，
/// 所以 worker 必须先把它们收敛，才允许派发新的 provider 任务。
///
/// 只处理本机日志过的工件——按落库的 id 删，或按 `zulangue-{task_id}` 标签
/// 在远端清单里找回"id 未及落库"的孤儿。同账号其他设备正在跑的工件不属于
/// 本机 claim，不会被碰到。
///
/// 收敛不了的行留在库里，下次启动继续重试：宁可重复删，不可漏删。
async fn sweep_orphaned_remote_artifacts(
    capture_store: &NotebookCaptureStore,
    base_url: &str,
    api_key: &str,
) {
    let claims = match capture_store.list_provider_remote_artifact_claims() {
        Ok(claims) => claims,
        Err(error) => {
            tracing::warn!(
                error = %error,
                "cannot read remote provider artifact journal; skipping startup sweep"
            );
            return;
        }
    };
    if claims.is_empty() {
        return;
    }
    tracing::info!(
        claims = claims.len(),
        "sweeping remote provider artifacts left behind by an interrupted transcription"
    );

    let endpoint = SonioxRemoteEndpoint { base_url, api_key };

    // 只要有一行缺 id，就得靠远端清单按标签找回。清单拉不到时不能把
    // "没找到"当成"远端没有"，那一轮直接放弃，claim 行留到下次启动。
    let needs_inventory = claims
        .iter()
        .any(|claim| claim.remote_file_id.is_none() || claim.remote_transcription_id.is_none());
    let inventory = if needs_inventory {
        match load_remote_artifact_inventory(&endpoint).await {
            Ok(inventory) => Some(inventory),
            Err(error) => {
                tracing::warn!(
                    error = %error,
                    "cannot list remote provider artifacts; startup sweep retries on next launch"
                );
                None
            }
        }
    } else {
        None
    };

    for claim in claims {
        let mut transcription_ids = claim
            .remote_transcription_id
            .iter()
            .cloned()
            .collect::<Vec<_>>();
        let mut file_ids = claim.remote_file_id.iter().cloned().collect::<Vec<_>>();
        let mut resolved = transcription_ids.len() == 1 && file_ids.len() == 1;
        if let Some(inventory) = inventory.as_ref() {
            for id in inventory.transcription_ids_for(&claim.client_reference_id) {
                if !transcription_ids.contains(&id) {
                    transcription_ids.push(id);
                }
            }
            for id in inventory.file_ids_for(&claim.client_reference_id) {
                if !file_ids.contains(&id) {
                    file_ids.push(id);
                }
            }
            // 清单到手就能断言"远端还剩什么"，没匹配到即为已经干净。
            resolved = true;
        }
        if !resolved {
            continue;
        }

        // 先删转录任务再删文件：文件可能被仍存在的转录任务引用。
        let mut deleted = true;
        for id in &transcription_ids {
            if let Err(error) = soniox_async_delete_remote_transcription(&endpoint, id).await {
                deleted = false;
                tracing::warn!(
                    task_id = %claim.task_id,
                    error = %error,
                    "failed to delete orphaned remote transcription"
                );
            }
        }
        for id in &file_ids {
            if let Err(error) = soniox_async_delete_remote_file(&endpoint, id).await {
                deleted = false;
                tracing::warn!(
                    task_id = %claim.task_id,
                    error = %error,
                    "failed to delete orphaned remote file"
                );
            }
        }
        if !deleted {
            continue;
        }
        if let Err(error) = capture_store.close_provider_remote_artifact_claim(&claim.task_id) {
            tracing::warn!(
                task_id = %claim.task_id,
                error = %error,
                "swept remote provider artifacts but could not close the journal claim"
            );
            continue;
        }
        tracing::info!(
            task_id = %claim.task_id,
            transcriptions = transcription_ids.len(),
            files = file_ids.len(),
            "swept orphaned remote provider artifacts"
        );
    }
}

async fn load_remote_artifact_inventory(
    endpoint: &SonioxRemoteEndpoint<'_>,
) -> Result<RemoteArtifactInventory, vt_stt::SttError> {
    let files = soniox_async_list_remote_files(endpoint).await?;
    let transcriptions = soniox_async_list_remote_transcriptions(endpoint).await?;
    Ok(RemoteArtifactInventory {
        files,
        transcriptions,
    })
}

/// 启动 worker(runtime spawn + cancel 控制)
#[allow(clippy::too_many_arguments)]
pub fn spawn_worker(
    runtime: &Runtime,
    task_queue: Arc<TaskQueue>,
    callbacks: Arc<Mutex<HashMap<String, Arc<dyn FfiTaskCallback>>>>,
    key_store: Arc<dyn KeyProvider>,
    api_key_store: Arc<dyn ApiKeyProvider>,
    _data_dir: PathBuf,
    db_path: PathBuf,
    notebook_runtime: Option<NotebookTranscriptProjector>,
    notebook_capture_store: NotebookCaptureStore,
    session_task_registry: Arc<SessionTaskRegistry>,
    provider_credential_bootstrap: Arc<ProviderCredentialBootstrapGate>,
    cancel: CancellationToken,
) {
    const TASK_LEASE_SECONDS: u64 = 2;
    const TASK_HEARTBEAT_SECONDS: u64 = 1;
    runtime.spawn(async move {
        tracing::info!("task worker waiting for provider credential bootstrap");
        if !provider_credential_bootstrap.wait_or_cancelled(&cancel).await {
            tracing::info!("task worker cancelled before provider credential bootstrap");
            return;
        }
        tracing::info!("task worker started");
        // 扫尾要在派发任何 provider 任务之前跑完，否则会把本进程刚开的
        // claim 当成孤儿。凭据可能稍后才在设置里保存，所以一直等到第一次
        // 拿得到 key 为止。
        let mut swept = false;
        loop {
            tokio::select! {
                _ = cancel.cancelled() => {
                    tracing::info!("task worker cancelled");
                    break;
                }
                _ = tokio::time::sleep(Duration::from_millis(200)) => {
                    if !swept {
                        let credential_scope = CURRENT_NOTEBOOK_CAPTURE_ENGINE.credential_scope;
                        let api_key = match api_key_store.get(credential_scope) {
                            Ok(value) if !value.trim().is_empty() => Some(value),
                            Ok(_) | Err(_) => None,
                        };
                        let Some(api_key) = api_key else {
                            continue;
                        };
                        sweep_orphaned_remote_artifacts(
                            &notebook_capture_store,
                            CURRENT_NOTEBOOK_CAPTURE_ENGINE.async_api_base_url,
                            &api_key,
                        )
                        .await;
                        swept = true;
                        continue;
                    }
                    match claim_next_worker_task(
                        task_queue.as_ref(),
                        &notebook_capture_store,
                        api_key_store.as_ref(),
                        TASK_LEASE_SECONDS,
                        |task_id| {
                            // Integrity failures are local quarantine events,
                            // not provider or user-visible task callbacks.
                            callbacks.lock().unwrap().remove(task_id);
                        },
                    )
                    .await
                    {
                        Ok(Some(WorkerPollResult::ReconciledProviderReceipt(receipt))) => {
                            let task_id = receipt.task_id.clone();
                            let recovery = recover_completed_provider_receipt_with(
                                task_queue.as_ref(),
                                &notebook_capture_store,
                                &session_task_registry,
                                &receipt,
                                |receipt| {
                                    notebook_capture_store
                                        .mark_async_task_terminal_for_session(
                                            &receipt.session_id,
                                            &receipt.task_id,
                                            true,
                                        )
                                        .map(|_| ())
                                        .map_err(|error| error.to_string())
                                },
                                |receipt| {
                                    crate::transcribe_api::project_transcribe_search_receipt(
                                        &db_path,
                                        receipt,
                                    )
                                },
                                |receipt| {
                                    if let Some(projector) = notebook_runtime.as_ref() {
                                        projector
                                            .project_persisted_async_transcript(
                                                &notebook_capture_store,
                                                &receipt.session_id,
                                            )
                                            .map(|_| ())
                                            .map_err(|error| error.to_string())
                                    } else {
                                        Ok(())
                                    }
                                },
                                |receipt| {
                                    if let Some(callback) =
                                        callbacks.lock().unwrap().remove(&receipt.task_id)
                                    {
                                        callback.on_complete(
                                            receipt.task_id.clone(),
                                            receipt.result_json.clone(),
                                        );
                                    }
                                },
                            )
                            .await;
                            match recovery {
                                Ok(CompletedProviderReceiptRecoveryOutcome::Completed) => {}
                                Ok(CompletedProviderReceiptRecoveryOutcome::Cancelled) => {
                                    callbacks.lock().unwrap().remove(&task_id);
                                }
                                Ok(CompletedProviderReceiptRecoveryOutcome::NotReady) => {
                                    tracing::debug!(
                                        task_id,
                                        "completed provider receipt changed before local recovery"
                                    );
                                }
                                Err(error) => {
                                    tracing::warn!(
                                        task_id,
                                        error = %error,
                                        "completed provider receipt recovery remains retryable"
                                    );
                                }
                            }
                        }
                        Ok(Some(WorkerPollResult::Claimed(WorkerTaskClaim {
                            task,
                            soniox_api_key,
                            provider_receipt_ready,
                        }))) => {
                            let task_id = task.id.clone();
                            let payload_tag = task.payload.type_tag();
                            let session_id = task.payload.session_id().to_string();
                            let task_registry_owner_id =
                                task_registry_owner_id(&task_id, &task.payload);
                            let callback = callbacks
                                .lock()
                                .unwrap()
                                .get(&task_id)
                                .cloned();
                            let session_registration =
                                match session_task_registry.register(&task_registry_owner_id) {
                                    Some(registration) => registration,
                                    None => {
                                        if let Err(error) = task_queue.purge_task(&task_id).await {
                                            tracing::warn!(
                                                owner_id = task_registry_owner_id,
                                                task_id,
                                                error = %error,
                                                "failed to remove task for process-blocked owner"
                                            );
                                        }
                                        callbacks.lock().unwrap().remove(&task_id);
                                        drop(task);
                                        continue;
                                    }
                                };
                            let session_cancel = session_registration.cancellation_token();
                            if !session_task_may_continue(
                                &notebook_capture_store,
                                task_queue.as_ref(),
                                &task_registry_owner_id,
                                &task_id,
                            )
                            .await
                            {
                                callbacks.lock().unwrap().remove(&task_id);
                                drop(session_registration);
                                drop(task);
                                continue;
                            }
                            if let Err((code, message)) = verify_capture_async_task_receipt(
                                &notebook_capture_store,
                                task_queue.as_ref(),
                                &task.payload,
                                &task_id,
                                provider_receipt_ready,
                            )
                            .await
                            {
                                if provider_receipt_ready {
                                    tracing::warn!(
                                        session_id,
                                        task_id,
                                        error = %message,
                                        "durable provider result is preserved after local receipt validation failure"
                                    );
                                    if let Some(callback) = &callback {
                                        callback.on_progress(
                                            task_id.clone(),
                                            "local_recovery_blocked".to_string(),
                                            90.0,
                                        );
                                    }
                                    drop(session_registration);
                                    drop(task);
                                    continue;
                                }
                                tracing::warn!(
                                    session_id,
                                    task_id,
                                    error = %message,
                                    "capture async task receipt rejected before provider dispatch"
                                );
                                if let Err(error) = task_queue
                                    .fail_local_preflight(&task_id, &message)
                                    .await
                                {
                                    tracing::warn!(
                                        task_id,
                                        error = %error,
                                        "failed to quarantine rejected capture async task"
                                    );
                                }
                                if let Err(error) = close_capture_async_receipt_if_queue_terminal(
                                    &notebook_capture_store,
                                    task_queue.as_ref(),
                                    &task.payload,
                                    &task_id,
                                )
                                .await
                                {
                                    tracing::warn!(
                                        session_id,
                                        task_id,
                                        error = %error,
                                        "failed to close rejected capture async receipt"
                                    );
                                }
                                if matches!(
                                    task_queue.get_status(&task_id).await,
                                    Ok(vt_pipeline::TaskStatus::Failed)
                                ) {
                                    if let Some(callback) = &callback {
                                        callback.on_error(task_id.clone(), code, message);
                                    }
                                    callbacks.lock().unwrap().remove(&task_id);
                                }
                                drop(session_registration);
                                drop(task);
                                continue;
                            }
                            if !provider_receipt_ready {
                            let privacy_level = match payload_privacy_level(&task.payload, &db_path) {
                                Ok(level) => level,
                                Err((code, msg)) => {
                                    if let Err(error) = task_queue
                                        .fail_local_preflight(&task_id, &msg)
                                        .await
                                    {
                                        tracing::warn!(
                                            task_id,
                                            error = %error,
                                            "failed to persist invalid privacy state rejection"
                                        );
                                    }
                                    if let Err(error) = close_capture_async_receipt_if_queue_terminal(
                                        &notebook_capture_store,
                                        task_queue.as_ref(),
                                        &task.payload,
                                        &task_id,
                                    )
                                    .await
                                    {
                                        tracing::warn!(
                                            session_id,
                                            task_id,
                                            error = %error,
                                            "failed to close privacy-invalid capture async receipt"
                                        );
                                    }
                                    if matches!(
                                        task_queue.get_status(&task_id).await,
                                        Ok(vt_pipeline::TaskStatus::Failed)
                                    ) {
                                        if let Some(cb) = &callback {
                                            cb.on_error(task_id.clone(), code, msg);
                                        }
                                        callbacks.lock().unwrap().remove(&task_id);
                                    }
                                    drop(session_registration);
                                    drop(task);
                                    continue;
                                }
                            };
                            let _provider_plan = match provider_worker_plan_for_task(&task.payload, &privacy_level) {
                                Ok(plan) => plan,
                                Err((code, msg)) => {
                                    if let Err(e) = task_queue
                                        .fail_local_preflight(&task_id, &msg)
                                        .await
                                    {
                                        tracing::warn!("queue.local_preflight privacy gate persist fail: {e}");
                                    }
                                    let is_terminal = matches!(
                                        task_queue.get_status(&task_id).await,
                                        Ok(vt_pipeline::TaskStatus::Failed)
                                    );
                                    if is_terminal {
                                        if let Err(error) = close_capture_async_receipt_if_queue_terminal(
                                            &notebook_capture_store,
                                            task_queue.as_ref(),
                                            &task.payload,
                                            &task_id,
                                        )
                                        .await
                                        {
                                            tracing::warn!(
                                                session_id,
                                                task_id,
                                                error = %error,
                                                "failed to close privacy-rejected capture async receipt"
                                            );
                                        }
                                        if let Some(cb) = &callback {
                                            cb.on_error(task_id.clone(), code, msg);
                                        }
                                        callbacks.lock().unwrap().remove(&task_id);
                                    }
                                    drop(session_registration);
                                    drop(task);
                                    continue;
                                }
                            };
                            }
                            if session_cancel.is_cancelled()
                                || !session_task_may_continue(
                                    &notebook_capture_store,
                                    task_queue.as_ref(),
                                    &task_registry_owner_id,
                                    &task_id,
                                )
                                .await
                            {
                                callbacks.lock().unwrap().remove(&task_id);
                                drop(session_registration);
                                drop(task);
                                continue;
                            }
                            let lease_cancel = CancellationToken::new();
                            let heartbeat_queue = task_queue.clone();
                            let heartbeat_task_id = task_id.clone();
                            let heartbeat_cancel = lease_cancel.clone();
                            let heartbeat_handle = tokio::spawn(async move {
                                let mut interval = tokio::time::interval(Duration::from_secs(TASK_HEARTBEAT_SECONDS));
                                interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
                                loop {
                                    tokio::select! {
                                        _ = heartbeat_cancel.cancelled() => break,
                                        _ = interval.tick() => {
                                            if let Err(e) = heartbeat_queue
                                                .heartbeat(&heartbeat_task_id, TASK_LEASE_SECONDS)
                                                .await
                                            {
                                                tracing::debug!("task heartbeat stopped for {heartbeat_task_id}: {e}");
                                                break;
                                            }
                                        }
                                    }
                                }
                            });

                            // 与旧裸 spawn 实现对齐: 先发一个 "starting" 0%,
                            // 让 UI 第一时间看到任务已起。下游 handler 再按阶段
                            // 发具体 progress。
                            if let Some(cb) = &callback {
                                cb.on_progress(
                                    task_id.clone(),
                                    "starting".to_string(),
                                    0.0,
                                );
                            }

                            // panic 保护: dispatch 在 inner_handle 里跑,
                            // panic 不会挂掉 worker loop。join_err.is_panic()
                            // 区分 panic / 正常错误。
                            let payload_clone = task.payload.clone();
                            let callback_clone = callback.clone();
                            let key_store_clone = key_store.clone();
                            let soniox_api_key_clone = soniox_api_key;
                            let db_clone = db_path.clone();
                            let cancel_clone = session_cancel.clone();
                            let tid_clone = task_id.clone();
                            let cancellation_policy = if matches!(
                                &payload_clone,
                                TaskPayload::Transcribe { .. }
                            ) {
                                HandlerCancellationPolicy::AwaitOwnedChildren
                            } else {
                                HandlerCancellationPolicy::AbortOuter
                            };
                            let inner_handle = tokio::spawn(async move {
                                dispatch_task(
                                    &payload_clone,
                                    &tid_clone,
                                    callback_clone,
                                    key_store_clone,
                                    soniox_api_key_clone,
                                    &db_clone,
                                    cancel_clone,
                                    None,
                                )
                                .await
                            });
                            let result = match await_handler_or_session_cancel(
                                inner_handle,
                                session_cancel.clone(),
                                cancellation_policy,
                            )
                            .await
                            {
                                TaskHandlerJoinOutcome::Finished(result) => result,
                                TaskHandlerJoinOutcome::SessionCancelled => {
                                    callbacks.lock().unwrap().remove(&task_id);
                                    lease_cancel.cancel();
                                    let _ = heartbeat_handle.await;
                                    drop(session_registration);
                                    drop(task);
                                    continue;
                                }
                            };
                            // Provider handlers persist their output before
                            // returning. Re-check before any projection or
                            // queue completion; a purge that raced the handler
                            // either cancelled it above or now owns cleanup of
                            // the just-produced artifact.
                            if !session_task_may_continue(
                                &notebook_capture_store,
                                task_queue.as_ref(),
                                &task_registry_owner_id,
                                &task_id,
                            )
                            .await
                            {
                                callbacks.lock().unwrap().remove(&task_id);
                                lease_cancel.cancel();
                                let _ = heartbeat_handle.await;
                                drop(session_registration);
                                drop(task);
                                continue;
                            }
                            match result {
                                Ok(complete_json) => {
                                    // Provider success is finalized first. The
                                    // independently retryable local Loro
                                    // projection must never turn a successful
                                    // Soniox task into a remote failure/retry.
                                    match finalize_successful_task(
                                        task_queue.as_ref(),
                                        &task_id,
                                        payload_tag,
                                        &session_id,
                                        &db_path,
                                        key_store.as_ref(),
                                    )
                                    .await
                                    {
                                    Ok(()) => {
                                        match close_capture_async_receipt_if_queue_terminal(
                                            &notebook_capture_store,
                                            task_queue.as_ref(),
                                            &task.payload,
                                            &task_id,
                                        )
                                        .await
                                        {
                                            Ok(()) => {
                                                if session_task_may_continue(
                                                    &notebook_capture_store,
                                                    task_queue.as_ref(),
                                                    &task_registry_owner_id,
                                                    &task_id,
                                                )
                                                .await
                                                {
                                                    if let Some(projector) = notebook_runtime.clone()
                                                    {
                                                        if let Err(error) = projector
                                                            .project_persisted_async_transcript(
                                                                &notebook_capture_store,
                                                                &session_id,
                                                            )
                                                        {
                                                            tracing::warn!(
                                                                session_id,
                                                                task_id,
                                                                error = %error,
                                                                "provider completed; local async projection remains retryable"
                                                            );
                                                        }
                                                    }
                                                }
                                                match notebook_capture_store
                                                    .get_async_provider_receipt(
                                                        &session_id,
                                                        &task_id,
                                                    )
                                                {
                                                    Ok(Some(receipt))
                                                        if receipt.result_json == complete_json =>
                                                    {
                                                        if let Some(cb) = &callback {
                                                            cb.on_complete(
                                                                task_id.clone(),
                                                                receipt.result_json,
                                                            );
                                                        }
                                                    }
                                                    Ok(Some(_)) => tracing::warn!(
                                                        session_id,
                                                        task_id,
                                                        error_code = "capture_provider_receipt_invalid",
                                                        "durable provider result changed before callback; suppressing callback"
                                                    ),
                                                    Ok(None) => tracing::warn!(
                                                        session_id,
                                                        task_id,
                                                        error_code = "capture_provider_receipt_invalid",
                                                        "durable provider receipt disappeared before callback; suppressing callback"
                                                    ),
                                                    Err(error) => tracing::warn!(
                                                        session_id,
                                                        task_id,
                                                        error_code = "capture_provider_receipt_invalid",
                                                        error = %error,
                                                        "durable provider receipt failed integrity verification before callback; suppressing callback"
                                                    ),
                                                }
                                                callbacks.lock().unwrap().remove(&task_id);
                                            }
                                            Err(receipt_error) => {
                                                tracing::warn!(
                                                    session_id,
                                                    task_id,
                                                    error = %receipt_error,
                                                    "task completed but capture async receipt did not close"
                                                );
                                                match notebook_capture_store
                                                    .get_async_provider_receipt(
                                                        &session_id,
                                                        &task_id,
                                                    )
                                                {
                                                    Ok(Some(_)) => {
                                                        if let Some(cb) = &callback {
                                                            cb.on_progress(
                                                                task_id.clone(),
                                                                "local_recovery_pending".to_string(),
                                                                99.0,
                                                            );
                                                        }
                                                    }
                                                    Ok(None) | Err(_) => {
                                                        callbacks.lock().unwrap().remove(&task_id);
                                                    }
                                                }
                                            }
                                        }
                                    }
                                    Err(error) => {
                                        let code = error.code().to_string();
                                        let msg = error.message();
                                        tracing::warn!(
                                            session_id,
                                            task_id,
                                            error_code = code,
                                            error = %msg,
                                            "provider result is durable; local finalization remains retryable"
                                        );
                                        match notebook_capture_store
                                            .get_async_provider_receipt(&session_id, &task_id)
                                        {
                                            Ok(Some(_)) => {
                                                if let Some(cb) = &callback {
                                                    cb.on_progress(
                                                        task_id.clone(),
                                                        "local_recovery_pending".to_string(),
                                                        95.0,
                                                    );
                                                }
                                            }
                                            Ok(None) | Err(_) => {
                                                callbacks.lock().unwrap().remove(&task_id);
                                            }
                                        }
                                    }
                                }
                                }
                                Err((code, msg)) => {
                                    tracing::warn!(
                                        "task {task_id} failed: {code} - {msg}"
                                    );
                                    let mut receipt_integrity_failed =
                                        code == "capture_provider_receipt_invalid";
                                    let durable_provider_receipt = match notebook_capture_store
                                        .get_async_provider_receipt(&session_id, &task_id)
                                    {
                                        Ok(receipt) => receipt.is_some(),
                                        Err(error @ NotebookCaptureStoreError::CorruptData(_)) => {
                                            receipt_integrity_failed = true;
                                            tracing::warn!(
                                                session_id,
                                                task_id,
                                                error_code = "capture_provider_receipt_invalid",
                                                error = %error,
                                                "corrupt provider receipt is being quarantined without callback or provider retry"
                                            );
                                            false
                                        }
                                        Err(error) if receipt_integrity_failed => {
                                            tracing::warn!(
                                                session_id,
                                                task_id,
                                                error_code = "capture_provider_receipt_invalid",
                                                error = %error,
                                                "invalid provider receipt is being quarantined without callback or provider retry"
                                            );
                                            false
                                        }
                                        Err(error) => {
                                            tracing::warn!(
                                                session_id,
                                                task_id,
                                                error = %error,
                                                "cannot inspect provider receipt after handler error; preserving task for recovery"
                                            );
                                            true
                                        }
                                    };
                                    if durable_provider_receipt {
                                        if let Some(cb) = &callback {
                                            cb.on_progress(
                                                task_id.clone(),
                                                "local_recovery_pending".to_string(),
                                                90.0,
                                            );
                                        }
                                        lease_cancel.cancel();
                                        let _ = heartbeat_handle.await;
                                        drop(session_registration);
                                        drop(task);
                                        continue;
                                    }
                                    let persist_failure = persist_task_handler_failure(
                                        task_queue.as_ref(),
                                        &task_id,
                                        &code,
                                        &msg,
                                    )
                                    .await;
                                    if let Err(error) = persist_failure {
                                        tracing::warn!(
                                            task_id,
                                            %error,
                                            "persist task failure state failed"
                                        );
                                    }
                                    // 判断是否终止(失败到 max_retries)还是会重试
                                    let is_terminal = matches!(
                                        task_queue.get_status(&task_id).await,
                                        Ok(vt_pipeline::TaskStatus::Failed)
                                    );
                                    if is_terminal {
                                        if let Err(receipt_error) =
                                            close_capture_async_receipt_if_queue_terminal(
                                                &notebook_capture_store,
                                                task_queue.as_ref(),
                                                &task.payload,
                                                &task_id,
                                            )
                                            .await
                                        {
                                            tracing::warn!(
                                                session_id,
                                                task_id,
                                                error = %receipt_error,
                                                "failed to close provider-failed capture async receipt"
                                            );
                                        }
                                        if !receipt_integrity_failed {
                                            if let Some(cb) = &callback {
                                            cb.on_error(task_id.clone(), code, msg);
                                            }
                                        }
                                        callbacks.lock().unwrap().remove(&task_id);
                                    }
                                    // else: 仍是 pending,下一轮再拿(callback 保留)
                                }
                            }

                            lease_cancel.cancel();
                            let _ = heartbeat_handle.await;
                            // drop Task → release semaphore permit
                            drop(session_registration);
                            drop(task);
                        }
                        Ok(None) => { /* 无任务 / 并发已满,继续 sleep */ }
                        Err(e) => {
                            tracing::warn!("task_queue.dequeue error: {e}");
                        }
                    }
                }
            }
        }
    });
}

/// 分发一个 task 到对应 handler。返回 Ok(json_result) 给 on_complete,
/// 或 Err((code, message)) 给 on_error / queue.fail。
#[allow(clippy::too_many_arguments)]
async fn dispatch_task(
    payload: &TaskPayload,
    task_id: &str,
    callback: Option<Arc<dyn FfiTaskCallback>>,
    key_store: Arc<dyn KeyProvider>,
    soniox_api_key: Option<String>,
    db_path: &Path,
    cancel: CancellationToken,
    provider_attempt_observer: Option<Arc<dyn Fn() + Send + Sync>>,
) -> Result<String, (String, String)> {
    // callback 可能为 None（例如复制/恢复的任务没有前端监听）；给一个
    // no-op 占位，下游函数按当前签名需要 Arc<dyn FfiTaskCallback>。
    let cb: Arc<dyn FfiTaskCallback> = callback.unwrap_or_else(|| Arc::new(NoopCallback));

    match payload {
        TaskPayload::Transcribe {
            session_id,
            language_hint,
            ..
        } => {
            let capture_store = NotebookCaptureStore::new(db_path).map_err(|error| {
                (
                    "capture_metadata_unavailable".to_string(),
                    format!("open capture store: {error}"),
                )
            })?;
            if let Some(receipt) = capture_store
                .get_async_provider_receipt(session_id, task_id)
                .map_err(|error| {
                    (
                        "capture_provider_receipt_invalid".to_string(),
                        format!("load provider success receipt: {error}"),
                    )
                })?
            {
                verify_post_stop_provider_receipt(&capture_store, &receipt)?;
                cb.on_progress(
                    task_id.to_string(),
                    "recovering_provider_result".into(),
                    90.0,
                );
                if let Err(error) =
                    crate::transcribe_api::project_transcribe_search_receipt(db_path, &receipt)
                {
                    tracing::warn!(
                        session_id,
                        task_id,
                        error = %error,
                        "provider receipt recovered; local FTS projection remains retryable"
                    );
                }
                return Ok(receipt.result_json);
            }

            let soniox_api_key = soniox_api_key.ok_or_else(|| {
                (
                    "provider_credential_unavailable".to_string(),
                    "Soniox credential is unavailable before provider dispatch".to_string(),
                )
            })?;

            // 预 load 必要数据
            let session_meta = SessionMetaStore::new(db_path).map_err(|e| {
                (
                    "source_audio_metadata_unavailable".to_string(),
                    format!("open source audio metadata: {e}"),
                )
            })?;
            let meta = session_meta.get_meta(session_id).map_err(|_| {
                (
                    "source_audio_metadata_unavailable".to_string(),
                    format!("session meta not found: {session_id}"),
                )
            })?;
            let audio_format = immutable_capture_audio_format(&capture_store, &meta, session_id)?;
            let run = capture_store
                .get_run_for_session(session_id)
                .map_err(|error| {
                    (
                        "context_snapshot_unavailable".to_string(),
                        format!("load capture run for Context snapshot: {error}"),
                    )
                })?
                .ok_or_else(|| {
                    (
                        "context_snapshot_unavailable".to_string(),
                        format!("capture session {session_id} disappeared before Context load"),
                    )
                })?;
            let context_store =
                ContextPackStore::new(db_path, key_store.clone()).map_err(|error| {
                    (
                        "context_snapshot_unavailable".to_string(),
                        format!("open Context snapshot store: {error}"),
                    )
                })?;
            let frozen_context = context_store.load_run_snapshot(&run.id).map_err(|error| {
                (
                    "context_snapshot_unavailable".to_string(),
                    format!("load frozen Context snapshot: {error}"),
                )
            })?;
            let key_id = meta.key_id.ok_or_else(|| {
                (
                    "source_audio_key_unavailable".to_string(),
                    "session has no encryption key".to_string(),
                )
            })?;
            let aes_key = key_store.load_key(&key_id).map_err(|e| {
                (
                    "source_audio_key_unavailable".to_string(),
                    format!("load source audio key: {e}"),
                )
            })?;
            let chunk_paths = retained_source_audio_chunk_paths(&session_meta, session_id)?;
            if chunk_paths.is_empty() {
                return Err((
                    "source_audio_missing".to_string(),
                    "capture run has no encrypted audio chunks".to_string(),
                ));
            }
            let provider_capture_store = capture_store.clone();
            let provider_session_id = session_id.clone();
            let provider_dispatch_gate: ProviderDispatchGate = Arc::new(move || {
                let engine = CURRENT_NOTEBOOK_CAPTURE_ENGINE;
                provider_capture_store
                    .claim_provider_provenance(
                        &provider_session_id,
                        CaptureProviderRole::PostStop,
                        engine.provider_id,
                        engine.post_stop_model_id,
                    )
                    .map_err(|error| {
                        (
                            "capture_provider_provenance_unavailable".to_string(),
                            format!("claim post-stop provider provenance: {error}"),
                        )
                    })?;
                if let Some(observer) = provider_attempt_observer.as_ref() {
                    observer();
                }
                Ok(())
            });
            run_transcribe_chunked_task_async(
                task_id,
                session_id,
                &soniox_api_key,
                language_hint.as_deref(),
                frozen_context
                    .as_ref()
                    .map(|value| value.context_json.as_str()),
                chunk_paths,
                aes_key,
                audio_format.sample_rate,
                audio_format.channels,
                audio_format.captured_frames,
                db_path.to_path_buf(),
                cb,
                cancel,
                provider_dispatch_gate,
            )
            .await
        }
    }
}

fn verify_post_stop_provider_receipt(
    capture_store: &NotebookCaptureStore,
    receipt: &AsyncProviderReceipt,
) -> Result<(), (String, String)> {
    let engine = CURRENT_NOTEBOOK_CAPTURE_ENGINE;
    let run = capture_store
        .get_run_for_session(&receipt.session_id)
        .map_err(|error| {
            (
                "capture_provider_receipt_invalid".to_string(),
                format!("load provider provenance for receipt: {error}"),
            )
        })?
        .ok_or_else(|| {
            (
                "capture_provider_receipt_invalid".to_string(),
                format!(
                    "capture session {} disappeared before provider receipt recovery",
                    receipt.session_id
                ),
            )
        })?;
    let stored_pair = (
        run.post_stop_provider_id.as_deref(),
        run.post_stop_model_id.as_deref(),
    );
    let receipt_pair = (receipt.provider_id.as_str(), receipt.model_id.as_str());
    // 收据是不可变的历史事实：升级前用 restream 跑出来的 post-stop 收据带
    // `stt-rt-v5`，它仍然必须可恢复，否则升级会把已完成的转录扔进隔离。
    // 新认领只接受当前模型（由 claim_provider_provenance 把关）。
    let receipt_model_supported = receipt_pair.1 == engine.post_stop_model_id
        || receipt_pair.1 == vt_store::notebook_capture_store::SONIOX_STT_RT_V5_MODEL_ID;
    if stored_pair != (Some(receipt_pair.0), Some(receipt_pair.1))
        || receipt_pair.0 != engine.provider_id
        || !receipt_model_supported
    {
        return Err((
            "capture_provider_receipt_invalid".to_string(),
            format!(
                "capture session {} has unsupported or mismatched post-stop provider provenance",
                receipt.session_id
            ),
        ));
    }
    Ok(())
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct ImmutableCaptureAudioFormat {
    sample_rate: u32,
    channels: u16,
    captured_frames: u64,
}

fn immutable_capture_audio_format(
    capture_store: &NotebookCaptureStore,
    session_meta: &SessionMeta,
    session_id: &str,
) -> Result<ImmutableCaptureAudioFormat, (String, String)> {
    let run = capture_store
        .get_run_for_session(session_id)
        .map_err(|error| {
            (
                "capture_audio_format_unavailable".to_string(),
                format!("cannot load immutable capture audio format: {error}"),
            )
        })?
        .ok_or_else(|| {
            (
                "capture_audio_format_missing".to_string(),
                format!("session {session_id} has no Notebook capture/import run"),
            )
        })?;
    let run_sample_rate = run.sample_rate.ok_or_else(|| {
        (
            "capture_audio_format_missing".to_string(),
            format!("capture run {} has no sample rate", run.id),
        )
    })?;
    let run_channels = run.channels.ok_or_else(|| {
        (
            "capture_audio_format_missing".to_string(),
            format!("capture run {} has no channel count", run.id),
        )
    })?;
    let meta_sample_rate = session_meta.sample_rate.ok_or_else(|| {
        (
            "capture_audio_format_missing".to_string(),
            format!("session {session_id} has no stored sample rate"),
        )
    })?;
    let meta_channels = session_meta.channels.ok_or_else(|| {
        (
            "capture_audio_format_missing".to_string(),
            format!("session {session_id} has no stored channel count"),
        )
    })?;
    if (run_sample_rate, run_channels) != (meta_sample_rate, meta_channels) {
        return Err((
            "capture_audio_format_mismatch".to_string(),
            format!(
                "capture run {} format {run_sample_rate}Hz/{run_channels}ch does not match session format {meta_sample_rate}Hz/{meta_channels}ch",
                run.id
            ),
        ));
    }
    if run.captured_frames == 0 {
        return Err((
            "capture_audio_format_missing".to_string(),
            format!("capture run {} has no captured frames", run.id),
        ));
    }

    Ok(ImmutableCaptureAudioFormat {
        sample_rate: run_sample_rate,
        channels: run_channels,
        captured_frames: run.captured_frames,
    })
}

fn retained_source_audio_chunk_paths(
    session_meta: &SessionMetaStore,
    session_id: &str,
) -> Result<Vec<PathBuf>, (String, String)> {
    retained_source_audio_chunk_paths_with(session_id, |session_id| {
        session_meta
            .list_audio_retention_chunks(session_id)
            .map_err(|error| error.to_string())
    })
}

fn retained_source_audio_chunk_paths_with(
    session_id: &str,
    load: impl FnOnce(&str) -> Result<Vec<AudioChunkRetentionRecord>, String>,
) -> Result<Vec<PathBuf>, (String, String)> {
    let mut chunks = load(session_id).map_err(|_| {
        (
            "source_audio_metadata_unavailable".to_string(),
            "source_audio_metadata_unavailable: encrypted audio retention ledger is unreadable"
                .to_string(),
        )
    })?;
    chunks.retain(|chunk| chunk.encrypted && !chunk.deleted);
    chunks.sort_by_key(|chunk| (chunk.start_ms, chunk.chunk_id.clone()));
    Ok(chunks
        .into_iter()
        .map(|chunk| PathBuf::from(chunk.local_path))
        .filter(|path| path.exists())
        .collect())
}

/// 占位 callback — 给没有前端监听器的恢复/复制任务使用。
/// 吞所有事件，让 handler 函数签名通过。
struct NoopCallback;

impl FfiTaskCallback for NoopCallback {
    fn on_progress(&self, _: String, _: String, _: f32) {}
    fn on_complete(&self, _: String, _: String) {}
    fn on_error(&self, _: String, _: String, _: String) {}
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

    struct RacingApiKeyStore {
        value: Mutex<Option<String>>,
        stale_has_once: AtomicBool,
    }

    impl RacingApiKeyStore {
        fn new() -> Self {
            Self {
                value: Mutex::new(None),
                stale_has_once: AtomicBool::new(false),
            }
        }

        fn force_stale_has_once(&self) {
            self.stale_has_once.store(true, Ordering::Release);
        }
    }

    impl ApiKeyProvider for RacingApiKeyStore {
        fn set(&self, _scope: &str, value: &str) -> Result<(), vt_crypto::CryptoError> {
            *self.value.lock().unwrap() = Some(value.to_string());
            Ok(())
        }

        fn get(&self, scope: &str) -> Result<String, vt_crypto::CryptoError> {
            self.value
                .lock()
                .unwrap()
                .clone()
                .ok_or_else(|| vt_crypto::CryptoError::KeyNotFound {
                    key_ref: format!("api_key:{scope}"),
                })
        }

        fn has(&self, _scope: &str) -> bool {
            self.stale_has_once.swap(false, Ordering::AcqRel)
                || self.value.lock().unwrap().is_some()
        }

        fn clear(&self, _scope: &str) -> Result<(), vt_crypto::CryptoError> {
            *self.value.lock().unwrap() = None;
            Ok(())
        }
    }

    #[tokio::test]
    async fn provider_key_absence_never_claims_or_spends_retry_and_saved_key_resumes() {
        let temp = tempfile::tempdir().unwrap();
        let queue = TaskQueue::new(&temp.path().join("tasks.db")).await.unwrap();
        let task_id = queue
            .enqueue(TaskPayload::Transcribe {
                session_id: "session-key-wait".into(),
                language_hint: None,
                remote_authorization: Some(
                    vt_pipeline::RemoteTaskAuthorization::soniox_post_recording_at(1),
                ),
            })
            .await
            .unwrap();
        let store = RacingApiKeyStore::new();

        assert!(claim_next_with_provider_credential(&queue, &store, 30)
            .await
            .unwrap()
            .is_none());
        let absent = queue.get_task(&task_id).await.unwrap();
        assert_eq!(absent.status, "pending");
        assert_eq!(absent.retry_count, 0);
        assert!(absent.lease_expires_at_ms.is_none());

        // Deterministically model clear() racing after the worker's has()
        // readiness check but before its credential load.
        store.force_stale_has_once();
        assert!(claim_next_with_provider_credential(&queue, &store, 30)
            .await
            .unwrap()
            .is_none());
        let raced = queue.get_task(&task_id).await.unwrap();
        assert_eq!(raced.status, "pending");
        assert_eq!(raced.retry_count, 0);
        assert!(raced.lease_expires_at_ms.is_none());

        store.set("soniox", "configured-after-wait").unwrap();
        let (claimed, resolved) = claim_next_with_provider_credential(&queue, &store, 30)
            .await
            .unwrap()
            .expect("saved key makes the pending task automatically claimable");
        assert_eq!(claimed.id, task_id);
        assert_eq!(claimed.retry_count, 0);
        assert_eq!(resolved, "configured-after-wait");
    }

    #[test]
    fn worker_privacy_lookup_fails_closed_for_missing_and_invalid_state() {
        let temp = tempfile::tempdir().unwrap();
        let db_path = temp.path().join("zulangue.db");
        let meta = SessionMetaStore::new(&db_path).unwrap();
        let sessions = vt_store::SessionQueryStore::new(&db_path).unwrap();
        for session_id in ["no-level", "invalid", "standard", "high", "maximum"] {
            sessions
                .insert_session(&vt_store::SessionRecord {
                    id: session_id.to_string(),
                    title: String::new(),
                    session_type: "recording".to_string(),
                    status: "completed".to_string(),
                    duration_ms: 0,
                    created_at: "2001-01-01 00:00:00".to_string(),
                    deleted_at: None,
                })
                .unwrap();
        }

        assert_eq!(
            session_privacy_level_strict(&db_path, "missing")
                .unwrap_err()
                .0,
            "privacy_state_unavailable"
        );

        meta.set_encrypted_path("no-level", "audio.enc", "key")
            .unwrap();
        assert_eq!(
            session_privacy_level_strict(&db_path, "no-level")
                .unwrap_err()
                .0,
            "privacy_state_invalid"
        );
        meta.set_privacy_level("invalid", "other").unwrap();
        assert_eq!(
            session_privacy_level_strict(&db_path, "invalid")
                .unwrap_err()
                .0,
            "privacy_state_invalid"
        );

        for level in ["standard", "high", "maximum"] {
            meta.set_privacy_level(level, level).unwrap();
            assert_eq!(
                session_privacy_level_strict(&db_path, level).unwrap(),
                level
            );
        }
    }

    #[test]
    fn provider_source_ledger_read_error_is_not_downgraded_to_empty_audio() {
        let error = retained_source_audio_chunk_paths_with("session-a", |_| {
            Err("forced retention ledger read failure".to_string())
        })
        .unwrap_err();

        assert_eq!(error.0, "source_audio_metadata_unavailable");
        assert!(error.1.contains("retention ledger is unreadable"));
    }

    #[tokio::test]
    async fn provider_source_ledger_failure_does_not_consume_provider_retry() {
        let temp = tempfile::tempdir().unwrap();
        let queue = TaskQueue::new(&temp.path().join("tasks.db")).await.unwrap();
        let task_id = queue
            .enqueue(TaskPayload::Transcribe {
                session_id: "session-ledger-error".into(),
                language_hint: None,
                remote_authorization: Some(
                    vt_pipeline::RemoteTaskAuthorization::soniox_post_recording_at(1),
                ),
            })
            .await
            .unwrap();
        let claimed = queue.claim_next(30).await.unwrap().unwrap();

        persist_task_handler_failure(
            &queue,
            &task_id,
            "source_audio_metadata_unavailable",
            "retention ledger unreadable",
        )
        .await
        .unwrap();
        drop(claimed);

        let task = queue.get_task(&task_id).await.unwrap();
        assert_eq!(task.status, "failed");
        assert_eq!(task.retry_count, 0);
        assert_eq!(
            task.error_msg.as_deref(),
            Some("retention ledger unreadable")
        );

        let provider_task_id = queue
            .enqueue(TaskPayload::Transcribe {
                session_id: "session-provider-error".into(),
                language_hint: None,
                remote_authorization: Some(
                    vt_pipeline::RemoteTaskAuthorization::soniox_post_recording_at(1),
                ),
            })
            .await
            .unwrap();
        let provider_claim = queue.claim_next(30).await.unwrap().unwrap();
        persist_task_handler_failure(
            &queue,
            &provider_task_id,
            "internal_error",
            "soniox: provider transport failed",
        )
        .await
        .unwrap();
        drop(provider_claim);
        let provider_task = queue.get_task(&provider_task_id).await.unwrap();
        assert_eq!(provider_task.status, "pending");
        assert_eq!(provider_task.retry_count, 1);
    }

    #[test]
    fn imported_48k_stereo_format_is_loaded_from_matching_run_and_session_snapshots() {
        let temp = tempfile::tempdir().unwrap();
        let main_db = temp.path().join("capture.db");
        let notebook = vt_store::NotebookStore::new(&main_db)
            .unwrap()
            .create_notebook(Some("48k import"))
            .unwrap();
        let capture_store = NotebookCaptureStore::new(&main_db).unwrap();
        let profile = capture_store.get_or_create_profile(&notebook.id).unwrap();
        capture_store
            .create_completed_import_run(
                &vt_store::notebook_capture_store::NewCompletedNotebookImportRun {
                    id: "run-48k-stereo".into(),
                    notebook_id: notebook.id,
                    session_id: "session-48k-stereo".into(),
                    audio_path: temp.path().join("audio.enc").to_string_lossy().into_owned(),
                    audio_key_ref: "key-48k-stereo".into(),
                    sample_rate: 48_000,
                    channels: 2,
                    captured_frames: 48_000,
                },
                &profile,
            )
            .unwrap();
        let meta_store = SessionMetaStore::new(&main_db).unwrap();
        meta_store
            .set_audio_format("session-48k-stereo", 48_000, 2)
            .unwrap();
        let meta = meta_store.get_meta("session-48k-stereo").unwrap();

        assert_eq!(
            immutable_capture_audio_format(&capture_store, &meta, "session-48k-stereo").unwrap(),
            ImmutableCaptureAudioFormat {
                sample_rate: 48_000,
                channels: 2,
                captured_frames: 48_000,
            }
        );

        meta_store
            .set_audio_format("session-48k-stereo", 44_100, 2)
            .unwrap();
        let mismatched = meta_store.get_meta("session-48k-stereo").unwrap();
        let error =
            immutable_capture_audio_format(&capture_store, &mismatched, "session-48k-stereo")
                .unwrap_err();
        assert_eq!(error.0, "capture_audio_format_mismatch");
    }

    async fn capture_receipt_fixture(
        state: AsyncTaskState,
        digest_override: Option<String>,
    ) -> (
        tempfile::TempDir,
        NotebookCaptureStore,
        TaskQueue,
        TaskPayload,
        String,
    ) {
        let temp = tempfile::tempdir().unwrap();
        let main_db = temp.path().join("capture.db");
        let notebook = vt_store::NotebookStore::new(&main_db)
            .unwrap()
            .create_notebook(Some("Capture receipt"))
            .unwrap();
        let store = NotebookCaptureStore::new(&main_db).unwrap();
        store.get_or_create_profile(&notebook.id).unwrap();
        let profile = store
            .update_profile(
                &notebook.id,
                0,
                &vt_store::NotebookCaptureProfileUpdate {
                    remote_realtime_enabled: false,
                    capture_mode: vt_store::CaptureMode::TranscriptionOnly,
                    language_a: "en".into(),
                    language_b: "zh".into(),
                    left_language: "en".into(),
                    right_language: "zh".into(),
                    selected_languages: vec!["en".into(), "zh".into()],
                    common_caption_language: None,
                    privacy_level: "standard".into(),
                    send_context_to_soniox: false,
                },
            )
            .unwrap();
        let run_id = format!("run-receipt-{:?}", state).to_lowercase();
        let session_id = format!("session-receipt-{:?}", state).to_lowercase();
        store
            .create_run(
                &vt_store::NewNotebookCaptureRun {
                    id: run_id.clone(),
                    notebook_id: notebook.id,
                    session_id: session_id.clone(),
                    remote_health: vt_store::RemoteHealth::Off,
                    audio_journal_path: temp
                        .path()
                        .join("capture.journal")
                        .to_string_lossy()
                        .into_owned(),
                    audio_key_ref: format!("audio-key-{run_id}"),
                    sample_rate: 16_000,
                    channels: 1,
                },
                &profile,
            )
            .unwrap();
        store
            .transition_capture(
                &run_id,
                vt_store::CaptureState::Recording,
                vt_store::CaptureState::Draining,
            )
            .unwrap();
        store
            .finalize_audio(
                &run_id,
                &temp
                    .path()
                    .join(format!("{run_id}.chunk.00000.enc"))
                    .to_string_lossy(),
                1_600,
            )
            .unwrap();
        store
            .transition_capture(
                &run_id,
                vt_store::CaptureState::Draining,
                vt_store::CaptureState::Completed,
            )
            .unwrap();
        store
            .authorize_async_transcription(&session_id, 1, Some("en"))
            .unwrap();

        let payload = TaskPayload::Transcribe {
            session_id: session_id.clone(),
            language_hint: Some("en".into()),
            remote_authorization: Some(
                vt_pipeline::RemoteTaskAuthorization::soniox_post_recording_at(1),
            ),
        };
        let task_id = format!("capture-async-{run_id}");
        let queue = TaskQueue::new(&temp.path().join("tasks.db")).await.unwrap();
        let payload_json = serde_json::to_string(&payload).unwrap();
        let digest =
            digest_override.unwrap_or_else(|| hex::encode(Sha256::digest(payload_json.as_bytes())));
        match state {
            AsyncTaskState::Pending => {
                queue
                    .enqueue_with_stable_id(
                        &task_id,
                        payload.clone(),
                        vt_pipeline::TaskPriority::Normal,
                    )
                    .await
                    .unwrap();
            }
            AsyncTaskState::Reserved => {
                store
                    .reserve_async_task(&run_id, &task_id, &digest)
                    .unwrap();
                queue
                    .enqueue_with_stable_id(
                        &task_id,
                        payload.clone(),
                        vt_pipeline::TaskPriority::Normal,
                    )
                    .await
                    .unwrap();
            }
            AsyncTaskState::Enqueued | AsyncTaskState::Completed | AsyncTaskState::Failed => {
                store
                    .reserve_async_task(&run_id, &task_id, &digest)
                    .unwrap();
                queue
                    .enqueue_with_stable_id(
                        &task_id,
                        payload.clone(),
                        vt_pipeline::TaskPriority::Normal,
                    )
                    .await
                    .unwrap();
                store.mark_async_task_enqueued(&run_id, &task_id).unwrap();
                if state == AsyncTaskState::Completed {
                    store
                        .mark_async_task_terminal_for_session(&session_id, &task_id, true)
                        .unwrap();
                } else if state == AsyncTaskState::Failed {
                    store
                        .mark_async_task_terminal_for_session(&session_id, &task_id, false)
                        .unwrap();
                }
            }
            AsyncTaskState::None => panic!("fixture requires an async-enabled receipt state"),
        }
        (temp, store, queue, payload, task_id)
    }

    fn commit_test_provider_receipt(
        store: &NotebookCaptureStore,
        payload: &TaskPayload,
        task_id: &str,
    ) -> String {
        let session_id = payload.session_id();
        let token = vt_model::Token {
            text: "already durable".into(),
            start_ms: 0,
            end_ms: 500,
            is_final: true,
            language: "en".into(),
            speaker: None,
            confidence: 1.0,
            translation_status: vt_model::TranslationStatus::None,
        };
        let result_json = serde_json::json!({
            "session_id": session_id,
            "token_count": 1,
            "full_text": "already durable",
            "duration_ms": 500,
        })
        .to_string();
        store
            .claim_provider_provenance(
                session_id,
                CaptureProviderRole::PostStop,
                CURRENT_NOTEBOOK_CAPTURE_ENGINE.provider_id,
                CURRENT_NOTEBOOK_CAPTURE_ENGINE.post_stop_model_id,
            )
            .and_then(|_| {
                store.commit_async_provider_success(session_id, task_id, &[token], &result_json)
            })
            .unwrap();
        result_json
    }

    fn suspend_sqlite_trigger(conn: &rusqlite::Connection, name: &str) -> String {
        let sql = conn
            .query_row(
                "SELECT sql FROM sqlite_schema WHERE type = 'trigger' AND name = ?1",
                [name],
                |row| row.get(0),
            )
            .unwrap();
        conn.execute_batch(&format!("DROP TRIGGER {name};"))
            .unwrap();
        sql
    }

    fn tamper_capture_provider_digest(db_path: &Path, session_id: &str) {
        let conn = rusqlite::Connection::open(db_path).unwrap();
        let trigger =
            suspend_sqlite_trigger(&conn, "notebook_capture_runs_provider_receipt_immutable");
        conn.execute(
            "UPDATE notebook_capture_runs
             SET async_provider_output_sha256 = ?1
             WHERE session_id = ?2",
            rusqlite::params!["0".repeat(64), session_id],
        )
        .unwrap();
        conn.execute_batch(&trigger).unwrap();
    }

    fn tamper_capture_receipt_task_id_missing(db_path: &Path, session_id: &str) {
        let conn = rusqlite::Connection::open(db_path).unwrap();
        let receipt_trigger =
            suspend_sqlite_trigger(&conn, "notebook_capture_runs_async_receipt_update");
        let identity_trigger =
            suspend_sqlite_trigger(&conn, "notebook_capture_runs_async_identity_immutable");
        conn.execute_batch("PRAGMA ignore_check_constraints = ON;")
            .unwrap();
        conn.execute(
            "UPDATE notebook_capture_runs SET async_task_id = NULL WHERE session_id = ?1",
            [session_id],
        )
        .unwrap();
        conn.execute_batch(&receipt_trigger).unwrap();
        conn.execute_batch(&identity_trigger).unwrap();
    }

    async fn add_valid_capture_provider_receipt(
        temp: &tempfile::TempDir,
        store: &NotebookCaptureStore,
        queue: &TaskQueue,
        notebook_id: &str,
        suffix: &str,
    ) -> (TaskPayload, String) {
        let run_id = format!("run-receipt-{suffix}");
        let session_id = format!("session-receipt-{suffix}");
        let profile = store.get_profile(notebook_id).unwrap().unwrap();
        store
            .create_run(
                &vt_store::NewNotebookCaptureRun {
                    id: run_id.clone(),
                    notebook_id: notebook_id.to_string(),
                    session_id: session_id.clone(),
                    remote_health: vt_store::RemoteHealth::Off,
                    audio_journal_path: temp
                        .path()
                        .join(format!("{suffix}.capture.journal"))
                        .to_string_lossy()
                        .into_owned(),
                    audio_key_ref: format!("audio-key-{suffix}"),
                    sample_rate: 16_000,
                    channels: 1,
                },
                &profile,
            )
            .unwrap();
        store
            .transition_capture(
                &run_id,
                vt_store::CaptureState::Recording,
                vt_store::CaptureState::Draining,
            )
            .unwrap();
        store
            .finalize_audio(
                &run_id,
                &temp
                    .path()
                    .join(format!("{suffix}.chunk.00000.enc"))
                    .to_string_lossy(),
                1_600,
            )
            .unwrap();
        store
            .transition_capture(
                &run_id,
                vt_store::CaptureState::Draining,
                vt_store::CaptureState::Completed,
            )
            .unwrap();
        store
            .authorize_async_transcription(&session_id, 1, Some("en"))
            .unwrap();
        let payload = TaskPayload::Transcribe {
            session_id: session_id.clone(),
            language_hint: Some("en".into()),
            remote_authorization: Some(
                vt_pipeline::RemoteTaskAuthorization::soniox_post_recording_at(1),
            ),
        };
        let task_id = format!("capture-async-{suffix}");
        let payload_digest = hex::encode(Sha256::digest(
            serde_json::to_string(&payload).unwrap().as_bytes(),
        ));
        store
            .reserve_async_task(&run_id, &task_id, &payload_digest)
            .unwrap();
        queue
            .enqueue_with_stable_id(&task_id, payload.clone(), vt_pipeline::TaskPriority::Normal)
            .await
            .unwrap();
        store.mark_async_task_enqueued(&run_id, &task_id).unwrap();
        commit_test_provider_receipt(store, &payload, &task_id);
        (payload, task_id)
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn session_registry_cancel_waits_for_handler_unregister_and_blocks_late_claims() {
        let registry = Arc::new(SessionTaskRegistry::new());
        let registration = registry.register("session-delete").unwrap();
        let cancel = registration.cancellation_token();
        let handler = tokio::spawn(async move {
            cancel.cancelled().await;
            // Mirrors the worker: unregister happens only after its handler has
            // observed cancellation and crossed the abort/join boundary.
            drop(registration);
        });

        let wait_registry = registry.clone();
        tokio::task::spawn_blocking(move || {
            wait_registry.cancel_and_wait("session-delete", Duration::from_secs(1))
        })
        .await
        .unwrap()
        .unwrap();
        handler.await.unwrap();

        assert_eq!(registry.active_count("session-delete"), 0);
        assert!(
            registry.register("session-delete").is_none(),
            "a task claimed before purge completion must not register late"
        );
    }

    #[test]
    fn transcription_registry_owner_is_immutable_session_id() {
        let transcription = TaskPayload::Transcribe {
            session_id: "capture-session".into(),
            language_hint: None,
            remote_authorization: Some(
                vt_pipeline::RemoteTaskAuthorization::soniox_post_recording_at(1),
            ),
        };
        assert_eq!(
            task_registry_owner_id("transcribe-task", &transcription),
            "capture-session"
        );
    }

    #[test]
    fn session_registry_cancel_wait_is_bounded() {
        let registry = Arc::new(SessionTaskRegistry::new());
        let registration = registry.register("session-stuck").unwrap();

        assert_eq!(
            registry.cancel_and_wait("session-stuck", Duration::from_millis(1)),
            Err(SessionTaskWaitError::Timeout {
                session_id: "session-stuck".to_string(),
            })
        );
        drop(registration);
        registry
            .cancel_and_wait("session-stuck", Duration::from_millis(10))
            .unwrap();
    }

    #[tokio::test]
    async fn handler_cancel_aborts_and_joins_before_returning() {
        struct DropFlag(Arc<AtomicBool>);
        impl Drop for DropFlag {
            fn drop(&mut self) {
                self.0.store(true, Ordering::SeqCst);
            }
        }

        let dropped = Arc::new(AtomicBool::new(false));
        let dropped_in_handler = dropped.clone();
        let (started_tx, started_rx) = tokio::sync::oneshot::channel();
        let handle = tokio::spawn(async move {
            let _guard = DropFlag(dropped_in_handler);
            let _ = started_tx.send(());
            std::future::pending::<()>().await;
            Ok::<String, (String, String)>(String::new())
        });
        started_rx.await.unwrap();
        let cancel = CancellationToken::new();
        cancel.cancel();

        let outcome =
            await_handler_or_session_cancel(handle, cancel, HandlerCancellationPolicy::AbortOuter)
                .await;
        assert!(matches!(outcome, TaskHandlerJoinOutcome::SessionCancelled));
        assert!(
            dropped.load(Ordering::SeqCst),
            "cancellation must await the aborted handler before returning"
        );
    }

    #[tokio::test]
    async fn cooperative_cancel_does_not_unregister_before_owned_child_finishes() {
        let (release_tx, release_rx) = tokio::sync::oneshot::channel();
        let handle = tokio::spawn(async move {
            let _ = release_rx.await;
            Ok::<String, (String, String)>(String::new())
        });
        let cancel = CancellationToken::new();
        cancel.cancel();
        let waiter = tokio::spawn(await_handler_or_session_cancel(
            handle,
            cancel,
            HandlerCancellationPolicy::AwaitOwnedChildren,
        ));

        tokio::time::sleep(Duration::from_millis(20)).await;
        assert!(
            !waiter.is_finished(),
            "a handler with owned child tasks must not be detached on cancellation"
        );
        let _ = release_tx.send(());
        assert!(matches!(
            waiter.await.unwrap(),
            TaskHandlerJoinOutcome::SessionCancelled
        ));
    }

    #[tokio::test]
    async fn capture_async_receipt_gate_requires_exact_identity_and_payload() {
        let (_temp, store, queue, payload, task_id) =
            capture_receipt_fixture(AsyncTaskState::Enqueued, None).await;
        verify_capture_async_task_receipt(&store, &queue, &payload, &task_id, false)
            .await
            .unwrap();

        let error =
            verify_capture_async_task_receipt(&store, &queue, &payload, "wrong-task", false)
                .await
                .unwrap_err();
        assert_eq!(error.0, "capture_async_receipt_invalid");

        let (_temp, store, queue, payload, task_id) =
            capture_receipt_fixture(AsyncTaskState::Reserved, Some("a".repeat(64))).await;
        let error = verify_capture_async_task_receipt(&store, &queue, &payload, &task_id, false)
            .await
            .unwrap_err();
        assert_eq!(error.0, "capture_async_receipt_invalid");
        assert_eq!(
            store
                .get_run_for_session(payload.session_id())
                .unwrap()
                .unwrap()
                .async_task_state,
            AsyncTaskState::Reserved,
            "a digest mismatch must not be promoted"
        );
    }

    #[tokio::test]
    async fn exact_reserved_capture_receipt_is_atomically_promoted_before_provider() {
        let (_temp, store, queue, payload, task_id) =
            capture_receipt_fixture(AsyncTaskState::Reserved, None).await;
        verify_capture_async_task_receipt(&store, &queue, &payload, &task_id, false)
            .await
            .unwrap();
        assert_eq!(
            store
                .get_run_for_session(payload.session_id())
                .unwrap()
                .unwrap()
                .async_task_state,
            AsyncTaskState::Enqueued
        );
    }

    #[tokio::test]
    async fn durable_receipt_dispatch_needs_no_key_or_audio_and_calls_provider_zero_times() {
        let (temp, store, queue, payload, task_id) =
            capture_receipt_fixture(AsyncTaskState::Enqueued, None).await;
        let expected_result = commit_test_provider_receipt(&store, &payload, &task_id);
        let api_keys = RacingApiKeyStore::new();

        let poll = claim_next_worker_task(&queue, &store, &api_keys, 30, |_| {})
            .await
            .unwrap()
            .unwrap();
        let WorkerPollResult::Claimed(WorkerTaskClaim {
            task,
            soniox_api_key,
            provider_receipt_ready,
        }) = poll
        else {
            panic!("receipt work must be claimed for local recovery");
        };
        assert!(provider_receipt_ready);
        assert!(soniox_api_key.is_none());
        assert!(!temp.path().join("capture.journal").exists());

        let provider_calls = Arc::new(AtomicUsize::new(0));
        let observed_calls = provider_calls.clone();
        let result = dispatch_task(
            &task.payload,
            &task.id,
            None,
            Arc::new(vt_crypto::MemoryKeyStore::new()),
            None,
            &temp.path().join("capture.db"),
            CancellationToken::new(),
            Some(Arc::new(move || {
                observed_calls.fetch_add(1, Ordering::SeqCst);
            })),
        )
        .await
        .unwrap();

        assert_eq!(result, expected_result);
        assert_eq!(provider_calls.load(Ordering::SeqCst), 0);
    }

    #[tokio::test]
    async fn corrupt_receipt_blocks_provider_fts_loro_and_callback_side_effects() {
        let (temp, store, queue, payload, task_id) =
            capture_receipt_fixture(AsyncTaskState::Enqueued, None).await;
        commit_test_provider_receipt(&store, &payload, &task_id);
        let stale_receipt = store
            .get_async_provider_receipt(payload.session_id(), &task_id)
            .unwrap()
            .unwrap();
        let db_path = temp.path().join("capture.db");
        tamper_capture_provider_digest(&db_path, payload.session_id());

        let side_effects = AtomicUsize::new(0);
        let error = recover_completed_provider_receipt_with(
            &queue,
            &store,
            &Arc::new(SessionTaskRegistry::new()),
            &stale_receipt,
            |_| {
                side_effects.fetch_add(1, Ordering::SeqCst);
                Ok(())
            },
            |_| {
                side_effects.fetch_add(1, Ordering::SeqCst);
                Ok(())
            },
            |_| {
                side_effects.fetch_add(1, Ordering::SeqCst);
                Ok(())
            },
            |_| {
                side_effects.fetch_add(1, Ordering::SeqCst);
            },
        )
        .await
        .unwrap_err();
        assert!(error.contains("validate provider receipt"));
        assert_eq!(
            side_effects.load(Ordering::SeqCst),
            0,
            "corrupt receipt reached close/FTS/Loro/callback"
        );

        let provider_calls = Arc::new(AtomicUsize::new(0));
        let observed_calls = provider_calls.clone();
        let dispatch_error = dispatch_task(
            &payload,
            &task_id,
            None,
            Arc::new(vt_crypto::MemoryKeyStore::new()),
            Some("configured-test-key".into()),
            &db_path,
            CancellationToken::new(),
            Some(Arc::new(move || {
                observed_calls.fetch_add(1, Ordering::SeqCst);
            })),
        )
        .await
        .unwrap_err();
        assert_eq!(dispatch_error.0, "capture_provider_receipt_invalid");
        assert_eq!(provider_calls.load(Ordering::SeqCst), 0);
    }

    #[tokio::test]
    async fn missing_task_id_corrupt_receipt_does_not_starve_valid_recovery() {
        let (temp, store, queue, corrupt_payload, corrupt_task_id) =
            capture_receipt_fixture(AsyncTaskState::Enqueued, None).await;
        commit_test_provider_receipt(&store, &corrupt_payload, &corrupt_task_id);
        let notebook_id = store
            .get_run_for_session(corrupt_payload.session_id())
            .unwrap()
            .unwrap()
            .notebook_id;
        let (valid_payload, valid_task_id) = add_valid_capture_provider_receipt(
            &temp,
            &store,
            &queue,
            &notebook_id,
            "valid-after-corrupt",
        )
        .await;
        let db_path = temp.path().join("capture.db");
        tamper_capture_receipt_task_id_missing(&db_path, corrupt_payload.session_id());

        let poll = claim_next_worker_task(&queue, &store, &RacingApiKeyStore::new(), 30, |_| {})
            .await
            .unwrap()
            .expect("valid receipt must remain claimable in the same poll");
        let WorkerPollResult::Claimed(WorkerTaskClaim {
            task,
            soniox_api_key,
            provider_receipt_ready,
        }) = poll
        else {
            panic!("valid provider receipt should be claimed for local recovery");
        };
        assert_eq!(task.id, valid_task_id);
        assert_eq!(task.payload.session_id(), valid_payload.session_id());
        assert!(provider_receipt_ready);
        assert!(soniox_api_key.is_none());

        let corrupt_state: String = rusqlite::Connection::open(&db_path)
            .unwrap()
            .query_row(
                "SELECT async_search_projection_state
                 FROM notebook_capture_runs WHERE session_id = ?1",
                [corrupt_payload.session_id()],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(corrupt_state, "failed");
        assert!(matches!(
            store.get_async_provider_receipt(corrupt_payload.session_id(), &corrupt_task_id),
            Err(NotebookCaptureStoreError::CorruptData(_))
        ));
        let scan = store.list_async_provider_receipts().unwrap();
        assert!(scan.corrupt.is_empty(), "quarantined row must not recur");
        assert_eq!(scan.receipts.len(), 1);
        assert_eq!(scan.receipts[0].task_id, valid_task_id);
    }

    #[tokio::test]
    async fn post_stop_provenance_claim_failure_calls_provider_zero_times() {
        let temp = tempfile::tempdir().unwrap();
        let db_path = temp.path().join("capture.db");
        let session_id = "post-stop-claim-failure";
        let task_id = "post-stop-claim-failure-task";
        let notebook = vt_store::NotebookStore::new(&db_path)
            .unwrap()
            .create_notebook(Some("Provider claim fault"))
            .unwrap();
        vt_store::SessionQueryStore::new(&db_path)
            .unwrap()
            .insert_session(&vt_store::SessionRecord {
                id: session_id.into(),
                title: "Provider claim fault".into(),
                session_type: "recording".into(),
                status: "completed".into(),
                duration_ms: 100,
                created_at: "2001-01-01 00:00:00".into(),
                deleted_at: None,
            })
            .unwrap();
        let store = NotebookCaptureStore::new(&db_path).unwrap();
        let current_profile = store.get_or_create_profile(&notebook.id).unwrap();
        let profile = store
            .update_profile(
                &notebook.id,
                current_profile.revision,
                &vt_store::NotebookCaptureProfileUpdate {
                    remote_realtime_enabled: false,
                    capture_mode: vt_store::CaptureMode::TranscriptionOnly,
                    language_a: "en".into(),
                    language_b: "zh".into(),
                    left_language: "en".into(),
                    right_language: "zh".into(),
                    selected_languages: vec!["en".into(), "zh".into()],
                    common_caption_language: None,
                    privacy_level: "standard".into(),
                    send_context_to_soniox: false,
                },
            )
            .unwrap();
        let audio_path = temp.path().join("post-stop-claim-failure.enc");
        let key_ref = "post-stop-claim-failure-key";
        let key = vt_crypto::SessionKey::generate();
        let pcm_f32le = vec![0_u8; 1_600 * std::mem::size_of::<f32>()];
        vt_crypto::encrypt_to_file(&audio_path, &key, &pcm_f32le).unwrap();
        store
            .create_completed_import_run(
                &vt_store::notebook_capture_store::NewCompletedNotebookImportRun {
                    id: "post-stop-claim-failure-run".into(),
                    notebook_id: notebook.id,
                    session_id: session_id.into(),
                    audio_path: audio_path.to_string_lossy().into_owned(),
                    audio_key_ref: key_ref.into(),
                    sample_rate: 16_000,
                    channels: 1,
                    captured_frames: 1_600,
                },
                &profile,
            )
            .unwrap();
        store
            .authorize_async_transcription(session_id, 1, Some("en"))
            .unwrap();
        store
            .reserve_async_task("post-stop-claim-failure-run", task_id, &"a".repeat(64))
            .unwrap();
        store
            .mark_async_task_enqueued("post-stop-claim-failure-run", task_id)
            .unwrap();

        let meta = SessionMetaStore::new(&db_path).unwrap();
        meta.set_encrypted_path(session_id, audio_path.to_str().unwrap(), key_ref)
            .unwrap();
        meta.set_audio_format(session_id, 16_000, 1).unwrap();
        meta.set_privacy_level(session_id, "standard").unwrap();
        meta.upsert_audio_retention_chunk(&AudioChunkRetentionRecord {
            session_id: session_id.into(),
            chunk_id: "post-stop-claim-failure:audio:00000".into(),
            start_ms: 0,
            end_ms: 100,
            local_path: audio_path.to_string_lossy().into_owned(),
            encrypted: true,
            deleted: false,
            retention_deadline_ms: i64::MAX,
            delete_error: None,
            deleted_at_ms: None,
        })
        .unwrap();
        let key_store = Arc::new(vt_crypto::MemoryKeyStore::new());
        key_store.store_key(key_ref, &key).unwrap();

        // Freeze Delete Forever after every local audio preflight input is
        // durable. The provider claim must now fail closed at the last gate.
        store.begin_session_purge(session_id).unwrap();
        let provider_calls = Arc::new(AtomicUsize::new(0));
        let observed_calls = provider_calls.clone();
        let payload = TaskPayload::Transcribe {
            session_id: session_id.into(),
            language_hint: Some("en".into()),
            remote_authorization: Some(
                vt_pipeline::RemoteTaskAuthorization::soniox_post_recording_at(1),
            ),
        };

        let error = dispatch_task(
            &payload,
            task_id,
            None,
            key_store,
            Some("configured-test-key".into()),
            &db_path,
            CancellationToken::new(),
            Some(Arc::new(move || {
                observed_calls.fetch_add(1, Ordering::SeqCst);
            })),
        )
        .await
        .unwrap_err();

        assert_eq!(error.0, "capture_provider_provenance_unavailable");
        assert_eq!(provider_calls.load(Ordering::SeqCst), 0);
        let run = store.get_run_for_session(session_id).unwrap().unwrap();
        assert!(run.post_stop_provider_id.is_none());
        assert!(run.post_stop_model_id.is_none());
    }

    #[tokio::test]
    async fn startup_rebuilds_or_repairs_tasks_db_from_provider_receipt_without_failing_run() {
        let (_temp, store, queue, payload, task_id) =
            capture_receipt_fixture(AsyncTaskState::Enqueued, None).await;
        commit_test_provider_receipt(&store, &payload, &task_id);
        let payload_digest = hex::encode(Sha256::digest(
            serde_json::to_string(&payload).unwrap().as_bytes(),
        ));
        queue.purge_task(&task_id).await.unwrap();
        let run = store
            .get_run_for_session(payload.session_id())
            .unwrap()
            .unwrap();

        assert_eq!(
            reconcile_capture_async_task_receipt_on_startup(
                &store,
                &queue,
                &run,
                &task_id,
                &payload,
                &payload_digest,
            )
            .await
            .unwrap(),
            StartupCaptureAsyncReceiptOutcome::ProviderReceiptReady
        );
        assert_eq!(
            queue.get_status(&task_id).await.unwrap(),
            TaskStatus::Pending
        );
        assert_eq!(
            store
                .get_run_for_session(payload.session_id())
                .unwrap()
                .unwrap()
                .async_task_state,
            AsyncTaskState::Enqueued
        );

        let (_temp, store, queue, payload, task_id) =
            capture_receipt_fixture(AsyncTaskState::Enqueued, None).await;
        commit_test_provider_receipt(&store, &payload, &task_id);
        let claimed = queue.claim_next(30).await.unwrap().unwrap();
        queue
            .fail_terminal(&task_id, "stale local failure")
            .await
            .unwrap();
        drop(claimed);
        let payload_digest = hex::encode(Sha256::digest(
            serde_json::to_string(&payload).unwrap().as_bytes(),
        ));
        let run = store
            .get_run_for_session(payload.session_id())
            .unwrap()
            .unwrap();
        assert_eq!(
            reconcile_capture_async_task_receipt_on_startup(
                &store,
                &queue,
                &run,
                &task_id,
                &payload,
                &payload_digest,
            )
            .await
            .unwrap(),
            StartupCaptureAsyncReceiptOutcome::ProviderReceiptReady
        );
        assert_eq!(
            store
                .get_run_for_session(payload.session_id())
                .unwrap()
                .unwrap()
                .async_task_state,
            AsyncTaskState::Enqueued
        );
        queue
            .complete_from_durable_provider_receipt(&task_id)
            .await
            .unwrap();
        store
            .mark_async_task_terminal_for_session(payload.session_id(), &task_id, true)
            .unwrap();
        assert_eq!(
            queue.get_status(&task_id).await.unwrap(),
            TaskStatus::Completed
        );
        assert_eq!(
            store
                .get_run_for_session(payload.session_id())
                .unwrap()
                .unwrap()
                .async_task_state,
            AsyncTaskState::Completed
        );
    }

    #[tokio::test]
    async fn completed_queue_receipt_retries_main_terminal_write_without_provider_or_restart() {
        let (_temp, store, queue, payload, task_id) =
            capture_receipt_fixture(AsyncTaskState::Enqueued, None).await;
        commit_test_provider_receipt(&store, &payload, &task_id);
        let claimed = queue.claim_next(30).await.unwrap().unwrap();
        queue.complete(&task_id).await.unwrap();
        drop(claimed);
        let receipt = store
            .get_async_provider_receipt(payload.session_id(), &task_id)
            .unwrap()
            .unwrap();
        let poll = claim_next_worker_task(&queue, &store, &RacingApiKeyStore::new(), 30, |_| {})
            .await
            .unwrap()
            .unwrap();
        assert!(matches!(
            poll,
            WorkerPollResult::ReconciledProviderReceipt(_)
        ));
        assert_eq!(
            store
                .get_run_for_session(payload.session_id())
                .unwrap()
                .unwrap()
                .async_task_state,
            AsyncTaskState::Enqueued,
            "worker polling must not mutate main state before registry ownership"
        );

        let injected_writes = AtomicUsize::new(0);
        let first = reconcile_completed_provider_receipt_with(&queue, &receipt, |_| {
            injected_writes.fetch_add(1, Ordering::SeqCst);
            Err("injected main terminal write failure".to_string())
        })
        .await;
        assert!(first.is_err());
        assert_eq!(injected_writes.load(Ordering::SeqCst), 1);
        assert_eq!(
            store
                .get_run_for_session(payload.session_id())
                .unwrap()
                .unwrap()
                .async_task_state,
            AsyncTaskState::Enqueued
        );

        assert!(
            reconcile_completed_provider_receipt_with(&queue, &receipt, |receipt| {
                store
                    .mark_async_task_terminal_for_session(
                        &receipt.session_id,
                        &receipt.task_id,
                        true,
                    )
                    .map(|_| ())
                    .map_err(|error| error.to_string())
            })
            .await
            .unwrap()
        );
        assert_eq!(
            store
                .get_run_for_session(payload.session_id())
                .unwrap()
                .unwrap()
                .async_task_state,
            AsyncTaskState::Completed
        );
    }

    #[tokio::test]
    async fn startup_reconciles_exact_reserved_row_without_creating_duplicate_upload() {
        let (_temp, store, queue, payload, task_id) =
            capture_receipt_fixture(AsyncTaskState::Reserved, None).await;
        let payload_digest = hex::encode(Sha256::digest(
            serde_json::to_string(&payload).unwrap().as_bytes(),
        ));
        let reserved = store
            .get_run_for_session(payload.session_id())
            .unwrap()
            .unwrap();

        assert_eq!(
            reconcile_capture_async_task_receipt_on_startup(
                &store,
                &queue,
                &reserved,
                &task_id,
                &payload,
                &payload_digest,
            )
            .await
            .unwrap(),
            StartupCaptureAsyncReceiptOutcome::Claimable
        );
        let enqueued = store
            .get_run_for_session(payload.session_id())
            .unwrap()
            .unwrap();
        assert_eq!(enqueued.async_task_state, AsyncTaskState::Enqueued);

        assert_eq!(
            reconcile_capture_async_task_receipt_on_startup(
                &store,
                &queue,
                &enqueued,
                &task_id,
                &payload,
                &payload_digest,
            )
            .await
            .unwrap(),
            StartupCaptureAsyncReceiptOutcome::Claimable
        );
        let tasks = queue.list_tasks(None).await.unwrap();
        assert_eq!(tasks.len(), 1, "startup must never enqueue a second upload");
        assert_eq!(tasks[0].id, task_id);
    }

    #[tokio::test]
    async fn startup_fail_closes_reserved_receipt_when_stable_row_is_missing_or_mismatched() {
        let (_temp, store, queue, payload, task_id) =
            capture_receipt_fixture(AsyncTaskState::Reserved, None).await;
        let payload_digest = hex::encode(Sha256::digest(
            serde_json::to_string(&payload).unwrap().as_bytes(),
        ));
        assert_eq!(queue.purge_session(payload.session_id()).await.unwrap(), 1);
        let reserved = store
            .get_run_for_session(payload.session_id())
            .unwrap()
            .unwrap();
        assert!(matches!(
            reconcile_capture_async_task_receipt_on_startup(
                &store,
                &queue,
                &reserved,
                &task_id,
                &payload,
                &payload_digest,
            )
            .await
            .unwrap(),
            StartupCaptureAsyncReceiptOutcome::FailedClosed { .. }
        ));
        assert_eq!(
            store
                .get_run_for_session(payload.session_id())
                .unwrap()
                .unwrap()
                .async_task_state,
            AsyncTaskState::Failed
        );
        assert!(queue.list_tasks(None).await.unwrap().is_empty());

        let (_temp, store, queue, payload, task_id) =
            capture_receipt_fixture(AsyncTaskState::Reserved, Some("a".repeat(64))).await;
        let payload_digest = hex::encode(Sha256::digest(
            serde_json::to_string(&payload).unwrap().as_bytes(),
        ));
        let reserved = store
            .get_run_for_session(payload.session_id())
            .unwrap()
            .unwrap();
        assert!(matches!(
            reconcile_capture_async_task_receipt_on_startup(
                &store,
                &queue,
                &reserved,
                &task_id,
                &payload,
                &payload_digest,
            )
            .await
            .unwrap(),
            StartupCaptureAsyncReceiptOutcome::FailedClosed { .. }
        ));
        assert_eq!(
            store
                .get_run_for_session(payload.session_id())
                .unwrap()
                .unwrap()
                .async_task_state,
            AsyncTaskState::Failed
        );
        assert_eq!(
            queue.list_tasks(None).await.unwrap().len(),
            1,
            "mismatched recovery must neither replace nor duplicate the durable row"
        );

        let (_temp, store, queue, payload, recorded_task_id) =
            capture_receipt_fixture(AsyncTaskState::Reserved, None).await;
        let payload_digest = hex::encode(Sha256::digest(
            serde_json::to_string(&payload).unwrap().as_bytes(),
        ));
        let expected_task_id = format!("{recorded_task_id}-expected");
        let reserved = store
            .get_run_for_session(payload.session_id())
            .unwrap()
            .unwrap();
        assert!(matches!(
            reconcile_capture_async_task_receipt_on_startup(
                &store,
                &queue,
                &reserved,
                &expected_task_id,
                &payload,
                &payload_digest,
            )
            .await
            .unwrap(),
            StartupCaptureAsyncReceiptOutcome::FailedClosed { .. }
        ));
        assert_eq!(
            store
                .get_run_for_session(payload.session_id())
                .unwrap()
                .unwrap()
                .async_task_state,
            AsyncTaskState::Failed
        );
        let tasks = queue.list_tasks(None).await.unwrap();
        assert_eq!(tasks.len(), 1);
        assert_eq!(tasks[0].id, recorded_task_id);
    }

    #[tokio::test]
    async fn startup_closes_exact_terminal_rows_and_keeps_running_row_claimable() {
        let (_temp, store, queue, payload, task_id) =
            capture_receipt_fixture(AsyncTaskState::Reserved, None).await;
        let payload_digest = hex::encode(Sha256::digest(
            serde_json::to_string(&payload).unwrap().as_bytes(),
        ));
        let claimed = queue.claim_next(30).await.unwrap().unwrap();
        assert_eq!(claimed.id, task_id);
        queue.complete(&task_id).await.unwrap();
        drop(claimed);
        let reserved = store
            .get_run_for_session(payload.session_id())
            .unwrap()
            .unwrap();
        assert_eq!(
            reconcile_capture_async_task_receipt_on_startup(
                &store,
                &queue,
                &reserved,
                &task_id,
                &payload,
                &payload_digest,
            )
            .await
            .unwrap(),
            StartupCaptureAsyncReceiptOutcome::Completed
        );
        assert_eq!(
            store
                .get_run_for_session(payload.session_id())
                .unwrap()
                .unwrap()
                .async_task_state,
            AsyncTaskState::Completed
        );

        let (_temp, store, queue, payload, task_id) =
            capture_receipt_fixture(AsyncTaskState::Reserved, None).await;
        let payload_digest = hex::encode(Sha256::digest(
            serde_json::to_string(&payload).unwrap().as_bytes(),
        ));
        queue.fail_terminal(&task_id, "terminal").await.unwrap();
        let reserved = store
            .get_run_for_session(payload.session_id())
            .unwrap()
            .unwrap();
        assert!(matches!(
            reconcile_capture_async_task_receipt_on_startup(
                &store,
                &queue,
                &reserved,
                &task_id,
                &payload,
                &payload_digest,
            )
            .await
            .unwrap(),
            StartupCaptureAsyncReceiptOutcome::FailedClosed { .. }
        ));
        assert_eq!(
            store
                .get_run_for_session(payload.session_id())
                .unwrap()
                .unwrap()
                .async_task_state,
            AsyncTaskState::Failed
        );

        let (_temp, store, queue, payload, task_id) =
            capture_receipt_fixture(AsyncTaskState::Reserved, None).await;
        let payload_digest = hex::encode(Sha256::digest(
            serde_json::to_string(&payload).unwrap().as_bytes(),
        ));
        let claimed = queue.claim_next(30).await.unwrap().unwrap();
        let reserved = store
            .get_run_for_session(payload.session_id())
            .unwrap()
            .unwrap();
        assert_eq!(
            reconcile_capture_async_task_receipt_on_startup(
                &store,
                &queue,
                &reserved,
                &task_id,
                &payload,
                &payload_digest,
            )
            .await
            .unwrap(),
            StartupCaptureAsyncReceiptOutcome::Claimable
        );
        assert_eq!(
            store
                .get_run_for_session(payload.session_id())
                .unwrap()
                .unwrap()
                .async_task_state,
            AsyncTaskState::Enqueued
        );
        drop(claimed);
    }

    #[tokio::test]
    async fn capture_async_receipt_gate_rejects_non_dispatchable_states_and_missing_task_row() {
        for state in [
            AsyncTaskState::Pending,
            AsyncTaskState::Completed,
            AsyncTaskState::Failed,
        ] {
            let (_temp, store, queue, payload, task_id) =
                capture_receipt_fixture(state, None).await;
            let error =
                verify_capture_async_task_receipt(&store, &queue, &payload, &task_id, false)
                    .await
                    .unwrap_err();
            assert_eq!(
                error.0, "capture_async_receipt_invalid",
                "state {state:?} must fail closed"
            );
        }

        let (_temp, store, queue, payload, task_id) =
            capture_receipt_fixture(AsyncTaskState::Reserved, None).await;
        assert_eq!(queue.purge_session(payload.session_id()).await.unwrap(), 1);
        let error = verify_capture_async_task_receipt(&store, &queue, &payload, &task_id, false)
            .await
            .unwrap_err();
        assert_eq!(error.0, "capture_async_receipt_invalid");
        assert_eq!(
            store
                .get_run_for_session(payload.session_id())
                .unwrap()
                .unwrap()
                .async_task_state,
            AsyncTaskState::Reserved,
            "a missing tasks.db row must never be promoted"
        );
    }

    #[tokio::test]
    async fn transcribe_without_capture_or_import_run_is_rejected() {
        let temp = tempfile::tempdir().unwrap();
        let store = NotebookCaptureStore::new(&temp.path().join("capture.db")).unwrap();
        let queue = TaskQueue::new(&temp.path().join("tasks.db")).await.unwrap();
        let payload = TaskPayload::Transcribe {
            session_id: "orphan-session".into(),
            language_hint: None,
            remote_authorization: Some(
                vt_pipeline::RemoteTaskAuthorization::soniox_post_recording_at(1),
            ),
        };
        let task_id = queue.enqueue(payload.clone()).await.unwrap();

        let error = verify_capture_async_task_receipt(&store, &queue, &payload, &task_id, false)
            .await
            .unwrap_err();
        assert_eq!(error.0, "capture_async_receipt_missing");
    }

    #[tokio::test]
    async fn capture_async_receipt_closes_only_after_true_queue_terminal_state() {
        let (_temp, store, queue, payload, task_id) =
            capture_receipt_fixture(AsyncTaskState::Enqueued, None).await;
        let _task = queue.claim_next(300).await.unwrap().unwrap();
        queue.fail(&task_id, "retry").await.unwrap();
        close_capture_async_receipt_if_queue_terminal(&store, &queue, &payload, &task_id)
            .await
            .unwrap();
        assert_eq!(
            store
                .get_run_for_session(payload.session_id())
                .unwrap()
                .unwrap()
                .async_task_state,
            AsyncTaskState::Enqueued,
            "retryable pending task must keep its Enqueued receipt"
        );

        let (_temp, store, queue, payload, task_id) =
            capture_receipt_fixture(AsyncTaskState::Enqueued, None).await;
        let _task = queue.claim_next(300).await.unwrap().unwrap();
        queue.complete(&task_id).await.unwrap();
        close_capture_async_receipt_if_queue_terminal(&store, &queue, &payload, &task_id)
            .await
            .unwrap();
        assert_eq!(
            store
                .get_run_for_session(payload.session_id())
                .unwrap()
                .unwrap()
                .async_task_state,
            AsyncTaskState::Completed
        );

        let (_temp, store, queue, payload, task_id) =
            capture_receipt_fixture(AsyncTaskState::Enqueued, None).await;
        let _task = queue.claim_next(300).await.unwrap().unwrap();
        queue.fail_terminal(&task_id, "terminal").await.unwrap();
        close_capture_async_receipt_if_queue_terminal(&store, &queue, &payload, &task_id)
            .await
            .unwrap();
        assert_eq!(
            store
                .get_run_for_session(payload.session_id())
                .unwrap()
                .unwrap()
                .async_task_state,
            AsyncTaskState::Failed
        );
    }

    #[tokio::test]
    async fn durable_tombstone_prevents_dispatch_and_clears_task_rows() {
        let tmp = tempfile::TempDir::new().unwrap();
        let capture_store = NotebookCaptureStore::new(&tmp.path().join("capture.db")).unwrap();
        capture_store
            .begin_session_purge("session-tombstoned")
            .unwrap();
        let queue = TaskQueue::new(&tmp.path().join("tasks.db")).await.unwrap();
        let task_id = queue
            .enqueue(TaskPayload::Transcribe {
                session_id: "session-tombstoned".to_string(),
                language_hint: None,
                remote_authorization: Some(
                    vt_pipeline::RemoteTaskAuthorization::soniox_post_recording_at(1),
                ),
            })
            .await
            .unwrap();
        let _claimed = queue.claim_next(300).await.unwrap().unwrap();

        assert!(
            !session_task_may_continue(&capture_store, &queue, "session-tombstoned", &task_id,)
                .await
        );
        assert!(
            queue.get_task(&task_id).await.is_err(),
            "tombstone handling must idempotently clear tasks.db"
        );
        assert_eq!(queue.purge_session("session-tombstoned").await.unwrap(), 0);
    }

    #[tokio::test]
    async fn deleted_task_row_prevents_late_projection_or_finalization_after_tombstone_completion()
    {
        let tmp = tempfile::TempDir::new().unwrap();
        let capture_store = NotebookCaptureStore::new(&tmp.path().join("capture.db")).unwrap();
        let queue = TaskQueue::new(&tmp.path().join("tasks.db")).await.unwrap();
        let task_id = queue
            .enqueue(TaskPayload::Transcribe {
                session_id: "session-finished-purge".to_string(),
                language_hint: None,
                remote_authorization: Some(
                    vt_pipeline::RemoteTaskAuthorization::soniox_post_recording_at(1),
                ),
            })
            .await
            .unwrap();
        let _claimed = queue.claim_next(300).await.unwrap().unwrap();

        // Models the narrow race in which the worker retains its claimed Task
        // value while the purge saga deletes tasks.db and then removes its
        // durable tombstone. The task-row half of the gate still rejects the
        // late projection/final commit.
        assert_eq!(
            queue.purge_session("session-finished-purge").await.unwrap(),
            1
        );
        assert!(
            !session_task_may_continue(&capture_store, &queue, "session-finished-purge", &task_id,)
                .await
        );
    }

    #[tokio::test]
    async fn finalize_success_returns_error_when_queue_complete_fails() {
        let tmp = tempfile::TempDir::new().unwrap();
        let db = tmp.path().join("tasks.db");
        let queue = TaskQueue::new(&db).await.unwrap();
        let task_id = queue
            .enqueue(TaskPayload::Transcribe {
                session_id: "s1".to_string(),
                language_hint: None,
                remote_authorization: Some(
                    vt_pipeline::RemoteTaskAuthorization::soniox_post_recording_at(1),
                ),
            })
            .await
            .unwrap();
        let _claimed = queue.claim_next(300).await.unwrap().unwrap();
        assert!(queue.purge_task(&task_id).await.unwrap());
        let key_store = vt_crypto::MemoryKeyStore::new();
        let err = finalize_successful_task(&queue, &task_id, "transcribe", "s1", &db, &key_store)
            .await
            .unwrap_err();

        assert_eq!(err.code(), "queue_completion_failed");
        assert!(queue.get_status(&task_id).await.is_err());
    }

    #[tokio::test]
    async fn provider_receipt_survives_privacy_failure_and_retries_only_local_finalization() {
        let (tmp, store, queue, payload, task_id) =
            capture_receipt_fixture(AsyncTaskState::Enqueued, None).await;
        let expected_result = commit_test_provider_receipt(&store, &payload, &task_id);
        let _claimed = queue.claim_next(300).await.unwrap().unwrap();
        let metadata_db = tmp.path().join("capture.db");
        let first_chunk_path = tmp.path().join("chunk-000.enc");
        let second_chunk_path = tmp.path().join("chunk-001-dir");
        std::fs::write(&first_chunk_path, b"encrypted chunk 0").unwrap();
        std::fs::create_dir(&second_chunk_path).unwrap();

        let session_meta = SessionMetaStore::new(&metadata_db).unwrap();
        session_meta
            .set_privacy_level(payload.session_id(), "high")
            .unwrap();
        for (chunk_id, start_ms, local_path) in [
            ("audio:00000", 0, first_chunk_path.as_path()),
            ("audio:00001", 1_000, second_chunk_path.as_path()),
        ] {
            session_meta
                .upsert_audio_retention_chunk(&vt_store::AudioChunkRetentionRecord {
                    session_id: payload.session_id().to_string(),
                    chunk_id: chunk_id.to_string(),
                    start_ms,
                    end_ms: start_ms + 1_000,
                    local_path: local_path.to_str().unwrap().to_string(),
                    encrypted: true,
                    deleted: false,
                    retention_deadline_ms: 0,
                    delete_error: None,
                    deleted_at_ms: None,
                })
                .unwrap();
        }

        let provider_calls = Arc::new(AtomicUsize::new(0));
        let observed_calls = provider_calls.clone();
        let recovered = dispatch_task(
            &payload,
            &task_id,
            None,
            Arc::new(vt_crypto::MemoryKeyStore::new()),
            None,
            &metadata_db,
            CancellationToken::new(),
            Some(Arc::new(move || {
                observed_calls.fetch_add(1, Ordering::SeqCst);
            })),
        )
        .await
        .unwrap();
        assert_eq!(recovered, expected_result);
        assert_eq!(provider_calls.load(Ordering::SeqCst), 0);

        let key_store = vt_crypto::MemoryKeyStore::new();
        let err = finalize_successful_task(
            &queue,
            &task_id,
            "transcribe",
            payload.session_id(),
            &metadata_db,
            &key_store,
        )
        .await
        .unwrap_err();

        assert_eq!(err.code(), "privacy_cleanup_failed");
        let task = queue.get_task(&task_id).await.unwrap();
        assert_eq!(task.status, "running");
        assert_eq!(task.retry_count, 0);
        assert_eq!(
            store
                .get_run_for_session(payload.session_id())
                .unwrap()
                .unwrap()
                .async_task_state,
            AsyncTaskState::Enqueued,
            "local privacy failure must not rewrite remote success as failed"
        );
        assert!(
            !first_chunk_path.exists(),
            "completed local cleanup steps stay idempotent across retry"
        );

        std::fs::remove_dir(&second_chunk_path).unwrap();
        finalize_successful_task(
            &queue,
            &task_id,
            "transcribe",
            payload.session_id(),
            &metadata_db,
            &key_store,
        )
        .await
        .unwrap();
        close_capture_async_receipt_if_queue_terminal(&store, &queue, &payload, &task_id)
            .await
            .unwrap();
        assert_eq!(
            queue.get_status(&task_id).await.unwrap(),
            TaskStatus::Completed
        );
        assert_eq!(
            store
                .get_run_for_session(payload.session_id())
                .unwrap()
                .unwrap()
                .async_task_state,
            AsyncTaskState::Completed
        );

        let chunks = session_meta
            .list_audio_retention_chunks(payload.session_id())
            .unwrap();
        let first = chunks
            .iter()
            .find(|chunk| chunk.chunk_id == "audio:00000")
            .unwrap();
        let second = chunks
            .iter()
            .find(|chunk| chunk.chunk_id == "audio:00001")
            .unwrap();
        assert!(first.deleted);
        assert!(second.deleted);
    }

    #[test]
    fn provider_worker_plan_routes_transcribe_to_async_stt_provider() {
        let plan = provider_worker_plan_for_task(
            &TaskPayload::Transcribe {
                session_id: "s1".into(),
                language_hint: Some("en".into()),
                remote_authorization: Some(
                    vt_pipeline::RemoteTaskAuthorization::soniox_post_recording_at(1),
                ),
            },
            "standard",
        )
        .unwrap();

        let engine = CURRENT_NOTEBOOK_CAPTURE_ENGINE;
        assert_eq!(plan.slot, "async_stt");
        assert_eq!(plan.provider_id, engine.provider_id);
        assert_eq!(plan.key_scope.as_deref(), Some(engine.credential_scope));
        assert_eq!(plan.model_id.as_deref(), Some(engine.post_stop_model_id));
    }

    #[test]
    fn provider_worker_plan_keeps_explicit_remote_authorization_under_maximum_privacy() {
        let plan = provider_worker_plan_for_task(
            &TaskPayload::Transcribe {
                session_id: "s1".into(),
                language_hint: None,
                remote_authorization: Some(
                    vt_pipeline::RemoteTaskAuthorization::soniox_post_recording_at(1),
                ),
            },
            "maximum",
        )
        .unwrap();

        assert_eq!(
            plan.provider_id,
            CURRENT_NOTEBOOK_CAPTURE_ENGINE.provider_id
        );
    }

    #[test]
    fn provider_worker_plan_rejects_invalid_privacy_state() {
        let err = provider_worker_plan_for_task(
            &TaskPayload::Transcribe {
                session_id: "s1".into(),
                language_hint: None,
                remote_authorization: Some(
                    vt_pipeline::RemoteTaskAuthorization::soniox_post_recording_at(1),
                ),
            },
            "unknown",
        )
        .unwrap_err();

        assert_eq!(err.0, "privacy_state_invalid");
    }

    /// 最小 HTTP/1.1 mock：只服务扫尾要用的清单与删除端点。
    struct SweepMock {
        base_url: String,
        requests: Arc<std::sync::Mutex<Vec<(String, String)>>>,
    }

    struct SweepMockPlan {
        files_body: String,
        transcriptions_body: String,
        fail_list: bool,
        fail_delete: bool,
    }

    impl Default for SweepMockPlan {
        fn default() -> Self {
            Self {
                files_body: r#"{"files":[]}"#.to_string(),
                transcriptions_body: r#"{"transcriptions":[]}"#.to_string(),
                fail_list: false,
                fail_delete: false,
            }
        }
    }

    async fn start_sweep_mock(plan: SweepMockPlan) -> SweepMock {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let requests: Arc<std::sync::Mutex<Vec<(String, String)>>> =
            Arc::new(std::sync::Mutex::new(Vec::new()));
        let recorded = requests.clone();

        tokio::spawn(async move {
            while let Ok((mut stream, _)) = listener.accept().await {
                loop {
                    let mut buffer = Vec::new();
                    let mut chunk = [0u8; 2048];
                    let head_end = loop {
                        if let Some(pos) = buffer
                            .windows(4)
                            .position(|window| window == b"\r\n\r\n".as_slice())
                        {
                            break Some(pos);
                        }
                        match stream.read(&mut chunk).await {
                            Ok(0) | Err(_) => break None,
                            Ok(read) => buffer.extend_from_slice(&chunk[..read]),
                        }
                    };
                    if head_end.is_none() {
                        break;
                    }
                    let head = String::from_utf8_lossy(&buffer).to_string();
                    let mut parts = head.split_whitespace();
                    let method = parts.next().unwrap_or_default().to_string();
                    let path = parts.next().unwrap_or_default().to_string();
                    recorded
                        .lock()
                        .unwrap()
                        .push((method.clone(), path.clone()));

                    let (status, body) = if method == "DELETE" {
                        if plan.fail_delete {
                            ("500 Internal Server Error", "{}".to_string())
                        } else {
                            ("200 OK", "{}".to_string())
                        }
                    } else if plan.fail_list {
                        ("500 Internal Server Error", "{}".to_string())
                    } else if path.starts_with("/v1/files") {
                        ("200 OK", plan.files_body.clone())
                    } else if path.starts_with("/v1/transcriptions") {
                        ("200 OK", plan.transcriptions_body.clone())
                    } else {
                        ("404 Not Found", "{}".to_string())
                    };
                    let response = format!(
                        "HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{body}",
                        body.len()
                    );
                    if stream.write_all(response.as_bytes()).await.is_err() {
                        break;
                    }
                }
            }
        });

        SweepMock {
            base_url: format!("http://127.0.0.1:{port}"),
            requests,
        }
    }

    impl SweepMock {
        fn paths(&self) -> Vec<String> {
            self.requests
                .lock()
                .unwrap()
                .iter()
                .map(|(method, path)| format!("{method} {path}"))
                .collect()
        }
    }

    #[tokio::test]
    async fn startup_sweep_deletes_journaled_artifacts_and_closes_the_claim() {
        let tmp = tempfile::TempDir::new().unwrap();
        let store = NotebookCaptureStore::new(&tmp.path().join("capture.db")).unwrap();
        store
            .open_provider_remote_artifact_claim("task-1", "session-1", "zulangue-task-1")
            .unwrap();
        store
            .record_provider_remote_file("task-1", "file-1")
            .unwrap();
        store
            .record_provider_remote_transcription("task-1", "tr-1")
            .unwrap();

        let mock = start_sweep_mock(SweepMockPlan::default()).await;
        sweep_orphaned_remote_artifacts(&store, &mock.base_url, "key").await;

        // 两个 id 都在库里时不需要拉清单，直接按 id 删；先转录后文件。
        assert_eq!(
            mock.paths(),
            vec![
                "DELETE /v1/transcriptions/tr-1".to_string(),
                "DELETE /v1/files/file-1".to_string(),
            ]
        );
        assert!(store
            .list_provider_remote_artifact_claims()
            .unwrap()
            .is_empty());
    }

    #[tokio::test]
    async fn startup_sweep_recovers_orphans_by_reference_tag_when_ids_never_landed() {
        let tmp = tempfile::TempDir::new().unwrap();
        let store = NotebookCaptureStore::new(&tmp.path().join("capture.db")).unwrap();
        store
            .open_provider_remote_artifact_claim("task-2", "session-2", "zulangue-task-2")
            .unwrap();

        let mock = start_sweep_mock(SweepMockPlan {
            files_body: r#"{"files":[
                {"id":"file-2","filename":"zulangue-task-2.wav"},
                {"id":"other-file","filename":"zulangue-task-999.wav"}
            ]}"#
            .to_string(),
            transcriptions_body: r#"{"transcriptions":[
                {"id":"tr-2","client_reference_id":"zulangue-task-2"},
                {"id":"other-tr","client_reference_id":"zulangue-task-999"}
            ]}"#
            .to_string(),
            ..SweepMockPlan::default()
        })
        .await;
        sweep_orphaned_remote_artifacts(&store, &mock.base_url, "key").await;

        let paths = mock.paths();
        assert!(paths.contains(&"DELETE /v1/transcriptions/tr-2".to_string()));
        assert!(paths.contains(&"DELETE /v1/files/file-2".to_string()));
        // 别的设备正在跑的工件不属于本机 claim，绝不能被扫掉。
        assert!(!paths.contains(&"DELETE /v1/files/other-file".to_string()));
        assert!(!paths.contains(&"DELETE /v1/transcriptions/other-tr".to_string()));
        assert!(store
            .list_provider_remote_artifact_claims()
            .unwrap()
            .is_empty());
    }

    #[tokio::test]
    async fn startup_sweep_keeps_the_claim_when_the_remote_listing_is_unavailable() {
        let tmp = tempfile::TempDir::new().unwrap();
        let store = NotebookCaptureStore::new(&tmp.path().join("capture.db")).unwrap();
        store
            .open_provider_remote_artifact_claim("task-3", "session-3", "zulangue-task-3")
            .unwrap();

        let mock = start_sweep_mock(SweepMockPlan {
            fail_list: true,
            ..SweepMockPlan::default()
        })
        .await;
        sweep_orphaned_remote_artifacts(&store, &mock.base_url, "key").await;

        // 清单拉不到就不能断言远端已经干净；claim 行留到下次启动重试。
        assert_eq!(
            store.list_provider_remote_artifact_claims().unwrap().len(),
            1
        );
    }

    #[tokio::test]
    async fn startup_sweep_keeps_the_claim_when_remote_deletion_fails() {
        let tmp = tempfile::TempDir::new().unwrap();
        let store = NotebookCaptureStore::new(&tmp.path().join("capture.db")).unwrap();
        store
            .open_provider_remote_artifact_claim("task-4", "session-4", "zulangue-task-4")
            .unwrap();
        store
            .record_provider_remote_file("task-4", "file-4")
            .unwrap();
        store
            .record_provider_remote_transcription("task-4", "tr-4")
            .unwrap();

        let mock = start_sweep_mock(SweepMockPlan {
            fail_delete: true,
            ..SweepMockPlan::default()
        })
        .await;
        sweep_orphaned_remote_artifacts(&store, &mock.base_url, "key").await;

        assert_eq!(
            store.list_provider_remote_artifact_claims().unwrap().len(),
            1
        );
    }
}
