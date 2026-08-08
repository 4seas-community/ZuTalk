//! 导出的端到端边界:zip 里出现什么、销毁之后还能导出什么。
//!
//! 导出是本机唯一一条把录音原样带出 App 的通路(分享那条链在依赖图上
//! 就够不到音频)。既然它存在,它的每一条边界都得有人守:没勾选音频
//! 时产物里不许有音频;音频已经销毁时要大声失败,而不是交出一份看起来
//! 完整、其实缺了东西的 zip。

use std::path::PathBuf;
use tempfile::TempDir;
use vt_ffi::notebook_capture_api::{
    FfiNotebookCaptureCallback, FfiNotebookCaptureEvent, FfiNotebookCaptureLivePreview,
};
use vt_ffi::settings_api::ExportZipOptions;
use vt_ffi::ZulangueCore;

struct NoopCaptureCallback;

impl FfiNotebookCaptureCallback for NoopCaptureCallback {
    fn on_capture_event(&self, _event: FfiNotebookCaptureEvent) {}
    fn on_live_preview(&self, _preview: FfiNotebookCaptureLivePreview) {}
}

fn make_core(dir: &TempDir) -> ZulangueCore {
    ZulangueCore::new_for_test(dir.path().to_str().unwrap().to_string()).unwrap()
}

/// 本机采集一小段(无 provider,所以只有音频、没有转录文本)。
fn capture_a_little_audio(core: &ZulangueCore) -> String {
    let notebook = core.create_notebook(Some("导出".into())).unwrap();
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

fn options(include_audio: bool) -> ExportZipOptions {
    ExportZipOptions {
        include_audio,
        include_markdown: true,
        include_srt: false,
        include_vtt: false,
        include_txt: true,
    }
}

/// zip 的条目名在本地文件头里是明文,直接找名字就够判断有没有那一项。
fn zip_mentions(path: &PathBuf, entry: &str) -> bool {
    let bytes = std::fs::read(path).unwrap();
    bytes
        .windows(entry.len())
        .any(|window| window == entry.as_bytes())
}

#[test]
fn an_export_without_audio_carries_no_audio() {
    let dir = TempDir::new().unwrap();
    let core = make_core(&dir);
    let session = capture_a_little_audio(&core);

    let out = dir.path().join("no-audio.zip");
    let size = core
        .export_session_zip(session, out.to_string_lossy().into_owned(), options(false))
        .unwrap();
    assert!(size > 0 && out.exists());
    assert!(zip_mentions(&out, "transcript.md"), "该有的文稿还是要有");
    assert!(
        !zip_mentions(&out, "audio.wav"),
        "没勾选音频时,产物里连音频条目都不许出现"
    );
}

#[test]
fn an_export_with_audio_actually_carries_the_audio() {
    // 反向对照:上一条的「没有」必须是选项造成的,而不是这条路本来
    // 就走不通 —— 否则那条测试永远绿,却什么都没守住。
    let dir = TempDir::new().unwrap();
    let core = make_core(&dir);
    let session = capture_a_little_audio(&core);

    let out = dir.path().join("with-audio.zip");
    core.export_session_zip(session, out.to_string_lossy().into_owned(), options(true))
        .unwrap();
    assert!(zip_mentions(&out, "audio.wav"), "勾选了音频就该真的带上");
}

#[test]
fn exporting_audio_after_it_was_destroyed_fails_loudly() {
    let dir = TempDir::new().unwrap();
    let core = make_core(&dir);
    let session = capture_a_little_audio(&core);

    core.destroy_session_audio_and_key(session.clone()).unwrap();
    assert!(
        !core
            .get_session(session.clone())
            .unwrap()
            .has_encrypted_audio,
        "前提:音频确实销毁了"
    );

    let out = dir.path().join("destroyed.zip");
    let result = core.export_session_zip(
        session.clone(),
        out.to_string_lossy().into_owned(),
        options(true),
    );
    assert!(
        result.is_err(),
        "音频已销毁还要带音频导出,必须失败 —— 交出一份缺了东西的 zip 是最坏的结果"
    );
    assert!(!out.exists(), "失败的导出不许在磁盘上留下半成品");

    // 不带音频的导出仍然应当成功:文字还在,销毁的是录音。
    let text_only = dir.path().join("text-only.zip");
    core.export_session_zip(
        session,
        text_only.to_string_lossy().into_owned(),
        options(false),
    )
    .expect("销毁音频不该连文字导出一起废掉");
    assert!(!zip_mentions(&text_only, "audio.wav"));
}

#[test]
fn exporting_an_unknown_session_says_so() {
    let dir = TempDir::new().unwrap();
    let core = make_core(&dir);
    let out = dir.path().join("ghost.zip");
    assert!(core
        .export_session_zip(
            "no-such-session".into(),
            out.to_string_lossy().into_owned(),
            options(false),
        )
        .is_err());
    assert!(!out.exists());
}

#[test]
fn the_clipboard_refuses_a_transcript_that_has_no_content() {
    // 空转录稿复制出一片空白,用户会以为是复制失败了。宁可报错。
    let dir = TempDir::new().unwrap();
    let core = make_core(&dir);
    let session = capture_a_little_audio(&core);

    assert!(
        core.get_session_transcript_clipboard_text(session).is_err(),
        "没有一句话的转录稿不该复制出空白"
    );
    assert!(core
        .get_session_transcript_clipboard_text("no-such-session".into())
        .is_err());
}
