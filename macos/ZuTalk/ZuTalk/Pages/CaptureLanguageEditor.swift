import SwiftUI

/// The languages a recording captures: chosen, ordered, and — with three —
/// marked as spoken in the room or only read as subtitles.
///
/// Home's quick-record popover and a topic's recording settings each had
/// their own copy of this, and only one of them could mark a language as
/// subtitles only.
struct CaptureLanguageEditor: View {
    @ObservedObject var editor: NotebookCaptureProfileEditorModel
    @State private var languageSearch = ""

    private var languages: [(code: String, label: String)] {
        NotebookCaptureSupportedLanguages.options()
    }

    private var draft: NotebookCaptureProfileDTO { editor.draft }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            ScrollView(.horizontal) {
                HStack(spacing: Spacing.sm) {
                    ForEach(Array(draft.selectedLanguages.enumerated()), id: \.element) {
                        index,
                        language in
                        selectedLanguageChip(language: language, index: index)
                    }
                }
            }
            .montereyScrollIndicators(true)

            if draft.selectedLanguages.count > 2 {
                languageRolesSummary
            }

            HStack(spacing: Spacing.sm) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.textTertiary)
                    .accessibilityHidden(true)
                TextField(
                    String(localized: "capture.settings.languages.search"),
                    text: $languageSearch
                )
                .textFieldStyle(.plain)
                .accessibilityLabel(Text(String(localized: "capture.settings.languages.search")))
            }
            .padding(.horizontal, Spacing.sm)
            .frame(minHeight: NotebookRealtimeControlLayoutPolicy.minimumInteractiveTarget)
            .background(Color.bgSunken.opacity(0.5))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.xs)
                    .strokeBorder(Color.borderGhost.opacity(0.3), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: Radius.xs))

            if languageSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                suggestedLanguageResults
            } else {
                languageSearchResults
            }
        }
    }

    private var languageSearchResults: some View {
        let query = languageSearch
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let selected = Set(draft.selectedLanguages)
        let matches = languages.filter { language in
            selected.contains(language.code) == false
                && (language.code.localizedCaseInsensitiveContains(query)
                    || language.label.localizedCaseInsensitiveContains(query))
        }

        return Group {
            if draft.selectedLanguages.count >= NotebookCaptureSupportedLanguages.maximumSelectedCount {
                Text(String(localized: "capture.settings.languages.maximum_reached"))
                    .font(.caption)
                    .foregroundColor(.textTertiary)
                    .padding(.vertical, Spacing.xs)
            } else if matches.isEmpty {
                Text(String(localized: "capture.settings.languages.no_results"))
                    .font(.caption)
                    .foregroundColor(.textTertiary)
                    .padding(.vertical, Spacing.xs)
            } else {
                addLanguageChipRow(matches)
            }
        }
    }

    @ViewBuilder
    private var suggestedLanguageResults: some View {
        let selected = Set(draft.selectedLanguages)
        let suggestions = NotebookCaptureSupportedLanguages.suggestedCodes()
            .filter { selected.contains($0) == false }
            .compactMap { code in languages.first { $0.code == code } }

        if draft.selectedLanguages.count < NotebookCaptureSupportedLanguages.maximumSelectedCount,
           suggestions.isEmpty == false {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(String(localized: "capture.settings.languages.suggested"))
                    .font(.system(size: 10))
                    .foregroundColor(.textTertiary)
                addLanguageChipRow(suggestions)
            }
        }
    }

    private func addLanguageChipRow(
        _ options: [(code: String, label: String)]
    ) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: Spacing.xs) {
                ForEach(options, id: \.code) { language in
                    Button {
                        addLanguage(language.code)
                    } label: {
                        Label(language.label, systemImage: "plus")
                            .font(.caption)
                            .padding(.horizontal, Spacing.sm)
                            .frame(minHeight: 32)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.textPrimary)
                    .background(Color.bgElevated.opacity(0.42))
                    .clipShape(Capsule())
                    .accessibilityLabel(Text(String(
                        format: String(localized: "capture.settings.languages.add_format"),
                        language.label
                    )))
                }
            }
        }
        .montereyScrollIndicators(true)
    }

    /// With three languages, what the room speaks decides how many
    /// connections a recording opens. Says which languages are listened for,
    /// which are only read, and what that costs.
    private var languageRolesSummary: some View {
        let subtitleOnly = draft.subtitleOnlyLanguages
        let spoken = draft.selectedLanguages.filter { subtitleOnly.contains($0) == false }
        let connections = NotebookCaptureToolbar.remoteLaneCount(
            selectedLanguages: draft.selectedLanguages,
            subtitleOnlyLanguages: subtitleOnly
        )
        let text = subtitleOnly.isEmpty
            ? String(
                format: String(localized: "capture.settings.languages.roles.all_spoken"),
                connections
            )
            : String(
                format: String(localized: "capture.settings.languages.roles.some_subtitle_only"),
                ListFormatter.localizedString(byJoining: spoken.map(languageLabel)),
                ListFormatter.localizedString(byJoining: subtitleOnly.map(languageLabel)),
                connections
            )
        return Label(text, systemImage: "captions.bubble")
            .font(.system(size: 10))
            .foregroundColor(.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
    }

    private func selectedLanguageChip(language: String, index: Int) -> some View {
        let subtitleOnly = draft.subtitleOnlyLanguages.contains(language)
        let spokenCount = draft.selectedLanguages.count - draft.subtitleOnlyLanguages.count
        return HStack(spacing: 2) {
            if draft.selectedLanguages.count > 2 {
                languageChipButton(
                    systemImage: subtitleOnly ? "captions.bubble" : "waveform",
                    label: String(
                        format: String(
                            localized: subtitleOnly
                                ? "capture.settings.languages.role.subtitle_only"
                                : "capture.settings.languages.role.spoken"
                        ),
                        languageLabel(language)
                    ),
                    disabled: subtitleOnly == false && spokenCount <= 1,
                    action: {
                        editor.scheduleUpdate(.setSubtitleOnly(language, subtitleOnly == false))
                    }
                )
                .help(String(
                    format: String(
                        localized: subtitleOnly
                            ? "capture.settings.languages.role.subtitle_only"
                            : "capture.settings.languages.role.spoken"
                    ),
                    languageLabel(language)
                ))
            }
            Text(languageLabel(language))
                .font(.captionMedium)
                .foregroundColor(subtitleOnly ? .textSecondary : .textPrimary)
                .padding(.leading, draft.selectedLanguages.count > 2 ? 0 : Spacing.sm)
                .padding(.trailing, Spacing.xs)

            languageChipButton(
                systemImage: "chevron.left",
                label: String(localized: "capture.settings.languages.move_earlier"),
                disabled: index == 0,
                action: { moveLanguage(at: index, offset: -1) }
            )
            languageChipButton(
                systemImage: "chevron.right",
                label: String(localized: "capture.settings.languages.move_later"),
                disabled: index == draft.selectedLanguages.count - 1,
                action: { moveLanguage(at: index, offset: 1) }
            )
            languageChipButton(
                systemImage: "xmark",
                label: String(localized: "capture.settings.languages.remove"),
                disabled: draft.selectedLanguages.count <= 1,
                action: { removeLanguage(at: index) }
            )
        }
        .frame(minHeight: 36)
        .background(Color.bgElevated.opacity(0.42))
        .overlay(
            Capsule()
                .strokeBorder(Color.borderGhost.opacity(0.3), lineWidth: 0.5)
        )
        .clipShape(Capsule())
        .accessibilityElement(children: .contain)
    }

    private func languageChipButton(
        systemImage: String,
        label: String,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .semibold))
                .frame(width: 28, height: 32)
        }
        .buttonStyle(.plain)
        .foregroundColor(.textSecondary)
        .contentShape(Rectangle())
        .disabled(disabled)
        .accessibilityLabel(Text(label))
    }

    private func addLanguage(_ language: String) {
        guard draft.selectedLanguages.count
                < NotebookCaptureSupportedLanguages.maximumSelectedCount,
              draft.selectedLanguages.contains(language) == false
        else { return }
        editor.scheduleUpdate(.addLanguage(language))
        languageSearch = ""
    }

    private func removeLanguage(at index: Int) {
        guard draft.selectedLanguages.count > 1,
              draft.selectedLanguages.indices.contains(index)
        else { return }
        editor.scheduleUpdate(.removeLanguage(draft.selectedLanguages[index]))
    }

    private func moveLanguage(at index: Int, offset: Int) {
        let destination = index + offset
        guard draft.selectedLanguages.indices.contains(index),
              draft.selectedLanguages.indices.contains(destination)
        else { return }
        editor.scheduleUpdate(.moveLanguage(draft.selectedLanguages[index], offset: offset))
    }

    /// A chosen language by its own name; the search results keep the full
    /// "native · localized · code" label for finding one.
    private func languageLabel(_ code: String) -> String {
        RecordingPresentation.languageName(code)
    }
}
