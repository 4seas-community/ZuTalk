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
    CaptionReceiver, NearbyAnnouncement, ScopeId, ShareCode, ShareEndpoint, ShareEndpointConfig,
    ShareHeader, ShareIdentity, WritePolicy,
};

use crate::notebook_capture_api::FfiNotebookCaptureLivePreview;
use crate::{CoreError, ZuTalkCore};

/// 用 Loro 回答「这份远端更新碰了采集投影拥有的区间吗」。
///
/// `vt-share` 定义了这个端口却不实现它:判定必须真的把更新应用一次才知道它动了
/// 哪里,而那需要持有文档。实现落在这里,探测跑在 `EditorBridge` fork 出的副本上。
///
/// 文档 id 由载荷带来,归属判定见 [`crate::shared_session_docs::SharedDocSync`]。
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
        // T2 切换完成后,可共享的转录稿文档全部是第 2 纪元块文档,由
        // block_guard 的静态规则手册裁决。判不出纪元/种类(文档未打开、
        // 或残存的第 1 纪元文档)一律拒收——第 1 纪元的 fork+重放守卫
        // 已退役,失败关闭是它唯一正确的替身:放行等于这道门不存在。
        self.editor
            .epoch2_admission_refuses(document_id, update)
            .unwrap_or(true)
    }
}

/// 收到的共享内容落在这个 Notebook 里。
///
/// 别人的内容不该混进你自己的 Notebook —— 收进来的东西和你自己录的东西,
/// 保留策略、编辑权、归属都不一样。给它一个固定的家,用户一眼能分清。
pub const SHARED_INBOX_NOTEBOOK_TITLE: &str = "分享";
pub(crate) const SHARED_INBOX_NOTEBOOK_INTERNAL_TITLE: &str = "__zutalk_internal_shared_inbox__";

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
            // 默认打开:它驱动「同一网络里的人」—— 发现 → 请求 → 批准。
            // macOS 会因此弹一次本地网络权限框,拒绝后分享码那条路仍然可用。
            enable_local_discovery: true,
        }
    }
}

/// 同一网络里一场愿意被找到的直播。
///
/// 只有主持人为这一场打开了「让附近的人找到」才会出现;名字与标题是主持人
/// 同意公开的那两句话,已经收拾过。公钥短形式是唯一可核对的身份。
#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiNearbyPeer {
    pub endpoint_id: String,
    pub short_label: String,
    pub host_name: String,
    pub title: String,
}

/// 房间里的一个人。
#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiRoomMember {
    pub endpoint_id: String,
    pub short_label: String,
    /// 对方自报的昵称,可能为空或与别人重名 —— **公钥才是身份**。
    pub display_name: String,
    /// 是不是你自己。
    pub is_me: bool,
    pub is_host: bool,
    /// 主持人视角:这个成员的字幕连接实际走的链路。观看端看别人、
    /// 以及自己那一行都是 `None` —— 不知道就不显示,不猜。
    pub link: Option<FfiShareLinkPath>,
}

/// 一条等着你回答的加入请求。
#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiJoinRequest {
    pub request_id: String,
    /// 请求方的公钥。**这是唯一可信的身份** —— 名字是对方自己写的。
    pub endpoint_id: String,
    pub short_label: String,
    /// 对方自报的名字,已经过滤。可能为空。
    pub display_name: String,
}

/// 请求加入的结果。
#[derive(Debug, Clone, uniffi::Enum)]
pub enum FfiJoinOutcome {
    /// 对方批准了,已经自动加入。
    Joined,
    /// 对方此刻没在共享。等一等再试。
    NotSharing,
    /// 对方拒绝了。再敲也没用。
    Declined,
    /// 对方一直没回应。
    TimedOut,
}

/// 观看端到主持人此刻实际走的链路。真值来自 QUIC 连接当前选中的传输
/// 路径——「直连被禁、只剩中继」是 AP 隔离网络的诊断特征。
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FfiShareLinkPath {
    Direct,
    Relayed,
}

impl From<vt_share::net::CaptionLinkPath> for FfiShareLinkPath {
    fn from(value: vt_share::net::CaptionLinkPath) -> Self {
        match value {
            vt_share::net::CaptionLinkPath::Direct => Self::Direct,
            vt_share::net::CaptionLinkPath::Relayed => Self::Relayed,
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
    /// 观看端到主持人的当前链路;没在观看或还没连上时为 `None`。
    pub viewer_link: Option<FfiShareLinkPath>,
    /// 已应用的字幕帧号;还没收到任何帧时为 `None`。
    pub applied_revision: Option<u64>,
    /// 本机作为主持人已经播出的最后一帧。`None` 表示**一帧都还没播** ——
    /// 通常是主持人还没开始录音,而不是网络有问题。这两种情况在界面上必须
    /// 说成不同的话,否则用户只会看到「什么都没有」。
    pub broadcast_revision: Option<u64>,
    /// 主持人已明确道别(仅观看端有意义)。界面据此显示「这场已结束,
    /// 收到的内容还在」,而不是永远停在「接收中」的最后一帧。
    pub host_left: bool,
    /// 当前房间按单次录音共享时,那一场的 session id。收件列表用它判定
    /// **哪一条**受房间写入策略约束 —— 只读约束只属于当前房间的那份文档,
    /// 不该殃及散场后留下的其它收件。Notebook 范围或未共享时为 `None`。
    pub scope_session_id: Option<String>,
    /// 这是一场正在录的直播(`false` = 一段录好的录音)。主持人一侧按开始
    /// 时的选择;观看端按主持人随帧带来的说明,旧版主持人没有说明时为 `false`。
    pub is_live: bool,
    /// 观看端的 ZuTalk 会留下这场的文字稿。主持人为直播打开、或共享的是一段
    /// 录好的录音时为真;关着时观看端只能边听边看,离开就没了。
    pub keeps_copies: bool,
    /// 主持人:同一网络的人能在附近列表里看到这场的名字与标题。
    pub discoverable: bool,
    /// 这场共享的录音标题;没起名时为空。
    pub title: String,
    /// 主持人自报的名字。观看端从主持人随帧带来的说明里读,不靠 gossip。
    pub host_name: String,
    /// 观看端:主持人把本机移出了这场共享。
    pub removed_by_host: bool,
    pub lines: Vec<FfiSharedCaptionLine>,
    /// 观看端:主播最新一帧的**完整**预览 —— 与主播本机画布收到的同一形态
    /// (多语言 lane、cue、lane 健康齐全)。旧版主播只发压扁行时为 `None`,
    /// 此时界面退化为 `lines` 列表。
    pub remote_preview: Option<FfiNotebookCaptureLivePreview>,
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
    /// 本机播出的最后一帧。用来区分「还没开始录音」和「播了但对方没收到」。
    last_broadcast_revision: Option<u64>,
    /// 本机的文档同步已经接上。主持人只在允许观看端留存时才接 —— 没接上
    /// 就不物化、不写 shared/ 下的副本,也不回答任何人的文档请求。
    doc_sync_enabled: bool,
    /// 已加入的 gossip 房间。在场与名册靠它 —— 没有它,房间里看不见彼此。
    room: Option<Arc<vt_share::net::RoomHandle>>,
    /// 网页分享(明文经服务器,见 share-web-captions.md)。它是「当前这场
    /// 共享」的属性:随停止共享一起收口,不能独立于房间存在。
    pub(crate) web_share: Option<Arc<crate::share_web::WebShareRuntime>>,
}

impl ShareRuntime {
    pub(crate) fn endpoint_handle(&self) -> Arc<ShareEndpoint> {
        self.endpoint.clone()
    }

    pub(crate) fn is_hosting(&self) -> bool {
        self.hosting.is_some()
    }

    pub(crate) fn roster_scope(&self) -> Option<ScopeId> {
        self.roster.as_ref().map(|roster| roster.scope().clone())
    }

    /// 文档同步已接上的主持人。shared/ 下的副本只为它写。
    pub(crate) fn serves_documents(&self) -> bool {
        self.hosting.is_some() && self.doc_sync_enabled
    }

    /// 这段录音此刻的字幕是否正在播给房间。
    pub(crate) fn broadcasts_session(&self, session_id: &str) -> bool {
        matches!(
            self.hosting.as_ref().map(|room| &room.code.scope),
            Some(ScopeId::Session { session_id: shared }) if shared == session_id
        )
    }
}

struct HostedRoom {
    code: ShareCode,
    /// 这一场主持人对房间说的话,随每一帧带出去。
    header: ShareHeader,
    /// 同一网络的人能在附近列表里看到名字与标题。
    discoverable: bool,
}

struct ViewedRoom {
    scope: ScopeId,
    code: ShareCode,
    host_only: bool,
    inbox: CaptionInbox,
    projection: CaptionReceiver,
    task: tokio::task::JoinHandle<()>,
    /// 主持人最近一次随帧说明的这场共享。旧版主持人没有。
    header: Option<ShareHeader>,
    /// 向主持人要文字稿的那条连接。主持人没允许留存时它会被当场关掉;
    /// 主持人中途允许了,要再拨一次。
    doc_sync: Option<tokio::task::JoinHandle<()>>,
    /// 上一次拨的时刻。断线重拨要隔一会儿,不在轮询节拍上连环拨号。
    last_dial: Option<std::time::Instant>,
}

impl Drop for ViewedRoom {
    fn drop(&mut self) {
        self.task.abort();
        if let Some(task) = self.doc_sync.take() {
            task.abort();
        }
    }
}

impl ZuTalkCore {
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
        {
            let endpoint = endpoint.clone();
            let name = self.share_display_name.lock().unwrap().clone();
            self.runtime
                .block_on(async move { endpoint.set_display_name(&name).await });
        }
        *guard = Some(ShareRuntime {
            endpoint: endpoint.clone(),
            hosting: None,
            viewing: None,
            roster: None,
            transport: wanted,
            last_broadcast_revision: None,
            doc_sync_enabled: false,
            room: None,
            web_share: None,
        });
        Ok(endpoint)
    }
}

#[uniffi::export]
impl ZuTalkCore {
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

