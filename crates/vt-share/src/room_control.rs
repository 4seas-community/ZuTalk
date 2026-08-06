//! 房间控制面:在场状态与名册。
//!
//! 这条通道跑在 `iroh-gossip` 上,**只承载小消息**。gossip 单条消息默认上限 4096
//! 字节(`iroh_gossip::proto::DEFAULT_MAX_MESSAGE_SIZE`),所以文档更新与字幕都不
//! 走这里 —— 它们各有自己的直连通道。
//!
//! 名册的权威只有一个:主持人。成员各自广播「我在」,但谁算数由主持人的名册说了算。
//! 这不是信任问题而是收敛问题 —— 让每个节点自己拼名册,断线重连后各家会得出不同的
//! 成员集合。
//!
//! 见 `docs/architecture/share-p2p.md` 第 2、4 节。

use std::collections::BTreeSet;

use iroh::{EndpointId, SecretKey};
use serde::{Deserialize, Serialize};

use crate::envelope::{EnvelopeError, PayloadKind, ShareEnvelope, UnsignedEnvelope};
use crate::permission::{RoomRoster, WritePolicy};
use crate::room::ScopeId;

/// 一份名册最多容纳的成员数。
///
/// 上限由 gossip 的 4096 字节决定,不是拍脑袋定的:每个成员 32 字节公钥,加上信封
/// 本身(公钥 32 + 签名 64 + scope + 类型标签)约 150 字节的固定开销。64 个成员
/// 用掉约 2.2 KB,留足一半余量给 scope 里的长 id。
/// `roster_at_capacity_fits_in_one_gossip_message` 对此有断言。
pub const MAX_ROSTER_MEMBERS: usize = 64;

/// 控制面消息。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum RoomControl {
    /// 「我在这个房间里,我叫这个名字」。新加入者与断线重连者都发它。
    ///
    /// **名字跟着 Hello 走,不进 Roster。** Roster 要装下 64 个成员,每人再加
    /// 一个名字就会撑破 gossip 的 4096 字节上限;而 Hello 是一人一条,加个
    /// 有界的名字绰绰有余。各人从收到的 Hello 里自己攒出名字表。
    Hello { display_name: String },
    /// 主持人广播的权威名册。其他人发的一律忽略。
    Roster {
        members: Vec<[u8; 32]>,
        host_only: bool,
    },
    /// 主动离开。收不到也没关系 —— gossip 的 `NeighborDown` 是兜底。
    Goodbye,
}

impl RoomControl {
    /// 本机该广播的 Hello,带上自己的名字(先收拾干净)。
    pub fn hello(display_name: &str) -> Self {
        Self::Hello {
            display_name: crate::nearby::sanitize_display_name(display_name),
        }
    }
}

