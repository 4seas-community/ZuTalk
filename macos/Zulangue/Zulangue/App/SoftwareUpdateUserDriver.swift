import AppKit
import Sparkle

/// What the app is currently doing about a newer version.
///
/// Only the update the app fetched on its own reaches these cases. A check the
/// user started from the menu keeps Sparkle's own windows, because there the
/// user asked to be told about every outcome — including "you are up to date".
enum SoftwareUpdateActivity: Equatable {
    case idle
    /// Downloading the new version. `fraction` stays nil until the server
    /// reports a content length; some CDNs omit it on the first response.
    case downloading(fraction: Double?)
    /// Unpacking the download, or handing it to the installer after the user
    /// asked to relaunch. Both are short and have no useful percentage.
    case preparing
    /// Downloaded, signature-verified, staged. Waiting for a relaunch.
    case readyToRelaunch
}

/// Sparkle user driver that keeps background updates silent but observable.
///
/// Sparkle's own silent path (`SUAutomaticallyUpdate`) downloads through
/// `SPUAutomaticUpdateDriver`, which never reports download bytes to a user
/// driver — an app using it can only say "nothing" and then "restart now".
/// To show real progress the app has to take the scheduled UI-driven path and
/// answer Sparkle's prompts itself: accept the update without asking, publish
/// the byte counts as `activity`, and then sit on the install reply until the
/// user actually clicks relaunch. Sparkle keeps the staged installer alive
/// while that reply is outstanding, so an update the user ignores still
/// installs when they quit.
///
/// Checks the user starts themselves are forwarded to `SPUStandardUserDriver`
/// untouched.
@MainActor
final class SoftwareUpdateUserDriver: NSObject, SPUUserDriver {

    /// Who owns the current update session's presentation.
    ///
    /// Sparkle calls `showUserInitiatedUpdateCheckWithCancellation:` only from
    /// its user-initiated driver, so silence is the safe default: a scheduled
    /// check that finds nothing, or fails on the network, must not open an
    /// alert the user never asked for.
    private enum Presentation {
        case silent
        case standard
    }

    private let standardDriver: SPUStandardUserDriver
    private var presentation: Presentation = .silent
    private var expectedContentLength: UInt64 = 0
    private var receivedContentLength: UInt64 = 0

    /// Held while the sidebar offers "relaunch". Answering it with `.install`
    /// installs immediately; never answering leaves Sparkle to install on quit.
    private var relaunchReply: ((SPUUserUpdateChoice) -> Void)?

    /// Called on the main actor whenever `activity` changes to a new value.
    var activityDidChange: ((SoftwareUpdateActivity) -> Void)?

    /// Called when the user asks to see an update that is already in flight,
    /// so the window carrying the progress row can be brought forward.
    var revealInFlightUpdate: (() -> Void)?

    private(set) var activity: SoftwareUpdateActivity = .idle {
        didSet {
            guard activity != oldValue else { return }
            activityDidChange?(activity)
        }
    }

    var isReadyToRelaunch: Bool { relaunchReply != nil }

    init(hostBundle: Bundle) {
        standardDriver = SPUStandardUserDriver(hostBundle: hostBundle, delegate: nil)
        super.init()
    }

    /// Drop a download or extraction that is no longer running, so the sidebar
    /// cannot be left with a progress bar that never moves. An update already
    /// staged and waiting on the user is left alone.
    func resetActivityIfInFlight() {
        guard relaunchReply == nil else { return }
        expectedContentLength = 0
        receivedContentLength = 0
        activity = .idle
    }

    /// Install the staged update and relaunch. No-op unless an update is
    /// actually waiting, so a stale click cannot quit the app.
    func installStagedUpdateAndRelaunch() {
        guard let relaunchReply else { return }
        self.relaunchReply = nil
        activity = .preparing
        relaunchReply(.install)
    }

    /// Fraction of the download that has arrived, or nil when the size is
    /// unknown. Clamped, because Sparkle may report a content length that
    /// disagrees with the bytes actually delivered.
    private var downloadFraction: Double? {
        guard expectedContentLength > 0 else { return nil }
        let fraction = Double(receivedContentLength) / Double(expectedContentLength)
        return min(max(fraction, 0), 1)
    }

    /// Mirrors `SPUAutomaticUpdateDriver`'s rule for updates that must not be
    /// fetched behind the user's back: an information-only release has nothing
    /// to install, a major upgrade may be a separate purchase, and a feed that
    /// failed signature validation must be shown, not acted on.
    private static func requiresUserAttention(_ item: SUAppcastItem) -> Bool {
        item.isInformationOnlyUpdate
            || item.isMajorUpgrade
            || item.signingValidationStatus == .failed
    }

