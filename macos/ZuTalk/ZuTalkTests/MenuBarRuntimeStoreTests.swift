// MenuBarRuntimeStoreTests.swift
//
// State-machine coverage for MenuBarRuntimeStore — the store that drives the
// menu-bar status icon and popover content. Replaces the prior
// IslandRuntimeStoreV2Tests; hover / caption-cluster / suppression-reducer
// scenarios were dropped along with the island UI they coordinated.

import XCTest
import Combine
@testable import ZuTalk

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

    /// The two labels were hard-coded English ("Transcribing…", "Ready in
    /// Home") whatever the interface language.
    func testProcessingLabelsComeFromTheInterfaceLanguage() {
        let completed = ProcessingInfo(stage: .completed, progress: 1, sessionId: "sess-1")
        let running = ProcessingInfo(stage: .transcribing, progress: 0.3, sessionId: "sess-1")

        XCTAssertEqual(completed.label, String(localized: "menubar.processing.ready"))
        XCTAssertEqual(running.label, String(localized: "menubar.processing.refining"))
        XCTAssertNotEqual(completed.label, "menubar.processing.ready", "the key must resolve")
        XCTAssertNotEqual(running.label, "menubar.processing.refining", "the key must resolve")
    }

    func testZuTalkAppRoutesCaptureControlsBackToNotebook() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ZuTalk", isDirectory: true)
        let source = root.appendingPathComponent("ZuTalkApp.swift")
        let contents = try String(contentsOf: source, encoding: .utf8)
        let commands = try String(
            contentsOf: root.appendingPathComponent("Capture/CaptureCommandCenter.swift"),
            encoding: .utf8
        )

        // Shortcuts and menus go through the one command center, which sends
        // an already-running recording back to its topic instead of starting
        // a second one.
        XCTAssertTrue(contents.contains("CaptureCommandCenter.shared"))
        XCTAssertTrue(commands.contains("openActiveNotebookForCapture"))
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

// MARK: - 0.8.2: one status sentence, four controls, hosting tools a layer down
//
// Lives here because the test target lists its files by hand. The rules these
// pin are docs/product/interface-layers.md.

@MainActor
final class RecordingBarStatusLineTests: XCTestCase {
    private func model(
        phase: RecordingBarModel.Phase = .recording,
        stoppingSeconds: Int? = nil,
        captions: RecordingBarModel.Captions = .live,
        offline: Bool = false,
        lagNotice: String? = nil,
        problem: String? = nil,
        haltedNotice: String? = nil
    ) -> RecordingBarModel {
        RecordingBarModel(
            phase: phase,
            elapsed: 65,
            stoppingSeconds: stoppingSeconds,
            captions: captions,
            offline: offline,
            lagNotice: lagNotice,
            problem: problem,
            haltedNotice: haltedNotice,
            canPause: true,
            canStop: true,
            stopNeedsRetry: false,
            justMarked: false,
            pausedWhileBilling: false
        )
    }

    func testEveryRowOfTheStatusTable() {
        let rows: [(RecordingBarModel, RecordingBarModel.StatusLine, String.LocalizationValue)] = [
            (model(), .recording, "recording_bar.status.recording"),
            (model(captions: .off), .audioOnly, "recording_bar.status.audio_only"),
            (model(captions: .connecting), .connectingText, "recording_bar.status.connecting"),
            (model(lagNotice: "Chinese translation 12 s behind"), .textBehind, "recording_bar.status.text_behind"),
            (model(captions: .partial), .someTextStopped, "recording_bar.status.some_text_stopped"),
            (model(captions: .stopped), .textStopped, "recording_bar.status.text_stopped"),
            (model(offline: true), .offline, "recording_bar.status.offline"),
            (model(phase: .paused), .paused, "capture.state.paused"),
            (model(phase: .pausing), .pausing, "capture.state.pausing"),
            (model(phase: .resuming), .resuming, "capture.state.resuming"),
            (model(phase: .stopping), .stopping(seconds: nil), "capture.state.saving_recording"),
        ]
        for (model, expected, key) in rows {
            XCTAssertEqual(model.statusLine, expected)
            XCTAssertEqual(model.statusLine.text, String(localized: key))
        }
    }

