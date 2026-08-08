//! 分享 UX 的端到端叙事:界面上每一块屏幕读到的东西,在这里逐站核实。
//!
//! 两个真实 core、真实端点、真实分享码,按用户实际经历的顺序走完一整场:
//! 开始共享 → 加入 → 名册收敛(带链路诊断)→ 主持人物化文档 → 观看端
//! 收到副本 → 协同订正收敛回主持人 → 录音条指示器/静音 → 主持人停止 →
//! 观看端看到「已结束」→ 副本留存 → 删除。再加一场只读房间,证明
//! HostOnly 下观看端的订正到不了主持人。
//!
//! 这不是单元测试的重复:单元测试各锁一站,这里锁的是**站与站之间的接缝**。

use std::time::Duration;

use vt_ffi::ZulangueCore;

fn core(dir: &tempfile::TempDir) -> ZulangueCore {
    ZulangueCore::new_for_test(dir.path().to_string_lossy().to_string()).unwrap()
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

    // ── 第一站:主持人按「单条录音」开始共享(对方保留一份的模式)。
    let session = "sess-e2e";
    let code = host
        .start_sharing(None, Some(session.into()), false)
        .expect("开始共享");
    host.enable_document_sync().expect("武装文档协同");

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

    // ── 第四站:录音条指示器的判定面。这场共享只覆盖 sess-e2e。
    use vt_ffi::FfiSessionBroadcastStatus as B;
    assert_eq!(
        host.session_broadcast_status("nb-any".into(), session.into()),
        B::Broadcasting
    );
    assert_eq!(
        host.session_broadcast_status("nb-any".into(), "other-session".into()),
        B::NotShared,
        "别的录音不在范围内,指示器不得亮"
    );
    host.set_session_broadcast_muted(session.into(), true);
    assert_eq!(
        host.session_broadcast_status("nb-any".into(), session.into()),
        B::Muted
    );
    host.set_session_broadcast_muted(session.into(), false);

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
    assert!(
        viewer
            .list_shared_sessions()
            .iter()
            .any(|info| info.session_id == session),
        "散场后副本仍在 —— 这正是「对方保留一份」的承诺"
    );
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
    let code = host
        .start_sharing(None, Some(session.into()), true)
        .unwrap();
    host.enable_document_sync().unwrap();
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
