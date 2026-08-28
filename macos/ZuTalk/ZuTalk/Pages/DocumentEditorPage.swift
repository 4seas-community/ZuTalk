// DocumentEditorPage.swift
// 笔记编辑器页面 — Notebook 文档表面的 UI 宿主
// 权威:design-system/MASTER.md §10 · D5 §7.5
//
// 架构:
//   DocumentEditorPage (SwiftUI 宿主)
//     ├── NoteTopChrome  (后退 / title / document 切换器)
//     ├── NoteMetadataBar(pill 元数据)
//     ├── BlockNoteEditorView(大纲编辑器,块文档 FFI)
//     │      └── BlockNoteStore ← noteBlockDocumentOpen / noteApplyOutline
//     └── NoteBottomSignature(local capture metadata)

import AppKit
import Combine
import SwiftUI

/// editor 的初始视图 — 录音启动走 .transcript,其他入口走 .notes(scratchpad 编辑器)。
enum EditorInitialView: String {
    case notes
    case transcript
}

private enum DocumentEditorSidePanel: Equatable {
    case tasks
}

private struct NotebookRouteLoadSnapshot: Sendable {
    let notebookTabs: [NotebookTabViewModel]
    let notebook: FfiNotebook?
    let session: SessionInfo?
    let transcriptionTasksBySessionId: [String: TranscriptionTaskSnapshot]
    /// The quick-capture Notebook is a backend identity, not a display-name
    /// convention. Keep it explicit so an ordinary Topic named "Unfiled"
    /// never receives the homepage-recording settings scope by accident.
    let isQuickCaptureNotebook: Bool
}

private enum NotebookRouteLoadOutcome: Sendable {
    case success(NotebookRouteLoadSnapshot)
    case failure(String)
}

enum NotebookCaptureSettingsRoutePolicy {
    static func notebookId(for route: EditorRoute?) -> String? {
        route?.notebookID
    }

    static func shouldDismiss(previous: EditorRoute?, current: EditorRoute?) -> Bool {
        previous != current
    }

    static func reusesCurrentRoute(selectedTabId: String, activeTabId: String?) -> Bool {
        selectedTabId == activeTabId
    }

    static func isDocumentEditorInteractive(
        showTranscript: Bool,
        presentedSettingsNotebookId: String?
    ) -> Bool {
        showTranscript == false && presentedSettingsNotebookId == nil
    }
}

enum NotebookTranscriptPresentationPolicy {
    static func shouldShow(
        displayType: NotebookTabDisplayType?,
        status _: NotebookTabStatus?,
        selectedSessionId: String?
    ) -> Bool {
        switch displayType {
        case .realtimeTranscript:
            // Realtime is also the Notebook's capture command center. It must
            // exist before the first session and remain reachable when the
            // current projection is pending/failed, so the next recording can
            // still be configured and started here.
            return true
        case .asyncTranscript:
            // The async status bar owns pending/failed presentation. Hiding the
            // whole transcript surface also hid credential recovery and made a
            // selected recording appear to have no available action.
            return selectedSessionId != nil
        case .manualNote, .none:
            return false
        }
    }
}

enum AsyncTranscriptPrimaryAction: Equatable {
    case none
    case addPersonalKey
    case start
}

enum AsyncTranscriptActionPolicy {
    static func isProviderPending(_ providerState: String?) -> Bool {
        guard let normalized = providerState?.lowercased() else { return false }
        return ["pending", "reserved", "enqueued"].contains(normalized)
    }

    static func primaryAction(
        projectionState: NotebookAsyncProjectionState?,
        providerState: String?,
        hasReadyPersonalKey: Bool
    ) -> AsyncTranscriptPrimaryAction {
        guard projectionState == NotebookAsyncProjectionState.none else { return .none }
        let normalizedProviderState = providerState?.lowercased()
        if normalizedProviderState == nil || normalizedProviderState == "none" {
            return hasReadyPersonalKey ? .start : .addPersonalKey
        }
        if isProviderPending(normalizedProviderState), hasReadyPersonalKey == false {
            return .addPersonalKey
        }
        return .none
    }
}

enum AsyncTranscriptContentPhase: Equatable {
    case loading
    case transcript
    case empty
}

enum AsyncTranscriptContentPolicy {
    static func phase(
        hasLines: Bool,
        projectionState: NotebookAsyncProjectionState?,
        providerState: String?,
        tabStatus: NotebookTabStatus,
        hasOperationInFlight: Bool,
        hasLoadFailure: Bool = false
    ) -> AsyncTranscriptContentPhase {
        // Durable content stays usable while a status callback or repair is
        // still reconciling. Never replace a real transcript with a spinner.
        if hasLines { return .transcript }
        if hasOperationInFlight { return .loading }
        if hasLoadFailure { return .empty }
        if projectionState == .pending || projectionState == .projecting {
            return .loading
        }
        if projectionState == .failed { return .empty }
        if AsyncTranscriptActionPolicy.isProviderPending(providerState) {
            return .loading
        }
        if providerState?.lowercased() == "failed" { return .empty }
        if tabStatus == .pending { return .loading }
        if tabStatus == .failed { return .empty }
        if projectionState == nil { return .loading }
        return .empty
    }
}

