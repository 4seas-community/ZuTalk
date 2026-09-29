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
    nonisolated static func builtinKind(
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

/// The header's path for a topic or recording page. The page used to repeat
/// this in a row of its own, and again as a large title under its tabs.
struct EditorBreadcrumb: Equatable {
    struct Recording: Equatable, Identifiable {
        var id: String { sessionID }
        var sessionID: String
        /// What it is called now; empty when untitled.
        var storedTitle: String
        /// The recording's title, or when it has none its start time.
        var label: String
        /// Start time (when titled), length and languages.
        var detail: String?
        var status: RecordingPresentation.Status?
    }

    var topicID: String?
    /// Nil for a recording that belongs to no topic yet.
    var topicTitle: String?
    var recording: Recording?
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
    /// Where the page under the header sits — the topic, and for a
    /// recording which one — published by that page for the header's path.
    @Published var editorBreadcrumb: EditorBreadcrumb?
    /// A recording opened straight onto its notes or its files, from a list
    /// row's menu. The recording page applies it once it has loaded.
    @Published var pendingSessionSurface: SessionSupplementarySurface?
    /// The topic the Record page should have chosen when it opens — set by a
    /// topic's own Record button, which leads there instead of starting a
    /// second way.
    @Published var recordTopicPreselection: String?

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

    /// Settings, landing on one section — "add your own key" lands on live
    /// captions rather than wherever settings was last left.
    func openSettings(section: SettingsSection) {
        SettingsRouter.shared.section = section
        select(tab: .config)
    }

    /// The one place recordings start, with a topic already chosen.
    func openRecordPage(topicID: String?) {
        recordTopicPreselection = topicID
        select(tab: .record)
    }

    /// The recording in progress, reached from the sidebar's first item. The
    /// sidebar keeps that item highlighted while its live page is open.
    func openLiveRecording() {
        activePrimaryTab = .record
        openActiveNotebookForCapture()
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

    func openSession(_ sessionID: String, surface: SessionSupplementarySurface) {
        pendingSessionSurface = surface
        openSession(sessionID)
    }

    /// The route lookup in flight for the last recording clicked, if any.
    private var sessionRouteTask: Task<Void, Never>?

    func openSession(_ sessionID: String) {
        sessionRouteTask?.cancel()
        sessionRouteTask = Task { [weak self] in
            await self?.openSessionResolvingRoute(sessionID)
        }
    }

    /// Opens a recording where it lives.
    ///
    /// Finding that place reads every topic's tabs, links and projections —
    /// close to a hundred queries on a library of twenty topics. It used to
    /// run on the main thread inside the click; now the click returns at
    /// once and the lookup happens off the main thread.
    func openSessionResolvingRoute(_ sessionID: String) async {
        guard let core = coreProvider() else {
            ToastCenter.shared.error(
                String(localized: "session.route.unavailable"),
                detail: String(localized: "session.route.unavailable_detail")
            )
            return
        }
        let captureContext = captureRouteContextProvider()
        let isActiveCapture = captureContext.isActive
            && captureContext.sessionID == sessionID
        let (route, failure) = await Task.detached(priority: .userInitiated) {
            () -> (ResolvedSessionRoute?, String?) in
            do {
                return (
                    try Self.resolveNotebookRoute(
                        for: sessionID,
                        core: core,
                        isActiveCapture: isActiveCapture
                    ),
                    nil
                )
            } catch {
                return (nil, String(describing: error))
            }
        }.value
        guard Task.isCancelled == false else { return }

        if let failure {
            Self.logger.error(
                "Open recording failed: \(failure, privacy: .private)"
            )
            ToastCenter.shared.error(
                String(localized: "session.route.unavailable"),
                detail: String(localized: "session.route.unavailable_detail")
            )
            return
        }
        guard let route else {
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
        case .record:
            return .record
        case .home:
            return .home
        case .topics:
            return .topics
        case .trash:
            return .trash
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

    typealias ResolvedSessionRoute = (notebookID: String, tabID: String, documentID: String)

    nonisolated private static func resolveNotebookRoute(
        for sessionID: String,
        core: any ZuTalkCoreProtocol,
        isActiveCapture: Bool
    ) throws -> ResolvedSessionRoute? {
        let session = try core.getSession(id: sessionID)
        let tasks = (try? core.listTasks(statusFilter: nil)) ?? []
        let preferredKind = SessionDefaultTabPolicy.builtinKind(
            sessionType: session.sessionType,
            hasAsyncTask: TranscriptionTaskIndex.makeIndex(tasks: tasks)[sessionID] != nil,
            isActiveCapture: isActiveCapture
        )

        var routableNotebooks = try core.listNotebooks()
        for systemNotebook in [
            try? core.getQuickCaptureNotebook(),
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
            if linkedDirectly == false {
                for tab in tabs {
                    let hasProjection = try core.listNotebookSessionProjections(tabId: tab.id)
                        .contains { $0.deletedAt == nil && $0.sessionId == sessionID }
                    if hasProjection {
                        projectedTabIDs.insert(tab.id)
                        break
                    }
                }
            }

            guard linkedDirectly || projectedTabIDs.isEmpty == false else { continue }
            let preferred = tabs.first {
                $0.builtinKind == preferredKind
            } ?? tabs.first {
                $0.builtinKind == "realtime_transcript"
            } ?? tabs.first

            guard let preferred else { return nil }
            return (notebook.id, preferred.id, preferred.docId)
        }
        return nil
    }
}
