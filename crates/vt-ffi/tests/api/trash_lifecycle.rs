//! 回收站生命周期的端到端:软删 → 列表消失 → 恢复 / 彻底删除。
//!
//! 这条链是数据丢失风险最高的一条:删错了要能回来,删干净了要真的不
//! 剩什么。TrashPage 的每个按钮都落在这里的一个动词上,而在此之前它们
//! 一个集成测试都没有 —— 只有 store 层各自的单测。
//!
//! 「删干净」的判据不是「列表里看不见」,而是逐个仓储追问:加密音频
//! 文件、密钥、session 行、全文索引,一个都不许留(录音带情绪,留一份
//! 影子比不删更糟)。

use std::path::PathBuf;
use tempfile::TempDir;
use vt_ffi::ZulangueCore;

fn fixture_wav() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../vt-audio/tests/fixtures/test_16k_mono.wav")
}

fn make_core() -> (TempDir, ZulangueCore) {
    let tmp = TempDir::new().unwrap();
    let core = ZulangueCore::new_for_test(tmp.path().to_str().unwrap().to_string()).unwrap();
    (tmp, core)
}

fn import_one(core: &ZulangueCore, title: &str) -> String {
    let notebook = core.create_notebook(Some(title.to_string())).unwrap();
    core.import_audio_into_notebook(fixture_wav().to_str().unwrap().to_string(), notebook.id)
        .unwrap()
        .session_id
}

fn active_ids(core: &ZulangueCore) -> Vec<String> {
    core.query_sessions(None, None, None, Some(100), None)
        .unwrap()
        .sessions
        .into_iter()
        .map(|s| s.id)
        .collect()
}

fn trashed_ids(core: &ZulangueCore) -> Vec<String> {
    core.list_trashed_sessions()
        .unwrap()
        .into_iter()
        .map(|s| s.id)
        .collect()
}

#[test]
fn a_session_moves_to_the_trash_and_comes_back_intact() {
    let (_tmp, core) = make_core();
    let session = import_one(&core, "回收站");

    assert_eq!(active_ids(&core), vec![session.clone()]);
    assert!(trashed_ids(&core).is_empty());

    core.soft_delete_session(session.clone()).unwrap();
    assert!(active_ids(&core).is_empty(), "软删之后 Home 列表不得再显示");
    assert_eq!(trashed_ids(&core), vec![session.clone()]);
    assert!(
        core.get_session(session.clone()).unwrap().is_trashed,
        "get_session 无视垃圾箱(撤销路径要读得到),但要如实说它在垃圾箱里"
    );

    // 回收站里的东西只是挪了位置,不是删了:音频与密钥必须原封不动。
    let info = core.get_session(session.clone()).unwrap();
    assert!(info.has_encrypted_audio, "软删不得动音频");

    core.restore_session(session.clone()).unwrap();
    assert_eq!(active_ids(&core), vec![session.clone()]);
    assert!(trashed_ids(&core).is_empty());
    assert!(!core.get_session(session).unwrap().is_trashed);
}

#[test]
fn deleting_and_restoring_twice_is_idempotent() {
    let (_tmp, core) = make_core();
    let session = import_one(&core, "幂等");

    core.soft_delete_session(session.clone()).unwrap();
    core.soft_delete_session(session.clone())
        .expect("重复软删是 no-op,不是错误");
    assert_eq!(trashed_ids(&core), vec![session.clone()]);

    core.restore_session(session.clone()).unwrap();
    core.restore_session(session.clone())
        .expect("重复恢复同样是 no-op");
    assert_eq!(active_ids(&core), vec![session]);

    // 不存在的 id 要说不存在,不能装作删掉了。
    assert!(core.soft_delete_session("no-such-session".into()).is_err());
    assert!(core.restore_session("no-such-session".into()).is_err());
}