    /// A translation that stopped leaves remote health "live"; it is still
    /// some of the text having stopped.
    func testAHaltedTranslationCountsAsSomeTextStopped() {
        XCTAssertEqual(
            model(captions: .live, haltedNotice: "Thai translation stopped").statusLine,
            .someTextStopped
        )
    }

    func testStoppingKeepsCountingSecondsAsBefore() {
        XCTAssertEqual(
            model(phase: .stopping, stoppingSeconds: 7).statusLine.text,
            String(format: String(localized: "capture.state.saving_recording_seconds"), Int64(7))
        )
        XCTAssertEqual(
            model(phase: .stopping, stoppingSeconds: 1).statusLine.text,
            String(localized: "capture.state.saving_recording"),
            "the first second is not worth counting"
        )
    }

    /// stopping > pausing / resuming / paused > offline > text stopped >
    /// some text stopped > behind > connecting > audio only > recording.
    /// Start with everything wrong at once and take the top one away.
    func testPriorityOrder() {
        var everything = model(
            phase: .stopping,
            stoppingSeconds: 5,
            captions: .stopped,
            offline: true,
            lagNotice: "Captions 9 s behind",
            problem: "The connection dropped.",
            haltedNotice: "Thai translation stopped"
        )
        XCTAssertEqual(everything.statusLine, .stopping(seconds: 5))

        for (phase, expected) in [
            (RecordingBarModel.Phase.pausing, RecordingBarModel.StatusLine.pausing),
            (.resuming, .resuming),
            (.paused, .paused),
        ] {
            everything.phase = phase
            XCTAssertEqual(everything.statusLine, expected, "pausing outranks every text problem")
        }

        everything.phase = .recording
        XCTAssertEqual(everything.statusLine, .offline)

        everything.offline = false
        XCTAssertEqual(everything.statusLine, .textStopped)

        everything.captions = .partial
        XCTAssertEqual(everything.statusLine, .someTextStopped)

        everything.captions = .connecting
        XCTAssertEqual(everything.statusLine, .someTextStopped, "a halted language outranks lag and connecting")

        everything.haltedNotice = nil
        XCTAssertEqual(everything.statusLine, .textBehind, "lag outranks connecting")

        everything.lagNotice = nil
        XCTAssertEqual(everything.statusLine, .connectingText)

        everything.captions = .off
        XCTAssertEqual(everything.statusLine, .audioOnly)

        everything.captions = .live
        XCTAssertEqual(everything.statusLine, .recording)
    }

    func testOnlyTextProblemsAreAmber() {
        let amber: [RecordingBarModel.StatusLine] = [.offline, .textStopped, .someTextStopped, .textBehind]
        let quiet: [RecordingBarModel.StatusLine] = [
            .stopping(seconds: 3), .pausing, .resuming, .paused,
            .connectingText, .audioOnly, .recording,
        ]
        XCTAssertTrue(amber.allSatisfy(\.reportsTextProblem))
        XCTAssertFalse(quiet.contains(where: \.reportsTextProblem))
    }

    /// The sentence rounds off; the tooltip keeps the exact words.
    func testSentenceNeverCountsLagAndTheTooltipDoes() throws {
        let lagging = model(lagNotice: "Chinese translation 12 s behind")
        XCTAssertNil(
            lagging.statusLine.text.rangeOfCharacter(from: .decimalDigits),
            "seconds of lag belong in the tooltip"
        )
        XCTAssertTrue(try XCTUnwrap(lagging.statusDetail).contains("Chinese translation 12 s behind"))

        XCTAssertEqual(
            model(captions: .stopped, problem: "The connection dropped.").statusDetail,
            "The connection dropped."
        )
        XCTAssertEqual(
            model(captions: .partial, haltedNotice: "Thai translation stopped").statusDetail,
            "Thai translation stopped"
        )
        XCTAssertEqual(
            model(offline: true, problem: "The connection dropped.").statusDetail,
            String(localized: "network.offline.recording_banner"),
            "no network explains every problem under it"
        )
        XCTAssertNil(model().statusDetail)
        XCTAssertNil(model(phase: .stopping, captions: .stopped, problem: "x").statusDetail)
    }

