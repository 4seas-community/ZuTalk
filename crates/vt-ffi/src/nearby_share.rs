//! 附近(见 docs/architecture/local-first-sync.md §9):同一网络里递一份文字稿、
//! 直接看直播字幕,都不经任何服务器。协议在 `vt_sync::nearby`;这里决定递什么、
//! 收到之后怎么落进资料库、直播推什么、观看端怎么读。
//!
//! - **递**:这场录音的同步文档(主题清空、回收站清空,当一份副本)加上它的
//!   录音笔记。收到的一方像收到自己另一台 Mac 同步来的录音一样物化,放进
//!   「未归入主题」,标注「来自 X」。对方已经有这场录音就不收 —— 一个陌生人
//!   不能借递稿改写本机已有的录音。
//! - **直播**:和加密链接同一份文字帧与转录稿片(`link_share` 的线上形态),
//!   走的是本来就端到端加密的 QUIC 连接,所以不再加一层。观看端只放在内存里。
//!
//! 音频不在这里:录音文档的列清单是封闭的,笔记是文字。
//!
//! 这是 `library_sync` 的子模块:落库要走同一把闸、同一个事务、同一套物化。

use std::collections::BTreeMap;
use std::sync::atomic::AtomicU64;

use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine;
use serde::{Deserialize, Serialize};
use tokio::sync::{oneshot, watch};
use vt_sync::{IncomingOffer, LiveEvent, LiveFeed, NearbyError, NearbyHandler, Presence};

use super::*;
use crate::notebook_capture_api::FfiNotebookCaptureLivePreview;

const PARCEL_VERSION: u32 = 1;
/// 不在名单上的设备的名字(附近递稿人自报的、备份的主人)存在这里,
/// 「来自 X」要用。
pub(super) const PEER_NAME_STATE: &str = "nearby_name/";
/// 直播中转录稿最多多久推一次。帧另走,不受它限制。
const TRANSCRIPT_INTERVAL: Duration = Duration::from_secs(2);
/// 观看端一次交给界面的行数上限。更早的在主播那里,观看端只看眼前。
const WATCH_LINES: usize = 300;

fn nearby_error(error: NearbyError) -> CoreError {
    let code = match error {
        NearbyError::Unreachable(_) => "nearby_unreachable",
        NearbyError::NotReceiving => "nearby_not_receiving",
        NearbyError::Declined => "nearby_declined",
        NearbyError::NoAnswer => "nearby_no_answer",
        NearbyError::Failed(ref reason) if reason == "already_have" => "nearby_already_have",
        NearbyError::Failed(_) | NearbyError::Interrupted(_) => "nearby_failed",
        NearbyError::NotLive => "nearby_not_live",
        NearbyError::TooLarge => "nearby_too_large",
    };
    sync_error(code)
}

// ── 递一份文字稿 ───────────────────────────────────────────────────────────

/// 线上的一份文字稿。字节用 base64,整份是 JSON:几 MB 的转录稿,不值得为它
/// 再引一种编码。
#[derive(Serialize, Deserialize)]
struct Parcel {
    v: u32,
    session_id: String,
    title: String,
    /// 录音的同步文档(Loro 快照)。
    recording: String,
    /// 录音笔记(Loro 更新),没写过笔记时为空。
    note: Option<String>,
}

