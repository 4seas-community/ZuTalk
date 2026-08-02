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
    static let defaultsKey = "zulangue.subtitleOverlay.fontSize"
    static let modeDefaultsKey = "zulangue.subtitleOverlay.fontMode"
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
        let widthBudget = Double(canvasSize.width - 24) / (perColumnFactor * columns)
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

enum SubtitleOverlayConversationLayout: Equatable {
    case columns
    case stacked
}

enum SubtitleOverlayLayoutPolicy {
    static let maximumLanguageCount = 3
    static let maximumAudienceRowCount = 8

    static func conversationLayout(
        width: CGFloat,
        languageCount: Int,
        fontSize: Double
    ) -> SubtitleOverlayConversationLayout {
        width >= minimumColumnWidth(fontSize: fontSize) * CGFloat(max(languageCount, 1))
            ? .columns
            : .stacked
    }

    static func audienceColumnCount(
        width: CGFloat,
        languageCount: Int,
        fontSize: Double
    ) -> Int {
        let count = min(max(languageCount, 1), maximumLanguageCount)
        let capacity = max(
            1,
            Int(width / minimumAudienceTileWidth(fontSize: fontSize))
        )

        switch count {
        case 1:
            return 1
        case 2:
            return capacity >= 2 ? 2 : 1
        case 3:
            return capacity >= 3 ? 3 : 1
        default:
            if capacity >= 4 { return 4 }
            if capacity >= 2 { return 2 }
            return 1
        }
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
        /// Provider order, the tiebreak within one stream's own output.
        let order: UInt64
        /// A final source line bypasses the visual refresh budget so the
        /// audience never leaves the last correction buffered off-screen.
        let isComplete: Bool
    }

