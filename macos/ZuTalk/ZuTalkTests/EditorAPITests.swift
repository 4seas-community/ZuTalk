import XCTest
@testable import ZuTalk

final class EditorAPITests: XCTestCase {

    private var core: ZuTalkCore!
    private var tempDir: String!

    override func setUp() {
        tempDir = NSTemporaryDirectory()
            .appending("zutalk-editor-\(UUID().uuidString)")
        core = try! ZuTalkCore.newDeferred(dataDir: tempDir)
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

// MARK: - 0.8.3 · topic options, terms and background, trash, collaboration

/// The topics area after the 0.8.3 interface pass: rows of a name and a
/// control, no sentences on the surface — and none of the sentences that
/// were disclosures lost on the way.
@MainActor
final class TopicsInterfaceTests: XCTestCase {
    private static let languages = ["en", "th", "ja", "ko", "fr", "es", "de", "zh-Hans"]

    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ZuTalk", isDirectory: true)
    }

    private func source(_ file: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
    }

    /// One language's strings, straight from its file.
    private func strings(_ language: String) throws -> [String: String] {
        let text = try source("Resources/\(language).lproj/Localizable.strings")
        var table: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            guard line.hasPrefix("\""), line.hasSuffix("\";"),
                  let separator = line.range(of: "\" = \"")
            else { continue }
            let key = String(line[line.index(after: line.startIndex)..<separator.lowerBound])
            table[key] = String(line[separator.upperBound..<line.index(line.endIndex, offsetBy: -2)])
        }
        return table
    }

    /// A topic's options are rows: the languages are the same pills as
    /// Home's card, sound and audio are menu pills, and what the page is —
    /// defaults — is its one-word header, with the sentence as its tooltip.
    func testTopicOptionsAreRowsOfANameAndAControl() throws {
        let options = try source("Pages/NotebookCaptureSettingsView.swift")
        for used in [
            "PlainRowGroup {",
            "PlainRow(",
            "CaptureLanguageEditor(editor: editor)",
            "AudioInputPicker(notebookId: notebookId)",
            "MenuPill(",
            "KnowledgeLibrarySheet()",
            "CityTopicChannelCard(notebookId: notebookId)",
            "String(localized: \"topics.options.header\")",
            "help: scope.settingsDescription",
        ] {
            XCTAssertTrue(options.contains(used), "topic options should use \(used)")
        }
        // No cards with a paragraph under their title, no text links, no
        // radio list of sentences.
        for retired in ["settingsCard(", ".buttonStyle(.link)", ".pickerStyle(", "largecircle.fill.circle"] {
            XCTAssertFalse(options.contains(retired), "topic options still has \(retired)")
        }

        // One way of choosing languages in the whole app: the full editor is
        // the pill strip, not a second set of chips.
        let languages = try source("Pages/CaptureLanguageEditor.swift")
        XCTAssertTrue(languages.contains("PillStrip {\n            CaptureLanguagePills(editor: editor)"))
        for retired in ["selectedLanguageChip", "languageChipButton", "chevron.left"] {
            XCTAssertFalse(languages.contains(retired), "the language editor still has \(retired)")
        }
        // The sound source is the same pill and the same choices as Home's.
        let sound = try source("Pages/AudioInputPicker.swift")
        XCTAssertFalse(sound.contains(".pickerStyle(.menu)"))
        XCTAssertEqual(sound.components(separatedBy: "MenuPill(").count - 1, 2)
    }

    /// With three languages the sentence about who speaks what is said to
    /// whoever asks; with fewer there is nothing to tell apart.
    func testLanguageRolesAreSaidOnlyOnceThereAreThree() {
        XCTAssertNil(CaptureLanguageEditor.rolesSummary(selected: ["en"], translatedOnly: []))
        XCTAssertNil(CaptureLanguageEditor.rolesSummary(selected: ["en", "zh"], translatedOnly: ["zh"]))
        XCTAssertEqual(
            CaptureLanguageEditor.rolesSummary(selected: ["en", "zh", "th"], translatedOnly: []),
            String(localized: "capture.languages.roles.all_spoken")
        )
        let mixed = CaptureLanguageEditor.rolesSummary(
            selected: ["en", "zh", "th"],
            translatedOnly: ["th", "ja"]
        )
        XCTAssertNotNil(mixed)
        XCTAssertNotEqual(mixed, String(localized: "capture.languages.roles.all_spoken"))
        XCTAssertTrue(mixed?.contains(RecordingPresentation.languageName("th")) == true)
        // A language that is not chosen plays no part, whatever was asked.
        XCTAssertFalse(mixed?.contains(RecordingPresentation.languageName("ja")) == true)
    }

