//! 照译蓝本 `tests/core/mirror-list-updates.test.ts`,四个用例全部移植。
//!
//! 蓝本的 `waitForSync` 微任务等待按 mirror.rs 模块注释的既定约定删去;
//! 蓝本 setState 后的 `doc.commit()` 是空提交(镜像已自行 commit),
//! 照抄无害,保留。蓝本第二例的 `throwOnValidationError: true` 在 Rust
//! 移植里没有对应开关 —— setState 校验失败一律返回 Err,行为已是蓝本
//! 开了该开关的形态。

mod common;

use std::sync::Arc;

use loro::{LoroDoc, LoroMap};
use serde_json::{json, Value};
use vt_mirror::mirror::{Mirror, MirrorOptions};
use vt_mirror::schema::{IdSelector, Schema, SchemaOptions};

fn id_selector() -> IdSelector {
    Arc::new(|item: &Value| {
        item.get("id")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string())
    })
}

/// mirror-list-updates.test.ts: "maintains list item identity with idSelector"
#[test]
fn maintains_list_item_identity_with_id_selector() {
    let todo_schema = Schema::root([(
        "todos",
        Schema::list_keyed(
            Schema::map([
                ("id", Schema::string_with(SchemaOptions::required())),
                ("text", Schema::string_with(SchemaOptions::required())),
                (
                    "completed",
                    Schema::boolean_with(SchemaOptions {
                        default_value: Some(json!(false)),
                        ..SchemaOptions::default()
                    }),
                ),
            ]),
            id_selector(),
        ),
    )]);

    let doc = LoroDoc::new();
    // 蓝本先建好容器结构再建镜像
    doc.get_list("todos");
    doc.commit();

    let mirror = Mirror::new(doc.clone(), Some(todo_schema), MirrorOptions::default()).unwrap();

    // 初始三条 todo
    let initial_todos = json!([
        {"id": "1", "text": "Task 1", "completed": false},
        {"id": "2", "text": "Task 2", "completed": false},
        {"id": "3", "text": "Task 3", "completed": false},
    ]);
    mirror
        .set_state_merge(&json!({"todos": initial_todos}))
        .unwrap();

    let state = mirror.get_state();
    assert_eq!(state["todos"].as_array().unwrap().len(), 3);
    assert_eq!(state["todos"][0]["id"], json!("1"));
    assert_eq!(state["todos"][1]["id"], json!("2"));
    assert_eq!(state["todos"][2]["id"], json!("3"));

    // 场景 1:只改一条的属性,顺序不变
    mirror
        .set_state_merge(&json!({"todos": [
            {"id": "1", "text": "Task 1", "completed": false},
            {"id": "2", "text": "Task 2 Updated", "completed": true},
            {"id": "3", "text": "Task 3", "completed": false},
        ]}))
        .unwrap();
    doc.commit();
    mirror.sync().unwrap();

    let state = mirror.get_state();
    assert_eq!(state["todos"].as_array().unwrap().len(), 3);
    assert_eq!(state["todos"][0]["id"], json!("1"));
    assert_eq!(state["todos"][1]["id"], json!("2"));
    assert_eq!(state["todos"][1]["text"], json!("Task 2 Updated"));
    assert_eq!(state["todos"][1]["completed"], json!(true));
    assert_eq!(state["todos"][2]["id"], json!("3"));

    // 场景 2:重排
    mirror
        .set_state_merge(&json!({"todos": [
            {"id": "3", "text": "Task 3", "completed": false},
            {"id": "1", "text": "Task 1", "completed": false},
            {"id": "2", "text": "Task 2 Updated", "completed": true},
        ]}))
        .unwrap();
    doc.commit();
    mirror.sync().unwrap();

    let state = mirror.get_state();
    assert_eq!(state["todos"].as_array().unwrap().len(), 3);
    assert_eq!(state["todos"][0]["id"], json!("3"));
    assert_eq!(state["todos"][1]["id"], json!("1"));
    assert_eq!(state["todos"][2]["id"], json!("2"));
    assert_eq!(state["todos"][2]["text"], json!("Task 2 Updated"));
    assert_eq!(state["todos"][2]["completed"], json!(true));

    // 场景 3:新增一条
    mirror
        .set_state_merge(&json!({"todos": [
            {"id": "3", "text": "Task 3", "completed": false},
            {"id": "1", "text": "Task 1", "completed": false},
            {"id": "2", "text": "Task 2 Updated", "completed": true},
            {"id": "4", "text": "Task 4", "completed": false},
        ]}))
        .unwrap();
    doc.commit();
    mirror.sync().unwrap();

    let state = mirror.get_state();
    assert_eq!(state["todos"].as_array().unwrap().len(), 4);
    assert_eq!(state["todos"][0]["id"], json!("3"));
    assert_eq!(state["todos"][1]["id"], json!("1"));
    assert_eq!(state["todos"][2]["id"], json!("2"));
    assert_eq!(state["todos"][3]["id"], json!("4"));
    assert_eq!(state["todos"][3]["text"], json!("Task 4"));

    // 场景 4:删除一条
    mirror
        .set_state_merge(&json!({"todos": [
            {"id": "3", "text": "Task 3", "completed": false},
            {"id": "1", "text": "Task 1", "completed": false},
            // id "2" 被删除
            {"id": "4", "text": "Task 4", "completed": false},
        ]}))
        .unwrap();
    doc.commit();
    mirror.sync().unwrap();

    let state = mirror.get_state();
    assert_eq!(state["todos"].as_array().unwrap().len(), 3);
    assert_eq!(state["todos"][0]["id"], json!("3"));
    assert_eq!(state["todos"][1]["id"], json!("1"));
    assert_eq!(state["todos"][2]["id"], json!("4"));
    // id "2" 不应再出现在列表里
    assert!(!state["todos"]
        .as_array()
        .unwrap()
        .iter()
        .any(|todo| todo["id"] == json!("2")));
}

