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

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            header
            CaptureStateLabel(
                captureState: info.captureState,
                remoteHealth: info.remoteHealth,
                projectionState: info.projectionState
            )
            readOnlyNotice
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

    private var readOnlyNotice: some View {
        Label(
            String(localized: "subtitle.overlay.read_only"),
            systemImage: "eye.fill"
        )
        .font(Font.sans11Medium)
        .foregroundColor(Color.textSecondary)
        .padding(.horizontal, Spacing.sm)
        .frame(maxWidth: .infinity, minHeight: Spacing.xl, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.sm).fill(Color.bgPanel))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.sm)
                .stroke(Color.borderPanel, lineWidth: 1)
        )
        .accessibilityLabel(Text(String(localized: "subtitle.overlay.read_only")))
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
