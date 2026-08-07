//! 照译蓝本 `tests/core/mirror-tags.test.ts`,唯一用例移植。
//!
//! 蓝本 `mirror.setState(obj, {tags})` 的对象形态是根级浅合并,这里用
//! `set_state` 的 updater 形态复刻同一合并;`dispose()` 对应 Rust 里
//! 丢弃 Mirror 句柄,测试结束自然发生。

use std::sync::{Arc, Mutex};

use loro::LoroDoc;
use serde_json::json;
use vt_mirror::mirror::{Mirror, MirrorOptions, SetStateOptions, SyncDirection, UpdateMetadata};
use vt_mirror::schema::Schema;

/// mirror-tags.test.ts: "should propogate tags to mirror.subscription"
#[test]
fn should_propagate_tags_to_mirror_subscription() {
    let doc = LoroDoc::new();
    let user_schema = Schema::root([("user", Schema::map([("name", Schema::string())]))]);

    let mirror = Mirror::new(
        doc,
        Some(user_schema),
        MirrorOptions {
            initial_state: Some(json!({"user": {"name": "Initial"}})),
            ..MirrorOptions::default()
        },
    )
    .unwrap();

    let captured: Arc<Mutex<Option<UpdateMetadata>>> = Arc::new(Mutex::new(None));
    let captured_in_callback = captured.clone();
    let _subscription = mirror.subscribe(Arc::new(move |_, metadata| {
        *captured_in_callback.lock().unwrap() = Some(metadata.clone());
    }));

    mirror
        .set_state(
            |state| {
                // 蓝本对象形态的 {...state, ...partial} 浅合并
                let mut next = state.clone();
                next["user"] = json!({"name": "Updated"});
                next
            },
            SetStateOptions {
                tags: Some(vec!["test-tag".to_string(), "important".to_string()]),
            },
        )
        .unwrap();

    let captured = captured.lock().unwrap();
    let metadata = captured.as_ref().expect("应捕获到 metadata");
    assert_eq!(metadata.direction, SyncDirection::ToLoro);
    assert_eq!(
        metadata.tags,
        Some(vec!["test-tag".to_string(), "important".to_string()])
    );
}
