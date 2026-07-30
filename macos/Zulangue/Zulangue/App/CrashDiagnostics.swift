import Foundation

private func ZulangueUncaughtExceptionHandler(_ exception: NSException) {
    CrashDiagnostics.handleUncaughtException(exception)
}

enum CrashDiagnostics {
    private static let lock = NSLock()
    private static let maxBreadcrumbs = 160
    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static var installed = false
    private static var breadcrumbs: [String] = []
    private static var latestWindowSnapshot = "No window snapshot captured yet."
    private static var latestAppState = "No app state captured yet."

    static var timestampFormatter: ISO8601DateFormatter {
        dateFormatter
    }

    static var crashReportURL: URL {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = support.appendingPathComponent("Zulangue", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("crash-diagnostics.log")
    }

    static func install() {
        lock.lock()
        let shouldInstall = !installed
        if shouldInstall {
            installed = true
        }
        lock.unlock()

        guard shouldInstall else { return }
        NSSetUncaughtExceptionHandler(ZulangueUncaughtExceptionHandler)
        record("diagnostics.install", "uncaught exception handler ready")
    }

    static func clearCrashReport() {
        try? FileManager.default.removeItem(at: crashReportURL)
    }

    static func record(
        _ category: String,
        _ message: String,
        detail: String? = nil,
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        let entry = formattedEntry(
            category: category,
            message: message,
            detail: detail,
            file: String(describing: file),
            line: line
        )

        lock.lock()
        appendBreadcrumbLocked(entry)
        lock.unlock()

        DebugLog.trace("\(category) \(message)", detail: detail)
    }

    @MainActor
    static func noteWindowChromeConfigured(role: String, detail: String) {
        WindowCoordinator.shared.refreshDiagnosticsSnapshot()
        record("window.chrome", role, detail: detail)
    }

    @MainActor
    static func noteHostingSizingStabilized(
        role: String,
        controllersDisabled: Int,
        viewsDisabled: Int,
        detail: String
    ) {
        let summary = "controllersDisabled=\(controllersDisabled) viewsDisabled=\(viewsDisabled) | \(detail)"
        WindowCoordinator.shared.refreshDiagnosticsSnapshot()
        record("window.hosting", role, detail: summary)
    }

    @MainActor
    static func noteMainWindowState(
        activeTab: String,
        needsOnboarding: Bool,
        activeDocId: String?,
        initialView: String,
        appActive: Bool
    ) {
        let summary = "tab=\(activeTab) onboarding=\(needsOnboarding) docId=\(activeDocId ?? "-") initialView=\(initialView) appActive=\(appActive)"
        let changed = updateAppState(summary)
        if changed {
            record("main-window.state", activeTab, detail: summary)
        }
        WindowCoordinator.shared.refreshDiagnosticsSnapshot()
    }

    @MainActor
    static func noteWindowOpenStrategy(_ strategy: String, detail: String) {
        WindowCoordinator.shared.refreshDiagnosticsSnapshot()
        record("main-window.open", strategy, detail: detail)
    }

    @MainActor
    static func noteFrameUpdateRequest(
        role: String,
        reason: String,
        currentFrame: NSRect,
        targetFrame: NSRect,
        animated: Bool
    ) {
        let detail = "reason=\(reason) animated=\(animated) current=\(format(currentFrame)) target=\(format(targetFrame))"
        record("window.frame-request", role, detail: detail)
    }

    static func handleUncaughtException(_ exception: NSException) {
        let report = buildUncaughtExceptionReport(for: exception)
        persistCrashReport(report)
    }

    static func buildUncaughtExceptionReport(for exception: NSException) -> String {
        let snapshot = snapshotState()
        let callStack = exception.callStackSymbols.isEmpty ? Thread.callStackSymbols : exception.callStackSymbols
        let windowCommands = WindowCommandRouter.shared.historySnapshot()
        let recordingCommands = snapshot.breadcrumbs.filter { $0.contains("recording.command") }
        let userInfoDescription: String
        if let userInfo = exception.userInfo, !userInfo.isEmpty {
            userInfoDescription = String(describing: userInfo)
        } else {
            userInfoDescription = "nil"
        }

        return [
            "=== Zulangue Uncaught NSException ===",
            "timestamp: \(dateFormatter.string(from: Date()))",
            "process: \(ProcessInfo.processInfo.processName)",
            "os: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "thread: \(Thread.isMainThread ? "main" : "background")",
            "name: \(exception.name.rawValue)",
            "reason: \(exception.reason ?? "nil")",
            "userInfo: \(userInfoDescription)",
            "",
            "--- App State ---",
            snapshot.appState,
            "",
            "--- Windows ---",
            snapshot.windowSnapshot,
            "",
            "--- Recent Window Commands ---",
            windowCommands.isEmpty
                ? "No window commands captured."
                : windowCommands.joined(separator: "\n"),
            "",
            "--- Recent Recording Commands ---",
            recordingCommands.isEmpty
                ? "No recording commands captured."
                : recordingCommands.joined(separator: "\n"),
            "",
            "--- Recent Breadcrumbs ---",
            snapshot.breadcrumbs.isEmpty ? "No breadcrumbs captured." : snapshot.breadcrumbs.joined(separator: "\n"),
            "",
            "--- Exception Call Stack ---",
            callStack.joined(separator: "\n"),
        ].joined(separator: "\n")
    }

    static func resetForTesting() {
        lock.lock()
        breadcrumbs.removeAll()
        latestWindowSnapshot = "No window snapshot captured yet."
        latestAppState = "No app state captured yet."
        lock.unlock()
    }

    static func updateWindowSnapshot(_ snapshot: String) {
        lock.lock()
        latestWindowSnapshot = snapshot
        lock.unlock()
    }

    private static func persistCrashReport(_ report: String) {
        let url = crashReportURL
        let separator = "\n\n"
        guard let data = (report + separator).data(using: .utf8) else { return }

        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    private static func formattedEntry(
        category: String,
        message: String,
        detail: String?,
        file: String,
        line: UInt
    ) -> String {
        let timestamp = dateFormatter.string(from: Date())
        let location = "\(file):\(line)"
        if let detail, !detail.isEmpty {
            return "[\(timestamp)] \(category) \(message) [\(location)] — \(detail)"
        }
        return "[\(timestamp)] \(category) \(message) [\(location)]"
    }

    private static func appendBreadcrumbLocked(_ entry: String) {
        breadcrumbs.append(entry)
        if breadcrumbs.count > maxBreadcrumbs {
            breadcrumbs.removeFirst(breadcrumbs.count - maxBreadcrumbs)
        }
    }

    @discardableResult
    private static func updateAppState(_ summary: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if latestAppState == summary {
            return false
        }
        latestAppState = summary
        return true
    }

    private static func snapshotState() -> (breadcrumbs: [String], windowSnapshot: String, appState: String) {
        lock.lock()
        defer { lock.unlock() }
        return (breadcrumbs, latestWindowSnapshot, latestAppState)
    }

    private static func format(_ rect: NSRect) -> String {
        String(
            format: "x=%.1f y=%.1f w=%.1f h=%.1f",
            rect.origin.x,
            rect.origin.y,
            rect.size.width,
            rect.size.height
        )
    }
}
