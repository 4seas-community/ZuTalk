import Combine
import Foundation

/// A rebuildable, session-filtered view of a builtin transcript Loro document.
/// Rust owns projection and persistence; this store only turns marked Loro runs
/// into stable SwiftUI rows for the selected session.
struct NotebookTranscriptLine: Identifiable, Equatable {
    let id: String
    let startMs: UInt64
    let text: String
}

@MainActor
protocol NotebookTranscriptEditorClienting: AnyObject {
    func openEditor(notebookId: String, tabId: String) throws
    func closeEditor(notebookId: String, tabId: String) throws
    func registerEditorCallback(
        notebookId: String,
        tabId: String,
        callback: any FfiEditorCallback
    ) throws
    func unregisterEditorCallback(notebookId: String, tabId: String) throws
    func editorDelta(notebookId: String, tabId: String) throws -> String
    func isEditorWritable(notebookId: String, tabId: String) throws -> Bool
    func replaceEditorText(
        notebookId: String,
        tabId: String,
        position: UInt64,
        length: UInt64,
        text: String
    ) throws
}

@MainActor
private final class LiveNotebookTranscriptEditorClient: NotebookTranscriptEditorClienting {
    private var core: ZulangueCore? { CoreClient.shared.core }

    func openEditor(notebookId: String, tabId: String) throws {
        guard let core else { throw NotebookCaptureClientError.ffiUnavailable }
        try core.openEditor(notebookId: notebookId, tabId: tabId)
    }

    func closeEditor(notebookId: String, tabId: String) throws {
        guard let core else { throw NotebookCaptureClientError.ffiUnavailable }
        try core.closeEditor(notebookId: notebookId, tabId: tabId)
    }

    func registerEditorCallback(
        notebookId: String,
        tabId: String,
        callback: any FfiEditorCallback
    ) throws {
        guard let core else { throw NotebookCaptureClientError.ffiUnavailable }
        try core.registerEditorCallback(notebookId: notebookId, tabId: tabId, callback: callback)
    }

    func unregisterEditorCallback(notebookId: String, tabId: String) throws {
        guard let core else { throw NotebookCaptureClientError.ffiUnavailable }
        try core.unregisterEditorCallback(notebookId: notebookId, tabId: tabId)
    }

    func editorDelta(notebookId: String, tabId: String) throws -> String {
        guard let core else { throw NotebookCaptureClientError.ffiUnavailable }
        return try core.getEditorDelta(notebookId: notebookId, tabId: tabId)
    }

    func isEditorWritable(notebookId: String, tabId: String) throws -> Bool {
        guard let core else { throw NotebookCaptureClientError.ffiUnavailable }
        return try core.isEditorWritable(notebookId: notebookId, tabId: tabId)
    }

    func replaceEditorText(
        notebookId: String,
        tabId: String,
        position: UInt64,
        length: UInt64,
        text: String
    ) throws {
        guard let core else { throw NotebookCaptureClientError.ffiUnavailable }
        try core.applyEdit(
            notebookId: notebookId,
            tabId: tabId,
            op: .replace(pos: position, len: length, text: text)
        )
    }
}

@MainActor
final class NotebookTranscriptProjectionStore: ObservableObject {
    static let shared = NotebookTranscriptProjectionStore()

    @Published private(set) var linesBySession: [String: [NotebookTranscriptLine]] = [:]
    @Published private(set) var editableBySession: [String: Bool] = [:]
    @Published private(set) var asyncProviderStateBySession: [String: String] = [:]
    @Published private(set) var asyncProjectionStateBySession: [String: NotebookAsyncProjectionState] = [:]
    @Published private(set) var asyncProjectionErrorBySession: [String: String] = [:]
    @Published private(set) var retryingAsyncProjectionSessions: Set<String> = []
    @Published private(set) var requestingAsyncTranscriptionSessions: Set<String> = []

    fileprivate struct EditorTarget: Equatable {
        let notebookId: String
        let tabId: String

        var key: String { "\(notebookId):\(tabId)" }
    }

    struct Attachment: Hashable {
        fileprivate let id: UUID
        fileprivate let targetKey: String
        fileprivate let generation: UInt64
    }

