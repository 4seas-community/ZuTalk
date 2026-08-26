import XCTest
@testable import ZuTalk

/// The combination table the content area used to enumerate by hand in a
/// SwiftUI `if / else if` chain. Every (tab, session, status, overlay)
/// combination must resolve to a named surface — the blank page was a
/// combination nobody had written a branch for.
final class EditorSurfaceTests: XCTestCase {

    @MainActor
    func testAsyncTranscriptContentPrefersDurableLinesOverTransientState() {
        XCTAssertEqual(
            AsyncTranscriptContentPolicy.phase(
                hasLines: true,
                projectionState: nil,
                providerState: "pending",
                tabStatus: .pending,
                hasOperationInFlight: true
            ),
            .transcript
        )
    }

    @MainActor
    func testAsyncTranscriptContentUsesLoadingOnlyForNonterminalWork() {
        XCTAssertEqual(
            AsyncTranscriptContentPolicy.phase(
                hasLines: false,
                projectionState: nil,
                providerState: nil,
                tabStatus: .ready,
                hasOperationInFlight: false,
                hasLoadFailure: true
            ),
            .empty
        )
        XCTAssertEqual(
            AsyncTranscriptContentPolicy.phase(
                hasLines: false,
                projectionState: nil,
                providerState: nil,
                tabStatus: .ready,
                hasOperationInFlight: false
            ),
            .loading
        )
        XCTAssertEqual(
            AsyncTranscriptContentPolicy.phase(
                hasLines: false,
                projectionState: .projecting,
                providerState: "completed",
                tabStatus: .ready,
                hasOperationInFlight: false
            ),
            .loading
        )
        XCTAssertEqual(
            AsyncTranscriptContentPolicy.phase(
                hasLines: false,
                projectionState: NotebookAsyncProjectionState.none,
                providerState: "reserved",
                tabStatus: .pending,
                hasOperationInFlight: false
            ),
            .loading
        )
        XCTAssertEqual(
            AsyncTranscriptContentPolicy.phase(
                hasLines: false,
                projectionState: .failed,
                providerState: "failed",
                tabStatus: .failed,
                hasOperationInFlight: false
            ),
            .empty
        )
        XCTAssertEqual(
            AsyncTranscriptContentPolicy.phase(
                hasLines: false,
                projectionState: NotebookAsyncProjectionState.none,
                providerState: "failed",
                tabStatus: .pending,
                hasOperationInFlight: false
            ),
            .empty,
            "a stale tab status must not turn a terminal provider failure into a spinner"
        )
        XCTAssertEqual(
            AsyncTranscriptContentPolicy.phase(
                hasLines: false,
                projectionState: NotebookAsyncProjectionState.none,
                providerState: "none",
                tabStatus: .ready,
                hasOperationInFlight: false
            ),
            .empty
        )
    }

    @MainActor
    func testAsyncTranscriptTimestampMatchesRealtimeTimelineFormat() {
        XCTAssertEqual(TranscriptTimestampPresentation.text(milliseconds: 3_999), "00:03")
        XCTAssertEqual(
            TranscriptTimestampPresentation.text(milliseconds: 3_661_000),
            "01:01:01"
        )
    }

    func testAsyncTranscriptMetadataNoticeRequiresTranscriptContent() {
        XCTAssertFalse(AsyncTranscriptMetadataNoticePolicy.shouldShow(for: []))
        XCTAssertFalse(
            AsyncTranscriptMetadataNoticePolicy.shouldShow(
                for: [asyncTranscriptLine(text: " \n ")]
            )
        )
    }

    func testAsyncTranscriptMetadataNoticeShowsWhenEveryRowLacksProviderMetadata() {
        XCTAssertTrue(
            AsyncTranscriptMetadataNoticePolicy.shouldShow(
                for: [
                    asyncTranscriptLine(id: "one", text: "First segment"),
                    asyncTranscriptLine(
                        id: "two",
                        text: "Second segment",
                        sourceLanguage: " und-Latn ",
                        providerSpeakerLabel: "  "
                    )
                ]
            )
        )
    }

    func testAsyncTranscriptMetadataNoticeHidesWhenAnyRowHasProviderMetadata() {
        let legacyLine = asyncTranscriptLine(id: "legacy", text: "Legacy segment")

        XCTAssertFalse(
            AsyncTranscriptMetadataNoticePolicy.shouldShow(
                for: [
                    legacyLine,
                    asyncTranscriptLine(
                        id: "speaker",
                        text: "Speaker segment",
                        providerSpeakerLabel: "spk_0"
                    )
                ]
            )
        )
        XCTAssertFalse(
            AsyncTranscriptMetadataNoticePolicy.shouldShow(
                for: [
                    legacyLine,
                    asyncTranscriptLine(
                        id: "language",
                        text: "Language segment",
                        sourceLanguage: "en-US"
                    )
                ]
            )
        )
    }

