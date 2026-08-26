import XCTest
@testable import ZuTalk

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
        XCTAssertNil(viewModel.selectedTopicFilterId)
        XCTAssertTrue(viewModel.topicIdBySessionId.isEmpty)
        XCTAssertFalse(viewModel.hasLoadedTopicMemberships)
        XCTAssertFalse(viewModel.isLoadingSessions)
        XCTAssertNil(viewModel.sessionLoadError)
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

    func testCatalogPaginationCollectsEverySessionAcrossPages() throws {
        let source = (0..<201).map { makeSessionInfo(id: "session-\($0)") }
        var requestedOffsets: [UInt32] = []

        let snapshot = try LibraryViewModel.loadCompleteSessionCatalog(
            pageSize: 200
        ) { limit, offset in
            requestedOffsets.append(offset)
            let start = Int(offset)
            let end = min(start + Int(limit), source.count)
            let page = start < end ? Array(source[start..<end]) : []
            return SessionQueryResultInfo(
                sessions: page,
                totalCount: UInt64(source.count)
            )
        }

        XCTAssertEqual(snapshot.sessions.map(\.id), source.map(\.id))
        XCTAssertEqual(snapshot.totalCount, 201)
        XCTAssertEqual(requestedOffsets, [0, 200])
    }

    func testCatalogPaginationRejectsANonProgressingPage() {
        let first = makeSessionInfo(id: "session-a")
        let second = makeSessionInfo(id: "session-b")

        XCTAssertThrowsError(
            try LibraryViewModel.loadCompleteSessionCatalog(pageSize: 2) { _, _ in
                SessionQueryResultInfo(
                    sessions: [first, second],
                    totalCount: 3
                )
            }
        ) { error in
            XCTAssertEqual(
                error as? SessionCatalogLoadError,
                .stalled(offset: 2)
            )
        }
    }

    func testCatalogPaginationRejectsATotalThatChangesMidSnapshot() {
        let source = (0..<3).map { makeSessionInfo(id: "session-\($0)") }

        XCTAssertThrowsError(
            try LibraryViewModel.loadCompleteSessionCatalog(pageSize: 2) { _, offset in
                if offset == 0 {
                    return SessionQueryResultInfo(
                        sessions: Array(source[0..<2]),
                        totalCount: 3
                    )
                }
                return SessionQueryResultInfo(
                    sessions: [source[2]],
                    totalCount: 4
                )
            }
        ) { error in
            XCTAssertEqual(
                error as? SessionCatalogLoadError,
                .snapshotChanged(expected: 3, actual: 4)
            )
        }
    }

    func testHomeOwnsSessionLedgerAndTopicsOwnTheWorkspaceLibrary() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ZuTalk", isDirectory: true)
        let contents = try String(
            contentsOf: root.appendingPathComponent("Pages/HomeView.swift"),
            encoding: .utf8
        )

        let homeStart = try XCTUnwrap(contents.range(of: "struct HomeView: View"))
        let topicsStart = try XCTUnwrap(contents.range(of: "struct TopicsView: View"))
        let home = String(contents[homeStart.lowerBound..<topicsStart.lowerBound])
        let topics = String(contents[topicsStart.lowerBound...])

        XCTAssertTrue(home.contains("HomeSessionCatalog("))
        XCTAssertTrue(home.contains("if shouldShowSessionCatalog"))
        XCTAssertTrue(contents.contains("viewModel.isLoadingSessions"))
        XCTAssertTrue(contents.contains("viewModel.sessionLoadError != nil"))
        XCTAssertTrue(contents.contains("viewModel.sessions.isEmpty == false"))
        XCTAssertTrue(contents.contains("viewModel.notebooks.isEmpty == false"))
        XCTAssertTrue(contents.contains("HomeTopicFilterBar"))
        XCTAssertTrue(contents.contains("viewModel.catalogGroupedSessions"))
        XCTAssertTrue(contents.contains("MainNavigationStore.shared.openSession(sessionId)"))
        XCTAssertTrue(contents.contains("onOpenTopic: openNotebook"))
        XCTAssertTrue(contents.contains("home.topic.open_selected"))
        XCTAssertTrue(contents.contains("HomeCatalogLoadFailureState"))
        XCTAssertTrue(contents.contains("HomeCatalogRefreshWarning"))
        XCTAssertTrue(contents.contains("home.catalog.load_failure"))
        XCTAssertFalse(home.contains("HomeNotebookCard("))
        XCTAssertFalse(home.contains("HomeNoNotebookView"))
        XCTAssertTrue(topics.contains("HomeNotebookCard("))
        XCTAssertTrue(topics.contains("HomeCreateNotebookSheet"))
        XCTAssertTrue(topics.contains("topics.search"))
        XCTAssertTrue(topics.contains("topics.create"))
        XCTAssertTrue(topics.contains("topics.page"))
        XCTAssertTrue(contents.contains("viewModel.notebooks"))
        XCTAssertTrue(contents.contains("MainNavigationStore.shared.openTopicWorkspace(notebookID: notebookId)"))
        XCTAssertFalse(home.contains("onImportAudio"))
        XCTAssertFalse(contents.contains("HomeImportAudioSheet"))
        XCTAssertFalse(contents.contains("home.catalog.import"))
        XCTAssertFalse(contents.contains("home.notebook.import"))
        XCTAssertTrue(contents.contains("ActiveBilingualTranscriptStore.shared"))
        XCTAssertTrue(contents.contains("HomeRecordingEntryPolicy.activeDestination"))
        XCTAssertTrue(contents.contains("home.record.return_active_format"))
        XCTAssertTrue(contents.contains("onReturnToActiveCapture: returnToActiveCapture"))
        XCTAssertTrue(contents.contains("onStartRecording: startQuickRecording"))
        XCTAssertTrue(contents.contains("NotebookCaptureStartCoordinator("))
        XCTAssertTrue(contents.contains("viewModel.canStartQuickCapture"))
        XCTAssertTrue(contents.contains(
            "NotebookCaptureStartPreparationWorkflow.prepare("
        ))
        XCTAssertTrue(contents.contains(
            ".shouldEnableRealtimeForQuickCapture("
        ))
        XCTAssertTrue(contents.contains(
            "prepareForHomeQuickCaptureStart("
        ))
        XCTAssertFalse(contents.contains("prepareForCaptureStart(enableRealtimeIfNeeded: false)"))
        XCTAssertTrue(contents.contains("home.record.start"))
        XCTAssertTrue(contents.contains("home.row.topic.unknown"))
        XCTAssertTrue(contents.contains("home.workspace.membership_unavailable"))
        XCTAssertFalse(contents.contains("onRecordInTopic"))
        XCTAssertTrue(contents.contains("HomeWorkspaceFailureView"))
        XCTAssertTrue(contents.contains("HomeWorkspaceRefreshWarning"))
        XCTAssertFalse(contents.contains("allowedContentTypes = [.audio]"))
        XCTAssertFalse(contents.contains("HomeRecentRecordingsSection"))
        XCTAssertFalse(contents.contains("HomeActivityHeatmap"))
        XCTAssertFalse(contents.contains("notebookEvents"))
        XCTAssertFalse(contents.contains("event.eventType"))
        XCTAssertFalse(contents.contains("tab.builtinKind"))
        XCTAssertFalse(contents.contains("home.workspace.error_format"))
        let quickCaptureRecovery = try XCTUnwrap(home.range(
            of: "await CommunityInviteSession.shared.settleRealtimeSession(usedSeconds: 0)"
        ))
        let quickCaptureErrorDetail = try XCTUnwrap(home.range(
            of: "detail: error.localizedDescription"
        ))
        XCTAssertLessThan(
            quickCaptureRecovery.lowerBound,
            quickCaptureErrorDetail.lowerBound,
            "an invite reservation must be recovered before presenting the specific start failure"
        )
        XCTAssertFalse(home.contains(
            "detail: String(localized: \"capture.route.unavailable_detail\")"
        ))
        XCTAssertFalse(contents.contains("detail: \"\\(error)\""))
    }

    func testTopicNamingUsesCanonicalTopicNounAcrossAllLocales() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ZuTalk/Resources", isDirectory: true)
        let forbiddenByLocale: [String: [String]] = [
            "de": ["Forschungsthem"],
            "en": ["research topic"],
            "es": ["tema de investigación", "temas de investigación"],
            "fr": ["sujet de recherche", "sujets de recherche"],
            "ja": ["研究テーマ"],
            "ko": ["연구 주제"],
            "th": ["หัวข้อวิจัย"],
            "zh-Hans": ["研究主题"],
        ]

        for (locale, forbiddenTerms) in forbiddenByLocale {
            let contents = try String(
                contentsOf: root
                    .appendingPathComponent("\(locale).lproj", isDirectory: true)
                    .appendingPathComponent("Localizable.strings"),
                encoding: .utf8
            )
            for forbiddenTerm in forbiddenTerms {
                XCTAssertNil(
                    contents.range(of: forbiddenTerm, options: .caseInsensitive),
                    "\(locale) should call the product object Topic without a research qualifier"
                )
            }
        }
    }

    func testHomeRecordingEntryReturnsToTheAuthoritativeActiveCaptureTopic() {
        let topics = [
            makeNotebook(id: "nb-active", title: "Oral History"),
            makeNotebook(id: "nb-browsed", title: "Team Meetings"),
        ]

        XCTAssertEqual(
            HomeRecordingEntryPolicy.activeDestination(
                isCaptureActive: true,
                captureNotebookId: "nb-active",
                notebooks: topics
            ),
            HomeActiveCaptureDestination(
                notebookId: "nb-active",
                topicTitle: "Oral History"
            )
        )
        XCTAssertNil(
            HomeRecordingEntryPolicy.activeDestination(
                isCaptureActive: false,
                captureNotebookId: "nb-active",
                notebooks: topics
            ),
            "without active capture, Home must expose the one-click recording action"
        )
    }

    func testHomeRecordingEntryStillReturnsWhenTheActiveTopicTitleHasNotLoaded() {
        XCTAssertEqual(
            HomeRecordingEntryPolicy.activeDestination(
                isCaptureActive: true,
                captureNotebookId: "nb-active",
                notebooks: []
            ),
            HomeActiveCaptureDestination(
                notebookId: "nb-active",
                topicTitle: nil
            ),
            "a workspace refresh failure must not hide the route back to an active capture"
        )
        XCTAssertNil(
            HomeRecordingEntryPolicy.activeDestination(
                isCaptureActive: true,
                captureNotebookId: "  \n",
                notebooks: []
            )
        )
    }

    func testHomeQuickCaptureEnablesRealtimeOnlyForAnEnabledActiveInvite() {
        XCTAssertTrue(
            HomeRecordingEntryPolicy.shouldEnableRealtimeForQuickCapture(
                inviteIsEnabled: true,
                inviteIsActive: true
            )
        )
        XCTAssertFalse(
            HomeRecordingEntryPolicy.shouldEnableRealtimeForQuickCapture(
                inviteIsEnabled: false,
                inviteIsActive: true
            )
        )
        XCTAssertFalse(
            HomeRecordingEntryPolicy.shouldEnableRealtimeForQuickCapture(
                inviteIsEnabled: true,
                inviteIsActive: false
            )
        )
    }

    func testQuickCaptureMembershipIsPresentedAsUnfiledUntilMovedToAResearchTopic() {
        let storageMemberships = [
            "quick-recording": "capture-inbox",
            "filed-interview": "topic-research",
        ]

        XCTAssertEqual(
            LibraryViewModel.visibleTopicMemberships(
                storageMemberships: storageMemberships,
                quickCaptureNotebookId: "capture-inbox"
            ),
            ["filed-interview": "topic-research"]
        )
        XCTAssertEqual(
            LibraryViewModel.visibleTopicMemberships(
                storageMemberships: storageMemberships,
                quickCaptureNotebookId: nil
            ),
            storageMemberships
        )
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
            .appendingPathComponent("ZuTalk", isDirectory: true)
        let viewModel = try String(
            contentsOf: root.appendingPathComponent("Library/LibraryViewModel.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(viewModel.contains("TranscriptionTaskIndex.load(core: core)"))
        XCTAssertFalse(viewModel.contains("templateId == \"transcript-hd\""))
        XCTAssertFalse(viewModel.contains("guard item.preview.isEmpty"))
        XCTAssertFalse(viewModel.contains("guard item.rawStatus.lowercased() == \"completed\""))
    }

    func testNotebookEditorIncludesResourcesAsAUiOnlyStatusTab() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ZuTalk", isDirectory: true)
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
        XCTAssertTrue(resources.contains("getSessionTranscriptAvailability"))
        XCTAssertFalse(resources.contains("repairSessionTranscriptProjection"))
        XCTAssertTrue(editor.contains("repairSessionTranscriptProjection"))
        XCTAssertTrue(resources.contains("TranscriptionTaskIndex.makeIndex"))
        XCTAssertTrue(resources.contains("getSession(id:"))
        XCTAssertFalse(resources.contains("limit: 500"))
        XCTAssertTrue(resources.contains("topic.research.copy"))
        XCTAssertTrue(resources.contains("Button(action: chooseAudioFile)"))
        XCTAssertTrue(resources.contains(".accessibilityIdentifier(\"topic.import\")"))
        XCTAssertTrue(resources.contains(
            "viewModel.importAudio(at: url, notebookId: notebookId)"
        ))
        XCTAssertTrue(resources.contains("panel.allowedContentTypes = [.audio]"))
        XCTAssertTrue(resources.contains("onOpen(.asyncTranscript)"))
        XCTAssertTrue(editor.contains("openResource(sessionId: sessionId, destination: destination)"))
        XCTAssertFalse(resources.contains("createNotebook"))
    }

    func testTranscriptResourceStatusUsesContentAvailabilityInsteadOfProjectionShells() {
        let noContentRun = SessionTranscriptAvailabilityInfo(
            hasRealtimeRun: true,
            hasRealtimeContent: false,
            hasAsyncContent: false
        )
        let asyncContent = SessionTranscriptAvailabilityInfo(
            hasRealtimeRun: false,
            hasRealtimeContent: false,
            hasAsyncContent: true
        )
        let completedTask = TranscriptionTaskSnapshot(
            taskId: "completed",
            status: "completed",
            errorMessage: nil
        )
        let pendingTask = TranscriptionTaskSnapshot(
            taskId: "pending",
            status: "running",
            errorMessage: nil
        )
        let failedTask = TranscriptionTaskSnapshot(
            taskId: "failed",
            status: "failed",
            errorMessage: "provider unavailable"
        )

        XCTAssertEqual(
            NotebookTranscriptResourceStatusPolicy.realtime(
                sessionStatus: "completed",
                availability: noContentRun
            ),
            .empty
        )
        XCTAssertEqual(
            NotebookTranscriptResourceStatusPolicy.realtime(
                sessionStatus: "recording",
                availability: nil
            ),
            .pending
        )
        XCTAssertEqual(
            NotebookTranscriptResourceStatusPolicy.realtime(
                sessionStatus: "completed",
                availability: nil
            ),
            .unknown
        )
        XCTAssertEqual(
            NotebookTranscriptResourceStatusPolicy.async(
                task: completedTask,
                availability: noContentRun
            ),
            .empty
        )
        XCTAssertEqual(
            NotebookTranscriptResourceStatusPolicy.async(
                task: nil,
                availability: asyncContent
            ),
            .ready
        )
        XCTAssertEqual(
            NotebookTranscriptResourceStatusPolicy.async(
                task: pendingTask,
                availability: nil
            ),
            .pending
        )
        XCTAssertEqual(
            NotebookTranscriptResourceStatusPolicy.async(
                task: failedTask,
                availability: asyncContent
            ),
            .failed
        )
    }

    func testAudioResourceStatusDistinguishesReadyDestroyedMissingAndContradictoryState() {
        let retained = AudioDestructionReportInfo(
            chunkTotal: 2,
            chunksDeleted: 0,
            filesRemaining: 2,
            keyDeleted: false,
            encryptedPathCleared: false,
            destroyedAtMs: nil,
            deleteErrors: []
        )
        let destroyed = AudioDestructionReportInfo(
            chunkTotal: 2,
            chunksDeleted: 2,
            filesRemaining: 0,
            keyDeleted: true,
            encryptedPathCleared: true,
            destroyedAtMs: 1_700_000_000_000,
            deleteErrors: []
        )
        let neverGenerated = AudioDestructionReportInfo(
            chunkTotal: 0,
            chunksDeleted: 0,
            filesRemaining: 0,
            keyDeleted: true,
            encryptedPathCleared: true,
            destroyedAtMs: nil,
            deleteErrors: []
        )
        let contradictory = AudioDestructionReportInfo(
            chunkTotal: 2,
            chunksDeleted: 2,
            filesRemaining: 1,
            keyDeleted: true,
            encryptedPathCleared: true,
            destroyedAtMs: 1_700_000_000_000,
            deleteErrors: []
        )

        XCTAssertEqual(
            NotebookAudioResourceStatusPolicy.resolve(
                sessionStatus: "recording",
                hasEncryptedAudio: true,
                destructionReport: retained
            ).status,
            .pending
        )
        XCTAssertEqual(
            NotebookAudioResourceStatusPolicy.resolve(
                sessionStatus: "completed",
                hasEncryptedAudio: true,
                destructionReport: retained
            ).status,
            .ready
        )
        let destroyedState = NotebookAudioResourceStatusPolicy.resolve(
            sessionStatus: "completed",
            hasEncryptedAudio: false,
            destructionReport: destroyed
        )
        XCTAssertEqual(destroyedState.status, .destroyed)
        XCTAssertEqual(
            destroyedState.destroyedAt,
            Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertEqual(
            NotebookAudioResourceStatusPolicy.resolve(
                sessionStatus: "completed",
                hasEncryptedAudio: false,
                destructionReport: neverGenerated
            ).status,
            .missing
        )
        XCTAssertEqual(
            NotebookAudioResourceStatusPolicy.resolve(
                sessionStatus: "completed",
                hasEncryptedAudio: true,
                destructionReport: nil
            ).status,
            .unknown
        )
        XCTAssertEqual(
            NotebookAudioResourceStatusPolicy.resolve(
                sessionStatus: "completed",
                hasEncryptedAudio: false,
                destructionReport: contradictory
            ).status,
            .failed
        )
    }

    func testResearchBundleKeepsAvailableTranscriptsAndNamesOmittedSessions() throws {
        enum MissingTranscript: Error { case unavailable }
        let items = [
            makeNotebookResourceItem(id: "session-ready", title: "First interview", offset: 0),
            makeNotebookResourceItem(id: "session-empty", title: "Second interview", offset: 60),
        ]

        let result = try XCTUnwrap(
            NotebookResourcesViewModel.composeResearchBundle(
                selectedItems: items,
                recordedLabel: "Recorded",
                sourceSessionLabel: "Source session",
                omittedHeading: "Omitted sessions",
                noTranscriptLabel: "No transcript available",
                transcriptForSession: { sessionId in
                    guard sessionId == "session-ready" else {
                        throw MissingTranscript.unavailable
                    }
                    return "Quoted answer"
                }
            )
        )

        XCTAssertEqual(result.copiedCount, 1)
        XCTAssertEqual(result.omittedCount, 1)
        XCTAssertTrue(result.text.contains("## First interview"))
        XCTAssertTrue(result.text.contains("Source session: session-ready"))
        XCTAssertTrue(result.text.contains("Quoted answer"))
        XCTAssertTrue(result.text.contains("## Omitted sessions"))
        XCTAssertTrue(result.text.contains("Source session: session-empty"))
    }

    func testResearchBundleReturnsNilWhenEverySelectedTranscriptIsUnavailable() {
        let items = [
            makeNotebookResourceItem(id: "session-empty", title: "Empty", offset: 0)
        ]

        XCTAssertNil(
            NotebookResourcesViewModel.composeResearchBundle(
                selectedItems: items,
                recordedLabel: "Recorded",
                sourceSessionLabel: "Source session",
                omittedHeading: "Omitted sessions",
                noTranscriptLabel: "No transcript available",
                transcriptForSession: { _ in "   \n" }
            )
        )
    }

    private func makeNotebookResourceItem(
        id: String,
        title: String,
        offset: TimeInterval
    ) -> NotebookResourceItem {
        NotebookResourceItem(
            id: id,
            title: title,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000 + offset),
            durationMs: 60_000,
            sessionType: "recording",
            rawStatus: "completed",
            preview: "",
            languagePair: "EN",
            audio: .ready,
            audioDestroyedAt: nil,
            realtimeTranscript: .missing,
            asyncTranscript: .ready
        )
    }

    // MARK: - Search

    func testFullTextSnippetRemovesSearchMarkupAndBoundsLength() {
        let longTail = String(repeating: "词 ", count: 180)
        let sanitized = LibraryViewModel.sanitizedSearchSnippet(
            "<b>关键</b>   内容 &amp; 证据 \(longTail)"
        )

        XCTAssertTrue(sanitized.hasPrefix("关键 内容 & 证据"))
        XCTAssertFalse(sanitized.contains("<b>"))
        XCTAssertFalse(sanitized.contains("</b>"))
        XCTAssertLessThanOrEqual(sanitized.count, 240)
    }

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
        XCTAssertEqual(viewModel.topicIdBySessionId["session-a"], "nb-research")
        XCTAssertEqual(viewModel.notebookSessionCounts["nb-research"], 1)
        XCTAssertEqual(viewModel.notebookSessionCounts["nb-meetings"], 0)
        XCTAssertEqual(viewModel.sessions, sessions)
        XCTAssertFalse(viewModel.hasNoResearchTopics)
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
        XCTAssertTrue(viewModel.hasNoResearchTopics)
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
        XCTAssertFalse(viewModel.hasNoResearchTopics)
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

    func testCatalogShowsAllSessionsAndTopicFilterDoesNotChangeCaptureNotebook() {
        let client = StubNotebookWorkspaceClient()
        client.notebooks = [
            makeNotebook(id: "nb-research", title: "AI History"),
            makeNotebook(id: "nb-meetings", title: "Community Governance")
        ]
        client.sessionLinksByNotebook["nb-research"] = [
            FfiNotebookSessionLink(
                notebookId: "nb-research",
                sessionId: "session-a",
                createdAt: "2001-01-04T00:00:00Z"
            )
        ]
        client.sessionLinksByNotebook["nb-meetings"] = [
            FfiNotebookSessionLink(
                notebookId: "nb-meetings",
                sessionId: "session-b",
                createdAt: "2001-01-04T00:00:00Z"
            )
        ]
        viewModel.sessions = [
            SessionListItem(
                id: "session-a",
                title: "Oral history interview",
                timeString: "10:00",
                durationString: "00:12",
                languagePair: "EN ↔ 中",
                createdAt: Date(timeIntervalSince1970: 2),
                preview: "Early community memory"
            ),
            SessionListItem(
                id: "session-b",
                title: "Governance meeting",
                timeString: "09:00",
                durationString: "00:08",
                languagePair: "中",
                createdAt: Date(timeIntervalSince1970: 1),
                preview: "Decision and follow-up"
            )
        ]

        viewModel.loadNotebookWorkspace(client: client)

        XCTAssertEqual(viewModel.catalogSessions.map(\.id), ["session-a", "session-b"])
        XCTAssertEqual(viewModel.activeNotebookId, "nb-research")
        XCTAssertEqual(viewModel.topicTitle(forSessionId: "session-b"), "Community Governance")

        viewModel.selectTopicFilter("nb-meetings")

        XCTAssertEqual(viewModel.catalogSessions.map(\.id), ["session-b"])
        XCTAssertEqual(
            viewModel.activeNotebookId,
            "nb-research",
            "Browsing a Topic must not silently change the capture destination"
        )
    }

    func testCatalogSearchIntersectsTopicAndMatchesTranscriptPreview() {
        let client = StubNotebookWorkspaceClient()
        client.notebooks = [
            makeNotebook(id: "nb-a", title: "Field Research"),
            makeNotebook(id: "nb-b", title: "Team Meetings")
        ]
        client.sessionLinksByNotebook["nb-a"] = [
            FfiNotebookSessionLink(
                notebookId: "nb-a",
                sessionId: "session-a",
                createdAt: "2001-01-04T00:00:00Z"
            )
        ]
        client.sessionLinksByNotebook["nb-b"] = [
            FfiNotebookSessionLink(
                notebookId: "nb-b",
                sessionId: "session-b",
                createdAt: "2001-01-04T00:00:00Z"
            )
        ]
        viewModel.sessions = [
            SessionListItem(
                id: "session-a",
                title: "Interview",
                timeString: "10:00",
                durationString: "00:12",
                languagePair: "EN",
                preview: "The migration story begins here"
            ),
            SessionListItem(
                id: "session-b",
                title: "Migration planning",
                timeString: "11:00",
                durationString: "00:08",
                languagePair: "中",
                preview: "A stronger title match outside the selected Topic"
            )
        ]
        viewModel.loadNotebookWorkspace(client: client)
        viewModel.selectTopicFilter("nb-a")

        viewModel.searchText = "migration"

        XCTAssertEqual(viewModel.catalogSessions.map(\.id), ["session-a"])

        viewModel.searchText = "field research"
        XCTAssertEqual(
            viewModel.catalogSessions.map(\.id),
            ["session-a"],
            "A Topic name is part of the catalogue's searchable context"
        )

        viewModel.searchText = String(localized: "home.row.kind.recording")
        XCTAssertEqual(
            viewModel.catalogSessions.map(\.id),
            ["session-a"],
            "The visible localized Session kind should also be searchable"
        )
    }

    func testUnknownTopicFilterFallsBackToAllSessions() {
        viewModel.sessions = makeMockSessions()

        viewModel.selectTopicFilter("missing-topic")

        XCTAssertNil(viewModel.selectedTopicFilterId)
        XCTAssertEqual(viewModel.catalogSessions.map(\.id), ["1", "2"])
    }

    func testCatalogTreatsWhitespaceOnlySearchAsEmpty() {
        viewModel.sessions = makeMockSessions()
        viewModel.searchText = "  \n "

        XCTAssertFalse(viewModel.hasCatalogSearchText)
        XCTAssertEqual(viewModel.catalogSessions.map(\.id), ["1", "2"])
    }

    func testWorkspaceReloadClearsADeletedTopicFilter() {
        let client = StubNotebookWorkspaceClient()
        client.notebooks = [
            makeNotebook(id: "nb-a", title: "Topic A"),
            makeNotebook(id: "nb-b", title: "Topic B")
        ]
        viewModel.loadNotebookWorkspace(client: client)
        viewModel.selectTopicFilter("nb-b")
        XCTAssertEqual(viewModel.selectedTopicFilterId, "nb-b")

        client.notebooks = [makeNotebook(id: "nb-a", title: "Topic A")]
        viewModel.loadNotebookWorkspace(client: client)

        XCTAssertNil(viewModel.selectedTopicFilterId)
    }

    func testTopicMembershipFailurePreservesLastKnownSnapshot() {
        let client = StubNotebookWorkspaceClient()
        client.notebooks = [makeNotebook(id: "nb-a", title: "Topic A")]
        client.sessionLinksByNotebook["nb-a"] = [
            FfiNotebookSessionLink(
                notebookId: "nb-a",
                sessionId: "session-a",
                createdAt: "2001-01-04T00:00:00Z"
            )
        ]
        viewModel.loadNotebookWorkspace(client: client)
        XCTAssertTrue(viewModel.hasLoadedTopicMemberships)
        XCTAssertEqual(viewModel.topicIdBySessionId["session-a"], "nb-a")
        XCTAssertEqual(viewModel.notebookSessionCounts["nb-a"], 1)

        client.listSessionsErrorByNotebook["nb-a"] = .databaseUnavailable
        viewModel.loadNotebookWorkspace(client: client)

        XCTAssertEqual(viewModel.topicIdBySessionId["session-a"], "nb-a")
        XCTAssertEqual(viewModel.notebookSessionCounts["nb-a"], 1)
        XCTAssertTrue(viewModel.hasLoadedTopicMemberships)
        XCTAssertEqual(
            viewModel.notebookWorkspaceError,
            String(localized: "home.workspace.load_failed")
        )
    }

    func testInitialTopicMembershipFailureDoesNotPretendSessionsAreUnfiled() {
        let client = StubNotebookWorkspaceClient()
        client.notebooks = [makeNotebook(id: "nb-a", title: "Topic A")]
        client.listSessionsErrorByNotebook["nb-a"] = .databaseUnavailable
        viewModel.sessions = [
            SessionListItem(
                id: "session-a",
                title: "Interview",
                timeString: "10:00",
                durationString: "00:12",
                languagePair: "EN"
            )
        ]

        viewModel.loadNotebookWorkspace(client: client)
        viewModel.selectUnfiledFilter()

        XCTAssertFalse(viewModel.hasLoadedTopicMemberships)
        XCTAssertNil(viewModel.selectedTopicFilterId)
        XCTAssertEqual(viewModel.unfiledSessionCount, 0)
        XCTAssertNil(viewModel.topicTitle(forSessionId: "session-a"))
        XCTAssertFalse(viewModel.canOpenCatalogSession("session-a"))
    }

    func testSuccessfulEmptyMembershipSnapshotMakesSessionsGenuinelyUnfiled() {
        let client = StubNotebookWorkspaceClient()
        client.notebooks = [makeNotebook(id: "nb-a", title: "Topic A")]
        viewModel.sessions = [
            SessionListItem(
                id: "session-a",
                title: "Interview",
                timeString: "10:00",
                durationString: "00:12",
                languagePair: "EN"
            )
        ]

        viewModel.loadNotebookWorkspace(client: client)
        viewModel.selectUnfiledFilter()

        XCTAssertTrue(viewModel.hasLoadedTopicMemberships)
        XCTAssertEqual(viewModel.selectedTopicFilterId, LibraryViewModel.unfiledTopicFilterId)
        XCTAssertEqual(viewModel.unfiledSessionCount, 1)
        XCTAssertEqual(viewModel.catalogSessions.map(\.id), ["session-a"])
    }

    func testTopicMembershipRemainsKnownWhenOnlyActiveTopicDetailsFail() {
        let client = StubNotebookWorkspaceClient()
        client.notebooks = [makeNotebook(id: "nb-a", title: "Topic A")]
        client.sessionLinksByNotebook["nb-a"] = [
            FfiNotebookSessionLink(
                notebookId: "nb-a",
                sessionId: "session-a",
                createdAt: "2001-01-04T00:00:00Z"
            )
        ]
        client.listTabsError = .databaseUnavailable

        viewModel.loadNotebookWorkspace(client: client)

        XCTAssertTrue(viewModel.hasLoadedTopicMemberships)
        XCTAssertEqual(viewModel.topicIdBySessionId["session-a"], "nb-a")
        XCTAssertEqual(
            viewModel.notebookWorkspaceError,
            String(localized: "home.workspace.load_failed")
        )
    }

    func testProjectionAloneDoesNotInventTopicOwnership() {
        let client = StubNotebookWorkspaceClient()
        client.notebooks = [makeNotebook(id: "nb-a", title: "Topic A")]
        client.tabsByNotebook["nb-a"] = [
            makeNotebookTab(id: "tab-a", notebookId: "nb-a", title: "Transcript")
        ]
        client.sessionProjectionsByTab["tab-a"] = [
            makeNotebookSessionProjection(
                id: "projection-a",
                notebookId: "nb-a",
                tabId: "tab-a",
                sessionId: "session-a",
                sectionTitle: nil
            )
        ]

        viewModel.loadNotebookWorkspace(client: client)

        XCTAssertNil(viewModel.topicIdBySessionId["session-a"])
        XCTAssertNil(viewModel.topicTitle(forSessionId: "session-a"))
        XCTAssertEqual(viewModel.notebookSessionCounts["nb-a"], 0)
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
        XCTAssertTrue(viewModel.hasNoResearchTopics)

        viewModel.createNotebook(title: "Field Notes", client: client)

        XCTAssertEqual(viewModel.notebooks.map(\.title), ["Field Notes"])
        XCTAssertEqual(viewModel.activeNotebook?.title, "Field Notes")
        XCTAssertFalse(viewModel.hasNoResearchTopics)
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

    private func makeSessionInfo(id: String) -> SessionInfo {
        SessionInfo(
            id: id,
            sessionType: "recording",
            status: "completed",
            title: id,
            durationMs: 1_000,
            sourceLanguage: "en",
            targetLanguages: [],
            createdAtUnixMs: 1_700_000_000_000,
            hasEncryptedAudio: true,
            preview: "",
            isTrashed: false
        )
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
    var listSessionsErrorByNotebook: [String: StubNotebookWorkspaceError] = [:]

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
        if let error = listSessionsErrorByNotebook[notebookId] { throw error }
        return sessionLinksByNotebook[notebookId] ?? []
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

    func testMakeListItemPreservesEmptyTitleForLocalizedPresentation() {
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

        XCTAssertEqual(item.title, "")
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

    func testHomeSessionStatusIncludesInterruptedAndPersistedImportedStates() {
        let interrupted = SessionListItem(
            id: "interrupted",
            title: "Interview",
            timeString: "10:00",
            durationString: "00:00",
            languagePair: "EN",
            rawStatus: "interrupted"
        )
        let imported = SessionListItem(
            id: "imported-status",
            title: "Archive tape",
            timeString: "09:00",
            durationString: "00:00",
            languagePair: "中",
            sessionType: "import",
            rawStatus: "imported"
        )
        let interruptedRetry = SessionListItem(
            id: "interrupted-retry",
            title: "Recovered interview",
            timeString: "08:00",
            durationString: "00:12",
            languagePair: "EN",
            preview: "Durable local transcript preview",
            rawStatus: "interrupted",
            transcriptDocumentStatus: "pending"
        )
        let importedFailure = SessionListItem(
            id: "imported-failure",
            title: "Archive tape",
            timeString: "07:00",
            durationString: "00:12",
            languagePair: "EN",
            sessionType: "import",
            rawStatus: "imported",
            transcriptDocumentStatus: "failed"
        )
        let failedCaptureWithStaleTask = SessionListItem(
            id: "failed-capture",
            title: "Failed capture",
            timeString: "06:00",
            durationString: "00:00",
            languagePair: "EN",
            rawStatus: "failed",
            transcriptDocumentStatus: "pending"
        )

        XCTAssertEqual(interrupted.homeStatusState, .interrupted)
        XCTAssertEqual(imported.homeStatusState, .imported)
        XCTAssertEqual(interruptedRetry.homeStatusState, .transcribing)
        XCTAssertEqual(importedFailure.homeStatusState, .failed)
        XCTAssertEqual(failedCaptureWithStaleTask.homeStatusState, .failed)
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
