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
    /// The page stays mounted under notes and settings so it keeps its
    /// history and tasks, but while a recording runs a hidden page has no
    /// reason to lay out a transcript nobody sees on every publish.
    var isVisible = true
    @StateObject private var history = NotebookCaptureHistoryStore()
    @ObservedObject private var capture = ActiveBilingualTranscriptStore.shared
    @ObservedObject private var marks = SessionMarkStore.shared

    var body: some View {
        pageContent
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
            // Stopping is when the transcript settles for good, so it is when
            // every excerpt is worth rebuilding once.
            SessionMarkStore.shared.refreshExcerpts()
        }
        .montereyOnChange(of: markSessionId) { _, session in
            SessionMarkStore.shared.load(sessionId: session)
        }
        .task(id: markSessionId ?? "none") {
            SessionMarkStore.shared.load(sessionId: markSessionId)
        }
        .task(id: isMarkingLive) {
            // Cheap by construction: this only reads when a mark dropped in
            // the last few seconds could still be waiting on a partial.
            //
            // A task rather than `.onReceive(Timer.publish(...))` in the body:
            // that built a new timer on every evaluation, and during a
            // recording the page re-evaluates more often than every two
            // seconds, so the tick kept being reset instead of firing.
            guard isMarkingLive else { return }
            while Task.isCancelled == false {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard Task.isCancelled == false else { break }
                SessionMarkStore.shared.refreshSettlingExcerpts()
            }
        }
        .montereyOnChange(of: activeSessionSpeakerIds) { _, speakerIds in
            refreshActiveSessionSpeakers(speakerIds)
        }
    }

    @ViewBuilder
    private var pageContent: some View {
        if isVisible || capture.isCaptureActive == false {
            visiblePage
        } else {
            Color.clear
        }
    }

    private var visiblePage: some View {
        VStack(spacing: 0) {
            if showsCaptureSetup, consolePresentation.showsConsole(
                stopNeedsAttention: capture.stopRecoveryRequired || capture.isAudioDrainDelayed
            ) {
                if consolePresentation == .inactiveEditor {
                    // Captions for the next recording, and Record. The
                    // settings tab is one click away in the tab bar; a button
                    // here used to open it a second way.
                    HStack(spacing: Spacing.md) {
                        Spacer(minLength: Spacing.md)
                        NotebookCaptureToolbar(
                            notebookId: notebookId,
                            profileEditor: editor
                        )
                    }
                    .padding(.horizontal, Spacing.xl)
                    .padding(.vertical, Spacing.sm)
                    .background(Color.bgSunken.opacity(0.42))
                }

                NotebookRealtimeCaptureConsole(
                    notebookId: notebookId,
                    editor: editor
                )

                Divider().background(Color.borderGhost.opacity(0.3))
            }

            transcriptAndRail
        }
    }

    /// While this page's recording is in progress nothing sits above the
    /// transcript: how the recording and its text are doing is the recording
    /// bar's one sentence, and the caption window, the reading layout and
    /// Copy are under its ⋯ (docs/product/interface-layers.md).
    private var consolePresentation: NotebookRealtimeConsolePresentation {
        NotebookRealtimeConsolePresentation.resolve(
            isCaptureActive: capture.isCaptureActive,
            captureState: capture.captureState,
            activeNotebookId: capture.notebookId,
            notebookId: notebookId
        )
    }

    // The transcript keeps the floor; the rail is where the listener's own
    // record accumulates beside it. With nothing marked — during the
    // recording as much as after it — the transcript has the rail's width.
    @ViewBuilder
    private var transcriptAndRail: some View {
        if #available(macOS 13.0, *) {
            // An HStack probed the whole transcript column at several widths
            // on every publish to share space with a rail whose width never
            // changes; this layout hands out the widths without asking.
            TranscriptRailLayout(separatorWidth: 1, railWidth: Self.railWidth) {
                historyView
                if let markSessionId, showsMarksRail {
                    railSeparator
                    marksRail(sessionId: markSessionId)
                }
            }
        } else {
            HStack(spacing: 0) {
                historyView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let markSessionId, showsMarksRail {
                    Divider().background(Color.borderGhost.opacity(0.4))
                    marksRail(sessionId: markSessionId)
                        .frame(width: Self.railWidth)
                }
            }
        }
    }

    private static let railWidth: CGFloat = 300

    /// The rail used to stand empty beside a live transcript from the first
    /// second, explaining a shortcut. It now arrives with the first mark.
    private var showsMarksRail: Bool {
        marks.marks.isEmpty == false
    }

    private var historyView: some View {
        NotebookRealtimeHistoryView(
            notebookId: notebookId,
            focusSessionId: sessionId,
            history: history
        )
    }

    /// A `Divider` takes its direction from an enclosing stack; outside one
    /// it would draw horizontally, so the line is drawn directly.
    private var railSeparator: some View {
        Color(nsColor: .separatorColor)
            .background(Color.borderGhost.opacity(0.4))
            .frame(width: 1)
            .frame(maxHeight: .infinity)
    }

    private func marksRail(sessionId: String) -> some View {
        SessionMarksPanel(
            sessionId: sessionId,
            isLive: isMarkingLive,
            onMark: { SessionMarkStore.shared.mark() }
        )
    }

    private func reloadHistory() async {
        await history.load(notebookId: notebookId)
        // Read the current IDs after the catalog await. This closes the mount
        // race where an initial speaker refresh could otherwise be cleared by
        // the catalog's notebook-switch/reset prefix or summary filtering.
        refreshActiveSessionSpeakers(activeSessionSpeakerIds)
    }

    /// The session marks attach to: the route's session, or the live one when
    /// the page is the capture console rather than a history route.
    private var markSessionId: String? {
        if let sessionId { return sessionId }
        guard capture.notebookId == notebookId else { return nil }
        return capture.sessionId
    }

    /// Marking is a live gesture. After the recording ends the rail is still
    /// there to read and annotate, but a new mark has no instant to attach to.
    private var isMarkingLive: Bool {
        capture.isCaptureActive
            && capture.notebookId == notebookId
            && capture.sessionId == markSessionId
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
        return capture.utteranceSpeakerIds
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

    /// Whether the console has anything to put above the transcript.
    ///
    /// A recording in progress has not: the recording bar's sentence is the
    /// one place its state is said. A stop is the same while it goes
    /// normally — the bar counts it out — and gets a line here only when it
    /// needs a person (it failed, or the audio is still being saved).
    func showsConsole(stopNeedsAttention: Bool) -> Bool {
        switch self {
        case .inactiveEditor, .activeElsewhereSummary: return true
        case .activeRunSummary: return false
        case .drainingSummary: return stopNeedsAttention
        }
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
            // No "· TH" after it: a language code is ours, not a word the
            // person choosing a language knows. Typing one still finds it.
            return (code, names)
        }
    }
}

