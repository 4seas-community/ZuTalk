//! 分享:点对点字幕与文本资源的 FFI 面。
//!
//! 传输层在 `vt-share`。这里只做三件事:把身份存进本机既有的受保护密钥库、把
//! 共享范围与分享码翻成 Swift 能拿的类型、把收到的字幕投影暴露出去。
//!
//! # 为什么身份的持久化在这一层
//!
//! `vt-share` 刻意不依赖 `vt-crypto`(那样它就够不到音频解密),所以它只接收和交出
//! 密钥字节,落盘由这里用既有的 `KeyProvider` 完成。
//!
//! # 为什么字幕用轮询而不是回调
//!
//! 帧是 replace-in-full 的:每一帧都描述完整的当前 tail,跳帧无害。因此「每 N 毫秒
//! 取一次最新状态」与「每帧回调一次」在观感上等价,却省掉一整套跨 FFI 的回调生命
//! 周期管理。这与采集的 `on_live_preview` 不同 —— 那条链路要驱动本机的持久化时间线,
//! 这条只驱动一块只读画布。
//!
//! 设计见 `docs/architecture/share-p2p.md`。

use std::str::FromStr;
use std::sync::{Arc, Mutex};

use vt_crypto::SessionKey;
use vt_share::net::{receive_captions, CaptionInbox};
use vt_share::{
    CaptionReceiver, ScopeId, ShareCode, ShareEndpoint, ShareEndpointConfig, ShareIdentity,
    WritePolicy,
};

use crate::{CoreError, ZulangueCore};

/// 用 Loro 回答「这份远端更新碰了采集投影拥有的区间吗」。
///
/// `vt-share` 定义了这个端口却不实现它:判定必须真的把更新应用一次才知道它动了
/// 哪里,而那需要持有文档。实现落在这里,探测跑在 `EditorBridge` fork 出的副本上。
///
/// 共享范围到文档 id 的映射是刻意保守的:只有按单次录音共享时才存在可判定的文档。
/// 按 Notebook 共享时一次更新可能落在任意一篇上,在把范围收窄到具体文档之前,
/// 这里一律拒收 —— 判不出来时放行等于这道门不存在。
pub(crate) struct LoroCaptureBoundaryGuard {
    editor: vt_store::EditorBridge,
}

impl LoroCaptureBoundaryGuard {
    pub(crate) fn new(editor: vt_store::EditorBridge) -> Self {
        Self { editor }
    }
}

impl vt_share::CaptureBoundaryGuard for LoroCaptureBoundaryGuard {
    fn touches_capture_owned_range(&self, scope: &ScopeId, update: &[u8]) -> bool {
        match scope {
            ScopeId::Session { session_id } => self
                .editor
                .remote_update_touches_capture_owned_range(session_id, update),
            ScopeId::Notebook { .. } => true,
        }
    }
}

/// 用 `EditorBridge` 回答文档同步的三个问题。
///
/// 与 [`LoroCaptureBoundaryGuard`] 同理:`vt-share` 定义端口但不认识 Loro,
/// 实现落在持有文档的这一侧。
///
/// 只有按单次录音共享时才存在可判定的文档;按 Notebook 共享时一次更新可能落在
/// 任意一篇上,在把范围收窄到具体文档之前,这里不提供也不合入任何东西。
pub(crate) struct LoroDocumentSync {
    editor: vt_store::EditorBridge,
}

impl LoroDocumentSync {
    pub(crate) fn new(editor: vt_store::EditorBridge) -> Self {
        Self { editor }
    }

    fn document_id(scope: &ScopeId) -> Option<&str> {
        match scope {
            ScopeId::Session { session_id } => Some(session_id),
            ScopeId::Notebook { .. } => None,
        }
    }
}

impl vt_share::DocumentSync for LoroDocumentSync {
    fn version(&self, scope: &ScopeId) -> Vec<u8> {
        Self::document_id(scope)
            .and_then(|id| self.editor.document_version(id))
            .unwrap_or_default()
    }

    fn updates_since(&self, scope: &ScopeId, version: &[u8]) -> Option<Vec<u8>> {
        self.editor
            .updates_since(Self::document_id(scope)?, version)
    }

    fn apply(&self, scope: &ScopeId, update: &[u8]) -> bool {
        Self::document_id(scope)
            .map(|id| self.editor.import_remote_update(id, update))
            .unwrap_or(false)
    }
}