/// mirror-list-updates.test.ts: "updates by position without idSelector"
#[test]
fn updates_by_position_without_id_selector() {
    let items_schema = Schema::root([(
        "items",
        // 不提供 idSelector
        Schema::list(Schema::map([(
            "value",
            Schema::string_with(SchemaOptions::required()),
        )])),
    )]);

    let doc = LoroDoc::new();
    let items_list = doc.get_list("items");
    doc.commit();

    // 直接建三个 map 条目
    let item1 = items_list.push_container(LoroMap::new()).unwrap();
    item1.insert("value", "Item 1").unwrap();
    let item2 = items_list.push_container(LoroMap::new()).unwrap();
    item2.insert("value", "Item 2").unwrap();
    let item3 = items_list.push_container(LoroMap::new()).unwrap();
    item3.insert("value", "Item 3").unwrap();
    doc.commit();

    let mirror = Mirror::new(doc.clone(), Some(items_schema), MirrorOptions::default()).unwrap();

    // 初始三条
    mirror
        .set_state_merge(&json!({"items": [
            {"value": "Item 1"},
            {"value": "Item 2"},
            {"value": "Item 3"},
        ]}))
        .unwrap();
    doc.commit();

    let state = mirror.get_state();
    assert_eq!(state["items"].as_array().unwrap().len(), 3);
    assert_eq!(state["items"][0]["value"], json!("Item 1"));
    assert_eq!(state["items"][1]["value"], json!("Item 2"));
    assert_eq!(state["items"][2]["value"], json!("Item 3"));

    // 场景 1:改中间一条
    mirror
        .set_state_merge(&json!({"items": [
            {"value": "Item 1"},
            {"value": "Item 2 Updated"},
            {"value": "Item 3"},
        ]}))
        .unwrap();
    doc.commit();
    mirror.sync().unwrap();

    let state = mirror.get_state();
    assert_eq!(state["items"].as_array().unwrap().len(), 3);
    assert_eq!(state["items"][0]["value"], json!("Item 1"));
    assert_eq!(state["items"][1]["value"], json!("Item 2 Updated"));
    assert_eq!(state["items"][2]["value"], json!("Item 3"));

    // 场景 2:重排
    mirror
        .set_state_merge(&json!({"items": [
            {"value": "Item 3"},
            {"value": "Item 1"},
            {"value": "Item 2 Updated"},
        ]}))
        .unwrap();
    doc.commit();
    mirror.sync().unwrap();

    let state = mirror.get_state();
    assert_eq!(state["items"].as_array().unwrap().len(), 3);
    assert_eq!(state["items"][0]["value"], json!("Item 3"));
    assert_eq!(state["items"][1]["value"], json!("Item 1"));
    assert_eq!(state["items"][2]["value"], json!("Item 2 Updated"));
}

