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

    /// The one sentence beside the clock (docs/product/interface-layers.md).
    ///
    /// Whether the text was keeping up used to be said in six places, in two
    /// wordings, with two thresholds for "behind". It is said here once:
    /// first that the recording itself is fine, then what the text is doing.
    /// The cases are in priority order; `RecordingBarModel.statusLine` picks
    /// the first that applies.
    enum StatusLine: Equatable {
        case stopping(seconds: Int?)
        case pausing
        case resuming
        case paused
        case offline
        case textStopped
        case someTextStopped
        case textBehind
        case connectingText
        case audioOnly
        case recording

        /// The text needs a look. The recording itself never does here: a
        /// recording in trouble stops, and the bar goes with it.
        var reportsTextProblem: Bool {
            switch self {
            case .offline, .textStopped, .someTextStopped, .textBehind:
                return true
            case .stopping, .pausing, .resuming, .paused, .connectingText, .audioOnly, .recording:
                return false
            }
        }

        var text: String {
            switch self {
            case .stopping(let seconds): return RecordingBarContent.savingText(seconds: seconds)
            case .pausing: return String(localized: "capture.state.pausing")
            case .resuming: return String(localized: "capture.state.resuming")
            case .paused: return String(localized: "capture.state.paused")
            case .offline: return String(localized: "recording_bar.status.offline")
            case .textStopped: return String(localized: "recording_bar.status.text_stopped")
            case .someTextStopped: return String(localized: "recording_bar.status.some_text_stopped")
            case .textBehind: return String(localized: "recording_bar.status.text_behind")
            case .connectingText: return String(localized: "recording_bar.status.connecting")
            case .audioOnly: return String(localized: "recording_bar.status.audio_only")
            case .recording: return String(localized: "recording_bar.status.recording")
            }
        }
    }

    var phase: Phase
    var elapsed: TimeInterval
    /// Whole seconds since Stop began, while it is still finishing.
    var stoppingSeconds: Int? = nil
    var captions: Captions
    /// Captions were asked for and this Mac has no network. Said instead of
    /// "connecting", which reads as the service being slow.
    var offline: Bool = false
    /// "Chinese translation 12 s behind" and the like; nil while keeping up.
    var lagNotice: String?
    /// Why captions are not running normally, in words someone can act on.
    var problem: String?
    /// "Thai translation stopped": a language whose text ended while the
    /// rest carries on. Remote health stays "live" through this, so it is
    /// carried separately.
    var haltedNotice: String? = nil
    var canPause: Bool
    var canStop: Bool
    var stopNeedsRetry: Bool
    var justMarked: Bool
    /// Paused while a provider connection is still open and billing.
    var pausedWhileBilling: Bool

    var statusLine: StatusLine {
        switch phase {
        case .stopping: return .stopping(seconds: stoppingSeconds)
        case .pausing: return .pausing
        case .resuming: return .resuming
        case .paused: return .paused
        case .recording: break
        }
        if offline { return .offline }
        if captions == .stopped { return .textStopped }
        if captions == .partial || haltedNotice != nil { return .someTextStopped }
        if lagNotice != nil { return .textBehind }
        if captions == .connecting { return .connectingText }
        if captions == .off { return .audioOnly }
        return .recording
    }

    /// The exact version of what the sentence rounds off — which language,
    /// how many seconds, why — for whoever hovers to find out. Nil when the
    /// sentence already says all there is.
    var statusDetail: String? {
        if phase == .stopping { return nil }
        if offline { return String(localized: "network.offline.recording_banner") }
        if let problem { return problem }
        if let haltedNotice { return haltedNotice }
        if let lagNotice {
            return lagNotice + "\n" + String(localized: "capture.toolbar.translation_lag_hint")
        }
        return nil
    }

    @MainActor
    static func current(
        capture: ActiveBilingualTranscriptStore,
        commands: CaptureCommandCenter,
        networkOffline: Bool,
        now: Date = Date(),
        clock: Date = Date()
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
            stoppingSeconds: phase == .stopping
                ? capture.stoppingSince.map { max(0, Int(clock.timeIntervalSince($0))) }
                : nil,
            captions: captions,
            offline: networkOffline && captions != .off,
            lagNotice: capture.liveLagNotice,
            problem: capture.transcriptionProblemText,
            haltedNotice: RecordingAttention.haltedNotice(capture.haltedTranslationLanguages),
            canPause: commands.canPause,
            canStop: commands.canStop,
            stopNeedsRetry: capture.stopRecoveryRequired,
            justMarked: commands.lastMarkedAt.map { now.timeIntervalSince($0) < 2.5 } ?? false,
            pausedWhileBilling: capture.captureState == .paused && remoteOpen
        )
    }
}

