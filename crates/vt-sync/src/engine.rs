//! 同步引擎:一个端点,多个同步空间。
//!
//! **空间**是一组文档加一份成员名单:自己的设备组是一个空间,邀请同事协作的每个
//! 主题各是一个空间,备份也是。同一台设备可以同时在好几个空间里,它们共用一个
//! iroh 端点;每个(空间, 对端设备)一条连接,握手的 [`SyncMessage::Hello`] 说明
//! 这条连接属于哪个空间。
//!
//! 每对设备在一个空间里只留一条连接。两边都会拨,但 id 小的一方先拨,大的一方
//! 等几秒没见到连接才拨 —— 对方可能正在退避,或者还以为一条已经断掉的旧连接活着。
//! 两边同时拨出的两条连接按一条双方算得出同样结果的规则留一条,见 [`register`]。
//!
//! 连接之上的协议见 [`crate::protocol`]。每条连接一个读循环、一个写循环:
//!
//! - 读循环从不等写循环。收到的请求只是往写队列里记一笔(无界、每笔很小),
//!   真正的差量在写的那一刻才从存储里导出。两边都在大量互传时,谁也不会因为
//!   对方不读而卡住自己的读 —— 那是双向流最典型的死锁。
//! - 存储调用都放进阻塞线程池:导出与合并可能是几十毫秒的 CPU 活,不能占着
//!   网络任务的线程。

use std::collections::{BTreeSet, HashMap};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, RwLock};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use iroh::address_lookup::MemoryLookup;
use iroh::endpoint::{presets, Connection, RecvStream, SendStream};
use iroh::protocol::{AcceptError, ProtocolHandler, Router};
use iroh::{Endpoint, EndpointAddr, EndpointId, RelayMode, RelayUrl, Watcher};
use tokio::sync::{mpsc, Notify};

use crate::identity::DeviceIdentity;
use crate::membership::Membership;
use crate::pairing::{
    sanitize_device_name, InviteBook, InvitePurpose, PairMessage, PairRejection, PairingTicket,
    INVITE_TTL, PAIR_ALPN,
};
use crate::protocol::{
    SpaceId, SyncMessage, MAX_UPDATE_BYTES, PROTOCOL_VERSION, SYNC_ALPN, UPDATE_CHUNK_BYTES,
};
use crate::store::{DocId, DocumentStore};
use crate::wire::{read_frame, write_frame, WireError};

/// 局域网发现用的 mDNS 服务名。只看得见 ZuTalk 的同步端点,不和别的 iroh 应用混在一起。
const MDNS_SERVICE: &str = "zutalk-sync";

const CONNECT_TIMEOUT: Duration = Duration::from_secs(15);
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(10);
const REDIAL_MIN: Duration = Duration::from_secs(1);
const REDIAL_MAX: Duration = Duration::from_secs(30);
/// id 大的一方先等这么久,让小的一方先拨。
const HIGHER_SIDE_GRACE: Duration = Duration::from_secs(3);
/// 两条连接建立的时间相差不到这么久,算两边同时拨出。
const RACE_WINDOW: Duration = Duration::from_secs(3);

const CLOSE_BYE: u32 = 0;
const CLOSE_NOT_MEMBER: u32 = 1;
const CLOSE_UNKNOWN_SPACE: u32 = 2;
const CLOSE_REPLACED: u32 = 3;

#[derive(Debug, Clone)]
pub struct SyncConfig {
    /// 自建中继。为空表示只走直连(局域网 / 已知地址)。
    ///
    /// **不用 `presets::N0`**:那会把本机地址发布到 n0 的公共目录。
    pub relay_urls: Vec<RelayUrl>,
    /// 局域网 mDNS 发现。macOS 首次会弹本地网络授权。
    pub local_discovery: bool,
    /// 配对时告诉对方的本机名字。
    pub device_name: String,
    /// 定时完整对账的间隔,兜住所有丢掉的改动通知。
    pub anti_entropy: Duration,
    /// 配对码有效期。
    pub invite_ttl: Duration,
    /// 只绑回环地址。给进程内测试用:本机网卡上的代理、虚拟网卡会让自己连自己
    /// 的 UDP 时通时不通,测的就不再是引擎了。
    pub loopback_only: bool,
}

impl Default for SyncConfig {
    fn default() -> Self {
        Self {
            relay_urls: Vec::new(),
            local_discovery: false,
            device_name: String::new(),
            anti_entropy: Duration::from_secs(60),
            invite_ttl: INVITE_TTL,
            loopback_only: false,
        }
    }
}

#[derive(Debug, thiserror::Error)]
pub enum SyncError {
    #[error("端点启动失败: {0}")]
    Bind(String),
    #[error("本机没有这个同步空间")]
    UnknownSpace,
}

