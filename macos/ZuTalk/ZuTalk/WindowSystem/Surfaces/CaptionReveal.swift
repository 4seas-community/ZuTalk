import Foundation

/// How one writing system is revealed on the caption canvas: in what units,
/// how fast, and how late at most.
///
/// Translations reach the canvas in mouthfuls — about fifteen provider
/// tokens every 1.4 s — and pasting each as one slab reads as blocks.
/// Pacing spreads a mouthful over the gap before the next one. What counts
/// as one step differs by script, and getting it wrong in either direction
/// shows: Latin text paced by character crawls, CJK text paced by space-
/// separated word arrives in sentence-sized jumps, and Thai has no spaces at
/// all, so a character-based pace cut words between a consonant and its
/// vowel sign and ran at less than the speed Thai arrives.
struct CaptionScriptProfile: Equatable {
    enum Unit: Equatable {
        /// Whitespace-separated words, each with the space after it.
        case spacedWord
        /// One character (grapheme cluster) per step.
        case character
        /// Dictionary word boundaries from the system tokenizer, for scripts
        /// written without spaces between words.
        case tokenizedWord(localeIdentifier: String)
    }

    let unit: Unit
    /// Steps per second while a mouthful is being spread out.
    let rate: Double
    /// No step appears later than this after its text arrived, whatever
    /// the backlog and however late the screen is drawn.
    let latencyBudget: TimeInterval

    static let latin = Self(unit: .spacedWord, rate: 9, latencyBudget: 1.2)
    static let korean = Self(unit: .spacedWord, rate: 7, latencyBudget: 1.2)
    static let cjk = Self(unit: .character, rate: 18, latencyBudget: 1.2)
    static let thai = Self(unit: .tokenizedWord(localeIdentifier: "th"), rate: 8, latencyBudget: 1.2)

    /// By the column's language when it is known — the cheapest and surest
    /// signal — and by the text's script otherwise.
    static func forLanguage(_ language: String?, text: String) -> Self {
        let code = (language ?? "").lowercased().split(separator: "-").first.map(String.init) ?? ""
        switch code {
        case "th": return .thai
        case "zh", "ja", "yue": return .cjk
        case "ko": return .korean
        case "": return forScript(of: text)
        default: return .latin
        }
    }

    static func forScript(of text: String) -> Self {
        var cjk = 0
        var thai = 0
        var hangul = 0
        var scored = 0
        for scalar in text.unicodeScalars.prefix(400) {
            guard scalar.properties.isAlphabetic else { continue }
            scored += 1
            switch scalar.value {
            case 0x2E80...0x9FFF, 0x3040...0x30FF, 0xF900...0xFAFF: cjk += 1
            case 0x0E00...0x0E7F: thai += 1
            case 0xAC00...0xD7AF, 0x1100...0x11FF: hangul += 1
            default: break
            }
        }
        guard scored > 0 else { return .latin }
        if thai * 2 >= scored { return .thai }
        if cjk * 2 >= scored { return .cjk }
        if hangul * 2 >= scored { return .korean }
        return .latin
    }

    /// End offsets (UTF-8) of each step of `text`, in order; the last one is
    /// the end of the text.
    func unitEnds(of text: String) -> [Int] {
        guard text.isEmpty == false else { return [] }
        var ends: [Int] = []
        switch unit {
        case .character:
            var offset = 0
            for character in text {
                offset += character.utf8.count
                if character.isWhitespace, let last = ends.indices.last {
                    ends[last] = offset
                } else {
                    ends.append(offset)
                }
            }
        case .spacedWord:
            var offset = 0
            var inWord = false
            for character in text {
                let isSpace = character.isWhitespace
                if isSpace == false, inWord == false, offset > 0 { ends.append(offset) }
                inWord = isSpace == false
                offset += character.utf8.count
            }
            ends.append(offset)
        case .tokenizedWord(let localeIdentifier):
            ends = Self.tokenizedEnds(of: text, localeIdentifier: localeIdentifier)
        }
        if ends.last != text.utf8.count { ends.append(text.utf8.count) }
        return ends
    }

