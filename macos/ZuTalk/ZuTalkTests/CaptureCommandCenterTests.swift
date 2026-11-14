import XCTest
@testable import ZuTalk

@MainActor
final class CaptureCommandCenterTests: XCTestCase {
    private func makeCenter() -> CaptureCommandCenter {
        CaptureCommandCenter(coreProvider: { nil }, inviteReady: { false })
    }

    /// Nothing is set up to provide live text, so a recording is made of
    /// the sound alone rather than failing to start.
    func testWithoutAKeyOrAnInviteARecordingHasNoLiveText() {
        let center = makeCenter()
        XCTAssertFalse(center.realtimeCredentialAvailable)
        XCTAssertFalse(center.nextRecordingUsesCaptions)
    }

    /// Live text is not a choice (0.8.4): it is on exactly when something
    /// can provide it. The command center has no setter for it, keeps no
    /// preference, and neither reads nor removes the one an earlier version
    /// saved — whoever chose "audio only" then gets live text again.
    func testLiveTextIsNotAChoiceAndNoPreferenceIsReadOrWritten() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("ZuTalk/Capture/CaptureCommandCenter.swift"),
            encoding: .utf8
        )
        for gone in [
            "setRealtimeCaptionsEnabled", "storedCaptionsChoice", "realtimeCaptionsEnabled",
            "capture.realtime_captions.enabled", "UserDefaults",
        ] {
            XCTAssertFalse(source.contains(gone), "the command center still has \(gone)")
        }
        XCTAssertTrue(source.contains(
            "var nextRecordingUsesCaptions: Bool {\n        realtimeCredentialAvailable\n    }"
        ))
        // An invite cannot be drawn on offline, and there is no switch left
        // to turn live text off with: the recording starts anyway, of the
        // sound alone, and says so.
        XCTAssertTrue(source.contains("catch where wantsCaptions && CommunityInviteError.isOffline(error)"))
        XCTAssertTrue(source.contains("preparation = try await prepare(false)"))
        XCTAssertTrue(source.contains("\"network.offline.audio_only_start\""))
    }

    func testNothingToPauseOrStopWithoutARecording() {
        let center = makeCenter()
        XCTAssertFalse(center.canPause)
        XCTAssertFalse(center.canStop)
    }

    /// Naming "Speaker 1" names the "Speaker 1" recorded after a reconnect
    /// too — but never someone already named, linked, or labelled otherwise.
    func testReconnectTwinsAreTheUnnamedSameLabelSpeakers() {
        func speaker(
            _ id: String,
            label: String,
            epoch: UInt64,
            name: String? = nil,
            participant: String? = nil
        ) -> NotebookSessionSpeakerDTO {
            NotebookSessionSpeakerDTO(
                id: id,
                sessionId: "s",
                providerSessionEpoch: epoch,
                provider: "soniox",
                providerLabel: label,
                localDisplayName: name,
                participantId: participant
            )
        }
        let first = speaker("a", label: "1", epoch: 1)
        let twins = NotebookSessionSpeakerDTO.unnamedReconnectTwins(
            of: first,
            among: [
                first,
                speaker("b", label: "1", epoch: 2),
                speaker("c", label: "2", epoch: 2),
                speaker("d", label: "1", epoch: 3, name: "已命名"),
                speaker("e", label: "1", epoch: 4, participant: "p"),
            ]
        )
        XCTAssertEqual(twins.map(\.id), ["b"])
    }

    func testClockReadsMinutesAndHours() {
        XCTAssertEqual(CaptureCommandCenter.clock(0), "00:00")
        XCTAssertEqual(CaptureCommandCenter.clock(754), "12:34")
        XCTAssertEqual(CaptureCommandCenter.clock(3_725), "1:02:05")
    }

    /// Settings lists what is actually registered — it used to promise font
    /// shortcuts that did nothing and describe ⌃⌥R as "open".
    func testShortcutListMatchesTheRegisteredShortcuts() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ZuTalk", isDirectory: true)
        let settings = try String(
            contentsOf: root.appendingPathComponent("Settings/FullSettingsView.swift"),
            encoding: .utf8
        )
        let hotKeys = try String(
            contentsOf: root.appendingPathComponent("App/HotKeyManager.swift"),
            encoding: .utf8
        )
        for key in ["kVK_ANSI_R", "kVK_ANSI_P", "kVK_ANSI_S"] {
            XCTAssertTrue(hotKeys.contains(key), "\(key) is registered")
        }
        for keys in ["⌃⌥R", "⌃⌥P", "⌃⌥S"] {
            XCTAssertTrue(settings.contains("keys: \"\(keys)\""), "\(keys) is listed")
        }
        XCTAssertFalse(settings.contains("settings.shortcuts.font_bigger"))
        XCTAssertFalse(settings.contains("settings.shortcuts.font_smaller"))
    }
}