impl LibrarySync {
    /// 递给附近一台的那份东西:标题与字节。录音中的那一场不递 —— 半截的句子
    /// 还在被改写。
    fn nearby_parcel(&self, session_id: &str) -> Result<(String, Vec<u8>), CoreError> {
        let recording = self
            .replica
            .read(|conn| {
                if !facts::is_exportable(conn, session_id)? {
                    return Ok(Err("still_recording"));
                }
                Ok(facts::read_recording(conn, session_id, &self.unfiled)?
                    .ok_or("recording_missing"))
            })
            .map_err(internal)?
            .map_err(sync_error)?;
        let mut copy = recording;
        // 收到的一方放进自己的「未归入主题」;回收站里的也当一份新的。
        copy.topic = None;
        copy.trashed_at = None;
        let title = copy.title.clone();
        let doc = LoroDoc::new();
        docs::write_recording(&doc, &copy, &self.device_hex, true).map_err(internal)?;
        let snapshot = doc.export(ExportMode::Snapshot).map_err(internal)?;
        let note = crate::block_document_api::session_note_document_id(session_id)
            .ok()
            .and_then(|doc_id| self.note_updates_since(&doc_id, &[]));
        let parcel = Parcel {
            v: PARCEL_VERSION,
            session_id: session_id.to_string(),
            title: title.clone(),
            recording: BASE64.encode(snapshot),
            note: note.map(|bytes| BASE64.encode(bytes)),
        };
        Ok((title, serde_json::to_vec(&parcel).map_err(internal)?))
    }

    /// 收下附近递来的一份。返回落进本机的录音 id;失败给稳定代码。
    fn receive_nearby_parcel(
        &self,
        from: &EndpointId,
        from_name: &str,
        bytes: &[u8],
    ) -> Result<String, String> {
        let parcel: Parcel = serde_json::from_slice(bytes).map_err(|_| "not_a_recording")?;
        if parcel.v != PARCEL_VERSION {
            return Err("not_a_recording".into());
        }
        let recording = BASE64
            .decode(&parcel.recording)
            .map_err(|_| "not_a_recording")?;
        let session = parcel.session_id.clone();
        let from_hex = device_hex(from);
        let doc_id = recording_doc(&session);
        let mut after = Aftermath::default();
        let written = {
            let _gate = self.gate.lock().unwrap();
            self.replica.write(|tx| {
                let here: bool = tx.query_row(
                    "SELECT EXISTS(SELECT 1 FROM session_records WHERE id = ?1)",
                    [&session],
                    |row| row.get(0),
                )?;
                if here || self.tombstoned(tx, &session)? || self.fact_doc(tx, &doc_id)?.is_some() {
                    return Ok(Err("already_have"));
                }
                let doc = LoroDoc::new();
                if doc.import(&recording).is_err() {
                    return Ok(Err("not_a_recording"));
                }
                // 只收它自己说的那一场,来源必须是递稿的这台(连接已认证过对方)。
                let fits = docs::read_recording(&doc)?.is_some_and(|(copy, origin)| {
                    copy.session_id == session && copy.topic.is_none() && origin == from_hex
                });
                if !fits {
                    return Ok(Err("not_a_recording"));
                }
                self.materialize(tx, &doc_id, &doc, &mut after, false)?;
                self.save_fact_doc(tx, &doc_id, &doc)?;
                facts::set_state(tx, &format!("{PEER_NAME_STATE}{from_hex}"), Some(from_name))?;
                Ok(Ok(()))
            })
        };
        match written {
            Ok(Ok(())) => {}
            Ok(Err(code)) => return Err(code.into()),
            Err(error) => {
                self.drop_cache();
                tracing::warn!(%error, "附近:收下递来的录音失败");
                return Err("failed".into());
            }
        }
        after.changed_docs.insert(doc_id);
        self.run_aftermath(after, None);
        if let Some(note) = parcel.note.and_then(|note| BASE64.decode(note).ok()) {
            if let Ok(note_id) = crate::block_document_api::session_note_document_id(&session) {
                *self.session_notes.lock().unwrap() = None;
                if let Err(error) = self.apply_note(&note_id, &note) {
                    tracing::warn!(%error, "附近:录音笔记没能落下");
                }
            }
        }
        Ok(session)
    }

    // ── 在附近的样子 ─────────────────────────────────────────────────────

    pub(super) fn publish_presence(&self) {
        let live = self
            .core
            .upgrade()
            .and_then(|core| core.nearby_live.title());
        self.engine.set_presence(Some(Presence {
            name: self.device_name.lock().unwrap().clone(),
            receiving: self.nearby.receiving.load(Ordering::SeqCst),
            live,
        }));
    }

