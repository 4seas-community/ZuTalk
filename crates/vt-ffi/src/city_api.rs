//! 交到城的档案馆:登录的居民把一场录音的各语言文字稿签成城的记录,贴到
//! 活动的标签上;音频切成一段一段的文件,跟在文字后面交。
//!
//! 设计见 `docs/architecture/city-archive.md`。协议(签名、连设备、活动与
//! 频道怎么合出来、一场录音切成哪些记录、文件怎么传)全在 `vt-city`;这里
//! 只管三件事:
//!
//! - **钥匙和账本放在哪。** 签名钥匙的种子进 `Secrets/content-keys.json`,
//!   单独一个名字;说明是谁、在哪座城的那一份和另外两本小账放在
//!   `city/` 下,都是 0600。
//! - **一场录音的事实怎么变成要交的句子。** 只读转录和说话人。标记不交:
//!   这里不读标记,协议库里也没有签标记的函数。
//! - **什么时候发。** 发之前先查这个人交不交得上 —— 活动的标签只验签名,
//!   交不上的东西贴上去也没人看得到,只会留在公开日志里。断网就留在
//!   排队,下次再发;同一份内容重发得到同样的记录,不会交出两份。
//!
//! # 音频
//!
//! 负责人 2026-11-14 改的规矩:「不给标记数据，录音可以给。」音频能离开这台
//! Mac 的路只有这一条,而且交上去就是公开的、删不掉的。所以:
//!
//! - **发不发只在一处定**:[`audio_clearance`]。登录着、这一场的文字稿已经交
//!   上去、设置里「连音频一起交」开着、这一场没有单独关掉 —— 四条都成立才
//!   发。签音频分段、传文件的那一个函数要拿着它给的凭据才调得动。
//! - **这里碰到的音频只是别人编好码的文件。** App 把一段导出成 AAC 的
//!   `.m4a` 交过来,这里读它的字节、算指纹、传上去;不解密录音,不认得采样。
//! - **文字和音频各算各的。** 文字交上去了、音频没被收下,那一场是「已交,
//!   音频没收下」,不是没交上。

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
use vt_city::hub::{
    city_tag, event_tag, file_name, DoorCity, Hub, FILE_MAX_BYTES, ROLE_COORDINATOR, ROLE_CURATOR,
};
use vt_city::identity::{Identity, StoredIdentity};
use vt_city::link::{LinkSession, LinkStep};
use vt_city::publish::{self, Correction, PartInput, Sentence, TakeInput, Translated};
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
const DAY_SECS: i64 = 24 * 60 * 60;

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
    /// 这一场的文字稿还没交上去:音频挂在那段录音上,得先有它。
    pub const AUDIO_NOT_FILED: &str = "city.error.audio_not_filed";
    /// 设置里「连音频一起交」关着。
    pub const AUDIO_OFF: &str = "city.error.audio_off";
    /// 这一场单独设成了不交音频。
    pub const AUDIO_WITHHELD: &str = "city.error.audio_withheld";
    /// App 交来的这一段不能用:段号、时刻不对,文件读不了,或者不是 MP4。
    pub const AUDIO_BAD_PART: &str = "city.error.audio_bad_part";
    /// 城的服务器不收这个人给这场活动的音频(403)。
    pub const AUDIO_REFUSED: &str = "city.error.audio_refused";
    /// 一段超过了城的服务器收的大小(16 MiB)。
    pub const AUDIO_TOO_BIG: &str = "city.error.audio_too_big";
    /// 今天往城里放的够多了(429);什么时候能再交另记着。
    pub const AUDIO_DAILY_CAP: &str = "city.error.audio_daily_cap";
    /// 城的服务器盘满了(507)。
    pub const AUDIO_SERVER_FULL: &str = "city.error.audio_server_full";
}

/// 音频的一段导出成什么:AAC,装在 MPEG-4 里(`.m4a`)。
const AUDIO_MIME: &str = publish::MIME_M4A;

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

fn on() -> bool {
    true
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
struct StoredOptions {
    speaker_names: bool,
    /// 连音频一起交。默认开(负责人 2026-11-14 定);0.8.0–0.8.2 写下的那一份
    /// 没有这一项,读进来也是开。
    #[serde(default = "on")]
    audio: bool,
    automatic: bool,
    /// 0.8.0–0.8.2 的选项里有「标记的位置」。标记不再交了:读进来的值不用,
    /// 写出去永远是 false。这一项还留着,只因为那几个版本读这份账本时非要
    /// 它不可 —— 少了它,退回旧版的人会看到一份空账本,再把它写回去。
    #[serde(default, skip_deserializing)]
    marks: bool,
}

impl Default for StoredOptions {
    fn default() -> Self {
        Self {
            speaker_names: true,
            audio: true,
            automatic: true,
            marks: false,
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
    /// 0.8.0–0.8.2 交上去的标记数。标记不再交,新交的永远是 0;以前交的
    /// 留在城的日志里删不掉,这个数照实留着。
    #[serde(default)]
    marks: u32,
    #[serde(default)]
    error_code: Option<String>,
    /// 这一场单独设成了不交音频:设置里开着也不交。
    #[serde(default)]
    audio_withheld: bool,
    #[serde(default)]
    audio: StoredAudio,
    updated_at: i64,
}

/// 一场录音的音频交到哪一步。每一段的细账在 `sent-<录音>.json` 里;这里是
/// 给界面看的那几个数,撤下以后也留着 —— 交上去的音频撤不回来。
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
struct StoredAudio {
    /// 该交:文字是这一版交的、当时要音频,或者人已经开口让交了。App 凭它
    /// 自己接着交(启动时、网络回来时)。0.8.0–0.8.2 交的没有这一项 ——
    /// 以前只交了文字的,不替人补交音频,等人开口。
    #[serde(default)]
    due: bool,
    /// 一共几段(App 上一次说的);0 是还没开始。
    #[serde(default)]
    planned: u32,
    /// 城的服务器上已经有几段。
    #[serde(default)]
    filed: u32,
    #[serde(default)]
    error_code: Option<String>,
    /// 今天放得太多时,城说什么时候能再来(Unix 秒)。
    #[serde(default)]
    retry_at: Option<i64>,
}

/// 设置和这一场都说要音频。登录没登录、文字交没交,在 [`audio_clearance`] 里
/// 另看;界面上「这一场会不会带音频」问的是这一句。
fn audio_wanted(options: &StoredOptions, filing: &StoredFiling) -> bool {
    options.audio && !filing.audio_withheld
}

/// 音频有没有交完。
fn audio_complete(audio: &StoredAudio) -> bool {
    audio.planned > 0 && audio.filed >= audio.planned
}

/// 该交、还没交完、现在也还要:App 会自己接着交的那些。
fn audio_due(options: &StoredOptions, filing: &StoredFiling) -> bool {
    filing.state == FilingState::Filed
        && filing.audio.due
        && audio_wanted(options, filing)
        && !audio_complete(&filing.audio)
}

/// 「可以发音频」的凭据。只有 [`audio_clearance`] 造得出来;签音频分段、传
/// 文件的 `city_send_part` 要拿着它才调得动。
struct AudioClearance {
    /// 音频挂在哪段录音上:文字交上去时签的那条 `tape/take`。
    take_id: String,
    event_id: String,
}

/// **音频什么时候离开这台 Mac,只在这里定。** 四条都成立才发,缺一条不发:
///
/// 1. 登录着 —— 音频以本人的名义交;
/// 2. 这一场的文字稿已经交上去了 —— 音频挂在那段录音上,没有它无处可挂;
/// 3. 设置里「连音频一起交」开着(默认开);
/// 4. 这一场没有被单独设成不交音频。
///
/// 第 3、4 两条是负责人 2026-11-14 定的:「不给标记数据，录音可以给。」
/// 交上去的音频是公开的,撤不回来;所以不成立时给的是「不发」,不是「问一下」。
fn audio_clearance(
    account: Option<&StoredAccount>,
    options: &StoredOptions,
    filing: Option<&StoredFiling>,
) -> Result<AudioClearance, &'static str> {
    if account.is_none() {
        return Err(code::SIGNED_OUT);
    }
    let filing = filing.ok_or(code::UNBOUND)?;
    let (FilingState::Filed, Some(take_id)) = (filing.state, filing.take_id.as_ref()) else {
        return Err(code::AUDIO_NOT_FILED);
    };
    if !options.audio {
        return Err(code::AUDIO_OFF);
    }
    if filing.audio_withheld {
        return Err(code::AUDIO_WITHHELD);
    }
    Ok(AudioClearance {
        take_id: take_id.clone(),
        event_id: filing.event_id.clone(),
    })
}

/// 音频的一段没交成:给界面的键,和(今天放得太多时)什么时候能再来。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct AudioFailure {
    code: &'static str,
    retry_at: Option<i64>,
}

impl From<&'static str> for AudioFailure {
    fn from(code: &'static str) -> Self {
        Self {
            code,
            retry_at: None,
        }
    }
}

/// 传文件时城的回话 → 给界面的键。文字那一路只分「没连上」和「服务器没
/// 照办」;音频多出几种,每一种人要做的事不一样。
fn audio_failure(error: &CityError, now: i64) -> AudioFailure {
    match error {
        CityError::Unclaimed | CityError::Refused => code::AUDIO_REFUSED.into(),
        CityError::FileTooBig => code::AUDIO_TOO_BIG.into(),
        CityError::DailyCap { retry_after_secs } => AudioFailure {
            code: code::AUDIO_DAILY_CAP,
            // 城按 UTC 的一天算,第二天清零:它没说等多久,就等到那时候。
            retry_at: Some(
                now + retry_after_secs
                    .map(|seconds| seconds.min(DAY_SECS as u64) as i64)
                    .unwrap_or(DAY_SECS - now.rem_euclid(DAY_SECS)),
            ),
        },
        CityError::ServerFull => code::AUDIO_SERVER_FULL.into(),
        other => failure_code(other).into(),
    }
}

/// App 交来的文件是不是 MPEG-4:第一个盒子是 `ftyp`。记录里写的类型是
/// `audio/mp4`,交上去就改不了;拿错了文件(一段没编码的录音、别的什么)在这里
/// 拦下,不让它带着这个名字进公开的档案。
fn looks_like_mp4(bytes: &[u8]) -> bool {
    bytes.len() > 8 && &bytes[4..8] == b"ftyp"
}

