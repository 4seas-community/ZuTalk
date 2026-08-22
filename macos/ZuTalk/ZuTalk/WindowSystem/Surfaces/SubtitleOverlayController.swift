import AppKit
import Combine
import SwiftUI

/// Automatic is the default: the overlay travels between a desk strip and a
/// projector canvas, and the right size for one is unreadable on the other.
/// Touching any manual size control is itself the opt-out — the operator who
/// asks for a specific size has answered the question automatic exists to
/// answer, so no separate switch needs flipping.
enum SubtitleOverlayFontMode: String, CaseIterable {
    case automatic
    case manual
}

enum SubtitleOverlayFontPolicy {
    static let defaultsKey = "zutalk.subtitleOverlay.fontSize"
    static let modeDefaultsKey = "zutalk.subtitleOverlay.fontMode"
    /// The ceiling is sized for a projector canvas read from the back of a
    /// meeting room, not for a laptop panel; the slider spans the full range
    /// continuously and the step only serves the fine-tune buttons.
    static let minimum = 16.0
    static let maximum = 160.0
    static let defaultValue = 30.0
    static let step = 2.0

    static func clamped(_ value: Double) -> Double {
        min(max(value, minimum), maximum)
    }

    static func smaller(than value: Double) -> Double {
        clamped(value - step)
    }

    static func larger(than value: Double) -> Double {
        clamped(value + step)
    }

    /// Automatic sizes type to the canvas, never to the content: a projector
    /// canvas gets projector type, the desk strip keeps desk type, and words
    /// arriving never reflow what is already on screen — content-driven
    /// fitting would re-rag every visible line on every utterance, which is
    /// the one motion a live caption wall cannot afford.
    ///
    /// The height term targets roughly four visible rows. The width term
    /// keeps the selected languages viable side by side, using the same
    /// per-column coefficient the layout policy enforces (8 × font for
    /// conversation columns, 10 × font for audience tiles), and the result
    /// quantizes downward to the slider step so rounding can never push the
    /// columns past the width that was promised to fit.
    static func automatic(
        canvasSize: CGSize,
        languageCount: Int,
        mode: SubtitleOverlayDisplayMode
    ) -> Double {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return defaultValue }
        let heightBudget = Double(canvasSize.height) / 13
        let columns = Double(max(languageCount, 1))
        let perColumnFactor = mode == .audience ? 10.0 : 8.0
        // The same chrome the layout policy prices in. If automatic sized
        // type against the raw width it would pick a size that fits N columns
        // arithmetically and then watch the layout drop to N-1, which is the
        // one thing automatic exists to prevent.
        let separator = mode == .audience
            ? Double(SubtitleOverlayLayoutPolicy.audienceColumnSpacing)
            : Double(SubtitleOverlayLayoutPolicy.conversationLaneDividerWidth)
        let chrome = Double(SubtitleOverlayLayoutPolicy.canvasHorizontalPadding)
            + separator * (columns - 1)
        let widthBudget = (Double(canvasSize.width) - chrome) / (perColumnFactor * columns)
        let quantized = (min(heightBudget, widthBudget) / step).rounded(.down) * step
        return clamped(quantized)
    }

    /// A size the operator explicitly chose before automatic existed keeps
    /// ruling their venue setup; only installs with no stored size start
    /// automatic. Runs once — after this the stored mode answers directly.
    static func migrateStoredModeIfNeeded(defaults: UserDefaults) {
        guard defaults.string(forKey: modeDefaultsKey) == nil,
              defaults.object(forKey: defaultsKey) != nil
        else { return }
        defaults.set(SubtitleOverlayFontMode.manual.rawValue, forKey: modeDefaultsKey)
    }
}

enum SubtitleOverlayDisplayMode: String, CaseIterable {
    case audience
    case conversation

    static func resolved(storedRawValue: String?) -> Self {
        storedRawValue.flatMap(Self.init(rawValue:)) ?? .audience
    }
}

/// Where the overlay window sits on its display.
///
/// `filled` and `banner` are both presentation placements: the operator has
/// handed the window to a room, so it stops behaving like a window the
/// operator drags around. They differ in what the room is looking at —
/// `filled` is the whole display, `banner` is a strip across the top with the
/// slide still visible underneath.
enum SubtitleOverlayPlacement: Equatable {
    /// Operator-sized, movable and resizable.
    case restored
    /// Full display width, anchored to the top edge, height chosen by the
    /// operator and remembered.
    case banner
    /// The display's whole usable frame.
    case filled
}

/// Geometry for the banner placement.
///
/// Width is never the operator's problem: projecting onto a second display
/// used to mean dragging both edges to the screen every time. Height is,
/// because how much of the slide a caption strip may cover is a judgement
/// about the room. So the width is taken and the height is remembered.
enum SubtitleOverlayBannerMetrics {
    static let heightKey = "zutalk.subtitleOverlay.bannerHeight"

    /// Enough for two audience rows at the default type size.
    static let minimumHeight: CGFloat = 120
    static let defaultHeightFraction: CGFloat = 0.25
    /// A caption strip that covers more than half the slide is not a strip.
    static let maximumHeightFraction: CGFloat = 0.5

    static func height(in visibleFrame: NSRect, defaults: UserDefaults = .standard) -> CGFloat {
        let stored = defaults.object(forKey: heightKey) as? Double
        let preferred = stored.map { CGFloat($0) }
            ?? visibleFrame.height * defaultHeightFraction
        let ceiling = max(minimumHeight, visibleFrame.height * maximumHeightFraction)
        return min(max(preferred, minimumHeight), ceiling)
    }

    static func frame(in visibleFrame: NSRect, defaults: UserDefaults = .standard) -> NSRect {
        let height = height(in: visibleFrame, defaults: defaults)
        return NSRect(
            x: visibleFrame.minX,
            y: visibleFrame.maxY - height,
            width: visibleFrame.width,
            height: height
        ).integral
    }

    static func persistHeight(_ height: CGFloat, defaults: UserDefaults = .standard) {
        guard height.isFinite, height >= minimumHeight else { return }
        defaults.set(Double(height), forKey: heightKey)
    }
}

enum SubtitleOverlayConversationLayout: Equatable {
    case columns
    case stacked
}

enum SubtitleOverlayLayoutPolicy {
    static let maximumLanguageCount = 3
    static let maximumAudienceRowCount = 8

    /// Width the columns never get: the canvas padding on both sides, plus
    /// the separator between neighbours. Every entry point below takes the
    /// **canvas** width and subtracts this itself, so the chrome is priced in
    /// exactly once — deciding capacity from a width the padding has already
    /// spent promises a column narrower than the minimum the decision exists
    /// to guarantee, and having callers pre-subtract it invites two callers
    /// to disagree about whether they already did.
    static let canvasHorizontalPadding: CGFloat = 24
    static let audienceColumnSpacing: CGFloat = 8
    static let conversationLaneDividerWidth: CGFloat = 1

    /// Width actually available to `count` audience tiles on this canvas.
    static func audienceContentWidth(width: CGFloat, columns: Int) -> CGFloat {
        width - canvasHorizontalPadding
            - audienceColumnSpacing * CGFloat(max(columns - 1, 0))
    }

    /// Width actually available to `lanes` conversation lanes on this canvas.
    static func conversationContentWidth(width: CGFloat, lanes: Int) -> CGFloat {
        width - canvasHorizontalPadding
            - conversationLaneDividerWidth * CGFloat(max(lanes - 1, 0))
    }

    static func conversationLayout(
        width: CGFloat,
        languageCount: Int,
        fontSize: Double
    ) -> SubtitleOverlayConversationLayout {
        let lanes = max(languageCount, 1)
        return conversationContentWidth(width: width, lanes: lanes)
            >= minimumColumnWidth(fontSize: fontSize) * CGFloat(lanes)
            ? .columns
            : .stacked
    }

    /// How many audience tiles fit side by side, degrading **one column at a
    /// time**.
    ///
    /// Three languages on a canvas that affords only two used to collapse
    /// straight to a single column, which the band layout then renders as
    /// three full-width bands stacked vertically. To the room that reads as
    /// "the languages stopped lining up", triggered by a canvas that was only
    /// marginally too narrow — and it flips back and forth across a single
    /// point of window width or one step of the font slider. Two columns plus
    /// one is the honest degradation: it keeps as much side-by-side reading
    /// as the canvas can actually pay for.
    static func audienceColumnCount(
        width: CGFloat,
        languageCount: Int,
        fontSize: Double
    ) -> Int {
        let count = min(max(languageCount, 1), maximumLanguageCount)
        let tile = minimumAudienceTileWidth(fontSize: fontSize)
        var fits = 1
        while fits < count,
              audienceContentWidth(width: width, columns: fits + 1)
                >= tile * CGFloat(fits + 1) {
            fits += 1
        }
        return fits
    }

    /// Audience retention is canvas-driven: the row count is whatever the box
    /// affords at the current font size — a squat strip carries a single live
    /// line, a stretched canvas keeps more finished rows on screen. Bounded
    /// above only so an ultra-tall canvas never turns into a scrollback log.
    static func audienceRowCount(height: CGFloat, fontSize: Double) -> Int {
        let estimatedRowHeight = max(CGFloat(fontSize) * 3.2, 1)
        return min(maximumAudienceRowCount, max(1, Int(height / estimatedRowHeight)))
    }

    /// Conversation retention is canvas-driven for the same reason audience
    /// retention is: the transcript keeps as many finished rows as the box
    /// affords at the current font, so a projector canvas fills with history
    /// instead of pinning a fixed handful of rows under a third of permanently
    /// blank canvas. Floored at the old constant four so the desk strip keeps
    /// its scrollback, and capped so an ultra-tall canvas stays a subtitle
    /// wall rather than a scrollback log.
    static func conversationRowCount(
        height: CGFloat,
        fontSize: Double,
        lanesPerRow: Int
    ) -> Int {
        let laneHeight = CGFloat(fontSize) * 2.35 + 28
        let rowHeight = laneHeight * CGFloat(max(lanesPerRow, 1)) + 10
        return min(12, max(4, Int(height / max(rowHeight, 1))))
    }

    static func minimumColumnWidth(fontSize: Double) -> CGFloat {
        max(240, CGFloat(fontSize * 8))
    }

    static func minimumAudienceTileWidth(fontSize: Double) -> CGFloat {
        max(340, CGFloat(fontSize * 10))
    }

    /// When the canvas is too narrow for every language side by side, the
    /// languages stack as bands — and each band must own an equal,
    /// bottom-anchored slice of the canvas. Without the slice, band heights
    /// are content-driven: five minutes of speech makes every band taller
    /// than the canvas, the outer bottom-aligned clip keeps only the last
    /// band, and every other language's newest words silently leave the
    /// screen. A tall band now clips its own history instead of evicting
    /// the languages above it.
    ///
    /// Floored at roughly one short card so an absurdly small canvas
    /// degrades to the outer clip rather than zero-height bands.
    static func audienceBandHeight(
        canvasHeight: CGFloat,
        bandCount: Int,
        reservesUnroutedStrip: Bool,
        fontSize: Double
    ) -> CGFloat {
        let bands = CGFloat(max(bandCount, 1))
        let verticalPadding: CGFloat = 24
        let interBandSpacing: CGFloat = 8 * (bands - 1)
        let unroutedReservation: CGFloat =
            reservesUnroutedStrip ? CGFloat(fontSize) * 2.4 + 8 : 0
        let available = canvasHeight - verticalPadding - interBandSpacing - unroutedReservation
        let slice = available / bands
        let minimumCard = CGFloat(fontSize) * 2.6
        return max(slice, minimumCard)
    }
}

/// What the overlay's scrolling modes watch to decide "the tail moved".
///
/// Row identity alone is not enough: one Soniox utterance grows hundreds of
/// times before a new row id appears, and each growth is what pushes the live
/// edge below the fold. Row *count* is not enough either — the overlay renders
/// a canvas-sized suffix, so a new row arriving and an old one aging out leaves
/// the count unchanged.
struct SubtitleOverlayFollowSignal: Equatable {
    let tailID: String
    let rowCount: Int
    let textExtent: Int
}

/// Whether the overlay's transcript is still tracking the live edge.
///
/// This is the same question `NotebookRealtimeFollowPolicy` answers for the
/// main transcript page, but the overlay cannot reuse that answer: the main
/// page renders the whole run, so its content only ever grows, and it reads a
/// shrinking offset as "the operator dragged up". The overlay renders a
/// canvas-sized suffix, so rows age off the top constantly and the scroll view
/// clamps the offset down on its own. Under the main page's policy that clamp
/// reads as an operator gesture, following stops, and the canvas parks itself
/// mid-transcript — which is the failure this policy exists to prevent.
///
/// Content height therefore participates in the decision: an offset that falls
/// while the content also shrank is the scroll view catching up to its own
/// trimmed content, not a person reaching for the scrollbar.
enum SubtitleOverlayFollowPolicy {
    /// Generous next to the main page's 72 pt: overlay rows are audience-sized,
    /// so a single row can be taller than the whole desk-strip viewport and
    /// landing "at the bottom" still leaves a large residual.
    static let liveEdgeDistance = 120.0

    static func reconciledFollowing(
        wasFollowing: Bool,
        previous: SubtitleOverlayScrollMetrics,
        current: SubtitleOverlayScrollMetrics
    ) -> Bool {
        if current.distanceFromBottom <= liveEdgeDistance {
            return true
        }
        // The suffix dropped a row: whatever the offset did, it was the scroll
        // view reacting to content it no longer has, not an operator gesture.
        if current.contentHeight < previous.contentHeight - 1 {
            return wasFollowing
        }
        if current.offsetY < previous.offsetY - 1 {
            return false
        }
        // Content growth increases distance from the bottom without moving the
        // viewport. Keep following so the throttled tail scroll can catch up.
        return wasFollowing
    }
}

struct SubtitleOverlayScrollMetrics: Equatable {
    let offsetY: Double
    let distanceFromBottom: Double
    let contentHeight: Double
}

