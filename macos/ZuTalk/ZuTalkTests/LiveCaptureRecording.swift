import Foundation
@testable import ZuTalk

/// One callback the core delivered to the capture store, with when it came.
struct LiveCaptureRecordedCallback: Codable {
    let atMs: Double
    let event: NotebookCaptureEventDTO?
    let preview: NotebookCaptureLivePreviewDTO?
}

/// Forwards every call to the real client. Recording and replay override the
/// one call that matters to them: the capture session's callbacks.
class ForwardingNotebookCaptureClient: NotebookCaptureClienting {
    let base: NotebookCaptureClienting

    init(base: NotebookCaptureClienting) {
        self.base = base
    }

    func getNotebookCaptureProfile(notebookId: String) throws -> NotebookCaptureProfileDTO {
        try base.getNotebookCaptureProfile(notebookId: notebookId)
    }
    func updateNotebookCaptureProfile(_ profile: NotebookCaptureProfileDTO) throws -> NotebookCaptureProfileDTO {
        try base.updateNotebookCaptureProfile(profile)
    }
    func previewNotebookCaptureContext(notebookId: String) throws -> NotebookCaptureContextPreviewDTO {
        try base.previewNotebookCaptureContext(notebookId: notebookId)
    }
    func listNotebookContextPacks(notebookId: String) throws -> [NotebookContextPackDTO] {
        try base.listNotebookContextPacks(notebookId: notebookId)
    }
    func listLibraryContextPacks() throws -> [NotebookContextPackDTO] {
        try base.listLibraryContextPacks()
    }
    func readLibraryContextPack(packId: String) throws -> String {
        try base.readLibraryContextPack(packId: packId)
    }
    func replaceLibraryContextPack(packId: String, expectedRevision: UInt64, documentJson: String) throws -> NotebookContextPackDTO {
        try base.replaceLibraryContextPack(packId: packId, expectedRevision: expectedRevision, documentJson: documentJson)
    }
    func createLibraryContextPack(title: String) throws -> NotebookContextPackDTO {
        try base.createLibraryContextPack(title: title)
    }
    func copyNotebookPrivateContextToLibrary(notebookId: String, title: String) throws -> NotebookContextPackDTO {
        try base.copyNotebookPrivateContextToLibrary(notebookId: notebookId, title: title)
    }
    func setNotebookContextPackBinding(notebookId: String, packId: String, position: UInt64?) throws {
        try base.setNotebookContextPackBinding(notebookId: notebookId, packId: packId, position: position)
    }
    func listContextPackSources(notebookId: String, packId: String) throws -> [NotebookContextPackSourceDTO] {
        try base.listContextPackSources(notebookId: notebookId, packId: packId)
    }
    func importContextPackText(notebookId: String, packId: String, title: String, text: String, contentKind: String) throws -> NotebookContextPackSourceDTO {
        try base.importContextPackText(notebookId: notebookId, packId: packId, title: title, text: text, contentKind: contentKind)
    }
    func exportContextPack(notebookId: String, packId: String, destinationPath: String) throws -> UInt32 {
        try base.exportContextPack(notebookId: notebookId, packId: packId, destinationPath: destinationPath)
    }
    func importContextPack(sourcePath: String, titleOverride: String?) throws -> NotebookContextPackDTO {
        try base.importContextPack(sourcePath: sourcePath, titleOverride: titleOverride)
    }
    func deleteContextPackSource(notebookId: String, sourceId: String) throws -> Bool {
        try base.deleteContextPackSource(notebookId: notebookId, sourceId: sourceId)
    }
    func deleteLibraryContextPack(packId: String, expectedRevision: UInt64) throws -> Bool {
        try base.deleteLibraryContextPack(packId: packId, expectedRevision: expectedRevision)
    }
    func startNotebookCaptureSession(
        notebookId: String,
        profileRevision: UInt64,
        confirmedContextDigest: String?,
        onCaptureEvent: @escaping @MainActor @Sendable (NotebookCaptureEventDTO) -> Void,
        onLivePreview: @escaping @MainActor @Sendable (NotebookCaptureLivePreviewDTO) -> Void
    ) throws -> NotebookCaptureEventDTO {
        try base.startNotebookCaptureSession(
            notebookId: notebookId,
            profileRevision: profileRevision,
            confirmedContextDigest: confirmedContextDigest,
            onCaptureEvent: onCaptureEvent,
            onLivePreview: onLivePreview
        )
    }
    func makeNotebookCaptureAudioPusher(sessionId: String) -> @Sendable (Data) -> String? {
        base.makeNotebookCaptureAudioPusher(sessionId: sessionId)
    }
    func pauseNotebookCaptureSession(sessionId: String, paused: Bool) async throws -> NotebookCaptureEventDTO {
        try await base.pauseNotebookCaptureSession(sessionId: sessionId, paused: paused)
    }
    func restartNotebookCaptureTranscription(sessionId: String) async throws -> NotebookCaptureEventDTO {
        try await base.restartNotebookCaptureTranscription(sessionId: sessionId)
    }
    func stopNotebookCaptureSession(sessionId: String) async throws -> NotebookCaptureEventDTO {
        try await base.stopNotebookCaptureSession(sessionId: sessionId)
    }
    func interruptNotebookCaptureSession(sessionId: String, reason: NotebookCaptureInterruptReason) async throws -> NotebookCaptureEventDTO {
        try await base.interruptNotebookCaptureSession(sessionId: sessionId, reason: reason)
    }
    func getNotebookCaptureSessionEvent(sessionId: String) throws -> NotebookCaptureEventDTO {
        try base.getNotebookCaptureSessionEvent(sessionId: sessionId)
    }
    func reconcileNotebookCaptureSessionEvent(sessionId: String) async throws -> NotebookCaptureEventDTO {
        try await base.reconcileNotebookCaptureSessionEvent(sessionId: sessionId)
    }
    func listNotebookCaptureUtterances(sessionId: String) throws -> [NotebookCaptureUtteranceDTO] {
        try base.listNotebookCaptureUtterances(sessionId: sessionId)
    }
    func listSpeakerParticipants() throws -> [SpeakerParticipantDTO] {
        try base.listSpeakerParticipants()
    }
    func createSpeakerParticipant(displayName: String) throws -> SpeakerParticipantDTO {
        try base.createSpeakerParticipant(displayName: displayName)
    }
    func renameSpeakerParticipant(participantId: String, displayName: String) throws -> SpeakerParticipantDTO {
        try base.renameSpeakerParticipant(participantId: participantId, displayName: displayName)
    }
    func deleteSpeakerParticipant(participantId: String) throws -> Bool {
        try base.deleteSpeakerParticipant(participantId: participantId)
    }
    func speakerParticipantRecordingCounts() throws -> [String: UInt32] {
        try base.speakerParticipantRecordingCounts()
    }
    func listNotebookSessionSpeakers(sessionId: String) throws -> [NotebookSessionSpeakerDTO] {
        try base.listNotebookSessionSpeakers(sessionId: sessionId)
    }
    func renameNotebookSessionSpeaker(sessionSpeakerId: String, localDisplayName: String?) throws -> NotebookSessionSpeakerDTO {
        try base.renameNotebookSessionSpeaker(sessionSpeakerId: sessionSpeakerId, localDisplayName: localDisplayName)
    }
    func linkNotebookSessionSpeaker(sessionSpeakerId: String, participantId: String) throws -> NotebookSessionSpeakerDTO {
        try base.linkNotebookSessionSpeaker(sessionSpeakerId: sessionSpeakerId, participantId: participantId)
    }
    func unlinkNotebookSessionSpeaker(sessionSpeakerId: String) throws -> NotebookSessionSpeakerDTO {
        try base.unlinkNotebookSessionSpeaker(sessionSpeakerId: sessionSpeakerId)
    }
    func listNotebookCaptureHistory(notebookId: String) throws -> [NotebookCaptureHistoryRunDTO] {
        try base.listNotebookCaptureHistory(notebookId: notebookId)
    }
    func listNotebookCaptureHistorySummaries(notebookId: String) throws -> [NotebookCaptureHistoryRunDTO] {
        try base.listNotebookCaptureHistorySummaries(notebookId: notebookId)
    }
    func loadNotebookCaptureHistorySummaries(notebookId: String) async throws -> [NotebookCaptureHistoryRunDTO] {
        try await base.loadNotebookCaptureHistorySummaries(notebookId: notebookId)
    }
    func loadNotebookCaptureHistoryUtterances(notebookId: String, sessionId: String) async throws -> [NotebookCaptureUtteranceDTO] {
        try await base.loadNotebookCaptureHistoryUtterances(notebookId: notebookId, sessionId: sessionId)
    }
    func loadNotebookSessionTranscriptGaps(sessionId: String) async throws -> [NotebookTranscriptGapDTO] {
        try await base.loadNotebookSessionTranscriptGaps(sessionId: sessionId)
    }
    func loadNotebookCaptureTranslationCues(sessionId: String) async throws -> [NotebookCaptureTranslationCueDTO] {
        try await base.loadNotebookCaptureTranslationCues(sessionId: sessionId)
    }
    func retryNotebookCaptureProjection(sessionId: String) throws -> NotebookCaptureEventDTO {
        try base.retryNotebookCaptureProjection(sessionId: sessionId)
    }
    func retryNotebookAsyncProjection(sessionId: String) throws -> NotebookCaptureEventDTO {
        try base.retryNotebookAsyncProjection(sessionId: sessionId)
    }
    func requestNotebookAsyncTranscription(sessionId: String) throws -> NotebookCaptureEventDTO {
        try base.requestNotebookAsyncTranscription(sessionId: sessionId)
    }
    func replaceNotebookUtteranceLane(utteranceId: String, laneLanguage: String, text: String, expectedRevision: UInt64) async throws -> NotebookCaptureUtteranceDTO {
        try await base.replaceNotebookUtteranceLane(utteranceId: utteranceId, laneLanguage: laneLanguage, text: text, expectedRevision: expectedRevision)
    }
    func projectNotebookRealtimeIncremental(sessionId: String) throws {
        try base.projectNotebookRealtimeIncremental(sessionId: sessionId)
    }
    func cancelNotebookRealtimeProjection(sessionId: String) {
        base.cancelNotebookRealtimeProjection(sessionId: sessionId)
    }
}

