import AppKit
import Combine
import SwiftUI

// MARK: - Realtime capture command center

/// Realtime exists before the first Session as a capture entry. Once a Session
/// is supplied, this page becomes that Session's one transcript Section.
struct NotebookRealtimeTranscriptPage: View {
    let notebookId: String
    /// A non-nil id is a hard presentation boundary, never a timeline focus.
    let sessionId: String?
    @ObservedObject var editor: NotebookCaptureProfileEditorModel
    let onOpenAdvancedSettings: () -> Void
    @StateObject private var history = NotebookCaptureHistoryStore()
    @ObservedObject private var capture = ActiveBilingualTranscriptStore.shared
    @ObservedObject private var subtitleOverlay = SubtitleOverlayCoordinator.shared

    var body: some View {
        VStack(spacing: 0) {
            if showsCaptureSetup {
                HStack(spacing: Spacing.md) {
                    Label(
                        String(localized: "capture.realtime.controls.profile_group"),
                        systemImage: "waveform.and.mic"
                    )
                    .font(.captionMedium)
                    .foregroundColor(.textSecondary)
                    Spacer(minLength: Spacing.md)
                    advancedSettingsButton
                    NotebookCaptureToolbar(
                        notebookId: notebookId,
                        profileEditor: editor
                    )
                    floatingSubtitleButton
                }
                .padding(.horizontal, Spacing.xl)
                .padding(.vertical, Spacing.sm)
                .background(Color.bgSunken.opacity(0.42))

                NotebookRealtimeCaptureConsole(
                    notebookId: notebookId,
                    editor: editor
                )

                Divider().background(Color.borderGhost.opacity(0.3))
            }

            NotebookRealtimeHistoryView(
                notebookId: notebookId,
                focusSessionId: sessionId,
                history: history
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.bgRoot)
        .task(id: "\(notebookId):\(sessionId ?? "new")") {
            await reloadHistory()
        }
        .montereyOnChange(of: capture.sessionId) { _, _ in
            guard capture.notebookId == notebookId else { return }
            Task { await reloadHistory() }
        }
        .montereyOnChange(of: capture.captureState) { _, state in
            guard capture.notebookId == notebookId,
                  state.isActive == false else { return }
            Task { await reloadHistory() }
        }
        .montereyOnChange(of: activeSessionSpeakerIds) { _, speakerIds in
            refreshActiveSessionSpeakers(speakerIds)
        }
    }

    private func reloadHistory() async {
        await history.load(notebookId: notebookId)
        // Read the current IDs after the catalog await. This closes the mount
        // race where an initial speaker refresh could otherwise be cleared by
        // the catalog's notebook-switch/reset prefix or summary filtering.
        refreshActiveSessionSpeakers(activeSessionSpeakerIds)
    }

    private var showsCaptureSetup: Bool {
        guard let sessionId else { return true }
        return capture.notebookId == notebookId
            && capture.sessionId == sessionId
            && capture.isCaptureActive
    }

    private func refreshActiveSessionSpeakers(_ speakerIds: [String]) {
        guard speakerIds.isEmpty == false,
              capture.notebookId == notebookId,
              let activeSessionId = capture.sessionId,
              sessionId == nil || sessionId == activeSessionId else { return }
        history.refreshSessionSpeakers(sessionId: activeSessionId)
    }

    private var activeSessionSpeakerIds: [String] {
        guard capture.notebookId == notebookId else { return [] }
        return Array(Set(capture.utterances.compactMap(\.sessionSpeakerId))).sorted()
    }

    private var floatingSubtitleButton: some View {
        let isAvailable = capture.isCaptureActive && capture.notebookId == notebookId
        let isPresented = subtitleOverlay.isPresented
        let title = isPresented
            ? String(localized: "capture.toolbar.subtitle_window.close")
            : String(localized: "capture.toolbar.subtitle_window.open")

        return Button {
            WindowCommandRouter.shared.requestToggleSubtitleOverlay()
        } label: {
            Image(systemName: isPresented ? "pip.exit" : "pip.enter")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(isPresented ? .brandAccent : .textPrimary)
        .background(
            RoundedRectangle(cornerRadius: Radius.xs)
                .fill(isPresented ? Color.brandAccent.opacity(0.14) : Color.bgElevated.opacity(0.65))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.xs)
                .strokeBorder(
                    isPresented ? Color.brandAccent.opacity(0.5) : Color.borderGhost.opacity(0.25),
                    lineWidth: 0.5
                )
        )
        .disabled(isAvailable == false)
        .opacity(isAvailable ? 1 : 0.45)
        .help(
            isAvailable
                ? String(localized: "capture.toolbar.subtitle_window.hint")
                : String(localized: "capture.toolbar.subtitle_window.unavailable_hint")
        )
        .accessibilityLabel(Text(title))
        .accessibilityHint(Text(
            isAvailable
                ? String(localized: "capture.toolbar.subtitle_window.hint")
                : String(localized: "capture.toolbar.subtitle_window.unavailable_hint")
        ))
        .accessibilityIdentifier(AccessibilityID.floatingSubtitleButton)
    }

    private var advancedSettingsButton: some View {
        Button(action: onOpenAdvancedSettings) {
            Label(
                String(localized: "topic.capture_setup.tab"),
                systemImage: "slider.horizontal.3"
            )
            .font(.captionMedium)
            .foregroundColor(.textSecondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(String(localized: "topic.capture_setup.tab.hint"))
        .accessibilityLabel(Text(String(localized: "topic.capture_setup.tab")))
        .accessibilityHint(Text(String(localized: "capture.settings.tab_hint")))
        .accessibilityIdentifier("capture.realtime.advanced_settings")
    }
}

/// High-frequency capture configuration. Its bindings target the Notebook's
/// persisted next-run profile, never `ActiveBilingualTranscriptStore.profile`,
/// which can be an immutable active or historical run snapshot.
enum NotebookRealtimeConsolePresentation: Equatable {
    case inactiveEditor
    case activeRunSummary
    case drainingSummary
    case activeElsewhereSummary

    static func resolve(
        isCaptureActive: Bool,
        captureState: NotebookCaptureState,
        activeNotebookId: String?,
        notebookId: String
    ) -> Self {
        guard isCaptureActive else { return .inactiveEditor }
        guard activeNotebookId == notebookId else { return .activeElsewhereSummary }
        return captureState == .draining || !captureState.isActive
            ? .drainingSummary
            : .activeRunSummary
    }
}

enum NotebookRealtimeControlLayoutAxis: Equatable {
    case horizontal
    case stacked
}

/// Keeps each native form control mounted once while allowing the row to stack
/// when its measured ideal content no longer fits the available width.
struct NotebookRealtimeControlLayoutPolicy {
    static let minimumInteractiveTarget: CGFloat = 44

    static func resolve(
        availableWidth: CGFloat?,
        requiredHorizontalWidth: CGFloat
    ) -> NotebookRealtimeControlLayoutAxis {
        guard let availableWidth, availableWidth.isFinite else { return .horizontal }
        return availableWidth >= requiredHorizontalWidth ? .horizontal : .stacked
    }
}

@available(macOS 13.0, *)
private struct NotebookAdaptiveSingleMountLayout: Layout {
    enum StackedAlignment: Equatable {
        case leading
        case center
    }

    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat
    let stackedAlignment: StackedAlignment

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let idealSizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let requiredWidth = idealSizes.map(\.width).reduce(0, +)
            + horizontalSpacing * CGFloat(max(0, subviews.count - 1))
        let availableWidth = finiteWidth(proposal.width)
        let axis = NotebookRealtimeControlLayoutPolicy.resolve(
            availableWidth: availableWidth,
            requiredHorizontalWidth: requiredWidth
        )

        switch axis {
        case .horizontal:
            return CGSize(
                width: availableWidth ?? requiredWidth,
                height: idealSizes.map(\.height).max() ?? 0
            )
        case .stacked:
            let width = availableWidth ?? idealSizes.map(\.width).max() ?? 0
            let stackedSizes = subviews.map {
                $0.sizeThatFits(ProposedViewSize(width: width, height: nil))
            }
            return CGSize(
                width: width,
                height: stackedSizes.map(\.height).reduce(0, +)
                    + verticalSpacing * CGFloat(max(0, subviews.count - 1))
            )
        }
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let idealSizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let requiredWidth = idealSizes.map(\.width).reduce(0, +)
            + horizontalSpacing * CGFloat(max(0, subviews.count - 1))
        let axis = NotebookRealtimeControlLayoutPolicy.resolve(
            availableWidth: bounds.width,
            requiredHorizontalWidth: requiredWidth
        )

        switch axis {
        case .horizontal:
            let extra = max(0, bounds.width - requiredWidth)
            let gap = subviews.count > 1
                ? horizontalSpacing + extra / CGFloat(subviews.count - 1)
                : 0
            var x = bounds.minX
            for (index, subview) in subviews.enumerated() {
                let size = idealSizes[index]
                subview.place(
                    at: CGPoint(x: x, y: bounds.midY - size.height / 2),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(size)
                )
                x += size.width + gap
            }
        case .stacked:
            var y = bounds.minY
            for subview in subviews {
                let size = subview.sizeThatFits(
                    ProposedViewSize(width: bounds.width, height: nil)
                )
                let x = stackedAlignment == .center
                    ? bounds.midX - size.width / 2
                    : bounds.minX
                subview.place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(size)
                )
                y += size.height + verticalSpacing
            }
        }
    }

    private func finiteWidth(_ width: CGFloat?) -> CGFloat? {
        guard let width, width.isFinite else { return nil }
        return max(0, width)
    }
}

private func notebookCaptureProviderDisplayName(_ providerId: String) -> String {
    ProviderCredentialAccount(scope: providerId)?.displayName ?? providerId
}

/// Soniox realtime language set. Speaker diarization is independent from this
/// list and applies equally to every language; these codes define the ordered
/// language lanes for one capture.
enum NotebookCaptureSupportedLanguages {
    static let maximumSelectedCount = 3

