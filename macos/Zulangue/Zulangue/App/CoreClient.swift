// CoreClient.swift
// ZulangueCore 全局持有 + 错误处理
// 权威：docs/design/D5-uniffi-api.md

import Foundation

// MARK: - CoreClient

/// ZulangueCore 全局单例持有器
///
/// Swift 端通过 CoreClient.shared.core 访问 Rust 核心。
/// 在 App 启动时初始化，初始化路径：~/Library/Application Support/Zulangue
@MainActor
final class CoreClient {
    static let shared = CoreClient()

    /// 底层 Rust 核心实例
    let core: ZulangueCore?

    /// 初始化错误（如果有）
    let initError: String?

    private init() {
        if let ffiError = uniffiVtFfiInitializationError() {
            self.core = nil
            self.initError = ffiError
            return
        }

        do {
            let dataDir = Self.defaultDataDir()
            // The sole production constructor defers durable task claims until
            // provider credentials have been restored or cleared fail-closed.
            let core = try ZulangueCore.newDeferred(dataDir: dataDir)

            self.core = core
            self.initError = nil
        } catch {
            self.core = nil
            self.initError = String(describing: error)
        }
    }

    /// 默认数据目录：~/Library/Application Support/Zulangue
    nonisolated static func defaultDataDir() -> String {
        let fm = FileManager.default
        let environment = ProcessInfo.processInfo.environment
        let dir: URL
        if TestEnvironment.isUnitTestMode || TestEnvironment.isUITestMode {
            if let explicitPath = environment["VT_TEST_DATA_DIR"], !explicitPath.isEmpty {
                dir = URL(fileURLWithPath: explicitPath, isDirectory: true)
            } else {
                dir = fm.temporaryDirectory
                    .appendingPathComponent("ZulangueTests", isDirectory: true)
                    .appendingPathComponent(String(ProcessInfo.processInfo.processIdentifier), isDirectory: true)
            }
        } else {
            let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            dir = appSupport.appendingPathComponent("Zulangue", isDirectory: true)
        }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }
}

// MARK: - Error helpers

extension CoreError {
    var userMessage: String {
        switch self {
        case .InitFailed(let message):       return "Init failed: \(message)"
        case .ValidationFailed(let message): return "Validation failed: \(message)"
        case .NotFound(let message):         return "Not found: \(message)"
        case .InternalError(let message):    return "Internal error: \(message)"
        @unknown default:                    return "Unknown error"
        }
    }
}
