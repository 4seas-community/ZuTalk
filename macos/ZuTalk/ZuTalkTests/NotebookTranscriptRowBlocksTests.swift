import XCTest
@testable import ZuTalk

/// The live transcript stays cheap only if a frame that changes the newest
/// row leaves every earlier block as it was, so SwiftUI compares it by two
/// integers and skips it.
@MainActor
final class NotebookTranscriptRowBlocksTests: XCTestCase {
    private func row(_ index: Int, text: String? = nil, final: Bool = true) -> NotebookCaptureUtteranceDTO {
        var utterance = NotebookCaptureUtteranceDTO(
            id: "utt-\(index)",
            sessionId: "session",
            sequence: UInt64(index),
            revision: 1,
            sourceLanguage: "th",
            sourceText: text ?? "ประโยคที่ \(index) ของการประชุม",
            sourceStartMs: UInt64(index) * 4_000,
            sourceEndMs: UInt64(index) * 4_000 + 3_500,
            translatedLanguage: nil,
            translatedText: nil,
            completion: final ? "complete" : "partial",
            alignment: "response_order"
        )
        utterance.languageVariants = [
            NotebookCaptureLanguageVariantDTO(
                language: "th", role: "source", text: utterance.sourceText,
                state: "ready", completion: final ? "complete" : "partial",
                projectionRevision: UInt64(index + 1)
            ),
            NotebookCaptureLanguageVariantDTO(
                language: "zh", role: "translation", text: "第 \(index) 句",
                state: "ready", completion: "complete",
                projectionRevision: UInt64(index + 1)
            ),
        ]
        utterance.sourceProjectionRevision = UInt64(index + 1)
        return utterance
    }

    private let noCues = NotebookTranslationCueIndex([])

    private func context(
        appliedRevision: UInt64 = 1_000,
        progress: NotebookTranslationProgress = .none,
        cues: NotebookTranslationCueIndex? = nil
    ) -> NotebookTranscriptRowContext {
        NotebookTranscriptRowContext(
            languages: ["th", "zh", "en"],
            progress: progress,
            continuationCues: cues ?? noCues,
            appliedRevision: appliedRevision,
            isLaneEditingEnabled: true,
            gaps: [],
            speakerNamesRevision: 0,
            speakerName: { _ in nil }
        )
    }

    private func versions(
        _ cache: NotebookTranscriptRowCache,
        _ chunks: [TranscriptChunk],
        _ context: NotebookTranscriptRowContext
    ) -> [UInt64] {
        cache.multilingualBlocks(chunks: chunks, context: context).blocks.map(\.version)
    }

    func testAGrowingTailRebuildsOnlyTheLastBlock() {
        let cache = NotebookTranscriptRowCache()
        var rows = (0..<40).map { row($0) }
        rows.append(row(40, text: "กำลังพูด", final: false))
        let before = versions(cache, cache.chunks(for: rows), context())
        XCTAssertEqual(before.count, 3)

        rows[40] = row(40, text: "กำลังพูดอยู่ต่อไปเรื่อยๆ", final: false)
        let after = versions(cache, cache.chunks(for: rows), context())
        XCTAssertEqual(Array(after.prefix(2)), Array(before.prefix(2)))
        XCTAssertNotEqual(after[2], before[2])
    }

    /// The projection watermark moves every second during a recording. Past
    /// a chunk's own lanes it changes nothing that chunk shows.
    func testTheMovingWatermarkLeavesSettledBlocksAlone() {
        let cache = NotebookTranscriptRowCache()
        let chunks = cache.chunks(for: (0..<40).map { row($0) })
        let before = versions(cache, chunks, context(appliedRevision: 500))
        let after = versions(cache, chunks, context(appliedRevision: 900))
        XCTAssertEqual(before, after)
    }

