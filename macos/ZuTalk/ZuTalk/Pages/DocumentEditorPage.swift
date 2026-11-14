// DocumentEditorPage.swift
// 笔记编辑器页面 — Notebook 文档表面的 UI 宿主
// 权威:design-system/MASTER.md §10 · D5 §7.5
//
// 架构:
//   DocumentEditorPage (SwiftUI 宿主)
//     ├── (位置与录音信息在主窗口顶栏的路径里,见 EditorBreadcrumb)
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

private struct NotebookRouteLoadSnapshot: Sendable {
    let notebookTabs: [NotebookTabViewModel]
    let notebook: FfiNotebook?
    let session: SessionInfo?
    /// Which transcripts the selected recording has: whether there is any
    /// text to copy, and whether there is a live version to go back to.
    let transcriptAvailability: SessionTranscriptAvailabilityInfo?
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
    /// 另一台 Mac 录的:音频在那台上,这里精修不了。带着那台的名字(可能为空)。
    case audioElsewhere(String)
}

enum AsyncTranscriptActionPolicy {
    static func isProviderPending(_ providerState: String?) -> Bool {
        guard let normalized = providerState?.lowercased() else { return false }
        return ["pending", "reserved", "enqueued"].contains(normalized)
    }

    static func primaryAction(
        projectionState: NotebookAsyncProjectionState?,
        providerState: String?,
        hasReadyPersonalKey: Bool,
        recordedOn: String? = nil
    ) -> AsyncTranscriptPrimaryAction {
        guard projectionState == NotebookAsyncProjectionState.none else { return .none }
        if let recordedOn {
            return .audioElsewhere(recordedOn)
        }
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

    @State private var isShowingExportSheet = false
    @State private var exportingSessionId: String?
    @State private var presentedCaptureSettingsNotebookId: String?
    @State private var isShowingResources: Bool
    @State private var sessionSupplementarySurface: SessionSupplementarySurface?
    @ObservedObject private var navigation = MainNavigationStore.shared
    /// 「分享」收件 Notebook 的判定源。观察它,id 迟到时页面能换对视图。

    /// The recording's ⋯ menu: one flag per question it asks.
    @State private var isRenamingRecording = false
    @State private var topicsForFiling: [TopicFilingChoice]?
    @State private var isConfirmingAudioDestroy = false
    @State private var isConfirmingRecordingDelete = false

    /// Notebook-scoped unified tab surface, including realtime transcript.
    @State private var notebookTabs: [NotebookTabViewModel] = []
    @State private var editorNotebook: FfiNotebook?
    @State private var editorSession: SessionInfo?
    @State private var transcriptAvailability: SessionTranscriptAvailabilityInfo?
    @State private var isQuickCaptureNotebook = false
    @State private var routeLoadError: String?
    @State private var routeLoadGeneration: UInt = 0
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
                DocumentTabBar(
                    tabs: notebookTabs,
                    activeTabId: activeNotebookTabId,
                    captureSettingsNotebookId: captureSettingsNotebookId,
                    isCaptureSettingsSelected: isShowingCaptureSettings,
                    isResourcesSelected: isShowingResources,
                    isTopicContext: isTopicContext,
                    sessionId: effectiveSessionId,
                    sessionSupplementarySurface: sessionSupplementarySurface,
                    hasLiveVersion: transcriptAvailability?.hasRealtimeContent ?? true,
                    onSelect: selectNotebookTab,
                    onSelectResources: showResources,
                    onSelectCaptureSettings: showCaptureSettings,
                    onSelectSessionNote: showSessionNote,
                    onSelectSessionSettings: showSessionSettings,
                    onCopyAll: copyWholeTranscript,
                    onExport: exportRecording,
                    onShare: shareRecordingAction,
                    onFile: fileRecordingAction,
                    onRename: { isRenamingRecording = true },
                    onFileIntoTopic: {
                        topicsForFiling = LibraryCommands.topicsForFiling(
                            excluding: route?.notebookID
                        )
                    },
                    onDestroyAudio: canDestroyAudio
                        ? { isConfirmingAudioDestroy = true }
                        : nil,
                    destroyAudioBlockedReason: destroyAudioBlockedReason,
                    onDeleteRecording: { isConfirmingRecordingDelete = true }
                )
                .audioDestroyConfirmation(
                    isPresented: $isConfirmingAudioDestroy,
                    recordingTitle: recordingDisplayTitle,
                    filedAudio: AudioDestroyQuestion.hasFiledAudio(sessionId: effectiveSessionId),
                    onConfirm: {
                        guard let sessionId = effectiveSessionId else { return }
                        SessionResourcesViewModel.destroyAudioAndAnnounce(sessionId: sessionId)
                    }
                )

                if routeLoadError != nil {
                    EditorRouteLoadWarning {
                        Task { await loadNotebookRoute() }
                    }
                }

                // The header above already names the topic and the
                // recording, with its time, length and languages; the tab
                // bar names the view. Each used to be repeated here — a
                // breadcrumb row, a large copy of the tab's name, and a row
                // with the length again.
                if isShowingCaptureSettings == false,
                   isShowingResources == false,
                   sessionSupplementarySurface == nil,
                   activeNotebookTab?.displayType == .manualNote {
                    TopicNotesContextHeader()
                }
            }

            // Stop lands here: the recording that just finished says so on
            // top of its own transcript, with what to do next.
            if docId != nil, let sessionId = effectiveSessionId {
                RecordingResultCardHost(
                    sessionId: sessionId,
                    isOnTranscript: surface.showsTranscriptLayer,
                    session: editorSession,
                    availability: transcriptAvailability,
                    refineTask: selectedTranscriptionTask?.tabStatus,
                    showingRefined: activeNotebookTab?.displayType == .asyncTranscript,
                    onFinished: showTranscriptOfFinishedRecording,
                    onCopy: copyWholeTranscript,
                    onExport: exportRecording,
                    onShare: shareRecordingAction,
                    onFile: fileRecordingAction,
                    onRefineStarted: refineDidStart,
                    onShowRefined: showRefinedTranscript
                )
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
                        isVisible: surface.showsTranscriptLayer
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
                    OneSentenceState(
                        systemImage: "waveform",
                        sentence: String(localized: "editor.empty.no_transcript_title"),
                        detail: String(localized: "editor.empty.no_transcript_desc")
                    )
                }