    fn nearby_status(&self) -> FfiNearbyStatus {
        let core = self.core.upgrade();
        let live = core.as_ref().and_then(|core| core.nearby_live.summary());
        FfiNearbyStatus {
            running: true,
            discovery: self
                .options
                .local_discovery
                .unwrap_or_else(default_local_discovery),
            receiving: self.nearby.receiving.load(Ordering::SeqCst),
            peers: self
                .engine
                .nearby()
                .into_iter()
                .map(|peer| FfiNearbyPeer {
                    device_id: device_hex(&peer.device),
                    name: peer.presence.name,
                    receiving: peer.presence.receiving,
                    live_title: peer.presence.live,
                })
                .collect(),
            offers: self.nearby.pending(),
            live_session_id: live.as_ref().map(|(session, _)| session.clone()),
            live_viewers: live.map(|(_, viewers)| viewers).unwrap_or(0),
            watching: self
                .nearby
                .watching
                .lock()
                .unwrap()
                .as_ref()
                .map(|w| device_hex(&w.host)),
        }
    }
}

/// 递来的东西在本机的收件处:等用户回答的、刚收下的。
#[derive(Default)]
pub(super) struct NearbyInbox {
    sync: Mutex<Weak<LibrarySync>>,
    receiving: AtomicBool,
    offers: Mutex<BTreeMap<u64, PendingOffer>>,
    next_offer: AtomicU64,
    received: Mutex<Vec<FfiNearbyReceived>>,
    watching: Mutex<Option<Watching>>,
}

struct PendingOffer {
    offer: IncomingOffer,
    answer: oneshot::Sender<bool>,
}

impl NearbyInbox {
    pub(super) fn attach(&self, sync: &Arc<LibrarySync>) {
        *self.sync.lock().unwrap() = Arc::downgrade(sync);
    }

    fn sync(&self) -> Option<Arc<LibrarySync>> {
        self.sync.lock().unwrap().upgrade()
    }

    fn changed(&self) {
        if let Some(listener) = self.sync().and_then(|sync| sync.listener()) {
            listener.on_nearby_changed();
        }
    }

    /// 还在等回答的。发送方已经不等了的顺手清掉。
    fn pending(&self) -> Vec<FfiNearbyOffer> {
        let mut offers = self.offers.lock().unwrap();
        offers.retain(|_, pending| !pending.answer.is_closed());
        offers
            .iter()
            .map(|(id, pending)| FfiNearbyOffer {
                id: *id,
                from_name: pending.offer.from_name.clone(),
                title: pending.offer.title.clone(),
                bytes: pending.offer.bytes,
            })
            .collect()
    }

    fn answer(&self, id: u64, accept: bool) {
        if let Some(pending) = self.offers.lock().unwrap().remove(&id) {
            let _ = pending.answer.send(accept);
        }
        self.changed();
    }
}

impl NearbyHandler for NearbyInbox {
    fn offer(&self, offer: IncomingOffer) -> oneshot::Receiver<bool> {
        let (answer, decision) = oneshot::channel();
        let id = self.next_offer.fetch_add(1, Ordering::SeqCst) + 1;
        self.offers
            .lock()
            .unwrap()
            .insert(id, PendingOffer { offer, answer });
        self.changed();
        decision
    }

    fn deliver(&self, offer: &IncomingOffer, parcel: Vec<u8>) -> Result<(), String> {
        let sync = self.sync().ok_or("failed")?;
        let session = sync.receive_nearby_parcel(&offer.from, &offer.from_name, &parcel)?;
        self.received.lock().unwrap().push(FfiNearbyReceived {
            session_id: session,
            title: offer.title.clone(),
            from_name: offer.from_name.clone(),
        });
        self.changed();
        Ok(())
    }

    fn live(&self) -> Option<LiveFeed> {
        self.sync()?.core.upgrade()?.nearby_live.feed()
    }
}

// ── 对附近直播 ─────────────────────────────────────────────────────────────

/// 转录稿的片:按片号排好,没变的片是同一个 `Arc`。
type PartsSender = watch::Sender<Arc<Vec<Arc<[u8]>>>>;

