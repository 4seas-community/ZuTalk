import AppKit
import Combine
import SwiftUI

// MARK: - Run-derived realtime transcript

enum NotebookTranscriptSessionIsolation {
    static func isActiveElsewhere(
        requestedSessionId: String,
        storeSessionId: String?,
        isCaptureActive: Bool
    ) -> Bool {
        isCaptureActive && storeSessionId != requestedSessionId
    }

    static func visibleUtterances(
        requestedSessionId: String,
        storeSessionId: String?,
        isCaptureActive: Bool,
        utterances: [NotebookCaptureUtteranceDTO]
    ) -> [NotebookCaptureUtteranceDTO] {
        guard isActiveElsewhere(
            requestedSessionId: requestedSessionId,
            storeSessionId: storeSessionId,
            isCaptureActive: isCaptureActive
        ) == false,
        storeSessionId == requestedSessionId
        else { return [] }
        return utterances.filter { $0.sessionId == requestedSessionId }
    }
}

enum NotebookRealtimeTranscriptLayout {
    static let headerHeight: CGFloat = 44
    static let horizontalInset: CGFloat = Spacing.xl
    static let horizontalScrollThreshold = 4
    static let minimumLanguageColumnWidth: CGFloat = 220

    static func usesHorizontalScroll(languageCount: Int) -> Bool {
        languageCount >= horizontalScrollThreshold
    }

    static func minimumContentWidth(languageCount: Int) -> CGFloat {
        CGFloat(max(languageCount, 1)) * minimumLanguageColumnWidth
    }
}

enum NotebookRealtimeProjectionLayout: Equatable {
    case snapshotUnavailable
    case transcriptionTimeline
    case bilingualColumns
}

enum NotebookRealtimeProjectionPolicy {
    /// The run's mode remains immutable processing provenance. The requested
    /// presentation is process-local and may change while recording.
    static func layout(
        presentation: NotebookTranscriptPresentationMode,
        run: NotebookCaptureHistoryRunDTO
    ) -> NotebookRealtimeProjectionLayout {
        guard run.mode != nil else { return .snapshotUnavailable }
        guard presentation == .bilingualColumns else { return .transcriptionTimeline }
        guard let languages = NotebookCaptureHistoryPolicy.displayLanguages(for: run) else {
            return .snapshotUnavailable
        }
        return languages.isEmpty ? .snapshotUnavailable : .bilingualColumns
    }
}

struct NotebookRealtimeAutoscrollSignal: Equatable {
    let utteranceID: String?
    let revision: UInt64
    let textExtent: Int
    let cueGroupEpoch: UInt64
    let cueProviderSequence: UInt64
    let cueRevision: UInt64
    let cueRevisionTotal: UInt64
    let cueCount: Int
    let cueTextExtent: Int
}

enum NotebookRealtimeAutoscrollPolicy {
    /// Row identity stays stable so SwiftUI can update in place. Presentation
    /// progress is a separate signal: a long Soniox utterance can grow hundreds
    /// of times before a new row ID appears.
    static func signal(
        in utterances: [NotebookCaptureUtteranceDTO],
        cues: [NotebookCaptureTranslationCueDTO] = []
    ) -> NotebookRealtimeAutoscrollSignal? {
        let utterance = utterances.last
        let latestCue = cues.max(by: cuePrecedes)
        guard utterance != nil || latestCue != nil else { return nil }
        let sourceTextExtent: Int = utterance?.sourceText.count ?? 0
        let translatedTextExtent: Int = utterance?.translatedText?.count ?? 0
        let variantTextExtent: Int = utterance?.languageVariants.reduce(0) { count, variant in
            count + (variant.text?.count ?? 0)
        } ?? 0
        let textExtent = sourceTextExtent + translatedTextExtent + variantTextExtent
        return NotebookRealtimeAutoscrollSignal(
            utteranceID: utterance?.id,
            revision: utterance?.revision ?? 0,
            textExtent: textExtent,
            cueGroupEpoch: latestCue?.groupEpoch ?? 0,
            cueProviderSequence: latestCue?.providerSequence ?? 0,
            cueRevision: latestCue?.revision ?? 0,
            cueRevisionTotal: cues.reduce(0) { total, cue in
                total &+ cue.groupEpoch &+ cue.providerSequence &+ cue.revision
            },
            cueCount: cues.count,
            cueTextExtent: cues.reduce(0) { $0 + $1.text.count }
        )
    }