    func testHaltedNoticeNamesTheLanguages() throws {
        XCTAssertNil(RecordingAttention.haltedNotice([]))
        let notice = try XCTUnwrap(RecordingAttention.haltedNotice(["th"]))
        let thai = Locale.current.localizedString(forLanguageCode: "th") ?? "TH"
        XCTAssertTrue(notice.contains(thai))
    }

    // MARK: Hosting tools

    func testAudienceButtonIsAHostingTool() {
        let suite = "RecordingBarStatusLineTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let mode = HostMode(
            defaults: defaults,
            initiallySignedIn: false,
            signedIn: Just(false).eraseToAnyPublisher()
        )

        XCTAssertFalse(
            LiveShareButton.showsInBar(hostMode: mode, live: false),
            "someone who only records has no audience button"
        )
        XCTAssertTrue(
            LiveShareButton.showsInBar(hostMode: mode, live: true),
            "a share that is running keeps the button that stops it"
        )

        mode.set(true)
        XCTAssertTrue(LiveShareButton.showsInBar(hostMode: mode, live: false))
    }

    /// One entry to the audience panel is on screen at a time: the button,
    /// or the item under ⋯.
    func testMoreMenuOffersAudienceCaptionsWhenTheButtonIsNotShowing() {
        XCTAssertTrue(RecordingBarMenu.offersAudienceCaptions(sessionId: "s", showsShareButton: false))
        XCTAssertFalse(RecordingBarMenu.offersAudienceCaptions(sessionId: "s", showsShareButton: true))
        XCTAssertFalse(RecordingBarMenu.offersAudienceCaptions(sessionId: nil, showsShareButton: false))
    }

    // MARK: The live page

    func testNothingSitsAboveTheTranscriptWhileItsRecordingRuns() {
        let recording = NotebookRealtimeConsolePresentation.activeRunSummary
        XCTAssertFalse(recording.showsConsole(stopNeedsAttention: false))
        XCTAssertFalse(recording.showsConsole(stopNeedsAttention: true))

        let stopping = NotebookRealtimeConsolePresentation.drainingSummary
        XCTAssertFalse(stopping.showsConsole(stopNeedsAttention: false), "the bar counts an ordinary stop out")
        XCTAssertTrue(stopping.showsConsole(stopNeedsAttention: true))

        XCTAssertTrue(NotebookRealtimeConsolePresentation.inactiveEditor.showsConsole(stopNeedsAttention: false))
        XCTAssertTrue(
            NotebookRealtimeConsolePresentation.activeElsewhereSummary.showsConsole(stopNeedsAttention: false)
        )
    }

    func testReadingLayoutIsOneChoiceForTheBarAndThePage() {
        let layout = TranscriptReadingLayout()
        XCTAssertEqual(layout.mode(for: nil), .bilingualColumns)
        XCTAssertEqual(layout.mode(for: "topic-a"), .bilingualColumns)

        layout.noteDefault(.sourceTimeline, for: "topic-a")
        XCTAssertEqual(layout.mode(for: "topic-a"), .sourceTimeline, "until someone chooses, the page's own default")
        XCTAssertNil(layout.chosen["topic-a"])

        layout.choose(.bilingualColumns, for: "topic-a")
        XCTAssertEqual(layout.mode(for: "topic-a"), .bilingualColumns)

        layout.noteDefault(.sourceTimeline, for: "topic-a")
        XCTAssertEqual(layout.mode(for: "topic-a"), .bilingualColumns, "a default never overrides a choice")
        XCTAssertEqual(layout.mode(for: "topic-b"), .bilingualColumns, "per topic")

        var publishes = 0
        let observer = layout.objectWillChange.sink { publishes += 1 }
        defer { observer.cancel() }
        layout.choose(.bilingualColumns, for: "topic-a")
        layout.noteDefault(.sourceTimeline, for: "topic-a")
        XCTAssertEqual(publishes, 0, "saying the same thing again must not redraw the bar")
    }

    // MARK: Wording and what left the screen

    private static let sourceRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("ZuTalk", isDirectory: true)

    private func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: Self.sourceRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func strings(_ language: String) throws -> [String: String] {
        let text = try source("Resources/\(language).lproj/Localizable.strings")
        var table: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard line.hasPrefix("\""), line.hasSuffix("\";"),
                  let separator = line.range(of: "\" = \"") else { continue }
            let key = String(line[line.index(after: line.startIndex)..<separator.lowerBound])
            table[key] = String(line[separator.upperBound..<line.index(line.endIndex, offsetBy: -2)])
        }
        return table
    }

    private static let liveKeys = [
        "recording_bar.status.recording",
        "recording_bar.status.audio_only",
        "recording_bar.status.connecting",
        "recording_bar.status.text_behind",
        "recording_bar.status.some_text_stopped",
        "recording_bar.status.text_stopped",
        "recording_bar.status.offline",
        "recording_bar.status.open_hint",
        "recording_bar.more",
        "recording_bar.more.caption_window.open",
        "recording_bar.more.caption_window.close",
        "recording_bar.more.copy_text",
        "recording_bar.more.audience",
        "menubar.recording.open_recording",
        "menubar.processing.refining",
        "menubar.processing.ready",
    ]

    /// The table in docs/product/interface-layers.md, word for word.
    func testStatusWordingIsTheLayersDocuments() throws {
        let expected: [(key: String, zh: String, en: String)] = [
            ("recording_bar.status.recording", "正在录音", "Recording"),
            ("recording_bar.status.audio_only", "正在录音 · 只录音", "Recording · audio only"),
            ("recording_bar.status.connecting", "正在录音 · 正在接通文字", "Recording · connecting text"),
            ("recording_bar.status.text_behind", "正在录音 · 文字慢了一点", "Recording · text is a little behind"),
            ("recording_bar.status.some_text_stopped", "正在录音 · 部分文字停了", "Recording · some text stopped"),
            ("recording_bar.status.text_stopped", "正在录音 · 文字停了", "Recording · text stopped"),
            ("recording_bar.status.offline", "正在录音 · 没联网，暂时出不了字", "Recording · offline, no text for now"),
        ]
        let zh = try strings("zh-Hans")
        let en = try strings("en")
        for row in expected {
            XCTAssertEqual(zh[row.key], row.zh)
            XCTAssertEqual(en[row.key], row.en)
        }
        XCTAssertEqual(zh["menubar.recording.open_recording"], "打开这场录音")
    }

    func testNewCopyIsInEveryLanguagesOwnWords() throws {
        let english = try strings("en")
        for language in ["th", "ja", "ko", "fr", "es", "de", "zh-Hans"] {
            let table = try strings(language)
            for key in Self.liveKeys {
                let value = try XCTUnwrap(table[key], "\(language) must define \(key)")
                XCTAssertNotEqual(value, english[key], "\(language) \(key) is still English")
                if ["th", "ja", "ko", "zh-Hans"].contains(language) {
                    XCTAssertNil(
                        value.range(of: "[A-Za-z]", options: .regularExpression),
                        "\(language) \(key) mixes in Latin text: \(value)"
                    )
                }
            }
        }
    }

    func testBarKeepsFourControlsAndReconnectStaysInTheBanner() throws {
        let bar = try source("UIScenes/Main/RecordingBar.swift")
        let start = try XCTUnwrap(bar.range(of: "struct RecordingBarContent: View"))
        let end = try XCTUnwrap(bar.range(of: "struct RecordingAttention: Equatable"))
        let content = String(bar[start.lowerBound..<end.lowerBound])

        for identifier in ["recording-bar.open", "recording-bar.mark", "recording-bar.pause",
                           "recording-bar.stop", "recording-bar.more"] {
            XCTAssertTrue(content.contains("\"\(identifier)\""), "\(identifier) must survive")
        }
        XCTAssertEqual(
            content.components(separatedBy: "barButton(").count - 1,
            4,
            "Mark, Pause and Stop, plus the helper itself; ⋯ is a Menu"
        )
        for retired in ["restart_transcription", "captionsChip", "recording_bar.unfiled",
                        "capture.remote.", "tortoise"] {
            XCTAssertFalse(content.contains(retired), "\(retired) left the bar")
        }

        let bannerStart = try XCTUnwrap(bar.range(of: "struct RecordingProblemBanner: View"))
        // The banner is the last thing in the file: the live-text choice
        // that used to follow it is gone.
        let banner = String(bar[bannerStart.lowerBound...])
        XCTAssertFalse(banner.contains("struct CaptionsChoiceChip"))
        XCTAssertTrue(banner.contains("commands.restartTranscription()"))
        XCTAssertTrue(banner.contains("capture.toolbar.restart_transcription"))
    }

    func testLivePageAndMenuBarDroppedWhatTheBarNowSays() throws {
        let page = try source("Pages/NotebookRealtimeTranscriptPage.swift")
        for retired in [
            "floatingSubtitleButton",
            "capture.realtime.controls.current_title",
            "capture.settings.active_locked",
            "capture.remote.catching_up",
            "realtimeModelId",
        ] {
            XCTAssertFalse(page.contains(retired), "the live page must not carry \(retired)")
        }
        XCTAssertTrue(page.contains("run.sessionId != activeSessionID"))

        let menuBar = try source("MenuBar/MenuBarRecordingView.swift")
        XCTAssertFalse(menuBar.contains("CaptureStateLabel("), "the popover says the bar's sentence")
        XCTAssertFalse(menuBar.contains("info.languagePair"), "which could be the engine's code name")
        XCTAssertFalse(menuBar.contains("\"menubar.recording.open_notebook\""))
        XCTAssertTrue(menuBar.contains("\"menubar.recording.open_recording\""))
        XCTAssertTrue(menuBar.contains("RecordingBarModel.current("))

        let models = try source("Capture/RecordingDomainModels.swift")
        for english in ["SONIOX", "Transcribing", "Ready in Home", "AES-256"] {
            XCTAssertFalse(models.contains(english))
        }
        let indicator = try source("DesignSystem/Primitives/LiveIndicator.swift")
        for code in ["\"REC\"", "\"POLISHING\"", "\"COMPLETED\"", "\"ERROR\""] {
            XCTAssertFalse(indicator.contains(code))
        }
        let hud = try source("MenuBar/RecordingHudView.swift")
        XCTAssertFalse(hud.contains("hud.recording.active"), "that key reads REC in every language")
        XCTAssertFalse(hud.contains("hud.recording.paused"))
    }
}

