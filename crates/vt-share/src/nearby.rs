//! 同一网络里的人:发现、请求加入、批准。
//!
//! # 为什么不是「发现即可进」
//!
//! 分享码里带的不只是地址,还有 [`crate::RoomSecret`] —— 那才是进房间的钥匙。
//! mDNS 找得到机器,但给不了房间权限,所以「看见就能加入」在架构上不成立,
//! 而且它**不该**成立:一台机器出现在局域网里,不代表它的主人想让你进来。
//!
//! 正确的形状是三步:发现 → 请求 → 主持人批准。批准之后钥匙经由那条已认证的
//! 直连交出。这比把 129 个字符的分享码贴进聊天软件**更安全** —— 钥匙不出局域网,
//! 不经过第三方,也不会留在别人的聊天记录里。
//!
//! # 局域网上能看到什么
//!
//! 默认只有一个不透明的公钥。姓名和录音标题只在**主持人为这一场直播打开
//! 「让附近的人找到」**时才进 mDNS 广播([`NearbyAnnouncement`]) —— 那是
//! 主持人对「同一网络的人都能看到我在直播什么」的明确同意。没打开时,
//! 附近列表里根本不出现这台机器,敲门也只会得到「没在共享」。

use serde::{Deserialize, Serialize};

/// 「附近的人」通道。与字幕、文档各自分开。
pub const NEARBY_ALPN: &[u8] = b"zutalk/nearby/1";

/// 自报的名字最长多少字节。
///
/// 它由对方提供,会显示在你的屏幕上,所以要有上限 —— 一个几 KB 的「名字」既能
/// 撑破界面,也是一种骚扰。
pub const MAX_DISPLAY_NAME_BYTES: usize = 64;

/// 这条通道上的消息。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum NearbyMessage {
    /// 「我是谁,我想加入」。
    JoinRequest { display_name: String },
    /// 批准,并交出分享码。
    JoinGranted { share_code: String },
    /// 不批准。
    JoinDenied { reason: DenyReason },
}

/// 为什么没让你进。
///
/// 「对方没在共享」和「对方拒绝了你」必须分开 —— 前者再等等就好,
/// 后者再请求多少次都没用。混成一句话会让人反复敲门。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum DenyReason {
    /// 对方此刻并没有在共享任何东西。
    NotSharing,
    /// 对方看到了请求,拒绝了。
    Declined,
    /// 对方一直没理。
    TimedOut,
}

/// 把自报的名字收拾成可以显示的样子。
///
/// 名字来自对方,所以要当作不可信输入:去掉控制字符(它们能伪造换行和缩进,
/// 把一条请求伪装成两条)、压掉首尾空白、按**字符**截断而不是字节,免得把
/// 一个多字节字符劈成两半。
pub fn sanitize_display_name(raw: &str) -> String {
    let cleaned: String = raw
        .chars()
        .filter(|c| !c.is_control())
        .collect::<String>()
        .trim()
        .to_string();
    if cleaned.is_empty() {
        return String::new();
    }
    let mut out = String::new();
    for c in cleaned.chars() {
        if out.len() + c.len_utf8() > MAX_DISPLAY_NAME_BYTES {
            break;
        }
        out.push(c);
    }
    out
}

/// 一个正在等你回答的加入请求。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PendingJoinRequest {
    /// 用来回答这一条请求。
    pub request_id: String,
    /// 请求方的公钥。**这是唯一可信的身份** —— 名字是对方随便写的。
    pub endpoint_id: iroh::EndpointId,
    /// 对方自报的名字,已经收拾过。可能为空。
    pub display_name: String,
}

/// 同一网络里一场愿意被找到的直播。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NearbyPeer {
    pub endpoint_id: iroh::EndpointId,
    /// 公钥的短形式。名字是对方自己写的,它才是可核对的身份。
    pub short_label: String,
    /// 主持人自报的名字与录音标题,已经收拾过。
    pub announcement: NearbyAnnouncement,
}

/// 主持人同意公开到局域网上的那两句话。
///
/// 装在 mDNS 的 TXT 记录里(iroh 的 user data,上限 245 字节),所以编码后
/// 必须放得下:名字已有 64 字节上限,标题按字符截到剩余空间。
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct NearbyAnnouncement {
    #[serde(rename = "n")]
    pub host_name: String,
    #[serde(rename = "t")]
    pub title: String,
}

/// mDNS TXT 记录里 user data 的上限(iroh `UserData::MAX_LENGTH`)。
pub const MAX_ANNOUNCEMENT_BYTES: usize = 245;
/// 编码的版本前缀。关掉公开时发的是 [`NEARBY_SILENT`] 而不是清空 ——
/// mDNS 服务更新地址时只在有值时覆写 TXT,清空会让旧标题一直挂着。
const NEARBY_LIVE_PREFIX: &str = "zt1";
pub const NEARBY_SILENT: &str = "zt0";

