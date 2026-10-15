import Foundation
import Combine
import Security

/// How a capture start resolved its provider credential.
enum CommunityInvitePreparation: Equatable {
    /// Invite mode is off or no invitation is redeemed; the runtime keeps
    /// whatever credential the user configured.
    case notUsed
    /// Invite time was reserved and the temporary key is active.
    case invite
    /// The invite service was unavailable; the user's own saved key was
    /// restored so the recording can still proceed.
    case personalKeyFallback
}

@MainActor
final class CommunityInviteSession: ObservableObject {
    static let shared = CommunityInviteSession()

    @Published private(set) var remainingSeconds: Int?
    @Published private(set) var isWorking = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var isEnabled = UserDefaults.standard.bool(
        forKey: "zutalk.community-invite.enabled"
    )
    /// Lane count of the capture selection currently on screen. The sidebar
    /// divides shared invite seconds by this to show wall-clock recordable
    /// time instead of raw lane-seconds.
    @Published private(set) var plannedLaneCount = 1
    /// What the invite service offers for cleaning up marked passages, as of
    /// the last quota answer. Nil until the service says so, and nil for good
    /// on a service without a model key — passages are never routed through
    /// it on a guess.
    @Published private(set) var passageDigestOffer: CommunityInvitePassageDigestOffer?

    private let baseURL = URL(string: "https://zulangue-invite.exe.xyz")!
    /// 邀请 token 存在 app 私有目录的 0600 文件里，而不是钥匙串。发布构建
    /// 是 ad-hoc 签名，每个构建的签名身份都不同，钥匙串条目的 ACL 会在每次
    /// 更新后拒认新二进制，向用户索要登录钥匙串密码。token 泄露的最坏后果
    /// 只是烧掉共享额度，配不上这个代价。
    private let tokenFileURL: URL
    private var accessToken: String?
    private var activeRealtimeSessionID: String?
    /// Realtime capture streams the same audio once per Soniox lane, so invite
    /// time must be charged per lane, not per wall-clock second.
    private var activeRealtimeLaneCount = 1
    /// Installed for the duration of an invite capture. While it is present
    /// the core asks it for a single-use key per connection, so no invite key
    /// is ever written into the shared credential runtime.
    private var laneCredentialProvider: CommunityInviteLaneCredentialProvider?
    /// Reservations still owed a settlement, on disk so that no way a
    /// recording can end — including the app not being there any more —
    /// leaves one open on the service.
    private let ledger: CommunityInviteSettlementLedger
    /// Recorded seconds last written to the ledger for the active
    /// reservation; the ledger is rewritten only every few seconds of change.
    private var ledgerRecordedSeconds = 0
    private var latestRecordedSeconds = 0
    private var isRetryingSettlements = false
    static let ledgerProgressInterval = 15

    private init() {
        tokenFileURL = Self.defaultTokenFileURL()
        accessToken = Self.loadToken(from: tokenFileURL)
        ledger = CommunityInviteSettlementLedger(
            fileURL: CommunityInviteSettlementLedger.defaultFileURL()
        )
        Self.purgeLegacyKeychainItem()
    }

    var isActive: Bool { accessToken != nil }