#[derive(Debug, thiserror::Error)]
pub enum PairError {
    #[error("连不上对方: {0}")]
    Unreachable(String),
    #[error(transparent)]
    Rejected(#[from] PairRejection),
    #[error("配对中断: {0}")]
    Interrupted(String),
}

/// 配对成功后加入方看到的结果。加入方据此在本机建好空间,再 [`SyncEngine::add_space`]。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Joined {
    pub space: SpaceId,
    pub purpose: InvitePurpose,
    /// 邀请方给这个空间的说明,比如主题名。设备组为空。
    pub label: String,
    /// 邀请方给应用自己的上下文,比如协作主题在邀请方那里的 id。
    pub context: String,
    pub inviter: EndpointId,
    pub inviter_name: String,
}

/// 一台对端设备在一个空间里此刻的同步状态。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PeerStatus {
    pub device: EndpointId,
    pub connected: bool,
    /// 连着且走的是中继(打洞没成)。
    pub via_relay: bool,
    /// 最近一次「对方有的本机都有了」的时刻(Unix 毫秒)。本次运行内有效。
    pub last_synced_unix_ms: Option<i64>,
    /// 还在等对方回的文档数。
    pub in_flight: usize,
}

pub struct SyncEngine {
    host: Arc<Host>,
    router: Router,
}

impl std::fmt::Debug for SyncEngine {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SyncEngine")
            .field("device", &self.host.identity)
            .finish_non_exhaustive()
    }
}

/// 端点与所有空间共享的东西。
struct Host {
    endpoint: Endpoint,
    identity: DeviceIdentity,
    config: SyncConfig,
    known: MemoryLookup,
    spaces: RwLock<HashMap<SpaceId, Arc<Space>>>,
    invites: InviteBook,
    /// 叫醒所有在退避中的拨号循环(网络变了、刚拿到新地址)。
    redial: Notify,
    closing: AtomicBool,
    /// 引擎启动时所在的运行时。调用方(比如 FFI 线程)不在运行时里时,拨号
    /// 任务也得有地方跑。
    runtime: tokio::runtime::Handle,
}

/// 一个同步空间:文档、名单、此刻的连接与拨号任务。
struct Space {
    id: SpaceId,
    store: Arc<dyn DocumentStore>,
    membership: Arc<dyn Membership>,
    links: Mutex<HashMap<EndpointId, Arc<Link>>>,
    synced_at: Mutex<HashMap<EndpointId, i64>>,
    dialers: Mutex<HashMap<EndpointId, tokio::task::JoinHandle<()>>>,
    removed: AtomicBool,
}

impl SyncEngine {
    pub async fn start(identity: DeviceIdentity, config: SyncConfig) -> Result<Self, SyncError> {
        // Minimal 而非 N0:不挂任何公共发现服务。
        let mut builder = Endpoint::builder(presets::Minimal)
            .secret_key(identity.secret().clone())
            .alpns(vec![SYNC_ALPN.to_vec(), PAIR_ALPN.to_vec()]);
        builder = if config.relay_urls.is_empty() {
            builder.relay_mode(RelayMode::Disabled)
        } else {
            // 自建中继前面是只转 HTTP 的边缘代理,UDP 到不了,所以不开 QUIC 地址发现。
            let relays = config
                .relay_urls
                .iter()
                .cloned()
                .map(|url| iroh::RelayConfig::new(url, None));
            builder.relay_mode(RelayMode::Custom(iroh::RelayMap::from_iter(relays)))
        };
        if config.loopback_only {
            builder = builder
                .bind_addr("127.0.0.1:0")
                .and_then(|b| b.bind_addr("[::1]:0"))
                .map_err(|e| SyncError::Bind(e.to_string()))?;
        }
        let known = MemoryLookup::new();
        builder = builder.address_lookup(known.clone());
        if config.local_discovery {
            let mdns = iroh_mdns_address_lookup::MdnsAddressLookup::builder()
                .advertise(true)
                .service_name(MDNS_SERVICE)
                .build(identity.id())
                .map_err(|e| SyncError::Bind(format!("局域网发现: {e}")))?;
            builder = builder.address_lookup(mdns);
        }
        let endpoint = builder
            .bind()
            .await
            .map_err(|e| SyncError::Bind(e.to_string()))?;

        let host = Arc::new(Host {
            endpoint: endpoint.clone(),
            identity,
            config,
            known,
            spaces: RwLock::default(),
            invites: InviteBook::default(),
            redial: Notify::new(),
            closing: AtomicBool::new(false),
            runtime: tokio::runtime::Handle::current(),
        });
        let router = Router::builder(endpoint)
            .accept(SYNC_ALPN, SyncAcceptor(host.clone()))
            .accept(PAIR_ALPN, PairAcceptor(host.clone()))
            .spawn();
        Ok(Self { host, router })
    }

