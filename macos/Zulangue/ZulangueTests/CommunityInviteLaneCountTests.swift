import XCTest
@testable import Zulangue

/// Invite billing charges per Soniox lane. This mapping must mirror the Rust
/// core's `remote_stream_plan`: one or two languages share a single stream,
/// three or more open one canonical lane plus one translation lane per
/// selected language.
@MainActor
final class CommunityInviteLaneCountTests: XCTestCase {
    func testOneOrTwoLanguagesUseSingleLane() {
        XCTAssertEqual(NotebookCaptureToolbar.remoteLaneCount(selectedLanguages: ["en"]), 1)
        XCTAssertEqual(
            NotebookCaptureToolbar.remoteLaneCount(selectedLanguages: ["en", "th"]),
            1
        )
    }

    func testThreeOrMoreLanguagesOpenCanonicalPlusPerLanguageLanes() {
        XCTAssertEqual(
            NotebookCaptureToolbar.remoteLaneCount(selectedLanguages: ["en", "th", "zh"]),
            4
        )
        XCTAssertEqual(
            NotebookCaptureToolbar.remoteLaneCount(selectedLanguages: ["en", "th", "zh", "ja"]),
            5
        )
    }

    /// The sidebar shows wall-clock recordable time: shared invite seconds
    /// divided by the lane count of the current selection.
    func testWallClockRecordableSecondsDividesByLaneCount() {
        XCTAssertEqual(
            CommunityInviteSession.wallClockRecordableSeconds(
                remainingSeconds: 5_400,
                laneCount: 1
            ),
            5_400
        )
        XCTAssertEqual(
            CommunityInviteSession.wallClockRecordableSeconds(
                remainingSeconds: 5_400,
                laneCount: 4
            ),
            1_350
        )
        XCTAssertEqual(
            CommunityInviteSession.wallClockRecordableSeconds(
                remainingSeconds: -60,
                laneCount: 0
            ),
            0
        )
    }
}

/// Invite lanes take a single-use key per connection. These cover the parts
/// that decide whether a recording survives: where each key comes from, and
/// whether a failure ends the recording or lets it reconnect.
@MainActor
final class CommunityInviteLaneCredentialTests: XCTestCase {
    private func provider(
        fetch: @escaping @Sendable (String, String, Int) async throws -> [String],
        deliver: @escaping @Sendable (String, Result<String, LaneCredentialFailure>) -> Void
    ) -> CommunityInviteLaneCredentialProvider {
        CommunityInviteLaneCredentialProvider(
            sessionID: "session-1",
            accessToken: "token-1",
            fetch: fetch,
            deliver: deliver
        )
    }

    func testPrimedKeysAnswerOpeningLanesWithoutARoundTrip() async {
        let fetchCount = LockedCounter()
        let answers = LockedAnswers()
        let subject = provider(
            fetch: { _, _, count in
                fetchCount.increment()
                return (0..<count).map { "batch-key-\($0)" }
            },
            deliver: { requestID, result in answers.record(requestID, result) }
        )

        await subject.prime(laneCount: 3)
        XCTAssertEqual(fetchCount.value, 1)
        XCTAssertEqual(subject.pooledKeyCount, 3)

        // Three lanes open at once; each is served from the batch, so the
        // opening burst costs exactly one request in total.
        subject.onLaneCredentialRequested(requestId: "r1")
        subject.onLaneCredentialRequested(requestId: "r2")
        subject.onLaneCredentialRequested(requestId: "r3")
        XCTAssertEqual(fetchCount.value, 1)
        XCTAssertEqual(subject.pooledKeyCount, 0)
        XCTAssertEqual(answers.key(for: "r1"), "batch-key-0")
        XCTAssertEqual(answers.key(for: "r2"), "batch-key-1")
        XCTAssertEqual(answers.key(for: "r3"), "batch-key-2")
    }

    func testAReconnectFetchesItsOwnKeyOnceThePoolIsEmpty() async throws {
        let fetchCount = LockedCounter()
        let answers = LockedAnswers()
        let subject = provider(
            fetch: { _, _, count in
                fetchCount.increment()
                XCTAssertEqual(count, 1, "a reconnect must ask for exactly one key")
                return ["reconnect-key"]
            },
            deliver: { requestID, result in answers.record(requestID, result) }
        )

        subject.onLaneCredentialRequested(requestId: "r1")
        try await answers.waitForAnswer(to: "r1")
        XCTAssertEqual(fetchCount.value, 1)
        XCTAssertEqual(answers.key(for: "r1"), "reconnect-key")
    }

    func testARefusedInviteIsTerminalAndAnOutageIsNot() async throws {
        let answers = LockedAnswers()
        let refusing = provider(
            fetch: { _, _, _ in throw LaneCredentialFailure.fromStatusCode(429) },
            deliver: { requestID, result in answers.record(requestID, result) }
        )
        refusing.onLaneCredentialRequested(requestId: "spent")
        try await answers.waitForAnswer(to: "spent")
        XCTAssertEqual(answers.failure(for: "spent")?.terminal, true)

        let offline = provider(
            fetch: { _, _, _ in throw URLError(.notConnectedToInternet) },
            deliver: { requestID, result in answers.record(requestID, result) }
        )
        offline.onLaneCredentialRequested(requestId: "offline")
        try await answers.waitForAnswer(to: "offline")
        XCTAssertEqual(
            answers.failure(for: "offline")?.terminal,
            false,
            "a network blip must stay retryable so the lane reconnects"
        )
    }

    func testInviteServiceStatusCodesMapToTerminalOnlyWhenTheAnswerIsFinal() {
        // Spent budget, revoked token, unknown session: retrying cannot help.
        XCTAssertTrue(LaneCredentialFailure.fromStatusCode(401).terminal)
        XCTAssertTrue(LaneCredentialFailure.fromStatusCode(404).terminal)
        XCTAssertTrue(LaneCredentialFailure.fromStatusCode(429).terminal)
        // A restarting or unconfigured service is worth another attempt.
        XCTAssertFalse(LaneCredentialFailure.fromStatusCode(502).terminal)
        XCTAssertFalse(LaneCredentialFailure.fromStatusCode(503).terminal)
    }

    func testDiscardingPooledKeysLeavesNothingRedeemable() async {
        let subject = provider(
            fetch: { _, _, count in (0..<count).map { "key-\($0)" } },
            deliver: { _, _ in }
        )
        await subject.prime(laneCount: 4)
        XCTAssertEqual(subject.pooledKeyCount, 4)
        subject.discardPooledKeys()
        XCTAssertEqual(subject.pooledKeyCount, 0)
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private final class LockedAnswers: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [String: Result<String, LaneCredentialFailure>] = [:]

    func record(_ requestID: String, _ result: Result<String, LaneCredentialFailure>) {
        lock.lock()
        results[requestID] = result
        lock.unlock()
    }

    private func result(for requestID: String) -> Result<String, LaneCredentialFailure>? {
        lock.lock()
        defer { lock.unlock() }
        return results[requestID]
    }

    func key(for requestID: String) -> String? {
        guard case .success(let key) = result(for: requestID) else { return nil }
        return key
    }

    func failure(for requestID: String) -> LaneCredentialFailure? {
        guard case .failure(let failure) = result(for: requestID) else { return nil }
        return failure
    }

    func waitForAnswer(to requestID: String) async throws {
        for _ in 0..<200 {
            if result(for: requestID) != nil { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("no answer delivered for \(requestID)")
    }
}