#[test]
fn batch_delete_takes_the_ones_it_can_and_reports_success() {
    let (_tmp, core) = make_core();
    let a = import_one(&core, "批量 A");
    let b = import_one(&core, "批量 B");

    core.soft_delete_sessions(vec![a.clone(), b.clone(), "ghost".into()])
        .expect("批量软删对不存在的 id 幂等");
    let mut trashed = trashed_ids(&core);
    trashed.sort();
    let mut expected = vec![a, b];
    expected.sort();
    assert_eq!(trashed, expected);
    assert!(active_ids(&core).is_empty());
}

#[test]
fn deleting_forever_leaves_nothing_behind() {
    let (_tmp, core) = make_core();
    let session = import_one(&core, "彻底删除");

    // 删之前先把「留了什么」记下来 —— 判据是这些东西真的没了,
    // 而不是列表里看不见。
    let chunks = core
        .session_meta_for_test()
        .list_audio_retention_chunks(&session)
        .unwrap();
    assert!(!chunks.is_empty(), "导入的 session 应当有加密音频块");
    let chunk_paths: Vec<PathBuf> = chunks
        .iter()
        .map(|c| PathBuf::from(c.local_path.clone()))
        .collect();
    for path in &chunk_paths {
        assert!(path.exists(), "删除前音频文件应当在: {}", path.display());
    }
    let key_ref = core
        .session_meta_for_test()
        .get_meta(&session)
        .unwrap()
        .key_id;

    core.soft_delete_session(session.clone()).unwrap();
    core.purge_session(session.clone()).unwrap();

    assert!(active_ids(&core).is_empty());
    assert!(trashed_ids(&core).is_empty(), "彻底删除后垃圾箱也要空");
    assert!(
        core.get_session(session.clone()).is_err(),
        "彻底删除后 get_session 要报不存在"
    );
    for path in &chunk_paths {
        assert!(
            !path.exists(),
            "加密音频文件必须真的消失: {}",
            path.display()
        );
    }
    if let Some(key_ref) = key_ref {
        assert!(
            !core.key_exists_for_test(&key_ref),
            "音频密钥必须跟着音频一起走"
        );
    }
    assert!(
        core.session_meta_for_test().get_meta(&session).is_err(),
        "session 元数据行不得留下(连带音频路径与密钥引用)"
    );
    assert!(
        core.session_meta_for_test()
            .list_audio_retention_chunks(&session)
            .unwrap()
            .is_empty(),
        "音频留存账本也要清空 —— 留着账本等于留着一张清单说这里曾有什么"
    );
}

#[test]
fn purging_without_a_trip_through_the_trash_still_works() {
    // TrashPage 是主路径,但 Notebook 侧的删除会直接彻底删 —— 两条路
    // 落在同一个动词上,不该有先后顺序的隐含要求。
    let (_tmp, core) = make_core();
    let session = import_one(&core, "直接彻底删");

    core.purge_session(session.clone()).unwrap();
    assert!(core.get_session(session).is_err());
}

#[test]
fn a_trashed_recording_stays_out_of_search_results() {
    // 搜索是「这台机器上有什么」的另一个入口。删掉的录音从 Home 消失
    // 却还能被搜出来,等于删除只是障眼法 —— 录音带情绪,这是最不能
    // 含糊的一处。
    let (_tmp, core) = make_core();
    let session = import_one(&core, "搜索");
    core.index_session_for_test(&session, "quarterly board meeting notes");

    let hits = core.search_sessions("quarterly".into(), 10).unwrap();
    assert_eq!(
        hits.iter()
            .map(|h| h.session_id.clone())
            .collect::<Vec<_>>(),
        vec![session.clone()],
        "前提:没删之前搜得到"
    );

    core.soft_delete_session(session.clone()).unwrap();
    let hits: Vec<String> = core
        .search_sessions("quarterly".into(), 10)
        .unwrap()
        .into_iter()
        .map(|h| h.session_id)
        .collect();
    assert!(
        hits.is_empty(),
        "在垃圾箱里的录音不得出现在搜索结果里,搜到的却是 {hits:?}"
    );

    // 从垃圾箱恢复之后,又该搜得回来。
    core.restore_session(session.clone()).unwrap();
    let hits = core.search_sessions("quarterly".into(), 10).unwrap();
    assert_eq!(
        hits.iter()
            .map(|h| h.session_id.clone())
            .collect::<Vec<_>>(),
        vec![session],
        "恢复之后要重新搜得到 —— 软删不是把索引也烧掉"
    );
}