enum AsyncTranscriptMetadataNoticePolicy {
    static func shouldShow(for lines: [NotebookTranscriptLine]) -> Bool {
        let hasTranscriptContent = lines.contains { line in
            line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
        guard hasTranscriptContent else { return false }

        return lines.contains { line in
            hasProviderSpeaker(line.providerSpeakerLabel)
                || hasSourceLanguage(line.sourceLanguage)
        } == false
    }

    private static func hasProviderSpeaker(_ label: String?) -> Bool {
        guard let label else { return false }
        return label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private static func hasSourceLanguage(_ language: String?) -> Bool {
        guard let language = language?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(separator: "-")
            .first,
            language.isEmpty == false
        else { return false }
        return language != "und"
    }
}

struct DocumentEditorPage: View {
    /// Notebook builtin document + optional session filter. The document is
    /// authoritative; selectedSessionID only scopes contextual UI/export.
    let route: EditorRoute?
    let initialView: EditorInitialView

    private var docId: String? {
        guard let id = route?.documentID, id.isEmpty == false else { return nil }
        return id
    }

    private var selectedSessionId: String? { route?.selectedSessionID }

    private var isShowingManualNotesTimeline: Bool {
        false
    }

    @State private var activeSidePanel: DocumentEditorSidePanel?
    @State private var isShowingExportSheet = false
    @State private var exportingSessionId: String?
    @State private var presentedCaptureSettingsNotebookId: String?
    @State private var isShowingResources: Bool
    @State private var sessionSupplementarySurface: SessionSupplementarySurface?
    @ObservedObject private var navigation = MainNavigationStore.shared
    /// 「分享」收件 Notebook 的判定源。观察它,id 迟到时页面能换对视图。
    @ObservedObject private var shareActivity = ShareActivityStore.shared

    /// Notebook-scoped unified tab surface, including realtime transcript.
    @State private var notebookTabs: [NotebookTabViewModel] = []
    @State private var editorNotebook: FfiNotebook?
    @State private var editorSession: SessionInfo?
    @State private var isQuickCaptureNotebook = false
    @State private var routeLoadError: String?
    @State private var routeLoadGeneration: UInt = 0
    @StateObject private var notebookTasks = NotebookTasksViewModel()
    @StateObject private var captureProfileEditor: NotebookCaptureProfileEditorModel

    /// 当前是否展示 Transcript 视图(Plaud 式)。true 时隐藏笔记编辑层。
    @State private var showTranscript: Bool

    init(route: EditorRoute? = nil, initialView: EditorInitialView = .notes) {
        self.route = route
        self.initialView = initialView
        _captureProfileEditor = StateObject(
            wrappedValue: NotebookCaptureProfileEditorModel(
                notebookId: route?.notebookID ?? ""
            )
        )
        _showTranscript = State(
            initialValue: route?.notebookID == nil && initialView == .transcript
        )
        _isShowingResources = State(
            initialValue: route?.opensTopicWorkspace == true
        )
        _sessionSupplementarySurface = State(initialValue: nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Route contains a stable builtin Loro document ID, so chrome can
            // remain mounted while Notebook metadata refreshes.
            if docId != nil {
                NoteTopChrome(
                    notebookTitle: editorNotebook?.title,
                    session: chromeSession,
                    isTopicWorkspace: isTopicContext,
                    backLabel: String(localized: navigation.activePrimaryTab == .topics
                        ? "sidebar.topics"
                        : "sidebar.home"),
                    onBack: navigateBack
                )

                DocumentTabBar(
                    tabs: notebookTabs,
                    activeTabId: activeNotebookTabId,
                    captureSettingsNotebookId: captureSettingsNotebookId,
                    isCaptureSettingsSelected: isShowingCaptureSettings,
                    isResourcesSelected: isShowingResources,
                    isTopicContext: isTopicContext,
                    sessionId: effectiveSessionId,
                    sessionSupplementarySurface: sessionSupplementarySurface,
                    onSelect: selectNotebookTab,
                    onSelectResources: showResources,
                    onSelectCaptureSettings: showCaptureSettings,
                    onSelectSessionNote: showSessionNote,
                    onSelectSessionSettings: showSessionSettings,
                    onExport: {
                        exportingSessionId = effectiveSessionId
                        isShowingExportSheet = true
                    }
                )

                if routeLoadError != nil {
                    EditorRouteLoadWarning {
                        Task { await loadNotebookRoute() }
                    }
                }

                if isShowingCaptureSettings {
                    NotebookSettingsNotebookHeader(title: editorNotebook?.title)
                } else if isShowingResources == false {
                    NotebookBuiltinTabTitle(title: visibleSurfaceTitle)
                    // 笔记面刻意不挂说明横幅:标签页已经写着「笔记」,
                    // 面包屑已经写着是哪一场会话。写作面前面每多一条
                    // 装饰,落笔前就多一分打断。
                    if sessionSupplementarySurface == .note,
                       effectiveSessionId != nil {
                        EmptyView()
                    } else if sessionSupplementarySurface == nil,
                              activeNotebookTab?.displayType == .manualNote {
                        TopicNotesContextHeader()
                    } else if sessionSupplementarySurface != .settings {
                        NoteMetadataBar(sessionId: effectiveSessionId)
                    }
                }
            }

            // Transcript 和 Editor 在 ZStack 中共存，切换时保留编辑器的光标、
            // 滚动位置和 IME 状态。
            ZStack {
                // Editor 层
                editorLayer
                    .opacity(editorLayerIsVisible ? 1 : 0)
                    .allowsHitTesting(editorLayerIsVisible)
                    .disabled(surface.showsNotebookOverlay)
                    .accessibilityHidden(editorLayerIsVisible == false)

                // Realtime is constructed even without a session: it is the
                // Notebook's capture command center. Async remains
                // session-scoped because it only displays a finished task.
                // 「分享」收件 Notebook 例外:它的内容来自别人的房间,不是
                // 本机采集 —— 同一个 tab 位置换成收件视图(实时画布 + 台账)。
                if let transcriptTab = activeNotebookTab,
                   transcriptTab.displayType == .realtimeTranscript,
                   transcriptTab.notebookId == shareActivity.sharedInboxNotebookId {
                    SharedInboxPage(notebookId: transcriptTab.notebookId)
                        .id("shared-inbox:\(transcriptTab.notebookId)")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .opacity(surface.showsTranscriptLayer ? 1 : 0)
                        .allowsHitTesting(surface.showsTranscriptLayer)
                        .accessibilityHidden(surface.showsTranscriptLayer == false)
                } else if let transcriptTab = activeNotebookTab,
                   transcriptTab.displayType == .realtimeTranscript {
                    NotebookRealtimeTranscriptPage(
                        notebookId: transcriptTab.notebookId,
                        sessionId: effectiveSessionId,
                        editor: captureProfileEditor,
                        onOpenAdvancedSettings: openAdvancedSettingsForCurrentContext
                    )
                        .id("realtime:\(transcriptTab.notebookId):\(effectiveSessionId ?? "new")")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .opacity(surface.showsTranscriptLayer ? 1 : 0)
                        .allowsHitTesting(surface.showsTranscriptLayer)
                        .accessibilityHidden(surface.showsTranscriptLayer == false)
                } else if let sid = effectiveSessionId,
                          let transcriptTab = activeNotebookTab,
                          transcriptTab.displayType == .asyncTranscript {
                    AsyncTranscriptView(
                        notebookId: transcriptTab.notebookId,
                        sessionId: sid,
                        tabId: transcriptTab.tabId,
                        displayType: transcriptTab.displayType,
                        status: transcriptTab.status,
                        taskErrorMessage: selectedTranscriptionTask?.errorMessage
                    )
                    .id("async:\(transcriptTab.notebookId):\(sid):\(transcriptTab.tabId)")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(surface.showsTranscriptLayer ? 1 : 0)
                    .allowsHitTesting(surface.showsTranscriptLayer)
                    .accessibilityHidden(surface.showsTranscriptLayer == false)
                } else if showTranscript && isShowingCaptureSettings == false {
                    // 用户点了 Transcript tab 但 doc 没 session(纯 scratchpad)
                    EmptyState(
                        illustration: { Arcanum003WaveformRuler() },
                        title: String(localized: "editor.empty.no_transcript_title"),
                        description: String(localized: "editor.empty.no_transcript_desc")
                    )
                }

                if let notebookId = presentedCaptureSettingsNotebookId,
                   notebookId == captureSettingsNotebookId {
                    NotebookCaptureSettingsView(
                        notebookId: notebookId,
                        editor: captureProfileEditor,
                        scope: captureSettingsScope,
                        onOpenRealtimeControls: openRealtimeControls
                    )
                        .id(notebookId)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                if isShowingResources, let notebookId = route?.notebookID {
                    NotebookResourcesView(
                        notebookId: notebookId,
                        notebookTitle: editorNotebook?.title,
                        onStartCapture: openRealtimeControls,
                        onOpenResource: { sessionId, destination in
                            openResource(sessionId: sessionId, destination: destination)
                        }
                    )
                    .id("resources:\(notebookId)")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.bgRoot)
        .sheet(isPresented: $isShowingExportSheet, onDismiss: {
            exportingSessionId = nil
        }) {
            if let sessionId = exportingSessionId ?? effectiveSessionId {
                ExportSheet(sessionId: sessionId)
            } else {
                VStack(spacing: Spacing.md) {
                    Image(systemName: "tray")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundColor(.textTertiary)
                    Text(String(localized: "editor.export.no_session"))
                        .font(.bodyMedium)
                        .foregroundColor(.textPrimary)
                }
                .padding(Spacing.xl)
                .frame(width: 360)
                .background(Color.bgRoot)
            }
        }
        .task(id: routeTaskId) {
            await loadNotebookRoute()
        }
        .task(id: route?.notebookID) {
            guard let notebookId = route?.notebookID,
                  notebookId == captureProfileEditor.notebookId
            else { return }
            captureProfileEditor.load()
        }
        .task(id: pendingTranscriptionTaskId) {
            guard pendingTranscriptionTaskId != nil else { return }
            while Task.isCancelled == false {
                try? await MontereyTaskSleep.seconds(1)
                guard Task.isCancelled == false else { return }
                await loadNotebookRoute()
                guard selectedTranscriptionTask?.tabStatus == .pending else { return }
            }
        }
        .montereyOnChange(of: initialView) { _, _ in syncPresentedRoute() }
        .montereyOnChange(of: route) { previousRoute, currentRoute in
            if NotebookCaptureSettingsRoutePolicy.shouldDismiss(
                previous: previousRoute,
                current: currentRoute
            ) {
                presentedCaptureSettingsNotebookId = nil
                isShowingResources = currentRoute?.opensTopicWorkspace == true
                sessionSupplementarySurface = nil
            }
        }
        // 停录后的异步转录物化完成后重新加载关联文档。
        .onReceive(NotificationCenter.default.publisher(for: .zutalkSessionUpdated)) { _ in
            Task {
                await loadNotebookRoute()
            }
        }
    }

    /// Editor 半部(toolbar + 文本编辑 / 状态占位 + signature)。单独抽出
    /// 保证 ZStack 里它与 TranscriptView 是两棵独立的子树,切 opacity 不牵连。
    @ViewBuilder
    private var editorLayer: some View {
        if isShowingManualNotesTimeline,
           let notebookId = route?.notebookID,
           let manualTab = activeNotebookTab {
            ManualNotesTimelineView(
                notebookId: notebookId,
                tabId: manualTab.tabId,
                documentId: manualTab.documentId,
                onOpenNote: { sessionId in
                    WindowCommandRouter.shared.requestOpenNotebookTab(
                        notebookID: notebookId,
                        tabID: manualTab.tabId,
                        documentID: manualTab.documentId,
                        selectedSessionID: sessionId
                    )
                }
            )
        } else {
            VStack(spacing: 0) {
            // 旧的格式工具栏随平文本编辑器一起拆除;大纲编辑器 v1 无格式化。
            // 任务面板入口保留为独立的工具条,只在笔记 tab 出现。
            if activeNotebookTab?.displayType == .manualNote {
                BlockNoteUtilityBar(
                    isTasksPanelActive: activeSidePanel == .tasks,
                    onShowTasks: {
                        if activeSidePanel == .tasks {
                            activeSidePanel = nil
                        } else {
                            activeSidePanel = .tasks
                            notebookTasks.refresh()
                        }
                    }
                )

                Divider()
                    .background(Color.borderGhost.opacity(0.4))
            }

            if docId != nil,
               let notebookId = route?.notebookID,
               let tabId = route?.tabID {
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        documentEditorContent(notebookId: notebookId, tabId: tabId)
                        NoteBottomSignature()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if activeSidePanel != nil {
                        Divider()
                            .background(Color.borderGhost.opacity(0.45))
                        NotebookTasksPanel(viewModel: notebookTasks)
                            .frame(width: 380)
                    }
                }
            } else {
                EmptyState(
                    illustration: { Arcanum003WaveformRuler() },
                    title: String(localized: "editor.empty.no_doc_title"),
                    description: String(localized: "editor.empty.no_doc_desc")
                )
            }
        }
        }
    }

    /// Exhaustive over `EditorSurface`. A new surface stops compiling here
    /// until it is given something to render, which is precisely what the old
    /// `if / else if` chain could not enforce — its fall-through returned
    /// `Color.clear` and shipped a blank page twice.
    @ViewBuilder
    private func documentEditorContent(notebookId: String, tabId: String) -> some View {
        switch surface {
        case .manualNote:
            // 大纲编辑器自管 open/close 与加载失败态(EmptyState + 重试)。
            BlockNoteEditorView(notebookId: notebookId, tabId: tabId)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .sessionNote(_, let sessionId):
            // A Session note is a separate block document. It never reuses the
            // Topic's shared Manual Note document or its outline rows.
            BlockNoteEditorView(sessionId: sessionId)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .sessionSettings(let notebookId, let sessionId):
            if let editorSession, editorSession.id == sessionId {
                SessionSettingsView(
                    notebookId: notebookId,
                    session: editorSession,
                    editor: captureProfileEditor,
                    captureSettingsScope: captureSettingsScope,
                    onOpenRealtimeControls: openRealtimeControls,
                    onOpenResource: { destination in
                        if destination == .manualNote {
                            showSessionNote()
                        } else {
                            openResource(sessionId: sessionId, destination: destination)
                        }
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if routeLoadError != nil {
                EmptyState(
                    icon: "exclamationmark.triangle",
                    title: String(localized: "editor.route.load_failed"),
                    description: String(localized: "session.settings.load_failed"),
                    action: (
                        label: String(localized: "session.settings.retry"),
                        handler: { Task { await loadNotebookRoute() } }
                    )
                )
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

        case .asyncNeedsSession:
            // The transcript layer is session-scoped, so the editor layer owns
            // this state rather than falling through to a blank surface.
            EmptyState(
                illustration: { Arcanum003WaveformRuler() },
                title: String(localized: "editor.transcript.async.no_session_title"),
                description: String(localized: "editor.transcript.async.no_session_desc"),
                action: (
                    label: String(localized: "resources.tab"),
                    handler: showResources
                )
            )

        case .tabsLoading:
            // Tabs resolve a frame or two after the route does. Previously this
            // also fell through to Color.clear — a blank page for as long as
            // the load took.
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .missingDocument:
            EmptyState(
                illustration: { Arcanum003WaveformRuler() },
                title: String(localized: "editor.empty.no_doc_title"),
                description: String(localized: "editor.empty.no_doc_desc")
            )

        // Drawn by their own layers in the ZStack; the editor layer is behind
        // them at opacity 0 and must not paint over them.
        case .realtime, .asyncTranscript, .captureSettings, .resources, .manualTimeline:
            Color.clear
        }
    }

    private var activeNotebookTabId: String? {
        route?.tabID
    }

    private var activeNotebookTab: NotebookTabViewModel? {
        guard let activeNotebookTabId else { return nil }
        return notebookTabs.first { $0.id == activeNotebookTabId }
    }

    /// Single source of truth for what the content area is showing. Every
    /// opacity, hit-testing and accessibility condition below derives from
    /// this rather than from the booleans it replaced.
    private var surface: EditorSurface {
        EditorSurfacePolicy.resolve(
            route: route,
            activeTab: activeNotebookTab,
            presentedCaptureSettingsNotebookId: presentedCaptureSettingsNotebookId,
            isShowingResources: isShowingResources,
            sessionSupplementarySurface: sessionSupplementarySurface
        )
    }

    /// The editor layer stays mounted for every surface so the cursor, scroll
    /// offset and IME state survive tab switches; this only decides whether it
    /// is the one the user can see and reach.
    private var editorLayerIsVisible: Bool {
        surface.showsTranscriptLayer == false && surface.showsNotebookOverlay == false
    }

    private var isShowingCaptureSettings: Bool {
        presentedCaptureSettingsNotebookId != nil
            && presentedCaptureSettingsNotebookId == captureSettingsNotebookId
    }

    private var captureSettingsNotebookId: String? {
        NotebookCaptureSettingsRoutePolicy.notebookId(for: route)
    }

    private var captureSettingsScope: NotebookCaptureSettingsScope {
        isQuickCaptureNotebook ? .quickCapture : .topic
    }

    private var effectiveSessionId: String? {
        selectedSessionId
    }

    private var chromeSession: SessionInfo? {
        // Topic Notes is one Topic-owned document. Session Notes, by contrast,
        // are intentionally session-owned and keep the recording breadcrumb.
        if sessionSupplementarySurface == nil,
           activeNotebookTab?.displayType == .manualNote {
            return nil
        }
        return editorSession
    }

    private var visibleSurfaceTitle: String? {
        switch sessionSupplementarySurface {
        case .note:
            return String(localized: "session.notes.title")
        case .settings:
            return String(localized: "session.settings.title")
        case nil:
            return activeNotebookTab?.title
        }
    }

    /// Topic workspaces own resources, shared notes and capture defaults.
    /// Supplying a Session id crosses into a single-transcript detail route.
    private var isTopicContext: Bool {
        selectedSessionId == nil && navigation.activePrimaryTab == .topics
    }

    private var selectedTranscriptionTask: TranscriptionTaskSnapshot? {
        guard let selectedSessionId else { return nil }
        return transcriptionTasksBySessionId[selectedSessionId]
    }

    private var pendingTranscriptionTaskId: String? {
        guard selectedTranscriptionTask?.tabStatus == .pending else { return nil }
        return selectedTranscriptionTask?.taskId
    }

    @State private var transcriptionTasksBySessionId: [String: TranscriptionTaskSnapshot] = [:]

    private var routeTaskId: String {
        [
            route?.notebookID,
            route?.tabID,
            route?.documentID,
            selectedSessionId,
            route?.opensTopicWorkspace == true ? "topic" : "content",
        ]
            .compactMap { $0 }
            .joined(separator: ":")
    }

    // MARK: - Loading

    @MainActor
    private func loadNotebookRoute() async {
        routeLoadGeneration &+= 1
        let generation = routeLoadGeneration
        guard let requestedRoute = route else {
            notebookTabs = []
            editorNotebook = nil
            editorSession = nil
            isQuickCaptureNotebook = false
            transcriptionTasksBySessionId = [:]
            routeLoadError = nil
            return
        }
        guard let core = CoreClient.shared.core else {
            notebookTabs = []
            editorNotebook = nil
            editorSession = nil
            isQuickCaptureNotebook = false
            transcriptionTasksBySessionId = [:]
            routeLoadError = String(localized: "editor.route.load_failed")
            return
        }

        let activeCapture = ActiveBilingualTranscriptStore.shared
        let activeCaptureNotebookId = activeCapture.notebookId
        let activeCaptureSessionId = activeCapture.sessionId
        let quickCaptureDisplayTitle = String(localized: "home.record.unfiled")
        let outcome = await Task.detached(priority: .userInitiated) {
            do {
                let loadedTranscriptionTasks = TranscriptionTaskIndex.makeIndex(
                    tasks: try core.listTasks(statusFilter: nil)
                )
                var loadedNotebook = try core.listNotebooks().first {
                    $0.id == requestedRoute.notebookID
                }
                let quickCaptureNotebook = try? core.getQuickCaptureNotebook()
                if let quickCaptureNotebook,
                   quickCaptureNotebook.id == requestedRoute.notebookID {
                    loadedNotebook = quickCaptureNotebook
                    loadedNotebook?.title = quickCaptureDisplayTitle
                } else if loadedNotebook == nil,
                          let sharedInboxNotebook = try? core.sharedInboxNotebook(),
                          sharedInboxNotebook.id == requestedRoute.notebookID {
                    loadedNotebook = sharedInboxNotebook
                }
                let loadedSession: SessionInfo?
                if let sessionId = requestedRoute.selectedSessionID {
                    // A selected Session is part of route identity. Failure
                    // must surface instead of silently showing the Topic name.
                    loadedSession = try core.getSession(id: sessionId)
                } else {
                    loadedSession = nil
                }
                let realtimeSessionId = requestedRoute.selectedSessionID
                    ?? (activeCaptureNotebookId == requestedRoute.notebookID
                        ? activeCaptureSessionId
                        : nil)
                let loadedTabs = try Self.loadNotebookTabModels(
                    notebookId: requestedRoute.notebookID,
                    realtimeSessionId: realtimeSessionId,
                    selectedSessionId: requestedRoute.selectedSessionID,
                    transcriptionTasksBySessionId: loadedTranscriptionTasks,
                    core: core
                )
                let presentedTabs = quickCaptureNotebook?.id == requestedRoute.notebookID
                    ? loadedTabs.filter { tab in
                        switch tab.displayType {
                        case .manualNote: false
                        case .realtimeTranscript, .asyncTranscript: true
                        }
                    }
                    : loadedTabs
                return NotebookRouteLoadOutcome.success(
                    NotebookRouteLoadSnapshot(
                        notebookTabs: presentedTabs,
                        notebook: loadedNotebook,
                        session: loadedSession,
                        transcriptionTasksBySessionId: loadedTranscriptionTasks,
                        isQuickCaptureNotebook: quickCaptureNotebook?.id
                            == requestedRoute.notebookID
                    )
                )
            } catch {
                return NotebookRouteLoadOutcome.failure(String(describing: error))
            }
        }.value

        guard routeLoadGeneration == generation, route == requestedRoute else { return }
        switch outcome {
        case .success(let snapshot):
            notebookTabs = snapshot.notebookTabs
            editorNotebook = snapshot.notebook
            editorSession = snapshot.session
            isQuickCaptureNotebook = snapshot.isQuickCaptureNotebook
            transcriptionTasksBySessionId = snapshot.transcriptionTasksBySessionId
            routeLoadError = nil
            let selectedTab = snapshot.notebookTabs.first { $0.id == requestedRoute.tabID }
            showTranscript = NotebookTranscriptPresentationPolicy.shouldShow(
                displayType: selectedTab?.displayType,
                status: selectedTab?.status,
                selectedSessionId: requestedRoute.selectedSessionID
            )
        case .failure(let detail):
            DebugLog.warn("load notebook route failed", detail: detail)
            isQuickCaptureNotebook = false
            routeLoadError = String(localized: "editor.route.load_failed")
        }
    }

    nonisolated private static func loadNotebookTabModels(
        notebookId: String,
        realtimeSessionId: String?,
        selectedSessionId: String?,
        transcriptionTasksBySessionId: [String: TranscriptionTaskSnapshot],
        core: any ZuTalkCoreProtocol
    ) throws -> [NotebookTabViewModel] {
        let backendTabs = try core.listNotebookTabs(notebookId: notebookId)
        var projectionsByTabId: [String: [FfiNotebookSessionProjection]] = [:]

        for tab in backendTabs {
            projectionsByTabId[tab.id] = try core.listNotebookSessionProjections(tabId: tab.id)
        }

        return NotebookTabViewModel.makeTabs(
            notebookId: notebookId,
            backendTabs: backendTabs,
            projectionsByTabId: projectionsByTabId,
            realtimeSessionId: realtimeSessionId,
            selectedSessionId: selectedSessionId,
            transcriptionTasksBySessionId: transcriptionTasksBySessionId
        )
    }

    private func selectNotebookTab(_ tab: NotebookTabViewModel) {
        let targetSessionId = tab.displayType == .manualNote
            ? nil
            : selectedSessionId
        let reusesCurrentRoute = NotebookCaptureSettingsRoutePolicy.reusesCurrentRoute(
            selectedTabId: tab.id,
            activeTabId: activeNotebookTabId
        )
        presentedCaptureSettingsNotebookId = nil
        isShowingResources = false
        sessionSupplementarySurface = nil
        if reusesCurrentRoute {
            if targetSessionId != selectedSessionId {
                WindowCommandRouter.shared.requestOpenNotebookTab(
                    notebookID: tab.notebookId,
                    tabID: tab.tabId,
                    documentID: tab.documentId,
                    selectedSessionID: targetSessionId
                )
                return
            }
            syncPresentedRoute()
            return
        }
        showTranscript = false
        WindowCommandRouter.shared.requestOpenNotebookTab(
            notebookID: tab.notebookId,
            tabID: tab.tabId,
            documentID: tab.documentId,
            selectedSessionID: targetSessionId
        )
    }

    private func showCaptureSettings() {
        guard effectiveSessionId == nil,
              let notebookId = captureSettingsNotebookId else { return }
        activeSidePanel = nil
        // 覆盖层出现前收回键盘焦点,行内 TextField 不得在被盖住时继续吃键击。
        NSApp.keyWindow?.makeFirstResponder(nil)
        isShowingResources = false
        sessionSupplementarySurface = nil
        presentedCaptureSettingsNotebookId = notebookId
    }

    /// The same control appears on both the Topic's pre-recording surface and
    /// a concrete Session's realtime surface, but those routes own different
    /// settings workspaces. Never cover a Session with the Topic overlay: its
    /// Settings tab also carries the immutable snapshot for that recording.
    private func openAdvancedSettingsForCurrentContext() {
        if effectiveSessionId != nil {
            showSessionSettings()
        } else {
            showCaptureSettings()
        }
    }

    private func showResources() {
        activeSidePanel = nil
        NSApp.keyWindow?.makeFirstResponder(nil)
        presentedCaptureSettingsNotebookId = nil
        sessionSupplementarySurface = nil
        showTranscript = false
        isShowingResources = true
    }

    private func showSessionNote() {
        guard effectiveSessionId != nil else { return }
        activeSidePanel = nil
        NSApp.keyWindow?.makeFirstResponder(nil)
        presentedCaptureSettingsNotebookId = nil
        isShowingResources = false
        showTranscript = false
        sessionSupplementarySurface = .note
    }

    private func showSessionSettings() {
        guard effectiveSessionId != nil else { return }
        activeSidePanel = nil
        NSApp.keyWindow?.makeFirstResponder(nil)
        presentedCaptureSettingsNotebookId = nil
        isShowingResources = false
        showTranscript = false
        sessionSupplementarySurface = .settings
    }

    private func openResource(
        sessionId: String,
        destination: NotebookResourceDestination
    ) {
        if destination == .audio {
            exportingSessionId = sessionId
            isShowingExportSheet = true
            return
        }
        isShowingResources = false
        guard let displayType = destination.displayType,
              let targetTab = notebookTabs.first(where: {
                  $0.displayType == displayType
              }) else {
            WindowCommandRouter.shared.requestOpenSession(sessionId)
            return
        }
        WindowCommandRouter.shared.requestOpenNotebookTab(
            notebookID: targetTab.notebookId,
            tabID: targetTab.tabId,
            documentID: targetTab.documentId,
            selectedSessionID: displayType == .manualNote ? nil : sessionId
        )
    }

    private func openRealtimeControls() {
        guard let realtimeTab = notebookTabs.first(where: {
            $0.displayType == .realtimeTranscript
        }) else { return }
        selectNotebookTab(realtimeTab)
    }

    private func navigateBack() {
        if isTopicContext {
            navigation.navigateTopics()
        } else if navigation.activePrimaryTab == .topics,
                  let notebookId = route?.notebookID {
            navigation.openTopicWorkspace(notebookID: notebookId)
        } else {
            WindowCommandRouter.shared.requestNavigateHome()
        }
    }

    private func syncPresentedRoute() {
        let selectedTab = activeNotebookTab
        showTranscript = NotebookTranscriptPresentationPolicy.shouldShow(
            displayType: selectedTab?.displayType,
            status: selectedTab?.status,
            selectedSessionId: selectedSessionId
        )
    }

}

private struct EditorRouteLoadWarning: View {
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: Spacing.md) {
            Label(
                String(localized: "editor.route.load_failed"),
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.bodySM)
            .foregroundColor(.signalAmber)
            Spacer(minLength: 0)
            Button(String(localized: "home.workspace.retry"), action: onRetry)
                .buttonStyle(.plain)
                .font(.bodyMedium)
                .frame(minHeight: 36)
        }
        .padding(.horizontal, Spacing.lg)
        .background(Color.bgElevated.opacity(0.24))
        .accessibilityIdentifier("editor.route.load_failure")
    }
}

// MARK: - NoteTopChrome (简化:只剩 back 按钮,document 切换移到下方 DocumentTabBar)

private struct NoteTopChrome: View {
    let notebookTitle: String?
    let session: SessionInfo?
    let isTopicWorkspace: Bool
    let backLabel: String
    let onBack: () -> Void

    var body: some View {
        HStack(spacing: Spacing.md) {
            Button(action: onBack) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                    Text(backLabel)
                        .font(.captionMedium)
                }
                .foregroundColor(.textSecondary)
            }
            .buttonStyle(.plain)
            .help(backLabel)

            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.textTertiary)
                .accessibilityHidden(true)

            if isTopicWorkspace {
                Label(
                    notebookTitle ?? String(localized: "topic.workspace.breadcrumb"),
                    systemImage: "list.bullet.rectangle"
                )
                .font(.bodyMedium)
                .foregroundColor(.textPrimary)
            } else if let session {
                HStack(spacing: Spacing.sm) {
                    if let notebookTitle, notebookTitle.isEmpty == false {
                        Text(notebookTitle)
                            .font(.bodyMedium)
                            .foregroundColor(.textSecondary)
                            .lineLimit(1)

                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.textTertiary)
                            .accessibilityHidden(true)
                    }

                    VStack(alignment: .leading, spacing: 1) {
                        Text(sessionDate(session))
                            .font(.bodyMedium)
                            .foregroundColor(.textPrimary)
                            .monospacedDigit()

                        if session.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                            Text(session.title)
                                .font(.caption)
                                .foregroundColor(.textSecondary)
                                .lineLimit(1)
                        }
                    }

                    SessionStatusPill(status: session.status, sessionType: session.sessionType)
                }
                .accessibilityElement(children: .combine)
            } else {
                Text(notebookTitle ?? String(localized: "topic.workspace.breadcrumb"))
                    .font(.bodyMedium)
                    .foregroundColor(.textPrimary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.sm)
        .frame(minHeight: 52)
    }

    private func sessionDate(_ session: SessionInfo) -> String {
        Date(timeIntervalSince1970: TimeInterval(session.createdAtUnixMs) / 1_000)
            .formatted(date: .abbreviated, time: .shortened)
    }
}

private struct SessionStatusPill: View {
    let status: String
    let sessionType: String

    var body: some View {
        Label(label, systemImage: icon)
            .font(.captionMedium)
            .foregroundColor(color)
            .padding(.horizontal, Spacing.sm)
            .frame(minHeight: 24)
            .background(color.opacity(0.1))
            .clipShape(Capsule())
    }

    private var normalizedStatus: String { status.lowercased() }

    private var label: String {
        switch normalizedStatus {
        case "recording": return String(localized: "home.status.recording")
        case "failed": return String(localized: "home.status.failed")
        case "interrupted": return String(localized: "home.status.interrupted")
        case "imported": return String(localized: "home.status.imported")
        default:
            return sessionType.lowercased() == "import"
                ? String(localized: "home.status.imported")
                : String(localized: "home.status.completed")
        }
    }

    private var icon: String {
        switch normalizedStatus {
        case "recording": return "record.circle.fill"
        case "failed": return "xmark.octagon.fill"
        case "interrupted": return "exclamationmark.triangle.fill"
        case "imported": return "square.and.arrow.down"
        default: return sessionType.lowercased() == "import"
            ? "square.and.arrow.down"
            : "checkmark.circle.fill"
        }
    }

    private var color: Color {
        switch normalizedStatus {
        case "recording": return .signalRed
        case "failed", "interrupted": return .signalAmber
        default: return .textSecondary
        }
    }
}

// MARK: - Notebook Tasks

@MainActor
private final class NotebookTasksViewModel: ObservableObject {
    @Published private(set) var tasks: [TaskInfoDto] = []
    @Published private(set) var lastError: String?

    private let client: any TaskStatusClienting

    init(client: (any TaskStatusClienting)? = nil) {
        self.client = client ?? LiveTaskStatusClient()
    }

    func refresh() {
        do {
            tasks = try client.listTasks(statusFilter: nil)
            lastError = nil
        } catch {
            tasks = []
            lastError = error.localizedDescription
        }
    }
}

private struct NotebookTasksPanel: View {
    @ObservedObject var viewModel: NotebookTasksViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(alignment: .top, spacing: Spacing.sm) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "editor.tasks.title"))
                        .font(.headline)
                        .foregroundColor(.textPrimary)
                    Text(String(format: String(localized: "editor.tasks.count_format"), Int64(viewModel.tasks.count)))
                        .font(.caption)
                        .foregroundColor(.textTertiary)
                }