/// Writes every callback of a real capture to a JSON Lines file, so the
/// exact stream a recording produced can be replayed later without Soniox.
final class RecordingNotebookCaptureClient: ForwardingNotebookCaptureClient {
    private let output: FileHandle
    private let started = DispatchTime.now()
    private let encoder = JSONEncoder()

    init(base: NotebookCaptureClienting, recordingTo url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        output = try FileHandle(forWritingTo: url)
        super.init(base: base)
    }

    deinit { try? output.close() }

    private func write(event: NotebookCaptureEventDTO?, preview: NotebookCaptureLivePreviewDTO?) {
        let atMs = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
        guard var line = try? encoder.encode(
            LiveCaptureRecordedCallback(atMs: atMs, event: event, preview: preview)
        ) else { return }
        line.append(0x0A)
        output.write(line)
    }

    override func startNotebookCaptureSession(
        notebookId: String,
        profileRevision: UInt64,
        confirmedContextDigest: String?,
        onCaptureEvent: @escaping @MainActor @Sendable (NotebookCaptureEventDTO) -> Void,
        onLivePreview: @escaping @MainActor @Sendable (NotebookCaptureLivePreviewDTO) -> Void
    ) throws -> NotebookCaptureEventDTO {
        let initial = try base.startNotebookCaptureSession(
            notebookId: notebookId,
            profileRevision: profileRevision,
            confirmedContextDigest: confirmedContextDigest,
            onCaptureEvent: { [weak self] event in
                self?.write(event: event, preview: nil)
                onCaptureEvent(event)
            },
            onLivePreview: { [weak self] preview in
                self?.write(event: nil, preview: preview)
                onLivePreview(preview)
            }
        )
        write(event: initial, preview: nil)
        return initial
    }
}

