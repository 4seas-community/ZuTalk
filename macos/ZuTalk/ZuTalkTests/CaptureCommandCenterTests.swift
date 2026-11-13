import XCTest
@testable import ZuTalk

@MainActor
final class CaptureCommandCenterTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "CaptureCommandCenterTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeCenter() -> CaptureCommandCenter {
        CaptureCommandCenter(defaults: defaults, coreProvider: { nil }, inviteReady: { false })
    }

    /// Nobody has chosen yet and nothing is set up to provide captions, so a
    /// recording stays on this Mac.
    func testCaptionsStartOffWithoutAWayToGetThem() {
        let center = makeCenter()
        XCTAssertFalse(center.realtimeCaptionsEnabled)
        XCTAssertFalse(center.nextRecordingUsesCaptions)
    }

    /// The choice beside the Record button is remembered for the next one.
    func testTheCaptionsChoiceIsRemembered() {
        makeCenter().setRealtimeCaptionsEnabled(true)
        XCTAssertTrue(makeCenter().realtimeCaptionsEnabled)
        makeCenter().setRealtimeCaptionsEnabled(false)
        XCTAssertFalse(makeCenter().realtimeCaptionsEnabled)
    }

    /// Wanting captions is not enough: without a key or an invite the
    /// recording records locally rather than failing to start.
    func testCaptionsNeedACredentialToBeUsed() {
        let center = makeCenter()
        center.setRealtimeCaptionsEnabled(true)
        XCTAssertFalse(center.realtimeCredentialAvailable)
        XCTAssertFalse(center.nextRecordingUsesCaptions)
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
    /// Keys are restored after launch. Before anyone chooses, the default
    /// follows them as they appear instead of freezing at "off".
    func testTheDefaultFollowsCredentialsUntilSomeoneChooses() {
        let suiteName = "CaptureCaptionsDefaultTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var inviteReady = false
        let center = CaptureCommandCenter(
            defaults: defaults,
            coreProvider: { nil },
            inviteReady: { inviteReady }
        )
        XCTAssertFalse(center.realtimeCaptionsEnabled)

        inviteReady = true
        XCTAssertTrue(center.realtimeCaptionsEnabled)
        XCTAssertTrue(center.nextRecordingUsesCaptions)

        center.setRealtimeCaptionsEnabled(false)
        XCTAssertFalse(center.realtimeCaptionsEnabled, "an explicit choice wins")
        XCTAssertFalse(center.nextRecordingUsesCaptions)
    }
}

// MARK: - 0.8.2: what happens after Stop

/// Stop lands on the recording: the one that just ended is remembered for
/// the card on its page, and that page is brought up if the window is there
/// to show it.
@MainActor
final class JustFinishedRecordingTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var opened: [String] = []
    private var windowIsShowing = true

    override func setUp() {
        super.setUp()
        suiteName = "JustFinishedRecordingTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        opened = []
        windowIsShowing = true
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeCenter(navigation: MainNavigationStore) -> CaptureCommandCenter {
        CaptureCommandCenter(
            navigation: navigation,
            defaults: defaults,
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
            webUrl: nil
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
        XCTAssertTrue(strings.contains("\"session.version.show_live\" = \"看边录边出的那一版\";"))
        XCTAssertTrue(strings.contains("\"transcript.copy_all\" = \"复制全文\";"))
        XCTAssertTrue(strings.contains(
            "\"recording.result.summary.audio_only\" = \"这一场只录了音。精修一遍就有文字稿。\";"
        ))
    }
}