// MARK: - 0.8.3: share panels, the caption window's bar, the menu bar
//
// docs/product/interface-layers.md 「界面怎么写」: no sentences on the surface,
// and a disclosure moves — into a tooltip, an ⓘ, a confirmation — but is never
// deleted. These pin both halves for the windows area.

@MainActor
final class WindowsAreaInterfaceTests: XCTestCase {
    private static let sourceRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("ZuTalk", isDirectory: true)

    private static let languages = ["en", "th", "ja", "ko", "fr", "es", "de", "zh-Hans"]

    private func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: Self.sourceRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func keys(_ language: String) throws -> Set<String> {
        let text = try source("Resources/\(language).lproj/Localizable.strings")
        var keys: Set<String> = []
        for line in text.split(separator: "\n") {
            guard line.hasPrefix("\""), let end = line.range(of: "\" = \"") else { continue }
            keys.insert(String(line[line.index(after: line.startIndex)..<end.lowerBound]))
        }
        return keys
    }

    // MARK: Disclosures

    func testThePanelShowsAtMostThreeFactsAndEachCarriesItsSentence() throws {
        for keeps in [false, true] {
            let facts = LiveSharePanelState(phase: .idle, keepsAfterEnd: keeps).facts
            XCTAssertEqual(facts.count, 3)
            XCTAssertEqual(facts[0], .noAudio)
            XCTAssertEqual(facts[1], .encrypted)
            XCTAssertEqual(
                facts[2].detailKey,
                keeps ? "share.live.stop_note_kept" : "share.live.stop_note",
                "what happens on stop follows the keep choice"
            )
        }
        XCTAssertEqual(ShareFact.noAudio.detailKey, "share.audio_never")
        XCTAssertEqual(ShareFact.encrypted.detailKey, "share.encrypted")
        XCTAssertEqual(ShareFact.linkExpires.detailKey, "share.recording.link_detail")

        let all: [ShareFact] = [
            .noAudio, .encrypted, .linkEncrypted, .linkExpires,
            .afterStop(keeps: false), .afterStop(keeps: true),
        ]
        for language in Self.languages {
            let defined = try keys(language)
            for fact in all {
                XCTAssertTrue(defined.contains(fact.labelKey), "\(language) lacks \(fact.labelKey)")
                XCTAssertTrue(defined.contains(fact.detailKey), "\(language) lacks \(fact.detailKey)")
            }
        }
    }

