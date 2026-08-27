import AVFoundation
import Combine
import Foundation

// MARK: - Active capture store

/// High-frequency, process-local presentation state lives on its own publisher.
/// Capture controls and settings observe `ActiveBilingualTranscriptStore`; they
/// must not rebuild for every speculative word, cue, or telemetry tick.
@MainActor
final class NotebookCaptureLivePresentationStore: ObservableObject {
    struct Frame: Equatable {
        var utterances: [NotebookCaptureUtteranceDTO] = []
        var translationCues: [String: NotebookCaptureTranslationCueDTO] = [:]
        var laneHealth: [String: NotebookCaptureLaneHealthDTO.State] = [:]
        var laneTelemetry: [String: NotebookCaptureLaneHealthDTO] = [:]
        /// The first live cue snapshot is authoritative even when it is empty:
        /// it hides an older durable cue tail until the live session ends.
        var hasTranslationCueAuthority = false
    }

    @Published private(set) var frame = Frame()

    var utterances: [NotebookCaptureUtteranceDTO] { frame.utterances }
    var translationCues: [String: NotebookCaptureTranslationCueDTO] {
        frame.translationCues
    }
    var laneHealth: [String: NotebookCaptureLaneHealthDTO.State] {
        frame.laneHealth
    }
    var laneTelemetry: [String: NotebookCaptureLaneHealthDTO] {
        frame.laneTelemetry
    }
    var hasTranslationCueAuthority: Bool { frame.hasTranslationCueAuthority }

    /// Mutates a complete presentation value off-publisher and installs it in
    /// one assignment. A preview revision therefore exposes either the previous
    /// frame or the complete next frame, never a cue/health/utterance mixture.
    @discardableResult
    fileprivate func updateFrame(_ mutate: (inout Frame) -> Void) -> Bool {
        var next = frame
        mutate(&next)
        guard next != frame else { return false }
        frame = next
        return true
    }

