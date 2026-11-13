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
        XCTAssertTrue(contents.contains("viewModel.isLoadingSessions"))
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
        XCTAssertTrue(contents.contains("MainNavigationStore.shared.openTopicWorkspace(notebookID: notebookId)"))
        XCTAssertTrue(contents.contains("home.row.topic.unknown"))
        XCTAssertTrue(contents.contains("home.workspace.membership_unavailable"))
        XCTAssertTrue(contents.contains("HomeWorkspaceFailureView"))
        XCTAssertTrue(contents.contains("HomeWorkspaceRefreshWarning"))
        XCTAssertFalse(contents.contains("HomeRecentRecordingsSection"))
        XCTAssertFalse(contents.contains("HomeActivityHeatmap"))
        XCTAssertFalse(contents.contains("notebookEvents"))
        XCTAssertFalse(contents.contains("event.eventType"))
        XCTAssertFalse(contents.contains("tab.builtinKind"))
        XCTAssertFalse(contents.contains("home.workspace.error_format"))
        XCTAssertFalse(contents.contains("NotebookCaptureStartCoordinator("))

        // Home is where a recording starts: one card above the list holds
        // the only Start button in the window. The list itself still starts
        // nothing, and the start goes through the same commands as ⌃⌥R.
        XCTAssertTrue(home.contains("HomeStartCard(library: viewModel"))
        XCTAssertFalse(home.contains("home.record.start"))
        XCTAssertFalse(contents.contains("CaptionsChoiceChip()"))
        XCTAssertFalse(contents.contains("startQuickCapture"))
        // A recording in no topic carries no topic label, and the list has
        // no strip of counts above it.
        XCTAssertFalse(contents.contains("home.row.topic.unassigned"))
        XCTAssertFalse(contents.contains("home.record.unfiled"))
        XCTAssertFalse(contents.contains("home.catalog.count_format"))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("Pages/RecordStartPage.swift").path
            ),
            "starting a recording is not a page of its own"
        )
        let record = try String(
            contentsOf: root.appendingPathComponent("Pages/HomeStartCard.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(record.contains("commands.startQuickCapture(profileEditor: editor)"))
        XCTAssertTrue(record.contains("commands.start(notebookId: notebookId, profileEditor: starter)"))
        // The choices are in the card, behind "Change": none of them stands
        // between the person and the Start button.
        let optionsStart = try XCTUnwrap(record.range(of: "private var options: some View"))
        let beforeOptions = String(record[..<optionsStart.lowerBound])
        let options = String(record[optionsStart.lowerBound...])
        XCTAssertTrue(beforeOptions.contains("if memory.showsOptions"))
        XCTAssertFalse(beforeOptions.contains("CaptureLanguageEditor("))
        XCTAssertFalse(beforeOptions.contains("AudioInputPicker("))
        XCTAssertFalse(beforeOptions.contains("Picker("))
        XCTAssertTrue(options.contains("CaptureLanguageEditor(editor: editor)"))
        XCTAssertTrue(options.contains("commands.setRealtimeCaptionsEnabled("))
        XCTAssertTrue(options.contains("hostMode.set("))
        // Where the transcript will be filed is confirmed per recording, so
        // that row is never inside the collapsed options — and nothing is
        // confirmed when the row is not on screen.
        XCTAssertTrue(beforeOptions.contains("StartCardHostingSection(editor: editor, topicId: topicId"))
        XCTAssertTrue(record.contains(
            "if StartCardHosting.current(hostMode: hostMode) == .destination {\n            CityStore.shared.confirmNextDestination()"
        ))
        // Meeting or microphone is decided before Start, with the same control
        // a recording's settings show.
        XCTAssertTrue(record.contains("AudioInputPicker(notebookId: notebookId"))
        let settings = try String(
            contentsOf: root.appendingPathComponent("Pages/NotebookCaptureSettingsView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(settings.contains("AudioInputPicker(notebookId: notebookId)"))
        XCTAssertFalse(settings.contains("selectAudioInputDevice("))
        XCTAssertFalse(record.contains("selectAudioInputDevice("))
        XCTAssertTrue(record.contains("home.record.start"))
        XCTAssertTrue(record.contains("allowedContentTypes = [.audio]"))
        XCTAssertTrue(record.contains("MainNavigationStore.shared.openLiveRecording()"))
        XCTAssertFalse(record.contains("NotebookCaptureStartCoordinator("))
        // Starting — and recovering an invite reservation when a start fails —
        // happens once, in the command center every Record button uses.
        let commands = try String(
            contentsOf: root.appendingPathComponent("Capture/CaptureCommandCenter.swift"),
            encoding: .utf8
        )
        let quickCaptureRecovery = try XCTUnwrap(commands.range(
            of: "await invite.settleRealtimeSession(usedSeconds: 0)"
        ))
        let quickCaptureErrorDetail = try XCTUnwrap(commands.range(
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
            isTrashed: false,
            recordedOn: nil
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
// formatDuration / formatLanguagePair 是 nonisolated 纯函数；
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

    /// Every language by its own name, in order, once — whatever the record
    /// calls source and target.
    func testLanguagesAreListedAsTheirSpeakersWriteThem() {
        XCTAssertEqual(
            LibraryViewModel.formatLanguagePair(source: "", targets: ["en", "zh-CN", "th"]),
            "English · 中文 · ไทย"
        )
        XCTAssertEqual(
            LibraryViewModel.formatLanguagePair(source: "en", targets: ["zh-Hans"]),
            "English · 中文"
        )
        XCTAssertEqual(
            LibraryViewModel.formatLanguagePair(source: "en", targets: ["en", "ja", "ko"]),
            "English · 日本語 · 한국어"
        )
        XCTAssertEqual(
            LibraryViewModel.formatLanguagePair(source: "fr", targets: []),
            "Français"
        )
    }

    func testDurationsReadAsLengthsNotClockTimes() {
        XCTAssertNil(RecordingPresentation.duration(ms: 400))
        XCTAssertNotNil(RecordingPresentation.duration(ms: 45_000))
        XCTAssertFalse(RecordingPresentation.duration(ms: 125_000)?.contains(":") ?? true)
    }

    func testUntitledRecordingsHaveNoTitle() {
        XCTAssertNil(RecordingPresentation.title("  \n"))
        XCTAssertEqual(RecordingPresentation.title(" 周会 "), "周会")
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
            isTrashed: false,
            recordedOn: nil
        )

        let item = LibraryViewModel.makeListItem(info)

        XCTAssertEqual(item.id, "abc-123")
        XCTAssertEqual(item.title, "interview-2024")
        XCTAssertEqual(item.durationString, "02:05")
        XCTAssertEqual(item.languagePair, "English · 中文")
        XCTAssertEqual(item.languageCodes, ["en", "zh-CN"])
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
            isTrashed: false,
            recordedOn: nil
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
            isTrashed: false,
            recordedOn: nil
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
            isTrashed: false,
            recordedOn: nil
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

// MARK: - Home: starting a recording, the sidebar, topics as optional

/// Home is where a recording starts (docs/product/interface-layers.md). What
/// can be checked without a window: the sentence under the Start button, the
/// rules for what the card and the sidebar show, and where the old Record
/// destination now leads.
@MainActor
final class HomeStartTests: XCTestCase {
    /// One language's phrases straight from its strings file, so a sentence
    /// can be compared word for word on any test machine.
    private func wording(_ language: String) throws -> RecordingPlanSentence.Wording {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ZuTalk/Resources/\(language).lproj/Localizable.strings")
        let table = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
        return RecordingPlanSentence.Wording(
            phrase: { table[$0] ?? $0 },
            locale: Locale(identifier: language)
        )
    }

    // MARK: The sentence

    func testOneLanguageWithNoTranslationSaysOnlyWhatIsSpokenAndWhereTheSoundComesFrom() throws {
        let plan = RecordingPlan(spoken: ["zh"])

        XCTAssertEqual(
            RecordingPlanSentence.text(plan, wording: try wording("zh-Hans")),
            "说中文 · 这台 Mac 的麦克风"
        )
        XCTAssertEqual(
            RecordingPlanSentence.text(plan, wording: try wording("en")),
            "Speaking 中文 · this Mac’s microphone"
        )
    }

    func testSeveralSpokenLanguagesAreSaidToTranslateIntoEachOther() throws {
        XCTAssertEqual(
            RecordingPlanSentence.text(
                RecordingPlan(spoken: ["zh", "en"]),
                wording: try wording("zh-Hans")
            ),
            "说中文和 English，互相翻译 · 这台 Mac 的麦克风"
        )
        XCTAssertEqual(
            RecordingPlanSentence.text(
                RecordingPlan(spoken: ["zh", "en", "th"]),
                wording: try wording("en")
            ),
            "Speaking 中文, English, and ไทย, translated into each other · this Mac’s microphone"
        )
    }

    func testLanguagesNobodySpeaksAreSaidAsTranslatedInto() throws {
        XCTAssertEqual(
            RecordingPlanSentence.text(
                RecordingPlan(spoken: ["zh"], translatedInto: ["en", "th"]),
                wording: try wording("zh-Hans")
            ),
            "说中文，同时译成 English 和 ไทย · 这台 Mac 的麦克风"
        )
        XCTAssertEqual(
            RecordingPlanSentence.text(
                RecordingPlan(spoken: ["zh", "en"], translatedInto: ["th"]),
                wording: try wording("zh-Hans")
            ),
            "说中文和 English，互相翻译，另外译成 ไทย · 这台 Mac 的麦克风"
        )
        // A language cannot be both; spoken wins, as it does in the profile.
        XCTAssertEqual(
            RecordingPlanSentence.text(
                RecordingPlan(spoken: ["zh"], translatedInto: ["zh"]),
                wording: try wording("zh-Hans")
            ),
            "说中文 · 这台 Mac 的麦克风"
        )
    }

    func testAudioOnlyNamesNoLanguage() throws {
        let plan = RecordingPlan(spoken: ["zh", "en"], liveText: false)

        XCTAssertEqual(
            RecordingPlanSentence.text(plan, wording: try wording("zh-Hans")),
            "只录音，不出字 · 这台 Mac 的麦克风"
        )
        XCTAssertEqual(
            RecordingPlanSentence.text(plan, wording: try wording("en")),
            "Audio only, no live text · this Mac’s microphone"
        )
    }

    func testTheSoundSourceIsNamedAsThePersonKnowsIt() throws {
        let zh = try wording("zh-Hans")

        XCTAssertEqual(
            RecordingPlanSentence.text(
                RecordingPlan(spoken: ["zh"], source: .soundFromMac),
                wording: zh
            ),
            "说中文 · 电脑里的声音"
        )
        XCTAssertEqual(
            RecordingPlanSentence.text(
                RecordingPlan(spoken: ["zh"], source: .microphone("USB Mic")),
                wording: zh
            ),
            "说中文 · 麦克风：USB Mic"
        )
        // A picked microphone whose name is unknown is still a microphone.
        XCTAssertEqual(
            RecordingPlanSentence.text(
                RecordingPlan(spoken: ["zh"], source: .microphone("  ")),
                wording: zh
            ),
            "说中文 · 这台 Mac 的麦克风"
        )
    }

    func testAChosenTopicIsSaidLastAndNoTopicIsNotMentioned() throws {
        let zh = try wording("zh-Hans")

        XCTAssertEqual(
            RecordingPlanSentence.text(
                RecordingPlan(spoken: ["zh"], topic: "周会"),
                wording: zh
            ),
            "说中文 · 这台 Mac 的麦克风 · 放进「周会」"
        )
        // The topic's own name is left exactly as it was typed.
        XCTAssertEqual(
            RecordingPlanSentence.text(
                RecordingPlan(spoken: ["zh"], liveText: false, topic: "AI与教育"),
                wording: zh
            ),
            "只录音，不出字 · 这台 Mac 的麦克风 · 放进「AI与教育」"
        )
        let none = RecordingPlanSentence.text(RecordingPlan(spoken: ["zh"], topic: "  "), wording: zh)
        XCTAssertEqual(none, "说中文 · 这台 Mac 的麦克风")
        XCTAssertFalse(none.contains("主题"))
    }

    func testLanguagesThatHaveNotLoadedLeaveOnlyTheRestOfTheSentence() throws {
        XCTAssertEqual(
            RecordingPlanSentence.text(
                RecordingPlan(spoken: [], source: .soundFromMac),
                wording: try wording("zh-Hans")
            ),
            "电脑里的声音"
        )
    }

    func testTheSentenceReadsAsOneInEveryInterfaceLanguage() throws {
        let plan = RecordingPlan(
            spoken: ["zh", "en"],
            translatedInto: ["th"],
            source: .soundFromMac,
            topic: "Weekly"
        )
        for language in AppLanguage.allCases {
            let text = RecordingPlanSentence.text(plan, wording: try wording(language.rawValue))
            for expected in ["中文", "English", "ไทย", "Weekly", " · "] {
                XCTAssertTrue(text.contains(expected), "\(language.rawValue): \(text)")
            }
            XCTAssertFalse(text.contains("home.plan."), "\(language.rawValue) is missing a phrase: \(text)")
            XCTAssertFalse(text.contains("%"), "\(language.rawValue) left a placeholder: \(text)")
        }
    }

    func testASpaceSeparatesChineseFromOtherScriptsAndNothingElseChanges() {
        XCTAssertEqual(
            RecordingPlanSentence.spacedBetweenScripts("说中文和English，互相翻译"),
            "说中文和 English，互相翻译"
        )
        XCTAssertEqual(
            RecordingPlanSentence.spacedBetweenScripts("中文、English和ไทย"),
            "中文、English 和 ไทย"
        )
        XCTAssertEqual(
            RecordingPlanSentence.spacedBetweenScripts("Englishで話し、日本語にも翻訳"),
            "English で話し、日本語にも翻訳"
        )
        for unchanged in [
            "说中文和 English，互相翻译",
            "Speaking 中文 and English",
            "ภาษาที่พูด: ไทย และ English",
            "말하는 언어: 한국어, English",
            "",
        ] {
            XCTAssertEqual(RecordingPlanSentence.spacedBetweenScripts(unchanged), unchanged)
        }
    }

    func testTwoLanguagesAreBothSpokenAndRolesStartAtThree() {
        let two = RecordingPlanSentence.languages(selected: ["zh", "en"], subtitleOnly: ["en"])
        XCTAssertEqual(two.spoken, ["zh", "en"])
        XCTAssertEqual(two.translatedInto, [])

        let three = RecordingPlanSentence.languages(
            selected: ["zh", "en", "th"],
            subtitleOnly: ["th"]
        )
        XCTAssertEqual(three.spoken, ["zh", "en"])
        XCTAssertEqual(three.translatedInto, ["th"])

        // Nobody speaking is read as anyone may, as the core reads it.
        let all = RecordingPlanSentence.languages(
            selected: ["zh", "en", "th"],
            subtitleOnly: ["zh", "en", "th"]
        )
        XCTAssertEqual(all.spoken, ["zh", "en", "th"])
        XCTAssertEqual(all.translatedInto, [])
    }

    func testEveryPhraseTheStartCardShowsIsLocalized() {
        for key in [
            "home.start.change",
            "home.start.change_done",
            "home.start.change_hint",
            "home.start.offline_hint",
            "home.plan.speak_format",
            "home.plan.speak_translate_format",
            "home.plan.speak_many_format",
            "home.plan.speak_many_translate_format",
            "home.plan.audio_only",
            "home.plan.source.this_mac",
            "home.plan.source.microphone_format",
            "home.plan.source.sound_from_mac",
            "home.plan.topic_format",
            "home.plan.join2_format",
            "home.plan.join3_format",
            "home.options.languages",
            "home.options.languages_detail",
            "home.options.source_detail_microphone_or_mac",
            "home.options.live_text",
            "home.options.live_text_detail",
            "home.options.live_text_needs_setup",
            "home.options.live_text_setup",
            "home.options.live_text_invite_format",
            "home.options.topic",
            "home.options.topic_detail",
            "home.options.topic.none",
            "home.options.topic.new",
            "home.options.hosting",
            "home.options.hosting_detail",
            "home.options.import",
            "home.hosting.sign_in_hint",
            "home.hosting.sign_in_button",
            "home.search.placeholder",
            "home.empty.sentence",
            "home.filter.no_topic",
            "home.filter.no_topic_empty",
            "home.row.put_in_topic",
            "home.row.open_hint",
            "home.row.needs_topic_hint",
            "topics.empty.description",
            "topic.none_choice",
            "capture.languages.roles.all_spoken",
            "capture.languages.roles.some_translated_format",
            "capture.languages.role.spoken_format",
            "capture.languages.role.translated_format",
            "audio_input.sound_from_mac",
        ] {
            let value = Bundle.main.localizedString(forKey: key, value: nil, table: nil)
            XCTAssertNotEqual(value, key, "missing localization for \(key)")
            XCTAssertFalse(value.isEmpty, "empty localization for \(key)")
        }
    }

    /// The words the interface no longer uses for a recording in no topic
    /// must not come back through Home, the start card or the sidebar.
    func testHomeNeverCallsARecordingUnfiled() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ZuTalk", isDirectory: true)
        for file in [
            "Pages/HomeView.swift",
            "Pages/HomeStartCard.swift",
            "Pages/RecordingPlanSentence.swift",
            "UIScenes/Main/MainShellView.swift",
            "UIScenes/Main/MainNavigationStore.swift",
            "Library/LibraryViewModel.swift",
        ] {
            let source = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            for retired in [
                "home.row.topic.unassigned",
                "home.record.unfiled",
                "home.catalog.unfiled_empty",
                "home.catalog.row.unfiled_hint",
                "home.catalog.row.open_unfiled_hint",
                "home.no_notebook.description",
                "capture.settings.context.current_quick_capture",
            ] {
                XCTAssertFalse(source.contains(retired), "\(file) still shows \(retired)")
            }
        }
    }

    // MARK: Return in a search field

    /// The Start button is the window's default action and now shares a page
    /// with the recordings' search field. Return typed into a text field
    /// must never start a recording.
    func testReturnInASearchFieldDoesNotReachTheStartButton() throws {
        var typing = TextEntryFocusKey.defaultValue
        XCTAssertFalse(typing)
        TextEntryFocusKey.reduce(value: &typing) { false }
        XCTAssertFalse(typing)
        TextEntryFocusKey.reduce(value: &typing) { true }
        TextEntryFocusKey.reduce(value: &typing) { false }
        XCTAssertTrue(typing, "one field with the keyboard is enough")

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ZuTalk", isDirectory: true)
        func source(_ file: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
        }
        let card = try source("Pages/HomeStartCard.swift")
        let home = try source("Pages/HomeView.swift")
        let languages = try source("Pages/CaptureLanguageEditor.swift")
        XCTAssertTrue(card.contains(".keyboardShortcut(startsOnReturn ? .defaultAction : nil)"))
        XCTAssertFalse(card.contains(".keyboardShortcut(.defaultAction)"))
        XCTAssertTrue(home.contains(
            "HomeStartCard(library: viewModel, startsOnReturn: isTypingInAField == false)"
        ))
        XCTAssertTrue(home.contains(".onPreferenceChange(TextEntryFocusKey.self)"))
        // Both text fields that sit on Home report when they have the keyboard.
        let report = ".preference(key: TextEntryFocusKey.self, value: isSearchFocused)"
        XCTAssertTrue(home.contains(report))
        XCTAssertTrue(languages.contains(report))
        XCTAssertTrue(languages.contains(".focused($isSearchFocused)"))
    }

    // MARK: Hosting an event

    func testTheCityRowShowsOnlyForSomeoneHostingOrWithAnEventAlreadyPicked() {
        // Not hosting: nothing about cities, signed in or not.
        XCTAssertEqual(
            StartCardHosting.resolve(hostingOn: false, signedIn: false, eventPicked: false),
            .hidden
        )
        XCTAssertEqual(
            StartCardHosting.resolve(hostingOn: false, signedIn: true, eventPicked: false),
            .hidden
        )
        // Hosting and signed in: the per-recording confirmation.
        XCTAssertEqual(
            StartCardHosting.resolve(hostingOn: true, signedIn: true, eventPicked: false),
            .destination
        )
        // Hosting with nobody signed in: one line saying what signing in gives.
        XCTAssertEqual(
            StartCardHosting.resolve(hostingOn: true, signedIn: false, eventPicked: false),
            .signInHint
        )
        // An event picked for the next recording will be filed whatever the
        // switch says, so the row that shows it cannot be hidden.
        XCTAssertEqual(
            StartCardHosting.resolve(hostingOn: false, signedIn: true, eventPicked: true),
            .destination
        )
        XCTAssertEqual(
            StartCardHosting.resolve(hostingOn: false, signedIn: false, eventPicked: true),
            .hidden
        )
    }

    // MARK: The sidebar

    func testTopicsAppearInTheSidebarWithTheFirstTopic() {
        XCTAssertFalse(SidebarTopicPresence.showsTopics(hasTopics: false, isCurrent: false))
        XCTAssertTrue(SidebarTopicPresence.showsTopics(hasTopics: true, isCurrent: false))
        // Still on the Topics page after deleting the last one.
        XCTAssertTrue(SidebarTopicPresence.showsTopics(hasTopics: false, isCurrent: true))
    }

    func testTopicPresenceCountsAtOnceAndAgainWhenTheLibraryChanges() async throws {
        let center = NotificationCenter()
        let count = HomeStartBox<Int?>(0)
        let presence = SidebarTopicPresence(center: center, countTopics: { count.value })
        XCTAssertFalse(presence.hasTopics)

        count.value = 1
        XCTAssertFalse(presence.hasTopics, "nothing said the library changed yet")
        center.post(name: .zutalkSessionUpdated, object: nil)
        try await waitUntil { presence.hasTopics }
        XCTAssertTrue(presence.hasTopics)

        // A library that cannot be read is not a library without topics.
        count.value = nil
        presence.refresh()
        XCTAssertTrue(presence.hasTopics)

        count.value = 0
        presence.refresh()
        XCTAssertFalse(presence.hasTopics)
    }

    func testCreatingATopicTellsTheRestOfTheWindow() {
        let center = NotificationCenter.default
        let posted = HomeStartBox(0)
        let token = center.addObserver(
            forName: .zutalkSessionUpdated,
            object: nil,
            queue: nil
        ) { _ in posted.value += 1 }
        defer { center.removeObserver(token) }
        let viewModel = LibraryViewModel(notebookContext: NotebookSessionContextStore())

        let client = StubNotebookWorkspaceClient()
        XCTAssertFalse(viewModel.createNotebook(title: "  ", client: client))
        XCTAssertEqual(posted.value, 0)
        XCTAssertTrue(viewModel.createNotebook(title: "Weekly", client: client))
        XCTAssertEqual(posted.value, 1)
        XCTAssertEqual(viewModel.researchNotebooks.map(\.title), ["Weekly"])
    }

    func testTheTopicFiltersDoNotOutliveTheLastTopic() {
        let client = StubNotebookWorkspaceClient()
        client.notebooks = [
            FfiNotebook(
                id: "topic-weekly",
                title: "Weekly",
                createdAt: "2000-01-01T00:00:00Z",
                updatedAt: "2000-01-01T00:00:00Z",
                deletedAt: nil
            )
        ]
        let viewModel = LibraryViewModel(notebookContext: NotebookSessionContextStore())
        viewModel.loadNotebookWorkspace(client: client)
        viewModel.selectUnfiledFilter()
        XCTAssertEqual(viewModel.selectedTopicFilterId, LibraryViewModel.unfiledTopicFilterId)

        // Home hides the filter bar with the last topic; a filter left on
        // would be one nobody can see or clear.
        client.notebooks = []
        viewModel.loadNotebookWorkspace(client: client)
        XCTAssertNil(viewModel.selectedTopicFilterId)
    }

    // MARK: Where the Record destination leads

    func testSelectingRecordLandsOnHomeAndAsksForTheStartCard() {
        let store = MainNavigationStore(
            captureRouteContextProvider: { (nil, nil, false) },
            coreProvider: { nil },
            notebookContext: NotebookSessionContextStore()
        )
        store.select(tab: .trash)
        let requests = store.startCardRequests

        store.select(tab: .record)

        XCTAssertEqual(store.activeTab, .home)
        XCTAssertEqual(store.activePrimaryTab, .home)
        XCTAssertEqual(store.activeRoute, .home)
        XCTAssertEqual(store.startCardRequests, requests + 1)

        // Going to Home itself is not a request to scroll its list away.
        store.select(tab: .home)
        XCTAssertEqual(store.startCardRequests, requests + 1)
    }

    func testATopicsRecordButtonLandsOnHomeWithThatTopicWaiting() {
        let store = MainNavigationStore(
            captureRouteContextProvider: { (nil, nil, false) },
            coreProvider: { nil },
            notebookContext: NotebookSessionContextStore()
        )
        store.select(tab: .topics)

        store.openRecordPage(topicID: "topic-weekly")

        XCTAssertEqual(store.activeTab, .home)
        XCTAssertEqual(store.activePrimaryTab, .home)
        XCTAssertEqual(store.recordTopicPreselection, "topic-weekly")
    }

    func testNoRouteLeadsToARecordPage() {
        for tab in MainTab.allCases {
            let store = MainNavigationStore(
                captureRouteContextProvider: { (nil, nil, false) },
                coreProvider: { nil },
                notebookContext: NotebookSessionContextStore()
            )
            store.select(tab: tab)
            XCTAssertNotEqual(store.activeTab, .record, "\(tab) must not show a record page")
        }
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while condition() == false, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

/// A value one test writes and a closure it handed out reads, both on the
/// main thread.
private final class HomeStartBox<Value>: @unchecked Sendable {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }
}
