//! iroh 传输层:Endpoint、Router、字幕广播与接收。
//!
//! 见 `docs/architecture/share-p2p.md` 第 2、3 节。

use std::sync::Arc;

use iroh::endpoint::{presets, Connection};
use iroh::protocol::{AcceptError, ProtocolHandler, Router};
use iroh::{Endpoint, EndpointAddr, RelayMode, RelayUrl};
use tokio::sync::{broadcast, Mutex};

use crate::caption::CaptionFrame;
use crate::docsync::{
    declare_versions, handle_incoming_update, respond_to_have, seal_update, DocSyncMessage,
    DocumentSync, IncomingOutcome,
};
use crate::identity::ShareIdentity;
use crate::nearby::{
    sanitize_display_name, DenyReason, NearbyAnnouncement, NearbyMessage, NearbyPeer,
    PendingJoinRequest, NEARBY_ALPN, NEARBY_SILENT,
};
use crate::permission::CaptureBoundaryGuard;
use crate::permission::RoomRoster;
use crate::room::ScopeId;
use crate::room_control::{open as open_control, seal as seal_control, RoomControl, RoomPresence};
use crate::sharecode::ShareCode;
use crate::wire::{read_message, write_message};

/// 实时字幕通道。每帧一条 uni-stream。
pub const LIVE_CAPTION_ALPN: &[u8] = b"zutalk/live-caption/1";
/// 文档协同通道。成对直连,承载签名信封。
pub const DOC_SYNC_ALPN: &[u8] = b"zutalk/doc-sync/1";

/// 文档同步的接线:一次把三个端口交齐。
///
/// 三者缺一不可 —— 没有 roster 判不了权限,没有 guard 判不了编辑边界,没有 sink
/// 合入不了。合成一个类型是为了让「少接一个就能跑」变成不可能。
pub struct DocSyncContext {
    pub scope: ScopeId,
    pub roster: Arc<Mutex<crate::permission::RoomRoster>>,
    pub guard: Arc<dyn CaptureBoundaryGuard + Send + Sync>,
    pub sink: Arc<dyn DocumentSync>,
    /// 本机是这个范围的主持人。**只有主持人转发成员的更新** —— 文档更新走
    /// 成对直连流(成员↔主持人),成员之间没有连接;A 的订正只有经主持人
    /// 转发才到得了 B。观看端不转发,所以回声(自己的更新被转回来)在
    /// 观看端就地止步,不会成环。
    pub hosting: bool,
}

impl std::fmt::Debug for DocSyncContext {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("DocSyncContext")
            .field("scope", &self.scope)
            .finish_non_exhaustive()
    }
}

impl Clone for DocSyncContext {
    fn clone(&self) -> Self {
        Self {
            scope: self.scope.clone(),
            roster: self.roster.clone(),
            guard: self.guard.clone(),
            sink: self.sink.clone(),
            hosting: self.hosting,
        }
    }
}

/// 广播端为每个接收者保留的待发帧数。
///
/// 满了就丢最旧的,**不背压** —— 一个慢接收者不能拖住采集回调。帧是
/// replace-in-full 的,丢旧帧无害(见 `caption` 模块)。
const CAPTION_FANOUT_DEPTH: usize = 4;

#[derive(Debug, thiserror::Error)]
pub enum NetError {
    #[error("绑定 endpoint 失败: {0}")]
    Bind(String),
    #[error("连接失败: {0}")]
    Connect(String),
    #[error("流读写失败: {0}")]
    Stream(String),
    #[error("主持人把本机移出了这场共享")]
    Removed,
}

/// 拨进来的人不在名册里。对方重试即可 —— 可能只是 Hello 还没到。
const CLOSE_NOT_A_MEMBER: u32 = 401;
/// 主持人移出了这台设备。对方不该再重连。
const CLOSE_REMOVED: u32 = 403;

/// 刚加入的人常常先拨字幕、Hello 后到。等这么久再下结论,免得第一次
/// 连接总被拒、要等重连才看得见字幕。
const ADMISSION_WAIT: std::time::Duration = std::time::Duration::from_secs(10);

/// 当前房间的放行依据:谁是主持人、本机是谁、名册在哪、凭什么核对入场凭证。
#[derive(Debug, Clone)]
struct RoomAccess {
    generation: u64,
    host: iroh::EndpointId,
    me: iroh::EndpointId,
    scope: ScopeId,
    room_secret: crate::room::RoomSecret,
    presence: Arc<Mutex<RoomPresence>>,
    /// 凭证收人之后要广播新名册,和事件循环用同一个发送端。
    sender: Arc<Mutex<Option<iroh_gossip::api::GossipSender>>>,
    identity: iroh::SecretKey,
}

type RoomAccessSlot = Arc<std::sync::Mutex<Option<RoomAccess>>>;

static ROOM_GENERATION: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);

/// 观看端连上字幕通道后交的第一条消息:我有这份码,我叫什么。
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
struct CaptionHello {
    ticket: [u8; 32],
    display_name: String,
}

enum Admission {
    Member,
    Removed,
    Stranger,
}

/// 名册里有没有这个人。
async fn roster_says(access: &RoomAccess, remote: iroh::EndpointId) -> Option<Admission> {
    let presence = access.presence.lock().await;
    if presence.is_banned(remote) {
        Some(Admission::Removed)
    } else if presence.roster().is_member(remote) {
        Some(Admission::Member)
    } else {
        None
    }
}

/// 凭证收人:进名册、把名册同步给文档准入门、广播给房间。
async fn admit_by_ticket(
    access: &RoomAccess,
    doc_context: &Mutex<Option<DocSyncContext>>,
    who: iroh::EndpointId,
    display_name: &str,
) {
    let (changed, roster, broadcast) = {
        let mut presence = access.presence.lock().await;
        let changed = presence.admit_with_ticket(who, display_name);
        (
            changed,
            presence.roster().clone(),
            presence.roster_broadcast(),
        )
    };
    if !changed {
        return;
    }
    if let Some(context) = doc_context.lock().await.as_ref() {
        if context.scope == access.scope {
            *context.roster.lock().await = roster;
        }
    }
    let sender = access.sender.lock().await.as_ref().cloned();
    if let (Some(roster), Some(sender)) = (broadcast, sender) {
        if let Ok(bytes) = seal_control(&roster, &access.scope, &access.identity) {
            let _ = sender.broadcast(bytes.into()).await;
        }
    }
}

/// 拨进字幕或文档通道的人,按当前房间该怎么对待。
///
/// 这两条通道不看分享码,只看连接的公钥 —— 而公钥是公开的(局域网 mDNS
/// 一直在广播它)。不按名册放行,任何人不必拿码、不必被批准就能直接拨
/// 字幕通道收看,分享码与批准都形同虚设。
///
/// 进名册有两条路:gossip 上的 Hello(旧版本观看端只有这条),或者字幕
/// 通道上当场交的入场凭证(`accepts_ticket`)。凭证是主路 —— Hello 有时
/// 十几秒才到,有时根本不到,不能让观看的人对着空白等。
async fn admit(
    slot: &RoomAccessSlot,
    doc_context: &Mutex<Option<DocSyncContext>>,
    connection: &Connection,
    accepts_ticket: bool,
) -> Admission {
    let remote = connection.remote_id();
    let access = slot.lock().unwrap().clone();
    let Some(access) = access else {
        return Admission::Stranger;
    };
    if access.host != access.me {
        // 观看端:成员之间没有连接,会拨过来的只有主持人。
        return if remote == access.host {
            Admission::Member
        } else {
            Admission::Stranger
        };
    }
    if let Some(known) = roster_says(&access, remote).await {
        return known;
    }

    let from_roster = async {
        loop {
            if let Some(known) = roster_says(&access, remote).await {
                return known;
            }
            tokio::time::sleep(std::time::Duration::from_millis(100)).await;
        }
    };
    let from_ticket = async {
        if !accepts_ticket {
            return std::future::pending::<Admission>().await;
        }
        let hello = async {
            let mut stream = connection.accept_uni().await.ok()?;
            read_message::<_, CaptionHello>(&mut stream).await.ok()
        };
        let Some(hello) = hello.await else {
            // 旧版本观看端不交凭证:只能等 Hello。
            return std::future::pending::<Admission>().await;
        };
        if hello.ticket != access.room_secret.admission_ticket(&access.scope, &remote) {
            return Admission::Stranger;
        }
        if let Some(Admission::Removed) = roster_says(&access, remote).await {
            return Admission::Removed;
        }
        admit_by_ticket(&access, doc_context, remote, &hello.display_name).await;
        Admission::Member
    };
    let decided = tokio::time::timeout(ADMISSION_WAIT, async {
        tokio::select! {
            outcome = from_roster => outcome,
            outcome = from_ticket => outcome,
        }
    })
    .await;
    decided.unwrap_or(Admission::Stranger)
}

