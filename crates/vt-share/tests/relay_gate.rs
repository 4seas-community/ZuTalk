//! 只在本机跑起中继时才有意义,平时忽略。
//!
//! 跑法见 services/share-relay/README.md 的「本地开发」。
use std::time::Duration;
use vt_share::{ShareEndpoint, ShareEndpointConfig, ShareIdentity};

#[tokio::test]
#[ignore = "需要本机中继;见 services/share-relay/README.md"]
async fn endpoint_reaches_the_local_relay() {
    let url: iroh::RelayUrl = std::env::var("ZULANGUE_TEST_RELAY")
        .expect("设 ZULANGUE_TEST_RELAY=http://127.0.0.1:3340")
        .parse()
        .unwrap();
    // 允许固定身份:先把它登记到邀请码服务,再跑同一个 endpoint,
    // 这样「登记前 / 登记后」的差别才可比。
    let identity = match std::env::var("ZULANGUE_TEST_SECRET") {
        Ok(hex_secret) => {
            let mut bytes = [0u8; 32];
            hex::decode_to_slice(hex_secret.trim(), &mut bytes).expect("32 字节十六进制私钥");
            ShareIdentity::from_secret_bytes(&bytes)
        }
        Err(_) => ShareIdentity::generate(),
    };
    eprintln!("ENDPOINT_ID={}", identity.endpoint_id());

    let endpoint = ShareEndpoint::bind(
        &identity,
        ShareEndpointConfig {
            relay_urls: vec![url],
            enable_local_discovery: false,
        },
    )
    .await
    .expect("配了中继也应当能绑定");

    // 给中继握手一点时间,好让门禁回调真的发生。
    tokio::time::sleep(Duration::from_secs(3)).await;
    eprintln!("ADDR={:?}", endpoint.endpoint_addr().await);
    endpoint.shutdown().await;
}
