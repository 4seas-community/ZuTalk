# ZuTalk caption-web

共享链接的转发服务。主持人在 App 里开始共享字幕、或给一段录音开只读链接,
App 把**加密后的**字幕帧、转录稿分片推到这里,浏览器打开 `/r/<房间id>#k=<密钥>`
就能看。设计见 [docs/architecture/share-links.md](../../docs/architecture/share-links.md)。

## 它保证什么、不保证什么

- **服务器看不到内容。** 密钥在链接 `#` 后面,浏览器从不把它发给服务器;
  这里存与转发的都是密文。服务器读得懂的只有事件类型、转录稿分片的 id
  (`<录音>:<片号>`,按它覆盖)与分割线种类(暂停时清掉最后一帧)。
- **观看页由这里下发。** 运营者理论上能下发一份会偷密钥的页面 —— 这是
  网页端加密的固有代价。页面是内联的固定版本,带 CSP(`connect-src 'self'`)、
  `Referrer-Policy: no-referrer`、`Cache-Control: no-store`。
- **稿留到留存期满,然后清掉。** 默认 24 小时,从最后一次推送算起
  (`--retention-hours` 可改)。主持人可以随时撤销(`DELETE …?purge=1`),
  当场删掉;直播没选「散场后保留」时,停止即撤销。配了 `--state-file` 就落
  一份盘(密文与发布口令),重启不作废别人手里的链接,服务按 0600 建。
  没有数据库,访问日志已静默。
- **音频从不经过这里。** App 侧的门禁见 `scripts/test_share_no_audio_gate.sh`。
- **房间号 + 密钥即门票。** 拿到完整链接的人都能看 —— 这正是扫码共享的
  语义。主持人可以锁定(新订阅 403)或换链接(旧房间当场删)。
- **上限挡脚本滥用**:建房按调用方限速(6/分钟)、全站 30/分钟、房间总数
  200、载荷 1 MiB、单房订阅 200。调用方身份取自 `X-Forwarded-For` ——
  TLS 在边缘终结,不认这个头的话每个请求的 peer 都是回环地址,「按调用方」
  会变成「全站」。那个头客户端能伪造,所以它只分桶,放行由全站桶兜底。
- **旧版本(0.5.8 及更早)推的是明文**,服务端照旧转发、观看页照旧显示
  (没有 `ct` 字段的载荷原样通过)。

## 部署(exe.dev)

与 invite 同一形态:单文件 Python(仅标准库)、systemd 托管、
TLS 由 exe.dev 边缘终结,VM 只讲 HTTP。

exe.dev 的边缘代理**固定转发到 `:8000`**、每台 VM 只有一个代理端口,所以
caption-web 独占一台 VM(`zulangue-caption`),与 relay 不合并的理由相同。

```bash
# exe.dev 控制台
ssh exe.dev new --name zulangue-caption --cpu 1 --memory 1GB
ssh exe.dev tag zulangue-caption seas4

# VM 上(服务目录按 zulangue-caption-web.service 里的 WorkingDirectory)
scp server.py zulangue-caption.exe.xyz:zulangue-caption-web/
scp zulangue-caption-web.service zulangue-caption.exe.xyz:
ssh zulangue-caption.exe.xyz 'sudo install -m644 zulangue-caption-web.service \
    /etc/systemd/system/ && sudo systemctl daemon-reload && \
    sudo systemctl enable --now zulangue-caption-web'

# 放开登录墙(不放开的话,扫码的人会先被要求登录 exe.dev)
ssh exe.dev share port zulangue-caption 8000
ssh exe.dev share set-public zulangue-caption

curl -s https://zulangue-caption.exe.xyz/healthz
```

`--public-base` 必须是浏览器可达的公开地址 —— 观看页链接由服务端用它拼出。

**注意 SSE**:边缘代理需要允许长响应(禁响应缓冲)。服务端每 25 秒发
一条心跳注释,穿透常见的空闲超时。`scripts/caption_web_prod_smoke.sh`
对已部署实例验证整条链路(含 SSE 穿透)。

## 接口

载荷都是信封 `{"v": 2, "ct": "<base64url 密文>", …}`;服务端不解密。

| 方法 | 路径 | 鉴权 | 说明 |
| --- | --- | --- | --- |
| POST | `/v1/rooms` | 无(限速) | 建房 → `{room_id, publish_token, viewer_url}` |
| POST | `/v1/rooms/{id}/meta` | Bearer | 这场共享的说明(标题、直播与否、能否下载),只留最新 |
| POST | `/v1/rooms/{id}/frame` | Bearer | 最新一帧(replace-in-full) |
| POST | `/v1/rooms/{id}/blocks` | Bearer | 转录稿的一片,按明文的 `session_id`(`<录音>:<片号>`)覆盖 |
| POST | `/v1/rooms/{id}/segment` | Bearer | 分割线(追加);明文 `kind` 为 `paused` 时清掉最后一帧 |
| POST | `/v1/rooms/{id}/lock` | Bearer | `{"locked": bool}`;锁上后新订阅 403,已在看的不受影响 |
| GET | `/v1/rooms/{id}/stats` | Bearer | `{viewers, locked, ended}`;顺带探一次所有订阅者,关掉的页面出列 |
| GET | `/v1/rooms/{id}` | 无 | `{locked, ended}` 或 404;观看页开门前问一句,不含内容 |
| DELETE | `/v1/rooms/{id}` | Bearer | 封笔:订阅者收 `ended`,不再收推送,稿留到留存期满 |
| DELETE | `/v1/rooms/{id}?purge=1` | Bearer | 撤销:订阅者收 `ended {"purged": true}`,房间与内容当场删掉(已封笔的也能撤) |
| GET | `/v1/rooms/{id}/events` | 无 | SSE:`init`(全量) → `meta`/`frame`/`blocks`/`segment` 增量 → `ended`;已封笔的房间发完全量直接给 `ended` |
| GET | `/r/{id}` | 无 | 观看页(内联 HTML/JS,无外部资源);房间不在也给页面,由页面说「已失效」 |
| GET | `/healthz` | 无 | 探活 |

## 测试

```bash
python3 -m unittest
```
