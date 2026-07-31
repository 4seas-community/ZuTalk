import AVFoundation
import Combine
import Foundation
import Synchronization

// MARK: - Capture contracts

/// Swift display model for the Rust-owned capture state machine. Raw values
/// deliberately match the schema/API contract so the eventual UniFFI adapter
/// remains a mechanical mapping instead of a second state machine.
enum NotebookCaptureState: String, Codable, CaseIterable, Equatable {
    case recording
    case paused
    case draining
    case completed
    case interrupted
    case failed

    var isActive: Bool {
        self == .recording || self == .paused || self == .draining
    }
}

enum NotebookRemoteHealth: String, Codable, CaseIterable, Equatable {
    case off
    case connecting
    case live
    case degraded
    case unavailable
}

enum NotebookProjectionState: String, Codable, CaseIterable, Equatable {
    case pending
    case projecting
    case ready
    case failed
}

/// Durable state of the local Async Transcript materialization. This is
/// intentionally independent from `postStopAsyncState`, which describes the
/// remote provider task. Retrying this state never uploads audio again.
enum NotebookAsyncProjectionState: String, Codable, CaseIterable, Equatable {
    case none
    case pending
    case projecting
    case ready
    case failed
}

enum NotebookCaptureMode: String, Codable, CaseIterable, Identifiable, Equatable {
    case transcriptionOnly = "transcription_only"
    case twoWay = "two_way"
    case multilingualOneWay = "multilingual_one_way"

    var id: String { rawValue }
}

struct NotebookCaptureProfileDTO: Codable, Equatable {
    var notebookId: String
    var remoteRealtimeEnabled: Bool
    var mode: NotebookCaptureMode
    var languageA: String
    var languageB: String
    var leftLanguage: String
    var rightLanguage: String
    var privacyLevel: NotebookAudioRetentionLevel
    var sendContextToSoniox: Bool
    var revision: UInt64
    /// Canonical user-ordered language columns. Empty values are accepted only
    /// as a compatibility signal from an older generated FFI and are resolved
    /// locally from the legacy left/right pair before presentation or save.
    var selectedLanguages: [String] = []
    /// Legacy compatibility only. New captures have no privileged caption
    /// language: every selected language is an equal output column.
    var commonCaptionLanguage: String? = nil

    static func localDefault(notebookId: String) -> Self {
        Self(
            notebookId: notebookId,
            remoteRealtimeEnabled: false,
            mode: .transcriptionOnly,
            languageA: "en",
            languageB: "zh",
            leftLanguage: "en",
            rightLanguage: "zh",
            privacyLevel: .standard,
            sendContextToSoniox: false,
            revision: 0,
            selectedLanguages: ["en", "zh"],
            commonCaptionLanguage: nil
        )
    }
}

struct NotebookCaptureContextSourceDTO: Codable, Equatable, Identifiable {
    let id: String
    let title: String
    let packKind: String
    let scalarCount: Int
    let included: Bool
    let reason: String?
}

struct NotebookCaptureContextPreviewDTO: Codable, Equatable {
    let notebookId: String
    let serializedContext: String
    let sources: [NotebookCaptureContextSourceDTO]
    let omittedReasons: [String]
    let digest: String
    let scalarCount: Int

    var containsSendableContext: Bool {
        let serialized = serializedContext.trimmingCharacters(in: .whitespacesAndNewlines)
        return serialized.isEmpty == false && serialized != "{}"
    }
}

/// Only a receipt supplied by Rust after the provider accepted a capture
/// snapshot may be shown as "applied". A binding or preview is never enough.
struct NotebookCaptureContextReceiptDTO: Codable, Equatable {
    let digest: String
    let applied: Bool
    let provider: String
    let model: String
    let appliedAt: String
}

struct NotebookContextPackDTO: Codable, Equatable, Identifiable {
    let id: String
    let scope: String
    let ownerNotebookId: String?
    let title: String
    let revision: UInt64
    let boundPosition: UInt64?

    var isPrivate: Bool { scope == "private" }
    var isBound: Bool { isPrivate || boundPosition != nil }
}

struct NotebookContextPackSourceDTO: Codable, Equatable, Identifiable {
    let id: String
    let packId: String
    let title: String
    let format: String
    let contentKind: String
    let plaintextSha256: String
    let plaintextBytes: UInt64
    let trusted: Bool
    let revision: UInt64
}

struct NotebookCaptureUtteranceDTO: Codable, Equatable, Identifiable {
    let id: String
    let sessionId: String
    let sequence: UInt64
    var sessionSpeakerId: String? = nil
    /// Aggregate provider-machine revision; never use this for a lane edit CAS.
    var revision: UInt64
    var sourceLanguage: String
    /// Display-only hint from the live speculative tail: the unambiguous
    /// pending provider language while `sourceLanguage` is still `und`.
    /// Never present on durable rows.
    var provisionalSourceLanguage: String? = nil
    var sourceText: String
    var sourceStartMs: UInt64?
    var sourceEndMs: UInt64?
    var translatedLanguage: String?
    var translatedText: String?
    var completion: String
    var alignment: String
    /// One independently progressing output per language. Legacy sessions can
    /// leave this empty and are projected from the source/translated shadow
    /// fields above.
    var languageVariants: [NotebookCaptureLanguageVariantDTO] = []
    /// Session Loro watermark at which the immutable source Final was emitted.
    var sourceProjectionRevision: UInt64 = 0
    /// Lane-local revision of the source's user-visible override.
    var sourceEditRevision: UInt64 = 0

    /// The normalized source variant is authoritative. Aggregate source
    /// fields may remain as inert compatibility bytes when a translation Final
    /// keeps the utterance shell alive after a speculative source withdrawal.
    var hasSourceLane: Bool {
        let sourceVariants = languageVariants.filter { $0.role == "source" }
        if sourceVariants.isEmpty {
            return languageVariants.isEmpty
        }
        return sourceVariants.contains {
            $0.state == "ready" && $0.text != nil && $0.completion != nil
        }
    }

    func isFinalLane(language: String) -> Bool {
        let language = Self.languageKey(language)
        if hasSourceLane && Self.languageKey(sourceLanguage) == language {
            return completion == "complete"
        }
        if let variant = languageVariants.first(where: {
            Self.languageKey($0.language) == language
        }) {
            return ["translation", "translated"].contains(variant.role)
                && variant.state == "ready"
                && variant.completion == "complete"
                && variant.text != nil
        }
        return translatedLanguage.map(Self.languageKey) == language
            && translatedText != nil
            && completion == "complete"
    }

    var hasFinalLaneReadyForProjection: Bool {
        if hasSourceLane && completion == "complete" {
            return true
        }
        return languageVariants.contains {
            ["translation", "translated"].contains($0.role)
                && $0.state == "ready"
                && $0.completion == "complete"
                && $0.text != nil
        }
    }

    func isLoroEditableLane(
        language: String,
        appliedRevision: UInt64
    ) -> Bool {
        let language = Self.languageKey(language)
        if hasSourceLane && Self.languageKey(sourceLanguage) == language {
            return completion == "complete"
                && sourceProjectionRevision > 0
                && sourceProjectionRevision <= appliedRevision
        }
        guard let variant = languageVariants.first(where: {
            Self.languageKey($0.language) == language
        }) else { return false }
        return ["translation", "translated"].contains(variant.role)
            && variant.state == "ready"
            && variant.completion == "complete"
            && variant.text != nil
            && variant.projectionRevision > 0
            && variant.projectionRevision <= appliedRevision
    }

    func mergingCommittedLane(
        from committed: NotebookCaptureUtteranceDTO,
        language: String
    ) -> NotebookCaptureUtteranceDTO {
        guard id == committed.id, sessionId == committed.sessionId else { return self }
        let language = Self.languageKey(language)
        var merged = self
        merged.revision = max(revision, committed.revision)

        if committed.hasSourceLane
            && Self.languageKey(committed.sourceLanguage) == language {
            merged.sourceText = committed.sourceText
            merged.sourceProjectionRevision = max(
                sourceProjectionRevision,
                committed.sourceProjectionRevision
            )
            merged.sourceEditRevision = max(
                sourceEditRevision,
                committed.sourceEditRevision
            )
            if let index = merged.languageVariants.firstIndex(where: {
                Self.languageKey($0.language) == language
            }),
            let committedVariant = committed.languageVariants.first(where: {
                Self.languageKey($0.language) == language
            }) {
                merged.languageVariants[index].text = committedVariant.text
                merged.languageVariants[index].projectionRevision = max(
                    merged.languageVariants[index].projectionRevision,
                    committedVariant.projectionRevision
                )
                merged.languageVariants[index].editRevision = max(
                    merged.languageVariants[index].editRevision,
                    committedVariant.editRevision
                )
            }
            return merged
        }

        let committedVariant = committed.languageVariants.first {
            Self.languageKey($0.language) == language
        }
        let committedLaneText: String?
        if let committedVariant {
            committedLaneText = committedVariant.text
        } else if committed.translatedLanguage.map(Self.languageKey) == language {
            committedLaneText = committed.translatedText
        } else {
            committedLaneText = nil
        }
        if let index = merged.languageVariants.firstIndex(where: {
            Self.languageKey($0.language) == language
        }) {
            merged.languageVariants[index].text = committedLaneText
            if let committedVariant {
                merged.languageVariants[index].projectionRevision = max(
                    merged.languageVariants[index].projectionRevision,
                    committedVariant.projectionRevision
                )
                merged.languageVariants[index].editRevision = max(
                    merged.languageVariants[index].editRevision,
                    committedVariant.editRevision
                )
            }
        } else if let committedVariant {
            merged.languageVariants.append(committedVariant)
        }
        if merged.translatedLanguage.map(Self.languageKey) == language {
            merged.translatedText = committedLaneText
        }
        return merged
    }

    func laneText(language: String) -> String? {
        let language = Self.languageKey(language)
        if hasSourceLane && Self.languageKey(sourceLanguage) == language {
            return sourceText
        }
        if let variant = languageVariants.first(where: {
            Self.languageKey($0.language) == language
        }) {
            return variant.text
        }
        guard translatedLanguage.map(Self.languageKey) == language else { return nil }
        return translatedText
    }

    func laneEditRevision(language: String) -> UInt64 {
        let language = Self.languageKey(language)
        if hasSourceLane && Self.languageKey(sourceLanguage) == language {
            return sourceEditRevision
        }
        return languageVariants.first {
            Self.languageKey($0.language) == language
        }?.editRevision ?? 0
    }

    nonisolated static func languageKey(_ language: String) -> String {
        language
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(separator: "-")
            .first
            .map(String.init) ?? ""
    }
}

private struct NotebookCaptureLaneMutationKey: Hashable {
    let utteranceId: String
    let language: String

    init(utteranceId: String, language: String) {
        self.utteranceId = utteranceId
        self.language = NotebookCaptureUtteranceDTO.languageKey(language)
    }
}

private struct NotebookCaptureCommittedLaneOverrideBarrier {
    let machineRevision: UInt64
    let committedUtterance: NotebookCaptureUtteranceDTO
}

struct NotebookCaptureLanguageVariantDTO: Codable, Equatable, Identifiable {
    var language: String
    var role: String
    var text: String?
    var state: String
    var completion: String?
    var projectionRevision: UInt64 = 0
    var editRevision: UInt64 = 0

    var id: String { language }
}

struct SpeakerParticipantDTO: Codable, Equatable, Identifiable {
    let id: String
    var displayName: String
}

struct NotebookSessionSpeakerDTO: Codable, Equatable, Identifiable {
    let id: String
    let sessionId: String
    let providerSessionEpoch: UInt64
    let provider: String
    let providerLabel: String
    var localDisplayName: String?
    var participantId: String?
}

/// One durable recording run in a Notebook timeline. A run remains visible
/// even when remote processing was off and therefore produced no utterances.
/// The optional mode/language fields preserve a fail-closed distinction
/// between a valid historical snapshot and legacy/corrupt rows.
struct NotebookCaptureHistoryRunDTO: Equatable, Identifiable {
    let sessionId: String
    let createdAt: String
    let completedAt: String?
    let captureState: NotebookCaptureState
    let remoteHealth: NotebookRemoteHealth
    let projectionState: NotebookProjectionState
    let asyncTaskState: String
    let asyncProjectionState: NotebookAsyncProjectionState
    let durationMs: UInt64?
    let capturedFrames: UInt64
    let hasAudio: Bool
    let mode: NotebookCaptureMode?
    let languageA: String?
    let languageB: String?
    let leftLanguage: String?
    let rightLanguage: String?
    let privacyLevel: NotebookAudioRetentionLevel?
    let utterances: [NotebookCaptureUtteranceDTO]
    /// Frozen per-run column order. `var` only preserves source compatibility
    /// with existing fixture memberwise initializers; presentation never mutates it.
    var selectedLanguages: [String] = []
    var commonCaptionLanguage: String? = nil
    var realtimeLoroAppliedRevision: UInt64 = 0

    var id: String { sessionId }

    func replacingUtterances(
        _ utterances: [NotebookCaptureUtteranceDTO]
    ) -> NotebookCaptureHistoryRunDTO {
        NotebookCaptureHistoryRunDTO(
            sessionId: sessionId,
            createdAt: createdAt,
            completedAt: completedAt,
            captureState: captureState,
            remoteHealth: remoteHealth,
            projectionState: projectionState,
            asyncTaskState: asyncTaskState,
            asyncProjectionState: asyncProjectionState,
            durationMs: durationMs,
            capturedFrames: capturedFrames,
            hasAudio: hasAudio,
            mode: mode,
            languageA: languageA,
            languageB: languageB,
            leftLanguage: leftLanguage,
            rightLanguage: rightLanguage,
            privacyLevel: privacyLevel,
            utterances: utterances,
            selectedLanguages: selectedLanguages,
            commonCaptionLanguage: commonCaptionLanguage,
            realtimeLoroAppliedRevision: realtimeLoroAppliedRevision
        )
    }
}

/// Derived presentation only. Changing this value never updates a capture
/// profile, run snapshot, utterance, or audio fact in Rust.
enum NotebookTranscriptPresentationMode: String, CaseIterable, Identifiable, Equatable {
    case sourceTimeline
    case bilingualColumns

    var id: String { rawValue }
}

struct NotebookCaptureEventDTO: Codable, Equatable {
    let sessionId: String
    let eventRevision: UInt64
    let isFullSnapshot: Bool
    let captureState: NotebookCaptureState
    let remoteHealth: NotebookRemoteHealth
    var realtimeLagMs: UInt64? = nil
    let projectionState: NotebookProjectionState
    let utterances: [NotebookCaptureUtteranceDTO]
    let contextReceipt: NotebookCaptureContextReceiptDTO?
    let providerErrorType: String?
    let providerRequestId: String?
    let mode: NotebookCaptureMode?
    let languageA: String?
    let languageB: String?
    let leftLanguage: String?
    let rightLanguage: String?
    let privacyLevel: NotebookAudioRetentionLevel?
    let realtimeProviderId: String?
    let realtimeModelId: String?
    let postStopProviderId: String?
    let postStopModelId: String?
    let postStopAsyncState: String
    let postStopAsyncProjectionState: NotebookAsyncProjectionState
    let selectedLanguages: [String]
    let commonCaptionLanguage: String?
    let realtimeLoroAppliedRevision: UInt64

