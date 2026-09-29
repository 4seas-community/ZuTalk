//! 配对码:把一台设备加进一个同步空间。
//!
//! 空间里的设备生成配对码(本机地址 + 一次性密钥 + 用途),对方输入或粘贴后拨过来,
//! 出示由密钥推出的证明。证明绑定了双方的设备 id,所以截获一次证明换个设备重放没用;
//! 密钥本身不上线。配对码**一次有效、十分钟过期**,用过或过期即作废。
//!
//! 用途(加自己的 Mac、邀请协作主题、指定备份机)写在码里,让加入方粘贴后就知道
//! 这是什么;真正以邀请方配对成功时的答复为准。
//!
//! 配对码等同于进门的钥匙,界面上应当只在邀请时显示,不该贴进公开渠道。

use std::str::FromStr;
use std::time::Duration;

use iroh::{EndpointAddr, EndpointId};
use iroh_tickets::{ParseError, Ticket};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::protocol::SpaceId;

/// 配对通道。
pub const PAIR_ALPN: &[u8] = b"zutalk/device-pair/1";

/// 配对码的有效期。
pub const INVITE_TTL: Duration = Duration::from_secs(10 * 60);

/// 设备名字的上限。它由对方提供,会显示在本机的设备列表里。
pub const MAX_DEVICE_NAME_BYTES: usize = 64;

/// 配对码是干什么用的。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum InvitePurpose {
    /// 把自己的另一台 Mac 加进设备组。
    Device,
    /// 邀请别人一起编辑一个主题。
    Topic,
    /// 把一台 Mac 指定为备份机。
    Backup,
}

#[derive(Clone, PartialEq, Eq)]
pub struct PairingTicket {
    /// 邀请方的地址:设备 id、直连地址、中继。
    pub inviter: EndpointAddr,
    /// 邀请方生成时声明的用途。只用于加入前的提示。
    pub purpose: InvitePurpose,
    secret: [u8; 32],
}

impl std::fmt::Debug for PairingTicket {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // 密钥不进日志。
        write!(f, "PairingTicket({})", self.inviter.id.fmt_short())
    }
}

#[derive(Serialize, Deserialize)]
struct TicketWire {
    inviter: EndpointAddr,
    purpose: InvitePurpose,
    secret: [u8; 32],
}

impl PairingTicket {
    pub(crate) fn new(inviter: EndpointAddr, secret: [u8; 32], purpose: InvitePurpose) -> Self {
        Self {
            inviter,
            purpose,
            secret,
        }
    }

    pub(crate) fn proof_for(&self, joiner: &EndpointId) -> [u8; 32] {
        proof(&self.secret, joiner, &self.inviter.id)
    }
}

impl Ticket for PairingTicket {
    const KIND: &'static str = "zutalkpair";

    fn encode_bytes(&self) -> Vec<u8> {
        postcard::to_stdvec(&TicketWire {
            inviter: self.inviter.clone(),
            purpose: self.purpose,
            secret: self.secret,
        })
        .expect("配对码必须可序列化")
    }

    fn decode_bytes(bytes: &[u8]) -> Result<Self, ParseError> {
        let wire: TicketWire = postcard::from_bytes(bytes)?;
        Ok(Self::new(wire.inviter, wire.secret, wire.purpose))
    }
}

impl std::fmt::Display for PairingTicket {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.encode_string())
    }
}

impl FromStr for PairingTicket {
    type Err = ParseError;

    /// 宽容地解析粘贴进来的东西:聊天软件会折行、输入法会把首字母大写。base32
    /// 大小写无关,空白也从不属于码的内容,去掉它们不会放进本该被拒的输入。
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        let normalized: String = s
            .chars()
            .filter(|c| !c.is_whitespace())
            .flat_map(char::to_lowercase)
            .collect();
        Self::decode_string(&normalized)
    }
}

