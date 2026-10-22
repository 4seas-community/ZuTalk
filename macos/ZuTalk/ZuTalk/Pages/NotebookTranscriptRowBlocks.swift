import SwiftUI

/// The transcript list, one view per `TranscriptChunk`.
///
/// A lazy stack keeps every row it has ever built, and following the live
/// edge builds them all, so a list of single rows made SwiftUI revisit the
/// whole recording on every frame: hundreds of children, each compared and
/// re-tracked although nothing about it had changed. It got slower minute by
/// minute until the page fell behind the speech.
///
/// One block per chunk, compared by the chunk's identity and version, makes
/// a frame cost the chunks that moved — in practice the last one — however
/// long the recording is.
enum NotebookTranscriptRowBlocks {
    /// Scroll target for the block holding a row; ids inside a block are
    /// only reachable once SwiftUI has built it.
    static func anchor(_ chunkID: UInt64) -> String {
        "notebook-transcript-block:\(chunkID)"
    }

    static func anchor(ofSequence sequence: UInt64) -> String {
        anchor(TranscriptChunk.chunkID(of: sequence))
    }
}

struct NotebookTranscriptRowBlock<Row: Equatable & Identifiable>: Identifiable, Equatable {
    let id: UInt64
    /// Bumped whenever the block's rows are rebuilt.
    let version: UInt64
    let rows: [Row]

    static func == (left: Self, right: Self) -> Bool {
        left.id == right.id && left.version == right.version
    }
}

/// Everything one row of the column transcript draws.
struct NotebookMultilingualRowModel: Equatable, Identifiable {
    let utterance: NotebookCaptureUtteranceDTO
    let projection: NotebookCaptureLaneProjection
    let speakerDisplayName: String?
    let leadingGaps: [NotebookTranscriptGapDTO]
    /// The projection watermark as far as this row can tell it apart: lanes
    /// are editable once it reaches their own revision, so beyond the row's
    /// highest final lane it changes nothing and is held there.
    let appliedRevision: UInt64

    var id: String { utterance.id }
}

/// Everything one row of the source timeline draws.
struct NotebookTranscriptionRowModel: Equatable, Identifiable {
    let utterance: NotebookCaptureUtteranceDTO
    let speakerDisplayName: String?
    let leadingGaps: [NotebookTranscriptGapDTO]
    let isEditable: Bool

    var id: String { utterance.id }
}

/// The calls a row makes back into its run view.
struct NotebookTranscriptRowActions {
    let manageSpeaker: (NotebookCaptureUtteranceDTO) -> Void
    let replace: (_ utteranceId: String, _ language: String, _ text: String) async throws -> Void
    let editingChanged: (BilingualLaneEditTarget, Bool) -> Void
}

/// What a transcript's rows are drawn against, besides the rows.
struct NotebookTranscriptRowContext {
    let languages: [String]
    let progress: NotebookTranslationProgress
    let continuationCues: NotebookTranslationCueIndex
    let appliedRevision: UInt64
    let isLaneEditingEnabled: Bool
    let gaps: [NotebookTranscriptGapDTO]
    let speakerNamesRevision: UInt64
    let speakerName: (NotebookCaptureUtteranceDTO) -> String?
}

/// Builds the blocks a transcript draws, doing per-row work only for chunks
/// whose rows or whose relevant context changed.
///
/// Each block remembers the slice of context it was built under, narrowed to
/// what can change its rows: translation progress and the projection
/// watermark are clamped to the chunk's own extent, so once the live edge has
/// moved past a chunk neither can change it again, and the continuation index
/// only matters to a chunk that has an empty cell.
@MainActor
final class NotebookTranscriptRowCache {
    private struct MultilingualKey: Equatable {
        let version: UInt64
        let languages: [String]
        let progress: NotebookTranslationProgress
        let appliedRevision: UInt64
        let previousSpeaker: String??
        let speakerNamesRevision: UInt64
        let gaps: [NotebookTranscriptGapDTO]
    }

    private struct MultilingualEntry {
        let key: MultilingualKey
        let usesContinuations: Bool
        let continuationToken: UInt64
        let block: NotebookTranscriptRowBlock<NotebookMultilingualRowModel>
    }

    private struct TranscriptionKey: Equatable {
        let version: UInt64
        let isLaneEditingEnabled: Bool
        let appliedRevision: UInt64
        let previousSpeaker: String??
        let speakerNamesRevision: UInt64
        let gaps: [NotebookTranscriptGapDTO]
    }

    private struct TranscriptionEntry {
        let key: TranscriptionKey
        let block: NotebookTranscriptRowBlock<NotebookTranscriptionRowModel>
    }

