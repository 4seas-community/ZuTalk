import AppKit

/// Action selector invoked from the menu-bar popover rows. Each row sets
/// `NSMenuItem.representedObject = "<action>"` and dispatches through
/// `NSApp.sendMenuBarAction(_:)`.
@MainActor
extension NSApplication {
    @objc func sendMenuBarAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? String else { return }
        switch action {
        case "subtitles":
            WindowCommandRouter.shared.requestToggleSubtitleOverlay()
        case "recording":
            WindowCommandRouter.shared.openMainWindow(detail: "menu-bar.popover.open-capture-notebook") {
                MainNavigationStoreV2.shared.openActiveNotebookForCapture()
            }
        case "settings":
            WindowCommandRouter.shared.requestOpenSettings()
        case "checkForUpdates":
            SoftwareUpdateController.shared.checkForUpdates()
        default:
            break
        }
    }
}
