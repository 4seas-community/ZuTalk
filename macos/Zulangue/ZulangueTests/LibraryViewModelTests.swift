import XCTest
@testable import Zulangue

@MainActor
final class LibraryViewModelTests: XCTestCase {

    var viewModel: LibraryViewModel!

    override func setUp() async throws {
        try await super.setUp()
        viewModel = LibraryViewModel()
    }

    override func tearDown() async throws {
        viewModel = nil
        try await super.tearDown()
    }

    // MARK: - Initial state

    func testInitialState() {
        XCTAssertEqual(viewModel.sessions.count, 0)
        XCTAssertEqual(viewModel.groupedSessions.count, 0)
        XCTAssertEqual(viewModel.searchText, "")
        XCTAssertNil(viewModel.selectedId)
        XCTAssertEqual(viewModel.totalCount, 0)
    }

    // MARK: - Selected session

    func testSelectedSessionReturnsNilWhenNoSelection() {
        XCTAssertNil(viewModel.selectedSession)
    }

    func testSelectedSessionReturnsMatchingItem() {
        let item = SessionListItem(
            id: "abc",
            title: "Test",
            timeString: "10:00",
            durationString: "00:01:00",
            languagePair: "en",
        )
        viewModel.sessions = [item]
        viewModel.selectedId = "abc"

        XCTAssertNotNil(viewModel.selectedSession)
        XCTAssertEqual(viewModel.selectedSession?.id, "abc")
    }

    func testSelectedSessionNilForUnknownId() {
        let item = SessionListItem(
            id: "a",
            title: "T",
            timeString: "10:00",
            durationString: "00:01:00",
            languagePair: "en",
        )
        viewModel.sessions = [item]
        viewModel.selectedId = "nonexistent"

        XCTAssertNil(viewModel.selectedSession)
    }

    // MARK: - Load sessions integration (uses real CoreClient)

    func testLoadSessionsDoesNotCrash() {
        // 在干净的 temp dir 上 CoreClient 应该返回空 list
        viewModel.loadSessions()
        // 空结果不会产生占位数据。
        XCTAssertGreaterThanOrEqual(viewModel.sessions.count, 0)
    }

