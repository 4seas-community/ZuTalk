# 网页分享：扫码看实时字幕稿

分享页的第二条出口。P2P 分享（[share-p2p.md](share-p2p.md)）要求对方也装着
Zulangue；网页分享面向**没装应用的人**：主持人开启后得到一个二维码和链接，
扫码进入网页就能看实时字幕，多语言转录可以切换语言，落定的内容累积成稿。

定案时间 2026-08-09。

## 0. 与 P2P 分享的边界

| | P2P 分享 | 网页分享 |
| --- | --- | --- |
| 对方需要什么 | Zulangue 应用 | 任何浏览器 |
| 传输 | iroh 端到端加密 | HTTPS 经 `caption-web` 服务 |
| 服务器可见性 | 看不到明文 | **看得到明文**（见下） |
| 协同订正 | 有 | 无（只读网页） |
| 内容留存 | 收端落库 | 服务器内存态，房间关闭即清 |

**明文取舍是用户明示的决定（2026-08-09）**：网页分享开启后，字幕明文经过
服务器。备选的端到端方案（密钥放 URL 片段、浏览器端解密、服务器只存密文）
被评估过、暂不实施——代价是网页端复杂度与调试难度。两条界限必须守住：

1. **UI 必须说出这句话**。开启网页分享的确认界面上写明「字幕明文会经过
   服务器」，不得含糊。P2P 分享的隐私叙述不适用于这条通道。
2. **音频照旧结构性排除**。网页通道只承载与 P2P 字幕通道相同的纯文本类型
   （`CaptionFrame` 与块快照），四层音频门禁（share-p2p.md §5）原样生效。

## 1. 架构

```
主持人 App                      caption-web (exe.xyz)            浏览器
─────────────                  ────────────────────            ──────
ShareCaptionTap ──帧──►  POST /v1/rooms/{id}/frame  ──SSE──►  实时 tail
publish_shared_session         POST /v1/rooms/{id}/blocks ──►  字幕稿
  └─块快照(去抖)──►
stop_sharing ────────►   DELETE /v1/rooms/{id}      ──SSE──►  「已结束」
```

- **帧**：与 P2P 同一份 `CaptionFrame`（完整形态：utterance/cue/lane 健康），
  replace-in-full，网页端整帧替换,丢帧无害。**必须经 `ShareCaptionTap` 的
  同一放行判定**（范围过滤、per-session 静音）——P2P 不发的帧,网页也不发,
  不存在第二套判定。
- **块快照**：字幕稿的来源。宿主本来就为共享 session 维护 T2 块文档
  （share-p2p.md §11）,`publish_shared_session` 时顺带把块列表
  （text + 各语言车道）推给服务,replace-in-full,服务端只留最新。
  网页的「稿」= 块快照;「实时」= 帧。两个时态,与 App 收端一致。
- **推送不阻塞采集**：帧与块都进 tokio `watch` 通道（新值覆盖旧值——
  replace-in-full 的天然搭配）,独立任务用 reqwest 慢慢发,发不动就丢中间态,
  与 P2P 扇出同一哲学（share-p2p.md §3.3）。
- **订阅**：网页用 SSE（`EventSource`）。单向、自动重连、纯 HTTP,
  stdlib `ThreadingHTTPServer` 一条长连接一个线程就够——观众是会议室量级,
  不是直播量级。

## 2. 服务:services/caption-web

与 `community-invite` 同一形态:Python 标准库单文件、systemd 托管、
用户自己部署。默认部署位 `https://zulangue-caption.exe.xyz`。

### 接口

| 方法 | 路径 | 鉴权 | 说明 |
| --- | --- | --- | --- |
| POST | `/v1/rooms` | 无（见滥用上限） | 建房,返回 `{room_id, publish_token, viewer_url}` |
| POST | `/v1/rooms/{id}/frame` | Bearer publish_token | 最新一帧,fanout |
| POST | `/v1/rooms/{id}/blocks` | Bearer publish_token | 最新块快照,fanout |
| DELETE | `/v1/rooms/{id}` | Bearer publish_token | 关房,订阅者收 `ended` |
| GET | `/v1/rooms/{id}/events` | 无（room_id 即门票） | SSE:先发全量（blocks+frame）,再发增量 |
| GET | `/r/{id}` | 无 | 观看页（内联 HTML/JS,无外部依赖） |
| GET | `/healthz` | 无 | 探活 |

`room_id` 与 `publish_token` 都是 `secrets.token_urlsafe`——房间号即门票,
不可猜测;发布口令只有主持人持有。

### 状态与留存

**内存态,不落盘。** 房间随进程重启消失——网页稿是投影,真相在主持人
本机（SQLite 事实层 + shared/ 文档）,重开网页分享即重建。留存规则:

- 空闲 TTL:最后一次推送后 6 小时自动清房（与会议时长同量级）;
- 主持人停止共享 → DELETE → 立即清;
- 房间数上限、载荷字节上限、建房按 IP 限速——挡的是脚本滥用,
  不是「未授权用户用不了」。

### 延后项

- **建房接邀请码门禁**:与 relay 门禁同构（endpoint 登记 + ed25519 签名
  验证）,滥用真出现了再立;
- 房间跨重启持久化;
- 端到端加密选项（密钥进 URL 片段）。

## 3. App 侧

### Rust（vt-ffi/src/share_web.rs）

`WebShareRuntime` 挂在 `ShareRuntime` 里（web 分享是「当前这场共享」的
属性,随 `stop_sharing` 一起收口）:

- `start_web_share()`:仅主持中可开;POST /v1/rooms,起推送任务;
- `stop_web_share()`:DELETE(尽力而为,fire-and-forget)+ 停任务;
- `web_share_state()`:给 UI 的快照(viewer_url 等);
- 帧入口在 `ShareCaptionTap::broadcast` 放行之后——同一帧、同一判定;
- 块入口在 `publish_shared_session`——宿主每次发布 P2P 更新时,
  同一份块列表推给网页(watch 覆盖 + 任务端去抖)。

### Swift(分享页)

主持中的「网页分享」卡片:开启前一句确认(明文警示);开启后显示二维码
(CoreImage `CIQRCodeGenerator`,零新依赖)、链接(可选中可复制)、
停止按钮。停止共享时网页分享一并结束,UI 不单独残留。

## 4. 观看页

单文件内联 HTML/JS/CSS,无外部资源(会议室网络不可预设能访问 CDN):

- **界面文案三语**(简体中文 / ไทย / English):观看的人就是这三种语言
  背景,英文独占的「This share has ended」对另外两种人是谜语。按
  `navigator.language` 自动选,右上角可手动切并记进 localStorage;
  界面语言与内容语言按钮互相独立;

- 顶部语言按钮:从块车道与帧 cue/utterance 语言并集自动生成,
  切换即切稿的显示车道与实时 tail 的字幕语言;
- 正文:落定块(选中语言的车道文本,缺席回落原文)+ 实时 tail
  (推测性,弱色显示);
- 自动跟底,回滚即停跟,「回到实时」按钮;
- `ended` 事件后显示「这场分享已结束」,稿保留在页面上直到关闭。
