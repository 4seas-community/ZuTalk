import Combine
import Foundation

/// Keeps the display awake only while the live-subtitle surface is enabled.
/// `ProcessInfo` maps this scoped activity to macOS power-management
/// assertions; ending the activity restores the user's existing idle policy.
@MainActor
final class SubtitleDisplaySleepActivity {
    typealias ActivityToken = any NSObjectProtocol
    typealias BeginActivity = (ProcessInfo.ActivityOptions, String) -> ActivityToken
    typealias EndActivity = (ActivityToken) -> Void

    static let options: ProcessInfo.ActivityOptions = [
        .userInitiated,
        .idleDisplaySleepDisabled,
    ]
    static let reason = "Displaying live subtitles"

    private let beginActivity: BeginActivity
    private let endActivity: EndActivity
    private var token: ActivityToken?

    init(
        beginActivity: @escaping BeginActivity = {
            ProcessInfo.processInfo.beginActivity(options: $0, reason: $1)
        },
        endActivity: @escaping EndActivity = {
            ProcessInfo.processInfo.endActivity($0)
        }
    ) {
        self.beginActivity = beginActivity
        self.endActivity = endActivity
    }

    var isActive: Bool {
        token != nil
    }

    func setActive(_ shouldBeActive: Bool) {
        if shouldBeActive {
            guard token == nil else { return }
            token = beginActivity(Self.options, Self.reason)
            return
        }

        guard let token else { return }
        self.token = nil
        endActivity(token)
    }

    deinit {
        if let token {
            endActivity(token)
        }
    }
}

/// Owns the single live-subtitle surface. Recording and translation remain
/// owned by `ActiveBilingualTranscriptStore`; the overlay is presentation only.
@MainActor
final class SubtitleOverlayCoordinator: ObservableObject {
    static let shared = SubtitleOverlayCoordinator()

    @Published private(set) var isPresented = false
    @Published private(set) var isMaximized = false

    private let capture = ActiveBilingualTranscriptStore.shared

    private init() {}

    func toggle() {
        if WindowCoordinator.shared.isRegistered(.subtitleOverlay) {
            dismiss()
            return
        }

        guard capture.isCaptureActive else {
            WindowCommandRouter.shared.openMainWindow(detail: "subtitle-overlay.idle") {
                MainNavigationStoreV2.shared.openActiveNotebookForCapture()
            }
            return
        }

        WindowCoordinator.shared.presentSubtitleOverlay(store: capture)
        isPresented = true
    }

    func dismiss() {
        WindowCoordinator.shared.dismissSubtitleOverlay()
        isPresented = false
        isMaximized = false
    }

    func toggleMaximized() {
        isMaximized = WindowCoordinator.shared.setSubtitleOverlayMaximized(!isMaximized)
    }

    func restoreWindow() {
        guard isMaximized else { return }
        isMaximized = WindowCoordinator.shared.setSubtitleOverlayMaximized(false)
    }

    func surfaceDidClose() {
        isPresented = false
        isMaximized = false
    }

    func resetForTesting() {
        dismiss()
    }
}
