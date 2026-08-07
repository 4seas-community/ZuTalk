//! 应用状态 ↔ Loro CRDT 的镜像同步引擎,TypeScript loro-mirror 的 Rust 移植。
//!
//! 这是 T2(转录稿句块列表)与 B(笔记递归树)两套文档 schema 共用的
//! 投影地基:上层维护一份普通的 Rust 状态,本层负责把状态差异翻译成
//! 最小的 Loro 容器操作(含 MovableList 的 LIS 最小移动)。
//!
//! **移植纪律:先照译上游测试,红;再照译实现,绿。** 不在移植中夹带
//! 行为改动 —— 我们要的是别人已经付过调试成本的行为,不是相似的新代码。
//! 出处与许可证见本 crate 的 THIRD_PARTY.md。

pub mod change;
pub mod diff;
pub mod lis;
pub mod mirror;
pub mod schema;
pub mod utils;
pub mod value;

pub use lis::longest_increasing_subsequence;
pub use value::{deep_equal, get_path_value, is_object, set_path_value, Value};