    private struct Registration {
        let target: EditorTarget
        let sessionId: String
        let generation: UInt64
        var leaseIds: Set<UUID>
    }

    private var registrationsByTargetKey: [String: Registration] = [:]
    private var targetKeyBySessionId: [String: String] = [:]
    private var callbacks: [String: NotebookTranscriptProjectionCallback] = [:]
    private let captureClient: NotebookCaptureClienting
    private let editorClient: NotebookTranscriptEditorClienting
    private var nextGeneration: UInt64 = 0

    init(
        captureClient: NotebookCaptureClienting? = nil,
        editorClient: NotebookTranscriptEditorClienting? = nil
    ) {
        self.captureClient = captureClient ?? RustNotebookCaptureClient()
        self.editorClient = editorClient ?? LiveNotebookTranscriptEditorClient()
    }

    @discardableResult
    func attachIfNeeded(
        sessionId: String,
        notebookId: String,
        tabId: String
    ) -> Attachment? {
        let target = EditorTarget(notebookId: notebookId, tabId: tabId)

        if var registration = registrationsByTargetKey[target.key],
           registration.sessionId == sessionId {
            let leaseId = UUID()
            registration.leaseIds.insert(leaseId)
            registrationsByTargetKey[target.key] = registration
            refresh(target: target)
            refreshAsyncProjectionState(sessionId: sessionId)
            return Attachment(
                id: leaseId,
                targetKey: target.key,
                generation: registration.generation
            )
        }

        if let oldTargetKey = targetKeyBySessionId[sessionId] {
            tearDown(targetKey: oldTargetKey)
        }
        if registrationsByTargetKey[target.key] != nil {
            tearDown(targetKey: target.key)
        }
        refreshAsyncProjectionState(sessionId: sessionId)

        do {
            try editorClient.openEditor(notebookId: notebookId, tabId: tabId)
        } catch {
            return nil
        }

        linesBySession[sessionId] = []
        editableBySession[sessionId] = (try? editorClient.isEditorWritable(
            notebookId: notebookId,
            tabId: tabId
        )) ?? false

        nextGeneration &+= 1
        let generation = nextGeneration
        let callback = NotebookTranscriptProjectionCallback(
            store: self,
            target: target,
            registrationGeneration: generation
        )
        callbacks[target.key] = callback
        do {
            try editorClient.registerEditorCallback(
                notebookId: notebookId,
                tabId: tabId,
                callback: callback
            )
        } catch {
            callbacks.removeValue(forKey: target.key)
            try? editorClient.closeEditor(notebookId: notebookId, tabId: tabId)
            clearPublishedState(sessionId: sessionId)
            return nil
        }

        let leaseId = UUID()
        registrationsByTargetKey[target.key] = Registration(
            target: target,
            sessionId: sessionId,
            generation: generation,
            leaseIds: [leaseId]
        )
        targetKeyBySessionId[sessionId] = target.key
        refresh(target: target)
        return Attachment(id: leaseId, targetKey: target.key, generation: generation)
    }

    func detach(_ attachment: Attachment) {
        guard var registration = registrationsByTargetKey[attachment.targetKey],
              registration.generation == attachment.generation,
              registration.leaseIds.remove(attachment.id) != nil
        else { return }

        if registration.leaseIds.isEmpty {
            tearDown(targetKey: attachment.targetKey)
        } else {
            registrationsByTargetKey[attachment.targetKey] = registration
        }
    }

    /// Replays only Rust's persisted provider result into the builtin Async
    /// Transcript document. No audio, credential, or provider call is reachable
    /// through this client method.
    func retryAsyncProjection(sessionId: String) throws {
        guard retryingAsyncProjectionSessions.contains(sessionId) == false else { return }
        retryingAsyncProjectionSessions.insert(sessionId)
        asyncProjectionErrorBySession[sessionId] = nil
        defer { retryingAsyncProjectionSessions.remove(sessionId) }

        do {
            let event = try captureClient.retryNotebookAsyncProjection(sessionId: sessionId)
            applyAsyncState(event)
            if let targetKey = targetKeyBySessionId[sessionId],
               let registration = registrationsByTargetKey[targetKey] {
                refresh(target: registration.target)
            }
        } catch {
            asyncProjectionErrorBySession[sessionId] = error.localizedDescription
            refreshAsyncProjectionState(sessionId: sessionId)
            throw error
        }
    }