@MainActor
final class CaptureCaptionsDefaultTests: XCTestCase {
    /// Keys and invites are restored after launch. Live text follows them
    /// as they appear and as they go, instead of freezing at how things
    /// stood when the app started.
    func testLiveTextFollowsWhatCanProvideIt() {
        var inviteReady = false
        let center = CaptureCommandCenter(
            coreProvider: { nil },
            inviteReady: { inviteReady }
        )
        XCTAssertFalse(center.nextRecordingUsesCaptions)

        inviteReady = true
        XCTAssertTrue(center.realtimeCredentialAvailable)
        XCTAssertTrue(center.nextRecordingUsesCaptions)

        // Switching the invite off in Settings is how a recording of the
        // sound alone is made now.
        inviteReady = false
        XCTAssertFalse(center.nextRecordingUsesCaptions)
    }
}

// MARK: - 0.8.2: what happens after Stop

/// Stop lands on the recording: the one that just ended is remembered for
/// the card on its page, and that page is brought up if the window is there
/// to show it.
@MainActor
final class JustFinishedRecordingTests: XCTestCase {
    private var opened: [String] = []
    private var windowIsShowing = true

    override func setUp() {
        super.setUp()
        opened = []
        windowIsShowing = true
    }

    private func makeCenter(navigation: MainNavigationStore) -> CaptureCommandCenter {
        CaptureCommandCenter(
            navigation: navigation,
            coreProvider: { nil },
            inviteReady: { false },
            mainWindowIsShowing: { [unowned self] in self.windowIsShowing },
            openRecording: { [unowned self] in self.opened.append($0) }
        )
    }

    private func show(_ sessionId: String, in navigation: MainNavigationStore) {
        navigation.openNotebookTab(
            notebookID: "topic",
            tabID: "tab-live",
            documentID: "doc-live",
            selectedSessionID: sessionId
        )
    }

    private let finished = FinishedRecording(sessionId: "just-ended", seconds: 754, audioOnly: false)

    func testNothingHasJustFinishedUntilAStopSucceeds() {
        XCTAssertNil(makeCenter(navigation: MainNavigationStore()).justFinished)
    }

    func testAFinishedRecordingIsRememberedAndItsPageOpened() {
        let center = makeCenter(navigation: MainNavigationStore())

        center.recordingFinished(finished)

        XCTAssertEqual(center.justFinished, finished)
        XCTAssertEqual(opened, ["just-ended"])
    }

    /// Stopped from the menu bar with the window closed: nothing is
    /// navigated behind the person's back, and the card is still there when
    /// they next open that recording.
    func testWithTheWindowNotShowingItIsRememberedButNothingIsOpened() {
        windowIsShowing = false
        let center = makeCenter(navigation: MainNavigationStore())

        center.recordingFinished(finished)

        XCTAssertEqual(center.justFinished, finished)
        XCTAssertEqual(opened, [])
    }

    /// The usual case: the person pressed Stop on the live page.
    func testThePageAlreadyShowingTheRecordingIsNotOpenedAgain() {
        let navigation = MainNavigationStore()
        let center = makeCenter(navigation: navigation)
        show("just-ended", in: navigation)

        center.recordingFinished(finished)

        XCTAssertEqual(center.justFinished, finished)
        XCTAssertEqual(opened, [])
    }

    /// The recording's page was left open under Home: it is not what is on
    /// screen, so Stop brings it back.
    func testAPageLeftBehindUnderHomeIsBroughtBack() {
        let navigation = MainNavigationStore()
        let center = makeCenter(navigation: navigation)
        show("just-ended", in: navigation)
        navigation.navigateHome()

        center.recordingFinished(finished)

        XCTAssertEqual(opened, ["just-ended"])
    }

    func testOpeningAnotherRecordingForgetsTheOneThatJustFinished() {
        let navigation = MainNavigationStore()
        let center = makeCenter(navigation: navigation)
        show("just-ended", in: navigation)
        center.recordingFinished(finished)

        show("an-older-one", in: navigation)

        XCTAssertNil(center.justFinished)
    }

    /// Going Home and coming back to the same recording is not moving on.
    func testLeavingAndComingBackToTheSameRecordingKeepsIt() {
        let navigation = MainNavigationStore()
        let center = makeCenter(navigation: navigation)
        show("just-ended", in: navigation)
        center.recordingFinished(finished)

        navigation.navigateHome()
        show("just-ended", in: navigation)

        XCTAssertEqual(center.justFinished, finished)
    }