    /// Whether the invitation currently stands in for a model key. The
    /// assistance switch still decides whether anything is sent, and a key the
    /// user saved still wins; the core enforces both.
    var coversPassageDigest: Bool {
        isEnabled && isActive && passageDigestOffer != nil
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "zutalk.community-invite.enabled")
        pushPassageDigestRouteToCore()
    }

    /// Tells the core where passages may go on the invitation, or that they
    /// may not. Called whenever the token, the switch, or the offer changes.
    func pushPassageDigestRouteToCore() {
        var route: FfiInviteDigestRoute?
        if coversPassageDigest, let accessToken, let offer = passageDigestOffer {
            route = FfiInviteDigestRoute(
                serviceUrl: baseURL.absoluteString,
                accessToken: accessToken,
                modelId: offer.model
            )
        }
        try? CoreClient.shared.core?.setInviteDigestRoute(route: route)
    }

    func redeem(_ code: String) async {
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty == false else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            let response: RedeemResponse = try await request(
                path: "/v1/redeem",
                method: "POST",
                body: ["code": normalized],
                token: nil
            )
            try saveAccessToken(response.accessToken)
            remainingSeconds = response.remainingSeconds
            setEnabled(true)
        } catch {
            errorMessage = String(localized: "community_invite.invalid")
            return
        }
        // The redeem answer does not say whether passage cleanup is offered;
        // the quota answer does.
        await refreshQuota()
    }

    func refreshQuota() async {
        guard isEnabled, let token = accessToken else { return }
        // Whatever an earlier run of the app could not settle goes first, so
        // the time shown afterwards is what is really left.
        await retryPendingSettlements()
        do {
            let response: CommunityInviteQuotaResponse = try await request(
                path: "/v1/quota",
                method: "GET",
                body: nil,
                token: token
            )
            remainingSeconds = response.remainingSeconds
            // A failed refresh keeps the last offer: being offline for a
            // moment is not the service withdrawing cleanup.
            passageDigestOffer = response.passageDigest
            pushPassageDigestRouteToCore()
        } catch {
            errorMessage = String(localized: "community_invite.unavailable")
        }
    }

    /// Reserves invite time for a realtime capture. When the invite service
    /// is unreachable or out of quota and the user has their own saved key,
    /// the saved key is restored and the start continues on it instead of
    /// failing the recording.
    func prepareRealtimeCredential(laneCount: Int) async throws -> CommunityInvitePreparation {
        let lanes = max(1, laneCount)
        updatePlannedLaneCount(lanes)
        guard isEnabled, accessToken != nil else { return .notUsed }
        await retryPendingSettlements()
        do {
            activeRealtimeSessionID = try await prepareCredential(
                requestedSeconds: 3 * 60 * 60 * lanes,
                laneCount: lanes
            )
            activeRealtimeLaneCount = lanes
            if let sessionID = activeRealtimeSessionID {
                latestRecordedSeconds = 0
                ledgerRecordedSeconds = 0
                ledger.record(CommunityInviteOpenReservation(
                    sessionID: sessionID,
                    laneCount: lanes,
                    reservedAt: Date(),
                    recordedSeconds: 0,
                    ended: false
                ))
            }
            // No renewal loop: every connection fetches its own key, so there
            // is no long-lived credential left to expire mid-recording.
            return .invite
        } catch {
            guard restorePersonalKeyIfSaved() else { throw error }
            errorMessage = String(localized: "community_invite.unavailable")
            return .personalKeyFallback
        }
    }

    func updatePlannedLaneCount(_ laneCount: Int) {
        let lanes = max(1, laneCount)
        guard plannedLaneCount != lanes else { return }
        plannedLaneCount = lanes
    }

    /// Shared invite seconds burn once per lane, so the wall-clock time the
    /// user can actually record is the remainder divided by the lane count.
    static func wallClockRecordableSeconds(remainingSeconds: Int, laneCount: Int) -> Int {
        max(0, remainingSeconds) / max(1, laneCount)
    }

    /// After-stop transcription never runs on invite time: Soniox temporary
    /// keys are WebSocket-scoped and the async file REST API rejects them.
    /// Uploading the recording also happens under whichever account owns the
    /// key, so it stays off until the user saves their own.
    var asyncTranscriptionNeedsPersonalKey: Bool {
        guard isEnabled, isActive else { return false }
        return hasSavedPersonalKey == false
    }

    /// Puts the user's own saved key into the runtime before an after-stop
    /// transcription while invite mode is on. Refuses while an invite
    /// realtime capture is running so its temporary key is not replaced
    /// mid-recording.
    func preparePersonalKeyForAsyncTranscription() throws {
        guard isEnabled, accessToken != nil else { return }
        guard activeRealtimeSessionID == nil else {
            throw CommunityInviteError.realtimeCaptureActive
        }
        guard restorePersonalKeyIfSaved() else {
            throw CommunityInviteError.personalKeyRequired
        }
    }

    private func prepareCredential(
        requestedSeconds: Int,
        laneCount: Int
    ) async throws -> String? {
        guard isEnabled, let token = accessToken else { return nil }
        // The reservation is counted in lane-seconds. The server needs the
        // lane count to divide it back into the wall-clock ceiling it hands
        // Soniox, otherwise every lane may run the full reservation alone.
        let response: RealtimeSessionResponse = try await request(
            path: "/v1/realtime-session",
            method: "POST",
            body: [
                "requested_seconds": requestedSeconds,
                "lane_count": laneCount,
                // New services return the opening single-use lane keys with
                // the reservation. Old services ignore this field and return
                // their legacy shared key, which is deliberately not used;
                // the missing `keys` array triggers the /key fallback below.
                "initial_key_mode": "single_use_batch",
            ],
            token: token
        )
        // Invite keys are single-use and short-lived, so they are served per
        // connection through the core instead of being written into the
        // shared credential runtime, where they would outlive their use and
        // shadow the user's own saved key.
        let provider = makeLaneCredentialProvider(
            sessionID: response.sessionID,
            token: token
        )
        laneCredentialProvider = provider
        CoreClient.shared.core?.setLaneCredentialRequester(requester: provider)
        await provider.prepareInitialKeys(
            response.initialKeys?.map(\.apiKey) ?? [],
            laneCount: laneCount,
            sessionCapSeconds: response.maxSessionDurationSeconds
        )
        remainingSeconds = max(0, (remainingSeconds ?? 0) - response.reservedSeconds)
        return response.sessionID
    }

    private func makeLaneCredentialProvider(
        sessionID: String,
        token: String
    ) -> CommunityInviteLaneCredentialProvider {
        let baseURL = self.baseURL
        return CommunityInviteLaneCredentialProvider(
            sessionID: sessionID,
            accessToken: token,
            fetchKeys: { sessionID, token, count in
                try await CommunityInviteSession.fetchLaneKeys(
                    baseURL: baseURL,
                    sessionID: sessionID,
                    token: token,
                    count: count
                )
            },
            deliverKey: { requestID, result in
                Task { @MainActor in
                    guard let core = CoreClient.shared.core else { return }
                    switch result {
                    case .success(let key):
                        core.fulfillLaneCredential(
                            requestId: requestID,
                            apiKey: key.apiKey,
                            sessionCapSeconds: key.sessionCapSeconds
                        )
                    case .failure(let failure):
                        core.failLaneCredential(
                            requestId: requestID,
                            message: failure.message,
                            refusal: failure.refusal
                        )
                    }
                }
            }
        )
    }

    /// One request covers a whole multi-language start; reconnects ask for a
    /// single key. Status codes the invite service uses for refusals become
    /// terminal failures so a lane stops instead of retrying a spent budget.
    nonisolated static func fetchLaneKeys(
        baseURL: URL,
        sessionID: String,
        token: String,
        count: Int
    ) async throws -> [CommunityInviteLaneKey] {
        var request = URLRequest(
            url: baseURL.appendingPathComponent("v1/realtime-session/key")
        )
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["session_id": sessionID, "count": count]
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LaneCredentialFailure(message: "no HTTP response", terminal: false)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw LaneCredentialFailure.fromResponse(statusCode: http.statusCode, body: data)
        }
        let decoded = try JSONDecoder().decode(LaneKeyResponse.self, from: data)
        return decoded.keys.map {
            CommunityInviteLaneKey(
                apiKey: $0.apiKey,
                sessionCapSeconds: decoded.maxSessionDurationSeconds
            )
        }
    }

    /// Ends the active reservation: called for every way a recording ends,
    /// and a no-op when there is none (a second caller for the same ending).
    func settleRealtimeSession(usedSeconds: Int) async {
        // Unused single-use keys are dropped rather than kept: they are only
        // redeemable for minutes, and holding them widens the window in which
        // a leaked one still opens a stream.
        laneCredentialProvider?.discardPooledKeys()
        laneCredentialProvider = nil
        CoreClient.shared.core?.setLaneCredentialRequester(requester: nil)
        let sessionID = activeRealtimeSessionID
        activeRealtimeSessionID = nil
        let lanes = activeRealtimeLaneCount
        activeRealtimeLaneCount = 1
        // The service's settlement endpoint is where the reservation ends,
        // but the ledger is where the obligation lives: mark it final first,
        // so a settle that does not get through is sent again later.
        if let sessionID {
            let recorded = max(usedSeconds, latestRecordedSeconds)
            ledger.record(CommunityInviteOpenReservation(
                sessionID: sessionID,
                laneCount: lanes,
                reservedAt: ledger.reservations()
                    .first { $0.sessionID == sessionID }?.reservedAt ?? Date(),
                recordedSeconds: recorded,
                ended: true
            ))
            if await settle(sessionID: sessionID, usedSeconds: recorded * lanes) {
                ledger.remove(sessionID: sessionID)
            }
        }
        latestRecordedSeconds = 0
        ledgerRecordedSeconds = 0
        // The session's temporary key is spent; put the user's own saved key
        // back so post-recording features never run on a dead credential.
        restorePersonalKeyIfSaved()
    }

    /// The recording clock, while an invite recording runs. Kept in memory
    /// every tick and in the ledger every few seconds of change, so that a
    /// recording the app never gets to settle is settled later for what it
    /// actually recorded rather than for nothing.
    func noteRealtimeProgress(elapsedSeconds: Int) {
        guard let sessionID = activeRealtimeSessionID else { return }
        latestRecordedSeconds = max(latestRecordedSeconds, elapsedSeconds)
        guard latestRecordedSeconds - ledgerRecordedSeconds >= Self.ledgerProgressInterval else {
            return
        }
        ledgerRecordedSeconds = latestRecordedSeconds
        guard let open = ledger.reservations().first(where: { $0.sessionID == sessionID }) else {
            return
        }
        var updated = open
        updated.recordedSeconds = latestRecordedSeconds
        ledger.record(updated)
    }

    /// Settles every reservation an earlier run, or an earlier attempt, left
    /// open. A reservation still being recorded on is skipped; one that was
    /// never marked ended belonged to a recording the app did not survive,
    /// and is settled for the time it had recorded by then.
    func retryPendingSettlements() async {
        guard isRetryingSettlements == false, accessToken != nil else { return }
        isRetryingSettlements = true
        defer { isRetryingSettlements = false }
        for reservation in ledger.reservations()
        where reservation.sessionID != activeRealtimeSessionID {
            if await settle(
                sessionID: reservation.sessionID,
                usedSeconds: reservation.usedLaneSeconds
            ) {
                ledger.remove(sessionID: reservation.sessionID)
            }
        }
    }

    /// The app is quitting with an invite recording that has just been
    /// stopped. Tries to settle it now, but never holds the quit up for
    /// long: whatever does not get through stays in the ledger for the next
    /// launch.
    func settleBeforeTermination(usedSeconds: Int, timeout: TimeInterval = 3) async {
        guard activeRealtimeSessionID != nil else { return }
        // Not a task group: leaving one waits for every child, so a settle
        // stuck on a dead connection would have held the quit for the
        // request's full timeout. Whichever finishes first resumes the quit.
        var finished = false
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Task { @MainActor in
                await self.settleRealtimeSession(usedSeconds: usedSeconds)
                if finished == false {
                    finished = true
                    continuation.resume()
                }
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                if finished == false {
                    finished = true
                    continuation.resume()
                }
            }
        }
    }

    /// Deletes the redeemed invitation from this Mac and returns the app to
    /// its normal credential state (the user's own saved key, if any).
    func removeInvite() {
        try? FileManager.default.removeItem(at: tokenFileURL)
        accessToken = nil
        passageDigestOffer = nil
        laneCredentialProvider?.discardPooledKeys()
        laneCredentialProvider = nil
        CoreClient.shared.core?.setLaneCredentialRequester(requester: nil)
        remainingSeconds = nil
        errorMessage = nil
        activeRealtimeSessionID = nil
        activeRealtimeLaneCount = 1
        // Without the token nothing in the ledger can be sent; the service
        // sweeps those reservations on its own.
        ledger.removeAll()
        setEnabled(false)
        // With no saved key this clears any leftover temporary key from the
        // runtime; with one it reactivates the user's own credential.
        try? ProviderCredentialSession.shared.activateSavedCredentials()
    }

    private var hasSavedPersonalKey: Bool {
        ProviderCredentialSession.shared.snapshot()
            .contains { $0.account == .soniox && $0.isSaved }
    }

    @discardableResult
    private func restorePersonalKeyIfSaved() -> Bool {
        guard hasSavedPersonalKey else { return false }
        do {
            try ProviderCredentialSession.shared.activateSavedCredentials()
            return true
        } catch {
            return false
        }
    }

    /// Whether the service has answered for this reservation — settled now,
    /// settled before, or never known to it. Only a missing answer (offline,
    /// a server error) means it must be tried again.
    private func settle(sessionID: String, usedSeconds: Int) async -> Bool {
        guard let token = accessToken else { return false }
        do {
            let response: CommunityInviteQuotaResponse = try await request(
                path: "/v1/realtime-session/settle",
                method: "POST",
                body: [
                    "session_id": sessionID,
                    "used_seconds": max(0, usedSeconds),
                ],
                token: token
            )
            remainingSeconds = response.remainingSeconds
            return true
        } catch CommunityInviteError.refused(statusCode: 404, reason: _) {
            // An older service answers a closed session this way; either way
            // there is nothing left to settle.
            return true
        } catch {
            return false
        }
    }

    /// 和 provider 凭据同一个 Secrets 目录，跟随同一套测试隔离。
    static func defaultTokenFileURL() -> URL {
        ProviderCredentialFileStore.defaultFileURL()
            .deletingLastPathComponent()
            .appendingPathComponent("community-invite.json", isDirectory: false)
    }

    static func loadToken(from url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              data.count <= 64 * 1024,
              let document = try? JSONDecoder().decode(InviteTokenDocument.self, from: data),
              document.version == 1
        else { return nil }
        let token = document.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    private func saveAccessToken(_ token: String) throws {
        do {
            let data = try JSONEncoder().encode(
                InviteTokenDocument(version: 1, accessToken: token)
            )
            let directoryURL = tokenFileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try data.write(to: tokenFileURL, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: tokenFileURL.path
            )
        } catch {
            throw CommunityInviteError.secureStorageFailed
        }
        accessToken = token
    }

    /// 旧版本把 token 存在钥匙串。只删不读：读取会触发钥匙串密码框——
    /// 正是这次要消灭的弹窗——而删除不碰密文，所以是安静的。token 就此
    /// 丢弃，持有邀请的用户重新兑换一次邀请码。
    private static func purgeLegacyKeychainItem() {
        guard TestEnvironment.isAnyTestMode == false else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            // 老名字，不能跟着产品改名走：要删的条目是 Zulangue 时期的构建
            // 写下的，它们的 service 属性永远停在旧 bundle ID 上。
            kSecAttrService as String: "xyz.voice.zulangue.community-invite",
            kSecAttrAccount as String: "access-token",
        ]
        SecItemDelete(query as CFDictionary)
    }

    private func request<Response: Decodable>(
        path: String,
        method: String,
        body: [String: Any]?,
        token: String?
    ) async throws -> Response {
        var request = URLRequest(
            url: baseURL.appendingPathComponent(
                path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            )
        )
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CommunityInviteError.requestFailed
        }
        guard (200..<300).contains(http.statusCode) else {
            // The service says why it refused in the body. Every refusal used
            // to read "community service unavailable", including two that
            // were nothing of the kind: an invitation out of time, and one
            // with recordings left unsettled by force-quits.
            let reason = (try? JSONDecoder().decode(RefusalBody.self, from: data))?.error
            throw CommunityInviteError.refused(statusCode: http.statusCode, reason: reason)
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private struct RefusalBody: Decodable {
        let error: String?
    }
}

