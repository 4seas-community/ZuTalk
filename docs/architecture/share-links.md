# 共享：端到端加密的链接

定案 2026-09-28，取代 [share-p2p.md](share-p2p.md)（点对点）与
[share-web-captions.md](share-web-captions.md)（明文网页分享）。两份旧文档
保留作历史记录。

## 0. 为什么推倒重来

点对点共享在真实场景里几乎没人进得来：

- **观众拿的是手机。** 点对点要求对方也在 Mac 上装着 ZuTalk。
- **加入码 130 多个字符。** 念不出来，只能复制粘贴。
- **跨网络靠中继，中继只放行有邀请码的设备。** 教室、会场的 Wi-Fi 普遍隔离
  设备，同一网络也连不上。
- **实时字幕本来就要联网**（Soniox 在云端），走一台服务器转发不降低可用性。

旧的网页分享解决了「手机能看」，代价是字幕明文经过服务器，还藏在面板
最底下。新方案把这两条合成一条：**谁拿到链接谁能在浏览器里看，服务器只
经手看不懂的密文。**

## 1. 两种共享

| | 直播字幕 | 录好的录音 |
| --- | --- | --- |
| 入口 | 录音条上的「共享字幕」 | 录音行菜单、录音页顶栏的「共享…」 |
| 对方拿到 | 二维码 / 链接，浏览器里看实时字幕与转录稿 | ① 一份文件（Markdown / SRT），经系统分享菜单发出；② 只读链接 |
| 能不能下载 | 主持人打开「散场后保留转录稿」才能 | 能 |
| 失效 | 停止即删；保留的话约 24 小时 | 24 小时，随时可撤销 |
| 控制 | 观看人数、锁定、换个链接、停止 | 撤销 |

不做：他人订正、附近发现、「收到的」页。点对点里做过的这三样随点对点
一起下线。

## 2. 加密

- 每条链接一把**现生成**的 AES-256-GCM 密钥（`LinkKey`，不复用任何录音的
  音频密钥），放在链接 `#k=` 后面。浏览器从不把 `#` 后面的部分发给服务器。
- 密文格式与 WebCrypto 对齐：`12 字节随机数 ‖ 密文 ‖ 16 字节校验码`，
  base64url 编码。观看页用 `crypto.subtle.decrypt` 解。
- 信封：`{"v": 2, "ct": "<密文>", ...}`。服务器只读得懂的明文字段只有三样：
  - 事件类型（URL 路径：`frame` / `blocks` / `segment` / `meta`）；
  - 转录稿分片的 id `"session_id": "<录音>:<片号>"`，服务器按它覆盖；
  - 分割线的种类 `"kind": "paused" | "started"`，暂停时服务器要清掉最后一帧。

  标题、字幕、译文、说话人名字都在密文里。
- **已知代价**：观看页的 JavaScript 由服务器下发，运营者理论上可以下发一份
  会把密钥发走的页面。缓解：页面是内联的固定版本（`services/caption-web/server.py`
  里），CSP `connect-src 'self'`、`Referrer-Policy: no-referrer`、
  `Cache-Control: no-store`；链接的密钥不进服务器日志（片段根本不发）。
- **拿到链接的人都能看。** 链接就是钥匙，App 在开始前说这句话。

## 3. 线路

```
ZuTalk (vt-ffi/src/link_share.rs)            caption-web                 浏览器
────────────────────────────────            ───────────                 ──────
start_live_link ─ POST /v1/rooms ────────►  建房
                  POST …/meta (密文) ─────►  存最新一份
LinkCaptionTap ── POST …/frame (密文) ────►  存最新一帧  ──SSE frame──►  解密、画字幕
投影 ack 后 ───── POST …/blocks (密文片) ─►  按片 id 覆盖 ──SSE blocks─►  合并分片成稿
暂停/恢复 ─────── POST …/segment ─────────►  追加         ──SSE segment►  分割线
refresh_live_link GET …/stats ────────────►  人数(顺带探掉关了的页面)
set_live_link_locked POST …/lock ─────────►  锁定:新订阅 403
replace_live_link 新房间 + DELETE 旧房间?purge=1
stop_live_link ── DELETE …(?purge=1) ─────►  封笔或当场删 ──SSE ended──►  「已结束」/「已撤销」
```