                Spacer()

                Button {
                    viewModel.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help(String(localized: "editor.tasks.refresh"))
            }

            if let lastError = viewModel.lastError, !lastError.isEmpty {
                Text(lastError)
                    .font(.caption)
                    .foregroundColor(.signalRed)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if viewModel.tasks.isEmpty {
                VStack(alignment: .center, spacing: Spacing.sm) {
                    Image(systemName: "checklist")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundColor(.textTertiary)
                    Text(String(localized: "editor.tasks.empty"))
                        .font(.bodyMedium)
                        .foregroundColor(.textSecondary)
                    Text(String(localized: "editor.tasks.empty.detail"))
                        .font(.caption)
                        .foregroundColor(.textTertiary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Spacing.sm) {
                        ForEach(viewModel.tasks, id: \.id) { task in
                            NotebookTaskRow(task: task)
                        }
                    }
                }
            }
        }
        .padding(Spacing.lg)
        .frame(maxHeight: .infinity)
        .background(Color.bgRoot)
        .task {
            viewModel.refresh()
        }
    }
}

private struct NotebookTaskRow: View {
    let task: TaskInfoDto

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            Image(systemName: iconName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(tone)
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: Spacing.xs) {
                    Text(task.status.capitalized)
                        .font(.captionMedium)
                        .foregroundColor(.textPrimary)
                    Text(shortId)
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Text(detailLine)
                    .font(.caption)
                    .foregroundColor(.textTertiary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(Color.bgElevated.opacity(0.48))
        .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
    }

    private var normalizedStatus: String {
        task.status.lowercased()
    }

    private var shortId: String {
        String(task.id.prefix(8))
    }

    private var iconName: String {
        switch normalizedStatus {
        case "pending":
            return "clock"
        case "running", "leased":
            return "arrow.triangle.2.circlepath"
        case "failed", "error":
            return "xmark.octagon"
        case "done", "completed", "succeeded":
            return "checkmark.circle"
        default:
            return "circle"
        }
    }

    private var tone: Color {
        switch normalizedStatus {
        case "failed", "error":
            return .signalRed
        case "running", "leased":
            return .signalAmber
        case "done", "completed", "succeeded":
            return .signalGreen
        default:
            return .textTertiary
        }
    }

    private var detailLine: String {
        if let error = task.errorMsg?.trimmingCharacters(in: .whitespacesAndNewlines), !error.isEmpty {
            return error
        }
        return String(format: String(localized: "editor.tasks.retry_format"), Int64(task.retryCount))
    }
}

// MARK: - DocumentTabBar

/// Notebook-scoped tab bar. The three document-backed items come from
/// NotebookTabViewModel; capture settings is a fourth UI-only surface and never
/// receives a synthetic tab ID or Loro document ID.
private struct DocumentTabBar: View {
    let tabs: [NotebookTabViewModel]
    let activeTabId: String?
    let captureSettingsNotebookId: String?
    let isCaptureSettingsSelected: Bool
    let isResourcesSelected: Bool
    let isTopicContext: Bool
    let sessionId: String?
    let sessionSupplementarySurface: SessionSupplementarySurface?
    let onSelect: (NotebookTabViewModel) -> Void
    let onSelectResources: () -> Void
    let onSelectCaptureSettings: () -> Void
    let onSelectSessionNote: () -> Void
    let onSelectSessionSettings: () -> Void
    let onExport: () -> Void
    @ObservedObject private var captureStore = ActiveBilingualTranscriptStore.shared

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    if isTopicContext {
                        ResourcesTabButton(
                            isActive: isResourcesSelected,
                            action: onSelectResources
                        )
                    }

