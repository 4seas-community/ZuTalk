//! vt-store Loro snapshot import fuzz.
//!
//! 任意字节作为 Loro snapshot 导入都不能 panic — 防御损坏的 .db BLOB。

#![no_main]
use libfuzzer_sys::fuzz_target;
use vt_store::EditorBridge;

fuzz_target!(|data: &[u8]| {
    // 1. 直接喂给 EditorBridge.replace_document
    let bridge = EditorBridge::new();
    let _ = bridge.replace_document("fuzz", data);

    // 2. 直接试 LoroDoc::import (绕过 EditorBridge)
    let doc = loro::LoroDoc::new();
    let _ = doc.import(data);
});
