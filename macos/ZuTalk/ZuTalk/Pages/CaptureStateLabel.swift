import AppKit
import Combine
import SwiftUI

struct CaptureStateLabel: View {
    let captureState: NotebookCaptureState
    let remoteHealth: NotebookRemoteHealth
    let projectionState: NotebookProjectionState
    var showsRemoteHealthWhenInactive = true
    /// Languages whose translation lane stopped mid-recording. Remote health
    /// cannot carry this: the capture is still live and its transcription is
    /// still healthy, which is exactly why the loss goes unnoticed.
    var haltedTranslationLanguages: [String] = []

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Label(captureStateText, systemImage: captureStateIcon)
            if captureState.isActive || showsRemoteHealthWhenInactive {
                Text("·").accessibilityHidden(true)
                Label(remoteText, systemImage: remoteIcon)
            }
            if captureState.isActive == false {
                Text("·").accessibilityHidden(true)
                Label(projectionText, systemImage: projectionIcon)
            }
            if haltedTranslationLanguages.isEmpty == false {
                Text("·").accessibilityHidden(true)
                // Gold, not the activity orange: orange belongs to recording
                // itself, and this notice appears while recording is healthy.
                Label(haltedTranslationText, systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.accentGold)
            }
        }
        .font(.captionMedium)
        .foregroundColor(.textSecondary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibilityStatus))
        .help(haltedTranslationLanguages.isEmpty ? "" : haltedTranslationHelp)
    }

    private var haltedTranslationText: String {
        let names = haltedTranslationLanguages
            .map { code in
                Locale.current.localizedString(forLanguageCode: code) ?? code.uppercased()
            }
            .joined(separator: ", ")
        return String(format: String(localized: "capture.translation.halted"), names)
    }

    private var haltedTranslationHelp: String {
        String(localized: "capture.translation.halted.detail")
    }

    private var accessibilityStatus: String {
        var parts = [captureStateText]
        if captureState.isActive || showsRemoteHealthWhenInactive {
            parts.append(remoteText)
        }
        if captureState.isActive == false {
            parts.append(projectionText)
        }
        if haltedTranslationLanguages.isEmpty == false {
            parts.append(haltedTranslationText)
        }
        return parts.joined(separator: ", ")
    }

    private var captureStateText: String {
        switch captureState {
        case .recording: return String(localized: "capture.state.recording")
        case .paused: return String(localized: "capture.state.paused")
        case .draining: return String(localized: "capture.state.draining")
        case .completed: return String(localized: "capture.state.completed")
        case .interrupted: return String(localized: "capture.state.interrupted")
        case .failed: return String(localized: "capture.state.failed")
        }
    }

    private var captureStateIcon: String {
        switch captureState {
        case .recording: return "record.circle.fill"
        case .paused: return "pause.circle.fill"
        case .draining: return "hourglass"
        case .completed: return "checkmark.circle.fill"
        case .interrupted: return "bolt.trianglebadge.exclamationmark.fill"
        case .failed: return "xmark.octagon.fill"
        }
    }

    private var remoteText: String {
        switch remoteHealth {
        case .off: return String(localized: "capture.remote.off")
        case .connecting: return String(localized: "capture.remote.connecting")
        case .live: return String(localized: "capture.remote.live")
        case .degraded: return String(localized: "capture.remote.degraded")
        case .unavailable: return String(localized: "capture.remote.unavailable")
        }
    }

    private var remoteIcon: String {
        switch remoteHealth {
        case .off: return "lock.fill"
        case .connecting: return "network"
        case .live: return "network.badge.shield.half.filled"
        case .degraded: return "exclamationmark.icloud.fill"
        case .unavailable: return "icloud.slash.fill"
        }
    }

    private var projectionText: String {
        switch projectionState {
        case .pending: return String(localized: "capture.projection.pending")
        case .projecting: return String(localized: "capture.projection.projecting")
        case .ready: return String(localized: "capture.projection.ready")
        case .failed: return String(localized: "capture.projection.failed")
        }
    }

    private var projectionIcon: String {
        switch projectionState {
        case .pending: return "clock.fill"
        case .projecting: return "arrow.triangle.2.circlepath"
        case .ready: return "pencil.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }
}