    func testTheInfoTextSaysEachSentenceOnce() {
        let text = ShareFact.fullText([.linkEncrypted, .linkExpires])
        XCTAssertEqual(text, ShareFact.linkExpires.detail, "both facts come from one sentence")
        XCTAssertEqual(
            ShareFact.fullText([.noAudio, .encrypted]).components(separatedBy: "\n").count,
            2
        )
    }

    /// Every sentence that used to be printed on the two panels is still
    /// referenced by them — as a tooltip, an ⓘ or a confirmation.
    func testNoDisclosureLeftTheSharePanels() throws {
        let panel = try source("Pages/ShareHostPanel.swift")
        for key in [
            "share.audio_never", "share.encrypted", "share.live.intro",
            "share.live.stop_note", "share.live.stop_note_kept",
            "share.live.keep_on_detail", "share.live.keep_off_detail",
            "share.live.lock_on_detail", "share.live.lock_off_detail",
            "share.live.replace_detail", "share.live.other_body",
            "share.copy.detail", "share.recording.link_detail",
            "share.recording.revoke_confirm_body",
            "nearby.live.choice_off_detail", "nearby.live.choice_on_detail",
            "nearby.send.detail", "nearby.send.none",
        ] {
            XCTAssertTrue(panel.contains("\"\(key)\""), "\(key) must stay reachable")
        }
        XCTAssertFalse(panel.contains("struct ShareChoice"), "a switch with a sentence under it")
        XCTAssertFalse(panel.contains("struct ShareAssurances"), "two sentences in a row")
        XCTAssertTrue(panel.contains("CityShareSection(request: request)"), "the city block stays mounted")

        let store = try source("App/ShareActivityStore.swift")
        XCTAssertTrue(store.contains("\"share.live.ended_with_recording\""))
        XCTAssertTrue(store.contains("\"share.live.ended_with_recording_kept\""))
    }

