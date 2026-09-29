//! 附近:递一份文字稿、看一场直播。两个引擎在同一进程里,只绑回环地址,不开
//! mDNS —— 「看见对方」由 `nearby_seen` 代替局域网发现。

use std::sync::{Arc, Mutex};
use std::time::Duration;

use tokio::sync::{oneshot, watch};
use vt_sync::{
    DeviceIdentity, IncomingOffer, LiveEvent, LiveFeed, NearbyError, NearbyHandler, Presence,
    SyncConfig, SyncEngine,
};

async fn engine(name: &str) -> SyncEngine {
    let config = SyncConfig {
        device_name: name.into(),
        loopback_only: true,
        ..SyncConfig::default()
    };
    SyncEngine::start(DeviceIdentity::generate(), config)
        .await
        .unwrap()
}

/// 接收方的应用:按预先定好的答案回应,记下收到了什么。
struct Inbox {
    answer: bool,
    offers: Mutex<Vec<IncomingOffer>>,
    delivered: Mutex<Vec<Vec<u8>>>,
    live: Mutex<Option<LiveFeed>>,
}

impl Inbox {
    fn new(answer: bool) -> Arc<Self> {
        Arc::new(Self {
            answer,
            offers: Mutex::default(),
            delivered: Mutex::default(),
            live: Mutex::default(),
        })
    }
}

impl NearbyHandler for Inbox {
    fn offer(&self, offer: IncomingOffer) -> oneshot::Receiver<bool> {
        self.offers.lock().unwrap().push(offer);
        let (tx, rx) = oneshot::channel();
        let _ = tx.send(self.answer);
        rx
    }

    fn deliver(&self, _offer: &IncomingOffer, parcel: Vec<u8>) -> Result<(), String> {
        self.delivered.lock().unwrap().push(parcel);
        Ok(())
    }

    fn live(&self) -> Option<LiveFeed> {
        self.live.lock().unwrap().clone()
    }
}

fn receiving(name: &str) -> Presence {
    Presence {
        name: name.into(),
        receiving: true,
        live: None,
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn a_transcript_handed_to_a_nearby_mac_arrives_only_after_it_is_accepted() {
    let studio = engine("工作室").await;
    let laptop = engine("笔记本").await;
    let inbox = Inbox::new(true);
    laptop.set_nearby_handler(Some(inbox.clone()));
    laptop.set_presence(Some(receiving("笔记本")));
    studio.nearby_seen(laptop.addr().await, receiving("笔记本"));

    let nearby = studio.nearby();
    assert_eq!(nearby.len(), 1);
    assert_eq!(nearby[0].device, laptop.device_id());
    assert_eq!(nearby[0].presence.name, "笔记本");

    // 大于一块,走分块。
    let parcel: Vec<u8> = (0..2_500_000u32).map(|i| (i % 251) as u8).collect();
    studio
        .send_parcel(laptop.device_id(), "工作室", "周会", &parcel)
        .await
        .unwrap();
    let offers = inbox.offers.lock().unwrap().clone();
    assert_eq!(offers.len(), 1);
    assert_eq!(offers[0].from, studio.device_id());
    assert_eq!(offers[0].from_name, "工作室");
    assert_eq!(offers[0].title, "周会");
    assert_eq!(offers[0].bytes, parcel.len() as u64);
    assert_eq!(inbox.delivered.lock().unwrap().as_slice(), &[parcel]);

    studio.shutdown().await;
    laptop.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_declined_or_unwanted_transcript_never_arrives() {
    let studio = engine("工作室").await;
    let laptop = engine("笔记本").await;
    let inbox = Inbox::new(false);
    laptop.set_nearby_handler(Some(inbox.clone()));
    studio.nearby_seen(laptop.addr().await, receiving("笔记本"));

    // 没打开接收:连问都不问用户。
    let refused = studio
        .send_parcel(laptop.device_id(), "工作室", "周会", b"hello")
        .await;
    assert_eq!(refused, Err(NearbyError::NotReceiving));
    assert!(inbox.offers.lock().unwrap().is_empty());

    // 打开了接收,但用户拒绝。
    laptop.set_presence(Some(receiving("笔记本")));
    let declined = studio
        .send_parcel(laptop.device_id(), "工作室", "周会", b"hello")
        .await;
    assert_eq!(declined, Err(NearbyError::Declined));
    assert_eq!(inbox.offers.lock().unwrap().len(), 1);
    assert!(inbox.delivered.lock().unwrap().is_empty());

    studio.shutdown().await;
    laptop.shutdown().await;
}

async fn next_event(events: &mut tokio::sync::mpsc::Receiver<LiveEvent>) -> LiveEvent {
    tokio::time::timeout(Duration::from_secs(10), events.recv())
        .await
        .expect("等直播事件超时")
        .expect("事件流断了")
}

#[tokio::test(flavor = "multi_thread")]
async fn a_nearby_viewer_gets_the_transcript_so_far_then_live_frames_then_the_end() {
    let host = engine("讲台").await;
    let viewer = engine("听众").await;
    let inbox = Inbox::new(false);
    host.set_nearby_handler(Some(inbox.clone()));

    // 没在直播:看不了。
    viewer.nearby_seen(host.addr().await, receiving("讲台"));
    assert_eq!(
        viewer.watch_live(host.device_id()).await.err(),
        Some(NearbyError::NotLive)
    );

    let part0: Arc<[u8]> = Arc::from(&b"part-0"[..]);
    let (frame_tx, frame_rx) = watch::channel(Some(Arc::from(&b"frame-1"[..])));
    let (parts_tx, parts_rx) = watch::channel(Arc::new(vec![part0.clone()]));
    *inbox.live.lock().unwrap() = Some(LiveFeed {
        title: "周会".into(),
        frame: frame_rx,
        parts: parts_rx,
    });
    host.set_presence(Some(Presence {
        name: "讲台".into(),
        receiving: false,
        live: Some("周会".into()),
    }));

    let (title, mut events) = viewer.watch_live(host.device_id()).await.unwrap();
    assert_eq!(title, "周会");
    // 晚到的先拿到已有的片,再拿到最后一帧。
    assert_eq!(
        next_event(&mut events).await,
        LiveEvent::Part {
            index: 0,
            total: 1,
            bytes: b"part-0".to_vec()
        }
    );
    assert_eq!(
        next_event(&mut events).await,
        LiveEvent::Frame(b"frame-1".to_vec())
    );

    // 片 0 没变,只推新增的片 1。
    parts_tx.send_replace(Arc::new(vec![part0, Arc::from(&b"part-1"[..])]));
    assert_eq!(
        next_event(&mut events).await,
        LiveEvent::Part {
            index: 1,
            total: 2,
            bytes: b"part-1".to_vec()
        }
    );
    frame_tx.send_replace(Some(Arc::from(&b"frame-2"[..])));
    assert_eq!(
        next_event(&mut events).await,
        LiveEvent::Frame(b"frame-2".to_vec())
    );

    // 散场。
    *inbox.live.lock().unwrap() = None;
    drop(frame_tx);
    drop(parts_tx);
    assert_eq!(next_event(&mut events).await, LiveEvent::Ended);

    host.shutdown().await;
    viewer.shutdown().await;
}
