//! 状态差异 → 最小 Change 集,整个镜像引擎的心脏。
//!
//! 移植自 macro 内嵌 loro-mirror 的 `src/core/diff.ts` 余下部分
//! (LIS 已在 [`crate::lis`])。蓝本没有 diff 的专属测试(行为由
//! mirror*.test.ts 在集成层覆盖),下方用例是逐函数提取的行为规格;
//! mirror.rs 落地后蓝本集成测试会再压一遍。
//!
//! 蓝本怪癖(照抄并钉死):
//!
//! 4. `diffListWithIdSelector` 里 `useContainer = !!(schema?.itemSchema
//!    .getContainerType() ?? true)` —— `??` 对 null 与 undefined 都兜底,
//!    表达式**恒为 true**。这里直接传 true,注释留痕。
//! 5. `diffMap` 对旧值用 JS 真值判断(`if (!oldItem)`):旧值是
//!    0/""/false/null 时一律走「新增」分支 —— 即使新旧相等也会发出一条
//!    冗余 insert。照抄(LWW 写同值无害,但确实多一个 op)。
//!
//! 语言差异(输出等价,已论证):蓝本两处用 `===` 引用相等做快速跳过
//! (`diffList`/`diffListWithIdSelector` 的逐位比较),Rust 的 Value 没有
//! 引用同一性,这里用 [`deep_equal`]。结构相等而引用不同的对象在蓝本里
//! 会掉进「同 id → 递归 diff → 空结果」,输出与直接跳过一致,只是省掉
//! 无操作递归。
//!
//! 已知蓝本局限(照抄,调用方需知):`diffMovableList` 的 move 变更用的
//! 是**删除前的旧索引**——同一批状态更新里既有删除又有跨过删除位的
//! move 时,apply 阶段会索引越界(TS 蓝本同样如此)。上层把重排与删除
//! 作为两次 set_state 提交即可绕开;等上游修了再跟。
//!
//! 错误信息逐字保留蓝本的 throw 文案。

use loro::{ContainerID, ContainerTrait, ContainerType, LoroDoc, ValueOrContainer};

use crate::change::{Change, ChangeKey, ChangeKind, InferContainerOptions};
use crate::lis::longest_increasing_subsequence;
use crate::schema::{IdSelector, Schema};
use crate::utils::{
    container_id_to_container_type, insert_child_to_map, is_value_of_container_type,
    root_container_id, try_infer_container_type, try_update_to_insert_container,
};
use crate::value::{deep_equal, Value};

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum DiffError {
    #[error("Failed to diff container. Old and new state must be objects")]
    RootStateNotObjects,
    #[error("Failed to diff container(map). Old and new state must be objects")]
    MapStateNotObjects,
    #[error("Failed to diff container(list). Old and new state must be arrays")]
    ListStateNotArrays,
    #[error("Failed to diff container(movable list). Old and new state must be arrays")]
    MovableListStateNotArrays,
    #[error("Failed to diff container(text). Old and new state must be strings")]
    TextStateNotStrings,
    #[error("Movable list schema must have an idSelector")]
    MovableListWithoutIdSelector,
    #[error("Expected map container")]
    ExpectedMapContainer,
}

/// JS `typeof value === "object"`:对象、数组、null 都算。蓝本的
/// isObjectLike 就是它。
fn is_object_like(value: &Value) -> bool {
    matches!(value, Value::Object(_) | Value::Array(_) | Value::Null)
}

/// 蓝本 `for (const key in obj)` 的语义化:对象出键,数组出下标字符串,
/// null 无迭代。
fn object_entries(value: &Value) -> Vec<(String, &Value)> {
    match value {
        Value::Object(map) => map.iter().map(|(k, v)| (k.clone(), v)).collect(),
        Value::Array(items) => items
            .iter()
            .enumerate()
            .map(|(i, v)| (i.to_string(), v))
            .collect(),
        _ => Vec::new(),
    }
}

fn object_get<'a>(value: &'a Value, key: &str) -> Option<&'a Value> {
    match value {
        Value::Object(map) => map.get(key),
        Value::Array(items) => items.get(key.parse::<usize>().ok()?),
        _ => None,
    }
}

/// 蓝本怪癖 5 的判定:JS 真值语义下的「假」。NaN 在 serde_json 里进不来,
/// 空集即可。
fn is_falsy(value: Option<&Value>) -> bool {
    match value {
        None | Some(Value::Null) => true,
        Some(Value::Bool(false)) => true,
        Some(Value::Number(n)) => n.as_f64() == Some(0.0),
        Some(Value::String(s)) => s.is_empty(),
        _ => false,
    }
}

