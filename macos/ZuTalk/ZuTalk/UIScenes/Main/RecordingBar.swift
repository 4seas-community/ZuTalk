import AppKit
import Combine
import SwiftUI

/// What the recording bar shows, decided once from the capture store so the
/// view itself only lays it out.
struct RecordingBarModel: Equatable {
    enum Phase: Equatable {
        case recording
        case paused
        case pausing
        case resuming
        case stopping
    }

    enum Captions: Equatable {
        case off
        case connecting
        case live
        case partial
        case stopped
    }

    var phase: Phase
    var elapsed: TimeInterval
    /// The topic the recording files into; nil for one that belongs to none.
    var topicTitle: String?
    var captions: Captions
    /// "Chinese translation 12 s behind" and the like; nil while keeping up.
    var lagNotice: String?
    /// Why captions are not running normally, in words someone can act on.
    var problem: String?
    var canReconnect: Bool
    var isReconnecting: Bool
    var canPause: Bool
    var canStop: Bool
    var stopNeedsRetry: Bool
    var justMarked: Bool
    /// Paused while a provider connection is still open and billing.
    var pausedWhileBilling: Bool

    @MainActor
    static func current(
        capture: ActiveBilingualTranscriptStore,
        commands: CaptureCommandCenter,
        topicTitle: String?,
        now: Date = Date()
    ) -> RecordingBarModel {
        let phase: Phase
        if commands.isStopping || (capture.captureState == .draining && capture.pauseTransition == nil) {
            phase = .stopping
        } else if let transition = capture.pauseTransition {
            phase = transition == .pausing ? .pausing : .resuming
        } else {
            phase = capture.captureState == .paused ? .paused : .recording
        }
        let captions: Captions
        switch capture.remoteHealth {
        case .off: captions = .off
        case .connecting: captions = .connecting
        case .live: captions = .live
        case .degraded: captions = .partial
        case .unavailable: captions = .stopped
        }
        let remoteOpen = capture.remoteHealth == .live
            || capture.remoteHealth == .connecting
            || capture.remoteHealth == .degraded
        return RecordingBarModel(
            phase: phase,
            elapsed: capture.elapsedRecordingTime,
            topicTitle: topicTitle,
            captions: captions,
            lagNotice: capture.liveLagNotice,
            problem: capture.transcriptionProblemText,
            canReconnect: capture.canRestartTranscription,
            isReconnecting: capture.isRestartingTranscription,
            canPause: commands.canPause,
            canStop: commands.canStop,
            stopNeedsRetry: capture.stopRecoveryRequired,
            justMarked: commands.lastMarkedAt.map { now.timeIntervalSince($0) < 2.5 } ?? false,
            pausedWhileBilling: capture.captureState == .paused && remoteOpen
        )
    }
}

struct RecordingBarActions {
    var openRecording: () -> Void
    var mark: () -> Void
    var togglePause: () -> Void
    var stop: () -> Void
    var reconnect: () -> Void

    @MainActor
    static var live: RecordingBarActions {
        let commands = CaptureCommandCenter.shared
        return RecordingBarActions(
            openRecording: { MainNavigationStore.shared.openActiveNotebookForCapture() },
            mark: { commands.mark() },
            togglePause: { commands.togglePause() },
            stop: { commands.stop() },
            reconnect: { commands.restartTranscription() }
        )
    }
}

/// The recording in progress, above every page of the main window.
///
/// Pause, Stop and Mark used to exist only on the recording's own live page.
/// Reading an older recording, writing notes, or looking at another topic
/// hid them — and with them any sign that the microphone was still on.
struct RecordingBar: View {
    /// Icons instead of labels, for a narrow window.
    var compact = false
    @ObservedObject private var capture = ActiveBilingualTranscriptStore.shared
    @ObservedObject private var livePresentation = ActiveBilingualTranscriptStore.shared.livePresentation
    @ObservedObject private var commands = CaptureCommandCenter.shared
    @State private var topicTitle: String?
    @State private var markTick = Date()

