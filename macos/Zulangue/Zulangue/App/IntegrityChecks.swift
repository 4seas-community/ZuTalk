// IntegrityChecks.swift
// 应用启动时检查关键组件与配置：
//
// - Info.plist 含必需的 usage description?
// - ZulangueCore 真的初始化了?
// - 菜单栏 NSStatusItem 真的安装上了?
// - 保留的应用级通知 catalog 是否自洽?
// - data dir / app-private provider credential path 安全可达?
// - MainWindowOpener.shared 真的具备主窗口重开能力?
//
// 失败时显示提示，并写入系统日志和本地诊断日志。

import Foundation
import Darwin
import os

/// 单个 integrity check 的结果
struct IntegrityCheckResult: Equatable {
    let name: String
    let passed: Bool
    let detail: String?

    static func ok(_ name: String) -> IntegrityCheckResult {
        IntegrityCheckResult(name: name, passed: true, detail: nil)
    }

    static func fail(_ name: String, _ detail: String) -> IntegrityCheckResult {
        IntegrityCheckResult(name: name, passed: false, detail: detail)
    }
}

/// 启动自检套件
enum IntegrityChecks {

    private static let logger = Logger(subsystem: "xyz.voice.zulangue", category: "integrity")

    // MARK: - 公共 API

    /// 在 app 启动时跑全部检查. 返回所有结果 (含 ok 的, 便于诊断包导出)
    @MainActor
    static func runAll() -> [IntegrityCheckResult] {
        var results: [IntegrityCheckResult] = []

        results.append(checkInfoPlistMicrophoneUsageDescription())
        results.append(checkInfoPlistBundleIdentifier())
        results.append(checkCoreClientInitialized())
        results.append(checkMenuBarStatusItemMounted())
        results.append(checkAllZulangueNotificationsHaveAtLeastOneObserver())
        results.append(checkMainWindowOpenerRegistered())
        results.append(checkApplicationSupportDirWritable())
        results.append(checkProviderCredentialFileLocation())

        return results
    }

    /// 跑全部 + 失败时显示 toast + 写 log + 返回 fail 列表
    /// 调用时机: ZulangueAppDelegate.applicationDidFinishLaunching 末尾
    @MainActor
    static func runOnLaunch() -> [IntegrityCheckResult] {
        let results = runAll()
        let failures = results.filter { !$0.passed }

        if failures.isEmpty {
            logger.info("✓ All \(results.count) integrity checks passed")
            return []
        }

        // 红字 toast (UI test 模式跳过, 避免污染断言)
        if !TestEnvironment.isAnyTestMode {
            let failedNames = failures.map(\.name).joined(separator: ", ")
            ToastCenter.shared.error(
                "Integrity check failed",
                detail: "\(failures.count)/\(results.count) checks failed: \(failedNames)"
            )
        }

        for f in failures {
            logger.error("✗ \(f.name): \(f.detail ?? "no detail")")
        }

        return failures
    }

    // MARK: - 单个 check 实现

    /// Info.plist 必须包含非空的 NSMicrophoneUsageDescription。
    static func checkInfoPlistMicrophoneUsageDescription() -> IntegrityCheckResult {
        let key = "NSMicrophoneUsageDescription"
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty else {
            return .fail(key, "missing or empty in Info.plist")
        }
        return .ok(key)
    }

    /// Bundle identifier 必须非空 (TCC 跟踪权限的依据)
    static func checkInfoPlistBundleIdentifier() -> IntegrityCheckResult {
        guard let id = Bundle.main.bundleIdentifier, !id.isEmpty else {
            return .fail("CFBundleIdentifier", "missing")
        }
        return .ok("CFBundleIdentifier=\(id)")
    }

    /// ZulangueCore (UniFFI Rust handle) 必须初始化
    @MainActor
    static func checkCoreClientInitialized() -> IntegrityCheckResult {
        guard CoreClient.shared.core != nil else {
            return .fail("CoreClient", CoreClient.shared.initError ?? "core not initialized")
        }
        return .ok("CoreClient")
    }

