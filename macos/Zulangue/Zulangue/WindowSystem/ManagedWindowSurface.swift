import AppKit

@MainActor
protocol ManagedWindowController: AnyObject {
    var windowSurfaceID: WindowSurfaceID { get }
    var managedWindow: NSWindow { get }
    var managedWindowSpec: WindowSpec { get }
}

typealias ManagedWindowSurface = ManagedWindowController

enum ManagedWindowRuntime {
    static func apply(spec: WindowSpec, to window: NSWindow) {
        window.collectionBehavior = spec.chrome.collectionBehavior
        window.hasShadow = spec.chrome.hasShadow
        window.isOpaque = spec.chrome.isOpaque
        window.titleVisibility = spec.chrome.titleVisibility
        window.titlebarAppearsTransparent = spec.chrome.titlebarAppearsTransparent
        window.animationBehavior = spec.chrome.animationBehavior

        if let minimumWindowSize = spec.chrome.minimumWindowSize {
            window.minSize = minimumWindowSize
        }
        if let minimumContentSize = spec.chrome.minimumContentSize {
            window.contentMinSize = minimumContentSize
        }
        if let maximumContentSize = spec.chrome.maximumContentSize {
            window.contentMaxSize = maximumContentSize
        }
        if let isMovable = spec.chrome.isMovable {
            window.isMovable = isMovable
        }
        if let isMovableByWindowBackground = spec.chrome.isMovableByWindowBackground {
            window.isMovableByWindowBackground = isMovableByWindowBackground
        }
        if let ignoresMouseEvents = spec.chrome.ignoresMouseEvents {
            window.ignoresMouseEvents = ignoresMouseEvents
        }

        switch spec.chrome.backgroundStyle {
        case .systemDefault:
            break
        case .clear:
            window.backgroundColor = .clear
        }

        if let panel = window as? NSPanel {
            panel.isFloatingPanel = spec.chrome.isFloatingPanel
            if let hidesOnDeactivate = spec.chrome.hidesOnDeactivate {
                panel.hidesOnDeactivate = hidesOnDeactivate
            }
        }

        // AppKit resets an NSPanel's level when toggling floating-panel state.
        if let level = spec.chrome.level {
            window.level = level
        }
    }

    @discardableResult
    static func present(window: NSWindow, using spec: WindowSpec) -> Bool {
        switch spec.presentation.presentAction {
        case .showAndFocus:
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            if let controller = window.windowController, !window.isVisible {
                controller.showWindow(nil)
            }
            window.makeKeyAndOrderFront(nil)
        case .orderFrontRegardless:
            window.orderFrontRegardless()
        case .showWindowAndOrderFront:
            if let controller = window.windowController {
                controller.showWindow(nil)
            }
            window.orderFrontRegardless()
        case .showWindowAndMakeKey:
            if let controller = window.windowController {
                controller.showWindow(nil)
            }
            window.makeKeyAndOrderFront(nil)
        }

        if spec.presentation.activatesApp {
            NSApp.activate(ignoringOtherApps: true)
        }
        return true
    }

    static func dismiss(window: NSWindow, using spec: WindowSpec) -> ManagedWindowDismissAction {
        switch spec.presentation.dismissAction {
        case .orderOut:
            window.orderOut(nil)
            return .orderOut
        case .close:
            if let controller = window.windowController {
                controller.close()
            } else {
                window.close()
            }
            return .close
        }
    }
}

extension ManagedWindowController {
    var managedWindowSpec: WindowSpec {
        WindowSpec.required(windowSurfaceID)
    }

    func configureManagedWindow() {
        ManagedWindowRuntime.apply(spec: managedWindowSpec, to: managedWindow)
    }

    func installManagedWindow() {
        configureManagedWindow()
        registerWithWindowSystem()
    }

    func registerWithWindowSystem() {
        WindowCoordinator.shared.registerWindow(managedWindow, id: windowSurfaceID)
    }

    @discardableResult
    func applyManagedFrame(
        _ frame: NSRect,
        animated: Bool = false,
        reason: String
    ) -> Bool {
        WindowCoordinator.shared.applyFrame(
            frame,
            to: windowSurfaceID,
            animated: animated,
            reason: reason
        )
    }

    @discardableResult
    func applyManagedFrame(
        _ result: WindowLayoutResult,
        animated: Bool = false,
        reason: String
    ) -> Bool {
        applyManagedFrame(result.frame, animated: animated, reason: reason)
    }

    @discardableResult
    func applyManagedLayout(
        _ input: WindowLayoutInput,
        animated: Bool = false,
        reason: String
    ) -> Bool {
        WindowCoordinator.shared.applyLayout(
            for: windowSurfaceID,
            input: input,
            animated: animated,
            reason: reason
        )
    }

    @discardableResult
    func stabilizeManagedHostingTree(detail: String? = nil) -> HostingSizingStabilizationResult {
        let result = WindowHosting.stabilizeWindowTree(on: managedWindow)
        CrashDiagnostics.noteHostingSizingStabilized(
            role: windowSurfaceID.role,
            controllersDisabled: result.controllersDisabled,
            viewsDisabled: result.viewsDisabled,
            detail: detail ?? WindowCoordinator.shared.describeWindowForDiagnostics(
                managedWindow,
                role: windowSurfaceID.role
            )
        )
        return result
    }

    @discardableResult
    func presentManagedWindow() -> Bool {
        WindowCoordinator.shared.presentRegisteredWindow(windowSurfaceID)
    }

    @discardableResult
    func dismissManagedWindow() -> ManagedWindowDismissAction? {
        WindowCoordinator.shared.dismissRegisteredWindow(windowSurfaceID)
    }
}