/// 按放行结果收口。返回 `true` 表示可以继续服务这条连接。
async fn admit_or_close(
    slot: &RoomAccessSlot,
    doc_context: &Mutex<Option<DocSyncContext>>,
    connection: &Connection,
    accepts_ticket: bool,
) -> bool {
    match admit(slot, doc_context, connection, accepts_ticket).await {
        Admission::Member => true,
        Admission::Removed => {
            connection.close(CLOSE_REMOVED.into(), b"removed by host");
            false
        }
        Admission::Stranger => {
            connection.close(CLOSE_NOT_A_MEMBER.into(), b"not a member");
            false
        }
    }
}

fn closed_as_removed(conn: &Connection) -> bool {
    matches!(
        conn.close_reason(),
        Some(iroh::endpoint::ConnectionError::ApplicationClosed(close))
            if close.error_code == CLOSE_REMOVED.into()
    )
}

/// 把设置里那几行字符串解析成中继地址。
///
/// 放在这一层是为了让上层不必直接依赖 iroh —— 上层只管字符串,解析规则归传输层。
/// 空行会被忽略:用户在设置里删到只剩一个空行,意思是「不要中继」,不是错误。
pub fn parse_relay_urls(raw: &[String]) -> Result<Vec<RelayUrl>, String> {
    let mut parsed = Vec::new();
    for line in raw {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        parsed.push(
            trimmed
                .parse()
                .map_err(|_| format!("中继地址无法解析: {trimmed}"))?,
        );
    }
    Ok(parsed)
}

/// 端点配置。
#[derive(Debug, Clone, Default)]
pub struct ShareEndpointConfig {
    /// 自建中继。为空表示只走直连(局域网 / 已知直连地址)。
    ///
    /// **不使用 `presets::N0`**:那会把本机地址发布到 n0 的公共 pkarr / DNS。
    pub relay_urls: Vec<RelayUrl>,
    /// 是否启用局域网 mDNS 发现。macOS 15+ 首次会弹系统授权,拒绝后仍可用分享码。
    pub enable_local_discovery: bool,
}

/// 本机分享端点。
#[derive(Debug)]
pub struct ShareEndpoint {
    router: Router,
    endpoint: Endpoint,
    /// 分享码里带来的地址存在这里。
    ///
    /// 没有它,`gossip.subscribe(topic, vec![host_id])` 只拿到一个公钥却无处可拨 ——
    /// 本机既不查公共发现服务,离线时也没有中继可问。分享码内嵌直连地址正是为了
    /// 补上这一步,所以加入房间前必须先把它喂进地址簿。
    known_addrs: iroh::address_lookup::MemoryLookup,
    gossip: iroh_gossip::net::Gossip,
    identity: ShareIdentity,
    captions: broadcast::Sender<Arc<CaptionFrame>>,
    /// 最近播出的一帧。晚进来的观看端先收到它 —— 不然在说话的间隙加入,
    /// 要对着空白等到下一句话才知道自己连上了、在看的是哪一场。
    last_caption: Arc<std::sync::Mutex<Option<Arc<CaptionFrame>>>>,
    /// 本机产生的文档更新,广播给所有已连接的对端。
    doc_updates: broadcast::Sender<Arc<(String, Vec<u8>)>>,
    doc_context: Arc<Mutex<Option<DocSyncContext>>>,
    /// 等待批准的加入请求。
    join_desk: Arc<JoinRequestDesk>,
    /// 主持中的分享码,批准时交出。
    hosted_code: Arc<Mutex<Option<String>>>,
    /// 本机自报的名字,交给请求台在拒绝/批准时用。为空表示只显示公钥。
    display_name: Arc<Mutex<String>>,
    /// 局域网发现服务。`None` 表示设置里没开。
    mdns: Option<iroh_mdns_address_lookup::MdnsAddressLookup>,
    /// 局域网上看到的 ZuTalk 与它们最近一次的宣告。常驻订阅维护 ——
    /// mDNS 只在对方**变了**时报一次,每次扫描现订阅只能看到上次之后的
    /// 变化,第二次扫描起列表就是空的。
    nearby_table:
        Arc<std::sync::Mutex<std::collections::BTreeMap<iroh::EndpointId, Option<String>>>>,
    _nearby_task: Option<AbortOnDrop>,
    /// 此刻连着字幕通道的观看端连接。主持人的链路诊断从这里读 ——
    /// AP 隔离(两机清单第一/二条)要靠主持人也看得见「谁在走中继」才判得出。
    caption_watchers: Arc<std::sync::Mutex<Vec<Connection>>>,
    /// 此刻连着文档通道的对端。移出成员时要当场断开他们。
    doc_connections: Arc<std::sync::Mutex<Vec<Connection>>>,
    /// 当前房间的放行依据。见 [`admit`]。
    room_access: RoomAccessSlot,
    /// 主持人转发面:成员推来、验签合入成功的**原始信封**,原样发给
    /// 所有文档连接。保留原作者签名 —— 接收端照常按名册验 A,不是
    /// 主持人替 A 背书。观看端从不往里写。
    doc_envelopes: broadcast::Sender<Arc<Vec<u8>>>,
}

