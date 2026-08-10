# 服务改名：zulangue-* → zutalk-*

产品在 0.4.0 改名为 ZuTalk。仓库、部署单元、环境变量已经跟着改完；**线上主机名
还没有**。这份文档是把线上也迁过去的顺序，以及一份「哪些名字永远不改」的清单
——后者比前者更重要，因为它是无法从代码里看出来的。

## 0. 先读这条：这次切换会打断谁

三个客户端地址不是普通字符串，是三台正在服务的机器：

| 常量 | 位置 | 现指向（未发布） |
|---|---|---|
| `DEFAULT_RELAY_URL` | crates/vt-ffi/src/share_api.rs | `zutalk-relay.exe.xyz` |
| `DEFAULT_WEB_CAPTION_SERVICE` | crates/vt-ffi/src/share_web.rs | `zutalk-caption.exe.xyz` |
| 邀请码 `baseURL` | macos/ZuTalk/ZuTalk/App/CommunityInviteSession.swift | `zutalk-invite.exe.xyz` |

已发布的 0.3.x 与 0.4.0 里，这三个常量硬编码的仍是**旧地址**——它们编译进了用户
机器上的二进制，改不动。更麻烦的是 caption
服务的 `--public-base` 会被**烤进已经发出去的二维码和观看页链接**——那些链接的
持有者不是你的用户，你没有任何渠道通知他们。

**决定（2026-08-10）：不设过渡期，切换即下线旧名。** 代价是明确的，接受它：

- 0.3.x 与 0.4.0 的已装客户端，分享、网页字幕、邀请码兑换在切换那一刻起失效，
  直到用户更新；
- 已经发出去的旧地址二维码与观看页链接**永久失效**，且持链接的人不是你的用户，
  无法通知。

要降低第一项的影响，就在切换前先把带新地址的版本发出去、给更新留出时间；第二项
无法降低，只能承担。

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

## 2. 环境变量：只认一个名字

`ZUTALK_ADMIN_TOKEN` / `ZUTALK_RELAY_AUTH_TOKEN`，没有回退。

代价是代码与机器上的 `service.env` **必须同一步更新**：只改一边，管理面板与中继
鉴权会立刻 401。这是刻意的——凭据读空时每个调用方都拒绝请求，失败是响亮的，而
不是一个继续接受任何输入的服务。第 3.2 节把两件事放在同一步。

由 `services/community-invite/test_server.py::ServiceCredentialNameTests` 守住，
其中一条专门断言改名前的 `ZULANGUE_*` **不再**被接受。

## 3. 线上迁移顺序

每一步都可单独回退。**不要跳步**——顺序本身就是不停服的保证。

### 3.1 DNS（需要 DNS 服务商权限）

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
ssh zutalk-caption.exe.xyz
sudo systemctl stop zulangue-caption-web
mv ~/zulangue-caption-web ~/zutalk-caption-web
# 新单元来自仓库 services/caption-web/zutalk-caption-web.service
sudo install -m644 zutalk-caption-web.service /etc/systemd/system/
sudo systemctl disable zulangue-caption-web
sudo rm /etc/systemd/system/zulangue-caption-web.service
sudo systemctl daemon-reload
sudo systemctl enable --now zutalk-caption-web
curl -s https://zulangue-caption.exe.xyz/healthz   # 旧名仍须可用
curl -s https://zutalk-caption.exe.xyz/healthz     # 新名也须可用
```

这一步有**数秒中断**。share-relay 那台中断期间正在进行的分享会重连。

**同一步**把 `service.env` 里的键名改成 `ZUTALK_*`（第 2 节：没有回退，只改一边
会立刻 401）：

```bash
sudo sed -i 's/^ZULANGUE_/ZUTALK_/' ~/zutalk-community-invite/service.env
```

relay 那台的 `IROH_RELAY_HTTP_BEARER_TOKEN` 不动——那是中继自己要求的名字。

### 3.3 客户端常量（已改，随下一版发出）

三个常量已经指向新地址（`DEFAULT_RELAY_URL`、`DEFAULT_WEB_CAPTION_SERVICE`、
`CommunityInviteSession.baseURL`）。**这一版必须在 3.1 与 3.2 验证通过之后才能
发布**，否则新客户端会连向尚不存在的主机名。

### 3.4 caption 的 `--public-base`

仓库里的单元已经写成 `https://zutalk-caption.exe.xyz`，随 3.2 生效。此后**新生成
的**二维码指向新地址；已经发出去的旧地址二维码在 3.5 之后失效。

### 3.5 下线旧主机名

确认 3.1–3.3 全部生效后，删除三条旧 DNS 记录并回收证书。这一步执行后，未更新的
客户端与已发出的旧二维码不再可用（见第 0 节）。

## 4. 建议：把断裂说给用户听

不设过渡期意味着断裂发生在用户那边而不是运维这边，所以它至少要**被预告**：在带
新地址的那一版发布说明里写明「更新后旧的分享链接与二维码会失效，请重新生成」。
这不改变技术方案，只是让失效对用户是预期内的事。

## 5. 当前状态

- [x] 仓库、systemd 单元、部署文档、冒烟脚本、环境变量（单名 + 测试）
- [x] 3.3 客户端常量已指向新地址（**尚未发布**）
- [ ] 3.1 DNS 记录 + 证书
- [ ] 3.2 三台机器的目录、单元与 `service.env` 改名（同一步）
- [ ] 3.4 `--public-base` 生效（随 3.2）
- [ ] 发布带新地址的客户端版本
- [ ] 3.5 删除旧 DNS 记录
