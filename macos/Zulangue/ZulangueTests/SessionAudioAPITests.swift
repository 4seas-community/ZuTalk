import XCTest
@testable import Zulangue

final class SessionAudioAPITests: XCTestCase {

    private var core: ZulangueCore!
    private var tempDir: String!

    override func setUp() {
        tempDir = NSTemporaryDirectory()
            .appending("zulangue-session-audio-\(UUID().uuidString)")
        core = try! ZulangueCore.newDeferred(dataDir: tempDir)
    }

    override func tearDown() {
        try? core.shutdown()
        try? FileManager.default.removeItem(atPath: tempDir)
    }

    func testImportNonexistentFileThrows() {
        let notebook = try! core.createNotebook(title: "Import test")
        XCTAssertThrowsError(
            try core.importAudioIntoNotebook(
                path: "/nonexistent/audio.mp3",
                notebookId: notebook.id
            )
        )
    }

    func testListTasksReturnsEmpty() throws {
        let tasks = try core.listTasks(statusFilter: nil)
        XCTAssertTrue(tasks.isEmpty)
    }

    func testGetTaskStatusNotFound() {
        XCTAssertThrowsError(try core.getTaskStatus(taskId: "nonexistent"))
    }

    func testGetAudioSegmentValidation() {
        // end_ms <= start_ms should fail
        XCTAssertThrowsError(
            try core.getAudioSegment(sessionId: "s1", startMs: 2000, endMs: 1000)
        )
        XCTAssertThrowsError(
            try core.getAudioSegment(sessionId: "s1", startMs: 0, endMs: 1_000)
        )
    }

}

@MainActor
final class NotebookSessionContextStoreTests: XCTestCase {
    func testNotebookContextRequiresActiveNotebookBeforeRecording() {
        let context = NotebookSessionContextStore()

        XCTAssertThrowsError(try context.requireActiveNotebookId())

        context.updateActiveNotebook(id: "nb-1", title: "Research")
        XCTAssertEqual(try context.requireActiveNotebookId(), "nb-1")
    }

    func testLastNotebookPersistsAcrossStoreInstancesUntilExplicitlyForgotten() throws {
        let suiteName = "NotebookSessionContextStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = NotebookSessionContextStore(defaults: defaults)
        first.updateActiveNotebook(id: "nb-last", title: "Last Notebook")
        first.clearActiveNotebook()

        let restored = NotebookSessionContextStore(defaults: defaults)
        XCTAssertEqual(restored.activeNotebookId, "nb-last")
        XCTAssertNil(restored.activeNotebookTitle, "titles are resolved fresh from Core")

        restored.forgetLastNotebook()
        XCTAssertNil(NotebookSessionContextStore(defaults: defaults).activeNotebookId)
    }

}