    /// 当前正在主持的分享码。没有在主持时为 `None`。
    ///
    /// 分享码必须能从这里取回,不能只活在界面的内存里 —— 切走标签页再回来、
    /// 或者重开窗口,界面就再也拿不到它,而「正在共享」的状态还亮着,
    /// 复制按钮于是静默失效。
    pub fn current_share_code(&self) -> Option<String> {
        let guard = self.share_runtime.lock().unwrap();
        let runtime = guard.as_ref()?;
        Some(runtime.hosting.as_ref()?.code.to_string())
    }

    /// 收到的共享内容该落进哪个 Notebook,没有就建一个。
    pub fn shared_inbox_notebook(&self) -> Result<crate::notebook_api::FfiNotebook, CoreError> {
        let record = self
            .notebook_store
            .ensure_internal_notebook(
                SHARED_INBOX_NOTEBOOK_INTERNAL_TITLE,
                SHARED_INBOX_NOTEBOOK_TITLE,
            )
            .map_err(|error| CoreError::InternalError {
                message: format!("准备分享 Notebook 失败: {error}"),
            })?;
        Ok(crate::notebook_api::FfiNotebook {
            id: record.id,
            title: SHARED_INBOX_NOTEBOOK_TITLE.to_string(),
            created_at: record.created_at,
            updated_at: record.updated_at,
            deleted_at: record.deleted_at,
        })
    }

    /// 同一网络里愿意被找到的直播。
    ///
    /// 刚打开时列表可能还空着 —— mDNS 是异步宣告的 —— 这时最多阻塞 `seconds`
    /// 秒等第一批。之后是常驻表的快照,立即返回。
    pub fn nearby_peers(&self, seconds: u32) -> Result<Vec<FfiNearbyPeer>, CoreError> {
        let endpoint = self.ensure_share_endpoint()?;
        let window = std::time::Duration::from_secs(seconds.clamp(1, 10) as u64);
        let peers = self
            .runtime
            .block_on(async move { endpoint.nearby_peers(window).await });
        Ok(peers
            .into_iter()
            .map(|p| FfiNearbyPeer {
                endpoint_id: p.endpoint_id.to_string(),
                short_label: p.short_label,
                host_name: p.announcement.host_name,
                title: p.announcement.title,
            })
            .collect())
    }

    /// 向同一网络里的某台机器请求加入。批准后自动进房。
    pub fn request_to_join_nearby(&self, endpoint_id: String) -> Result<FfiJoinOutcome, CoreError> {
        let endpoint = self.ensure_share_endpoint()?;
        let answer = self
            .runtime
            .block_on(async move { endpoint.request_to_join(&endpoint_id).await })
            .map_err(|error| CoreError::InternalError {
                message: format!("请求加入失败: {error}"),
            })?;
        match answer {
            Ok(code) => {
                self.join_share(code)?;
                Ok(FfiJoinOutcome::Joined)
            }
            Err(vt_share::DenyReason::NotSharing) => Ok(FfiJoinOutcome::NotSharing),
            Err(vt_share::DenyReason::Declined) => Ok(FfiJoinOutcome::Declined),
            Err(vt_share::DenyReason::TimedOut) => Ok(FfiJoinOutcome::TimedOut),
        }
    }

    /// 等着你回答的加入请求。
    pub fn pending_join_requests(&self) -> Vec<FfiJoinRequest> {
        let guard = self.share_runtime.lock().unwrap();
        let Some(runtime) = guard.as_ref() else {
            return Vec::new();
        };
        let desk = runtime.endpoint.join_desk();
        drop(guard);
        self.runtime.block_on(async move {
            desk.pending()
                .await
                .into_iter()
                .map(|r| FfiJoinRequest {
                    request_id: r.request_id,
                    endpoint_id: r.endpoint_id.to_string(),
                    short_label: r.endpoint_id.fmt_short().to_string(),
                    display_name: r.display_name,
                })
                .collect()
        })
    }

    /// 批准一条加入请求,把分享码交给对方。
    pub fn approve_join_request(&self, request_id: String) -> Result<bool, CoreError> {
        let (desk, code) = {
            let guard = self.share_runtime.lock().unwrap();
            let Some(runtime) = guard.as_ref() else {
                return Ok(false);
            };
            let Some(hosting) = runtime.hosting.as_ref() else {
                return Ok(false);
            };
            (runtime.endpoint.join_desk(), hosting.code.to_string())
        };
        Ok(self
            .runtime
            .block_on(async move { desk.approve(&request_id, code).await }))
    }