    /// Translation progress past a chunk's last row, plus the binding grace,
    /// cannot resolve anything more in it.
    func testProgressPastAChunkLeavesItAlone() {
        let cache = NotebookTranscriptRowCache()
        let chunks = cache.chunks(for: (0..<40).map { row($0) })
        func progress(_ ms: UInt64) -> NotebookTranslationProgress {
            NotebookTranslationProgress(settledThroughMs: ["en": ms], stoppedLanguages: [])
        }
        let first = versions(cache, chunks, context(progress: progress(500_000)))
        let second = versions(cache, chunks, context(progress: progress(600_000)))
        XCTAssertEqual(first, second)
    }

    func testClampedWatermarkKeepsEditabilityExact() {
        let cache = NotebookTranscriptRowCache()
        let chunks = cache.chunks(for: (0..<3).map { row($0) })
        for applied in UInt64(0)...5 {
            let models = cache.multilingualBlocks(chunks: chunks, context: context(appliedRevision: applied))
                .blocks.flatMap(\.rows)
            for model in models {
                for language in ["th", "zh"] {
                    XCTAssertEqual(
                        model.utterance.isLoroEditableLane(language: language, appliedRevision: model.appliedRevision),
                        model.utterance.isLoroEditableLane(language: language, appliedRevision: applied),
                        "row \(model.id) lane \(language) at watermark \(applied)"
                    )
                }
            }
            XCTAssertEqual(
                chunks.contains { $0.hasEditableLane(appliedRevision: applied) },
                (0..<3).map { row($0) }.contains { utterance in
                    ["th", "zh"].contains { utterance.isLoroEditableLane(language: $0, appliedRevision: applied) }
                }
            )
        }
    }

    /// A new translation segment at the live edge must not rebuild chunks
    /// that ended long before it, though their empty cells read the index.
    func testANewSegmentAtTheLiveEdgeLeavesEarlierChunksAlone() {
        func cue(_ id: String, start: UInt64) -> NotebookCaptureTranslationCueDTO {
            NotebookCaptureTranslationCueDTO(
                targetLanguage: "en", groupEpoch: 0, providerSequence: UInt64(id.utf8.first ?? 0),
                sourceLanguage: "th", sourceStartMs: start, sourceEndMs: start + 3_000,
                text: "segment", completion: "complete", withdrawn: false, revision: 1
            )
        }
        let cache = NotebookTranscriptRowCache()
        let chunks = cache.chunks(for: (0..<48).map { row($0) })
        let first = NotebookTranslationCueIndex([cue("a", start: 4_000)])
        let second = NotebookTranslationCueIndex(
            [cue("a", start: 4_000), cue("b", start: 190_000)],
            replacing: first
        )
        let before = versions(cache, chunks, context(cues: first))
        let after = versions(cache, chunks, context(cues: second))
        XCTAssertEqual(Array(after.prefix(2)), Array(before.prefix(2)))
        XCTAssertNotEqual(after[2], before[2], "the last chunk reaches the new segment")
    }

    /// Gaps anchor before the same rows the flat rule picks.
    func testGapsAnchorWhereTheFlatRuleAnchorsThem() {
        let rows = (0..<50).map { row($0) }
        let gaps = [10_000, 63_000, 150_000, 999_000].enumerated().map { index, start in
            NotebookTranscriptGapDTO(
                id: "gap-\(index)",
                sessionId: "session",
                startMs: UInt64(start),
                endMs: UInt64(start) + 2_000,
                repairState: "open"
            )
        }
        let flat = NotebookTranscriptGapPresentation.anchoredGaps(utterances: rows, gaps: gaps)
        let cache = NotebookTranscriptRowCache()
        let chunked = NotebookTranscriptRowCache.anchorGaps(gaps, in: cache.chunks(for: rows)) { _ in true }
        XCTAssertEqual(chunked.leading, flat.leading)
        XCTAssertEqual(chunked.trailing, flat.trailing)
    }

    func testUnorderedRowsStillGiveOneBlockPerChunk() {
        let cache = NotebookTranscriptRowCache()
        let rows = Array((0..<34).map { row($0) }.reversed())
        let chunks = cache.chunks(for: rows)
        XCTAssertEqual(chunks.map(\.id), [0, 1, 2])
        XCTAssertEqual(chunks.flatMap(\.rows).map(\.sequence), (0..<34).map(UInt64.init))
    }
}