    var body: some View {
        if capture.isCaptureActive {
            HStack(spacing: Spacing.sm) {
                // Sharing this recording live starts here, and while it is
                // live the same button says so and how many are watching.
                if let sessionId = capture.sessionId {
                    LiveShareButton(
                        sessionId: sessionId,
                        title: LiveShareText.title(topic: topicTitle),
                        compact: compact
                    )
                }
                RecordingBarContent(
                    model: .current(
                        capture: capture,
                        commands: commands,
                        topicTitle: topicTitle,
                        now: markTick
                    ),
                    actions: .live,
                    compact: compact
                )
            }
            .task(id: capture.notebookId) { loadTopicTitle() }
            .onReceive(commands.$lastMarkedAt) { markedAt in
                markTick = Date()
                guard markedAt != nil else { return }
                // Let the acknowledgement fade on its own.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { markTick = Date() }
            }
            .transition(.opacity)
        }
    }

    private func loadTopicTitle() {
        guard let notebookId = capture.notebookId,
              let core = CoreClient.shared.core
        else {
            topicTitle = nil
            return
        }
        if let quick = try? core.getQuickCaptureNotebook(), quick.id == notebookId {
            topicTitle = nil
            return
        }
        topicTitle = (try? core.listNotebooks())?
            .first(where: { $0.id == notebookId })?
            .title
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct RecordingBarContent: View {
    let model: RecordingBarModel
    let actions: RecordingBarActions
    var compact = false

    var body: some View {
        row(compact: compact)
    }

    private func row(compact: Bool) -> some View {
        HStack(spacing: Spacing.sm) {
            identity(compact: compact)
            if compact == false {
                captionsChip
                if let lag = model.lagNotice {
                    Label(lag, systemImage: "tortoise.fill")
                        .font(.bodySM)
                        .foregroundColor(.signalAmber)
                        .lineLimit(1)
                        .help(String(localized: "capture.toolbar.translation_lag_hint"))
                }
            }
            controls(compact: compact)
        }
        .fixedSize()
    }

    private func identity(compact: Bool) -> some View {
        Button(action: actions.openRecording) {
            HStack(spacing: Spacing.sm) {
                PulsingDot(color: dotColor, size: 8)
                    .accessibilityHidden(true)
                Text(CaptureCommandCenter.clock(model.elapsed))
                    .font(.monoNum12)
                    .foregroundColor(.textPrimary)
                if compact == false {
                    Text(phaseText)
                        .font(.bodySM)
                        .foregroundColor(model.phase == .recording ? .textSecondary : .signalAmber)
                    Text(model.topicTitle ?? String(localized: "recording_bar.unfiled"))
                        .font(.bodyMedium)
                        .foregroundColor(.textPrimary)
                        .lineLimit(1)
                        .frame(maxWidth: 220, alignment: .leading)
                }
            }
            .padding(.horizontal, Spacing.sm + 2)
            .frame(minHeight: 30)
            .background(Color.signalRed.opacity(model.phase == .recording ? 0.08 : 0.04))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(String(localized: "recording_bar.open_hint"))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibilitySummary))
        .accessibilityHint(Text(String(localized: "recording_bar.open_hint")))
        .accessibilityIdentifier("recording-bar.open")
    }

    private var captionsChip: some View {
        Label(captionsText, systemImage: captionsIcon)
            .font(.bodySM)
            .foregroundColor(captionsColor)
            .lineLimit(1)
            .help(model.problem ?? captionsText)
    }

    private func controls(compact: Bool) -> some View {
        HStack(spacing: Spacing.xs) {
            if model.canReconnect || model.isReconnecting {
                barButton(
                    title: String(localized: "capture.toolbar.restart_transcription"),
                    systemImage: model.isReconnecting ? "hourglass" : "arrow.clockwise",
                    tint: .signalAmber,
                    compact: compact,
                    disabled: model.isReconnecting,
                    help: String(localized: "capture.toolbar.restart_transcription_hint"),
                    action: actions.reconnect
                )
                .accessibilityIdentifier("recording-bar.reconnect")
            }
            barButton(
                title: model.justMarked
                    ? String(localized: "recording_bar.marked")
                    : String(localized: "recording_bar.mark"),
                systemImage: model.justMarked ? "bookmark.fill" : "bookmark",
                tint: model.justMarked ? .brandAccent : .textPrimary,
                compact: compact,
                disabled: model.phase == .stopping,
                help: String(localized: "recording_bar.mark_hint"),
                action: actions.mark
            )
            .accessibilityIdentifier("recording-bar.mark")
            barButton(
                title: model.phase == .paused || model.phase == .resuming
                    ? String(localized: "capture.toolbar.resume")
                    : String(localized: "capture.toolbar.pause"),
                systemImage: model.phase == .paused || model.phase == .resuming
                    ? "play.fill"
                    : "pause.fill",
                tint: .textPrimary,
                compact: compact,
                disabled: model.canPause == false,
                help: String(localized: "recording_bar.pause_hint"),
                action: actions.togglePause
            )
            .accessibilityIdentifier("recording-bar.pause")
            barButton(
                title: model.phase == .stopping
                    ? String(localized: "capture.state.draining")
                    : model.stopNeedsRetry
                        ? String(localized: "home.workspace.retry")
                        : String(localized: "capture.toolbar.stop"),
                systemImage: model.phase == .stopping
                    ? "hourglass"
                    : model.stopNeedsRetry ? "arrow.clockwise" : "stop.fill",
                tint: .signalRed,
                compact: compact,
                disabled: model.canStop == false,
                help: String(localized: "recording_bar.stop_hint"),
                action: actions.stop
            )
            .accessibilityIdentifier("recording-bar.stop")
        }
    }

    private func barButton(
        title: String,
        systemImage: String,
        tint: Color,
        compact: Bool,
        disabled: Bool,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Group {
                if compact {
                    Image(systemName: systemImage)
                        .frame(width: 30, height: 30)
                } else {
                    Label(title, systemImage: systemImage)
                        .padding(.horizontal, Spacing.sm + 2)
                        .frame(minHeight: 30)
                }
            }
            .font(.bodyMedium)
            .foregroundColor(tint)
            .background(tint.opacity(0.1))
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
        .help(help)
        .accessibilityLabel(Text(title))
    }

    private var dotColor: Color {
        switch model.phase {
        case .recording: return .signalRed
        case .paused, .pausing, .resuming: return .signalAmber
        case .stopping: return .textTertiary
        }
    }

    private var phaseText: String {
        switch model.phase {
        case .recording: return String(localized: "capture.state.recording")
        case .paused: return String(localized: "capture.state.paused")
        case .pausing: return String(localized: "capture.state.pausing")
        case .resuming: return String(localized: "capture.state.resuming")
        case .stopping: return String(localized: "capture.state.draining")
        }
    }

    private var captionsText: String {
        switch model.captions {
        case .off: return String(localized: "recording_bar.captions.off")
        case .connecting: return String(localized: "capture.remote.connecting")
        case .live: return String(localized: "capture.remote.live")
        case .partial: return String(localized: "capture.remote.degraded")
        case .stopped: return String(localized: "capture.remote.unavailable")
        }
    }

    private var captionsIcon: String {
        switch model.captions {
        case .off: return "mic.fill"
        case .connecting: return "ellipsis.bubble"
        case .live: return "captions.bubble.fill"
        case .partial, .stopped: return "exclamationmark.bubble.fill"
        }
    }

    private var captionsColor: Color {
        switch model.captions {
        case .off, .connecting: return .textSecondary
        case .live: return .signalGreen
        case .partial, .stopped: return .signalAmber
        }
    }

    private var accessibilitySummary: String {
        [
            phaseText,
            CaptureCommandCenter.clock(model.elapsed),
            model.topicTitle ?? String(localized: "recording_bar.unfiled"),
            captionsText,
        ].joined(separator: ", ")
    }
}

/// A full-width line under the header when live captions need attention:
/// why they stopped, and the one action that brings them back. Recording
/// itself is unaffected, so this informs rather than alarms.
struct RecordingProblemBanner: View {
    @ObservedObject private var capture = ActiveBilingualTranscriptStore.shared
    @ObservedObject private var livePresentation = ActiveBilingualTranscriptStore.shared.livePresentation
    @ObservedObject private var commands = CaptureCommandCenter.shared

