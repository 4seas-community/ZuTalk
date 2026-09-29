//! 附近:同一个网络里的 ZuTalk 互相看见,直接递一份文字稿,直接看直播字幕。
//! 设计见 `docs/architecture/local-first-sync.md` §9。
//!
//! - **看见**:本机愿意被看见时(打开了「接收」,或正在对附近直播),把名字和
//!   状态放进 mDNS 广播的自定义数据;别的 ZuTalk 从局域网发现里读出来。不愿意
//!   被看见时广播里只有匿名的端点 id,和只开同步时一样。
//! - **递文字稿**:发送方连上对方,先报标题和大小;对方的用户点了接收才开始传。
//!   传的是不透明字节,是什么、怎么落地由调用方决定。
//! - **看直播**:观看方连上主播,主播推实时帧(replace-in-full,只推最新的)和
//!   转录稿的片(只推变了的片)。什么也不落盘。
//!
//! 和设备同步共用一个端点,但不看名单:附近的人本来就不在任何名单里。能做的
//! 只有上面两件事,而且都要本机先表示愿意(打开接收 / 打开附近直播)。

use std::collections::HashMap;
use std::sync::{Arc, Mutex, RwLock};
use std::time::Duration;

use iroh::endpoint::Connection;
use iroh::protocol::{AcceptError, ProtocolHandler};
use iroh::EndpointId;
use serde::{Deserialize, Serialize};
use tokio::sync::{mpsc, oneshot, watch};

use crate::wire::{read_frame, write_frame, WireError};

/// 附近通道。
pub const NEARBY_ALPN: &[u8] = b"zutalk/nearby/1";

/// 一份文字稿的上限。两小时三语讲座的转录稿连笔记也就几 MB。
pub const MAX_PARCEL_BYTES: u64 = 64 * 1024 * 1024;
const CHUNK_BYTES: usize = 1024 * 1024;
/// 等对方的用户点「接收」。
pub const OFFER_WAIT: Duration = Duration::from_secs(120);
const CONNECT_TIMEOUT: Duration = Duration::from_secs(15);
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(10);
/// 收完之后落地(写库、投影)最多等多久。
const DELIVER_TIMEOUT: Duration = Duration::from_secs(60);

const PRESENCE_TAG: &str = "zt1";
/// mDNS 自定义数据的上限(iroh `UserData::MAX_LENGTH`)。
const PRESENCE_MAX_BYTES: usize = 245;
const NAME_MAX_BYTES: usize = 64;

/// 本机在附近的样子。
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Presence {
    pub name: String,
    /// 愿意接收别人递来的文字稿。
    pub receiving: bool,
    /// 正在对附近直播的录音标题。
    pub live: Option<String>,
}

impl Presence {
    /// 有没有要让附近的人看见的东西。
    pub fn is_visible(&self) -> bool {
        self.receiving || self.live.is_some()
    }

    /// 放进 mDNS 的样子:`zt1|<标记>|<名字>|<直播标题>`。`%` 与 `|` 转义;
    /// 名字最多 64 字节,标题填满剩下的,都按字符截断。
    pub(crate) fn encode(&self) -> String {
        let mut flags = String::new();
        if self.receiving {
            flags.push('r');
        }
        if self.live.is_some() {
            flags.push('l');
        }
        let head = format!("{PRESENCE_TAG}|{flags}|");
        let name = escape_within(&self.name, NAME_MAX_BYTES);
        let rest = PRESENCE_MAX_BYTES - head.len() - name.len() - 1;
        let title = escape_within(self.live.as_deref().unwrap_or(""), rest);
        format!("{head}{name}|{title}")
    }

    pub(crate) fn decode(text: &str) -> Option<Self> {
        let mut fields = text.splitn(4, '|');
        if fields.next()? != PRESENCE_TAG {
            return None;
        }
        let flags = fields.next()?;
        let name = unescape(fields.next()?);
        let title = unescape(fields.next().unwrap_or(""));
        let presence = Self {
            name: crate::pairing::sanitize_device_name(&name),
            receiving: flags.contains('r'),
            live: flags
                .contains('l')
                .then(|| title.chars().filter(|c| !c.is_control()).collect()),
        };
        presence.is_visible().then_some(presence)
    }
}

fn escape_within(text: &str, budget: usize) -> String {
    let mut out = String::new();
    for c in text.chars() {
        let piece = match c {
            '%' => "%25".to_string(),
            '|' => "%7C".to_string(),
            c => c.to_string(),
        };
        if out.len() + piece.len() > budget {
            break;
        }
        out.push_str(&piece);
    }
    out
}

