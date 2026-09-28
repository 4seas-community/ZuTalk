//! 两个真实 endpoint 之间的字幕往返。
//!
//! 这些测试不打桩传输层:它们真的绑两个 iroh endpoint、真的走 QUIC。设计里最容易
//! 出错的假设都在这里被验证 —— 每帧一条 uni-stream 能否承载超过 datagram 上限的
//! 帧、丢帧后接收端会不会卡住、乱序旧帧会不会把画面倒回去。
//!
//! 全程无中继、无发现服务:直接用对方的 `EndpointAddr` 配对,与局域网断网场景一致。
//!
//! 字幕通道只服务房间名册里的人,所以每条往返测试都先让两端拿同一份码进房。

use std::time::Duration;

use vt_share::net::{receive_captions, CaptionInbox, RoomHandle};
use vt_share::{
    CaptionFrame, CaptionLine, CaptionReceiver, FrameOutcome, RoomSecret, ScopeId, ShareCode,
    ShareEndpoint, ShareEndpointConfig, ShareIdentity, WritePolicy,
};

fn scope() -> ScopeId {
    ScopeId::Session {
        session_id: "round-trip".into(),
    }
}

fn line(text: &str) -> CaptionLine {
    CaptionLine {
        speaker: Some("spk-1".into()),
        source_language: "ja".into(),
        source_text: text.into(),
        target_language: Some("zh-Hans".into()),
        target_text: Some(format!("译:{text}")),
        completion: "partial".into(),
    }
}

fn frame(revision: u64, lines: Vec<CaptionLine>) -> CaptionFrame {
    CaptionFrame::flat(scope(), revision, lines)
}

async fn endpoint() -> ShareEndpoint {
    ShareEndpoint::bind(&ShareIdentity::generate(), ShareEndpointConfig::default())
        .await
        .expect("离线绑定应当成功")
}

/// 主持人开房,观看端拿码进房。房间句柄要活到测试结束 —— 丢掉它,
/// 字幕通道就不再认这个名册。
async fn paired_room(
    host: &ShareEndpoint,
    viewer: &ShareEndpoint,
) -> (RoomHandle, RoomHandle, ShareCode) {
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
    (host_room, viewer_room, code)
}

