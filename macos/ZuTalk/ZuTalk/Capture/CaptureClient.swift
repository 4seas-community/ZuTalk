import AVFoundation
import Combine
import Foundation

/// Stable Swift seam for the UniFFI surface. Method names mirror the product
/// contract, and the default implementation fails closed when no live adapter
/// is available.
protocol NotebookCaptureClienting: AnyObject {
    func getNotebookCaptureProfile(notebookId: String) throws -> NotebookCaptureProfileDTO
    func updateNotebookCaptureProfile(_ profile: NotebookCaptureProfileDTO) throws -> NotebookCaptureProfileDTO
    func previewNotebookCaptureContext(notebookId: String) throws -> NotebookCaptureContextPreviewDTO
    func listNotebookContextPacks(notebookId: String) throws -> [NotebookContextPackDTO]
    func listLibraryContextPacks() throws -> [NotebookContextPackDTO]
    func readLibraryContextPack(packId: String) throws -> String
    func replaceLibraryContextPack(
        packId: String,
        expectedRevision: UInt64,
        documentJson: String
    ) throws -> NotebookContextPackDTO
    func createLibraryContextPack(title: String) throws -> NotebookContextPackDTO
    func copyNotebookPrivateContextToLibrary(
        notebookId: String,
        title: String
    ) throws -> NotebookContextPackDTO
    func setNotebookContextPackBinding(
        notebookId: String,
        packId: String,
        position: UInt64?
    ) throws
    func listContextPackSources(
        notebookId: String,
        packId: String
    ) throws -> [NotebookContextPackSourceDTO]
    func importContextPackText(
        notebookId: String,
        packId: String,
        title: String,
        text: String,
        contentKind: String
    ) throws -> NotebookContextPackSourceDTO
    func exportContextPack(
        notebookId: String,
        packId: String,
        destinationPath: String
    ) throws -> UInt32
    func importContextPack(
        sourcePath: String,
        titleOverride: String?
    ) throws -> NotebookContextPackDTO
    func deleteContextPackSource(notebookId: String, sourceId: String) throws -> Bool
    func deleteLibraryContextPack(packId: String, expectedRevision: UInt64) throws -> Bool
    func startNotebookCaptureSession(
        notebookId: String,
        profileRevision: UInt64,
        confirmedContextDigest: String?,
        onCaptureEvent: @escaping @MainActor @Sendable (NotebookCaptureEventDTO) -> Void,
        onLivePreview: @escaping @MainActor @Sendable (NotebookCaptureLivePreviewDTO) -> Void
    ) throws -> NotebookCaptureEventDTO
    /// Builds a sendable, session-bound audio sink. The microphone callback
    /// invokes this sink off the main actor so realtime PCM never queues one
    /// MainActor task per frame.
    func makeNotebookCaptureAudioPusher(sessionId: String) -> @Sendable (Data) -> String?
    func pauseNotebookCaptureSession(
        sessionId: String,
        paused: Bool
    ) async throws -> NotebookCaptureEventDTO
    func stopNotebookCaptureSession(sessionId: String) async throws -> NotebookCaptureEventDTO
    func interruptNotebookCaptureSession(
        sessionId: String,
        reason: NotebookCaptureInterruptReason
    ) async throws -> NotebookCaptureEventDTO
    func getNotebookCaptureSessionEvent(sessionId: String) throws -> NotebookCaptureEventDTO
    func reconcileNotebookCaptureSessionEvent(
        sessionId: String
    ) async throws -> NotebookCaptureEventDTO
    func listNotebookCaptureUtterances(sessionId: String) throws -> [NotebookCaptureUtteranceDTO]
    func listSpeakerParticipants() throws -> [SpeakerParticipantDTO]
    func createSpeakerParticipant(displayName: String) throws -> SpeakerParticipantDTO
    func renameSpeakerParticipant(
        participantId: String,
        displayName: String
    ) throws -> SpeakerParticipantDTO
    func listNotebookSessionSpeakers(sessionId: String) throws -> [NotebookSessionSpeakerDTO]
    func renameNotebookSessionSpeaker(
        sessionSpeakerId: String,
        localDisplayName: String?
    ) throws -> NotebookSessionSpeakerDTO
    func linkNotebookSessionSpeaker(
        sessionSpeakerId: String,
        participantId: String
    ) throws -> NotebookSessionSpeakerDTO
    func unlinkNotebookSessionSpeaker(
        sessionSpeakerId: String
    ) throws -> NotebookSessionSpeakerDTO
    func listNotebookCaptureHistory(notebookId: String) throws -> [NotebookCaptureHistoryRunDTO]
    func listNotebookCaptureHistorySummaries(
        notebookId: String
    ) throws -> [NotebookCaptureHistoryRunDTO]
    func loadNotebookCaptureHistorySummaries(
        notebookId: String
    ) async throws -> [NotebookCaptureHistoryRunDTO]
    func loadNotebookCaptureHistoryUtterances(
        notebookId: String,
        sessionId: String
    ) async throws -> [NotebookCaptureUtteranceDTO]
    func loadNotebookSessionTranscriptGaps(
        sessionId: String
    ) async throws -> [NotebookTranscriptGapDTO]
    func retryNotebookCaptureProjection(sessionId: String) throws -> NotebookCaptureEventDTO
    func retryNotebookAsyncProjection(sessionId: String) throws -> NotebookCaptureEventDTO
    func requestNotebookAsyncTranscription(sessionId: String) throws -> NotebookCaptureEventDTO
    func replaceNotebookUtteranceLane(
        utteranceId: String,
        laneLanguage: String,
        text: String,
        expectedRevision: UInt64
    ) async throws -> NotebookCaptureUtteranceDTO
    func projectNotebookRealtimeIncremental(sessionId: String) throws
    func cancelNotebookRealtimeProjection(sessionId: String)
}

extension NotebookCaptureClienting {
    /// Gap dividers are advisory presentation; clients without the query
    /// simply draw none.
    func loadNotebookSessionTranscriptGaps(
        sessionId: String
    ) async throws -> [NotebookTranscriptGapDTO] {
        []
    }

    func listLibraryContextPacks() throws -> [NotebookContextPackDTO] {
        throw NotebookCaptureClientError.ffiUnavailable
    }

    func readLibraryContextPack(packId: String) throws -> String {
        throw NotebookCaptureClientError.ffiUnavailable
    }