    func testBarButtonSaysOnlyTheCountWhileItIsLive() {
        XCTAssertEqual(
            LiveShareText.barLabel(live: false, viewers: 0),
            String(localized: "share.live.bar")
        )
        XCTAssertEqual(
            LiveShareText.barLabel(live: true, viewers: 3),
            String(format: String(localized: "share.live.viewers_format"), Int64(3))
        )
        XCTAssertEqual(
            LiveShareText.displayed("https://host.example/l/abc#secret"),
            "host.example/l/abc#…",
            "the key is never printed"
        )
    }

    // MARK: The caption window's bar

    func testMoreMenuHoldsWhatLeftTheBarAndShowsTheShortcuts() {
        let state = SubtitleOverlayMenu.State(
            theme: .dark,
            placement: .restored,
            fontIsAutomatic: true,
            backdropOpacity: 0.6,
            backdropAdjustable: true
        )
        var picked: [String] = []
        let items = SubtitleOverlayMenu.items(
            state: state,
            actions: SubtitleOverlayMenu.Actions(
                toggleFontAutomatic: { picked.append("auto") },
                setTheme: { picked.append("theme:\($0.rawValue)") },
                setBackdropOpacity: { picked.append("backdrop:\($0)") },
                toggleFilled: { picked.append("fill") },
                toggleBanner: { picked.append("banner") }
            )
        )
        let actions = items.filter { $0.role == .action }
        XCTAssertEqual(actions.count, 5, "automatic size, dark, light, fill, banner")
        XCTAssertEqual(actions.map(\.isOn), [true, true, false, false, false])
        XCTAssertEqual(actions.map(\.shortcut), [nil, nil, nil, .fill, .banner])
        XCTAssertEqual(
            actions.compactMap(\.identifier),
            [
                AccessibilityID.floatingSubtitleFontAuto,
                AccessibilityID.floatingSubtitleMaximize,
                AccessibilityID.floatingSubtitleBanner,
            ],
            "the identifiers of the controls that moved"
        )
        let slider = items.first {
            if case .slider = $0.role { return true }
            return false
        }
        XCTAssertEqual(
            slider?.role,
            .slider(value: 0.6, range: SubtitleOverlayBackdropPolicy.opacityRange)
        )
        for item in items where item.role != .separator {
            XCTAssertFalse(item.title.isEmpty)
        }
        actions.forEach { $0.action() }
        slider?.setValue(0.7)
        XCTAssertEqual(picked, ["auto", "theme:dark", "theme:light", "fill", "banner", "backdrop:0.7"])

        let menu = SubtitleOverlayMenuPresenter.menu(for: items, target: nil, action: nil, sliderAction: nil)
        let fill = menu.items.first { $0.identifier?.rawValue == AccessibilityID.floatingSubtitleMaximize }
        XCTAssertEqual(fill?.keyEquivalent, "f")
        XCTAssertEqual(fill?.keyEquivalentModifierMask, [.control, .command])
        let banner = menu.items.first { $0.identifier?.rawValue == AccessibilityID.floatingSubtitleBanner }
        XCTAssertEqual(banner?.keyEquivalent, "b")
        XCTAssertEqual(menu.items.filter { $0.view is SubtitleOverlayMenuSliderRow }.count, 1)

        var filled = state
        filled.placement = .filled
        let restore = SubtitleOverlayMenu.items(state: filled, actions: .init())
            .first { $0.identifier == AccessibilityID.floatingSubtitleMaximize }
        XCTAssertEqual(restore?.title, String(localized: "subtitle.overlay.restore"))
    }