impl NearbyAnnouncement {
    pub fn new(host_name: &str, title: &str) -> Self {
        Self {
            host_name: sanitize_display_name(host_name),
            title: sanitize_label(title, 160),
        }
    }

    /// 编成 TXT 记录能装下的一行。标题太长时逐字缩短,直到放得下。
    pub fn encode(&self) -> String {
        let mut announcement = self.clone();
        loop {
            let body = serde_json::to_string(&announcement).unwrap_or_default();
            let encoded = format!("{NEARBY_LIVE_PREFIX}{body}");
            if encoded.len() <= MAX_ANNOUNCEMENT_BYTES || announcement.title.is_empty() {
                return encoded;
            }
            announcement.title.pop();
        }
    }

    /// 解开别人的广播。不是直播宣告(旧版本、关着公开、乱码)一律 `None`。
    /// 内容来自局域网上的任何人,所以照样当不可信输入收拾一遍。
    pub fn decode(raw: &str) -> Option<Self> {
        let body = raw.strip_prefix(NEARBY_LIVE_PREFIX)?;
        let parsed: Self = serde_json::from_str(body).ok()?;
        Some(Self::new(&parsed.host_name, &parsed.title))
    }
}

/// 与 [`sanitize_display_name`] 同一套收拾,上限另给。
fn sanitize_label(raw: &str, max_bytes: usize) -> String {
    let cleaned: String = raw.chars().filter(|c| !c.is_control()).collect();
    let mut out = String::new();
    for c in cleaned.trim().chars() {
        if out.len() + c.len_utf8() > max_bytes {
            break;
        }
        out.push(c);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn messages_round_trip() {
        for message in [
            NearbyMessage::JoinRequest {
                display_name: "楼下的 Mac".into(),
            },
            NearbyMessage::JoinGranted {
                share_code: "zutalkshare…".into(),
            },
            NearbyMessage::JoinDenied {
                reason: DenyReason::Declined,
            },
        ] {
            let bytes = serde_json::to_vec(&message).unwrap();
            assert_eq!(
                serde_json::from_slice::<NearbyMessage>(&bytes).unwrap(),
                message
            );
        }
    }

    #[test]
    fn an_ordinary_name_survives() {
        assert_eq!(sanitize_display_name("  楼下的 Mac  "), "楼下的 Mac");
    }

    /// 控制字符能伪造换行和缩进,把一条请求在界面上伪装成两条。
    #[test]
    fn control_characters_are_stripped() {
        assert_eq!(sanitize_display_name("访客\n批准\t了\u{0}"), "访客批准了");
    }

    /// 名字要显示在别人屏幕上,必须有上限。
    #[test]
    fn an_overlong_name_is_truncated() {
        let name = sanitize_display_name(&"x".repeat(500));
        assert_eq!(name.len(), MAX_DISPLAY_NAME_BYTES);
    }

    /// 按字符截断,不能把一个多字节字符劈成两半。
    #[test]
    fn truncation_never_splits_a_character() {
        let name = sanitize_display_name(&"の".repeat(100));
        assert!(name.len() <= MAX_DISPLAY_NAME_BYTES);
        assert!(std::str::from_utf8(name.as_bytes()).is_ok());
        assert!(name.chars().all(|c| c == 'の'));
    }

    #[test]
    fn an_empty_name_stays_empty() {
        assert_eq!(sanitize_display_name("   \n\t "), "");
    }

    #[test]
    fn an_announcement_round_trips_and_fits() {
        let long = NearbyAnnouncement::new(&"名".repeat(40), &"長い題名".repeat(60));
        let encoded = long.encode();
        assert!(encoded.len() <= MAX_ANNOUNCEMENT_BYTES);
        let decoded = NearbyAnnouncement::decode(&encoded).unwrap();
        assert_eq!(decoded.host_name, long.host_name);
        assert!(long.title.starts_with(&decoded.title));

        let short = NearbyAnnouncement::new("楼下的 Mac", "周会");
        assert_eq!(NearbyAnnouncement::decode(&short.encode()), Some(short));
    }

    /// 关着公开、旧版本、别人塞进来的乱码,都不算一场直播。
    #[test]
    fn only_a_live_announcement_decodes() {
        assert_eq!(NearbyAnnouncement::decode(NEARBY_SILENT), None);
        assert_eq!(NearbyAnnouncement::decode("foobar"), None);
        assert_eq!(NearbyAnnouncement::decode("zt1{not json"), None);
        let spoofed = NearbyAnnouncement::decode(r#"zt1{"n":"a\nb","t":"x\ty"}"#).unwrap();
        assert_eq!(spoofed.host_name, "ab");
        assert_eq!(spoofed.title, "xy");
    }

    /// 「还没开始共享」和「被拒绝了」必须分得开 —— 否则用户会反复敲门。
    #[test]
    fn deny_reasons_are_distinct() {
        assert_ne!(DenyReason::NotSharing, DenyReason::Declined);
        assert_ne!(DenyReason::Declined, DenyReason::TimedOut);
    }
}