    /// Two of the three audio choices delete audio for good. What each one
    /// does left the page, so the ⓘ beside the pill has to say all of it.
    func testAudioChoiceDisclosureSaysWhatEveryChoiceDoes() throws {
        let disclosure = AudioPrivacyOptionSummary.disclosure
        for level in NotebookAudioRetentionLevel.allCases {
            let option = AudioPrivacyOptionSummary(level: level)
            XCTAssertTrue(disclosure.contains(option.title))
            XCTAssertTrue(disclosure.contains(option.storageText))
        }
        XCTAssertTrue(disclosure.contains(String(localized: "capture.settings.retention.subtitle")))
        XCTAssertTrue(
            try source("Pages/NotebookCaptureSettingsView.swift")
                .contains("InfoButton(AudioPrivacyOptionSummary.disclosure")
        )
    }

    /// The sentences that were disclosures moved; none was deleted. Each
    /// lives in an ⓘ beside its control or in the confirmation at the moment
    /// of the action.
    func testDisclosuresMovedAndWereNotDeleted() throws {
        let options = try source("Pages/NotebookCaptureSettingsView.swift")
        XCTAssertTrue(options.contains(
            "InfoButton(\n                                String(localized: \"settings.audio_input.system_audio_hint\")"
        ))

        let collaboration = try source("Library/TopicCollaborationSheet.swift")
        // What a collaborator sees, and that audio never leaves the Mac
        // that recorded it.
        XCTAssertTrue(collaboration.contains("InfoButton(String(localized: \"topic.collab.explain\")"))
        XCTAssertTrue(collaboration.contains(
            "InfoButton(\n                    String(localized: \"topic.collab.join_explain\")"
        ))
        XCTAssertTrue(collaboration.contains(
            "InfoButton(\n                        String(localized: \"topic.collab.code_hint\")"
        ))
        for confirmation in [
            "topic.collab.stop_confirm_message",
            "topic.collab.leave_confirm_message",
            "topic.collab.remove_confirm_message",
        ] {
            XCTAssertTrue(collaboration.contains(confirmation))
        }
        XCTAssertFalse(collaboration.contains("Text(String(localized: \"topic.collab.explain\"))"))

        let trash = try source("Pages/TrashPage.swift")
        // "Cannot be undone" is said where the deletion is confirmed: once
        // for one recording, once for all of them.
        XCTAssertEqual(
            trash.components(separatedBy: "Text(String(localized: \"trash.purge.confirm_desc\"))").count - 1,
            2
        )
        // The window's header names the page; what the page is for is the
        // list's tooltip, and the page prints no title of its own.
        XCTAssertTrue(trash.contains(".help(String(localized: \"trash.subtitle\"))"))
        XCTAssertFalse(trash.contains("PlainPageHeader("))
        XCTAssertTrue(trash.contains("PlainEmptyLine(String(localized: \"trash.empty.desc\"))"))

        let knowledge = try source("Pages/KnowledgeLibraryPage.swift")
        XCTAssertTrue(knowledge.contains("PlainEmptyLine(String(localized: \"knowledge.empty.description\"))"))
        for moved in [
            "knowledge.subtitle",
            "knowledge.general.subtitle",
            "knowledge.background.subtitle",
            "knowledge.terms.subtitle",
            "knowledge.translations.subtitle",
        ] {
            XCTAssertTrue(knowledge.contains("help: String(localized: \"\(moved)\")"), "\(moved) lost its tooltip")
        }
    }

    /// The words added for this pass are labels: one or two words, never a
    /// sentence, in every language.
    func testNewLabelsAreAWordOrTwoInEveryLanguage() throws {
        let keys = [
            "topics.options.header",
            "topics.options.languages",
            "topics.options.sound",
            "topics.options.audio",
            "topics.options.edit",
            "topics.options.preview",
            "knowledge.action.new",
            "knowledge.action.import",
            "knowledge.meter.title",
            "trash.action.empty",
            "topic.collab.action.copy",
            "topic.collab.action.invite",
            "topic.collab.action.stop",
            "topic.collab.action.leave",
        ]
        for language in Self.languages {
            let table = try strings(language)
            for key in keys {
                let value = try XCTUnwrap(table[key], "\(language) lacks \(key)")
                XCTAssertFalse(value.isEmpty, "\(language) \(key) is empty")
                XCTAssertLessThanOrEqual(
                    value.split(separator: " ").count, 2,
                    "\(language) \(key) is more than a label: \(value)"
                )
                XCTAssertNil(
                    value.rangeOfCharacter(from: CharacterSet(charactersIn: ".。!！?？…,，")),
                    "\(language) \(key) reads as a sentence: \(value)"
                )
            }
        }
    }
}