    func testPlacementShortcutsAnswerWithoutTheBar() throws {
        func key(_ characters: String, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: 0, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0
            ))
        }
        XCTAssertEqual(SubtitleOverlayShortcut.matching(try key("f", [.control, .command])), .fill)
        XCTAssertEqual(SubtitleOverlayShortcut.matching(try key("b", [.control, .command, .capsLock])), .banner)
        XCTAssertNil(SubtitleOverlayShortcut.matching(try key("f", [.command])))
        XCTAssertNil(SubtitleOverlayShortcut.matching(try key("f", [.control, .command, .shift])))
        XCTAssertNil(SubtitleOverlayShortcut.matching(try key("x", [.control, .command])))

        let overlay = try source("WindowSystem/Surfaces/SubtitleOverlayController.swift")
        XCTAssertTrue(overlay.contains("SubtitleOverlayPanel("), "the panel that answers the shortcuts")
        XCTAssertFalse(overlay.contains(".keyboardShortcut("), "a shortcut on a button the hover bar may not be showing")
    }

    /// What the hover bar carries: the sentence, the recording controls, pin,
    /// ⋯ and close; the layout switch and the size. Nothing else.
    func testHoverBarKeepsOnlyWhatAPresenterReachesFor() throws {
        let overlay = try source("WindowSystem/Surfaces/SubtitleOverlayController.swift")
        let start = try XCTUnwrap(overlay.range(of: "private func controlRows("))
        let end = try XCTUnwrap(overlay.range(of: "private var moreButton"))
        let rows = String(overlay[start.lowerBound..<end.lowerBound])
        for kept in ["captureStatus(", "SubtitleOverlayRecordingControls(", "pinButton",
                     "moreButton", "closeButton", "modePicker", "fontControls"] {
            XCTAssertTrue(rows.contains(kept), "\(kept) stays on the bar")
        }
        for moved in ["themeButton", "backdropOpacityControl", "fontAutoButton",
                      "maximizeButton", "bannerButton"] {
            XCTAssertFalse(overlay.contains(moved), "\(moved) is an item of the ⋯ menu now")
        }
        XCTAssertTrue(overlay.contains("measuredControlBarHeight = proxy.size.height"),
                      "the bar still measures itself for the hover band")
        XCTAssertTrue(overlay.contains(".labelsHidden()"), "the layout switch is 144 pt of segments, no label")
    }

    func testCaptionSettingsCanBeShownWithoutChangingTheRealOnes() {
        let suite = "WindowsAreaInterfaceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SubtitleOverlayPresentationSettings(defaults: defaults)
        XCTAssertEqual(settings.theme, .dark)
        XCTAssertTrue(settings.isPinned)

        settings.theme = .light
        settings.displayMode = .conversation
        settings.togglePinned()
        XCTAssertEqual(defaults.string(forKey: SubtitleOverlayTheme.defaultsKey), "light")
        XCTAssertEqual(
            defaults.string(forKey: SubtitleOverlayPresentationSettings.displayModeDefaultsKey),
            "conversation"
        )
        XCTAssertEqual(defaults.object(forKey: SubtitleOverlayWindowPolicy.pinnedDefaultsKey) as? Bool, false)
    }

    // MARK: The menu bar

    /// One sentence and its one action; what the action leads to is said to
    /// whoever asks.
    func testSuppressedPopoverPrintsOneSentence() throws {
        let view = try source("MenuBar/MenuBarSuppressedView.swift")
        XCTAssertEqual(
            view.components(separatedBy: "Text(descriptor.body)").count - 1,
            1,
            "only as what VoiceOver says after the action's name"
        )
        XCTAssertTrue(view.contains(".help(descriptor.body)"))
        XCTAssertTrue(view.contains(".accessibilityHint(Text(descriptor.body))"))
        for reason in [MenuBarSuppressionReason.privacy, .userDisabled, .onboarding] {
            let descriptor = MenuBarSuppressedView.Descriptor.descriptor(for: reason)
            XCTAssertFalse(descriptor.title.isEmpty)
            XCTAssertFalse(descriptor.body.isEmpty)
            XCTAssertNotNil(descriptor.action)
        }

        let recording = try source("MenuBar/MenuBarRecordingView.swift")
        XCTAssertEqual(
            recording.components(separatedBy: "\"menubar.recording.live_transcript\"").count - 1,
            1
        )
        XCTAssertTrue(
            recording.contains(".accessibilityLabel(Text(String(localized: \"menubar.recording.live_transcript\")))"),
            "the preview's title is only its accessibility label"
        )
        let processing = try source("MenuBar/MenuBarProcessingView.swift")
        XCTAssertEqual(
            processing.components(separatedBy: "Text(\"\\(Int(info.progress * 100))%\")").count - 1,
            1,
            "the figure sits on the status line, once"
        )
    }

    func testNewLabelsAreShortInEveryLanguage() throws {
        let labels = [
            "share.fact.no_audio", "share.fact.encrypted", "share.fact.deleted_on_stop",
            "share.fact.kept_24h", "share.fact.expires_24h", "share.live.keep_short",
            "share.live.start_short", "share.live.stop_short", "share.live.replace_short",
            "share.qr.show", "share.copy.sent", "subtitle.overlay.menu.banner",
            "subtitle.overlay.menu.backdrop",
        ]
        for language in Self.languages {
            let text = try source("Resources/\(language).lproj/Localizable.strings")
            for key in labels {
                let line = try XCTUnwrap(
                    text.split(separator: "\n").first { $0.hasPrefix("\"\(key)\" = ") },
                    "\(language) lacks \(key)"
                )
                let value = line.dropFirst(key.count + 6).dropLast(2)
                XCTAssertLessThanOrEqual(value.count, 40, "\(language) \(key) is a label: \(value)")
                // German and Spanish labels may end in an abbreviation's stop.
                XCTAssertFalse(value.hasSuffix("。") || value.hasSuffix("!") || value.hasSuffix("?"),
                               "\(language) \(key) is not a sentence")
            }
            XCTAssertFalse(
                text.contains("\"subtitle.overlay.font_auto.off\""),
                "nothing reads the off state any more: the menu item is ticked or not"
            )
        }
    }
}
