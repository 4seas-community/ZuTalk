import AppKit
import Combine
import SwiftUI

/// The recording a Stop just saved: which one, how long it ran, and whether
/// it was getting text as it went. Kept only for the card on its page
/// (`RecordingResultCard`); nothing of it survives a relaunch.
struct FinishedRecording: Equatable {
    let sessionId: String
    /// How long it ran, by the recording clock.
    let seconds: Int
    /// Live text was off for this one: so far there is audio and no transcript.
    let audioOnly: Bool
    /// The stop already said "saved" in a toast (it came from the menu bar,
    /// the caption window or the shortcut). A page that decides not to turn
    /// to the result card uses this to avoid saying it twice — or not at all.
    var announced = false
}

/// Every recording command, for every surface that offers one: a topic's
/// Record button, Home, the recording bar above every page, the menu bar,
/// and the global shortcuts.
///
/// Recording used to be controllable only from the topic toolbar, and only
/// on that topic's live page. Reading an older recording, switching to Notes,
/// presenting from another app — each hid Pause and Stop entirely. The
/// commands now live here once, so every surface behaves the same and none of
/// them is the only way out.
@MainActor
final class CaptureCommandCenter: ObservableObject {
    static let shared = CaptureCommandCenter()

    @Published private(set) var isStarting = false
    @Published private(set) var isPausing = false
    @Published private(set) var isStopping = false
    /// A second Stop, asking Rust to interrupt after the first went unanswered.
    @Published private(set) var isRetryingStop = false
    private var stopAttempt: UUID?
    /// When the last mark landed, so the surface that made it can say so.
    @Published private(set) var lastMarkedAt: Date?
    /// The recording a Stop just saved, until the card on its page is closed
    /// or another recording is opened. Pressing Stop in the main window used
    /// to leave no sign that anything had been kept.
    @Published private(set) var justFinished: FinishedRecording?

    private let capture: ActiveBilingualTranscriptStore
    private let navigation: MainNavigationStore
    private let invite: CommunityInviteSession
    private let coreProvider: @MainActor () -> (any ZuTalkCoreProtocol)?
    private let inviteReady: @MainActor () -> Bool
    private let mainWindowIsShowing: @MainActor () -> Bool
    private let openRecording: @MainActor (String) -> Void
    private var settlementObservers: Set<AnyCancellable> = []
    private var openedRecordingObserver: AnyCancellable?

    init(
        capture: ActiveBilingualTranscriptStore? = nil,
        navigation: MainNavigationStore? = nil,
        invite: CommunityInviteSession? = nil,
        coreProvider: @escaping @MainActor () -> (any ZuTalkCoreProtocol)? = {
            CoreClient.shared.core
        },
        inviteReady: (@MainActor () -> Bool)? = nil,
        mainWindowIsShowing: (@MainActor () -> Bool)? = nil,
        openRecording: (@MainActor (String) -> Void)? = nil
    ) {
        let invite = invite ?? .shared
        let navigation = navigation ?? .shared
        self.capture = capture ?? .shared
        self.navigation = navigation
        self.invite = invite
        self.coreProvider = coreProvider
        self.inviteReady = inviteReady ?? { invite.isEnabled && invite.isActive }
        self.mainWindowIsShowing = mainWindowIsShowing
            ?? { WindowCoordinator.shared.isMainWindowVisible() }
        self.openRecording = openRecording ?? { navigation.openSession($0) }
        observeRecordingForInviteSettlement()
        observeOpenedRecordings()
    }

    // MARK: - Invite settlement

