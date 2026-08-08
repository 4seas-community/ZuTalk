//! 笔记块文档的端到端:开 → 编辑 → 关 → 重开,以及第 1 纪元迁移。
//!
//! 之前这条链只有 vt-ffi 库内单测(同一个进程、同一个 core、文档一直
//! 开着)。用户实际经历的是另一条:写完关掉 App,明天再打开。落盘与
//! 重开之间的每一步都得自己站得住。
//!
//! 撤销栈刻意**不**跨重开存活(会话状态),这里把这条约定钉死 —— 免得
//! 将来有人「顺手」持久化它,把别人昨天的编辑撤没了。

use std::path::PathBuf;
use tempfile::TempDir;
use vt_ffi::block_document_api::{FfiDocumentKind, FfiOutlineKind, FfiOutlineRow};
use vt_ffi::ZulangueCore;

fn make_core(dir: &TempDir) -> ZulangueCore {
    ZulangueCore::new_for_test(dir.path().to_str().unwrap().to_string()).unwrap()
}

fn row(id: &str, depth: u32, text: &str, kind: FfiOutlineKind) -> FfiOutlineRow {
    FfiOutlineRow {
        id: id.into(),
        depth,
        text: text.into(),
        kind,
        checked: false,
    }
}

/// 建一个 Notebook,返回它的笔记 tab id。
fn note_tab(core: &ZulangueCore) -> (String, String) {
    let notebook = core.create_notebook(Some("笔记".into())).unwrap();
    let tabs = core.list_notebook_tabs(notebook.id.clone()).unwrap();
    let tab = tabs
        .into_iter()
        .find(|t| t.builtin_kind == "manual_note")
        .expect("每个 Notebook 都有笔记 tab");
    (notebook.id, tab.id)
}

#[test]
fn an_outline_survives_closing_the_document_and_reopening_it() {
    let dir = TempDir::new().unwrap();
    let core = make_core(&dir);
    let (notebook, tab) = note_tab(&core);

    let doc_id = core
        .note_block_document_open(notebook.clone(), tab.clone())
        .unwrap();
    core.note_apply_outline(
        doc_id.clone(),
        vec![
            row("h", 0, "会议纪要", FfiOutlineKind::Heading1),
            row("a", 0, "第一件事", FfiOutlineKind::Paragraph),
            row("a1", 1, "细节", FfiOutlineKind::Paragraph),
            FfiOutlineRow {
                checked: true,
                ..row("t", 0, "已办", FfiOutlineKind::Task)
            },
        ],
    )
    .unwrap();
    core.block_document_close(doc_id.clone()).unwrap();

    // 同一个 core 里重开:落盘 → 读回。
    let reopened = core.note_block_document_open(notebook, tab).unwrap();
    assert_eq!(reopened, doc_id, "同一个 tab 永远对应同一份文档");
    let rows = core.note_outline_rows(doc_id).unwrap();
    assert_eq!(
        rows.iter().map(|r| r.text.clone()).collect::<Vec<_>>(),
        vec!["会议纪要", "第一件事", "细节", "已办"]
    );
    assert_eq!(
        rows.iter().map(|r| r.depth).collect::<Vec<_>>(),
        vec![0, 0, 1, 0]
    );
    assert_eq!(rows[0].kind, FfiOutlineKind::Heading1, "块类型要跟着落盘");
    assert_eq!(rows[3].kind, FfiOutlineKind::Task);
    assert!(rows[3].checked, "勾选态同样是文档的一部分");
}

#[test]
fn an_outline_survives_a_whole_app_restart() {
    // 关掉 App 再打开:新的 Core、新的注册表,只有磁盘是共同点。
    let dir = TempDir::new().unwrap();
    let (notebook, tab, doc_id) = {
        let core = make_core(&dir);
        let (notebook, tab) = note_tab(&core);
        let doc_id = core
            .note_block_document_open(notebook.clone(), tab.clone())
            .unwrap();
        core.note_apply_outline(
            doc_id.clone(),
            vec![row("a", 0, "昨天写的", FfiOutlineKind::Quote)],
        )
        .unwrap();
        // 刻意不 close:模拟直接退出 App。
        (notebook, tab, doc_id)
    };

    let reborn = make_core(&dir);
    let reopened = reborn.note_block_document_open(notebook, tab).unwrap();
    assert_eq!(reopened, doc_id);
    let rows = reborn.note_outline_rows(doc_id).unwrap();
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].text, "昨天写的");
    assert_eq!(rows[0].kind, FfiOutlineKind::Quote);
}

#[test]
fn the_undo_stack_does_not_reach_across_a_restart() {
    let dir = TempDir::new().unwrap();
    let (notebook, tab) = {
        let core = make_core(&dir);
        let (notebook, tab) = note_tab(&core);
        let doc_id = core
            .note_block_document_open(notebook.clone(), tab.clone())
            .unwrap();
        core.note_apply_outline(
            doc_id.clone(),
            vec![row("a", 0, "第一版", FfiOutlineKind::Paragraph)],
        )
        .unwrap();
        core.note_apply_outline(
            doc_id.clone(),
            vec![row("a", 0, "第二版", FfiOutlineKind::Paragraph)],
        )
        .unwrap();
        assert!(
            core.note_undo_state(doc_id.clone()).unwrap().can_undo,
            "同一会话里当然撤得动"
        );
        (notebook, tab)
    };

    let reborn = make_core(&dir);
    let doc_id = reborn.note_block_document_open(notebook, tab).unwrap();
    let state = reborn.note_undo_state(doc_id.clone()).unwrap();
    assert!(
        !state.can_undo && !state.can_redo,
        "重开之后撤销栈从空开始 —— 昨天的编辑不该被今天的 ⌘Z 撤掉"
    );
    let attempted = reborn.note_undo(doc_id.clone()).unwrap();
    assert!(!attempted.performed, "空栈上的撤销是 no-op,不是错误");
    assert_eq!(
        reborn.note_outline_rows(doc_id).unwrap()[0].text,
        "第二版",
        "no-op 的撤销不许动内容"
    );
}

