//! 设备之间的同步协议。
//!
//! 每对设备一条 QUIC 连接、一条长寿的双向流,所有文档复用。两边对等,没有主从:
//!
//! 1. 连上后互发 [`SyncMessage::Hello`](同一个设备组、同一版协议才继续);
//! 2. 互发完整的 [`SyncMessage::Summary`](文档 id → 版本摘要);
//! 3. 各自比对对方的摘要,对不一致、且本机愿意收的文档发 [`SyncMessage::Want`],
//!    带上本机当前版本;
//! 4. 对方按这个版本导出差量,切块发 [`SyncMessage::Update`]。**每个 Want 都有应答**,
//!    没有可给的也回一个空的末块 —— 这样请求方能确定地知道这一轮结束了;
//! 5. 之后本机改动一个文档,就发一份只含这个文档的 Summary(`complete: false`),
//!    对方照第 3 步拉取;另有定时的完整 Summary 兜底(反熵)。
//!
//! 只拉不推:每台设备只要自己缺的东西,不猜对方缺什么。这让协议没有「我以为你
//! 有了」这类状态可以出错。

use serde::{Deserialize, Serialize};

use crate::store::{DocId, VersionDigest};

/// 设备同步通道。
pub const SYNC_ALPN: &[u8] = b"zutalk/device-sync/1";

/// 协议版本。不同版本的设备不同步,而不是猜着兼容。
pub const PROTOCOL_VERSION: u32 = 1;

/// 差量切块的大小。一个几十 MB 的文档分多块走,单帧远低于
/// [`crate::wire::MAX_FRAME_BYTES`]。
pub const UPDATE_CHUNK_BYTES: usize = 1024 * 1024;

/// 一份差量重组后的上限。对端是自己的设备,但一个坏掉的文档不该吃光内存。
pub const MAX_UPDATE_BYTES: usize = 256 * 1024 * 1024;

/// 设备组 id。随机 32 字节,在配对时由邀请方交给新设备。
#[derive(Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
pub struct GroupId(pub [u8; 32]);

impl GroupId {
    pub fn generate() -> Self {
        Self(rand::random())
    }

    pub fn to_hex(&self) -> String {
        hex::encode(self.0)
    }

    pub fn from_hex(text: &str) -> Option<Self> {
        let bytes = hex::decode(text.trim()).ok()?;
        Some(Self(bytes.try_into().ok()?))
    }
}

impl std::fmt::Debug for GroupId {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "GroupId({})", &self.to_hex()[..8])
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum SyncMessage {
    Hello {
        group: GroupId,
        protocol: u32,
    },
    /// 文档摘要。`complete` 为真时是本机全部可同步文档;为假时只是刚改过的几个。
    Summary {
        docs: Vec<(DocId, VersionDigest)>,
        complete: bool,
    },
    /// 「我停在这个版本,把我缺的给我」。空版本表示本机还没有这个文档。
    Want {
        doc: DocId,
        version: Vec<u8>,
    },
    /// 一块差量。同一份差量的各块连续发出,`last` 标出最后一块;空的末块表示
    /// 对方什么都不缺。
    Update {
        doc: DocId,
        bytes: Vec<u8>,
        last: bool,
    },
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn group_ids_are_random_and_round_trip_through_hex() {
        let a = GroupId::generate();
        let b = GroupId::generate();
        assert_ne!(a, b);
        assert_eq!(GroupId::from_hex(&a.to_hex()), Some(a));
        assert_eq!(GroupId::from_hex("not hex"), None);
    }

    #[test]
    fn an_update_frame_carries_its_bytes_without_inflation() {
        let message = SyncMessage::Update {
            doc: "library".into(),
            bytes: vec![0xAB; 1000],
            last: true,
        };
        let encoded = postcard::to_stdvec(&message).unwrap();
        // JSON 会把每个字节写成 "171,",四倍体积;postcard 只多几个字节的头。
        assert!(encoded.len() < 1020, "{} 字节", encoded.len());
    }
}