/// 控制面消息处理失败的原因。
#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
pub enum ControlError {
    #[error("信封校验失败: {0}")]
    Envelope(#[from] EnvelopeError),
    #[error("载荷类型不属于控制面")]
    WrongPayloadKind,
    #[error("控制面消息无法解码")]
    Malformed,
    #[error("名册只有主持人可以广播")]
    RosterFromNonHost,
    #[error("名册 {actual} 人,超过上限 {MAX_ROSTER_MEMBERS}")]
    RosterTooLarge { actual: usize },
    #[error("消息 {actual} 字节,超过 gossip 单条上限")]
    TooLargeForGossip { actual: usize },
    #[error("自报的名字过长")]
    DisplayNameTooLong,
}

/// 把一条控制面消息签名并编码成可以交给 gossip 的字节。
pub fn seal(
    control: &RoomControl,
    scope: &ScopeId,
    secret: &SecretKey,
) -> Result<Vec<u8>, ControlError> {
    if let RoomControl::Roster { members, .. } = control {
        if members.len() > MAX_ROSTER_MEMBERS {
            return Err(ControlError::RosterTooLarge {
                actual: members.len(),
            });
        }
    }
    let payload = postcard::to_stdvec(control).map_err(|_| ControlError::Malformed)?;
    let bytes = UnsignedEnvelope::new(scope.clone(), PayloadKind::RoomControl, payload)
        .sign(secret)
        .encode_compact()?;

    // 超限的消息 gossip 会直接拒收。与其让它静默消失,不如在这里就报出来。
    if bytes.len() > iroh_gossip::proto::DEFAULT_MAX_MESSAGE_SIZE {
        return Err(ControlError::TooLargeForGossip {
            actual: bytes.len(),
        });
    }
    Ok(bytes)
}

/// 校验并取出一条控制面消息。
///
/// 与文档通道一样,验签排在最前:在知道作者是谁之前,任何基于作者的判断都无意义。
pub fn open(
    bytes: &[u8],
    scope: &ScopeId,
    host: EndpointId,
) -> Result<(EndpointId, RoomControl), ControlError> {
    let envelope = ShareEnvelope::decode_compact(bytes)?;
    envelope.verify(scope)?;
    if envelope.kind != PayloadKind::RoomControl {
        return Err(ControlError::WrongPayloadKind);
    }
    let control: RoomControl =
        postcard::from_bytes(&envelope.payload).map_err(|_| ControlError::Malformed)?;

    match &control {
        RoomControl::Roster { members, .. } => {
            if envelope.author != host {
                return Err(ControlError::RosterFromNonHost);
            }
            if members.len() > MAX_ROSTER_MEMBERS {
                return Err(ControlError::RosterTooLarge {
                    actual: members.len(),
                });
            }
        }
        RoomControl::Hello { display_name } => {
            // 名字由对方自己填,当作不可信输入。超长的直接拒 —— 它会被广播给
            // 房间里每个人,不该由一个人决定别人屏幕上显示多少字。
            if display_name.len() > crate::nearby::MAX_DISPLAY_NAME_BYTES {
                return Err(ControlError::DisplayNameTooLong);
            }
        }
        RoomControl::Goodbye => {}
    }
    Ok((envelope.author, control))
}

/// 本机看到的房间在场状态。
///
/// 主持人这一侧用它累积「谁打过招呼」,再据此广播名册;观看者这一侧用它跟随主持人
/// 的名册。两种角色共用一个类型,差别只在谁有权写。
#[derive(Debug)]
pub struct RoomPresence {
    scope: ScopeId,
    host: EndpointId,
    is_host: bool,
    seen: BTreeSet<EndpointId>,
    roster: RoomRoster,
    /// 谁叫什么。从各自的 Hello 里攒出来 —— 名册广播装不下这些。
    names: std::collections::BTreeMap<EndpointId, String>,
}

impl RoomPresence {
    /// `my_name` 是本机的昵称。**要在这里记下来** —— 它随 Hello 广播出去,
    /// 但 gossip 不会把自己的消息回送给自己,不记就永远看不到自己的名字。
    pub fn new(
        scope: ScopeId,
        host: EndpointId,
        me: EndpointId,
        my_name: &str,
        policy: WritePolicy,
    ) -> Self {
        let mut seen = BTreeSet::new();
        seen.insert(host);
        seen.insert(me);
        let mut roster = RoomRoster::new(scope.clone(), host, policy);
        roster.admit(me);
        let mut names = std::collections::BTreeMap::new();
        let cleaned = crate::nearby::sanitize_display_name(my_name);
        if !cleaned.is_empty() {
            names.insert(me, cleaned);
        }
        Self {
            scope,
            host,
            is_host: me == host,
            seen,
            roster,
            names,
        }
    }

    /// 房间里某人的名字。没自报过就没有。
    pub fn name_of(&self, who: EndpointId) -> Option<&str> {
        self.names.get(&who).map(String::as_str)
    }

    /// 房间成员与他们的名字,按公钥排序。
    ///
    /// 名字可能为空或重复 —— 它是对方自己填的。**公钥才是身份**,所以两个都给。
    pub fn members_with_names(&self) -> Vec<(EndpointId, String)> {
        self.roster
            .members()
            .map(|id| (*id, self.names.get(id).cloned().unwrap_or_default()))
            .collect()
    }

    pub fn roster(&self) -> &RoomRoster {
        &self.roster
    }

    pub fn scope(&self) -> &ScopeId {
        &self.scope
    }