    func requestAsyncTranscription(sessionId: String, notebookId: String) async throws {
        guard requestingAsyncTranscriptionSessions.contains(sessionId) == false else { return }
        requestingAsyncTranscriptionSessions.insert(sessionId)
        defer { requestingAsyncTranscriptionSessions.remove(sessionId) }

        let run = try captureClient
            .listNotebookCaptureHistory(notebookId: notebookId)
            .first(where: { $0.sessionId == sessionId })
        let durationSeconds = Int(
            ((run?.durationMs ?? 0) + 999) / 1_000
        )
        let reservationSessionID = try await CommunityInviteSession.shared.prepareAsyncCredential(
            requestedSeconds: max(1, durationSeconds)
        )
        do {
            let event = try captureClient.requestNotebookAsyncTranscription(
                sessionId: sessionId
            )
            applyAsyncState(event)
            Task { @MainActor [weak self] in
                await self?.settleAsyncWhenTerminal(
                    sessionId: sessionId,
                    durationSeconds: durationSeconds,
                    reservationSessionID: reservationSessionID
                )
            }
        } catch {
            await CommunityInviteSession.shared.settleAsyncSession(
                sessionID: reservationSessionID,
                usedSeconds: 0
            )
            throw error
        }
    }

    private func settleAsyncWhenTerminal(
        sessionId: String,
        durationSeconds: Int,
        reservationSessionID: String?
    ) async {
        for _ in 0..<360 {
            try? await Task.sleep(for: .seconds(5))
            guard let event = try? captureClient.getNotebookCaptureSessionEvent(
                sessionId: sessionId
            ) else { continue }
            applyAsyncState(event)
            if event.postStopAsyncState == "completed" {
                await CommunityInviteSession.shared.settleAsyncSession(
                    sessionID: reservationSessionID,
                    usedSeconds: durationSeconds
                )
                return
            }
            if event.postStopAsyncState == "failed" {
                await CommunityInviteSession.shared.settleAsyncSession(
                    sessionID: reservationSessionID,
                    usedSeconds: 0
                )
                return
            }
        }
        await CommunityInviteSession.shared.settleAsyncSession(
            sessionID: reservationSessionID,
            usedSeconds: 0
        )
    }

    func replaceSegment(sessionId: String, segmentIndex: Int, text: String) {
        guard let targetKey = targetKeyBySessionId[sessionId],
              let target = registrationsByTargetKey[targetKey]?.target,
              let delta = try? editorClient.editorDelta(
                  notebookId: target.notebookId,
                  tabId: target.tabId
              )
        else { return }

        let segments = Self.parse(delta).filter { $0.sessionId == sessionId }
        guard segments.indices.contains(segmentIndex) else { return }
        let segment = segments[segmentIndex]
        try? editorClient.replaceEditorText(
            notebookId: target.notebookId,
            tabId: target.tabId,
            position: UInt64(segment.scalarStart),
            length: UInt64(segment.scalarEnd - segment.scalarStart),
            text: text
        )
    }

    fileprivate func documentDidChange(
        target: EditorTarget,
        registrationGeneration: UInt64
    ) {
        guard registrationsByTargetKey[target.key]?.generation == registrationGeneration else {
            return
        }
        refresh(target: target)
    }

    private func tearDown(targetKey: String) {
        guard let registration = registrationsByTargetKey.removeValue(forKey: targetKey) else {
            return
        }
        let target = registration.target
        try? editorClient.unregisterEditorCallback(
            notebookId: target.notebookId,
            tabId: target.tabId
        )
        try? editorClient.closeEditor(notebookId: target.notebookId, tabId: target.tabId)
        targetKeyBySessionId.removeValue(forKey: registration.sessionId)
        callbacks.removeValue(forKey: targetKey)
        clearPublishedState(sessionId: registration.sessionId)
    }