    func testClosingTheCardForgetsIt() {
        let center = makeCenter(navigation: MainNavigationStore())
        center.recordingFinished(finished)

        center.dismissJustFinished()

        XCTAssertNil(center.justFinished)
    }

    /// A Stop that failed may have left the recording running; saying
    /// "recorded" then would be a lie. Stop's one implementation records the
    /// finished recording on its success path only.
    func testOnlyAStopThatSucceededRemembersItsRecording() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("ZuTalk/Capture/CaptureCommandCenter.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "func stop(announce: Bool = false) {"))
        let end = try XCTUnwrap(source.range(
            of: "// MARK: - After Stop",
            range: start.upperBound..<source.endIndex
        ))
        let stop = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertEqual(stop.components(separatedBy: "recordingFinished(").count - 1, 1)
        let remembered = try XCTUnwrap(stop.range(of: "recordingFinished(ending)"))
        let stopped = try XCTUnwrap(stop.range(of: "try await capture.stop()"))
        let failure = try XCTUnwrap(stop.range(of: "} catch {"))
        XCTAssertLessThan(stopped.lowerBound, remembered.lowerBound)
        XCTAssertLessThan(remembered.lowerBound, failure.lowerBound)
    }
}

/// What the card on a just-finished recording says, case by case.
final class RecordingResultCardModelTests: XCTestCase {
    private typealias Model = RecordingResultCardModel

    // MARK: Summary line

    func testARecordingWithLiveTextHasItsTranscriptBelowAndItsAudioOnThisMac() {
        XCTAssertEqual(
            Model.summary(liveTextOff: false, hasText: true, hasAudio: true),
            .textAndAudio
        )
        // Before the page has read what the recording has, its own setting
        // is the answer.
        XCTAssertEqual(
            Model.summary(liveTextOff: false, hasText: nil, hasAudio: true),
            .textAndAudio
        )
    }

    func testARecordingMadeWithLiveTextOffIsAudioOnly() {
        XCTAssertEqual(
            Model.summary(liveTextOff: true, hasText: nil, hasAudio: true),
            .audioOnly
        )
        XCTAssertEqual(
            Model.summary(liveTextOff: true, hasText: false, hasAudio: true),
            .audioOnly
        )
    }

    /// Live text was on but none arrived (offline, say): promising a
    /// transcript below would be wrong.
    func testARecordingWhoseTextNeverArrivedIsAudioOnlyToo() {
        XCTAssertEqual(
            Model.summary(liveTextOff: false, hasText: false, hasAudio: true),
            .audioOnly
        )
    }

    func testAnAudioOnlyRecordingThatHasSinceBeenRefinedHasText() {
        XCTAssertEqual(
            Model.summary(liveTextOff: true, hasText: true, hasAudio: true),
            .textAndAudio
        )
    }

    func testAudioAlreadyDeletedIsNotSaidToBeOnThisMac() {
        XCTAssertEqual(
            Model.summary(liveTextOff: false, hasText: true, hasAudio: false),
            .textOnly
        )
    }

    /// Copy and Share are about the text; with none they are not offered.
    func testCopyAndShareNeedText() {
        let withText = Model.make(
            seconds: 754, liveTextOff: false, hasText: true, hasAudio: true, refine: .available
        )
        let audioOnly = Model.make(
            seconds: 754, liveTextOff: true, hasText: nil, hasAudio: true, refine: .available
        )
        XCTAssertTrue(withText.hasText)
        XCTAssertFalse(audioOnly.hasText)
        XCTAssertEqual(withText.duration, RecordingPresentation.duration(ms: 754_000))
        XCTAssertNotNil(withText.duration)
    }

    // MARK: Refine row

    private func refine(
        task: NotebookTabStatus? = nil,
        hasRefinedText: Bool = false,
        isRequesting: Bool = false,
        showingRefined: Bool = false,
        hasAudio: Bool = true,
        hasReadyPersonalKey: Bool = true,
        recordedOn: String? = nil
    ) -> Model.Refine? {
        Model.refine(
            task: task,
            hasRefinedText: hasRefinedText,
            isRequesting: isRequesting,
            showingRefined: showingRefined,
            hasAudio: hasAudio,
            hasReadyPersonalKey: hasReadyPersonalKey,
            recordedOn: recordedOn
        )
    }

    func testRefineIsOfferedWhenItCanStart() {
        XCTAssertEqual(refine(), .available)
    }

