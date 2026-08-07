//! 照译蓝本 `tests/core/mirror-movable-list.test.ts`,八个用例全部移植。
//!
//! 蓝本的 `waitForSync`(三个微任务)按 mirror.rs 模块注释的既定约定
//! 删去:Rust 侧事件在 commit 内同步派发,setState 返回后状态已收敛。
//! 蓝本 `mirror.setState(obj)` 的对象形态是根级浅合并,对应
//! `set_state_merge`。

mod common;

use std::sync::Arc;

use common::{cid, deep_value_with_id, value_is_container_of_type};
use loro::LoroDoc;
use serde_json::{json, Value};
use vt_mirror::mirror::{Mirror, MirrorOptions};
use vt_mirror::schema::{IdSelector, Schema};

/// 蓝本 `initTestMirror`。
fn init_test_mirror() -> (Mirror, LoroDoc) {
    let doc = LoroDoc::new();
    doc.set_peer_id(1).unwrap();
    let selector: IdSelector = Arc::new(|item: &Value| {
        item.get("id")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string())
    });
    let schema = Schema::root([(
        "list",
        Schema::movable_list_keyed(
            Schema::map([("id", Schema::string()), ("text", Schema::text())]),
            selector,
        ),
    )]);
    let mirror = Mirror::new(doc.clone(), Some(schema), MirrorOptions::default()).unwrap();
    mirror
        .set_state_merge(&json!({"list": [{"id": "1", "text": "Hello World"}]}))
        .unwrap();
    mirror.sync().unwrap();
    (mirror, doc)
}

/// mirror-movable-list.test.ts: "movable list properly initializes containers"
#[test]
fn movable_list_properly_initializes_containers() {
    let (_mirror, doc) = init_test_mirror();
    let serialized = deep_value_with_id(&doc);

    assert!(
        value_is_container_of_type(&serialized["list"], ":MovableList"),
        "list 字段应是 LoroMovableList 容器"
    );
    assert!(
        value_is_container_of_type(&serialized["list"]["value"][0], ":Map"),
        "list 条目应是 LoroMap 容器"
    );
    assert!(
        value_is_container_of_type(&serialized["list"]["value"][0]["value"]["text"], ":Text"),
        "list 条目的 text 应是 LoroText 容器"
    );
}

/// mirror-movable-list.test.ts: "movable list items retain container ids on insert + move"
#[test]
fn movable_list_items_retain_container_ids_on_insert_and_move() {
    let (mirror, doc) = init_test_mirror();

    let initial_serialized = deep_value_with_id(&doc);
    // 原列表第一项的容器 id
    let initial_id = cid(&initial_serialized["list"]["value"][0]);

    mirror
        .set_state_merge(&json!({"list": [
            {"id": "2", "text": "Hello World"},
            {"id": "1", "text": "Hello World"},
        ]}))
        .unwrap();
    mirror.sync().unwrap();

    let serialized = deep_value_with_id(&doc);
    // 只是移动了条目,第二项的容器 id 应与原第一项相同
    assert_eq!(cid(&serialized["list"]["value"][1]), initial_id);
}

/// mirror-movable-list.test.ts: "movable list handles insertion of items correctly"
#[test]
fn movable_list_handles_insertion_of_items_correctly() {
    let (mirror, doc) = init_test_mirror();

    mirror
        .set_state_merge(&json!({"list": [
            {"id": "1", "text": "Hello World"},
            {"id": "2", "text": "Hello World"},
            {"id": "3", "text": "Hello World"},
        ]}))
        .unwrap();
    mirror.sync().unwrap();

    let serialized = deep_value_with_id(&doc);
    assert_eq!(
        serialized["list"]["value"].as_array().unwrap().len(),
        3,
        "list 应有三个条目"
    );
}

