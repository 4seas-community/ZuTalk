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
    @Published private(set) var placement: SubtitleOverlayPlacement = .restored

    /// Both presentation placements hide the operator chrome the same way.
    var isMaximized: Bool { placement != .restored }

    private let capture = ActiveBilingualTranscriptStore.shared

    private init() {}

    func toggle() {
        if WindowCoordinator.shared.isRegistered(.subtitleOverlay) {
            dismiss()
            return
        }

        // 两个合法的数据源:本机正在录,或者在别人的房间里收 —— 观看端的
        // 悬浮字幕吃远端帧(SubtitleOverlayView 的共享分支),不吃本机采集。
        guard capture.isCaptureActive || ShareActivityStore.shared.isViewing else {
            WindowCommandRouter.shared.openMainWindow(detail: "subtitle-overlay.idle") {
                MainNavigationStore.shared.openActiveNotebookForCapture()
            }
            return
        }

        WindowCoordinator.shared.presentSubtitleOverlay(store: capture)
        isPresented = true
    }

    func dismiss() {
        WindowCoordinator.shared.dismissSubtitleOverlay()
        isPresented = false
        placement = .restored
    }

    func toggleMaximized() {
        setPlacement(placement == .filled ? .restored : .filled)
    }

    /// A strip across the top of the display: the caption is readable from the
    /// back of the room and the slide underneath is still visible. Leaving it
    /// returns to the operator's own window, not to the other presentation
    /// placement, so one control always means "give me my window back".
    func toggleBanner() {
        setPlacement(placement == .banner ? .restored : .banner)
    }

    func restoreWindow() {
        guard placement != .restored else { return }
        setPlacement(.restored)
    }

    private func setPlacement(_ target: SubtitleOverlayPlacement) {
        placement = WindowCoordinator.shared.setSubtitleOverlayPlacement(target)
    }

    func surfaceDidClose() {
        isPresented = false
        placement = .restored
    }

    func resetForTesting() {
        dismiss()
    }
}
