//! 设备组名单。
//!
//! 引擎只问三件事:本机在哪个组、谁是组员、配对成功后怎么把人记上。名单存在
//! 哪里、怎么在组内同步,是调用方(vt-ffi)的事 —— 它本身就是一份同步文档。
//!
//! 放行只看这里:QUIC 握手已经证明了对方的设备 id,[`Membership::is_member`]
//! 说不是,就不同步。

use iroh::EndpointId;

use crate::protocol::GroupId;

pub trait Membership: Send + Sync + 'static {
    /// 本机所在的设备组;还没配对过时为 `None`。
    fn group(&self) -> Option<GroupId>;

    /// 组内所有设备(可以含本机)。
    fn members(&self) -> Vec<EndpointId>;

    fn is_member(&self, device: &EndpointId) -> bool {
        self.members().contains(device)
    }

    /// 邀请方:通过验证的新设备入组。本机还没有设备组时,由实现方在这里新建。
    fn admit(&self, device: EndpointId, name: &str) -> Result<GroupId, String>;

    /// 加入方:被接纳后加入对方的设备组。
    fn join(&self, group: GroupId, inviter: EndpointId, inviter_name: &str) -> Result<(), String>;
}