/// The multilingual audience canvas as per-language tracks on one shared
/// capture timeline — the caption-format shape (WebVTT/TTML: one track per
/// language, cues anchored to time, no cross-track binding).
///
/// A column holds the source lines placed in its language plus the
/// translation cues targeting it, each in its own segmentation. Columns do
/// not row-align: every column bottom-anchors, so "now" is the bottom edge
/// of every column and cross-language correspondence holds exactly where the
/// audience is reading. History above may drift out of row alignment; the
/// standing invariant already prefers the present over the past.
enum SubtitleAudienceTimeline {
    struct Item: Identifiable, Equatable {
        enum Kind: Equatable {
            case source
            case translation
        }

        let id: String
        let kind: Kind
        let text: String
        /// Capture-timeline start of the words this item covers. Translation
        /// items inherit their segment's source-token range — translation
        /// tokens themselves carry no provider timestamps.
        let anchorMs: UInt64?
        /// Capture-timeline end of the covered words. Coverage, not start,
        /// is what decides whether a column is behind: a coarse translation
        /// segment can START rows before the newest speech and still cover
        /// it entirely.
        let endMs: UInt64?
        /// A lower bound for an item the provider never timed: the coverage of
        /// the nearest earlier item from its own stream. Sorting only. It is a
        /// true statement ("not spoken before this"), not a measurement, so it
        /// must never reach the coverage arithmetic — a lane carried entirely
        /// by inherited bounds would read as caught up and the waiting
        /// ellipsis would never appear again.
        let inheritedAnchorMs: UInt64?
        /// Provider order, the tiebreak within one stream's own output.
        let order: UInt64
        /// A final source line bypasses the visual refresh budget so the
        /// audience never leaves the last correction buffered off-screen.
        let isComplete: Bool
    }

    /// Spoken order: anchored items by time, source before its own translation
    /// on a tie. An item the provider never timed does not fall to the end of
    /// its column; it inherits the coverage of the nearest earlier item from
    /// its own stream and sorts there.
    ///
    /// Timestamps restart when a whole stream group restarts, so ordering
    /// across a restart leans on the fact that old-epoch items leave the
    /// visible suffix almost immediately.
    ///
    /// `inheritedSourceAnchors` maps an utterance id to that lower bound. It is
    /// supplied by the caller rather than derived here because the audience
    /// canvas is fed a pruned candidate set: a bound computed from whatever
    /// rows survived pruning is not the bound computed from the whole session,
    /// and the bounded and full projections must stay presentation-equivalent.
    /// Cues need no such argument — their lane is never pruned before it
    /// arrives here.
    static func columns(
        languages: [String],
        utterances: [NotebookCaptureUtteranceDTO],
        placement: (NotebookCaptureUtteranceDTO) -> String?,
        cues: (String) -> [NotebookCaptureTranslationCueDTO],
        inheritedSourceAnchors: [String: UInt64] = [:],
        visibleLimit: Int? = nil
    ) -> [String: [Item]] {
        var columns: [String: [Item]] = [:]
        var coverageLeaders: [String: Item] = [:]
        for language in languages {
            columns[language] = []
        }

        func retain(_ item: Item, in language: String) {
            guard columns[language] != nil else { return }
            if let coverage = item.endMs ?? item.anchorMs {
                let existingCoverage = coverageLeaders[language]
                    .flatMap { $0.endMs ?? $0.anchorMs }
                if existingCoverage.map({ coverage > $0 }) ?? true {
                    coverageLeaders[language] = item
                }
            }
            columns[language]?.append(item)
            guard let visibleLimit else { return }
            let limit = max(visibleLimit, 0)
            columns[language]?.sort(by: itemComesBefore)
            if let count = columns[language]?.count, count > limit {
                columns[language]?.removeFirst(count - limit)
            }
        }

        for utterance in utterances {
            guard let language = placement(utterance),
                  columns[language] != nil
            else { continue }
            var inheritedSourceAnchorMs: UInt64?
            if utterance.sourceStartMs == nil {
                inheritedSourceAnchorMs = inheritedSourceAnchors[utterance.id]
            }
            retain(Item(
                id: "source:\(utterance.id)",
                kind: .source,
                text: utterance.sourceText,
                anchorMs: utterance.sourceStartMs,
                endMs: utterance.sourceEndMs,
                inheritedAnchorMs: inheritedSourceAnchorMs,
                order: utterance.sequence,
                isComplete: utterance.completion == "complete"
            ), in: language)
        }
        for language in languages {
            let languageCues = cues(language)
            let latestTimedCue = languageCues
                .filter { $0.sourceStartMs != nil }
                .max { left, right in
                    if left.groupEpoch != right.groupEpoch {
                        return left.groupEpoch < right.groupEpoch
                    }
                    return left.providerSequence < right.providerSequence
                }
            for cue in languageCues where cue.text.isEmpty == false {
                // A cue that "translates" its own language would double the
                // source line; providers do not emit these, and one arriving
                // anyway must not duplicate the column.
                guard cue.sourceLanguage != cue.targetLanguage else { continue }
                // Missing provider timestamps must not make an early cue sort
                // after every later timed cue forever. Provider sequence is
                // authoritative inside this target stream, so a later timed
                // sibling retires an older unanchored presentation item.
                if cue.sourceStartMs == nil,
                   let latestTimedCue,
                   cue.groupEpoch < latestTimedCue.groupEpoch
                    || (cue.groupEpoch == latestTimedCue.groupEpoch
                        && cue.providerSequence < latestTimedCue.providerSequence) {
                    continue
                }
                // The survivor of the retirement rule above is the newest cue
                // this lane has, so the newest timed sibling's coverage is its
                // lower bound. That still places it last in the lane, as an
                // unanchored head always was — but now behind that sibling by
                // a stated fact rather than by having no time at all.
                var inheritedCueAnchorMs: UInt64?
                if cue.sourceStartMs == nil, let latestTimedCue {
                    inheritedCueAnchorMs = latestTimedCue.sourceEndMs
                        ?? latestTimedCue.sourceStartMs
                }
                retain(Item(
                    id: "cue:\(cue.id)",
                    kind: .translation,
                    text: cue.text,
                    anchorMs: cue.sourceStartMs,
                    endMs: cue.sourceEndMs,
                    inheritedAnchorMs: inheritedCueAnchorMs,
                    order: cue.providerSequence,
                    isComplete: cue.completion == "complete"
                ), in: language)
            }
        }
        for language in languages {
            // A bounded visible suffix is enough to paint the column, but the
            // waiting calculation below also needs the greatest coverage ever
            // seen in that lane. Retain that one extra item when it fell
            // outside the suffix; the caller trims it after asking whether the
            // lane is behind. This keeps the bounded and full projections
            // presentation-equivalent even across timestamp restarts.
            if let visibleLimit,
               visibleLimit > 0,
               let coverageLeader = coverageLeaders[language],
               columns[language]?.contains(where: { $0.id == coverageLeader.id }) == false {
                columns[language]?.append(coverageLeader)
            }
            columns[language]?.sort(by: itemComesBefore)
        }
        return columns
    }

    nonisolated private static func itemComesBefore(_ left: Item, _ right: Item) -> Bool {
        let leftAnchor = left.anchorMs ?? left.inheritedAnchorMs
        let rightAnchor = right.anchorMs ?? right.inheritedAnchorMs
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
            if (left.anchorMs == nil) != (right.anchorMs == nil) {
                return right.anchorMs == nil
            }
            switch (left.kind, right.kind) {
            case (.source, .translation):
                return true
            case (.translation, .source):
                return false
            default:
                return left.order < right.order
            }
        }
    }

    /// Columns whose coverage trails the newest spoken words. The waiting
    /// placeholder keeps the lane visibly alive instead of letting an absent
    /// column read as "this language is broken".
    ///
    /// Behind means "covers less", not "starts earlier": the auxiliary
    /// streams segment on their own boundaries, so a coarse translation
    /// segment can start rows before the newest speech and still cover it
    /// entirely — comparing starts would pin a perpetual ellipsis on a
    /// column whose text is fully current.
    ///
    /// A lane whose stream died is never "waiting": the ellipsis is a promise
    /// that words are coming, and for a dead lane that promise is false. Its
    /// column simply stops, and the operator — not the audience — is told why.
    static func waitingLanguages(
        columns: [String: [Item]],
        failedLanguages: Set<String> = []
    ) -> Set<String> {
        let newestSpokenEnd = columns.values
            .joined()
            .filter { $0.kind == .source }
            .compactMap { $0.endMs ?? $0.anchorMs }
            .max()
        guard let newestSpokenEnd else { return [] }
        var waiting: Set<String> = []
        for (language, items) in columns where !failedLanguages.contains(language) {
            let covered = items
                .compactMap { $0.endMs ?? $0.anchorMs }
                .max() ?? 0
            if covered < newestSpokenEnd {
                waiting.insert(language)
            }
        }
        return waiting
    }

    /// The newest line no column claims — an unselected known language, or a
    /// line whose identity is still pending with no usable hint. Spoken words
    /// must appear, so the strip keeps showing an unplaced line for as long
    /// as it would still sit in the visible tail — a French interjection must
    /// not vanish the instant the next Chinese sentence lands. Beyond that
    /// window it ages out exactly like every placed line does.
    static func unroutedText(
        utterances: [NotebookCaptureUtteranceDTO],
        placement: (NotebookCaptureUtteranceDTO) -> String?,
        window: Int = 1
    ) -> String? {
        let tail: [NotebookCaptureUtteranceDTO] = Array(utterances.suffix(max(window, 1)))
        for utterance in tail.reversed() {
            guard utterance.hasSourceLane,
                  utterance.sourceText.isEmpty == false,
                  placement(utterance) == nil
            else { continue }
            return utterance.sourceText
        }
        return nil
    }
}

/// Conversation keeps its durable row history, but its live edge follows the
/// same independent language tracks as audience mode. The newest source row is
/// removed from row history and represented here together with the newest cue
/// from every target stream. A cue therefore becomes visible without first
/// acquiring a canonical-row binding, and one late stream cannot hold back a
/// sibling that has already produced words.
enum SubtitleConversationTimeline {
    /// One row becomes the independent live edge and one more row leaves room
    /// for an unrouted source line. Conversation never needs the full session
    /// to render a canvas-sized suffix.
    static let utteranceLookbackAllowance = 2

    struct Projection: Equatable {
        let historicalUtterances: [NotebookCaptureUtteranceDTO]
        let unroutedLiveUtterance: NotebookCaptureUtteranceDTO?
        let liveLanes: [NotebookCaptureLanguageLane]

        var hasLiveWords: Bool {
            liveLanes.contains { $0.text?.isEmpty == false }
        }

        var hasContent: Bool {
            historicalUtterances.isEmpty == false
                || unroutedLiveUtterance != nil
                || hasLiveWords
        }
    }

    static func projection(
        languages: [String],
        utterances: [NotebookCaptureUtteranceDTO],
        placement: (NotebookCaptureUtteranceDTO) -> String?,
        cues: (String) -> [NotebookCaptureTranslationCueDTO],
        failedLanguages: Set<String> = []
    ) -> Projection {
        let languages = Array(
            languages.prefix(SubtitleOverlayLayoutPolicy.maximumLanguageCount)
        )
        // Conversation is handed the suffix it renders, so that suffix is the
        // whole input this projection has; there is no pruning step upstream to
        // take the bounds from instead.
        let columns = SubtitleAudienceTimeline.columns(
            languages: languages,
            utterances: utterances,
            placement: placement,
            cues: cues,
            inheritedSourceAnchors: NotebookCaptureLivePresentation.inheritedSourceAnchors(
                durable: utterances,
                sessionId: nil
            )
        )
        let waitingLanguages = SubtitleAudienceTimeline.waitingLanguages(
            columns: columns,
            failedLanguages: failedLanguages
        )

        // `presentedUtterances` is already in source order. Only its newest
        // source-bearing row belongs to the replaceable live edge; all older
        // rows retain their established row/variant presentation.
        let liveUtterance = utterances.last(where: {
            $0.hasSourceLane && $0.sourceText.isEmpty == false
        })
        let historicalUtterances: [NotebookCaptureUtteranceDTO]
        if let liveUtterance {
            historicalUtterances = utterances.filter { $0.id != liveUtterance.id }
        } else {
            historicalUtterances = utterances
        }
        let unroutedLiveUtterance = liveUtterance.flatMap { utterance in
            placement(utterance) == nil ? utterance : nil
        }

        let liveLanes = languages.map { language in
            let liveSourceItemID = liveUtterance.map { "source:\($0.id)" }
            let liveSourceText = columns[language]?.last(where: { item in
                item.kind == .source && item.id == liveSourceItemID
            })?.text
            // `waiting` describes how far a lane has processed; it must never
            // hide words already delivered. Only a translation whose explicit
            // coverage ends before the live source even starts is historical.
            // A partial covering [0, 4500] while source is [0, 5000] is useful
            // live text, and an unanchored provider head is displayed at once.
            let liveSourceStart = liveUtterance?.sourceStartMs
            let translationText = failedLanguages.contains(language)
                ? nil
                : columns[language]?.last(where: { item in
                    guard item.kind == .translation else { return false }
                    guard let liveSourceStart,
                          let coveredThrough = item.endMs ?? item.anchorMs
                    else { return true }
                    return coveredThrough >= liveSourceStart
                })?.text
            // A source item is live only when it belongs to the newest
            // source-bearing utterance. Older source rows remain exclusively
            // in history and can never masquerade as another language's
            // current translation. Actual spoken words still win if that
            // language's auxiliary stream happens to be failed.
            let text = liveSourceText ?? translationText
            let missingState: NotebookCaptureMissingLaneState
            if failedLanguages.contains(language) {
                missingState = .failed
            } else if waitingLanguages.contains(language) {
                missingState = .waiting
            } else {
                missingState = .unavailable
            }
            return NotebookCaptureLanguageLane(
                language: language,
                text: text,
                missingLaneState: missingState
            )
        }

        return Projection(
            historicalUtterances: historicalUtterances,
            unroutedLiveUtterance: unroutedLiveUtterance,
            liveLanes: liveLanes
        )
    }
}