/// 证明「我拿着这张配对码」。绑定双方 id:同一份证明换一台设备出示无效。
fn proof(secret: &[u8; 32], joiner: &EndpointId, inviter: &EndpointId) -> [u8; 32] {
    let mut hasher = Sha256::new();
    hasher.update(b"zutalk/pair/v1");
    hasher.update(secret);
    hasher.update(joiner.as_bytes());
    hasher.update(inviter.as_bytes());
    hasher.finalize().into()
}

/// 配对通道上的消息。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) enum PairMessage {
    Request {
        proof: [u8; 32],
        device_name: String,
        /// 加入方自己的地址。邀请方之后要拨回来同步,不能只靠这一次来电。
        joiner: EndpointAddr,
    },
    Accepted {
        space: SpaceId,
        purpose: InvitePurpose,
        /// 邀请方给这个空间的说明(主题名等),给人看。
        label: String,
        /// 给应用自己用的上下文(比如协作主题的 id),不给人看。
        context: String,
        inviter_name: String,
    },
    Rejected {
        reason: PairRejection,
    },
}

/// 为什么没配上。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, thiserror::Error)]
pub enum PairRejection {
    /// 配对码不对、用过了或过期了。三者对外不区分,免得给猜码的人线索。
    #[error("配对码无效或已过期")]
    InvalidOrExpired,
    /// 对方收下了配对码,但没能把本机记进名单(或那个空间已经不在了)。
    #[error("对方暂时无法添加设备")]
    Unavailable,
}

/// 把对方自报的设备名收拾成能显示的样子:去掉控制字符(能伪造换行),压掉首尾
/// 空白,按字符截断而不是字节,不把多字节字符劈成两半。
pub fn sanitize_device_name(raw: &str) -> String {
    let cleaned: String = raw.chars().filter(|c| !c.is_control()).collect();
    let mut out = String::new();
    for c in cleaned.trim().chars() {
        if out.len() + c.len_utf8() > MAX_DEVICE_NAME_BYTES {
            break;
        }
        out.push(c);
    }
    out
}

/// 一张还没用掉的配对码。
#[derive(Debug, Clone)]
pub(crate) struct OpenInvite {
    secret: [u8; 32],
    expires: tokio::time::Instant,
    pub(crate) space: SpaceId,
    pub(crate) purpose: InvitePurpose,
    pub(crate) label: String,
    pub(crate) context: String,
}

/// 邀请方手里还没用掉的配对码。
#[derive(Debug, Default)]
pub(crate) struct InviteBook {
    open: std::sync::Mutex<Vec<OpenInvite>>,
}

impl InviteBook {
    pub(crate) fn issue(
        &self,
        secret: [u8; 32],
        space: SpaceId,
        purpose: InvitePurpose,
        label: String,
        context: String,
        ttl: Duration,
    ) {
        let now = tokio::time::Instant::now();
        let mut open = self.open.lock().unwrap();
        open.retain(|invite| invite.expires > now);
        open.push(OpenInvite {
            secret,
            expires: now + ttl,
            space,
            purpose,
            label,
            context,
        });
    }

    /// 核对证明。对上且没过期就当场作废这张码并交出它。
    pub(crate) fn redeem(
        &self,
        presented: &[u8; 32],
        joiner: &EndpointId,
        inviter: &EndpointId,
    ) -> Option<OpenInvite> {
        let now = tokio::time::Instant::now();
        let mut open = self.open.lock().unwrap();
        open.retain(|invite| invite.expires > now);
        let index = open.iter().position(|invite| {
            constant_time_eq(&proof(&invite.secret, joiner, inviter), presented)
        })?;
        Some(open.remove(index))
    }

    /// 作废一个空间的全部配对码(空间关了、或邀请方点了「取消邀请」)。
    pub(crate) fn revoke_space(&self, space: &SpaceId) {
        self.open
            .lock()
            .unwrap()
            .retain(|invite| invite.space != *space);
    }
}

