// DebugLog.swift
// 调试模式开关 + 统一的 toast/日志记录器
//
// 默认关闭。Settings 里可以开启,开启后:
//   - DebugLog.info/warn 会出 toast(正常用户看不到)
//   - 所有 info/warn/error 都追加到 ~/Library/Application Support/Zulangue/debug.log
//
// 用法:
//   DebugLog.info("⌘B bold", detail: "selected 5 chars")
//   DebugLog.error("apply failed", detail: "\(error)")
//
// 约定:
//   - error 永远出 toast(用户需要知道哪里错了),但写文件需要 debug mode
//   - info / warn 只在 debug mode 下才出 toast
//   - 日志文件超 1MB 自动 rotate 成 debug.log.1(只保留一代)

import Foundation
import SwiftUI

/// @AppStorage 存的 key
enum DebugModeKey {
    static let enabled = "zulangue.debugMode"
}

enum DebugLog {
    // MARK: - State

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: DebugModeKey.enabled)
    }

    static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: DebugModeKey.enabled)
    }

    // MARK: - Log API

    @MainActor
    static func info(_ title: String, detail: String? = nil) {
        guard isEnabled else { return }
        ToastCenter.shared.info(title, detail: detail)
        appendLine("INFO", title: title, detail: detail)
    }

    @MainActor
    static func warn(_ title: String, detail: String? = nil) {
        guard isEnabled else { return }
        ToastCenter.shared.warning(title, detail: detail)
        appendLine("WARN", title: title, detail: detail)
    }

    /// 低噪声诊断日志: 只写文件,不弹 toast.
    static func trace(_ title: String, detail: String? = nil) {
        guard isEnabled else { return }
        appendLine("TRACE", title: title, detail: detail)
    }

    /// error 永远出 toast(真实错误用户必须知道),但文件记录仅 debug 模式下做
    @MainActor
    static func error(_ title: String, detail: String? = nil) {
        ToastCenter.shared.error(title, detail: detail)
        if isEnabled {
            appendLine("ERROR", title: title, detail: detail)
        }
    }

    // MARK: - File location

    /// `~/Library/Application Support/Zulangue/debug.log`
    static var logFileURL: URL {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = support.appendingPathComponent("Zulangue", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("debug.log")
    }

    /// 清空 debug.log(Settings "Clear logs" 按钮用)
    static func clearLog() {
        try? FileManager.default.removeItem(at: logFileURL)
    }

    // MARK: - Internal

    private static let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// 超过这个大小就 rotate 到 debug.log.1
    private static let maxBytes: UInt64 = 1 * 1024 * 1024

    private static let writeQueue = DispatchQueue(label: "xyz.voice.zulangue.debug-log")

    private static func appendLine(_ level: String, title: String, detail: String?) {
        let timestamp = dateFormatter.string(from: Date())
        let line: String
        if let detail = detail, !detail.isEmpty {
            line = "[\(timestamp)] \(level) \(title) — \(detail)\n"
        } else {
            line = "[\(timestamp)] \(level) \(title)\n"
        }

        writeQueue.async {
            rotateIfNeeded()
            writeLine(line)
        }
    }

    private static func writeLine(_ line: String) {
        let url = logFileURL
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            // 文件不存在 → 创建
            try? data.write(to: url)
        }
    }

    private static func rotateIfNeeded() {
        let url = logFileURL
        guard
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = (attrs[.size] as? NSNumber)?.uint64Value,
            size > maxBytes
        else { return }

        let rotated = url.deletingLastPathComponent().appendingPathComponent("debug.log.1")
        try? FileManager.default.removeItem(at: rotated)
        try? FileManager.default.moveItem(at: url, to: rotated)
    }
}
