//! 链接共享:把一场录音以端到端加密的网页链接交给别人看。
//!
//! 设计见 `docs/architecture/share-links.md`。要点:
//!
//! - 每条链接一把随机密钥(不复用任何音频密钥),放在链接 `#k=` 后面。浏览器
//!   从不把 `#` 后面的部分发给服务器,所以 caption-web 手里只有密文。
//! - 服务器只读得懂信封上的三样东西:事件类型、转录稿分片的 id
//!   (`<录音>:<片号>`)、分割线的种类(暂停时它要清掉最后一帧)。标题、
//!   字幕、说话人名字都在密文里。
//! - 直播:采集回调派发线程上的每一帧加密后推;转录稿在投影 ack 之后按片
//!   推,**只推变了的片** —— 长讲座的整份稿会超过服务端单次 1 MiB 的上限,
//!   每次整份重推也白白占着会场的上行。
//! - 录好的录音:建房 → 说明 → 各片 → 封笔;服务端 24 小时后清掉,主持人
//!   随时可以撤销(当场清掉)。
//!
//! 音频从不经过这里:载荷只有文字。

use std::collections::{BTreeMap, HashMap};
use std::hash::{Hash, Hasher};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use vt_crypto::SessionKey;

use crate::notebook_capture_api::FfiNotebookCaptureLivePreview;
use crate::{CoreError, ZuTalkCore};

/// 默认部署位。与 invite 同一域名家族。
pub const DEFAULT_LINK_SERVICE: &str = "https://zulangue-caption.exe.xyz";
/// 录好的录音的链接多久失效(负责人定案 2026-09-28)。服务端的留存期按
/// 最后一次推送计,录音链接推完即封笔,两者一致。
pub(crate) const RECORDING_LINK_TTL_SECS: i64 = 24 * 60 * 60;
/// 一片转录稿装多少句。三语讲座一句连译文约 1 KB,一片远在 1 MiB 之下。
const BLOCKS_PER_PART: usize = 120;
/// 直播中转录稿最多多久推一次。字幕帧另走,不受它限制。
const TRANSCRIPT_PUSH_INTERVAL: Duration = Duration::from_secs(2);
const REGISTRY_FILE: &str = "share-links.json";

/// 核心启动时用的链接服务。调试构建认 `ZUTALK_LINK_SERVICE`,好让开发版
/// 对着本机起的 caption-web 跑,开发数据不上线;发布构建只认默认值。
pub(crate) fn initial_link_service() -> String {
    #[cfg(debug_assertions)]
    if let Ok(base) = std::env::var("ZUTALK_LINK_SERVICE") {
        if !base.trim().is_empty() {
            return base;
        }
    }
    DEFAULT_LINK_SERVICE.to_string()
}

fn internal(message: impl std::fmt::Display) -> CoreError {
    CoreError::InternalError {
        message: message.to_string(),
    }
}

fn unreachable_service(error: impl std::fmt::Display) -> CoreError {
    CoreError::InternalError {
        message: format!("连不上共享服务: {error}"),
    }
}

fn now_epoch() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| elapsed.as_secs() as i64)
        .unwrap_or(0)
}

// =========================================================================
// 密钥与信封
// =========================================================================

/// 一条链接的内容密钥。AES-256-GCM,格式与浏览器 WebCrypto 对得上:
/// 12 字节随机数 ‖ 密文 ‖ 校验码。
struct LinkKey(SessionKey);

impl LinkKey {
    fn generate() -> Self {
        Self(SessionKey::generate())
    }

    fn fragment(&self) -> String {
        URL_SAFE_NO_PAD.encode(self.0.as_bytes())
    }

    fn seal<T: Serialize>(&self, value: &T) -> Result<String, CoreError> {
        let plain = serde_json::to_vec(value).map_err(internal)?;
        let sealed = vt_crypto::encrypt_chunk(&plain, &self.0).map_err(internal)?;
        Ok(URL_SAFE_NO_PAD.encode(sealed))
    }

    /// 信封:密文 + 服务器需要读的那一两个明文字段。
    fn envelope<T: Serialize>(&self, value: &T, clear: Value) -> Result<Value, CoreError> {
        let mut envelope = json!({ "v": 2, "ct": self.seal(value)? });
        if let (Value::Object(target), Value::Object(fields)) = (&mut envelope, clear) {
            target.extend(fields);
        }
        Ok(envelope)
    }
}

// =========================================================================
// 线上形态(加密前)。观看页按这些键名读 —— 改名即断线。
// =========================================================================

/// 这场共享的说明。
#[derive(Debug, Clone, Serialize)]
struct LinkMeta {
    title: String,
    /// 正在录的直播;`false` 是一段录好的录音。
    live: bool,
    /// 观看页给不给「下载」。直播跟着「散场后让观众留」,录音链接恒给。
    download: bool,
}

#[derive(Debug, Clone, Serialize)]
struct WebUtterance {
    id: String,
    session_id: String,
    speaker: Option<String>,
    source_language: String,
    provisional_source_language: Option<String>,
    source_text: String,
    translated_language: Option<String>,
    translated_text: Option<String>,
    completion: String,
}

#[derive(Debug, Clone, Serialize)]
struct WebCue {
    target_language: String,
    text: String,
    completion: String,
}

/// 一帧实时字幕:正在说的那一截,replace-in-full。
#[derive(Debug, Clone, Serialize)]
struct WebFrame {
    session_id: String,
    preview_revision: u64,
    utterances: Vec<WebUtterance>,
    cues: Vec<WebCue>,
}

fn web_frame(preview: &FfiNotebookCaptureLivePreview) -> WebFrame {
    WebFrame {
        session_id: preview.session_id.clone(),
        preview_revision: preview.preview_revision,
        utterances: preview
            .utterances
            .iter()
            .map(|u| WebUtterance {
                id: u.id.clone(),
                session_id: u.session_id.clone(),
                speaker: u.session_speaker_id.clone(),
                source_language: u.source_language.clone(),
                provisional_source_language: u.provisional_source_language.clone(),
                source_text: u.source_text.clone(),
                translated_language: u.translated_language.clone(),
                translated_text: u.translated_text.clone(),
                completion: u.completion.clone(),
            })
            .collect(),
        // 撤回的 cue 是删除指令,不是内容。
        cues: preview
            .translation_cues
            .iter()
            .filter(|cue| !cue.withdrawn)
            .map(|cue| WebCue {
                target_language: cue.target_language.clone(),
                text: cue.text.clone(),
                completion: cue.completion.clone(),
            })
            .collect(),
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize)]
struct WebBlock {
    id: String,
    owner: String,
    text: String,
    lanes: BTreeMap<String, String>,
    /// 说话人在本场录音内的标识,查 `speakers` 取名字。
    speaker: Option<String>,
}

