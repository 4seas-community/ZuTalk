import AppKit
import Sparkle

/// Owns the single Sparkle updater used by the app menu and menu-bar popover.
///
/// Sparkle starts only in a real app process. Unit and UI tests can exercise
/// routing without contacting the public appcast or changing updater defaults.
@MainActor
final class SoftwareUpdateController {
    static let shared = SoftwareUpdateController()

    private let updaterController: SPUStandardUpdaterController
    private var testCheckAction: (() -> Void)?
    private let isConfigured: Bool

    var isAvailable: Bool { isConfigured }

    var automaticallyChecksForUpdates: Bool {
        isConfigured && updaterController.updater.automaticallyChecksForUpdates
    }

    private init() {
        isConfigured = Self.hasReleaseConfiguration
        updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        if isConfigured && !TestEnvironment.isAnyTestMode {
            updaterController.startUpdater()
        }
    }

    func checkForUpdates() {
        if let testCheckAction {
            testCheckAction()
            return
        }
        guard isConfigured else {
            let alert = NSAlert()
            alert.messageText = String(localized: "updates.unavailable.title")
            alert.informativeText = String(localized: "updates.unavailable.message")
            alert.alertStyle = .informational
            alert.addButton(withTitle: String(localized: "updates.unavailable.dismiss"))
            alert.runModal()
            return
        }
        updaterController.checkForUpdates(nil)
    }

    func installTestCheckAction(_ action: (() -> Void)?) {
        guard TestEnvironment.isAnyTestMode else { return }
        testCheckAction = action
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        guard isConfigured else { return }
        updaterController.updater.automaticallyChecksForUpdates = enabled
    }

    private static var hasReleaseConfiguration: Bool {
        guard
            let feedURL = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
            let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        else {
            return false
        }
        return feedURL.hasPrefix("https://")
            && !publicKey.isEmpty
            && !publicKey.contains("$(")
    }
}