    private struct ProjectionEntry {
        let utterance: NotebookCaptureUtteranceDTO
        let languages: [String]
        let projection: NotebookCaptureLaneProjection
    }

    private var multilingual: [UInt64: MultilingualEntry] = [:]
    private var transcription: [UInt64: TranscriptionEntry] = [:]
    private var projections: [String: ProjectionEntry] = [:]
    private var arrayChunks: [TranscriptChunk] = []
    private var nextVersion: UInt64 = 1

    private func takeVersion() -> UInt64 {
        defer { nextVersion &+= 1 }
        return nextVersion
    }

    // MARK: Chunks for a plain row array

    /// Chunks for a finished recording's rows, reusing every chunk whose rows
    /// came out the same as last time.
    func chunks(for unordered: [NotebookCaptureUtteranceDTO]) -> [TranscriptChunk] {
        // Stored rows come ordered by sequence; anything else is put in order
        // first so a chunk is never split into two with the same identity.
        let isOrdered = zip(unordered, unordered.dropFirst()).allSatisfy { $0.sequence <= $1.sequence }
        let rows = isOrdered ? unordered : unordered.sorted { $0.sequence < $1.sequence }
        let previous = Dictionary(uniqueKeysWithValues: arrayChunks.map { ($0.id, $0) })
        var result: [TranscriptChunk] = []
        var start = 0
        while start < rows.count {
            let chunkID = TranscriptChunk.chunkID(of: rows[start].sequence)
            var end = start
            while end < rows.count, TranscriptChunk.chunkID(of: rows[end].sequence) == chunkID {
                end += 1
            }
            let slice = rows[start..<end]
            if let reused = previous[chunkID], reused.rows.elementsEqual(slice) {
                result.append(reused)
            } else {
                result.append(TranscriptChunk(id: chunkID, version: takeVersion(), rows: Array(slice)))
            }
            start = end
        }
        arrayChunks = result
        return result
    }

    // MARK: Column transcript

    func multilingualBlocks(
        chunks: [TranscriptChunk],
        context: NotebookTranscriptRowContext
    ) -> (blocks: [NotebookTranscriptRowBlock<NotebookMultilingualRowModel>],
          trailingGaps: [NotebookTranscriptGapDTO]) {
        let anchored = Self.anchorGaps(context.gaps, in: chunks) { _ in true }
        var blocks: [NotebookTranscriptRowBlock<NotebookMultilingualRowModel>] = []
        blocks.reserveCapacity(chunks.count)
        var live: Set<UInt64> = []
        var previousSpeaker: String?? = nil
        for chunk in chunks {
            live.insert(chunk.id)
            let key = MultilingualKey(
                version: chunk.version,
                languages: context.languages,
                progress: Self.clamp(context.progress, to: chunk),
                appliedRevision: min(context.appliedRevision, chunk.maxFinalLaneProjectionRevision),
                previousSpeaker: previousSpeaker,
                speakerNamesRevision: context.speakerNamesRevision,
                gaps: anchored.byChunk[chunk.id] ?? []
            )
            if let entry = multilingual[chunk.id], entry.key == key,
               entry.usesContinuations == false
                || context.continuationCues.agreesForRows(
                    endingBy: chunk.maxSourceEndMs ?? 0,
                    withIndex: entry.continuationToken
                ) {
                // Carry the entry forward to this index, so the next one is
                // compared against what this chunk now agrees with.
                multilingual[chunk.id] = MultilingualEntry(
                    key: entry.key,
                    usesContinuations: entry.usesContinuations,
                    continuationToken: context.continuationCues.token,
                    block: entry.block
                )
                blocks.append(entry.block)
            } else {
                let entry = buildMultilingual(chunk, key: key, context: context, leading: anchored.leading)
                multilingual[chunk.id] = entry
                blocks.append(entry.block)
            }
            if let last = chunk.rows.last { previousSpeaker = .some(last.sessionSpeakerId) }
        }
        if multilingual.count > live.count {
            multilingual = multilingual.filter { live.contains($0.key) }
            let rowIDs = Set(chunks.lazy.flatMap(\.rows).map(\.id))
            projections = projections.filter { rowIDs.contains($0.key) }
        }
        return (blocks, anchored.trailing)
    }

