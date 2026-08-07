//! 文档同步:线上消息与合入决策。
//!
//! 这一层不认识 Loro。CRDT 的三件事 —— 「我现在是什么版本」「对方缺哪些更新」
//! 「把这份更新合进去」—— 都由 [`DocumentSync`] 端口交给持有文档的一侧实现
//! (vt-ffi)。这里只负责协议与准入。
//!
//! # 每一份进来的更新都要过门
//!
//! 合入之前跑完整条准入链:归属 → 结构纪元 → 验签 → 成员资格 → 写入策略 →
//! 编辑边界。**判不出来一律拒收** —— 判不出来时放行,等于这道门不存在。
//!
//! 见 `docs/architecture/share-p2p.md` 第 4.2 节。

use serde::{Deserialize, Serialize};

use crate::envelope::{PayloadKind, ShareEnvelope};
use crate::permission::{admit_document_update, AdmissionDenial, CaptureBoundaryGuard, RoomRoster};
use crate::room::ScopeId;

/// 一份文档更新的载荷:它属于哪一篇,以及内容。
///
/// 文档 id 必须随更新一起走,否则按 Notebook 共享时无从知道这笔改动落在哪一篇上。
/// 但它是**对端声称的**,所以收到后一定要用 [`DocumentSync::document_in_scope`]
/// 验一遍 —— 不验就等于允许一个按录音共享的房间去写别的文档。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DocumentUpdatePayload {
    pub document_id: String,
    /// 这份更新所属文档的结构纪元。**它也是对端声称的**,接收侧必须与本机
    /// 同一篇文档的纪元比对,不匹配大声拒绝 —— 两个纪元的 oplog 属于两个
    /// 结构不同的文档,CRDT 会把混流老实合并成一篇两边都损坏的东西。
    /// 见 docs/architecture/document-schema-decision.md「迁移」一节。
    pub schema_epoch: u64,
    pub update: Vec<u8>,
}

/// 一篇文档的版本声明。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DocumentVersion {
    pub document_id: String,
    pub version: Vec<u8>,
}

/// 文档通道上的一条消息。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum DocSyncMessage {
    /// 「这些文档我各自有到这个版本」。
    ///
    /// 版本是不透明字节 —— 对 Loro 是 `VersionVector` 的编码,但这一层不需要知道。
    /// 按 Notebook 共享时会有多篇,按单次录音共享时只有一篇。
    Have { versions: Vec<DocumentVersion> },
    /// 若干份签过名的更新,每篇文档一份。
    Updates { envelopes: Vec<Vec<u8>> },
    /// 没有可发的更新。显式说出来,好过让对方等一个永远不来的消息。
    UpToDate,
}

/// 持有文档的一侧要回答的几件事。
pub trait DocumentSync: Send + Sync {
    /// 这个共享范围里当前有哪些文档。
    ///
    /// 按单次录音共享时只有一篇;按 Notebook 共享时是该 Notebook 下的全部录音。
    fn documents(&self, scope: &ScopeId) -> Vec<String>;

    /// 这篇文档是否属于这个共享范围。
    ///
    /// **判不出来必须返回 `false`。** 这是防止一个房间被用来写它管不着的文档的
    /// 唯一一道检查 —— 放行等于把所有共享范围合并成一个。
    fn document_in_scope(&self, scope: &ScopeId, document_id: &str) -> bool;

    /// 某一篇文档的当前版本,用于告诉对方「我有到这里」。
    fn version(&self, scope: &ScopeId, document_id: &str) -> Vec<u8>;

    /// 这篇文档当前的结构纪元。
    ///
    /// **判不出来必须返回 `None`**,上层按拒收处理 —— 纪元未知时放行,
    /// 等于允许另一纪元的操作混进这篇文档的历史。
    fn schema_epoch(&self, scope: &ScopeId, document_id: &str) -> Option<u64>;

    /// 对方停在 `version` 时,这篇文档缺的那些更新。没有则返回 `None`。
    fn updates_since(&self, scope: &ScopeId, document_id: &str, version: &[u8]) -> Option<Vec<u8>>;

