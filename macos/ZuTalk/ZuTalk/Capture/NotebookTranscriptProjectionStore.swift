import Combine
import Foundation

/// A rebuildable, session-filtered view of a builtin transcript Loro document.
/// Rust owns projection and persistence; this store only turns marked Loro runs
/// into stable SwiftUI rows for the selected session.
struct NotebookTranscriptLine: Identifiable, Equatable {
    let id: String
    /// Provider timing is optional because legacy marked documents may only
    /// carry segment/session ownership. Missing timing must not become 00:00.
    let startMs: UInt64?
    let endMs: UInt64?
    let sourceLanguage: String?
    /// Anonymous label scoped to the async provider result. It is display-only
    /// and is never a realtime SessionSpeaker identity.
    let providerSpeakerLabel: String?
    let text: String
}

enum NotebookTranscriptProjectionEditError: Error, Equatable {
    case unavailable
    case staleSegment
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
    private var core: ZuTalkCore? { CoreClient.shared.core }

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
    @Published private(set) var documentReadErrorBySession: [String: String] = [:]
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

    func requestAsyncTranscription(sessionId: String) async throws {
        guard requestingAsyncTranscriptionSessions.contains(sessionId) == false else { return }
        requestingAsyncTranscriptionSessions.insert(sessionId)
        defer { requestingAsyncTranscriptionSessions.remove(sessionId) }

        // After-stop transcription always runs on the user's own key. Invite
        // temporary keys are WebSocket-scoped, so the async file API would
        // reject them, and the upload must happen under the account that
        // consented to it.
        try CommunityInviteSession.shared.preparePersonalKeyForAsyncTranscription()
        let event = try captureClient.requestNotebookAsyncTranscription(
            sessionId: sessionId
        )
        applyAsyncState(event)
        Task { @MainActor [weak self] in
            await self?.pollAsyncStateUntilTerminal(sessionId: sessionId)
        }
    }

    private func pollAsyncStateUntilTerminal(sessionId: String) async {
        for _ in 0..<360 {
            try? await MontereyTaskSleep.seconds(5)
            guard let event = try? captureClient.getNotebookCaptureSessionEvent(
                sessionId: sessionId
            ) else { continue }
            applyAsyncState(event)
            if event.postStopAsyncState == "completed" || event.postStopAsyncState == "failed" {
                return
            }
        }
    }

    func replaceSegment(sessionId: String, segmentId: String, text: String) throws {
        guard let targetKey = targetKeyBySessionId[sessionId],
              let target = registrationsByTargetKey[targetKey]?.target else {
            throw NotebookTranscriptProjectionEditError.unavailable
        }

        let delta: String
        do {
            delta = try editorClient.editorDelta(
                notebookId: target.notebookId,
                tabId: target.tabId
            )
            documentReadErrorBySession[sessionId] = nil
        } catch {
            documentReadErrorBySession[sessionId] = error.localizedDescription
            editableBySession[sessionId] = false
            throw error
        }

        guard let segment = Self.parse(delta).first(where: {
            $0.sessionId == sessionId && $0.segmentId == segmentId
        }) else {
            throw NotebookTranscriptProjectionEditError.staleSegment
        }
        try editorClient.replaceEditorText(
            notebookId: target.notebookId,
            tabId: target.tabId,
            position: UInt64(segment.scalarStart),
            length: UInt64(segment.scalarEnd - segment.scalarStart),
            text: text
        )
    }

    /// Re-reads the currently attached transcript document without releasing
    /// its editor lease. A failed retry therefore keeps the last good rows on
    /// screen and can be attempted again without rebuilding view identity.
    func retryDocumentRead(sessionId: String) throws {
        guard let targetKey = targetKeyBySessionId[sessionId],
              let target = registrationsByTargetKey[targetKey]?.target else {
            throw NotebookTranscriptProjectionEditError.unavailable
        }
        do {
            try loadDocument(target: target, sessionId: sessionId)
        } catch {
            publishDocumentReadFailure(error, sessionId: sessionId)
            throw error
        }
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
        documentReadErrorBySession.removeValue(forKey: sessionId)
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
        guard let sessionId = registrationsByTargetKey[target.key]?.sessionId else { return }
        do {
            try loadDocument(target: target, sessionId: sessionId)
        } catch {
            // Keep the last good projection visible, but make it read-only and
            // publish the failure so the page can offer an explicit retry.
            publishDocumentReadFailure(error, sessionId: sessionId)
        }
    }

    private func loadDocument(target: EditorTarget, sessionId: String) throws {
        let delta = try editorClient.editorDelta(
            notebookId: target.notebookId,
            tabId: target.tabId
        )
        documentReadErrorBySession[sessionId] = nil

        linesBySession[sessionId] = Self.parse(delta)
            .filter { $0.sessionId == sessionId }
            .map {
                NotebookTranscriptLine(
                    id: $0.segmentId,
                    startMs: $0.startMs,
                    endMs: $0.endMs,
                    sourceLanguage: $0.sourceLanguage,
                    providerSpeakerLabel: $0.providerSpeakerLabel,
                    text: $0.text
                )
            }
        editableBySession[sessionId] = (try? editorClient.isEditorWritable(
            notebookId: target.notebookId,
            tabId: target.tabId
        )) ?? false
    }