private struct NotebookRealtimeCaptureConsole: View {
    let notebookId: String
    @ObservedObject var editor: NotebookCaptureProfileEditorModel
    @ObservedObject private var capture = ActiveBilingualTranscriptStore.shared
    @ObservedObject private var credentialSession = ProviderCredentialSession.shared

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

    /// What is left of the active-run row. It used to say the configuration
    /// was frozen, name the provider and its model, and report captions
    /// health and lag — all of it either internal or the recording bar's
    /// sentence a second time. Two things remain, neither about the text:
    /// that this topic cannot start a recording because another one is
    /// running, and a stop that needs a person.
    private var activeRunSummary: some View {
        HStack(alignment: .center, spacing: Spacing.sm) {
            if presentation == .activeElsewhereSummary {
                Image(systemName: "lock.fill")
                    .accessibilityHidden(true)
                Text(String(localized: "capture.toolbar.active_other_notebook"))
            } else if capture.stopRecoveryRequired {
                Image(systemName: "exclamationmark.triangle.fill")
                    .accessibilityHidden(true)
                Text(String(localized: "capture.toast.stop_failed"))
            } else if capture.isAudioDrainDelayed {
                Image(systemName: "externaldrive.badge.timemachine")
                    .accessibilityHidden(true)
                Text(String(localized: "capture.state.audio_drain_delayed"))
            }
            Spacer(minLength: 0)
        }
        .font(.captionMedium)
        .foregroundColor(.textSecondary)
        .accessibilityElement(children: .combine)
    }