    /// Invite time is settled when a recording ends, however it ends.
    ///
    /// It used to be settled from Stop's success path only. A recording the
    /// microphone ended, one Rust interrupted, one ended by quitting, and one
    /// whose Stop failed all left the reservation open, and the service then
    /// refused new recordings while two such leftovers were waiting out their
    /// six hours. The settle is idempotent, so Stop's own call and this one
    /// can both run for the same ending.
    private func observeRecordingForInviteSettlement() {
        let capture = self.capture
        let invite = self.invite
        var wasActive = capture.activity.isCaptureActive
        capture.activity.$isCaptureActive
            .removeDuplicates()
            .sink { [weak self] isActive in
                defer { wasActive = isActive }
                guard wasActive, isActive == false else { return }
                // The recording is over, whatever is still waiting for an
                // answer about it. A command that never answers must not keep
                // the next recording's Stop or Pause greyed out.
                self?.stopAttempt = nil
                self?.isStopping = false
                self?.isRetryingStop = false
                self?.isPausing = false
                // A recording filed under a city event goes to that city's
                // archive when it ends, however it ended; see `CityStore`.
                CityStore.shared.recordingEnded()
                let usedSeconds = Int(capture.elapsedRecordingTime.rounded(.up))
                Task { @MainActor in
                    await invite.settleRealtimeSession(usedSeconds: usedSeconds)
                }
            }
            .store(in: &settlementObservers)
        capture.clock.$elapsed
            .sink { elapsed in
                invite.noteRealtimeProgress(elapsedSeconds: Int(elapsed.rounded(.down)))
            }
            .store(in: &settlementObservers)
    }

    // MARK: - Live text

    /// A Soniox key of one's own, or an invite that is switched on.
    var realtimeCredentialAvailable: Bool {
        coreProvider()?.hasApiKey(scope: ProviderCredentialAccount.soniox.scope) == true
            || inviteReady()
    }

    /// Whether the next recording gets live text: whenever something can
    /// provide it. It was a choice beside every Record button until 0.8.4 —
    /// 「默认录音就是出字，不需要有这个可配置的。」 A recording of the sound
    /// alone is what happens with no invite and no key, which is set up in
    /// Settings, not chosen per recording. (The choice an earlier version
    /// saved is neither read nor removed.)
    var nextRecordingUsesCaptions: Bool {
        realtimeCredentialAvailable
    }

    // MARK: - Start

    /// Starts recording into a topic with that topic's languages.
    func start(notebookId: String, profileEditor: NotebookCaptureProfileEditorModel) {
        Task { await startNow(notebookId: notebookId, profileEditor: profileEditor) }
    }

    /// Starts a recording that belongs to no topic yet — Home's Record button
    /// and ⌃⌥R. It can be filed into a topic afterwards.
    func startQuickCapture(profileEditor: NotebookCaptureProfileEditorModel? = nil) {
        guard let notebookId = profileEditor?.notebookId ?? quickCaptureNotebookId() else {
            ToastCenter.shared.error(String(localized: "capture.route.unavailable"))
            return
        }
        let editor: NotebookCaptureProfileEditorModel
        if let profileEditor, profileEditor.notebookId == notebookId {
            // A load or save that failed transiently would otherwise block the
            // start; retry is a no-op in the healthy states.
            profileEditor.retry()
            editor = profileEditor
        } else {
            editor = NotebookCaptureProfileEditorModel(notebookId: notebookId)
            editor.load()
        }
        start(notebookId: notebookId, profileEditor: editor)
    }

    @discardableResult
    func startNow(
        notebookId: String,
        profileEditor: NotebookCaptureProfileEditorModel
    ) async -> Bool {
        if capture.isCaptureActive {
            navigation.openActiveNotebookForCapture()
            return false
        }
        guard isStarting == false,
              let startLease = NotebookCaptureStartWorkflowGate.shared.acquire()
        else {
            ToastCenter.shared.warning(String(localized: "capture.toast.start_failed"))
            return false
        }
        isStarting = true
        defer {
            NotebookCaptureStartWorkflowGate.shared.release(startLease)
            isStarting = false
        }
        let wantsCaptions = nextRecordingUsesCaptions
        // Saves the languages for this start and, when it will have live
        // text, gets what the text runs on.
        let prepare: @MainActor (Bool) async throws -> CommunityInvitePreparation = { [invite] liveText in
            try await NotebookCaptureStartPreparationWorkflow.prepare(
                enableRealtimeIfNeeded: liveText,
                prepareProfile: { realtime in
                    try await profileEditor.prepareForCaptureStart(realtime: realtime)
                    return profileEditor.draft
                },
                prepareRealtimeCredential: { laneCount in
                    try await invite.prepareRealtimeCredential(laneCount: laneCount)
                }
            )
        }
        do {
            let preparation: CommunityInvitePreparation
            do {
                preparation = try await prepare(wantsCaptions)
            } catch where wantsCaptions && CommunityInviteError.isOffline(error) {
                // An invite cannot be drawn on without a network, and there
                // is no longer a switch to turn live text off with. Recording
                // itself needs no network: this one is made of the sound
                // alone, and the person is told so.
                await invite.settleRealtimeSession(usedSeconds: 0)
                preparation = try await prepare(false)
                ToastCenter.shared.info(String(localized: "network.offline.audio_only_start"))
            }
            if preparation == .personalKeyFallback {
                ToastCenter.shared.info(String(localized: "community_invite.fallback_personal_key"))
            }
            try await NotebookCaptureStartCoordinator(
                capture: capture,
                navigation: navigation
            ).start(notebookId: notebookId)
            // A new recording is under way: the one before it is no longer
            // the one that "just" finished.
            justFinished = nil
            return true
        } catch {
            // Return any invite reservation made above; a no-op when none exists.
            await invite.settleRealtimeSession(usedSeconds: 0)
            ToastCenter.shared.error(
                String(localized: "capture.toast.start_failed"),
                detail: error.localizedDescription
            )
            return false
        }
    }