impl ShareEndpoint {
    /// 绑定端点并启动 accept 循环。
    pub async fn bind(
        identity: &ShareIdentity,
        config: ShareEndpointConfig,
    ) -> Result<Self, NetError> {
        let (captions, _) = broadcast::channel(CAPTION_FANOUT_DEPTH);
        // 文档更新不能丢,所以队列开得比字幕深得多:字幕丢旧帧无害,少一份 CRDT
        // 更新却会让两端永远不收敛。
        let (doc_updates, _) = broadcast::channel::<Arc<(String, Vec<u8>)>>(256);
        // 主持人转发面,深度同上 —— 同样一笔都不能丢。
        let (doc_envelopes, _) = broadcast::channel::<Arc<Vec<u8>>>(256);
        let doc_context: Arc<Mutex<Option<DocSyncContext>>> = Arc::new(Mutex::new(None));
        let join_desk = Arc::new(JoinRequestDesk::default());
        // 主持中的分享码。请求台批准时要交出它;没在共享时它是 None,
        // 这样「没在共享」和「拒绝了你」能被分开回答。
        let hosted_code: Arc<Mutex<Option<String>>> = Arc::new(Mutex::new(None));
        let display_name = Arc::new(Mutex::new(String::new()));

        // Minimal 而非 N0:只设定必需的 crypto provider,不挂任何公共发现服务。
        let mut builder = Endpoint::builder(presets::Minimal)
            .secret_key(identity.secret().clone())
            .alpns(vec![
                LIVE_CAPTION_ALPN.to_vec(),
                DOC_SYNC_ALPN.to_vec(),
                iroh_gossip::ALPN.to_vec(),
            ]);

        builder = if config.relay_urls.is_empty() {
            builder.relay_mode(RelayMode::Disabled)
        } else {
            let configs: Vec<_> = config
                .relay_urls
                .iter()
                .cloned()
                // QUIC 地址发现用默认端口(7824);None 表示只走 HTTP 中继。
                .map(|url| iroh::RelayConfig::new(url, Some(Default::default())))
                .collect();
            builder.relay_mode(RelayMode::Custom(iroh::RelayMap::from_iter(configs)))
        };

        let known_addrs = iroh::address_lookup::MemoryLookup::new();
        builder = builder.address_lookup(known_addrs.clone());

        // 局域网上只广播一个不透明公钥 —— 姓名和房间信息**不进 mDNS**,否则
        // 咖啡馆里的任何人都能看到谁在开什么会。那些只在对方连上来时才给。
        let mdns = if config.enable_local_discovery {
            let service = iroh_mdns_address_lookup::MdnsAddressLookup::builder()
                .advertise(true)
                .build(identity.endpoint_id())
                .map_err(|e| NetError::Bind(format!("局域网发现: {e}")))?;
            builder = builder.address_lookup(service.clone());
            Some(service)
        } else {
            None
        };

        let endpoint = builder
            .bind()
            .await
            .map_err(|e| NetError::Bind(e.to_string()))?;

        let caption_watchers: Arc<std::sync::Mutex<Vec<Connection>>> = Default::default();
        let last_caption: Arc<std::sync::Mutex<Option<Arc<CaptionFrame>>>> = Default::default();
        let doc_connections: Arc<std::sync::Mutex<Vec<Connection>>> = Default::default();
        let room_access: RoomAccessSlot = Default::default();
        let nearby_table: Arc<
            std::sync::Mutex<std::collections::BTreeMap<iroh::EndpointId, Option<String>>>,
        > = Default::default();
        let nearby_task = mdns.as_ref().map(|mdns| {
            let mdns = mdns.clone();
            let table = nearby_table.clone();
            let me = identity.endpoint_id();
            AbortOnDrop(tokio::spawn(async move {
                use n0_future::StreamExt;
                let mut events = mdns.subscribe().await;
                while let Some(event) = events.next().await {
                    match event {
                        iroh_mdns_address_lookup::DiscoveryEvent::Discovered {
                            endpoint_info,
                            ..
                        } => {
                            let id = endpoint_info.endpoint_id;
                            if id == me {
                                continue;
                            }
                            let data = endpoint_info.data.user_data().map(|d| d.to_string());
                            table.lock().unwrap().insert(id, data);
                        }
                        iroh_mdns_address_lookup::DiscoveryEvent::Expired { endpoint_id } => {
                            table.lock().unwrap().remove(&endpoint_id);
                        }
                        // non_exhaustive:我们只关心出现与消失。
                        _ => {}
                    }
                }
            }))
        });
        let gossip = iroh_gossip::net::Gossip::builder().spawn(endpoint.clone());
        let router = Router::builder(endpoint.clone())
            .accept(iroh_gossip::ALPN, gossip.clone())
            .accept(
                LIVE_CAPTION_ALPN,
                CaptionAcceptor {
                    captions: captions.clone(),
                    last: last_caption.clone(),
                    watchers: caption_watchers.clone(),
                    access: room_access.clone(),
                    doc_context: doc_context.clone(),
                },
            )
            .accept(
                NEARBY_ALPN,
                NearbyAcceptor {
                    desk: join_desk.clone(),
                    hosted_code: hosted_code.clone(),
                },
            )
            .accept(
                DOC_SYNC_ALPN,
                DocSyncAcceptor {
                    context: doc_context.clone(),
                    updates: doc_updates.clone(),
                    envelopes: doc_envelopes.clone(),
                    identity: identity.clone(),
                    access: room_access.clone(),
                    connections: doc_connections.clone(),
                },
            )
            .spawn();

        Ok(Self {
            router,
            endpoint,
            known_addrs,
            gossip,
            identity: identity.clone(),
            captions,
            last_caption,
            doc_updates,
            doc_context,
            join_desk,
            display_name,
            hosted_code,
            mdns,
            nearby_table,
            _nearby_task: nearby_task,
            caption_watchers,
            doc_connections,
            room_access,
            doc_envelopes,
        })
    }

    /// 本机公开身份。分享给对方的就是它。
    pub fn endpoint_id(&self) -> iroh::EndpointId {
        self.endpoint.id()
    }

    /// 当前可直连地址,用于装进分享码。
    pub async fn endpoint_addr(&self) -> EndpointAddr {
        self.endpoint.addr()
    }

    /// 把一帧字幕交给广播任务。
    ///
    /// **立即返回,永不阻塞。** 没有接收者时是 no-op;接收者慢了就丢旧帧。
    /// 这是采集回调能安全调用它的前提。
    pub fn broadcast_caption(&self, frame: CaptionFrame) {
        let frame = Arc::new(frame);
        *self.last_caption.lock().unwrap() = Some(frame.clone());
        // send 只在没有订阅者时报错,那是正常状态,不是故障。
        let _ = self.captions.send(frame);
    }

    /// 这一场播完了:忘掉最后一帧,下一场的观看端不会先看到上一场的字幕。
    pub fn end_broadcast(&self) {
        *self.last_caption.lock().unwrap() = None;
    }

    /// 等到与任一配置中继握手成功,或超时。
    ///
    /// 中继握手要过 relay-auth 门禁:没在邀请码服务登记过的 endpoint 会被
    /// 拒之门外,表现就是这里一直等不到 —— 所以「等到了」证明的是
    /// 「邀请码 → 登记 → 中继放行」整条链,不只是网络通。
    /// 真实网络冒烟(scripts/share_relay_smoke.sh)靠它做断言。
    pub async fn relay_online(&self, timeout: std::time::Duration) -> bool {
        tokio::time::timeout(timeout, self.endpoint.online())
            .await
            .is_ok()
    }

    /// 主持人视角:此刻连着字幕通道的观看端,以及各自实际走的链路。
    ///
    /// 与观看端的 `link_path` 同一份真值来源(QUIC 当前选中的传输路径)。
    /// 已断开的连接顺手剪掉 —— 注册表只在 accept 与这里被碰,不需要后台清扫。
    pub fn caption_watchers(&self) -> Vec<(iroh::EndpointId, CaptionLinkPath)> {
        let mut guard = self.caption_watchers.lock().unwrap();
        guard.retain(|conn| conn.close_reason().is_none());
        guard
            .iter()
            .filter_map(|conn| Some((conn.remote_id(), caption_link_path_of(conn)?)))
            .collect()
    }

    /// 接上文档同步。在此之前 `DOC_SYNC_ALPN` 上的连接一律被拒。
    pub async fn enable_document_sync(&self, context: DocSyncContext) {
        *self.doc_context.lock().await = Some(context);
    }

    /// 关掉文档同步:之后拨进来的文档连接一律被拒,已有的连接当场断开。
    pub async fn disable_document_sync(&self) {
        *self.doc_context.lock().await = None;
        let mut registry = self.doc_connections.lock().unwrap();
        for conn in registry.drain(..) {
            conn.close(0u32.into(), b"document sync ended");
        }
    }

    /// 把本机产生的一份文档更新推给所有对端。
    ///
    /// 由 Loro 的 `subscribe_local_update` 驱动。立即返回,不阻塞编辑。
    /// `document_id` 必须是这份更新真正所属的那一篇 —— 按 Notebook 共享时,
    /// 对端要靠它把更新落到正确的文档上。
    pub fn publish_document_update(&self, document_id: String, update: Vec<u8>) {
        let _ = self.doc_updates.send(Arc::new((document_id, update)));
    }

