# Zulangue caption-web

扫码看实时字幕稿。主持人在分享页开启「网页分享」后,App 把字幕帧与稿的块
快照推到这里,浏览器扫二维码打开 `/r/<房间id>` 就能看,多语言可切换。
设计见 [docs/architecture/share-web-captions.md](../../docs/architecture/share-web-captions.md)。

## 它保证什么、不保证什么

- **字幕明文经过本服务。** 这是与 P2P 分享的本质区别,也是产品定案
  (2026-08-09):网页观看端不装应用,没有端到端密钥可言。App 的开启
  界面会把这句话说给主持人。
- **不留超过必要的东西。** 全部状态在内存:主持人停止共享即清房;
  空闲 6 小时自动清;进程重启即空。没有数据库,没有日志里的内容明文
  (访问日志已静默)。
- **音频照旧结构性排除。** 本服务只接收与 P2P 字幕通道相同的纯文本
  载荷,App 侧的四层音频门禁原样生效。
- **房间号即门票。** `room_id` 不可猜测;拿到链接的人都能看 —— 这正是
  扫码分享的语义。发布口令只有主持人持有。
- **上限挡脚本滥用**:建房按 IP 限速(6/分钟)、房间总数 200、载荷
  1 MiB、单房订阅 200。建房接邀请码门禁(与 relay 门禁同构)列为
  延后项,滥用真出现了再立。

## 部署(exe.dev)

与 invite / relay 同一形态:单文件 Python(仅标准库)、systemd 托管、
TLS 由 exe.dev 边缘终结,VM 只讲 HTTP。

```bash
# VM 上(服务目录按 zulangue-caption-web.service 里的 WorkingDirectory)
mkdir -p "$SERVICE_HOME/zulangue-caption-web"
scp server.py "<vm>:$SERVICE_HOME/zulangue-caption-web/"
scp zulangue-caption-web.service <vm>:/etc/systemd/system/
systemctl daemon-reload && systemctl enable --now zulangue-caption-web
curl -s http://127.0.0.1:8100/healthz
```

边缘代理把 `zulangue-caption.exe.xyz` 转发到 `:8100`。`--public-base`
必须是浏览器可达的公开地址 —— 观看页链接由服务端用它拼出。

**注意 SSE**:边缘代理需要允许长响应(禁响应缓冲)。服务端每 25 秒发
一条心跳注释,穿透常见的空闲超时。

## 接口

| 方法 | 路径 | 鉴权 | 说明 |
| --- | --- | --- | --- |
| POST | `/v1/rooms` | 无(限速) | 建房 → `{room_id, publish_token, viewer_url}` |
| POST | `/v1/rooms/{id}/frame` | Bearer | 最新一帧(replace-in-full) |
| POST | `/v1/rooms/{id}/blocks` | Bearer | 某场录音的稿(块快照,按 session 只留最新) |
| DELETE | `/v1/rooms/{id}` | Bearer | 关房,订阅者收 `ended` |
| GET | `/v1/rooms/{id}/events` | 无 | SSE:`init`(全量) → `frame`/`blocks` 增量 → `ended` |
| GET | `/r/{id}` | 无 | 观看页(内联 HTML/JS,无外部资源) |
| GET | `/healthz` | 无 | 探活 |

## 测试

```bash
python3 -m unittest
```
