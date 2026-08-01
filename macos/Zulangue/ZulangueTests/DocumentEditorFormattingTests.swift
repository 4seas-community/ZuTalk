import AppKit
import XCTest
@testable import Zulangue

final class DocumentEditorExportEntryTests: XCTestCase {
    func testDocumentEditorMountsExportSheetFromSessionTabAction() throws {
        let source = try Self.loadDocumentEditorPage()

        XCTAssertTrue(source.contains("@State private var isShowingExportSheet = false"))
        XCTAssertTrue(source.contains(".sheet(isPresented: $isShowingExportSheet)"))
        XCTAssertTrue(source.contains("ExportSheet(sessionId: sessionId)"))
        XCTAssertTrue(source.contains("tray.and.arrow.up"))
        XCTAssertTrue(source.contains(".disabled(sessionId == nil)"))
    }

    private static func loadDocumentEditorPage() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Zulangue", isDirectory: true)
        return try String(
            contentsOf: root.appendingPathComponent("Pages/DocumentEditorPage.swift"),
            encoding: .utf8
        )
    }
}

final class DocumentEditorTabLayoutTests: XCTestCase {
    func testNotebookTabBarStaysAboveVariableTabContent() throws {
        let source = try Self.loadDocumentEditorPage()
        let topChrome = try XCTUnwrap(source.range(of: "NoteTopChrome("))
        let tabBar = try XCTUnwrap(source.range(of: "DocumentTabBar("))
        let settingsHeader = try XCTUnwrap(
            source.range(of: "NotebookSettingsNotebookHeader(title: editorNotebook?.title)")
        )
        let builtinTitle = try XCTUnwrap(
            source.range(of: "NotebookBuiltinTabTitle(title: activeNotebookTab?.title)")
        )
        let manualNoteHeader = try XCTUnwrap(source.range(of: "ManualTimeNoteHeader("))
        let metadataBar = try XCTUnwrap(
            source.range(of: "NoteMetadataBar(sessionId: effectiveSessionId)")
        )

        XCTAssertLessThan(topChrome.lowerBound, tabBar.lowerBound)
        XCTAssertLessThan(tabBar.lowerBound, settingsHeader.lowerBound)
        XCTAssertLessThan(tabBar.lowerBound, builtinTitle.lowerBound)
        XCTAssertLessThan(tabBar.lowerBound, manualNoteHeader.lowerBound)
        XCTAssertLessThan(tabBar.lowerBound, metadataBar.lowerBound)
        XCTAssertTrue(source.contains("} else if isShowingResources == false {"))
    }

    private static func loadDocumentEditorPage() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Zulangue", isDirectory: true)
        return try String(
            contentsOf: root.appendingPathComponent("Pages/DocumentEditorPage.swift"),
            encoding: .utf8
        )
    }
}

final class DocumentEditorTaskQueuePanelTests: XCTestCase {
    func testDocumentEditorMountsTaskQueuePanel() throws {
        let source = try Self.loadDocumentEditorPage()

        XCTAssertTrue(source.contains("case tasks"))
        XCTAssertTrue(source.contains("@StateObject private var notebookTasks = NotebookTasksViewModel()"))
        XCTAssertTrue(source.contains("NotebookTasksPanel(viewModel: notebookTasks)"))
        XCTAssertTrue(source.contains("ToolButton(systemIcon: \"checklist\""))
        XCTAssertTrue(source.contains("client.listTasks(statusFilter: nil)"))
    }

    private static func loadDocumentEditorPage() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Zulangue", isDirectory: true)
        return try String(
            contentsOf: root.appendingPathComponent("Pages/DocumentEditorPage.swift"),
            encoding: .utf8
        )
    }
}

final class DocumentEditorMinimalMVPSmokeTests: XCTestCase {
    func testEditorExcludesAgentAndAmbientMutationSurfacesButKeepsLocalEditing() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Zulangue", isDirectory: true)
        let page = try String(
            contentsOf: root.appendingPathComponent("Pages/DocumentEditorPage.swift"),
            encoding: .utf8
        )
        let bridge = try String(
            contentsOf: root.appendingPathComponent("Bridge/Generated/vt_ffi.swift"),
            encoding: .utf8
        )