/// diff.ts `diffContainer`:按容器类型分派。`container_id = None` 即蓝本的
/// 根层空串。
pub fn diff_container(
    doc: &LoroDoc,
    old_state: &Value,
    new_state: &Value,
    container_id: Option<&ContainerID>,
    schema: Option<&Schema>,
    infer_options: Option<InferContainerOptions>,
) -> Result<Vec<Change>, DiffError> {
    let Some(container_id) = container_id else {
        if !is_object_like(old_state)
            || !is_object_like(new_state)
            || !matches!(schema, None | Some(Schema::Root { .. }))
        {
            return Err(DiffError::RootStateNotObjects);
        }
        return diff_map(doc, old_state, new_state, None, schema, infer_options);
    };

    let Some(container_type) = container_id_to_container_type(container_id) else {
        // 蓝本对未知类型不分派,返回空 changes。
        return Ok(Vec::new());
    };

    match container_type {
        ContainerType::Map => {
            if !is_object_like(old_state)
                || !is_object_like(new_state)
                || !matches!(schema, None | Some(Schema::Map { .. }))
            {
                return Err(DiffError::MapStateNotObjects);
            }
            diff_map(
                doc,
                old_state,
                new_state,
                Some(container_id),
                schema,
                infer_options,
            )
        }
        ContainerType::List => {
            let (Value::Array(old_items), Value::Array(new_items)) = (old_state, new_state) else {
                return Err(DiffError::ListStateNotArrays);
            };
            if !matches!(schema, None | Some(Schema::List { .. })) {
                return Err(DiffError::ListStateNotArrays);
            }
            let (item_schema, id_selector) = match schema {
                Some(Schema::List {
                    item, id_selector, ..
                }) => (item.get().map(|s| s.as_ref()), id_selector.clone()),
                _ => (None, None),
            };
            if let Some(id_selector) = id_selector {
                diff_list_with_id_selector(
                    doc,
                    old_items,
                    new_items,
                    container_id,
                    item_schema,
                    &id_selector,
                    infer_options,
                )
            } else {
                diff_list(
                    doc,
                    old_items,
                    new_items,
                    container_id,
                    item_schema,
                    infer_options,
                )
            }
        }
        ContainerType::MovableList => {
            let (Value::Array(old_items), Value::Array(new_items)) = (old_state, new_state) else {
                return Err(DiffError::MovableListStateNotArrays);
            };
            if !matches!(schema, None | Some(Schema::MovableList { .. })) {
                return Err(DiffError::MovableListStateNotArrays);
            }
            let (item_schema, id_selector) = match schema {
                Some(Schema::MovableList {
                    item, id_selector, ..
                }) => (item.get().map(|s| s.as_ref()), id_selector.clone()),
                _ => (None, None),
            };
            let Some(id_selector) = id_selector else {
                return Err(DiffError::MovableListWithoutIdSelector);
            };
            diff_movable_list(
                doc,
                old_items,
                new_items,
                container_id,
                item_schema,
                &id_selector,
                infer_options,
            )
        }
        ContainerType::Text => {
            let (Value::String(old_text), Value::String(new_text)) = (old_state, new_state) else {
                return Err(DiffError::TextStateNotStrings);
            };
            if !matches!(schema, None | Some(Schema::Text(_))) {
                return Err(DiffError::TextStateNotStrings);
            }
            Ok(diff_text(old_text, new_text, container_id))
        }
        _ => Ok(Vec::new()),
    }
}

/// diff.ts `diffText`:全量替换语义,细粒度靠 mirror 层的 update_by_line
/// (蓝本亦然,text 的最小编辑不在 diff 层)。
pub fn diff_text(old_state: &str, new_state: &str, container_id: &ContainerID) -> Vec<Change> {
    if new_state == old_state {
        return Vec::new();
    }
    vec![Change {
        container: Some(container_id.clone()),
        key: ChangeKey::Prop(String::new()),
        value: Some(Value::String(new_state.to_string())),
        kind: ChangeKind::Insert,
    }]
}

/// 蓝本 `if (id)`:undefined 与空串都算没有 id。
fn select_id(id_selector: &IdSelector, item: &Value) -> Option<String> {
    id_selector(item).filter(|id| !id.is_empty())
}

