import AVFoundation
import Combine
import Foundation

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
        // Parsing inside the sort comparator used to construct two date
        // formatters for every comparison. SwiftUI called this path repeatedly
        // while live text arrived, turning a small catalog into a CPU and
        // allocation storm. Decorate once, sort the cached keys, then unwrap.
        let fractionalParser = ISO8601DateFormatter()
        fractionalParser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestampParser = ISO8601DateFormatter()
        timestampParser.formatOptions = [.withInternetDateTime]
        let keyedRuns = runs.map { run in
            (
                run: run,
                parsedDate: parsedTimestamp(
                    run.createdAt,
                    fractionalParser: fractionalParser,
                    timestampParser: timestampParser
                )
            )
        }

        return keyedRuns.sorted { lhs, rhs in
            if let lhsDate = lhs.parsedDate,
               let rhsDate = rhs.parsedDate,
               lhsDate != rhsDate {
                return lhsDate < rhsDate
            }
            if lhs.run.createdAt != rhs.run.createdAt,
               lhs.parsedDate == nil || rhs.parsedDate == nil {
                return lhs.run.createdAt < rhs.run.createdAt
            }
            return lhs.run.sessionId < rhs.run.sessionId
        }.map { $0.run }
    }

    static func defaultPresentation(
        for runs: [NotebookCaptureHistoryRunDTO]
    ) -> NotebookTranscriptPresentationMode {
        defaultPresentation(forOrderedRuns: orderedRuns(runs))
    }

    static func defaultPresentation(
        forOrderedRuns runs: [NotebookCaptureHistoryRunDTO]
    ) -> NotebookTranscriptPresentationMode {
        guard let latest = runs.last,
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
        commonCaptionLanguage: String?,
        lastIdentifiedSourceLanguage: String? = nil
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
        //
        // `lastIdentifiedSourceLanguage` is a caller-supplied guess for when
        // the provider offers no hint at all. Only the audience canvas passes
        // it: there, a full-width row that snaps into a column a moment later
        // makes the layout jump under the room, so borrowing a column reads
        // better than spilling. The durable transcript passes nothing and
        // keeps the stricter rule, because a stored row must not claim a
        // language identity the provider never established.
        if utterance.hasSourceLane,
           source == nil || source == "und",
           utterance.sourceText.isEmpty == false,
           let placement = normalizedLanguage(utterance.provisionalSourceLanguage)
               .flatMap({ $0 == "und" ? nil : $0 })
               .flatMap({ languages.contains($0) ? $0 : nil })
               ?? normalizedLanguage(lastIdentifiedSourceLanguage)
                   .flatMap({ languages.contains($0) ? $0 : nil }),
           textsByLanguage[placement] == nil {
            textsByLanguage[placement] = utterance.sourceText
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

    /// Which audience column a source line joins. The same source rules as
    /// `laneProjection`, without materializing lanes: a committed identity
    /// goes to its own selected column; a pending identity borrows the
    /// provider hint, then the caller's last-identified fallback; an
    /// unselected known language joins no column and stays a full-width line.
    static func audienceSourcePlacement(
        for utterance: NotebookCaptureUtteranceDTO,
        selectedLanguages: [String],
        lastIdentifiedSourceLanguage: String?
    ) -> String? {
        guard utterance.hasSourceLane, utterance.sourceText.isEmpty == false else {
            return nil
        }
        let languages = orderedLanguages(selectedLanguages)
        if let source = normalizedLanguage(utterance.sourceLanguage), source != "und" {
            return languages.contains(source) ? source : nil
        }
        // The provider's provisional hint is an identification, not a guess.
        // If it names a language outside the selection, the honest answer is
        // "no column" — falling through to the previous speaker's language
        // would put demonstrably French words in the Chinese column, and a
        // confidently misfiled line is worse for the room than an unlabelled
        // one. Only a line with no identification at all borrows the last
        // identified language, and only if that language has a column.
        if let provisional = normalizedLanguage(utterance.provisionalSourceLanguage),
           provisional != "und" {
            return languages.contains(provisional) ? provisional : nil
        }
        return normalizedLanguage(lastIdentifiedSourceLanguage)
            .flatMap { languages.contains($0) ? $0 : nil }
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

    private static func parsedTimestamp(
        _ value: String,
        fractionalParser: ISO8601DateFormatter,
        timestampParser: ISO8601DateFormatter
    ) -> Date? {
        fractionalParser.date(from: value) ?? timestampParser.date(from: value)
    }
}

/// Notebook-scoped read model for every durable recording run. `focusSessionId`
/// belongs to the view and is deliberately absent from this query API, so
/// opening a historical session cannot hide its siblings.
enum NotebookCaptureTranscriptLoadState: Equatable {
    case unloaded
    case loading
    case loaded
    case failed(String)
}

@MainActor
final class NotebookCaptureHistoryStore: ObservableObject {
    @Published private(set) var runs: [NotebookCaptureHistoryRunDTO] = []
    @Published private(set) var loadedNotebookId: String?
    @Published private(set) var isLoading = false
    @Published private(set) var lastError: String?
    @Published private(set) var presentationByNotebook: [String: NotebookTranscriptPresentationMode] = [:]
    @Published private(set) var speakerParticipants: [SpeakerParticipantDTO] = []
    @Published private(set) var sessionSpeakersBySession: [String: [NotebookSessionSpeakerDTO]] = [:]
    @Published private(set) var transcriptLoadingSessionIds: Set<String> = []
    @Published private(set) var transcriptLoadErrors: [String: String] = [:]
    /// Recorded transcript gaps per session, refreshed with each hydrated
    /// transcript and on live remote-health transitions. A handful of small
    /// rows per session; reset with each catalog load.
    @Published private(set) var transcriptGapsBySession: [String: [NotebookTranscriptGapDTO]] = [:]

    private let client: NotebookCaptureClienting
    private var laneMutationsInFlight: Set<NotebookCaptureLaneMutationKey> = []
    private var loadedTranscriptSessionIds: Set<String> = []
    private var transcriptLoadRequestIds: [String: UUID] = [:]
    private var catalogLoadRequestId: UUID?

    init(client: NotebookCaptureClienting? = nil) {
        self.client = client ?? RustNotebookCaptureClient()
    }

    func load(notebookId: String) async {
        guard notebookId.isEmpty == false else { return }
        let requestId = UUID()
        catalogLoadRequestId = requestId
        // A catalog refresh is also a content invalidation boundary. Do not
        // carry a selected transcript across it without re-reading SQLite.
        transcriptLoadRequestIds = [:]
        transcriptLoadingSessionIds = []
        loadedTranscriptSessionIds = []
        transcriptLoadErrors = [:]
        transcriptGapsBySession = [:]
        if loadedNotebookId != notebookId {
            runs = []
            sessionSpeakersBySession = [:]
            loadedNotebookId = notebookId
        }
        isLoading = true
        defer {
            if catalogLoadRequestId == requestId {
                catalogLoadRequestId = nil
                isLoading = false
            }
        }

        do {
            let summaries = NotebookCaptureHistoryPolicy.orderedRuns(
                try await client.loadNotebookCaptureHistorySummaries(notebookId: notebookId)
            )
            guard Task.isCancelled == false,
                  catalogLoadRequestId == requestId,
                  loadedNotebookId == notebookId else { return }
            var eagerLoadedSessionIds: Set<String> = []
            runs = summaries.map { summary in
                if summary.utterances.isEmpty == false {
                    eagerLoadedSessionIds.insert(summary.sessionId)
                }
                return summary
            }
            loadedTranscriptSessionIds = eagerLoadedSessionIds
            if presentationByNotebook[notebookId] == nil {
                var nextPresentation = presentationByNotebook
                nextPresentation[notebookId] = NotebookCaptureHistoryPolicy.defaultPresentation(
                    forOrderedRuns: runs
                )
                presentationByNotebook = nextPresentation
            }
            lastError = nil
            // The rail only needs summary metadata. Session speaker labels are
            // hydrated with the one transcript the user opens, avoiding an
            // N+1 chain of synchronous FFI reads on the MainActor.
            refreshSpeakerDirectory(for: runs.map(\.sessionId), hydrateSessions: false)
            // Lightweight/platform clients may use the protocol fallback and
            // return already-hydrated fixtures. Preserve their historical
            // speaker behavior without penalizing the production summary path.
            for sessionId in eagerLoadedSessionIds {
                refreshSessionSpeakers(sessionId: sessionId)
            }
        } catch {
            guard Task.isCancelled == false,
                  catalogLoadRequestId == requestId,
                  loadedNotebookId == notebookId else { return }
            runs = []
            loadedTranscriptSessionIds = []
            transcriptLoadingSessionIds = []
            transcriptLoadErrors = [:]
            transcriptLoadRequestIds = [:]
            lastError = error.localizedDescription
        }
    }

    func transcriptGaps(sessionId: String) -> [NotebookTranscriptGapDTO] {
        transcriptGapsBySession[sessionId] ?? []
    }

    /// Re-reads one session's recorded gaps. Failures keep the previous
    /// value: dividers are advisory presentation, not worth an error surface.
    func refreshTranscriptGaps(sessionId: String) async {
        guard sessionId.isEmpty == false,
              let gaps = try? await client.loadNotebookSessionTranscriptGaps(
                  sessionId: sessionId
              )
        else { return }
        if transcriptGapsBySession[sessionId] != gaps {
            var next = transcriptGapsBySession
            next[sessionId] = gaps
            transcriptGapsBySession = next
        }
    }

    func transcriptLoadState(sessionId: String) -> NotebookCaptureTranscriptLoadState {
        if loadedTranscriptSessionIds.contains(sessionId) {
            return .loaded
        }
        if transcriptLoadingSessionIds.contains(sessionId) {
            return .loading
        }
        if let error = transcriptLoadErrors[sessionId] {
            return .failed(error)
        }
        return .unloaded
    }

    /// Hydrates only the recording the user opened. The Notebook catalog stays
    /// lightweight, so ten long recordings do not cross FFI or enter SwiftUI's
    /// view tree together.
    func loadTranscript(sessionId: String) async {
        guard sessionId.isEmpty == false,
              let notebookId = loadedNotebookId,
              loadedTranscriptSessionIds.contains(sessionId) == false,
              transcriptLoadingSessionIds.contains(sessionId) == false,
              runs.contains(where: { $0.sessionId == sessionId })
        else { return }

        let requestId = UUID()
        transcriptLoadRequestIds[sessionId] = requestId
        var loading = transcriptLoadingSessionIds
        loading.insert(sessionId)
        transcriptLoadingSessionIds = loading
        var errors = transcriptLoadErrors
        errors.removeValue(forKey: sessionId)
        transcriptLoadErrors = errors
        defer {
            if transcriptLoadRequestIds[sessionId] == requestId {
                transcriptLoadRequestIds.removeValue(forKey: sessionId)
                var nextLoading = transcriptLoadingSessionIds
                nextLoading.remove(sessionId)
                transcriptLoadingSessionIds = nextLoading
            }
        }

        do {
            let utterances = try await client.loadNotebookCaptureHistoryUtterances(
                notebookId: notebookId,
                sessionId: sessionId
            )
                .filter { $0.sessionId == sessionId }
                .sorted { $0.sequence < $1.sequence }
            guard Task.isCancelled == false,
                  loadedNotebookId == notebookId,
                  transcriptLoadRequestIds[sessionId] == requestId,
                  let index = runs.firstIndex(where: { $0.sessionId == sessionId }) else {
                return
            }
            var nextRuns = runs.map { run in
                run.sessionId == sessionId ? run : run.replacingUtterances([])
            }
            nextRuns[index] = runs[index].replacingUtterances(utterances)
            loadedTranscriptSessionIds = [sessionId]
            runs = nextRuns
            refreshSessionSpeakers(sessionId: sessionId)
            await refreshTranscriptGaps(sessionId: sessionId)
        } catch {
            guard loadedNotebookId == notebookId,
                  transcriptLoadRequestIds[sessionId] == requestId else { return }
            var nextErrors = transcriptLoadErrors
            nextErrors[sessionId] = error.localizedDescription
            transcriptLoadErrors = nextErrors
        }
    }

    /// Keeps the transcript cache bounded to the run currently selected in the
    /// rail and invalidates any slower request for a run the user left behind.
    func retainOnlyTranscript(sessionId: String?) {
        let retainedIds = sessionId.map { Set([$0]) } ?? []
        transcriptLoadRequestIds = transcriptLoadRequestIds.filter {
            retainedIds.contains($0.key)
        }
        transcriptLoadingSessionIds.formIntersection(retainedIds)
        loadedTranscriptSessionIds.formIntersection(retainedIds)
        let nextRuns = runs.map { run in
            retainedIds.contains(run.sessionId) ? run : run.replacingUtterances([])
        }
        if nextRuns != runs {
            runs = nextRuns
        }
    }

    func presentationMode(for notebookId: String) -> NotebookTranscriptPresentationMode {
        // `load` computes the default once from the ordered summary catalog.
        // Never derive it from a live overlay during SwiftUI body evaluation.
        presentationByNotebook[notebookId] ?? .sourceTimeline
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
        Task { await load(notebookId: loadedNotebookId) }
    }

    private func refreshSpeakerDirectory(
        for sessionIds: [String],
        hydrateSessions: Bool = true
    ) {
        refreshSpeakerParticipants()
        let wantedSessionIds = Set(sessionIds)
        sessionSpeakersBySession = sessionSpeakersBySession.filter {
            wantedSessionIds.contains($0.key)
        }
        if hydrateSessions {
            for sessionId in wantedSessionIds {
                refreshSessionSpeakers(sessionId: sessionId)
            }
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