    private static func cuePrecedes(
        _ left: NotebookCaptureTranslationCueDTO,
        _ right: NotebookCaptureTranslationCueDTO
    ) -> Bool {
        if left.groupEpoch != right.groupEpoch {
            return left.groupEpoch < right.groupEpoch
        }
        if left.providerSequence != right.providerSequence {
            return left.providerSequence < right.providerSequence
        }
        return left.revision < right.revision
    }
}

enum NotebookRealtimeSectionPolicy {
    static func targetRun(
        runs: [NotebookCaptureHistoryRunDTO],
        requestedSessionID: String?,
        activeSessionID: String?
    ) -> NotebookCaptureHistoryRunDTO? {
        if let requestedSessionID,
           requestedSessionID.isEmpty == false {
            return runs.first { $0.sessionId == requestedSessionID }
        }
        guard let activeSessionID,
              activeSessionID.isEmpty == false else { return nil }
        return runs.first { $0.sessionId == activeSessionID }
    }
}

struct NotebookRealtimeScrollMetrics: Equatable {
    let offsetY: Double
    let distanceFromBottom: Double
}

enum NotebookRealtimeFollowPolicy {
    static let liveEdgeDistance = 72.0

    static func reconciledFollowing(
        wasFollowing: Bool,
        previous: NotebookRealtimeScrollMetrics,
        current: NotebookRealtimeScrollMetrics
    ) -> Bool {
        if current.distanceFromBottom <= liveEdgeDistance {
            return true
        }
        if current.offsetY < previous.offsetY - 1 {
            return false
        }
        // Content growth increases distance from the bottom without moving the
        // viewport. Keep following so the throttled tail scroll can catch up.
        return wasFollowing
    }
}

enum NotebookRealtimeRunPresentation {
    private static let fractionalTimestampParser: ISO8601DateFormatter = {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return parser
    }()