/// diff.ts `diffMovableList`:删除(降序)→ LIS 最小移动 → 插入 → 更新。
pub fn diff_movable_list(
    doc: &LoroDoc,
    old_state: &[Value],
    new_state: &[Value],
    container_id: &ContainerID,
    item_schema: Option<&Schema>,
    id_selector: &IdSelector,
    infer_options: Option<InferContainerOptions>,
) -> Result<Vec<Change>, DiffError> {
    struct CommonItem<'a> {
        old_index: usize,
        new_index: usize,
        old_item: &'a Value,
        new_item: &'a Value,
    }

    let mut changes: Vec<Change> = Vec::new();

    let mut old_map: std::collections::HashMap<String, (usize, &Value)> =
        std::collections::HashMap::new();
    let mut new_ids: std::collections::HashSet<String> = std::collections::HashSet::new();
    let mut common_items: Vec<CommonItem> = Vec::new();

    for (index, item) in old_state.iter().enumerate() {
        if let Some(id) = select_id(id_selector, item) {
            old_map.insert(id, (index, item));
        }
    }

    for (new_index, item) in new_state.iter().enumerate() {
        if let Some(id) = select_id(id_selector, item) {
            new_ids.insert(id.clone());
            if let Some(&(old_index, old_item)) = old_map.get(&id) {
                common_items.push(CommonItem {
                    old_index,
                    new_index,
                    old_item,
                    new_item: item,
                });
            }
        }
    }

    // 删除:旧有新无,按索引降序,避免删除时的位移。
    let mut deletion_indexes: Vec<usize> = old_map
        .iter()
        .filter(|(id, _)| !new_ids.contains(*id))
        .map(|(_, &(index, _))| index)
        .collect();
    deletion_indexes.sort_unstable_by(|a, b| b.cmp(a));
    changes.extend(deletion_indexes.into_iter().map(|index| Change {
        container: Some(container_id.clone()),
        key: ChangeKey::Index(index),
        value: None,
        kind: ChangeKind::Delete,
    }));

    // 移动:common items(新序)上做旧索引的 LIS;LIS 内的项保持不动,
    // 只移动 LIS 之外且新旧位置不同的项。
    let old_indices_sequence: Vec<usize> = common_items.iter().map(|info| info.old_index).collect();
    let lis_indices = longest_increasing_subsequence(&old_indices_sequence);
    let lis_set: std::collections::HashSet<usize> = lis_indices.into_iter().collect();
    for (i, info) in common_items.iter().enumerate() {
        if !lis_set.contains(&i) && info.old_index != info.new_index {
            changes.push(Change {
                container: Some(container_id.clone()),
                key: ChangeKey::Index(info.old_index),
                value: Some(info.new_item.clone()),
                kind: ChangeKind::Move {
                    from_index: info.old_index,
                    to_index: info.new_index,
                },
            });
        }
    }

    // 插入:新有旧无(或没有 id)的项。
    for (new_index, item) in new_state.iter().enumerate() {
        let known = select_id(id_selector, item).is_some_and(|id| old_map.contains_key(&id));
        if !known {
            changes.push(try_update_to_insert_container(
                Change {
                    container: Some(container_id.clone()),
                    key: ChangeKey::Index(new_index),
                    value: Some(item.clone()),
                    kind: ChangeKind::Insert,
                },
                true,
                item_schema,
            ));
        }
    }

    // 更新:同 id 内容变了。容器项递归,纯值项删+插。
    let movable_list = doc.get_movable_list(container_id.clone());
    for info in &common_items {
        if deep_equal(info.old_item, info.new_item) {
            continue;
        }
        let current_item = movable_list.get(info.old_index);
        if let Some(ValueOrContainer::Container(container)) = current_item {
            changes.extend(diff_container(
                doc,
                info.old_item,
                info.new_item,
                Some(&container.id()),
                item_schema,
                infer_options,
            )?);
        } else {
            changes.push(Change {
                container: Some(container_id.clone()),
                key: ChangeKey::Index(info.new_index),
                value: None,
                kind: ChangeKind::Delete,
            });
            changes.push(try_update_to_insert_container(
                Change {
                    container: Some(container_id.clone()),
                    key: ChangeKey::Index(info.new_index),
                    value: Some(info.new_item.clone()),
                    kind: ChangeKind::Insert,
                },
                true,
                item_schema,
            ));
        }
    }

    Ok(changes)
}