    /// 主动连上一个对端做文档同步:先补齐历史,再持续互推。
    pub async fn sync_document_with(&self, peer: EndpointAddr) -> Result<(), NetError> {
        let context = {
            let guard = self.doc_context.lock().await;
            guard
                .clone()
                .ok_or_else(|| NetError::Connect("文档同步尚未启用".into()))?
        };

        let conn = self
            .endpoint
            .connect(peer, DOC_SYNC_ALPN)
            .await
            .map_err(|e| NetError::Connect(e.to_string()))?;

        // 补齐历史:告诉对方我停在哪，收下它认为我缺的那部分。
        let (mut send, mut recv) = conn
            .open_bi()
            .await
            .map_err(|e| NetError::Stream(e.to_string()))?;
        let have = declare_versions(&context.scope, context.sink.as_ref());
        write_message(&mut send, &have)
            .await
            .map_err(|e| NetError::Stream(e.to_string()))?;
        let _ = send.finish();

        if let Ok(DocSyncMessage::Updates { envelopes }) =
            read_message::<_, DocSyncMessage>(&mut recv).await
        {
            for envelope in envelopes {
                apply_incoming(&context, &envelope, Some(&self.doc_envelopes)).await;
            }
        }

        // 之后双向互推:各自开 uni-stream 发自己的更新。反熵与应答
        // 与推送并跑 —— 推送是快路径,对账兜底。
        let outbound = spawn_update_pusher(
            conn.clone(),
            self.doc_updates.subscribe(),
            self.doc_envelopes.subscribe(),
            context.clone(),
            self.identity.clone(),
        );
        let inbound =
            spawn_update_reader(conn.clone(), context.clone(), self.doc_envelopes.clone());
        let responder = spawn_have_responder(conn.clone(), context.clone(), self.identity.clone());
        let prober = spawn_anti_entropy(conn.clone(), context, self.doc_envelopes.clone());
        // 以连接为准收尾。推送任务只在有东西可发时才碰连接,对端关了它也
        // 察觉不到 —— 等它们自己结束,调用方就永远以为还连着,对端(比如
        // 主持人后来才允许留存)要它重拨时它也不会重拨。
        let tasks = [outbound, inbound, responder, prober];
        conn.closed().await;
        for task in &tasks {
            task.abort();
        }
        Ok(())
    }

    /// 把一台机器的地址喂进地址簿。
    ///
    /// 局域网发现给的是完整地址,但请求加入时只按 id 拨号 —— 先喂进来,
    /// 否则拿到公钥却无处可拨(和 `join_room` 同一个道理)。
    pub async fn join_room_addr_hint(&self, addr: EndpointAddr) {
        self.known_addrs.add_endpoint_info(addr);
    }

    /// 等待批准的加入请求。界面拿去显示。
    pub fn join_desk(&self) -> Arc<JoinRequestDesk> {
        self.join_desk.clone()
    }

    /// 告诉请求台现在主持的是哪个分享码。没在共享时传 `None`。
    pub async fn set_hosted_share_code(&self, code: Option<String>) {
        *self.hosted_code.lock().await = code;
    }

    /// 本机自报的名字。会交给对方显示,所以先收拾干净。
    pub async fn set_display_name(&self, name: &str) {
        *self.display_name.lock().await = sanitize_display_name(name);
    }

    /// 同一网络里愿意被找到的直播。
    ///
    /// 只列出宣告了 [`NearbyAnnouncement`] 的机器 —— 没在直播、或主持人没打开
    /// 「让附近的人找到」的,根本不出现。表是常驻订阅维护的;刚绑定时可能还
    /// 空着,这时最多等 `window` 让第一批宣告到达。没开局域网发现时返回空。
    pub async fn nearby_peers(&self, window: std::time::Duration) -> Vec<NearbyPeer> {
        if self.mdns.is_none() {
            return Vec::new();
        }
        let deadline = tokio::time::Instant::now() + window;
        loop {
            let live: Vec<NearbyPeer> = self
                .nearby_table
                .lock()
                .unwrap()
                .iter()
                .filter_map(|(id, data)| {
                    let announcement = NearbyAnnouncement::decode(data.as_deref()?)?;
                    Some(NearbyPeer {
                        endpoint_id: *id,
                        short_label: id.fmt_short().to_string(),
                        announcement,
                    })
                })
                .collect();
            if !live.is_empty() || tokio::time::Instant::now() >= deadline {
                return live;
            }
            tokio::time::sleep(std::time::Duration::from_millis(200)).await;
        }
    }

    /// 在局域网上宣告(或撤下)这场直播的名字与标题。
    ///
    /// `None` 发的是「静默」标记而不是清空 —— mDNS 服务只在有值时覆写 TXT,
    /// 清空会让上一场的标题一直挂在别人的列表里。
    pub fn set_nearby_announcement(&self, announcement: Option<&NearbyAnnouncement>) {
        let text = announcement
            .map(NearbyAnnouncement::encode)
            .unwrap_or_else(|| NEARBY_SILENT.to_string());
        match text.parse::<iroh::address_lookup::UserData>() {
            Ok(data) => self.endpoint.set_user_data_for_address_lookup(Some(data)),
            Err(error) => tracing::warn!(%error, "附近宣告放不进 mDNS 记录"),
        }
    }

    /// 主持人把一位成员移出当前房间:出名册、广播新名册、断开他的字幕与
    /// 文档连接。他手里的码还在,但再连进来会被拒 —— 要让所有旧码失效,
    /// 只能停止这场共享再开一场。
    pub async fn remove_member(&self, room: &RoomHandle, who: iroh::EndpointId) -> bool {
        let removed = room.ban(who).await;
        if !removed {
            return false;
        }
        let roster = room.roster().await;
        if let Some(context) = self.doc_context.lock().await.as_ref() {
            if context.scope == *roster.scope() {
                *context.roster.lock().await = roster;
            }
        }
        for registry in [&self.caption_watchers, &self.doc_connections] {
            let mut guard = registry.lock().unwrap();
            guard.retain(|conn| {
                if conn.remote_id() == who {
                    conn.close(CLOSE_REMOVED.into(), b"removed by host");
                    false
                } else {
                    conn.close_reason().is_none()
                }
            });
        }
        true
    }

    /// 向同一网络里的某台机器请求加入它的共享。
    ///
    /// 成功时返回对方交出的分享码。**钥匙不出局域网** —— 它经这条直连交出,
    /// 不经过任何聊天软件,也不会留在别人的聊天记录里。
    ///
    /// `peer` 是十六进制的 endpoint id。收字符串而不是类型,是为了让上层不必
    /// 直接依赖 iroh —— 解析规则归传输层(和 `parse_relay_urls` 同一个道理)。
    pub async fn request_to_join(
        &self,
        peer: &str,
    ) -> Result<Result<String, DenyReason>, NetError> {
        let peer: iroh::EndpointId = peer
            .trim()
            .parse()
            .map_err(|_| NetError::Connect(format!("endpoint id 无法解析: {peer}")))?;
        let name = self.display_name.lock().await.clone();
        let conn = self
            .endpoint
            .connect(peer, NEARBY_ALPN)
            .await
            .map_err(|e| NetError::Connect(e.to_string()))?;
        let (mut send, mut recv) = conn
            .open_bi()
            .await
            .map_err(|e| NetError::Stream(e.to_string()))?;
        write_message(
            &mut send,
            &NearbyMessage::JoinRequest { display_name: name },
        )
        .await
        .map_err(|e| NetError::Stream(e.to_string()))?;
        let _ = send.finish();

        match read_message::<_, NearbyMessage>(&mut recv).await {
            Ok(NearbyMessage::JoinGranted { share_code }) => Ok(Ok(share_code)),
            Ok(NearbyMessage::JoinDenied { reason }) => Ok(Err(reason)),
            Ok(_) => Ok(Err(DenyReason::Declined)),
            Err(error) => Err(NetError::Stream(error.to_string())),
        }
    }

