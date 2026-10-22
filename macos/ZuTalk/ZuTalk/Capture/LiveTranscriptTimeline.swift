import Combine
import Foundation

/// A run of transcript rows: every row whose sequence falls in one fixed
/// window of `size` sequences.
///
/// Rows only ever change near the live edge, so a recording's transcript is a
/// long frozen prefix and a short moving tail. Cutting it by sequence makes
/// that visible to everything downstream: a chunk keeps its identity and its
/// `version` for as long as none of its rows change, and comparing two chunks
/// is comparing two integers. Every consumer — the page, the subtitle window,
/// derived scans — keys its own work on chunks and so redoes only what moved.
struct TranscriptChunk: Identifiable, Equatable {
    static let size: UInt64 = 16

    /// `sequence / size`; also the chunk's order.
    let id: UInt64
    /// Bumped whenever the chunk's rows change. Unique across chunks of one
    /// timeline, so `(id, version)` names one exact set of rows.
    let version: UInt64
    let rows: [NotebookCaptureUtteranceDTO]
    /// Facts consumers need about the chunk as a whole, computed once here
    /// instead of rescanned by each of them on every frame.
    let maxSourceStartMs: UInt64?
    let maxSourceEndMs: UInt64?
    let maxFinalLaneProjectionRevision: UInt64
    /// The lowest revision at which any lane of these rows becomes editable;
    /// `nil` when none has a final lane yet.
    let minFinalLaneProjectionRevision: UInt64?

    init(id: UInt64, version: UInt64, rows: [NotebookCaptureUtteranceDTO]) {
        self.id = id
        self.version = version
        self.rows = rows
        maxSourceStartMs = rows.compactMap(\.sourceStartMs).max()
        maxSourceEndMs = rows.compactMap(\.sourceEndMs).max()
        maxFinalLaneProjectionRevision = rows.map(\.highestFinalLaneProjectionRevision).max() ?? 0
        minFinalLaneProjectionRevision = rows.compactMap(\.lowestFinalLaneProjectionRevision).min()
    }

    /// Whether any lane of these rows is editable at this watermark.
    func hasEditableLane(appliedRevision: UInt64) -> Bool {
        minFinalLaneProjectionRevision.map { $0 <= appliedRevision } ?? false
    }

    static func == (left: Self, right: Self) -> Bool {
        left.id == right.id && left.version == right.version
    }

    static func chunkID(of sequence: UInt64) -> UInt64 { sequence / size }
}

/// What the live transcript shows at one moment: the stored rows with the
/// provider's speculative tail laid over them, as chunks.
struct LiveTranscriptFrame: Equatable {
    var sessionId: String?
    var chunks: [TranscriptChunk]
    /// Bumped on every published change; the frame compares by it alone.
    var revision: UInt64
    /// Whether any row is stored, not only the speculative tail: what can be
    /// copied, exported or edited.
    var hasStoredRows = false

    static let empty = Self(sessionId: nil, chunks: [], revision: 0)

    static func == (left: Self, right: Self) -> Bool {
        left.revision == right.revision && left.sessionId == right.sessionId
    }

    var isEmpty: Bool { chunks.allSatisfy { $0.rows.isEmpty } }

    var rowCount: Int { chunks.reduce(0) { $0 + $1.rows.count } }

    /// The last `limit` rows, read from the end without touching the rest.
    func tail(limit: Int) -> [NotebookCaptureUtteranceDTO] {
        guard limit > 0 else { return [] }
        var result: [NotebookCaptureUtteranceDTO] = []
        result.reserveCapacity(limit)
        for chunk in chunks.reversed() {
            for row in chunk.rows.reversed() {
                result.append(row)
                if result.count == limit { return result.reversed() }
            }
        }
        return result.reversed()
    }

    /// Every row in order. Linear in the recording: for user actions and
    /// tests, never for anything that runs per frame.
    var rows: [NotebookCaptureUtteranceDTO] { chunks.flatMap(\.rows) }
}

