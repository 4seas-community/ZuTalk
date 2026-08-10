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
        -> [String]
    private let deliver: @Sendable (_ requestID: String, _ result: Result<String, LaneCredentialFailure>) -> Void

    private let lock = NSLock()
    private var pooled: [String] = []

    init(
        sessionID: String,
        accessToken: String,
        fetch: @escaping @Sendable (String, String, Int) async throws -> [String],
        deliver: @escaping @Sendable (String, Result<String, LaneCredentialFailure>) -> Void
    ) {
        self.sessionID = sessionID
        self.accessToken = accessToken
        self.fetch = fetch
        self.deliver = deliver
    }

    /// Fetches the opening batch. A failure here is not fatal: every lane can
    /// still fetch its own key, it just pays a round trip first.
    func prime(laneCount: Int) async {
        guard let keys = try? await fetch(sessionID, accessToken, max(1, laneCount)) else { return }
        deposit(keys)
    }

    private func deposit(_ keys: [String]) {
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
                        .failure(LaneCredentialFailure(message: "no key returned", terminal: true))
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

/// Why a lane could not be given a credential. `terminal` refusals stop the
/// stream; everything else lets it retry with backoff.
struct LaneCredentialFailure: Error, Equatable {
    let message: String
    let terminal: Bool

    /// The invitation itself said no — spent budget, unknown session, revoked
    /// token. Retrying cannot change the answer.
    static func fromStatusCode(_ statusCode: Int) -> LaneCredentialFailure {
        let terminal = statusCode == 401 || statusCode == 404 || statusCode == 429
        return LaneCredentialFailure(
            message: "invite service returned \(statusCode)",
            terminal: terminal
        )
    }
}