    /// 合入一份**已经通过准入**的更新。返回是否真的合进去了。
    fn apply(&self, scope: &ScopeId, document_id: &str, update: &[u8]) -> bool;
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
    let Ok(payload) = postcard::from_bytes::<DocumentUpdatePayload>(&envelope.payload) else {
        return IncomingOutcome::Malformed;
    };

    // 归属先于一切实质判断:文档 id 是对端声称的,而这道检查不依赖作者是谁,又便宜。
    // 一个按录音共享的房间不该能写进另一篇文档。
    if !sink.document_in_scope(roster.scope(), &payload.document_id) {
        return IncomingOutcome::Denied(AdmissionDenial::DocumentNotInScope);
    }

    // 纪元紧随归属:另一纪元的更新无论作者是谁、权限如何都不能合入。
    // 混流不是权限问题,是结构损坏 —— 所以它排在作者与写入策略之前。
    match sink.schema_epoch(roster.scope(), &payload.document_id) {
        None => return IncomingOutcome::Denied(AdmissionDenial::SchemaEpochUnknown),
        Some(local) if local != payload.schema_epoch => {
            return IncomingOutcome::Denied(AdmissionDenial::SchemaEpochMismatch {
                local,
                remote: payload.schema_epoch,
            });
        }
        Some(_) => {}
    }

    if let Err(denial) = admit_document_update(
        &envelope,
        &payload.document_id,
        &payload.update,
        roster,
        guard,
    ) {
        return IncomingOutcome::Denied(denial);
    }
    if sink.apply(roster.scope(), &payload.document_id, &payload.update) {
        IncomingOutcome::Applied
    } else {
        IncomingOutcome::ApplyFailed
    }
}

/// 把一份本机更新打包成可以发出去的信封。
pub fn seal_update(
    scope: &ScopeId,
    document_id: &str,
    schema_epoch: u64,
    update: Vec<u8>,
    secret: &iroh::SecretKey,
) -> Option<Vec<u8>> {
    let payload = postcard::to_stdvec(&DocumentUpdatePayload {
        document_id: document_id.to_string(),
        schema_epoch,
        update,
    })
    .ok()?;
    crate::envelope::UnsignedEnvelope::new(scope.clone(), PayloadKind::DocumentUpdate, payload)
        .sign(secret)
        .encode_compact()
        .ok()
}

/// 本机所有文档的版本声明,用于向对方索要缺失的部分。
pub fn declare_versions(scope: &ScopeId, sink: &dyn DocumentSync) -> DocSyncMessage {
    DocSyncMessage::Have {
        versions: sink
            .documents(scope)
            .into_iter()
            .map(|document_id| DocumentVersion {
                version: sink.version(scope, &document_id),
                document_id,
            })
            .collect(),
    }
}