impl StoredFiling {
    fn snapshot(
        &self,
        session_id: &str,
        server: Option<&str>,
        changed: u32,
        options: &StoredOptions,
    ) -> FfiCityFiling {
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
            audio_wanted: audio_wanted(options, self),
            audio_withheld: self.audio_withheld,
            audio_due: audio_due(options, self),
            audio_parts_planned: self.audio.planned,
            audio_parts_filed: self.audio.filed,
            audio_error_code: self.audio.error_code.clone(),
            audio_retry_at_epoch: self.audio.retry_at,
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
    /// 交上去的那条 `tape/take`,原样留一份:城的文件服务器收一段音频之前要
    /// 在活动的标签上找到认领它的记录,连同它指着的这一条,所以每交一段都把
    /// 它再贴一遍。0.8.0–0.8.2 交的没留,用到时从活动的标签上取回来。
    #[serde(default)]
    take: Option<Value>,
    /// 音频交到哪一段了:段号 → 那一段。
    #[serde(default)]
    parts: BTreeMap<u32, SentPart>,
}

/// 音频的一段:为它签过什么、文件传上去没有。
///
/// 签之前先记在这里。记录贴出去、文件还没传完就断了(一段几兆,会场的网常
/// 这样),下一次凭它接着来:字节没变就签出同一条记录;变了(重新导出的
/// `.m4a` 不保证逐字节相同)也知道前一条在哪。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
struct SentPart {
    /// 文件的指纹(SHA-256)。
    file: String,
    size: u64,
    t0_ms: i64,
    dur_ms: i64,
    /// 签这一段的记录时写的时刻。
    at_ms: i64,
    /// 活动的标签收下了这一段的记录。
    #[serde(default)]
    posted: bool,
    /// 城的服务器上有这个文件了。只在 `posted` 之后才会是真:说「这一段交了」
    /// 的时候,城里一定有指着它的那条记录。
    uploaded: bool,
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
            // 改字不动音频:那条录音和已经交了的几段原样带过去。
            take: sent.take.clone(),
            parts: sent.parts.clone(),
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
        self.city_keep_login(hub.base(), city, identity, roles, card, offered_name)
    }

    /// 把登录的结果留在这台 Mac 上。不走网络。
    fn city_keep_login(
        &self,
        server: &str,
        city: &DoorCity,
        identity: Identity,
        roles: Vec<String>,
        card: Vec<Value>,
        offered_name: &str,
    ) -> Result<FfiCityAccount, CoreError> {
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
            server: server.to_string(),
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
        let ledger = self.city_ledger();
        let filing = ledger.filings.get(session_id).cloned()?;
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
            &ledger.options,
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
                    // 撤下以后再交是另一件素材,另一段录音:以前交的音频挂在
                    // 原来那一段上,还在城里,但不算这一件的。
                    filing.built_at_ms = None;
                    filing.take_id = None;
                    filing.block_id = None;
                    filing.audio = StoredAudio::default();
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
            ..SentCopy::default()
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

        // 那条 tape/take 是签出来的第一条:留一份,交音频时要连它一起再贴。
        copy.take = built.records.first().cloned();
        if let Some(path) = self.city_sent_path(session_id) {
            write_private_json(&path, &copy).map_err(|_| code::SERVER)?;
        }
        let languages = language_counts(&lines);
        self.with_city_ledger(|ledger| {
            // 文字交上去的这一刻要音频,音频就算「该交」:App 接着一段段交。
            // 那时不要、以后才打开的,等人开口。
            let wants_audio = ledger.options.audio;
            if let Some(filing) = ledger.filings.get_mut(session_id) {
                filing.audio = StoredAudio {
                    due: wants_audio && !filing.audio_withheld,
                    ..StoredAudio::default()
                };
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
                filing.marks = 0;
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

    /// 从档案馆撤下:签一条 `arc/mark { to: "drop" }`,那件素材从档案馆的页面
    /// 上消失。**撤下的只是那一件。** 交上去的文字记录还在城的日志里,交上去
    /// 的音频还在城的服务器上、凭指纹照样取得到 —— 城没有删它们的办法。账本
    /// 里音频交了几段因此留着不清,界面照实说。
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

    // ---------------------------------------------------------------------
    // 音频
    // ---------------------------------------------------------------------

    /// 这一场现在能不能发音频。见 [`audio_clearance`]。
    fn city_audio_clearance(&self, session_id: &str) -> Result<AudioClearance, &'static str> {
        let account = self.city_stored_account();
        let ledger = self.city_ledger();
        audio_clearance(
            account.as_ref(),
            &ledger.options,
            ledger.filings.get(session_id),
        )
    }

    fn city_sent_copy(&self, session_id: &str) -> SentCopy {
        self.city_sent_path(session_id)
            .and_then(|path| read_json(&path))
            .unwrap_or_default()
    }

    /// 音频的细账,连同那条 `tape/take`。细账是跟着一段录音的:换了一段
    /// (撤下以后再交),以前的不算。
    fn city_audio_copy(&self, session_id: &str, clearance: &AudioClearance) -> SentCopy {
        let mut sent = self.city_sent_copy(session_id);
        let another_take = sent.take.as_ref().is_some_and(|take| {
            vt_city::record::record_id(take).ok().as_deref() != Some(clearance.take_id.as_str())
        });
        if another_take {
            sent.take = None;
            sent.parts.clear();
        }
        sent
    }

    /// 交上去的那条 `tape/take`。这一版交的留在细账里;0.8.0–0.8.2 交的没留,
    /// 到活动的标签上取回来(只认这个人签的、验得过的、名字对得上的)。
    fn city_take_record(
        &self,
        hub: &Hub,
        account: &StoredAccount,
        clearance: &AudioClearance,
        sent: &mut SentCopy,
    ) -> Result<Value, &'static str> {
        if let Some(take) = &sent.take {
            return Ok(take.clone());
        }
        let on_tag = self
            .runtime
            .block_on(hub.tag_get(&event_tag(&clearance.event_id), &["tape/take"], &[]))
            .map_err(|error| failure_code(&error))?;
        let take = on_tag
            .into_iter()
            .find(|record| {
                record["e"]["by"].as_str() == Some(account.person_id.as_str())
                    && vt_city::record::record_id(record).ok().as_deref()
                        == Some(clearance.take_id.as_str())
                    && vt_city::record::verify(record)
            })
            .ok_or_else(|| {
                // 账本说交过,城里却没有那段录音:这一件要重新交,不是再试一次音频。
                tracing::warn!("the take a filing names is not on its event's tag");
                code::SERVER
            })?;
        sent.take = Some(take.clone());
        Ok(take)
    }

    /// 城的文件服务器只替住在这座城里的人存录音。登录时还不是居民的,现问
    /// 一遍(也许后来入了城);还不是,就一条记录都不签 —— 认领不上的分段贴
    /// 出去,只会在公开的日志里留下一段放不出来的录音。
    fn city_housed(&self, hub: &Hub, account: &StoredAccount) -> Result<(), &'static str> {
        if account.is_resident() {
            return Ok(());
        }
        let roles = self
            .runtime
            .block_on(hub.roles(&account.city_id, &account.person_id))
            .map_err(|error| failure_code(&error))?;
        if roles.is_empty() {
            return Err(code::AUDIO_REFUSED);
        }
        let mut refreshed = account.clone();
        refreshed.roles = roles;
        if let Err(error) = write_private_json(&self.city_path(ACCOUNT_FILE), &refreshed) {
            tracing::warn!(?error, "city roles were not saved");
        }
        Ok(())
    }

    /// **签一段音频的记录、把文件传上去 —— 全仓库只有这一处。** 要拿着
    /// [`audio_clearance`] 给的凭据才调得动。
    ///
    /// 顺序是城定的:先把认领这个文件的记录(`tape/part`,连同它指着的那条
    /// `tape/take`)贴到活动的标签上,再 `PUT /files/<指纹>`;反过来服务器回
    /// 403。文件是 App 编好码交来的,这里只读字节、算指纹。
    ///
    /// 一旦服务器收下,这段音频就是公开的,撤不回来。
    #[allow(clippy::too_many_arguments)]
    fn city_send_part(
        &self,
        clearance: &AudioClearance,
        session_id: &str,
        n: u32,
        encoded_file: &Path,
        t0_ms: i64,
        dur_ms: i64,
        levels: &str,
    ) -> Result<(), AudioFailure> {
        let sent_path = self.city_sent_path(session_id).ok_or(code::UNBOUND)?;
        let mut sent = self.city_audio_copy(session_id, clearance);
        // 这一段已经在城的服务器上了:什么都不用做,也不用联网。
        if sent.parts.get(&n).is_some_and(|part| part.uploaded) {
            return Ok(());
        }

        // 超过城收的大小的,读都不读。
        let size = std::fs::metadata(encoded_file)
            .map(|meta| meta.len())
            .map_err(|_| code::AUDIO_BAD_PART)?;
        if size > FILE_MAX_BYTES {
            return Err(code::AUDIO_TOO_BIG.into());
        }
        let bytes = std::fs::read(encoded_file).map_err(|_| code::AUDIO_BAD_PART)?;
        if !looks_like_mp4(&bytes) {
            return Err(code::AUDIO_BAD_PART.into());
        }
        let file = file_name(&bytes);

        let account = self.city_stored_account().ok_or(code::SIGNED_OUT)?;
        let identity = self.city_identity(&account).map_err(|_| code::SIGNED_OUT)?;
        let hub = self
            .city_hub(&account.server, REQUEST_TIMEOUT)
            .map_err(|_| code::BAD_ADDRESS)?;
        let failed = |error: CityError| audio_failure(&error, now_epoch());
        self.city_housed(&hub, &account)?;

        // 城对每个段号只认它最先看到的那一条记录(按签的时刻排)。
        let at_ms = match sent.parts.get(&n) {
            // 上一次签过、字节没变:沿用那一刻,签出来的就是同一条。
            Some(earlier) if earlier.file == file => earlier.at_ms,
            // 上一次签过,这一次的字节不一样了(重新导出的文件不保证逐字节
            // 相同)。那一条记录贴上去过的话,先问它的文件是不是其实传完了,
            // 只是没来得及记:是,这一段就已经交了,不再传第二份。不是 ——
            // 或者那一条有没有贴上去都说不准 —— 它指着的就是一个城里没有的
            // 文件:新的这一条要排到它前面,不然城里这一段永远放不出来。
            Some(earlier) => {
                let earlier = earlier.clone();
                if earlier.posted
                    && self
                        .runtime
                        .block_on(hub.file_exists(&earlier.file))
                        .map_err(failed)?
                {
                    sent.parts.insert(
                        n,
                        SentPart {
                            uploaded: true,
                            ..earlier
                        },
                    );
                    write_private_json(&sent_path, &sent).map_err(|_| code::SERVER)?;
                    return Ok(());
                }
                earlier.at_ms - 1
            }
            None => now_ms(),
        };
        let take = self.city_take_record(&hub, &account, clearance, &mut sent)?;
        let part = publish::build_part(
            &identity,
            &PartInput {
                take_id: clearance.take_id.clone(),
                n,
                file: file.clone(),
                size,
                t0_ms,
                dur_ms,
                mime: AUDIO_MIME.to_string(),
                levels: levels.to_string(),
            },
            at_ms,
        )
        .map_err(|error| match error {
            CityError::FileTooBig => code::AUDIO_TOO_BIG,
            _ => code::AUDIO_BAD_PART,
        })?;

        // 先记下签了什么,再贴。
        let mut entry = SentPart {
            file: file.clone(),
            size,
            t0_ms,
            dur_ms,
            at_ms,
            posted: false,
            uploaded: false,
        };
        sent.parts.insert(n, entry.clone());
        write_private_json(&sent_path, &sent).map_err(|_| code::SERVER)?;

        let card = self.city_card(&hub, &account, &identity);
        let tags = [event_tag(&clearance.event_id)];
        self.runtime
            .block_on(Self::city_post(&hub, &tags, &card, &[take, part.rec]))
            .map_err(failed)?;
        entry.posted = true;
        sent.parts.insert(n, entry.clone());
        write_private_json(&sent_path, &sent).map_err(|_| code::SERVER)?;

        self.runtime
            .block_on(async move {
                // 服务器上已经有这些字节(上一次传完了没来得及记):不再传。
                if !hub.file_exists(&file).await? {
                    hub.file_put(&file, bytes).await?;
                }
                Ok::<(), CityError>(())
            })
            .map_err(failed)?;
        entry.uploaded = true;
        sent.parts.insert(n, entry);
        write_private_json(&sent_path, &sent).map_err(|_| code::SERVER)?;
        Ok(())
    }

    /// 交音频的一段,把结果记进账本。
    #[allow(clippy::too_many_arguments)]
    fn city_file_part(
        &self,
        session_id: &str,
        n: u32,
        total: u32,
        encoded_file: &Path,
        t0_ms: i64,
        dur_ms: i64,
        levels: &str,
    ) -> Result<FfiCityFiling, CoreError> {
        let _claim = self.city_claim(session_id)?;
        // 发不发,先过这一关。过不了的什么都不读、不签、不传。
        let clearance = self.city_audio_clearance(session_id).map_err(refuse)?;
        if total == 0 || n >= total || t0_ms < 0 || dur_ms <= 0 {
            return Err(refuse(code::AUDIO_BAD_PART));
        }
        // 今天放得太多、城说的时候还没到:不去碰它,原样给回。
        let capped = self
            .city_ledger()
            .filings
            .get(session_id)
            .and_then(|filing| filing.audio.retry_at)
            .is_some_and(|retry_at| retry_at > now_epoch());
        if capped {
            return self
                .city_filing_snapshot(session_id, false)
                .ok_or_else(|| refuse(code::UNBOUND));
        }

        let outcome = self.city_send_part(
            &clearance,
            session_id,
            n,
            encoded_file,
            t0_ms,
            dur_ms,
            levels,
        );
        // App 交来的东西不对:不是这场录音的状态,不记进账本。
        if let Err(AudioFailure {
            code: code::AUDIO_BAD_PART,
            ..
        }) = outcome
        {
            return Err(refuse(code::AUDIO_BAD_PART));
        }
        let filed = self
            .city_sent_copy(session_id)
            .parts
            .values()
            .filter(|part| part.uploaded)
            .count() as u32;
        self.with_city_ledger(|ledger| {
            if let Some(filing) = ledger.filings.get_mut(session_id) {
                // 人开了口(或者 App 接着上一回在交):从此算「该交」,断了自己接上。
                filing.audio.due = true;
                filing.audio.planned = total;
                filing.audio.filed = filed;
                filing.audio.error_code = outcome.err().map(|failure| failure.code.to_string());
                filing.audio.retry_at = outcome.err().and_then(|failure| failure.retry_at);
                filing.updated_at = now_epoch();
            }
        })?;
        self.city_filing_snapshot(session_id, false)
            .ok_or_else(|| refuse(code::UNBOUND))
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
    /// 连音频一起交。默认开。交上去的音频是公开的,撤不回来。
    pub audio: bool,
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
    /// 0.8.0–0.8.2 交上去的标记数。标记不再交:这一版起交的永远是 0;以前
    /// 交的留在城的日志里删不掉,这个数照实留着。
    pub marks: u32,
    /// 交上去以后在这台 Mac 上改过、还没更新过去的句数。
    pub changed_sentences: u32,
    /// 文字这一路的错。音频没交成不写在这里,也不改 `state`。
    pub error_code: Option<String>,
    /// 档案馆里这件素材的网址。
    pub web_url: Option<String>,
    /// 这一场要不要带音频:设置里「连音频一起交」开着,这一场也没单独关掉。
    pub audio_wanted: bool,
    /// 这一场单独设成了不交音频(`city_set_session_audio`)。
    pub audio_withheld: bool,
    /// 音频该交、还没交完、现在也还要:App 自己接着交(启动时、网络回来时)。
    /// 以前只交了文字的录音不在此列,等人开口。
    pub audio_due: bool,
    /// 音频一共几段;0 是还没开始交。
    pub audio_parts_planned: u32,
    /// 城的服务器上已经有几段。撤下以后这个数也留着:交上去的音频撤不回来。
    pub audio_parts_filed: u32,
    /// 音频上一次没交成的原因:`city.error.audio_refused`、`audio_too_big`、
    /// `audio_daily_cap`、`audio_server_full`,或者 `city.error.offline`、
    /// `city.error.server`。交成了就清掉。
    pub audio_error_code: Option<String>,
    /// `audio_error_code` 是 `city.error.audio_daily_cap` 时:什么时候能再交
    /// (Unix 秒)。
    pub audio_retry_at_epoch: Option<i64>,
}

/// 交音频之前问一遍:要不要导出,怎么切,哪几段已经交了。
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiCityAudioPlan {
    /// 现在能不能交。false 就什么都别导出,`hold_code` 说为什么。
    pub upload: bool,
    /// 不能交的原因:`city.error.signed_out`、`unbound`、`audio_not_filed`、
    /// `audio_off`、`audio_withheld`、`audio_daily_cap`。
    pub hold_code: Option<String>,
    /// 同 `FfiCityFiling.audio_due`:该不该由 App 自己开始、接着交。
    pub due: bool,
    /// 一段多长(毫秒):300 000。最后一段可以短。第 n 段从 n × part_ms 开始。
    pub part_ms: i64,
    /// 一段最多多少字节(16 MiB)。
    pub max_part_bytes: u64,
    /// 导出成什么:`audio/mp4`(AAC,`.m4a`)。
    pub mime: String,
    /// 上一次说的一共几段;0 是还没开始。
    pub parts_planned: u32,
    /// 城的服务器上已经有的段号,从小到大。
    pub parts_filed: Vec<u32>,
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
            audio: options.audio,
            automatic: options.automatic,
        }
    }

