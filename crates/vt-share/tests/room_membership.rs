//! 三个真实 endpoint 组成的房间。
//!
//! 这是「大家在同一个 Wi-Fi 下，主持人的字幕铺到每台机器」那个场景的最小可验证
//! 形态：主持人开房，两位观看者用同一份分享码加入，主持人的名册最终把三个人都
//! 认出来。
//!
//! 全程无中继、无公共发现服务 —— 与会议室断网时的行为一致。

use std::time::Duration;

use vt_share::{
    RoomSecret, ScopeId, ShareCode, ShareEndpoint, ShareEndpointConfig, ShareIdentity, WritePolicy,
};

async fn endpoint() -> (ShareEndpoint, ShareIdentity) {
    let identity = ShareIdentity::generate();
    let endpoint = ShareEndpoint::bind(&identity, ShareEndpointConfig::default())
        .await
        .expect("离线绑定应当成功");
    (endpoint, identity)
}

/// 轮询等待名册涨到 `want` 人，避免依赖固定 sleep 造成偶发失败。
async fn wait_for_members(room: &vt_share::net::RoomHandle, want: usize) -> usize {
    let mut seen = 0;
    for _ in 0..200 {
        seen = room.member_count().await;
        if seen >= want {
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    seen
}

fn scope() -> ScopeId {
    ScopeId::Session {
        session_id: "room-test".into(),
    }
}

#[tokio::test]
async fn host_roster_converges_on_every_viewer_that_joined() {
    let (host, _host_id) = endpoint().await;
    let (viewer_a, _a) = endpoint().await;
    let (viewer_b, _b) = endpoint().await;

    let code = ShareCode::new(
        host.endpoint_addr().await,
        scope(),
        RoomSecret::generate(),
        WritePolicy::Everyone,
    );

    // 主持人先开房，观看者以主持人为 bootstrap 加入。
    let host_room = host.join_room(&code, vec![]).await.unwrap();
    let host_id = host.endpoint_id();
    let _room_a = viewer_a.join_room(&code, vec![host_id]).await.unwrap();
    let _room_b = viewer_b.join_room(&code, vec![host_id]).await.unwrap();

    let seen = wait_for_members(&host_room, 3).await;
    assert_eq!(seen, 3, "主持人的名册应当收敛到三个人，实际 {seen}");

    let roster = host_room.roster().await;
    assert!(roster.is_member(viewer_a.endpoint_id()));
    assert!(roster.is_member(viewer_b.endpoint_id()));
    assert!(roster.is_member(host_id));

    host.shutdown().await;
    viewer_a.shutdown().await;
    viewer_b.shutdown().await;
}

/// 只读房间里，观看者写不进文档 —— 策略随名册一起传播到每个接收端。
#[tokio::test]
async fn host_only_policy_reaches_the_viewers() {
    let (host, _h) = endpoint().await;
    let (viewer, _v) = endpoint().await;

    let code = ShareCode::new(
        host.endpoint_addr().await,
        scope(),
        RoomSecret::generate(),
        WritePolicy::HostOnly,
    );

    let host_room = host.join_room(&code, vec![]).await.unwrap();
    let viewer_room = viewer
        .join_room(&code, vec![host.endpoint_id()])
        .await
        .unwrap();

    wait_for_members(&host_room, 2).await;

    // 观看者从分享码就知道策略，不必等名册。
    let roster = viewer_room.roster().await;
    assert_eq!(roster.policy(), WritePolicy::HostOnly);
    assert!(!roster.may_write(viewer.endpoint_id()));
    assert!(roster.may_write(host.endpoint_id()));

    host.shutdown().await;
    viewer.shutdown().await;
}

/// 换一个 room_secret 就是换一个房间：拿旧分享码的人进不来。
///
/// 这是「停止共享」的全部机制 —— 它只挡后续，删不掉对方已经收到的内容。
#[tokio::test]
async fn rotating_the_room_secret_locks_out_the_old_code() {
    let (host, _h) = endpoint().await;
    let (stale, _s) = endpoint().await;

    let host_addr = host.endpoint_addr().await;
    let old_code = ShareCode::new(
        host_addr.clone(),
        scope(),
        RoomSecret::generate(),
        WritePolicy::Everyone,
    );
    let rotated = ShareCode::new(
        host_addr,
        scope(),
        RoomSecret::generate(),
        WritePolicy::Everyone,
    );
    assert_ne!(old_code.topic_id(), rotated.topic_id());

    // 主持人换到新房间，老成员还拿着旧分享码。
    let host_room = host.join_room(&rotated, vec![]).await.unwrap();
    let _stale_room = stale
        .join_room(&old_code, vec![host.endpoint_id()])
        .await
        .unwrap();

    tokio::time::sleep(Duration::from_millis(600)).await;
    let roster = host_room.roster().await;
    assert!(
        !roster.is_member(stale.endpoint_id()),
        "拿旧分享码的成员不该出现在新房间的名册里"
    );

    host.shutdown().await;
    stale.shutdown().await;
}
