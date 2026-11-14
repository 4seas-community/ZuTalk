import SwiftUI

/// The languages a recording captures: chosen, ordered, and — with three —
/// marked as spoken, or as one everything is also translated into.
///
/// There is one way of choosing them in the whole app: a pill per language
/// (`CaptureLanguagePills`) — × takes one away, ＋ opens the search, the icon
/// in front says spoken or only translated into once there are three, and
/// the order is changed from a pill's context menu.
///   - Home's start card lays the pills out in its own strip;
///   - `CaptureLanguageEditor` is that same strip for everywhere else: a
///     topic's options, and the console a topic's recordings start from.
struct CaptureLanguageEditor: View {
    @ObservedObject var editor: NotebookCaptureProfileEditorModel

    var body: some View {
        PillStrip {
            CaptureLanguagePills(editor: editor)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(String(localized: "home.record.languages.picker")))
        .accessibilityHint(Text(Self.rolesSummary(
            selected: editor.draft.selectedLanguages,
            translatedOnly: editor.draft.subtitleOnlyLanguages
        ) ?? ""))
    }

    /// With three languages, which are spoken and which everything is also
    /// translated into, in one sentence: what used to be printed under the
    /// chips, now said to whoever asks (a tooltip, VoiceOver). Nil with one
    /// or two, where there is nothing to tell apart. How many connections
    /// that opens is the app's business, not something to weigh before
    /// recording (docs/product/interface-layers.md keeps that number in
    /// Settings).
    static func rolesSummary(selected: [String], translatedOnly: [String]) -> String? {
        guard selected.count > 2 else { return nil }
        let translated = selected.filter(translatedOnly.contains)
        let spoken = selected.filter { translated.contains($0) == false }
        guard translated.isEmpty == false else {
            return String(localized: "capture.languages.roles.all_spoken")
        }
        return RecordingPlanSentence.spacedBetweenScripts(String(
            format: String(localized: "capture.languages.roles.some_translated_format"),
            ListFormatter.localizedString(byJoining: spoken.map(RecordingPresentation.languageName)),
            ListFormatter.localizedString(byJoining: translated.map(RecordingPresentation.languageName))
        ))
    }
}

// MARK: - Finding a language to add

/// The search field, what it finds, and — before anything is typed — the
/// languages people add most: what the popover behind a strip's ＋ shows.
struct CaptureLanguageSearch: View {
    @ObservedObject var editor: NotebookCaptureProfileEditorModel
    /// Puts the keyboard in the field as soon as it shows: in a popover the
    /// person opened it to type.
    var focusesOnAppear = false
    /// Called once a language has been added.
    var onAdd: () -> Void = {}

    @State private var languageSearch = ""
    @FocusState private var isSearchFocused: Bool

    private var languages: [(code: String, label: String)] {
        NotebookCaptureSupportedLanguages.options()
    }

    private var draft: NotebookCaptureProfileDTO { editor.draft }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.textTertiary)
                    .accessibilityHidden(true)
                TextField(
                    String(localized: "capture.settings.languages.search"),
                    text: $languageSearch
                )
                .textFieldStyle(.plain)
                .focused($isSearchFocused)
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
        // Where this field shares a window with a default button (Home's
        // Start), Return while searching for a language must not press it.
        .preference(key: TextEntryFocusKey.self, value: isSearchFocused)
        .onAppear {
            guard focusesOnAppear else { return }
            // The popover is still coming up; focus takes once it has.
            DispatchQueue.main.async { isSearchFocused = true }
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

    private func addLanguage(_ language: String) {
        guard draft.selectedLanguages.count
                < NotebookCaptureSupportedLanguages.maximumSelectedCount,
              draft.selectedLanguages.contains(language) == false
        else { return }
        editor.scheduleUpdate(.addLanguage(language))
        languageSearch = ""
        onAdd()
    }
}

// MARK: - Pills

