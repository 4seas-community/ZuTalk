# 服务改名：仓库改完，主机名不改

产品在 0.4.0 改名为 ZuTalk。仓库、部署单元、工作目录、环境变量已经跟着改完；
**线上主机名不跟着改**。这份文档的主体是一份「哪些名字永远不改」的清单——它无法
从代码里看出来——外加一份主机名迁移的顺序，那份现在是备查，不是待办。

## 0. 先读这条：主机名迁移已撤销

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

## 1. 永远不改的名字

改这些不会报错，只会静默地弄坏东西。每一条都在代码里有注释，这里是索引：

| 名字 | 在哪 | 改了会怎样 |
|---|---|---|
| `~/Library/Application Support/Zulangue` | LegacyIdentityMigration.swift | 老用户的录音与笔记找不到，迁移静默失效 |
| `xyz.voice.zulangue`（bundle ID） | 同上 | 老用户的偏好设置读不到 |
| `.zulangue-core.lock` / `zulangue.db` | 同上 | 迁移认不出旧数据目录 |
| `xyz.voice.zulangue.community-invite` | CommunityInviteSession.swift | 老用户已兑换的邀请码从 Keychain 里消失 |
| Sparkle keychain 账户 `Zulangue` | justfile / docs/releasing.md | 发布时找不到私钥；App 内置公钥对应的就是这把。**有门禁强制**：scripts/test_release_distribution_gate.sh |
| CHANGELOG 中 0.3.x 条目 | CHANGELOG.md | 已发布的原文不回溯改写（文件抬头已写明这条规矩） |

判据是一致的：**凡是用来找「改名之前就已经存在的东西」的名字，都不跟着改名走。**

## 2. 环境变量：只认一个名字，而且是改名前那个

**决定（2026-08-11）：`ZULANGUE_ADMIN_TOKEN` / `ZULANGUE_RELAY_AUTH_TOKEN`
`ZULANGUE_INVITE_DB` 保持原名，仓库跟着机器走。** 它们属于第 1 节那张表的同一
类：用来找「改名之前就已经存在的东西」的名字。三台机器的 `service.env` 里现在
就是这三个名字，改代码等于要求同一步改机器，而这份收益只是名字整齐。

没有回退——只认一个名字。代码与机器一旦对不上，凭据读空，每个调用方都拒绝请求，
失败是响亮的，而不是一个继续接受任何输入的服务。保持原名的直接后果是：**这一步
从「必须同一步做」变成「不必做」**，第 3.2 节因此只剩目录与单元名。

由 `services/community-invite/test_server.py::ServiceCredentialNameTests` 守住。
它钉的方向也翻过来了：断言 `ZUTALK_*` **不被**接受——将来真要改名，机器必须同
一步改，所以那个名字不能先在代码里单方面开始生效。

## 3. 线上迁移顺序

**3.1、3.4、3.5 已作废**（见第 0 节）：它们是启用与下线主机名的步骤，而主机名不
换了。原文保留，因为哪天真要迁移时，推理与顺序比重写一遍可靠。

3.2 只剩目录与单元名，`service.env` 键名已随第 2 节撤销——仓库现在和机器一样认
`ZULANGUE_*`，**服务端代码可以直接部署，没有前置条件**。剩下的目录与单元改名是
纯粹的整齐，尚未决定做不做。

每一步都可单独回退。**不要跳步**——顺序本身就是不停服的保证。

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

### 3.2 服务器目录与单元改名（每台机器）

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

这一步有**数秒中断**。share-relay 那台中断期间正在进行的分享会重连。

**`service.env` 里的键名不动**（第 2 节已撤销）：`ZULANGUE_*` 是仓库现在认的名
字，动它就是那条 401。relay 那台的 `IROH_RELAY_HTTP_BEARER_TOKEN` 同样不动——那
是中继自己要求的名字。

也就是说这一步只剩 `mv` 和单元名，没有任何东西要求它和一次部署同步。

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

## 5. 当前状态

- [x] 仓库、systemd 单元、部署文档、冒烟脚本
- [x] 3.3 客户端常量指向 `zulangue-*`，与已发布版本一致
- [x] 3.1 / 3.4 / 3.5 已作废（主机名不换）
- [x] 第 2 节环境变量键名已撤销回 `ZULANGUE_*`（单名 + 测试守住反方向）——
      **服务端代码现在可以直接部署，没有前置条件**
- [ ] 3.2 三台机器的目录与单元改名——纯整齐，尚未决定做不做；不做的话，仓库里的
      `zutalk-*.service`（含 `WorkingDirectory=/home/exedev/zutalk-*`）与机器上
      的实际路径对不上，谁照着它部署谁踩坑