/// Publishes the live transcript as chunked frames at a bounded rate.
///
/// The capture store applies every provider event the moment it arrives;
/// that is bookkeeping, and stays cheap. What used to be expensive was that
/// each event also republished the whole transcript and every observer
/// re-read all of it. Here a change only marks chunks dirty. At most once per
/// `interval` the dirty chunks are rebuilt and one frame is published, so a
/// burst of events costs one frame, and a main thread that falls behind skips
/// frames instead of queueing them: the next frame is always the newest
/// state, and lag cannot accumulate.
@MainActor
final class LiveTranscriptTimeline: ObservableObject {
    static let defaultInterval: TimeInterval = 0.1

    @Published private(set) var frame = LiveTranscriptFrame.empty

    /// Read at frame time, so marking dirty never copies anything.
    struct Source {
        var sessionId: () -> String?
        /// Stored rows, ordered by sequence.
        var durable: () -> [NotebookCaptureUtteranceDTO]
        /// The speculative tail; a stored row wins over a preview row with
        /// the same sequence.
        var preview: () -> [NotebookCaptureUtteranceDTO]
    }

    private let interval: TimeInterval
    private var source: Source?
    private var durableChunks: [UInt64: TranscriptChunk] = [:]
    private var publishedChunks: [UInt64: TranscriptChunk] = [:]
    private var previewChunkIDs: Set<UInt64> = []
    /// `nil` means every chunk: a snapshot, a reset, or an edit whose extent
    /// was not reported.
    private var dirtyDurable: Set<UInt64>? = []
    private var previewDirty = false
    private var cuesDirty = false
    private var nextVersion: UInt64 = 1
    private var revision: UInt64 = 0
    private var sessionId: String?
    private var scheduled: Task<Void, Never>?
    private var lastPublishedAt: TimeInterval = 0

    init(interval: TimeInterval = LiveTranscriptTimeline.defaultInterval) {
        self.interval = max(0, interval)
    }

    func attach(_ source: Source) {
        self.source = source
        noteDurableChanged(sequences: nil)
    }

    /// Rows with these sequences were added, replaced or removed; `nil` when
    /// the change may touch any row.
    func noteDurableChanged(sequences: [UInt64]?) {
        if let sequences, dirtyDurable != nil {
            for sequence in sequences {
                dirtyDurable?.insert(TranscriptChunk.chunkID(of: sequence))
            }
        } else {
            dirtyDurable = nil
        }
        schedule()
    }

    func notePreviewChanged() {
        previewDirty = true
        schedule()
    }

    /// The live translation cues changed. They are not part of the frame —
    /// readers take them from the capture store — but a frame is published
    /// so that the page drawing them looks again, at the same bounded rate.
    func noteLiveCuesChanged() {
        cuesDirty = true
        schedule()
    }

    /// Builds and publishes the pending frame now, for tests. Everything else
    /// waits for its slot, at most one interval.
    func flush() {
        scheduled?.cancel()
        scheduled = nil
        rebuild()
    }

    private func schedule() {
        guard scheduled == nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let wait = max(0, lastPublishedAt + interval - now)
        scheduled = Task { @MainActor [weak self] in
            if wait > 0 {
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            } else {
                await Task.yield()
            }
            guard let self, Task.isCancelled == false else { return }
            self.scheduled = nil
            self.rebuild()
        }
    }