                    ForEach(visibleTabs) { tab in
                        NotebookTabButton(
                            tab: effectiveTab(tab),
                            isActive: isCaptureSettingsSelected == false
                                && isResourcesSelected == false
                                && sessionSupplementarySurface == nil
                                && tab.id == activeTabId,
                            action: { onSelect(tab) }
                        )
                    }

                    if isTopicContext == false, sessionId != nil {
                        SessionSupplementaryTabButton(
                            title: String(localized: "session.tab.notes"),
                            systemImage: "square.and.pencil",
                            accessibilityIdentifier: "session.tab.notes",
                            isActive: sessionSupplementarySurface == .note,
                            action: onSelectSessionNote
                        )
                        SessionSupplementaryTabButton(
                            title: String(localized: "session.tab.settings"),
                            systemImage: "slider.horizontal.3",
                            accessibilityIdentifier: "session.tab.settings",
                            isActive: sessionSupplementarySurface == .settings,
                            action: onSelectSessionSettings
                        )
                    }

                    // A Topic needs a settings entry before its first Session
                    // exists. Session routes use their own Settings tab above,
                    // which embeds this exact same settings implementation.
                    if isTopicContext, captureSettingsNotebookId != nil {
                        CaptureSettingsTabButton(
                            isActive: isCaptureSettingsSelected,
                            action: onSelectCaptureSettings
                        )
                    }
                }
            }

            Spacer(minLength: Spacing.md)

            if isTopicContext == false,
               isCaptureSettingsSelected == false,
               isResourcesSelected == false {
                Button(action: onExport) {
                    Image(systemName: "tray.and.arrow.up")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(sessionId == nil ? .textTertiary.opacity(0.5) : .textTertiary)
                        .padding(.horizontal, Spacing.sm)
                        .padding(.vertical, 5)
                }
                .buttonStyle(.plain)
                .disabled(sessionId == nil)
                .help(String(localized: sessionId == nil ? "editor.export.no_session" : "editor.export.hint"))
                .accessibilityLabel(String(localized: "editor.export.title"))
            }
        }
        .padding(.horizontal, Spacing.lg)
        .background(Color.bgSunken.opacity(0.4))
        .overlay(
            Rectangle()
                .fill(Color.borderGhost.opacity(0.3))
                .frame(height: 0.5),
            alignment: .bottom
        )
    }

    private var visibleTabs: [NotebookTabViewModel] {
        tabs.filter { tab in
            if isTopicContext {
                return tab.displayType != .asyncTranscript
            }
            return tab.displayType != .manualNote
        }
    }

    private func effectiveTab(_ tab: NotebookTabViewModel) -> NotebookTabViewModel {
        let resolvedStatus = NotebookRealtimeTabStatusPolicy.resolve(
            displayType: tab.displayType,
            baseStatus: tab.status,
            tabNotebookId: tab.notebookId,
            activeNotebookId: captureStore.notebookId,
            activeSessionId: captureStore.sessionId,
            captureIsActive: captureStore.captureState.isActive
        )
        let resolvedTitle = isTopicContext && tab.displayType == .realtimeTranscript
            ? String(localized: "topic.workspace.record")
            : tab.title
        guard resolvedStatus != tab.status || resolvedTitle != tab.title else { return tab }
        return NotebookTabViewModel(
            id: tab.id,
            notebookId: tab.notebookId,
            tabId: tab.tabId,
            displayType: tab.displayType,
            documentId: tab.documentId,
            sessionLink: tab.sessionLink,
            title: resolvedTitle,
            status: resolvedStatus,
            position: tab.position
        )
    }
}