/// Paces a translation card's text onto the screen at reading speed instead of
/// painting each provider batch as one slab.
///
/// Translations arrive in mouthfuls — measured p50 15 tokens per batch, p50
/// 1.4 s between batches — because the provider needs source context before it
/// can translate at all. The gap between mouthfuls is idle screen time; the
/// reveal cursor spends exactly that time walking through the buffered text,
/// so the column reads as flowing words while adding only bounded latency.
///
/// The unrevealed tail is also a free mask: a provider rewrite that lands
/// beyond the cursor was never on screen, so it costs zero visible erasure —
/// masking priced in idle time instead of MeetDot's constant four words or the
/// 4-second lag Google pays for erasure 0.1.
enum SubtitlePacedReveal {
    struct State: Equatable {
        /// Fractional so per-tick advances below one character accumulate.
        var revealedChars: Double = 0

        func revealedPrefix(of text: String) -> String {
            let whole = Int(revealedChars)
            if whole >= text.count { return text }
            return String(text.prefix(whole))
        }
    }

    /// Dense scripts (CJK, Thai) carry a word per character or two and are
    /// read at far fewer characters per second than spaced Latin text.
    enum Script {
        case dense
        case spaced
    }

    /// Base rates hold a column legible; the adaptive term above them exists
    /// to drain a measured-size backlog inside one measured batch gap
    /// (~90 Latin / ~25 dense chars per mouthful, ~1.4 s to the next one).
    static func characterRate(script: Script, backlogChars: Int) -> Double {
        let (base, halfway): (Double, Double) = switch script {
        case .dense: (13, 20)
        case .spaced: (40, 60)
        }
        return base * (1 + Double(max(backlogChars, 0)) / halfway)
    }

    /// Beyond four mouthfuls of backlog (a reconnect flood, not live speech),
    /// pacing would turn into visible lag; the cursor snaps forward instead.
    static func snapBacklogLimit(script: Script) -> Int {
        switch script {
        case .dense: 100
        case .spaced: 360
        }
    }

    static func script(for text: String) -> Script {
        var dense = 0
        var scored = 0
        for scalar in text.unicodeScalars {
            guard scalar.properties.isAlphabetic else { continue }
            scored += 1
            switch scalar.value {
            case 0x2E80...0x9FFF,       // CJK radicals through unified ideographs
                 0x3040...0x30FF,       // kana
                 0xF900...0xFAFF,       // compatibility ideographs
                 0x0E00...0x0E7F:       // Thai
                dense += 1
            default:
                break
            }
        }
        guard scored > 0 else { return .spaced }
        return dense * 2 >= scored ? .dense : .spaced
    }

    /// A text change keeps every already-revealed character that survived and
    /// never re-reveals what the reader has seen: appends and beyond-cursor
    /// rewrites leave the cursor alone; a rewrite that reaches under the
    /// cursor snaps it back to the surviving prefix so the correction shows
    /// immediately instead of replaying the whole card.
    static func reconcile(state: State, oldText: String, newText: String) -> State {
        var state = state
        let survivingPrefix = zip(oldText, newText)
            .prefix(while: { $0 == $1 })
            .count
        if state.revealedChars > Double(survivingPrefix) {
            state.revealedChars = Double(survivingPrefix)
        }
        return state
    }

    static func advance(state: State, elapsedSeconds: Double, text: String) -> State {
        var state = state
        let total = Double(text.count)
        guard state.revealedChars < total else {
            state.revealedChars = total
            return state
        }
        let script = script(for: text)
        let backlog = Int(total - state.revealedChars)
        if backlog > snapBacklogLimit(script: script) {
            state.revealedChars = total - Double(snapBacklogLimit(script: script))
        }
        let rate = characterRate(script: script, backlogChars: backlog)
        state.revealedChars = min(total, state.revealedChars + rate * elapsedSeconds)
        return state
    }
}

/// The canonical preview can revise several times a second. The audience
/// needs the newest words, not every intermediate hypothesis: partials share
/// one trailing-edge refresh while a Final bypasses the budget immediately.
enum SubtitleAudienceSourceRefresh {
    static let interval: Duration = .milliseconds(250)

    struct Update: Equatable {
        let text: String
        let isComplete: Bool
    }

    struct State: Equatable {
        private(set) var displayedText: String
        private(set) var pendingText: String

        init(text: String) {
            displayedText = text
            pendingText = text
        }

        mutating func receive(_ update: Update) {
            pendingText = update.text
            if update.isComplete {
                displayedText = update.text
            }
        }

        mutating func flush() {
            displayedText = pendingText
        }
    }
}

/// Side table keeping each card's reveal progress across view re-creation.
/// Not observable on purpose: cards render from their own @State, and
/// publishing every 33 ms tick would re-render every column.
@MainActor
final class AudienceRevealMemory {
    private var progress: [String: (state: SubtitlePacedReveal.State, text: String)] = [:]

    func recall(_ id: String) -> (state: SubtitlePacedReveal.State, text: String)? {
        progress[id]
    }

    func store(_ id: String, state: SubtitlePacedReveal.State, text: String) {
        progress[id] = (state, text)
    }

    /// Cards fall off the visible suffix as the session grows; their cursors
    /// go with them so a long meeting cannot accumulate one entry per cue.
    func prune(keeping visible: Set<String>) {
        guard progress.count > visible.count else { return }
        progress = progress.filter { visible.contains($0.key) }
    }
}

/// Drives `SubtitlePacedReveal` at caption frame rate. The task restarts on
/// every text revision: reconcile decides what the cursor keeps, then the
/// loop walks the remainder out at reading speed and ends when the card is
/// fully revealed — an idle card costs no timer.
private struct AudiencePacedText: View {
    let id: String
    let text: String
    let fontSize: Double
    let memory: AudienceRevealMemory

    @State private var reveal: SubtitlePacedReveal.State
    @State private var revealedText: String
    @State private var lastText: String

    init(
        id: String,
        text: String,
        fontSize: Double,
        startsRevealed: Bool,
        memory: AudienceRevealMemory
    ) {
        self.id = id
        self.text = text
        self.fontSize = fontSize
        self.memory = memory
        // A card the memory already knows resumes exactly where it was —
        // a layout rebuild is not a reason to replay words at the room.
        let seed = memory.recall(id) ?? (
            state: SubtitlePacedReveal.State(
                revealedChars: startsRevealed ? Double(text.count) : 0
            ),
            text: text
        )
        _reveal = State(initialValue: seed.state)
        _revealedText = State(initialValue: seed.state.revealedPrefix(of: seed.text))
        _lastText = State(initialValue: seed.text)
    }

    var body: some View {
        Text(revealedText)
            .font(.system(size: CGFloat(fontSize), weight: .semibold))
            .foregroundColor(.primary)
            .textSelection(.enabled)
            .multilineTextAlignment(.leading)
            .task(id: text) {
                reveal = SubtitlePacedReveal.reconcile(
                    state: reveal,
                    oldText: lastText,
                    newText: text
                )
                lastText = text
                revealedText = reveal.revealedPrefix(of: text)
                memory.store(id, state: reveal, text: text)
                while !Task.isCancelled, Int(reveal.revealedChars) < text.count {
                    try? await Task.sleep(for: .milliseconds(33))
                    if Task.isCancelled { return }
                    reveal = SubtitlePacedReveal.advance(
                        state: reveal,
                        elapsedSeconds: 0.033,
                        text: text
                    )
                    revealedText = reveal.revealedPrefix(of: text)
                    memory.store(id, state: reveal, text: text)
                }
            }
    }
}

/// Coalesces high-frequency hypotheses onto a trailing-edge budget without
/// animating the whole text block. A 180 ms opacity transition restarted by
/// every Chinese partial produced overlapping snapshots — the visible ghosting
/// reported by users.
///
/// Styling belongs to the caller: this view owns *when* the words change, never
/// how they look, so the audience cards and the conversation lanes can share
/// one budget while keeping their own type.
private struct StableRefreshText: View {
    let update: SubtitleAudienceSourceRefresh.Update

    @State private var refresh: SubtitleAudienceSourceRefresh.State
    @State private var scheduledFlush: Task<Void, Never>?

    init(text: String, isComplete: Bool) {
        update = SubtitleAudienceSourceRefresh.Update(
            text: text,
            isComplete: isComplete
        )
        _refresh = State(initialValue: SubtitleAudienceSourceRefresh.State(text: text))
    }

    var body: some View {
        Text(refresh.displayedText)
            .transaction { transaction in
                transaction.animation = nil
            }
            .onChange(of: update) { _, value in
                receive(value)
            }
            .onDisappear {
                scheduledFlush?.cancel()
                scheduledFlush = nil
            }
    }

    private func receive(_ value: SubtitleAudienceSourceRefresh.Update) {
        refresh.receive(value)
        if value.isComplete {
            scheduledFlush?.cancel()
            scheduledFlush = nil
        } else {
            scheduleFlushIfNeeded()
        }
    }

    private func scheduleFlushIfNeeded() {
        guard scheduledFlush == nil else { return }
        scheduledFlush = Task { @MainActor in
            try? await Task.sleep(for: SubtitleAudienceSourceRefresh.interval)
            // Clearing the handle on the cancelled path too: a handle left
            // behind reads as "a flush is already scheduled" and would retire
            // the budget for the rest of this view's life.
            guard Task.isCancelled == false else {
                scheduledFlush = nil
                return
            }
            refresh.flush()
            scheduledFlush = nil
        }
    }
}

private struct AudienceStableSourceText: View {
    let text: String
    let isComplete: Bool
    let fontSize: Double

    var body: some View {
        StableRefreshText(text: text, isComplete: isComplete)
            .font(.system(size: CGFloat(fontSize), weight: .semibold))
            .foregroundColor(.primary)
            .textSelection(.enabled)
            .multilineTextAlignment(.leading)
    }
}

/// The overlay paints a plain color instead of a blurred material.
///
/// A backdrop blur makes the compositor re-run a CoreImage effect over
/// whatever sits behind the window every time the canvas is dirtied. This
/// canvas floats above a live meeting and is dirtied by every transcript
/// revision, so the blur can never be cached — the work lands on the
/// WindowServer main thread and stalls the whole display pipeline, not just
/// this app. Alpha-blending a uniform color gives the audience a view through
/// to the shared screen without bringing that expensive blur path back.
///
/// Hairlines follow the same constraint: white-on-material disappears against
/// the light canvas, so they resolve through the semantic separator color.
enum SubtitleOverlayPalette {
    static let surface = Color(nsColor: .windowBackgroundColor)
    static let hairline = Color(nsColor: .separatorColor)
}

/// Light and dark are an explicit operator choice rather than a mirror of the
/// system appearance: the canvas is read off a projector in a room whose
/// lighting has nothing to do with how this Mac is themed, and a meeting that
/// starts in daylight should not have its subtitles invert at sunset. Dark is
/// the default because a bright panel washes out a projected room.
///
/// The choice resolves through the window's `NSAppearance` rather than by
/// hardcoding colors, so the surface, hairlines, and text all resolve as a
/// matched set — forcing a dark fill while the text stayed system-light would
/// leave the words unreadable, which is the one failure this canvas cannot
/// afford.
enum SubtitleOverlayTheme: String, CaseIterable {
    case dark
    case light

    static let defaultsKey = "zutalk.subtitleOverlay.theme"

    var appearance: NSAppearance? {
        NSAppearance(named: self == .dark ? .darkAqua : .aqua)
    }

    var colorScheme: ColorScheme {
        self == .dark ? .dark : .light
    }

    var toggled: SubtitleOverlayTheme {
        self == .dark ? .light : .dark
    }
}

/// Keeps the shared screen visible while retaining enough contrast for text.
/// The operator can tune a plain-color alpha blend for the surface behind the
/// captions; the glyphs never inherit this opacity. The hover bar is denser so
/// controls remain legible over both captions and shared content. macOS'
/// Reduce Transparency preference always restores an opaque canvas.
enum SubtitleOverlayBackdropPolicy {
    static let defaultsKey = "zutalk.subtitleOverlay.backgroundOpacity"
    static let minimumOpacity = 0.50
    static let maximumOpacity = 0.90
    static let defaultOpacity = 0.60
    static let controlBarOpacity = 0.94
    static let opacityRange = minimumOpacity...maximumOpacity

    static func canvasOpacity(
        storedOpacity: Double,
        reduceTransparency: Bool
    ) -> Double {
        guard reduceTransparency == false else { return 1 }
        return min(max(storedOpacity, minimumOpacity), maximumOpacity)
    }

    static func controlsOpacity(reduceTransparency: Bool) -> Double {
        reduceTransparency ? 1 : controlBarOpacity
    }
}

enum SubtitleOverlayWindowPolicy {
    static let pinnedDefaultsKey = "zutalk.subtitleOverlay.isPinned"

    static func level(isPinned: Bool) -> NSWindow.Level {
        isPinned ? .floating : .normal
    }

    static func collectionBehavior(isPinned: Bool) -> NSWindow.CollectionBehavior {
        isPinned
            ? [.canJoinAllSpaces, .fullScreenAuxiliary]
            : [.moveToActiveSpace, .fullScreenAuxiliary]
    }

    /// A screen-filling canvas must stay on the Space where the operator
    /// expanded it. Reusing the pinned all-Spaces behavior here would cover
    /// every desktop on that display with a full-size panel.
    static let maximizedCollectionBehavior: NSWindow.CollectionBehavior = [
        .moveToActiveSpace,
        .fullScreenAuxiliary,
    ]
}

@MainActor
final class SubtitleOverlayPresentationSettings: ObservableObject {
    static let shared = SubtitleOverlayPresentationSettings()