    /// 拒绝一条加入请求。
    pub fn decline_join_request(&self, request_id: String) -> bool {
        let guard = self.share_runtime.lock().unwrap();
        let Some(runtime) = guard.as_ref() else {
            return false;
        };
        let desk = runtime.endpoint.join_desk();
        drop(guard);
        self.runtime
            .block_on(async move { desk.decline(&request_id).await })
    }

    /// 本机的昵称。房间里的人和「附近的人」列表都靠它认出你。
    ///
    /// 存在本机;每次绑定端点时重新交给传输层。空的话别人只看得到公钥。
    pub fn share_display_name(&self) -> String {
        self.share_display_name.lock().unwrap().clone()
    }

    pub fn set_share_display_name(&self, name: String) -> Result<(), CoreError> {
        let cleaned = vt_share::sanitize_display_name(&name);
        *self.share_display_name.lock().unwrap() = cleaned.clone();
        // 端点还没建时不必现在推 —— 建的时候会读这个值。
        if let Ok(mut guard) = self.share_runtime.lock() {
            if let Some(runtime) = guard.as_mut() {
                let endpoint = runtime.endpoint.clone();
                // 正在主持的这一场也改口:后面的帧与附近宣告都用新名字。
                if let Some(hosting) = runtime.hosting.as_mut() {
                    hosting.header.host_name = cleaned.clone();
                    if hosting.discoverable {
                        endpoint.set_nearby_announcement(Some(&NearbyAnnouncement::new(
                            &hosting.header.host_name,
                            &hosting.header.title,
                        )));
                    }
                }
                drop(guard);
                self.runtime
                    .block_on(async move { endpoint.set_display_name(&cleaned).await });
            }
        }
        Ok(())
    }

    /// 房间里都有谁。没在房间里时为空。
    pub fn room_members(&self) -> Vec<FfiRoomMember> {
        let (room, me, endpoint) = {
            let guard = self.share_runtime.lock().unwrap();
            let Some(runtime) = guard.as_ref() else {
                return Vec::new();
            };
            let Some(room) = runtime.room.clone() else {
                return Vec::new();
            };
            (
                room,
                runtime.endpoint.endpoint_id(),
                runtime.endpoint.clone(),
            )
        };
        let host = room.host();
        // 主持人这一侧:每个观看端字幕连接实际走的链路。观看端没人连它,
        // 表为空,所有成员的 link 自然是 None。
        let links: std::collections::BTreeMap<_, _> =
            endpoint.caption_watchers().into_iter().collect();
        self.runtime.block_on(async move {
            room.members_with_names()
                .await
                .into_iter()
                .map(|(id, display_name)| FfiRoomMember {
                    endpoint_id: id.to_string(),
                    short_label: id.fmt_short().to_string(),
                    display_name,
                    is_me: id == me,
                    is_host: id == host,
                    link: links.get(&id).copied().map(Into::into),
                })
                .collect()
        })
    }

    /// 本机分享身份。首次调用会生成并持久化。
    pub fn share_identity(&self) -> Result<FfiShareIdentity, CoreError> {
        let identity = self.load_or_create_share_identity()?;
        Ok(FfiShareIdentity {
            endpoint_id: identity.endpoint_id().to_string(),
            short_label: identity.short_label(),
        })
    }

    /// 把正在录的这一场直播给别人看,返回加入码。
    ///
    /// 观看的人只读。`keep_copies` 关着时主持人不接文档同步:观看端只收得到
    /// 实时字幕,他们的 ZuTalk 不会留下文字稿;打开后才把文字稿同步过去。
    pub fn start_live_share(
        &self,
        session_id: String,
        keep_copies: bool,
    ) -> Result<String, CoreError> {
        self.start_sharing(session_id, true, true, keep_copies)
    }

    /// 把一段录好的录音共享给别人:他们会得到一份文字稿副本。
    /// `host_only` 为真时对方只读,否则可以订正。
    pub fn start_recording_share(
        &self,
        session_id: String,
        host_only: bool,
    ) -> Result<String, CoreError> {
        self.start_sharing(session_id, false, host_only, true)
    }

    /// 直播中途允许观看端留下文字稿。**只能打开,不能收回** —— 已经同步过去
    /// 的内容在对方手里,关掉只会让界面说假话。
    pub fn allow_viewers_to_keep_copies(&self) -> Result<(), CoreError> {
        {
            let mut guard = self.share_runtime.lock().unwrap();
            let Some(hosting) = guard.as_mut().and_then(|runtime| runtime.hosting.as_mut()) else {
                return Err(CoreError::ValidationFailed {
                    message: "没有在共享".into(),
                });
            };
            if hosting.header.keeps_copies {
                return Ok(());
            }
            hosting.header.keeps_copies = true;
        }
        self.enable_document_sync()
    }

    /// 让同一网络的人在附近列表里看到这场的名字与标题,或者撤下。
    ///
    /// 关着时本机不出现在任何人的附近列表里,敲门也只会得到「没在共享」。
    pub fn set_share_discoverable(&self, discoverable: bool) -> Result<(), CoreError> {
        let (endpoint, announcement, code) = {
            let mut guard = self.share_runtime.lock().unwrap();
            let Some(runtime) = guard.as_mut() else {
                return Err(CoreError::ValidationFailed {
                    message: "没有在共享".into(),
                });
            };
            let Some(hosting) = runtime.hosting.as_mut() else {
                return Err(CoreError::ValidationFailed {
                    message: "没有在共享".into(),
                });
            };
            hosting.discoverable = discoverable;
            let announcement = discoverable
                .then(|| NearbyAnnouncement::new(&hosting.header.host_name, &hosting.header.title));
            (
                runtime.endpoint.clone(),
                announcement,
                discoverable.then(|| hosting.code.to_string()),
            )
        };
        endpoint.set_nearby_announcement(announcement.as_ref());
        // 请求台只在公开时交码。没公开的直播不接陌生人的敲门。
        self.runtime
            .block_on(async move { endpoint.set_hosted_share_code(code).await });
        Ok(())
    }