private struct SessionSupplementaryTabButton: View {
    let title: String
    let systemImage: String
    let accessibilityIdentifier: String
    let isActive: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                Label(title, systemImage: systemImage)
                    .font(.bodyMedium)
                    .lineLimit(1)
                    .foregroundColor(isActive || isHovering ? .textPrimary : .textSecondary)
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, 8)

                Rectangle()
                    .fill(isActive ? Color.brandAccent : Color.clear)
                    .frame(height: 2)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(title)
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

private struct ResourcesTabButton: View {
    let isActive: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                Label(
                    String(localized: "topic.sessions.tab"),
                    systemImage: "list.bullet.rectangle"
                )
                .font(.bodyMedium)
                .lineLimit(1)
                .foregroundColor(isActive || isHovering ? .textPrimary : .textSecondary)
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, 8)

                Rectangle()
                    .fill(isActive ? Color.brandAccent : Color.clear)
                    .frame(height: 2)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(String(localized: "topic.sessions.tab.hint"))
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .accessibilityIdentifier("notebook.tab.resources")
    }
}

private struct CaptureSettingsTabButton: View {
    let isActive: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                Label(
                    String(localized: "topic.capture_setup.tab"),
                    systemImage: "slider.horizontal.3"
                )
                .font(.bodyMedium)
                .lineLimit(1)
                .foregroundColor(isActive || isHovering ? .textPrimary : .textSecondary)
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, 8)

                Rectangle()
                    .fill(isActive ? Color.brandAccent : Color.clear)
                    .frame(height: 2)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(String(localized: "topic.capture_setup.tab.hint"))
        .accessibilityLabel(Text(String(localized: "topic.capture_setup.tab")))
        .accessibilityHint(Text(String(localized: "capture.settings.tab_hint")))
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .accessibilityIdentifier("notebook.tab.capture_settings")
    }
}

private struct NotebookTabButton: View {
    let tab: NotebookTabViewModel
    let isActive: Bool
    let action: () -> Void

    @State private var isHovering = false
    @State private var spin: Bool = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                HStack(spacing: 4) {
                    leadingIndicator
                    Text(tab.title)
                        .font(.bodyMedium)
                        .lineLimit(1)
                }
                .foregroundColor(tintColor)
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, 8)

                Rectangle()
                    .fill(isActive ? Color.brandAccent : Color.clear)
                    .frame(height: 2)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isActive)
        .help(helpText)
        .accessibilityLabel(tab.title)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(helpText)
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .onAppear { spin = shouldAnimateIndicator }
        .montereyOnChange(of: tab.status) { _, newStatus in
            spin = Self.shouldAnimate(status: newStatus)
        }
    }

    private var shouldAnimateIndicator: Bool {
        Self.shouldAnimate(status: tab.status)
    }

    private static func shouldAnimate(status: NotebookTabStatus) -> Bool {
        switch status {
        case .pending, .live:
            return true
        case .ready, .failed:
            return false
        }
    }

    @ViewBuilder
    private var leadingIndicator: some View {
        switch tab.status {
        case .pending:
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 11, weight: .medium))
                .rotationEffect(.degrees(spin ? 360 : 0))
                .animation(.linear(duration: 1.1).repeatForever(autoreverses: false), value: spin)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .medium))
        case .live:
            Circle()
                .fill(Color.signalRed)
                .frame(width: 6, height: 6)
                .opacity(spin ? 1.0 : 0.35)
                .animation(
                    .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                    value: spin
                )
        default:
            Image(systemName: iconName)
                .font(.system(size: 11, weight: .medium))
        }
    }

    private var tintColor: Color {
        switch tab.status {
        case .failed:
            return .signalAmber
        case .pending:
            return isActive ? .textPrimary : .textSecondary
        default:
            return isActive ? .textPrimary : (isHovering ? .textSecondary : .textTertiary)
        }
    }

    private var iconName: String {
        switch tab.displayType {
        case .realtimeTranscript:
            return "waveform"
        case .asyncTranscript:
            return "waveform.badge.plus"
        case .manualNote:
            return "square.and.pencil"
        }
    }

    private var helpText: String {
        if tab.displayType == .realtimeTranscript {
            return tab.status == .live
                ? String(localized: "editor.tab.transcript.live.hint")
                : String(localized: "editor.tab.transcript.hint")
        }
        return tab.title
    }

    private var accessibilityValue: String {
        let key: String
        switch tab.status {
        case .ready: key = "resources.status.ready"
        case .pending: key = "resources.status.pending"
        case .failed: key = "resources.status.failed"
        case .live: key = "home.status.recording"
        }
        return String(localized: String.LocalizationValue(key))
    }
}

// MARK: - Async transcript

/// Session-filtered projection of the builtin Async Transcript document.
/// Rust owns the durable Loro document; this view only derives stable rows.
private struct AsyncTranscriptView: View {
    let notebookId: String
    let sessionId: String
    let tabId: String
    let displayType: NotebookTabDisplayType
    let status: NotebookTabStatus
    let taskErrorMessage: String?

    @ObservedObject private var projectionStore = NotebookTranscriptProjectionStore.shared
    // Observed for statusRevision so the key-required gate below reacts when
    // the user saves or removes their own key in Settings.
    @ObservedObject private var providerCredentials = ProviderCredentialSession.shared
    @StateObject private var projectionAttachment =
        NotebookTranscriptProjectionAttachmentCoordinator(
            store: NotebookTranscriptProjectionStore.shared
        )
    @State private var isRepairingStoredProjection = false
    @State private var storedProjectionRepairFailed = false

    private var lines: [NotebookTranscriptLine] {
        projectionStore.linesBySession[sessionId] ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            asyncStatusBar
            if AsyncTranscriptMetadataNoticePolicy.shouldShow(for: lines) {
                AsyncTranscriptMetadataNotice()
            }
            Divider().background(Color.borderGhost.opacity(0.25))
            Group {
                switch contentPhase {
                case .loading:
                    AsyncTranscriptLoadingView(statusText: asyncStatusText)
                case .empty:
                    EmptyState(
                        illustration: { Arcanum003WaveformRuler() },
                        title: emptyStateTitle,
                        description: emptyStateDescription
                    )
                case .transcript:
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(lines) { line in
                                AsyncTranscriptRow(
                                    line: line,
                                    isEditable: isTranscriptEditable,
                                    onReplace: { text in
                                        try projectionStore.replaceSegment(
                                            sessionId: sessionId,
                                            segmentId: line.id,
                                            text: text
                                        )
                                    },
                                    onEditingChanged: { target, focused in
                                        projectionAttachment.setEditPending(
                                            segmentId: target.utteranceId,
                                            pending: focused
                                        )
                                    }
                                )
                                .id(line.id)
                                Divider().background(Color.borderGhost.opacity(0.22))
                            }
                        }
                        .padding(.horizontal, NotebookRealtimeTranscriptLayout.horizontalInset)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.bgRoot)
        .task(id: "\(sessionId):\(tabId)") {
            await repairStoredProjection(showFailureToast: false)
            attachProjection()
        }
        .onDisappear {
            projectionAttachment.requestDetach()
        }
    }

    private var asyncProjectionState: NotebookAsyncProjectionState? {
        projectionStore.asyncProjectionStateBySession[sessionId]
    }

    private var asyncProviderState: String? {
        projectionStore.asyncProviderStateBySession[sessionId]
    }

    private var isRetryingProjection: Bool {
        projectionStore.retryingAsyncProjectionSessions.contains(sessionId)
    }

    private var isTranscriptEditable: Bool {
        projectionStore.editableBySession[sessionId] == true
    }

    private var contentPhase: AsyncTranscriptContentPhase {
        AsyncTranscriptContentPolicy.phase(
            hasLines: lines.isEmpty == false,
            projectionState: asyncProjectionState,
            providerState: asyncProviderState,
            tabStatus: status,
            hasOperationInFlight: isRetryingProjection
                || isRepairingStoredProjection
                || isRequestingAsyncTranscription,
            hasLoadFailure: hasProjectionLoadFailure
        )
    }

    private var hasProjectionLoadFailure: Bool {
        projectionAttachment.attachmentFailed
            || documentReadError != nil
            || (asyncProjectionState == nil
                && projectionStore.asyncProjectionErrorBySession[sessionId] != nil)
    }

    private var documentReadError: String? {
        projectionStore.documentReadErrorBySession[sessionId]
    }

