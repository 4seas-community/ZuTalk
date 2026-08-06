//! 本机分享身份。
//!
//! 身份是一把长期 ed25519 密钥,它的公钥就是 iroh 的 `EndpointId` —— 也就是用户
//! 交给对方的「公钥」。身份稳定是前提:换一次,联系人保存的公钥就全部失效。
//!
//! **持久化不在这里。** vt-share 不依赖 vt-crypto(见 `Cargo.toml` 的说明),
//! 所以密钥的落盘由调用方(vt-ffi)用既有的密钥库完成,这里只接收和交出字节。

use iroh::{EndpointId, SecretKey};

/// 本机身份。
#[derive(Clone)]
pub struct ShareIdentity {
    secret: SecretKey,
}

impl std::fmt::Debug for ShareIdentity {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // 只打印公开部分。私钥永不出现在日志里。
        write!(f, "ShareIdentity({})", self.endpoint_id().fmt_short())
    }
}

impl ShareIdentity {
    /// 新建一把身份密钥。调用方负责立刻把 [`Self::to_secret_bytes`] 存起来。
    pub fn generate() -> Self {
        Self {
            secret: SecretKey::generate(),
        }
    }

    /// 从既有密钥库取回的字节还原。
    pub fn from_secret_bytes(bytes: &[u8; 32]) -> Self {
        Self {
            secret: SecretKey::from_bytes(bytes),
        }
    }

    /// 交给调用方持久化。这是私钥,只应写入受保护的密钥库。
    pub fn to_secret_bytes(&self) -> [u8; 32] {
        self.secret.to_bytes()
    }

    /// 分享给对方的公开身份。
    pub fn endpoint_id(&self) -> EndpointId {
        self.secret.public()
    }

    /// 给人看的短形式,用于 UI 与日志。
    pub fn short_label(&self) -> String {
        self.endpoint_id().fmt_short().to_string()
    }

    pub(crate) fn secret(&self) -> &SecretKey {
        &self.secret
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identity_round_trips_through_bytes() {
        let original = ShareIdentity::generate();
        let restored = ShareIdentity::from_secret_bytes(&original.to_secret_bytes());
        assert_eq!(original.endpoint_id(), restored.endpoint_id());
    }

    #[test]
    fn generated_identities_differ() {
        assert_ne!(
            ShareIdentity::generate().endpoint_id(),
            ShareIdentity::generate().endpoint_id()
        );
    }

    /// 私钥不得出现在任何调试输出里。
    #[test]
    fn debug_never_leaks_the_secret() {
        let id = ShareIdentity::generate();
        let rendered = format!("{id:?}");
        assert!(!rendered.contains(&hex::encode(id.to_secret_bytes())));
        assert!(rendered.starts_with("ShareIdentity("));
    }

    /// 同一把身份签出的名字,验得过自己的签名。
    #[test]
    fn identity_signs_verifiably() {
        let id = ShareIdentity::generate();
        let sig = id.secret().sign(b"message");
        assert!(id.endpoint_id().verify(b"message", &sig).is_ok());
        assert!(id.endpoint_id().verify(b"other", &sig).is_err());
    }
}