/// 一个说话人在网页上的显示材料。名字是用户给的专名;没有名字时网页按
/// 观看者的界面语言拼「说话人 3」,所以编号单独送。
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize)]
struct WebSpeaker {
    name: Option<String>,
    label: String,
}

/// 转录稿的一片。
#[derive(Debug, Clone, Serialize)]
struct WebTranscriptPart {
    session_id: String,
    part: usize,
    /// 这场录音现在一共几片。网页据此丢掉已经不存在的尾片。
    parts: usize,
    blocks: Vec<WebBlock>,
    speakers: BTreeMap<String, WebSpeaker>,
}

impl WebTranscriptPart {
    /// 服务器按它覆盖:同一片的新值原地替换。
    fn wire_id(&self) -> String {
        format!("{}:{}", self.session_id, self.part)
    }

    fn fingerprint(&self) -> u64 {
        let mut hasher = std::collections::hash_map::DefaultHasher::new();
        self.parts.hash(&mut hasher);
        self.blocks.hash(&mut hasher);
        self.speakers.hash(&mut hasher);
        hasher.finish()
    }
}

/// 录音开始/暂停在网页上的分割线。
#[derive(Debug, Clone, Serialize)]
struct WebSegment {
    kind: String,
    session_id: String,
    at: i64,
    after_block_id: Option<String>,
}

// =========================================================================
// 房间与推送
// =========================================================================

#[derive(Debug, Deserialize)]
struct CreateRoomResponse {
    room_id: String,
    publish_token: String,
    viewer_url: String,
}

#[derive(Debug, Deserialize)]
struct RoomStats {
    viewers: u32,
    locked: bool,
}

/// caption-web 上的一间房,加上这条链接的密钥。
struct LinkRoom {
    room_url: String,
    room_id: String,
    publish_token: String,
    /// 带 `#k=` 的完整链接 —— 二维码与复制按钮的内容。
    url: String,
    key: LinkKey,
}

fn http_client(timeout: Duration) -> Result<reqwest::Client, CoreError> {
    reqwest::Client::builder()
        .timeout(timeout)
        .build()
        .map_err(internal)
}

impl ZuTalkCore {
    fn link_service(&self) -> String {
        self.link_service
            .lock()
            .unwrap()
            .trim_end_matches('/')
            .to_string()
    }

    /// 建房。走网络,调用方不在主线程上调。
    fn open_link_room(&self) -> Result<LinkRoom, CoreError> {
        let base = self.link_service();
        let created: CreateRoomResponse = self.runtime.block_on(async {
            let response = http_client(Duration::from_secs(10))?
                .post(format!("{base}/v1/rooms"))
                .json(&json!({}))
                .send()
                .await
                .map_err(unreachable_service)?;
            if !response.status().is_success() {
                return Err(internal(format!("共享服务拒绝建房: {}", response.status())));
            }
            response
                .json::<CreateRoomResponse>()
                .await
                .map_err(internal)
        })?;
        let key = LinkKey::generate();
        Ok(LinkRoom {
            room_url: format!("{base}/v1/rooms/{}", created.room_id),
            room_id: created.room_id,
            publish_token: created.publish_token,
            url: format!("{}#k={}", created.viewer_url, key.fragment()),
            key,
        })
    }

    /// 同步推一条(说明、各片)。建房与封笔前后用 —— 那时顺序要紧,
    /// 不能交给后台任务。
    fn post_to_room(
        &self,
        room_url: &str,
        token: &str,
        suffix: &str,
        body: &Value,
    ) -> Result<(), CoreError> {
        self.runtime.block_on(async {
            let response = http_client(Duration::from_secs(20))?
                .post(format!("{room_url}/{suffix}"))
                .bearer_auth(token)
                .json(body)
                .send()
                .await
                .map_err(unreachable_service)?;
            if response.status().is_success() {
                Ok(())
            } else {
                Err(internal(format!(
                    "共享服务拒收 {suffix}: {}",
                    response.status()
                )))
            }
        })
    }

    /// 封笔(`purge = false`,内容留到留存期满)或撤销(当场删)。
    fn close_room(&self, room_url: &str, token: &str, purge: bool) -> Result<(), CoreError> {
        let url = if purge {
            format!("{room_url}?purge=1")
        } else {
            room_url.to_string()
        };
        self.runtime.block_on(async {
            let response = http_client(Duration::from_secs(10))?
                .delete(url)
                .bearer_auth(token)
                .send()
                .await
                .map_err(unreachable_service)?;
            // 房间已经不在(过期、被清)也算达成了目的。
            if response.status().is_success() || response.status().as_u16() == 401 {
                Ok(())
            } else {
                Err(internal(format!(
                    "共享服务没能关闭链接: {}",
                    response.status()
                )))
            }
        })
    }

    /// 一场录音的转录稿,按片切好。实时转录有内容就用它(连同译文与用户的
    /// 订正);只有精修结果的录音(比如导入的音频)退回精修稿的纯文字。
    fn transcript_parts(&self, session_id: &str) -> Result<Vec<WebTranscriptPart>, CoreError> {
        let utterances = self
            .notebook_capture_store
            .list_utterances(session_id)
            .map_err(crate::notebook_capture_api::store_error)?;
        let mut blocks: Vec<WebBlock> = utterances
            .iter()
            .filter_map(|utterance| {
                crate::notebook_capture_api::t2_machine_block_write(utterance).map(|write| {
                    WebBlock {
                        id: write.id,
                        owner: write.owner,
                        text: write.text,
                        lanes: write.lanes,
                        speaker: utterance.session_speaker_id.clone(),
                    }
                })
            })
            .filter(|block| !block.text.is_empty() || !block.lanes.is_empty())
            .collect();
        if blocks.is_empty() {
            blocks = self.refined_blocks(session_id)?;
        }
        let speakers = self.web_speakers(session_id);
        let chunks: Vec<Vec<WebBlock>> = blocks
            .chunks(BLOCKS_PER_PART)
            .map(<[WebBlock]>::to_vec)
            .collect();
        let parts = chunks.len();
        Ok(chunks
            .into_iter()
            .enumerate()
            .map(|(part, blocks)| WebTranscriptPart {
                session_id: session_id.to_string(),
                part,
                parts,
                blocks,
                speakers: speakers.clone(),
            })
            .collect())
    }