    private func quickCaptureNotebookId() -> String? {
        guard let notebook = try? coreProvider()?.getQuickCaptureNotebook(),
              notebook.deletedAt == nil
        else { return nil }
        return notebook.id
    }

    // MARK: - While recording

    var canPause: Bool {
        capture.isCaptureActive
            && capture.captureState != .draining
            && isPausing == false
            && isStopping == false
    }

    /// Stop is offered whenever a recording is running and no Stop is already
    /// on its way — and again once a command that went unanswered has been
    /// handed back (`stopRecoveryRequired`), even while that first Stop is
    /// still waiting somewhere. Requiring it to come back first is what left
    /// nothing to press.
    var canStop: Bool {
        guard capture.isCaptureActive else { return false }
        if capture.stopRecoveryRequired {
            return isRetryingStop == false
        }
        return isStopping == false && capture.captureState != .draining
    }

    func togglePause() {
        guard canPause else { return }
        let pause = capture.captureState != .paused
        isPausing = true
        Task { @MainActor in
            defer { isPausing = false }
            do {
                try await capture.setPaused(pause)
            } catch {
                ToastCenter.shared.error(
                    String(localized: "capture.toast.pause_failed"),
                    detail: error.localizedDescription
                )
            }
        }
    }

    /// Ends the recording. A stop that succeeds lands on the recording's own
    /// page (`recordingFinished`). `announce` also says so in a toast with
    /// how much was kept — for a stop made from outside the window, where
    /// that page may not be on screen.
    func stop(announce: Bool = false) {
        guard canStop else { return }
        let retrying = capture.stopRecoveryRequired
        if retrying {
            isRetryingStop = true
        } else {
            isStopping = true
        }
        let attempt = UUID()
        stopAttempt = attempt
        Task { @MainActor in
            defer {
                // A Stop that answers only after its recording ended some
                // other way must not reset the flags of a later one.
                if stopAttempt == attempt {
                    if retrying {
                        isRetryingStop = false
                    } else {
                        isStopping = false
                    }
                }
            }
            let usedSeconds = Int(capture.elapsedRecordingTime.rounded(.up))
            // Read before the Stop is answered: which recording this is and
            // whether it was getting live text are the store's to forget
            // once it has ended.
            let ending = capture.sessionId.map {
                FinishedRecording(
                    sessionId: $0,
                    seconds: usedSeconds,
                    audioOnly: capture.profile.remoteRealtimeEnabled == false,
                    announced: announce
                )
            }
            do {
                if retrying {
                    try await capture.retryStopRecovery()
                } else {
                    try await capture.stop()
                }
                // Only a Stop that came back saved lands anywhere; one that
                // failed may still be recording. Nor does one whose place
                // another recording has already taken. Before the invite is
                // settled: that asks a server, and the page should not wait.
                if let ending, capture.isCaptureActive == false {
                    recordingFinished(ending)
                }
                await invite.settleRealtimeSession(usedSeconds: usedSeconds)
                if announce {
                    ToastCenter.shared.success(String(
                        format: String(localized: "capture.toast.stopped_saved"),
                        Self.clock(TimeInterval(usedSeconds))
                    ))
                }
            } catch {
                if capture.isCaptureActive == false {
                    await invite.settleRealtimeSession(usedSeconds: usedSeconds)
                }
                ToastCenter.shared.error(
                    String(localized: "capture.toast.stop_failed"),
                    detail: error.localizedDescription
                )
            }
        }
    }

