//! 两个真实 endpoint 之间的字幕往返。
//!
//! 这些测试不打桩传输层:它们真的绑两个 iroh endpoint、真的走 QUIC。设计里最容易
//! 出错的假设都在这里被验证 —— 每帧一条 uni-stream 能否承载超过 datagram 上限的
//! 帧、丢帧后接收端会不会卡住、乱序旧帧会不会把画面倒回去。
//!
//! 全程无中继、无发现服务:直接用对方的 `EndpointAddr` 配对,与局域网断网场景一致。

use std::time::Duration;

use vt_share::net::{receive_captions, CaptionInbox};
use vt_share::{
    CaptionFrame, CaptionLine, CaptionReceiver, FrameOutcome, ScopeId, ShareEndpoint,
    ShareEndpointConfig, ShareIdentity,
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
    CaptionFrame {
        scope: scope(),
        preview_revision: revision,
        lines,
    }
}

async fn endpoint() -> ShareEndpoint {
    ShareEndpoint::bind(&ShareIdentity::generate(), ShareEndpointConfig::default())
        .await
        .expect("离线绑定应当成功")
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

    let host_addr = host.endpoint_addr().await;
    let inbox = CaptionInbox::default();

    let listening = {
        let inbox = inbox.clone();
        tokio::spawn(async move { receive_captions(&viewer, host_addr, scope(), inbox).await })
    };

    // 给接收端一点时间把连接建起来,再开始广播。
    tokio::time::sleep(Duration::from_millis(200)).await;
    host.broadcast_caption(frame(1, vec![line("こんにちは")]));

    let got = collect(&inbox, 1).await;
    assert_eq!(got.len(), 1, "接收端应当收到一帧");
    assert_eq!(got[0].preview_revision, 1);
    assert_eq!(got[0].lines[0].source_text, "こんにちは");
    assert_eq!(
        got[0].lines[0].target_text.as_deref(),
        Some("译:こんにちは")
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
    let host_addr = host.endpoint_addr().await;
    let inbox = CaptionInbox::default();

    let listening = {
        let inbox = inbox.clone();
        tokio::spawn(async move { receive_captions(&viewer, host_addr, scope(), inbox).await })
    };
    tokio::time::sleep(Duration::from_millis(200)).await;

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
    let host_addr = host.endpoint_addr().await;
    let inbox = CaptionInbox::default();

    let listening = {
        let inbox = inbox.clone();
        tokio::spawn(async move { receive_captions(&viewer, host_addr, scope(), inbox).await })
    };
    tokio::time::sleep(Duration::from_millis(200)).await;

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
    let host_addr = host.endpoint_addr().await;
    let inbox = CaptionInbox::default();

    let listening = {
        let inbox = inbox.clone();
        tokio::spawn(async move { receive_captions(&viewer, host_addr, scope(), inbox).await })
    };
    tokio::time::sleep(Duration::from_millis(200)).await;

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
