//! 蓝本集成测试的共享脚手架。
//!
//! 蓝本测试依赖 `doc.getDeepValueWithID()` 与 `src/core/utils.ts` 的
//! `valueIsContainer` / `valueIsContainerOfType`,这里给出对应物:
//! loro 的 `get_deep_value_with_id` 把容器节点序列化为 `{cid, value}`
//! 对象,cid 字符串以容器类型名结尾,与蓝本 `endsWith(containerType)`
//! 的判定逐字对应。

#![allow(dead_code)]

use loro::LoroDoc;
use serde_json::Value;

/// 蓝本 `doc.getDeepValueWithID()` 的 JSON 视图。
pub fn deep_value_with_id(doc: &LoroDoc) -> Value {
    Value::from(doc.get_deep_value_with_id())
}

/// utils.ts `valueIsContainer`:带 cid 的 `{cid, value}` 容器节点。
pub fn value_is_container(value: &Value) -> bool {
    value.get("cid").is_some_and(Value::is_string) && value.get("value").is_some()
}

/// utils.ts `valueIsContainerOfType`:cid 以容器类型名结尾。
pub fn value_is_container_of_type(value: &Value, container_type: &str) -> bool {
    value_is_container(value)
        && value["cid"]
            .as_str()
            .is_some_and(|cid| cid.ends_with(container_type))
}

/// 蓝本 `serialized.x.cid`:取容器节点的 cid 字符串。
pub fn cid(value: &Value) -> String {
    value["cid"].as_str().expect("应是容器节点").to_string()
}