#[test]
fn undo_and_redo_walk_the_outline_back_and_forward() {
    let dir = TempDir::new().unwrap();
    let core = make_core(&dir);
    let (notebook, tab) = note_tab(&core);
    let doc_id = core.note_block_document_open(notebook, tab).unwrap();

    core.note_apply_outline(
        doc_id.clone(),
        vec![row("a", 0, "一", FfiOutlineKind::Paragraph)],
    )
    .unwrap();
    core.note_apply_outline(
        doc_id.clone(),
        vec![
            row("a", 0, "一", FfiOutlineKind::Paragraph),
            row("b", 0, "二", FfiOutlineKind::Paragraph),
        ],
    )
    .unwrap();

    let undone = core.note_undo(doc_id.clone()).unwrap();
    assert!(undone.performed);
    assert_eq!(
        core.note_outline_rows(doc_id.clone())
            .unwrap()
            .iter()
            .map(|r| r.text.clone())
            .collect::<Vec<_>>(),
        vec!["一"],
        "撤销回到只有一行"
    );

    let redone = core.note_redo(doc_id.clone()).unwrap();
    assert!(redone.performed);
    assert_eq!(
        core.note_outline_rows(doc_id)
            .unwrap()
            .iter()
            .map(|r| r.text.clone())
            .collect::<Vec<_>>(),
        vec!["一", "二"],
        "重做把第二行放回来"
    );
}

#[test]
fn a_first_epoch_note_is_migrated_line_by_line_and_the_old_file_is_archived() {
    let dir = TempDir::new().unwrap();
    let core = make_core(&dir);
    let (notebook, tab) = note_tab(&core);

    // 用第 1 纪元的编辑器写一份平文本笔记,并落盘。
    core.open_editor(notebook.clone(), tab.clone()).unwrap();
    core.apply_edit(
        notebook.clone(),
        tab.clone(),
        vt_ffi::editor_api::FfiEditOp::Insert {
            pos: 0,
            text: "第一行\n第二行\n\n第四行".into(),
        },
    )
    .unwrap();
    // close_editor 会把快照同步落盘 —— 后台 flusher 是 500ms 合并写,
    // 测试不等它。
    core.close_editor(notebook.clone(), tab.clone()).unwrap();

    let legacy_files: Vec<PathBuf> = std::fs::read_dir(dir.path().join("editor-docs"))
        .unwrap()
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.extension().is_some_and(|ext| ext == "loro"))
        .collect();
    assert_eq!(legacy_files.len(), 1, "应当只有一份第 1 纪元快照");
    let legacy = legacy_files[0].clone();

    // 现在按块文档打开:迁移就在这一步发生。
    let doc_id = core.note_block_document_open(notebook, tab).unwrap();
    let rows = core.note_outline_rows(doc_id).unwrap();
    assert_eq!(
        rows.iter().map(|r| r.text.clone()).collect::<Vec<_>>(),
        vec!["第一行", "第二行", "", "第四行"],
        "逐行成行,空行保留 —— 内容要逐字节可还原"
    );
    assert!(
        rows.iter().all(|r| r.depth == 0),
        "平文本没有层级,迁移不许凭空造出缩进"
    );
    assert!(
        rows.iter().all(|r| r.kind == FfiOutlineKind::Paragraph),
        "平文本也没有块类型"
    );

    assert!(!legacy.exists(), "迁移后旧快照要改名让路");
    assert!(
        legacy.with_extension("loro.pre-epoch2").exists(),
        "但必须留档,不能直接删 —— 迁移出错时这是唯一的退路"
    );
}

#[test]
fn a_note_document_refuses_to_be_reopened_as_a_transcript() {
    let dir = TempDir::new().unwrap();
    let core = make_core(&dir);
    let (notebook, tab) = note_tab(&core);
    let doc_id = core.note_block_document_open(notebook, tab).unwrap();

    assert!(
        core.block_document_open(doc_id.clone(), FfiDocumentKind::Transcript)
            .is_err(),
        "同一份文档换个 kind 打开必须大声拒绝,不能悄悄按另一套规则手册办事"
    );
    // 拒绝之后原句柄还得好好的。
    assert!(core.note_outline_rows(doc_id).is_ok());
}

#[test]
fn a_document_id_cannot_walk_out_of_its_directory() {
    let dir = TempDir::new().unwrap();
    let core = make_core(&dir);
    for evil in ["../escape", "a/b", "..", "with.dot", ""] {
        assert!(
            core.block_document_open(evil.into(), FfiDocumentKind::Note)
                .is_err(),
            "非法 doc_id {evil:?} 必须拒绝 —— doc_id 会进文件名"
        );
    }
}

#[test]
fn the_note_channel_refuses_transcript_tabs() {
    let dir = TempDir::new().unwrap();
    let core = make_core(&dir);
    let notebook = core.create_notebook(Some("笔记".into())).unwrap();
    let tabs = core.list_notebook_tabs(notebook.id.clone()).unwrap();
    for tab in tabs.into_iter().filter(|t| t.builtin_kind != "manual_note") {
        assert!(
            core.note_block_document_open(notebook.id.clone(), tab.id)
                .is_err(),
            "转录稿是证据,不许从笔记这条宽松通道迁移"
        );
    }
}