/// 核心上的一格:正在对附近直播的那一场。字幕出口往里写帧,转录稿由一条
/// 后台线程按节拍推。
#[derive(Default)]
pub(crate) struct NearbyLiveSlot(Mutex<Option<NearbyLiveHost>>);

pub(crate) struct NearbyLiveHost {
    session_id: String,
    title: String,
    frame: watch::Sender<Option<Arc<[u8]>>>,
    parts: Arc<PartsSender>,
    stop: Arc<AtomicBool>,
}

impl Drop for NearbyLiveHost {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
    }
}

impl NearbyLiveSlot {
    fn title(&self) -> Option<String> {
        self.0
            .lock()
            .unwrap()
            .as_ref()
            .map(|host| host.title.clone())
    }

    /// 在播哪一场、几个人在看。
    fn summary(&self) -> Option<(String, u32)> {
        self.0
            .lock()
            .unwrap()
            .as_ref()
            .map(|host| (host.session_id.clone(), host.frame.receiver_count() as u32))
    }

    fn feed(&self) -> Option<LiveFeed> {
        self.0.lock().unwrap().as_ref().map(|host| LiveFeed {
            title: host.title.clone(),
            frame: host.frame.subscribe(),
            parts: host.parts.subscribe(),
        })
    }
}

/// 字幕出口:只推正在附近直播的那一场。
pub(crate) fn nearby_broadcast(slot: &NearbyLiveSlot, preview: &FfiNotebookCaptureLivePreview) {
    let Ok(guard) = slot.0.lock() else {
        return;
    };
    let Some(host) = guard.as_ref() else {
        return;
    };
    if host.session_id != preview.session_id {
        return;
    }
    if let Ok(bytes) = serde_json::to_vec(&crate::link_share::web_frame(preview)) {
        host.frame.send_replace(Some(Arc::from(bytes)));
    }
}

/// 有人在看就按节拍重算转录稿,只把变了的片换成新的 `Arc`。
fn push_transcript(
    core: Weak<ZuTalkCore>,
    session: String,
    parts: Arc<PartsSender>,
    stop: Arc<AtomicBool>,
) {
    let spawned = std::thread::Builder::new()
        .name("zutalk-nearby-live".into())
        .spawn(move || {
            while !stop.load(Ordering::SeqCst) {
                if parts.receiver_count() > 0 {
                    let Some(core) = core.upgrade() else {
                        return;
                    };
                    if let Ok(fresh) = core.transcript_parts(&session) {
                        let current = parts.borrow().clone();
                        let next: Vec<Arc<[u8]>> = fresh
                            .iter()
                            .enumerate()
                            .filter_map(|(index, part)| {
                                let bytes = serde_json::to_vec(part).ok()?;
                                Some(match current.get(index) {
                                    Some(previous) if **previous == *bytes => previous.clone(),
                                    _ => Arc::from(bytes),
                                })
                            })
                            .collect();
                        let same = next.len() == current.len()
                            && next
                                .iter()
                                .zip(current.iter())
                                .all(|(a, b)| Arc::ptr_eq(a, b));
                        if !same {
                            parts.send_replace(Arc::new(next));
                        }
                    }
                }
                // 小步睡,停得快。
                for _ in 0..10 {
                    if stop.load(Ordering::SeqCst) {
                        return;
                    }
                    std::thread::sleep(TRANSCRIPT_INTERVAL / 10);
                }
            }
        });
    if let Err(error) = spawned {
        tracing::warn!(%error, "附近直播:转录稿线程没起来");
    }
}

// ── 看附近的直播 ───────────────────────────────────────────────────────────

struct Watching {
    host: EndpointId,
    host_name: String,
    title: String,
    view: Arc<Mutex<WatchView>>,
    task: tokio::task::JoinHandle<()>,
}

impl Drop for Watching {
    fn drop(&mut self) {
        // 丢掉事件的接收端,引擎那边就关连接。
        self.task.abort();
    }
}

#[derive(Default)]
struct WatchView {
    frame: Option<InFrame>,
    parts: BTreeMap<u32, InPart>,
    ended: bool,
}

