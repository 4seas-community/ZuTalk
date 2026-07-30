import AppKit

@MainActor
final class WindowCoordinator {
    static let shared = WindowCoordinator()

    private final class WeakWindowBox {
        weak var window: NSWindow?

        init(_ window: NSWindow) {
            self.window = window
        }
    }

    private struct PendingLayoutUpdate {
        let input: WindowLayoutInput
        let animated: Bool
        let reason: String
    }

    private struct DiagnosticObserverSpec {
        let name: Notification.Name
        let label: String
    }

    private struct DiagnosticAttachment {
        let windowID: ObjectIdentifier
        let tokens: [NSObjectProtocol]
    }

    private var catalog: [WindowSurfaceID: WindowSpec] = [:]
    private var registeredWindows: [WindowSurfaceID: WeakWindowBox] = [:]
    private var mainSurfaceController: MainWindowControllerV2?
    private var floatingPanelSurfaceController: FloatingPanelControllerV2?
    private var captionSurfaceController: CaptionControllerV2?
    private var operatorPanelSurfaceController: OperatorPanelControllerV2?
    private var pendingLayoutUpdates: [WindowSurfaceID: PendingLayoutUpdate] = [:]
    private var scheduledLayoutUpdates: Set<WindowSurfaceID> = []
    private var diagnosticAttachments: [WindowSurfaceID: DiagnosticAttachment] = [:]

    private init() {}

    func installBaselineCatalog() {
        guard catalog.isEmpty else { return }
        catalog = WindowSpec.baselineCatalog()
        CrashDiagnostics.record(
            "window-system.bootstrap",
            "baseline catalog ready",
            detail: "count=\(catalog.count)"
        )
    }

    func spec(for id: WindowSurfaceID) -> WindowSpec? {
        if catalog.isEmpty {
            installBaselineCatalog()
        }
        return catalog[id]
    }

    func catalogSnapshot() -> [WindowSpec] {
        if catalog.isEmpty {
            installBaselineCatalog()
        }
        return WindowSurfaceID.allCases.compactMap { catalog[$0] }
    }

    func registerWindow(_ window: NSWindow, id: WindowSurfaceID) {
        if catalog.isEmpty {
            installBaselineCatalog()
        }
        registeredWindows[id] = WeakWindowBox(window)
        let title = window.title.isEmpty ? "<untitled>" : window.title
        let ownership = catalog[id]?.ownership.rawValue ?? "unknown"
        CrashDiagnostics.record(
            "window-system.register",
            id.rawValue,
            detail: "title=\(title) ownership=\(ownership)"
        )
        attachDiagnostics(to: window, id: id)
        refreshDiagnosticsSnapshot()
    }

    @discardableResult
    func presentRegisteredWindow(_ id: WindowSurfaceID) -> Bool {
        guard let window = window(for: id), let spec = spec(for: id) else {
            CrashDiagnostics.record(
                "window-system.present-missing",
                id.rawValue,
                detail: "registered=\(registeredWindows[id] != nil)"
            )
            return false
        }
        return ManagedWindowRuntime.present(window: window, using: spec)
    }

    @discardableResult
    func dismissRegisteredWindow(_ id: WindowSurfaceID) -> ManagedWindowDismissAction? {
        guard let window = window(for: id), let spec = spec(for: id) else {
            CrashDiagnostics.record(
                "window-system.dismiss-missing",
                id.rawValue,
                detail: "registered=\(registeredWindows[id] != nil)"
            )
            return nil
        }
        return ManagedWindowRuntime.dismiss(window: window, using: spec)
    }

    func unregisterWindow(_ id: WindowSurfaceID) {
        detachDiagnostics(for: id)
        registeredWindows.removeValue(forKey: id)
        CrashDiagnostics.record("window-system.unregister", id.rawValue)
        refreshDiagnosticsSnapshot()
    }

    func window(for id: WindowSurfaceID) -> NSWindow? {
        if let window = registeredWindows[id]?.window {
            return window
        }
        registeredWindows.removeValue(forKey: id)
        return nil
    }

    func isRegistered(_ id: WindowSurfaceID) -> Bool {
        window(for: id) != nil
    }

    func showMainWindow() {
        let controller = ensureMainWindowSurfaceController()
        guard !TestEnvironment.isUnitTestMode else { return }
        controller.showAndFocus()
    }