fn constant_time_eq(a: &[u8; 32], b: &[u8; 32]) -> bool {
    a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

#[cfg(test)]
mod tests {
    use super::*;

    fn some_id() -> EndpointId {
        iroh::SecretKey::generate().public()
    }

    #[test]
    fn a_ticket_survives_being_mangled_on_the_way_and_hides_its_secret() {
        let ticket =
            PairingTicket::new(EndpointAddr::new(some_id()), [7; 32], InvitePurpose::Topic);
        let text = ticket.to_string();
        assert!(text.starts_with("zutalkpair"));

        // 聊天软件折行 + 输入法首字母大写。
        let (head, tail) = text.split_at(20);
        let mangled = format!("  {}\n{}  ", head.to_uppercase(), tail);
        let parsed = mangled.parse::<PairingTicket>().unwrap();
        assert_eq!(parsed, ticket);
        assert_eq!(parsed.purpose, InvitePurpose::Topic);

        assert!(!format!("{ticket:?}").contains(&hex::encode([7u8; 32])));
    }

    #[test]
    fn an_invite_is_redeemed_once_and_only_by_the_device_it_was_proven_for() {
        let book = InviteBook::default();
        let (inviter, joiner, other) = (some_id(), some_id(), some_id());
        let space = SpaceId::generate();
        let ticket = PairingTicket::new(EndpointAddr::new(inviter), [9; 32], InvitePurpose::Device);
        book.issue(
            [9; 32],
            space,
            InvitePurpose::Device,
            String::new(),
            String::new(),
            INVITE_TTL,
        );

        let proof = ticket.proof_for(&joiner);
        assert!(
            book.redeem(&proof, &other, &inviter).is_none(),
            "证明绑定了加入方"
        );
        let redeemed = book.redeem(&proof, &joiner, &inviter).expect("应当对上");
        assert_eq!(redeemed.space, space);
        assert!(book.redeem(&proof, &joiner, &inviter).is_none(), "一次有效");
    }

    #[tokio::test(start_paused = true)]
    async fn an_invite_expires() {
        let book = InviteBook::default();
        let (inviter, joiner) = (some_id(), some_id());
        let ticket = PairingTicket::new(EndpointAddr::new(inviter), [3; 32], InvitePurpose::Device);
        book.issue(
            [3; 32],
            SpaceId::generate(),
            InvitePurpose::Device,
            String::new(),
            String::new(),
            INVITE_TTL,
        );
        tokio::time::advance(INVITE_TTL + Duration::from_secs(1)).await;
        assert!(book
            .redeem(&ticket.proof_for(&joiner), &joiner, &inviter)
            .is_none());
    }

    #[test]
    fn revoking_a_space_voids_its_open_invites_only() {
        let book = InviteBook::default();
        let (inviter, joiner) = (some_id(), some_id());
        let (kept, revoked) = (SpaceId::generate(), SpaceId::generate());
        book.issue(
            [1; 32],
            revoked,
            InvitePurpose::Topic,
            "周会".into(),
            String::new(),
            INVITE_TTL,
        );
        book.issue(
            [2; 32],
            kept,
            InvitePurpose::Topic,
            "访谈".into(),
            String::new(),
            INVITE_TTL,
        );
        book.revoke_space(&revoked);
        let gone = PairingTicket::new(EndpointAddr::new(inviter), [1; 32], InvitePurpose::Topic);
        let alive = PairingTicket::new(EndpointAddr::new(inviter), [2; 32], InvitePurpose::Topic);
        assert!(book
            .redeem(&gone.proof_for(&joiner), &joiner, &inviter)
            .is_none());
        assert_eq!(
            book.redeem(&alive.proof_for(&joiner), &joiner, &inviter)
                .map(|i| i.label),
            Some("访谈".to_string())
        );
    }

    #[test]
    fn device_names_are_cleaned_and_cut_on_character_boundaries() {
        assert_eq!(sanitize_device_name("  工作\n的 Mac \u{7}"), "工作的 Mac");
        let long = "长".repeat(40);
        let cut = sanitize_device_name(&long);
        assert!(cut.len() <= MAX_DEVICE_NAME_BYTES);
        assert_eq!(cut, "长".repeat(21));
    }
}
