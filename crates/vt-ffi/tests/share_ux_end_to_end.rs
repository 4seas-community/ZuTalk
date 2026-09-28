//! 分享 UX 的端到端叙事:界面上每一块屏幕读到的东西,在这里逐站核实。
//!
//! 两个真实 core、真实端点、真实分享码,按用户实际经历的顺序走完一整场:
//! 共享一段录音 → 加入 → 名册收敛(带链路诊断)→ 主持人物化文档 → 观看端
//! 收到副本 → 协同订正收敛回主持人 → 主持人停止 → 观看端看到「已结束」→
//! 副本留存(记得是谁的哪一场)→ 删除。再加一场只读房间,证明 HostOnly 下
//! 观看端的订正到不了主持人;一场直播,证明默认什么都不留、允许后才留;
//! 以及被移出的人知道自己被移出了。
//!
//! 这不是单元测试的重复:单元测试各锁一站,这里锁的是**站与站之间的接缝**。

use std::time::Duration;

use vt_ffi::ZuTalkCore;

fn core(dir: &tempfile::TempDir) -> ZuTalkCore {
    ZuTalkCore::new_for_test(dir.path().to_string_lossy().to_string()).unwrap()
}

/// 轮询直到条件成立,最多等 `seconds` 秒。gossip 与 doc-sync 都是异步送达,
/// 固定 sleep 会偶发,轮询上限会立刻暴露真坏。
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

#[test]
fn a_full_share_session_from_start_to_deletion() {
    let host_dir = tempfile::tempdir().unwrap();
    let viewer_dir = tempfile::tempdir().unwrap();
    let host = core(&host_dir);
    let viewer = core(&viewer_dir);
    host.set_share_display_name("主持人".into()).unwrap();
    viewer.set_share_display_name("观看者".into()).unwrap();

    // ── 第一站:主持人共享一段录好的录音,对方可以订正。
    let session = "sess-e2e";
    let code = host
        .start_recording_share(session.into(), false)
        .expect("开始共享");

    // 分享码可以从核心再取一次 —— 界面重建后复制按钮仍然有效。
    assert_eq!(host.current_share_code().as_deref(), Some(code.as_str()));

    // ── 第二站:观看端粘码加入。
    viewer.join_share(code).expect("加入");
    let state = viewer.share_state();
    assert!(state.is_viewing);
    assert_eq!(
        state.scope_session_id.as_deref(),
        Some(session),
        "收件列表的按条锁定靠它认出当前房间那一份"
    );

    // ── 第三站:名册收敛,主持人看得见观看者。
    assert!(
        wait_until(10, || host.room_members().len() >= 2),
        "主持人的名册应当收敛到两个人"
    );
    let members = host.room_members();
    let watcher = members
        .iter()
        .find(|member| !member.is_me)
        .expect("名册里有观看者");
    assert_eq!(watcher.display_name, "观看者");

    // 链路诊断:观看端拨的是字幕通道,主持人应当能看到这条连接的链路。
    // 单机回环是直连;这里只断言「有答案」,不断言具体值 —— 值属于网络。
    assert!(
        wait_until(10, || {
            host.room_members()
                .iter()
                .any(|member| !member.is_me && member.link.is_some())
        }),
        "主持人应当看得到观看者的链路(直连/中继)"
    );

    // ── 第四站:观看端知道这是一段录好的录音,而且会留一份。
    assert!(
        wait_until(10, || {
            let state = viewer.share_state();
            state.host_name == "主持人" && !state.is_live && state.keeps_copies
        }),
        "观看端应当从主持人那里知道:谁的、录好的、会留一份"
    );

    // ── 第五站:主持人物化共享文档(界面动词:插批注),推给房间。
    host.shared_session_insert_annotation(session.into(), 0, "note-host".into(), "会前备注".into())
        .expect("主持人写入共享文档");

    // 观看端应当收到并落盘 —— 收件列表出现这一场。
    assert!(
        wait_until(10, || {
            viewer
                .list_shared_sessions()
                .iter()
                .any(|info| info.session_id == session && info.block_count >= 1)
        }),
        "观看端的收件列表应当出现这场录音的副本"
    );
    let received = viewer.list_shared_sessions();
    let entry = received
        .iter()
        .find(|info| info.session_id == session)
        .unwrap();
    assert!(entry.received_at_epoch > 0, "收到时间来自文件 mtime");

    // ── 第六站:观看端订正,Everyone 房间应当收敛回主持人。
    let blocks = viewer.shared_session_blocks(session.into()).unwrap();
    let block_id = blocks[0].id.clone();
    viewer
        .shared_session_replace_text(session.into(), block_id.clone(), "会前备注(已订正)".into())
        .expect("观看端订正");
    assert!(
        wait_until(10, || {
            host.shared_session_blocks(session.into())
                .map(|blocks| blocks.iter().any(|b| b.text == "会前备注(已订正)"))
                .unwrap_or(false)
        }),
        "全员可写的房间里,观看端的订正应当收敛回主持人"
    );

    // ── 第七站:主持人停止。观看端要能看出「这场已结束」。
    host.stop_sharing().unwrap();
    assert!(
        wait_until(10, || viewer.share_state().host_left),
        "主持人停止后,观看端必须能看出这场已经散了"
    );

    // ── 第八站:观看端离开。副本留下,随后可删,删了不再出现。
    viewer.stop_sharing().unwrap();
    let kept = viewer.list_shared_sessions();
    let kept = kept
        .iter()
        .find(|info| info.session_id == session)
        .expect("散场后副本仍在 —— 这正是「对方保留一份」的承诺");
    assert_eq!(kept.host_name, "主持人", "散场后也说得出是谁共享的");
    viewer.delete_shared_session(session.into()).unwrap();
    assert!(
        !viewer
            .list_shared_sessions()
            .iter()
            .any(|info| info.session_id == session),
        "删除后收件列表不再出现这一场"
    );
}

