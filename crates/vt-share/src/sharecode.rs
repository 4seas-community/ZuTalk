//! 分享码。
//!
//! 交给对方的一串文本,里面装着找到本机所需的一切:直连地址、中继地址、房间密钥、
//! 共享范围。**因此分享码等同于房间钥匙**,不该贴进公开渠道。
//!
//! 内嵌直连地址是刻意的 —— 它让局域网在完全断网时也能配对,不依赖任何发现服务,
//! 也就不需要把用户地址发布到公共 pkarr / DNS。见 `share-p2p.md` 第 2.1 节。
//!
//! 编码沿用 iroh 的 ticket 约定(`iroh-tickets`):小写 kind 前缀 + 无填充 base32。

use iroh::EndpointAddr;
use iroh_tickets::{ParseError, Ticket};
use serde::{Deserialize, Serialize};

use crate::permission::WritePolicy;
use crate::room::{RoomSecret, ScopeId};

/// 分享码的线上表示。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
struct ShareCodeWire {
    host: EndpointAddr,
    scope: ScopeId,
    room_secret: [u8; 32],
    /// 主持人声明的写入策略。接收端据此初始化本地名册。
    host_only: bool,
}

/// 一份分享码。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ShareCode {
    /// 主持人的地址,含公钥与可直连的地址。
    pub host: EndpointAddr,
    pub scope: ScopeId,
    pub room_secret: RoomSecret,
    pub policy: WritePolicy,
}

impl ShareCode {
    pub fn new(
        host: EndpointAddr,
        scope: ScopeId,
        room_secret: RoomSecret,
        policy: WritePolicy,
    ) -> Self {
        Self {
            host,
            scope,
            room_secret,
            policy,
        }
    }

    /// 这份分享码对应的 gossip 房间。
    pub fn topic_id(&self) -> iroh_gossip::proto::TopicId {
        self.room_secret.topic_id(&self.scope)
    }

    fn to_wire(&self) -> ShareCodeWire {
        ShareCodeWire {
            host: self.host.clone(),
            scope: self.scope.clone(),
            room_secret: *self.room_secret.as_bytes(),
            host_only: matches!(self.policy, WritePolicy::HostOnly),
        }
    }

    fn from_wire(wire: ShareCodeWire) -> Self {
        Self {
            host: wire.host,
            scope: wire.scope,
            room_secret: RoomSecret::from_bytes(wire.room_secret),
            policy: if wire.host_only {
                WritePolicy::HostOnly
            } else {
                WritePolicy::Everyone
            },
        }
    }
}

impl Ticket for ShareCode {
    const KIND: &'static str = "zulangueshare";

    fn encode_bytes(&self) -> Vec<u8> {
        postcard::to_stdvec(&self.to_wire()).expect("ShareCode 必须可序列化")
    }

    fn decode_bytes(bytes: &[u8]) -> Result<Self, ParseError> {
        let wire: ShareCodeWire = postcard::from_bytes(bytes)?;
        Ok(Self::from_wire(wire))
    }
}

impl std::fmt::Display for ShareCode {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.encode_string())
    }
}

impl std::str::FromStr for ShareCode {
    type Err = ParseError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Self::decode_string(s.trim())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use iroh::SecretKey;
    use std::str::FromStr;

    fn code(policy: WritePolicy) -> ShareCode {
        let host = EndpointAddr::from(SecretKey::generate().public());
        ShareCode::new(
            host,
            ScopeId::Notebook {
                notebook_id: "nb-1".into(),
            },
            RoomSecret::from_bytes([7; 32]),
            policy,
        )
    }

    #[test]
    fn share_code_round_trips_through_string() {
        for policy in [WritePolicy::Everyone, WritePolicy::HostOnly] {
            let original = code(policy);
            let text = original.to_string();
            let back = ShareCode::from_str(&text).unwrap();
            assert_eq!(back, original);
            assert_eq!(back.policy, policy);
        }
    }

    /// 用户粘贴时常带首尾空白,不该因此失败。
    #[test]
    fn surrounding_whitespace_is_tolerated() {
        let original = code(WritePolicy::Everyone);
        let padded = format!("  \n{original}\t ");
        assert_eq!(ShareCode::from_str(&padded).unwrap(), original);
    }

    /// 前缀是身份的一部分:别的 iroh ticket 不能被当成分享码吃进来。
    #[test]
    fn foreign_ticket_kinds_are_refused() {
        let text = code(WritePolicy::Everyone).to_string();
        let swapped = text.replacen(ShareCode::KIND, "endpoint", 1);
        assert!(ShareCode::from_str(&swapped).is_err());
    }

    #[test]
    fn garbage_is_refused() {
        assert!(ShareCode::from_str("").is_err());
        assert!(ShareCode::from_str("zulangueshare").is_err());
        assert!(ShareCode::from_str("zulangueshare!!!not-base32!!!").is_err());
    }

    /// 分享码决定房间,而房间由 secret 与 scope 共同派生。
    #[test]
    fn topic_matches_the_room_derivation() {
        let c = code(WritePolicy::Everyone);
        assert_eq!(c.topic_id(), c.room_secret.topic_id(&c.scope));
    }

    /// 换一个 room_secret 就是换一个房间 —— 老分享码进不来新房间。
    #[test]
    fn rotating_the_secret_invalidates_the_old_code() {
        let old = code(WritePolicy::Everyone);
        let mut rotated = old.clone();
        rotated.room_secret = RoomSecret::from_bytes([9; 32]);
        assert_ne!(old.topic_id(), rotated.topic_id());
    }

    /// 编码是规范形式:同一份分享码每次编出同一串。
    #[test]
    fn encoding_is_deterministic() {
        let c = code(WritePolicy::HostOnly);
        assert_eq!(c.to_string(), c.to_string());
        assert!(c.to_string().starts_with(ShareCode::KIND));
    }
}
