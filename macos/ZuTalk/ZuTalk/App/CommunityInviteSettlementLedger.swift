import Foundation

/// One invite reservation this Mac opened and has not yet settled.
struct CommunityInviteOpenReservation: Codable, Equatable {
    let sessionID: String
    let laneCount: Int
    let reservedAt: Date
    /// Wall-clock seconds recorded on this reservation, as far as anyone
    /// knew last. Written while the recording runs, so a force-quit or a
    /// crash still leaves an honest figure to settle with.
    var recordedSeconds: Int
    /// The recording has ended and `recordedSeconds` is final.
    var ended: Bool

    /// What the service is told: invite time is spent once per lane.
    var usedLaneSeconds: Int { max(0, recordedSeconds) * max(1, laneCount) }

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case laneCount = "lane_count"
        case reservedAt = "reserved_at"
        case recordedSeconds = "recorded_seconds"
        case ended
    }
}

/// The reservations still owed a settlement, kept on disk.
///
/// Settling used to be one request sent once, from the success path of the
/// Stop button. Every other way a recording ends — the microphone going away,
/// the app quitting, a crash, a force-quit after Stop hung, or that one
/// request failing on a bad connection — left the reservation open on the
/// service until its six-hour sweep, which then charged nothing. A quarter of
/// all invite recordings ended that way. Writing the reservation down the
/// moment it is made, and crossing it off only when the service has answered,
/// turns each of those endings into a settlement that is merely late.
///
/// Same directory and permissions as the invite token, so it follows the same
/// test isolation and never holds anything more sensitive than session ids.
final class CommunityInviteSettlementLedger {
    private let fileURL: URL
    private let lock = NSLock()

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    static func defaultFileURL() -> URL {
        CommunityInviteSession.defaultTokenFileURL()
            .deletingLastPathComponent()
            .appendingPathComponent("community-invite-reservations.json", isDirectory: false)
    }

    func reservations() -> [CommunityInviteOpenReservation] {
        lock.lock()
        defer { lock.unlock() }
        return load()
    }

    /// Inserts the reservation, or replaces the one with the same id.
    func record(_ reservation: CommunityInviteOpenReservation) {
        lock.lock()
        defer { lock.unlock() }
        var all = load().filter { $0.sessionID != reservation.sessionID }
        all.append(reservation)
        save(all)
    }

    func remove(sessionID: String) {
        lock.lock()
        defer { lock.unlock() }
        let all = load()
        let remaining = all.filter { $0.sessionID != sessionID }
        guard remaining.count != all.count else { return }
        save(remaining)
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func load() -> [CommunityInviteOpenReservation] {
        guard let data = try? Data(contentsOf: fileURL),
              data.count <= 256 * 1024,
              let document = try? Self.decoder.decode(Document.self, from: data),
              document.version == 1
        else { return [] }
        return document.reservations
    }

    private func save(_ reservations: [CommunityInviteOpenReservation]) {
        if reservations.isEmpty {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        guard let data = try? Self.encoder.encode(
            Document(version: 1, reservations: reservations)
        ) else { return }
        let directoryURL = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        do {
            try data.write(to: fileURL, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        } catch {
            DebugLog.warn("community invite reservation ledger not written", detail: "\(error)")
        }
    }

    private struct Document: Codable {
        let version: Int
        let reservations: [CommunityInviteOpenReservation]
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