    /// 精修稿的纯文字,一段一块。没有精修结果时为空。
    fn refined_blocks(&self, session_id: &str) -> Result<Vec<WebBlock>, CoreError> {
        let transcript = crate::settings_api::export_transcript(self, session_id)?;
        if !matches!(transcript, vt_export::ExportTranscript::AsyncTokens(_)) {
            return Ok(Vec::new());
        }
        let text = vt_export::export_txt(&vt_export::ExportData {
            title: String::new(),
            transcript,
            summary: None,
        })
        .map_err(internal)?;
        Ok(text
            .split("\n\n")
            .map(str::trim)
            .filter(|paragraph| !paragraph.is_empty())
            .enumerate()
            .map(|(index, paragraph)| WebBlock {
                id: format!("refined-{index}"),
                owner: format!("capture:{session_id}"),
                text: paragraph.to_string(),
                lanes: BTreeMap::new(),
                speaker: None,
            })
            .collect())
    }

    /// 本场录音的说话人名录。取名规则与 App 画布一致:会话内改名优先,
    /// 其次关联参与者的名字,都没有就只送编号。
    fn web_speakers(&self, session_id: &str) -> BTreeMap<String, WebSpeaker> {
        let Ok(speakers) = self
            .notebook_capture_store
            .list_session_speakers(session_id)
        else {
            return BTreeMap::new();
        };
        if speakers.is_empty() {
            return BTreeMap::new();
        }
        let participants: HashMap<String, String> = self
            .notebook_capture_store
            .list_participants()
            .map(|values| values.into_iter().map(|p| (p.id, p.display_name)).collect())
            .unwrap_or_default();
        speakers
            .into_iter()
            .map(|speaker| {
                let name = speaker
                    .local_display_name
                    .as_deref()
                    .map(str::trim)
                    .filter(|value| !value.is_empty())
                    .map(str::to_string)
                    .or_else(|| {
                        speaker
                            .participant_id
                            .as_deref()
                            .and_then(|id| participants.get(id))
                            .map(|name| name.trim().to_string())
                            .filter(|name| !name.is_empty())
                    });
                (
                    speaker.id,
                    WebSpeaker {
                        name,
                        label: speaker.provider_label,
                    },
                )
            })
            .collect()
    }
}

/// 直播的后台推送:帧、说明、分割线一条任务,转录稿另一条(它要节流,
/// 不能拖住字幕)。发送失败不重试不积压 —— 下一帧、下一次转录稿都是完整的;
/// 只有分割线重试一次,漏一条就永久少一条线。
struct LivePublisher {
    frame_tx: tokio::sync::watch::Sender<Option<Value>>,
    meta_tx: tokio::sync::watch::Sender<Option<Value>>,
    segment_tx: tokio::sync::mpsc::UnboundedSender<Value>,
    /// 待推的转录稿片:按片 id 覆盖,按首次出现排序。
    pending_parts: Arc<Mutex<Vec<(String, Value)>>>,
    parts_wake: tokio::sync::watch::Sender<u64>,
    tasks: Vec<tokio::task::JoinHandle<()>>,
}

impl Drop for LivePublisher {
    fn drop(&mut self) {
        for task in &self.tasks {
            task.abort();
        }
    }
}

impl LivePublisher {
    fn spawn(runtime: &tokio::runtime::Runtime, room_url: String, token: String) -> Self {
        let (frame_tx, mut frame_rx) = tokio::sync::watch::channel::<Option<Value>>(None);
        let (meta_tx, mut meta_rx) = tokio::sync::watch::channel::<Option<Value>>(None);
        let (segment_tx, mut segment_rx) = tokio::sync::mpsc::unbounded_channel::<Value>();
        let (parts_wake, mut parts_rx) = tokio::sync::watch::channel::<u64>(0);
        let pending_parts: Arc<Mutex<Vec<(String, Value)>>> = Arc::default();

        let live = {
            let room_url = room_url.clone();
            let token = token.clone();
            runtime.spawn(async move {
                let Ok(client) = http_client(Duration::from_secs(10)) else {
                    return;
                };
                let post = |suffix: &'static str, body: Value| {
                    let request = client
                        .post(format!("{room_url}/{suffix}"))
                        .bearer_auth(&token)
                        .json(&body);
                    async move { request.send().await }
                };
                loop {
                    tokio::select! {
                        changed = frame_rx.changed() => {
                            if changed.is_err() { break; }
                            let frame = frame_rx.borrow_and_update().clone();
                            if let Some(frame) = frame {
                                if let Err(error) = post("frame", frame).await {
                                    tracing::debug!(%error, "直播链接:帧未送达");
                                }
                            }
                        }
                        changed = meta_rx.changed() => {
                            if changed.is_err() { break; }
                            let meta = meta_rx.borrow_and_update().clone();
                            if let Some(meta) = meta {
                                if let Err(error) = post("meta", meta).await {
                                    tracing::debug!(%error, "直播链接:说明未送达");
                                }
                            }
                        }
                        segment = segment_rx.recv() => {
                            let Some(segment) = segment else { break };
                            for attempt in 0..2 {
                                match post("segment", segment.clone()).await {
                                    Ok(response) if response.status().is_success() => break,
                                    other => {
                                        tracing::debug!(?other, attempt, "直播链接:分割线未送达");
                                        tokio::time::sleep(Duration::from_millis(400)).await;
                                    }
                                }
                            }
                        }
                    }
                }
            })
        };

        let transcript = {
            let pending_parts = pending_parts.clone();
            runtime.spawn(async move {
                let Ok(client) = http_client(Duration::from_secs(30)) else {
                    return;
                };
                while parts_rx.changed().await.is_ok() {
                    parts_rx.borrow_and_update();
                    let batch = std::mem::take(&mut *pending_parts.lock().unwrap());
                    for (_, body) in batch {
                        let result = client
                            .post(format!("{room_url}/blocks"))
                            .bearer_auth(&token)
                            .json(&body)
                            .send()
                            .await;
                        if let Err(error) = result {
                            tracing::debug!(%error, "直播链接:转录稿未送达");
                        }
                    }
                    tokio::time::sleep(TRANSCRIPT_PUSH_INTERVAL).await;
                }
            })
        };

        Self {
            frame_tx,
            meta_tx,
            segment_tx,
            pending_parts,
            parts_wake,
            tasks: vec![live, transcript],
        }
    }

    fn queue_part(&self, wire_id: String, body: Value) {
        {
            let mut pending = self.pending_parts.lock().unwrap();
            match pending.iter_mut().find(|(id, _)| *id == wire_id) {
                Some(slot) => slot.1 = body,
                None => pending.push((wire_id, body)),
            }
        }
        self.parts_wake.send_modify(|version| *version += 1);
    }
}

