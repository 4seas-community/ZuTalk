//! 复现「朋友点了加入，什么也没发生」。
//!
//! 走真实的 FFI 路径:两个 core、真实端点、真实分享码。要回答的是——
//! joinShare 是抛错了,还是成功了却没东西可看?

use vt_ffi::ZulangueCore;

fn core(dir: &tempfile::TempDir) -> ZulangueCore {
    ZulangueCore::new_for_test(dir.path().to_string_lossy().to_string()).unwrap()
}

#[test]
fn joining_with_a_valid_code_reports_a_usable_state() {
    let host_dir = tempfile::tempdir().unwrap();
    let viewer_dir = tempfile::tempdir().unwrap();
    let host = core(&host_dir);
    let viewer = core(&viewer_dir);

    // 主持人开始共享,拿到分享码。
    let code = host
        .start_sharing(Some("nb-1".into()), None, false)
        .expect("开始共享应当成功");
    assert!(
        code.starts_with("zulangueshare"),
        "分享码格式: {}",
        &code[..20.min(code.len())]
    );

    // 朋友粘贴分享码加入。
    match viewer.join_share(code) {
        Ok(()) => {}
        Err(error) => panic!("加入失败,而界面上看不到任何提示: {error}"),
    }

    let state = viewer.share_state();
    eprintln!(
        "加入后: is_sharing={} is_viewing={} is_host={} lines={} revision={:?}",
        state.is_sharing,
        state.is_viewing,
        state.is_host,
        state.lines.len(),
        state.applied_revision
    );
    assert!(state.is_viewing, "加入后应当处于观看状态");

    // 主持人没在录音 —— 所以没有任何字幕。以前界面对此一言不发,
    // 现在这个组合必须能被区分出来:已连上,但对方还没开始。
    assert!(state.lines.is_empty());
    assert_eq!(
        state.applied_revision, None,
        "还没收到帧;界面据此显示「已加入 — 等待主持人」"
    );

    // 主持人那边同样要能区分「共享开着」和「真的在播」。
    let host_state = host.share_state();
    assert!(host_state.is_host);
    assert_eq!(
        host_state.broadcast_revision, None,
        "还没录音就不该显示成正在广播"
    );
}

/// 分享码必须能从核心取回,不能只活在界面的内存里。
///
/// 以前它只存在 Swift 的一个私有变量里:切走标签页再回来就没了,而「正在共享」
/// 还亮着,复制按钮于是静默失效 —— 用户再也没有办法把码交出去。
#[test]
fn the_share_code_survives_a_view_being_recreated() {
    let dir = tempfile::tempdir().unwrap();
    let host = core(&dir);
    assert_eq!(host.current_share_code(), None, "没共享时不该有码");

    let issued = host
        .start_sharing(Some("nb-1".into()), None, false)
        .unwrap();
    assert_eq!(
        host.current_share_code().as_deref(),
        Some(issued.as_str()),
        "界面重建后必须还能取回同一个分享码"
    );

    host.stop_sharing().unwrap();
    assert_eq!(host.current_share_code(), None, "停止后不该再交出码");
}

/// 录音条上的共享指示器必须说真话:在共享范围内亮、不在时灭、静音后变灰。
///
/// 判定与 `ShareCaptionTap::broadcast` 同一份 —— 这里锁住的是 FFI 查询那一半。
#[test]
fn the_broadcast_status_matches_the_share_scope() {
    use vt_ffi::FfiSessionBroadcastStatus;

    let dir = tempfile::tempdir().unwrap();
    let host = core(&dir);

    // 没在共享:任何录音都不该亮指示器。
    assert_eq!(
        host.session_broadcast_status("nb-1".into(), "sess-1".into()),
        FfiSessionBroadcastStatus::NotShared
    );

    // 共享整本 nb-1:其中的录音在播,别的 Notebook 不在。
    host.start_sharing(Some("nb-1".into()), None, false)
        .unwrap();
    assert_eq!(
        host.session_broadcast_status("nb-1".into(), "sess-1".into()),
        FfiSessionBroadcastStatus::Broadcasting
    );
    assert_eq!(
        host.session_broadcast_status("nb-2".into(), "sess-2".into()),
        FfiSessionBroadcastStatus::NotShared,
        "共享着 nb-1,在 nb-2 里录音不该显示成在共享"
    );

    // 一键静音只影响这一段,松开就恢复。
    host.set_session_broadcast_muted("sess-1".into(), true);
    assert_eq!(
        host.session_broadcast_status("nb-1".into(), "sess-1".into()),
        FfiSessionBroadcastStatus::Muted
    );
    host.set_session_broadcast_muted("sess-1".into(), false);
    assert_eq!(
        host.session_broadcast_status("nb-1".into(), "sess-1".into()),
        FfiSessionBroadcastStatus::Broadcasting
    );

    // 停止共享后指示器灭,静音清单也不跨共享残留。
    host.set_session_broadcast_muted("sess-1".into(), true);
    host.stop_sharing().unwrap();
    assert_eq!(
        host.session_broadcast_status("nb-1".into(), "sess-1".into()),
        FfiSessionBroadcastStatus::NotShared
    );
    host.start_sharing(Some("nb-1".into()), None, false)
        .unwrap();
    assert_eq!(
        host.session_broadcast_status("nb-1".into(), "sess-1".into()),
        FfiSessionBroadcastStatus::Broadcasting,
        "上一场共享的静音不该带进下一场"
    );
    host.stop_sharing().unwrap();
}

