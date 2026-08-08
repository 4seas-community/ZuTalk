//! Schema 定义系统:声明应用状态与 Loro 容器类型的对应关系。
//!
//! 移植自 macro 内嵌 loro-mirror 的 `src/schema/`(index.ts + types.ts +
//! validators.ts)。schema 层没有专属蓝本测试,下面的用例是从 validators.ts
//! 逐分支提取的行为规格 —— 包括两处蓝本怪癖,照抄不修:
//!
//! 1. **movable-list 不验条目**:`validateSchema` 的 list 分支用
//!    `isLoroListSchema` 守卫条目递归,movable-list 走不进去;
//! 2. **movable-list 没有默认值分支**:`getDefaultValue` 的 switch 只有
//!    `loro-list`,movable-list 落到 default → `undefined`。
//!
//! 语言差异:TS 的 `validate` 返回 `true | false | string`,这里用
//! [`ValidationOutcome`] 三态对应;`defaultValue` 的「键存在性」用
//! `Option<Value>` 对应。

use std::collections::BTreeMap;
use std::sync::{Arc, OnceLock};

use loro::ContainerType;

use crate::value::Value;

/// 自定义校验的结果,对应 TS `validate` 的 `true | false | string`。
pub enum ValidationOutcome {
    /// TS `true`
    Ok,
    /// TS `false` → 通用错误信息
    Fail,
    /// TS 返回字符串 → 自定义错误信息
    FailWith(String),
}

pub type Validator = Arc<dyn Fn(&Value) -> ValidationOutcome + Send + Sync>;
/// 列表条目的身份选择器。蓝本返回 `string | undefined`。
pub type IdSelector = Arc<dyn Fn(&Value) -> Option<String> + Send + Sync>;

/// schema 节点的公共选项,对应 types.ts `SchemaOptions`。
#[derive(Default, Clone)]
pub struct SchemaOptions {
    pub required: bool,
    /// `Some` 即 TS 的「`defaultValue` 键存在」。
    pub default_value: Option<Value>,
    pub validate: Option<Validator>,
}

impl SchemaOptions {
    pub fn required() -> Self {
        Self {
            required: true,
            ..Self::default()
        }
    }
}

/// 递归 schema 的后填充槽:蓝本靠对象引用赋值
/// (`children.itemSchema = nodeSchema`)成环,Rust 里用 OnceLock 一次性
/// 填充。未填充的槽在校验时视为「无条目 schema」(蓝本 idSelector 可缺的
/// 同一精神:判不出来就不判)。
pub struct SchemaSlot {
    cell: OnceLock<Arc<Schema>>,
}

impl SchemaSlot {
    pub fn new(item: Arc<Schema>) -> Self {
        let cell = OnceLock::new();
        let _ = cell.set(item);
        Self { cell }
    }

    /// 建一个空槽,之后用 [`SchemaSlot::fill`] 闭环。
    pub fn deferred() -> Self {
        Self {
            cell: OnceLock::new(),
        }
    }

    /// 填充递归引用。重复填充是编程错误。
    pub fn fill(&self, item: Arc<Schema>) {
        if self.cell.set(item).is_err() {
            panic!("SchemaSlot 只能填充一次");
        }
    }

    pub fn get(&self) -> Option<&Arc<Schema>> {
        self.cell.get()
    }
}

/// 一个 schema 节点,对应 types.ts 的 `SchemaType` 联合。
pub enum Schema {
    /// `schema.String`
    PlainString(SchemaOptions),
    /// `schema.Number`
    PlainNumber(SchemaOptions),
    /// `schema.Boolean`
    PlainBoolean(SchemaOptions),
    /// `schema.Ignore`:不与 Loro 同步的字段
    Ignore(SchemaOptions),
    /// `schema.LoroText`
    Text(SchemaOptions),
    /// `schema.LoroMap`
    Map {
        fields: BTreeMap<String, Arc<Schema>>,
        options: SchemaOptions,
    },
    /// `schema.LoroList`
    List {
        item: SchemaSlot,
        id_selector: Option<IdSelector>,
        options: SchemaOptions,
    },
    /// `schema.LoroMovableList`
    MovableList {
        item: SchemaSlot,
        id_selector: Option<IdSelector>,
        options: SchemaOptions,
    },
    /// `schema(...)`:文档根,每个字段是一个根容器
    Root {
        fields: BTreeMap<String, Arc<Schema>>,
        options: SchemaOptions,
    },
}

