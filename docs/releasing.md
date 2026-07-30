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

1. 更新 Cargo 与 Xcode 的公开版本号，并递增 Xcode
   `CURRENT_PROJECT_VERSION`。构建号绝不能复用。
2. 更新 `packaging/release-notes.md`。
3. 运行完整本地门禁。
4. 设置标签环境并在本机生成发布产物：

   ```bash
   GITHUB_REPOSITORY=4seas-community/zulangue \
   GITHUB_REF_NAME=v0.1.2 \
   just release-sparkle-adhoc
   ```

5. 为 DMG 生成 SHA-256 文件。
6. 创建 OpenPGP 签名标签并推送提交与标签。
7. 从本机上传以下三个文件到 GitHub Release：

   - `Zulangue-0.1.2.dmg`
   - `Zulangue-macOS.sha256`
   - `appcast.xml`

标签 CI 会重新运行秘密检查、Rust/Swift 测试，并独立编译一个 Ad Hoc
Universal DMG 作为验证产物。CI 不生成 appcast，也不创建 GitHub Release。

appcast 使用稳定 HTTPS 地址：

```text
https://github.com/4seas-community/zulangue/releases/latest/download/appcast.xml
```

其中的实际 DMG 下载地址绑定到不可变的版本标签，不使用可变的 `latest`
下载地址。

## 用户看到的行为

- Zulangue 默认每天检查一次更新，不发送匿名系统画像。
- 检查到新版本时，Sparkle 显示原生提示，由用户决定下载和安装。
- 用户也可以在 App 菜单或菜单栏弹窗中选择“检查更新…”。
- 更新在解压前验证 Ed25519 签名；appcast 本身也必须通过签名验证。
- 首次安装 `0.1.1` 时，用户可能需要手动通过 Gatekeeper 确认。

不包含 Sparkle 的旧版无法自行获得更新能力。因此，现有 `0.1.0` 用户必须
手动安装一次首个含 Sparkle 的新版本；从该版本开始才可以收到后续提示。

## 发布失败原则

以下任一条件不满足时，不得创建 GitHub Release：

- 标签、Cargo 与 Xcode 版本不一致；
- 构建号没有递增；
- Sparkle 公钥缺失；
- App 不是预期的 Ad Hoc 签名；
- DMG 条目或 appcast 没有 Sparkle Ed25519 签名；
- appcast 下载地址没有绑定到不可变版本标签；
- 隐私或秘密扫描失败。