    pub fn set_city_filing_options(&self, options: FfiCityFilingOptions) -> Result<(), CoreError> {
        self.with_city_ledger(|ledger| {
            ledger.options = StoredOptions {
                speaker_names: options.speaker_names,
                audio: options.audio,
                automatic: options.automatic,
                ..StoredOptions::default()
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
            // 换一场活动,不该把「这一场不交音频」悄悄改回去。
            let audio_withheld = ledger
                .filings
                .get(&session_id)
                .is_some_and(|filing| filing.audio_withheld);
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
                            audio_withheld,
                            audio: StoredAudio::default(),
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
                let mut snapshot = filing.snapshot(session_id, server, 0, &ledger.options);
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

    /// 这一场交不交音频。`enabled` 为 false:设置里开着,这一场也不交;为
    /// true:照设置来(设置关着时仍然不交 —— 设置是总开关,单场只能往少里
    /// 改)。录之前、录音中、交了文字以后都能改;已经交上去的音频撤不回来。
    /// 不走网络。这场录音还没归到活动时回 `city.error.unbound`。
    pub fn city_set_session_audio(
        &self,
        session_id: String,
        enabled: bool,
    ) -> Result<FfiCityFiling, CoreError> {
        let known = self.with_city_ledger(|ledger| {
            let Some(filing) = ledger.filings.get_mut(&session_id) else {
                return false;
            };
            filing.audio_withheld = !enabled;
            filing.updated_at = now_epoch();
            true
        })?;
        if !known {
            return Err(refuse(code::UNBOUND));
        }
        self.city_filing_snapshot(&session_id, false)
            .ok_or_else(|| refuse(code::UNBOUND))
    }

    /// 交音频之前问一遍:现在能不能交、一段多长、哪几段已经在城的服务器上。
    /// 不走网络。`upload` 为 false 时不要导出音频。
    pub fn city_audio_plan(&self, session_id: String) -> FfiCityAudioPlan {
        let account = self.city_stored_account();
        let ledger = self.city_ledger();
        let filing = ledger.filings.get(&session_id);
        let clearance = audio_clearance(account.as_ref(), &ledger.options, filing);
        let capped = filing
            .and_then(|filing| filing.audio.retry_at)
            .is_some_and(|retry_at| retry_at > now_epoch());
        let hold_code = match &clearance {
            Err(hold) => Some(hold.to_string()),
            Ok(_) if capped => Some(code::AUDIO_DAILY_CAP.to_string()),
            Ok(_) => None,
        };
        let parts_filed = match &clearance {
            Ok(clearance) => self
                .city_audio_copy(&session_id, clearance)
                .parts
                .iter()
                .filter(|(_, part)| part.uploaded)
                .map(|(n, _)| *n)
                .collect(),
            Err(_) => Vec::new(),
        };
        FfiCityAudioPlan {
            upload: hold_code.is_none(),
            hold_code,
            due: filing.is_some_and(|filing| audio_due(&ledger.options, filing)),
            part_ms: publish::PART_MS,
            max_part_bytes: FILE_MAX_BYTES,
            mime: AUDIO_MIME.to_string(),
            parts_planned: filing.map_or(0, |filing| filing.audio.planned),
            parts_filed,
        }
    }

    /// 交音频的一段。走网络,一段可能要传好几分钟,别在主线程上调。
    ///
    /// App 把这场录音的音频按 `city_audio_plan` 说的长度切开,每一段导出成一个
    /// 能单独播放的 AAC `.m4a` 文件,一段调一次:`n` 是段号(从 0 起),`total`
    /// 是一共几段,`path` 是那个文件,`t0_ms`、`dur_ms` 是这一段在录音时间线上
    /// 的起点和长度(和转录句子的时刻同一个钟),`levels` 是每秒一个 0–9 的
    /// 音量(画波形用,可以为空,最多 3600 个)。文件由 App 自己删。
    ///
    /// 这一段已经在城的服务器上就直接给回,不联网。出错分两种:
    /// - 发不了、不该发(没登录、文字还没交、设置关着、这一场单独关了、参数
    ///   不对、这一场正在交别的)—— 回错误,账本不动;
    /// - 发了没成(没连上、城不收、太大、今天放得太多、服务器满了)—— 照常
    ///   给回这场录音的状态,原因在 `audio_error_code` 里。文字交上去了这件事
    ///   不受影响。
    #[allow(clippy::too_many_arguments)]
    pub fn city_file_audio_part(
        &self,
        session_id: String,
        n: u32,
        total: u32,
        path: String,
        t0_ms: i64,
        dur_ms: i64,
        levels: String,
    ) -> Result<FfiCityFiling, CoreError> {
        self.city_file_part(
            &session_id,
            n,
            total,
            Path::new(&path),
            t0_ms,
            dur_ms,
            &levels,
        )
    }

    /// 音频该交、还没交完、现在去交有用的录音。启动时、网络回来时照这份单子
    /// 接着交(每一场先问 `city_audio_plan`)。城不收的、一段太大的不在里面
    /// —— 再试也一样,等人来看;今天放得太多的,到城说的时候才回到单子上。
    /// 没登录时是空的:导出音频不便宜,交不了就别让 App 白忙。
    pub fn city_pending_audio_sessions(&self) -> Vec<String> {
        if self.city_stored_account().is_none() {
            return Vec::new();
        }
        let ledger = self.city_ledger();
        let now = now_epoch();
        ledger
            .filings
            .iter()
            .filter(|(_, filing)| {
                audio_due(&ledger.options, filing)
                    && !matches!(
                        filing.audio.error_code.as_deref(),
                        Some(code::AUDIO_REFUSED | code::AUDIO_TOO_BIG)
                    )
                    && filing.audio.retry_at.is_none_or(|retry_at| retry_at <= now)
            })
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
            ..SentCopy::default()
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
        assert!(core.city_filing_options().audio, "默认连音频一起交");
        core.set_city_filing_options(FfiCityFilingOptions {
            speaker_names: false,
            audio: true,
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
        assert!(!options.speaker_names && !options.automatic && options.audio);
        core.set_city_filing_options(FfiCityFilingOptions {
            audio: false,
            ..options
        })
        .unwrap();
        assert!(!core.city_filing_options().audio, "关掉以后记得住");
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
            audio: true,
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
    /// 交上去(有标记也不交标记)、重发不重复、这一场关着音频时什么都不传、
    /// 打开以后一段段交音频、撤下、退出登录。由
    /// `tools/city-interop/e2e-app.mjs` 起服务器、扮旧设备、读回来核对;
    /// 单独跑没有意义,所以平时不跑。
    #[test]
    #[ignore = "needs a city server on this machine; run tools/city-interop/e2e-app.mjs"]
    fn files_a_recording_into_a_city_on_this_machine() {
        let base = std::env::var("ZUTALK_CITY_E2E_BASE").expect("ZUTALK_CITY_E2E_BASE");
        let proceed = std::env::var("ZUTALK_CITY_E2E_PROCEED").expect("ZUTALK_CITY_E2E_PROCEED");
        // 那一头备好的几段音频:[{ path, t0, dur, lv }]。
        let audio: Vec<Value> = serde_json::from_str(
            &std::env::var("ZUTALK_CITY_E2E_AUDIO").expect("ZUTALK_CITY_E2E_AUDIO"),
        )
        .expect("ZUTALK_CITY_E2E_AUDIO is a JSON list of parts");
        let step =
            |name: &str, value: Value| println!("E2E {}", json!({ "step": name, "value": value }));
        // 等那一头读回来核对完再往下走。
        let wait_for = |suffix: &str| {
            let waited = std::time::Instant::now();
            while !Path::new(&format!("{proceed}{suffix}")).exists() {
                assert!(
                    waited.elapsed() < Duration::from_secs(120),
                    "nobody said to go on"
                );
                std::thread::sleep(Duration::from_millis(200));
            }
        };
        let (_temp, core, _notebook, _run, _doc) =
            crate::notebook_capture_api::tests::projected_core_fixture();
        // 这场录音上有一个标记。标记不交:交上去的东西里不该有它。(标记挂在
        // 录音的目录项上,台架里那一场没有目录项,先补一个。)
        core.session_store
            .insert_session(&vt_store::SessionRecord {
                id: "session-a".into(),
                title: "Language exchange, week 3".into(),
                session_type: "recording".into(),
                status: "completed".into(),
                duration_ms: 5_000,
                created_at: "2026-11-13T10:00:00Z".into(),
                deleted_at: None,
            })
            .unwrap();
        core.session_marks
            .create("mark-a", "session-a", 1_000, 500)
            .unwrap();
        assert_eq!(core.session_marks.list("session-a").unwrap().len(), 1);

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

        assert_eq!(filed.marks, 0, "标记不交");
        assert!(
            filed.audio_wanted && filed.audio_due,
            "默认带音频,文字交完就该交"
        );
        assert_eq!(core.city_pending_audio_sessions(), ["session-a"]);
        wait_for("");

        // 音频。这一场单独关掉的时候:不读、不签、不传。
        let send = |n: usize| {
            let part = &audio[n];
            core.city_file_audio_part(
                "session-a".into(),
                n as u32,
                audio.len() as u32,
                part["path"].as_str().unwrap().to_string(),
                part["t0"].as_i64().unwrap(),
                part["dur"].as_i64().unwrap(),
                part["lv"].as_str().unwrap().to_string(),
            )
        };
        let without = core
            .city_set_session_audio("session-a".into(), false)
            .unwrap();
        let refused = match send(0) {
            Err(CoreError::ValidationFailed { message }) => message,
            other => panic!("audio went out for a recording set to go without: {other:?}"),
        };
        let held = core.city_audio_plan("session-a".into());
        step(
            "audio-withheld",
            json!({
                "wanted": without.audio_wanted, "error": refused,
                "upload": held.upload, "hold": held.hold_code,
                "pending": core.city_pending_audio_sessions(),
            }),
        );
        wait_for(".withheld");

        // 打开以后:照计划一段段交。
        core.city_set_session_audio("session-a".into(), true)
            .unwrap();
        let plan = core.city_audio_plan("session-a".into());
        step(
            "audio-plan",
            json!({
                "upload": plan.upload, "due": plan.due, "part_ms": plan.part_ms,
                "max": plan.max_part_bytes, "mime": plan.mime, "filed": plan.parts_filed,
            }),
        );
        let mut after = Vec::new();
        for n in 0..audio.len() {
            let filing = send(n).unwrap();
            after.push(json!({
                "state": format!("{:?}", filing.state), "planned": filing.audio_parts_planned,
                "filed": filing.audio_parts_filed, "error": filing.audio_error_code,
            }));
        }
        // 再交一遍已经交了的:什么都不变。
        let again = send(0).unwrap();
        step(
            "audio",
            json!({
                "parts": after, "again": again.audio_parts_filed,
                "filed": core.city_audio_plan("session-a".into()).parts_filed,
                "pending": core.city_pending_audio_sessions(),
            }),
        );
        wait_for(".audio");

        let withdrawn = core.city_withdraw_filing("session-a".into()).unwrap();
        assert_eq!(
            withdrawn.audio_parts_filed,
            audio.len() as u32,
            "撤下以后交上去的音频还在,照实留着"
        );
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

    // =====================================================================
    // 音频
    // =====================================================================

    use std::collections::VecDeque;
    use std::io::{Read as _, Write as _};
    use std::sync::Arc;

    const EVENT: &str = "abababababababababababababababababababababababababababababababab";
    const CITY: &str = "c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00";
    const EVENT_HUB: &str = "/hub/ev%3Aabababababababab";

    /// 假城收到的一个请求:「方法 地址」和正文。
    type Asked = (String, Vec<u8>);

    /// 假城对一次 PUT 的回话。
    #[derive(Clone, Copy)]
    enum Put {
        /// 收下。
        Take,
        /// 回这个状态码,可以带 Retry-After。
        Status(u16, Option<u64>),
        /// 读完请求就挂断,一个字不回。
        HangUp,
    }

    /// 本机的一台假城:活动的标签、文件、名分各有最简单的一套回话,收到的
    /// 请求一条条记着。不验签,不认人 —— 那些由 `tools/city-interop` 拿城自己
    /// 的代码来验;这里验的是这一头在什么时候发了什么、把回话当成了什么。
    #[derive(Clone)]
    struct FakeCity {
        base: String,
        asked: Arc<Mutex<Vec<Asked>>>,
        files: Arc<Mutex<HashSet<String>>>,
        puts: Arc<Mutex<VecDeque<Put>>>,
        /// 接下来还有几次贴记录要挂断不回。
        lost_posts: Arc<Mutex<u32>>,
        takes: Arc<Mutex<Vec<Value>>>,
        roles: Arc<Mutex<Vec<&'static str>>>,
    }

    impl FakeCity {
        fn start() -> FakeCity {
            let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
            let city = FakeCity {
                base: format!("http://{}", listener.local_addr().unwrap()),
                asked: Arc::default(),
                files: Arc::default(),
                puts: Arc::default(),
                lost_posts: Arc::default(),
                takes: Arc::default(),
                roles: Arc::default(),
            };
            let serving = city.clone();
            std::thread::spawn(move || {
                for stream in listener.incoming().flatten() {
                    let serving = serving.clone();
                    std::thread::spawn(move || serving.serve(stream));
                }
            });
            city
        }

        fn serve(&self, mut stream: std::net::TcpStream) {
            let mut bytes = Vec::new();
            let mut chunk = [0u8; 16 * 1024];
            let (head_end, length) = loop {
                let read = stream.read(&mut chunk).unwrap_or(0);
                if read == 0 {
                    return;
                }
                bytes.extend_from_slice(&chunk[..read]);
                if let Some(at) = bytes.windows(4).position(|window| window == b"\r\n\r\n") {
                    let head = String::from_utf8_lossy(&bytes[..at]).to_lowercase();
                    let length = head
                        .lines()
                        .find_map(|line| line.strip_prefix("content-length:"))
                        .and_then(|value| value.trim().parse::<usize>().ok())
                        .unwrap_or(0);
                    break (at + 4, length);
                }
            };
            while bytes.len() < head_end + length {
                let read = stream.read(&mut chunk).unwrap_or(0);
                if read == 0 {
                    break;
                }
                bytes.extend_from_slice(&chunk[..read]);
            }
            let head = String::from_utf8_lossy(&bytes[..head_end]).to_string();
            let mut words = head.split_whitespace();
            let (method, target) = (
                words.next().unwrap_or("").to_string(),
                words.next().unwrap_or("").to_string(),
            );
            let body = bytes[head_end..].to_vec();
            self.asked
                .lock()
                .unwrap()
                .push((format!("{method} {target}"), body.clone()));
            let Some((status, headers, reply)) = self.answer(&method, &target, &body) else {
                return;
            };
            let response = format!(
                "HTTP/1.1 {status} X\r\n{headers}Content-Length: {}\r\nConnection: close\r\n\r\n{reply}",
                reply.len()
            );
            let _ = stream.write_all(response.as_bytes());
        }

        /// 状态码、多出来的头、正文;`None` 是挂断。
        fn answer(&self, method: &str, target: &str, body: &[u8]) -> Option<(u16, String, String)> {
            let plain =
                |status: u16, reply: Value| Some((status, String::new(), reply.to_string()));
            if let Some(file) = target.strip_prefix("/files/") {
                if method == "GET" {
                    let has = self.files.lock().unwrap().contains(file);
                    return plain(if has { 206 } else { 404 }, json!({}));
                }
                let next = self.puts.lock().unwrap().pop_front().unwrap_or(Put::Take);
                return match next {
                    Put::Take => {
                        assert_eq!(file_name(body), file, "传上来的字节就是指纹说的那些");
                        self.files.lock().unwrap().insert(file.to_string());
                        plain(200, json!({ "ok": true }))
                    }
                    Put::Status(status, retry) => Some((
                        status,
                        retry
                            .map(|seconds| format!("Retry-After: {seconds}\r\n"))
                            .unwrap_or_default(),
                        json!({ "status": status }).to_string(),
                    )),
                    Put::HangUp => None,
                };
            }
            if target.starts_with("/p/") {
                let credentials: Vec<Value> = self
                    .roles
                    .lock()
                    .unwrap()
                    .iter()
                    .map(|role| json!({ "credentialSubject": { "role": role, "city": { "polis": CITY } } }))
                    .collect();
                return plain(200, json!({ "credentials": credentials }));
            }
            if method == "POST" {
                let mut lost = self.lost_posts.lock().unwrap();
                if *lost > 0 {
                    *lost -= 1;
                    return None;
                }
                return plain(200, json!({ "took": 1, "refused": [] }));
            }
            if target.starts_with(EVENT_HUB) {
                let takes = self.takes.lock().unwrap().clone();
                return plain(
                    200,
                    json!({ "recs": takes, "n": takes.len(), "more": false }),
                );
            }
            plain(200, json!({ "recs": [], "n": 0, "more": false }))
        }

        fn lines(&self) -> Vec<String> {
            self.asked
                .lock()
                .unwrap()
                .iter()
                .map(|(line, _)| line.clone())
                .collect()
        }

        fn count(&self) -> usize {
            self.asked.lock().unwrap().len()
        }

        /// 最近一次贴到活动标签上的那一批。
        fn last_post(&self) -> Vec<Value> {
            let asked = self.asked.lock().unwrap();
            let (_, body) = asked
                .iter()
                .rev()
                .find(|(line, _)| line == &format!("POST {EVENT_HUB}"))
                .expect("something was posted to the event's tag");
            serde_json::from_slice(body).unwrap()
        }

        fn script(&self, puts: &[Put]) {
            self.puts.lock().unwrap().extend(puts.iter().copied());
        }
    }

    fn test_identity() -> Identity {
        let fixtures: Value =
            serde_json::from_str(include_str!("../../vt-city/tests/fixtures/identity.json"))
                .unwrap();
        Identity::from_key_string(fixtures["people"][0]["key_string"].as_str().unwrap()).unwrap()
    }

    fn core_in(temp: &tempfile::TempDir) -> ZuTalkCore {
        ZuTalkCore::new_for_test(temp.path().to_string_lossy().to_string()).unwrap()
    }

    /// 登录到假城,不走连设备那一套。
    fn sign_in(core: &ZuTalkCore, city: &FakeCity, roles: &[&str]) {
        let identity = test_identity();
        let card = vec![identity.inception().clone()];
        core.city_keep_login(
            &city.base,
            &DoorCity {
                id: CITY.to_string(),
                name: "Harbour Town".to_string(),
                members: 3,
            },
            identity,
            roles.iter().map(|role| role.to_string()).collect(),
            card,
            "Ada of the Garden",
        )
        .unwrap();
    }

    fn bind(core: &ZuTalkCore, session_id: &str) {
        core.city_bind_session(
            session_id.to_string(),
            Some(FfiCityEvent {
                id: EVENT.to_string(),
                title: "Morning circle".to_string(),
                place: String::new(),
                start_ms: 1,
                end_ms: 2,
                residents_only: false,
                mine: true,
            }),
        )
        .unwrap();
    }

    /// 这场录音的文字已经交上去了:账本和细账照交完以后的样子摆好。给回那条
    /// `tape/take`。`remembered` 为 false 是 0.8.0–0.8.2 交的样子 —— 细账里没
    /// 留那条记录,也没有「音频该交」这回事。
    fn filed(core: &ZuTalkCore, session_id: &str, remembered: bool) -> Value {
        bind(core, session_id);
        let built = publish::build_take(
            &test_identity(),
            &TakeInput {
                event_id: EVENT.to_string(),
                title: "Recording".to_string(),
                started_ms: 1_794_520_000_000,
                duration_ms: 600_000,
                sentences: vec![Sentence {
                    t_ms: 0,
                    d_ms: 900,
                    speaker: String::new(),
                    text: "Good morning.".to_string(),
                }],
                ..TakeInput::default()
            },
            1_794_528_000_000,
        )
        .unwrap();
        let take = built.records[0].clone();
        core.with_city_ledger(|ledger| {
            let wants_audio = ledger.options.audio;
            let filing = ledger.filings.get_mut(session_id).unwrap();
            filing.state = FilingState::Filed;
            filing.take_id = Some(built.take_id.clone());
            filing.block_id = Some(built.block_id.clone());
            filing.tags = vec![event_tag(EVENT)];
            filing.filed_at = Some(now_epoch());
            filing.audio.due = remembered && wants_audio && !filing.audio_withheld;
        })
        .unwrap();
        write_private_json(
            &core.city_sent_path(session_id).unwrap(),
            &SentCopy {
                take: remembered.then(|| take.clone()),
                ..SentCopy::default()
            },
        )
        .unwrap();
        take
    }

    /// 一段编好码的音频的样子:开头是 MPEG-4 的 `ftyp` 盒子,后面的字节随 `seed` 变。
    fn m4a(seed: u8, len: usize) -> Vec<u8> {
        let mut bytes = vec![0, 0, 0, 0x1c];
        bytes.extend_from_slice(b"ftypM4A ");
        bytes.extend((bytes.len()..len).map(|at| (at as u8).wrapping_mul(31).wrapping_add(seed)));
        bytes
    }

    fn part_file(temp: &tempfile::TempDir, name: &str, bytes: &[u8]) -> String {
        let path = temp.path().join(name);
        std::fs::write(&path, bytes).unwrap();
        path.to_string_lossy().to_string()
    }

    fn send_part(
        core: &ZuTalkCore,
        n: u32,
        total: u32,
        path: &str,
    ) -> Result<FfiCityFiling, CoreError> {
        core.city_file_audio_part(
            "session-a".into(),
            n,
            total,
            path.to_string(),
            i64::from(n) * 300_000,
            300_000,
            "0123456789".into(),
        )
    }

    fn refusal(outcome: Result<FfiCityFiling, CoreError>) -> String {
        match outcome {
            Err(CoreError::ValidationFailed { message }) => message,
            other => panic!("expected a refusal, got {other:?}"),
        }
    }

    /// 0.8.0–0.8.2 的账本就是这个样子:选项里有 marks、没有 audio,交过的那
    /// 一场记着标记数,没有任何音频的字段。
    const LEDGER_0_8_2: &str = r#"{
        "options": { "speaker_names": false, "marks": true, "automatic": false },
        "topics": {},
        "filings": { "session-a": {
            "event_id": "abababababababababababababababababababababababababababababababab",
            "event_title": "Morning circle", "event_start_ms": 1, "state": "filed",
            "channel": null, "built_at_ms": 1794528000000,
            "take_id": "1111111111111111111111111111111111111111111111111111111111111111",
            "block_id": "2222222222222222222222222222222222222222222222222222222222222222",
            "tags": ["ev:abababababababab"], "filed_at": 1794528100, "signer_name": "Ada",
            "languages": { "en": 3 }, "speakers": 1, "marks": 2, "error_code": null,
            "updated_at": 1794528100
        } }
    }"#;

    #[test]
    fn an_option_file_from_before_audio_reads_as_audio_on_and_marks_gone() {
        let temp = tempfile::tempdir().unwrap();
        let core = core_in(&temp);
        std::fs::create_dir_all(core.city_path(FILINGS_FILE).parent().unwrap()).unwrap();
        std::fs::write(core.city_path(FILINGS_FILE), LEDGER_0_8_2).unwrap();

        let options = core.city_filing_options();
        assert!(options.audio, "没有这一项的旧选项:照默认,开着");
        assert!(
            !options.speaker_names && !options.automatic,
            "别的照旧读得出"
        );
        let old = core.city_filing("session-a".into()).unwrap();
        assert_eq!(old.state, FfiCityFilingState::Filed);
        assert_eq!(old.marks, 2, "以前交过几个标记,照实留着");
        assert!(old.audio_wanted && !old.audio_withheld);
        assert!(!old.audio_due, "以前只交了文字的,不替人补交音频");
        assert_eq!(
            (
                old.audio_parts_planned,
                old.audio_parts_filed,
                old.audio_error_code
            ),
            (0, 0, None)
        );
        assert!(core.city_pending_audio_sessions().is_empty());

        // 写回去以后:旧版非要不可的那一项还在,而且是 false —— 退回旧版的人
        // 账本还读得出,标记也不会再交。
        core.set_city_filing_options(options).unwrap();
        let written: Value =
            serde_json::from_slice(&std::fs::read(core.city_path(FILINGS_FILE)).unwrap()).unwrap();
        assert_eq!(
            written["options"],
            json!({ "speaker_names": false, "audio": true, "automatic": false, "marks": false })
        );
        #[derive(Deserialize)]
        struct OptionsAsOf082 {
            #[allow(dead_code)]
            speaker_names: bool,
            marks: bool,
            #[allow(dead_code)]
            automatic: bool,
        }
        let reread: OptionsAsOf082 = serde_json::from_value(written["options"].clone()).unwrap();
        assert!(!reread.marks);
        assert_eq!(written["filings"]["session-a"]["marks"], 2);
    }

    #[test]
    fn a_recording_can_go_without_audio_while_the_option_is_on() {
        let temp = tempfile::tempdir().unwrap();
        let core = core_in(&temp);
        assert_eq!(
            refusal(core.city_set_session_audio("session-a".into(), false)),
            code::UNBOUND,
            "还没归到活动,没有地方记"
        );
        bind(&core, "session-a");
        let bound = core.city_filing("session-a".into()).unwrap();
        assert!(bound.audio_wanted && !bound.audio_withheld, "默认带音频");

        let without = core
            .city_set_session_audio("session-a".into(), false)
            .unwrap();
        assert!(!without.audio_wanted && without.audio_withheld);
        // 换一场活动,这一场的选择还在。
        bind(&core, "session-a");
        assert!(core.city_filing("session-a".into()).unwrap().audio_withheld);
        let with = core
            .city_set_session_audio("session-a".into(), true)
            .unwrap();
        assert!(with.audio_wanted && !with.audio_withheld);

        // 设置是总开关:关着的时候,单场说「要」也不交。
        core.set_city_filing_options(FfiCityFilingOptions {
            audio: false,
            ..core.city_filing_options()
        })
        .unwrap();
        let off = core
            .city_set_session_audio("session-a".into(), true)
            .unwrap();
        assert!(!off.audio_wanted && !off.audio_withheld);
    }

    #[test]
    fn no_audio_is_read_signed_or_sent_unless_every_condition_holds() {
        let city = FakeCity::start();
        let temp = tempfile::tempdir().unwrap();
        let core = core_in(&temp);
        // 一个不存在的文件:过不了关的,连读都不该去读它。
        let nowhere = temp
            .path()
            .join("no-such.m4a")
            .to_string_lossy()
            .to_string();
        let attempt = |core: &ZuTalkCore| refusal(send_part(core, 0, 2, &nowhere));
        let held = |core: &ZuTalkCore| {
            let plan = core.city_audio_plan("session-a".into());
            assert!(!plan.upload);
            plan.hold_code.unwrap()
        };

        // 一、没登录。
        filed(&core, "session-a", true);
        assert_eq!(attempt(&core), code::SIGNED_OUT);
        assert_eq!(held(&core), code::SIGNED_OUT);
        assert!(
            core.city_pending_audio_sessions().is_empty(),
            "没登录:单子上没有它,App 不会去导出"
        );

        // 二、登录了,这场录音没归到活动;归了,文字还没交上去。
        sign_in(&core, &city, &["resident"]);
        core.city_bind_session("session-a".into(), None).unwrap();
        core.with_city_ledger(|ledger| ledger.filings.clear())
            .unwrap();
        assert_eq!(attempt(&core), code::UNBOUND);
        assert_eq!(held(&core), code::UNBOUND);
        bind(&core, "session-a");
        assert_eq!(attempt(&core), code::AUDIO_NOT_FILED);
        assert_eq!(held(&core), code::AUDIO_NOT_FILED);
        for state in [
            FilingState::Queued,
            FilingState::Failed,
            FilingState::Withdrawn,
        ] {
            core.city_set_state("session-a", state, None).unwrap();
            assert_eq!(attempt(&core), code::AUDIO_NOT_FILED, "{state:?}");
        }

        // 三、文字交了,设置里关着。
        filed(&core, "session-a", true);
        let options = core.city_filing_options();
        core.set_city_filing_options(FfiCityFilingOptions {
            audio: false,
            ..options
        })
        .unwrap();
        assert_eq!(attempt(&core), code::AUDIO_OFF);
        assert_eq!(held(&core), code::AUDIO_OFF);
        assert!(!core.city_filing("session-a".into()).unwrap().audio_wanted);
        assert!(core.city_pending_audio_sessions().is_empty());

        // 四、设置开着,这一场单独关了。
        core.set_city_filing_options(options).unwrap();
        core.city_set_session_audio("session-a".into(), false)
            .unwrap();
        assert_eq!(attempt(&core), code::AUDIO_WITHHELD);
        assert_eq!(held(&core), code::AUDIO_WITHHELD);
        assert!(core.city_pending_audio_sessions().is_empty());

        // 哪一回都没有碰过城,账本里也没有记下任何音频的事。
        assert_eq!(city.count(), 0);
        let filing = core.city_filing("session-a".into()).unwrap();
        assert_eq!(
            (
                filing.audio_parts_planned,
                filing.audio_parts_filed,
                filing.audio_error_code
            ),
            (0, 0, None)
        );
        assert!(core.city_sent_copy("session-a").parts.is_empty());

        // 四条都成立:这才去读那个文件(它不存在,所以是「这一段不能用」)。
        core.city_set_session_audio("session-a".into(), true)
            .unwrap();
        assert!(core.city_audio_plan("session-a".into()).upload);
        assert_eq!(attempt(&core), code::AUDIO_BAD_PART);
        assert_eq!(city.count(), 0);
    }

    #[test]
    fn each_part_is_claimed_on_the_event_tag_and_then_uploaded() {
        let city = FakeCity::start();
        let temp = tempfile::tempdir().unwrap();
        let core = core_in(&temp);
        sign_in(&core, &city, &["resident"]);
        let take = filed(&core, "session-a", true);
        let take_id = vt_city::record::record_id(&take).unwrap();
        let (first, second) = (m4a(1, 40_000), m4a(2, 30_000));
        let (first_path, second_path) = (
            part_file(&temp, "0.m4a", &first),
            part_file(&temp, "1.m4a", &second),
        );

        let plan = core.city_audio_plan("session-a".into());
        assert!(plan.upload && plan.due && plan.hold_code.is_none());
        assert_eq!(
            (plan.part_ms, plan.max_part_bytes, plan.mime.as_str()),
            (300_000, 16 * 1024 * 1024, "audio/mp4")
        );
        assert_eq!((plan.parts_planned, plan.parts_filed), (0, vec![]));
        assert_eq!(core.city_pending_audio_sessions(), ["session-a"]);

        let after_first = send_part(&core, 0, 2, &first_path).unwrap();
        assert_eq!(after_first.state, FfiCityFilingState::Filed);
        assert_eq!(
            (
                after_first.audio_parts_planned,
                after_first.audio_parts_filed,
                after_first.audio_error_code.clone(),
                after_first.error_code.clone(),
            ),
            (2, 1, None, None)
        );
        assert!(after_first.audio_due, "还差一段");
        // 先贴认领的记录,再问有没有,再传 —— 城要的就是这个顺序。
        let name = file_name(&first);
        assert_eq!(
            city.lines(),
            [
                format!("POST {EVENT_HUB}"),
                format!("GET /files/{name}"),
                format!("PUT /files/{name}"),
            ]
        );
        let posted = city.last_post();
        assert_eq!(
            posted
                .iter()
                .map(|record| record["e"]["type"].as_str().unwrap())
                .collect::<Vec<_>>(),
            ["id/inception", "tape/take", "tape/part"]
        );
        assert_eq!(posted[1], take, "那条录音原样再贴一遍");
        let part = &posted[2];
        assert!(vt_city::record::verify(part));
        assert_eq!(part["e"]["by"], test_identity().id());
        assert_eq!(part["e"]["links"], json!([take_id]));
        assert_eq!(
            part["e"]["body"],
            json!({
                "n": 0, "file": name, "size": 40_000, "t0": 0, "dur": 300_000,
                "mime": "audio/mp4", "lv": "0123456789",
            })
        );
        assert_eq!(
            city.asked.lock().unwrap()[2].1,
            first,
            "传的就是那个文件的字节"
        );

        let after_second = send_part(&core, 1, 2, &second_path).unwrap();
        assert_eq!(
            (
                after_second.audio_parts_planned,
                after_second.audio_parts_filed
            ),
            (2, 2)
        );
        assert!(!after_second.audio_due, "交完了");
        assert_eq!(city.last_post()[2]["e"]["body"]["t0"], 300_000);
        assert!(core.city_pending_audio_sessions().is_empty());
        assert_eq!(core.city_audio_plan("session-a".into()).parts_filed, [0, 1]);
        assert_eq!(city.count(), 6);

        // 已经在城里的一段再交一遍:不联网,什么都不变。连文件都不用在。
        std::fs::remove_file(&first_path).unwrap();
        let again = send_part(&core, 0, 2, &first_path).unwrap();
        assert_eq!(again.audio_parts_filed, 2);
        assert_eq!(city.count(), 6);

        // 交上去以后改了字、更新过去:音频的账原样带着,不会被冲掉。
        let sent = core.city_sent_copy("session-a");
        let carried = changes_since(&sent, &[line("a", 0, "hello", &[])]).copy;
        assert_eq!(carried.parts, sent.parts);
        assert_eq!(carried.take, Some(take));
        assert_eq!(carried.parts.len(), 2);
    }

    #[test]
    fn a_dropped_upload_resumes_at_the_first_missing_part() {
        let city = FakeCity::start();
        let temp = tempfile::tempdir().unwrap();
        let core = core_in(&temp);
        sign_in(&core, &city, &["resident"]);
        filed(&core, "session-a", true);
        let paths: Vec<String> = (0..3u8)
            .map(|n| part_file(&temp, &format!("{n}.m4a"), &m4a(n, 20_000 + usize::from(n))))
            .collect();

        // 第 0 段传上去了;第 1 段传到一半连接断了。
        send_part(&core, 0, 3, &paths[0]).unwrap();
        city.script(&[Put::HangUp]);
        let dropped = send_part(&core, 1, 3, &paths[1]).unwrap();
        assert_eq!(dropped.state, FfiCityFilingState::Filed, "文字照样是交了的");
        assert_eq!(dropped.error_code, None);
        assert_eq!(dropped.audio_error_code.as_deref(), Some(code::OFFLINE));
        assert_eq!(
            (dropped.audio_parts_planned, dropped.audio_parts_filed),
            (3, 1)
        );
        let signed_before = city.last_post()[2].clone();

        // 重新打开以后(另一个 core,同一个目录):单子上还有它,从第 1 段接着来。
        drop(core);
        let core = core_in(&temp);
        assert_eq!(core.city_pending_audio_sessions(), ["session-a"]);
        let plan = core.city_audio_plan("session-a".into());
        assert!(plan.upload && plan.due);
        assert_eq!((plan.parts_planned, plan.parts_filed), (3, vec![0]));
        let resumed = send_part(&core, 1, 3, &paths[1]).unwrap();
        assert_eq!(resumed.audio_error_code, None);
        assert_eq!(resumed.audio_parts_filed, 2);
        assert_eq!(
            city.last_post()[2],
            signed_before,
            "字节没变,签出来的是同一条记录:城里不会多出一条"
        );

        // 第 2 段:文件传完了,这一头没来得及记就退出了。
        send_part(&core, 2, 3, &paths[2]).unwrap();
        let path = core.city_sent_path("session-a").unwrap();
        let mut sent = core.city_sent_copy("session-a");
        sent.parts.get_mut(&2).unwrap().uploaded = false;
        write_private_json(&path, &sent).unwrap();
        let before = city.count();
        let noted = send_part(&core, 2, 3, &paths[2]).unwrap();
        assert_eq!(noted.audio_parts_filed, 3);
        assert_eq!(
            city.lines()[before..]
                .iter()
                .map(|line| line.split(' ').next().unwrap())
                .collect::<Vec<_>>(),
            ["POST", "GET"],
            "城里已经有这些字节:不传第二遍"
        );
        assert!(core.city_pending_audio_sessions().is_empty());
    }

    #[test]
    fn a_part_exported_again_with_other_bytes_takes_the_place_of_the_unfinished_one() {
        let city = FakeCity::start();
        let temp = tempfile::tempdir().unwrap();
        let core = core_in(&temp);
        sign_in(&core, &city, &["resident"]);
        filed(&core, "session-a", true);
        let (earlier, later) = (m4a(7, 20_000), m4a(8, 20_000));
        let path = part_file(&temp, "0.m4a", &earlier);

        city.script(&[Put::HangUp]);
        send_part(&core, 0, 1, &path).unwrap();
        let unfinished = city.last_post()[2].clone();
        assert_eq!(unfinished["e"]["body"]["file"], file_name(&earlier));

        // 重新导出的文件字节不一样了,前一个文件城里没有。
        std::fs::write(&path, &later).unwrap();
        let before = city.count();
        let replaced = send_part(&core, 0, 1, &path).unwrap();
        assert_eq!(
            (replaced.audio_parts_filed, replaced.audio_error_code),
            (1, None)
        );
        assert_eq!(
            city.lines()[before..],
            [
                format!("GET /files/{}", file_name(&earlier)),
                format!("POST {EVENT_HUB}"),
                format!("GET /files/{}", file_name(&later)),
                format!("PUT /files/{}", file_name(&later)),
            ]
        );
        let replacement = city.last_post()[2].clone();
        assert_eq!(replacement["e"]["body"]["file"], file_name(&later));
        assert_eq!(replacement["e"]["body"]["n"], 0);
        // 城对一个段号只认最先的那一条(按签的时刻):新的要排在指着空文件的
        // 那一条前面。城自己的代码怎么读这两条,见 tools/city-interop/check-take.mjs。
        assert_eq!(
            replacement["e"]["at"].as_i64().unwrap(),
            unfinished["e"]["at"].as_i64().unwrap() - 1
        );
    }

    #[test]
    fn a_part_whose_first_bytes_arrived_after_all_is_not_sent_twice() {
        let city = FakeCity::start();
        let temp = tempfile::tempdir().unwrap();
        let core = core_in(&temp);
        sign_in(&core, &city, &["resident"]);
        filed(&core, "session-a", true);
        let (earlier, later) = (m4a(7, 20_000), m4a(8, 20_000));
        let path = part_file(&temp, "0.m4a", &earlier);
        city.script(&[Put::HangUp]);
        send_part(&core, 0, 1, &path).unwrap();
        // 其实城收下了,只是回话没到。
        city.files.lock().unwrap().insert(file_name(&earlier));

        std::fs::write(&path, &later).unwrap();
        let before = city.count();
        let noted = send_part(&core, 0, 1, &path).unwrap();
        assert_eq!((noted.audio_parts_filed, noted.audio_error_code), (1, None));
        assert_eq!(
            city.lines()[before..],
            [format!("GET /files/{}", file_name(&earlier))],
            "这一段已经在城里了:不签第二条记录,不传第二份"
        );
    }

    #[test]
    fn a_file_is_not_counted_as_filed_unless_its_record_reached_the_city() {
        let city = FakeCity::start();
        let temp = tempfile::tempdir().unwrap();
        let core = core_in(&temp);
        sign_in(&core, &city, &["resident"]);
        filed(&core, "session-a", true);
        let (earlier, later) = (m4a(7, 20_000), m4a(8, 20_000));
        let path = part_file(&temp, "0.m4a", &earlier);

        // 记录没贴上去(连接断了):文件自然也没传。
        *city.lost_posts.lock().unwrap() = 1;
        let lost = send_part(&core, 0, 1, &path).unwrap();
        assert_eq!(lost.audio_error_code.as_deref(), Some(code::OFFLINE));
        assert_eq!(city.lines(), [format!("POST {EVENT_HUB}")]);
        let noted = core.city_sent_copy("session-a").parts[&0].clone();
        assert!(!noted.posted && !noted.uploaded);

        // 城里碰巧有一模一样的字节(比如另一段录音传过):不能凭这个就说这一段
        // 交了 —— 这段录音名下还没有指着它的记录。
        city.files.lock().unwrap().insert(file_name(&earlier));
        std::fs::write(&path, &later).unwrap();
        let before = city.count();
        let done = send_part(&core, 0, 1, &path).unwrap();
        assert_eq!((done.audio_parts_filed, done.audio_error_code), (1, None));
        assert_eq!(
            city.lines()[before..],
            [
                format!("POST {EVENT_HUB}"),
                format!("GET /files/{}", file_name(&later)),
                format!("PUT /files/{}", file_name(&later)),
            ]
        );
        assert_eq!(city.last_post()[2]["e"]["body"]["file"], file_name(&later));
        let kept = core.city_sent_copy("session-a").parts[&0].clone();
        assert!(kept.posted && kept.uploaded);
        assert_eq!(kept.file, file_name(&later));
    }

    #[test]
    fn each_way_the_city_turns_audio_down_is_told_apart_and_the_text_stays_filed() {
        let city = FakeCity::start();
        let temp = tempfile::tempdir().unwrap();
        let core = core_in(&temp);
        sign_in(&core, &city, &["resident"]);
        filed(&core, "session-a", true);
        let path = part_file(&temp, "0.m4a", &m4a(3, 20_000));

        for (answer, expect, worth_retrying) in [
            (Put::Status(403, None), code::AUDIO_REFUSED, false),
            (Put::Status(413, None), code::AUDIO_TOO_BIG, false),
            (Put::Status(507, None), code::AUDIO_SERVER_FULL, true),
            (Put::Status(400, None), code::SERVER, true),
            (Put::Status(500, None), code::SERVER, true),
            (Put::HangUp, code::OFFLINE, true),
        ] {
            city.script(&[answer]);
            let turned_down = send_part(&core, 0, 2, &path).unwrap();
            assert_eq!(turned_down.audio_error_code.as_deref(), Some(expect));
            assert_eq!(turned_down.audio_retry_at_epoch, None, "{expect}");
            // 「已交,音频没收下」,不是没交上。
            assert_eq!(turned_down.state, FfiCityFilingState::Filed, "{expect}");
            assert_eq!(turned_down.error_code, None, "{expect}");
            assert!(turned_down.web_url.is_some(), "{expect}");
            assert_eq!(turned_down.audio_parts_filed, 0, "{expect}");
            assert!(core.city_pending_sessions().is_empty(), "{expect}");
            assert_eq!(
                core.city_pending_audio_sessions().len(),
                usize::from(worth_retrying),
                "{expect}: 再试有没有用"
            );
            // 人再点一次总是可以的。
            assert!(core.city_audio_plan("session-a".into()).upload, "{expect}");
        }

        // 今天放得太多:记下城说的时候,到那时候之前不再去碰它。
        city.script(&[Put::Status(429, Some(3_600))]);
        let now = now_epoch();
        let capped = send_part(&core, 0, 2, &path).unwrap();
        assert_eq!(
            capped.audio_error_code.as_deref(),
            Some(code::AUDIO_DAILY_CAP)
        );
        let lifts = capped.audio_retry_at_epoch.unwrap();
        assert!((now + 3_599..=now + 3_602).contains(&lifts), "{lifts}");
        assert_eq!(capped.state, FfiCityFilingState::Filed);
        assert!(core.city_pending_audio_sessions().is_empty());
        let plan = core.city_audio_plan("session-a".into());
        assert!(!plan.upload);
        assert_eq!(plan.hold_code.as_deref(), Some(code::AUDIO_DAILY_CAP));
        let before = city.count();
        let still = send_part(&core, 0, 2, &path).unwrap();
        assert_eq!(still.audio_retry_at_epoch, Some(lifts));
        assert_eq!(city.count(), before, "没到时候:不联网");

        // 到时候了:单子上又有它,交成了,原因清掉。
        core.with_city_ledger(|ledger| {
            ledger.filings.get_mut("session-a").unwrap().audio.retry_at = Some(now - 1);
        })
        .unwrap();
        assert_eq!(core.city_pending_audio_sessions(), ["session-a"]);
        let done = send_part(&core, 0, 2, &path).unwrap();
        assert_eq!(
            (
                done.audio_parts_filed,
                done.audio_error_code,
                done.audio_retry_at_epoch
            ),
            (1, None, None)
        );
    }

    #[test]
    fn the_cap_lifts_at_the_next_utc_midnight_when_the_city_does_not_say() {
        // 2026-11-14 10:00:00 UTC。
        let now = 1_794_650_400;
        assert_eq!(now % DAY_SECS, 10 * 3_600);
        let said = audio_failure(
            &CityError::DailyCap {
                retry_after_secs: Some(90),
            },
            now,
        );
        assert_eq!(
            (said.code, said.retry_at),
            (code::AUDIO_DAILY_CAP, Some(now + 90))
        );
        let silent = audio_failure(
            &CityError::DailyCap {
                retry_after_secs: None,
            },
            now,
        );
        assert_eq!(silent.retry_at, Some(now + 14 * 3_600));
        // 再离谱的回话也不让人等过一天。
        let absurd = audio_failure(
            &CityError::DailyCap {
                retry_after_secs: Some(u64::MAX),
            },
            now,
        );
        assert_eq!(absurd.retry_at, Some(now + DAY_SECS));
        for (error, expect) in [
            (CityError::Unclaimed, code::AUDIO_REFUSED),
            (CityError::Refused, code::AUDIO_REFUSED),
            (CityError::FileTooBig, code::AUDIO_TOO_BIG),
            (CityError::ServerFull, code::AUDIO_SERVER_FULL),
            (CityError::BadFile, code::SERVER),
            (CityError::Http { status: 502 }, code::SERVER),
            (CityError::Offline, code::OFFLINE),
        ] {
            let failure = audio_failure(&error, now);
            assert_eq!((failure.code, failure.retry_at), (expect, None));
        }
    }

    #[test]
    fn what_the_app_hands_over_is_checked_before_anything_is_signed() {
        let city = FakeCity::start();
        let temp = tempfile::tempdir().unwrap();
        let core = core_in(&temp);
        sign_in(&core, &city, &["resident"]);
        filed(&core, "session-a", true);
        let good = part_file(&temp, "good.m4a", &m4a(1, 20_000));
        let call = |n: u32, total: u32, path: &str, t0_ms: i64, dur_ms: i64, levels: &str| {
            core.city_file_audio_part(
                "session-a".into(),
                n,
                total,
                path.to_string(),
                t0_ms,
                dur_ms,
                levels.to_string(),
            )
        };

        // 不是 MPEG-4 的文件:记录里写的是 audio/mp4,不能让别的东西顶着这个名字交上去。
        let mut wav = b"RIFF\x24\x08\x00\x00WAVEfmt ".to_vec();
        wav.resize(20_000, 0);
        let not_mp4 = part_file(&temp, "raw.wav", &wav);
        let empty = part_file(&temp, "empty.m4a", &[]);
        for (what, outcome) in [
            ("段号超出了一共几段", call(2, 2, &good, 0, 300_000, "")),
            ("一共零段", call(0, 0, &good, 0, 300_000, "")),
            ("起点是负的", call(0, 2, &good, -1, 300_000, "")),
            ("没有长度", call(0, 2, &good, 0, 0, "")),
            ("音量里有别的字", call(0, 2, &good, 0, 300_000, "12a")),
            (
                "音量超过一小时",
                call(0, 2, &good, 0, 300_000, &"5".repeat(3_601)),
            ),
            ("不是 MP4", call(0, 2, &not_mp4, 0, 300_000, "")),
            ("空文件", call(0, 2, &empty, 0, 300_000, "")),
            (
                "一个目录",
                call(0, 2, &temp.path().to_string_lossy(), 0, 300_000, ""),
            ),
        ] {
            assert_eq!(refusal(outcome), code::AUDIO_BAD_PART, "{what}");
        }
        // App 交错了东西,不是这场录音的状态:账本不动。
        let untouched = core.city_filing("session-a".into()).unwrap();
        assert_eq!(
            (
                untouched.audio_parts_planned,
                untouched.audio_error_code.clone()
            ),
            (0, None)
        );

        // 超过城收的大小:记下来给人看,一个字节都不读、不传。
        let huge = temp.path().join("huge.m4a");
        std::fs::File::create(&huge)
            .unwrap()
            .set_len(FILE_MAX_BYTES + 1)
            .unwrap();
        let too_big = call(0, 2, &huge.to_string_lossy(), 0, 300_000, "").unwrap();
        assert_eq!(
            too_big.audio_error_code.as_deref(),
            Some(code::AUDIO_TOO_BIG)
        );
        assert_eq!(too_big.state, FfiCityFilingState::Filed);
        assert_eq!(city.count(), 0, "哪一回都没有碰过城");
        assert!(core.city_sent_copy("session-a").parts.is_empty());
    }

    #[test]
    fn someone_the_city_does_not_house_signs_no_part() {
        let city = FakeCity::start();
        let temp = tempfile::tempdir().unwrap();
        let core = core_in(&temp);
        // 登录时还不是这座城的居民(主办可以不是居民:文字交得上,音频城不替他存)。
        sign_in(&core, &city, &[]);
        filed(&core, "session-a", true);
        let path = part_file(&temp, "0.m4a", &m4a(1, 20_000));

        let turned_away = send_part(&core, 0, 1, &path).unwrap();
        assert_eq!(
            turned_away.audio_error_code.as_deref(),
            Some(code::AUDIO_REFUSED)
        );
        assert_eq!(turned_away.state, FfiCityFilingState::Filed);
        assert_eq!(
            city.lines(),
            [format!(
                "GET /p/c0ffee00c0ffee00/vc?id={}",
                test_identity().id()
            )],
            "只问了一句名分;认领不上的分段不往公开的日志里贴"
        );
        assert!(core.city_sent_copy("session-a").parts.is_empty());

        // 后来入了城:现问得到,就交得上,名分也记下。
        city.roles.lock().unwrap().push("resident");
        let housed = send_part(&core, 0, 1, &path).unwrap();
        assert_eq!(
            (housed.audio_parts_filed, housed.audio_error_code),
            (1, None)
        );
        assert_eq!(core.city_account().unwrap().roles, ["resident"]);
    }

    #[test]
    fn audio_for_a_recording_filed_as_text_earlier_waits_to_be_asked_for() {
        let city = FakeCity::start();
        let temp = tempfile::tempdir().unwrap();
        let core = core_in(&temp);
        sign_in(&core, &city, &["resident"]);
        // 0.8.2 交的:细账里没有留那条录音。
        let take = filed(&core, "session-a", false);
        let paths: Vec<String> = (0..2u8)
            .map(|n| part_file(&temp, &format!("{n}.m4a"), &m4a(n, 20_000)))
            .collect();

        let before = core.city_filing("session-a".into()).unwrap();
        assert!(before.audio_wanted && !before.audio_due);
        assert!(
            core.city_pending_audio_sessions().is_empty(),
            "没有人开口,什么都不会自己交"
        );
        let plan = core.city_audio_plan("session-a".into());
        assert!(plan.upload && !plan.due, "人开口的话,交得了");
        assert_eq!(city.count(), 0);

        // 城里找不到那段录音(账本说交过,城里没有):不签,不传。
        let stranger = publish::build_take(
            &test_identity(),
            &TakeInput {
                event_id: EVENT.to_string(),
                started_ms: 1,
                ..TakeInput::default()
            },
            1_700_000_000_000,
        )
        .unwrap()
        .records[0]
            .clone();
        city.takes.lock().unwrap().push(stranger);
        let missing = send_part(&core, 0, 2, &paths[0]).unwrap();
        assert_eq!(missing.audio_error_code.as_deref(), Some(code::SERVER));
        assert_eq!(
            city.lines(),
            [format!("GET {EVENT_HUB}?since=0&wait=0&kinds=tape/take")]
        );

        // 人开了口:那条录音从活动的标签上取回来,连它一起贴。
        city.takes.lock().unwrap().push(take.clone());
        let start = city.count();
        let asked_for = send_part(&core, 0, 2, &paths[0]).unwrap();
        assert_eq!(
            (asked_for.audio_parts_filed, asked_for.audio_error_code),
            (1, None)
        );
        assert!(asked_for.audio_due, "开了口就算该交:断了自己接上");
        assert_eq!(
            city.lines()[start..]
                .iter()
                .map(|line| line.split(' ').next().unwrap())
                .collect::<Vec<_>>(),
            ["GET", "POST", "GET", "PUT"]
        );
        assert_eq!(city.last_post()[1], take);
        assert_eq!(core.city_pending_audio_sessions(), ["session-a"]);

        // 取回来的那一条记下了:下一段不用再取。
        let start = city.count();
        send_part(&core, 1, 2, &paths[1]).unwrap();
        assert_eq!(
            city.lines()[start..]
                .iter()
                .map(|line| line.split(' ').next().unwrap())
                .collect::<Vec<_>>(),
            ["POST", "GET", "PUT"]
        );
        assert!(core.city_pending_audio_sessions().is_empty());
    }

    #[test]
    fn withdrawing_leaves_the_count_of_filed_audio_and_filing_again_starts_over() {
        let city = FakeCity::start();
        let temp = tempfile::tempdir().unwrap();
        let core = core_in(&temp);
        sign_in(&core, &city, &["resident"]);
        filed(&core, "session-a", true);
        let path = part_file(&temp, "0.m4a", &m4a(1, 20_000));
        send_part(&core, 0, 2, &path).unwrap();

        // 撤下:那件素材从档案馆的页面上消失,交上去的音频还在城里。
        let withdrawn = core.city_withdraw_filing("session-a".into()).unwrap();
        assert_eq!(withdrawn.state, FfiCityFilingState::Withdrawn);
        assert_eq!(
            (withdrawn.audio_parts_planned, withdrawn.audio_parts_filed),
            (2, 1),
            "交上去的那一段撤不回来,照实留着"
        );
        assert!(!withdrawn.audio_due);
        assert!(core.city_pending_audio_sessions().is_empty());
        let posted = city.last_post();
        assert_eq!(posted.last().unwrap()["e"]["type"], "arc/mark");
        assert_eq!(posted.last().unwrap()["e"]["body"], json!({ "to": "drop" }));
        assert!(!posted
            .iter()
            .any(|record| record["e"]["type"] == "tape/part"));
        // 撤下以后不再往那段录音上交音频。
        assert_eq!(
            refusal(send_part(&core, 1, 2, &path)),
            code::AUDIO_NOT_FILED
        );

        // 再交是另一段录音:音频从头算。(假城的日历是空的,所以这一次交不上
        // —— 要看的只是账本在动手之前清了什么。)
        let again = core.city_file_session("session-a".into()).unwrap();
        assert_eq!(again.error_code.as_deref(), Some(code::EVENT_GONE));
        assert_eq!((again.audio_parts_planned, again.audio_parts_filed), (0, 0));
        let stored = core.city_ledger().filings["session-a"].clone();
        assert_eq!(stored.audio, StoredAudio::default());
        assert_eq!(stored.take_id, None);
    }

    #[test]
    fn progress_recorded_for_one_take_is_not_counted_for_the_next() {
        let city = FakeCity::start();
        let temp = tempfile::tempdir().unwrap();
        let core = core_in(&temp);
        sign_in(&core, &city, &["resident"]);
        filed(&core, "session-a", true);
        let path = part_file(&temp, "0.m4a", &m4a(1, 20_000));
        send_part(&core, 0, 1, &path).unwrap();
        assert_eq!(core.city_audio_plan("session-a".into()).parts_filed, [0]);

        // 账本指着另一段录音了,细账还是原来那一段的。
        core.with_city_ledger(|ledger| {
            ledger.filings.get_mut("session-a").unwrap().take_id = Some("cd".repeat(32));
        })
        .unwrap();
        assert!(core
            .city_audio_plan("session-a".into())
            .parts_filed
            .is_empty());
    }
}
