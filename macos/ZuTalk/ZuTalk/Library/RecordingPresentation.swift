import SwiftUI

/// How a recording is described wherever it is listed, so Home, a topic and
/// the transcript header say the same thing the same way.
///
/// Rows used to disagree with each other and with themselves: "中 · EN" on
/// Home, "zh · en · th" in a topic, durations as "02:00" beside clock times
/// in the same font, and a green "completed" badge on nearly every row.
enum RecordingPresentation {
    /// A language as its own speakers write it — 中文, English, ไทย — which
    /// reads the same whatever language the app is shown in.
    nonisolated static func languageName(_ code: String) -> String {
        let normalized = code
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        let base = normalized.split(separator: "-").first.map(String.init) ?? normalized
        guard base.isEmpty == false, base != "und" else { return "" }
        let name = Locale(identifier: base).localizedString(forLanguageCode: base)
            ?? Locale.current.localizedString(forLanguageCode: base)
            ?? base.uppercased()
        // Autonyms come lowercased for some languages ("français"); a label
        // starts with a capital where the script has one.
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    nonisolated static func languageList(_ codes: [String]) -> String {
        var seen = Set<String>()
        return codes
            .map(languageName)
            .filter { $0.isEmpty == false && seen.insert($0).inserted }
            .joined(separator: " · ")
    }

    /// "12 min", "1 hr 5 min", "45 sec" — never a clock face, which next to
    /// a start time reads as another time of day.
    nonisolated static func duration(ms: UInt64) -> String? {
        let seconds = TimeInterval(ms) / 1_000
        guard seconds >= 1 else { return nil }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .short
        formatter.maximumUnitCount = 2
        formatter.allowedUnits = seconds >= 60 ? [.hour, .minute] : [.second]
        return formatter.string(from: seconds)
    }

    /// Only what needs attention gets a badge. A finished recording is the
    /// normal case and says nothing.
    enum Status: Equatable {
        case recording
        case transcribing
        case interrupted
        case failed

        var text: String {
            switch self {
            case .recording: return String(localized: "home.status.recording")
            case .transcribing: return String(localized: "home.status.transcribing")
            case .interrupted: return String(localized: "home.status.interrupted")
            case .failed: return String(localized: "home.status.failed")
            }
        }

        var icon: String {
            switch self {
            case .recording: return "record.circle.fill"
            case .transcribing: return "hourglass"
            case .interrupted: return "exclamationmark.circle.fill"
            case .failed: return "exclamationmark.triangle.fill"
            }
        }

        var color: Color {
            switch self {
            case .recording: return .signalRed
            case .transcribing, .interrupted: return .signalAmber
            case .failed: return .destructive
            }
        }
    }

    /// A stored title, or nothing: an untitled recording is identified by its
    /// time and its first words, not by the word "Untitled".
    nonisolated static func title(_ stored: String) -> String? {
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The one line a recording goes by in a list: its title, else its first
    /// words on one line. Nil when it has neither, and the row says so with
    /// a placeholder.
    nonisolated static func rowWords(title: String?, preview: String) -> String? {
        if let title = title.flatMap(Self.title) { return title }
        let words = preview
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.isEmpty == false }
            .joined(separator: " ")
        return words.isEmpty ? nil : words
    }

    /// What a row says about a recording beyond its name, languages and
    /// topic: one thing at most. A state that needs attention comes first;
    /// then where the audio is, when that is another Mac; then that it was
    /// brought in rather than recorded here.
    enum RowMark: Equatable {
        case status(Status)
        case otherDevice(String)
        case imported

        nonisolated static func resolve(
            status: Status?,
            recordedOn: String?,
            isImport: Bool
        ) -> RowMark? {
            if let status { return .status(status) }
            if let recordedOn { return .otherDevice(recordedOn) }
            return isImport ? .imported : nil
        }
    }
}

/// A recording's name in a list, on one line: its title, else what was said
/// first, else a word for why there is nothing. A state that needs attention
/// follows it as an icon and a word.
struct RecordingRowText: View {
    let title: String?
    let preview: String
    let placeholder: String?
    var status: RecordingPresentation.Status?

    var body: some View {
        let words = RecordingPresentation.rowWords(title: title, preview: preview)
        HStack(spacing: Spacing.sm) {
            Text(words ?? placeholder ?? String(localized: "recording.row.no_words"))
                .font(.bodyMedium)
                .foregroundColor(words == nil ? .textTertiary : .textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            if let status {
                Label(status.text, systemImage: status.icon)
                    .font(.bodySM)
                    .foregroundColor(status.color)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }
}