fn unescape(text: &str) -> String {
    text.replace("%7C", "|").replace("%25", "%")
}

/// 附近一台愿意被看见的 ZuTalk。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NearbyPeer {
    pub device: EndpointId,
    pub presence: Presence,
}

/// 有人要递一份文字稿来。名字是对方自报的,只能拿来提示。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IncomingOffer {
    pub from: EndpointId,
    pub from_name: String,
    pub title: String,
    pub bytes: u64,
}

/// 直播的内容源。帧 replace-in-full;转录稿按片,没变的片是同一个 `Arc`。
/// 发送端丢掉 `watch::Sender` 即散场。
#[derive(Clone)]
pub struct LiveFeed {
    pub title: String,
    pub frame: watch::Receiver<Option<Arc<[u8]>>>,
    pub parts: watch::Receiver<Arc<Vec<Arc<[u8]>>>>,
}

/// 应用一侧:收不收、收下后怎么落地、此刻在直播什么。
pub trait NearbyHandler: Send + Sync + 'static {
    /// 有人要递一份文字稿来。返回的通道给出用户的决定;通道被丢掉算拒绝。
    fn offer(&self, offer: IncomingOffer) -> oneshot::Receiver<bool>;
    /// 用户接收之后,整份东西到了。会阻塞(写库),在阻塞线程上调。
    fn deliver(&self, offer: &IncomingOffer, parcel: Vec<u8>) -> Result<(), String>;
    /// 此刻对附近直播的那一场。
    fn live(&self) -> Option<LiveFeed>;
}

/// 直播观看方收到的东西。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LiveEvent {
    Frame(Vec<u8>),
    Part {
        index: u32,
        total: u32,
        bytes: Vec<u8>,
    },
    /// 主播停了直播(或关了附近直播)。
    Ended,
}

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum NearbyError {
    #[error("连不上对方: {0}")]
    Unreachable(String),
    #[error("对方没有打开接收")]
    NotReceiving,
    #[error("对方拒绝了")]
    Declined,
    #[error("对方没有回应")]
    NoAnswer,
    #[error("对方没能收下: {0}")]
    Failed(String),
    #[error("对方没在直播")]
    NotLive,
    #[error("太大了")]
    TooLarge,
    #[error("传输中断: {0}")]
    Interrupted(String),
}

fn interrupted(error: impl std::fmt::Display) -> NearbyError {
    NearbyError::Interrupted(error.to_string())
}

#[derive(Debug, Serialize, Deserialize)]
enum Request {
    Offer {
        from_name: String,
        title: String,
        bytes: u64,
    },
    Watch,
}

#[derive(Debug, Serialize, Deserialize)]
enum Reply {
    Accepted,
    Declined,
    NotReceiving,
    TooLarge,
    Received,
    Failed(String),
    Live {
        title: String,
    },
    NotLive,
    Frame(Vec<u8>),
    Part {
        index: u32,
        total: u32,
        bytes: Vec<u8>,
    },
    Ended,
}

#[derive(Debug, Serialize, Deserialize)]
enum Upload {
    Chunk(Vec<u8>),
    Done,
}

/// 附近这一块在端点里的状态。
#[derive(Default)]
pub(crate) struct NearbyState {
    presence: Mutex<Option<Presence>>,
    peers: Mutex<HashMap<EndpointId, Presence>>,
    handler: RwLock<Option<Arc<dyn NearbyHandler>>>,
}

impl NearbyState {
    pub(crate) fn set_presence(&self, presence: Option<Presence>) -> Option<String> {
        let presence = presence.filter(Presence::is_visible);
        let encoded = presence.as_ref().map(Presence::encode);
        *self.presence.lock().unwrap() = presence;
        encoded
    }

    pub(crate) fn presence(&self) -> Option<Presence> {
        self.presence.lock().unwrap().clone()
    }

    pub(crate) fn set_handler(&self, handler: Option<Arc<dyn NearbyHandler>>) {
        *self.handler.write().unwrap() = handler;
    }

    fn handler(&self) -> Option<Arc<dyn NearbyHandler>> {
        self.handler.read().unwrap().clone()
    }

    /// 局域网发现报来一台:有可读的自定义数据才算「愿意被看见」,否则从列表里拿掉。
    pub(crate) fn discovered(&self, device: EndpointId, user_data: Option<&str>) {
        let mut peers = self.peers.lock().unwrap();
        match user_data.and_then(Presence::decode) {
            Some(presence) => {
                peers.insert(device, presence);
            }
            None => {
                peers.remove(&device);
            }
        }
    }

    pub(crate) fn expired(&self, device: &EndpointId) {
        self.peers.lock().unwrap().remove(device);
    }

