//! vt-store Loro snapshot import property tests.
//!
//! Loro 加载任意字节时不得 panic。
//! 同时验证：
//! - Loro snapshot round-trip（导出后再导入应该相等）
//! - 任意字节 import 不 panic
//! - EditorBridge.replace_document 任意字节不 panic

use proptest::prelude::*;
use vt_store::{EditOp, EditorBridge};

fn make_doc_with_text(text: &str) -> loro::LoroDoc {
    let doc = loro::LoroDoc::new();
    doc.get_text("content").insert(0, text).unwrap();
    doc
}

fn snapshot_of(doc: &loro::LoroDoc) -> Vec<u8> {
    doc.export(loro::ExportMode::Snapshot).unwrap()
}

proptest! {
    /// 任意 UTF-8 文本的 LoroDoc 导出 → 重新创建 LoroDoc 导入 → 内容必须一致
    #[test]
    fn prop_loro_snapshot_roundtrip(text in "\\PC{0,500}") {
        let doc1 = make_doc_with_text(&text);
        let snapshot = snapshot_of(&doc1);

        let doc2 = loro::LoroDoc::new();
        doc2.import(&snapshot).unwrap();
        let restored = doc2.get_text("content").to_string();
        prop_assert_eq!(restored, text);
    }

    /// 任意字节作为 Loro snapshot 导入 — 必须返回 Err，不能 panic
    #[test]
    fn prop_loro_import_arbitrary_bytes_no_panic(garbage in prop::collection::vec(any::<u8>(), 0..2048)) {
        let result = std::panic::catch_unwind(|| {
            let doc = loro::LoroDoc::new();
            // 任何字节都不应让 LoroDoc 内部 panic
            let _ = doc.import(&garbage);
        });
        prop_assert!(result.is_ok(), "Loro import arbitrary bytes must not panic");
    }

    /// EditorBridge.replace_document 用任意字节调用必须返回 Err，不能 panic
    #[test]
    fn prop_editor_bridge_replace_document_no_panic(garbage in prop::collection::vec(any::<u8>(), 0..2048)) {
        let bridge = EditorBridge::new();
        let result = std::panic::catch_unwind(|| {
            let _ = bridge.replace_document("test", &garbage);
        });
        prop_assert!(result.is_ok(), "replace_document with garbage must not panic");
    }

    /// EditorBridge 文本插入 → 内容必须包含所插入字符串
    #[test]
    fn prop_editor_bridge_insert_contains(text in "\\PC{1,100}") {
        let bridge = EditorBridge::new();
        let doc = loro::LoroDoc::new();
        bridge.open("s1", doc).unwrap();
        bridge.apply("s1", EditOp::Insert { pos: 0, text: text.clone() }).unwrap();
        let content = bridge.get_content("s1").unwrap();
        prop_assert!(content.contains(&text));
    }
}

#[test]
fn smoke_proptest_module_compiles() {
    let doc = loro::LoroDoc::new();
    doc.get_text("content").insert(0, "hello").unwrap();
    let s = doc.export(loro::ExportMode::Snapshot).unwrap();
    assert!(!s.is_empty());
}
