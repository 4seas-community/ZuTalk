import AppKit
import Combine
import Foundation
import OSLog

enum NotebookCaptureRouteSessionPolicy {
    static func resolve(
        requestedSessionId: String?,
        targetNotebookId: String,
        isRealtimeTab: Bool,
        activeCaptureNotebookId: String?,
        activeCaptureSessionId: String?,
        isCaptureActive: Bool
    ) -> String? {
        // An explicit Session selection is user intent. A live capture in the
        // same Topic must not silently replace a historical row the user chose.
        if let requestedSessionId, requestedSessionId.isEmpty == false {
            return requestedSessionId
        }
        guard isRealtimeTab,
              isCaptureActive,
              activeCaptureNotebookId == targetNotebookId,
              let activeCaptureSessionId,
              activeCaptureSessionId.isEmpty == false
        else { return requestedSessionId }
        return activeCaptureSessionId
    }
}

enum SessionDefaultTabPolicy {
    static func builtinKind(
        sessionType: String,
        hasAsyncTask: Bool,
        isActiveCapture: Bool
    ) -> String {
        if isActiveCapture { return "realtime_transcript" }
        if hasAsyncTask || sessionType.lowercased() == "import" {
            return "async_transcript"
        }
        return "realtime_transcript"
    }
}

@MainActor
final class MainNavigationStore: ObservableObject {
    static let shared = MainNavigationStore()
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "xyz.voice.zutalk",
        category: "MainNavigation"
    )

    typealias CaptureRouteContext = (
        notebookID: String?,
        sessionID: String?,
        isActive: Bool
    )

    @Published private(set) var activeTab: MainTab = .home
    /// Keeps the first-level information architecture selected while an
    /// editor route is open beneath it (for example Topic -> Session).
    @Published private(set) var activePrimaryTab: MainTab = .home
    @Published private(set) var activeRoute: MainRoute = .home
    @Published private(set) var needsOnboarding: Bool = OnboardingController.shouldShowOnboarding
    @Published private(set) var activeEditorRoute: EditorRoute?
    @Published private(set) var activeNotebookTitle: String?
    @Published private(set) var pendingEditorView: EditorInitialView = .notes

    private let activeNotebookIDProvider: @MainActor () -> String?
    private let captureRouteContextProvider: @MainActor () -> CaptureRouteContext
    private let coreProvider: @MainActor () -> (any ZuTalkCoreProtocol)?
    private let notebookContext: NotebookSessionContextStore
    private var didAttemptLaunchNotebookRestore = false

    var activeDocID: String? { activeEditorRoute?.documentID }
    var activeNotebookID: String? { activeEditorRoute?.notebookID }
    var activeNotebookTabID: String? { activeEditorRoute?.tabID }
    var selectedSessionID: String? { activeEditorRoute?.selectedSessionID }

    init(
        activeNotebookIDProvider: @escaping @MainActor () -> String? = {
            NotebookSessionContextStore.shared.activeNotebookId
        },
        captureRouteContextProvider: @escaping @MainActor () -> CaptureRouteContext = {
            let capture = ActiveBilingualTranscriptStore.shared
            return (capture.notebookId, capture.sessionId, capture.isCaptureActive)
        },
        coreProvider: @escaping @MainActor () -> (any ZuTalkCoreProtocol)? = {
            CoreClient.shared.core
        },
        notebookContext: NotebookSessionContextStore? = nil
    ) {
        self.activeNotebookIDProvider = activeNotebookIDProvider
        self.captureRouteContextProvider = captureRouteContextProvider
        self.coreProvider = coreProvider
        let resolvedNotebookContext = notebookContext ?? NotebookSessionContextStore.shared
        self.notebookContext = resolvedNotebookContext
        recordSnapshot()
    }

    func completeOnboarding() {
        needsOnboarding = false
        recordSnapshot()
    }

    func presentOnboarding() {
        needsOnboarding = true
        recordSnapshot()
    }

    func select(tab: MainTab) {
        let route = route(for: tab)
        if tab != .editor {
            activePrimaryTab = tab
        }
        activeTab = route.tab
        activeRoute = route
        recordSnapshot()
    }

    func openSettings() {
        select(tab: .config)
    }

    func navigateHome() {
        select(tab: .home)
    }

    func navigateTopics() {
        select(tab: .topics)
    }

    /// One-shot launch reconciliation. A remembered Topic does not navigate;
    /// only an actually active capture returns to its realtime workspace.
    @discardableResult
    func restoreLastNotebookOnLaunch() -> Bool {
        guard needsOnboarding == false,
              didAttemptLaunchNotebookRestore == false
        else { return didAttemptLaunchNotebookRestore }
        guard activeTab == .home,
              activeEditorRoute == nil
        else {
            didAttemptLaunchNotebookRestore = true
            return true
        }
        // A remembered Topic is context, not a reason to bypass the global
        // Session ledger on every cold launch. Only an actually active capture
        // earns an automatic return to the recording surface.
        let captureContext = captureRouteContextProvider()
        guard captureContext.isActive,
              let captureNotebookID = captureContext.notebookID,
              captureNotebookID.isEmpty == false else {
            didAttemptLaunchNotebookRestore = true
            return true
        }

        let completed = openNotebookForCapture(
            preferredNotebookID: captureNotebookID,
            selectedSessionID: captureContext.sessionID,
            allowsFallback: false,
            showsErrors: false
        )
        if completed {
            didAttemptLaunchNotebookRestore = true
        }
        return completed
    }

    /// Routes every non-Notebook capture affordance to the active Notebook.
    /// It never starts, pauses, resumes, or stops capture; those controls live
    /// exclusively in `NotebookCaptureToolbar`.
    func openActiveNotebookForCapture() {
        let captureContext = captureRouteContextProvider()
        let activeCaptureNotebookID: String?
        if captureContext.isActive,
           let capturedNotebookID = captureContext.notebookID,
           capturedNotebookID.isEmpty == false {
            activeCaptureNotebookID = capturedNotebookID
        } else {
            activeCaptureNotebookID = nil
        }
        let preferredNotebookID = captureContext.isActive
            ? activeCaptureNotebookID
            : activeNotebookIDProvider()
        openNotebookForCapture(
            preferredNotebookID: preferredNotebookID,
            selectedSessionID: captureContext.isActive
                && activeCaptureNotebookID == preferredNotebookID
                ? captureContext.sessionID
                : nil,
            allowsFallback: captureContext.isActive == false,
            showsErrors: true
        )
    }

    /// Opens a Topic as a research workspace. This is deliberately separate
    /// from capture routing: browsing a Topic must not drop the user directly
    /// into microphone controls or imply that recording has started.
    func openTopicWorkspace(notebookID: String) {
        guard notebookID.isEmpty == false,
              let core = coreProvider()
        else {
            ToastCenter.shared.error(
                String(localized: "topic.route.unavailable"),
                detail: String(localized: "topic.route.unavailable_detail")
            )
            return
        }

        do {
            guard let notebook = try core.listNotebooks().first(where: {
                $0.deletedAt == nil && $0.id == notebookID
            }),
            let tab = try core.listNotebookTabs(notebookId: notebookID)
                .first(where: {
                    $0.deletedAt == nil && $0.builtinKind == "realtime_transcript"
                })
            else { throw NotebookSessionLifecycleError.notebookRequired }

            activeEditorRoute = EditorRoute(
                notebookID: notebookID,
                tabID: tab.id,
                documentID: tab.docId,
                selectedSessionID: nil,
                opensTopicWorkspace: true
            )
            activeNotebookTitle = notebook.title
            notebookContext.updateActiveNotebook(id: notebookID, title: notebook.title)
            pendingEditorView = .notes
            activePrimaryTab = .topics
            select(tab: .editor)
        } catch {
            Self.logger.error(
                "Open Topic workspace failed: \(String(describing: error), privacy: .private)"
            )
            ToastCenter.shared.error(
                String(localized: "topic.route.unavailable"),
                detail: String(localized: "topic.route.unavailable_detail")
            )
        }
    }

    func openNotebookTab(
        notebookID: String,
        tabID: String,
        documentID: String,
        selectedSessionID: String?
    ) {
        let captureContext = captureRouteContextProvider()
        let isRealtimeTab: Bool
        if let core = coreProvider(),
           let tabs = try? core.listNotebookTabs(notebookId: notebookID) {
            isRealtimeTab = tabs.contains(where: {
                $0.id == tabID
                    && $0.deletedAt == nil
                    && $0.builtinKind == "realtime_transcript"
            })
        } else {
            isRealtimeTab = false
        }
        let resolvedSessionID = NotebookCaptureRouteSessionPolicy.resolve(
            requestedSessionId: selectedSessionID,
            targetNotebookId: notebookID,
            isRealtimeTab: isRealtimeTab,
            activeCaptureNotebookId: captureContext.notebookID,
            activeCaptureSessionId: captureContext.sessionID,
            isCaptureActive: captureContext.isActive
        )
        let notebookTitle = resolveNotebookTitle(notebookID: notebookID)
        activeEditorRoute = EditorRoute(
            notebookID: notebookID,
            tabID: tabID,
            documentID: documentID,
            selectedSessionID: resolvedSessionID
        )
        activeNotebookTitle = notebookTitle
        notebookContext.updateActiveNotebook(id: notebookID, title: notebookTitle)
        // Builtin tabs are persistent Loro documents. Even the realtime tab
        // opens that document directly; selectedSessionID is filter/context.
        pendingEditorView = .notes
        select(tab: .editor)
    }

    /// Opens the Notebook's builtin realtime document for one explicit
    /// capture session. Settings is a UI-only tab, so starting there must not
    /// inherit whichever document happened to be hidden behind it.
    func openRealtimeTranscript(
        notebookID: String,
        selectedSessionID: String
    ) {
        guard notebookID.isEmpty == false,
              selectedSessionID.isEmpty == false,
              let core = coreProvider()
        else {
            ToastCenter.shared.error(
                String(localized: "capture.route.unavailable"),
                detail: String(localized: "capture.route.unavailable_detail")
            )
            return
        }

        do {
            guard let tab = try core.listNotebookTabs(notebookId: notebookID)
                .first(where: {
                    $0.deletedAt == nil && $0.builtinKind == "realtime_transcript"
                })
            else { throw NotebookSessionLifecycleError.notebookRequired }

            openNotebookTab(
                notebookID: notebookID,
                tabID: tab.id,
                documentID: tab.docId,
                selectedSessionID: selectedSessionID
            )
        } catch {
            Self.logger.error(
                "Open realtime capture transcript failed: \(String(describing: error), privacy: .private)"
            )
            ToastCenter.shared.error(
                String(localized: "capture.route.unavailable"),
                detail: String(localized: "capture.route.unavailable_detail")
            )
        }
    }

    /// Binds a newly-created capture to the route that launched it so the
    /// realtime transcript appears immediately. Starting from Manual Notes (or
    /// any non-realtime tab) intentionally keeps the user's current page.
    func bindStartedCaptureSession(notebookID: String, sessionID: String) {
        guard sessionID.isEmpty == false,
              let route = activeEditorRoute,
              route.notebookID == notebookID,
              let core = coreProvider(),
              let tab = try? core.listNotebookTabs(notebookId: notebookID).first(where: { $0.id == route.tabID }),
              tab.deletedAt == nil,
              tab.builtinKind == "realtime_transcript"
        else { return }

        openNotebookTab(
            notebookID: notebookID,
            tabID: route.tabID,
            documentID: route.documentID,
            selectedSessionID: sessionID
        )
    }

    func openSession(_ sessionID: String) {
        guard let core = coreProvider() else {
            ToastCenter.shared.error(
                String(localized: "session.route.unavailable"),
                detail: String(localized: "session.route.unavailable_detail")
            )
            return
        }

        do {
            guard let route = try notebookRoute(for: sessionID, core: core) else {
                Self.logger.warning(
                    "Session has no Notebook route: \(sessionID, privacy: .private)"
                )
                ToastCenter.shared.warning(
                    String(localized: "session.route.unavailable"),
                    detail: String(localized: "session.route.unavailable_detail")
                )
                return
            }
            openNotebookTab(
                notebookID: route.notebookID,
                tabID: route.tabID,
                documentID: route.documentID,
                selectedSessionID: sessionID
            )
        } catch {
            Self.logger.error(
                "Open recording failed: \(String(describing: error), privacy: .private)"
            )
            ToastCenter.shared.error(
                String(localized: "session.route.unavailable"),
                detail: String(localized: "session.route.unavailable_detail")
            )
        }
    }

    func recordSnapshot() {
        CrashDiagnostics.noteMainWindowState(
            activeTab: activeTab.rawValue,
            needsOnboarding: needsOnboarding,
            activeDocId: activeDocID,
            initialView: pendingEditorView.rawValue,
            appActive: NSApp.isActive
        )
    }

    func resetForTesting() {
        activeTab = .home
        activePrimaryTab = .home
        activeRoute = .home
        needsOnboarding = false
        activeEditorRoute = nil
        activeNotebookTitle = nil
        pendingEditorView = .notes
        didAttemptLaunchNotebookRestore = false
        recordSnapshot()
    }

    @discardableResult
    private func openNotebookForCapture(
        preferredNotebookID: String?,
        selectedSessionID: String?,
        allowsFallback: Bool,
        showsErrors: Bool
    ) -> Bool {
        guard let core = coreProvider() else {
            if showsErrors {
                ToastCenter.shared.error(
                    String(localized: "capture.route.unavailable"),
                    detail: String(localized: "capture.route.unavailable_detail")
                )
            }
            return false
        }

        do {
            let notebooks = try core.listNotebooks()
            let normalizedPreferredID = preferredNotebookID?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var preferredNotebook = normalizedPreferredID.flatMap { notebookID in
                notebooks.first(where: { $0.id == notebookID })
            }
            if preferredNotebook == nil, let normalizedPreferredID {
                let systemNotebooks = [
                    try? core.getQuickCaptureNotebook(),
                    try? core.sharedInboxNotebook(),
                ].compactMap { $0 }
                preferredNotebook = systemNotebooks.first { $0.id == normalizedPreferredID }
            }
            let targetNotebook = preferredNotebook ?? (allowsFallback ? notebooks.first : nil)

            guard let targetNotebook else {
                if notebooks.isEmpty, allowsFallback {
                    notebookContext.forgetLastNotebook()
                }
                navigateHome()
                if showsErrors {
                    ToastCenter.shared.warning(
                        String(localized: "capture.route.no_notebook"),
                        detail: String(localized: "capture.route.no_notebook_detail")
                    )
                }
                return false
            }

            guard let tab = try core.listNotebookTabs(notebookId: targetNotebook.id)
                .first(where: {
                    $0.deletedAt == nil && $0.builtinKind == "realtime_transcript"
                }) else {
                throw NotebookSessionLifecycleError.notebookRequired
            }
            openNotebookTab(
                notebookID: targetNotebook.id,
                tabID: tab.id,
                documentID: tab.docId,
                selectedSessionID: selectedSessionID
            )
            return true
        } catch {
            Self.logger.error(
                "Open active Notebook capture failed: \(String(describing: error), privacy: .private)"
            )
            if showsErrors {
                ToastCenter.shared.error(
                    String(localized: "capture.route.unavailable"),
                    detail: String(localized: "capture.route.unavailable_detail")
                )
            }
            return false
        }
    }

    private func resolveNotebookTitle(notebookID: String) -> String? {
        if let core = coreProvider() {
            if let quickCaptureNotebook = try? core.getQuickCaptureNotebook(),
               quickCaptureNotebook.id == notebookID {
                return String(localized: "home.record.unfiled")
            }
            if let notebooks = try? core.listNotebooks(),
               let title = notebooks.first(where: { $0.id == notebookID })?.title {
                return title
            }
        }
        guard notebookContext.activeNotebookId == notebookID else { return nil }
        return notebookContext.activeNotebookTitle
    }

    private func route(for tab: MainTab) -> MainRoute {
        switch tab {
        case .home:
            return .home
        case .topics:
            return .topics
        case .knowledge:
            return .knowledge
        case .trash:
            return .trash
        case .share:
            return .share
        case .editor:
            guard let activeEditorRoute else { return .home }
            return .editor(
                route: activeEditorRoute,
                initialView: pendingEditorView
            )
        case .config:
            return .settings
        }
    }

    private func notebookRoute(
        for sessionID: String,
        core: any ZuTalkCoreProtocol
    ) throws -> EditorRoute? {
        let session = try core.getSession(id: sessionID)
        let captureContext = captureRouteContextProvider()
        let preferredKind = SessionDefaultTabPolicy.builtinKind(
            sessionType: session.sessionType,
            hasAsyncTask: TranscriptionTaskIndex.load(core: core)[sessionID] != nil,
            isActiveCapture: captureContext.isActive
                && captureContext.sessionID == sessionID
        )

        var routableNotebooks = try core.listNotebooks()
        for systemNotebook in [
            try? core.getQuickCaptureNotebook(),
            try? core.sharedInboxNotebook(),
        ].compactMap({ $0 })
        where routableNotebooks.contains(where: { $0.id == systemNotebook.id }) == false {
            routableNotebooks.append(systemNotebook)
        }

        for notebook in routableNotebooks {
            let tabs = try core.listNotebookTabs(notebookId: notebook.id)
                .filter { $0.deletedAt == nil }
            let linkedDirectly = try core.listNotebookSessions(notebookId: notebook.id)
                .contains { $0.sessionId == sessionID }

            var projectedTabIDs = Set<String>()
            for tab in tabs {
                let hasProjection = try core.listNotebookSessionProjections(tabId: tab.id)
                    .contains { $0.deletedAt == nil && $0.sessionId == sessionID }
                if hasProjection { projectedTabIDs.insert(tab.id) }
            }

            guard linkedDirectly || projectedTabIDs.isEmpty == false else { continue }
            let preferred = tabs.first {
                $0.builtinKind == preferredKind
            } ?? tabs.first {
                $0.builtinKind == "realtime_transcript"
            } ?? tabs.first

            guard let preferred else { return nil }
            return EditorRoute(
                notebookID: notebook.id,
                tabID: preferred.id,
                documentID: preferred.docId,
                selectedSessionID: sessionID
            )
        }
        return nil
    }
}