    func replaceLibraryContextPack(
        packId: String,
        expectedRevision: UInt64,
        documentJson: String
    ) throws -> NotebookContextPackDTO {
        throw NotebookCaptureClientError.ffiUnavailable
    }

    /// Keeps lightweight test/platform clients source-compatible while the
    /// live Rust adapter remains the only production history implementation.
    func listNotebookCaptureHistory(
        notebookId: String
    ) throws -> [NotebookCaptureHistoryRunDTO] {
        throw NotebookCaptureClientError.ffiUnavailable
    }

    /// Lightweight/platform clients may keep returning their in-memory full
    /// fixtures. Production overrides this with the summary-only Rust query.
    func listNotebookCaptureHistorySummaries(
        notebookId: String
    ) throws -> [NotebookCaptureHistoryRunDTO] {
        try listNotebookCaptureHistory(notebookId: notebookId)
    }

    func loadNotebookCaptureHistorySummaries(
        notebookId: String
    ) async throws -> [NotebookCaptureHistoryRunDTO] {
        try listNotebookCaptureHistorySummaries(notebookId: notebookId)
    }

    func loadNotebookCaptureHistoryUtterances(
        notebookId: String,
        sessionId: String
    ) async throws -> [NotebookCaptureUtteranceDTO] {
        try listNotebookCaptureUtterances(sessionId: sessionId)
    }

    func requestNotebookAsyncTranscription(
        sessionId: String
    ) throws -> NotebookCaptureEventDTO {
        throw NotebookCaptureClientError.ffiUnavailable
    }

    func projectNotebookRealtimeIncremental(sessionId: String) throws {
        throw NotebookCaptureClientError.ffiUnavailable
    }

    func reconcileNotebookCaptureSessionEvent(
        sessionId: String
    ) async throws -> NotebookCaptureEventDTO {
        try getNotebookCaptureSessionEvent(sessionId: sessionId)
    }

    func cancelNotebookRealtimeProjection(sessionId: String) {}

    func listSpeakerParticipants() throws -> [SpeakerParticipantDTO] {
        throw NotebookCaptureClientError.ffiUnavailable
    }

    func createSpeakerParticipant(displayName: String) throws -> SpeakerParticipantDTO {
        throw NotebookCaptureClientError.ffiUnavailable
    }

    func renameSpeakerParticipant(
        participantId: String,
        displayName: String
    ) throws -> SpeakerParticipantDTO {
        throw NotebookCaptureClientError.ffiUnavailable
    }

    func listNotebookSessionSpeakers(
        sessionId: String
    ) throws -> [NotebookSessionSpeakerDTO] {
        throw NotebookCaptureClientError.ffiUnavailable
    }

    func renameNotebookSessionSpeaker(
        sessionSpeakerId: String,
        localDisplayName: String?
    ) throws -> NotebookSessionSpeakerDTO {
        throw NotebookCaptureClientError.ffiUnavailable
    }

    func linkNotebookSessionSpeaker(
        sessionSpeakerId: String,
        participantId: String
    ) throws -> NotebookSessionSpeakerDTO {
        throw NotebookCaptureClientError.ffiUnavailable
    }

    func unlinkNotebookSessionSpeaker(
        sessionSpeakerId: String
    ) throws -> NotebookSessionSpeakerDTO {
        throw NotebookCaptureClientError.ffiUnavailable
    }
}

// MARK: - Live Rust adapter

/// Coalesces durable Final-watermark wakes onto one utility queue. The capture
/// callback runs on MainActor and must never perform Loro snapshot fsync there.
final class NotebookRealtimeProjectionScheduler: @unchecked Sendable {
    typealias Projection = @Sendable (String) throws -> Void

    private struct Job: @unchecked Sendable {
        var projection: Projection
        var generation: UInt64
        var fastFailureCount: Int
        var runningGeneration: UInt64?
        var scheduledWorkItem: DispatchWorkItem?
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(
        label: "xyz.voice.zutalk.realtime-projection",
        qos: .utility
    )
    private let maximumFastRetries: Int
    private let initialFastRetryDelay: TimeInterval
    private let cappedRetryDelay: TimeInterval
    private var nextGeneration: UInt64 = 0
    private var jobs: [String: Job] = [:]

    init(
        maximumFastRetries: Int = 3,
        initialFastRetryDelay: TimeInterval = 0.025,
        cappedRetryDelay: TimeInterval = 2
    ) {
        let normalizedFastRetryDelay = max(0, initialFastRetryDelay)
        self.maximumFastRetries = max(0, maximumFastRetries)
        self.initialFastRetryDelay = normalizedFastRetryDelay
        self.cappedRetryDelay = max(
            normalizedFastRetryDelay,
            max(0.001, cappedRetryDelay)
        )
    }

    func schedule(sessionId: String, projection: @escaping Projection) {
        lock.lock()
        nextGeneration &+= 1
        let generation = nextGeneration
        if var job = jobs[sessionId] {
            job.projection = projection
            job.generation = generation
            job.fastFailureCount = 0
            job.scheduledWorkItem?.cancel()
            job.scheduledWorkItem = nil
            let isRunning = job.runningGeneration != nil
            jobs[sessionId] = job
            if isRunning == false {
                enqueueLocked(sessionId: sessionId, generation: generation, after: 0)
            }
        } else {
            jobs[sessionId] = Job(
                projection: projection,
                generation: generation,
                fastFailureCount: 0,
                runningGeneration: nil,
                scheduledWorkItem: nil
            )
            enqueueLocked(sessionId: sessionId, generation: generation, after: 0)
        }
        lock.unlock()
    }

    func cancel(sessionId: String) {
        lock.lock()
        let job = jobs.removeValue(forKey: sessionId)
        job?.scheduledWorkItem?.cancel()
        lock.unlock()
    }