    /// 菜单栏 NSStatusItem 必须已安装(除非 unit test 模式)。
    /// 启动后没装上 = 用户没有任何入口去启动录音 / 打开 settings。
    @MainActor
    static func checkMenuBarStatusItemMounted() -> IntegrityCheckResult {
        if TestEnvironment.isUnitTestMode {
            return .ok("MenuBarStatusItem (skipped in unit test)")
        }
        if !MenuBarCoordinator.shared.isInstalled {
            return .fail("MenuBarStatusItem", "menu bar status item was not installed by AppDelegate")
        }
        return .ok("MenuBarStatusItem")
    }

    /// WindowSystem 重构后,这里只保留应用级通知 catalog 完整性检查。
    static func checkAllZulangueNotificationsHaveAtLeastOneObserver() -> IntegrityCheckResult {
        let names: [Notification.Name] = [
            .zulangueSessionUpdated,
            .zulanguePermissionsMayHaveChanged,
        ]
        let raw = names.map(\.rawValue)
        if raw.contains(where: { $0.isEmpty }) {
            return .fail("Zulangue notifications", "found empty notification name")
        }
        if Set(raw).count != raw.count {
            return .fail("Zulangue notifications", "found duplicate notification names")
        }
        return .ok("Zulangue notifications (\(names.count) names)")
    }

    /// 主窗口必须可以通过统一 opener 打开。
    @MainActor
    static func checkMainWindowOpenerRegistered() -> IntegrityCheckResult {
        if !MainWindowOpener.shared.isRegistered {
            return .fail("MainWindowOpener", "main window open pathway is not ready")
        }
        return .ok("MainWindowOpener")
    }

    /// data dir 可写 (UniFFI 写 SQLite + 加密 .enc 都需要)
    static func checkApplicationSupportDirWritable() -> IntegrityCheckResult {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first
        guard let dir = appSupport else {
            return .fail("Application Support", "URL not available")
        }
        let zulangueDir = dir.appendingPathComponent("Zulangue", isDirectory: true)
        try? FileManager.default.createDirectory(at: zulangueDir, withIntermediateDirectories: true)
        if !FileManager.default.isWritableFile(atPath: zulangueDir.path) {
            return .fail("Application Support", "Zulangue dir not writable: \(zulangueDir.path)")
        }
        return .ok("Application Support (\(zulangueDir.path))")
    }

    /// Verify only ownership/type/mode metadata for the current provider file.
    /// Tests skip the real user profile and pass an isolated fixture explicitly.
    static func checkProviderCredentialFileLocation(
        fileURL explicitFileURL: URL? = nil
    ) -> IntegrityCheckResult {
        if explicitFileURL == nil,
           TestEnvironment.isUnitTestMode || TestEnvironment.isUITestMode {
            return .ok("Provider credentials (skipped in tests)")
        }

        let fileURL = explicitFileURL ?? ProviderCredentialFileStore.defaultFileURL()
        let directoryURL = fileURL.deletingLastPathComponent()
        var directoryInfo = stat()
        guard lstat(directoryURL.path, &directoryInfo) == 0 else {
            return .fail(
                "Provider credentials",
                "private directory unavailable: \(directoryURL.path)"
            )
        }
        guard (directoryInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              directoryInfo.st_uid == geteuid(),
              (directoryInfo.st_mode & mode_t(0o777)) == mode_t(0o700) else {
            return .fail(
                "Provider credentials",
                "private directory ownership, type, or mode is invalid: \(directoryURL.path)"
            )
        }

        var fileInfo = stat()
        guard lstat(fileURL.path, &fileInfo) == 0 else {
            if errno == ENOENT {
                // Remote providers are optional; no file is the expected
                // local-only state before the first explicit Save.
                return .ok("Provider credentials (not configured)")
            }
            return .fail(
                "Provider credentials",
                "credential file metadata is unavailable: \(fileURL.path)"
            )
        }
        guard (fileInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              fileInfo.st_uid == geteuid(),
              (fileInfo.st_mode & mode_t(0o777)) == mode_t(0o600) else {
            return .fail(
                "Provider credentials",
                "credential file ownership, type, or mode is invalid: \(fileURL.path)"
            )
        }
        return .ok("Provider credentials (\(fileURL.path))")
    }
}

// MainWindowOpener.isRegistered 在 ZulangueApp.swift 里直接定义