    func isMainWindowReadyForOpen() -> Bool {
        true
    }

    func isMainWindowVisible() -> Bool {
        mainSurfaceController?.window?.isVisible == true
    }

    @discardableResult
    func presentFloatingPanel(store: ActiveBilingualTranscriptStore) -> NSPanel {
        if let controller = floatingPanelSurfaceController,
           controller.storeForTesting === store,
           let panel = controller.managedWindow as? NSPanel {
            _ = presentRegisteredWindow(.floatingPanel)
            return panel
        }

        dismissFloatingPanel()

        let controller = FloatingPanelControllerV2(store: store)
        floatingPanelSurfaceController = controller
        registerWindow(controller.managedWindow, id: .floatingPanel)
        applyInitialFloatingPanelLayout(using: controller)
        _ = presentRegisteredWindow(.floatingPanel)
        guard let panel = controller.managedWindow as? NSPanel else {
            preconditionFailure("FloatingPanelControllerV2 should own an NSPanel")
        }
        return panel
    }

    func dismissFloatingPanel() {
        guard floatingPanelSurfaceController != nil else { return }
        _ = dismissRegisteredWindow(.floatingPanel)
        unregisterWindow(.floatingPanel)
        floatingPanelSurfaceController = nil
    }

    @discardableResult
    func ensureCaptionMirror(
        store: CaptionStoreV2? = nil,
        screen: NSScreen? = nil,
        onClose: (() -> Void)? = nil
    ) -> CaptionControllerV2 {
        if let captionSurfaceController {
            if let store, captionSurfaceController.storeForTesting !== store {
                dismissCaptionMirror()
                return ensureCaptionMirror(store: store, screen: screen, onClose: onClose)
            }
            if let onClose {
                captionSurfaceController.onClose = onClose
            }
            if let screen {
                captionSurfaceController.moveToScreen(screen)
            }
            return captionSurfaceController
        }

        let resolvedStore = store ?? CaptionStoreV2()
        let controller = CaptionControllerV2(store: resolvedStore, screen: screen, onClose: onClose)
        captionSurfaceController = controller
        registerWindow(controller.managedWindow, id: .captionMirror)
        applyInitialCaptionLayout(using: controller, preferredScreen: screen)
        return controller
    }

    @discardableResult
    func presentCaptionMirror(
        store: CaptionStoreV2? = nil,
        screen: NSScreen? = nil,
        onClose: (() -> Void)? = nil
    ) -> CaptionControllerV2 {
        let controller = ensureCaptionMirror(store: store, screen: screen, onClose: onClose)
        _ = presentRegisteredWindow(.captionMirror)
        return controller
    }

    func dismissCaptionMirror() {
        guard captionSurfaceController != nil else { return }
        captionSurfaceController?.onClose = nil
        _ = dismissRegisteredWindow(.captionMirror)
        unregisterWindow(.captionMirror)
        captionSurfaceController = nil
    }

    @discardableResult
    func presentOperatorPanel(store: OperatorPanelStoreV2) -> OperatorPanelControllerV2 {
        if let controller = operatorPanelSurfaceController,
           controller.storeForTesting === store {
            _ = presentRegisteredWindow(.operatorPanel)
            return controller
        }

        dismissOperatorPanel()

        let controller = OperatorPanelControllerV2(store: store)
        operatorPanelSurfaceController = controller
        registerWindow(controller.managedWindow, id: .operatorPanel)
        applyInitialOperatorPanelLayout(using: controller)
        _ = presentRegisteredWindow(.operatorPanel)
        return controller
    }

    func dismissOperatorPanel() {
        guard operatorPanelSurfaceController != nil else { return }
        _ = dismissRegisteredWindow(.operatorPanel)
        unregisterWindow(.operatorPanel)
        operatorPanelSurfaceController = nil
    }

    func didCloseManagedSurface(_ id: WindowSurfaceID) {
        switch id {
        case .main:
            mainSurfaceController = nil
        case .floatingPanel:
            floatingPanelSurfaceController = nil
        case .captionMirror:
            captionSurfaceController = nil
        case .operatorPanel:
            operatorPanelSurfaceController = nil
        }
        unregisterWindow(id)
    }