    /// 处理一条已经校验过的控制面消息。
    ///
    /// 返回 `true` 表示名册发生了变化 —— 主持人据此决定要不要重新广播。
    pub fn apply(&mut self, author: EndpointId, control: RoomControl) -> bool {
        match control {
            RoomControl::Hello { display_name } => {
                // 名字每次都更新:有人改了昵称再打招呼,房间里应当跟着变。
                // 没自报名字不算「名字变了」—— 否则每一次重复的 Hello 都会
                // 被当成变化,把房间刷个不停。
                let cleaned = crate::nearby::sanitize_display_name(&display_name);
                let name_changed = !cleaned.is_empty()
                    && self.names.get(&author).map(String::as_str) != Some(cleaned.as_str());
                if name_changed {
                    self.names.insert(author, cleaned);
                }
                if !self.seen.insert(author) {
                    // 人没变但名字变了,界面也要跟着刷新。
                    return name_changed;
                }
                if self.is_host {
                    // 只有主持人能把「打过招呼」变成「在名册里」。
                    self.roster.admit(author);
                    return true;
                }
                false
            }
            RoomControl::Goodbye => {
                self.seen.remove(&author);
                self.names.remove(&author);
                if self.is_host {
                    return self.roster.remove(author);
                }
                false
            }
            RoomControl::Roster { members, host_only } => {
                if self.is_host {
                    // 主持人不跟随别人的名册 —— 那是它自己的权威。
                    return false;
                }
                let mut next = RoomRoster::new(
                    self.scope.clone(),
                    self.host,
                    if host_only {
                        WritePolicy::HostOnly
                    } else {
                        WritePolicy::Everyone
                    },
                );
                for raw in members {
                    if let Ok(id) = EndpointId::from_bytes(&raw) {
                        next.admit(id);
                    }
                }
                self.roster = next;
                // 名字表不动:名册是主持人给的成员清单,名字是各人自己报的,
                // 重建名册不该把已经认识的人变回一串公钥。
                true
            }
        }
    }

    /// 主持人当前应当广播的名册。非主持人调用返回 `None`。
    pub fn roster_broadcast(&self) -> Option<RoomControl> {
        if !self.is_host {
            return None;
        }
        Some(RoomControl::Roster {
            members: self
                .roster
                .members()
                .take(MAX_ROSTER_MEMBERS)
                .map(|id| *id.as_bytes())
                .collect(),
            host_only: matches!(self.roster.policy(), WritePolicy::HostOnly),
        })
    }