    var body: some View {
        if capture.isCaptureActive, let message {
            HStack(spacing: Spacing.sm) {
                Image(systemName: icon)
                    .foregroundColor(.signalAmber)
                    .accessibilityHidden(true)
                Text(message)
                    .font(.bodySM)
                    .foregroundColor(.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Spacing.md)
                if capture.canRestartTranscription || capture.isRestartingTranscription {
                    Button {
                        commands.restartTranscription()
                    } label: {
                        Label(
                            String(localized: "capture.toolbar.restart_transcription"),
                            systemImage: capture.isRestartingTranscription ? "hourglass" : "arrow.clockwise"
                        )
                        .font(.bodyMedium)
                    }
                    .buttonStyle(.bordered)
                    .disabled(capture.isRestartingTranscription)
                    .help(String(localized: "capture.toolbar.restart_transcription_hint"))
                }
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.sm)
            .background(Color.signalAmber.opacity(0.1))
            .overlay(
                Rectangle()
                    .fill(Color.signalAmber.opacity(0.3))
                    .frame(height: 0.5),
                alignment: .bottom
            )
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("recording-bar.problem")
        }
    }

    private var message: String? {
        if let problem = capture.transcriptionProblemText {
            return problem
        }
        let halted = capture.haltedTranslationLanguages
        if halted.isEmpty == false {
            let names = halted
                .map { Locale.current.localizedString(forLanguageCode: $0) ?? $0.uppercased() }
                .joined(separator: ", ")
            return String(format: String(localized: "capture.translation.halted"), names)
                + " " + String(localized: "capture.translation.halted.detail")
        }
        if capture.captureState == .paused,
           capture.remoteHealth == .live
            || capture.remoteHealth == .connecting
            || capture.remoteHealth == .degraded {
            return String(localized: "capture.toolbar.pause_billing_detail")
        }
        return nil
    }

