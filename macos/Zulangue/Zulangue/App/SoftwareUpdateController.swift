import AppKit
import Combine
import Sparkle

/// Owns the single Sparkle updater used by the app menu and menu-bar popover.
///
/// Sparkle starts only in a real app process. Unit and UI tests can exercise
/// routing without contacting the public appcast or changing updater defaults.
///
/// Transient network failures (an interrupted download or an unreachable
/// appcast) are retried automatically a few times before the user has to act,
/// because the public release CDN is unreliable from some networks.
@MainActor
final class SoftwareUpdateController: NSObject, ObservableObject {
    static let shared = SoftwareUpdateController()

    static let maximumNetworkRetries = 2
    private static let retryDelaySeconds: TimeInterval = 6

    private var updaterController: SPUStandardUpdaterController!
    private var testCheckAction: (() -> Void)?
    private var isConfigured = false
    private var retriesRemaining = SoftwareUpdateController.maximumNetworkRetries
    private var immediateInstallHandler: (() -> Void)?

    /// Becomes true only after Sparkle has downloaded and prepared a signed
    /// update. The sidebar observes this instead of showing a permanent help
    /// action or an update action that may have nothing to install.
    @Published private(set) var isUpdateReadyToInstall = false

    var isAvailable: Bool { isConfigured }

    var automaticallyChecksForUpdates: Bool {
        isConfigured && updaterController.updater.automaticallyChecksForUpdates
    }

    override private init() {
        super.init()
        isConfigured = Self.hasReleaseConfiguration
        updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,
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
        retriesRemaining = Self.maximumNetworkRetries
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

    func installUpdateAndRelaunch() {
        guard let immediateInstallHandler else { return }
        immediateInstallHandler()
    }

    private func prepareImmediateInstallation(_ handler: @escaping () -> Void) {
        immediateInstallHandler = handler
        isUpdateReadyToInstall = true
    }

    /// Whether an aborted update cycle failed on the network rather than on
    /// policy, signatures, or the user cancelling, and is worth retrying.
    static func isTransientNetworkFailure(_ error: NSError) -> Bool {
        guard error.domain == SUSparkleErrorDomain else { return false }
        let retryableCodes = [
            Int(SUError.downloadError.rawValue),
            Int(SUError.appcastError.rawValue),
        ]
        guard retryableCodes.contains(error.code) else { return false }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError,
            underlying.domain == NSURLErrorDomain,
            underlying.code == NSURLErrorCancelled
        {
            return false
        }
        return true
    }

    private func handleAbort(_ error: NSError) {
        guard isConfigured, !TestEnvironment.isAnyTestMode else { return }
        guard Self.isTransientNetworkFailure(error), retriesRemaining > 0 else { return }
        retriesRemaining -= 1
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.retryDelaySeconds) { [weak self] in
            guard let self, self.isConfigured else { return }
            self.updaterController.checkForUpdates(nil)
        }
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

extension SoftwareUpdateController: SPUUpdaterDelegate {
    nonisolated func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        Task { @MainActor in
            self.prepareImmediateInstallation(immediateInstallHandler)
        }
        return true
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let nsError = error as NSError
        Task { @MainActor in
            self.handleAbort(nsError)
        }
    }

    nonisolated func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: Error?
    ) {
        guard error == nil else { return }
        Task { @MainActor in
            self.retriesRemaining = Self.maximumNetworkRetries
        }
    }
}
