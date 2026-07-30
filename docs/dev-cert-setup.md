# macOS 签名

本地开发构建由 Xcode 的 Signing 设置处理。每位开发者应在自己的 Xcode
环境中选择可用的 Development Team，不要把个人 Team ID 写入公共项目配置。

公开分发需要：

1. 使用 Developer ID Application 证书签名。
2. 启用 Hardened Runtime。
3. 将安装包提交 Apple 公证。
4. 对公证成功的应用或 DMG 执行 staple。
5. 使用 Gatekeeper 验证最终产物。

签名身份和公证凭据应通过本机 Keychain 或受保护的发布环境提供，不得提交到
仓库。