    /// 把一位观看者移出这场共享。他手里的码随之失效;别人不受影响。
    pub fn remove_share_member(&self, endpoint_id: String) -> Result<bool, CoreError> {
        let who: vt_share::EndpointId =
            endpoint_id
                .trim()
                .parse()
                .map_err(|_| CoreError::ValidationFailed {
                    message: format!("无法识别的设备: {endpoint_id}"),
                })?;
        let (endpoint, room) = {
            let guard = self.share_runtime.lock().unwrap();
            let Some(runtime) = guard.as_ref() else {
                return Ok(false);
            };
            if runtime.hosting.is_none() {
                return Ok(false);
            }
            let Some(room) = runtime.room.clone() else {
                return Ok(false);
            };
            (runtime.endpoint.clone(), room)
        };
        Ok(self
            .runtime
            .block_on(async move { endpoint.remove_member(&room, who).await }))
    }
}

impl ZuTalkCore {
    fn start_sharing(
        &self,
        session_id: String,
        live: bool,
        host_only: bool,
        keep_copies: bool,
    ) -> Result<String, CoreError> {
        if session_id.trim().is_empty() {
            return Err(CoreError::ValidationFailed {
                message: "要共享哪一段录音?".into(),
            });
        }
        let title = self
            .session_store
            .get_session(&session_id)
            .map(|record| record.title)
            .unwrap_or_default();
        let scope = ScopeId::Session { session_id };

        let endpoint = self.ensure_share_endpoint()?;

        // 一次一个房间。观看中开播、共享中再开播,都会把两套房间状态
        // 拧在一起(名册互相顶替、viewing 与 hosting 并存)—— 拒绝比
        // 造出说不清的混合状态诚实。
        {
            let guard = self.share_runtime.lock().unwrap();
            if let Some(runtime) = guard.as_ref() {
                if runtime.viewing.is_some() {
                    return Err(CoreError::ValidationFailed {
                        message: "正在看别人的共享;先离开,再从这台 Mac 共享".into(),
                    });
                }
                if runtime.hosting.is_some() {
                    return Err(CoreError::ValidationFailed {
                        message: "已经在共享;先停止当前这一场,再开始新的".into(),
                    });
                }
            }
        }

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

        // 真的进 gossip 房间 —— 在场与名册都靠它,不进就永远看不见彼此。
        let joined = {
            let endpoint = endpoint.clone();
            let code = code.clone();
            self.runtime
                .block_on(async move { endpoint.join_room(&code, vec![]).await })
                .map_err(|error| CoreError::InternalError {
                    message: format!("进入房间失败: {error}"),
                })?
        };

        let header = ShareHeader {
            title,
            host_name: self.share_display_name.lock().unwrap().clone(),
            live,
            keeps_copies: keep_copies,
        };
        {
            let mut guard = self.share_runtime.lock().unwrap();
            let runtime = guard.as_mut().expect("端点刚刚建立");
            runtime.roster = Some(vt_share::RoomRoster::new(
                code.scope.clone(),
                identity_id,
                code.policy,
            ));
            runtime.room = Some(Arc::new(joined));
            runtime.hosting = Some(HostedRoom {
                code: code.clone(),
                header: header.clone(),
                discoverable: false,
            });
        }
        // 先播一帧只有说明的空帧:录好的录音不会再有字幕帧,直播也可能正
        // 停在一句话的间隙 —— 进来的人要马上知道看的是谁的哪一场。
        let mut opening = vt_share::CaptionFrame::flat(code.scope.clone(), 0, Vec::new());
        if let ScopeId::Session { session_id } = &code.scope {
            opening.session_id = session_id.clone();
        }
        opening.share = Some(header);
        endpoint.broadcast_caption(opening);
        // 附近宣告默认静默,请求台也不交码 —— 公开是主持人另外点头的事。
        endpoint.set_nearby_announcement(None);

        if keep_copies {
            if let Err(error) = self.enable_document_sync() {
                let _ = self.stop_sharing();
                return Err(error);
            }
        }
        Ok(code.to_string())
    }
}

#[uniffi::export]
impl ZuTalkCore {
    /// 停止共享。
    ///
    /// **只停止继续发送。** 已经合并进对方文档的内容无法收回 —— 房间密钥轮换让老成员
    /// 拿不到后续、也进不来新房间,仅此而已。界面必须如实说明这一点。
    pub fn stop_sharing(&self) -> Result<(), CoreError> {
        self.shared_sessions.clear_room_state();
        let mut guard = self.share_runtime.lock().unwrap();
        if let Some(runtime) = guard.as_mut() {
            // 网页分享随房间一起收口:先关房(尽力而为,服务端有 TTL 兜底)。
            if let Some(web) = runtime.web_share.take() {
                web.close(&self.runtime);
            }
            if runtime.hosting.take().is_some() {
                // 附近列表里撤下,下一场的观看端也不会先看到这一场的最后一帧。
                runtime.endpoint.set_nearby_announcement(None);
                runtime.endpoint.end_broadcast();
            }
            // ViewedRoom 的 Drop 会中止接收任务。
            runtime.viewing = None;
            runtime.roster = None;
            // 文档同步随这一场结束;下一场按它自己的选择重新接。
            runtime.doc_sync_enabled = false;
            let endpoint = runtime.endpoint.clone();
            self.runtime
                .block_on(async move { endpoint.disable_document_sync().await });
            // 播出水位同理:不清零,下一场共享会在录音开始前就显示成
            // 「正在播出」—— hostingWaiting 与 hostingLive 的区分靠它。
            runtime.last_broadcast_revision = None;
            // 先道别再拆房间 —— 丢掉 RoomHandle 会中止事件循环,
            // 那之后就没人替你说这句话了,别人要等超时才知道你走了。
            if let Some(room) = runtime.room.take() {
                self.runtime
                    .block_on(async move { room.announce_departure().await });
            }
            let endpoint = runtime.endpoint.clone();
            self.runtime
                .block_on(async move { endpoint.set_hosted_share_code(None).await });
        }
        Ok(())
    }

    /// 用分享码加入别人的房间。
    pub fn join_share(&self, code: String) -> Result<(), CoreError> {
        let parsed = ShareCode::from_str(&code).map_err(|error| CoreError::ValidationFailed {
            message: format!("分享码无法解析: {error}"),
        })?;

        let endpoint = self.ensure_share_endpoint()?;

        // 主持中不能加入别人的房间(一次一个房间)。观看中换房间是允许的,
        // 但要先跟老房间道别 —— 静默消失让那边的人等到超时才知道你走了。
        {
            let mut guard = self.share_runtime.lock().unwrap();
            if let Some(runtime) = guard.as_mut() {
                if runtime.hosting.is_some() {
                    return Err(CoreError::ValidationFailed {
                        message: "正在主持共享;先停止,再加入别人的房间".into(),
                    });
                }
                if runtime.viewing.is_some() || runtime.room.is_some() {
                    self.shared_sessions.clear_room_state();
                    runtime.viewing = None;
                    runtime.roster = None;
                    if let Some(room) = runtime.room.take() {
                        self.runtime
                            .block_on(async move { room.announce_departure().await });
                    }
                }
            }
        }

        let inbox = CaptionInbox::default();
        let scope = parsed.scope.clone();

        let task = {
            let endpoint = endpoint.clone();
            let inbox = inbox.clone();
            let code = parsed.clone();
            self.runtime.spawn(async move {
                if let Err(error) = receive_captions(&endpoint, code, inbox).await {
                    tracing::warn!(%error, "字幕接收结束");
                }
            })
        };

        let joined = {
            let endpoint = endpoint.clone();
            let parsed = parsed.clone();
            self.runtime
                .block_on(async move { endpoint.join_room(&parsed, vec![]).await })
                .map_err(|error| CoreError::InternalError {
                    message: format!("进入房间失败: {error}"),
                })?
        };

        let mut guard = self.share_runtime.lock().unwrap();
        let runtime = guard.as_mut().expect("端点刚刚建立");
        runtime.room = Some(Arc::new(joined));
        runtime.roster = Some(vt_share::RoomRoster::new(
            parsed.scope.clone(),
            parsed.host.id,
            parsed.policy,
        ));
        runtime.viewing = Some(ViewedRoom {
            scope: scope.clone(),
            code: parsed.clone(),
            host_only: matches!(parsed.policy, WritePolicy::HostOnly),
            inbox,
            projection: CaptionReceiver::new(),
            task,
            header: None,
            doc_sync: None,
            last_dial: None,
        });
        drop(guard);

        // 收端落库从这里开始:按单次录音共享时那一篇预先入册,然后武装
        // 文档同步、拨一次。主持人没允许留存时这一拨会被当场关掉,本机什么
        // 也不落;主持人中途允许了,share_state 看到说明会再拨。
        // Notebook 范围(旧版主持人)在这里入不了册 —— 之后由 share_state
        // 在吸收字幕帧时按主播宣告逐个登记。
        if let ScopeId::Session { session_id } = &scope {
            self.shared_sessions.register_known(session_id);
        }
        if let Err(error) = self.enable_document_sync() {
            tracing::warn!(%error, "文档同步未能武装;字幕仍可用");
        }
        self.dial_document_sync();
        Ok(())
    }

