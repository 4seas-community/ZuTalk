import XCTest
@testable import Zulangue

/// The combination table the content area used to enumerate by hand in a
/// SwiftUI `if / else if` chain. Every (tab, session, status, overlay)
/// combination must resolve to a named surface — the blank page was a
/// combination nobody had written a branch for.
final class EditorSurfaceTests: XCTestCase {

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
        resources: Bool = false
    ) -> EditorSurface {
        EditorSurfacePolicy.resolve(
            route: route,
            activeTab: tab,
            presentedCaptureSettingsNotebookId: captureSettings,
            isShowingResources: resources
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

    func testAsyncPendingAndFailedAreNamedEvenWithASession() {
        XCTAssertEqual(
            resolve(route: route(session: "s1"), tab: tab(.asyncTranscript, status: .pending)),
            .asyncPending(notebookId: "nb", tabId: "tab")
        )
        XCTAssertEqual(
            resolve(route: route(session: "s1"), tab: tab(.asyncTranscript, status: .failed)),
            .asyncFailed(notebookId: "nb", tabId: "tab")
        )
    }

    func testAsyncPendingAndFailedOutrankTheMissingSession() {
        // Status is the more useful thing to say: the session will arrive when
        // the task finishes, so "still transcribing" beats "pick a recording".
        XCTAssertEqual(
            resolve(route: route(session: nil), tab: tab(.asyncTranscript, status: .pending)),
            .asyncPending(notebookId: "nb", tabId: "tab")
        )
        XCTAssertEqual(
            resolve(route: route(session: nil), tab: tab(.asyncTranscript, status: .failed)),
            .asyncFailed(notebookId: "nb", tabId: "tab")
        )
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

    func testManualNoteSplitsOnSession() {
        XCTAssertEqual(
            resolve(route: route(session: nil), tab: tab(.manualNote)),
            .manualTimeline(notebookId: "nb", tabId: "tab")
        )
        let opened = resolve(route: route(session: "s1"), tab: tab(.manualNote))
        XCTAssertEqual(opened, .manualNote(notebookId: "nb", tabId: "tab"))
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

        var seen: Set<EditorSurface> = []
        for displayType in displayTypes {
            for status in statuses {
                for session in sessions {
                    for (settings, resources) in overlays {
                        let surface = resolve(
                            route: route(session: session),
                            tab: tab(displayType, status: status),
                            captureSettings: settings,
                            resources: resources
                        )
                        seen.insert(surface)
                    }
                }
            }
        }

        // 96 combinations collapse onto exactly these eleven named surfaces.
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
                .asyncPending(notebookId: "nb", tabId: "tab"),
                .asyncFailed(notebookId: "nb", tabId: "tab"),
                .asyncNeedsSession(notebookId: "nb"),
                .asyncTranscript(notebookId: "nb", sessionId: "s1", tabId: "tab", status: .ready),
                .asyncTranscript(notebookId: "nb", sessionId: "s1", tabId: "tab", status: .live),
                .manualTimeline(notebookId: "nb", tabId: "tab"),
                .manualNote(notebookId: "nb", tabId: "tab"),
            ]
        )
    }
}
