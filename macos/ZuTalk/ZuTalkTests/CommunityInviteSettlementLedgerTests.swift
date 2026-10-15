import XCTest
@testable import ZuTalk

/// A reservation is crossed off only once the service has answered for it,
/// so every way a recording can end leaves something that is settled later.
@MainActor
final class CommunityInviteSettlementLedgerTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("invite-ledger-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func ledger() -> CommunityInviteSettlementLedger {
        CommunityInviteSettlementLedger(
            fileURL: directory.appendingPathComponent("reservations.json")
        )
    }

    private func reservation(
        _ id: String,
        lanes: Int = 3,
        recorded: Int = 0,
        ended: Bool = false
    ) -> CommunityInviteOpenReservation {
        CommunityInviteOpenReservation(
            sessionID: id,
            laneCount: lanes,
            reservedAt: Date(timeIntervalSince1970: 1_800_000_000),
            recordedSeconds: recorded,
            ended: ended
        )
    }

    func testAReservationSurvivesTheProcessThatMadeIt() {
        ledger().record(reservation("a", recorded: 120))
        // A new ledger on the same file is the next launch after a crash.
        XCTAssertEqual(ledger().reservations(), [reservation("a", recorded: 120)])
    }

    func testRecordingAgainReplacesRatherThanDuplicates() {
        let ledger = ledger()
        ledger.record(reservation("a", recorded: 15))
        ledger.record(reservation("b"))
        ledger.record(reservation("a", recorded: 600, ended: true))
        XCTAssertEqual(
            ledger.reservations().sorted { $0.sessionID < $1.sessionID },
            [reservation("a", recorded: 600, ended: true), reservation("b")]
        )
    }

    func testRemovingTheLastReservationLeavesNoFileBehind() {
        let ledger = ledger()
        ledger.record(reservation("a"))
        ledger.remove(sessionID: "a")
        XCTAssertTrue(ledger.reservations().isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("reservations.json").path
            )
        )
    }

    func testTheLedgerIsReadableOnlyByItsOwner() throws {
        ledger().record(reservation("a"))
        let attributes = try FileManager.default.attributesOfItem(
            atPath: directory.appendingPathComponent("reservations.json").path
        )
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testAnUnreadableLedgerIsTreatedAsEmptyInsteadOfFailing() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: directory.appendingPathComponent("reservations.json"))
        XCTAssertTrue(ledger().reservations().isEmpty)
    }

    func testInviteTimeIsSpentOncePerLane() {
        XCTAssertEqual(reservation("a", lanes: 3, recorded: 1_093).usedLaneSeconds, 3_279)
        XCTAssertEqual(reservation("a", lanes: 0, recorded: 60).usedLaneSeconds, 60)
        XCTAssertEqual(reservation("a", lanes: 2, recorded: -5).usedLaneSeconds, 0)
    }

    /// Every refusal used to read "community service unavailable".
    func testRefusalsSayWhatTheServiceSaid() {
        XCTAssertEqual(
            CommunityInviteError.refusalDescription(statusCode: 409, reason: "quota_exhausted"),
            String(localized: "community_invite.start.time_exhausted")
        )
        XCTAssertEqual(
            CommunityInviteError.refusalDescription(statusCode: 503, reason: "capacity_reached"),
            String(localized: "community_invite.start.busy")
        )
        XCTAssertEqual(
            CommunityInviteError.refusalDescription(statusCode: 401, reason: nil),
            String(localized: "community_invite.start.unauthorized")
        )
        XCTAssertEqual(
            CommunityInviteError.refusalDescription(statusCode: 502, reason: "upstream_unavailable"),
            String(localized: "community_invite.unavailable")
        )
    }
}