    /// 加入分享码所描述的房间。
    ///
    /// 房间是一个 gossip topic,由 `room_secret` 与共享范围共同派生 —— 所以它不可
    /// 从 Notebook id 猜出来,轮换 secret 就等于换一个房间。
    ///
    /// `bootstrap` 是已知的成员;主持人自己开房时传空。
    pub async fn join_room(
        &self,
        code: &ShareCode,
        bootstrap: Vec<iroh::EndpointId>,
    ) -> Result<RoomHandle, NetError> {
        let me = self.identity.endpoint_id();
        let host = code.host.id;
        let scope = code.scope.clone();

        // 先把主持人的直连地址喂进地址簿,再让 gossip 按 id 去拨。
        self.known_addrs.add_endpoint_info(code.host.clone());

        let mut bootstrap = bootstrap;
        if host != me && !bootstrap.contains(&host) {
            bootstrap.push(host);
        }

        let topic = self
            .gossip
            .subscribe(code.topic_id(), bootstrap)
            .await
            .map_err(|e| NetError::Connect(e.to_string()))?;
        let (sender, mut receiver) = topic.split();

        // 昵称要在建 presence 之前读出来:它既随 Hello 广播出去,也要在本地
        // 记下,否则自己在房间里永远显示成一串公钥。
        let my_name = self.display_name.lock().await.clone();
        let presence = Arc::new(Mutex::new(RoomPresence::new(
            scope.clone(),
            host,
            me,
            &my_name,
            code.policy,
        )));

        // Hello 不能只在加入时发一次。
        //
        // `subscribe` 立即返回,此刻通常还没有任何邻居,那一发就石沉大海 —— 而
        // 没有人会替你重发。所以真正的announce时机是「有邻居上线了」,首次加入与
        // 断线重连因此走同一条路径。
        // Hello 带上自己的名字,房间里的人才看得出彼此是谁。
        let hello = seal_control(
            &RoomControl::hello(&my_name),
            &scope,
            self.identity.secret(),
        )
        .map_err(|e| NetError::Stream(e.to_string()))?;
        // 已经有邻居时也发一次,省掉一个来回。
        let _ = sender.broadcast(hello.clone().into()).await;

        let generation = ROOM_GENERATION.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let shared_sender = Arc::new(Mutex::new(Some(sender.clone())));
        *self.room_access.lock().unwrap() = Some(RoomAccess {
            generation,
            host,
            me,
            scope: scope.clone(),
            room_secret: code.room_secret.clone(),
            presence: presence.clone(),
            sender: shared_sender.clone(),
            identity: self.identity.secret().clone(),
        });
        // 事件循环会把 scope move 进去,离开时发 Goodbye 还要用,先留一份。
        let scope_for_handle = scope.clone();
        let task = {
            let presence = presence.clone();
            let secret = self.identity.secret().clone();
            let doc_context = self.doc_context.clone();
            tokio::spawn(async move {
                use futures_lite::StreamExt;
                while let Some(event) = receiver.next().await {
                    let Ok(event) = event else { break };
                    let changed = match event {
                        iroh_gossip::api::Event::Received(message) => {
                            match open_control(&message.content, &scope, host) {
                                Ok((author, control)) => {
                                    presence.lock().await.apply(author, control)
                                }
                                Err(error) => {
                                    // 坏消息丢掉即可,不该拖垮整个房间。
                                    tracing::debug!(%error, "丢弃一条控制面消息");
                                    false
                                }
                            }
                        }
                        iroh_gossip::api::Event::NeighborDown(who) => {
                            presence.lock().await.neighbor_down(who)
                        }
                        iroh_gossip::api::Event::NeighborUp(_) => {
                            // 新邻居出现:向它announce自己。对方可能是刚加入的人,
                            // 也可能是本机重连后重新看见的老成员。
                            let _ = sender.broadcast(hello.clone().into()).await;
                            false
                        }
                        iroh_gossip::api::Event::Lagged => false,
                    };

                    // 名册变了就由主持人重新广播。非主持人的 roster_broadcast 是 None,
                    // 所以这一段对观看者天然是空转。
                    if changed {
                        // 文档准入门的名册要跟着进化。它在 enable 时拿到的只是
                        // 一份快照 —— 不刷新,后来被批准的成员的每一笔订正都会
                        // 在成员检查上被拒收,表现为「观看端改了,主持人永远
                        // 收不到」,而且两边都不报错。
                        if let Some(context) = doc_context.lock().await.as_ref() {
                            if context.scope == scope {
                                *context.roster.lock().await =
                                    presence.lock().await.roster().clone();
                            }
                        }
                        let broadcast = presence.lock().await.roster_broadcast();
                        if let Some(roster) = broadcast {
                            if let Ok(bytes) = seal_control(&roster, &scope, &secret) {
                                let _ = sender.broadcast(bytes.into()).await;
                            }
                        }
                    }
                }
            })
        };

        Ok(RoomHandle {
            presence,
            host,
            scope: scope_for_handle,
            secret: self.identity.secret().clone(),
            sender: shared_sender,
            task,
            access: self.room_access.clone(),
            generation,
        })
    }

    pub async fn shutdown(self) {
        let _ = self.router.shutdown().await;
    }
}

/// 把一份收到的更新过门再合入。
/// 反熵间隔:每隔这么久与对端对一次版本账。
///
/// 实时推送是快路径,但它建立在「每一笔都送到了」的假设上 —— 丢包、
/// 误拒、任务假死,任何一笔缺席都会让后续更新永远挂起(CRDT 等前置)。
/// 版本对账不做这个假设:双方各自宣告到哪了,缺什么补什么,幂等。
/// 追平时只有一来一回的 Have/UpToDate,代价可以忽略。
const ANTI_ENTROPY_INTERVAL: std::time::Duration = std::time::Duration::from_secs(2);

/// 持续应答对端的版本宣告 —— 每条进来的 bi-stream 答一次。
///
/// 首次催缺与之后的反熵轮询走同一条协议,这里不区分。
fn spawn_have_responder(
    conn: Connection,
    context: DocSyncContext,
    identity: ShareIdentity,
) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        loop {
            let (mut send, mut recv) = match conn.accept_bi().await {
                Ok(pair) => pair,
                Err(_) => break,
            };
            if let Ok(DocSyncMessage::Have { versions }) =
                read_message::<_, DocSyncMessage>(&mut recv).await
            {
                let reply = respond_to_have(
                    &versions,
                    &context.scope,
                    context.sink.as_ref(),
                    identity.secret(),
                );
                let _ = write_message(&mut send, &reply).await;
                let _ = send.finish();
            }
        }
    })
}

/// 周期性向对端宣告本机版本,收下补发。反熵的主动半边。
fn spawn_anti_entropy(
    conn: Connection,
    context: DocSyncContext,
    relay: broadcast::Sender<Arc<Vec<u8>>>,
) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        loop {
            tokio::time::sleep(ANTI_ENTROPY_INTERVAL).await;
            let Ok((mut send, mut recv)) = conn.open_bi().await else {
                break;
            };
            let have = declare_versions(&context.scope, context.sink.as_ref());
            if write_message(&mut send, &have).await.is_err() {
                break;
            }
            let _ = send.finish();
            if let Ok(DocSyncMessage::Updates { envelopes }) =
                read_message::<_, DocSyncMessage>(&mut recv).await
            {
                for envelope in envelopes {
                    apply_incoming(&context, &envelope, Some(&relay)).await;
                }
            }
        }
    })
}

async fn apply_incoming(
    context: &DocSyncContext,
    envelope: &[u8],
    relay: Option<&broadcast::Sender<Arc<Vec<u8>>>>,
) {
    let roster = context.roster.lock().await.clone();
    match handle_incoming_update(
        envelope,
        &roster,
        context.guard.as_ref(),
        context.sink.as_ref(),
    ) {
        IncomingOutcome::Applied => {
            // 主持人转发合入成功的成员更新:成员之间没有连接,A 的订正
            // 只有这一跳才到得了 B。原始信封原样转发,签名仍是 A 的 ——
            // 每个接收端照常过完整条准入链。发回给 A 自己也无害:那些
            // ops A 已经有,合入是幂等的。被拒的更新不转发。
            if context.hosting {
                if let Some(relay) = relay {
                    let _ = relay.send(Arc::new(envelope.to_vec()));
                }
            }
        }
        outcome => tracing::debug!(?outcome, "丢弃一份未通过准入的文档更新"),
    }
}