/// 身份密钥在本机密钥库里的固定名字。
///
/// 身份稳定是前提:换一次,联系人保存下来的公钥就全部失效。所以它不随 session
/// 轮换,只有一份。
const SHARE_IDENTITY_KEY_REF: &str = "share-identity";

/// 本机的分享身份。
#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiShareIdentity {
    /// 完整公钥的十六进制形式。对方要的就是它。
    pub endpoint_id: String,
    /// 给人看的短形式,用于界面与日志。
    pub short_label: String,
}

/// 一行收到的字幕。**纯文本,没有任何音频字段。**
#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiSharedCaptionLine {
    pub speaker: Option<String>,
    pub source_language: String,
    pub source_text: String,
    pub target_language: Option<String>,
    pub target_text: Option<String>,
    /// "partial" 或 "complete"。
    pub completion: String,
}

/// 当前共享状态的一帧快照。
#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiShareState {
    pub is_sharing: bool,
    /// 作为观看者加入了别人的房间。
    pub is_viewing: bool,
    /// 只读房间(主持人可写,其他人只读)。
    pub host_only: bool,
    /// 本机是这个房间的主持人。
    pub is_host: bool,
    /// 已应用的字幕帧号;还没收到任何帧时为 `None`。
    pub applied_revision: Option<u64>,
    pub lines: Vec<FfiSharedCaptionLine>,
}

/// 进程内的分享运行时。
pub(crate) struct ShareRuntime {
    endpoint: Arc<ShareEndpoint>,
    /// 主持时持有的房间;`None` 表示本机只是观看者或未共享。
    hosting: Option<HostedRoom>,
    /// 观看别人时的接收侧。
    viewing: Option<ViewedRoom>,
    /// 当前房间名册。主持与加入时都会建立,决定谁能写文档。
    roster: Option<vt_share::RoomRoster>,
}

struct HostedRoom {
    code: ShareCode,
}

struct ViewedRoom {
    scope: ScopeId,
    host_only: bool,
    inbox: CaptionInbox,
    projection: CaptionReceiver,
    task: tokio::task::JoinHandle<()>,
}

impl Drop for ViewedRoom {
    fn drop(&mut self) {
        self.task.abort();
    }
}

impl ZulangueCore {
    /// 取回本机身份,首次调用时生成并存进密钥库。
    fn load_or_create_share_identity(&self) -> Result<ShareIdentity, CoreError> {
        if self.key_store.key_exists(SHARE_IDENTITY_KEY_REF) {
            let key = self
                .key_store
                .load_key(SHARE_IDENTITY_KEY_REF)
                .map_err(|error| CoreError::InternalError {
                    message: format!("读取分享身份失败: {error}"),
                })?;
            return Ok(ShareIdentity::from_secret_bytes(key.as_bytes()));
        }

        let identity = ShareIdentity::generate();
        let key = SessionKey::from_bytes(identity.to_secret_bytes());
        self.key_store
            .store_key(SHARE_IDENTITY_KEY_REF, &key)
            .map_err(|error| CoreError::InternalError {
                message: format!("保存分享身份失败: {error}"),
            })?;
        Ok(identity)
    }

    /// 确保端点已绑定,返回它。
    fn ensure_share_endpoint(&self) -> Result<Arc<ShareEndpoint>, CoreError> {
        let mut guard = self.share_runtime.lock().unwrap();
        if let Some(runtime) = guard.as_ref() {
            return Ok(runtime.endpoint.clone());
        }

        let identity = self.load_or_create_share_identity()?;
        // 中继与局域网发现由设置决定;两者都关掉时仍可用分享码点对点配对。
        let config = ShareEndpointConfig {
            relay_urls: Vec::new(),
            enable_local_discovery: true,
        };
        let endpoint = self
            .runtime
            .block_on(ShareEndpoint::bind(&identity, config))
            .map_err(|error| CoreError::InternalError {
                message: format!("启动分享端点失败: {error}"),
            })?;
        let endpoint = Arc::new(endpoint);
        *guard = Some(ShareRuntime {
            endpoint: endpoint.clone(),
            hosting: None,
            viewing: None,
            roster: None,
        });
        Ok(endpoint)
    }
}