private struct InviteTokenDocument: Codable {
    let version: Int
    let accessToken: String

    enum CodingKeys: String, CodingKey {
        case version
        case accessToken = "access_token"
    }
}

private struct RedeemResponse: Decodable {
    let accessToken: String
    let remainingSeconds: Int

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case remainingSeconds = "remaining_seconds"
    }
}

struct CommunityInviteQuotaResponse: Decodable {
    let remainingSeconds: Int
    /// Only `/v1/quota` carries this; settle answers leave it out, and are
    /// never read for it.
    let passageDigest: CommunityInvitePassageDigestOffer?

    enum CodingKeys: String, CodingKey {
        case remainingSeconds = "remaining_seconds"
        case passageDigest = "passage_digest"
    }
}

/// The invite service's offer to clean up marked passages on its own model
/// key. The service names the provider and model, so Settings can say where a
/// passage goes without the app keeping a copy of the service's choices.
struct CommunityInvitePassageDigestOffer: Decodable, Equatable {
    let provider: String
    let model: String
    let dailyLimit: Int
    let remainingToday: Int

    enum CodingKeys: String, CodingKey {
        case provider
        case model
        case dailyLimit = "daily_limit"
        case remainingToday = "remaining_today"
    }
}

struct RealtimeSessionResponse: Decodable {
    let sessionID: String
    let reservedSeconds: Int
    // Present on old services. It is a reusable shared key, so the new
    // single-use lane provider must never put it into its opening-key pool.
    let legacyAPIKey: String?
    let initialKeys: [RealtimeLaneKey]?
    /// How long the opening keys may stream before Soniox ends them. Absent
    /// from services that predate the hand-over; lanes then roll over when
    /// Soniox ends the connection instead.
    let maxSessionDurationSeconds: UInt64?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case reservedSeconds = "reserved_seconds"
        case legacyAPIKey = "api_key"
        case initialKeys = "keys"
        case maxSessionDurationSeconds = "max_session_duration_seconds"
    }
}