    private func buildMultilingual(
        _ chunk: TranscriptChunk,
        key: MultilingualKey,
        context: NotebookTranscriptRowContext,
        leading: [String: [NotebookTranscriptGapDTO]]
    ) -> MultilingualEntry {
        var usesContinuations = false
        var previous = key.previousSpeaker
        let models = chunk.rows.map { utterance -> NotebookMultilingualRowModel in
            let waited = baseProjection(for: utterance, languages: context.languages)
                .resolvingWaits(context.progress, rowEndMs: utterance.sourceEndMs)
            if waited.lanes.contains(where: { $0.text == nil && $0.missingLaneState == .unavailable }) {
                usesContinuations = true
            }
            let startsTurn = previous == nil || previous! != utterance.sessionSpeakerId
            previous = .some(utterance.sessionSpeakerId)
            return NotebookMultilingualRowModel(
                utterance: utterance,
                projection: waited.markingContinuations(
                    rowStartMs: utterance.sourceStartMs,
                    rowEndMs: utterance.sourceEndMs,
                    cues: context.continuationCues
                ),
                speakerDisplayName: startsTurn ? context.speakerName(utterance) : nil,
                leadingGaps: leading[utterance.id] ?? [],
                appliedRevision: min(context.appliedRevision, utterance.highestFinalLaneProjectionRevision)
            )
        }
        return MultilingualEntry(
            key: key,
            usesContinuations: usesContinuations,
            continuationToken: context.continuationCues.token,
            block: NotebookTranscriptRowBlock(id: chunk.id, version: takeVersion(), rows: models)
        )
    }

    // MARK: Source timeline

    func transcriptionBlocks(
        chunks: [TranscriptChunk],
        context: NotebookTranscriptRowContext
    ) -> (blocks: [NotebookTranscriptRowBlock<NotebookTranscriptionRowModel>],
          trailingGaps: [NotebookTranscriptGapDTO]) {
        let anchored = Self.anchorGaps(context.gaps, in: chunks) { $0.hasSourceLane }
        var blocks: [NotebookTranscriptRowBlock<NotebookTranscriptionRowModel>] = []
        var live: Set<UInt64> = []
        var previousSpeaker: String?? = nil
        for chunk in chunks {
            live.insert(chunk.id)
            let key = TranscriptionKey(
                version: chunk.version,
                isLaneEditingEnabled: context.isLaneEditingEnabled,
                appliedRevision: min(context.appliedRevision, chunk.maxFinalLaneProjectionRevision),
                previousSpeaker: previousSpeaker,
                speakerNamesRevision: context.speakerNamesRevision,
                gaps: anchored.byChunk[chunk.id] ?? []
            )
            let entry: TranscriptionEntry
            if let cached = transcription[chunk.id], cached.key == key {
                entry = cached
            } else {
                entry = buildTranscription(chunk, key: key, context: context, leading: anchored.leading)
                transcription[chunk.id] = entry
            }
            if entry.block.rows.isEmpty == false { blocks.append(entry.block) }
            if let last = chunk.rows.last(where: \.hasSourceLane) {
                previousSpeaker = .some(last.sessionSpeakerId)
            }
        }
        if transcription.count > live.count {
            transcription = transcription.filter { live.contains($0.key) }
        }
        return (blocks, anchored.trailing)
    }

    private func buildTranscription(
        _ chunk: TranscriptChunk,
        key: TranscriptionKey,
        context: NotebookTranscriptRowContext,
        leading: [String: [NotebookTranscriptGapDTO]]
    ) -> TranscriptionEntry {
        var previous = key.previousSpeaker
        let models = chunk.rows.filter(\.hasSourceLane).map { utterance -> NotebookTranscriptionRowModel in
            let startsTurn = previous == nil || previous! != utterance.sessionSpeakerId
            previous = .some(utterance.sessionSpeakerId)
            return NotebookTranscriptionRowModel(
                utterance: utterance,
                speakerDisplayName: startsTurn ? context.speakerName(utterance) : nil,
                leadingGaps: leading[utterance.id] ?? [],
                isEditable: context.isLaneEditingEnabled && utterance.isLoroEditableLane(
                    language: utterance.sourceLanguage,
                    appliedRevision: context.appliedRevision
                )
            )
        }
        return TranscriptionEntry(
            key: key,
            block: NotebookTranscriptRowBlock(id: chunk.id, version: takeVersion(), rows: models)
        )
    }

    // MARK: Shared

    private func baseProjection(
        for utterance: NotebookCaptureUtteranceDTO,
        languages: [String]
    ) -> NotebookCaptureLaneProjection {
        if let entry = projections[utterance.id],
           entry.languages == languages,
           entry.utterance == utterance {
            return entry.projection
        }
        let projection = NotebookCaptureHistoryPolicy.laneProjection(
            for: utterance,
            selectedLanguages: languages,
            commonCaptionLanguage: nil
        )
        projections[utterance.id] = ProjectionEntry(
            utterance: utterance,
            languages: languages,
            projection: projection
        )
        return projection
    }