    fileprivate func resetFrame() {
        guard frame != Frame() else { return }
        frame = Frame()
    }
}

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
        private static let maximumBufferedDeltaCount = 256

        let id: UUID
        let sessionId: String
        let generation: UInt64?
        var targetEventRevision: UInt64
        var bufferedDeltas: [UInt64: NotebookCaptureEventDTO]

        mutating func observe(_ event: NotebookCaptureEventDTO) {
            guard event.sessionId == sessionId,
                  event.isFullSnapshot == false,
                  event.eventRevision > 0
            else { return }
            targetEventRevision = max(targetEventRevision, event.eventRevision)
            bufferedDeltas[event.eventRevision] = event
            while bufferedDeltas.count > Self.maximumBufferedDeltaCount,
                  let oldestRevision = bufferedDeltas.keys.min() {
                bufferedDeltas.removeValue(forKey: oldestRevision)
            }
        }
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
    let livePresentation = NotebookCaptureLivePresentationStore()
    private struct AudienceDurablePresentationCache {
        let sessionId: String
        let selectedLanguages: [String]
        let fallbackLanguage: String?
        let maximumRows: Int
        let utterances: [NotebookCaptureUtteranceDTO]
        let inheritedSourceAnchors: [String: UInt64]
    }
    private var audienceDurablePresentationCache: AudienceDurablePresentationCache?
    private var cachedLastIdentifiedSourceLanguage: String?
    private var hasCachedLastIdentifiedSourceLanguage = false
    private var cachedHighestFinalProjectionRevision: UInt64 = 0
    private var hasCachedHighestFinalProjectionRevision = false
    var livePreviewUtterances: [NotebookCaptureUtteranceDTO] {
        livePresentation.utterances
    }
    @Published private(set) var utterances: [NotebookCaptureUtteranceDTO] = [] {
        didSet {
            // Durable rows change far less often than speculative frames. A
            // lazy invalidation makes a long `und` tail pay for one reverse
            // scan at the next durable boundary, not once per visible row on
            // every provider-rate SwiftUI refresh.
            cachedLastIdentifiedSourceLanguage = nil
            hasCachedLastIdentifiedSourceLanguage = false
            cachedHighestFinalProjectionRevision = 0
            hasCachedHighestFinalProjectionRevision = false
            audienceDurablePresentationCache = nil
        }
    }
    /// Time-anchored auxiliary translation cues, keyed by cue identity.
    /// The audience canvas reads translations from here in multilingual mode;
    /// the durable transcript keeps reading bound utterance variants.
    @Published private(set) var translationCues: [String: NotebookCaptureTranslationCueDTO] = [:]
    /// Bounded replace-in-full cue tail delivered with the speculative source
    /// frame. While capture is active this is the live canvas authority; it is
    /// deliberately separate from the durable all-session cue dictionary.
    var liveTranslationCues: [String: NotebookCaptureTranslationCueDTO] {
        livePresentation.translationCues
    }
    /// Per-lane health of the running stream group, keyed by target language;
    /// the canonical lane is keyed by `canonicalLaneHealthKey`. Process-local:
    /// it describes a live group, so it is empty outside one.
    var laneHealth: [String: NotebookCaptureLaneHealthDTO.State] {
        livePresentation.laneHealth
    }
    /// Full per-lane progress state from the latest replace-in-full frame.
    /// This lets operator telemetry distinguish provider lag from UI paint or
    /// row-correlation delay without exposing diagnostics on the audience UI.
    var laneTelemetry: [String: NotebookCaptureLaneHealthDTO] {
        livePresentation.laneTelemetry
    }

    /// The canonical transcription lane has no target language of its own.
    static let canonicalLaneHealthKey = "#canonical"

    /// Target languages whose translation lane was stopped at the live edge
    /// because local audio could no longer be appended to it contiguously.
    ///
    /// Transcription carries on, so nothing about the screen says translation
    /// ended — the column simply stops growing, minutes before anyone notices.
    /// The lane cannot rejoin the recording either: resuming it would place
    /// new audio on a provider timeline that no longer matches. So the only
    /// honest thing to do is say which languages stopped and when.
    var haltedTranslationLanguages: [String] {
        laneTelemetry
            .filter { key, lane in
                key != Self.canonicalLaneHealthKey && lane.inputDiscontinuous
            }
            .keys
            .sorted()
    }
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
    /// Process-local presentation for a terminal command whose durable owner
    /// could not yet be converged. `captureState` remains Rust-authoritative;
    /// the UI uses this flag to show an actionable retry instead of an
    /// indefinite draining spinner.
    @Published private(set) var stopRecoveryRequired = false
    /// Derived, process-local presentation state. Rust remains authoritative
    /// for the durable capture state; this flag only tells the UI that closing
    /// the admitted local-audio backlog has exceeded the watchdog interval.
    @Published private(set) var isAudioDrainDelayed = false
    @Published private(set) var isAudioInputSwitching = false
    @Published private(set) var activeAudioInputDevice: AudioInputDevice?

    private let client: NotebookCaptureClienting
    private let audioSource: NotebookCaptureAudioSourcing
    private let elapsedTimerInterval: TimeInterval
    private let audioQueueCapacity: Int
    private let audioDrainWatchdogInterval: TimeInterval
    /// Zero publishes every revision synchronously, which is what a test that
    /// asserts on preview content wants: the coalescing window is a rendering
    /// budget, not a contract about what the transcript contains.
    private let livePreviewCoalescingInterval: TimeInterval
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
    private var lastLivePreviewPublishedAt: TimeInterval?
    private var heldLivePreview: NotebookCaptureLivePreviewDTO?
    private var livePreviewFlushTask: Task<Void, Never>?
    private var pendingCallbackEvent: NotebookCaptureEventDTO?
    private var pendingLivePreview: NotebookCaptureLivePreviewDTO?
    private var utteranceGapRepair: UtteranceGapRepair?
    private var utteranceGapRepairTask: Task<Void, Never>?
    /// Published because `isEditable` reads it: the transcript withdraws its
    /// lane carets for the length of a terminal transition, and a caret that
    /// outlives the store's own gate is a caret whose commit is rejected.
    @Published private var terminalTransitionLease: TerminalTransitionLease?
    private var terminalTransitionDrainPending = false
    private var pendingTerminalTransitionEvent: NotebookCaptureEventDTO?
    private var audioDrainWatchdogTask: Task<Void, Never>?
    /// Store-wide single flight. A view-local loading flag disappears when
    /// navigation rebuilds Home, while microphone permission and device
    /// preparation can still be suspended. Keeping the lease here prevents a
    /// second Start from replacing the callback generation of the first.
    private var captureStartInFlight = false
    private var lifecycleOperationCount = 0
    private var lifecycleOperationWaiters: [CheckedContinuation<Void, Never>] = []

    var presentationCaptureState: NotebookCaptureState {
        stopRecoveryRequired ? .failed : captureState
    }

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
        audioDrainWatchdogInterval: TimeInterval = 5,
        livePreviewCoalescingInterval: TimeInterval = NotebookCaptureLivePreviewCoalescing.interval
    ) {
        self.client = client ?? RustNotebookCaptureClient()
        self.audioSource = audioSource ?? LiveNotebookCaptureAudioSource()
        self.elapsedTimerInterval = max(0.001, elapsedTimerInterval)
        self.audioQueueCapacity = max(1, audioQueueCapacity)
        self.audioDrainWatchdogInterval = max(0.001, audioDrainWatchdogInterval)
        self.livePreviewCoalescingInterval = max(0, livePreviewCoalescingInterval)
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

    func presentedUtteranceTail(limit: Int) -> [NotebookCaptureUtteranceDTO] {
        NotebookCaptureLivePresentation.utteranceTail(
            durable: utterances,
            preview: livePreviewUtterances,
            sessionId: sessionId,
            limit: limit
        )
    }

    /// One coherent durable audience frame: the bounded candidate rows and the
    /// whole-session anchor bounds they were pruned under. The two must come
    /// from the same computation — pruning an untimed row under one order and
    /// painting it under another is exactly how a bounded column stops matching
    /// the full one.
    private func audienceDurablePresentation(
        maximumRows: Int,
        sessionId: String
    ) -> AudienceDurablePresentationCache? {
        guard maximumRows > 0 else { return nil }
        let languages = selectedLanguages
        let fallbackLanguage = lastIdentifiedSourceLanguage ?? languages.first
        if let cache = audienceDurablePresentationCache,
           cache.sessionId == sessionId,
           cache.selectedLanguages == languages,
           cache.fallbackLanguage == fallbackLanguage,
           cache.maximumRows == maximumRows {
            return cache
        }
        let anchors = NotebookCaptureLivePresentation.inheritedSourceAnchors(
            durable: utterances,
            sessionId: sessionId
        )
        let cache = AudienceDurablePresentationCache(
            sessionId: sessionId,
            selectedLanguages: languages,
            fallbackLanguage: fallbackLanguage,
            maximumRows: maximumRows,
            utterances: NotebookCaptureLivePresentation.audienceDurableCandidates(
                durable: utterances,
                sessionId: sessionId,
                selectedLanguages: languages,
                lastIdentifiedSourceLanguage: fallbackLanguage,
                maximumRows: maximumRows,
                inheritedSourceAnchors: anchors
            ),
            inheritedSourceAnchors: anchors
        )
        audienceDurablePresentationCache = cache
        return cache
    }

    /// The sort-only bounds belonging to `presentedAudienceUtterances` at the
    /// same row budget. Live preview rows are absent on purpose: they are the
    /// newest words in the session, so having no bound already places them
    /// where they belong.
    func presentedAudienceInheritedSourceAnchors(maximumRows: Int) -> [String: UInt64] {
        let maximumRows = max(maximumRows, 0)
        guard maximumRows > 0, let sessionId else { return [:] }
        return audienceDurablePresentation(
            maximumRows: maximumRows,
            sessionId: sessionId
        )?.inheritedSourceAnchors ?? [:]
    }

    /// A presentation-equivalent, canvas-bounded audience input. Durable
    /// candidates are rebuilt only when durable rows/profile context changes;
    /// provider-rate preview frames merge into that small cache without
    /// walking or allocating the complete session.
    func presentedAudienceUtterances(maximumRows: Int) -> [NotebookCaptureUtteranceDTO] {
        let maximumRows = max(maximumRows, 0)
        guard maximumRows > 0, let sessionId else { return [] }
        let durableCandidates = audienceDurablePresentation(
            maximumRows: maximumRows,
            sessionId: sessionId
        )?.utterances ?? []

        func containsDurableSequence(_ sequence: UInt64) -> Bool {
            var lowerBound = 0
            var upperBound = utterances.count
            while lowerBound < upperBound {
                let midpoint = lowerBound + (upperBound - lowerBound) / 2
                if utterances[midpoint].sequence < sequence {
                    lowerBound = midpoint + 1
                } else {
                    upperBound = midpoint
                }
            }
            return lowerBound < utterances.count
                && utterances[lowerBound].sequence == sequence
                && utterances[lowerBound].sessionId == sessionId
        }

        var presented = durableCandidates
        presented.append(contentsOf: livePreviewUtterances.filter {
            $0.sessionId == sessionId && containsDurableSequence($0.sequence) == false
        })
        presented.sort {
            if $0.sequence != $1.sequence { return $0.sequence < $1.sequence }
            return $0.id < $1.id
        }
        return presented
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

        // A durable Notebook binding is the user's standing choice. Profile
        // autosave must not grow a second context-preparation gate: Start
        // recompiles the latest payload and Rust verifies that exact digest.
        if saved.sendContextToSoniox == false {
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

    /// Compiles the Notebook's currently bound reference material and records
    /// its exact digest for the imminent capture. Binding is the durable user
    /// choice; this digest remains a short-lived integrity check, not a second
    /// per-launch confirmation step.
    @discardableResult
    func prepareContextForCapture(
        notebookId: String
    ) throws -> NotebookCaptureContextPreviewDTO {
        do {
            let preview = try client.previewNotebookCaptureContext(notebookId: notebookId)
            contextPreview = preview
            guard preview.notebookId == notebookId,
                  preview.containsSendableContext
            else {
                confirmedContextDigest = nil
                confirmedContextNotebookId = nil
                throw NotebookCaptureClientError.contextUnavailable
            }
            confirmedContextDigest = preview.digest
            confirmedContextNotebookId = notebookId
            lastError = nil
            return preview
        } catch {
            confirmedContextDigest = nil
            confirmedContextNotebookId = nil
            if contextPreview?.notebookId != notebookId {
                contextPreview = nil
            }
            lastError = error.localizedDescription
            throw error
        }
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
            } ?? packs.first(where: { $0.isPrivate == false && $0.isBound })?.id
                ?? packs.first(where: \.isPrivate)?.id
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

    /// Makes one Pack the Notebook's durable transcription context. Library
    /// bindings are the persisted selection, so reopening the Notebook restores
    /// the same Pack without a second UI-only preference.
    func selectContextPackForTranscription(_ packId: String, notebookId: String) throws {
        guard loadedContextNotebookId == notebookId,
              let selected = contextPacks.first(where: { $0.id == packId })
        else { return }

        for pack in contextPacks where pack.isPrivate == false && pack.id != packId && pack.isBound {
            try client.setNotebookContextPackBinding(
                notebookId: notebookId,
                packId: pack.id,
                position: nil
            )
        }
        if selected.isPrivate == false && selected.isBound == false {
            try client.setNotebookContextPackBinding(
                notebookId: notebookId,
                packId: selected.id,
                position: 0
            )
        }

        invalidateContextPreview()
        try loadContextPacks(notebookId: notebookId)
        try selectContextPack(packId, notebookId: notebookId)
        let preview = try previewContext(notebookId: notebookId)
        if preview.containsSendableContext {
            confirmContextPreview(digest: preview.digest)
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

    /// Writes the whole Pack to one shareable file. The file is plaintext, so
    /// the caller must have asked for this explicitly.
    @discardableResult
    func exportContextPack(
        notebookId: String,
        packId: String,
        destinationPath: String
    ) throws -> UInt32 {
        try client.exportContextPack(
            notebookId: notebookId,
            packId: packId,
            destinationPath: destinationPath
        )
    }

    /// Loads a Pack file into a brand-new Library Pack and selects it.
    @discardableResult
    func importContextPack(
        notebookId: String,
        sourcePath: String
    ) throws -> NotebookContextPackDTO {
        let pack = try client.importContextPack(sourcePath: sourcePath, titleOverride: nil)
        invalidateContextPreview()
        try loadContextPacks(notebookId: notebookId)
        try selectContextPack(pack.id, notebookId: notebookId)
        return pack
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
        guard captureStartInFlight == false,
              isCaptureActive == false,
              terminalTransitionLease == nil
        else { throw NotebookCaptureClientError.captureAlreadyActive }
        captureStartInFlight = true
        beginLifecycleOperation()
        defer {
            captureStartInFlight = false
            endLifecycleOperation()
        }
        // The durable owner may still be completing an older run after Swift
        // has already removed its microphone. Reject before even reading the
        // next profile or preparing audio so a second capture cannot overlap
        // that terminal transition.
        // Always resolve the current persisted profile. `profile` also carries
        // an immutable historical run snapshot while reopening transcripts and
        // must never be reused as configuration for a new capture.
        let startProfile = try client.getNotebookCaptureProfile(notebookId: notebookId)
        try validate(startProfile)
        let startContextDigest = startProfile.sendContextToSoniox
            ? try prepareContextForCapture(notebookId: notebookId).digest
            : nil

        try await audioSource.prepare()
        // MainActor methods can interleave at the permission/device await.
        // Re-prove the durable owner is still idle before allocating a callback
        // generation or asking Rust to create a capture run.
        guard isCaptureActive == false,
              terminalTransitionLease == nil
        else { throw NotebookCaptureClientError.captureAlreadyActive }
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
                confirmedContextDigest: startContextDigest,
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
        self.cachedLastIdentifiedSourceLanguage = nil
        cancelLivePreviewCoalescing()
        self.livePresentation.updateFrame { frame in
            frame.utterances = []
        }
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
        self.stopRecoveryRequired = false
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

    /// Rebinds only the local microphone generation. The durable Notebook
    /// capture, provider stream, callback generation and audio push gate stay
    /// alive, so changing hardware does not create a new transcript session.
    func selectAudioInputDevice(uid: String?, notebookId requestedNotebookId: String) async throws {
        let trimmedUID = uid?.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedUID = trimmedUID?.isEmpty == false ? trimmedUID : nil
        guard isAudioInputSwitching == false,
              lifecycleOperationCount == 0,
              terminalTransitionLease == nil,
              isCaptureActive == false || notebookId == requestedNotebookId
        else {
            throw AudioInputDeviceError.switchUnavailable
        }
        isAudioInputSwitching = true
        beginLifecycleOperation()
        defer {
            endLifecycleOperation()
            isAudioInputSwitching = false
        }

        // Resolve without mutating UserDefaults. A failed B bind must leave A
        // selected and available for an immediate rollback.
        let candidate = try audioSource.resolveInputDevice(uid: requestedUID)
        let previousSelectionUID = audioSource.selectedInputDeviceUID
        let previousDevice = audioSource.preparedInputDevice

        guard isCaptureActive else {
            audioSource.commitInputDeviceSelection(uid: requestedUID, device: candidate)
            return
        }
        guard captureState == .recording else {
            if captureState == .paused {
                audioSource.commitInputDeviceSelection(uid: requestedUID, device: candidate)
                activeAudioInputDevice = candidate
                return
            }
            throw AudioInputDeviceError.switchUnavailable
        }
        guard let sessionId,
              let gate = audioPushGate,
              audioToken != nil,
              let previousDevice
        else {
            throw NotebookCaptureClientError.captureNotActive
        }

        // Switching preference semantics (explicit vs system-default) does not
        // need a hardware restart when both resolve to the same physical input.
        if candidate.uid == previousDevice.uid,
           candidate.deviceID == previousDevice.deviceID {
            audioSource.commitInputDeviceSelection(uid: requestedUID, device: candidate)
            activeAudioInputDevice = candidate
            return
        }

        let microphoneTerminal = releaseMicrophoneSubscription()
        if let microphoneTerminal {
            await handleAudioTerminal(microphoneTerminal.rawValue, sessionId: sessionId)
            throw NotebookCaptureClientError.captureNotActive
        }
        if let gateTerminal = gate.terminalMessage {
            await handleAudioTerminal(gateTerminal, sessionId: sessionId)
            throw NotebookCaptureClientError.captureNotActive
        }

        do {
            try subscribeMicrophone(
                sessionId: sessionId,
                gate: gate,
                inputDevice: candidate
            )
            audioSource.commitInputDeviceSelection(uid: requestedUID, device: candidate)
        } catch let switchError {
            var rollbackCandidates: [AudioInputDevice] = []
            if let previousSelectionUID {
                if let refreshedExplicitDevice = try? audioSource.resolveInputDevice(
                    uid: previousSelectionUID
                ) {
                    rollbackCandidates.append(refreshedExplicitDevice)
                }
                if rollbackCandidates.contains(previousDevice) == false {
                    rollbackCandidates.append(previousDevice)
                }
            } else {
                // "System default" is a preference, not the identity of the
                // device that was actually recording. Restore that concrete
                // device first; if it disappeared, the latest default is a
                // second recovery option.
                rollbackCandidates.append(previousDevice)
                if let latestDefault = try? audioSource.resolveInputDevice(uid: nil),
                   rollbackCandidates.contains(latestDefault) == false {
                    rollbackCandidates.append(latestDefault)
                }
            }

            var rollbackError: Error?
            var didRestoreMicrophone = false
            for rollbackDevice in rollbackCandidates {
                do {
                    try subscribeMicrophone(
                        sessionId: sessionId,
                        gate: gate,
                        inputDevice: rollbackDevice
                    )
                    audioSource.commitInputDeviceSelection(
                        uid: previousSelectionUID,
                        device: rollbackDevice
                    )
                    didRestoreMicrophone = true
                    break
                } catch let error {
                    rollbackError = error
                }
            }
            if didRestoreMicrophone == false {
                await handleLocalInterrupt(
                    .localAudioUnavailable,
                    message: "\(switchError.localizedDescription) · \(rollbackError?.localizedDescription ?? AudioInputDeviceError.noInputDevice.localizedDescription)",
                    sessionId: sessionId
                )
            }
            throw switchError
        }
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
                let readError = error
                // The read and the failed Stop can contend on the same SQLite
                // writer. Retry through Rust's ownership-gated interruption:
                // it tears down a live owner or neutrally recovers a Stop run
                // that already handed off to detached recovery.
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
                            followupError: "durable recovery returned an active capture"
                        )
                    } else {
                        lastError = stopError.localizedDescription
                    }
                } catch {
                    if isCurrentTerminalTransition(lease) {
                        enterStopFailureFallback(
                            lease: lease,
                            stopError: stopError.localizedDescription,
                            followupError: "\(readError.localizedDescription) · \(error.localizedDescription)"
                        )
                    }
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

    /// Retries only the durable terminal convergence after a failed Stop.
    /// The microphone and local push gate are already closed; Rust either
    /// interrupts a remaining owner or neutrally recovers the detached run.
    func retryStopRecovery() async throws {
        beginLifecycleOperation()
        defer { endLifecycleOperation() }
        guard stopRecoveryRequired,
              let sessionId,
              let lease = terminalTransitionLease,
              isCurrentTerminalTransition(lease)
        else {
            throw NotebookCaptureClientError.captureNotActive
        }
        let previousStopError = lastError

        let event: NotebookCaptureEventDTO
        do {
            event = try await client.interruptNotebookCaptureSession(
                sessionId: sessionId,
                reason: .localAudioUnavailable
            )
        } catch {
            enterStopFailureFallback(
                lease: lease,
                stopError: lastError ?? error.localizedDescription,
                followupError: error.localizedDescription
            )
            throw error
        }
        guard isCurrentTerminalTransition(lease) else {
            if captureState.isActive == false, lastError == previousStopError {
                lastError = nil
            }
            return
        }
        guard applyAuthoritativeTerminal(event, for: lease) else {
            enterStopFailureFallback(
                lease: lease,
                stopError: lastError ?? "durable Stop recovery",
                followupError: "durable recovery returned an active capture"
            )
            throw NotebookCaptureClientError.captureNotActive
        }
        if lastError == previousStopError {
            lastError = nil
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
        stopRecoveryRequired = false
        isAudioInputSwitching = false
        activeAudioInputDevice = nil
        audioPushGate?.abort()
        audioPushGate = nil
        releaseMicrophoneSubscription()
        stopElapsedTimer()
        sessionId = nil
        notebookId = nil
        profile = .localDefault(notebookId: "")
        captureState = .completed
        remoteHealth = .off
        realtimeLagMs = nil
        projectionState = .ready
        utterances = []
        cachedLastIdentifiedSourceLanguage = nil
        translationCues = [:]
        committedLaneOverrideBarriers.removeAll(keepingCapacity: true)
        cancelLivePreviewCoalescing()
        livePresentation.resetFrame()
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
            commonCaptionLanguage: commonCaptionLanguage,
            // The leading selected column carries the first line of a session,
            // before any language has been identified to inherit.
            lastIdentifiedSourceLanguage: lastIdentifiedSourceLanguage
                ?? selectedLanguages.first
        )
    }

    /// Which audience column a source line joins; nil keeps it a full-width
    /// unrouted line. Mirrors the audience-mode lane rules exactly.
    func audienceSourcePlacement(
        for utterance: NotebookCaptureUtteranceDTO
    ) -> String? {
        makeAudienceSourcePlacement()(utterance)
    }

    /// Freezes the language-placement context for one presentation pass.
    /// Besides guaranteeing that every row uses the same settled-language
    /// fallback, this avoids rescanning a long `und` tail for every row.
    func makeAudienceSourcePlacement() -> (NotebookCaptureUtteranceDTO) -> String? {
        let languages = selectedLanguages
        let fallbackLanguage = lastIdentifiedSourceLanguage ?? languages.first
        return { utterance in
            NotebookCaptureHistoryPolicy.audienceSourcePlacement(
                for: utterance,
                selectedLanguages: languages,
                lastIdentifiedSourceLanguage: fallbackLanguage
            )
        }
    }

    /// The most recent language the provider actually identified in this
    /// session. Used only as the last resort for placing an `und` line, after
    /// the provider's own per-utterance hint. Durable merge/snapshot boundaries
    /// refresh the cache once; a live SwiftUI frame must never rescan the whole
    /// session just to place each visible row.
    private var lastIdentifiedSourceLanguage: String? {
        if hasCachedLastIdentifiedSourceLanguage {
            return cachedLastIdentifiedSourceLanguage
        }
        defer { hasCachedLastIdentifiedSourceLanguage = true }
        for utterance in utterances.reversed() where utterance.hasSourceLane {
            let language = utterance.sourceLanguage.lowercased()
            if language.isEmpty == false, language != "und" {
                cachedLastIdentifiedSourceLanguage = language
                return cachedLastIdentifiedSourceLanguage
            }
        }
        cachedLastIdentifiedSourceLanguage = nil
        return cachedLastIdentifiedSourceLanguage
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
        reconcileTranslationCues(for: event)
        reconcileLaneHealth(for: event)
        projectRealtimeIfPending(sessionId: event.sessionId)
        if let receipt = event.contextReceipt, receipt.applied {
            appliedContextReceipt = receipt
            appliedContextSessionId = event.sessionId
        }

        if event.captureState.isActive == false {
            cancelLivePreviewCoalescing()
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

    private func projectRealtimeIfPending(sessionId eventSessionId: String) {
        guard captureState.isActive,
              sessionId == eventSessionId,
              highestFinalProjectionRevision > realtimeLoroAppliedRevision
        else { return }
        try? client.projectNotebookRealtimeIncremental(sessionId: eventSessionId)
    }

    /// Empty progress callbacks dominate event volume. Cache the durable
    /// maximum across them so an acknowledged long transcript does not trade
    /// the removed Rust hydration for an O(n) MainActor scan on every event.
    private var highestFinalProjectionRevision: UInt64 {
        if hasCachedHighestFinalProjectionRevision {
            return cachedHighestFinalProjectionRevision
        }
        cachedHighestFinalProjectionRevision = utterances.reduce(UInt64(0)) {
            max($0, $1.highestFinalLaneProjectionRevision)
        }
        hasCachedHighestFinalProjectionRevision = true
        return cachedHighestFinalProjectionRevision
    }

    private func merge(_ updates: [NotebookCaptureUtteranceDTO]) {
        guard updates.isEmpty == false else { return }
        let preparedUpdates = prepareUtteranceUpdates(updates)
        var mergedUtterances = utterances
        for update in preparedUpdates {
            Self.upsertOrderedUtterance(update, into: &mergedUtterances)
        }
        if mergedUtterances != utterances {
            utterances = mergedUtterances
        }
        // Preserve the old non-empty-event menu refresh behavior even when all
        // rows belong to another session or lose stale-revision arbitration.
        refreshRecentTranscriptPresentation()
    }

    /// Drops rows a provider replacement withdrew.
    ///
    /// The durable row is already gone in Rust, so this is not a policy
    /// decision the client gets to weigh — it is the client catching up. What
    /// it must not do is drop a row the same batch is re-adding as a
    /// translation-only shell; Rust guarantees a sequence is never in both
    /// lists, and [`reconcileUtterances`] applies them in one pass either way.
    private func removeUtterances(sequences: [UInt64]) {
        guard sequences.isEmpty == false else { return }
        let withdrawn = Set(sequences)
        let remaining = utterances.filter {
            $0.sessionId != sessionId || withdrawn.contains($0.sequence) == false
        }
        guard remaining.count != utterances.count else { return }
        utterances = remaining
        refreshRecentTranscriptPresentation()
    }

    /// Applies edit barriers before revision arbitration, matching the durable
    /// callback contract. Keeping this step ordered matters because observing a
    /// callback that contains a committed lane may retire its process-local
    /// barrier for the following update in the same batch.
    private func prepareUtteranceUpdates(
        _ updates: [NotebookCaptureUtteranceDTO]
    ) -> [NotebookCaptureUtteranceDTO] {
        var prepared: [NotebookCaptureUtteranceDTO] = []
        prepared.reserveCapacity(updates.count)
        for unprotectedUpdate in updates {
            let update = protectingCommittedLaneOverrides(in: unprotectedUpdate)
            guard update.sessionId == sessionId else { continue }
            prepared.append(update)
        }
        return prepared
    }

    /// `utterances` is session-scoped and maintained in strict sequence order.
    /// Equal revisions remain last-writer-wins, while a stale revision is
    /// ignored exactly as it was by the former linear-search/full-sort merge.
    private static func upsertOrderedUtterance(
        _ update: NotebookCaptureUtteranceDTO,
        into rows: inout [NotebookCaptureUtteranceDTO]
    ) {
        if let last = rows.last, last.sequence < update.sequence {
            rows.append(update)
            return
        }

        var lowerBound = 0
        var upperBound = rows.count
        while lowerBound < upperBound {
            let midpoint = lowerBound + (upperBound - lowerBound) / 2
            if rows[midpoint].sequence < update.sequence {
                lowerBound = midpoint + 1
            } else {
                upperBound = midpoint
            }
        }

        if lowerBound < rows.count,
           rows[lowerBound].sequence == update.sequence {
            if update.revision >= rows[lowerBound].revision {
                rows[lowerBound] = update
            }
        } else {
            rows.insert(update, at: lowerBound)
        }
    }

    /// Builds an authoritative snapshot off-publisher, selecting the highest
    /// revision for each sequence (and the later row for equal revisions), then
    /// sorting once. The caller installs the completed value atomically.
    private func rebuiltUtteranceSnapshot(
        from updates: [NotebookCaptureUtteranceDTO]
    ) -> [NotebookCaptureUtteranceDTO] {
        let preparedUpdates = prepareUtteranceUpdates(updates)
        var latestBySequence: [UInt64: NotebookCaptureUtteranceDTO] = [:]
        latestBySequence.reserveCapacity(preparedUpdates.count)
        for update in preparedUpdates {
            if let current = latestBySequence[update.sequence],
               update.revision < current.revision {
                continue
            }
            latestBySequence[update.sequence] = update
        }
        return latestBySequence.values.sorted { $0.sequence < $1.sequence }
    }

    private func replaceUtterances(
        with updates: [NotebookCaptureUtteranceDTO]
    ) {
        utterances = rebuiltUtteranceSnapshot(from: updates)
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
        guard preview.sessionId == sessionId, captureState.isActive else { return }
        if let lastAppliedLivePreviewRevision,
           preview.previewRevision <= lastAppliedLivePreviewRevision {
            return
        }
        lastAppliedLivePreviewRevision = preview.previewRevision

        switch NotebookCaptureLivePreviewCoalescing.decide(
            now: Self.livePreviewClock(),
            lastPublishedAt: lastLivePreviewPublishedAt,
            interval: livePreviewCoalescingInterval
        ) {
        case .publishNow:
            publishLivePreview(preview)
        case .hold(let delay):
            // Hold the complete replace-in-full frame. Coalescing only the
            // utterance array allowed cue and lane-health bursts to bypass the
            // rendering budget and invalidate the whole transcript page.
            heldLivePreview = preview
            scheduleLivePreviewFlush(after: delay)
        }
    }

    private static func livePreviewClock() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    private func publishLivePreview(_ preview: NotebookCaptureLivePreviewDTO) {
        guard preview.sessionId == sessionId, captureState.isActive else { return }
        livePreviewFlushTask?.cancel()
        livePreviewFlushTask = nil
        heldLivePreview = nil
        lastLivePreviewPublishedAt = Self.livePreviewClock()

        let nextTranslationCues = Dictionary(
            preview.translationCues
                .filter { $0.withdrawn == false && $0.text.isEmpty == false }
                .map { ($0.id, $0) },
            uniquingKeysWith: { left, right in
                right.revision >= left.revision ? right : left
            }
        )
        let nextLaneHealth = Dictionary(
            preview.laneHealth.map { lane in
                (
                    lane.targetLanguage.map(normalizedLanguage)
                        ?? Self.canonicalLaneHealthKey,
                    lane.state
                )
            },
            uniquingKeysWith: { _, right in right }
        )
        let nextLaneTelemetry = Dictionary(
            preview.laneHealth.map { lane in
                (
                    lane.targetLanguage.map(normalizedLanguage)
                        ?? Self.canonicalLaneHealthKey,
                    lane
                )
            },
            uniquingKeysWith: { _, right in right }
        )
        let nextUtterances = preview.utterances.filter {
            $0.sessionId == preview.sessionId
        }
        let utterancesChanged = nextUtterances != livePreviewUtterances
        livePresentation.updateFrame { frame in
            frame.translationCues = nextTranslationCues
            // The first empty live frame must still hide a durable cue tail.
            // Carrying that authority bit inside the frame makes the boundary
            // one real publication instead of a manual notification followed
            // by several independently published fields.
            frame.hasTranslationCueAuthority = true
            frame.laneHealth = nextLaneHealth
            frame.laneTelemetry = nextLaneTelemetry
            frame.utterances = nextUtterances
        }
        if utterancesChanged {
            refreshRecentTranscriptPresentation()
        }
    }

    private func scheduleLivePreviewFlush(after delay: TimeInterval) {
        // An in-flight flush already covers the newly held revision; letting it
        // stand is what keeps a burst to one publish per window.
        guard livePreviewFlushTask == nil else { return }
        livePreviewFlushTask = Task { @MainActor [weak self] in
            try? await MontereyTaskSleep.seconds(delay)
            guard Task.isCancelled == false else { return }
            self?.flushHeldLivePreview()
        }
    }

    private func flushHeldLivePreview() {
        livePreviewFlushTask = nil
        guard let preview = heldLivePreview else { return }
        publishLivePreview(preview)
    }

    /// Drops any held revision without publishing it. Every path that clears
    /// the preview must call this, otherwise a flush scheduled moments earlier
    /// would repopulate the canvas after the session that produced it is gone.
    private func cancelLivePreviewCoalescing() {
        livePreviewFlushTask?.cancel()
        livePreviewFlushTask = nil
        heldLivePreview = nil
        lastLivePreviewPublishedAt = nil
    }

    private func refreshRecentTranscriptPresentation() {
        let recent = presentedUtteranceTail(limit: 2).map { utterance in
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

    /// Cue deltas upsert by identity and only ever move a key's revision
    /// forward; a stale redelivery after mailbox coalescing is ignored. A
    /// coalescing gap heals through the same full-snapshot rebuild as
    /// utterances, because snapshots carry the whole present cue set.
    private func reconcileTranslationCues(for event: NotebookCaptureEventDTO) {
        if event.isFullSnapshot {
            translationCues = Dictionary(
                event.translationCues.filter { $0.withdrawn == false }.map { ($0.id, $0) },
                uniquingKeysWith: { left, right in right.revision >= left.revision ? right : left }
            )
            return
        }
        guard event.translationCues.isEmpty == false else { return }
        for cue in event.translationCues {
            if cue.withdrawn {
                translationCues.removeValue(forKey: cue.id)
                continue
            }
            if let existing = translationCues[cue.id], existing.revision > cue.revision {
                continue
            }
            translationCues[cue.id] = cue
        }
    }

    /// Lane health is current state, not an edge: a live capture carries the
    /// whole group's health on every event, so a coalesced delta loses
    /// nothing. An empty payload during a live capture means the group has
    /// not reported any lane yet; a terminal capture state ends the group,
    /// and with it any claim about its lanes.
    private func reconcileLaneHealth(for event: NotebookCaptureEventDTO) {
        if event.captureState.isActive == false {
            livePresentation.updateFrame { frame in
                frame.utterances = []
                frame.laneHealth = [:]
                frame.laneTelemetry = [:]
            }
            return
        }
        guard event.laneHealth.isEmpty == false else { return }
        let nextLaneHealth = Dictionary(
            event.laneHealth.map { lane in
                (
                    lane.targetLanguage.map(normalizedLanguage)
                        ?? Self.canonicalLaneHealthKey,
                    lane.state
                )
            },
            uniquingKeysWith: { _, right in right }
        )
        let nextLaneTelemetry = Dictionary(
            event.laneHealth.map { lane in
                (
                    lane.targetLanguage.map(normalizedLanguage)
                        ?? Self.canonicalLaneHealthKey,
                    lane
                )
            },
            uniquingKeysWith: { _, right in right }
        )
        livePresentation.updateFrame { frame in
            frame.laneHealth = nextLaneHealth
            frame.laneTelemetry = nextLaneTelemetry
        }
    }

    /// Languages whose column is dark for good. The canvas uses this to stay
    /// silent instead of promising a translation that will never arrive.
    var failedTranslationLanguages: Set<String> {
        Set(
            laneHealth
                .filter { $0.key != Self.canonicalLaneHealthKey && $0.value == .failed }
                .keys
        )
    }

    /// Languages the operator should be told are degraded right now — dark
    /// for good, or mid-reconnect. Operator chrome only.
    var degradedTranslationLanguages: [String] {
        laneHealth
            .filter { $0.key != Self.canonicalLaneHealthKey && $0.value != .live }
            .keys
            .sorted()
    }

    /// The audience canvas's per-language cue view: present cues targeting
    /// `language`, in spoken order. Epoch and provider sequence are the
    /// authoritative order within one target stream. Capture timestamps are
    /// alignment evidence, not an ordering fallback: putting nil after every
    /// timestamp would let one old unanchored cue remain the track head
    /// forever.
    var presentedTranslationCueSnapshot: [NotebookCaptureTranslationCueDTO] {
        let cues = captureState.isActive && livePresentation.hasTranslationCueAuthority
            ? liveTranslationCues
            : translationCues
        return cues.values.sorted(by: Self.translationCueComesBefore)
    }

    func presentedTranslationCues(for language: String) -> [NotebookCaptureTranslationCueDTO] {
        let normalized = normalizedLanguage(language)
        return presentedTranslationCueSnapshot
            .filter { normalizedLanguage($0.targetLanguage) == normalized }
    }

    private static func translationCueComesBefore(
        _ left: NotebookCaptureTranslationCueDTO,
        _ right: NotebookCaptureTranslationCueDTO
    ) -> Bool {
        if left.groupEpoch != right.groupEpoch {
            return left.groupEpoch < right.groupEpoch
        }
        if left.providerSequence != right.providerSequence {
            return left.providerSequence < right.providerSequence
        }
        let leftStart = left.sourceStartMs ?? 0
        let rightStart = right.sourceStartMs ?? 0
        if leftStart != rightStart {
            return leftStart < rightStart
        }
        return left.id < right.id
    }

    private func reconcileUtterances(for event: NotebookCaptureEventDTO) {
        if event.isFullSnapshot {
            cancelUtteranceGapRepair()
            replaceUtterances(with: event.utterances)
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
        //
        // Withdrawal is part of the delta: a provider replacement can retire a
        // speculative row outright, and until that had a delta shape the only
        // way to say so was a whole-session resend on the publication path.
        // Rust guarantees a sequence is never in both lists — a withdrawal
        // that leaves a translation-only shell behind sends the shell as an
        // upsert — so the two can be applied in either order.
        removeUtterances(sequences: event.removedSequences)
        merge(event.utterances)
        lastAppliedEventRevision = event.eventRevision

        if var repair = utteranceGapRepair,
           repair.sessionId == event.sessionId {
            // The Rust snapshot carries the exact callback revision it covers.
            // Keep later deltas so the snapshot can be installed and advanced
            // to the live edge without requiring callbacks to go quiet.
            repair.observe(event)
            utteranceGapRepair = repair
            return
        }

        guard hasGap else { return }
        beginUtteranceGapRepair(with: event)
    }

    private func beginUtteranceGapRepair(with event: NotebookCaptureEventDTO) {
        guard utteranceGapRepair == nil else { return }
        var repair = UtteranceGapRepair(
            id: UUID(),
            sessionId: event.sessionId,
            generation: acceptedCallbackGeneration,
            targetEventRevision: event.eventRevision,
            bufferedDeltas: [:]
        )
        repair.observe(event)
        utteranceGapRepair = repair
        utteranceGapRepairTask = Task { @MainActor [weak self] in
            await self?.runUtteranceGapRepair(id: repair.id)
        }
    }

    private func runUtteranceGapRepair(id: UUID) async {
        var retryDelayNanoseconds: UInt64 = 20_000_000
        let maximumRetryDelayNanoseconds: UInt64 = 1_000_000_000
        while let repair = currentUtteranceGapRepair(id: id) {
            let requestedTargetEventRevision = repair.targetEventRevision
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

            // Active Rust snapshots are stamped, under the callback mailbox
            // lock, with the highest callback revision they cover. Revision
            // zero is retained as a compatibility fallback for an older core:
            // the snapshot read still happened after the repair request and
            // therefore covers its request-time target.
            let checkpointRevision = snapshot.eventRevision == 0
                ? requestedTargetEventRevision
                : snapshot.eventRevision
            let replayDeltas = current.bufferedDeltas.values
                .filter { $0.eventRevision > checkpointRevision }
                .sorted { $0.eventRevision < $1.eventRevision }

            // Install the checkpoint even if callbacks continued during the
            // read. Later buffered deltas are replayed below, so a deletion in
            // the snapshot cannot resurrect stale local data and the repair no
            // longer depends on finding a quiet interval.
            var repairedUtterances = rebuiltUtteranceSnapshot(from: snapshot.utterances)
            for delta in replayDeltas {
                let preparedUpdates = prepareUtteranceUpdates(delta.utterances)
                for update in preparedUpdates {
                    Self.upsertOrderedUtterance(update, into: &repairedUtterances)
                }
            }
            utterances = repairedUtterances
            refreshRecentTranscriptPresentation()
            // A coalesced callback can omit the Final delta that opened this
            // repair. Installing the authoritative checkpoint must itself
            // restore the projector wake; waiting for another provider event
            // would strand a quiet final at the end of a session.
            projectRealtimeIfPending(sessionId: current.sessionId)
            reconcileTranslationCues(for: snapshot)
            reconcileLaneHealth(for: snapshot)
            for delta in replayDeltas {
                reconcileTranslationCues(for: delta)
                reconcileLaneHealth(for: delta)
            }

            let replayedMaximumRevision = replayDeltas.last?.eventRevision
                ?? checkpointRevision
            lastAppliedEventRevision = max(
                lastAppliedEventRevision ?? 0,
                max(checkpointRevision, replayedMaximumRevision)
            )

            var continuousThroughRevision = checkpointRevision
            for delta in replayDeltas {
                guard continuousThroughRevision < UInt64.max else { break }
                let expectedRevision = continuousThroughRevision + 1
                guard delta.eventRevision == expectedRevision else { break }
                continuousThroughRevision = delta.eventRevision
            }

            if continuousThroughRevision >= current.targetEventRevision {
                utteranceGapRepair = nil
                utteranceGapRepairTask = nil
                return
            }

            // A second callback coalescing gap exists after this checkpoint.
            // Keep only deltas the snapshot did not cover and fetch a newer
            // checkpoint immediately. Each successful read advances coverage,
            // even while the provider continues producing events.
            var next = current
            next.bufferedDeltas = current.bufferedDeltas.filter {
                $0.key > checkpointRevision
            }
            utteranceGapRepair = next
            retryDelayNanoseconds = 20_000_000
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
        gate: NotebookCaptureAudioPushGate,
        inputDevice: AudioInputDevice? = nil
    ) throws {
        guard audioToken == nil else { throw CaptureError.alreadySubscribed }
        guard let inputDevice = inputDevice ?? audioSource.preparedInputDevice else {
            throw AudioInputDeviceError.noInputDevice
        }
        let subscription = try audioSource.subscribe(
            inputDevice: inputDevice,
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
        audioToken = subscription
        activeAudioInputDevice = inputDevice
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
        stopRecoveryRequired = true
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
        cachedLastIdentifiedSourceLanguage = nil
        translationCues = [:]
        committedLaneOverrideBarriers.removeAll(keepingCapacity: true)
        cancelLivePreviewCoalescing()
        livePresentation.resetFrame()
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
        stopRecoveryRequired = false
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
        stopRecoveryRequired = false
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
