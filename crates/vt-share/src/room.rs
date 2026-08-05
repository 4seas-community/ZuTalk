//! 房间标识与共享范围。
//!
//! 房间由 [`RoomSecret`] 定义,而不是由 Notebook / Session 的 id 定义。这带来两个
//! 性质:topic 不可从 id 猜出来;轮换 secret 就等于换一个房间 —— 这正是「停止共享」
//! 的实现手段(老成员保留已有内容,但拿不到后续,也进不来新房间)。
//!
//! 见 `docs/architecture/share-p2p.md` 第 2 节与 4.3。

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

/// topic 派生的域分隔串。改动即协议破坏。
const TOPIC_DOMAIN: &[u8] = b"zulangue/room/v1";

/// 共享范围。
///
/// 两种粒度对应产品上的两种选择:按 Notebook 记住,或只共享指定的一次录音。
/// 用默认的外部标签表示,不要内部标签(`tag = "..."`):内部标签需要
/// `deserialize_any`,而 postcard 这类非自描述格式永远不会支持它 —— 分享码就是
/// 用 postcard 编码的。
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ScopeId {
    /// 整个 Notebook。在其中开始的录音默认参与共享。
    Notebook { notebook_id: String },
    /// 单次录音,不影响同 Notebook 的其他录音。
    Session { session_id: String },
}

impl ScopeId {
    /// 参与 topic 派生的稳定字节。带类型前缀,避免同名的 notebook 与 session 撞车。
    fn derivation_bytes(&self) -> Vec<u8> {
        match self {
            Self::Notebook { notebook_id } => {
                let mut v = b"notebook:".to_vec();
                v.extend_from_slice(notebook_id.as_bytes());
                v
            }
            Self::Session { session_id } => {
                let mut v = b"session:".to_vec();
                v.extend_from_slice(session_id.as_bytes());
                v
            }
        }
    }
}

/// 房间密钥。随分享码交出,轮换即换房间。
///
/// 刻意不实现 `Display` / `Debug` 的明文输出:它进日志就等于房间泄露。
#[derive(Clone, PartialEq, Eq)]
pub struct RoomSecret([u8; 32]);

impl std::fmt::Debug for RoomSecret {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // 只暴露一个短指纹用于排障,永不打印原文。
        write!(f, "RoomSecret({}…)", &hex::encode(&self.0[..3]))
    }
}

impl RoomSecret {
    pub fn from_bytes(bytes: [u8; 32]) -> Self {
        Self(bytes)
    }

    pub fn as_bytes(&self) -> &[u8; 32] {
        &self.0
    }

    /// 用 iroh 的密钥生成器产生,避免自己引一个 RNG。
    pub fn generate() -> Self {
        Self(iroh::SecretKey::generate().to_bytes())
    }

    /// 派生这个房间的 gossip topic。
    ///
    /// `SHA-256(域 || scope || secret)`。secret 放在最后是刻意的:哈希前缀不会
    /// 泄露 secret 的任何部分,而 scope 与域是公开信息。
    pub fn topic_id(&self, scope: &ScopeId) -> iroh_gossip::proto::TopicId {
        let mut hasher = Sha256::new();
        hasher.update(TOPIC_DOMAIN);
        hasher.update(scope.derivation_bytes());
        hasher.update(self.0);
        let digest: [u8; 32] = hasher.finalize().into();
        iroh_gossip::proto::TopicId::from_bytes(digest)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn secret(seed: u8) -> RoomSecret {
        RoomSecret::from_bytes([seed; 32])
    }

    fn notebook(id: &str) -> ScopeId {
        ScopeId::Notebook {
            notebook_id: id.into(),
        }
    }

    #[test]
    fn topic_is_stable_for_same_inputs() {
        let s = secret(1);
        let scope = notebook("nb-1");
        assert_eq!(s.topic_id(&scope), s.topic_id(&scope));
    }

    /// 轮换 secret 必须换出一个不同的房间 —— 这是「停止共享」的全部依据。
    #[test]
    fn rotating_the_secret_changes_the_room() {
        let scope = notebook("nb-1");
        assert_ne!(secret(1).topic_id(&scope), secret(2).topic_id(&scope));
    }

    #[test]
    fn different_scopes_never_share_a_topic() {
        let s = secret(1);
        assert_ne!(s.topic_id(&notebook("nb-1")), s.topic_id(&notebook("nb-2")));
    }

    /// 同名的 notebook 与 session 不能撞进同一个房间。
    #[test]
    fn scope_kinds_are_domain_separated() {
        let s = secret(1);
        let nb = ScopeId::Notebook {
            notebook_id: "same-id".into(),
        };
        let se = ScopeId::Session {
            session_id: "same-id".into(),
        };
        assert_ne!(s.topic_id(&nb), s.topic_id(&se));
    }

    /// secret 不得出现在任何调试输出里 —— 它进日志就等于房间泄露。
    #[test]
    fn debug_never_leaks_the_secret() {
        let s = RoomSecret::from_bytes([0xAB; 32]);
        let rendered = format!("{s:?}");
        assert!(!rendered.contains(&hex::encode([0xAB; 32])));
        assert!(rendered.starts_with("RoomSecret(ab"));
    }

    #[test]
    fn generated_secrets_differ() {
        assert_ne!(RoomSecret::generate(), RoomSecret::generate());
    }
}
