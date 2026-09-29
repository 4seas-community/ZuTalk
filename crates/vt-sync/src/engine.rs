//! 同步引擎:端点、连接管理、对账。
//!
//! 每对设备一条连接。两边都会拨,但 id 小的一方先拨,大的一方等几秒没见到连接才拨
//! —— 对方可能正在退避,或者还以为一条已经断掉的旧连接活着。两边同时拨出的两条
//! 连接按一条双方算得出同样结果的规则留一条,见 [`register`]。
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
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use iroh::address_lookup::MemoryLookup;
use iroh::endpoint::{presets, Connection, RecvStream, SendStream};
use iroh::protocol::{AcceptError, ProtocolHandler, Router};
use iroh::{Endpoint, EndpointAddr, EndpointId, RelayMode, RelayUrl, Watcher};
use tokio::sync::{mpsc, Notify};

use crate::identity::DeviceIdentity;
use crate::membership::Membership;
use crate::pairing::{
    sanitize_device_name, InviteBook, PairMessage, PairRejection, PairingTicket, INVITE_TTL,
    PAIR_ALPN,
};
use crate::protocol::{
    GroupId, SyncMessage, MAX_UPDATE_BYTES, PROTOCOL_VERSION, SYNC_ALPN, UPDATE_CHUNK_BYTES,
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
const CLOSE_WRONG_GROUP: u32 = 2;
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
}

#[derive(Debug, thiserror::Error)]
pub enum PairError {
    #[error("连不上对方: {0}")]
    Unreachable(String),
    #[error(transparent)]
    Rejected(#[from] PairRejection),
    #[error("配对中断: {0}")]
    Interrupted(String),
    #[error("加入设备组失败: {0}")]
    Membership(String),
}

/// 配对成功后加入方看到的结果。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Joined {
    pub group: GroupId,
    pub inviter: EndpointId,
    pub inviter_name: String,
}

/// 一台组内设备此刻的同步状态。
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
    shared: Arc<Shared>,
    router: Router,
}

impl std::fmt::Debug for SyncEngine {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SyncEngine")
            .field("device", &self.shared.identity)
            .finish_non_exhaustive()
    }
}

struct Shared {
    endpoint: Endpoint,
    identity: DeviceIdentity,
    config: SyncConfig,
    store: Arc<dyn DocumentStore>,
    membership: Arc<dyn Membership>,
    known: MemoryLookup,
    links: Mutex<HashMap<EndpointId, Arc<Link>>>,
    synced_at: Mutex<HashMap<EndpointId, i64>>,
    dialers: Mutex<HashMap<EndpointId, tokio::task::JoinHandle<()>>>,
    invites: InviteBook,
    /// 叫醒所有在退避中的拨号循环(网络变了、刚拿到新地址)。
    redial: Notify,
    closing: AtomicBool,
}

impl SyncEngine {
    pub async fn start(
        identity: DeviceIdentity,
        config: SyncConfig,
        store: Arc<dyn DocumentStore>,
        membership: Arc<dyn Membership>,
    ) -> Result<Self, SyncError> {
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

        let shared = Arc::new(Shared {
            endpoint: endpoint.clone(),
            identity,
            config,
            store,
            membership,
            known,
            links: Mutex::default(),
            synced_at: Mutex::default(),
            dialers: Mutex::default(),
            invites: InviteBook::default(),
            redial: Notify::new(),
            closing: AtomicBool::new(false),
        });
        let router = Router::builder(endpoint)
            .accept(SYNC_ALPN, SyncAcceptor(shared.clone()))
            .accept(PAIR_ALPN, PairAcceptor(shared.clone()))
            .spawn();
        shared.members_changed();
        Ok(Self { shared, router })
    }

    pub fn device_id(&self) -> EndpointId {
        self.shared.identity.id()
    }

