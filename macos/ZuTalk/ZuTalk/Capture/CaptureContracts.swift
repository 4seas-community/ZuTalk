import AVFoundation
import Combine
import Foundation

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

    /// Greatest durable watermark carried by a machine Final lane in this
    /// row. Zero is the legacy/not-yet-projectable sentinel.
    var highestFinalLaneProjectionRevision: UInt64 {
        var highest: UInt64 = hasSourceLane && completion == "complete"
            ? sourceProjectionRevision
            : 0
        for variant in languageVariants where
            ["translation", "translated"].contains(variant.role)
                && variant.state == "ready"
                && variant.completion == "complete"
                && variant.text != nil {
            highest = max(highest, variant.projectionRevision)
        }
        return highest
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

struct NotebookCaptureLaneMutationKey: Hashable {
    let utteranceId: String
    let language: String

    init(utteranceId: String, language: String) {
        self.utteranceId = utteranceId
        self.language = NotebookCaptureUtteranceDTO.languageKey(language)
    }
}

struct NotebookCaptureCommittedLaneOverrideBarrier {
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

/// One stretch of captured audio that went untranscribed in realtime — a
/// network outage the reconnect loop rode out by skipping to the live edge.
/// Positions are milliseconds on the capture timeline. The transcript view
/// draws unrepaired gaps as time-labeled dividers between the rows around
/// them; a `repaired` gap has been filled by post-stop transcription and no
/// longer earns a divider.
struct NotebookTranscriptGapDTO: Equatable, Identifiable {
    let id: String
    let sessionId: String
    let startMs: UInt64
    let endMs: UInt64
    let repairState: String

    var isRepaired: Bool { repairState == "repaired" }
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
    /// Sequences a provider replacement withdrew. Deltas only — a full
    /// snapshot's `utterances` is already the whole truth. Rust never puts a
    /// sequence in both lists, so order between the two does not matter.
    var removedSequences: [UInt64] = []
    /// Deltas carry only cues changed by this event; a full snapshot replaces
    /// the session's whole cue view. A withdrawn cue removes its entry.
    let translationCues: [NotebookCaptureTranslationCueDTO]
    /// Present only on lane transitions and always the whole group; empty
    /// means "nothing to report", so the last non-empty set stands.
    let laneHealth: [NotebookCaptureLaneHealthDTO]
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
        removedSequences: [UInt64] = [],
        translationCues: [NotebookCaptureTranslationCueDTO] = [],
        laneHealth: [NotebookCaptureLaneHealthDTO] = [],
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
        self.removedSequences = removedSequences
        self.translationCues = translationCues
        self.laneHealth = laneHealth
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
    let translationCues: [NotebookCaptureTranslationCueDTO]
    let laneHealth: [NotebookCaptureLaneHealthDTO]

    init(
        sessionId: String,
        previewRevision: UInt64,
        utterances: [NotebookCaptureUtteranceDTO],
        translationCues: [NotebookCaptureTranslationCueDTO] = [],
        laneHealth: [NotebookCaptureLaneHealthDTO] = []
    ) {
        self.sessionId = sessionId
        self.previewRevision = previewRevision
        self.utterances = utterances
        self.translationCues = translationCues
        self.laneHealth = laneHealth
    }
}

/// One auxiliary translation segment anchored to the capture audio timeline.
///
/// A cue never references a canonical row. Which words it translates is a
/// read-time question answered by time overlap, which is what lets the
/// audience canvas show a translation the moment the provider produces it
/// instead of waiting for the slower canonical lane.
struct NotebookCaptureTranslationCueDTO: Codable, Equatable, Identifiable {
    let targetLanguage: String
    let groupEpoch: UInt64
    let providerSequence: UInt64
    let sourceLanguage: String
    let sourceStartMs: UInt64?
    let sourceEndMs: UInt64?
    let text: String
    /// "partial" while the provider is still revising, "complete" once final.
    let completion: String
    /// A withdrawn cue is a removal instruction for a retracted segment.
    let withdrawn: Bool
    let revision: UInt64

    var id: String { "\(groupEpoch):\(providerSequence):\(targetLanguage)" }
}

/// Health of one stream lane in the running capture group.
///
/// Operator chrome only. The audience canvas consumes exactly one bit of it —
/// a lane that will never fill again stops showing the waiting ellipsis,
/// because a placeholder promises "it's coming" and a dead lane is not.
struct NotebookCaptureLaneHealthDTO: Codable, Equatable {
    enum State: String, Codable {
        case live
        case connecting
        case failed
    }

    /// nil is the canonical transcription lane.
    let targetLanguage: String?
    let state: State
    let groupEpoch: UInt64
    let finalAudioProcMs: UInt64?
    let totalAudioProcMs: UInt64?
    let lagMs: UInt64?
    let inputDiscontinuous: Bool

    init(
        targetLanguage: String?,
        state: State,
        groupEpoch: UInt64 = 0,
        finalAudioProcMs: UInt64? = nil,
        totalAudioProcMs: UInt64? = nil,
        lagMs: UInt64? = nil,
        inputDiscontinuous: Bool = false
    ) {
        self.targetLanguage = targetLanguage
        self.state = state
        self.groupEpoch = groupEpoch
        self.finalAudioProcMs = finalAudioProcMs
        self.totalAudioProcMs = totalAudioProcMs
        self.lagMs = lagMs
        self.inputDiscontinuous = inputDiscontinuous
    }
}

enum NotebookCaptureInterruptReason: String, Codable, Equatable, Sendable {
    case localAudioOverflow = "local_audio_overflow"
    case localAudioUnavailable = "local_audio_unavailable"
}
