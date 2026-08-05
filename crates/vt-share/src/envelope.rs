//! 签名信封。
//!
//! 每一条跨机器的载荷都包在这里,由发送方的 iroh 身份密钥签名,接收方按房间名册
//! 验签。**权限判定只能建立在这层签名上**,不能建立在 Loro 的 `PeerID` 上:
//! `loro/src/lib.rs:913-916` 明确警告不要给用户或设备分配固定 PeerID(重复 PeerID
//! 会产生冲突 OpID 并损坏文档),而且 gossip 是转发式的,传输层的发送者不等于作者。
//!
//! 见 `docs/architecture/share-p2p.md` 第 4.2 节。

use iroh::{EndpointId, SecretKey, Signature};
use serde::{Deserialize, Serialize};

use crate::room::ScopeId;

/// 签名覆盖范围的域分隔串。改动即协议破坏。
const SIGNING_DOMAIN: &[u8] = b"zulangue/envelope/v1";

/// 信封承载的载荷类型。
///
/// 封闭枚举:新增一种跨机器载荷必须在这里显式登记,不能悄悄搭现有通道的车。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PayloadKind {
    /// Loro CRDT 更新字节。
    DocumentUpdate,
    /// 房间控制面消息(在场、名册、版本通告)。
    RoomControl,
    /// 一份文本资源。
    Resource,
}

/// 待签名的信封。签名前后是两个类型,避免「忘了签就发出去」。
#[derive(Debug, Clone)]
pub struct UnsignedEnvelope {
    pub scope: ScopeId,
    pub kind: PayloadKind,
    pub payload: Vec<u8>,
}

impl UnsignedEnvelope {
    pub fn new(scope: ScopeId, kind: PayloadKind, payload: Vec<u8>) -> Self {
        Self {
            scope,
            kind,
            payload,
        }
    }

    /// 用发送方身份签名。
    pub fn sign(self, secret: &SecretKey) -> ShareEnvelope {
        let author = secret.public();
        let message = signing_message(&author, &self.scope, &self.kind, &self.payload);
        let signature = secret.sign(&message);
        ShareEnvelope {
            author,
            scope: self.scope,
            kind: self.kind,
            payload: self.payload,
            signature,
        }
    }
}

/// 已签名的信封。
///
/// `author` 参与签名,所以攻击者不能把别人的载荷重新挂到自己名下,也不能把自己的
/// 载荷冒充成主持人的。`scope` 参与签名,所以一个房间里的合法更新不能被重放到
/// 另一个房间。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ShareEnvelope {
    pub author: EndpointId,
    pub scope: ScopeId,
    pub kind: PayloadKind,
    pub payload: Vec<u8>,
    pub signature: Signature,
}

/// 验签失败的原因。区分开是为了让上层能分别计数与告警。
#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
pub enum EnvelopeError {
    #[error("签名与内容不符")]
    BadSignature,
    #[error("信封属于另一个共享范围")]
    ScopeMismatch,
}

impl ShareEnvelope {
    /// 验签,并确认它确实属于本房间。
    ///
    /// 只回答「这确实是 author 为这个 scope 写的」。**它不回答 author 有没有权限** ——
    /// 那是 [`crate::permission`] 的事,两件事刻意分开。
    pub fn verify(&self, expected_scope: &ScopeId) -> Result<(), EnvelopeError> {
        if &self.scope != expected_scope {
            return Err(EnvelopeError::ScopeMismatch);
        }
        let message = signing_message(&self.author, &self.scope, &self.kind, &self.payload);
        self.author
            .verify(&message, &self.signature)
            .map_err(|_| EnvelopeError::BadSignature)
    }
}

