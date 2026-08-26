// LibraryViewModel.swift
// HomeView 用的 session 列表数据层 + Models。
//
// HomeView 使用的 session 数据类型与查询逻辑。

import SwiftUI
import Combine
import OSLog

enum SessionCatalogLoadError: Error, Equatable {
    case invalidPageSize
    case snapshotChanged(expected: UInt64, actual: UInt64)
    case stalled(offset: UInt32)
    case incomplete(expected: UInt64, actual: UInt64)
}

// MARK: - Models

struct SessionListItem: Identifiable, Equatable {
    let id: String
    var title: String
    var timeString: String       // e.g. "14:23"
    var durationString: String   // e.g. "01:23:45"
    var durationMs: UInt64 = 0
    var languagePair: String     // e.g. "EN ↔ 中"
    var badges: [SessionBadge] = []
    var createdAt: Date = Date()
    var sessionType: String = "overlay"
    var hasEncryptedAudio: Bool = true
    /// Transcript 首 ~120 字预览(Home 列表显示这行让用户一眼看出"在说什么")
    var preview: String = ""
    // 完整数据(Detail 视图已删,这两个留着兼容 LibraryViewModel 映射,UI 不读)
    var transcriptText: String = ""
    var summaryText: String = ""
    /// session_records.status: "recording" | "completed" | "imported" | "interrupted" | "failed"
    /// 用来在 Home 列表区分"录音中"/"转录中"/"无语音",避免文案误导。
    var rawStatus: String = "completed"
    /// "pending" | "ready" | "failed" from the authoritative Transcribe task.
    /// Home 列表用它区分"真的在转录"和"根本没启动转录"。
    var transcriptDocumentStatus: String? = nil
}

struct SessionBadge: Equatable {
    let label: String
    let color: Color
}

struct SessionGroup {
    let label: String  // "TODAY", "YESTERDAY", "Apr 10, 2026"
    let sessions: [SessionListItem]
}

private enum NotebookAudioImportOutcome: Sendable {
    case success(ImportResultInfo)
    case failure
}

private enum SessionCatalogQueryOutcome: @unchecked Sendable {
    case success(sessions: [SessionInfo], totalCount: UInt64)
    case failure(message: String)
}

private enum SessionFullTextSearchOutcome: @unchecked Sendable {
    case success([SearchResultInfo])
    case failure(String)
}

enum SessionPreviewPlaceholderState: Equatable {
    case recording
    case transcribing
    case noSpeech
    case failed
    case notTranscribed
}

enum HomeSessionStatusState: Equatable {
    case recording
    case transcribing
    case interrupted
    case failed
    case completed
    case imported
}

/// Home's recording affordance has two materially different jobs. When a
/// capture is already active it must return to that capture's Topic; otherwise
/// it lets the user choose where a new recording should live.
struct HomeActiveCaptureDestination: Equatable {
    let notebookId: String
    let topicTitle: String?
}

enum HomeRecordingEntryPolicy {
    /// A redeemed, enabled community invitation is an explicit authorization
    /// for Home's one-click capture to use realtime transcription. Without it,
    /// a fresh quick-capture profile remains local-only.
    static func shouldEnableRealtimeForQuickCapture(
        inviteIsEnabled: Bool,
        inviteIsActive: Bool
    ) -> Bool {
        inviteIsEnabled && inviteIsActive
    }

    static func activeDestination(
        isCaptureActive: Bool,
        captureNotebookId: String?,
        notebooks: [FfiNotebook]
    ) -> HomeActiveCaptureDestination? {
        guard isCaptureActive,
              let captureNotebookId,
              captureNotebookId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        else { return nil }

        let topicTitle = notebooks
            .first(where: { $0.id == captureNotebookId })?
            .title
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return HomeActiveCaptureDestination(
            notebookId: captureNotebookId,
            topicTitle: topicTitle?.isEmpty == false ? topicTitle : nil
        )
    }
}

extension SessionListItem {
    /// 这段录音此刻还在录。删除一族的入口都要看它 —— Core 会拒绝删除
    /// 正在录的 session(软删与彻底删除一视同仁),UI 不该先摆出一个
    /// 注定失败的按钮。
    var isRecording: Bool {
        rawStatus.lowercased() == "recording"
    }

    var homeStatusState: HomeSessionStatusState? {
        let normalizedStatus = rawStatus.lowercased()
        if normalizedStatus == "recording" {
            return .recording
        }
        if transcriptDocumentStatus == "failed" {
            return .failed
        }
        if normalizedStatus == "failed" {
            return .failed
        }
        if transcriptDocumentStatus == "pending" {
            return .transcribing
        }
        if normalizedStatus == "interrupted" {
            return .interrupted
        }
        if normalizedStatus == "imported" {
            return .imported
        }
        if normalizedStatus == "completed" {
            return sessionType == "import" ? .imported : .completed
        }
        return nil
    }

    var previewPlaceholderState: SessionPreviewPlaceholderState? {
        guard preview.isEmpty else { return nil }

        let normalizedStatus = rawStatus.lowercased()
        if normalizedStatus == "recording" {
            return .recording
        }
        if normalizedStatus == "failed" || transcriptDocumentStatus == "failed" {
            return .failed
        }
        if transcriptDocumentStatus == "pending" {
            return .transcribing
        }
        if durationMs == 0 {
            return .noSpeech
        }
        if transcriptDocumentStatus == "ready" {
            return nil
        }
        return .notTranscribed
    }
}

