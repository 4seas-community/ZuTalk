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
}

/// A recording's list entry text: its title when it has one, and what was
/// said. Without a title the first words take the title's place.
struct RecordingRowText: View {
    let title: String?
    let preview: String
    let placeholder: String?
    var status: RecordingPresentation.Status?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let title {
                HStack(spacing: Spacing.sm) {
                    Text(title)
                        .font(.bodyMedium)
                        .foregroundColor(.textPrimary)
                        .lineLimit(1)
                    statusBadge
                }
                if preview.isEmpty == false {
                    Text(preview)
                        .font(.bodySM)
                        .foregroundColor(.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if preview.isEmpty == false {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                    Text(preview)
                        .font(.bodyMedium)
                        .foregroundColor(.textPrimary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    statusBadge
                }
            } else {
                HStack(spacing: Spacing.sm) {
                    Text(placeholder ?? String(localized: "recording.row.no_words"))
                        .font(.bodyMedium)
                        .foregroundColor(.textTertiary)
                    statusBadge
                }
            }
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        if let status {
            Label(status.text, systemImage: status.icon)
                .font(.bodySM)
                .foregroundColor(status.color)
                .lineLimit(1)
                .fixedSize()
        }
    }
}
