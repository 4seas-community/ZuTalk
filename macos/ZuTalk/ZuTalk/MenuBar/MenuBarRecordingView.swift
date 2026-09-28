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

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            header
            CaptureStateLabel(
                captureState: info.captureState,
                remoteHealth: info.remoteHealth,
                projectionState: info.projectionState,
                haltedTranslationLanguages: capture.haltedTranslationLanguages
            )
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

    private var header: some View {
        HStack(spacing: Spacing.sm) {
            PulsingDot(
                color: info.isPaused ? Color.accentGold : Color.accentOrange,
                size: 8
            )
            Text(info.elapsedString)
                .font(Font.monoNum12)
                .foregroundColor(info.isPaused ? Color.accentGold : Color.textPrimary)
            Text("·")
                .font(Font.mono10)
                .foregroundColor(Color.textMuted)
            Text(info.languagePair)
                .font(Font.mono10)
                .foregroundColor(Color.textSecondary)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(
            "\(info.isPaused ? String(localized: "capture.state.paused") : String(localized: "capture.state.recording")), \(info.elapsedString)"
        ))
    }

    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(String(localized: "menubar.recording.live_transcript"))
                .font(Font.mono9)
                .foregroundColor(Color.textTertiary)
                .textCase(.uppercase)

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
    }

    private var openNotebookButton: some View {
        Button(action: openNotebook) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "rectangle.stack.fill")
                    .font(.system(size: 11, weight: .semibold))
                Text(String(localized: "menubar.recording.open_notebook"))
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
        .accessibilityLabel(Text(String(localized: "menubar.recording.open_notebook")))
    }

    private var floatingSubtitleButton: some View {
        Button(action: toggleFloatingSubtitles) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: subtitleOverlay.isPresented ? "pip.exit" : "pip.enter")
                    .font(.system(size: 11, weight: .semibold))
                Text(String(localized: subtitleOverlay.isPresented
                    ? "menubar.recording.close_subtitles"
                    : "menubar.recording.open_subtitles"))
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
        .accessibilityLabel(Text(String(localized: subtitleOverlay.isPresented
            ? "menubar.recording.close_subtitles"
            : "menubar.recording.open_subtitles")))
        .accessibilityHint(Text(String(localized: "capture.toolbar.subtitle_window.hint")))
        .accessibilityIdentifier(AccessibilityID.menuBarSubtitleButton)
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
    @ObservedObject private var commands = CaptureCommandCenter.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            if let problem = capture.transcriptionProblemText {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(Font.sans11Medium)
                    .foregroundColor(Color.accentGold)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Spacing.xs) {
                if capture.canRestartTranscription || capture.isRestartingTranscription {
                    control(
                        title: String(localized: "capture.toolbar.restart_transcription"),
                        systemImage: "arrow.clockwise",
                        tint: Color.accentGold,
                        disabled: capture.isRestartingTranscription
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
