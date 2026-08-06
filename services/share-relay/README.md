# Zulangue share relay

自建 [iroh](https://github.com/n0-computer/iroh) 中继，供「分享」标签页在直连打洞
失败时回落使用。设计见
[docs/architecture/share-p2p.md](../../docs/architecture/share-p2p.md) 第 6 节。

## 它保证什么、不保证什么

- **挡的是陌生人白嫖带宽。** 只有向邀请码服务登记过 endpoint id 的客户端能用它。
  但拿到客户端的人都能走邀请码登记，所以这不等于「未授权用户用不了分享功能」。
- **它不改变隐私。** 中继看不到明文，流量始终端到端加密——开不开门禁都一样。
- **同一 Wi-Fi 的会议室场景根本用不到它。** 局域网直连成功率接近 100%，分享码里
  内嵌了直连地址，断网也能配对。中继只在跨网络且打洞失败时才介入。

## 当前部署（exe.dev）

| | |
| --- | --- |
| 中继 | `zulangue-relay.exe.xyz`（1 vCPU / 2 GB），systemd 单元 `zulangue-share-relay` |
| 邀请码服务 | `zulangue-invite.exe.xyz`，门禁端点 `/v1/relay-auth` |
| 客户端用的 relay URL | `https://zulangue-relay.exe.xyz` |

exe.dev 的网络模型和一般 VM 不同，本目录里的 `relay.toml` 是**通用形态**，实际
部署用的是下面这几条差异：

- **TLS 由 exe.dev 边缘终结**，VM 只讲 HTTP，所以没有 `[tls]` 段，也不需要
  Let's Encrypt。
- **边缘代理固定转发到 `:8000`**，所以 `http_bind_addr = "0.0.0.0:8000"`。
  VM 在 NAT 后面，只有 22 直接暴露。
- **代理只转 HTTP，UDP 到不了 VM**，所以 `enable_quic_addr_discovery = false`。
  代价是打洞成功率略降，不影响可用性。
- 代理默认要求 exe.dev 登录，须 `share set-public zulangue-relay` 放开。
- **每台 VM 只有一个代理端口**（`share port` 是单数），这就是中继没有和邀请码
  服务合并到一台的原因——合并要在关键路径的机器前面再架一层 nginx 分流。

一个踩过的坑：用 curl 测 `Upgrade` 头会得到误导结论。curl 走 HTTP/2 时**自己**
就不发这个头（HTTP/2 禁止逐跳头），看起来像代理剥掉了。必须加 `--http1.1` 才测得准。
实测 exe.dev 的代理是**透传** `Upgrade` 的，中继协议因此可用。

## 部署

中继二进制来自 iroh 仓库，不在本仓库构建：

```bash
cargo install --git https://github.com/n0-computer/iroh --tag v1.0.3 --features server iroh-relay
```

放好文件。`RELAY_HOME` 取 `zulangue-share-relay.service` 里 `WorkingDirectory`
的值：

```bash
RELAY_HOME=~/zulangue-share-relay
install -Dm755 ~/.cargo/bin/iroh-relay "$RELAY_HOME/bin/iroh-relay"
install -Dm644 relay.toml "$RELAY_HOME/relay.toml"
sudo install -Dm644 zulangue-share-relay.service /etc/systemd/system/zulangue-share-relay.service
```

服务间凭据只存在于 `service.env`，**永远不要提交**：

```bash
umask 077
printf 'IROH_RELAY_HTTP_BEARER_TOKEN=%s\n' "$(openssl rand -hex 32)" > "$RELAY_HOME/service.env"
```

同一个值要写进邀请码服务的 `service.env`，键名是 `ZULANGUE_RELAY_AUTH_TOKEN`——
两边不一致时中继的每次鉴权都会拿到 401，表现为「所有人都连不上中继」。

启动：

```bash
sudo systemctl enable --now zulangue-share-relay
```

## 运营统计

中继每 15 分钟把自己的 Prometheus 计数器按天报给邀请码服务
(`zulangue-relay-stats.timer` → `report-stats.py` → `POST /v1/relay-stats`)。

**这条路径在结构上产不出社交图谱。** 中继的计数器是全局量 —— 累计字节、连接数、
掉包数 —— 它们**不带标签**,没有「谁连了谁」这种维度可读。服务端那张 `relay_daily`
表也只有聚合列,没有 endpoint 列。所以不是「我们选择不记配对」,是这条链路上记不出来。
`test_endpoint_data_in_a_report_is_never_stored` 对此有断言:上报里夹带 endpoint
信息,一个字节都不落库。

指标端口只绑 `127.0.0.1`,不经代理对外。

两个实现细节值得知道:

- **计数器重启会归零。** 上报的是增量,所以本地存一份上次读数做差;读数变小时把
  当前值整个当作增量 —— 报负数会被服务端拒掉,那一整段区间就丢了。
- **上报失败不写状态文件**,下次跑会把这段区间补上。

一个踩过的坑:别在 systemd 单元里套一层 `sh -c` 去给环境变量改名。那层 shell 里的
变量展开拿不到 `EnvironmentFile` 的值,表现为上报一直 401 而 token 明明是对的。
让脚本自己认两个名字更省事。

## 端口

| 端口 | 协议 | 用途 |
| --- | --- | --- |
| 443 | TCP | 中继协议（走 HTTP upgrade）与 Let's Encrypt 签发 |
| 7824 | UDP | QUIC 地址发现 |

## 一个会让所有人都连不上的坑

iroh-relay 1.0.3 的文档说鉴权请求带 `X-Iroh-Endpoint-Id` 头，**但源码里发出去的
实际是 `X-Iroh-NodeId`**——1.0 把 NodeId 改名成 EndpointId 时这个头名字没跟着改。

只认文档里那个名字的话，线上表现是「所有人都连不上中继」，而两边日志都显示一切
正常：邀请码服务返回 200，中继只说「正文不是 true」。邀请码服务因此两个名字都收。

这个坑是本机把中继真跑起来才发现的，curl 测不出来——curl 是你自己写的头名。

## 验证门禁真的在拦

```bash
ZULANGUE_RELAY_AUTH_TOKEN=... INVITE_URL=https://invite.exe.dev ./smoke-test.sh
```

它验四件事:服务可达、未登记被拒、token 不符 401、登记后放行。**但 curl 类测试
证明不了中继端到端能用**——头名字这个坑就是它测不出来的,因为头名是你自己写的。
真正的验证是把中继跑起来看它的日志:

```bash
RUST_LOG=iroh_relay=debug iroh-relay --dev --config-path relay-dev.toml
# 已登记: "HTTP access check OK: Allow access"
# 未登记: "HTTP access check failed: Deny access"
```

注意「正文不是 true」这条消息对**拒绝**和**故障**是同一句 —— 正文 `false` 也算
"invalid response text"。分辨二者要看已登记的那个 endpoint 有没有出现 OK。

暂停一个邀请码会同时断掉它名下所有 endpoint 的中继权限，不需要第二个开关。

## 本地开发

不需要中继：局域网直连即可，`ShareEndpointConfig::relay_urls` 留空就是
`RelayMode::Disabled`。要在本机试中继，用 `--dev`（HTTP-only，端口 3340，跳过
TLS 与 QUIC 地址发现）。