    pub fn device_id(&self) -> EndpointId {
        self.host.identity.id()
    }

    /// 开始同步一个空间。同一个 id 已经在了就换成新的(旧连接断开)。
    pub fn add_space(
        &self,
        id: SpaceId,
        store: Arc<dyn DocumentStore>,
        membership: Arc<dyn Membership>,
    ) {
        let space = Arc::new(Space {
            id,
            store,
            membership,
            links: Mutex::default(),
            synced_at: Mutex::default(),
            dialers: Mutex::default(),
            removed: AtomicBool::new(false),
        });
        let old = self.host.spaces.write().unwrap().insert(id, space.clone());
        if let Some(old) = old {
            old.stop();
        }
        self.host.members_changed(&space);
    }

    /// 停止同步一个空间:断开它的连接、停掉拨号。本机的文档不动。
    pub fn remove_space(&self, id: &SpaceId) {
        let removed = self.host.spaces.write().unwrap().remove(id);
        if let Some(space) = removed {
            space.stop();
        }
        self.host.invites.revoke_space(id);
    }

    pub fn spaces(&self) -> Vec<SpaceId> {
        self.host.spaces.read().unwrap().keys().copied().collect()
    }

    /// 本机当前可被拨到的地址。刚启动时直连地址要等一小会儿才齐。
    pub async fn addr(&self) -> EndpointAddr {
        let mut watcher = self.host.endpoint.watch_addr();
        let ready = async {
            loop {
                let addr = watcher.get();
                if addr.ip_addrs().next().is_some() || addr.relay_urls().next().is_some() {
                    return addr;
                }
                if watcher.updated().await.is_err() {
                    return watcher.get();
                }
            }
        };
        match tokio::time::timeout(Duration::from_secs(3), ready).await {
            Ok(addr) => addr,
            Err(_) => self.host.endpoint.addr(),
        }
    }

    /// 告诉引擎一台设备可能在哪。中继与局域网发现之外的第三个来源。
    pub fn add_address_hint(&self, addr: EndpointAddr) {
        self.host.known.add_endpoint_info(addr);
        self.host.redial.notify_waiters();
    }

    /// 本机改动了一个空间里的文档。立即返回;通知在各连接的写循环里合并发出。
    pub fn notify_changed(&self, space: &SpaceId, doc: &DocId) {
        if let Some(space) = self.host.space(space) {
            space.fan_out(doc, None);
        }
    }

    /// 请这个空间里连着的设备把完整摘要再发一次。本机刚能收下之前婉拒的文档时用。
    pub fn refresh(&self, space: &SpaceId) {
        if let Some(space) = self.host.space(space) {
            for link in space.links.lock().unwrap().values() {
                let _ = link.control.send(Outbound::RequestSummary);
            }
        }
    }

    /// 一个空间的名单变了(同步来的、本机移除了设备)。按新名单增减拨号与连接。
    pub fn members_changed(&self, space: &SpaceId) {
        if let Some(space) = self.host.space(space) {
            self.host.members_changed(&space);
        }
    }

    /// 网络变了(换 Wi-Fi、从睡眠醒来)。让 iroh 重新探路,并立刻重拨。
    pub async fn network_changed(&self) {
        self.host.endpoint.network_change().await;
        self.host.redial.notify_waiters();
    }

    /// 为一个空间生成一张配对码,在 [`SyncConfig::invite_ttl`] 内有效、只能用一次。
    /// `label`(给人看,比如主题名)与 `context`(给应用用)在配对成功后交给
    /// 加入方,不写进配对码本身。
    pub async fn create_invite(
        &self,
        space: &SpaceId,
        purpose: InvitePurpose,
        label: &str,
        context: &str,
    ) -> Result<PairingTicket, SyncError> {
        if self.host.space(space).is_none() {
            return Err(SyncError::UnknownSpace);
        }
        let secret: [u8; 32] = rand::random();
        self.host.invites.issue(
            secret,
            *space,
            purpose,
            label.to_string(),
            context.to_string(),
            self.host.config.invite_ttl,
        );
        Ok(PairingTicket::new(self.addr().await, secret, purpose))
    }

    /// 作废一个空间所有还没用掉的配对码。
    pub fn revoke_invites(&self, space: &SpaceId) {
        self.host.invites.revoke_space(space);
    }

