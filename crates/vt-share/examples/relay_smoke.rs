//! 真实中继链路的冒烟探针。配合 scripts/share_relay_smoke.sh 使用。
//!
//! 两个子命令:
//!
//! - `id <secret-file>`:生成一把分享身份,密钥落到文件,endpoint id 打到
//!   stdout。脚本拿这个 id 去邀请码服务登记。
//! - `online <secret-file> <relay-url> <timeout-secs>`:用同一把身份绑定
//!   端点并等中继握手。**等到了**证明 relay-auth 放行了这个 endpoint;
//!   等不到(退出码 1)对未登记的身份是预期结果 —— 门禁在挡陌生人。
//!
//! 探针刻意不连房间、不发内容:它回答的只有一个问题 —— 这把身份此刻
//! 能不能被自建中继接纳。

use std::time::Duration;

use vt_share::{parse_relay_urls, ShareEndpoint, ShareEndpointConfig, ShareIdentity};

fn usage() -> ! {
    eprintln!("用法: relay_smoke id <secret-file>");
    eprintln!("      relay_smoke online <secret-file> <relay-url> <timeout-secs>");
    std::process::exit(2);
}

#[tokio::main]
async fn main() {
    let args: Vec<String> = std::env::args().collect();
    match args.get(1).map(String::as_str) {
        Some("id") => {
            let Some(path) = args.get(2) else { usage() };
            let identity = ShareIdentity::generate();
            std::fs::write(path, identity.to_secret_bytes()).expect("写身份密钥文件");
            println!("{}", identity.endpoint_id());
        }
        Some("online") => {
            let (Some(path), Some(relay), Some(timeout)) = (args.get(2), args.get(3), args.get(4))
            else {
                usage()
            };
            let bytes = std::fs::read(path).expect("读身份密钥文件");
            let bytes: [u8; 32] = bytes.as_slice().try_into().expect("密钥应为 32 字节");
            let identity = ShareIdentity::from_secret_bytes(&bytes);
            let timeout: u64 = timeout.parse().expect("超时秒数");

            let relay_urls = parse_relay_urls(&[relay.clone()]).expect("中继地址");
            let endpoint = ShareEndpoint::bind(
                &identity,
                ShareEndpointConfig {
                    relay_urls,
                    // 冒烟只看中继,不需要局域网发现(也免得弹权限框)。
                    enable_local_discovery: false,
                },
            )
            .await
            .expect("绑定端点");

            let online = endpoint.relay_online(Duration::from_secs(timeout)).await;
            endpoint.shutdown().await;
            if online {
                println!("relay-online {}", identity.endpoint_id());
            } else {
                println!("relay-refused-or-unreachable {}", identity.endpoint_id());
                std::process::exit(1);
            }
        }
        _ => usage(),
    }
}
