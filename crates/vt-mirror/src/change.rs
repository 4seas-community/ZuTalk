//! 一次状态差异要施加到 Loro 文档上的最小操作单元。
//!
//! 移植自 macro 内嵌 loro-mirror 的 `src/core/mirror.ts` 里的 `Change` 联合
//! 类型。TS 用字段组合表达变体,Rust 拆成 `ChangeKind` 枚举;字段对应关系:
//!
//! - `container: ContainerID | ""` → `Option<ContainerID>`(`None` = 根层)
//! - `key: string | number` → [`ChangeKey`]
//! - `value: any`(可 undefined) → `Option<Value>`
//! - `kind + childContainerType + fromIndex/toIndex` → [`ChangeKind`]

use loro::{ContainerID, ContainerType};

use crate::value::Value;

/// TS `key: string | number`:map 键或列表索引。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ChangeKey {
    Prop(String),
    Index(usize),
}

impl From<&str> for ChangeKey {
    fn from(key: &str) -> Self {
        Self::Prop(key.to_string())
    }
}

impl From<usize> for ChangeKey {
    fn from(index: usize) -> Self {
        Self::Index(index)
    }
}

/// TS 的 `kind` 判别 + 附属字段。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ChangeKind {
    /// `kind: "insert"`:纯值插入/覆写
    Insert,
    /// `kind: "delete"`
    Delete,
    /// `kind: "insert-container"`:此处要建子容器,`value` 是它的初始状态
    InsertContainer { child_type: ContainerType },
    /// `kind: "move"`(仅 MovableList)
    Move { from_index: usize, to_index: usize },
}

/// 一条待应用的变更。
#[derive(Debug, Clone, PartialEq)]
pub struct Change {
    /// `None` 对应蓝本的根层空串 `""`。
    pub container: Option<ContainerID>,
    pub key: ChangeKey,
    /// `None` 对应 JS `undefined`(如 delete 变更没有值)。
    pub value: Option<Value>,
    pub kind: ChangeKind,
}

/// mirror.ts `InferContainerOptions`:没有 schema 时按值推断容器类型的开关。
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct InferContainerOptions {
    /// 数组默认建 MovableList 而不是 List
    pub default_movable_list: bool,
    /// 字符串默认建 LoroText 而不是纯值
    pub default_loro_text: bool,
}