    pub(crate) fn peers(&self) -> Vec<NearbyPeer> {
        let mut peers: Vec<NearbyPeer> = self
            .peers
            .lock()
            .unwrap()
            .iter()
            .map(|(device, presence)| NearbyPeer {
                device: *device,
                presence: presence.clone(),
            })
            .collect();
        peers.sort_by(|a, b| {
            a.presence
                .name
                .cmp(&b.presence.name)
                .then(a.device.cmp(&b.device))
        });
        peers
    }
}

// ── 发送方 ────────────────────────────────────────────────────────────────

/// 递一份文字稿。对方点了接收、收下并落地之后才返回 `Ok`。
pub(crate) async fn send_parcel(
    endpoint: &iroh::Endpoint,
    to: EndpointId,
    from_name: &str,
    title: &str,
    parcel: &[u8],
) -> Result<(), NearbyError> {
    if parcel.len() as u64 > MAX_PARCEL_BYTES {
        return Err(NearbyError::TooLarge);
    }
    let conn = tokio::time::timeout(CONNECT_TIMEOUT, endpoint.connect(to, NEARBY_ALPN))
        .await
        .map_err(|_| NearbyError::Unreachable("超时".into()))?
        .map_err(|e| NearbyError::Unreachable(e.to_string()))?;
    let result = async {
        let (mut send, mut recv) = conn.open_bi().await.map_err(interrupted)?;
        write_frame(
            &mut send,
            &Request::Offer {
                from_name: from_name.to_string(),
                title: title.to_string(),
                bytes: parcel.len() as u64,
            },
        )
        .await
        .map_err(interrupted)?;
        // 对方的用户可能正走开;多给一点,让对方先超时拒绝。
        let answer = tokio::time::timeout(
            OFFER_WAIT + HANDSHAKE_TIMEOUT,
            read_frame::<_, Reply>(&mut recv),
        )
        .await
        .map_err(|_| NearbyError::NoAnswer)?
        .map_err(interrupted)?;
        match answer {
            Reply::Accepted => {}
            Reply::Declined => return Err(NearbyError::Declined),
            Reply::NotReceiving => return Err(NearbyError::NotReceiving),
            Reply::TooLarge => return Err(NearbyError::TooLarge),
            other => return Err(interrupted(format!("意外的回复 {other:?}"))),
        }
        for chunk in parcel.chunks(CHUNK_BYTES) {
            write_frame(&mut send, &Upload::Chunk(chunk.to_vec()))
                .await
                .map_err(interrupted)?;
        }
        write_frame(&mut send, &Upload::Done)
            .await
            .map_err(interrupted)?;
        send.finish().map_err(interrupted)?;
        let done = tokio::time::timeout(
            DELIVER_TIMEOUT + HANDSHAKE_TIMEOUT,
            read_frame::<_, Reply>(&mut recv),
        )
        .await
        .map_err(|_| NearbyError::NoAnswer)?
        .map_err(interrupted)?;
        match done {
            Reply::Received => Ok(()),
            Reply::Failed(reason) => Err(NearbyError::Failed(reason)),
            other => Err(interrupted(format!("意外的回复 {other:?}"))),
        }
    }
    .await;
    conn.close(0u32.into(), b"done");
    result
}

/// 看附近一台的直播。返回标题和事件流;丢掉接收端即离开。
pub(crate) async fn watch_live(
    endpoint: &iroh::Endpoint,
    host: EndpointId,
    runtime: &tokio::runtime::Handle,
) -> Result<(String, mpsc::Receiver<LiveEvent>), NearbyError> {
    let conn = tokio::time::timeout(CONNECT_TIMEOUT, endpoint.connect(host, NEARBY_ALPN))
        .await
        .map_err(|_| NearbyError::Unreachable("超时".into()))?
        .map_err(|e| NearbyError::Unreachable(e.to_string()))?;
    let opened = async {
        let (mut send, mut recv) = conn.open_bi().await.map_err(interrupted)?;
        write_frame(&mut send, &Request::Watch)
            .await
            .map_err(interrupted)?;
        send.finish().map_err(interrupted)?;
        let reply = read_frame::<_, Reply>(&mut recv)
            .await
            .map_err(interrupted)?;
        Ok::<_, NearbyError>((reply, recv))
    };
    let (reply, mut recv) = tokio::time::timeout(HANDSHAKE_TIMEOUT, opened)
        .await
        .map_err(|_| NearbyError::NoAnswer)??;
    let title = match reply {
        Reply::Live { title } => title,
        Reply::NotLive => {
            conn.close(0u32.into(), b"bye");
            return Err(NearbyError::NotLive);
        }
        other => {
            conn.close(0u32.into(), b"bye");
            return Err(interrupted(format!("意外的回复 {other:?}")));
        }
    };
    let (events, receiver) = mpsc::channel(64);
    runtime.spawn(async move {
        loop {
            let event = tokio::select! {
                _ = events.closed() => break,
                message = read_frame::<_, Reply>(&mut recv) => match message {
                    Ok(Reply::Frame(bytes)) => LiveEvent::Frame(bytes),
                    Ok(Reply::Part { index, total, bytes }) => LiveEvent::Part { index, total, bytes },
                    Ok(Reply::Ended) | Err(_) => LiveEvent::Ended,
                    Ok(_) => continue,
                },
            };
            let ended = event == LiveEvent::Ended;
            if events.send(event).await.is_err() || ended {
                break;
            }
        }
        conn.close(0u32.into(), b"bye");
    });
    Ok((title, receiver))
}

