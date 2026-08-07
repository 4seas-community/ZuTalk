//! 应用状态的值表示与路径工具。
//!
//! 移植自 macro 内嵌 loro-mirror 的 `src/core/utils.ts`(isObject / deepEqual /
//! getPathValue / setPathValue 四件),测试照译自 `tests/core/utils.test.ts`。
//!
//! 语言差异约定(逐条,与蓝本行为对齐):
//! - JS 的 `undefined` 在这里表示为**缺席**:读侧用 `Option<&Value>`,写侧用
//!   `None` 触发删除。`null` 仍是 `Value::Null` —— 蓝本里
//!   `deepEqual(null, undefined) === false`,对应这里 `Some(Null) != None`,
//!   由调用方的 Option 相等性承担。
//! - JS 只有一种数值,`42 === 42.0`;serde_json 区分整型/浮点,所以数值比较
//!   一律折算成 f64。
//! - Date/RegExp/Function 在 `serde_json::Value` 里不存在,蓝本对它们的分支
//!   无从移植,属于空集而非行为偏离。

pub use serde_json::Value;

/// utils.ts `isObject`:对象且非数组。(Date/RegExp/Function 的排除在
/// `Value` 类型系统里天然成立。)
pub fn is_object(value: &Value) -> bool {
    value.is_object()
}

/// utils.ts `deepEqual`。与 `Value: PartialEq` 的唯一差别是数值按 JS 语义
/// 折算比较 —— `serde_json` 会把 `42`(u64) 与 `42.0`(f64) 判不等,蓝本
/// 判相等。
pub fn deep_equal(a: &Value, b: &Value) -> bool {
    match (a, b) {
        (Value::Number(x), Value::Number(y)) => match (x.as_f64(), y.as_f64()) {
            (Some(x), Some(y)) => x == y,
            _ => x == y,
        },
        (Value::Array(xs), Value::Array(ys)) => {
            xs.len() == ys.len() && xs.iter().zip(ys).all(|(x, y)| deep_equal(x, y))
        }
        (Value::Object(xs), Value::Object(ys)) => {
            xs.len() == ys.len()
                && xs
                    .iter()
                    .all(|(k, x)| ys.get(k).is_some_and(|y| deep_equal(x, y)))
        }
        _ => a == b,
    }
}

/// utils.ts `getPathValue`。数组允许用数字字符串索引(蓝本路径元素统一是
/// 字符串);任何走不下去的情况返回 `None`(= JS `undefined`)。
pub fn get_path_value<'a>(obj: &'a Value, path: &[&str]) -> Option<&'a Value> {
    let mut current = obj;
    for key in path {
        current = match current {
            Value::Object(map) => map.get(*key)?,
            Value::Array(items) => items.get(key.parse::<usize>().ok()?)?,
            // JS 里对字符串/数字继续取属性得 undefined(字符串的数字索引是
            // 例外,蓝本测试不覆盖,这里统一 None)。
            _ => return None,
        };
    }
    Some(current)
}