/// 只读房间:观看端的订正推不进主持人。
///
/// 这不是发送端强制 —— 观看端本地照样改得动(乐观编辑),但诚实的主持人
/// 按写入策略拒收。界面靠 host_only 禁入口避免造出这种孤儿编辑;这里锁的
/// 是即便入口被绕过,权限门也真的在。
#[test]
fn a_read_only_room_refuses_viewer_corrections_at_the_host() {
    let host_dir = tempfile::tempdir().unwrap();
    let viewer_dir = tempfile::tempdir().unwrap();
    let host = core(&host_dir);
    let viewer = core(&viewer_dir);

    let session = "sess-readonly";
    let code = host.start_recording_share(session.into(), true).unwrap();
    viewer.join_share(code).unwrap();

    let state = viewer.share_state();
    assert!(state.host_only, "观看端要知道这是只读房间,好禁掉编辑入口");

    assert!(wait_until(10, || host.room_members().len() >= 2));

    host.shared_session_insert_annotation(session.into(), 0, "note-ro".into(), "只读底稿".into())
        .unwrap();
    assert!(
        wait_until(10, || {
            viewer
                .list_shared_sessions()
                .iter()
                .any(|info| info.session_id == session && info.block_count >= 1)
        }),
        "只读房间照样收得到内容 —— 只读限制的是回写,不是接收"
    );

    // 观看端本地改动成功(P2P 无法阻止),但主持人拒收。
    let blocks = viewer.shared_session_blocks(session.into()).unwrap();
    let block_id = blocks[0].id.clone();
    viewer
        .shared_session_replace_text(session.into(), block_id, "越权订正".into())
        .expect("本地乐观编辑本身不报错");

    // 给推送留出时间,然后断言主持人那份**没有**变。
    std::thread::sleep(Duration::from_millis(1_500));
    let host_blocks = host.shared_session_blocks(session.into()).unwrap();
    assert!(
        host_blocks.iter().all(|b| b.text != "越权订正"),
        "HostOnly 房间的宿主必须拒收观看端的订正"
    );

    host.stop_sharing().unwrap();
    viewer.stop_sharing().unwrap();
}