        for removedSymbol in [
            "requestAmbientProofread",
            "requestAmbientSupplement",
            "pushAmbientIdle",
            "applyAgentEdit",
            "AgentTabPolicyEditor",
            "AgentChangeReviewView",
            "startEnhance",
            "onApplyTemplate",
        ] {
            XCTAssertFalse(page.contains(removedSymbol), "\(removedSymbol) must stay outside the MVP editor")
        }
        for removedBridgeSymbol in [
            "startEnhance",
            "autoTitleSession",
            "setAutoSummary",
            "clearAutoSummary",
        ] {
            XCTAssertFalse(
                bridge.contains(removedBridgeSymbol),
                "\(removedBridgeSymbol) must stay outside the MVP FFI surface"
            )
        }

        XCTAssertTrue(page.contains("DocumentTextView("))
        XCTAssertTrue(page.contains("final class LoroBackedTextView: NSTextView"))
        XCTAssertTrue(page.contains("func textDidChange(_ notification: Notification)"))
        XCTAssertTrue(page.contains(".accessibilityHint(Text(isEditable ?"))
        XCTAssertFalse(page.contains("NotebookAskPanel("))
        XCTAssertFalse(page.contains("submitNotebookAskTask"))
        XCTAssertFalse(page.contains("editor.toolbar.show_sources"))
        XCTAssertFalse(page.contains("d.templateId == \"transcript-hd\""))
        XCTAssertFalse(page.contains("d.kind == \"enhanced\" && d.status != \"ready\""))
    }

    func testTranscriptEmptyStatesDistinguishLocalRealtimeAndAsyncWork() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Zulangue", isDirectory: true)
        let page = try String(
            contentsOf: root.appendingPathComponent("Pages/DocumentEditorPage.swift"),
            encoding: .utf8
        )
        let captureViews = try String(
            contentsOf: root.appendingPathComponent("Pages/NotebookCaptureViews.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(page.contains("NotebookRealtimeTranscriptPage("))
        XCTAssertTrue(page.contains("AsyncTranscriptView("))
        XCTAssertFalse(page.contains("struct TranscriptView: View"))
        XCTAssertTrue(captureViews.contains("NotebookRealtimeProjectionPolicy.layout"))
        XCTAssertTrue(captureViews.contains("capture.transcript.transcription_empty_title"))
        XCTAssertTrue(captureViews.contains("editor.transcript.realtime.empty_title"))
        XCTAssertTrue(page.contains("editor.transcript.async.pending_title"))
        XCTAssertTrue(page.contains("editor.transcript.async.failed_title"))
        XCTAssertTrue(page.contains("editor.transcript.async.empty_title"))
        XCTAssertFalse(page.contains("recordingStore.activeRecordingInfo"))
    }
}

final class DocumentEditorWorkspacePanelLocalizationTests: XCTestCase {
    func testTaskPanelUsesLocalizedCopyAndAskIsAbsent() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Zulangue", isDirectory: true)
        let source = try String(
            contentsOf: root.appendingPathComponent("Pages/DocumentEditorPage.swift"),
            encoding: .utf8
        )

        for key in ["editor.tasks.title", "editor.tasks.empty"] {
            XCTAssertTrue(source.contains(key), "\(key) should be used by editor workspace panels")
        }

        XCTAssertFalse(source.contains("NotebookAskPanel"))
        XCTAssertFalse(source.contains("editor.ask."))
        XCTAssertFalse(source.contains("Text(\"No tasks yet\")"))
        XCTAssertFalse(source.contains("Text(\"No provenance yet\")"))
        XCTAssertFalse(source.contains(".help(\"Submit notebook question\")"))
        XCTAssertFalse(source.contains(".help(\"Refresh sources\")"))
        XCTAssertFalse(source.contains("ToastCenter.shared.error(\"Notebook ask failed\""))
    }

    func testToolbarWorkspaceActionsUseLocalizedTooltips() throws {
        let source = try Self.loadDocumentEditorPage()
        let toolbarKeys = ["editor.toolbar.show_tasks"]

        for key in toolbarKeys {
            XCTAssertTrue(
                source.contains("tooltip: String(localized: \"\(key)\")"),
                "\(key) should be used by editor toolbar actions"
            )
        }

        for staleTooltip in [
            "tooltip: \"Show tasks\""
        ] {
            XCTAssertFalse(source.contains(staleTooltip), "\(staleTooltip) should be localized")
        }

        for locale in ["en.lproj", "zh-Hans.lproj", "ja.lproj"] {
            let strings = try Self.loadLocalization(locale)
            for key in toolbarKeys {
                XCTAssertTrue(strings.contains("\"\(key)\" ="), "\(locale) should define \(key)")
            }
        }
    }

    private static func loadDocumentEditorPage() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Zulangue", isDirectory: true)
        return try String(
            contentsOf: root.appendingPathComponent("Pages/DocumentEditorPage.swift"),
            encoding: .utf8
        )
    }

    private static func loadLocalization(_ locale: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Zulangue", isDirectory: true)
        return try String(
            contentsOf: root.appendingPathComponent("Resources/\(locale)/Localizable.strings"),
            encoding: .utf8
        )
    }
}