    /// Today refining runs on the person's own key. Without one the row says
    /// so and leads to Settings — never a button that does nothing.
    func testWithoutAKeyRefineLeadsToSettings() {
        XCTAssertEqual(refine(hasReadyPersonalKey: false), .needsSetup)
        // A refine already queued waits for the key in the same way.
        XCTAssertEqual(refine(task: .pending, hasReadyPersonalKey: false), .needsSetup)
    }

    func testRefineUnderWayHasNothingToPress() {
        XCTAssertEqual(refine(task: .pending), .inProgress)
        XCTAssertEqual(refine(isRequesting: true), .inProgress)
    }

    func testAFinishedRefineLeadsToTheRefinedTranscript() {
        XCTAssertEqual(refine(task: .ready, hasRefinedText: true), .ready)
        XCTAssertEqual(refine(task: .ready), .ready)
        XCTAssertEqual(refine(task: .failed), .failed)
    }

    /// The refined view's own status bar says how it went; the card does not
    /// offer a button to the page already on screen.
    func testTheRowIsDroppedWhenTheRefinedTranscriptIsAlreadyOnScreen() {
        XCTAssertNil(refine(task: .ready, hasRefinedText: true, showingRefined: true))
        XCTAssertNil(refine(task: .failed, showingRefined: true))
        // Still worth saying while it is on its way, and still startable.
        XCTAssertEqual(refine(task: .pending, showingRefined: true), .inProgress)
        XCTAssertEqual(refine(showingRefined: true), .available)
    }

    func testNothingToRefineWithoutAudioOnThisMac() {
        XCTAssertNil(refine(hasAudio: false))
        XCTAssertNil(refine(recordedOn: "Another Mac"))
    }

    // MARK: Archive line

    private func filing(_ state: FfiCityFilingState) -> FfiCityFiling {
        FfiCityFiling(
            sessionId: "just-ended",
            eventId: "event-1",
            eventTitle: "Language Exchange",
            eventStartMs: 1_794_547_200_000,
            channelTitle: nil,
            state: state,
            filedAtEpoch: nil,
            signerName: "Sam",
            languages: [],
            speakers: 0,
            marks: 0,
            changedSentences: 0,
            errorCode: nil,
            webUrl: nil,
            audioWanted: false,
            audioWithheld: false,
            audioDue: false,
            audioPartsPlanned: 0,
            audioPartsFiled: 0,
            audioErrorCode: nil,
            audioRetryAtEpoch: nil
        )
    }

    func testARecordingNeverGivenAnEventHasNoArchiveLine() {
        XCTAssertNil(Model.city(signedIn: true, filing: nil, busy: false, offline: false))
        XCTAssertNil(Model.city(signedIn: false, filing: filing(.filed), busy: false, offline: false))
    }

    func testAFiledRecordingSaysSo() {
        let status = Model.city(signedIn: true, filing: filing(.filed), busy: false, offline: false)
        XCTAssertEqual(status?.kind, .filed)
        XCTAssertEqual(status, CityFilingStatus.resolve(filing(.filed), busy: false, offline: false))
    }

    func testAQueuedRecordingSaysItIsWaiting() {
        XCTAssertEqual(
            Model.city(signedIn: true, filing: filing(.queued), busy: false, offline: false)?.kind,
            .waiting
        )
        // Being filed this very moment, before the core has a row for it.
        XCTAssertEqual(
            Model.city(signedIn: true, filing: nil, busy: true, offline: false)?.kind,
            .sending
        )
    }
}

/// The one button that replaced the 实时版 | 精修版 switch names the version
/// you can go to, not the one you are on.
final class TranscriptVersionButtonTests: XCTestCase {
    func testTheButtonNamesTheOtherVersion() {
        XCTAssertEqual(
            TranscriptVersionButtonPolicy.labelKey(showing: .asyncTranscript),
            "session.version.show_live"
        )
        XCTAssertEqual(
            TranscriptVersionButtonPolicy.labelKey(showing: .realtimeTranscript),
            "session.version.show_refined"
        )
        XCTAssertNil(TranscriptVersionButtonPolicy.labelKey(showing: .manualNote))
        XCTAssertEqual(
            TranscriptVersionButtonPolicy.destination(showing: .asyncTranscript),
            .realtimeTranscript
        )
        XCTAssertEqual(
            TranscriptVersionButtonPolicy.destination(showing: .realtimeTranscript),
            .asyncTranscript
        )
    }

