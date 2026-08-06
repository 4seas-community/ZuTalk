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
}
