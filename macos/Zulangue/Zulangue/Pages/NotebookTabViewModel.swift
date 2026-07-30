import Foundation

enum NotebookTabDisplayType: Equatable {
    case realtimeTranscript
    case asyncTranscript
    case manualNote
}

enum NotebookTabStatus: Equatable {
    case ready
    case pending
    case failed
    case live

    init(taskStatus: String) {
        switch taskStatus {
        case "pending", "running":
            self = .pending
        case "failed", "cancelled", "canceled":
            self = .failed
        default:
            self = .ready
        }
    }
}

/// Realtime tab status is ephemeral UI state. The active capture store is the
/// sole authority; a tab reload must never persist `.live` after capture ends.
enum NotebookRealtimeTabStatusPolicy {
    static func resolve(
        displayType: NotebookTabDisplayType,
        baseStatus: NotebookTabStatus,
        tabNotebookId: String,
        activeNotebookId: String?,
        activeSessionId: String?,
        captureIsActive: Bool
    ) -> NotebookTabStatus {
        guard displayType == .realtimeTranscript else { return baseStatus }
        guard captureIsActive,
              tabNotebookId == activeNotebookId,
              activeSessionId != nil else {
            return .ready
        }
        return .live
    }
}

/// Persistent task-queue state for the most recent explicit asynchronous
/// transcription of one recording session. The task queue is authoritative;
/// no placeholder document is created for pending/failed state.
struct TranscriptionTaskSnapshot: Equatable {
    let taskId: String
    let status: String
    let errorMessage: String?

    var tabStatus: NotebookTabStatus { NotebookTabStatus(taskStatus: status) }
}

enum TranscriptionTaskIndex {
    static func load(core: any ZulangueCoreProtocol) -> [String: TranscriptionTaskSnapshot] {
        guard let tasks = try? core.listTasks(statusFilter: nil) else { return [:] }
        return makeIndex(tasks: tasks)
    }

    /// `listTasks` is ordered newest-first by the Rust queue. The persisted task
    /// payload is authoritative for its session.
    static func makeIndex(tasks: [TaskInfoDto]) -> [String: TranscriptionTaskSnapshot] {
        var result: [String: TranscriptionTaskSnapshot] = [:]

        for task in tasks {
            guard let sessionId = transcribeSessionId(from: task.payloadJson) else {
                continue
            }
            // The first task for a session is the newest one because listTasks is
            // stable newest-first (created_at, rowid). Older retries cannot replace it.
            guard result[sessionId] == nil else { continue }
            let snapshot = TranscriptionTaskSnapshot(
                taskId: task.id,
                status: task.status,
                errorMessage: task.errorMsg
            )
            result[sessionId] = snapshot
        }
        return result
    }

    static func transcribeSessionId(from payloadJson: String) -> String? {
        guard let data = payloadJson.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let taskPayload: [String: Any]
        if let payloadType = root["payload_type"] as? String {
            guard payloadType == "transcribe",
                  let envelopePayload = root["payload"] as? [String: Any] else {
                return nil
            }
            taskPayload = envelopePayload
        } else {
            taskPayload = root
        }
        let transcribe = (taskPayload["Transcribe"] as? [String: Any])
            ?? (taskPayload["transcribe"] as? [String: Any])
        return transcribe?["session_id"] as? String
    }
}

struct NotebookTabSessionLink: Equatable {
    let notebookId: String
    let sessionId: String
    let sectionTitle: String?
}

struct NotebookTabViewModel: Identifiable, Equatable {
    let id: String
    let notebookId: String
    let tabId: String
    let displayType: NotebookTabDisplayType
    let documentId: String
    let sessionLink: NotebookTabSessionLink?
    let title: String
    let status: NotebookTabStatus
    let position: Int64

    static func makeTabs(
        notebookId: String,
        backendTabs: [FfiNotebookTab],
        projectionsByTabId: [String: [FfiNotebookSessionProjection]],
        realtimeSessionId: String?,
        selectedSessionId: String? = nil,
        transcriptionTasksBySessionId: [String: TranscriptionTaskSnapshot] = [:]
    ) -> [NotebookTabViewModel] {
        let builtinKinds = Set([
            "realtime_transcript",
            "async_transcript",
            "manual_note",
        ])

        // A Notebook has exactly three backend-owned builtin tabs and can be
        // reopened before it has any sessions.
        return backendTabs
            .filter {
                $0.deletedAt == nil
                    && builtinKinds.contains($0.builtinKind)
            }
            .sorted { lhs, rhs in
                if lhs.position == rhs.position { return lhs.createdAt < rhs.createdAt }
                return lhs.position < rhs.position
            }
            .compactMap { tab -> NotebookTabViewModel? in
                guard let displayType = displayType(for: tab) else { return nil }
                let scopedSessionId = selectedSessionId
                    ?? realtimeSessionId.flatMap { $0.isEmpty ? nil : $0 }
                return from(
                    tab: tab,
                    displayType: displayType,
                    projections: projectionsByTabId[tab.id] ?? [],
                    selectedSessionId: scopedSessionId,
                    transcriptionTask: scopedSessionId.flatMap {
                        transcriptionTasksBySessionId[$0]
                    }
                )
            }
    }

    private static func from(
        tab: FfiNotebookTab,
        displayType: NotebookTabDisplayType,
        projections: [FfiNotebookSessionProjection],
        selectedSessionId: String?,
        transcriptionTask: TranscriptionTaskSnapshot?
    ) -> NotebookTabViewModel {
        let selectedProjection = selectedSessionId.flatMap { sessionId in
            projections.first { $0.sessionId == sessionId }
        } ?? projections.first
        let sessionLink = sessionLink(projection: selectedProjection)
        let status: NotebookTabStatus
        if displayType == .asyncTranscript, let transcriptionTask {
            status = transcriptionTask.tabStatus
        } else {
            status = .ready
        }
        return NotebookTabViewModel(
            id: tab.id,
            notebookId: tab.notebookId,
            tabId: tab.id,
            displayType: displayType,
            documentId: tab.docId,
            sessionLink: sessionLink,
            title: displayTitle(displayType: displayType),
            status: status,
            position: tab.position
        )
    }

    private static func displayType(for tab: FfiNotebookTab) -> NotebookTabDisplayType? {
        switch tab.builtinKind {
        case "realtime_transcript": return .realtimeTranscript
        case "async_transcript": return .asyncTranscript
        case "manual_note": return .manualNote
        default: return nil
        }
    }

    private static func displayTitle(displayType: NotebookTabDisplayType) -> String {
        switch displayType {
        case .realtimeTranscript:
            return String(localized: "editor.tab.transcript")
        case .asyncTranscript:
            return String(localized: "doc.transcript_hd")
        case .manualNote:
            return String(localized: "doc.scratchpad")
        }
    }

    private static func sessionLink(
        projection: FfiNotebookSessionProjection?
    ) -> NotebookTabSessionLink? {
        if let projection {
            return NotebookTabSessionLink(
                notebookId: projection.notebookId,
                sessionId: projection.sessionId,
                sectionTitle: projection.sectionTitle
            )
        }
        return nil
    }

}