    private func enqueueLocked(
        sessionId: String,
        generation: UInt64,
        after delay: TimeInterval
    ) {
        guard var job = jobs[sessionId],
              job.generation == generation,
              job.runningGeneration == nil,
              job.scheduledWorkItem == nil
        else { return }

        let workItem = DispatchWorkItem { [weak self] in
            self?.run(sessionId: sessionId, generation: generation)
        }
        job.scheduledWorkItem = workItem
        jobs[sessionId] = job
        queue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func run(sessionId: String, generation: UInt64) {
        let projection: (String) throws -> Void
        lock.lock()
        guard var job = jobs[sessionId],
              job.generation == generation,
              job.runningGeneration == nil
        else {
            lock.unlock()
            return
        }
        job.scheduledWorkItem = nil
        job.runningGeneration = generation
        projection = job.projection
        jobs[sessionId] = job
        lock.unlock()

        let succeeded: Bool
        do {
            try projection(sessionId)
            succeeded = true
        } catch {
            succeeded = false
        }
        finish(
            sessionId: sessionId,
            attemptedGeneration: generation,
            succeeded: succeeded
        )
    }

    private func finish(
        sessionId: String,
        attemptedGeneration: UInt64,
        succeeded: Bool
    ) {
        lock.lock()
        guard var job = jobs[sessionId],
              job.runningGeneration == attemptedGeneration
        else {
            lock.unlock()
            return
        }
        job.runningGeneration = nil

        if job.generation != attemptedGeneration {
            // A new durable wake replaces any stale in-flight outcome and
            // restores the fast retry budget.
            let refreshedGeneration = job.generation
            jobs[sessionId] = job
            enqueueLocked(
                sessionId: sessionId,
                generation: refreshedGeneration,
                after: 0
            )
            lock.unlock()
            return
        }

        if succeeded {
            jobs.removeValue(forKey: sessionId)
            lock.unlock()
            return
        }

        job.fastFailureCount += 1
        let failureCount = job.fastFailureCount
        jobs[sessionId] = job
        let delay: TimeInterval
        if failureCount <= maximumFastRetries {
            delay = initialFastRetryDelay * pow(2, Double(failureCount - 1))
        } else {
            // Keep the durable wake alive through a quiet period without a
            // busy loop. Terminal/session teardown is the explicit owner of
            // cancellation.
            delay = cappedRetryDelay
        }
        enqueueLocked(sessionId: sessionId, generation: job.generation, after: delay)
        lock.unlock()
    }
}

/// Mechanical UniFFI adapter. Rust remains the only owner of capture state,
/// context compilation, persistence, projection, and terminal transitions.
@MainActor
final class RustNotebookCaptureClient: NotebookCaptureClienting {
    private let coreProvider: @MainActor () -> (any ZuTalkCoreProtocol)?
    private let realtimeProjectionScheduler = NotebookRealtimeProjectionScheduler()

    init(
        coreProvider: @escaping @MainActor () -> (any ZuTalkCoreProtocol)? = {
            CoreClient.shared.core
        }
    ) {
        self.coreProvider = coreProvider
    }

    func getNotebookCaptureProfile(notebookId: String) throws -> NotebookCaptureProfileDTO {
        Self.map(try requireCore().getNotebookCaptureProfile(notebookId: notebookId))
    }

    func updateNotebookCaptureProfile(
        _ profile: NotebookCaptureProfileDTO
    ) throws -> NotebookCaptureProfileDTO {
        Self.map(try requireCore().updateNotebookCaptureProfile(profile: Self.ffi(profile)))
    }

    func previewNotebookCaptureContext(
        notebookId: String
    ) throws -> NotebookCaptureContextPreviewDTO {
        Self.map(try requireCore().previewNotebookCaptureContext(notebookId: notebookId))
    }

    func listNotebookContextPacks(notebookId: String) throws -> [NotebookContextPackDTO] {
        try requireCore().listNotebookContextPacks(notebookId: notebookId).map(Self.map)
    }

    func listLibraryContextPacks() throws -> [NotebookContextPackDTO] {
        try requireCore().listLibraryContextPacks().map(Self.map)
    }

    func readLibraryContextPack(packId: String) throws -> String {
        try requireCore().readLibraryContextPack(packId: packId)
    }

    func replaceLibraryContextPack(
        packId: String,
        expectedRevision: UInt64,
        documentJson: String
    ) throws -> NotebookContextPackDTO {
        Self.map(try requireCore().replaceLibraryContextPack(
            packId: packId,
            expectedRevision: expectedRevision,
            documentJson: documentJson
        ))
    }

    func createLibraryContextPack(title: String) throws -> NotebookContextPackDTO {
        Self.map(try requireCore().createLibraryContextPack(title: title))
    }

    func copyNotebookPrivateContextToLibrary(
        notebookId: String,
        title: String
    ) throws -> NotebookContextPackDTO {
        Self.map(try requireCore().copyNotebookPrivateContextToLibrary(
            notebookId: notebookId,
            title: title
        ))
    }

    func setNotebookContextPackBinding(
        notebookId: String,
        packId: String,
        position: UInt64?
    ) throws {
        try requireCore().setNotebookContextPackBinding(
            notebookId: notebookId,
            packId: packId,
            position: position
        )
    }

    func listContextPackSources(
        notebookId: String,
        packId: String
    ) throws -> [NotebookContextPackSourceDTO] {
        try requireCore().listContextPackSources(
            notebookId: notebookId,
            packId: packId
        ).map(Self.map)
    }

    func importContextPackText(
        notebookId: String,
        packId: String,
        title: String,
        text: String,
        contentKind: String
    ) throws -> NotebookContextPackSourceDTO {
        Self.map(try requireCore().importContextPackText(
            notebookId: notebookId,
            packId: packId,
            title: title,
            text: text,
            contentKind: contentKind
        ))
    }

    func exportContextPack(
        notebookId: String,
        packId: String,
        destinationPath: String
    ) throws -> UInt32 {
        try requireCore().exportContextPack(
            notebookId: notebookId,
            packId: packId,
            destinationPath: destinationPath
        )
    }

    func importContextPack(
        sourcePath: String,
        titleOverride: String?
    ) throws -> NotebookContextPackDTO {
        Self.map(try requireCore().importContextPack(
            sourcePath: sourcePath,
            titleOverride: titleOverride
        ))
    }

    func deleteContextPackSource(notebookId: String, sourceId: String) throws -> Bool {
        try requireCore().deleteContextPackSource(notebookId: notebookId, sourceId: sourceId)
    }

    func deleteLibraryContextPack(packId: String, expectedRevision: UInt64) throws -> Bool {
        try requireCore().deleteLibraryContextPack(
            packId: packId,
            expectedRevision: expectedRevision
        )
    }

