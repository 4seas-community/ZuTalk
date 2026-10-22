import XCTest
@testable import ZuTalk

/// The chunked live transcript must be exactly the rows the flat merge would
/// give, and must only ever rebuild the chunks that changed.
@MainActor
final class LiveTranscriptTimelineTests: XCTestCase {
    private struct Generator {
        var state: UInt64
        mutating func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(max(bound, 1)))
        }
    }

    static func row(
        _ sequence: UInt64,
        session: String = "session",
        text: String? = nil,
        revision: UInt64 = 1,
        language: String = "th",
        start: UInt64?? = nil,
        preview: Bool = false
    ) -> NotebookCaptureUtteranceDTO {
        let startMs = start ?? .some(sequence * 3_000)
        return NotebookCaptureUtteranceDTO(
            id: preview ? "preview-\(sequence)" : "utt-\(sequence)",
            sessionId: session,
            sequence: sequence,
            revision: revision,
            sourceLanguage: language,
            sourceText: text ?? "แถว \(sequence) r\(revision)",
            sourceStartMs: startMs,
            sourceEndMs: startMs.map { $0 + 2_500 },
            translatedLanguage: nil,
            translatedText: nil,
            completion: preview ? "partial" : "complete",
            alignment: "response_order"
        )
    }

    private final class Rows {
        var session: String? = "session"
        var durable: [NotebookCaptureUtteranceDTO] = []
        var preview: [NotebookCaptureUtteranceDTO] = []
    }

    private func timeline(_ rows: Rows) -> LiveTranscriptTimeline {
        let timeline = LiveTranscriptTimeline(interval: 0)
        timeline.attach(LiveTranscriptTimeline.Source(
            sessionId: { rows.session },
            durable: { rows.durable },
            preview: { rows.preview }
        ))
        timeline.flush()
        return timeline
    }

    func testAChangedRowRebuildsOnlyItsOwnChunk() {
        let rows = Rows()
        rows.durable = (0..<50).map { Self.row($0) }
        let timeline = timeline(rows)
        let before = timeline.frame.chunks
        XCTAssertEqual(before.map(\.id), [0, 1, 2, 3])

        rows.durable[20] = Self.row(20, revision: 2)
        timeline.noteDurableChanged(sequences: [20])
        timeline.flush()
        let after = timeline.frame.chunks

        XCTAssertEqual(after.map(\.id), [0, 1, 2, 3])
        XCTAssertEqual(after[0].version, before[0].version)
        XCTAssertNotEqual(after[1].version, before[1].version)
        XCTAssertEqual(after[2].version, before[2].version)
        XCTAssertEqual(after[3].version, before[3].version)
        XCTAssertEqual(after[1].rows[4].revision, 2)
    }

    func testAPreviewTailTouchesOnlyTheChunksItCovers() {
        let rows = Rows()
        rows.durable = (0..<40).map { Self.row($0) }
        let timeline = timeline(rows)
        let before = timeline.frame.chunks

        rows.preview = [Self.row(40, preview: true)]
        timeline.notePreviewChanged()
        timeline.flush()
        let after = timeline.frame.chunks

        XCTAssertEqual(after.map(\.id), [0, 1, 2])
        XCTAssertEqual(after[0].version, before[0].version)
        XCTAssertEqual(after[1].version, before[1].version)
        XCTAssertNotEqual(after[2].version, before[2].version)
        XCTAssertEqual(after[2].rows.last?.id, "preview-40")

        // The tail settling into a stored row of the same sequence replaces
        // the preview row instead of showing both.
        rows.durable.append(Self.row(40))
        timeline.noteDurableChanged(sequences: [40])
        rows.preview = []
        timeline.notePreviewChanged()
        timeline.flush()
        XCTAssertEqual(timeline.frame.chunks.last?.rows.last?.id, "utt-40")
        XCTAssertEqual(timeline.frame.rowCount, 41)
    }

    /// Copying the transcript copies stored rows; a recording whose words
    /// are all still speculative has nothing to copy yet, and its frame says
    /// so even though it shows text.
    func testAFrameOfOnlyTheSpeculativeTailHasNoStoredRows() {
        let rows = Rows()
        let timeline = timeline(rows)
        rows.preview = [Self.row(0, preview: true)]
        timeline.notePreviewChanged()
        timeline.flush()
        XCTAssertFalse(timeline.frame.isEmpty)
        XCTAssertFalse(timeline.frame.hasStoredRows)

        rows.durable = [Self.row(0)]
        timeline.noteDurableChanged(sequences: [0])
        timeline.flush()
        XCTAssertTrue(timeline.frame.hasStoredRows)
    }

    /// Whatever the sequence of edits, the frame is the flat merge.
    func testTheFrameIsAlwaysTheFlatMerge() {
        var generator = Generator(state: 7)
        for _ in 0..<40 {
            let rows = Rows()
            let timeline = timeline(rows)
            var bySequence: [UInt64: NotebookCaptureUtteranceDTO] = [:]
            for step in 0..<60 {
                switch generator.next(5) {
                case 0, 1:
                    let sequence = UInt64(generator.next(90))
                    bySequence[sequence] = Self.row(sequence, revision: UInt64(step + 1))
                    rows.durable = bySequence.values.sorted { $0.sequence < $1.sequence }
                    timeline.noteDurableChanged(sequences: [sequence])
                case 2:
                    let keys = bySequence.keys.sorted()
                    if keys.isEmpty == false {
                        let sequence = keys[generator.next(keys.count)]
                        bySequence[sequence] = nil
                        rows.durable = bySequence.values.sorted { $0.sequence < $1.sequence }
                        timeline.noteDurableChanged(sequences: generator.next(2) == 0 ? [sequence] : nil)
                    }
                default:
                    let first = UInt64(generator.next(95))
                    rows.preview = (0..<UInt64(generator.next(4))).map {
                        Self.row(first + $0, revision: UInt64(step + 1), preview: true)
                    }
                    timeline.notePreviewChanged()
                }
                if generator.next(3) == 0 {
                    timeline.flush()
                    XCTAssertEqual(
                        timeline.frame.rows,
                        NotebookCaptureLivePresentation.utterances(
                            durable: rows.durable,
                            preview: rows.preview,
                            sessionId: rows.session
                        )
                    )
                }
            }
        }
    }

    func testAnotherSessionStartsFromAnEmptyFrame() {
        let rows = Rows()
        rows.durable = (0..<5).map { Self.row($0) }
        let timeline = timeline(rows)
        XCTAssertEqual(timeline.frame.rowCount, 5)

        rows.session = "next"
        rows.durable = [Self.row(0, session: "next")]
        timeline.noteDurableChanged(sequences: nil)
        timeline.flush()
        XCTAssertEqual(timeline.frame.sessionId, "next")
        XCTAssertEqual(timeline.frame.rows.map(\.sessionId), ["next"])
    }

    /// A burst of changes inside one interval is one published frame.
    func testABurstOfChangesPublishesOneFrame() async throws {
        let rows = Rows()
        let timeline = LiveTranscriptTimeline(interval: 0.2)
        timeline.attach(LiveTranscriptTimeline.Source(
            sessionId: { rows.session },
            durable: { rows.durable },
            preview: { rows.preview }
        ))
        timeline.flush()
        let start = timeline.frame.revision
        for sequence in 0..<30 {
            rows.durable.append(Self.row(UInt64(sequence)))
            timeline.noteDurableChanged(sequences: [UInt64(sequence)])
        }
        try await Task.sleep(nanoseconds: 450_000_000)
        XCTAssertEqual(timeline.frame.revision, start + 1)
        XCTAssertEqual(timeline.frame.rowCount, 30)
    }

    // MARK: Audience candidates

    /// Folding row by row, from any checkpoint, gives what the whole-session
    /// functions give.
    func testTheResumableAudienceFoldMatchesTheWholeSessionScan() {
        var generator = Generator(state: 11)
        let languages = ["th", "zh", "en"]
        for trial in 0..<60 {
            var rows: [NotebookCaptureUtteranceDTO] = []
            for sequence in 0..<UInt64(10 + generator.next(80)) {
                let untimed = generator.next(6) == 0
                let start = UInt64(generator.next(200_000))
                rows.append(Self.row(
                    sequence,
                    language: ["th", "zh", "en", "und", "fr"][generator.next(5)],
                    start: untimed ? .some(nil) : .some(start)
                ))
            }
            let limit = 1 + generator.next(6)
            let fallback = trial % 2 == 0 ? "zh" : nil
            let anchors = NotebookCaptureLivePresentation.inheritedSourceAnchors(
                durable: rows,
                sessionId: "session"
            )
            let expected = NotebookCaptureLivePresentation.audienceDurableCandidates(
                durable: rows,
                sessionId: "session",
                selectedLanguages: languages,
                fallbackLanguage: fallback,
                maximumRows: limit,
                inheritedSourceAnchors: anchors
            )

            // Fold with a checkpoint in the middle, as the store does.
            let split = generator.next(rows.count)
            var fold = AudienceCandidateFold()
            for row in rows[..<split] {
                fold.consume(row, selectedLanguages: languages, fallbackLanguage: fallback, limit: limit)
            }
            var resumed = fold
            for row in rows[split...] {
                resumed.consume(row, selectedLanguages: languages, fallbackLanguage: fallback, limit: limit)
            }
            let result = resumed.result(globalTail: Array(rows.suffix(limit)), tailAnchors: [:])

            XCTAssertEqual(result.utterances, expected, "trial \(trial)")
            for utterance in result.utterances {
                XCTAssertEqual(result.anchors[utterance.id], anchors[utterance.id], "trial \(trial)")
            }
        }
    }

    // MARK: Coalesced events

    private struct Model: Equatable {
        var rows: [UInt64: NotebookCaptureUtteranceDTO] = [:]
        var cues: [String: NotebookCaptureTranslationCueDTO] = [:]

        /// The store's rules: a snapshot replaces, removals drop, the higher
        /// revision wins and the later event wins a tie.
        mutating func apply(_ event: NotebookCaptureEventDTO) {
            if event.isFullSnapshot {
                rows = [:]
                cues = [:]
            }
            for sequence in event.removedSequences { rows[sequence] = nil }
            for row in event.utterances {
                if let current = rows[row.sequence], current.revision > row.revision { continue }
                rows[row.sequence] = row
            }
            // `reconcileTranslationCues`: a withdrawal always removes; a cue
            // replaces one with no higher revision.
            for cue in event.translationCues {
                if cue.withdrawn {
                    cues[cue.id] = nil
                    continue
                }
                if let current = cues[cue.id], current.revision > cue.revision { continue }
                cues[cue.id] = cue
            }
        }
    }

    private static func event(
        revision: UInt64,
        full: Bool,
        rows: [NotebookCaptureUtteranceDTO],
        removed: [UInt64],
        cues: [NotebookCaptureTranslationCueDTO]
    ) -> NotebookCaptureEventDTO {
        NotebookCaptureEventDTO(
            sessionId: "session",
            eventRevision: revision,
            isFullSnapshot: full,
            captureState: .recording,
            remoteHealth: .live,
            projectionState: .ready,
            utterances: rows,
            removedSequences: removed,
            translationCues: cues,
            contextReceipt: nil,
            providerErrorType: nil,
            providerRequestId: nil
        )
    }

    func testOneCoalescedEventLeavesWhatTheEventsLeaveOneByOne() {
        var generator = Generator(state: 23)
        for trial in 0..<200 {
            var base = Model()
            var start = Self.event(revision: 1, full: true, rows: (0..<UInt64(generator.next(8))).map { Self.row($0) }, removed: [], cues: [])
            if generator.next(2) == 0 { start = Self.event(revision: 1, full: false, rows: [], removed: [], cues: []) }
            base.apply(start)
            var oneByOne = base
            var queued: [NotebookCaptureEventDTO] = []
            for revision in 2..<UInt64(2 + 1 + generator.next(6)) {
                let rows = (0..<generator.next(4)).map { _ in
                    Self.row(UInt64(generator.next(12)), revision: UInt64(generator.next(5)))
                }
                let removed = (0..<generator.next(2)).map { _ in UInt64(generator.next(12)) }
                    .filter { sequence in rows.contains { $0.sequence == sequence } == false }
                let cues = (0..<generator.next(3)).map { _ in
                    NotebookCaptureTranslationCueDTO(
                        targetLanguage: "en", groupEpoch: 0,
                        providerSequence: UInt64(generator.next(4)), sourceLanguage: "th",
                        sourceStartMs: 0, sourceEndMs: 1_000, text: "t\(revision)",
                        completion: "partial", withdrawn: generator.next(4) == 0,
                        revision: UInt64(generator.next(5))
                    )
                }
                let event = Self.event(
                    revision: revision,
                    full: generator.next(7) == 0,
                    rows: rows,
                    removed: removed,
                    cues: cues
                )
                oneByOne.apply(event)
                queued.append(event)
            }
            var merged = base
            let coalesced = queued.dropFirst().reduce(queued[0]) {
                NotebookCaptureEventDTO.coalescing($0, into: $1)
            }
            merged.apply(coalesced)
            XCTAssertEqual(merged, oneByOne, "trial \(trial)")
            XCTAssertEqual(coalesced.coversFromRevision ?? coalesced.eventRevision, 2, "trial \(trial)")
            XCTAssertEqual(coalesced.eventRevision, queued.last?.eventRevision)
        }
    }

    /// The core leaves a revision out on purpose when it cannot read the
    /// rows for it, so that the next event shows the store a gap and the
    /// store reloads. Merging across that hole must keep it visible.
    func testMergingAcrossAMissingRevisionKeepsTheGapVisible() {
        let seven = Self.event(revision: 7, full: false, rows: [Self.row(1)], removed: [], cues: [])
        let nine = Self.event(revision: 9, full: false, rows: [Self.row(2)], removed: [], cues: [])
        let merged = NotebookCaptureEventDTO.coalescing(seven, into: nine)
        XCTAssertEqual(merged.coversFromRevision ?? merged.eventRevision, 9, "revision 8 is missing")

        var eightToNine = nine
        eightToNine.coversFromRevision = 8
        let contiguous = NotebookCaptureEventDTO.coalescing(seven, into: eightToNine)
        XCTAssertEqual(contiguous.coversFromRevision ?? contiguous.eventRevision, 7)
    }
}
