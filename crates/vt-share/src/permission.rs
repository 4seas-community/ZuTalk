//! 房间名册与接收端准入门。
//!
//! # 这层保证的实际形状
//!
//! P2P 里没有服务器,**「只读」不可能由发送端强制**。它只能是每个接收端在合入之前
//! 自己过滤。所以真实保证是:
//!
//! > 所有运行未经篡改客户端的成员,都会拒绝非主持人的改动。
//!
//! 改过客户端的人可以在自己那份文档上随便改,也可以往外发,但诚实节点会丢弃。这
//! 对会议场景够用 —— 它防的是误操作和越权,不防恶意成员篡改自己那一份。**UI 上
//! 不得暗示更强的保证。**
//!
//! 见 `docs/architecture/share-p2p.md` 第 4.2 节。

use std::collections::BTreeSet;

use iroh::EndpointId;

use crate::envelope::{EnvelopeError, PayloadKind, ShareEnvelope};
use crate::room::ScopeId;

/// 房间的写入策略。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WritePolicy {
    /// 全员平权可编辑。
    Everyone,
    /// 主持人可写,其他人只读。
    HostOnly,
}

/// 房间名册:谁在房间里、谁是主持人、当前写入策略。
#[derive(Debug, Clone)]
pub struct RoomRoster {
    scope: ScopeId,
    host: EndpointId,
    members: BTreeSet<EndpointId>,
    policy: WritePolicy,
}

impl RoomRoster {
    /// 主持人恒为成员 —— 一个把自己踢出房间的名册没有意义。
    pub fn new(scope: ScopeId, host: EndpointId, policy: WritePolicy) -> Self {
        let mut members = BTreeSet::new();
        members.insert(host);
        Self {
            scope,
            host,
            members,
            policy,
        }
    }

    pub fn scope(&self) -> &ScopeId {
        &self.scope
    }

    pub fn host(&self) -> EndpointId {
        self.host
    }

    pub fn policy(&self) -> WritePolicy {
        self.policy
    }

    pub fn set_policy(&mut self, policy: WritePolicy) {
        self.policy = policy;
    }

    pub fn admit(&mut self, member: EndpointId) {
        self.members.insert(member);
    }

    /// 主持人不可被移除,否则房间会失去唯一的写入权威。
    pub fn remove(&mut self, member: EndpointId) -> bool {
        if member == self.host {
            return false;
        }
        self.members.remove(&member)
    }

    pub fn is_member(&self, who: EndpointId) -> bool {
        self.members.contains(&who)
    }

    pub fn members(&self) -> impl Iterator<Item = &EndpointId> {
        self.members.iter()
    }

    /// 这位成员是否被允许写入文档。
    pub fn may_write(&self, who: EndpointId) -> bool {
        if !self.is_member(who) {
            return false;
        }
        match self.policy {
            WritePolicy::Everyone => true,
            WritePolicy::HostOnly => who == self.host,
        }
    }
}

