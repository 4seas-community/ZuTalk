//! 上下文包的端到端:私有包的归属、Library 包的绑定、导入导出往返。
//!
//! 这一族有十几个动词,之前集成测试一个都没有。它值得守的不只是功能:
//! 包里放的是会被送进 provider 提示词的材料,**谁能读谁的包**是一条
//! 安全边界(`require_context_pack_access`);而导出会把包写成明文 JSON
//! ——它离开了加密边界,所以只该在用户明确导出时发生,且导入回来必须
//! 是一份新身份、新密钥的副本,而不是原件复活。

use std::path::PathBuf;
use tempfile::TempDir;
use vt_ffi::ZulangueCore;

fn make_core(dir: &TempDir) -> ZulangueCore {
    ZulangueCore::new_for_test(dir.path().to_str().unwrap().to_string()).unwrap()
}

fn notebook(core: &ZulangueCore, title: &str) -> String {
    core.create_notebook(Some(title.to_string())).unwrap().id
}

/// 这个 Notebook 的私有包。
fn private_pack(
    core: &ZulangueCore,
    notebook_id: &str,
) -> vt_ffi::notebook_capture_api::FfiContextPackInfo {
    core.list_notebook_context_packs(notebook_id.to_string())
        .unwrap()
        .into_iter()
        .find(|pack| pack.scope == "private")
        .expect("每个 Notebook 都有一个私有包")
}

#[test]
fn every_notebook_starts_with_exactly_one_private_pack() {
    let dir = TempDir::new().unwrap();
    let core = make_core(&dir);
    let nb = notebook(&core, "私有包");

    let packs = core.list_notebook_context_packs(nb.clone()).unwrap();
    let private: Vec<_> = packs.iter().filter(|p| p.scope == "private").collect();
    assert_eq!(private.len(), 1, "私有包不多不少一个");
    assert_eq!(private[0].owner_notebook_id.as_deref(), Some(nb.as_str()));
    assert!(
        private[0].bound_position.is_none(),
        "私有包不需要绑定 —— 它本来就属于这个 Notebook"
    );

    // 幂等:再列一次不该又造一个。
    let again = private_pack(&core, &nb);
    assert_eq!(again.id, private[0].id);
}

#[test]
fn a_notebook_cannot_reach_into_another_notebooks_private_pack() {
    // 包里放的是会被送进 provider 提示词的材料。两个 Notebook 之间的
    // 隔离不是整洁问题,是「A 会议的机密不许出现在 B 会议的提示词里」。
    let dir = TempDir::new().unwrap();
    let core = make_core(&dir);
    let mine = notebook(&core, "我的");
    let theirs = notebook(&core, "别人的");
    let their_pack = private_pack(&core, &theirs).id;

    assert!(
        core.list_context_pack_sources(mine.clone(), their_pack.clone())
            .is_err(),
        "读不到别人的私有包"
    );
    assert!(
        core.import_context_pack_text(
            mine.clone(),
            their_pack.clone(),
            "偷渡".into(),
            "机密".into(),
            "text".into(),
        )
        .is_err(),
        "更不许往别人的私有包里塞东西"
    );
    let out = dir.path().join("stolen.json");
    assert!(
        core.export_context_pack(mine, their_pack, out.to_string_lossy().into_owned())
            .is_err(),
        "也不许把别人的私有包导出成明文"
    );
    assert!(!out.exists(), "被拒绝的导出不许在磁盘上留下文件");
}

#[test]
fn text_sources_land_in_the_pack_and_can_be_removed() {
    let dir = TempDir::new().unwrap();
    let core = make_core(&dir);
    let nb = notebook(&core, "材料");
    let pack = private_pack(&core, &nb).id;

    let source = core
        .import_context_pack_text(
            nb.clone(),
            pack.clone(),
            "议程".into(),
            "第一项:预算".into(),
            "text".into(),
        )
        .unwrap();
    assert_eq!(source.pack_id, pack);
    assert!(source.plaintext_bytes > 0);
    assert!(
        !source.plaintext_sha256.is_empty(),
        "内容摘要要有 —— 上下文回执靠它说明白送了什么进去"
    );

    let listed = core
        .list_context_pack_sources(nb.clone(), pack.clone())
        .unwrap();
    assert_eq!(listed.len(), 1);
    assert_eq!(listed[0].id, source.id);

    assert!(core
        .delete_context_pack_source(nb.clone(), source.id.clone())
        .unwrap());
    assert!(core
        .list_context_pack_sources(nb.clone(), pack)
        .unwrap()
        .is_empty());
    // 删第二次:不许再报一次「删掉了」—— 要么说不存在,要么如实说
    // 什么都没删。
    if let Ok(deleted) = core.delete_context_pack_source(nb, source.id) {
        assert!(!deleted, "第二次删除不该再声称删掉了什么");
    }
}