    /// An imported file, or a recording made with live text off, has no live
    /// version to go back to.
    func testThereIsNoWayBackToALiveVersionThatDoesNotExist() {
        XCTAssertFalse(TranscriptVersionButtonPolicy.isOffered(
            showing: .asyncTranscript, hasLiveVersion: false
        ))
        XCTAssertTrue(TranscriptVersionButtonPolicy.isOffered(
            showing: .asyncTranscript, hasLiveVersion: true
        ))
        // The refined view is always reachable: it is also where refining
        // an older recording starts.
        XCTAssertTrue(TranscriptVersionButtonPolicy.isOffered(
            showing: .realtimeTranscript, hasLiveVersion: false
        ))
    }

    /// One name for the thing in every language's new copy: the keys exist
    /// and the reference wording is the one the interface rules fix.
    func testTheReferenceWordingIsTheAgreedOne() throws {
        let strings = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("ZuTalk/Resources/zh-Hans.lproj/Localizable.strings"),
            encoding: .utf8
        )
        XCTAssertTrue(strings.contains("\"session.version.show_refined\" = \"看精修稿\";"))
        XCTAssertTrue(strings.contains("\"session.version.show_live\" = \"看现场稿\";"))
        XCTAssertTrue(strings.contains("\"transcript.copy_all\" = \"复制全文\";"))
        XCTAssertTrue(strings.contains(
            "\"recording.result.summary.audio_only\" = \"这一场只录了音。精修一遍就有文字稿。\";"
        ))
    }
}

// MARK: - 0.8.3: one word per control in the recording area

/// A recording's page says things in a word: the card after Stop, the tab
/// bar, the details tab, the bar over a refined transcript. The sentences
/// that used to be printed are tooltips now, and these pin which.
final class RecordingAreaWordingTests: XCTestCase {
    private func strings(_ language: String) throws -> [String: String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ZuTalk/Resources/\(language).lproj/Localizable.strings")
        return try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
    }

