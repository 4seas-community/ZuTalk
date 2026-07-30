import XCTest
@testable import Zulangue

final class EditorAPITests: XCTestCase {

    private var core: ZulangueCore!
    private var tempDir: String!

    override func setUp() {
        tempDir = NSTemporaryDirectory()
            .appending("zulangue-editor-\(UUID().uuidString)")
        core = try! ZulangueCore.newDeferred(dataDir: tempDir)
    }

    override func tearDown() {
        try? core.shutdown()
        try? FileManager.default.removeItem(atPath: tempDir)
    }

    private func makeManualTarget(title: String = "Editor") throws -> (String, String) {
        let notebook = try core.createNotebook(title: title)
        let tab = try XCTUnwrap(
            core.listNotebookTabs(notebookId: notebook.id)
                .first { $0.builtinKind == "manual_note" }
        )
        return (notebook.id, tab.id)
    }

    // --- Editor lifecycle ---

    func testEditorOpenInsertGetClose() throws {
        let (notebookId, tabId) = try makeManualTarget()
        try core.openEditor(notebookId: notebookId, tabId: tabId)

        try core.applyEdit(
            notebookId: notebookId,
            tabId: tabId,
            op: .insert(pos: 0, text: "Hello World")
        )

        let content = try core.getEditorContent(notebookId: notebookId, tabId: tabId)
        XCTAssertTrue(content.contains("Hello World"),
                       "content should contain inserted text, got: \(content)")

        try core.closeEditor(notebookId: notebookId, tabId: tabId)
    }

    func testEditorDeleteOperation() throws {
        let (notebookId, tabId) = try makeManualTarget()
        try core.openEditor(notebookId: notebookId, tabId: tabId)
        try core.applyEdit(
            notebookId: notebookId,
            tabId: tabId,
            op: .insert(pos: 0, text: "ABCDE")
        )

        try core.applyEdit(
            notebookId: notebookId,
            tabId: tabId,
            op: .delete(pos: 0, len: 2)
        )

        let content = try core.getEditorContent(notebookId: notebookId, tabId: tabId)
        XCTAssertEqual(content, "CDE")

        try core.closeEditor(notebookId: notebookId, tabId: tabId)
    }

    func testArbitraryTabIdentityFailsClosed() throws {
        let notebook = try core.createNotebook(title: "Boundary")
        XCTAssertThrowsError(
            try core.openEditor(notebookId: notebook.id, tabId: "caller-supplied-doc-id")
        )
    }

    func testEditorMultipleSessions() throws {
        let first = try makeManualTarget(title: "First")
        let second = try makeManualTarget(title: "Second")
        try core.openEditor(notebookId: first.0, tabId: first.1)
        try core.openEditor(notebookId: second.0, tabId: second.1)

        try core.applyEdit(notebookId: first.0, tabId: first.1, op: .insert(pos: 0, text: "Session1"))
        try core.applyEdit(notebookId: second.0, tabId: second.1, op: .insert(pos: 0, text: "Session2"))

        let c1 = try core.getEditorContent(notebookId: first.0, tabId: first.1)
        let c2 = try core.getEditorContent(notebookId: second.0, tabId: second.1)

        XCTAssertTrue(c1.contains("Session1"))
        XCTAssertTrue(c2.contains("Session2"))
        XCTAssertFalse(c1.contains("Session2"), "sessions should be isolated")

        try core.closeEditor(notebookId: first.0, tabId: first.1)
        try core.closeEditor(notebookId: second.0, tabId: second.1)
    }
}
