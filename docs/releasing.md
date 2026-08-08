# macOS 发布与更新

Zulangue 的正式分发链路是：

> Ad Hoc 签名的 Universal DMG → 用户首次确认安装 → Sparkle 2 定期检查
> HTTPS appcast → 显示原生更新提示 → 验证 Ed25519 签名后替换
> `Zulangue.app`

当前项目没有 Apple `Developer ID Application` 证书，因此安装包没有 Apple
公证。首次安装可能被 Gatekeeper 阻止，用户需要在 Finder 中右键选择“打开”，
或到“系统设置 → 隐私与安全性”确认。Ad Hoc 签名不能提供 Apple 开发者身份，
但 Sparkle 签名仍会验证更新包和 appcast 是否由 Zulangue 项目签发。

## 安全边界

当前发布只使用两组彼此独立的凭据：

1. **项目 OpenPGP 密钥**：签 Git 提交和版本标签。
2. **Sparkle Ed25519 密钥对**：验证 Zulangue 更新包和 appcast。

Sparkle 密钥不是 Soniox、GitHub、Apple ID 或 Git 提交签名密钥。它必须为软件
更新单独生成。公钥会放进 App；私钥不得提交到 Git、写入 Release、构建日志或
普通配置文件。

## 一次性配置

### Sparkle 更新签名

从项目固定使用的 Sparkle 2.9.4 官方发行包中运行：

```bash
./bin/generate_keys --account Zulangue
```

该命令会新建专用密钥，并将私钥保存到当前 macOS 登录 Keychain。Base64
公钥写入 Xcode 项目的 `SPARKLE_PUBLIC_ED_KEY` 构建设置；公钥不是秘密，
应跟随源码发布，让每个 Zulangue 安装包只接受该项目签发的更新。

将私钥导出到受保护的离线位置进行备份：

```bash
./bin/generate_keys --account Zulangue -x /secure/offline/Zulangue-Sparkle.key
```

导出的文件等同于更新签名密码，不能放在仓库、同步盘、GitHub Secrets 或聊天
记录中。项目只允许在受控 Mac 上从登录 Keychain 的 `Zulangue` 账户签名；
GitHub Actions 不接收也不使用这把私钥。

## 每次发布

```bash
just bump 0.3.3                 # 版本号一次改对，旧说明归档进 CHANGELOG
$EDITOR packaging/release-notes.md
just local-gate

GITHUB_REPOSITORY=4seas-community/zulangue \
GITHUB_REF_NAME=v0.3.3 \
just release-ship
```

`release-ship` 依次做三件事，任何一步失败都停在原地：

1. **`release-sparkle-adhoc`** — Universal Ad Hoc 构建、DMG、增量更新包、
   用登录 Keychain 里的 Sparkle 私钥签署 appcast，并为这一份 DMG 生成
   `Zulangue-macOS.sha256`。
2. **`release-tag`** — 打 OpenPGP 签名标签，推送提交与标签到主库。
   产物先做出来、标签才推：标签一推出去就是对外承诺。
3. **`release-publish`** — 等 GitHub 镜像收到标签，按 appcast 点名清点
   附件，上传，然后回头逐个确认拿得到。

### 这条链上每一步在防什么

- **目的地**：`GITHUB_REPOSITORY` 必须与 `github` remote 一致。下载地址
  会被**签进** appcast——仓库名打错的话签名依然有效、地址却指向别处，
  从产物上看不出来。`GITHUB_REF_NAME` 由版本检查与 Cargo 版本对齐。
- **镜像竞态**：主库在 Gitea，GitHub 是镜像。抢在同步之前发布的话，
  GitHub 会拿默认分支 HEAD 自己造一个同名标签——既不是那个签名标签，
  还可能指向别的提交。发布前会等，并比对提交号；`gh` 那边也带
  `--verify-tag`。
- **附件齐全**：以 appcast 为准。它点名了哪些文件就传哪些——漏传一个
  delta 不会有任何提示，用户侧签名验证照样通过，下载 404。
