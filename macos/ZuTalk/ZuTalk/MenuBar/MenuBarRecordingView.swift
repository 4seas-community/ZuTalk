import SwiftUI

/// Popover content shown while recording. Combines what were two island states
/// (`recordingCompact` / `recordingExpanded`) — the popover has the space to
/// always show the header *and* the transcript preview together; there is no
/// progressive disclosure to design for.
@MainActor
struct MenuBarRecordingView: View {
    let info: RecordingInfo
    let recentLines: [TranscriptLine]
    @ObservedObject private var subtitleOverlay = SubtitleOverlayCoordinator.shared
    @ObservedObject private var capture = ActiveBilingualTranscriptStore.shared
    /// Lag and halted languages reach the sentence through these.
    @ObservedObject private var livePresentation = ActiveBilingualTranscriptStore.shared.livePresentation
    @ObservedObject private var commands = CaptureCommandCenter.shared
    @ObservedObject private var network = NetworkReachability.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            header
            // App 缩在菜单栏里录音时,这里是唯一看得见的表面 ——
            // 这场录音在不在直播给别人看,必须在这里也说。
            LiveShareStatusLabel(sessionId: capture.sessionId)
            MenuBarRecordingControls()
            if !recentLines.isEmpty {
                transcriptSection
            }
            floatingSubtitleButton
            openNotebookButton
        }
    }

    /// Dot, clock, and the recording bar's own sentence. This row used to
    /// carry a language-or-engine label, with a second row under it wording
    /// the state of the captions a third way.
    private var header: some View {
        let status = statusLine
        return HStack(spacing: Spacing.sm) {
            PulsingDot(
                color: info.isPaused ? Color.accentGold : Color.accentOrange,
                size: 8
            )
            Text(info.elapsedString)
                .font(Font.monoNum12)
                .foregroundColor(info.isPaused ? Color.accentGold : Color.textPrimary)
            Text(status.text)
                .font(Font.sans12)
                .foregroundColor(status.reportsTextProblem ? Color.accentGold : Color.textSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(status.text), \(info.elapsedString)"))
        .accessibilityIdentifier("menu-bar.recording-status")
    }

    /// The same value the recording bar shows. The seconds of a stop are
    /// left out: nothing here ticks while it finishes.
    private var statusLine: RecordingBarModel.StatusLine {
        var model = RecordingBarModel.current(
            capture: capture,
            commands: commands,
            networkOffline: network.isOffline
        )
        model.stoppingSeconds = nil
        return model.statusLine
    }

    /// The last two lines, as they are. The box used to carry a title; two
    /// timestamped lines of what was just said need none, so the title is
    /// now only what VoiceOver calls the box.
    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            ForEach(recentLines.suffix(2)) { line in
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    HStack(spacing: Spacing.sm) {
                        Text(line.timestamp)
                            .font(Font.mono9)
                            .foregroundColor(Color.textDim)
                        if !line.languageLabel.isEmpty {
                            Text(line.languageLabel)
                                .font(Font.mono9)
                                .foregroundColor(Color.textSecondary)
                        }
                    }
                    Text(line.text)
                        .font(Font.sans12)
                        .foregroundColor(Color.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
        }
        .padding(Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Radius.sm)
                .fill(Color.bgPanel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.sm)
                .stroke(Color.borderPanel, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(String(localized: "menubar.recording.live_transcript")))
    }

    /// Opens the recording in progress, which is what it now says. It used
    /// to say "Open topic".
    private var openNotebookButton: some View {
        Button(action: openNotebook) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "rectangle.stack.fill")
                    .font(.system(size: 11, weight: .semibold))
                Text(String(localized: "menubar.recording.open_recording"))
                    .font(Font.sans11Medium)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(Color.textTertiary)
            }
            .foregroundColor(Color.textSecondary)
            .padding(.horizontal, Spacing.sm)
            .frame(height: Spacing.xl)
            .background(
                RoundedRectangle(cornerRadius: Radius.sm)
                    .fill(Color.clear)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(String(localized: "menubar.recording.open_recording")))
    }

    private var floatingSubtitleButton: some View {
        Button(action: toggleFloatingSubtitles) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: subtitleOverlay.isPresented ? "pip.exit" : "pip.enter")
                    .font(.system(size: 11, weight: .semibold))
                Text(captionWindowTitle)
                    .font(Font.sans11Medium)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(Color.textTertiary)
            }
            .foregroundColor(Color.brandAccent)
            .padding(.horizontal, Spacing.sm)
            .frame(height: Spacing.xl)
            .background(
                RoundedRectangle(cornerRadius: Radius.sm)
                    .fill(Color.brandAccentSoft)
            )
        }
        .buttonStyle(.plain)
        .help(String(localized: "capture.toolbar.subtitle_window.hint"))
        .accessibilityLabel(Text(captionWindowTitle))
        .accessibilityHint(Text(String(localized: "capture.toolbar.subtitle_window.hint")))
        .accessibilityIdentifier(AccessibilityID.menuBarSubtitleButton)
    }

    /// The caption window under the one name it has everywhere, the same
    /// words as in the recording bar's ⋯.
    private var captionWindowTitle: String {
        String(localized: subtitleOverlay.isPresented
            ? "recording_bar.more.caption_window.close"
            : "recording_bar.more.caption_window.open")
    }

    private func openNotebook() {
        WindowCommandRouter.shared.openMainWindow(detail: "menu-bar.popover.open-notebook") {
            MainNavigationStore.shared.openActiveNotebookForCapture()
        }
        MenuBarCoordinator.shared.closePopover()
    }

    private func toggleFloatingSubtitles() {
        WindowCommandRouter.shared.requestToggleSubtitleOverlay()
        MenuBarCoordinator.shared.closePopover()
    }

}

