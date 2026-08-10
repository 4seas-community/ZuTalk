# 服务改名：产品叫 ZuTalk，部署叫 zulangue

产品在 0.4.0 改名为 ZuTalk。**后端的部署侧整体留在 `zulangue`，并且到此冻结。**

## 判据（先读这条，它取代此前所有个案判断）

> **凡是某个系统拿来「找东西」的字符串 → `zulangue`，永不再改。
> 凡是人读的字符串 → `ZuTalk`。**

问一个问题就能分类：**这个仓库之外，是不是已经有谁攥着这串字符？** 攥着它的可能是
DNS、三台机器的文件系统、已经发出去的客户端二进制、Soniox 的用量日志、访客的浏览
器。是，就归 `zulangue`；不是，就归 `ZuTalk`。

这条判据是从三次返工里换来的。此前写的是「凡是用来找**改名之前就已经存在的东西**
的名字，都不跟着改名走」——意思一样，但它要求每次现场判断「算不算已经存在」，而这
个判断先后判错了主机名、环境变量键、Soniox 归属前缀、中继状态文件路径四次。换成
「标识符还是文案」之后不需要判断。

**「全都改成 zutalk」这个终点根本不存在**，这是冻结的硬理由：归属前缀存在 Soniox
的用量日志里（保留 91 天，第三方记录），语言选择存在访客自己的浏览器里——这两样
不归我们控制，无论上不上机器改，都凑不出一套齐整的 `zutalk`。

## 0. 主机名迁移已撤销

**决定（2026-08-11）：三个 `zutalk-*` 主机名不启用，客户端与服务端一律继续用
`zulangue-*`。** 第 3.1、3.4、3.5 节随之作废，保留在下面只为记录当时的推理。

| 常量 | 位置 | 指向 |
|---|---|---|
| `DEFAULT_RELAY_URL` | crates/vt-ffi/src/share_api.rs | `zulangue-relay.exe.xyz` |
| `DEFAULT_WEB_CAPTION_SERVICE` | crates/vt-ffi/src/share_web.rs | `zulangue-caption.exe.xyz` |
| 邀请码 `baseURL` | macos/ZuTalk/ZuTalk/App/CommunityInviteSession.swift | `zulangue-invite.exe.xyz` |

这三个常量编译进用户机器上的二进制，发出去就改不动。0.3.x 与 0.4.0 已装的客户端
里是同样三个地址，所以维持现状意味着**没有任何一台已装客户端会因为改名而失效**。
caption 的 `--public-base` 同理：已经发出去的二维码与观看页链接继续有效，而那些
链接的持有者不是你的用户，本来就没有渠道通知。

撤销之前的推理仍然成立，只是结论反过来了：迁移主机名的代价是已装客户端与已发出
的链接同时失效，收益只是名字整齐。主机名对用户不可见——它出现在二维码里，不出现
在界面上——所以这份收益买不起那份代价。

判断这件事不能靠人记得：`just release-tag` 会先跑
`scripts/check_service_endpoints.sh`，从源码常量里取出主机名，逐个确认能解析且
HTTPS 连得上，否则拒绝打标签。它现在守的是上表这三个名字。

### 0.1 曾经的决定（2026-08-10，已撤销）

原计划是不设过渡期、切换即下线旧名，接受已装客户端与已发出链接同时失效。客户端
常量先改成了 `zutalk-*`（a6ec1d9），DNS 记录始终没有添加，于是工作区里的代码有一
天指向了三个不存在的主机名——构建、测试与当时所有门禁照常通过。
`scripts/check_service_endpoints.sh`（f1c99bd）就是为拦住这个窗口写的，也确实拦住
了 0.4.1。

## 1. 永远不改的名字（全量）

改这些不会报错，只会静默地弄坏东西。「谁攥着它」那一列就是判据本身。

### 1.1 客户端与发布

| 名字 | 在哪 | 谁攥着 | 改了会怎样 |
|---|---|---|---|
| `~/Library/Application Support/Zulangue` | LegacyIdentityMigration.swift | 老用户的硬盘 | 录音与笔记找不到，迁移静默失效 |
| `xyz.voice.zulangue`（bundle ID） | 同上 | 老用户的偏好设置 | 偏好读不到 |
| `.zulangue-core.lock` / `zulangue.db` | 同上 | 老用户的数据目录 | 迁移认不出旧目录 |
| `xyz.voice.zulangue.community-invite` | CommunityInviteSession.swift | 老用户的 Keychain | 已兑换的邀请码消失 |
| Sparkle keychain 账户 `Zulangue` | justfile / docs/releasing.md | 本机 Keychain | 发布时找不到私钥；App 内置公钥对应的就是这把。**有门禁**：scripts/test_release_distribution_gate.sh |
| 三个 `zulangue-*.exe.xyz` 主机名 | share_api.rs / share_web.rs / CommunityInviteSession.swift | DNS + 已发布的二进制 | 已装客户端全部失联（见第 0 节）。**有门禁**：scripts/check_service_endpoints.sh |
| CHANGELOG 中 0.3.x 条目 | CHANGELOG.md | 已发布的原文 | 不回溯改写（文件抬头已写明） |

