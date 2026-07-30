import Combine
import Foundation

/// Coordinates read-only capture mirrors. It never creates an STT session,
/// subscribes to a microphone, or stops the Notebook-owned capture.
@MainActor
final class OverlaySessionCoordinatorV2 {
    static let shared = OverlaySessionCoordinatorV2()

    private let capture = ActiveBilingualTranscriptStore.shared
    private var captionStore: CaptionStoreV2?
    private var operatorStore: OperatorPanelStoreV2?
    private var utteranceObserver: AnyCancellable?
    private var statusObserver: AnyCancellable?
    private var captionFontObserver: AnyCancellable?

    private init() {}

    var isFloatingPanelVisible: Bool {
        WindowCoordinator.shared.isRegistered(.floatingPanel)
    }

    func toggleFloatingPanel() {
        if isFloatingPanelVisible {
            stopFloatingPanelIfNeeded()
            return
        }
        guard capture.isCaptureActive else {
            openOwningNotebook(detail: "floating.idle-open-notebook")
            return
        }
        WindowCoordinator.shared.presentFloatingPanel(store: capture)
    }

    func stopFloatingPanelIfNeeded() {
        WindowCoordinator.shared.dismissFloatingPanel()
    }

    func toggleCaptionMirror() {
        if WindowCoordinator.shared.isRegistered(.captionMirror) {
            stopCaptionMirror()
            return
        }
        guard capture.isCaptureActive else {
            openOwningNotebook(detail: "caption-mirror.idle-open-notebook")
            return
        }

        let captionStore = CaptionStoreV2()
        let operatorStore = OperatorPanelStoreV2()
        self.captionStore = captionStore
        self.operatorStore = operatorStore
        syncMirrors()

        utteranceObserver = Publishers.CombineLatest(capture.$profile, capture.$utterances)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in
                self?.syncMirrors()
            }
        statusObserver = Publishers.CombineLatest4(
            capture.$captureState,
            capture.$remoteHealth,
            capture.$projectionState,
            capture.$elapsedRecordingTime
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _, _, _, _ in
            self?.syncMirrors()
        }
        captionFontObserver = operatorStore.$captionFontSize
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak captionStore] fontSize in
                captionStore?.fontSize = fontSize
            }

        _ = WindowCoordinator.shared.ensureCaptionMirror(
            store: captionStore,
            onClose: { [weak self] in
                self?.stopCaptionMirror(closeSurface: false)
            }
        )
        WindowCoordinator.shared.presentCaptionMirror(store: captionStore)
        WindowCoordinator.shared.presentOperatorPanel(store: operatorStore)
    }

    func resetForTesting() {
        stopFloatingPanelIfNeeded()
        stopCaptionMirror()
    }

    private func stopCaptionMirror(closeSurface: Bool = true) {
        utteranceObserver?.cancel()
        utteranceObserver = nil
        statusObserver?.cancel()
        statusObserver = nil
        captionFontObserver?.cancel()
        captionFontObserver = nil
        if closeSurface {
            WindowCoordinator.shared.dismissCaptionMirror()
            WindowCoordinator.shared.dismissOperatorPanel()
        }
        captionStore = nil
        operatorStore = nil
    }

    private func syncMirrors() {
        guard let captionStore, let operatorStore else { return }
        let status = mirrorStatusText
        captionStore.statusMessage = status
        operatorStore.captureStatus = status
        operatorStore.isRunning = capture.isCaptureActive
        operatorStore.elapsedTime = capture.elapsedRecordingTime
        operatorStore.configure(selectedLanguages: capture.selectedLanguages)

        captionStore.selectedLanguages = capture.selectedLanguages

        guard capture.isCaptureActive else {
            captionStore.rows = []
            return
        }

        var rows: [CaptionOverlayRowV2] = []
        for utterance in capture.utterances.suffix(3) {
            rows.append(CaptionOverlayRowV2(
                id: utterance.id,
                sourceLanguage: utterance.sourceLanguage,
                projection: capture.projection(for: utterance)
            ))
        }
        captionStore.rows = rows
    }

    private var mirrorStatusText: String {
        if capture.isCaptureActive == false {
            return String(localized: "capture.mirror.idle")
        }
        switch capture.captureState {
        case .recording:
            return capture.remoteHealth == .degraded || capture.remoteHealth == .unavailable
                ? String(localized: "capture.mirror.recording_degraded")
                : String(localized: "capture.mirror.recording")
        case .paused:
            return String(localized: "capture.mirror.paused")
        case .draining:
            return String(localized: "capture.mirror.draining")
        case .completed, .interrupted, .failed:
            return String(localized: "capture.mirror.idle")
        }
    }

    private func openOwningNotebook(detail: String) {
        WindowCommandRouter.shared.openMainWindow(detail: detail) {
            MainNavigationStoreV2.shared.openActiveNotebookForCapture()
        }
    }
}