/// Mark, Pause and Stop for the recording in progress, from the menu bar.
///
/// The popover used to say "read only" and send people to the main window
/// for these — while ZuTalk was tucked away behind the slides or the call
/// they were recording.
@MainActor
private struct MenuBarRecordingControls: View {
    @ObservedObject private var capture = ActiveBilingualTranscriptStore.shared
    @ObservedObject private var livePresentation = ActiveBilingualTranscriptStore.shared.livePresentation
    @ObservedObject private var commands = CaptureCommandCenter.shared
    @ObservedObject private var network = NetworkReachability.shared

    /// Why the text needs attention and whether Reconnect helps, exactly as
    /// the line under the main window's header puts it. The note about a
    /// paused connection still being billed stays in the main window: it
    /// asks for nothing that can be done from here.
    private var attention: RecordingAttention? {
        guard let attention = RecordingAttention.current(
            capture: capture,
            networkOffline: network.isOffline
        ), attention.kind != .pausedWhileBilling else { return nil }
        return attention
    }

    var body: some View {
        let attention = self.attention
        VStack(alignment: .leading, spacing: Spacing.xs) {
            if let attention {
                Label(attention.message, systemImage: attention.icon)
                    .font(Font.sans11Medium)
                    .foregroundColor(Color.accentGold)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Spacing.xs) {
                if attention?.offersReconnect == true {
                    control(
                        title: String(localized: "capture.toolbar.restart_transcription"),
                        systemImage: "arrow.clockwise",
                        tint: Color.accentGold,
                        disabled: attention?.isReconnecting == true
                    ) { commands.restartTranscription() }
                }
                control(
                    title: String(localized: "recording_bar.mark"),
                    systemImage: "bookmark",
                    tint: Color.textPrimary,
                    disabled: capture.captureState == .draining
                ) { commands.mark() }
                control(
                    title: capture.captureState == .paused
                        ? String(localized: "capture.toolbar.resume")
                        : String(localized: "capture.toolbar.pause"),
                    systemImage: capture.captureState == .paused ? "play.fill" : "pause.fill",
                    tint: Color.textPrimary,
                    disabled: commands.canPause == false
                ) { commands.togglePause() }
                control(
                    title: String(localized: "capture.toolbar.stop"),
                    systemImage: "stop.fill",
                    tint: Color.signalRed,
                    disabled: commands.canStop == false
                ) {
                    commands.stop(announce: true)
                    MenuBarCoordinator.shared.closePopover()
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("menu-bar.recording-controls")
    }

    private func control(
        title: String,
        systemImage: String,
        tint: Color,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                Text(title)
                    .font(Font.sans11Medium)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundColor(tint)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(RoundedRectangle(cornerRadius: Radius.sm).fill(Color.bgPanel))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.sm)
                    .stroke(Color.borderPanel, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
        .accessibilityLabel(Text(title))
    }
}