/// 准入被拒的原因。逐条分开是为了让 UI 能给出不同的说明,也让日志能分别计数。
#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
pub enum AdmissionDenial {
    #[error("信封校验失败: {0}")]
    Envelope(#[from] EnvelopeError),
    #[error("作者不在本房间名册内")]
    NotAMember,
    #[error("只读房间里只有主持人可以写入")]
    ReadOnlyForThisAuthor,
    #[error("载荷类型不属于这条通道")]
    WrongPayloadKind,
    #[error("改动落在采集投影拥有的区间上")]
    TouchesCaptureOwnedRange,
    #[error("这篇文档不属于本共享范围")]
    DocumentNotInScope,
    #[error("文档结构纪元不匹配:本机 {local},对端 {remote}")]
    SchemaEpochMismatch { local: u64, remote: u64 },
    #[error("本机判不出这篇文档的结构纪元")]
    SchemaEpochUnknown,
}

/// 文档更新的编辑边界裁决。
///
/// CRDT 不认 `editor_bridge.rs` 的 `set_capture_owned_range` —— 转录投影拥有的
/// 区间不该被人改,但 CRDT 会老实合并远端对那段的修改。这一层必须在合入之前做。
///
/// 判定需要真的把更新试着应用一遍才能知道它动了哪里,而那需要 Loro。vt-share 不
/// 依赖 Loro:边界判定作为一个端口留在这里,由持有文档的一侧(vt-ffi)实现。
pub trait CaptureBoundaryGuard {
    /// 这份更新是否触碰了采集投影拥有的区间。
    ///
    /// 实现方应当在一份**副本**上试应用后再回答,不要污染真实文档。
    fn touches_capture_owned_range(
        &self,
        scope: &ScopeId,
        document_id: &str,
        update: &[u8],
    ) -> bool;
}

/// 谁都拦不住的守卫:用于全员平权且没有采集投影的房间,以及测试。
#[derive(Debug, Clone, Copy, Default)]
pub struct AllowAllBoundaries;

impl CaptureBoundaryGuard for AllowAllBoundaries {
    fn touches_capture_owned_range(
        &self,
        _scope: &ScopeId,
        _document_id: &str,
        _update: &[u8],
    ) -> bool {
        false
    }
}

/// 接收端准入门。
///
/// 四步顺序是刻意的,且**不可重排**:
///
/// 1. 验签 —— 在知道作者是谁之前,任何基于作者的判断都无意义;
/// 2. 成员资格 —— 房间外的人不该被继续处理;
/// 3. 写入策略 —— 只读房间里非主持人到此为止;
/// 4. 编辑边界 —— 最贵的一步放在最后,前面任何一步失败都不必付这个代价。
///
/// 信封是凭证(验签与作者判定用它),`update` 是解包后的内容(边界判定用它)。
///
/// 两者必须分开传:签名覆盖的是信封里那份**包装过**的载荷,拿解包后的字节去验签
/// 一定失败。
pub fn admit_document_update(
    envelope: &ShareEnvelope,
    document_id: &str,
    update: &[u8],
    roster: &RoomRoster,
    guard: &dyn CaptureBoundaryGuard,
) -> Result<(), AdmissionDenial> {
    envelope.verify(roster.scope())?;

    if envelope.kind != PayloadKind::DocumentUpdate {
        return Err(AdmissionDenial::WrongPayloadKind);
    }
    if !roster.is_member(envelope.author) {
        return Err(AdmissionDenial::NotAMember);
    }
    if !roster.may_write(envelope.author) {
        return Err(AdmissionDenial::ReadOnlyForThisAuthor);
    }
    // 宿主豁免编辑边界:采集边界守卫防的是「别人碰机器的内容」,而共享
    // session 文档里的机器就是宿主——它的机器块投影必须能到达观看端。
    // 验签与成员资格在前,豁免只对证明了身份的宿主生效;成员(非宿主)
    // 的更新仍逐条过边界。
    if envelope.author != roster.host()
        && guard.touches_capture_owned_range(roster.scope(), document_id, update)
    {
        return Err(AdmissionDenial::TouchesCaptureOwnedRange);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::envelope::UnsignedEnvelope;
    use iroh::SecretKey;

    struct RejectAll;
    impl CaptureBoundaryGuard for RejectAll {
        fn touches_capture_owned_range(
            &self,
            _scope: &ScopeId,
            _document_id: &str,
            _update: &[u8],
        ) -> bool {
            true
        }
    }

    /// 测试里统一用的文档 id。
    const DOC: &str = "doc-1";

    fn scope() -> ScopeId {
        ScopeId::Notebook {
            notebook_id: "nb".into(),
        }
    }

    fn update_from(key: &SecretKey) -> ShareEnvelope {
        UnsignedEnvelope::new(scope(), PayloadKind::DocumentUpdate, b"loro-bytes".to_vec())
            .sign(key)
    }

    fn roster(host: &SecretKey, policy: WritePolicy) -> RoomRoster {
        RoomRoster::new(scope(), host.public(), policy)
    }

    #[test]
    fn host_may_always_write() {
        let host = SecretKey::generate();
        for policy in [WritePolicy::Everyone, WritePolicy::HostOnly] {
            let r = roster(&host, policy);
            assert!(
                admit_document_update(&update_from(&host), DOC, b"", &r, &AllowAllBoundaries)
                    .is_ok()
            );
        }
    }

    #[test]
    fn member_may_write_when_everyone_can() {
        let host = SecretKey::generate();
        let guest = SecretKey::generate();
        let mut r = roster(&host, WritePolicy::Everyone);
        r.admit(guest.public());
        assert!(
            admit_document_update(&update_from(&guest), DOC, b"", &r, &AllowAllBoundaries).is_ok()
        );
    }

    /// 只读房间的核心断言:成员身份合法、签名合法,但依然写不进去。
    #[test]
    fn member_is_refused_in_host_only_rooms() {
        let host = SecretKey::generate();
        let guest = SecretKey::generate();
        let mut r = roster(&host, WritePolicy::HostOnly);
        r.admit(guest.public());
        assert_eq!(
            admit_document_update(&update_from(&guest), DOC, b"", &r, &AllowAllBoundaries),
            Err(AdmissionDenial::ReadOnlyForThisAuthor)
        );
    }

    #[test]
    fn stranger_is_refused_even_when_everyone_may_write() {
        let host = SecretKey::generate();
        let stranger = SecretKey::generate();
        let r = roster(&host, WritePolicy::Everyone);
        assert_eq!(
            admit_document_update(&update_from(&stranger), DOC, b"", &r, &AllowAllBoundaries),
            Err(AdmissionDenial::NotAMember)
        );
    }

    /// 被移出房间的人立刻写不进来 —— 这是「停止共享」在名册侧的一半。
    #[test]
    fn removed_member_loses_write_access() {
        let host = SecretKey::generate();
        let guest = SecretKey::generate();
        let mut r = roster(&host, WritePolicy::Everyone);
        r.admit(guest.public());
        assert!(r.remove(guest.public()));
        assert_eq!(
            admit_document_update(&update_from(&guest), DOC, b"", &r, &AllowAllBoundaries),
            Err(AdmissionDenial::NotAMember)
        );
    }

    #[test]
    fn host_cannot_be_removed() {
        let host = SecretKey::generate();
        let mut r = roster(&host, WritePolicy::HostOnly);
        assert!(!r.remove(host.public()));
        assert!(r.is_member(host.public()));
    }

    /// 编辑边界对主持人同样成立 —— 采集投影拥有的区间不属于任何人。
    #[test]
    fn capture_boundary_exempts_the_host_and_blocks_members() {
        // 宿主即机器:它的机器投影必须能到达观看端,边界对它豁免。
        let host = SecretKey::generate();
        let r = roster(&host, WritePolicy::HostOnly);
        assert_eq!(
            admit_document_update(&update_from(&host), DOC, b"", &r, &RejectAll),
            Ok(())
        );

        // 成员(非宿主)的更新仍逐条过边界。
        let member = SecretKey::generate();
        let mut r = roster(&host, WritePolicy::Everyone);
        r.admit(member.public());
        assert_eq!(
            admit_document_update(&update_from(&member), DOC, b"", &r, &RejectAll),
            Err(AdmissionDenial::TouchesCaptureOwnedRange)
        );
    }

    /// 验签排在最前:一个签名坏掉的信封,不该因为作者恰好是主持人就通过。
    #[test]
    fn signature_is_checked_before_anything_else() {
        let host = SecretKey::generate();
        let r = roster(&host, WritePolicy::Everyone);
        let mut env = update_from(&host);
        env.payload = b"tampered".to_vec();
        assert_eq!(
            admit_document_update(&env, DOC, b"", &r, &AllowAllBoundaries),
            Err(AdmissionDenial::Envelope(EnvelopeError::BadSignature))
        );
    }

    /// 控制面消息不能走文档通道进来。
    #[test]
    fn control_payload_cannot_enter_the_document_channel() {
        let host = SecretKey::generate();
        let r = roster(&host, WritePolicy::Everyone);
        let env =
            UnsignedEnvelope::new(scope(), PayloadKind::RoomControl, b"hello".to_vec()).sign(&host);
        assert_eq!(
            admit_document_update(&env, DOC, b"", &r, &AllowAllBoundaries),
            Err(AdmissionDenial::WrongPayloadKind)
        );
    }

    /// 策略是可切换的,切换后立刻生效。
    #[test]
    fn policy_switch_takes_effect_immediately() {
        let host = SecretKey::generate();
        let guest = SecretKey::generate();
        let mut r = roster(&host, WritePolicy::Everyone);
        r.admit(guest.public());
        assert!(r.may_write(guest.public()));
        r.set_policy(WritePolicy::HostOnly);
        assert!(!r.may_write(guest.public()));
    }
}
