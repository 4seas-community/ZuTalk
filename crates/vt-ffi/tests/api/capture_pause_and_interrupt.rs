//! 采集的暂停/恢复/中断:状态机与所有权的端到端。
//!
//! 一次只能有一个采集所有者(`capture_ownership_gate`)。暂停、恢复、
//! 中断都在动这个所有权,而它们的失败路径是最容易漏的地方 —— 所有权
//! 没释放,用户就再也开不了下一次录音,只能重启 App。这里每条失败之后
//! 都追问一句:还录得起来吗。

use tempfile::TempDir;
use vt_ffi::notebook_capture_api::{
    FfiNotebookCaptureCallback, FfiNotebookCaptureEvent, FfiNotebookCaptureInterruptReason,
    FfiNotebookCaptureLivePreview, FfiNotebookCaptureState,
};
use vt_ffi::ZulangueCore;

struct NoopCaptureCallback;

impl FfiNotebookCaptureCallback for NoopCaptureCallback {
    fn on_capture_event(&self, _event: FfiNotebookCaptureEvent) {}
    fn on_live_preview(&self, _preview: FfiNotebookCaptureLivePreview) {}
}

fn make_core(dir: &TempDir) -> ZulangueCore {
    ZulangueCore::new_for_test(dir.path().to_str().unwrap().to_string()).unwrap()
}

/// 开一次本机采集(无 provider),返回 (notebook_id, session_id)。
fn start_capture(core: &ZulangueCore, title: &str) -> (String, String) {
    let notebook = core.create_notebook(Some(title.to_string())).unwrap();
    let profile = core
        .get_notebook_capture_profile(notebook.id.clone())
        .unwrap();
    let capture = core
        .start_notebook_capture_session(
            notebook.id.clone(),
            profile.revision,
            None,
            Box::new(NoopCaptureCallback),
        )
        .unwrap();
    (notebook.id, capture.session_id)
}

/// 还开得起下一次录音吗 —— 采集所有权有没有被卡住的唯一判据。
fn can_start_another(core: &ZulangueCore, notebook_id: &str) -> bool {
    let Ok(profile) = core.get_notebook_capture_profile(notebook_id.to_string()) else {
        return false;
    };
    match core.start_notebook_capture_session(
        notebook_id.to_string(),
        profile.revision,
        None,
        Box::new(NoopCaptureCallback),
    ) {
        Ok(capture) => {
            let _ = core.stop_notebook_capture_session(capture.session_id);
            true
        }
        Err(_) => false,
    }
}

#[test]
fn pause_and_resume_walk_the_state_machine_both_ways() {
    let dir = TempDir::new().unwrap();
    let core = make_core(&dir);
    let (notebook, session) = start_capture(&core, "暂停");
    core.push_notebook_capture_session(session.clone(), vec![0_u8; 3_200])
        .unwrap();

    let paused = core
        .pause_notebook_capture_session(session.clone(), true)
        .unwrap();
    assert_eq!(paused.capture_state, FfiNotebookCaptureState::Paused);
    assert_eq!(
        core.get_notebook_capture_session_event(session.clone())
            .unwrap()
            .capture_state,
        FfiNotebookCaptureState::Paused,
        "暂停要落盘 —— 崩溃重启后还得认这个状态"
    );

    let resumed = core
        .pause_notebook_capture_session(session.clone(), false)
        .unwrap();
    assert_eq!(resumed.capture_state, FfiNotebookCaptureState::Recording);

    core.stop_notebook_capture_session(session).unwrap();
    assert!(can_start_another(&core, &notebook));
}

#[test]
fn pausing_twice_is_refused_without_losing_the_recording() {
    // 状态机只认一次跃迁。重复暂停要拒绝,但不能顺手把这次录音搞坏 ——
    // 拒绝之后必须还能继续录、能正常停。
    let dir = TempDir::new().unwrap();
    let core = make_core(&dir);
    let (notebook, session) = start_capture(&core, "重复暂停");
    core.push_notebook_capture_session(session.clone(), vec![0_u8; 3_200])
        .unwrap();

    core.pause_notebook_capture_session(session.clone(), true)
        .unwrap();
    assert!(
        core.pause_notebook_capture_session(session.clone(), true)
            .is_err(),
        "已经暂停了还要暂停:拒绝"
    );
    assert!(
        core.get_notebook_capture_session_event(session.clone())
            .unwrap()
            .capture_state
            == FfiNotebookCaptureState::Paused,
        "被拒绝的跃迁不许改状态"
    );

    // 恢复之后一切照常。
    core.pause_notebook_capture_session(session.clone(), false)
        .unwrap();
    assert!(
        core.pause_notebook_capture_session(session.clone(), false)
            .is_err(),
        "没暂停就恢复,同样拒绝"
    );
    core.push_notebook_capture_session(session.clone(), vec![0_u8; 3_200])
        .unwrap();
    core.stop_notebook_capture_session(session).unwrap();
    assert!(can_start_another(&core, &notebook));
}