impl Schema {
    // ---- index.ts 的构造函数族 ----

    pub fn string() -> Arc<Self> {
        Arc::new(Self::PlainString(SchemaOptions::default()))
    }
    pub fn string_with(options: SchemaOptions) -> Arc<Self> {
        Arc::new(Self::PlainString(options))
    }
    pub fn number() -> Arc<Self> {
        Arc::new(Self::PlainNumber(SchemaOptions::default()))
    }
    pub fn number_with(options: SchemaOptions) -> Arc<Self> {
        Arc::new(Self::PlainNumber(options))
    }
    pub fn boolean() -> Arc<Self> {
        Arc::new(Self::PlainBoolean(SchemaOptions::default()))
    }
    pub fn boolean_with(options: SchemaOptions) -> Arc<Self> {
        Arc::new(Self::PlainBoolean(options))
    }
    pub fn ignore() -> Arc<Self> {
        Arc::new(Self::Ignore(SchemaOptions::default()))
    }
    pub fn text() -> Arc<Self> {
        Arc::new(Self::Text(SchemaOptions::default()))
    }
    pub fn text_with(options: SchemaOptions) -> Arc<Self> {
        Arc::new(Self::Text(options))
    }

    pub fn map<I>(fields: I) -> Arc<Self>
    where
        I: IntoIterator<Item = (&'static str, Arc<Schema>)>,
    {
        Self::map_with(fields, SchemaOptions::default())
    }

    pub fn map_with<I>(fields: I, options: SchemaOptions) -> Arc<Self>
    where
        I: IntoIterator<Item = (&'static str, Arc<Schema>)>,
    {
        Arc::new(Self::Map {
            fields: fields
                .into_iter()
                .map(|(k, v)| (k.to_string(), v))
                .collect(),
            options,
        })
    }

    pub fn list(item: Arc<Schema>) -> Arc<Self> {
        Arc::new(Self::List {
            item: SchemaSlot::new(item),
            id_selector: None,
            options: SchemaOptions::default(),
        })
    }

    pub fn list_keyed(item: Arc<Schema>, id_selector: IdSelector) -> Arc<Self> {
        Arc::new(Self::List {
            item: SchemaSlot::new(item),
            id_selector: Some(id_selector),
            options: SchemaOptions::default(),
        })
    }

    pub fn movable_list_keyed(item: Arc<Schema>, id_selector: IdSelector) -> Arc<Self> {
        Arc::new(Self::MovableList {
            item: SchemaSlot::new(item),
            id_selector: Some(id_selector),
            options: SchemaOptions::default(),
        })
    }

    /// 递归容器:条目 schema 之后再 [`SchemaSlot::fill`]。
    pub fn movable_list_deferred(id_selector: IdSelector) -> Arc<Self> {
        Arc::new(Self::MovableList {
            item: SchemaSlot::deferred(),
            id_selector: Some(id_selector),
            options: SchemaOptions::default(),
        })
    }

    pub fn root<I>(fields: I) -> Arc<Self>
    where
        I: IntoIterator<Item = (&'static str, Arc<Schema>)>,
    {
        Arc::new(Self::Root {
            fields: fields
                .into_iter()
                .map(|(k, v)| (k.to_string(), v))
                .collect(),
            options: SchemaOptions::default(),
        })
    }

    // ---- types.ts `getContainerType` / validators.ts 的类型守卫 ----

    pub fn options(&self) -> &SchemaOptions {
        match self {
            Self::PlainString(o)
            | Self::PlainNumber(o)
            | Self::PlainBoolean(o)
            | Self::Ignore(o)
            | Self::Text(o) => o,
            Self::Map { options, .. }
            | Self::List { options, .. }
            | Self::MovableList { options, .. }
            | Self::Root { options, .. } => options,
        }
    }

    /// `getContainerType()`:原语与 Ignore 返回 `None`。
    pub fn container_type(&self) -> Option<ContainerType> {
        match self {
            Self::PlainString(_)
            | Self::PlainNumber(_)
            | Self::PlainBoolean(_)
            | Self::Ignore(_) => None,
            Self::Text(_) => Some(ContainerType::Text),
            Self::Map { .. } | Self::Root { .. } => Some(ContainerType::Map),
            Self::List { .. } => Some(ContainerType::List),
            Self::MovableList { .. } => Some(ContainerType::MovableList),
        }
    }

    /// validators.ts `isContainerSchema`。注意蓝本不把 Root 算容器 schema。
    pub fn is_container_schema(&self) -> bool {
        matches!(
            self,
            Self::Map { .. } | Self::List { .. } | Self::MovableList { .. } | Self::Text(_)
        )
    }

    pub fn is_list_like(&self) -> bool {
        matches!(self, Self::List { .. } | Self::MovableList { .. })
    }
}

/// validators.ts `validateSchema`。`value = None` 对应 JS `undefined`。
/// 错误信息逐字与蓝本一致 —— 上层测试(以及未来的诊断)依赖这些字符串。
pub fn validate_schema(schema: &Schema, value: Option<&Value>) -> Result<(), Vec<String>> {
    let mut errors: Vec<String> = Vec::new();

    // 蓝本把 null 与 undefined 同等对待。
    let missing = matches!(value, None | Some(Value::Null));
    if schema.options().required && missing {
        return Err(vec!["Value is required".to_string()]);
    }
    if missing {
        return Ok(());
    }
    let value = value.expect("missing 已排除 None");

    match schema {
        Schema::PlainString(_) => {
            if !value.is_string() {
                errors.push("Value must be a string".to_string());
            }
        }
        Schema::PlainNumber(_) => {
            if !value.is_number() {
                errors.push("Value must be a number".to_string());
            }
        }
        Schema::PlainBoolean(_) => {
            if !value.is_boolean() {
                errors.push("Value must be a boolean".to_string());
            }
        }
        Schema::Ignore(_) => {}
        Schema::Text(_) => {
            if !value.is_string() {
                errors.push("Content must be a string".to_string());
            }
        }
        Schema::Map { fields, .. } => {
            if let Value::Object(object) = value {
                for (key, field_schema) in fields {
                    let result = validate_schema(field_schema, object.get(key));
                    if let Err(field_errors) = result {
                        errors.extend(field_errors.into_iter().map(|err| format!("{key}: {err}")));
                    }
                }
            } else {
                errors.push("Value must be an object".to_string());
            }
        }
        Schema::List { item, .. } => {
            if let Value::Array(items) = value {
                // 未填充的递归槽 = 没有条目 schema 可验,与蓝本
                // `isLoroListSchema` 守卫失败时的静默一致。
                if let Some(item_schema) = item.get() {
                    for (index, entry) in items.iter().enumerate() {
                        if let Err(item_errors) = validate_schema(item_schema, Some(entry)) {
                            errors.extend(
                                item_errors
                                    .into_iter()
                                    .map(|err| format!("Item {index}: {err}")),
                            );
                        }
                    }
                }
            } else {
                errors.push("Value must be an array".to_string());
            }
        }
        // 蓝本怪癖 1:movable-list 分支的条目守卫是 `isLoroListSchema`,
        // 恒为 false —— 只查「是数组」,条目一律放行。照抄。
        Schema::MovableList { .. } => {
            if !value.is_array() {
                errors.push("Value must be an array".to_string());
            }
        }
        Schema::Root { fields, .. } => {
            if let Value::Object(object) = value {
                for (key, field_schema) in fields {
                    let result = validate_schema(field_schema, object.get(key));
                    if let Err(field_errors) = result {
                        errors.extend(field_errors.into_iter().map(|err| format!("{key}: {err}")));
                    }
                }
                for key in object.keys() {
                    if !fields.contains_key(key) {
                        errors.push(format!("Unknown property: {key}"));
                    }
                }
            } else {
                errors.push("Value must be an object".to_string());
            }
        }
    }

    if let Some(validate) = &schema.options().validate {
        match validate(value) {
            ValidationOutcome::Ok => {}
            ValidationOutcome::Fail => {
                errors.push("Value failed custom validation".to_string());
            }
            ValidationOutcome::FailWith(message) => errors.push(message),
        }
    }

    if errors.is_empty() {
        Ok(())
    } else {
        Err(errors)
    }
}

/// validators.ts `getDefaultValue`。`None` 对应 JS `undefined`。
pub fn get_default_value(schema: &Schema) -> Option<Value> {
    // `defaultValue` 键存在即生效,哪怕值是 null。
    if let Some(default) = &schema.options().default_value {
        return Some(default.clone());
    }

    match schema {
        Schema::PlainString(options) | Schema::Text(options) => {
            options.required.then(|| Value::String(String::new()))
        }
        Schema::PlainNumber(options) => options.required.then(|| Value::from(0)),
        Schema::PlainBoolean(options) => options.required.then_some(Value::Bool(false)),
        Schema::Map { fields, .. } | Schema::Root { fields, .. } => {
            let mut result = serde_json::Map::new();
            for (key, field_schema) in fields {
                if let Some(value) = get_default_value(field_schema) {
                    result.insert(key.clone(), value);
                }
            }
            Some(Value::Object(result))
        }
        Schema::List { .. } => Some(Value::Array(Vec::new())),
        // 蓝本怪癖 2:switch 没有 movable-list 分支,落 default → undefined。
        // Ignore 同样落 default。照抄。
        Schema::MovableList { .. } | Schema::Ignore(_) => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn person_map() -> Arc<Schema> {
        Schema::map([
            ("name", Schema::string_with(SchemaOptions::required())),
            ("age", Schema::number()),
        ])
    }

    // ---- validateSchema:required 分支 ----

    #[test]
    fn required_and_missing_is_the_required_error() {
        let schema = Schema::string_with(SchemaOptions::required());
        assert_eq!(
            validate_schema(&schema, None),
            Err(vec!["Value is required".to_string()])
        );
        // 蓝本把 null 与 undefined 同等对待
        assert_eq!(
            validate_schema(&schema, Some(&json!(null))),
            Err(vec!["Value is required".to_string()])
        );
    }

    #[test]
    fn optional_and_missing_is_valid() {
        assert_eq!(validate_schema(&Schema::string(), None), Ok(()));
        assert_eq!(
            validate_schema(&Schema::string(), Some(&json!(null))),
            Ok(())
        );
    }

    // ---- validateSchema:类型分支的消息逐字对齐 ----

    #[test]
    fn primitive_type_mismatches_use_blueprint_messages() {
        assert_eq!(
            validate_schema(&Schema::string(), Some(&json!(42))),
            Err(vec!["Value must be a string".to_string()])
        );
        assert_eq!(
            validate_schema(&Schema::number(), Some(&json!("x"))),
            Err(vec!["Value must be a number".to_string()])
        );
        assert_eq!(
            validate_schema(&Schema::boolean(), Some(&json!(1))),
            Err(vec!["Value must be a boolean".to_string()])
        );
        // LoroText 的消息与 String 不同:蓝本写的是 "Content must be a string"
        assert_eq!(
            validate_schema(&Schema::text(), Some(&json!(42))),
            Err(vec!["Content must be a string".to_string()])
        );
    }

    #[test]
    fn ignore_accepts_anything() {
        assert_eq!(validate_schema(&Schema::ignore(), Some(&json!(42))), Ok(()));
        assert_eq!(
            validate_schema(&Schema::ignore(), Some(&json!({"any": "thing"}))),
            Ok(())
        );
    }

    // ---- validateSchema:map 分支 ----

    #[test]
    fn map_rejects_non_objects() {
        assert_eq!(
            validate_schema(&person_map(), Some(&json!("not-an-object"))),
            Err(vec!["Value must be an object".to_string()])
        );
    }

    #[test]
    fn map_field_errors_carry_the_key_prefix() {
        assert_eq!(
            validate_schema(
                &person_map(),
                Some(&json!({"name": "someone", "age": "old"}))
            ),
            Err(vec!["age: Value must be a number".to_string()])
        );
        // required 字段缺失:前缀 + required 消息
        assert_eq!(
            validate_schema(&person_map(), Some(&json!({"age": 3}))),
            Err(vec!["name: Value is required".to_string()])
        );
    }

    #[test]
    fn map_accepts_valid_objects() {
        assert_eq!(
            validate_schema(&person_map(), Some(&json!({"name": "someone", "age": 3}))),
            Ok(())
        );
    }

    // ---- validateSchema:list 分支 ----

    #[test]
    fn list_rejects_non_arrays() {
        let schema = Schema::list(Schema::string());
        assert_eq!(
            validate_schema(&schema, Some(&json!({}))),
            Err(vec!["Value must be an array".to_string()])
        );
    }

    #[test]
    fn list_item_errors_carry_the_index_prefix() {
        let schema = Schema::list(Schema::string());
        assert_eq!(
            validate_schema(&schema, Some(&json!(["ok", 42]))),
            Err(vec!["Item 1: Value must be a string".to_string()])
        );
    }

    /// 蓝本怪癖 1:movable-list 分支的条目守卫是 `isLoroListSchema`,
    /// movable-list 走不进去 —— 条目**不被校验**。照抄。
    #[test]
    fn movable_list_items_are_not_validated_blueprint_quirk() {
        let selector: IdSelector = Arc::new(|item| {
            item.get("id")
                .and_then(|v| v.as_str())
                .map(|s| s.to_string())
        });
        let schema = Schema::movable_list_keyed(Schema::string(), selector);
        // 条目类型全错,但 movable-list 只查「是数组」
        assert_eq!(validate_schema(&schema, Some(&json!([1, 2, 3]))), Ok(()));
        assert_eq!(
            validate_schema(&schema, Some(&json!("not-an-array"))),
            Err(vec!["Value must be an array".to_string()])
        );
    }

    // ---- validateSchema:root 分支 ----

    #[test]
    fn root_rejects_unknown_properties() {
        let schema = Schema::root([("meta", person_map())]);
        assert_eq!(
            validate_schema(
                &schema,
                Some(&json!({"meta": {"name": "someone"}, "extra": 1}))
            ),
            Err(vec!["Unknown property: extra".to_string()])
        );
    }

    // ---- validateSchema:自定义校验 ----

    #[test]
    fn custom_validation_messages() {
        let with_message = Schema::string_with(SchemaOptions {
            validate: Some(Arc::new(|value| {
                if value.as_str().is_some_and(|s| s.len() <= 3) {
                    ValidationOutcome::Ok
                } else {
                    ValidationOutcome::FailWith("too long".to_string())
                }
            })),
            ..SchemaOptions::default()
        });
        assert_eq!(validate_schema(&with_message, Some(&json!("ok"))), Ok(()));
        assert_eq!(
            validate_schema(&with_message, Some(&json!("looooong"))),
            Err(vec!["too long".to_string()])
        );

        let plain_false = Schema::string_with(SchemaOptions {
            validate: Some(Arc::new(|_| ValidationOutcome::Fail)),
            ..SchemaOptions::default()
        });
        assert_eq!(
            validate_schema(&plain_false, Some(&json!("x"))),
            Err(vec!["Value failed custom validation".to_string()])
        );
    }

    // ---- getDefaultValue ----

    #[test]
    fn explicit_default_value_wins() {
        let schema = Schema::string_with(SchemaOptions {
            default_value: Some(json!("preset")),
            ..SchemaOptions::default()
        });
        assert_eq!(get_default_value(&schema), Some(json!("preset")));
    }

    #[test]
    fn required_primitives_default_to_zero_values() {
        assert_eq!(
            get_default_value(&Schema::string_with(SchemaOptions::required())),
            Some(json!(""))
        );
        assert_eq!(
            get_default_value(&Schema::number_with(SchemaOptions::required())),
            Some(json!(0))
        );
        assert_eq!(
            get_default_value(&Schema::boolean_with(SchemaOptions::required())),
            Some(json!(false))
        );
        assert_eq!(
            get_default_value(&Schema::text_with(SchemaOptions::required())),
            Some(json!(""))
        );
    }

    #[test]
    fn optional_primitives_default_to_none() {
        assert_eq!(get_default_value(&Schema::string()), None);
        assert_eq!(get_default_value(&Schema::number()), None);
        assert_eq!(get_default_value(&Schema::boolean()), None);
        assert_eq!(get_default_value(&Schema::text()), None);
    }

    #[test]
    fn map_and_root_assemble_field_defaults() {
        let map = Schema::map([
            ("name", Schema::string_with(SchemaOptions::required())),
            ("age", Schema::number()),
        ]);
        assert_eq!(get_default_value(&map), Some(json!({"name": ""})));

        let root = Schema::root([("profile", map.clone())]);
        assert_eq!(
            get_default_value(&root),
            Some(json!({"profile": {"name": ""}}))
        );
    }

    #[test]
    fn list_defaults_to_empty_array() {
        assert_eq!(
            get_default_value(&Schema::list(Schema::string())),
            Some(json!([]))
        );
    }

    /// 蓝本怪癖 2:getDefaultValue 的 switch 没有 movable-list 分支,
    /// 落到 default → undefined。照抄。
    #[test]
    fn movable_list_has_no_default_blueprint_quirk() {
        let selector: IdSelector = Arc::new(|_| None);
        assert_eq!(
            get_default_value(&Schema::movable_list_keyed(Schema::string(), selector)),
            None
        );
    }

    #[test]
    fn ignore_has_no_default() {
        assert_eq!(get_default_value(&Schema::ignore()), None);
    }
}