/// mirror-list-updates.test.ts: "efficiently updates nested lists with idSelectors"
#[test]
fn efficiently_updates_nested_lists_with_id_selectors() {
    let nested_schema = Schema::root([(
        "categories",
        Schema::list_keyed(
            Schema::map([
                ("id", Schema::string_with(SchemaOptions::required())),
                ("name", Schema::string_with(SchemaOptions::required())),
                (
                    "items",
                    Schema::list_keyed(
                        Schema::map([
                            ("id", Schema::string_with(SchemaOptions::required())),
                            ("name", Schema::string_with(SchemaOptions::required())),
                            (
                                "quantity",
                                Schema::number_with(SchemaOptions {
                                    default_value: Some(json!(1)),
                                    ..SchemaOptions::default()
                                }),
                            ),
                        ]),
                        id_selector(),
                    ),
                ),
            ]),
            id_selector(),
        ),
    )]);

    let doc = LoroDoc::new();
    doc.get_list("categories");
    doc.commit();

    let mirror = Mirror::new(doc.clone(), Some(nested_schema), MirrorOptions::default()).unwrap();

    // 初始:两个分类,各两条
    mirror
        .set_state_merge(&json!({"categories": [
            {
                "id": "cat1",
                "name": "Category 1",
                "items": [
                    {"id": "item1", "name": "Item 1", "quantity": 1},
                    {"id": "item2", "name": "Item 2", "quantity": 2},
                ],
            },
            {
                "id": "cat2",
                "name": "Category 2",
                "items": [
                    {"id": "item3", "name": "Item 3", "quantity": 3},
                    {"id": "item4", "name": "Item 4", "quantity": 4},
                ],
            },
        ]}))
        .unwrap();
    doc.commit();
    mirror.sync().unwrap();

    let state = mirror.get_state();
    assert_eq!(state["categories"].as_array().unwrap().len(), 2);
    assert_eq!(state["categories"][0]["id"], json!("cat1"));
    assert_eq!(state["categories"][0]["items"].as_array().unwrap().len(), 2);
    assert_eq!(state["categories"][0]["items"][0]["id"], json!("item1"));
    assert_eq!(state["categories"][0]["items"][0]["quantity"], json!(1));

    // 场景:改嵌套条目的属性
    mirror
        .set_state_merge(&json!({"categories": [
            {
                "id": "cat1",
                "name": "Category 1",
                "items": [
                    {"id": "item1", "name": "Item 1", "quantity": 10},
                    {"id": "item2", "name": "Item 2", "quantity": 2},
                ],
            },
            {
                "id": "cat2",
                "name": "Category 2",
                "items": [
                    {"id": "item3", "name": "Item 3", "quantity": 3},
                    {"id": "item4", "name": "Item 4", "quantity": 4},
                ],
            },
        ]}))
        .unwrap();
    doc.commit();
    mirror.sync().unwrap();

    let state = mirror.get_state();
    assert_eq!(state["categories"][0]["items"][0]["quantity"], json!(10));
    assert_eq!(state["categories"][0]["items"][1]["quantity"], json!(2));

    // 场景:新增嵌套条目
    mirror
        .set_state_merge(&json!({"categories": [
            {
                "id": "cat1",
                "name": "Category 1",
                "items": [
                    {"id": "item1", "name": "Item 1", "quantity": 10},
                    {"id": "item2", "name": "Item 2", "quantity": 2},
                    {"id": "item5", "name": "Item 5", "quantity": 5},
                ],
            },
            {
                "id": "cat2",
                "name": "Category 2",
                "items": [
                    {"id": "item3", "name": "Item 3", "quantity": 3},
                    {"id": "item4", "name": "Item 4", "quantity": 4},
                ],
            },
        ]}))
        .unwrap();
    doc.commit();
    mirror.sync().unwrap();

    let state = mirror.get_state();
    assert_eq!(state["categories"][0]["items"].as_array().unwrap().len(), 3);
    assert_eq!(state["categories"][0]["items"][2]["id"], json!("item5"));
    assert_eq!(state["categories"][0]["items"][2]["quantity"], json!(5));
}