/// What ⋯ holds: the second layer of the bar, one click in. These were
/// buttons on the live page, shown to everyone all the time; the page is now
/// only the transcript.
struct RecordingBarMenu: Equatable {
    var captionWindowOpen = false
    var readingLayout: NotebookTranscriptPresentationMode = .bilingualColumns
    /// 「给观众看字幕…」 is offered here whenever the bar's own button for it
    /// is not showing, so the panel is always reachable from one of the two.
    var offersAudienceCaptions = false
    /// The recording the audience panel is for.
    var sessionId: String?
    /// The title its viewers see.
    var audienceTitle = ""

    @MainActor
    static func current(
        capture: ActiveBilingualTranscriptStore,
        captionWindowOpen: Bool,
        readingLayout: TranscriptReadingLayout,
        audienceTitle: String,
        showsShareButton: Bool
    ) -> RecordingBarMenu {
        RecordingBarMenu(
            captionWindowOpen: captionWindowOpen,
            readingLayout: readingLayout.mode(for: capture.notebookId),
            offersAudienceCaptions: offersAudienceCaptions(
                sessionId: capture.sessionId,
                showsShareButton: showsShareButton
            ),
            sessionId: capture.sessionId,
            audienceTitle: audienceTitle
        )
    }

    /// Exactly one of the two entries to the audience panel is on screen:
    /// the bar's button for someone hosting, this item for everyone else.
    static func offersAudienceCaptions(sessionId: String?, showsShareButton: Bool) -> Bool {
        sessionId != nil && showsShareButton == false
    }
}

struct RecordingBarActions {
    var openRecording: () -> Void
    var mark: () -> Void
    var togglePause: () -> Void
    var stop: () -> Void
    var toggleCaptionWindow: () -> Void = {}
    var setReadingLayout: (NotebookTranscriptPresentationMode) -> Void = { _ in }
    var copyText: () -> Void = {}

