# Zulangue

Zulangue 是一款原生 macOS 语音笔记应用。它使用 SwiftUI/AppKit 构建界面，
使用 Rust 处理录音状态、转录、持久化、加密和导出，并通过 UniFFI 连接两端。

## 仓库

- 主仓库：[4Seas/zulangue](https://tea.4seas.xyz/4Seas/zulangue)
- GitHub 镜像：[4seas-community/zulangue](https://github.com/4seas-community/zulangue)

代码维护、分支和标签以 Gitea 主仓库为准。主仓库的提交会自动镜像到 GitHub，
并由 GitHub Actions 运行构建与测试；不要直接向 GitHub 镜像推送提交。

## 功能

- 在 Notebook 中录音或导入音频
- 使用 Soniox 进行实时或异步转录
- 将录音、转录和手写笔记保存在本机
- 编辑、检索并导出内容
- 在发送音频或上下文前要求明确的用户操作

## 开发

首次准备环境：

```bash
just setup
```

生成 Rust 核心、UniFFI 绑定并同步 Xcode 项目：

```bash
just dev
```

随后用 Xcode 打开 `macos/Zulangue/Zulangue.xcodeproj`。

## 测试

```bash
just local-gate
```

也可以按需运行：

```bash
just test
just swift-test
just ci-check
```

## 打包

当前社区发布路线：

1. 构建 arm64 与 x86_64 Universal App，并使用 Ad Hoc 代码签名；
2. 创建带 Applications 快捷方式的 DMG；
3. 在发布 Mac 上使用专用 Sparkle Ed25519 私钥签署更新包和 appcast；
4. 将 DMG、SHA-256 校验文件和 `appcast.xml` 发布到 GitHub Release；
5. 已安装的 Zulangue 通过 Sparkle 2 从 HTTPS appcast 检查更新并提示用户。

当前安装包没有 Apple Developer ID 签名或公证，首次打开时可能需要在 Finder
中右键选择“打开”，或在“隐私与安全性”中确认。Sparkle 私钥只保存在发布
Mac 的登录 Keychain，GitHub Actions 只做无私钥的构建和测试。完整步骤见
[macOS 发布说明](docs/releasing.md)。

## 目录

- `crates/`：Rust 核心
- `macos/Zulangue/`：macOS 应用和测试
- `docs/`：当前公开文档
- `design-system/`：界面设计原则
- `scripts/`：当前构建与验证脚本
- `fuzz/`：模糊测试入口

## 隐私

音频、转录和笔记默认保存在本机。远程转录只在用户发起对应操作后进行。
API 凭据不得写入源码、日志、诊断信息或命令行参数。
服务凭据保存在应用私有目录的 `Secrets/provider-credentials.json` 中，仅供当前
macOS 登录账户读取；它不会进入 Keychain、UserDefaults 或 SQLite。

## License

GPL-3.0-or-later，详见 [LICENSE](LICENSE)。