/// mirror-list-updates.test.ts: "synchronizes lists correctly with and without idSelector"
#[test]
fn synchronizes_lists_correctly_with_and_without_id_selector() {
    let item_map = || {
        Schema::map([
            ("id", Schema::string_with(SchemaOptions::required())),
            ("value", Schema::string_with(SchemaOptions::required())),
        ])
    };
    let with_id_schema = Schema::root([("items", Schema::list_keyed(item_map(), id_selector()))]);
    let without_id_schema = Schema::root([("items", Schema::list(item_map()))]);
    let movable_list_schema = Schema::root([(
        "items",
        Schema::movable_list_keyed(item_map(), id_selector()),
    )]);

    let doc_with_id = LoroDoc::new();
    doc_with_id.get_list("items");
    doc_with_id.commit();
    let mirror_with_id = Mirror::new(
        doc_with_id.clone(),
        Some(with_id_schema),
        MirrorOptions::default(),
    )
    .unwrap();

    let doc_without_id = LoroDoc::new();
    doc_without_id.get_list("items");
    doc_without_id.commit();
    let mirror_without_id = Mirror::new(
        doc_without_id.clone(),
        Some(without_id_schema),
        MirrorOptions::default(),
    )
    .unwrap();

    let doc_movable = LoroDoc::new();
    doc_movable.get_movable_list("items");
    doc_movable.commit();
    let mirror_movable = Mirror::new(
        doc_movable.clone(),
        Some(movable_list_schema),
        MirrorOptions::default(),
    )
    .unwrap();

    // 生成 10 个条目
    let items: Vec<Value> = (0..10)
        .map(|i| json!({"id": format!("id-{i}"), "value": format!("value-{i}")}))
        .collect();

    mirror_with_id
        .set_state_merge(&json!({"items": items}))
        .unwrap();
    mirror_without_id
        .set_state_merge(&json!({"items": items}))
        .unwrap();
    mirror_movable
        .set_state_merge(&json!({"items": items}))
        .unwrap();
    doc_with_id.commit();
    doc_without_id.commit();
    doc_movable.commit();

    mirror_with_id.sync().unwrap();
    mirror_without_id.sync().unwrap();
    mirror_movable.sync().unwrap();

    assert_eq!(
        mirror_with_id.get_state()["items"]
            .as_array()
            .unwrap()
            .len(),
        10
    );
    assert_eq!(
        mirror_without_id.get_state()["items"]
            .as_array()
            .unwrap()
            .len(),
        10
    );
    assert_eq!(
        mirror_movable.get_state()["items"]
            .as_array()
            .unwrap()
            .len(),
        10
    );

    // 倒序重排
    let reversed_items: Vec<Value> = items.iter().rev().cloned().collect();
    mirror_with_id
        .set_state_merge(&json!({"items": reversed_items}))
        .unwrap();
    mirror_without_id
        .set_state_merge(&json!({"items": reversed_items}))
        .unwrap();
    mirror_movable
        .set_state_merge(&json!({"items": reversed_items}))
        .unwrap();
    doc_with_id.commit();
    doc_without_id.commit();

    mirror_with_id.sync().unwrap();
    mirror_without_id.sync().unwrap();

    for i in 0..10 {
        let expected = json!(format!("id-{}", 9 - i));
        assert_eq!(mirror_with_id.get_state()["items"][i]["id"], expected);
        assert_eq!(mirror_without_id.get_state()["items"][i]["id"], expected);
        assert_eq!(mirror_movable.get_state()["items"][i]["id"], expected);
    }

    // 只比较 items 数组本身
    assert_eq!(
        mirror_with_id.get_state()["items"],
        mirror_without_id.get_state()["items"]
    );
    assert_eq!(
        mirror_without_id.get_state()["items"],
        mirror_movable.get_state()["items"]
    );
}