/// Plays a recorded callback stream into the capture store instead of the
/// provider's. The real core still runs a local-only capture underneath, so
/// the session, its history entry and every other call are genuine; only
/// what the provider would have said comes from the file, and nothing goes
/// over the network.
final class ReplayingNotebookCaptureClient: ForwardingNotebookCaptureClient {
    /// The profile the recording was made with. The core itself captures
    /// locally, so the store is shown this one in its place.
    let recordedProfile: (NotebookCaptureProfileDTO) -> NotebookCaptureProfileDTO
    private(set) var sessionId: String?
    private var onCaptureEvent: (@MainActor @Sendable (NotebookCaptureEventDTO) -> Void)?
    private var onLivePreview: (@MainActor @Sendable (NotebookCaptureLivePreviewDTO) -> Void)?
    private var rows: [UInt64: NotebookCaptureUtteranceDTO] = [:]
    private var cues: [String: NotebookCaptureTranslationCueDTO] = [:]
    private var lastEvent: NotebookCaptureEventDTO?

    init(
        base: NotebookCaptureClienting,
        recordedProfile: @escaping (NotebookCaptureProfileDTO) -> NotebookCaptureProfileDTO
    ) {
        self.recordedProfile = recordedProfile
        super.init(base: base)
    }

    override func getNotebookCaptureProfile(notebookId: String) throws -> NotebookCaptureProfileDTO {
        recordedProfile(try base.getNotebookCaptureProfile(notebookId: notebookId))
    }