    /// 用对方给的配对码加入它的空间。成功后调用方建好本机的空间再 `add_space`。
    pub async fn join(&self, ticket: &PairingTicket) -> Result<Joined, PairError> {
        let host = &self.host;
        let inviter = ticket.inviter.id;
        host.known.add_endpoint_info(ticket.inviter.clone());
        let conn = tokio::time::timeout(
            CONNECT_TIMEOUT,
            host.endpoint.connect(ticket.inviter.clone(), PAIR_ALPN),
        )
        .await
        .map_err(|_| PairError::Unreachable("超时".into()))?
        .map_err(|e| PairError::Unreachable(e.to_string()))?;

        let request = PairMessage::Request {
            proof: ticket.proof_for(&self.device_id()),
            device_name: host.config.device_name.clone(),
            joiner: self.addr().await,
        };
        let exchange = async {
            let (mut send, mut recv) = conn.open_bi().await.map_err(interrupted)?;
            write_frame(&mut send, &request)
                .await
                .map_err(interrupted)?;
            send.finish().map_err(interrupted)?;
            read_frame::<_, PairMessage>(&mut recv)
                .await
                .map_err(interrupted)
        };
        let reply = tokio::time::timeout(HANDSHAKE_TIMEOUT, exchange)
            .await
            .map_err(|_| PairError::Interrupted("对方没有回应".into()))??;
        conn.close(CLOSE_BYE.into(), b"paired");

        match reply {
            PairMessage::Accepted {
                space,
                purpose,
                label,
                context,
                inviter_name,
            } => Ok(Joined {
                space,
                purpose,
                label: sanitize_device_name(&label),
                context: context.chars().take(256).collect(),
                inviter,
                inviter_name: sanitize_device_name(&inviter_name),
            }),
            PairMessage::Rejected { reason } => Err(PairError::Rejected(reason)),
            PairMessage::Request { .. } => Err(PairError::Interrupted("对方回了一个请求".into())),
        }
    }

    /// 一个空间里其他设备的同步状态。
    pub fn peers(&self, space: &SpaceId) -> Vec<PeerStatus> {
        let Some(space) = self.host.space(space) else {
            return Vec::new();
        };
        let me = self.device_id();
        // 先问名单再上锁:名单的实现在调用方,可能有它自己的锁。
        let mut devices: BTreeSet<EndpointId> = space.membership.members().into_iter().collect();
        let links = space.links.lock().unwrap();
        let synced = space.synced_at.lock().unwrap();
        devices.extend(links.keys().copied());
        devices.remove(&me);
        devices
            .into_iter()
            .map(|device| {
                let link = links.get(&device);
                PeerStatus {
                    device,
                    connected: link.is_some(),
                    via_relay: link.is_some_and(|l| is_relayed(&l.conn)),
                    last_synced_unix_ms: synced.get(&device).copied(),
                    in_flight: link.map_or(0, |l| l.in_flight.load(Ordering::Relaxed)),
                }
            })
            .collect()
    }

    /// 断开所有空间、关掉端点。之后这个引擎不再可用。
    pub async fn shutdown(&self) {
        self.host.stop();
        let _ = self.router.shutdown().await;
    }
}

impl Drop for SyncEngine {
    fn drop(&mut self) {
        // 拨号任务持有空间;不在这里停掉,引擎丢了它们还在后台转。
        self.host.stop();
    }
}

fn interrupted(e: impl std::fmt::Display) -> PairError {
    PairError::Interrupted(e.to_string())
}

fn is_relayed(conn: &Connection) -> bool {
    conn.paths()
        .iter()
        .find(|path| path.is_selected())
        .is_some_and(|path| path.is_relay())
}

fn now_unix_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_millis() as i64)
}

impl Host {
    fn stop(&self) {
        self.closing.store(true, Ordering::SeqCst);
        for (_, space) in self.spaces.write().unwrap().drain() {
            space.stop();
        }
        self.redial.notify_waiters();
    }

    fn me(&self) -> EndpointId {
        self.identity.id()
    }

    fn space(&self, id: &SpaceId) -> Option<Arc<Space>> {
        self.spaces.read().unwrap().get(id).cloned()
    }

    fn members_changed(self: &Arc<Self>, space: &Arc<Space>) {
        if self.closing.load(Ordering::SeqCst) || space.removed.load(Ordering::SeqCst) {
            return;
        }
        let me = self.me();
        let members: BTreeSet<EndpointId> = space
            .membership
            .members()
            .into_iter()
            .filter(|device| *device != me)
            .collect();

        // 不在名单上的连接当场断开。
        space.links.lock().unwrap().retain(|device, link| {
            let keep = members.contains(device);
            if !keep {
                link.conn.close(CLOSE_NOT_MEMBER.into(), b"not a member");
            }
            keep
        });

        // 设备都在同一个自建中继上,给每台记一条中继地址,跨网络就拨得到。
        if !self.config.relay_urls.is_empty() {
            for device in &members {
                let addr = EndpointAddr::new(*device).with_addrs(
                    self.config
                        .relay_urls
                        .iter()
                        .cloned()
                        .map(iroh::TransportAddr::Relay),
                );
                self.known.add_endpoint_info(addr);
            }
        }

        let mut dialers = space.dialers.lock().unwrap();
        dialers.retain(|device, task| {
            let keep = members.contains(device) && !task.is_finished();
            if !keep {
                task.abort();
            }
            keep
        });
        for device in members {
            dialers.entry(device).or_insert_with(|| {
                self.runtime
                    .spawn(dial_loop(self.clone(), space.clone(), device))
            });
        }
    }

