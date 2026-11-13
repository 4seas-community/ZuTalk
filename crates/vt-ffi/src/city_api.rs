//! 交到城的档案馆:登录的居民把一场录音的各语言文字稿签成城的记录,贴到
//! 活动的标签上。
//!
//! 设计见 `docs/architecture/city-archive.md`。协议(签名、连设备、活动与
//! 频道怎么合出来、一场录音切成哪些记录)全在 `vt-city`;这里只管三件事:
//!
//! - **钥匙和账本放在哪。** 签名钥匙的种子进 `Secrets/content-keys.json`,
//!   单独一个名字;说明是谁、在哪座城的那一份和另外两本小账放在
//!   `city/` 下,都是 0600。
//! - **一场录音的事实怎么变成要交的句子。** 只读转录、说话人、标记的位置。
//! - **什么时候发。** 发之前先查这个人交不交得上 —— 活动的标签只验签名,
//!   交不上的东西贴上去也没人看得到,只会留在公开日志里。断网就留在
//!   排队,下次再发;同一份内容重发得到同样的记录,不会交出两份。
//!
//! 音频从不经过这里:不读音频分段,不上传任何文件。

use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::Duration;

use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use vt_city::calendar::CityEvent;
use vt_city::error::CityError;
use vt_city::hub::{city_tag, DoorCity, Hub, ROLE_COORDINATOR, ROLE_CURATOR};
use vt_city::identity::{Identity, StoredIdentity};
use vt_city::link::{LinkSession, LinkStep};
use vt_city::publish::{self, Correction, Sentence, TakeInput, Translated};
use vt_crypto::SessionKey;

use crate::{CoreError, ZuTalkCore};

/// 登录的那把签名钥匙在密钥库里的名字。这个模块只碰这一把。
pub(crate) const CITY_IDENTITY_KEY_REF: &str = "city-identity";
const CITY_DIR: &str = "city";
const ACCOUNT_FILE: &str = "account.json";
const CALENDAR_FILE: &str = "calendar.json";
const FILINGS_FILE: &str = "filings.json";
/// 连设备的房号在服务器上留五分钟。
const LOGIN_TTL_SECS: i64 = 5 * 60;
/// 服务器一次最多收 1 MB,留出余量。
const POST_BYTES: usize = 900 * 1024;
const REQUEST_TIMEOUT: Duration = Duration::from_secs(20);
/// 中转一次最多挂 25 秒才回话。
const RELAY_TIMEOUT: Duration = Duration::from_secs(40);
/// 城里谁能审,问过一次记这么久。任免不常有;过了再问。
const CURATORS_TTL_SECS: i64 = 6 * 60 * 60;
/// 一次取活动最多为这么多人去问城:再多就先用已经知道的。
const CURATOR_LOOKUPS: usize = 40;
/// 精修稿没有逐句的时刻:一段算这么长,只为让各段的先后站得住。
const PARAGRAPH_STEP_MS: i64 = 1_000;

/// 界面按这些键取文案(Localizable.strings 里同名)。
mod code {
    pub const OFFLINE: &str = "city.error.offline";
    pub const SERVER: &str = "city.error.server";
    pub const BAD_ADDRESS: &str = "city.error.bad_address";
    pub const NO_CITY: &str = "city.error.no_city";
    pub const BAD_KEY: &str = "city.error.bad_key";
    pub const SIGNED_OUT: &str = "city.error.signed_out";
    pub const UNBOUND: &str = "city.error.unbound";
    pub const NOT_ALLOWED: &str = "city.error.not_allowed";
    pub const EVENT_GONE: &str = "city.error.event_gone";
    pub const NO_TRANSCRIPT: &str = "city.error.no_transcript";
    pub const REFUSED: &str = "city.error.refused";
    pub const BUSY: &str = "city.error.busy";
}

fn refuse(code: &'static str) -> CoreError {
    CoreError::ValidationFailed {
        message: code.to_string(),
    }
}

fn internal(error: impl std::fmt::Display) -> CoreError {
    CoreError::InternalError {
        message: error.to_string(),
    }
}

/// 城那边出的错只分两种给人看:没连上,和服务器没照办。细节进日志。
fn failure_code(error: &CityError) -> &'static str {
    match error {
        CityError::Offline => code::OFFLINE,
        other => {
            tracing::warn!(error = %other, "city request failed");
            code::SERVER
        }
    }
}

fn city_error(error: CityError) -> CoreError {
    refuse(failure_code(&error))
}

fn now_epoch() -> i64 {
    now_ms() / 1000
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| elapsed.as_millis() as i64)
        .unwrap_or(0)
}

fn digest(text: &str) -> String {
    hex::encode(&Sha256::digest(text.as_bytes())[..8])
}

fn read_json<T: DeserializeOwned>(path: &Path) -> Option<T> {
    std::fs::read(path)
        .ok()
        .and_then(|bytes| serde_json::from_slice(&bytes).ok())
}

/// 账本都这样写:目录 0700、文件 0600,先写临时文件再改名。
fn write_private_json<T: Serialize>(path: &Path, value: &T) -> Result<(), CoreError> {
    use std::io::Write;
    use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
    if let Some(directory) = path.parent() {
        std::fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(directory)
            .map_err(internal)?;
    }
    let temporary = path.with_extension("json.tmp");
    let bytes = serde_json::to_vec(value).map_err(internal)?;
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(&temporary)
        .map_err(internal)?;
    file.write_all(&bytes).map_err(internal)?;
    file.sync_all().map_err(internal)?;
    std::fs::rename(&temporary, path).map_err(internal)
}

// =========================================================================
// 进程里的状态
// =========================================================================

#[derive(Default)]
pub(crate) struct CitySlot {
    /// 正在办的登录;一次只办一个。
    login: Mutex<Option<PendingLogin>>,
    login_generation: std::sync::atomic::AtomicU64,
    /// 账本的读-改-写要排队。
    ledger: Mutex<()>,
    /// 正在交的录音,免得同一场并发发两遍。
    in_flight: Mutex<HashSet<String>>,
}

struct PendingLogin {
    generation: u64,
    server: String,
    city: DoorCity,
    session: LinkSession,
    started_at: i64,
}

struct InFlight<'a> {
    slot: &'a CitySlot,
    session_id: String,
}

impl Drop for InFlight<'_> {
    fn drop(&mut self) {
        if let Ok(mut set) = self.slot.in_flight.lock() {
            set.remove(&self.session_id);
        }
    }
}

// =========================================================================
// 存在本机的几份
// =========================================================================

/// 登录的是谁、在哪座城。签名钥匙的种子不在这里,在密钥库里。
#[derive(Debug, Clone, Serialize, Deserialize)]
struct StoredAccount {
    version: u8,
    server: String,
    city_id: String,
    city_name: String,
    person_id: String,
    person_name: String,
    roles: Vec<String>,
    identity_version: u8,
    controller: Option<String>,
    inception: Value,
    /// 每一批记录前面都要带的那几条(开户记录、名片、DID 日志):读的一方
    /// 凭它认这把签名钥匙。登录时取一次。
    card: Vec<Value>,
    signed_in_at: i64,
}

impl StoredAccount {
    fn snapshot(&self) -> FfiCityAccount {
        FfiCityAccount {
            server: self.server.clone(),
            city_id: self.city_id.clone(),
            city_name: self.city_name.clone(),
            person_id: self.person_id.clone(),
            person_name: self.person_name.clone(),
            roles: self.roles.clone(),
            signed_in_at_epoch: self.signed_in_at,
        }
    }

    fn is_resident(&self) -> bool {
        !self.roles.is_empty()
    }

    /// 协调者。建城人卸任以后还留着「建城人」的名分,所以不看那一项。
    fn is_coordinator(&self) -> bool {
        self.roles.iter().any(|role| role == ROLE_COORDINATOR)
    }

