//! 观看端字幕画布的端到端第一半:一帧三语字幕过**真实端点**之后,
//! 还剩下多少画布画得出栏目所需要的东西。
//!
//! 修的那个毛病(观看端只画一列滚动横条,本机录音却是分栏)不在任何
//! 一层里面,它在**接缝**上:完整形态的帧早就过了网,观看端却没有路
//! 通到布局。所以测的也必须是接缝,一层一层的单元测试证明不了它。
//!
//! 端到端在这里被切成两半,由一份 golden 接上:
//!
//! 1. 这个测试:两个真实 core、真实端点、真实分享码,主播按真实 tap
//!    路径广播一帧,观看端收下来。断言画布依赖的字段逐个过了网,再把
//!    **收到的那一帧**原样写成 `ZulangueTests/Golden/shared-live-preview.json`。
//! 2. `WindowSystemTests.testSharedRoomOverlayDrawsColumnsFromTheWireGolden`:
//!    读同一份 golden,喂给 `SubtitleOverlayView.sharedAudienceInput`,
//!    断言三栏、各栏内容、飘走的那句不占栏。
//!
//! 为什么不写成一个进程里跑完的 Swift 测试:让主播广播一帧的入口是
//! `broadcast_live_preview_for_test`,它**故意没有** `#[uniffi::export]` ——
//! 为了测试方便往出货的 FFI 面上加一个方法,代价比这份 golden 大。
//!
//! golden 的残余缝隙,说在前面:两边各自按字段名读写 JSON,所以给
//! `FfiNotebookCaptureLivePreview` 新加一个字段时,两边都不会自己报错。
//! 加字段的人得记得这份 golden —— 下面的字段清单就是提醒。
//! 重新生成:`ZULANGUE_REGENERATE_CAPTION_GOLDEN=1 cargo test -p vt-ffi
//! --test share_viewer_caption_canvas`。

use std::time::Duration;

use vt_ffi::notebook_capture_api::{
    FfiNotebookCaptureLaneHealth, FfiNotebookCaptureLivePreview, FfiNotebookCaptureTranslationCue,
    FfiNotebookCaptureUtterance,
};
use vt_ffi::ZulangueCore;

fn core(dir: &tempfile::TempDir) -> ZulangueCore {
    ZulangueCore::new_for_test(dir.path().to_string_lossy().to_string()).unwrap()
}