    fn hello(&self, space: &SpaceId) -> SyncMessage {
        SyncMessage::Hello {
            space: *space,
            protocol: PROTOCOL_VERSION,
        }
    }
}

impl Space {
    fn stop(&self) {
        self.removed.store(true, Ordering::SeqCst);
        for (_, dialer) in self.dialers.lock().unwrap().drain() {
            dialer.abort();
        }
        for (_, link) in self.links.lock().unwrap().drain() {
            link.conn.close(CLOSE_BYE.into(), b"space closed");
        }
    }

    fn fan_out(&self, doc: &DocId, except: Option<EndpointId>) {
        for (device, link) in self.links.lock().unwrap().iter() {
            if Some(*device) == except {
                continue;
            }
            link.dirty.lock().unwrap().insert(doc.clone());
            link.dirty_signal.notify_one();
        }
    }

    fn link_to(&self, device: &EndpointId) -> Option<Arc<Link>> {
        self.links.lock().unwrap().get(device).cloned()
    }

    /// 在阻塞线程池里调存储。存储自己出了 panic 算这条连接失败,不带垮引擎。
    async fn with_store<R, F>(&self, f: F) -> Option<R>
    where
        R: Send + 'static,
        F: FnOnce(&dyn DocumentStore) -> R + Send + 'static,
    {
        let store = self.store.clone();
        match tokio::task::spawn_blocking(move || f(store.as_ref())).await {
            Ok(value) => Some(value),
            Err(error) => {
                tracing::error!(%error, "同步存储调用失败");
                None
            }
        }
    }
}

async fn dial_loop(host: Arc<Host>, space: Arc<Space>, device: EndpointId) {
    let dials_first = host.me() < device;
    let mut backoff = REDIAL_MIN;
    loop {
        if host.closing.load(Ordering::SeqCst)
            || space.removed.load(Ordering::SeqCst)
            || !space.membership.is_member(&device)
        {
            return;
        }
        if let Some(link) = space.link_to(&device) {
            link.conn.closed().await;
            backoff = REDIAL_MIN;
            continue;
        }
        if !dials_first {
            tokio::select! {
                _ = tokio::time::sleep(HIGHER_SIDE_GRACE) => {}
                _ = host.redial.notified() => {}
            }
            if space.link_to(&device).is_some() {
                continue;
            }
        }
        // 先登记再拨:拨号期间来的「重拨」也不会漏掉。
        let redial = host.redial.notified();
        match tokio::time::timeout(CONNECT_TIMEOUT, host.endpoint.connect(device, SYNC_ALPN)).await
        {
            Ok(Ok(conn)) => {
                backoff = REDIAL_MIN;
                if let Err(error) = run_dialed(&host, &space, conn).await {
                    tracing::debug!(device = %device.fmt_short(), %error, "同步连接结束");
                }
                continue;
            }
            Ok(Err(error)) => {
                tracing::debug!(device = %device.fmt_short(), %error, "拨不通");
            }
            Err(_) => tracing::debug!(device = %device.fmt_short(), "拨号超时"),
        }
        tokio::select! {
            _ = tokio::time::sleep(backoff) => {}
            _ = redial => { backoff = REDIAL_MIN; continue; }
        }
        backoff = (backoff * 2).min(REDIAL_MAX);
    }
}

async fn run_dialed(
    host: &Arc<Host>,
    space: &Arc<Space>,
    conn: Connection,
) -> Result<(), WireError> {
    let (mut send, mut recv) = conn.open_bi().await.map_err(|e| WireError::Io(e.into()))?;
    write_frame(&mut send, &host.hello(&space.id)).await?;
    let theirs = tokio::time::timeout(HANDSHAKE_TIMEOUT, read_frame::<_, SyncMessage>(&mut recv))
        .await
        .map_err(|_| WireError::Io(std::io::ErrorKind::TimedOut.into()))??;
    let accepted = matches!(
        theirs,
        SyncMessage::Hello { space: id, protocol } if id == space.id && protocol == PROTOCOL_VERSION
    );
    if !accepted {
        conn.close(CLOSE_UNKNOWN_SPACE.into(), b"wrong space");
        return Ok(());
    }
    run_link(host, space, conn, true, send, recv).await
}