    private func clearPublishedState(sessionId: String) {
        linesBySession.removeValue(forKey: sessionId)
        editableBySession.removeValue(forKey: sessionId)
        asyncProviderStateBySession.removeValue(forKey: sessionId)
        asyncProjectionStateBySession.removeValue(forKey: sessionId)
        asyncProjectionErrorBySession.removeValue(forKey: sessionId)
        retryingAsyncProjectionSessions.remove(sessionId)
    }

    private func refreshAsyncProjectionState(sessionId: String) {
        do {
            applyAsyncState(try captureClient.getNotebookCaptureSessionEvent(sessionId: sessionId))
        } catch {
            asyncProjectionErrorBySession[sessionId] = error.localizedDescription
        }
    }

    private func applyAsyncState(_ event: NotebookCaptureEventDTO) {
        asyncProviderStateBySession[event.sessionId] = event.postStopAsyncState
        asyncProjectionStateBySession[event.sessionId] = event.postStopAsyncProjectionState
        asyncProjectionErrorBySession[event.sessionId] = nil
    }

    private func refresh(target: EditorTarget) {
        guard let sessionId = registrationsByTargetKey[target.key]?.sessionId,
              let delta = try? editorClient.editorDelta(
                  notebookId: target.notebookId,
                  tabId: target.tabId
              )
        else { return }

        linesBySession[sessionId] = Self.parse(delta)
            .filter { $0.sessionId == sessionId }
            .map {
                NotebookTranscriptLine(
                    id: $0.segmentId,
                    startMs: $0.timestampMs,
                    text: $0.text
                )
            }
        editableBySession[sessionId] = (try? editorClient.isEditorWritable(
            notebookId: target.notebookId,
            tabId: target.tabId
        )) ?? false
    }

    private struct ParsedSegment {
        let sessionId: String
        let segmentId: String
        let timestampMs: UInt64
        var text: String
        let scalarStart: Int
        var scalarEnd: Int
    }

    private static func parse(_ json: String) -> [ParsedSegment] {
        var result: [ParsedSegment] = []
        var scalarPosition = 0

        for operation in LoroDeltaParser.parse(json) {
            let runLength = operation.insert.unicodeScalars.count
            defer { scalarPosition += runLength }
            guard let attributes = operation.attributes else { continue }

            let segmentId: String
            if let value = attributes["segment_id"] as? String {
                segmentId = value
            } else if let value = attributes["segment_id"] as? NSNumber {
                segmentId = value.stringValue
            } else {
                continue
            }

            let sessionId = attributes["session_id"] as? String ?? ""
            let timestampMs = (attributes["timestamp_ms"] as? NSNumber)?.uint64Value ?? 0

            if let last = result.last,
               last.sessionId == sessionId,
               last.segmentId == segmentId,
               last.scalarEnd == scalarPosition {
                var updated = last
                updated.text += operation.insert
                updated.scalarEnd = scalarPosition + runLength
                result[result.count - 1] = updated
            } else {
                result.append(
                    ParsedSegment(
                        sessionId: sessionId,
                        segmentId: segmentId,
                        timestampMs: timestampMs,
                        text: operation.insert,
                        scalarStart: scalarPosition,
                        scalarEnd: scalarPosition + runLength
                    )
                )
            }
        }
        return result
    }
}

private final class NotebookTranscriptProjectionCallback: FfiEditorCallback, @unchecked Sendable {
    private weak var store: NotebookTranscriptProjectionStore?
    private let target: NotebookTranscriptProjectionStore.EditorTarget
    private let registrationGeneration: UInt64

    init(
        store: NotebookTranscriptProjectionStore,
        target: NotebookTranscriptProjectionStore.EditorTarget,
        registrationGeneration: UInt64
    ) {
        self.store = store
        self.target = target
        self.registrationGeneration = registrationGeneration
    }

    func onDocChanged(docId: String, generation: UInt64) {
        Task { @MainActor [weak store] in
            _ = docId
            _ = generation
            store?.documentDidChange(
                target: target,
                registrationGeneration: registrationGeneration
            )
        }
    }
}
