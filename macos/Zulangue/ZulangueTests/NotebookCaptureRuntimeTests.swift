import AppKit
import Combine
import CoreAudio
import XCTest
@testable import Zulangue

final class NotebookCaptureRuntimeTests: XCTestCase {

    // MARK: - ActiveBilingualTranscriptStore

    @MainActor
    func testRealtimeTabLiveStatusComesOnlyFromTheActiveCapture() {
        let live = NotebookRealtimeTabStatusPolicy.resolve(
            displayType: .realtimeTranscript,
            baseStatus: .ready,
            tabNotebookId: "notebook-a",
            activeNotebookId: "notebook-a",
            activeSessionId: "session-a",
            captureIsActive: true
        )
        XCTAssertEqual(live, .live)

        let completed = NotebookRealtimeTabStatusPolicy.resolve(
            displayType: .realtimeTranscript,
            baseStatus: .live,
            tabNotebookId: "notebook-a",
            activeNotebookId: "notebook-a",
            activeSessionId: "session-a",
            captureIsActive: false
        )
        XCTAssertEqual(completed, .ready)

        let otherNotebook = NotebookRealtimeTabStatusPolicy.resolve(
            displayType: .realtimeTranscript,
            baseStatus: .live,
            tabNotebookId: "notebook-b",
            activeNotebookId: "notebook-a",
            activeSessionId: "session-a",
            captureIsActive: true
        )
        XCTAssertEqual(otherNotebook, .ready)

        let missingActiveSession = NotebookRealtimeTabStatusPolicy.resolve(
            displayType: .realtimeTranscript,
            baseStatus: .live,
            tabNotebookId: "notebook-a",
            activeNotebookId: "notebook-a",
            activeSessionId: nil,
            captureIsActive: true
        )
        XCTAssertEqual(missingActiveSession, .ready)

        let asyncStatus = NotebookRealtimeTabStatusPolicy.resolve(
            displayType: .asyncTranscript,
            baseStatus: .failed,
            tabNotebookId: "notebook-a",
            activeNotebookId: "notebook-a",
            activeSessionId: "session-a",
            captureIsActive: true
        )
        XCTAssertEqual(asyncStatus, .failed)
    }

    @MainActor
    func testNotebookCaptureDefaultsAreLocalAndDoNotSendContext() {
        let profile = NotebookCaptureProfileDTO.localDefault(notebookId: "notebook-a")

        XCTAssertFalse(profile.remoteRealtimeEnabled)
        XCTAssertEqual(profile.mode, .transcriptionOnly)
        XCTAssertEqual(profile.privacyLevel, .standard)
        XCTAssertFalse(profile.sendContextToSoniox)
        XCTAssertEqual(profile.languageA, "en")
        XCTAssertEqual(profile.languageB, "zh")
        XCTAssertEqual(profile.selectedLanguages, ["en", "zh"])
        XCTAssertNil(profile.commonCaptionLanguage)
    }

    @MainActor
    func testTranscriptClipboardPublishesOnlyExplicitNonEmptyText() {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("xyz.voice.zulangue.tests.\(UUID().uuidString)")
        )
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("sentinel", forType: .string))

        XCTAssertFalse(TranscriptClipboard.write(" \n ", to: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), "sentinel")

        XCTAssertTrue(TranscriptClipboard.write("ZH: 你好\nEN: Hello", to: pasteboard))
        XCTAssertEqual(
            pasteboard.string(forType: .string),
            "ZH: 你好\nEN: Hello"
        )
    }

    @MainActor
    func testCaptureSettingsEditorAutosavesEachChangeWithFreshRevision() {
        var initial = NotebookCaptureProfileDTO.localDefault(notebookId: "notebook-a")
        initial.revision = 4
        let persistence = FakeNotebookCaptureProfilePersistence(profile: initial)
        let editor = NotebookCaptureProfileEditorModel(
            notebookId: "notebook-a",
            persistence: persistence
        )

        editor.load()
        editor.update { $0.remoteRealtimeEnabled = true }
        editor.update { $0.selectedLanguages = ["en"] }
        editor.update { $0.selectedLanguages = ["ja", "en", "zh"] }

        XCTAssertEqual(persistence.saveRequests.map(\.revision), [4, 5, 6])
        XCTAssertEqual(editor.draft.revision, 7)
        XCTAssertEqual(editor.draft.mode, .multilingualOneWay)
        XCTAssertEqual(editor.draft.selectedLanguages, ["ja", "en", "zh"])
        XCTAssertNil(editor.draft.commonCaptionLanguage)
        XCTAssertEqual(editor.draft.languageA, "ja")
        XCTAssertEqual(editor.persistenceState, .saved)
    }

    @MainActor
    func testCaptureSettingsEditorDefersViewActionsAndDrainsThemInOrder() async {
        var initial = NotebookCaptureProfileDTO.localDefault(notebookId: "notebook-a")
        initial.revision = 12
        let persistence = FakeNotebookCaptureProfilePersistence(profile: initial)
        let editor = NotebookCaptureProfileEditorModel(
            notebookId: "notebook-a",
            persistence: persistence
        )
        editor.load()

        let firstDrain = editor.scheduleUpdate(.remoteRealtimeEnabled(true))
        let secondDrain = editor.scheduleUpdate(.selectedLanguages(["en", "zh", "th"]))

        XCTAssertFalse(
            editor.draft.remoteRealtimeEnabled,
            "a SwiftUI Binding setter must not publish while its view update is still running"
        )
        XCTAssertTrue(persistence.saveRequests.isEmpty)

        await firstDrain.value
        await secondDrain.value

        XCTAssertEqual(persistence.saveRequests.map(\.revision), [12, 13])
        XCTAssertEqual(persistence.saveRequests[0].mode, .twoWay)
        XCTAssertEqual(persistence.saveRequests[1].mode, .multilingualOneWay)
        XCTAssertTrue(editor.draft.remoteRealtimeEnabled)
        XCTAssertEqual(editor.draft.mode, .multilingualOneWay)
        XCTAssertEqual(editor.draft.selectedLanguages, ["en", "zh", "th"])
        XCTAssertEqual(editor.draft.revision, 14)
    }

    @MainActor
    func testQueuedLanguageEditsComposeAgainstTheLatestSavedOrder() async {
        var initial = NotebookCaptureProfileDTO.twoWay(notebookId: "notebook-a")
        initial.revision = 20
        let persistence = FakeNotebookCaptureProfilePersistence(profile: initial)
        let editor = NotebookCaptureProfileEditorModel(
            notebookId: "notebook-a",
            persistence: persistence
        )
        editor.load()

        let addThai = editor.scheduleUpdate(.addLanguage("th"))
        let addJapaneseAtLimit = editor.scheduleUpdate(.addLanguage("ja"))
        let removeChinese = editor.scheduleUpdate(.removeLanguage("zh"))
        let addJapanese = editor.scheduleUpdate(.addLanguage("ja"))
        let moveJapaneseFirst = editor.scheduleUpdate(.moveLanguage("ja", offset: -2))

        await addThai.value
        await addJapaneseAtLimit.value
        await removeChinese.value
        await addJapanese.value
        await moveJapaneseFirst.value

        XCTAssertEqual(editor.draft.selectedLanguages, ["ja", "en", "th"])
        XCTAssertNil(editor.draft.commonCaptionLanguage)
        XCTAssertEqual(
            persistence.saveRequests.map(\.selectedLanguages),
            [
                ["en", "zh", "th"],
                ["en", "th"],
                ["en", "th", "ja"],
                ["ja", "en", "th"],
            ]
        )
        XCTAssertEqual(persistence.saveRequests.map(\.revision), [20, 21, 22, 23])
    }

    @MainActor
    func testCaptureStartImplicitlyAuthorizesRealtimeBeforePreparingAudio() async throws {
        let client = FakeNotebookCaptureClient(
            profile: .localDefault(notebookId: "notebook-a")
        )
        let audio = FakeNotebookCaptureAudioSource()
        let store = ActiveBilingualTranscriptStore(client: client, audioSource: audio)
        let editor = NotebookCaptureProfileEditorModel(
            notebookId: "notebook-a",
            persistence: store
        )
        editor.load()

        XCTAssertFalse(client.profile.remoteRealtimeEnabled)

        try await editor.prepareForCaptureStart()
        try await store.start(notebookId: "notebook-a")

        XCTAssertTrue(client.profile.remoteRealtimeEnabled)
        XCTAssertEqual(client.profile.mode, .twoWay)
        XCTAssertEqual(client.profileUpdateCount, 1)
        XCTAssertEqual(client.startCount, 1)
        XCTAssertEqual(audio.prepareCount, 1)
        try await store.stop()
    }

    @MainActor
    func testMenuBarShowsOrderedSessionLanguagesWithoutTranslationArrows() async throws {
        MenuBarRuntimeStore.shared.resetForTesting()
        defer { MenuBarRuntimeStore.shared.resetForTesting() }

        let twoLanguageStore = ActiveBilingualTranscriptStore(
            client: FakeNotebookCaptureClient(profile: .twoWay(notebookId: "notebook-a")),
            audioSource: FakeNotebookCaptureAudioSource()
        )
        try await twoLanguageStore.start(notebookId: "notebook-a")
        XCTAssertEqual(
            MenuBarRuntimeStore.shared.activeRecordingInfo?.languagePair,
            "EN · 中"
        )
        try await twoLanguageStore.stop()

        var multilingual = NotebookCaptureProfileDTO.twoWay(notebookId: "notebook-b")
        multilingual.mode = .multilingualOneWay
        multilingual.selectedLanguages = ["en", "zh", "th"]
        multilingual.commonCaptionLanguage = nil
        let multilingualStore = ActiveBilingualTranscriptStore(
            client: FakeNotebookCaptureClient(profile: multilingual),
            audioSource: FakeNotebookCaptureAudioSource()
        )
        try await multilingualStore.start(notebookId: "notebook-b")
        let languageSummary = try XCTUnwrap(
            MenuBarRuntimeStore.shared.activeRecordingInfo?.languagePair
        )
        XCTAssertEqual(languageSummary, "EN · 中 · TH")
        XCTAssertFalse(languageSummary.contains("↔"))
        XCTAssertFalse(languageSummary.contains("→"))
        try await multilingualStore.stop()
    }

    @MainActor
    func testCaptureStartUsesLatestQueuedMultilingualProfile() async throws {
        let client = FakeNotebookCaptureClient(
            profile: .localDefault(notebookId: "notebook-a")
        )
        let audio = FakeNotebookCaptureAudioSource()
        let store = ActiveBilingualTranscriptStore(client: client, audioSource: audio)
        let editor = NotebookCaptureProfileEditorModel(
            notebookId: "notebook-a",
            persistence: store
        )
        editor.load()

        _ = editor.scheduleUpdate(.addLanguage("th"))
        try await editor.prepareForCaptureStart()
        try await store.start(notebookId: "notebook-a")

        XCTAssertEqual(client.profile.selectedLanguages, ["en", "zh", "th"])
        XCTAssertNil(client.profile.commonCaptionLanguage)
        XCTAssertEqual(client.profile.mode, .multilingualOneWay)
        XCTAssertTrue(client.profile.remoteRealtimeEnabled)
        XCTAssertEqual(client.profile.revision, 2)
        XCTAssertEqual(client.profileUpdateCount, 2)
        XCTAssertEqual(client.startCount, 1)
        XCTAssertEqual(audio.prepareCount, 1)
        try await store.stop()
    }

    @MainActor
    func testCaptureStartFailsBeforeAudioWhenImplicitRealtimeAuthorizationSaveFails() async {
        let client = FakeNotebookCaptureClient(
            profile: .localDefault(notebookId: "notebook-a")
        )
        client.profileUpdateError = .ffiUnavailable
        let audio = FakeNotebookCaptureAudioSource()
        let store = ActiveBilingualTranscriptStore(client: client, audioSource: audio)
        let editor = NotebookCaptureProfileEditorModel(
            notebookId: "notebook-a",
            persistence: store
        )
        editor.load()

        do {
            try await editor.prepareForCaptureStart()
            try await store.start(notebookId: "notebook-a")
            XCTFail("a failed autosave must block capture start")
        } catch {
            XCTAssertTrue(error is NotebookCaptureProfileStartBlockedError)
        }

        XCTAssertEqual(client.profileUpdateCount, 1)
        XCTAssertEqual(client.startCount, 0)
        XCTAssertEqual(audio.prepareCount, 0)
        XCTAssertFalse(store.hasAudioSubscription)
    }

    @MainActor
    func testCaptureStartFailsBeforeAudioWhenQueuedLanguageAutosaveFails() async {
        let client = FakeNotebookCaptureClient(
            profile: .localDefault(notebookId: "notebook-a")
        )
        client.profileUpdateError = .ffiUnavailable
        let audio = FakeNotebookCaptureAudioSource()
        let store = ActiveBilingualTranscriptStore(client: client, audioSource: audio)
        let editor = NotebookCaptureProfileEditorModel(
            notebookId: "notebook-a",
            persistence: store
        )
        editor.load()

        _ = editor.scheduleUpdate(.addLanguage("th"))

        do {
            try await editor.prepareForCaptureStart()
            try await store.start(notebookId: "notebook-a")
            XCTFail("a failed queued language autosave must block capture start")
        } catch {
            XCTAssertTrue(error is NotebookCaptureProfileStartBlockedError)
        }

        XCTAssertEqual(editor.draft.selectedLanguages, ["en", "zh", "th"])
        XCTAssertEqual(client.profileUpdateCount, 2)
        XCTAssertEqual(client.startCount, 0)
        XCTAssertEqual(audio.prepareCount, 0)
        XCTAssertFalse(store.hasAudioSubscription)
    }

    @MainActor
    func testProfileAutosaveSurvivesOriginatingViewTeardown() async {
        let persistence = FakeNotebookCaptureProfilePersistence(
            profile: .localDefault(notebookId: "notebook-a")
        )
        var editor: NotebookCaptureProfileEditorModel? = NotebookCaptureProfileEditorModel(
            notebookId: "notebook-a",
            persistence: persistence
        )
        editor!.load()
        let drain = editor!.scheduleUpdate(.remoteRealtimeEnabled(true))

        editor = nil
        await drain.value

        XCTAssertEqual(persistence.saveRequests.count, 1)
        XCTAssertTrue(persistence.saveRequests[0].remoteRealtimeEnabled)
    }

    @MainActor
    func testCaptureSettingsEditorSubmitsOnlyNormalizedSnapshots() {
        var initial = NotebookCaptureProfileDTO.twoWay(notebookId: "notebook-a")
        initial.sendContextToSoniox = true
        let persistence = FakeNotebookCaptureProfilePersistence(profile: initial)
        let editor = NotebookCaptureProfileEditorModel(
            notebookId: "notebook-a",
            persistence: persistence
        )
        editor.load()

        editor.update { $0.remoteRealtimeEnabled = false }

        let saved = persistence.saveRequests.last
        XCTAssertEqual(persistence.saveRequests.count, 1)
        XCTAssertEqual(saved?.remoteRealtimeEnabled, false)
        XCTAssertEqual(saved?.mode, .transcriptionOnly)
        XCTAssertEqual(saved?.sendContextToSoniox, false)

        editor.update { $0.remoteRealtimeEnabled = true }
        editor.update {
            $0.selectedLanguages = [" TH-th ", "en-US", "th", ""]
        }
        XCTAssertEqual(persistence.saveRequests.last?.mode, .twoWay)
        XCTAssertEqual(persistence.saveRequests.last?.selectedLanguages, ["th", "en"])
        XCTAssertEqual(persistence.saveRequests.last?.languageA, "th")
        XCTAssertEqual(persistence.saveRequests.last?.languageB, "en")
        XCTAssertNil(persistence.saveRequests.last?.commonCaptionLanguage)

        editor.update { $0.selectedLanguages = ["zh", "th", "en"] }
        XCTAssertEqual(persistence.saveRequests.last?.mode, .multilingualOneWay)
        XCTAssertNil(persistence.saveRequests.last?.commonCaptionLanguage)
    }

    @MainActor
    func testCaptureLanguageCountDerivesModeWithoutPromotingTheFirstColumn() {
        let cases: [([String], NotebookCaptureMode)] = [
            (["en"], .transcriptionOnly),
            (["en", "zh"], .twoWay),
            (["en", "zh", "th"], .multilingualOneWay),
            (["ja", "en", "zh"], .multilingualOneWay),
        ]

        for (languages, expectedMode) in cases {
            var profile = NotebookCaptureProfileDTO.localDefault(notebookId: "notebook-a")
            profile.remoteRealtimeEnabled = true
            profile.selectedLanguages = languages

            let normalized = NotebookCaptureProfileEditorModel.normalized(profile)

            XCTAssertEqual(normalized.selectedLanguages, languages)
            XCTAssertEqual(normalized.mode, expectedMode)
            XCTAssertNil(normalized.commonCaptionLanguage)
            XCTAssertEqual(normalized.languageA, languages[0])
        }

        var duplicateProfile = NotebookCaptureProfileDTO.localDefault(notebookId: "notebook-a")
        duplicateProfile.remoteRealtimeEnabled = true
        duplicateProfile.selectedLanguages = [" TH-th ", "", "th", "EN-us", "en"]
        let normalized = NotebookCaptureProfileEditorModel.normalized(duplicateProfile)
        XCTAssertEqual(normalized.selectedLanguages, ["th", "en"])
        XCTAssertEqual(normalized.mode, .twoWay)

        duplicateProfile.selectedLanguages = ["en", "zh", "th", "ja", "fr"]
        XCTAssertEqual(
            NotebookCaptureProfileEditorModel.normalized(duplicateProfile).selectedLanguages,
            ["en", "zh", "th"],
            "legacy profiles must preserve language order while adopting the three-language limit"
        )

        duplicateProfile.selectedLanguages = []
        XCTAssertEqual(
            NotebookCaptureProfileEditorModel.normalized(duplicateProfile).selectedLanguages,
            ["en"],
            "the editor must always retain at least one language"
        )

        duplicateProfile.selectedLanguages = ["en", "zh", "th"]
        duplicateProfile.commonCaptionLanguage = "th"
        XCTAssertNil(
            NotebookCaptureProfileEditorModel.normalized(duplicateProfile)
                .commonCaptionLanguage,
            "column order must not promote any language to a special translation target"
        )
    }

    @MainActor
    func testStoreDoesNotPromoteTheFirstSelectedLanguage() throws {
        let client = FakeNotebookCaptureClient(profile: .twoWay(notebookId: "notebook-a"))
        let store = ActiveBilingualTranscriptStore(
            client: client,
            audioSource: FakeNotebookCaptureAudioSource()
        )
        var candidate = client.profile
        candidate.remoteRealtimeEnabled = true
        candidate.mode = .multilingualOneWay
        candidate.selectedLanguages = ["en", "zh", "th"]
        candidate.commonCaptionLanguage = nil

        let saved = try store.saveProfile(candidate)

        XCTAssertEqual(saved.mode, .multilingualOneWay)
        XCTAssertEqual(saved.selectedLanguages, ["en", "zh", "th"])
        XCTAssertNil(saved.commonCaptionLanguage)
        XCTAssertEqual(saved.languageA, "en")
        XCTAssertEqual(saved.languageB, "zh")
    }

    @MainActor
    func testCaptureSettingsEditorNeverWritesRevisionZeroFallbackAfterLoadFailure() {
        let persistence = FakeNotebookCaptureProfilePersistence(
            profile: .twoWay(notebookId: "notebook-a")
        )
        persistence.loadError = TestCaptureSettingsError.readFailed
        let editor = NotebookCaptureProfileEditorModel(
            notebookId: "notebook-a",
            persistence: persistence
        )

        editor.load()
        editor.update { $0.remoteRealtimeEnabled = true }

        XCTAssertFalse(editor.canEdit)
        XCTAssertTrue(persistence.saveRequests.isEmpty)
        guard case .loadFailed = editor.persistenceState else {
            return XCTFail("read failure must remain visible and block autosave")
        }
    }

    @MainActor
    func testCaptureSettingsEditorRetriesLatestDraftWithoutStaleRevision() {
        var initial = NotebookCaptureProfileDTO.localDefault(notebookId: "notebook-a")
        initial.revision = 9
        let persistence = FakeNotebookCaptureProfilePersistence(profile: initial)
        let editor = NotebookCaptureProfileEditorModel(
            notebookId: "notebook-a",
            persistence: persistence
        )
        editor.load()
        persistence.saveError = TestCaptureSettingsError.writeFailed

        editor.update { $0.remoteRealtimeEnabled = true }
        guard case .saveFailed = editor.persistenceState else {
            return XCTFail("failed autosave must remain retryable")
        }

        persistence.saveError = nil
        editor.retry()

        XCTAssertEqual(persistence.saveRequests.map(\.revision), [9, 9])
        XCTAssertTrue(editor.draft.remoteRealtimeEnabled)
        XCTAssertEqual(editor.draft.revision, 10)
        XCTAssertEqual(editor.persistenceState, .saved)
    }

    @MainActor
    func testCaptureSettingsEditorDoesNotRetryAWriteDuringCapture() {
        var initial = NotebookCaptureProfileDTO.localDefault(notebookId: "notebook-a")
        initial.revision = 9
        let persistence = FakeNotebookCaptureProfilePersistence(profile: initial)
        let editor = NotebookCaptureProfileEditorModel(
            notebookId: "notebook-a",
            persistence: persistence
        )
        editor.load()
        XCTAssertNil(editor.captureStartDisabledReason)
        persistence.saveError = TestCaptureSettingsError.writeFailed
        editor.update { $0.remoteRealtimeEnabled = true }
        XCTAssertEqual(persistence.saveRequests.count, 1)

        persistence.saveError = nil
        persistence.isCaptureActive = true
        editor.retry()

        XCTAssertEqual(persistence.saveRequests.count, 1)
        XCTAssertNotNil(editor.captureStartDisabledReason)
        guard case .saveFailed = editor.persistenceState else {
            return XCTFail("recording must preserve the pending failure without retrying a write")
        }
    }

    @MainActor
    func testCaptureSettingsEditorDoesNotObserveRunSnapshotOrEditDuringCapture() {
        let persistence = FakeNotebookCaptureProfilePersistence(
            profile: .twoWay(notebookId: "notebook-a")
        )
        let editor = NotebookCaptureProfileEditorModel(
            notebookId: "notebook-a",
            persistence: persistence
        )
        editor.load()
        let loaded = editor.draft

        persistence.profile.languageA = "fr"
        persistence.profile.languageB = "de"
        persistence.isCaptureActive = true
        editor.update { $0.languageA = "ja" }

        XCTAssertEqual(editor.draft, loaded)
        XCTAssertTrue(persistence.saveRequests.isEmpty)
    }

    @MainActor
    func testPersistedContextProfileNeverRequiresPerLaunchReview() {
        var profile = NotebookCaptureProfileDTO.twoWay(notebookId: "notebook-a")
        profile.sendContextToSoniox = true
        let persistence = FakeNotebookCaptureProfilePersistence(profile: profile)
        let editor = NotebookCaptureProfileEditorModel(
            notebookId: "notebook-a",
            persistence: persistence
        )

        editor.load()
        XCTAssertEqual(editor.persistenceState, .saved)
        XCTAssertNil(editor.captureStartDisabledReason)

        editor.update {
            $0.languageA = "ja"
            $0.leftLanguage = "ja"
        }
        XCTAssertEqual(editor.persistenceState, .saved)
        XCTAssertNil(editor.captureStartDisabledReason)
    }

    @MainActor
    func testUnavailableProfileLoadKeepsRevisionZeroFallbackReadOnly() {
        let store = ActiveBilingualTranscriptStore(
            client: UnavailableNotebookCaptureClient(),
            audioSource: FakeNotebookCaptureAudioSource()
        )
        let editor = NotebookCaptureProfileEditorModel(
            notebookId: "notebook-a",
            persistence: store
        )

        editor.load()

        XCTAssertFalse(editor.canEdit)
        XCTAssertEqual(editor.draft.revision, 0)
        XCTAssertNotNil(editor.captureStartDisabledReason)
        guard case .loadFailed = editor.persistenceState else {
            return XCTFail("the real unavailable client must fail closed")
        }
    }

    @MainActor
    func testContextEgressCannotBeSavedWhileRemoteProcessingIsOff() {
        let store = ActiveBilingualTranscriptStore(
            client: FakeNotebookCaptureClient(profile: .localDefault(notebookId: "notebook-a")),
            audioSource: FakeNotebookCaptureAudioSource()
        )
        var profile = NotebookCaptureProfileDTO.localDefault(notebookId: "notebook-a")
        profile.sendContextToSoniox = true

        XCTAssertThrowsError(try store.saveProfile(profile)) { error in
            XCTAssertEqual(error as? NotebookCaptureClientError, .remoteRequiredForContext)
        }
    }

    @MainActor
    func testActiveCaptureRejectsProfileWritesAtTheStoreBoundary() async throws {
        let client = FakeNotebookCaptureClient(profile: .twoWay(notebookId: "notebook-a"))
        let store = ActiveBilingualTranscriptStore(
            client: client,
            audioSource: FakeNotebookCaptureAudioSource()
        )
        try await store.start(notebookId: "notebook-a")

        var candidate = client.profile
        candidate.languageA = "ja"
        candidate.leftLanguage = "ja"
        XCTAssertThrowsError(try store.saveProfile(candidate)) { error in
            XCTAssertEqual(error as? NotebookCaptureClientError, .captureAlreadyActive)
        }
        XCTAssertEqual(client.profileUpdateCount, 0)
        try await store.stop()
    }

    @MainActor
    func testActiveCaptureKeepsOneMicrophoneSubscriptionAndNotebookOwnership() async throws {
        let client = FakeNotebookCaptureClient(profile: .twoWay(notebookId: "notebook-a"))
        let audio = FakeNotebookCaptureAudioSource()
        let store = ActiveBilingualTranscriptStore(client: client, audioSource: audio)
        store.loadProfile(notebookId: "notebook-a")

        try await store.start(notebookId: "notebook-a")
        XCTAssertEqual(audio.subscribeCount, 1)
        XCTAssertTrue(store.hasAudioSubscription)
        XCTAssertEqual(store.notebookId, "notebook-a")
        XCTAssertEqual(store.sessionId, "session-a")

        audio.emit(Data([0x01, 0x02]))

        do {
            try await store.start(notebookId: "notebook-b")
            XCTFail("a second active capture must be rejected")
        } catch {
            XCTAssertEqual(error as? NotebookCaptureClientError, .captureAlreadyActive)
        }
        XCTAssertEqual(audio.subscribeCount, 1)
        XCTAssertEqual(store.notebookId, "notebook-a")

        store.loadUtterances(notebookId: "notebook-b", sessionId: "old-session-in-notebook-b")
        XCTAssertEqual(store.sessionId, "session-a", "view navigation must not reassign active capture")
        XCTAssertEqual(store.notebookId, "notebook-a")

        try await store.setPaused(true)
        XCTAssertEqual(client.audioPushCount, 1, "pause must drain accepted audio before finalization")
        XCTAssertEqual(audio.unsubscribeCount, 1, "pause must synchronously stop and drain the microphone")
        XCTAssertEqual(audio.subscribeCount, 1)
        XCTAssertFalse(store.hasAudioSubscription)
        XCTAssertEqual(store.captureState, .paused)

        audio.emit(Data([0x03, 0x04]))
        try await store.setPaused(false)
        XCTAssertEqual(client.audioPushCount, 1, "audio received while paused must stay local and be discarded")
        XCTAssertEqual(audio.subscribeCount, 2, "resume must install one fresh microphone generation")
        XCTAssertTrue(store.hasAudioSubscription)

        audio.emit(Data([0x05, 0x06]))

        try await store.stop()
        XCTAssertEqual(client.audioPushCount, 2, "stop must drain accepted audio before closing the run")
        XCTAssertEqual(audio.unsubscribeCount, 2)
        XCTAssertFalse(store.hasAudioSubscription)
        XCTAssertEqual(store.captureState, .completed)
    }

    @MainActor
    func testRecordingInputSwitchKeepsSessionAndPushesOldFramesBeforeNewDeviceFrames() async throws {
        let client = FakeNotebookCaptureClient(profile: .twoWay(notebookId: "notebook-a"))
        let audio = FakeNotebookCaptureAudioSource()
        let store = ActiveBilingualTranscriptStore(client: client, audioSource: audio)
        try await store.start(notebookId: "notebook-a")
        let originalSessionId = store.sessionId

        let oldDeviceTail = Data([0x0A])
        let newDeviceHead = Data([0x0B])
        audio.emitOnUnsubscribe = oldDeviceTail

        try await store.selectAudioInputDevice(uid: "mixer-b", notebookId: "notebook-a")
        audio.emit(newDeviceHead)
        let pushedBoth = await waitUntil { client.audioPushCount == 2 }

        XCTAssertTrue(pushedBoth)
        XCTAssertEqual(client.audioPushPayloads, [oldDeviceTail, newDeviceHead])
        XCTAssertEqual(store.sessionId, originalSessionId)
        XCTAssertEqual(store.captureState, .recording)
        XCTAssertTrue(store.hasAudioSubscription)
        XCTAssertEqual(audio.unsubscribeCount, 1)
        XCTAssertEqual(audio.subscribeCount, 2)
        XCTAssertEqual(audio.subscribedInputDeviceUIDs, ["test-default-input", "mixer-b"])
        XCTAssertEqual(audio.selectedInputDeviceUID, "mixer-b")
        XCTAssertEqual(audio.committedInputDeviceUIDs.count, 1)
        XCTAssertEqual(audio.committedInputDeviceUIDs[0], "mixer-b")
        XCTAssertEqual(client.startCount, 1)
        XCTAssertEqual(client.pauseCount, 0)
        XCTAssertEqual(client.stopCount, 0)
        XCTAssertEqual(client.interruptCount, 0)

        try await store.stop()
    }

    @MainActor
    func testSameInputUIDWithNewRuntimeDeviceIDRebindsTheMicrophone() async throws {
        let client = FakeNotebookCaptureClient(profile: .twoWay(notebookId: "notebook-a"))
        let audio = FakeNotebookCaptureAudioSource()
        let store = ActiveBilingualTranscriptStore(client: client, audioSource: audio)
        try await store.start(notebookId: "notebook-a")
        let firstDeviceID = try XCTUnwrap(audio.subscribedInputDeviceIDs.first)
        let replacementDeviceID = firstDeviceID &+ 1
        audio.resolvedDeviceIDs["test-default-input"] = replacementDeviceID

        try await store.selectAudioInputDevice(uid: nil, notebookId: "notebook-a")

        XCTAssertEqual(audio.unsubscribeCount, 1)
        XCTAssertEqual(audio.subscribeCount, 2)
        XCTAssertEqual(audio.subscribedInputDeviceIDs.last, replacementDeviceID)
        XCTAssertEqual(store.captureState, .recording)

        try await store.stop()
    }

    @MainActor
    func testFailedInputSwitchRollsBackOldDeviceWithoutStoppingCapture() async throws {
        let client = FakeNotebookCaptureClient(profile: .twoWay(notebookId: "notebook-a"))
        let audio = FakeNotebookCaptureAudioSource()
        let store = ActiveBilingualTranscriptStore(client: client, audioSource: audio)
        try await store.start(notebookId: "notebook-a")
        audio.failNextSubscribeCount = 1

        do {
            try await store.selectAudioInputDevice(uid: "mixer-b", notebookId: "notebook-a")
            XCTFail("a failed target device must be reported")
        } catch {
            XCTAssertTrue(error is CaptureError)
        }

        XCTAssertEqual(store.captureState, .recording)
        XCTAssertTrue(store.hasAudioSubscription)
        XCTAssertNil(audio.selectedInputDeviceUID)
        XCTAssertEqual(
            audio.subscribedInputDeviceUIDs,
            ["test-default-input", "mixer-b", "test-default-input"]
        )
        XCTAssertEqual(client.interruptCount, 0)

        try await store.stop()
    }

    @MainActor
    func testFailedSwitchFromSystemDefaultRestoresActualPreviousDeviceBeforeLatestDefault() async throws {
        let client = FakeNotebookCaptureClient(profile: .twoWay(notebookId: "notebook-a"))
        let audio = FakeNotebookCaptureAudioSource()
        let store = ActiveBilingualTranscriptStore(client: client, audioSource: audio)
        try await store.start(notebookId: "notebook-a")
        audio.defaultInputDeviceUID = "replacement-system-default"
        audio.failNextSubscribeCount = 1

        do {
            try await store.selectAudioInputDevice(uid: "mixer-b", notebookId: "notebook-a")
            XCTFail("a failed target device must be reported")
        } catch {
            XCTAssertTrue(error is CaptureError)
        }

        XCTAssertEqual(
            audio.subscribedInputDeviceUIDs,
            ["test-default-input", "mixer-b", "test-default-input"]
        )
        XCTAssertEqual(store.activeAudioInputDevice?.uid, "test-default-input")
        XCTAssertNil(audio.selectedInputDeviceUID)
        XCTAssertEqual(store.captureState, .recording)
        XCTAssertTrue(store.hasAudioSubscription)
        XCTAssertEqual(client.interruptCount, 0)

        try await store.stop()
    }

    @MainActor
    func testInputSwitchInterruptsOnceWhenTargetAndRollbackBothFail() async throws {
        let client = FakeNotebookCaptureClient(profile: .twoWay(notebookId: "notebook-a"))
        let audio = FakeNotebookCaptureAudioSource()
        let store = ActiveBilingualTranscriptStore(client: client, audioSource: audio)
        try await store.start(notebookId: "notebook-a")
        audio.failNextSubscribeCount = 2

        do {
            try await store.selectAudioInputDevice(uid: "mixer-b", notebookId: "notebook-a")
            XCTFail("two failed device starts must interrupt the capture")
        } catch {
            XCTAssertTrue(error is CaptureError)
        }

        XCTAssertEqual(client.interruptCount, 1)
        XCTAssertEqual(client.lastInterruptReason, .localAudioUnavailable)
        XCTAssertFalse(store.hasAudioSubscription)
        XCTAssertFalse(store.isCaptureActive)
        XCTAssertNil(audio.selectedInputDeviceUID)
    }

    @MainActor
    func testPausedInputSelectionAppliesOnlyWhenCaptureResumes() async throws {
        let client = FakeNotebookCaptureClient(profile: .twoWay(notebookId: "notebook-a"))
        let audio = FakeNotebookCaptureAudioSource()
        let store = ActiveBilingualTranscriptStore(client: client, audioSource: audio)
        try await store.start(notebookId: "notebook-a")
        try await store.setPaused(true)

        try await store.selectAudioInputDevice(uid: "mixer-b", notebookId: "notebook-a")

        XCTAssertEqual(store.captureState, .paused)
        XCTAssertEqual(audio.subscribeCount, 1)
        XCTAssertEqual(audio.selectedInputDeviceUID, "mixer-b")
        XCTAssertEqual(store.activeAudioInputDevice?.uid, "mixer-b")

        try await store.setPaused(false)
        XCTAssertEqual(audio.subscribeCount, 2)
        XCTAssertEqual(audio.subscribedInputDeviceUIDs.last, "mixer-b")
        XCTAssertEqual(store.captureState, .recording)

        try await store.stop()
    }

    @MainActor
    func testActiveSessionRowsAreHiddenFromAnotherSessionView() async throws {
        let client = FakeNotebookCaptureClient(
            profile: .twoWay(notebookId: "notebook-a"),
            startUtterances: [.sample]
        )
        let store = ActiveBilingualTranscriptStore(
            client: client,
            audioSource: FakeNotebookCaptureAudioSource()
        )
        try await store.start(notebookId: "notebook-a")

        let visibleInB = NotebookTranscriptSessionIsolation.visibleUtterances(
            requestedSessionId: "session-b",
            storeSessionId: store.sessionId,
            isCaptureActive: store.isCaptureActive,
            utterances: store.utterances
        )

        XCTAssertTrue(visibleInB.isEmpty, "Notebook B must never render Notebook A's live rows")
        XCTAssertTrue(NotebookTranscriptSessionIsolation.isActiveElsewhere(
            requestedSessionId: "session-b",
            storeSessionId: store.sessionId,
            isCaptureActive: store.isCaptureActive
        ))
        store.loadUtterances(notebookId: "notebook-b", sessionId: "session-b")
        XCTAssertEqual(store.sessionId, "session-a", "viewing B must not replace A's capture owner")
        XCTAssertEqual(store.utterances.map(\.sourceText), ["Hello"])
    }

    @MainActor
    func testSequentialCaptureDeltasUpsertBySessionAndSequenceWithoutFullReload() async throws {
        let client = FakeNotebookCaptureClient(profile: .twoWay(notebookId: "notebook-a"))
        let store = ActiveBilingualTranscriptStore(
            client: client,
            audioSource: FakeNotebookCaptureAudioSource()
        )
        try await store.start(notebookId: "notebook-a")

        var first = NotebookCaptureUtteranceDTO.sample
        first.revision = 1
        first.sourceText = "First revision"
        client.emitCaptureEvent(captureEvent(
            sessionId: "session-a",
            state: .recording,
            utterances: [first],
            eventRevision: 1,
            isFullSnapshot: false
        ))

        var replacement = first.replacingIdentity(id: "provider-reissued-id")
        replacement.revision = 2
        replacement.sourceText = "Second revision"
        client.emitCaptureEvent(captureEvent(
            sessionId: "session-a",
            state: .recording,
            utterances: [replacement],
            eventRevision: 2,
            isFullSnapshot: false
        ))

        XCTAssertEqual(client.listUtterancesCount, 0)
        XCTAssertEqual(store.utterances.count, 1)
        XCTAssertEqual(store.utterances.first?.id, "provider-reissued-id")
        XCTAssertEqual(store.utterances.first?.sourceText, "Second revision")
        store.resetForTesting()
    }

    @MainActor
    func testOutOfOrderCaptureDeltaKeepsSequenceOrderAndRevisionWinnerSemantics() async throws {
        let client = FakeNotebookCaptureClient(profile: .twoWay(notebookId: "notebook-a"))
        let store = ActiveBilingualTranscriptStore(
            client: client,
            audioSource: FakeNotebookCaptureAudioSource()
        )
        try await store.start(notebookId: "notebook-a")

        var zero = NotebookCaptureUtteranceDTO.sample.replacingIdentity(
            id: "utt-0",
            sequence: 0
        )
        zero.revision = 2
        zero.sourceText = "zero-original"
        var two = NotebookCaptureUtteranceDTO.sample.replacingIdentity(
            id: "utt-2",
            sequence: 2
        )
        two.revision = 3
        two.sourceText = "two-newest"
        client.emitCaptureEvent(captureEvent(
            sessionId: "session-a",
            state: .recording,
            utterances: [two, zero],
            eventRevision: 1,
            isFullSnapshot: true
        ))

        var three = NotebookCaptureUtteranceDTO.sample.replacingIdentity(
            id: "utt-3",
            sequence: 3
        )
        three.revision = 1
        three.sourceText = "three"
        var one = NotebookCaptureUtteranceDTO.sample.replacingIdentity(
            id: "utt-1",
            sequence: 1
        )
        one.revision = 1
        one.sourceText = "one"
        var staleTwo = two
        staleTwo.revision = 2
        staleTwo.sourceText = "two-stale"
        var equalZero = zero.replacingIdentity(id: "utt-0-equal")
        equalZero.sourceText = "zero-equal-later"
        var foreign = three.replacingIdentity(
            id: "utt-foreign",
            sessionId: "session-b",
            sequence: 4
        )
        foreign.sourceText = "must stay hidden"

        var publishedSnapshots: [[UInt64]] = []
        let observation = store.$utterances.dropFirst().sink { utterances in
            publishedSnapshots.append(utterances.map(\.sequence))
        }
        client.emitCaptureEvent(captureEvent(
            sessionId: "session-a",
            state: .recording,
            utterances: [three, one, staleTwo, equalZero, foreign],
            eventRevision: 2,
            isFullSnapshot: false
        ))

        XCTAssertEqual(store.utterances.map(\.sequence), [0, 1, 2, 3])
        XCTAssertEqual(
            store.utterances.map(\.sourceText),
            ["zero-equal-later", "one", "two-newest", "three"]
        )
        XCTAssertEqual(store.utterances.first?.id, "utt-0-equal")
        XCTAssertEqual(
            publishedSnapshots,
            [[0, 1, 2, 3]],
            "one durable delta must publish only its fully merged ordered value"
        )
        withExtendedLifetime(observation) {}
        store.resetForTesting()
    }

    @MainActor
    func testFullSnapshotIsSortedDeduplicatedAndPublishedAtomically() async throws {
        let client = FakeNotebookCaptureClient(profile: .twoWay(notebookId: "notebook-a"))
        let store = ActiveBilingualTranscriptStore(
            client: client,
            audioSource: FakeNotebookCaptureAudioSource()
        )
        try await store.start(notebookId: "notebook-a")

        var deleted = NotebookCaptureUtteranceDTO.sample.replacingIdentity(
            id: "utt-deleted",
            sequence: 9
        )
        deleted.sourceText = "must disappear"
        client.emitCaptureEvent(captureEvent(
            sessionId: "session-a",
            state: .recording,
            utterances: [deleted],
            eventRevision: 1,
            isFullSnapshot: false
        ))

        var zero = NotebookCaptureUtteranceDTO.sample.replacingIdentity(
            id: "utt-0",
            sequence: 0
        )
        zero.revision = 1
        zero.sourceText = "zero"
        var oneFirst = NotebookCaptureUtteranceDTO.sample.replacingIdentity(
            id: "utt-1-first",
            sequence: 1
        )
        oneFirst.revision = 2
        oneFirst.sourceText = "one-first"
        var oneEqualLater = oneFirst.replacingIdentity(id: "utt-1-later")
        oneEqualLater.sourceText = "one-equal-later"
        var twoNewest = NotebookCaptureUtteranceDTO.sample.replacingIdentity(
            id: "utt-2-newest",
            sequence: 2
        )
        twoNewest.revision = 3
        twoNewest.sourceText = "two-newest"
        var twoStale = twoNewest.replacingIdentity(id: "utt-2-stale")
        twoStale.revision = 2
        twoStale.sourceText = "two-stale-later"

        var publishedSnapshots: [[UInt64]] = []
        let observation = store.$utterances.dropFirst().sink { utterances in
            publishedSnapshots.append(utterances.map(\.sequence))
        }
        client.emitCaptureEvent(captureEvent(
            sessionId: "session-a",
            state: .recording,
            utterances: [twoNewest, oneFirst, zero, twoStale, oneEqualLater],
            eventRevision: 2,
            isFullSnapshot: true
        ))

        XCTAssertEqual(store.utterances.map(\.sequence), [0, 1, 2])
        XCTAssertEqual(
            store.utterances.map(\.sourceText),
            ["zero", "one-equal-later", "two-newest"]
        )
        XCTAssertEqual(
            publishedSnapshots,
            [[0, 1, 2]],
            "an authoritative replacement must not expose an empty or partially rebuilt transcript"
        )
        withExtendedLifetime(observation) {}
        store.resetForTesting()
    }

    @MainActor
    func testEmptyDeltaStillWakesPendingFinalProjectionFromDurableLocalRows() async throws {
        let client = FakeNotebookCaptureClient(profile: .twoWay(notebookId: "notebook-a"))
        let store = ActiveBilingualTranscriptStore(
            client: client,
            audioSource: FakeNotebookCaptureAudioSource()
        )
        try await store.start(notebookId: "notebook-a")

        client.emitCaptureEvent(captureEvent(
            sessionId: "session-a",
            state: .recording,
            utterances: [.sample],
            eventRevision: 1,
            isFullSnapshot: false
        ))
        XCTAssertEqual(client.realtimeProjectionCount, 1)

        client.emitCaptureEvent(captureEvent(
            sessionId: "session-a",
            state: .recording,
            utterances: [],
            eventRevision: 2,
            isFullSnapshot: false
        ))

        XCTAssertEqual(
            client.realtimeProjectionCount,
            2,
            "a coalesced empty callback must still retry the durable Final watermark"
        )
        store.resetForTesting()
    }

    @MainActor
    func testAppliedProjectionWatermarkStopsProgressCallbacksFromRewakingFinal() async throws {
        let client = FakeNotebookCaptureClient(profile: .twoWay(notebookId: "notebook-a"))
        let store = ActiveBilingualTranscriptStore(
            client: client,
            audioSource: FakeNotebookCaptureAudioSource()
        )
        try await store.start(notebookId: "notebook-a")

        client.emitCaptureEvent(captureEvent(
            sessionId: "session-a",
            state: .recording,
            utterances: [.sample],
            eventRevision: 1,
            isFullSnapshot: false,
            realtimeLoroAppliedRevision: 0
        ))
        XCTAssertEqual(client.realtimeProjectionCount, 1)

        // The first empty callback carries Rust's durable ACK. Every later
        // progress/health-only callback must remain a projector no-op even
        // though the same historical Final stays in the local transcript.
        for eventRevision in 2...101 {
            client.emitCaptureEvent(captureEvent(
                sessionId: "session-a",
                state: .recording,
                utterances: [],
                eventRevision: UInt64(eventRevision),
                isFullSnapshot: false,
                realtimeLoroAppliedRevision: 1
            ))
        }
        XCTAssertEqual(
            client.realtimeProjectionCount,
            1,
            "an acknowledged Final must not wake projection on every progress callback"
        )

        var laterTranslationFinal = NotebookCaptureUtteranceDTO.sample
            .replacingIdentity(id: "utt-2", sequence: 2)
        laterTranslationFinal.revision = 8
        laterTranslationFinal.completion = "partial"
        laterTranslationFinal.sourceProjectionRevision = 0
        laterTranslationFinal.languageVariants = [
            NotebookCaptureLanguageVariantDTO(
                language: "th",
                role: "translation",
                text: "สวัสดี",
                state: "ready",
                completion: "complete",
                projectionRevision: 2
            ),
        ]
        client.emitCaptureEvent(captureEvent(
            sessionId: "session-a",
            state: .recording,
            utterances: [laterTranslationFinal],
            eventRevision: 102,
            isFullSnapshot: false,
            realtimeLoroAppliedRevision: 1
        ))
        XCTAssertEqual(
            client.realtimeProjectionCount,
            2,
            "a newer independent Final lane must still wake projection exactly once"
        )
        store.resetForTesting()
    }

    @MainActor
    func testTranslationFinalWakesProjectionWhileSourceRemainsPartial() async throws {
        let client = FakeNotebookCaptureClient(profile: .twoWay(notebookId: "notebook-a"))
        let store = ActiveBilingualTranscriptStore(
            client: client,
            audioSource: FakeNotebookCaptureAudioSource()
        )
        try await store.start(notebookId: "notebook-a")

        var translationFirst = NotebookCaptureUtteranceDTO.sample
        translationFirst.completion = "partial"
        translationFirst.languageVariants = [
            NotebookCaptureLanguageVariantDTO(
                language: "zh",
                role: "translation",
                text: "你好",
                state: "ready",
                completion: "complete",
                projectionRevision: 1
            ),
        ]
        client.emitCaptureEvent(captureEvent(
            sessionId: "session-a",
            state: .recording,
            utterances: [translationFirst],
            eventRevision: 1,
            isFullSnapshot: false
        ))

        XCTAssertTrue(translationFirst.isFinalLane(language: "zh"))
        XCTAssertFalse(translationFirst.isFinalLane(language: "en"))
        XCTAssertEqual(client.realtimeProjectionCount, 1)
        store.resetForTesting()
    }

    func testLaneEditabilityUsesIndependentDurableProjectionWatermarks() {
        var utterance = NotebookCaptureUtteranceDTO.sample
        utterance.completion = "partial"
        utterance.sourceProjectionRevision = 0
        utterance.languageVariants = [
            NotebookCaptureLanguageVariantDTO(
                language: "zh-Hans",
                role: "translation",
                text: "你好",
                state: "ready",
                completion: "complete",
                projectionRevision: 1
            ),
            NotebookCaptureLanguageVariantDTO(
                language: "th",
                role: "translation",
                text: "สวัสดี",
                state: "ready",
                completion: "complete",
                projectionRevision: 2
            ),
        ]

        XCTAssertTrue(utterance.isLoroEditableLane(language: "ZH-cn", appliedRevision: 1))
        XCTAssertFalse(
            utterance.isLoroEditableLane(language: "th", appliedRevision: 1),
            "a later Final lane must remain locked without relocking an earlier durable lane"
        )
        XCTAssertFalse(utterance.isLoroEditableLane(language: "en", appliedRevision: 1))
        XCTAssertTrue(utterance.isLoroEditableLane(language: "th", appliedRevision: 2))

        utterance.completion = "complete"
        utterance.sourceProjectionRevision = 3
        utterance.languageVariants.append(NotebookCaptureLanguageVariantDTO(
            language: "en",
            role: "source",
            text: "hello",
            state: "ready",
            completion: "complete",
            projectionRevision: 3
        ))
        XCTAssertFalse(utterance.isLoroEditableLane(language: "en-US", appliedRevision: 2))
        XCTAssertTrue(utterance.isLoroEditableLane(language: "en-US", appliedRevision: 3))
    }

    func testTranslationCanReuseTheWithdrawnAggregateSourceLanguage() {
        var utterance = NotebookCaptureUtteranceDTO.sample
        utterance.sourceLanguage = "en"
        utterance.sourceText = ""
        utterance.completion = "partial"
        utterance.sourceProjectionRevision = 0
        utterance.sourceEditRevision = 9
        utterance.languageVariants = [
            NotebookCaptureLanguageVariantDTO(
                language: "en",
                role: "translation",
                text: "independent lane",
                state: "ready",
                completion: "complete",
                projectionRevision: 2,
                editRevision: 3
            ),
        ]

        XCTAssertFalse(utterance.hasSourceLane)
        XCTAssertTrue(utterance.isFinalLane(language: "en"))
        XCTAssertTrue(utterance.isLoroEditableLane(language: "en", appliedRevision: 2))
        XCTAssertEqual(utterance.laneText(language: "en"), "independent lane")
        XCTAssertEqual(utterance.laneEditRevision(language: "en"), 3)
        let projection = NotebookCaptureHistoryPolicy.laneProjection(
            for: utterance,
            selectedLanguages: ["en", "zh"],
            commonCaptionLanguage: nil
        )
        XCTAssertEqual(projection.lanes.first?.text, "independent lane")
    }

    func testLanguageColumnsSupplementLatestCueUntilDurableLaneCatchesUp() throws {
        var utterance = NotebookCaptureUtteranceDTO.sample
        utterance.sourceLanguage = "zh"
        utterance.sourceText = "最新中文"
        utterance.languageVariants = [
            NotebookCaptureLanguageVariantDTO(
                language: "en",
                role: "translation",
                text: "It.",
                state: "ready",
                completion: "complete"
            ),
        ]
        let staleCue = NotebookCaptureTranslationCueDTO(
            targetLanguage: "en",
            groupEpoch: 0,
            providerSequence: 1,
            sourceLanguage: "zh",
            sourceStartMs: 1_000,
            sourceEndMs: 1_500,
            text: "Older English",
            completion: "complete",
            withdrawn: false,
            revision: 1
        )
        let latestCue = NotebookCaptureTranslationCueDTO(
            targetLanguage: "en-US",
            groupEpoch: 0,
            providerSequence: 2,
            sourceLanguage: "zh-CN",
            sourceStartMs: 1_500,
            sourceEndMs: 3_000,
            text: "The complete latest English sentence.",
            completion: "partial",
            withdrawn: false,
            revision: 3
        )

        var supplemental = NotebookLanguageColumnCueOverlay.latestSupplementalCues(
            languages: ["zh", "en", "th"],
            utterances: [utterance],
            cues: [latestCue, staleCue]
        )
        XCTAssertEqual(supplemental["en"]?.id, latestCue.id)
        XCTAssertNil(supplemental["zh"], "a source-language echo is never a supplemental cue")
        XCTAssertNil(supplemental["th"])

        utterance.languageVariants[0].text = "The complete latest English sentence."
        supplemental = NotebookLanguageColumnCueOverlay.latestSupplementalCues(
            languages: ["zh", "en", "th"],
            utterances: [utterance],
            cues: [latestCue, staleCue]
        )
        XCTAssertNil(
            supplemental["en"],
            "the temporary live tail disappears when the durable lane contains the cue"
        )
    }

    @MainActor
    func testMenuBarRecentLineLabelsTranslationOnlyShellFromVisibleLane() async throws {
        MenuBarRuntimeStore.shared.resetForTesting()
        defer { MenuBarRuntimeStore.shared.resetForTesting() }

        let client = FakeNotebookCaptureClient(
            profile: .twoWay(notebookId: "notebook-a")
        )
        let store = ActiveBilingualTranscriptStore(
            client: client,
            audioSource: FakeNotebookCaptureAudioSource()
        )
        try await store.start(notebookId: "notebook-a")

        var shell = NotebookCaptureUtteranceDTO.sample
        shell.sourceText = ""
        shell.sourceStartMs = nil
        shell.sourceEndMs = nil
        shell.completion = "partial"
        shell.sourceProjectionRevision = 0
        shell.languageVariants = [
            NotebookCaptureLanguageVariantDTO(
                language: "zh",
                role: "translation",
                text: "只剩翻译",
                state: "ready",
                completion: "complete",
                projectionRevision: 1
            ),
        ]
        client.emitCaptureEvent(captureEvent(
            sessionId: "session-a",
            state: .recording,
            utterances: [shell],
            eventRevision: 1,
            isFullSnapshot: false
        ))

        let recent = try XCTUnwrap(MenuBarRuntimeStore.shared.cachedRecentLines.first)
        XCTAssertEqual(recent.text, "只剩翻译")
        XCTAssertEqual(recent.languageLabel, "中")
        XCTAssertEqual(recent.timestamp, "")
        store.resetForTesting()
    }

    func testRealtimeProjectionSchedulerReturnsImmediatelyAndCoalescesBackpressure() {
        let scheduler = NotebookRealtimeProjectionScheduler()
        let firstStarted = expectation(description: "first projection started")
        let completed = expectation(description: "coalesced projections completed")
        completed.expectedFulfillmentCount = 2
        let releaseFirst = DispatchSemaphore(value: 0)
        let recorder = FakeAudioPushRecorder()
        let projection: NotebookRealtimeProjectionScheduler.Projection = { _ in
            recorder.record()
            if recorder.value == 1 {
                firstStarted.fulfill()
                releaseFirst.wait()
            }
            completed.fulfill()
        }

        scheduler.schedule(sessionId: "session-a", projection: projection)
        wait(for: [firstStarted], timeout: 1)
        for _ in 0..<20 {
            scheduler.schedule(sessionId: "session-a", projection: projection)
        }
        releaseFirst.signal()
        wait(for: [completed], timeout: 1)

        XCTAssertEqual(
            recorder.value,
            2,
            "one in-flight projection plus one coalesced retry should absorb callback bursts"
        )
    }

    func testRealtimeProjectionSchedulerRetriesTransientFailureWithoutAnotherWake() {
        let scheduler = NotebookRealtimeProjectionScheduler(
            maximumFastRetries: 3,
            initialFastRetryDelay: 0.001,
            cappedRetryDelay: 0.02
        )
        let converged = expectation(description: "projection converged")
        let attempts = FakeAudioPushRecorder()

        scheduler.schedule(sessionId: "session-a") { _ in
            attempts.record()
            if attempts.value < 3 {
                throw NotebookCaptureClientError.ffiUnavailable
            }
            converged.fulfill()
        }

        wait(for: [converged], timeout: 1)
        XCTAssertEqual(
            attempts.value,
            3,
            "one Final wake must survive two transient projection failures"
        )
    }

    func testRealtimeProjectionSchedulerKeepsQuietWakeUntilSlowRetrySucceeds() {
        let scheduler = NotebookRealtimeProjectionScheduler(
            maximumFastRetries: 3,
            initialFastRetryDelay: 0.001,
            cappedRetryDelay: 0.02
        )
        let converged = expectation(description: "slow retry converged")
        let attempts = FakeAudioPushRecorder()

        scheduler.schedule(sessionId: "session-a") { _ in
            attempts.record()
            if attempts.value <= 4 {
                throw NotebookCaptureClientError.ffiUnavailable
            }
            converged.fulfill()
        }

        wait(for: [converged], timeout: 1)
        XCTAssertEqual(
            attempts.value,
            5,
            "the fourth failure must retain the wake for a capped slow retry"
        )
    }

    func testRealtimeProjectionSchedulerCancelStopsPermanentRetry() {
        let scheduler = NotebookRealtimeProjectionScheduler(
            maximumFastRetries: 0,
            initialFastRetryDelay: 0,
            cappedRetryDelay: 0.05
        )
        let firstAttempt = expectation(description: "first projection attempted")
        let unexpectedRetry = expectation(description: "retry after cancellation")
        unexpectedRetry.isInverted = true
        let attempts = FakeAudioPushRecorder()
        let releaseFirstAttempt = DispatchSemaphore(value: 0)

        scheduler.schedule(sessionId: "session-a") { _ in
            attempts.record()
            if attempts.value == 1 {
                firstAttempt.fulfill()
                releaseFirstAttempt.wait()
            } else {
                unexpectedRetry.fulfill()
            }
            throw NotebookCaptureClientError.ffiUnavailable
        }

        wait(for: [firstAttempt], timeout: 1)
        scheduler.cancel(sessionId: "session-a")
        releaseFirstAttempt.signal()
        wait(for: [unexpectedRetry], timeout: 0.1)
        XCTAssertEqual(attempts.value, 1)
    }

    func testRealtimeProjectionSchedulerOldFinishCannotDuplicateRescheduledGeneration() {
        let scheduler = NotebookRealtimeProjectionScheduler(
            maximumFastRetries: 0,
            initialFastRetryDelay: 0,
            cappedRetryDelay: 10
        )
        let oldGenerationStarted = expectation(description: "old generation started")
        let releaseOldGeneration = DispatchSemaphore(value: 0)

        scheduler.schedule(sessionId: "session-a") { _ in
            oldGenerationStarted.fulfill()
            releaseOldGeneration.wait()
            throw NotebookCaptureClientError.ffiUnavailable
        }
        wait(for: [oldGenerationStarted], timeout: 1)

        scheduler.cancel(sessionId: "session-a")
        let newGenerationAttempted = expectation(description: "new generation attempted")
        let newGenerationAttempts = FakeAudioPushRecorder()
        scheduler.schedule(sessionId: "session-a") { _ in
            newGenerationAttempts.record()
            if newGenerationAttempts.value == 1 {
                newGenerationAttempted.fulfill()
            }
            throw NotebookCaptureClientError.ffiUnavailable
        }

        releaseOldGeneration.signal()
        wait(for: [newGenerationAttempted], timeout: 1)

        // Both sessions share one serial projection queue. Any duplicate G2
        // work item created by G1's stale finish is already ahead of this
        // probe, while G2's legitimate retry remains delayed by ten seconds.
        // Draining to the probe therefore proves the count without a timing
        // window or an inverted expectation.
        let queueDrained = expectation(description: "projection queue drained")
        scheduler.schedule(sessionId: "session-b") { _ in
            queueDrained.fulfill()
        }
        wait(for: [queueDrained], timeout: 1)

        scheduler.cancel(sessionId: "session-a")
        XCTAssertEqual(newGenerationAttempts.value, 1)
    }

    @MainActor
    func testLivePreviewReplacesInPlaceWithoutEnteringDurableUtterances() async throws {
        let client = FakeNotebookCaptureClient(profile: .twoWay(notebookId: "notebook-a"))
        // Preview coalescing is a rendering budget; this test asserts what the
        // transcript contains, so it publishes every revision synchronously.
        let store = ActiveBilingualTranscriptStore(
            client: client,
            audioSource: FakeNotebookCaptureAudioSource(),
            livePreviewCoalescingInterval: 0
        )
        try await store.start(notebookId: "notebook-a")

        var preview = NotebookCaptureUtteranceDTO.sample
        preview.revision = 0
        preview.sourceLanguage = "und"
        preview.sourceText = "hel"
        preview.translatedLanguage = nil
        preview.translatedText = nil
        preview.completion = "partial"
        preview.alignment = "source_only"
        client.emitLivePreview(NotebookCaptureLivePreviewDTO(
            sessionId: "session-a",
            previewRevision: 1,
            utterances: [preview]
        ))

        XCTAssertTrue(store.utterances.isEmpty)
        XCTAssertEqual(store.presentedUtterances.map(\.sourceText), ["hel"])
        XCTAssertEqual(client.listUtterancesCount, 0)

        preview.sourceText = "hello"
        client.emitLivePreview(NotebookCaptureLivePreviewDTO(
            sessionId: "session-a",
            previewRevision: 3,
            utterances: [preview]
        ))
        XCTAssertEqual(store.presentedUtterances.map(\.sourceText), ["hello"])
        XCTAssertEqual(client.listUtterancesCount, 0, "preview gaps never rebuild durable rows")

        preview.sourceText = "stale"
        client.emitLivePreview(NotebookCaptureLivePreviewDTO(
            sessionId: "session-a",
            previewRevision: 2,
            utterances: [preview]
        ))
        XCTAssertEqual(store.presentedUtterances.map(\.sourceText), ["hello"])

        var durable = NotebookCaptureUtteranceDTO.sample
        durable.sourceText = "Hello."
        client.emitCaptureEvent(captureEvent(
            sessionId: "session-a",
            state: .recording,
            utterances: [durable],
            eventRevision: 1,
            isFullSnapshot: false
        ))

        XCTAssertEqual(store.utterances.map(\.sourceText), ["Hello."])
        XCTAssertEqual(store.presentedUtterances.map(\.sourceText), ["Hello."])
        client.emitLivePreview(NotebookCaptureLivePreviewDTO(
            sessionId: "session-a",
            previewRevision: 4,
            utterances: []
        ))
        XCTAssertEqual(store.presentedUtterances.map(\.sourceText), ["Hello."])
        store.resetForTesting()
    }

    /// A revision that reverts to the currently published text must still
    /// displace a newer revision waiting inside the coalescing window.
    /// Comparing an arriving revision against the published text alone would
    /// treat the revert as a no-op and leave the superseded revision queued,
    /// so the window would close by publishing text the provider had already
    /// taken back.
    @MainActor
    func testLivePreviewRevertDisplacesTheRevisionHeldInsideTheWindow() async throws {
        let client = FakeNotebookCaptureClient(profile: .twoWay(notebookId: "notebook-a"))
        let store = ActiveBilingualTranscriptStore(
            client: client,
            audioSource: FakeNotebookCaptureAudioSource(),
            livePreviewCoalescingInterval: 0.1
        )
        try await store.start(notebookId: "notebook-a")

        var preview = NotebookCaptureUtteranceDTO.sample
        preview.revision = 0
        preview.sourceLanguage = "und"
        preview.translatedLanguage = nil
        preview.translatedText = nil
        preview.completion = "partial"
        preview.alignment = "source_only"

        func emit(_ text: String, revision: UInt64) {
            preview.sourceText = text
            client.emitLivePreview(NotebookCaptureLivePreviewDTO(
                sessionId: "session-a",
                previewRevision: revision,
                utterances: [preview]
            ))
        }

        // Opens the window on the leading edge.
        emit("recognised", revision: 1)
        XCTAssertEqual(store.presentedUtterances.map(\.sourceText), ["recognised"])

        // Held: the window is still open.
        emit("recognised the", revision: 2)
        XCTAssertEqual(
            store.presentedUtterances.map(\.sourceText),
            ["recognised"],
            "a revision inside the window must not publish yet"
        )

        // The provider retracts the trailing word, landing back on the text
        // that is already on screen.
        emit("recognised", revision: 3)

        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(
            store.presentedUtterances.map(\.sourceText),
            ["recognised"],
            "the window must close on the retraction, not on the text it replaced"
        )
        store.resetForTesting()
    }

    @MainActor
    func testLongContinuousPreviewBurstPublishesNewestTailAfterCoalescingBudget() async throws {
        let client = FakeNotebookCaptureClient(profile: .twoWay(notebookId: "notebook-a"))
        let store = ActiveBilingualTranscriptStore(
            client: client,
            audioSource: FakeNotebookCaptureAudioSource(),
            elapsedTimerInterval: 10,
            livePreviewCoalescingInterval: 0.05
        )
        try await store.start(notebookId: "notebook-a")

        var parentObjectChangeCount = 0
        let parentObservation = store.objectWillChange.sink {
            parentObjectChangeCount += 1
        }

        var preview = NotebookCaptureUtteranceDTO.sample
        preview.revision = 0
        preview.sourceLanguage = "und"
        preview.translatedLanguage = nil
        preview.translatedText = nil
        preview.completion = "partial"
        preview.alignment = "source_only"

        for revision in 1...750 {
            let suffix = revision == 750 ? "[FINAL-TAIL]" : ""
            preview.sourceText = "continuous partial \(revision)\(suffix)"
            client.emitLivePreview(NotebookCaptureLivePreviewDTO(
                sessionId: "session-a",
                previewRevision: UInt64(revision),
                utterances: [preview]
            ))
        }

        let didPublishTail = await waitUntil {
            store.presentedUtterances.last?.sourceText.hasSuffix("[FINAL-TAIL]") == true
        }
        XCTAssertTrue(
            didPublishTail,
            "the display budget may drop intermediate frames but must publish the newest tail"
        )
        XCTAssertEqual(store.captureState, .recording)
        XCTAssertEqual(client.listUtterancesCount, 0)
        XCTAssertEqual(
            parentObjectChangeCount,
            0,
            "speculative words must not invalidate capture controls and settings"
        )
        withExtendedLifetime(parentObservation) {}
        store.resetForTesting()
    }

    @MainActor
    func testLivePreviewPublishesCoherentFramesOnceIncludingEmptyCueAuthority() async throws {
        let client = FakeNotebookCaptureClient(profile: .twoWay(notebookId: "notebook-a"))
        let store = ActiveBilingualTranscriptStore(
            client: client,
            audioSource: FakeNotebookCaptureAudioSource(),
            livePreviewCoalescingInterval: 0
        )
        try await store.start(notebookId: "notebook-a")

        let durableCue = NotebookCaptureTranslationCueDTO(
            targetLanguage: "zh",
            groupEpoch: 0,
            providerSequence: 1,
            sourceLanguage: "en",
            sourceStartMs: 0,
            sourceEndMs: 500,
            text: "durable cue",
            completion: "partial",
            withdrawn: false,
            revision: 1
        )
        client.emitCaptureEvent(captureEvent(
            sessionId: "session-a",
            state: .recording,
            utterances: [],
            eventRevision: 1,
            isFullSnapshot: false,
            translationCues: [durableCue]
        ))
        XCTAssertEqual(store.presentedTranslationCues(for: "zh").map(\.text), ["durable cue"])

        var objectChangeCount = 0
        let observation = store.livePresentation.objectWillChange.sink {
            objectChangeCount += 1
        }
        var frames: [NotebookCaptureLivePresentationStore.Frame] = []
        let frameObservation = store.livePresentation.$frame.dropFirst().sink { frame in
            frames.append(frame)
        }
        var parentObjectChangeCount = 0
        let parentObservation = store.objectWillChange.sink {
            parentObjectChangeCount += 1
        }

        client.emitLivePreview(NotebookCaptureLivePreviewDTO(
            sessionId: "session-a",
            previewRevision: 1,
            utterances: []
        ))

        XCTAssertEqual(objectChangeCount, 1)
        XCTAssertEqual(frames.count, 1)
        let emptyAuthorityFrame = try XCTUnwrap(frames.first)
        XCTAssertTrue(emptyAuthorityFrame.hasTranslationCueAuthority)
        XCTAssertTrue(emptyAuthorityFrame.utterances.isEmpty)
        XCTAssertTrue(emptyAuthorityFrame.translationCues.isEmpty)
        XCTAssertTrue(
            store.presentedTranslationCues(for: "zh").isEmpty,
            "the first empty live cue snapshot must hide the older durable cue tail"
        )

        var previewUtterance = NotebookCaptureUtteranceDTO.sample
        previewUtterance.revision = 0
        previewUtterance.sourceText = "coherent partial"
        previewUtterance.completion = "partial"
        let liveCue = NotebookCaptureTranslationCueDTO(
            targetLanguage: "zh",
            groupEpoch: 1,
            providerSequence: 2,
            sourceLanguage: "en",
            sourceStartMs: 500,
            sourceEndMs: 900,
            text: "live cue",
            completion: "partial",
            withdrawn: false,
            revision: 2
        )
        let liveHealth = NotebookCaptureLaneHealthDTO(
            targetLanguage: "zh",
            state: .live,
            groupEpoch: 1,
            finalAudioProcMs: 700,
            totalAudioProcMs: 900,
            lagMs: 200
        )
        let coherentPreview = NotebookCaptureLivePreviewDTO(
            sessionId: "session-a",
            previewRevision: 2,
            utterances: [previewUtterance],
            translationCues: [liveCue],
            laneHealth: [liveHealth]
        )
        client.emitLivePreview(coherentPreview)

        XCTAssertEqual(objectChangeCount, 2)
        XCTAssertEqual(frames.count, 2)
        let populatedFrame = try XCTUnwrap(frames.last)
        XCTAssertEqual(populatedFrame.utterances.map(\.sourceText), ["coherent partial"])
        XCTAssertEqual(populatedFrame.translationCues[liveCue.id]?.text, "live cue")
        XCTAssertEqual(populatedFrame.laneHealth["zh"], .live)
        XCTAssertEqual(populatedFrame.laneTelemetry["zh"]?.lagMs, 200)
        XCTAssertTrue(populatedFrame.hasTranslationCueAuthority)

        // A newer provider revision with the same presentation value advances
        // latest-wins bookkeeping without manufacturing another UI invalidation.
        client.emitLivePreview(NotebookCaptureLivePreviewDTO(
            sessionId: coherentPreview.sessionId,
            previewRevision: 3,
            utterances: coherentPreview.utterances,
            translationCues: coherentPreview.translationCues,
            laneHealth: coherentPreview.laneHealth
        ))
        XCTAssertEqual(objectChangeCount, 2)
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(parentObjectChangeCount, 0)

        observation.cancel()
        frameObservation.cancel()
        parentObservation.cancel()
        store.resetForTesting()
    }

    @MainActor
    func testCueOnlyPreviewBurstSharesTheRenderingBudgetAndPublishesNewestFrame() async throws {
        let client = FakeNotebookCaptureClient(profile: .twoWay(notebookId: "notebook-a"))
        let store = ActiveBilingualTranscriptStore(
            client: client,
            audioSource: FakeNotebookCaptureAudioSource(),
            elapsedTimerInterval: 10,
            livePreviewCoalescingInterval: 0.1
        )
        try await store.start(notebookId: "notebook-a")

        var objectChangeCount = 0
        let observation = store.livePresentation.objectWillChange.sink {
            objectChangeCount += 1
        }
        var parentObjectChangeCount = 0
        let parentObservation = store.objectWillChange.sink {
            parentObjectChangeCount += 1
        }
        for revision in 1...200 {
            client.emitLivePreview(NotebookCaptureLivePreviewDTO(
                sessionId: "session-a",
                previewRevision: UInt64(revision),
                utterances: [],
                translationCues: [NotebookCaptureTranslationCueDTO(
                    targetLanguage: "zh",
                    groupEpoch: 1,
                    providerSequence: 1,
                    sourceLanguage: "en",
                    sourceStartMs: 0,
                    sourceEndMs: 500,
                    text: "cue-\(revision)",
                    completion: "partial",
                    withdrawn: false,
                    revision: UInt64(revision)
                )],
                laneHealth: [NotebookCaptureLaneHealthDTO(
                    targetLanguage: "zh",
                    state: .live,
                    groupEpoch: 1,
                    totalAudioProcMs: UInt64(revision),
                    lagMs: UInt64(revision)
                )]
            ))
        }

        let didPublishTail = await waitUntil {
            store.presentedTranslationCues(for: "zh").map(\.text) == ["cue-200"]
                && store.laneTelemetry["zh"]?.lagMs == 200
        }
        XCTAssertTrue(didPublishTail, "cue and health coalescing must remain latest-wins")
        XCTAssertEqual(
            objectChangeCount,
            2,
            "the leading and newest trailing frame must each invalidate observers exactly once"
        )
        XCTAssertEqual(
            parentObjectChangeCount,
            0,
            "speculative frames must not invalidate capture controls and settings"
        )
        withExtendedLifetime((observation, parentObservation)) {}
        store.resetForTesting()
    }

    @MainActor
    func testHeldLivePreviewCannotReviveAfterTerminalCaptureEvent() async throws {
        let client = FakeNotebookCaptureClient(profile: .twoWay(notebookId: "notebook-a"))
        let store = ActiveBilingualTranscriptStore(
            client: client,
            audioSource: FakeNotebookCaptureAudioSource(),
            livePreviewCoalescingInterval: 0.2
        )
        try await store.start(notebookId: "notebook-a")

        var preview = NotebookCaptureUtteranceDTO.sample
        preview.sourceText = "leading"
        preview.completion = "partial"
        client.emitLivePreview(NotebookCaptureLivePreviewDTO(
            sessionId: "session-a",
            previewRevision: 1,
            utterances: [preview]
        ))
        preview.sourceText = "held"
        client.emitLivePreview(NotebookCaptureLivePreviewDTO(
            sessionId: "session-a",
            previewRevision: 2,
            utterances: [preview]
        ))

        client.emitCaptureEvent(captureEvent(
            sessionId: "session-a",
            state: .completed,
            utterances: [],
            eventRevision: 1,
            isFullSnapshot: false
        ))
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(store.captureState, .completed)
        XCTAssertTrue(store.livePreviewUtterances.isEmpty)
        XCTAssertFalse(
            store.livePreviewUtterances.contains(where: { $0.sourceText == "held" }),
            "a canceled trailing frame must not repopulate terminal presentation"
        )
        store.resetForTesting()
    }

    @MainActor
    func testCaptureDeltaRevisionGapRebuildsOnceThenResumesIncrementalUpserts() async throws {
        let client = FakeNotebookCaptureClient(profile: .twoWay(notebookId: "notebook-a"))
        let store = ActiveBilingualTranscriptStore(
            client: client,
            audioSource: FakeNotebookCaptureAudioSource()
        )
        try await store.start(notebookId: "notebook-a")

        var first = NotebookCaptureUtteranceDTO.sample.replacingIdentity(sequence: 0)
        first.revision = 1
        client.emitCaptureEvent(captureEvent(
            sessionId: "session-a",
            state: .recording,
            utterances: [first],
            eventRevision: 1,
            isFullSnapshot: false
        ))

        var second = first.replacingIdentity(id: "utt-2", sequence: 1)
        second.sourceText = "Recovered from durable rows"
        client.reconcileEvents = [captureEvent(
            sessionId: "session-a",
            state: .recording,
            utterances: [first, second]
        )]
        client.emitCaptureEvent(captureEvent(
            sessionId: "session-a",
            state: .recording,
            utterances: [second],
            eventRevision: 3,
            isFullSnapshot: false
        ))

        let didRepair = await waitUntil {
            client.reconcileCallCount == 1 && store.utterances.map(\.sequence) == [0, 1]
        }
        XCTAssertTrue(didRepair)
        XCTAssertEqual(client.sessionEventCount, 1)
        XCTAssertEqual(client.listUtterancesCount, 0)
        XCTAssertEqual(store.utterances.map(\.sequence), [0, 1])

        second.revision = 2
        second.sourceText = "Next delta"
        client.emitCaptureEvent(captureEvent(
            sessionId: "session-a",
            state: .recording,
            utterances: [second],
            eventRevision: 4,
            isFullSnapshot: false
        ))

        XCTAssertEqual(client.reconcileCallCount, 1)
        XCTAssertEqual(client.listUtterancesCount, 0)
        XCTAssertEqual(store.utterances.last?.sourceText, "Next delta")
        store.resetForTesting()
    }

    @MainActor
    func testCaptureGapRepairLeavesMainActorResponsiveWhileSnapshotIsBlocked() async throws {
        let client = FakeNotebookCaptureClient(profile: .twoWay(notebookId: "notebook-a"))
        let controller = BlockingNotebookReconcileController()
        client.reconcileController = controller
        let store = ActiveBilingualTranscriptStore(
            client: client,
            audioSource: FakeNotebookCaptureAudioSource()
        )
        try await store.start(notebookId: "notebook-a")

        var first = NotebookCaptureUtteranceDTO.sample.replacingIdentity(sequence: 0)
        first.revision = 1
        client.emitCaptureEvent(captureEvent(
            sessionId: "session-a",
            state: .recording,
            utterances: [first],
            eventRevision: 1,
            isFullSnapshot: false
        ))

        var second = first.replacingIdentity(id: "utt-2", sequence: 1)
        second.sourceText = "Recovered asynchronously"
        client.reconcileEvents = [captureEvent(
            sessionId: "session-a",
            state: .recording,
            utterances: [first, second]
        )]
        client.emitCaptureEvent(captureEvent(
            sessionId: "session-a",
            state: .recording,
            utterances: [second],
            eventRevision: 3,
            isFullSnapshot: false
        ))

        let didBlockSnapshot = await waitUntil { controller.isWaiting(call: 0) }
        XCTAssertTrue(didBlockSnapshot)

        var heartbeat = false
        Task { @MainActor in heartbeat = true }
        let didReceiveHeartbeat = await waitUntil { heartbeat }
        XCTAssertTrue(
            didReceiveHeartbeat,
            "a full repair read must never synchronously block the MainActor"
        )

        controller.release(call: 0)
        let didRepair = await waitUntil {
            store.utterances.map(\.sourceText).contains("Recovered asynchronously")
        }
        XCTAssertTrue(didRepair)
        XCTAssertEqual(client.listUtterancesCount, 0)
        store.resetForTesting()
    }

    @MainActor
    func testCaptureGapRepairRetriesAfterFailureWithoutAnotherCallback() async throws {
        let client = FakeNotebookCaptureClient(profile: .twoWay(notebookId: "notebook-a"))
        let store = ActiveBilingualTranscriptStore(
            client: client,
            audioSource: FakeNotebookCaptureAudioSource()
        )
        try await store.start(notebookId: "notebook-a")

        var first = NotebookCaptureUtteranceDTO.sample.replacingIdentity(sequence: 0)
        first.revision = 1
        client.emitCaptureEvent(captureEvent(
            sessionId: "session-a",
            state: .recording,
            utterances: [first],
            eventRevision: 1,
            isFullSnapshot: false
        ))

        var missing = first.replacingIdentity(id: "utt-missing", sequence: 1)
        missing.sourceText = "recovered after retry"
        let snapshot = captureEvent(
            sessionId: "session-a",
            state: .recording,
            utterances: [first, missing]
        )
        client.reconcileEvents = [snapshot, snapshot]
        client.reconcileErrors = [.ffiUnavailable, nil]

        client.emitCaptureEvent(captureEvent(
            sessionId: "session-a",
            state: .recording,
            utterances: [],
            eventRevision: 3,
            isFullSnapshot: false
        ))

        let didRecover = await waitUntil {
            client.reconcileCallCount >= 2
                && store.utterances.map(\.sourceText).contains("recovered after retry")
        }
        XCTAssertTrue(
            didRecover,
            "a transient snapshot failure must remain repair-required without another callback"
        )
        XCTAssertEqual(client.listUtterancesCount, 0)
        store.resetForTesting()
    }

    @MainActor
    func testCaptureGapRepairRebuildsTranslationCuesAndLaneHealth() async throws {
        let client = FakeNotebookCaptureClient(profile: .twoWay(notebookId: "notebook-a"))
        let store = ActiveBilingualTranscriptStore(
            client: client,
            audioSource: FakeNotebookCaptureAudioSource()
        )
        try await store.start(notebookId: "notebook-a")

        let cue = { (sequence: UInt64, text: String) in
            NotebookCaptureTranslationCueDTO(
                targetLanguage: "th",
                groupEpoch: 0,
                providerSequence: sequence,
                sourceLanguage: "zh",
                sourceStartMs: 1_000 * sequence,
                sourceEndMs: 1_000 * sequence + 500,
                text: text,
                completion: "partial",
                withdrawn: false,
                revision: 1
            )
        }

        // Two cues reach the canvas.
        client.emitCaptureEvent(captureEvent(
            sessionId: "session-a",
            state: .recording,
            utterances: [],
            eventRevision: 1,
            isFullSnapshot: false,
            translationCues: [cue(0, "หนึ่ง"), cue(1, "สอง")]
        ))
        let rendered = await waitUntil { store.translationCues.count == 2 }
        XCTAssertTrue(rendered, "cues must reach the store before the gap opens")

        // The provider retracts the second cue and a lane dies. That delta is
        // coalesced away — the client never sees it — and the next event
        // arrives with a revision gap, which is the only signal it gets.
        let snapshot = captureEvent(
            sessionId: "session-a",
            state: .recording,
            utterances: [],
            translationCues: [cue(0, "หนึ่ง")],
            laneHealth: [
                NotebookCaptureLaneHealthDTO(targetLanguage: nil, state: .live),
                NotebookCaptureLaneHealthDTO(targetLanguage: "th", state: .failed),
            ]
        )
        client.reconcileEvents = [snapshot]

        client.emitCaptureEvent(captureEvent(
            sessionId: "session-a",
            state: .recording,
            utterances: [],
            eventRevision: 5,
            isFullSnapshot: false
        ))

        let healed = await waitUntil {
            store.translationCues.count == 1
                && store.failedTranslationLanguages == ["th"]
        }
        XCTAssertTrue(
            healed,
            "the gap-repair snapshot must rebuild cues and lane health, not just utterances"
        )
        XCTAssertNil(
            store.translationCues["0:1:th"],
            "a withdrawal lost to coalescing must not leave retracted text on the canvas"
        )
        store.resetForTesting()
    }

    @MainActor
    func testLivePreviewFrameReplacesCueAndHealthTailWithoutDeletingDurableFacts() async throws {
        let client = FakeNotebookCaptureClient(profile: .twoWay(notebookId: "notebook-a"))
        let store = ActiveBilingualTranscriptStore(
            client: client,
            audioSource: FakeNotebookCaptureAudioSource()
        )
        try await store.start(notebookId: "notebook-a")

        let cue = {
            (target: String, sequence: UInt64, text: String) in
            NotebookCaptureTranslationCueDTO(
                targetLanguage: target,
                groupEpoch: 0,
                providerSequence: sequence,
                sourceLanguage: "en",
                sourceStartMs: sequence * 1_000,
                sourceEndMs: sequence * 1_000 + 800,
                text: text,
                completion: "partial",
                withdrawn: false,
                revision: 1
            )
        }
        let durableChinese = cue("zh", 0, "耐久旧事实")
        client.emitCaptureEvent(captureEvent(
            sessionId: "session-a",
            state: .recording,
            utterances: [],
            eventRevision: 1,
            isFullSnapshot: false,
            translationCues: [durableChinese]
        ))
        let didPersistDurableCue = await waitUntil {
            store.translationCues[durableChinese.id] != nil
        }
        XCTAssertTrue(didPersistDurableCue)

        let liveChinese = cue("zh", 1, "当前中文")
        let liveThai = cue("th", 1, "ภาษาไทยปัจจุบัน")
        client.emitLivePreview(NotebookCaptureLivePreviewDTO(
            sessionId: "session-a",
            previewRevision: 1,
            utterances: [],
            translationCues: [liveChinese, liveThai],
            laneHealth: [
                NotebookCaptureLaneHealthDTO(targetLanguage: nil, state: .live),
                NotebookCaptureLaneHealthDTO(
                    targetLanguage: "zh",
                    state: .live,
                    groupEpoch: 2,
                    finalAudioProcMs: 4_100,
                    totalAudioProcMs: 4_500,
                    lagMs: 400
                ),
                NotebookCaptureLaneHealthDTO(targetLanguage: "th", state: .live),
            ]
        ))
        let didInstallFirstLiveFrame = await waitUntil {
            store.presentedTranslationCues(for: "zh").map(\.text) == ["当前中文"]
                && store.presentedTranslationCues(for: "th").map(\.text)
                    == ["ภาษาไทยปัจจุบัน"]
        }
        XCTAssertTrue(didInstallFirstLiveFrame)
        XCTAssertEqual(
            Set(store.presentedTranslationCueSnapshot.map(\.text)),
            Set(["当前中文", "ภาษาไทยปัจจุบัน"])
        )
        XCTAssertEqual(store.laneTelemetry["zh"]?.groupEpoch, 2)
        XCTAssertEqual(store.laneTelemetry["zh"]?.lagMs, 400)

        let newerThai = cue("th", 2, "ภาษาไทยล่าสุด")
        client.emitLivePreview(NotebookCaptureLivePreviewDTO(
            sessionId: "session-a",
            previewRevision: 2,
            utterances: [],
            translationCues: [newerThai],
            laneHealth: [
                NotebookCaptureLaneHealthDTO(targetLanguage: nil, state: .live),
                NotebookCaptureLaneHealthDTO(
                    targetLanguage: "zh",
                    state: .failed,
                    groupEpoch: 2,
                    finalAudioProcMs: 4_100,
                    totalAudioProcMs: 4_500,
                    lagMs: 2_300,
                    inputDiscontinuous: true
                ),
                NotebookCaptureLaneHealthDTO(targetLanguage: "th", state: .live),
            ]
        ))
        let didReplaceLiveFrame = await waitUntil {
            store.presentedTranslationCues(for: "zh").isEmpty
                && store.presentedTranslationCues(for: "th").map(\.text) == ["ภาษาไทยล่าสุด"]
                && store.failedTranslationLanguages == ["zh"]
        }
        XCTAssertTrue(didReplaceLiveFrame)
        XCTAssertEqual(
            store.presentedTranslationCueSnapshot.map(\.text),
            ["ภาษาไทยล่าสุด"]
        )
        XCTAssertEqual(store.laneTelemetry["zh"]?.lagMs, 2_300)
        XCTAssertEqual(store.laneTelemetry["zh"]?.inputDiscontinuous, true)
        XCTAssertNotNil(
            store.translationCues[durableChinese.id],
            "bounded live-frame absence must withdraw presentation only, not durable history"
        )
        store.resetForTesting()
    }

    @MainActor
    func testCaptureGapRepairFromOldGenerationCannotOverwriteNewSession() async throws {
        let client = FakeNotebookCaptureClient(profile: .twoWay(notebookId: "notebook-a"))
        let controller = BlockingNotebookReconcileController()
        client.reconcileController = controller
        client.reconcileEvents = [captureEvent(
            sessionId: "session-a",
            state: .recording,
            utterances: [.sample]
        )]
        let store = ActiveBilingualTranscriptStore(
            client: client,
            audioSource: FakeNotebookCaptureAudioSource()
        )
        try await store.start(notebookId: "notebook-a")

        client.emitCaptureEvent(captureEvent(
            sessionId: "session-a",
            state: .recording,
            utterances: [.sample],
            eventRevision: 2,
            isFullSnapshot: false
        ))
        let didBlockOldRepair = await waitUntil { controller.isWaiting(call: 0) }
        XCTAssertTrue(didBlockOldRepair)

        store.resetForTesting()
        client.nextSessionId = "session-b"
        try await store.start(notebookId: "notebook-a")
        XCTAssertEqual(store.sessionId, "session-b")
        XCTAssertTrue(store.utterances.isEmpty)

        controller.release(call: 0)
        _ = await waitUntil { controller.isWaiting(call: 0) == false }
        XCTAssertEqual(store.sessionId, "session-b")
        XCTAssertTrue(
            store.utterances.isEmpty,
            "the completed repair for session A must fail its generation guard"
        )
        store.resetForTesting()
    }

    @MainActor
    func testSecondGapDiscardsInFlightSnapshotAndRepairsDeletedRow() async throws {
        let client = FakeNotebookCaptureClient(profile: .twoWay(notebookId: "notebook-a"))
        let controller = BlockingNotebookReconcileController()
        client.reconcileController = controller
        let store = ActiveBilingualTranscriptStore(
            client: client,
            audioSource: FakeNotebookCaptureAudioSource()
        )
        try await store.start(notebookId: "notebook-a")

        var current = NotebookCaptureUtteranceDTO.sample.replacingIdentity(sequence: 0)
        current.revision = 1
        var deleted = current.replacingIdentity(id: "utt-deleted", sequence: 1)
        deleted.sourceText = "must disappear"
        client.emitCaptureEvent(captureEvent(
            sessionId: "session-a",
            state: .recording,
            utterances: [current, deleted],
            eventRevision: 1,
            isFullSnapshot: false
        ))

        var firstGap = current
        firstGap.revision = 2
        firstGap.sourceText = "first gap"
        var latest = firstGap
        latest.revision = 3
        latest.sourceText = "after deletion"
        client.reconcileEvents = [
            captureEvent(
                sessionId: "session-a",
                state: .recording,
                utterances: [firstGap, deleted]
            ),
            captureEvent(
                sessionId: "session-a",
                state: .recording,
                utterances: [latest]
            ),
        ]

        client.emitCaptureEvent(captureEvent(
            sessionId: "session-a",
            state: .recording,
            utterances: [firstGap],
            eventRevision: 3,
            isFullSnapshot: false
        ))
        let didBlockFirstRepair = await waitUntil { controller.isWaiting(call: 0) }
        XCTAssertTrue(didBlockFirstRepair)

        // Revision 4 carried the durable deletion but its callback was
        // coalesced. Revision 5 must invalidate the already-read first
        // snapshot and force a second authoritative read.
        client.emitCaptureEvent(captureEvent(
            sessionId: "session-a",
            state: .recording,
            utterances: [latest],
            eventRevision: 5,
            isFullSnapshot: false
        ))
        controller.release(call: 0)

        let didStartSecondRepair = await waitUntil { controller.isWaiting(call: 1) }
        XCTAssertTrue(didStartSecondRepair)
        XCTAssertEqual(
            store.utterances.map(\.sourceText),
            ["after deletion", "must disappear"],
            "the stale first snapshot must not be installed"
        )

        controller.release(call: 1)
        let didConverge = await waitUntil {
            store.utterances.map(\.sourceText) == ["after deletion"]
        }
        XCTAssertTrue(didConverge)
        XCTAssertEqual(client.reconcileCallCount, 2)
        XCTAssertEqual(client.listUtterancesCount, 0)
        store.resetForTesting()
    }

    @MainActor
    func testCaptureGapRepairReplaysContinuousDeltasAfterSnapshotCheckpoint() async throws {
        let client = FakeNotebookCaptureClient(profile: .twoWay(notebookId: "notebook-a"))
        let controller = BlockingNotebookReconcileController()
        client.reconcileController = controller
        let store = ActiveBilingualTranscriptStore(
            client: client,
            audioSource: FakeNotebookCaptureAudioSource()
        )
        try await store.start(notebookId: "notebook-a")

        let cue = { (sequence: UInt64, text: String) in
            NotebookCaptureTranslationCueDTO(
                targetLanguage: "th",
                groupEpoch: 0,
                providerSequence: sequence,
                sourceLanguage: "en",
                sourceStartMs: sequence * 1_000,
                sourceEndMs: sequence * 1_000 + 700,
                text: text,
                completion: "partial",
                withdrawn: false,
                revision: 1
            )
        }
        let firstCue = cue(0, "หนึ่ง")
        let withdrawnCue = cue(1, "สอง")
        let withdrawal = NotebookCaptureTranslationCueDTO(
            targetLanguage: withdrawnCue.targetLanguage,
            groupEpoch: withdrawnCue.groupEpoch,
            providerSequence: withdrawnCue.providerSequence,
            sourceLanguage: withdrawnCue.sourceLanguage,
            sourceStartMs: withdrawnCue.sourceStartMs,
            sourceEndMs: withdrawnCue.sourceEndMs,
            text: "",
            completion: "partial",
            withdrawn: true,
            revision: 2
        )

        var first = NotebookCaptureUtteranceDTO.sample.replacingIdentity(sequence: 0)
        first.revision = 1
        first.sourceText = "initial"
        client.emitCaptureEvent(captureEvent(
            sessionId: "session-a",
            state: .recording,
            utterances: [first],
            eventRevision: 1,
            isFullSnapshot: false,
            translationCues: [firstCue, withdrawnCue],
            laneHealth: [
                NotebookCaptureLaneHealthDTO(targetLanguage: nil, state: .live),
                NotebookCaptureLaneHealthDTO(targetLanguage: "th", state: .live),
            ]
        ))

        var checkpointFirst = first
        checkpointFirst.revision = 2
        checkpointFirst.sourceText = "checkpoint"
        var recovered = first.replacingIdentity(id: "utt-recovered", sequence: 1)
        recovered.sourceText = "recovered missing revision"
        client.reconcileEvents = [captureEvent(
            sessionId: "session-a",
            state: .recording,
            utterances: [checkpointFirst, recovered],
            eventRevision: 3,
            isFullSnapshot: true,
            translationCues: [firstCue, withdrawnCue],
            laneHealth: [
                NotebookCaptureLaneHealthDTO(targetLanguage: nil, state: .live),
                NotebookCaptureLaneHealthDTO(targetLanguage: "th", state: .live),
            ]
        )]

        // Revision 2 was coalesced. Revision 3 starts the repair and is covered
        // by the mailbox-locked snapshot above.
        client.emitCaptureEvent(captureEvent(
            sessionId: "session-a",
            state: .recording,
            utterances: [checkpointFirst],
            eventRevision: 3,
            isFullSnapshot: false
        ))
        let didStartRepair = await waitUntil { controller.isWaiting(call: 0) }
        XCTAssertTrue(didStartRepair)

        // Continuous callbacks arrive while the snapshot is in flight. The
        // withdrawal and failed lane are both state that must survive replay.
        client.emitCaptureEvent(captureEvent(
            sessionId: "session-a",
            state: .recording,
            utterances: [],
            eventRevision: 4,
            isFullSnapshot: false,
            translationCues: [withdrawal],
            laneHealth: [
                NotebookCaptureLaneHealthDTO(targetLanguage: nil, state: .live),
                NotebookCaptureLaneHealthDTO(targetLanguage: "th", state: .failed),
            ]
        ))
        var latest = checkpointFirst
        latest.revision = 3
        latest.sourceText = "latest continuous callback"
        client.emitCaptureEvent(captureEvent(
            sessionId: "session-a",
            state: .recording,
            utterances: [latest],
            eventRevision: 5,
            isFullSnapshot: false
        ))

        controller.release(call: 0)
        let didConverge = await waitUntil {
            store.utterances.map(\.sourceText) == [
                "latest continuous callback",
                "recovered missing revision",
            ]
                && store.translationCues[firstCue.id] != nil
                && store.translationCues[withdrawnCue.id] == nil
                && store.failedTranslationLanguages == ["th"]
        }
        XCTAssertTrue(
            didConverge,
            "a checkpoint plus contiguous replay must converge without a quiet callback window"
        )
        XCTAssertEqual(client.reconcileCallCount, 1)
        XCTAssertFalse(controller.isWaiting(call: 1))
        store.resetForTesting()
    }

    @MainActor
    func testInactiveSessionChangeClearsOldRowsWhenNewSessionIsEmptyAndCannotEditOldRow() async {
        let client = FakeNotebookCaptureClient(profile: .twoWay(notebookId: "notebook-a"))
        let store = ActiveBilingualTranscriptStore(
            client: client,
            audioSource: FakeNotebookCaptureAudioSource()
        )
        client.sessionEventOverride = captureEvent(sessionId: "session-a", utterances: [.sample])
        store.loadUtterances(notebookId: "notebook-a", sessionId: "session-a")
        XCTAssertEqual(store.utterances.map(\.sourceText), ["Hello"])

        client.sessionEventOverride = captureEvent(sessionId: "session-b", utterances: [])
        store.loadUtterances(notebookId: "notebook-b", sessionId: "session-b")

        XCTAssertEqual(store.sessionId, "session-b")
        XCTAssertTrue(store.utterances.isEmpty)
        do {
            try await store.replaceLane(
                utteranceId: "utt-1",
                language: "en",
                text: "must not edit A"
            )
            XCTFail("an utterance from the previous session must stay unavailable")
        } catch {
            XCTAssertEqual(error as? NotebookCaptureClientError, .projectionLocked)
        }
        XCTAssertNil(client.lastReplaceExpectedRevision)
    }

    @MainActor
    func testRepeatedLoadOfValidEmptyRunUsesAppliedSnapshotWithoutSecondFFIRead() {
        let client = FakeNotebookCaptureClient(profile: .twoWay(notebookId: "notebook-a"))
        let store = ActiveBilingualTranscriptStore(
            client: client,
            audioSource: FakeNotebookCaptureAudioSource()
        )
        client.sessionEventOverride = captureEvent(sessionId: "empty-session", utterances: [])

        store.loadUtterances(notebookId: "notebook-a", sessionId: "empty-session")
        XCTAssertTrue(store.hasLoadedCaptureRunSnapshot)
        XCTAssertTrue(store.utterances.isEmpty)
        XCTAssertEqual(client.sessionEventCount, 1)

        client.sessionEventError = .ffiUnavailable
        store.loadUtterances(notebookId: "notebook-a", sessionId: "empty-session")

        XCTAssertEqual(client.sessionEventCount, 1, "a valid zero-row run is still a loaded snapshot")
        XCTAssertTrue(store.hasLoadedCaptureRunSnapshot)
        XCTAssertNil(store.lastError)
    }

    @MainActor
    func testRepeatedLoadRetriesSameSessionAfterFailedSnapshotRead() {
        let client = FakeNotebookCaptureClient(profile: .twoWay(notebookId: "notebook-a"))
        let store = ActiveBilingualTranscriptStore(
            client: client,
            audioSource: FakeNotebookCaptureAudioSource()
        )
        client.sessionEventError = .ffiUnavailable

        store.loadUtterances(notebookId: "notebook-a", sessionId: "retry-session")
        XCTAssertEqual(client.sessionEventCount, 1)
        XCTAssertFalse(store.hasLoadedCaptureRunSnapshot)
        XCTAssertEqual(store.projectionState, .failed)

        client.sessionEventError = nil
        client.sessionEventOverride = captureEvent(sessionId: "retry-session", utterances: [])
        store.loadUtterances(notebookId: "notebook-a", sessionId: "retry-session")

        XCTAssertEqual(client.sessionEventCount, 2, "a failed snapshot must not poison explicit retry")
        XCTAssertTrue(store.hasLoadedCaptureRunSnapshot)
        XCTAssertTrue(store.utterances.isEmpty)
        XCTAssertNil(store.lastError)
    }

    @MainActor
    func testInactiveSessionChangeReplacesOldRowsInsteadOfMergingSessions() {
        let client = FakeNotebookCaptureClient(profile: .twoWay(notebookId: "notebook-a"))
        let store = ActiveBilingualTranscriptStore(
            client: client,
            audioSource: FakeNotebookCaptureAudioSource()
        )
        client.sessionEventOverride = captureEvent(sessionId: "session-a", utterances: [.sample])
        store.loadUtterances(notebookId: "notebook-a", sessionId: "session-a")

        let utteranceB = NotebookCaptureUtteranceDTO(
            id: "utt-b",
            sessionId: "session-b",
            sequence: 1,
            revision: 1,
            sourceLanguage: "en",
            sourceText: "Only B",
            sourceStartMs: 0,
            sourceEndMs: 500,
            translatedLanguage: "zh",
            translatedText: "只有 B",
            completion: "complete",
            alignment: "response_order"
        )
        client.sessionEventOverride = captureEvent(sessionId: "session-b", utterances: [utteranceB])
        store.loadUtterances(notebookId: "notebook-b", sessionId: "session-b")

        XCTAssertEqual(store.utterances.map(\.id), ["utt-b"])
        XCTAssertEqual(Set(store.utterances.map(\.sessionId)), ["session-b"])
    }

    @MainActor
    func testHistoricalLoadFailureClearsPreviousRowsAndSnapshotMetadata() {
        let client = FakeNotebookCaptureClient(profile: .twoWay(notebookId: "notebook-a"))
        let store = ActiveBilingualTranscriptStore(
            client: client,
            audioSource: FakeNotebookCaptureAudioSource()
        )
        client.sessionEventOverride = captureEvent(sessionId: "session-a", utterances: [.sample])
        store.loadUtterances(notebookId: "notebook-a", sessionId: "session-a")
        XCTAssertFalse(store.utterances.isEmpty)

        client.sessionEventOverride = nil
        client.sessionEventError = .ffiUnavailable
        store.loadUtterances(notebookId: "notebook-b", sessionId: "session-b")

        XCTAssertEqual(store.sessionId, "session-b")
        XCTAssertTrue(store.utterances.isEmpty)
        XCTAssertEqual(store.projectionState, .failed)
        XCTAssertFalse(store.hasValidRunProfileSnapshot)
        XCTAssertTrue(store.leftLanguage.isEmpty)
        XCTAssertNotNil(store.lastError)
    }

    @MainActor
    func testSavingFutureNotebookProfileDoesNotRewriteHistoricalRunSnapshot() throws {
        let client = FakeNotebookCaptureClient(profile: .twoWay(notebookId: "notebook-a"))
        let store = ActiveBilingualTranscriptStore(
            client: client,
            audioSource: FakeNotebookCaptureAudioSource()
        )
        client.sessionEventOverride = captureEvent(
            sessionId: "historical-session",
            utterances: [.sample]
        )
        store.loadUtterances(notebookId: "notebook-a", sessionId: "historical-session")
        let runSnapshot = store.profile

        var futureProfile = client.profile
        futureProfile.languageA = "fr"
        futureProfile.languageB = "de"
        futureProfile.leftLanguage = "fr"
        futureProfile.rightLanguage = "de"
        futureProfile.selectedLanguages = ["fr", "de"]
        futureProfile.commonCaptionLanguage = nil
        _ = try store.saveProfile(futureProfile)

        XCTAssertEqual(store.sessionId, "historical-session")
        XCTAssertEqual(store.profile, runSnapshot)
        XCTAssertEqual(store.leftLanguage, "en")
        XCTAssertEqual(store.rightLanguage, "zh")
        XCTAssertEqual(store.selectedLanguages, ["en", "zh"])
        XCTAssertNil(store.commonCaptionLanguage)
        XCTAssertEqual(client.profile.languageA, "fr")
        XCTAssertEqual(client.profile.languageB, "de")
        XCTAssertEqual(client.profile.selectedLanguages, ["fr", "de"])
    }

    @MainActor
    func testLateTerminalCallbackFromPreviousRunCannotStopNewCapture() async throws {
        let client = FakeNotebookCaptureClient(profile: .twoWay(notebookId: "notebook-a"))
        let audio = FakeNotebookCaptureAudioSource()
        let store = ActiveBilingualTranscriptStore(client: client, audioSource: audio)

        try await store.start(notebookId: "notebook-a")
        try await store.stop()
        XCTAssertEqual(audio.unsubscribeCount, 1)

        client.nextSessionId = "session-b"
        try await store.start(notebookId: "notebook-a")
        XCTAssertEqual(store.sessionId, "session-b")
        XCTAssertTrue(store.hasAudioSubscription)

        client.emitCaptureEvent(
            captureEvent(sessionId: "session-a", state: .completed, utterances: []),
            callbackSessionId: "session-a"
        )

        XCTAssertEqual(store.sessionId, "session-b")
        XCTAssertEqual(store.captureState, .recording)
        XCTAssertTrue(store.hasAudioSubscription)
        XCTAssertEqual(audio.unsubscribeCount, 1, "stale A callback must not take B's microphone")
    }

    @MainActor
    func testTerminalLeaseRejectsNewCaptureUntilOldInterruptCommits() async throws {
        let client = FakeNotebookCaptureClient(profile: .twoWay(notebookId: "notebook-a"))
        let interrupt = BlockingNotebookInterruptController()
        client.interruptController = interrupt
        let audio = FakeNotebookCaptureAudioSource()
        let store = ActiveBilingualTranscriptStore(client: client, audioSource: audio)
        try await store.start(notebookId: "notebook-a")

        audio.emitOverflow()
        let interruptIsWaiting = await waitUntil {
            client.interruptCount == 1 && interrupt.isWaiting
        }
        XCTAssertTrue(interruptIsWaiting)
        XCTAssertEqual(store.captureState, .draining)
        XCTAssertTrue(store.isCaptureActive)
        XCTAssertFalse(store.isEditable)

        let immutableRunProfile = store.profile
        store.loadProfile(notebookId: "notebook-b")
        store.loadUtterances(notebookId: "notebook-b", sessionId: "session-b")
        XCTAssertEqual(store.sessionId, "session-a")
        XCTAssertEqual(store.profile, immutableRunProfile)

        client.nextSessionId = "session-b"
        do {
            try await store.start(notebookId: "notebook-b")
            XCTFail("B must not start while A still owns the terminal lease")
        } catch {
            XCTAssertEqual(error as? NotebookCaptureClientError, .captureAlreadyActive)
        }
        XCTAssertEqual(client.startCount, 1, "rejection must happen before entering the client")
        XCTAssertEqual(audio.prepareCount, 1, "rejection must happen before preparing a second microphone")
        XCTAssertEqual(audio.subscribeCount, 1)

        client.emitCaptureEvent(
            captureEvent(sessionId: "session-a", state: .interrupted, utterances: []),
            callbackSessionId: "session-a"
        )
        XCTAssertEqual(store.captureState, .interrupted)
        XCTAssertFalse(store.isCaptureActive)

        client.profile = .twoWay(notebookId: "notebook-b")
        try await store.start(notebookId: "notebook-b")
        XCTAssertEqual(store.sessionId, "session-b")
        XCTAssertEqual(store.captureState, .recording)
        XCTAssertTrue(store.hasAudioSubscription)
        XCTAssertEqual(audio.subscribeCount, 2)

        interrupt.release()
        let oldInterruptDidFinish = await waitUntil { interrupt.didFinish }
        XCTAssertTrue(oldInterruptDidFinish)
        client.emitCaptureEvent(
            captureEvent(sessionId: "session-a", state: .interrupted, utterances: []),
            callbackSessionId: "session-a"
        )

        XCTAssertEqual(store.sessionId, "session-b")
        XCTAssertEqual(store.captureState, .recording)
        XCTAssertTrue(store.hasAudioSubscription)
        XCTAssertEqual(audio.unsubscribeCount, 1, "late A completion must not release B's microphone")
        try await store.stop()
    }

    @MainActor
    func testRealtimeRouteBindsNewSessionImmediatelyButManualNotesStaySelected() async throws {
        let tempDir = NSTemporaryDirectory()
            .appending("zulangue-start-route-\(UUID().uuidString)")
        let core = try ZulangueCore.newDeferred(dataDir: tempDir)
        defer {
            try? core.shutdown()
            try? FileManager.default.removeItem(atPath: tempDir)
        }
        let notebook = try core.createNotebook(title: "Route test")
        let tabs = try core.listNotebookTabs(notebookId: notebook.id)
        let realtime = try XCTUnwrap(tabs.first { $0.builtinKind == "realtime_transcript" })
        let manual = try XCTUnwrap(tabs.first { $0.builtinKind == "manual_note" })
        let navigation = MainNavigationStore(
            activeNotebookIDProvider: { notebook.id },
            captureRouteContextProvider: { (nil, nil, false) },
            coreProvider: { core }
        )

        navigation.openNotebookTab(
            notebookID: notebook.id,
            tabID: manual.id,
            documentID: manual.docId,
            selectedSessionID: nil
        )
        navigation.bindStartedCaptureSession(notebookID: notebook.id, sessionID: "ignored-session")
        XCTAssertEqual(navigation.activeNotebookTabID, manual.id)
        XCTAssertNil(navigation.selectedSessionID, "manual notes must not be forced to the live transcript")

        navigation.openNotebookTab(
            notebookID: notebook.id,
            tabID: realtime.id,
            documentID: realtime.docId,
            selectedSessionID: nil
        )
        let capture = ActiveBilingualTranscriptStore(
            client: FakeNotebookCaptureClient(profile: .twoWay(notebookId: notebook.id)),
            audioSource: FakeNotebookCaptureAudioSource()
        )
        try await NotebookCaptureStartCoordinator(capture: capture, navigation: navigation)
            .start(notebookId: notebook.id)

        XCTAssertEqual(capture.sessionId, "session-a")
        XCTAssertEqual(navigation.activeNotebookTabID, realtime.id)
        XCTAssertEqual(navigation.selectedSessionID, "session-a")
    }

    @MainActor
    func testCaptureStartAlwaysRevealsRealtimeCommandCenter() async throws {
        let tempDir = NSTemporaryDirectory()
            .appending("zulangue-manual-start-route-\(UUID().uuidString)")
        let core = try ZulangueCore.newDeferred(dataDir: tempDir)
        defer {
            try? core.shutdown()
            try? FileManager.default.removeItem(atPath: tempDir)
        }
        let notebook = try core.createNotebook(title: "Manual start route")
        let manual = try XCTUnwrap(
            try core.listNotebookTabs(notebookId: notebook.id)
                .first { $0.builtinKind == "manual_note" }
        )
        let navigation = MainNavigationStore(
            activeNotebookIDProvider: { notebook.id },
            captureRouteContextProvider: { (nil, nil, false) },
            coreProvider: { core }
        )
        navigation.openNotebookTab(
            notebookID: notebook.id,
            tabID: manual.id,
            documentID: manual.docId,
            selectedSessionID: nil
        )
        let capture = ActiveBilingualTranscriptStore(
            client: FakeNotebookCaptureClient(profile: .twoWay(notebookId: notebook.id)),
            audioSource: FakeNotebookCaptureAudioSource()
        )

        try await NotebookCaptureStartCoordinator(capture: capture, navigation: navigation)
            .start(notebookId: notebook.id)

        let realtime = try XCTUnwrap(
            try core.listNotebookTabs(notebookId: notebook.id)
                .first { $0.builtinKind == "realtime_transcript" }
        )
        XCTAssertEqual(navigation.activeNotebookTabID, realtime.id)
        XCTAssertEqual(navigation.activeDocID, realtime.docId)
        XCTAssertEqual(navigation.selectedSessionID, "session-a")
        XCTAssertTrue(capture.isCaptureActive)
        try await capture.stop()
    }

    @MainActor
    func testRealtimeRoutePrefersTheMatchingActiveCaptureSession() {
        XCTAssertEqual(
            NotebookCaptureRouteSessionPolicy.resolve(
                requestedSessionId: "historical-session",
                targetNotebookId: "notebook-a",
                isRealtimeTab: true,
                activeCaptureNotebookId: "notebook-a",
                activeCaptureSessionId: "live-session",
                isCaptureActive: true
            ),
            "live-session"
        )
        XCTAssertEqual(
            NotebookCaptureRouteSessionPolicy.resolve(
                requestedSessionId: "historical-session",
                targetNotebookId: "notebook-b",
                isRealtimeTab: true,
                activeCaptureNotebookId: "notebook-a",
                activeCaptureSessionId: "live-session",
                isCaptureActive: true
            ),
            "historical-session"
        )
        XCTAssertNil(
            NotebookCaptureRouteSessionPolicy.resolve(
                requestedSessionId: nil,
                targetNotebookId: "notebook-a",
                isRealtimeTab: false,
                activeCaptureNotebookId: "notebook-a",
                activeCaptureSessionId: "live-session",
                isCaptureActive: true
            )
        )
    }

    @MainActor
    func testOnlyManualNotesMountTheLoroTextEditor() {
        XCTAssertTrue(NotebookDocumentSurfacePolicy.mountsLoroTextEditor(for: .manualNote))
        XCTAssertFalse(NotebookDocumentSurfacePolicy.mountsLoroTextEditor(for: .realtimeTranscript))
        XCTAssertFalse(NotebookDocumentSurfacePolicy.mountsLoroTextEditor(for: .asyncTranscript))
    }

    @MainActor
    func testStartingFromSettingsAlwaysRevealsTheNewRealtimeSession() async throws {
        let tempDir = NSTemporaryDirectory()
            .appending("zulangue-settings-start-route-\(UUID().uuidString)")
        let core = try ZulangueCore.newDeferred(dataDir: tempDir)
        defer {
            try? core.shutdown()
            try? FileManager.default.removeItem(atPath: tempDir)
        }
        let notebook = try core.createNotebook(title: "Settings start route")
        let tabs = try core.listNotebookTabs(notebookId: notebook.id)
        let realtime = try XCTUnwrap(tabs.first { $0.builtinKind == "realtime_transcript" })
        let manual = try XCTUnwrap(tabs.first { $0.builtinKind == "manual_note" })
        let navigation = MainNavigationStore(
            activeNotebookIDProvider: { notebook.id },
            captureRouteContextProvider: { (nil, nil, false) },
            coreProvider: { core }
        )
        navigation.openNotebookTab(
            notebookID: notebook.id,
            tabID: manual.id,
            documentID: manual.docId,
            selectedSessionID: nil
        )
        let capture = ActiveBilingualTranscriptStore(
            client: FakeNotebookCaptureClient(profile: .twoWay(notebookId: notebook.id)),
            audioSource: FakeNotebookCaptureAudioSource()
        )

        try await NotebookCaptureStartCoordinator(capture: capture, navigation: navigation)
            .start(notebookId: notebook.id)

        XCTAssertEqual(navigation.activeNotebookTabID, realtime.id)
        XCTAssertEqual(navigation.activeNotebookID, notebook.id)
        XCTAssertEqual(navigation.activeDocID, realtime.docId)
        XCTAssertEqual(navigation.selectedSessionID, "session-a")
        XCTAssertEqual(navigation.activeTab, .editor)
        XCTAssertTrue(capture.isCaptureActive)
        try await capture.stop()
    }

    @MainActor
    func testDisplayElapsedTimeUsesTheSingleCaptureStateAndFreezesWhilePaused() async throws {
        let client = FakeNotebookCaptureClient(profile: .twoWay(notebookId: "notebook-a"))
        let store = ActiveBilingualTranscriptStore(
            client: client,
            audioSource: FakeNotebookCaptureAudioSource(),
            elapsedTimerInterval: 0.01
        )
        store.loadProfile(notebookId: "notebook-a")
        try await store.start(notebookId: "notebook-a")

        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertGreaterThan(store.elapsedRecordingTime, 0)

        try await store.setPaused(true)
        let pausedElapsed = store.elapsedRecordingTime
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertEqual(store.elapsedRecordingTime, pausedElapsed, accuracy: 0.0001)

        try await store.stop()
    }

    @MainActor
    func testStopFailureAppliesAuthoritativeRustSessionSnapshot() async throws {
        let client = FakeNotebookCaptureClient(profile: .twoWay(notebookId: "notebook-a"))
        client.shouldFailStop = true
        client.sessionEventOverride = captureEvent(
            sessionId: "session-a",
            state: .interrupted,
            utterances: []
        )
        let audio = FakeNotebookCaptureAudioSource()
        let store = ActiveBilingualTranscriptStore(client: client, audioSource: audio)
        store.loadProfile(notebookId: "notebook-a")
        try await store.start(notebookId: "notebook-a")

        do {
            try await store.stop()
            XCTFail("stop should surface the terminal finalization error")
        } catch {
            XCTAssertEqual(error as? NotebookCaptureClientError, .ffiUnavailable)
        }
        XCTAssertEqual(client.sessionEventCount, 1)
        XCTAssertEqual(store.captureState, .interrupted)
        XCTAssertEqual(store.projectionState, .ready)
        XCTAssertFalse(store.hasAudioSubscription)
        XCTAssertEqual(audio.unsubscribeCount, 1)
    }

    @MainActor
    func testStopFailureWithAuthoritativeRecordingSnapshotDurablyInterruptsFailClosed() async throws {
        let client = FakeNotebookCaptureClient(profile: .twoWay(notebookId: "notebook-a"))
        client.shouldFailStop = true
        client.sessionEventOverride = captureEvent(
            sessionId: "session-a",
            state: .recording,
            utterances: []
        )
        let audio = FakeNotebookCaptureAudioSource()
        let store = ActiveBilingualTranscriptStore(client: client, audioSource: audio)
        try await store.start(notebookId: "notebook-a")

        do {
            try await store.stop()
            XCTFail("stop should surface the persistence failure")
        } catch {
            XCTAssertEqual(error as? NotebookCaptureClientError, .ffiUnavailable)
        }

        XCTAssertEqual(client.sessionEventCount, 1)
        XCTAssertEqual(client.interruptCount, 1, "an authoritative active snapshot must be durably interrupted")
        XCTAssertEqual(client.lastInterruptReason, .localAudioUnavailable)
        XCTAssertEqual(store.captureState, .interrupted)
        XCTAssertFalse(store.isCaptureActive)
        XCTAssertFalse(store.hasAudioSubscription)
        XCTAssertFalse(store.hasAudioPushGateForTesting)
        XCTAssertNotNil(store.lastError, "the original stop failure must remain visible")
    }

    @MainActor
    func testStopFailureWithAuthoritativeDrainingSnapshotRecoversDetachedRun() async throws {
        let client = FakeNotebookCaptureClient(profile: .twoWay(notebookId: "notebook-a"))
        client.shouldFailStop = true
        client.sessionEventOverride = captureEvent(
            sessionId: "session-a",
            state: .draining,
            utterances: []
        )
        let store = ActiveBilingualTranscriptStore(
            client: client,
            audioSource: FakeNotebookCaptureAudioSource()
        )
        try await store.start(notebookId: "notebook-a")

        do {
            try await store.stop()
            XCTFail("stop should surface the persistence failure")
        } catch {
            XCTAssertEqual(error as? NotebookCaptureClientError, .ffiUnavailable)
        }

        XCTAssertEqual(client.sessionEventCount, 1)
        XCTAssertEqual(client.interruptCount, 1)
        XCTAssertEqual(client.lastInterruptReason, .localAudioUnavailable)
        XCTAssertEqual(store.captureState, .interrupted)
        XCTAssertFalse(store.isCaptureActive)
        XCTAssertFalse(store.hasAudioSubscription)
        XCTAssertFalse(store.hasAudioPushGateForTesting)
        XCTAssertNotNil(store.lastError)
    }

    @MainActor
    func testStopFailureWithActiveSnapshotFallsBackLocallyOnlyAfterInterruptFails() async throws {
        let client = FakeNotebookCaptureClient(profile: .twoWay(notebookId: "notebook-a"))
        client.shouldFailStop = true
        client.sessionEventOverride = captureEvent(
            sessionId: "session-a",
            state: .recording,
            utterances: []
        )
        client.interruptError = .ffiUnavailable
        let store = ActiveBilingualTranscriptStore(
            client: client,
            audioSource: FakeNotebookCaptureAudioSource()
        )
        try await store.start(notebookId: "notebook-a")

        do {
            try await store.stop()
            XCTFail("stop should surface the persistence failure")
        } catch {
            XCTAssertEqual(error as? NotebookCaptureClientError, .ffiUnavailable)
        }

        XCTAssertEqual(client.sessionEventCount, 1)
        XCTAssertEqual(client.interruptCount, 1)
        XCTAssertEqual(store.captureState, .draining)
        XCTAssertEqual(store.projectionState, .pending)
        XCTAssertTrue(store.stopRecoveryRequired)
        XCTAssertEqual(store.presentationCaptureState, .failed)
        XCTAssertTrue(store.isCaptureActive, "an unresolved durable owner must retain the lease")
        XCTAssertFalse(store.isEditable)
        XCTAssertFalse(store.hasAudioSubscription)
        XCTAssertFalse(store.hasAudioPushGateForTesting)
        XCTAssertNotNil(store.lastError)
    }

    @MainActor
    func testStopFailureRecoversDurablyWhenAuthoritativeReadAlsoFails() async throws {
        let client = FakeNotebookCaptureClient(profile: .twoWay(notebookId: "notebook-a"))
        client.shouldFailStop = true
        client.sessionEventError = .ffiUnavailable
        let audio = FakeNotebookCaptureAudioSource()
        let store = ActiveBilingualTranscriptStore(client: client, audioSource: audio)
        try await store.start(notebookId: "notebook-a")

        do {
            try await store.stop()
            XCTFail("stop should surface the terminal finalization error")
        } catch {
            XCTAssertEqual(error as? NotebookCaptureClientError, .ffiUnavailable)
        }

        XCTAssertEqual(client.sessionEventCount, 1)
        XCTAssertEqual(client.interruptCount, 1)
        XCTAssertEqual(store.captureState, .interrupted)
        XCTAssertFalse(store.isCaptureActive)
        XCTAssertTrue(store.isEditable)
        XCTAssertFalse(store.hasAudioSubscription)
        XCTAssertNotNil(store.lastError)
    }

    @MainActor
    func testStopFailureBecomesExplicitlyRetryableWhenReadAndRecoveryBothFail() async throws {
        let client = FakeNotebookCaptureClient(profile: .twoWay(notebookId: "notebook-a"))
        client.shouldFailStop = true
        client.sessionEventError = .ffiUnavailable
        client.interruptError = .ffiUnavailable
        let audio = FakeNotebookCaptureAudioSource()
        let store = ActiveBilingualTranscriptStore(client: client, audioSource: audio)
        try await store.start(notebookId: "notebook-a")

        do {
            try await store.stop()
            XCTFail("stop should surface the terminal finalization error")
        } catch {
            XCTAssertEqual(error as? NotebookCaptureClientError, .ffiUnavailable)
        }

        XCTAssertEqual(client.sessionEventCount, 1)
        XCTAssertEqual(client.interruptCount, 1)
        XCTAssertEqual(store.captureState, .draining)
        XCTAssertEqual(store.projectionState, .pending)
        XCTAssertTrue(store.stopRecoveryRequired)
        XCTAssertEqual(store.presentationCaptureState, .failed)
        XCTAssertTrue(store.isCaptureActive, "a failed durable recovery must retain the lease")
        XCTAssertFalse(store.isEditable)
        XCTAssertFalse(store.hasAudioSubscription)
        XCTAssertNotNil(store.lastError)

        client.interruptError = nil
        try await store.retryStopRecovery()

        XCTAssertEqual(client.interruptCount, 2)
        XCTAssertEqual(store.captureState, .interrupted)
        XCTAssertEqual(store.presentationCaptureState, .interrupted)
        XCTAssertFalse(store.stopRecoveryRequired)
        XCTAssertFalse(store.isCaptureActive)
        XCTAssertTrue(store.isEditable)
        XCTAssertNil(store.lastError)
    }

    @MainActor
    func testStreamingResamplerPreservesCountFrequencyAndBufferContinuity() {
        for inputRate in [44_100.0, 48_000.0] {
            let chunked = resampledTone(
                inputRate: inputRate,
                frequency: 997,
                chunks: [137, 4_096, 53, 777, 2_003]
            )
            let contiguous = resampledTone(
                inputRate: inputRate,
                frequency: 997,
                chunks: [Int(inputRate)]
            )

            XCTAssertEqual(chunked.count, 16_000, "\(inputRate) Hz must produce exact 16 kHz count")
            XCTAssertEqual(chunked, contiguous, "buffer boundaries must not reset phase or FIR history")
            XCTAssertEqual(
                estimatedFrequency(of: chunked, sampleRate: 16_000),
                997,
                accuracy: 2.0
            )
        }
    }

    @MainActor
    func testStreamingResamplerSuppressesAboveNyquistAliasing() {
        for inputRate in [44_100.0, 48_000.0] {
            let passband = resampledTone(
                inputRate: inputRate,
                frequency: 1_000,
                chunks: [251, 1_337, 89, 4_001]
            )
            let stopband = resampledTone(
                inputRate: inputRate,
                frequency: 12_000,
                chunks: [251, 1_337, 89, 4_001]
            )
            let passbandRMS = rms(Array(passband.dropFirst(1_024)))
            let stopbandRMS = rms(Array(stopband.dropFirst(1_024)))
            XCTAssertLessThan(
                stopbandRMS / passbandRMS,
                0.05,
                "12 kHz input must not alias into the 16 kHz output"
            )
        }
    }

    @MainActor
    func testMicrophoneTapRingIsAtomicBoundedAndReportsOverflowOnce() {
        let ring = MicrophoneCaptureSPSCRing(capacity: 2, maximumFramesPerSlot: 4)
        let first: [Float] = [0.1, 0.2, 0.3, 0.4]
        let second: [Float] = [-0.1, -0.2]

        XCTAssertEqual(
            first.withUnsafeBufferPointer { ring.enqueue($0, sampleTime: 10) },
            .accepted
        )
        XCTAssertEqual(
            second.withUnsafeBufferPointer { ring.enqueue($0, sampleTime: 20) },
            .accepted
        )
        XCTAssertEqual(
            first.withUnsafeBufferPointer { ring.enqueue($0, sampleTime: 30) },
            .overflow
        )
        XCTAssertEqual(
            first.withUnsafeBufferPointer { ring.enqueue($0, sampleTime: 40) },
            .closed
        )
        XCTAssertEqual(ring.pendingCountForTesting, 2)
        XCTAssertTrue(ring.claimOverflowNotification())
        XCTAssertFalse(ring.claimOverflowNotification(), "overflow must be visible exactly once")

        var received: [([Float], Int64)] = []
        XCTAssertTrue(ring.consume { received.append((Array($0), $1)) })
        XCTAssertTrue(ring.consume { received.append((Array($0), $1)) })
        XCTAssertFalse(ring.consume { _ = ($0, $1) })
        XCTAssertEqual(received.map(\.0), [first, second])
        XCTAssertEqual(received.map(\.1), [10, 20])
        XCTAssertTrue(ring.isClosedAndDrained)
    }

    func testMicrophoneTapClosureOnlyPublishesToPreallocatedRing() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Zulangue/Capture/MicrophoneCapture.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "inputNode.installTap("))
        let end = try XCTUnwrap(
            source.range(of: "if didPrewarm == false", range: start.upperBound..<source.endIndex)
        )
        let tap = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(source.contains("import Synchronization"))
        XCTAssertTrue(tap.contains("worker.enqueue("))
        XCTAssertTrue(tap.contains("channelData[0]"))
        XCTAssertTrue(tap.contains("stride: buffer.stride"))
        for forbidden in [
            "NSLock", ".lock()", ".wait()", "DispatchSemaphore", "DispatchQueue",
            ".async", "Data(", "StreamingS16Resampler", ".process(", "Array(",
        ] {
            XCTAssertFalse(tap.contains(forbidden), "tap must not contain \(forbidden)")
        }
    }

    @MainActor
    func testMicrophoneWorkerFencesAcceptedFramesBeforeOneShotOverflow() {
        let recorder = MicrophoneWorkerRecorder()
        let worker = MicrophoneCaptureWorker(
            generation: 7,
            inputSampleRate: 48_000,
            ringCapacity: 2,
            maximumFramesPerSlot: 32,
            onAudio: { generation, data, _ in
                recorder.recordAudio(generation: generation, data: data)
            },
            onOverflow: { recorder.recordOverflow(generation: $0) }
        )
        let samples = (0..<32).map { Float($0) / 32 }

        // Fill deterministically before the consumer starts.
        XCTAssertEqual(
            samples.withUnsafeBufferPointer { worker.enqueue($0, sampleTime: 0) },
            .accepted
        )
        XCTAssertEqual(
            samples.withUnsafeBufferPointer { worker.enqueue($0, sampleTime: 32) },
            .accepted
        )
        XCTAssertEqual(
            samples.withUnsafeBufferPointer { worker.enqueue($0, sampleTime: 64) },
            .overflow
        )

        worker.start()
        let terminalReason = worker.closeAndWait()

        XCTAssertEqual(recorder.audioGenerations, [7, 7])
        XCTAssertTrue(recorder.audioByteCounts.allSatisfy { $0 > 0 })
        XCTAssertEqual(recorder.overflowGenerations, [7])
        XCTAssertEqual(terminalReason, .overflow)
    }

    @MainActor
    func testMicrophoneWorkerStopStartGenerationIsolation() {
        let recorder = MicrophoneWorkerRecorder()
        let samples = Array(repeating: Float(0.25), count: 64)

        let first = MicrophoneCaptureWorker(
            generation: 41,
            inputSampleRate: 44_100,
            ringCapacity: 2,
            maximumFramesPerSlot: 64,
            onAudio: { generation, data, _ in
                recorder.recordAudio(generation: generation, data: data)
            },
            onOverflow: { recorder.recordOverflow(generation: $0) }
        )
        first.start()
        XCTAssertEqual(
            samples.withUnsafeBufferPointer { first.enqueue($0, sampleTime: 0) },
            .accepted
        )
        first.closeAndWait()
        XCTAssertEqual(recorder.audioGenerations, [41])

        let second = MicrophoneCaptureWorker(
            generation: 42,
            inputSampleRate: 48_000,
            ringCapacity: 2,
            maximumFramesPerSlot: 64,
            onAudio: { generation, data, _ in
                recorder.recordAudio(generation: generation, data: data)
            },
            onOverflow: { recorder.recordOverflow(generation: $0) }
        )
        second.start()
        XCTAssertEqual(
            samples.withUnsafeBufferPointer { second.enqueue($0, sampleTime: 0) },
            .accepted
        )
        second.closeAndWait()

        XCTAssertEqual(recorder.audioGenerations, [41, 42])
        XCTAssertTrue(recorder.overflowGenerations.isEmpty)
    }

    @MainActor
    func testMicrophoneRingOverflowTriggersOneDurableInterrupt() async throws {
        let client = FakeNotebookCaptureClient(profile: .twoWay(notebookId: "notebook-a"))
        let audio = FakeNotebookCaptureAudioSource()
        let store = ActiveBilingualTranscriptStore(client: client, audioSource: audio)
        store.loadProfile(notebookId: "notebook-a")
        try await store.start(notebookId: "notebook-a")

        audio.emitOverflow()
        audio.emitOverflow()

        let interrupted = await waitUntil { client.interruptCount == 1 }
        XCTAssertTrue(interrupted)
        XCTAssertEqual(client.interruptCount, 1)
        XCTAssertEqual(client.lastInterruptReason, .localAudioOverflow)
        XCTAssertEqual(store.captureState, .interrupted)
        XCTAssertEqual(store.providerErrorType, "local_audio_overflow")
        XCTAssertEqual(audio.unsubscribeCount, 1)
    }

    @MainActor
    func testStopAdmitsFrameDeliveredByMicrophoneUnsubscribeFence() async throws {
        let client = FakeNotebookCaptureClient(profile: .twoWay(notebookId: "notebook-a"))
        let audio = FakeNotebookCaptureAudioSource()
        let store = ActiveBilingualTranscriptStore(client: client, audioSource: audio)
        store.loadProfile(notebookId: "notebook-a")
        try await store.start(notebookId: "notebook-a")
        audio.emitOnUnsubscribe = Data([0x01, 0x02])

        try await store.stop()

        XCTAssertEqual(audio.unsubscribeCount, 1)
        XCTAssertEqual(
            client.audioPushCount,
            1,
            "the Rust gate must remain open until the microphone worker fence drains"
        )
    }

    @MainActor
    func testPauseStopsTapBeforeClosingRustPushGateAndResumeUsesFreshSubscription() async throws {
        let client = FakeNotebookCaptureClient(profile: .twoWay(notebookId: "notebook-a"))
        let audio = FakeNotebookCaptureAudioSource()
        let store = ActiveBilingualTranscriptStore(client: client, audioSource: audio)
        try await store.start(notebookId: "notebook-a")
        audio.emitOnUnsubscribe = Data([0x11, 0x12])

        try await store.setPaused(true)

        XCTAssertEqual(client.audioPushCount, 1, "the tap drain must reach Rust before pause finalization")
        XCTAssertEqual(client.pauseCount, 1)
        XCTAssertEqual(audio.unsubscribeCount, 1)
        XCTAssertFalse(store.hasAudioSubscription)

        try await store.setPaused(false)

        XCTAssertEqual(client.pauseCount, 2)
        XCTAssertEqual(audio.subscribeCount, 2)
        XCTAssertTrue(store.hasAudioSubscription)
    }

    @MainActor
    func testBlockingPauseRequestLeavesMainActorResponsiveAndSettlesPaused() async throws {
        let client = FakeNotebookCaptureClient(profile: .twoWay(notebookId: "notebook-a"))
        let pauseController = BlockingNotebookPauseController()
        client.pauseController = pauseController
        let store = ActiveBilingualTranscriptStore(
            client: client,
            audioSource: FakeNotebookCaptureAudioSource()
        )
        try await store.start(notebookId: "notebook-a")

        let pauseTask = Task { @MainActor in
            try await store.setPaused(true)
        }
        let didEnterPauseRequest = await waitUntil { pauseController.isWaiting }
        XCTAssertTrue(didEnterPauseRequest)
        XCTAssertEqual(store.captureState, .draining)
        XCTAssertFalse(store.hasAudioSubscription)

        var heartbeat = false
        Task { @MainActor in heartbeat = true }
        let didReceiveHeartbeat = await waitUntil { heartbeat }
        XCTAssertTrue(
            didReceiveHeartbeat,
            "the MainActor must keep servicing UI work while pause waits on FFI"
        )

        pauseController.release()
        try await pauseTask.value

        XCTAssertEqual(store.captureState, .paused)
        XCTAssertFalse(store.hasAudioSubscription)
    }

    @MainActor
    func testPauseErrorReconcilesACommittedDurablePauseBeforeReopeningAudio() async throws {
        let client = FakeNotebookCaptureClient(profile: .twoWay(notebookId: "notebook-a"))
        client.pauseError = .ffiUnavailable
        client.sessionEventOverride = captureEvent(
            sessionId: "session-a",
            state: .paused,
            utterances: []
        )
        let audio = FakeNotebookCaptureAudioSource()
        let store = ActiveBilingualTranscriptStore(client: client, audioSource: audio)
        try await store.start(notebookId: "notebook-a")

        try await store.setPaused(true)

        XCTAssertEqual(client.pauseCount, 1)
        XCTAssertEqual(client.sessionEventCount, 1)
        XCTAssertEqual(store.captureState, .paused)
        XCTAssertEqual(audio.unsubscribeCount, 1)
        XCTAssertEqual(audio.subscribeCount, 1, "a committed pause must not reopen the microphone")
        XCTAssertFalse(store.hasAudioSubscription)
    }

    @MainActor
    func testResumeErrorReconcilesACommittedDurableResumeBeforeReopeningAudio() async throws {
        let client = FakeNotebookCaptureClient(profile: .twoWay(notebookId: "notebook-a"))
        let audio = FakeNotebookCaptureAudioSource()
        let store = ActiveBilingualTranscriptStore(client: client, audioSource: audio)
        try await store.start(notebookId: "notebook-a")
        try await store.setPaused(true)
        client.pauseError = .ffiUnavailable
        client.sessionEventOverride = captureEvent(
            sessionId: "session-a",
            state: .recording,
            utterances: []
        )

        try await store.setPaused(false)

        XCTAssertEqual(client.pauseCount, 2)
        XCTAssertEqual(client.sessionEventCount, 1)
        XCTAssertEqual(store.captureState, .recording)
        XCTAssertEqual(audio.subscribeCount, 2)
        XCTAssertTrue(store.hasAudioSubscription)
    }

    @MainActor
    func testStopPrioritizesOverflowReturnedBySynchronousMicrophoneDrain() async throws {
        let client = FakeNotebookCaptureClient(profile: .twoWay(notebookId: "notebook-a"))
        let audio = FakeNotebookCaptureAudioSource()
        audio.terminalReasonOnUnsubscribe = .localAudioOverflow
        let store = ActiveBilingualTranscriptStore(client: client, audioSource: audio)
        try await store.start(notebookId: "notebook-a")

        try await store.stop()

        XCTAssertEqual(client.stopCount, 0, "normal stop must not win after microphone overflow")
        XCTAssertEqual(client.interruptCount, 1)
        XCTAssertEqual(client.lastInterruptReason, .localAudioOverflow)
        XCTAssertEqual(store.captureState, .interrupted)
        XCTAssertEqual(store.providerErrorType, NotebookCaptureInterruptReason.localAudioOverflow.rawValue)
    }

    @MainActor
    func testAudioPushGateOverflowIsNonBlockingAndFencesAcceptedFrames() async {
        let controller = BlockingAudioPushController()
        let terminalReasons = LockedStrings()
        let gate = NotebookCaptureAudioPushGate(
            capacity: 2,
            push: { controller.push($0) },
            onTerminal: { terminalReasons.append($0) }
        )

        XCTAssertEqual(gate.submit(Data([1])), .accepted)
        XCTAssertTrue(controller.waitForFirstPush())
        XCTAssertEqual(gate.submit(Data([2])), .accepted)

        let startedAt = Date()
        XCTAssertEqual(gate.submit(Data([3])), .overflow)
        XCTAssertEqual(gate.submit(Data([4])), .overflow)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.05)
        XCTAssertEqual(terminalReasons.values, ["local_audio_overflow"])

        gate.close()
        controller.releaseFirstPush()
        await gate.fence()
        XCTAssertEqual(controller.completedCount, 2, "all pre-overflow accepted frames must reach Rust")
    }

    @MainActor
    func testCloseAndConcurrentTapNeverReportsFalseOverflow() async {
        let harnesses = (0..<256).map { _ in AudioGateCloseRaceHarness() }
        DispatchQueue.concurrentPerform(iterations: harnesses.count * 2) { index in
            let harness = harnesses[index / 2]
            if index.isMultiple(of: 2) {
                harness.submit()
            } else {
                harness.close()
            }
        }

        for harness in harnesses {
            await harness.fence()
            XCTAssertNotEqual(harness.result, .overflow)
            XCTAssertTrue(harness.terminalReasons.isEmpty)
        }
    }

    @MainActor
    func testPushFailureReasonIsVisibleBeforeFenceReturns() async {
        let terminalReasons = LockedStrings()
        let gate = NotebookCaptureAudioPushGate(
            capacity: 1,
            push: { _ in "persist capture audio: disk full" },
            onTerminal: { terminalReasons.append($0) }
        )

        XCTAssertEqual(gate.submit(Data([1])), .accepted)
        gate.close()
        await gate.fence()

        XCTAssertEqual(gate.terminalMessage, "persist capture audio: disk full")
        XCTAssertEqual(terminalReasons.values, ["persist capture audio: disk full"])
    }

    @MainActor
    func testPauseAndStopFenceBeforeCallingRustTransitions() async throws {
        let pauseController = BlockingAudioPushController()
        let pauseClient = FakeNotebookCaptureClient(profile: .twoWay(notebookId: "notebook-a"))
        pauseClient.audioPushHandler = { pauseController.push($0) }
        let pauseAudio = FakeNotebookCaptureAudioSource()
        let pauseStore = ActiveBilingualTranscriptStore(
            client: pauseClient,
            audioSource: pauseAudio,
            audioDrainWatchdogInterval: 0.01
        )
        pauseStore.loadProfile(notebookId: "notebook-a")
        try await pauseStore.start(notebookId: "notebook-a")
        pauseAudio.emit(Data([1]))
        XCTAssertTrue(pauseController.waitForFirstPush())

        let pauseTask = Task { try await pauseStore.setPaused(true) }
        let pauseDrainDelayed = await waitUntil { pauseStore.isAudioDrainDelayed }
        XCTAssertTrue(pauseDrainDelayed)
        XCTAssertEqual(pauseStore.captureState, .draining)
        XCTAssertTrue(pauseStore.isCaptureActive)
        XCTAssertFalse(pauseStore.isEditable)
        XCTAssertEqual(pauseClient.pauseCount, 0, "Rust pause must wait for the accepted audio fence")
        pauseController.releaseFirstPush()
        try await pauseTask.value
        XCTAssertEqual(pauseClient.pauseCount, 1)
        XCTAssertEqual(pauseStore.captureState, .paused)
        XCTAssertFalse(pauseStore.isAudioDrainDelayed)
        try await pauseStore.stop()

        let stopController = BlockingAudioPushController()
        let stopClient = FakeNotebookCaptureClient(profile: .twoWay(notebookId: "notebook-a"))
        stopClient.audioPushHandler = { stopController.push($0) }
        let stopAudio = FakeNotebookCaptureAudioSource()
        let stopStore = ActiveBilingualTranscriptStore(
            client: stopClient,
            audioSource: stopAudio,
            audioDrainWatchdogInterval: 0.01
        )
        stopStore.loadProfile(notebookId: "notebook-a")
        try await stopStore.start(notebookId: "notebook-a")
        stopAudio.emit(Data([1]))
        XCTAssertTrue(stopController.waitForFirstPush())

        let stopTask = Task { try await stopStore.stop() }
        let didReleaseStopAudio = await waitUntil { stopAudio.unsubscribeCount == 1 }
        XCTAssertTrue(didReleaseStopAudio)
        let stopDrainDelayed = await waitUntil { stopStore.isAudioDrainDelayed }
        XCTAssertTrue(stopDrainDelayed)
        XCTAssertEqual(stopStore.captureState, .draining)
        XCTAssertTrue(stopStore.isCaptureActive)
        XCTAssertFalse(stopStore.isEditable)
        XCTAssertEqual(stopClient.stopCount, 0, "Rust stop must wait for the accepted audio fence")
        do {
            try await stopStore.start(notebookId: "notebook-b")
            XCTFail("a slow drain must retain exclusive capture ownership")
        } catch {
            XCTAssertEqual(error as? NotebookCaptureClientError, .captureAlreadyActive)
        }
        XCTAssertEqual(stopClient.startCount, 1)
        XCTAssertEqual(stopAudio.prepareCount, 1)
        stopController.releaseFirstPush()
        try await stopTask.value
        XCTAssertEqual(stopClient.stopCount, 1)
        XCTAssertEqual(stopController.completedCount, 1)
        XCTAssertEqual(stopStore.captureState, .completed)
        XCTAssertFalse(stopStore.isAudioDrainDelayed)
    }

    @MainActor
    func testApplicationTerminationFencesAcceptedAudioBeforeCompletingCapture() async throws {
        let controller = BlockingAudioPushController()
        let client = FakeNotebookCaptureClient(profile: .twoWay(notebookId: "notebook-a"))
        client.audioPushHandler = { controller.push($0) }
        let audio = FakeNotebookCaptureAudioSource()
        let store = ActiveBilingualTranscriptStore(
            client: client,
            audioSource: audio,
            audioDrainWatchdogInterval: 0.01
        )
        try await store.start(notebookId: "notebook-a")
        audio.emit(Data([0x41, 0x42]))
        XCTAssertTrue(controller.waitForFirstPush())

        let termination = Task { await store.prepareForApplicationTermination() }
        let didReleaseMicrophone = await waitUntil { audio.unsubscribeCount == 1 }
        XCTAssertTrue(didReleaseMicrophone)
        XCTAssertEqual(client.stopCount, 0, "termination must not close Rust before accepted audio drains")
        XCTAssertTrue(store.requiresApplicationTerminationPreparation)

        controller.releaseFirstPush()
        await termination.value

        XCTAssertEqual(controller.completedCount, 1)
        XCTAssertEqual(client.stopCount, 1)
        XCTAssertFalse(store.hasAudioSubscription)
        XCTAssertFalse(store.requiresApplicationTerminationPreparation)
        XCTAssertEqual(store.captureState, .completed)
    }

    @MainActor
    func testTerminalCallbackBeforeFenceWaitsForAcceptedAudioWithoutOpeningNextRun() async throws {
        let controller = BlockingAudioPushController()
        let client = FakeNotebookCaptureClient(profile: .twoWay(notebookId: "notebook-a"))
        client.audioPushHandler = { controller.push($0) }
        let audio = FakeNotebookCaptureAudioSource()
        let store = ActiveBilingualTranscriptStore(
            client: client,
            audioSource: audio,
            audioDrainWatchdogInterval: 0.01
        )
        try await store.start(notebookId: "notebook-a")
        audio.emit(Data([1]))
        XCTAssertTrue(controller.waitForFirstPush())

        let stopTask = Task { try await store.stop() }
        let didEnterDrain = await waitUntil { store.isAudioDrainDelayed }
        XCTAssertTrue(didEnterDrain)
        client.emitCaptureEvent(
            captureEvent(sessionId: "session-a", state: .completed, utterances: []),
            callbackSessionId: "session-a"
        )

        XCTAssertEqual(store.captureState, .draining, "terminal UI waits for the local audio fence")
        XCTAssertTrue(store.isCaptureActive)
        XCTAssertFalse(store.isEditable)
        XCTAssertEqual(controller.completedCount, 0)
        XCTAssertEqual(client.stopCount, 0)
        do {
            try await store.start(notebookId: "notebook-b")
            XCTFail("a pending terminal callback must not release the drain lease")
        } catch {
            XCTAssertEqual(error as? NotebookCaptureClientError, .captureAlreadyActive)
        }

        controller.releaseFirstPush()
        try await stopTask.value

        XCTAssertEqual(controller.completedCount, 1)
        XCTAssertEqual(store.captureState, .completed)
        XCTAssertFalse(store.isCaptureActive)
        XCTAssertFalse(store.isAudioDrainDelayed)
        XCTAssertEqual(client.stopCount, 0, "the authoritative callback already completed the run")
    }

    @MainActor
    func testFirstRustPushFailureUsesDurableSnapshotAndReleasesMicrophoneOnce() async throws {
        let client = FakeNotebookCaptureClient(profile: .twoWay(notebookId: "notebook-a"))
        client.audioPushFailureMessage = "persist capture audio: disk full"
        let audio = FakeNotebookCaptureAudioSource()
        let store = ActiveBilingualTranscriptStore(client: client, audioSource: audio)
        store.loadProfile(notebookId: "notebook-a")
        try await store.start(notebookId: "notebook-a")

        audio.emit(Data([1, 2]))
        let didLoadDurableEvent = await waitUntil { client.sessionEventCount == 1 }
        XCTAssertTrue(didLoadDurableEvent)
        XCTAssertEqual(client.interruptCount, 0, "Rust already interrupted before returning push failure")
        XCTAssertEqual(audio.unsubscribeCount, 1)
        XCTAssertFalse(store.hasAudioSubscription)
        XCTAssertEqual(store.captureState, .interrupted)
        XCTAssertEqual(store.providerErrorType, "local_audio_persistence")
    }

    @MainActor
    func testRustPushFailureExplicitlyInterruptsWhenDurableSnapshotIsStillActive() async throws {
        let client = FakeNotebookCaptureClient(profile: .twoWay(notebookId: "notebook-a"))
        client.audioPushFailureMessage = "persist capture audio progress: database locked"
        client.sessionEventOverride = NotebookCaptureEventDTO(
            sessionId: "session-a",
            captureState: .recording,
            remoteHealth: .connecting,
            projectionState: .pending,
            utterances: [],
            translationCues: [],
            laneHealth: [],
            contextReceipt: nil,
            providerErrorType: nil,
            providerRequestId: nil,
            mode: .twoWay,
            languageA: "en",
            languageB: "zh",
            leftLanguage: "en",
            rightLanguage: "zh",
            selectedLanguages: ["en", "zh"],
            commonCaptionLanguage: nil
        )
        let audio = FakeNotebookCaptureAudioSource()
        let store = ActiveBilingualTranscriptStore(client: client, audioSource: audio)
        store.loadProfile(notebookId: "notebook-a")
        try await store.start(notebookId: "notebook-a")

        audio.emit(Data([1, 2]))
        let didInterrupt = await waitUntil { client.interruptCount == 1 }

        XCTAssertTrue(didInterrupt)
        XCTAssertEqual(client.sessionEventCount, 1)
        XCTAssertEqual(client.lastInterruptReason, .localAudioUnavailable)
        XCTAssertEqual(audio.unsubscribeCount, 1)
        XCTAssertFalse(store.hasAudioSubscription)
        XCTAssertEqual(store.captureState, .interrupted)
    }

    @MainActor
    func testRustTerminalCallbackImmediatelyReleasesMicrophoneWithoutDuplicateCleanup() async throws {
        let client = FakeNotebookCaptureClient(profile: .twoWay(notebookId: "notebook-a"))
        let audio = FakeNotebookCaptureAudioSource()
        let store = ActiveBilingualTranscriptStore(client: client, audioSource: audio)
        store.loadProfile(notebookId: "notebook-a")
        try await store.start(notebookId: "notebook-a")

        let terminal = NotebookCaptureEventDTO(
            sessionId: "session-a",
            captureState: .interrupted,
            remoteHealth: .off,
            projectionState: .pending,
            utterances: [],
            translationCues: [],
            laneHealth: [],
            contextReceipt: nil,
            providerErrorType: "local_audio_persistence",
            providerRequestId: nil,
            mode: .twoWay,
            languageA: "en",
            languageB: "zh",
            leftLanguage: "en",
            rightLanguage: "zh",
            selectedLanguages: ["en", "zh"],
            commonCaptionLanguage: nil
        )
        client.emitCaptureEvent(terminal)
        client.emitCaptureEvent(terminal)

        XCTAssertEqual(audio.unsubscribeCount, 1)
        XCTAssertFalse(store.hasAudioSubscription)
        XCTAssertEqual(store.captureState, .interrupted)
        XCTAssertEqual(client.interruptCount, 0)
    }

    @MainActor
    func testLocalQueueOverflowInterruptsOnlyAfterAcceptedFramesDrain() async throws {
        let controller = BlockingAudioPushController()
        let client = FakeNotebookCaptureClient(profile: .twoWay(notebookId: "notebook-a"))
        client.audioPushHandler = { controller.push($0) }
        let audio = FakeNotebookCaptureAudioSource()
        let store = ActiveBilingualTranscriptStore(
            client: client,
            audioSource: audio,
            audioQueueCapacity: 2
        )
        store.loadProfile(notebookId: "notebook-a")
        try await store.start(notebookId: "notebook-a")

        audio.emit(Data([1]))
        XCTAssertTrue(controller.waitForFirstPush())
        audio.emit(Data([2]))
        audio.emit(Data([3]))

        let didReleaseOverflowAudio = await waitUntil { audio.unsubscribeCount == 1 }
        XCTAssertTrue(didReleaseOverflowAudio)
        XCTAssertEqual(store.captureState, .draining)
        XCTAssertTrue(store.isCaptureActive)
        XCTAssertFalse(store.isEditable)
        XCTAssertEqual(client.interruptCount, 0, "overflow interrupt must wait for the fence")
        controller.releaseFirstPush()
        let didPersistOverflowInterrupt = await waitUntil { client.interruptCount == 1 }
        XCTAssertTrue(didPersistOverflowInterrupt)
        XCTAssertEqual(controller.completedCount, 2)
        XCTAssertEqual(client.lastInterruptReason, .localAudioOverflow)
        XCTAssertEqual(store.providerErrorType, "local_audio_overflow")
    }

    @MainActor
    func testDefaultAudioQueueAbsorbsTwelveSecondsOfTransientWriterStall() async throws {
        let controller = BlockingAudioPushController()
        let client = FakeNotebookCaptureClient(profile: .twoWay(notebookId: "notebook-a"))
        client.audioPushHandler = { controller.push($0) }
        let audio = FakeNotebookCaptureAudioSource()
        let store = ActiveBilingualTranscriptStore(client: client, audioSource: audio)
        try await store.start(notebookId: "notebook-a")

        // Production microphone callbacks arrive about ten times per second.
        // Keep the first durable write blocked while 128 callbacks arrive so a
        // transient fsync or UI scheduling stall cannot terminate local audio.
        let callbackCount = 128
        audio.emit(Data([0]))
        XCTAssertTrue(controller.waitForFirstPush())
        for value in 1..<callbackCount {
            audio.emit(Data([UInt8(truncatingIfNeeded: value)]))
        }

        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(audio.unsubscribeCount, 0)
        XCTAssertEqual(client.interruptCount, 0)
        XCTAssertEqual(store.captureState, .recording)

        controller.releaseFirstPush()
        let drained = await waitUntil(timeout: 2) {
            controller.completedCount == callbackCount
        }
        XCTAssertTrue(drained)
        try await store.stop()
        XCTAssertEqual(store.captureState, .completed)
    }

    @MainActor
    func testResumeGateFailureCannotLeaveRustRecordingWithClosedAudio() async throws {
        let client = FakeNotebookCaptureClient(profile: .twoWay(notebookId: "notebook-a"))
        let store = ActiveBilingualTranscriptStore(
            client: client,
            audioSource: FakeNotebookCaptureAudioSource()
        )
        store.loadProfile(notebookId: "notebook-a")
        try await store.start(notebookId: "notebook-a")
        try await store.setPaused(true)
        store.abortAudioGateForTesting()

        do {
            try await store.setPaused(false)
            XCTFail("resume must fail after the local gate becomes terminal")
        } catch {
            XCTAssertEqual(error as? NotebookCaptureClientError, .captureNotActive)
        }
        XCTAssertEqual(client.pauseCount, 2, "Rust resume was attempted")
        XCTAssertEqual(client.interruptCount, 1, "failed reopen must terminate durable Recording")
        XCTAssertEqual(client.lastInterruptReason, .localAudioUnavailable)
        XCTAssertEqual(store.captureState, .interrupted)
        XCTAssertFalse(store.hasAudioSubscription)
    }

    @MainActor
    func testAudiencePlacementNeverFilesAnIdentifiedLineUnderAnotherLanguage() {
        let line = { (source: String, provisional: String?) -> NotebookCaptureUtteranceDTO in
            var value = NotebookCaptureUtteranceDTO(
                id: "utt-1",
                sessionId: "session-a",
                sequence: 1,
                revision: 1,
                sourceLanguage: source,
                sourceText: "des mots",
                sourceStartMs: 100,
                sourceEndMs: 700,
                translatedLanguage: nil,
                translatedText: nil,
                completion: "complete",
                alignment: "source_only"
            )
            value.provisionalSourceLanguage = provisional
            return value
        }
        let place = { (utterance: NotebookCaptureUtteranceDTO) -> String? in
            NotebookCaptureHistoryPolicy.audienceSourcePlacement(
                for: utterance,
                selectedLanguages: ["zh", "en", "th"],
                lastIdentifiedSourceLanguage: "zh"
            )
        }

        // The provider says French. French has no column, so the honest
        // answer is no column — not the previous speaker's Chinese.
        XCTAssertNil(place(line("und", "fr")))
        // A committed identity outside the selection behaves the same way.
        XCTAssertNil(place(line("fr", nil)))
        // A provisional hint inside the selection still places immediately.
        XCTAssertEqual(place(line("und", "en")), "en")
        // Only a line with no identification at all borrows the last one.
        XCTAssertEqual(place(line("und", nil)), "zh")
    }

    @MainActor
    func testTwoLanguageProjectionMapsByLanguageWithoutRewritingUtterance() async throws {
        let utterance = NotebookCaptureUtteranceDTO(
            id: "utt-1",
            sessionId: "session-a",
            sequence: 1,
            revision: 4,
            sourceLanguage: "zh-CN",
            sourceText: "你好",
            sourceStartMs: 100,
            sourceEndMs: 700,
            translatedLanguage: "en",
            translatedText: "Hello",
            completion: "complete",
            alignment: "response_order"
        )
        let client = FakeNotebookCaptureClient(
            profile: .twoWay(notebookId: "notebook-a"),
            startUtterances: [utterance]
        )
        let store = ActiveBilingualTranscriptStore(
            client: client,
            audioSource: FakeNotebookCaptureAudioSource()
        )
        store.loadProfile(notebookId: "notebook-a")
        try await store.start(notebookId: "notebook-a")

        let projection = store.projection(for: utterance)
        XCTAssertEqual(projection.lanes.map(\.language), ["en", "zh"])
        XCTAssertEqual(projection.lanes.map(\.text), ["Hello", "你好"])
        XCTAssertEqual(
            store.utterances.first,
            utterance,
            "display projection must not rewrite capture data"
        )
    }

    func testRealtimeAutoscrollTracksInPlaceGrowthWithoutChangingRowIdentity() {
        func utterance(
            id: String,
            sequence: UInt64,
            revision: UInt64,
            text: String
        ) -> NotebookCaptureUtteranceDTO {
            NotebookCaptureUtteranceDTO(
                id: id,
                sessionId: "session-a",
                sequence: sequence,
                revision: revision,
                sourceLanguage: "en",
                sourceText: text,
                sourceStartMs: 0,
                sourceEndMs: 500,
                translatedLanguage: "zh",
                translatedText: "\u{4f60}\u{597d}",
                completion: "partial",
                alignment: "response_order"
            )
        }

        let firstRevision = utterance(id: "utt-1", sequence: 1, revision: 1, text: "Hello")
        let laterRevision = utterance(
            id: "utt-1",
            sequence: 1,
            revision: 639,
            text: String(repeating: "A growing utterance. ", count: 40)
        )
        let nextUtterance = utterance(id: "utt-2", sequence: 2, revision: 1, text: "Next")
        let firstSignal = NotebookRealtimeAutoscrollPolicy.signal(in: [firstRevision])
        let laterSignal = NotebookRealtimeAutoscrollPolicy.signal(in: [laterRevision])

        XCTAssertEqual(firstSignal?.utteranceID, laterSignal?.utteranceID)
        XCTAssertNotEqual(firstSignal, laterSignal)
        XCTAssertEqual(
            NotebookRealtimeAutoscrollPolicy.signal(
                in: [laterRevision, nextUtterance]
            )?.utteranceID,
            "utt-2"
        )

        let firstCue = NotebookCaptureTranslationCueDTO(
            targetLanguage: "th",
            groupEpoch: 1,
            providerSequence: 4,
            sourceLanguage: "en",
            sourceStartMs: 0,
            sourceEndMs: 500,
            text: "สวัสดี",
            completion: "partial",
            withdrawn: false,
            revision: 1
        )
        let revisedCue = NotebookCaptureTranslationCueDTO(
            targetLanguage: firstCue.targetLanguage,
            groupEpoch: firstCue.groupEpoch,
            providerSequence: firstCue.providerSequence,
            sourceLanguage: firstCue.sourceLanguage,
            sourceStartMs: firstCue.sourceStartMs,
            sourceEndMs: firstCue.sourceEndMs,
            text: "สวัสดีครับ",
            completion: "partial",
            withdrawn: false,
            revision: 2
        )
        XCTAssertNotEqual(
            NotebookRealtimeAutoscrollPolicy.signal(in: [], cues: [firstCue]),
            NotebookRealtimeAutoscrollPolicy.signal(in: [], cues: [revisedCue]),
            "a cue-only live frame must advance the tail signal"
        )
        XCTAssertNil(NotebookRealtimeAutoscrollPolicy.signal(in: [], cues: []))
    }

    func testRealtimeFollowPausesForManualScrollAndKeepsFollowingContentGrowth() {
        let liveEdge = NotebookRealtimeScrollMetrics(offsetY: 900, distanceFromBottom: 20)
        let contentGrowth = NotebookRealtimeScrollMetrics(offsetY: 900, distanceFromBottom: 180)
        let manualScroll = NotebookRealtimeScrollMetrics(offsetY: 620, distanceFromBottom: 460)

        XCTAssertTrue(NotebookRealtimeFollowPolicy.reconciledFollowing(
            wasFollowing: true,
            previous: liveEdge,
            current: contentGrowth
        ))
        XCTAssertFalse(NotebookRealtimeFollowPolicy.reconciledFollowing(
            wasFollowing: true,
            previous: contentGrowth,
            current: manualScroll
        ))
        XCTAssertTrue(NotebookRealtimeFollowPolicy.reconciledFollowing(
            wasFollowing: false,
            previous: manualScroll,
            current: liveEdge
        ))
    }

    @MainActor
    func testEmptyFullSnapshotClearsRecentTranscriptPresentation() async throws {
        MenuBarRuntimeStore.shared.resetForTesting()
        defer { MenuBarRuntimeStore.shared.resetForTesting() }
        let client = FakeNotebookCaptureClient(
            profile: .twoWay(notebookId: "notebook-a"),
            startUtterances: [.sample]
        )
        let store = ActiveBilingualTranscriptStore(
            client: client,
            audioSource: FakeNotebookCaptureAudioSource()
        )
        store.loadProfile(notebookId: "notebook-a")
        try await store.start(notebookId: "notebook-a")

        client.emitCaptureEvent(captureEvent(
            sessionId: "session-a",
            state: .recording,
            utterances: [.sample],
            eventRevision: 1,
            isFullSnapshot: false
        ))
        XCTAssertFalse(MenuBarRuntimeStore.shared.cachedRecentLines.isEmpty)

        client.emitCaptureEvent(captureEvent(
            sessionId: "session-a",
            state: .recording,
            utterances: [],
            eventRevision: 2,
            isFullSnapshot: true
        ))

        XCTAssertTrue(MenuBarRuntimeStore.shared.cachedRecentLines.isEmpty)
    }

    @MainActor
    func testFiveThousandRowFullSnapshotPublishesOneAtomicReplacement() async throws {
        let client = FakeNotebookCaptureClient(profile: .twoWay(notebookId: "notebook-a"))
        let store = ActiveBilingualTranscriptStore(
            client: client,
            audioSource: FakeNotebookCaptureAudioSource()
        )
        try await store.start(notebookId: "notebook-a")

        var rows = (0..<5_000).map { index in
            var row = NotebookCaptureUtteranceDTO.sample.replacingIdentity(
                id: "snapshot-\(index)",
                sequence: UInt64(index)
            )
            // Force the cached fallback to scan a long unidentified tail once
            // at snapshot install time; rendering must reuse that result.
            row.sourceLanguage = index == 0 ? "zh" : "und"
            row.sourceText = "row \(index)"
            return row
        }
        var newerDuplicate = rows[2_500]
        newerDuplicate.revision += 1
        newerDuplicate.sourceText = "newer duplicate"
        var equalRevisionDuplicate = newerDuplicate
        equalRevisionDuplicate.sourceText = "equal revision wins last"
        var staleDuplicate = rows[2_500]
        staleDuplicate.sourceText = "stale duplicate"
        rows.append(contentsOf: [newerDuplicate, equalRevisionDuplicate, staleDuplicate])
        var publishedCounts: [Int] = []
        let observation = store.$utterances.dropFirst().sink { rows in
            publishedCounts.append(rows.count)
        }

        client.emitCaptureEvent(captureEvent(
            sessionId: "session-a",
            state: .recording,
            utterances: rows,
            eventRevision: 1,
            isFullSnapshot: true
        ))

        XCTAssertEqual(store.utterances.count, 5_000)
        XCTAssertEqual(store.utterances.first?.sourceText, "row 0")
        XCTAssertEqual(store.utterances[2_500].sourceText, "equal revision wins last")
        XCTAssertEqual(store.utterances.last?.sourceText, "row 4999")
        var pending = NotebookCaptureUtteranceDTO.sample.replacingIdentity(
            id: "pending",
            sequence: 5_000
        )
        pending.sourceLanguage = "und"
        pending.provisionalSourceLanguage = nil
        XCTAssertEqual(store.makeAudienceSourcePlacement()(pending), "zh")
        XCTAssertEqual(
            publishedCounts,
            [5_000],
            "an authoritative repair must never publish a transient empty canvas"
        )
        withExtendedLifetime(observation) {}
        store.resetForTesting()
    }

    func testRealtimeRunSelectionPrefersFocusThenActiveThenLatestAndPreservesClicks() {
        let first = NotebookCaptureHistoryRunDTO.fixture(
            sessionId: "session-a",
            createdAt: "2001-01-02T08:00:00Z"
        )
        let latest = NotebookCaptureHistoryRunDTO.fixture(
            sessionId: "session-b",
            createdAt: "2001-01-02T09:00:00Z"
        )
        let runs = [first, latest]

        XCTAssertEqual(
            NotebookRealtimeRunSelectionPolicy.initialSessionID(
                runs: runs,
                requestedSessionID: "session-a",
                activeSessionID: "session-b"
            ),
            "session-a"
        )
        XCTAssertEqual(
            NotebookRealtimeRunSelectionPolicy.initialSessionID(
                runs: runs,
                requestedSessionID: nil,
                activeSessionID: "session-b"
            ),
            "session-b"
        )
        XCTAssertEqual(
            NotebookRealtimeRunSelectionPolicy.initialSessionID(
                runs: runs,
                requestedSessionID: nil,
                activeSessionID: nil
            ),
            "session-b"
        )
        XCTAssertEqual(
            NotebookRealtimeRunSelectionPolicy.reconciledSessionID(
                currentSessionID: "session-a",
                runs: runs,
                requestedSessionID: nil,
                activeSessionID: "session-b"
            ),
            "session-a",
            "a rail click remains selected while that run is still visible"
        )
    }

    func testNotebookHistoryOrdersEveryRunAndKeepsZeroTranscriptRecordings() {
        let later = NotebookCaptureHistoryRunDTO.fixture(
            sessionId: "session-b",
            createdAt: "2001-01-02T09:15:00Z",
            utterances: [.sample]
        )
        let emptyEarlier = NotebookCaptureHistoryRunDTO.fixture(
            sessionId: "session-a",
            createdAt: "2001-01-02T08:00:00Z",
            utterances: []
        )
        let tied = NotebookCaptureHistoryRunDTO.fixture(
            sessionId: "session-c",
            createdAt: later.createdAt,
            utterances: []
        )

        let ordered = NotebookCaptureHistoryPolicy.orderedRuns([tied, later, emptyEarlier])

        XCTAssertEqual(ordered.map(\.sessionId), ["session-a", "session-b", "session-c"])
        XCTAssertEqual(ordered.count, 3)
        XCTAssertTrue(ordered[0].utterances.isEmpty)
        XCTAssertTrue(ordered[2].utterances.isEmpty)
    }

    func testNotebookHistoryParsesEachMixedTimestampOnceBeforeSorting() {
        let first = NotebookCaptureHistoryRunDTO.fixture(
            sessionId: "session-a",
            createdAt: "2001-01-02T08:00:00Z"
        )
        let fractional = NotebookCaptureHistoryRunDTO.fixture(
            sessionId: "session-b",
            createdAt: "2001-01-02T08:00:00.500Z"
        )
        let later = NotebookCaptureHistoryRunDTO.fixture(
            sessionId: "session-c",
            createdAt: "2001-01-02T09:00:00+00:00"
        )
        let malformed = NotebookCaptureHistoryRunDTO.fixture(
            sessionId: "session-d",
            createdAt: "malformed-timestamp"
        )

        XCTAssertEqual(
            NotebookCaptureHistoryPolicy.orderedRuns([malformed, later, fractional, first])
                .map(\.sessionId),
            ["session-a", "session-b", "session-c", "session-d"]
        )
    }

    @MainActor
    func testHistoryStoreQueriesNotebookRatherThanFocusedSessionAndKeepsDisplayTransient() async {
        let runs = [
            NotebookCaptureHistoryRunDTO.fixture(
                sessionId: "session-a",
                createdAt: "2001-01-02T08:00:00Z"
            ),
            NotebookCaptureHistoryRunDTO.fixture(
                sessionId: "session-b",
                createdAt: "2001-01-02T09:00:00Z"
            ),
        ]
        let client = FakeNotebookCaptureClient(
            profile: .twoWay(notebookId: "notebook-a"),
            historyRuns: Array(runs.reversed())
        )
        let store = NotebookCaptureHistoryStore(client: client)

        await store.load(notebookId: "notebook-a")

        XCTAssertEqual(client.historyNotebookIds, ["notebook-a"])
        XCTAssertEqual(store.runs.map(\.sessionId), ["session-a", "session-b"])
        XCTAssertEqual(store.presentationMode(for: "notebook-a"), .bilingualColumns)

        store.setPresentationMode(.sourceTimeline, for: "notebook-a")

        XCTAssertEqual(store.presentationMode(for: "notebook-a"), .sourceTimeline)
        XCTAssertEqual(store.presentationMode(for: "notebook-b"), .sourceTimeline)
        XCTAssertEqual(client.profileUpdateCount, 0, "display changes must never write capture settings")
    }

    @MainActor
    func testHistoryStoreLoadsSummaryCatalogThenHydratesOnlySelectedTranscript() async {
        var firstUtterance = NotebookCaptureUtteranceDTO.sample
        firstUtterance = NotebookCaptureUtteranceDTO(
            id: firstUtterance.id,
            sessionId: "session-a",
            sequence: firstUtterance.sequence,
            revision: firstUtterance.revision,
            sourceLanguage: firstUtterance.sourceLanguage,
            sourceText: firstUtterance.sourceText,
            sourceStartMs: firstUtterance.sourceStartMs,
            sourceEndMs: firstUtterance.sourceEndMs,
            translatedLanguage: firstUtterance.translatedLanguage,
            translatedText: firstUtterance.translatedText,
            completion: firstUtterance.completion,
            alignment: firstUtterance.alignment,
            languageVariants: firstUtterance.languageVariants,
            sourceProjectionRevision: firstUtterance.sourceProjectionRevision,
            sourceEditRevision: firstUtterance.sourceEditRevision
        )
        let secondUtterance = NotebookCaptureUtteranceDTO(
            id: "utterance-b",
            sessionId: "session-b",
            sequence: 1,
            revision: 1,
            sourceLanguage: "en",
            sourceText: "Second recording",
            sourceStartMs: 0,
            sourceEndMs: 500,
            translatedLanguage: "zh",
            translatedText: "第二次录音",
            completion: "complete",
            alignment: "response_order"
        )
        let runs = [
            NotebookCaptureHistoryRunDTO.fixture(
                sessionId: "session-a",
                createdAt: "2001-01-02T08:00:00Z",
                utterances: [firstUtterance]
            ),
            NotebookCaptureHistoryRunDTO.fixture(
                sessionId: "session-b",
                createdAt: "2001-01-02T09:00:00Z",
                utterances: [secondUtterance]
            ),
        ]
        let client = FakeNotebookCaptureClient(
            profile: .twoWay(notebookId: "notebook-a"),
            startUtterances: [firstUtterance],
            historyRuns: runs,
            historySummariesOmitUtterances: true
        )
        let store = NotebookCaptureHistoryStore(client: client)

        await store.load(notebookId: "notebook-a")

        XCTAssertTrue(store.runs.allSatisfy(\.utterances.isEmpty))
        XCTAssertEqual(store.transcriptLoadState(sessionId: "session-a"), .unloaded)
        XCTAssertEqual(client.listUtterancesCount, 0)
        XCTAssertEqual(
            client.listSessionSpeakersCount,
            0,
            "the summary rail must not issue one speaker query per historical run"
        )

        await store.loadTranscript(sessionId: "session-a")

        XCTAssertEqual(store.runs[0].utterances, [firstUtterance])
        XCTAssertTrue(store.runs[1].utterances.isEmpty)
        XCTAssertEqual(store.transcriptLoadState(sessionId: "session-a"), .loaded)
        XCTAssertEqual(client.listUtterancesCount, 1)
        XCTAssertEqual(client.listSessionSpeakersCount, 1)

        await store.loadTranscript(sessionId: "session-a")
        XCTAssertEqual(client.listUtterancesCount, 1, "a hydrated run is not decoded twice")

        client.listUtterancesOverride = [secondUtterance]
        store.retainOnlyTranscript(sessionId: "session-b")
        await store.loadTranscript(sessionId: "session-b")

        XCTAssertTrue(store.runs[0].utterances.isEmpty, "the prior transcript is evicted")
        XCTAssertEqual(store.runs[1].utterances, [secondUtterance])
        XCTAssertEqual(store.transcriptLoadState(sessionId: "session-a"), .unloaded)
        XCTAssertEqual(store.transcriptLoadState(sessionId: "session-b"), .loaded)
        XCTAssertEqual(client.listSessionSpeakersCount, 2)

        await store.load(notebookId: "notebook-a")
        XCTAssertTrue(
            store.runs.allSatisfy(\.utterances.isEmpty),
            "a catalog refresh invalidates cached transcript text"
        )
    }

    @MainActor
    func testHistoryCatalogLoadLeavesMainActorResponsiveAndKeepsSummariesLightweight() async {
        let runs = (0..<100).map { index in
            NotebookCaptureHistoryRunDTO.fixture(
                sessionId: "session-\(index)",
                createdAt: String(format: "2001-01-02T08:%02d:00Z", index % 60),
                utterances: [.sample]
            )
        }
        let controller = BlockingNotebookCatalogLoadController()
        let client = FakeNotebookCaptureClient(
            profile: .twoWay(notebookId: "notebook-a"),
            historyRuns: runs,
            historySummariesOmitUtterances: true
        )
        client.catalogLoadController = controller
        let store = NotebookCaptureHistoryStore(client: client)

        let loadTask = Task { await store.load(notebookId: "notebook-a") }
        let didSuspend = await waitUntil { controller.isWaiting }
        XCTAssertTrue(didSuspend)

        var heartbeat = false
        Task { @MainActor in heartbeat = true }
        let didReceiveHeartbeat = await waitUntil { heartbeat }
        XCTAssertTrue(
            didReceiveHeartbeat,
            "a catalog FFI read must suspend instead of blocking the MainActor"
        )
        XCTAssertEqual(client.listSessionSpeakersCount, 0)

        controller.release()
        await loadTask.value

        XCTAssertEqual(store.runs.count, 100)
        XCTAssertTrue(store.runs.allSatisfy(\.utterances.isEmpty))
        XCTAssertEqual(client.listSessionSpeakersCount, 0)
    }

    @MainActor
    func testHistoryStoreRejectsAStaleTranscriptAfterCatalogSwitch() async {
        let utterance = NotebookCaptureUtteranceDTO.sample
        let firstRun = NotebookCaptureHistoryRunDTO.fixture(
            sessionId: utterance.sessionId,
            createdAt: "2001-01-02T08:00:00Z",
            utterances: [utterance]
        )
        let nextRun = NotebookCaptureHistoryRunDTO.fixture(
            sessionId: "session-b",
            createdAt: "2001-01-02T09:00:00Z"
        )
        let controller = BlockingNotebookUtteranceLoadController()
        let client = FakeNotebookCaptureClient(
            profile: .twoWay(notebookId: "notebook-a"),
            startUtterances: [utterance],
            historyRuns: [firstRun],
            historySummariesOmitUtterances: true
        )
        client.utteranceLoadController = controller
        let store = NotebookCaptureHistoryStore(client: client)
        await store.load(notebookId: "notebook-a")

        let task = Task { await store.loadTranscript(sessionId: utterance.sessionId) }
        let didStartLoading = await waitUntil { controller.isWaiting }
        XCTAssertTrue(didStartLoading)
        XCTAssertEqual(store.transcriptLoadState(sessionId: utterance.sessionId), .loading)

        client.historyRuns = [nextRun]
        await store.load(notebookId: "notebook-b")
        controller.release()
        await task.value

        XCTAssertEqual(store.loadedNotebookId, "notebook-b")
        XCTAssertEqual(store.runs.map(\.sessionId), ["session-b"])
        XCTAssertTrue(store.runs[0].utterances.isEmpty)
        XCTAssertEqual(store.transcriptLoadState(sessionId: utterance.sessionId), .unloaded)
    }

    @MainActor
    func testHistoryStoreUsesLaneWatermarksWhenTerminalProjectionHasFailed() async throws {
        var utterance = NotebookCaptureUtteranceDTO.sample
        utterance.completion = "partial"
        utterance.sourceProjectionRevision = 0
        utterance.languageVariants = [
            NotebookCaptureLanguageVariantDTO(
                language: "zh",
                role: "translation",
                text: "你好",
                state: "ready",
                completion: "complete",
                projectionRevision: 1
            ),
            NotebookCaptureLanguageVariantDTO(
                language: "th",
                role: "translation",
                text: "สวัสดี",
                state: "ready",
                completion: "complete",
                projectionRevision: 2
            ),
        ]
        let run = NotebookCaptureHistoryRunDTO.fixture(
            sessionId: "session-a",
            createdAt: "2001-01-02T08:00:00Z",
            projection: .failed,
            utterances: [utterance],
            selectedLanguages: ["en", "zh", "th"],
            realtimeLoroAppliedRevision: 1
        )
        let client = FakeNotebookCaptureClient(
            profile: .twoWay(notebookId: "notebook-a"),
            startUtterances: [utterance],
            historyRuns: [run]
        )
        let store = NotebookCaptureHistoryStore(client: client)
        await store.load(notebookId: "notebook-a")

        do {
            try await store.replaceLane(
                utteranceId: utterance.id,
                language: "en",
                text: "source is still partial"
            )
            XCTFail("partial source must remain locked")
        } catch {
            XCTAssertEqual(error as? NotebookCaptureClientError, .projectionLocked)
        }
        try await store.replaceLane(
            utteranceId: utterance.id,
            language: "zh",
            text: "已编辑"
        )
        do {
            try await store.replaceLane(
                utteranceId: utterance.id,
                language: "th",
                text: "ยังล็อกอยู่"
            )
            XCTFail("a lane beyond the applied watermark must remain locked")
        } catch {
            XCTAssertEqual(error as? NotebookCaptureClientError, .projectionLocked)
        }

        XCTAssertEqual(
            client.lastReplaceExpectedRevision,
            utterance.laneEditRevision(language: "zh")
        )
    }

    @MainActor
    func testHistoryStoreEditsDurableFinalSourceOutsideSelectedLanguages() async throws {
        var utterance = NotebookCaptureUtteranceDTO.sample
        utterance.sourceLanguage = "ja"
        utterance.sourceText = "こんにちは"
        utterance.translatedLanguage = nil
        utterance.translatedText = nil
        utterance.languageVariants = []
        utterance.sourceProjectionRevision = 1
        let run = NotebookCaptureHistoryRunDTO.fixture(
            sessionId: "session-a",
            createdAt: "2001-01-02T08:00:00Z",
            projection: .failed,
            utterances: [utterance],
            selectedLanguages: ["en", "zh"],
            realtimeLoroAppliedRevision: 1
        )
        let client = FakeNotebookCaptureClient(
            profile: .twoWay(notebookId: "notebook-a"),
            startUtterances: [utterance],
            historyRuns: [run]
        )
        let store = NotebookCaptureHistoryStore(client: client)
        await store.load(notebookId: "notebook-a")

        let laneProjection = NotebookCaptureHistoryPolicy.laneProjection(
            for: utterance,
            selectedLanguages: ["en", "zh"],
            commonCaptionLanguage: nil
        )
        XCTAssertEqual(laneProjection.unselectedLanguageText, "こんにちは")
        XCTAssertTrue(utterance.isLoroEditableLane(language: "ja", appliedRevision: 1))

        try await store.replaceLane(
            utteranceId: utterance.id,
            language: "ja",
            text: "編集済み"
        )
        XCTAssertEqual(
            client.lastReplaceExpectedRevision,
            utterance.sourceEditRevision
        )
    }

    func testRealtimeLanguagePickerCoversEverySupportedSonioxLanguageExactlyOnce() {
        let expected = [
            "af", "sq", "ar", "az", "eu", "be", "bn", "bs", "bg", "ca",
            "zh", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "gl",
            "de", "el", "gu", "he", "hi", "hu", "id", "it", "ja", "kn",
            "kk", "ko", "lv", "lt", "mk", "ms", "ml", "mr", "no", "fa",
            "pl", "pt", "pa", "ro", "ru", "sr", "sk", "sl", "es", "sw",
            "sv", "tl", "ta", "te", "th", "tr", "uk", "ur", "vi", "cy",
        ]

        XCTAssertEqual(NotebookCaptureSupportedLanguages.codes, expected)
        XCTAssertEqual(
            Set(NotebookCaptureSupportedLanguages.codes).count,
            NotebookCaptureSupportedLanguages.codes.count
        )
        XCTAssertEqual(
            NotebookCaptureSupportedLanguages.options(locale: Locale(identifier: "en"))
                .map(\.code),
            expected
        )
        let labels = Dictionary(
            uniqueKeysWithValues: NotebookCaptureSupportedLanguages.options(
                locale: Locale(identifier: "en")
            ).map { ($0.code, $0.label) }
        )
        XCTAssertTrue(labels["de"]?.contains("Deutsch") == true)
        XCTAssertTrue(labels["th"]?.contains("ไทย") == true)
        XCTAssertTrue(labels["hi"]?.contains("हिन्दी") == true)
        XCTAssertTrue(labels["bn"]?.contains("বাংলা") == true)
    }

    func testRealtimeLanguagePickerAddsTheInterfaceLanguageToSuggestions() {
        XCTAssertEqual(
            NotebookCaptureSupportedLanguages.suggestedCodes(interfaceLanguage: .ko),
            ["th", "en", "zh", "ko"]
        )
        XCTAssertEqual(
            NotebookCaptureSupportedLanguages.suggestedCodes(interfaceLanguage: .ja),
            ["th", "en", "zh", "ja"]
        )
        XCTAssertEqual(
            NotebookCaptureSupportedLanguages.suggestedCodes(interfaceLanguage: .zhHans),
            ["th", "en", "zh"]
        )
        XCTAssertEqual(
            NotebookCaptureSupportedLanguages.suggestedCodes(interfaceLanguage: .en),
            ["th", "en", "zh"]
        )
    }

    @MainActor
    func testSpeakerNamesPreferSessionOverrideThenManualParticipantThenProviderLabel() async throws {
        let utterance = NotebookCaptureUtteranceDTO(
            id: "utt-speaker",
            sessionId: "session-a",
            sequence: 1,
            sessionSpeakerId: "session-speaker-1",
            revision: 1,
            sourceLanguage: "vi",
            sourceText: "Xin chào",
            sourceStartMs: 0,
            sourceEndMs: 500,
            translatedLanguage: nil,
            translatedText: nil,
            completion: "complete",
            alignment: "source_only"
        )
        let participant = SpeakerParticipantDTO(id: "participant-1", displayName: "Alex")
        let speaker = NotebookSessionSpeakerDTO(
            id: "session-speaker-1",
            sessionId: "session-a",
            providerSessionEpoch: 0,
            provider: "soniox",
            providerLabel: "7",
            localDisplayName: nil,
            participantId: participant.id
        )
        let run = NotebookCaptureHistoryRunDTO.fixture(
            sessionId: "session-a",
            createdAt: "2001-01-02T08:00:00Z",
            utterances: [utterance]
        )
        let client = FakeNotebookCaptureClient(
            profile: .twoWay(notebookId: "notebook-a"),
            historyRuns: [run],
            speakerParticipants: [participant],
            sessionSpeakersBySession: ["session-a": [speaker]]
        )
        let store = NotebookCaptureHistoryStore(client: client)

        await store.load(notebookId: "notebook-a")
        await store.loadTranscript(sessionId: "session-a")
        XCTAssertEqual(
            store.speakerDisplayName(
                sessionSpeakerId: speaker.id,
                sessionId: speaker.sessionId
            ),
            "Alex"
        )

        try store.renameSessionSpeaker(
            sessionSpeakerId: speaker.id,
            localDisplayName: "Host"
        )
        XCTAssertEqual(
            store.speakerDisplayName(
                sessionSpeakerId: speaker.id,
                sessionId: speaker.sessionId
            ),
            "Host"
        )

        try store.renameSessionSpeaker(
            sessionSpeakerId: speaker.id,
            localDisplayName: nil
        )
        try store.unlinkSessionSpeaker(sessionSpeakerId: speaker.id)
        XCTAssertEqual(
            store.speakerDisplayName(
                sessionSpeakerId: speaker.id,
                sessionId: speaker.sessionId
            ),
            String(
                format: String(localized: "capture.speaker.fallback_format"),
                speaker.providerLabel
            )
        )

        let linked = try store.createParticipantAndLink(
            displayName: "Mai",
            sessionSpeakerId: speaker.id
        )
        XCTAssertNotNil(linked.participantId)
        XCTAssertEqual(
            store.speakerDisplayName(
                sessionSpeakerId: speaker.id,
                sessionId: speaker.sessionId
            ),
            "Mai"
        )
    }

    @MainActor
    func testDerivedBilingualPresentationKeepsMissingTranslationAsPlaceholderData() {
        let pending = NotebookCaptureUtteranceDTO(
            id: "utt-pending",
            sessionId: "session-a",
            sequence: 1,
            revision: 1,
            sourceLanguage: "en",
            sourceText: "Hello",
            sourceStartMs: 400,
            sourceEndMs: 900,
            translatedLanguage: "zh",
            translatedText: nil,
            completion: "partial",
            alignment: "translation_pending"
        )
        let bilingualRun = NotebookCaptureHistoryRunDTO.fixture(
            sessionId: "session-a",
            createdAt: "2001-01-02T08:00:00Z",
            mode: .twoWay,
            utterances: [pending]
        )
        let sourceOnlyRun = NotebookCaptureHistoryRunDTO.fixture(
            sessionId: "session-b",
            createdAt: "2001-01-02T09:00:00Z",
            mode: .transcriptionOnly,
            utterances: [pending]
        )

        XCTAssertEqual(
            NotebookRealtimeProjectionPolicy.layout(
                presentation: .bilingualColumns,
                run: bilingualRun
            ),
            .bilingualColumns
        )
        let lanes = NotebookCaptureHistoryPolicy.laneTexts(
            for: pending,
            leftLanguage: "en",
            rightLanguage: "zh"
        )
        XCTAssertEqual(lanes.left, "Hello")
        XCTAssertNil(lanes.right, "UI must render its stable waiting placeholder")
        XCTAssertNil(lanes.outsidePair)
        XCTAssertNil(lanes.pendingLanguage)
        XCTAssertEqual(lanes.missingLaneState, .waiting)
        XCTAssertEqual(
            NotebookRealtimeProjectionPolicy.layout(
                presentation: .bilingualColumns,
                run: sourceOnlyRun
            ),
            .bilingualColumns,
            "one selected language still owns one explicit language column"
        )
        XCTAssertEqual(
            NotebookCaptureHistoryPolicy.defaultPresentation(for: [sourceOnlyRun]),
            .bilingualColumns
        )
        let singleLane = NotebookCaptureHistoryPolicy.laneProjection(
            for: pending,
            selectedLanguages: ["en"],
            commonCaptionLanguage: nil
        )
        XCTAssertEqual(singleLane.lanes.count, 1)
        XCTAssertEqual(singleLane.lanes[0].language, "en")
        XCTAssertEqual(singleLane.lanes[0].text, "Hello")
        XCTAssertEqual(singleLane.lanes[0].missingLaneState, .unavailable)
        XCTAssertNil(singleLane.pendingLanguage)
        XCTAssertNil(singleLane.unselectedLanguageText)
        XCTAssertEqual(
            NotebookRealtimeProjectionPolicy.layout(
                presentation: .sourceTimeline,
                run: sourceOnlyRun
            ),
            .transcriptionTimeline,
            "the user can still explicitly choose the chronological timeline"
        )
    }

    @MainActor
    func testLocalSourceOnlyRunCanStillUseMultipleKnownLanguageColumns() {
        let run = NotebookCaptureHistoryRunDTO.fixture(
            sessionId: "session-local-multilingual",
            createdAt: "2001-01-02T08:00:00Z",
            mode: .transcriptionOnly,
            utterances: [.sample],
            selectedLanguages: ["en", "zh"]
        )

        XCTAssertEqual(
            NotebookCaptureHistoryPolicy.defaultPresentation(for: [run]),
            .bilingualColumns
        )
        XCTAssertEqual(
            NotebookRealtimeProjectionPolicy.layout(
                presentation: .bilingualColumns,
                run: run
            ),
            .bilingualColumns,
            "known source languages may use ordered columns even when no translation was requested"
        )
    }

    @MainActor
    func testLegacyCommonCaptionDoesNotInvalidateSelectedLanguageSnapshot() {
        let run = NotebookCaptureHistoryRunDTO.fixture(
            sessionId: "session-legacy-common",
            createdAt: "2001-01-02T08:00:00Z",
            mode: .multilingualOneWay,
            selectedLanguages: ["en", "zh", "th"],
            commonCaptionLanguage: "th"
        )

        XCTAssertTrue(NotebookCaptureHistoryPolicy.hasValidLanguageSelection(run))
        XCTAssertEqual(
            NotebookCaptureHistoryPolicy.displayLanguages(for: run),
            ["en", "zh", "th"]
        )
        XCTAssertEqual(
            NotebookRealtimeProjectionPolicy.layout(
                presentation: .bilingualColumns,
                run: run
            ),
            .bilingualColumns
        )
    }

    @MainActor
    func testOnlyPartialTranslationPendingRowsKeepWaitingForAMissingLane() {
        let cases: [(completion: String, alignment: String)] = [
            ("complete", "source_only"),
            ("complete", "translation_pending"),
            ("partial", "source_only"),
            ("complete", "paired"),
        ]

        for (index, state) in cases.enumerated() {
            let utterance = NotebookCaptureUtteranceDTO(
                id: "utt-finished-\(index)",
                sessionId: "session-a",
                sequence: UInt64(index + 1),
                revision: 1,
                sourceLanguage: "en",
                sourceText: "Finished source",
                sourceStartMs: 0,
                sourceEndMs: 300,
                translatedLanguage: "zh",
                translatedText: nil,
                completion: state.completion,
                alignment: state.alignment
            )
            let projection = NotebookCaptureHistoryPolicy.laneTexts(
                for: utterance,
                leftLanguage: "en",
                rightLanguage: "zh"
            )

            XCTAssertEqual(projection.left, "Finished source")
            XCTAssertNil(projection.right)
            XCTAssertEqual(
                projection.missingLaneState,
                .unavailable,
                "\(state.completion)/\(state.alignment) must not wait forever"
            )
        }
    }

    func testOrderedMultilingualProjectionRoutesTextByLanguageNotByOrigin() {
        let utterance = NotebookCaptureUtteranceDTO(
            id: "utt-multilingual",
            sessionId: "session-a",
            sequence: 1,
            revision: 2,
            sourceLanguage: "zh-CN",
            sourceText: "今天我们讨论这个问题",
            sourceStartMs: 0,
            sourceEndMs: 600,
            translatedLanguage: "en-US",
            translatedText: "Today we will discuss this question",
            completion: "complete",
            alignment: "response_order"
        )

        let projection = NotebookCaptureHistoryPolicy.laneProjection(
            for: utterance,
            selectedLanguages: ["en", "zh", "th"],
            commonCaptionLanguage: nil
        )

        XCTAssertEqual(projection.lanes.map(\.language), ["en", "zh", "th"])
        XCTAssertEqual(projection.lanes.map(\.text), [
            "Today we will discuss this question",
            "今天我们讨论这个问题",
            nil,
        ])
        XCTAssertEqual(
            projection.lanes.map(\.missingLaneState),
            [.unavailable, .unavailable, .unavailable]
        )
        XCTAssertNil(projection.pendingLanguage)
        XCTAssertNil(projection.unselectedLanguageText)
    }

    func testLegacySingleTranslationDoesNotPromoteASelectedColumnToTarget() {
        let utterance = NotebookCaptureUtteranceDTO(
            id: "utt-pending-common",
            sessionId: "session-a",
            sequence: 1,
            revision: 1,
            sourceLanguage: "zh",
            sourceText: "正在发言",
            sourceStartMs: 0,
            sourceEndMs: nil,
            translatedLanguage: "en",
            translatedText: nil,
            completion: "partial",
            alignment: "translation_pending"
        )

        let projection = NotebookCaptureHistoryPolicy.laneProjection(
            for: utterance,
            selectedLanguages: ["en", "zh", "th"],
            commonCaptionLanguage: nil
        )

        XCTAssertEqual(projection.lanes.map(\.text), [nil, "正在发言", nil])
        XCTAssertEqual(
            projection.lanes.map(\.missingLaneState),
            [.waiting, .unavailable, .waiting],
            "legacy pending state must apply equally to every missing selected-language lane"
        )
    }

    func testMultilingualProjectionKeepsWaitingAndFailureScopedPerTargetLane() {
        var utterance = NotebookCaptureUtteranceDTO(
            id: "utt-variant-state",
            sessionId: "session-a",
            sequence: 1,
            revision: 3,
            sourceLanguage: "zh",
            sourceText: "正在发言",
            sourceStartMs: 0,
            sourceEndMs: nil,
            translatedLanguage: nil,
            translatedText: nil,
            completion: "partial",
            alignment: "translation_pending"
        )
        utterance.languageVariants = [
            NotebookCaptureLanguageVariantDTO(
                language: "zh",
                role: "source",
                text: "正在发言",
                state: "ready",
                completion: "partial"
            ),
            NotebookCaptureLanguageVariantDTO(
                language: "en",
                role: "translated",
                text: "Speaking now",
                state: "ready",
                completion: "complete"
            ),
            NotebookCaptureLanguageVariantDTO(
                language: "th",
                role: "translated",
                text: nil,
                state: "waiting",
                completion: nil
            ),
            NotebookCaptureLanguageVariantDTO(
                language: "ja",
                role: "translated",
                text: nil,
                state: "failed",
                completion: nil
            ),
        ]

        let projection = NotebookCaptureHistoryPolicy.laneProjection(
            for: utterance,
            selectedLanguages: ["zh", "en", "th", "ja"],
            commonCaptionLanguage: nil
        )

        XCTAssertEqual(
            projection.lanes.map(\.text),
            ["正在发言", "Speaking now", nil, nil]
        )
        XCTAssertEqual(
            projection.lanes.map(\.missingLaneState),
            [.unavailable, .unavailable, .waiting, .failed],
            "one failed target must not fail or complete any other selected-language lane"
        )
    }

    func testUnknownAndUnselectedLanguagesStayFullWidthOutsideOrderedLanes() {
        func utterance(language: String, text: String) -> NotebookCaptureUtteranceDTO {
            NotebookCaptureUtteranceDTO(
                id: "utt-\(language.isEmpty ? "empty" : language)",
                sessionId: "session-a",
                sequence: 1,
                revision: 1,
                sourceLanguage: language,
                sourceText: text,
                sourceStartMs: 0,
                sourceEndMs: 200,
                translatedLanguage: nil,
                translatedText: nil,
                completion: "partial",
                alignment: "source_only"
            )
        }

        // With no caller-supplied guess the strict rule holds: a row must not
        // claim a language identity the provider never established.
        let pending = NotebookCaptureHistoryPolicy.laneProjection(
            for: utterance(language: "und", text: "provisional"),
            selectedLanguages: ["en", "zh", "th"],
            commonCaptionLanguage: nil
        )
        XCTAssertEqual(pending.pendingLanguage, "provisional")
        XCTAssertNil(pending.unselectedLanguageText)
        XCTAssertTrue(pending.lanes.allSatisfy { $0.text == nil })

        // The audience canvas supplies a guess, which places the words in a
        // column instead of spilling them across the full width.
        let borrowed = NotebookCaptureHistoryPolicy.laneProjection(
            for: utterance(language: "und", text: "provisional"),
            selectedLanguages: ["en", "zh", "th"],
            commonCaptionLanguage: nil,
            lastIdentifiedSourceLanguage: "zh"
        )
        XCTAssertNil(borrowed.pendingLanguage)
        XCTAssertEqual(borrowed.lanes.first(where: { $0.text != nil })?.language, "zh")
        XCTAssertEqual(borrowed.lanes.first(where: { $0.text != nil })?.text, "provisional")

        // A guess naming a column that is not on screen cannot place anything.
        let unusable = NotebookCaptureHistoryPolicy.laneProjection(
            for: utterance(language: "und", text: "provisional"),
            selectedLanguages: ["en", "zh", "th"],
            commonCaptionLanguage: nil,
            lastIdentifiedSourceLanguage: "ja"
        )
        XCTAssertEqual(unusable.pendingLanguage, "provisional")
        XCTAssertTrue(unusable.lanes.allSatisfy { $0.text == nil })

        let unselected = NotebookCaptureHistoryPolicy.laneProjection(
            for: utterance(language: "ja", text: "こんにちは"),
            selectedLanguages: ["en", "zh", "th"],
            commonCaptionLanguage: nil
        )
        XCTAssertNil(unselected.pendingLanguage)
        XCTAssertEqual(unselected.unselectedLanguageText, "こんにちは")
        XCTAssertTrue(unselected.lanes.allSatisfy { $0.text == nil })
    }

    func testProvisionalLanguagePlacesPendingTextInItsLaneImmediately() {
        func utterance(
            provisional: String?,
            sourceLanguage: String = "und"
        ) -> NotebookCaptureUtteranceDTO {
            NotebookCaptureUtteranceDTO(
                id: "utt-provisional",
                sessionId: "session-a",
                sequence: 1,
                revision: 1,
                sourceLanguage: sourceLanguage,
                provisionalSourceLanguage: provisional,
                sourceText: "你好世界",
                sourceStartMs: 0,
                sourceEndMs: 200,
                translatedLanguage: nil,
                translatedText: nil,
                completion: "partial",
                alignment: "source_only"
            )
        }

        let placed = NotebookCaptureHistoryPolicy.laneProjection(
            for: utterance(provisional: "zh"),
            selectedLanguages: ["en", "zh"],
            commonCaptionLanguage: nil
        )
        XCTAssertNil(
            placed.pendingLanguage,
            "a provisional selected language must replace the pending placeholder"
        )
        XCTAssertNil(placed.lanes[0].text)
        XCTAssertEqual(placed.lanes[1].text, "你好世界")

        let outsideSelection = NotebookCaptureHistoryPolicy.laneProjection(
            for: utterance(provisional: "ja"),
            selectedLanguages: ["en", "zh"],
            commonCaptionLanguage: nil
        )
        XCTAssertEqual(
            outsideSelection.pendingLanguage,
            "你好世界",
            "an unselected provisional language stays outside the ordered lanes"
        )
        XCTAssertTrue(outsideSelection.lanes.allSatisfy { $0.text == nil })

        let committed = NotebookCaptureHistoryPolicy.laneProjection(
            for: utterance(provisional: "zh", sourceLanguage: "en"),
            selectedLanguages: ["en", "zh"],
            commonCaptionLanguage: nil
        )
        XCTAssertEqual(
            committed.lanes[0].text,
            "你好世界",
            "a committed identity always outranks a stale provisional hint"
        )
        XCTAssertNil(committed.lanes[1].text)
    }

    func testUnknownPartialSourceDoesNotHideAnIndependentFinalTranslationLane() {
        var utterance = NotebookCaptureUtteranceDTO(
            id: "utt-translation-first",
            sessionId: "session-a",
            sequence: 1,
            revision: 2,
            sourceLanguage: "und",
            sourceText: "provisional source",
            sourceStartMs: 0,
            sourceEndMs: nil,
            translatedLanguage: nil,
            translatedText: nil,
            completion: "partial",
            alignment: "translation_pending"
        )
        utterance.languageVariants = [
            NotebookCaptureLanguageVariantDTO(
                language: "zh",
                role: "translation",
                text: "已完成的翻译",
                state: "ready",
                completion: "complete"
            ),
        ]

        let projection = NotebookCaptureHistoryPolicy.laneProjection(
            for: utterance,
            selectedLanguages: ["en", "zh"],
            commonCaptionLanguage: nil
        )

        XCTAssertNil(projection.pendingLanguage)
        XCTAssertNil(projection.lanes[0].text)
        XCTAssertEqual(projection.lanes[1].text, "已完成的翻译")
    }

    @MainActor
    func testUnknownLanguageWaitsOutsideBothColumnsUntilProviderIdentifiesIt() {
        let store = ActiveBilingualTranscriptStore(
            client: FakeNotebookCaptureClient(profile: .twoWay(notebookId: "notebook-a")),
            audioSource: FakeNotebookCaptureAudioSource()
        )
        store.loadProfile(notebookId: "notebook-a")

        for (index, language) in ["", "  ", "und", "UND-US"].enumerated() {
            let utterance = NotebookCaptureUtteranceDTO(
                id: "utt-pending-\(index)",
                sessionId: "session-a",
                sequence: UInt64(index + 1),
                revision: 1,
                sourceLanguage: language,
                sourceText: "provisional words",
                sourceStartMs: 0,
                sourceEndMs: 300,
                translatedLanguage: nil,
                translatedText: nil,
                completion: "partial",
                alignment: "source_only"
            )

            let historyProjection = NotebookCaptureHistoryPolicy.laneTexts(
                for: utterance,
                leftLanguage: "en",
                rightLanguage: "zh"
            )
            XCTAssertNil(historyProjection.left)
            XCTAssertNil(historyProjection.right)
            XCTAssertNil(historyProjection.outsidePair)
            XCTAssertEqual(historyProjection.pendingLanguage, "provisional words")
            XCTAssertEqual(historyProjection.missingLaneState, .unavailable)
            XCTAssertEqual(
                store.texts(for: utterance),
                historyProjection,
                "live and history projection must share the same language safety rule"
            )
        }
    }

    @MainActor
    func testActiveOverlayUpdatesOnlyItsMatchingHistorySection() {
        let old = NotebookCaptureHistoryRunDTO.fixture(
            sessionId: "old-session",
            createdAt: "2001-01-02T08:00:00Z",
            utterances: []
        )
        let activeBase = NotebookCaptureHistoryRunDTO.fixture(
            sessionId: "active-session",
            createdAt: "2001-01-02T09:00:00Z",
            state: .recording,
            projection: .pending,
            mode: .multilingualOneWay,
            utterances: [],
            selectedLanguages: ["en", "zh", "th"],
            commonCaptionLanguage: nil
        )
        let liveUtterance = NotebookCaptureUtteranceDTO(
            id: "live-utt",
            sessionId: "active-session",
            sequence: 1,
            revision: 3,
            sourceLanguage: "en",
            sourceText: "Live",
            sourceStartMs: 10,
            sourceEndMs: 90,
            translatedLanguage: "zh",
            translatedText: nil,
            completion: "partial",
            alignment: "translation_pending"
        )

        var activeProfile = NotebookCaptureProfileDTO.twoWay(notebookId: "notebook-a")
        activeProfile.mode = .multilingualOneWay
        activeProfile.selectedLanguages = ["en", "zh", "th"]
        activeProfile.commonCaptionLanguage = nil

        let overlaid = NotebookCaptureHistoryPolicy.overlayActiveRun(
            [old, activeBase],
            requestedNotebookId: "notebook-a",
            activeNotebookId: "notebook-a",
            activeSessionId: "active-session",
            isCaptureActive: true,
            captureState: .paused,
            remoteHealth: .live,
            projectionState: .pending,
            realtimeLoroAppliedRevision: 0,
            profile: activeProfile,
            utterances: [liveUtterance]
        )

        XCTAssertEqual(overlaid[0], old)
        XCTAssertEqual(overlaid[1].captureState, .paused)
        XCTAssertEqual(overlaid[1].utterances, [liveUtterance])
        XCTAssertEqual(overlaid[1].selectedLanguages, ["en", "zh", "th"])
        XCTAssertNil(overlaid[1].commonCaptionLanguage)
    }

    @MainActor
    func testFocusedLanePreservesDraftForItsOriginalLanguageTarget() {
        let english = BilingualLaneEditTarget(utteranceId: "utt-1", laneLanguage: "en")
        var buffer = BilingualLaneDraftBuffer(target: english, text: "Hello")
        buffer.draft = "Edited English"

        let commit = buffer.pendingCommit()
        XCTAssertEqual(commit?.target, english, "the draft must remain bound to its original lane")
        XCTAssertEqual(commit?.text, "Edited English")
    }

    @MainActor
    func testEditableLaneSeedsLatestProviderTextWithoutOverwritingUserDraft() {
        let english = BilingualLaneEditTarget(utteranceId: "utt-1", laneLanguage: "en")
        var buffer = BilingualLaneDraftBuffer(target: english, text: "early partial")

        buffer.syncAuthoritativeTextIfUnedited(target: english, text: "final transcript")
        XCTAssertEqual(buffer.draft, "final transcript")
        XCTAssertNil(buffer.pendingCommit())

        buffer.draft = "user correction"
        buffer.syncAuthoritativeTextIfUnedited(target: english, text: "late provider value")
        XCTAssertEqual(buffer.draft, "user correction")
        XCTAssertEqual(buffer.pendingCommit()?.text, "user correction")
    }

    @MainActor
    func testActiveLanguageOrderRemainsFrozenAcrossSubsequentRunSnapshotEvent() async throws {
        let client = FakeNotebookCaptureClient(profile: .twoWay(notebookId: "notebook-a"))
        let store = ActiveBilingualTranscriptStore(
            client: client,
            audioSource: FakeNotebookCaptureAudioSource()
        )
        store.loadProfile(notebookId: "notebook-a")
        try await store.start(notebookId: "notebook-a")
        XCTAssertEqual(store.selectedLanguages, ["en", "zh"])

        client.emitCaptureEvent(NotebookCaptureEventDTO(
            sessionId: "session-a",
            captureState: .recording,
            remoteHealth: .live,
            projectionState: .pending,
            utterances: [],
            translationCues: [],
            laneHealth: [],
            contextReceipt: nil,
            providerErrorType: nil,
            providerRequestId: nil,
            mode: .twoWay,
            languageA: "en",
            languageB: "zh",
            leftLanguage: "en",
            rightLanguage: "zh",
            selectedLanguages: ["en", "zh"],
            commonCaptionLanguage: nil
        ))

        XCTAssertEqual(
            store.selectedLanguages,
            ["en", "zh"],
            "later events must not drift the immutable run column order"
        )
    }

    @MainActor
    func testReopenUsesImmutableRunSnapshotInsteadOfNewNotebookProfile() {
        var newerNotebookProfile = NotebookCaptureProfileDTO.twoWay(notebookId: "notebook-a")
        newerNotebookProfile.languageA = "ja"
        newerNotebookProfile.languageB = "ko"
        newerNotebookProfile.leftLanguage = "ja"
        newerNotebookProfile.rightLanguage = "ko"
        newerNotebookProfile.selectedLanguages = ["ja", "ko"]
        newerNotebookProfile.commonCaptionLanguage = nil
        let client = FakeNotebookCaptureClient(profile: newerNotebookProfile)
        client.sessionEventOverride = NotebookCaptureEventDTO(
            sessionId: "historical-session",
            captureState: .completed,
            remoteHealth: .off,
            realtimeLagMs: nil,
            projectionState: .ready,
            utterances: [],
            translationCues: [],
            laneHealth: [],
            contextReceipt: nil,
            providerErrorType: nil,
            providerRequestId: nil,
            mode: .twoWay,
            languageA: "fr",
            languageB: "de",
            leftLanguage: "de",
            rightLanguage: "fr",
            postStopAsyncState: "enqueued",
            selectedLanguages: ["de", "fr"],
            commonCaptionLanguage: nil
        )
        let store = ActiveBilingualTranscriptStore(
            client: client,
            audioSource: FakeNotebookCaptureAudioSource()
        )

        store.loadProfile(notebookId: "notebook-a")
        XCTAssertEqual(store.leftLanguage, "ja")
        store.loadUtterances(notebookId: "notebook-b", sessionId: "historical-session")

        XCTAssertEqual(store.profile.mode, .twoWay)
        XCTAssertEqual(store.profile.languageA, "fr")
        XCTAssertEqual(store.profile.languageB, "de")
        XCTAssertEqual(store.leftLanguage, "de")
        XCTAssertEqual(store.rightLanguage, "fr")
        XCTAssertEqual(store.selectedLanguages, ["de", "fr"])
        XCTAssertNil(store.commonCaptionLanguage)
        XCTAssertEqual(store.postStopAsyncState, "enqueued")
        XCTAssertTrue(store.hasValidRunProfileSnapshot)
        XCTAssertEqual(store.profile.notebookId, "notebook-b")

        XCTAssertEqual(client.profileUpdateCount, 0)
    }

    @MainActor
    func testReopenInterruptedRunUsesAuthoritativeTerminalSnapshotWithoutMicrophone() {
        let client = FakeNotebookCaptureClient(profile: .twoWay(notebookId: "notebook-a"))
        client.sessionEventOverride = NotebookCaptureEventDTO(
            sessionId: "interrupted-session",
            captureState: .interrupted,
            remoteHealth: .off,
            projectionState: .pending,
            utterances: [],
            translationCues: [],
            laneHealth: [],
            contextReceipt: nil,
            providerErrorType: NotebookCaptureInterruptReason.localAudioOverflow.rawValue,
            providerRequestId: nil,
            mode: .twoWay,
            languageA: "fr",
            languageB: "de",
            leftLanguage: "fr",
            rightLanguage: "de",
            realtimeProviderId: "soniox",
            realtimeModelId: "stt-rt-v5",
            postStopProviderId: nil,
            postStopModelId: nil,
            postStopAsyncState: "none",
            selectedLanguages: ["fr", "de"],
            commonCaptionLanguage: nil
        )
        let audio = FakeNotebookCaptureAudioSource()
        let store = ActiveBilingualTranscriptStore(client: client, audioSource: audio)

        store.loadUtterances(notebookId: "notebook-a", sessionId: "interrupted-session")

        XCTAssertEqual(store.captureState, .interrupted)
        XCTAssertEqual(store.projectionState, .pending)
        XCTAssertEqual(store.providerErrorType, "local_audio_overflow")
        XCTAssertEqual(store.leftLanguage, "fr")
        XCTAssertEqual(store.rightLanguage, "de")
        XCTAssertEqual(store.realtimeProviderId, "soniox")
        XCTAssertEqual(store.realtimeModelId, "stt-rt-v5")
        XCTAssertNil(store.postStopProviderId)
        XCTAssertTrue(store.hasLoadedCaptureRunSnapshot)
        XCTAssertFalse(store.isCaptureActive)
        XCTAssertFalse(store.hasAudioSubscription)
        XCTAssertEqual(audio.subscribeCount, 0)
    }

    @MainActor
    func testRustAdapterRoundTripsOrderedMultilingualProfile() {
        let mapped = RustNotebookCaptureClient.map(FfiNotebookCaptureProfile(
            notebookId: "notebook-a",
            remoteRealtimeEnabled: true,
            mode: .multilingualOneWay,
            languageA: "en",
            languageB: "zh",
            leftLanguage: "en",
            rightLanguage: "zh",
            selectedLanguages: ["en", "zh", "th"],
            commonCaptionLanguage: "en",
            privacyLevel: "standard",
            sendContextToSoniox: false,
            revision: 8
        ))

        XCTAssertEqual(mapped.mode, .multilingualOneWay)
        XCTAssertEqual(mapped.selectedLanguages, ["en", "zh", "th"])
        XCTAssertNil(mapped.commonCaptionLanguage)

        let lowered = RustNotebookCaptureClient.ffi(mapped)
        XCTAssertEqual(lowered.mode, .multilingualOneWay)
        XCTAssertEqual(lowered.selectedLanguages, ["en", "zh", "th"])
        XCTAssertNil(lowered.commonCaptionLanguage)
    }

    @MainActor
    func testRustAdapterMapsRunSnapshotWithoutFallback() {
        let mapped = RustNotebookCaptureClient.map(FfiNotebookCaptureEvent(
            sessionId: "session-fr-de",
            eventRevision: 7,
            isFullSnapshot: true,
            captureState: .completed,
            remoteHealth: .off,
            realtimeLagMs: nil,
            projectionState: .ready,
            realtimeLoroAppliedRevision: 9,
            mode: .multilingualOneWay,
            languageA: "fr",
            languageB: "de",
            leftLanguage: "de",
            rightLanguage: "fr",
            selectedLanguages: ["en", "fr", "de"],
            commonCaptionLanguage: "en",
            privacyLevel: "standard",
            postStopAsyncState: "completed",
            postStopAsyncProjectionState: .failed,
            realtimeProviderId: "soniox",
            realtimeModelId: "stt-rt-v5",
            postStopProviderId: "soniox",
            postStopModelId: "stt-rt-v5",
            utterances: [],
            translationCues: [],
            laneHealth: [],
            contextReceipt: nil,
            providerErrorType: nil,
            providerRequestId: "request-1"
        ))

        XCTAssertEqual(mapped.mode, .multilingualOneWay)
        XCTAssertEqual(mapped.languageA, "fr")
        XCTAssertEqual(mapped.languageB, "de")
        XCTAssertEqual(mapped.leftLanguage, "de")
        XCTAssertEqual(mapped.rightLanguage, "fr")
        XCTAssertEqual(mapped.selectedLanguages, ["en", "fr", "de"])
        XCTAssertNil(mapped.commonCaptionLanguage)
        XCTAssertEqual(mapped.postStopAsyncState, "completed")
        XCTAssertEqual(mapped.postStopAsyncProjectionState, .failed)
        XCTAssertEqual(mapped.realtimeProviderId, "soniox")
        XCTAssertEqual(mapped.realtimeModelId, "stt-rt-v5")
        XCTAssertEqual(mapped.postStopProviderId, "soniox")
        XCTAssertEqual(mapped.postStopModelId, "stt-rt-v5")
        XCTAssertEqual(mapped.realtimeLoroAppliedRevision, 9)

        let corrupt = RustNotebookCaptureClient.map(FfiNotebookCaptureEvent(
            sessionId: "session-corrupt",
            eventRevision: 1,
            isFullSnapshot: true,
            captureState: .failed,
            remoteHealth: .off,
            realtimeLagMs: nil,
            projectionState: .failed,
            realtimeLoroAppliedRevision: 0,
            mode: nil,
            languageA: nil,
            languageB: nil,
            leftLanguage: nil,
            rightLanguage: nil,
            selectedLanguages: [],
            commonCaptionLanguage: nil,
            privacyLevel: nil,
            postStopAsyncState: "none",
            postStopAsyncProjectionState: .none,
            realtimeProviderId: nil,
            realtimeModelId: nil,
            postStopProviderId: nil,
            postStopModelId: nil,
            utterances: [],
            translationCues: [],
            laneHealth: [],
            contextReceipt: nil,
            providerErrorType: "profile_snapshot_corrupt",
            providerRequestId: nil
        ))
        XCTAssertNil(corrupt.mode)
        XCTAssertNil(corrupt.languageA)
        XCTAssertNil(corrupt.rightLanguage)
        XCTAssertTrue(corrupt.selectedLanguages.isEmpty)
        XCTAssertNil(corrupt.commonCaptionLanguage)
    }

    @MainActor
    func testLaterEventAddsPostStopProvenanceWithoutReplacingRealtimeClaim() async throws {
        let profile = NotebookCaptureProfileDTO.localDefault(notebookId: "notebook-a")
        let client = FakeNotebookCaptureClient(profile: profile)
        let store = ActiveBilingualTranscriptStore(
            client: client,
            audioSource: FakeNotebookCaptureAudioSource()
        )
        store.loadProfile(notebookId: "notebook-a")
        try await store.start(notebookId: "notebook-a")

        client.emitCaptureEvent(NotebookCaptureEventDTO(
            sessionId: "session-a",
            eventRevision: 1,
            isFullSnapshot: false,
            captureState: .recording,
            remoteHealth: .off,
            projectionState: .pending,
            utterances: [],
            translationCues: [],
            laneHealth: [],
            contextReceipt: nil,
            providerErrorType: nil,
            providerRequestId: nil,
            realtimeProviderId: "soniox",
            realtimeModelId: "stt-rt-v5",
            postStopAsyncState: "running"
        ))

        XCTAssertEqual(store.realtimeProviderId, "soniox")
        XCTAssertEqual(store.realtimeModelId, "stt-rt-v5")
        XCTAssertNil(store.postStopProviderId)

        client.emitCaptureEvent(NotebookCaptureEventDTO(
            sessionId: "session-a",
            eventRevision: 2,
            isFullSnapshot: false,
            captureState: .recording,
            remoteHealth: .off,
            projectionState: .pending,
            utterances: [],
            translationCues: [],
            laneHealth: [],
            contextReceipt: nil,
            providerErrorType: nil,
            providerRequestId: nil,
            realtimeProviderId: "unexpected-provider",
            realtimeModelId: "unexpected-model",
            postStopProviderId: "soniox",
            postStopModelId: "stt-rt-v5",
            postStopAsyncState: "running"
        ))

        XCTAssertEqual(store.realtimeProviderId, "soniox")
        XCTAssertEqual(store.realtimeModelId, "stt-rt-v5")
        XCTAssertEqual(store.postStopProviderId, "soniox")
        XCTAssertEqual(store.postStopModelId, "stt-rt-v5")
    }

    @MainActor
    func testAsyncProjectionStateAndRetryStayIndependentFromProviderCompletion() throws {
        let client = FakeNotebookCaptureClient(profile: .localDefault(notebookId: "notebook-a"))
        client.sessionEventOverride = NotebookCaptureEventDTO(
            sessionId: "session-a",
            captureState: .completed,
            remoteHealth: .off,
            projectionState: .ready,
            utterances: [],
            translationCues: [],
            laneHealth: [],
            contextReceipt: nil,
            providerErrorType: nil,
            providerRequestId: nil,
            mode: .transcriptionOnly,
            languageA: "en",
            languageB: "zh",
            leftLanguage: "en",
            rightLanguage: "zh",
            postStopAsyncState: "completed",
            postStopAsyncProjectionState: .failed,
            selectedLanguages: ["en"],
            commonCaptionLanguage: nil
        )
        client.asyncProjectionRetryEventOverride = NotebookCaptureEventDTO(
            sessionId: "session-a",
            captureState: .completed,
            remoteHealth: .off,
            projectionState: .ready,
            utterances: [],
            translationCues: [],
            laneHealth: [],
            contextReceipt: nil,
            providerErrorType: nil,
            providerRequestId: nil,
            mode: .transcriptionOnly,
            languageA: "en",
            languageB: "zh",
            leftLanguage: "en",
            rightLanguage: "zh",
            postStopAsyncState: "completed",
            postStopAsyncProjectionState: .ready,
            selectedLanguages: ["en"],
            commonCaptionLanguage: nil
        )
        let store = NotebookTranscriptProjectionStore(captureClient: client)

        store.attachIfNeeded(
            sessionId: "session-a",
            notebookId: "notebook-a",
            tabId: "async-tab"
        )
        XCTAssertEqual(store.asyncProviderStateBySession["session-a"], "completed")
        XCTAssertEqual(store.asyncProjectionStateBySession["session-a"], .failed)

        try store.retryAsyncProjection(sessionId: "session-a")
        XCTAssertEqual(client.asyncProjectionRetryCount, 1)
        XCTAssertEqual(store.asyncProviderStateBySession["session-a"], "completed")
        XCTAssertEqual(store.asyncProjectionStateBySession["session-a"], .ready)
    }

    @MainActor
    func testTranscriptProjectionAttachmentClosesEditorAfterLastViewLease() throws {
        let captureClient = FakeNotebookCaptureClient(
            profile: .localDefault(notebookId: "notebook-a")
        )
        let editorClient = FakeNotebookTranscriptEditorClient()
        let store = NotebookTranscriptProjectionStore(
            captureClient: captureClient,
            editorClient: editorClient
        )

        let first = try XCTUnwrap(store.attachIfNeeded(
            sessionId: "session-a",
            notebookId: "notebook-a",
            tabId: "async-tab"
        ))
        let replacementView = try XCTUnwrap(store.attachIfNeeded(
            sessionId: "session-a",
            notebookId: "notebook-a",
            tabId: "async-tab"
        ))

        XCTAssertEqual(editorClient.openCount, 1)
        XCTAssertEqual(editorClient.registerCount, 1)
        store.detach(first)
        XCTAssertEqual(editorClient.closeCount, 0, "a replacement view still owns the projection")
        XCTAssertEqual(editorClient.unregisterCount, 0)

        store.detach(replacementView)
        XCTAssertEqual(editorClient.unregisterCount, 1)
        XCTAssertEqual(editorClient.closeCount, 1, "the final lease must release Rust's editor refcount")
    }

    @MainActor
    func testTranscriptProjectionReattachCreatesOneFreshCallbackOwner() async throws {
        let captureClient = FakeNotebookCaptureClient(
            profile: .localDefault(notebookId: "notebook-a")
        )
        let editorClient = FakeNotebookTranscriptEditorClient()
        let store = NotebookTranscriptProjectionStore(
            captureClient: captureClient,
            editorClient: editorClient
        )

        let first = try XCTUnwrap(store.attachIfNeeded(
            sessionId: "session-a",
            notebookId: "notebook-a",
            tabId: "async-tab"
        ))
        let staleCallback = try XCTUnwrap(editorClient.registeredCallback)
        store.detach(first)

        let second = try XCTUnwrap(store.attachIfNeeded(
            sessionId: "session-a",
            notebookId: "notebook-a",
            tabId: "async-tab"
        ))
        let readsBeforeStaleEvent = editorClient.deltaReadCount
        staleCallback.onDocChanged(docId: "stale-doc", generation: 1)
        await Task.yield()

        XCTAssertEqual(
            editorClient.deltaReadCount,
            readsBeforeStaleEvent,
            "a callback from a released attachment must not refresh the new owner"
        )
        XCTAssertEqual(editorClient.openCount, 2)
        XCTAssertEqual(editorClient.registerCount, 2)
        store.detach(second)
        XCTAssertEqual(editorClient.closeCount, 2)
    }

    @MainActor
    func testCorruptHistoricalRunUsesLocalizedProfileSnapshotError() {
        let client = FakeNotebookCaptureClient(profile: .twoWay(notebookId: "notebook-a"))
        client.sessionEventOverride = NotebookCaptureEventDTO(
            sessionId: "session-corrupt",
            captureState: .failed,
            remoteHealth: .off,
            projectionState: .failed,
            utterances: [],
            translationCues: [],
            laneHealth: [],
            contextReceipt: nil,
            providerErrorType: "profile_snapshot_corrupt",
            providerRequestId: nil,
            mode: nil,
            languageA: nil,
            languageB: nil,
            leftLanguage: nil,
            rightLanguage: nil,
            postStopAsyncState: "none"
        )
        let store = ActiveBilingualTranscriptStore(
            client: client,
            audioSource: FakeNotebookCaptureAudioSource()
        )

        store.loadUtterances(notebookId: "notebook-a", sessionId: "session-corrupt")

        XCTAssertEqual(
            store.lastError,
            String(localized: "capture.error.profile_snapshot_unavailable")
        )
    }

    @MainActor
    func testLegacyCommonCaptionDoesNotInvalidateMultilingualEvent() {
        let client = FakeNotebookCaptureClient(profile: .twoWay(notebookId: "notebook-a"))
        client.sessionEventOverride = NotebookCaptureEventDTO(
            sessionId: "session-invalid-common",
            captureState: .completed,
            remoteHealth: .off,
            projectionState: .ready,
            utterances: [],
            translationCues: [],
            laneHealth: [],
            contextReceipt: nil,
            providerErrorType: nil,
            providerRequestId: nil,
            mode: .multilingualOneWay,
            languageA: "en",
            languageB: "zh",
            leftLanguage: "en",
            rightLanguage: "zh",
            postStopAsyncState: "none",
            selectedLanguages: ["en", "zh", "th"],
            commonCaptionLanguage: "th"
        )
        let store = ActiveBilingualTranscriptStore(
            client: client,
            audioSource: FakeNotebookCaptureAudioSource()
        )

        store.loadUtterances(
            notebookId: "notebook-a",
            sessionId: "session-invalid-common"
        )

        XCTAssertTrue(store.hasValidRunProfileSnapshot)
        XCTAssertEqual(store.selectedLanguages, ["en", "zh", "th"])
        XCTAssertNil(store.lastError)
    }

    func testRustCaptureCallbackHopsToMainActor() {
        let callbackExpectation = expectation(description: "capture callback reaches main actor")
        let callback = RustNotebookCaptureCallback(
            onCaptureEvent: { event in
                XCTAssertTrue(Thread.isMainThread)
                XCTAssertEqual(event.sessionId, "session-callback")
                callbackExpectation.fulfill()
            },
            onLivePreview: { _ in }
        )
        let event = FfiNotebookCaptureEvent(
            sessionId: "session-callback",
            eventRevision: 1,
            isFullSnapshot: false,
            captureState: .recording,
            remoteHealth: .live,
            realtimeLagMs: 8_000,
            projectionState: .pending,
            realtimeLoroAppliedRevision: 0,
            mode: .twoWay,
            languageA: "en",
            languageB: "zh",
            leftLanguage: "en",
            rightLanguage: "zh",
            selectedLanguages: ["en", "zh"],
            commonCaptionLanguage: nil,
            privacyLevel: "standard",
            postStopAsyncState: "none",
            postStopAsyncProjectionState: .none,
            realtimeProviderId: nil,
            realtimeModelId: nil,
            postStopProviderId: nil,
            postStopModelId: nil,
            utterances: [],
            translationCues: [],
            laneHealth: [],
            contextReceipt: nil,
            providerErrorType: nil,
            providerRequestId: nil
        )

        DispatchQueue.global(qos: .userInitiated).async {
            callback.onCaptureEvent(event: event)
        }
        wait(for: [callbackExpectation], timeout: 1)
    }

    @MainActor
    func testThirdLanguageRendersAsFullWidthOutsidePairText() {
        let store = ActiveBilingualTranscriptStore(
            client: FakeNotebookCaptureClient(profile: .twoWay(notebookId: "notebook-a")),
            audioSource: FakeNotebookCaptureAudioSource()
        )
        store.loadProfile(notebookId: "notebook-a")
        let utterance = NotebookCaptureUtteranceDTO(
            id: "utt-ja",
            sessionId: "session-a",
            sequence: 1,
            revision: 1,
            sourceLanguage: "ja",
            sourceText: "こんにちは",
            sourceStartMs: 0,
            sourceEndMs: 300,
            translatedLanguage: nil,
            translatedText: nil,
            completion: "complete",
            alignment: "outside_pair"
        )

        let texts = store.texts(for: utterance)
        XCTAssertNil(texts.left)
        XCTAssertNil(texts.right)
        XCTAssertEqual(texts.outsidePair, "こんにちは")
        XCTAssertNil(texts.pendingLanguage)
        XCTAssertEqual(texts.missingLaneState, .unavailable)

        XCTAssertEqual(
            texts,
            NotebookCaptureHistoryPolicy.laneTexts(
                for: utterance,
                leftLanguage: "en",
                rightLanguage: "zh"
            ),
            "a known third language must use the same outside-pair projection everywhere"
        )
    }

    @MainActor
    func testBoundContextIsPreparedAutomaticallyBeforeCaptureStart() async throws {
        var profile = NotebookCaptureProfileDTO.twoWay(notebookId: "notebook-a")
        profile.sendContextToSoniox = true
        let client = FakeNotebookCaptureClient(profile: profile)
        let audio = FakeNotebookCaptureAudioSource()
        let store = ActiveBilingualTranscriptStore(
            client: client,
            audioSource: audio
        )
        store.loadProfile(notebookId: "notebook-a")

        try await store.start(notebookId: "notebook-a")

        XCTAssertEqual(client.startCount, 1)
        XCTAssertEqual(client.previewCount, 1)
        XCTAssertEqual(audio.prepareCount, 1)
        XCTAssertEqual(client.lastConfirmedContextDigest, "context-digest")
        XCTAssertTrue(store.hasConfirmedContext(notebookId: "notebook-a"))
        XCTAssertNil(store.appliedContextReceipt, "automatic digest preparation is not an applied receipt")
    }

    @MainActor
    func testProfileSaveDoesNotCreateASecondContextPreparationGate() async throws {
        var profile = NotebookCaptureProfileDTO.twoWay(notebookId: "notebook-a")
        let client = FakeNotebookCaptureClient(profile: profile)
        let store = ActiveBilingualTranscriptStore(
            client: client,
            audioSource: FakeNotebookCaptureAudioSource()
        )
        store.loadProfile(notebookId: "notebook-a")

        profile.sendContextToSoniox = true
        try store.saveProfile(profile)
        XCTAssertEqual(client.previewCount, 0, "profile autosave must not compile or block on context")

        try await store.start(notebookId: "notebook-a")

        XCTAssertEqual(client.startCount, 1)
        XCTAssertEqual(client.previewCount, 1, "Start compiles the current bound payload exactly once")
        XCTAssertEqual(client.lastConfirmedContextDigest, "context-digest")
    }

    @MainActor
    func testProfileSaveAndStartUseTheNewestBoundContextDigest() async throws {
        var profile = NotebookCaptureProfileDTO.twoWay(notebookId: "notebook-a")
        let client = FakeNotebookCaptureClient(profile: profile)
        client.previewDigestAfterProfileUpdate = "changed-during-save"
        let store = ActiveBilingualTranscriptStore(
            client: client,
            audioSource: FakeNotebookCaptureAudioSource()
        )
        store.loadProfile(notebookId: "notebook-a")

        profile.sendContextToSoniox = true
        try store.saveProfile(profile)
        try await store.start(notebookId: "notebook-a")

        XCTAssertEqual(client.startCount, 1)
        XCTAssertEqual(store.contextPreview?.digest, "changed-during-save")
        XCTAssertEqual(client.lastConfirmedContextDigest, "changed-during-save")
    }

    @MainActor
    func testEmptyBoundContextFailsBeforeAudioWithoutAskingForConfirmation() async {
        var profile = NotebookCaptureProfileDTO.twoWay(notebookId: "notebook-a")
        profile.sendContextToSoniox = true
        let client = FakeNotebookCaptureClient(profile: profile)
        client.previewSerializedContext = "{}"
        let audio = FakeNotebookCaptureAudioSource()
        let store = ActiveBilingualTranscriptStore(client: client, audioSource: audio)

        do {
            try await store.start(notebookId: "notebook-a")
            XCTFail("empty bound context must fail before recording")
        } catch {
            XCTAssertEqual(error as? NotebookCaptureClientError, .contextUnavailable)
        }

        XCTAssertEqual(client.previewCount, 1)
        XCTAssertEqual(client.startCount, 0)
        XCTAssertEqual(audio.prepareCount, 0)
        XCTAssertEqual(
            store.lastError,
            String(localized: "capture.settings.context.empty")
        )
    }

    @MainActor
    func testContextCompilationFailureStopsBeforeAudioPreparation() async {
        var profile = NotebookCaptureProfileDTO.twoWay(notebookId: "notebook-a")
        profile.sendContextToSoniox = true
        let client = FakeNotebookCaptureClient(profile: profile)
        client.previewError = .ffiUnavailable
        let audio = FakeNotebookCaptureAudioSource()
        let store = ActiveBilingualTranscriptStore(client: client, audioSource: audio)

        do {
            try await store.start(notebookId: "notebook-a")
            XCTFail("context compilation failure must fail before recording")
        } catch {
            XCTAssertEqual(error as? NotebookCaptureClientError, .ffiUnavailable)
        }

        XCTAssertEqual(client.previewCount, 1)
        XCTAssertEqual(client.startCount, 0)
        XCTAssertEqual(audio.prepareCount, 0)
    }

    @MainActor
    func testContextPackBindingAndImportsInvalidateExactPreview() throws {
        let client = FakeNotebookCaptureClient(profile: .twoWay(notebookId: "notebook-a"))
        let store = ActiveBilingualTranscriptStore(
            client: client,
            audioSource: FakeNotebookCaptureAudioSource()
        )

        try store.loadContextPacks(notebookId: "notebook-a")
        XCTAssertEqual(store.contextPacks.first?.scope, "private")
        XCTAssertEqual(store.selectedContextPackId, "private-pack")

        _ = try store.previewContext(notebookId: "notebook-a")
        XCTAssertNotNil(store.contextPreview)
        try store.setContextPackBound(
            notebookId: "notebook-a",
            packId: "library-pack",
            isBound: true
        )
        XCTAssertNil(store.contextPreview, "binding changes must invalidate the reviewed snapshot")
        XCTAssertNotNil(store.contextPacks.first(where: { $0.id == "library-pack" })?.boundPosition)

        try store.selectContextPack("private-pack", notebookId: "notebook-a")
        try store.importContextText(
            notebookId: "notebook-a",
            packId: "private-pack",
            title: "Product names",
            text: "Zulangue\nSoniox",
            contentKind: "terms"
        )
        XCTAssertEqual(store.contextSources.count, 1)
        XCTAssertEqual(store.contextSources.first?.contentKind, "terms")
        XCTAssertEqual(client.lastContextSourceNotebookId, "notebook-a")
    }

    @MainActor
    func testSelectedLibraryIsPersistedAndRestoredForNotebookTranscription() throws {
        let client = FakeNotebookCaptureClient(profile: .twoWay(notebookId: "notebook-a"))
        let store = ActiveBilingualTranscriptStore(
            client: client,
            audioSource: FakeNotebookCaptureAudioSource()
        )

        try store.loadContextPacks(notebookId: "notebook-a")
        try store.selectContextPackForTranscription(
            "library-pack",
            notebookId: "notebook-a"
        )

        XCTAssertEqual(store.selectedContextPackId, "library-pack")
        XCTAssertEqual(client.contextBindingPositions, [0])
        XCTAssertTrue(store.hasConfirmedContext(notebookId: "notebook-a"))

        let reopenedStore = ActiveBilingualTranscriptStore(
            client: client,
            audioSource: FakeNotebookCaptureAudioSource()
        )
        try reopenedStore.loadContextPacks(notebookId: "notebook-a")
        XCTAssertEqual(
            reopenedStore.selectedContextPackId,
            "library-pack",
            "the durable Notebook binding must restore the prior knowledge-base selection"
        )
    }

    @MainActor
    func testKnowledgeLibraryImportsPackJSONAndPersistsEditsThroughRustBoundary() throws {
        let general = #"{"topic":"Anthropology","location":"Chiang Mai"}"#
        let document: [String: Any] = [
            "schema": "zulangue.context-pack.v1",
            "title": "人类学论坛",
            "sources": [
                [
                    "title": "概况",
                    "format": "text",
                    "content_kind": "general",
                    "sha256": String(repeating: "0", count: 64),
                    "content": general,
                ],
                [
                    "title": "专有词",
                    "format": "text",
                    "content_kind": "terms",
                    "sha256": String(repeating: "1", count: 64),
                    "content": "Zuzalu\n参与式观察",
                ],
                [
                    "title": "固定译法",
                    "format": "translation_csv",
                    "content_kind": "translation_terms",
                    "sha256": String(repeating: "2", count: 64),
                    "content": "en,zh\nparticipant observation,参与式观察",
                ],
                [
                    "title": "背景 A",
                    "format": "markdown",
                    "content_kind": "text",
                    "sha256": String(repeating: "3", count: 64),
                    "content": "第一段背景。",
                ],
                [
                    "title": "背景 B",
                    "format": "text",
                    "content_kind": "text",
                    "sha256": String(repeating: "4", count: 64),
                    "content": "第二段背景。",
                ],
            ],
        ]
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("knowledge-import-\(UUID().uuidString).zulangue-pack.json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
            .write(to: fileURL, options: .atomic)

        let client = FakeNotebookCaptureClient(profile: .twoWay(notebookId: "notebook-a"))
        let store = KnowledgeProfileStore(client: client)
        let importedID = try store.importJSON(from: fileURL)
        var imported = try XCTUnwrap(store.activeProfiles.first(where: { $0.id == importedID }))

        XCTAssertEqual(imported.name, "人类学论坛")
        XCTAssertEqual(imported.general.topic, "Anthropology")
        XCTAssertEqual(imported.general.location, "Chiang Mai")
        XCTAssertEqual(imported.terms.map(\.value), ["Zuzalu", "参与式观察"])
        XCTAssertEqual(imported.translationTerms.first?.targetText, "参与式观察")
        XCTAssertEqual(imported.backgroundText, "第一段背景。\n\n第二段背景。")

        imported.name = "人类学论坛（清迈）"
        imported = try XCTUnwrap(store.update(imported))
        let nameOnlyReplacement = try XCTUnwrap(client.lastLibraryReplacementJSON)
        let nameOnlyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(nameOnlyReplacement.utf8)) as? [String: Any]
        )
        let preservedSources = try XCTUnwrap(nameOnlyObject["sources"] as? [[String: Any]])
        XCTAssertEqual(
            preservedSources.compactMap { $0["title"] as? String },
            ["概况", "专有词", "固定译法", "背景 A", "背景 B"]
        )
        XCTAssertEqual(
            preservedSources.compactMap { $0["sha256"] as? String },
            (0...4).map { String(repeating: String($0), count: 64) }
        )

        imported.summary = "帮助识别人类学论坛中的专有名词"
        imported.terms.append(.init(value: "田野调查"))
        let saved = try XCTUnwrap(store.update(imported))
        XCTAssertEqual(saved.revision, 2)

        let replacement = try XCTUnwrap(client.lastLibraryReplacementJSON)
        let replacementObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(replacement.utf8)) as? [String: Any]
        )
        XCTAssertEqual(replacementObject["schema"] as? String, "zulangue.context-pack.v1")
        let replacementSources = try XCTUnwrap(replacementObject["sources"] as? [[String: Any]])
        XCTAssertEqual(Set(replacementSources.compactMap { $0["content_kind"] as? String }), [
            "general", "terms", "text", "translation_terms",
        ])
        XCTAssertTrue(replacementSources.allSatisfy {
            ($0["sha256"] as? String)?.count == 64
        })
        let updatedGeneral = try XCTUnwrap(replacementSources.first {
            ($0["content_kind"] as? String) == "general"
        })
        XCTAssertEqual(updatedGeneral["title"] as? String, "概况")
        XCTAssertEqual(updatedGeneral["format"] as? String, "text")
        let updatedTerms = try XCTUnwrap(replacementSources.first {
            ($0["content_kind"] as? String) == "terms"
        })
        XCTAssertEqual(updatedTerms["title"] as? String, "专有词")
        XCTAssertEqual(updatedTerms["format"] as? String, "text")
        let preservedBackground = replacementSources.filter {
            ($0["content_kind"] as? String) == "text"
        }
        XCTAssertEqual(
            preservedBackground.compactMap { $0["title"] as? String },
            ["背景 A", "背景 B"]
        )
        XCTAssertEqual(
            preservedBackground.compactMap { $0["format"] as? String },
            ["markdown", "text"]
        )
        let preservedTranslation = try XCTUnwrap(replacementSources.first {
            ($0["content_kind"] as? String) == "translation_terms"
        })
        XCTAssertEqual(preservedTranslation["title"] as? String, "固定译法")
        XCTAssertEqual(preservedTranslation["sha256"] as? String, String(repeating: "2", count: 64))

        let reopened = KnowledgeProfileStore(client: client)
        let restored = try XCTUnwrap(reopened.activeProfiles.first(where: { $0.id == importedID }))
        XCTAssertEqual(restored.summary, imported.summary)
        XCTAssertEqual(restored.backgroundText, imported.backgroundText)
        XCTAssertTrue(restored.terms.contains(where: { $0.value == "田野调查" }))

        var ambiguousBackgroundEdit = restored
        ambiguousBackgroundEdit.backgroundText = "论坛在清迈举行。"
        XCTAssertNil(reopened.update(ambiguousBackgroundEdit))
        XCTAssertTrue(reopened.persistenceError?.contains("multiple JSON sources") == true)
        let afterAmbiguousEdit = KnowledgeProfileStore(client: client)
        XCTAssertEqual(
            afterAmbiguousEdit.activeProfiles.first(where: { $0.id == importedID })?.backgroundText,
            restored.backgroundText,
            "an ambiguous many-source edit must not replace or merge the imported sources"
        )

        client.libraryReplacementError = .ffiUnavailable
        var rejected = restored
        rejected.summary = "这次改动不应被伪装成已保存"
        XCTAssertNil(reopened.update(rejected))
        XCTAssertNotNil(reopened.persistenceError)
        client.libraryReplacementError = nil
        let afterFailure = KnowledgeProfileStore(client: client)
        XCTAssertEqual(
            afterFailure.activeProfiles.first(where: { $0.id == importedID })?.summary,
            restored.summary
        )
    }

    func testKnowledgeJSONImportLivesOutsideNotebookSettings() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Zulangue", isDirectory: true)
        let knowledge = try String(
            contentsOf: root.appendingPathComponent("Pages/KnowledgeLibraryPage.swift"),
            encoding: .utf8
        )
        let captureSettings = try String(
            contentsOf: root.appendingPathComponent("Pages/NotebookCaptureViews.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(knowledge.contains("knowledge.import_json"))
        XCTAssertTrue(knowledge.contains("NSOpenPanel()"))
        XCTAssertTrue(knowledge.contains("store.importJSON(from: url)"))
        XCTAssertFalse(knowledge.contains("isOn: $term.isEnabled"))
        XCTAssertTrue(knowledge.contains("guard saveNow() else { return }"))
        XCTAssertTrue(knowledge.contains("capture.settings.autosave.save_failed"))
        XCTAssertFalse(captureSettings.contains("chooseContextPackToImport"))
        XCTAssertFalse(captureSettings.contains("contextPackEditor"))
        XCTAssertFalse(captureSettings.contains("NSSavePanel()"))
        XCTAssertTrue(captureSettings.contains("selectContextPackForTranscription"))
        XCTAssertTrue(captureSettings.contains("requestContextPreview"))
    }

    @MainActor
    func testContextBrowserNeverPublishesAnotherNotebooksPartialOrStaleState() throws {
        let client = FakeNotebookCaptureClient(profile: .twoWay(notebookId: "notebook-a"))
        let store = ActiveBilingualTranscriptStore(
            client: client,
            audioSource: FakeNotebookCaptureAudioSource()
        )
        try store.loadContextPacks(notebookId: "notebook-a")
        try store.importContextText(
            notebookId: "notebook-a",
            packId: "private-pack",
            title: "Notebook A terms",
            text: "private A metadata",
            contentKind: "terms"
        )
        XCTAssertEqual(store.loadedContextNotebookId, "notebook-a")
        XCTAssertEqual(store.contextSources.count, 1)

        client.contextPackListError = .ffiUnavailable
        XCTAssertThrowsError(try store.loadContextPacks(notebookId: "notebook-b"))
        XCTAssertNil(store.loadedContextNotebookId)
        XCTAssertTrue(store.contextPacks.isEmpty)
        XCTAssertTrue(store.contextSources.isEmpty)
        XCTAssertNil(store.selectedContextPackId)

        client.contextPackListError = nil
        try store.loadContextPacks(notebookId: "notebook-a")
        XCTAssertEqual(store.contextSources.count, 1)
        client.contextSourceListError = .ffiUnavailable
        XCTAssertThrowsError(try store.loadContextPacks(notebookId: "notebook-b"))
        XCTAssertNil(store.loadedContextNotebookId)
        XCTAssertTrue(store.contextPacks.isEmpty)
        XCTAssertTrue(store.contextSources.isEmpty)
        XCTAssertNil(store.selectedContextPackId)
    }

    @MainActor
    func testEmptyCompiledContextCannotBeConfirmedForEgress() {
        let preview = NotebookCaptureContextPreviewDTO(
            notebookId: "notebook-a",
            serializedContext: "  {}\n",
            sources: [],
            omittedReasons: [],
            digest: "empty-digest",
            scalarCount: 2
        )

        XCTAssertFalse(preview.containsSendableContext)
    }

    @MainActor
    func testTranscriptLaneUnlocksAtAppliedWatermarkDuringRecording() async throws {
        let utterance = NotebookCaptureUtteranceDTO.sample
        let client = FakeNotebookCaptureClient(
            profile: .twoWay(notebookId: "notebook-a"),
            startUtterances: [utterance]
        )
        let store = ActiveBilingualTranscriptStore(
            client: client,
            audioSource: FakeNotebookCaptureAudioSource()
        )
        store.loadProfile(notebookId: "notebook-a")
        try await store.start(notebookId: "notebook-a")

        do {
            try await store.replaceLane(
                utteranceId: utterance.id,
                language: "en",
                text: "Edited"
            )
            XCTFail("the lane must remain locked below its projection watermark")
        } catch {
            XCTAssertEqual(error as? NotebookCaptureClientError, .projectionLocked)
        }

        client.emitCaptureEvent(captureEvent(
            sessionId: "session-a",
            state: .recording,
            utterances: [utterance],
            eventRevision: 1,
            isFullSnapshot: true,
            realtimeLoroAppliedRevision: 1
        ))

        XCTAssertEqual(store.captureState, .recording)
        XCTAssertEqual(store.projectionState, .pending)
        XCTAssertTrue(store.isEditable)
        try await store.replaceLane(
            utteranceId: utterance.id,
            language: "en",
            text: "Edited"
        )
        XCTAssertEqual(
            client.lastReplaceExpectedRevision,
            utterance.sourceEditRevision
        )
        XCTAssertEqual(store.utterances.first?.sourceEditRevision, 1)
        XCTAssertEqual(store.utterances.first?.sourceText, "Edited")
    }

    @MainActor
    func testLaneEditStaysResponsiveAndMergesOnlyCommittedLaneIntoNewerEvent() async throws {
        let utterance = NotebookCaptureUtteranceDTO.sample
        let client = FakeNotebookCaptureClient(
            profile: .twoWay(notebookId: "notebook-a"),
            startUtterances: [utterance]
        )
        let replaceController = BlockingNotebookPauseController()
        client.replaceController = replaceController
        let store = ActiveBilingualTranscriptStore(
            client: client,
            audioSource: FakeNotebookCaptureAudioSource()
        )
        try await store.start(notebookId: "notebook-a")
        client.emitCaptureEvent(captureEvent(
            sessionId: "session-a",
            state: .recording,
            utterances: [utterance],
            eventRevision: 1,
            realtimeLoroAppliedRevision: 1
        ))

        let editTask = Task { @MainActor in
            try await store.replaceLane(
                utteranceId: utterance.id,
                language: "en",
                text: "User edit"
            )
        }
        let didEnterEdit = await waitUntil { replaceController.isWaiting }
        XCTAssertTrue(didEnterEdit)

        do {
            try await store.replaceLane(
                utteranceId: utterance.id,
                language: "en",
                text: "Duplicate edit"
            )
            XCTFail("one lane must allow only one durable mutation in flight")
        } catch {
            XCTAssertEqual(error as? NotebookCaptureClientError, .projectionLocked)
        }

        var heartbeat = false
        Task { @MainActor in heartbeat = true }
        let didReceiveHeartbeat = await waitUntil { heartbeat }
        XCTAssertTrue(didReceiveHeartbeat)

        var newer = utterance
        newer.revision = 9
        newer.sessionSpeakerId = "speaker-new"
        newer.translatedText = "并行更新"
        newer.languageVariants[0].text = "并行更新"
        client.emitCaptureEvent(captureEvent(
            sessionId: "session-a",
            state: .recording,
            utterances: [newer],
            eventRevision: 2,
            realtimeLoroAppliedRevision: 1
        ))

        replaceController.release()
        try await editTask.value

        let merged = try XCTUnwrap(store.utterances.first)
        XCTAssertEqual(merged.sourceText, "User edit")
        XCTAssertEqual(merged.translatedText, "并行更新")
        XCTAssertEqual(merged.languageVariants.first?.text, "并行更新")
        XCTAssertEqual(merged.sessionSpeakerId, "speaker-new")
        XCTAssertEqual(merged.revision, 9)
    }

    @MainActor
    func testCommittedLaneRejectsStaleEqualRevisionCallbackWithoutBlockingOtherFields() async throws {
        let utterance = NotebookCaptureUtteranceDTO.sample
        let client = FakeNotebookCaptureClient(
            profile: .twoWay(notebookId: "notebook-a"),
            startUtterances: [utterance]
        )
        let store = ActiveBilingualTranscriptStore(
            client: client,
            audioSource: FakeNotebookCaptureAudioSource()
        )
        try await store.start(notebookId: "notebook-a")
        client.emitCaptureEvent(captureEvent(
            sessionId: "session-a",
            state: .recording,
            utterances: [utterance],
            eventRevision: 1,
            realtimeLoroAppliedRevision: 1
        ))

        try await store.replaceLane(
            utteranceId: utterance.id,
            language: "en",
            text: "User edit"
        )
        XCTAssertEqual(store.utterances.first?.revision, 7)
        XCTAssertEqual(store.utterances.first?.sourceEditRevision, 1)

        var staleEqualRevision = utterance
        staleEqualRevision.revision = 7
        staleEqualRevision.sessionSpeakerId = "speaker-late"
        staleEqualRevision.translatedText = "晚到的其他语言"
        staleEqualRevision.languageVariants[0].text = "晚到的其他语言"
        client.emitCaptureEvent(captureEvent(
            sessionId: "session-a",
            state: .recording,
            utterances: [staleEqualRevision],
            eventRevision: 2,
            realtimeLoroAppliedRevision: 1
        ))

        let protected = try XCTUnwrap(store.utterances.first)
        XCTAssertEqual(protected.sourceText, "User edit")
        XCTAssertEqual(protected.translatedText, "晚到的其他语言")
        XCTAssertEqual(protected.languageVariants.first?.text, "晚到的其他语言")
        XCTAssertEqual(protected.sessionSpeakerId, "speaker-late")
        XCTAssertEqual(protected.revision, 7)
        XCTAssertEqual(protected.sourceEditRevision, 1)

        var higherMachineRevision = staleEqualRevision
        higherMachineRevision.revision = 8
        higherMachineRevision.sourceText = "Higher machine source"
        client.emitCaptureEvent(captureEvent(
            sessionId: "session-a",
            state: .recording,
            utterances: [higherMachineRevision],
            eventRevision: 3,
            realtimeLoroAppliedRevision: 1
        ))

        XCTAssertEqual(
            store.utterances.first?.sourceText,
            "User edit",
            "a newer machine fact must not erase a committed user override"
        )
        XCTAssertEqual(store.utterances.first?.sourceEditRevision, 1)
        XCTAssertEqual(store.utterances.first?.revision, 8)
    }

    @MainActor
    private func resampledTone(
        inputRate: Double,
        frequency: Double,
        chunks: [Int]
    ) -> [Int16] {
        let inputCount = Int(inputRate)
        let input = (0..<inputCount).map { index in
            Float(0.5 * sin(2 * Double.pi * frequency * Double(index) / inputRate))
        }
        let resampler = StreamingS16Resampler(inputSampleRate: inputRate)
        var output: [Int16] = []
        var offset = 0
        var chunkIndex = 0
        while offset < input.count {
            let requested = chunks[chunkIndex % chunks.count]
            let end = min(input.count, offset + max(1, requested))
            output.append(contentsOf: resampler.process(Array(input[offset..<end])))
            offset = end
            chunkIndex += 1
        }
        return output
    }

    private func estimatedFrequency(of samples: [Int16], sampleRate: Double) -> Double {
        let values = samples.dropFirst(512).map(Double.init)
        var crossings: [Double] = []
        guard values.count > 2 else { return 0 }
        for index in 1..<values.count {
            let previous = values[index - 1]
            let current = values[index]
            if previous <= 0, current > 0 {
                let fraction = previous == current ? 0 : -previous / (current - previous)
                crossings.append(Double(index - 1) + fraction)
            }
        }
        guard let first = crossings.first,
              let last = crossings.last,
              crossings.count > 1,
              last > first
        else { return 0 }
        return Double(crossings.count - 1) * sampleRate / (last - first)
    }

    private func rms(_ samples: [Int16]) -> Double {
        guard samples.isEmpty == false else { return 0 }
        let energy = samples.reduce(0.0) { partial, sample in
            let value = Double(sample) / 32_768
            return partial + value * value
        }
        return sqrt(energy / Double(samples.count))
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 1,
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }

    private func captureEvent(
        sessionId: String,
        state: NotebookCaptureState = .completed,
        utterances: [NotebookCaptureUtteranceDTO],
        eventRevision: UInt64 = 0,
        isFullSnapshot: Bool = true,
        realtimeLoroAppliedRevision: UInt64? = nil,
        translationCues: [NotebookCaptureTranslationCueDTO] = [],
        laneHealth: [NotebookCaptureLaneHealthDTO] = []
    ) -> NotebookCaptureEventDTO {
        let durableRevision = utterances.reduce(UInt64(0)) { current, utterance in
            max(
                current,
                max(
                    utterance.sourceProjectionRevision,
                    utterance.languageVariants.map(\.projectionRevision).max() ?? 0
                )
            )
        }
        return NotebookCaptureEventDTO(
            sessionId: sessionId,
            eventRevision: eventRevision,
            isFullSnapshot: isFullSnapshot,
            captureState: state,
            remoteHealth: state.isActive ? .live : .off,
            projectionState: state.isActive ? .pending : .ready,
            utterances: utterances,
            translationCues: translationCues,
            laneHealth: laneHealth,
            contextReceipt: nil,
            providerErrorType: nil,
            providerRequestId: nil,
            mode: .twoWay,
            languageA: "en",
            languageB: "zh",
            leftLanguage: "en",
            rightLanguage: "zh",
            postStopAsyncState: "none",
            selectedLanguages: ["en", "zh"],
            commonCaptionLanguage: nil,
            realtimeLoroAppliedRevision: realtimeLoroAppliedRevision
                ?? (state.isActive ? 0 : durableRevision)
        )
    }

    @MainActor
    func testRealtimeConsolePresentationSeparatesActiveRunFromNextRunEditor() {
        for state in [
            NotebookCaptureState.completed,
            .interrupted,
            .failed,
        ] {
            XCTAssertEqual(
                NotebookRealtimeConsolePresentation.resolve(
                    isCaptureActive: false,
                    captureState: state,
                    activeNotebookId: nil,
                    notebookId: "notebook-a"
                ),
                .inactiveEditor
            )
        }

        for state in [NotebookCaptureState.recording, .paused] {
            XCTAssertEqual(
                NotebookRealtimeConsolePresentation.resolve(
                    isCaptureActive: true,
                    captureState: state,
                    activeNotebookId: "notebook-a",
                    notebookId: "notebook-a"
                ),
                .activeRunSummary
            )
        }
        XCTAssertEqual(
            NotebookRealtimeConsolePresentation.resolve(
                isCaptureActive: true,
                captureState: .draining,
                activeNotebookId: "notebook-a",
                notebookId: "notebook-a"
            ),
            .drainingSummary
        )
        for terminalState in [NotebookCaptureState.interrupted, .failed, .completed] {
            XCTAssertEqual(
                NotebookRealtimeConsolePresentation.resolve(
                    isCaptureActive: true,
                    captureState: terminalState,
                    activeNotebookId: "notebook-a",
                    notebookId: "notebook-a"
                ),
                .drainingSummary,
                "A terminal-looking Swift snapshot remains read-only while its terminal lease is active"
            )
        }
        XCTAssertEqual(
            NotebookRealtimeConsolePresentation.resolve(
                isCaptureActive: true,
                captureState: .recording,
                activeNotebookId: "notebook-b",
                notebookId: "notebook-a"
            ),
            .activeElsewhereSummary
        )
    }

    @MainActor
    func testRealtimeControlLayoutStacksWithoutDuplicatingNativeControls() {
        XCTAssertEqual(NotebookRealtimeControlLayoutPolicy.minimumInteractiveTarget, 44)
        XCTAssertEqual(
            NotebookRealtimeControlLayoutPolicy.resolve(
                availableWidth: 319,
                requiredHorizontalWidth: 320
            ),
            .stacked
        )
        XCTAssertEqual(
            NotebookRealtimeControlLayoutPolicy.resolve(
                availableWidth: 320,
                requiredHorizontalWidth: 320
            ),
            .horizontal
        )
        XCTAssertEqual(
            NotebookRealtimeControlLayoutPolicy.resolve(
                availableWidth: nil,
                requiredHorizontalWidth: 320
            ),
            .horizontal
        )
    }

    func testFourOrMoreLanguageColumnsShareHorizontalScroll() {
        XCTAssertFalse(
            NotebookRealtimeTranscriptLayout.usesHorizontalScroll(languageCount: 1)
        )
        XCTAssertFalse(
            NotebookRealtimeTranscriptLayout.usesHorizontalScroll(languageCount: 3)
        )
        XCTAssertTrue(
            NotebookRealtimeTranscriptLayout.usesHorizontalScroll(languageCount: 4)
        )
        XCTAssertTrue(
            NotebookRealtimeTranscriptLayout.usesHorizontalScroll(languageCount: 8)
        )
        XCTAssertEqual(
            NotebookRealtimeTranscriptLayout.minimumContentWidth(languageCount: 4),
            NotebookRealtimeTranscriptLayout.minimumLanguageColumnWidth * 4
        )
    }

    /// The active run's rows come from the capture overlay while
    /// `history.runs` keeps no utterances for that session. Routing a live
    /// lane commit at the history store therefore failed its lookup gate
    /// after the row had already offered a caret. The commit must reach the
    /// store that owns the rows, and the caret must respect the capture
    /// store's own editing gate.
    func testActiveRunLaneEditsCommitAgainstTheCaptureStore() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Zulangue", isDirectory: true)
        let captureViews = try String(
            contentsOf: root.appendingPathComponent("Pages/NotebookCaptureViews.swift"),
            encoding: .utf8
        )

        let activeRunStart = try XCTUnwrap(
            captureViews.range(of: "private struct NotebookRealtimeActiveRunView: View")
        )
        let activeRunView = String(captureViews[activeRunStart.lowerBound...])
        XCTAssertTrue(
            activeRunView.contains("try await capture.replaceLane("),
            "a live lane edit must commit against the capture store that owns the presented rows"
        )
        XCTAssertFalse(
            activeRunView.contains("history.replaceLane("),
            "history.runs holds no utterances for the active session, so its replaceLane can only throw projectionLocked"
        )
        XCTAssertTrue(
            captureViews.contains("isLaneEditingEnabled: capture.isEditable"),
            "the live caret must withdraw while a terminal transition holds the session"
        )

        let utteranceViewStart = try XCTUnwrap(
            captureViews.range(of: "struct NotebookRealtimeUtteranceView: View")
        )
        let utteranceView = String(captureViews[utteranceViewStart.lowerBound...])
        XCTAssertTrue(
            utteranceView.contains("guard isLaneEditingEnabled else { return false }"),
            "the run-level gate must sit above every per-lane projection watermark"
        )
    }

    func testCaptureSurfacesKeepControlsNotebookOnlyAndAccessible() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Zulangue", isDirectory: true)
        let captureViews = try String(
            contentsOf: root.appendingPathComponent("Pages/NotebookCaptureViews.swift"),
            encoding: .utf8
        )
        let menu = try String(
            contentsOf: root.appendingPathComponent("MenuBar/MenuBarRecordingView.swift"),
            encoding: .utf8
        )
        let overlays = try String(
            contentsOf: root.appendingPathComponent("App/SubtitleOverlayCoordinator.swift"),
            encoding: .utf8
        )
        let activeCapture = try String(
            contentsOf: root.appendingPathComponent("Capture/ActiveBilingualTranscriptStore.swift"),
            encoding: .utf8
        )
        let overlayViews = try String(
            contentsOf: root.appendingPathComponent("WindowSystem/Surfaces/SubtitleOverlayController.swift"),
            encoding: .utf8
        )
        let documentEditor = try String(
            contentsOf: root.appendingPathComponent("Pages/DocumentEditorPage.swift"),
            encoding: .utf8
        )
        let mainShell = try String(
            contentsOf: root.appendingPathComponent("UIScenes/Main/MainShellView.swift"),
            encoding: .utf8
        )
        let realtimeConsoleStart = try XCTUnwrap(
            captureViews.range(of: "private struct NotebookRealtimeCaptureConsole: View")
        )
        let realtimeConsoleEnd = try XCTUnwrap(
            captureViews[realtimeConsoleStart.upperBound...]
                .range(of: "// MARK: - Notebook capture settings")
        )
        let realtimeConsole = String(
            captureViews[realtimeConsoleStart.lowerBound..<realtimeConsoleEnd.lowerBound]
        )
        let activeSummaryStart = try XCTUnwrap(
            realtimeConsole.range(of: "private var activeRunSummary: some View")
        )
        let activeSummaryEnd = try XCTUnwrap(
            realtimeConsole[activeSummaryStart.upperBound...]
                .range(of: "private var inactiveProfileEditor: some View")
        )
        let activeSummary = String(
            realtimeConsole[activeSummaryStart.lowerBound..<activeSummaryEnd.lowerBound]
        )
        let inactiveEditorStart = try XCTUnwrap(
            realtimeConsole.range(of: "private var inactiveProfileEditor: some View")
        )
        let inactiveEditorEnd = try XCTUnwrap(
            realtimeConsole[inactiveEditorStart.upperBound...]
                .range(of: "private var scopeCopy: some View")
        )
        let inactiveEditor = String(
            realtimeConsole[inactiveEditorStart.lowerBound..<inactiveEditorEnd.lowerBound]
        )
        let settingsStart = try XCTUnwrap(
            captureViews.range(of: "struct NotebookCaptureSettingsView: View")
        )
        let settingsEnd = try XCTUnwrap(
            captureViews[settingsStart.upperBound...]
                .range(of: "// MARK: - Run-derived realtime transcript")
        )
        let settingsView = String(captureViews[settingsStart.lowerBound..<settingsEnd.lowerBound])
        let contextSectionStart = try XCTUnwrap(
            settingsView.range(of: "private var contextSection: some View")
        )
        let contextSectionEnd = try XCTUnwrap(
            settingsView[contextSectionStart.upperBound...]
                .range(of: "@ViewBuilder\n    private var contextBrowserSection")
        )
        let contextSection = String(
            settingsView[contextSectionStart.lowerBound..<contextSectionEnd.lowerBound]
        )
        let realtimeTranscriptStart = try XCTUnwrap(
            captureViews.range(of: "struct NotebookRealtimeUtteranceView: View")
        )
        let realtimeTranscriptEnd = try XCTUnwrap(
            captureViews[realtimeTranscriptStart.upperBound...]
                .range(of: "private struct TranscriptionUtteranceRow: View")
        )
        let realtimeTranscriptView = String(
            captureViews[realtimeTranscriptStart.lowerBound..<realtimeTranscriptEnd.lowerBound]
        )
        let laneTextStart = try XCTUnwrap(
            captureViews.range(of: "private struct BilingualLaneText: View")
        )
        let laneTextEnd = try XCTUnwrap(
            captureViews[laneTextStart.upperBound...]
                .range(of: "struct CaptureStateLabel: View")
        )
        let laneTextView = String(
            captureViews[laneTextStart.lowerBound..<laneTextEnd.lowerBound]
        )
        let conversationRowStart = try XCTUnwrap(
            overlayViews.range(of: "private func conversationRow(")
        )
        let conversationRowEnd = try XCTUnwrap(
            overlayViews[conversationRowStart.upperBound...]
                .range(of: "/// Words-first projection")
        )
        let conversationRowView = String(
            overlayViews[conversationRowStart.lowerBound..<conversationRowEnd.lowerBound]
        )
        let conversationLaneStart = try XCTUnwrap(
            overlayViews.range(of: "private func conversationLane(")
        )
        let conversationLaneEnd = try XCTUnwrap(
            overlayViews[conversationLaneStart.upperBound...]
                .range(of: "/// One lane, words only")
        )
        let conversationLaneView = String(
            overlayViews[conversationLaneStart.lowerBound..<conversationLaneEnd.lowerBound]
        )
        let audienceTimelineStart = try XCTUnwrap(
            overlayViews.range(of: "private func audienceTimelineBody(")
        )
        let audienceTimelineEnd = try XCTUnwrap(
            overlayViews[audienceTimelineStart.upperBound...]
                .range(of: "/// One language's track")
        )
        let audienceTimelineView = String(
            overlayViews[audienceTimelineStart.lowerBound..<audienceTimelineEnd.lowerBound]
        )
        XCTAssertTrue(captureViews.contains("try await capture.start(notebookId: notebookId)"))
        XCTAssertTrue(captureViews.contains("try await capture.setPaused"))
        XCTAssertTrue(captureViews.contains("try await capture.stop()"))
        XCTAssertTrue(captureViews.contains("@FocusState"))
        XCTAssertTrue(captureViews.contains("accessibilityReduceMotion"))
        XCTAssertTrue(captureViews.contains("capture.transcript.waiting_lane"))
        XCTAssertTrue(captureViews.contains("capture.transcript.unselected_language"))
        XCTAssertFalse(captureViews.contains("【超出当前语言对】"))
        XCTAssertTrue(captureViews.contains("capture.settings.context.selected"))
        XCTAssertTrue(captureViews.contains("capture.settings.context.not_selected"))
        XCTAssertTrue(captureViews.contains("NotebookCaptureProfileEditorModel"))
        XCTAssertTrue(captureViews.contains("func prepareForCaptureStart() async throws"))
        XCTAssertTrue(captureViews.contains(
            "try await profileEditor.prepareForCaptureStart()"
        ))
        let startButtonStart = try XCTUnwrap(
            captureViews.range(of: "private var startButton: some View")
        )
        let startButtonEnd = try XCTUnwrap(
            captureViews[startButtonStart.upperBound...]
                .range(of: "private var pauseButton: some View")
        )
        let startButtonSource = String(
            captureViews[startButtonStart.lowerBound..<startButtonEnd.lowerBound]
        )
        let profilePreparation = try XCTUnwrap(
            startButtonSource.range(of: "try await profileEditor.prepareForCaptureStart()")
        )
        let captureStart = try XCTUnwrap(
            startButtonSource.range(of: "NotebookCaptureStartCoordinator(")
        )
        XCTAssertLessThan(
            profilePreparation.lowerBound,
            captureStart.lowerBound,
            "Start must durably authorize the latest language profile before preparing audio"
        )
        XCTAssertFalse(documentEditor.contains("NotebookCaptureToolbar("))
        XCTAssertEqual(
            captureViews.components(separatedBy: "NotebookCaptureToolbar(").count - 1,
            1,
            "Realtime Transcript must be the only mounted capture command surface"
        )
        XCTAssertTrue(captureViews.contains("navigation.openRealtimeTranscript("))
        XCTAssertTrue(captureViews.contains("profileForNotebook"))
        XCTAssertFalse(captureViews.contains("@Environment(\\.dismiss)"))
        XCTAssertFalse(captureViews.contains("@State private var isShowingSettings"))
        XCTAssertFalse(captureViews.contains("Button(String(localized: \"common.save\"))"))
        XCTAssertTrue(documentEditor.contains("CaptureSettingsTabButton"))
        XCTAssertTrue(documentEditor.contains("NotebookRealtimeTranscriptPage("))
        XCTAssertTrue(documentEditor.contains("NotebookCaptureSettingsView("))
        XCTAssertEqual(
            documentEditor.components(separatedBy: "@StateObject private var captureProfileEditor").count - 1,
            1,
            "DocumentEditorPage must own exactly one Notebook-scoped profile editor"
        )
        XCTAssertEqual(
            documentEditor.components(separatedBy: "editor: captureProfileEditor").count - 1,
            2,
            "Realtime and Settings must observe the same profile editor instance"
        )
        XCTAssertTrue(documentEditor.contains(".id(notebookId)"))
        XCTAssertTrue(mainShell.contains(".id(activeEditorRoute?.notebookID ?? \"no-notebook-route\")"))
        XCTAssertTrue(documentEditor.contains("capture settings is a fourth UI-only surface"))
        XCTAssertFalse(documentEditor.contains("tabID: \"capture-settings\""))
        XCTAssertTrue(documentEditor.contains("makeFirstResponder(nil)"))
        XCTAssertTrue(documentEditor.contains("tv.isEditable = isEditable"))
        XCTAssertFalse(documentEditor.contains("showsCaptureToolbar"))
        XCTAssertFalse(captureViews.contains("revealRealtimeTranscriptOnStart"))
        XCTAssertFalse(documentEditor.contains("captureProfileEditor: captureProfileEditor"))
        XCTAssertTrue(documentEditor.contains(
            "NotebookDocumentSurfacePolicy.mountsLoroTextEditor"
        ))
        XCTAssertFalse(settingsView.contains("remoteSection"))
        XCTAssertFalse(settingsView.contains("translationSection"))
        XCTAssertFalse(settingsView.contains("NotebookCaptureSettingsIntentQueue"))
        XCTAssertTrue(settingsView.contains("selectContextPack(pack.id)"))
        XCTAssertTrue(settingsView.contains(
            "try capture.selectContextPackForTranscription(packId, notebookId: notebookId)"
        ))
        XCTAssertFalse(settingsView.contains("scheduleContextIntent("))
        XCTAssertFalse(settingsView.contains("contextReviewRequired"))
        XCTAssertFalse(
            settingsView.contains("privacyNotice"),
            "recording settings should not repeat a separate privacy banner"
        )
        XCTAssertFalse(
            contextSection.contains("\"lock.fill\""),
            "reference-material status should describe use, not imply that controls are locked"
        )
        XCTAssertFalse(
            contextSection.contains("if draft.remoteRealtimeEnabled"),
            "a new Notebook must be able to prepare references before its first recording"
        )
        XCTAssertTrue(settingsView.contains("profile.remoteRealtimeEnabled = true"))
        XCTAssertTrue(settingsView.contains("profile.sendContextToSoniox = true"))
        XCTAssertTrue(settingsView.contains("contextPackDisplayTitle(pack)"))
        XCTAssertFalse(
            settingsView.contains("Text(pack.title)"),
            "the stored private-pack title is an internal name and must not leak into the UI"
        )
        XCTAssertFalse(
            settingsView.contains("set: { setPack("),
            "library pack Binding setters must enqueue a concrete bind intent"
        )
        XCTAssertFalse(settingsView.contains(
            ".onChange(of: capture.contextPreview?.digest) { _, _ in\n            editor.contextConsentDidChange()"
        ))
        XCTAssertFalse(realtimeConsole.contains("remoteRealtimeBinding"))
        XCTAssertFalse(realtimeConsole.contains("remoteConsentSection"))
        XCTAssertFalse(realtimeConsole.contains("capture.settings.remote.toggle"))
        XCTAssertTrue(realtimeConsole.contains("automaticRealtimeDisclosure"))
        XCTAssertTrue(realtimeConsole.contains("capture.settings.realtime.start_disclosure"))
        XCTAssertTrue(realtimeConsole.contains(".addLanguage("))
        XCTAssertTrue(realtimeConsole.contains(".removeLanguage("))
        XCTAssertTrue(realtimeConsole.contains(".moveLanguage("))
        XCTAssertFalse(
            realtimeConsole.contains(".selectedLanguages("),
            "language controls must enqueue semantic edits instead of stale full snapshots"
        )
        XCTAssertFalse(realtimeConsole.contains("modeBinding"))
        XCTAssertFalse(realtimeConsole.contains("languageABinding"))
        XCTAssertFalse(realtimeConsole.contains("languageBBinding"))
        XCTAssertTrue(realtimeConsole.contains("editor.scheduleUpdate("))
        XCTAssertTrue(realtimeConsole.contains("NotebookRealtimeConsolePresentation.resolve("))
        XCTAssertTrue(activeSummary.contains("capture.profile"))
        XCTAssertTrue(activeSummary.contains("capture.isAudioDrainDelayed"))
        XCTAssertTrue(activeSummary.contains("externaldrive.badge.timemachine"))
        XCTAssertTrue(activeSummary.contains("capture.state.audio_drain_delayed"))
        XCTAssertFalse(
            activeSummary.contains("engineStore"),
            "active runs must render persisted run state rather than the current next-run engine descriptor"
        )
        for forbidden in ["Toggle(", "Picker(", ".pickerStyle", ".help(", "Binding(", "editor.draft"] {
            XCTAssertFalse(
                activeSummary.contains(forbidden),
                "active recording summary must not mount \(forbidden)"
            )
        }
        XCTAssertTrue(realtimeConsole.contains("persistenceStatus"))
        XCTAssertFalse(
            inactiveEditor.contains(".disabled("),
            "load/save failure recovery must remain enabled when profile inputs are disabled"
        )
        XCTAssertTrue(
            realtimeConsole.contains("private var inactiveProfileControls: some View"),
            "profile input disabling must be scoped away from autosave recovery actions"
        )
        XCTAssertFalse(realtimeConsole.contains("NotebookRealtimeConfigurationVisibility.resolve("))
        XCTAssertTrue(realtimeConsole.contains("languageSelectionSection"))
        XCTAssertFalse(realtimeConsole.contains("processingModeSection"))
        XCTAssertFalse(realtimeConsole.contains("languagePairSection"))
        XCTAssertTrue(realtimeConsole.contains("capture.settings.languages.question"))
        XCTAssertTrue(realtimeConsole.contains("languageSearchResults"))
        XCTAssertTrue(realtimeConsole.contains("addLanguage("))
        XCTAssertTrue(realtimeConsole.contains("removeLanguage(at:"))
        XCTAssertTrue(realtimeConsole.contains("moveLanguage(at:"))
        XCTAssertTrue(realtimeConsole.contains("draft.selectedLanguages.count > 1"))
        XCTAssertTrue(captureViews.contains("maximumSelectedCount = 3"))
        XCTAssertFalse(realtimeConsole.contains("isCommonCaption"))
        XCTAssertFalse(realtimeConsole.contains("capture.settings.languages.common_caption"))
        XCTAssertTrue(realtimeConsole.contains("NotebookCaptureSupportedLanguages.options()"))
        XCTAssertFalse(
            realtimeConsole.contains("engineStore"),
            "provider and model identity belong in settings, not the recording console"
        )
        XCTAssertTrue(realtimeConsole.contains("credentialSession.snapshot()"))
        XCTAssertTrue(realtimeConsole.contains("credentialAttentionTitle"))
        XCTAssertFalse(
            realtimeConsole.contains("credential.loaded_unverified"),
            "a healthy credential must stay silent in the recording console"
        )
        XCTAssertGreaterThanOrEqual(
            realtimeConsole
                .components(separatedBy: "NotebookRealtimeControlLayoutPolicy.minimumInteractiveTarget")
                .count - 1,
            1,
            "language search must retain a 44-point interaction target"
        )
        XCTAssertFalse(realtimeConsole.contains(".frame(width: 230)"))
        XCTAssertFalse(
            realtimeConsole.contains("ViewThatFits(in: .horizontal)"),
            "the realtime console must mount each native form control once"
        )
        XCTAssertFalse(
            realtimeConsole.contains("editor.update {"),
            "SwiftUI Binding setters must enqueue explicit profile actions instead of publishing synchronously"
        )
        XCTAssertTrue(realtimeTranscriptView.contains("NotebookRealtimeProjectionPolicy.layout"))
        XCTAssertTrue(realtimeTranscriptView.contains("case .snapshotUnavailable:"))
        XCTAssertTrue(realtimeTranscriptView.contains("private var bilingualLayout"))
        XCTAssertTrue(realtimeTranscriptView.contains("private var transcriptionOnlyLayout"))
        XCTAssertTrue(realtimeTranscriptView.contains("TranscriptionUtteranceRow("))
        XCTAssertEqual(
            realtimeTranscriptView.components(separatedBy: ".onChange(of: latestUtteranceID)").count - 1,
            0,
            "run sections must not create nested token-driven scroll loops"
        )
        XCTAssertFalse(realtimeTranscriptView.contains("latestUtteranceRevisionKey"))
        XCTAssertFalse(realtimeTranscriptView.contains(".onChange(of: visibleUtterances.count)"))
        XCTAssertEqual(
            captureViews.components(separatedBy: "capture.loadUtterances(").count - 1,
            0,
            "session focus must never replace the Notebook-wide history query"
        )
        XCTAssertTrue(captureViews.contains("await history.load(notebookId: notebookId)"))
        XCTAssertTrue(
            captureViews.contains("refreshActiveSessionSpeakers(activeSessionSpeakerIds)"),
            "catalog completion must rehydrate an already-active capture's speaker metadata"
        )
        XCTAssertTrue(activeCapture.contains("listNotebookCaptureHistory(notebookId:"))
        XCTAssertTrue(realtimeTranscriptView.contains("NotebookCaptureHistoryPolicy.laneProjection("))
        XCTAssertTrue(realtimeTranscriptView.contains("languageCount: displayLanguages.count"))
        XCTAssertTrue(captureViews.contains("ForEach(Array(projection.lanes.enumerated())"))
        XCTAssertTrue(captureViews.contains("NotebookCaptureLanguageLane"))
        XCTAssertTrue(laneTextView.contains("scheduleFocusChange"))
        XCTAssertTrue(laneTextView.contains("scheduleTextSync"))
        XCTAssertTrue(
            laneTextView.contains("scheduleTextSync(text)"),
            "the first editable lane appearance must seed the latest authoritative provider text"
        )
        XCTAssertTrue(laneTextView.contains("scheduleDisappear"))
        XCTAssertTrue(
            laneTextView.contains(".lineLimit(2...)"),
            "editable language-column rows must grow with their complete text"
        )
        XCTAssertFalse(
            laneTextView.contains(".lineLimit(2...10)"),
            "a ten-line editor cap hides the tail instead of growing the utterance row"
        )
        XCTAssertFalse(
            laneTextView.contains(".onChange(of: target)"),
            "lane identity already retargets with .id; a second synchronous retarget loop re-enters SwiftUI"
        )
        XCTAssertTrue(realtimeTranscriptView.contains("runHeader"))
        XCTAssertTrue(realtimeTranscriptView.contains("createdAtText"))
        XCTAssertTrue(realtimeTranscriptView.contains("run.utterances.isEmpty"))
        XCTAssertTrue(realtimeTranscriptView.contains("capture.transcript.copy"))
        XCTAssertTrue(realtimeTranscriptView.contains("getSessionTranscriptClipboardText"))
        XCTAssertTrue(realtimeTranscriptView.contains("TranscriptClipboard.write"))
        XCTAssertTrue(realtimeTranscriptView.contains(
            "run.utterances.isEmpty == false && laneEditingState.canSwap"
        ))
        XCTAssertTrue(realtimeTranscriptView.contains(".frame(minWidth: 44, minHeight: 44)"))
        XCTAssertTrue(captureViews.contains("projection.pendingLanguage"))
        XCTAssertTrue(captureViews.contains("projection.unselectedLanguageText"))
        XCTAssertTrue(captureViews.contains("capture.transcript.language_pending"))
        XCTAssertTrue(captureViews.contains("missingLaneState == .waiting"))
        XCTAssertTrue(captureViews.contains("missingLaneState == .failed"))
        XCTAssertTrue(captureViews.contains("capture.transcript.failed_lane"))
        XCTAssertTrue(captureViews.contains("Text(sourceLanguageLabel)"))
        XCTAssertTrue(captureViews.contains("normalizedSourceLanguage == \"und\""))
        XCTAssertFalse(realtimeTranscriptView.contains("bilingualHeader"))
        XCTAssertFalse(realtimeTranscriptView.contains("languageHeading("))
        XCTAssertEqual(
            realtimeTranscriptView
                .components(separatedBy: ".frame(height: NotebookRealtimeTranscriptLayout.headerHeight)")
                .count - 1,
            1,
            "comparison columns should begin with text; only the timeline keeps a heading"
        )
        XCTAssertFalse(realtimeTranscriptView.contains("capture.transcript.swap"))
        XCTAssertFalse(realtimeTranscriptView.contains("columnsReversed"))
        XCTAssertFalse(realtimeTranscriptView.contains(
            "capture.settings.languages.common_caption"
        ))
        XCTAssertTrue(realtimeTranscriptView.contains(
            ".accessibilityLabel(Text(String(localized: \"capture.transcript.realtime_accessibility_label\")))"
        ))
        XCTAssertGreaterThanOrEqual(
            documentEditor.components(separatedBy: ".accessibilityHidden(").count - 1,
            2,
            "hidden editor and transcript layers must leave the accessibility tree"
        )
        XCTAssertGreaterThanOrEqual(
            captureViews.components(separatedBy: "ViewThatFits(in: .horizontal)").count - 1,
            2,
            "Context Pack controls and recording history headers must degrade for narrow windows"
        )
        XCTAssertTrue(captureViews.contains(".textSelection(.enabled)"))
        XCTAssertTrue(captureViews.contains(".help(message)"))
        XCTAssertTrue(captureViews.contains("onReplace(target.laneLanguage"))
        XCTAssertFalse(captureViews.contains(".disabled(laneEditingState.canSwap == false)"))
        XCTAssertFalse(menu.contains("requestTogglePause"))
        XCTAssertFalse(menu.contains("requestToggleRecording"))
        XCTAssertFalse(overlays.contains("MicrophoneCapture"))
        XCTAssertEqual(
            activeCapture.components(separatedBy: "MicrophoneCapture.shared.subscribe").count - 1,
            1,
            "the app must have one capture-owned microphone subscription site"
        )
        XCTAssertFalse(activeCapture.contains("DispatchSemaphore"))
        XCTAssertFalse(activeCapture.contains(".wait()"))
        XCTAssertFalse(activeCapture.contains("stateLock.try"))
        XCTAssertTrue(activeCapture.contains("import Synchronization"))
        XCTAssertTrue(activeCapture.contains("capture.error.profile_snapshot_unavailable"))
        XCTAssertFalse(activeCapture.contains("Capture profile snapshot is unavailable."))
        XCTAssertTrue(overlayViews.contains("if store.isCaptureActive == false"))
        XCTAssertTrue(overlayViews.contains("capture.transcript.waiting_lane"))
        XCTAssertTrue(overlayViews.contains("capture.transcript.unselected_language"))
        XCTAssertTrue(overlayViews.contains("capture.transcript.language_pending"))
        XCTAssertTrue(overlayViews.contains("lane.missingLaneState == .waiting"))
        XCTAssertTrue(overlayViews.contains("lane.missingLaneState == .failed"))
        XCTAssertTrue(overlayViews.contains("capture.transcript.failed_lane"))
        XCTAssertTrue(overlayViews.contains("store.selectedLanguages"))
        XCTAssertTrue(overlayViews.contains("store.projection(for: utterance)"))
        XCTAssertFalse(overlays.contains("commonCaptionLanguage"))
        XCTAssertFalse(
            overlayViews.contains("private var languageHeader"),
            "floating Compare columns should begin with subtitle text, without a redundant language header"
        )
        XCTAssertFalse(
            overlayViews.contains("showsLanguageHeader"),
            "stacked Compare lanes should not reintroduce visible language labels"
        )
        XCTAssertTrue(conversationLaneView.contains(
            ".accessibilityLabel(Text(languageName(lane.language)))"
        ))
        XCTAssertTrue(conversationLaneView.contains(
            ".accessibilityValue(Text(conversationLaneAccessibilityValue(lane)))"
        ))
        XCTAssertTrue(overlayViews.contains("ForEach(Array(displayLanes(projection).enumerated())"))
        XCTAssertTrue(overlayViews.contains("SubtitleOverlayDisplayMode"))
        XCTAssertTrue(overlayViews.contains("SubtitleOverlayLayoutPolicy"))
        XCTAssertTrue(
            overlayViews.contains("alignment: .bottom"),
            "audience rows anchor to the bottom edge so the newest words are always fully visible"
        )
        XCTAssertTrue(
            conversationRowView.contains("HStack(alignment: .bottom, spacing: 0)"),
            "conversation columns must share a visible bottom edge when language lengths diverge"
        )
        XCTAssertFalse(
            conversationRowView.contains("HStack(alignment: .top, spacing: 0)"),
            "top-aligned short conversation lanes disappear when the longest lane clips at the top"
        )
        XCTAssertTrue(
            overlayViews.contains(".clipped()"),
            "overflow leaves through the top edge; history yields to the words being spoken"
        )
        XCTAssertTrue(
            overlayViews.contains(".fixedSize(horizontal: false, vertical: true)"),
            "audience rows keep their natural text height instead of truncating inside equal slices"
        )
        XCTAssertTrue(
            overlayViews.contains("alignment: .bottomLeading"),
            "lane text anchors to the card bottom so a short language survives top-edge clipping"
        )
        XCTAssertTrue(
            conversationLaneView.contains("alignment: .bottomLeading"),
            "each conversation lane must keep its newest tail on the shared bottom edge"
        )
        XCTAssertFalse(
            conversationLaneView.contains("alignment: .topLeading"),
            "a conversation lane must not retain a conflicting top anchor"
        )
        XCTAssertFalse(
            overlayViews.contains("maxHeight: .infinity, alignment: .topLeading"),
            "a top-anchored lane vanishes entirely when a taller sibling clips the row through the top"
        )
        XCTAssertFalse(
            overlayViews.contains("LazyVGrid"),
            "audience lanes stretch to fill their share; a content-sized grid leaves blank canvas"
        )
        XCTAssertTrue(overlayViews.contains(
            "SubtitleOverlayLayoutPolicy.audienceRowCount("
        ))
        XCTAssertTrue(audienceTimelineView.contains("store.presentedAudienceUtterances("))
        XCTAssertFalse(
            audienceTimelineView.contains("store.presentedUtteranceTail("),
            "a global tail would evict a sparse language whose own visible suffix is still current"
        )
        XCTAssertTrue(audienceTimelineView.contains("store.makeAudienceSourcePlacement()"))
        XCTAssertFalse(
            audienceTimelineView.contains("store.presentedUtterances"),
            "Audience must never rebuild the complete session during a live frame"
        )
        XCTAssertFalse(
            overlayViews.contains("presentedUtterances.suffix(2)"),
            "audience retention is height-driven; a fixed pair evicts a translation before it can be read"
        )
        XCTAssertFalse(overlayViews.contains("commonCaptionLanguage"))
        XCTAssertFalse(overlayViews.contains("capture.settings.languages.common_caption"))
        XCTAssertFalse(overlayViews.contains("isCommonCaption"))
        XCTAssertFalse(overlayViews.contains("index == 0"))
        XCTAssertFalse(overlayViews.contains("【超出当前语言对】"))
        XCTAssertTrue(overlayViews.contains("ScrollView {"))
        XCTAssertTrue(overlayViews.contains("LazyVStack(spacing: 10)"))
        XCTAssertTrue(overlayViews.contains(".defaultScrollAnchor(.bottom)"))
        XCTAssertTrue(overlayViews.contains("SubtitleOverlayFontPolicy"))
        XCTAssertFalse(overlayViews.contains("Text(\"Source:"))
        XCTAssertFalse(documentEditor.contains("struct TranscriptView: View"))
        XCTAssertTrue(captureViews.contains("NotebookRealtimeUtteranceView("))
        XCTAssertFalse(documentEditor.contains("shouldShowBilingualTranscript"))
        XCTAssertFalse(captureViews.contains("NotebookBilingualTranscriptView"))

        for locale in ["en", "zh-Hans", "ja"] {
            let strings = try String(
                contentsOf: root.appendingPathComponent("Resources/\(locale).lproj/Localizable.strings"),
                encoding: .utf8
            )
            for key in [
                "capture.settings.languages.question",
                "capture.settings.languages.ordered_detail",
                "capture.settings.languages.search",
                "capture.settings.languages.no_results",
                "capture.settings.languages.maximum_reached",
                "capture.settings.languages.add_format",
                "capture.settings.languages.move_earlier",
                "capture.settings.languages.move_later",
                "capture.settings.languages.remove",
                "capture.transcript.unselected_language",
                "capture.transcript.presentation.timeline",
                "capture.transcript.presentation.timeline_detail",
                "capture.transcript.presentation.language_columns",
                "capture.transcript.presentation.language_columns_detail",
                "capture.transcript.failed_lane",
                "capture.error.profile_snapshot_unavailable",
                "capture.settings.context.selected",
                "capture.settings.context.not_selected",
                "capture.settings.context.current_notebook_detail",
                "capture.settings.tab",
                "capture.settings.tab_hint",
                "capture.settings.autosave.saved",
                "capture.settings.autosave.save_failed",
                "capture.settings.active_locked",
                "capture.settings.footer.realtime",
                "capture.settings.context.create_library",
                "capture.settings.retention.title",
                "capture.settings.realtime.start_disclosure",
                "capture.realtime.controls.current_title",
                "capture.realtime.controls.profile_group",
                "capture.realtime.controls.review_context",
                "capture.transcript.realtime_accessibility_label",
                "capture.transcript.transcription_heading",
                "capture.transcript.transcription_empty_title",
                "capture.transcript.transcription_empty_detail",
                "capture.transcript.snapshot_unavailable_detail",
                "capture.transcript.copy",
                "capture.transcript.copy_hint",
                "capture.transcript.copy_empty_hint",
                "capture.transcript.copy_finish_edit_hint",
                "capture.transcript.copy_success",
                "capture.transcript.copy_success_detail",
                "capture.transcript.copy_success_live_detail",
                "capture.transcript.copy_failed",
                "capture.transcript.copy_clipboard_failed",
                "subtitle.overlay.title",
                "subtitle.overlay.accessibility_label",
                "subtitle.overlay.language_count",
                "subtitle.overlay.background_opacity",
                "subtitle.overlay.font_smaller",
                "subtitle.overlay.font_larger",
                "subtitle.overlay.move_resize_hint",
                "subtitle.overlay.maximize",
                "subtitle.overlay.restore",
                "subtitle.overlay.pin",
                "subtitle.overlay.unpin",
                "subtitle.overlay.pinned",
                "subtitle.overlay.unpinned",
                "subtitle.overlay.mode",
                "subtitle.overlay.mode.conversation",
                "subtitle.overlay.mode.audience",
                "subtitle.overlay.mode.conversation.help",
                "subtitle.overlay.mode.audience.help",
                "capture.toolbar.subtitle_window.open",
                "capture.toolbar.subtitle_window.close",
                "menubar.recording.open_subtitles",
                "menubar.recording.close_subtitles",
            ] {
                XCTAssertTrue(strings.contains("\"\(key)\" ="), "\(locale) must define \(key)")
            }
            XCTAssertFalse(
                strings.contains("\"capture.settings.languages.common_caption\" ="),
                "\(locale) must not describe the first selected language as a special caption lane"
            )
            for retiredLabel in ["Public caption", "公共字幕", "共通字幕"] {
                XCTAssertFalse(
                    strings.localizedCaseInsensitiveContains(retiredLabel),
                    "\(locale) must not expose the retired public-caption concept"
                )
            }
        }
    }
}

private enum TestCaptureSettingsError: LocalizedError {
    case readFailed
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .readFailed: return "profile read failed"
        case .writeFailed: return "profile write failed"
        }
    }
}

@MainActor
private final class FakeNotebookCaptureProfilePersistence: NotebookCaptureProfilePersisting {
    var profile: NotebookCaptureProfileDTO
    var isCaptureActive = false
    var lastError: String?
    var loadError: TestCaptureSettingsError?
    var saveError: TestCaptureSettingsError?
    private(set) var saveRequests: [NotebookCaptureProfileDTO] = []

    init(profile: NotebookCaptureProfileDTO) {
        self.profile = profile
    }

    func profileForNotebook(_ notebookId: String) -> NotebookCaptureProfileDTO {
        if let loadError {
            lastError = loadError.localizedDescription
            return .localDefault(notebookId: notebookId)
        }
        lastError = nil
        return profile
    }

    func saveProfile(
        _ candidate: NotebookCaptureProfileDTO
    ) throws -> NotebookCaptureProfileDTO {
        saveRequests.append(candidate)
        if let saveError { throw saveError }

        var saved = candidate
        saved.revision += 1
        profile = saved
        return saved
    }
}

@MainActor
private final class FakeNotebookTranscriptEditorClient: NotebookTranscriptEditorClienting {
    private(set) var openCount = 0
    private(set) var closeCount = 0
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0
    private(set) var deltaReadCount = 0
    private(set) var registeredCallback: (any FfiEditorCallback)?
    var delta = "[]"
    var writable = true

    func openEditor(notebookId: String, tabId: String) throws {
        _ = notebookId
        _ = tabId
        openCount += 1
    }

    func closeEditor(notebookId: String, tabId: String) throws {
        _ = notebookId
        _ = tabId
        closeCount += 1
    }

    func registerEditorCallback(
        notebookId: String,
        tabId: String,
        callback: any FfiEditorCallback
    ) throws {
        _ = notebookId
        _ = tabId
        registerCount += 1
        registeredCallback = callback
    }

    func unregisterEditorCallback(notebookId: String, tabId: String) throws {
        _ = notebookId
        _ = tabId
        unregisterCount += 1
        registeredCallback = nil
    }

    func editorDelta(notebookId: String, tabId: String) throws -> String {
        _ = notebookId
        _ = tabId
        deltaReadCount += 1
        return delta
    }

    func isEditorWritable(notebookId: String, tabId: String) throws -> Bool {
        _ = notebookId
        _ = tabId
        return writable
    }

    func replaceEditorText(
        notebookId: String,
        tabId: String,
        position: UInt64,
        length: UInt64,
        text: String
    ) throws {
        _ = notebookId
        _ = tabId
        _ = position
        _ = length
        _ = text
    }
}

private final class BlockingAudioPushController: @unchecked Sendable {
    private let firstPushStarted = DispatchSemaphore(value: 0)
    private let releaseFirstPushSemaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var pushCount = 0
    private var completedPushCount = 0

    nonisolated func push(_ data: Data) -> String? {
        lock.lock()
        pushCount += 1
        let ordinal = pushCount
        lock.unlock()

        if ordinal == 1 {
            firstPushStarted.signal()
            releaseFirstPushSemaphore.wait()
        }

        lock.lock()
        completedPushCount += 1
        lock.unlock()
        return nil
    }

    nonisolated func waitForFirstPush(timeout: TimeInterval = 1) -> Bool {
        firstPushStarted.wait(timeout: .now() + timeout) == .success
    }

    nonisolated func releaseFirstPush() {
        releaseFirstPushSemaphore.signal()
    }

    nonisolated var completedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return completedPushCount
    }
}

@MainActor
private final class BlockingNotebookInterruptController {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isReleased = false
    private(set) var isWaiting = false
    private(set) var didFinish = false

    func wait() async {
        guard isReleased == false else {
            didFinish = true
            return
        }
        isWaiting = true
        await withCheckedContinuation { continuation in
            if isReleased {
                continuation.resume()
            } else {
                self.continuation = continuation
            }
        }
        isWaiting = false
        didFinish = true
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class BlockingNotebookPauseController {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isReleased = false
    private(set) var isWaiting = false

    func wait() async {
        guard isReleased == false else { return }
        isWaiting = true
        await withCheckedContinuation { continuation in
            if isReleased {
                continuation.resume()
            } else {
                self.continuation = continuation
            }
        }
        isWaiting = false
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class BlockingNotebookReconcileController {
    private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]
    private var releasedCalls: Set<Int> = []
    private(set) var waitingCalls: Set<Int> = []

    func wait(call: Int) async {
        guard releasedCalls.contains(call) == false else { return }
        waitingCalls.insert(call)
        await withCheckedContinuation { continuation in
            if releasedCalls.contains(call) {
                continuation.resume()
            } else {
                continuations[call] = continuation
            }
        }
        waitingCalls.remove(call)
    }

    func release(call: Int) {
        releasedCalls.insert(call)
        continuations.removeValue(forKey: call)?.resume()
    }

    func isWaiting(call: Int) -> Bool {
        waitingCalls.contains(call)
    }
}

@MainActor
private final class BlockingNotebookUtteranceLoadController {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isReleased = false
    private(set) var isWaiting = false

    func wait() async {
        guard isReleased == false else { return }
        isWaiting = true
        await withCheckedContinuation { continuation in
            if isReleased {
                continuation.resume()
            } else {
                self.continuation = continuation
            }
        }
        isWaiting = false
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class BlockingNotebookCatalogLoadController {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isReleased = false
    private(set) var isWaiting = false

    func wait() async {
        guard isReleased == false else { return }
        isWaiting = true
        await withCheckedContinuation { continuation in
            if isReleased {
                continuation.resume()
            } else {
                self.continuation = continuation
            }
        }
        isWaiting = false
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}

private final class LockedStrings: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    nonisolated func append(_ value: String) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    nonisolated var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class MicrophoneWorkerRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedAudioGenerations: [UInt64] = []
    private var storedAudioByteCounts: [Int] = []
    private var storedOverflowGenerations: [UInt64] = []

    nonisolated func recordAudio(generation: UInt64, data: Data) {
        lock.lock()
        storedAudioGenerations.append(generation)
        storedAudioByteCounts.append(data.count)
        lock.unlock()
    }

    nonisolated func recordOverflow(generation: UInt64) {
        lock.lock()
        storedOverflowGenerations.append(generation)
        lock.unlock()
    }

    nonisolated var audioGenerations: [UInt64] {
        lock.lock()
        defer { lock.unlock() }
        return storedAudioGenerations
    }

    nonisolated var audioByteCounts: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return storedAudioByteCounts
    }

    nonisolated var overflowGenerations: [UInt64] {
        lock.lock()
        defer { lock.unlock() }
        return storedOverflowGenerations
    }
}

private final class AudioGateCloseRaceHarness: @unchecked Sendable {
    let gate: NotebookCaptureAudioPushGate
    private let reasons: LockedStrings
    private let resultLock = NSLock()
    nonisolated(unsafe) private var submissionResult: NotebookCaptureAudioPushGate.SubmissionResult?

    init() {
        let reasons = LockedStrings()
        self.reasons = reasons
        gate = NotebookCaptureAudioPushGate(
            capacity: 1,
            push: { _ in nil },
            onTerminal: { reasons.append($0) }
        )
    }

    nonisolated func submit() {
        let result = gate.submit(Data([1]))
        resultLock.lock()
        submissionResult = result
        resultLock.unlock()
    }

    nonisolated func close() {
        gate.close()
    }

    nonisolated func fence() async {
        await gate.fence()
    }

    nonisolated var result: NotebookCaptureAudioPushGate.SubmissionResult? {
        resultLock.lock()
        defer { resultLock.unlock() }
        return submissionResult
    }

    nonisolated var terminalReasons: [String] {
        reasons.values
    }
}

@MainActor
private final class FakeNotebookCaptureAudioSource: NotebookCaptureAudioSourcing {
    private(set) var selectedInputDeviceUID: String?
    private(set) var preparedInputDevice: AudioInputDevice?
    private(set) var prepareCount = 0
    private(set) var subscribeCount = 0
    private(set) var unsubscribeCount = 0
    private(set) var subscribedInputDeviceUIDs: [String] = []
    private(set) var subscribedInputDeviceIDs: [AudioDeviceID] = []
    private(set) var committedInputDeviceUIDs: [String?] = []
    private var handler: (@Sendable (Data) -> Void)?
    private var overflowHandler: (@Sendable () -> Void)?
    var emitOnUnsubscribe: Data?
    var terminalReasonOnUnsubscribe: NotebookCaptureInterruptReason?
    var failNextSubscribeCount = 0
    var resolvedDeviceIDs: [String: AudioDeviceID] = [:]
    var defaultInputDeviceUID = "test-default-input"

    func prepare() async throws {
        prepareCount += 1
        if preparedInputDevice == nil {
            preparedInputDevice = makeDevice(uid: selectedInputDeviceUID ?? defaultInputDeviceUID)
        }
    }

    func resolveInputDevice(uid: String?) throws -> AudioInputDevice {
        makeDevice(uid: uid ?? defaultInputDeviceUID)
    }

    func commitInputDeviceSelection(uid: String?, device: AudioInputDevice) {
        selectedInputDeviceUID = uid
        preparedInputDevice = device
        committedInputDeviceUIDs.append(uid)
    }

    func subscribe(
        inputDevice: AudioInputDevice,
        onAudio: @escaping @Sendable (Data) -> Void,
        onOverflow: @escaping @Sendable () -> Void
    ) throws -> NotebookCaptureAudioToken {
        subscribeCount += 1
        subscribedInputDeviceUIDs.append(inputDevice.uid)
        subscribedInputDeviceIDs.append(inputDevice.deviceID)
        if failNextSubscribeCount > 0 {
            failNextSubscribeCount -= 1
            throw CaptureError.formatError
        }
        handler = onAudio
        overflowHandler = onOverflow
        return NotebookCaptureAudioToken(id: UUID())
    }

    @discardableResult
    func unsubscribe(_ token: NotebookCaptureAudioToken) -> NotebookCaptureInterruptReason? {
        unsubscribeCount += 1
        if let emitOnUnsubscribe {
            handler?(emitOnUnsubscribe)
            self.emitOnUnsubscribe = nil
        }
        handler = nil
        overflowHandler = nil
        let terminalReason = terminalReasonOnUnsubscribe
        terminalReasonOnUnsubscribe = nil
        return terminalReason
    }

    func emit(_ data: Data) {
        handler?(data)
    }

    func emitOverflow() {
        overflowHandler?()
    }

    private func makeDevice(uid: String) -> AudioInputDevice {
        AudioInputDevice(
            deviceID: resolvedDeviceIDs[uid]
                ?? AudioDeviceID(abs(uid.hashValue % 10_000) + 1),
            uid: uid,
            name: uid
        )
    }
}

private final class FakeAudioPushRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var payloads: [Data] = []

    nonisolated func record(_ data: Data = Data()) {
        lock.lock()
        count += 1
        payloads.append(data)
        lock.unlock()
    }

    nonisolated var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    nonisolated var values: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return payloads
    }
}

@MainActor
private final class FakeNotebookCaptureClient: NotebookCaptureClienting {
    var profile: NotebookCaptureProfileDTO
    let startUtterances: [NotebookCaptureUtteranceDTO]
    private(set) var startCount = 0
    private(set) var lastConfirmedContextDigest: String?
    private(set) var lastReplaceExpectedRevision: UInt64?
    private(set) var lastContextSourceNotebookId: String?
    private(set) var lastExportedContextPackPath: String?
    private(set) var interruptCount = 0
    private(set) var sessionEventCount = 0
    private(set) var reconcileCallCount = 0
    private(set) var previewCount = 0
    private(set) var profileUpdateCount = 0
    private(set) var contextBindingPackIds: [String] = []
    private(set) var contextBindingPositions: [UInt64?] = []
    private(set) var lastInterruptReason: NotebookCaptureInterruptReason?
    private(set) var pauseCount = 0
    private(set) var stopCount = 0
    private(set) var listUtterancesCount = 0
    private(set) var listSessionSpeakersCount = 0
    private(set) var realtimeProjectionCount = 0
    private(set) var asyncProjectionRetryCount = 0
    private(set) var historyNotebookIds: [String] = []
    var shouldFailStop = false
    var pauseError: NotebookCaptureClientError?
    var audioPushFailureMessage: String?
    var audioPushHandler: (@Sendable (Data) -> String?)?
    var sessionEventOverride: NotebookCaptureEventDTO?
    var sessionEventError: NotebookCaptureClientError?
    var interruptError: NotebookCaptureClientError?
    var interruptController: BlockingNotebookInterruptController?
    var pauseController: BlockingNotebookPauseController?
    var replaceController: BlockingNotebookPauseController?
    var reconcileController: BlockingNotebookReconcileController?
    var reconcileEvents: [NotebookCaptureEventDTO] = []
    var reconcileErrors: [NotebookCaptureClientError?] = []
    var previewDigest = "context-digest"
    var previewDigestAfterProfileUpdate: String?
    var previewSerializedContext = "{\"terms\":[\"Zulangue\"]}"
    var previewError: NotebookCaptureClientError?
    var contextPackListError: NotebookCaptureClientError?
    var contextSourceListError: NotebookCaptureClientError?
    var libraryReplacementError: NotebookCaptureClientError?
    var profileUpdateError: NotebookCaptureClientError?
    var listUtterancesOverride: [NotebookCaptureUtteranceDTO]?
    var utteranceLoadController: BlockingNotebookUtteranceLoadController?
    var catalogLoadController: BlockingNotebookCatalogLoadController?
    var historyRuns: [NotebookCaptureHistoryRunDTO]
    let historySummariesOmitUtterances: Bool
    var speakerParticipants: [SpeakerParticipantDTO]
    var sessionSpeakersBySession: [String: [NotebookSessionSpeakerDTO]]
    var asyncProjectionRetryEventOverride: NotebookCaptureEventDTO?
    var nextSessionId = "session-a"
    private let audioPushRecorder = FakeAudioPushRecorder()
    private var captureCallback: (@MainActor @Sendable (NotebookCaptureEventDTO) -> Void)?
    private var captureCallbacks: [String: @MainActor @Sendable (NotebookCaptureEventDTO) -> Void] = [:]
    private var livePreviewCallback: (
        @MainActor @Sendable (NotebookCaptureLivePreviewDTO) -> Void
    )?
    private var livePreviewCallbacks: [
        String: @MainActor @Sendable (NotebookCaptureLivePreviewDTO) -> Void
    ] = [:]
    private var lastStartedSessionId = "session-a"
    private var contextPacks: [NotebookContextPackDTO]
    private var contextSources: [String: [NotebookContextPackSourceDTO]] = [:]
    private var libraryContextPacks: [NotebookContextPackDTO] = []
    private var libraryDocuments: [String: String] = [:]
    private(set) var lastLibraryReplacementJSON: String?

    var audioPushCount: Int { audioPushRecorder.value }
    var audioPushPayloads: [Data] { audioPushRecorder.values }

    init(
        profile: NotebookCaptureProfileDTO,
        startUtterances: [NotebookCaptureUtteranceDTO] = [],
        historyRuns: [NotebookCaptureHistoryRunDTO] = [],
        speakerParticipants: [SpeakerParticipantDTO] = [],
        sessionSpeakersBySession: [String: [NotebookSessionSpeakerDTO]] = [:],
        historySummariesOmitUtterances: Bool = false
    ) {
        self.profile = profile
        self.startUtterances = startUtterances
        self.historyRuns = historyRuns
        self.speakerParticipants = speakerParticipants
        self.sessionSpeakersBySession = sessionSpeakersBySession
        self.historySummariesOmitUtterances = historySummariesOmitUtterances
        self.contextPacks = [
            NotebookContextPackDTO(
                id: "private-pack",
                scope: "private",
                ownerNotebookId: profile.notebookId,
                title: "Private Context",
                revision: 0,
                boundPosition: nil
            ),
            NotebookContextPackDTO(
                id: "library-pack",
                scope: "library",
                ownerNotebookId: nil,
                title: "Shared Terms",
                revision: 0,
                boundPosition: nil
            ),
        ]
    }

    func getNotebookCaptureProfile(notebookId: String) throws -> NotebookCaptureProfileDTO {
        profile
    }

    func updateNotebookCaptureProfile(_ profile: NotebookCaptureProfileDTO) throws -> NotebookCaptureProfileDTO {
        profileUpdateCount += 1
        if let profileUpdateError { throw profileUpdateError }
        var saved = profile
        saved.revision += 1
        self.profile = saved
        if let previewDigestAfterProfileUpdate {
            previewDigest = previewDigestAfterProfileUpdate
            self.previewDigestAfterProfileUpdate = nil
        }
        return saved
    }

    func previewNotebookCaptureContext(notebookId: String) throws -> NotebookCaptureContextPreviewDTO {
        previewCount += 1
        if let previewError { throw previewError }
        return NotebookCaptureContextPreviewDTO(
            notebookId: notebookId,
            serializedContext: previewSerializedContext,
            sources: [NotebookCaptureContextSourceDTO(
                id: "source-1",
                title: "Private terms",
                packKind: "private",
                scalarCount: 24,
                included: true,
                reason: nil
            )],
            omittedReasons: [],
            digest: previewDigest,
            scalarCount: 24
        )
    }

    func listNotebookContextPacks(notebookId: String) throws -> [NotebookContextPackDTO] {
        if let contextPackListError { throw contextPackListError }
        return contextPacks
    }

    func listLibraryContextPacks() throws -> [NotebookContextPackDTO] {
        libraryContextPacks
    }

    func readLibraryContextPack(packId: String) throws -> String {
        guard let document = libraryDocuments[packId] else {
            throw NotebookCaptureClientError.ffiUnavailable
        }
        return document
    }

    func replaceLibraryContextPack(
        packId: String,
        expectedRevision: UInt64,
        documentJson: String
    ) throws -> NotebookContextPackDTO {
        if let libraryReplacementError { throw libraryReplacementError }
        guard let index = libraryContextPacks.firstIndex(where: {
            $0.id == packId && $0.revision == expectedRevision
        }) else {
            throw NotebookCaptureClientError.ffiUnavailable
        }
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(documentJson.utf8)) as? [String: Any]
        )
        let title = try XCTUnwrap(object["title"] as? String)
        let old = libraryContextPacks[index]
        let saved = NotebookContextPackDTO(
            id: old.id,
            scope: old.scope,
            ownerNotebookId: nil,
            title: title,
            revision: old.revision + 1,
            boundPosition: nil
        )
        libraryContextPacks[index] = saved
        libraryDocuments[packId] = documentJson
        lastLibraryReplacementJSON = documentJson
        return saved
    }

    func createLibraryContextPack(title: String) throws -> NotebookContextPackDTO {
        let id = UUID().uuidString.lowercased()
        let pack = NotebookContextPackDTO(
            id: id,
            scope: "library",
            ownerNotebookId: nil,
            title: title,
            revision: 0,
            boundPosition: nil
        )
        contextPacks.append(pack)
        libraryContextPacks.append(pack)
        libraryDocuments[id] = "{\"schema\":\"zulangue.context-pack.v1\",\"title\":\"\(title)\",\"sources\":[]}"
        return pack
    }

    func copyNotebookPrivateContextToLibrary(
        notebookId: String,
        title: String
    ) throws -> NotebookContextPackDTO {
        try createLibraryContextPack(title: title)
    }

    func setNotebookContextPackBinding(
        notebookId: String,
        packId: String,
        position: UInt64?
    ) throws {
        contextBindingPackIds.append(packId)
        contextBindingPositions.append(position)
        guard let index = contextPacks.firstIndex(where: { $0.id == packId }) else { return }
        let old = contextPacks[index]
        contextPacks[index] = NotebookContextPackDTO(
            id: old.id,
            scope: old.scope,
            ownerNotebookId: old.ownerNotebookId,
            title: old.title,
            revision: old.revision,
            boundPosition: position
        )
    }

    func listContextPackSources(
        notebookId: String,
        packId: String
    ) throws -> [NotebookContextPackSourceDTO] {
        if let contextSourceListError { throw contextSourceListError }
        lastContextSourceNotebookId = notebookId
        return contextSources[packId, default: []]
    }

    func importContextPackText(
        notebookId: String,
        packId: String,
        title: String,
        text: String,
        contentKind: String
    ) throws -> NotebookContextPackSourceDTO {
        lastContextSourceNotebookId = notebookId
        let source = NotebookContextPackSourceDTO(
            id: "source-\(contextSources[packId, default: []].count)",
            packId: packId,
            title: title,
            format: "text",
            contentKind: contentKind,
            plaintextSha256: "digest",
            plaintextBytes: UInt64(text.utf8.count),
            trusted: true,
            revision: 0
        )
        contextSources[packId, default: []].append(source)
        return source
    }

    func exportContextPack(
        notebookId: String,
        packId: String,
        destinationPath: String
    ) throws -> UInt32 {
        lastContextSourceNotebookId = notebookId
        lastExportedContextPackPath = destinationPath
        return UInt32(contextSources[packId, default: []].count)
    }

    func importContextPack(
        sourcePath: String,
        titleOverride: String?
    ) throws -> NotebookContextPackDTO {
        let rawDocument = try String(contentsOfFile: sourcePath, encoding: .utf8)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(rawDocument.utf8)) as? [String: Any]
        )
        let documentTitle = try XCTUnwrap(object["title"] as? String)
        let id = UUID().uuidString.lowercased()
        let pack = NotebookContextPackDTO(
            id: id,
            scope: "library",
            ownerNotebookId: nil,
            title: titleOverride ?? documentTitle,
            revision: 0,
            boundPosition: nil
        )
        contextPacks.append(pack)
        libraryContextPacks.append(pack)
        libraryDocuments[id] = rawDocument
        return pack
    }

    func deleteContextPackSource(notebookId: String, sourceId: String) throws -> Bool {
        lastContextSourceNotebookId = notebookId
        for packId in Array(contextSources.keys) {
            if let index = contextSources[packId]?.firstIndex(where: { $0.id == sourceId }) {
                contextSources[packId]?.remove(at: index)
                return true
            }
        }
        return false
    }

    func deleteLibraryContextPack(packId: String, expectedRevision: UInt64) throws -> Bool {
        var deleted = false
        if let index = contextPacks.firstIndex(where: { $0.id == packId && !$0.isPrivate }) {
            contextPacks.remove(at: index)
            contextSources[packId] = nil
            deleted = true
        }
        if let index = libraryContextPacks.firstIndex(where: {
            $0.id == packId && $0.revision == expectedRevision
        }) {
            libraryContextPacks.remove(at: index)
            libraryDocuments[packId] = nil
            deleted = true
        }
        return deleted
    }

    func startNotebookCaptureSession(
        notebookId: String,
        profileRevision: UInt64,
        confirmedContextDigest: String?,
        onCaptureEvent: @escaping @MainActor @Sendable (NotebookCaptureEventDTO) -> Void,
        onLivePreview: @escaping @MainActor @Sendable (NotebookCaptureLivePreviewDTO) -> Void
    ) throws -> NotebookCaptureEventDTO {
        startCount += 1
        lastConfirmedContextDigest = confirmedContextDigest
        lastStartedSessionId = nextSessionId
        captureCallback = onCaptureEvent
        captureCallbacks[nextSessionId] = onCaptureEvent
        livePreviewCallback = onLivePreview
        livePreviewCallbacks[nextSessionId] = onLivePreview
        return event(
            sessionId: nextSessionId,
            state: .recording,
            remote: .connecting,
            projection: .pending
        )
    }

    func makeNotebookCaptureAudioPusher(sessionId: String) -> @Sendable (Data) -> String? {
        if let audioPushHandler { return audioPushHandler }
        let failure = audioPushFailureMessage
        return { [audioPushRecorder] data in
            audioPushRecorder.record(data)
            return failure
        }
    }

    func pauseNotebookCaptureSession(
        sessionId: String,
        paused: Bool
    ) async throws -> NotebookCaptureEventDTO {
        pauseCount += 1
        if let pauseController {
            await pauseController.wait()
        }
        if let pauseError { throw pauseError }
        return event(
            sessionId: sessionId,
            state: paused ? .paused : .recording,
            remote: .live,
            projection: .pending
        )
    }

    func stopNotebookCaptureSession(sessionId: String) async throws -> NotebookCaptureEventDTO {
        stopCount += 1
        if shouldFailStop {
            throw NotebookCaptureClientError.ffiUnavailable
        }
        return event(sessionId: sessionId, state: .completed, remote: .off, projection: .ready)
    }

    func interruptNotebookCaptureSession(
        sessionId: String,
        reason: NotebookCaptureInterruptReason
    ) async throws -> NotebookCaptureEventDTO {
        interruptCount += 1
        lastInterruptReason = reason
        if let interruptController {
            await interruptController.wait()
        }
        if let interruptError { throw interruptError }
        return event(
            sessionId: sessionId,
            state: .interrupted,
            remote: .off,
            projection: .pending,
            providerErrorType: reason.rawValue
        )
    }

    func getNotebookCaptureSessionEvent(sessionId: String) throws -> NotebookCaptureEventDTO {
        sessionEventCount += 1
        if let sessionEventError { throw sessionEventError }
        if let sessionEventOverride { return sessionEventOverride }
        return event(
            sessionId: sessionId,
            state: .interrupted,
            remote: .off,
            projection: .pending,
            providerErrorType: "local_audio_persistence"
        )
    }

    func reconcileNotebookCaptureSessionEvent(
        sessionId: String
    ) async throws -> NotebookCaptureEventDTO {
        sessionEventCount += 1
        let call = reconcileCallCount
        reconcileCallCount += 1
        let capturedEvent: NotebookCaptureEventDTO? = reconcileEvents.indices.contains(call)
            ? reconcileEvents[call]
            : sessionEventOverride
        let capturedError = reconcileErrors.indices.contains(call)
            ? reconcileErrors[call]
            : sessionEventError
        if let reconcileController {
            await reconcileController.wait(call: call)
        }
        if let capturedError { throw capturedError }
        if let capturedEvent { return capturedEvent }
        return event(
            sessionId: sessionId,
            state: .interrupted,
            remote: .off,
            projection: .pending,
            providerErrorType: "local_audio_persistence"
        )
    }

    func projectNotebookRealtimeIncremental(sessionId: String) throws {
        realtimeProjectionCount += 1
    }

    func emitCaptureEvent(_ event: NotebookCaptureEventDTO) {
        captureCallback?(event)
    }

    func emitCaptureEvent(
        _ event: NotebookCaptureEventDTO,
        callbackSessionId: String
    ) {
        captureCallbacks[callbackSessionId]?(event)
    }

    func emitLivePreview(_ preview: NotebookCaptureLivePreviewDTO) {
        livePreviewCallback?(preview)
    }

    func emitLivePreview(
        _ preview: NotebookCaptureLivePreviewDTO,
        callbackSessionId: String
    ) {
        livePreviewCallbacks[callbackSessionId]?(preview)
    }

    func listNotebookCaptureUtterances(sessionId: String) throws -> [NotebookCaptureUtteranceDTO] {
        listUtterancesCount += 1
        return listUtterancesOverride ?? startUtterances
    }

    func loadNotebookCaptureHistoryUtterances(
        notebookId: String,
        sessionId: String
    ) async throws -> [NotebookCaptureUtteranceDTO] {
        listUtterancesCount += 1
        let captured = listUtterancesOverride ?? startUtterances
        if let utteranceLoadController {
            await utteranceLoadController.wait()
        }
        return captured
    }

    func listSpeakerParticipants() throws -> [SpeakerParticipantDTO] {
        speakerParticipants
    }

    func createSpeakerParticipant(displayName: String) throws -> SpeakerParticipantDTO {
        let participant = SpeakerParticipantDTO(
            id: "participant-\(speakerParticipants.count + 1)",
            displayName: displayName
        )
        speakerParticipants.append(participant)
        return participant
    }

    func renameSpeakerParticipant(
        participantId: String,
        displayName: String
    ) throws -> SpeakerParticipantDTO {
        guard let index = speakerParticipants.firstIndex(where: { $0.id == participantId }) else {
            throw NotebookCaptureClientError.ffiUnavailable
        }
        speakerParticipants[index].displayName = displayName
        return speakerParticipants[index]
    }

    func listNotebookSessionSpeakers(
        sessionId: String
    ) throws -> [NotebookSessionSpeakerDTO] {
        listSessionSpeakersCount += 1
        return sessionSpeakersBySession[sessionId, default: []]
    }

    func renameNotebookSessionSpeaker(
        sessionSpeakerId: String,
        localDisplayName: String?
    ) throws -> NotebookSessionSpeakerDTO {
        try updateSessionSpeaker(id: sessionSpeakerId) {
            $0.localDisplayName = localDisplayName
        }
    }

    func linkNotebookSessionSpeaker(
        sessionSpeakerId: String,
        participantId: String
    ) throws -> NotebookSessionSpeakerDTO {
        try updateSessionSpeaker(id: sessionSpeakerId) {
            $0.participantId = participantId
        }
    }

    func unlinkNotebookSessionSpeaker(
        sessionSpeakerId: String
    ) throws -> NotebookSessionSpeakerDTO {
        try updateSessionSpeaker(id: sessionSpeakerId) {
            $0.participantId = nil
        }
    }

    func listNotebookCaptureHistory(
        notebookId: String
    ) throws -> [NotebookCaptureHistoryRunDTO] {
        historyNotebookIds.append(notebookId)
        return historyRuns
    }

    func listNotebookCaptureHistorySummaries(
        notebookId: String
    ) throws -> [NotebookCaptureHistoryRunDTO] {
        historyNotebookIds.append(notebookId)
        guard historySummariesOmitUtterances else { return historyRuns }
        return historyRuns.map { $0.replacingUtterances([]) }
    }

    func loadNotebookCaptureHistorySummaries(
        notebookId: String
    ) async throws -> [NotebookCaptureHistoryRunDTO] {
        let captured = try listNotebookCaptureHistorySummaries(notebookId: notebookId)
        if let catalogLoadController {
            await catalogLoadController.wait()
        }
        return captured
    }

    func retryNotebookCaptureProjection(sessionId: String) throws -> NotebookCaptureEventDTO {
        event(sessionId: sessionId, state: .completed, remote: .off, projection: .ready)
    }

    func retryNotebookAsyncProjection(sessionId: String) throws -> NotebookCaptureEventDTO {
        asyncProjectionRetryCount += 1
        return asyncProjectionRetryEventOverride ?? NotebookCaptureEventDTO(
            sessionId: sessionId,
            captureState: .completed,
            remoteHealth: .off,
            projectionState: .ready,
            utterances: startUtterances,
            contextReceipt: nil,
            providerErrorType: nil,
            providerRequestId: nil,
            mode: profile.mode,
            languageA: profile.languageA,
            languageB: profile.languageB,
            leftLanguage: profile.leftLanguage,
            rightLanguage: profile.rightLanguage,
            postStopAsyncState: "completed",
            postStopAsyncProjectionState: .ready,
            selectedLanguages: profile.selectedLanguages,
            commonCaptionLanguage: profile.commonCaptionLanguage
        )
    }

    func replaceNotebookUtteranceLane(
        utteranceId: String,
        laneLanguage: String,
        text: String,
        expectedRevision: UInt64
    ) async throws -> NotebookCaptureUtteranceDTO {
        lastReplaceExpectedRevision = expectedRevision
        if let replaceController {
            await replaceController.wait()
        }
        var updated = startUtterances.first(where: { $0.id == utteranceId }) ?? .sample
        let laneLanguage = NotebookCaptureUtteranceDTO.languageKey(laneLanguage)
        if NotebookCaptureUtteranceDTO.languageKey(updated.sourceLanguage) == laneLanguage {
            updated.sourceText = text
            updated.sourceEditRevision = expectedRevision &+ 1
            if let index = updated.languageVariants.firstIndex(where: {
                NotebookCaptureUtteranceDTO.languageKey($0.language) == laneLanguage
            }) {
                updated.languageVariants[index].text = text
                updated.languageVariants[index].editRevision = expectedRevision &+ 1
            }
        } else {
            if let index = updated.languageVariants.firstIndex(where: {
                NotebookCaptureUtteranceDTO.languageKey($0.language) == laneLanguage
            }) {
                updated.languageVariants[index].text = text
                updated.languageVariants[index].editRevision = expectedRevision &+ 1
            }
            if updated.translatedLanguage.map(
                NotebookCaptureUtteranceDTO.languageKey
            ) == laneLanguage {
                updated.translatedText = text
            }
        }
        return updated
    }

    private func updateSessionSpeaker(
        id: String,
        mutate: (inout NotebookSessionSpeakerDTO) -> Void
    ) throws -> NotebookSessionSpeakerDTO {
        for sessionId in Array(sessionSpeakersBySession.keys) {
            guard var speakers = sessionSpeakersBySession[sessionId],
                  let index = speakers.firstIndex(where: { $0.id == id }) else {
                continue
            }
            mutate(&speakers[index])
            sessionSpeakersBySession[sessionId] = speakers
            return speakers[index]
        }
        throw NotebookCaptureClientError.ffiUnavailable
    }

    private func event(
        sessionId: String? = nil,
        state: NotebookCaptureState,
        remote: NotebookRemoteHealth,
        projection: NotebookProjectionState,
        providerErrorType: String? = nil
    ) -> NotebookCaptureEventDTO {
        let durableRevision = startUtterances.reduce(UInt64(0)) { current, utterance in
            max(
                current,
                max(
                    utterance.sourceProjectionRevision,
                    utterance.languageVariants.map(\.projectionRevision).max() ?? 0
                )
            )
        }
        return NotebookCaptureEventDTO(
            sessionId: sessionId ?? lastStartedSessionId,
            captureState: state,
            remoteHealth: remote,
            projectionState: projection,
            utterances: startUtterances,
            contextReceipt: nil,
            providerErrorType: providerErrorType,
            providerRequestId: nil,
            mode: profile.mode,
            languageA: profile.languageA,
            languageB: profile.languageB,
            leftLanguage: profile.leftLanguage,
            rightLanguage: profile.rightLanguage,
            postStopAsyncState: "none",
            selectedLanguages: profile.selectedLanguages,
            commonCaptionLanguage: profile.commonCaptionLanguage,
            realtimeLoroAppliedRevision: projection == .ready ? durableRevision : 0
        )
    }
}

private extension NotebookCaptureProfileDTO {
    static func twoWay(notebookId: String) -> Self {
        Self(
            notebookId: notebookId,
            remoteRealtimeEnabled: true,
            mode: .twoWay,
            languageA: "en",
            languageB: "zh",
            leftLanguage: "en",
            rightLanguage: "zh",
            privacyLevel: .standard,
            sendContextToSoniox: false,
            revision: 2,
            selectedLanguages: ["en", "zh"],
            commonCaptionLanguage: nil
        )
    }
}

private extension NotebookCaptureUtteranceDTO {
    func replacingIdentity(
        id: String? = nil,
        sessionId: String? = nil,
        sequence: UInt64? = nil
    ) -> Self {
        Self(
            id: id ?? self.id,
            sessionId: sessionId ?? self.sessionId,
            sequence: sequence ?? self.sequence,
            sessionSpeakerId: sessionSpeakerId,
            revision: revision,
            sourceLanguage: sourceLanguage,
            sourceText: sourceText,
            sourceStartMs: sourceStartMs,
            sourceEndMs: sourceEndMs,
            translatedLanguage: translatedLanguage,
            translatedText: translatedText,
            completion: completion,
            alignment: alignment,
            languageVariants: languageVariants,
            sourceProjectionRevision: sourceProjectionRevision
        )
    }

    static var sample: Self {
        Self(
            id: "utt-1",
            sessionId: "session-a",
            sequence: 1,
            revision: 7,
            sourceLanguage: "en",
            sourceText: "Hello",
            sourceStartMs: 0,
            sourceEndMs: 600,
            translatedLanguage: "zh",
            translatedText: "你好",
            completion: "complete",
            alignment: "response_order",
            languageVariants: [
                NotebookCaptureLanguageVariantDTO(
                    language: "zh",
                    role: "translation",
                    text: "你好",
                    state: "ready",
                    completion: "complete",
                    projectionRevision: 1
                ),
                NotebookCaptureLanguageVariantDTO(
                    language: "en",
                    role: "source",
                    text: "Hello",
                    state: "ready",
                    completion: "complete",
                    projectionRevision: 1
                ),
            ],
            sourceProjectionRevision: 1
        )
    }
}

private extension NotebookCaptureHistoryRunDTO {
    static func fixture(
        sessionId: String,
        createdAt: String,
        state: NotebookCaptureState = .completed,
        projection: NotebookProjectionState = .ready,
        mode: NotebookCaptureMode? = .twoWay,
        utterances: [NotebookCaptureUtteranceDTO] = [],
        hasAudio: Bool = true,
        selectedLanguages: [String]? = nil,
        commonCaptionLanguage: String? = nil,
        realtimeLoroAppliedRevision: UInt64? = nil
    ) -> Self {
        let frozenLanguages = selectedLanguages ?? {
            switch mode {
            case .transcriptionOnly:
                return ["en"]
            case .twoWay:
                return ["en", "zh"]
            case .multilingualOneWay:
                return ["en", "zh", "th"]
            case nil:
                return []
            }
        }()
        let durableRevision = utterances.reduce(UInt64(0)) { current, utterance in
            max(
                current,
                max(
                    utterance.sourceProjectionRevision,
                    utterance.languageVariants.map(\.projectionRevision).max() ?? 0
                )
            )
        }
        return Self(
            sessionId: sessionId,
            createdAt: createdAt,
            completedAt: state.isActive ? nil : createdAt,
            captureState: state,
            remoteHealth: state.isActive ? .live : .off,
            projectionState: projection,
            asyncTaskState: "none",
            asyncProjectionState: .none,
            durationMs: 8_000,
            capturedFrames: 128_000,
            hasAudio: hasAudio,
            mode: mode,
            languageA: mode == nil ? nil : "en",
            languageB: mode == nil ? nil : "zh",
            leftLanguage: mode == nil ? nil : "en",
            rightLanguage: mode == nil ? nil : "zh",
            privacyLevel: mode == nil ? nil : .standard,
            utterances: utterances,
            selectedLanguages: frozenLanguages,
            commonCaptionLanguage: commonCaptionLanguage,
            realtimeLoroAppliedRevision: realtimeLoroAppliedRevision
                ?? (projection == .ready ? durableRevision : 0)
        )
    }
}