/// 持续把更新推给一个对端。两个来源:本机更新(要用本机身份签名封装)与
/// 主持人转发面上的成员信封(已带原作者签名,原样送出)。
fn spawn_update_pusher(
    conn: Connection,
    mut updates: broadcast::Receiver<Arc<(String, Vec<u8>)>>,
    mut relayed: broadcast::Receiver<Arc<Vec<u8>>>,
    context: DocSyncContext,
    identity: ShareIdentity,
) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        loop {
            let envelope: Vec<u8> = tokio::select! {
                update = updates.recv() => {
                    let update = match update {
                        Ok(update) => update,
                        // 文档更新落后就没法只补最新的 —— CRDT 需要每一笔。断开让对方
                        // 重连后走补齐历史那条路,比装作没事继续发要诚实。
                        Err(broadcast::error::RecvError::Lagged(n)) => {
                            tracing::warn!(missed = n, "文档推送任务退出:本机更新队列落后");
                            break;
                        }
                        Err(broadcast::error::RecvError::Closed) => break,
                    };
                    let (document_id, bytes) = update.as_ref();
                    // 与 respond_to_have 同一条纪律:纪元判不出来就不发。
                    let Some(schema_epoch) =
                        context.sink.schema_epoch(&context.scope, document_id)
                    else {
                        continue;
                    };
                    let Some(envelope) = seal_update(
                        &context.scope,
                        document_id,
                        schema_epoch,
                        bytes.clone(),
                        identity.secret(),
                    ) else {
                        continue;
                    };
                    envelope
                }
                relayed_envelope = relayed.recv() => {
                    match relayed_envelope {
                        Ok(envelope) => envelope.as_ref().clone(),
                        // 转发信封同样一笔不能丢:落后就断开重来。
                        Err(broadcast::error::RecvError::Lagged(n)) => {
                            tracing::warn!(missed = n, "文档推送任务退出:转发队列落后");
                            break;
                        }
                        Err(broadcast::error::RecvError::Closed) => break,
                    }
                }
            };
            let stream = match conn.open_uni().await {
                Ok(stream) => stream,
                Err(error) => {
                    tracing::warn!(%error, "文档推送任务退出:开流失败(连接已断)");
                    break;
                }
            };
            let mut stream = stream;
            if let Err(error) = write_message(
                &mut stream,
                &DocSyncMessage::Updates {
                    envelopes: vec![envelope],
                },
            )
            .await
            {
                tracing::warn!(%error, "文档推送任务退出:写流失败");
                break;
            }
            let _ = stream.finish();
        }
    })
}

/// 持续接收对端推来的更新。
fn spawn_update_reader(
    conn: Connection,
    context: DocSyncContext,
    relay: broadcast::Sender<Arc<Vec<u8>>>,
) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        loop {
            let mut stream = match conn.accept_uni().await {
                Ok(stream) => stream,
                Err(error) => {
                    tracing::warn!(%error, "文档读取任务退出:连接已断");
                    break;
                }
            };
            match read_message::<_, DocSyncMessage>(&mut stream).await {
                Ok(DocSyncMessage::Updates { envelopes }) => {
                    for envelope in envelopes {
                        apply_incoming(&context, &envelope, Some(&relay)).await;
                    }
                }
                Ok(_) => {}
                Err(error) => tracing::debug!(%error, "丢弃一条无法解码的文档消息"),
            }
        }
    })
}

/// 「附近的人」的服务端:收下请求,停在请求台上等主持人回答。
#[derive(Debug, Clone)]
struct NearbyAcceptor {
    desk: Arc<JoinRequestDesk>,
    hosted_code: Arc<Mutex<Option<String>>>,
}

impl ProtocolHandler for NearbyAcceptor {
    async fn accept(&self, connection: Connection) -> Result<(), AcceptError> {
        let endpoint_id = connection.remote_id();
        let Ok((mut send, mut recv)) = connection.accept_bi().await else {
            return Ok(());
        };
        let Ok(NearbyMessage::JoinRequest { display_name }) =
            read_message::<_, NearbyMessage>(&mut recv).await
        else {
            return Ok(());
        };

        // 没在共享就当场回绝,不打扰主持人 —— 而且要说清楚是「没在共享」
        // 而不是「拒绝了你」,否则对方会反复敲门。
        if self.hosted_code.lock().await.is_none() {
            let _ = write_message(
                &mut send,
                &NearbyMessage::JoinDenied {
                    reason: DenyReason::NotSharing,
                },
            )
            .await;
            let _ = send.finish();
            // handler 一返回,Router 就关掉连接 —— 不等对方收完,回复会在路上丢掉,
            // 请求方看到的是「连接断了」而不是「对方没在共享」。
            connection.closed().await;
            return Ok(());
        }

        let request_id = uuid::Uuid::new_v4().to_string();
        let request = PendingJoinRequest {
            request_id: request_id.clone(),
            endpoint_id,
            // 名字是对方随便写的,收拾过再显示。唯一可信的身份是公钥。
            display_name: sanitize_display_name(&display_name),
        };
        let waiting = self.desk.park(request).await;

        let answer = match tokio::time::timeout(JOIN_REQUEST_TIMEOUT, waiting).await {
            Ok(Ok(Some(code))) => NearbyMessage::JoinGranted { share_code: code },
            Ok(Ok(None)) => NearbyMessage::JoinDenied {
                reason: DenyReason::Declined,
            },
            // 超时或请求台被丢弃:明确告诉对方没人理,好过让他一直转圈。
            _ => {
                self.desk.forget(&request_id).await;
                NearbyMessage::JoinDenied {
                    reason: DenyReason::TimedOut,
                }
            }
        };
        let _ = write_message(&mut send, &answer).await;
        let _ = send.finish();
        // 同上:等对方读完再让 handler 返回。
        connection.closed().await;
        Ok(())
    }
}

/// 文档同步的服务端。
#[derive(Debug, Clone)]
struct DocSyncAcceptor {
    context: Arc<Mutex<Option<DocSyncContext>>>,
    updates: broadcast::Sender<Arc<(String, Vec<u8>)>>,
    /// 主持人转发面。见 [`ShareEndpoint::doc_envelopes`]。
    envelopes: broadcast::Sender<Arc<Vec<u8>>>,
    identity: ShareIdentity,
    access: RoomAccessSlot,
    connections: Arc<std::sync::Mutex<Vec<Connection>>>,
}

impl ProtocolHandler for DocSyncAcceptor {
    async fn accept(&self, connection: Connection) -> Result<(), AcceptError> {
        // 没接上文档同步就没有可同步的东西。静默接受再什么都不做会让对方空等。
        let Some(context) = self.context.lock().await.clone() else {
            connection.close(1u32.into(), b"document sync not enabled");
            return Ok(());
        };
        // 文档里是整份文字稿:和字幕一样只给名册里的人。
        if !admit_or_close(&self.access, &self.context, &connection, false).await {
            return Ok(());
        }
        {
            let mut registry = self.connections.lock().unwrap();
            registry.retain(|conn| conn.close_reason().is_none());
            registry.push(connection.clone());
        }

        // 版本宣告的应答常驻 —— 首次催缺与之后每一轮反熵都走它。
        let responder =
            spawn_have_responder(connection.clone(), context.clone(), self.identity.clone());
        let outbound = spawn_update_pusher(
            connection.clone(),
            self.updates.subscribe(),
            self.envelopes.subscribe(),
            context.clone(),
            self.identity.clone(),
        );
        let inbound =
            spawn_update_reader(connection.clone(), context.clone(), self.envelopes.clone());
        // 受理侧也主动对账:宿主同样可能缺成员的更新。
        let prober = spawn_anti_entropy(connection.clone(), context, self.envelopes.clone());
        // 同 `sync_document_with`:连接断了就收尾,不留一直等更新的空转任务。
        let tasks = [responder, outbound, inbound, prober];
        connection.closed().await;
        for task in &tasks {
            task.abort();
        }
        Ok(())
    }
}