#[derive(Clone)]
struct SyncAcceptor(Arc<Host>);

impl std::fmt::Debug for SyncAcceptor {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("SyncAcceptor")
    }
}

impl ProtocolHandler for SyncAcceptor {
    async fn accept(&self, conn: Connection) -> Result<(), AcceptError> {
        let host = &self.0;
        let remote = conn.remote_id();
        let handshake = async {
            let (send, mut recv) = conn.accept_bi().await?;
            let theirs = read_frame::<_, SyncMessage>(&mut recv)
                .await
                .map_err(AcceptError::from_err)?;
            Ok::<_, AcceptError>((send, recv, theirs))
        };
        let Ok(Ok((mut send, recv, theirs))) =
            tokio::time::timeout(HANDSHAKE_TIMEOUT, handshake).await
        else {
            conn.close(CLOSE_BYE.into(), b"no hello");
            return Ok(());
        };
        let SyncMessage::Hello {
            space: space_id,
            protocol: PROTOCOL_VERSION,
        } = theirs
        else {
            conn.close(CLOSE_UNKNOWN_SPACE.into(), b"bad hello");
            return Ok(());
        };
        // 本机不在这个空间里,或者对方不在这个空间的名单上:一律不谈,也不说是哪种。
        // QUIC 握手已经证明了对方是谁。
        let Some(space) = host
            .space(&space_id)
            .filter(|space| space.membership.is_member(&remote))
        else {
            conn.close(CLOSE_NOT_MEMBER.into(), b"not a member");
            return Ok(());
        };
        write_frame(&mut send, &host.hello(&space.id))
            .await
            .map_err(AcceptError::from_err)?;
        if let Err(error) = run_link(host, &space, conn, false, send, recv).await {
            tracing::debug!(%error, "同步连接结束");
        }
        Ok(())
    }
}

#[derive(Clone)]
struct PairAcceptor(Arc<Host>);

impl std::fmt::Debug for PairAcceptor {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("PairAcceptor")
    }
}

impl ProtocolHandler for PairAcceptor {
    async fn accept(&self, conn: Connection) -> Result<(), AcceptError> {
        let host = &self.0;
        let joiner = conn.remote_id();
        let request = async {
            let (send, mut recv) = conn.accept_bi().await?;
            let message = read_frame::<_, PairMessage>(&mut recv)
                .await
                .map_err(AcceptError::from_err)?;
            Ok::<_, AcceptError>((send, message))
        };
        let Ok(Ok((mut send, message))) = tokio::time::timeout(HANDSHAKE_TIMEOUT, request).await
        else {
            return Ok(());
        };
        let PairMessage::Request {
            proof,
            device_name,
            joiner: joiner_addr,
        } = message
        else {
            return Ok(());
        };

        let redeemed = if joiner_addr.id == joiner {
            host.invites.redeem(&proof, &joiner, &host.me())
        } else {
            None
        };
        let mut admitted_into = None;
        let reply = match redeemed {
            None => PairMessage::Rejected {
                reason: PairRejection::InvalidOrExpired,
            },
            Some(invite) => match host.space(&invite.space) {
                None => PairMessage::Rejected {
                    reason: PairRejection::Unavailable,
                },
                Some(space) => {
                    match space
                        .membership
                        .admit(joiner, &sanitize_device_name(&device_name))
                    {
                        Ok(()) => {
                            host.known.add_endpoint_info(joiner_addr);
                            admitted_into = Some(space);
                            PairMessage::Accepted {
                                space: invite.space,
                                purpose: invite.purpose,
                                label: invite.label,
                                context: invite.context,
                                inviter_name: host.config.device_name.clone(),
                            }
                        }
                        Err(error) => {
                            tracing::warn!(%error, "配对码有效,但没能把新设备记进名单");
                            PairMessage::Rejected {
                                reason: PairRejection::Unavailable,
                            }
                        }
                    }
                }
            },
        };
        let _ = write_frame(&mut send, &reply).await;
        let _ = send.finish();
        // handler 一返回 Router 就关连接;等对方读完、自己关,回复才不会丢在路上。
        let _ = tokio::time::timeout(HANDSHAKE_TIMEOUT, conn.closed()).await;
        if let Some(space) = admitted_into {
            host.members_changed(&space);
        }
        Ok(())
    }
}

/// 一条已握手的同步连接。
struct Link {
    conn: Connection,
    dialed_by_me: bool,
    established: tokio::time::Instant,
    /// 本机改过、还没通知对方的文档。写循环取走后发一份局部摘要。
    dirty: Mutex<BTreeSet<DocId>>,
    dirty_signal: Notify,
    in_flight: AtomicUsize,
    /// 写循环的队列,读循环和引擎都往里放。
    control: mpsc::UnboundedSender<Outbound>,
}