#[uniffi::export]
impl ZulangueCore {
    /// 本机分享身份。首次调用会生成并持久化。
    pub fn share_identity(&self) -> Result<FfiShareIdentity, CoreError> {
        let identity = self.load_or_create_share_identity()?;
        Ok(FfiShareIdentity {
            endpoint_id: identity.endpoint_id().to_string(),
            short_label: identity.short_label(),
        })
    }

    /// 开始共享,返回交给对方的分享码。
    ///
    /// `notebook_id` 与 `session_id` 二选一:前者按 Notebook 共享(其中开始的录音
    /// 默认参与),后者只共享指定的一次录音。
    pub fn start_sharing(
        &self,
        notebook_id: Option<String>,
        session_id: Option<String>,
        host_only: bool,
    ) -> Result<String, CoreError> {
        let scope = match (notebook_id, session_id) {
            (Some(notebook_id), None) => ScopeId::Notebook { notebook_id },
            (None, Some(session_id)) => ScopeId::Session { session_id },
            _ => {
                return Err(CoreError::ValidationFailed {
                    message: "共享范围必须且只能指定 notebook_id 或 session_id 之一".into(),
                })
            }
        };

        let endpoint = self.ensure_share_endpoint()?;
        let identity_id = endpoint.endpoint_id();
        let host = self.runtime.block_on(endpoint.endpoint_addr());
        let code = ShareCode::new(
            host,
            scope,
            vt_share::RoomSecret::generate(),
            if host_only {
                WritePolicy::HostOnly
            } else {
                WritePolicy::Everyone
            },
        );

        let mut guard = self.share_runtime.lock().unwrap();
        let runtime = guard.as_mut().expect("端点刚刚建立");
        runtime.roster = Some(vt_share::RoomRoster::new(
            code.scope.clone(),
            identity_id,
            code.policy,
        ));
        runtime.hosting = Some(HostedRoom { code: code.clone() });
        Ok(code.to_string())
    }

    /// 停止共享。
    ///
    /// **只停止继续发送。** 已经合并进对方文档的内容无法收回 —— 房间密钥轮换让老成员
    /// 拿不到后续、也进不来新房间,仅此而已。界面必须如实说明这一点。
    pub fn stop_sharing(&self) -> Result<(), CoreError> {
        let mut guard = self.share_runtime.lock().unwrap();
        if let Some(runtime) = guard.as_mut() {
            runtime.hosting = None;
            // ViewedRoom 的 Drop 会中止接收任务。
            runtime.viewing = None;
            runtime.roster = None;
        }
        Ok(())
    }

    /// 用分享码加入别人的房间。
    pub fn join_share(&self, code: String) -> Result<(), CoreError> {
        let parsed = ShareCode::from_str(&code).map_err(|error| CoreError::ValidationFailed {
            message: format!("分享码无法解析: {error}"),
        })?;

        let endpoint = self.ensure_share_endpoint()?;
        let inbox = CaptionInbox::default();
        let scope = parsed.scope.clone();
        let host_addr = parsed.host.clone();

        let task = {
            let endpoint = endpoint.clone();
            let inbox = inbox.clone();
            let scope = scope.clone();
            self.runtime.spawn(async move {
                if let Err(error) = receive_captions(&endpoint, host_addr, scope, inbox).await {
                    tracing::warn!(%error, "字幕接收结束");
                }
            })
        };

        let mut guard = self.share_runtime.lock().unwrap();
        let runtime = guard.as_mut().expect("端点刚刚建立");
        runtime.roster = Some(vt_share::RoomRoster::new(
            parsed.scope.clone(),
            parsed.host.id,
            parsed.policy,
        ));
        runtime.viewing = Some(ViewedRoom {
            scope,
            host_only: matches!(parsed.policy, WritePolicy::HostOnly),
            inbox,
            projection: CaptionReceiver::new(),
            task,
        });
        Ok(())
    }

