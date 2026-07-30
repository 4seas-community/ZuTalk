// MenuBarRuntimeStoreTests.swift
//
// State-machine coverage for MenuBarRuntimeStore — the store that drives the
// menu-bar status icon and popover content. Replaces the prior
// IslandRuntimeStoreV2Tests; hover / caption-cluster / suppression-reducer
// scenarios were dropped along with the island UI they coordinated.

import XCTest
import Combine
@testable import Zulangue

@MainActor
final class MenuBarRuntimeStoreTests: XCTestCase {
    var store: MenuBarRuntimeStore!

    override func setUp() async throws {
        try await super.setUp()
        store = MenuBarRuntimeStore.shared
        store.resetForTesting()
    }

    override func tearDown() async throws {
        store.resetForTesting()
        store = nil
        try await super.tearDown()
    }

    func testInitialState_isIdleWithNoSuppression() {
        XCTAssertEqual(store.state, .idle)
        XCTAssertFalse(store.isRecording)
        XCTAssertNil(store.suppressionReason)
        XCTAssertTrue(store.cachedRecentLines.isEmpty)
    }

    func testStartRecording_movesToRecordingCompactState() {
        store.startRecording(info: RecordingInfo(
            sessionId: "session-local",
            remoteRealtimeEnabled: false,
            elapsed: 0
        ))

        guard case .recordingCompact(let info) = store.state else {
            return XCTFail("expected recordingCompact, got \(store.state)")
        }
        XCTAssertEqual(info.elapsed, 0)
        XCTAssertTrue(store.isRecording)
        XCTAssertEqual(store.activeRecordingInfo?.sessionId, "session-local")
        XCTAssertEqual(store.activeRecordingInfo?.remoteRealtimeEnabled, false)
    }

    func testUpdateRecording_mutatesElapsedAndPauseInPlace() {
        store.startRecording(info: RecordingInfo())

        store.updateRecording { info in
            info.elapsed = 42
            info.isPaused = true
        }

        guard case .recordingCompact(let info) = store.state else {
            return XCTFail("state should remain recordingCompact across mutation")
        }
        XCTAssertEqual(info.elapsed, 42)
        XCTAssertTrue(info.isPaused)
    }

    func testUpdateRecording_isNoOpWhenIdle() {
        store.updateRecording { info in
            info.elapsed = 99
        }
        XCTAssertEqual(store.state, .idle)
    }

    func testStopRecording_returnsToIdleAndClearsRecentLines() {
        store.startRecording(info: RecordingInfo())
        store.updateRecordingRecentLines([
            TranscriptLine(timestamp: "00:01", languageLabel: "EN", text: "hi")
        ])

        store.stopRecording()

        XCTAssertEqual(store.state, .idle)
        XCTAssertTrue(store.cachedRecentLines.isEmpty)
        XCTAssertFalse(store.isRecording)
        XCTAssertNil(store.activeRecordingInfo)
    }

    func testReturnToIdle_clearsBackgroundProcessing() {
        let processingInfo = ProcessingInfo(stage: .transcribing, progress: 0.3, sessionId: "sess-1")
        store.showProcessing(processingInfo)
        XCTAssertEqual(store.state, .backgroundProcessing(processingInfo))

        store.returnToIdle()

        XCTAssertEqual(store.state, .idle)
    }

    func testProcessingCompletedPointsToHomeWorkspace() {
        let info = ProcessingInfo(stage: .completed, progress: 1, sessionId: "sess-1")

        XCTAssertEqual(info.label, "Ready in Home")
    }

    func testZulangueAppRoutesCaptureControlsBackToNotebook() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Zulangue", isDirectory: true)
        let source = root.appendingPathComponent("ZulangueApp.swift")
        let contents = try String(contentsOf: source, encoding: .utf8)

        XCTAssertTrue(contents.contains("openActiveNotebookForCapture"))
        XCTAssertFalse(contents.contains("session.start("))
        XCTAssertFalse(contents.contains("session.stop("))
    }

    func testUpdateRecordingRecentLines_cachesLinesWhenCompact() {
        // Popover may open mid-recording — even in `recordingCompact` we cache the
        // lines so the user sees context the instant they expand the popover, not
        // after the next 200ms transcript tick.
        store.startRecording(info: RecordingInfo())
        let lines = [
            TranscriptLine(timestamp: "00:01", languageLabel: "EN", text: "hello"),
            TranscriptLine(timestamp: "00:03", languageLabel: "ZH", text: "world")
        ]

        store.updateRecordingRecentLines(lines)

        XCTAssertEqual(store.cachedRecentLines.count, 2)
        if case .recordingCompact = store.state {
            // ok — state stays compact while we cache lines
        } else {
            XCTFail("state should stay compact while caching lines")
        }
    }

    func testUpdateRecordingRecentLines_isNoOpWhenIdle() {
        store.updateRecordingRecentLines([
            TranscriptLine(timestamp: "00:01", languageLabel: "EN", text: "x")
        ])
        XCTAssertTrue(store.cachedRecentLines.isEmpty)
    }

    func testSetSuppressed_setsAndClearsReason() {
        store.setSuppressed(.privacy)
        XCTAssertEqual(store.suppressionReason, .privacy)

        store.setSuppressed(nil)
        XCTAssertNil(store.suppressionReason)
    }

    func testSetSuppressed_isIdempotentForSameReason() {
        var notifications = 0
        let cancellable = store.$suppressionReason.dropFirst().sink { _ in
            notifications += 1
        }
        defer { cancellable.cancel() }

        store.setSuppressed(.privacy)
        store.setSuppressed(.privacy)
        store.setSuppressed(.privacy)

        XCTAssertEqual(notifications, 1, "duplicate setSuppressed should not republish")
    }

}