    private func source(_ file: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("ZuTalk/\(file)"),
            encoding: .utf8
        )
    }

    /// Where refining stands is the pill's word, icon and tone; why, its
    /// tooltip. "Needs setup" still leads to Settings.
    func testTheRefinePillSaysWhereRefiningStandsAndWhatAPressDoes() {
        let available = RefinePillFace.resolve(.available, hasText: true)
        XCTAssertEqual(available.press, .refine)
        XCTAssertFalse(available.isPrimary, "Copy is the filled pill when there is text")
        XCTAssertEqual(available.helpKeys, ["recording.result.refine.detail"])

        // With no text yet, refining is the thing to do next.
        let audioOnly = RefinePillFace.resolve(.available, hasText: false)
        XCTAssertTrue(audioOnly.isPrimary)
        XCTAssertEqual(audioOnly.helpKeys.first, "recording.result.summary.audio_only")

        let needsSetup = RefinePillFace.resolve(.needsSetup, hasText: true)
        XCTAssertEqual(needsSetup.press, .openSettings)
        XCTAssertEqual(needsSetup.mark, .warning)
        XCTAssertEqual(needsSetup.tone, .dimmed)
        XCTAssertEqual(needsSetup.helpKeys, ["recording.result.refine.needs_setup"])

        let running = RefinePillFace.resolve(.inProgress, hasText: true)
        XCTAssertEqual(running.press, .nothing)
        XCTAssertEqual(running.helpKeys, ["recording.result.refine.in_progress"])

        let ready = RefinePillFace.resolve(.ready, hasText: true)
        XCTAssertEqual(ready.press, .showRefined)
        XCTAssertEqual(ready.tone, .on)
        XCTAssertEqual(ready.titleKey, "resources.async")

        let failed = RefinePillFace.resolve(.failed, hasText: true)
        XCTAssertEqual(failed.press, .showRefined)
        XCTAssertEqual(failed.tone, .warning)

        // No two states look alike.
        let faces = [available, needsSetup, running, ready, failed]
        XCTAssertEqual(
            Set(faces.map { "\($0.titleKey)|\($0.systemImage)|\($0.tone)|\($0.mark)" }).count,
            faces.count
        )
    }

    /// The version pill shows the version on screen, not the other one.
    func testTheVersionPillNamesTheVersionOnScreen() {
        XCTAssertEqual(TranscriptVersionButtonPolicy.titleKey(.realtimeTranscript), "resources.realtime")
        XCTAssertEqual(TranscriptVersionButtonPolicy.titleKey(.asyncTranscript), "resources.async")
        XCTAssertNil(TranscriptVersionButtonPolicy.titleKey(.manualNote))
    }

    func testEveryControlIsAWordOrTwoInEveryLanguage() throws {
        let words: [(key: String, zh: String, en: String)] = [
            ("recording.word.copy", "复制", "Copy"),
            ("recording.word.share", "分享", "Share"),
            ("common.export.action", "导出", "Export"),
            ("recording.word.rename", "改名", "Rename"),
            ("sidebar.notebook", "主题", "Topic"),
            ("session.tab.settings", "详情", "Details"),
            ("recording.word.delete_audio", "删音频", "Delete audio"),
            ("common.delete", "删除", "Delete"),
            ("refine.action", "精修", "Refine"),
            ("recording.word.open", "打开", "Open"),
            ("recording.word.verify", "核验", "Verify"),
            ("recording.word.read_only", "只读", "Read-only"),
            ("recording.word.select", "选择", "Select"),
            ("recording.word.select_all", "全选", "Select all"),
            ("recording.word.version", "版本", "Version"),
            ("recording.details.files", "文件", "Files"),
            ("recording.details.info", "信息", "Info"),
            ("recording.details.setup", "配置", "Setup"),
        ]
        let zh = try strings("zh-Hans")
        let en = try strings("en")
        for word in words {
            XCTAssertEqual(zh[word.key], word.zh, word.key)
            XCTAssertEqual(en[word.key], word.en, word.key)
        }
        let keys = words.map(\.key)
        for language in AppLanguage.allCases {
            let table = try strings(language.rawValue)
            for key in keys {
                let value = try XCTUnwrap(table[key], "\(language.rawValue) \(key)")
                XCTAssertLessThanOrEqual(value.count, 24, "\(language.rawValue) \(key): \(value)")
                for stop in ["。", ". ", "，", ", ", "；", "：", ": "] {
                    XCTAssertFalse(
                        value.contains(stop),
                        "\(language.rawValue) \(key) reads as a sentence: \(value)"
                    )
                }
            }
        }
    }

    /// The ⋯ of a recording: take away, then name and file, then remove.
    func testTheRecordingMenuIsWordsWithTheRemovalsLast() throws {
        let page = try source("Pages/DocumentEditorPage.swift")
        let start = try XCTUnwrap(page.range(of: "private var recordingMenu: some View"))
        let end = try XCTUnwrap(page.range(
            of: ".accessibilityIdentifier(\"session.menu\")",
            range: start.upperBound..<page.endIndex
        ))
        let menu = String(page[start.lowerBound..<end.lowerBound])
        let order = [
            "recording.word.copy", "recording.word.share", "common.export.action",
            "recording.word.rename", "sidebar.notebook", "session.tab.settings",
            "recording.word.delete_audio", "common.delete",
        ]
        var cursor = menu.startIndex
        for key in order {
            let found = try XCTUnwrap(
                menu.range(of: "\"\(key)\"", range: cursor..<menu.endIndex),
                "\(key) is missing or out of order"
            )
            cursor = found.upperBound
        }
        XCTAssertEqual(menu.components(separatedBy: "role: .destructive").count - 1, 2)
        XCTAssertTrue(menu.contains("MorePill("))
    }

    /// The card after Stop is a title and one strip of the shared pills,
    /// and prints no sentence. From this version audio can leave the Mac
    /// (it may be filed to a city's archive), so nothing here says it stays.
    func testTheResultCardIsATitleAndOneStripAndClaimsNothingAboutWhereAudioStays() throws {
        let card = try source("Pages/RecordingResultCard.swift")
        let start = try XCTUnwrap(card.range(of: "struct RecordingResultCard: View"))
        let end = try XCTUnwrap(card.range(of: "enum TranscriptVersionButtonPolicy"))
        let view = String(card[start.lowerBound..<end.lowerBound])
        for used in ["PillStrip {", "PrimaryPill(", "ActionPill("] {
            XCTAssertTrue(view.contains(used), "the card should use \(used)")
        }
        for own in ["Text(summaryText)", "refineDetail(", "Divider()", "RoundedRectangle"] {
            XCTAssertFalse(view.contains(own), "the card should not have \(own)")
        }
        XCTAssertEqual(view.components(separatedBy: "PrimaryPill(").count - 1, 2,
                       "Copy, or Refine in its place when there is no text")
        XCTAssertTrue(view.contains(".pillExplained(help: summaryText)"))

        for language in AppLanguage.allCases {
            let table = try strings(language.rawValue)
            for gone in [
                "recording.result.summary.text_and_audio",
                "captions_choice.off_hint",
                "editor.transcript.async.failed_desc",
            ] {
                XCTAssertNil(table[gone], "\(language.rawValue) still has \(gone)")
            }
            // Where the audio goes when there is live text stays a
            // disclosure, by name.
            let disclosure = try XCTUnwrap(table["home.card.live_text_disclosure"])
            XCTAssertTrue(disclosure.contains("Soniox"), "\(language.rawValue): \(disclosure)")
        }
        // It is read where a recording starts — every Start button says it
        // on hover and to VoiceOver — and, one click away, where live text
        // is set up. The choice it used to sit beside is gone.
        let notice = try source("Pages/LiveTextNotice.swift")
        XCTAssertTrue(notice.contains("[String(localized: \"home.card.live_text_disclosure\")]"))
        XCTAssertTrue(try source("Pages/NotebookCaptureToolbar.swift").contains("LiveTextStartHint.lines("))
        XCTAssertTrue(try source("Pages/HomeStartCard.swift").contains("LiveTextStartHint.lines("))
        XCTAssertTrue(try source("Settings/AccountSettingsSection.swift").contains(
            "info: String(localized: \"home.card.live_text_disclosure\")"
        ))
        XCTAssertFalse(try source("UIScenes/Main/RecordingBar.swift").contains("CaptionsChoiceChip"))
    }

    /// The recording bar, the tab bar and the sheets draw no capsule of
    /// their own: they are the shared pills.
    func testTheRecordingAreaDrawsNoPillsOfItsOwn() throws {
        let bar = try source("UIScenes/Main/RecordingBar.swift")
        let start = try XCTUnwrap(bar.range(of: "struct RecordingBarContent: View"))
        let end = try XCTUnwrap(bar.range(of: "struct RecordingAttention: Equatable"))
        let content = String(bar[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(content.contains("ActionPill("))
        XCTAssertTrue(content.contains("MorePill("))
        XCTAssertTrue(content.contains(".modifier(PillChrome())"))
        for own in ["Capsule()", ".frame(minHeight: 30)", "tint.opacity("] {
            XCTAssertFalse(content.contains(own), "the bar should not draw its own \(own)")
        }
        for file in ["Library/ExportSheet.swift", "Library/LibraryCommands.swift"] {
            let sheet = try source(file)
            XCTAssertTrue(sheet.contains("SheetButtons("), file)
            XCTAssertFalse(sheet.contains("GroupBox("), file)
            XCTAssertFalse(sheet.contains("library.file.message\"))\n                    .font"), file)
        }
    }
}

// MARK: - 0.8.4: a finished recording is filed to an event from where it is

/// 「交到活动」: where it shows and as what. Three entries — the card after
/// Stop, the recording's tab bar, its ⋯ menu — and one sheet.
final class CityFilingEntryTests: XCTestCase {
    private func entry(
        _ place: CityFilingEntry.Place,
        signedIn: Bool = true,
        hosting: Bool = true,
        filing: Bool = false,
        recording: Bool = false
    ) -> CityFilingEntry {
        CityFilingEntry.resolve(
            place: place,
            signedIn: signedIn,
            hostingOn: hosting,
            hasFiling: filing,
            isRecording: recording
        )
    }

    private func source(_ file: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("ZuTalk/\(file)"),
            encoding: .utf8
        )
    }

    private func strings(_ language: String) throws -> [String: String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ZuTalk/Resources/\(language).lproj/Localizable.strings")
        return try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
    }

    /// Signing in is offered on Home's hosting row; nothing here stands in
    /// for it.
    func testNotSignedInNothingIsOfferedAnywhere() {
        for place in [CityFilingEntry.Place.surface, .menu] {
            for hosting in [true, false] {
                for filing in [true, false] {
                    XCTAssertEqual(
                        entry(place, signedIn: false, hosting: hosting, filing: filing),
                        .none
                    )
                }
            }
        }
    }

    /// Where the recording in progress will go is the recording bar's to
    /// say; it can be filed once it has stopped.
    func testTheRecordingInProgressOffersNothing() {
        XCTAssertEqual(entry(.surface, recording: true), .none)
        XCTAssertEqual(entry(.surface, filing: true, recording: true), .none)
        XCTAssertEqual(entry(.menu, recording: true), .none)
    }

    /// The page is the first layer: the way in is there for someone hosting.
    /// A filing that exists shows its status whatever the switch says.
    func testOnThePageTheWayInIsForSomeoneHostingAndAFilingAlwaysShows() {
        XCTAssertEqual(entry(.surface, hosting: true, filing: false), .action)
        XCTAssertEqual(entry(.surface, hosting: false, filing: false), .none)
        XCTAssertEqual(entry(.surface, hosting: true, filing: true), .status)
        XCTAssertEqual(entry(.surface, hosting: false, filing: true), .status)
    }

    /// A menu is the second layer: anyone signed in finds it there.
    func testInAMenuItIsOfferedToAnyoneSignedIn() {
        for hosting in [true, false] {
            for filing in [true, false] {
                XCTAssertEqual(entry(.menu, hosting: hosting, filing: filing), .action)
            }
        }
    }

    /// On the card the pill and the status are the same place in two
    /// states: never both.
    func testTheCardOffersThePillOrShowsTheStatusNeverBoth() {
        let offered = RecordingResultCardModel.make(
            seconds: 754, liveTextOff: false, hasText: true, hasAudio: true,
            refine: nil, offersFiling: true
        )
        XCTAssertTrue(offered.offersFiling)
        XCTAssertNil(offered.city)

        let filing = RecordingResultCardModel.make(
            seconds: 754, liveTextOff: false, hasText: true, hasAudio: true,
            refine: nil,
            city: CityFilingStatus.resolve(nil, busy: true, offline: false),
            offersFiling: true
        )
        XCTAssertFalse(filing.offersFiling)
        XCTAssertNotNil(filing.city)

        XCTAssertFalse(RecordingResultCardModel.make(
            seconds: 754, liveTextOff: false, hasText: true, hasAudio: true, refine: nil
        ).offersFiling)
    }

    func testAllThreeEntriesOpenOneSheetAndTheSheetIsTheArchiveBlock() throws {
        // One presenter, one sheet.
        let store = try source("App/ShareActivityStore.swift")
        XCTAssertTrue(store.contains("func presentCityFiling(sessionId: String, title: String)"))
        let shell = try source("UIScenes/Main/MainShellView.swift")
        XCTAssertTrue(shell.contains(
            ".sheet(item: $shareActivity.cityFilingRequest) { request in\n            CityFilingSheet(request: request)"
        ))
        // The sheet is the share panel's own archive block and nothing else:
        // no second set of actions, no second copy of its disclosures.
        let sheet = try source("Pages/CityFilingSheet.swift")
        XCTAssertTrue(sheet.contains("CityShareSection(request: request, standsAlone: true)"))
        for own in ["InfoButton(", "city.share.public_note", "city.audio.public", "city.action.file"] {
            XCTAssertFalse(sheet.contains(own), "the sheet should not have its own \(own)")
        }
        XCTAssertTrue(try source("Pages/ShareHostPanel.swift").contains("CityShareSection(request: request)"))

        // The card, the tab bar, and the three menus.
        let card = try source("Pages/RecordingResultCard.swift")
        XCTAssertTrue(card.contains("if model.offersFiling {"))
        XCTAssertTrue(card.contains("action: onFile"))
        let page = try source("Pages/DocumentEditorPage.swift")
        XCTAssertTrue(page.contains("CityFilingEntryPill(sessionId: sessionId, onOpen: onFile"))
        XCTAssertTrue(page.contains("CityFilingMenuItem(sessionId: sessionId, onOpen: onFile)"))
        XCTAssertTrue(page.contains("ShareActivityStore.shared.presentCityFiling(sessionId: sessionId, title: label)"))
        for list in ["Pages/HomeView.swift", "Pages/NotebookResourcesView.swift"] {
            let text = try source(list)
            XCTAssertTrue(text.contains("CityFilingMenuItem(sessionId:"), list)
            XCTAssertTrue(text.contains("ShareActivityStore.shared.presentCityFiling("), list)
        }
    }

    /// The entry is a word or two in every language; and what the archive
    /// block says about being public, standing alone, is what it says in the
    /// share panel without the comparison to the link below it.
    func testTheEntryIsShortAndThePublicNoteKeepsItsSubstance() throws {
        XCTAssertEqual(try strings("zh-Hans")["city.filing.action"], "交到活动")
        XCTAssertEqual(try strings("en")["city.filing.action"], "File to event")
        for language in AppLanguage.allCases {
            let table = try strings(language.rawValue)
            let action = try XCTUnwrap(table["city.filing.action"], language.rawValue)
            XCTAssertLessThanOrEqual(action.count, 26, "\(language.rawValue): \(action)")
            for stop in ["。", ". ", "，", ", ", "：", ": "] {
                XCTAssertFalse(action.contains(stop), "\(language.rawValue): \(action)")
            }
            let alone = try XCTUnwrap(table["city.filing.public_note"], language.rawValue)
            let inPanel = try XCTUnwrap(table["city.share.public_note"], language.rawValue)
            let core = alone.trimmingCharacters(in: CharacterSet(charactersIn: ".。"))
            XCTAssertTrue(inPanel.hasPrefix(core), "\(language.rawValue): \(alone)")
        }
    }
}
