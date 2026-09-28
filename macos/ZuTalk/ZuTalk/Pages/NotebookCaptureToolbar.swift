import AppKit
import Combine
import SwiftUI

/// Where a topic's recording starts: the live-captions choice and Record.
///
/// While a recording runs — this topic's or any other — its controls are in
/// the recording bar above every page (`RecordingBar`), so this stays out of
/// the way instead of offering a second, partial set of them.
struct NotebookCaptureToolbar: View {
    let notebookId: String
    @ObservedObject var profileEditor: NotebookCaptureProfileEditorModel
    @ObservedObject private var capture = ActiveBilingualTranscriptStore.shared
    @ObservedObject private var commands = CaptureCommandCenter.shared

    var body: some View {
        HStack(spacing: Spacing.sm) {
            if capture.isCaptureActive {
                EmptyView()
            } else {
                CaptionsChoiceChip()
                startButton
            }
        }
        .onAppear { publishPlannedLaneCount() }
        .montereyOnChange(of: profileEditor.draft.selectedLanguages) { _, _ in
            publishPlannedLaneCount()
        }
        .montereyOnChange(of: profileEditor.draft.subtitleOnlyLanguages) { _, _ in
            publishPlannedLaneCount()
        }
        .montereyOnChange(of: commands.nextRecordingUsesCaptions) { _, _ in
            publishPlannedLaneCount()
        }
    }

    /// Keeps the sidebar's invite-time display honest: it divides shared
    /// invite seconds by this lane count. Local-only recordings open no
    /// remote lanes, so they report a single lane.
    private func publishPlannedLaneCount() {
        CommunityInviteSession.shared.updatePlannedLaneCount(
            commands.nextRecordingUsesCaptions
                ? Self.remoteLaneCount(
                    selectedLanguages: profileEditor.draft.selectedLanguages,
                    subtitleOnlyLanguages: profileEditor.draft.subtitleOnlyLanguages
                )
                : 1
        )
    }

    /// See `NotebookCaptureStartPreparationWorkflow.remoteLaneCount`.
    static func remoteLaneCount(
        selectedLanguages: [String],
        subtitleOnlyLanguages: [String] = []
    ) -> Int {
        NotebookCaptureStartPreparationWorkflow.remoteLaneCount(
            selectedLanguages: selectedLanguages,
            subtitleOnlyLanguages: subtitleOnlyLanguages
        )
    }

    private var startButton: some View {
        let disabledReason = profileEditor.captureStartDisabledReason
        return Button {
            guard commands.isStarting == false, disabledReason == nil else { return }
            commands.start(notebookId: notebookId, profileEditor: profileEditor)
        } label: {
            Label(
                commands.isStarting
                    ? String(localized: "capture.toolbar.starting")
                    : String(localized: "capture.toolbar.start"),
                systemImage: commands.isStarting ? "ellipsis" : "record.circle"
            )
            .font(.bodyMedium)
            .padding(.horizontal, Spacing.md)
            .frame(minHeight: 36)
        }
        .buttonStyle(.plain)
        .foregroundColor(.signalRed)
        .background(Color.signalRed.opacity(0.1))
        .overlay(Capsule().strokeBorder(Color.signalRed.opacity(0.3), lineWidth: 0.5))
        .clipShape(Capsule())
        .disabled(commands.isStarting || disabledReason != nil)
        .accessibilityLabel(Text(String(localized: "capture.toolbar.start")))
        .accessibilityHint(Text(disabledReason ?? String(localized: "capture.toolbar.start_hint")))
        .help(disabledReason ?? String(localized: "capture.toolbar.start_hint"))
        .accessibilityIdentifier("capture.start")
    }
}