/// diff.ts `diffListWithIdSelector`:带 offset 记账的顺序扫描。
pub fn diff_list_with_id_selector(
    doc: &LoroDoc,
    old_state: &[Value],
    new_state: &[Value],
    container_id: &ContainerID,
    item_schema: Option<&Schema>,
    id_selector: &IdSelector,
    infer_options: Option<InferContainerOptions>,
) -> Result<Vec<Change>, DiffError> {
    let mut changes: Vec<Change> = Vec::new();

    // 蓝本怪癖 4:useContainer 表达式恒为 true(`?? true` 对 null 与
    // undefined 都兜底,而 getContainerType 只会返回类型或 null)。
    let use_container = true;

    let mut old_ids: std::collections::HashSet<String> = std::collections::HashSet::new();
    for item in old_state {
        if let Some(id) = select_id(id_selector, item) {
            old_ids.insert(id);
        }
    }

    let list = doc.get_list(container_id.clone());
    let mut new_index: usize = 0;
    // 蓝本 offset 可为负;有符号记账,应用到 usize 索引时再合成。
    let mut offset: i64 = 0;
    let mut index: usize = 0;
    let signed = |index: usize, offset: i64| -> usize {
        usize::try_from(index as i64 + offset).unwrap_or(0)
    };

    while index < old_state.len() {
        let old_item = &old_state[index];
        let new_item = new_state.get(new_index);

        // 蓝本此处是 `===` 引用相等;deep_equal 输出等价(见模块注释)。
        if new_item.is_some_and(|new_item| deep_equal(old_item, new_item)) {
            new_index += 1;
            index += 1;
            continue;
        }

        let old_id = select_id(id_selector, old_item);
        let new_id = new_item.and_then(|item| select_id(id_selector, item));

        let (Some(old_id), Some(new_id)) = (&old_id, &new_id) else {
            index += 1;
            continue;
        };
        let new_item = new_item.expect("new_id 存在则 new_item 存在");

        if old_id == new_id {
            let item_on_loro = list.get(index);
            if let Some(ValueOrContainer::Container(container)) = item_on_loro {
                changes.extend(diff_container(
                    doc,
                    old_item,
                    new_item,
                    Some(&container.id()),
                    item_schema,
                    infer_options,
                )?);
            } else if !deep_equal(old_item, new_item) {
                changes.push(Change {
                    container: Some(container_id.clone()),
                    key: ChangeKey::Index(signed(index, offset)),
                    value: None,
                    kind: ChangeKind::Delete,
                });
                changes.push(try_update_to_insert_container(
                    Change {
                        container: Some(container_id.clone()),
                        key: ChangeKey::Index(signed(index, offset)),
                        value: Some(new_item.clone()),
                        kind: ChangeKind::Insert,
                    },
                    use_container,
                    item_schema,
                ));
            }
            new_index += 1;
            index += 1;
            continue;
        }

        if !old_ids.contains(new_id) {
            changes.push(try_update_to_insert_container(
                Change {
                    container: Some(container_id.clone()),
                    key: ChangeKey::Index(signed(index, offset)),
                    value: Some(new_item.clone()),
                    kind: ChangeKind::Insert,
                },
                use_container,
                item_schema,
            ));
            // 蓝本 index--/continue(for 循环再 ++):等价于原地重试同一
            // 个旧项。
            offset += 1;
            new_index += 1;
            continue;
        }

        changes.push(Change {
            container: Some(container_id.clone()),
            key: ChangeKey::Index(signed(index, offset)),
            value: None,
            kind: ChangeKind::Delete,
        });
        offset -= 1;
        index += 1;
    }

    while new_index < new_state.len() {
        changes.push(try_update_to_insert_container(
            Change {
                container: Some(container_id.clone()),
                key: ChangeKey::Index(signed(index, offset)),
                value: Some(new_state[new_index].clone()),
                kind: ChangeKind::Insert,
            },
            use_container,
            item_schema,
        ));
        offset += 1;
        new_index += 1;
    }

    Ok(changes)
}

/// diff.ts `diffList`:无 id 选择器的按位比较。可能造成克隆式更新,
/// 蓝本注释同样建议能用 id 就用 diffMovableList。
pub fn diff_list(
    doc: &LoroDoc,
    old_state: &[Value],
    new_state: &[Value],
    container_id: &ContainerID,
    item_schema: Option<&Schema>,
    infer_options: Option<InferContainerOptions>,
) -> Result<Vec<Change>, DiffError> {
    let mut changes: Vec<Change> = Vec::new();
    let old_len = old_state.len();
    let new_len = new_state.len();
    let min_len = old_len.min(new_len);
    let list = doc.get_list(container_id.clone());

    for i in 0..min_len {
        // 蓝本 `===` 快速跳过;deep_equal 输出等价(见模块注释)。
        if deep_equal(&old_state[i], &new_state[i]) {
            continue;
        }
        let item_on_loro = list.get(i);
        if let Some(ValueOrContainer::Container(container)) = item_on_loro {
            changes.extend(diff_container(
                doc,
                &old_state[i],
                &new_state[i],
                Some(&container.id()),
                item_schema,
                infer_options,
            )?);
        } else {
            changes.push(Change {
                container: Some(container_id.clone()),
                key: ChangeKey::Index(i),
                value: None,
                kind: ChangeKind::Delete,
            });
            changes.push(try_update_to_insert_container(
                Change {
                    container: Some(container_id.clone()),
                    key: ChangeKey::Index(i),
                    value: Some(new_state[i].clone()),
                    kind: ChangeKind::Insert,
                },
                true,
                item_schema,
            ));
        }
    }

    // 收缩:蓝本按升序发删除(应用层按同一约定处理)。
    for i in new_len..old_len {
        changes.push(Change {
            container: Some(container_id.clone()),
            key: ChangeKey::Index(i),
            value: None,
            kind: ChangeKind::Delete,
        });
    }

    for (i, item) in new_state.iter().enumerate().take(new_len).skip(old_len) {
        changes.push(try_update_to_insert_container(
            Change {
                container: Some(container_id.clone()),
                key: ChangeKey::Index(i),
                value: Some(item.clone()),
                kind: ChangeKind::Insert,
            },
            true,
            item_schema,
        ));
    }

    Ok(changes)
}

