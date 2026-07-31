// SoftwareUpdateRetryTests.swift
//
// Coverage for the transient-network classification that decides whether an
// aborted Sparkle update cycle is retried automatically. Only genuine network
// failures may retry; signature, policy, and user-cancelled aborts must not.

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
}