    private func rebuild() {
        lastPublishedAt = ProcessInfo.processInfo.systemUptime
        guard let source else { return }
        let currentSession = source.sessionId()
        if currentSession != sessionId {
            sessionId = currentSession
            durableChunks = [:]
            publishedChunks = [:]
            previewChunkIDs = []
            dirtyDurable = nil
            previewDirty = true
        }
        guard dirtyDurable != [] || previewDirty || cuesDirty else { return }

        let durable = source.durable()
        var touched: Set<UInt64> = []
        if let dirty = dirtyDurable {
            for chunkID in dirty {
                let rows = Self.rows(in: chunkID, of: durable, sessionId: currentSession)
                if updateDurableChunk(chunkID, rows: rows) { touched.insert(chunkID) }
            }
        } else {
            var seen: Set<UInt64> = []
            var start = 0
            while start < durable.count {
                let chunkID = TranscriptChunk.chunkID(of: durable[start].sequence)
                var end = start
                while end < durable.count,
                      TranscriptChunk.chunkID(of: durable[end].sequence) == chunkID {
                    end += 1
                }
                let rows = durable[start..<end].filter { $0.sessionId == currentSession }
                seen.insert(chunkID)
                if updateDurableChunk(chunkID, rows: rows) { touched.insert(chunkID) }
                start = end
            }
            for chunkID in durableChunks.keys where seen.contains(chunkID) == false {
                durableChunks[chunkID] = nil
                touched.insert(chunkID)
            }
        }
        dirtyDurable = []

        // The preview overlays the chunks it touches now and the ones it
        // touched last time; everything else is the stored chunk as is.
        var previewByChunk: [UInt64: [NotebookCaptureUtteranceDTO]] = [:]
        if previewDirty || touched.isEmpty == false {
            for row in source.preview() where row.sessionId == currentSession {
                previewByChunk[TranscriptChunk.chunkID(of: row.sequence), default: []].append(row)
            }
            touched.formUnion(previewChunkIDs)
            touched.formUnion(previewByChunk.keys)
            previewChunkIDs = Set(previewByChunk.keys)
        }
        previewDirty = false

        var changed = false
        for chunkID in touched {
            let stored = durableChunks[chunkID]
            let next: TranscriptChunk?
            if let preview = previewByChunk[chunkID], preview.isEmpty == false {
                let rows = Self.overlay(preview: preview, on: stored?.rows ?? [])
                if let current = publishedChunks[chunkID], current.rows == rows {
                    next = current
                } else {
                    next = TranscriptChunk(id: chunkID, version: takeVersion(), rows: rows)
                }
            } else {
                next = stored
            }
            if publishedChunks[chunkID] != next {
                publishedChunks[chunkID] = next
                changed = true
            }
        }
        changed = changed || cuesDirty
        cuesDirty = false
        guard changed || frame.sessionId != currentSession else { return }
        revision &+= 1
        frame = LiveTranscriptFrame(
            sessionId: currentSession,
            chunks: publishedChunks.keys.sorted().compactMap { publishedChunks[$0] }
                .filter { $0.rows.isEmpty == false },
            revision: revision,
            hasStoredRows: durableChunks.isEmpty == false
        )
    }

    /// Returns whether the chunk changed.
    private func updateDurableChunk(_ chunkID: UInt64, rows: [NotebookCaptureUtteranceDTO]) -> Bool {
        if rows.isEmpty {
            return durableChunks.removeValue(forKey: chunkID) != nil
        }
        if let current = durableChunks[chunkID], current.rows == rows { return false }
        durableChunks[chunkID] = TranscriptChunk(id: chunkID, version: takeVersion(), rows: rows)
        return true
    }

    private func takeVersion() -> UInt64 {
        defer { nextVersion &+= 1 }
        return nextVersion
    }

    /// Stored rows of one chunk, found by binary search in the ordered rows.
    static func rows(
        in chunkID: UInt64,
        of durable: [NotebookCaptureUtteranceDTO],
        sessionId: String?
    ) -> [NotebookCaptureUtteranceDTO] {
        let first = chunkID * TranscriptChunk.size
        let limit = first + TranscriptChunk.size
        var low = 0
        var high = durable.count
        while low < high {
            let middle = (low + high) / 2
            if durable[middle].sequence < first { low = middle + 1 } else { high = middle }
        }
        var rows: [NotebookCaptureUtteranceDTO] = []
        var index = low
        while index < durable.count, durable[index].sequence < limit {
            if durable[index].sessionId == sessionId { rows.append(durable[index]) }
            index += 1
        }
        return rows
    }

    /// `NotebookCaptureLivePresentation.utterances` for one chunk, so the
    /// chunked frame and the flat merge can never disagree: a stored row wins
    /// over every preview row carrying its sequence.
    static func overlay(
        preview: [NotebookCaptureUtteranceDTO],
        on stored: [NotebookCaptureUtteranceDTO]
    ) -> [NotebookCaptureUtteranceDTO] {
        guard let sessionId = stored.first?.sessionId ?? preview.first?.sessionId else {
            return stored
        }
        return NotebookCaptureLivePresentation.utterances(
            durable: stored,
            preview: preview,
            sessionId: sessionId
        )
    }
}
