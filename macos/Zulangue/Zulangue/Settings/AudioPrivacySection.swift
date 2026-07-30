import SwiftUI

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

struct AudioPrivacySection: View {
    @Binding var selection: NotebookAudioRetentionLevel
    let isEnabled: Bool

    private var options: [AudioPrivacyOptionSummary] {
        NotebookAudioRetentionLevel.allCases.map { AudioPrivacyOptionSummary(level: $0) }
    }

    var body: some View {
        SettingsCard(
            title: String(localized: "capture.settings.retention.title"),
            subtitle: String(localized: "capture.settings.retention.subtitle")
        ) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                ForEach(options) { option in
                    Button {
                        selection = option.level
                    } label: {
                        HStack(alignment: .top, spacing: Spacing.sm) {
                            Image(systemName: option.level == selection
                                  ? "largecircle.fill.circle"
                                  : "circle")
                                .font(.system(size: 12))
                                .foregroundColor(option.level == selection
                                                 ? .signalBlue
                                                 : .textTertiary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.title)
                                    .font(.captionMedium)
                                    .foregroundColor(.bpLine)
                                Text(option.storageText)
                                    .font(.caption)
                                    .foregroundColor(.textOnBpDim)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: Spacing.sm)
                        }
                    }
                    .buttonStyle(.plain)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                    .disabled(isEnabled == false)
                    .accessibilityLabel(Text(option.title))
                    .accessibilityValue(Text(option.level == selection
                                              ? String(localized: "capture.settings.context.selected")
                                              : String(localized: "capture.settings.context.not_selected")))
                    .accessibilityHint(Text(option.storageText))
                }
            }
        }
    }
}