#[test]
fn bilingual_terms_refuse_to_arrive_as_plain_text() {
    // 术语表要成对的两列,从一段纯文本里猜不出来。宁可拒绝。
    let dir = TempDir::new().unwrap();
    let core = make_core(&dir);
    let nb = notebook(&core, "术语");
    let pack = private_pack(&core, &nb).id;

    assert!(core
        .import_context_pack_text(
            nb.clone(),
            pack.clone(),
            "术语".into(),
            "foo=bar".into(),
            "translation_terms".into(),
        )
        .is_err());
    // 不认识的种类同样拒绝,不静默当成 reference。
    assert!(core
        .import_context_pack_text(nb, pack, "未知".into(), "x".into(), "hologram".into(),)
        .is_err());
}

#[test]
fn a_library_pack_binds_to_a_notebook_and_unbinds_again() {
    let dir = TempDir::new().unwrap();
    let core = make_core(&dir);
    let nb = notebook(&core, "绑定");
    let library = core.create_library_context_pack("公司术语".into()).unwrap();
    assert_eq!(library.scope, "library");
    assert!(library.owner_notebook_id.is_none(), "Library 包不属于谁");

    // 建出来还没绑:列表里有它,但没有位置。
    let listed = core.list_notebook_context_packs(nb.clone()).unwrap();
    let found = listed.iter().find(|p| p.id == library.id).unwrap();
    assert!(found.bound_position.is_none());

    core.set_notebook_context_pack_binding(nb.clone(), library.id.clone(), Some(0))
        .unwrap();
    let bound = core
        .list_notebook_context_packs(nb.clone())
        .unwrap()
        .into_iter()
        .find(|p| p.id == library.id)
        .unwrap();
    assert_eq!(bound.bound_position, Some(0), "绑上之后要有位置");

    core.set_notebook_context_pack_binding(nb.clone(), library.id.clone(), None)
        .unwrap();
    let unbound = core
        .list_notebook_context_packs(nb)
        .unwrap()
        .into_iter()
        .find(|p| p.id == library.id)
        .unwrap();
    assert!(unbound.bound_position.is_none(), "解绑之后位置要清掉");
    assert_eq!(
        core.list_library_context_packs().unwrap().len(),
        1,
        "解绑不是删除 —— 包还在 Library 里"
    );
}

#[test]
fn a_pack_survives_a_round_trip_through_a_file_as_a_new_copy() {
    let dir = TempDir::new().unwrap();
    let core = make_core(&dir);
    let nb = notebook(&core, "往返");
    let pack = private_pack(&core, &nb).id;
    core.import_context_pack_text(
        nb.clone(),
        pack.clone(),
        "议程".into(),
        "第一项:预算".into(),
        "text".into(),
    )
    .unwrap();

    let file = dir.path().join("pack.json");
    let exported = core
        .export_context_pack(
            nb.clone(),
            pack.clone(),
            file.to_string_lossy().into_owned(),
        )
        .unwrap();
    assert_eq!(exported, 1, "导出报告的条目数要对");
    assert!(file.exists());

    let imported = core
        .import_context_pack(file.to_string_lossy().into_owned(), Some("导回来".into()))
        .unwrap();
    assert_ne!(imported.id, pack, "导入是一份新身份的副本,不是原件复活");
    assert_eq!(
        imported.scope, "library",
        "导入的落在 Library,不认原来的归属"
    );
    assert_eq!(imported.title, "导回来");

    // 内容跟着回来了。
    let sources = core
        .list_context_pack_sources(nb, imported.id.clone())
        .unwrap();
    assert_eq!(sources.len(), 1);
    assert_eq!(sources[0].title, "议程");
    assert_ne!(
        sources[0].pack_id, pack,
        "副本里的源属于副本,不该还指着原包"
    );
}

#[test]
fn importing_something_that_is_not_a_pack_is_refused_politely() {
    let dir = TempDir::new().unwrap();
    let core = make_core(&dir);

    let junk = dir.path().join("not-a-pack.json");
    std::fs::write(&junk, b"{\"hello\":\"world\"}").unwrap();
    assert!(
        core.import_context_pack(junk.to_string_lossy().into_owned(), None)
            .is_err(),
        "长得像 JSON 不代表是 Pack 文件"
    );

    let garbage = dir.path().join("garbage.bin");
    std::fs::write(&garbage, [0xff_u8; 64]).unwrap();
    assert!(core
        .import_context_pack(garbage.to_string_lossy().into_owned(), None)
        .is_err());

    let missing = dir.path().join("nope.json");
    assert!(core
        .import_context_pack(missing.to_string_lossy().into_owned(), None)
        .is_err());

    // 目录不是文件。
    assert!(core
        .import_context_pack(dir.path().to_string_lossy().into_owned(), None)
        .is_err());

    assert!(
        core.list_library_context_packs().unwrap().is_empty(),
        "每一次失败的导入都不许留下半个包"
    );
}