/// diff.ts `diffMap`:根 map 与嵌套 map 共用。`container_id = None` 即根。
pub fn diff_map(
    doc: &LoroDoc,
    old_state: &Value,
    new_state: &Value,
    container_id: Option<&ContainerID>,
    schema: Option<&Schema>,
    infer_options: Option<InferContainerOptions>,
) -> Result<Vec<Change>, DiffError> {
    let mut changes: Vec<Change> = Vec::new();

    let schema_fields = match schema {
        Some(Schema::Map { fields, .. }) | Some(Schema::Root { fields, .. }) => Some(fields),
        _ => None,
    };

    // 删除的键。
    for (key, _) in object_entries(old_state) {
        if object_get(new_state, &key).is_none() {
            changes.push(Change {
                container: container_id.cloned(),
                key: ChangeKey::Prop(key),
                value: None,
                kind: ChangeKind::Delete,
            });
        }
    }

    // 新增或修改的键。
    for (key, new_item) in object_entries(new_state) {
        let old_item = object_get(old_state, &key);

        let child_schema = schema_fields.and_then(|fields| fields.get(&key)).cloned();
        let container_type = child_schema
            .as_deref()
            .and_then(Schema::container_type)
            .or_else(|| try_infer_container_type(new_item, infer_options));

        // 蓝本怪癖 5:旧值为 JS 假值(含 0/""/false/null/缺席)一律按
        // 「新增」处理 —— 新旧相等也发 insert。
        if is_falsy(old_item) {
            match container_type {
                Some(child_type) => changes.push(Change {
                    container: container_id.cloned(),
                    key: ChangeKey::Prop(key),
                    value: Some(new_item.clone()),
                    kind: ChangeKind::InsertContainer { child_type },
                }),
                None => changes.push(Change {
                    container: container_id.cloned(),
                    key: ChangeKey::Prop(key),
                    value: Some(new_item.clone()),
                    kind: ChangeKind::Insert,
                }),
            }
            continue;
        }
        let old_item = old_item.expect("is_falsy 已排除缺席");

        // 蓝本 `oldItem !== newItem`;deep_equal 输出等价(见模块注释)。
        if !deep_equal(old_item, new_item) {
            let both_match_container = container_type.is_some_and(|t| {
                is_value_of_container_type(t, new_item) && is_value_of_container_type(t, old_item)
            });
            if both_match_container {
                let container_type = container_type.expect("both_match_container 蕴含 Some");
                match container_id {
                    // 父层是文档根:子容器按根容器取。
                    None => {
                        let Some(child_id) = root_container_id(doc, &key, container_type) else {
                            return Err(DiffError::ExpectedMapContainer);
                        };
                        changes.extend(diff_container(
                            doc,
                            old_item,
                            new_item,
                            Some(&child_id),
                            child_schema.as_deref(),
                            infer_options,
                        )?);
                    }
                    Some(container_id) => {
                        if container_id.container_type() != ContainerType::Map {
                            return Err(DiffError::ExpectedMapContainer);
                        }
                        let map = doc.get_map(container_id.clone());
                        match map.get(&key) {
                            Some(ValueOrContainer::Container(child)) => {
                                changes.extend(diff_container(
                                    doc,
                                    old_item,
                                    new_item,
                                    Some(&child.id()),
                                    child_schema.as_deref(),
                                    infer_options,
                                )?);
                            }
                            _ => {
                                changes.push(insert_child_to_map(
                                    Some(container_id.clone()),
                                    &key,
                                    new_item.clone(),
                                ));
                            }
                        }
                    }
                }
            } else {
                // 子值形状变了(容器 ↔ 非容器):整体重插。
                changes.push(insert_child_to_map(
                    container_id.cloned(),
                    &key,
                    new_item.clone(),
                ));
            }
        }
    }

    Ok(changes)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::schema::SchemaOptions;
    use serde_json::json;
    use std::sync::Arc;

    fn id_by_field(field: &'static str) -> IdSelector {
        Arc::new(move |item: &Value| {
            item.get(field)
                .and_then(|v| v.as_str())
                .map(|s| s.to_string())
        })
    }

    fn node(id: &str) -> Value {
        json!({"id": id})
    }

    // ---- diffText ----

    #[test]
    fn text_equal_states_produce_no_changes() {
        let doc = LoroDoc::new();
        let cid = doc.get_text("t").id();
        assert!(diff_text("同文", "同文", &cid).is_empty());
    }

    #[test]
    fn text_change_is_one_full_insert() {
        let doc = LoroDoc::new();
        let cid = doc.get_text("t").id();
        let changes = diff_text("旧", "新", &cid);
        assert_eq!(changes.len(), 1);
        assert_eq!(changes[0].kind, ChangeKind::Insert);
        assert_eq!(changes[0].key, ChangeKey::Prop(String::new()));
        assert_eq!(changes[0].value, Some(json!("新")));
    }

    // ---- diffMap ----

    #[test]
    fn map_removed_key_becomes_delete() {
        let doc = LoroDoc::new();
        let changes = diff_map(
            &doc,
            &json!({"gone": 1, "kept": 2}),
            &json!({"kept": 2}),
            None,
            None,
            None,
        )
        .unwrap();
        assert_eq!(changes.len(), 1);
        assert_eq!(changes[0].key, ChangeKey::Prop("gone".into()));
        assert_eq!(changes[0].kind, ChangeKind::Delete);
    }

    #[test]
    fn map_added_primitive_is_plain_insert() {
        let doc = LoroDoc::new();
        let changes = diff_map(&doc, &json!({}), &json!({"n": 7}), None, None, None).unwrap();
        assert_eq!(changes.len(), 1);
        assert_eq!(changes[0].kind, ChangeKind::Insert);
        assert_eq!(changes[0].value, Some(json!(7)));
    }

    #[test]
    fn map_added_object_becomes_container_insert() {
        let doc = LoroDoc::new();
        let schema = Schema::root([("profile", Schema::map([("name", Schema::string())]))]);
        let changes = diff_map(
            &doc,
            &json!({}),
            &json!({"profile": {"name": "a"}}),
            None,
            Some(&schema),
            None,
        )
        .unwrap();
        assert_eq!(changes.len(), 1);
        assert_eq!(
            changes[0].kind,
            ChangeKind::InsertContainer {
                child_type: ContainerType::Map
            }
        );
    }

    /// 蓝本怪癖 5:旧值 0 即使等于新值也发一条冗余 insert。
    #[test]
    fn map_falsy_old_value_reinserts_even_when_equal_blueprint_quirk() {
        let doc = LoroDoc::new();
        let changes = diff_map(&doc, &json!({"n": 0}), &json!({"n": 0}), None, None, None).unwrap();
        assert_eq!(changes.len(), 1);
        assert_eq!(changes[0].kind, ChangeKind::Insert);
        assert_eq!(changes[0].value, Some(json!(0)));
    }

    #[test]
    fn map_root_nested_container_change_recurses() {
        let doc = LoroDoc::new();
        let map = doc.get_map("profile");
        map.insert("name", "a").unwrap();
        doc.commit();

        let schema = Schema::root([("profile", Schema::map([("name", Schema::string())]))]);
        let changes = diff_map(
            &doc,
            &json!({"profile": {"name": "a"}}),
            &json!({"profile": {"name": "b"}}),
            None,
            Some(&schema),
            None,
        )
        .unwrap();
        assert_eq!(changes.len(), 1);
        assert_eq!(changes[0].container, Some(map.id()));
        assert_eq!(changes[0].key, ChangeKey::Prop("name".into()));
        assert_eq!(changes[0].value, Some(json!("b")));
    }

    #[test]
    fn map_shape_change_reinserts_the_child() {
        let doc = LoroDoc::new();
        let map = doc.get_map("m");
        map.insert("k", 1).unwrap();
        doc.commit();
        let cid = map.id();

        // 数字 → 对象:形状变了,整体重插为子容器。
        let changes = diff_map(
            &doc,
            &json!({"k": 1}),
            &json!({"k": {"nested": true}}),
            Some(&cid),
            None,
            None,
        )
        .unwrap();
        assert_eq!(changes.len(), 1);
        assert_eq!(
            changes[0].kind,
            ChangeKind::InsertContainer {
                child_type: ContainerType::Map
            }
        );
    }

    // ---- diffList(无 id) ----

    fn plain_list_doc(values: &[i64]) -> (LoroDoc, ContainerID) {
        let doc = LoroDoc::new();
        let list = doc.get_list("items");
        for (i, v) in values.iter().enumerate() {
            list.insert(i, *v).unwrap();
        }
        doc.commit();
        (doc, list.id())
    }

    #[test]
    fn list_positional_replace_is_delete_then_insert() {
        let (doc, cid) = plain_list_doc(&[1, 2, 3]);
        let changes = diff_list(
            &doc,
            &[json!(1), json!(2), json!(3)],
            &[json!(1), json!(9), json!(3)],
            &cid,
            None,
            None,
        )
        .unwrap();
        assert_eq!(
            changes
                .iter()
                .map(|c| (c.kind.clone(), c.key.clone()))
                .collect::<Vec<_>>(),
            vec![
                (ChangeKind::Delete, ChangeKey::Index(1)),
                (ChangeKind::Insert, ChangeKey::Index(1)),
            ]
        );
    }

    /// 收缩的删除按升序发出 —— 蓝本如此,应用层按此约定处理。钉死顺序。
    #[test]
    fn list_shrink_deletes_ascending_blueprint_order() {
        let (doc, cid) = plain_list_doc(&[1, 2, 3]);
        let changes = diff_list(
            &doc,
            &[json!(1), json!(2), json!(3)],
            &[json!(1)],
            &cid,
            None,
            None,
        )
        .unwrap();
        assert_eq!(
            changes.iter().map(|c| c.key.clone()).collect::<Vec<_>>(),
            vec![ChangeKey::Index(1), ChangeKey::Index(2)]
        );
        assert!(changes.iter().all(|c| c.kind == ChangeKind::Delete));
    }

    #[test]
    fn list_growth_appends_inserts() {
        let (doc, cid) = plain_list_doc(&[1]);
        let changes = diff_list(
            &doc,
            &[json!(1)],
            &[json!(1), json!(2), json!(3)],
            &cid,
            None,
            None,
        )
        .unwrap();
        assert_eq!(changes.len(), 2);
        assert_eq!(changes[0].key, ChangeKey::Index(1));
        assert_eq!(changes[1].key, ChangeKey::Index(2));
    }

    // ---- diffListWithIdSelector ----

    fn keyed_list_schema() -> (Arc<Schema>, IdSelector) {
        let selector = id_by_field("id");
        let item = Schema::map([("id", Schema::string_with(SchemaOptions::required()))]);
        (Schema::list_keyed(item, selector.clone()), selector)
    }

    #[test]
    fn keyed_list_insert_in_the_middle() {
        let doc = LoroDoc::new();
        let cid = doc.get_list("items").id();
        let (schema, selector) = keyed_list_schema();
        let item_schema = match schema.as_ref() {
            Schema::List { item, .. } => item.get().cloned(),
            _ => unreachable!(),
        };
        let changes = diff_list_with_id_selector(
            &doc,
            &[node("a"), node("b")],
            &[node("a"), node("x"), node("b")],
            &cid,
            item_schema.as_deref(),
            &selector,
            None,
        )
        .unwrap();
        assert_eq!(changes.len(), 1);
        assert_eq!(changes[0].key, ChangeKey::Index(1));
        assert_eq!(
            changes[0].kind,
            ChangeKind::InsertContainer {
                child_type: ContainerType::Map
            }
        );
    }

    #[test]
    fn keyed_list_removal_in_the_middle() {
        let doc = LoroDoc::new();
        let cid = doc.get_list("items").id();
        let (_, selector) = keyed_list_schema();
        let changes = diff_list_with_id_selector(
            &doc,
            &[node("a"), node("b"), node("c")],
            &[node("a"), node("c")],
            &cid,
            None,
            &selector,
            None,
        )
        .unwrap();
        assert_eq!(changes.len(), 1);
        assert_eq!(changes[0].key, ChangeKey::Index(1));
        assert_eq!(changes[0].kind, ChangeKind::Delete);
    }

    #[test]
    fn keyed_list_trailing_append_lands_after_survivors() {
        let doc = LoroDoc::new();
        let cid = doc.get_list("items").id();
        let (_, selector) = keyed_list_schema();
        let changes = diff_list_with_id_selector(
            &doc,
            &[node("a")],
            &[node("a"), node("b")],
            &cid,
            None,
            &selector,
            None,
        )
        .unwrap();
        assert_eq!(changes.len(), 1);
        assert_eq!(changes[0].key, ChangeKey::Index(1));
        // 无 item schema 时蓝本不升级容器(tryUpdateToInsertContainer 只在
        // schema 存在时才推断),追加保持纯值 insert。
        assert_eq!(changes[0].kind, ChangeKind::Insert);
    }

    // ---- diffMovableList ----

    fn movable_doc_with_ids(ids: &[&str]) -> (LoroDoc, ContainerID) {
        let doc = LoroDoc::new();
        let list = doc.get_movable_list("items");
        for (i, id) in ids.iter().enumerate() {
            let map = list.insert_container(i, loro::LoroMap::new()).unwrap();
            map.insert("id", *id).unwrap();
        }
        doc.commit();
        (doc, list.id())
    }

    /// 三项轮转只需要一次 move:LIS 保住 [a,b],只有 c 动。
    #[test]
    fn movable_rotation_is_a_single_move() {
        let (doc, cid) = movable_doc_with_ids(&["a", "b", "c"]);
        let selector = id_by_field("id");
        let changes = diff_movable_list(
            &doc,
            &[node("a"), node("b"), node("c")],
            &[node("c"), node("a"), node("b")],
            &cid,
            None,
            &selector,
            None,
        )
        .unwrap();
        assert_eq!(changes.len(), 1);
        assert_eq!(
            changes[0].kind,
            ChangeKind::Move {
                from_index: 2,
                to_index: 0
            }
        );
    }

    /// 删除按索引降序发出,避免应用时的位移。钉死顺序。
    #[test]
    fn movable_deletions_are_descending() {
        let (doc, cid) = movable_doc_with_ids(&["a", "b", "c", "d"]);
        let selector = id_by_field("id");
        let changes = diff_movable_list(
            &doc,
            &[node("a"), node("b"), node("c"), node("d")],
            &[node("b"), node("d")],
            &cid,
            None,
            &selector,
            None,
        )
        .unwrap();
        assert_eq!(
            changes.iter().map(|c| c.key.clone()).collect::<Vec<_>>(),
            vec![ChangeKey::Index(2), ChangeKey::Index(0)]
        );
        assert!(changes.iter().all(|c| c.kind == ChangeKind::Delete));
    }

    #[test]
    fn movable_new_item_is_inserted_at_its_new_index() {
        let (doc, cid) = movable_doc_with_ids(&["a", "b"]);
        let selector = id_by_field("id");
        let item = Schema::map([("id", Schema::string())]);
        let changes = diff_movable_list(
            &doc,
            &[node("a"), node("b")],
            &[node("a"), node("x"), node("b")],
            &cid,
            Some(&item),
            &selector,
            None,
        )
        .unwrap();
        assert_eq!(changes.len(), 1);
        assert_eq!(changes[0].key, ChangeKey::Index(1));
        assert_eq!(
            changes[0].kind,
            ChangeKind::InsertContainer {
                child_type: ContainerType::Map
            }
        );
    }

    /// 同 id 的容器项内容变化走递归 diff,而不是删+插。
    #[test]
    fn movable_update_recurses_into_container_items() {
        let (doc, cid) = movable_doc_with_ids(&["a"]);
        let selector = id_by_field("id");
        let item_schema = Schema::map([("id", Schema::string()), ("label", Schema::string())]);
        let changes = diff_movable_list(
            &doc,
            &[json!({"id": "a", "label": "old"})],
            &[json!({"id": "a", "label": "new"})],
            &cid,
            Some(&item_schema),
            &selector,
            None,
        )
        .unwrap();
        assert_eq!(changes.len(), 1);
        assert_eq!(changes[0].key, ChangeKey::Prop("label".into()));
        // 落在子 map 容器上,而不是列表上
        assert_ne!(changes[0].container, Some(cid));
    }

    // ---- diffContainer 分派 ----

    #[test]
    fn dispatch_movable_without_selector_is_the_blueprint_error() {
        let doc = LoroDoc::new();
        let cid = doc.get_movable_list("items").id();
        // 手工构造无 selector 的 movable schema
        let schema = Schema::MovableList {
            item: crate::schema::SchemaSlot::new(Schema::string()),
            id_selector: None,
            options: SchemaOptions::default(),
        };
        assert_eq!(
            diff_container(
                &doc,
                &json!([]),
                &json!([]),
                Some(&cid),
                Some(&schema),
                None
            ),
            Err(DiffError::MovableListWithoutIdSelector)
        );
    }

    #[test]
    fn dispatch_type_mismatch_errors_match_blueprint_messages() {
        let doc = LoroDoc::new();
        let text_cid = doc.get_text("t").id();
        assert_eq!(
            diff_container(&doc, &json!(1), &json!(2), Some(&text_cid), None, None),
            Err(DiffError::TextStateNotStrings)
        );
        assert_eq!(
            diff_container(&doc, &json!("a"), &json!("b"), None, None, None),
            Err(DiffError::RootStateNotObjects)
        );
    }
}