    func startNotebookCaptureSession(
        notebookId: String,
        profileRevision: UInt64,
        confirmedContextDigest: String?,
        onCaptureEvent: @escaping @MainActor @Sendable (NotebookCaptureEventDTO) -> Void,
        onLivePreview: @escaping @MainActor @Sendable (NotebookCaptureLivePreviewDTO) -> Void
    ) throws -> NotebookCaptureEventDTO {
        let callback = RustNotebookCaptureCallback(
            onCaptureEvent: onCaptureEvent,
            onLivePreview: onLivePreview
        )
        return Self.map(try requireCore().startNotebookCaptureSession(
            notebookId: notebookId,
            profileRevision: profileRevision,
            confirmedContextDigest: confirmedContextDigest,
            callback: callback
        ))
    }

    func makeNotebookCaptureAudioPusher(sessionId: String) -> @Sendable (Data) -> String? {
        guard let core = coreProvider() else {
            return { _ in NotebookCaptureClientError.ffiUnavailable.localizedDescription }
        }
        return { audioData in
            do {
                try core.pushNotebookCaptureSession(
                    sessionId: sessionId,
                    audioData: audioData
                )
                return nil
            } catch {
                return error.localizedDescription
            }
        }
    }

    func pauseNotebookCaptureSession(
        sessionId: String,
        paused: Bool
    ) async throws -> NotebookCaptureEventDTO {
        let core = try requireCore()
        let event = try await Task.detached {
            try core.pauseNotebookCaptureSession(
                sessionId: sessionId,
                paused: paused
            )
        }.value
        return Self.map(event)
    }

    func stopNotebookCaptureSession(sessionId: String) async throws -> NotebookCaptureEventDTO {
        let core = try requireCore()
        let event = try await Task.detached {
            try core.stopNotebookCaptureSession(sessionId: sessionId)
        }.value
        return Self.map(event)
    }

    func interruptNotebookCaptureSession(
        sessionId: String,
        reason: NotebookCaptureInterruptReason
    ) async throws -> NotebookCaptureEventDTO {
        let core = try requireCore()
        let ffiReason = Self.ffi(reason)
        let event = try await Task.detached {
            try core.interruptNotebookCaptureSession(
                sessionId: sessionId,
                reason: ffiReason
            )
        }.value
        return Self.map(event)
    }

    func getNotebookCaptureSessionEvent(sessionId: String) throws -> NotebookCaptureEventDTO {
        Self.map(try requireCore().getNotebookCaptureSessionEvent(sessionId: sessionId))
    }

    func reconcileNotebookCaptureSessionEvent(
        sessionId: String
    ) async throws -> NotebookCaptureEventDTO {
        let core = try requireCore()
        let event = try await Task.detached {
            try core.getNotebookCaptureSessionEvent(sessionId: sessionId)
        }.value
        return Self.map(event)
    }

    func listNotebookCaptureUtterances(
        sessionId: String
    ) throws -> [NotebookCaptureUtteranceDTO] {
        try requireCore().listNotebookCaptureUtterances(sessionId: sessionId).map(Self.map)
    }

    func listNotebookCaptureHistory(
        notebookId: String
    ) throws -> [NotebookCaptureHistoryRunDTO] {
        try requireCore()
            .listNotebookCaptureHistory(notebookId: notebookId)
            .map(Self.map)
    }

    func listNotebookCaptureHistorySummaries(
        notebookId: String
    ) throws -> [NotebookCaptureHistoryRunDTO] {
        try requireCore()
            .listNotebookCaptureHistorySummaries(notebookId: notebookId)
            .map(Self.map)
    }

    func loadNotebookCaptureHistorySummaries(
        notebookId: String
    ) async throws -> [NotebookCaptureHistoryRunDTO] {
        let core = try requireCore()
        let values = try await Task.detached {
            try core.listNotebookCaptureHistorySummaries(notebookId: notebookId)
        }.value
        return values.map(Self.map)
    }

    func loadNotebookCaptureHistoryUtterances(
        notebookId: String,
        sessionId: String
    ) async throws -> [NotebookCaptureUtteranceDTO] {
        let core = try requireCore()
        let values = try await Task.detached {
            try core.listNotebookCaptureHistoryUtterances(
                notebookId: notebookId,
                sessionId: sessionId
            )
        }.value
        return values.map(Self.map)
    }

    func loadNotebookSessionTranscriptGaps(
        sessionId: String
    ) async throws -> [NotebookTranscriptGapDTO] {
        let core = try requireCore()
        let values = try await Task.detached {
            try core.listNotebookSessionTranscriptGaps(sessionId: sessionId)
        }.value
        return values.map { gap in
            NotebookTranscriptGapDTO(
                id: gap.id,
                sessionId: gap.sessionId,
                startMs: gap.startMs,
                endMs: gap.endMs,
                repairState: gap.repairState
            )
        }
    }

    func listSpeakerParticipants() throws -> [SpeakerParticipantDTO] {
        try requireCore().listSpeakerParticipants().map(Self.map)
    }

    func createSpeakerParticipant(displayName: String) throws -> SpeakerParticipantDTO {
        Self.map(try requireCore().createSpeakerParticipant(displayName: displayName))
    }

    func renameSpeakerParticipant(
        participantId: String,
        displayName: String
    ) throws -> SpeakerParticipantDTO {
        Self.map(try requireCore().renameSpeakerParticipant(
            participantId: participantId,
            displayName: displayName
        ))
    }

    func listNotebookSessionSpeakers(
        sessionId: String
    ) throws -> [NotebookSessionSpeakerDTO] {
        try requireCore().listNotebookSessionSpeakers(sessionId: sessionId).map(Self.map)
    }

    func renameNotebookSessionSpeaker(
        sessionSpeakerId: String,
        localDisplayName: String?
    ) throws -> NotebookSessionSpeakerDTO {
        Self.map(try requireCore().renameNotebookSessionSpeaker(
            sessionSpeakerId: sessionSpeakerId,
            localDisplayName: localDisplayName
        ))
    }

    func linkNotebookSessionSpeaker(
        sessionSpeakerId: String,
        participantId: String
    ) throws -> NotebookSessionSpeakerDTO {
        Self.map(try requireCore().linkNotebookSessionSpeaker(
            sessionSpeakerId: sessionSpeakerId,
            participantId: participantId
        ))
    }

    func unlinkNotebookSessionSpeaker(
        sessionSpeakerId: String
    ) throws -> NotebookSessionSpeakerDTO {
        Self.map(try requireCore().unlinkNotebookSessionSpeaker(
            sessionSpeakerId: sessionSpeakerId
        ))
    }

    func retryNotebookCaptureProjection(sessionId: String) throws -> NotebookCaptureEventDTO {
        Self.map(try requireCore().retryNotebookCaptureProjection(sessionId: sessionId))
    }