impl WatchView {
    fn apply(&mut self, event: LiveEvent) {
        match event {
            LiveEvent::Frame(bytes) => {
                if let Ok(frame) = serde_json::from_slice(&bytes) {
                    self.frame = Some(frame);
                }
            }
            LiveEvent::Part {
                index,
                total,
                bytes,
            } => {
                self.parts.retain(|i, _| *i < total);
                if index < total {
                    if let Ok(part) = serde_json::from_slice(&bytes) {
                        self.parts.insert(index, part);
                    }
                }
            }
            LiveEvent::Ended => self.ended = true,
        }
    }

    /// 转录稿的句子在前,实时尾巴在后;尾巴里已经落定成句子的不再重复。
    fn lines(&self) -> (Vec<FfiNearbyLine>, Vec<String>) {
        let mut speakers: BTreeMap<&str, &InSpeaker> = BTreeMap::new();
        for part in self.parts.values() {
            for (id, speaker) in &part.speakers {
                speakers.insert(id, speaker);
            }
        }
        let who = |id: &Option<String>| -> (Option<String>, Option<String>) {
            match id.as_deref().and_then(|id| speakers.get(id)) {
                Some(speaker) => (speaker.name.clone(), Some(speaker.label.clone())),
                None => (None, None),
            }
        };
        let mut languages = BTreeSet::new();
        let mut settled_ids = BTreeSet::new();
        let mut lines = Vec::new();
        for block in self.parts.values().flat_map(|part| &part.blocks) {
            settled_ids.insert(block.id.as_str());
            let (speaker, speaker_label) = who(&block.speaker);
            languages.extend(block.lanes.keys().cloned());
            lines.push(FfiNearbyLine {
                id: block.id.clone(),
                speaker,
                speaker_label,
                source: block.text.clone(),
                translations: block
                    .lanes
                    .iter()
                    .map(|(language, text)| FfiNearbyText {
                        language: language.clone(),
                        text: text.clone(),
                    })
                    .collect(),
                settled: true,
            });
        }
        if let Some(frame) = &self.frame {
            for utterance in &frame.utterances {
                if settled_ids.contains(utterance.id.as_str()) {
                    continue;
                }
                let (speaker, speaker_label) = who(&utterance.speaker);
                let mut translations = Vec::new();
                if let (Some(language), Some(text)) =
                    (&utterance.translated_language, &utterance.translated_text)
                {
                    languages.insert(language.clone());
                    translations.push(FfiNearbyText {
                        language: language.clone(),
                        text: text.clone(),
                    });
                }
                lines.push(FfiNearbyLine {
                    id: utterance.id.clone(),
                    speaker,
                    speaker_label,
                    source: utterance.source_text.clone(),
                    translations,
                    settled: false,
                });
            }
            for cue in &frame.cues {
                languages.insert(cue.target_language.clone());
                lines.push(FfiNearbyLine {
                    id: format!("cue-{}", cue.target_language),
                    speaker: None,
                    speaker_label: None,
                    source: String::new(),
                    translations: vec![FfiNearbyText {
                        language: cue.target_language.clone(),
                        text: cue.text.clone(),
                    }],
                    settled: false,
                });
            }
        }
        let skip = lines.len().saturating_sub(WATCH_LINES);
        (lines.split_off(skip), languages.into_iter().collect())
    }
}

// 观看端按 `link_share` 的线上形态读。键名与那边的 Serialize 一致 ——
// `a_nearby_viewer_reads_what_the_live_link_writes` 守着两边不分家。

#[derive(Deserialize)]
struct InFrame {
    #[serde(default)]
    utterances: Vec<InUtterance>,
    #[serde(default)]
    cues: Vec<InCue>,
}

#[derive(Deserialize)]
struct InUtterance {
    id: String,
    speaker: Option<String>,
    source_text: String,
    translated_language: Option<String>,
    translated_text: Option<String>,
}

#[derive(Deserialize)]
struct InCue {
    target_language: String,
    text: String,
}