### 1.2 服务端部署

| 名字 | 在哪 | 谁攥着 | 改了会怎样 |
|---|---|---|---|
| `ZULANGUE_ADMIN_TOKEN` / `ZULANGUE_RELAY_AUTH_TOKEN` / `ZULANGUE_INVITE_DB` | community-invite/server.py `env_secret` | 三台机器的 `service.env` | 管理面板与中继鉴权立刻 401（第 2 节） |
| `zulangue-community:` 归属前缀 | community-invite/server.py `USAGE_REFERENCE_PREFIX` | **Soniox 的用量日志（91 天，改不了）** | 改名前签发的用量永久算不进任何邀请码的配额——`INSERT OR IGNORE` 按 uuid 去重，重跑 reconcile 也不纠正 |
| `~/zulangue-{share-relay,caption-web,community-invite}` | 五个单元文件 + report-stats.py 的 `STATE_FILE` | 三台机器的文件系统 | 单元起不来；中继统计写不进 `ReadWritePaths`，丢掉上次读数后把整个单调计数器当成一个区间的增量 |
| `zulangue-*.service` / `.timer` 单元名 | services/*/ | 三台机器的 systemd | `After=` 依赖落空，旧单元不会被顶掉 |
| `zulangue-caption` / `zulangue-relay` VM 名 | 两份 README 的部署命令 | exe.dev 平台 | 命令指向不存在的 VM |
| `zulangue-ui-lang` / `zulangue-content-langs` | caption-web/server.py 的观看页 | **访客自己的浏览器** | 老观众已保存的语言栏选择清空，而那些浏览器碰不到也通知不到 |

### 1.3 反过来，这些是文案，跟着产品走

页面 `<title>` 与 `<h1>`、systemd 的 `Description=`、HTTP `Server:` 头
（`zutalk-caption-web`、`ZuTalkCommunityInvite/1`）、docstring 与全部中文文档。
它们没有第二个持有者，所以随时可改，也确实都是 ZuTalk。

`Server:` 头长得像标识符但不是——没有任何测试或脚本匹配它。**长相不算数，持有者
才算数**，这一条正是判据比直觉可靠的地方。

### 1.4 例外：P2P 是 `zutalk`，而且对

ALPN `zutalk/live-caption/1`、`zutalk/doc-sync/1`、`zutalk/nearby/1`、签名域
`zutalk/envelope/v1`、房间域 `zutalk/room/v1`、分享码前缀 `zutalkshare`。

它们同样是标识符，但两端都是 App，而 0.4.0 已经把「两台 Mac 必须同版本」写进了
CHANGELOG 并发出去了。持有者是**已发布的 0.4.0 客户端**，所以冻结在 `zutalk`。
判据没有破例：跟着持有者走，这里的持有者恰好拿的就是新名字。

HTTP 线上协议（`/v1/rooms`、`/frame`、`/blocks`、`/segment`、`/r/<id>`、
`/healthz`）**一个产品名都不含**，所以它天然不受任何改名影响。新加接口照此办理。

## 2. 环境变量：只认一个名字，而且是改名前那个

**决定（2026-08-11）：`ZULANGUE_ADMIN_TOKEN` / `ZULANGUE_RELAY_AUTH_TOKEN`
`ZULANGUE_INVITE_DB` 保持原名，仓库跟着机器走。** 三台机器的 `service.env` 里现在
就是这三个名字，改代码等于要求同一步改机器，而这份收益只是名字整齐。

没有回退——只认一个名字。代码与机器一旦对不上，凭据读空，每个调用方都拒绝请求，
失败是响亮的，而不是一个继续接受任何输入的服务。保持原名的直接后果是：**这一步
从「必须同一步做」变成「不必做」**。

由 `services/community-invite/test_server.py::ServiceCredentialNameTests` 守住。
它钉的方向也翻过来了：断言 `ZUTALK_*` **不被**接受——将来真要改名，机器必须同
一步改，所以那个名字不能先在代码里单方面开始生效。

## 3. 线上迁移顺序

**整节已作废，一步都不做。** 3.1 / 3.4 / 3.5 是主机名的启用与下线；3.2 是目录、
单元名与 `service.env` 键名。判据落定之后，这些名字全部归 `zulangue`，机器上本来
就是这样，所以**没有迁移可做**。

**服务端代码现在可以直接部署，没有任何前置条件。**

原文整节保留，不是待办，是备查：哪天真要迁移什么，这里的推理与顺序比重写一遍
可靠——尤其是「不要跳步，顺序本身就是不停服的保证」这条。

### 3.1 DNS（需要 DNS 服务商权限）—— 已作废

给三个新名字加记录，指向**与旧名相同的 IP**：

```
zutalk-relay.exe.xyz    → 与 zulangue-relay.exe.xyz 同 IP
zutalk-caption.exe.xyz  → 与 zulangue-caption.exe.xyz 同 IP
zutalk-invite.exe.xyz   → 与 zulangue-invite.exe.xyz 同 IP
```

验证（**不要用本机 `dig`**：如果本机有 VPN/代理的合成 DNS，任何名字都会解析成
`198.18.x.x`，看起来全都成功。用外部解析器）：

```bash
dig +short @1.1.1.1 zutalk-relay.exe.xyz
```

证书也要覆盖新名（Let's Encrypt 的话在服务器上扩 SAN）。

### 3.2 服务器目录与单元改名 —— 已作废

以 caption 为例，其余两台同理：

```bash
ssh zulangue-caption.exe.xyz
sudo systemctl stop zulangue-caption-web
mv ~/zulangue-caption-web ~/zutalk-caption-web
# 新单元来自仓库 services/caption-web/zutalk-caption-web.service
sudo install -m644 zutalk-caption-web.service /etc/systemd/system/
sudo systemctl disable zulangue-caption-web
sudo rm /etc/systemd/system/zulangue-caption-web.service
sudo systemctl daemon-reload
sudo systemctl enable --now zutalk-caption-web
curl -s https://zulangue-caption.exe.xyz/healthz   # 主机名不变，改完仍须可用
```

这一步有**数秒中断**，而它买不到任何东西：目录名与单元名的持有者是这三台机器，
按判据就该留在 `zulangue`。仓库里的单元文件已经改回 `zulangue-*.service`，与机器
一致，直接 `install` 即可，不需要 `mv`、不需要 `disable` 旧单元。

`service.env` 里的键名同样不动（第 2 节）。relay 那台的
`IROH_RELAY_HTTP_BEARER_TOKEN` 也不动——那是中继自己要求的名字，与改名无关。

### 3.3 客户端常量：不动

三个常量（`DEFAULT_RELAY_URL`、`DEFAULT_WEB_CAPTION_SERVICE`、
`CommunityInviteSession.baseURL`）指向 `zulangue-*`，与 0.3.x、0.4.0 已装客户端
里的一致。发版不再有前置条件。

`just release-tag` 仍会先跑 `scripts/check_service_endpoints.sh`——它从源码常量里
取主机名，所以换了指向也不用改脚本，现在守的就是这三个旧名。它查外部解析器：本机
若有 VPN/代理的合成 DNS，任何名字都会"解析成功"。

### 3.4 caption 的 `--public-base` —— 已作废

仓库里的单元维持 `https://zulangue-caption.exe.xyz`。已经发出去的二维码与观看页
链接继续有效。

### 3.5 下线旧主机名 —— 已作废

三个主机名不下线。

## 4. 不需要预告断裂

主机名不换，所以没有断裂可预告：已装客户端的分享、网页字幕、邀请码兑换不受影响，
已发出的二维码与观看页链接继续有效。发布说明里不需要为此写任何东西。

## 5. 当前状态：**结清，没有待办**

- [x] 判据落定（本文抬头），第 1 节是按它分类的全量清单
- [x] 部署侧全部归位 `zulangue`：五个单元文件与其中的路径、Soniox 归属前缀、
      中继状态文件路径、观看页 localStorage 键、admin cookie、三份 README 的部署
      命令与 VM 名、`scripts/share_relay_smoke.sh` 里的远端路径
- [x] 环境变量键名 `ZULANGUE_*`（单名无回退，测试守住反方向）
- [x] 客户端常量与三个主机名指向 `zulangue-*`，与已发布版本一致
- [x] 3.1 / 3.2 / 3.4 / 3.5 全部作废——**机器一个字都不用动**
- [x] **服务端代码可直接部署，无前置条件**

有一件事这份文档核实不了：**机器上的真实状态**。上面每一处「机器上是
`zulangue-*`」都来自本文自己的记录与第 3 节的迁移原文，不是实测。真动手部署前，
上去各看一眼比信这份文档可靠：

```bash
ssh zulangue-caption.exe.xyz 'ls ~; systemctl list-units --all | grep -i zu; grep -o "^[A-Z_]*=" ~/*/service.env'
```

对不上的话，**以机器为准改这份清单**，不要以清单为准改机器——判据的整个要点就是
攥着字符串的那一方说了算。
