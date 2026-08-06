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
        forKey: "zulangue.community-invite.enabled"
    )
    /// Lane count of the capture selection currently on screen. The sidebar
    /// divides shared invite seconds by this to show wall-clock recordable
    /// time instead of raw lane-seconds.
    @Published private(set) var plannedLaneCount = 1

    private let baseURL = URL(string: "https://zulangue-invite.exe.xyz")!
    private let keychainService = "xyz.voice.zulangue.community-invite"
    private let keychainAccount = "access-token"
    private var activeRealtimeSessionID: String?
    /// Realtime capture streams the same audio once per Soniox lane, so invite
    /// time must be charged per lane, not per wall-clock second.
    private var activeRealtimeLaneCount = 1
    /// Installed for the duration of an invite capture. While it is present
    /// the core asks it for a single-use key per connection, so no invite key
    /// is ever written into the shared credential runtime.
    private var laneCredentialProvider: CommunityInviteLaneCredentialProvider?

    var isActive: Bool { accessToken != nil }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "zulangue.community-invite.enabled")
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
        }
    }

    /// 把本机的分享身份登记到邀请码服务。
    ///
    /// 中继只放行登记过的 endpoint。**不做这一步，中继会拒绝每一个真实用户** ——
    /// 而且拒绝是安静的：局域网直连照常可用，只有跨网络需要中继时才连不上。
    ///
    /// 幂等，失败不打扰用户：登记只影响中继回落，直连和分享码都不依赖它。
    func enrollShareEndpoint(_ endpointID: String) async {
        guard isEnabled, let token = accessToken else { return }
        guard endpointID.isEmpty == false else { return }
        do {
            let _: EnrollResponse = try await request(
                path: "/v1/share-endpoint",
                method: "POST",
                body: ["endpoint_id": endpointID],
                token: token
            )
        } catch {
            // 登记不上只是失去中继回落，不该挡住分享本身。
        }
    }

    func refreshQuota() async {
        guard isEnabled, let token = accessToken else { return }
        do {
            let response: QuotaResponse = try await request(
                path: "/v1/quota",
                method: "GET",
                body: nil,
                token: token
            )
            remainingSeconds = response.remainingSeconds
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
        do {
            activeRealtimeSessionID = try await prepareCredential(
                requestedSeconds: 3 * 60 * 60 * lanes,
                laneCount: lanes
            )
            activeRealtimeLaneCount = lanes
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
        await provider.prime(laneCount: laneCount)
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
            fetch: { sessionID, token, count in
                try await CommunityInviteSession.fetchLaneKeys(
                    baseURL: baseURL,
                    sessionID: sessionID,
                    token: token,
                    count: count
                )
            },
            deliver: { requestID, result in
                Task { @MainActor in
                    guard let core = CoreClient.shared.core else { return }
                    switch result {
                    case .success(let key):
                        core.fulfillLaneCredential(requestId: requestID, apiKey: key)
                    case .failure(let failure):
                        core.failLaneCredential(
                            requestId: requestID,
                            message: failure.message,
                            terminal: failure.terminal
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
    ) async throws -> [String] {
        var request = URLRequest(url: baseURL.appending(path: "/v1/realtime-session/key"))
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
            throw LaneCredentialFailure.fromStatusCode(http.statusCode)
        }
        let decoded = try JSONDecoder().decode(LaneKeyResponse.self, from: data)
        return decoded.keys.map { $0.apiKey }
    }

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
        await settle(sessionID: sessionID, usedSeconds: usedSeconds * lanes)
        // The session's temporary key is spent; put the user's own saved key
        // back so post-recording features never run on a dead credential.
        restorePersonalKeyIfSaved()
    }

    /// Deletes the redeemed invitation from this Mac and returns the app to
    /// its normal credential state (the user's own saved key, if any).
    func removeInvite() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        SecItemDelete(query as CFDictionary)
        laneCredentialProvider?.discardPooledKeys()
        laneCredentialProvider = nil
        CoreClient.shared.core?.setLaneCredentialRequester(requester: nil)
        remainingSeconds = nil
        errorMessage = nil
        activeRealtimeSessionID = nil
        activeRealtimeLaneCount = 1
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

    private func settle(sessionID: String?, usedSeconds: Int) async {
        guard let token = accessToken,
              let sessionID
        else { return }
        do {
            let response: QuotaResponse = try await request(
                path: "/v1/realtime-session/settle",
                method: "POST",
                body: [
                    "session_id": sessionID,
                    "used_seconds": max(0, usedSeconds),
                ],
                token: token
            )
            remainingSeconds = response.remainingSeconds
        } catch {
            errorMessage = String(localized: "community_invite.unavailable")
        }
    }

    private var accessToken: String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func saveAccessToken(_ token: String) throws {
        let data = Data(token.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        SecItemDelete(query as CFDictionary)
        let insert = query.merging([
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]) { _, new in new }
        guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else {
            throw CommunityInviteError.secureStorageFailed
        }
    }

    private func request<Response: Decodable>(
        path: String,
        method: String,
        body: [String: Any]?,
        token: String?
    ) async throws -> Response {
        var request = URLRequest(url: baseURL.appending(path: path))
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
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else { throw CommunityInviteError.requestFailed }
        return try JSONDecoder().decode(Response.self, from: data)
    }
}

private struct EnrollResponse: Decodable {
    let status: String
}

private struct RedeemResponse: Decodable {
    let accessToken: String
    let remainingSeconds: Int

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case remainingSeconds = "remaining_seconds"
    }
}

private struct QuotaResponse: Decodable {
    let remainingSeconds: Int

    enum CodingKeys: String, CodingKey {
        case remainingSeconds = "remaining_seconds"
    }
}

private struct RealtimeSessionResponse: Decodable {
    let sessionID: String
    let reservedSeconds: Int
    let apiKey: String

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case reservedSeconds = "reserved_seconds"
        case apiKey = "api_key"
    }
}

/// One batch of single-use lane keys. The service also mirrors a single key
/// into flat fields for the legacy path; only the array is read here.
private struct LaneKeyResponse: Decodable {
    struct Key: Decodable {
        let apiKey: String

        enum CodingKeys: String, CodingKey {
            case apiKey = "api_key"
        }
    }

    let keys: [Key]
}

private enum CommunityInviteError: Error, LocalizedError {
    case requestFailed
    case secureStorageFailed
    case personalKeyRequired
    case realtimeCaptureActive

    var errorDescription: String? {
        switch self {
        case .requestFailed, .secureStorageFailed:
            return nil
        case .personalKeyRequired:
            return String(localized: "community_invite.async.needs_personal_key")
        case .realtimeCaptureActive:
            return String(localized: "community_invite.async.wait_for_recording")
        }
    }
}
