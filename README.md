# Zulangue

Zulangue 是一款原生 macOS 语音笔记应用。它使用 SwiftUI/AppKit 构建界面，
使用 Rust 处理录音状态、转录、持久化、加密和导出，并通过 UniFFI 连接两端。

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

当前社区发布包：

```bash
just release-adhoc
```

该命令生成一个同时支持 Apple Silicon 和 Intel 的 Universal DMG，并使用
Ad Hoc 签名。打开 DMG 后，将 Zulangue 拖到 Applications 即可安装。
由于它没有 Apple 公证，首次打开时 macOS 可能要求用户在“系统设置 →
隐私与安全性”中确认打开。

需要无安全提示的正式公开分发时，应改用 Developer ID 签名和 Apple 公证。

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