/// What one language pill offers. Plain values, so the rules — when a
/// language can be removed, when its role can change — are checked on their
/// own.
nonisolated struct CaptureLanguagePillState: Equatable, Sendable {
    nonisolated enum Role: Equatable, Sendable {
        /// Someone will speak it.
        case spoken
        /// Nobody speaks it; everything is also translated into it.
        case translatedInto
    }

    let code: String
    /// Nil with one or two languages: two translate into each other, and
    /// there is nothing to tell apart.
    let role: Role?
    /// Someone has to be speaking: the last spoken language stays spoken.
    let canToggleRole: Bool
    /// A recording has at least one language.
    let canRemove: Bool
    let canMoveEarlier: Bool
    let canMoveLater: Bool

    static func pills(selected: [String], translatedOnly: [String]) -> [CaptureLanguagePillState] {
        let hasRoles = selected.count > 2
        let translated = hasRoles ? selected.filter(translatedOnly.contains) : []
        let spokenCount = selected.count - translated.count
        return selected.enumerated().map { index, code in
            let role: Role? = hasRoles
                ? (translated.contains(code) ? .translatedInto : .spoken)
                : nil
            return CaptureLanguagePillState(
                code: code,
                role: role,
                canToggleRole: role == .translatedInto || (role == .spoken && spokenCount > 1),
                canRemove: selected.count > 1,
                canMoveEarlier: index > 0,
                canMoveLater: index < selected.count - 1
            )
        }
    }

    /// The ＋ is offered until the most a recording can carry is chosen.
    static func canAdd(selectedCount: Int, maximum: Int) -> Bool {
        selectedCount < maximum
    }

    /// The role, said in a sentence for a tooltip: which it is, and how to
    /// change it.
    static func roleDescription(_ role: Role, language: String) -> String {
        RecordingPlanSentence.spacedBetweenScripts(String(
            format: String(
                localized: role == .translatedInto
                    ? "capture.languages.role.translated_format"
                    : "capture.languages.role.spoken_format"
            ),
            RecordingPresentation.languageName(language)
        ))
    }
}

/// The languages as pills: each shows its own name, drops out with its ×,
/// and — once there are three — carries the icon that says whether it is
/// spoken or only translated into. A ＋ opens the search. Reordering is in
/// each pill's context menu.
struct CaptureLanguagePills: View {
    @ObservedObject var editor: NotebookCaptureProfileEditorModel
    @State private var showsSearch = false

    private var draft: NotebookCaptureProfileDTO { editor.draft }

    var body: some View {
        let pills = CaptureLanguagePillState.pills(
            selected: draft.selectedLanguages,
            translatedOnly: draft.subtitleOnlyLanguages
        )
        HStack(spacing: PillMetrics.spacing) {
            ForEach(pills, id: \.code) { pill in
                languagePill(pill)
            }
            if CaptureLanguagePillState.canAdd(
                selectedCount: pills.count,
                maximum: NotebookCaptureSupportedLanguages.maximumSelectedCount
            ) {
                addPill
            }
        }
    }

    private func languagePill(_ pill: CaptureLanguagePillState) -> some View {
        ValuePill(
            RecordingPresentation.languageName(pill.code),
            isMuted: pill.role == .translatedInto,
            leading: pill.role.map { role in
                ValuePill.Leading(
                    systemImage: role == .translatedInto ? "captions.bubble" : "waveform",
                    tint: role == .translatedInto ? .textTertiary : .brandAccent,
                    help: CaptureLanguagePillState.roleDescription(role, language: pill.code),
                    isEnabled: pill.canToggleRole
                ) {
                    editor.scheduleUpdate(.setSubtitleOnly(pill.code, role == .spoken))
                }
            },
            removeLabel: String(localized: "capture.settings.languages.remove"),
            onRemove: pill.canRemove
                ? { editor.scheduleUpdate(.removeLanguage(pill.code)) }
                : nil
        )
        .contextMenu {
            Button(String(localized: "home.card.move_earlier")) {
                editor.scheduleUpdate(.moveLanguage(pill.code, offset: -1))
            }
            .disabled(pill.canMoveEarlier == false)
            Button(String(localized: "home.card.move_later")) {
                editor.scheduleUpdate(.moveLanguage(pill.code, offset: 1))
            }
            .disabled(pill.canMoveLater == false)
        }
    }

    private var addPill: some View {
        ActionPill(
            nil,
            systemImage: "plus",
            help: String(localized: "home.options.languages_detail"),
            accessibilityLabel: String(localized: "capture.settings.languages.search")
        ) {
            showsSearch = true
        }
        .accessibilityIdentifier("record.page.languages.add")
        .popover(isPresented: $showsSearch, arrowEdge: .bottom) {
            CaptureLanguageSearch(editor: editor, focusesOnAppear: true) {
                showsSearch = false
            }
            .padding(Spacing.md)
            .frame(width: 340)
        }
    }
}