    private var icon: String {
        capture.captureState == .paused && capture.transcriptionProblemText == nil
            ? "clock.badge.exclamationmark"
            : "exclamationmark.triangle.fill"
    }
}

/// The live-captions choice beside a Record button: what the next recording
/// will do, switchable in place. Captions send audio to Soniox, so the choice
/// is made — and visible — where recording starts, never implied.
struct CaptionsChoiceChip: View {
    @ObservedObject private var commands = CaptureCommandCenter.shared
    @ObservedObject private var invite = CommunityInviteSession.shared
    @ObservedObject private var credentials = ProviderCredentialSession.shared
    var isLocked = false

    var body: some View {
        let _ = credentials.statusRevision
        let available = commands.realtimeCredentialAvailable
        let on = commands.realtimeCaptionsEnabled && available
        Button {
            if available {
                commands.setRealtimeCaptionsEnabled(!commands.realtimeCaptionsEnabled)
            } else {
                MainNavigationStore.shared.openSettings(section: .captions)
            }
        } label: {
            Label(
                on ? onTitle : String(localized: "captions_choice.off"),
                systemImage: on ? "captions.bubble.fill" : "mic.fill"
            )
            .font(.bodyMedium)
            .foregroundColor(on ? .brandAccent : .textSecondary)
            .padding(.horizontal, Spacing.md)
            .frame(minHeight: 36)
            .background(on ? Color.brandAccent.opacity(0.1) : Color.bgElevated.opacity(0.5))
            .overlay(
                Capsule().strokeBorder(
                    (on ? Color.brandAccent : Color.borderGhost).opacity(0.35),
                    lineWidth: Stroke.thin
                )
            )
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isLocked)
        .help(helpText(available: available, on: on))
        .accessibilityLabel(Text(String(localized: on ? "captions_choice.on" : "captions_choice.off")))
        .accessibilityHint(Text(helpText(available: available, on: on)))
        .accessibilityIdentifier("captions-choice")
    }

    /// With an invite, how long it lasts at the connections this recording
    /// will open — said before recording, where the time is about to be
    /// spent, rather than only in the sidebar.
    private var onTitle: String {
        guard invite.isEnabled, invite.isActive, let remaining = invite.remainingSeconds else {
            return String(localized: "captions_choice.on")
        }
        let recordable = CommunityInviteSession.wallClockRecordableSeconds(
            remainingSeconds: remaining,
            laneCount: invite.plannedLaneCount
        )
        let length = RecordingPresentation.duration(ms: UInt64(max(recordable, 0)) * 1_000)
            ?? RecordingPresentation.duration(ms: 1_000) ?? ""
        return String(format: String(localized: "captions_choice.on_invite_format"), length)
    }

    private func helpText(available: Bool, on: Bool) -> String {
        guard available else { return String(localized: "captions_choice.unavailable_hint") }
        return String(localized: on ? "captions_choice.on_hint" : "captions_choice.off_hint")
    }
}
