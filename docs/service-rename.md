# 服务改名：zulangue-* → zutalk-*

产品在 0.4.0 改名为 ZuTalk。仓库、部署单元、环境变量已经跟着改完；**线上主机名
还没有**。这份文档是把线上也迁过去的顺序，以及一份「哪些名字永远不改」的清单
——后者比前者更重要，因为它是无法从代码里看出来的。

## 0. 先读这条：为什么不能直接替换

三个客户端地址不是普通字符串，是三台正在服务的机器：

| 常量 | 位置 | 指向 |
|---|---|---|
| `DEFAULT_RELAY_URL` | crates/vt-ffi/src/share_api.rs | `zulangue-relay.exe.xyz` |
| `DEFAULT_WEB_CAPTION_SERVICE` | crates/vt-ffi/src/share_web.rs | `zulangue-caption.exe.xyz` |
| 邀请码 `baseURL` | macos/ZuTalk/ZuTalk/App/CommunityInviteSession.swift | `zulangue-invite.exe.xyz` |

已经装了 0.3.x 与 0.4.0 的用户，客户端里硬编码的就是旧地址。更麻烦的是 caption
服务的 `--public-base` 会被**烤进已经发出去的二维码和观看页链接**——那些链接的
持有者不是你的用户，你没有任何渠道通知他们。

所以旧主机名的下线是一个**有代价的决定**，不是清理工作。下线日期见第 4 节。

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

## 2. 环境变量：已经两个名字都认

`ZUTALK_ADMIN_TOKEN` / `ZUTALK_RELAY_AUTH_TOKEN` 是当前名，改名前的 `ZULANGUE_*`
仍然读得到（`services/community-invite/server.py` 的 `env_secret`，以及
report-stats.py 与 smoke-test.sh 里的同款回退）。

这样做的原因：代码与机器上的 `service.env` 不是同一次部署。只认新名的话，谁先落
地都会让管理面板与中继鉴权**静默 401**——日志里不会有任何一行说这是改名造成的。
两边都认，两侧就互相独立，任意顺序都安全。

回退由 `services/community-invite/test_server.py::ServiceCredentialNameTests`
守住，共 4 条。

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

`service.env` 里的键名此时可以改成 `ZUTALK_*`，也可以不改——两边都认（第 2 节）。

### 3.3 客户端常量（下一版 App）

三个常量改指新地址，发一版。**在 3.1 与 3.2 验证通过之前不要做这一步。**

改完之后：新装的客户端用新地址，旧客户端继续用旧地址，两者都通向同一批服务器。

### 3.4 caption 的 `--public-base`

仓库里的单元已经写成 `https://zutalk-caption.exe.xyz`。它一生效，**新生成的**二维
码就指向新地址；**已经发出去的**旧地址二维码依赖旧主机名继续解析。

## 4. 旧名下线日期

**2027-08-10**（0.4.0 发布后一年）。

下线之前必须确认：

1. 旧主机名的访问日志连续 30 天无客户端流量（二维码扫码也算）；
2. Sparkle 更新统计显示 0.3.x / 0.4.0 的活跃安装量归零或可接受；
3. 在下线前一个版本的发布说明里写明旧链接将失效。

三条有任何一条不成立，就把日期往后推——旧名多留一年的成本是一组 DNS 记录和证
书，链接失效的成本是别人手上的二维码打不开。

## 5. 当前状态

- [x] 仓库、systemd 单元、部署文档、冒烟脚本、环境变量（含回退与测试）
- [ ] 3.1 DNS 记录 + 证书
- [ ] 3.2 三台机器的目录与单元改名
- [ ] 3.3 客户端常量（下一版）
- [ ] 3.4 `--public-base` 生效（随 3.2）
- [ ] 4. 到期下线旧名