/// 等待主持人回答的加入请求。
///
/// 请求在这里停住,直到界面上有人点批准或拒绝。超时按拒绝处理 —— 让对方一直转圈
/// 比明确告诉他「没人理」更糟。
#[derive(Debug, Default)]
pub struct JoinRequestDesk {
    pending: Mutex<
        Vec<(
            PendingJoinRequest,
            tokio::sync::oneshot::Sender<Option<String>>,
        )>,
    >,
}

/// 一条加入请求最多等主持人多久。
///
/// 比一次「看一眼、想一下、点一下」长得多,又不至于让请求方以为程序死了。
const JOIN_REQUEST_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(60);

impl JoinRequestDesk {
    /// 界面拿去显示。
    pub async fn pending(&self) -> Vec<PendingJoinRequest> {
        self.pending
            .lock()
            .await
            .iter()
            .map(|(request, _)| request.clone())
            .collect()
    }

    /// 批准:把分享码交给等在那里的请求。
    pub async fn approve(&self, request_id: &str, share_code: String) -> bool {
        self.answer(request_id, Some(share_code)).await
    }

    /// 拒绝。
    pub async fn decline(&self, request_id: &str) -> bool {
        self.answer(request_id, None).await
    }

    async fn answer(&self, request_id: &str, code: Option<String>) -> bool {
        let mut pending = self.pending.lock().await;
        let Some(index) = pending.iter().position(|(r, _)| r.request_id == request_id) else {
            return false;
        };
        let (_, responder) = pending.remove(index);
        responder.send(code).is_ok()
    }

    async fn park(
        &self,
        request: PendingJoinRequest,
    ) -> tokio::sync::oneshot::Receiver<Option<String>> {
        let (tx, rx) = tokio::sync::oneshot::channel();
        self.pending.lock().await.push((request, tx));
        rx
    }

    async fn forget(&self, request_id: &str) {
        self.pending
            .lock()
            .await
            .retain(|(r, _)| r.request_id != request_id);
    }
}

/// 一个已加入的房间。丢弃它就退出该房间的控制面。
#[derive(Debug)]
pub struct RoomHandle {
    presence: Arc<Mutex<RoomPresence>>,
    host: iroh::EndpointId,
    scope: ScopeId,
    secret: iroh::SecretKey,
    /// 用来发 Goodbye。事件循环也持有一份。
    sender: Arc<Mutex<Option<iroh_gossip::api::GossipSender>>>,
    task: tokio::task::JoinHandle<()>,
    /// 端点的放行槽。房间散了要把自己从里面撤掉,否则字幕通道还按一个
    /// 已经不存在的名册放人。
    access: RoomAccessSlot,
    generation: u64,
}

impl RoomHandle {
    /// 离开房间前跟大家说一声。
    ///
    /// 不说也不会错 —— gossip 的 `NeighborDown` 是兜底 —— 但那要等超时,
    /// 期间房间里所有人都还以为你在。说一声是即时的。
    pub async fn announce_departure(&self) {
        let Some(sender) = self.sender.lock().await.as_ref().cloned() else {
            return;
        };
        if let Ok(bytes) = seal_control(&RoomControl::Goodbye, &self.scope, &self.secret) {
            let _ = sender.broadcast(bytes.into()).await;
        }
    }

    /// 当前名册的快照。
    pub async fn roster(&self) -> RoomRoster {
        self.presence.lock().await.roster().clone()
    }

    /// 房间的主持人。
    pub fn host(&self) -> iroh::EndpointId {
        self.host
    }

    /// 房间里都有谁,以及他们自报的名字。
    ///
    /// 名字可能为空或重复 —— 它是对方自己填的。公钥才是身份,所以两个都给。
    pub async fn members_with_names(&self) -> Vec<(iroh::EndpointId, String)> {
        self.presence.lock().await.members_with_names()
    }

    /// 当前在场人数。
    pub async fn member_count(&self) -> usize {
        self.presence.lock().await.roster().members().count()
    }

    /// 主持人是否已明确道别。观看端据此把「接收中」切换成
    /// 「这场已结束,收到的内容还在」。
    pub async fn host_departed(&self) -> bool {
        self.presence.lock().await.host_departed()
    }

    /// 移出一位成员并广播新名册。见 [`ShareEndpoint::remove_member`]。
    async fn ban(&self, who: iroh::EndpointId) -> bool {
        let broadcast = {
            let mut presence = self.presence.lock().await;
            if !presence.ban(who) {
                return false;
            }
            presence.roster_broadcast()
        };
        if let (Some(roster), Some(sender)) =
            (broadcast, self.sender.lock().await.as_ref().cloned())
        {
            if let Ok(bytes) = seal_control(&roster, &self.scope, &self.secret) {
                let _ = sender.broadcast(bytes.into()).await;
            }
        }
        true
    }
}

impl Drop for RoomHandle {
    fn drop(&mut self) {
        self.task.abort();
        let mut slot = self.access.lock().unwrap();
        if slot.as_ref().map(|access| access.generation) == Some(self.generation) {
            *slot = None;
        }
    }
}

/// 后台任务的句柄,随拥有者一起结束。
#[derive(Debug)]
struct AbortOnDrop(tokio::task::JoinHandle<()>);

impl Drop for AbortOnDrop {
    fn drop(&mut self) {
        self.0.abort();
    }
}

/// 观看端到主持人此刻实际走的链路。
///
/// 真值来自 QUIC 连接当前**选中**的传输路径,不是配置也不是猜测——
/// 「直连被禁、只剩中继」正是 AP 隔离网络的诊断特征,双机验证清单
/// 靠这个区分。曾经有一个写死 true 的指示器,恒真的指示器比没有更坏,
/// 被撤掉了;这个类型是它的真值接班人。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CaptionLinkPath {
    /// 打洞成功,流量端到端直达。
    Direct,
    /// 直连没打通,流量经中继转发(仍端到端加密)。
    Relayed,
}

/// 收到的字幕帧汇集处。
#[derive(Debug, Clone, Default)]
pub struct CaptionInbox {
    frames: Arc<Mutex<Vec<CaptionFrame>>>,
    /// 到主持人的当前链路。`None` = 没连上(或刚断开重连中)。
    /// 用同步锁:唯一的读方(share_state)是同步调用,写方每帧一次。
    link: Arc<std::sync::Mutex<Option<CaptionLinkPath>>>,
    /// 主持人把本机移出了。接收循环据此停止重连。
    removed: Arc<std::sync::atomic::AtomicBool>,
}

impl CaptionInbox {
    /// 取走已收到的帧。
    pub async fn drain(&self) -> Vec<CaptionFrame> {
        std::mem::take(&mut *self.frames.lock().await)
    }

    /// 当前到主持人的链路。
    pub fn link_path(&self) -> Option<CaptionLinkPath> {
        *self.link.lock().unwrap()
    }

    /// 主持人是否把本机移出了这场共享。
    pub fn removed(&self) -> bool {
        self.removed.load(std::sync::atomic::Ordering::Relaxed)
    }

    fn set_link_path(&self, value: Option<CaptionLinkPath>) {
        *self.link.lock().unwrap() = value;
    }

    async fn push(&self, frame: CaptionFrame) {
        self.frames.lock().await.push(frame);
    }
}

/// 连接当前选中路径的链路类型。选中路径尚未确立时按保守值报中继——
/// 打洞成功与否只有「选中了直连路径」才算数。
fn caption_link_path_of(conn: &Connection) -> Option<CaptionLinkPath> {
    let paths = conn.paths();
    let selected = paths.iter().find(|path| path.is_selected())?;
    Some(if selected.is_relay() {
        CaptionLinkPath::Relayed
    } else {
        CaptionLinkPath::Direct
    })
}

