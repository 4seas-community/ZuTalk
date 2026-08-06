//! 文档同步:线上消息与合入决策。
//!
//! 这一层不认识 Loro。CRDT 的三件事 —— 「我现在是什么版本」「对方缺哪些更新」
//! 「把这份更新合进去」—— 都由 [`DocumentSync`] 端口交给持有文档的一侧实现
//! (vt-ffi)。这里只负责协议与准入。
//!
//! # 每一份进来的更新都要过门
//!
//! 合入之前跑完整条准入链:验签 → 成员资格 → 写入策略 → 编辑边界。**判不出来一律
//! 拒收** —— 判不出来时放行,等于这道门不存在。
//!
//! 见 `docs/architecture/share-p2p.md` 第 4.2 节。

use serde::{Deserialize, Serialize};

use crate::envelope::{PayloadKind, ShareEnvelope};
use crate::permission::{admit_document_update, AdmissionDenial, CaptureBoundaryGuard, RoomRoster};
use crate::room::ScopeId;

/// 文档通道上的一条消息。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum DocSyncMessage {
    /// 「我有到这个版本为止的内容」。
    ///
    /// 版本是不透明字节 —— 对 Loro 是 `VersionVector` 的编码,但这一层不需要知道。
    Have { version: Vec<u8> },
    /// 一份签过名的更新。
    Update { envelope: Vec<u8> },
    /// 没有可发的更新。显式说出来,好过让对方等一个永远不来的消息。
    UpToDate,
}

/// 持有文档的一侧要回答的三件事。
pub trait DocumentSync: Send + Sync {
    /// 本机当前版本,用于告诉对方「我有到这里」。
    fn version(&self, scope: &ScopeId) -> Vec<u8>;

    /// 对方停在 `version` 时缺的那些更新。没有则返回 `None`。
    fn updates_since(&self, scope: &ScopeId, version: &[u8]) -> Option<Vec<u8>>;

    /// 合入一份**已经通过准入**的更新。返回是否真的合进去了。
    fn apply(&self, scope: &ScopeId, update: &[u8]) -> bool;
}

/// 一条进来的更新的处置结果。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum IncomingOutcome {
    /// 通过准入并已合入。
    Applied,
    /// 被准入门拒绝。
    Denied(AdmissionDenial),
    /// 通过了准入,但文档层没能合入(通常是更新本身损坏)。
    ApplyFailed,
    /// 信封根本解不开。
    Malformed,
}

/// 处理一份收到的更新:先过门,再合入。
///
/// 顺序不可颠倒。先合入再判定就等于没有判定 —— CRDT 的合并是不可撤销的。
pub fn handle_incoming_update(
    envelope_bytes: &[u8],
    roster: &RoomRoster,
    guard: &dyn CaptureBoundaryGuard,
    sink: &dyn DocumentSync,
) -> IncomingOutcome {
    let Ok(envelope) = ShareEnvelope::decode_compact(envelope_bytes) else {
        return IncomingOutcome::Malformed;
    };
    if let Err(denial) = admit_document_update(&envelope, roster, guard) {
        return IncomingOutcome::Denied(denial);
    }
    if sink.apply(roster.scope(), &envelope.payload) {
        IncomingOutcome::Applied
    } else {
        IncomingOutcome::ApplyFailed
    }
}