/// 主持人停止共享后,观看端要能看出「这场已结束」。
///
/// 以前观看端的状态机只有「等第一帧」和「接收中」两态:主持人走了,画面
/// 定格在最后一帧,永远显示「Receiving captions」—— 和网络卡死无法区分。
#[test]
fn a_viewer_sees_the_host_leave() {
    let host_dir = tempfile::tempdir().unwrap();
    let viewer_dir = tempfile::tempdir().unwrap();
    let host = core(&host_dir);
    let viewer = core(&viewer_dir);

    let code = host
        .start_sharing(None, Some("sess-1".into()), false)
        .unwrap();
    viewer.join_share(code).unwrap();
    assert!(!viewer.share_state().host_left, "主持人还在,不该显示已结束");

    // 等 gossip 网格先立起来:道别只送达已经连上的人,不重发。
    // 现实里主持人总是先看到有人在房间里,然后才结束 —— 测试同序。
    let mut connected = false;
    for _ in 0..200 {
        if host.room_members().len() >= 2 {
            connected = true;
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(50));
    }
    assert!(connected, "观看端应当先出现在主持人的房间名册里");

    // stop_sharing 先道别再拆房间;Goodbye 经 gossip 送达要一点时间。
    host.stop_sharing().unwrap();
    let mut left = false;
    for _ in 0..200 {
        if viewer.share_state().host_left {
            left = true;
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(50));
    }
    assert!(left, "主持人停止后,观看端必须能看出这场已经散了");

    // 观看端自己退出,状态回到干净的未共享。
    viewer.stop_sharing().unwrap();
    assert!(!viewer.share_state().host_left);
}

/// 收到的内容有固定的家,而且这个家是幂等创建的。
#[test]
fn the_shared_inbox_notebook_is_created_once() {
    let dir = tempfile::tempdir().unwrap();
    let core = core(&dir);
    let first = core.shared_inbox_notebook().unwrap();
    let second = core.shared_inbox_notebook().unwrap();
    assert_eq!(first.id, second.id, "不该每次都新建一个");
    assert_eq!(first.title, "分享");
}

/// 收到的转录稿能删,而且只删本机副本。
///
/// 对一个隐私敏感的产品,「收到了但删不掉」是个洞:台账即目录,
/// 删除 = 文件消失 + 内存痕迹清空,幂等。
#[test]
fn a_received_transcript_can_be_deleted_locally() {
    let dir = tempfile::tempdir().unwrap();
    let core = core(&dir);

    // 插一条批注就会物化这份共享文档(ensure → 动词 → 落盘)。
    core.shared_session_insert_annotation("sess-del".into(), 0, "note-1".into(), "记一笔".into())
        .unwrap();
    let listed = core.list_shared_sessions();
    assert_eq!(listed.len(), 1);
    assert!(
        listed[0].received_at_epoch > 0,
        "收到时间取文件 mtime,不该是 0"
    );

    core.delete_shared_session("sess-del".into()).unwrap();
    assert!(
        core.list_shared_sessions().is_empty(),
        "台账即目录:文件没了记录就没了"
    );
    // 幂等:重复删除不抛错。
    core.delete_shared_session("sess-del".into()).unwrap();
}

/// 坏掉的分享码要抛错 —— 界面靠这个错误才有话可说。
#[test]
fn a_damaged_code_reports_an_error_instead_of_doing_nothing() {
    let dir = tempfile::tempdir().unwrap();
    let core = core(&dir);
    assert!(core
        .join_share("zulangueshare-not-a-real-code".into())
        .is_err());
    assert!(core.join_share(String::new()).is_err());
}

/// 昵称存在本机,重开也在;房间里的人靠它认出彼此。
#[test]
fn a_nickname_is_remembered_and_cleaned() {
    let dir = tempfile::tempdir().unwrap();
    let core = core(&dir);
    assert_eq!(core.share_display_name(), "", "默认没有昵称");

    core.set_share_display_name("  楼下的 Mac  ".into())
        .unwrap();
    assert_eq!(core.share_display_name(), "楼下的 Mac", "首尾空白要去掉");

    // 昵称会被广播给房间里每个人,所以控制字符不能留。
    core.set_share_display_name("坏人\n主持人批准了".into())
        .unwrap();
    assert_eq!(core.share_display_name(), "坏人主持人批准了");
}

/// 开始共享之后,自己就在房间成员里 —— 以前这里是空的,因为从没进过 gossip 房间。
#[test]
fn the_host_appears_in_its_own_room() {
    let dir = tempfile::tempdir().unwrap();
    let core = core(&dir);
    core.set_share_display_name("主持人".into()).unwrap();
    assert!(core.room_members().is_empty(), "没共享时房间是空的");

    core.start_sharing(Some("nb-1".into()), None, false)
        .unwrap();
    let members = core.room_members();
    assert_eq!(members.len(), 1, "主持人应当在自己的房间里");
    assert!(members[0].is_me);
    assert!(members[0].is_host);
    assert_eq!(members[0].display_name, "主持人");

    core.stop_sharing().unwrap();
    assert!(core.room_members().is_empty(), "停止后房间要清空");
}