    func retryNotebookAsyncProjection(sessionId: String) throws -> NotebookCaptureEventDTO {
        Self.map(try requireCore().retryNotebookAsyncProjection(sessionId: sessionId))
    }

    func requestNotebookAsyncTranscription(
        sessionId: String
    ) throws -> NotebookCaptureEventDTO {
        Self.map(try requireCore().requestNotebookAsyncTranscription(sessionId: sessionId))
    }

    func replaceNotebookUtteranceLane(
        utteranceId: String,
        laneLanguage: String,
        text: String,
        expectedRevision: UInt64
    ) async throws -> NotebookCaptureUtteranceDTO {
        let core = try requireCore()
        let utterance = try await Task.detached {
            try core.replaceNotebookUtteranceLane(
                utteranceId: utteranceId,
                laneLanguage: laneLanguage,
                text: text,
                expectedRevision: expectedRevision
            )
        }.value
        return Self.map(utterance)
    }

    func projectNotebookRealtimeIncremental(sessionId: String) throws {
        let core = try requireCore()
        realtimeProjectionScheduler.schedule(sessionId: sessionId) { sessionId in
            try core.projectNotebookRealtimeIncremental(sessionId: sessionId)
        }
    }

    func cancelNotebookRealtimeProjection(sessionId: String) {
        realtimeProjectionScheduler.cancel(sessionId: sessionId)
    }

    private func requireCore() throws -> any ZuTalkCoreProtocol {
        guard let core = coreProvider() else { throw NotebookCaptureClientError.ffiUnavailable }
        return core
    }

    static func map(_ value: FfiNotebookCaptureProfile) -> NotebookCaptureProfileDTO {
        let mode = map(value.mode)
        let selectedLanguages = NotebookCaptureHistoryPolicy.resolvedSelectedLanguages(
            value.selectedLanguages,
            legacyLeftLanguage: value.leftLanguage,
            legacyRightLanguage: value.rightLanguage
        )
        return NotebookCaptureProfileDTO(
            notebookId: value.notebookId,
            remoteRealtimeEnabled: value.remoteRealtimeEnabled,
            mode: mode,
            languageA: value.languageA,
            languageB: value.languageB,
            leftLanguage: value.leftLanguage,
            rightLanguage: value.rightLanguage,
            privacyLevel: NotebookAudioRetentionLevel(rawValue: value.privacyLevel) ?? .standard,
            sendContextToSoniox: value.sendContextToSoniox,
            revision: value.revision,
            selectedLanguages: selectedLanguages,
            commonCaptionLanguage: nil
        )
    }

    static func ffi(_ value: NotebookCaptureProfileDTO) -> FfiNotebookCaptureProfile {
        let selectedLanguages = NotebookCaptureHistoryPolicy.resolvedSelectedLanguages(
            value.selectedLanguages,
            legacyLeftLanguage: value.leftLanguage,
            legacyRightLanguage: value.rightLanguage
        )
        return FfiNotebookCaptureProfile(
            notebookId: value.notebookId,
            remoteRealtimeEnabled: value.remoteRealtimeEnabled,
            mode: ffi(value.mode),
            languageA: value.languageA,
            languageB: value.languageB,
            leftLanguage: value.leftLanguage,
            rightLanguage: value.rightLanguage,
            selectedLanguages: selectedLanguages,
            commonCaptionLanguage: nil,
            privacyLevel: value.privacyLevel.rawValue,
            sendContextToSoniox: value.sendContextToSoniox,
            revision: value.revision
        )
    }

    static func map(_ value: FfiNotebookCaptureContextPreview) -> NotebookCaptureContextPreviewDTO {
        NotebookCaptureContextPreviewDTO(
            notebookId: value.notebookId,
            serializedContext: value.serializedContext,
            sources: value.sources.map { source in
                NotebookCaptureContextSourceDTO(
                    id: source.id,
                    title: source.title,
                    packKind: source.packKind,
                    scalarCount: Int(clamping: source.scalarCount),
                    included: source.included,
                    reason: source.reason
                )
            },
            omittedReasons: value.omittedReasons,
            digest: value.digest,
            scalarCount: Int(clamping: value.scalarCount)
        )
    }

    static func map(_ value: FfiContextPackInfo) -> NotebookContextPackDTO {
        NotebookContextPackDTO(
            id: value.id,
            scope: value.scope,
            ownerNotebookId: value.ownerNotebookId,
            title: value.title,
            revision: value.revision,
            boundPosition: value.boundPosition
        )
    }

    static func map(_ value: FfiContextPackSourceInfo) -> NotebookContextPackSourceDTO {
        NotebookContextPackSourceDTO(
            id: value.id,
            packId: value.packId,
            title: value.title,
            format: value.format,
            contentKind: value.contentKind,
            plaintextSha256: value.plaintextSha256,
            plaintextBytes: value.plaintextBytes,
            trusted: value.trusted,
            revision: value.revision
        )
    }