                if let notebookId = presentedCaptureSettingsNotebookId,
                   notebookId == captureSettingsNotebookId {
                    NotebookCaptureSettingsView(
                        notebookId: notebookId,
                        editor: captureProfileEditor,
                        scope: captureSettingsScope
                    )
                        .id(notebookId)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                if isShowingResources, let notebookId = route?.notebookID {
                    NotebookResourcesView(
                        notebookId: notebookId,
                        notebookTitle: editorNotebook?.title,
                        onStartCapture: startRecordingInTopic,
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
        .sheet(isPresented: $isRenamingRecording) {
            RenameSheet(
                title: String(localized: "recording.word.rename"),
                placeholder: String(localized: "library.rename.recording_placeholder"),
                initialText: editorSession?.title ?? "",
                allowsEmpty: true
            ) { title in
                guard let sessionId = effectiveSessionId else { return false }
                return LibraryCommands.renameRecording(id: sessionId, to: title)
            }
        }
        .sheet(isPresented: Binding(
            get: { topicsForFiling != nil },
            set: { if $0 == false { topicsForFiling = nil } }
        )) {
            FileIntoTopicSheet(
                topics: topicsForFiling ?? [],
                isInTopic: isQuickCaptureNotebook == false
            ) { choice, newTopicName in
                guard let sessionId = effectiveSessionId else { return false }
                return LibraryCommands.fileRecording(
                    id: sessionId,
                    into: choice,
                    newTopicName: newTopicName
                )
            }
        }
        // The trash can be restored from, but a click in a menu should still
        // say where the recording is going.
        .confirmationDialog(
            String(
                format: String(localized: "session.delete.confirm_title_format"),
                recordingDisplayTitle
            ),
            isPresented: $isConfirmingRecordingDelete,
            titleVisibility: .visible
        ) {
            Button(
                String(localized: "resources.delete.confirm_button"),
                role: .destructive,
                action: deleteRecording
            )
            Button(String(localized: "common.cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "session.delete.confirm_message"))
        }
        .task(id: routeTaskId) {
            await loadNotebookRoute()
        }
        .task(id: breadcrumb) {
            navigation.editorBreadcrumb = breadcrumb
        }
        .onDisappear {
            if navigation.editorBreadcrumb == breadcrumb {
                navigation.editorBreadcrumb = nil
            }
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
                // Once a second for as long as refining takes: the status is
                // what is being watched, so what the recording has is not
                // re-read until it changes hands.
                await loadNotebookRoute(rereadsAvailability: false)
                guard selectedTranscriptionTask?.tabStatus == .pending else {
                    await loadNotebookRoute()
                    return
                }
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
            applyPendingSessionSurface()
        }
        .onAppear(perform: applyPendingSessionSurface)
        .montereyOnChange(of: navigation.pendingSessionSurface) { _, _ in
            applyPendingSessionSurface()
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
            if docId != nil,
               let notebookId = route?.notebookID,
               let tabId = route?.tabID {
                VStack(spacing: 0) {
                    documentEditorContent(notebookId: notebookId, tabId: tabId)
                    NoteBottomSignature()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                OneSentenceState(
                    systemImage: "doc",
                    sentence: String(localized: "editor.empty.no_doc_title"),
                    detail: String(localized: "editor.empty.no_doc_desc")
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
                OneSentenceState(
                    systemImage: "exclamationmark.triangle",
                    sentence: String(localized: "session.settings.load_failed"),
                    tint: .signalAmber,
                    action: .init(
                        title: String(localized: "session.settings.retry"),
                        systemImage: "arrow.clockwise",
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
            OneSentenceState(
                systemImage: "waveform",
                sentence: String(localized: "editor.transcript.async.no_session_title"),
                detail: String(localized: "editor.transcript.async.no_session_desc"),
                action: .init(
                    title: String(localized: "resources.tab"),
                    systemImage: "list.bullet.rectangle",
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
            OneSentenceState(
                systemImage: "doc",
                sentence: String(localized: "editor.empty.no_doc_title"),
                detail: String(localized: "editor.empty.no_doc_desc")
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

    /// Sharing a finished recording, from ⋯. One still being recorded is
    /// shared live from the recording bar instead.
    private var shareRecordingAction: (() -> Void)? {
        guard let sessionId = effectiveSessionId else { return nil }
        let capture = ActiveBilingualTranscriptStore.shared
        if capture.isCaptureActive, capture.sessionId == sessionId { return nil }
        let label = navigation.editorBreadcrumb?.recording?.label ?? ""
        return { ShareActivityStore.shared.presentRecordingShare(sessionId: sessionId, title: label) }
    }

    /// Filing a finished recording to a city event: the card's pill, the
    /// tab bar's, and ⋯ all open the one archive sheet. Nil while the
    /// recording is still being made.
    private var fileRecordingAction: (() -> Void)? {
        guard let sessionId = effectiveSessionId else { return nil }
        let capture = ActiveBilingualTranscriptStore.shared
        if capture.isCaptureActive, capture.sessionId == sessionId { return nil }
        let label = navigation.editorBreadcrumb?.recording?.label ?? ""
        return { ShareActivityStore.shared.presentCityFiling(sessionId: sessionId, title: label) }
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

    /// This page's place, for the header: see `EditorBreadcrumb`.
    private var breadcrumb: EditorBreadcrumb? {
        guard docId != nil else { return nil }
        var recording: EditorBreadcrumb.Recording?
        if let session = chromeSession {
            let started = Date(timeIntervalSince1970: TimeInterval(session.createdAtUnixMs) / 1_000)
                .formatted(date: .abbreviated, time: .shortened)
            let title = RecordingPresentation.title(session.title)
            let details = [
                title == nil ? nil : started,
                RecordingPresentation.duration(ms: session.durationMs),
                RecordingPresentation.languageList([session.sourceLanguage] + session.targetLanguages),
            ]
            .compactMap { $0 }
            .filter { $0.isEmpty == false }
            let status: RecordingPresentation.Status?
            switch session.status.lowercased() {
            case "recording": status = .recording
            case "interrupted": status = .interrupted
            case "failed": status = .failed
            default: status = nil
            }
            recording = EditorBreadcrumb.Recording(
                sessionID: session.id,
                storedTitle: session.title,
                label: title ?? started,
                detail: details.isEmpty ? nil : details.joined(separator: " · "),
                status: status
            )
        }
        return EditorBreadcrumb(
            topicID: route?.notebookID,
            topicTitle: isQuickCaptureNotebook ? nil : editorNotebook?.title,
            recording: recording
        )
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

    /// - Parameter rereadsAvailability: false to keep what is already known
    ///   about this same recording's transcripts — reading it walks every
    ///   line of the recording.
    @MainActor
    private func loadNotebookRoute(rereadsAvailability: Bool = true) async {
        routeLoadGeneration &+= 1
        let generation = routeLoadGeneration
        guard let requestedRoute = route else {
            notebookTabs = []
            editorNotebook = nil
            editorSession = nil
            transcriptAvailability = nil
            isQuickCaptureNotebook = false
            transcriptionTasksBySessionId = [:]
            routeLoadError = nil
            return
        }
        guard let core = CoreClient.shared.core else {
            notebookTabs = []
            editorNotebook = nil
            editorSession = nil
            transcriptAvailability = nil
            isQuickCaptureNotebook = false
            transcriptionTasksBySessionId = [:]
            routeLoadError = String(localized: "editor.route.load_failed")
            return
        }

        let knownAvailability = rereadsAvailability == false
            && editorSession?.id == requestedRoute.selectedSessionID
            ? transcriptAvailability
            : nil
        let activeCapture = ActiveBilingualTranscriptStore.shared
        let activeCaptureNotebookId = activeCapture.notebookId
        let activeCaptureSessionId = activeCapture.sessionId
        // Nothing on the page asks what a recording has while it is still
        // being made, and the answer would be stale by the next sentence.
        let recordingThisSession = activeCapture.isCaptureActive
            && activeCaptureSessionId == requestedRoute.selectedSessionID
        let quickCaptureDisplayTitle = String(localized: "sidebar.home")
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
                }
                let loadedSession: SessionInfo?
                let loadedAvailability: SessionTranscriptAvailabilityInfo?
                if let sessionId = requestedRoute.selectedSessionID {
                    // A selected Session is part of route identity. Failure
                    // must surface instead of silently showing the Topic name.
                    loadedSession = try core.getSession(id: sessionId)
                    // Advisory: without it the page assumes the usual case
                    // (there is text, and there was a live version).
                    loadedAvailability = recordingThisSession
                        ? nil
                        : knownAvailability
                            ?? (try? core.getSessionTranscriptAvailability(sessionId: sessionId))
                } else {
                    loadedSession = nil
                    loadedAvailability = nil
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
                        transcriptAvailability: loadedAvailability,
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
            transcriptAvailability = snapshot.transcriptAvailability
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
        // 覆盖层出现前收回键盘焦点,行内 TextField 不得在被盖住时继续吃键击。
        NSApp.keyWindow?.makeFirstResponder(nil)
        isShowingResources = false
        sessionSupplementarySurface = nil
        presentedCaptureSettingsNotebookId = notebookId
    }

    private func showResources() {
        NSApp.keyWindow?.makeFirstResponder(nil)
        presentedCaptureSettingsNotebookId = nil
        sessionSupplementarySurface = nil
        showTranscript = false
        isShowingResources = true
    }

    /// A list row asked for this recording's notes or files rather than its
    /// transcript.
    private func applyPendingSessionSurface() {
        guard let surface = navigation.pendingSessionSurface,
              effectiveSessionId != nil
        else { return }
        navigation.pendingSessionSurface = nil
        switch surface {
        case .note: showSessionNote()
        case .settings: showSessionSettings()
        }
    }

    private func showSessionNote() {
        guard effectiveSessionId != nil else { return }
        NSApp.keyWindow?.makeFirstResponder(nil)
        presentedCaptureSettingsNotebookId = nil
        isShowingResources = false
        showTranscript = false
        sessionSupplementarySurface = .note
    }

    private func showSessionSettings() {
        // While it is being recorded a recording's page is its transcript and
        // its notes; its files and settings wait until it has stopped.
        guard effectiveSessionId != nil, isBeingRecorded == false else { return }
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

    /// The topic's Record button records. It used to open the live page,
    /// where a second Record button did.
    /// A topic's Record button leads to the Record page with this topic chosen:
    /// languages and live captions are decided in one place, for every start.
    private func startRecordingInTopic() {
        navigation.openRecordPage(topicID: route?.notebookID)
    }

    private func syncPresentedRoute() {
        let selectedTab = activeNotebookTab
        showTranscript = NotebookTranscriptPresentationPolicy.shouldShow(
            displayType: selectedTab?.displayType,
            status: selectedTab?.status,
            selectedSessionId: selectedSessionId
        )
    }

    // MARK: - After Stop, and the recording's ⋯ menu

    private var isBeingRecorded: Bool {
        guard let sessionId = effectiveSessionId else { return false }
        let capture = ActiveBilingualTranscriptStore.shared
        return capture.isCaptureActive && capture.sessionId == sessionId
    }

    /// The recording as the header names it: its title, or its start time.
    private var recordingDisplayTitle: String {
        navigation.editorBreadcrumb?.recording?.label
            ?? RecordingPresentation.title(editorSession?.title ?? "")
            ?? String(localized: "resources.untitled_recording")
    }

    /// This page's recording has just finished. If its notes (or files) were
    /// on screen, turn to its transcript, where the card says it was saved.
    /// Only at that moment — coming back to the notes later is left alone.
    private func showTranscriptOfFinishedRecording() {
        if sessionSupplementarySurface == .note {
            // Someone writing notes stays on their notes: pulling the page
            // out from under a sentence being typed costs more than the card
            // tells. A toast says it was saved, unless the stop already did;
            // the card is on the transcript when they turn to it.
            if let finished = CaptureCommandCenter.shared.justFinished, finished.announced == false {
                ToastCenter.shared.success(String(
                    format: String(localized: "capture.toast.stopped_saved"),
                    CaptureCommandCenter.clock(TimeInterval(finished.seconds))
                ))
            }
        } else if sessionSupplementarySurface != nil {
            sessionSupplementarySurface = nil
            syncPresentedRoute()
        }
        // What the card says depends on what the recording ended up with.
        Task { await loadNotebookRoute() }
    }

    private func copyWholeTranscript() {
        guard let sessionId = effectiveSessionId else { return }
        // The version being read is the version copied.
        TranscriptClipboard.copyWholeTranscript(
            sessionId: sessionId,
            refined: activeNotebookTab?.displayType == .asyncTranscript
        )
    }

    private func exportRecording() {
        exportingSessionId = effectiveSessionId
        isShowingExportSheet = true
    }

    private func showRefinedTranscript() {
        guard let refined = notebookTabs.first(where: { $0.displayType == .asyncTranscript })
        else { return }
        selectNotebookTab(refined)
    }

    /// Refining was asked for from the card. The task queue now has it, so
    /// read it (the page then follows it until it is done). A recording with
    /// no text yet has nothing to keep on screen meanwhile: show where the
    /// refined transcript will appear.
    private func refineDidStart(hadText: Bool) {
        Task { await loadNotebookRoute() }
        if hadText == false {
            showRefinedTranscript()
        }
    }

    /// There is audio on this Mac to delete. One recorded on another Mac
    /// keeps its audio there.
    private var canDestroyAudio: Bool {
        editorSession?.hasEncryptedAudio == true && editorSession?.recordedOn == nil
    }

    private var destroyAudioBlockedReason: String? {
        selectedTranscriptionTask?.tabStatus == .pending
            ? String(localized: "session.menu.destroy_audio.refining")
            : nil
    }

    private func deleteRecording() {
        guard let sessionId = effectiveSessionId,
              LibraryCommands.moveRecordingToTrash(id: sessionId)
        else { return }
        ToastCenter.shared.success(String(localized: "session.delete.done"))
        let commands = CaptureCommandCenter.shared
        if commands.justFinished?.sessionId == sessionId {
            commands.dismissJustFinished()
        }
        navigation.navigateHome()
    }

}

/// The place on a recording's page where its result card goes, and the one
/// part of the page that watches for the recording finishing.
///
/// It feeds the card from the live stores — the command center, the person's
/// key, the city — so the page around it is not redrawn by every publish of
/// theirs: a mark or a pause during a recording must not re-run the page.
private struct RecordingResultCardHost: View {
    let sessionId: String
    /// The card sits on the transcript, not on the recording's notes or files.
    let isOnTranscript: Bool
    let session: SessionInfo?
    let availability: SessionTranscriptAvailabilityInfo?
    /// The newest refine of this recording in the task queue, if any.
    let refineTask: NotebookTabStatus?
    let showingRefined: Bool
    /// This recording has just finished: the page turns to its transcript.
    let onFinished: () -> Void
    let onCopy: () -> Void
    let onExport: () -> Void
    let onShare: (() -> Void)?
    /// Opens the archive sheet for this recording.
    let onFile: (() -> Void)?
    let onRefineStarted: (_ hadText: Bool) -> Void
    let onShowRefined: () -> Void

    @ObservedObject private var commands = CaptureCommandCenter.shared
    @ObservedObject private var hostMode = HostMode.shared
    // Observed for statusRevision, so the refine row follows a key saved or
    // removed in Settings.
    @ObservedObject private var providerCredentials = ProviderCredentialSession.shared
    @ObservedObject private var city = CityStore.shared
    @State private var isRequestingRefine = false
    /// Asked for from here and accepted; the task queue shows it a moment
    /// later.
    @State private var didRequestRefine = false

    private var finished: FinishedRecording? {
        guard let finished = commands.justFinished, finished.sessionId == sessionId
        else { return nil }
        return finished
    }

    var body: some View {
        // A stack even when empty, so there is always a view for the change
        // handler below to live on.
        VStack(spacing: 0) {
            if isOnTranscript, let finished {
                RecordingResultCard(
                    model: model(finished),
                    onCopy: onCopy,
                    onExport: onExport,
                    onShare: { onShare?() },
                    onFile: { onFile?() },
                    onRefine: { requestRefine(finished) },
                    onOpenSettings: {
                        MainNavigationStore.shared.openSettings(section: .account)
                    },
                    onShowRefined: onShowRefined,
                    onDismiss: commands.dismissJustFinished
                )
                .padding(.horizontal, NotebookRealtimeTranscriptLayout.horizontalInset)
                .padding(.top, Spacing.md)
                .padding(.bottom, Spacing.sm)
            }
        }
        // The moment of the Stop itself, not a later visit: opening this
        // recording afterwards — on its notes, say — is left where it lands.
        .montereyOnChange(of: commands.justFinished) { _, finished in
            if finished?.sessionId == sessionId { onFinished() }
        }
    }

    private func model(_ finished: FinishedRecording) -> RecordingResultCardModel {
        let hasAudio = session?.hasEncryptedAudio ?? true
        return RecordingResultCardModel.make(
            seconds: finished.seconds,
            liveTextOff: finished.audioOnly,
            hasText: hasText,
            hasAudio: hasAudio,
            refine: RecordingResultCardModel.refine(
                task: refineTask,
                hasRefinedText: availability?.hasAsyncContent == true,
                isRequesting: isRequestingRefine || (didRequestRefine && refineTask == nil),
                showingRefined: showingRefined,
                hasAudio: hasAudio,
                hasReadyPersonalKey: hasReadyPersonalSonioxKey,
                recordedOn: session?.recordedOn
            ),
            city: RecordingResultCardModel.city(
                signedIn: city.account != nil,
                filing: city.filings[finished.sessionId],
                busy: city.busySessions.contains(finished.sessionId),
                offline: city.offline,
                signer: city.account?.personName
            ),
            cityEventTitle: city.filings[finished.sessionId]?.eventTitle,
            offersFiling: onFile != nil && CityFilingEntry.resolve(
                place: .surface,
                signedIn: city.account != nil,
                hostingOn: hostMode.isOn,
                hasFiling: city.filings[finished.sessionId] != nil
                    || city.busySessions.contains(finished.sessionId),
                isRecording: false
            ) == .action
        )
    }

    private var hasText: Bool? {
        availability.map { $0.hasRealtimeContent || $0.hasAsyncContent }
    }

    private var hasReadyPersonalSonioxKey: Bool {
        providerCredentials.snapshot().contains {
            $0.account == .soniox && $0.isSaved && $0.isActive
        }
    }

    /// The page's own refine: the same request the refined view's button
    /// makes.
    private func requestRefine(_ finished: FinishedRecording) {
        guard isRequestingRefine == false else { return }
        isRequestingRefine = true
        let sessionId = finished.sessionId
        let hadText = model(finished).hasText
        Task { @MainActor in
            defer { isRequestingRefine = false }
            do {
                try await NotebookTranscriptProjectionStore.shared.requestAsyncTranscription(
                    sessionId: sessionId
                )
                didRequestRefine = true
                onRefineStarted(hadText)
            } catch {
                ToastCenter.shared.error(
                    String(localized: "refine.start_failed"),
                    detail: error.localizedDescription
                )
            }
        }
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
            ActionPill(
                String(localized: "home.workspace.retry"),
                systemImage: "arrow.clockwise",
                style: .quiet,
                action: onRetry
            )
        }
        .padding(.horizontal, Spacing.lg)
        .background(Color.bgElevated.opacity(0.24))
        .accessibilityIdentifier("editor.route.load_failure")
    }
}

// MARK: - DocumentTabBar

/// Notebook-scoped tab bar. The three document-backed items come from
/// NotebookTabViewModel; capture settings is a fourth UI-only surface and never
/// receives a synthetic tab ID or Loro document ID.
struct DocumentTabBar: View {
    let tabs: [NotebookTabViewModel]
    let activeTabId: String?
    let captureSettingsNotebookId: String?
    let isCaptureSettingsSelected: Bool
    let isResourcesSelected: Bool
    let isTopicContext: Bool
    let sessionId: String?
    let sessionSupplementarySurface: SessionSupplementarySurface?
    /// False for a recording with no live text: an imported file, or one
    /// recorded with live text off.
    let hasLiveVersion: Bool
    let onSelect: (NotebookTabViewModel) -> Void
    let onSelectResources: () -> Void
    let onSelectCaptureSettings: () -> Void
    let onSelectSessionNote: () -> Void
    let onSelectSessionSettings: () -> Void
    let onCopyAll: () -> Void
    let onExport: () -> Void
    /// Nil while the recording is still being recorded: that one is shared
    /// live from the recording bar instead.
    let onShare: (() -> Void)?
    /// Opens the archive sheet; nil while the recording is being recorded.
    let onFile: (() -> Void)?
    /// A state of the filing entry to draw instead of the live one.
    var shownFiling: CityFilingEntryPill.Shown?
    let onRename: () -> Void
    let onFileIntoTopic: () -> Void
    /// Nil when there is no audio on this Mac to delete.
    let onDestroyAudio: (() -> Void)?
    /// Why the audio cannot be deleted just now, said under the greyed item.
    let destroyAudioBlockedReason: String?
    let onDeleteRecording: () -> Void
    @ObservedObject private var captureStore = ActiveBilingualTranscriptStore.shared

    /// A recording's page has two tabs — its transcript and its notes. Which
    /// transcript (live or refined) is a pill at the far end showing the
    /// version on screen, not two more tabs; everything else about the
    /// recording sits behind ⋯.
    private var isRecordingPage: Bool { isTopicContext == false && sessionId != nil }

    /// This page's recording is the one being made right now. Then the page
    /// is for reading along and taking notes: which version to look at, its
    /// files, and renaming or deleting it all wait until it has stopped.
    private var isBeingRecorded: Bool {
        guard let sessionId else { return false }
        return captureStore.isCaptureActive && captureStore.sessionId == sessionId
    }

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

                    if isRecordingPage {
                        if let transcriptTab {
                            NotebookTabButton(
                                tab: transcriptTab,
                                isActive: isTranscriptSelected,
                                action: { onSelect(activeTranscriptTab ?? transcriptTabs[0]) }
                            )
                            .accessibilityIdentifier("session.tab.transcript")
                        }
                        SessionSupplementaryTabButton(
                            title: String(localized: "session.tab.notes"),
                            systemImage: "square.and.pencil",
                            accessibilityIdentifier: "session.tab.notes",
                            isActive: sessionSupplementarySurface == .note,
                            action: onSelectSessionNote
                        )
                        // Reached from ⋯; shown as a tab only while it is open,
                        // so there is always a selected tab saying where you are.
                        if sessionSupplementarySurface == .settings, isBeingRecorded == false {
                            SessionSupplementaryTabButton(
                                title: String(localized: "session.tab.settings"),
                                systemImage: "slider.horizontal.3",
                                accessibilityIdentifier: "session.tab.settings",
                                isActive: true,
                                action: onSelectSessionSettings
                            )
                        }
                    } else {
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
                    }

                    // A topic's own options: what its next recording starts
                    // with. A recording's settings tab above shows only what
                    // that recording used.
                    if isTopicContext, captureSettingsNotebookId != nil {
                        CaptureSettingsTabButton(
                            isActive: isCaptureSettingsSelected,
                            action: onSelectCaptureSettings
                        )
                    }
                }
            }

            Spacer(minLength: Spacing.md)

            if isRecordingPage, isBeingRecorded == false {
                if isTranscriptSelected,
                   let showing = activeTranscriptTab,
                   let other = transcriptTabs.first(where: { $0.id != showing.id }),
                   TranscriptVersionButtonPolicy.isOffered(
                       showing: showing.displayType,
                       hasLiveVersion: hasLiveVersion
                   ) {
                    TranscriptVersionSwitch(
                        showing: showing.displayType,
                        destination: effectiveTab(other),
                        onSelect: onSelect
                    )
                    .padding(.trailing, PillMetrics.spacing)
                }
                // Whether this recording reached the city's archive — or,
                // for someone hosting, the way to file one that has not been
                // given an event. Both open the archive sheet. Not for the
                // recording in progress (no `onFile`): where that one will
                // go is in the recording bar.
                if let sessionId, let onFile {
                    CityFilingEntryPill(sessionId: sessionId, onOpen: onFile, shown: shownFiling)
                }
                recordingMenu
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

    /// A topic's own tabs: its notes. Its recordings and settings are the
    /// buttons either side; a topic has no transcript of its own — the live
    /// view it used to have here was a recording's page by another name.
    private var visibleTabs: [NotebookTabViewModel] {
        tabs.filter { tab in
            if isTopicContext {
                return tab.displayType == .manualNote
            }
            return tab.displayType != .manualNote
        }
    }

    private var transcriptTabs: [NotebookTabViewModel] {
        tabs.filter { $0.displayType == .realtimeTranscript || $0.displayType == .asyncTranscript }
            .sorted { lhs, _ in lhs.displayType == .realtimeTranscript }
    }

    private var activeTranscriptTab: NotebookTabViewModel? {
        transcriptTabs.first { $0.id == activeTabId }
    }

    private var isTranscriptSelected: Bool {
        isCaptureSettingsSelected == false
            && isResourcesSelected == false
            && sessionSupplementarySurface == nil
            && activeTranscriptTab != nil
    }

    /// The one "Transcript" tab, carrying the status of the version on show
    /// (a live dot while recording, a spinner while the refined one is made).
    private var transcriptTab: NotebookTabViewModel? {
        guard let base = activeTranscriptTab ?? transcriptTabs.first else { return nil }
        let effective = effectiveTab(base)
        return NotebookTabViewModel(
            id: effective.id,
            notebookId: effective.notebookId,
            tabId: effective.tabId,
            displayType: effective.displayType,
            documentId: effective.documentId,
            sessionLink: effective.sessionLink,
            title: String(localized: "session.tab.transcript"),
            status: effective.status,
            position: effective.position
        )
    }

    /// What people come to a recording's ⋯ for, each in a word: take the
    /// text away, name it, file it, and — last, past a divider — the things
    /// that remove. What each removal costs is said by the question it asks
    /// before doing it, not by a longer name here.
    private var recordingMenu: some View {
        MorePill(String(localized: "session.menu.label")) {
            Button(action: onCopyAll) {
                Label(String(localized: "recording.word.copy"), systemImage: Icon.copy)
            }
            if let onShare {
                Button(action: onShare) {
                    Label(String(localized: "recording.word.share"), systemImage: Icon.export)
                }
            }
            // For anyone signed in to a city, hosting or not.
            if let sessionId, let onFile {
                CityFilingMenuItem(sessionId: sessionId, onOpen: onFile)
            }
            Button(action: onExport) {
                Label(String(localized: "common.export.action"), systemImage: "tray.and.arrow.up")
            }
            Divider()
            Button(action: onRename) {
                Label(String(localized: "recording.word.rename"), systemImage: "pencil")
            }
            Button(action: onFileIntoTopic) {
                Label(String(localized: "sidebar.notebook"), systemImage: "folder")
            }
            Button(action: onSelectSessionSettings) {
                Label(String(localized: "session.tab.settings"), systemImage: "slider.horizontal.3")
            }
            Divider()
            if let onDestroyAudio {
                // Greyed with its reason rather than hidden: an item that
                // comes and goes reads as something else being wrong.
                Button(role: .destructive, action: onDestroyAudio) {
                    Label(String(localized: "recording.word.delete_audio"), systemImage: "waveform.slash")
                }
                .disabled(destroyAudioBlockedReason != nil)
                if let destroyAudioBlockedReason {
                    Text(destroyAudioBlockedReason)
                }
            }
            Button(role: .destructive, action: onDeleteRecording) {
                Label(String(localized: "common.delete"), systemImage: "trash")
            }
        }
        .accessibilityIdentifier("session.menu")
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

/// Which transcript is on screen, as a pill: 「精修稿」 or 「边录边出的那一版」.
/// Its menu lists both, the one on screen ticked, and picking the other goes
/// there. It was a two-way 实时版 | 精修版 switch, then a text link naming
/// the other version; a control that shows its own value is what the rest
/// of the app's pills are, and it is found without being read.
private struct TranscriptVersionSwitch: View {
    /// The version on screen.
    let showing: NotebookTabDisplayType
    /// The other version's tab, with how it stands right now.
    let destination: NotebookTabViewModel
    let onSelect: (NotebookTabViewModel) -> Void

    var body: some View {
        if let current = TranscriptVersionButtonPolicy.title(showing),
           let other = TranscriptVersionButtonPolicy.title(destination.displayType) {
            MenuPill(
                current,
                systemImage: "square.stack",
                // A refine that failed is worth a glance before opening.
                tone: destination.status == .failed ? .warning : .normal,
                help: TranscriptVersionButtonPolicy.label(showing: showing),
                accessibilityLabel: String(localized: "recording.word.version")
            ) {
                let here = PillMenuItem(current, isOn: true)
                let there = PillMenuItem(otherTitle(other)) { onSelect(destination) }
                // Always the live version first, so the menu does not
                // reorder itself as the page changes.
                return showing == .realtimeTranscript ? [here, there] : [there, here]
            }
            .accessibilityIdentifier(destination.displayType == .realtimeTranscript
                ? "session.transcript.live"
                : "session.transcript.refined")
        }
    }

    /// The other version, with a word after it while it is being made or
    /// after it failed.
    private func otherTitle(_ name: String) -> String {
        switch destination.status {
        case .pending:
            return name + " · " + String(localized: "resources.status.pending")
        case .failed:
            return name + " · " + String(localized: "resources.status.failed")
        case .ready, .live:
            return name
        }
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

/// How the refined transcript stands: the word and icon its bar shows, and
/// the sentence that word is short for.
struct RefinedStatus {
    var word: String
    var systemImage: String
    var tint: Color = .textTertiary
    var isBusy = false
    /// The tooltip: the longer way of saying the word.
    var help: String?
    /// A reason worth a click to read — the service's error text.
    var detail: String?
}

/// The bar over a refined transcript: a status — an icon and a word — and
/// the one thing to do about it. What used to be spelled out here in a
/// sentence, and under it in a paragraph, is the status's tooltip, or one
/// click away in the ⓘ. A plain view of what it is handed, so each state
/// can be drawn and checked without a recording behind it.
struct RefinedStatusBar: View {
    struct Retry {
        var title: String
        var hint: String
        var isBusy: Bool
    }

    let sessionId: String
    let status: RefinedStatus
    /// The refined text came without speakers or languages.
    var showsMetadataNotice = false
    var isReadOnly = false
    let action: AsyncTranscriptPrimaryAction
    var isRequesting = false
    var retry: Retry?
    let onStart: () -> Void
    let onOpenSettings: () -> Void
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: PillMetrics.spacing) {
            StatusWord(
                status.word,
                systemImage: status.systemImage,
                tint: status.tint,
                isBusy: status.isBusy,
                help: status.help
            )
            .accessibilityIdentifier("async.transcription.status.\(sessionId)")
            if let detail = status.detail {
                // Why it failed, in the service's own words.
                InfoButton(detail, accessibilityLabel: status.word)
            }
            if showsMetadataNotice {
                InfoButton(String(localized: "editor.transcript.async.metadata_missing_notice"))
                    .accessibilityIdentifier("async.transcript.metadata-missing")
            }
            if isReadOnly {
                StatusWord(
                    String(localized: "recording.word.read_only"),
                    systemImage: "lock.fill",
                    help: String(localized: "capture.transcript.read_only")
                )
            }
            Spacer(minLength: Spacing.md)
            switch action {
            case .addPersonalKey:
                // Post-stop upload requires a saved personal key. Keep the
                // setup action visible for an already queued task too: the
                // worker will continue once that key becomes available.
                ActionPill(
                    String(localized: "refine.action"),
                    systemImage: "wand.and.stars",
                    tone: .dimmed,
                    mark: .warning,
                    help: String(localized: "community_invite.async.needs_personal_key"),
                    action: onOpenSettings
                )
                .accessibilityIdentifier("async.transcription.add-key.\(sessionId)")
            case .start:
                PrimaryPill(
                    String(localized: "refine.action"),
                    systemImage: "wand.and.stars",
                    help: String(localized: "recording.result.refine.detail"),
                    action: onStart
                )
                .disabled(isRequesting)
                .accessibilityIdentifier("async.transcription.start.\(sessionId)")
            case .audioElsewhere(let device):
                StatusWord(
                    RecordingOrigin.badge(device),
                    systemImage: "laptopcomputer",
                    help: RecordingOrigin.audioElsewhereHint(device)
                )
                .accessibilityIdentifier("async.transcription.audio-elsewhere.\(sessionId)")
            case .none:
                EmptyView()
            }
            if let retry {
                ActionPill(
                    retry.title,
                    systemImage: "arrow.clockwise",
                    help: retry.hint,
                    action: onRetry
                )
                .disabled(retry.isBusy)
                .accessibilityIdentifier("async.transcription.retry-projection.\(sessionId)")
            }
        }
        .padding(.horizontal, NotebookRealtimeTranscriptLayout.horizontalInset + Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(Color.bgSunken.opacity(0.2))
        .accessibilityElement(children: .contain)
    }
}

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
    /// 另一台 Mac 录的:那台的名字。本机录的为 nil。
    @State private var recordedOn: String?

    private var lines: [NotebookTranscriptLine] {
        projectionStore.linesBySession[sessionId] ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            asyncStatusBar
            Divider().background(Color.borderGhost.opacity(0.25))
            Group {
                switch contentPhase {
                case .loading:
                    // The bar above says what is being waited for.
                    AsyncTranscriptLoadingView(statusText: asyncStatus.word)
                case .empty:
                    OneSentenceState(
                        systemImage: asyncStatus.systemImage,
                        sentence: emptyStateSentence,
                        tint: asyncStatus.tint,
                        detail: emptyStateDetail
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
            recordedOn = CoreClient.shared.core?.sessionRecordedOn(sessionId: sessionId)
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
        let failed = asyncProjectionState == .failed
            || storedProjectionRepairFailed
            || hasProjectionLoadFailure
        return RefinedStatusBar(
            sessionId: sessionId,
            status: asyncStatus,
            showsMetadataNotice: AsyncTranscriptMetadataNoticePolicy.shouldShow(for: lines),
            isReadOnly: lines.isEmpty == false && isTranscriptEditable == false,
            action: primaryAction,
            isRequesting: isRequestingAsyncTranscription,
            retry: failed
                ? .init(
                    title: retryActionLabel,
                    hint: retryActionHint,
                    isBusy: isRetryingProjection || isRepairingStoredProjection
                )
                : nil,
            onStart: requestAsyncTranscription,
            onOpenSettings: { MainNavigationStore.shared.openSettings(section: .account) },
            onRetry: retryProjection
        )
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
            hasReadyPersonalKey: hasReadyPersonalSonioxKey,
            recordedOn: recordedOn
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

    private typealias Status = RefinedStatus

    private var asyncStatus: Status {
        let failedIcon = "exclamationmark.triangle.fill"
        if isRetryingProjection || isRepairingStoredProjection {
            return Status(
                word: String(localized: "editor.transcript.async.status.projecting"),
                systemImage: "arrow.triangle.2.circlepath",
                isBusy: true
            )
        }
        if let documentReadError {
            return Status(
                word: String(localized: "resources.status.failed"),
                systemImage: failedIcon,
                tint: .signalAmber,
                help: String(localized: "editor.route.load_failed"),
                detail: documentReadError
            )
        }
        if storedProjectionRepairFailed || hasProjectionLoadFailure {
            return Status(
                word: String(localized: "editor.transcript.async.status.projection_failed"),
                systemImage: failedIcon,
                tint: .signalAmber,
                help: String(localized: "editor.transcript.async.projection_failed_desc")
            )
        }
        if lines.isEmpty == false {
            return Status(
                word: String(localized: "resources.async"),
                systemImage: "checkmark.circle.fill",
                tint: .signalGreen,
                help: String(localized: "editor.transcript.async.status.ready")
            )
        }
        switch asyncProjectionState {
        case .some(.pending):
            return Status(
                word: String(localized: "editor.transcript.async.status.projection_pending"),
                systemImage: "clock.fill",
                help: String(localized: "editor.transcript.async.projection_pending_desc")
            )
        case .some(.projecting):
            return Status(
                word: String(localized: "editor.transcript.async.status.projecting"),
                systemImage: "arrow.triangle.2.circlepath",
                isBusy: true,
                help: String(localized: "editor.transcript.async.projection_pending_desc")
            )
        case .some(.ready):
            return Status(
                word: String(localized: "editor.transcript.async.status.ready"),
                systemImage: "checkmark.circle.fill",
                tint: .signalGreen
            )
        case .some(.failed):
            return Status(
                word: String(localized: "editor.transcript.async.status.projection_failed"),
                systemImage: failedIcon,
                tint: .signalAmber,
                help: String(localized: "editor.transcript.async.projection_failed_desc")
            )
        case .some(.none):
            if isProviderPending || status == .pending {
                return Status(
                    word: String(localized: "editor.transcript.async.pending_title"),
                    systemImage: "hourglass",
                    isBusy: isProviderPending,
                    help: [
                        String(localized: "editor.transcript.async.status.provider_pending"),
                        String(localized: "editor.transcript.async.pending_desc"),
                    ].joined(separator: "\n")
                )
            }
            if asyncProviderState == "failed" || status == .failed {
                return Status(
                    word: String(localized: "editor.transcript.async.failed_title"),
                    systemImage: failedIcon,
                    tint: .signalAmber,
                    help: String(localized: "editor.transcript.async.status.provider_failed"),
                    detail: providerFailureDetail
                )
            }
            return Status(
                word: String(localized: "editor.transcript.async.empty_title"),
                systemImage: "wand.and.stars",
                help: String(localized: "editor.transcript.async.status.off")
            )
        case nil:
            return Status(
                word: String(localized: "editor.transcript.async.status.loading"),
                systemImage: "clock",
                isBusy: hasProjectionLoadFailure == false
            )
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

    /// The one sentence an empty refined view prints. The bar above has
    /// the state in a word; this says it once, in full.
    private var emptyStateSentence: String {
        if documentReadError != nil {
            return String(localized: "editor.route.load_failed")
        }
        if storedProjectionRepairFailed || hasProjectionLoadFailure {
            return String(localized: "editor.transcript.async.projection_failed_title")
        }
        switch asyncProjectionState {
        case .some(.pending), .some(.projecting):
            return String(localized: "editor.transcript.async.projection_pending_desc")
        case .some(.failed):
            return String(localized: "editor.transcript.async.projection_failed_title")
        case .some(.none) where status == .pending || isProviderPending:
            return String(localized: "editor.transcript.async.pending_desc")
        case .some(.none) where status == .failed || asyncProviderState == "failed":
            return String(localized: "recording.result.refine.failed")
        default:
            return String(localized: "editor.transcript.async.empty_desc")
        }
    }

    /// What used to be the paragraph under the title: the tooltip now.
    private var emptyStateDetail: String? {
        if let documentReadError { return documentReadError }
        if storedProjectionRepairFailed || hasProjectionLoadFailure
            || asyncProjectionState == .failed {
            return String(localized: "editor.transcript.async.projection_failed_desc")
        }
        if asyncProjectionState == NotebookAsyncProjectionState.none,
           status == .failed || asyncProviderState == "failed" {
            return providerFailureDetail
        }
        return nil
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

    /// The service's own account of why refining failed, when it gave one.
    private var providerFailureDetail: String? {
        guard let detail = taskErrorMessage?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), detail.isEmpty == false else { return nil }
        return detail
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
        normalizedSourceLanguage.map(RecordingPresentation.languageName)
    }

    private var timestampText: String? {
        guard let milliseconds = line.startMs else { return nil }
        return TranscriptTimestampPresentation.text(milliseconds: milliseconds)
    }
}

private struct AsyncTranscriptLoadingView: View {
    let statusText: String

    var body: some View {
        ProgressView()
            .controlSize(.small)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel(Text(statusText))
    }
}

// MARK: - Builtin tab title

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
            Text(String(localized: "session.notes.title"))
                .font(.caption)
                .foregroundColor(.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.sm)
        .background(Color.bgSunken.opacity(0.18))
        // Whose notes these are, for whoever asks.
        .pillExplained(help: String(localized: "session.notes.context"))
        .accessibilityIdentifier("session.notes.context")
    }
}

/// A finished recording's details tab is about that recording only: what it
/// has (audio, transcripts, notes) and what it was recorded with. It used to
/// carry, between the two, the editor for the *next* recording's defaults,
/// and people could not tell which recording they were changing. Those
/// defaults live where a recording is started and in the topic's own options
/// (docs/product/interface-layers.md).
///
/// Three groups, each under one word — files, info, setup — and every row a
/// name and a value or a control. The sentences that used to sit under the
/// headings are their tooltips.
private struct SessionSettingsView: View {
    let notebookId: String
    let session: SessionInfo
    let onOpenResource: (NotebookResourceDestination) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                sessionResourceSection

                SessionSettingsSnapshotView(
                    notebookId: notebookId,
                    session: session,
                    isEmbedded: true
                )
            }
            // One centred column for all three groups.
            .padding(.horizontal, Spacing.xl)
            .padding(.vertical, Spacing.lg)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
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
            settingsSection(
                title: String(localized: "recording.details.info"),
                rows: sessionRows
            )

            VStack(alignment: .leading, spacing: Spacing.xs) {
                GroupHeader(
                    String(localized: "recording.details.setup"),
                    // What these rows are: what this recording used, not a
                    // default anyone can change here.
                    help: String(localized: "session.settings.subtitle")
                )
                if isLoading {
                    StatusWord(
                        String(localized: "editor.transcript.async.status.loading"),
                        systemImage: "clock",
                        isBusy: true
                    )
                } else if let loadError {
                    HStack(spacing: PillMetrics.spacing) {
                        StatusWord(
                            String(localized: "session.settings.load_failed"),
                            systemImage: "exclamationmark.triangle.fill",
                            tint: .signalAmber,
                            help: loadError
                        )
                        ActionPill(
                            String(localized: "session.settings.retry"),
                            systemImage: "arrow.clockwise"
                        ) {
                            Task { await load() }
                        }
                    }
                } else {
                    if captureRun == nil {
                        snapshotNotice(
                            key: session.sessionType.lowercased() == "import"
                                ? "session.settings.snapshot.imported_missing"
                                : "session.settings.snapshot.missing",
                            systemImage: "questionmark.circle",
                            color: .textTertiary
                        )
                    } else if captureRun?.providerErrorType == "profile_snapshot_corrupt" {
                        snapshotNotice(
                            key: "session.settings.snapshot.corrupt",
                            systemImage: "exclamationmark.triangle.fill",
                            color: .signalAmber
                        )
                    }
                    rowList(captureRows)
                }
            }

            HStack(spacing: Spacing.sm) {
                Image(systemName: "number")
                    .foregroundColor(.textTertiary)
                    .accessibilityHidden(true)
                Text(session.id)
                    .font(.caption.monospaced())
                    .foregroundColor(.textTertiary)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, isEmbedded ? 0 : Spacing.xl)
        .padding(.vertical, isEmbedded ? 0 : Spacing.lg)
        .frame(maxWidth: isEmbedded ? .infinity : 860, alignment: .leading)
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
                value: session.recordedOn.map(RecordingOrigin.audioOn)
                    ?? String(localized: session.hasEncryptedAudio
                        ? "session.settings.value.available"
                        : "session.settings.value.unavailable")
            ),
        ]
    }

    private var captureRows: [SessionSettingsRowModel] {
        // Nothing was recorded about the setup: the one line above says so,
        // and a row reading "unknown" would only say it twice.
        guard let captureRun else { return [] }
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

    /// A group: one word, then its rows. No box around it; space and the
    /// word are what set it apart.
    private func settingsSection(
        title: String,
        rows: [SessionSettingsRowModel]
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            GroupHeader(title)
            rowList(rows)
        }
    }

    private func rowList(_ rows: [SessionSettingsRowModel]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { row in
                SessionSettingsRow(row: row)
            }
        }
    }

    /// The one line a group with nothing to list may print.
    private func snapshotNotice(
        key: String.LocalizationValue,
        systemImage: String,
        color: Color
    ) -> some View {
        HStack(spacing: PillMetrics.iconSpacing) {
            Image(systemName: systemImage)
                .font(PillMetrics.iconFont)
                .foregroundColor(color)
                .accessibilityHidden(true)
            Text(String(localized: key))
                .font(PillMetrics.font)
                .foregroundColor(.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minHeight: PillMetrics.height, alignment: .leading)
        .accessibilityElement(children: .combine)
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

    /// The languages by name, as everywhere else: a code is ours, not a
    /// word the reader knows.
    private var languageText: String {
        let names = RecordingPresentation.languageList(
            [session.sourceLanguage] + session.targetLanguages
        )
        return names.isEmpty ? String(localized: "session.settings.value.unknown") : names
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
        DetailRow(row.label, systemImage: row.icon, value: row.value)
            .accessibilityElement(children: .combine)
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