    /// Surfaced as one-tap suggestions before the user types a search query.
    /// Keep the primary regional languages first, then make the current UI
    /// language available without requiring a search.
    static func suggestedCodes(
        interfaceLanguage: AppLanguage = .currentFromStorage()
    ) -> [String] {
        let interfaceCode = interfaceLanguage == .zhHans
            ? "zh"
            : interfaceLanguage.rawValue
        return ["th", "en", "zh"] + (["th", "en", "zh"].contains(interfaceCode)
            ? []
            : [interfaceCode])
    }

    static let codes = [
        "af", "sq", "ar", "az", "eu", "be", "bn", "bs", "bg", "ca",
        "zh", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "gl",
        "de", "el", "gu", "he", "hi", "hu", "id", "it", "ja", "kn",
        "kk", "ko", "lv", "lt", "mk", "ms", "ml", "mr", "no", "fa",
        "pl", "pt", "pa", "ro", "ru", "sr", "sk", "sl", "es", "sw",
        "sv", "tl", "ta", "te", "th", "tr", "uk", "ur", "vi", "cy",
    ]

    static func options(
        locale: Locale = .current
    ) -> [(code: String, label: String)] {
        codes.map { code in
            let localizedName = locale.localizedString(forLanguageCode: code)
                ?? code.uppercased()
            let nativeName = Locale(identifier: code)
                .localizedString(forLanguageCode: code)
                ?? localizedName
            let names = nativeName.caseInsensitiveCompare(localizedName) == .orderedSame
                ? nativeName
                : "\(nativeName) · \(localizedName)"
            return (code, "\(names) · \(code.uppercased())")
        }
    }
}

private struct NotebookRealtimeCaptureConsole: View {
    let notebookId: String
    @ObservedObject var editor: NotebookCaptureProfileEditorModel
    @ObservedObject private var capture = ActiveBilingualTranscriptStore.shared
    @ObservedObject private var credentialSession = ProviderCredentialSession.shared
    @State private var languageSearch = ""