/// 字幕通道的服务端。
///
/// 流向是**观看端拨号、主持端推送**:观看端连上来后,这个 handler 订阅本机的广播
/// 通道,把每一帧当作一条独立的 uni-stream 写回去。反过来做(两端都 accept)会
/// 双向死锁。
#[derive(Debug, Clone)]
struct CaptionAcceptor {
    captions: broadcast::Sender<Arc<CaptionFrame>>,
    last: Arc<std::sync::Mutex<Option<Arc<CaptionFrame>>>>,
    /// 活跃观看端注册表,主持人的链路诊断从这里读。
    watchers: Arc<std::sync::Mutex<Vec<Connection>>>,
    access: RoomAccessSlot,
    doc_context: Arc<Mutex<Option<DocSyncContext>>>,
}

impl ProtocolHandler for CaptionAcceptor {
    async fn accept(&self, connection: Connection) -> Result<(), AcceptError> {
        if !admit_or_close(&self.access, &self.doc_context, &connection, true).await {
            return Ok(());
        }
        {
            // 登记进注册表,顺手剪掉已断开的 —— 重连会积累死连接。
            let mut watchers = self.watchers.lock().unwrap();
            watchers.retain(|conn| conn.close_reason().is_none());
            watchers.push(connection.clone());
        }
        // 先订阅再取最后一帧:两步之间播出的帧会在订阅里,不会漏;重复的
        // 那一帧按 revision 在接收端丢掉。
        let mut rx = self.captions.subscribe();
        let mut pending = self.last.lock().unwrap().clone();
        loop {
            let frame = match pending.take() {
                Some(frame) => frame,
                None => match rx.recv().await {
                    Ok(frame) => frame,
                    // 落后太多:跳到最新,不补发。旧帧对 replace-in-full 没有价值。
                    Err(broadcast::error::RecvError::Lagged(_)) => continue,
                    Err(broadcast::error::RecvError::Closed) => break,
                },
            };
            // 每帧一条 uni-stream:写完即关,帧与帧互不阻塞,也没有尺寸上限。
            let mut stream = match connection.open_uni().await {
                Ok(stream) => stream,
                // 对端断开是正常收尾,不是错误。
                Err(_) => break,
            };
            if write_message(&mut stream, frame.as_ref()).await.is_err() {
                break;
            }
            let _ = stream.finish();
        }
        Ok(())
    }
}

/// 接收端:连上广播者并把帧投进 inbox。
/// 断线后隔多久重试。
///
/// 连接会因为很多寻常原因断掉:换了 Wi-Fi、机器睡了一下、路由器抖了一下。
/// 一断就永久放弃,表现是「字幕忽然停了,而且再也不回来」——而界面上看不出
/// 任何异常,因为它并不知道自己已经聋了。
const RECONNECT_DELAY: std::time::Duration = std::time::Duration::from_secs(2);

pub async fn receive_captions(
    endpoint: &ShareEndpoint,
    code: ShareCode,
    inbox: CaptionInbox,
) -> Result<(), NetError> {
    let ticket = code
        .room_secret
        .admission_ticket(&code.scope, &endpoint.endpoint_id());
    let host = code.host;
    let scope = code.scope;
    // 一直重连,直到调用方把这个任务取消(停止共享或退出房间时会取消)。
    loop {
        match receive_captions_once(endpoint, host.clone(), scope.clone(), ticket, inbox.clone())
            .await
        {
            Ok(()) => {}
            Err(NetError::Removed) => {
                inbox
                    .removed
                    .store(true, std::sync::atomic::Ordering::Relaxed);
                inbox.set_link_path(None);
                return Err(NetError::Removed);
            }
            Err(error) => tracing::debug!(%error, "字幕连接中断,准备重连"),
        }
        // 断线期间不显示过期的链路——「没连上」和「经中继」在界面上
        // 必须是两句话。
        inbox.set_link_path(None);
        tokio::time::sleep(RECONNECT_DELAY).await;
    }
}

async fn receive_captions_once(
    endpoint: &ShareEndpoint,
    host: EndpointAddr,
    scope: ScopeId,
    ticket: [u8; 32],
    inbox: CaptionInbox,
) -> Result<(), NetError> {
    let conn = endpoint
        .endpoint
        .connect(host, LIVE_CAPTION_ALPN)
        .await
        .map_err(|e| NetError::Connect(e.to_string()))?;
    inbox.set_link_path(caption_link_path_of(&conn));

    // 先交入场凭证,主持人当场核对。旧版主持人不读它,这条流就晾在那里,无害。
    let display_name = endpoint.display_name.lock().await.clone();
    let mut hello = conn
        .open_uni()
        .await
        .map_err(|e| NetError::Stream(e.to_string()))?;
    write_message(
        &mut hello,
        &CaptionHello {
            ticket,
            display_name,
        },
    )
    .await
    .map_err(|e| NetError::Stream(e.to_string()))?;
    let _ = hello.finish();

    while let Ok(mut stream) = conn.accept_uni().await {
        // 每帧刷新一次:打洞在首帧之后才成功时,指示器要跟着从
        // 「经中继」升级成「直连」。paths() 是快照读,每帧一次很便宜。
        inbox.set_link_path(caption_link_path_of(&conn));
        match read_message::<_, CaptionFrame>(&mut stream).await {
            Ok(frame) if frame.scope == scope => inbox.push(frame).await,
            Ok(_) => tracing::debug!("丢弃一帧属于其他共享范围的字幕"),
            Err(error) => tracing::debug!(%error, "丢弃一帧无法解码的字幕"),
        }
    }
    if closed_as_removed(&conn) {
        return Err(NetError::Removed);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// ALPN 是协议身份的一部分,改动即破坏兼容。这条测试把它钉住。
    #[test]
    fn alpns_are_stable() {
        assert_eq!(LIVE_CAPTION_ALPN, b"zutalk/live-caption/1");
        assert_eq!(DOC_SYNC_ALPN, b"zutalk/doc-sync/1");
        assert_ne!(LIVE_CAPTION_ALPN, DOC_SYNC_ALPN);
    }

    #[test]
    fn relay_urls_parse_and_skip_blanks() {
        let parsed = parse_relay_urls(&[
            "https://relay.example".into(),
            "  ".into(),
            String::new(),
            "  https://other.example  ".into(),
        ])
        .unwrap();
        assert_eq!(parsed.len(), 2, "空行是「不要中继」,不是错误");
    }

    /// 全空等于「只走直连」—— 这是一个合法选择,不该报错。
    #[test]
    fn all_blank_means_no_relay() {
        assert!(parse_relay_urls(&["".into(), "   ".into()])
            .unwrap()
            .is_empty());
    }

    /// 但真写错了要当场报出来,不能等到连不上才发现。
    #[test]
    fn a_malformed_relay_url_is_refused() {
        let error = parse_relay_urls(&["not a url".into()]).unwrap_err();
        assert!(error.contains("not a url"));
    }

    #[tokio::test]
    async fn endpoint_binds_without_relay_or_discovery() {
        let identity = ShareIdentity::generate();
        let ep = ShareEndpoint::bind(&identity, ShareEndpointConfig::default())
            .await
            .expect("离线绑定应当成功");
        assert_eq!(ep.endpoint_id(), identity.endpoint_id());
        ep.shutdown().await;
    }

    /// 没有接收者时广播必须是 no-op,而不是错误或阻塞 —— 采集回调依赖这一点。
    #[tokio::test]
    async fn broadcasting_without_listeners_is_a_noop() {
        let identity = ShareIdentity::generate();
        let ep = ShareEndpoint::bind(&identity, ShareEndpointConfig::default())
            .await
            .unwrap();
        ep.broadcast_caption(CaptionFrame::flat(
            ScopeId::Session {
                session_id: "s".into(),
            },
            1,
            vec![],
        ));
        ep.shutdown().await;
    }

    #[tokio::test]
    async fn inbox_drains_once() {
        let inbox = CaptionInbox::default();
        inbox
            .push(CaptionFrame::flat(
                ScopeId::Session {
                    session_id: "s".into(),
                },
                1,
                vec![],
            ))
            .await;
        assert_eq!(inbox.drain().await.len(), 1);
        assert!(inbox.drain().await.is_empty());
    }
}