    // MARK: - SPUUserDriver

    func show(
        _ request: SPUUpdatePermissionRequest,
        reply: @escaping (SUUpdatePermissionResponse) -> Void
    ) {
        standardDriver.show(request, reply: reply)
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        presentation = .standard
        standardDriver.showUserInitiatedUpdateCheck(cancellation: cancellation)
    }

    func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        // Authoritative for this session. Sparkle only calls
        // `dismissUpdateInstallation` when it shows an error, so the flag from
        // a previous session cannot be trusted to have been cleared.
        presentation = state.userInitiated ? .standard : .silent
        guard presentation == .silent else {
            standardDriver.showUpdateFound(with: appcastItem, state: state, reply: reply)
            return
        }

        guard !Self.requiresUserAttention(appcastItem) else {
            // Leave it for the next check the user starts themselves, which
            // gets Sparkle's full window with release notes and a real choice.
            reply(.dismiss)
            return
        }

        switch state.stage {
        case .installing:
            // A previous session already staged this update. Answering
            // `.install` here quits and relaunches immediately, so hold the
            // reply and let the sidebar decide when.
            relaunchReply = reply
            activity = .readyToRelaunch
        default:
            expectedContentLength = 0
            receivedContentLength = 0
            activity = .downloading(fraction: nil)
            reply(.install)
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        guard presentation == .standard else { return }
        standardDriver.showUpdateReleaseNotes(with: downloadData)
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {
        guard presentation == .standard else { return }
        standardDriver.showUpdateReleaseNotesFailedToDownloadWithError(error)
    }

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        guard presentation == .standard else {
            acknowledgement()
            return
        }
        standardDriver.showUpdateNotFoundWithError(error, acknowledgement: acknowledgement)
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        guard presentation == .standard else {
            // A background update that fails is not the user's problem to
            // solve. The row goes back to nothing and the next trigger retries.
            activity = .idle
            acknowledgement()
            return
        }
        standardDriver.showUpdaterError(error, acknowledgement: acknowledgement)
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        guard presentation == .silent else {
            standardDriver.showDownloadInitiated(cancellation: cancellation)
            return
        }
        expectedContentLength = 0
        receivedContentLength = 0
        activity = .downloading(fraction: nil)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        guard presentation == .silent else {
            standardDriver.showDownloadDidReceiveExpectedContentLength(expectedContentLength)
            return
        }
        // Sparkle may report the length more than once for one download.
        self.expectedContentLength = expectedContentLength
        receivedContentLength = 0
        activity = .downloading(fraction: downloadFraction)
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        guard presentation == .silent else {
            standardDriver.showDownloadDidReceiveData(ofLength: length)
            return
        }
        receivedContentLength += length
        activity = .downloading(fraction: downloadFraction)
    }

    func showDownloadDidStartExtractingUpdate() {
        guard presentation == .silent else {
            standardDriver.showDownloadDidStartExtractingUpdate()
            return
        }
        activity = .preparing
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        guard presentation == .silent else {
            standardDriver.showExtractionReceivedProgress(progress)
            return
        }
        activity = .preparing
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard presentation == .silent else {
            standardDriver.showReady(toInstallAndRelaunch: reply)
            return
        }
        relaunchReply = reply
        activity = .readyToRelaunch
    }

    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    ) {
        guard presentation == .silent else {
            standardDriver.showInstallingUpdate(
                withApplicationTerminated: applicationTerminated,
                retryTerminatingApplication: retryTerminatingApplication
            )
            return
        }
        activity = .preparing
    }

    func showUpdateInstalledAndRelaunched(
        _ relaunched: Bool,
        acknowledgement: @escaping () -> Void
    ) {
        guard presentation == .standard else {
            acknowledgement()
            return
        }
        standardDriver.showUpdateInstalledAndRelaunched(relaunched, acknowledgement: acknowledgement)
    }

    func showUpdateInFocus() {
        guard presentation == .silent else {
            standardDriver.showUpdateInFocus()
            return
        }
        // The progress row lives in the main window's sidebar.
        revealInFlightUpdate?()
    }

    func dismissUpdateInstallation() {
        if presentation == .standard {
            standardDriver.dismissUpdateInstallation()
        }
        presentation = .silent
        relaunchReply = nil
        expectedContentLength = 0
        receivedContentLength = 0
        activity = .idle
    }
}