#[test]
fn editing_a_library_pack_needs_the_revision_you_read() {
    // 两个窗口同时编辑同一个包,后写的不许悄悄盖掉先写的。
    let dir = TempDir::new().unwrap();
    let core = make_core(&dir);
    let pack = core.create_library_context_pack("术语".into()).unwrap();

    let document = core.read_library_context_pack(pack.id.clone()).unwrap();
    let updated = core
        .replace_library_context_pack(pack.id.clone(), pack.revision, document.clone())
        .unwrap();
    assert!(updated.revision > pack.revision, "写一次,版本要往前走");

    assert!(
        core.replace_library_context_pack(pack.id.clone(), pack.revision, document)
            .is_err(),
        "拿旧版本号再写一次必须被挡下"
    );
    assert!(
        core.delete_library_context_pack(pack.id.clone(), pack.revision)
            .is_err(),
        "删除同样要拿着当前版本号"
    );
    assert!(core
        .delete_library_context_pack(pack.id, updated.revision)
        .unwrap());
    assert!(core.list_library_context_packs().unwrap().is_empty());
}

#[test]
fn copying_the_private_pack_to_the_library_leaves_the_original_alone() {
    let dir = TempDir::new().unwrap();
    let core = make_core(&dir);
    let nb = notebook(&core, "复制");
    let private = private_pack(&core, &nb).id;
    core.import_context_pack_text(
        nb.clone(),
        private.clone(),
        "议程".into(),
        "第一项".into(),
        "text".into(),
    )
    .unwrap();

    let copy = core
        .copy_notebook_private_context_to_library(nb.clone(), "共享议程".into())
        .unwrap();
    assert_ne!(copy.id, private);
    assert_eq!(copy.scope, "library");
    assert_eq!(
        core.list_context_pack_sources(nb.clone(), copy.id)
            .unwrap()
            .len(),
        1,
        "复制要连内容一起"
    );
    assert_eq!(
        core.list_context_pack_sources(nb, private).unwrap().len(),
        1,
        "原来的私有包不受影响"
    );
}

#[test]
fn an_exported_pack_file_is_plaintext_and_only_appears_where_asked() {
    // 导出是唯一一条把包写成明文的路。写出来的必须正是用户点的那个
    // 位置,内容必须是能被另一台机器读懂的 JSON —— 否则「导出」是假的。
    let dir = TempDir::new().unwrap();
    let core = make_core(&dir);
    let nb = notebook(&core, "明文");
    let pack = private_pack(&core, &nb).id;
    core.import_context_pack_text(
        nb.clone(),
        pack.clone(),
        "议程".into(),
        "可辨认的原文".into(),
        "text".into(),
    )
    .unwrap();

    let file: PathBuf = dir.path().join("nested").join("pack.json");
    assert!(
        core.export_context_pack(
            nb.clone(),
            pack.clone(),
            file.to_string_lossy().into_owned()
        )
        .is_err(),
        "父目录不存在时要报错,而不是把文件丢到别处"
    );

    let file = dir.path().join("pack.json");
    core.export_context_pack(nb, pack, file.to_string_lossy().into_owned())
        .unwrap();
    let raw = std::fs::read_to_string(&file).unwrap();
    assert!(
        raw.contains("可辨认的原文"),
        "导出的是明文 —— 这正是它只该在用户明确导出时发生的原因"
    );
    serde_json::from_str::<serde_json::Value>(&raw).expect("导出的必须是合法 JSON");
}

#[test]
fn the_library_verbs_refuse_to_operate_on_a_private_pack() {
    // Library 那几个动词不收 notebook_id,所以它们绕过了
    // `require_context_pack_access`。要是它们肯对一个私有包 id 动手,
    // 「A 的私有包 B 读不到」这条边界就有一扇后门 —— 把 id 换个动词
    // 递进去就行了。
    let dir = TempDir::new().unwrap();
    let core = make_core(&dir);
    let theirs = notebook(&core, "别人的");
    let their_private = private_pack(&core, &theirs);
    core.import_context_pack_text(
        theirs.clone(),
        their_private.id.clone(),
        "机密议程".into(),
        "只有他们该看见的字".into(),
        "text".into(),
    )
    .unwrap();

    let read = core.read_library_context_pack(their_private.id.clone());
    if let Ok(document) = &read {
        assert!(
            !document.contains("只有他们该看见的字"),
            "私有包的内容从 Library 动词漏出来了"
        );
    }
    assert!(read.is_err(), "Library 的读取动词不该认一个私有包 id");

    assert!(
        core.replace_library_context_pack(
            their_private.id.clone(),
            their_private.revision,
            "{\"title\":\"改掉\",\"sources\":[]}".into(),
        )
        .is_err(),
        "更不该让人从这条路改写别人的私有包"
    );
    assert!(
        core.delete_library_context_pack(their_private.id.clone(), their_private.revision)
            .is_err(),
        "也不该从这条路删掉别人的私有包"
    );

    // 边界之后,原包必须完好。
    let still_there = core
        .list_context_pack_sources(theirs, their_private.id)
        .unwrap();
    assert_eq!(still_there.len(), 1, "被拒绝的操作不许留下任何痕迹");
    assert_eq!(still_there[0].title, "机密议程");
}