    /// Word boundaries from `CFStringTokenizer`, which segments Thai by
    /// dictionary. Boundaries come in UTF-16 and are mapped to UTF-8 so a
    /// step never ends inside a grapheme cluster: a Thai vowel or tone mark
    /// always stays with its consonant.
    private static func tokenizedEnds(of text: String, localeIdentifier: String) -> [Int] {
        let string = text as NSString
        let tokenizer = CFStringTokenizerCreate(
            nil,
            string,
            CFRange(location: 0, length: string.length),
            kCFStringTokenizerUnitWordBoundary,
            Locale(identifier: localeIdentifier) as CFLocale
        )
        var utf16Ends: [Int] = []
        while CFStringTokenizerAdvanceToNextToken(tokenizer) != [] {
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            let end = range.location + range.length
            // A token of spaces belongs to the word before it.
            let token = string.substring(with: NSRange(location: range.location, length: range.length))
            if token.allSatisfy(\.isWhitespace), utf16Ends.isEmpty == false {
                utf16Ends[utf16Ends.count - 1] = end
            } else {
                utf16Ends.append(end)
            }
        }
        var ends: [Int] = []
        ends.reserveCapacity(utf16Ends.count)
        for utf16End in utf16Ends {
            // Snap to a character boundary, then measure in UTF-8.
            let index = String.Index(utf16Offset: utf16End, in: text)
            let boundary = text.rangeOfComposedCharacterSequence(
                at: index == text.endIndex ? text.index(before: index) : index
            )
            let snapped = index == text.endIndex || index == boundary.lowerBound ? index : boundary.upperBound
            let offset = text.utf8.distance(from: text.startIndex, to: snapped)
            if offset > (ends.last ?? 0) { ends.append(offset) }
        }
        return ends
    }
}

/// When each step of a caption card appears.
///
/// The old reveal advanced a cursor by a fixed 33 ms per timer tick. The
/// timer runs on the main thread, so whenever the main thread was busy each
/// tick came late and still counted as 33 ms; the reveal slowed by exactly
/// the factor the app was behind, the backlog grew, and the card trailed the
/// speech more and more. A plan instead gives every step a due time when its
/// text arrives, and what is visible is a function of the clock alone: a
/// late frame draws more at once, and nothing accumulates.
struct CaptionRevealPlan: Equatable {
    let text: String
    let profile: CaptionScriptProfile
    /// UTF-8 end offset of each step.
    let ends: [Int]
    /// When each step arrived, and when it is due; both non-decreasing.
    let arrivals: [TimeInterval]
    let dues: [TimeInterval]

    static func start(
        text: String,
        profile: CaptionScriptProfile,
        now: TimeInterval,
        revealed: Bool
    ) -> Self {
        let empty = Self(text: "", profile: profile, ends: [], arrivals: [], dues: [])
        let plan = empty.updated(text: text, now: now)
        guard revealed else { return plan }
        return Self(
            text: plan.text,
            profile: profile,
            ends: plan.ends,
            arrivals: plan.arrivals,
            dues: plan.dues.map { _ in -.infinity }
        )
    }

    /// The plan for a revised text. Steps that survived unchanged keep their
    /// schedule — nothing the reader has seen is replayed — and every step
    /// still to come is spread from now over at most the latency budget.
    func updated(text newText: String, now: TimeInterval) -> Self {
        if newText == text { return self }
        let newEnds = profile.unitEnds(of: newText)
        let shared = zip(text.utf8, newText.utf8).prefix(while: { $0 == $1 }).count
        var arrivals: [TimeInterval] = []
        var dues: [TimeInterval] = []
        arrivals.reserveCapacity(newEnds.count)
        dues.reserveCapacity(newEnds.count)
        for (index, end) in newEnds.enumerated() {
            // A step survives when the old step it continues lay entirely in
            // the unchanged prefix — a word the provider has only extended,
            // or one that just gained its trailing space, stays where it was.
            let start = index == 0 ? 0 : newEnds[index - 1]
            if index < ends.count,
               ends[index] <= shared,
               (index == 0 ? 0 : ends[index - 1]) == start,
               end >= ends[index] {
                arrivals.append(self.arrivals[index])
                dues.append(self.dues[index])
            } else {
                arrivals.append(now)
                dues.append(.infinity)
            }
        }
        // Spread everything not yet shown.
        let pending = dues.indices.filter { dues[$0] > now }
        if pending.isEmpty == false {
            let span = min(Double(pending.count) / profile.rate, profile.latencyBudget)
            var previous = -TimeInterval.infinity
            for (position, index) in pending.enumerated() {
                let planned = now + span * Double(position + 1) / Double(pending.count)
                let due = max(previous, min(planned, arrivals[index] + profile.latencyBudget))
                dues[index] = due
                previous = due
            }
        }
        return Self(text: newText, profile: profile, ends: newEnds, arrivals: arrivals, dues: dues)
    }

    /// How many steps are visible at `now`.
    func visibleSteps(at now: TimeInterval) -> Int {
        var low = 0
        var high = dues.count
        while low < high {
            let middle = (low + high) / 2
            if dues[middle] <= now { low = middle + 1 } else { high = middle }
        }
        return low
    }

    func visibleText(at now: TimeInterval) -> String {
        let steps = visibleSteps(at: now)
        guard steps > 0 else { return "" }
        guard steps < ends.count else { return text }
        let end = text.utf8.index(text.utf8.startIndex, offsetBy: ends[steps - 1])
        return String(text[..<end])
    }

    /// When the whole text is visible.
    var completesAt: TimeInterval { dues.last ?? -.infinity }
}