    private func publishDocumentReadFailure(_ error: Error, sessionId: String) {
        documentReadErrorBySession[sessionId] = error.localizedDescription
        editableBySession[sessionId] = false
    }

    private struct ParsedSegment {
        let sessionId: String
        let segmentId: String
        var startMs: UInt64?
        var endMs: UInt64?
        var sourceLanguage: String?
        var providerSpeakerLabel: String?
        var text: String
        var scalarStart: Int
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
            let startMs = uint64Attribute(attributes, keys: ["timestamp_ms", "start_ms"])
            let endMs = uint64Attribute(attributes, keys: ["end_ms"])
            let sourceLanguage = stringAttribute(attributes, key: "source_language")
            let providerSpeakerLabel = stringAttribute(
                attributes,
                key: "provider_speaker_label"
            )

            if let last = result.last,
               last.sessionId == sessionId,
               last.segmentId == segmentId,
               last.scalarEnd == scalarPosition {
                var updated = last
                updated.text += operation.insert
                updated.scalarEnd = scalarPosition + runLength
                updated.startMs = updated.startMs ?? startMs
                if let endMs {
                    updated.endMs = max(updated.endMs ?? endMs, endMs)
                }
                updated.sourceLanguage = updated.sourceLanguage ?? sourceLanguage
                updated.providerSpeakerLabel = updated.providerSpeakerLabel
                    ?? providerSpeakerLabel
                result[result.count - 1] = updated
            } else {
                result.append(
                    ParsedSegment(
                        sessionId: sessionId,
                        segmentId: segmentId,
                        startMs: startMs,
                        endMs: endMs,
                        sourceLanguage: sourceLanguage,
                        providerSpeakerLabel: providerSpeakerLabel,
                        text: operation.insert,
                        scalarStart: scalarPosition,
                        scalarEnd: scalarPosition + runLength
                    )
                )
            }
        }
        return result.map(strippingRenderedTimestampPrefix)
    }

    /// Older Rust projections marked the rendered timestamp header and body as
    /// one segment. Strip only the exact header implied by that segment's
    /// timestamp metadata, so user-authored bracketed text is left untouched.
    private static func strippingRenderedTimestampPrefix(
        _ segment: ParsedSegment
    ) -> ParsedSegment {
        guard let startMs = segment.startMs else { return segment }

        let totalSeconds = startMs / 1_000
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        let prefix: String
        if hours > 0 {
            prefix = String(format: "[%02llu:%02llu:%02llu]\n", hours, minutes, seconds)
        } else {
            prefix = String(format: "[%02llu:%02llu]\n", minutes, seconds)
        }

        guard segment.text.hasPrefix(prefix) else { return segment }
        var stripped = segment
        stripped.text.removeFirst(prefix.count)
        stripped.scalarStart += prefix.unicodeScalars.count
        return stripped
    }

    private static func uint64Attribute(
        _ attributes: [String: Any],
        keys: [String]
    ) -> UInt64? {
        for key in keys {
            if let value = attributes[key] as? NSNumber {
                return value.uint64Value
            }
            if let value = attributes[key] as? String,
               let parsed = UInt64(value) {
                return parsed
            }
        }
        return nil
    }

    private static func stringAttribute(
        _ attributes: [String: Any],
        key: String
    ) -> String? {
        guard let value = attributes[key] as? String else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}

/// Owns one view lease and releases it only after every focused transcript row
/// has finished its blur/disappear commit. This keeps the Rust editor target
/// alive across a tab switch without making the projection store retain views.
@MainActor
final class NotebookTranscriptProjectionAttachmentCoordinator: ObservableObject {
    @Published private(set) var attachmentFailed = false

    private let store: NotebookTranscriptProjectionStore
    private var attachment: NotebookTranscriptProjectionStore.Attachment?
    private var pendingEditSegmentIds: Set<String> = []
    private var detachRequested = false

    init(store: NotebookTranscriptProjectionStore) {
        self.store = store
    }

    @discardableResult
    func attach(
        sessionId: String,
        notebookId: String,
        tabId: String
    ) -> Bool {
        // The view may become visible again before its disappearance commit
        // finishes. Renewing ownership cancels the queued detach.
        detachRequested = false
        // A retry button cannot safely replace the editor target while a row
        // is still flushing. The pending edit completion will leave the
        // existing attachment intact, after which the user can retry again.
        guard pendingEditSegmentIds.isEmpty else { return attachment != nil }
        detachNow()
        let next = store.attachIfNeeded(
            sessionId: sessionId,
            notebookId: notebookId,
            tabId: tabId
        )
        attachment = next
        attachmentFailed = next == nil
        return next != nil
    }

    func setEditPending(segmentId: String, pending: Bool) {
        if pending {
            pendingEditSegmentIds.insert(segmentId)
        } else {
            pendingEditSegmentIds.remove(segmentId)
        }
        detachIfReady()
    }

    func requestDetach() {
        detachRequested = true
        detachIfReady()
    }

    private func detachIfReady() {
        guard detachRequested, pendingEditSegmentIds.isEmpty else { return }
        detachNow()
    }

    private func detachNow() {
        guard let attachment else { return }
        store.detach(attachment)
        self.attachment = nil
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