#[test]
fn pausing_a_session_that_is_not_the_active_one_is_refused() {
    let dir = TempDir::new().unwrap();
    let core = make_core(&dir);
    let (notebook, session) = start_capture(&core, "认人");

    assert!(
        core.pause_notebook_capture_session("someone-else".into(), true)
            .is_err(),
        "暂停要指名道姓,不能顺手把当前那一场停了"
    );
    assert_eq!(
        core.get_notebook_capture_session_event(session.clone())
            .unwrap()
            .capture_state,
        FfiNotebookCaptureState::Recording
    );

    core.stop_notebook_capture_session(session).unwrap();
    assert!(can_start_another(&core, &notebook));
}

#[test]
fn an_interruption_is_durable_and_releases_the_capture_owner() {
    let dir = TempDir::new().unwrap();
    let core = make_core(&dir);
    let (notebook, session) = start_capture(&core, "中断");
    core.push_notebook_capture_session(session.clone(), vec![0_u8; 3_200])
        .unwrap();

    let interrupted = core
        .interrupt_notebook_capture_session(
            session.clone(),
            FfiNotebookCaptureInterruptReason::LocalAudioUnavailable,
        )
        .unwrap();
    assert_eq!(
        interrupted.capture_state,
        FfiNotebookCaptureState::Interrupted
    );
    assert_eq!(
        interrupted.provider_error_type.as_deref(),
        Some("local_audio_unavailable"),
        "中断原因要留下来 —— UI 得说得出为什么断的"
    );
    assert_eq!(
        core.get_session(session.clone()).unwrap().status,
        "interrupted"
    );
    // 断之前收下的音频不该跟着没:中断不是删除。
    assert!(
        core.get_session(session.clone())
            .unwrap()
            .has_encrypted_audio
    );

    // 最要紧的一条:所有权释放了,下一次录音开得起来。
    assert!(
        can_start_another(&core, &notebook),
        "中断之后必须还能开下一次录音,否则用户只能重启 App"
    );
    // 断了的那一场不再收音频。
    assert!(core
        .push_notebook_capture_session(session, vec![0_u8; 3_200])
        .is_err());
}

#[test]
fn a_paused_session_can_still_be_interrupted() {
    let dir = TempDir::new().unwrap();
    let core = make_core(&dir);
    let (notebook, session) = start_capture(&core, "暂停中断");
    core.push_notebook_capture_session(session.clone(), vec![0_u8; 3_200])
        .unwrap();
    core.pause_notebook_capture_session(session.clone(), true)
        .unwrap();

    let interrupted = core
        .interrupt_notebook_capture_session(
            session.clone(),
            FfiNotebookCaptureInterruptReason::LocalAudioOverflow,
        )
        .unwrap();
    assert_eq!(
        interrupted.capture_state,
        FfiNotebookCaptureState::Interrupted
    );
    assert!(can_start_another(&core, &notebook));
}

#[test]
fn a_stopped_session_cannot_be_paused_or_interrupted_again() {
    let dir = TempDir::new().unwrap();
    let core = make_core(&dir);
    let (notebook, session) = start_capture(&core, "停后");
    core.push_notebook_capture_session(session.clone(), vec![0_u8; 3_200])
        .unwrap();
    core.stop_notebook_capture_session(session.clone()).unwrap();

    assert!(core
        .pause_notebook_capture_session(session.clone(), true)
        .is_err());
    assert!(core
        .interrupt_notebook_capture_session(
            session.clone(),
            FfiNotebookCaptureInterruptReason::LocalAudioUnavailable,
        )
        .is_err());
    // 状态没被这两次拒绝改坏。
    assert_ne!(
        core.get_notebook_capture_session_event(session)
            .unwrap()
            .capture_state,
        FfiNotebookCaptureState::Interrupted
    );
    assert!(can_start_another(&core, &notebook));
}

#[test]
fn a_paused_recording_still_refuses_to_be_deleted() {
    // 「正在录的不能删」这条规矩要认整段录音,不只是它此刻在不在收音。
    // 暂停只是中途歇一口气,录音还没结束。
    let dir = TempDir::new().unwrap();
    let core = make_core(&dir);
    let (notebook, session) = start_capture(&core, "暂停时删除");
    core.push_notebook_capture_session(session.clone(), vec![0_u8; 3_200])
        .unwrap();
    core.pause_notebook_capture_session(session.clone(), true)
        .unwrap();

    assert!(
        core.soft_delete_session(session.clone()).is_err(),
        "暂停中的录音同样删不得"
    );
    assert!(core.purge_session(session.clone()).is_err());

    core.stop_notebook_capture_session(session.clone()).unwrap();
    core.soft_delete_session(session).expect("停了就删得动了");
    assert!(can_start_another(&core, &notebook));
}
