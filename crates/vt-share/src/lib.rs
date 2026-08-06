//! 点对点分享:字幕广播、文档协同与文本资源传输。
//!
//! 设计见 `docs/architecture/share-p2p.md`。
//!
//! # 这个 crate 的边界
//!
//! 不依赖 `vt-crypto` 与 `vt-audio`,因此拿不到 `SessionKey`、也碰不到 PCM。
//! **音频永远不会经由分享路径离开本机**,这一点由依赖图保证,不由代码纪律保证;
//! `scripts/test_share_no_audio_gate.sh` 在 CI 里对此断言。
//!
//! # 三条通道
//!
//! | 数据 | 通道 | 可靠性 |
//! | --- | --- | --- |
//! | 实时字幕预览 | [`net::LIVE_CAPTION_ALPN`],每帧一条 uni-stream | 整帧到达或不到达,按 revision 丢旧 |
//! | 房间控制面 | `iroh-gossip`(单条 4 KB 上限) | 必达,小消息 |
//! | 文档协同 | [`net::DOC_SYNC_ALPN`],成对直连 | 必达,可乱序 |

mod caption;
mod docsync;
mod envelope;
mod identity;
pub mod net;
mod permission;
mod resource;
mod room;
mod room_control;
mod shareable;
mod sharecode;
mod wire;

pub use caption::{CaptionFrame, CaptionLine, CaptionReceiver, FrameOutcome};
pub use docsync::{
    declare_versions, handle_incoming_update, respond_to_have, seal_update, DocSyncMessage,
    DocumentSync, DocumentUpdatePayload, DocumentVersion, IncomingOutcome,
};
pub use envelope::{EnvelopeError, PayloadKind, ShareEnvelope, UnsignedEnvelope};
pub use identity::ShareIdentity;
pub use net::{DocSyncContext, ShareEndpoint, ShareEndpointConfig};
pub use permission::{
    admit_document_update, AdmissionDenial, AllowAllBoundaries, CaptureBoundaryGuard, RoomRoster,
    WritePolicy,
};
pub use resource::{
    answer as answer_resource_request, ResourceError, ResourceProvider, ResourceRequest,
    ResourceResponse, MAX_RESOURCE_BYTES,
};
pub use room::{RoomSecret, ScopeId};
pub use room_control::{
    open as open_room_control, seal as seal_room_control, ControlError, RoomControl, RoomPresence,
    MAX_ROSTER_MEMBERS,
};
pub use shareable::ShareableKind;
pub use sharecode::ShareCode;
pub use wire::{content_digest, WireError, MAX_MESSAGE_BYTES};

/// 分享层错误。
#[derive(Debug, thiserror::Error)]
pub enum ShareError {
    /// 请求的资源在本机不存在或尚未生成。
    #[error("资源不可用: {0}")]
    ResourceUnavailable(String),
    #[error(transparent)]
    Net(#[from] net::NetError),
    #[error(transparent)]
    Wire(#[from] WireError),
    #[error(transparent)]
    Admission(#[from] AdmissionDenial),
}