    override func startNotebookCaptureSession(
        notebookId: String,
        profileRevision: UInt64,
        confirmedContextDigest: String?,
        onCaptureEvent: @escaping @MainActor @Sendable (NotebookCaptureEventDTO) -> Void,
        onLivePreview: @escaping @MainActor @Sendable (NotebookCaptureLivePreviewDTO) -> Void
    ) throws -> NotebookCaptureEventDTO {
        self.onCaptureEvent = onCaptureEvent
        self.onLivePreview = onLivePreview
        let initial = try base.startNotebookCaptureSession(
            notebookId: notebookId,
            profileRevision: profileRevision,
            confirmedContextDigest: confirmedContextDigest,
            onCaptureEvent: { _ in },
            onLivePreview: { _ in }
        )
        sessionId = initial.sessionId
        return initial
    }

    /// Hands one recorded callback to the store, keeping the state a repair
    /// would read back.
    @MainActor
    func deliver(_ callback: LiveCaptureRecordedCallback) {
        if let event = callback.event {
            if event.isFullSnapshot {
                rows = [:]
                cues = [:]
            }
            for sequence in event.removedSequences { rows[sequence] = nil }
            for row in event.utterances {
                if let current = rows[row.sequence], current.revision > row.revision { continue }
                rows[row.sequence] = row
            }
            for cue in event.translationCues {
                if cue.withdrawn { cues[cue.id] = nil } else { cues[cue.id] = cue }
            }
            lastEvent = event
            onCaptureEvent?(event)
        }
        if let preview = callback.preview {
            onLivePreview?(preview)
        }
    }

    private func snapshot(sessionId: String) throws -> NotebookCaptureEventDTO {
        guard let lastEvent else { return try base.getNotebookCaptureSessionEvent(sessionId: sessionId) }
        let encoded = try JSONEncoder().encode(lastEvent)
        var object = try XCTUnwrapJSONObject(encoded)
        object["isFullSnapshot"] = true
        object["removedSequences"] = []
        object["utterances"] = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(rows.values.sorted { $0.sequence < $1.sequence })
        )
        object["translationCues"] = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(Array(cues.values))
        )
        return try JSONDecoder().decode(
            NotebookCaptureEventDTO.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
    }

    override func getNotebookCaptureSessionEvent(sessionId: String) throws -> NotebookCaptureEventDTO {
        sessionId == self.sessionId ? try snapshot(sessionId: sessionId) : try base.getNotebookCaptureSessionEvent(sessionId: sessionId)
    }

    override func reconcileNotebookCaptureSessionEvent(sessionId: String) async throws -> NotebookCaptureEventDTO {
        sessionId == self.sessionId ? try snapshot(sessionId: sessionId) : try await base.reconcileNotebookCaptureSessionEvent(sessionId: sessionId)
    }

    override func listNotebookCaptureUtterances(sessionId: String) throws -> [NotebookCaptureUtteranceDTO] {
        sessionId == self.sessionId
            ? rows.values.sorted { $0.sequence < $1.sequence }
            : try base.listNotebookCaptureUtterances(sessionId: sessionId)
    }

    override func projectNotebookRealtimeIncremental(sessionId: String) throws {}

    override func loadNotebookCaptureHistorySummaries(notebookId: String) async throws -> [NotebookCaptureHistoryRunDTO] {
        patch(try await base.loadNotebookCaptureHistorySummaries(notebookId: notebookId))
    }

    override func listNotebookCaptureHistorySummaries(notebookId: String) throws -> [NotebookCaptureHistoryRunDTO] {
        patch(try base.listNotebookCaptureHistorySummaries(notebookId: notebookId))
    }

    /// The core recorded locally; the history shows the run as recorded.
    private func patch(_ runs: [NotebookCaptureHistoryRunDTO]) -> [NotebookCaptureHistoryRunDTO] {
        guard let lastEvent else { return runs }
        return runs.map { run in
            guard run.sessionId == sessionId else { return run }
            return NotebookCaptureHistoryRunDTO(
                sessionId: run.sessionId,
                createdAt: run.createdAt,
                completedAt: run.completedAt,
                captureState: run.captureState,
                remoteHealth: run.remoteHealth,
                projectionState: run.projectionState,
                asyncTaskState: run.asyncTaskState,
                asyncProjectionState: run.asyncProjectionState,
                durationMs: run.durationMs,
                capturedFrames: run.capturedFrames,
                hasAudio: run.hasAudio,
                mode: lastEvent.mode,
                languageA: lastEvent.languageA,
                languageB: lastEvent.languageB,
                leftLanguage: lastEvent.leftLanguage,
                rightLanguage: lastEvent.rightLanguage,
                privacyLevel: run.privacyLevel,
                utterances: run.utterances,
                selectedLanguages: lastEvent.selectedLanguages,
                commonCaptionLanguage: nil,
                realtimeLoroAppliedRevision: run.realtimeLoroAppliedRevision
            )
        }
    }
}

private func XCTUnwrapJSONObject(_ data: Data) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw NSError(domain: "LiveCaptureReplay", code: 2)
    }
    return object
}