    @discardableResult
    func applyFrame(
        _ frame: NSRect,
        to id: WindowSurfaceID,
        display: Bool = true,
        animated: Bool = false,
        reason: String
    ) -> Bool {
        guard let window = window(for: id) else {
            CrashDiagnostics.record(
                "window-system.missing-window",
                id.rawValue,
                detail: "reason=\(reason)"
            )
            return false
        }
        CrashDiagnostics.noteFrameUpdateRequest(
            role: id.role,
            reason: reason,
            currentFrame: window.frame,
            targetFrame: frame,
            animated: animated
        )
        guard !window.frame.equalTo(frame) else { return true }
        let strategy = spec(for: id)?.frameApplyStrategy ?? .setFrame
        switch strategy {
        case .setFrame:
            window.setFrame(frame, display: display, animate: animated)
        case .setFrameOriginPreservingSize:
            if !window.frame.size.equalTo(frame.size) {
                window.setFrame(
                    NSRect(origin: window.frame.origin, size: frame.size),
                    display: display,
                    animate: false
                )
            }
            window.setFrameOrigin(frame.origin)
            if display {
                window.displayIfNeeded()
            }
        }
        return true
    }

    @discardableResult
    func applyLayout(
        for id: WindowSurfaceID,
        input: WindowLayoutInput,
        animated: Bool = false,
        reason: String
    ) -> Bool {
        guard let layout = WindowLayoutEngine.layout(for: id, input: input) else {
            CrashDiagnostics.record(
                "window-system.layout-miss",
                id.rawValue,
                detail: "reason=\(reason)"
            )
            return false
        }
        return applyFrame(
            layout.frame,
            to: id,
            animated: animated,
            reason: reason
        )
    }

    func requestLayoutUpdate(
        for id: WindowSurfaceID,
        input: WindowLayoutInput,
        animated: Bool = false,
        reason: String
    ) {
        if let existing = pendingLayoutUpdates[id] {
            pendingLayoutUpdates[id] = PendingLayoutUpdate(
                input: input,
                animated: existing.animated || animated,
                reason: reason
            )
        } else {
            pendingLayoutUpdates[id] = PendingLayoutUpdate(
                input: input,
                animated: animated,
                reason: reason
            )
        }

        guard scheduledLayoutUpdates.insert(id).inserted else { return }

        DispatchQueue.main.async { [weak self] in
            self?.flushLayoutUpdate(for: id)
        }
    }

    func registrySnapshot() -> [String] {
        if catalog.isEmpty {
            installBaselineCatalog()
        }

        return WindowSurfaceID.allCases.map { id in
            let spec = catalog[id]
            let window = window(for: id)
            let className = window.map { String(describing: type(of: $0)) } ?? "-"
            let title = window?.title.isEmpty == false ? window?.title ?? "-" : "-"
            let frame = window.map { "\($0.frame.debugDescription)" } ?? "-"
            let visible = window?.isVisible ?? false
            let presentAction = spec?.presentation.presentAction.rawValue ?? "-"
            let dismissAction = spec?.presentation.dismissAction.rawValue ?? "-"
            return "surface=\(id.rawValue) role=\(id.role) ownership=\(spec?.ownership.rawValue ?? "-") present=\(presentAction) dismiss=\(dismissAction) registered=\(window != nil) visible=\(visible) class=\(className) title=\(title) frame=\(frame)"
        }
    }

    func diagnosticsSnapshot() -> String {
        let registryLines = registrySnapshot()
        let appKitLines = NSApp.windows
            .sorted { $0.windowNumber < $1.windowNumber }
            .map { describeWindowForDiagnostics($0) }

        let registrySnapshot = registryLines.isEmpty
            ? "No registered window surfaces."
            : registryLines.joined(separator: "\n")
        let appKitSnapshot = appKitLines.isEmpty
            ? "No AppKit windows."
            : appKitLines.joined(separator: "\n")

        return [
            "[Registry]",
            registrySnapshot,
            "",
            "[AppKit]",
            appKitSnapshot,
        ].joined(separator: "\n")
    }

    func refreshDiagnosticsSnapshot() {
        CrashDiagnostics.updateWindowSnapshot(diagnosticsSnapshot())
    }