final class DocumentEditorFormattingTests: XCTestCase {
    func testLegacyListStringDecodesAsDepthOne() {
        let style = LoroListStyle.decode(from: "bullet")

        XCTAssertEqual(style, LoroListStyle(kind: "bullet", depth: 1))
    }

    func testListStyleValueJsonRoundTripsDepth() throws {
        let style = LoroListStyle(kind: "ordered", depth: 3)
        let raw = try JSONSerialization.jsonObject(with: Data(style.valueJson.utf8))
        let decoded = LoroListStyle.decode(from: raw)

        XCTAssertEqual(decoded, style)
    }

    func testRenderAttributesExposeListDepthAndIndent() {
        let attrs = LoroAttributedStringBuilder.renderAttributes(
            for: [
                LoroMarkKey.list: [
                    "kind": "ordered",
                    "depth": 3,
                ]
            ],
            style: .default
        )

        XCTAssertEqual(attrs[.zulangueListKind] as? String, "ordered")
        XCTAssertEqual((attrs[.zulangueListDepth] as? NSNumber)?.intValue, 3)

        let paragraphStyle = attrs[.paragraphStyle] as? NSParagraphStyle
        let expectedIndent = LoroRenderStyle.listBaseIndent + (2 * LoroRenderStyle.listIndentStep)
        XCTAssertEqual(paragraphStyle?.headIndent ?? 0, expectedIndent, accuracy: 0.001)
        XCTAssertEqual(paragraphStyle?.firstLineHeadIndent ?? 0, expectedIndent, accuracy: 0.001)
    }

    func testReadableInsetCentersOnWideWindowsAndClampsOnNarrowWindows() {
        let style = LoroRenderStyle.default

        XCTAssertEqual(
            style.readableHorizontalInset(for: 640),
            LoroRenderStyle.minimumHorizontalInset,
            accuracy: 0.001
        )
        XCTAssertGreaterThan(
            style.readableHorizontalInset(for: 1400),
            LoroRenderStyle.minimumHorizontalInset
        )
    }

    func testHeadingParagraphStyleAddsMoreVerticalRhythmThanBody() {
        let style = LoroRenderStyle.default
        let body = style.paragraphStyle()
        let heading = style.paragraphStyle(headingLevel: 1)

        XCTAssertGreaterThan(heading.paragraphSpacingBefore, body.paragraphSpacingBefore)
        XCTAssertGreaterThan(heading.paragraphSpacing, body.paragraphSpacing)
        XCTAssertGreaterThan(heading.lineSpacing, body.lineSpacing)
    }
}