/// 进行中的直播链接。
pub(crate) struct LiveLink {
    session_id: String,
    title: String,
    keeps_after_end: bool,
    locked: bool,
    viewers: u32,
    room: LinkRoom,
    publisher: LivePublisher,
    /// 已经推过的片 → 内容指纹。只推变了的。
    sent_parts: HashMap<String, u64>,
}

impl LiveLink {
    fn meta(&self) -> LinkMeta {
        LinkMeta {
            title: self.title.clone(),
            live: true,
            download: self.keeps_after_end,
        }
    }

    fn snapshot(&self) -> FfiLiveLink {
        FfiLiveLink {
            session_id: self.session_id.clone(),
            url: self.room.url.clone(),
            viewers: self.viewers,
            locked: self.locked,
            keeps_after_end: self.keeps_after_end,
        }
    }

    fn publish_meta(&self) {
        if let Ok(envelope) = self.room.key.envelope(&self.meta(), json!({})) {
            let _ = self.publisher.meta_tx.send(Some(envelope));
        }
    }

    /// 把变了的片交给后台推送。
    fn queue_transcript(&mut self, parts: Vec<WebTranscriptPart>) {
        for part in parts {
            let wire_id = part.wire_id();
            let fingerprint = part.fingerprint();
            if self.sent_parts.get(&wire_id) == Some(&fingerprint) {
                continue;
            }
            let Ok(envelope) = self
                .room
                .key
                .envelope(&part, json!({ "session_id": wire_id }))
            else {
                continue;
            };
            self.sent_parts.insert(wire_id.clone(), fingerprint);
            self.publisher.queue_part(wire_id, envelope);
        }
    }
}

pub(crate) type LiveLinkSlot = Mutex<Option<LiveLink>>;

/// 采集侧到直播链接的接线。挂在回调派发线程上:那里是「Swift 将要看到
/// 什么」唯一确定的地方,网页看到的与本机屏幕上的是同一帧。加密与入队都是
/// 微秒级,不拖慢派发。
#[derive(Clone)]
pub(crate) struct LinkCaptionTap {
    live: Arc<LiveLinkSlot>,
}

impl LinkCaptionTap {
    pub(crate) fn new(live: Arc<LiveLinkSlot>) -> Self {
        Self { live }
    }

    /// 只播正在直播的那一场;同时在录的别的录音一帧也不出去。
    pub(crate) fn broadcast(&self, preview: &FfiNotebookCaptureLivePreview) {
        let Ok(guard) = self.live.lock() else {
            return;
        };
        let Some(link) = guard.as_ref() else {
            return;
        };
        if link.session_id != preview.session_id {
            return;
        }
        if let Ok(envelope) = link.room.key.envelope(&web_frame(preview), json!({})) {
            let _ = link.publisher.frame_tx.send(Some(envelope));
        }
    }
}

// =========================================================================
// 录音链接的本机台账
// =========================================================================

/// 一条录好的录音的链接。台账在本机,撤销要用发布口令;链接里带着密钥,
/// 所以文件按 0600 写。
#[derive(Debug, Clone, Serialize, Deserialize)]
struct StoredLink {
    room_id: String,
    room_url: String,
    publish_token: String,
    session_id: String,
    url: String,
    created_at: i64,
    expires_at: i64,
}

impl StoredLink {
    fn snapshot(&self) -> FfiRecordingLink {
        FfiRecordingLink {
            room_id: self.room_id.clone(),
            session_id: self.session_id.clone(),
            url: self.url.clone(),
            created_at_epoch: self.created_at,
            expires_at_epoch: self.expires_at,
        }
    }
}

impl ZuTalkCore {
    fn link_registry_path(&self) -> PathBuf {
        self.data_dir.join(REGISTRY_FILE)
    }

    /// 读台账,顺手丢掉已经过期的(服务端那边也早清了)。
    fn load_link_registry(&self) -> Vec<StoredLink> {
        let now = now_epoch();
        std::fs::read(self.link_registry_path())
            .ok()
            .and_then(|bytes| serde_json::from_slice::<Vec<StoredLink>>(&bytes).ok())
            .unwrap_or_default()
            .into_iter()
            .filter(|link| link.expires_at > now)
            .collect()
    }

    fn save_link_registry(&self, links: &[StoredLink]) -> Result<(), CoreError> {
        use std::io::Write;
        use std::os::unix::fs::OpenOptionsExt;
        let path = self.link_registry_path();
        let temporary = path.with_extension("json.tmp");
        let bytes = serde_json::to_vec(links).map_err(internal)?;
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&temporary)
            .map_err(internal)?;
        file.write_all(&bytes).map_err(internal)?;
        file.sync_all().map_err(internal)?;
        std::fs::rename(&temporary, &path).map_err(internal)
    }
}

// =========================================================================
// FFI
// =========================================================================

/// 进行中的直播链接。
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiLiveLink {
    pub session_id: String,
    /// 带密钥的完整链接:二维码与「复制链接」的内容。
    pub url: String,
    /// 此刻打开着观看页的人数(上一次刷新时)。
    pub viewers: u32,
    /// 锁上之后新的人进不来,已经在看的不受影响。
    pub locked: bool,
    /// 散场后转录稿留在链接上(约 24 小时),观众可以下载。关着时散场即删。
    pub keeps_after_end: bool,
}

/// 一段录好的录音的链接。
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiRecordingLink {
    pub room_id: String,
    pub session_id: String,
    pub url: String,
    pub created_at_epoch: i64,
    pub expires_at_epoch: i64,
}

/// 「发送副本」的文件格式。
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FfiTranscriptFileFormat {
    /// 转录稿:标题、说话人、各语言分行。
    Markdown,
    /// 字幕文件(SRT),可以直接挂到视频上。
    Subtitles,
}

#[uniffi::export]
impl ZuTalkCore {
    /// 开始直播这场录音:建房、推说明与已有的转录稿,之后每一帧都会加密推过去。
    /// 走网络,调用方不在主线程上调。
    pub fn start_live_link(
        &self,
        session_id: String,
        title: String,
        keeps_after_end: bool,
    ) -> Result<FfiLiveLink, CoreError> {
        if self.live_link.lock().unwrap().is_some() {
            return Err(CoreError::ValidationFailed {
                message: "已经在直播;先停止当前这一场".into(),
            });
        }
        let room = self.open_link_room()?;
        let mut link = LiveLink {
            publisher: LivePublisher::spawn(
                &self.runtime,
                room.room_url.clone(),
                room.publish_token.clone(),
            ),
            session_id,
            title,
            keeps_after_end,
            locked: false,
            viewers: 0,
            room,
            sent_parts: HashMap::new(),
        };
        // 说明先到:网页一打开就知道这是哪一场、能不能下载。
        let meta = link.room.key.envelope(&link.meta(), json!({}))?;
        self.post_to_room(&link.room.room_url, &link.room.publish_token, "meta", &meta)?;
        let parts = self.transcript_parts(&link.session_id)?;
        link.queue_transcript(parts);
        let snapshot = link.snapshot();
        *self.live_link.lock().unwrap() = Some(link);
        Ok(snapshot)
    }