/// 等到观看端过了名册这道门、真的挂上了字幕通道。之前广播的帧没有人收。
async fn wait_for_watcher(host: &ShareEndpoint, viewer: iroh::EndpointId) -> bool {
    for _ in 0..200 {
        if host.caption_watchers().iter().any(|(id, _)| *id == viewer) {
            return true;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    false
}

/// 轮询等待 inbox 收满 `want` 帧,避免依赖固定 sleep 造成的偶发失败。
async fn collect(inbox: &CaptionInbox, want: usize) -> Vec<CaptionFrame> {
    let mut got = Vec::new();
    for _ in 0..200 {
        got.extend(inbox.drain().await);
        if got.len() >= want {
            break;
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    got
}

#[tokio::test]
async fn caption_frame_crosses_two_real_endpoints() {
    let host = endpoint().await;
    let viewer = endpoint().await;
    let viewer_id = viewer.endpoint_id();
    let (_host_room, _viewer_room, code) = paired_room(&host, &viewer).await;
    let inbox = CaptionInbox::default();

    let listening = {
        let inbox = inbox.clone();
        tokio::spawn(async move { receive_captions(&viewer, code, inbox).await })
    };

    assert!(
        wait_for_watcher(&host, viewer_id).await,
        "观看端应当进得了字幕通道"
    );
    host.broadcast_caption(frame(1, vec![line("こんにちは")]));

    let got = collect(&inbox, 1).await;
    assert_eq!(got.len(), 1, "接收端应当收到一帧");
    assert_eq!(got[0].preview_revision, 1);
    assert_eq!(got[0].lines[0].source_text, "こんにちは");
    assert_eq!(
        got[0].lines[0].target_text.as_deref(),
        Some("译:こんにちは")
    );
    // 链路指示是真值:同机双端点无中继,收到帧后必然报「直连」。
    assert_eq!(
        inbox.link_path(),
        Some(vt_share::net::CaptionLinkPath::Direct),
        "同机直连必须报 Direct,而不是写死或缺席"
    );

    listening.abort();
    host.shutdown().await;
}

/// 一帧远超 QUIC datagram 上限(约 1.2 KB)也必须完整送达。
///
/// 这正是设计从 datagram 改为「每帧一条 uni-stream」的原因:八行多语言字幕在
/// 中日泰 UTF-8 下轻易过万字节,datagram 根本装不下。
#[tokio::test]
async fn frame_far_larger_than_a_datagram_survives() {
    let host = endpoint().await;
    let viewer = endpoint().await;
    let viewer_id = viewer.endpoint_id();
    let (_host_room, _viewer_room, code) = paired_room(&host, &viewer).await;
    let inbox = CaptionInbox::default();

    let listening = {
        let inbox = inbox.clone();
        tokio::spawn(async move { receive_captions(&viewer, code, inbox).await })
    };
    assert!(
        wait_for_watcher(&host, viewer_id).await,
        "观看端应当进得了字幕通道"
    );

    // 八行 × 每行约 2 KB 的日文正文,序列化后远超一个 QUIC 包。
    let bulky: Vec<CaptionLine> = (0..8)
        .map(|i| line(&format!("{i}{}", "これは長い字幕の行です。".repeat(80))))
        .collect();
    let payload = serde_json::to_vec(&frame(7, bulky.clone())).unwrap();
    assert!(
        payload.len() > 16 * 1024,
        "测试样本必须真的超过 datagram 上限,实际 {} 字节",
        payload.len()
    );

    host.broadcast_caption(frame(7, bulky));

    let got = collect(&inbox, 1).await;
    assert_eq!(got.len(), 1, "超大帧应当完整送达");
    assert_eq!(got[0].lines.len(), 8);
    assert!(got[0].lines[3].source_text.len() > 2000);

    listening.abort();
    host.shutdown().await;
}

/// 连发多帧后,接收端投影应当停在最新的一帧上。
///
/// 中途丢帧是允许的(广播端对慢接收者丢帧而非背压),所以断言的是「最终收敛到最新」,
/// 不是「一帧不落」—— 后者不是这条通道承诺的性质。
#[tokio::test]
async fn projection_converges_on_the_newest_frame() {
    let host = endpoint().await;
    let viewer = endpoint().await;
    let viewer_id = viewer.endpoint_id();
    let (_host_room, _viewer_room, code) = paired_room(&host, &viewer).await;
    let inbox = CaptionInbox::default();

    let listening = {
        let inbox = inbox.clone();
        tokio::spawn(async move { receive_captions(&viewer, code, inbox).await })
    };
    assert!(
        wait_for_watcher(&host, viewer_id).await,
        "观看端应当进得了字幕通道"
    );

    for revision in 1..=12u64 {
        host.broadcast_caption(frame(revision, vec![line(&format!("行 {revision}"))]));
        tokio::time::sleep(Duration::from_millis(15)).await;
    }

    let got = collect(&inbox, 1).await;
    assert!(!got.is_empty(), "至少应当收到一帧");

    // 无论收到几帧、以什么顺序到达,投影都必须落在见过的最大 revision 上。
    let mut projection = CaptionReceiver::new();
    let highest = got.iter().map(|f| f.preview_revision).max().unwrap();
    for f in got {
        projection.accept(f, &scope());
    }
    assert_eq!(projection.applied_revision(), Some(highest));
    assert_eq!(projection.lines()[0].source_text, format!("行 {highest}"));

    listening.abort();
    host.shutdown().await;
}

/// 属于另一个共享范围的帧不得进入本房间的投影。
#[tokio::test]
async fn frames_from_another_scope_are_filtered_in_transit() {
    let host = endpoint().await;
    let viewer = endpoint().await;
    let viewer_id = viewer.endpoint_id();
    let (_host_room, _viewer_room, code) = paired_room(&host, &viewer).await;
    let inbox = CaptionInbox::default();

    let listening = {
        let inbox = inbox.clone();
        tokio::spawn(async move { receive_captions(&viewer, code, inbox).await })
    };
    assert!(
        wait_for_watcher(&host, viewer_id).await,
        "观看端应当进得了字幕通道"
    );

    let mut foreign = frame(1, vec![line("别人的会议")]);
    foreign.scope = ScopeId::Session {
        session_id: "somebody-else".into(),
    };
    host.broadcast_caption(foreign);
    host.broadcast_caption(frame(2, vec![line("我们的会议")]));

    let got = collect(&inbox, 1).await;
    assert!(
        got.iter().all(|f| f.scope == scope()),
        "跨范围的帧必须在传输层就被丢掉"
    );

    listening.abort();
    host.shutdown().await;
}

/// 没拿到码的人直接拨主持人的字幕通道,什么也收不到。
///
/// 公钥是公开的 —— 局域网 mDNS 一直在广播它。以前字幕通道谁拨都给,
/// 分享码与「请求加入 → 批准」形同虚设。
#[tokio::test]
async fn a_stranger_without_the_code_receives_nothing() {
    let host = endpoint().await;
    let viewer = endpoint().await;
    let stranger = endpoint().await;
    let (_host_room, _viewer_room, code) = paired_room(&host, &viewer).await;

    // 知道主持人在哪、在共享什么,只是没有那份码。
    let guessed = ShareCode::new(
        code.host.clone(),
        code.scope.clone(),
        RoomSecret::generate(),
        code.policy,
    );
    let inbox = CaptionInbox::default();
    let listening = {
        let inbox = inbox.clone();
        tokio::spawn(async move { receive_captions(&stranger, guessed, inbox).await })
    };

    for revision in 1..=20u64 {
        host.broadcast_caption(frame(revision, vec![line("内部会议")]));
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert!(
        inbox.drain().await.is_empty(),
        "不在名册里的人不该收到任何一帧"
    );
    assert!(host.caption_watchers().is_empty(), "陌生人不该挂上字幕通道");

    listening.abort();
    host.shutdown().await;
}

/// 主持人移出一位观看者:当场断开,之后再连也进不来,观看端知道自己被移出了。
#[tokio::test]
async fn a_removed_viewer_is_cut_off_and_stays_out() {
    let host = endpoint().await;
    let viewer = endpoint().await;
    let viewer_id = viewer.endpoint_id();
    let (host_room, _viewer_room, code) = paired_room(&host, &viewer).await;
    let inbox = CaptionInbox::default();
    let listening = {
        let inbox = inbox.clone();
        tokio::spawn(async move { receive_captions(&viewer, code, inbox).await })
    };
    assert!(wait_for_watcher(&host, viewer_id).await);
    host.broadcast_caption(frame(1, vec![line("移出之前")]));
    assert_eq!(collect(&inbox, 1).await.len(), 1);

    assert!(host.remove_member(&host_room, viewer_id).await);
    assert!(!host_room.roster().await.is_member(viewer_id));

    let mut noticed = false;
    for _ in 0..100 {
        if inbox.removed() {
            noticed = true;
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert!(noticed, "观看端应当知道自己被移出了,而不是一直重连");

    for revision in 2..=10u64 {
        host.broadcast_caption(frame(revision, vec![line("移出之后")]));
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert!(
        inbox.drain().await.iter().all(|f| f.preview_revision < 2),
        "移出之后的帧不该再到达"
    );

    listening.abort();
    host.shutdown().await;
}

/// 说话的间隙加入的人,马上看到最近一帧 —— 不必等下一句话才知道自己连上了。
#[tokio::test]
async fn a_late_viewer_sees_the_latest_frame_at_once() {
    let host = endpoint().await;
    let viewer = endpoint().await;
    let (_host_room, _viewer_room, code) = paired_room(&host, &viewer).await;

    let mut titled = frame(4, vec![line("さっきの話")]);
    titled.share = Some(vt_share::ShareHeader {
        title: "周会".into(),
        host_name: "楼下的 Mac".into(),
        live: true,
        keeps_copies: false,
    });
    host.broadcast_caption(titled);

    let inbox = CaptionInbox::default();
    let listening = {
        let inbox = inbox.clone();
        tokio::spawn(async move { receive_captions(&viewer, code, inbox).await })
    };
    let got = collect(&inbox, 1).await;
    assert_eq!(got.len(), 1, "晚进来的人应当立即收到最近一帧");
    assert_eq!(got[0].preview_revision, 4);
    assert_eq!(
        got[0].share.as_ref().map(|s| s.title.as_str()),
        Some("周会")
    );

    host.end_broadcast();
    listening.abort();
    host.shutdown().await;
}

/// 广播端在没有任何接收者时必须照常工作,且不阻塞。
///
/// 采集回调直接调用 `broadcast_caption`,它一旦阻塞就会拖住整条实时链路。
#[tokio::test]
async fn broadcasting_never_blocks_the_caller() {
    let host = endpoint().await;

    let started = std::time::Instant::now();
    for revision in 0..1000u64 {
        host.broadcast_caption(frame(revision, vec![line("x")]));
    }
    let elapsed = started.elapsed();

    assert!(
        elapsed < Duration::from_millis(500),
        "1000 帧广播耗时 {elapsed:?},说明发送路径存在阻塞"
    );
    host.shutdown().await;
}

/// 接收端只在内存里投影,`clear` 之后不留残影 —— 观看的是别人的内容,不落库。
#[tokio::test]
async fn viewer_projection_leaves_nothing_behind() {
    let mut projection = CaptionReceiver::new();
    assert_eq!(
        projection.accept(frame(3, vec![line("临时")]), &scope()),
        FrameOutcome::Applied
    );
    projection.clear();
    assert_eq!(projection.applied_revision(), None);
    assert!(projection.lines().is_empty());
}