    /// 打开文档协同。
    ///
    /// 必须在共享已经开始之后调用 —— 它要用当前房间的名册判定谁能写。之后本机的
    /// 每一笔编辑都会推给对端,对端推来的每一笔都要过完整条准入链才会合入。
    pub fn enable_document_sync(&self) -> Result<(), CoreError> {
        let guard = self.share_runtime.lock().unwrap();
        let Some(runtime) = guard.as_ref() else {
            return Err(CoreError::ValidationFailed {
                message: "尚未开始共享".into(),
            });
        };
        let Some(roster) = runtime.roster.clone() else {
            return Err(CoreError::ValidationFailed {
                message: "尚未开始共享".into(),
            });
        };
        let context = vt_share::DocSyncContext {
            scope: roster.scope().clone(),
            roster: Arc::new(tokio::sync::Mutex::new(roster)),
            guard: Arc::new(LoroCaptureBoundaryGuard::new(self.editor_bridge.clone())),
            sink: Arc::new(LoroDocumentSync::new(self.editor_bridge.clone())),
        };
        let endpoint = runtime.endpoint.clone();
        self.runtime
            .block_on(async move { endpoint.enable_document_sync(context).await });
        Ok(())
    }

    /// 一份收到的文档更新是否可以合入。
    ///
    /// 走完整条准入链:验签 → 成员资格 → 写入策略 → 编辑边界。最后一步用 Loro 在
    /// 副本上试应用,回答「它碰了采集投影拥有的区间吗」。
    ///
    /// **返回 false 就必须丢弃。** 任何判不出来的情况都返回 false —— 判不出来时
    /// 放行,等于这道门不存在。
    pub fn share_admits_document_update(&self, envelope: Vec<u8>) -> bool {
        let guard = self.share_runtime.lock().unwrap();
        let Some(runtime) = guard.as_ref() else {
            return false;
        };
        let Some(roster) = runtime.roster.as_ref() else {
            return false;
        };
        let Ok(envelope) = vt_share::ShareEnvelope::decode_compact(&envelope) else {
            return false;
        };
        let boundary = LoroCaptureBoundaryGuard::new(self.editor_bridge.clone());
        vt_share::admit_document_update(&envelope, roster, &boundary).is_ok()
    }

    /// 取当前分享状态与字幕投影。
    ///
    /// 每次调用会吸收自上次以来收到的所有帧;因为帧是 replace-in-full 的,只有最新
    /// 的那一帧会留下痕迹,中间被跳过的帧不需要补。
    pub fn share_state(&self) -> FfiShareState {
        let mut guard = self.share_runtime.lock().unwrap();
        let Some(runtime) = guard.as_mut() else {
            return FfiShareState {
                is_sharing: false,
                is_viewing: false,
                host_only: false,
                is_host: false,
                applied_revision: None,
                lines: Vec::new(),
            };
        };

        let is_host = runtime.hosting.is_some();
        let host_only = match (&runtime.hosting, &runtime.viewing) {
            (Some(room), _) => matches!(room.code.policy, WritePolicy::HostOnly),
            (None, Some(room)) => room.host_only,
            _ => false,
        };

        let mut applied_revision = None;
        let mut lines = Vec::new();
        if let Some(room) = runtime.viewing.as_mut() {
            let scope = room.scope.clone();
            for frame in self.runtime.block_on(room.inbox.drain()) {
                room.projection.accept(frame, &scope);
            }
            applied_revision = room.projection.applied_revision();
            lines = room
                .projection
                .lines()
                .iter()
                .map(|line| FfiSharedCaptionLine {
                    speaker: line.speaker.clone(),
                    source_language: line.source_language.clone(),
                    source_text: line.source_text.clone(),
                    target_language: line.target_language.clone(),
                    target_text: line.target_text.clone(),
                    completion: line.completion.clone(),
                })
                .collect();
        }

        FfiShareState {
            is_sharing: is_host || runtime.viewing.is_some(),
            is_viewing: runtime.viewing.is_some(),
            host_only,
            is_host,
            applied_revision,
            lines,
        }
    }
}

/// 供 `ZulangueCore` 持有的运行时槽位。
pub(crate) type ShareRuntimeSlot = Mutex<Option<ShareRuntime>>;

#[cfg(test)]
mod tests {
    use super::*;
    use vt_crypto::MemoryKeyStore;

    /// 身份必须稳定:第二次取回的公钥要和第一次相同,否则联系人保存的公钥会失效。
    #[test]
    fn identity_survives_a_reload_from_the_key_store() {
        let store = MemoryKeyStore::new();
        let first = ShareIdentity::generate();
        store
            .store_raw(SHARE_IDENTITY_KEY_REF, &first.to_secret_bytes())
            .unwrap();

        let loaded = store.load_key(SHARE_IDENTITY_KEY_REF).unwrap();
        let second = ShareIdentity::from_secret_bytes(loaded.as_bytes());
        assert_eq!(first.endpoint_id(), second.endpoint_id());
    }