    @Published private(set) var isPinned: Bool
    @Published var displayMode: SubtitleOverlayDisplayMode {
        didSet {
            UserDefaults.standard.set(
                displayMode.rawValue,
                forKey: Self.displayModeDefaultsKey
            )
        }
    }

    @Published var theme: SubtitleOverlayTheme {
        didSet {
            UserDefaults.standard.set(
                theme.rawValue,
                forKey: SubtitleOverlayTheme.defaultsKey
            )
        }
    }

    private static let displayModeDefaultsKey = "zutalk.subtitleOverlay.displayMode"

    private init(defaults: UserDefaults = .standard) {
        SubtitleOverlayFontPolicy.migrateStoredModeIfNeeded(defaults: defaults)
        if defaults.object(forKey: SubtitleOverlayWindowPolicy.pinnedDefaultsKey) == nil {
            isPinned = true
        } else {
            isPinned = defaults.bool(forKey: SubtitleOverlayWindowPolicy.pinnedDefaultsKey)
        }
        displayMode = SubtitleOverlayDisplayMode.resolved(
            storedRawValue: defaults.string(forKey: Self.displayModeDefaultsKey)
        )
        theme = defaults.string(forKey: SubtitleOverlayTheme.defaultsKey)
            .flatMap(SubtitleOverlayTheme.init(rawValue:))
            ?? .dark
    }

    func togglePinned(defaults: UserDefaults = .standard) {
        isPinned.toggle()
        defaults.set(isPinned, forKey: SubtitleOverlayWindowPolicy.pinnedDefaultsKey)
    }
}

struct SubtitleOverlayView: View {
    @ObservedObject var store: ActiveBilingualTranscriptStore
    @ObservedObject private var livePresentation: NotebookCaptureLivePresentationStore
    @ObservedObject private var coordinator = SubtitleOverlayCoordinator.shared
    @ObservedObject private var presentationSettings = SubtitleOverlayPresentationSettings.shared
    // 观看端分支的数据源:别人房间里的远端预览帧。本机没在录而人在房间里
    // 时,画布切到它 —— 同一扇窗、同一套主题与字号,只有内容来源不同。
    @ObservedObject private var shareActivity = ShareActivityStore.shared
    @Environment(\.accessibilityReduceTransparency)
    private var accessibilityReduceTransparency
    @AppStorage(SubtitleOverlayBackdropPolicy.defaultsKey)
    private var storedBackdropOpacity = SubtitleOverlayBackdropPolicy.defaultOpacity
    @AppStorage(SubtitleOverlayFontPolicy.defaultsKey)
    private var storedFontSize = SubtitleOverlayFontPolicy.defaultValue
    @AppStorage(SubtitleOverlayFontPolicy.modeDefaultsKey)
    private var storedFontMode = SubtitleOverlayFontMode.automatic
    // The canvas size feeds the automatic font, and the control bar lives
    // outside the content's GeometryReader, so the size passes through view
    // state instead of a geometry parameter.
    @State private var canvasSize = CGSize.zero
    @State private var isHoveringOverlay = false
    // Reveal cursors live outside view identity: a resize across a
    // column-count threshold or a font step rebuilds the band structure and
    // with it every column view, and per-view state would replay the live
    // card's reveal from zero each time. The reference itself is stable
    // @State; the class is deliberately not observable — each card's own
    // @State drives its rendering, this is only where progress survives.
    @State private var revealMemory = AudienceRevealMemory()
    // The scrolling modes follow the live edge. `defaultScrollAnchor(.bottom)`
    // alone only places the *initial* offset, so a transcript whose content
    // height moves — a long language wrapping to four lines, then aging out of
    // the canvas-sized suffix — left the viewport parked over a stale offset:
    // frozen mid-transcript, and blank once the content shrank out from under
    // it. Reopening the overlay rebuilt the scroll view, which is why closing
    // and reopening "fixed" it.
    @State private var isFollowingLive = true
    @State private var liveFollowTask: Task<Void, Never>?
    @State private var liveFollowGeneration: UInt64 = 0
    // The strip of canvas that re-summons the operator chrome once the panel
    // fills a display. It has to cover the chrome itself: a band shorter than
    // the controls means hovering the lower half of the bar reads as "pointer
    // left the strip" and the bar dismisses itself under the pointer. That
    // used to be a literal 52, sized by eye against a one-row bar, and it went
    // wrong the moment the bar became two rows. Measured from the chrome, so
    // it cannot drift from it again.
    @State private var measuredControlBarHeight: CGFloat?

    /// Before the chrome has ever been laid out there is nothing to measure,
    /// and the band still has to be big enough to summon it.
    private static let minimumControlBarHoverBand: CGFloat = 96

    private var controlBarHoverBand: CGFloat {
        max(measuredControlBarHeight ?? 0, Self.minimumControlBarHoverBand)
    }

    // Deliberately unanimated, unlike the main transcript page's equivalent:
    // an animated catch-up would still be travelling when the next revision
    // lands, and a caption wall that is permanently mid-glide is harder to
    // read than one that simply is where the words are.
    private static let liveTailAnchorID = "zutalk.subtitleOverlay.live-tail"

    init(store: ActiveBilingualTranscriptStore) {
        self.store = store
        _livePresentation = ObservedObject(wrappedValue: store.livePresentation)
    }

