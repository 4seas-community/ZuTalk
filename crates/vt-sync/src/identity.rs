//! 本机设备身份。
//!
//! 一把长期 ed25519 密钥,它的公钥就是 iroh 的 `EndpointId`。设备组的名单按它
//! 记人,所以它必须稳定:换一次,别的 Mac 就不认得这台了。
//!
//! **持久化不在这里。** 这个包不依赖 vt-crypto(见 `Cargo.toml`),密钥由调用方
//! 用既有的密钥库落盘,这里只接收和交出字节。

use iroh::{EndpointId, SecretKey};

#[derive(Clone)]
pub struct DeviceIdentity {
    secret: SecretKey,
}

impl std::fmt::Debug for DeviceIdentity {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // 只打印公开部分。私钥永不出现在日志里。
        write!(f, "DeviceIdentity({})", self.id().fmt_short())
    }
}

impl DeviceIdentity {
    /// 新建一把身份密钥。调用方负责立刻把 [`Self::to_secret_bytes`] 存起来。
    pub fn generate() -> Self {
        Self {
            secret: SecretKey::generate(),
        }
    }

    pub fn from_secret_bytes(bytes: &[u8; 32]) -> Self {
        Self {
            secret: SecretKey::from_bytes(bytes),
        }
    }

    /// 交给调用方持久化。这是私钥,只应写入受保护的密钥库。
    pub fn to_secret_bytes(&self) -> [u8; 32] {
        self.secret.to_bytes()
    }

    pub fn id(&self) -> EndpointId {
        self.secret.public()
    }

    pub(crate) fn secret(&self) -> &SecretKey {
        &self.secret
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identity_round_trips_through_its_secret_bytes() {
        let identity = DeviceIdentity::generate();
        let restored = DeviceIdentity::from_secret_bytes(&identity.to_secret_bytes());
        assert_eq!(identity.id(), restored.id());
    }

    #[test]
    fn debug_output_never_shows_the_secret() {
        let identity = DeviceIdentity::generate();
        let shown = format!("{identity:?}");
        assert!(!shown.contains(&hex::encode(identity.to_secret_bytes())));
    }
}