    private var asyncStatusBar: some View {
        HStack(spacing: Spacing.sm) {
            if isRetryingProjection
                || isRepairingStoredProjection
                || (hasProjectionLoadFailure == false
                    && (asyncProjectionState == .projecting || isProviderPending)) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: asyncStatusIcon)
                    .foregroundColor(asyncStatusColor)
                    .accessibilityHidden(true)
            }
            Text(asyncStatusText)
                .font(.captionMedium)
                .foregroundColor(.textSecondary)
            Spacer(minLength: Spacing.md)
            if lines.isEmpty == false, isTranscriptEditable == false {
                Label(
                    String(localized: "capture.transcript.read_only"),
                    systemImage: "lock.fill"
                )
                .font(.caption)
                .foregroundColor(.textSecondary)
            }
            switch primaryAction {
            case .addPersonalKey:
                // Post-stop upload requires a saved personal key. Keep the
                // setup action visible for an already queued task too: the
                // worker will continue once that key becomes available.
                Button {
                    MainNavigationStore.shared.openSettings()
                } label: {
                    Label(
                        String(localized: "editor.transcript.async.invite_add_key"),
                        systemImage: "key"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .frame(minHeight: 44)
                .help(String(localized: "community_invite.async.needs_personal_key"))
                .accessibilityHint(Text(String(
                    localized: "community_invite.async.needs_personal_key"
                )))
                .accessibilityIdentifier("async.transcription.add-key.\(sessionId)")
            case .start:
                Button {
                    requestAsyncTranscription()
                } label: {
                    Label(
                        String(localized: "editor.transcript.async.start"),
                        systemImage: "waveform.badge.plus"
                    )
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .frame(minHeight: 44)
                .disabled(isRequestingAsyncTranscription)
                .accessibilityIdentifier("async.transcription.start.\(sessionId)")
            case .none:
                EmptyView()
            }
            if asyncProjectionState == .failed
                || storedProjectionRepairFailed
                || hasProjectionLoadFailure {
                Button {
                    retryProjection()
                } label: {
                    Label(
                        retryActionLabel,
                        systemImage: "arrow.clockwise"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .frame(minHeight: 44)
                .disabled(isRetryingProjection || isRepairingStoredProjection)
                .help(retryActionHint)
                .accessibilityHint(Text(retryActionHint))
                .accessibilityIdentifier("async.transcription.retry-projection.\(sessionId)")
            }
        }
        .padding(.horizontal, Spacing.xl + Spacing.lg)
        .frame(minHeight: 52)
        .background(Color.bgSunken.opacity(0.2))
        .accessibilityElement(children: .contain)
    }

    private var isRequestingAsyncTranscription: Bool {
        projectionStore.requestingAsyncTranscriptionSessions.contains(sessionId)
    }

    private var hasReadyPersonalSonioxKey: Bool {
        providerCredentials.snapshot().contains {
            $0.account == .soniox && $0.isSaved && $0.isActive
        }
    }

    private var primaryAction: AsyncTranscriptPrimaryAction {
        guard hasProjectionLoadFailure == false else { return .none }
        return AsyncTranscriptActionPolicy.primaryAction(
            projectionState: asyncProjectionState,
            providerState: asyncProviderState,
            hasReadyPersonalKey: hasReadyPersonalSonioxKey
        )
    }

    private func requestAsyncTranscription() {
        Task { @MainActor in
            do {
                try await projectionStore.requestAsyncTranscription(
                    sessionId: sessionId
                )
            } catch {
                ToastCenter.shared.error(
                    String(localized: "editor.transcript.async.start_failed"),
                    detail: error.localizedDescription
                )
            }
        }
    }

    private var asyncStatusText: String {
        if isRetryingProjection || isRepairingStoredProjection {
            return String(localized: "editor.transcript.async.status.projecting")
        }
        if documentReadError != nil {
            return String(localized: "editor.route.load_failed")
        }
        if storedProjectionRepairFailed || hasProjectionLoadFailure {
            return String(localized: "editor.transcript.async.status.projection_failed")
        }
        if lines.isEmpty == false {
            return String(localized: "editor.transcript.async.status.ready")
        }
        switch asyncProjectionState {
        case .some(.pending):
            return String(localized: "editor.transcript.async.status.projection_pending")
        case .some(.projecting):
            return String(localized: "editor.transcript.async.status.projecting")
        case .some(.ready):
            return String(localized: "editor.transcript.async.status.ready")
        case .some(.failed):
            return String(localized: "editor.transcript.async.status.projection_failed")
        case .some(.none):
            switch asyncProviderState {
            case "pending", "reserved", "enqueued":
                return String(localized: "editor.transcript.async.status.provider_pending")
            case "failed":
                return String(localized: "editor.transcript.async.status.provider_failed")
            default:
                return String(localized: "editor.transcript.async.status.off")
            }
        case nil:
            return String(localized: "editor.transcript.async.status.loading")
        }
    }

    private var asyncStatusIcon: String {
        if storedProjectionRepairFailed || hasProjectionLoadFailure {
            return "exclamationmark.triangle.fill"
        }
        if lines.isEmpty == false { return "checkmark.circle.fill" }
        switch asyncProjectionState {
        case .some(.ready): return "checkmark.circle.fill"
        case .some(.failed): return "exclamationmark.triangle.fill"
        case .some(.pending): return "clock.fill"
        case .some(.projecting): return "arrow.triangle.2.circlepath"
        case .some(.none):
            return asyncProviderState == "failed" ? "exclamationmark.circle.fill" : "icloud.slash"
        case nil: return "clock"
        }
    }

    private var asyncStatusColor: Color {
        if storedProjectionRepairFailed || hasProjectionLoadFailure { return .signalAmber }
        if lines.isEmpty == false { return .signalGreen }
        switch asyncProjectionState {
        case .some(.ready): return .signalGreen
        case .some(.failed): return .signalAmber
        default: return .textTertiary
        }
    }

    private func retryProjection() {
        if documentReadError != nil {
            do {
                try projectionStore.retryDocumentRead(sessionId: sessionId)
            } catch {
                ToastCenter.shared.error(
                    String(localized: "editor.route.load_failed"),
                    detail: error.localizedDescription
                )
            }
            return
        }
        if storedProjectionRepairFailed {
            Task { @MainActor in
                await repairStoredProjection(showFailureToast: true)
            }
            return
        }
        if hasProjectionLoadFailure {
            attachProjection()
            if hasProjectionLoadFailure {
                if let documentReadError {
                    ToastCenter.shared.error(
                        String(localized: "editor.route.load_failed"),
                        detail: documentReadError
                    )
                } else {
                    ToastCenter.shared.error(
                        String(localized: "editor.transcript.async.retry_failed")
                    )
                }
            }
            return
        }
        retryLocalProjection()
    }

    private func attachProjection() {
        projectionAttachment.attach(
            sessionId: sessionId,
            notebookId: notebookId,
            tabId: tabId
        )
    }

    private func retryLocalProjection() {
        Task { @MainActor in
            do {
                try projectionStore.retryAsyncProjection(sessionId: sessionId)
            } catch {
                ToastCenter.shared.error(
                    String(localized: "editor.transcript.async.retry_failed"),
                    detail: error.localizedDescription
                )
            }
        }
    }

    /// Legacy/imported Sessions can have durable async tokens but no capture
    /// run state machine. Repair their missing marked section lazily when this
    /// exact Session is opened, avoiding an O(n²) scan of a large Topic.
    private func repairStoredProjection(showFailureToast: Bool) async {
        guard isRepairingStoredProjection == false,
              let core = CoreClient.shared.core else { return }
        isRepairingStoredProjection = true
        let targetSessionId = sessionId
        let succeeded = await Task.detached(priority: .userInitiated) {
            do {
                _ = try core.repairSessionTranscriptProjection(sessionId: targetSessionId)
                return true
            } catch {
                return false
            }
        }.value
        isRepairingStoredProjection = false
        storedProjectionRepairFailed = !succeeded
        if !succeeded, showFailureToast {
            ToastCenter.shared.error(
                String(localized: "editor.transcript.async.retry_failed")
            )
        }
    }

    private var emptyStateTitle: String {
        if documentReadError != nil {
            return String(localized: "editor.route.load_failed")
        }
        if storedProjectionRepairFailed || hasProjectionLoadFailure {
            return String(localized: "editor.transcript.async.projection_failed_title")
        }
        switch asyncProjectionState {
        case .some(.pending), .some(.projecting):
            return String(localized: "editor.transcript.async.pending_title")
        case .some(.failed):
            return String(localized: "editor.transcript.async.projection_failed_title")
        case .some(.none) where status == .pending || isProviderPending:
            return String(localized: "editor.transcript.async.pending_title")
        case .some(.none) where status == .failed || asyncProviderState == "failed":
            return String(localized: "editor.transcript.async.failed_title")
        default:
            return String(localized: "editor.transcript.async.empty_title")
        }
    }

    private var emptyStateDescription: String {
        if let documentReadError { return documentReadError }
        if storedProjectionRepairFailed || hasProjectionLoadFailure {
            return String(localized: "editor.transcript.async.projection_failed_desc")
        }
        switch asyncProjectionState {
        case .some(.pending), .some(.projecting):
            return String(localized: "editor.transcript.async.projection_pending_desc")
        case .some(.failed):
            return String(localized: "editor.transcript.async.projection_failed_desc")
        case .some(.none) where status == .pending || isProviderPending:
            return String(localized: "editor.transcript.async.pending_desc")
        case .some(.none) where status == .failed || asyncProviderState == "failed":
            return providerFailureDescription
        default:
            return String(localized: "editor.transcript.async.empty_desc")
        }
    }

    private var isProviderPending: Bool {
        AsyncTranscriptActionPolicy.isProviderPending(asyncProviderState)
    }

    private var retryActionLabel: String {
        documentReadError == nil
            ? String(localized: "editor.transcript.async.retry_projection")
            : String(localized: "capture.settings.autosave.retry")
    }

    private var retryActionHint: String {
        documentReadError
            ?? String(localized: "editor.transcript.async.retry_projection_hint")
    }

    private var providerFailureDescription: String {
        let summary = String(localized: "editor.transcript.async.failed_desc")
        guard let detail = taskErrorMessage?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), detail.isEmpty == false else { return summary }
        return "\(summary)\n\n\(detail)"
    }
}

private struct AsyncTranscriptMetadataNotice: View {
    var body: some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Image(systemName: "info.circle")
                .accessibilityHidden(true)
            Text(String(localized: "editor.transcript.async.metadata_missing_notice"))
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundColor(.textSecondary)
        .padding(.horizontal, NotebookRealtimeTranscriptLayout.horizontalInset)
        .padding(.vertical, Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.bgSunken.opacity(0.12))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("async.transcript.metadata-missing")
    }
}

/// One after-stop transcript row. New projections preserve the async
/// provider's anonymous speaker, language, and timing metadata; legacy rows
/// remain valid and simply omit metadata they never recorded.
private struct AsyncTranscriptRow: View {
    let line: NotebookTranscriptLine
    let isEditable: Bool
    let onReplace: (String) async throws -> Void
    let onEditingChanged: (BilingualLaneEditTarget, Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            if hasMetadataHeader {
                HStack(spacing: Spacing.sm) {
                    if let speakerDisplayName {
                        Label(speakerDisplayName, systemImage: "person.crop.circle")
                            .font(.captionMedium)
                            .foregroundColor(.textPrimary)
                            .padding(.horizontal, Spacing.sm)
                            .frame(minHeight: 28)
                            .background(Color.bgElevated.opacity(0.48))
                            .clipShape(Capsule())
                            .overlay(
                                Capsule().strokeBorder(
                                    Color.borderGhost.opacity(0.35),
                                    lineWidth: 0.5
                                )
                            )
                    }

                    if let timestampText {
                        Label(timestampText, systemImage: "waveform")
                            .accessibilityLabel(Text(String(
                                format: String(localized: "capture.transcript.source_timestamp"),
                                timestampText
                            )))
                    }

                    if let sourceLanguageLabel {
                        Text(sourceLanguageLabel)
                    }
                }
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(.textTertiary)
            }

            BilingualLaneText(
                target: editTarget,
                text: line.text,
                isEditable: isEditable,
                editAccessibilityLabel: String(localized: "editor.tab.transcript.hint"),
                commitFailureMessage: String(localized: "editor.transcript.edit_failed"),
                onCommit: { _, text in
                    try await onReplace(text)
                },
                onEditingChanged: onEditingChanged
            )
            .id(editTarget)
            .accessibilityIdentifier("async.transcript.segment.\(line.id)")
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.lg)
        .frame(maxWidth: .infinity, minHeight: 80, alignment: .topLeading)
        .accessibilityElement(children: .contain)
    }