    var body: some View {
        subtitleBody
            .frame(minWidth: 560, minHeight: 180)
            .background(
                RoundedRectangle(cornerRadius: canvasCornerRadius, style: .continuous)
                    .fill(SubtitleOverlayPalette.surface.opacity(canvasOpacity))
                    .overlay(
                        RoundedRectangle(cornerRadius: canvasCornerRadius, style: .continuous)
                            .strokeBorder(
                                SubtitleOverlayPalette.hairline,
                                lineWidth: coordinator.isMaximized ? 0 : 0.5
                            )
                    )
            )
            .overlay(alignment: .topTrailing) {
                // The leading inset is transparent and belongs to the layout,
                // not to the chrome: it is what guarantees the controls can
                // never slide under the maximize affordance at the opposite
                // corner, however wide the operator's window is.
                hoverControlBar
                    .padding(.leading, 50)
                    .background(
                        GeometryReader { proxy in
                            Color.clear
                                .onAppear { measuredControlBarHeight = proxy.size.height }
                                .onChange(of: proxy.size.height) { _, height in
                                    measuredControlBarHeight = height
                                }
                        }
                    )
            }
            .overlay(alignment: .topLeading) {
                // The two placement controls stay together in the corner the
                // hover bar deliberately leaves free, so neither depends on
                // the operator finding the hover strip first.
                HStack(spacing: 6) {
                    maximizeButton
                    bannerButton
                }
                .padding(8)
            }
            .clipShape(RoundedRectangle(cornerRadius: canvasCornerRadius, style: .continuous))
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    // Once the panel fills a display, the pointer is almost
                    // always inside it. Limit chrome activation to the top
                    // control strip so subtitles return to a clean canvas as
                    // soon as the pointer moves back into the content.
                    updateControlBarVisibility(
                        coordinator.isMaximized
                            ? location.y <= controlBarHoverBand
                            : true
                    )
                case .ended:
                    updateControlBarVisibility(false)
                }
            }
            .onExitCommand {
                coordinator.restoreWindow()
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(String(localized: "subtitle.overlay.accessibility_label")))
            .accessibilityValue(Text(String(
                format: String(localized: "subtitle.overlay.language_count"),
                store.selectedLanguages.count
            )))
            .environment(\.colorScheme, presentationSettings.theme.colorScheme)
    }

    private var canvasCornerRadius: CGFloat {
        coordinator.isMaximized ? 0 : 14
    }

    private func updateControlBarVisibility(_ isVisible: Bool) {
        guard isHoveringOverlay != isVisible else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            isHoveringOverlay = isVisible
        }
    }

    /// The overlay is a projection canvas in every mode: while it is being
    /// watched rather than operated, the operator chrome stays off-screen
    /// entirely and returns only under the pointer. The window itself remains
    /// movable by its background.
    /// Operator chrome sized to the controls, not to the window.
    ///
    /// It used to be a full-width band: a stretching spacer pushed the status
    /// to one edge and the controls to the other, an opaque background filled
    /// everything between them, and a divider ran the whole width underneath.
    /// On a desk that reads as a toolbar. Projected onto a wall at 1100 points
    /// it reads as a banner across the top of the slide, and most of it is the
    /// empty middle — the room is shown a stripe that carries nothing.
    ///
    /// A pill in the corner is the same controls at the same size, occupying
    /// only what they need, and it matches the treatment the maximize
    /// affordance opposite it already uses.
    @ViewBuilder
    private var hoverControlBar: some View {
        if isHoveringOverlay {
            controlBar
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(SubtitleOverlayPalette.surface.opacity(controlsOpacity))
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(
                                    SubtitleOverlayPalette.hairline,
                                    lineWidth: 0.5
                                )
                        )
                )
                .padding(8)
                .transition(.opacity)
        }
    }

    private var canvasOpacity: Double {
        SubtitleOverlayBackdropPolicy.canvasOpacity(
            storedOpacity: storedBackdropOpacity,
            reduceTransparency: accessibilityReduceTransparency
        )
    }

    private var configuredCanvasOpacity: Double {
        SubtitleOverlayBackdropPolicy.canvasOpacity(
            storedOpacity: storedBackdropOpacity,
            reduceTransparency: false
        )
    }

    private var controlsOpacity: Double {
        SubtitleOverlayBackdropPolicy.controlsOpacity(
            reduceTransparency: accessibilityReduceTransparency
        )
    }

    /// Two compact rows, always, sized to what they carry.
    ///
    /// Everything in here has a fixed width — a 144 pt mode picker, a 110 pt
    /// font slider, a 72 pt opacity slider, five 28 pt buttons — so one row
    /// comes to roughly 970 points before any spacing. On a desk that is a
    /// toolbar. On a projector it is a banner nearly as wide as the canvas,
    /// and the room reads it as part of the slide.
    ///
    /// Two rows cut the width to whichever row is wider, about half. A
    /// `ViewThatFits` used to offer this shape only as a fallback for windows
    /// too narrow for one row, which meant the wide venues that need it most
    /// never got it — and it could not have helped anyway, because each row
    /// carried a `Spacer` and the whole thing sat on a full-width band, so it
    /// stretched to the window either way. Both are gone; the rows now hug.
    ///
    /// The window title goes with them. It named the window to a room that is
    /// already looking at it.
    /// Always two rows; the only thing that degrades on a genuinely small
    /// window is the status prose, which is the one item here the operator can
    /// read somewhere else. Every control stays.
    private var controlBar: some View {
        ViewThatFits(in: .horizontal) {
            controlRows(includesStatus: true)
            controlRows(includesStatus: false)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .help(String(localized: "subtitle.overlay.move_resize_hint"))
    }

    private func controlRows(includesStatus: Bool) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 8) {
                if includesStatus {
                    captureStatus
                }
                backdropOpacityControl
                themeButton
                pinButton
                closeButton
            }
            HStack(spacing: 8) {
                modePicker
                fontControls
            }
        }
    }

    /// Puts the canvas across the top of the display at full width, leaving
    /// the slide underneath visible. Separate from the fill control rather
    /// than a third stop on it: an operator reaching for one of these in front
    /// of a room should not have to cycle through the other.
    private var bannerButton: some View {
        Button {
            coordinator.toggleBanner()
        } label: {
            Image(systemName: coordinator.placement == .banner
                ? "rectangle.topthird.inset.filled"
                : "rectangle.tophalf.inset.filled")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(.secondary)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(SubtitleOverlayPalette.surface.opacity(controlsOpacity))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(SubtitleOverlayPalette.hairline, lineWidth: 0.5)
                )
        )
        .help(String(localized: coordinator.placement == .banner
            ? "subtitle.overlay.restore"
            : "subtitle.overlay.banner"))
        .accessibilityLabel(Text(String(localized: coordinator.placement == .banner
            ? "subtitle.overlay.restore"
            : "subtitle.overlay.banner")))
        .accessibilityIdentifier(AccessibilityID.floatingSubtitleBanner)
        .keyboardShortcut("b", modifiers: [.control, .command])
    }

    private var maximizeButton: some View {
        Button {
            coordinator.toggleMaximized()
        } label: {
            Image(systemName: coordinator.placement == .filled
                ? "arrow.down.right.and.arrow.up.left"
                : "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(.secondary)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(SubtitleOverlayPalette.surface.opacity(controlsOpacity))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(SubtitleOverlayPalette.hairline, lineWidth: 0.5)
                )
        )
        .help(String(localized: coordinator.isMaximized
            ? "subtitle.overlay.restore"
            : "subtitle.overlay.maximize"))
        .accessibilityLabel(Text(String(localized: coordinator.isMaximized
            ? "subtitle.overlay.restore"
            : "subtitle.overlay.maximize")))
        .accessibilityIdentifier(AccessibilityID.floatingSubtitleMaximize)
        .keyboardShortcut("f", modifiers: [.control, .command])
    }

    private var captureStatus: some View {
        HStack(spacing: 8) {
            CaptureStateLabel(
                captureState: store.presentationCaptureState,
                remoteHealth: store.remoteHealth,
                projectionState: store.projectionState
            )
            degradedLanesBadge
        }
    }

    /// A single translation lane can now go dark without stopping the room,
    /// which trades a loud failure for a quiet one. The operator's invariant
    /// is that any degradation stays visible — so the languages that are
    /// behind or dark are named here, in the hover chrome the audience never
    /// sees, at a fixed small size that ignores the subtitle font slider.
    @ViewBuilder
    private var degradedLanesBadge: some View {
        let degraded = store.degradedTranslationLanguages
        if degraded.isEmpty == false {
            Label(
                degraded.map { displayLanguageCode($0) }.joined(separator: " · "),
                systemImage: "exclamationmark.triangle"
            )
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.secondary)
            // A lane that is merely behind will catch up; one stopped for a
            // gap in its audio will not, and the two need different advice.
            .help(String(localized: store.haltedTranslationLanguages.isEmpty
                ? "subtitle.overlay.degraded_lanes"
                : "capture.translation.halted.detail"))
            .accessibilityLabel(Text(String(localized: store.haltedTranslationLanguages.isEmpty
                ? "subtitle.overlay.degraded_lanes"
                : "capture.translation.halted.detail")))
        }
    }

    private var pinButton: some View {
        Button {
            presentationSettings.togglePinned()
        } label: {
            Image(systemName: presentationSettings.isPinned ? "pin.fill" : "pin.slash")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(presentationSettings.isPinned ? .accentColor : .secondary)
        .help(String(localized: presentationSettings.isPinned
            ? "subtitle.overlay.unpin"
            : "subtitle.overlay.pin"))
        .accessibilityLabel(Text(String(localized: presentationSettings.isPinned
            ? "subtitle.overlay.unpin"
            : "subtitle.overlay.pin")))
        .accessibilityValue(Text(String(localized: presentationSettings.isPinned
            ? "subtitle.overlay.pinned"
            : "subtitle.overlay.unpinned")))
    }

    private var themeButton: some View {
        Button {
            presentationSettings.theme = presentationSettings.theme.toggled
        } label: {
            Image(systemName: presentationSettings.theme == .dark
                ? "moon.fill"
                : "sun.max.fill")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(.secondary)
        .help(String(localized: presentationSettings.theme == .dark
            ? "subtitle.overlay.theme.switch_to_light"
            : "subtitle.overlay.theme.switch_to_dark"))
        .accessibilityLabel(Text(String(localized: presentationSettings.theme == .dark
            ? "subtitle.overlay.theme.switch_to_light"
            : "subtitle.overlay.theme.switch_to_dark")))
        .accessibilityValue(Text(String(localized: presentationSettings.theme == .dark
            ? "subtitle.overlay.theme.dark"
            : "subtitle.overlay.theme.light")))
    }

    private var closeButton: some View {
        Button {
            coordinator.dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(.secondary)
        .help(String(localized: "common.close"))
        .accessibilityLabel(Text(String(localized: "common.close")))
    }

    private var modePicker: some View {
        Picker(
            String(localized: "subtitle.overlay.mode"),
            selection: $presentationSettings.displayMode
        ) {
            Text(String(localized: "subtitle.overlay.mode.audience"))
                .tag(SubtitleOverlayDisplayMode.audience)
            Text(String(localized: "subtitle.overlay.mode.conversation"))
                .tag(SubtitleOverlayDisplayMode.conversation)
        }
        .pickerStyle(.segmented)
        .frame(width: 144)
        .help(String(localized: presentationSettings.displayMode == .conversation
            ? "subtitle.overlay.mode.conversation.help"
            : "subtitle.overlay.mode.audience.help"))
    }

    private var fontControls: some View {
        HStack(spacing: 4) {
            fontButton(
                systemImage: "textformat.size.smaller",
                label: String(localized: "subtitle.overlay.font_smaller"),
                identifier: AccessibilityID.floatingSubtitleFontSmaller,
                disabled: fontSize <= SubtitleOverlayFontPolicy.minimum
            ) {
                setManualFontSize(SubtitleOverlayFontPolicy.smaller(than: fontSize))
            }

            Slider(
                value: Binding(
                    get: { fontSize },
                    set: { setManualFontSize($0) }
                ),
                in: SubtitleOverlayFontPolicy.minimum...SubtitleOverlayFontPolicy.maximum
            )
            .controlSize(.mini)
            .frame(width: 110)
            .help(String(localized: "subtitle.overlay.font_size"))
            .accessibilityLabel(Text(String(localized: "subtitle.overlay.font_size")))
            .accessibilityValue(Text(verbatim: "\(Int(fontSize))"))

            Text(verbatim: "\(Int(fontSize))")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 30)
                .accessibilityHidden(true)

            fontButton(
                systemImage: "textformat.size.larger",
                label: String(localized: "subtitle.overlay.font_larger"),
                identifier: AccessibilityID.floatingSubtitleFontLarger,
                disabled: fontSize >= SubtitleOverlayFontPolicy.maximum
            ) {
                setManualFontSize(SubtitleOverlayFontPolicy.larger(than: fontSize))
            }

            fontAutoButton
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.07))
        )
    }

    private var backdropOpacityControl: some View {
        HStack(spacing: 4) {
            Image(systemName: "circle.lefthalf.filled")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .accessibilityHidden(true)

            Slider(
                value: Binding(
                    get: { configuredCanvasOpacity },
                    set: { storedBackdropOpacity = $0 }
                ),
                in: SubtitleOverlayBackdropPolicy.opacityRange
            )
            .controlSize(.mini)
            .frame(width: 72)
            .accessibilityLabel(Text(String(localized: "subtitle.overlay.background_opacity")))
            .accessibilityValue(Text(verbatim: "\(Int(canvasOpacity * 100))%"))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.07))
        )
        .disabled(accessibilityReduceTransparency)
        .help(String(localized: "subtitle.overlay.background_opacity"))
    }

    /// Every manual size control funnels through here: asking for a specific
    /// size is the opt-out from automatic, so no separate switch needs
    /// flipping off. The slider grabs from wherever automatic currently sits,
    /// which makes the handoff a nudge rather than a jump.
    private func setManualFontSize(_ value: Double) {
        storedFontSize = value
        if storedFontMode != .manual {
            storedFontMode = .manual
        }
    }

    private var fontAutoButton: some View {
        Button {
            if storedFontMode == .automatic {
                // Freeze the size automatic chose so leaving it never moves
                // the canvas.
                storedFontSize = fontSize
                storedFontMode = .manual
            } else {
                storedFontMode = .automatic
            }
        } label: {
            Image(systemName: storedFontMode == .automatic ? "a.circle.fill" : "a.circle")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 28, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(storedFontMode == .automatic ? .accentColor : .secondary)
        .help(String(localized: storedFontMode == .automatic
            ? "subtitle.overlay.font_auto.disable"
            : "subtitle.overlay.font_auto.enable"))
        .accessibilityLabel(Text(String(localized: storedFontMode == .automatic
            ? "subtitle.overlay.font_auto.disable"
            : "subtitle.overlay.font_auto.enable")))
        .accessibilityValue(Text(String(localized: storedFontMode == .automatic
            ? "subtitle.overlay.font_auto.on"
            : "subtitle.overlay.font_auto.off")))
        .accessibilityIdentifier(AccessibilityID.floatingSubtitleFontAuto)
    }

    private func fontButton(
        systemImage: String,
        label: String,
        identifier: String,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 28, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(.primary)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
        .help(label)
        .accessibilityLabel(Text(label))
        .accessibilityIdentifier(identifier)
    }

    /// 观看端分支生效的条件:本机没在录,而人在别人的房间里。
    /// 本机采集永远优先 —— 同时成立时(理论上不会,录音入口在房间中
    /// 是禁用的)以本机为准,不会把两场内容混在一扇窗里。
    private var showsSharedFeed: Bool {
        store.isCaptureActive == false && shareActivity.isViewing
    }

    /// A scroll view that keeps the live edge on screen.
    ///
    /// The tail anchor is a one-point spacer rather than the last row: rows are
    /// replaced in place as the provider revises them, and scrolling to a row
    /// that is about to change height lands short of where that row ends up.
    private func liveFollowingScroll<Content: View>(
        signal: SubtitleOverlayFollowSignal,
        indicators: ScrollIndicatorVisibility = .visible,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    content()
                    Color.clear
                        .frame(height: 1)
                        .id(Self.liveTailAnchorID)
                }
            }
            .defaultScrollAnchor(.bottom)
            .scrollIndicators(indicators)
            .onScrollGeometryChange(for: SubtitleOverlayScrollMetrics.self) { geometry in
                let visibleBottom = geometry.contentOffset.y + geometry.containerSize.height
                let contentBottom = geometry.contentSize.height + geometry.contentInsets.bottom
                return SubtitleOverlayScrollMetrics(
                    offsetY: Double(geometry.contentOffset.y),
                    distanceFromBottom: Double(max(0, contentBottom - visibleBottom)),
                    contentHeight: Double(geometry.contentSize.height)
                )
            } action: { previous, current in
                isFollowingLive = SubtitleOverlayFollowPolicy.reconciledFollowing(
                    wasFollowing: isFollowingLive,
                    previous: previous,
                    current: current
                )
                if isFollowingLive == false {
                    cancelLiveFollow()
                }
            }
            .onChange(of: signal) { _, _ in
                scheduleLiveFollow(using: proxy)
            }
            .onAppear {
                isFollowingLive = true
                proxy.scrollTo(Self.liveTailAnchorID, anchor: .bottom)
            }
            .onDisappear { cancelLiveFollow() }
        }
    }

    /// A provider may publish ten or more revisions each second. Scroll at most
    /// four times per second and never animate in-place growth; animating every
    /// partial competes with the text layout that just changed the row height.
    private func scheduleLiveFollow(using proxy: ScrollViewProxy) {
        guard liveFollowTask == nil, isFollowingLive else { return }
        liveFollowGeneration &+= 1
        let generation = liveFollowGeneration
        liveFollowTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard Task.isCancelled == false,
                  generation == liveFollowGeneration,
                  isFollowingLive
            else {
                if generation == liveFollowGeneration {
                    liveFollowTask = nil
                }
                return
            }
            proxy.scrollTo(Self.liveTailAnchorID, anchor: .bottom)
            liveFollowTask = nil
        }
    }

    private func cancelLiveFollow() {
        liveFollowGeneration &+= 1
        liveFollowTask?.cancel()
        liveFollowTask = nil
    }

    private var subtitleBody: some View {
        GeometryReader { geometry in
            Group {
                if showsSharedFeed {
                    sharedFeedBody(geometry: geometry)
                } else {
                    switch presentationSettings.displayMode {
                    case .conversation:
                        conversationBody(geometry: geometry)
                    case .audience:
                        audienceBody(geometry: geometry)
                    }
                }
            }
            .onAppear { canvasSize = geometry.size }
            .onChange(of: geometry.size) { _, size in canvasSize = size }
        }
    }

    /// 远端帧的字幕投影。帧是 replace-in-full 的,整个画面每帧重画,没有
    /// 增量状态;cue 与句子的对应不在这里重算(share-p2p.md §3.2 的红线)。
    ///
    /// **画布与本机录音同一块。** 在别人房间里看字幕和自己录音看字幕,是
    /// 同一件事的两个来源,不该长成两个产品:本机三语是三栏,进了房间却
    /// 变成一列滚动的横条,观众得重新学一次怎么读。差别只在内容从哪来。
    @ViewBuilder
    private func sharedFeedBody(geometry: GeometryProxy) -> some View {
        if shareActivity.hostLeft {
            emptyState(
                String(localized: "share.status.host_left"),
                systemImage: "antenna.radiowaves.left.and.right.slash"
            )
        } else if let preview = shareActivity.remotePreview {
            audienceTimelineCanvas(
                geometry: geometry,
                input: Self.sharedAudienceInput(preview: preview)
            )
            .frame(width: geometry.size.width, height: geometry.size.height)
        } else if shareActivity.remoteLines.isEmpty == false {
            // 旧版主播:只有压扁行。
            sharedFeedLegacyLines(shareActivity.remoteLines)
                .frame(width: geometry.size.width, height: geometry.size.height)
        } else {
            emptyState(
                String(localized: "subtitle.overlay.waiting"),
                systemImage: "waveform"
            )
        }
    }

    /// 远端帧 → 画布输入。
    ///
    /// 本机录音的栏目来自采集档案(用户自己选的几门语言)。房间里没有这份
    /// 档案:观看的人不曾配置主播讲什么、译什么。所以栏目从帧本身认 ——
    /// **主播真的在跑的车道**(lane health / cue 的目标语言)加上这一帧的
    /// 主导原文语言。
    ///
    /// 认车道而不认「出现过的语言」,是因为真实录音里语言识别会飘:一句
    /// 被误判成法语的中文不该凭空长出一栏法语。飘出来的句子落进画布本来
    /// 就有的「没有归属」条,与主播本机的处置一致。
    static func sharedAudienceInput(
        preview: FfiNotebookCaptureLivePreview
    ) -> AudienceCanvasInput {
        let frame = RustNotebookCaptureClient.map(preview)
        let utterances = frame.utterances
        let dominantSource = dominantSourceLanguage(utterances)

        var lanes: [String] = frame.laneHealth
            .compactMap { $0.targetLanguage }
            .map(normalizedLanguageCode)
        if lanes.isEmpty {
            // 旧版主播不发 lane health。退回「有译文的语言」——比无栏可看强。
            lanes = frame.translationCues.map { normalizedLanguageCode($0.targetLanguage) }
                + utterances.compactMap { $0.translatedLanguage }.map(normalizedLanguageCode)
        }
        var seen: Set<String> = []
        var languages: [String] = []
        for language in [dominantSource].compactMap({ $0 }) + lanes.sorted()
        where seen.insert(language).inserted {
            languages.append(language)
        }

        var cuesByLanguage = Dictionary(
            grouping: frame.translationCues.filter { $0.withdrawn == false },
            by: { normalizedLanguageCode($0.targetLanguage) }
        )
        // 两方对谈的主播不发 cue,译文绑在句子上。把它按 cue 的形状递给
        // 画布 —— 这不是重算对应关系(那条红线还在),是把主播自己定好的
        // 绑定原样搬过来。
        for utterance in utterances {
            guard let language = utterance.translatedLanguage.map(normalizedLanguageCode),
                  let text = utterance.translatedText,
                  text.isEmpty == false,
                  cuesByLanguage[language] == nil
            else { continue }
            cuesByLanguage[language, default: []].append(
                NotebookCaptureTranslationCueDTO(
                    targetLanguage: language,
                    groupEpoch: 0,
                    providerSequence: utterance.sequence,
                    sourceLanguage: normalizedLanguageCode(utterance.sourceLanguage),
                    sourceStartMs: utterance.sourceStartMs,
                    sourceEndMs: utterance.sourceEndMs,
                    text: text,
                    completion: utterance.completion,
                    withdrawn: false,
                    revision: utterance.revision
                )
            )
        }

        return AudienceCanvasInput(
            languages: languages,
            utterances: utterances,
            placement: { utterance in
                NotebookCaptureHistoryPolicy.audienceSourcePlacement(
                    for: utterance,
                    selectedLanguages: languages,
                    lastIdentifiedSourceLanguage: dominantSource
                )
            },
            cuesByLanguage: cuesByLanguage,
            failedLanguages: Set(
                frame.laneHealth
                    .filter { $0.state == .failed }
                    .compactMap { $0.targetLanguage }
                    .map(normalizedLanguageCode)
            ),
            // 房间里这一帧就是画布看得见的全部,所以下界直接从它算 ——
            // 本机那条路要先绕开裁剪,这里没有裁剪可绕。
            inheritedSourceAnchors: NotebookCaptureLivePresentation.inheritedSourceAnchors(
                durable: utterances,
                sessionId: nil
            )
        )
    }

    /// 这一帧里说的主要是哪门语言。带说话人标识的句子(canonical 车道的
    /// 产物)优先参与判定 —— 辅助车道的碎片通常没有说话人。同级按句数,
    /// 长度只作平票裁决:一句冗长的外语碎片不该赢过两句正主。
    static func dominantSourceLanguage(
        _ utterances: [NotebookCaptureUtteranceDTO]
    ) -> String? {
        let speakered = utterances.filter { $0.sessionSpeakerId != nil }
        let pool = speakered.isEmpty ? utterances : speakered
        var count: [String: Int] = [:]
        var length: [String: Int] = [:]
        for utterance in pool {
            let language = normalizedLanguageCode(
                utterance.provisionalSourceLanguage ?? utterance.sourceLanguage
            )
            guard language.isEmpty == false, language != "und" else { continue }
            count[language, default: 0] += 1
            length[language, default: 0] += utterance.sourceText.count
        }
        return count.keys.max { left, right in
            if count[left] != count[right] { return count[left]! < count[right]! }
            return length[left]! < length[right]!
        }
    }

    private func sharedFeedLegacyLines(_ lines: [FfiSharedCaptionLine]) -> some View {
        liveFollowingScroll(
            signal: SubtitleOverlayFollowSignal(
                tailID: lines.last?.sourceText ?? "",
                rowCount: lines.count,
                textExtent: (lines.last?.sourceText.count ?? 0)
                    + (lines.last?.targetText?.count ?? 0)
            ),
            indicators: .hidden
        ) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    VStack(alignment: .leading, spacing: 4) {
                        if line.sourceText.isEmpty == false {
                            Text(line.sourceText)
                                .font(.system(size: fontSize, weight: .medium))
                                .foregroundColor(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let text = line.targetText, text.isEmpty == false {
                            Text(text)
                                .font(.system(size: fontSize * 0.86))
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(16)
        }
    }

    private func conversationBody(geometry: GeometryProxy) -> some View {
        let layout = SubtitleOverlayLayoutPolicy.conversationLayout(
            width: geometry.size.width,
            languageCount: displayLanguages.count,
            fontSize: fontSize
        )
        let rowBudget = SubtitleOverlayLayoutPolicy.conversationRowCount(
            height: geometry.size.height,
            fontSize: fontSize,
            lanesPerRow: layout == .columns ? 1 : displayLanguages.count
        )
        let utteranceTail = store.presentedUtteranceTail(
            limit: rowBudget + SubtitleConversationTimeline.utteranceLookbackAllowance
        )

        return conversationTranscript(
            layout: layout,
            rowBudget: rowBudget,
            utterances: utteranceTail
        )
            .frame(width: geometry.size.width, height: geometry.size.height)
    }

    @ViewBuilder
    private func conversationTranscript(
        layout: SubtitleOverlayConversationLayout,
        rowBudget: Int,
        utterances: [NotebookCaptureUtteranceDTO]
    ) -> some View {
        if store.profile.mode == .multilingualOneWay {
            conversationTimelineTranscript(
                layout: layout,
                rowBudget: rowBudget,
                utterances: utterances
            )
        } else if store.isCaptureActive == false {
            emptyState(
                String(localized: "subtitle.overlay.recording_ended"),
                systemImage: "checkmark.circle"
            )
        } else if utterances.isEmpty {
            emptyState(
                String(localized: "subtitle.overlay.waiting"),
                systemImage: "waveform"
            )
        } else {
            let rows = Array(utterances.suffix(rowBudget))
            liveFollowingScroll(signal: Self.followSignal(rows: rows)) {
                LazyVStack(spacing: 10) {
                    ForEach(rows) { utterance in
                        conversationRow(utterance, layout: layout)
                    }
                }
                .padding(12)
            }
        }
    }

    /// The tail row is the only one that revises, so its extent is the whole
    /// growth signal; row count carries the rest.
    private static func followSignal(
        rows: [NotebookCaptureUtteranceDTO]
    ) -> SubtitleOverlayFollowSignal {
        let tail = rows.last
        let sourceExtent = tail?.sourceText.count ?? 0
        let translatedExtent = tail?.translatedText?.count ?? 0
        let variantExtent = tail?.languageVariants.reduce(into: 0) { extent, variant in
            extent += variant.text?.count ?? 0
        } ?? 0
        return SubtitleOverlayFollowSignal(
            tailID: tail?.id ?? "",
            rowCount: rows.count,
            textExtent: sourceExtent + translatedExtent + variantExtent
        )
    }

    @ViewBuilder
    private func conversationTimelineTranscript(
        layout: SubtitleOverlayConversationLayout,
        rowBudget: Int,
        utterances: [NotebookCaptureUtteranceDTO]
    ) -> some View {
        // One snapshot for the whole pass, grouped once — the same discipline
        // `localAudienceInput` already applies. Asking the store per language
        // re-sorted the entire cue set once for every column, on every
        // provider revision, to answer three questions about one unchanged
        // set. Grouping also drops the per-language linear filter.
        let cuesByLanguage = Dictionary(
            grouping: store.presentedTranslationCueSnapshot,
            by: { normalizedLanguageCode($0.targetLanguage) }
        )
        let timeline = SubtitleConversationTimeline.projection(
            languages: displayLanguages,
            utterances: utterances,
            placement: store.makeAudienceSourcePlacement(),
            cues: { cuesByLanguage[normalizedLanguageCode($0)] ?? [] },
            failedLanguages: store.failedTranslationLanguages
        )
        let liveRowCount = timeline.hasLiveWords ? 1 : 0
        let unroutedRowCount = timeline.unroutedLiveUtterance == nil ? 0 : 1
        let historyBudget = max(rowBudget - liveRowCount - unroutedRowCount, 0)

        if store.isCaptureActive == false {
            emptyState(
                String(localized: "subtitle.overlay.recording_ended"),
                systemImage: "checkmark.circle"
            )
        } else if timeline.hasContent == false {
            emptyState(
                String(localized: "subtitle.overlay.waiting"),
                systemImage: "waveform"
            )
        } else {
            let history = Array(timeline.historicalUtterances.suffix(historyBudget))
            // The live edge is not a row in `history`: it is rebuilt from the
            // independent lane heads on every provider revision, so its text
            // extent is what actually moves the tail here.
            let signal = SubtitleOverlayFollowSignal(
                tailID: timeline.unroutedLiveUtterance?.id
                    ?? history.last?.id
                    ?? "",
                rowCount: history.count + liveRowCount + unroutedRowCount,
                textExtent: timeline.liveLanes.reduce(0) { $0 + ($1.text?.count ?? 0) }
                    + (timeline.unroutedLiveUtterance?.sourceText.count ?? 0)
            )
            liveFollowingScroll(signal: signal) {
                LazyVStack(spacing: 10) {
                    ForEach(history) { utterance in
                        conversationRow(utterance, layout: layout)
                    }
                    if let unrouted = timeline.unroutedLiveUtterance {
                        conversationRow(unrouted, layout: layout)
                    }
                    if timeline.hasLiveWords {
                        conversationLiveRow(timeline.liveLanes, layout: layout)
                    }
                }
                .padding(12)
            }
        }
    }

    /// The audience never reads system prose. Silence, session start, and
    /// session end all present the same way — a quiet canvas — and words are
    /// the only thing that ever appears on it.
    ///
    /// Retention favors the present over the past: rows keep their natural
    /// text height and stack from the bottom edge, so a long monologue pushes
    /// finished rows off the top instead of squeezing every row into an equal
    /// slice that truncates the words currently being spoken. When a single
    /// utterance outgrows the whole canvas, the bottom anchor clips its
    /// already-read head and keeps the live tail on screen.
    @ViewBuilder
    private func audienceBody(geometry: GeometryProxy) -> some View {
        // Multilingual capture reads translations as time-anchored cues on
        // per-language tracks; the row model would gate every translation on
        // the slower canonical row it binds to. Two-way capture has no
        // auxiliary streams and no cues, so it keeps the row model.
        if store.profile.mode == .multilingualOneWay {
            audienceTimelineBody(geometry: geometry)
        } else {
            audienceRowsBody(geometry: geometry)
        }
    }

    /// One audience canvas's input, independent of where the words came from.
    ///
    /// The canvas used to read `store` directly, which is why the audience
    /// looked at two different products depending on whose room they were in:
    /// the host got per-language columns, and anyone watching a shared room
    /// got a single scrolling list, because the shared branch had no way to
    /// reach the layout at all. Both sources now fill this one value.
    struct AudienceCanvasInput {
        let languages: [String]
        let utterances: [NotebookCaptureUtteranceDTO]
        let placement: (NotebookCaptureUtteranceDTO) -> String?
        let cuesByLanguage: [String: [NotebookCaptureTranslationCueDTO]]
        let failedLanguages: Set<String>
        /// Sort-only lower bounds for rows the provider never timed, keyed by
        /// utterance id. It travels with `utterances` because the local capture
        /// hands over a pruned candidate set, and the bound has to come from
        /// the session those rows were pruned out of.
        var inheritedSourceAnchors: [String: UInt64] = [:]
    }

    /// The local capture's input. Freezes one coherent presentation frame:
    /// the previous body rebuilt and sorted the complete session three times,
    /// and recomputed the durable language fallback once for every source
    /// row, so provider-rate preview updates got progressively more expensive
    /// as a meeting grew even though the canvas shows at most eight cards.
    private var localAudienceInput: AudienceCanvasInput {
        AudienceCanvasInput(
            languages: store.selectedLanguages,
            utterances: store.presentedAudienceUtterances(
                maximumRows: SubtitleOverlayLayoutPolicy.maximumAudienceRowCount
            ),
            placement: store.makeAudienceSourcePlacement(),
            cuesByLanguage: Dictionary(
                grouping: store.presentedTranslationCueSnapshot,
                by: { normalizedLanguageCode($0.targetLanguage) }
            ),
            failedLanguages: store.failedTranslationLanguages,
            inheritedSourceAnchors: store.presentedAudienceInheritedSourceAnchors(
                maximumRows: SubtitleOverlayLayoutPolicy.maximumAudienceRowCount
            )
        )
    }

    @ViewBuilder
    private func audienceTimelineBody(geometry: GeometryProxy) -> some View {
        if store.isCaptureActive {
            audienceTimelineCanvas(geometry: geometry, input: localAudienceInput)
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private func audienceTimelineCanvas(
        geometry: GeometryProxy,
        input: AudienceCanvasInput
    ) -> some View {
        let languages = input.languages
        let utterances = input.utterances
        let placement = input.placement
        let cuesByLanguage = input.cuesByLanguage
        let bandSize = SubtitleOverlayLayoutPolicy.audienceColumnCount(
            width: geometry.size.width,
            languageCount: languages.count,
            fontSize: fontSize
        )
        let bandStarts = Array(stride(from: 0, to: max(languages.count, 1), by: bandSize))
        // The strip probe uses a window-of-one on purpose: it only decides
        // whether space must be reserved, and the real lookup below reuses
        // the budget derived from the resulting band height.
        let reservesStrip = SubtitleAudienceTimeline.unroutedText(
            utterances: utterances,
            placement: placement
        ) != nil
        let bandHeight = SubtitleOverlayLayoutPolicy.audienceBandHeight(
            canvasHeight: geometry.size.height,
            bandCount: bandStarts.count,
            reservesUnroutedStrip: reservesStrip,
            fontSize: fontSize
        )
        let itemBudget = SubtitleOverlayLayoutPolicy.audienceRowCount(
            height: bandHeight,
            fontSize: fontSize
        )
        let columns = SubtitleAudienceTimeline.columns(
            languages: languages,
            utterances: utterances,
            placement: placement,
            cues: { language in
                cuesByLanguage[normalizedLanguageCode(language)] ?? []
            },
            inheritedSourceAnchors: input.inheritedSourceAnchors,
            visibleLimit: itemBudget
        )
        let waiting = SubtitleAudienceTimeline.waitingLanguages(
            columns: columns,
            failedLanguages: input.failedLanguages
        )
        let unrouted = SubtitleAudienceTimeline.unroutedText(
            utterances: utterances,
            placement: placement,
            window: itemBudget
        )
        let trimmed = columns.mapValues { items in Array(items.suffix(itemBudget)) }
        let visibleCueIds = Set(
            trimmed.values.joined()
                .filter { $0.kind == .translation }
                .map(\.id)
        )
        // 有没有字就画不画 —— 上游(本机采集 / 远端房间)是否还活着,由调用
        // 方在进来之前判断;画布只对内容负责。
        let hasWords = trimmed.values.contains { $0.isEmpty == false } || unrouted != nil

        if hasWords {
            VStack(spacing: 8) {
                ForEach(bandStarts, id: \.self) { start in
                    HStack(alignment: .bottom, spacing: 8) {
                        ForEach(
                            Array(languages[start..<min(start + bandSize, languages.count)]),
                            id: \.self
                        ) { language in
                            audienceCueColumn(
                                language: language,
                                items: trimmed[language] ?? [],
                                waiting: waiting.contains(language)
                            )
                        }
                    }
                    .frame(maxWidth: .infinity)
                    // Every band keeps its own newest words on its own
                    // bottom edge; a tall band clips its head instead of
                    // pushing the bands above it off the canvas.
                    .frame(height: bandHeight, alignment: .bottom)
                    .clipped()
                }
                if let unrouted {
                    audiencePlainText(unrouted)
                }
            }
            .padding(12)
            .frame(
                width: geometry.size.width,
                height: geometry.size.height,
                alignment: .bottom
            )
            .clipped()
            .onChange(of: visibleCueIds) { _, visible in
                revealMemory.prune(keeping: visible)
            }
        } else {
            Color.clear
        }
    }

    /// One language's track: its own cards, its own segmentation, bottom
    /// anchored so the newest words sit on the shared "now" edge. Card counts
    /// deliberately do not match across columns — a translation stream that
    /// segments coarser than the canonical one produces fewer, longer cards,
    /// and forcing them into row alignment is exactly the binding this layout
    /// retires.
    private func audienceCueColumn(
        language: String,
        items: [SubtitleAudienceTimeline.Item],
        waiting: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(items) { item in
                audienceCueCard(
                    item: item,
                    // Only the live tail paces from zero. Cards already on
                    // screen keep their reveal state across updates (stable
                    // ForEach identity); finished cards arriving with a
                    // reopened window render instantly instead of replaying
                    // history.
                    startsRevealed: item.id != items.last?.id
                )
            }
            if waiting, items.isEmpty {
                // An empty waiting column is the whole column: the promise has
                // nothing to displace, and a bare gap would read as a lane
                // that died rather than one that is a beat behind.
                waitingCard
            }
        }
        .frame(maxWidth: .infinity, alignment: .bottom)
        // The ellipsis is a promise, not content, so it must not move content.
        // Stacked under the newest card it pushed that card up off the shared
        // bottom edge — and the bottom edge is the one correspondence this
        // layout guarantees, the whole reason columns are allowed to disagree
        // about everything above it. A lane one beat behind therefore showed
        // its current line higher than every sibling's, which reads exactly
        // like the languages having come out of alignment. As an overlay it
        // says the same thing and displaces nothing.
        .overlay(alignment: .bottomTrailing) {
            if waiting, items.isEmpty == false {
                waitingGlyph
                    .padding(.trailing, 12)
                    .padding(.bottom, 10)
            }
        }
        .animation(.easeOut(duration: 0.22), value: items.map(\.id))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(languageName(language)))
    }

    private var waitingGlyph: some View {
        Image(systemName: "ellipsis")
            .font(.system(size: max(CGFloat(fontSize) * 0.55, 12), weight: .semibold))
            .foregroundColor(.secondary.opacity(0.55))
    }

    private var waitingCard: some View {
        waitingGlyph
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(
                maxWidth: .infinity,
                minHeight: CGFloat(fontSize) * 1.6,
                alignment: .bottomLeading
            )
            .background(subtitleCardBackground)
    }

    /// Source cards paint as delivered — the canonical preview already flows
    /// at word grain. Translation cards pace: the provider hands translations
    /// over in measured ~15-token mouthfuls every ~1.4 s, and painting a
    /// mouthful as one slab is exactly the "blocky translation" complaint.
    @ViewBuilder
    private func audienceCueCard(
        item: SubtitleAudienceTimeline.Item,
        startsRevealed: Bool
    ) -> some View {
        if item.kind == .translation {
            AudiencePacedText(
                id: item.id,
                text: item.text,
                fontSize: fontSize,
                startsRevealed: startsRevealed,
                memory: revealMemory
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .bottomLeading)
            .background(subtitleCardBackground)
        } else {
            AudienceStableSourceText(
                text: item.text,
                isComplete: item.isComplete,
                fontSize: fontSize
            )
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .bottomLeading)
                .background(subtitleCardBackground)
        }
    }

    @ViewBuilder
    private func audienceRowsBody(geometry: GeometryProxy) -> some View {
        let utterances = store.presentedUtteranceTail(
            limit: SubtitleOverlayLayoutPolicy.audienceRowCount(
                height: geometry.size.height,
                fontSize: fontSize
            )
        )

        if store.isCaptureActive, utterances.isEmpty == false {
            VStack(spacing: 10) {
                ForEach(utterances) { utterance in
                    audienceRow(utterance, width: geometry.size.width)
                        .frame(maxWidth: .infinity)
                        .transition(.opacity)
                }
            }
            .padding(12)
            .animation(.easeOut(duration: 0.22), value: utterances.map(\.id))
            .frame(
                width: geometry.size.width,
                height: geometry.size.height,
                alignment: .bottom
            )
            .clipped()
        } else {
            Color.clear
        }
    }

    /// Status prose is operator chrome, not subtitle content: it keeps a fixed
    /// small size no matter how large the audience font is cranked.
    private func emptyState(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
    }

    @ViewBuilder
    private func conversationRow(
        _ utterance: NotebookCaptureUtteranceDTO,
        layout: SubtitleOverlayConversationLayout
    ) -> some View {
        let projection = store.projection(for: utterance)

        // A line whose language is still unidentified, or whose language the
        // room did not select, is still speech. It shows as speech: full
        // width, no label, no icon.
        //
        // This used to be a captioned status row — "语言待定" with an
        // ellipsis glyph, in a different colour from every line around it.
        // The overlay is what the room is looking at, and the standing
        // invariant for it is that the canvas never carries system prose: the
        // audience has no idea what a language lane is and cannot act on the
        // news. Worse, the labelled row is a different shape from its
        // neighbours, so a single unidentified line visibly broke the column
        // grid — one of the ways "the languages stopped lining up" showed up
        // in practice. The operator still needs to know; that belongs in
        // operator chrome, which already reports lane health on hover.
        //
        // The durable transcript page keeps the stricter labelled treatment.
        // Its reader is not in the room, is reading afterwards, and is served
        // by knowing that the identity was never established.
        if let pendingLanguage = projection.pendingLanguage {
            audiencePlainText(pendingLanguage)
        } else if let outsideText = projection.unselectedLanguageText {
            audiencePlainText(outsideText)
        } else {
            if layout == .columns {
                // A shared bottom edge keeps every language's newest words in
                // view when a much longer sibling clips through the row's top.
                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(Array(displayLanes(projection).enumerated()), id: \.offset) {
                        index,
                        lane in
                        conversationLane(lane)
                        if index < displayLanes(projection).count - 1 {
                            Divider().overlay(SubtitleOverlayPalette.hairline)
                        }
                    }
                }
                .background(subtitleCardBackground)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(displayLanes(projection).enumerated()), id: \.offset) {
                        index,
                        lane in
                        conversationLane(lane)
                        if index < displayLanes(projection).count - 1 {
                            Divider().overlay(SubtitleOverlayPalette.hairline)
                        }
                    }
                }
                .background(subtitleCardBackground)
            }
        }
    }

    /// The live conversation edge has the same visual geometry as a durable
    /// row, but its lanes are independent track heads rather than variants
    /// bound to one canonical utterance.
    @ViewBuilder
    private func conversationLiveRow(
        _ lanes: [NotebookCaptureLanguageLane],
        layout: SubtitleOverlayConversationLayout
    ) -> some View {
        if layout == .columns {
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(Array(lanes.enumerated()), id: \.offset) { index, lane in
                    conversationLane(lane, coalescesRevisions: true)
                    if index < lanes.count - 1 {
                        Divider().overlay(SubtitleOverlayPalette.hairline)
                    }
                }
            }
            .background(subtitleCardBackground)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(lanes.enumerated()), id: \.offset) { index, lane in
                    conversationLane(lane, coalescesRevisions: true)
                    if index < lanes.count - 1 {
                        Divider().overlay(SubtitleOverlayPalette.hairline)
                    }
                }
            }
            .background(subtitleCardBackground)
        }
    }

    /// Words-first projection with a quiet promise: lanes carrying words show
    /// them, and a lane whose translation is still on its way holds its place
    /// with a dimmed ellipsis card instead of vanishing — an absent column
    /// reads as "this language is broken", while a placeholder reads as "it's
    /// coming". Lanes that will never fill (unavailable, failed) stay hidden;
    /// the audience is never shown error prose. A line whose language is
    /// still unrouted (pending identification or outside the selection) is
    /// still speech — it shows full-width as plain text, with no label
    /// explaining itself, and the columns catch up silently on the next
    /// revision.
    @ViewBuilder
    private func audienceRow(
        _ utterance: NotebookCaptureUtteranceDTO,
        width: CGFloat
    ) -> some View {
        let projection = store.projection(for: utterance)
        let lanes = displayLanes(projection).filter {
            $0.text?.isEmpty == false || $0.missingLaneState == .waiting
        }

        if lanes.contains(where: { $0.text?.isEmpty == false }) {
            let columnCount = SubtitleOverlayLayoutPolicy.audienceColumnCount(
                width: width,
                languageCount: lanes.count,
                fontSize: fontSize
            )
            let rowStarts = Array(stride(from: 0, to: lanes.count, by: columnCount))

            // Lane cards match the tallest lane in their row, and the row
            // itself takes whatever height its text needs — no line is ever
            // cut to fit a pre-sliced tile.
            VStack(spacing: 8) {
                ForEach(rowStarts, id: \.self) { start in
                    HStack(alignment: .bottom, spacing: 8) {
                        ForEach(
                            Array(lanes[start..<min(start + columnCount, lanes.count)].enumerated()),
                            id: \.offset
                        ) { _, lane in
                            if lane.text?.isEmpty == false {
                                audienceLane(lane)
                            } else {
                                audienceWaitingLane(lane)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else if let unroutedText = projection.pendingLanguage
            ?? projection.unselectedLanguageText,
            unroutedText.isEmpty == false {
            audiencePlainText(unroutedText)
        }
    }

    private func audiencePlainText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: CGFloat(fontSize), weight: .semibold))
            .foregroundColor(.primary)
            .textSelection(.enabled)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .bottomLeading)
            .fixedSize(horizontal: false, vertical: true)
            .background(subtitleCardBackground)
    }

    private func conversationLane(
        _ lane: NotebookCaptureLanguageLane,
        coalescesRevisions: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            laneContent(lane, coalescesRevisions: coalescesRevisions)
                .font(.system(size: CGFloat(fontSize), weight: .medium))
                .textSelection(.enabled)
        }
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, minHeight: CGFloat(fontSize * 2.35), alignment: .bottomLeading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(languageName(lane.language)))
        .accessibilityValue(Text(conversationLaneAccessibilityValue(lane)))
    }

    /// One lane, words only: no per-row language caption, no line cap, no
    /// dimming. The row being read is usually the one whose translation just
    /// filled in, so every visible row keeps full size and full brightness,
    /// and a long sentence wraps instead of scaling away its tail.
    ///
    /// Lane text anchors to the bottom of its card: languages run different
    /// lengths, so a row taller than the canvas clips through its top edge —
    /// a top-anchored short lane would sit entirely inside that clipped band
    /// and vanish, while bottom-anchored lanes all keep their live tail in
    /// the visible bottom region.
    private func audienceLane(_ lane: NotebookCaptureLanguageLane) -> some View {
        Text(lane.text ?? "")
            .font(.system(size: CGFloat(fontSize), weight: .semibold))
            .foregroundColor(.primary)
            .transaction { transaction in
                transaction.animation = nil
            }
            .textSelection(.enabled)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .background(subtitleCardBackground)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(languageName(lane.language)))
            .accessibilityValue(Text(lane.text ?? ""))
    }

    /// A lane whose translation is still in flight keeps its column with a
    /// dimmed ellipsis — never prose, so the quiet-canvas rule holds. The
    /// ellipsis scales with the subtitle font so the placeholder reads at the
    /// same distance the words will.
    private func audienceWaitingLane(_ lane: NotebookCaptureLanguageLane) -> some View {
        Image(systemName: "ellipsis")
            .font(.system(size: max(CGFloat(fontSize) * 0.55, 12), weight: .semibold))
            .foregroundColor(.secondary.opacity(0.55))
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(
                maxWidth: .infinity,
                minHeight: CGFloat(fontSize) * 1.6,
                maxHeight: .infinity,
                alignment: .bottomLeading
            )
            .background(subtitleCardBackground)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(languageName(lane.language)))
            .accessibilityValue(Text(String(
                format: String(localized: "capture.transcript.waiting_lane"),
                displayLanguageCode(lane.language)
            )))
    }

    @ViewBuilder
    private func laneContent(
        _ lane: NotebookCaptureLanguageLane,
        coalescesRevisions: Bool = false
    ) -> some View {
        if let text = lane.text, text.isEmpty == false {
            if coalescesRevisions {
                // Measured on a 107-minute recording: the Chinese lane
                // delivered 27,367 revisions carrying 32,738 characters — one
                // full row re-layout per 1.2 characters, against 40 characters
                // per revision on the English lane. The budget is a ceiling on
                // that, not a delay: a row leaves the live edge the moment a
                // newer source row appears and re-renders as ordinary history,
                // so no settled text is ever held back by it.
                StableRefreshText(text: text, isComplete: false)
                    .foregroundColor(.primary)
            } else {
                Text(text)
                    .foregroundColor(.primary)
            }
        } else if lane.missingLaneState == .waiting {
            Label(
                String(
                    format: String(localized: "capture.transcript.waiting_lane"),
                    displayLanguageCode(lane.language)
                ),
                systemImage: "ellipsis"
            )
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.secondary)
        } else if lane.missingLaneState == .failed {
            Label(
                String(
                    format: String(localized: "capture.transcript.failed_lane"),
                    displayLanguageCode(lane.language)
                ),
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.orange)
        } else {
            Text("—")
                .foregroundColor(.secondary.opacity(0.5))
                .accessibilityHidden(true)
        }
    }

    private func conversationLaneAccessibilityValue(
        _ lane: NotebookCaptureLanguageLane
    ) -> String {
        if let text = lane.text, text.isEmpty == false {
            return text
        }

        switch lane.missingLaneState {
        case .waiting:
            return String(
                format: String(localized: "capture.transcript.waiting_lane"),
                displayLanguageCode(lane.language)
            )
        case .failed:
            return String(
                format: String(localized: "capture.transcript.failed_lane"),
                displayLanguageCode(lane.language)
            )
        case .unavailable:
            return ""
        }
    }

    private func statusRow(
        title: String,
        detail: String,
        systemImage: String,
        color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .foregroundColor(color)
            if detail.isEmpty == false {
                Text(detail)
                    .font(.system(size: CGFloat(fontSize), weight: .medium))
                    .foregroundColor(.primary)
                    .textSelection(.enabled)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.055))
        )
    }

    private var fontSize: Double {
        switch storedFontMode {
        case .automatic:
            return SubtitleOverlayFontPolicy.automatic(
                canvasSize: canvasSize,
                languageCount: displayLanguages.count,
                mode: presentationSettings.displayMode
            )
        case .manual:
            return SubtitleOverlayFontPolicy.clamped(storedFontSize)
        }
    }

    private var displayLanguages: [String] {
        Array(
            store.selectedLanguages.prefix(
                SubtitleOverlayLayoutPolicy.maximumLanguageCount
            )
        )
    }

    private func displayLanes(
        _ projection: NotebookCaptureLaneProjection
    ) -> [NotebookCaptureLanguageLane] {
        Array(
            projection.lanes.prefix(
                SubtitleOverlayLayoutPolicy.maximumLanguageCount
            )
        )
    }

    private var subtitleCardBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.primary.opacity(0.055))
    }

    private func languageName(_ code: String) -> String {
        let normalized = normalizedLanguageCode(code)
        return Locale(identifier: normalized).localizedString(forLanguageCode: normalized)
            ?? Locale.current.localizedString(forLanguageCode: normalized)
            ?? displayLanguageCode(code)
    }

    private func displayLanguageCode(_ code: String) -> String {
        normalizedLanguageCode(code).uppercased()
    }

    private func normalizedLanguageCode(_ code: String) -> String {
        Self.normalizedLanguageCode(code)
    }

    /// 纯字符串折叠,不碰任何视图状态 —— 标 nonisolated,好让它在
    /// `map` 这类非隔离闭包里用。
    nonisolated static func normalizedLanguageCode(_ code: String) -> String {
        code
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-")
            .first
            .map(String.init) ?? code.lowercased()
    }
}

