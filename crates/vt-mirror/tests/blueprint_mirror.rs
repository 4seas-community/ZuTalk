//! 照译蓝本 `tests/core/mirror.test.ts`,十三个用例全部移植。
//! (mirror.rs 底部 tests 模块覆盖的是 state.test.ts 的门面用例与
//! 各集成场景的核心断言,与本文件不重复。)
//!
//! 语言差异约定(与 mirror.rs 模块注释一致,无用例跳过):
//! - `waitForSync` 微任务等待与 `setTimeout` 删去:Rust 侧事件在 commit
//!   内同步派发。
//! - `mirror.dispose()` 对应丢弃最后一个 Mirror 句柄(drop 即释放全部
//!   doc 订阅)。
//! - 蓝本部分 `expect(...)` 忘了接匹配器(vitest 下是空断言),路径合法
//!   的一律升为真断言。
//! - 蓝本把已挂载的根容器 insertContainer 进列表/地图时,loro 语义是
//!   深拷贝一份,Rust 侧行为相同,照抄蓝本的写法。

mod common;

use std::sync::{Arc, Mutex};

use common::{deep_value_with_id, value_is_container, value_is_container_of_type};
use loro::{LoroDoc, LoroValue};
use serde_json::{json, Value};
use vt_mirror::change::InferContainerOptions;
use vt_mirror::mirror::{Mirror, MirrorOptions, SyncDirection};
use vt_mirror::schema::{Schema, SchemaOptions, SchemaSlot};

fn default_of(value: Value) -> SchemaOptions {
    SchemaOptions {
        default_value: Some(value),
        ..SchemaOptions::default()
    }
}

/// mirror.test.ts: "syncs initial state from LoroDoc correctly"
#[test]
fn syncs_initial_state_from_loro_doc_correctly() {
    let doc = LoroDoc::new();
    let todo_map = doc.get_map("todos");
    todo_map
        .insert(
            "1",
            LoroValue::from(json!({"id": "1", "text": "Buy milk", "completed": false})),
        )
        .unwrap();
    todo_map
        .insert(
            "2",
            LoroValue::from(json!({"id": "2", "text": "Write tests", "completed": true})),
        )
        .unwrap();
    doc.commit();

    let todo_schema = Schema::root([(
        "todos",
        Schema::map([
            ("id", Schema::string()),
            ("text", Schema::string()),
            ("completed", Schema::boolean()),
        ]),
    )]);

    let mirror = Mirror::new(doc, Some(todo_schema), MirrorOptions::default()).unwrap();

    let state = mirror.get_state();
    assert_eq!(
        state["todos"]["1"],
        json!({"id": "1", "text": "Buy milk", "completed": false})
    );
    assert_eq!(
        state["todos"]["2"],
        json!({"id": "2", "text": "Write tests", "completed": true})
    );
}

/// mirror.test.ts: "updates app state when LoroDoc changes"
#[test]
fn updates_app_state_when_loro_doc_changes() {
    let doc = LoroDoc::new();
    let counter_schema = Schema::root([("meta", Schema::map([("counter", Schema::number())]))]);

    let map = doc.get_map("meta");
    map.insert("counter", 0).unwrap();
    doc.commit();

    let mirror = Mirror::new(doc.clone(), Some(counter_schema), MirrorOptions::default()).unwrap();

    assert_eq!(mirror.get_state()["meta"]["counter"], json!(0));

    // 用订阅记录镜像状态变化
    let state_changes: Arc<Mutex<Vec<Value>>> = Arc::new(Mutex::new(Vec::new()));
    let directions: Arc<Mutex<Vec<SyncDirection>>> = Arc::new(Mutex::new(Vec::new()));
    let state_changes_cb = state_changes.clone();
    let directions_cb = directions.clone();
    let _subscription = mirror.subscribe(Arc::new(move |state, meta| {
        state_changes_cb.lock().unwrap().push(state.clone());
        directions_cb.lock().unwrap().push(meta.direction);
    }));

    map.insert("counter", 5).unwrap();
    doc.commit();

    assert_eq!(mirror.get_state()["meta"]["counter"], json!(5));

    let state_changes = state_changes.lock().unwrap();
    let directions = directions.lock().unwrap();
    assert!(!state_changes.is_empty());
    assert_eq!(state_changes.last().unwrap()["meta"]["counter"], json!(5));
    assert_eq!(*directions.last().unwrap(), SyncDirection::FromLoro);
}

