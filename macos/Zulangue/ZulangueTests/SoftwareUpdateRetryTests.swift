// SoftwareUpdateRetryTests.swift
//
// Coverage for the two decisions that keep background updating silent: which
// aborted Sparkle cycles are worth retrying (only genuine network failures —
// signature, policy, and user-cancelled aborts must not), and when a wake or a
// reconnect is allowed to start another check against the release CDN.

import Sparkle
import XCTest

@testable import Zulangue

@MainActor
final class SoftwareUpdateRetryTests: XCTestCase {

    private func sparkleError(_ code: SUError, underlying: NSError? = nil) -> NSError {
        var userInfo: [String: Any] = [:]
        if let underlying {
            userInfo[NSUnderlyingErrorKey] = underlying
        }
        return NSError(
            domain: SUSparkleErrorDomain,
            code: Int(code.rawValue),
            userInfo: userInfo
        )
    }

    func testInterruptedDownloadAndUnreachableAppcastAreRetryable() {
        XCTAssertTrue(
            SoftwareUpdateController.isTransientNetworkFailure(
                sparkleError(
                    .downloadError,
                    underlying: NSError(
                        domain: NSURLErrorDomain,
                        code: NSURLErrorNetworkConnectionLost
                    )
                )
            )
        )
        XCTAssertTrue(
            SoftwareUpdateController.isTransientNetworkFailure(sparkleError(.appcastError))
        )
    }

    func testUserCancelledDownloadIsNotRetryable() {
        XCTAssertFalse(
            SoftwareUpdateController.isTransientNetworkFailure(
                sparkleError(
                    .downloadError,
                    underlying: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
                )
            )
        )
    }

    func testNonNetworkAbortsAreNotRetryable() {
        XCTAssertFalse(
            SoftwareUpdateController.isTransientNetworkFailure(
                sparkleError(.signatureError)
            )
        )
        XCTAssertFalse(
            SoftwareUpdateController.isTransientNetworkFailure(
                sparkleError(.noUpdateError)
            )
        )
        XCTAssertFalse(
            SoftwareUpdateController.isTransientNetworkFailure(
                NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
            )
        )
    }

    // MARK: - Background check throttling

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func shouldCheck(
        automatic: Bool = true,
        sessionInProgress: Bool = false,
        lastCheckFailedOnNetwork: Bool = false,
        secondsSinceLastCheck: TimeInterval?
    ) -> Bool {
        SoftwareUpdateController.shouldStartBackgroundCheck(
            automaticChecksEnabled: automatic,
            sessionInProgress: sessionInProgress,
            lastCheckDate: secondsSinceLastCheck.map { now.addingTimeInterval(-$0) },
            lastCheckFailedOnNetwork: lastCheckFailedOnNetwork,
            now: now
        )
    }

    func testFirstCheckOfAnInstallIsAllowed() {
        XCTAssertTrue(shouldCheck(secondsSinceLastCheck: nil))
    }

    /// Waking a laptop a dozen times an hour, or a Wi-Fi connection that keeps
    /// dropping, must not turn into a dozen requests against the release CDN.
    func testChecksWithinTheFloorAreDropped() {
        let floor = SoftwareUpdateController.backgroundCheckFloorSeconds
        XCTAssertFalse(shouldCheck(secondsSinceLastCheck: 0))
        XCTAssertFalse(shouldCheck(secondsSinceLastCheck: floor - 1))
        XCTAssertTrue(shouldCheck(secondsSinceLastCheck: floor))
        XCTAssertTrue(shouldCheck(secondsSinceLastCheck: floor * 4))
    }

    /// A running session already covers everything a new check would do,
    /// including an update that is downloaded and waiting on a relaunch.
    func testRunningSessionBlocksAnotherCheck() {
        XCTAssertFalse(
            shouldCheck(sessionInProgress: true, secondsSinceLastCheck: nil)
        )
    }

    /// Sparkle stamps its last-check date even when the check never reached the
    /// appcast. Reconnecting after a failed check is the moment most likely to
    /// succeed, so it must not wait out the full floor.
    func testCheckThatFailedOnTheNetworkIsRetriedSoon() {
        let retryFloor = SoftwareUpdateController.retryFloorSeconds
        XCTAssertFalse(
            shouldCheck(lastCheckFailedOnNetwork: true, secondsSinceLastCheck: retryFloor - 1)
        )
        XCTAssertTrue(
            shouldCheck(lastCheckFailedOnNetwork: true, secondsSinceLastCheck: retryFloor)
        )
        // The same gap after a check that simply found nothing stays blocked.
        XCTAssertFalse(shouldCheck(secondsSinceLastCheck: retryFloor))
    }

    func testUserWhoTurnedOffAutomaticChecksIsNeverOverridden() {
        XCTAssertFalse(
            shouldCheck(automatic: false, secondsSinceLastCheck: nil)
        )
    }
}