    // MARK: - After Stop

    /// A recording has ended, saved. Its page shows a card saying so until
    /// the card is closed; if the main window is on screen, that page is
    /// brought up now. With the window closed nothing is navigated: the
    /// toast is the sign, and the card is there when the page is next opened.
    func recordingFinished(_ recording: FinishedRecording) {
        justFinished = recording
        guard mainWindowIsShowing() else { return }
        let alreadyShowing = navigation.activeTab == .editor
            && navigation.selectedSessionID == recording.sessionId
        if alreadyShowing == false {
            openRecording(recording.sessionId)
        }
    }

    /// The person closed the card.
    func dismissJustFinished() {
        justFinished = nil
    }

    /// The card belongs to the recording that just finished. Opening a
    /// different one means the person has moved on; going Home, or to a
    /// topic's list, has not.
    private func observeOpenedRecordings() {
        openedRecordingObserver = navigation.$activeEditorRoute
            .map { $0?.selectedSessionID }
            .removeDuplicates()
            .sink { [weak self] opened in
                guard let self,
                      let opened,
                      let finished = self.justFinished,
                      opened != finished.sessionId
                else { return }
                self.justFinished = nil
            }
    }

    func restartTranscription() {
        guard capture.canRestartTranscription else { return }
        Task { @MainActor in
            do {
                try await capture.restartTranscription()
            } catch {
                ToastCenter.shared.error(
                    String(localized: "capture.toast.restart_transcription_failed"),
                    detail: error.localizedDescription
                )
            }
        }
    }

    /// Marks the moment just heard in the recording in progress.
    @discardableResult
    func mark() -> Bool {
        let marked = SessionMarkStore.shared.markLiveCapture()
        if marked { lastMarkedAt = Date() }
        return marked
    }

    // MARK: - System sleep

    private var sleepObservers: [NSObjectProtocol] = []
    /// A recording this Mac's sleep ended, waiting to be announced on wake.
    private var endedBySleepSeconds: Int?

    /// A Mac that goes to sleep ends the recording, saved, the same as Stop.
    ///
    /// Nothing is heard while it sleeps, and the transcription connection
    /// dies under it: carrying on after wake used to leave a recording that
    /// kept its microphone but never got captions again, with a gap no one
    /// chose. Ending it at the moment the lid closes is the honest record.
    func endRecordingWhenTheMacSleeps() {
        guard sleepObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        sleepObservers.append(center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                CaptureCommandCenter.shared.handleSystemWillSleep()
            }
        })
        sleepObservers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                CaptureCommandCenter.shared.handleSystemDidWake()
            }
        })
    }

    func handleSystemWillSleep() {
        guard capture.isCaptureActive, canStop else { return }
        endedBySleepSeconds = Int(capture.elapsedRecordingTime.rounded(.up))
        stop()
    }

    func handleSystemDidWake() {
        guard let seconds = endedBySleepSeconds else { return }
        endedBySleepSeconds = nil
        ToastCenter.shared.info(String(
            format: String(localized: "capture.toast.stopped_by_sleep"),
            Self.clock(TimeInterval(seconds))
        ))
    }

    // MARK: - Shortcuts

    /// ⌃⌥R: start a recording if none is running, otherwise stop it.
    func toggleRecordingFromShortcut() {
        if capture.isCaptureActive {
            stop(announce: true)
        } else {
            startQuickCapture()
        }
    }

    /// ⌃⌥P
    func togglePauseFromShortcut() {
        guard capture.isCaptureActive else {
            ToastCenter.shared.info(String(localized: "session.marks.toast.no_recording"))
            return
        }
        togglePause()
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds), 0)
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%02d:%02d", minutes, secs)
    }
}
