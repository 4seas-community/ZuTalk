import Combine
import Foundation

/// Owns the single live-subtitle surface. Recording and translation remain
/// owned by `ActiveBilingualTranscriptStore`; the overlay is presentation only.
@MainActor
final class SubtitleOverlayCoordinator: ObservableObject {
    static let shared = SubtitleOverlayCoordinator()

    @Published private(set) var isPresented = false

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
    }

    func surfaceDidClose() {
        isPresented = false
    }

    func resetForTesting() {
        dismiss()
    }
}