fn wait_until(seconds: u64, mut check: impl FnMut() -> bool) -> bool {
    for _ in 0..(seconds * 20) {
        if check() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    check()
}

fn utterance(
    sequence: u64,
    speaker: Option<&str>,
    language: &str,
    text: &str,
) -> FfiNotebookCaptureUtterance {
    FfiNotebookCaptureUtterance {
        id: format!("u{sequence}"),
        session_id: "sess-canvas".into(),
        sequence,
        revision: 1,
        session_speaker_id: speaker.map(str::to_string),
        source_language: language.into(),
        provisional_source_language: None,
        source_text: text.into(),
        source_start_ms: Some(sequence * 1_000),
        source_end_ms: Some(sequence * 1_000 + 800),
        translated_language: None,
        translated_text: None,
        completion: "complete".into(),
        alignment: "source_only".into(),
        source_projection_revision: 0,
        source_edit_revision: 0,
        language_variants: vec![],
    }
}

/// 论坛现场那一场的形状:中文主讲,英泰两条译文车道,外加一句被语言
/// 识别认成法语的碎片(没有说话人 —— 碎片通常没有)。
fn trilingual_preview() -> FfiNotebookCaptureLivePreview {
    FfiNotebookCaptureLivePreview {
        session_id: "sess-canvas".into(),
        preview_revision: 7,
        utterances: vec![
            utterance(1, Some("spk-1"), "zh-Hans", "家庭、流动和附近。"),
            utterance(2, Some("spk-1"), "zh-Hans", "我们从哪里开始讲起呢。"),
            utterance(3, None, "fr", "une bribe"),
        ],
        translation_cues: vec![
            FfiNotebookCaptureTranslationCue {
                target_language: "en".into(),
                group_epoch: 1,
                provider_sequence: 1,
                source_language: "zh-Hans".into(),
                source_start_ms: Some(1_000),
                source_end_ms: Some(2_800),
                text: "Family, mobility, and the nearby.".into(),
                completion: "complete".into(),
                withdrawn: false,
                revision: 1,
            },
            FfiNotebookCaptureTranslationCue {
                target_language: "th".into(),
                group_epoch: 1,
                provider_sequence: 1,
                source_language: "zh-Hans".into(),
                source_start_ms: Some(1_000),
                source_end_ms: Some(2_800),
                text: "ครอบครัว การเคลื่อนย้าย และสิ่งใกล้ตัว".into(),
                completion: "complete".into(),
                withdrawn: false,
                revision: 1,
            },
            // 撤回的 cue 不该过网 —— 过了就会在栏里留一句已经收回的话。
            FfiNotebookCaptureTranslationCue {
                target_language: "th".into(),
                group_epoch: 1,
                provider_sequence: 2,
                source_language: "zh-Hans".into(),
                source_start_ms: Some(2_800),
                source_end_ms: Some(3_000),
                text: "ถอนแล้ว".into(),
                completion: "partial".into(),
                withdrawn: true,
                revision: 2,
            },
        ],
        lane_health: vec![
            FfiNotebookCaptureLaneHealth {
                target_language: None,
                state: "live".into(),
                group_epoch: 1,
                final_audio_proc_ms: Some(2_800),
                total_audio_proc_ms: Some(3_000),
                lag_ms: Some(120),
                input_discontinuous: false,
            },
            FfiNotebookCaptureLaneHealth {
                target_language: Some("en".into()),
                state: "live".into(),
                group_epoch: 1,
                final_audio_proc_ms: Some(2_800),
                total_audio_proc_ms: Some(3_000),
                lag_ms: Some(300),
                input_discontinuous: false,
            },
            FfiNotebookCaptureLaneHealth {
                target_language: Some("th".into()),
                state: "failed".into(),
                group_epoch: 1,
                final_audio_proc_ms: None,
                total_audio_proc_ms: None,
                lag_ms: None,
                input_discontinuous: false,
            },
        ],
    }
}

fn golden_path() -> std::path::PathBuf {
    std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../macos/Zulangue/ZulangueTests/Golden/shared-live-preview.json")
}

/// 观看端收到的那一帧 → JSON。字段名与 FFI 记录一一对应,Swift 侧按同样
/// 的名字读回去。
fn to_golden_json(preview: &FfiNotebookCaptureLivePreview) -> String {
    let value = serde_json::json!({
        "session_id": preview.session_id,
        "preview_revision": preview.preview_revision,
        "utterances": preview.utterances.iter().map(|u| serde_json::json!({
            "id": u.id,
            "session_id": u.session_id,
            "sequence": u.sequence,
            "revision": u.revision,
            "session_speaker_id": u.session_speaker_id,
            "source_language": u.source_language,
            "provisional_source_language": u.provisional_source_language,
            "source_text": u.source_text,
            "source_start_ms": u.source_start_ms,
            "source_end_ms": u.source_end_ms,
            "translated_language": u.translated_language,
            "translated_text": u.translated_text,
            "completion": u.completion,
            "alignment": u.alignment,
        })).collect::<Vec<_>>(),
        "translation_cues": preview.translation_cues.iter().map(|c| serde_json::json!({
            "target_language": c.target_language,
            "group_epoch": c.group_epoch,
            "provider_sequence": c.provider_sequence,
            "source_language": c.source_language,
            "source_start_ms": c.source_start_ms,
            "source_end_ms": c.source_end_ms,
            "text": c.text,
            "completion": c.completion,
            "withdrawn": c.withdrawn,
            "revision": c.revision,
        })).collect::<Vec<_>>(),
        "lane_health": preview.lane_health.iter().map(|l| serde_json::json!({
            "target_language": l.target_language,
            "state": l.state,
            "group_epoch": l.group_epoch,
        })).collect::<Vec<_>>(),
    });
    format!("{}\n", serde_json::to_string_pretty(&value).unwrap())
}

#[test]
fn a_trilingual_frame_reaches_the_viewer_with_everything_the_canvas_needs() {
    let host_dir = tempfile::tempdir().unwrap();
    let viewer_dir = tempfile::tempdir().unwrap();
    let host = core(&host_dir);
    let viewer = core(&viewer_dir);

    let code = host
        .start_sharing(Some("nb-canvas".into()), None, false)
        .expect("开始共享");
    viewer.join_share(code).expect("加入房间");
    assert!(
        wait_until(10, || viewer.share_state().is_viewing),
        "观看端应当进到房间里"
    );

    // 走真实 tap 路径广播:范围过滤、静音判定、完整形态翻译都是生产代码。
    let sent = trilingual_preview();
    assert!(
        wait_until(15, || {
            host.broadcast_live_preview_for_test("nb-canvas".into(), &sent);
            viewer.share_state().remote_preview.is_some()
        }),
        "观看端应当收到主播的预览帧"
    );
    let received = viewer
        .share_state()
        .remote_preview
        .expect("上一步已经等到了");

    // ── 画布靠这些字段分栏。逐个断言,而不是只比一个整体相等 —— 哪个
    //    字段掉在路上,报出来的应当是那个字段的名字。
    assert_eq!(received.session_id, "sess-canvas");
    assert_eq!(received.utterances.len(), 3, "三句话都要过网");

    let first = &received.utterances[0];
    assert_eq!(first.source_text, "家庭、流动和附近。");
    assert_eq!(
        first.source_language, "zh-Hans",
        "原文语种决定这句落在哪一栏"
    );
    assert_eq!(
        first.session_speaker_id.as_deref(),
        Some("spk-1"),
        "说话人既是标签,也是判定主导语言时的加权信号"
    );
    assert_eq!(
        (first.source_start_ms, first.source_end_ms),
        (Some(1_000), Some(1_800)),
        "时间锚决定卡片在栏里的先后"
    );

    assert!(
        received.utterances[2].session_speaker_id.is_none(),
        "飘出来的碎片没有说话人 —— 主导语言判定要认得出这一点"
    );

    // cue 按语言分别到齐;撤回的那条不许过网。
    let cue_languages: Vec<&str> = received
        .translation_cues
        .iter()
        .map(|c| c.target_language.as_str())
        .collect();
    assert_eq!(cue_languages, vec!["en", "th"], "撤回的 cue 不得过网");
    assert!(received.translation_cues.iter().all(|c| c.text != "ถอนแล้ว"));

    // lane health 是栏目的来源:主播真的在跑的车道才配有一栏。
    let lanes: Vec<(Option<&str>, &str)> = received
        .lane_health
        .iter()
        .map(|l| (l.target_language.as_deref(), l.state.as_str()))
        .collect();
    assert_eq!(
        lanes,
        vec![(None, "live"), (Some("en"), "live"), (Some("th"), "failed")],
        "canonical 车道 + 两条译文车道,状态原样过网"
    );

    // ── 把收到的这一帧交给下半场。
    let actual = to_golden_json(&received);
    let path = golden_path();
    if std::env::var("ZULANGUE_REGENERATE_CAPTION_GOLDEN").as_deref() == Ok("1") || !path.exists() {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, &actual).unwrap();
        panic!("golden 已写入 {},重跑一次以验证", path.display());
    }
    let expected = std::fs::read_to_string(&path).unwrap();
    assert_eq!(
        actual, expected,
        "过网之后的帧变了形。要么是真坏了,要么是记录该更新 —— \
         用 ZULANGUE_REGENERATE_CAPTION_GOLDEN=1 重新生成,并去看 Swift 侧那半场"
    );

    host.stop_sharing().unwrap();
}
