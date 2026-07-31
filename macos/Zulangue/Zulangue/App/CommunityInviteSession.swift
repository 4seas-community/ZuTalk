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

    private let baseURL = URL(string: "https://zulangue-invite.exe.xyz")!
    private let keychainService = "xyz.voice.zulangue.community-invite"
    private let keychainAccount = "access-token"
    private var activeRealtimeSessionID: String?
    /// Realtime capture streams the same audio once per Soniox lane, so invite
    /// time must be charged per lane, not per wall-clock second.
    private var activeRealtimeLaneCount = 1

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
        guard isEnabled, accessToken != nil else { return .notUsed }
        do {
            activeRealtimeSessionID = try await prepareCredential(
                requestedSeconds: 3 * 60 * 60 * lanes
            )
            activeRealtimeLaneCount = lanes
            return .invite
        } catch {
            guard restorePersonalKeyIfSaved() else { throw error }
            errorMessage = String(localized: "community_invite.unavailable")
            return .personalKeyFallback
        }
    }

    /// Returns the reservation session ID, or nil when the request runs on
    /// the user's own key (invite disabled, or unavailable with a saved key).
    func prepareAsyncCredential(requestedSeconds: Int) async throws -> String? {
        guard isEnabled, accessToken != nil else { return nil }
        do {
            return try await prepareCredential(
                requestedSeconds: min(max(1, requestedSeconds), 5 * 60 * 60)
            )
        } catch {
            guard restorePersonalKeyIfSaved() else { throw error }
            errorMessage = String(localized: "community_invite.unavailable")
            return nil
        }
    }

    private func prepareCredential(requestedSeconds: Int) async throws -> String? {
        guard isEnabled, let token = accessToken else { return nil }
        let response: RealtimeSessionResponse = try await request(
            path: "/v1/realtime-session",
            method: "POST",
            body: ["requested_seconds": requestedSeconds],
            token: token
        )
        try ProviderCredentialSession.shared.activateProcessOnlyCredential(
            response.apiKey,
            for: .soniox
        )
        remainingSeconds = max(0, (remainingSeconds ?? 0) - response.reservedSeconds)
        return response.sessionID
    }

    func settleRealtimeSession(usedSeconds: Int) async {
        let sessionID = activeRealtimeSessionID
        activeRealtimeSessionID = nil
        let lanes = activeRealtimeLaneCount
        activeRealtimeLaneCount = 1
        await settle(sessionID: sessionID, usedSeconds: usedSeconds * lanes)
        // The session's temporary key is spent; put the user's own saved key
        // back so post-recording features never run on a dead credential.
        restorePersonalKeyIfSaved()
    }

    func settleAsyncSession(sessionID: String?, usedSeconds: Int) async {
        await settle(sessionID: sessionID, usedSeconds: usedSeconds)
        // Async settles can fire minutes later; never stomp the temporary key
        // of a realtime capture that is still running.
        if activeRealtimeSessionID == nil {
            restorePersonalKeyIfSaved()
        }
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
        remainingSeconds = nil
        errorMessage = nil
        activeRealtimeSessionID = nil
        activeRealtimeLaneCount = 1
        setEnabled(false)
        // With no saved key this clears any leftover temporary key from the
        // runtime; with one it reactivates the user's own credential.
        try? ProviderCredentialSession.shared.activateSavedCredentials()
    }

    @discardableResult
    private func restorePersonalKeyIfSaved() -> Bool {
        let hasSavedKey = ProviderCredentialSession.shared.snapshot()
            .contains { $0.account == .soniox && $0.isSaved }
        guard hasSavedKey else { return false }
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

private enum CommunityInviteError: Error {
    case requestFailed
    case secureStorageFailed
}