#[test]
fn a_trashed_recording_stops_counting_towards_its_notebook() {
    // Home 的列表和 Notebook 的「几段录音」读的是同一件事实的两条路。
    // 删一段之后两边给出不同的数,用户只能猜哪个是真的。
    let (_tmp, core) = make_core();
    let notebook = core.create_notebook(Some("同一件事实".into())).unwrap();
    let keep = core
        .import_audio_into_notebook(
            fixture_wav().to_str().unwrap().to_string(),
            notebook.id.clone(),
        )
        .unwrap()
        .session_id;
    let drop = core
        .import_audio_into_notebook(
            fixture_wav().to_str().unwrap().to_string(),
            notebook.id.clone(),
        )
        .unwrap()
        .session_id;

    assert_eq!(active_ids(&core).len(), 2);
    assert_eq!(
        core.list_notebook_sessions(notebook.id.clone())
            .unwrap()
            .len(),
        2,
        "前提:两段都在这个 Notebook 里"
    );

    core.soft_delete_session(drop.clone()).unwrap();

    assert_eq!(active_ids(&core), vec![keep.clone()]);
    let linked: Vec<String> = core
        .list_notebook_sessions(notebook.id)
        .unwrap()
        .into_iter()
        .map(|link| link.session_id)
        .collect();
    assert_eq!(
        linked,
        vec![keep],
        "Notebook 里也不该再算上垃圾箱里的那一段 —— 两个界面必须给同一个数"
    );
}

#[test]
fn purging_takes_the_search_index_with_it() {
    let (_tmp, core) = make_core();
    let session = import_one(&core, "搜索索引");
    core.index_session_for_test(&session, "quarterly board meeting notes");

    core.purge_session(session).unwrap();
    assert!(
        core.search_sessions("quarterly".into(), 10)
            .unwrap()
            .is_empty(),
        "彻底删除后全文索引里不得留下残句"
    );
}

/// 正在录的删不了 —— 软删与彻底删除一视同仁。
///
/// 「删了它」之后录音还在往一个已删对象里写音频、烧 provider 分钟,
/// 停下来才发现东西直接落进了垃圾箱。停止录音是删除的前置条件,两个
/// 删除动词都守这一条。
#[test]
fn a_recording_in_progress_cannot_be_deleted_until_it_stops() {
    use vt_ffi::notebook_capture_api::{
        FfiNotebookCaptureCallback, FfiNotebookCaptureEvent, FfiNotebookCaptureLivePreview,
    };
    struct Noop;
    impl FfiNotebookCaptureCallback for Noop {
        fn on_capture_event(&self, _event: FfiNotebookCaptureEvent) {}
        fn on_live_preview(&self, _preview: FfiNotebookCaptureLivePreview) {}
    }

    let (_tmp, core) = make_core();
    let notebook = core.create_notebook(Some("录音中".into())).unwrap();
    let profile = core
        .get_notebook_capture_profile(notebook.id.clone())
        .unwrap();
    let capture = core
        .start_notebook_capture_session(notebook.id, profile.revision, None, Box::new(Noop))
        .unwrap();
    core.push_notebook_capture_session(capture.session_id.clone(), vec![0_u8; 3_200])
        .unwrap();

    assert!(
        core.soft_delete_session(capture.session_id.clone())
            .is_err(),
        "录音进行中,软删要拒绝"
    );
    assert!(
        core.purge_session(capture.session_id.clone()).is_err(),
        "彻底删除同样拒绝"
    );
    // 拒绝之后,这段录音必须还好好地在 Home 里 —— 别拒绝一半留个残状态。
    assert_eq!(active_ids(&core), vec![capture.session_id.clone()]);
    assert!(trashed_ids(&core).is_empty());

    // 停下来,就删得动了。
    core.stop_notebook_capture_session(capture.session_id.clone())
        .unwrap();
    core.soft_delete_session(capture.session_id.clone())
        .expect("停止之后删除应当放行");
    assert_eq!(trashed_ids(&core), vec![capture.session_id]);
}