    /// 打开文档协同。
    ///
    /// 必须在共享已经开始之后调用 —— 它要用当前房间的名册判定谁能写。之后本机的
    /// 每一笔编辑都会推给对端,对端推来的每一笔都要过完整条准入链才会合入。
    pub fn enable_document_sync(&self) -> Result<(), CoreError> {
        let (endpoint, roster, room, hosting) = {
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
            (
                runtime.endpoint.clone(),
                roster,
                runtime.room.clone(),
                runtime.hosting.is_some(),
            )
        };
        // 名册以房间在场为准:enable 之前已经进来的成员不能被落下。
        // 之后的进出由房间事件循环持续刷进 DocSyncContext。
        let roster = match room {
            Some(room) => self.runtime.block_on(async move { room.roster().await }),
            None => roster,
        };
        let scope = roster.scope().clone();

        // 宿主先物化范围内的共享文档:version / updates_since 只对打开的
        // 文档有答案,不物化的同步是一场空转。
        if hosting {
            self.materialize_shared_sessions(&scope)?;
        }

        let context = vt_share::DocSyncContext {
            scope,
            roster: Arc::new(tokio::sync::Mutex::new(roster)),
            guard: Arc::new(LoroCaptureBoundaryGuard::new(self.editor_bridge.clone())),
            sink: Arc::new(crate::shared_session_docs::SharedDocSync::new(
                self.shared_sessions.clone(),
                self.editor_bridge.clone(),
                self.notebook_capture_store.clone(),
                self.data_dir.clone(),
                hosting,
            )),
            // 只有主持人转发成员更新 —— 成员之间没有连接,A 的订正要经
            // 这一跳才到得了 B。
            hosting,
        };
        self.runtime
            .block_on(async move { endpoint.enable_document_sync(context).await });
        if let Some(runtime) = self.share_runtime.lock().unwrap().as_mut() {
            runtime.doc_sync_enabled = true;
        }
        Ok(())
    }

    /// 取当前分享状态与字幕投影。
    ///
    /// 每次调用会吸收自上次以来收到的所有帧;因为帧是 replace-in-full 的,只有最新
    /// 的那一帧会留下痕迹,中间被跳过的帧不需要补。
    pub fn share_state(&self) -> FfiShareState {
        let mut redial = false;
        let state = {
            let mut guard = self.share_runtime.lock().unwrap();
            let Some(runtime) = guard.as_mut() else {
                return FfiShareState::idle();
            };
            self.snapshot_share_state(runtime, &mut redial)
        };
        if redial {
            self.dial_document_sync();
        }
        if state.is_viewing && state.keeps_copies {
            if let Some(session_id) = state.scope_session_id.as_deref() {
                crate::shared_session_docs::remember_received_meta(
                    &self.shared_sessions,
                    &self.data_dir,
                    session_id,
                    &state.title,
                    &state.host_name,
                );
            }
        }
        state
    }

