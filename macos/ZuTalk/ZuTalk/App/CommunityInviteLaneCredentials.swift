import Foundation

/// Supplies one single-use Soniox key per capture connection while a
/// community invitation is the credential source.
///
/// The core calls `onLaneCredentialRequested` on the thread that is about to
/// open a WebSocket, so it must return immediately. Every answer is delivered
/// later through the core's fulfill/fail entry points.
///
/// Keys for the initial lanes are fetched in one batch at capture start, so
/// the lanes that open right after it never wait on the network. Reconnects
/// fetch on demand: an invite key stays redeemable for only a few minutes, so
/// a spare kept in reserve would be stale exactly when it was needed.
final class CommunityInviteLaneCredentialProvider: FfiLaneCredentialRequester, @unchecked Sendable {
    private let sessionID: String
    private let accessToken: String
    private let fetch: @Sendable (_ sessionID: String, _ token: String, _ count: Int) async throws
        -> [CommunityInviteLaneKey]
    private let deliver: @Sendable (
        _ requestID: String,
        _ result: Result<CommunityInviteLaneKey, LaneCredentialFailure>
    ) -> Void

    private let lock = NSLock()
    private var pooled: [CommunityInviteLaneKey] = []

    init(
        sessionID: String,
        accessToken: String,
        fetchKeys: @escaping @Sendable (String, String, Int) async throws -> [CommunityInviteLaneKey],
        deliverKey: @escaping @Sendable (String, Result<CommunityInviteLaneKey, LaneCredentialFailure>) -> Void
    ) {
        self.sessionID = sessionID
        self.accessToken = accessToken
        self.fetch = fetchKeys
        self.deliver = deliverKey
    }

    /// For callers that only deal in key strings and know no session caps.
    convenience init(
        sessionID: String,
        accessToken: String,
        fetch: @escaping @Sendable (String, String, Int) async throws -> [String],
        deliver: @escaping @Sendable (String, Result<String, LaneCredentialFailure>) -> Void
    ) {
        self.init(
            sessionID: sessionID,
            accessToken: accessToken,
            fetchKeys: { sessionID, token, count in
                try await fetch(sessionID, token, count).map {
                    CommunityInviteLaneKey(apiKey: $0, sessionCapSeconds: nil)
                }
            },
            deliverKey: { requestID, result in
                deliver(requestID, result.map(\.apiKey))
            }
        )
    }

    /// Seeds keys returned with a new reservation, fetching only the missing
    /// opening lanes when talking to an older service (which returns no batch)
    /// or to a service that returned a partial batch. A failure here is not
    /// fatal: every lane can still fetch its own key on demand.
    ///
    /// `sessionCapSeconds` is how long the service minted the opening keys to
    /// stream for; each lane hands over to its next key shortly before then.
    func prepareInitialKeys(
        _ initialKeys: [String],
        laneCount: Int,
        sessionCapSeconds: UInt64? = nil
    ) async {
        deposit(initialKeys.map {
            CommunityInviteLaneKey(apiKey: $0, sessionCapSeconds: sessionCapSeconds)
        })
        let missingCount = max(0, max(1, laneCount) - pooledKeyCount)
        guard missingCount > 0,
              let keys = try? await fetch(sessionID, accessToken, missingCount)
        else { return }
        deposit(keys)
    }

    /// Compatibility entry point for callers that do not receive keys with
    /// the reservation response.
    func prime(laneCount: Int) async {
        await prepareInitialKeys([], laneCount: laneCount)
    }

    private func deposit(_ keys: [CommunityInviteLaneKey]) {
        lock.lock()
        pooled.append(contentsOf: keys)
        lock.unlock()
    }

    func onLaneCredentialRequested(requestId: String) {
        lock.lock()
        let pooledKey = pooled.isEmpty ? nil : pooled.removeFirst()
        lock.unlock()

        if let pooledKey {
            deliver(requestId, .success(pooledKey))
            return
        }

        Task { [sessionID, accessToken, fetch, deliver] in
            do {
                let keys = try await fetch(sessionID, accessToken, 1)
                guard let key = keys.first else {
                    deliver(
                        requestId,
                        .failure(LaneCredentialFailure(message: "no key returned", refusal: .refused))
                    )
                    return
                }
                deliver(requestId, .success(key))
            } catch let failure as LaneCredentialFailure {
                deliver(requestId, .failure(failure))
            } catch {
                // Anything unclassified is treated as transient so the lane
                // keeps its normal reconnect backoff instead of ending the
                // recording on a blip.
                deliver(
                    requestId,
                    .failure(
                        LaneCredentialFailure(
                            message: error.localizedDescription,
                            terminal: false
                        )
                    )
                )
            }
        }
    }

    /// Drops any unused keys. They are single-use and short-lived, so keeping
    /// them past the recording only widens the window in which a leaked one
    /// still works.
    func discardPooledKeys() {
        lock.lock()
        pooled.removeAll()
        lock.unlock()
    }

    var pooledKeyCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pooled.count
    }
}

/// One single-use key for one connection, and how long the service minted it
/// to stream for. A known cap lets the lane hand over to its next key at a
/// pause before the provider would end the connection.
struct CommunityInviteLaneKey: Equatable, Sendable {
    let apiKey: String
    let sessionCapSeconds: UInt64?
}

/// Why a lane could not be given a credential. Refusals and spent time stop
/// the stream; everything else lets it retry with backoff.
struct LaneCredentialFailure: Error, Equatable {
    let message: String
    let refusal: FfiLaneCredentialRefusal

    init(message: String, refusal: FfiLaneCredentialRefusal) {
        self.message = message
        self.refusal = refusal
    }

    init(message: String, terminal: Bool) {
        self.init(message: message, refusal: terminal ? .refused : .transient)
    }

    var terminal: Bool { refusal != .transient }

    /// Reads the invite service's answer. The service names why it said no
    /// in the body; the status alone cannot tell a spent invitation from a
    /// spent key budget (both 429), and the two need different words.
    static func fromResponse(statusCode: Int, body: Data?) -> LaneCredentialFailure {
        let reason = body
            .flatMap { try? JSONDecoder().decode(RefusalBody.self, from: $0) }?
            .error ?? ""
        let refusal: FfiLaneCredentialRefusal
        if reason == "quota_exhausted" || statusCode == 402 {
            refusal = .timeExhausted
        } else if statusCode == 401 || statusCode == 404 || statusCode == 429 {
            refusal = .refused
        } else {
            refusal = .transient
        }
        let detail = reason.isEmpty ? "" : " \(reason)"
        return LaneCredentialFailure(
            message: "invite service returned \(statusCode)\(detail)",
            refusal: refusal
        )
    }

    /// The invitation itself said no — spent budget, unknown session, revoked
    /// token. Retrying cannot change the answer.
    static func fromStatusCode(_ statusCode: Int) -> LaneCredentialFailure {
        fromResponse(statusCode: statusCode, body: nil)
    }

    private struct RefusalBody: Decodable {
        let error: String?
    }
}