    /// 整条准入链跑一遍:签名 → 成员 → 策略 → 编辑边界,最后一步用真实的 Loro 探测。
    ///
    /// 这条测试的意义在于串起三个 crate:`vt-share` 出规则、`vt-store` 出 Loro
    /// 判定、`vt-ffi` 把两者接上。任何一处接错,这里就会放行一份该拒的更新。
    #[test]
    fn admission_chain_refuses_a_remote_edit_inside_the_capture_range() {
        use loro::LoroDoc;
        use vt_share::{
            admit_document_update, AdmissionDenial, PayloadKind, RoomRoster, UnsignedEnvelope,
            WritePolicy,
        };
        use vt_store::EditorBridge;

        let doc = LoroDoc::new();
        doc.get_text("content").insert(0, "0123456789").unwrap();
        doc.commit();
        let editor = EditorBridge::new();
        editor.open("session-1", doc).unwrap();
        editor
            .set_capture_owned_range("session-1", "owner", "cap-1", 2, 6)
            .unwrap();

        // 远端从同一份快照分叉,产生一份真实可合入的更新。
        let remote = LoroDoc::new();
        remote
            .import(&editor.export_snapshot("session-1").unwrap())
            .unwrap();
        let before = remote.oplog_vv();
        remote.get_text("content").insert(4, "插进来").unwrap();
        remote.commit();
        let update = remote.export(loro::ExportMode::updates(&before)).unwrap();

        let scope = ScopeId::Session {
            session_id: "session-1".into(),
        };
        let host = iroh::SecretKey::generate();
        let roster = RoomRoster::new(scope.clone(), host.public(), WritePolicy::Everyone);
        let envelope =
            UnsignedEnvelope::new(scope, PayloadKind::DocumentUpdate, update).sign(&host);
        let guard = LoroCaptureBoundaryGuard::new(editor.clone());

        // 签名合法、是主持人、房间全员可写 —— 依然要被最后一步拦下。
        assert_eq!(
            admit_document_update(&envelope, &roster, &guard),
            Err(AdmissionDenial::TouchesCaptureOwnedRange)
        );
    }

    /// 落在采集区间之外的同一条链路必须放行,否则这道门就是「拒绝一切」。
    #[test]
    fn admission_chain_accepts_a_remote_edit_outside_the_capture_range() {
        use loro::LoroDoc;
        use vt_share::{
            admit_document_update, PayloadKind, RoomRoster, UnsignedEnvelope, WritePolicy,
        };
        use vt_store::EditorBridge;

        let doc = LoroDoc::new();
        doc.get_text("content").insert(0, "0123456789").unwrap();
        doc.commit();
        let editor = EditorBridge::new();
        editor.open("session-2", doc).unwrap();
        editor
            .set_capture_owned_range("session-2", "owner", "cap-1", 2, 6)
            .unwrap();

        let remote = LoroDoc::new();
        remote
            .import(&editor.export_snapshot("session-2").unwrap())
            .unwrap();
        let before = remote.oplog_vv();
        remote.get_text("content").insert(9, "尾巴").unwrap();
        remote.commit();
        let update = remote.export(loro::ExportMode::updates(&before)).unwrap();

        let scope = ScopeId::Session {
            session_id: "session-2".into(),
        };
        let host = iroh::SecretKey::generate();
        let roster = RoomRoster::new(scope.clone(), host.public(), WritePolicy::Everyone);
        let envelope =
            UnsignedEnvelope::new(scope, PayloadKind::DocumentUpdate, update).sign(&host);
        let guard = LoroCaptureBoundaryGuard::new(editor.clone());

        assert!(admit_document_update(&envelope, &roster, &guard).is_ok());
    }

    /// ed25519 私钥恰好是密钥库的槽位宽度,所以可以直接复用受保护的存储。
    #[test]
    fn identity_secret_matches_the_key_store_slot_width() {
        assert_eq!(
            ShareIdentity::generate().to_secret_bytes().len(),
            vt_crypto::KEY_SIZE
        );
    }
}