enum Outbound {
    Summary,
    RequestSummary,
    Want(DocId),
    Serve { doc: DocId, from: Vec<u8> },
}

/// 把一条新连接登记为和这台设备在这个空间里的那条连接。返回假表示新连接落选、
/// 应当关掉。
///
/// - 没有旧连接:登记。
/// - 旧连接是刚建立的(不到 [`RACE_WINDOW`]):两边同时拨了。留 id 小的一方拨出的
///   那条 —— 两边看到的是同一对连接,按同一条规则,留下的是同一条。
/// - 旧连接已经有一阵了:新的换掉旧的。对方肯拨过来,说明它那头已经没有可用的
///   连接,旧的这条多半是对方重启或断网后还没超时的残留。
fn register(me: EndpointId, space: &Space, device: EndpointId, link: &Arc<Link>) -> bool {
    let mut links = space.links.lock().unwrap();
    if let Some(old) = links.get(&device) {
        let racing = old.established.elapsed() < RACE_WINDOW;
        let dialed_by_lower = link.dialed_by_me == (me < device);
        if racing && !dialed_by_lower {
            return false;
        }
        old.conn.close(CLOSE_REPLACED.into(), b"replaced");
    }
    links.insert(device, link.clone());
    true
}

async fn run_link(
    host: &Arc<Host>,
    space: &Arc<Space>,
    conn: Connection,
    dialed_by_me: bool,
    send: SendStream,
    recv: RecvStream,
) -> Result<(), WireError> {
    let device = conn.remote_id();
    let (outbound, queue) = mpsc::unbounded_channel();
    let link = Arc::new(Link {
        conn: conn.clone(),
        dialed_by_me,
        established: tokio::time::Instant::now(),
        dirty: Mutex::default(),
        dirty_signal: Notify::new(),
        in_flight: AtomicUsize::new(0),
        control: outbound.clone(),
    });
    if host.closing.load(Ordering::SeqCst)
        || space.removed.load(Ordering::SeqCst)
        || !register(host.me(), space, device, &link)
    {
        conn.close(CLOSE_REPLACED.into(), b"duplicate");
        return Ok(());
    }
    tracing::debug!(device = %device.fmt_short(), "同步连接建立");

    let _ = outbound.send(Outbound::Summary);
    let writer = tokio::spawn(write_loop(
        host.config.anti_entropy,
        space.clone(),
        link.clone(),
        send,
        queue,
    ));
    let result = tokio::select! {
        result = read_loop(space, &link, device, recv, outbound) => result,
        _ = conn.closed() => Ok(()),
    };
    writer.abort();
    {
        let mut links = space.links.lock().unwrap();
        if links
            .get(&device)
            .is_some_and(|current| Arc::ptr_eq(current, &link))
        {
            links.remove(&device);
        }
    }
    conn.close(CLOSE_BYE.into(), b"bye");
    result
}

async fn read_loop(
    space: &Arc<Space>,
    link: &Link,
    device: EndpointId,
    mut recv: RecvStream,
    outbound: mpsc::UnboundedSender<Outbound>,
) -> Result<(), WireError> {
    // 发出了 Want、还没收到末块的文档。值为真表示等待期间对方又宣告过新版本,
    // 这一轮的应答可能已经过时,收完要再要一次。
    let mut pending: HashMap<DocId, bool> = HashMap::new();
    let mut assembling: Option<(DocId, Vec<u8>)> = None;

    loop {
        let message: SyncMessage = read_frame(&mut recv).await?;
        match message {
            SyncMessage::Hello { .. } => {
                return Err(WireError::Io(std::io::Error::other("重复的 Hello")));
            }
            SyncMessage::Summary { docs, complete } => {
                let wanted = space
                    .with_store(move |store| {
                        docs.into_iter()
                            .filter(|(doc, digest)| match store.digest(doc) {
                                Some(mine) => mine != *digest,
                                None => store.accepts(doc),
                            })
                            .map(|(doc, _)| doc)
                            .collect::<Vec<_>>()
                    })
                    .await
                    .unwrap_or_default();
                for doc in wanted {
                    if let Some(stale) = pending.get_mut(&doc) {
                        *stale = true;
                    } else {
                        pending.insert(doc.clone(), false);
                        let _ = outbound.send(Outbound::Want(doc));
                    }
                }
                if complete && pending.is_empty() {
                    space
                        .synced_at
                        .lock()
                        .unwrap()
                        .insert(device, now_unix_ms());
                }
            }
            SyncMessage::Want { doc, version } => {
                let _ = outbound.send(Outbound::Serve { doc, from: version });
            }
            SyncMessage::RequestSummary => {
                let _ = outbound.send(Outbound::Summary);
            }
            SyncMessage::Update { doc, bytes, last } => {
                let buffer = match &mut assembling {
                    Some((current, buffer)) if *current == doc => {
                        buffer.extend_from_slice(&bytes);
                        buffer
                    }
                    Some(_) => {
                        return Err(WireError::Io(std::io::Error::other("两份差量交错")));
                    }
                    None => &mut assembling.insert((doc.clone(), bytes)).1,
                };
                if buffer.len() > MAX_UPDATE_BYTES {
                    return Err(WireError::TooLarge {
                        actual: buffer.len(),
                    });
                }
                if !last {
                    continue;
                }
                let (doc, update) = assembling.take().expect("刚放进去");
                // 没要过的不收。
                let Some(stale) = pending.remove(&doc) else {
                    continue;
                };
                if !update.is_empty() {
                    let target = doc.clone();
                    let applied = space
                        .with_store(move |store| store.apply(&target, &update))
                        .await;
                    match applied {
                        Some(Ok(true)) => space.fan_out(&doc, Some(device)),
                        Some(Ok(false)) => {}
                        Some(Err(error)) => {
                            tracing::warn!(doc = %doc, %error, "对方的差量合不进来");
                        }
                        None => {}
                    }
                }
                if stale {
                    pending.insert(doc.clone(), false);
                    let _ = outbound.send(Outbound::Want(doc));
                }
                if pending.is_empty() {
                    space
                        .synced_at
                        .lock()
                        .unwrap()
                        .insert(device, now_unix_ms());
                }
            }
        }
        link.in_flight.store(pending.len(), Ordering::Relaxed);
    }
}

