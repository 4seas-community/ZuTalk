# ZuTalk caption-web

扫码看实时字幕稿。主持人在分享页开启「网页分享」后,App 把字幕帧与稿的块
快照推到这里,浏览器扫二维码打开 `/r/<房间id>` 就能看,多语言可切换。
设计见 [docs/architecture/share-web-captions.md](../../docs/architecture/share-web-captions.md)。

## 它保证什么、不保证什么

- **字幕明文经过本服务。** 这是与 P2P 分享的本质区别,也是产品定案
  (2026-08-09):网页观看端不装应用,没有端到端密钥可言。App 的开启
  界面会把这句话说给主持人。
- **稿留到留存期满,然后清掉。** 默认 24 小时,从最后一次推送算起
  (`--retention-hours` 可改)。主持人停止共享**只封笔不删** —— 散场
  恰恰是最多人去读稿的时候,删房等于把「扫码看字幕」缩成「必须现场
  看完」。配了 `--state-file` 就落一份盘,重启不作废别人手里的链接;
  那份文件里有字幕明文与发布口令,服务按 0600 建。没有数据库,没有
  日志里的内容明文(访问日志已静默)。

  「进程重启即空」曾写在这里当保证,其实不是:明文本来就要在这台机器上
  待满整个留存期,重启清空只是让恰好那一刻拿着链接的人白拿。真正的
  保证是留存期本身,以及 App 开启界面把这件事说给主持人。
- **音频照旧结构性排除。** 本服务只接收与 P2P 字幕通道相同的纯文本
  载荷,App 侧的四层音频门禁原样生效。
- **房间号即门票。** `room_id` 不可猜测;拿到链接的人都能看 —— 这正是
  扫码分享的语义。发布口令只有主持人持有。
- **上限挡脚本滥用**:建房按调用方限速(6/分钟)、全站 30/分钟、房间总数
  200、载荷 1 MiB、单房订阅 200。调用方身份取自 `X-Forwarded-For` ——
  TLS 在边缘终结,不认这个头的话每个请求的 peer 都是回环地址,「按调用方」
  会变成「全站」。那个头客户端能伪造,所以它只分桶,放行由全站桶兜底。
  建房接邀请码门禁(与 relay 门禁同构)列为延后项,滥用真出现了再立。

## 部署(exe.dev)

与 invite / relay 同一形态:单文件 Python(仅标准库)、systemd 托管、
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

| 方法 | 路径 | 鉴权 | 说明 |
| --- | --- | --- | --- |
| POST | `/v1/rooms` | 无(限速) | 建房 → `{room_id, publish_token, viewer_url}` |
| POST | `/v1/rooms/{id}/frame` | Bearer | 最新一帧(replace-in-full) |
| POST | `/v1/rooms/{id}/blocks` | Bearer | 某场录音的稿(块快照,按 session 只留最新) |
| DELETE | `/v1/rooms/{id}` | Bearer | 封笔:订阅者收 `ended`,不再收推送,稿留到留存期满 |
| GET | `/v1/rooms/{id}/events` | 无 | SSE:`init`(全量) → `frame`/`blocks` 增量 → `ended`;已封笔的房间发完全量直接给 `ended` |
| GET | `/r/{id}` | 无 | 观看页(内联 HTML/JS,无外部资源) |
| GET | `/healthz` | 无 | 探活 |

## 测试

```bash
python3 -m unittest
```
