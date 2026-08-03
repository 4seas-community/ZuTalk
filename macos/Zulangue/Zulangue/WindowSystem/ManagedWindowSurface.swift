import AppKit

/// Presentation side of the window catalog.
///
/// `apply` lives on `ManagedWindowRuntimeV2`, which both window controllers
/// call through `ManagedWindowControllerV2.configureManagedWindow()`. Only the
/// present/dismiss half is still routed through the coordinator, so only that
/// half lives here.
enum ManagedWindowRuntime {
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