async fn write_loop(
    anti_entropy: Duration,
    space: Arc<Space>,
    link: Arc<Link>,
    mut send: SendStream,
    mut queue: mpsc::UnboundedReceiver<Outbound>,
) {
    let mut anti_entropy = tokio::time::interval(anti_entropy);
    anti_entropy.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    // 第一次完整摘要已经在队列里了。
    anti_entropy.reset();

    loop {
        let item = tokio::select! {
            item = queue.recv() => match item {
                Some(item) => item,
                None => return,
            },
            _ = link.dirty_signal.notified() => {
                let docs: Vec<DocId> = std::mem::take(&mut *link.dirty.lock().unwrap())
                    .into_iter()
                    .collect();
                let digests = space
                    .with_store(move |store| {
                        docs.into_iter()
                            .filter_map(|doc| store.digest(&doc).map(|digest| (doc, digest)))
                            .collect::<Vec<_>>()
                    })
                    .await
                    .unwrap_or_default();
                if digests.is_empty() {
                    continue;
                }
                let message = SyncMessage::Summary { docs: digests, complete: false };
                if write_frame(&mut send, &message).await.is_err() {
                    return;
                }
                continue;
            }
            _ = anti_entropy.tick() => Outbound::Summary,
        };

        let written = match item {
            Outbound::Summary => {
                let docs = space
                    .with_store(|store| store.summary())
                    .await
                    .unwrap_or_default();
                write_frame(
                    &mut send,
                    &SyncMessage::Summary {
                        docs,
                        complete: true,
                    },
                )
                .await
            }
            Outbound::RequestSummary => write_frame(&mut send, &SyncMessage::RequestSummary).await,
            Outbound::Want(doc) => {
                let target = doc.clone();
                let version = space
                    .with_store(move |store| store.version(&target))
                    .await
                    .flatten()
                    .unwrap_or_default();
                write_frame(&mut send, &SyncMessage::Want { doc, version }).await
            }
            Outbound::Serve { doc, from } => {
                let target = doc.clone();
                let update = space
                    .with_store(move |store| store.updates_since(&target, &from))
                    .await
                    .flatten()
                    .unwrap_or_default();
                write_update(&mut send, doc, update).await
            }
        };
        if written.is_err() {
            return;
        }
    }
}

/// 一份差量切块连续写出。空差量也写一个末块:每个 Want 都要有应答。
async fn write_update(send: &mut SendStream, doc: DocId, update: Vec<u8>) -> Result<(), WireError> {
    if update.is_empty() {
        return write_frame(
            send,
            &SyncMessage::Update {
                doc,
                bytes: Vec::new(),
                last: true,
            },
        )
        .await;
    }
    let chunks = update.chunks(UPDATE_CHUNK_BYTES).count();
    for (index, chunk) in update.chunks(UPDATE_CHUNK_BYTES).enumerate() {
        write_frame(
            send,
            &SyncMessage::Update {
                doc: doc.clone(),
                bytes: chunk.to_vec(),
                last: index + 1 == chunks,
            },
        )
        .await?;
    }
    Ok(())
}
