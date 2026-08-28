import AppKit
import XCTest
@testable import ZuTalk

final class DocumentEditorExportEntryTests: XCTestCase {
    func testDocumentEditorMountsExportSheetFromSessionTabAction() throws {
        let source = try Self.loadDocumentEditorPage()

        XCTAssertTrue(source.contains("@State private var isShowingExportSheet = false"))
        XCTAssertTrue(source.contains(".sheet(isPresented: $isShowingExportSheet, onDismiss:"))
        XCTAssertTrue(source.contains("exportingSessionId ?? effectiveSessionId"))
        XCTAssertTrue(source.contains("ExportSheet(sessionId: sessionId)"))
        XCTAssertTrue(source.contains("tray.and.arrow.up"))
        XCTAssertTrue(source.contains(".disabled(sessionId == nil)"))
    }

    private static func loadDocumentEditorPage() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ZuTalk", isDirectory: true)
        return try String(
            contentsOf: root.appendingPathComponent("Pages/DocumentEditorPage.swift"),
            encoding: .utf8
        )
    }
}

final class DocumentEditorTabLayoutTests: XCTestCase {
    func testMissingSessionProjectionDoesNotBorrowSiblingTranscript() {
        let tab = FfiNotebookTab(
            id: "tab-realtime",
            notebookId: "topic-a",
            builtinKind: "realtime_transcript",
            title: "Realtime",
            docId: "doc-realtime",
            position: 0,
            createdAt: "2000-01-01T00:00:00Z",
            updatedAt: "2000-01-01T00:00:00Z",
            deletedAt: nil
        )
        let sibling = FfiNotebookSessionProjection(
            id: "projection-b",
            notebookId: "topic-a",
            tabId: tab.id,
            sessionId: "session-b",
            sectionTitle: "Sibling",
            createdAt: "2000-01-01T00:00:00Z",
            updatedAt: "2000-01-01T00:00:00Z",
            deletedAt: nil
        )

        let tabs = NotebookTabViewModel.makeTabs(
            notebookId: "topic-a",
            backendTabs: [tab],
            projectionsByTabId: [tab.id: [sibling]],
            realtimeSessionId: "session-a",
            selectedSessionId: "session-a"
        )

        XCTAssertEqual(tabs.count, 1)
        XCTAssertNil(tabs.first?.sessionLink)
    }

    func testNotebookTabBarStaysAboveVariableTabContent() throws {
        let source = try Self.loadDocumentEditorPage()
        let topChrome = try XCTUnwrap(source.range(of: "NoteTopChrome("))
        let tabBar = try XCTUnwrap(source.range(of: "DocumentTabBar("))
        let settingsHeader = try XCTUnwrap(
            source.range(of: "NotebookSettingsNotebookHeader(title: editorNotebook?.title)")
        )
        let builtinTitle = try XCTUnwrap(
            source.range(of: "NotebookBuiltinTabTitle(title: visibleSurfaceTitle)")
        )
        let topicNotesHeader = try XCTUnwrap(source.range(of: "TopicNotesContextHeader()"))
        let metadataBar = try XCTUnwrap(
            source.range(of: "NoteMetadataBar(sessionId: effectiveSessionId)")
        )

        XCTAssertLessThan(topChrome.lowerBound, tabBar.lowerBound)
        XCTAssertLessThan(tabBar.lowerBound, settingsHeader.lowerBound)
        XCTAssertLessThan(tabBar.lowerBound, builtinTitle.lowerBound)
        XCTAssertLessThan(tabBar.lowerBound, topicNotesHeader.lowerBound)
        XCTAssertLessThan(tabBar.lowerBound, metadataBar.lowerBound)
        XCTAssertTrue(source.contains("} else if isShowingResources == false {"))
    }

    func testTopicNotesClearsSessionContextAndUsesTopicChrome() throws {
        let source = try Self.loadDocumentEditorPage()

        XCTAssertTrue(source.contains("activeNotebookTab?.displayType == .manualNote"))
        XCTAssertTrue(source.contains("let targetSessionId = tab.displayType == .manualNote"))
        XCTAssertTrue(source.contains("selectedSessionID: targetSessionId"))
        XCTAssertTrue(source.contains("selectedSessionID: displayType == .manualNote ? nil : sessionId"))
        XCTAssertTrue(source.contains(
            "notebookTitle ?? String(localized: \"topic.workspace.breadcrumb\")"
        ))
    }

