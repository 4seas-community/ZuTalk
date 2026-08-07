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

    @State private var activeSidePanel: DocumentEditorSidePanel?
    @State private var isShowingExportSheet = false
    @State private var presentedCaptureSettingsNotebookId: String?
    @State private var isShowingResources = false

    /// Notebook-scoped unified tab surface, including realtime transcript.
    @State private var notebookTabs: [NotebookTabViewModel] = []
    @State private var editorNotebook: FfiNotebook?
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
        case .asyncPending:
            PendingDocumentState()

        case .asyncFailed:
            FailedDocumentState(errorMessage: selectedTranscriptionTask?.errorMessage)

        case .manualNote:
            // 大纲编辑器自管 open/close 与加载失败态(EmptyState + 重试)。
            BlockNoteEditorView(notebookId: notebookId, tabId: tabId)
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
            isShowingResources: isShowingResources
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
        // 覆盖层出现前收回键盘焦点,行内 TextField 不得在被盖住时继续吃键击。
        NSApp.keyWindow?.makeFirstResponder(nil)
        isShowingResources = false
        presentedCaptureSettingsNotebookId = notebookId
    }

    private func showResources() {
        activeSidePanel = nil
        NSApp.keyWindow?.makeFirstResponder(nil)
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
    @ObservedObject private var communityInvite = CommunityInviteSession.shared
    // Observed for statusRevision so the key-required gate below reacts when
    // the user saves or removes their own key in Settings.
    @ObservedObject private var providerCredentials = ProviderCredentialSession.shared
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
                if communityInvite.asyncTranscriptionNeedsPersonalKey {
                    // Invite time covers realtime only; the upload-based
                    // after-stop pass stays off until the user brings their
                    // own key, so recordings never leave the Mac unrequested.
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
                    .help(String(localized: "editor.transcript.async.invite_add_key_hint"))
                    .accessibilityHint(Text(String(
                        localized: "editor.transcript.async.invite_add_key_hint"
                    )))
                } else {
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
