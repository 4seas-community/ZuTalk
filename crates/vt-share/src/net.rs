//! iroh 传输层:Endpoint、Router、字幕广播与接收。
//!
//! 见 `docs/architecture/share-p2p.md` 第 2、3 节。

use std::sync::Arc;

use iroh::endpoint::{presets, Connection};
use iroh::protocol::{AcceptError, ProtocolHandler, Router};
use iroh::{Endpoint, EndpointAddr, RelayMode, RelayUrl};
use tokio::sync::{broadcast, Mutex};

use crate::caption::CaptionFrame;
use crate::identity::ShareIdentity;
use crate::permission::RoomRoster;
use crate::room::ScopeId;
use crate::room_control::{open as open_control, seal as seal_control, RoomControl, RoomPresence};
use crate::sharecode::ShareCode;
use crate::wire::{read_message, write_message};

/// 实时字幕通道。每帧一条 uni-stream。
pub const LIVE_CAPTION_ALPN: &[u8] = b"zulangue/live-caption/1";
/// 文档协同通道。成对直连,承载签名信封。
pub const DOC_SYNC_ALPN: &[u8] = b"zulangue/doc-sync/1";

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
}

impl ShareEndpoint {
    /// 绑定端点并启动 accept 循环。
    pub async fn bind(
        identity: &ShareIdentity,
        config: ShareEndpointConfig,
    ) -> Result<Self, NetError> {
        let (captions, _) = broadcast::channel(CAPTION_FANOUT_DEPTH);

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

        if config.enable_local_discovery {
            builder =
                builder.address_lookup(iroh_mdns_address_lookup::MdnsAddressLookup::builder());
        }

        let endpoint = builder
            .bind()
            .await
            .map_err(|e| NetError::Bind(e.to_string()))?;

        let gossip = iroh_gossip::net::Gossip::builder().spawn(endpoint.clone());
        let router = Router::builder(endpoint.clone())
            .accept(iroh_gossip::ALPN, gossip.clone())
            .accept(
                LIVE_CAPTION_ALPN,
                CaptionAcceptor {
                    captions: captions.clone(),
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
        // send 只在没有订阅者时报错,那是正常状态,不是故障。
        let _ = self.captions.send(Arc::new(frame));
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

        let presence = Arc::new(Mutex::new(RoomPresence::new(
            scope.clone(),
            host,
            me,
            code.policy,
        )));

        // Hello 不能只在加入时发一次。
        //
        // `subscribe` 立即返回,此刻通常还没有任何邻居,那一发就石沉大海 —— 而
        // 没有人会替你重发。所以真正的announce时机是「有邻居上线了」,首次加入与
        // 断线重连因此走同一条路径。
        let hello = seal_control(&RoomControl::Hello, &scope, self.identity.secret())
            .map_err(|e| NetError::Stream(e.to_string()))?;
        // 已经有邻居时也发一次,省掉一个来回。
        let _ = sender.broadcast(hello.clone().into()).await;

        let task = {
            let presence = presence.clone();
            let secret = self.identity.secret().clone();
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

        Ok(RoomHandle { presence, task })
    }

    pub async fn shutdown(self) {
        let _ = self.router.shutdown().await;
    }
}

/// 一个已加入的房间。丢弃它就退出该房间的控制面。
#[derive(Debug)]
pub struct RoomHandle {
    presence: Arc<Mutex<RoomPresence>>,
    task: tokio::task::JoinHandle<()>,
}

impl RoomHandle {
    /// 当前名册的快照。
    pub async fn roster(&self) -> RoomRoster {
        self.presence.lock().await.roster().clone()
    }

    /// 当前在场人数。
    pub async fn member_count(&self) -> usize {
        self.presence.lock().await.roster().members().count()
    }
}

impl Drop for RoomHandle {
    fn drop(&mut self) {
        self.task.abort();
    }
}

/// 收到的字幕帧汇集处。
#[derive(Debug, Clone, Default)]
pub struct CaptionInbox {
    frames: Arc<Mutex<Vec<CaptionFrame>>>,
}

impl CaptionInbox {
    /// 取走已收到的帧。
    pub async fn drain(&self) -> Vec<CaptionFrame> {
        std::mem::take(&mut *self.frames.lock().await)
    }

    async fn push(&self, frame: CaptionFrame) {
        self.frames.lock().await.push(frame);
    }
}

/// 字幕通道的服务端。
///
/// 流向是**观看端拨号、主持端推送**:观看端连上来后,这个 handler 订阅本机的广播
/// 通道,把每一帧当作一条独立的 uni-stream 写回去。反过来做(两端都 accept)会
/// 双向死锁。
#[derive(Debug, Clone)]
struct CaptionAcceptor {
    captions: broadcast::Sender<Arc<CaptionFrame>>,
}

impl ProtocolHandler for CaptionAcceptor {
    async fn accept(&self, connection: Connection) -> Result<(), AcceptError> {
        let mut rx = self.captions.subscribe();
        loop {
            let frame = match rx.recv().await {
                Ok(frame) => frame,
                // 落后太多:跳到最新,不补发。旧帧对 replace-in-full 没有价值。
                Err(broadcast::error::RecvError::Lagged(_)) => continue,
                Err(broadcast::error::RecvError::Closed) => break,
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
pub async fn receive_captions(
    endpoint: &ShareEndpoint,
    host: EndpointAddr,
    scope: ScopeId,
    inbox: CaptionInbox,
) -> Result<(), NetError> {
    let conn = endpoint
        .endpoint
        .connect(host, LIVE_CAPTION_ALPN)
        .await
        .map_err(|e| NetError::Connect(e.to_string()))?;

    while let Ok(mut stream) = conn.accept_uni().await {
        match read_message::<_, CaptionFrame>(&mut stream).await {
            Ok(frame) if frame.scope == scope => inbox.push(frame).await,
            Ok(_) => tracing::debug!("丢弃一帧属于其他共享范围的字幕"),
            Err(error) => tracing::debug!(%error, "丢弃一帧无法解码的字幕"),
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// ALPN 是协议身份的一部分,改动即破坏兼容。这条测试把它钉住。
    #[test]
    fn alpns_are_stable() {
        assert_eq!(LIVE_CAPTION_ALPN, b"zulangue/live-caption/1");
        assert_eq!(DOC_SYNC_ALPN, b"zulangue/doc-sync/1");
        assert_ne!(LIVE_CAPTION_ALPN, DOC_SYNC_ALPN);
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
        ep.broadcast_caption(CaptionFrame {
            scope: ScopeId::Session {
                session_id: "s".into(),
            },
            preview_revision: 1,
            lines: vec![],
        });
        ep.shutdown().await;
    }

    #[tokio::test]
    async fn inbox_drains_once() {
        let inbox = CaptionInbox::default();
        inbox
            .push(CaptionFrame {
                scope: ScopeId::Session {
                    session_id: "s".into(),
                },
                preview_revision: 1,
                lines: vec![],
            })
            .await;
        assert_eq!(inbox.drain().await.len(), 1);
        assert!(inbox.drain().await.is_empty());
    }
}
