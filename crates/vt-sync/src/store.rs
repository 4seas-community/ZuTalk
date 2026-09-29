//! 同步引擎看到的文档:一个 id,一个版本,一段差量。
//!
//! 引擎不知道 Loro,也不知道文档里装的是什么 —— 那是调用方(vt-ffi)的事。
//! 引擎只要求:
//!
//! - 能列出本机所有可同步文档及其版本摘要(用来对账);
//! - 给定对方的版本,能导出对方缺的差量;
//! - 能把对方的差量合进来,并说清合进来之后有没有变化;
//! - 能判断一个本机还没有的文档该不该收(文档种类是封闭清单)。
//!
//! 版本是不透明字节(实际是编码后的 Loro 版本向量);摘要是它的规范化哈希,
//! 只用来判断「两边是不是一样」,不参与合并。

/// 文档 id。形如 `library`、`recording/<录音 id>`、`note/<文档 id>`。
pub type DocId = String;

/// 版本摘要。两边摘要相等即认为文档一致,不再交换版本。
pub type VersionDigest = [u8; 32];

#[derive(Debug, thiserror::Error)]
pub enum StoreError {
    #[error("不收这个文档: {0}")]
    NotAccepted(DocId),
    #[error("差量合不进来: {0}")]
    Rejected(String),
    #[error("存储失败: {0}")]
    Storage(String),
}

pub trait DocumentStore: Send + Sync + 'static {
    /// 本机所有可同步文档与各自的版本摘要。
    fn summary(&self) -> Vec<(DocId, VersionDigest)>;

    /// 一个文档的版本摘要;本机没有这个文档时为 `None`。
    fn digest(&self, doc: &DocId) -> Option<VersionDigest>;

    /// 一个文档的版本(不透明字节);本机没有时为 `None`。
    fn version(&self, doc: &DocId) -> Option<Vec<u8>>;

    /// 对方停在 `from` 版本(空字节表示对方什么都没有)时它缺的差量。
    /// 对方已经不缺时为 `None`。
    fn updates_since(&self, doc: &DocId, from: &[u8]) -> Option<Vec<u8>>;

    /// 合入对方的差量。合进来后本机内容有变化时返回 `true`。
    fn apply(&self, doc: &DocId, update: &[u8]) -> Result<bool, StoreError>;

    /// 本机还没有的文档,对方给了,收不收。种类不在清单上的一律不收。
    fn accepts(&self, doc: &DocId) -> bool;
}
