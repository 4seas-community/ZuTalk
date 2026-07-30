import Combine
import Foundation
import SwiftUI

/// Reasons that replace the regular menu-bar waveform with a remediation state.
enum MenuBarSuppressionReason: Equatable {
    case privacy
    case userDisabled
    case onboarding
}

/// The state machine driving the menu-bar status icon and popover content.
/// `ActiveBilingualTranscriptStore` is the only recording lifecycle owner; this
/// store receives derived presentation snapshots for the menu-bar and HUD.
/// `recordingCompact` and `recordingExpanded` render the same popover layout but
/// remain distinct presentation states for callers that choose compactness.
enum MenuBarRuntimeState: Equatable {
    case idle
    case recordingCompact(RecordingInfo)
    case recordingExpanded(RecordingInfo, recentLines: [TranscriptLine])
    case backgroundProcessing(ProcessingInfo)

    var isRecording: Bool {
        switch self {
        case .recordingCompact, .recordingExpanded:
            return true
        default:
            return false
        }
    }
}

@MainActor
final class MenuBarRuntimeStore: ObservableObject {
    static let shared = MenuBarRuntimeStore()

    @Published private(set) var state: MenuBarRuntimeState = .idle
    @Published private(set) var suppressionReason: MenuBarSuppressionReason?

    private var recordingRecentLinesCache: [TranscriptLine] = []

    private init() {}

    var isRecording: Bool {
        state.isRecording
    }

    var activeRecordingInfo: RecordingInfo? {
        switch state {
        case .recordingCompact(let info), .recordingExpanded(let info, _):
            return info
        default:
            return nil
        }
    }

    func resetForTesting() {
        state = .idle
        suppressionReason = nil
        recordingRecentLinesCache = []
    }

    /// Mark the status item as suppressed (currently only `.privacy` fires).
    /// While set, the icon swaps to `mic.slash.fill` and the popover shows
    /// `MenuBarSuppressedView` with a CTA toward System Settings.
    func setSuppressed(_ reason: MenuBarSuppressionReason?) {
        guard suppressionReason != reason else { return }
        suppressionReason = reason
    }

    func startRecording(info: RecordingInfo) {
        recordingRecentLinesCache = []
        state = .recordingCompact(info)
    }

    /// Mutate the in-flight `RecordingInfo`. No-op if recording is not active.
    func updateRecording(_ update: (inout RecordingInfo) -> Void) {
        switch state {
        case .recordingCompact(var info):
            update(&info)
            state = .recordingCompact(info)
        case .recordingExpanded(var info, let recentLines):
            update(&info)
            state = .recordingExpanded(info, recentLines: recentLines)
        default:
            break
        }
    }

    /// Push the most recent transcript lines so the popover (if opened) can
    /// render them. Lines are cached even in `recordingCompact` so opening the
    /// popover mid-recording shows context immediately.
    func updateRecordingRecentLines(_ recentLines: [TranscriptLine]) {
        guard state.isRecording else { return }
        recordingRecentLinesCache = recentLines

        if case .recordingExpanded(let info, _) = state {
            state = .recordingExpanded(info, recentLines: recentLines)
        }
    }

    var cachedRecentLines: [TranscriptLine] { recordingRecentLinesCache }

    func stopRecording() {
        recordingRecentLinesCache = []
        state = .idle
    }

    func returnToIdle() {
        recordingRecentLinesCache = []
        state = .idle
    }

    func showProcessing(_ info: ProcessingInfo) {
        state = .backgroundProcessing(info)
    }
}