    private func asyncTranscriptLine(
        id: String = "line",
        text: String,
        sourceLanguage: String? = nil,
        providerSpeakerLabel: String? = nil
    ) -> NotebookTranscriptLine {
        NotebookTranscriptLine(
            id: id,
            startMs: nil,
            endMs: nil,
            sourceLanguage: sourceLanguage,
            providerSpeakerLabel: providerSpeakerLabel,
            text: text
        )
    }

    private func route(
        notebook: String = "nb",
        tab: String = "tab",
        document: String = "doc",
        session: String? = nil
    ) -> EditorRoute {
        EditorRoute(
            notebookID: notebook,
            tabID: tab,
            documentID: document,
            selectedSessionID: session
        )
    }

    private func tab(
        _ displayType: NotebookTabDisplayType,
        status: NotebookTabStatus = .ready,
        tabId: String = "tab"
    ) -> NotebookTabViewModel {
        NotebookTabViewModel(
            id: tabId,
            notebookId: "nb",
            tabId: tabId,
            displayType: displayType,
            documentId: "doc",
            sessionLink: nil,
            title: "t",
            status: status,
            position: 0
        )
    }

    private func resolve(
        route: EditorRoute?,
        tab: NotebookTabViewModel?,
        captureSettings: String? = nil,
        resources: Bool = false,
        sessionSupplementarySurface: SessionSupplementarySurface? = nil
    ) -> EditorSurface {
        EditorSurfacePolicy.resolve(
            route: route,
            activeTab: tab,
            presentedCaptureSettingsNotebookId: captureSettings,
            isShowingResources: resources,
            sessionSupplementarySurface: sessionSupplementarySurface
        )
    }

    // MARK: - The two surfaces that used to render blank

    func testAsyncTabWithoutSessionIsItsOwnSurface() {
        let surface = resolve(route: route(session: nil), tab: tab(.asyncTranscript))

        XCTAssertEqual(surface, .asyncNeedsSession(notebookId: "nb"))
        XCTAssertFalse(surface.showsTranscriptLayer)
    }

    func testDocumentWhoseTabsHaveNotLoadedIsItsOwnSurface() {
        let surface = resolve(route: route(), tab: nil)

        XCTAssertEqual(surface, .tabsLoading(notebookId: "nb"))
    }

    // MARK: - Route level

    func testNilRouteIsMissingDocument() {
        XCTAssertEqual(resolve(route: nil, tab: nil), .missingDocument)
    }

    func testEmptyDocumentIdIsMissingDocument() {
        XCTAssertEqual(resolve(route: route(document: ""), tab: tab(.manualNote)), .missingDocument)
    }

    // MARK: - Overlay precedence

    func testCaptureSettingsCoversTabContent() {
        for displayType in [
            NotebookTabDisplayType.realtimeTranscript, .asyncTranscript, .manualNote,
        ] {
            let surface = resolve(
                route: route(session: "s1"),
                tab: tab(displayType),
                captureSettings: "nb"
            )
            XCTAssertEqual(surface, .captureSettings(notebookId: "nb"), "\(displayType)")
            XCTAssertTrue(surface.showsNotebookOverlay)
        }
    }

    func testCaptureSettingsForAnotherNotebookDoesNotCover() {
        let surface = resolve(
            route: route(session: "s1"),
            tab: tab(.manualNote),
            captureSettings: "other-notebook"
        )

        XCTAssertEqual(surface, .manualNote(notebookId: "nb", tabId: "tab"))
    }

    func testResourcesCoversTabContent() {
        let surface = resolve(route: route(session: "s1"), tab: tab(.manualNote), resources: true)

        XCTAssertEqual(surface, .resources(notebookId: "nb"))
        XCTAssertTrue(surface.showsNotebookOverlay)
    }

    func testCaptureSettingsOutranksResources() {
        let surface = resolve(
            route: route(),
            tab: tab(.manualNote),
            captureSettings: "nb",
            resources: true
        )

        XCTAssertEqual(surface, .captureSettings(notebookId: "nb"))
    }

    // MARK: - Realtime

    func testRealtimeResolvesWithAndWithoutSession() {
        XCTAssertEqual(
            resolve(route: route(session: nil), tab: tab(.realtimeTranscript)),
            .realtime(notebookId: "nb", sessionId: nil)
        )
        XCTAssertEqual(
            resolve(route: route(session: "s1"), tab: tab(.realtimeTranscript)),
            .realtime(notebookId: "nb", sessionId: "s1")
        )
    }