    init(
        sessionId: String,
        eventRevision: UInt64 = 0,
        isFullSnapshot: Bool = true,
        captureState: NotebookCaptureState,
        remoteHealth: NotebookRemoteHealth,
        realtimeLagMs: UInt64? = nil,
        projectionState: NotebookProjectionState,
        utterances: [NotebookCaptureUtteranceDTO],
        contextReceipt: NotebookCaptureContextReceiptDTO?,
        providerErrorType: String?,
        providerRequestId: String?,
        mode: NotebookCaptureMode? = nil,
        languageA: String? = nil,
        languageB: String? = nil,
        leftLanguage: String? = nil,
        rightLanguage: String? = nil,
        privacyLevel: NotebookAudioRetentionLevel? = nil,
        realtimeProviderId: String? = nil,
        realtimeModelId: String? = nil,
        postStopProviderId: String? = nil,
        postStopModelId: String? = nil,
        postStopAsyncState: String = "none",
        postStopAsyncProjectionState: NotebookAsyncProjectionState = .none,
        selectedLanguages: [String] = [],
        commonCaptionLanguage: String? = nil,
        realtimeLoroAppliedRevision: UInt64 = 0
    ) {
        self.sessionId = sessionId
        self.eventRevision = eventRevision
        self.isFullSnapshot = isFullSnapshot
        self.captureState = captureState
        self.remoteHealth = remoteHealth
        self.realtimeLagMs = realtimeLagMs
        self.projectionState = projectionState
        self.utterances = utterances
        self.contextReceipt = contextReceipt
        self.providerErrorType = providerErrorType
        self.providerRequestId = providerRequestId
        self.mode = mode
        self.languageA = languageA
        self.languageB = languageB
        self.leftLanguage = leftLanguage
        self.rightLanguage = rightLanguage
        self.privacyLevel = privacyLevel
        self.realtimeProviderId = realtimeProviderId
        self.realtimeModelId = realtimeModelId
        self.postStopProviderId = postStopProviderId
        self.postStopModelId = postStopModelId
        self.postStopAsyncState = postStopAsyncState
        self.postStopAsyncProjectionState = postStopAsyncProjectionState
        self.selectedLanguages = selectedLanguages
        self.commonCaptionLanguage = commonCaptionLanguage
        self.realtimeLoroAppliedRevision = realtimeLoroAppliedRevision
    }
}

/// Replace-in-full, process-local view of the current Soniox speculative tail.
/// It never represents a persisted transcript row.
struct NotebookCaptureLivePreviewDTO: Equatable {
    let sessionId: String
    let previewRevision: UInt64
    let utterances: [NotebookCaptureUtteranceDTO]
}

enum NotebookCaptureLivePresentation {
    static func utterances(
        durable: [NotebookCaptureUtteranceDTO],
        preview: [NotebookCaptureUtteranceDTO],
        sessionId: String?
    ) -> [NotebookCaptureUtteranceDTO] {
        guard let sessionId else { return durable }
        var rows = durable.filter { $0.sessionId == sessionId }
        let durableSequences = Set(rows.map(\.sequence))
        rows.append(contentsOf: preview.filter {
            $0.sessionId == sessionId && durableSequences.contains($0.sequence) == false
        })
        return rows.sorted { $0.sequence < $1.sequence }
    }
}

enum NotebookCaptureInterruptReason: String, Codable, Equatable, Sendable {
    case localAudioOverflow = "local_audio_overflow"
    case localAudioUnavailable = "local_audio_unavailable"
}

