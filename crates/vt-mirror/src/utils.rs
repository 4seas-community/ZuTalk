//! 容器相关工具:类型推断、Change 构造与升级。
//!
//! 移植自 macro 内嵌 loro-mirror 的 `src/core/utils.ts` 余下部分(前四件
//! 值工具在 [`crate::value`])。蓝本没有这些函数的专属测试,下方用例是
//! 逐分支提取的行为规格。
//!
//! 蓝本怪癖 3,照抄并钉死:`tryUpdateToInsertContainer` 的 switch 只有
//! Map/List/Text/Counter 四个分支 —— schema 明明能给出 MovableList,却落
//! 空,变更停留在纯值 insert。上游如此,等上游修了再跟。
//!
//! 语言差异:`containerIdToContainerType` 在 TS 里靠字符串后缀猜类型,
//! Rust 的 `ContainerID` 自带类型,这里直接读 —— 但蓝本对 Map/List/Text/
//! MovableList 之外返回 undefined,照抄(Tree/Counter → None)。

use loro::{ContainerID, ContainerType, LoroDoc};

use crate::change::{Change, ChangeKey, ChangeKind, InferContainerOptions};
use crate::schema::Schema;
use crate::value::{is_object, Value};

/// utils.ts `containerIdToContainerType`。
pub fn container_id_to_container_type(container_id: &ContainerID) -> Option<ContainerType> {
    match container_id.container_type() {
        t @ (ContainerType::Map
        | ContainerType::List
        | ContainerType::Text
        | ContainerType::MovableList) => Some(t),
        _ => None,
    }
}

/// utils.ts `getRootContainerByType` 的可失败版本:蓝本对未知类型
/// `throw new Error()`,这里返回 `None` 让调用方自己处置。
pub fn root_container_id(
    doc: &LoroDoc,
    key: &str,
    container_type: ContainerType,
) -> Option<ContainerID> {
    use loro::ContainerTrait;
    match container_type {
        ContainerType::Text => Some(doc.get_text(key).id()),
        ContainerType::List => Some(doc.get_list(key).id()),
        ContainerType::MovableList => Some(doc.get_movable_list(key).id()),
        ContainerType::Map => Some(doc.get_map(key).id()),
        _ => None,
    }
}

/// utils.ts `insertChildToMap`:按值形状决定是建子容器还是插纯值。
pub fn insert_child_to_map(container_id: Option<ContainerID>, key: &str, value: Value) -> Change {
    if is_object(&value) {
        Change {
            container: container_id,
            key: ChangeKey::from(key),
            value: Some(value),
            kind: ChangeKind::InsertContainer {
                child_type: ContainerType::Map,
            },
        }
    } else if value.is_array() {
        Change {
            container: container_id,
            key: ChangeKey::from(key),
            value: Some(value),
            kind: ChangeKind::InsertContainer {
                child_type: ContainerType::List,
            },
        }
    } else {
        Change {
            container: container_id,
            key: ChangeKey::from(key),
            value: Some(value),
            kind: ChangeKind::Insert,
        }
    }
}

/// utils.ts `tryUpdateToInsertContainer`:把纯值 insert 升级成建容器。
///
/// 蓝本先问 schema(`schemaToContainerType`),问不出再按值猜
/// (`tryInferContainerType`,注意此处**不带** defaults)。
pub fn try_update_to_insert_container(
    mut change: Change,
    to_update: bool,
    schema: Option<&Schema>,
) -> Change {
    if !to_update {
        return change;
    }
    if change.kind != ChangeKind::Insert {
        return change;
    }

    let container_type = schema.and_then(|schema| {
        schema
            .container_type()
            .or_else(|| try_infer_container_type(change.value.as_ref()?, None))
    });

    match container_type {
        Some(
            child_type @ (ContainerType::Map
            | ContainerType::List
            | ContainerType::Text
            | ContainerType::Counter),
        ) => {
            change.kind = ChangeKind::InsertContainer { child_type };
        }
        // 蓝本怪癖 3:switch 没有 MovableList 分支,升级落空。
        _ => {}
    }

    change
}