    /// 某段录音此刻是否正在播给别人看。录音条上的「直播中」据此亮起。
    pub fn is_session_shared_live(&self, session_id: String) -> bool {
        self.share_runtime
            .lock()
            .unwrap()
            .as_ref()
            .is_some_and(|runtime| runtime.broadcasts_session(&session_id))
    }
}

impl FfiShareState {
    fn idle() -> Self {
        FfiShareState {
            is_sharing: false,
            is_viewing: false,
            host_only: false,
            is_host: false,
            viewer_link: None,
            applied_revision: None,
            broadcast_revision: None,
            host_left: false,
            scope_session_id: None,
            is_live: false,
            keeps_copies: false,
            discoverable: false,
            title: String::new(),
            host_name: String::new(),
            removed_by_host: false,
            lines: Vec::new(),
            remote_preview: None,
        }
    }
}

impl ZuTalkCore {
    fn snapshot_share_state(&self, runtime: &mut ShareRuntime, redial: &mut bool) -> FfiShareState {
        let is_host = runtime.hosting.is_some();
        let host_only = match (&runtime.hosting, &runtime.viewing) {
            (Some(room), _) => matches!(room.code.policy, WritePolicy::HostOnly),
            (None, Some(room)) => room.host_only,
            _ => false,
        };

        let mut applied_revision = None;
        let mut lines = Vec::new();
        let mut remote_preview = None;
        let mut removed_by_host = false;
        if let Some(room) = runtime.viewing.as_mut() {
            let scope = room.scope.clone();
            for frame in self.runtime.block_on(room.inbox.drain()) {
                if let Some(header) = frame.share.clone() {
                    room.header = Some(header);
                }
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
            remote_preview = room.projection.latest_frame().and_then(remote_preview_from);
            removed_by_host = room.inbox.removed();

            // 主持人允许留存了,而要文字稿的那条连接已经被关掉(开始时没允许)
            // 或断了 —— 再拨一次。
            let wants_copies = room.header.as_ref().is_some_and(|h| h.keeps_copies);
            let dialing = room
                .doc_sync
                .as_ref()
                .is_some_and(|task| !task.is_finished());
            let cooled = room
                .last_dial
                .is_none_or(|at| at.elapsed() >= std::time::Duration::from_secs(3));
            if wants_copies && !dialing && cooled && !removed_by_host {
                *redial = true;
            }

            // Notebook 范围(旧版主持人)的收端落库入册:主播在字幕通道里宣告
            // 的 session id 可以入册 —— 字幕帧只来自与主播 QUIC 认证的直连,
            // 且已过范围检查,等价于**主播自报**,不是「成员自报」;bridge 键位
            // 占用防御照旧兜底(id 撞上本机文档时拒绝挂载)。
            if matches!(&scope, ScopeId::Notebook { .. }) {
                if let Some(preview) = remote_preview.as_ref() {
                    if !preview.session_id.is_empty() {
                        self.shared_sessions.register_known(&preview.session_id);
                    }
                }
            }
        }

        // 主持人是否已道别 —— 只对观看端有意义,主持人自己永远是 false。
        let host_left = if runtime.viewing.is_some() {
            match runtime.room.as_ref() {
                Some(room) => {
                    let room = room.clone();
                    self.runtime
                        .block_on(async move { room.host_departed().await })
                }
                None => false,
            }
        } else {
            false
        };

        let header = match (&runtime.hosting, &runtime.viewing) {
            (Some(room), _) => Some(room.header.clone()),
            (None, Some(room)) => room.header.clone(),
            _ => None,
        }
        .unwrap_or_default();
        FfiShareState {
            is_sharing: is_host || runtime.viewing.is_some(),
            is_viewing: runtime.viewing.is_some(),
            host_only,
            is_host,
            viewer_link: runtime
                .viewing
                .as_ref()
                .and_then(|room| room.inbox.link_path())
                .map(Into::into),
            applied_revision,
            broadcast_revision: runtime.last_broadcast_revision,
            host_left,
            scope_session_id: match runtime.roster_scope() {
                Some(ScopeId::Session { session_id }) => Some(session_id),
                _ => None,
            },
            is_live: header.live,
            keeps_copies: header.keeps_copies,
            discoverable: runtime
                .hosting
                .as_ref()
                .is_some_and(|room| room.discoverable),
            title: sanitize_label(&header.title),
            host_name: vt_share::sanitize_display_name(&header.host_name),
            removed_by_host,
            lines,
            remote_preview,
        }
    }

    /// 观看端:向主持人要文字稿。主持人没接文档同步时这一拨会被当场关掉,
    /// 本机什么也不落。
    fn dial_document_sync(&self) {
        let mut guard = self.share_runtime.lock().unwrap();
        let Some(runtime) = guard.as_mut() else {
            return;
        };
        let endpoint = runtime.endpoint.clone();
        let Some(room) = runtime.viewing.as_mut() else {
            return;
        };
        if let Some(task) = room.doc_sync.take() {
            task.abort();
        }
        let host = room.code.host.clone();
        room.last_dial = Some(std::time::Instant::now());
        room.doc_sync = Some(self.runtime.spawn(async move {
            if let Err(error) = endpoint.sync_document_with(host).await {
                tracing::debug!(%error, "文档同步未接上;主持人允许留存时会再拨");
            }
        }));
    }
}

/// 别人给的标题,显示前收拾一遍:去控制字符、压首尾空白、限长。
fn sanitize_label(raw: &str) -> String {
    let cleaned: String = raw.chars().filter(|c| !c.is_control()).collect();
    cleaned.trim().chars().take(120).collect()
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

    /// 把一帧本机预览广播给房间。非主持人、未共享、不是共享的那一场时都是 no-op。
    pub(crate) fn broadcast(&self, preview: &FfiNotebookCaptureLivePreview) {
        let Ok(guard) = self.runtime.lock() else {
            return;
        };
        let Some(runtime) = guard.as_ref() else {
            return;
        };
        // 只有主持人广播自己的字幕。观看者手里的是别人的内容,不该再转发出去。
        // 只播共享的那一场:同时在录的别的录音一帧也不出去。
        if !runtime.broadcasts_session(&preview.session_id) {
            return;
        }
        let Some(hosting) = runtime.hosting.as_ref() else {
            return;
        };

        // 同一帧、同一放行:网页通道在这之后分流,P2P 不发的帧网页也不发。
        let mut frame = caption_frame_from(hosting.code.scope.clone(), preview);
        frame.share = Some(hosting.header.clone());
        if let Some(web) = runtime.web_share.as_ref() {
            web.publish_frame(&frame);
        }
        runtime.endpoint.broadcast_caption(frame);
        drop(guard);
        if let Ok(mut guard) = self.runtime.lock() {
            if let Some(runtime) = guard.as_mut() {
                runtime.last_broadcast_revision = Some(preview.preview_revision);
            }
        }
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

    // 完整形态与压扁行同源同帧。接收端有完整形态就能还原主播本机画布的
    // 观感;旧接收端只认 `lines`,所以两份都发。
    let utterances = preview
        .utterances
        .iter()
        .map(|u| vt_share::CaptionUtterance {
            id: u.id.clone(),
            session_id: u.session_id.clone(),
            sequence: u.sequence,
            revision: u.revision,
            speaker: u.session_speaker_id.clone(),
            source_language: u.source_language.clone(),
            provisional_source_language: u.provisional_source_language.clone(),
            source_text: u.source_text.clone(),
            source_start_ms: u.source_start_ms,
            source_end_ms: u.source_end_ms,
            translated_language: u.translated_language.clone(),
            translated_text: u.translated_text.clone(),
            completion: u.completion.clone(),
            alignment: u.alignment.clone(),
        })
        .collect();

    // 帧是 replace-in-full 的:撤回的 cue 直接缺席即可,不需要墓碑。
    let cues = preview
        .translation_cues
        .iter()
        .filter(|c| !c.withdrawn)
        .map(|c| vt_share::CaptionCue {
            target_language: c.target_language.clone(),
            group_epoch: c.group_epoch,
            provider_sequence: c.provider_sequence,
            source_language: c.source_language.clone(),
            source_start_ms: c.source_start_ms,
            source_end_ms: c.source_end_ms,
            text: c.text.clone(),
            completion: c.completion.clone(),
            revision: c.revision,
        })
        .collect();

    let lane_health = preview
        .lane_health
        .iter()
        .map(|h| vt_share::CaptionLaneHealth {
            target_language: h.target_language.clone(),
            state: h.state.clone(),
            group_epoch: h.group_epoch,
        })
        .collect();

    vt_share::CaptionFrame {
        scope,
        preview_revision: preview.preview_revision,
        lines,
        session_id: preview.session_id.clone(),
        utterances,
        cues,
        lane_health,
        share: None,
    }
}

/// 把线上帧的完整形态还原成采集层的预览类型。
///
/// 主机本地的投影水位在对端没有意义,一律置零;`language_variants` 在实时
/// 预览帧上本就恒空(durable 变体是落库事实,不在预览里合成)。
/// 旧版主播的帧没有完整形态 —— 返回 `None`,界面退化为压扁行列表。
fn remote_preview_from(frame: &vt_share::CaptionFrame) -> Option<FfiNotebookCaptureLivePreview> {
    if frame.session_id.is_empty() && frame.utterances.is_empty() && frame.cues.is_empty() {
        return None;
    }
    Some(FfiNotebookCaptureLivePreview {
        session_id: frame.session_id.clone(),
        preview_revision: frame.preview_revision,
        utterances: frame
            .utterances
            .iter()
            .map(
                |u| crate::notebook_capture_api::FfiNotebookCaptureUtterance {
                    id: u.id.clone(),
                    session_id: u.session_id.clone(),
                    sequence: u.sequence,
                    revision: u.revision,
                    session_speaker_id: u.speaker.clone(),
                    source_language: u.source_language.clone(),
                    provisional_source_language: u.provisional_source_language.clone(),
                    source_text: u.source_text.clone(),
                    source_start_ms: u.source_start_ms,
                    source_end_ms: u.source_end_ms,
                    translated_language: u.translated_language.clone(),
                    translated_text: u.translated_text.clone(),
                    completion: u.completion.clone(),
                    alignment: u.alignment.clone(),
                    source_projection_revision: 0,
                    source_edit_revision: 0,
                    language_variants: Vec::new(),
                },
            )
            .collect(),
        translation_cues: frame
            .cues
            .iter()
            .map(
                |c| crate::notebook_capture_api::FfiNotebookCaptureTranslationCue {
                    target_language: c.target_language.clone(),
                    group_epoch: c.group_epoch,
                    provider_sequence: c.provider_sequence,
                    source_language: c.source_language.clone(),
                    source_start_ms: c.source_start_ms,
                    source_end_ms: c.source_end_ms,
                    text: c.text.clone(),
                    completion: c.completion.clone(),
                    withdrawn: false,
                    revision: c.revision,
                },
            )
            .collect(),
        lane_health: frame
            .lane_health
            .iter()
            .map(
                |h| crate::notebook_capture_api::FfiNotebookCaptureLaneHealth {
                    target_language: h.target_language.clone(),
                    state: h.state.clone(),
                    group_epoch: h.group_epoch,
                    final_audio_proc_ms: None,
                    total_audio_proc_ms: None,
                    lag_ms: None,
                    input_discontinuous: false,
                },
            )
            .collect(),
    })
}

impl ZuTalkCore {
    /// 测试专用:以主播身份把一帧预览按**真实 tap 路径**广播出去。
    ///
    /// 集成测试没有真采集回调可挂,但范围过滤、完整帧翻译这些判定必须走
    /// 生产代码,不能在测试里手搭旁路。
    #[doc(hidden)]
    pub fn broadcast_live_preview_for_test(&self, preview: &FfiNotebookCaptureLivePreview) {
        ShareCaptionTap::new(self.share_runtime.clone()).broadcast(preview);
    }
}

/// 供 `ZuTalkCore` 持有的运行时槽位。
pub(crate) type ShareRuntimeSlot = Mutex<Option<ShareRuntime>>;

/// 测试共用的预览帧样本。share_web 的测试也要同一份 —— 帧的形状只声明一次。
#[cfg(test)]
pub(crate) mod test_support {
    use super::FfiNotebookCaptureLivePreview;

    pub(crate) fn preview(session_id: &str, revision: u64) -> FfiNotebookCaptureLivePreview {
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
            lane_health: vec![crate::notebook_capture_api::FfiNotebookCaptureLaneHealth {
                target_language: Some("ko".into()),
                state: "connecting".into(),
                group_epoch: 1,
                final_audio_proc_ms: Some(1200),
                total_audio_proc_ms: Some(1500),
                lag_ms: Some(300),
                input_discontinuous: false,
            }],
        }
    }
}

#[cfg(test)]
mod tests {
    use super::test_support::preview;
    use super::*;
    use vt_crypto::MemoryKeyStore;

