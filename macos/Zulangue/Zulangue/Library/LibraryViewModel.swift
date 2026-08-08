// LibraryViewModel.swift
// HomeView 用的 session 列表数据层 + Models。
//
// HomeView 使用的 session 数据类型与查询逻辑。

import SwiftUI
import Combine
import OSLog

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
    case failed
    case completed
    case imported
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
        if normalizedStatus == "failed" || transcriptDocumentStatus == "failed" {
            return .failed
        }
        if transcriptDocumentStatus == "pending" {
            return .transcribing
        }
        if normalizedStatus == "completed", durationMs > 0 {
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
    static let notebookTitleMaxLength = 120
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "xyz.voice.zulangue",
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
    @Published var notebookWorkspaceError: String?
    @Published private(set) var isImportingAudio = false
    @Published private(set) var audioImportError: String?

    private let notebookContext: NotebookSessionContextStore

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
            sessions.removeAll { $0.id == id }
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
            sessions.removeAll { selectedIds.contains($0.id) }
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

    var requiresNotebookBeforeRecording: Bool {
        notebooks.isEmpty
    }

    var activeNotebookSessions: [SessionListItem] {
        let sessionIds = activeNotebookSessionIds
        guard sessionIds.isEmpty == false else { return [] }
        return sessions.filter { sessionIds.contains($0.id) }
    }

    /// Home is scoped to the selected Notebook. Search must never make the
    /// current-Notebook header control a global session list by accident.
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
        let client = client ?? LiveNotebookWorkspaceClient()
        var didLoadNotebookList = false
        do {
            let loadedNotebooks = try client.listNotebooks()
                .filter { $0.deletedAt == nil }
            didLoadNotebookList = true
            notebooks = loadedNotebooks
            notebookSessionCounts = Dictionary(
                uniqueKeysWithValues: loadedNotebooks.map { notebook in
                    let links = (try? client.listNotebookSessions(notebookId: notebook.id)) ?? []
                    return (notebook.id, Set(links.map(\.sessionId)).count)
                }
            )
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
        guard let core = CoreClient.shared.core else {
            ToastCenter.shared.error(String(localized: "home.recordings.load_failed"))
            sessions = []
            rebuildGroups()
            return
        }

        do {
            let result = try core.querySessions(
                sessionType: nil,
                status: nil,
                searchText: searchText.isEmpty ? nil : searchText,
                limit: 200,
                offset: 0
            )
            sessions = Self.attachTranscriptDocumentStatus(
                to: result.sessions.map(Self.makeListItem),
                core: core
            )
            rebuildGroups()
            if selectedId == nil {
                selectedId = sessions.first?.id
            }
        } catch {
            Self.logger.error(
                "Load Home recordings failed: \(String(describing: error), privacy: .private)"
            )
            ToastCenter.shared.error(String(localized: "home.recordings.load_failed"))
            sessions = []
            rebuildGroups()
        }
    }

    @MainActor
    private static func attachTranscriptDocumentStatus(
        to items: [SessionListItem],
        core: ZulangueCore
    ) -> [SessionListItem] {
        let transcriptionTasksBySessionId = TranscriptionTaskIndex.load(core: core)
        return items.map { item in
            guard item.preview.isEmpty else { return item }
            guard item.rawStatus.lowercased() == "completed" else { return item }

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
                    name: .zulangueSessionUpdated,
                    object: result.sessionId
                )
                ToastCenter.shared.success(
                    String(localized: "home.import.completed"),
                    detail: "\(result.sourceFormat) · \(result.durationMs / 1000)s"
                )
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
    func search() { loadSessions() }

    /// 把 FFI 层的 SessionInfo 映射为 UI 用的 SessionListItem
    @MainActor
    static func makeListItem(_ info: SessionInfo) -> SessionListItem {
        let createdAt = Date(timeIntervalSince1970: TimeInterval(info.createdAtUnixMs) / 1000)
        let displayTitle = info.title.isEmpty
            ? "Session \(info.id.prefix(8))"
            : info.title

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