    private var editTarget: BilingualLaneEditTarget {
        BilingualLaneEditTarget(
            utteranceId: line.id,
            laneLanguage: normalizedSourceLanguage ?? "und"
        )
    }

    private var hasMetadataHeader: Bool {
        speakerDisplayName != nil || timestampText != nil || sourceLanguageLabel != nil
    }

    private var speakerDisplayName: String? {
        guard let label = line.providerSpeakerLabel?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            label.isEmpty == false
        else { return nil }
        return String(
            format: String(localized: "editor.transcript.async.speaker_format"),
            label
        )
    }

    private var normalizedSourceLanguage: String? {
        guard let language = line.sourceLanguage?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(separator: "-")
            .first
            .map(String.init),
            language.isEmpty == false,
            language != "und"
        else { return nil }
        return language
    }

    private var sourceLanguageLabel: String? {
        normalizedSourceLanguage?.uppercased()
    }

    private var timestampText: String? {
        guard let milliseconds = line.startMs else { return nil }
        return TranscriptTimestampPresentation.text(milliseconds: milliseconds)
    }
}

private struct AsyncTranscriptLoadingView: View {
    let statusText: String

    var body: some View {
        VStack(spacing: Spacing.md) {
            ProgressView()
                .controlSize(.small)
                .accessibilityHidden(true)
            Text(statusText)
                .font(.caption)
                .foregroundColor(.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(statusText))
    }
}

// MARK: - Builtin tab title

private struct NotebookSettingsNotebookHeader: View {
    let title: String?

    var body: some View {
        Text(title?.isEmpty == false ? title! : String(localized: "home.notebook.new"))
            .font(.system(size: 22, weight: .semibold))
            .foregroundColor(.textPrimary)
            .lineLimit(1)
            .padding(.horizontal, Spacing.lg)
            .padding(.top, Spacing.sm)
            .padding(.bottom, Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct NotebookBuiltinTabTitle: View {
    let title: String?

    var body: some View {
        Text(title ?? String(localized: "editor.title.untitled"))
            .font(.system(size: 22, weight: .semibold))
            .foregroundColor(.textPrimary)
            .padding(.horizontal, Spacing.lg)
            .padding(.top, Spacing.sm)
            .padding(.bottom, Spacing.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct TopicNotesContextHeader: View {
    var body: some View {
        HStack(spacing: Spacing.sm) {
                Image(systemName: "folder.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.textSecondary)
            Text(String(localized: "topic.notes.shared_document"))
                .font(.caption)
                .foregroundColor(.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.sm)
        .background(Color.bgSunken.opacity(0.18))
    }
}

private struct SessionNotesContextHeader: View {
    var body: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "doc.text")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.brandAccent)
            Text(String(localized: "session.notes.context"))
                .font(.caption)
                .foregroundColor(.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.sm)
        .background(Color.bgSunken.opacity(0.18))
        .accessibilityIdentifier("session.notes.context")
    }
}

/// Session Settings is the complete recording-settings workspace, not merely
/// a metadata card. Resource state belongs at the top, editable defaults stay
/// in the middle, and the immutable run snapshot closes the same page. Keeping
/// the three areas in one reading flow avoids making provenance look like an
/// alternative mode of the settings workspace.
private struct SessionSettingsView: View {
    let notebookId: String
    let session: SessionInfo
    @ObservedObject var editor: NotebookCaptureProfileEditorModel
    let captureSettingsScope: NotebookCaptureSettingsScope
    let onOpenRealtimeControls: () -> Void
    let onOpenResource: (NotebookResourceDestination) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                sessionResourceSection

                NotebookCaptureSettingsView(
                    notebookId: notebookId,
                    editor: editor,
                    scope: captureSettingsScope,
                    embeddedInParentScrollView: true,
                    onOpenRealtimeControls: onOpenRealtimeControls
                )
                .id("session-recording-settings:\(notebookId)")
                .frame(maxWidth: .infinity, alignment: .top)

                Divider()
                    .padding(.horizontal, Spacing.xl)
                    .background(Color.borderGhost.opacity(0.45))

                Text(String(localized: "session.settings.workspace.snapshot"))
                    .font(.headline)
                    .foregroundColor(.textPrimary)
                    .padding(.horizontal, Spacing.xl)
                    .padding(.top, Spacing.xl)
                    .frame(maxWidth: .infinity, alignment: .leading)

                SessionSettingsSnapshotView(
                    notebookId: notebookId,
                    session: session,
                    isEmbedded: true
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.bgRoot)
        .accessibilityIdentifier("session.settings.\(session.id)")
    }

    @ViewBuilder
    private var sessionResourceSection: some View {
        SessionResourceSettingsView(
            sessionId: session.id,
            sessionTitle: session.title,
            onOpen: onOpenResource
        )
    }
}

private struct SessionSettingsSnapshotView: View {
    let notebookId: String
    let session: SessionInfo
    var isEmbedded = false

    @State private var captureRun: FfiNotebookCaptureHistoryRun?
    @State private var isLoading = true
    @State private var loadError: String?

    var body: some View {
        Group {
            if isEmbedded {
                snapshotContent
            } else {
                ScrollView {
                    snapshotContent
                }
            }
        }
        .background(Color.bgRoot)
        .task(id: "\(notebookId):\(session.id)") { await load() }
        .accessibilityIdentifier("session.settings.snapshot.\(session.id)")
    }

    private var snapshotContent: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(String(localized: "session.settings.subtitle"))
                    .font(.bodySM)
                    .foregroundColor(.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            settingsSection(
                title: String(localized: "session.settings.section.session"),
                rows: sessionRows
            )

            if isLoading {
                HStack(spacing: Spacing.sm) {
                    ProgressView()
                        .controlSize(.small)
                    Text(String(localized: "editor.transcript.async.status.loading"))
                        .font(.bodySM)
                        .foregroundColor(.textSecondary)
                }
                .frame(maxWidth: .infinity, minHeight: 80)
            } else if let loadError {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Label(
                        String(localized: "session.settings.load_failed"),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.bodyMedium)
                    .foregroundColor(.signalAmber)
                    Text(loadError)
                        .font(.caption)
                        .foregroundColor(.textSecondary)
                        .textSelection(.enabled)
                    Button(String(localized: "session.settings.retry")) {
                        Task { await load() }
                    }
                    .buttonStyle(.bordered)
                }
                .padding(Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.bgElevated.opacity(0.32))
                .clipShape(RoundedRectangle(cornerRadius: Radius.md))
            } else {
                if captureRun == nil {
                    snapshotNotice(
                        key: session.sessionType.lowercased() == "import"
                            ? "session.settings.snapshot.imported_missing"
                            : "session.settings.snapshot.missing",
                        systemImage: "questionmark.circle",
                        color: .textSecondary
                    )
                } else if captureRun?.providerErrorType == "profile_snapshot_corrupt" {
                    snapshotNotice(
                        key: "session.settings.snapshot.corrupt",
                        systemImage: "exclamationmark.triangle.fill",
                        color: .signalAmber
                    )
                }

                settingsSection(
                    title: String(localized: "session.settings.section.capture"),
                    rows: captureRows
                )
            }

            HStack(spacing: Spacing.sm) {
                Image(systemName: "number")
                    .foregroundColor(.textTertiary)
                Text(session.id)
                    .font(.caption.monospaced())
                    .foregroundColor(.textTertiary)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
            }
            .padding(.top, Spacing.sm)
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.lg)
        .frame(maxWidth: 860, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var sessionRows: [SessionSettingsRowModel] {
        [
            SessionSettingsRowModel(
                icon: "calendar",
                label: String(localized: "session.settings.field.created"),
                value: createdAtText
            ),
            SessionSettingsRowModel(
                icon: "clock",
                label: String(localized: "session.settings.field.duration"),
                value: durationText(session.durationMs)
            ),
            SessionSettingsRowModel(
                icon: session.sessionType == "import" ? "square.and.arrow.down" : "mic",
                label: String(localized: "session.settings.field.type"),
                value: String(localized: session.sessionType == "import"
                    ? "home.row.kind.import"
                    : "home.row.kind.recording")
            ),
            SessionSettingsRowModel(
                icon: "circle.dotted",
                label: String(localized: "session.settings.field.status"),
                value: statusText
            ),
            SessionSettingsRowModel(
                icon: "character.bubble",
                label: String(localized: "session.settings.field.languages"),
                value: languageText
            ),
            SessionSettingsRowModel(
                icon: "waveform",
                label: String(localized: "session.settings.field.audio"),
                value: String(localized: session.hasEncryptedAudio
                    ? "session.settings.value.available"
                    : "session.settings.value.unavailable")
            ),
        ]
    }

    private var captureRows: [SessionSettingsRowModel] {
        guard let captureRun else {
            return [
                SessionSettingsRowModel(
                    icon: "archivebox",
                    label: String(localized: "session.settings.section.capture"),
                    value: String(localized: "session.settings.value.unknown")
                ),
            ]
        }
        var rows = [
            SessionSettingsRowModel(
                icon: "rectangle.split.2x1",
                label: String(localized: "session.settings.field.mode"),
                value: modeText(captureRun.mode)
            ),
            SessionSettingsRowModel(
                icon: "lock.shield",
                label: String(localized: "session.settings.field.privacy"),
                value: privacyText(captureRun.privacyLevel)
            ),
            SessionSettingsRowModel(
                icon: "network",
                label: String(localized: "session.settings.field.remote_realtime"),
                value: booleanSnapshotText(captureRun.remoteRealtimeEnabled)
            ),
            SessionSettingsRowModel(
                icon: "books.vertical",
                label: String(localized: "session.settings.field.context_sharing"),
                value: booleanSnapshotText(captureRun.sendContextToSoniox)
            ),
            SessionSettingsRowModel(
                icon: "bolt.horizontal.circle",
                label: String(localized: "session.settings.field.realtime_engine"),
                value: engineText(
                    provider: captureRun.realtimeProviderId,
                    model: captureRun.realtimeModelId
                )
            ),
            SessionSettingsRowModel(
                icon: "waveform.badge.plus",
                label: String(localized: "session.settings.field.processed_engine"),
                value: engineText(
                    provider: captureRun.postStopProviderId,
                    model: captureRun.postStopModelId
                )
            ),
            SessionSettingsRowModel(
                icon: "slider.horizontal.3",
                label: String(localized: "session.settings.field.format"),
                value: audioFormatText(captureRun)
            ),
            SessionSettingsRowModel(
                icon: "mic",
                label: String(localized: "session.settings.field.audio_input"),
                value: String(localized: "session.settings.value.not_recorded")
            ),
        ]
        if captureRun.sendContextToSoniox == true {
            rows.append(
                SessionSettingsRowModel(
                    icon: "doc.text.magnifyingglass",
                    label: String(localized: "session.settings.field.context_source"),
                    value: String(localized: "session.settings.value.not_recorded")
                )
            )
        }
        return rows
    }

    private func settingsSection(
        title: String,
        rows: [SessionSettingsRowModel]
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.headline)
                .foregroundColor(.textPrimary)
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)

            Divider()
                .background(Color.borderGhost.opacity(0.45))

            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                SessionSettingsRow(row: row)
                if index < rows.count - 1 {
                    Divider()
                        .padding(.leading, 48)
                        .background(Color.borderGhost.opacity(0.35))
                }
            }
        }
        .background(Color.bgElevated.opacity(0.3))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md)
                .strokeBorder(Color.borderGhost.opacity(0.55), lineWidth: Stroke.thin)
        )
        .clipShape(RoundedRectangle(cornerRadius: Radius.md))
    }

    private func snapshotNotice(
        key: String.LocalizationValue,
        systemImage: String,
        color: Color
    ) -> some View {
        Label(String(localized: key), systemImage: systemImage)
            .font(.bodySM)
            .foregroundColor(color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.bgElevated.opacity(0.28))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.md)
                    .strokeBorder(color.opacity(0.3), lineWidth: Stroke.thin)
            )
            .clipShape(RoundedRectangle(cornerRadius: Radius.md))
    }

    @MainActor
    private func load() async {
        isLoading = true
        loadError = nil
        guard let core = CoreClient.shared.core else {
            isLoading = false
            loadError = CoreClient.shared.initError ?? String(localized: "session.settings.load_failed")
            return
        }
        do {
            let requestedNotebookId = notebookId
            let requestedSessionId = session.id
            let runs = try await Task.detached(priority: .userInitiated) {
                try core.listNotebookCaptureHistorySummaries(notebookId: requestedNotebookId)
            }.value
            captureRun = runs.first { $0.sessionId == requestedSessionId }
            isLoading = false
        } catch {
            captureRun = nil
            isLoading = false
            loadError = error.localizedDescription
        }
    }

    private var createdAtText: String {
        Date(timeIntervalSince1970: TimeInterval(session.createdAtUnixMs) / 1_000)
            .formatted(date: .long, time: .shortened)
    }

    private var languageText: String {
        let codes = ([session.sourceLanguage] + session.targetLanguages)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
            .filter { $0.isEmpty == false }
        return codes.isEmpty
            ? String(localized: "session.settings.value.unknown")
            : codes.joined(separator: " · ")
    }

    private var statusText: String {
        let key: String
        switch session.status.lowercased() {
        case "completed": key = "home.status.completed"
        case "failed": key = "home.status.failed"
        case "imported": key = "home.status.imported"
        case "interrupted": key = "home.status.interrupted"
        case "recording": key = "home.status.recording"
        case "transcribing": key = "home.status.transcribing"
        default: return session.status.isEmpty
            ? String(localized: "session.settings.value.unknown")
            : session.status
        }
        return String(localized: String.LocalizationValue(key))
    }

    private func durationText(_ ms: UInt64) -> String {
        let total = Int(ms / 1_000)
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, seconds) }
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func modeText(_ mode: FfiNotebookCaptureMode?) -> String {
        let key: String
        switch mode {
        case .transcriptionOnly: key = "session.settings.mode.transcription_only"
        case .twoWay: key = "session.settings.mode.two_way"
        case .multilingualOneWay: key = "session.settings.mode.multilingual_one_way"
        case nil: return String(localized: "session.settings.value.unknown")
        }
        return String(localized: String.LocalizationValue(key))
    }

    private func privacyText(_ rawValue: String?) -> String {
        guard let rawValue,
              let level = NotebookAudioRetentionLevel(rawValue: rawValue) else {
            return String(localized: "session.settings.value.unknown")
        }
        return AudioPrivacyOptionSummary(level: level).title
    }

    private func booleanSnapshotText(_ value: Bool?) -> String {
        guard let value else {
            return String(localized: "session.settings.value.unknown")
        }
        return String(localized: value
            ? "session.settings.value.enabled"
            : "session.settings.value.disabled")
    }

    private func engineText(provider: String?, model: String?) -> String {
        let values = [provider, model]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
        return values.isEmpty
            ? String(localized: "session.settings.value.unknown")
            : values.joined(separator: " · ")
    }

    private func audioFormatText(_ run: FfiNotebookCaptureHistoryRun) -> String {
        guard let sampleRate = run.sampleRate, let channels = run.channels else {
            return String(localized: "session.settings.value.unknown")
        }
        return String(
            format: String(localized: "session.settings.value.audio_format"),
            UInt64(sampleRate).formatted(),
            UInt64(channels).formatted()
        )
    }
}

