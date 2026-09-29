//! 用一个现生成的设备身份连一次中继,报告中继怎么答复。
//!
//! 升级或调整中继门禁后跑一下:它走的是真实客户端的整条路径(TLS、HTTP upgrade、
//! 中继协议握手、门禁回调),curl 测不到这些。
//!
//! ```bash
//! cargo run -p vt-sync --example relay_probe -- https://zulangue-relay.exe.xyz
//! ```
//!
//! 现在的门禁只放行登记过邀请码的设备,现生成的身份应当看到「被拒」—— 这恰好
//! 证明中继在说话、也真的问过门禁。门禁改成放行所有设备之后,应当看到「已连上」。

use std::time::Duration;

use iroh::endpoint::presets;
use iroh::{Endpoint, RelayMap, RelayMode, RelayUrl, Watcher};

#[tokio::main]
async fn main() {
    let url: RelayUrl = std::env::args()
        .nth(1)
        .expect("用法: relay_probe <中继地址>")
        .parse()
        .expect("中继地址无法解析");
    let endpoint = Endpoint::builder(presets::Minimal)
        .relay_mode(RelayMode::Custom(RelayMap::from_iter([
            iroh::RelayConfig::new(url.clone(), None),
        ])))
        .bind()
        .await
        .expect("端点启动失败");

    let mut status = endpoint.home_relay_status();
    let verdict = tokio::time::timeout(Duration::from_secs(20), async {
        loop {
            for relay in status.get() {
                if relay.is_connected() {
                    return "已连上".to_string();
                }
                if let Some(reason) = relay.auth_denied_reason() {
                    return format!("被拒: {reason}");
                }
            }
            if status.updated().await.is_err() {
                return "状态通道关闭".to_string();
            }
        }
    })
    .await
    .unwrap_or_else(|_| {
        let errors: Vec<String> = status
            .get()
            .iter()
            .filter_map(|relay| relay.last_error().map(|e| e.to_string()))
            .collect();
        format!("20 秒内没有结论;最近的错误: {errors:?}")
    });
    println!("{url} → {verdict}");
    endpoint.close().await;
}
