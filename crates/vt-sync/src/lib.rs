//! 设备之间直接同步。设计见 `docs/architecture/local-first-sync.md`。
//!
//! 这个包只搬「文档 id + 不透明字节」:谁能连(设备组名单)、连上之后怎么对账、
//! 怎么把差量送到。文档是什么、怎么合并、合并后怎么落进界面读的表,都在调用方。

pub mod engine;
pub mod identity;
pub mod membership;
pub mod pairing;
pub mod protocol;
pub mod store;
pub mod wire;

pub use engine::{Joined, PairError, PeerStatus, SyncConfig, SyncEngine, SyncError};
pub use identity::DeviceIdentity;
pub use iroh::{EndpointAddr, EndpointId, RelayUrl};
pub use membership::Membership;
pub use pairing::{PairRejection, PairingTicket};
pub use protocol::GroupId;
pub use store::{DocId, DocumentStore, StoreError, VersionDigest};