// ── 接收方 / 主播 ──────────────────────────────────────────────────────────

#[derive(Clone)]
pub(crate) struct NearbyAcceptor(pub(crate) Arc<NearbyState>);

impl std::fmt::Debug for NearbyAcceptor {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("NearbyAcceptor")
    }
}

impl ProtocolHandler for NearbyAcceptor {
    async fn accept(&self, conn: Connection) -> Result<(), AcceptError> {
        let state = &self.0;
        let from = conn.remote_id();
        let opened = async {
            let (send, mut recv) = conn.accept_bi().await?;
            let request = read_frame::<_, Request>(&mut recv)
                .await
                .map_err(AcceptError::from_err)?;
            Ok::<_, AcceptError>((send, recv, request))
        };
        let Ok(Ok((mut send, mut recv, request))) =
            tokio::time::timeout(HANDSHAKE_TIMEOUT, opened).await
        else {
            return Ok(());
        };
        let handler = state.handler();
        let presence = state.presence();
        match request {
            Request::Offer {
                from_name,
                title,
                bytes,
            } => {
                let receiving = presence.as_ref().is_some_and(|p| p.receiving);
                let offer = IncomingOffer {
                    from,
                    from_name: crate::pairing::sanitize_device_name(&from_name),
                    title: title
                        .chars()
                        .filter(|c| !c.is_control())
                        .take(200)
                        .collect(),
                    bytes,
                };
                let reply = match handler {
                    _ if bytes > MAX_PARCEL_BYTES => Reply::TooLarge,
                    Some(handler) if receiving => {
                        receive_parcel(&conn, &mut send, &mut recv, handler, offer).await
                    }
                    _ => Reply::NotReceiving,
                };
                let _ = write_frame(&mut send, &reply).await;
                let _ = send.finish();
                let _ = tokio::time::timeout(HANDSHAKE_TIMEOUT, conn.closed()).await;
            }
            Request::Watch => {
                let feed = presence
                    .as_ref()
                    .filter(|p| p.live.is_some())
                    .and(handler)
                    .and_then(|handler| handler.live());
                match feed {
                    None => {
                        let _ = write_frame(&mut send, &Reply::NotLive).await;
                        let _ = send.finish();
                        let _ = tokio::time::timeout(HANDSHAKE_TIMEOUT, conn.closed()).await;
                    }
                    Some(feed) => {
                        if let Err(error) = stream_live(&conn, &mut send, feed).await {
                            tracing::debug!(%error, "附近直播的一位观众离开");
                        }
                        let _ = send.finish();
                    }
                }
            }
        }
        Ok(())
    }
}

/// 问用户;接收了就收完整份、交给应用落地。返回要给发送方的最后一句。
async fn receive_parcel(
    conn: &Connection,
    send: &mut iroh::endpoint::SendStream,
    recv: &mut iroh::endpoint::RecvStream,
    handler: Arc<dyn NearbyHandler>,
    offer: IncomingOffer,
) -> Reply {
    let decision = handler.offer(offer.clone());
    let accepted = tokio::select! {
        answer = tokio::time::timeout(OFFER_WAIT, decision) => {
            matches!(answer, Ok(Ok(true)))
        }
        // 发送方不等了:别留一个没人等的提示。
        _ = conn.closed() => return Reply::Declined,
    };
    if !accepted {
        return Reply::Declined;
    }
    if write_frame(send, &Reply::Accepted).await.is_err() {
        return Reply::Failed("中断".into());
    }
    let mut parcel = Vec::with_capacity(offer.bytes.min(MAX_PARCEL_BYTES) as usize);
    loop {
        let chunk =
            tokio::time::timeout(HANDSHAKE_TIMEOUT * 3, read_frame::<_, Upload>(recv)).await;
        match chunk {
            Ok(Ok(Upload::Chunk(bytes))) => {
                if (parcel.len() + bytes.len()) as u64 > offer.bytes {
                    return Reply::Failed("比说好的大".into());
                }
                parcel.extend_from_slice(&bytes);
            }
            Ok(Ok(Upload::Done)) => break,
            Ok(Err(error)) => return Reply::Failed(error.to_string()),
            Err(_) => return Reply::Failed("超时".into()),
        }
    }
    let delivered = tokio::time::timeout(
        DELIVER_TIMEOUT,
        tokio::task::spawn_blocking(move || handler.deliver(&offer, parcel)),
    )
    .await;
    match delivered {
        Ok(Ok(Ok(()))) => Reply::Received,
        Ok(Ok(Err(reason))) => Reply::Failed(reason),
        _ => Reply::Failed("落地失败".into()),
    }
}