    /// 当前直播链接的快照。纯内存,可以在主线程上调。
    pub fn live_link(&self) -> Option<FfiLiveLink> {
        self.live_link
            .lock()
            .unwrap()
            .as_ref()
            .map(LiveLink::snapshot)
    }

    /// 问一次服务端:几个人在看、锁没锁。走网络。
    pub fn refresh_live_link(&self) -> Option<FfiLiveLink> {
        let (room_url, token) = {
            let guard = self.live_link.lock().unwrap();
            let link = guard.as_ref()?;
            (link.room.room_url.clone(), link.room.publish_token.clone())
        };
        let stats: Option<RoomStats> = self.runtime.block_on(async {
            let client = http_client(Duration::from_secs(5)).ok()?;
            let response = client
                .get(format!("{room_url}/stats"))
                .bearer_auth(&token)
                .send()
                .await
                .ok()?;
            response.json::<RoomStats>().await.ok()
        });
        let mut guard = self.live_link.lock().unwrap();
        let link = guard.as_mut()?;
        if let Some(stats) = stats {
            if link.room.room_url == room_url {
                link.viewers = stats.viewers;
                link.locked = stats.locked;
            }
        }
        Some(link.snapshot())
    }

    /// 锁上:新的观看者进不来,已经在看的不受影响。走网络。
    pub fn set_live_link_locked(&self, locked: bool) -> Result<FfiLiveLink, CoreError> {
        let (room_url, token) = self.live_room_credentials()?;
        let stats: RoomStats = self.runtime.block_on(async {
            let response = http_client(Duration::from_secs(10))?
                .post(format!("{room_url}/lock"))
                .bearer_auth(&token)
                .json(&json!({ "locked": locked }))
                .send()
                .await
                .map_err(unreachable_service)?;
            response.json::<RoomStats>().await.map_err(internal)
        })?;
        let mut guard = self.live_link.lock().unwrap();
        let link = guard.as_mut().ok_or_else(no_live_link)?;
        link.locked = stats.locked;
        link.viewers = stats.viewers;
        Ok(link.snapshot())
    }

    /// 散场后要不要把转录稿留在链接上。直播进行中可以来回改 —— 真正的
    /// 去留在停止那一刻才定。
    pub fn set_live_link_keeps_after_end(&self, keeps: bool) -> Result<FfiLiveLink, CoreError> {
        let mut guard = self.live_link.lock().unwrap();
        let link = guard.as_mut().ok_or_else(no_live_link)?;
        link.keeps_after_end = keeps;
        link.publish_meta();
        Ok(link.snapshot())
    }

    /// 换一个链接:新房间、新密钥,旧链接当场失效(在看的人要重新扫码)。
    /// 用来把不该在场的人请出去。走网络。
    pub fn replace_live_link(&self) -> Result<FfiLiveLink, CoreError> {
        let (session_id, title, keeps, locked) = {
            let guard = self.live_link.lock().unwrap();
            let link = guard.as_ref().ok_or_else(no_live_link)?;
            (
                link.session_id.clone(),
                link.title.clone(),
                link.keeps_after_end,
                link.locked,
            )
        };
        let room = self.open_link_room()?;
        let mut fresh = LiveLink {
            publisher: LivePublisher::spawn(
                &self.runtime,
                room.room_url.clone(),
                room.publish_token.clone(),
            ),
            session_id,
            title,
            keeps_after_end: keeps,
            locked: false,
            viewers: 0,
            room,
            sent_parts: HashMap::new(),
        };
        let meta = fresh.room.key.envelope(&fresh.meta(), json!({}))?;
        self.post_to_room(
            &fresh.room.room_url,
            &fresh.room.publish_token,
            "meta",
            &meta,
        )?;
        let parts = self.transcript_parts(&fresh.session_id)?;
        fresh.queue_transcript(parts);
        let old = self.live_link.lock().unwrap().replace(fresh);
        if let Some(old) = old {
            let _ = self.close_room(&old.room.room_url, &old.room.publish_token, true);
        }
        if locked {
            // 换链接是为了请人出去,锁的状态跟着新链接走。
            return self.set_live_link_locked(true);
        }
        self.live_link().ok_or_else(no_live_link)
    }

    /// 停止直播。散场后留转录稿的,先把最新的整份推完再封笔(内容留约
    /// 24 小时);不留的当场清掉。走网络。
    pub fn stop_live_link(&self) -> Result<(), CoreError> {
        let Some(link) = self.live_link.lock().unwrap().take() else {
            return Ok(());
        };
        let LiveLink {
            session_id,
            keeps_after_end,
            room,
            publisher,
            ..
        } = link;
        drop(publisher);
        if keeps_after_end {
            for part in self.transcript_parts(&session_id)? {
                let envelope = room
                    .key
                    .envelope(&part, json!({ "session_id": part.wire_id() }))?;
                self.post_to_room(&room.room_url, &room.publish_token, "blocks", &envelope)?;
            }
        }
        self.close_room(&room.room_url, &room.publish_token, !keeps_after_end)
    }

    /// 给一段录好的录音开一条只读链接:24 小时后失效,可以随时撤销。走网络。
    pub fn create_recording_link(
        &self,
        session_id: String,
        title: String,
    ) -> Result<FfiRecordingLink, CoreError> {
        let parts = self.transcript_parts(&session_id)?;
        if parts.is_empty() {
            return Err(CoreError::ValidationFailed {
                message: "这段录音还没有转录稿可以共享".into(),
            });
        }
        let room = self.open_link_room()?;
        let meta = LinkMeta {
            title,
            live: false,
            download: true,
        };
        let publish = || -> Result<(), CoreError> {
            let envelope = room.key.envelope(&meta, json!({}))?;
            self.post_to_room(&room.room_url, &room.publish_token, "meta", &envelope)?;
            for part in &parts {
                let envelope = room
                    .key
                    .envelope(part, json!({ "session_id": part.wire_id() }))?;
                self.post_to_room(&room.room_url, &room.publish_token, "blocks", &envelope)?;
            }
            // 封笔:内容就此定稿,留到留存期满。
            self.close_room(&room.room_url, &room.publish_token, false)
        };
        if let Err(error) = publish() {
            // 推了一半的房间不留:清掉,不让一条残缺的链接在外面。
            let _ = self.close_room(&room.room_url, &room.publish_token, true);
            return Err(error);
        }
        let created_at = now_epoch();
        let stored = StoredLink {
            room_id: room.room_id.clone(),
            room_url: room.room_url.clone(),
            publish_token: room.publish_token.clone(),
            session_id,
            url: room.url.clone(),
            created_at,
            expires_at: created_at + RECORDING_LINK_TTL_SECS,
        };
        let mut links = self.load_link_registry();
        links.push(stored.clone());
        self.save_link_registry(&links)?;
        Ok(stored.snapshot())
    }

