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
//! 只有一个不透明的公钥。**姓名和房间信息不进 mDNS 广播** —— 那会让咖啡馆里的
//! 任何人看到「谁在开什么会」。这些只在对方主动连上来、并且被问到时才给。

use serde::{Deserialize, Serialize};

/// 「附近的人」通道。与字幕、文档各自分开。
pub const NEARBY_ALPN: &[u8] = b"zulangue/nearby/1";

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

/// 同一网络里看到的一台 Zulangue。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NearbyPeer {
    pub endpoint_id: iroh::EndpointId,
    /// 给人看的短形式。局域网上除此之外看不到任何信息。
    pub short_label: String,
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
                share_code: "zulangueshare…".into(),
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

    /// 「还没开始共享」和「被拒绝了」必须分得开 —— 否则用户会反复敲门。
    #[test]
    fn deny_reasons_are_distinct() {
        assert_ne!(DenyReason::NotSharing, DenyReason::Declined);
        assert_ne!(DenyReason::Declined, DenyReason::TimedOut);
    }
}