/// mirror.test.ts: "updates LoroDoc when app state changes"
#[test]
fn updates_loro_doc_when_app_state_changes() {
    let doc = LoroDoc::new();
    let user_schema = Schema::root([(
        "user",
        Schema::map([("name", Schema::string()), ("email", Schema::string())]),
    )]);

    let user_map = doc.get_map("user");
    user_map.insert("name", "Jane").unwrap();
    user_map.insert("email", "jane.example").unwrap();
    doc.commit();

    let mirror = Mirror::new(doc.clone(), Some(user_schema), MirrorOptions::default()).unwrap();

    mirror
        .set_state_merge(&json!({"user": {"name": "John", "email": "john.example"}}))
        .unwrap();

    assert_eq!(
        user_map.get("name").unwrap().into_value().unwrap(),
        LoroValue::from("John")
    );
    assert_eq!(
        user_map.get("email").unwrap().into_value().unwrap(),
        LoroValue::from("john.example")
    );
}

/// mirror.test.ts: "handles nested container updates"
#[test]
fn handles_nested_container_updates() {
    let doc = LoroDoc::new();
    let blog_schema = Schema::root([(
        "blog",
        Schema::map([
            ("title", Schema::string_with(default_of(json!("My Blog")))),
            (
                "posts",
                Schema::list(Schema::map([
                    ("id", Schema::string_with(SchemaOptions::required())),
                    ("title", Schema::string_with(SchemaOptions::required())),
                    ("content", Schema::string_with(default_of(json!("")))),
                ])),
            ),
        ]),
    )]);

    // 蓝本以根容器为脚手架:post1 是根 map,insertContainer 深拷贝进列表
    let blog_map = doc.get_map("blog");
    blog_map.insert("title", "My Blog").unwrap();

    let posts_list = doc.get_list("posts");

    let post1 = doc.get_map("post1");
    post1.insert("id", "1").unwrap();
    post1.insert("title", "First Post").unwrap();
    post1.insert("content", "Hello World").unwrap();

    posts_list.insert_container(0, post1).unwrap();
    blog_map
        .insert_container("posts", doc.get_list("posts"))
        .unwrap();
    doc.commit();

    let mirror = Mirror::new(doc.clone(), Some(blog_schema), MirrorOptions::default()).unwrap();
    mirror.sync().unwrap();

    let initial_state = mirror.get_state();
    assert_eq!(initial_state["blog"]["title"], json!("My Blog"));

    // 蓝本的条件断言:posts 可能出现在 blog.posts,也可能在根层
    if initial_state["blog"]["posts"]
        .as_array()
        .is_some_and(|posts| !posts.is_empty())
    {
        assert_eq!(initial_state["blog"]["posts"][0]["id"], json!("1"));
        assert_eq!(
            initial_state["blog"]["posts"][0]["title"],
            json!("First Post")
        );
    } else if let Some(posts) = initial_state["posts"].as_array() {
        assert!(!posts.is_empty());
        assert_eq!(posts[0]["id"], json!("1"));
        assert_eq!(posts[0]["title"], json!("First Post"));
    }

    // 第二篇
    let post2 = doc.get_map("post2");
    post2.insert("id", "2").unwrap();
    post2.insert("title", "Second Post").unwrap();
    post2.insert("content", "More content").unwrap();

    posts_list.insert_container(1, post2).unwrap();
    doc.commit();

    mirror.sync().unwrap();

    let updated_state = mirror.get_state();
    if let Some(posts) = updated_state["blog"]["posts"].as_array() {
        if posts.len() > 1 {
            assert_eq!(posts[1]["id"], json!("2"));
            assert_eq!(posts[1]["title"], json!("Second Post"));
        }
    } else if let Some(posts) = updated_state["posts"].as_array() {
        let found = posts.iter().find(|post| post["id"] == json!("2"));
        assert!(found.is_some());
        if let Some(found) = found {
            assert_eq!(found["title"], json!("Second Post"));
        }
    }
}

/// mirror.test.ts: "maintains consistency during rapid changes"
#[test]
fn maintains_consistency_during_rapid_changes() {
    let doc = LoroDoc::new();
    let counter_schema = Schema::root([(
        "meta",
        Schema::map([("counter", Schema::number_with(default_of(json!(0))))]),
    )]);

    let map = doc.get_map("meta");
    map.insert("counter", 0).unwrap();
    doc.commit();

    let mirror = Mirror::new(doc.clone(), Some(counter_schema), MirrorOptions::default()).unwrap();

    assert_eq!(mirror.get_state()["meta"]["counter"], json!(0));

    // 连续快速更新
    for i in 1..=5 {
        mirror
            .set_state_merge(&json!({"meta": {"counter": i}}))
            .unwrap();
        doc.commit();
    }

    assert_eq!(mirror.get_state()["meta"]["counter"], json!(5));
}