    /// 本机当前可被拨到的地址。刚启动时直连地址要等一小会儿才齐。
    pub async fn addr(&self) -> EndpointAddr {
        let mut watcher = self.shared.endpoint.watch_addr();
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
            Err(_) => self.shared.endpoint.addr(),
        }
    }

    /// 告诉引擎一台设备可能在哪。中继与局域网发现之外的第三个来源。
    pub fn add_address_hint(&self, addr: EndpointAddr) {
        self.shared.known.add_endpoint_info(addr);
        self.shared.redial.notify_waiters();
    }

    /// 本机改动了一个文档。立即返回;通知在各连接的写循环里合并发出。
    pub fn notify_changed(&self, doc: &DocId) {
        self.shared.fan_out(doc, None);
    }

    /// 名单变了(同步来的、本机移除了设备)。按新名单增减拨号与连接。
    pub fn members_changed(&self) {
        self.shared.members_changed();
    }

    /// 网络变了(换 Wi-Fi、从睡眠醒来)。让 iroh 重新探路,并立刻重拨。
    pub async fn network_changed(&self) {
        self.shared.endpoint.network_change().await;
        self.shared.redial.notify_waiters();
    }

    /// 生成一张配对码,在 [`SyncConfig::invite_ttl`] 内有效、只能用一次。
    pub async fn create_invite(&self) -> PairingTicket {
        let secret: [u8; 32] = rand::random();
        self.shared
            .invites
            .issue(secret, self.shared.config.invite_ttl);
        PairingTicket::new(self.addr().await, secret)
    }

    /// 用对方给的配对码加入它的设备组。
    pub async fn join(&self, ticket: &PairingTicket) -> Result<Joined, PairError> {
        let shared = &self.shared;
        let inviter = ticket.inviter.id;
        shared.known.add_endpoint_info(ticket.inviter.clone());
        let conn = tokio::time::timeout(
            CONNECT_TIMEOUT,
            shared.endpoint.connect(ticket.inviter.clone(), PAIR_ALPN),
        )
        .await
        .map_err(|_| PairError::Unreachable("超时".into()))?
        .map_err(|e| PairError::Unreachable(e.to_string()))?;

        let request = PairMessage::Request {
            proof: ticket.proof_for(&self.device_id()),
            device_name: shared.config.device_name.clone(),
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
                group,
                inviter_name,
            } => {
                let inviter_name = sanitize_device_name(&inviter_name);
                shared
                    .membership
                    .join(group, inviter, &inviter_name)
                    .map_err(PairError::Membership)?;
                shared.members_changed();
                Ok(Joined {
                    group,
                    inviter,
                    inviter_name,
                })
            }
            PairMessage::Rejected { reason } => Err(PairError::Rejected(reason)),
            PairMessage::Request { .. } => Err(PairError::Interrupted("对方回了一个请求".into())),
        }
    }

    /// 组内其他设备的同步状态。
    pub fn peers(&self) -> Vec<PeerStatus> {
        let me = self.device_id();
        // 先问名单再上锁:名单的实现在调用方,可能有它自己的锁。
        let mut devices: BTreeSet<EndpointId> =
            self.shared.membership.members().into_iter().collect();
        let links = self.shared.links.lock().unwrap();
        let synced = self.shared.synced_at.lock().unwrap();
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

    pub async fn shutdown(self) {
        self.shared.stop();
        let _ = self.router.shutdown().await;
    }
}

