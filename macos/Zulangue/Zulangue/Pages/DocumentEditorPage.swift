// DocumentEditorPage.swift
// 富文本笔记编辑器 — Loro CRDT 文档的 UI 宿主
// 权威:design-system/MASTER.md §10 · D5 §7.5
//
// 架构:
//   DocumentEditorPage (SwiftUI 宿主)
//     ├── NoteTopChrome  (后退 / title / document 切换器)
//     ├── NoteMetadataBar(pill 元数据)
//     ├── EditorToolbar  (B/I/H1-3/•/1./code/S)
//     ├── DocumentTextView(NSViewRepresentable 包 NSTextView)
//     │      └── LoroTextBridge ← 接 CoreClient 的 Rust EditorBridge
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
        status: NotebookTabStatus?,
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
            return status != .pending && status != .failed && selectedSessionId != nil
        case .manualNote, .none:
            return false
        }
    }
}

enum NotebookDocumentSurfacePolicy {
    static func mountsLoroTextEditor(for displayType: NotebookTabDisplayType?) -> Bool {
        displayType == .manualNote
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
        activeNotebookTab?.displayType == .manualNote && selectedSessionId == nil
    }

    @State private var bridge: LoroTextBridge?
    @State private var hostedTextView: NSTextView?
    @State private var currentSelection: NSRange = NSRange(location: 0, length: 0)
    @State private var formattingState: EditorFormattingState = .init()
    @State private var bridgeError: String?
    @State private var activeSidePanel: DocumentEditorSidePanel?
    @State private var isShowingExportSheet = false
    @State private var presentedCaptureSettingsNotebookId: String?
    @State private var isShowingResources = false

    /// Notebook-scoped unified tab surface, including realtime transcript.
    @State private var notebookTabs: [NotebookTabViewModel] = []
    @State private var editorNotebook: FfiNotebook?
    @StateObject private var notebookTasks = NotebookTasksViewModel()
    @StateObject private var captureProfileEditor: NotebookCaptureProfileEditorModel