/// mirror.test.ts: "syncFromLoro and syncToLoro methods maintain consistency"
#[test]
fn sync_from_loro_and_sync_to_loro_methods_maintain_consistency() {
    let doc = LoroDoc::new();
    let data_schema = Schema::root([(
        "meta",
        Schema::map([("value", Schema::string_with(default_of(json!("initial"))))]),
    )]);

    let map = doc.get_map("meta");
    map.insert("value", "initial").unwrap();
    doc.commit();

    let mirror = Mirror::new(doc.clone(), Some(data_schema), MirrorOptions::default()).unwrap();

    assert_eq!(mirror.get_state()["meta"]["value"], json!("initial"));

    // 直接改 LoroDoc
    map.insert("value", "updated in loro").unwrap();
    doc.commit();

    // 手动从 Loro 同步
    mirror.sync_from_loro();

    assert_eq!(
        mirror.get_state()["meta"]["value"],
        json!("updated in loro")
    );

    mirror
        .set_state_merge(&json!({"meta": {"value": "updated in app"}}))
        .unwrap();

    // 手动同步到 Loro 并提交
    mirror.sync_to_loro().unwrap();
    doc.commit();

    assert_eq!(
        map.get("value").unwrap().into_value().unwrap(),
        LoroValue::from("updated in app")
    );
}

/// mirror.test.ts: "handles text container updates correctly"
#[test]
fn handles_text_container_updates_correctly() {
    let doc = LoroDoc::new();
    let note_schema = Schema::root([("note", Schema::text_with(default_of(json!(""))))]);

    let note_text = doc.get_text("note");
    note_text
        .update("Initial note text", loro::UpdateOptions::default())
        .unwrap();
    doc.commit();

    let mirror = Mirror::new(doc.clone(), Some(note_schema), MirrorOptions::default()).unwrap();

    assert_eq!(mirror.get_state()["note"], json!("Initial note text"));

    // 从 LoroDoc 侧更新文本
    note_text
        .update(
            "Updated note text from Loro",
            loro::UpdateOptions::default(),
        )
        .unwrap();
    doc.commit();

    assert_eq!(
        mirror.get_state()["note"],
        json!("Updated note text from Loro")
    );

    mirror
        .set_state_merge(&json!({"note": "Updated note text from app"}))
        .unwrap();
    doc.commit();

    assert_eq!(
        mirror.get_state()["note"],
        json!("Updated note text from app")
    );
}

/// mirror.test.ts: "detects new containers created during runtime"
#[test]
fn detects_new_containers_created_during_runtime() {
    let doc = LoroDoc::new();
    let dynamic_schema = Schema::root([(
        "items",
        Schema::list(Schema::map([
            ("id", Schema::string_with(SchemaOptions::required())),
            ("name", Schema::string_with(SchemaOptions::required())),
        ])),
    )]);

    let items_list = doc.get_list("items");

    let item1 = doc.get_map("item1");
    item1.insert("id", "1").unwrap();
    item1.insert("name", "First Item").unwrap();

    items_list.insert_container(0, item1).unwrap();
    doc.commit();

    let mirror = Mirror::new(doc.clone(), Some(dynamic_schema), MirrorOptions::default()).unwrap();

    let initial_state = mirror.get_state();
    assert_eq!(initial_state["items"].as_array().unwrap().len(), 1);
    assert_eq!(initial_state["items"][0]["name"], json!("First Item"));

    // 运行时新增容器
    let item2 = doc.get_map("item2");
    item2.insert("id", "2").unwrap();
    item2.insert("name", "Second Item").unwrap();

    items_list.insert_container(1, item2).unwrap();
    doc.commit();

    mirror.sync_from_loro();

    let updated_state = mirror.get_state();
    assert_eq!(updated_state["items"].as_array().unwrap().len(), 2);
    assert_eq!(updated_state["items"][1]["id"], json!("2"));
    assert_eq!(updated_state["items"][1]["name"], json!("Second Item"));
}

