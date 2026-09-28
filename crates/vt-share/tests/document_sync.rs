//! 两个真实 endpoint 之间的文档同步。
//!
//! 用一个不依赖 Loro 的假文档层：更新就是一串字节，版本就是「我收到了几条」。
//! 这样测的是协议与准入这两层，而不是 CRDT 本身 —— Loro 侧的判定另有
//! `vt-store` 的 `capture_boundary_probe_tests` 覆盖。

use std::sync::{Arc, Mutex};
use std::time::Duration;

use vt_share::net::RoomHandle;
use vt_share::{
    AllowAllBoundaries, DocSyncContext, DocumentSync, RoomRoster, RoomSecret, ScopeId, ShareCode,
    ShareEndpoint, ShareEndpointConfig, ShareIdentity, WritePolicy,
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

/// 这个假文档层只认一篇文档,与 scope 的 session_id 同名。
const DOC: &str = "sync";

impl DocumentSync for FakeDoc {
    fn documents(&self, _scope: &ScopeId) -> Vec<String> {
        vec![DOC.to_string()]
    }
    fn document_in_scope(&self, _scope: &ScopeId, document_id: &str) -> bool {
        document_id == DOC
    }
    fn version(&self, _scope: &ScopeId, _document_id: &str) -> Vec<u8> {
        (self.applied.lock().unwrap().len() as u64)
            .to_le_bytes()
            .to_vec()
    }
    fn schema_epoch(&self, _scope: &ScopeId, _document_id: &str) -> Option<u64> {
        Some(1)
    }
    fn updates_since(
        &self,
        _scope: &ScopeId,
        _document_id: &str,
        _version: &[u8],
    ) -> Option<Vec<u8>> {
        let history = self.history.lock().unwrap();
        if history.is_empty() {
            None
        } else {
            Some(history.clone())
        }
    }
    fn apply(&self, _scope: &ScopeId, _document_id: &str, update: &[u8]) -> bool {
        self.applied.lock().unwrap().push(update.to_vec());
        true
    }
}

/// 主持人开房并接上文档同步。名册与房间同源 —— 文档通道只服务名册里的人。
async fn hosted(
    policy: WritePolicy,
    doc: Arc<FakeDoc>,
) -> (Arc<ShareEndpoint>, RoomHandle, ShareCode) {
    let host = ShareEndpoint::bind(&ShareIdentity::generate(), ShareEndpointConfig::default())
        .await
        .unwrap();
    let code = ShareCode::new(
        host.endpoint_addr().await,
        scope(),
        RoomSecret::generate(),
        policy,
    );
    let room = host.join_room(&code, vec![]).await.unwrap();
    host.enable_document_sync(DocSyncContext {
        scope: scope(),
        roster: Arc::new(tokio::sync::Mutex::new(room.roster().await)),
        guard: Arc::new(AllowAllBoundaries),
        hosting: true,
        sink: doc,
    })
    .await;
    (Arc::new(host), room, code)
}

/// 拿码进房、接上文档同步的观看端。
async fn joined(code: &ShareCode, doc: Arc<FakeDoc>) -> (Arc<ShareEndpoint>, RoomHandle) {
    let endpoint = ShareEndpoint::bind(&ShareIdentity::generate(), ShareEndpointConfig::default())
        .await
        .unwrap();
    let room = endpoint.join_room(code, vec![code.host.id]).await.unwrap();
    endpoint
        .enable_document_sync(DocSyncContext {
            scope: scope(),
            roster: Arc::new(tokio::sync::Mutex::new(RoomRoster::new(
                scope(),
                code.host.id,
                code.policy,
            ))),
            guard: Arc::new(AllowAllBoundaries),
            hosting: false,
            sink: doc,
        })
        .await;
    (Arc::new(endpoint), room)
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

    let (host, _host_room, code) = hosted(WritePolicy::Everyone, host_doc).await;
    let (joiner, _joiner_room) = joined(&code, joiner_doc.clone()).await;
    let host_addr = code.host.clone();

    let syncing = tokio::spawn(async move { joiner.sync_document_with(host_addr).await });

    let applied = wait_for_applied(&joiner_doc, 1).await;
    assert_eq!(applied, vec![b"earlier-history".to_vec()], "应当补齐历史");

    syncing.abort();
    drop(host);
}

/// 主持人之后产生的更新，实时推到已连接的对端。
#[tokio::test]
async fn live_updates_reach_a_connected_peer() {
    let host_doc = Arc::new(FakeDoc::default());
    let peer_doc = Arc::new(FakeDoc::default());

    let (host, _host_room, code) = hosted(WritePolicy::Everyone, host_doc).await;
    let (peer, _peer_room) = joined(&code, peer_doc.clone()).await;
    let host_addr = code.host.clone();
    let syncing = tokio::spawn(async move { peer.sync_document_with(host_addr).await });

    // 等对端过了名册那道门:在那之前发的实时更新没有连接可走,只能靠对账补。
    tokio::time::sleep(Duration::from_millis(800)).await;
    host.publish_document_update(DOC.into(), b"live-edit-1".to_vec());
    host.publish_document_update(DOC.into(), b"live-edit-2".to_vec());

    let applied = wait_for_applied(&peer_doc, 2).await;
    assert!(
        applied.contains(&b"live-edit-1".to_vec()) && applied.contains(&b"live-edit-2".to_vec()),
        "两笔实时更新都应当到达，实际 {applied:?}"
    );

    syncing.abort();
}

/// 只读房间里，非主持人推来的更新到不了主持人的文档层。
///
/// 这是「只读」在网络路径上的最终断言 —— 前面几层测的是判定函数，这条测的是
/// 判定真的挂在了收包路径上。
#[tokio::test]
async fn read_only_room_drops_updates_from_a_viewer() {
    let host_doc = Arc::new(FakeDoc::default());
    let viewer_doc = Arc::new(FakeDoc::default());

    let (_host, _host_room, code) = hosted(WritePolicy::HostOnly, host_doc.clone()).await;
    let (viewer, _viewer_room) = joined(&code, viewer_doc).await;
    let host_addr = code.host.clone();

    let syncing = {
        let viewer = viewer.clone();
        tokio::spawn(async move { viewer.sync_document_with(host_addr).await })
    };

    tokio::time::sleep(Duration::from_millis(800)).await;
    // 观看者试图推一笔更新给主持人。
    viewer.publish_document_update(DOC.into(), b"viewer-edit".to_vec());
    tokio::time::sleep(Duration::from_millis(600)).await;
    syncing.abort();

    assert!(
        host_doc.applied().is_empty(),
        "只读房间里观看者的更新不该抵达主持人的文档层，实际 {:?}",
        host_doc.applied()
    );
}

/// 没拿到码的人拨文档通道,拿不到文字稿。
///
/// 文档通道和字幕通道一样只看连接的公钥;不按名册放行,任何知道主持人
/// 公钥的人都能把整份文字稿拉走。
#[tokio::test]
async fn a_stranger_cannot_pull_the_transcript() {
    let host_doc = Arc::new(FakeDoc::default());
    *host_doc.history.lock().unwrap() = b"the-whole-transcript".to_vec();
    let (_host, _host_room, code) = hosted(WritePolicy::HostOnly, host_doc).await;

    let stranger_doc = Arc::new(FakeDoc::default());
    let stranger = ShareEndpoint::bind(&ShareIdentity::generate(), ShareEndpointConfig::default())
        .await
        .unwrap();
    stranger
        .enable_document_sync(DocSyncContext {
            scope: scope(),
            roster: Arc::new(tokio::sync::Mutex::new(RoomRoster::new(
                scope(),
                code.host.id,
                code.policy,
            ))),
            guard: Arc::new(AllowAllBoundaries),
            hosting: false,
            sink: stranger_doc.clone(),
        })
        .await;
    let host_addr = code.host.clone();
    let syncing = tokio::spawn(async move { stranger.sync_document_with(host_addr).await });

    tokio::time::sleep(Duration::from_millis(1500)).await;
    syncing.abort();
    assert!(
        stranger_doc.applied().is_empty(),
        "不在名册里的人不该拿到任何历史"
    );
}