    private static let timestampParser: ISO8601DateFormatter = {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime]
        return parser
    }()

    static func createdAtText(for run: NotebookCaptureHistoryRunDTO) -> String {
        guard let date = fractionalTimestampParser.date(from: run.createdAt)
            ?? timestampParser.date(from: run.createdAt) else {
            return run.createdAt
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    static func durationText(for run: NotebookCaptureHistoryRunDTO) -> String {
        guard let durationMs = run.durationMs else {
            return run.capturedFrames == 0 ? "00:00" : "—"
        }
        let totalSeconds = Int(durationMs / 1_000)
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        return hours > 0
            ? String(format: "%02d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
    }
}

/// Positions recorded transcript gaps between the rows of one session, so
/// the reader sees "audio here is not transcribed yet" instead of the text
/// silently jumping across a network outage.
enum NotebookTranscriptGapPresentation {
    /// A gap anchors before the first row that begins at or after its start;
    /// a gap past the last timed row trails the transcript (the live edge).
    /// Repaired gaps have durable rows again and earn no divider.
    static func anchoredGaps(
        utterances: [NotebookCaptureUtteranceDTO],
        gaps: [NotebookTranscriptGapDTO]
    ) -> (leading: [String: [NotebookTranscriptGapDTO]], trailing: [NotebookTranscriptGapDTO]) {
        var leading: [String: [NotebookTranscriptGapDTO]] = [:]
        var trailing: [NotebookTranscriptGapDTO] = []
        for gap in gaps where gap.isRepaired == false {
            let anchor = utterances.first { utterance in
                guard let startMs = utterance.sourceStartMs else { return false }
                return startMs >= gap.startMs
            }
            if let anchor {
                leading[anchor.id, default: []].append(gap)
            } else {
                trailing.append(gap)
            }
        }
        return (leading, trailing)
    }

    /// "12:34 – 13:05" on the capture timeline, hours only when the
    /// recording has them.
    static func rangeText(for gap: NotebookTranscriptGapDTO) -> String {
        "\(positionText(ms: gap.startMs)) – \(positionText(ms: gap.endMs))"
    }

    static func positionText(ms: UInt64) -> String {
        let totalSeconds = Int(ms / 1_000)
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
    }
}

/// The horizontal rule a transcript draws where captured audio has no
/// realtime text: a line broken by the gap's position on the recording.
struct NotebookTranscriptGapDivider: View {
    let gap: NotebookTranscriptGapDTO

    var body: some View {
        HStack(spacing: Spacing.sm) {
            dividerLine
            Label(labelText, systemImage: "waveform.slash")
                .font(.caption)
                .foregroundColor(.textTertiary)
                .lineLimit(1)
                .fixedSize()
            dividerLine
        }
        .padding(.vertical, Spacing.xs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(labelText))
    }

    private var labelText: String {
        String(
            format: String(localized: "capture.transcript.gap_range_format"),
            NotebookTranscriptGapPresentation.rangeText(for: gap)
        )
    }

    private var dividerLine: some View {
        Rectangle()
            .fill(Color.borderGhost.opacity(0.5))
            .frame(height: 1)
            .frame(maxWidth: .infinity)
    }
}

/// Bridges the short interval where an auxiliary translation is already a
/// durable time-anchored cue but cannot yet be attached to one canonical row.
/// The subtitle canvas reads those cues directly; without this overlay the
/// Notebook columns can visibly trail even though both surfaces received the
/// same capture event.
enum NotebookLanguageColumnCueOverlay {
    static func latestSupplementalCues(
        languages: [String],
        utterances: [NotebookCaptureUtteranceDTO],
        cues: [NotebookCaptureTranslationCueDTO]
    ) -> [String: NotebookCaptureTranslationCueDTO] {
        var seenLanguages: Set<String> = []
        let languages = languages
            .map(normalizedLanguage)
            .filter { $0.isEmpty == false && seenLanguages.insert($0).inserted }
        var result: [String: NotebookCaptureTranslationCueDTO] = [:]

        for language in languages {
            let representedTexts = utterances
                .compactMap { $0.laneText(language: language) }
                .map(normalizedText)
                .filter { $0.isEmpty == false }
            let matchingCues = cues.filter {
                normalizedLanguage($0.targetLanguage) == language
                    && normalizedLanguage($0.sourceLanguage) != language
                    && $0.withdrawn == false
                    && normalizedText($0.text).isEmpty == false
            }
            guard let latest = matchingCues.max(by: cuePrecedes) else { continue }

            let cueText = normalizedText(latest.text)
            let isAlreadyRepresented = representedTexts.contains { text in
                text == cueText || text.contains(cueText)
            }
            if isAlreadyRepresented == false {
                result[language] = latest
            }
        }
        return result
    }

    private static func cuePrecedes(
        _ left: NotebookCaptureTranslationCueDTO,
        _ right: NotebookCaptureTranslationCueDTO
    ) -> Bool {
        if left.groupEpoch != right.groupEpoch {
            return left.groupEpoch < right.groupEpoch
        }
        if left.providerSequence != right.providerSequence {
            return left.providerSequence < right.providerSequence
        }
        return left.revision < right.revision
    }

    private static func normalizedLanguage(_ language: String) -> String {
        language
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(separator: "-")
            .first
            .map(String.init) ?? ""
    }

    private static func normalizedText(_ text: String) -> String {
        text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()
    }
}