// MARK: - View Model

class LibraryViewModel: ObservableObject {
    static let unfiledTopicFilterId = "__zutalk_ui_unfiled__"
    static let notebookTitleMaxLength = 120
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "xyz.voice.zutalk",
        category: "NotebookHome"
    )

    @Published var sessions: [SessionListItem] = []
    @Published var groupedSessions: [SessionGroup] = []
    @Published var searchText: String = ""
    @Published var selectedId: String?
    @Published var totalCount: Int = 0
    @Published var notebooks: [FfiNotebook] = []
    @Published var activeNotebookId: String?
    @Published var notebookTabs: [FfiNotebookTab] = []
    @Published var notebookSessionLinks: [FfiNotebookSessionLink] = []
    @Published var notebookSessionProjections: [FfiNotebookSessionProjection] = []
    @Published private(set) var notebookSessionCounts: [String: Int] = [:]
    /// UI-level Topic projection. Storage still calls this entity Notebook and
    /// preserves its single-owner invariant; Home only uses it as a filter and
    /// display lookup for the global Session catalogue.
    @Published private(set) var topicIdBySessionId: [String: String] = [:]
    /// False only before Core has produced the first complete ownership
    /// snapshot. An empty map is otherwise meaningful: it means the Sessions
    /// are genuinely unfiled, not that membership failed to load.
    @Published private(set) var hasLoadedTopicMemberships = false
    /// Core's technical capture owner is hidden from the product Topic
    /// taxonomy. Sessions stored there appear as unfiled until the user chooses
    /// a research Topic.
    @Published private(set) var quickCaptureNotebookId: String?
    private var storageNotebookIdBySessionId: [String: String] = [:]
    @Published var selectedTopicFilterId: String?
    @Published var notebookWorkspaceError: String?
    @Published private(set) var isLoadingSessions = false
    @Published private(set) var sessionLoadError: String?
    @Published private(set) var isSearchingTranscripts = false
    @Published private(set) var transcriptSearchError: String?
    @Published private(set) var transcriptSearchSnippets: [String: String] = [:]
    @Published private(set) var isImportingAudio = false
    @Published private(set) var audioImportError: String?

    private let notebookContext: NotebookSessionContextStore
    private var sessionLoadGeneration: UInt = 0
    private var transcriptSearchGeneration: UInt = 0
    private var transcriptSearchTask: Task<Void, Never>?
    private var isTranscriptSearchRequestInFlight = false
    private var pendingTranscriptSearch: (
        query: String,
        generation: UInt,
        core: any ZuTalkCoreProtocol
    )?

    @MainActor
    init(notebookContext: NotebookSessionContextStore? = nil) {
        self.notebookContext = notebookContext ?? .shared
    }

    // 多选模式状态:UI 点顶部 "Select" 进入;每行出 checkbox
    @Published var selectionMode: Bool = false
    @Published var selectedIds: Set<String> = []

    func enterSelectionMode() {
        selectionMode = true
        selectedIds.removeAll()
    }

    func exitSelectionMode() {
        selectionMode = false
        selectedIds.removeAll()
    }

    /// 正在录的选不进来:批量删除里混进一条正在录的,Core 会整批拒绝
    /// (删一半更糟),所以根本不让它进名单。
    @MainActor
    func toggleSelected(_ id: String) {
        if selectedIds.contains(id) {
            selectedIds.remove(id)
        } else if isRecording(id) {
            ToastCenter.shared.info(String(localized: "home.recording.delete_while_recording"))
        } else {
            selectedIds.insert(id)
        }
    }

    private func isRecording(_ id: String) -> Bool {
        sessions.first { $0.id == id }?.isRecording ?? false
    }

    /// 单删(右键 ContextMenu)→ 软删到 Trash。
    @MainActor
    func softDelete(_ id: String) {
        guard let core = CoreClient.shared.core else { return }
        // 菜单项本来就禁着;这里再拦一道,防的是「点开菜单时还没开始录,
        // 点下去时已经在录」那一拍。
        guard !isRecording(id) else {
            ToastCenter.shared.info(String(localized: "home.recording.delete_while_recording"))
            return
        }
        do {
            try core.softDeleteSession(sessionId: id)
            cancelPendingSessionLoad()
            sessions.removeAll { $0.id == id }
            removeSessionsFromTopicCatalog([id])
            rebuildGroups()
            if selectedId == id { selectedId = sessions.first?.id }
            ToastCenter.shared.info(String(localized: "library.toast.moved_to_trash"))
        } catch {
            Self.logger.error(
                "Move recording to Trash failed: \(String(describing: error), privacy: .private)"
            )
            ToastCenter.shared.error(String(localized: "home.recording.delete_failed"))
        }
    }

    /// 批量软删(多选模式下点 "Delete N" 按钮)。
    @MainActor
    func softDeleteSelected() {
        guard !selectedIds.isEmpty, let core = CoreClient.shared.core else { return }
        let ids = Array(selectedIds)
        guard !ids.contains(where: { isRecording($0) }) else {
            ToastCenter.shared.info(String(localized: "home.recording.delete_while_recording"))
            return
        }
        do {
            try core.softDeleteSessions(sessionIds: ids)
            cancelPendingSessionLoad()
            sessions.removeAll { selectedIds.contains($0.id) }
            removeSessionsFromTopicCatalog(Set(ids))
            rebuildGroups()
            ToastCenter.shared.info(
                String(format: String(localized: "library.toast.bulk_moved_to_trash"), ids.count)
            )
            exitSelectionMode()
        } catch {
            Self.logger.error(
                "Bulk move recordings to Trash failed: \(String(describing: error), privacy: .private)"
            )
            ToastCenter.shared.error(String(localized: "home.recording.bulk_delete_failed"))
        }
    }

    var selectedSession: SessionListItem? {
        sessions.first { $0.id == selectedId }
    }

    var activeNotebook: FfiNotebook? {
        guard let activeNotebookId else { return nil }
        return notebooks.first { $0.id == activeNotebookId }
    }

    var researchNotebooks: [FfiNotebook] {
        notebooks
    }

    var canStartQuickCapture: Bool {
        quickCaptureNotebookId != nil
    }

    func canOpenCatalogSession(_ sessionId: String) -> Bool {
        storageNotebookIdBySessionId[sessionId] != nil
    }

    var hasNoResearchTopics: Bool {
        notebooks.isEmpty
    }

    var activeNotebookSessions: [SessionListItem] {
        let sessionIds = activeNotebookSessionIds
        guard sessionIds.isEmpty == false else { return [] }
        return sessions.filter { sessionIds.contains($0.id) }
    }

    /// The research ledger is global by default. A Topic filter narrows that
    /// ledger without changing the active Notebook/capture destination.
    var catalogSessions: [SessionListItem] {
        let topicScoped: [SessionListItem]
        if let selectedTopicFilterId {
            if selectedTopicFilterId == Self.unfiledTopicFilterId {
                topicScoped = hasLoadedTopicMemberships
                    ? sessions.filter { topicIdBySessionId[$0.id] == nil }
                    : []
            } else {
                topicScoped = sessions.filter {
                    topicIdBySessionId[$0.id] == selectedTopicFilterId
                }
            }
        } else {
            topicScoped = sessions
        }

        let normalizedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered: [SessionListItem]
        if normalizedSearch.isEmpty {
            filtered = topicScoped
        } else {
            filtered = topicScoped.compactMap { item in
                let kindLabel = item.sessionType == "import"
                    ? String(localized: "home.row.kind.import")
                    : String(localized: "home.row.kind.recording")
                let localMatch = item.title.localizedCaseInsensitiveContains(normalizedSearch)
                    || item.preview.localizedCaseInsensitiveContains(normalizedSearch)
                    || item.languagePair.localizedCaseInsensitiveContains(normalizedSearch)
                    || item.sessionType.localizedCaseInsensitiveContains(normalizedSearch)
                    || kindLabel.localizedCaseInsensitiveContains(normalizedSearch)
                    || (topicTitle(forSessionId: item.id)?
                        .localizedCaseInsensitiveContains(normalizedSearch) ?? false)
                    || (hasLoadedTopicMemberships
                        && topicIdBySessionId[item.id] == nil
                        && String(localized: "home.row.topic.unassigned")
                            .localizedCaseInsensitiveContains(normalizedSearch))
                guard localMatch || transcriptSearchSnippets[item.id] != nil else {
                    return nil
                }
                guard let snippet = transcriptSearchSnippets[item.id],
                      snippet.isEmpty == false else { return item }
                var updated = item
                updated.preview = snippet
                return updated
            }
        }

        return filtered.sorted { lhs, rhs in
            if lhs.createdAt == rhs.createdAt {
                return lhs.id < rhs.id
            }
            return lhs.createdAt > rhs.createdAt
        }
    }

    var catalogGroupedSessions: [SessionGroup] {
        Self.groupSessions(catalogSessions)
    }

    var hasCatalogSearchText: Bool {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    @MainActor
    func updateTranscriptSearch() {
        transcriptSearchTask?.cancel()
        pendingTranscriptSearch = nil
        transcriptSearchGeneration &+= 1
        let generation = transcriptSearchGeneration
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard query.isEmpty == false else {
            transcriptSearchSnippets = [:]
            transcriptSearchError = nil
            isSearchingTranscripts = false
            return
        }
        guard let core = CoreClient.shared.core else {
            transcriptSearchSnippets = [:]
            transcriptSearchError = String(localized: "home.catalog.search_failed")
            isSearchingTranscripts = false
            return
        }

        transcriptSearchSnippets = [:]
        isSearchingTranscripts = true
        transcriptSearchError = nil
        transcriptSearchTask = Task { @MainActor [weak self, core] in
            do {
                try await MontereyTaskSleep.milliseconds(250)
            } catch {
                return
            }
            guard Task.isCancelled == false else { return }
            self?.startTranscriptSearch(
                query: query,
                generation: generation,
                core: core
            )
        }
    }

    @MainActor
    private func startTranscriptSearch(
        query: String,
        generation: UInt,
        core: any ZuTalkCoreProtocol
    ) {
        guard generation == transcriptSearchGeneration,
              query == searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return }
        if isTranscriptSearchRequestInFlight {
            // FFI reads are synchronous and cannot be cancelled once started.
            // Keep only the newest debounced request instead of queueing every
            // intermediate query behind SearchStore's connection mutex.
            pendingTranscriptSearch = (query, generation, core)
            return
        }
        isTranscriptSearchRequestInFlight = true
        Task { @MainActor [weak self, core] in
            let outcome = await Task.detached(priority: .userInitiated) {
                do {
                    return SessionFullTextSearchOutcome.success(
                        try core.searchSessions(query: query, limit: 5_000)
                    )
                } catch {
                    return SessionFullTextSearchOutcome.failure(String(describing: error))
                }
            }.value
            guard let self else { return }
            self.isTranscriptSearchRequestInFlight = false
            if self.transcriptSearchGeneration == generation,
               query == self.searchText.trimmingCharacters(in: .whitespacesAndNewlines) {
                self.isSearchingTranscripts = false
                switch outcome {
                case .success(let results):
                    var snippets: [String: String] = [:]
                    for result in results where snippets[result.sessionId] == nil {
                        snippets[result.sessionId] = Self.sanitizedSearchSnippet(result.snippet)
                    }
                    self.transcriptSearchSnippets = snippets
                    self.transcriptSearchError = nil
                case .failure:
                    // Metadata matching remains usable; do not turn a search
                    // backend failure into a false "no results" state.
                    self.transcriptSearchSnippets = [:]
                    self.transcriptSearchError = String(localized: "home.catalog.search_failed")
                }
            }
            if let pending = self.pendingTranscriptSearch {
                self.pendingTranscriptSearch = nil
                self.startTranscriptSearch(
                    query: pending.query,
                    generation: pending.generation,
                    core: pending.core
                )
            }
        }
    }

    nonisolated static func sanitizedSearchSnippet(_ raw: String) -> String {
        let withoutMarkup = raw
            .replacingOccurrences(of: "<b>", with: "")
            .replacingOccurrences(of: "</b>", with: "")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
        let collapsed = withoutMarkup
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return String(collapsed.prefix(240))
    }

    nonisolated static func visibleTopicMemberships(
        storageMemberships: [String: String],
        quickCaptureNotebookId: String?
    ) -> [String: String] {
        guard let quickCaptureNotebookId else { return storageMemberships }
        return storageMemberships.filter { $0.value != quickCaptureNotebookId }
    }

    func topicTitle(forSessionId sessionId: String) -> String? {
        guard let topicId = topicIdBySessionId[sessionId] else { return nil }
        return notebooks.first(where: { $0.id == topicId })?.title
    }

    func selectTopicFilter(_ topicId: String?) {
        guard let topicId else {
            selectedTopicFilterId = nil
            return
        }
        selectedTopicFilterId = researchNotebooks.contains(where: { $0.id == topicId })
            ? topicId
            : nil
    }

    func selectUnfiledFilter() {
        guard hasLoadedTopicMemberships else { return }
        selectedTopicFilterId = Self.unfiledTopicFilterId
    }

    var unfiledSessionCount: Int {
        guard hasLoadedTopicMemberships else { return 0 }
        return sessions.lazy.filter { self.topicIdBySessionId[$0.id] == nil }.count
    }

    /// Files an unassigned Session. Home quick recordings already have a
    /// hidden technical owner, so they use the full resource-preserving move;
    /// truly legacy orphans use Core's atomic first-attachment contract.
    @discardableResult
    @MainActor
    func assignOrphanSession(
        _ sessionId: String,
        to notebookId: String,
        core: (any ZuTalkCoreProtocol)? = nil
    ) -> Bool {
        let storageOwner = storageNotebookIdBySessionId[sessionId]
        guard hasLoadedTopicMemberships,
              topicIdBySessionId[sessionId] == nil,
              storageOwner == nil || storageOwner == quickCaptureNotebookId,
              let target = researchNotebooks.first(where: { $0.id == notebookId }),
              let core = core ?? CoreClient.shared.core else {
            return false
        }
        guard isRecording(sessionId) == false else {
            ToastCenter.shared.info(String(localized: "home.recording.delete_while_recording"))
            return false
        }

        do {
            var transcriptProjectionDeferred = false
            if let storageOwner {
                try core.moveSessionToNotebook(
                    sessionId: sessionId,
                    targetNotebookId: notebookId
                )
                notebookSessionCounts[storageOwner] = max(
                    0,
                    (notebookSessionCounts[storageOwner] ?? 0) - 1
                )
            } else {
                let result = try core.assignOrphanSessionToNotebook(
                    sessionId: sessionId,
                    notebookId: notebookId
                )
                transcriptProjectionDeferred = result.transcriptProjectionDeferred
            }
            storageNotebookIdBySessionId[sessionId] = notebookId
            topicIdBySessionId[sessionId] = notebookId
            notebookSessionCounts[notebookId, default: 0] += 1
            NotificationCenter.default.post(name: .zutalkSessionUpdated, object: sessionId)
            ToastCenter.shared.success(
                String(localized: "home.row.assign.done"),
                detail: target.title
            )
            if transcriptProjectionDeferred {
                ToastCenter.shared.warning(
                    String(localized: "home.row.assign.projection_pending")
                )
            }
            return true
        } catch {
            Self.logger.error(
                "File orphan Session into Topic failed: \(String(describing: error), privacy: .private)"
            )
            ToastCenter.shared.error(String(localized: "home.row.assign.failed"))
            return false
        }
    }

    /// Notebook editor/history still needs its own scoped projection. Home's
    /// primary ledger uses `catalogGroupedSessions` instead.
    var activeNotebookGroupedSessions: [SessionGroup] {
        let filtered = searchText.isEmpty
            ? activeNotebookSessions
            : activeNotebookSessions.filter {
                $0.title.localizedCaseInsensitiveContains(searchText)
                    || $0.preview.localizedCaseInsensitiveContains(searchText)
            }
        return Self.groupSessions(filtered)
    }

    private var activeNotebookSessionIds: Set<String> {
        Set(notebookSessionLinks.map(\.sessionId))
            .union(notebookSessionProjections.map(\.sessionId))
    }

    @MainActor
    func loadNotebookWorkspace(client: (any NotebookWorkspaceClienting)? = nil) {
        let usesLiveCore = client == nil
        let client = client ?? LiveNotebookWorkspaceClient()
        var didLoadNotebookList = false
        do {
            let loadedNotebooks = try client.listNotebooks()
                .filter { $0.deletedAt == nil }
            let systemNotebooks: [FfiNotebook]
            if usesLiveCore {
                guard let core = CoreClient.shared.core else {
                    throw NotebookCaptureClientError.ffiUnavailable
                }
                systemNotebooks = [
                    try core.getQuickCaptureNotebook(),
                    try core.sharedInboxNotebook(),
                ].filter { $0.deletedAt == nil }
            } else {
                systemNotebooks = []
            }
            let discoveredQuickCaptureNotebookId = systemNotebooks.first?.id
            let loadedQuickCaptureNotebookId = discoveredQuickCaptureNotebookId
                ?? quickCaptureNotebookId
            didLoadNotebookList = true
            var loadedCounts: [String: Int] = [:]
            var loadedStorageNotebookIdBySessionId: [String: String] = [:]
            var storageNotebooks = loadedNotebooks
            for notebook in systemNotebooks
            where storageNotebooks.contains(where: { $0.id == notebook.id }) == false {
                storageNotebooks.append(notebook)
            }
            for notebook in storageNotebooks {
                // Membership links are the ownership fact. Tab projections are
                // rendered views and must not silently create a Topic relation.
                let links = try client.listNotebookSessions(notebookId: notebook.id)
                let sessionIds = Set(links.map(\.sessionId))
                loadedCounts[notebook.id] = sessionIds.count
                for sessionId in sessionIds {
                    loadedStorageNotebookIdBySessionId[sessionId] = notebook.id
                }
            }
            let loadedTopicIdBySessionId = Self.visibleTopicMemberships(
                storageMemberships: loadedStorageNotebookIdBySessionId,
                quickCaptureNotebookId: loadedQuickCaptureNotebookId
            )
            // Publish one coherent Topic snapshot. A failed membership read
            // keeps the last known catalogue instead of turning unknown into 0.
            notebooks = loadedNotebooks
            notebookSessionCounts = loadedCounts
            topicIdBySessionId = loadedTopicIdBySessionId
            storageNotebookIdBySessionId = loadedStorageNotebookIdBySessionId
            quickCaptureNotebookId = loadedQuickCaptureNotebookId
            hasLoadedTopicMemberships = true
            if let selectedTopicFilterId,
               selectedTopicFilterId != Self.unfiledTopicFilterId,
               researchNotebooks.contains(where: { $0.id == selectedTopicFilterId }) == false {
                self.selectedTopicFilterId = nil
            }
            let preferredNotebookId = activeNotebookId
                ?? notebookContext.activeNotebookId
            if let preferredNotebookId,
               loadedNotebooks.contains(where: { $0.id == preferredNotebookId }) {
                activeNotebookId = preferredNotebookId
            } else {
                activeNotebookId = loadedNotebooks.first?.id
            }
            try loadActiveNotebookDetails(client: client)
            publishActiveNotebookContext()
            notebookWorkspaceError = nil
        } catch {
            if notebooks.isEmpty {
                activeNotebookId = nil
            } else if activeNotebook == nil {
                activeNotebookId = notebooks.first?.id
            }
            clearActiveNotebookDetails()
            if didLoadNotebookList {
                publishActiveNotebookContext()
            }
            notebookWorkspaceError = String(localized: "home.workspace.load_failed")
            ToastCenter.shared.error(String(localized: "home.workspace.load_failed"))
        }
    }

    @MainActor
    func selectNotebook(_ notebookId: String, client: (any NotebookWorkspaceClienting)? = nil) {
        let client = client ?? LiveNotebookWorkspaceClient()
        guard notebooks.contains(where: { $0.id == notebookId }) else { return }
        activeNotebookId = notebookId
        do {
            try loadActiveNotebookDetails(client: client)
            publishActiveNotebookContext()
            notebookWorkspaceError = nil
        } catch {
            clearActiveNotebookDetails()
            publishActiveNotebookContext()
            notebookWorkspaceError = String(localized: "home.workspace.select_failed")
            ToastCenter.shared.error(String(localized: "home.workspace.select_failed"))
        }
    }

    @discardableResult
    @MainActor
    func selectNotebook(
        containingSession sessionId: String,
        client: (any NotebookWorkspaceClienting)? = nil
    ) -> Bool {
        let client = client ?? LiveNotebookWorkspaceClient()
        if activeNotebookSessionIds.contains(sessionId), let activeNotebookId {
            selectNotebook(activeNotebookId, client: client)
            return true
        }

        do {
            for notebook in notebooks {
                let links = try client.listNotebookSessions(notebookId: notebook.id)
                if links.contains(where: { $0.sessionId == sessionId }) {
                    selectNotebook(notebook.id, client: client)
                    return true
                }

                let tabs = try client.listNotebookTabs(notebookId: notebook.id)
                    .filter { $0.deletedAt == nil }
                for tab in tabs {
                    let projections = try client.listNotebookSessionProjections(tabId: tab.id)
                    if projections.contains(where: { $0.deletedAt == nil && $0.sessionId == sessionId }) {
                        selectNotebook(notebook.id, client: client)
                        return true
                    }
                }
            }
            notebookWorkspaceError = nil
            return false
        } catch {
            notebookWorkspaceError = String(localized: "home.workspace.resolve_failed")
            ToastCenter.shared.error(String(localized: "home.workspace.resolve_failed"))
            return false
        }
    }

    @discardableResult
    @MainActor
    func createNotebook(
        title: String,
        client: (any NotebookWorkspaceClienting)? = nil
    ) -> Bool {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedTitle.isEmpty == false else {
            ToastCenter.shared.warning(
                String(localized: "home.create.invalid_title"),
                detail: String(localized: "home.create.invalid_title.detail")
            )
            return false
        }
        guard normalizedTitle.count <= Self.notebookTitleMaxLength else {
            ToastCenter.shared.warning(
                String(localized: "home.create.title_too_long"),
                detail: String(
                    format: String(localized: "home.create.title_too_long.detail_format"),
                    Int64(Self.notebookTitleMaxLength)
                )
            )
            return false
        }

        let client = client ?? LiveNotebookWorkspaceClient()
        let notebook: FfiNotebook
        do {
            notebook = try client.createNotebook(title: normalizedTitle)
        } catch {
            notebookWorkspaceError = String(localized: "home.create.failed")
            ToastCenter.shared.error(String(localized: "home.create.failed"))
            return false
        }

        if let index = notebooks.firstIndex(where: { $0.id == notebook.id }) {
            notebooks[index] = notebook
        } else {
            notebooks.append(notebook)
        }
        notebookSessionCounts[notebook.id] = 0
        activeNotebookId = notebook.id

        do {
            try loadActiveNotebookDetails(client: client)
            notebookWorkspaceError = nil
        } catch {
            clearActiveNotebookDetails()
            notebookWorkspaceError = String(localized: "home.workspace.refresh_failed")
            ToastCenter.shared.warning(
                String(localized: "home.create.completed"),
                detail: String(localized: "home.workspace.refresh_failed")
            )
        }
        publishActiveNotebookContext()
        return true
    }

    @MainActor
    func loadSessions() {
        sessionLoadGeneration &+= 1
        let generation = sessionLoadGeneration
        sessionLoadError = nil

        guard let core = CoreClient.shared.core else {
            isLoadingSessions = false
            let message = String(localized: "home.recordings.load_failed")
            sessionLoadError = message
            ToastCenter.shared.error(message)
            return
        }

        isLoadingSessions = true
        Task { @MainActor [weak self, core] in
            let outcome = await Task.detached(priority: .userInitiated) {
                do {
                    let snapshot = try Self.loadCompleteSessionCatalog { limit, offset in
                        try core.querySessions(
                            sessionType: nil,
                            status: nil,
                            searchText: nil,
                            limit: limit,
                            offset: offset
                        )
                    }
                    return SessionCatalogQueryOutcome.success(
                        sessions: snapshot.sessions,
                        totalCount: snapshot.totalCount
                    )
                } catch {
                    return SessionCatalogQueryOutcome.failure(
                        message: String(describing: error)
                    )
                }
            }.value

            guard let self, self.sessionLoadGeneration == generation else { return }
            self.isLoadingSessions = false

            switch outcome {
            case .success(let loadedSessions, let loadedTotalCount):
                self.sessionLoadError = nil
                self.sessions = Self.attachTranscriptDocumentStatus(
                    to: loadedSessions.map(Self.makeListItem),
                    core: core
                )
                self.rebuildGroups()
                self.totalCount = Int(clamping: loadedTotalCount)
                if self.selectedId == nil {
                    self.selectedId = self.sessions.first?.id
                }
            case .failure(let message):
                Self.logger.error(
                    "Load Home recordings failed: \(message, privacy: .private)"
                )
                let displayMessage = String(localized: "home.recordings.load_failed")
                self.sessionLoadError = displayMessage
                ToastCenter.shared.error(displayMessage)
            }
        }
    }

    /// Loads one coherent catalogue snapshot in bounded pages. The store uses
    /// a deterministic `(sort field, id)` order; this layer still rejects
    /// duplicate/no-progress pages and a total that changes mid-read rather
    /// than publishing a partial ledger as complete.
    nonisolated static func loadCompleteSessionCatalog(
        pageSize: UInt32 = 200,
        queryPage: (UInt32, UInt32) throws -> SessionQueryResultInfo
    ) throws -> (sessions: [SessionInfo], totalCount: UInt64) {
        guard pageSize > 0 else { throw SessionCatalogLoadError.invalidPageSize }

        var offset: UInt32 = 0
        var loadedSessions: [SessionInfo] = []
        var seenSessionIds: Set<String> = []
        var expectedTotal: UInt64?

        repeat {
            let page = try queryPage(pageSize, offset)
            if let expectedTotal {
                guard page.totalCount == expectedTotal else {
                    throw SessionCatalogLoadError.snapshotChanged(
                        expected: expectedTotal,
                        actual: page.totalCount
                    )
                }
            } else {
                expectedTotal = page.totalCount
            }

            let uniquePage = page.sessions.filter {
                seenSessionIds.insert($0.id).inserted
            }
            loadedSessions.append(contentsOf: uniquePage)

            let expected = expectedTotal ?? 0
            let actual = UInt64(loadedSessions.count)
            guard actual <= expected else {
                throw SessionCatalogLoadError.incomplete(expected: expected, actual: actual)
            }
            if actual == expected { break }
            guard page.sessions.isEmpty == false else {
                throw SessionCatalogLoadError.incomplete(expected: expected, actual: actual)
            }
            guard uniquePage.isEmpty == false else {
                throw SessionCatalogLoadError.stalled(offset: offset)
            }

            let increment = UInt32(page.sessions.count)
            guard UInt32.max - offset >= increment else {
                throw SessionCatalogLoadError.incomplete(expected: expected, actual: actual)
            }
            offset += increment
        } while true

        return (loadedSessions, expectedTotal ?? 0)
    }

    @MainActor
    private static func attachTranscriptDocumentStatus(
        to items: [SessionListItem],
        core: ZuTalkCore
    ) -> [SessionListItem] {
        let transcriptionTasksBySessionId = TranscriptionTaskIndex.load(core: core)
        return items.map { item in
            var updated = item
            updated.transcriptDocumentStatus = homeTranscriptStatus(
                from: transcriptionTasksBySessionId[item.id]
            )
            return updated
        }
    }

    static func homeTranscriptStatus(from task: TranscriptionTaskSnapshot?) -> String? {
        guard let task else { return nil }
        switch task.tabStatus {
        case .pending: return "pending"
        case .ready: return "ready"
        case .failed: return "failed"
        case .live: return nil
        }
    }

    @MainActor
    private func loadActiveNotebookDetails(client: any NotebookWorkspaceClienting) throws {
        guard let activeNotebookId else {
            clearActiveNotebookDetails()
            return
        }

        let tabs = try client.listNotebookTabs(notebookId: activeNotebookId)
            .filter { $0.deletedAt == nil }
            .sorted { lhs, rhs in
                if lhs.position == rhs.position {
                    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }
                return lhs.position < rhs.position
            }
        notebookTabs = tabs
        notebookSessionLinks = try client.listNotebookSessions(notebookId: activeNotebookId)
        notebookSessionProjections = try tabs.flatMap { tab in
            try client.listNotebookSessionProjections(tabId: tab.id)
                .filter { $0.deletedAt == nil }
        }
    }

    @MainActor
    private func publishActiveNotebookContext() {
        if let activeNotebook {
            notebookContext.updateActiveNotebook(
                id: activeNotebook.id,
                title: activeNotebook.title
            )
        } else {
            notebookContext.forgetLastNotebook()
        }
    }

    private func clearActiveNotebookDetails() {
        notebookTabs = []
        notebookSessionLinks = []
        notebookSessionProjections = []
    }

    private func removeSessionsFromTopicCatalog(_ sessionIds: Set<String>) {
        for sessionId in sessionIds {
            topicIdBySessionId.removeValue(forKey: sessionId)
            guard let topicId = storageNotebookIdBySessionId.removeValue(
                forKey: sessionId
            ) else {
                continue
            }
            notebookSessionCounts[topicId] = max(
                0,
                (notebookSessionCounts[topicId] ?? 0) - 1
            )
        }
    }

    @MainActor
    private func cancelPendingSessionLoad() {
        sessionLoadGeneration &+= 1
        isLoadingSessions = false
    }

    /// Import an audio file into the active Notebook while preserving Notebook
    /// ownership and making the new session available to all three builtin tabs.
    @MainActor
    func importAudioIntoActiveNotebook(
        at url: URL,
        client: (any NotebookWorkspaceClienting)? = nil,
        importer: (any NotebookAudioImporting)? = nil
    ) {
        guard let notebookId = activeNotebookId else {
            ToastCenter.shared.warning(
                String(localized: "home.import.no_notebook"),
                detail: String(localized: "home.import.no_notebook.detail")
            )
            return
        }

        guard isImportingAudio == false else {
            ToastCenter.shared.warning(
                String(localized: "home.import.already_running"),
                detail: String(localized: "home.import.already_running.detail")
            )
            return
        }

        let workspaceClient = client ?? LiveNotebookWorkspaceClient()
        let audioImporter: any NotebookAudioImporting
        if let importer {
            audioImporter = importer
        } else {
            guard let core = CoreClient.shared.core else {
                let message = String(localized: "home.import.failed.detail")
                audioImportError = message
                ToastCenter.shared.error(
                    String(localized: "home.import.failed"),
                    detail: message
                )
                return
            }
            audioImporter = LiveNotebookAudioImporter(core: core)
        }

        let path = url.path
        isImportingAudio = true
        audioImportError = nil
        ToastCenter.shared.info(
            String(localized: "home.import.in_progress"),
            detail: url.lastPathComponent
        )

        Task { @MainActor [weak self] in
            let outcome: NotebookAudioImportOutcome = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        continuation.resume(returning: .success(
                            try audioImporter.importAudioIntoNotebook(
                                path: path,
                                notebookId: notebookId
                            )
                        ))
                    } catch {
                        Self.logger.error(
                            "Notebook audio import failed: \(String(describing: error), privacy: .private)"
                        )
                        continuation.resume(returning: .failure)
                    }
                }
            }

            guard let self else { return }
            self.isImportingAudio = false

            switch outcome {
            case .success(let result):
                self.selectedId = result.sessionId
                self.audioImportError = nil
                do {
                    try self.loadActiveNotebookDetails(client: workspaceClient)
                    self.notebookWorkspaceError = nil
                } catch {
                    let message = String(localized: "home.workspace.refresh_failed")
                    self.notebookWorkspaceError = message
                    ToastCenter.shared.warning(
                        String(localized: "home.import.completed"),
                        detail: message
                    )
                }
                NotificationCenter.default.post(
                    name: .zutalkSessionUpdated,
                    object: result.sessionId
                )
                ToastCenter.shared.success(
                    String(localized: "home.import.completed"),
                    detail: "\(result.sourceFormat) · \(result.durationMs / 1000)s"
                )
                MainNavigationStore.shared.openSession(result.sessionId)
            case .failure:
                let message = String(localized: "home.import.failed.detail")
                self.audioImportError = message
                ToastCenter.shared.error(
                    String(localized: "home.import.failed"),
                    detail: message
                )
            }
        }
    }

    @MainActor
    func search() { updateTranscriptSearch() }

    /// 把 FFI 层的 SessionInfo 映射为 UI 用的 SessionListItem
    @MainActor
    static func makeListItem(_ info: SessionInfo) -> SessionListItem {
        let createdAt = Date(timeIntervalSince1970: TimeInterval(info.createdAtUnixMs) / 1000)
        // Keep the persisted title truthful. Presentation decides how an
        // untitled Session is named; exposing an ID here made internal storage
        // details compete with the timestamp, which is the primary identifier.
        let displayTitle = info.title

        var badges: [SessionBadge] = []
        switch info.sessionType {
        case "import":
            badges.append(SessionBadge(label: "IMPORT", color: Color.signalAmber))
        default:
            break
        }
        if !info.hasEncryptedAudio {
            badges.append(SessionBadge(label: "AUDIO DELETED", color: Color.signalRed))
        }

        return SessionListItem(
            id: info.id,
            title: displayTitle,
            timeString: Self.timeFormatter.string(from: createdAt),
            durationString: Self.formatDuration(ms: info.durationMs),
            durationMs: info.durationMs,
            languagePair: Self.formatLanguagePair(
                source: info.sourceLanguage,
                targets: info.targetLanguages
            ),
            badges: badges,
            createdAt: createdAt,
            sessionType: info.sessionType,
            hasEncryptedAudio: info.hasEncryptedAudio,
            preview: info.preview,
            rawStatus: info.status
        )
    }

    nonisolated static func formatDuration(ms: UInt64) -> String {
        let totalSec = ms / 1000
        let h = totalSec / 3600
        let m = (totalSec % 3600) / 60
        let s = totalSec % 60
        if h > 0 {
            return String(format: "%02d:%02d:%02d", h, m, s)
        } else {
            return String(format: "%02d:%02d", m, s)
        }
    }

    /// 格式化语言显示：录音所选语言等权时用点分隔；旧的明确源/目标数据
    /// 仍保留双向或单向箭头。
    nonisolated static func formatLanguagePair(source: String, targets: [String]) -> String {
        let src = source.isEmpty ? "" : source.uppercased()
        let abbreviated = targets.map(Self.abbreviateLanguage)

        if src.isEmpty && abbreviated.isEmpty { return "—" }
        if src.isEmpty { return abbreviated.joined(separator: " · ") }
        if abbreviated.isEmpty { return src }
        if abbreviated.count == 1 { return "\(src) ↔ \(abbreviated[0])" }
        return "\(src) → \(abbreviated.joined(separator: ","))"
    }

    nonisolated private static func abbreviateLanguage(_ code: String) -> String {
        let normalized = code.lowercased()
        switch normalized {
        case "zh-cn", "zh-hans", "zh": return "中"
        case "zh-tw", "zh-hant":       return "繁"
        case "ja", "jp":                return "日"
        case "ko":                      return "韩"
        case "en":                      return "EN"
        case "es":                      return "ES"
        case "fr":                      return "FR"
        case "de":                      return "DE"
        case "ru":                      return "RU"
        case "it":                      return "IT"
        case "pt":                      return "PT"
        default:                        return code.uppercased()
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    func toggleFilter() {
        // Filter sheet UI pending
    }

    private func rebuildGroups() {
        let filtered = searchText.isEmpty
            ? sessions
            : sessions.filter { $0.title.localizedCaseInsensitiveContains(searchText) }

        groupedSessions = Self.groupSessions(filtered)
        totalCount = filtered.count
    }

    private static func groupSessions(_ sessions: [SessionListItem]) -> [SessionGroup] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!

        var todayList: [SessionListItem] = []
        var yesterdayList: [SessionListItem] = []
        var olderByDay: [Date: [SessionListItem]] = [:]

        for s in sessions {
            let day = calendar.startOfDay(for: s.createdAt)
            if day == today {
                todayList.append(s)
            } else if day == yesterday {
                yesterdayList.append(s)
            } else {
                olderByDay[day, default: []].append(s)
            }
        }

        var groups: [SessionGroup] = []
        if !todayList.isEmpty { groups.append(SessionGroup(label: String(localized: "library.group.today"), sessions: todayList)) }
        if !yesterdayList.isEmpty { groups.append(SessionGroup(label: String(localized: "library.group.yesterday"), sessions: yesterdayList)) }

        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        for (day, list) in olderByDay.sorted(by: { $0.key > $1.key }) {
            groups.append(SessionGroup(label: formatter.string(from: day), sessions: list))
        }

        return groups
    }
}