/// 构造被签名的字节串。
///
/// 每个字段都带长度前缀,防止拼接歧义 —— 否则 `("ab","c")` 与 `("a","bc")` 会产生
/// 同一条待签消息,让签名可以被搬到另一组字段上。
fn signing_message(
    author: &EndpointId,
    scope: &ScopeId,
    kind: &PayloadKind,
    payload: &[u8],
) -> Vec<u8> {
    let scope_bytes = serde_json::to_vec(scope).expect("ScopeId 必须可序列化");
    let kind_bytes = serde_json::to_vec(kind).expect("PayloadKind 必须可序列化");

    let mut message = Vec::with_capacity(
        SIGNING_DOMAIN.len() + 32 + scope_bytes.len() + kind_bytes.len() + payload.len() + 32,
    );
    let mut push = |field: &[u8]| {
        message.extend_from_slice(&(field.len() as u64).to_le_bytes());
        message.extend_from_slice(field);
    };
    push(SIGNING_DOMAIN);
    push(author.as_bytes());
    push(&scope_bytes);
    push(&kind_bytes);
    push(payload);
    message
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scope_a() -> ScopeId {
        ScopeId::Notebook {
            notebook_id: "nb-a".into(),
        }
    }

    fn scope_b() -> ScopeId {
        ScopeId::Notebook {
            notebook_id: "nb-b".into(),
        }
    }

    fn sealed(secret: &SecretKey, scope: ScopeId, payload: &[u8]) -> ShareEnvelope {
        UnsignedEnvelope::new(scope, PayloadKind::DocumentUpdate, payload.to_vec()).sign(secret)
    }

    #[test]
    fn honest_envelope_verifies() {
        let key = SecretKey::generate();
        let env = sealed(&key, scope_a(), b"update");
        assert!(env.verify(&scope_a()).is_ok());
        assert_eq!(env.author, key.public());
    }

    #[test]
    fn tampered_payload_is_rejected() {
        let key = SecretKey::generate();
        let mut env = sealed(&key, scope_a(), b"update");
        env.payload = b"evil".to_vec();
        assert_eq!(env.verify(&scope_a()), Err(EnvelopeError::BadSignature));
    }

    /// 冒充主持人:换掉 author 字段,签名必须失效。这是只读模式的地基 ——
    /// 如果 author 可以随便改,权限判定就没有任何意义。
    #[test]
    fn swapping_the_author_is_rejected() {
        let real = SecretKey::generate();
        let impostor = SecretKey::generate();
        let mut env = sealed(&impostor, scope_a(), b"update");
        env.author = real.public();
        assert_eq!(env.verify(&scope_a()), Err(EnvelopeError::BadSignature));
    }

    /// 跨房间重放:在 A 房间合法的更新,不能被搬到 B 房间。
    #[test]
    fn cross_scope_replay_is_rejected() {
        let key = SecretKey::generate();
        let env = sealed(&key, scope_a(), b"update");
        assert_eq!(env.verify(&scope_b()), Err(EnvelopeError::ScopeMismatch));

        // 直接改 scope 字段也不行 —— scope 参与签名。
        let mut moved = env;
        moved.scope = scope_b();
        assert_eq!(moved.verify(&scope_b()), Err(EnvelopeError::BadSignature));
    }

    /// 换掉载荷类型不能让一条控制面消息冒充文档更新。
    #[test]
    fn swapping_the_payload_kind_is_rejected() {
        let key = SecretKey::generate();
        let mut env = sealed(&key, scope_a(), b"update");
        env.kind = PayloadKind::RoomControl;
        assert_eq!(env.verify(&scope_a()), Err(EnvelopeError::BadSignature));
    }

    /// 字段带长度前缀,所以相邻字段之间不存在拼接歧义。
    #[test]
    fn field_boundaries_are_unambiguous() {
        let key = SecretKey::generate();
        let a = UnsignedEnvelope::new(
            ScopeId::Session {
                session_id: "ab".into(),
            },
            PayloadKind::Resource,
            b"c".to_vec(),
        )
        .sign(&key);
        let b = UnsignedEnvelope::new(
            ScopeId::Session {
                session_id: "a".into(),
            },
            PayloadKind::Resource,
            b"bc".to_vec(),
        )
        .sign(&key);
        assert_ne!(a.signature.to_bytes(), b.signature.to_bytes());
    }

    #[test]
    fn envelope_round_trips_through_serde() {
        let key = SecretKey::generate();
        let env = sealed(&key, scope_a(), b"update");
        let bytes = serde_json::to_vec(&env).unwrap();
        let back: ShareEnvelope = serde_json::from_slice(&bytes).unwrap();
        assert!(back.verify(&scope_a()).is_ok());
        assert_eq!(back.payload, env.payload);
    }
}