    static func map(_ value: FfiNotebookCaptureEvent) -> NotebookCaptureEventDTO {
        let mode = value.mode.map(Self.map)
        let selectedLanguages = NotebookCaptureHistoryPolicy.resolvedSelectedLanguages(
            value.selectedLanguages,
            legacyLeftLanguage: value.leftLanguage,
            legacyRightLanguage: value.rightLanguage
        )
        return NotebookCaptureEventDTO(
            sessionId: value.sessionId,
            eventRevision: value.eventRevision,
            isFullSnapshot: value.isFullSnapshot,
            captureState: map(value.captureState),
            remoteHealth: map(value.remoteHealth),
            realtimeLagMs: value.realtimeLagMs,
            projectionState: map(value.projectionState),
            utterances: value.utterances.map(Self.map),
            removedSequences: value.removedSequences,
            translationCues: value.translationCues.map { cue in
                NotebookCaptureTranslationCueDTO(
                    targetLanguage: cue.targetLanguage,
                    groupEpoch: cue.groupEpoch,
                    providerSequence: cue.providerSequence,
                    sourceLanguage: cue.sourceLanguage,
                    sourceStartMs: cue.sourceStartMs,
                    sourceEndMs: cue.sourceEndMs,
                    text: cue.text,
                    completion: cue.completion,
                    withdrawn: cue.withdrawn,
                    revision: cue.revision
                )
            },
            laneHealth: value.laneHealth.compactMap { lane in
                // An unknown state string is dropped rather than guessed:
                // inventing "live" for it would hide a degradation, and
                // inventing "failed" would kill a healthy column.
                NotebookCaptureLaneHealthDTO.State(rawValue: lane.state).map { state in
                    NotebookCaptureLaneHealthDTO(
                        targetLanguage: lane.targetLanguage,
                        state: state,
                        groupEpoch: lane.groupEpoch,
                        finalAudioProcMs: lane.finalAudioProcMs,
                        totalAudioProcMs: lane.totalAudioProcMs,
                        lagMs: lane.lagMs,
                        inputDiscontinuous: lane.inputDiscontinuous
                    )
                }
            },
            contextReceipt: value.contextReceipt.map { receipt in
                NotebookCaptureContextReceiptDTO(
                    digest: receipt.digest,
                    applied: receipt.applied,
                    provider: receipt.provider,
                    model: receipt.model,
                    appliedAt: receipt.appliedAt
                )
            },
            providerErrorType: value.providerErrorType,
            providerRequestId: value.providerRequestId,
            mode: mode,
            languageA: value.languageA,
            languageB: value.languageB,
            leftLanguage: value.leftLanguage,
            rightLanguage: value.rightLanguage,
            privacyLevel: value.privacyLevel.flatMap(NotebookAudioRetentionLevel.init(rawValue:)),
            realtimeProviderId: value.realtimeProviderId,
            realtimeModelId: value.realtimeModelId,
            postStopProviderId: value.postStopProviderId,
            postStopModelId: value.postStopModelId,
            postStopAsyncState: value.postStopAsyncState,
            postStopAsyncProjectionState: map(value.postStopAsyncProjectionState),
            selectedLanguages: selectedLanguages,
            commonCaptionLanguage: nil,
            realtimeLoroAppliedRevision: value.realtimeLoroAppliedRevision
        )
    }

    static func map(_ value: FfiNotebookCaptureLivePreview) -> NotebookCaptureLivePreviewDTO {
        NotebookCaptureLivePreviewDTO(
            sessionId: value.sessionId,
            previewRevision: value.previewRevision,
            utterances: value.utterances.map(Self.map),
            translationCues: value.translationCues.map { cue in
                NotebookCaptureTranslationCueDTO(
                    targetLanguage: cue.targetLanguage,
                    groupEpoch: cue.groupEpoch,
                    providerSequence: cue.providerSequence,
                    sourceLanguage: cue.sourceLanguage,
                    sourceStartMs: cue.sourceStartMs,
                    sourceEndMs: cue.sourceEndMs,
                    text: cue.text,
                    completion: cue.completion,
                    withdrawn: cue.withdrawn,
                    revision: cue.revision
                )
            },
            laneHealth: value.laneHealth.compactMap { lane in
                NotebookCaptureLaneHealthDTO.State(rawValue: lane.state).map { state in
                    NotebookCaptureLaneHealthDTO(
                        targetLanguage: lane.targetLanguage,
                        state: state,
                        groupEpoch: lane.groupEpoch,
                        finalAudioProcMs: lane.finalAudioProcMs,
                        totalAudioProcMs: lane.totalAudioProcMs,
                        lagMs: lane.lagMs,
                        inputDiscontinuous: lane.inputDiscontinuous
                    )
                }
            }
        )
    }

    static func map(
        _ value: FfiNotebookCaptureHistoryRun
    ) -> NotebookCaptureHistoryRunDTO {
        let mode = value.mode.map(Self.map)
        let selectedLanguages = NotebookCaptureHistoryPolicy.resolvedSelectedLanguages(
            value.selectedLanguages,
            legacyLeftLanguage: value.leftLanguage,
            legacyRightLanguage: value.rightLanguage
        )
        let durationMs = value.sampleRate.flatMap { sampleRate -> UInt64? in
            guard sampleRate > 0 else { return nil }
            return value.capturedFrames.multipliedReportingOverflow(by: 1_000).overflow
                ? nil
                : value.capturedFrames * 1_000 / UInt64(sampleRate)
        }
        return NotebookCaptureHistoryRunDTO(
            sessionId: value.sessionId,
            createdAt: value.createdAt,
            completedAt: value.completedAt,
            captureState: map(value.captureState),
            remoteHealth: map(value.remoteHealth),
            projectionState: map(value.projectionState),
            asyncTaskState: value.postStopAsyncState,
            asyncProjectionState: map(value.postStopAsyncProjectionState),
            durationMs: durationMs,
            capturedFrames: value.capturedFrames,
            hasAudio: value.hasAudio,
            mode: mode,
            languageA: value.languageA,
            languageB: value.languageB,
            leftLanguage: value.leftLanguage,
            rightLanguage: value.rightLanguage,
            privacyLevel: value.privacyLevel.flatMap(NotebookAudioRetentionLevel.init(rawValue:)),
            utterances: value.utterances.map(Self.map),
            selectedLanguages: selectedLanguages,
            commonCaptionLanguage: nil,
            realtimeLoroAppliedRevision: value.realtimeLoroAppliedRevision
        )
    }

    static func map(_ value: FfiNotebookCaptureUtterance) -> NotebookCaptureUtteranceDTO {
        NotebookCaptureUtteranceDTO(
            id: value.id,
            sessionId: value.sessionId,
            sequence: value.sequence,
            sessionSpeakerId: value.sessionSpeakerId,
            revision: value.revision,
            sourceLanguage: value.sourceLanguage,
            provisionalSourceLanguage: value.provisionalSourceLanguage,
            sourceText: value.sourceText,
            sourceStartMs: value.sourceStartMs,
            sourceEndMs: value.sourceEndMs,
            translatedLanguage: value.translatedLanguage,
            translatedText: value.translatedText,
            completion: value.completion,
            alignment: value.alignment,
            languageVariants: value.languageVariants.map { variant in
                NotebookCaptureLanguageVariantDTO(
                    language: variant.language,
                    role: variant.role,
                    text: variant.text,
                    state: variant.state,
                    completion: variant.completion,
                    projectionRevision: variant.projectionRevision,
                    editRevision: variant.editRevision
                )
            },
            sourceProjectionRevision: value.sourceProjectionRevision,
            sourceEditRevision: value.sourceEditRevision
        )
    }

    static func map(_ value: FfiSpeakerParticipant) -> SpeakerParticipantDTO {
        SpeakerParticipantDTO(
            id: value.id,
            displayName: value.displayName
        )
    }