/// mirror-movable-list.test.ts: "movable list handles shuffling of many items at once correctly"
#[test]
fn movable_list_handles_shuffling_of_many_items_at_once_correctly() {
    let (mirror, doc) = init_test_mirror();

    mirror
        .set_state_merge(&json!({"list": [
            {"id": "1", "text": "Hello World"},
            {"id": "2", "text": "Hello World"},
            {"id": "3", "text": "Hello World"},
        ]}))
        .unwrap();
    mirror.sync().unwrap();

    let initial_serialized = deep_value_with_id(&doc);
    let initial_id_of_first_item = cid(&initial_serialized["list"]["value"][0]);
    let initial_id_of_second_item = cid(&initial_serialized["list"]["value"][1]);
    let initial_id_of_third_item = cid(&initial_serialized["list"]["value"][2]);

    let desired_state = json!({"list": [
        {"id": "2", "text": "Hello World"},
        {"id": "3", "text": "Hello World"},
        {"id": "1", "text": "Hello World"},
    ]});

    mirror.set_state_merge(&desired_state).unwrap();
    mirror.sync().unwrap();

    let serialized = deep_value_with_id(&doc);

    assert_eq!(
        cid(&serialized["list"]["value"][0]),
        initial_id_of_second_item,
        "第一项应带原第二项的容器 id"
    );
    assert_eq!(
        cid(&serialized["list"]["value"][1]),
        initial_id_of_third_item,
        "第二项应带原第三项的容器 id"
    );
    assert_eq!(
        cid(&serialized["list"]["value"][2]),
        initial_id_of_first_item,
        "第三项应带原第一项的容器 id"
    );

    assert_eq!(serialized["list"]["value"][0]["value"]["id"], json!("2"));
    assert_eq!(serialized["list"]["value"][1]["value"]["id"], json!("3"));
    assert_eq!(serialized["list"]["value"][2]["value"]["id"], json!("1"));

    assert_eq!(mirror.get_state(), desired_state);
}

/// mirror-movable-list.test.ts: "movable list shuffle with updates should shuffle and update"
#[test]
fn movable_list_shuffle_with_updates_should_shuffle_and_update() {
    let (mirror, doc) = init_test_mirror();

    mirror
        .set_state_merge(&json!({"list": [
            {"id": "1", "text": "Hello World"},
            {"id": "2", "text": "Hello World"},
            {"id": "3", "text": "Hello World"},
        ]}))
        .unwrap();
    mirror.sync().unwrap();

    let desired_state = json!({"list": [
        {"id": "2", "text": "Hello World Updated 2"},
        {"id": "3", "text": "Hello World Updated 3"},
        {"id": "1", "text": "Hello World Updated 1"},
    ]});

    mirror.set_state_merge(&desired_state).unwrap();
    mirror.sync().unwrap();

    let serialized = deep_value_with_id(&doc);

    assert_eq!(
        serialized["list"]["value"][0]["value"]["id"],
        json!("2"),
        "第一项应有正确的 id"
    );
    assert_eq!(
        serialized["list"]["value"][1]["value"]["id"],
        json!("3"),
        "第二项应有正确的 id"
    );
    assert_eq!(
        serialized["list"]["value"][2]["value"]["id"],
        json!("1"),
        "第三项应有正确的 id"
    );

    assert_eq!(
        serialized["list"]["value"][0]["value"]["text"]["value"],
        json!("Hello World Updated 2"),
        "第一项应有正确的 text"
    );
    assert_eq!(
        serialized["list"]["value"][1]["value"]["text"]["value"],
        json!("Hello World Updated 3"),
        "第二项应有正确的 text"
    );
    assert_eq!(
        serialized["list"]["value"][2]["value"]["text"]["value"],
        json!("Hello World Updated 1"),
        "第三项应有正确的 text"
    );

    assert_eq!(mirror.get_state(), desired_state);
}

/// mirror-movable-list.test.ts: "movable list handles basic insert"
#[test]
fn movable_list_handles_basic_insert() {
    let (mirror, doc) = init_test_mirror();

    let desired_state = json!({"list": [
        {"id": "1", "text": "Hello World"},
        {"id": "2", "text": "Hello World"},
    ]});

    mirror.set_state_merge(&desired_state).unwrap();
    mirror.sync().unwrap();

    let serialized = deep_value_with_id(&doc);
    assert_eq!(
        serialized["list"]["value"].as_array().unwrap().len(),
        2,
        "list 应有两个条目"
    );
    assert_eq!(mirror.get_state(), desired_state);
}

/// mirror-movable-list.test.ts: "movable list handles basic delete"
#[test]
fn movable_list_handles_basic_delete() {
    let (mirror, doc) = init_test_mirror();

    mirror.set_state_merge(&json!({"list": []})).unwrap();
    mirror.sync().unwrap();

    let serialized = deep_value_with_id(&doc);
    assert_eq!(
        serialized["list"]["value"].as_array().unwrap().len(),
        0,
        "list 应为空"
    );
}

/// mirror-movable-list.test.ts: "movable list handles basic update"
#[test]
fn movable_list_handles_basic_update() {
    let (mirror, doc) = init_test_mirror();

    let desired_state = json!({"list": [
        {"id": "1", "text": "Hello World 4"},
    ]});

    mirror.set_state_merge(&desired_state).unwrap();
    mirror.sync().unwrap();

    let serialized = deep_value_with_id(&doc);
    assert_eq!(
        serialized["list"]["value"][0]["value"]["text"]["value"],
        json!("Hello World 4"),
        "text 应被更新"
    );
    assert_eq!(mirror.get_state(), desired_state);
}
