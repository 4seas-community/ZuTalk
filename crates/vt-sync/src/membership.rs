//! 一个同步空间的成员名单。
//!
//! 引擎只问两件事:谁是成员、配对成功后怎么把人记上。名单存在哪里、怎么在空间内
//! 同步,是调用方(vt-ffi)的事 —— 它本身通常就是一份同步文档。
//!
//! 放行只看这里:QUIC 握手已经证明了对方的设备 id,[`Membership::is_member`]
//! 说不是,就不同步。

use iroh::EndpointId;

pub trait Membership: Send + Sync + 'static {
    /// 空间内所有设备(可以含本机)。
    fn members(&self) -> Vec<EndpointId>;

    fn is_member(&self, device: &EndpointId) -> bool {
        self.members().contains(device)
    }

    /// 邀请方:出示了有效配对码的新设备入册。
    fn admit(&self, device: EndpointId, name: &str) -> Result<(), String>;
}