- **转录稿分片**：每片 120 句，指纹不变的片不重推。长讲座的整份稿会超过
  服务端单次 1 MiB 的上限，每次整份重推也白占会场的上行。直播中最多 2 秒
  推一次；字幕帧另走一条任务，不受它拖累。
- **内容来源**：实时转录有内容就用它（连同译文与用户的订正，
  `t2_machine_block_write`）；只有精修结果的录音（导入的音频）退回精修稿的
  纯文字。
- **推送失败不重试不积压**：下一帧、下一次转录稿都是完整的。只有分割线
  重试一次——漏一条就永久少一条线。
- **人数**：服务器在主持人每次询问时给每个订阅者写一条 SSE 注释
  （`: ping`），关掉的页面在一两次询问之内出列；否则要等 25 秒一次的心跳。

## 4. 音频不可共享

共享只有两个出口，都在 `crates/vt-ffi/src/link_share.rs`：加密链接与发送副本
（`transcript_file`，只走 `export_markdown` / `export_srt`）。
`scripts/test_share_no_audio_gate.sh` 四层检查（去掉注释与测试模块之后）：

1. 模块不引用 `vt_audio`、音频解密（`decrypt_session_audio` 等）、PCM 类型；
   加密前的线上结构体字段名里没有 audio / pcm / wav / sample。
2. 链接密钥只能 `SessionKey::generate()`，不从密钥库或已有字节取。
3. 发送副本不走会打包 `audio.wav` 的 zip 导出。
4. App 的共享界面（`*Share*.swift`）不碰音频导出。

## 5. 链接的去留

- **直播**：默认「散场即删」（负责人定案：默认不留、可逐场允许）。打开
  「散场后保留转录稿」后，停止时先把最新的整份推完再封笔，观众约 24 小时内
  还能读、能下载。直播中可以来回改，停止那一刻才定。
- **录音随录音条结束**：录音停了，直播在两拍之内自动停止。
- **退出 App**：最多等 2 秒去停止直播；网络不通就由服务端留存期兜底。
- **录音链接**：建房 → 说明 → 各片 → 封笔，24 小时后服务端清掉。本机台账
  `share-links.json`（0600，含发布口令与带密钥的链接）只为列出与撤销；过期的
  读取时顺手丢掉。推了一半失败的房间当场删，不让残缺链接留在外面。
- **撤销**：`DELETE /v1/rooms/{id}?purge=1`，在看的人收到带 `purged` 的
  `ended`，房间与内容当场从服务器删掉。已结束（封笔）的房间也能撤。

## 6. 观看页

- 八种界面语言，语言名用本族名（Intl.DisplayNames）。
- 打开前先问 `GET /v1/rooms/{id}`：404 说「链接已失效或已撤销」，锁定说
  「主持人已锁定」，链接缺 `#k=` 说「链接不完整」。失效的链接照样给页面，
  扫码的人看到一句说明，不是一段报错。
- 事件按到达顺序排队解密（解密是异步的，不排队会乱序）。
- 下载：说明里 `download: true` 才显示。

## 7. 验证

- `services/caption-web`：`python3 -m unittest`（加密转发、锁定、撤销、失效
  链接页、关掉的页面出列）。
- `link_share::tests::a_link_round_trip_against_the_caption_service`：本机起一份
  caption-web，走完录音链接、直播、暂停、人数、锁定、换链接、留稿与删除，
  断言服务器上没有明文、用链接里的密钥解得开。`scripts/caption_web_smoke.sh`
  驱动它；`scripts/caption_web_prod_smoke.sh` 对生产跑同一条（加
  `LINK_SHARE_SERVICE`），跑完不留房间。

## 8. 点对点的善后

- `crates/vt-share`、`share_api.rs`、`share_web.rs`、`shared_session_docs.rs`
  删除；Swift 的「收到的」页、点对点设置、中继登记、字幕窗的观看模式删除。
- **中继（`services/share-relay`，zulangue-relay.exe.xyz）继续运行**：还没升级
  的旧版本仍在用点对点。新版本不再连它，`check_service_endpoints.sh` 也不再查。
- 旧版本通过点对点收到的转录稿留在用户磁盘上
  （`block-documents/shared/`，以及隐藏的「分享」主题），新版本不删也不显示。