    private var inactiveProfileEditor: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            inactiveProfileControls
        }
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

            CaptureLanguageEditor(editor: editor)
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

    private func languageLabel(_ code: String) -> String {
        languages.first(where: { $0.code == code })?.label ?? code.uppercased()
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
    @ObservedObject private var readingLayout = TranscriptReadingLayout.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedSessionID: String?
    /// Not @State fields: see `LiveFollowTicket`.
    @State private var liveFollow = LiveFollowTicket()
    @State private var isFollowingLive = true

    var body: some View {
        VStack(spacing: 0) {
            // A way of reading is only offered when there is something to
            // read — and, while that something is still being recorded, from
            // the recording bar's ⋯ instead, so this page is all transcript.
            if let run = presentedRun, run.sessionId != activeSessionID {
                presentationControl
                Divider().background(Color.borderGhost.opacity(0.28))
            }
            historyBody
        }
        .background(Color.bgRoot)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(String(localized: "capture.transcript.realtime_accessibility_label")))
        .onDisappear(perform: cancelLiveFollow)
        // The bar's ⋯ ticks the layout in effect; until someone chooses,
        // that is the one this page worked out from its recordings.
        .onAppear { readingLayout.noteDefault(defaultPresentationMode, for: notebookId) }
        .montereyOnChange(of: defaultPresentationMode) { _, mode in
            readingLayout.noteDefault(mode, for: notebookId)
        }
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
            // The live run draws its rows from the timeline; its run value
            // carries none, so an unchanged run stays equal while rows move.
            utterances: []
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

    /// What this topic's transcript opens in when nobody chose.
    private var defaultPresentationMode: NotebookTranscriptPresentationMode {
        history.presentationMode(for: notebookId)
    }

    /// The choice is shared with the recording bar's ⋯ (see
    /// `TranscriptReadingLayout`); the control below and that menu are two
    /// entries to it.
    private var presentationMode: NotebookTranscriptPresentationMode {
        readingLayout.chosen[notebookId] ?? defaultPresentationMode
    }

    private var presentationBinding: Binding<NotebookTranscriptPresentationMode> {
        Binding(
            get: { presentationMode },
            set: { readingLayout.choose($0, for: notebookId) }
        )
    }

    /// Both ways of reading, visible at once, above a finished transcript.
    /// This was a menu whose arrow only appeared on hover, labelled with the
    /// current choice alone.
    private var presentationControl: some View {
        HStack {
            Picker(
                String(localized: "capture.transcript.presentation.label"),
                selection: presentationBinding
            ) {
                Text(String(localized: "capture.transcript.presentation.language_columns"))
                    .tag(NotebookTranscriptPresentationMode.bilingualColumns)
                Text(String(localized: "capture.transcript.presentation.timeline"))
                    .tag(NotebookTranscriptPresentationMode.sourceTimeline)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help(String(localized: presentationMode == .bilingualColumns
                ? "capture.transcript.presentation.language_columns_detail"
                : "capture.transcript.presentation.timeline_detail"))
            .accessibilityLabel(Text(String(localized: "capture.transcript.presentation.label")))
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
            // Nothing is being recorded here yet: say what will appear, not
            // that a recording "has no realtime result".
            EmptyState(
                icon: "captions.bubble",
                title: String(localized: focusSessionId == nil
                    ? "capture.live.idle_title"
                    : "editor.transcript.realtime.empty_title"),
                description: String(localized: focusSessionId == nil
                    ? "capture.live.idle_detail"
                    : "editor.transcript.realtime.empty_desc")
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
                                    offsetY: LiveScrollGeometry.whole(geometry.contentOffset.y),
                                    distanceFromBottom: LiveScrollGeometry.whole(max(
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
                .onReceive(
                    NotificationCenter.default.publisher(for: .zutalkRevealTranscriptMoment)
                ) { notification in
                    reveal(notification, using: proxy)
                }
                // The live overlay maps runs one to one and keeps their ids,
                // so the catalog's ids are the same list — without filtering
                // the whole live transcript again just to read them.
                .montereyOnChange(of: history.runs.map(\.sessionId)) { _, _ in
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
                        liveTranslationCues: [],
                        continuationCues: history.translationCueIndex(sessionId: run.sessionId),
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

    /// Brings the row spoken at a moment into view, and stops following the
    /// live edge so it stays there.
    private func reveal(_ notification: Notification, using proxy: ScrollViewProxy) {
        guard let run = presentedRun,
              let sessionId = notification.userInfo?["sessionId"] as? String,
              sessionId == run.sessionId,
              let ms = notification.userInfo?["ms"] as? UInt64
        else { return }
        let utterances = sessionId == activeSessionID ? capture.utterances : run.utterances
        guard let target = utterances
            .filter({ ($0.sourceStartMs ?? .max) <= ms })
            .max(by: { ($0.sourceStartMs ?? 0) < ($1.sourceStartMs ?? 0) })
            ?? utterances.first
        else { return }
        cancelLiveFollow()
        isFollowingLive = false
        // Rows live inside blocks, and a lazy stack only knows the ids of its
        // own children: bring the row's block in first, then the row.
        let listed = presentationMode == .bilingualColumns
            ? utterances
            : utterances.filter(\.hasSourceLane)
        if listed.contains(where: { $0.id == target.id }) {
            proxy.scrollTo(
                NotebookTranscriptRowBlocks.anchor(ofSequence: target.sequence),
                anchor: .center
            )
        }
        Task { @MainActor in
            await Task.yield()
            if reduceMotion {
                proxy.scrollTo(target.id, anchor: .center)
            } else {
                withAnimation(.easeOut(duration: 0.22)) {
                    proxy.scrollTo(target.id, anchor: .center)
                }
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
        // Only a real change may invalidate the view; this runs on every
        // scroll-geometry change, including the ones its own relayout causes.
        if isFollowingLive != next {
            isFollowingLive = next
        }
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
        guard liveFollow.task == nil,
              isFollowingLive,
              let sessionID = activeSessionID,
              selectedSessionID == sessionID else { return }
        let ticket = liveFollow
        ticket.generation &+= 1
        let generation = ticket.generation
        ticket.task = Task { @MainActor in
            try? await MontereyTaskSleep.milliseconds(250)
            guard Task.isCancelled == false,
                  generation == ticket.generation,
                  isFollowingLive,
                  selectedSessionID == sessionID,
                  activeSessionID == sessionID else {
                if generation == ticket.generation {
                    ticket.task = nil
                }
                return
            }
            proxy.scrollTo(liveTailAnchor(sessionID), anchor: .bottom)
            ticket.task = nil
        }
    }

    private func cancelLiveFollow() {
        liveFollow.cancel()
    }
}

private struct NotebookRealtimeActiveRunView: View {
    let run: NotebookCaptureHistoryRunDTO
    let presentationMode: NotebookTranscriptPresentationMode
    let isLaneEditingEnabled: Bool
    let history: NotebookCaptureHistoryStore
    private let capture: ActiveBilingualTranscriptStore
    private let liveTailAnchorID: String
    private let onLiveAutoscrollSignal: () -> Void
    /// The only source of rows here, published at most ten times a second.
    @ObservedObject private var timeline: LiveTranscriptTimeline

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
        _timeline = ObservedObject(wrappedValue: capture.timeline)
    }

    var body: some View {
        // Rows of another session never reach this view: the timeline is
        // reset with the store's session.
        let isThisRun = timeline.frame.sessionId == run.sessionId
        let chunks = isThisRun ? timeline.frame.chunks : []
        VStack(spacing: 0) {
            NotebookRealtimeUtteranceView(
                run: run,
                liveChunks: chunks,
                liveHasStoredRows: isThisRun && timeline.frame.hasStoredRows,
                liveTranslationCues: capture.presentedTranslationCueSnapshot,
                continuationCues: capture.continuationCueIndex,
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
                history: history,
                translationProgress: capture.translationProgress
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
            in: timeline.frame.sessionId == run.sessionId ? timeline.frame.tail(limit: 1) : [],
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
