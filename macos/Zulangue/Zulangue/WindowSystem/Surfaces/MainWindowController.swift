import AppKit
import SwiftUI

@MainActor
final class MainWindowController: NSWindowController, ManagedWindowController {
    private var hostingController: NSHostingController<AnyView>?

    var windowSurfaceID: WindowSurfaceID { .main }
    var managedWindow: NSWindow {
        guard let window else { preconditionFailure("MainWindowController.window missing") }
        return window
    }

    init() {
        let spec = WindowSpec.required(.main)
        let window = NSWindow(
            contentRect: spec.initialContentRect,
            styleMask: spec.styleMask,
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier(WindowSurfaceID.main.rawValue)
        window.title = "Zulangue"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        configureManagedWindow()
        if !TestEnvironment.isUnitTestMode {
            WindowChromeConfigurator.shared.configure(managedWindow)
        }
        installRootView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func installRootView() {
        if TestEnvironment.isUnitTestMode {
            managedWindow.contentViewController = NSViewController()
            hostingController = nil
            return
        }
        let controller = WindowHosting.makeController(
            rootView: AnyView(rootView),
            policy: managedWindowSpec.hostingPolicy
        )
        managedWindow.contentViewController = controller
        _ = WindowHosting.stabilizeWindowTree(on: managedWindow)
        hostingController = controller
    }

    func showAndFocus() {
        if managedWindow.isMiniaturized {
            managedWindow.deminiaturize(nil)
        }
        if !managedWindow.isVisible {
            showWindow(nil)
        }
        managedWindow.makeKeyAndOrderFront(nil)
        if !TestEnvironment.isUnitTestMode {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private var rootView: some View {
        if TestEnvironment.isUnitTestMode {
            return AnyView(
                Text("MainWindow test host")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            )
        }
        return AnyView(
            MainShellView(store: MainNavigationStore.shared)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.bgRoot)
        )
    }
}