    /// 能审这座城的人:协调者和策展人。收进来的活动归他们管。
    fn is_reviewer(&self) -> bool {
        self.roles
            .iter()
            .any(|role| role == ROLE_COORDINATOR || role == ROLE_CURATOR)
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
struct StoredEvent {
    id: String,
    title: String,
    place: String,
    start_ms: i64,
    end_ms: i64,
    scope: String,
    hosts: Vec<String>,
    crew: Vec<String>,
    /// 从别处的日历收进来的:城里能审的人都算它的主办。
    #[serde(default)]
    imported: bool,
    /// 取消了的活动不拿出来给人选,可它在城里还在:交过的素材照样看得到。
    #[serde(default)]
    cancelled: bool,
}

impl StoredEvent {
    fn of(event: &CityEvent) -> Self {
        Self {
            id: event.id.clone(),
            title: event.title.clone(),
            place: event.place.clone(),
            start_ms: event.start_ms,
            end_ms: event.end_ms,
            scope: event.scope.clone(),
            hosts: event.hosts.clone(),
            crew: event.crew.clone(),
            imported: event.imported,
            cancelled: event.cancelled,
        }
    }

    fn involves(&self, person_id: &str) -> bool {
        self.hosts.iter().any(|id| id == person_id) || self.crew.iter().any(|id| id == person_id)
    }

    fn snapshot(&self, person_id: &str) -> FfiCityEvent {
        FfiCityEvent {
            id: self.id.clone(),
            title: self.title.clone(),
            place: self.place.clone(),
            start_ms: self.start_ms,
            end_ms: self.end_ms,
            residents_only: self.scope == "polis",
            mine: self.involves(person_id),
        }
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
struct StoredChannel {
    id: String,
    title: String,
}

impl StoredChannel {
    fn snapshot(&self) -> FfiCityChannel {
        FfiCityChannel {
            id: self.id.clone(),
            title: self.title.clone(),
        }
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
struct StoredCalendar {
    fetched_at: i64,
    events: Vec<StoredEvent>,
    /// 这个人能往里放东西的频道。
    channels: Vec<StoredChannel>,
    /// 问过城的:这个身份号算不算能审的人(或者是城授权的那把收活动的钥匙)。
    #[serde(default)]
    curators: BTreeMap<String, bool>,
    #[serde(default)]
    curators_checked_at: i64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
struct StoredOptions {
    speaker_names: bool,
    marks: bool,
    automatic: bool,
}

impl Default for StoredOptions {
    fn default() -> Self {
        Self {
            speaker_names: true,
            marks: true,
            automatic: true,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum FilingState {
    Bound,
    Queued,
    Filed,
    Failed,
    Withdrawn,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct StoredFiling {
    event_id: String,
    event_title: String,
    event_start_ms: i64,
    state: FilingState,
    #[serde(default)]
    channel: Option<StoredChannel>,
    /// 第一次动手发的时刻。重发沿用它,同样的内容就签出同样的记录,
    /// 服务器只留一份。
    #[serde(default)]
    built_at_ms: Option<i64>,
    #[serde(default)]
    take_id: Option<String>,
    #[serde(default)]
    block_id: Option<String>,
    #[serde(default)]
    tags: Vec<String>,
    #[serde(default)]
    filed_at: Option<i64>,
    #[serde(default)]
    signer_name: String,
    #[serde(default)]
    languages: BTreeMap<String, u32>,
    #[serde(default)]
    speakers: u32,
    #[serde(default)]
    marks: u32,
    #[serde(default)]
    error_code: Option<String>,
    updated_at: i64,
}

impl StoredFiling {
    fn snapshot(&self, session_id: &str, server: Option<&str>, changed: u32) -> FfiCityFiling {
        let web_url = match (server, &self.block_id, self.state) {
            (Some(server), Some(block), FilingState::Filed) => Some(format!(
                "{}/archive/c/{}/b/{}",
                server.trim_end_matches('/'),
                self.event_id,
                block
            )),
            _ => None,
        };
        FfiCityFiling {
            session_id: session_id.to_string(),
            event_id: self.event_id.clone(),
            event_title: self.event_title.clone(),
            event_start_ms: self.event_start_ms,
            channel_title: self.channel.as_ref().map(|channel| channel.title.clone()),
            state: match self.state {
                FilingState::Bound => FfiCityFilingState::Bound,
                FilingState::Queued => FfiCityFilingState::Queued,
                FilingState::Filed => FfiCityFilingState::Filed,
                FilingState::Failed => FfiCityFilingState::Failed,
                FilingState::Withdrawn => FfiCityFilingState::Withdrawn,
            },
            filed_at_epoch: self.filed_at,
            signer_name: self.signer_name.clone(),
            languages: self
                .languages
                .iter()
                .map(|(language, sentences)| FfiCityLanguageCount {
                    language: language.clone(),
                    sentences: *sentences,
                })
                .collect(),
            speakers: self.speakers,
            marks: self.marks,
            changed_sentences: changed,
            error_code: self.error_code.clone(),
            web_url,
        }
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
struct StoredLedger {
    #[serde(default)]
    options: StoredOptions,
    /// 主题 → 频道。
    #[serde(default)]
    topics: BTreeMap<String, StoredChannel>,
    /// 录音 → 归到哪、交到哪一步了。
    #[serde(default)]
    filings: BTreeMap<String, StoredFiling>,
}

/// 交上去的那一版,按句记着:之后在 ZuTalk 里改了字,凭它数出改了几句、
/// 只发改过的。
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
struct SentCopy {
    /// 录音里的句子 → 交上去时的时刻和内容摘要。
    lines: BTreeMap<String, SentLine>,
    /// 录音里的说话人 → 交上去时用的短号。
    speakers: BTreeMap<String, String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
struct SentLine {
    t_ms: i64,
    source: String,
    lanes: BTreeMap<String, String>,
}

// =========================================================================
// 一场录音 → 要交的句子
// =========================================================================

/// 转录里的一句,连同它的各语言译文。
#[derive(Debug, Clone, PartialEq, Eq)]
struct Line {
    id: String,
    start_ms: i64,
    duration_ms: i64,
    speaker: Option<String>,
    language: Option<String>,
    text: String,
    /// 语言 → 译文;不含原文那一种。
    lanes: BTreeMap<String, String>,
}

/// 给每一句定时刻。城那边拿时刻当句子的名字,同一场里不能重;交过的句子
/// 沿用交上去时的时刻,这样改字才对得上原来那一句。
fn assign_times(lines: &[Line], known: &BTreeMap<String, SentLine>) -> Vec<i64> {
    let mut used: HashSet<i64> = known.values().map(|line| line.t_ms).collect();
    lines
        .iter()
        .map(|line| {
            if let Some(sent) = known.get(&line.id) {
                return sent.t_ms;
            }
            let mut t = line.start_ms.max(0);
            while !used.insert(t) {
                t += 1;
            }
            t
        })
        .collect()
}

/// 说话人的短号:按出场先后 1、2、3。交过的沿用。
fn speaker_labels(lines: &[Line], known: &BTreeMap<String, String>) -> BTreeMap<String, String> {
    let mut labels = known.clone();
    for speaker in lines.iter().filter_map(|line| line.speaker.as_ref()) {
        if !labels.contains_key(speaker) {
            labels.insert(speaker.clone(), (labels.len() + 1).to_string());
        }
    }
    labels
}

fn sent_line(t_ms: i64, line: &Line) -> SentLine {
    SentLine {
        t_ms,
        source: digest(&line.text),
        lanes: line
            .lanes
            .iter()
            .map(|(language, text)| (language.clone(), digest(text)))
            .collect(),
    }
}

/// 每种语言有几句:原文算它自己的语言,译文算译成的语言。
fn language_counts(lines: &[Line]) -> BTreeMap<String, u32> {
    let mut counts = BTreeMap::new();
    for line in lines {
        if let Some(language) = &line.language {
            *counts.entry(language.clone()).or_insert(0) += 1;
        }
        for language in line.lanes.keys() {
            *counts.entry(language.clone()).or_insert(0) += 1;
        }
    }
    counts
}

/// 交上去以后改过的、新出现的句子。
struct Changes {
    fixes: Vec<Correction>,
    added: Vec<Sentence>,
    translations: BTreeMap<String, Vec<Translated>>,
    count: u32,
    copy: SentCopy,
}

fn changes_since(sent: &SentCopy, lines: &[Line]) -> Changes {
    let times = assign_times(lines, &sent.lines);
    let labels = speaker_labels(lines, &sent.speakers);
    let mut changes = Changes {
        fixes: Vec::new(),
        added: Vec::new(),
        translations: BTreeMap::new(),
        count: 0,
        copy: SentCopy {
            lines: sent.lines.clone(),
            speakers: labels.clone(),
        },
    };
    for (line, t_ms) in lines.iter().zip(times) {
        let now = sent_line(t_ms, line);
        let before = sent.lines.get(&line.id);
        if before == Some(&now) {
            continue;
        }
        changes.count += 1;
        let source_changed = before.is_none_or(|before| before.source != now.source);
        match before {
            None => changes.added.push(Sentence {
                t_ms,
                d_ms: line.duration_ms,
                speaker: line
                    .speaker
                    .as_ref()
                    .and_then(|speaker| labels.get(speaker))
                    .cloned()
                    .unwrap_or_default(),
                text: line.text.clone(),
            }),
            Some(_) if source_changed => changes.fixes.push(Correction {
                t_ms,
                text: line.text.clone(),
            }),
            Some(_) => {}
        }
        for (language, text) in &line.lanes {
            let lane_changed =
                before.is_none_or(|before| before.lanes.get(language) != now.lanes.get(language));
            // 原文改了,译文的指纹就对不上了:没改字的译文也要重新签。
            if source_changed || lane_changed {
                changes
                    .translations
                    .entry(language.clone())
                    .or_default()
                    .push(Translated {
                        t_ms,
                        source_text: line.text.clone(),
                        text: text.clone(),
                    });
            }
        }
        changes.copy.lines.insert(line.id.clone(), now);
    }
    changes
}

/// 这个人交不交得上:这一场的主办、记录员,这座城的协调者;收进来的活动
/// 再加上策展人 —— 那种活动城里能审的人都算主办。
fn may_file(event: &StoredEvent, account: &StoredAccount) -> bool {
    event.involves(&account.person_id)
        || account.is_coordinator()
        || (event.imported && account.is_reviewer())
}

/// 说话人短号和句子照城的读法收拾一遍:不然名字对不上,译文也会被当成过时。
fn added_segment(sentence: &Sentence) -> Option<Value> {
    let text: String = sentence
        .text
        .trim()
        .chars()
        .take(publish::SENTENCE_MAX / 2)
        .collect();
    if text.is_empty() {
        return None;
    }
    Some(json!({
        "t": sentence.t_ms,
        "d": sentence.d_ms,
        "sp": publish::speaker_label(&sentence.speaker),
        "text": text,
    }))
}

fn profile_name(card: &[Value]) -> Option<String> {
    card.iter()
        .filter(|record| record["e"]["type"] == "id/profile")
        .max_by_key(|record| record["e"]["at"].as_i64().unwrap_or(0))
        .and_then(|record| record["e"]["body"]["name"].as_str())
        .map(|name| name.trim().to_string())
        .filter(|name| !name.is_empty())
}

fn safe_file_stem(session_id: &str) -> Option<&str> {
    let ok = !session_id.is_empty()
        && session_id.len() <= 80
        && session_id
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_');
    ok.then_some(session_id)
}

impl ZuTalkCore {
    fn city_path(&self, file: &str) -> PathBuf {
        self.data_dir.join(CITY_DIR).join(file)
    }

    fn city_sent_path(&self, session_id: &str) -> Option<PathBuf> {
        safe_file_stem(session_id).map(|stem| self.city_path(&format!("sent-{stem}.json")))
    }

    fn city_hub(&self, server: &str, timeout: Duration) -> Result<Hub, CoreError> {
        // 连不上就早点知道,好再试一次:城的服务器常有一阵连不上,机器本身在线。
        let builder = reqwest::Client::builder()
            .timeout(timeout)
            .connect_timeout(Duration::from_secs(10));
        // 调试构建认 `ZUTALK_CITY_RESOLVE=<主机名>=<地址:端口>`:城的服务器不肯
        // 把自己开在裸 IP 上,对着本机起的那一台联调时要替它解析名字。发布构建
        // 不认。
        #[cfg(debug_assertions)]
        let builder = match std::env::var("ZUTALK_CITY_RESOLVE")
            .ok()
            .as_deref()
            .and_then(|rule| rule.split_once('='))
            .and_then(|(host, address)| Some((host.to_string(), address.parse().ok()?)))
        {
            Some((host, address)) => builder.resolve(&host, address),
            None => builder,
        };
        let http = builder.build().map_err(internal)?;
        Hub::new(server, http).map_err(|_| refuse(code::BAD_ADDRESS))
    }

    /// 登录着的那一位;钥匙不在(被清过)就当没登录。
    fn city_stored_account(&self) -> Option<StoredAccount> {
        if !self.key_store.key_exists(CITY_IDENTITY_KEY_REF) {
            return None;
        }
        read_json(&self.city_path(ACCOUNT_FILE))
    }

    fn city_identity(&self, account: &StoredAccount) -> Result<Identity, CoreError> {
        let key = self
            .key_store
            .load_key(CITY_IDENTITY_KEY_REF)
            .map_err(|_| refuse(code::SIGNED_OUT))?;
        let stored = StoredIdentity {
            version: account.identity_version,
            id: account.person_id.clone(),
            seed: URL_SAFE_NO_PAD.encode(key.as_bytes()),
            controller: account.controller.clone(),
            inception: account.inception.clone(),
        };
        Identity::from_stored(&stored).map_err(|_| refuse(code::SIGNED_OUT))
    }

    fn city_ledger(&self) -> StoredLedger {
        read_json(&self.city_path(FILINGS_FILE)).unwrap_or_default()
    }

    fn with_city_ledger<R>(
        &self,
        change: impl FnOnce(&mut StoredLedger) -> R,
    ) -> Result<R, CoreError> {
        let _guard = self.city.ledger.lock().unwrap();
        let mut ledger = self.city_ledger();
        let result = change(&mut ledger);
        write_private_json(&self.city_path(FILINGS_FILE), &ledger)?;
        Ok(result)
    }

    /// 登录办成了:取角色和名片,钥匙进密钥库,说明写进账本。
    fn finish_city_login(
        &self,
        server: &str,
        city: &DoorCity,
        identity: Identity,
        offered_name: &str,
    ) -> Result<FfiCityAccount, CoreError> {
        let hub = self.city_hub(server, REQUEST_TIMEOUT)?;
        let (roles, card) = self.runtime.block_on(async {
            let roles = hub.roles(&city.id, identity.id()).await.unwrap_or_default();
            let card = hub
                .card(&city.id, &identity)
                .await
                .unwrap_or_else(|_| vec![identity.inception().clone()]);
            (roles, card)
        });
        let offered = offered_name.trim();
        let person_name = if offered.is_empty() {
            profile_name(&card).unwrap_or_default()
        } else {
            offered.to_string()
        };
        let stored = identity.to_stored();
        let mut seed = URL_SAFE_NO_PAD
            .decode(stored.seed.as_bytes())
            .map_err(|_| refuse(code::BAD_KEY))?;
        let bytes: Result<[u8; vt_crypto::KEY_SIZE], _> = seed.as_slice().try_into();
        let kept = bytes.map_err(|_| refuse(code::BAD_KEY)).and_then(|bytes| {
            self.key_store
                .store_key(CITY_IDENTITY_KEY_REF, &SessionKey::from_bytes(bytes))
                .map_err(internal)
        });
        seed.iter_mut().for_each(|byte| *byte = 0);
        kept?;
        let account = StoredAccount {
            version: 1,
            server: hub.base().to_string(),
            city_id: city.id.clone(),
            city_name: city.name.clone(),
            person_id: stored.id.clone(),
            person_name,
            roles,
            identity_version: stored.version,
            controller: stored.controller.clone(),
            inception: stored.inception.clone(),
            card,
            signed_in_at: now_epoch(),
        };
        write_private_json(&self.city_path(ACCOUNT_FILE), &account)?;
        Ok(account.snapshot())
    }

    /// 这场录音现在的句子。实时转录有内容就用它(连同译文和用户的订正);
    /// 只有精修稿的(导入的音频)退回精修稿的各段。
    fn city_lines(&self, session_id: &str) -> Result<Vec<Line>, CoreError> {
        let mut utterances = self
            .notebook_capture_store
            .list_utterances(session_id)
            .map_err(crate::notebook_capture_api::store_error)?;
        utterances.sort_by_key(|utterance| utterance.sequence);
        let mut previous_end = 0i64;
        let mut lines = Vec::new();
        for utterance in &utterances {
            let Some(write) = crate::notebook_capture_api::t2_machine_block_write(utterance) else {
                continue;
            };
            // 原文被撤回、只剩译文的空壳行没有可以当名字的原句,不交。
            if write.text.trim().is_empty() {
                continue;
            }
            let language =
                crate::notebook_capture_api::identified_language(&utterance.source_language);
            let start_ms = utterance
                .source_start_ms
                .map(|ms| ms as i64)
                .unwrap_or(previous_end);
            let end_ms = utterance
                .source_end_ms
                .map(|ms| ms as i64)
                .unwrap_or(start_ms)
                .max(start_ms);
            previous_end = end_ms;
            let lanes = write
                .lanes
                .into_iter()
                .filter(|(lane, text)| Some(lane) != language.as_ref() && !text.trim().is_empty())
                .collect();
            lines.push(Line {
                id: utterance.id.clone(),
                start_ms,
                duration_ms: end_ms - start_ms,
                speaker: utterance.session_speaker_id.clone(),
                language,
                text: write.text,
                lanes,
            });
        }
        if !lines.is_empty() {
            return Ok(lines);
        }
        Ok(self
            .refined_paragraphs(session_id)?
            .into_iter()
            .enumerate()
            .map(|(index, text)| Line {
                id: format!("refined-{index}"),
                start_ms: index as i64 * PARAGRAPH_STEP_MS,
                duration_ms: PARAGRAPH_STEP_MS,
                speaker: None,
                language: None,
                text,
                lanes: BTreeMap::new(),
            })
            .collect())
    }

    /// 说话人的名字:会话内改名优先,其次关联参与者的名字。没起名的不给。
    fn city_speaker_names(&self, session_id: &str) -> HashMap<String, String> {
        let Ok(speakers) = self
            .notebook_capture_store
            .list_session_speakers(session_id)
        else {
            return HashMap::new();
        };
        let participants: HashMap<String, String> = self
            .notebook_capture_store
            .list_participants()
            .map(|values| values.into_iter().map(|p| (p.id, p.display_name)).collect())
            .unwrap_or_default();
        speakers
            .into_iter()
            .filter_map(|speaker| {
                let name = speaker
                    .local_display_name
                    .as_deref()
                    .map(str::trim)
                    .filter(|name| !name.is_empty())
                    .map(str::to_string)
                    .or_else(|| {
                        speaker
                            .participant_id
                            .as_deref()
                            .and_then(|id| participants.get(id))
                            .map(|name| name.trim().to_string())
                            .filter(|name| !name.is_empty())
                    })?;
                Some((speaker.id, name))
            })
            .collect()
    }

    fn city_changed_count(&self, session_id: &str) -> u32 {
        let Some(sent) = self
            .city_sent_path(session_id)
            .and_then(|path| read_json::<SentCopy>(&path))
        else {
            return 0;
        };
        self.city_lines(session_id)
            .map(|lines| changes_since(&sent, &lines).count)
            .unwrap_or(0)
    }

    fn city_filing_snapshot(&self, session_id: &str, with_changes: bool) -> Option<FfiCityFiling> {
        let filing = self.city_ledger().filings.get(session_id).cloned()?;
        let account = self.city_stored_account();
        let changed = if with_changes && filing.state == FilingState::Filed {
            self.city_changed_count(session_id)
        } else {
            0
        };
        let mut snapshot = filing.snapshot(
            session_id,
            account.as_ref().map(|a| a.server.as_str()),
            changed,
        );
        self.city_note_gone(&self.city_calendar_copy(), &filing, &mut snapshot);
        Some(snapshot)
    }

    fn city_calendar_copy(&self) -> StoredCalendar {
        read_json(&self.city_path(CALENDAR_FILE)).unwrap_or_default()
    }

    /// 交上去以后,活动在城里被删了、取消了:素材在城里就看不到了。本机说
    /// 「已交」而城里没有,人会以为没同步 —— 照实标出来。只在活动列表是交了
    /// 以后才读的那一份时才下这个结论。
    fn city_note_gone(
        &self,
        calendar: &StoredCalendar,
        filing: &StoredFiling,
        snapshot: &mut FfiCityFiling,
    ) {
        let read_since = filing
            .filed_at
            .is_some_and(|filed_at| calendar.fetched_at > filed_at);
        // 比「上次没更新成」「上次没撤下来」要紧:素材在城里已经看不到了,
        // 该做的是换一场活动,不是再试一次。
        if filing.state == FilingState::Filed
            && read_since
            && !calendar
                .events
                .iter()
                .any(|event| event.id == filing.event_id)
        {
            snapshot.error_code = Some(code::EVENT_GONE.to_string());
        }
    }

    fn city_set_state(
        &self,
        session_id: &str,
        state: FilingState,
        error_code: Option<&'static str>,
    ) -> Result<(), CoreError> {
        self.with_city_ledger(|ledger| {
            if let Some(filing) = ledger.filings.get_mut(session_id) {
                filing.state = state;
                filing.error_code = error_code.map(str::to_string);
                filing.updated_at = now_epoch();
            }
        })
    }

    fn city_claim(&self, session_id: &str) -> Result<InFlight<'_>, CoreError> {
        let mut set = self.city.in_flight.lock().unwrap();
        if !set.insert(session_id.to_string()) {
            return Err(refuse(code::BUSY));
        }
        Ok(InFlight {
            slot: &self.city,
            session_id: session_id.to_string(),
        })
    }

    /// 从城的标签上重读活动和频道,存一份在本机。
    ///
    /// 只读城的标签,不读活动自己的标签:城的服务器只让居民和它授权的那把
    /// 收活动的钥匙往城的标签上写,「这一条是能审的人签的」才有意义。
    async fn city_read_calendar(
        hub: &Hub,
        account: &StoredAccount,
        previous: &StoredCalendar,
    ) -> Result<StoredCalendar, CityError> {
        let records = hub
            .tag_get(
                &city_tag(&account.city_id),
                vt_city::calendar::CITY_KINDS,
                &[],
            )
            .await?;

        // 收进来的活动占了城里日历的大半,它们的主办是「能审的人」。谁算,
        // 只有城说得准:挨个问,问过的记着。
        let now = now_epoch();
        let fresh = now - previous.curators_checked_at < CURATORS_TTL_SECS;
        let mut known: BTreeMap<String, bool> = if fresh {
            previous.curators.clone()
        } else {
            BTreeMap::new()
        };
        let importers = vt_city::calendar::importers(&records);
        let mut asked = 0usize;
        for candidate in vt_city::calendar::curator_candidates(&records) {
            if candidate == account.person_id {
                known.insert(candidate, account.is_reviewer());
                continue;
            }
            if known.contains_key(&candidate) || asked >= CURATOR_LOOKUPS {
                continue;
            }
            asked += 1;
            // 问不到的不记:下次再问,这一次当它不算。
            if let Ok(roles) = hub.roles(&account.city_id, &candidate).await {
                let reviews = roles
                    .iter()
                    .any(|role| role == ROLE_COORDINATOR || role == ROLE_CURATOR);
                // 在城里什么名分都没有、却签了收进来的活动:那是城授权的钥匙。
                let import_key = roles.is_empty() && importers.contains(&candidate);
                known.insert(candidate, reviews || import_key);
            }
        }
        let curators: Vec<String> = known
            .iter()
            .filter(|(_, curates)| **curates)
            .map(|(id, _)| id.clone())
            .collect();

        let mut events: Vec<StoredEvent> =
            vt_city::calendar::reduce_events_curated(&records, &curators)
                .iter()
                .map(StoredEvent::of)
                .collect();
        events.sort_by(|a, b| (a.start_ms, &a.id).cmp(&(b.start_ms, &b.id)));
        let mut channels: Vec<StoredChannel> = vt_city::channels::reduce_channels(&records)
            .iter()
            .filter(|channel| {
                vt_city::channels::may_put(
                    channel,
                    &account.person_id,
                    account.is_resident(),
                    account.is_coordinator(),
                )
            })
            .map(|channel| StoredChannel {
                id: channel.id.clone(),
                title: channel.title.clone(),
            })
            .collect();
        channels.sort_by(|a, b| a.title.cmp(&b.title));
        Ok(StoredCalendar {
            fetched_at: now,
            events,
            channels,
            curators: known,
            curators_checked_at: if fresh {
                previous.curators_checked_at
            } else {
                now
            },
        })
    }

    fn city_refresh_calendar(
        &self,
        hub: &Hub,
        account: &StoredAccount,
    ) -> Result<StoredCalendar, CityError> {
        let previous: StoredCalendar =
            read_json(&self.city_path(CALENDAR_FILE)).unwrap_or_default();
        let calendar = self
            .runtime
            .block_on(Self::city_read_calendar(hub, account, &previous))?;
        // 存不下不算读失败:这一次照样用刚读到的。
        if let Err(error) = write_private_json(&self.city_path(CALENDAR_FILE), &calendar) {
            tracing::warn!(?error, "city calendar copy was not saved");
        }
        Ok(calendar)
    }

    /// 每一批记录前面带的名片。换过签名钥匙的人,名片里要有他的 DID 日志,
    /// 城的服务器凭它认这把钥匙;登录时没取到就在这里补取。
    fn city_card(&self, hub: &Hub, account: &StoredAccount, identity: &Identity) -> Vec<Value> {
        let has_log = account
            .card
            .iter()
            .any(|record| record["e"]["type"] == "id/did");
        if identity.signs_with_inception_key() || has_log {
            return account.card.clone();
        }
        let Ok(card) = self.runtime.block_on(hub.card(&account.city_id, identity)) else {
            return account.card.clone();
        };
        let mut refreshed = account.clone();
        refreshed.card = card.clone();
        if let Err(error) = write_private_json(&self.city_path(ACCOUNT_FILE), &refreshed) {
            tracing::warn!(?error, "city card was not saved");
        }
        card
    }

    /// 把一批记录贴到这几个标签,每个标签只贴它该收的那几种。活动的标签必须
    /// 收下;城的标签尽力而为 —— 签的人不是居民时它不收,活动页照样读得到。
    async fn city_post(
        hub: &Hub,
        tags: &[String],
        card: &[Value],
        records: &[Value],
    ) -> Result<(), CityError> {
        for (index, tag) in tags.iter().enumerate() {
            let wanted = publish::for_tag(tag, records);
            let ours: HashSet<String> = wanted
                .iter()
                .filter_map(vt_city::record::signature_of)
                .collect();
            for batch in publish::batches(card, &wanted, POST_BYTES) {
                let outcome = match hub.tag_post(tag, &batch).await {
                    Ok(outcome) => outcome,
                    Err(error) if index > 0 => {
                        tracing::warn!(error = %error, "city tag did not take the filing");
                        break;
                    }
                    Err(error) => return Err(error),
                };
                let turned_away = outcome
                    .refused
                    .iter()
                    .any(|signature| ours.contains(signature));
                if turned_away && index == 0 {
                    return Err(CityError::Refused);
                }
                if turned_away {
                    tracing::warn!("city tag turned the filing away");
                    break;
                }
            }
        }
        Ok(())
    }

    fn city_file(&self, session_id: &str) -> Result<FfiCityFiling, CoreError> {
        let account = self
            .city_stored_account()
            .ok_or_else(|| refuse(code::SIGNED_OUT))?;
        let _claim = self.city_claim(session_id)?;
        let built_at_ms = now_ms();
        let filing = self
            .with_city_ledger(|ledger| {
                let filing = ledger.filings.get_mut(session_id)?;
                if filing.state == FilingState::Filed {
                    return Some(filing.clone());
                }
                if filing.state == FilingState::Withdrawn {
                    // 撤下以后再交是另一件素材。
                    filing.built_at_ms = None;
                    filing.take_id = None;
                    filing.block_id = None;
                }
                filing.state = FilingState::Queued;
                filing.error_code = None;
                filing.built_at_ms.get_or_insert(built_at_ms);
                filing.updated_at = now_epoch();
                Some(filing.clone())
            })?
            .ok_or_else(|| refuse(code::UNBOUND))?;
        if filing.state == FilingState::Filed {
            return self
                .city_filing_snapshot(session_id, true)
                .ok_or_else(|| refuse(code::UNBOUND));
        }
        let outcome = self.city_send(session_id, &account, &filing);
        match outcome {
            Ok(()) => {}
            // 没连上:留在排队,联网后、下次启动时再发。
            Err(code::OFFLINE) => {
                self.city_set_state(session_id, FilingState::Queued, Some(code::OFFLINE))?
            }
            Err(error_code) => {
                self.city_set_state(session_id, FilingState::Failed, Some(error_code))?
            }
        }
        self.city_filing_snapshot(session_id, false)
            .ok_or_else(|| refuse(code::UNBOUND))
    }

    /// 真正发出去的那一步。出错给回界面用的键。
    fn city_send(
        &self,
        session_id: &str,
        account: &StoredAccount,
        filing: &StoredFiling,
    ) -> Result<(), &'static str> {
        let identity = self.city_identity(account).map_err(|_| code::SIGNED_OUT)?;
        let hub = self
            .city_hub(&account.server, REQUEST_TIMEOUT)
            .map_err(|_| code::BAD_ADDRESS)?;
        // 现取一遍:主办、记录员可能刚改过,活动也可能刚被取消。
        let event = self
            .city_refresh_calendar(&hub, account)
            .map_err(|error| failure_code(&error))?
            .events
            .into_iter()
            .find(|event| event.id == filing.event_id && !event.cancelled)
            // 活动在城里被删了、取消了:不往一场没办的活动里交。
            .ok_or(code::EVENT_GONE)?;
        if !may_file(&event, account) {
            return Err(code::NOT_ALLOWED);
        }

        let lines = self.city_lines(session_id).map_err(|_| code::SERVER)?;
        if lines.is_empty() {
            return Err(code::NO_TRANSCRIPT);
        }
        let ledger = self.city_ledger();
        let options = ledger.options;
        // 目录里没有这一场(不该有,可也别因此交不上):题目和时长另想办法。
        let record = self.session_store.get_session(session_id).ok();
        let channel = self
            .notebook_store
            .get_linked_notebook_id(session_id)
            .ok()
            .flatten()
            .and_then(|notebook| ledger.topics.get(&notebook).cloned());

        let times = assign_times(&lines, &BTreeMap::new());
        let labels = speaker_labels(&lines, &BTreeMap::new());
        let mut translations: BTreeMap<String, Vec<Translated>> = BTreeMap::new();
        let mut sentences = Vec::with_capacity(lines.len());
        let mut copy = SentCopy {
            lines: BTreeMap::new(),
            speakers: labels.clone(),
        };
        for (line, t_ms) in lines.iter().zip(times) {
            sentences.push(Sentence {
                t_ms,
                d_ms: line.duration_ms,
                speaker: line
                    .speaker
                    .as_ref()
                    .and_then(|speaker| labels.get(speaker))
                    .cloned()
                    .unwrap_or_default(),
                text: line.text.clone(),
            });
            for (language, text) in &line.lanes {
                translations
                    .entry(language.clone())
                    .or_default()
                    .push(Translated {
                        t_ms,
                        source_text: line.text.clone(),
                        text: text.clone(),
                    });
            }
            copy.lines.insert(line.id.clone(), sent_line(t_ms, line));
        }
        let names = if options.speaker_names {
            self.city_speaker_names(session_id)
        } else {
            HashMap::new()
        };
        let speakers: Vec<(String, String)> = labels
            .iter()
            .filter_map(|(speaker, label)| Some((label.clone(), names.get(speaker)?.clone())))
            .collect();
        let marks_ms: Vec<i64> = if options.marks {
            self.session_marks
                .list(session_id)
                .map(|marks| marks.iter().map(|mark| mark.start_ms as i64).collect())
                .unwrap_or_default()
        } else {
            Vec::new()
        };
        let started_ms = record
            .as_ref()
            .and_then(|record| chrono::DateTime::parse_from_rfc3339(&record.created_at).ok())
            .map(|at| at.timestamp_millis())
            .unwrap_or_else(|| filing.built_at_ms.unwrap_or_else(now_ms));
        let spoken_ms = lines
            .last()
            .map(|line| line.start_ms + line.duration_ms)
            .unwrap_or(0);
        let duration_ms = record
            .as_ref()
            .map(|record| record.duration_ms as i64)
            .unwrap_or(0)
            .max(spoken_ms);
        let title = record
            .as_ref()
            .map(|record| record.title.trim().to_string())
            .filter(|title| !title.is_empty())
            .unwrap_or_else(|| event.title.clone());
        let input = TakeInput {
            event_id: event.id.clone(),
            title,
            started_ms,
            duration_ms,
            sentences,
            translations: translations.into_iter().collect(),
            speakers: speakers.clone(),
            marks_ms: marks_ms.clone(),
            channel_ids: channel.iter().map(|channel| channel.id.clone()).collect(),
        };
        let built =
            publish::build_take(&identity, &input, filing.built_at_ms.unwrap_or_else(now_ms))
                .map_err(|error| failure_code(&error))?;
        let as_event = CityEvent {
            id: event.id.clone(),
            title: event.title.clone(),
            place: event.place.clone(),
            tz: String::new(),
            scope: event.scope.clone(),
            city: account.city_id.clone(),
            by: String::new(),
            start_ms: event.start_ms,
            end_ms: event.end_ms,
            hosts: event.hosts.clone(),
            crew: event.crew.clone(),
            cancelled: false,
            imported: event.imported,
        };
        // 城自己的录制还要求首位主办也是居民才贴城的标签。收进来的活动签的
        // 是城授权的钥匙,不是居民,可它们正是归城管的活动:档案馆和主题的
        // 频道都从城的标签上读,所以这里只看交的人是不是居民。
        let tags = vt_city::calendar::recording_tags(&as_event, account.is_resident());
        let card = self.city_card(&hub, account, &identity);
        self.runtime
            .block_on(Self::city_post(&hub, &tags, &card, &built.records))
            .map_err(|error| match error {
                CityError::Refused => code::REFUSED,
                other => failure_code(&other),
            })?;

        if let Some(path) = self.city_sent_path(session_id) {
            write_private_json(&path, &copy).map_err(|_| code::SERVER)?;
        }
        let languages = language_counts(&lines);
        self.with_city_ledger(|ledger| {
            if let Some(filing) = ledger.filings.get_mut(session_id) {
                filing.state = FilingState::Filed;
                filing.error_code = None;
                filing.event_title = event.title.clone();
                filing.event_start_ms = event.start_ms;
                filing.channel = channel.clone();
                filing.take_id = Some(built.take_id.clone());
                filing.block_id = Some(built.block_id.clone());
                filing.tags = tags.clone();
                filing.filed_at = Some(now_epoch());
                filing.signer_name = account.person_name.clone();
                filing.languages = languages;
                filing.speakers = speakers.len() as u32;
                filing.marks = marks_ms.len() as u32;
                filing.updated_at = now_epoch();
            }
        })
        .map_err(|_| code::SERVER)
    }

    fn city_update(&self, session_id: &str) -> Result<(), &'static str> {
        let account = self.city_stored_account().ok_or(code::SIGNED_OUT)?;
        let filing = self
            .city_ledger()
            .filings
            .get(session_id)
            .cloned()
            .ok_or(code::UNBOUND)?;
        let (Some(take_id), FilingState::Filed) = (filing.take_id.clone(), filing.state) else {
            return Err(code::UNBOUND);
        };
        let sent_path = self.city_sent_path(session_id).ok_or(code::UNBOUND)?;
        let sent: SentCopy = read_json(&sent_path).unwrap_or_default();
        let lines = self.city_lines(session_id).map_err(|_| code::SERVER)?;
        let changes = changes_since(&sent, &lines);
        if changes.count == 0 {
            return Ok(());
        }
        let identity = self.city_identity(&account).map_err(|_| code::SIGNED_OUT)?;
        let at_ms = now_ms();
        let mut records = Vec::new();
        if !changes.added.is_empty() {
            let segs: Vec<Value> = changes.added.iter().filter_map(added_segment).collect();
            let added = vt_city::record::make(
                &identity,
                "tape/text",
                json!({ "segs": segs }),
                std::slice::from_ref(&take_id),
                &[identity.id().to_string()],
                at_ms,
            )
            .map_err(|error| failure_code(&error))?;
            records.push(added.rec);
        }
        let translations: Vec<(String, Vec<Translated>)> =
            changes.translations.into_iter().collect();
        records.extend(
            publish::build_update(
                &identity,
                &take_id,
                &changes.fixes,
                &translations,
                at_ms + 1,
            )
            .map_err(|error| failure_code(&error))?,
        );
        let hub = self
            .city_hub(&account.server, REQUEST_TIMEOUT)
            .map_err(|_| code::BAD_ADDRESS)?;
        let card = self.city_card(&hub, &account, &identity);
        self.runtime
            .block_on(Self::city_post(&hub, &filing.tags, &card, &records))
            .map_err(|error| match error {
                CityError::Refused => code::REFUSED,
                other => failure_code(&other),
            })?;
        write_private_json(&sent_path, &changes.copy).map_err(|_| code::SERVER)?;
        let languages = language_counts(&lines);
        self.with_city_ledger(|ledger| {
            if let Some(filing) = ledger.filings.get_mut(session_id) {
                filing.languages = languages;
                filing.filed_at = Some(now_epoch());
                filing.updated_at = now_epoch();
            }
        })
        .map_err(|_| code::SERVER)
    }

    fn city_withdraw(&self, session_id: &str) -> Result<(), &'static str> {
        let account = self.city_stored_account().ok_or(code::SIGNED_OUT)?;
        let filing = self
            .city_ledger()
            .filings
            .get(session_id)
            .cloned()
            .ok_or(code::UNBOUND)?;
        let (Some(block_id), FilingState::Filed) = (filing.block_id.clone(), filing.state) else {
            return Err(code::UNBOUND);
        };
        let identity = self.city_identity(&account).map_err(|_| code::SIGNED_OUT)?;
        let records = publish::build_withdraw(&identity, &block_id, now_ms())
            .map_err(|error| failure_code(&error))?;
        let hub = self
            .city_hub(&account.server, REQUEST_TIMEOUT)
            .map_err(|_| code::BAD_ADDRESS)?;
        let card = self.city_card(&hub, &account, &identity);
        self.runtime
            .block_on(Self::city_post(&hub, &filing.tags, &card, &records))
            .map_err(|error| match error {
                CityError::Refused => code::REFUSED,
                other => failure_code(&other),
            })?;
        if let Some(path) = self.city_sent_path(session_id) {
            let _ = std::fs::remove_file(path);
        }
        self.city_set_state(session_id, FilingState::Withdrawn, None)
            .map_err(|_| code::SERVER)
    }
}

// =========================================================================
// FFI
// =========================================================================

/// 登录着的居民。
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiCityAccount {
    pub server: String,
    pub city_id: String,
    pub city_name: String,
    pub person_id: String,
    pub person_name: String,
    /// 城签给这个人的身份:resident、founder、coordinator、curator、inviter。
    /// 空着就是还不是这座城的居民。
    pub roles: Vec<String>,
    pub signed_in_at_epoch: i64,
}

/// 给旧设备扫的码。
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiCityLoginOffer {
    /// 二维码与「复制码」的内容。
    pub code: String,
    pub server: String,
    pub city_name: String,
    pub expires_at_epoch: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum FfiCityLoginStep {
    /// 还没有新消息,接着问。
    Waiting,
    /// 旧设备扫过了:两边各显示这个六位数,等那一边的人确认。
    Check {
        digits: String,
    },
    Done {
        account: FfiCityAccount,
    },
    /// 那一边点了「不一致」,或者这一边取消了。
    Cancelled,
    /// 五分钟没办成,码作废了。
    Expired,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiCityEvent {
    pub id: String,
    pub title: String,
    pub place: String,
    pub start_ms: i64,
    pub end_ms: i64,
    /// 只给居民看的活动。
    pub residents_only: bool,
    /// 登录的人是这一场的主办或记录员。
    pub mine: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiCityCalendar {
    pub events: Vec<FfiCityEvent>,
    /// 0 是还没取过。
    pub fetched_at_epoch: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiCityChannel {
    pub id: String,
    pub title: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct FfiCityFilingOptions {
    pub speaker_names: bool,
    pub marks: bool,
    /// 停止录音后自己去交;关着就等人按。
    pub automatic: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FfiCityFilingState {
    /// 选好了活动,还没交。
    Bound,
    /// 该交了:正在发,或者在等网络。
    Queued,
    Filed,
    Failed,
    Withdrawn,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiCityLanguageCount {
    pub language: String,
    pub sentences: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiCityFiling {
    pub session_id: String,
    pub event_id: String,
    pub event_title: String,
    pub event_start_ms: i64,
    pub channel_title: Option<String>,
    pub state: FfiCityFilingState,
    pub filed_at_epoch: Option<i64>,
    pub signer_name: String,
    pub languages: Vec<FfiCityLanguageCount>,
    pub speakers: u32,
    pub marks: u32,
    /// 交上去以后在这台 Mac 上改过、还没更新过去的句数。
    pub changed_sentences: u32,
    pub error_code: Option<String>,
    /// 档案馆里这件素材的网址。
    pub web_url: Option<String>,
}

#[uniffi::export]
impl ZuTalkCore {
    pub fn city_account(&self) -> Option<FfiCityAccount> {
        self.city_stored_account().map(|account| account.snapshot())
    }

    /// 开始登录:问这个地址是哪座城,出一个给旧设备扫的码。走网络。
    pub fn city_login_begin(&self, server: String) -> Result<FfiCityLoginOffer, CoreError> {
        let hub = self.city_hub(&server, REQUEST_TIMEOUT)?;
        let door = self.runtime.block_on(hub.door()).map_err(city_error)?;
        let city = door.city.ok_or_else(|| refuse(code::NO_CITY))?;
        let session = LinkSession::new().map_err(city_error)?;
        let started_at = now_epoch();
        let offer = FfiCityLoginOffer {
            code: session.code(),
            server: hub.base().to_string(),
            city_name: city.name.clone(),
            expires_at_epoch: started_at + LOGIN_TTL_SECS,
        };
        let generation = self
            .city
            .login_generation
            .fetch_add(1, std::sync::atomic::Ordering::SeqCst)
            + 1;
        *self.city.login.lock().unwrap() = Some(PendingLogin {
            generation,
            server: hub.base().to_string(),
            city,
            session,
            started_at,
        });
        Ok(offer)
    }

    /// 等旧设备的下一句话,最多挂二十几秒。走网络,调用方在后台线程上循环调。
    pub fn city_login_poll(&self) -> Result<FfiCityLoginStep, CoreError> {
        let (generation, server, room, since, started_at) = {
            let guard = self.city.login.lock().unwrap();
            let Some(pending) = guard.as_ref() else {
                return Ok(FfiCityLoginStep::Cancelled);
            };
            (
                pending.generation,
                pending.server.clone(),
                pending.session.room().to_string(),
                pending.session.since(),
                pending.started_at,
            )
        };
        if now_epoch() - started_at > LOGIN_TTL_SECS {
            self.city_login_cancel();
            return Ok(FfiCityLoginStep::Expired);
        }
        let hub = self.city_hub(&server, RELAY_TIMEOUT)?;
        let (messages, n) = self
            .runtime
            .block_on(hub.relay_get(&room, since))
            .map_err(city_error)?;
        let step = {
            let mut guard = self.city.login.lock().unwrap();
            // 等的这一会儿里取消了、换了一个码:这一句不作数。
            let Some(pending) = guard
                .as_mut()
                .filter(|pending| pending.generation == generation)
            else {
                return Ok(FfiCityLoginStep::Cancelled);
            };
            pending.session.absorb(&messages, n).map_err(city_error)?
        };
        match step {
            LinkStep::Waiting => Ok(FfiCityLoginStep::Waiting),
            LinkStep::Check(digits) => Ok(FfiCityLoginStep::Check { digits }),
            LinkStep::Cancelled => {
                self.city_login_cancel();
                Ok(FfiCityLoginStep::Cancelled)
            }
            LinkStep::Done { identity, name } => {
                let Some(pending) = self.city.login.lock().unwrap().take() else {
                    return Ok(FfiCityLoginStep::Cancelled);
                };
                let account =
                    self.finish_city_login(&pending.server, &pending.city, identity, &name)?;
                Ok(FfiCityLoginStep::Done { account })
            }
        }
    }

    pub fn city_login_cancel(&self) {
        *self.city.login.lock().unwrap() = None;
    }

    /// 没有别的设备在手边时:直接填恢复密钥。走网络。
    pub fn city_login_with_recovery_key(
        &self,
        server: String,
        recovery_key: String,
    ) -> Result<FfiCityAccount, CoreError> {
        let identity =
            Identity::from_key_string(&recovery_key).map_err(|_| refuse(code::BAD_KEY))?;
        let hub = self.city_hub(&server, REQUEST_TIMEOUT)?;
        let door = self.runtime.block_on(hub.door()).map_err(city_error)?;
        let city = door.city.ok_or_else(|| refuse(code::NO_CITY))?;
        self.city_login_cancel();
        self.finish_city_login(hub.base(), &city, identity, "")
    }

    /// 退出登录:钥匙和说明从这台 Mac 上删掉。交过什么的账留着。
    pub fn city_sign_out(&self) -> Result<(), CoreError> {
        self.city_login_cancel();
        if self.key_store.key_exists(CITY_IDENTITY_KEY_REF) {
            self.key_store
                .delete_key(CITY_IDENTITY_KEY_REF)
                .map_err(internal)?;
        }
        for file in [ACCOUNT_FILE, CALENDAR_FILE] {
            match std::fs::remove_file(self.city_path(file)) {
                Ok(()) => {}
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                Err(error) => return Err(internal(error)),
            }
        }
        Ok(())
    }

    pub fn city_filing_options(&self) -> FfiCityFilingOptions {
        let options = self.city_ledger().options;
        FfiCityFilingOptions {
            speaker_names: options.speaker_names,
            marks: options.marks,
            automatic: options.automatic,
        }
    }

    pub fn set_city_filing_options(&self, options: FfiCityFilingOptions) -> Result<(), CoreError> {
        self.with_city_ledger(|ledger| {
            ledger.options = StoredOptions {
                speaker_names: options.speaker_names,
                marks: options.marks,
                automatic: options.automatic,
            };
        })
    }

    /// 城的活动。`refresh` 时走网络重新取;否则给本机存着的那一份。
    pub fn city_calendar(&self, refresh: bool) -> Result<FfiCityCalendar, CoreError> {
        let account = self
            .city_stored_account()
            .ok_or_else(|| refuse(code::SIGNED_OUT))?;
        if refresh {
            let hub = self.city_hub(&account.server, REQUEST_TIMEOUT)?;
            self.city_refresh_calendar(&hub, &account)
                .map_err(city_error)?;
        }
        let stored: StoredCalendar = read_json(&self.city_path(CALENDAR_FILE)).unwrap_or_default();
        Ok(FfiCityCalendar {
            events: stored
                .events
                .iter()
                .filter(|event| !event.cancelled)
                .map(|event| event.snapshot(&account.person_id))
                .collect(),
            fetched_at_epoch: stored.fetched_at,
        })
    }

    /// 这个人能往里放东西的频道,按上一次取活动时的样子。
    pub fn city_channels(&self) -> Vec<FfiCityChannel> {
        read_json::<StoredCalendar>(&self.city_path(CALENDAR_FILE))
            .unwrap_or_default()
            .channels
            .iter()
            .map(StoredChannel::snapshot)
            .collect()
    }

    pub fn city_topic_channel(&self, notebook_id: String) -> Option<FfiCityChannel> {
        self.city_ledger()
            .topics
            .get(&notebook_id)
            .map(StoredChannel::snapshot)
    }

    pub fn set_city_topic_channel(
        &self,
        notebook_id: String,
        channel: Option<FfiCityChannel>,
    ) -> Result<(), CoreError> {
        self.with_city_ledger(|ledger| match channel {
            Some(channel) => {
                ledger.topics.insert(
                    notebook_id,
                    StoredChannel {
                        id: channel.id,
                        title: channel.title,
                    },
                );
            }
            None => {
                ledger.topics.remove(&notebook_id);
            }
        })
    }

    /// 这场录音归到哪场活动;`event` 为空就是这场不交。录之前、录音中、
    /// 录完以后都能改;已经交上去的要先撤下。
    pub fn city_bind_session(
        &self,
        session_id: String,
        event: Option<FfiCityEvent>,
    ) -> Result<Option<FfiCityFiling>, CoreError> {
        if safe_file_stem(&session_id).is_none() {
            return Err(refuse(code::UNBOUND));
        }
        let signer_name = self
            .city_stored_account()
            .map(|account| account.person_name)
            .unwrap_or_default();
        self.with_city_ledger(|ledger| {
            let filed = ledger
                .filings
                .get(&session_id)
                .is_some_and(|filing| filing.state == FilingState::Filed);
            if filed {
                return;
            }
            match event {
                Some(event) => {
                    ledger.filings.insert(
                        session_id.clone(),
                        StoredFiling {
                            event_id: event.id,
                            event_title: event.title,
                            event_start_ms: event.start_ms,
                            state: FilingState::Bound,
                            channel: None,
                            built_at_ms: None,
                            take_id: None,
                            block_id: None,
                            tags: Vec::new(),
                            filed_at: None,
                            signer_name,
                            languages: BTreeMap::new(),
                            speakers: 0,
                            marks: 0,
                            error_code: None,
                            updated_at: now_epoch(),
                        },
                    );
                }
                None => {
                    ledger.filings.remove(&session_id);
                }
            }
        })?;
        Ok(self.city_filing_snapshot(&session_id, false))
    }

    /// 这场录音交到哪一步了,连同交上去以后改了几句。长录音别在主线程上调。
    pub fn city_filing(&self, session_id: String) -> Option<FfiCityFiling> {
        self.city_filing_snapshot(&session_id, true)
    }

    /// 归过活动的录音,最近动过的在前。设置里「已交到档案馆」据此列出。
    pub fn city_filings(&self) -> Vec<FfiCityFiling> {
        let account = self.city_stored_account();
        let server = account.as_ref().map(|account| account.server.as_str());
        let ledger = self.city_ledger();
        let mut filings: Vec<(&String, &StoredFiling)> = ledger.filings.iter().collect();
        filings.sort_by(|a, b| b.1.updated_at.cmp(&a.1.updated_at));
        let calendar = self.city_calendar_copy();
        filings
            .into_iter()
            .map(|(session_id, filing)| {
                let mut snapshot = filing.snapshot(session_id, server, 0);
                self.city_note_gone(&calendar, filing, &mut snapshot);
                snapshot
            })
            .collect()
    }

    /// 交到档案馆。走网络。没连上时留在排队,给回的那一份写着。
    pub fn city_file_session(&self, session_id: String) -> Result<FfiCityFiling, CoreError> {
        self.city_file(&session_id)
    }

    /// 把交上去以后改过的句子更新过去。走网络。
    pub fn city_update_filing(&self, session_id: String) -> Result<FfiCityFiling, CoreError> {
        let _claim = self.city_claim(&session_id)?;
        if let Err(error_code) = self.city_update(&session_id) {
            if matches!(error_code, code::SIGNED_OUT | code::UNBOUND) {
                return Err(refuse(error_code));
            }
            // 没更新成:素材还在档案馆,只是旧的。状态不动,原因写上。
            self.with_city_ledger(|ledger| {
                if let Some(filing) = ledger.filings.get_mut(&session_id) {
                    filing.error_code = Some(error_code.to_string());
                }
            })?;
        } else {
            self.with_city_ledger(|ledger| {
                if let Some(filing) = ledger.filings.get_mut(&session_id) {
                    filing.error_code = None;
                }
            })?;
        }
        self.city_filing_snapshot(&session_id, true)
            .ok_or_else(|| refuse(code::UNBOUND))
    }

    /// 从档案馆撤下。走网络。
    pub fn city_withdraw_filing(&self, session_id: String) -> Result<FfiCityFiling, CoreError> {
        let _claim = self.city_claim(&session_id)?;
        if let Err(error_code) = self.city_withdraw(&session_id) {
            if matches!(error_code, code::SIGNED_OUT | code::UNBOUND) {
                return Err(refuse(error_code));
            }
            self.with_city_ledger(|ledger| {
                if let Some(filing) = ledger.filings.get_mut(&session_id) {
                    filing.error_code = Some(error_code.to_string());
                }
            })?;
        }
        self.city_filing_snapshot(&session_id, false)
            .ok_or_else(|| refuse(code::UNBOUND))
    }

    /// 还在排队的录音。启动时、网络回来时照这份单子重发。
    pub fn city_pending_sessions(&self) -> Vec<String> {
        self.city_ledger()
            .filings
            .iter()
            .filter(|(_, filing)| filing.state == FilingState::Queued)
            .map(|(session_id, _)| session_id.clone())
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn line(id: &str, start_ms: i64, text: &str, lanes: &[(&str, &str)]) -> Line {
        Line {
            id: id.to_string(),
            start_ms,
            duration_ms: 900,
            speaker: Some("speaker-a".to_string()),
            language: Some("en".to_string()),
            text: text.to_string(),
            lanes: lanes
                .iter()
                .map(|(language, text)| (language.to_string(), text.to_string()))
                .collect(),
        }
    }

    fn copy_of(lines: &[Line]) -> SentCopy {
        let times = assign_times(lines, &BTreeMap::new());
        SentCopy {
            lines: lines
                .iter()
                .zip(times)
                .map(|(line, t_ms)| (line.id.clone(), sent_line(t_ms, line)))
                .collect(),
            speakers: speaker_labels(lines, &BTreeMap::new()),
        }
    }

    #[test]
    fn sentences_that_start_together_still_get_distinct_times() {
        let lines = [
            line("a", 1_000, "one", &[]),
            line("b", 1_000, "two", &[]),
            line("c", 1_001, "three", &[]),
        ];
        let times = assign_times(&lines, &BTreeMap::new());
        assert_eq!(times, vec![1_000, 1_001, 1_002]);
    }

    #[test]
    fn a_filed_sentence_keeps_its_time_when_an_earlier_one_appears_later() {
        let filed = [line("b", 1_000, "two", &[])];
        let sent = copy_of(&filed);
        let now = [line("a", 1_000, "one", &[]), line("b", 1_000, "two", &[])];
        let times = assign_times(&now, &sent.lines);
        assert_eq!(times[1], 1_000, "交过的那一句沿用原来的时刻");
        assert_ne!(times[0], times[1]);
    }

    #[test]
    fn nothing_changed_means_nothing_to_send() {
        let lines = [line("a", 0, "hello", &[("zh", "你好")])];
        let changes = changes_since(&copy_of(&lines), &lines);
        assert_eq!(changes.count, 0);
        assert!(changes.fixes.is_empty() && changes.added.is_empty());
        assert!(changes.translations.is_empty());
    }

    #[test]
    fn correcting_the_source_resends_its_translations_too() {
        let before = [line("a", 0, "helo", &[("zh", "你好"), ("th", "สวัสดี")])];
        let after = [line("a", 0, "hello", &[("zh", "你好"), ("th", "สวัสดี")])];
        let changes = changes_since(&copy_of(&before), &after);
        assert_eq!(changes.count, 1);
        assert_eq!(changes.fixes.len(), 1);
        assert_eq!(changes.fixes[0].text, "hello");
        // 译文没改字,但它记着的原文指纹过时了。
        assert_eq!(changes.translations.len(), 2);
        assert_eq!(changes.translations["zh"][0].source_text, "hello");
    }

    #[test]
    fn correcting_one_translation_sends_only_that_language() {
        let before = [line("a", 0, "hello", &[("zh", "你号"), ("th", "สวัสดี")])];
        let after = [line("a", 0, "hello", &[("zh", "你好"), ("th", "สวัสดี")])];
        let changes = changes_since(&copy_of(&before), &after);
        assert_eq!(changes.count, 1);
        assert!(changes.fixes.is_empty());
        assert_eq!(changes.translations.keys().collect::<Vec<_>>(), vec!["zh"]);
    }

    #[test]
    fn a_new_sentence_is_added_not_fixed() {
        let before = [line("a", 0, "hello", &[])];
        let after = [line("a", 0, "hello", &[]), line("b", 2_000, "again", &[])];
        let changes = changes_since(&copy_of(&before), &after);
        assert_eq!(changes.count, 1);
        assert!(changes.fixes.is_empty());
        assert_eq!(changes.added.len(), 1);
        assert_eq!(changes.added[0].t_ms, 2_000);
        assert_eq!(changes.added[0].speaker, "1");
    }

    #[test]
    fn each_language_counts_its_own_sentences() {
        let mut thai = line("b", 1_000, "สวัสดี", &[("en", "hello"), ("zh", "你好")]);
        thai.language = Some("th".to_string());
        let lines = [line("a", 0, "hello", &[("zh", "你好")]), thai];
        let counts = language_counts(&lines);
        assert_eq!(counts["en"], 2);
        assert_eq!(counts["th"], 1);
        assert_eq!(counts["zh"], 2);
    }

    #[test]
    fn only_hosts_recorders_and_coordinators_may_file() {
        let event = StoredEvent {
            id: "e".into(),
            hosts: vec!["host".into()],
            crew: vec!["recorder".into()],
            ..Default::default()
        };
        let account = |person: &str, roles: &[&str]| StoredAccount {
            version: 1,
            server: String::new(),
            city_id: String::new(),
            city_name: String::new(),
            person_id: person.to_string(),
            person_name: String::new(),
            roles: roles.iter().map(|role| role.to_string()).collect(),
            identity_version: 1,
            controller: None,
            inception: Value::Null,
            card: Vec::new(),
            signed_in_at: 0,
        };
        assert!(may_file(&event, &account("host", &["resident"])));
        assert!(may_file(&event, &account("recorder", &[])));
        assert!(may_file(
            &event,
            &account("someone", &["resident", "coordinator"])
        ));
        assert!(!may_file(&event, &account("someone", &["resident"])));
        // 策展人只管收进来的活动;建城人卸任以后不再算协调者。
        assert!(!may_file(
            &event,
            &account("someone", &["resident", "curator"])
        ));
        assert!(!may_file(
            &event,
            &account("someone", &["resident", "founder"])
        ));
        let imported = StoredEvent {
            imported: true,
            ..event.clone()
        };
        assert!(may_file(
            &imported,
            &account("someone", &["resident", "curator"])
        ));
        assert!(!may_file(&imported, &account("someone", &["resident"])));
    }

    #[test]
    fn a_recording_is_bound_rebound_and_unbound_without_the_network() {
        let temp = tempfile::tempdir().unwrap();
        let core = ZuTalkCore::new_for_test(temp.path().to_string_lossy().to_string()).unwrap();
        let event = |id: &str| FfiCityEvent {
            id: id.to_string(),
            title: format!("event {id}"),
            place: String::new(),
            start_ms: 1,
            end_ms: 2,
            residents_only: false,
            mine: true,
        };
        assert!(core.city_filing("session-a".into()).is_none());
        let bound = core
            .city_bind_session("session-a".into(), Some(event("one")))
            .unwrap()
            .unwrap();
        assert_eq!(bound.state, FfiCityFilingState::Bound);
        assert_eq!(bound.event_id, "one");
        let rebound = core
            .city_bind_session("session-a".into(), Some(event("two")))
            .unwrap()
            .unwrap();
        assert_eq!(rebound.event_id, "two");
        assert!(
            core.city_pending_sessions().is_empty(),
            "只选了活动,还没排队"
        );
        assert!(core
            .city_bind_session("session-a".into(), None)
            .unwrap()
            .is_none());
        assert!(core.city_filings().is_empty());
        // 没登录就交:明说,不悄悄排队。
        core.city_bind_session("session-a".into(), Some(event("one")))
            .unwrap();
        assert!(core.city_file_session("session-a".into()).is_err());
        assert!(core.city_pending_sessions().is_empty());
    }

    #[test]
    fn options_and_topic_channels_survive_a_reload() {
        let temp = tempfile::tempdir().unwrap();
        let core = ZuTalkCore::new_for_test(temp.path().to_string_lossy().to_string()).unwrap();
        assert!(core.city_filing_options().automatic, "默认自动交");
        core.set_city_filing_options(FfiCityFilingOptions {
            speaker_names: false,
            marks: true,
            automatic: false,
        })
        .unwrap();
        core.set_city_topic_channel(
            "topic-a".into(),
            Some(FfiCityChannel {
                id: "channel".into(),
                title: "读书会".into(),
            }),
        )
        .unwrap();
        let options = core.city_filing_options();
        assert!(!options.speaker_names && !options.automatic && options.marks);
        assert_eq!(
            core.city_topic_channel("topic-a".into()).unwrap().title,
            "读书会"
        );
        core.set_city_topic_channel("topic-a".into(), None).unwrap();
        assert!(core.city_topic_channel("topic-a".into()).is_none());
    }

    #[test]
    fn the_ledger_is_private_to_this_login() {
        use std::os::unix::fs::PermissionsExt;
        let temp = tempfile::tempdir().unwrap();
        let core = ZuTalkCore::new_for_test(temp.path().to_string_lossy().to_string()).unwrap();
        core.set_city_filing_options(FfiCityFilingOptions {
            speaker_names: true,
            marks: true,
            automatic: true,
        })
        .unwrap();
        let file = core.city_path(FILINGS_FILE);
        assert_eq!(
            std::fs::metadata(&file).unwrap().permissions().mode() & 0o777,
            0o600
        );
        assert_eq!(
            std::fs::metadata(file.parent().unwrap())
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o700
        );
    }

    /// 对着本机起的一座城把整条路走一遍:扫码登录、读活动、交不上的不发、
    /// 交上去、重发不重复、撤下、退出登录。由
    /// `tools/city-interop/e2e-app.mjs` 起服务器、扮旧设备、读回来核对;
    /// 单独跑没有意义,所以平时不跑。
    #[test]
    #[ignore = "needs a city server on this machine; run tools/city-interop/e2e-app.mjs"]
    fn files_a_recording_into_a_city_on_this_machine() {
        let base = std::env::var("ZUTALK_CITY_E2E_BASE").expect("ZUTALK_CITY_E2E_BASE");
        let proceed = std::env::var("ZUTALK_CITY_E2E_PROCEED").expect("ZUTALK_CITY_E2E_PROCEED");
        let step =
            |name: &str, value: Value| println!("E2E {}", json!({ "step": name, "value": value }));
        let (_temp, core, _notebook, _run, _doc) =
            crate::notebook_capture_api::tests::projected_core_fixture();

        let offer = core.city_login_begin(base).unwrap();
        step("code", json!(offer.code));
        let mut shown = false;
        let account = loop {
            match core.city_login_poll().unwrap() {
                FfiCityLoginStep::Done { account } => break account,
                FfiCityLoginStep::Check { digits } if !shown => {
                    shown = true;
                    step("check", json!(digits));
                }
                FfiCityLoginStep::Check { .. } | FfiCityLoginStep::Waiting => {}
                other => panic!("sign-in ended early: {other:?}"),
            }
        };
        assert_eq!(core.city_account().as_ref(), Some(&account));
        step(
            "signed-in",
            json!({ "id": account.person_id, "name": account.person_name,
                    "city": account.city_name, "roles": account.roles }),
        );

        let calendar = core.city_calendar(true).unwrap();
        step(
            "calendar",
            calendar
                .events
                .iter()
                .map(|event| json!({ "title": event.title, "mine": event.mine }))
                .collect(),
        );
        let event = |title: &str| {
            calendar
                .events
                .iter()
                .find(|event| event.title == title)
                .unwrap_or_else(|| panic!("no event called {title}"))
                .clone()
        };
        let channels = core.city_channels();
        step(
            "channels",
            channels
                .iter()
                .map(|channel| json!(channel.title))
                .collect(),
        );
        let notebook = core
            .notebook_store
            .get_linked_notebook_id("session-a")
            .unwrap()
            .expect("the fixture's recording belongs to a topic");
        core.set_city_topic_channel(notebook, channels.first().cloned())
            .unwrap();

        // 别人的活动:交不上,而且什么都没发出去。
        core.city_bind_session("session-a".into(), Some(event("Evening walk")))
            .unwrap();
        let turned_away = core.city_file_session("session-a".into()).unwrap();
        step(
            "not-allowed",
            json!({ "state": format!("{:?}", turned_away.state), "error": turned_away.error_code }),
        );

        // 收进来的活动,协调者把这个人指成了记录员。
        core.city_bind_session("session-a".into(), Some(event("Language Exchange")))
            .unwrap();
        let filed = core.city_file_session("session-a".into()).unwrap();
        let stored = core.city_ledger().filings["session-a"].clone();
        step(
            "filed",
            json!({
                "state": format!("{:?}", filed.state), "error": filed.error_code,
                "url": filed.web_url, "channel": filed.channel_title, "signer": filed.signer_name,
                "languages": filed.languages.iter().map(|l| json!([l.language, l.sentences])).collect::<Vec<_>>(),
                "take": stored.take_id, "block": stored.block_id, "tags": stored.tags,
            }),
        );
        let again = core.city_file_session("session-a".into()).unwrap();
        assert_eq!(again.state, FfiCityFilingState::Filed);
        assert_eq!(
            core.city_filing("session-a".into())
                .unwrap()
                .changed_sentences,
            0
        );
        assert!(core.city_pending_sessions().is_empty());

        // 等那一头读回来核对完,再撤下。
        let waited = std::time::Instant::now();
        while !Path::new(&proceed).exists() {
            assert!(
                waited.elapsed() < Duration::from_secs(120),
                "nobody said to go on"
            );
            std::thread::sleep(Duration::from_millis(200));
        }
        let withdrawn = core.city_withdraw_filing("session-a".into()).unwrap();
        step(
            "withdrawn",
            json!({ "state": format!("{:?}", withdrawn.state), "error": withdrawn.error_code }),
        );

        core.city_sign_out().unwrap();
        assert!(core.city_account().is_none());
        assert!(!core.key_store.key_exists(CITY_IDENTITY_KEY_REF));
        step("signed-out", json!(true));
    }

    #[test]
    fn a_filed_recording_whose_event_the_city_deleted_says_so() {
        let temp = tempfile::tempdir().unwrap();
        let core = ZuTalkCore::new_for_test(temp.path().to_string_lossy().to_string()).unwrap();
        let event = FfiCityEvent {
            id: "kept".into(),
            title: "Kept".into(),
            place: String::new(),
            start_ms: 1,
            end_ms: 2,
            residents_only: false,
            mine: true,
        };
        for (session, id) in [("session-kept", "kept"), ("session-gone", "gone")] {
            core.city_bind_session(
                session.into(),
                Some(FfiCityEvent {
                    id: id.into(),
                    ..event.clone()
                }),
            )
            .unwrap();
        }
        core.with_city_ledger(|ledger| {
            for filing in ledger.filings.values_mut() {
                filing.state = FilingState::Filed;
                filing.filed_at = Some(1_000);
            }
        })
        .unwrap();
        let calendar = |fetched_at| StoredCalendar {
            fetched_at,
            events: vec![StoredEvent {
                id: "kept".into(),
                ..Default::default()
            }],
            ..Default::default()
        };

        // 活动列表是交之前读的:说明不了什么。
        write_private_json(&core.city_path(CALENDAR_FILE), &calendar(900)).unwrap();
        assert_eq!(
            core.city_filing("session-gone".into()).unwrap().error_code,
            None
        );

        // 交了以后又读过,那一场不在了。
        write_private_json(&core.city_path(CALENDAR_FILE), &calendar(2_000)).unwrap();
        let gone = core.city_filing("session-gone".into()).unwrap();
        assert_eq!(gone.state, FfiCityFilingState::Filed);
        assert_eq!(gone.error_code.as_deref(), Some(code::EVENT_GONE));
        assert_eq!(
            core.city_filing("session-kept".into()).unwrap().error_code,
            None
        );
        let listed: Vec<_> = core
            .city_filings()
            .into_iter()
            .map(|filing| (filing.session_id, filing.error_code))
            .collect();
        assert!(listed.contains(&("session-gone".into(), Some(code::EVENT_GONE.to_string()))));
        assert!(listed.contains(&("session-kept".into(), None)));

        // 上次更新没成,不该把「活动没了」盖住。
        core.with_city_ledger(|ledger| {
            ledger.filings.get_mut("session-gone").unwrap().error_code =
                Some(code::OFFLINE.to_string());
        })
        .unwrap();
        assert_eq!(
            core.city_filing("session-gone".into())
                .unwrap()
                .error_code
                .as_deref(),
            Some(code::EVENT_GONE)
        );

        // 取消了的活动在城里还在:交过的不算没了,只是不再拿出来给人选。
        let mut cancelled = calendar(3_000);
        cancelled.events[0].cancelled = true;
        write_private_json(&core.city_path(CALENDAR_FILE), &cancelled).unwrap();
        assert_eq!(
            core.city_filing("session-kept".into()).unwrap().error_code,
            None
        );
    }

    #[test]
    fn a_projected_recording_becomes_sentences_with_their_translations() {
        let (_temp, core, _notebook, _run, _doc) =
            crate::notebook_capture_api::tests::projected_core_fixture();
        let lines = core.city_lines("session-a").unwrap();
        assert!(!lines.is_empty());
        assert!(lines.iter().all(|line| !line.text.trim().is_empty()));
        assert!(
            lines
                .iter()
                .any(|line| line.lanes.values().any(|text| text.contains("你好"))),
            "译文跟着原句走"
        );
        for line in &lines {
            if let Some(language) = &line.language {
                assert!(!line.lanes.contains_key(language), "原文那一种不算译文");
            }
        }
    }
}