    func testTopicAndSessionTabsDoNotMixTheirResourceScopes() throws {
        let source = try Self.loadDocumentEditorPage()

        XCTAssertTrue(source.contains("let isTopicContext: Bool"))
        XCTAssertTrue(source.contains("if isTopicContext {\n                        ResourcesTabButton("))
        XCTAssertTrue(source.contains("if isTopicContext, captureSettingsNotebookId != nil"))
        XCTAssertTrue(source.contains("return tab.displayType != .asyncTranscript"))
        XCTAssertTrue(source.contains("return tab.displayType != .manualNote"))
        XCTAssertTrue(source.contains("if isTopicContext == false,"))
        XCTAssertTrue(source.contains("navigation.openTopicWorkspace(notebookID: notebookId)"))
    }

    func testEverySessionExposesFourPurposeBuiltTabs() throws {
        let source = try Self.loadDocumentEditorPage()

        let transcriptTabs = try XCTUnwrap(source.range(of: "ForEach(visibleTabs)"))
        let notesTab = try XCTUnwrap(source.range(of: "title: String(localized: \"session.tab.notes\")"))
        let settingsTab = try XCTUnwrap(source.range(of: "title: String(localized: \"session.tab.settings\")"))

        XCTAssertTrue(source.contains("session.tab.notes"))
        XCTAssertTrue(source.contains("session.tab.settings"))
        XCTAssertTrue(source.contains("accessibilityIdentifier: \"session.tab.notes\""))
        XCTAssertTrue(source.contains("accessibilityIdentifier: \"session.tab.settings\""))
        XCTAssertTrue(source.contains("BlockNoteEditorView(sessionId: sessionId)"))
        XCTAssertTrue(source.contains("SessionSettingsView("))
        XCTAssertTrue(source.contains("sessionSupplementarySurface == nil"))
        XCTAssertLessThan(transcriptTabs.lowerBound, notesTab.lowerBound)
        XCTAssertLessThan(notesTab.lowerBound, settingsTab.lowerBound)
    }

    func testSessionSettingsIsOnePageWithResourcesFirstAndSnapshotAtBottom() throws {
        let source = try Self.loadDocumentEditorPage()
        let captureViews = try Self.loadNotebookCaptureViews()
        let settingsStart = try XCTUnwrap(
            source.range(of: "private struct SessionSettingsView: View")
        )
        let snapshotStart = try XCTUnwrap(
            source.range(
                of: "private struct SessionSettingsSnapshotView: View",
                range: settingsStart.upperBound..<source.endIndex
            )
        )
        let settings = String(source[settingsStart.lowerBound..<snapshotStart.lowerBound])
        let resources = try XCTUnwrap(settings.range(of: "sessionResourceSection"))
        let setup = try XCTUnwrap(settings.range(of: "NotebookCaptureSettingsView("))
        let snapshot = try XCTUnwrap(settings.range(of: "SessionSettingsSnapshotView("))

        XCTAssertFalse(source.contains("private enum SessionSettingsPane"))
        XCTAssertFalse(settings.contains(".pickerStyle(.segmented)"))
        XCTAssertLessThan(resources.lowerBound, setup.lowerBound)
        XCTAssertLessThan(setup.lowerBound, snapshot.lowerBound)
        XCTAssertEqual(settings.components(separatedBy: "SessionSettingsSnapshotView(").count, 2)
        XCTAssertTrue(settings.contains("embeddedInParentScrollView: true"))
        XCTAssertTrue(settings.contains("isEmbedded: true"))
        XCTAssertTrue(settings.contains("SessionResourceSettingsView("))
        XCTAssertTrue(settings.contains("onOpen: onOpenResource"))
        XCTAssertTrue(source.contains("session.settings.workspace.snapshot"))
        XCTAssertTrue(captureViews.contains("enum NotebookCaptureSettingsScope"))
        XCTAssertTrue(captureViews.contains("capture.settings.subtitle.topic"))
        XCTAssertTrue(captureViews.contains("capture.settings.subtitle.quick_capture"))
        XCTAssertTrue(captureViews.contains("session.settings.workspace.scope.topic"))
        XCTAssertTrue(captureViews.contains("session.settings.workspace.scope.quick_capture"))
        XCTAssertTrue(source.contains(
            "SessionSettingsView(\n                    notebookId: notebookId,\n                    session: editorSession,\n                    editor: captureProfileEditor"
        ))
        XCTAssertTrue(source.contains("private struct SessionSettingsSnapshotView: View"))
        XCTAssertTrue(source.contains("listNotebookCaptureHistorySummaries"))
        XCTAssertTrue(source.contains("session.settings.subtitle"))
        XCTAssertTrue(source.contains("session.settings.snapshot.missing"))
        XCTAssertTrue(source.contains("session.settings.snapshot.imported_missing"))
        XCTAssertTrue(source.contains("session.settings.snapshot.corrupt"))
        XCTAssertTrue(source.contains("captureRun.remoteRealtimeEnabled"))
        XCTAssertTrue(source.contains("captureRun.sendContextToSoniox"))
        XCTAssertTrue(source.contains("session.settings.field.audio_input"))
        XCTAssertTrue(source.contains("session.settings.field.context_source"))
        XCTAssertTrue(source.contains("session.settings.value.not_recorded"))
        XCTAssertTrue(source.contains(
            "captureRun?.providerErrorType == \"profile_snapshot_corrupt\""
        ))
        XCTAssertTrue(source.contains("} else if routeLoadError != nil {"))
    }

