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

use crate::notebook_capture_api::FfiNotebookCaptureLivePreview;
use crate::{CoreError, ZulangueCore};

/// 用 Loro 回答「这份远端更新碰了采集投影拥有的区间吗」。
///
/// `vt-share` 定义了这个端口却不实现它:判定必须真的把更新应用一次才知道它动了
/// 哪里,而那需要持有文档。实现落在这里,探测跑在 `EditorBridge` fork 出的副本上。
///
/// 文档 id 由载荷带来,归属判定见 [`LoroDocumentSync::document_in_scope`]。
pub(crate) struct LoroCaptureBoundaryGuard {
    editor: vt_store::EditorBridge,
}

impl LoroCaptureBoundaryGuard {
    pub(crate) fn new(editor: vt_store::EditorBridge) -> Self {
        Self { editor }
    }
}

impl vt_share::CaptureBoundaryGuard for LoroCaptureBoundaryGuard {
    fn touches_capture_owned_range(
        &self,
        _scope: &ScopeId,
        document_id: &str,
        update: &[u8],
    ) -> bool {
        self.editor
            .remote_update_touches_capture_owned_range(document_id, update)
    }
}

/// 用 `EditorBridge` 回答文档同步的三个问题。
///
/// 与 [`LoroCaptureBoundaryGuard`] 同理:`vt-share` 定义端口但不认识 Loro,
/// 实现落在持有文档的这一侧。
///
/// 共享范围里有哪些文档,由这一层回答。
///
/// 按单次录音共享时只有一篇,id 就是 session_id;按 Notebook 共享时是该 Notebook
/// 下的全部录音,来自 `list_notebook_capture_history_summaries`。
///
/// **归属判定是这里最要紧的一件事。** 文档 id 随载荷从对端来,不验就等于允许一个
/// 房间去写它管不着的文档。任何查不出来的情况都判为不属于 —— 放行等于没有这道检查。
pub(crate) struct LoroDocumentSync {
    editor: vt_store::EditorBridge,
    capture_store: Arc<vt_store::NotebookCaptureStore>,
}

impl LoroDocumentSync {
    pub(crate) fn new(
        editor: vt_store::EditorBridge,
        capture_store: Arc<vt_store::NotebookCaptureStore>,
    ) -> Self {
        Self {
            editor,
            capture_store,
        }
    }
}

impl vt_share::DocumentSync for LoroDocumentSync {
    fn documents(&self, scope: &ScopeId) -> Vec<String> {
        match scope {
            ScopeId::Session { session_id } => vec![session_id.clone()],
            ScopeId::Notebook { notebook_id } => self
                .capture_store
                .list_notebook_capture_history_summaries(notebook_id)
                .map(|runs| runs.into_iter().map(|run| run.session_id).collect())
                .unwrap_or_default(),
        }
    }

    fn document_in_scope(&self, scope: &ScopeId, document_id: &str) -> bool {
        match scope {
            ScopeId::Session { session_id } => session_id == document_id,
            ScopeId::Notebook { .. } => self.documents(scope).iter().any(|id| id == document_id),
        }
    }

    fn version(&self, _scope: &ScopeId, document_id: &str) -> Vec<u8> {
        self.editor
            .document_version(document_id)
            .unwrap_or_default()
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
        self.editor.import_remote_update(document_id, update)
    }
}

/// 官方中继。用户可以在设置里改掉或清空。
///
/// 清空**不是故障状态**:局域网内直连本来就不需要中继,分享码里带着直连地址,
/// 断网也能配对。中继只在跨网络打洞失败时才介入。
pub const DEFAULT_RELAY_URL: &str = "https://zulangue-relay.exe.xyz";

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

/// 分享的传输配置。由设置页决定,不参与共享协议本身。
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiShareTransport {
    /// 中继地址。为空表示只走直连 —— 局域网可用,跨网络打洞失败时没有兜底。
    pub relay_urls: Vec<String>,
    /// 局域网 mDNS 发现。macOS 15+ 首次会弹系统授权;拒绝后仍可用分享码配对。
    pub enable_local_discovery: bool,
}