    static func map(_ value: FfiSessionSpeaker) -> NotebookSessionSpeakerDTO {
        NotebookSessionSpeakerDTO(
            id: value.id,
            sessionId: value.sessionId,
            providerSessionEpoch: value.providerSessionEpoch,
            provider: value.provider,
            providerLabel: value.providerLabel,
            localDisplayName: value.localDisplayName,
            participantId: value.participantId
        )
    }

    private static func map(_ value: FfiNotebookCaptureMode) -> NotebookCaptureMode {
        switch value {
        case .transcriptionOnly: return .transcriptionOnly
        case .twoWay: return .twoWay
        case .multilingualOneWay: return .multilingualOneWay
        }
    }

    private static func ffi(_ value: NotebookCaptureMode) -> FfiNotebookCaptureMode {
        switch value {
        case .transcriptionOnly: return .transcriptionOnly
        case .twoWay: return .twoWay
        case .multilingualOneWay: return .multilingualOneWay
        }
    }

    private static func map(_ value: FfiNotebookCaptureState) -> NotebookCaptureState {
        switch value {
        case .recording: return .recording
        case .paused: return .paused
        case .draining: return .draining
        case .completed: return .completed
        case .interrupted: return .interrupted
        case .failed: return .failed
        }
    }

    private static func map(_ value: FfiNotebookRemoteHealth) -> NotebookRemoteHealth {
        switch value {
        case .off: return .off
        case .connecting: return .connecting
        case .live: return .live
        case .degraded: return .degraded
        case .unavailable: return .unavailable
        }
    }

    private static func map(_ value: FfiNotebookProjectionState) -> NotebookProjectionState {
        switch value {
        case .pending: return .pending
        case .projecting: return .projecting
        case .ready: return .ready
        case .failed: return .failed
        }
    }

    private static func map(
        _ value: FfiNotebookAsyncProjectionState
    ) -> NotebookAsyncProjectionState {
        switch value {
        case .none: return .none
        case .pending: return .pending
        case .projecting: return .projecting
        case .ready: return .ready
        case .failed: return .failed
        }
    }

    private static func ffi(
        _ value: NotebookCaptureInterruptReason
    ) -> FfiNotebookCaptureInterruptReason {
        switch value {
        case .localAudioOverflow: return .localAudioOverflow
        case .localAudioUnavailable: return .localAudioUnavailable
        }
    }
}

final class RustNotebookCaptureCallback: FfiNotebookCaptureCallback, @unchecked Sendable {
    nonisolated private let dispatcher: NotebookCaptureCallbackDispatcher

    nonisolated init(
        onCaptureEvent: @escaping @MainActor @Sendable (NotebookCaptureEventDTO) -> Void,
        onLivePreview: @escaping @MainActor @Sendable (NotebookCaptureLivePreviewDTO) -> Void
    ) {
        self.dispatcher = NotebookCaptureCallbackDispatcher(
            deliverEvent: onCaptureEvent,
            deliverPreview: onLivePreview
        )
    }

    nonisolated func onCaptureEvent(event: FfiNotebookCaptureEvent) {
        dispatcher.submit(event)
    }

    nonisolated func onLivePreview(preview: FfiNotebookCaptureLivePreview) {
        dispatcher.submit(preview)
    }
}

/// UniFFI callbacks return before their MainActor work runs. Both callback
/// classes keep one newest-only slot so a busy MainActor cannot turn realtime
/// delivery into an unbounded queue. A skipped durable revision is repaired
/// asynchronously from the authoritative snapshot by the store below.
/// One shared drain also makes final-row promotion run before the empty preview
/// that follows it.
private final class NotebookCaptureCallbackDispatcher: @unchecked Sendable {
    nonisolated private let lock = NSLock()
    nonisolated(unsafe) private var pendingEvent: FfiNotebookCaptureEvent?
    nonisolated(unsafe) private var pending: FfiNotebookCaptureLivePreview?
    nonisolated(unsafe) private var drainScheduled = false
    nonisolated private let deliverEvent:
        @MainActor @Sendable (NotebookCaptureEventDTO) -> Void
    nonisolated private let deliverPreview:
        @MainActor @Sendable (NotebookCaptureLivePreviewDTO) -> Void

    nonisolated init(
        deliverEvent: @escaping @MainActor @Sendable (NotebookCaptureEventDTO) -> Void,
        deliverPreview: @escaping @MainActor @Sendable (NotebookCaptureLivePreviewDTO) -> Void
    ) {
        self.deliverEvent = deliverEvent
        self.deliverPreview = deliverPreview
    }

    nonisolated func submit(_ event: FfiNotebookCaptureEvent) {
        lock.lock()
        if pendingEvent == nil
            || pendingEvent?.sessionId != event.sessionId
            || (pendingEvent?.eventRevision ?? 0) <= event.eventRevision {
            pendingEvent = event
        }
        let shouldSchedule = scheduleDrainIfNeededLocked()
        lock.unlock()
        scheduleDrain(shouldSchedule)
    }

    nonisolated func submit(_ preview: FfiNotebookCaptureLivePreview) {
        lock.lock()
        if pending == nil
            || pending?.sessionId != preview.sessionId
            || (pending?.previewRevision ?? 0) <= preview.previewRevision {
            pending = preview
        }
        let shouldSchedule = scheduleDrainIfNeededLocked()
        lock.unlock()
        scheduleDrain(shouldSchedule)
    }

    nonisolated private func scheduleDrainIfNeededLocked() -> Bool {
        guard drainScheduled == false else { return false }
        drainScheduled = true
        return true
    }

    nonisolated private func scheduleDrain(_ shouldSchedule: Bool) {
        guard shouldSchedule else { return }
        Task { @MainActor [self] in drainOne() }
    }

    @MainActor
    private func drainOne() {
        let event: FfiNotebookCaptureEvent?
        let preview: FfiNotebookCaptureLivePreview?
        lock.lock()
        event = pendingEvent
        pendingEvent = nil
        preview = pending
        pending = nil
        lock.unlock()

        if let event {
            deliverEvent(RustNotebookCaptureClient.map(event))
        }
        if let preview {
            deliverPreview(RustNotebookCaptureClient.map(preview))
        }

        lock.lock()
        let hasPending = pendingEvent != nil || pending != nil
        if hasPending == false {
            drainScheduled = false
        }
        lock.unlock()

        if hasPending {
            Task { @MainActor [self] in drainOne() }
        }
    }
}

enum NotebookCaptureClientError: LocalizedError, Equatable {
    case ffiUnavailable
    case captureAlreadyActive
    case remoteRequiredForTranslation
    case remoteRequiredForContext
    case languagePairMustDiffer
    case contextUnavailable
    case captureNotActive
    case projectionLocked