    func testRouteSnapshotLoadsOffMainActorAndRejectsStaleOrMissingSessionResults() throws {
        let source = try Self.loadDocumentEditorPage()

        XCTAssertTrue(source.contains("@State private var routeLoadGeneration: UInt = 0"))
        XCTAssertTrue(source.contains("await Task.detached(priority: .userInitiated)"))
        XCTAssertTrue(source.contains("loadedSession = try core.getSession(id: sessionId)"))
        XCTAssertTrue(source.contains(
            "guard routeLoadGeneration == generation, route == requestedRoute else { return }"
        ))
        XCTAssertTrue(source.contains(
            "routeLoadError = String(localized: \"editor.route.load_failed\")"
        ))
        XCTAssertTrue(source.contains("quickCaptureNotebook?.id == requestedRoute.notebookID"))
        XCTAssertTrue(source.contains("case .manualNote: false"))
    }

    private static func loadDocumentEditorPage() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ZuTalk", isDirectory: true)
        return try String(
            contentsOf: root.appendingPathComponent("Pages/DocumentEditorPage.swift"),
            encoding: .utf8
        )
    }

    private static func loadNotebookCaptureViews() throws -> String {
        try CaptureSourceCorpus.captureViews()
    }
}

final class DocumentEditorTaskQueuePanelTests: XCTestCase {
    func testDocumentEditorMountsTaskQueuePanel() throws {
        let source = try Self.loadDocumentEditorPage()

        XCTAssertTrue(source.contains("case tasks"))
        XCTAssertTrue(source.contains("@StateObject private var notebookTasks = NotebookTasksViewModel()"))
        XCTAssertTrue(source.contains("NotebookTasksPanel(viewModel: notebookTasks)"))
        XCTAssertTrue(source.contains("BlockNoteUtilityBar("))
        XCTAssertTrue(source.contains("Image(systemName: \"checklist\")"))
        XCTAssertTrue(source.contains("client.listTasks(statusFilter: nil)"))
    }

    private static func loadDocumentEditorPage() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ZuTalk", isDirectory: true)
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
            .appendingPathComponent("ZuTalk", isDirectory: true)
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

        // 本地编辑面从平文本编辑器换成了大纲编辑器(块文档 FFI),编辑面
        // 本身是一整个 NSTextView —— 手势与落库分居两个文件,所以这里
        // 一起读。
        let outlineEditor = try String(
            contentsOf: root.appendingPathComponent("Pages/BlockNoteEditorView.swift"),
            encoding: .utf8
        )
        let outlineCanvas = try String(
            contentsOf: root.appendingPathComponent("Pages/BlockNoteTextCanvas.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(page.contains("BlockNoteEditorView(notebookId: notebookId, tabId: tabId)"))
        XCTAssertFalse(page.contains("DocumentTextView("))
        XCTAssertFalse(page.contains("LoroBackedTextView"))
        XCTAssertTrue(outlineEditor.contains("BlockNoteTextCanvas("))
        // 本地编辑仍然真的落库:拆分与整份派生都写回块文档 FFI。
        XCTAssertTrue(outlineCanvas.contains("store.splitRow(rowId:"))
        XCTAssertTrue(outlineCanvas.contains("store.applyDerivedRows("))
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
            .appendingPathComponent("ZuTalk", isDirectory: true)
        let page = try String(
            contentsOf: root.appendingPathComponent("Pages/DocumentEditorPage.swift"),
            encoding: .utf8
        )
        let captureViews = try CaptureSourceCorpus.captureViews()

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
            .appendingPathComponent("ZuTalk", isDirectory: true)
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
                source.contains(".help(String(localized: \"\(key)\"))"),
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
            .appendingPathComponent("ZuTalk", isDirectory: true)
        return try String(
            contentsOf: root.appendingPathComponent("Pages/DocumentEditorPage.swift"),
            encoding: .utf8
        )
    }

    private static func loadLocalization(_ locale: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ZuTalk", isDirectory: true)
        return try String(
            contentsOf: root.appendingPathComponent("Resources/\(locale)/Localizable.strings"),
            encoding: .utf8
        )
    }
}