    /// gossip 报告一个直接邻居掉线。视同 `Goodbye` 的兜底。
    pub fn neighbor_down(&mut self, who: EndpointId) -> bool {
        self.apply(who, RoomControl::Goodbye)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scope() -> ScopeId {
        ScopeId::Notebook {
            notebook_id: "nb".into(),
        }
    }

    #[test]
    fn hello_round_trips_and_verifies() {
        let host = SecretKey::generate();
        let bytes = seal(&RoomControl::hello(""), &scope(), &host).unwrap();
        let (author, control) = open(&bytes, &scope(), host.public()).unwrap();
        assert_eq!(author, host.public());
        assert_eq!(control, RoomControl::hello(""));
    }

    /// 控制面消息必须真的装得进一条 gossip 消息 —— 满员名册是最坏情况。
    #[test]
    fn roster_at_capacity_fits_in_one_gossip_message() {
        let host = SecretKey::generate();
        let members: Vec<[u8; 32]> = (0..MAX_ROSTER_MEMBERS)
            .map(|_| *SecretKey::generate().public().as_bytes())
            .collect();
        // 用一个长 id 的 scope,把固定开销也算进最坏情况。
        let wide = ScopeId::Session {
            session_id: "s".repeat(128),
        };
        let bytes = seal(
            &RoomControl::Roster {
                members,
                host_only: true,
            },
            &wide,
            &host,
        )
        .unwrap();
        assert!(
            bytes.len() <= iroh_gossip::proto::DEFAULT_MAX_MESSAGE_SIZE,
            "满员名册 {} 字节,超过 gossip 上限",
            bytes.len()
        );
    }

    /// 紧凑编码存在的理由:JSON 会把同一条消息撑到装不下。
    #[test]
    fn compact_encoding_is_far_smaller_than_json() {
        let host = SecretKey::generate();
        let members: Vec<[u8; 32]> = (0..MAX_ROSTER_MEMBERS)
            .map(|_| *SecretKey::generate().public().as_bytes())
            .collect();
        let control = RoomControl::Roster {
            members,
            host_only: false,
        };
        let compact = seal(&control, &scope(), &host).unwrap();

        let payload = postcard::to_stdvec(&control).unwrap();
        let json = serde_json::to_vec(
            &UnsignedEnvelope::new(scope(), PayloadKind::RoomControl, payload).sign(&host),
        )
        .unwrap();
        assert!(
            json.len() > iroh_gossip::proto::DEFAULT_MAX_MESSAGE_SIZE,
            "JSON 版本应当撑破 gossip 上限,实际 {} 字节",
            json.len()
        );
        assert!(compact.len() < json.len() / 2);
    }

    #[test]
    fn oversized_roster_is_refused_before_sending() {
        let host = SecretKey::generate();
        let members = vec![[0u8; 32]; MAX_ROSTER_MEMBERS + 1];
        assert!(matches!(
            seal(
                &RoomControl::Roster {
                    members,
                    host_only: false
                },
                &scope(),
                &host
            ),
            Err(ControlError::RosterTooLarge { .. })
        ));
    }

    /// 名册只有主持人说了算。一个成员伪造名册想把自己塞进去,必须被拒。
    #[test]
    fn roster_from_a_non_host_is_refused() {
        let host = SecretKey::generate();
        let guest = SecretKey::generate();
        let bytes = seal(
            &RoomControl::Roster {
                members: vec![*guest.public().as_bytes()],
                host_only: false,
            },
            &scope(),
            &guest,
        )
        .unwrap();
        assert_eq!(
            open(&bytes, &scope(), host.public()),
            Err(ControlError::RosterFromNonHost)
        );
    }

    #[test]
    fn tampered_control_message_is_refused() {
        let host = SecretKey::generate();
        let mut bytes = seal(&RoomControl::hello(""), &scope(), &host).unwrap();
        let last = bytes.len() - 1;
        bytes[last] ^= 0xFF;
        assert!(open(&bytes, &scope(), host.public()).is_err());
    }

    #[test]
    fn control_message_from_another_scope_is_refused() {
        let host = SecretKey::generate();
        let bytes = seal(&RoomControl::hello(""), &scope(), &host).unwrap();
        let other = ScopeId::Notebook {
            notebook_id: "somebody-else".into(),
        };
        assert_eq!(
            open(&bytes, &other, host.public()),
            Err(ControlError::Envelope(EnvelopeError::ScopeMismatch))
        );
    }

    /// 主持人收到 Hello 就把人纳入名册,并且这会体现在下一次广播里。
    #[test]
    fn host_admits_on_hello_and_publishes_it() {
        let host = SecretKey::generate();
        let guest = SecretKey::generate();
        let mut presence = RoomPresence::new(
            scope(),
            host.public(),
            host.public(),
            "",
            WritePolicy::Everyone,
        );

        assert!(presence.apply(guest.public(), RoomControl::hello("")));
        assert!(presence.roster().is_member(guest.public()));

        let Some(RoomControl::Roster { members, .. }) = presence.roster_broadcast() else {
            panic!("主持人应当有名册可广播");
        };
        assert!(members.contains(guest.public().as_bytes()));
    }

    /// 重复的 Hello 不该反复触发名册广播。
    #[test]
    fn repeated_hello_does_not_churn_the_roster() {
        let host = SecretKey::generate();
        let guest = SecretKey::generate();
        let mut presence = RoomPresence::new(
            scope(),
            host.public(),
            host.public(),
            "",
            WritePolicy::Everyone,
        );
        assert!(presence.apply(guest.public(), RoomControl::hello("")));
        assert!(!presence.apply(guest.public(), RoomControl::hello("")));
    }

    /// 观看者跟随主持人的名册,而不是自己拼。
    #[test]
    fn viewer_follows_the_host_roster() {
        let host = SecretKey::generate();
        let me = SecretKey::generate();
        let other = SecretKey::generate();
        let mut presence = RoomPresence::new(
            scope(),
            host.public(),
            me.public(),
            "",
            WritePolicy::Everyone,
        );

        // 观看者收到别人的 Hello 时不该自作主张纳入。
        assert!(!presence.apply(other.public(), RoomControl::hello("")));
        assert!(!presence.roster().is_member(other.public()));

        // 主持人的名册到达后才生效,并且能改写策略。
        assert!(presence.apply(
            host.public(),
            RoomControl::Roster {
                members: vec![*me.public().as_bytes(), *other.public().as_bytes()],
                host_only: true,
            }
        ));
        assert!(presence.roster().is_member(other.public()));
        assert_eq!(presence.roster().policy(), WritePolicy::HostOnly);
        assert!(!presence.roster().may_write(me.public()));
    }

    /// 观看者不广播名册 —— 它没有这个权威。
    #[test]
    fn viewer_never_broadcasts_a_roster() {
        let host = SecretKey::generate();
        let me = SecretKey::generate();
        let presence = RoomPresence::new(
            scope(),
            host.public(),
            me.public(),
            "",
            WritePolicy::Everyone,
        );
        assert!(presence.roster_broadcast().is_none());
    }

    /// 名字跟着 Hello 走,房间里的人据此认出彼此。
    #[test]
    fn a_hello_carries_the_name_into_the_room() {
        let host = SecretKey::generate();
        let guest = SecretKey::generate();
        let mut presence = RoomPresence::new(
            scope(),
            host.public(),
            host.public(),
            "",
            WritePolicy::Everyone,
        );

        presence.apply(guest.public(), RoomControl::hello("朋友的 Mac"));
        assert_eq!(presence.name_of(guest.public()), Some("朋友的 Mac"));

        let listed = presence.members_with_names();
        assert!(listed
            .iter()
            .any(|(id, name)| *id == guest.public() && name == "朋友的 Mac"));
    }

    /// 改了昵称再打招呼,房间里要跟着变。
    #[test]
    fn renaming_updates_the_room() {
        let host = SecretKey::generate();
        let guest = SecretKey::generate();
        let mut presence = RoomPresence::new(
            scope(),
            host.public(),
            host.public(),
            "",
            WritePolicy::Everyone,
        );
        presence.apply(guest.public(), RoomControl::hello("旧名字"));
        assert!(presence.apply(guest.public(), RoomControl::hello("新名字")));
        assert_eq!(presence.name_of(guest.public()), Some("新名字"));
    }

    /// 名字是对方自己填的,不可信 —— 控制字符不能进到别人屏幕上。
    #[test]
    fn a_hostile_name_is_cleaned_before_it_reaches_a_screen() {
        let host = SecretKey::generate();
        let guest = SecretKey::generate();
        let mut presence = RoomPresence::new(
            scope(),
            host.public(),
            host.public(),
            "",
            WritePolicy::Everyone,
        );
        presence.apply(guest.public(), RoomControl::hello("坏人\n主持人\t批准了"));
        assert_eq!(presence.name_of(guest.public()), Some("坏人主持人批准了"));
    }

    /// 超长的名字会被广播给房间里每个人,不该由一个人决定别人屏幕上显示多少字。
    #[test]
    fn an_overlong_name_is_refused_on_the_wire() {
        let host = SecretKey::generate();
        let bytes = seal(
            &RoomControl::Hello {
                display_name: "x".repeat(500),
            },
            &scope(),
            &host,
        )
        .unwrap();
        assert_eq!(
            open(&bytes, &scope(), host.public()),
            Err(ControlError::DisplayNameTooLong)
        );
    }

    /// 离开时把名字一起带走,不留残影。
    #[test]
    fn leaving_takes_the_name_with_it() {
        let host = SecretKey::generate();
        let guest = SecretKey::generate();
        let mut presence = RoomPresence::new(
            scope(),
            host.public(),
            host.public(),
            "",
            WritePolicy::Everyone,
        );
        presence.apply(guest.public(), RoomControl::hello("朋友"));
        presence.apply(guest.public(), RoomControl::Goodbye);
        assert_eq!(presence.name_of(guest.public()), None);
    }

    /// 掉线的邻居等同于 Goodbye,主持人据此把人移出名册。
    #[test]
    fn neighbor_down_removes_the_member() {
        let host = SecretKey::generate();
        let guest = SecretKey::generate();
        let mut presence = RoomPresence::new(
            scope(),
            host.public(),
            host.public(),
            "",
            WritePolicy::Everyone,
        );
        presence.apply(guest.public(), RoomControl::hello(""));
        assert!(presence.neighbor_down(guest.public()));
        assert!(!presence.roster().is_member(guest.public()));
    }

    /// 主持人自己掉不出房间 —— 否则房间会失去唯一的写入权威。
    #[test]
    fn host_cannot_leave_its_own_room() {
        let host = SecretKey::generate();
        let mut presence = RoomPresence::new(
            scope(),
            host.public(),
            host.public(),
            "",
            WritePolicy::Everyone,
        );
        assert!(!presence.neighbor_down(host.public()));
        assert!(presence.roster().is_member(host.public()));
    }
}