/// 按对方声明的版本,准备一份要发回去的消息。
///
/// 载荷仍然要签名 —— 补齐历史和实时更新走的是同一条准入链,补历史不是免检通道。
pub fn respond_to_have(
    peer_version: &[u8],
    scope: &ScopeId,
    sink: &dyn DocumentSync,
    secret: &iroh::SecretKey,
) -> DocSyncMessage {
    match sink.updates_since(scope, peer_version) {
        Some(update) => {
            let envelope = crate::envelope::UnsignedEnvelope::new(
                scope.clone(),
                PayloadKind::DocumentUpdate,
                update,
            )
            .sign(secret);
            match envelope.encode_compact() {
                Ok(bytes) => DocSyncMessage::Update { envelope: bytes },
                Err(_) => DocSyncMessage::UpToDate,
            }
        }
        None => DocSyncMessage::UpToDate,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::envelope::UnsignedEnvelope;
    use crate::permission::{AllowAllBoundaries, WritePolicy};
    use iroh::SecretKey;
    use std::sync::Mutex;

    /// 记录被合入了什么,用来断言「拒收的东西没有偷偷进去」。
    #[derive(Default)]
    struct RecordingSink {
        applied: Mutex<Vec<Vec<u8>>>,
        version: Vec<u8>,
        pending: Option<Vec<u8>>,
        accept: bool,
    }

    impl RecordingSink {
        fn accepting() -> Self {
            Self {
                accept: true,
                ..Default::default()
            }
        }
        fn refusing() -> Self {
            Self {
                accept: false,
                ..Default::default()
            }
        }
        fn applied(&self) -> Vec<Vec<u8>> {
            self.applied.lock().unwrap().clone()
        }
    }

    impl DocumentSync for RecordingSink {
        fn version(&self, _scope: &ScopeId) -> Vec<u8> {
            self.version.clone()
        }
        fn updates_since(&self, _scope: &ScopeId, _version: &[u8]) -> Option<Vec<u8>> {
            self.pending.clone()
        }
        fn apply(&self, _scope: &ScopeId, update: &[u8]) -> bool {
            self.applied.lock().unwrap().push(update.to_vec());
            self.accept
        }
    }

    struct RejectAll;
    impl CaptureBoundaryGuard for RejectAll {
        fn touches_capture_owned_range(&self, _scope: &ScopeId, _update: &[u8]) -> bool {
            true
        }
    }

    fn scope() -> ScopeId {
        ScopeId::Session {
            session_id: "doc".into(),
        }
    }

    fn signed_update(secret: &SecretKey, payload: &[u8]) -> Vec<u8> {
        UnsignedEnvelope::new(scope(), PayloadKind::DocumentUpdate, payload.to_vec())
            .sign(secret)
            .encode_compact()
            .unwrap()
    }

    #[test]
    fn admitted_update_reaches_the_document() {
        let host = SecretKey::generate();
        let roster = RoomRoster::new(scope(), host.public(), WritePolicy::Everyone);
        let sink = RecordingSink::accepting();
        let bytes = signed_update(&host, b"loro-update");

        assert_eq!(
            handle_incoming_update(&bytes, &roster, &AllowAllBoundaries, &sink),
            IncomingOutcome::Applied
        );
        assert_eq!(sink.applied(), vec![b"loro-update".to_vec()]);
    }

    /// 被拒的更新**一个字节都不能**到达文档层。
    #[test]
    fn denied_update_never_reaches_the_document() {
        let host = SecretKey::generate();
        let stranger = SecretKey::generate();
        let roster = RoomRoster::new(scope(), host.public(), WritePolicy::Everyone);
        let sink = RecordingSink::accepting();
        let bytes = signed_update(&stranger, b"loro-update");

        assert_eq!(
            handle_incoming_update(&bytes, &roster, &AllowAllBoundaries, &sink),
            IncomingOutcome::Denied(AdmissionDenial::NotAMember)
        );
        assert!(sink.applied().is_empty(), "被拒的更新不该抵达文档层");
    }

    /// 只读房间里,成员的更新到不了文档层。
    #[test]
    fn read_only_member_update_never_reaches_the_document() {
        let host = SecretKey::generate();
        let guest = SecretKey::generate();
        let mut roster = RoomRoster::new(scope(), host.public(), WritePolicy::HostOnly);
        roster.admit(guest.public());
        let sink = RecordingSink::accepting();

        assert_eq!(
            handle_incoming_update(
                &signed_update(&guest, b"x"),
                &roster,
                &AllowAllBoundaries,
                &sink
            ),
            IncomingOutcome::Denied(AdmissionDenial::ReadOnlyForThisAuthor)
        );
        assert!(sink.applied().is_empty());
    }

    /// 编辑边界的拒绝同样发生在合入之前。
    #[test]
    fn capture_boundary_blocks_before_the_merge() {
        let host = SecretKey::generate();
        let roster = RoomRoster::new(scope(), host.public(), WritePolicy::Everyone);
        let sink = RecordingSink::accepting();

        assert_eq!(
            handle_incoming_update(&signed_update(&host, b"x"), &roster, &RejectAll, &sink),
            IncomingOutcome::Denied(AdmissionDenial::TouchesCaptureOwnedRange)
        );
        assert!(sink.applied().is_empty());
    }

    #[test]
    fn tampered_envelope_is_refused() {
        let host = SecretKey::generate();
        let roster = RoomRoster::new(scope(), host.public(), WritePolicy::Everyone);
        let sink = RecordingSink::accepting();
        let mut bytes = signed_update(&host, b"x");
        let last = bytes.len() - 1;
        bytes[last] ^= 0xFF;

        assert!(matches!(
            handle_incoming_update(&bytes, &roster, &AllowAllBoundaries, &sink),
            IncomingOutcome::Denied(_) | IncomingOutcome::Malformed
        ));
        assert!(sink.applied().is_empty());
    }

    #[test]
    fn garbage_is_reported_as_malformed() {
        let host = SecretKey::generate();
        let roster = RoomRoster::new(scope(), host.public(), WritePolicy::Everyone);
        let sink = RecordingSink::accepting();
        assert_eq!(
            handle_incoming_update(b"not-an-envelope", &roster, &AllowAllBoundaries, &sink),
            IncomingOutcome::Malformed
        );
    }

    /// 文档层自己合不进去时要如实报告,不能当成成功。
    #[test]
    fn apply_failure_is_reported() {
        let host = SecretKey::generate();
        let roster = RoomRoster::new(scope(), host.public(), WritePolicy::Everyone);
        let sink = RecordingSink::refusing();
        assert_eq!(
            handle_incoming_update(
                &signed_update(&host, b"x"),
                &roster,
                &AllowAllBoundaries,
                &sink
            ),
            IncomingOutcome::ApplyFailed
        );
    }

    /// 补齐历史也要签名 —— 它不是免检通道,对端仍会拿它过同一条准入链。
    #[test]
    fn catch_up_response_is_signed_and_admissible() {
        let host = SecretKey::generate();
        let roster = RoomRoster::new(scope(), host.public(), WritePolicy::Everyone);
        let sink = RecordingSink {
            pending: Some(b"missing-history".to_vec()),
            accept: true,
            ..Default::default()
        };

        let DocSyncMessage::Update { envelope } =
            respond_to_have(b"peer-vv", &scope(), &sink, &host)
        else {
            panic!("有待发更新时应当回 Update");
        };

        let receiver = RecordingSink::accepting();
        assert_eq!(
            handle_incoming_update(&envelope, &roster, &AllowAllBoundaries, &receiver),
            IncomingOutcome::Applied
        );
        assert_eq!(receiver.applied(), vec![b"missing-history".to_vec()]);
    }

    /// 没有可发的更新时显式说 UpToDate,不要让对方空等。
    #[test]
    fn nothing_to_send_reports_up_to_date() {
        let host = SecretKey::generate();
        let sink = RecordingSink::accepting();
        assert_eq!(
            respond_to_have(b"peer-vv", &scope(), &sink, &host),
            DocSyncMessage::UpToDate
        );
    }

    #[test]
    fn messages_round_trip() {
        for message in [
            DocSyncMessage::Have {
                version: vec![1, 2, 3],
            },
            DocSyncMessage::Update {
                envelope: vec![4, 5],
            },
            DocSyncMessage::UpToDate,
        ] {
            let bytes = serde_json::to_vec(&message).unwrap();
            assert_eq!(
                serde_json::from_slice::<DocSyncMessage>(&bytes).unwrap(),
                message
            );
        }
    }
}