    /// tap 的**帧级**放行:只有共享的那一场播得出去,不只是状态查询说不播。
    ///
    /// 录音条上的「直播中」看 `is_session_shared_live`;这里锁广播那一半 ——
    /// 两半漂移开,就是「指示器灭着,字幕还在往外走」这种最坏的组合。
    /// 以 `last_broadcast_revision`(只在真正送出时推进)为观察点。
    #[test]
    fn only_the_shared_recording_is_broadcast() {
        let dir = tempfile::tempdir().unwrap();
        let core = ZuTalkCore::new_for_test(dir.path().to_string_lossy().to_string()).unwrap();
        core.start_live_share("sess-a".into(), false).unwrap();
        let tap = ShareCaptionTap::new(core.share_runtime.clone());

        // 同时在录的另一场:一帧都不许出去。
        tap.broadcast(&preview("sess-b", 1));
        assert_eq!(core.share_state().broadcast_revision, None);
        assert!(!core.is_session_shared_live("sess-b".into()));

        tap.broadcast(&preview("sess-a", 3));
        assert_eq!(core.share_state().broadcast_revision, Some(3));
        assert!(core.is_session_shared_live("sess-a".into()));

        core.stop_sharing().unwrap();

        // 停止后 tap 变 no-op,指示器也灭。
        tap.broadcast(&preview("sess-a", 4));
        assert_eq!(core.share_state().broadcast_revision, None);
        assert!(!core.is_session_shared_live("sess-a".into()));
    }

    /// 直播默认不让观看端留文字稿:主持人不接文档同步,也不在 shared/ 下写
    /// 任何东西。打开之后才接,而且关不回去。
    #[test]
    fn a_live_share_keeps_nothing_until_the_host_allows_it() {
        let dir = tempfile::tempdir().unwrap();
        let core = ZuTalkCore::new_for_test(dir.path().to_string_lossy().to_string()).unwrap();
        core.start_live_share("sess-live".into(), false).unwrap();

        let state = core.share_state();
        assert!(state.is_live && !state.keeps_copies && state.host_only);
        core.refresh_shared_session_document("sess-live");
        assert!(
            !crate::shared_session_docs::shared_documents_dir(&core.data_dir)
                .join("sess-live.loro")
                .exists(),
            "不允许留存时,主持人不该为这一场写同步副本"
        );

        core.allow_viewers_to_keep_copies().unwrap();
        assert!(core.share_state().keeps_copies);
        assert!(core
            .share_runtime
            .lock()
            .unwrap()
            .as_ref()
            .unwrap()
            .serves_documents());

        core.stop_sharing().unwrap();
        assert!(!core.share_state().keeps_copies);
    }

    /// 附近宣告只在主持人点头时带上名字与标题;请求台也只在那时交码。
    #[test]
    fn nearby_visibility_is_the_hosts_choice() {
        let dir = tempfile::tempdir().unwrap();
        let core = ZuTalkCore::new_for_test(dir.path().to_string_lossy().to_string()).unwrap();
        assert!(
            core.set_share_discoverable(true).is_err(),
            "没在共享时无从公开"
        );

        core.start_live_share("sess-near".into(), false).unwrap();
        assert!(!core.share_state().discoverable, "默认不公开");
        core.set_share_discoverable(true).unwrap();
        assert!(core.share_state().discoverable);
        core.set_share_discoverable(false).unwrap();
        assert!(!core.share_state().discoverable);
        core.stop_sharing().unwrap();
    }

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
    /// 远端改动的三种形态:订正机器块车道(放行)、插批注(放行)、
    /// 篡改机器块归属字段(拒)。
    enum RemoteEdit {
        LaneCorrection,
        Annotation,
        OwnerTamper,
    }

    /// 建一份 T2 转录稿开进 bridge,远端分叉出一份真实可合入的更新。
    fn remote_edit(session_id: &str, edit: RemoteEdit) -> (vt_store::EditorBridge, Vec<u8>) {
        use loro::LoroDoc;
        use vt_store::document_schema::{new_block_document, DocumentKind};
        use vt_store::transcript_projection::TranscriptProjection;
        use vt_store::EditorBridge;

        let projection =
            TranscriptProjection::open(new_block_document(DocumentKind::Transcript)).unwrap();
        projection
            .machine_upsert_block(
                vt_store::transcript_projection::MachineBlockWrite {
                    id: "u1".into(),
                    owner: format!("capture:{session_id}"),
                    text: "机器句".into(),
                    lanes: Default::default(),
                },
                &Default::default(),
                None,
            )
            .unwrap();
        let editor = EditorBridge::new();
        editor.open(session_id, projection.doc().clone()).unwrap();

        let remote = LoroDoc::new();
        remote
            .import(&editor.export_snapshot(session_id).unwrap())
            .unwrap();
        let before = remote.oplog_vv();
        let remote_projection = TranscriptProjection::open(remote).unwrap();
        match edit {
            RemoteEdit::LaneCorrection => remote_projection
                .user_replace_text("u1", "远端订正机器句")
                .unwrap(),
            RemoteEdit::Annotation => remote_projection
                .insert_annotation(1, "n1", "远端批注")
                .unwrap(),
            RemoteEdit::OwnerTamper => {
                let block = remote_projection
                    .doc()
                    .get_list("utterances")
                    .get(0)
                    .and_then(|value| value.into_container().ok())
                    .and_then(|container| container.into_map().ok())
                    .expect("首块是 map");
                block.insert("owner", "user").unwrap();
                remote_projection.doc().commit();
            }
        }
        let update = remote_projection
            .doc()
            .export(loro::ExportMode::updates(&before))
            .unwrap();
        (editor, update)
    }

