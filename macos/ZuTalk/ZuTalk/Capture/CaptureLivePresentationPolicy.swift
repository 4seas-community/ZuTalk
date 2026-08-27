import AVFoundation
import Combine
import Foundation

enum NotebookCaptureLivePresentation {
    static func utterances(
        durable: [NotebookCaptureUtteranceDTO],
        preview: [NotebookCaptureUtteranceDTO],
        sessionId: String?
    ) -> [NotebookCaptureUtteranceDTO] {
        guard let sessionId else { return durable }
        let durableRows = durable.filter { $0.sessionId == sessionId }
        let previewRows = preview.filter { $0.sessionId == sessionId }
        guard previewRows.isEmpty == false else { return durableRows }

        // Both stores maintain source-sequence order. Merge their ordered
        // views directly instead of rebuilding a full-session Set and sorting
        // the complete result on every speculative frame. A durable sequence
        // wins over every preview row carrying that sequence, exactly as in
        // the former implementation.
        var rows: [NotebookCaptureUtteranceDTO] = []
        rows.reserveCapacity(durableRows.count + previewRows.count)
        var durableIndex = 0
        var previewIndex = 0
        while durableIndex < durableRows.count, previewIndex < previewRows.count {
            let durableRow = durableRows[durableIndex]
            let previewRow = previewRows[previewIndex]
            if durableRow.sequence <= previewRow.sequence {
                rows.append(durableRow)
                durableIndex += 1
                if durableRow.sequence == previewRow.sequence {
                    let durableSequence = durableRow.sequence
                    while previewIndex < previewRows.count,
                          previewRows[previewIndex].sequence == durableSequence {
                        previewIndex += 1
                    }
                }
            } else {
                rows.append(previewRow)
                previewIndex += 1
            }
        }
        rows.append(contentsOf: durableRows[durableIndex...])
        rows.append(contentsOf: previewRows[previewIndex...])
        return rows
    }

    /// Canvas-sized live suffix without filtering or sorting the full durable
    /// session on every SwiftUI refresh. Both inputs are maintained in source
    /// sequence order by the store/provider. Walking backward stops as soon as
    /// enough candidates exist, then only the at-most `2 * limit` candidate
    /// set is deduplicated and sorted.
    static func utteranceTail(
        durable: [NotebookCaptureUtteranceDTO],
        preview: [NotebookCaptureUtteranceDTO],
        sessionId: String?,
        limit: Int
    ) -> [NotebookCaptureUtteranceDTO] {
        let limit = max(limit, 0)
        guard limit > 0 else { return [] }
        guard let sessionId else { return Array(durable.suffix(limit)) }

        func orderedTail(
            of rows: [NotebookCaptureUtteranceDTO],
            sessionId: String
        ) -> [NotebookCaptureUtteranceDTO] {
            var result: [NotebookCaptureUtteranceDTO] = []
            result.reserveCapacity(min(limit, rows.count))
            for row in rows.reversed() {
                if row.sessionId != sessionId { continue }
                result.append(row)
                if result.count == limit { break }
            }
            return result.reversed()
        }

        let durableTail = orderedTail(of: durable, sessionId: sessionId)
        let previewTail = orderedTail(of: preview, sessionId: sessionId)
        let durableSequences = Set(durableTail.map(\.sequence))
        // When the durable suffix is already full, an older preview cannot
        // enter the final suffix. This also prevents an old preview duplicate
        // whose durable row sits just outside the bounded candidate set from
        // resurfacing as live text.
        let durableCutoff = durableTail.count == limit
            ? durableTail.first?.sequence
            : nil
        var rows = durableTail
        rows.append(contentsOf: previewTail.filter { row in
            guard durableSequences.contains(row.sequence) == false else { return false }
            return durableCutoff.map { row.sequence > $0 } ?? true
        })
        rows.sort { $0.sequence < $1.sequence }
        return Array(rows.suffix(limit))
    }

    /// Sort-only lower bounds for the source rows this session never received a
    /// provider timestamp for, keyed by utterance id.
    ///
    /// A row carries no time when the provider omitted token metadata for the
    /// words it holds. Reading that as "later than everything timed" drops the
    /// row to the bottom of its column, which is wrong in the one way an
    /// audience notices: the sentence they just heard appears below sentences
    /// spoken minutes ago. What is actually known about such a row is that it
    /// was not spoken before the row ahead of it, so that row's coverage is
    /// carried forward as its bound.
    ///
    /// This must be computed over the whole durable session, before any
    /// pruning: a bound taken from whichever rows survived pruning is a
    /// different bound, and the bounded and full audience projections have to
    /// stay presentation-equivalent. Durable rows arrive in sequence order.
    ///
    /// The bound is deliberately not a timestamp. It never reaches coverage
    /// arithmetic — a lane held up entirely by inherited bounds must still read
    /// as behind — and it is never persisted, exported, or displayed.
    ///
    /// A nil `sessionId` takes every row, for a caller that was already handed
    /// one session's rows — a shared room's frame, for one.
    static func inheritedSourceAnchors(
        durable: [NotebookCaptureUtteranceDTO],
        sessionId: String?
    ) -> [String: UInt64] {
        var anchors: [String: UInt64] = [:]
        var carried: UInt64?
        for utterance in durable
        where sessionId.map({ utterance.sessionId == $0 }) ?? true {
            guard let start = utterance.sourceStartMs else {
                if let carried {
                    anchors[utterance.id] = carried
                }
                continue
            }
            // The most recent timed row, not the greatest coverage ever seen:
            // timestamps restart with a stream group, and a bound taken from
            // the old epoch's clock would push the row back down the column
            // the restart just lifted it out of.
            carried = utterance.sourceEndMs ?? start
        }
        return anchors
    }