    /// Spoken order: anchored items by time (source before its own
    /// translation on a tie), unanchored items after everything timed.
    /// Timestamps restart when a whole stream group restarts, so ordering
    /// across a restart leans on the fact that old-epoch items leave the
    /// visible suffix almost immediately.
    static func columns(
        languages: [String],
        utterances: [NotebookCaptureUtteranceDTO],
        placement: (NotebookCaptureUtteranceDTO) -> String?,
        cues: (String) -> [NotebookCaptureTranslationCueDTO],
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
            retain(Item(
                id: "source:\(utterance.id)",
                kind: .source,
                text: utterance.sourceText,
                anchorMs: utterance.sourceStartMs,
                endMs: utterance.sourceEndMs,
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
                retain(Item(
                    id: "cue:\(cue.id)",
                    kind: .translation,
                    text: cue.text,
                    anchorMs: cue.sourceStartMs,
                    endMs: cue.sourceEndMs,
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
        switch (left.anchorMs, right.anchorMs) {
        case let (.some(leftAnchor), .some(rightAnchor)) where leftAnchor != rightAnchor:
            return leftAnchor < rightAnchor
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        default:
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
        let columns = SubtitleAudienceTimeline.columns(
            languages: languages,
            utterances: utterances,
            placement: placement,
            cues: cues
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

/// Coalesces high-frequency canonical hypotheses without animating the whole
/// text block. A 180 ms opacity transition restarted by every Chinese partial
/// produced overlapping snapshots — the visible ghosting reported by users.
private struct AudienceStableSourceText: View {
    let update: SubtitleAudienceSourceRefresh.Update
    let fontSize: Double

    @State private var refresh: SubtitleAudienceSourceRefresh.State
    @State private var scheduledFlush: Task<Void, Never>?

    init(text: String, isComplete: Bool, fontSize: Double) {
        update = SubtitleAudienceSourceRefresh.Update(
            text: text,
            isComplete: isComplete
        )
        self.fontSize = fontSize
        _refresh = State(initialValue: SubtitleAudienceSourceRefresh.State(text: text))
    }

    var body: some View {
        Text(refresh.displayedText)
            .font(.system(size: CGFloat(fontSize), weight: .semibold))
            .foregroundColor(.primary)
            .textSelection(.enabled)
            .multilineTextAlignment(.leading)
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
            guard Task.isCancelled == false else { return }
            refresh.flush()
            scheduledFlush = nil
        }
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

    static let defaultsKey = "zulangue.subtitleOverlay.theme"

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
    static let defaultsKey = "zulangue.subtitleOverlay.backgroundOpacity"
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
    static let pinnedDefaultsKey = "zulangue.subtitleOverlay.isPinned"

    static func level(isPinned: Bool) -> NSWindow.Level {
        isPinned ? .floating : .normal
    }

    static func collectionBehavior(isPinned: Bool) -> NSWindow.CollectionBehavior {
        isPinned
            ? [.canJoinAllSpaces, .fullScreenAuxiliary]
            : [.moveToActiveSpace, .fullScreenAuxiliary]
    }
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

    private static let displayModeDefaultsKey = "zulangue.subtitleOverlay.displayMode"

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

    init(store: ActiveBilingualTranscriptStore) {
        self.store = store
        _livePresentation = ObservedObject(wrappedValue: store.livePresentation)
    }

    var body: some View {
        subtitleBody
            .frame(minWidth: 560, minHeight: 180)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(SubtitleOverlayPalette.surface.opacity(canvasOpacity))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(SubtitleOverlayPalette.hairline, lineWidth: 0.5)
                    )
            )
            .overlay(alignment: .top) { hoverControlBar }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.15)) {
                    isHoveringOverlay = hovering
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(String(localized: "subtitle.overlay.accessibility_label")))
            .accessibilityValue(Text(String(
                format: String(localized: "subtitle.overlay.language_count"),
                store.selectedLanguages.count
            )))
            .environment(\.colorScheme, presentationSettings.theme.colorScheme)
    }

    /// The overlay is a projection canvas in every mode: while it is being
    /// watched rather than operated, the operator chrome stays off-screen
    /// entirely and returns only under the pointer. The window itself remains
    /// movable by its background.
    @ViewBuilder
    private var hoverControlBar: some View {
        if isHoveringOverlay {
            VStack(spacing: 0) {
                controlBar
                Divider().overlay(SubtitleOverlayPalette.hairline)
            }
            .background(SubtitleOverlayPalette.surface.opacity(controlsOpacity))
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

    private var controlBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                captureStatus

                Text(String(localized: "subtitle.overlay.title"))
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)

                Spacer(minLength: 16)

                modePicker
                fontControls
                backdropOpacityControl
                themeButton
                pinButton
                closeButton
            }

            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    captureStatus
                    Spacer(minLength: 8)
                    backdropOpacityControl
                    themeButton
                    pinButton
                    closeButton
                }
                HStack(spacing: 8) {
                    modePicker
                    Spacer(minLength: 8)
                    fontControls
                }
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .help(String(localized: "subtitle.overlay.move_resize_hint"))
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
            .help(String(localized: "subtitle.overlay.degraded_lanes"))
            .accessibilityLabel(Text(String(localized: "subtitle.overlay.degraded_lanes")))
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

    private var subtitleBody: some View {
        GeometryReader { geometry in
            Group {
                switch presentationSettings.displayMode {
                case .conversation:
                    conversationBody(geometry: geometry)
                case .audience:
                    audienceBody(geometry: geometry)
                }
            }
            .onAppear { canvasSize = geometry.size }
            .onChange(of: geometry.size) { _, size in canvasSize = size }
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
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(utterances.suffix(rowBudget)) { utterance in
                        conversationRow(utterance, layout: layout)
                    }
                }
                .padding(12)
            }
            .defaultScrollAnchor(.bottom)
            .scrollIndicators(.visible)
        }
    }

    @ViewBuilder
    private func conversationTimelineTranscript(
        layout: SubtitleOverlayConversationLayout,
        rowBudget: Int,
        utterances: [NotebookCaptureUtteranceDTO]
    ) -> some View {
        let timeline = SubtitleConversationTimeline.projection(
            languages: displayLanguages,
            utterances: utterances,
            placement: { store.audienceSourcePlacement(for: $0) },
            cues: { store.presentedTranslationCues(for: $0) },
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
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(timeline.historicalUtterances.suffix(historyBudget)) { utterance in
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
            .defaultScrollAnchor(.bottom)
            .scrollIndicators(.visible)
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

    @ViewBuilder
    private func audienceTimelineBody(geometry: GeometryProxy) -> some View {
        let languages = store.selectedLanguages
        // Freeze one coherent presentation frame. The previous body rebuilt
        // and sorted the complete session three times, and recomputed the
        // durable language fallback once for every source row. Provider-rate
        // preview updates therefore became progressively more expensive as a
        // meeting grew even though the canvas shows at most eight cards.
        let utterances = store.presentedAudienceUtterances(
            maximumRows: SubtitleOverlayLayoutPolicy.maximumAudienceRowCount
        )
        let placement = store.makeAudienceSourcePlacement()
        let cuesByLanguage = Dictionary(
            grouping: store.presentedTranslationCueSnapshot,
            by: { normalizedLanguageCode($0.targetLanguage) }
        )
        let bandSize = SubtitleOverlayLayoutPolicy.audienceColumnCount(
            width: geometry.size.width - 24,
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
            visibleLimit: itemBudget
        )
        let waiting = SubtitleAudienceTimeline.waitingLanguages(
            columns: columns,
            failedLanguages: store.failedTranslationLanguages
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
        let hasWords = trimmed.values.contains { $0.isEmpty == false } || unrouted != nil

        if store.isCaptureActive, hasWords {
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
            if waiting {
                Image(systemName: "ellipsis")
                    .font(.system(size: max(CGFloat(fontSize) * 0.55, 12), weight: .semibold))
                    .foregroundColor(.secondary.opacity(0.55))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: CGFloat(fontSize) * 1.6,
                        alignment: .bottomLeading
                    )
                    .background(subtitleCardBackground)
            }
        }
        .frame(maxWidth: .infinity, alignment: .bottom)
        .animation(.easeOut(duration: 0.22), value: items.map(\.id))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(languageName(language)))
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
                    audienceRow(utterance, width: geometry.size.width - 24)
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

        if let pendingLanguage = projection.pendingLanguage {
            statusRow(
                title: String(localized: "capture.transcript.language_pending"),
                detail: pendingLanguage,
                systemImage: "ellipsis",
                color: .secondary
            )
        } else if let outsideText = projection.unselectedLanguageText {
            statusRow(
                title: String(
                    format: String(localized: "capture.transcript.unselected_language"),
                    displayLanguageCode(utterance.sourceLanguage)
                ),
                detail: outsideText,
                systemImage: "character.bubble",
                color: .secondary
            )
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
                    conversationLane(lane)
                    if index < lanes.count - 1 {
                        Divider().overlay(SubtitleOverlayPalette.hairline)
                    }
                }
            }
            .background(subtitleCardBackground)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(lanes.enumerated()), id: \.offset) { index, lane in
                    conversationLane(lane)
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

    private func conversationLane(_ lane: NotebookCaptureLanguageLane) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            laneContent(lane)
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
    private func laneContent(_ lane: NotebookCaptureLanguageLane) -> some View {
        if let text = lane.text, text.isEmpty == false {
            Text(text)
                .foregroundColor(.primary)
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
        code
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-")
            .first
            .map(String.init) ?? code.lowercased()
    }
}

@MainActor
final class SubtitleOverlayController: NSWindowController, ManagedWindowControllerV2, NSWindowDelegate {
    private static let savedFrameKey = "zulangue.subtitleOverlay.frame"

    private let store: ActiveBilingualTranscriptStore
    private var hostingView: NSHostingView<SubtitleOverlayView>?
    private var presentationSettingsCancellable: AnyCancellable?
    private var themeCancellable: AnyCancellable?

    var windowSurfaceID: WindowSurfaceID { .subtitleOverlay }
    var managedWindow: NSWindow {
        guard let window else { preconditionFailure("SubtitleOverlayController.window missing") }
        return window
    }

    init(store: ActiveBilingualTranscriptStore) {
        self.store = store
        let spec = WindowSpecV2.required(.subtitleOverlay)
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
        persistFrame()
    }

    var storeForTesting: ActiveBilingualTranscriptStore {
        store
    }

    static func loadSavedFrame(defaults: UserDefaults = .standard) -> NSRect? {
        guard let encoded = defaults.string(forKey: savedFrameKey) else { return nil }
        let rect = NSRectFromString(encoded)
        return rect.width > 0 && rect.height > 0 ? rect : nil
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
        managedWindow.collectionBehavior =
            SubtitleOverlayWindowPolicy.collectionBehavior(isPinned: isPinned)
        if isPinned, managedWindow.isVisible {
            managedWindow.orderFrontRegardless()
        }
    }

    private func installRootView() {
        let hostingView = WindowHostingV2.makeView(
            rootView: SubtitleOverlayView(store: store),
            policy: managedWindowSpec.hostingPolicy
        )
        WindowHostingV2.installPinnedView(hostingView, into: managedWindow)
        _ = WindowHostingV2.stabilizeWindowTree(on: managedWindow)
        self.hostingView = hostingView
        managedWindow.contentViewController = nil
    }

    private func persistFrame(defaults: UserDefaults = .standard) {
        defaults.set(NSStringFromRect(managedWindow.frame), forKey: Self.savedFrameKey)
    }
}
