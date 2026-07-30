import Foundation
import Combine
import Security

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

    func prepareRealtimeCredential() async throws {
        activeRealtimeSessionID = try await prepareCredential(
            requestedSeconds: 3 * 60 * 60
        )
    }

    func prepareAsyncCredential(requestedSeconds: Int) async throws -> String? {
        try await prepareCredential(
            requestedSeconds: min(max(1, requestedSeconds), 5 * 60 * 60)
        )
    }

    private func prepareCredential(requestedSeconds: Int) async throws -> String? {
        guard let token = accessToken else { return nil }
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
        await settle(sessionID: sessionID, usedSeconds: usedSeconds)
    }

    func settleAsyncSession(sessionID: String?, usedSeconds: Int) async {
        await settle(sessionID: sessionID, usedSeconds: usedSeconds)
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