/// 直播默认什么都不留:观看端边看边听,离开就没了。主持人允许之后才留,
/// 而且留下的那份记得是谁的哪一场。
#[test]
fn a_live_share_leaves_nothing_behind_unless_the_host_allows_it() {
    let host_dir = tempfile::tempdir().unwrap();
    let viewer_dir = tempfile::tempdir().unwrap();
    let host = core(&host_dir);
    let viewer = core(&viewer_dir);
    host.set_share_display_name("主持人".into()).unwrap();

    let session = "sess-live-keep";
    let code = host.start_live_share(session.into(), false).unwrap();
    viewer.join_share(code).unwrap();
    assert!(wait_until(10, || host.room_members().len() >= 2));

    // 主持人写了东西 —— 不允许留存时它哪儿也不去。
    host.shared_session_insert_annotation(session.into(), 0, "n1".into(), "现场笔记".into())
        .unwrap();
    std::thread::sleep(Duration::from_millis(1_500));
    let state = viewer.share_state();
    assert!(state.is_live && !state.keeps_copies);
    assert!(
        viewer.list_shared_sessions().is_empty(),
        "直播没允许留存,观看端的 ZuTalk 不该留下任何文字稿"
    );

    // 主持人打开「允许观看的人保存文字稿」:观看端重新去要,落下一份。
    host.allow_viewers_to_keep_copies().unwrap();
    host.shared_session_insert_annotation(session.into(), 1, "n2".into(), "允许之后".into())
        .unwrap();
    // 说明随下一帧到达;直播里帧是一直在来的。
    let preview = viewer_preview(session);
    assert!(
        wait_until(15, || {
            host.broadcast_live_preview_for_test(&preview);
            viewer.share_state().keeps_copies
                && viewer
                    .list_shared_sessions()
                    .iter()
                    .any(|info| info.session_id == session && info.block_count >= 1)
        }),
        "主持人允许之后,观看端应当收到并留下文字稿"
    );
    let kept = viewer.list_shared_sessions();
    assert_eq!(kept[0].host_name, "主持人");

    host.stop_sharing().unwrap();
    viewer.stop_sharing().unwrap();
}

/// 被移出的人知道自己被移出了,而且不再收到字幕。
#[test]
fn a_removed_viewer_is_told_so() {
    let host_dir = tempfile::tempdir().unwrap();
    let viewer_dir = tempfile::tempdir().unwrap();
    let host = core(&host_dir);
    let viewer = core(&viewer_dir);

    let code = host.start_live_share("sess-kick".into(), false).unwrap();
    viewer.join_share(code).unwrap();
    let viewer_id = viewer.share_identity().unwrap().endpoint_id;
    assert!(wait_until(10, || host.room_members().iter().any(
        |member| member.endpoint_id == viewer_id && member.link.is_some()
    )));

    assert!(host.remove_share_member(viewer_id.clone()).unwrap());
    assert!(
        wait_until(10, || viewer.share_state().removed_by_host),
        "观看端应当知道自己被移出了,而不是对着不动的字幕干等"
    );
    assert!(
        host.room_members()
            .iter()
            .all(|member| member.endpoint_id != viewer_id),
        "移出之后名册里不该再有他"
    );

    host.stop_sharing().unwrap();
    viewer.stop_sharing().unwrap();
}

fn viewer_preview(session: &str) -> vt_ffi::notebook_capture_api::FfiNotebookCaptureLivePreview {
    vt_ffi::notebook_capture_api::FfiNotebookCaptureLivePreview {
        session_id: session.into(),
        preview_revision: 1,
        utterances: Vec::new(),
        translation_cues: Vec::new(),
        lane_health: Vec::new(),
    }
}
