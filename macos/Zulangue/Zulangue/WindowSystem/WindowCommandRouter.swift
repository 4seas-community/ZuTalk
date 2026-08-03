import AppKit
import Combine
import Foundation

enum WindowCommand: String {
    case openMainWindow
    case toggleSubtitleOverlay
    case openSession
    case openSettings
    case openNotebookTab
    case navigateHome
}

struct WindowCommandRecord: Equatable {
    let timestamp: Date
    let command: WindowCommand
    let detail: String
}

@MainActor
struct WindowCommandRouterTestOverrides {
    var openMainWindow: ((String, (@MainActor @Sendable () -> Void)?) -> Void)?
    var toggleSubtitleOverlay: (() -> Void)?
    var openSession: ((String) -> Void)?
    var openSettings: (() -> Void)?
    var openNotebookTab: ((EditorRoute) -> Void)?
    var navigateHome: (() -> Void)?
}

final class WindowCommandRouter {
    static let shared = WindowCommandRouter()

    private let lock = NSLock()
    private var history: [WindowCommandRecord] = []
    private let maxHistory = 80
    @MainActor private var testOverrides: WindowCommandRouterTestOverrides?

    private init() {}

    func openMainWindow(
        detail: String = "router",
        then followUp: (@MainActor @Sendable () -> Void)? = nil
    ) {
        record(.openMainWindow, detail: detail)
        Task { @MainActor in
            if let handler = self.testOverrides?.openMainWindow {
                handler(detail, followUp)
                return
            }
            MainWindowOpener.shared.open(then: followUp)
        }
    }

    func requestToggleSubtitleOverlay() {
        record(.toggleSubtitleOverlay, detail: "current-capture-subtitles")
        Task { @MainActor in
            if let handler = self.testOverrides?.toggleSubtitleOverlay {
                handler()
                return
            }
            SubtitleOverlayCoordinator.shared.toggle()
        }
    }

    func requestOpenSession(_ sessionId: String, revealMainWindow: Bool = false) {
        record(.openSession, detail: "\(sessionId) reveal=\(revealMainWindow)")
        Task { @MainActor in
            let route: @MainActor @Sendable () -> Void = {
                if let handler = self.testOverrides?.openSession {
                    handler(sessionId)
                    return
                }
                MainNavigationStore.shared.openSession(sessionId)
            }
            self.routeMainWindow(
                revealMainWindow: revealMainWindow,
                detail: "open-session:\(sessionId)",
                action: route
            )
        }
    }

    func requestOpenSettings() {
        record(.openSettings, detail: "main-window.config-tab")
        Task { @MainActor in
            if let handler = self.testOverrides?.openSettings {
                handler()
                return
            }
            MainWindowOpener.shared.open {
                MainNavigationStore.shared.openSettings()
            }
        }
    }

    func requestOpenNotebookTab(
        notebookID: String,
        tabID: String,
        documentID: String,
        selectedSessionID: String? = nil,
        revealMainWindow: Bool = false
    ) {
        let route = EditorRoute(
            notebookID: notebookID,
            tabID: tabID,
            documentID: documentID,
            selectedSessionID: selectedSessionID
        )
        record(
            .openNotebookTab,
            detail: "notebook=\(notebookID) tab=\(tabID) session=\(selectedSessionID ?? "<none>") reveal=\(revealMainWindow)"
        )
        Task { @MainActor in
            let action: @MainActor @Sendable () -> Void = {
                if let handler = self.testOverrides?.openNotebookTab {
                    handler(route)
                    return
                }
                MainNavigationStore.shared.openNotebookTab(
                    notebookID: notebookID,
                    tabID: tabID,
                    documentID: documentID,
                    selectedSessionID: selectedSessionID
                )
            }
            self.routeMainWindow(
                revealMainWindow: revealMainWindow,
                detail: "open-notebook-tab:\(tabID)",
                action: action
            )
        }
    }

    func requestNavigateHome() {
        record(.navigateHome, detail: "main-window.home")
        Task { @MainActor in
            if let handler = self.testOverrides?.navigateHome {
                handler()
                return
            }
            MainNavigationStore.shared.navigateHome()
        }
    }

    @MainActor
    func installTestOverrides(_ overrides: WindowCommandRouterTestOverrides?) {
        testOverrides = overrides
    }

    func historySnapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let formatter = CrashDiagnostics.timestampFormatter
        return history.map { record in
            "[\(formatter.string(from: record.timestamp))] \(record.command.rawValue) \(record.detail)"
        }
    }

    @MainActor
    func resetForTesting() {
        lock.lock()
        history.removeAll()
        lock.unlock()
        testOverrides = nil
        MainNavigationStore.shared.resetForTesting()
    }

    @MainActor
    private func routeMainWindow(
        revealMainWindow: Bool,
        detail: String,
        action: @escaping @MainActor @Sendable () -> Void
    ) {
        guard revealMainWindow else {
            action()
            return
        }
        guard !WindowCoordinator.shared.isMainWindowVisible() else {
            action()
            return
        }
        if let handler = testOverrides?.openMainWindow {
            handler(detail, action)
            return
        }
        MainWindowOpener.shared.open(then: action)
    }

    private func record(_ command: WindowCommand, detail: String) {
        let record = WindowCommandRecord(timestamp: Date(), command: command, detail: detail)
        lock.lock()
        history.append(record)
        if history.count > maxHistory {
            history.removeFirst(history.count - maxHistory)
        }
        lock.unlock()

        CrashDiagnostics.record("window.command", command.rawValue, detail: detail)
    }
}