    /// 当前是否展示 Transcript 视图(Plaud 式)。true 时隐藏 DocumentTextView。
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
    }

    var body: some View {
        VStack(spacing: 0) {
            // Route contains a stable builtin Loro document ID, so chrome can
            // remain mounted while Notebook metadata refreshes.
            if docId != nil {
                NoteTopChrome(
                    onBack: { WindowCommandRouter.shared.requestNavigateHome() }
                )

                DocumentTabBar(
                    tabs: notebookTabs,
                    activeTabId: activeNotebookTabId,
                    captureSettingsNotebookId: captureSettingsNotebookId,
                    isCaptureSettingsSelected: isShowingCaptureSettings,
                    isResourcesSelected: isShowingResources,
                    sessionId: effectiveSessionId,
                    onSelect: selectNotebookTab,
                    onSelectResources: showResources,
                    onSelectCaptureSettings: showCaptureSettings,
                    onExport: { isShowingExportSheet = true }
                )

                if isShowingCaptureSettings {
                    NotebookSettingsNotebookHeader(title: editorNotebook?.title)
                } else if isShowingResources == false {
                    NotebookBuiltinTabTitle(title: activeNotebookTab?.title)
                    if activeNotebookTab?.displayType == .manualNote,
                       let notebookId = route?.notebookID,
                       let sessionId = effectiveSessionId {
                        ManualTimeNoteHeader(
                            notebookId: notebookId,
                            sessionId: sessionId,
                            initialTitle: activeNotebookTab?.sessionLink?.sectionTitle,
                            onRenamed: {
                                Task { await loadNotebookRoute() }
                            }
                        )
                    } else {
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
                if let transcriptTab = activeNotebookTab,
                   transcriptTab.displayType == .realtimeTranscript {
                    NotebookRealtimeTranscriptPage(
                        notebookId: transcriptTab.notebookId,
                        sessionId: effectiveSessionId,
                        editor: captureProfileEditor,
                        onOpenAdvancedSettings: showCaptureSettings
                    )
                        .id("realtime:\(transcriptTab.notebookId)")
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
                        status: transcriptTab.status
                    )
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
                        onOpenRealtimeControls: openRealtimeControls
                    )
                        .id(notebookId)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                if isShowingResources, let notebookId = route?.notebookID {
                    NotebookResourcesView(
                        notebookId: notebookId,
                        onOpenSession: { sessionId in
                            WindowCommandRouter.shared.requestOpenSession(sessionId)
                        }
                    )
                    .id("resources:\(notebookId)")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.bgRoot)
        .sheet(isPresented: $isShowingExportSheet) {
            if let sessionId = effectiveSessionId {
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
                try? await Task.sleep(for: .seconds(1))
                guard Task.isCancelled == false else { return }
                await loadNotebookRoute()
                guard selectedTranscriptionTask?.tabStatus == .pending else { return }
            }
        }
        .onChange(of: initialView) { _, _ in syncPresentedRoute() }
        .onChange(of: route) { previousRoute, currentRoute in
            if NotebookCaptureSettingsRoutePolicy.shouldDismiss(
                previous: previousRoute,
                current: currentRoute
            ) {
                presentedCaptureSettingsNotebookId = nil
            }
        }
        // 停录后的异步转录物化完成后重新加载关联文档。
        .onReceive(NotificationCenter.default.publisher(for: .zulangueSessionUpdated)) { _ in
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
            if NotebookDocumentSurfacePolicy.mountsLoroTextEditor(
                for: activeNotebookTab?.displayType
            ) {
                EditorToolbar(
                    textView: hostedTextView,
                    selection: currentSelection,
                    hasSelection: currentSelection.length > 0,
                    formattingState: formattingState,
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
        case .documentUnavailable(let message):
            EmptyState(
                icon: "exclamationmark.triangle",
                title: String(localized: "editor.empty.unavailable_title"),
                description: message
            )

        case .asyncPending:
            PendingDocumentState()

        case .asyncFailed:
            FailedDocumentState(errorMessage: selectedTranscriptionTask?.errorMessage)

        case .manualNote:
            // 文档切换时通过 updateNSView 更换 bridge，并复用 NSTextView。
            ZStack(alignment: .topLeading) {
                DocumentTextView(
                    notebookId: notebookId,
                    tabId: tabId,
                    isEditable: surface.allowsTextEditing,
                    bridge: $bridge,
                    textView: $hostedTextView,
                    selection: $currentSelection,
                    formattingState: $formattingState,
                    bridgeError: $bridgeError,
                    onTextActivity: {},
                    onViewportChanged: {}
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .asyncNeedsSession:
            // The transcript layer is session-scoped, so the editor layer owns
            // this state rather than falling through to a blank surface.
            EmptyState(
                illustration: { Arcanum003WaveformRuler() },
                title: String(localized: "editor.transcript.async.no_session_title"),
                description: String(localized: "editor.transcript.async.no_session_desc")
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
            bridgeError: bridgeError
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

    private var effectiveSessionId: String? {
        selectedSessionId
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
        [route?.notebookID, route?.tabID, route?.documentID, selectedSessionId]
            .compactMap { $0 }
            .joined(separator: ":")
    }

    // MARK: - Loading

    private func loadNotebookRoute() async {
        guard let route, let core = CoreClient.shared.core else {
            notebookTabs = []
            editorNotebook = nil
            transcriptionTasksBySessionId = [:]
            return
        }
        do {
            let loadedTranscriptionTasks = TranscriptionTaskIndex.load(core: core)
            let loadedNotebook = try core.listNotebooks().first { $0.id == route.notebookID }
            let activeCapture = ActiveBilingualTranscriptStore.shared
            let realtimeSessionId = selectedSessionId
                ?? (activeCapture.notebookId == route.notebookID ? activeCapture.sessionId : nil)
            let loadedTabs = try loadNotebookTabModels(
                notebookId: route.notebookID,
                realtimeSessionId: realtimeSessionId,
                transcriptionTasksBySessionId: loadedTranscriptionTasks,
                core: core
            )
            await MainActor.run {
                self.notebookTabs = loadedTabs
                self.editorNotebook = loadedNotebook
                self.transcriptionTasksBySessionId = loadedTranscriptionTasks
                let selectedTab = loadedTabs.first { $0.id == route.tabID }
                self.showTranscript = NotebookTranscriptPresentationPolicy.shouldShow(
                    displayType: selectedTab?.displayType,
                    status: selectedTab?.status,
                    selectedSessionId: self.selectedSessionId
                )
            }
        } catch {
            DebugLog.warn("load notebook route failed", detail: "\(error)")
        }
    }

    private func loadNotebookTabModels(
        notebookId: String,
        realtimeSessionId: String?,
        transcriptionTasksBySessionId: [String: TranscriptionTaskSnapshot],
        core: any ZulangueCoreProtocol
    ) throws -> [NotebookTabViewModel] {
        let backendTabs = try core.listNotebookTabs(notebookId: notebookId)
        var projectionsByTabId: [String: [FfiNotebookSessionProjection]] = [:]

        for tab in backendTabs {
            projectionsByTabId[tab.id] = (try? core.listNotebookSessionProjections(tabId: tab.id)) ?? []
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
        let reusesCurrentRoute = NotebookCaptureSettingsRoutePolicy.reusesCurrentRoute(
            selectedTabId: tab.id,
            activeTabId: activeNotebookTabId
        )
        presentedCaptureSettingsNotebookId = nil
        isShowingResources = false
        if reusesCurrentRoute {
            syncPresentedRoute()
            return
        }
        showTranscript = false
        WindowCommandRouter.shared.requestOpenNotebookTab(
            notebookID: tab.notebookId,
            tabID: tab.tabId,
            documentID: tab.documentId,
            selectedSessionID: selectedSessionId
        )
    }

    private func showCaptureSettings() {
        guard let notebookId = captureSettingsNotebookId else { return }
        activeSidePanel = nil
        hostedTextView?.window?.makeFirstResponder(nil)
        isShowingResources = false
        presentedCaptureSettingsNotebookId = notebookId
    }

    private func showResources() {
        activeSidePanel = nil
        hostedTextView?.window?.makeFirstResponder(nil)
        presentedCaptureSettingsNotebookId = nil
        showTranscript = false
        isShowingResources = true
    }

    private func openRealtimeControls() {
        guard let realtimeTab = notebookTabs.first(where: {
            $0.displayType == .realtimeTranscript
        }) else { return }
        selectNotebookTab(realtimeTab)
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

// MARK: - Pending / Failed document states (Plan A UX)

/// status=pending 时覆盖 editor area 的占位面板。
private struct PendingDocumentState: View {
    var body: some View {
        VStack(spacing: Spacing.md) {
            ProgressView()
                .controlSize(.small)
            Text(title)
                .font(.bodyMedium)
                .foregroundColor(.textSecondary)
            Text(subtitle)
                .font(.caption)
                .foregroundColor(.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var title: String {
        String(localized: "editor.pending.transcribing")
    }
    private var subtitle: String {
        String(localized: "editor.pending.subtitle")
    }
}

/// status=failed 时的 editor area — 显示"重新转录"按钮。
private struct FailedDocumentState: View {
    let errorMessage: String?

    var body: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 28))
                .foregroundColor(.signalAmber)
            Text(title)
                .font(.bodyMedium)
                .foregroundColor(.textSecondary)
            Text(String(localized: "editor.failed.subtitle"))
                .font(.caption)
                .foregroundColor(.textTertiary)
                .multilineTextAlignment(.center)
            if let errorMessage, !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.signalRed)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var title: String {
        String(localized: "editor.failed.transcribing")
    }
}

// MARK: - NoteTopChrome (简化:只剩 back 按钮,document 切换移到下方 DocumentTabBar)

private struct NoteTopChrome: View {
    let onBack: () -> Void

    var body: some View {
        HStack(spacing: Spacing.md) {
            Button(action: onBack) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                    Text("sidebar.home")
                        .font(.captionMedium)
                }
                .foregroundColor(.textSecondary)
            }
            .buttonStyle(.plain)
            .help(String(localized: "sidebar.back_to_home"))

            Spacer()
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.sm)
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
    let sessionId: String?
    let onSelect: (NotebookTabViewModel) -> Void
    let onSelectResources: () -> Void
    let onSelectCaptureSettings: () -> Void
    let onExport: () -> Void
    @ObservedObject private var captureStore = ActiveBilingualTranscriptStore.shared

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(tabs) { tab in
                        NotebookTabButton(
                            tab: effectiveTab(tab),
                            isActive: isCaptureSettingsSelected == false
                                && isResourcesSelected == false
                                && tab.id == activeTabId,
                            action: { onSelect(tab) }
                        )
                    }

                    ResourcesTabButton(
                        isActive: isResourcesSelected,
                        action: onSelectResources
                    )

                    if captureSettingsNotebookId != nil {
                        CaptureSettingsTabButton(
                            isActive: isCaptureSettingsSelected,
                            action: onSelectCaptureSettings
                        )
                    }
                }
            }

            Spacer(minLength: Spacing.md)

            if isCaptureSettingsSelected == false && isResourcesSelected == false {
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

    private func effectiveTab(_ tab: NotebookTabViewModel) -> NotebookTabViewModel {
        let resolvedStatus = NotebookRealtimeTabStatusPolicy.resolve(
            displayType: tab.displayType,
            baseStatus: tab.status,
            tabNotebookId: tab.notebookId,
            activeNotebookId: captureStore.notebookId,
            activeSessionId: captureStore.sessionId,
            captureIsActive: captureStore.captureState.isActive
        )
        guard resolvedStatus != tab.status else { return tab }
        return NotebookTabViewModel(
            id: tab.id,
            notebookId: tab.notebookId,
            tabId: tab.tabId,
            displayType: tab.displayType,
            documentId: tab.documentId,
            sessionLink: tab.sessionLink,
            title: tab.title,
            status: resolvedStatus,
            position: tab.position
        )
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
                    String(localized: "resources.tab"),
                    systemImage: "tray.full"
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
        .help(String(localized: "resources.tab.hint"))
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
                    String(localized: "capture.settings.tab"),
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
        .help(String(localized: "capture.settings.tab_hint"))
        .accessibilityLabel(Text(String(localized: "capture.settings.tab")))
        .accessibilityHint(Text(String(localized: "capture.settings.tab_hint")))
        .accessibilityAddTraits(isActive ? .isSelected : [])
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
        .onChange(of: tab.status) { _, newStatus in
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
        let state: String
        switch tab.status {
        case .ready: state = "Ready"
        case .pending: state = "Transcription pending"
        case .failed: state = "Transcription failed"
        case .live: state = "Live transcription"
        }
        return isActive ? "Selected, \(state)" : state
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

    @ObservedObject private var projectionStore = NotebookTranscriptProjectionStore.shared
    @State private var editingIndex: Int?
    @State private var editingDraft = ""
    @State private var projectionAttachment: NotebookTranscriptProjectionStore.Attachment?

    private var lines: [NotebookTranscriptLine] {
        projectionStore.linesBySession[sessionId] ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            asyncStatusBar
            Divider().background(Color.borderGhost.opacity(0.25))
            Group {
                if lines.isEmpty {
                    EmptyState(
                        illustration: { Arcanum003WaveformRuler() },
                        title: emptyStateTitle,
                        description: emptyStateDescription
                    )
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: Spacing.xl) {
                            ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                                TranscriptSegmentView(
                                    line: line,
                                    isEditing: editingIndex == index,
                                    isEditable: projectionStore.editableBySession[sessionId] == true,
                                    draft: $editingDraft,
                                    onStartEdit: {
                                        editingDraft = line.text
                                        editingIndex = index
                                    },
                                    onCommit: {
                                        projectionStore.replaceSegment(
                                            sessionId: sessionId,
                                            segmentIndex: index,
                                            text: editingDraft
                                        )
                                        editingIndex = nil
                                    },
                                    onCancel: {
                                        editingIndex = nil
                                    }
                                )
                            }
                        }
                        .padding(.horizontal, Spacing.xl + Spacing.lg)
                        .padding(.vertical, Spacing.xl)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.bgRoot)
        .task(id: "\(sessionId):\(tabId)") {
            if let projectionAttachment {
                projectionStore.detach(projectionAttachment)
            }
            projectionAttachment = projectionStore.attachIfNeeded(
                sessionId: sessionId,
                notebookId: notebookId,
                tabId: tabId
            )
        }
        .onDisappear {
            if let projectionAttachment {
                projectionStore.detach(projectionAttachment)
                self.projectionAttachment = nil
            }
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

    private var asyncStatusBar: some View {
        HStack(spacing: Spacing.sm) {
            if asyncProjectionState == .projecting || isRetryingProjection {
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
            if canRequestAsyncTranscription {
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
            }
            if asyncProjectionState == .failed {
                Button {
                    retryLocalProjection()
                } label: {
                    Label(
                        String(localized: "editor.transcript.async.retry_projection"),
                        systemImage: "arrow.clockwise"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .frame(minHeight: 44)
                .disabled(isRetryingProjection)
                .help(String(localized: "editor.transcript.async.retry_projection_hint"))
                .accessibilityHint(Text(String(
                    localized: "editor.transcript.async.retry_projection_hint"
                )))
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

    private var canRequestAsyncTranscription: Bool {
        asyncProjectionState == NotebookAsyncProjectionState.none
            && (asyncProviderState == nil || asyncProviderState == "none")
    }

    private func requestAsyncTranscription() {
        Task { @MainActor in
            do {
                try await projectionStore.requestAsyncTranscription(
                    sessionId: sessionId,
                    notebookId: notebookId
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
        if isRetryingProjection {
            return String(localized: "editor.transcript.async.status.projecting")
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
        switch asyncProjectionState {
        case .some(.ready): return .signalGreen
        case .some(.failed): return .signalAmber
        default: return .textTertiary
        }
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

    private var emptyStateTitle: String {
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
        switch asyncProjectionState {
        case .some(.pending), .some(.projecting):
            return String(localized: "editor.transcript.async.projection_pending_desc")
        case .some(.failed):
            return String(localized: "editor.transcript.async.projection_failed_desc")
        case .some(.none) where status == .pending || isProviderPending:
            return String(localized: "editor.transcript.async.pending_desc")
        case .some(.none) where status == .failed || asyncProviderState == "failed":
            return String(localized: "editor.transcript.async.failed_desc")
        default:
            return String(localized: "editor.transcript.async.empty_desc")
        }
    }

    private var isProviderPending: Bool {
        ["pending", "reserved", "enqueued"].contains(asyncProviderState)
    }
}
/// 单个转录段落的渲染。click 切换编辑模式。
private struct TranscriptSegmentView: View {
    let line: NotebookTranscriptLine
    let isEditing: Bool
    let isEditable: Bool
    @Binding var draft: String
    let onStartEdit: () -> Void
    let onCommit: () -> Void
    let onCancel: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 时间戳 — 小字灰色
            HStack(spacing: Spacing.md) {
                Text(formatTs(line.startMs))
                    .font(.captionMedium.monospacedDigit())
                    .foregroundColor(.textTertiary)
                Spacer()
                if isHovering && !isEditing && isEditable {
                    Text("Edit")
                        .font(.captionMedium)
                        .foregroundColor(.textTertiary.opacity(0.8))
                }
            }

            if isEditing {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    TextEditor(text: $draft)
                        .font(.system(size: 15))
                        .foregroundColor(.textPrimary)
                        .scrollContentBackground(.hidden)
                        .background(Color.bgSunken)
                        .overlay(
                            RoundedRectangle(cornerRadius: Radius.sm)
                                .strokeBorder(Color.brandAccent.opacity(0.6), lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
                        .frame(minHeight: 80)

                    HStack(spacing: Spacing.sm) {
                        Button("Save") { onCommit() }
                            .keyboardShortcut(.return, modifiers: .command)
                        Button("Cancel") { onCancel() }
                            .keyboardShortcut(.cancelAction)
                        Spacer()
                        Text("⌘↵ save · esc cancel")
                            .font(.captionMedium)
                            .foregroundColor(.textTertiary)
                    }
                }
            } else {
                Button(action: onStartEdit) {
                    Text(line.text)
                        .font(.system(size: 15))
                        .foregroundColor(.textPrimary)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, Spacing.sm)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: Radius.sm)
                                .fill(
                                    (isHovering && isEditable)
                                        ? Color.bgElevated.opacity(0.35)
                                        : Color.clear
                                )
                        )
                }
                .buttonStyle(.plain)
                .disabled(!isEditable)
                .accessibilityLabel(Text("Transcript segment at \(formatTs(line.startMs))"))
                .accessibilityValue(Text(line.text))
                .accessibilityHint(Text(isEditable ? "Edit transcript segment" : "Available after transcription completes"))
            }
        }
        .onHover { isHovering = $0 }
    }

    private func formatTs(_ ms: UInt64) -> String {
        let total = Int(ms / 1000)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%02d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
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
        .onChange(of: initialTitle) { _, newValue in
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

// MARK: - Toolbar

private struct EditorFormattingState: Equatable {
    var isBold: Bool = false
    var isItalic: Bool = false
    var isCode: Bool = false
    var isStrike: Bool = false
    var headingLevel: Int?
    var listKind: String?
    var listDepth: Int?
    var isPendingBlock: Bool = false

    var blockLabel: String {
        if let level = headingLevel {
            return "H\(level)"
        }
        switch listKind {
        case "bullet":
            return "List"
        case "ordered":
            return "Ordered"
        default:
            return "Body"
        }
    }

    var statusLabel: String {
        let label: String = {
            if let depth = listDepth, listKind != nil, depth > 1 {
                return "\(blockLabel) · L\(depth)"
            }
            return blockLabel
        }()
        return isPendingBlock ? "\(label) pending" : label
    }
}

private struct EditorToolbar: View {
    let textView: NSTextView?
    let selection: NSRange
    let hasSelection: Bool
    let formattingState: EditorFormattingState
    let isTasksPanelActive: Bool
    let onShowTasks: (() -> Void)?

    private var editorTextView: LoroBackedTextView? {
        textView as? LoroBackedTextView
    }

    var body: some View {
        HStack(spacing: 4) {
            ToolButton(label: "B", tooltip: "Bold  ⌘B", isBold: true, isActive: formattingState.isBold) {
                editorTextView?.toggleInlineStyle(key: LoroMarkKey.bold, valueJson: LoroMarkValue.trueJson)
            }
            .keyboardShortcut("b", modifiers: .command)

            ToolButton(label: "I", tooltip: "Italic  ⌘I", isItalic: true, isActive: formattingState.isItalic) {
                editorTextView?.toggleInlineStyle(key: LoroMarkKey.italic, valueJson: LoroMarkValue.trueJson)
            }
            .keyboardShortcut("i", modifiers: .command)

            ToolButton(label: "S", tooltip: "Strikethrough", isStrike: true, isActive: formattingState.isStrike) {
                editorTextView?.toggleInlineStyle(key: LoroMarkKey.strikethrough, valueJson: LoroMarkValue.trueJson)
            }

            ToolDivider()

            ToolButton(label: "P", tooltip: "Body  ⌘0", isActive: formattingState.headingLevel == nil && formattingState.listKind == nil) {
                editorTextView?.clearBlockStyle()
            }
            .keyboardShortcut("0", modifiers: .command)

            ToolButton(label: "H1", tooltip: "Heading 1  ⌘1", isActive: formattingState.headingLevel == 1) {
                editorTextView?.toggleHeading(level: 1)
            }
            .keyboardShortcut("1", modifiers: .command)

            ToolButton(label: "H2", tooltip: "Heading 2  ⌘2", isActive: formattingState.headingLevel == 2) {
                editorTextView?.toggleHeading(level: 2)
            }
            .keyboardShortcut("2", modifiers: .command)

            ToolButton(label: "H3", tooltip: "Heading 3  ⌘3", isActive: formattingState.headingLevel == 3) {
                editorTextView?.toggleHeading(level: 3)
            }
            .keyboardShortcut("3", modifiers: .command)

            ToolDivider()

            ToolButton(systemIcon: "list.bullet", tooltip: "Bullet list  ⌘⇧8", isActive: formattingState.listKind == "bullet") {
                editorTextView?.toggleList(kind: "bullet")
            }
            .keyboardShortcut("8", modifiers: [.command, .shift])

            ToolButton(systemIcon: "list.number", tooltip: "Numbered list  ⌘⇧7", isActive: formattingState.listKind == "ordered") {
                editorTextView?.toggleList(kind: "ordered")
            }
            .keyboardShortcut("7", modifiers: [.command, .shift])

            ToolDivider()

            ToolButton(systemIcon: "curlybraces", tooltip: "Inline code  ⌘E", isActive: formattingState.isCode) {
                editorTextView?.toggleInlineStyle(key: LoroMarkKey.code, valueJson: LoroMarkValue.trueJson)
            }
            .keyboardShortcut("e", modifiers: .command)

            ToolButton(systemIcon: "checklist", tooltip: String(localized: "editor.toolbar.show_tasks"), isActive: isTasksPanelActive) {
                onShowTasks?()
            }
            .disabled(onShowTasks == nil)

            Spacer()

            Text(hasSelection ? "\(selection.length) sel · \(formattingState.statusLabel)" : formattingState.statusLabel)
                .font(.captionMedium)
                .foregroundColor(.textTertiary)
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.sm)
        .frame(height: 44)
        .background(Color.bgSunken)
        .disabled(editorTextView?.loroBridge == nil)
    }
}

private struct ToolButton: View {
    var label: String? = nil
    var systemIcon: String? = nil
    let tooltip: String
    var isBold: Bool = false
    var isItalic: Bool = false
    var isStrike: Bool = false
    var isActive: Bool = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Group {
                if let icon = systemIcon {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                } else if let label = label {
                    Text(label)
                        .font(font)
                        .strikethrough(isStrike)
                }
            }
            .foregroundColor(isActive ? .brandAccent : (isHovering ? .brandAccent : .textSecondary))
            .frame(width: 32, height: 32)
            .background(
                isActive
                    ? Color.brandAccent.opacity(0.14)
                    : (isHovering ? Color.bgElevated.opacity(0.5) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.sm)
                    .strokeBorder(
                        isActive ? Color.brandAccent.opacity(0.45) : Color.clear,
                        lineWidth: 0.8
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
            .contentShape(RoundedRectangle(cornerRadius: Radius.sm))
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .accessibilityLabel(Text(tooltip))
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.1), value: isHovering)
    }

    private var font: Font {
        if isBold { return .system(size: 13, weight: .bold) }
        if isItalic { return .system(size: 13, weight: .regular).italic() }
        return .system(size: 12, weight: .semibold)
    }
}

private struct ToolDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.borderGhost.opacity(0.3))
            .frame(width: 1, height: 20)
            .padding(.horizontal, 4)
    }
}

// MARK: - NSTextView 子类:拦截快捷键,并统一处理 toolbar / keyboard / markdown
//         三条编辑路径。这样同一个格式动作只走一套逻辑,不会出现"快捷键能用、
//         toolbar 不对、markdown 还要再等一下"的割裂体验。

final class LoroBackedTextView: NSTextView {
    enum PendingBlockStyle: Equatable {
        case heading(level: Int, anchor: Int)
        case list(kind: String, depth: Int, anchor: Int)

        var anchor: Int {
            switch self {
            case .heading(_, let anchor), .list(_, _, let anchor):
                return anchor
            }
        }

        var listStyle: LoroListStyle? {
            switch self {
            case .heading:
                return nil
            case .list(let kind, let depth, _):
                return LoroListStyle(kind: kind, depth: depth)
            }
        }
    }

    // NSTextStorage.delegate does not own the bridge. Keep it alive with the
    // text view; LoroTextBridge only keeps a weak textView, so this is acyclic.
    var loroBridge: LoroTextBridge?
    var pendingBlockStyle: PendingBlockStyle?
    var pendingMarkdownPrefix: String?
    var pendingNewlineUnmark: Int?
    fileprivate var formattingStateDidChange: ((EditorFormattingState) -> Void)?

    private var renderStyle: LoroRenderStyle {
        loroBridge?.renderStyle ?? .default
    }

    private struct ListParagraphSnapshot: Equatable {
        let anchor: Int
        let style: LoroListStyle?
    }

    private struct PendingListSnapshot: Equatable {
        let style: LoroListStyle
        let anchor: Int
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateReadableLayout()
    }

    func updateReadableLayout() {
        guard let textContainer else { return }
        textContainer.lineFragmentPadding = 0
        let referenceWidth = max(bounds.width, enclosingScrollView?.contentSize.width ?? 0)
        let horizontalInset = renderStyle.readableHorizontalInset(for: referenceWidth)
        let targetInset = NSSize(width: horizontalInset, height: LoroRenderStyle.verticalInset)
        if textContainerInset != targetInset {
            textContainerInset = targetInset
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard loroBridge != nil else {
            return super.performKeyEquivalent(with: event)
        }

        let keyChar = event.charactersIgnoringModifiers ?? ""
        switch (mods, keyChar) {
        case (.command, "b"):
            DebugLog.info("⌘B bold", detail: "sel \(selectedRange().length) chars")
            toggleInlineStyle(key: LoroMarkKey.bold, valueJson: LoroMarkValue.trueJson)
            return true
        case (.command, "i"):
            DebugLog.info("⌘I italic", detail: "sel \(selectedRange().length) chars")
            toggleInlineStyle(key: LoroMarkKey.italic, valueJson: LoroMarkValue.trueJson)
            return true
        case (.command, "e"):
            DebugLog.info("⌘E code", detail: "sel \(selectedRange().length) chars")
            toggleInlineStyle(key: LoroMarkKey.code, valueJson: LoroMarkValue.trueJson)
            return true
        case (.command, "0"):
            DebugLog.info("⌘0 body", detail: "paragraph")
            clearBlockStyle()
            return true
        case (.command, "1"), (.command, "2"), (.command, "3"):
            let level = Int(keyChar) ?? 1
            DebugLog.info("⌘\(level) H\(level)", detail: "paragraph")
            toggleHeading(level: level)
            return true
        case ([.command, .shift], "7"):
            DebugLog.info("⌘⇧7 ordered list", detail: "paragraph")
            toggleList(kind: "ordered")
            return true
        case ([.command, .shift], "8"):
            DebugLog.info("⌘⇧8 bullet list", detail: "paragraph")
            toggleList(kind: "bullet")
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    private func cancelPendingBlockStyle(restoreMarkdownPrefix: Bool) -> Bool {
        guard let pendingBlockStyle else { return false }

        let selection = selectedRange()
        guard selection.length == 0 else { return false }

        let paragraph = paragraphContentRange(in: selection)
        guard paragraph.length == 0, paragraph.location == pendingBlockStyle.anchor else {
            return false
        }

        let restoredPrefix = restoreMarkdownPrefix ? pendingMarkdownPrefix : nil
        clearPendingBlockStyle(syncTypingAttributes: false)
        typingAttributes = bodyTypingAttributes(from: typingAttributes)

        if let restoredPrefix, let storage = textStorage {
            storage.replaceCharacters(
                in: NSRange(location: selection.location, length: 0),
                with: restoredPrefix
            )
            let offset = (restoredPrefix as NSString).length
            setSelectedRange(NSRange(location: selection.location + offset, length: 0))
        }

        publishFormattingState()
        return true
    }

    override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(cancelOperation(_:)):
            if cancelPendingBlockStyle(restoreMarkdownPrefix: false) {
                return
            }
        case #selector(deleteBackward(_:)):
            if cancelPendingBlockStyle(restoreMarkdownPrefix: true) {
                return
            }
        case #selector(insertTab(_:)):
            if adjustListDepth(by: 1) {
                return
            }
        case #selector(insertBacktab(_:)):
            if adjustListDepth(by: -1) {
                return
            }
        default:
            break
        }
        super.doCommand(by: selector)
    }

    func publishFormattingState() {
        formattingStateDidChange?(currentFormattingState())
    }

    func resetTransientEditorState() {
        pendingBlockStyle = nil
        pendingMarkdownPrefix = nil
        pendingNewlineUnmark = nil
        typingAttributes = baseTypingAttributes()
        publishFormattingState()
    }

    func syncPendingBlockStyleForSelectionIfNeeded() {
        guard let pendingBlockStyle else { return }
        if paragraphContentRange(in: selectedRange()).location != pendingBlockStyle.anchor {
            clearPendingBlockStyle(syncTypingAttributes: true)
        }
    }

    func refreshTypingAttributesFromSelectionContext() {
        guard pendingBlockStyle == nil else {
            publishFormattingState()
            return
        }
        guard let storage = textStorage else {
            typingAttributes = baseTypingAttributes()
            publishFormattingState()
            return
        }
        let range = selectedRange()
        guard range.length == 0 else {
            publishFormattingState()
            return
        }
        guard storage.length > 0 else {
            typingAttributes = baseTypingAttributes()
            publishFormattingState()
            return
        }

        let ns = string as NSString
        let atLineStart = range.location == 0 || (range.location > 0 && ns.character(at: range.location - 1) == 10)
        let sampleIndex: Int
        if atLineStart, range.location < storage.length {
            sampleIndex = range.location
        } else if range.location > 0 {
            sampleIndex = min(range.location - 1, storage.length - 1)
        } else {
            sampleIndex = 0
        }

        typingAttributes = normalizedTypingAttributes(storage.attributes(at: sampleIndex, effectiveRange: nil))
        publishFormattingState()
    }

    func toggleInlineStyle(key: String, valueJson: String) {
        guard let bridge = loroBridge else { return }
        let range = selectedRange()
        if range.length > 0 {
            bridge.toggleMark(key: key, valueJson: valueJson, utf16Range: range)
            publishFormattingState()
            return
        }

        let current = currentFormattingState()
        let shouldEnable: Bool = {
            switch key {
            case LoroMarkKey.bold:          return !current.isBold
            case LoroMarkKey.italic:        return !current.isItalic
            case LoroMarkKey.code:          return !current.isCode
            case LoroMarkKey.strikethrough: return !current.isStrike
            default:                        return true
            }
        }()
        typingAttributes = typingAttributesByTogglingInlineMark(
            key: key,
            enabled: shouldEnable,
            attrs: typingAttributes
        )
        publishFormattingState()
    }

    func toggleHeading(level: Int) {
        guard let bridge = loroBridge else { return }
        let contentRange = paragraphContentRange(in: selectedRange())
        let fullRange = paragraphRangeIncludingTrailingNewline(in: selectedRange())

        if contentRange.length == 0 {
            if currentFormattingState().headingLevel == level {
                clearBlockStyle()
            } else {
                setPendingBlockStyle(.heading(level: level, anchor: contentRange.location))
            }
            return
        }

        if paragraphHeadingLevel(contentRange) == level {
            bridge.removeMark(key: LoroMarkKey.heading, utf16Range: fullRange)
            clearPendingBlockStyle(syncTypingAttributes: false)
            typingAttributes = bodyTypingAttributes(from: typingAttributes)
            publishFormattingState()
        } else {
            bridge.removeMark(key: LoroMarkKey.heading, utf16Range: fullRange)
            bridge.removeMark(key: LoroMarkKey.list, utf16Range: fullRange)
            bridge.applyMark(
                key: LoroMarkKey.heading,
                valueJson: LoroMarkValue.int(level),
                utf16Range: contentRange
            )
            clearPendingBlockStyle(syncTypingAttributes: false)
            typingAttributes = blockTypingAttributes(
                from: typingAttributes,
                blockStyle: .heading(level: level, anchor: contentRange.location)
            )
            publishFormattingState()
        }
    }

    func toggleList(kind: String) {
        guard let bridge = loroBridge else { return }
        let contentRange = paragraphContentRange(in: selectedRange())
        let fullRange = paragraphRangeIncludingTrailingNewline(in: selectedRange())
        let existingListStyle = paragraphListStyle(in: contentRange)
        let targetListStyle = LoroListStyle(
            kind: kind,
            depth: existingListStyle?.depth ?? currentFormattingState().listDepth ?? 1
        )

        if contentRange.length == 0 {
            if currentFormattingState().listKind == kind {
                clearBlockStyle()
            } else {
                setPendingBlockStyle(
                    .list(kind: kind, depth: targetListStyle.depth, anchor: contentRange.location)
                )
            }
            return
        }

        if existingListStyle?.kind == kind {
            bridge.removeMark(key: LoroMarkKey.list, utf16Range: fullRange)
            clearPendingBlockStyle(syncTypingAttributes: false)
            typingAttributes = bodyTypingAttributes(from: typingAttributes)
            publishFormattingState()
        } else {
            bridge.removeMark(key: LoroMarkKey.heading, utf16Range: fullRange)
            bridge.removeMark(key: LoroMarkKey.list, utf16Range: fullRange)
            bridge.applyMark(
                key: LoroMarkKey.list,
                valueJson: targetListStyle.valueJson,
                utf16Range: contentRange
            )
            clearPendingBlockStyle(syncTypingAttributes: false)
            typingAttributes = blockTypingAttributes(
                from: typingAttributes,
                blockStyle: .list(
                    kind: kind,
                    depth: targetListStyle.depth,
                    anchor: contentRange.location
                )
            )
            publishFormattingState()
        }
    }

    func clearBlockStyle() {
        guard let bridge = loroBridge else { return }
        let fullRange = paragraphRangeIncludingTrailingNewline(in: selectedRange())
        if fullRange.length > 0 {
            bridge.removeMark(key: LoroMarkKey.heading, utf16Range: fullRange)
            bridge.removeMark(key: LoroMarkKey.list, utf16Range: fullRange)
        }
        clearPendingBlockStyle(syncTypingAttributes: false)
        typingAttributes = bodyTypingAttributes(from: typingAttributes)
        publishFormattingState()
    }

    private func adjustListDepth(by delta: Int) -> Bool {
        let actionName = delta > 0 ? "Indent List" : "Outdent List"

        if let pending = currentPendingListSnapshot() {
            let nextDepth = pending.style.depth + delta
            let nextSnapshot: PendingListSnapshot? = nextDepth < LoroListStyle.minDepth
                ? nil
                : PendingListSnapshot(
                    style: LoroListStyle(kind: pending.style.kind, depth: nextDepth),
                    anchor: pending.anchor
                )
            restorePendingListSnapshot(
                nextSnapshot,
                inverse: pending,
                actionName: actionName
            )
            return true
        }

        let before = selectedListParagraphSnapshots()
        guard before.contains(where: { $0.style != nil }) else { return false }

        let after = before.map { snapshot in
            guard let style = snapshot.style else { return snapshot }
            let nextDepth = style.depth + delta
            if nextDepth < LoroListStyle.minDepth {
                return ListParagraphSnapshot(anchor: snapshot.anchor, style: nil)
            }
            return ListParagraphSnapshot(
                anchor: snapshot.anchor,
                style: LoroListStyle(kind: style.kind, depth: nextDepth)
            )
        }

        restoreListParagraphSnapshots(after, inverse: before, actionName: actionName)
        return true
    }

    private func currentPendingListSnapshot() -> PendingListSnapshot? {
        guard let pendingBlockStyle,
              case .list(let kind, let depth, let anchor) = pendingBlockStyle,
              selectedRange().length == 0
        else {
            return nil
        }

        let paragraph = paragraphContentRange(in: selectedRange())
        guard paragraph.length == 0, paragraph.location == anchor else { return nil }
        return PendingListSnapshot(style: LoroListStyle(kind: kind, depth: depth), anchor: anchor)
    }

    private func selectedListParagraphSnapshots() -> [ListParagraphSnapshot] {
        let ns = string as NSString
        guard ns.length > 0 else { return [] }

        let iterationRange = paragraphIterationRange(in: selectedRange(), text: ns)
        guard iterationRange.length > 0 else { return [] }

        var snapshots: [ListParagraphSnapshot] = []
        var cursor = iterationRange.location
        let end = iterationRange.location + iterationRange.length

        while cursor < end {
            let paragraphRange = ns.paragraphRange(for: NSRange(location: cursor, length: 0))
            let contentRange = paragraphContentRange(for: paragraphRange, text: ns)
            snapshots.append(
                ListParagraphSnapshot(
                    anchor: contentRange.location,
                    style: paragraphListStyle(in: contentRange)
                )
            )

            let next = paragraphRange.location + max(paragraphRange.length, 1)
            if next <= cursor {
                break
            }
            cursor = next
        }

        return snapshots
    }

    private func paragraphIterationRange(in selection: NSRange, text: NSString) -> NSRange {
        guard text.length > 0 else { return NSRange(location: 0, length: 0) }

        let safeStart = min(selection.location, max(text.length - 1, 0))
        let startParagraph = text.paragraphRange(for: NSRange(location: safeStart, length: 0))

        if selection.length == 0 {
            return startParagraph
        }

        let safeEnd = min(selection.location + max(selection.length - 1, 0), text.length - 1)
        let endParagraph = text.paragraphRange(for: NSRange(location: safeEnd, length: 0))
        let combinedEnd = endParagraph.location + endParagraph.length
        return NSRange(location: startParagraph.location, length: combinedEnd - startParagraph.location)
    }

    private func restorePendingListSnapshot(
        _ snapshot: PendingListSnapshot?,
        inverse: PendingListSnapshot?,
        actionName: String
    ) {
        registerUndoAction(name: actionName) { tv in
            tv.restorePendingListSnapshot(inverse, inverse: snapshot, actionName: actionName)
        }

        if let snapshot {
            setSelectedRange(NSRange(location: snapshot.anchor, length: 0))
            setPendingBlockStyle(
                .list(kind: snapshot.style.kind, depth: snapshot.style.depth, anchor: snapshot.anchor)
            )
        } else {
            clearPendingBlockStyle(syncTypingAttributes: false)
            typingAttributes = bodyTypingAttributes(from: typingAttributes)
            publishFormattingState()
        }
    }

    private func restoreListParagraphSnapshots(
        _ snapshots: [ListParagraphSnapshot],
        inverse: [ListParagraphSnapshot],
        actionName: String
    ) {
        registerUndoAction(name: actionName) { tv in
            tv.restoreListParagraphSnapshots(inverse, inverse: snapshots, actionName: actionName)
        }
        applyListParagraphSnapshots(snapshots)
    }

    private func applyListParagraphSnapshots(_ snapshots: [ListParagraphSnapshot]) {
        guard let bridge = loroBridge else { return }
        let preservedSelection = selectedRange()

        for snapshot in snapshots {
            let paragraphSelection = NSRange(location: snapshot.anchor, length: 0)
            let contentRange = paragraphContentRange(in: paragraphSelection)
            let fullRange = paragraphRangeIncludingTrailingNewline(in: paragraphSelection)
            if fullRange.length > 0 {
                bridge.removeMark(key: LoroMarkKey.list, utf16Range: fullRange)
            }
            if let style = snapshot.style, contentRange.length > 0 {
                bridge.applyMark(
                    key: LoroMarkKey.list,
                    valueJson: style.valueJson,
                    utf16Range: contentRange
                )
            }
        }

        setSelectedRange(preservedSelection)
        refreshTypingAttributesFromSelectionContext()
    }

    fileprivate func registerMarkdownShortcutUndo(token: String, blockStyle: PendingBlockStyle) {
        registerUndoAction(name: "Markdown Shortcut") { tv in
            tv.restoreMarkdownShortcutLiteral(token: token, blockStyle: blockStyle)
        }
    }

    private func restoreMarkdownShortcutLiteral(token: String, blockStyle: PendingBlockStyle) {
        registerUndoAction(name: "Markdown Shortcut") { tv in
            tv.reapplyMarkdownShortcutFormatting(token: token, blockStyle: blockStyle)
        }

        let anchor = min(blockStyle.anchor, (string as NSString).length)
        let paragraphSelection = NSRange(location: anchor, length: 0)
        let fullRange = paragraphRangeIncludingTrailingNewline(in: paragraphSelection)
        if let bridge = loroBridge, fullRange.length > 0 {
            bridge.removeMark(key: LoroMarkKey.heading, utf16Range: fullRange)
            bridge.removeMark(key: LoroMarkKey.list, utf16Range: fullRange)
        }

        clearPendingBlockStyle(syncTypingAttributes: false)
        typingAttributes = bodyTypingAttributes(from: typingAttributes)

        textStorage?.replaceCharacters(
            in: NSRange(location: anchor, length: 0),
            with: token
        )
        let offset = (token as NSString).length
        setSelectedRange(NSRange(location: anchor + offset, length: 0))
        publishFormattingState()
    }

    private func reapplyMarkdownShortcutFormatting(token: String, blockStyle: PendingBlockStyle) {
        registerUndoAction(name: "Markdown Shortcut") { tv in
            tv.restoreMarkdownShortcutLiteral(token: token, blockStyle: blockStyle)
        }

        let ns = string as NSString
        let anchor = min(blockStyle.anchor, ns.length)
        let tokenLength = (token as NSString).length
        if ns.length >= anchor + tokenLength,
           ns.substring(with: NSRange(location: anchor, length: tokenLength)) == token {
            textStorage?.replaceCharacters(
                in: NSRange(location: anchor, length: tokenLength),
                with: ""
            )
        }

        setSelectedRange(NSRange(location: anchor, length: 0))
        let contentRange = paragraphContentRange(in: selectedRange())
        guard let bridge = loroBridge else { return }

        if contentRange.length == 0 {
            setPendingBlockStyle(
                blockStyle,
                markdownPrefix: token.trimmingCharacters(in: .whitespaces)
            )
            return
        }

        let fullRange = paragraphRangeIncludingTrailingNewline(in: selectedRange())
        bridge.removeMark(key: LoroMarkKey.heading, utf16Range: fullRange)
        bridge.removeMark(key: LoroMarkKey.list, utf16Range: fullRange)

        switch blockStyle {
        case .heading(let level, _):
            bridge.applyMark(
                key: LoroMarkKey.heading,
                valueJson: LoroMarkValue.int(level),
                utf16Range: contentRange
            )
        case .list(_, _, _):
            if let listStyle = blockStyle.listStyle {
                bridge.applyMark(
                    key: LoroMarkKey.list,
                    valueJson: listStyle.valueJson,
                    utf16Range: contentRange
                )
            }
        }

        clearPendingBlockStyle(syncTypingAttributes: false)
        typingAttributes = blockTypingAttributes(from: typingAttributes, blockStyle: blockStyle)
        publishFormattingState()
    }

    private func registerUndoAction(
        name: String,
        _ action: @escaping (LoroBackedTextView) -> Void
    ) {
        undoManager?.registerUndo(withTarget: self, handler: action)
        undoManager?.setActionName(name)
    }

    /// 返回当前段落的"内容 range"(去掉尾部 \n),用于段落级 mark 避免扩散到下一行。
    func paragraphContentRange(in selection: NSRange) -> NSRange {
        let ns = string as NSString
        guard ns.length > 0 else { return NSRange(location: 0, length: 0) }
        let safeLocation = min(selection.location, max(ns.length - 1, 0))
        return paragraphContentRange(
            for: ns.paragraphRange(for: NSRange(location: safeLocation, length: selection.length)),
            text: ns
        )
    }

    func paragraphRangeIncludingTrailingNewline(in selection: NSRange) -> NSRange {
        let ns = string as NSString
        guard ns.length > 0 else { return NSRange(location: 0, length: 0) }
        let safeLocation = min(selection.location, max(ns.length - 1, 0))
        return ns.paragraphRange(for: NSRange(location: safeLocation, length: selection.length))
    }

    private func paragraphContentRange(for paragraphRange: NSRange, text: NSString) -> NSRange {
        var contentRange = paragraphRange
        if contentRange.length > 0 {
            let last = contentRange.location + contentRange.length - 1
            if text.character(at: last) == 10 /* \n */ {
                contentRange.length -= 1
            }
        }
        return contentRange
    }

    fileprivate func setPendingBlockStyle(_ style: PendingBlockStyle) {
        setPendingBlockStyle(style, markdownPrefix: nil)
    }

    fileprivate func setPendingBlockStyle(_ style: PendingBlockStyle, markdownPrefix: String?) {
        pendingBlockStyle = style
        pendingMarkdownPrefix = markdownPrefix
        typingAttributes = blockTypingAttributes(from: typingAttributes, blockStyle: style)
        publishFormattingState()
    }

    fileprivate func clearPendingBlockStyle(syncTypingAttributes: Bool) {
        pendingBlockStyle = nil
        pendingMarkdownPrefix = nil
        if syncTypingAttributes {
            refreshTypingAttributesFromSelectionContext()
        } else {
            publishFormattingState()
        }
    }

    fileprivate func currentFormattingState() -> EditorFormattingState {
        if let pendingBlockStyle, selectedRange().length == 0 {
            let attrs = normalizedTypingAttributes(typingAttributes)
            let block: (heading: Int?, list: String?, listDepth: Int?) = {
                switch pendingBlockStyle {
                case .heading(let level, _):
                    return (level, nil, nil)
                case .list(let kind, let depth, _):
                    return (nil, kind, depth)
                }
            }()
            return EditorFormattingState(
                isBold: isBold(in: attrs),
                isItalic: isItalic(in: attrs),
                isCode: isCode(in: attrs),
                isStrike: isStruck(in: attrs),
                headingLevel: block.heading,
                listKind: block.list,
                listDepth: block.listDepth,
                isPendingBlock: true
            )
        }

        if selectedRange().length > 0, let storage = textStorage {
            let range = selectedRange()
            let selectionAttrs = storage.attributedSubstring(from: range)
            let listStyle = paragraphListStyle(in: paragraphContentRange(in: range))
            return EditorFormattingState(
                isBold: selectionAttrs.hasMark(key: LoroMarkKey.bold),
                isItalic: selectionAttrs.hasMark(key: LoroMarkKey.italic),
                isCode: selectionAttrs.hasMark(key: LoroMarkKey.code),
                isStrike: selectionAttrs.hasMark(key: LoroMarkKey.strikethrough),
                headingLevel: paragraphHeadingLevel(paragraphContentRange(in: range)),
                listKind: listStyle?.kind,
                listDepth: listStyle?.depth
            )
        }

        let attrs = normalizedTypingAttributes(typingAttributes)
        let listStyle = listStyle(in: attrs)
        return EditorFormattingState(
            isBold: isBold(in: attrs),
            isItalic: isItalic(in: attrs),
            isCode: isCode(in: attrs),
            isStrike: isStruck(in: attrs),
            headingLevel: headingLevel(in: attrs),
            listKind: listStyle?.kind,
            listDepth: listStyle?.depth
        )
    }

    private func paragraphHeadingLevel(_ range: NSRange) -> Int? {
        guard range.length > 0, let storage = textStorage else { return nil }
        var level: Int?
        var consistent = true
        storage.enumerateAttribute(.font, in: range, options: []) { value, _, stop in
            guard let font = value as? NSFont else {
                consistent = false
                stop.pointee = true
                return
            }
            let detected = Self.headingLevel(for: font.pointSize)
            if level == nil {
                level = detected
            } else if level != detected {
                consistent = false
                stop.pointee = true
            }
        }
        return consistent ? level : nil
    }

    private func paragraphListStyle(in range: NSRange) -> LoroListStyle? {
        guard let storage = textStorage else { return nil }
        let probeRange = range.length > 0 ? range : paragraphRangeIncludingTrailingNewline(in: selectedRange())
        guard probeRange.length > 0 else { return listStyle(in: typingAttributes) }
        return listStyle(in: storage.attributes(at: probeRange.location, effectiveRange: nil))
    }

    private func normalizedTypingAttributes(_ attrs: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        var normalized = attrs
        if normalized[.font] == nil {
            normalized[.font] = NSFont.systemFont(ofSize: renderStyle.baseFontSize)
        }
        if normalized[.paragraphStyle] == nil {
            normalized[.paragraphStyle] = renderStyle.paragraphStyle()
        }
        if !isCode(in: normalized) {
            normalized[.foregroundColor] = renderStyle.textColor
            normalized.removeValue(forKey: .backgroundColor)
        }
        return normalized
    }

    private func baseTypingAttributes() -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: renderStyle.baseFontSize),
            .foregroundColor: renderStyle.textColor,
            .paragraphStyle: renderStyle.paragraphStyle(),
        ]
    }

    fileprivate func bodyTypingAttributes(from attrs: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        let flags = inlineFlags(in: attrs)
        return typingAttributesFromComponents(
            pointSize: renderStyle.baseFontSize,
            isBold: flags.bold,
            isItalic: flags.italic,
            isCode: flags.code,
            isStrike: flags.strike,
            listStyle: nil
        )
    }

    fileprivate func blockTypingAttributes(
        from attrs: [NSAttributedString.Key: Any],
        blockStyle: PendingBlockStyle
    ) -> [NSAttributedString.Key: Any] {
        let flags = inlineFlags(in: attrs)
        let pointSize: CGFloat = {
            switch blockStyle {
            case .heading(let level, _):
                return renderStyle.headingFontSize(level)
            case .list:
                return renderStyle.baseFontSize
            }
        }()
        return typingAttributesFromComponents(
            pointSize: pointSize,
            isBold: flags.bold,
            isItalic: flags.italic,
            isCode: flags.code,
            isStrike: flags.strike,
            listStyle: blockStyle.listStyle
        )
    }

    private func typingAttributesByTogglingInlineMark(
        key: String,
        enabled: Bool,
        attrs: [NSAttributedString.Key: Any]
    ) -> [NSAttributedString.Key: Any] {
        let flags = inlineFlags(in: attrs)
        let pointSize = (attrs[.font] as? NSFont)?.pointSize ?? renderStyle.baseFontSize
        let nextBold = (key == LoroMarkKey.bold) ? enabled : flags.bold
        let nextItalic = (key == LoroMarkKey.italic) ? enabled : flags.italic
        let nextCode = (key == LoroMarkKey.code) ? enabled : flags.code
        let nextStrike = (key == LoroMarkKey.strikethrough) ? enabled : flags.strike
        return typingAttributesFromComponents(
            pointSize: pointSize,
            isBold: nextBold,
            isItalic: nextItalic,
            isCode: nextCode,
            isStrike: nextStrike,
            listStyle: listStyle(in: attrs)
        )
    }

    private func typingAttributesFromComponents(
        pointSize: CGFloat,
        isBold: Bool,
        isItalic: Bool,
        isCode: Bool,
        isStrike: Bool,
        listStyle: LoroListStyle?
    ) -> [NSAttributedString.Key: Any] {
        let headingLevel = Self.headingLevel(for: pointSize)
        var attrs: [NSAttributedString.Key: Any] = [
            .font: Self.makeFont(
                pointSize: pointSize,
                isBold: isBold,
                isItalic: isItalic,
                isCode: isCode
            ),
            .foregroundColor: isCode ? renderStyle.codeForeground : renderStyle.textColor,
            .paragraphStyle: renderStyle.paragraphStyle(
                headingLevel: headingLevel,
                listStyle: listStyle
            ),
        ]
        if isCode {
            attrs[.backgroundColor] = renderStyle.codeBackground
        }
        if isStrike {
            attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        if let listStyle {
            attrs[.zulangueListKind] = listStyle.kind
            attrs[.zulangueListDepth] = NSNumber(value: listStyle.depth)
        }
        return attrs
    }

    private func inlineFlags(in attrs: [NSAttributedString.Key: Any]) -> (bold: Bool, italic: Bool, code: Bool, strike: Bool) {
        (
            bold: isBold(in: attrs),
            italic: isItalic(in: attrs),
            code: isCode(in: attrs),
            strike: isStruck(in: attrs)
        )
    }

    private func isBold(in attrs: [NSAttributedString.Key: Any]) -> Bool {
        guard let font = attrs[.font] as? NSFont else { return false }
        return font.fontDescriptor.symbolicTraits.contains(.bold)
    }

    private func isItalic(in attrs: [NSAttributedString.Key: Any]) -> Bool {
        guard let font = attrs[.font] as? NSFont else { return false }
        return font.fontDescriptor.symbolicTraits.contains(.italic)
    }

    private func isCode(in attrs: [NSAttributedString.Key: Any]) -> Bool {
        guard let font = attrs[.font] as? NSFont else { return false }
        return font.fontDescriptor.symbolicTraits.contains(.monoSpace)
    }

    private func isStruck(in attrs: [NSAttributedString.Key: Any]) -> Bool {
        if let strike = attrs[.strikethroughStyle] as? NSNumber {
            return strike.intValue != 0
        }
        if let strike = attrs[.strikethroughStyle] as? Int {
            return strike != 0
        }
        return false
    }

    private func headingLevel(in attrs: [NSAttributedString.Key: Any]) -> Int? {
        guard let font = attrs[.font] as? NSFont else { return nil }
        return Self.headingLevel(for: font.pointSize)
    }

    private func listStyle(in attrs: [NSAttributedString.Key: Any]) -> LoroListStyle? {
        LoroListStyle.fromAttributes(attrs)
    }

    private static func headingLevel(for pointSize: CGFloat) -> Int? {
        if pointSize >= 21 { return 1 }
        if pointSize >= 17 { return 2 }
        if pointSize >= 15 { return 3 }
        return nil
    }

    private static func makeFont(
        pointSize: CGFloat,
        isBold: Bool,
        isItalic: Bool,
        isCode: Bool
    ) -> NSFont {
        let weight: NSFont.Weight = isBold ? .semibold : .regular
        var font = isCode
            ? NSFont.monospacedSystemFont(ofSize: pointSize, weight: weight)
            : NSFont.systemFont(ofSize: pointSize, weight: weight)
        if isItalic {
            let desc = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.italic))
            if let italicFont = NSFont(descriptor: desc, size: pointSize) {
                font = italicFont
            }
        }
        return font
    }

}

// MARK: - NSTextView wrapping

private struct DocumentTextView: NSViewRepresentable {
    let notebookId: String
    let tabId: String
    let isEditable: Bool
    @Binding var bridge: LoroTextBridge?
    @Binding var textView: NSTextView?
    @Binding var selection: NSRange
    @Binding var formattingState: EditorFormattingState
    @Binding var bridgeError: String?
    var onTextActivity: (() -> Void)? = nil
    var onViewportChanged: (() -> Void)? = nil

    func makeNSView(context: Context) -> NSScrollView {
        // 用自定义 NSTextView 子类(LoroBackedTextView),从头手动搭 scroll view
        // 因为 NSTextView.scrollableTextView() 只给默认 NSTextView,不给子类。
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.contentView.postsBoundsChangedNotifications = true

        let contentSize = scrollView.contentSize
        let textContainer = NSTextContainer(
            size: NSSize(width: contentSize.width, height: .greatestFiniteMagnitude)
        )
        textContainer.widthTracksTextView = true
        textContainer.containerSize = NSSize(
            width: contentSize.width,
            height: .greatestFiniteMagnitude
        )
        textContainer.lineFragmentPadding = 0

        let layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(textContainer)

        let textStorage = NSTextStorage()
        textStorage.addLayoutManager(layoutManager)

        let tv = LoroBackedTextView(frame: .zero, textContainer: textContainer)
        tv.autoresizingMask = [.width]
        tv.minSize = NSSize(width: 0, height: contentSize.height)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false

        // 使用系统动态颜色，确保 NSViewRepresentable 在深浅模式下正确解析。
        tv.backgroundColor = .textBackgroundColor
        tv.drawsBackground = true
        tv.textColor = .labelColor
        tv.insertionPointColor = NSColor(Color.brandAccent)
        tv.selectedTextAttributes = [
            .backgroundColor: NSColor(Color.brandAccent.opacity(0.3)),
            .foregroundColor: NSColor.labelColor,
        ]

        // 编辑行为
        tv.isRichText = true
        tv.isEditable = isEditable
        tv.allowsUndo = true
        tv.importsGraphics = false
        tv.usesFindBar = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false

        // 排版
        tv.updateReadableLayout()

        // ⚠️ 不要设 tv.font = ...
        // Apple 文档:rich-text 模式下,设置 tv.font 会**覆盖所有现有字符**的 font
        // (包括我们 setAttributedString 后的 per-char font)。只靠 typingAttributes
        // 控制"新输入字符的默认 font"。
        tv.typingAttributes = [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.labelColor, // dynamic,跟随 dark/light
            .paragraphStyle: LoroRenderStyle.default.paragraphStyle(),
        ]

        tv.delegate = context.coordinator
        scrollView.documentView = tv
        context.coordinator.installViewportObservation(on: scrollView.contentView)

        // bridge 在 updateNSView 中按文档变化 attach/disconnect，以复用
        // NSTextView 并保留光标、滚动位置和 IME 状态。
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let tv = nsView.documentView as? LoroBackedTextView else { return }
        let coord = context.coordinator

        // Visibility alone does not revoke AppKit first responder status. Apply
        // editability before the same-document fast path so a hidden transcript
        // editor cannot accept keystrokes while Settings is selected.
        tv.isEditable = isEditable
        if isEditable == false, tv.window?.firstResponder === tv {
            tv.window?.makeFirstResponder(nil)
        }

        tv.formattingStateDidChange = { newState in
            DispatchQueue.main.async {
                self.formattingState = newState
            }
        }

        // Rust resolves the actual doc id. Swift tracks only the authorized
        // Notebook/tab identity at this boundary.
        let targetDocumentKey = "\(notebookId):\(tabId)"
        if coord.mountedDocId == targetDocumentKey { return }

        // 同步断开旧 bridge，确保 delegate 与 Rust session 在新 bridge
        // attach 前完成清理。
        if let oldBridge = tv.loroBridge {
            tv.loroBridge = nil
            oldBridge.disconnect()
        }
        // 旧 doc 的 transient editor state 不应带到新 doc。
        tv.resetTransientEditorState()

        // 先占位:哪怕 attach 还没落地,也认为这个 tv "承诺"挂到 targetSessionId。
        // 紧接着 SwiftUI 重绘又带同样 sessionId 进来时 early-return,不会重复入队。
        let targetDocumentKeyForAttach = targetDocumentKey
        coord.mountedDocId = targetDocumentKeyForAttach

        // 同步 attach 以确保 delegate 在用户输入前就位。Binding 赋值延迟到
        // 下一个主线程 tick，避免在 view update 期间修改 SwiftUI state。
        let attachResult: Result<LoroTextBridge, Error>
        do {
            let b = try LoroTextBridge.attach(
                notebookId: notebookId,
                tabId: tabId,
                textView: tv
            )
            tv.loroBridge = b  // 非 @Binding,同步写安全
            attachResult = .success(b)
        } catch {
            coord.mountedDocId = nil
            attachResult = .failure(error)
        }

        DispatchQueue.main.async {
            // 中间切到别的 doc → 本次结果过时,不更新 @Binding
            // (同步 attach 上来的 tv.loroBridge 会被下一次 updateNSView 的
            //  oldBridge.disconnect() 清理,不会泄漏)
            guard coord.mountedDocId == targetDocumentKeyForAttach else { return }
            switch attachResult {
            case .success(let b):
                self.bridge = b
                self.textView = tv
                self.bridgeError = nil
                tv.publishFormattingState()
                self.onViewportChanged?()
            case .failure(let err):
                self.bridgeError = String(describing: err)
            }
        }
    }

    /// SwiftUI 销毁 NSViewRepresentable 时同步断开 bridge，避免延迟清理误关
    /// 同一文档刚建立的 Rust editor session。
    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        guard let tv = nsView.documentView as? LoroBackedTextView else { return }
        let bridge = tv.loroBridge
        tv.loroBridge = nil
        coordinator.mountedDocId = nil
        tv.resetTransientEditorState()
        MainActor.assumeIsolated {
            bridge?.disconnect()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let parent: DocumentTextView
        private var viewportObserver: NSObjectProtocol?

        /// 当前 NSTextView 已 attach 的 docId。updateNSView 用它
        /// 判断是否需要切换 bridge。nil 表示还没 attach 或刚被 disconnect。
        var mountedDocId: String?

        init(_ parent: DocumentTextView) {
            self.parent = parent
        }

        deinit {
            if let viewportObserver {
                NotificationCenter.default.removeObserver(viewportObserver)
            }
        }

        func installViewportObservation(on clipView: NSClipView) {
            if let viewportObserver {
                NotificationCenter.default.removeObserver(viewportObserver)
            }
            viewportObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: clipView,
                queue: .main
            ) { [weak self] _ in
                self?.parent.onViewportChanged?()
            }
        }

        // MARK: Selection

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? LoroBackedTextView else { return }
            let range = tv.selectedRange()
            tv.syncPendingBlockStyleForSelectionIfNeeded()
            tv.refreshTypingAttributesFromSelectionContext()
            DispatchQueue.main.async {
                self.parent.selection = range
            }
        }

        // MARK: Markdown shortcuts

        /// 行首 `# ` / `## ` / `### ` / `- ` / `1. ` + 空格 → 触发对应段落 mark。
        /// 空格被吃掉,prefix 被删掉,pending mark 留到下次 textDidChange 执行。
        func textView(
            _ textView: NSTextView,
            shouldChangeTextIn affectedRange: NSRange,
            replacementString: String?
        ) -> Bool {
            guard let tv = textView as? LoroBackedTextView else { return true }
            // Final-2:Enter 插入 \n 后需要断开段落级 mark 的扩散。
            // 记录插入位置,让 textDidChange 完成 unmark。
            if replacementString == "\n", affectedRange.length == 0 {
                let currentParagraph = tv.paragraphContentRange(in: tv.selectedRange())
                let paragraphText = (tv.string as NSString).substring(with: currentParagraph)
                let currentState = tv.currentFormattingState()
                let currentListStyle = currentState.listKind.map {
                    LoroListStyle(kind: $0, depth: currentState.listDepth ?? LoroListStyle.minDepth)
                }
                let currentHeading = currentState.headingLevel

                if currentParagraph.length == 0, currentHeading != nil, currentListStyle == nil {
                    tv.clearPendingBlockStyle(syncTypingAttributes: false)
                    tv.typingAttributes = tv.bodyTypingAttributes(from: tv.typingAttributes)
                    tv.publishFormattingState()
                    return true
                }

                if currentParagraph.length == 0, currentListStyle != nil, let bridge = parent.bridge {
                    bridge.removeMark(
                        key: LoroMarkKey.list,
                        utf16Range: tv.paragraphRangeIncludingTrailingNewline(in: tv.selectedRange())
                    )
                    tv.clearPendingBlockStyle(syncTypingAttributes: false)
                    tv.typingAttributes = tv.bodyTypingAttributes(from: tv.typingAttributes)
                    tv.publishFormattingState()
                    return true
                }

                tv.pendingNewlineUnmark = affectedRange.location
                if let currentListStyle, !paragraphText.isEmpty {
                    tv.setPendingBlockStyle(
                        .list(
                            kind: currentListStyle.kind,
                            depth: currentListStyle.depth,
                            anchor: affectedRange.location + 1
                        )
                    )
                }
                return true
            }

            guard replacementString == " ",
                  affectedRange.length == 0,
                  parent.bridge != nil
            else { return true }

            let str = textView.string as NSString
            let pos = affectedRange.location

            // 找当前行起点
            var lineStart = pos
            while lineStart > 0 && str.character(at: lineStart - 1) != 10 /* \n */ {
                lineStart -= 1
            }

            let prefixLen = pos - lineStart
            guard prefixLen > 0, prefixLen <= 3 else { return true }
            let prefix = str.substring(with: NSRange(location: lineStart, length: prefixLen))

            let blockStyle: LoroBackedTextView.PendingBlockStyle? = {
                switch prefix {
                case "#":   return .heading(level: 1, anchor: lineStart)
                case "##":  return .heading(level: 2, anchor: lineStart)
                case "###": return .heading(level: 3, anchor: lineStart)
                case "-":   return .list(kind: "bullet", depth: LoroListStyle.minDepth, anchor: lineStart)
                case "*":   return .list(kind: "bullet", depth: LoroListStyle.minDepth, anchor: lineStart)
                case "1.":  return .list(kind: "ordered", depth: LoroListStyle.minDepth, anchor: lineStart)
                default:    return nil
                }
            }()
            guard let blockStyle else { return true }

            // 删除 prefix(空格还没插,return false 吃掉)
            textView.textStorage?.replaceCharacters(
                in: NSRange(location: lineStart, length: prefixLen),
                with: ""
            )
            textView.setSelectedRange(NSRange(location: lineStart, length: 0))
            tv.setPendingBlockStyle(blockStyle, markdownPrefix: prefix)
            tv.registerMarkdownShortcutUndo(token: "\(prefix) ", blockStyle: blockStyle)

            switch blockStyle {
            case .heading(let level, _):
                DebugLog.info("# → H\(level)", detail: "type content")
            case .list(let kind, let depth, _):
                DebugLog.info("\(prefix) → \(kind) list", detail: "depth \(depth)")
            }

            return false
        }

        /// 用户输入后兑现 pendingMark。先清 pending 再调 applyMark,防重入。
        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? LoroBackedTextView else { return }
            parent.onTextActivity?()
            parent.onViewportChanged?()

            // Final-2:先消化 Enter 后的 unmark(保证新段落不继承 heading/list)
            let handledNewlineBreak = (tv.pendingNewlineUnmark != nil)
            if let nlPos = tv.pendingNewlineUnmark,
               let bridge = parent.bridge {
                tv.pendingNewlineUnmark = nil
                let nlRange = NSRange(location: nlPos, length: 1)
                // 两个 key 都尝试 unmark — 无 mark 的情况 Rust 侧等价 no-op
                bridge.removeMark(key: LoroMarkKey.heading, utf16Range: nlRange)
                bridge.removeMark(key: LoroMarkKey.list, utf16Range: nlRange)
            }

            guard let pending = tv.pendingBlockStyle,
                  let bridge = parent.bridge
            else {
                if handledNewlineBreak {
                    tv.typingAttributes = tv.bodyTypingAttributes(from: tv.typingAttributes)
                    tv.publishFormattingState()
                } else {
                    tv.publishFormattingState()
                }
                return
            }

            let ns = tv.string as NSString
            let sel = tv.selectedRange()
            var para = ns.paragraphRange(for: sel)
            if para.length > 0 {
                let last = para.location + para.length - 1
                if ns.character(at: last) == 10 /* \n */ {
                    para.length -= 1
                }
            }
            guard para.length > 0 else {
                tv.publishFormattingState()
                return
            }

            tv.clearPendingBlockStyle(syncTypingAttributes: false)
            switch pending {
            case .heading(let level, _):
                bridge.applyMark(
                    key: LoroMarkKey.heading,
                    valueJson: LoroMarkValue.int(level),
                    utf16Range: para
                )
                DebugLog.info("H\(level) applied", detail: "range \(para.location)..\(para.location + para.length)")
            case .list(let kind, let depth, _):
                bridge.applyMark(
                    key: LoroMarkKey.list,
                    valueJson: LoroListStyle(kind: kind, depth: depth).valueJson,
                    utf16Range: para
                )
                DebugLog.info(
                    "\(kind) list applied",
                    detail: "depth \(depth) · range \(para.location)..\(para.location + para.length)"
                )
            }
            if handledNewlineBreak {
                tv.refreshTypingAttributesFromSelectionContext()
            } else {
                tv.publishFormattingState()
            }
        }
    }
}

// NOTE: preview block removed after a parsing-state bug caused by another part
// of the file (resolved by the wider refactor). If needed, re-add with #if DEBUG
// once file is known-good.
