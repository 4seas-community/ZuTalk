//! 分享 UX 的补充场景。share_ux_end_to_end.rs 走主线;这里走岔路 ——
//! 每一条都是真实会议里会发生、且与主线走**不同代码路径**的事。
//!
//! - 晚加入:内容在先、加入在后,走催缺(Have/respond_to_have),
//!   不是主线的实时推送;
//! - 三人房间:A 的订正要经主持人转发才到得了 B —— 文档更新走成对
//!   直连流,没有转发星型就是断的;
//! - 双向黄金起点:观看端先写、宿主后写,§11 声称能安全合并;
//! - Notebook 范围:v1 字幕-only,观看端必须拒收一切文档;
//! - 删了再收:副本删除后重进房间,催缺把它再拉回来;
//! - 散场再开:上一场的「已结束」不得污染下一场。

use std::time::Duration;

use vt_ffi::ZulangueCore;

fn core(dir: &tempfile::TempDir) -> ZulangueCore {
    ZulangueCore::new_for_test(dir.path().to_string_lossy().to_string()).unwrap()
}

fn wait_until(seconds: u64, mut check: impl FnMut() -> bool) -> bool {
    let rounds = seconds * 20;
    for _ in 0..rounds {
        if check() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    check()
}

/// 晚加入的人靠催缺补课,而且更新通道装得下大段文本。
///
/// 主线测试是「先加入、后物化」——内容经实时推送到达。这里反过来:
/// 主持人先写好内容,观看端才加入。这走的是 join 时那一次
/// `sync_document_with` 催缺(Have → respond_to_have → 全量补发),
/// 与推送是两条路径。20KB 的批注顺带钉死「文档通道没有 gossip 那样的
/// 尺寸红线」。
#[test]
fn a_late_joiner_catches_up_on_existing_content() {
    let host_dir = tempfile::tempdir().unwrap();
    let viewer_dir = tempfile::tempdir().unwrap();
    let host = core(&host_dir);
    let viewer = core(&viewer_dir);

    let session = "sess-late";
    let code = host
        .start_sharing(None, Some(session.into()), false)
        .unwrap();
    host.enable_document_sync().unwrap();

    // 内容先于观看端存在:一条普通批注 + 一条 20KB 的长文。
    host.shared_session_insert_annotation(session.into(), 0, "note-1".into(), "开场白".into())
        .unwrap();
    let long_text = "长".repeat(20_000);
    host.shared_session_insert_annotation(session.into(), 1, "note-long".into(), long_text.clone())
        .unwrap();

    // 现在才加入。
    viewer.join_share(code).unwrap();
    assert!(
        wait_until(10, || {
            viewer
                .shared_session_blocks(session.into())
                .map(|blocks| blocks.len() >= 2)
                .unwrap_or(false)
        }),
        "晚加入的人必须通过催缺拿到已有内容"
    );
    let blocks = viewer.shared_session_blocks(session.into()).unwrap();
    assert_eq!(blocks[0].text, "开场白");
    assert_eq!(blocks[1].text, long_text, "20KB 文本要原样到达");

    host.stop_sharing().unwrap();
    viewer.stop_sharing().unwrap();
}

/// 三人房间:一个观看端的订正,另一个观看端也要看得到。
///
/// 文档更新走成对直连流(A↔主持人、B↔主持人),A 和 B 之间没有连接。
/// A 的订正只有经主持人**转发**才到得了 B —— 没有这一跳,多人协同
/// 就只是三场两人协同。
#[test]
fn a_correction_reaches_the_other_viewer_through_the_host() {
    let host_dir = tempfile::tempdir().unwrap();
    let a_dir = tempfile::tempdir().unwrap();
    let b_dir = tempfile::tempdir().unwrap();
    let host = core(&host_dir);
    let viewer_a = core(&a_dir);
    let viewer_b = core(&b_dir);

    let session = "sess-trio";
    let code = host
        .start_sharing(None, Some(session.into()), false)
        .unwrap();
    host.enable_document_sync().unwrap();

    viewer_a.join_share(code.clone()).unwrap();
    viewer_b.join_share(code).unwrap();
    assert!(
        wait_until(10, || host.room_members().len() >= 3),
        "名册应当收敛到三个人"
    );

    // 主持人写底稿,两个观看端都收到。
    host.shared_session_insert_annotation(session.into(), 0, "note-1".into(), "底稿".into())
        .unwrap();
    for (name, viewer) in [("A", &viewer_a), ("B", &viewer_b)] {
        assert!(
            wait_until(10, || {
                viewer
                    .shared_session_blocks(session.into())
                    .map(|blocks| !blocks.is_empty())
                    .unwrap_or(false)
            }),
            "观看端 {name} 应当收到底稿"
        );
    }

    // A 订正;B 必须看得到 —— 经主持人转发。
    let block_id = viewer_a.shared_session_blocks(session.into()).unwrap()[0]
        .id
        .clone();
    viewer_a
        .shared_session_replace_text(session.into(), block_id, "底稿(A 的订正)".into())
        .unwrap();

    assert!(
        wait_until(10, || {
            host.shared_session_blocks(session.into())
                .map(|blocks| blocks[0].text == "底稿(A 的订正)")
                .unwrap_or(false)
        }),
        "A 的订正应当先到主持人"
    );
    assert!(
        wait_until(10, || {
            viewer_b
                .shared_session_blocks(session.into())
                .map(|blocks| blocks[0].text == "底稿(A 的订正)")
                .unwrap_or(false)
        }),
        "A 的订正必须经主持人转发抵达 B —— 否则多人协同只是幻觉"
    );

    host.stop_sharing().unwrap();
    viewer_a.stop_sharing().unwrap();
    viewer_b.stop_sharing().unwrap();
}

/// 双向黄金起点:观看端在收到宿主任何内容**之前**先写自己的批注。
///
/// §11 的安全声明 —— 两台机器各自从黄金起点开同一 session 的空文档也能
/// 安全合并(根容器按名收敛)。这里让两边真的各写各的再互推。
#[test]
fn both_sides_can_start_from_the_golden_ancestor_and_merge() {
    let host_dir = tempfile::tempdir().unwrap();
    let viewer_dir = tempfile::tempdir().unwrap();
    let host = core(&host_dir);
    let viewer = core(&viewer_dir);

    let session = "sess-golden";
    let code = host
        .start_sharing(None, Some(session.into()), false)
        .unwrap();
    host.enable_document_sync().unwrap();
    viewer.join_share(code).unwrap();
    assert!(wait_until(10, || host.room_members().len() >= 2));

    // 两边同时从零起步:观看端先写,宿主后写。
    viewer
        .shared_session_insert_annotation(
            session.into(),
            0,
            "note-viewer".into(),
            "观看端先写".into(),
        )
        .unwrap();
    host.shared_session_insert_annotation(session.into(), 0, "note-host".into(), "宿主后写".into())
        .unwrap();

    // 两边都应当收敛到同样的两条批注(顺序由 CRDT 决定,内容集合一致)。
    let both = |core: &ZulangueCore| {
        core.shared_session_blocks(session.into())
            .map(|blocks| {
                let texts: Vec<_> = blocks.iter().map(|b| b.text.clone()).collect();
                texts.contains(&"观看端先写".to_string()) && texts.contains(&"宿主后写".to_string())
            })
            .unwrap_or(false)
    };
    assert!(wait_until(10, || both(&host)), "宿主应当合并进观看端的批注");
    assert!(
        wait_until(10, || both(&viewer)),
        "观看端应当合并进宿主的批注"
    );

    // 收敛后两边文本集合一致 —— 不是各自表述。
    let texts = |core: &ZulangueCore| {
        let mut t: Vec<String> = core
            .shared_session_blocks(session.into())
            .unwrap()
            .iter()
            .map(|b| b.text.clone())
            .collect();
        t.sort();
        t
    };
    assert!(
        wait_until(10, || texts(&host) == texts(&viewer)),
        "两边最终必须一字不差"
    );

    host.stop_sharing().unwrap();
    viewer.stop_sharing().unwrap();
}

/// Notebook 范围 v1 是字幕-only:观看端必须拒收一切文档。
///
/// 入册清单为空,接受成员自报的 id 会打开 bridge 键位抢占面
/// (share-p2p.md §11)。这里锁的是:宿主就算推了,观看端也一份不落盘。
#[test]
fn notebook_scope_rooms_stay_captions_only() {
    let host_dir = tempfile::tempdir().unwrap();
    let viewer_dir = tempfile::tempdir().unwrap();
    let host = core(&host_dir);
    let viewer = core(&viewer_dir);

    let code = host
        .start_sharing(Some("nb-1".into()), None, false)
        .unwrap();
    host.enable_document_sync().unwrap();
    viewer.join_share(code).unwrap();
    assert!(wait_until(10, || host.room_members().len() >= 2));

    // 宿主往一份 session 文档里写东西并发布。观看端的范围判定应当拒收。
    host.shared_session_insert_annotation("sess-nb".into(), 0, "note-1".into(), "不该出去".into())
        .unwrap();

    // 给传播留时间,然后断言观看端什么都没落盘。
    std::thread::sleep(Duration::from_millis(1_500));
    assert!(
        viewer.list_shared_sessions().is_empty(),
        "Notebook 范围的房间里,观看端不得落盘任何文档 —— v1 只有字幕"
    );

    host.stop_sharing().unwrap();
    viewer.stop_sharing().unwrap();
}

/// 删了副本再进同一个房间,催缺把它再拉回来。
///
/// 删除只删本机副本;房间还开着、宿主手里还有 —— 重新加入后应当能
/// 再收一遍,而且从黄金起点重开的文档与宿主的历史安全合并。
#[test]
fn a_deleted_copy_can_be_received_again() {
    let host_dir = tempfile::tempdir().unwrap();
    let viewer_dir = tempfile::tempdir().unwrap();
    let host = core(&host_dir);
    let viewer = core(&viewer_dir);

    let session = "sess-again";
    let code = host
        .start_sharing(None, Some(session.into()), false)
        .unwrap();
    host.enable_document_sync().unwrap();

    viewer.join_share(code.clone()).unwrap();
    host.shared_session_insert_annotation(session.into(), 0, "note-1".into(), "第一稿".into())
        .unwrap();
    assert!(wait_until(10, || {
        !viewer.list_shared_sessions().is_empty()
    }));

    // 离房 → 删副本 → 重进同一个房间。
    viewer.stop_sharing().unwrap();
    viewer.delete_shared_session(session.into()).unwrap();
    assert!(viewer.list_shared_sessions().is_empty());

    viewer.join_share(code).unwrap();
    assert!(
        wait_until(10, || {
            viewer
                .shared_session_blocks(session.into())
                .map(|blocks| blocks.iter().any(|b| b.text == "第一稿"))
                .unwrap_or(false)
        }),
        "重新加入后,催缺应当把删掉的副本再拉回来"
    );

    host.stop_sharing().unwrap();
    viewer.stop_sharing().unwrap();
}

/// 上一场的「已结束」不得污染下一场。
///
/// 主持人停止(观看端看到 hostLeft)后再开新一场,观看端用新码加入 ——
/// 状态必须是干净的「已加入」,不是残留的「已结束」。
#[test]
fn a_new_room_resets_the_ended_state() {
    let host_dir = tempfile::tempdir().unwrap();
    let viewer_dir = tempfile::tempdir().unwrap();
    let host = core(&host_dir);
    let viewer = core(&viewer_dir);

    // 第一场:开、进、散。
    let code1 = host
        .start_sharing(None, Some("sess-one".into()), false)
        .unwrap();
    viewer.join_share(code1).unwrap();
    assert!(wait_until(10, || host.room_members().len() >= 2));
    host.stop_sharing().unwrap();
    assert!(
        wait_until(10, || viewer.share_state().host_left),
        "第一场散了,观看端应当看到已结束"
    );
    viewer.stop_sharing().unwrap();

    // 第二场:新码新房。
    let code2 = host
        .start_sharing(None, Some("sess-two".into()), false)
        .unwrap();
    viewer.join_share(code2).unwrap();
    let state = viewer.share_state();
    assert!(state.is_viewing);
    assert!(
        !state.host_left,
        "新一场的状态必须干净 —— 上一场的「已结束」不得残留"
    );

    host.stop_sharing().unwrap();
    viewer.stop_sharing().unwrap();
}
