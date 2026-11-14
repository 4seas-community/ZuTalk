import Foundation

enum NotebookAudioRetentionLevel: String, Codable, CaseIterable, Identifiable, Equatable {
    case standard
    case high
    case maximum

    var id: String { rawValue }
}

struct AudioPrivacyOptionSummary: Identifiable, Equatable {
    let level: NotebookAudioRetentionLevel

    var id: String { level.rawValue }

    var title: String {
        switch level {
        case .standard:
            String(localized: "capture.settings.retention.standard.title")
        case .high:
            String(localized: "capture.settings.retention.high.title")
        case .maximum:
            String(localized: "capture.settings.retention.maximum.title")
        }
    }

    var storageText: String {
        switch level {
        case .standard:
            String(localized: "capture.settings.retention.standard.detail")
        case .high:
            String(localized: "capture.settings.retention.high.detail")
        case .maximum:
            String(localized: "capture.settings.retention.maximum.detail")
        }
    }

    /// The icon on the pill that shows this choice: kept, or deleted.
    var systemImage: String {
        level == .standard ? "internaldrive" : "trash"
    }

    /// What each choice does to the audio, one line apiece, and when the
    /// choice takes hold. Two of the three delete audio for good, so this is
    /// what the ⓘ beside the choice says: it has to be readable before
    /// choosing, not only after.
    static var disclosure: String {
        let choices = NotebookAudioRetentionLevel.allCases.map { level -> String in
            let option = AudioPrivacyOptionSummary(level: level)
            return option.title + " — " + option.storageText
        }
        return (choices + [String(localized: "capture.settings.retention.subtitle")])
            .joined(separator: "\n")
    }
}