    /// 这段录音还有效的链接,新的在前。
    pub fn recording_links(&self, session_id: String) -> Vec<FfiRecordingLink> {
        let mut links: Vec<FfiRecordingLink> = self
            .load_link_registry()
            .iter()
            .filter(|link| link.session_id == session_id)
            .map(StoredLink::snapshot)
            .collect();
        links.sort_by(|a, b| b.created_at_epoch.cmp(&a.created_at_epoch));
        links
    }

    /// 所有还有效的录音链接,新的在前。设置里「共享」一节据此列出此刻
    /// 在外面的一切,好让主持人一处看清、随手撤销。
    pub fn all_recording_links(&self) -> Vec<FfiRecordingLink> {
        let mut links: Vec<FfiRecordingLink> = self
            .load_link_registry()
            .iter()
            .map(StoredLink::snapshot)
            .collect();
        links.sort_by(|a, b| b.created_at_epoch.cmp(&a.created_at_epoch));
        links
    }

    /// 撤销一条录音链接:服务端当场删掉内容,链接从此打不开。走网络。
    pub fn revoke_recording_link(&self, room_id: String) -> Result<(), CoreError> {
        let mut links = self.load_link_registry();
        let Some(index) = links.iter().position(|link| link.room_id == room_id) else {
            return Ok(());
        };
        let link = links[index].clone();
        self.close_room(&link.room_url, &link.publish_token, true)?;
        links.remove(index);
        self.save_link_registry(&links)
    }

    /// 「发送副本」的文件内容。音频从不在里面。
    pub fn transcript_file(
        &self,
        session_id: String,
        format: FfiTranscriptFileFormat,
    ) -> Result<String, CoreError> {
        let record =
            self.session_store
                .get_session(&session_id)
                .map_err(|_| CoreError::NotFound {
                    message: format!("session not found: {session_id}"),
                })?;
        let data = vt_export::ExportData {
            title: record.title,
            transcript: crate::settings_api::export_transcript(self, &session_id)?,
            summary: None,
        };
        match format {
            FfiTranscriptFileFormat::Markdown => vt_export::export_markdown(&data),
            FfiTranscriptFileFormat::Subtitles => vt_export::export_srt(&data),
        }
        .map_err(internal)
    }
}

fn no_live_link() -> CoreError {
    CoreError::ValidationFailed {
        message: "没有在直播".into(),
    }
}

impl ZuTalkCore {
    fn live_room_credentials(&self) -> Result<(String, String), CoreError> {
        let guard = self.live_link.lock().unwrap();
        let link = guard.as_ref().ok_or_else(no_live_link)?;
        Ok((link.room.room_url.clone(), link.room.publish_token.clone()))
    }

    /// 投影 ack 之后:正在直播这一场的话,把变了的转录稿片交给后台推送。
    /// 绝不让共享侧的失败影响采集产线 —— 错误只记日志。
    pub(crate) fn push_live_link_transcript(&self, session_id: &str) {
        let live = {
            let guard = self.live_link.lock().unwrap();
            guard
                .as_ref()
                .is_some_and(|link| link.session_id == session_id)
        };
        if !live {
            return;
        }
        match self.transcript_parts(session_id) {
            Ok(parts) => {
                if let Some(link) = self.live_link.lock().unwrap().as_mut() {
                    if link.session_id == session_id {
                        link.queue_transcript(parts);
                    }
                }
            }
            Err(error) => tracing::warn!(session_id, %error, "直播链接:转录稿没取到"),
        }
    }

    /// 录音开始/恢复或暂停:网页上留一条分割线。不是直播的那一场不留。
    pub(crate) fn push_live_link_segment(&self, session_id: &str, kind: &str) {
        let guard = self.live_link.lock().unwrap();
        let Some(link) = guard.as_ref() else {
            return;
        };
        if link.session_id != session_id {
            return;
        }
        let after_block_id = self
            .notebook_capture_store
            .list_utterances(session_id)
            .ok()
            .and_then(|utterances| {
                utterances
                    .iter()
                    .rev()
                    .find_map(crate::notebook_capture_api::t2_machine_block_write)
                    .map(|write| write.id)
            });
        let segment = WebSegment {
            kind: kind.to_string(),
            session_id: session_id.to_string(),
            at: now_epoch(),
            after_block_id,
        };
        if let Ok(envelope) = link.room.key.envelope(&segment, json!({ "kind": kind })) {
            let _ = link.publisher.segment_tx.send(envelope);
        }
    }

