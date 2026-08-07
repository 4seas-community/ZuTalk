//! 照译蓝本 `tests/core/mirror-text.test.ts`,三个用例全部移植。
//!
//! 蓝本的 `waitForSync` 微任务等待按 mirror.rs 模块注释的既定约定删去。
//! 蓝本第二例有两处 `expect(...)` 忘了接匹配器(vitest 下是空断言):
//! 路径合法的一处(`serialized.map` 是 Map 容器)这里升为真断言;另一处
//! `serialized.map.text` 路径本身就是错的(漏了 `.value`),其正确形态在
//! 蓝本后文已有真断言,这里不重复移植。

mod common;

use common::{deep_value_with_id, value_is_container, value_is_container_of_type};
use loro::{Container, LoroDoc, ValueOrContainer};
use serde_json::json;
use vt_mirror::mirror::{Mirror, MirrorOptions};
use vt_mirror::schema::Schema;

/// mirror-text.test.ts: "updates properly reflect when LoroText is at root"
#[test]
fn updates_properly_reflect_when_loro_text_is_at_root() {
    let doc = LoroDoc::new();
    let schema = Schema::root([("text", Schema::text())]);
    let mirror = Mirror::new(doc.clone(), Some(schema), MirrorOptions::default()).unwrap();

    mirror
        .set_state_merge(&json!({"text": "Hello World"}))
        .unwrap();
    mirror.sync().unwrap();

    let serialized = deep_value_with_id(&doc);
    assert!(
        value_is_container_of_type(&serialized["text"], ":Text"),
        "text 字段应是 LoroText 容器"
    );
    assert_eq!(
        serialized["text"]["value"],
        json!("Hello World"),
        "text 字段应为 'Hello World' -- 从镜像写入"
    );

    doc.get_text("text")
        .update("Hello World 2", loro::UpdateOptions::default())
        .unwrap();

    mirror.sync().unwrap();

    assert_eq!(
        mirror.get_state()["text"],
        json!("Hello World 2"),
        "text 字段应为 'Hello World 2' -- 从 loro 写入"
    );

    let serialized = deep_value_with_id(&doc);
    assert!(
        value_is_container_of_type(&serialized["text"], ":Text"),
        "text 字段应是 LoroText 容器 -- 从 loro 写入后"
    );
}

/// mirror-text.test.ts: "updates reflect when LoroText is within a LoroMap"
#[test]
fn updates_reflect_when_loro_text_is_within_a_loro_map() {
    let doc = LoroDoc::new();
    let schema = Schema::root([("map", Schema::map([("text", Schema::text())]))]);
    let mirror = Mirror::new(doc.clone(), Some(schema), MirrorOptions::default()).unwrap();

    mirror
        .set_state_merge(&json!({"map": {"text": "Hello World"}}))
        .unwrap();
    mirror.sync().unwrap();

    let serialized = deep_value_with_id(&doc);
    assert!(
        value_is_container_of_type(&serialized["map"], ":Map"),
        "map 字段应是 LoroMap 容器"
    );
    assert!(
        value_is_container_of_type(&serialized["map"]["value"]["text"], ":Text"),
        "text 字段应是 LoroText 容器 -- 从镜像写入"
    );
    assert_eq!(
        serialized["map"]["value"]["text"]["value"],
        json!("Hello World"),
        "text 字段应为 'Hello World' -- 从镜像写入"
    );

    let map = doc.get_map("map");
    let Some(ValueOrContainer::Container(Container::Text(text))) = map.get("text") else {
        panic!("text 应是 LoroText 容器");
    };
    text.update("Hello World 2", loro::UpdateOptions::default())
        .unwrap();

    mirror.sync().unwrap();

    assert_eq!(
        mirror.get_state()["map"]["text"],
        json!("Hello World 2"),
        "text 字段应为 'Hello World 2' -- 从 loro 写入"
    );

    let serialized = deep_value_with_id(&doc);
    assert!(
        value_is_container(&serialized["map"])
            && value_is_container_of_type(&serialized["map"], ":Map"),
        "map 字段应是 LoroMap 容器 -- 从 loro 写入后"
    );
}

/// mirror-text.test.ts: "updates reflect when LoroText is within LoroList"
#[test]
fn updates_reflect_when_loro_text_is_within_loro_list() {
    let doc = LoroDoc::new();
    let schema = Schema::root([("list", Schema::list(Schema::text()))]);
    let mirror = Mirror::new(doc.clone(), Some(schema), MirrorOptions::default()).unwrap();

    mirror
        .set_state_merge(&json!({"list": ["Hello World"]}))
        .unwrap();
    mirror.sync().unwrap();

    let serialized = deep_value_with_id(&doc);
    assert!(
        value_is_container_of_type(&serialized["list"], ":List"),
        "list 字段应是 LoroList 容器"
    );
    assert!(
        value_is_container_of_type(&serialized["list"]["value"][0], ":Text"),
        "list 条目应是 LoroText 容器"
    );
    assert_eq!(
        serialized["list"]["value"][0]["value"],
        json!("Hello World"),
        "text 应为 'Hello World' -- 从镜像写入"
    );
}