    /// The durable source rows that can still affect an audience canvas with
    /// `maximumRows` visible cards per language. This preserves each language's
    /// independently sorted suffix, the greatest coverage item used by the
    /// waiting indicator, and the global suffix used by the unrouted strip.
    /// Everything else is provably invisible until the next durable change.
    ///
    /// `inheritedSourceAnchors` must be the whole-session map from the function
    /// above. Pruning happens here, so an untimed row is selected — or dropped —
    /// under the same order the canvas will later paint it in.
    static func audienceDurableCandidates(
        durable: [NotebookCaptureUtteranceDTO],
        sessionId: String,
        selectedLanguages: [String],
        lastIdentifiedSourceLanguage: String?,
        maximumRows: Int,
        inheritedSourceAnchors: [String: UInt64] = [:]
    ) -> [NotebookCaptureUtteranceDTO] {
        let limit = max(maximumRows, 0)
        guard limit > 0 else { return [] }

        func sourceComesBefore(
            _ left: NotebookCaptureUtteranceDTO,
            _ right: NotebookCaptureUtteranceDTO
        ) -> Bool {
            let leftAnchor = left.sourceStartMs ?? inheritedSourceAnchors[left.id]
            let rightAnchor = right.sourceStartMs ?? inheritedSourceAnchors[right.id]
            switch (leftAnchor, rightAnchor) {
            case let (.some(leftAnchor), .some(rightAnchor)) where leftAnchor != rightAnchor:
                return leftAnchor < rightAnchor
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            default:
                // Same instant: what was measured there precedes what merely
                // cannot have happened before it.
                if (left.sourceStartMs == nil) != (right.sourceStartMs == nil) {
                    return right.sourceStartMs == nil
                }
                return left.sequence < right.sequence
            }
        }

        let placement: (NotebookCaptureUtteranceDTO) -> String? = { utterance in
            NotebookCaptureHistoryPolicy.audienceSourcePlacement(
                for: utterance,
                selectedLanguages: selectedLanguages,
                lastIdentifiedSourceLanguage: lastIdentifiedSourceLanguage
            )
        }
        var visibleSources: [String: [NotebookCaptureUtteranceDTO]] = [:]
        var coverageLeaders: [String: NotebookCaptureUtteranceDTO] = [:]
        var globalTail: [NotebookCaptureUtteranceDTO] = []
        globalTail.reserveCapacity(limit)

        for utterance in durable where utterance.sessionId == sessionId {
            globalTail.append(utterance)
            if globalTail.count > limit {
                globalTail.removeFirst(globalTail.count - limit)
            }

            guard let language = placement(utterance) else { continue }
            var retained = visibleSources[language] ?? []
            retained.append(utterance)
            retained.sort(by: sourceComesBefore)
            if retained.count > limit {
                retained.removeFirst(retained.count - limit)
            }
            visibleSources[language] = retained

            if let coverage = utterance.sourceEndMs ?? utterance.sourceStartMs {
                let existingCoverage = coverageLeaders[language]
                    .flatMap { $0.sourceEndMs ?? $0.sourceStartMs }
                if existingCoverage.map({ coverage > $0 }) ?? true {
                    coverageLeaders[language] = utterance
                }
            }
        }

        var candidatesByID: [String: NotebookCaptureUtteranceDTO] = [:]
        for utterance in globalTail {
            candidatesByID[utterance.id] = utterance
        }
        for utterance in visibleSources.values.joined() {
            candidatesByID[utterance.id] = utterance
        }
        for utterance in coverageLeaders.values {
            candidatesByID[utterance.id] = utterance
        }
        return candidatesByID.values.sorted {
            if $0.sequence != $1.sequence { return $0.sequence < $1.sequence }
            return $0.id < $1.id
        }
    }
}

/// Bounds how often interim preview revisions reach the published transcript.
///
/// The realtime provider emits a preview revision at roughly speaking cadence —
/// on the order of ten or more per second — and each one replaces the whole
/// preview array, which redraws the subtitle canvas end to end. That canvas is
/// a window floating over a live meeting, so its redraws are work the display
/// compositor cannot cache; left unbounded they are the dominant cost of
/// showing subtitles at all.
///
/// Only the interim path is bounded. Committed text reaches the transcript
/// through the durable utterance list, so the sole thing a held revision
/// delays is an interim string that a newer revision is about to overwrite.
///
/// The first revision after a quiet gap publishes immediately, so the first
/// word after silence is never late; only a burst is held, and the caller's
/// trailing flush guarantees the last revision of a burst still lands.
enum NotebookCaptureLivePreviewCoalescing {
    /// Thirty publishes a second is past the point where a reader can tell
    /// coalescing is happening, so the words appear to flow. The window is not
    /// removed entirely because it is the only ceiling on a provider that
    /// revises in bursts; without it a pathological run of revisions has
    /// nothing standing between it and the compositor.
    nonisolated static let interval: TimeInterval = 1.0 / 30.0

    enum Decision: Equatable {
        case publishNow
        case hold(after: TimeInterval)
    }

    static func decide(
        now: TimeInterval,
        lastPublishedAt: TimeInterval?,
        interval: TimeInterval = interval
    ) -> Decision {
        guard interval > 0, let lastPublishedAt else { return .publishNow }
        let elapsed = now - lastPublishedAt
        // A non-monotonic or rewound clock reads as "long enough ago" rather
        // than stranding the canvas behind a hold that never expires.
        guard elapsed >= 0, elapsed < interval else { return .publishNow }
        return .hold(after: interval - elapsed)
    }
}