    func describeWindowForDiagnostics(_ window: NSWindow, role: String? = nil) -> String {
        let identifier = window.identifier?.rawValue ?? "-"
        let title = window.title.isEmpty ? "-" : window.title
        let screenName = window.screen?.localizedName ?? "-"
        let resolvedRole = role ?? diagnosticRole(for: window) ?? "-"
        return "role=\(resolvedRole) class=\(String(describing: type(of: window))) id=\(identifier) title=\(title) frame=\(window.frame.debugDescription) visible=\(window.isVisible) key=\(window.isKeyWindow) main=\(window.isMainWindow) mini=\(window.isMiniaturized) screen=\(screenName)"
    }

    func resetForTesting() {
        OverlaySessionCoordinatorV2.shared.resetForTesting()
        mainSurfaceController?.window?.orderOut(nil)
        floatingPanelSurfaceController?.window?.orderOut(nil)
        captionSurfaceController?.window?.orderOut(nil)
        operatorPanelSurfaceController?.window?.orderOut(nil)
        dismissFloatingPanel()
        dismissCaptionMirror()
        dismissOperatorPanel()
        mainSurfaceController = nil
        floatingPanelSurfaceController = nil
        captionSurfaceController = nil
        operatorPanelSurfaceController = nil
        catalog.removeAll()
        detachAllDiagnostics()
        registeredWindows.removeAll()
        pendingLayoutUpdates.removeAll()
        scheduledLayoutUpdates.removeAll()
        refreshDiagnosticsSnapshot()
    }

    var mainWindowControllerForTesting: MainWindowControllerV2? {
        mainSurfaceController
    }

    var floatingPanelForTesting: NSPanel? {
        floatingPanelSurfaceController?.managedWindow as? NSPanel
    }

    var captionControllerForTesting: CaptionControllerV2? {
        captionSurfaceController
    }

    var operatorPanelControllerForTesting: OperatorPanelControllerV2? {
        operatorPanelSurfaceController
    }

    private func flushLayoutUpdate(for id: WindowSurfaceID) {
        scheduledLayoutUpdates.remove(id)
        guard let pending = pendingLayoutUpdates.removeValue(forKey: id) else { return }
        _ = applyLayout(
            for: id,
            input: pending.input,
            animated: pending.animated,
            reason: pending.reason
        )
    }

    @discardableResult
    private func ensureMainWindowSurfaceController() -> MainWindowControllerV2 {
        if let mainSurfaceController {
            return mainSurfaceController
        }
        let controller = MainWindowControllerV2()
        mainSurfaceController = controller
        registerWindow(controller.managedWindow, id: .main)
        guard !TestEnvironment.isUnitTestMode else {
            return controller
        }
        let profile = DisplayProfileResolverV2.resolveProfile(from: controller.window?.screen)
        let snapshot = WindowLayoutEngineV2.mainWindowSnapshot(
            for: WindowLayoutRequestV2(
                surfaceID: .main,
                display: profile,
                systemState: .default,
                currentFrame: controller.managedWindow.frame
            )
        )
        applyV2LayoutSnapshot(snapshot, reason: "window.main.initial")
        return controller
    }

    private func applyInitialFloatingPanelLayout(using controller: FloatingPanelControllerV2) {
        let profile = DisplayProfileResolverV2.resolveProfile(from: controller.managedWindow.screen)
        let snapshot = WindowLayoutEngineV2.floatingPanelSnapshot(
            for: WindowLayoutRequestV2(
                surfaceID: .floatingPanel,
                display: profile,
                systemState: .default,
                currentFrame: controller.managedWindow.frame,
                savedFrame: FloatingPanelControllerV2.loadSavedFrame()
            )
        )
        applyV2LayoutSnapshot(snapshot, reason: "window.floating-panel.initial")
    }

    private func applyInitialCaptionLayout(using controller: CaptionControllerV2, preferredScreen: NSScreen?) {
        let profile = DisplayProfileResolverV2.resolveProfile(from: preferredScreen ?? controller.managedWindow.screen)
        let snapshot = WindowLayoutEngineV2.captionWindowSnapshot(
            for: WindowLayoutRequestV2(
                surfaceID: .captionMirror,
                display: profile,
                systemState: .default,
                currentFrame: controller.managedWindow.frame
            )
        )
        applyV2LayoutSnapshot(snapshot, reason: "window.caption.initial")
    }