    func testRealtimeIgnoresStatusBecauseItIsNeverTranscribed() {
        for status in [NotebookTabStatus.ready, .pending, .failed, .live] {
            XCTAssertEqual(
                resolve(route: route(), tab: tab(.realtimeTranscript, status: status)),
                .realtime(notebookId: "nb", sessionId: nil),
                "\(status)"
            )
        }
    }

    // MARK: - Async

    func testAsyncPendingAndFailedKeepTheSelectedRecordingSurfaceMounted() {
        XCTAssertEqual(
            resolve(route: route(session: "s1"), tab: tab(.asyncTranscript, status: .pending)),
            .asyncTranscript(
                notebookId: "nb",
                sessionId: "s1",
                tabId: "tab",
                status: .pending
            )
        )
        XCTAssertEqual(
            resolve(route: route(session: "s1"), tab: tab(.asyncTranscript, status: .failed)),
            .asyncTranscript(
                notebookId: "nb",
                sessionId: "s1",
                tabId: "tab",
                status: .failed
            )
        )
    }

    func testEveryAsyncStatusWithoutASessionAsksForARecording() {
        for status in [NotebookTabStatus.ready, .pending, .failed, .live] {
            XCTAssertEqual(
                resolve(route: route(session: nil), tab: tab(.asyncTranscript, status: status)),
                .asyncNeedsSession(notebookId: "nb"),
                "\(status)"
            )
        }
    }

    func testAsyncReadyWithSessionShowsTranscript() {
        let surface = resolve(
            route: route(session: "s1"),
            tab: tab(.asyncTranscript, status: .ready)
        )

        XCTAssertEqual(
            surface,
            .asyncTranscript(notebookId: "nb", sessionId: "s1", tabId: "tab", status: .ready)
        )
        XCTAssertTrue(surface.showsTranscriptLayer)
    }

    // MARK: - Manual notes

    func testManualNoteIsOneHonestTopicDocumentWithOrWithoutSessionContext() {
        XCTAssertEqual(
            resolve(route: route(session: nil), tab: tab(.manualNote)),
            .manualNote(notebookId: "nb", tabId: "tab")
        )
        let opened = resolve(route: route(session: "s1"), tab: tab(.manualNote))
        XCTAssertEqual(opened, .manualNote(notebookId: "nb", tabId: "tab"))
    }

    func testSessionNoteAndSettingsAreIndependentNamedSurfaces() {
        XCTAssertEqual(
            resolve(
                route: route(session: "s1"),
                tab: tab(.realtimeTranscript),
                sessionSupplementarySurface: .note
            ),
            .sessionNote(notebookId: "nb", sessionId: "s1")
        )
        XCTAssertEqual(
            resolve(
                route: route(session: "s1"),
                tab: tab(.asyncTranscript),
                sessionSupplementarySurface: .settings
            ),
            .sessionSettings(notebookId: "nb", sessionId: "s1")
        )
    }

    func testSessionSupplementaryTabsRequireAConcreteSession() {
        XCTAssertEqual(
            resolve(
                route: route(session: nil),
                tab: tab(.realtimeTranscript),
                sessionSupplementarySurface: .note
            ),
            .realtime(notebookId: "nb", sessionId: nil)
        )
    }

    func testSessionSupplementarySurfaceOutranksStaleTopicOverlayState() {
        XCTAssertEqual(
            resolve(
                route: route(session: "s1"),
                tab: tab(.realtimeTranscript),
                captureSettings: "nb",
                resources: true,
                sessionSupplementarySurface: .settings
            ),
            .sessionSettings(notebookId: "nb", sessionId: "s1")
        )
    }

    // MARK: - Totality