#[derive(Deserialize)]
struct InPart {
    #[serde(default)]
    blocks: Vec<InBlock>,
    #[serde(default)]
    speakers: BTreeMap<String, InSpeaker>,
}

#[derive(Deserialize)]
struct InBlock {
    id: String,
    text: String,
    #[serde(default)]
    lanes: BTreeMap<String, String>,
    speaker: Option<String>,
}

#[derive(Deserialize)]
struct InSpeaker {
    name: Option<String>,
    label: String,
}

// ── FFI ──────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiNearbyPeer {
    pub device_id: String,
    /// 对方自报的名字。
    pub name: String,
    pub receiving: bool,
    /// 正在对附近直播的录音标题。
    pub live_title: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiNearbyOffer {
    pub id: u64,
    pub from_name: String,
    pub title: String,
    pub bytes: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiNearbyReceived {
    pub session_id: String,
    pub title: String,
    pub from_name: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiNearbyStatus {
    /// 同步(也就是端点)开着。关着时附近什么也做不了。
    pub running: bool,
    /// 局域网发现开着。关着时看不见别人,别人也看不见这台。
    pub discovery: bool,
    pub receiving: bool,
    pub peers: Vec<FfiNearbyPeer>,
    /// 等本机的用户回答的递稿。
    pub offers: Vec<FfiNearbyOffer>,
    pub live_session_id: Option<String>,
    pub live_viewers: u32,
    /// 正在看哪一台的直播。
    pub watching: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiNearbyText {
    pub language: String,
    pub text: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiNearbyLine {
    pub id: String,
    /// 说话人的名字;没起名时为空,界面用 `speaker_label` 拼「说话人 N」。
    pub speaker: Option<String>,
    pub speaker_label: Option<String>,
    /// 原文。只有某种译文的行(多语单向的实时译文)为空。
    pub source: String,
    pub translations: Vec<FfiNearbyText>,
    /// 已经落定;`false` 是正在说的那一截。
    pub settled: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiNearbyWatch {
    pub host_name: String,
    pub title: String,
    pub ended: bool,
    /// 行里出现过的译文语言。原文不在其中。
    pub languages: Vec<String>,
    pub lines: Vec<FfiNearbyLine>,
}

#[uniffi::export]
impl ZuTalkCore {
    /// 附近此刻的样子:看得见谁、在等回答的递稿、自己在不在直播。
    pub fn nearby_status(&self) -> FfiNearbyStatus {
        match self.library_sync.get() {
            Some(sync) => sync.nearby_status(),
            None => FfiNearbyStatus {
                running: false,
                discovery: false,
                receiving: false,
                peers: Vec::new(),
                offers: Vec::new(),
                live_session_id: None,
                live_viewers: 0,
                watching: None,
            },
        }
    }

    /// 让附近的 Mac 看见这台、能递文字稿过来。每次递来都要本机的用户点接收。
    pub fn nearby_set_receiving(&self, on: bool) -> Result<(), CoreError> {
        let sync = self.running_sync()?;
        sync.nearby.receiving.store(on, Ordering::SeqCst);
        sync.publish_presence();
        Ok(())
    }

    pub fn nearby_answer(&self, offer_id: u64, accept: bool) {
        if let Some(sync) = self.library_sync.get() {
            sync.nearby.answer(offer_id, accept);
        }
    }

    /// 取走刚收下的(界面据此提示一次)。
    pub fn nearby_take_received(&self) -> Vec<FfiNearbyReceived> {
        self.library_sync
            .get()
            .map(|sync| std::mem::take(&mut *sync.nearby.received.lock().unwrap()))
            .unwrap_or_default()
    }

    /// 把一场录好的录音的文字稿递给附近一台。对方接收并收下后才返回;对方可能
    /// 要想一会儿,最多等两分钟。不要在主线程上调。
    ///
    /// `title` 是发送方列表里显示的名字(没起标题的录音显示开头的话),只用在
    /// 对方的提示里;为空时用录音自己的标题。
    pub fn nearby_send_recording(
        &self,
        device_id: String,
        session_id: String,
        title: String,
    ) -> Result<(), CoreError> {
        let sync = self.running_sync()?;
        let to = parse_device(&device_id).ok_or_else(|| sync_error("nearby_unreachable"))?;
        let (own_title, parcel) = sync.nearby_parcel(&session_id)?;
        let title = match title.trim() {
            "" => own_title,
            shown => shown.chars().take(120).collect(),
        };
        let from_name = sync.device_name.lock().unwrap().clone();
        sync.runtime
            .block_on(sync.engine.send_parcel(to, &from_name, &title, &parcel))
            .map_err(nearby_error)
    }

    /// 让同一网络里的 ZuTalk 直接看这一场的实时字幕。同一时间只播一场。
    pub fn nearby_start_live(
        self: Arc<Self>,
        session_id: String,
        title: String,
    ) -> Result<(), CoreError> {
        let sync = self.running_sync()?;
        let (frame, _) = watch::channel(None);
        let (parts, _) = watch::channel(Arc::new(Vec::new()));
        let parts = Arc::new(parts);
        let stop = Arc::new(AtomicBool::new(false));
        let title = title.trim().chars().take(120).collect::<String>();
        let host = NearbyLiveHost {
            session_id: session_id.clone(),
            title,
            frame,
            parts: parts.clone(),
            stop: stop.clone(),
        };
        // 换掉旧的:旧的观众收到散场。
        drop(self.nearby_live.0.lock().unwrap().replace(host));
        push_transcript(Arc::downgrade(&self), session_id, parts, stop);
        sync.publish_presence();
        Ok(())
    }

    pub fn nearby_stop_live(&self) {
        drop(self.nearby_live.0.lock().unwrap().take());
        if let Some(sync) = self.library_sync.get() {
            sync.publish_presence();
        }
    }

    /// 开始看附近一台的直播,返回标题。同一时间只看一场。
    pub fn nearby_watch(&self, device_id: String) -> Result<String, CoreError> {
        let sync = self.running_sync()?;
        let host = parse_device(&device_id).ok_or_else(|| sync_error("nearby_unreachable"))?;
        drop(sync.nearby.watching.lock().unwrap().take());
        let host_name = sync
            .engine
            .nearby()
            .into_iter()
            .find(|peer| peer.device == host)
            .map(|peer| peer.presence.name)
            .unwrap_or_default();
        let (title, mut events) = sync
            .runtime
            .block_on(sync.engine.watch_live(host))
            .map_err(nearby_error)?;
        let view = Arc::new(Mutex::new(WatchView::default()));
        let task = {
            let view = view.clone();
            sync.runtime.spawn(async move {
                while let Some(event) = events.recv().await {
                    let ended = event == LiveEvent::Ended;
                    view.lock().unwrap().apply(event);
                    if ended {
                        break;
                    }
                }
                view.lock().unwrap().ended = true;
            })
        };
        *sync.nearby.watching.lock().unwrap() = Some(Watching {
            host,
            host_name,
            title: title.clone(),
            view,
            task,
        });
        Ok(title)
    }

    pub fn nearby_stop_watching(&self) {
        if let Some(sync) = self.library_sync.get() {
            drop(sync.nearby.watching.lock().unwrap().take());
        }
    }

    /// 正在看的直播此刻的样子。界面在看的时候按节拍来取。
    pub fn nearby_watch_state(&self) -> Option<FfiNearbyWatch> {
        let sync = self.library_sync.get()?;
        let watching = sync.nearby.watching.lock().unwrap();
        let watching = watching.as_ref()?;
        let view = watching.view.lock().unwrap();
        let (lines, languages) = view.lines();
        Some(FfiNearbyWatch {
            host_name: watching.host_name.clone(),
            title: watching.title.clone(),
            ended: view.ended,
            languages,
            lines,
        })
    }
}

impl ZuTalkCore {
    /// 附近递来的录音:递稿人自报的名字。
    pub(super) fn nearby_sender_name(&self, device: &str) -> Option<String> {
        self.replica
            .read(|conn| facts::state(conn, &format!("{PEER_NAME_STATE}{device}")))
            .ok()
            .flatten()
    }
}