/// utils.ts `setPathValue`。`value = None` 即 JS 的 `undefined`,在终点执行
/// 删除;空路径是显式空操作。中间节点缺失或不是容器时创建空对象(数组在
/// JS 里 typeof 也是 "object",所以途经的数组原样保留)。
pub fn set_path_value(obj: &mut Value, path: &[&str], value: Option<Value>) {
    if path.is_empty() {
        return;
    }
    let mut current = obj;
    for key in &path[..path.len() - 1] {
        let needs_object = !matches!(&*current, Value::Object(_) | Value::Array(_));
        if needs_object {
            *current = Value::Object(serde_json::Map::new());
        }
        current = match current {
            Value::Object(map) => map
                .entry(key.to_string())
                .or_insert(Value::Object(serde_json::Map::new())),
            Value::Array(items) => {
                let Ok(index) = key.parse::<usize>() else {
                    return;
                };
                if index >= items.len() {
                    items.resize(index + 1, Value::Null);
                }
                &mut items[index]
            }
            _ => unreachable!("上面刚保证过是容器"),
        };
        // 中间值存在但不是容器(如数字):蓝本会用 {} 盖掉再继续。
        if !matches!(current, Value::Object(_) | Value::Array(_)) {
            *current = Value::Object(serde_json::Map::new());
        }
    }
    let last = path[path.len() - 1];
    match current {
        Value::Object(map) => match value {
            Some(value) => {
                map.insert(last.to_string(), value);
            }
            None => {
                map.remove(last);
            }
        },
        Value::Array(items) => {
            let Ok(index) = last.parse::<usize>() else {
                return;
            };
            match value {
                Some(value) => {
                    if index >= items.len() {
                        items.resize(index + 1, Value::Null);
                    }
                    items[index] = value;
                }
                // JS 的 delete 在数组上留洞(undefined);Value 没有洞,用
                // Null 表示。蓝本测试不覆盖此分支。
                None => {
                    if index < items.len() {
                        items[index] = Value::Null;
                    }
                }
            }
        }
        _ => {}
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    // ---- utils.test.ts describe("isObject") ----

    #[test]
    fn is_object_returns_true_for_objects() {
        assert!(is_object(&json!({})));
        assert!(is_object(&json!({"a": 1})));
    }

    #[test]
    fn is_object_returns_false_for_non_objects() {
        assert!(!is_object(&json!(null)));
        assert!(!is_object(&json!(42)));
        assert!(!is_object(&json!("string")));
        assert!(!is_object(&json!(true)));
        assert!(!is_object(&json!([])));
    }

    // ---- utils.test.ts describe("deepEqual") ----

    #[test]
    fn deep_equal_identical_primitives() {
        assert!(deep_equal(&json!(42), &json!(42)));
        assert!(deep_equal(&json!("hello"), &json!("hello")));
        assert!(deep_equal(&json!(true), &json!(true)));
        assert!(deep_equal(&json!(null), &json!(null)));
        // JS 语义:42 === 42.0
        assert!(deep_equal(&json!(42), &json!(42.0)));
    }

    #[test]
    fn deep_equal_different_primitives() {
        assert!(!deep_equal(&json!(42), &json!(43)));
        assert!(!deep_equal(&json!("hello"), &json!("world")));
        assert!(!deep_equal(&json!(true), &json!(false)));
        assert!(!deep_equal(&json!(0), &json!(null)));
    }

    #[test]
    fn deep_equal_identical_simple_objects() {
        assert!(deep_equal(
            &json!({"a": 1, "b": 2}),
            &json!({"a": 1, "b": 2})
        ));
        // 键序无关
        assert!(deep_equal(
            &json!({"b": 2, "a": 1}),
            &json!({"a": 1, "b": 2})
        ));
    }

    #[test]
    fn deep_equal_different_simple_objects() {
        assert!(!deep_equal(
            &json!({"a": 1, "b": 2}),
            &json!({"a": 1, "b": 3})
        ));
        assert!(!deep_equal(&json!({"a": 1, "b": 2}), &json!({"a": 1})));
        assert!(!deep_equal(&json!({"a": 1}), &json!({"a": 1, "b": 2})));
    }

    #[test]
    fn deep_equal_arrays() {
        assert!(deep_equal(&json!([1, 2, 3]), &json!([1, 2, 3])));
        assert!(!deep_equal(&json!([1, 2, 3]), &json!([1, 2, 4])));
        assert!(!deep_equal(&json!([1, 2, 3]), &json!([1, 2])));
        assert!(!deep_equal(&json!([1, 2]), &json!([1, 2, 3])));
    }

    #[test]
    fn deep_equal_nested_structures() {
        assert!(deep_equal(
            &json!({"a": 1, "b": {"c": 3, "d": [4, 5]}}),
            &json!({"a": 1, "b": {"c": 3, "d": [4, 5]}})
        ));
        assert!(!deep_equal(
            &json!({"a": 1, "b": {"c": 3, "d": [4, 5]}}),
            &json!({"a": 1, "b": {"c": 3, "d": [4, 6]}})
        ));
    }

    // ---- utils.test.ts describe("getPathValue") ----

    fn test_obj() -> Value {
        json!({
            "a": 1,
            "b": {
                "c": 2,
                "d": [3, 4, 5],
                "e": { "f": 6 }
            }
        })
    }

    #[test]
    fn get_path_value_simple_path() {
        assert_eq!(get_path_value(&test_obj(), &["a"]), Some(&json!(1)));
    }

    #[test]
    fn get_path_value_nested_path() {
        assert_eq!(get_path_value(&test_obj(), &["b", "c"]), Some(&json!(2)));
        assert_eq!(
            get_path_value(&test_obj(), &["b", "e", "f"]),
            Some(&json!(6))
        );
    }

    #[test]
    fn get_path_value_array_index() {
        assert_eq!(
            get_path_value(&test_obj(), &["b", "d", "1"]),
            Some(&json!(4))
        );
    }

    #[test]
    fn get_path_value_missing_paths_are_none() {
        assert_eq!(get_path_value(&test_obj(), &["x"]), None);
        assert_eq!(get_path_value(&test_obj(), &["b", "x"]), None);
        assert_eq!(get_path_value(&test_obj(), &["b", "d", "10"]), None);
    }

    #[test]
    fn get_path_value_empty_path_returns_self() {
        let obj = test_obj();
        assert_eq!(get_path_value(&obj, &[]), Some(&obj));
    }

    // ---- utils.test.ts describe("setPathValue") ----

    #[test]
    fn set_path_value_simple_path() {
        let mut obj = json!({"a": 1});
        set_path_value(&mut obj, &["b"], Some(json!(2)));
        assert_eq!(obj, json!({"a": 1, "b": 2}));
    }

    #[test]
    fn set_path_value_updates_existing() {
        let mut obj = json!({"a": 1, "b": 2});
        set_path_value(&mut obj, &["b"], Some(json!(3)));
        assert_eq!(obj, json!({"a": 1, "b": 3}));
    }

    #[test]
    fn set_path_value_nested_path_creates_object() {
        let mut obj = json!({"a": 1});
        set_path_value(&mut obj, &["b", "c"], Some(json!(2)));
        assert_eq!(obj, json!({"a": 1, "b": {"c": 2}}));
    }

    #[test]
    fn set_path_value_updates_nested() {
        let mut obj = json!({"a": 1, "b": {"c": 2}});
        set_path_value(&mut obj, &["b", "c"], Some(json!(3)));
        assert_eq!(obj, json!({"a": 1, "b": {"c": 3}}));
    }

    #[test]
    fn set_path_value_array_element() {
        let mut obj = json!({"a": [1, 2, 3]});
        set_path_value(&mut obj, &["a", "1"], Some(json!(4)));
        assert_eq!(obj, json!({"a": [1, 4, 3]}));
    }

    #[test]
    fn set_path_value_creates_intermediates() {
        let mut obj = json!({});
        set_path_value(&mut obj, &["a", "b", "c"], Some(json!(1)));
        assert_eq!(obj, json!({"a": {"b": {"c": 1}}}));
    }

    #[test]
    fn set_path_value_empty_path_is_noop() {
        let mut obj = json!({"a": 1});
        set_path_value(&mut obj, &[], Some(json!({"b": 2})));
        assert_eq!(obj, json!({"a": 1}));
    }

    #[test]
    fn set_path_value_none_deletes() {
        let mut obj = json!({"a": 1, "b": 2});
        set_path_value(&mut obj, &["b"], None);
        assert_eq!(obj, json!({"a": 1}));
    }
}