- **校验和**：`Zulangue-macOS.sha256` 文件名不带版本号，最容易发出上一
  版的那份。生成由 `sparkle-appcast` 负责，发布前再当场重算一次。
- **delta 基线**：按版本号挑前两个版本，不按文件修改时间——本地任何一
  个旧 DMG 被重建就会静默拿错基线，用户那边表现为白下一遍全量。基线
  还必须是真的发布过的版本。
- **发出去之后**：逐个 HEAD appcast 里的地址，并确认稳定 appcast 地址
  已经指向新版本。

标签 CI 会重新运行秘密检查、Rust/Swift 测试，并独立编译一个 Ad Hoc
Universal DMG。注意它**只证明这份源码在一台干净机器上构建得出来**：
Xcode 加 Ad Hoc 签名不是比特可复现的，所以那份 DMG 无法与本机上传的
那份逐字节对照。CI 不生成 appcast，也不创建 GitHub Release。

appcast 使用稳定 HTTPS 地址：

```text
https://github.com/4seas-community/zulangue/releases/latest/download/appcast.xml
```

其中的实际 DMG 下载地址绑定到不可变的版本标签，不使用可变的 `latest`
下载地址。

## 用户看到的行为

- Zulangue 默认每天检查一次更新，不发送匿名系统画像。
- 检查到新版本时，Sparkle 在后台下载并验证更新包；准备完成后，主窗口侧栏才显示
  “更新并重启”，由用户决定何时安装和重启。
- 用户也可以在 App 菜单或菜单栏弹窗中选择“检查更新…”。
- 更新在解压前验证 Ed25519 签名；appcast 本身也必须通过签名验证。
- 首次安装 `0.1.1` 时，用户可能需要手动通过 Gatekeeper 确认。

不包含 Sparkle 的旧版无法自行获得更新能力。因此，现有 `0.1.0` 用户必须
手动安装一次首个含 Sparkle 的新版本；从该版本开始才可以收到后续提示。

## 发出去之后发现问题

已经发布的版本无法收回：`releases/latest/download/appcast.xml` 是稳定
地址，用户的 Sparkle 随时可能已经取过它。所以这里没有"撤回"，只有
"往前修"。

**首选：立刻发下一版。** `just bump` 递进补丁号，修掉问题，重走一遍
`release-ship`。稳定 appcast 地址会指向新版本，还没更新的人直接跳过坏
的那一版；已经更新的人在下一次检查时被拉回来。这是唯一对所有人都有效
的路径。

**只有在坏版本明确有害时**（会丢数据、会泄露内容），才把那个 GitHub
Release 标成 pre-release 或删掉附件——`latest` 会退回上一版，appcast 也
跟着退回，未更新的人不再拿到它。已经装上的人不会因此回退，仍然要靠下
一版救。删除标签没有意义：标签是历史，删掉只会让已发布的 DMG 地址失效
而救不了任何人。

**不要**重新打同一个版本号：Sparkle 用构建号判断新旧，同一个构建号在
已经装了那一版的人那里永远不会触发更新。

## 发布失败原则

以下任一条件不满足时，不得创建 GitHub Release：

- 标签、Cargo 与 Xcode 版本不一致；
- 构建号没有递增；
- Sparkle 公钥缺失；
- App 不是预期的 Ad Hoc 签名；
- DMG 条目或 appcast 没有 Sparkle Ed25519 签名；
- appcast 下载地址没有绑定到不可变版本标签；
- 隐私或秘密扫描失败；
- `GITHUB_REPOSITORY` 与 `github` remote 不一致；
- GitHub 上的标签还没到，或指向的不是本机那个签名标签；
- appcast 点名的附件没有全部上传，或上传后取不到；
- `Zulangue-macOS.sha256` 描述的不是这一次要发布的 DMG。

上述每一条都由 `just release-ship` 自动执行，`scripts/test_release_distribution_gate.sh`
负责保证这些检查不会被悄悄删掉。