    /// Progress as far as a chunk can tell it apart: a wait resolves once its
    /// lane has settled `bindingGraceMs` past the row's end, so beyond the
    /// chunk's last end plus that grace, further progress changes nothing.
    static func clamp(
        _ progress: NotebookTranslationProgress,
        to chunk: TranscriptChunk
    ) -> NotebookTranslationProgress {
        guard progress.isEmpty == false else { return progress }
        let ceiling = (chunk.maxSourceEndMs ?? 0) + NotebookTranslationProgress.bindingGraceMs
        return NotebookTranslationProgress(
            settledThroughMs: progress.settledThroughMs.mapValues { min($0, ceiling) },
            stoppedLanguages: progress.stoppedLanguages
        )
    }

    /// `NotebookTranscriptGapPresentation.anchoredGaps` over chunks: a gap
    /// anchors before the first listed row that begins at or after its start,
    /// and chunks that cannot hold that row are skipped whole.
    static func anchorGaps(
        _ gaps: [NotebookTranscriptGapDTO],
        in chunks: [TranscriptChunk],
        listing isListed: (NotebookCaptureUtteranceDTO) -> Bool
    ) -> (leading: [String: [NotebookTranscriptGapDTO]],
          byChunk: [UInt64: [NotebookTranscriptGapDTO]],
          trailing: [NotebookTranscriptGapDTO]) {
        var leading: [String: [NotebookTranscriptGapDTO]] = [:]
        var byChunk: [UInt64: [NotebookTranscriptGapDTO]] = [:]
        var trailing: [NotebookTranscriptGapDTO] = []
        for gap in gaps where gap.isRepaired == false {
            var anchored = false
            for chunk in chunks {
                guard let latest = chunk.maxSourceStartMs, latest >= gap.startMs else { continue }
                if let row = chunk.rows.first(where: {
                    isListed($0) && ($0.sourceStartMs.map { $0 >= gap.startMs } ?? false)
                }) {
                    leading[row.id, default: []].append(gap)
                    byChunk[chunk.id, default: []].append(gap)
                    anchored = true
                    break
                }
            }
            if anchored == false { trailing.append(gap) }
        }
        return (leading, byChunk, trailing)
    }
}

struct NotebookMultilingualRowBlock: View, Equatable {
    let block: NotebookTranscriptRowBlock<NotebookMultilingualRowModel>
    let isLaneEditingEnabled: Bool
    let actions: NotebookTranscriptRowActions

    nonisolated static func == (left: Self, right: Self) -> Bool {
        left.block == right.block && left.isLaneEditingEnabled == right.isLaneEditingEnabled
    }

    var body: some View {
        // One lazy child per block: a bare ForEach would be flattened into
        // the enclosing stack, and its rows would be children again.
        VStack(spacing: 0) {
            ForEach(block.rows) { row in
                ForEach(row.leadingGaps) { gap in
                    NotebookTranscriptGapDivider(gap: gap)
                }
                MultilingualUtteranceRow(
                    utterance: row.utterance,
                    projection: row.projection,
                    speakerDisplayName: row.speakerDisplayName,
                    onManageSpeaker: { actions.manageSpeaker(row.utterance) },
                    isLaneEditingEnabled: isLaneEditingEnabled,
                    realtimeLoroAppliedRevision: row.appliedRevision,
                    onReplace: { language, text in
                        try await actions.replace(row.utterance.id, language, text)
                    },
                    onEditingChanged: actions.editingChanged
                )
                .id(row.utterance.id)
                Divider().background(Color.borderGhost.opacity(0.22))
            }
        }
    }
}

struct NotebookTranscriptionRowBlock: View, Equatable {
    let block: NotebookTranscriptRowBlock<NotebookTranscriptionRowModel>
    let actions: NotebookTranscriptRowActions

    nonisolated static func == (left: Self, right: Self) -> Bool {
        left.block == right.block
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(block.rows) { row in
                ForEach(row.leadingGaps) { gap in
                    NotebookTranscriptGapDivider(gap: gap)
                }
                TranscriptionUtteranceRow(
                    utterance: row.utterance,
                    speakerDisplayName: row.speakerDisplayName,
                    onManageSpeaker: { actions.manageSpeaker(row.utterance) },
                    isEditable: row.isEditable,
                    onReplace: { language, text in
                        try await actions.replace(row.utterance.id, language, text)
                    },
                    onEditingChanged: actions.editingChanged
                )
                .id(row.utterance.id)
                Divider().background(Color.borderGhost.opacity(0.22))
            }
        }
    }
}
