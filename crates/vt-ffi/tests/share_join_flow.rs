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