    var errorDescription: String? {
        switch self {
        case .ffiUnavailable:
            return String(localized: "capture.error.ffi_unavailable")
        case .captureAlreadyActive:
            return String(localized: "capture.error.already_active")
        case .remoteRequiredForTranslation:
            return String(localized: "capture.error.remote_required")
        case .remoteRequiredForContext:
            return String(localized: "capture.error.context_requires_remote")
        case .languagePairMustDiffer:
            return String(localized: "capture.error.languages_must_differ")
        case .contextUnavailable:
            return String(localized: "capture.settings.context.empty")
        case .captureNotActive:
            return String(localized: "capture.error.not_active")
        case .projectionLocked:
            return String(localized: "capture.error.projection_locked")
        }
    }
}

final class UnavailableNotebookCaptureClient: NotebookCaptureClienting {
    func getNotebookCaptureProfile(notebookId: String) throws -> NotebookCaptureProfileDTO {
        throw NotebookCaptureClientError.ffiUnavailable
    }

    func updateNotebookCaptureProfile(_ profile: NotebookCaptureProfileDTO) throws -> NotebookCaptureProfileDTO {
        throw NotebookCaptureClientError.ffiUnavailable
    }

    func previewNotebookCaptureContext(notebookId: String) throws -> NotebookCaptureContextPreviewDTO {
        throw NotebookCaptureClientError.ffiUnavailable
    }

    func listNotebookContextPacks(notebookId: String) throws -> [NotebookContextPackDTO] {
        throw NotebookCaptureClientError.ffiUnavailable
    }

    func listLibraryContextPacks() throws -> [NotebookContextPackDTO] {
        throw NotebookCaptureClientError.ffiUnavailable
    }

    func readLibraryContextPack(packId: String) throws -> String {
        throw NotebookCaptureClientError.ffiUnavailable
    }

    func replaceLibraryContextPack(
        packId: String,
        expectedRevision: UInt64,
        documentJson: String
    ) throws -> NotebookContextPackDTO {
        throw NotebookCaptureClientError.ffiUnavailable
    }

    func createLibraryContextPack(title: String) throws -> NotebookContextPackDTO {
        throw NotebookCaptureClientError.ffiUnavailable
    }

    func copyNotebookPrivateContextToLibrary(
        notebookId: String,
        title: String
    ) throws -> NotebookContextPackDTO {
        throw NotebookCaptureClientError.ffiUnavailable
    }

    func setNotebookContextPackBinding(
        notebookId: String,
        packId: String,
        position: UInt64?
    ) throws {
        throw NotebookCaptureClientError.ffiUnavailable
    }

    func listContextPackSources(
        notebookId: String,
        packId: String
    ) throws -> [NotebookContextPackSourceDTO] {
        throw NotebookCaptureClientError.ffiUnavailable
    }

    func importContextPackText(
        notebookId: String,
        packId: String,
        title: String,
        text: String,
        contentKind: String
    ) throws -> NotebookContextPackSourceDTO {
        throw NotebookCaptureClientError.ffiUnavailable
    }

    func exportContextPack(
        notebookId: String,
        packId: String,
        destinationPath: String
    ) throws -> UInt32 {
        throw NotebookCaptureClientError.ffiUnavailable
    }

    func importContextPack(
        sourcePath: String,
        titleOverride: String?
    ) throws -> NotebookContextPackDTO {
        throw NotebookCaptureClientError.ffiUnavailable
    }

    func deleteContextPackSource(notebookId: String, sourceId: String) throws -> Bool {
        throw NotebookCaptureClientError.ffiUnavailable
    }

    func deleteLibraryContextPack(packId: String, expectedRevision: UInt64) throws -> Bool {
        throw NotebookCaptureClientError.ffiUnavailable
    }

    func startNotebookCaptureSession(
        notebookId: String,
        profileRevision: UInt64,
        confirmedContextDigest: String?,
        onCaptureEvent: @escaping @MainActor @Sendable (NotebookCaptureEventDTO) -> Void,
        onLivePreview: @escaping @MainActor @Sendable (NotebookCaptureLivePreviewDTO) -> Void
    ) throws -> NotebookCaptureEventDTO {
        throw NotebookCaptureClientError.ffiUnavailable
    }

    func makeNotebookCaptureAudioPusher(sessionId: String) -> @Sendable (Data) -> String? {
        { _ in NotebookCaptureClientError.ffiUnavailable.localizedDescription }
    }

    func pauseNotebookCaptureSession(
        sessionId: String,
        paused: Bool
    ) async throws -> NotebookCaptureEventDTO {
        throw NotebookCaptureClientError.ffiUnavailable
    }

    func stopNotebookCaptureSession(sessionId: String) async throws -> NotebookCaptureEventDTO {
        throw NotebookCaptureClientError.ffiUnavailable
    }

    func interruptNotebookCaptureSession(
        sessionId: String,
        reason: NotebookCaptureInterruptReason
    ) async throws -> NotebookCaptureEventDTO {
        throw NotebookCaptureClientError.ffiUnavailable
    }

    func getNotebookCaptureSessionEvent(sessionId: String) throws -> NotebookCaptureEventDTO {
        throw NotebookCaptureClientError.ffiUnavailable
    }

    func listNotebookCaptureUtterances(sessionId: String) throws -> [NotebookCaptureUtteranceDTO] {
        throw NotebookCaptureClientError.ffiUnavailable
    }

    func retryNotebookCaptureProjection(sessionId: String) throws -> NotebookCaptureEventDTO {
        throw NotebookCaptureClientError.ffiUnavailable
    }

    func retryNotebookAsyncProjection(sessionId: String) throws -> NotebookCaptureEventDTO {
        throw NotebookCaptureClientError.ffiUnavailable
    }

    func replaceNotebookUtteranceLane(
        utteranceId: String,
        laneLanguage: String,
        text: String,
        expectedRevision: UInt64
    ) async throws -> NotebookCaptureUtteranceDTO {
        throw NotebookCaptureClientError.ffiUnavailable
    }
}