/// utils.ts `tryInferContainerType`。
pub fn try_infer_container_type(
    value: &Value,
    defaults: Option<InferContainerOptions>,
) -> Option<ContainerType> {
    let defaults = defaults.unwrap_or_default();
    if is_object(value) {
        Some(ContainerType::Map)
    } else if value.is_array() {
        if defaults.default_movable_list {
            Some(ContainerType::MovableList)
        } else {
            Some(ContainerType::List)
        }
    } else if value.is_string() {
        if defaults.default_loro_text {
            Some(ContainerType::Text)
        } else {
            None
        }
    } else {
        None
    }
}

/// utils.ts `isValueOfContainerType`。
///
/// 蓝本用 `typeof value === "object" && value !== null`,数组也过 —— 所以
/// Map 分支对数组同样放行,照抄。
pub fn is_value_of_container_type(container_type: ContainerType, value: &Value) -> bool {
    match container_type {
        ContainerType::MovableList | ContainerType::List | ContainerType::Map => {
            matches!(value, Value::Object(_) | Value::Array(_))
        }
        ContainerType::Text => value.is_string(),
        _ => false,
    }
}

/// utils.ts `inferContainerTypeFromValue`:与 `tryInferContainerType` 相同的
/// 判定,但返回 schema 层的判别名。这里两者共享一个实现,返回
/// `ContainerType` 已足够 —— 蓝本的两份拷贝是 TS 字符串类型系统的产物。
pub fn infer_container_type_from_value(
    value: &Value,
    defaults: Option<InferContainerOptions>,
) -> Option<ContainerType> {
    try_infer_container_type(value, defaults)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::sync::Arc;

    // ---- containerIdToContainerType ----

    #[test]
    fn known_container_types_map_through() {
        let doc = LoroDoc::new();
        use loro::ContainerTrait;
        assert_eq!(
            container_id_to_container_type(&doc.get_map("m").id()),
            Some(ContainerType::Map)
        );
        assert_eq!(
            container_id_to_container_type(&doc.get_list("l").id()),
            Some(ContainerType::List)
        );
        assert_eq!(
            container_id_to_container_type(&doc.get_text("t").id()),
            Some(ContainerType::Text)
        );
        assert_eq!(
            container_id_to_container_type(&doc.get_movable_list("ml").id()),
            Some(ContainerType::MovableList)
        );
    }

    /// 蓝本对四类之外返回 undefined —— Tree 也要 None。
    #[test]
    fn other_container_types_are_none() {
        let doc = LoroDoc::new();
        use loro::ContainerTrait;
        assert_eq!(
            container_id_to_container_type(&doc.get_tree("tr").id()),
            None
        );
    }

    // ---- insertChildToMap ----

    #[test]
    fn objects_become_child_map_containers() {
        let change = insert_child_to_map(None, "profile", json!({"a": 1}));
        assert_eq!(
            change.kind,
            ChangeKind::InsertContainer {
                child_type: ContainerType::Map
            }
        );
        assert_eq!(change.key, ChangeKey::from("profile"));
    }

    #[test]
    fn arrays_become_child_list_containers() {
        let change = insert_child_to_map(None, "items", json!([1, 2]));
        assert_eq!(
            change.kind,
            ChangeKind::InsertContainer {
                child_type: ContainerType::List
            }
        );
    }

    #[test]
    fn primitives_stay_plain_inserts() {
        let change = insert_child_to_map(None, "count", json!(42));
        assert_eq!(change.kind, ChangeKind::Insert);
        assert_eq!(change.value, Some(json!(42)));
    }

    // ---- tryUpdateToInsertContainer ----

    fn plain_insert(value: Value) -> Change {
        Change {
            container: None,
            key: ChangeKey::from("k"),
            value: Some(value),
            kind: ChangeKind::Insert,
        }
    }

    #[test]
    fn no_update_flag_leaves_the_change_alone() {
        let change = try_update_to_insert_container(
            plain_insert(json!({"a": 1})),
            false,
            Some(&Schema::map([])),
        );
        assert_eq!(change.kind, ChangeKind::Insert);
    }

    #[test]
    fn schema_says_map_upgrades_the_insert() {
        let change = try_update_to_insert_container(
            plain_insert(json!({"a": 1})),
            true,
            Some(&Schema::map([])),
        );
        assert_eq!(
            change.kind,
            ChangeKind::InsertContainer {
                child_type: ContainerType::Map
            }
        );
    }

    #[test]
    fn schema_says_text_upgrades_the_insert() {
        let change = try_update_to_insert_container(
            plain_insert(json!("hello")),
            true,
            Some(&Schema::text()),
        );
        assert_eq!(
            change.kind,
            ChangeKind::InsertContainer {
                child_type: ContainerType::Text
            }
        );
    }

    /// 蓝本怪癖 3:schema 给出 MovableList,switch 落空,变更不升级。
    #[test]
    fn movable_list_upgrade_falls_through_blueprint_quirk() {
        let selector: crate::schema::IdSelector = Arc::new(|_| None);
        let schema = Schema::movable_list_keyed(Schema::string(), selector);
        let change =
            try_update_to_insert_container(plain_insert(json!([1, 2])), true, Some(&schema));
        assert_eq!(change.kind, ChangeKind::Insert);
    }

    /// 原语 schema(container_type = None)时按值推断:数组 → List。
    #[test]
    fn primitive_schema_falls_back_to_value_inference() {
        let change = try_update_to_insert_container(
            plain_insert(json!([1, 2])),
            true,
            Some(&Schema::ignore()),
        );
        assert_eq!(
            change.kind,
            ChangeKind::InsertContainer {
                child_type: ContainerType::List
            }
        );
    }

    /// 没有 schema 时完全不升级(蓝本:containerType = undefined)。
    #[test]
    fn no_schema_means_no_upgrade() {
        let change = try_update_to_insert_container(plain_insert(json!({"a": 1})), true, None);
        assert_eq!(change.kind, ChangeKind::Insert);
    }

    /// 值推断不带 defaults:字符串推不出 Text(蓝本内部调用同样不传)。
    #[test]
    fn plain_string_without_text_schema_stays_plain() {
        let change = try_update_to_insert_container(
            plain_insert(json!("hello")),
            true,
            Some(&Schema::ignore()),
        );
        assert_eq!(change.kind, ChangeKind::Insert);
    }

    #[test]
    fn delete_changes_are_never_upgraded() {
        let change = Change {
            container: None,
            key: ChangeKey::from("k"),
            value: None,
            kind: ChangeKind::Delete,
        };
        let unchanged =
            try_update_to_insert_container(change.clone(), true, Some(&Schema::map([])));
        assert_eq!(unchanged, change);
    }

    // ---- tryInferContainerType / isValueOfContainerType ----

    #[test]
    fn infer_container_type_from_values() {
        assert_eq!(
            try_infer_container_type(&json!({"a": 1}), None),
            Some(ContainerType::Map)
        );
        assert_eq!(
            try_infer_container_type(&json!([1]), None),
            Some(ContainerType::List)
        );
        assert_eq!(try_infer_container_type(&json!("s"), None), None);
        assert_eq!(try_infer_container_type(&json!(42), None), None);
    }

    #[test]
    fn infer_respects_defaults() {
        let defaults = InferContainerOptions {
            default_movable_list: true,
            default_loro_text: true,
        };
        assert_eq!(
            try_infer_container_type(&json!([1]), Some(defaults)),
            Some(ContainerType::MovableList)
        );
        assert_eq!(
            try_infer_container_type(&json!("s"), Some(defaults)),
            Some(ContainerType::Text)
        );
    }

    /// 蓝本用 typeof === "object",数组能过 Map 检查 —— 照抄。
    #[test]
    fn value_of_container_type_matches_blueprint_typeof_semantics() {
        assert!(is_value_of_container_type(ContainerType::Map, &json!([1])));
        assert!(is_value_of_container_type(
            ContainerType::Map,
            &json!({"a": 1})
        ));
        assert!(!is_value_of_container_type(ContainerType::Map, &json!("s")));
        assert!(is_value_of_container_type(
            ContainerType::List,
            &json!({"a": 1})
        ));
        assert!(is_value_of_container_type(ContainerType::Text, &json!("s")));
        assert!(!is_value_of_container_type(ContainerType::Text, &json!(1)));
        assert!(!is_value_of_container_type(
            ContainerType::Counter,
            &json!(1)
        ));
    }
}
