import AppKit
import SwiftUI

@MainActor
final class MainWindowController: NSWindowController, ManagedWindowController {
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

    /// Installs the shell as the window's content view rather than as a content
    /// view controller.
    ///
    /// `NSWindow.contentViewController` hands window sizing to AppKit, which
    /// resizes the window to fit the controller on assignment and again when the
    /// window is first shown — the spec's frame is applied in between and then
    /// overwritten. The subtitle overlay never had this problem because it pins
    /// a content view instead, so the main window now does the same.
    func installRootView() {
        if TestEnvironment.isUnitTestMode {
            managedWindow.contentViewController = NSViewController()
            return
        }
        let hostingView = WindowHosting.makeView(
            rootView: AnyView(rootView),
            policy: managedWindowSpec.hostingPolicy
        )
        WindowHosting.installPinnedView(hostingView, into: managedWindow)
        _ = WindowHosting.stabilizeWindowTree(on: managedWindow)
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