    private var languages: [(code: String, label: String)] {
        NotebookCaptureSupportedLanguages.options()
    }

    private var draft: NotebookCaptureProfileDTO { editor.draft }

    private var presentation: NotebookRealtimeConsolePresentation {
        NotebookRealtimeConsolePresentation.resolve(
            isCaptureActive: capture.isCaptureActive,
            captureState: capture.captureState,
            activeNotebookId: capture.notebookId,
            notebookId: notebookId
        )
    }

    var body: some View {
        Group {
            switch presentation {
            case .inactiveEditor:
                inactiveProfileEditor
            case .activeRunSummary, .drainingSummary, .activeElsewhereSummary:
                activeRunSummary
            }
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.bgElevated.opacity(0.2))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(String(localized: "capture.realtime.controls.profile_group")))
    }

    /// Keep this row to one thin status line. The transcript itself already
    /// makes the selected languages evident, so repeating them here adds noise.
    private var activeRunSummary: some View {
        let profile = capture.profile
        return HStack(alignment: .center, spacing: Spacing.md) {
            scopeCopy
            if presentation == .activeElsewhereSummary {
                Label(
                    String(localized: "capture.toolbar.active_other_notebook"),
                    systemImage: "lock.fill"
                )
                .font(.captionMedium)
                .foregroundColor(.textSecondary)
            } else {
                summaryChip(
                    activeRemoteStatus(for: profile),
                    systemImage: profile.remoteRealtimeEnabled ? "network" : "lock.fill"
                )
            }
            Spacer(minLength: Spacing.sm)
            if presentation == .drainingSummary {
                HStack(spacing: Spacing.xs) {
                    if capture.stopRecoveryRequired {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .accessibilityHidden(true)
                        Text(String(localized: "capture.toast.stop_failed"))
                    } else if capture.isAudioDrainDelayed {
                        Image(systemName: "externaldrive.badge.timemachine")
                            .accessibilityHidden(true)
                        Text(String(localized: "capture.state.audio_drain_delayed"))
                    } else {
                        ProgressView()
                            .controlSize(.small)
                        Text(String(localized: "capture.state.draining"))
                    }
                }
                .font(.captionMedium)
                .foregroundColor(.textSecondary)
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var inactiveProfileEditor: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            inactiveProfileControls
        }
    }

    private var scopeCopy: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(scopeTitle, systemImage: capture.isCaptureActive ? "lock.fill" : "record.circle")
                .font(.captionMedium)
                .foregroundColor(.textPrimary)
            Text(scopeDetail)
                .font(.system(size: 10))
                .foregroundColor(.textTertiary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var scopeTitle: String {
        if capture.notebookId == notebookId {
            return String(localized: "capture.realtime.controls.current_title")
        }
        return String(localized: "capture.toolbar.active_other_notebook")
    }

    private var scopeDetail: String {
        String(localized: "capture.settings.active_locked")
    }

    private var inactiveProfileControls: some View {
        VStack(alignment: .leading, spacing: 0) {
            languageSelectionSection
            controlDivider
            automaticRealtimeDisclosure
        }
        .padding(.horizontal, Spacing.md)
        .background(Color.bgSunken.opacity(0.34))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.sm)
                .strokeBorder(Color.borderGhost.opacity(0.25), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
        .disabled(editor.canEdit == false)
        .opacity(editor.canEdit ? 1 : 0.58)
    }

    private var languageSelectionSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(alignment: .center, spacing: Spacing.md) {
                Label(
                    String(localized: "capture.settings.languages.question"),
                    systemImage: "character.bubble"
                )
                    .font(.captionMedium)
                    .foregroundColor(.textPrimary)
                Spacer(minLength: Spacing.sm)
                persistenceStatus
            }
            Text(String(localized: "capture.settings.languages.ordered_detail"))
                .font(.system(size: 10))
                .foregroundColor(.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

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
        .padding(.vertical, Spacing.sm)
    }

    private var automaticRealtimeDisclosure: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Label(
                String(localized: "capture.settings.realtime.start_disclosure"),
                systemImage: "network"
            )
                .font(.system(size: 10))
                .foregroundColor(.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            if let credentialAttentionTitle {
                credentialStatusLabel(title: credentialAttentionTitle)
            }
        }
        .padding(.vertical, Spacing.sm)
        .accessibilityElement(children: .contain)
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

    private func selectedLanguageChip(language: String, index: Int) -> some View {
        HStack(spacing: 2) {
            Text(languageLabel(language))
                .font(.captionMedium)
                .foregroundColor(.textPrimary)
                .padding(.leading, Spacing.sm)
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

    private func credentialStatusLabel(title: String) -> some View {
        Label(title, systemImage: credentialStatusIcon)
            .font(.system(size: 10))
            .foregroundColor(credentialStatusColor)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            .accessibilityHint(Text(String(localized: "capture.settings.remote.credential.hint")))
    }

    private var credentialPresentationState: ProviderCredentialPresentationState {
        _ = credentialSession.statusRevision
        let snapshot = credentialSession.snapshot().first(where: { $0.account == .soniox })
            ?? ProviderCredentialSnapshot(
                account: .soniox,
                scope: ProviderCredentialAccount.soniox.scope,
                isSaved: false,
                isActive: false
            )
        return .resolve(snapshot)
    }

    // A healthy credential is the expected default and stays silent here;
    // only states that block or degrade recording surface a status line.
    private var credentialAttentionTitle: String? {
        switch credentialPresentationState {
        case .savedLoadedUnverified, .runtimeOnlyUnverified:
            nil
        case .savedInactive:
            String(localized: "capture.settings.remote.credential.saved_inactive")
        case .missing:
            String(localized: "capture.settings.remote.credential.missing")
        }
    }

    private var credentialStatusIcon: String {
        switch credentialPresentationState {
        case .savedLoadedUnverified, .runtimeOnlyUnverified: "key.fill"
        case .savedInactive: "exclamationmark.triangle.fill"
        case .missing: "key"
        }
    }

    private var credentialStatusColor: Color {
        switch credentialPresentationState {
        case .savedLoadedUnverified, .runtimeOnlyUnverified: .textSecondary
        case .savedInactive: .signalAmber
        case .missing: .textTertiary
        }
    }

    private var controlDivider: some View {
        Divider().background(Color.borderGhost.opacity(0.24))
    }

    private func summaryChip(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.captionMedium)
            .foregroundColor(.textPrimary)
            .padding(.horizontal, Spacing.sm)
            .frame(minHeight: 28)
            .background(Color.bgSunken.opacity(0.42))
            .clipShape(Capsule())
    }

    private func languageLabel(_ code: String) -> String {
        languages.first(where: { $0.code == code })?.label ?? code.uppercased()
    }

    private var remoteHealthTitle: String {
        switch capture.remoteHealth {
        case .off: String(localized: "capture.remote.off")
        case .connecting: String(localized: "capture.remote.connecting")
        case .live: String(localized: "capture.remote.live")
        case .degraded: String(localized: "capture.remote.degraded")
        case .unavailable: String(localized: "capture.remote.unavailable")
        }
    }

    private func activeRemoteStatus(for profile: NotebookCaptureProfileDTO) -> String {
        guard profile.remoteRealtimeEnabled,
              let providerId = capture.realtimeProviderId,
              let modelId = capture.realtimeModelId
        else { return remoteHealthTitle }
        let providerName = notebookCaptureProviderDisplayName(providerId)
        if let lagMs = capture.realtimeLagMs, lagMs >= 1_000 {
            let lagSeconds = Int((lagMs + 999) / 1_000)
            let catchingUp = String(
                format: String(localized: "capture.remote.catching_up"),
                lagSeconds
            )
            return "\(providerName) · \(modelId) · \(catchingUp)"
        }
        return "\(providerName) · \(modelId) · \(remoteHealthTitle)"
    }

    @ViewBuilder
    private var persistenceStatus: some View {
        switch editor.persistenceState {
        case .loading:
            statusLabel(
                String(localized: "capture.settings.autosave.loading"),
                systemImage: "arrow.clockwise",
                color: .textSecondary
            )
        case .saving:
            statusLabel(
                String(localized: "capture.settings.autosave.saving"),
                systemImage: "arrow.triangle.2.circlepath",
                color: .textSecondary
            )
        case .saved:
            statusLabel(
                String(localized: "capture.settings.autosave.saved"),
                systemImage: "checkmark.circle.fill",
                color: .signalGreen
            )
        case .loadFailed(let message):
            failureStatus(
                title: String(localized: "capture.settings.autosave.load_failed"),
                message: message,
                actionTitle: String(localized: "capture.settings.autosave.retry"),
                action: editor.retry
            )
        case .saveFailed(let message):
            failureStatus(
                title: String(localized: "capture.settings.autosave.save_failed"),
                message: message,
                actionTitle: String(localized: "capture.settings.autosave.retry"),
                action: editor.retry
            )
        }
    }

    private func statusLabel(_ title: String, systemImage: String, color: Color) -> some View {
        Label(title, systemImage: systemImage)
            .font(.captionMedium)
            .foregroundColor(color)
            .fixedSize()
            .accessibilityLabel(Text(title))
    }

    private func failureStatus(
        title: String,
        message: String,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            HStack(spacing: Spacing.xs) {
                Label(title, systemImage: "exclamationmark.triangle.fill")
                    .font(.captionMedium)
                    .foregroundColor(.signalAmber)
                    .lineLimit(1)
                Button(actionTitle, action: action)
                    .buttonStyle(.link)
                    .font(.caption)
            }
            Text(message)
                .font(.system(size: 10))
                .foregroundColor(.textTertiary)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(title). \(message)"))
    }

}

/// Presents exactly one Session Section. The Topic may own many durable runs,
/// but sibling summaries and navigation belong to the Topic resources page.
private struct NotebookRealtimeHistoryView: View {
    let notebookId: String
    let focusSessionId: String?
    @ObservedObject var history: NotebookCaptureHistoryStore
    @ObservedObject private var capture = ActiveBilingualTranscriptStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPresentationControlHovered = false
    @State private var selectedSessionID: String?
    @State private var liveFollowTask: Task<Void, Never>?
    @State private var liveFollowGeneration: UInt64 = 0
    @State private var isFollowingLive = true

    var body: some View {
        VStack(spacing: 0) {
            presentationControl
            Divider().background(Color.borderGhost.opacity(0.28))
            historyBody
        }
        .background(Color.bgRoot)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(String(localized: "capture.transcript.realtime_accessibility_label")))
        .onDisappear(perform: cancelLiveFollow)
    }

    private var availableRuns: [NotebookCaptureHistoryRunDTO] {
        NotebookCaptureHistoryPolicy.overlayActiveRun(
            history.runs,
            requestedNotebookId: notebookId,
            activeNotebookId: capture.notebookId,
            activeSessionId: capture.sessionId,
            isCaptureActive: capture.isCaptureActive,
            captureState: capture.captureState,
            remoteHealth: capture.remoteHealth,
            projectionState: capture.projectionState,
            realtimeLoroAppliedRevision: capture.realtimeLoroAppliedRevision,
            profile: capture.profile,
            utterances: capture.utterances
        )
    }

    private var presentedRun: NotebookCaptureHistoryRunDTO? {
        NotebookRealtimeSectionPolicy.targetRun(
            runs: availableRuns,
            requestedSessionID: focusSessionId,
            activeSessionID: activeSessionID
        )
    }

    private var activeSessionID: String? {
        guard capture.notebookId == notebookId, capture.isCaptureActive else { return nil }
        return capture.sessionId
    }

    private var presentationMode: NotebookTranscriptPresentationMode {
        history.presentationMode(for: notebookId)
    }

    private var presentationBinding: Binding<NotebookTranscriptPresentationMode> {
        Binding(
            get: { presentationMode },
            set: { history.setPresentationMode($0, for: notebookId) }
        )
    }

    private var presentationControl: some View {
        HStack {
            Menu {
                Button {
                    presentationBinding.wrappedValue = .sourceTimeline
                } label: {
                    if presentationMode == .sourceTimeline {
                        Label(
                            String(localized: "capture.transcript.presentation.timeline"),
                            systemImage: "checkmark"
                        )
                    } else {
                        Text(String(localized: "capture.transcript.presentation.timeline"))
                    }
                }
                Button {
                    presentationBinding.wrappedValue = .bilingualColumns
                } label: {
                    if presentationMode == .bilingualColumns {
                        Label(
                            String(localized: "capture.transcript.presentation.language_columns"),
                            systemImage: "checkmark"
                        )
                    } else {
                        Text(String(localized: "capture.transcript.presentation.language_columns"))
                    }
                }
            } label: {
                HStack(spacing: Spacing.xs) {
                    Text(presentationMode == .bilingualColumns
                         ? String(localized: "capture.transcript.presentation.language_columns")
                         : String(localized: "capture.transcript.presentation.timeline"))
                        .font(.captionMedium)
                        .foregroundColor(.textPrimary)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.textTertiary)
                        .opacity(isPresentationControlHovered ? 1 : 0)
                }
                .padding(.horizontal, Spacing.sm)
                .frame(minHeight: 32)
                .background(
                    Color.bgElevated.opacity(isPresentationControlHovered ? 0.42 : 0)
                )
                .clipShape(RoundedRectangle(cornerRadius: Radius.xs))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .onHover { isPresentationControlHovered = $0 }
            .accessibilityLabel(Text(String(localized: "settings.shortcuts.cycle_display")))
            .accessibilityValue(Text(
                presentationMode == .bilingualColumns
                    ? String(localized: "capture.transcript.presentation.language_columns")
                    : String(localized: "capture.transcript.presentation.timeline")
            ))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.xs)
    }

    @ViewBuilder
    private var historyBody: some View {
        if history.isLoading, presentedRun == nil {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel(Text(String(localized: "capture.settings.autosave.loading")))
        } else if let lastError = history.lastError {
            EmptyState(
                icon: "exclamationmark.triangle.fill",
                title: String(localized: "capture.route.unavailable"),
                description: lastError,
                action: (
                    label: String(localized: "capture.settings.autosave.retry"),
                    handler: { Task { await reloadHistory() } }
                )
            )
        } else if presentedRun == nil {
            EmptyState(
                illustration: { Arcanum003WaveformRuler() },
                title: String(localized: "editor.transcript.realtime.empty_title"),
                description: String(localized: "editor.transcript.realtime.empty_desc")
            )
        } else {
            ScrollViewReader { proxy in
                Group {
                    if #available(macOS 15.0, *) {
                        historyScroll(using: proxy)
                            .onScrollGeometryChange(
                                for: NotebookRealtimeScrollMetrics.self
                            ) { geometry in
                                let visibleBottom = geometry.contentOffset.y
                                    + geometry.containerSize.height
                                let contentBottom = geometry.contentSize.height
                                    + geometry.contentInsets.bottom
                                return NotebookRealtimeScrollMetrics(
                                    offsetY: Double(geometry.contentOffset.y),
                                    distanceFromBottom: Double(max(
                                        0,
                                        contentBottom - visibleBottom
                                    ))
                                )
                            } action: { previous, current in
                                reconcileLiveFollowing(previous: previous, current: current)
                            }
                    } else {
                        // Monterey has no public scroll-geometry callback.
                        // Keep following the live edge instead of guessing at
                        // user intent from private AppKit implementation state.
                        historyScroll(using: proxy)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if selectedSessionID == activeSessionID, isFollowingLive == false {
                        Button {
                            resumeLiveFollow(using: proxy)
                        } label: {
                            Label(
                                String(localized: "capture.transcript.back_to_live"),
                                systemImage: "arrow.down.to.line"
                            )
                            .font(.captionMedium)
                            .foregroundColor(.bgSunken)
                            .padding(.horizontal, Spacing.md)
                            .frame(minHeight: 30)
                            .background(Color.textPrimary)
                            .clipShape(Capsule())
                            .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
                        }
                        .buttonStyle(.plain)
                        .padding(Spacing.lg)
                    }
                }
                .onAppear {
                    reconcileSelection(using: proxy, animated: false)
                }
                .montereyOnChange(of: focusSessionId) { _, _ in
                    reconcileSelection(using: proxy, animated: false)
                }
                .montereyOnChange(of: availableRuns.map(\.sessionId)) { _, _ in
                    reconcileSelection(using: proxy, animated: false)
                }
                .montereyOnChange(of: activeSessionID) { _, _ in
                    reconcileSelection(using: proxy, animated: false)
                }
            }
        }
    }

    private func historyScroll(using proxy: ScrollViewProxy) -> some View {
        ScrollView {
            if let run = presentedRun {
                runView(run, using: proxy)
                    .id(runAnchor(run.sessionId))
                    .padding(.horizontal, Spacing.xl)
                    .padding(.vertical, Spacing.lg)
            }
        }
    }

    private func reloadHistory() async {
        await history.load(notebookId: notebookId)
        guard let sessionId = activeSessionID,
              capture.utterances.contains(where: { $0.sessionSpeakerId != nil }) else { return }
        history.refreshSessionSpeakers(sessionId: sessionId)
    }

    @ViewBuilder
    private func runView(
        _ run: NotebookCaptureHistoryRunDTO,
        using proxy: ScrollViewProxy
    ) -> some View {
        if activeSessionID == run.sessionId
                    || history.transcriptLoadState(sessionId: run.sessionId) == .loaded {
            if run.sessionId == activeSessionID {
                NotebookRealtimeActiveRunView(
                    run: run,
                    presentationMode: presentationMode,
                    // Read here rather than inside the active-run boundary:
                    // this view already observes the capture store, and that
                    // boundary deliberately observes only the preview frame.
                    isLaneEditingEnabled: capture.isEditable,
                    history: history,
                    capture: capture,
                    liveTailAnchorID: liveTailAnchor(run.sessionId),
                    onLiveAutoscrollSignal: {
                        scheduleLiveFollow(using: proxy)
                    }
                )
            } else {
                VStack(spacing: 0) {
                    NotebookRealtimeUtteranceView(
                        run: run,
                        presentedUtterances: run.utterances,
                        liveTranslationCues: [],
                        presentationMode: presentationMode,
                        isFocused: true,
                        isLaneEditingEnabled: true,
                        replaceLane: { utteranceId, language, text in
                            try await history.replaceLane(
                                utteranceId: utteranceId,
                                language: language,
                                text: text
                            )
                        },
                        history: history
                    )
                }
            }
        } else {
            NotebookRealtimeTranscriptLoadView(
                run: run,
                state: history.transcriptLoadState(sessionId: run.sessionId),
                retry: {
                    Task { await history.loadTranscript(sessionId: run.sessionId) }
                }
            )
            .task(id: run.sessionId) {
                await history.loadTranscript(sessionId: run.sessionId)
            }
        }
    }

    private func runAnchor(_ sessionId: String) -> String {
        "notebook-capture-run:\(sessionId)"
    }

    private func liveTailAnchor(_ sessionId: String) -> String {
        "notebook-capture-live-tail:\(sessionId)"
    }

    private func reconcileSelection(using proxy: ScrollViewProxy, animated: Bool) {
        guard let run = presentedRun else {
            selectedSessionID = nil
            history.retainOnlyTranscript(sessionId: nil)
            return
        }
        let sessionID = run.sessionId
        if selectedSessionID == sessionID {
            history.retainOnlyTranscript(
                sessionId: sessionID == activeSessionID ? nil : sessionID
            )
        } else {
            selectRun(sessionID, using: proxy, animated: animated)
        }
    }

    private func selectRun(
        _ sessionID: String,
        using proxy: ScrollViewProxy,
        animated: Bool
    ) {
        guard presentedRun?.sessionId == sessionID else { return }
        cancelLiveFollow()
        let isLive = sessionID == activeSessionID
        selectedSessionID = sessionID
        isFollowingLive = isLive
        history.retainOnlyTranscript(sessionId: isLive ? nil : sessionID)
        Task { @MainActor in
            await Task.yield()
            let action = {
                proxy.scrollTo(
                    isLive ? liveTailAnchor(sessionID) : runAnchor(sessionID),
                    anchor: isLive ? .bottom : .top
                )
            }
            if animated, reduceMotion == false {
                withAnimation(.easeOut(duration: 0.22), action)
            } else {
                action()
            }
        }
    }

    private func reconcileLiveFollowing(
        previous: NotebookRealtimeScrollMetrics,
        current: NotebookRealtimeScrollMetrics
    ) {
        guard selectedSessionID == activeSessionID else { return }
        let next = NotebookRealtimeFollowPolicy.reconciledFollowing(
            wasFollowing: isFollowingLive,
            previous: previous,
            current: current
        )
        if isFollowingLive, next == false {
            cancelLiveFollow()
        }
        isFollowingLive = next
    }

    private func resumeLiveFollow(using proxy: ScrollViewProxy) {
        guard let sessionID = activeSessionID,
              selectedSessionID == sessionID else { return }
        cancelLiveFollow()
        isFollowingLive = true
        let action = {
            proxy.scrollTo(liveTailAnchor(sessionID), anchor: .bottom)
        }
        if reduceMotion {
            action()
        } else {
            withAnimation(.easeOut(duration: 0.22), action)
        }
    }

    /// A provider may publish ten or more revisions each second. Scroll at most
    /// four times per second and never animate in-place growth; animating every
    /// partial competes with the text layout that just changed the row height.
    private func scheduleLiveFollow(using proxy: ScrollViewProxy) {
        guard liveFollowTask == nil,
              isFollowingLive,
              let sessionID = activeSessionID,
              selectedSessionID == sessionID else { return }
        liveFollowGeneration &+= 1
        let generation = liveFollowGeneration
        liveFollowTask = Task { @MainActor in
            try? await MontereyTaskSleep.milliseconds(250)
            guard Task.isCancelled == false,
                  generation == liveFollowGeneration,
                  isFollowingLive,
                  selectedSessionID == sessionID,
                  activeSessionID == sessionID else {
                if generation == liveFollowGeneration {
                    liveFollowTask = nil
                }
                return
            }
            proxy.scrollTo(liveTailAnchor(sessionID), anchor: .bottom)
            liveFollowTask = nil
        }
    }

    private func cancelLiveFollow() {
        liveFollowGeneration &+= 1
        liveFollowTask?.cancel()
        liveFollowTask = nil
    }
}

/// Owns the provider-rate observation for the one mounted live run. A
/// speculative preview frame updates live text and follow-at-edge behavior
/// without rebuilding the durable Session Section.
private struct NotebookRealtimeActiveRunView: View {
    let run: NotebookCaptureHistoryRunDTO
    let presentationMode: NotebookTranscriptPresentationMode
    let isLaneEditingEnabled: Bool
    let history: NotebookCaptureHistoryStore
    private let capture: ActiveBilingualTranscriptStore
    private let liveTailAnchorID: String
    private let onLiveAutoscrollSignal: () -> Void
    @ObservedObject private var livePresentation: NotebookCaptureLivePresentationStore

    init(
        run: NotebookCaptureHistoryRunDTO,
        presentationMode: NotebookTranscriptPresentationMode,
        isLaneEditingEnabled: Bool,
        history: NotebookCaptureHistoryStore,
        capture: ActiveBilingualTranscriptStore,
        liveTailAnchorID: String,
        onLiveAutoscrollSignal: @escaping () -> Void
    ) {
        self.run = run
        self.presentationMode = presentationMode
        self.isLaneEditingEnabled = isLaneEditingEnabled
        self.history = history
        self.capture = capture
        self.liveTailAnchorID = liveTailAnchorID
        self.onLiveAutoscrollSignal = onLiveAutoscrollSignal
        _livePresentation = ObservedObject(wrappedValue: capture.livePresentation)
    }

    var body: some View {
        let presentedUtterances = NotebookCaptureLivePresentation.utterances(
            durable: run.utterances,
            preview: livePresentation.utterances,
            sessionId: run.sessionId
        )
        VStack(spacing: 0) {
            NotebookRealtimeUtteranceView(
                run: run,
                presentedUtterances: presentedUtterances,
                liveTranslationCues: capture.presentedTranslationCueSnapshot,
                presentationMode: presentationMode,
                isFocused: true,
                isLaneEditingEnabled: isLaneEditingEnabled,
                // The live run's rows are the capture store's own utterances,
                // so its store is the only one that can accept an edit to them.
                replaceLane: { utteranceId, language, text in
                    try await capture.replaceLane(
                        utteranceId: utteranceId,
                        language: language,
                        text: text
                    )
                },
                history: history
            )
            Color.clear
                .frame(height: 1)
                .id(liveTailAnchorID)
        }
        .montereyOnChange(of: liveAutoscrollSignal) { _, signal in
            guard signal != nil else { return }
            onLiveAutoscrollSignal()
        }
        .task(id: run.sessionId) {
            await history.refreshTranscriptGaps(sessionId: run.sessionId)
        }
        // A reconnect that skipped audio writes its gap record when the
        // replacement connection comes up, which is also a health transition.
        .montereyOnChange(of: capture.remoteHealth) { _, _ in
            let sessionId = run.sessionId
            Task { @MainActor in
                await history.refreshTranscriptGaps(sessionId: sessionId)
            }
        }
    }

    private var liveAutoscrollSignal: NotebookRealtimeAutoscrollSignal? {
        NotebookRealtimeAutoscrollPolicy.signal(
            in: NotebookCaptureLivePresentation.utteranceTail(
                durable: run.utterances,
                preview: livePresentation.utterances,
                sessionId: run.sessionId,
                limit: 1
            ),
            cues: capture.presentedTranslationCueSnapshot
        )
    }
}

private struct NotebookRealtimeTranscriptLoadView: View {
    let run: NotebookCaptureHistoryRunDTO
    let state: NotebookCaptureTranscriptLoadState
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            switch state {
            case .failed(let message):
                Label(
                    String(localized: "capture.transcript.load_recording_failed"),
                    systemImage: "exclamationmark.triangle.fill"
                )
                    .font(.captionMedium)
                    .foregroundColor(.signalAmber)
                Text(message)
                    .font(.caption)
                    .foregroundColor(.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(String(localized: "capture.settings.autosave.retry"), action: retry)
                    .buttonStyle(.borderless)
            case .unloaded, .loading, .loaded:
                HStack(spacing: Spacing.sm) {
                    ProgressView().controlSize(.small)
                    Text(String(localized: "capture.transcript.loading_recording"))
                        .font(.caption)
                        .foregroundColor(.textSecondary)
                }
            }
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
        .background(Color.bgSunken.opacity(0.2))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.sm)
                .strokeBorder(Color.borderGhost.opacity(0.24), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
        .accessibilityLabel(Text(
            "\(NotebookRealtimeRunPresentation.createdAtText(for: run)), "
                + String(localized: "capture.transcript.loading_recording")
        ))
    }
}