@MainActor
final class SubtitleOverlayController: NSWindowController, ManagedWindowController, NSWindowDelegate {
    static let savedFrameKey = "zutalk.subtitleOverlay.frame"

    private let store: ActiveBilingualTranscriptStore
    private var hostingView: NSHostingView<SubtitleOverlayView>?
    private var presentationSettingsCancellable: AnyCancellable?
    private var themeCancellable: AnyCancellable?
    private var restoredWindowFrame: NSRect?
    private var restoredContentMinSize: NSSize?
    private var restoredContentMaxSize: NSSize?
    private var isApplyingMaximizedTransition = false
    private(set) var placement: SubtitleOverlayPlacement = .restored

    /// Both presentation placements share the window treatment — no shadow, no
    /// dragging, above full-screen apps — and every existing call site asks
    /// this question rather than which of the two it is.
    var isMaximized: Bool { placement != .restored }

    var windowSurfaceID: WindowSurfaceID { .subtitleOverlay }
    var managedWindow: NSWindow {
        guard let window else { preconditionFailure("SubtitleOverlayController.window missing") }
        return window
    }

    init(store: ActiveBilingualTranscriptStore) {
        self.store = store
        let spec = WindowSpec.required(.subtitleOverlay)
        let panel = NSPanel(
            contentRect: spec.initialContentRect,
            styleMask: spec.styleMask,
            backing: .buffered,
            defer: false
        )
        panel.identifier = NSUserInterfaceItemIdentifier(WindowSurfaceID.subtitleOverlay.rawValue)
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        configureManagedWindow()
        configurePanel()
        installRootView()
        observePresentationSettings()
        managedWindow.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func close() {
        super.close()
        WindowCoordinator.shared.didCloseManagedSurface(.subtitleOverlay)
        SubtitleOverlayCoordinator.shared.surfaceDidClose()
    }

    func windowDidMove(_ notification: Notification) {
        persistFrame()
    }

    func windowDidResize(_ notification: Notification) {
        // A banner resize is the operator choosing how much of the slide the
        // strip may cover. That is the one thing about this placement worth
        // remembering, and it is remembered per operator, not per display.
        if placement == .banner, isApplyingMaximizedTransition == false {
            SubtitleOverlayBannerMetrics.persistHeight(managedWindow.frame.height)
            return
        }
        persistFrame()
    }

    /// Presentation placements follow the window to whatever display it lands
    /// on. Dragging the overlay onto the projector is the ordinary way to set
    /// one up, and a strip still sized for the laptop would have to be fixed
    /// by hand — the thing this placement exists to avoid.
    func windowDidChangeScreen(_ notification: Notification) {
        guard isApplyingMaximizedTransition == false,
              let visibleFrame = managedWindow.screen?.visibleFrame
        else { return }
        let frame: NSRect
        switch placement {
        case .restored:
            return
        case .filled:
            frame = visibleFrame.integral
        case .banner:
            frame = SubtitleOverlayBannerMetrics.frame(in: visibleFrame)
            managedWindow.contentMinSize = NSSize(
                width: frame.width,
                height: SubtitleOverlayBannerMetrics.minimumHeight
            )
            managedWindow.contentMaxSize = NSSize(
                width: frame.width,
                height: max(
                    SubtitleOverlayBannerMetrics.minimumHeight,
                    visibleFrame.height * SubtitleOverlayBannerMetrics.maximumHeightFraction
                )
            )
        }
        _ = WindowCoordinator.shared.applyFrame(
            frame,
            to: .subtitleOverlay,
            animated: false,
            reason: "window.subtitle-overlay.display-change"
        )
    }

    var storeForTesting: ActiveBilingualTranscriptStore {
        store
    }

    static func loadSavedFrame(defaults: UserDefaults = .standard) -> NSRect? {
        guard let encoded = defaults.string(forKey: savedFrameKey) else { return nil }
        let rect = NSRectFromString(encoded)
        return rect.width > 0 && rect.height > 0 ? rect : nil
    }

    /// Expands the subtitle canvas over the usable frame of its current
    /// display without creating a separate macOS Space. The menu bar and Dock
    /// remain reachable, while the live overlay stays above presentation
    /// software and restores the exact operator-sized window on exit.
    @discardableResult
    func setMaximized(
        _ shouldMaximize: Bool,
        targetFrame: NSRect? = nil,
        applyFrame: (NSRect) -> Bool
    ) -> Bool {
        setPlacement(
            shouldMaximize ? .filled : .restored,
            targetFrame: targetFrame,
            applyFrame: applyFrame
        ) != .restored
    }

    /// Moves the overlay between its operator placement and the two
    /// presentation placements, restoring the exact operator-sized window on
    /// the way back out.
    ///
    /// `targetFrame` names the display to present on; for `banner` the strip
    /// is derived from it rather than used as-is, so a caller cannot ask for a
    /// banner that is not the width of its display.
    @discardableResult
    func setPlacement(
        _ target: SubtitleOverlayPlacement,
        targetFrame: NSRect? = nil,
        applyFrame: (NSRect) -> Bool
    ) -> SubtitleOverlayPlacement {
        guard target != placement else { return placement }

        guard target != .restored else {
            let frame = restoredWindowFrame ?? managedWindowSpec.initialContentRect
            isApplyingMaximizedTransition = true
            placement = .restored
            restoreWindowChrome()
            let didApplyFrame = applyFrame(frame)
            restoredWindowFrame = nil
            isApplyingMaximizedTransition = false
            guard didApplyFrame else { return placement }
            persistFrame()
            return placement
        }

        guard let visibleFrame = targetFrame
            ?? managedWindow.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSScreen.screens.first?.visibleFrame
        else { return placement }

        // Going straight from one presentation placement to the other must not
        // record the presentation frame as the window to come back to.
        let previous = placement
        if previous == .restored {
            restoredWindowFrame = managedWindow.frame
            restoredContentMinSize = managedWindow.contentMinSize
            restoredContentMaxSize = managedWindow.contentMaxSize
        }

        isApplyingMaximizedTransition = true
        placement = target
        let frame = applyPresentationChrome(for: target, in: visibleFrame)

        let didApplyFrame = applyFrame(frame)
        isApplyingMaximizedTransition = false
        if didApplyFrame == false {
            placement = previous
            // The chrome for `target` is already on the window. Leaving it
            // there would strand the panel in one placement's bounds while it
            // reports another — a banner that reports as filled would be stuck
            // at the display width with no way to resize out of it.
            if previous == .restored {
                restoredWindowFrame = nil
                restoreWindowChrome()
            } else {
                _ = applyPresentationChrome(for: previous, in: visibleFrame)
            }
        }
        return placement
    }

    /// Applies the window treatment a presentation placement needs and returns
    /// the frame it wants. Bounds are widened before the frame is applied
    /// because a frame larger than the current maximum content size would
    /// otherwise be clamped on the way in.
    @discardableResult
    private func applyPresentationChrome(
        for placement: SubtitleOverlayPlacement,
        in visibleFrame: NSRect
    ) -> NSRect {
        managedWindow.isMovable = false
        managedWindow.isMovableByWindowBackground = false
        managedWindow.hasShadow = false
        managedWindow.collectionBehavior =
            SubtitleOverlayWindowPolicy.maximizedCollectionBehavior

        switch placement {
        case .restored:
            preconditionFailure("restored is not a presentation placement")
        case .filled:
            managedWindow.contentMaxSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
            managedWindow.styleMask = managedWindow.styleMask.subtracting(.resizable)
            return visibleFrame.integral
        case .banner:
            // Width is locked to the display by pinning both content bounds to
            // it, which leaves AppKit's own resize handles working vertically.
            // The operator drags the height they want and never touches width.
            let banner = SubtitleOverlayBannerMetrics.frame(in: visibleFrame)
            managedWindow.styleMask = managedWindow.styleMask.union(.resizable)
            managedWindow.contentMinSize = NSSize(
                width: banner.width,
                height: SubtitleOverlayBannerMetrics.minimumHeight
            )
            managedWindow.contentMaxSize = NSSize(
                width: banner.width,
                height: max(
                    SubtitleOverlayBannerMetrics.minimumHeight,
                    visibleFrame.height * SubtitleOverlayBannerMetrics.maximumHeightFraction
                )
            )
            return banner
        }
    }

    private func configurePanel() {
        guard let panel = managedWindow as? NSPanel else { return }
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = true
    }

    private func observePresentationSettings() {
        presentationSettingsCancellable = SubtitleOverlayPresentationSettings.shared.$isPinned
            .removeDuplicates()
            .sink { [weak self] isPinned in
                self?.applyPinnedState(isPinned)
            }
        themeCancellable = SubtitleOverlayPresentationSettings.shared.$theme
            .removeDuplicates()
            .sink { [weak self] theme in
                self?.applyTheme(theme)
            }
    }

    /// Pinning the appearance to the window rather than to the hosting view
    /// keeps the panel's own chrome — the resize edges and the shadow AppKit
    /// draws outside the SwiftUI content — in the same theme as the canvas.
    private func applyTheme(_ theme: SubtitleOverlayTheme) {
        managedWindow.appearance = theme.appearance
    }

    private func applyPinnedState(_ isPinned: Bool) {
        managedWindow.level = SubtitleOverlayWindowPolicy.level(isPinned: isPinned)
        managedWindow.collectionBehavior = isMaximized
            ? SubtitleOverlayWindowPolicy.maximizedCollectionBehavior
            : SubtitleOverlayWindowPolicy.collectionBehavior(isPinned: isPinned)
        if isPinned, managedWindow.isVisible {
            managedWindow.orderFrontRegardless()
        }
    }

    private func installRootView() {
        let hostingView = WindowHosting.makeView(
            rootView: SubtitleOverlayView(store: store),
            policy: managedWindowSpec.hostingPolicy
        )
        WindowHosting.installPinnedView(hostingView, into: managedWindow)
        _ = WindowHosting.stabilizeWindowTree(on: managedWindow)
        self.hostingView = hostingView
        managedWindow.contentViewController = nil
    }

    private func restoreWindowChrome() {
        managedWindow.styleMask = managedWindow.styleMask.union(.resizable)
        // The banner locks both content bounds to its display's width. Putting
        // the spec's bounds back is not enough: whichever of the two the spec
        // leaves unset would keep the display width and the restored window
        // could then only ever be that wide.
        if let restoredContentMinSize {
            managedWindow.contentMinSize = restoredContentMinSize
        }
        if let restoredContentMaxSize {
            managedWindow.contentMaxSize = restoredContentMaxSize
        }
        restoredContentMinSize = nil
        restoredContentMaxSize = nil
        managedWindow.hasShadow = managedWindowSpec.chrome.hasShadow
        if let isMovable = managedWindowSpec.chrome.isMovable {
            managedWindow.isMovable = isMovable
        }
        if let isMovableByWindowBackground = managedWindowSpec.chrome.isMovableByWindowBackground {
            managedWindow.isMovableByWindowBackground = isMovableByWindowBackground
        }
        if let maximumContentSize = managedWindowSpec.chrome.maximumContentSize {
            managedWindow.contentMaxSize = maximumContentSize
        }
        applyPinnedState(SubtitleOverlayPresentationSettings.shared.isPinned)
    }

    private func persistFrame(defaults: UserDefaults = .standard) {
        guard isMaximized == false, isApplyingMaximizedTransition == false else { return }
        defaults.set(NSStringFromRect(managedWindow.frame), forKey: Self.savedFrameKey)
    }
}