    /// The property the old model could not state: every combination resolves
    /// onto a named surface, so nothing can fall through to a blank page.
    func testEveryCombinationResolvesToANamedSurface() {
        let displayTypes: [NotebookTabDisplayType] = [
            .realtimeTranscript, .asyncTranscript, .manualNote,
        ]
        let statuses: [NotebookTabStatus] = [.ready, .pending, .failed, .live]
        let sessions: [String?] = [nil, "s1"]
        let overlays: [(String?, Bool)] = [(nil, false), ("nb", false), (nil, true), ("nb", true)]
        let sessionSurfaces: [SessionSupplementarySurface?] = [nil, .note, .settings]

        var seen: Set<EditorSurface> = []
        for displayType in displayTypes {
            for status in statuses {
                for session in sessions {
                    for (settings, resources) in overlays {
                        for sessionSurface in sessionSurfaces {
                            let surface = resolve(
                                route: route(session: session),
                                tab: tab(displayType, status: status),
                                captureSettings: settings,
                                resources: resources,
                                sessionSupplementarySurface: sessionSurface
                            )
                            seen.insert(surface)
                        }
                    }
                }
            }
        }

        // 96 combinations collapse onto these named surfaces.
        // Listing them is the point: the old model could not say what the
        // content area was capable of showing. (documentUnavailable left with
        // the Loro text bridge: the outline editor owns its own failure state.)
        XCTAssertEqual(
            seen,
            [
                .captureSettings(notebookId: "nb"),
                .resources(notebookId: "nb"),
                .realtime(notebookId: "nb", sessionId: nil),
                .realtime(notebookId: "nb", sessionId: "s1"),
                .asyncNeedsSession(notebookId: "nb"),
                .asyncTranscript(notebookId: "nb", sessionId: "s1", tabId: "tab", status: .ready),
                .asyncTranscript(notebookId: "nb", sessionId: "s1", tabId: "tab", status: .pending),
                .asyncTranscript(notebookId: "nb", sessionId: "s1", tabId: "tab", status: .failed),
                .asyncTranscript(notebookId: "nb", sessionId: "s1", tabId: "tab", status: .live),
                .sessionNote(notebookId: "nb", sessionId: "s1"),
                .sessionSettings(notebookId: "nb", sessionId: "s1"),
                .manualNote(notebookId: "nb", tabId: "tab"),
            ]
        )
    }

    func testAsyncTranscriptPresentationNeverHidesASelectedRecordingByStatus() {
        for status in [NotebookTabStatus.ready, .pending, .failed, .live] {
            XCTAssertTrue(
                NotebookTranscriptPresentationPolicy.shouldShow(
                    displayType: .asyncTranscript,
                    status: status,
                    selectedSessionId: "s1"
                ),
                "\(status)"
            )
        }
        XCTAssertFalse(
            NotebookTranscriptPresentationPolicy.shouldShow(
                displayType: .asyncTranscript,
                status: .ready,
                selectedSessionId: nil
            )
        )
    }

    func testResourceDestinationsMapToTheirExactNotebookTabs() {
        XCTAssertNil(NotebookResourceDestination.audio.displayType)
        XCTAssertEqual(
            NotebookResourceDestination.realtimeTranscript.displayType,
            .realtimeTranscript
        )
        XCTAssertEqual(
            NotebookResourceDestination.asyncTranscript.displayType,
            .asyncTranscript
        )
        XCTAssertEqual(
            NotebookResourceDestination.manualNote.displayType,
            .manualNote
        )
    }

    func testAsyncPrimaryActionKeepsCredentialRecoveryVisibleWithoutReuploadingFailures() {
        XCTAssertEqual(
            AsyncTranscriptActionPolicy.primaryAction(
                projectionState: NotebookAsyncProjectionState.none,
                providerState: "none",
                hasReadyPersonalKey: true
            ),
            .start
        )
        XCTAssertEqual(
            AsyncTranscriptActionPolicy.primaryAction(
                projectionState: NotebookAsyncProjectionState.none,
                providerState: "none",
                hasReadyPersonalKey: false
            ),
            .addPersonalKey
        )
        XCTAssertEqual(
            AsyncTranscriptActionPolicy.primaryAction(
                projectionState: NotebookAsyncProjectionState.none,
                providerState: "pending",
                hasReadyPersonalKey: false
            ),
            .addPersonalKey
        )
        XCTAssertEqual(
            AsyncTranscriptActionPolicy.primaryAction(
                projectionState: NotebookAsyncProjectionState.none,
                providerState: "failed",
                hasReadyPersonalKey: true
            ),
            .none
        )
        XCTAssertEqual(
            AsyncTranscriptActionPolicy.primaryAction(
                projectionState: .failed,
                providerState: "completed",
                hasReadyPersonalKey: true
            ),
            .none
        )
        XCTAssertEqual(
            AsyncTranscriptActionPolicy.primaryAction(
                projectionState: nil,
                providerState: nil,
                hasReadyPersonalKey: true
            ),
            .none
        )
    }

    func testAsyncProviderPendingPolicyCoversEveryDurableQueueState() {
        for state in ["pending", "reserved", "enqueued", "PENDING"] {
            XCTAssertTrue(AsyncTranscriptActionPolicy.isProviderPending(state), state)
        }
        for state in ["none", "completed", "failed"] {
            XCTAssertFalse(AsyncTranscriptActionPolicy.isProviderPending(state), state)
        }
        XCTAssertFalse(AsyncTranscriptActionPolicy.isProviderPending(nil))
    }
}