/// mirror.test.ts: "resource cleanup happens correctly"
#[test]
fn resource_cleanup_happens_correctly() {
    let doc = LoroDoc::new();
    let data_schema = Schema::root([(
        "data",
        Schema::map([
            ("key1", Schema::string()),
            ("key2", Schema::string()),
            ("key3", Schema::string()),
        ]),
    )]);

    let data_map = doc.get_map("data");
    data_map.insert("key1", "value1").unwrap();
    doc.commit();

    let mirror = Mirror::new(doc.clone(), Some(data_schema), MirrorOptions::default()).unwrap();

    let calls = Arc::new(Mutex::new(0usize));
    let calls_cb = calls.clone();
    let subscription = mirror.subscribe(Arc::new(move |_, _| {
        *calls_cb.lock().unwrap() += 1;
    }));

    // 订阅正常工作
    data_map.insert("key2", "value2").unwrap();
    doc.commit();
    assert!(*calls.lock().unwrap() > 0);

    // 重置计数
    *calls.lock().unwrap() = 0;

    // 蓝本 dispose():丢弃最后一个 Mirror 句柄即释放全部 doc 订阅
    drop(mirror);

    // 此后 doc 的变更不应再触发订阅者
    data_map.insert("key3", "value3").unwrap();
    doc.commit();
    assert_eq!(*calls.lock().unwrap(), 0);

    // dispose 之后退订仍应安全
    drop(subscription);
}

/// mirror.test.ts: "correctly initializes nested containers with schemas"
#[test]
fn correctly_initializes_nested_containers_with_schemas() {
    let doc = LoroDoc::new();
    let nested_schema = Schema::root([(
        "users",
        Schema::map([
            (
                "profile",
                Schema::map([
                    ("name", Schema::text()),
                    ("age", Schema::number()),
                    ("tags", Schema::list(Schema::string())),
                ]),
            ),
            (
                "posts",
                Schema::list(Schema::map([
                    ("title", Schema::string()),
                    ("content", Schema::string()),
                    (
                        "comments",
                        Schema::list(Schema::map([
                            ("author", Schema::string()),
                            ("text", Schema::text()),
                        ])),
                    ),
                ])),
            ),
        ]),
    )]);

    let mirror = Mirror::new(doc.clone(), Some(nested_schema), MirrorOptions::default()).unwrap();

    mirror
        .set_state_merge(&json!({"users": {
            "profile": {
                "name": "John",
                "age": 30,
                "tags": ["developer", "typescript"],
            },
            "posts": [
                {
                    "title": "First Post",
                    "content": "Hello World",
                    "comments": [
                        {"author": "Jane", "text": "Great post!"},
                        {"author": "Bob", "text": "Nice job!"},
                    ],
                },
            ],
        }}))
        .unwrap();

    let serialized = deep_value_with_id(&doc);

    let user_container = &serialized["users"];
    assert!(value_is_container_of_type(user_container, ":Map"));

    // profile 应是 LoroMap
    let profile_container = &user_container["value"]["profile"];
    assert!(value_is_container_of_type(profile_container, ":Map"));

    // profile 里的 name 应是 LoroText
    assert!(value_is_container_of_type(
        &profile_container["value"]["name"],
        ":Text"
    ));
    assert_eq!(profile_container["value"]["name"]["value"], json!("John"));

    // profile 里的 age 应是普通数值
    assert_eq!(profile_container["value"]["age"], json!(30));

    // profile 里的 tags 应是 LoroList
    let tags_list = &profile_container["value"]["tags"];
    assert!(value_is_container_of_type(tags_list, ":List"));
    assert_eq!(tags_list["value"], json!(["developer", "typescript"]));

    // posts 应是 LoroList
    let posts_container = &user_container["value"]["posts"];
    assert!(value_is_container_of_type(posts_container, ":List"));
    assert_eq!(posts_container["value"].as_array().unwrap().len(), 1);

    // 第一篇 post 应是 LoroMap
    let post_container = &posts_container["value"][0];
    assert!(value_is_container_of_type(post_container, ":Map"));
    assert_eq!(post_container["value"]["title"], json!("First Post"));
    assert_eq!(post_container["value"]["content"], json!("Hello World"));

    // comments 应是 LoroList
    let inner_comments_container = &post_container["value"]["comments"];
    assert!(value_is_container_of_type(
        inner_comments_container,
        ":List"
    ));
    assert_eq!(
        inner_comments_container["value"].as_array().unwrap().len(),
        2
    );

    // comment 应是 LoroMap
    let comment_container = &inner_comments_container["value"][0];
    assert!(value_is_container_of_type(comment_container, ":Map"));

    // comment 里的 author 应是普通字符串
    assert_eq!(comment_container["value"]["author"], json!("Jane"));

    // comment 里的 text 应是 LoroText
    let comment_text_container = &comment_container["value"]["text"];
    assert!(value_is_container_of_type(comment_text_container, ":Text"));
    assert_eq!(comment_text_container["value"], json!("Great post!"));
}