/// 按对方声明的版本,准备一份要发回去的消息。
///
/// 载荷仍然要签名 —— 补齐历史和实时更新走的是同一条准入链,补历史不是免检通道。
pub fn respond_to_have(
    peer_versions: &[DocumentVersion],
    scope: &ScopeId,
    sink: &dyn DocumentSync,
    secret: &iroh::SecretKey,
) -> DocSyncMessage {
    let mut envelopes = Vec::new();

    // 本机有、对方没提到的文档也要发 —— 那是对方还完全没见过的内容。
    for document_id in sink.documents(scope) {
        let peer_version = peer_versions
            .iter()
            .find(|v| v.document_id == document_id)
            .map(|v| v.version.as_slice())
            .unwrap_or(&[]);
        let Some(update) = sink.updates_since(scope, &document_id, peer_version) else {
            continue;
        };
        // 纪元判不出来就不发。发一个猜出来的纪元,等于替对端跳过混流检查。
        let Some(schema_epoch) = sink.schema_epoch(scope, &document_id) else {
            continue;
        };
        if let Some(bytes) = seal_update(scope, &document_id, schema_epoch, update, secret) {
            envelopes.push(bytes);
        }
    }

    if envelopes.is_empty() {
        DocSyncMessage::UpToDate
    } else {
        DocSyncMessage::Updates { envelopes }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::permission::{AllowAllBoundaries, WritePolicy};
    use iroh::SecretKey;
    use std::collections::BTreeSet;
    use std::sync::Mutex;

    const DOC: &str = "doc-1";
    const EPOCH: u64 = 1;

    /// 记录被合入了什么,用来断言「拒收的东西没有偷偷进去」。
    struct RecordingSink {
        applied: Mutex<Vec<(String, Vec<u8>)>>,
        /// 这个范围里有哪些文档。
        docs: BTreeSet<String>,
        /// 待补给对方的历史,按文档。
        pending: Option<Vec<u8>>,
        /// 本机文档的结构纪元;`None` 模拟判不出来。
        epoch: Option<u64>,
        accept: bool,
    }

    impl Default for RecordingSink {
        fn default() -> Self {
            Self {
                applied: Mutex::new(Vec::new()),
                docs: [DOC.to_string()].into_iter().collect(),
                pending: None,
                epoch: Some(EPOCH),
                accept: true,
            }
        }
    }

    impl RecordingSink {
        fn accepting() -> Self {
            Self::default()
        }
        fn refusing() -> Self {
            Self {
                accept: false,
                ..Default::default()
            }
        }
        fn applied(&self) -> Vec<(String, Vec<u8>)> {
            self.applied.lock().unwrap().clone()
        }
    }

    impl DocumentSync for RecordingSink {
        fn documents(&self, _scope: &ScopeId) -> Vec<String> {
            self.docs.iter().cloned().collect()
        }
        fn document_in_scope(&self, _scope: &ScopeId, document_id: &str) -> bool {
            self.docs.contains(document_id)
        }
        fn version(&self, _scope: &ScopeId, _document_id: &str) -> Vec<u8> {
            Vec::new()
        }
        fn schema_epoch(&self, _scope: &ScopeId, _document_id: &str) -> Option<u64> {
            self.epoch
        }
        fn updates_since(
            &self,
            _scope: &ScopeId,
            _document_id: &str,
            _version: &[u8],
        ) -> Option<Vec<u8>> {
            self.pending.clone()
        }
        fn apply(&self, _scope: &ScopeId, document_id: &str, update: &[u8]) -> bool {
            self.applied
                .lock()
                .unwrap()
                .push((document_id.to_string(), update.to_vec()));
            self.accept
        }
    }

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

    fn scope() -> ScopeId {
        ScopeId::Session {
            session_id: DOC.into(),
        }
    }

    fn signed(secret: &SecretKey, document_id: &str, payload: &[u8]) -> Vec<u8> {
        seal_update(&scope(), document_id, EPOCH, payload.to_vec(), secret).unwrap()
    }

    fn signed_with_epoch(
        secret: &SecretKey,
        document_id: &str,
        schema_epoch: u64,
        payload: &[u8],
    ) -> Vec<u8> {
        seal_update(
            &scope(),
            document_id,
            schema_epoch,
            payload.to_vec(),
            secret,
        )
        .unwrap()
    }

    #[test]
    fn admitted_update_reaches_the_right_document() {
        let host = SecretKey::generate();
        let roster = RoomRoster::new(scope(), host.public(), WritePolicy::Everyone);
        let sink = RecordingSink::accepting();

        assert_eq!(
            handle_incoming_update(
                &signed(&host, DOC, b"loro-update"),
                &roster,
                &AllowAllBoundaries,
                &sink
            ),
            IncomingOutcome::Applied
        );
        assert_eq!(sink.applied(), vec![(DOC.into(), b"loro-update".to_vec())]);
    }

    /// **这是这一版新增的关键安全断言。**
    ///
    /// 文档 id 由对端声称,所以一个房间必须拒绝它管不着的文档 —— 否则拿到任意一份
    /// 分享码的人,就能往你别的 Notebook / 别的录音里写东西。
    #[test]
    fn an_update_for_a_document_outside_the_room_is_refused() {
        let host = SecretKey::generate();
        let roster = RoomRoster::new(scope(), host.public(), WritePolicy::Everyone);
        let sink = RecordingSink::accepting();

        assert_eq!(
            handle_incoming_update(
                &signed(&host, "somebody-elses-doc", b"x"),
                &roster,
                &AllowAllBoundaries,
                &sink
            ),
            IncomingOutcome::Denied(AdmissionDenial::DocumentNotInScope)
        );
        assert!(sink.applied().is_empty(), "范围外的文档一个字节都不该合入");
    }

    /// 另一纪元的更新无论作者是谁都不能合入 —— 两个纪元的 oplog 属于两个
    /// 结构不同的文档,CRDT 会把混流合并成一篇两边都损坏的东西。
    #[test]
    fn an_update_from_another_schema_epoch_is_refused_loudly() {
        let host = SecretKey::generate();
        let roster = RoomRoster::new(scope(), host.public(), WritePolicy::Everyone);
        let sink = RecordingSink::accepting();

        assert_eq!(
            handle_incoming_update(
                &signed_with_epoch(&host, DOC, EPOCH + 1, b"epoch-2-bytes"),
                &roster,
                &AllowAllBoundaries,
                &sink
            ),
            IncomingOutcome::Denied(AdmissionDenial::SchemaEpochMismatch {
                local: EPOCH,
                remote: EPOCH + 1,
            })
        );
        assert!(sink.applied().is_empty(), "混流一个字节都不能合入");
    }

    /// 纪元判不出来一律拒收 —— 与准入链其它环节同一条家法。
    #[test]
    fn an_unknown_local_epoch_refuses_the_update() {
        let host = SecretKey::generate();
        let roster = RoomRoster::new(scope(), host.public(), WritePolicy::Everyone);
        let sink = RecordingSink {
            epoch: None,
            ..Default::default()
        };

        assert_eq!(
            handle_incoming_update(
                &signed(&host, DOC, b"x"),
                &roster,
                &AllowAllBoundaries,
                &sink
            ),
            IncomingOutcome::Denied(AdmissionDenial::SchemaEpochUnknown)
        );
        assert!(sink.applied().is_empty());
    }

    /// 纪元判不出来也不发 —— 发一个猜的纪元等于替对端跳过混流检查。
    #[test]
    fn an_unknown_local_epoch_sends_nothing() {
        let host = SecretKey::generate();
        let sink = RecordingSink {
            pending: Some(b"history".to_vec()),
            epoch: None,
            ..Default::default()
        };
        assert_eq!(
            respond_to_have(&[], &scope(), &sink, &host),
            DocSyncMessage::UpToDate
        );
    }

    /// 被拒的更新**一个字节都不能**到达文档层。
    #[test]
    fn denied_update_never_reaches_the_document() {
        let host = SecretKey::generate();
        let stranger = SecretKey::generate();
        let roster = RoomRoster::new(scope(), host.public(), WritePolicy::Everyone);
        let sink = RecordingSink::accepting();

        assert_eq!(
            handle_incoming_update(
                &signed(&stranger, DOC, b"x"),
                &roster,
                &AllowAllBoundaries,
                &sink
            ),
            IncomingOutcome::Denied(AdmissionDenial::NotAMember)
        );
        assert!(sink.applied().is_empty());
    }

    #[test]
    fn read_only_member_update_never_reaches_the_document() {
        let host = SecretKey::generate();
        let guest = SecretKey::generate();
        let mut roster = RoomRoster::new(scope(), host.public(), WritePolicy::HostOnly);
        roster.admit(guest.public());
        let sink = RecordingSink::accepting();

        assert_eq!(
            handle_incoming_update(
                &signed(&guest, DOC, b"x"),
                &roster,
                &AllowAllBoundaries,
                &sink
            ),
            IncomingOutcome::Denied(AdmissionDenial::ReadOnlyForThisAuthor)
        );
        assert!(sink.applied().is_empty());
    }

    #[test]
    fn capture_boundary_blocks_before_the_merge() {
        // 边界对成员生效(宿主按「宿主即机器」豁免,见 permission 的测试)。
        let host = SecretKey::generate();
        let member = SecretKey::generate();
        let mut roster = RoomRoster::new(scope(), host.public(), WritePolicy::Everyone);
        roster.admit(member.public());
        let sink = RecordingSink::accepting();

        assert_eq!(
            handle_incoming_update(&signed(&member, DOC, b"x"), &roster, &RejectAll, &sink),
            IncomingOutcome::Denied(AdmissionDenial::TouchesCaptureOwnedRange)
        );
        assert!(sink.applied().is_empty());
    }

    #[test]
    fn tampered_envelope_is_refused() {
        let host = SecretKey::generate();
        let roster = RoomRoster::new(scope(), host.public(), WritePolicy::Everyone);
        let sink = RecordingSink::accepting();
        let mut bytes = signed(&host, DOC, b"x");
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

    #[test]
    fn apply_failure_is_reported() {
        let host = SecretKey::generate();
        let roster = RoomRoster::new(scope(), host.public(), WritePolicy::Everyone);
        let sink = RecordingSink::refusing();
        assert_eq!(
            handle_incoming_update(
                &signed(&host, DOC, b"x"),
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
            ..Default::default()
        };

        let DocSyncMessage::Updates { envelopes } = respond_to_have(&[], &scope(), &sink, &host)
        else {
            panic!("有待发更新时应当回 Updates");
        };
        assert_eq!(envelopes.len(), 1);

        let receiver = RecordingSink::accepting();
        assert_eq!(
            handle_incoming_update(&envelopes[0], &roster, &AllowAllBoundaries, &receiver),
            IncomingOutcome::Applied
        );
        assert_eq!(
            receiver.applied(),
            vec![(DOC.into(), b"missing-history".to_vec())]
        );
    }

    /// 按 Notebook 共享时,每一篇文档各自补齐。
    #[test]
    fn every_document_in_a_notebook_room_is_caught_up() {
        let host = SecretKey::generate();
        let notebook = ScopeId::Notebook {
            notebook_id: "nb".into(),
        };
        let sink = RecordingSink {
            docs: ["a".into(), "b".into(), "c".into()].into_iter().collect(),
            pending: Some(b"history".to_vec()),
            ..Default::default()
        };

        let DocSyncMessage::Updates { envelopes } = respond_to_have(&[], &notebook, &sink, &host)
        else {
            panic!("三篇文档都该有补齐内容");
        };
        assert_eq!(envelopes.len(), 3, "每一篇文档各发一份");
    }

    /// 对方完全没提到的文档也要发 —— 那是它还没见过的内容。
    #[test]
    fn a_document_the_peer_never_mentioned_is_still_sent() {
        let host = SecretKey::generate();
        let sink = RecordingSink {
            docs: ["known".into(), "brand-new".into()].into_iter().collect(),
            pending: Some(b"history".to_vec()),
            ..Default::default()
        };
        let DocSyncMessage::Updates { envelopes } = respond_to_have(
            &[DocumentVersion {
                document_id: "known".into(),
                version: vec![1],
            }],
            &scope(),
            &sink,
            &host,
        ) else {
            panic!("应当有可发内容");
        };
        assert_eq!(envelopes.len(), 2);
    }

    #[test]
    fn nothing_to_send_reports_up_to_date() {
        let host = SecretKey::generate();
        let sink = RecordingSink::accepting();
        assert_eq!(
            respond_to_have(&[], &scope(), &sink, &host),
            DocSyncMessage::UpToDate
        );
    }

    #[test]
    fn declared_versions_cover_every_document() {
        let sink = RecordingSink {
            docs: ["a".into(), "b".into()].into_iter().collect(),
            ..Default::default()
        };
        let DocSyncMessage::Have { versions } = declare_versions(&scope(), &sink) else {
            panic!("应当声明版本");
        };
        assert_eq!(versions.len(), 2);
    }

    #[test]
    fn messages_round_trip() {
        for message in [
            DocSyncMessage::Have {
                versions: vec![DocumentVersion {
                    document_id: "d".into(),
                    version: vec![1, 2, 3],
                }],
            },
            DocSyncMessage::Updates {
                envelopes: vec![vec![4, 5]],
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
