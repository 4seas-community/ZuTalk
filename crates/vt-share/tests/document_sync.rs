//! 两个真实 endpoint 之间的文档同步。
//!
//! 用一个不依赖 Loro 的假文档层：更新就是一串字节，版本就是「我收到了几条」。
//! 这样测的是协议与准入这两层，而不是 CRDT 本身 —— Loro 侧的判定另有
//! `vt-store` 的 `capture_boundary_probe_tests` 覆盖。

use std::sync::{Arc, Mutex};
use std::time::Duration;

use vt_share::{
    AllowAllBoundaries, DocSyncContext, DocumentSync, RoomRoster, ScopeId, ShareEndpoint,
    ShareEndpointConfig, ShareIdentity, WritePolicy,
};

fn scope() -> ScopeId {
    ScopeId::Session {
        session_id: "sync".into(),
    }
}

/// 一个把更新按到达顺序堆起来的假文档。
#[derive(Default)]
struct FakeDoc {
    applied: Mutex<Vec<Vec<u8>>>,
    /// 待补给对方的历史。
    history: Mutex<Vec<u8>>,
}

impl FakeDoc {
    fn applied(&self) -> Vec<Vec<u8>> {
        self.applied.lock().unwrap().clone()
    }
}

impl DocumentSync for FakeDoc {
    fn version(&self, _scope: &ScopeId) -> Vec<u8> {
        (self.applied.lock().unwrap().len() as u64)
            .to_le_bytes()
            .to_vec()
    }
    fn updates_since(&self, _scope: &ScopeId, _version: &[u8]) -> Option<Vec<u8>> {
        let history = self.history.lock().unwrap();
        if history.is_empty() {
            None
        } else {
            Some(history.clone())
        }
    }
    fn apply(&self, _scope: &ScopeId, update: &[u8]) -> bool {
        self.applied.lock().unwrap().push(update.to_vec());
        true
    }
}

async fn endpoint_with_doc(
    host_id: iroh::EndpointId,
    policy: WritePolicy,
    doc: Arc<FakeDoc>,
) -> ShareEndpoint {
    let endpoint = ShareEndpoint::bind(&ShareIdentity::generate(), ShareEndpointConfig::default())
        .await
        .unwrap();
    endpoint
        .enable_document_sync(DocSyncContext {
            scope: scope(),
            roster: Arc::new(tokio::sync::Mutex::new(RoomRoster::new(
                scope(),
                host_id,
                policy,
            ))),
            guard: Arc::new(AllowAllBoundaries),
            sink: doc,
        })
        .await;
    endpoint
}

async fn wait_for_applied(doc: &FakeDoc, want: usize) -> Vec<Vec<u8>> {
    for _ in 0..200 {
        let got = doc.applied();
        if got.len() >= want {
            return got;
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    doc.applied()
}

/// 新加入者连上来时，先拿到自己缺的那段历史。
#[tokio::test]
async fn late_joiner_receives_the_missing_history() {
    let host_doc = Arc::new(FakeDoc::default());
    *host_doc.history.lock().unwrap() = b"earlier-history".to_vec();
    let joiner_doc = Arc::new(FakeDoc::default());

    // 主持人的身份同时是名册里的 host，所以它签的更新过得了准入。
    let host = ShareEndpoint::bind(&ShareIdentity::generate(), ShareEndpointConfig::default())
        .await
        .unwrap();
    let host_id = host.endpoint_id();
    host.enable_document_sync(DocSyncContext {
        scope: scope(),
        roster: Arc::new(tokio::sync::Mutex::new(RoomRoster::new(
            scope(),
            host_id,
            WritePolicy::Everyone,
        ))),
        guard: Arc::new(AllowAllBoundaries),
        sink: host_doc.clone(),
    })
    .await;

    let joiner = endpoint_with_doc(host_id, WritePolicy::Everyone, joiner_doc.clone()).await;
    let host_addr = host.endpoint_addr().await;

    let syncing = tokio::spawn(async move { joiner.sync_document_with(host_addr).await });

    let applied = wait_for_applied(&joiner_doc, 1).await;
    assert_eq!(applied, vec![b"earlier-history".to_vec()], "应当补齐历史");

    syncing.abort();
    host.shutdown().await;
}

/// 主持人之后产生的更新，实时推到已连接的对端。
#[tokio::test]
async fn live_updates_reach_a_connected_peer() {
    let host_doc = Arc::new(FakeDoc::default());
    let peer_doc = Arc::new(FakeDoc::default());

    let host = ShareEndpoint::bind(&ShareIdentity::generate(), ShareEndpointConfig::default())
        .await
        .unwrap();
    let host_id = host.endpoint_id();
    host.enable_document_sync(DocSyncContext {
        scope: scope(),
        roster: Arc::new(tokio::sync::Mutex::new(RoomRoster::new(
            scope(),
            host_id,
            WritePolicy::Everyone,
        ))),
        guard: Arc::new(AllowAllBoundaries),
        sink: host_doc,
    })
    .await;

    let peer = endpoint_with_doc(host_id, WritePolicy::Everyone, peer_doc.clone()).await;
    let host_addr = host.endpoint_addr().await;
    let syncing = tokio::spawn(async move { peer.sync_document_with(host_addr).await });

    tokio::time::sleep(Duration::from_millis(300)).await;
    host.publish_document_update(b"live-edit-1".to_vec());
    host.publish_document_update(b"live-edit-2".to_vec());

    let applied = wait_for_applied(&peer_doc, 2).await;
    assert!(
        applied.contains(&b"live-edit-1".to_vec()) && applied.contains(&b"live-edit-2".to_vec()),
        "两笔实时更新都应当到达，实际 {applied:?}"
    );

    syncing.abort();
    host.shutdown().await;
}

/// 只读房间里，非主持人推来的更新到不了对方的文档层。
///
/// 这是「只读」在网络路径上的最终断言 —— 前面几层测的是判定函数，这条测的是
/// 判定真的挂在了收包路径上。
#[tokio::test]
async fn read_only_room_drops_updates_from_a_viewer() {
    let host_doc = Arc::new(FakeDoc::default());
    let viewer_doc = Arc::new(FakeDoc::default());

    // 主持人是另一把不参与本次连接的钥匙，所以观看者签的更新一定不是主持人签的。
    let absent_host = iroh::SecretKey::generate().public();

    let host = endpoint_with_doc(absent_host, WritePolicy::HostOnly, host_doc.clone()).await;
    // sync_document_with 会一直跑,所以 endpoint 要留在外面共享,不能 move 进任务。
    let viewer = Arc::new(endpoint_with_doc(absent_host, WritePolicy::HostOnly, viewer_doc).await);
    let host_addr = host.endpoint_addr().await;

    let syncing = {
        let viewer = viewer.clone();
        tokio::spawn(async move { viewer.sync_document_with(host_addr).await })
    };

    tokio::time::sleep(Duration::from_millis(400)).await;
    // 观看者试图推一笔更新给主持人。
    viewer.publish_document_update(b"viewer-edit".to_vec());
    tokio::time::sleep(Duration::from_millis(400)).await;
    syncing.abort();

    assert!(
        host_doc.applied().is_empty(),
        "只读房间里观看者的更新不该抵达主持人的文档层，实际 {:?}",
        host_doc.applied()
    );

    host.shutdown().await;
}