impl Default for FfiShareTransport {
    fn default() -> Self {
        Self {
            relay_urls: vec![DEFAULT_RELAY_URL.to_string()],
            enable_local_discovery: true,
        }
    }
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
    /// 绑定这个端点时用的传输配置,用于判断设置变了要不要重建。
    transport: FfiShareTransport,
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
        let wanted = self.share_transport.lock().unwrap().clone();
        let mut guard = self.share_runtime.lock().unwrap();
        if let Some(runtime) = guard.as_ref() {
            // 设置没变就复用。变了且当前没在共享,就丢掉重建;正在共享时不动,
            // 中途换中继会把房间里的人踢掉,不值得。
            let idle = runtime.hosting.is_none() && runtime.viewing.is_none();
            if runtime.transport == wanted || !idle {
                return Ok(runtime.endpoint.clone());
            }
        }

        let identity = self.load_or_create_share_identity()?;
        let relay_urls = vt_share::parse_relay_urls(&wanted.relay_urls)
            .map_err(|message| CoreError::ValidationFailed { message })?;
        let config = ShareEndpointConfig {
            relay_urls,
            enable_local_discovery: wanted.enable_local_discovery,
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
            transport: wanted,
        });
        Ok(endpoint)
    }
}

#[uniffi::export]
impl ZulangueCore {
    /// 出厂默认的传输配置。设置页用它做「恢复默认」。
    pub fn default_share_transport(&self) -> FfiShareTransport {
        FfiShareTransport::default()
    }

    /// 当前生效的传输配置。
    pub fn share_transport(&self) -> FfiShareTransport {
        self.share_transport.lock().unwrap().clone()
    }

    /// 设定传输配置。
    ///
    /// 当前没在共享时立即生效(下次用到端点会按新配置重建);正在共享时保留现有
    /// 连接,新配置在下一次开始共享时生效 —— 中途换中继会把房间里的人踢掉。
    pub fn set_share_transport(&self, transport: FfiShareTransport) -> Result<(), CoreError> {
        // 先校验再落库,免得存进一个连不上的地址。
        vt_share::parse_relay_urls(&transport.relay_urls)
            .map_err(|message| CoreError::ValidationFailed { message })?;
        *self.share_transport.lock().unwrap() = transport;
        Ok(())
    }

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
            sink: Arc::new(LoroDocumentSync::new(
                self.editor_bridge.clone(),
                self.notebook_capture_store.clone(),
            )),
        };
        let endpoint = runtime.endpoint.clone();
        self.runtime
            .block_on(async move { endpoint.enable_document_sync(context).await });
        Ok(())
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

/// 采集侧到分享通道的接线。
///
/// 挂在**回调派发线程**上,不在采集热路径上:那里已经做过合并,是「Swift 将要看到
/// 什么」唯一确定的地方,广播出去的内容因此与本机屏幕上的完全一致。
///
/// `broadcast_caption` 立即返回、对慢接收者丢帧,所以这一步不会拖慢派发。
#[derive(Clone)]
pub(crate) struct ShareCaptionTap {
    runtime: Arc<ShareRuntimeSlot>,
}

impl ShareCaptionTap {
    pub(crate) fn new(runtime: Arc<ShareRuntimeSlot>) -> Self {
        Self { runtime }
    }

    /// 把一帧本机预览广播给房间。非主持人、未共享、范围不符时都是 no-op。
    pub(crate) fn broadcast(&self, preview: &FfiNotebookCaptureLivePreview) {
        let Ok(guard) = self.runtime.lock() else {
            return;
        };
        let Some(runtime) = guard.as_ref() else {
            return;
        };
        // 只有主持人广播自己的字幕。观看者手里的是别人的内容,不该再转发出去。
        let Some(hosting) = runtime.hosting.as_ref() else {
            return;
        };
        let scope = &hosting.code.scope;

        // 按单次录音共享时,只广播那一场的字幕。
        if let ScopeId::Session { session_id } = scope {
            if session_id != &preview.session_id {
                return;
            }
        }

        runtime
            .endpoint
            .broadcast_caption(caption_frame_from(scope.clone(), preview));
    }
}

