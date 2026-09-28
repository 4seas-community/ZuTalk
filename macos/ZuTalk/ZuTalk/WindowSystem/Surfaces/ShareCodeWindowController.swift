import AppKit
import SwiftUI

/// 放大的共享二维码。会场里把它拖到投影屏上,或者把笔记本转过去给前排的人扫。
@MainActor
final class ShareCodeWindowController: NSWindowController, ManagedWindowController, NSWindowDelegate {
    var windowSurfaceID: WindowSurfaceID { .shareCode }
    var managedWindow: NSWindow {
        guard let window else { preconditionFailure("ShareCodeWindowController.window missing") }
        return window
    }

    init() {
        let spec = WindowSpec.required(.shareCode)
        let window = NSWindow(
            contentRect: spec.initialContentRect,
            styleMask: spec.styleMask,
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier(WindowSurfaceID.shareCode.rawValue)
        window.title = String(localized: "share.link.large_window_title")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        configureManagedWindow()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(url: String, title: String) {
        guard !TestEnvironment.isUnitTestMode else { return }
        let hostingView = WindowHosting.makeView(
            rootView: LargeShareQRView(url: url, title: title),
            policy: managedWindowSpec.hostingPolicy
        )
        WindowHosting.installPinnedView(hostingView, into: managedWindow)
    }

    func windowWillClose(_ notification: Notification) {
        WindowCoordinator.shared.didCloseManagedSurface(.shareCode)
    }
}