    /// 测试与冒烟:把链接服务指到本地起的 caption-web。
    #[doc(hidden)]
    pub fn set_link_service_for_test(&self, base: String) {
        *self.link_service.lock().unwrap() = base;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 观看页那一侧:从链接的 `#k=` 取回密钥、解开信封。
    impl LinkKey {
        fn from_fragment(fragment: &str) -> Option<Self> {
            let bytes = URL_SAFE_NO_PAD.decode(fragment).ok()?;
            let bytes: [u8; vt_crypto::KEY_SIZE] = bytes.try_into().ok()?;
            Some(Self(SessionKey::from_bytes(bytes)))
        }

        fn open(&self, sealed: &str) -> Value {
            let bytes = URL_SAFE_NO_PAD.decode(sealed).unwrap();
            let plain = vt_crypto::decrypt_chunk(&bytes, &self.0).unwrap();
            serde_json::from_slice(&plain).unwrap()
        }
    }

    #[test]
    fn a_sealed_payload_opens_with_the_key_in_the_link_and_nothing_else() {
        let key = LinkKey::generate();
        let envelope = key
            .envelope(
                &json!({ "text": "只给拿到链接的人" }),
                json!({ "session_id": "s:0" }),
            )
            .unwrap();
        assert_eq!(envelope["v"], 2);
        assert_eq!(envelope["session_id"], "s:0", "服务器要读的字段留在外面");
        let sealed = envelope["ct"].as_str().unwrap();
        assert!(!sealed.contains("只给"), "内容不能以明文出现在信封里");

        let from_link = LinkKey::from_fragment(&key.fragment()).unwrap();
        assert_eq!(from_link.open(sealed)["text"], "只给拿到链接的人");
        // 12 字节随机数:同一内容两次封装得到不同密文。
        let again = key
            .envelope(&json!({ "text": "只给拿到链接的人" }), json!({}))
            .unwrap();
        assert_ne!(again["ct"], envelope["ct"]);
    }

    #[test]
    fn a_link_key_is_url_safe_and_the_right_length() {
        let fragment = LinkKey::generate().fragment();
        assert_eq!(fragment.len(), 43, "32 字节 base64url 不带填充");
        assert!(fragment
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_'));
        assert!(LinkKey::from_fragment("too-short").is_none());
    }

    #[test]
    fn transcript_parts_fingerprint_changes_only_with_content() {
        let part = |text: &str| WebTranscriptPart {
            session_id: "s".into(),
            part: 0,
            parts: 1,
            blocks: vec![WebBlock {
                id: "b".into(),
                owner: "capture:s".into(),
                text: text.into(),
                lanes: BTreeMap::from([("en".into(), "hi".into())]),
                speaker: None,
            }],
            speakers: BTreeMap::new(),
        };
        assert_eq!(part("你好").fingerprint(), part("你好").fingerprint());
        assert_ne!(part("你好").fingerprint(), part("您好").fingerprint());
        assert_eq!(part("你好").wire_id(), "s:0");
    }

    fn preview(
        session_id: &str,
        revision: u64,
    ) -> crate::notebook_capture_api::FfiNotebookCaptureLivePreview {
        use crate::notebook_capture_api::{
            FfiNotebookCaptureTranslationCue, FfiNotebookCaptureUtterance,
        };
        crate::notebook_capture_api::FfiNotebookCaptureLivePreview {
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

    #[test]
    fn a_frame_carries_text_only_and_drops_withdrawn_cues() {
        let mut preview = preview("sess", 3);
        if let Some(cue) = preview.translation_cues.first_mut() {
            cue.withdrawn = true;
        }
        let withdrawn = preview
            .translation_cues
            .iter()
            .filter(|c| c.withdrawn)
            .count();
        let frame = web_frame(&preview);
        assert_eq!(frame.cues.len(), preview.translation_cues.len() - withdrawn);
        let json = serde_json::to_string(&frame).unwrap();
        for forbidden in ["audio", "pcm", "wav", "sample"] {
            assert!(!json.contains(forbidden), "帧里不该出现 {forbidden}");
        }
    }

    /// 本机起的(或 `LINK_SHARE_SERVICE` 指定的)caption-web。
    struct CaptionService {
        base: String,
        child: Option<std::process::Child>,
    }

    impl Drop for CaptionService {
        fn drop(&mut self) {
            if let Some(child) = self.child.as_mut() {
                let _ = child.kill();
                let _ = child.wait();
            }
        }
    }

    impl CaptionService {
        fn start() -> Option<Self> {
            if let Ok(base) = std::env::var("LINK_SHARE_SERVICE") {
                return Some(Self { base, child: None });
            }
            let port = std::net::TcpListener::bind("127.0.0.1:0")
                .ok()?
                .local_addr()
                .ok()?
                .port();
            let base = format!("http://127.0.0.1:{port}");
            let script = concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/../../services/caption-web/server.py"
            );
            let child = std::process::Command::new("python3")
                .args([
                    script,
                    "--host",
                    "127.0.0.1",
                    "--port",
                    &port.to_string(),
                    "--public-base",
                    &base,
                ])
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null())
                .spawn()
                .ok()?;
            let service = Self {
                base,
                child: Some(child),
            };
            for _ in 0..80 {
                if std::net::TcpStream::connect(("127.0.0.1", port)).is_ok() {
                    return Some(service);
                }
                std::thread::sleep(Duration::from_millis(50));
            }
            None
        }

        fn local(&self) -> bool {
            self.child.is_some()
        }

        fn status(&self, core: &ZuTalkCore, room_id: &str) -> (u16, Value) {
            let url = format!("{}/v1/rooms/{room_id}", self.base);
            core.runtime.block_on(async {
                let response = reqwest::get(url).await.unwrap();
                let status = response.status().as_u16();
                (
                    status,
                    response.json::<Value>().await.unwrap_or(Value::Null),
                )
            })
        }

        /// 读 SSE 直到 `until` 这个事件完整到手。返回状态码与原文。
        fn events_until(&self, core: &ZuTalkCore, room_id: &str, until: &str) -> (u16, String) {
            let marker = format!("event: {until}\n");
            let url = format!("{}/v1/rooms/{room_id}/events", self.base);
            core.runtime.block_on(async {
                let mut response = reqwest::get(url).await.unwrap();
                let status = response.status().as_u16();
                let mut body = String::new();
                if status != 200 {
                    return (status, body);
                }
                let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
                loop {
                    let complete = body
                        .split_once(marker.as_str())
                        .is_some_and(|(_, rest)| rest.contains("\n\n"));
                    if complete {
                        break;
                    }
                    match tokio::time::timeout_at(deadline, response.chunk()).await {
                        Ok(Ok(Some(chunk))) => body.push_str(&String::from_utf8_lossy(&chunk)),
                        _ => break,
                    }
                }
                (status, body)
            })
        }

        fn events(&self, core: &ZuTalkCore, room_id: &str) -> (u16, String) {
            self.events_until(core, room_id, "init")
        }

        fn init(&self, core: &ZuTalkCore, room_id: &str) -> Value {
            let (status, body) = self.events(core, room_id);
            assert_eq!(status, 200, "订阅被拒: {body}");
            sse_data(&body, "init").expect("没有 init")
        }
    }

    fn sse_data(body: &str, event: &str) -> Option<Value> {
        let (_, rest) = body.split_once(&format!("event: {event}\ndata: "))?;
        let (data, _) = rest.split_once("\n\n")?;
        serde_json::from_str(data).ok()
    }

    /// 链接拆成房间号与密钥 —— 观看页做的就是这件事。
    fn split_link(url: &str) -> (String, LinkKey) {
        let (page, fragment) = url.split_once("#k=").expect("链接里没有密钥");
        let room_id = page.rsplit('/').next().unwrap().to_string();
        (
            room_id,
            LinkKey::from_fragment(fragment).expect("密钥格式不对"),
        )
    }

    fn wait_until<T>(mut probe: impl FnMut() -> Option<T>) -> T {
        for _ in 0..60 {
            if let Some(value) = probe() {
                return value;
            }
            std::thread::sleep(Duration::from_millis(100));
        }
        panic!("等不到");
    }

    /// 对着一个真的 caption-web 走完整链路:服务器手里只有密文,拿链接里的
    /// 密钥解得开;撤销、锁定、换链接、散场去留都在服务端兑现。
    ///
    /// 默认在本机起一份 `services/caption-web/server.py`(没有 python3 就跳过);
    /// 设了 `LINK_SHARE_SERVICE` 就对着那个地址跑 —— 生产冒烟用这条。
    #[test]
    fn a_link_round_trip_against_the_caption_service() {
        let Some(service) = CaptionService::start() else {
            eprintln!("跳过:本机起不了 caption-web(没有 python3?)");
            return;
        };
        let (_temp, core, _notebook, _run, _doc) =
            crate::notebook_capture_api::tests::projected_core_fixture();
        core.set_link_service_for_test(service.base.clone());

        // ── 录好的录音:只读链接 ──
        let link = core
            .create_recording_link("session-a".into(), "冒烟录音".into())
            .unwrap();
        assert!(link.expires_at_epoch - link.created_at_epoch == RECORDING_LINK_TTL_SECS);
        let (room_id, key) = split_link(&link.url);
        assert_eq!(room_id, link.room_id);
        let (status, events) = service.events_until(&core, &room_id, "ended");
        assert_eq!(status, 200);
        for plain in ["hello", "你好", "冒烟录音"] {
            assert!(!events.contains(plain), "服务器上出现了明文 {plain}");
        }
        assert!(events.contains("event: ended"), "录音链接推完即封笔");
        let init = sse_data(&events, "init").unwrap();
        let meta = key.open(init["meta"]["ct"].as_str().unwrap());
        assert_eq!(meta["title"], "冒烟录音");
        assert_eq!(meta["live"], false);
        assert_eq!(meta["download"], true);
        let part = key.open(init["sessions"][0]["ct"].as_str().unwrap());
        assert_eq!(part["session_id"], "session-a");
        assert!(
            part["blocks"].to_string().contains("你好"),
            "解开的稿里应有译文"
        );
        // 别的密钥解不开。
        let stranger = LinkKey::generate();
        let sealed = URL_SAFE_NO_PAD
            .decode(init["meta"]["ct"].as_str().unwrap())
            .unwrap();
        assert!(vt_crypto::decrypt_chunk(&sealed, &stranger.0).is_err());

        assert_eq!(core.recording_links("session-a".into()), vec![link.clone()]);
        assert_eq!(core.all_recording_links(), vec![link.clone()]);
        assert!(core.recording_links("session-other".into()).is_empty());
        core.revoke_recording_link(link.room_id.clone()).unwrap();
        assert_eq!(service.status(&core, &room_id).0, 404, "撤销即删");
        assert!(core.recording_links("session-a".into()).is_empty());
        assert!(core.all_recording_links().is_empty());

        // ── 直播 ──
        let live = core
            .start_live_link("session-a".into(), "直播冒烟".into(), false)
            .unwrap();
        let (live_room, live_key) = split_link(&live.url);
        let tap = LinkCaptionTap::new(core.live_link.clone());
        // 同时在录的别的录音一帧也不出去。
        tap.broadcast(&preview("session-other", 1));
        tap.broadcast(&preview("session-a", 2));
        let init = wait_until(|| {
            let init = service.init(&core, &live_room);
            let ready = init["frame"].is_object()
                && init["sessions"].as_array().is_some_and(|s| !s.is_empty());
            ready.then_some(init)
        });
        let frame = live_key.open(init["frame"]["ct"].as_str().unwrap());
        assert_eq!(frame["session_id"], "session-a");
        assert_eq!(frame["utterances"][0]["source_text"], "こんにちは");
        assert_eq!(
            frame["cues"].as_array().unwrap().len(),
            1,
            "撤回的 cue 不出去"
        );
        let meta = live_key.open(init["meta"]["ct"].as_str().unwrap());
        assert_eq!(meta["live"], true);
        assert_eq!(meta["download"], false);

        // 暂停:分割线的种类服务器读得到(它要清掉最后一帧),其余在密文里。
        core.push_live_link_segment("session-a", "paused");
        let init = wait_until(|| {
            let init = service.init(&core, &live_room);
            init["segments"]
                .as_array()
                .is_some_and(|s| !s.is_empty())
                .then_some(init)
        });
        assert_eq!(init["segments"][0]["kind"], "paused");
        assert_eq!(
            live_key.open(init["segments"][0]["ct"].as_str().unwrap())["kind"],
            "paused"
        );
        assert!(init["frame"].is_null(), "暂停后半句字幕不该挂着");

        // 观看人数:一个人开着页面。
        let url = format!("{}/v1/rooms/{live_room}/events", service.base);
        let watching = core.runtime.block_on(reqwest::get(url)).unwrap();
        // 前面几次探询的连接已经关了;主持人每问一次,服务端就探一次。
        let refreshed = wait_until(|| core.refresh_live_link().filter(|link| link.viewers == 1));
        assert!(!refreshed.locked);

        // 锁上:在看的不受影响,新的进不来。
        let locked = core.set_live_link_locked(true).unwrap();
        assert!(locked.locked);
        assert_eq!(service.events(&core, &live_room).0, 403);
        assert_eq!(service.status(&core, &live_room).1["locked"], true);
        drop(watching);

        // 换链接:旧链接当场失效,新链接沿用锁。
        let replaced = core.replace_live_link().unwrap();
        assert_ne!(replaced.url, live.url);
        assert!(replaced.locked);
        assert_eq!(service.status(&core, &live_room).0, 404);
        let (fresh_room, _) = split_link(&replaced.url);
        core.set_live_link_locked(false).unwrap();

        if service.local() {
            // 散场后留稿:封笔,观众还读得到;默认不留则当场删。
            core.set_live_link_keeps_after_end(true).unwrap();
            core.stop_live_link().unwrap();
            let (status, body) = service.status(&core, &fresh_room);
            assert_eq!(status, 200);
            assert_eq!(body["ended"], true);
            assert!(core.live_link().is_none());

            core.start_live_link("session-a".into(), "直播冒烟".into(), false)
                .unwrap();
        }
        let (last_room, _) = split_link(&core.live_link().unwrap().url);
        core.stop_live_link().unwrap();
        assert_eq!(
            service.status(&core, &last_room).0,
            404,
            "不留稿的直播散场即删"
        );
        assert!(core.live_link().is_none());
    }
}