/// Stable Swift seam for the UniFFI surface. Method names mirror the product
/// contract, and the default implementation fails closed when no live adapter
/// is available.
protocol NotebookCaptureClienting: AnyObject {
    func getNotebookCaptureProfile(notebookId: String) throws -> NotebookCaptureProfileDTO
    func updateNotebookCaptureProfile(_ profile: NotebookCaptureProfileDTO) throws -> NotebookCaptureProfileDTO
    func previewNotebookCaptureContext(notebookId: String) throws -> NotebookCaptureContextPreviewDTO
    func listNotebookContextPacks(notebookId: String) throws -> [NotebookContextPackDTO]
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
    func importContextPackFile(
        notebookId: String,
        packId: String,
        path: String,
        contentKind: String
    ) throws -> NotebookContextPackSourceDTO
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
    /// Keeps lightweight test/platform clients source-compatible while the
    /// live Rust adapter remains the only production history implementation.
    func listNotebookCaptureHistory(
        notebookId: String
    ) throws -> [NotebookCaptureHistoryRunDTO] {
        throw NotebookCaptureClientError.ffiUnavailable
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
        label: "xyz.voice.zulangue.realtime-projection",
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
    private let coreProvider: @MainActor () -> (any ZulangueCoreProtocol)?
    private let realtimeProjectionScheduler = NotebookRealtimeProjectionScheduler()

    init(
        coreProvider: @escaping @MainActor () -> (any ZulangueCoreProtocol)? = {
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

    func importContextPackFile(
        notebookId: String,
        packId: String,
        path: String,
        contentKind: String
    ) throws -> NotebookContextPackSourceDTO {
        Self.map(try requireCore().importContextPackFile(
            notebookId: notebookId,
            packId: packId,
            path: path,
            contentKind: contentKind
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

    private func requireCore() throws -> any ZulangueCoreProtocol {
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
            utterances: value.utterances.map(Self.map)
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
    case contextConfirmationRequired
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
        case .contextConfirmationRequired:
            return String(localized: "capture.error.context_confirmation_required")
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

    func importContextPackFile(
        notebookId: String,
        packId: String,
        path: String,
        contentKind: String
    ) throws -> NotebookContextPackSourceDTO {
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

// MARK: - Notebook capture history presentation

/// A language-safe presentation of one utterance. An unknown provider language
/// stays outside the fixed columns; only a known non-pair language is presented
/// as `outsidePair`.
enum NotebookCaptureMissingLaneState: Equatable {
    case waiting
    case failed
    case unavailable
}

struct NotebookCaptureLaneTexts: Equatable {
    let left: String?
    let right: String?
    let outsidePair: String?
    let pendingLanguage: String?
    let missingLaneState: NotebookCaptureMissingLaneState
}

struct NotebookCaptureLanguageLane: Identifiable, Equatable {
    let language: String
    let text: String?
    let missingLaneState: NotebookCaptureMissingLaneState

    var id: String { language }
}

/// Ordered presentation facts for an arbitrary number of configured language
/// columns. Source and translated provenance remains in the utterance DTO; this
/// value deliberately exposes only equal-weight display lanes.
struct NotebookCaptureLaneProjection: Equatable {
    let lanes: [NotebookCaptureLanguageLane]
    let pendingLanguage: String?
    let unselectedLanguageText: String?
}

enum NotebookCaptureHistoryPolicy {
    /// RFC 3339 timestamps sort lexicographically. The session id provides a
    /// deterministic tie-breaker for imported or repaired rows that share the
    /// same creation instant.
    static func orderedRuns(
        _ runs: [NotebookCaptureHistoryRunDTO]
    ) -> [NotebookCaptureHistoryRunDTO] {
        runs.sorted { lhs, rhs in
            let lhsDate = parsedTimestamp(lhs.createdAt)
            let rhsDate = parsedTimestamp(rhs.createdAt)
            if let lhsDate, let rhsDate, lhsDate != rhsDate {
                return lhsDate < rhsDate
            }
            if lhs.createdAt != rhs.createdAt, lhsDate == nil || rhsDate == nil {
                return lhs.createdAt < rhs.createdAt
            }
            return lhs.sessionId < rhs.sessionId
        }
    }

    static func defaultPresentation(
        for runs: [NotebookCaptureHistoryRunDTO]
    ) -> NotebookTranscriptPresentationMode {
        guard let latest = orderedRuns(runs).last,
              displayLanguages(for: latest)?.isEmpty == false
        else { return .sourceTimeline }
        return .bilingualColumns
    }

    static func hasValidLanguageSelection(_ run: NotebookCaptureHistoryRunDTO) -> Bool {
        guard let mode = run.mode,
              let languages = displayLanguagesUnchecked(for: run),
              (1...8).contains(languages.count)
        else { return false }
        if mode == .multilingualOneWay, languages.count < 3 { return false }
        return true
    }

    static func hasValidLanguagePair(_ run: NotebookCaptureHistoryRunDTO) -> Bool {
        guard run.mode == .twoWay,
              let languages = displayLanguages(for: run),
              languages.count == 2
        else { return false }
        guard let languageA = normalizedLanguage(run.languageA),
              let languageB = normalizedLanguage(run.languageB),
              languageA != languageB
        else { return false }
        return Set(languages) == Set([languageA, languageB])
    }

    static func displayLanguages(
        for run: NotebookCaptureHistoryRunDTO
    ) -> [String]? {
        guard hasValidLanguageSelection(run) else { return nil }
        return displayLanguagesUnchecked(for: run)
    }

    /// Canonicalizes an explicit ordered selection and falls back only when a
    /// locally older FFI record still carries the valid legacy display pair.
    /// An empty explicit selection plus empty legacy fields stays empty so a
    /// corrupt immutable run snapshot remains fail-closed.
    static func resolvedSelectedLanguages(
        _ selectedLanguages: [String],
        legacyLeftLanguage: String?,
        legacyRightLanguage: String?
    ) -> [String] {
        let explicit = orderedLanguages(selectedLanguages)
        if explicit.isEmpty == false { return explicit }
        return orderedLanguages([legacyLeftLanguage, legacyRightLanguage].compactMap { $0 })
    }

    static func resolvedCommonCaptionLanguage(
        _ commonCaptionLanguage: String?,
        selectedLanguages: [String]
    ) -> String? {
        guard let common = normalizedLanguage(commonCaptionLanguage),
              selectedLanguages.contains(common)
        else { return nil }
        return common
    }

    /// Legacy snapshot compatibility only. Current presentation and capture
    /// routing never give this language a privileged role.
    static func resolvedCommonCaptionLanguage(
        _ commonCaptionLanguage: String?,
        selectedLanguages: [String],
        mode: NotebookCaptureMode?
    ) -> String? {
        guard let common = resolvedCommonCaptionLanguage(
            commonCaptionLanguage,
            selectedLanguages: selectedLanguages
        ) else { return nil }
        _ = mode
        return common
    }

    static func laneProjection(
        for utterance: NotebookCaptureUtteranceDTO,
        selectedLanguages: [String],
        commonCaptionLanguage: String?
    ) -> NotebookCaptureLaneProjection {
        _ = commonCaptionLanguage
        let languages = orderedLanguages(selectedLanguages)
        var textsByLanguage: [String: String] = [:]
        var stateByLanguage: [String: NotebookCaptureMissingLaneState] = [:]
        for variant in utterance.languageVariants {
            guard let language = normalizedLanguage(variant.language),
                  languages.contains(language)
            else { continue }
            if let text = variant.text?.trimmingCharacters(in: .whitespacesAndNewlines),
               text.isEmpty == false {
                textsByLanguage[language] = text
            }
            switch variant.state {
            case "waiting":
                stateByLanguage[language] = .waiting
            case "failed":
                stateByLanguage[language] = .failed
            default:
                stateByLanguage[language] = .unavailable
            }
        }

        let source = normalizedLanguage(utterance.sourceLanguage)
        if utterance.hasSourceLane,
           let source, source != "und",
           languages.contains(source),
           utterance.sourceText.isEmpty == false {
            textsByLanguage[source] = utterance.sourceText
        }
        // While the durable identity is still `und`, the live tail's
        // provisional provider language places the text in its lane
        // immediately instead of a full-width language-pending row. A later
        // provider correction re-homes the text on the next callback.
        if utterance.hasSourceLane,
           source == nil || source == "und",
           let provisional = normalizedLanguage(utterance.provisionalSourceLanguage),
           provisional != "und",
           languages.contains(provisional),
           utterance.sourceText.isEmpty == false,
           textsByLanguage[provisional] == nil {
            textsByLanguage[provisional] = utterance.sourceText
        }
        let translated = normalizedLanguage(utterance.translatedLanguage)
        if let translated,
           languages.contains(translated),
           textsByLanguage[translated] == nil,
           let translatedText = utterance.translatedText,
           translatedText.isEmpty == false {
            textsByLanguage[translated] = translatedText
        }

        let legacyWaiting = missingLaneState(for: utterance) == .waiting
        let lanes = languages.map { language in
            let missingState: NotebookCaptureMissingLaneState
            if textsByLanguage[language] != nil {
                missingState = .unavailable
            } else if let state = stateByLanguage[language] {
                missingState = state
            } else if legacyWaiting, language != source {
                missingState = .waiting
            } else {
                missingState = .unavailable
            }
            return NotebookCaptureLanguageLane(
                language: language,
                text: textsByLanguage[language],
                missingLaneState: missingState
            )
        }
        let sourceLanguageIsPending = source == nil || source == "und"
        let hasVisibleLaneText = lanes.contains {
            $0.text?.isEmpty == false
        }
        return NotebookCaptureLaneProjection(
            lanes: lanes,
            pendingLanguage: utterance.hasSourceLane
                && sourceLanguageIsPending
                && hasVisibleLaneText == false
                ? utterance.sourceText
                : nil,
            unselectedLanguageText: utterance.hasSourceLane
                && !sourceLanguageIsPending
                && source.map { !languages.contains($0) } == true
                ? utterance.sourceText
                : nil
        )
    }

    /// Response-order pairing is the durable source fact. An unidentified
    /// source stays pending outside both columns, while a known third language
    /// uses the full-width outside-pair presentation. A missing translated lane
    /// stays nil; its state decides between a live waiting cue and a neutral
    /// completed placeholder.
    static func laneTexts(
        for utterance: NotebookCaptureUtteranceDTO,
        leftLanguage: String,
        rightLanguage: String
    ) -> NotebookCaptureLaneTexts {
        let languages = orderedLanguages([leftLanguage, rightLanguage])
        let projection = laneProjection(
            for: utterance,
            selectedLanguages: languages,
            commonCaptionLanguage: nil
        )
        return NotebookCaptureLaneTexts(
            left: projection.lanes.first?.text,
            right: projection.lanes.dropFirst().first?.text,
            outsidePair: projection.unselectedLanguageText,
            pendingLanguage: projection.pendingLanguage,
            missingLaneState: projection.lanes.contains { $0.missingLaneState == .waiting }
                ? .waiting
                : .unavailable
        )
    }

    /// Realtime callbacks overlay only the matching durable run. Other runs in
    /// the Notebook history remain untouched and are never filtered by focus.
    static func overlayActiveRun(
        _ runs: [NotebookCaptureHistoryRunDTO],
        requestedNotebookId: String,
        activeNotebookId: String?,
        activeSessionId: String?,
        isCaptureActive: Bool,
        captureState: NotebookCaptureState,
        remoteHealth: NotebookRemoteHealth,
        projectionState: NotebookProjectionState,
        realtimeLoroAppliedRevision: UInt64,
        profile: NotebookCaptureProfileDTO,
        utterances: [NotebookCaptureUtteranceDTO]
    ) -> [NotebookCaptureHistoryRunDTO] {
        guard isCaptureActive,
              activeNotebookId == requestedNotebookId,
              let activeSessionId
        else { return runs }

        return runs.map { run in
            guard run.sessionId == activeSessionId else { return run }
            return NotebookCaptureHistoryRunDTO(
                sessionId: run.sessionId,
                createdAt: run.createdAt,
                completedAt: run.completedAt,
                captureState: captureState,
                remoteHealth: remoteHealth,
                projectionState: projectionState,
                asyncTaskState: run.asyncTaskState,
                asyncProjectionState: run.asyncProjectionState,
                durationMs: run.durationMs,
                capturedFrames: run.capturedFrames,
                hasAudio: run.hasAudio,
                mode: profile.mode,
                languageA: profile.languageA,
                languageB: profile.languageB,
                leftLanguage: profile.leftLanguage,
                rightLanguage: profile.rightLanguage,
                privacyLevel: profile.privacyLevel,
                utterances: utterances.filter { $0.sessionId == activeSessionId },
                selectedLanguages: resolvedSelectedLanguages(
                    profile.selectedLanguages,
                    legacyLeftLanguage: profile.leftLanguage,
                    legacyRightLanguage: profile.rightLanguage
                ),
                commonCaptionLanguage: nil,
                realtimeLoroAppliedRevision: max(
                    run.realtimeLoroAppliedRevision,
                    realtimeLoroAppliedRevision
                )
            )
        }
    }

    private static func displayLanguagesUnchecked(
        for run: NotebookCaptureHistoryRunDTO
    ) -> [String]? {
        let languages = resolvedSelectedLanguages(
            run.selectedLanguages,
            legacyLeftLanguage: run.leftLanguage,
            legacyRightLanguage: run.rightLanguage
        )
        return languages.isEmpty ? nil : languages
    }

    private static func orderedLanguages(_ languages: [String]) -> [String] {
        var seen: Set<String> = []
        return languages.compactMap { normalizedLanguage($0) }.filter { seen.insert($0).inserted }
    }

    private static func normalizedLanguage(_ language: String?) -> String? {
        guard let language else { return nil }
        let normalized = language
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(separator: "-")
            .first
            .map(String.init) ?? ""
        return normalized.isEmpty ? nil : normalized
    }

    private static func missingLaneState(
        for utterance: NotebookCaptureUtteranceDTO
    ) -> NotebookCaptureMissingLaneState {
        let alignment = utterance.alignment
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let completion = utterance.completion
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return alignment == "translation_pending" && completion == "partial"
            ? .waiting
            : .unavailable
    }

    private static func parsedTimestamp(_ value: String) -> Date? {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = parser.date(from: value) { return date }
        parser.formatOptions = [.withInternetDateTime]
        return parser.date(from: value)
    }
}

/// Notebook-scoped read model for every durable recording run. `focusSessionId`
/// belongs to the view and is deliberately absent from this query API, so
/// opening a historical session cannot hide its siblings.
@MainActor
final class NotebookCaptureHistoryStore: ObservableObject {
    @Published private(set) var runs: [NotebookCaptureHistoryRunDTO] = []
    @Published private(set) var loadedNotebookId: String?
    @Published private(set) var isLoading = false
    @Published private(set) var lastError: String?
    @Published private(set) var presentationByNotebook: [String: NotebookTranscriptPresentationMode] = [:]
    @Published private(set) var speakerParticipants: [SpeakerParticipantDTO] = []
    @Published private(set) var sessionSpeakersBySession: [String: [NotebookSessionSpeakerDTO]] = [:]

    private let client: NotebookCaptureClienting
    private var laneMutationsInFlight: Set<NotebookCaptureLaneMutationKey> = []

    init(client: NotebookCaptureClienting? = nil) {
        self.client = client ?? RustNotebookCaptureClient()
    }

    func load(notebookId: String) {
        guard notebookId.isEmpty == false else { return }
        if loadedNotebookId != notebookId {
            runs = []
            sessionSpeakersBySession = [:]
            loadedNotebookId = notebookId
        }
        isLoading = true
        defer { isLoading = false }

        do {
            runs = NotebookCaptureHistoryPolicy.orderedRuns(
                try client.listNotebookCaptureHistory(notebookId: notebookId)
            )
            lastError = nil
            refreshSpeakerDirectory(for: runs.map(\.sessionId))
        } catch {
            runs = []
            lastError = error.localizedDescription
        }
    }

    func presentationMode(
        for notebookId: String,
        runs: [NotebookCaptureHistoryRunDTO]? = nil
    ) -> NotebookTranscriptPresentationMode {
        presentationByNotebook[notebookId]
            ?? NotebookCaptureHistoryPolicy.defaultPresentation(for: runs ?? self.runs)
    }

    func setPresentationMode(
        _ mode: NotebookTranscriptPresentationMode,
        for notebookId: String
    ) {
        guard notebookId.isEmpty == false else { return }
        var next = presentationByNotebook
        next[notebookId] = mode
        presentationByNotebook = next
    }

    var orderedSpeakerParticipants: [SpeakerParticipantDTO] {
        speakerParticipants.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    func sessionSpeaker(
        id sessionSpeakerId: String?,
        sessionId: String
    ) -> NotebookSessionSpeakerDTO? {
        guard let sessionSpeakerId else { return nil }
        return sessionSpeakersBySession[sessionId]?.first { $0.id == sessionSpeakerId }
    }

    func speakerDisplayName(
        sessionSpeakerId: String?,
        sessionId: String
    ) -> String? {
        guard let sessionSpeakerId else { return nil }
        guard let speaker = sessionSpeaker(id: sessionSpeakerId, sessionId: sessionId) else {
            return String(localized: "capture.speaker.fallback")
        }
        if let localName = normalizedNonEmpty(speaker.localDisplayName) {
            return localName
        }
        if let participantId = speaker.participantId,
           let participant = speakerParticipants.first(where: { $0.id == participantId }),
           let participantName = normalizedNonEmpty(participant.displayName) {
            return participantName
        }
        return String(
            format: String(localized: "capture.speaker.fallback_format"),
            speaker.providerLabel
        )
    }

    /// Speaker metadata is auxiliary to transcript history. A missing or older
    /// core must never make otherwise durable utterances disappear.
    func refreshSessionSpeakers(sessionId: String) {
        guard sessionId.isEmpty == false else { return }
        do {
            replaceSessionSpeakers(
                try client.listNotebookSessionSpeakers(sessionId: sessionId),
                sessionId: sessionId
            )
        } catch {
            // Best effort by design. History remains readable without labels.
        }
    }

    func refreshSpeakerParticipants() {
        do {
            speakerParticipants = orderedParticipants(try client.listSpeakerParticipants())
        } catch {
            // Best effort by design. Existing session-only labels still work.
        }
    }

    @discardableResult
    func renameSessionSpeaker(
        sessionSpeakerId: String,
        localDisplayName: String?
    ) throws -> NotebookSessionSpeakerDTO {
        let updated = try client.renameNotebookSessionSpeaker(
            sessionSpeakerId: sessionSpeakerId,
            localDisplayName: normalizedNonEmpty(localDisplayName)
        )
        upsertSessionSpeaker(updated)
        return updated
    }

    @discardableResult
    func linkSessionSpeaker(
        sessionSpeakerId: String,
        participantId: String
    ) throws -> NotebookSessionSpeakerDTO {
        let updated = try client.linkNotebookSessionSpeaker(
            sessionSpeakerId: sessionSpeakerId,
            participantId: participantId
        )
        upsertSessionSpeaker(updated)
        return updated
    }

    @discardableResult
    func createParticipantAndLink(
        displayName: String,
        sessionSpeakerId: String
    ) throws -> NotebookSessionSpeakerDTO {
        let participant = try client.createSpeakerParticipant(
            displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        upsertParticipant(participant)
        return try linkSessionSpeaker(
            sessionSpeakerId: sessionSpeakerId,
            participantId: participant.id
        )
    }

    @discardableResult
    func renameSpeakerParticipant(
        participantId: String,
        displayName: String
    ) throws -> SpeakerParticipantDTO {
        let updated = try client.renameSpeakerParticipant(
            participantId: participantId,
            displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        upsertParticipant(updated)
        return updated
    }

    @discardableResult
    func unlinkSessionSpeaker(
        sessionSpeakerId: String
    ) throws -> NotebookSessionSpeakerDTO {
        let updated = try client.unlinkNotebookSessionSpeaker(
            sessionSpeakerId: sessionSpeakerId
        )
        upsertSessionSpeaker(updated)
        return updated
    }

    func replaceLane(
        utteranceId: String,
        language: String,
        text: String
    ) async throws {
        let mutationKey = NotebookCaptureLaneMutationKey(
            utteranceId: utteranceId,
            language: language
        )
        guard laneMutationsInFlight.insert(mutationKey).inserted else {
            throw NotebookCaptureClientError.projectionLocked
        }
        defer { laneMutationsInFlight.remove(mutationKey) }

        guard let runIndex = runs.firstIndex(where: { run in
            run.utterances.contains(where: { $0.id == utteranceId })
        }),
        let utteranceIndex = runs[runIndex].utterances.firstIndex(where: {
            $0.id == utteranceId
        }) else {
            throw NotebookCaptureClientError.projectionLocked
        }

        let current = runs[runIndex].utterances[utteranceIndex]
        guard current.isLoroEditableLane(
            language: language,
            appliedRevision: runs[runIndex].realtimeLoroAppliedRevision
        ) else {
            throw NotebookCaptureClientError.projectionLocked
        }
        let updated = try await client.replaceNotebookUtteranceLane(
            utteranceId: utteranceId,
            laneLanguage: mutationKey.language,
            text: text,
            expectedRevision: current.laneEditRevision(language: mutationKey.language)
        )

        // The active overlay or a history refresh may have advanced unrelated
        // fields while SQLite/Loro fsync was in flight. Re-find by durable ID
        // and merge only the committed lane into that newest snapshot.
        guard let latestRunIndex = runs.firstIndex(where: { run in
            run.utterances.contains(where: { $0.id == utteranceId })
        }),
        let latestUtteranceIndex = runs[latestRunIndex].utterances.firstIndex(where: {
            $0.id == utteranceId
        }) else { return }
        let latest = runs[latestRunIndex].utterances[latestUtteranceIndex]
        guard latest.sessionId == updated.sessionId else { return }
        var nextUtterances = runs[latestRunIndex].utterances
        nextUtterances[latestUtteranceIndex] = latest.mergingCommittedLane(
            from: updated,
            language: mutationKey.language
        )
        var nextRuns = runs
        nextRuns[latestRunIndex] = runs[latestRunIndex].replacingUtterances(nextUtterances)
        runs = nextRuns
    }

    func retryProjection(sessionId: String) throws {
        _ = try client.retryNotebookCaptureProjection(sessionId: sessionId)
        guard let loadedNotebookId else { return }
        load(notebookId: loadedNotebookId)
    }

    private func refreshSpeakerDirectory(for sessionIds: [String]) {
        refreshSpeakerParticipants()
        let wantedSessionIds = Set(sessionIds)
        sessionSpeakersBySession = sessionSpeakersBySession.filter {
            wantedSessionIds.contains($0.key)
        }
        for sessionId in wantedSessionIds {
            refreshSessionSpeakers(sessionId: sessionId)
        }
    }

    private func replaceSessionSpeakers(
        _ speakers: [NotebookSessionSpeakerDTO],
        sessionId: String
    ) {
        var next = sessionSpeakersBySession
        next[sessionId] = speakers.sorted(by: Self.sessionSpeakerComesBefore)
        sessionSpeakersBySession = next
    }

    private func upsertSessionSpeaker(_ speaker: NotebookSessionSpeakerDTO) {
        var speakers = sessionSpeakersBySession[speaker.sessionId, default: []]
        if let index = speakers.firstIndex(where: { $0.id == speaker.id }) {
            speakers[index] = speaker
        } else {
            speakers.append(speaker)
        }
        replaceSessionSpeakers(speakers, sessionId: speaker.sessionId)
    }

    private func upsertParticipant(_ participant: SpeakerParticipantDTO) {
        var participants = speakerParticipants
        if let index = participants.firstIndex(where: { $0.id == participant.id }) {
            participants[index] = participant
        } else {
            participants.append(participant)
        }
        speakerParticipants = orderedParticipants(participants)
    }

    private func orderedParticipants(
        _ participants: [SpeakerParticipantDTO]
    ) -> [SpeakerParticipantDTO] {
        participants.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    private func normalizedNonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private static func sessionSpeakerComesBefore(
        _ lhs: NotebookSessionSpeakerDTO,
        _ rhs: NotebookSessionSpeakerDTO
    ) -> Bool {
        if lhs.providerSessionEpoch != rhs.providerSessionEpoch {
            return lhs.providerSessionEpoch < rhs.providerSessionEpoch
        }
        let labelComparison = lhs.providerLabel.localizedStandardCompare(rhs.providerLabel)
        if labelComparison != .orderedSame {
            return labelComparison == .orderedAscending
        }
        return lhs.id < rhs.id
    }
}

// MARK: - Single microphone seam

struct NotebookCaptureAudioToken: Hashable {
    let id: UUID
}

/// Bounded single-consumer queue between the AVAudioEngine tap and Rust.
/// `submit` only performs atomic operations plus a bounded async enqueue; it
/// never waits for a lock or semaphore. Pause/stop atomically close admission,
/// then asynchronously fence all frames accepted before that transition.
final class NotebookCaptureAudioPushGate: @unchecked Sendable {
    enum SubmissionResult: Equatable, Sendable {
        case accepted
        case closed
        case overflow
    }

    private enum State: Int, Sendable {
        case accepting = 0
        case closed = 1
        case overflow = 2
        case pushFailure = 3
        case aborted = 4
    }

    private let queue = DispatchQueue(label: "app.zulangue.notebook-capture-audio")
    private let push: @Sendable (Data) -> String?
    private let onTerminal: @Sendable (String) -> Void
    private let capacity: Int
    private let state = Atomic<Int>(State.accepting.rawValue)
    private let pendingCount = Atomic<Int>(0)
    private let fenceLock = NSLock()
    nonisolated(unsafe) private var fenceWaiters: [CheckedContinuation<Void, Never>] = []
    private let failureLock = NSLock()
    nonisolated(unsafe) private var pushFailureMessage: String?

    nonisolated init(
        capacity: Int = 8,
        push: @escaping @Sendable (Data) -> String?,
        onTerminal: @escaping @Sendable (String) -> Void
    ) {
        self.capacity = max(1, capacity)
        self.push = push
        self.onTerminal = onTerminal
    }

    /// Called directly by the AVAudioEngine tap. At most `capacity` accepted
    /// blocks can be queued or in-flight, so Dispatch work allocation is also
    /// bounded when Rust persistence slows down.
    @discardableResult
    nonisolated func submit(_ audioData: Data) -> SubmissionResult {
        guard audioData.isEmpty == false else { return .closed }

        while true {
            let currentState = state.load(ordering: .acquiring)
            guard currentState == State.accepting.rawValue else {
                return currentState == State.closed.rawValue ? .closed : .overflow
            }

            let currentPending = pendingCount.load(ordering: .relaxed)
            if currentPending >= capacity {
                let transition = state.compareExchange(
                    expected: State.accepting.rawValue,
                    desired: State.overflow.rawValue,
                    ordering: .acquiringAndReleasing
                )
                if transition.exchanged {
                    onTerminal(NotebookCaptureInterruptReason.localAudioOverflow.rawValue)
                    return .overflow
                }
                continue
            }

            let reservation = pendingCount.compareExchange(
                expected: currentPending,
                desired: currentPending + 1,
                ordering: .acquiringAndReleasing
            )
            guard reservation.exchanged else { continue }

            // Close may race between the first state load and reservation.
            // Frames reserved after close are rejected; frames whose second
            // check wins are accepted and therefore covered by `fence()`.
            let reservedState = state.load(ordering: .acquiring)
            guard reservedState == State.accepting.rawValue else {
                rejectReservationFromTap()
                return reservedState == State.closed.rawValue ? .closed : .overflow
            }

            queue.async { [self] in pushAcceptedFrame(audioData) }
            return .accepted
        }
    }

    nonisolated func close() {
        _ = state.compareExchange(
            expected: State.accepting.rawValue,
            desired: State.closed.rawValue,
            ordering: .acquiringAndReleasing
        )
    }

    @discardableResult
    nonisolated func reopen() -> Bool {
        guard pendingCount.load(ordering: .acquiring) == 0 else { return false }
        return state.compareExchange(
            expected: State.closed.rawValue,
            desired: State.accepting.rawValue,
            ordering: .acquiringAndReleasing
        ).exchanged
    }

    nonisolated func abort() {
        state.store(State.aborted.rawValue, ordering: .releasing)
        resumeFenceWaitersIfDrained()
    }

    nonisolated func fence() async {
        await withCheckedContinuation { continuation in
            fenceLock.lock()
            if pendingCount.load(ordering: .acquiring) == 0 {
                fenceLock.unlock()
                continuation.resume()
            } else {
                fenceWaiters.append(continuation)
                fenceLock.unlock()
            }
        }
    }

    nonisolated var pendingCountForTesting: Int {
        pendingCount.load(ordering: .acquiring)
    }

    /// Available after `fence()` for deterministic pause/stop decisions. A
    /// persistence failure upgrades an earlier overflow because Rust has
    /// already durably interrupted the run in that case.
    nonisolated var terminalMessage: String? {
        switch state.load(ordering: .acquiring) {
        case State.overflow.rawValue:
            return NotebookCaptureInterruptReason.localAudioOverflow.rawValue
        case State.pushFailure.rawValue:
            failureLock.lock()
            defer { failureLock.unlock() }
            return pushFailureMessage
        default:
            return nil
        }
    }

    private nonisolated func pushAcceptedFrame(_ audioData: Data) {
        let currentState = state.load(ordering: .acquiring)
        guard currentState != State.aborted.rawValue,
              currentState != State.pushFailure.rawValue
        else {
            finishAcceptedFrame()
            return
        }

        if let message = push(audioData) {
            failureLock.lock()
            pushFailureMessage = message
            failureLock.unlock()

            while true {
                let observed = state.load(ordering: .acquiring)
                guard observed != State.aborted.rawValue,
                      observed != State.pushFailure.rawValue
                else { break }
                if state.compareExchange(
                    expected: observed,
                    desired: State.pushFailure.rawValue,
                    ordering: .acquiringAndReleasing
                ).exchanged {
                    onTerminal(message)
                    break
                }
            }
        }
        finishAcceptedFrame()
    }

    private nonisolated func finishAcceptedFrame() {
        let previous = pendingCount.wrappingSubtract(1, ordering: .acquiringAndReleasing).oldValue
        precondition(previous > 0, "audio gate pending count underflow")
        if previous == 1 {
            resumeFenceWaitersIfDrained()
        }
    }

    /// Reservation rollback can run on the AVAudioEngine tap. Any waiter
    /// bookkeeping is deferred to the bounded serial queue so the tap never
    /// acquires `fenceLock`.
    private nonisolated func rejectReservationFromTap() {
        let previous = pendingCount.wrappingSubtract(1, ordering: .acquiringAndReleasing).oldValue
        precondition(previous > 0, "audio gate pending count underflow")
        if previous == 1 {
            queue.async { [self] in resumeFenceWaitersIfDrained() }
        }
    }

    private nonisolated func resumeFenceWaitersIfDrained() {
        guard pendingCount.load(ordering: .acquiring) == 0 else { return }
        fenceLock.lock()
        guard pendingCount.load(ordering: .acquiring) == 0 else {
            fenceLock.unlock()
            return
        }
        let waiters = fenceWaiters
        fenceWaiters.removeAll(keepingCapacity: true)
        fenceLock.unlock()
        waiters.forEach { $0.resume() }
    }
}

@MainActor
protocol NotebookCaptureAudioSourcing: AnyObject {
    func prepare() async throws
    func subscribe(
        onAudio: @escaping @Sendable (Data) -> Void,
        onOverflow: @escaping @Sendable () -> Void
    ) throws -> NotebookCaptureAudioToken
    @discardableResult
    func unsubscribe(_ token: NotebookCaptureAudioToken) -> NotebookCaptureInterruptReason?
}

@MainActor
final class LiveNotebookCaptureAudioSource: NotebookCaptureAudioSourcing {
    private var subscriptions: [NotebookCaptureAudioToken: MicrophoneCapture.SubscriptionToken] = [:]

    func prepare() async throws {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return
        case .notDetermined:
            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
            }
            if !granted { throw RecordingLiveError.microphonePermissionDenied }
        case .denied, .restricted:
            throw RecordingLiveError.microphonePermissionDenied
        @unknown default:
            throw RecordingLiveError.microphonePermissionDenied
        }
    }

    func subscribe(
        onAudio: @escaping @Sendable (Data) -> Void,
        onOverflow: @escaping @Sendable () -> Void
    ) throws -> NotebookCaptureAudioToken {
        let sourceToken = try MicrophoneCapture.shared.subscribe(
            onOverflow: onOverflow,
            { data, _ in onAudio(data) }
        )
        let token = NotebookCaptureAudioToken(id: UUID())
        subscriptions[token] = sourceToken
        return token
    }

    @discardableResult
    func unsubscribe(_ token: NotebookCaptureAudioToken) -> NotebookCaptureInterruptReason? {
        guard let sourceToken = subscriptions.removeValue(forKey: token) else { return nil }
        switch MicrophoneCapture.shared.unsubscribe(sourceToken) {
        case .overflow:
            return .localAudioOverflow
        case nil:
            return nil
        }
    }
}

// MARK: - Active capture store

@MainActor
final class ActiveBilingualTranscriptStore: ObservableObject {
    static let shared = ActiveBilingualTranscriptStore()

    /// About 25 seconds of canonical 16 kHz mono callbacks at the production
    /// 4,800-frame microphone tap cadence. The bounded backlog stays below one
    /// MiB of PCM while absorbing an occasional fsync or scheduler stall.
    nonisolated static let defaultAudioQueueCapacity = 256

    private struct TerminalTransitionLease: Equatable {
        let id: UUID
        let sessionId: String
        let generation: UInt64
    }

    private struct UtteranceGapRepair {
        let id: UUID
        let sessionId: String
        let generation: UInt64?
        var targetEventRevision: UInt64
    }

    @Published private(set) var sessionId: String?
    @Published private(set) var notebookId: String?
    @Published private(set) var profile = NotebookCaptureProfileDTO.localDefault(notebookId: "")
    @Published private(set) var captureState: NotebookCaptureState = .completed
    @Published private(set) var remoteHealth: NotebookRemoteHealth = .off
    @Published private(set) var realtimeLagMs: UInt64?
    @Published private(set) var projectionState: NotebookProjectionState = .ready
    @Published private(set) var realtimeLoroAppliedRevision: UInt64 = 0
    /// Process-local Soniox speculative tail. Durable transcript consumers
    /// must continue to use `utterances`.
    @Published private(set) var livePreviewUtterances: [NotebookCaptureUtteranceDTO] = []
    @Published private(set) var utterances: [NotebookCaptureUtteranceDTO] = []
    @Published private(set) var contextPreview: NotebookCaptureContextPreviewDTO?
    @Published private(set) var contextPacks: [NotebookContextPackDTO] = []
    @Published private(set) var contextSources: [NotebookContextPackSourceDTO] = []
    @Published private(set) var selectedContextPackId: String?
    @Published private(set) var loadedContextNotebookId: String?
    @Published private(set) var appliedContextReceipt: NotebookCaptureContextReceiptDTO?
    @Published private(set) var appliedContextSessionId: String?
    @Published private(set) var providerErrorType: String?
    @Published private(set) var providerRequestId: String?
    @Published private(set) var realtimeProviderId: String?
    @Published private(set) var realtimeModelId: String?
    @Published private(set) var postStopProviderId: String?
    @Published private(set) var postStopModelId: String?
    @Published private(set) var postStopAsyncState = "none"
    @Published private(set) var postStopAsyncProjectionState: NotebookAsyncProjectionState = .none
    @Published private(set) var hasValidRunProfileSnapshot = true
    @Published private(set) var elapsedRecordingTime: TimeInterval = 0
    @Published private(set) var lastError: String?
    @Published private(set) var isLoading = false
    /// Derived, process-local presentation state. Rust remains authoritative
    /// for the durable capture state; this flag only tells the UI that closing
    /// the admitted local-audio backlog has exceeded the watchdog interval.
    @Published private(set) var isAudioDrainDelayed = false

    private let client: NotebookCaptureClienting
    private let audioSource: NotebookCaptureAudioSourcing
    private let elapsedTimerInterval: TimeInterval
    private let audioQueueCapacity: Int
    private let audioDrainWatchdogInterval: TimeInterval
    private var laneMutationsInFlight: Set<NotebookCaptureLaneMutationKey> = []
    private var committedLaneOverrideBarriers:
        [NotebookCaptureLaneMutationKey: NotebookCaptureCommittedLaneOverrideBarrier] = [:]
    private var audioToken: NotebookCaptureAudioToken?
    private var audioPushGate: NotebookCaptureAudioPushGate?
    private var elapsedTimer: AnyCancellable?
    private var terminalSessionId: String?
    private var appliedRunProfileSessionId: String?
    private var confirmedContextDigest: String?
    private var confirmedContextNotebookId: String?
    private var callbackGeneration: UInt64 = 0
    private var acceptedCallbackGeneration: UInt64?
    private var readyCallbackGeneration: UInt64?
    private var callbackSessionId: String?
    private var lastAppliedEventRevision: UInt64?
    private var lastAppliedLivePreviewRevision: UInt64?
    private var pendingCallbackEvent: NotebookCaptureEventDTO?
    private var pendingLivePreview: NotebookCaptureLivePreviewDTO?
    private var utteranceGapRepair: UtteranceGapRepair?
    private var utteranceGapRepairTask: Task<Void, Never>?
    private var terminalTransitionLease: TerminalTransitionLease?
    private var terminalTransitionDrainPending = false
    private var pendingTerminalTransitionEvent: NotebookCaptureEventDTO?
    private var audioDrainWatchdogTask: Task<Void, Never>?
    private var lifecycleOperationCount = 0
    private var lifecycleOperationWaiters: [CheckedContinuation<Void, Never>] = []

    /// A corrupt run still counts as loaded so the UI can show an explicit
    /// snapshot error instead of guessing a presentation mode.
    var hasLoadedCaptureRunSnapshot: Bool {
        guard let sessionId else { return false }
        return appliedRunProfileSessionId == sessionId
    }

    init(
        client: NotebookCaptureClienting? = nil,
        audioSource: NotebookCaptureAudioSourcing? = nil,
        elapsedTimerInterval: TimeInterval = 1,
        audioQueueCapacity: Int = ActiveBilingualTranscriptStore.defaultAudioQueueCapacity,
        audioDrainWatchdogInterval: TimeInterval = 5
    ) {
        self.client = client ?? RustNotebookCaptureClient()
        self.audioSource = audioSource ?? LiveNotebookCaptureAudioSource()
        self.elapsedTimerInterval = max(0.001, elapsedTimerInterval)
        self.audioQueueCapacity = max(1, audioQueueCapacity)
        self.audioDrainWatchdogInterval = max(0.001, audioDrainWatchdogInterval)
    }

    var hasAudioSubscription: Bool { audioToken != nil }
#if DEBUG
    var hasAudioPushGateForTesting: Bool { audioPushGate != nil }
#endif
    var isCaptureActive: Bool {
        sessionId != nil && (captureState.isActive || terminalTransitionLease != nil)
    }

    var presentedUtterances: [NotebookCaptureUtteranceDTO] {
        NotebookCaptureLivePresentation.utterances(
            durable: utterances,
            preview: livePreviewUtterances,
            sessionId: sessionId
        )
    }
    var requiresApplicationTerminationPreparation: Bool {
        lifecycleOperationCount > 0
            || audioToken != nil
            || audioPushGate != nil
            || isCaptureActive
    }
    var isEditable: Bool {
        sessionId != nil && terminalTransitionLease == nil
    }

    var leftLanguage: String {
        selectedLanguages.first ?? normalizedLanguage(profile.leftLanguage)
    }

    var rightLanguage: String {
        if selectedLanguages.count > 1 {
            return selectedLanguages[1]
        }
        let stored = normalizedLanguage(profile.rightLanguage)
        if sameLanguage(stored, profile.languageA) || sameLanguage(stored, profile.languageB) {
            return stored
        }
        let a = normalizedLanguage(profile.languageA)
        let b = normalizedLanguage(profile.languageB)
        return sameLanguage(leftLanguage, a) ? b : a
    }

    var selectedLanguages: [String] {
        NotebookCaptureHistoryPolicy.resolvedSelectedLanguages(
            profile.selectedLanguages,
            legacyLeftLanguage: profile.leftLanguage,
            legacyRightLanguage: profile.rightLanguage
        )
    }

    var commonCaptionLanguage: String? {
        nil
    }

    func loadProfile(notebookId: String) {
        guard notebookId.isEmpty == false else { return }
        guard terminalTransitionLease == nil else { return }
        guard isCaptureActive == false || self.notebookId == notebookId else { return }
        isLoading = true
        defer { isLoading = false }
        profile = profileForNotebook(notebookId)
    }

    func profileForNotebook(_ notebookId: String) -> NotebookCaptureProfileDTO {
        do {
            let loaded = try client.getNotebookCaptureProfile(notebookId: notebookId)
            lastError = nil
            return loaded
        } catch NotebookCaptureClientError.ffiUnavailable {
            // Before the generated adapter lands, keep privacy-safe defaults and
            // expose the integration state without allowing a revision-0
            // fallback to be edited and written over a real profile.
            lastError = NotebookCaptureClientError.ffiUnavailable.localizedDescription
            return .localDefault(notebookId: notebookId)
        } catch {
            lastError = error.localizedDescription
            return .localDefault(notebookId: notebookId)
        }
    }

    @discardableResult
    func saveProfile(_ candidate: NotebookCaptureProfileDTO) throws -> NotebookCaptureProfileDTO {
        guard isCaptureActive == false else {
            throw NotebookCaptureClientError.captureAlreadyActive
        }
        let reviewedDigest = confirmedContextDigest
        let reviewedNotebookId = confirmedContextNotebookId
        var normalized = candidate
        normalized.selectedLanguages = NotebookCaptureHistoryPolicy.resolvedSelectedLanguages(
            candidate.selectedLanguages,
            legacyLeftLanguage: candidate.leftLanguage,
            legacyRightLanguage: candidate.rightLanguage
        )
        switch (normalized.remoteRealtimeEnabled, normalized.selectedLanguages.count) {
        case (false, _), (_, 1):
            normalized.mode = .transcriptionOnly
        case (true, 2):
            normalized.mode = .twoWay
        case (true, 3...):
            normalized.mode = .multilingualOneWay
        default:
            break
        }
        normalized.commonCaptionLanguage = nil
        if let firstLanguage = normalized.selectedLanguages.first {
            normalized.languageA = firstLanguage
            normalized.leftLanguage = firstLanguage
        }
        if normalized.selectedLanguages.count > 1 {
            normalized.languageB = normalized.selectedLanguages[1]
            normalized.rightLanguage = normalized.selectedLanguages[1]
        } else {
            normalized.rightLanguage = normalized.languageB
        }
        try validate(normalized)
        let saved = try client.updateNotebookCaptureProfile(normalized)

        // `profile` is display state for the active or reopened immutable run.
        // Persisting a Notebook's next-run capture settings must never rewrite
        // historical transcript lanes or the current run snapshot.

        // Saving the profile increments its revision in Rust, but it must not
        // silently discard the exact Context Pack consent the user just gave.
        // Recompile after the save and retain consent only when the reviewed
        // Notebook, digest and sendable payload are byte-for-byte equivalent.
        // Any compiler/read failure remains fail-closed even though the profile
        // itself was persisted successfully.
        if saved.sendContextToSoniox,
           let reviewedDigest,
           reviewedNotebookId == saved.notebookId {
            let refreshed: NotebookCaptureContextPreviewDTO
            do {
                refreshed = try client.previewNotebookCaptureContext(notebookId: saved.notebookId)
            } catch {
                invalidateContextPreview()
                throw error
            }
            contextPreview = refreshed
            if refreshed.notebookId == saved.notebookId,
               refreshed.digest == reviewedDigest,
               refreshed.containsSendableContext {
                confirmedContextDigest = reviewedDigest
                confirmedContextNotebookId = saved.notebookId
            } else {
                confirmedContextDigest = nil
                confirmedContextNotebookId = nil
                throw NotebookCaptureClientError.contextConfirmationRequired
            }
        } else {
            invalidateContextPreview()
        }
        lastError = nil
        return saved
    }

    func hasConfirmedContext(notebookId: String) -> Bool {
        guard confirmedContextNotebookId == notebookId,
              let confirmedContextDigest,
              let contextPreview,
              contextPreview.notebookId == notebookId,
              contextPreview.digest == confirmedContextDigest,
              contextPreview.containsSendableContext
        else { return false }
        return true
    }

    @discardableResult
    func previewContext(notebookId: String) throws -> NotebookCaptureContextPreviewDTO {
        let preview = try client.previewNotebookCaptureContext(notebookId: notebookId)
        contextPreview = preview
        confirmedContextDigest = nil
        lastError = nil
        return preview
    }

    func confirmContextPreview(digest: String) {
        guard let contextPreview,
              contextPreview.digest == digest,
              contextPreview.containsSendableContext
        else { return }
        confirmedContextDigest = digest
        confirmedContextNotebookId = contextPreview.notebookId
    }

    func revokeContextConfirmation() {
        confirmedContextDigest = nil
        confirmedContextNotebookId = nil
    }

    func loadContextPacks(notebookId: String) throws {
        let priorSelection = loadedContextNotebookId == notebookId
            ? selectedContextPackId
            : nil
        clearContextBrowserState()

        do {
            let packs = sortedContextPacks(
                try client.listNotebookContextPacks(notebookId: notebookId)
            )
            let selection = priorSelection.flatMap { selectedId in
                packs.contains(where: { $0.id == selectedId }) ? selectedId : nil
            } ?? packs.first(where: \.isPrivate)?.id
            let sources = try selection.map { packId in
                try fetchContextSources(notebookId: notebookId, packId: packId)
            } ?? []

            // Publish one Notebook-scoped snapshot only after both calls have
            // succeeded. A partial B load must never leave A metadata visible.
            contextPacks = packs
            selectedContextPackId = selection
            contextSources = sources
            loadedContextNotebookId = notebookId
            lastError = nil
        } catch {
            clearContextBrowserState()
            invalidateContextPreview()
            lastError = error.localizedDescription
            throw error
        }
    }

    func selectContextPack(_ packId: String, notebookId: String) throws {
        guard loadedContextNotebookId == notebookId,
              contextPacks.contains(where: { $0.id == packId })
        else { return }
        do {
            let sources = try fetchContextSources(notebookId: notebookId, packId: packId)
            selectedContextPackId = packId
            contextSources = sources
            lastError = nil
        } catch {
            clearContextBrowserState()
            lastError = error.localizedDescription
            throw error
        }
    }

    func setContextPackBound(
        notebookId: String,
        packId: String,
        isBound: Bool
    ) throws {
        let nextPosition = isBound
            ? (contextPacks.compactMap(\.boundPosition).max().map { $0 + 1 } ?? 0)
            : nil
        try client.setNotebookContextPackBinding(
            notebookId: notebookId,
            packId: packId,
            position: nextPosition
        )
        invalidateContextPreview()
        try loadContextPacks(notebookId: notebookId)
    }

    @discardableResult
    func createLibraryContextPack(title: String, notebookId: String) throws -> NotebookContextPackDTO {
        let pack = try client.createLibraryContextPack(title: title)
        invalidateContextPreview()
        try loadContextPacks(notebookId: notebookId)
        try selectContextPack(pack.id, notebookId: notebookId)
        return pack
    }

    @discardableResult
    func copyPrivateContextToLibrary(
        notebookId: String,
        title: String
    ) throws -> NotebookContextPackDTO {
        let pack = try client.copyNotebookPrivateContextToLibrary(
            notebookId: notebookId,
            title: title
        )
        invalidateContextPreview()
        try loadContextPacks(notebookId: notebookId)
        try selectContextPack(pack.id, notebookId: notebookId)
        return pack
    }

    func importContextText(
        notebookId: String,
        packId: String,
        title: String,
        text: String,
        contentKind: String
    ) throws {
        _ = try client.importContextPackText(
            notebookId: notebookId,
            packId: packId,
            title: title,
            text: text,
            contentKind: contentKind
        )
        invalidateContextPreview()
        try loadContextSources(notebookId: notebookId, packId: packId)
    }

    func importContextFile(
        notebookId: String,
        packId: String,
        path: String,
        contentKind: String
    ) throws {
        _ = try client.importContextPackFile(
            notebookId: notebookId,
            packId: packId,
            path: path,
            contentKind: contentKind
        )
        invalidateContextPreview()
        try loadContextSources(notebookId: notebookId, packId: packId)
    }

    func deleteContextSource(notebookId: String, sourceId: String, packId: String) throws {
        _ = try client.deleteContextPackSource(notebookId: notebookId, sourceId: sourceId)
        invalidateContextPreview()
        try loadContextSources(notebookId: notebookId, packId: packId)
    }

    func deleteLibraryContextPack(pack: NotebookContextPackDTO, notebookId: String) throws {
        guard pack.isPrivate == false else { return }
        _ = try client.deleteLibraryContextPack(
            packId: pack.id,
            expectedRevision: pack.revision
        )
        invalidateContextPreview()
        try loadContextPacks(notebookId: notebookId)
    }

    func start(notebookId: String) async throws {
        beginLifecycleOperation()
        defer { endLifecycleOperation() }
        // The durable owner may still be completing an older run after Swift
        // has already removed its microphone. Reject before even reading the
        // next profile or preparing audio so a second capture cannot overlap
        // that terminal transition.
        guard isCaptureActive == false,
              terminalTransitionLease == nil
        else { throw NotebookCaptureClientError.captureAlreadyActive }
        // Always resolve the current persisted profile. `profile` also carries
        // an immutable historical run snapshot while reopening transcripts and
        // must never be reused as configuration for a new capture.
        let startProfile = try client.getNotebookCaptureProfile(notebookId: notebookId)
        try validate(startProfile)
        if startProfile.sendContextToSoniox,
           confirmedContextDigest == nil
            || confirmedContextDigest != contextPreview?.digest
            || confirmedContextNotebookId != notebookId {
            throw NotebookCaptureClientError.contextConfirmationRequired
        }

        try await audioSource.prepare()
        callbackGeneration &+= 1
        let generation = callbackGeneration
        acceptedCallbackGeneration = generation
        readyCallbackGeneration = nil
        callbackSessionId = nil
        pendingCallbackEvent = nil
        pendingLivePreview = nil
        cancelUtteranceGapRepair()

        let initial: NotebookCaptureEventDTO
        do {
            initial = try client.startNotebookCaptureSession(
                notebookId: notebookId,
                profileRevision: startProfile.revision,
                confirmedContextDigest: startProfile.sendContextToSoniox ? confirmedContextDigest : nil,
                onCaptureEvent: { [weak self] event in
                    self?.receiveCaptureCallback(event, generation: generation)
                },
                onLivePreview: { [weak self] preview in
                    self?.receiveLivePreview(preview, generation: generation)
                }
            )
        } catch {
            invalidateCaptureCallback(generation: generation)
            throw error
        }
        callbackSessionId = initial.sessionId

        self.notebookId = notebookId
        self.profile = startProfile
        self.utterances = []
        self.livePreviewUtterances = []
        self.lastAppliedEventRevision = nil
        self.lastAppliedLivePreviewRevision = nil
        self.appliedContextReceipt = nil
        self.appliedContextSessionId = nil
        self.providerErrorType = nil
        self.providerRequestId = nil
        self.realtimeProviderId = nil
        self.realtimeModelId = nil
        self.postStopProviderId = nil
        self.postStopModelId = nil
        self.lastError = nil
        self.terminalSessionId = nil
        self.appliedRunProfileSessionId = nil
        apply(initial)

        let startedSessionId = initial.sessionId
        let pushGate = NotebookCaptureAudioPushGate(
            capacity: audioQueueCapacity,
            push: client.makeNotebookCaptureAudioPusher(sessionId: startedSessionId),
            onTerminal: { [weak self] message in
                Task { @MainActor [weak self] in
                    await self?.handleAudioTerminal(message, sessionId: startedSessionId)
                }
            }
        )
        audioPushGate = pushGate
        do {
            try subscribeMicrophone(sessionId: startedSessionId, gate: pushGate)
        } catch {
            await handleLocalInterrupt(
                .localAudioUnavailable,
                message: error.localizedDescription,
                sessionId: startedSessionId,
                makeCallbackReady: generation
            )
            throw error
        }

        MenuBarRuntimeStore.shared.startRecording(info: RecordingInfo(
            sessionId: initial.sessionId,
            remoteRealtimeEnabled: startProfile.remoteRealtimeEnabled,
            languagePair: captureLanguageSummary,
            captureState: initial.captureState,
            remoteHealth: initial.remoteHealth,
            projectionState: initial.projectionState
        ))
        startElapsedTimer()
        readyCallbackGeneration = generation
        drainPendingCaptureCallback(generation: generation)
        drainPendingLivePreview(generation: generation)
    }

    func setPaused(_ paused: Bool) async throws {
        beginLifecycleOperation()
        defer { endLifecycleOperation() }
        guard let sessionId,
              (paused ? captureState == .recording : captureState == .paused),
              terminalTransitionLease == nil
        else {
            throw NotebookCaptureClientError.captureNotActive
        }
        if paused {
            guard let drainLease = beginTerminalTransition(sessionId: sessionId) else {
                throw NotebookCaptureClientError.captureNotActive
            }
            let preDrainState = captureState
            captureState = .draining
            // Remove the tap first. `unsubscribe` synchronously drains the
            // preallocated microphone ring, so every accepted frame can still
            // enter the Rust push gate before that gate closes and Rust
            // finalizes the current utterance.
            let gate = audioPushGate
            let microphoneTerminal = releaseMicrophoneSubscription()
            gate?.close()
            startAudioDrainWatchdog(for: drainLease)
            await gate?.fence()
            audioFenceDidDrain(for: drainLease)
            guard isCurrentTerminalTransition(drainLease) else {
                throw NotebookCaptureClientError.captureNotActive
            }
            if let terminalMessage = terminalMessage(
                microphoneTerminal: microphoneTerminal,
                gate: gate
            ) {
                await resolveAudioTerminal(
                    terminalMessage,
                    sessionId: sessionId,
                    lease: drainLease
                )
                throw NotebookCaptureClientError.captureNotActive
            }

            do {
                let event = try await client.pauseNotebookCaptureSession(
                    sessionId: sessionId,
                    paused: true
                )
                guard isCurrentTerminalTransition(drainLease),
                      event.sessionId == sessionId
                else { throw NotebookCaptureClientError.captureNotActive }
                if event.captureState.isActive == false {
                    _ = applyAuthoritativeTerminal(event, for: drainLease)
                    throw NotebookCaptureClientError.captureNotActive
                }
                guard event.captureState == .paused else {
                    clearTerminalTransition(drainLease)
                    apply(event)
                    try restoreMicrophoneAfterRejectedPause(
                        sessionId: sessionId,
                        gate: gate
                    )
                    throw NotebookCaptureClientError.captureNotActive
                }
                clearTerminalTransition(drainLease)
                apply(event)
                MenuBarRuntimeStore.shared.updateRecording { $0.isPaused = true }
            } catch let pauseError {
                guard isCurrentTerminalTransition(drainLease) else {
                    throw pauseError
                }
                // The Rust transition and its response are not one failure
                // boundary: SQLite may already contain Paused even if a later
                // provider-health write or FFI response failed. Reconcile the
                // durable state before reopening the microphone, otherwise a
                // successful pause is falsely reported as failed and local
                // audio resumes against a paused capture.
                let authoritative = try? await client.reconcileNotebookCaptureSessionEvent(
                    sessionId: sessionId
                )
                if let authoritative, authoritative.sessionId == sessionId {
                    if authoritative.captureState.isActive == false {
                        _ = applyAuthoritativeTerminal(authoritative, for: drainLease)
                        throw pauseError
                    }
                    if authoritative.captureState == .paused {
                        clearTerminalTransition(drainLease)
                        apply(authoritative)
                        MenuBarRuntimeStore.shared.updateRecording { $0.isPaused = true }
                        return
                    }
                    clearTerminalTransition(drainLease)
                    apply(authoritative)
                } else {
                    clearTerminalTransition(drainLease)
                    captureState = preDrainState
                }

                // Rust did not commit the pause. Restore local recording with
                // one fresh microphone generation; if that cannot be done,
                // fail closed and durably interrupt the run.
                if terminalSessionId == nil, captureState == .recording {
                    do {
                        try restoreMicrophoneAfterRejectedPause(
                            sessionId: sessionId,
                            gate: gate
                        )
                    } catch {
                        await handleLocalInterrupt(
                            .localAudioUnavailable,
                            message: error.localizedDescription,
                            sessionId: sessionId
                        )
                    }
                }
                throw pauseError
            }
            return
        }

        guard let resumeLease = beginTerminalTransition(sessionId: sessionId) else {
            throw NotebookCaptureClientError.captureNotActive
        }
        captureState = .draining
        // Paused capture has no open microphone stream to fence. The lease is
        // still retained across the detached FFI request so Stop/Start and
        // callbacks cannot create a silent Recording state.
        audioFenceDidDrain(for: resumeLease)

        let event: NotebookCaptureEventDTO
        do {
            event = try await client.pauseNotebookCaptureSession(
                sessionId: sessionId,
                paused: false
            )
        } catch let resumeError {
            guard isCurrentTerminalTransition(resumeLease) else {
                throw resumeError
            }
            guard let authoritative = try? await client.reconcileNotebookCaptureSessionEvent(
                sessionId: sessionId
            ),
            authoritative.sessionId == sessionId else {
                clearTerminalTransition(resumeLease)
                captureState = .paused
                throw resumeError
            }
            if authoritative.captureState.isActive == false {
                _ = applyAuthoritativeTerminal(authoritative, for: resumeLease)
                throw resumeError
            }
            guard authoritative.captureState == .recording else {
                clearTerminalTransition(resumeLease)
                apply(authoritative)
                throw resumeError
            }
            event = authoritative
        }

        guard isCurrentTerminalTransition(resumeLease),
              event.sessionId == sessionId
        else { throw NotebookCaptureClientError.captureNotActive }
        if event.captureState.isActive == false {
            _ = applyAuthoritativeTerminal(event, for: resumeLease)
            throw NotebookCaptureClientError.captureNotActive
        }
        guard event.captureState == .recording else {
            clearTerminalTransition(resumeLease)
            apply(event)
            throw NotebookCaptureClientError.captureNotActive
        }
        guard terminalSessionId == nil,
              self.sessionId == sessionId,
              let gate = audioPushGate,
              gate.reopen()
        else {
            clearTerminalTransition(resumeLease)
            apply(event)
            await handleLocalInterrupt(
                .localAudioUnavailable,
                message: "local audio queue could not reopen",
                sessionId: sessionId
            )
            throw NotebookCaptureClientError.captureNotActive
        }
        do {
            try subscribeMicrophone(sessionId: sessionId, gate: gate)
        } catch {
            clearTerminalTransition(resumeLease)
            apply(event)
            await handleLocalInterrupt(
                .localAudioUnavailable,
                message: error.localizedDescription,
                sessionId: sessionId
            )
            throw error
        }
        guard isCurrentTerminalTransition(resumeLease) else {
            _ = releaseMicrophoneSubscription()
            gate.close()
            throw NotebookCaptureClientError.captureNotActive
        }
        clearTerminalTransition(resumeLease)
        apply(event)
        MenuBarRuntimeStore.shared.updateRecording { $0.isPaused = false }
    }

    func stop() async throws {
        beginLifecycleOperation()
        defer { endLifecycleOperation() }
        guard let sessionId,
              captureState.isActive,
              let lease = beginTerminalTransition(sessionId: sessionId)
        else {
            throw NotebookCaptureClientError.captureNotActive
        }
        let convergence = enterTerminalConvergence(sessionId: sessionId, lease: lease)
        startAudioDrainWatchdog(for: lease)
        // Removing the tap fences its preallocated ring first. Those frames
        // must still be admitted to the Rust push gate before that gate closes.
        let microphoneTerminal = convergence.microphoneTerminal
        await convergence.gate?.fence()
        audioFenceDidDrain(for: lease)
        guard isCurrentTerminalTransition(lease) else { return }

        if let terminalMessage = terminalMessage(
            microphoneTerminal: microphoneTerminal,
            gate: convergence.gate
        ) {
            await resolveAudioTerminal(
                terminalMessage,
                sessionId: sessionId,
                lease: lease
            )
            return
        }

        do {
            let event = try await client.stopNotebookCaptureSession(sessionId: sessionId)
            guard isCurrentTerminalTransition(lease) else { return }
            guard applyAuthoritativeTerminal(event, for: lease) else {
                throw NotebookCaptureClientError.captureNotActive
            }
        } catch {
            let stopError = error
            // A callback can commit A's terminal transition while the detached
            // Rust stop is still returning. Once its lease is gone, neither
            // the result nor this error may mutate a subsequently started B.
            guard isCurrentTerminalTransition(lease) else { throw stopError }

            let authoritative: NotebookCaptureEventDTO
            do {
                authoritative = try client.getNotebookCaptureSessionEvent(sessionId: sessionId)
            } catch {
                if isCurrentTerminalTransition(lease) {
                    enterStopFailureFallback(
                        lease: lease,
                        stopError: stopError.localizedDescription,
                        followupError: error.localizedDescription
                    )
                }
                throw stopError
            }

            guard isCurrentTerminalTransition(lease) else { throw stopError }

            if authoritative.captureState.isActive {
                // Swift has already removed the microphone and push gate to
                // honor the user's Stop action. An authoritative active Rust
                // snapshot therefore cannot be rendered as recording: that
                // would create a silent active capture. Fail closed by asking
                // Rust for a durable terminal transition.
                do {
                    let interrupted = try await client.interruptNotebookCaptureSession(
                        sessionId: sessionId,
                        reason: .localAudioUnavailable
                    )
                    guard isCurrentTerminalTransition(lease) else { throw stopError }
                    if applyAuthoritativeTerminal(interrupted, for: lease) == false {
                        enterStopFailureFallback(
                            lease: lease,
                            stopError: stopError.localizedDescription,
                            followupError: "durable interrupt returned an active capture"
                        )
                    } else {
                        lastError = stopError.localizedDescription
                    }
                } catch {
                    let interruptError = error
                    // A terminal callback may have won the race while the
                    // interrupt call was in flight. Preserve it; otherwise a
                    // failed interrupt is the final fail-closed fallback.
                    if isCurrentTerminalTransition(lease) {
                        enterStopFailureFallback(
                            lease: lease,
                            stopError: stopError.localizedDescription,
                            followupError: interruptError.localizedDescription
                        )
                    }
                }
            } else {
                // Stop can fail after Rust has already committed a terminal
                // transition. Render that authoritative terminal snapshot.
                if applyAuthoritativeTerminal(authoritative, for: lease) {
                    lastError = stopError.localizedDescription
                }
            }
            throw stopError
        }
    }

    func retryProjection() throws {
        guard let sessionId, captureState.isActive == false else {
            throw NotebookCaptureClientError.projectionLocked
        }
        apply(try client.retryNotebookCaptureProjection(sessionId: sessionId))
    }

    func loadUtterances(notebookId: String, sessionId: String) {
        // Opening another Notebook/session is a view change, never a capture
        // ownership transition. Keep the active run and its immutable profile.
        guard isCaptureActive == false || self.sessionId == sessionId else { return }
        // SwiftUI may recreate the presentation task while reconciling tabs.
        // An already-applied immutable run snapshot is a successful empty or
        // non-empty result, not a signal to issue another synchronous FFI read.
        if self.notebookId == notebookId,
           self.sessionId == sessionId,
           hasLoadedCaptureRunSnapshot {
            return
        }
        if self.sessionId != sessionId {
            clearSessionScopedDisplayState()
            self.sessionId = sessionId
            captureState = .completed
            remoteHealth = .off
            projectionState = .pending
        }
        if self.notebookId != notebookId {
            invalidateContextPreview()
            contextPacks = []
            contextSources = []
            selectedContextPackId = nil
        }
        self.notebookId = notebookId
        profile.notebookId = notebookId
        appliedRunProfileSessionId = nil
        do {
            apply(try client.getNotebookCaptureSessionEvent(sessionId: sessionId))
            utterances.sort { $0.sequence < $1.sequence }
            if hasValidRunProfileSnapshot { lastError = nil }
        } catch NotebookCaptureClientError.ffiUnavailable {
            // Fail closed while Rust is unavailable. Never infer an old run's
            // display languages from the Notebook's current profile.
            failSessionLoad(
                String(localized: "capture.error.profile_snapshot_unavailable")
            )
        } catch {
            failSessionLoad(error.localizedDescription)
        }
    }

    func replaceLane(utteranceId: String, language: String, text: String) async throws {
        let mutationKey = NotebookCaptureLaneMutationKey(
            utteranceId: utteranceId,
            language: language
        )
        guard laneMutationsInFlight.insert(mutationKey).inserted else {
            throw NotebookCaptureClientError.projectionLocked
        }
        defer { laneMutationsInFlight.remove(mutationKey) }

        guard isEditable else { throw NotebookCaptureClientError.projectionLocked }
        guard let index = utterances.firstIndex(where: { $0.id == utteranceId }) else {
            throw NotebookCaptureClientError.projectionLocked
        }
        guard utterances[index].sessionId == sessionId else {
            throw NotebookCaptureClientError.projectionLocked
        }
        guard utterances[index].isLoroEditableLane(
            language: language,
            appliedRevision: realtimeLoroAppliedRevision
        ) else {
            throw NotebookCaptureClientError.projectionLocked
        }
        let expectedRevision = utterances[index].laneEditRevision(
            language: mutationKey.language
        )
        let updated = try await client.replaceNotebookUtteranceLane(
            utteranceId: utteranceId,
            laneLanguage: mutationKey.language,
            text: text,
            expectedRevision: expectedRevision
        )

        guard let latestIndex = utterances.firstIndex(where: { $0.id == utteranceId }) else {
            return
        }
        let latest = utterances[latestIndex]
        guard latest.sessionId == updated.sessionId,
              latest.sessionId == sessionId else { return }
        utterances[latestIndex] = latest.mergingCommittedLane(
            from: updated,
            language: mutationKey.language
        )
        committedLaneOverrideBarriers[mutationKey] =
            NotebookCaptureCommittedLaneOverrideBarrier(
                machineRevision: updated.revision,
                committedUtterance: updated
            )
    }

    func swapDisplayLanguages() {
        guard profile.selectedLanguages.count == 2 else { return }
        profile.selectedLanguages.swapAt(0, 1)
        profile.leftLanguage = profile.selectedLanguages[0]
        profile.rightLanguage = profile.selectedLanguages[1]
        // This is view-only state for the active/loaded run. The durable run
        // keeps its mode/language facts; an interactive left/right swap is
        // always rebuilt in memory and never writes back to history.
    }

    /// AppKit calls this before Rust shutdown. It first lets any already-running
    /// start/pause/stop transition settle, then uses the ordinary Stop path so
    /// the microphone ring and every frame admitted to the bounded push gate
    /// are fenced before the durable capture run is finalized.
    func prepareForApplicationTermination() async {
        await waitForLifecycleQuiescence()

        if captureState.isActive, terminalTransitionLease == nil {
            do {
                try await stop()
            } catch {
                lastError = error.localizedDescription
            }
        }
        await waitForLifecycleQuiescence()

        // Defensive convergence for a partially-started or failed terminal
        // transition. Never abort here: accepted audio must remain durable even
        // when the provider or final projection cannot finish during quit.
        if audioToken != nil || audioPushGate != nil {
            let gate = audioPushGate
            audioPushGate = nil
            _ = releaseMicrophoneSubscription()
            gate?.close()
            await gate?.fence()
            stopElapsedTimer()
        }

        guard let sessionId, captureState.isActive || terminalTransitionLease != nil else {
            return
        }

        let lease = terminalTransitionLease ?? beginTerminalTransition(sessionId: sessionId)
        if let lease {
            terminalTransitionDrainPending = false
            audioDrainWatchdogTask?.cancel()
            audioDrainWatchdogTask = nil
            isAudioDrainDelayed = false
            do {
                let event = try await client.interruptNotebookCaptureSession(
                    sessionId: sessionId,
                    reason: .localAudioUnavailable
                )
                if applyAuthoritativeTerminal(event, for: lease) == false {
                    enterStopFailureFallback(
                        lease: lease,
                        stopError: lastError ?? "application termination",
                        followupError: "durable interrupt returned an active capture"
                    )
                }
            } catch {
                enterStopFailureFallback(
                    lease: lease,
                    stopError: lastError ?? "application termination",
                    followupError: error.localizedDescription
                )
            }
        }
    }

    func resetForTesting() {
        audioDrainWatchdogTask?.cancel()
        audioDrainWatchdogTask = nil
        terminalTransitionLease = nil
        terminalTransitionDrainPending = false
        pendingTerminalTransitionEvent = nil
        isAudioDrainDelayed = false
        audioPushGate?.abort()
        audioPushGate = nil
        releaseMicrophoneSubscription()
        stopElapsedTimer()
        sessionId = nil
        notebookId = nil
        profile = .localDefault(notebookId: "")
        captureState = .completed
        remoteHealth = .off
        projectionState = .ready
        utterances = []
        committedLaneOverrideBarriers.removeAll(keepingCapacity: true)
        livePreviewUtterances = []
        lastAppliedEventRevision = nil
        lastAppliedLivePreviewRevision = nil
        contextPreview = nil
        contextPacks = []
        contextSources = []
        selectedContextPackId = nil
        appliedContextReceipt = nil
        appliedContextSessionId = nil
        providerErrorType = nil
        providerRequestId = nil
        realtimeProviderId = nil
        realtimeModelId = nil
        postStopProviderId = nil
        postStopModelId = nil
        postStopAsyncState = "none"
        postStopAsyncProjectionState = .none
        hasValidRunProfileSnapshot = true
        elapsedRecordingTime = 0
        lastError = nil
        confirmedContextDigest = nil
        confirmedContextNotebookId = nil
        terminalSessionId = nil
        appliedRunProfileSessionId = nil
        acceptedCallbackGeneration = nil
        readyCallbackGeneration = nil
        callbackSessionId = nil
        pendingCallbackEvent = nil
        pendingLivePreview = nil
        cancelUtteranceGapRepair()
        lifecycleOperationCount = 0
        let lifecycleWaiters = lifecycleOperationWaiters
        lifecycleOperationWaiters.removeAll(keepingCapacity: false)
        lifecycleWaiters.forEach { $0.resume() }
    }

#if DEBUG
    func abortAudioGateForTesting() {
        audioPushGate?.abort()
    }
#endif

    func texts(for utterance: NotebookCaptureUtteranceDTO) -> NotebookCaptureLaneTexts {
        NotebookCaptureHistoryPolicy.laneTexts(
            for: utterance,
            leftLanguage: leftLanguage,
            rightLanguage: rightLanguage
        )
    }

    func projection(
        for utterance: NotebookCaptureUtteranceDTO
    ) -> NotebookCaptureLaneProjection {
        NotebookCaptureHistoryPolicy.laneProjection(
            for: utterance,
            selectedLanguages: selectedLanguages,
            commonCaptionLanguage: commonCaptionLanguage
        )
    }

    private var captureLanguageSummary: String {
        if profile.remoteRealtimeEnabled == false {
            return String(localized: "menubar.recording.mode.local")
        }
        let languages = selectedLanguages.map(displayLanguage)
        return languages.isEmpty
            ? String(localized: "menubar.recording.mode.remote")
            : languages.joined(separator: " · ")
    }

    private func validate(_ profile: NotebookCaptureProfileDTO) throws {
        let languages = NotebookCaptureHistoryPolicy.resolvedSelectedLanguages(
            profile.selectedLanguages,
            legacyLeftLanguage: profile.leftLanguage,
            legacyRightLanguage: profile.rightLanguage
        )
        guard (1...8).contains(languages.count) else {
            throw NotebookCaptureClientError.languagePairMustDiffer
        }
        if profile.mode != .transcriptionOnly, profile.remoteRealtimeEnabled == false {
            throw NotebookCaptureClientError.remoteRequiredForTranslation
        }
        if profile.mode == .twoWay, sameLanguage(profile.languageA, profile.languageB) {
            throw NotebookCaptureClientError.languagePairMustDiffer
        }
        if profile.mode == .multilingualOneWay, languages.count < 3 {
            throw NotebookCaptureClientError.languagePairMustDiffer
        }
        if profile.sendContextToSoniox, profile.remoteRealtimeEnabled == false {
            throw NotebookCaptureClientError.remoteRequiredForContext
        }
    }

    private func apply(_ event: NotebookCaptureEventDTO) {
        if let lease = terminalTransitionLease {
            // While A owns the terminal lease, no event for another session is
            // allowed to switch the store's identity. Direct async results use
            // the same lease check before reaching this method; this guard also
            // protects subsequent callback and read paths.
            guard event.sessionId == lease.sessionId else { return }
            if event.captureState.isActive == false,
               terminalTransitionDrainPending {
                // A terminal callback can race the local audio fence. Preserve
                // every already-admitted frame and apply the authoritative
                // snapshot only after that fence completes.
                pendingTerminalTransitionEvent = event
                return
            }
        }

        let matchingLease = terminalTransitionLease.flatMap { lease in
            lease.sessionId == event.sessionId ? lease : nil
        }
        if event.isFullSnapshot == false,
           sessionId == event.sessionId,
           let lastAppliedEventRevision,
           event.eventRevision < lastAppliedEventRevision {
            // A delayed direct result or callback must not regress either the
            // capture state or its utterance view.
            return
        }
        if let currentSessionId = sessionId,
           currentSessionId != event.sessionId {
            clearSessionScopedDisplayState()
        }
        sessionId = event.sessionId
        captureState = matchingLease != nil && event.captureState.isActive
            ? .draining
            : event.captureState
        remoteHealth = event.remoteHealth
        realtimeLagMs = event.realtimeLagMs
        projectionState = event.projectionState
        realtimeLoroAppliedRevision = max(
            realtimeLoroAppliedRevision,
            event.realtimeLoroAppliedRevision
        )
        providerErrorType = event.providerErrorType
        providerRequestId = event.providerRequestId
        postStopAsyncState = event.postStopAsyncState
        postStopAsyncProjectionState = event.postStopAsyncProjectionState
        if realtimeProviderId == nil,
           realtimeModelId == nil,
           let providerId = event.realtimeProviderId,
           let modelId = event.realtimeModelId {
            realtimeProviderId = providerId
            realtimeModelId = modelId
        }
        if postStopProviderId == nil,
           postStopModelId == nil,
           let providerId = event.postStopProviderId,
           let modelId = event.postStopModelId {
            postStopProviderId = providerId
            postStopModelId = modelId
        }
        if appliedRunProfileSessionId != event.sessionId {
            appliedRunProfileSessionId = event.sessionId
            let selectedLanguages = NotebookCaptureHistoryPolicy.resolvedSelectedLanguages(
                event.selectedLanguages,
                legacyLeftLanguage: nil,
                legacyRightLanguage: nil
            )
            if let mode = event.mode,
               (1...8).contains(selectedLanguages.count),
               mode != .multilingualOneWay || selectedLanguages.count >= 3 {
                profile.mode = mode
                profile.selectedLanguages = selectedLanguages
                profile.commonCaptionLanguage = nil
                profile.languageA = event.languageA ?? selectedLanguages.first ?? ""
                profile.languageB = event.languageB
                    ?? selectedLanguages.dropFirst().first
                    ?? profile.languageA
                profile.leftLanguage = event.leftLanguage
                    ?? selectedLanguages.first
                    ?? ""
                profile.rightLanguage = event.rightLanguage
                    ?? selectedLanguages.dropFirst().first
                    ?? profile.leftLanguage
                hasValidRunProfileSnapshot = true
            } else {
                // Rust deliberately emits nil when the immutable per-run
                // snapshot is corrupt. Empty the lanes instead of substituting
                // a newer Notebook profile or a hard-coded language pair.
                profile.languageA = ""
                profile.languageB = ""
                profile.leftLanguage = ""
                profile.rightLanguage = ""
                profile.selectedLanguages = []
                profile.commonCaptionLanguage = nil
                hasValidRunProfileSnapshot = false
                lastError = String(localized: "capture.error.profile_snapshot_unavailable")
            }
        }
        reconcileUtterances(for: event)
        if event.captureState.isActive,
           utterances.contains(where: \.hasFinalLaneReadyForProjection) {
            try? client.projectNotebookRealtimeIncremental(sessionId: event.sessionId)
        }
        if let receipt = event.contextReceipt, receipt.applied {
            appliedContextReceipt = receipt
            appliedContextSessionId = event.sessionId
        }

        if event.captureState.isActive == false {
            livePreviewUtterances = []
            lastAppliedLivePreviewRevision = nil
            refreshRecentTranscriptPresentation()
            _ = enterLocalTerminal(
                sessionId: event.sessionId,
                state: event.captureState,
                abortPendingAudio: true
            )
            if let matchingLease {
                clearTerminalTransition(matchingLease)
            }
        } else if matchingLease != nil {
            // An active callback may have been emitted before Rust observed the
            // stop/interrupt request. It can update data and provider health,
            // but cannot reopen local recording while the lease is converging.
            captureState = .draining
            MenuBarRuntimeStore.shared.returnToIdle()
        } else {
            MenuBarRuntimeStore.shared.updateRecording { info in
                guard info.sessionId == event.sessionId else { return }
                info.isPaused = event.captureState == .paused
                info.remoteRealtimeEnabled = event.remoteHealth == .connecting || event.remoteHealth == .live
                info.captureState = event.captureState
                info.remoteHealth = event.remoteHealth
                info.projectionState = event.projectionState
            }
        }
    }

    private func merge(_ updates: [NotebookCaptureUtteranceDTO]) {
        for unprotectedUpdate in updates {
            let update = protectingCommittedLaneOverrides(in: unprotectedUpdate)
            guard update.sessionId == sessionId else { continue }
            if let index = utterances.firstIndex(where: {
                $0.sessionId == update.sessionId && $0.sequence == update.sequence
            }) {
                if update.revision >= utterances[index].revision {
                    utterances[index] = update
                }
            } else {
                utterances.append(update)
            }
        }
        utterances.sort { $0.sequence < $1.sequence }
        refreshRecentTranscriptPresentation()
    }

    private func protectingCommittedLaneOverrides(
        in update: NotebookCaptureUtteranceDTO
    ) -> NotebookCaptureUtteranceDTO {
        let matchingKeys = committedLaneOverrideBarriers.keys.filter {
            $0.utteranceId == update.id
        }
        guard matchingKeys.isEmpty == false else { return update }

        var protected = update
        for key in matchingKeys {
            guard let barrier = committedLaneOverrideBarriers[key],
                  barrier.committedUtterance.sessionId == update.sessionId
            else { continue }

            let committedEditRevision = barrier.committedUtterance.laneEditRevision(
                language: key.language
            )
            let updateEditRevision = update.laneEditRevision(language: key.language)
            if update.revision > barrier.machineRevision {
                if updateEditRevision >= committedEditRevision {
                    committedLaneOverrideBarriers.removeValue(forKey: key)
                } else {
                    // A newer provider revision does not supersede a user
                    // override. Until the callback carries at least the
                    // committed lane edit revision, retain that lane while
                    // still accepting every unrelated machine field.
                    protected = protected.mergingCommittedLane(
                        from: barrier.committedUtterance,
                        language: key.language
                    )
                }
                continue
            }
            guard update.revision == barrier.machineRevision else { continue }

            let committedText = barrier.committedUtterance.laneText(
                language: key.language
            )
            if update.laneText(language: key.language) == committedText,
               updateEditRevision >= committedEditRevision {
                // A callback or authoritative snapshot now contains the
                // durable override, so subsequent machine revisions can flow
                // normally without retaining process-local state.
                committedLaneOverrideBarriers.removeValue(forKey: key)
                continue
            }
            // This callback was read before the override commit but delivered
            // afterward. Advance every unrelated field/lane from the callback
            // while retaining only the just-committed lane text.
            protected = protected.mergingCommittedLane(
                from: barrier.committedUtterance,
                language: key.language
            )
        }
        return protected
    }

    private func applyLivePreview(_ preview: NotebookCaptureLivePreviewDTO) {
        guard preview.sessionId == sessionId else { return }
        if let lastAppliedLivePreviewRevision,
           preview.previewRevision <= lastAppliedLivePreviewRevision {
            return
        }
        let next = preview.utterances.filter {
            $0.sessionId == preview.sessionId
        }
        lastAppliedLivePreviewRevision = preview.previewRevision
        guard next != livePreviewUtterances else { return }
        livePreviewUtterances = next
        refreshRecentTranscriptPresentation()
    }

    private func refreshRecentTranscriptPresentation() {
        let recent = presentedUtterances.suffix(2).map { utterance in
            let laneProjection = projection(for: utterance)
            let displayedLane: (language: String, text: String)
            if let pendingLanguage = laneProjection.pendingLanguage {
                displayedLane = (utterance.sourceLanguage, pendingLanguage)
            } else if let outsideText = laneProjection.unselectedLanguageText {
                displayedLane = (utterance.sourceLanguage, outsideText)
            } else if let lane = laneProjection.lanes.first(where: {
                $0.text?.isEmpty == false
            }), let text = lane.text {
                displayedLane = (lane.language, text)
            } else {
                displayedLane = (
                    utterance.hasSourceLane ? utterance.sourceLanguage : "",
                    ""
                )
            }
            return TranscriptLine(
                id: utterance.id,
                timestamp: formatTimestamp(
                    utterance.hasSourceLane ? utterance.sourceStartMs : nil
                ),
                languageLabel: laneProjection.pendingLanguage == nil
                    ? displayLanguage(displayedLane.language)
                    : String(localized: "capture.transcript.language_pending"),
                text: displayedLane.text
            )
        }
        MenuBarRuntimeStore.shared.updateRecordingRecentLines(Array(recent))
    }

    private func reconcileUtterances(for event: NotebookCaptureEventDTO) {
        if event.isFullSnapshot {
            cancelUtteranceGapRepair()
            utterances = []
            merge(event.utterances)
            lastAppliedEventRevision = event.eventRevision
            return
        }

        if let lastAppliedEventRevision,
           event.eventRevision == lastAppliedEventRevision {
            // A direct method result and its callback may carry the same
            // stamped delta. Its state is idempotent; do not upsert twice.
            return
        }

        let expectedRevision = lastAppliedEventRevision.map { $0 &+ 1 }
        let hasGap = expectedRevision != event.eventRevision

        // Apply the newest durable delta immediately. If the dispatcher
        // coalesced one or more revisions, the async authoritative pass below
        // fills in omitted rows without blocking the MainActor.
        merge(event.utterances)
        lastAppliedEventRevision = event.eventRevision

        if var repair = utteranceGapRepair,
           repair.sessionId == event.sessionId {
            // Any event that arrives while a snapshot is in flight can make
            // that snapshot stale, even when the event itself is sequential.
            // Advancing the target makes the repair discard that result and
            // fetch again after the newest observed durable revision.
            repair.targetEventRevision = max(
                repair.targetEventRevision,
                event.eventRevision
            )
            utteranceGapRepair = repair
            return
        }

        guard hasGap else { return }
        beginUtteranceGapRepair(
            sessionId: event.sessionId,
            targetEventRevision: event.eventRevision
        )
    }

    private func beginUtteranceGapRepair(
        sessionId: String,
        targetEventRevision: UInt64
    ) {
        guard utteranceGapRepair == nil else { return }
        let repair = UtteranceGapRepair(
            id: UUID(),
            sessionId: sessionId,
            generation: acceptedCallbackGeneration,
            targetEventRevision: targetEventRevision
        )
        utteranceGapRepair = repair
        utteranceGapRepairTask = Task { @MainActor [weak self] in
            await self?.runUtteranceGapRepair(id: repair.id)
        }
    }

    private func runUtteranceGapRepair(id: UUID) async {
        var retryDelayNanoseconds: UInt64 = 20_000_000
        let maximumRetryDelayNanoseconds: UInt64 = 1_000_000_000
        while let repair = currentUtteranceGapRepair(id: id) {
            let targetEventRevision = repair.targetEventRevision
            let snapshot: NotebookCaptureEventDTO
            do {
                // The live adapter performs the blocking UniFFI read on a
                // detached worker. The MainActor only awaits its result.
                snapshot = try await client.reconcileNotebookCaptureSessionEvent(
                    sessionId: repair.sessionId
                )
            } catch {
                guard currentUtteranceGapRepair(id: id) != nil else { return }
                lastError = error.localizedDescription
                try? await Task.sleep(nanoseconds: retryDelayNanoseconds)
                guard Task.isCancelled == false,
                      currentUtteranceGapRepair(id: id) != nil
                else { return }
                retryDelayNanoseconds = min(
                    retryDelayNanoseconds &* 2,
                    maximumRetryDelayNanoseconds
                )
                continue
            }

            guard let current = currentUtteranceGapRepair(id: id) else { return }
            guard snapshot.sessionId == current.sessionId,
                  snapshot.isFullSnapshot else {
                lastError = NotebookCaptureClientError.captureNotActive.localizedDescription
                try? await Task.sleep(nanoseconds: retryDelayNanoseconds)
                guard Task.isCancelled == false,
                      currentUtteranceGapRepair(id: id) != nil
                else { return }
                retryDelayNanoseconds = min(
                    retryDelayNanoseconds &* 2,
                    maximumRetryDelayNanoseconds
                )
                continue
            }

            guard current.targetEventRevision == targetEventRevision else {
                // The snapshot may have been read before a callback observed
                // during this await. Discard it completely so deletions and
                // variant removals cannot resurrect stale local data.
                retryDelayNanoseconds = 20_000_000
                continue
            }

            // No higher event revision arrived during the read, so this full
            // durable snapshot is authoritative for the stable target. Route
            // every row through `merge` to preserve committed edit barriers.
            utterances = []
            merge(snapshot.utterances)
            utteranceGapRepair = nil
            utteranceGapRepairTask = nil
            return
        }
    }

    private func currentUtteranceGapRepair(id: UUID) -> UtteranceGapRepair? {
        guard let repair = utteranceGapRepair,
              repair.id == id,
              repair.sessionId == sessionId,
              repair.generation == acceptedCallbackGeneration
        else { return nil }
        if repair.generation != nil,
           callbackSessionId != repair.sessionId {
            return nil
        }
        return repair
    }

    private func cancelUtteranceGapRepair() {
        utteranceGapRepairTask?.cancel()
        utteranceGapRepairTask = nil
        utteranceGapRepair = nil
    }

    @discardableResult
    private func releaseMicrophoneSubscription() -> NotebookCaptureInterruptReason? {
        guard let audioToken else { return nil }
        self.audioToken = nil
        return audioSource.unsubscribe(audioToken)
    }

    private func subscribeMicrophone(
        sessionId: String,
        gate: NotebookCaptureAudioPushGate
    ) throws {
        guard audioToken == nil else { throw CaptureError.alreadySubscribed }
        audioToken = try audioSource.subscribe(
            onAudio: { audioData in
                gate.submit(audioData)
            },
            onOverflow: { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.handleAudioTerminal(
                        NotebookCaptureInterruptReason.localAudioOverflow.rawValue,
                        sessionId: sessionId
                    )
                }
            }
        )
    }

    private func restoreMicrophoneAfterRejectedPause(
        sessionId: String,
        gate: NotebookCaptureAudioPushGate?
    ) throws {
        guard terminalSessionId == nil,
              self.sessionId == sessionId,
              captureState == .recording,
              let gate,
              gate.reopen()
        else {
            throw NotebookCaptureClientError.captureNotActive
        }
        try subscribeMicrophone(sessionId: sessionId, gate: gate)
    }

    private func terminalMessage(
        microphoneTerminal: NotebookCaptureInterruptReason?,
        gate: NotebookCaptureAudioPushGate?
    ) -> String? {
        // A push failure is already a durable Rust transition and therefore
        // wins if present. Otherwise the synchronous microphone drain result
        // must beat the normal pause/stop path.
        gate?.terminalMessage ?? microphoneTerminal?.rawValue
    }

    private func enterStopFailureFallback(
        lease: TerminalTransitionLease,
        stopError: String,
        followupError: String
    ) {
        guard isCurrentTerminalTransition(lease) else { return }
        projectionState = .failed
        lastError = "\(stopError) · \(followupError)"
        captureState = .draining
        stopElapsedTimer()
        MenuBarRuntimeStore.shared.returnToIdle()
    }

    private func loadContextSources(notebookId: String, packId: String) throws {
        do {
            contextSources = try fetchContextSources(notebookId: notebookId, packId: packId)
            loadedContextNotebookId = notebookId
            lastError = nil
        } catch {
            clearContextBrowserState()
            lastError = error.localizedDescription
            throw error
        }
    }

    private func fetchContextSources(
        notebookId: String,
        packId: String
    ) throws -> [NotebookContextPackSourceDTO] {
        try client.listContextPackSources(notebookId: notebookId, packId: packId)
            .sorted { lhs, rhs in
                if lhs.title != rhs.title {
                    return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
                }
                return lhs.id < rhs.id
            }
    }

    private func sortedContextPacks(
        _ packs: [NotebookContextPackDTO]
    ) -> [NotebookContextPackDTO] {
        packs.sorted { lhs, rhs in
            if lhs.isPrivate != rhs.isPrivate { return lhs.isPrivate }
            switch (lhs.boundPosition, rhs.boundPosition) {
            case let (.some(left), .some(right)) where left != right:
                return left < right
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            default:
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
        }
    }

    private func clearContextBrowserState() {
        contextPacks = []
        contextSources = []
        selectedContextPackId = nil
        loadedContextNotebookId = nil
    }

    private func invalidateContextPreview() {
        contextPreview = nil
        confirmedContextDigest = nil
        confirmedContextNotebookId = nil
    }

    private func clearSessionScopedDisplayState() {
        if let sessionId {
            client.cancelNotebookRealtimeProjection(sessionId: sessionId)
        }
        cancelUtteranceGapRepair()
        utterances = []
        committedLaneOverrideBarriers.removeAll(keepingCapacity: true)
        livePreviewUtterances = []
        lastAppliedEventRevision = nil
        lastAppliedLivePreviewRevision = nil
        appliedContextReceipt = nil
        appliedContextSessionId = nil
        providerErrorType = nil
        providerRequestId = nil
        realtimeProviderId = nil
        realtimeModelId = nil
        postStopProviderId = nil
        postStopModelId = nil
        postStopAsyncState = "none"
        postStopAsyncProjectionState = .none
        realtimeLoroAppliedRevision = 0
        hasValidRunProfileSnapshot = true
        elapsedRecordingTime = 0
        terminalSessionId = nil
        appliedRunProfileSessionId = nil
    }

    private func failSessionLoad(_ message: String) {
        clearSessionScopedDisplayState()
        captureState = .completed
        remoteHealth = .off
        projectionState = .failed
        profile.languageA = ""
        profile.languageB = ""
        profile.leftLanguage = ""
        profile.rightLanguage = ""
        profile.selectedLanguages = []
        profile.commonCaptionLanguage = nil
        hasValidRunProfileSnapshot = false
        lastError = message
    }

    private func receiveCaptureCallback(
        _ event: NotebookCaptureEventDTO,
        generation: UInt64
    ) {
        guard acceptedCallbackGeneration == generation else { return }
        guard readyCallbackGeneration == generation else {
            if pendingCallbackEvent == nil
                || (pendingCallbackEvent?.eventRevision ?? 0) <= event.eventRevision {
                pendingCallbackEvent = event
            }
            return
        }
        guard callbackSessionId == event.sessionId else { return }
        apply(event)
    }

    private func receiveLivePreview(
        _ preview: NotebookCaptureLivePreviewDTO,
        generation: UInt64
    ) {
        guard acceptedCallbackGeneration == generation else { return }
        guard readyCallbackGeneration == generation else {
            pendingLivePreview = preview
            return
        }
        guard callbackSessionId == preview.sessionId else { return }
        applyLivePreview(preview)
    }

    private func drainPendingCaptureCallback(generation: UInt64) {
        guard acceptedCallbackGeneration == generation,
              readyCallbackGeneration == generation,
              let event = pendingCallbackEvent
        else { return }
        pendingCallbackEvent = nil
        guard callbackSessionId == event.sessionId else { return }
        apply(event)
    }

    private func drainPendingLivePreview(generation: UInt64) {
        guard acceptedCallbackGeneration == generation,
              readyCallbackGeneration == generation,
              let preview = pendingLivePreview
        else { return }
        pendingLivePreview = nil
        guard callbackSessionId == preview.sessionId else { return }
        applyLivePreview(preview)
    }

    private func invalidateCaptureCallback(generation: UInt64? = nil) {
        if let generation, acceptedCallbackGeneration != generation { return }
        acceptedCallbackGeneration = nil
        readyCallbackGeneration = nil
        callbackSessionId = nil
        pendingCallbackEvent = nil
        pendingLivePreview = nil
        cancelUtteranceGapRepair()
    }

    private func beginTerminalTransition(
        sessionId: String
    ) -> TerminalTransitionLease? {
        guard terminalTransitionLease == nil,
              self.sessionId == sessionId,
              terminalSessionId == nil
        else { return nil }

        let lease = TerminalTransitionLease(
            id: UUID(),
            sessionId: sessionId,
            generation: callbackGeneration
        )
        terminalTransitionLease = lease
        terminalTransitionDrainPending = true
        pendingTerminalTransitionEvent = nil
        isAudioDrainDelayed = false
        return lease
    }

    private func isCurrentTerminalTransition(
        _ lease: TerminalTransitionLease
    ) -> Bool {
        terminalTransitionLease == lease
            && sessionId == lease.sessionId
            && callbackGeneration == lease.generation
    }

    private func enterTerminalConvergence(
        sessionId: String,
        lease: TerminalTransitionLease
    ) -> (
        gate: NotebookCaptureAudioPushGate?,
        microphoneTerminal: NotebookCaptureInterruptReason?
    ) {
        guard isCurrentTerminalTransition(lease),
              self.sessionId == sessionId
        else { return (nil, nil) }

        client.cancelNotebookRealtimeProjection(sessionId: sessionId)
        let gate = audioPushGate
        audioPushGate = nil
        // Unsubscribe first so frames already admitted by the microphone ring
        // can still enter the gate before it closes.
        let microphoneTerminal = releaseMicrophoneSubscription()
        gate?.close()
        stopElapsedTimer()
        captureState = .draining
        MenuBarRuntimeStore.shared.returnToIdle()
        return (gate, microphoneTerminal)
    }

    private func startAudioDrainWatchdog(for lease: TerminalTransitionLease) {
        guard isCurrentTerminalTransition(lease),
              terminalTransitionDrainPending
        else { return }
        audioDrainWatchdogTask?.cancel()
        let nanoseconds = UInt64(min(
            audioDrainWatchdogInterval * 1_000_000_000,
            Double(UInt64.max)
        ))
        audioDrainWatchdogTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            guard let self,
                  self.isCurrentTerminalTransition(lease),
                  self.terminalTransitionDrainPending
            else { return }
            // This is presentation-only. Never abort the gate, discard queued
            // audio, or release the lease merely because the drain is slow.
            self.isAudioDrainDelayed = true
        }
    }

    private func audioFenceDidDrain(for lease: TerminalTransitionLease) {
        guard isCurrentTerminalTransition(lease) else { return }
        terminalTransitionDrainPending = false
        audioDrainWatchdogTask?.cancel()
        audioDrainWatchdogTask = nil

        if let pending = pendingTerminalTransitionEvent {
            pendingTerminalTransitionEvent = nil
            _ = applyAuthoritativeTerminal(pending, for: lease)
        }
    }

    private func clearTerminalTransition(_ lease: TerminalTransitionLease) {
        guard terminalTransitionLease == lease else { return }
        terminalTransitionLease = nil
        terminalTransitionDrainPending = false
        pendingTerminalTransitionEvent = nil
        audioDrainWatchdogTask?.cancel()
        audioDrainWatchdogTask = nil
        isAudioDrainDelayed = false
    }

    @discardableResult
    private func applyAuthoritativeTerminal(
        _ event: NotebookCaptureEventDTO,
        for lease: TerminalTransitionLease
    ) -> Bool {
        guard isCurrentTerminalTransition(lease),
              event.sessionId == lease.sessionId,
              event.captureState.isActive == false
        else { return false }

        if terminalTransitionDrainPending {
            pendingTerminalTransitionEvent = event
            return true
        }
        apply(event)
        return true
    }

    @discardableResult
    private func enterLocalTerminal(
        sessionId: String,
        state: NotebookCaptureState,
        abortPendingAudio: Bool
    ) -> NotebookCaptureAudioPushGate? {
        client.cancelNotebookRealtimeProjection(sessionId: sessionId)
        if callbackSessionId == sessionId {
            invalidateCaptureCallback()
        }
        terminalSessionId = sessionId
        let gate = audioPushGate
        audioPushGate = nil
        releaseMicrophoneSubscription()
        if abortPendingAudio {
            gate?.abort()
        } else {
            gate?.close()
        }
        stopElapsedTimer()
        captureState = state
        MenuBarRuntimeStore.shared.returnToIdle()
        return gate
    }

    private func handleAudioTerminal(_ message: String, sessionId: String) async {
        beginLifecycleOperation()
        defer { endLifecycleOperation() }
        guard self.sessionId == sessionId,
              captureState.isActive,
              let lease = beginTerminalTransition(sessionId: sessionId)
        else { return }

        let convergence = enterTerminalConvergence(sessionId: sessionId, lease: lease)
        startAudioDrainWatchdog(for: lease)
        // Overflow still has frames that were accepted before the ring filled.
        // They must reach Rust before it transitions the durable run.
        await convergence.gate?.fence()
        audioFenceDidDrain(for: lease)
        guard isCurrentTerminalTransition(lease) else { return }

        let terminalMessage = convergence.gate?.terminalMessage ?? message
        await resolveAudioTerminal(
            terminalMessage,
            sessionId: sessionId,
            lease: lease
        )
    }

    private func resolveAudioTerminal(
        _ terminalMessage: String,
        sessionId: String,
        lease: TerminalTransitionLease
    ) async {
        guard isCurrentTerminalTransition(lease) else { return }
        let isOverflow = terminalMessage == NotebookCaptureInterruptReason.localAudioOverflow.rawValue
        lastError = terminalMessage
        providerErrorType = isOverflow
            ? NotebookCaptureInterruptReason.localAudioOverflow.rawValue
            : "local_audio_persistence"

        do {
            if isOverflow {
                let event = try await client.interruptNotebookCaptureSession(
                    sessionId: sessionId,
                    reason: .localAudioOverflow
                )
                guard isCurrentTerminalTransition(lease) else { return }
                if applyAuthoritativeTerminal(event, for: lease) == false {
                    enterStopFailureFallback(
                        lease: lease,
                        stopError: terminalMessage,
                        followupError: "durable interrupt returned an active capture"
                    )
                }
            } else {
                // Rust persistence failures transition the run before returning
                // from push. Re-read that durable snapshot, but never trust an
                // active result after Swift has already removed the microphone:
                // older/mixed Rust builds or a second persistence fault could
                // otherwise leave a silent Recording run. Explicitly request a
                // terminal transition when the authoritative snapshot is active.
                let authoritative = try client.getNotebookCaptureSessionEvent(
                    sessionId: sessionId
                )
                guard isCurrentTerminalTransition(lease) else { return }
                if authoritative.captureState.isActive {
                    let event = try await client.interruptNotebookCaptureSession(
                        sessionId: sessionId,
                        reason: .localAudioUnavailable
                    )
                    guard isCurrentTerminalTransition(lease) else { return }
                    if applyAuthoritativeTerminal(event, for: lease) == false {
                        enterStopFailureFallback(
                            lease: lease,
                            stopError: terminalMessage,
                            followupError: "durable interrupt returned an active capture"
                        )
                    }
                } else {
                    _ = applyAuthoritativeTerminal(authoritative, for: lease)
                }
            }
        } catch {
            // Local capture is already fail-closed and the microphone is gone.
            // Keep the original audio failure visible alongside FFI cleanup.
            if isCurrentTerminalTransition(lease) {
                enterStopFailureFallback(
                    lease: lease,
                    stopError: terminalMessage,
                    followupError: error.localizedDescription
                )
            }
        }
    }

    private func handleLocalInterrupt(
        _ reason: NotebookCaptureInterruptReason,
        message: String,
        sessionId: String,
        makeCallbackReady generation: UInt64? = nil
    ) async {
        beginLifecycleOperation()
        defer { endLifecycleOperation() }
        guard self.sessionId == sessionId,
              captureState.isActive,
              let lease = beginTerminalTransition(sessionId: sessionId)
        else { return }
        lastError = message
        providerErrorType = reason.rawValue
        let convergence = enterTerminalConvergence(sessionId: sessionId, lease: lease)
        startAudioDrainWatchdog(for: lease)
        if let generation {
            readyCallbackGeneration = generation
            drainPendingCaptureCallback(generation: generation)
        }
        await convergence.gate?.fence()
        audioFenceDidDrain(for: lease)
        guard isCurrentTerminalTransition(lease) else { return }

        do {
            let event = try await client.interruptNotebookCaptureSession(
                sessionId: sessionId,
                reason: reason
            )
            guard isCurrentTerminalTransition(lease) else { return }
            if applyAuthoritativeTerminal(event, for: lease) == false {
                enterStopFailureFallback(
                    lease: lease,
                    stopError: message,
                    followupError: "durable interrupt returned an active capture"
                )
            }
        } catch {
            if isCurrentTerminalTransition(lease) {
                enterStopFailureFallback(
                    lease: lease,
                    stopError: message,
                    followupError: error.localizedDescription
                )
            }
        }
    }

    private func startElapsedTimer() {
        elapsedTimer?.cancel()
        elapsedRecordingTime = 0
        elapsedTimer = Timer.publish(every: elapsedTimerInterval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                guard self.isCaptureActive else {
                    self.stopElapsedTimer()
                    return
                }
                if self.captureState == .recording {
                    self.elapsedRecordingTime += self.elapsedTimerInterval
                }
                MenuBarRuntimeStore.shared.updateRecording { info in
                    info.elapsed = self.elapsedRecordingTime
                }
            }
    }

    private func stopElapsedTimer() {
        elapsedTimer?.cancel()
        elapsedTimer = nil
    }

    private func beginLifecycleOperation() {
        lifecycleOperationCount += 1
    }

    private func endLifecycleOperation() {
        precondition(lifecycleOperationCount > 0)
        lifecycleOperationCount -= 1
        guard lifecycleOperationCount == 0 else { return }
        let waiters = lifecycleOperationWaiters
        lifecycleOperationWaiters.removeAll(keepingCapacity: true)
        waiters.forEach { $0.resume() }
    }

    private func waitForLifecycleQuiescence() async {
        guard lifecycleOperationCount > 0 else { return }
        await withCheckedContinuation { continuation in
            lifecycleOperationWaiters.append(continuation)
        }
    }

    private func normalizedLanguage(_ language: String) -> String {
        language.lowercased().split(separator: "-").first.map(String.init) ?? ""
    }

    private func sameLanguage(_ lhs: String, _ rhs: String) -> Bool {
        normalizedLanguage(lhs) == normalizedLanguage(rhs)
    }

    private func displayLanguage(_ language: String) -> String {
        switch normalizedLanguage(language) {
        case "en": return "EN"
        case "zh": return "中"
        case "ja": return "日"
        case "ko": return "한"
        case "es": return "ES"
        case "fr": return "FR"
        case "de": return "DE"
        default: return language.uppercased()
        }
    }

    private func formatTimestamp(_ milliseconds: UInt64?) -> String {
        guard let milliseconds else { return "" }
        let total = Int(milliseconds / 1_000)
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        let hours = total / 3_600
        return hours > 0
            ? String(format: "%02d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
    }
}