    fn run_chain(
        session_id: &str,
        document_id: &str,
        update: Vec<u8>,
        editor: vt_store::EditorBridge,
    ) -> vt_share::IncomingOutcome {
        run_chain_as(session_id, document_id, update, editor, false)
    }

    /// `author_is_host`:宿主按「宿主即机器」豁免编辑边界,成员逐条过。
    fn run_chain_as(
        session_id: &str,
        document_id: &str,
        update: Vec<u8>,
        editor: vt_store::EditorBridge,
        author_is_host: bool,
    ) -> vt_share::IncomingOutcome {
        use vt_share::{handle_incoming_update, seal_update, RoomRoster, WritePolicy};

        let scope = ScopeId::Session {
            session_id: session_id.into(),
        };
        let host = iroh::SecretKey::generate();
        let member = iroh::SecretKey::generate();
        let mut roster = RoomRoster::new(scope.clone(), host.public(), WritePolicy::Everyone);
        roster.admit(member.public());
        let author = if author_is_host { &host } else { &member };
        // 信封纪元照本地文档实际声明的来;查不出(文档不在范围)时按
        // 当前纪元封,让 scope 检查自己出面拒绝。
        let epoch = editor
            .schema_epoch(session_id)
            .unwrap_or(vt_store::editor_bridge::CURRENT_SCHEMA_EPOCH);
        let envelope = seal_update(&scope, document_id, epoch, update, author).unwrap();

        // NotebookCaptureStore 只在 Notebook 范围下才被问到,Session 范围用不着它。
        let store = Arc::new(
            vt_store::notebook_capture_store::NotebookCaptureStore::new(&std::path::PathBuf::from(
                ":memory:",
            ))
            .unwrap(),
        );
        let temp = tempfile::tempdir().unwrap();
        handle_incoming_update(
            &envelope,
            &roster,
            &LoroCaptureBoundaryGuard::new(editor.clone()),
            &crate::shared_session_docs::SharedDocSync::new(
                std::sync::Arc::new(crate::shared_session_docs::SharedSessionState::default()),
                editor,
                store,
                temp.path().to_path_buf(),
                true,
            ),
        )
    }

    #[test]
    fn admission_chain_refuses_identity_tamper_but_admits_lane_correction() {
        // 成员篡改机器块归属字段:拒。
        let (editor, update) = remote_edit("session-1", RemoteEdit::OwnerTamper);
        assert_eq!(
            run_chain("session-1", "session-1", update, editor),
            vt_share::IncomingOutcome::Denied(vt_share::AdmissionDenial::TouchesCaptureOwnedRange)
        );

        // 成员订正机器块的车道内容:协作订正的人类层,放行。
        let (editor, update) = remote_edit("session-1b", RemoteEdit::LaneCorrection);
        assert_eq!(
            run_chain("session-1b", "session-1b", update, editor),
            vt_share::IncomingOutcome::Applied
        );
    }

    /// 批注块的同一条链路必须放行,否则这道门就是「拒绝一切」。
    #[test]
    fn admission_chain_accepts_a_remote_annotation() {
        let (editor, update) = remote_edit("session-2", RemoteEdit::Annotation);
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
        let (editor, update) = remote_edit("session-3", RemoteEdit::Annotation);
        assert_eq!(
            run_chain("session-3", "somebody-elses-doc", update, editor),
            vt_share::IncomingOutcome::Denied(vt_share::AdmissionDenial::DocumentNotInScope)
        );
    }

    /// 第 1 纪元(或纪元不明)的文档在守卫退役后一律拒收:失败关闭是
    /// fork+重放守卫唯一正确的替身。
    #[test]
    fn admission_chain_fails_closed_for_a_non_epoch2_document() {
        use loro::LoroDoc;
        use vt_store::EditorBridge;

        let doc = LoroDoc::new();
        doc.get_text("content").insert(0, "旧平文本").unwrap();
        doc.commit();
        let editor = EditorBridge::new();
        editor.open("session-4", doc).unwrap();

        let remote = LoroDoc::new();
        remote
            .import(&editor.export_snapshot("session-4").unwrap())
            .unwrap();
        let before = remote.oplog_vv();
        remote.get_text("content").insert(0, "远端编辑 ").unwrap();
        remote.commit();
        let update = remote.export(loro::ExportMode::updates(&before)).unwrap();

        assert_eq!(
            run_chain("session-4", "session-4", update, editor),
            vt_share::IncomingOutcome::Denied(vt_share::AdmissionDenial::TouchesCaptureOwnedRange)
        );
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

    /// 完整形态过网往返:接收端还原出的预览与主播本机画布收到的同一形态。
    /// 这是「收端画布 = 主播画布」的根 —— 压扁行列表曾把 lane/cue/健康全丢掉。
    #[test]
    fn full_preview_round_trips_across_the_wire_shape() {
        let scope = ScopeId::Session {
            session_id: "s".into(),
        };
        let frame = caption_frame_from(scope, &preview("s", 9));

        assert_eq!(frame.session_id, "s");
        assert_eq!(frame.utterances.len(), 1);
        assert_eq!(frame.cues.len(), 1, "撤回的 cue 在完整形态里同样缺席");
        assert_eq!(frame.lane_health.len(), 1);
        assert_eq!(frame.lane_health[0].state, "connecting");

        let back = remote_preview_from(&frame).expect("完整形态可还原");
        assert_eq!(back.session_id, "s");
        assert_eq!(back.preview_revision, 9);
        assert_eq!(back.utterances[0].source_text, "こんにちは");
        assert_eq!(
            back.utterances[0].provisional_source_language.as_deref(),
            Some("ja"),
            "临时车道标签必须过网,否则对端把 und 放不进车道"
        );
        assert_eq!(back.utterances[0].source_start_ms, Some(0));
        assert_eq!(back.translation_cues.len(), 1);
        assert_eq!(back.translation_cues[0].target_language, "ko");
        assert!(!back.translation_cues[0].withdrawn);
        assert_eq!(back.lane_health[0].target_language.as_deref(), Some("ko"));
        assert_eq!(back.lane_health[0].state, "connecting");
        // 主机本地的诊断细节不过网,还原侧一律置空。
        assert_eq!(back.lane_health[0].lag_ms, None);
    }

    /// 旧版主播只发压扁行 —— 还原不出完整预览,界面必须退化而不是崩。
    #[test]
    fn a_legacy_flat_frame_yields_no_remote_preview() {
        let frame = vt_share::CaptionFrame::flat(
            ScopeId::Session {
                session_id: "s".into(),
            },
            1,
            vec![],
        );
        assert!(remote_preview_from(&frame).is_none());
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
        assert!(
            t.enable_local_discovery,
            "局域网发现默认打开:它驱动「同一网络里的人」"
        );
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