impl Drop for SyncEngine {
    fn drop(&mut self) {
        // 拨号任务持有 Shared;不在这里停掉,引擎丢了它们还在后台转。
        self.shared.stop();
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

impl Shared {
    fn stop(&self) {
        self.closing.store(true, Ordering::SeqCst);
        for (_, dialer) in self.dialers.lock().unwrap().drain() {
            dialer.abort();
        }
        for (_, link) in self.links.lock().unwrap().drain() {
            link.conn.close(CLOSE_BYE.into(), b"shutdown");
        }
        self.redial.notify_waiters();
    }

    fn me(&self) -> EndpointId {
        self.identity.id()
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

    fn members_changed(self: &Arc<Self>) {
        if self.closing.load(Ordering::SeqCst) {
            return;
        }
        let me = self.me();
        let members: BTreeSet<EndpointId> = self
            .membership
            .members()
            .into_iter()
            .filter(|device| *device != me)
            .collect();

        // 不在名单上的连接当场断开。
        self.links.lock().unwrap().retain(|device, link| {
            let keep = members.contains(device);
            if !keep {
                link.conn.close(CLOSE_NOT_MEMBER.into(), b"not a member");
            }
            keep
        });

        // 组内设备都在同一个自建中继上,给每台记一条中继地址,跨网络就拨得到。
        for device in &members {
            if !self.config.relay_urls.is_empty() {
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

        let mut dialers = self.dialers.lock().unwrap();
        dialers.retain(|device, task| {
            let keep = members.contains(device) && !task.is_finished();
            if !keep {
                task.abort();
            }
            keep
        });
        for device in members {
            dialers
                .entry(device)
                .or_insert_with(|| tokio::spawn(dial_loop(self.clone(), device)));
        }
    }

    fn link_to(&self, device: &EndpointId) -> Option<Arc<Link>> {
        self.links.lock().unwrap().get(device).cloned()
    }

    fn hello(&self) -> Option<SyncMessage> {
        Some(SyncMessage::Hello {
            group: self.membership.group()?,
            protocol: PROTOCOL_VERSION,
        })
    }

    fn accepts_hello(&self, message: &SyncMessage) -> bool {
        matches!(
            message,
            SyncMessage::Hello { group, protocol }
                if *protocol == PROTOCOL_VERSION && Some(*group) == self.membership.group()
        )
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

async fn dial_loop(shared: Arc<Shared>, device: EndpointId) {
    let dials_first = shared.me() < device;
    let mut backoff = REDIAL_MIN;
    loop {
        if shared.closing.load(Ordering::SeqCst) || !shared.membership.is_member(&device) {
            return;
        }
        if let Some(link) = shared.link_to(&device) {
            link.conn.closed().await;
            backoff = REDIAL_MIN;
            continue;
        }
        if !dials_first {
            tokio::select! {
                _ = tokio::time::sleep(HIGHER_SIDE_GRACE) => {}
                _ = shared.redial.notified() => {}
            }
            if shared.link_to(&device).is_some() {
                continue;
            }
        }
        // 先登记再拨:拨号期间来的「重拨」也不会漏掉。
        let redial = shared.redial.notified();
        match tokio::time::timeout(CONNECT_TIMEOUT, shared.endpoint.connect(device, SYNC_ALPN))
            .await
        {
            Ok(Ok(conn)) => {
                backoff = REDIAL_MIN;
                if let Err(error) = run_dialed(&shared, conn).await {
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

async fn run_dialed(shared: &Arc<Shared>, conn: Connection) -> Result<(), WireError> {
    let Some(hello) = shared.hello() else {
        conn.close(CLOSE_WRONG_GROUP.into(), b"no group");
        return Ok(());
    };
    let (mut send, mut recv) = conn.open_bi().await.map_err(|e| WireError::Io(e.into()))?;
    write_frame(&mut send, &hello).await?;
    let theirs = tokio::time::timeout(HANDSHAKE_TIMEOUT, read_frame::<_, SyncMessage>(&mut recv))
        .await
        .map_err(|_| WireError::Io(std::io::ErrorKind::TimedOut.into()))??;
    if !shared.accepts_hello(&theirs) {
        conn.close(CLOSE_WRONG_GROUP.into(), b"wrong group");
        return Ok(());
    }
    run_link(shared, conn, true, send, recv).await
}

#[derive(Clone)]
struct SyncAcceptor(Arc<Shared>);

impl std::fmt::Debug for SyncAcceptor {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("SyncAcceptor")
    }
}

impl ProtocolHandler for SyncAcceptor {
    async fn accept(&self, conn: Connection) -> Result<(), AcceptError> {
        let shared = &self.0;
        // QUIC 握手已经证明了对方是谁;不在名单上就不谈。
        if !shared.membership.is_member(&conn.remote_id()) {
            conn.close(CLOSE_NOT_MEMBER.into(), b"not a member");
            return Ok(());
        }
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
        let Some(hello) = shared.hello().filter(|_| shared.accepts_hello(&theirs)) else {
            conn.close(CLOSE_WRONG_GROUP.into(), b"wrong group");
            return Ok(());
        };
        write_frame(&mut send, &hello)
            .await
            .map_err(AcceptError::from_err)?;
        if let Err(error) = run_link(shared, conn, false, send, recv).await {
            tracing::debug!(%error, "同步连接结束");
        }
        Ok(())
    }
}

#[derive(Clone)]
struct PairAcceptor(Arc<Shared>);

impl std::fmt::Debug for PairAcceptor {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("PairAcceptor")
    }
}

impl ProtocolHandler for PairAcceptor {
    async fn accept(&self, conn: Connection) -> Result<(), AcceptError> {
        let shared = &self.0;
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

        let reply =
            if joiner_addr.id != joiner || !shared.invites.redeem(&proof, &joiner, &shared.me()) {
                PairMessage::Rejected {
                    reason: PairRejection::InvalidOrExpired,
                }
            } else {
                match shared
                    .membership
                    .admit(joiner, &sanitize_device_name(&device_name))
                {
                    Ok(group) => {
                        shared.known.add_endpoint_info(joiner_addr);
                        PairMessage::Accepted {
                            group,
                            inviter_name: shared.config.device_name.clone(),
                        }
                    }
                    Err(error) => {
                        tracing::warn!(%error, "配对码有效,但没能把新设备记进名单");
                        PairMessage::Rejected {
                            reason: PairRejection::Unavailable,
                        }
                    }
                }
            };
        let admitted = matches!(reply, PairMessage::Accepted { .. });
        let _ = write_frame(&mut send, &reply).await;
        let _ = send.finish();
        // handler 一返回 Router 就关连接;等对方读完、自己关,回复才不会丢在路上。
        let _ = tokio::time::timeout(HANDSHAKE_TIMEOUT, conn.closed()).await;
        if admitted {
            shared.members_changed();
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
}

enum Outbound {
    Summary,
    Want(DocId),
    Serve { doc: DocId, from: Vec<u8> },
}

/// 把一条新连接登记为和这台设备的那条连接。返回假表示新连接落选、应当关掉。
///
/// - 没有旧连接:登记。
/// - 旧连接是刚建立的(不到 [`RACE_WINDOW`]):两边同时拨了。留 id 小的一方拨出的
///   那条 —— 两边看到的是同一对连接,按同一条规则,留下的是同一条。
/// - 旧连接已经有一阵了:新的换掉旧的。对方肯拨过来,说明它那头已经没有可用的
///   连接,旧的这条多半是对方重启或断网后还没超时的残留。
fn register(shared: &Shared, device: EndpointId, link: &Arc<Link>) -> bool {
    let mut links = shared.links.lock().unwrap();
    if let Some(old) = links.get(&device) {
        let racing = old.established.elapsed() < RACE_WINDOW;
        let dialed_by_lower = link.dialed_by_me == (shared.me() < device);
        if racing && !dialed_by_lower {
            return false;
        }
        old.conn.close(CLOSE_REPLACED.into(), b"replaced");
    }
    links.insert(device, link.clone());
    true
}

async fn run_link(
    shared: &Arc<Shared>,
    conn: Connection,
    dialed_by_me: bool,
    send: SendStream,
    recv: RecvStream,
) -> Result<(), WireError> {
    let device = conn.remote_id();
    let link = Arc::new(Link {
        conn: conn.clone(),
        dialed_by_me,
        established: tokio::time::Instant::now(),
        dirty: Mutex::default(),
        dirty_signal: Notify::new(),
        in_flight: AtomicUsize::new(0),
    });
    if shared.closing.load(Ordering::SeqCst) || !register(shared, device, &link) {
        conn.close(CLOSE_REPLACED.into(), b"duplicate");
        return Ok(());
    }
    tracing::debug!(device = %device.fmt_short(), "同步连接建立");

    let (outbound, queue) = mpsc::unbounded_channel();
    let _ = outbound.send(Outbound::Summary);
    let writer = tokio::spawn(write_loop(shared.clone(), link.clone(), send, queue));
    let result = tokio::select! {
        result = read_loop(shared, &link, device, recv, outbound) => result,
        _ = conn.closed() => Ok(()),
    };
    writer.abort();
    {
        let mut links = shared.links.lock().unwrap();
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
    shared: &Arc<Shared>,
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
                let wanted = shared
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
                    shared
                        .synced_at
                        .lock()
                        .unwrap()
                        .insert(device, now_unix_ms());
                }
            }
            SyncMessage::Want { doc, version } => {
                let _ = outbound.send(Outbound::Serve { doc, from: version });
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
                    let applied = shared
                        .with_store(move |store| store.apply(&target, &update))
                        .await;
                    match applied {
                        Some(Ok(true)) => shared.fan_out(&doc, Some(device)),
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
                    shared
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
    shared: Arc<Shared>,
    link: Arc<Link>,
    mut send: SendStream,
    mut queue: mpsc::UnboundedReceiver<Outbound>,
) {
    let mut anti_entropy = tokio::time::interval(shared.config.anti_entropy);
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
                let digests = shared
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
                let docs = shared
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
            Outbound::Want(doc) => {
                let target = doc.clone();
                let version = shared
                    .with_store(move |store| store.version(&target))
                    .await
                    .flatten()
                    .unwrap_or_default();
                write_frame(&mut send, &SyncMessage::Want { doc, version }).await
            }
            Outbound::Serve { doc, from } => {
                let target = doc.clone();
                let update = shared
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
