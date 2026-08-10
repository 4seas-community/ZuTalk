import AppKit

/// Application-level quit routing shared by explicit UI controls and tests.
///
/// Always request termination through AppKit. The app delegate then drains an
/// active recording, persists the remaining audio, flushes open editors, and
/// shuts down the Rust core before termination completes.
@MainActor
protocol ApplicationQuitRequesting: AnyObject {
    func requestApplicationQuit()
}

extension NSApplication: ApplicationQuitRequesting {
    func requestApplicationQuit() {
        terminate(nil)
    }
}

enum ApplicationQuitAction {
    @MainActor
    static func perform(on application: ApplicationQuitRequesting) {
        application.requestApplicationQuit()
    }
}

enum ApplicationQuitConfirmationPolicy {
    static func requiresConfirmation(for captureState: NotebookCaptureState?) -> Bool {
        captureState == .recording || captureState == .paused
    }
}

/// Presents the recording guard for every application-level quit route:
/// the menu-bar button, Command-Q, the Dock, and the system application menu.
///
/// Cancel is the default button so Return cannot accidentally stop an
/// in-flight recording.
@MainActor
enum ApplicationQuitConfirmationAlert {
    static func confirmActiveRecordingQuit() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "app.quit.confirm.title")
        alert.informativeText = String(localized: "app.quit.confirm.message")
        alert.addButton(withTitle: String(localized: "app.quit.confirm.cancel"))
        let quitButton = alert.addButton(
            withTitle: String(localized: "app.quit.confirm.action")
        )
        quitButton.hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn
    }
}
