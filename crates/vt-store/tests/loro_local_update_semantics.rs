//! 出站钩子的前提:`subscribe_local_update` 会不会被 `import` 触发?
//!
//! 会的话,收到别人的改动就会把它再播回去 —— 两台机器互相回声,永不停歇。
//! 整个文档同步的出站设计都压在这一条上,所以实测而不是读文档。

use loro::LoroDoc;
use std::sync::{Arc, Mutex};

#[test]
fn importing_a_remote_update_does_not_fire_the_local_hook() {
    let local = LoroDoc::new();
    let fired: Arc<Mutex<Vec<Vec<u8>>>> = Arc::new(Mutex::new(Vec::new()));
    let sink = fired.clone();
    let _sub = local.subscribe_local_update(Box::new(move |bytes| {
        sink.lock().unwrap().push(bytes.to_vec());
        true
    }));

    // 本地编辑:钩子应当响。
    local.get_text("content").insert(0, "本地写的").unwrap();
    local.commit();
    let after_local = fired.lock().unwrap().len();
    assert!(after_local > 0, "本地编辑必须触发钩子,否则改动发不出去");

    // 远端的一份更新合进来:钩子**不该**响。
    let remote = LoroDoc::new();
    remote.get_text("content").insert(0, "远端写的").unwrap();
    remote.commit();
    let update = remote.export(loro::ExportMode::all_updates()).unwrap();
    local.import(&update).unwrap();
    local.commit();

    assert_eq!(
        fired.lock().unwrap().len(),
        after_local,
        "合入远端更新触发了本地钩子 —— 出站会把它播回去,形成回声风暴"
    );
}
