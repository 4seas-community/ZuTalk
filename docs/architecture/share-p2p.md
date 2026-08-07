# 分享：点对点字幕与文档协同

侧边栏新增「分享」标签。用 [iroh](https://github.com/n0-computer/iroh) 做点对点，
交换公钥即可找到对方。目标效果：对方进入共享状态后，他的实时字幕在本机实时可见；
同一份文档可多人协同编辑。

本文只描述分享路径。实时分段本身的权威机制见
[timeline-projection.md](timeline-projection.md)，本文不重复。

## 0. 非目标

- **音频永远不在分享范围内。** 这不是默认值，是不可配置的约束，第 5 节给出强制手段。
- 不做任意文件发送。可分享的东西来自一份封闭清单，见 5.2。
- 不做公开发现。不向 n0 的公共 DNS / pkarr 发布本机地址。
- 不接管实时分段、对齐或投影逻辑。分享层只搬运已经定好的结果。

## 1. 本文核对过的事实

设计依赖的外部版本与 API，全部在 2026-08-06 核对过。

| 依赖 | 版本 | 说明 |
| --- | --- | --- |
| `iroh` | 1.0.3 | 2026-06 发 1.0，承诺 wire protocol 与 API 稳定 |
| `iroh-relay` | 1.0.3 | n0 生产环境同一份代码，可自建 |
| `iroh-gossip` | 0.101.0 | 依赖 `iroh ^1`，兼容 |
| `iroh-blobs` | 0.103.0 | 依赖 `iroh ^1.0.0`，兼容 |
| `iroh-tickets` | 1.0.0 | 分享码编码，**不要手写** |
| `iroh-mdns-address-lookup` | 0.4.0 | 局域网发现，**不在 iroh 核心里** |
| `loro` | 本仓库 1.10.8 / 最新 1.13.9 | 已在 `vt-ffi` 使用 |

iroh 1.0 把 `NodeId` / `NodeAddr` 改名为 `EndpointId` / `EndpointAddr`。网上大量
0.x 教程的代码不能直接抄。

**MSRV 无余量**：`iroh` / `iroh-gossip` / `iroh-blobs` 的 `rust-version` 都是
`1.91`，与 `rust-toolchain.toml` 的 `1.91.0` 正好相等。`iroh` 本身是 edition 2024
（1.91 支持，与本仓库的 2021 不冲突）。升级这些依赖前要先确认 MSRV 没有上抬。

BLE 自定义传输需要 iroh 的 `unstable-custom-transports` feature——名字里就写着
unstable。

本仓库 loro 1.10.8 已具备协同所需的全部钩子，位置逐个核对过：

| 用途 | API | 位置 |
| --- | --- | --- |
| 出站：本地改动的 update 字节 | `subscribe_local_update` | `loro/src/lib.rs:1032` |
| 入站：批量合入远端 update | `import_batch` | `:425` |
| 差量协商 | `oplog_vv()` / `state_vv()` | `:816` / `:822` |
| 快照与增量导出 | `export(ExportMode)` | `:1235` |
| 光标与在场 | `awareness` 模块 | `:47` |

[loro-dev/iroh-loro](https://github.com/loro-dev/iroh-loro) 是 Loro 官方做的
iroh + Loro 协同 demo，**只支持 2 个 peer、单个纯文本文件**，不能直接使用，
但结构可参考。

## 2. 身份与群组

**身份**是一把长期 ed25519 密钥，即 iroh 的 `EndpointId`。密钥存进现有
`FileKeyStore`，与 API key 同级对待。身份稳定是前提——联系人保存下来的公钥换一次
就全部失效。

**群组**用 `iroh-gossip` 的 `TopicId`（32 字节）。加入同一 topic 即同一房间，成员
发现、广播、进出全由它负责，底层是 HyParView + PlumTree。这是 n0 官方维护的一等
公民协议，不需要自己实现成员管理。

> 早期方案考虑过星型直连。既然确定要群组和多人协同，星型等于把 gossip 重写一遍，
> 放弃。

`TopicId` 由房间密钥派生，不直接用 `notebook_id`：

```
TopicId = BLAKE3("zulangue/room/v1" || scope_id || room_secret)
```

`room_secret` 随机生成、随分享码一起交出。这样 topic 不可猜测，并且**轮换
`room_secret` 就等于换一个房间**——这正是第 4.3 节「停止共享」的实现手段。

**不用 `iroh-docs`。** 它是建在 blobs + gossip 之上的 CRDT KV，自带 iroh 自己的
CRDT。本仓库已有 Loro，用它就是两套 CRDT 打架。

### 2.1 必须用 `presets::Minimal`，不能用 `presets::N0`

`iroh-1.0.3/src/endpoint/presets.rs:81-104`：`N0` preset 等价于挂上
`PkarrPublisher` + `PkarrResolver` + `DnsAddressLookup`，**会把本机地址发布到
n0 的公共 pkarr / DNS（`dns.iroh.link`）**。这与第 0 节「不做公开发现」直接冲突。

`Minimal` 只设定 mandatory 的 crypto provider，不带任何中继与发现。所以形态是：

```
Endpoint::builder(presets::Minimal)
    .relay_urls([自建 relay])          // 第 6 节
    .add_address_lookup(MdnsAddressLookup)  // 局域网，可选且需系统授权
    .alpns([LIVE_CAPTION_ALPN, DOC_SYNC_ALPN, iroh_gossip::ALPN])
```

对端地址不靠公共发现，而是随分享码交出——分享码用
[`iroh-tickets`](https://docs.rs/iroh-tickets) 编码，不要手写。局域网发现用
`iroh-mdns-address-lookup`（0.4.0，依赖 `iroh ^1.0.0`），**它不在 iroh 核心里**，
是独立 crate。

## 3. 三条通道

分享的数据有三种，寿命和可靠性要求完全不同，必须分开走。

| 数据 | 通道 | 可靠性 | 进文档历史 |
| --- | --- | --- | --- |
| 实时字幕预览（推测性 tail） | 自定义 ALPN，**每帧一条 QUIC uni-stream** | 整帧到达或不到达，按 revision 丢旧 | 否 |
| 房间控制面（在场、名册、版本通告） | `iroh-gossip` | 必达，小消息 | 否 |
| 文档协同（Loro update 字节） | 成对直连 QUIC bi-stream | 必达，可乱序 | 是 |
| 文件（封闭清单，无音频） | `iroh-blobs` | 必达 | — |

ALPN 取 `zulangue/live-caption/1` 与 `zulangue/doc-sync/1`，与 `iroh-gossip` 的
ALPN 一同注册在同一个 `Router` 上。

### 3.0 两条尺寸红线，决定了上面的通道选择

这两条是从依赖源码里读出来的硬上限，初版设计（字幕走 datagram、Loro update 走
gossip）在它们面前都不成立。

**QUIC datagram 约 1.2 KB 封顶。** `iroh-1.0.3/src/endpoint/connection.rs:986-998`
的 `max_datagram_size()` 文档：数据必须装进单个 QUIC 包，随路径 MTU 变化，且
「if the peer's limit is large this is guaranteed to be a little over a kilobyte
at minimum」。而观众画布最多渲染八行（`notebook_capture_api.rs:3354`），一帧含八行
utterance 加多语言 cue 加 lane health，UTF-8 中日泰文本下轻易过万字节。
→ **不用 datagram。改为每帧开一条 uni-stream**：QUIC 开 uni-stream 不需要额外往返，
写完即关，帧与帧互不阻塞，接收端读完整条流再按 `preview_revision` 决定用还是丢。
这样既没有尺寸上限，也保住了「丢旧帧无害」的性质，还省掉了分片重组逻辑。

**gossip 单条消息默认 4096 字节。** `iroh-gossip-0.101.0/src/proto.rs:69` 的
`DEFAULT_MAX_MESSAGE_SIZE = 4096`（下限常量 `MIN_MAX_MESSAGE_SIZE = 512`）。
`net.rs:154` 有 `Builder::max_message_size` 可调大，但要求所有节点取值一致，且大
消息会损伤 gossip 的扇出效率。Loro update 在粘贴整段、首次同步时远超 4 KB。
→ **gossip 只做控制面**，真正的 update 字节走成对直连流。这也正是 `iroh-docs`
自己的结构（gossip 通告 + blobs 搬运）。

### 3.1 实时字幕不进 CRDT

这条最要紧。字幕预览帧是高频、replace-in-full、可丢弃的；CRDT update 是**每一笔
都永久留在 oplog 里**的历史。把每秒几十帧的推测性字幕写进 Loro，文档历史会迅速
膨胀，而且推测性 tail 会被反复修订和撤回（`FfiNotebookCaptureTranslationCue` 的
`withdrawn` 字段），噪声全部沉进历史。

分界线代码里已经有了：`notebook_capture_api.rs:248` 的
`realtime_loro_applied_revision` 就是「已投影进 Loro 的水位线」。水位线以下走
CRDT，以上走轻量广播。

### 3.2 字幕通道的载荷

广播端直接转发 `FfiNotebookCaptureLivePreview`（`notebook_capture_api.rs:389`）。
它的注释已经写明每帧携带完整当前 tail、跳号无害——这正好是不可靠通道的理想载荷，
接收端按 `preview_revision` 单调取新即可。不需要为分享另设一套投影模型。

晚加入的人只看得到 bounded tail，所以另需一条有序通道补发落定内容：
`on_capture_event` 的 delta 按 revision 递增发送。

**跨流对齐权威必须留在广播端唯一一处，接收端不得重做**，否则两端会产生分歧。
理由见 [timeline-projection.md](timeline-projection.md)。

### 3.3 扇出不得阻塞采集

广播端同时在跑采集、STT WebSocket、多语言 lane，再加 N 条连接。发送要走独立任务，
对慢速接收者**丢帧而不是背压**。预览帧 replace-in-full，丢帧本就无害。

## 4. 共享范围与权限

### 4.1 两种范围

- **按 Notebook**：记住该 Notebook 的共享意向，之后在其中开始的录音默认参与共享。
- **按单次录音**：只共享指定 Session，不影响 Notebook 其他录音。

按 Notebook 记住有一个隐私陷阱：下次在这个 Notebook 按下录音，字幕会自动发出去。
考虑到录音内容的敏感性（见 [PRD](../product/PRD.md) 的数据边界），记住的语义必须是
**「这个 Notebook 默认开启」而非「自动开始且无提示」**：

- 首次为某个 Notebook 开启共享，必须显式确认一次。
- 录音进行中，录音条上常驻可见的共享指示器，一键可关。
- 关闭只影响本次，不清除 Notebook 的记忆。

### 4.2 权限：P2P 里「只读」到底能保证什么

两种模式：**全员平权可编辑** / **主持人可写、其他人只读**。

必须说清楚它的实际形状。P2P 没有服务器，只读**不可能由发送端强制**——它只能是
每个接收端在 `import_batch` 之前过滤。所以真实保证是：

> 所有运行未经篡改客户端的成员，都会拒绝非主持人的改动。

改过客户端的人可以在自己那份文档上随便改，也可以往外发，但诚实节点会丢弃。这个
保证对会议场景够用——它防的是误操作和越权，不防恶意成员篡改自己那一份。**UI 上
不得暗示更强的保证。**

**不能用 Loro `PeerID` 做权限判定。** `loro/src/lib.rs:913-916` 的 `set_peer_id`
文档明确警告：不要给用户或设备分配固定 PeerID，重复 PeerID 会产生冲突 OpID 并
**损坏文档**，推荐每进程随机。而且 gossip 是转发式的，传输层的发送者不等于作者。

所以每条 update 包一层用 iroh 身份密钥签名的信封，接收端按房间名册验签：

```
ShareEnvelope {
    author: EndpointId,
    scope:  ScopeId,
    payload: Vec<u8>,      // Loro update bytes
    signature: [u8; 64],   // author 对 (scope || payload) 的签名
}
```

接收端的 import 门（按顺序）：

1. **归属检查**：载荷声称的文档 id 必须属于本共享范围，否则一个房间就能写进
   它管不着的文档。
2. **结构纪元检查**：载荷带 `schema_epoch`，与本机同一篇文档的纪元不符直接丢弃。
   混流不是权限问题，是结构损坏——两个纪元的 oplog 属于两个结构不同的文档
   （见 document-schema-decision.md「迁移」一节），所以它排在作者判定之前。
3. 验签，签名不符直接丢弃。
4. 只读模式下 `author != host` 直接丢弃。
5. **编辑边界检查**：CRDT 不认 `editor_bridge.rs` 的
   `set_capture_owned_range`——转录投影拥有的区间不该被人改，但 CRDT 会老实合并
   远端对那段的修改。这一层必须在 `import_batch` **之前**做，不能指望 CRDT 自己拦。
6. 通过后才 `import_batch`。

任何一步**判不出来一律拒收**——判不出来时放行，等于这道门不存在。

### 4.3 停止共享的语义

CRDT 一旦合并进对方的 doc，对方本地就有完整历史，收不回来。**停止共享只能是
「停止继续同步」，不能是「删除对方已有的」。** 实现即轮换 `room_secret`：老成员保留
已有内容，但拿不到后续，也进不来新房间。

UI 必须把这句话说明白，不能让用户以为点了停止对方就看不到了。这与音频不可共享是
同一条原则——不可撤回的东西，事前门槛要高。

## 5. 音频不可共享的强制

### 5.1 已知漏点

`crates/vt-export/src/zip.rs:18` 的 `ExportOptions::default()` 里
`include_audio: true`，导出包会写进 `audio.wav`。任何「分享导出包」的实现只要顺手
复用 `export_zip`，默认行为就是把音频发出去。

### 5.2 四层强制，从强到弱

**第一层 · 依赖图。** `vt-share` 的 `Cargo.toml` 不依赖 `vt-crypto` 和 `vt-audio`。
音频是每 Session 一把 `SessionKey` 加密落盘的（`session_meta.rs` 的 `key_id` /
`audio_key_ref`），拿不到 `vt-crypto` 就解不开。这不是约定不发，是物理上发不出明文。
CI 用 `cargo tree` 断言。

**第二层 · 封闭枚举。** 不提供任意路径发送口。对外只有
`share_resource(session_id, ShareableKind)`，`ShareableKind` 没有音频变体，也没有
Context Pack 变体（它是加密的用户资料，同样不该默认可分享）。加 exhaustive match
测试，将来新增变体会编译失败而非静默放行。

**第三层 · 复用点收口。** 给 `vt-export` 加 `ExportOptions::shareable()` 构造器，
让分享路径只能走它；门禁 grep 断言分享代码中不出现 `include_audio: true` 与
`ExportOptions::default()`。

**第四层 · 线上载荷。** 字幕通道只承载 `FfiNotebookCaptureLivePreview` /
`FfiNotebookCaptureEvent` 这类纯文本结构。`vt-model:38` 的 PCM `AudioFrame` 不得
出现在任何 wire 类型里。

新增 `scripts/test_share_no_audio_gate.sh`，接进 `just ci-check`，写法沿用
`scripts/test_minimal_mvp_architecture_gate.sh`。**门禁要在写业务代码之前先立。**

## 6. 中继节点

自建 `iroh-relay`。用它的 HTTP 回调式访问控制接到现有
[`services/community-invite/`](../../services/community-invite/README.md)：

```toml
enable_quic_addr_discovery = true

[access.http]
url = "https://invite.exe.dev/v1/relay-auth"
bearer_token = "服务间密钥"

[tls]
cert_mode = "LetsEncrypt"
```

relay 对该 URL 发 **POST**，请求头带 `X-Iroh-Endpoint-Id`（hex 公钥）；返回 200 且
body 为 `true` 才放行，其余一律拒绝（`iroh-relay-1.0.3/src/main.rs:160-210`）。
服务端加一张 `endpoint_enrollment` 表和 `/v1/relay-auth` 路由，鉴权模型、审计表、
admin 面板全部复用。App 首次生成身份后拿邀请码登记 endpoint-id。

配置取值已按源码核对：`AccessConfig` 带 `#[serde(rename_all = "lowercase")]`，
所以 TOML 键是 `[access.http]`；`CertMode` 没有 rename，取值就是字面的
`"Manual"` / `"LetsEncrypt"` / `"Reloading"`。

**密钥不落配置文件。** `bearer_token` 可由环境变量 `IROH_RELAY_HTTP_BEARER_TOKEN`
覆盖并优先于配置值，走 `service.env`，与 `community-invite` 现有做法一致。

端口：HTTPS 443（relay 协议走 HTTP upgrade）+ QUIC 地址发现 UDP 7824。

两条界限要写清楚：

- 这个门禁挡的是**陌生人白嫖带宽**，不是「未授权用户用不了这个功能」——拿到客户端的
  人都能走邀请码注册。
- 它**不改变隐私**。relay 看不到明文，流量始终端到端加密，开不开门禁都一样。

## 7. 传输与网络覆盖

Wi-Fi、蜂窝、以太网、局域网在 iroh 下不是四种传输——都是 QUIC over UDP，自动支持。
真正的工程含义是 NAT 差异：以太网 / Wi-Fi 打洞成功率高，运营商 CGNAT（iPhone 热点）
常失败并回落 relay。Mac 无蜂窝模块，蜂窝即热点。

**同一 Wi-Fi 的会议室场景**是最容易的一种：直连成功率接近 100%，不走 relay，
分享码内嵌 `EndpointAddr` 直连地址再叠加 mDNS，**断网也能开会**。延迟是亚毫秒到
几毫秒，端到端延迟几乎全部来自 STT 出字，网络这段可忽略。

三个实际的坑：

1. **AP 隔离。** 很多会议室、酒店、咖啡馆 Wi-Fi 开了客户端隔离，同网段互相不可见，
   直连和 mDNS 全废，必须回落 relay 也就必须有互联网。UI 要显示当前是直连还是中继。
2. **本地网络权限。** macOS 15+ 做 mDNS 需要 `NSLocalNetworkUsageDescription`，
   首次弹系统授权。拒绝后只剩手动交换分享码（`iroh-tickets` 里已内嵌直连地址），
   要有降级路径。局域网发现本身是独立 crate `iroh-mdns-address-lookup`，
   不随 iroh 核心提供。
3. **蓝牙**是唯一真正独立的传输，只有第三方实验 crate
   [mcginty/iroh-ble-transport](https://github.com/mcginty/iroh-ble-transport)
   （macOS/iOS/Android/Linux，GATT 起连、可用时升级 L2CAP）。带宽只够跑字幕，
   传文件不可用。列为可选后期项，需要 `NSBluetoothAlwaysUsageDescription`。

App Sandbox 当前是关的（`macos/Zulangue.entitlements`），不涉及网络 entitlement。

## 8. UI

`MainTab` 加 `case share`（`ZulangueApp.swift:290`），sidebar 加一项
（`MainShellView.swift:84`），新增 `Pages/SharePage.swift`。

- 文案走 `String(localized: "sidebar.share")`，补齐七语
  （en/th/ja/fr/es/de/zh-Hans）；繁体与缅甸语按既定范围不做。
- 新增 `AccessibilityID.mainTabShare`；`WindowSystemTests` / `DesignSystemTests`
  有 sidebar 断言需同步。

## 9. 分期

**第一期 · 骨架、门禁、文件分享。** `vt-share` crate（`ShareableKind` 封闭枚举）、
身份生成与持久化、`iroh-tickets` 分享码、`iroh-blobs` 收发、Share 标签页、
relay 部署与 `/v1/relay-auth`、`test_share_no_audio_gate.sh`。
验收：两台 Mac 跨网络与跨局域网互传封闭清单内的资源。

**第二期 · 实时字幕共享。** gossip 房间、双通道协议、广播端 fan-out、接收端只读
投影、加入退出与断线重连、共享确认与常驻指示器。

**第三期 · 文档协同。** 签名信封、接收端 import 门（验签 / 权限 / 编辑边界）、
两种权限模式、`room_secret` 轮换。

**第四期 · 可选。** BLE transport 实验（仅字幕）。

## 10. 未决

- 第三期的编辑边界过滤要多严：是拒绝整条 update，还是只丢弃越界的那部分操作？
  后者更友好但要拆 Loro update，代价未评估。
- 房间名册怎么分发与更新（主持人签名的成员列表 vs gossip 内广播）。
- 大房间下 gossip 的实测扇出成本，需要在第二期收数据后再定人数上限。