private struct SessionSettingsRowModel: Identifiable {
    let icon: String
    let label: String
    let value: String
    var id: String { label }
}

private struct SessionSettingsRow: View {
    let row: SessionSettingsRowModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.md) {
            Image(systemName: row.icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.textTertiary)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(row.label)
                .font(.bodySM)
                .foregroundColor(.textSecondary)
                .frame(width: 150, alignment: .leading)
            Text(row.value)
                .font(.bodyMedium)
                .foregroundColor(.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm + 2)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - NoteMetadataBar (pill-style metadata)

private struct NoteMetadataBar: View {
    let sessionId: String?
    @State private var sessionInfo: SessionInfo?

    var body: some View {
        HStack(spacing: Spacing.sm) {
            if let info = sessionInfo {
                if info.durationMs > 0 {
                    Pill(icon: "clock", text: formatDuration(info.durationMs))
                }
                if !info.sourceLanguage.isEmpty {
                    Pill(icon: "character.bubble", text: info.sourceLanguage.uppercased())
                }
            }
            Spacer()
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.bottom, Spacing.sm)
        .task(id: sessionId ?? "") { await load() }
    }

    @MainActor
    private func load() async {
        guard let sessionId, let core = CoreClient.shared.core else {
            sessionInfo = nil
            return
        }
        do {
            sessionInfo = try core.getSession(id: sessionId)
        } catch {
            // session 不存在(旧数据或未入 session_records),静默
            sessionInfo = nil
        }
    }

    private struct Pill: View {
        let icon: String
        let text: String
        var body: some View {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .medium))
                Text(text)
                    .font(.captionMedium)
            }
            .foregroundColor(.textSecondary)
        }
    }

    private func formatDuration(_ ms: UInt64) -> String {
        let total = Int(ms / 1000)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}

private struct ManualTimeNoteHeader: View {
    let notebookId: String
    let sessionId: String
    let initialTitle: String?
    let onRenamed: () -> Void

    @State private var title = ""
    @State private var savedTitle = ""
    @State private var createdAt: Date?
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
                TextField(
                    String(localized: "manual_note.title.placeholder"),
                    text: $title
                )
                .textFieldStyle(.plain)
                .font(.titleMD)
                .foregroundColor(.textPrimary)
                .onSubmit(save)
                .accessibilityIdentifier("manual_note.title")

                if title != savedTitle {
                    Button(action: save) {
                        if isSaving {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.brandAccent)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isSaving)
                    .help(String(localized: "manual_note.title.save"))
                    .accessibilityIdentifier("manual_note.title.save")
                }
            }

            HStack(spacing: Spacing.sm) {
                if let createdAt {
                    Label(
                        createdAt.formatted(date: .long, time: .shortened),
                        systemImage: "clock"
                    )
                    .font(.bodySM)
                    .foregroundColor(.textSecondary)
                    .accessibilityLabel(
                        String(
                            format: String(localized: "manual_note.created_at_format"),
                            createdAt.formatted(date: .long, time: .shortened)
                        )
                    )
                }

                Text(String(sessionId.prefix(8)))
                    .font(.caption.monospaced())
                    .foregroundColor(.textTertiary)

                Spacer()
            }
        }
        .padding(Spacing.md)
        .background(Color.bgElevated.opacity(0.28))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.sm)
                .strokeBorder(Color.borderGhost.opacity(0.5), lineWidth: Stroke.thin)
        )
        .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
        .padding(.horizontal, Spacing.lg)
        .padding(.bottom, Spacing.md)
        .task(id: sessionId) {
            title = initialTitle ?? ""
            savedTitle = title
            guard let core = CoreClient.shared.core,
                  let session = try? core.getSession(id: sessionId) else {
                createdAt = nil
                return
            }
            createdAt = Date(
                timeIntervalSince1970: TimeInterval(session.createdAtUnixMs) / 1_000
            )
        }
        .montereyOnChange(of: initialTitle) { _, newValue in
            let resolved = newValue ?? ""
            title = resolved
            savedTitle = resolved
        }
    }

    private func save() {
        guard isSaving == false, title != savedTitle,
              let core = CoreClient.shared.core else { return }
        isSaving = true
        do {
            let projection = try core.renameNotebookManualNote(
                notebookId: notebookId,
                sessionId: sessionId,
                title: title
            )
            title = projection.sectionTitle ?? ""
            savedTitle = title
            onRenamed()
        } catch {
            ToastCenter.shared.error(String(localized: "manual_note.title.save_failed"))
        }
        isSaving = false
    }
}

// MARK: - NoteBottomSignature (pipeline signature)

private struct NoteBottomSignature: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.shield")
                .font(.system(size: 10, weight: .medium))
            Text("editor.footer.local_encrypted")
            Spacer()
        }
        .font(.captionMedium)
        .foregroundColor(.textTertiary)
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, 6)
        .background(Color.bgSunken.opacity(0.6))
        .overlay(
            Rectangle()
                .fill(Color.borderGhost.opacity(0.3))
                .frame(height: 0.5),
            alignment: .top
        )
    }

}


// MARK: - BlockNoteUtilityBar(笔记 tab 的工具条:目前只有任务面板入口)

/// 旧格式工具栏拆除后保留的最小工具条。格式化不再存在(大纲编辑器 v1
/// 是纯文本行),但转录任务队列面板的入口仍要可达。
private struct BlockNoteUtilityBar: View {
    let isTasksPanelActive: Bool
    let onShowTasks: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack {
            Spacer()

            Button(action: onShowTasks) {
                Image(systemName: "checklist")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(
                        isTasksPanelActive
                            ? .brandAccent
                            : (isHovering ? .brandAccent : .textSecondary)
                    )
                    .frame(width: 32, height: 32)
                    .background(
                        isTasksPanelActive
                            ? Color.brandAccent.opacity(0.14)
                            : (isHovering ? Color.bgElevated.opacity(0.5) : Color.clear)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
                    .contentShape(RoundedRectangle(cornerRadius: Radius.sm))
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .help(String(localized: "editor.toolbar.show_tasks"))
            .accessibilityLabel(Text(String(localized: "editor.toolbar.show_tasks")))
            .accessibilityAddTraits(isTasksPanelActive ? .isSelected : [])
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.xs)
        .frame(height: 40)
        .background(Color.bgSunken)
    }
}
