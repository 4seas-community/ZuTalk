import AppKit
import Combine
import SwiftUI

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
    /// When the last mark landed, so the surface that made it can say so.
    @Published private(set) var lastMarkedAt: Date?
    /// The person's own choice, once they have made one.
    @Published private var storedCaptionsChoice: Bool?

    /// Whether new recordings ask for live captions. Shown and switched next
    /// to every Record button, so the choice is made where it takes effect.
    /// Until someone chooses, it follows whether they set up a way to get
    /// captions — saving a key or redeeming an invite is that intent — and
    /// follows it live, since keys are restored after launch.
    var realtimeCaptionsEnabled: Bool {
        storedCaptionsChoice ?? realtimeCredentialAvailable
    }

    private let capture: ActiveBilingualTranscriptStore
    private let navigation: MainNavigationStore
    private let invite: CommunityInviteSession
    private let defaults: UserDefaults
    private let coreProvider: @MainActor () -> (any ZuTalkCoreProtocol)?
    private let inviteReady: @MainActor () -> Bool
    /// Watching someone else's share and recording can't happen together —
    /// the two would tangle. Asks before leaving; `true` means go ahead.
    private let leaveWatchingToRecord: @MainActor () -> Bool

    static let realtimeCaptionsDefaultsKey = "capture.realtime_captions.enabled"

    init(
        capture: ActiveBilingualTranscriptStore? = nil,
        navigation: MainNavigationStore? = nil,
        invite: CommunityInviteSession? = nil,
        defaults: UserDefaults = .standard,
        coreProvider: @escaping @MainActor () -> (any ZuTalkCoreProtocol)? = {
            CoreClient.shared.core
        },
        inviteReady: (@MainActor () -> Bool)? = nil,
        leaveWatchingToRecord: (@MainActor () -> Bool)? = nil
    ) {
        let invite = invite ?? .shared
        self.capture = capture ?? .shared
        self.navigation = navigation ?? .shared
        self.invite = invite
        self.defaults = defaults
        self.coreProvider = coreProvider
        self.inviteReady = inviteReady ?? { invite.isEnabled && invite.isActive }
        self.leaveWatchingToRecord = leaveWatchingToRecord
            ?? { ShareActivityStore.shared.confirmLeavingToRecord() }
        storedCaptionsChoice = defaults.object(forKey: Self.realtimeCaptionsDefaultsKey) != nil
            ? defaults.bool(forKey: Self.realtimeCaptionsDefaultsKey)
            : nil
    }

    // MARK: - Captions choice

    /// A Soniox key of one's own, or an invite that is switched on.
    var realtimeCredentialAvailable: Bool {
        coreProvider()?.hasApiKey(scope: ProviderCredentialAccount.soniox.scope) == true
            || inviteReady()
    }

    /// What the next recording will do, as the Record button should say it.
    var nextRecordingUsesCaptions: Bool {
        realtimeCaptionsEnabled && realtimeCredentialAvailable
    }

    func setRealtimeCaptionsEnabled(_ enabled: Bool) {
        storedCaptionsChoice = enabled
        defaults.set(enabled, forKey: Self.realtimeCaptionsDefaultsKey)
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
        guard leaveWatchingToRecord() else { return false }
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
        do {
            let preparation = try await NotebookCaptureStartPreparationWorkflow.prepare(
                enableRealtimeIfNeeded: wantsCaptions,
                prepareProfile: { realtime in
                    try await profileEditor.prepareForCaptureStart(realtime: realtime)
                    return profileEditor.draft
                },
                prepareRealtimeCredential: { [invite] laneCount in
                    try await invite.prepareRealtimeCredential(laneCount: laneCount)
                }
            )
            if preparation == .personalKeyFallback {
                ToastCenter.shared.info(String(localized: "community_invite.fallback_personal_key"))
            }
            try await NotebookCaptureStartCoordinator(
                capture: capture,
                navigation: navigation
            ).start(notebookId: notebookId)
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

    var canStop: Bool {
        capture.isCaptureActive
            && isStopping == false
            && (capture.captureState != .draining || capture.stopRecoveryRequired)
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

    /// Ends the recording. `announce` says so in a toast with how much was
    /// kept — for a stop made from outside the window, where nothing else
    /// on screen would.
    func stop(announce: Bool = false) {
        guard canStop else { return }
        isStopping = true
        Task { @MainActor in
            defer { isStopping = false }
            let usedSeconds = Int(capture.elapsedRecordingTime.rounded(.up))
            do {
                if capture.stopRecoveryRequired {
                    try await capture.retryStopRecovery()
                } else {
                    try await capture.stop()
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
