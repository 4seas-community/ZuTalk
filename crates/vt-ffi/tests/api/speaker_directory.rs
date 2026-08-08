//! 说话人目录:一场录音里的「Speaker 2」怎么变成「张三」。
//!
//! 两层名字:**session speaker** 是 provider 在这一场里报出来的标签,
//! **participant** 是跨录音的一个人。会前不知道谁会说话,所以先有标签,
//! 事后再认领。这一族之前没有集成测试;它守的是两条:
//!
//! - 认领是**指向**,不是复制。改了 participant 的名字,所有认领过它的
//!   录音跟着改;否则一次改名要挨个录音重来一遍。
//! - session 级的手写名字**压过** participant 的名字。「这一场他用的是
//!   另一个称呼」必须表达得出来。

use tempfile::TempDir;
use vt_ffi::notebook_capture_api::{
    FfiNotebookCaptureCallback, FfiNotebookCaptureEvent, FfiNotebookCaptureLivePreview,
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

/// 录一小段并停下,返回 session_id —— 说话人要挂在一场真实的录音上。
fn a_finished_recording(core: &ZulangueCore, title: &str) -> String {
    let notebook = core.create_notebook(Some(title.to_string())).unwrap();
    let profile = core
        .get_notebook_capture_profile(notebook.id.clone())
        .unwrap();
    let capture = core
        .start_notebook_capture_session(
            notebook.id,
            profile.revision,
            None,
            Box::new(NoopCaptureCallback),
        )
        .unwrap();
    core.push_notebook_capture_session(capture.session_id.clone(), vec![0_u8; 3_200])
        .unwrap();
    core.stop_notebook_capture_session(capture.session_id.clone())
        .unwrap();
    capture.session_id
}

#[test]
fn a_participant_is_created_named_and_listed() {
    let dir = TempDir::new().unwrap();
    let core = make_core(&dir);

    let participant = core.create_speaker_participant("张三".into()).unwrap();
    assert_eq!(participant.display_name, "张三");
    assert_eq!(core.list_speaker_participants().unwrap().len(), 1);

    let renamed = core
        .rename_speaker_participant(participant.id.clone(), "张三丰".into())
        .unwrap();
    assert_eq!(renamed.id, participant.id, "改名不换身份");
    assert_eq!(renamed.display_name, "张三丰");

    // 空名字拒绝:一个叫「」的人在列表里没法认。
    assert!(core.create_speaker_participant("   ".into()).is_err());
    assert!(core
        .rename_speaker_participant(participant.id, "".into())
        .is_err());
    assert!(core
        .rename_speaker_participant("no-such-participant".into(), "李四".into())
        .is_err());
}

#[test]
fn claiming_a_speaker_points_at_the_participant_instead_of_copying_the_name() {
    // 认领之后改 participant 的名字,录音那边要跟着变。要是认领时把
    // 名字抄过去,一次改名就得挨个录音重来。
    let dir = TempDir::new().unwrap();
    let core = make_core(&dir);
    let session = a_finished_recording(&core, "认领");
    let speaker = core
        .ensure_session_speaker_for_test(&session, "Speaker 2")
        .unwrap();
    let participant = core.create_speaker_participant("张三".into()).unwrap();

    let linked = core
        .link_notebook_session_speaker(speaker.clone(), participant.id.clone())
        .unwrap();
    assert_eq!(
        linked.participant_id.as_deref(),
        Some(participant.id.as_str())
    );
    assert!(
        linked.local_display_name.is_none(),
        "认领不写 session 级名字 —— 那是另一件事"
    );

    core.rename_speaker_participant(participant.id.clone(), "张三丰".into())
        .unwrap();
    let after = core
        .list_notebook_session_speakers(session.clone())
        .unwrap();
    assert_eq!(after.len(), 1);
    assert_eq!(
        after[0].participant_id.as_deref(),
        Some(participant.id.as_str()),
        "改名不该动认领关系"
    );

    // 解绑:标签回到无主状态,provider 报的原始标签还在。
    let unlinked = core.unlink_notebook_session_speaker(speaker).unwrap();
    assert!(unlinked.participant_id.is_none());
    assert_eq!(
        unlinked.provider_label, "Speaker 2",
        "provider 报的原始标签是事实,任何操作都不许改它"
    );
}

#[test]
fn a_session_only_name_overrides_the_claimed_participant() {
    let dir = TempDir::new().unwrap();
    let core = make_core(&dir);
    let session = a_finished_recording(&core, "本场称呼");
    let speaker = core
        .ensure_session_speaker_for_test(&session, "Speaker 1")
        .unwrap();
    let participant = core.create_speaker_participant("张三".into()).unwrap();
    core.link_notebook_session_speaker(speaker.clone(), participant.id)
        .unwrap();

    let named = core
        .rename_notebook_session_speaker(speaker.clone(), Some("主持人".into()))
        .unwrap();
    assert_eq!(
        named.local_display_name.as_deref(),
        Some("主持人"),
        "这一场他就是「主持人」"
    );
    assert!(
        named.participant_id.is_some(),
        "本场称呼不该顺手把认领关系抹掉"
    );

    // 空字符串 = 清掉本场称呼,回到 participant 的名字。
    let cleared = core
        .rename_notebook_session_speaker(speaker.clone(), Some("   ".into()))
        .unwrap();
    assert!(cleared.local_display_name.is_none());
    let cleared = core.rename_notebook_session_speaker(speaker, None).unwrap();
    assert!(cleared.local_display_name.is_none());
}

#[test]
fn speakers_from_two_recordings_can_claim_the_same_person() {
    // 同一个人在两场会里都说了话 —— 两条标签指向同一个 participant,
    // 这正是「跨录音的一个人」的意思。
    let dir = TempDir::new().unwrap();
    let core = make_core(&dir);
    let monday = a_finished_recording(&core, "周一");
    let tuesday = a_finished_recording(&core, "周二");
    let participant = core.create_speaker_participant("张三".into()).unwrap();

    for session in [&monday, &tuesday] {
        let speaker = core
            .ensure_session_speaker_for_test(session, "Speaker 1")
            .unwrap();
        core.link_notebook_session_speaker(speaker, participant.id.clone())
            .unwrap();
    }

    for session in [&monday, &tuesday] {
        let speakers = core
            .list_notebook_session_speakers(session.clone())
            .unwrap();
        assert_eq!(speakers.len(), 1);
        assert_eq!(
            speakers[0].participant_id.as_deref(),
            Some(participant.id.as_str())
        );
        assert_eq!(
            speakers[0].session_id, *session,
            "标签归各自的录音,不许串场"
        );
    }
}

#[test]
fn claiming_refuses_ghosts_on_both_sides() {
    let dir = TempDir::new().unwrap();
    let core = make_core(&dir);
    let session = a_finished_recording(&core, "幽灵");
    let speaker = core
        .ensure_session_speaker_for_test(&session, "Speaker 1")
        .unwrap();
    let participant = core.create_speaker_participant("张三".into()).unwrap();

    assert!(
        core.link_notebook_session_speaker(speaker.clone(), "no-such-participant".into())
            .is_err(),
        "认领一个不存在的人:拒绝"
    );
    assert!(
        core.link_notebook_session_speaker("no-such-speaker".into(), participant.id)
            .is_err(),
        "给一条不存在的标签认领:同样拒绝"
    );
    assert!(core
        .rename_notebook_session_speaker("no-such-speaker".into(), Some("x".into()))
        .is_err());
    assert!(core
        .unlink_notebook_session_speaker("no-such-speaker".into())
        .is_err());

    // 一连串拒绝之后,原来的标签还干干净净。
    let speakers = core.list_notebook_session_speakers(session).unwrap();
    assert_eq!(speakers.len(), 1);
    assert_eq!(speakers[0].id, speaker);
    assert!(speakers[0].participant_id.is_none());
}

#[test]
fn deleting_the_recording_forever_takes_its_speaker_labels_with_it() {
    // 说话人标签是「这场录音里谁说了话」的一部分。录音彻底删了,
    // 标签不该还留在库里说明这里曾经有过谁。
    let dir = TempDir::new().unwrap();
    let core = make_core(&dir);
    let session = a_finished_recording(&core, "彻底删除");
    core.ensure_session_speaker_for_test(&session, "Speaker 1")
        .unwrap();
    let participant = core.create_speaker_participant("张三".into()).unwrap();

    core.purge_session(session.clone()).unwrap();
    assert!(
        core.list_notebook_session_speakers(session)
            .unwrap()
            .is_empty(),
        "录音没了,这一场的说话人标签也该没了"
    );
    // participant 是跨录音的,不跟着一场录音走。
    assert_eq!(
        core.list_speaker_participants().unwrap()[0].id,
        participant.id,
        "跨录音的人不因为删掉一场录音而消失"
    );
}
