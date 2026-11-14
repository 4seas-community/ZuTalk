// RecordingPlanSentence.swift
// 「开始录音」下面那一句:这一场会怎么录。
//
// 开始之前要定的事有好几样 —— 说什么语言、译成什么、声音从哪来、出不出字、
// 放不放进主题 —— 每一样都有默认值。把它们摆成一排控件放在按钮前面,人就得
// 先看懂每一样才敢按开始。所以默认值只用一句话念出来,想改的人点「更改」
// (docs/product/interface-layers.md)。

import Foundation

/// How the next recording will be made: everything the sentence under the
/// Start button says.
nonisolated struct RecordingPlan: Equatable, Sendable {
    nonisolated enum Source: Equatable, Sendable {
        /// Whatever microphone this Mac uses when nobody chose one.
        case thisMac
        /// A microphone the person picked, by its name.
        case microphone(String)
        /// What the Mac plays: the far side of an online meeting, a video.
        case soundFromMac
    }

    /// Languages people will speak, in the order they were chosen.
    var spoken: [String]
    /// Languages nobody speaks that everything is also translated into.
    var translatedInto: [String] = []
    var source: Source = .thisMac
    /// Text appears while recording: true whenever something can provide
    /// it. False — nothing can yet — is a recording of the sound alone.
    var liveText = true
    /// The topic the recording goes into; nil when it goes into none.
    var topic: String?
}

nonisolated enum RecordingPlanSentence {
    /// Where the phrases come from. The app reads its own strings in the
    /// language it is shown in; tests read one language's file, so a sentence
    /// can be checked word for word whatever language the test machine uses.
    nonisolated struct Wording {
        var phrase: (String) -> String
        var locale: Locale

        static var app: Wording {
            Wording(
                phrase: { Bundle.main.localizedString(forKey: $0, value: nil, table: nil) },
                locale: .current
            )
        }
    }

    /// The whole sentence: what is spoken and translated (or that nothing is
    /// written down), where the sound comes from, and the topic if there is
    /// one. Each part is a whole localized phrase; only the order of the
    /// parts and the mark between them are shared.
    static func text(_ plan: RecordingPlan, wording: Wording = .app) -> String {
        var parts: [String] = []
        if let languages = languagePhrase(plan, wording: wording) {
            parts.append(languages)
        }
        parts.append(sourcePhrase(plan.source, wording: wording))
        if let topic = plan.topic?.trimmingCharacters(in: .whitespacesAndNewlines),
           topic.isEmpty == false {
            parts.append(String(format: wording.phrase("home.plan.topic_format"), topic))
        }
        switch parts.count {
        case 1:
            return parts[0]
        case 2:
            return String(format: wording.phrase("home.plan.join2_format"), parts[0], parts[1])
        default:
            return String(
                format: wording.phrase("home.plan.join3_format"),
                parts[0], parts[1], parts[2]
            )
        }
    }

    /// What a saved profile means for the sentence. Two languages translate
    /// into each other, so both count as spoken; from three on, the ones
    /// marked as nobody's speech are the ones only translated into.
    @MainActor
    static func languages(
        selected: [String],
        subtitleOnly: [String]
    ) -> (spoken: [String], translatedInto: [String]) {
        let translated = selected.count > 2
            ? NotebookCaptureLanguageRoles.subtitleOnly(selected: selected, requested: subtitleOnly)
            : []
        return (selected.filter { translated.contains($0) == false }, translated)
    }

    private static func languagePhrase(_ plan: RecordingPlan, wording: Wording) -> String? {
        guard plan.liveText else { return wording.phrase("home.plan.audio_only") }
        let spoken = names(plan.spoken)
        // A profile that has not loaded yet names no language; say only where
        // the sound comes from rather than an empty "Speaking".
        guard spoken.isEmpty == false else { return nil }
        let translated = names(plan.translatedInto).filter { spoken.contains($0) == false }
        let phrase: String
        switch (spoken.count > 1, translated.isEmpty) {
        case (false, true):
            phrase = String(format: wording.phrase("home.plan.speak_format"), spoken[0])
        case (false, false):
            phrase = String(
                format: wording.phrase("home.plan.speak_translate_format"),
                spoken[0],
                list(translated, wording: wording)
            )
        case (true, true):
            phrase = String(
                format: wording.phrase("home.plan.speak_many_format"),
                list(spoken, wording: wording)
            )
        case (true, false):
            phrase = String(
                format: wording.phrase("home.plan.speak_many_translate_format"),
                list(spoken, wording: wording),
                list(translated, wording: wording)
            )
        }
        return spacedBetweenScripts(phrase)
    }

    private static func sourcePhrase(_ source: RecordingPlan.Source, wording: Wording) -> String {
        switch source {
        case .thisMac:
            return wording.phrase("home.plan.source.this_mac")
        case .microphone(let name):
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.isEmpty == false else {
                return wording.phrase("home.plan.source.this_mac")
            }
            return String(format: wording.phrase("home.plan.source.microphone_format"), name)
        case .soundFromMac:
            return wording.phrase("home.plan.source.sound_from_mac")
        }
    }

    /// Languages by their own names, each once, unknown codes left out.
    private static func names(_ codes: [String]) -> [String] {
        var seen = Set<String>()
        return codes
            .map(RecordingPresentation.languageName)
            .filter { $0.isEmpty == false && seen.insert($0).inserted }
    }

    private static func list(_ names: [String], wording: Wording) -> String {
        let formatter = ListFormatter()
        formatter.locale = wording.locale
        return formatter.string(from: names) ?? names.joined(separator: ", ")
    }

    /// Chinese and Japanese put no space between words, so a language named
    /// in another script ("English", "ไทย") would run into the characters
    /// around it: 「说中文和English」. One space goes at each such boundary,
    /// the way those languages are typeset. Text that already has the space,
    /// or has no such boundary, comes back unchanged.
    static func spacedBetweenScripts(_ text: String) -> String {
        enum Script { case unspaced, spaced, neither }
        func script(_ scalar: Unicode.Scalar) -> Script {
            let kana: ClosedRange<UInt32> = 0x3040...0x30FF
            if scalar.properties.isIdeographic || kana.contains(scalar.value) {
                return .unspaced
            }
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter,
                 .otherLetter, .nonspacingMark, .spacingMark, .enclosingMark:
                return .spaced
            default:
                return .neither
            }
        }
        var result = String.UnicodeScalarView()
        var previous = Script.neither
        for scalar in text.unicodeScalars {
            let current = script(scalar)
            if (previous == .unspaced && current == .spaced)
                || (previous == .spaced && current == .unspaced) {
                result.append(" ")
            }
            result.append(scalar)
            previous = current
        }
        return String(result)
    }
}
