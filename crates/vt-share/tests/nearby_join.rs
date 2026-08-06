//! 「同一网络里的人」:请求加入与批准。
//!
//! mDNS 发现依赖真实局域网，在 CI 的沙箱里不可靠，所以这里测的是**发现之后**
//! 的那一段——它才是承载安全性质的部分：发现 ≠ 准入，钥匙只在批准后交出。
//!
//! 请求方直接用对方的 `EndpointAddr` 拨号，等价于「已经发现了它」。

use std::time::Duration;

use vt_share::{
    DenyReason, RoomSecret, ScopeId, ShareCode, ShareEndpoint, ShareEndpointConfig, ShareIdentity,
    WritePolicy,
};

async fn endpoint() -> ShareEndpoint {
    ShareEndpoint::bind(&ShareIdentity::generate(), ShareEndpointConfig::default())
        .await
        .expect("离线绑定应当成功")
}

fn a_share_code(host: iroh::EndpointAddr) -> String {
    ShareCode::new(
        host,
        ScopeId::Notebook {
            notebook_id: "nb-1".into(),
        },
        RoomSecret::generate(),
        WritePolicy::Everyone,
    )
    .to_string()
}

/// 等请求出现在主持人的请求台上。
async fn wait_for_request(desk: &vt_share::JoinRequestDesk) -> vt_share::PendingJoinRequest {
    for _ in 0..100 {
        if let Some(request) = desk.pending().await.into_iter().next() {
            return request;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    panic!("请求始终没有出现在请求台上");
}

/// 批准之后，钥匙经这条直连交出——不经过任何聊天软件。
#[tokio::test]
async fn approving_hands_over_the_share_code() {
    let host = endpoint().await;
    let guest = endpoint().await;

    let code = a_share_code(host.endpoint_addr().await);
    host.set_hosted_share_code(Some(code.clone())).await;
    guest.set_display_name("朋友的 Mac").await;

    // 客人先把主持人的地址喂进去，等价于「刚刚在局域网里发现了它」。
    let host_addr = host.endpoint_addr().await;
    let host_id = host.endpoint_id();
    let asking = {
        let guest_ref = &guest;
        async move {
            guest_ref.join_room_addr_hint(host_addr).await;
            guest_ref.request_to_join(&host_id.to_string()).await
        }
    };
    let answering = async {
        let desk = host.join_desk();
        let request = wait_for_request(&desk).await;
        assert_eq!(request.display_name, "朋友的 Mac");
        assert_eq!(request.endpoint_id, guest.endpoint_id());
        assert!(desk.approve(&request.request_id, code.clone()).await);
    };

    let (answer, ()) = tokio::join!(asking, answering);
    assert_eq!(answer.unwrap().unwrap(), code, "批准后应当拿到分享码");

    host.shutdown().await;
    guest.shutdown().await;
}

/// 拒绝就是拒绝，而且不能顺手把钥匙漏出去。
#[tokio::test]
async fn declining_reveals_nothing() {
    let host = endpoint().await;
    let guest = endpoint().await;

    let code = a_share_code(host.endpoint_addr().await);
    host.set_hosted_share_code(Some(code.clone())).await;

    let host_addr = host.endpoint_addr().await;
    let host_id = host.endpoint_id();
    let asking = async {
        guest.join_room_addr_hint(host_addr).await;
        guest.request_to_join(&host_id.to_string()).await
    };
    let answering = async {
        let desk = host.join_desk();
        let request = wait_for_request(&desk).await;
        assert!(desk.decline(&request.request_id).await);
    };

    let (answer, ()) = tokio::join!(asking, answering);
    match answer.unwrap() {
        Err(DenyReason::Declined) => {}
        other => panic!("应当被拒绝，实际 {other:?}"),
    }

    host.shutdown().await;
}

/// 对方没在共享时当场回绝，而且要说清楚是「没在共享」而不是「拒绝了你」——
/// 混成一句话会让人反复敲门。
#[tokio::test]
async fn a_host_that_is_not_sharing_says_so() {
    let host = endpoint().await;
    let guest = endpoint().await;
    let host_addr = host.endpoint_addr().await;

    guest.join_room_addr_hint(host_addr).await;
    let answer = guest
        .request_to_join(&host.endpoint_id().to_string())
        .await
        .unwrap();
    match answer {
        Err(DenyReason::NotSharing) => {}
        other => panic!("应当回「没在共享」，实际 {other:?}"),
    }

    // 主持人那边不该被打扰。
    assert!(host.join_desk().pending().await.is_empty());

    host.shutdown().await;
}

/// 发现 ≠ 准入。看得见一台机器，不等于能拿到它的房间钥匙。
#[tokio::test]
async fn discovery_alone_grants_nothing() {
    let host = endpoint().await;
    let guest = endpoint().await;
    let code = a_share_code(host.endpoint_addr().await);
    host.set_hosted_share_code(Some(code.clone())).await;

    let host_addr = host.endpoint_addr().await;
    guest.join_room_addr_hint(host_addr).await;

    // 请求发出去了，但主持人不回答。超时必须是拒绝，而不是默认放行。
    let desk = host.join_desk();
    let host_id_text = host.endpoint_id().to_string();
    let asking = guest.request_to_join(&host_id_text);
    let observing = async {
        let request = wait_for_request(&desk).await;
        // 故意什么都不做，然后把请求撤掉,模拟主持人关掉了页面。
        desk.decline(&request.request_id).await
    };
    let (answer, _) = tokio::join!(asking, observing);
    assert!(
        answer.unwrap().is_err(),
        "没有明确批准就不该拿到钥匙"
    );

    host.shutdown().await;
}