    @MainActor
    static var live: RecordingBarActions {
        let commands = CaptureCommandCenter.shared
        let capture = ActiveBilingualTranscriptStore.shared
        return RecordingBarActions(
            openRecording: { MainNavigationStore.shared.openActiveNotebookForCapture() },
            mark: { commands.mark() },
            togglePause: { commands.togglePause() },
            stop: { commands.stop() },
            toggleCaptionWindow: { WindowCommandRouter.shared.requestToggleSubtitleOverlay() },
            setReadingLayout: { layout in
                guard let notebookId = capture.notebookId else { return }
                TranscriptReadingLayout.shared.choose(layout, for: notebookId)
            },
            copyText: {
                guard let sessionId = capture.sessionId else { return }
                // Copying reads the stored rows; words that are all still
                // speculative leave nothing to copy, which is not a failure.
                guard capture.timeline.frame.hasStoredRows else {
                    ToastCenter.shared.info(String(localized: "capture.transcript.copy_empty_hint"))
                    return
                }
                NotebookTranscriptCopy.copy(sessionId: sessionId, isLive: true)
            }
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
    /// The bar shows the clock; the capture store no longer ticks with it.
    @ObservedObject private var clock = ActiveBilingualTranscriptStore.shared.clock
    @ObservedObject private var commands = CaptureCommandCenter.shared
    @ObservedObject private var network = NetworkReachability.shared
    /// Flipping 「我在主持活动」 shows or hides the audience button at once.
    @ObservedObject private var hostMode = HostMode.shared
    @ObservedObject private var share = ShareActivityStore.shared
    @ObservedObject private var nearby = NearbyStore.shared
    @ObservedObject private var subtitleOverlay = SubtitleOverlayCoordinator.shared
    @ObservedObject private var readingLayout = TranscriptReadingLayout.shared
    @State private var topicTitle: String?
    @State private var markTick = Date()

    var body: some View {
        if capture.isCaptureActive {
            HStack(spacing: Spacing.sm) {
                // A hosting tool: showing this recording to an audience
                // starts here, and while it is live the same button says so
                // and how many are watching. Everyone else finds the same
                // panel under ⋯.
                if let sessionId = capture.sessionId, showsShareButton {
                    LiveShareButton(
                        sessionId: sessionId,
                        title: LiveShareText.title(topic: topicTitle),
                        compact: compact
                    )
                }
                if let since = capture.stoppingSince {
                    // Ticks only while Stop is finishing, to count it out.
                    TimelineView(.periodic(from: since, by: 1)) { context in
                        content(clock: context.date)
                    }
                } else {
                    content(clock: Date())
                }
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

    private var showsShareButton: Bool {
        guard let sessionId = capture.sessionId else { return false }
        return LiveShareButton.showsInBar(
            hostMode: hostMode,
            live: LiveShareButton.isLive(sessionId: sessionId, share: share, nearby: nearby)
        )
    }

    private func content(clock: Date) -> RecordingBarContent {
        RecordingBarContent(
            model: .current(
                capture: capture,
                commands: commands,
                networkOffline: network.isOffline,
                now: markTick,
                clock: clock
            ),
            menu: .current(
                capture: capture,
                captionWindowOpen: subtitleOverlay.isPresented,
                readingLayout: readingLayout,
                audienceTitle: LiveShareText.title(topic: topicTitle),
                showsShareButton: showsShareButton
            ),
            actions: .live,
            compact: compact
        )
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

/// Dot, clock, one sentence; then Mark, Pause, Stop and ⋯.
///
/// The bar used to carry the phase, the topic's name, a captions chip, a lag
/// label and a Reconnect button beside these — nineteen controls on screen
/// while recording, counting the live page's. What is left is what someone
/// needs to record, glance, and stop.
///
/// Everything on it is a pill of the shared family (`PillMetrics`,
/// `PillPalette`): the same height, fill and border as the pills on Home and
/// on a recording's page, so the bar reads as part of the app rather than a
/// strip of its own. Red is kept for two things: the dot, and Stop's icon.
struct RecordingBarContent: View {
    let model: RecordingBarModel
    var menu = RecordingBarMenu()
    let actions: RecordingBarActions
    var compact = false
    @State private var showsAudiencePanel = false

    var body: some View {
        HStack(spacing: PillMetrics.spacing) {
            identity
            // Where this recording will be filed, when a city event was chosen.
            CityDestinationChip(compact: compact)
            controls
        }
        .fixedSize()
    }

    private var identity: some View {
        let status = model.statusLine
        return Button(action: actions.openRecording) {
            HStack(spacing: Spacing.sm) {
                PulsingDot(color: dotColor, size: 8)
                    .accessibilityHidden(true)
                Text(CaptureCommandCenter.clock(model.elapsed))
                    .font(.monoNum12)
                    .foregroundColor(.textPrimary)
                if compact == false {
                    // Capped so a long translation cannot push the controls
                    // out of the header; the tooltip always has it in full.
                    Text(status.text)
                        .font(PillMetrics.font)
                        .foregroundColor(status.reportsTextProblem ? .signalAmber : .textSecondary)
                        .lineLimit(1)
                        .frame(maxWidth: Self.sentenceMaxWidth, alignment: .leading)
                }
            }
            .padding(.horizontal, PillMetrics.horizontalPadding)
            .modifier(PillChrome())
        }
        .buttonStyle(.plain)
        .help(statusHelp)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibilitySummary))
        .accessibilityHint(Text(String(localized: "recording_bar.status.open_hint")))
        .accessibilityIdentifier("recording-bar.open")
    }

    private var controls: some View {
        HStack(spacing: PillMetrics.spacing) {
            // No Reconnect here: when the text needs it, the line under the
            // header (`RecordingProblemBanner`) says why and offers it once.
            barButton(
                title: model.justMarked
                    ? String(localized: "recording_bar.marked")
                    : String(localized: "recording_bar.mark"),
                systemImage: model.justMarked ? "bookmark.fill" : "bookmark",
                // Tinted for the moment after a mark, like a toggle that is on.
                tone: model.justMarked ? .on : .normal,
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
                disabled: model.canPause == false,
                help: String(localized: "recording_bar.pause_hint"),
                action: actions.togglePause
            )
            .accessibilityIdentifier("recording-bar.pause")
            barButton(
                // While it saves, the sentence beside the clock says so and
                // counts; the button only shows that it is busy.
                title: model.stopNeedsRetry && model.phase != .stopping
                    ? String(localized: "recording_bar.retry_stop")
                    : String(localized: "capture.toolbar.stop"),
                // Not a bare ↻: that reads as reconnecting, which is the
                // banner's action, not this button's.
                systemImage: model.phase == .stopping
                    ? "hourglass"
                    : model.stopNeedsRetry ? "exclamationmark.arrow.circlepath" : "stop.fill",
                iconTint: .signalRed,
                disabled: model.canStop == false,
                help: String(localized: "recording_bar.stop_hint"),
                action: actions.stop
            )
            .accessibilityIdentifier("recording-bar.stop")
            moreMenu
        }
    }

    /// The caption window, the reading layout and Copy moved here from the
    /// live page. They stay one click away, where they do not have to be
    /// understood before pressing Stop.
    private var moreMenu: some View {
        MorePill(String(localized: "recording_bar.more")) {
            moreItems
        }
        .accessibilityIdentifier("recording-bar.more")
        // Anchored here rather than on the audience button: this is the
        // entry for someone who has no such button. It stays put when the
        // share starts and the button appears beside the bar.
        .popover(isPresented: $showsAudiencePanel, arrowEdge: .bottom) {
            if let sessionId = menu.sessionId {
                LiveSharePopover(sessionId: sessionId, title: menu.audienceTitle)
            }
        }
    }

    @ViewBuilder
    private var moreItems: some View {
        Button(
            String(localized: menu.captionWindowOpen
                ? "recording_bar.more.caption_window.close"
                : "recording_bar.more.caption_window.open"),
            action: actions.toggleCaptionWindow
        )
        .accessibilityIdentifier(AccessibilityID.floatingSubtitleButton)
        Divider()
        Picker(
            String(localized: "capture.transcript.presentation.label"),
            selection: Binding(
                get: { menu.readingLayout },
                set: { actions.setReadingLayout($0) }
            )
        ) {
            Text(String(localized: "capture.transcript.presentation.language_columns"))
                .tag(NotebookTranscriptPresentationMode.bilingualColumns)
            Text(String(localized: "capture.transcript.presentation.timeline"))
                .tag(NotebookTranscriptPresentationMode.sourceTimeline)
        }
        .pickerStyle(.inline)
        .labelsHidden()
        Divider()
        Button(String(localized: "recording_bar.more.copy_text"), action: actions.copyText)
            .accessibilityIdentifier("recording-bar.more.copy")
        if menu.offersAudienceCaptions {
            Divider()
            Button(String(localized: "recording_bar.more.audience")) {
                showsAudiencePanel = true
            }
            .accessibilityIdentifier("recording-bar.more.audience")
        }
    }

    /// One of the bar's controls, as a shared pill: a word and an icon, or
    /// — in a narrow window — the icon alone in a circle of the same height.
    private func barButton(
        title: String,
        systemImage: String,
        tone: PillTone = .normal,
        iconTint: Color? = nil,
        disabled: Bool,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        ActionPill(
            compact ? nil : title,
            systemImage: systemImage,
            tone: tone,
            iconTint: iconTint,
            help: help,
            accessibilityLabel: title,
            action: action
        )
        .disabled(disabled)
    }

    private var dotColor: Color {
        switch model.phase {
        case .recording: return .signalRed
        case .paused, .pausing, .resuming: return .signalAmber
        case .stopping: return .textTertiary
        }
    }

    /// Long recordings take a few seconds to seal; the count says it is
    /// working rather than stuck.
    static func savingText(seconds: Int?) -> String {
        guard let seconds, seconds >= 2 else {
            return String(localized: "capture.state.saving_recording")
        }
        return String(
            format: String(localized: "capture.state.saving_recording_seconds"),
            Int64(seconds)
        )
    }

    /// Wider than the sentence in any of the eight languages today.
    private static let sentenceMaxWidth: CGFloat = 300

    /// The sentence never counts seconds or names a language; the tooltip
    /// does, for whoever wants to know. It leads with the sentence itself,
    /// which a narrow window does not show at all.
    private var statusHelp: String {
        var lines = [model.statusLine.text]
        if let detail = model.statusDetail { lines.append(detail) }
        lines.append(String(localized: "recording_bar.status.open_hint"))
        return lines.joined(separator: "\n")
    }

    private var accessibilitySummary: String {
        [
            model.statusLine.text,
            CaptureCommandCenter.clock(model.elapsed),
        ].joined(separator: ", ")
    }
}

/// What about the recording's text needs a person, in the words the line
/// under the header uses: the reason, and whether Reconnect would help. The
/// menu bar popover says the same thing from here instead of wording it a
/// second way.
struct RecordingAttention: Equatable {
    enum Kind: Equatable {
        case offline
        case problem
        case translationHalted
        case pausedWhileBilling
    }

    var kind: Kind
    var message: String
    var icon: String
    /// Offered unless there is no network: the lanes already retry then, and
    /// pressing it changes nothing.
    var offersReconnect: Bool
    var isReconnecting: Bool

    @MainActor
    static func current(
        capture: ActiveBilingualTranscriptStore,
        networkOffline: Bool
    ) -> RecordingAttention? {
        // No network explains every caption problem underneath it, and its
        // remedy is the user's own Wi-Fi, so it is said first.
        let offline = networkOffline && capture.remoteHealth != .off
        let kind: Kind
        let message: String
        if offline {
            kind = .offline
            message = String(localized: "network.offline.recording_banner")
        } else if let problem = capture.transcriptionProblemText {
            kind = .problem
            message = problem
        } else if let halted = haltedNotice(capture.haltedTranslationLanguages) {
            kind = .translationHalted
            message = halted + " " + String(localized: "capture.translation.halted.detail")
        } else if capture.captureState == .paused,
                  capture.remoteHealth == .live
                    || capture.remoteHealth == .connecting
                    || capture.remoteHealth == .degraded {
            kind = .pausedWhileBilling
            message = String(localized: "capture.toolbar.pause_billing_detail")
        } else {
            return nil
        }
        let icon: String
        if offline {
            icon = "wifi.slash"
        } else if capture.captureState == .paused, capture.transcriptionProblemText == nil {
            icon = "clock.badge.exclamationmark"
        } else {
            icon = "exclamationmark.triangle.fill"
        }
        return RecordingAttention(
            kind: kind,
            message: message,
            icon: icon,
            offersReconnect: offline == false
                && (capture.canRestartTranscription || capture.isRestartingTranscription),
            isReconnecting: capture.isRestartingTranscription
        )
    }

    /// "Thai translation stopped", naming every language it happened to.
    static func haltedNotice(_ languages: [String]) -> String? {
        guard languages.isEmpty == false else { return nil }
        let names = languages
            .map { Locale.current.localizedString(forLanguageCode: $0) ?? $0.uppercased() }
            .joined(separator: ", ")
        return String(format: String(localized: "capture.translation.halted"), names)
    }
}

/// A full-width line under the header when live captions need attention:
/// why they stopped, and the one action that brings them back. Recording
/// itself is unaffected, so this informs rather than alarms.
struct RecordingProblemBanner: View {
    @ObservedObject private var capture = ActiveBilingualTranscriptStore.shared
    @ObservedObject private var livePresentation = ActiveBilingualTranscriptStore.shared.livePresentation
    @ObservedObject private var commands = CaptureCommandCenter.shared
    @ObservedObject private var network = NetworkReachability.shared

    var body: some View {
        if capture.isCaptureActive,
           let attention = RecordingAttention.current(
               capture: capture,
               networkOffline: network.isOffline
           ) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: attention.icon)
                    .foregroundColor(.signalAmber)
                    .accessibilityHidden(true)
                Text(attention.message)
                    .font(.bodySM)
                    .foregroundColor(.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Spacing.md)
                if attention.offersReconnect {
                    ActionPill(
                        String(localized: "capture.toolbar.restart_transcription"),
                        systemImage: attention.isReconnecting ? "hourglass" : "arrow.clockwise",
                        help: String(localized: "capture.toolbar.restart_transcription_hint")
                    ) {
                        commands.restartTranscription()
                    }
                    .disabled(attention.isReconnecting)
                    // The bar's own Reconnect button is gone; this is the one.
                    .accessibilityIdentifier("recording-bar.reconnect")
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
}