struct RealtimeLaneKey: Decodable {
    let apiKey: String

    enum CodingKeys: String, CodingKey {
        case apiKey = "api_key"
    }
}

/// One batch of single-use lane keys. The service also mirrors a single key
/// into flat fields for the legacy path; only the array is read here.
private struct LaneKeyResponse: Decodable {
    let keys: [RealtimeLaneKey]
    let maxSessionDurationSeconds: UInt64?

    enum CodingKeys: String, CodingKey {
        case keys
        case maxSessionDurationSeconds = "max_session_duration_seconds"
    }
}

enum CommunityInviteError: Error, LocalizedError, Equatable {
    case requestFailed
    case refused(statusCode: Int, reason: String?)
    case secureStorageFailed
    case personalKeyRequired
    case realtimeCaptureActive

    var errorDescription: String? {
        switch self {
        case .requestFailed:
            return String(localized: "community_invite.unavailable")
        case let .refused(statusCode, reason):
            return Self.refusalDescription(statusCode: statusCode, reason: reason)
        case .secureStorageFailed:
            return nil
        case .personalKeyRequired:
            return String(localized: "community_invite.async.needs_personal_key")
        case .realtimeCaptureActive:
            return String(localized: "community_invite.async.wait_for_recording")
        }
    }

    /// The words for a refusal, chosen by what the service said rather than
    /// by status code alone (a spent invitation and a spent key budget are
    /// both 429; a full service and a busy key mint are both 503).
    static func refusalDescription(statusCode: Int, reason: String?) -> String {
        switch reason {
        case "quota_exhausted":
            return String(localized: "community_invite.start.time_exhausted")
        case "capacity_reached":
            return String(localized: "community_invite.start.busy")
        case "unauthorized", "invalid_invite":
            return String(localized: "community_invite.start.unauthorized")
        default:
            if statusCode == 401 {
                return String(localized: "community_invite.start.unauthorized")
            }
            return String(localized: "community_invite.unavailable")
        }
    }
}