    private func applyInitialOperatorPanelLayout(using controller: OperatorPanelControllerV2) {
        let profile = DisplayProfileResolverV2.resolveProfile(from: controller.managedWindow.screen)
        let snapshot = WindowLayoutEngineV2.operatorPanelSnapshot(
            for: WindowLayoutRequestV2(
                surfaceID: .operatorPanel,
                display: profile,
                systemState: .default,
                currentFrame: controller.managedWindow.frame
            )
        )
        applyV2LayoutSnapshot(snapshot, reason: "window.operator-panel.initial")
    }

    @discardableResult
    private func applyV2LayoutSnapshot(
        _ snapshot: WindowLayoutSnapshotV2,
        reason: String
    ) -> Bool {
        applyFrame(snapshot.outerFrame, to: snapshot.surfaceID, animated: false, reason: reason)
    }

    private func diagnosticRole(for window: NSWindow) -> String? {
        let objectID = ObjectIdentifier(window)
        return diagnosticAttachments.first(where: { $0.value.windowID == objectID })?.key.role
    }

    private func attachDiagnostics(to window: NSWindow, id: WindowSurfaceID) {
        let objectID = ObjectIdentifier(window)
        if diagnosticAttachments[id]?.windowID == objectID {
            return
        }

        detachDiagnostics(for: id)

        CrashDiagnostics.record(
            "window.attach",
            id.role,
            detail: describeWindowForDiagnostics(window, role: id.role)
        )

        let tokens = diagnosticObserverSpecs().map { spec in
            NotificationCenter.default.addObserver(
                forName: spec.name,
                object: window,
                queue: .main
            ) { [weak self, weak window] _ in
                guard let self, let window else { return }
                Task { @MainActor in
                    self.handleDiagnosticNotification(spec, window: window, id: id)
                }
            }
        }

        diagnosticAttachments[id] = DiagnosticAttachment(windowID: objectID, tokens: tokens)
    }

    private func detachDiagnostics(for id: WindowSurfaceID) {
        guard let attachment = diagnosticAttachments.removeValue(forKey: id) else { return }
        for token in attachment.tokens {
            NotificationCenter.default.removeObserver(token)
        }
    }

    private func detachAllDiagnostics() {
        for attachment in diagnosticAttachments.values {
            for token in attachment.tokens {
                NotificationCenter.default.removeObserver(token)
            }
        }
        diagnosticAttachments.removeAll()
    }

    private func handleDiagnosticNotification(
        _ spec: DiagnosticObserverSpec,
        window: NSWindow,
        id: WindowSurfaceID
    ) {
        CrashDiagnostics.record(
            "window.\(spec.label)",
            id.role,
            detail: describeWindowForDiagnostics(window, role: id.role)
        )
        if spec.name == NSWindow.willCloseNotification {
            detachDiagnostics(for: id)
        }
        refreshDiagnosticsSnapshot()
    }

    private func diagnosticObserverSpecs() -> [DiagnosticObserverSpec] {
        [
            DiagnosticObserverSpec(name: NSWindow.didResizeNotification, label: "didResize"),
            DiagnosticObserverSpec(name: NSWindow.didMoveNotification, label: "didMove"),
            DiagnosticObserverSpec(name: NSWindow.didBecomeKeyNotification, label: "didBecomeKey"),
            DiagnosticObserverSpec(name: NSWindow.didResignKeyNotification, label: "didResignKey"),
            DiagnosticObserverSpec(name: NSWindow.didBecomeMainNotification, label: "didBecomeMain"),
            DiagnosticObserverSpec(name: NSWindow.didResignMainNotification, label: "didResignMain"),
            DiagnosticObserverSpec(name: NSWindow.willStartLiveResizeNotification, label: "willStartLiveResize"),
            DiagnosticObserverSpec(name: NSWindow.didEndLiveResizeNotification, label: "didEndLiveResize"),
            DiagnosticObserverSpec(name: NSWindow.didMiniaturizeNotification, label: "didMiniaturize"),
            DiagnosticObserverSpec(name: NSWindow.didDeminiaturizeNotification, label: "didDeminiaturize"),
            DiagnosticObserverSpec(name: NSWindow.didChangeScreenNotification, label: "didChangeScreen"),
            DiagnosticObserverSpec(name: NSWindow.willCloseNotification, label: "willClose"),
        ]
    }
}