/// 批量删除里混进了正在录的那一条:整批拒绝,一条都不删。
///
/// 悄悄跳过一条最坏:用户看着列表少了几行,以为全删了。
#[test]
fn a_batch_that_contains_the_live_recording_is_refused_whole() {
    use vt_ffi::notebook_capture_api::{
        FfiNotebookCaptureCallback, FfiNotebookCaptureEvent, FfiNotebookCaptureLivePreview,
    };
    struct Noop;
    impl FfiNotebookCaptureCallback for Noop {
        fn on_capture_event(&self, _event: FfiNotebookCaptureEvent) {}
        fn on_live_preview(&self, _preview: FfiNotebookCaptureLivePreview) {}
    }

    let (_tmp, core) = make_core();
    let notebook = core.create_notebook(Some("混批".into())).unwrap();
    let done = core
        .import_audio_into_notebook(
            fixture_wav().to_str().unwrap().to_string(),
            notebook.id.clone(),
        )
        .unwrap()
        .session_id;
    let profile = core
        .get_notebook_capture_profile(notebook.id.clone())
        .unwrap();
    let live = core
        .start_notebook_capture_session(notebook.id, profile.revision, None, Box::new(Noop))
        .unwrap();
    core.push_notebook_capture_session(live.session_id.clone(), vec![0_u8; 3_200])
        .unwrap();

    assert!(
        core.soft_delete_sessions(vec![done.clone(), live.session_id.clone()])
            .is_err(),
        "名单里有正在录的,整批拒绝"
    );
    assert!(
        trashed_ids(&core).is_empty(),
        "拒绝就是一条都不删,包括本来能删的那条"
    );

    // 把正在录的那条从名单里去掉,其余照删。
    core.soft_delete_sessions(vec![done.clone()]).unwrap();
    assert_eq!(trashed_ids(&core), vec![done]);
    core.stop_notebook_capture_session(live.session_id).unwrap();
}

#[test]
fn a_recording_moved_between_notebooks_keeps_its_trash_state_straight() {
    // 移动改的是归属,软删改的是可见性。两件事叠在一起时,录音不该
    // 从两个 Notebook 里同时消失(找不回来),也不该同时出现在两个里。
    let (_tmp, core) = make_core();
    let source = core.create_notebook(Some("原处".into())).unwrap();
    let target = core.create_notebook(Some("去处".into())).unwrap();
    let session = core
        .import_audio_into_notebook(
            fixture_wav().to_str().unwrap().to_string(),
            source.id.clone(),
        )
        .unwrap()
        .session_id;

    core.move_session_to_notebook(session.clone(), target.id.clone())
        .unwrap();
    assert!(core
        .list_notebook_sessions(source.id.clone())
        .unwrap()
        .is_empty());
    assert_eq!(
        core.list_notebook_sessions(target.id.clone())
            .unwrap()
            .len(),
        1,
        "移动之后只在去处出现一次"
    );

    core.soft_delete_session(session.clone()).unwrap();
    assert!(
        core.list_notebook_sessions(target.id.clone())
            .unwrap()
            .is_empty(),
        "进了垃圾箱,去处也不再显示"
    );
    assert_eq!(trashed_ids(&core), vec![session.clone()]);

    core.restore_session(session.clone()).unwrap();
    let back: Vec<String> = core
        .list_notebook_sessions(target.id)
        .unwrap()
        .into_iter()
        .map(|link| link.session_id)
        .collect();
    assert_eq!(
        back,
        vec![session],
        "捞回来要回到它当时所在的那个 Notebook,不是原处"
    );
    assert!(core.list_notebook_sessions(source.id).unwrap().is_empty());
}
