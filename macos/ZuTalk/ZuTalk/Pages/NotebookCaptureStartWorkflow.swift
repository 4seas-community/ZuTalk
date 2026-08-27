import AppKit
import Combine
import SwiftUI

// MARK: - Notebook-only capture controls

@MainActor
struct NotebookCaptureStartCoordinator {
    let capture: ActiveBilingualTranscriptStore
    let navigation: MainNavigationStore

    func start(notebookId: String) async throws {
        try await capture.start(notebookId: notebookId)
        guard let sessionId = capture.sessionId else {
            throw NotebookCaptureClientError.captureNotActive
        }
        navigation.openRealtimeTranscript(
            notebookID: notebookId,
            selectedSessionID: sessionId
        )
    }
}

/// Process-wide lease for the complete start workflow, including invite
/// credential preparation before the capture store takes its microphone lease.
@MainActor
final class NotebookCaptureStartWorkflowGate {
    struct Lease: Equatable {
        fileprivate let id: UUID
    }

    static let shared = NotebookCaptureStartWorkflowGate()
    private var activeLeaseID: UUID?

    func acquire() -> Lease? {
        guard activeLeaseID == nil else { return nil }
        let lease = Lease(id: UUID())
        activeLeaseID = lease.id
        return lease
    }

    func release(_ lease: Lease) {
        guard activeLeaseID == lease.id else { return }
        activeLeaseID = nil
    }
}

/// Orders the durable profile commit and any remote credential reservation for
/// every capture entry point. The returned preparation must complete before
/// the caller starts audio capture.
@MainActor
enum NotebookCaptureStartPreparationWorkflow {
    static func prepare(
        enableRealtimeIfNeeded: Bool,
        prepareProfile: @MainActor (Bool) async throws -> NotebookCaptureProfileDTO,
        prepareRealtimeCredential: @MainActor (Int) async throws -> CommunityInvitePreparation
    ) async throws -> CommunityInvitePreparation {
        let finalProfile = try await prepareProfile(enableRealtimeIfNeeded)
        guard finalProfile.remoteRealtimeEnabled else { return .notUsed }

        return try await prepareRealtimeCredential(
            remoteLaneCount(selectedLanguages: finalProfile.selectedLanguages)
        )
    }

    /// Mirrors the Rust core's `remote_stream_plan`: one or two languages run
    /// on a single WebSocket, three or more open one canonical lane plus one
    /// translation lane per language. Invite billing charges per lane.
    static func remoteLaneCount(selectedLanguages: [String]) -> Int {
        selectedLanguages.count <= 2 ? 1 : selectedLanguages.count + 1
    }
}

enum NotebookCaptureSettingsPersistenceState: Equatable {
    case loading
    case saving
    case saved
    case loadFailed(String)
    case saveFailed(String)
}

struct NotebookCaptureProfileStartBlockedError: LocalizedError, Equatable {
    let reason: String

    var errorDescription: String? { reason }
}

/// A dedicated persistence seam for the settings editor. The editor never
/// observes `ActiveBilingualTranscriptStore.profile`: that value can represent
/// an immutable active or historical run snapshot, not the Notebook's current
/// persisted capture profile.
@MainActor
protocol NotebookCaptureProfilePersisting: AnyObject {
    var isCaptureActive: Bool { get }
    var lastError: String? { get }

    func profileForNotebook(_ notebookId: String) -> NotebookCaptureProfileDTO
    @discardableResult
    func saveProfile(_ candidate: NotebookCaptureProfileDTO) throws -> NotebookCaptureProfileDTO
}

extension ActiveBilingualTranscriptStore: NotebookCaptureProfilePersisting {}