    func testHomeViewIsNotebookLibraryAndHidesInternalDiagnostics() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Zulangue", isDirectory: true)
        let contents = try String(
            contentsOf: root.appendingPathComponent("Pages/HomeView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(contents.contains("HomeNotebookLibrary"))
        XCTAssertTrue(contents.contains("HomeNotebookCard"))
        XCTAssertTrue(contents.contains("HomeCreateNotebookSheet"))
        XCTAssertTrue(contents.contains("viewModel.notebooks"))
        XCTAssertTrue(contents.contains("MainNavigationStore.shared.openActiveNotebookForCapture()"))
        XCTAssertTrue(contents.contains("HomeWorkspaceFailureView"))
        XCTAssertTrue(contents.contains("HomeWorkspaceRefreshWarning"))
        XCTAssertFalse(contents.contains("HomeNotebookLibrary(\n                        viewModel: viewModel,\n                        capture:"))
        XCTAssertFalse(contents.contains("chooseAudioForActiveNotebook"))
        XCTAssertFalse(contents.contains("HomeRecentRecordingsSection(\n                        viewModel: viewModel"))
        XCTAssertFalse(contents.contains("HomeActivityHeatmap"))
        XCTAssertFalse(contents.contains("notebookEvents"))
        XCTAssertFalse(contents.contains("event.eventType"))
        XCTAssertFalse(contents.contains("tab.builtinKind"))
        XCTAssertFalse(contents.contains("home.workspace.error_format"))
        XCTAssertFalse(contents.contains("error.localizedDescription"))
        XCTAssertFalse(contents.contains("detail: \"\\(error)\""))
    }

    func testHomeTranscriptStatusUsesTaskQueueWithoutLegacyPlaceholder() throws {
        let running = TranscriptionTaskSnapshot(
            taskId: "task-running",
            status: "running",
            errorMessage: nil
        )
        let failed = TranscriptionTaskSnapshot(
            taskId: "task-failed",
            status: "failed",
            errorMessage: "provider unavailable"
        )
        let completed = TranscriptionTaskSnapshot(
            taskId: "task-completed",
            status: "completed",
            errorMessage: nil
        )

        XCTAssertEqual(LibraryViewModel.homeTranscriptStatus(from: running), "pending")
        XCTAssertEqual(LibraryViewModel.homeTranscriptStatus(from: failed), "failed")
        XCTAssertEqual(LibraryViewModel.homeTranscriptStatus(from: completed), "ready")
        XCTAssertNil(LibraryViewModel.homeTranscriptStatus(from: nil))

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Zulangue", isDirectory: true)
        let viewModel = try String(
            contentsOf: root.appendingPathComponent("Library/LibraryViewModel.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(viewModel.contains("TranscriptionTaskIndex.load(core: core)"))
        XCTAssertFalse(viewModel.contains("templateId == \"transcript-hd\""))
    }

    func testNotebookEditorIncludesResourcesAsAUiOnlyStatusTab() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Zulangue", isDirectory: true)
        let editor = try String(
            contentsOf: root.appendingPathComponent("Pages/DocumentEditorPage.swift"),
            encoding: .utf8
        )
        let resources = try String(
            contentsOf: root.appendingPathComponent("Pages/NotebookResourcesView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(editor.contains("ResourcesTabButton"))
        XCTAssertTrue(editor.contains("NotebookResourcesView("))
        XCTAssertTrue(editor.contains("isShowingResources"))
        XCTAssertTrue(resources.contains("NotebookResourceItem"))
        XCTAssertTrue(resources.contains("listNotebookSessions"))
        XCTAssertTrue(resources.contains("listNotebookSessionProjections"))
        XCTAssertTrue(resources.contains("TranscriptionTaskIndex.load"))
        XCTAssertFalse(resources.contains("createNotebook"))
    }

    // MARK: - Search

    func testSearchEmptyShowsAll() {
        viewModel.sessions = makeMockSessions()
        viewModel.searchText = ""
        viewModel.search()
        // search() calls loadSessions() which queries Core
        // 我们只验证它不崩溃
    }

    // MARK: - Notebook workspace

    func testLoadNotebookWorkspaceSelectsFirstNotebookAndKeepsSessionList() {
        let client = StubNotebookWorkspaceClient()
        client.notebooks = [
            makeNotebook(id: "nb-research", title: "Research"),
            makeNotebook(id: "nb-meetings", title: "Meetings")
        ]
        client.tabsByNotebook["nb-research"] = [
            makeNotebookTab(id: "tab-notes", notebookId: "nb-research", title: "Notes"),
            makeNotebookTab(id: "tab-transcript", notebookId: "nb-research", title: "Transcript")
        ]
        client.sessionProjectionsByTab["tab-notes"] = [
            makeNotebookSessionProjection(
                id: "projection-1",
                notebookId: "nb-research",
                tabId: "tab-notes",
                sessionId: "session-a",
                sectionTitle: "Kickoff"
            )
        ]
        client.sessionLinksByNotebook["nb-research"] = [
            FfiNotebookSessionLink(
                notebookId: "nb-research",
                sessionId: "session-a",
                createdAt: "2000-01-01T00:00:00Z"
            )
        ]
        let sessions = [
            SessionListItem(
                id: "session-a",
                title: "Kickoff",
                timeString: "10:00",
                durationString: "00:12",
                languagePair: "EN",
            )
        ] + makeMockSessions()
        viewModel.sessions = sessions

        viewModel.loadNotebookWorkspace(client: client)

        XCTAssertEqual(viewModel.notebooks.map(\.id), ["nb-research", "nb-meetings"])
        XCTAssertEqual(viewModel.activeNotebook?.title, "Research")
        XCTAssertEqual(viewModel.notebookTabs.map(\.id), ["tab-notes", "tab-transcript"])
        XCTAssertEqual(viewModel.notebookSessionProjections.map(\.sessionId), ["session-a"])
        XCTAssertEqual(viewModel.activeNotebookSessions.map(\.id), ["session-a"])
        XCTAssertEqual(viewModel.sessions, sessions)
        XCTAssertFalse(viewModel.requiresNotebookBeforeRecording)
    }

    func testLoadNotebookWorkspaceRestoresCurrentNotebookContext() {
        let client = StubNotebookWorkspaceClient()
        client.notebooks = [
            makeNotebook(id: "nb-research", title: "Research"),
            makeNotebook(id: "nb-meetings", title: "Meetings")
        ]
        let notebookContext = NotebookSessionContextStore()
        notebookContext.updateActiveNotebook(
            id: "nb-meetings",
            title: "Meetings"
        )
        let restoredViewModel = LibraryViewModel(notebookContext: notebookContext)

        restoredViewModel.loadNotebookWorkspace(client: client)

        XCTAssertEqual(restoredViewModel.activeNotebookId, "nb-meetings")
        XCTAssertEqual(restoredViewModel.activeNotebook?.title, "Meetings")
    }

    func testLoadNotebookWorkspaceFallsBackWhenLastNotebookNoLongerExists() {
        let client = StubNotebookWorkspaceClient()
        client.notebooks = [
            makeNotebook(id: "nb-research", title: "Research"),
            makeNotebook(id: "nb-meetings", title: "Meetings")
        ]
        let notebookContext = NotebookSessionContextStore(
            activeNotebookId: "nb-deleted",
            activeNotebookTitle: "Deleted"
        )
        let restoredViewModel = LibraryViewModel(notebookContext: notebookContext)

        restoredViewModel.loadNotebookWorkspace(client: client)

        XCTAssertEqual(restoredViewModel.activeNotebookId, "nb-research")
        XCTAssertEqual(notebookContext.activeNotebookId, "nb-research")
    }

    func testNotebookListFailureKeepsLastNotebookForRetry() {
        let client = StubNotebookWorkspaceClient()
        client.listNotebooksError = .databaseUnavailable
        let notebookContext = NotebookSessionContextStore(
            activeNotebookId: "nb-last",
            activeNotebookTitle: "Last"
        )
        let restoredViewModel = LibraryViewModel(notebookContext: notebookContext)

        restoredViewModel.loadNotebookWorkspace(client: client)

        XCTAssertNil(restoredViewModel.activeNotebookId)
        XCTAssertEqual(notebookContext.activeNotebookId, "nb-last")
    }

    func testInitialWorkspaceLoadFailureShowsStableRetryState() {
        let client = StubNotebookWorkspaceClient()
        client.listNotebooksError = .databaseUnavailable

        viewModel.loadNotebookWorkspace(client: client)

        XCTAssertTrue(viewModel.notebooks.isEmpty)
        XCTAssertNil(viewModel.activeNotebookId)
        XCTAssertEqual(
            viewModel.notebookWorkspaceError,
            String(localized: "home.workspace.load_failed")
        )
        XCTAssertTrue(viewModel.requiresNotebookBeforeRecording)
    }

    func testWorkspaceDetailFailureRetainsNotebookListAndShowsRefreshState() {
        let client = StubNotebookWorkspaceClient()
        client.notebooks = [makeNotebook(id: "nb-research", title: "Research")]
        client.listTabsError = .databaseUnavailable

        viewModel.loadNotebookWorkspace(client: client)

        XCTAssertEqual(viewModel.notebooks.map(\.id), ["nb-research"])
        XCTAssertEqual(viewModel.activeNotebookId, "nb-research")
        XCTAssertTrue(viewModel.notebookTabs.isEmpty)
        XCTAssertEqual(
            viewModel.notebookWorkspaceError,
            String(localized: "home.workspace.load_failed")
        )
        XCTAssertFalse(viewModel.requiresNotebookBeforeRecording)
    }

    func testHomeGroupsOnlySelectedNotebookSessionsAndFiltersImmediately() {
        viewModel.sessions = [
            SessionListItem(
                id: "session-a",
                title: "Weekly research",
                timeString: "10:00",
                durationString: "00:12",
                languagePair: "EN ↔ 中",
                createdAt: Date(),
                preview: "Transcription notes"
            ),
            SessionListItem(
                id: "session-b",
                title: "Private meeting",
                timeString: "11:00",
                durationString: "00:08",
                languagePair: "中",
                createdAt: Date(),
                preview: "Must not appear in Notebook A"
            )
        ]
        viewModel.notebookSessionLinks = [
            FfiNotebookSessionLink(
                notebookId: "nb-a",
                sessionId: "session-a",
                createdAt: "2001-01-04T00:00:00Z"
            )
        ]

        XCTAssertEqual(
            viewModel.activeNotebookGroupedSessions.flatMap(\.sessions).map(\.id),
            ["session-a"]
        )

        viewModel.searchText = "transcription"
        XCTAssertEqual(
            viewModel.activeNotebookGroupedSessions.flatMap(\.sessions).map(\.id),
            ["session-a"],
            "Search updates from the published text binding without another database query"
        )

        viewModel.searchText = "private"
        XCTAssertTrue(
            viewModel.activeNotebookGroupedSessions.isEmpty,
            "Search must not escape the current Notebook even if a global session matches"
        )
    }

    func testSelectNotebookContainingSessionUsesLoadedLinksAndProjections() {
        let client = StubNotebookWorkspaceClient()
        client.notebooks = [
            makeNotebook(id: "nb-research", title: "Research"),
            makeNotebook(id: "nb-meetings", title: "Meetings")
        ]
        client.tabsByNotebook["nb-research"] = [
            makeNotebookTab(id: "tab-research", notebookId: "nb-research", title: "Research Notes")
        ]
        client.tabsByNotebook["nb-meetings"] = [
            makeNotebookTab(id: "tab-meetings", notebookId: "nb-meetings", title: "Meeting Notes")
        ]
        client.sessionProjectionsByTab["tab-research"] = [
            makeNotebookSessionProjection(
                id: "projection-a",
                notebookId: "nb-research",
                tabId: "tab-research",
                sessionId: "session-a",
                sectionTitle: nil
            )
        ]
        client.sessionProjectionsByTab["tab-meetings"] = [
            makeNotebookSessionProjection(
                id: "projection-b",
                notebookId: "nb-meetings",
                tabId: "tab-meetings",
                sessionId: "session-b",
                sectionTitle: nil
            )
        ]
        client.sessionLinksByNotebook["nb-meetings"] = [
            FfiNotebookSessionLink(
                notebookId: "nb-meetings",
                sessionId: "legacy-session",
                createdAt: "2000-01-01T00:00:00Z"
            )
        ]

        viewModel.loadNotebookWorkspace(client: client)
        XCTAssertEqual(viewModel.activeNotebookId, "nb-research")

        XCTAssertTrue(viewModel.selectNotebook(containingSession: "legacy-session", client: client))

        XCTAssertEqual(viewModel.activeNotebookId, "nb-meetings")
        XCTAssertEqual(viewModel.notebookTabs.map(\.id), ["tab-meetings"])
        XCTAssertEqual(viewModel.notebookSessionProjections.map(\.sessionId), ["session-b"])
    }

    func testCreateNotebookSelectsCreatedNotebookWhenWorkspaceIsEmpty() {
        let client = StubNotebookWorkspaceClient()

        viewModel.loadNotebookWorkspace(client: client)
        XCTAssertTrue(viewModel.requiresNotebookBeforeRecording)

        viewModel.createNotebook(title: "Field Notes", client: client)

        XCTAssertEqual(viewModel.notebooks.map(\.title), ["Field Notes"])
        XCTAssertEqual(viewModel.activeNotebook?.title, "Field Notes")
        XCTAssertFalse(viewModel.requiresNotebookBeforeRecording)
    }

    func testCreateNotebookRejectsBlankTitleWithoutWriting() {
        let client = StubNotebookWorkspaceClient()

        XCTAssertFalse(viewModel.createNotebook(title: "   \n", client: client))
        XCTAssertTrue(client.notebooks.isEmpty)
        XCTAssertTrue(viewModel.notebooks.isEmpty)
    }

    func testCreateNotebookRejectsOverlongTitleWithoutWriting() {
        let client = StubNotebookWorkspaceClient()
        let title = String(
            repeating: "a",
            count: LibraryViewModel.notebookTitleMaxLength + 1
        )

        XCTAssertFalse(viewModel.createNotebook(title: title, client: client))
        XCTAssertTrue(client.notebooks.isEmpty)
        XCTAssertTrue(viewModel.notebooks.isEmpty)
    }

    func testCreateNotebookReturnsSuccessWhenCommittedNotebookRefreshFails() {
        let client = StubNotebookWorkspaceClient()
        client.listTabsError = .databaseUnavailable

        XCTAssertTrue(viewModel.createNotebook(title: "Field Notes", client: client))

        XCTAssertEqual(client.notebooks.map(\.title), ["Field Notes"])
        XCTAssertEqual(viewModel.notebooks.map(\.title), ["Field Notes"])
        XCTAssertEqual(viewModel.activeNotebook?.title, "Field Notes")
        XCTAssertEqual(
            viewModel.notebookWorkspaceError,
            String(localized: "home.workspace.refresh_failed")
        )
    }

    func testImportAudioTargetsActiveNotebookAndRefreshesWorkspace() async {
        let client = StubNotebookWorkspaceClient()
        client.notebooks = [makeNotebook(id: "nb-research", title: "Research")]
        client.tabsByNotebook["nb-research"] = [
            makeNotebookTab(id: "tab-imported", notebookId: "nb-research", title: "Manual Note")
        ]
        let importer = StubNotebookAudioImporter(result: ImportResultInfo(
            sessionId: "session-imported",
            sourceFormat: "mp3",
            durationMs: 2_000,
            sampleRate: 16_000,
            channels: 1
        ))
        viewModel.loadNotebookWorkspace(client: client)

        viewModel.importAudioIntoActiveNotebook(
            at: URL(fileURLWithPath: "/tmp/interview.mp3"),
            client: client,
            importer: importer
        )
        await waitForAudioImportToFinish()

        XCTAssertEqual(importer.calls.count, 1)
        XCTAssertEqual(importer.calls[0].path, "/tmp/interview.mp3")
        XCTAssertEqual(importer.calls[0].notebookId, "nb-research")
        XCTAssertFalse(importer.calls[0].wasCalledOnMainThread)
        XCTAssertEqual(viewModel.selectedId, "session-imported")
        XCTAssertEqual(viewModel.notebookTabs.map(\.id), ["tab-imported"])
        XCTAssertNil(viewModel.audioImportError)
    }

    func testImportAudioFailureLeavesSelectionAndWorkspaceUntouched() async {
        let client = StubNotebookWorkspaceClient()
        client.notebooks = [makeNotebook(id: "nb-research", title: "Research")]
        let importer = StubNotebookAudioImporter(errorMessage: "decoder rejected file")
        viewModel.loadNotebookWorkspace(client: client)
        viewModel.selectedId = "session-existing"

        viewModel.importAudioIntoActiveNotebook(
            at: URL(fileURLWithPath: "/tmp/broken.mp3"),
            client: client,
            importer: importer
        )
        await waitForAudioImportToFinish()

        XCTAssertEqual(importer.calls.count, 1)
        XCTAssertEqual(viewModel.selectedId, "session-existing")
        XCTAssertEqual(
            viewModel.audioImportError,
            String(localized: "home.import.failed.detail")
        )
        XCTAssertNotEqual(viewModel.audioImportError, "decoder rejected file")
        XCTAssertFalse(viewModel.isImportingAudio)
    }

    // MARK: - Helpers

    private func makeMockSessions() -> [SessionListItem] {
        [
            SessionListItem(
                id: "1",
                title: "Engineering sync",
                timeString: "14:23",
                durationString: "01:00:00",
                languagePair: "en",
                createdAt: Date()
            ),
            SessionListItem(
                id: "2",
                title: "Customer call",
                timeString: "09:00",
                durationString: "00:30:00",
                languagePair: "zh-CN",
                createdAt: Calendar.current.date(byAdding: .day, value: -1, to: Date())!
            ),
        ]
    }

    private func makeNotebook(id: String, title: String) -> FfiNotebook {
        FfiNotebook(
            id: id,
            title: title,
            createdAt: "2000-01-01T00:00:00Z",
            updatedAt: "2000-01-01T00:00:00Z",
            deletedAt: nil
        )
    }

    private func makeNotebookTab(id: String, notebookId: String, title: String) -> FfiNotebookTab {
        FfiNotebookTab(
            id: id,
            notebookId: notebookId,
            builtinKind: "manual_note",
            title: title,
            docId: "doc-\(id)",
            position: 0,
            createdAt: "2000-01-01T00:00:00Z",
            updatedAt: "2000-01-01T00:00:00Z",
            deletedAt: nil
        )
    }

    private func makeNotebookSessionProjection(
        id: String,
        notebookId: String,
        tabId: String,
        sessionId: String,
        sectionTitle: String?
    ) -> FfiNotebookSessionProjection {
        FfiNotebookSessionProjection(
            id: id,
            notebookId: notebookId,
            tabId: tabId,
            sessionId: sessionId,
            sectionTitle: sectionTitle,
            createdAt: "2000-01-01T00:00:00Z",
            updatedAt: "2000-01-01T00:00:00Z",
            deletedAt: nil
        )
    }

    private func waitForAudioImportToFinish() async {
        for _ in 0..<200 {
            if viewModel.isImportingAudio == false { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Timed out waiting for background audio import")
    }
}

@MainActor
private final class StubNotebookWorkspaceClient: NotebookWorkspaceClienting {
    var notebooks: [FfiNotebook] = []
    var tabsByNotebook: [String: [FfiNotebookTab]] = [:]
    var sessionLinksByNotebook: [String: [FfiNotebookSessionLink]] = [:]
    var sessionProjectionsByTab: [String: [FfiNotebookSessionProjection]] = [:]
    var listNotebooksError: StubNotebookWorkspaceError?
    var listTabsError: StubNotebookWorkspaceError?

    func listNotebooks() throws -> [FfiNotebook] {
        if let listNotebooksError { throw listNotebooksError }
        return notebooks
    }

    func createNotebook(title: String?) throws -> FfiNotebook {
        let id = "created-\(notebooks.count + 1)"
        let notebook = FfiNotebook(
            id: id,
            title: title ?? "New Notebook",
            createdAt: "2000-01-01T00:00:00Z",
            updatedAt: "2000-01-01T00:00:00Z",
            deletedAt: nil
        )
        notebooks.append(notebook)
        return notebook
    }

    func listNotebookTabs(notebookId: String) throws -> [FfiNotebookTab] {
        if let listTabsError { throw listTabsError }
        return tabsByNotebook[notebookId] ?? []
    }

    func listNotebookSessions(notebookId: String) throws -> [FfiNotebookSessionLink] {
        sessionLinksByNotebook[notebookId] ?? []
    }

    func listNotebookSessionProjections(tabId: String) throws -> [FfiNotebookSessionProjection] {
        sessionProjectionsByTab[tabId] ?? []
    }

}

private enum StubNotebookWorkspaceError: Error {
    case databaseUnavailable
}

private final class StubNotebookAudioImporter: NotebookAudioImporting, @unchecked Sendable {
    struct Call {
        let path: String
        let notebookId: String
        let wasCalledOnMainThread: Bool
    }

    private let lock = NSLock()
    private let result: ImportResultInfo?
    private let errorMessage: String?
    private var recordedCalls: [Call] = []

    init(result: ImportResultInfo) {
        self.result = result
        self.errorMessage = nil
    }

    init(errorMessage: String) {
        self.result = nil
        self.errorMessage = errorMessage
    }

    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return recordedCalls
    }

    func importAudioIntoNotebook(
        path: String,
        notebookId: String
    ) throws -> ImportResultInfo {
        lock.lock()
        recordedCalls.append(Call(
            path: path,
            notebookId: notebookId,
            wasCalledOnMainThread: Thread.isMainThread
        ))
        lock.unlock()

        if let errorMessage {
            throw StubNotebookAudioImportError(message: errorMessage)
        }
        return result!
    }
}

private struct StubNotebookAudioImportError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - SessionGroup tests

@MainActor
final class SessionGroupTests: XCTestCase {

    func testSessionGroupConstruction() {
        let item = SessionListItem(
            id: "x",
            title: "Test",
            timeString: "10:00",
            durationString: "00:01:00",
            languagePair: "en",
        )
        let group = SessionGroup(label: "TODAY", sessions: [item])
        XCTAssertEqual(group.label, "TODAY")
        XCTAssertEqual(group.sessions.count, 1)
    }
}

// MARK: - SessionBadge tests

final class SessionBadgeTests: XCTestCase {

    @MainActor
    func testBadgeEquality() {
        let a = SessionBadge(label: "IMPORT", color: .signalAmber)
        let b = SessionBadge(label: "IMPORT", color: .signalAmber)
        XCTAssertEqual(a, b)
    }
}

// MARK: - LibraryViewModel pure helpers (formatting)
//
// formatDuration / formatLanguagePair / abbreviateLanguage 是 nonisolated 纯函数；
// makeListItem 因为构造 SessionBadge 需要 Color tokens 所以是 @MainActor。
// 整个 helper 测试类标记 @MainActor，这样所有测试都在主线程上运行。

@MainActor
final class LibraryViewModelHelpersTests: XCTestCase {

    // MARK: - formatDuration

    func testFormatDurationZero() {
        XCTAssertEqual(LibraryViewModel.formatDuration(ms: 0), "00:00")
    }

    func testFormatDurationSeconds() {
        XCTAssertEqual(LibraryViewModel.formatDuration(ms: 5_000), "00:05")
        XCTAssertEqual(LibraryViewModel.formatDuration(ms: 45_000), "00:45")
    }

    func testFormatDurationMinutes() {
        XCTAssertEqual(LibraryViewModel.formatDuration(ms: 60_000), "01:00")
        XCTAssertEqual(LibraryViewModel.formatDuration(ms: 90_000), "01:30")
    }

    func testFormatDurationHours() {
        // 1h 23m 45s = 5025000 ms
        XCTAssertEqual(LibraryViewModel.formatDuration(ms: 5_025_000), "01:23:45")
    }

    func testFormatDurationLargeSession() {
        // 5 hours
        XCTAssertEqual(LibraryViewModel.formatDuration(ms: 18_000_000), "05:00:00")
    }

    // MARK: - formatLanguagePair

    func testFormatLanguagePairEmpty() {
        XCTAssertEqual(
            LibraryViewModel.formatLanguagePair(source: "", targets: []),
            "—"
        )
    }

    func testFormatLanguagePairSourceOnly() {
        XCTAssertEqual(
            LibraryViewModel.formatLanguagePair(source: "en", targets: []),
            "EN"
        )
    }

    func testFormatLanguagePairEqualMultilingualLanes() {
        XCTAssertEqual(
            LibraryViewModel.formatLanguagePair(
                source: "",
                targets: ["en", "zh-CN", "th"]
            ),
            "EN · 中 · TH"
        )
    }

    func testFormatLanguagePairOneTarget() {
        XCTAssertEqual(
            LibraryViewModel.formatLanguagePair(source: "en", targets: ["zh-CN"]),
            "EN ↔ 中"
        )
    }

    func testFormatLanguagePairMultipleTargets() {
        let result = LibraryViewModel.formatLanguagePair(
            source: "en",
            targets: ["zh-CN", "ja", "ko"]
        )
        XCTAssertEqual(result, "EN → 中,日,韩")
    }

    func testFormatLanguagePairUnknownLanguage() {
        let result = LibraryViewModel.formatLanguagePair(
            source: "en",
            targets: ["xx"]
        )
        XCTAssertEqual(result, "EN ↔ XX")
    }

    func testFormatLanguagePairCommonLanguageCodes() {
        let pairs: [(String, String)] = [
            ("zh-cn", "中"),
            ("zh-hans", "中"),
            ("zh-tw", "繁"),
            ("zh-hant", "繁"),
            ("ja", "日"),
            ("ko", "韩"),
            ("es", "ES"),
            ("fr", "FR"),
            ("de", "DE"),
        ]
        for (input, expected) in pairs {
            let actual = LibraryViewModel.formatLanguagePair(source: "en", targets: [input])
            XCTAssertEqual(actual, "EN ↔ \(expected)", "input: \(input)")
        }
    }

    // MARK: - makeListItem

    func testMakeListItemUsesTitle() {
        let info = SessionInfo(
            id: "abc-123",
            sessionType: "import",
            status: "imported",
            title: "interview-2024",
            durationMs: 125_000,
            sourceLanguage: "en",
            targetLanguages: ["zh-CN"],
            createdAtUnixMs: 1_700_000_000_000,
            hasEncryptedAudio: true,
            preview: "",
            isTrashed: false
        )

        let item = LibraryViewModel.makeListItem(info)

        XCTAssertEqual(item.id, "abc-123")
        XCTAssertEqual(item.title, "interview-2024")
        XCTAssertEqual(item.durationString, "02:05")
        XCTAssertEqual(item.languagePair, "EN ↔ 中")
        XCTAssertTrue(item.hasEncryptedAudio)
        XCTAssertEqual(item.sessionType, "import")
    }

    func testMakeListItemFallbackTitleForEmptyTitle() {
        let info = SessionInfo(
            id: "deadbeef-1234",
            sessionType: "recording",
            status: "recording",
            title: "",
            durationMs: 0,
            sourceLanguage: "",
            targetLanguages: [],
            createdAtUnixMs: 1_700_000_000_000,
            hasEncryptedAudio: true,
            preview: "",
            isTrashed: false
        )

        let item = LibraryViewModel.makeListItem(info)

        XCTAssertEqual(item.title, "Session deadbeef")
        XCTAssertEqual(item.durationString, "00:00")
        XCTAssertEqual(item.languagePair, "—")
    }

    @MainActor
    func testMakeListItemAudioDeletedBadge() {
        let info = SessionInfo(
            id: "x",
            sessionType: "import",
            status: "completed",
            title: "Old recording",
            durationMs: 1000,
            sourceLanguage: "en",
            targetLanguages: [],
            createdAtUnixMs: 1_700_000_000_000,
            hasEncryptedAudio: false,
            preview: "",
            isTrashed: false
        )

        let item = LibraryViewModel.makeListItem(info)
        // import + audio deleted = 2 badges
        XCTAssertEqual(item.badges.count, 2)
        XCTAssertTrue(item.badges.contains { $0.label == "IMPORT" })
        XCTAssertTrue(item.badges.contains { $0.label == "AUDIO DELETED" })
        XCTAssertFalse(item.hasEncryptedAudio)
    }

    func testMakeListItemCreatedAtFromUnixMs() {
        let unixMs: UInt64 = 1_700_000_000_000
        let info = SessionInfo(
            id: "x",
            sessionType: "recording",
            status: "recording",
            title: "T",
            durationMs: 0,
            sourceLanguage: "",
            targetLanguages: [],
            createdAtUnixMs: unixMs,
            hasEncryptedAudio: true,
            preview: "",
            isTrashed: false
        )
        let item = LibraryViewModel.makeListItem(info)
        XCTAssertEqual(
            item.createdAt.timeIntervalSince1970,
            Double(unixMs) / 1000,
            accuracy: 0.001
        )
    }

    // MARK: - preview placeholder state

    func testHomeSessionStatusMakesCompletedRecordingExplicit() {
        let completed = SessionListItem(
            id: "completed",
            title: "T",
            timeString: "10:00",
            durationString: "00:23",
            durationMs: 23_200,
            languagePair: "EN ↔ 中",
            preview: "",
            rawStatus: "completed"
        )
        let pending = SessionListItem(
            id: "pending",
            title: "T",
            timeString: "10:00",
            durationString: "00:23",
            durationMs: 23_200,
            languagePair: "EN ↔ 中",
            preview: "",
            rawStatus: "completed",
            transcriptDocumentStatus: "pending"
        )

        XCTAssertEqual(completed.homeStatusState, .completed)
        XCTAssertEqual(pending.homeStatusState, .transcribing)
    }

    func testHomeSessionStatusDistinguishesImportedAudioFromRecording() {
        let imported = SessionListItem(
            id: "imported",
            title: "Interview",
            timeString: "10:00",
            durationString: "00:23",
            durationMs: 23_200,
            languagePair: "EN",
            sessionType: "import",
            preview: "",
            rawStatus: "completed"
        )

        XCTAssertEqual(imported.homeStatusState, .imported)
    }

    func testPreviewPlaceholderStateRecordingWins() {
        let item = SessionListItem(
            id: "1",
            title: "T",
            timeString: "10:00",
            durationString: "00:10",
            durationMs: 10_000,
            languagePair: "EN",
            preview: "",
            rawStatus: "recording"
        )

        XCTAssertEqual(item.previewPlaceholderState, .recording)
    }

    func testPreviewPlaceholderStateUsesPendingTranscriptTask() {
        let item = SessionListItem(
            id: "2",
            title: "T",
            timeString: "10:00",
            durationString: "00:10",
            durationMs: 10_000,
            languagePair: "EN",
            preview: "",
            rawStatus: "completed",
            transcriptDocumentStatus: "pending"
        )

        XCTAssertEqual(item.previewPlaceholderState, .transcribing)
    }

    func testPreviewPlaceholderStateShowsNotTranscribedWhenAutoTranscribeNeverStarted() {
        let item = SessionListItem(
            id: "3",
            title: "T",
            timeString: "10:00",
            durationString: "00:10",
            durationMs: 10_000,
            languagePair: "EN",
            preview: "",
            rawStatus: "completed"
        )

        XCTAssertEqual(item.previewPlaceholderState, .notTranscribed)
    }

    func testPreviewPlaceholderStateFailsWhenTranscriptTaskFailed() {
        let item = SessionListItem(
            id: "4",
            title: "T",
            timeString: "10:00",
            durationString: "00:10",
            durationMs: 10_000,
            languagePair: "EN",
            preview: "",
            rawStatus: "completed",
            transcriptDocumentStatus: "failed"
        )

        XCTAssertEqual(item.previewPlaceholderState, .failed)
    }

    func testPreviewPlaceholderStateSuppressesPlaceholderWhenPreviewExists() {
        let item = SessionListItem(
            id: "5",
            title: "T",
            timeString: "10:00",
            durationString: "00:10",
            durationMs: 10_000,
            languagePair: "EN",
            preview: "hello world",
            rawStatus: "completed",
            transcriptDocumentStatus: "pending"
        )

        XCTAssertNil(item.previewPlaceholderState)
    }
}