/// 给一位观众推直播,直到散场或对方离开。
async fn stream_live(
    conn: &Connection,
    send: &mut iroh::endpoint::SendStream,
    mut feed: LiveFeed,
) -> Result<(), WireError> {
    write_frame(
        send,
        &Reply::Live {
            title: feed.title.clone(),
        },
    )
    .await?;
    // 晚到的观众先拿到此刻的全部片与最后一帧。
    let mut sent: Vec<Arc<[u8]>> = Vec::new();
    let parts = feed.parts.borrow_and_update().clone();
    send_changed_parts(send, &parts, &mut sent).await?;
    let frame = feed.frame.borrow_and_update().clone();
    if let Some(frame) = frame {
        write_frame(send, &Reply::Frame(frame.to_vec())).await?;
    }
    loop {
        tokio::select! {
            _ = conn.closed() => return Ok(()),
            changed = feed.frame.changed() => {
                if changed.is_err() {
                    break;
                }
                let frame = feed.frame.borrow_and_update().clone();
                if let Some(frame) = frame {
                    write_frame(send, &Reply::Frame(frame.to_vec())).await?;
                }
            }
            changed = feed.parts.changed() => {
                if changed.is_err() {
                    break;
                }
                let parts = feed.parts.borrow_and_update().clone();
                send_changed_parts(send, &parts, &mut sent).await?;
            }
        }
    }
    write_frame(send, &Reply::Ended).await?;
    Ok(())
}

async fn send_changed_parts(
    send: &mut iroh::endpoint::SendStream,
    parts: &[Arc<[u8]>],
    sent: &mut Vec<Arc<[u8]>>,
) -> Result<(), WireError> {
    let total = parts.len() as u32;
    let shrank = sent.len() > parts.len();
    sent.truncate(parts.len());
    for (index, part) in parts.iter().enumerate() {
        let same = sent
            .get(index)
            .is_some_and(|previous| Arc::ptr_eq(previous, part) || previous == part);
        if same && !shrank {
            continue;
        }
        write_frame(
            send,
            &Reply::Part {
                index: index as u32,
                total,
                bytes: part.to_vec(),
            },
        )
        .await?;
        if index < sent.len() {
            sent[index] = part.clone();
        } else {
            sent.push(part.clone());
        }
    }
    if shrank && parts.is_empty() {
        // 片数变成零:发一个空的「共 0 片」,让观众清掉。
        write_frame(
            send,
            &Reply::Part {
                index: 0,
                total: 0,
                bytes: Vec::new(),
            },
        )
        .await?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn presence_round_trips_through_the_mdns_text() {
        let presence = Presence {
            name: "工作室|Mac 100%".into(),
            receiving: true,
            live: Some("周会 | 第三季度".into()),
        };
        let text = presence.encode();
        assert!(text.len() <= PRESENCE_MAX_BYTES);
        assert_eq!(Presence::decode(&text), Some(presence));

        let quiet = Presence {
            name: "笔记本".into(),
            receiving: false,
            live: None,
        };
        // 什么都不愿意:解出来当作看不见。
        assert_eq!(Presence::decode(&quiet.encode()), None);
        assert_eq!(Presence::decode("other|r|x|"), None);
    }

    #[test]
    fn a_long_title_is_cut_on_a_character_boundary_to_fit() {
        let presence = Presence {
            name: "名".repeat(40),
            receiving: false,
            live: Some("长".repeat(200)),
        };
        let text = presence.encode();
        assert!(text.len() <= PRESENCE_MAX_BYTES, "{} 字节", text.len());
        let back = Presence::decode(&text).unwrap();
        assert!(back.name.len() <= NAME_MAX_BYTES);
        assert!(back.live.unwrap().chars().all(|c| c == '长'));
    }
}