/// mirror.test.ts: "handles recursive schemas"
#[test]
fn handles_recursive_schemas() {
    // 蓝本靠对象引用赋值成环;这里用 SchemaSlot 的后填充槽闭环
    let children_schema = Arc::new(Schema::List {
        item: SchemaSlot::deferred(),
        id_selector: None,
        options: SchemaOptions::default(),
    });
    let node_schema = Schema::map([
        ("name", Schema::text()),
        ("children", children_schema.clone()),
    ]);
    let Schema::List { item, .. } = children_schema.as_ref() else {
        unreachable!()
    };
    item.fill(node_schema.clone());

    let recursive_schema = Schema::root([("root", node_schema)]);

    let loro_doc = LoroDoc::new();
    let mirror = Mirror::new(
        loro_doc.clone(),
        Some(recursive_schema),
        MirrorOptions::default(),
    )
    .unwrap();

    mirror
        .set_state_merge(&json!({"root": {
            "name": "Root",
            "children": [
                {
                    "name": "Child 1",
                    "children": [
                        {"name": "Grandchild 1", "children": []},
                        {"name": "Grandchild 2", "children": []},
                    ],
                },
                {"name": "Child 2", "children": []},
            ],
        }}))
        .unwrap();

    let serialized = deep_value_with_id(&loro_doc);

    assert!(value_is_container(&serialized["root"]));
    assert!(value_is_container_of_type(&serialized["root"], ":Map"));

    assert!(value_is_container(&serialized["root"]["value"]["name"]));
    assert!(value_is_container_of_type(
        &serialized["root"]["value"]["name"],
        ":Text"
    ));

    let children = &serialized["root"]["value"]["children"];
    assert!(value_is_container(children));
    assert!(value_is_container_of_type(children, ":List"));

    assert!(value_is_container(&children["value"][0]));
    assert!(value_is_container_of_type(&children["value"][0], ":Map"));

    let grandchildren = &children["value"][0]["value"]["children"];
    assert!(value_is_container(grandchildren));
    assert!(value_is_container_of_type(grandchildren, ":List"));

    assert!(value_is_container(&grandchildren["value"][0]));
    assert!(value_is_container_of_type(
        &grandchildren["value"][0],
        ":Map"
    ));

    assert!(value_is_container(
        &grandchildren["value"][0]["value"]["name"]
    ));
    assert!(value_is_container_of_type(
        &grandchildren["value"][0]["value"]["name"],
        ":Text"
    ));
}

/// mirror.test.ts: "subscribers get notified correct amounts for nested containers"
#[test]
fn subscribers_get_notified_correct_amounts_for_nested_containers() {
    let test_schema = Schema::root([(
        "root",
        Schema::map([("name", Schema::text()), ("type", Schema::text())]),
    )]);

    let loro_doc = LoroDoc::new();
    let mirror = Mirror::new(
        loro_doc.clone(),
        Some(test_schema),
        MirrorOptions {
            initial_state: Some(json!({"root": {"name": "Root", "type": "root"}})),
            ..MirrorOptions::default()
        },
    )
    .unwrap();

    let snapshot = loro_doc.export(loro::ExportMode::Snapshot).unwrap();

    // 另一个 doc 制造更新
    let doc2 = LoroDoc::new();
    doc2.import(&snapshot).unwrap();
    doc2.get_map("root").insert("name", "Root2").unwrap();

    let update = doc2.export(loro::ExportMode::all_updates()).unwrap();

    let counter = Arc::new(Mutex::new(0usize));
    let counter_cb = counter.clone();
    let _subscription = mirror.subscribe(Arc::new(move |_, _| {
        *counter_cb.lock().unwrap() += 1;
    }));

    loro_doc.import(&update).unwrap();

    // 这次 import 只应通知订阅者一次
    assert_eq!(*counter.lock().unwrap(), 1);
}

/// mirror.test.ts: "should respect the infer options that are passed to it"
#[test]
fn should_respect_the_infer_options_that_are_passed_to_it() {
    let some_state = json!({
        "list": [{}],
        "text": "some string",
    });

    let doc = LoroDoc::new();
    let mirror = Mirror::new(
        doc.clone(),
        None,
        MirrorOptions {
            infer_options: InferContainerOptions {
                default_loro_text: true,
                default_movable_list: true,
            },
            ..MirrorOptions::default()
        },
    )
    .unwrap();

    mirror.set_state_merge(&some_state).unwrap();

    let state = deep_value_with_id(&doc);
    assert!(value_is_container_of_type(&state["list"], "MovableList"));
    assert!(value_is_container_of_type(&state["text"], "Text"));
}