/// 把一帧本机预览翻成线上帧。
///
/// **两条车道原样过去,不在这里重做对应关系。** utterance 与 translation cue 的
/// 对应是按时间区间在读取时回答的(见 timeline-projection.md),让接收端重算一遍会
/// 让两端得出不同的结果。所以这里只做搬运。
fn caption_frame_from(
    scope: ScopeId,
    preview: &FfiNotebookCaptureLivePreview,
) -> vt_share::CaptionFrame {
    let mut lines: Vec<vt_share::CaptionLine> = preview
        .utterances
        .iter()
        .map(|u| vt_share::CaptionLine {
            speaker: u.session_speaker_id.clone(),
            // 推测性尾部的 durable 语言可能还是 und,此时用临时标签,
            // 让对端能立刻把它放进正确的车道。
            source_language: u
                .provisional_source_language
                .clone()
                .unwrap_or_else(|| u.source_language.clone()),
            source_text: u.source_text.clone(),
            target_language: u.translated_language.clone(),
            target_text: u.translated_text.clone(),
            completion: u.completion.clone(),
        })
        .collect();

    lines.extend(
        preview
            .translation_cues
            .iter()
            .filter(|c| !c.withdrawn)
            .map(|c| vt_share::CaptionLine {
                speaker: None,
                source_language: c.source_language.clone(),
                source_text: String::new(),
                target_language: Some(c.target_language.clone()),
                target_text: Some(c.text.clone()),
                completion: c.completion.clone(),
            }),
    );

    vt_share::CaptionFrame {
        scope,
        preview_revision: preview.preview_revision,
        lines,
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

    /// 整条准入链跑一遍,走的是真实入口 `handle_incoming_update`。
    ///
    /// 这条测试的意义在于串起三个 crate:`vt-share` 出规则、`vt-store` 出 Loro
    /// 判定、`vt-ffi` 把两者接上。任何一处接错,这里就会放行一份该拒的更新。
    fn remote_edit(session_id: &str, at: usize) -> (vt_store::EditorBridge, Vec<u8>) {
        use loro::LoroDoc;
        use vt_store::EditorBridge;

        let doc = LoroDoc::new();
        doc.get_text("content").insert(0, "0123456789").unwrap();
        doc.commit();
        let editor = EditorBridge::new();
        editor.open(session_id, doc).unwrap();
        editor
            .set_capture_owned_range(session_id, "owner", "cap-1", 2, 6)
            .unwrap();

        // 远端从同一份快照分叉,产生一份真实可合入的更新。
        let remote = LoroDoc::new();
        remote
            .import(&editor.export_snapshot(session_id).unwrap())
            .unwrap();
        let before = remote.oplog_vv();
        remote.get_text("content").insert(at, "插进来").unwrap();
        remote.commit();
        let update = remote.export(loro::ExportMode::updates(&before)).unwrap();
        (editor, update)
    }

    fn run_chain(
        session_id: &str,
        document_id: &str,
        update: Vec<u8>,
        editor: vt_store::EditorBridge,
    ) -> vt_share::IncomingOutcome {
        use vt_share::{handle_incoming_update, seal_update, RoomRoster, WritePolicy};

        let scope = ScopeId::Session {
            session_id: session_id.into(),
        };
        let host = iroh::SecretKey::generate();
        let roster = RoomRoster::new(scope.clone(), host.public(), WritePolicy::Everyone);
        let envelope = seal_update(&scope, document_id, update, &host).unwrap();

        // NotebookCaptureStore 只在 Notebook 范围下才被问到,Session 范围用不着它。
        let store = Arc::new(
            vt_store::notebook_capture_store::NotebookCaptureStore::new(&std::path::PathBuf::from(
                ":memory:",
            ))
            .unwrap(),
        );
        handle_incoming_update(
            &envelope,
            &roster,
            &LoroCaptureBoundaryGuard::new(editor.clone()),
            &LoroDocumentSync::new(editor, store),
        )
    }

    #[test]
    fn admission_chain_refuses_a_remote_edit_inside_the_capture_range() {
        let (editor, update) = remote_edit("session-1", 4);
        assert_eq!(
            run_chain("session-1", "session-1", update, editor),
            vt_share::IncomingOutcome::Denied(vt_share::AdmissionDenial::TouchesCaptureOwnedRange)
        );
    }

    /// 落在采集区间之外的同一条链路必须放行,否则这道门就是「拒绝一切」。
    #[test]
    fn admission_chain_accepts_a_remote_edit_outside_the_capture_range() {
        let (editor, update) = remote_edit("session-2", 9);
        assert_eq!(
            run_chain("session-2", "session-2", update, editor),
            vt_share::IncomingOutcome::Applied
        );
    }

    /// 按录音共享的房间,不能被用来写进另一篇文档。
    ///
    /// 文档 id 由对端声称,这是唯一挡住它的检查。
    #[test]
    fn a_session_room_cannot_write_into_another_document() {
        let (editor, update) = remote_edit("session-3", 9);
        assert_eq!(
            run_chain("session-3", "somebody-elses-doc", update, editor),
            vt_share::IncomingOutcome::Denied(vt_share::AdmissionDenial::DocumentNotInScope)
        );
    }

    fn preview(session_id: &str, revision: u64) -> FfiNotebookCaptureLivePreview {
        use crate::notebook_capture_api::{
            FfiNotebookCaptureTranslationCue, FfiNotebookCaptureUtterance,
        };
        FfiNotebookCaptureLivePreview {
            session_id: session_id.into(),
            preview_revision: revision,
            utterances: vec![FfiNotebookCaptureUtterance {
                id: "u1".into(),
                session_id: session_id.into(),
                sequence: 1,
                revision: 1,
                session_speaker_id: Some("spk".into()),
                source_language: "und".into(),
                provisional_source_language: Some("ja".into()),
                source_text: "こんにちは".into(),
                source_start_ms: Some(0),
                source_end_ms: Some(500),
                translated_language: Some("zh-Hans".into()),
                translated_text: Some("你好".into()),
                completion: "partial".into(),
                alignment: "aligned".into(),
                source_projection_revision: 0,
                source_edit_revision: 0,
                language_variants: vec![],
            }],
            translation_cues: vec![
                FfiNotebookCaptureTranslationCue {
                    target_language: "ko".into(),
                    group_epoch: 1,
                    provider_sequence: 1,
                    source_language: "ja".into(),
                    source_start_ms: Some(0),
                    source_end_ms: Some(500),
                    text: "안녕하세요".into(),
                    completion: "partial".into(),
                    withdrawn: false,
                    revision: 1,
                },
                // 已撤回的 cue 不该被广播出去。
                FfiNotebookCaptureTranslationCue {
                    target_language: "fr".into(),
                    group_epoch: 1,
                    provider_sequence: 2,
                    source_language: "ja".into(),
                    source_start_ms: Some(0),
                    source_end_ms: Some(500),
                    text: "retiré".into(),
                    completion: "partial".into(),
                    withdrawn: true,
                    revision: 1,
                },
            ],
            lane_health: vec![],
        }
    }

    /// 两条车道原样过去,撤回的 cue 不发。
    #[test]
    fn frame_carries_both_lanes_and_drops_withdrawn_cues() {
        let scope = ScopeId::Session {
            session_id: "s".into(),
        };
        let frame = caption_frame_from(scope.clone(), &preview("s", 9));

        assert_eq!(frame.preview_revision, 9);
        assert_eq!(frame.scope, scope);
        assert_eq!(frame.lines.len(), 2, "一条 utterance + 一条未撤回的 cue");

        // 推测性尾部的 durable 语言还是 und,应当用临时标签,否则对端放不进车道。
        assert_eq!(frame.lines[0].source_language, "ja");
        assert_eq!(frame.lines[0].source_text, "こんにちは");
        assert_eq!(frame.lines[0].target_text.as_deref(), Some("你好"));
        assert_eq!(frame.lines[0].speaker.as_deref(), Some("spk"));

        assert_eq!(frame.lines[1].target_language.as_deref(), Some("ko"));
        assert!(
            frame
                .lines
                .iter()
                .all(|l| l.target_text.as_deref() != Some("retiré")),
            "撤回的 cue 不该出现在线上帧里"
        );
    }

    /// **音频门禁在这一层的具体形态:线上帧里没有任何可以承载 PCM 的字段。**
    #[test]
    fn frame_is_text_only() {
        let frame = caption_frame_from(
            ScopeId::Session {
                session_id: "s".into(),
            },
            &preview("s", 1),
        );
        let json = serde_json::to_string(&frame).unwrap();
        for banned in ["pcm", "audio", "wav", "sample_rate", "channels"] {
            assert!(
                !json.to_ascii_lowercase().contains(banned),
                "线上字幕帧不得出现 {banned}"
            );
        }
    }

    /// 出厂默认必须真的带上官方中继 —— 忘了接线的话,机器部署了也没人用。
    #[test]
    fn default_transport_points_at_the_deployed_relay() {
        let t = FfiShareTransport::default();
        assert_eq!(t.relay_urls, vec![DEFAULT_RELAY_URL.to_string()]);
        assert!(t.enable_local_discovery);
        assert!(
            vt_share::parse_relay_urls(&t.relay_urls).is_ok(),
            "默认地址必须解析得动"
        );
    }

    /// 清空中继是合法选择 —— 局域网直连不需要它。
    #[test]
    fn an_empty_relay_list_is_accepted() {
        assert!(vt_share::parse_relay_urls(&[]).unwrap().is_empty());
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
