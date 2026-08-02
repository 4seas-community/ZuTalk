import AppKit
import Combine
import SwiftUI

// MARK: - Notebook-only capture controls

@MainActor
struct NotebookCaptureStartCoordinator {
    let capture: ActiveBilingualTranscriptStore
    let navigation: MainNavigationStoreV2

    func start(notebookId: String) async throws {
        try await capture.start(notebookId: notebookId)
        guard let sessionId = capture.sessionId else {
            throw NotebookCaptureClientError.captureNotActive
        }
        navigation.openRealtimeTranscript(
            notebookID: notebookId,
            selectedSessionID: sessionId
        )
    }
}

enum NotebookCaptureSettingsPersistenceState: Equatable {
    case loading
    case saving
    case saved
    case loadFailed(String)
    case saveFailed(String)
}

struct NotebookCaptureProfileStartBlockedError: LocalizedError, Equatable {
    let reason: String

    var errorDescription: String? { reason }
}

/// A dedicated persistence seam for the settings editor. The editor never
/// observes `ActiveBilingualTranscriptStore.profile`: that value can represent
/// an immutable active or historical run snapshot, not the Notebook's current
/// persisted capture profile.
@MainActor
protocol NotebookCaptureProfilePersisting: AnyObject {
    var isCaptureActive: Bool { get }
    var lastError: String? { get }

    func profileForNotebook(_ notebookId: String) -> NotebookCaptureProfileDTO
    @discardableResult
    func saveProfile(_ candidate: NotebookCaptureProfileDTO) throws -> NotebookCaptureProfileDTO
}

extension ActiveBilingualTranscriptStore: NotebookCaptureProfilePersisting {}

/// A finite set of low-frequency UI intents. SwiftUI control bindings enqueue
/// these values instead of publishing ObservableObject changes from inside a
/// view update. The editor drains them in order on the next MainActor turn.
enum NotebookCaptureProfileEditAction {
    case remoteRealtimeEnabled(Bool)
    case selectedLanguages([String])
    case addLanguage(String)
    case removeLanguage(String)
    case moveLanguage(String, offset: Int)
    case sendContextToSoniox(Bool)

    fileprivate func apply(to profile: inout NotebookCaptureProfileDTO) {
        switch self {
        case .remoteRealtimeEnabled(let enabled):
            profile.remoteRealtimeEnabled = enabled
        case .selectedLanguages(let languages):
            profile.selectedLanguages = languages
        case .addLanguage(let language):
            guard profile.selectedLanguages.count
                    < NotebookCaptureSupportedLanguages.maximumSelectedCount,
                  profile.selectedLanguages.contains(language) == false
            else { return }
            profile.selectedLanguages.append(language)
        case .removeLanguage(let language):
            guard profile.selectedLanguages.count > 1,
                  let index = profile.selectedLanguages.firstIndex(of: language)
            else { return }
            profile.selectedLanguages.remove(at: index)
        case .moveLanguage(let language, let offset):
            guard let index = profile.selectedLanguages.firstIndex(of: language) else { return }
            let destination = index + offset
            guard profile.selectedLanguages.indices.contains(destination) else { return }
            profile.selectedLanguages.remove(at: index)
            profile.selectedLanguages.insert(language, at: destination)
        case .sendContextToSoniox(let enabled):
            profile.sendContextToSoniox = enabled
        }
    }
}

/// Owns one Notebook's editable capture profile. SwiftUI intents enter a
/// next-MainActor-turn FIFO; within that drain, each save completes
/// synchronously and returns its CAS revision before the next intent is applied.
/// Older responses therefore cannot overwrite a newer draft, and rapid toggles
/// cannot share a stale revision.
@MainActor
final class NotebookCaptureProfileEditorModel: ObservableObject {
    let notebookId: String

    @Published private(set) var draft: NotebookCaptureProfileDTO
    @Published private(set) var persistenceState: NotebookCaptureSettingsPersistenceState = .loading

    private let persistence: any NotebookCaptureProfilePersisting
    private var persistedProfile: NotebookCaptureProfileDTO?
    private var pendingViewActions: [NotebookCaptureProfileEditAction] = []
    private var scheduledViewActionDrain: Task<Void, Never>?

    init(notebookId: String) {
        self.notebookId = notebookId
        self.persistence = ActiveBilingualTranscriptStore.shared
        self.draft = .localDefault(notebookId: notebookId)
    }

    init(
        notebookId: String,
        persistence: any NotebookCaptureProfilePersisting
    ) {
        self.notebookId = notebookId
        self.persistence = persistence
        self.draft = .localDefault(notebookId: notebookId)
    }

    var canEdit: Bool {
        guard persistedProfile != nil else { return false }
        if case .loading = persistenceState { return false }
        if case .loadFailed = persistenceState { return false }
        return persistence.isCaptureActive == false
    }

    var captureStartDisabledReason: String? {
        switch persistenceState {
        case .saved:
            return nil
        case .loading:
            return String(localized: "capture.settings.autosave.loading")
        case .saving:
            return String(localized: "capture.settings.autosave.saving")
        case .loadFailed:
            return String(localized: "capture.settings.autosave.load_failed")
        case .saveFailed:
            return String(localized: "capture.settings.autosave.save_failed")
        }
    }

    func load() {
        persistenceState = .loading
        let loaded = persistence.profileForNotebook(notebookId)
        draft = loaded
        guard let loadError = persistence.lastError else {
            persistedProfile = loaded
            persistenceState = .saved
            return
        }

        // `profileForNotebook` deliberately returns a privacy-safe revision-0
        // fallback on read failure. Keep it visible, but never make it editable
        // or write it back over a real profile.
        persistedProfile = nil
        persistenceState = .loadFailed(loadError)
    }

    func update(_ change: (inout NotebookCaptureProfileDTO) -> Void) {
        guard canEdit else { return }
        var candidate = draft
        change(&candidate)
        candidate = Self.normalized(candidate)
        guard Self.sameConfiguration(candidate, draft) == false else { return }
        draft = candidate
        persist(candidate)
    }

    /// SwiftUI can invoke a Binding setter while AttributeGraph is evaluating
    /// the current view. Publishing or crossing FFI synchronously from that
    /// callback causes a re-entrant update. Queue concrete intents, yield one
    /// MainActor turn, then preserve their order and fresh CAS revisions.
    @discardableResult
    func scheduleUpdate(_ action: NotebookCaptureProfileEditAction) -> Task<Void, Never> {
        pendingViewActions.append(action)
        if let scheduledViewActionDrain {
            return scheduledViewActionDrain
        }

        // Keep the editor alive through the next-turn drain so autosave is not
        // cancelled by SwiftUI tearing down the originating view.
        let task = Task { @MainActor in
            await Task.yield()
            self.drainScheduledUpdates()
        }
        scheduledViewActionDrain = task
        return task
    }

    /// A Start click is both the commit boundary for queued language edits and
    /// the explicit authorization for this recording's Soniox realtime lane.
    /// Persist that authorization before audio preparation so there is one
    /// user decision, one durable profile snapshot, and no pre-start egress.
    func prepareForCaptureStart() async throws {
        while let scheduledViewActionDrain {
            await scheduledViewActionDrain.value
        }
        if draft.remoteRealtimeEnabled == false {
            update { $0.remoteRealtimeEnabled = true }
        }
        if let reason = captureStartDisabledReason {
            throw NotebookCaptureProfileStartBlockedError(reason: reason)
        }
    }

    func retry() {
        guard persistence.isCaptureActive == false else { return }
        switch persistenceState {
        case .loadFailed:
            load()
        case .saveFailed:
            persist(draft)
        case .loading, .saving, .saved:
            break
        }
    }

    static func normalized(_ profile: NotebookCaptureProfileDTO) -> NotebookCaptureProfileDTO {
        var normalized = profile

        var seenLanguages = Set<String>()
        normalized.selectedLanguages = normalized.selectedLanguages.compactMap { language in
            let code = language
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .split(separator: "-")
                .first
                .map(String.init) ?? ""
            guard code.isEmpty == false, code != "und",
                  seenLanguages.insert(code).inserted
            else { return nil }
            return code
        }
        normalized.selectedLanguages = Array(
            normalized.selectedLanguages.prefix(
                NotebookCaptureSupportedLanguages.maximumSelectedCount
            )
        )
        if normalized.selectedLanguages.isEmpty {
            let fallback = normalized.languageA
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .split(separator: "-")
                .first
                .map(String.init) ?? ""
            normalized.selectedLanguages = [fallback.isEmpty ? "en" : fallback]
        }

        if normalized.remoteRealtimeEnabled == false {
            normalized.mode = .transcriptionOnly
            normalized.sendContextToSoniox = false
        } else {
            switch normalized.selectedLanguages.count {
            case 1:
                normalized.mode = .transcriptionOnly
            case 2:
                normalized.mode = .twoWay
            default:
                normalized.mode = .multilingualOneWay
            }
        }

        // Language order controls only the visible column order. New captures
        // do not promote the first selected language to a special target.
        normalized.commonCaptionLanguage = nil

        // Keep the legacy pair fields synchronized while older history rows
        // and mixed-version clients still rely on them. They are no longer
        // exposed as user choices.
        normalized.languageA = normalized.selectedLanguages[0]
        if normalized.selectedLanguages.count >= 2 {
            normalized.languageB = normalized.selectedLanguages[1]
        } else {
            let legacyB = normalized.languageB
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .split(separator: "-")
                .first
                .map(String.init) ?? ""
            normalized.languageB = legacyB.isEmpty || legacyB == normalized.languageA
                ? (normalized.languageA == "en" ? "zh" : "en")
                : legacyB
        }
        normalized.leftLanguage = normalized.languageA
        normalized.rightLanguage = normalized.languageB
        return normalized
    }

    static func sameConfiguration(
        _ lhs: NotebookCaptureProfileDTO,
        _ rhs: NotebookCaptureProfileDTO
    ) -> Bool {
        var lhs = lhs
        var rhs = rhs
        lhs.revision = 0
        rhs.revision = 0
        return lhs == rhs
    }

    private func persist(_ requested: NotebookCaptureProfileDTO) {
        guard let persistedProfile else { return }
        var candidate = Self.normalized(requested)
        candidate.revision = persistedProfile.revision
        draft = candidate
        persistenceState = .saving

        do {
            let saved = try persistence.saveProfile(candidate)
            self.persistedProfile = saved
            draft = saved
            persistenceState = .saved
        } catch {
            let saveMessage = error.localizedDescription
            let refreshed = persistence.profileForNotebook(notebookId)
            if persistence.lastError == nil {
                self.persistedProfile = refreshed
                if Self.sameConfiguration(refreshed, candidate) {
                    // The profile write succeeded, but required post-write
                    // preparation failed. Keep the persisted value visible and
                    // expose a retryable technical failure.
                    draft = refreshed
                    persistenceState = .saveFailed(saveMessage)
                } else {
                    var rebased = candidate
                    rebased.revision = refreshed.revision
                    draft = rebased
                    persistenceState = .saveFailed(saveMessage)
                }
            } else {
                persistenceState = .saveFailed(saveMessage)
            }
        }
    }

    private func drainScheduledUpdates() {
        let actions = pendingViewActions
        pendingViewActions.removeAll(keepingCapacity: true)
        scheduledViewActionDrain = nil

        for action in actions {
            guard canEdit else { continue }
            update { action.apply(to: &$0) }
        }
    }
}

/// The only UI surface allowed to start, pause, resume, or stop capture.
/// Menu bar, Floating, and Caption Mirror surfaces observe the same store read-only.
struct NotebookCaptureToolbar: View {
    let notebookId: String
    @ObservedObject var profileEditor: NotebookCaptureProfileEditorModel
    @ObservedObject private var capture = ActiveBilingualTranscriptStore.shared
    @State private var isStarting = false
    @State private var isPausing = false
    @State private var isStopping = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            HStack(spacing: Spacing.sm) {
                if capture.isCaptureActive {
                    if capture.notebookId == notebookId {
                        captureStatus
                        pauseButton
                        stopButton
                    } else {
                        Button {
                            MainNavigationStoreV2.shared.openActiveNotebookForCapture()
                        } label: {
                            Label(
                                String(localized: "capture.toolbar.active_other_notebook"),
                                systemImage: "arrowshape.turn.up.left.fill"
                            )
                            .font(.captionMedium)
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.textOnBpDim)
                        .help(String(localized: "capture.open_notebook_hint"))
                        .accessibilityLabel(Text(String(localized: "capture.open_notebook")))
                    }
                } else {
                    startButton
                }

            }

            if showsPauseBillingNotice {
                Label(
                    String(localized: "capture.toolbar.pause_billing"),
                    systemImage: "clock.badge.exclamationmark"
                )
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.signalAmber)
                .lineLimit(1)
                .help(String(localized: "capture.toolbar.pause_billing_detail"))
                .accessibilityHint(Text(String(localized: "capture.toolbar.pause_billing_detail")))
            }
        }
    }

    /// Mirrors the Rust core's `remote_stream_plan`: one or two languages run
    /// on a single WebSocket, three or more open one canonical lane plus one
    /// translation lane per language. Invite billing charges per lane.
    static func remoteLaneCount(selectedLanguages: [String]) -> Int {
        selectedLanguages.count <= 2 ? 1 : selectedLanguages.count + 1
    }

    private var startButton: some View {
        Button {
            guard isStarting == false,
                  profileEditor.captureStartDisabledReason == nil
            else { return }
            isStarting = true
            Task { @MainActor in
                defer { isStarting = false }
                do {
                    // Local-only recordings open no Soniox lanes; reserving
                    // invite time for them would silently burn shared quota.
                    if profileEditor.draft.remoteRealtimeEnabled {
                        let preparation = try await CommunityInviteSession.shared
                            .prepareRealtimeCredential(
                                laneCount: Self.remoteLaneCount(
                                    selectedLanguages: profileEditor.draft.selectedLanguages
                                )
                            )
                        if preparation == .personalKeyFallback {
                            ToastCenter.shared.info(
                                String(localized: "community_invite.fallback_personal_key")
                            )
                        }
                    }
                    try await profileEditor.prepareForCaptureStart()
                    try await NotebookCaptureStartCoordinator(
                        capture: capture,
                        navigation: MainNavigationStoreV2.shared
                    ).start(notebookId: notebookId)
                } catch {
                    // Return any invite reservation made above; a no-op when
                    // none exists.
                    await CommunityInviteSession.shared.settleRealtimeSession(usedSeconds: 0)
                    ToastCenter.shared.error(
                        String(localized: "capture.toast.start_failed"),
                        detail: error.localizedDescription
                    )
                }
            }
        } label: {
            Label(
                isStarting
                    ? String(localized: "capture.toolbar.starting")
                    : String(localized: "capture.toolbar.start"),
                systemImage: isStarting ? "ellipsis" : "record.circle"
            )
            .font(.captionMedium)
            .padding(.horizontal, 10)
            .frame(minHeight: 28)
        }
        .buttonStyle(.plain)
        .foregroundColor(.brandAccent)
        .background(Color.brandAccent.opacity(0.12))
        .overlay(Capsule().strokeBorder(Color.brandAccent.opacity(0.45), lineWidth: 0.5))
        .clipShape(Capsule())
        .disabled(isStarting || profileEditor.captureStartDisabledReason != nil)
        .keyboardShortcut("r", modifiers: [.control, .option])
        .accessibilityLabel(Text(String(localized: "capture.toolbar.start")))
        .accessibilityHint(Text(
            profileEditor.captureStartDisabledReason
                ?? String(localized: "capture.toolbar.start_hint")
        ))
        .help(
            profileEditor.captureStartDisabledReason
                ?? String(localized: "capture.toolbar.start_hint")
        )
    }

    private var pauseButton: some View {
        let isPaused = capture.captureState == .paused
        return Button {
            guard isPausing == false else { return }
            isPausing = true
            Task { @MainActor in
                defer { isPausing = false }
                do {
                    try await capture.setPaused(!isPaused)
                } catch {
                    ToastCenter.shared.error(
                        String(localized: "capture.toast.pause_failed"),
                        detail: error.localizedDescription
                    )
                }
            }
        } label: {
            Label(
                isPaused
                    ? String(localized: "capture.toolbar.resume")
                    : String(localized: "capture.toolbar.pause"),
                systemImage: isPaused ? "play.fill" : "pause.fill"
            )
            .font(.captionMedium)
            .frame(minWidth: 72, minHeight: 28)
        }
        .buttonStyle(.plain)
        .foregroundColor(.bpLine)
        .background(Color.bpBlueLight.opacity(0.65))
        .clipShape(Capsule())
        .disabled(capture.captureState == .draining || isPausing)
        .keyboardShortcut("p", modifiers: [.control, .option])
        .accessibilityLabel(Text(isPaused
            ? String(localized: "capture.toolbar.resume")
            : String(localized: "capture.toolbar.pause")))
    }

    private var stopButton: some View {
        Button {
            guard isStopping == false else { return }
            isStopping = true
            Task { @MainActor in
                defer { isStopping = false }
                do {
                    let usedSeconds = Int(capture.elapsedRecordingTime.rounded(.up))
                    try await capture.stop()
                    await CommunityInviteSession.shared.settleRealtimeSession(
                        usedSeconds: usedSeconds
                    )
                } catch {
                    ToastCenter.shared.error(
                        String(localized: "capture.toast.stop_failed"),
                        detail: error.localizedDescription
                    )
                }
            }
        } label: {
            Label(
                isStopping
                    ? String(localized: "capture.state.draining")
                    : String(localized: "capture.toolbar.stop"),
                systemImage: isStopping ? "hourglass" : "stop.fill"
            )
                .font(.captionMedium)
                .frame(minWidth: 64, minHeight: 28)
        }
        .buttonStyle(.plain)
        .foregroundColor(.signalRed)
        .background(Color.signalRed.opacity(0.12))
        .clipShape(Capsule())
        .disabled(capture.captureState == .draining || isStopping)
        .keyboardShortcut("r", modifiers: [.control, .option])
        .accessibilityLabel(Text(String(localized: "capture.toolbar.stop")))
        .accessibilityHint(Text(String(localized: "capture.toolbar.stop_hint")))
    }

    private var captureStatus: some View {
        CaptureStateLabel(
            captureState: capture.captureState,
            remoteHealth: capture.remoteHealth,
            projectionState: capture.projectionState
        )
    }

    private var showsPauseBillingNotice: Bool {
        guard capture.captureState == .paused else { return false }
        return capture.remoteHealth == .connecting
            || capture.remoteHealth == .live
            || capture.remoteHealth == .degraded
    }
}

// MARK: - Realtime capture command center

/// Realtime exists before the first session. The profile editor represents the
/// next capture; a loaded run remains an immutable source snapshot below it.
struct NotebookRealtimeTranscriptPage: View {
    let notebookId: String
    /// Optional navigation focus only. History is always queried by Notebook.
    let sessionId: String?
    @ObservedObject var editor: NotebookCaptureProfileEditorModel
    let onOpenAdvancedSettings: () -> Void
    @StateObject private var history = NotebookCaptureHistoryStore()
    @ObservedObject private var capture = ActiveBilingualTranscriptStore.shared
    @ObservedObject private var subtitleOverlay = SubtitleOverlayCoordinator.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Spacing.md) {
                Label(
                    String(localized: "capture.realtime.controls.profile_group"),
                    systemImage: "waveform.and.mic"
                )
                    .font(.captionMedium)
                    .foregroundColor(.textOnBpDim)
                Spacer(minLength: Spacing.md)
                NotebookCaptureToolbar(
                    notebookId: notebookId,
                    profileEditor: editor
                )
                floatingSubtitleButton
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.vertical, Spacing.sm)
            .background(Color.bpBlueDeep.opacity(0.42))

            NotebookRealtimeCaptureConsole(
                notebookId: notebookId,
                editor: editor,
                onOpenAdvancedSettings: onOpenAdvancedSettings
            )

            Divider().background(Color.bpLineGhost.opacity(0.3))

            NotebookRealtimeHistoryView(
                notebookId: notebookId,
                focusSessionId: sessionId,
                history: history
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.bpBlue)
        .task(id: notebookId) {
            await reloadHistory()
        }
        .onChange(of: capture.sessionId) { _, _ in
            guard capture.notebookId == notebookId else { return }
            Task { await reloadHistory() }
        }
        .onChange(of: capture.captureState) { _, state in
            guard capture.notebookId == notebookId,
                  state.isActive == false else { return }
            Task { await reloadHistory() }
        }
        .onChange(of: activeSessionSpeakerIds) { _, speakerIds in
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

    private func refreshActiveSessionSpeakers(_ speakerIds: [String]) {
        guard speakerIds.isEmpty == false,
              capture.notebookId == notebookId,
              let sessionId = capture.sessionId else { return }
        history.refreshSessionSpeakers(sessionId: sessionId)
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
        .foregroundColor(isPresented ? .brandAccent : .bpLine)
        .background(
            RoundedRectangle(cornerRadius: Radius.xs)
                .fill(isPresented ? Color.brandAccent.opacity(0.14) : Color.bpBlueLight.opacity(0.65))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.xs)
                .strokeBorder(
                    isPresented ? Color.brandAccent.opacity(0.5) : Color.bpLineGhost.opacity(0.25),
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
    let onOpenAdvancedSettings: () -> Void
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
        .background(Color.bpBlueLight.opacity(0.2))
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
                .foregroundColor(.textOnBpDim)
            } else {
                summaryChip(
                    activeRemoteStatus(for: profile),
                    systemImage: profile.remoteRealtimeEnabled ? "network" : "lock.fill"
                )
            }
            Spacer(minLength: Spacing.sm)
            if presentation == .drainingSummary {
                HStack(spacing: Spacing.xs) {
                    if capture.isAudioDrainDelayed {
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
                .foregroundColor(.textOnBpDim)
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
                .foregroundColor(.bpLine)
            Text(scopeDetail)
                .font(.system(size: 10))
                .foregroundColor(.textOnBpFaint)
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
        .background(Color.bpBlueDeep.opacity(0.34))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.sm)
                .strokeBorder(Color.bpLineGhost.opacity(0.25), lineWidth: 0.5)
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
                    .foregroundColor(.bpLine)
                Spacer(minLength: Spacing.sm)
                persistenceStatus
            }
            Text(String(localized: "capture.settings.languages.ordered_detail"))
                .font(.system(size: 10))
                .foregroundColor(.textOnBpFaint)
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
            .scrollIndicators(.visible)

            HStack(spacing: Spacing.sm) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.textOnBpFaint)
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
            .background(Color.bpBlueDeep.opacity(0.5))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.xs)
                    .strokeBorder(Color.bpLineGhost.opacity(0.3), lineWidth: 0.5)
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
                .foregroundColor(.textOnBpFaint)
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
                    .foregroundColor(.textOnBpFaint)
                    .padding(.vertical, Spacing.xs)
            } else if matches.isEmpty {
                Text(String(localized: "capture.settings.languages.no_results"))
                    .font(.caption)
                    .foregroundColor(.textOnBpFaint)
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
                    .foregroundColor(.textOnBpFaint)
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
                    .foregroundColor(.bpLine)
                    .background(Color.bpBlueLight.opacity(0.42))
                    .clipShape(Capsule())
                    .accessibilityLabel(Text(String(
                        format: String(localized: "capture.settings.languages.add_format"),
                        language.label
                    )))
                }
            }
        }
        .scrollIndicators(.visible)
    }

    private func selectedLanguageChip(language: String, index: Int) -> some View {
        HStack(spacing: 2) {
            Text(languageLabel(language))
                .font(.captionMedium)
                .foregroundColor(.bpLine)
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
        .background(Color.bpBlueLight.opacity(0.42))
        .overlay(
            Capsule()
                .strokeBorder(Color.bpLineGhost.opacity(0.3), lineWidth: 0.5)
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
        .foregroundColor(.textOnBpDim)
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
        case .savedLoadedUnverified, .runtimeOnlyUnverified: .textOnBpDim
        case .savedInactive: .signalAmber
        case .missing: .textOnBpFaint
        }
    }

    private var controlDivider: some View {
        Divider().background(Color.bpLineGhost.opacity(0.24))
    }

    private func summaryChip(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.captionMedium)
            .foregroundColor(.bpLine)
            .padding(.horizontal, Spacing.sm)
            .frame(minHeight: 28)
            .background(Color.bpBlueDeep.opacity(0.42))
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
                color: .textOnBpDim
            )
        case .saving:
            statusLabel(
                String(localized: "capture.settings.autosave.saving"),
                systemImage: "arrow.triangle.2.circlepath",
                color: .textOnBpDim
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
                .foregroundColor(.textOnBpFaint)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(title). \(message)"))
    }

}

// MARK: - Notebook capture settings

struct NotebookCaptureSettingsView: View {
    let notebookId: String
    @ObservedObject private var capture = ActiveBilingualTranscriptStore.shared
    @ObservedObject private var editor: NotebookCaptureProfileEditorModel
    @ObservedObject private var engineStore = NotebookCaptureEnginePresentationStore.shared
    @ObservedObject private var inputDevices = AudioInputDeviceStore.shared
    let onOpenRealtimeControls: () -> Void
    @State private var isReviewingContext = false
    @State private var isLoadingContextPacks = true
    @State private var contextLoadError: String?

    init(
        notebookId: String,
        editor: NotebookCaptureProfileEditorModel,
        onOpenRealtimeControls: @escaping () -> Void
    ) {
        self.notebookId = notebookId
        _editor = ObservedObject(wrappedValue: editor)
        self.onOpenRealtimeControls = onOpenRealtimeControls
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                header

                if capture.isCaptureActive {
                    Label(
                        String(localized: "capture.settings.active_locked"),
                        systemImage: "exclamationmark.circle.fill"
                    )
                    .font(.captionMedium)
                    .foregroundColor(.signalAmber)
                    .padding(Spacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.signalAmber.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
                }

                audioInputSection

                VStack(alignment: .leading, spacing: Spacing.lg) {
                    contextBrowserSection
                    postStopRemoteProcessingSection
                    retentionSection
                }
                .disabled(editor.canEdit == false)
                .opacity(editor.canEdit ? 1 : 0.62)

                realtimeFooterLink
            }
            .frame(maxWidth: 820, alignment: .leading)
            .padding(Spacing.xl)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.bpBlue)
        .task(id: notebookId) {
            inputDevices.refresh()
            engineStore.refresh()
            loadContextBrowser()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            inputDevices.refresh()
        }
    }

    private var draft: NotebookCaptureProfileDTO { editor.draft }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: Spacing.md) {
                headerCopy
                Spacer()
                settingsActions
            }
            VStack(alignment: .leading, spacing: Spacing.sm) {
                headerCopy
                settingsActions
            }
        }
    }

    private var settingsActions: some View {
        persistenceStatus
    }

    private var headerCopy: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(String(localized: "capture.settings.title"))
                .font(.headline)
                .foregroundColor(.bpLine)
            Text(String(localized: "capture.settings.subtitle"))
                .font(.caption)
                .foregroundColor(.textOnBpDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var audioInputSection: some View {
        settingsCard(
            title: String(localized: "settings.audio_input.title"),
            icon: "waveform.and.mic"
        ) {
            Text(String(localized: "settings.audio_input.subtitle"))
                .font(.caption)
                .foregroundColor(.textOnBpDim)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Spacing.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "settings.audio_input.device"))
                        .font(.captionMedium)
                        .foregroundColor(.bpLine)
                    Text(String(localized: "settings.audio_input.local_scope"))
                        .font(.system(size: 10))
                        .foregroundColor(.textOnBpFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: Spacing.sm)

                Picker("", selection: audioInputSelection) {
                    Text(systemDefaultInputTitle).tag(String?.none)
                    ForEach(inputDevices.devices) { device in
                        Text(device.name).tag(Optional(device.uid))
                    }
                    if inputDevices.isExplicitSelectionUnavailable,
                       let missingUID = inputDevices.selectedUID {
                        Text(unavailableInputTitle).tag(Optional(missingUID))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 280, alignment: .trailing)
                .disabled(audioInputSelectionDisabled)
                .accessibilityLabel(Text(String(localized: "settings.audio_input.device")))

                Button {
                    inputDevices.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundColor(.textOnBpDim)
                .disabled(capture.isAudioInputSwitching)
                .help(String(localized: "settings.audio_input.refresh"))
                .accessibilityLabel(Text(String(localized: "settings.audio_input.refresh")))
            }
            .padding(Spacing.md)
            .background(Color.bpBlueDeep.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: Radius.sm))

            Text(String(localized: "settings.audio_input.channel_one_hint"))
                .font(.caption)
                .foregroundColor(.textOnBpDim)
                .fixedSize(horizontal: false, vertical: true)

            if let status = audioInputStatus {
                Label(status.text, systemImage: status.systemImage)
                    .font(.captionMedium)
                    .foregroundColor(status.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var audioInputSelection: Binding<String?> {
        Binding(
            get: { inputDevices.selectedUID },
            set: { requestedUID in
                Task { @MainActor in
                    do {
                        try await capture.selectAudioInputDevice(
                            uid: requestedUID,
                            notebookId: notebookId
                        )
                    } catch {
                        ToastCenter.shared.error(
                            String(localized: "capture.toast.audio_input_switch_failed"),
                            detail: error.localizedDescription
                        )
                    }
                }
            }
        )
    }

    private var audioInputSelectionDisabled: Bool {
        capture.isAudioInputSwitching
            || capture.captureState == .draining
            || (capture.isCaptureActive && capture.notebookId != notebookId)
    }

    private var systemDefaultInputTitle: String {
        let resolvedDevice = inputDevices.selectedUID == nil && capture.isCaptureActive
            ? capture.activeAudioInputDevice
            : inputDevices.defaultInputDevice
        guard let name = resolvedDevice?.name else {
            return String(localized: "settings.audio_input.system_default")
        }
        return String(
            format: String(localized: "settings.audio_input.system_default_format"),
            name
        )
    }

    private var unavailableInputTitle: String {
        let name = inputDevices.selectedDeviceLastKnownName
            ?? inputDevices.selectedUID
            ?? String(localized: "settings.audio_input.device")
        return String(
            format: String(localized: "settings.audio_input.unavailable_format"),
            name
        )
    }

    private var audioInputStatus: (text: String, systemImage: String, color: Color)? {
        if capture.isAudioInputSwitching {
            return (
                String(localized: "settings.audio_input.switching"),
                "arrow.triangle.2.circlepath",
                .brandAccent
            )
        }
        if capture.isCaptureActive, capture.notebookId != notebookId {
            return (
                String(localized: "settings.audio_input.active_elsewhere"),
                "lock.fill",
                .signalAmber
            )
        }
        if capture.captureState == .draining {
            return (
                String(localized: "settings.audio_input.error.switch_unavailable"),
                "hourglass",
                .signalAmber
            )
        }
        if let refreshError = inputDevices.refreshError {
            return (refreshError, "exclamationmark.triangle.fill", .signalAmber)
        }
        if inputDevices.isExplicitSelectionUnavailable {
            return (
                String(
                    format: String(localized: "settings.audio_input.error.unavailable_format"),
                    inputDevices.selectedDeviceLastKnownName
                        ?? inputDevices.selectedUID
                        ?? String(localized: "settings.audio_input.device")
                ),
                "exclamationmark.triangle.fill",
                .signalAmber
            )
        }
        if inputDevices.hasLoadedSnapshot, inputDevices.devices.isEmpty {
            return (
                String(localized: "settings.audio_input.error.no_device"),
                "exclamationmark.triangle.fill",
                .signalAmber
            )
        }
        if capture.isCaptureActive, capture.notebookId == notebookId {
            return (
                String(localized: "settings.audio_input.active_switch_hint"),
                "arrow.left.arrow.right",
                .textOnBpDim
            )
        }
        return nil
    }

    private var realtimeFooterLink: some View {
        Button(action: onOpenRealtimeControls) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "waveform.and.mic")
                    .font(.system(size: 11, weight: .semibold))
                Text(String(localized: "capture.settings.footer.realtime"))
                    .fixedSize(horizontal: false, vertical: true)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
            }
            .font(.caption)
            .foregroundColor(.textOnBpDim)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(String(localized: "capture.settings.footer.realtime")))
    }

    @ViewBuilder
    private var persistenceStatus: some View {
        switch editor.persistenceState {
        case .loading:
            settingsStatusLabel(
                String(localized: "capture.settings.autosave.loading"),
                systemImage: "arrow.clockwise",
                color: .textOnBpDim
            )
        case .saving:
            settingsStatusLabel(
                String(localized: "capture.settings.autosave.saving"),
                systemImage: "arrow.triangle.2.circlepath",
                color: .textOnBpDim
            )
        case .saved:
            settingsStatusLabel(
                String(localized: "capture.settings.autosave.saved"),
                systemImage: "checkmark.circle.fill",
                color: .signalGreen
            )
        case .loadFailed(let message):
            settingsFailureStatus(
                title: String(localized: "capture.settings.autosave.load_failed"),
                message: message,
                actionTitle: String(localized: "capture.settings.autosave.retry"),
                action: editor.retry
            )
        case .saveFailed(let message):
            settingsFailureStatus(
                title: String(localized: "capture.settings.autosave.save_failed"),
                message: message,
                actionTitle: String(localized: "capture.settings.autosave.retry"),
                action: editor.retry
            )
        }
    }

    private func settingsStatusLabel(
        _ title: String,
        systemImage: String,
        color: Color
    ) -> some View {
        Label(title, systemImage: systemImage)
            .font(.captionMedium)
            .foregroundColor(color)
            .accessibilityLabel(Text(title))
    }

    private func settingsFailureStatus(
        title: String,
        message: String,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .trailing, spacing: Spacing.xs) {
            Label(title, systemImage: "exclamationmark.triangle.fill")
                .font(.captionMedium)
                .foregroundColor(.signalAmber)
            Text(message)
                .font(.caption2)
                .foregroundColor(.textOnBpFaint)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
                .help(message)
            Button(actionTitle, action: action)
                .buttonStyle(.link)
                .font(.caption)
                .disabled(capture.isCaptureActive)
        }
        .frame(maxWidth: 280, alignment: .trailing)
    }

    private var contextSection: some View {
        settingsCard(
            title: String(localized: "capture.settings.context.title"),
            icon: "books.vertical.fill"
        ) {
            Text(String(localized: "capture.settings.context.pack_detail"))
                .font(.caption)
                .foregroundColor(.textOnBpDim)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Spacing.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "capture.settings.context.current"))
                        .font(.system(size: 10))
                        .foregroundColor(.textOnBpFaint)
                    Text(selectedContextPack.map(contextPackDisplayTitle)
                         ?? String(localized: "capture.settings.context.no_selection"))
                        .font(.captionMedium)
                        .foregroundColor(.bpLine)
                        .lineLimit(1)
                }

                Spacer(minLength: Spacing.sm)

                Menu {
                    ForEach(capture.contextPacks) { pack in
                        Button {
                            selectContextPack(pack.id)
                        } label: {
                            if capture.selectedContextPackId == pack.id {
                                Label(contextPackDisplayTitle(pack), systemImage: "checkmark")
                            } else {
                                Text(contextPackDisplayTitle(pack))
                            }
                        }
                    }
                } label: {
                    Text(String(localized: "capture.settings.context.choose"))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(capture.contextPacks.isEmpty)
                .accessibilityLabel(Text(String(localized: "capture.settings.context.choose")))
            }
            .padding(Spacing.md)
            .background(Color.bpBlueDeep.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: Radius.sm))

            Button(String(localized: "capture.settings.context.preview")) {
                requestContextPreview()
            }
            .buttonStyle(.plain)
            .font(.caption)
            .disabled(selectedContextPack == nil)

            if isReviewingContext {
                contextReview
            }
        }
    }

    @ViewBuilder
    private var contextBrowserSection: some View {
        if isLoadingContextPacks {
            settingsCard(
                title: String(localized: "capture.settings.context.title"),
                icon: "doc.text.magnifyingglass"
            ) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(Text(String(localized: "capture.settings.autosave.loading")))
            }
        } else if let contextLoadError {
            settingsCard(
                title: String(localized: "capture.settings.context.title"),
                icon: "exclamationmark.triangle.fill"
            ) {
                Text(contextLoadError)
                    .font(.caption)
                    .foregroundColor(.signalAmber)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Button(String(localized: "capture.settings.autosave.retry")) {
                    loadContextBrowser()
                }
                .buttonStyle(.bordered)
            }
        } else if capture.loadedContextNotebookId == notebookId {
            contextSection
        }
    }

    private var retentionSection: some View {
        settingsCard(
            title: String(localized: "capture.settings.retention.title"),
            icon: "internaldrive"
        ) {
            Text(String(localized: "capture.settings.retention.subtitle"))
                .font(.caption)
                .foregroundColor(.textOnBpDim)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(NotebookAudioRetentionLevel.allCases) { level in
                retentionOptionRow(AudioPrivacyOptionSummary(level: level))
            }
        }
    }

    private func retentionOptionRow(_ option: AudioPrivacyOptionSummary) -> some View {
        let isSelected = draft.privacyLevel == option.level
        return Button {
            editor.update { $0.privacyLevel = option.level }
        } label: {
            HStack(alignment: .top, spacing: Spacing.sm) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 12))
                    .foregroundColor(isSelected ? .brandAccent : .textOnBpFaint)
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(option.title))
        .accessibilityValue(Text(isSelected
                                 ? String(localized: "capture.settings.context.selected")
                                 : String(localized: "capture.settings.context.not_selected")))
        .accessibilityHint(Text(option.storageText))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var postStopRemoteProcessingSection: some View {
        settingsCard(
            title: String(localized: "capture.settings.after_stop.title"),
            icon: "waveform.badge.plus"
        ) {
            Text(String(localized: engineStore.engine.postStopUsesAsyncFileApi == true
                ? "capture.settings.after_stop.detail"
                : "capture.settings.after_stop.unavailable_detail"))
                .font(.caption)
                .foregroundColor(.textOnBpDim)
                .fixedSize(horizontal: false, vertical: true)

            Text("\(String(localized: "capture.settings.after_stop.engine")) · \(engineStore.engine.postStopSummary) · \(engineStore.engine.postStopExecutionSummary)")
                .font(.system(size: 10))
                .foregroundColor(.textOnBpFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func contextPackDisplayTitle(_ pack: NotebookContextPackDTO) -> String {
        pack.isPrivate
            ? String(localized: "capture.settings.context.private_pack")
            : pack.title
    }

    @ViewBuilder
    private var contextReview: some View {
        if let preview = capture.contextPreview, preview.notebookId == notebookId {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Label(
                    String(
                        format: String(localized: "capture.settings.context.preview_count"),
                        preview.scalarCount
                    ),
                    systemImage: "eye.fill"
                )
                .font(.captionMedium)
                .foregroundColor(.bpLine)

                ScrollView {
                    Text(preview.containsSendableContext == false
                         ? String(localized: "capture.settings.context.empty")
                         : preview.serializedContext)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.textOnBpDim)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Spacing.sm)
                }
                .frame(minHeight: 96, maxHeight: 180)
                .background(Color.bpBlueDeep.opacity(0.7))
                .clipShape(RoundedRectangle(cornerRadius: Radius.sm))

                ForEach(preview.sources) { source in
                    Label {
                        Text("\(source.title) · \(source.scalarCount)")
                            .font(.caption)
                    } icon: {
                        Image(systemName: source.included ? "checkmark.circle" : "minus.circle")
                    }
                    .foregroundColor(source.included ? .textOnBpDim : .signalAmber)
                }

                ForEach(Array(preview.omittedReasons.enumerated()), id: \.offset) { _, reason in
                    Label(reason, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundColor(.signalAmber)
                }

                Button(String(localized: "common.close")) {
                    isReviewingContext = false
                }
                .buttonStyle(.bordered)
            }
            .padding(Spacing.md)
            .background(Color.bpBlueLight.opacity(0.32))
            .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
        }
    }

    private func settingsCard<Content: View>(
        title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Label(title, systemImage: icon)
                .font(.captionMedium)
                .foregroundColor(.textOnBpDim)
            content()
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.bpBlueLight.opacity(0.3))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md)
                .strokeBorder(Color.bpLineGhost.opacity(0.3), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: Radius.md))
    }

    private func requestContextPreview() {
        do {
            _ = try capture.previewContext(notebookId: notebookId)
            isReviewingContext = true
        } catch {
            ToastCenter.shared.error(
                String(localized: "capture.toast.context_preview_failed"),
                detail: error.localizedDescription
            )
        }
    }

    private func loadContextBrowser() {
        isLoadingContextPacks = true
        contextLoadError = nil
        defer { isLoadingContextPacks = false }
        do {
            try capture.loadContextPacks(notebookId: notebookId)
        } catch {
            contextLoadError = error.localizedDescription
            ToastCenter.shared.error(
                String(localized: "capture.toast.context_load_failed"),
                detail: error.localizedDescription
            )
        }
    }

    private var selectedContextPack: NotebookContextPackDTO? {
        guard let id = capture.selectedContextPackId else { return nil }
        return capture.contextPacks.first(where: { $0.id == id })
    }

    private func selectContextPack(_ packId: String) {
        do {
            try capture.selectContextPackForTranscription(packId, notebookId: notebookId)
            editor.update { profile in
                profile.remoteRealtimeEnabled = true
                profile.sendContextToSoniox = true
            }
            isReviewingContext = false
        } catch {
            showContextError(error)
        }
    }

    private func showContextError(_ error: Error) {
        ToastCenter.shared.error(
            String(localized: "capture.toast.context_update_failed"),
            detail: error.localizedDescription
        )
    }

}

// MARK: - Run-derived realtime transcript

enum NotebookTranscriptSessionIsolation {
    static func isActiveElsewhere(
        requestedSessionId: String,
        storeSessionId: String?,
        isCaptureActive: Bool
    ) -> Bool {
        isCaptureActive && storeSessionId != requestedSessionId
    }

    static func visibleUtterances(
        requestedSessionId: String,
        storeSessionId: String?,
        isCaptureActive: Bool,
        utterances: [NotebookCaptureUtteranceDTO]
    ) -> [NotebookCaptureUtteranceDTO] {
        guard isActiveElsewhere(
            requestedSessionId: requestedSessionId,
            storeSessionId: storeSessionId,
            isCaptureActive: isCaptureActive
        ) == false,
        storeSessionId == requestedSessionId
        else { return [] }
        return utterances.filter { $0.sessionId == requestedSessionId }
    }
}

enum NotebookRealtimeTranscriptLayout {
    static let headerHeight: CGFloat = 44
    static let horizontalInset: CGFloat = Spacing.xl
    static let horizontalScrollThreshold = 4
    static let minimumLanguageColumnWidth: CGFloat = 220

    static func usesHorizontalScroll(languageCount: Int) -> Bool {
        languageCount >= horizontalScrollThreshold
    }

    static func minimumContentWidth(languageCount: Int) -> CGFloat {
        CGFloat(max(languageCount, 1)) * minimumLanguageColumnWidth
    }
}

enum NotebookRealtimeProjectionLayout: Equatable {
    case snapshotUnavailable
    case transcriptionTimeline
    case bilingualColumns
}

enum NotebookRealtimeProjectionPolicy {
    /// The run's mode remains immutable processing provenance. The requested
    /// presentation is process-local and may change while recording.
    static func layout(
        presentation: NotebookTranscriptPresentationMode,
        run: NotebookCaptureHistoryRunDTO
    ) -> NotebookRealtimeProjectionLayout {
        guard run.mode != nil else { return .snapshotUnavailable }
        guard presentation == .bilingualColumns else { return .transcriptionTimeline }
        guard let languages = NotebookCaptureHistoryPolicy.displayLanguages(for: run) else {
            return .snapshotUnavailable
        }
        return languages.isEmpty ? .snapshotUnavailable : .bilingualColumns
    }
}

struct NotebookRealtimeAutoscrollSignal: Equatable {
    let utteranceID: String?
    let revision: UInt64
    let textExtent: Int
    let cueGroupEpoch: UInt64
    let cueProviderSequence: UInt64
    let cueRevision: UInt64
    let cueRevisionTotal: UInt64
    let cueCount: Int
    let cueTextExtent: Int
}

enum NotebookRealtimeAutoscrollPolicy {
    /// Row identity stays stable so SwiftUI can update in place. Presentation
    /// progress is a separate signal: a long Soniox utterance can grow hundreds
    /// of times before a new row ID appears.
    static func signal(
        in utterances: [NotebookCaptureUtteranceDTO],
        cues: [NotebookCaptureTranslationCueDTO] = []
    ) -> NotebookRealtimeAutoscrollSignal? {
        let utterance = utterances.last
        let latestCue = cues.max(by: cuePrecedes)
        guard utterance != nil || latestCue != nil else { return nil }
        let sourceTextExtent: Int = utterance?.sourceText.count ?? 0
        let translatedTextExtent: Int = utterance?.translatedText?.count ?? 0
        let variantTextExtent: Int = utterance?.languageVariants.reduce(0) { count, variant in
            count + (variant.text?.count ?? 0)
        } ?? 0
        let textExtent = sourceTextExtent + translatedTextExtent + variantTextExtent
        return NotebookRealtimeAutoscrollSignal(
            utteranceID: utterance?.id,
            revision: utterance?.revision ?? 0,
            textExtent: textExtent,
            cueGroupEpoch: latestCue?.groupEpoch ?? 0,
            cueProviderSequence: latestCue?.providerSequence ?? 0,
            cueRevision: latestCue?.revision ?? 0,
            cueRevisionTotal: cues.reduce(0) { total, cue in
                total &+ cue.groupEpoch &+ cue.providerSequence &+ cue.revision
            },
            cueCount: cues.count,
            cueTextExtent: cues.reduce(0) { $0 + $1.text.count }
        )
    }

    private static func cuePrecedes(
        _ left: NotebookCaptureTranslationCueDTO,
        _ right: NotebookCaptureTranslationCueDTO
    ) -> Bool {
        if left.groupEpoch != right.groupEpoch {
            return left.groupEpoch < right.groupEpoch
        }
        if left.providerSequence != right.providerSequence {
            return left.providerSequence < right.providerSequence
        }
        return left.revision < right.revision
    }
}

enum NotebookRealtimeRunSelectionPolicy {
    static func initialSessionID(
        runs: [NotebookCaptureHistoryRunDTO],
        requestedSessionID: String?,
        activeSessionID: String?
    ) -> String? {
        let sessionIDs = Set(runs.map(\.sessionId))
        if let requestedSessionID, sessionIDs.contains(requestedSessionID) {
            return requestedSessionID
        }
        if let activeSessionID, sessionIDs.contains(activeSessionID) {
            return activeSessionID
        }
        return runs.last?.sessionId
    }

    static func reconciledSessionID(
        currentSessionID: String?,
        runs: [NotebookCaptureHistoryRunDTO],
        requestedSessionID: String?,
        activeSessionID: String?
    ) -> String? {
        let sessionIDs = Set(runs.map(\.sessionId))
        if let currentSessionID, sessionIDs.contains(currentSessionID) {
            return currentSessionID
        }
        return initialSessionID(
            runs: runs,
            requestedSessionID: requestedSessionID,
            activeSessionID: activeSessionID
        )
    }
}

struct NotebookRealtimeScrollMetrics: Equatable {
    let offsetY: Double
    let distanceFromBottom: Double
}

enum NotebookRealtimeFollowPolicy {
    static let liveEdgeDistance = 72.0

    static func reconciledFollowing(
        wasFollowing: Bool,
        previous: NotebookRealtimeScrollMetrics,
        current: NotebookRealtimeScrollMetrics
    ) -> Bool {
        if current.distanceFromBottom <= liveEdgeDistance {
            return true
        }
        if current.offsetY < previous.offsetY - 1 {
            return false
        }
        // Content growth increases distance from the bottom without moving the
        // viewport. Keep following so the throttled tail scroll can catch up.
        return wasFollowing
    }
}

enum NotebookRealtimeRunPresentation {
    private static let fractionalTimestampParser: ISO8601DateFormatter = {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return parser
    }()

    private static let timestampParser: ISO8601DateFormatter = {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime]
        return parser
    }()

    static func createdAtText(for run: NotebookCaptureHistoryRunDTO) -> String {
        guard let date = fractionalTimestampParser.date(from: run.createdAt)
            ?? timestampParser.date(from: run.createdAt) else {
            return run.createdAt
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    static func durationText(for run: NotebookCaptureHistoryRunDTO) -> String {
        guard let durationMs = run.durationMs else {
            return run.capturedFrames == 0 ? "00:00" : "—"
        }
        let totalSeconds = Int(durationMs / 1_000)
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        return hours > 0
            ? String(format: "%02d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
    }
}

/// Bridges the short interval where an auxiliary translation is already a
/// durable time-anchored cue but cannot yet be attached to one canonical row.
/// The subtitle canvas reads those cues directly; without this overlay the
/// Notebook columns can visibly trail even though both surfaces received the
/// same capture event.
enum NotebookLanguageColumnCueOverlay {
    static func latestSupplementalCues(
        languages: [String],
        utterances: [NotebookCaptureUtteranceDTO],
        cues: [NotebookCaptureTranslationCueDTO]
    ) -> [String: NotebookCaptureTranslationCueDTO] {
        var seenLanguages: Set<String> = []
        let languages = languages
            .map(normalizedLanguage)
            .filter { $0.isEmpty == false && seenLanguages.insert($0).inserted }
        var result: [String: NotebookCaptureTranslationCueDTO] = [:]

        for language in languages {
            let representedTexts = utterances
                .compactMap { $0.laneText(language: language) }
                .map(normalizedText)
                .filter { $0.isEmpty == false }
            let matchingCues = cues.filter {
                normalizedLanguage($0.targetLanguage) == language
                    && normalizedLanguage($0.sourceLanguage) != language
                    && $0.withdrawn == false
                    && normalizedText($0.text).isEmpty == false
            }
            guard let latest = matchingCues.max(by: cuePrecedes) else { continue }

            let cueText = normalizedText(latest.text)
            let isAlreadyRepresented = representedTexts.contains { text in
                text == cueText || text.contains(cueText)
            }
            if isAlreadyRepresented == false {
                result[language] = latest
            }
        }
        return result
    }

    private static func cuePrecedes(
        _ left: NotebookCaptureTranslationCueDTO,
        _ right: NotebookCaptureTranslationCueDTO
    ) -> Bool {
        if left.groupEpoch != right.groupEpoch {
            return left.groupEpoch < right.groupEpoch
        }
        if left.providerSequence != right.providerSequence {
            return left.providerSequence < right.providerSequence
        }
        return left.revision < right.revision
    }

    private static func normalizedLanguage(_ language: String) -> String {
        language
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(separator: "-")
            .first
            .map(String.init) ?? ""
    }

    private static func normalizedText(_ text: String) -> String {
        text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()
    }
}

/// A Notebook timeline owns every durable capture run. The rail keeps every run
/// addressable, while only the selected transcript is hydrated and mounted.
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
            Divider().background(Color.bpLineGhost.opacity(0.28))
            historyBody
        }
        .background(Color.bpBlue)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(String(localized: "capture.transcript.realtime_accessibility_label")))
        .onDisappear(perform: cancelLiveFollow)
    }

    private var presentedRuns: [NotebookCaptureHistoryRunDTO] {
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
                        .foregroundColor(.bpLine)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.textOnBpFaint)
                        .opacity(isPresentationControlHovered ? 1 : 0)
                }
                .padding(.horizontal, Spacing.sm)
                .frame(minHeight: 32)
                .background(
                    Color.bpBlueLight.opacity(isPresentationControlHovered ? 0.42 : 0)
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
        if history.isLoading, history.runs.isEmpty {
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
        } else if presentedRuns.isEmpty {
            EmptyState(
                illustration: { Arcanum003WaveformRuler() },
                title: String(localized: "editor.transcript.realtime.empty_title"),
                description: String(localized: "editor.transcript.realtime.empty_desc")
            )
        } else {
            ScrollViewReader { proxy in
                HStack(spacing: 0) {
                    NotebookRealtimeRunNavigator(
                        runs: presentedRuns,
                        selectedSessionID: selectedSessionID,
                        activeSessionID: activeSessionID,
                        onSelect: { sessionID in
                            selectRun(sessionID, using: proxy, animated: true)
                        }
                    )
                    Divider().background(Color.bpLineGhost.opacity(0.24))
                    ScrollView {
                        LazyVStack(spacing: Spacing.lg) {
                            ForEach(presentedRuns) { run in
                                runView(run, using: proxy)
                                    .id(runAnchor(run.sessionId))
                            }
                        }
                        .padding(.horizontal, Spacing.xl)
                        .padding(.vertical, Spacing.lg)
                    }
                    .onScrollGeometryChange(for: NotebookRealtimeScrollMetrics.self) { geometry in
                        let visibleBottom = geometry.contentOffset.y
                            + geometry.containerSize.height
                        let contentBottom = geometry.contentSize.height
                            + geometry.contentInsets.bottom
                        return NotebookRealtimeScrollMetrics(
                            offsetY: Double(geometry.contentOffset.y),
                            distanceFromBottom: Double(max(0, contentBottom - visibleBottom))
                        )
                    } action: { previous, current in
                        reconcileLiveFollowing(previous: previous, current: current)
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
                                .foregroundColor(.bpBlueDeep)
                                .padding(.horizontal, Spacing.md)
                                .frame(minHeight: 30)
                                .background(Color.bpLine)
                                .clipShape(Capsule())
                                .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
                            }
                            .buttonStyle(.plain)
                            .padding(Spacing.lg)
                        }
                    }
                }
                .onAppear {
                    reconcileSelection(using: proxy, animated: false)
                }
                .onChange(of: focusSessionId) { _, sessionID in
                    guard let sessionID else { return }
                    selectRun(sessionID, using: proxy, animated: true)
                }
                .onChange(of: presentedRuns.map(\.sessionId)) { _, _ in
                    reconcileSelection(using: proxy, animated: false)
                }
                .onChange(of: activeSessionID) { _, sessionID in
                    guard let sessionID else { return }
                    selectRun(sessionID, using: proxy, animated: true)
                }
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
        if selectedSessionID != run.sessionId {
            NotebookRealtimeRunSummaryView(run: run) {
                selectRun(run.sessionId, using: proxy, animated: true)
            }
        } else if activeSessionID == run.sessionId
                    || history.transcriptLoadState(sessionId: run.sessionId) == .loaded {
            if run.sessionId == activeSessionID {
                NotebookRealtimeActiveRunView(
                    run: run,
                    presentationMode: presentationMode,
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
        guard let sessionID = NotebookRealtimeRunSelectionPolicy.reconciledSessionID(
            currentSessionID: selectedSessionID,
            runs: presentedRuns,
            requestedSessionID: focusSessionId,
            activeSessionID: activeSessionID
        ) else {
            selectedSessionID = nil
            history.retainOnlyTranscript(sessionId: nil)
            return
        }
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
        guard presentedRuns.contains(where: { $0.sessionId == sessionID }) else { return }
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
            try? await Task.sleep(for: .milliseconds(250))
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

/// Owns the provider-rate observation for the one mounted live run. Keeping
/// this boundary below the history timeline means a speculative preview frame
/// updates live text and follow-at-edge behavior without rebuilding the
/// durable run projection or its navigator.
private struct NotebookRealtimeActiveRunView: View {
    let run: NotebookCaptureHistoryRunDTO
    let presentationMode: NotebookTranscriptPresentationMode
    let history: NotebookCaptureHistoryStore
    private let capture: ActiveBilingualTranscriptStore
    private let liveTailAnchorID: String
    private let onLiveAutoscrollSignal: () -> Void
    @ObservedObject private var livePresentation: NotebookCaptureLivePresentationStore

    init(
        run: NotebookCaptureHistoryRunDTO,
        presentationMode: NotebookTranscriptPresentationMode,
        history: NotebookCaptureHistoryStore,
        capture: ActiveBilingualTranscriptStore,
        liveTailAnchorID: String,
        onLiveAutoscrollSignal: @escaping () -> Void
    ) {
        self.run = run
        self.presentationMode = presentationMode
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
                history: history
            )
            Color.clear
                .frame(height: 1)
                .id(liveTailAnchorID)
        }
        .onChange(of: liveAutoscrollSignal) { _, signal in
            guard signal != nil else { return }
            onLiveAutoscrollSignal()
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

private struct NotebookRealtimeRunNavigator: View {
    let runs: [NotebookCaptureHistoryRunDTO]
    let selectedSessionID: String?
    let activeSessionID: String?
    let onSelect: (String) -> Void

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 2) {
                ForEach(runs) { run in
                    let isSelected = run.sessionId == selectedSessionID
                    let isActive = run.sessionId == activeSessionID
                    Button {
                        onSelect(run.sessionId)
                    } label: {
                        Capsule()
                            .fill(barColor(isSelected: isSelected, isActive: isActive))
                            .frame(
                                width: isSelected ? 26 : (isActive ? 20 : 11),
                                height: isSelected ? 4 : 3
                            )
                            .frame(width: 44, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(helpText(for: run))
                    .accessibilityLabel(Text(helpText(for: run)))
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(.vertical, Spacing.lg)
        }
        .scrollIndicators(.never)
        .frame(width: 52)
        .background(Color.bpBlueDeep.opacity(0.18))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(String(localized: "capture.transcript.run_navigator")))
    }

    private func barColor(isSelected: Bool, isActive: Bool) -> Color {
        if isSelected { return .bpLine }
        if isActive { return .signalGreen }
        return .textOnBpFaint.opacity(0.58)
    }

    private func helpText(for run: NotebookCaptureHistoryRunDTO) -> String {
        "\(NotebookRealtimeRunPresentation.createdAtText(for: run)) · "
            + NotebookRealtimeRunPresentation.durationText(for: run)
    }
}

private struct NotebookRealtimeRunSummaryView: View {
    let run: NotebookCaptureHistoryRunDTO
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: Spacing.lg) {
                VStack(alignment: .leading, spacing: 2) {
                    Label(
                        NotebookRealtimeRunPresentation.createdAtText(for: run),
                        systemImage: "clock"
                    )
                        .font(.captionMedium)
                        .foregroundColor(.bpLine)
                    Text(String(run.sessionId.prefix(12)))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.textOnBpFaint)
                }
                Spacer(minLength: Spacing.md)
                Label(
                    NotebookRealtimeRunPresentation.durationText(for: run),
                    systemImage: run.hasAudio ? "waveform" : "waveform.slash"
                )
                    .font(.caption)
                    .foregroundColor(.textOnBpDim)
                CaptureStateLabel(
                    captureState: run.captureState,
                    remoteHealth: run.remoteHealth,
                    projectionState: run.projectionState,
                    showsRemoteHealthWhenInactive: false
                )
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.textOnBpFaint)
            }
            .padding(.horizontal, Spacing.lg)
            .frame(minHeight: 58)
            .background(Color.bpBlueDeep.opacity(0.2))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.sm)
                    .strokeBorder(Color.bpLineGhost.opacity(0.24), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
            .contentShape(RoundedRectangle(cornerRadius: Radius.sm))
        }
        .buttonStyle(.plain)
        .help(String(localized: "capture.transcript.open_recording"))
        .accessibilityHint(Text(String(localized: "capture.transcript.open_recording")))
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
                    .foregroundColor(.textOnBpDim)
                    .fixedSize(horizontal: false, vertical: true)
                Button(String(localized: "capture.settings.autosave.retry"), action: retry)
                    .buttonStyle(.borderless)
            case .unloaded, .loading, .loaded:
                HStack(spacing: Spacing.sm) {
                    ProgressView().controlSize(.small)
                    Text(String(localized: "capture.transcript.loading_recording"))
                        .font(.caption)
                        .foregroundColor(.textOnBpDim)
                }
            }
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
        .background(Color.bpBlueDeep.opacity(0.2))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.sm)
                .strokeBorder(Color.bpLineGhost.opacity(0.24), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
        .accessibilityLabel(Text(
            "\(NotebookRealtimeRunPresentation.createdAtText(for: run)), "
                + String(localized: "capture.transcript.loading_recording")
        ))
    }
}

/// One durable run section inside the Notebook history. It never queries by
/// session id and never changes the run's frozen processing configuration.
struct NotebookRealtimeUtteranceView: View {
    let run: NotebookCaptureHistoryRunDTO
    /// Already merged once by the active-run boundary. Keeping the complete
    /// array as an input prevents this view's header, empty state, cue overlay,
    /// and row bodies from each rebuilding the full durable+preview session.
    let presentedUtterances: [NotebookCaptureUtteranceDTO]
    let liveTranslationCues: [NotebookCaptureTranslationCueDTO]
    let presentationMode: NotebookTranscriptPresentationMode
    let isFocused: Bool
    @ObservedObject var history: NotebookCaptureHistoryStore
    @State private var laneEditingState = BilingualLaneEditingState()
    @State private var speakerSelection: NotebookSpeakerSelection?

    var body: some View {
        VStack(spacing: 0) {
            runHeader
            Divider().background(Color.bpLineGhost.opacity(0.3))
            switch projectionLayout {
            case .bilingualColumns:
                bilingualLayout
            case .transcriptionTimeline:
                transcriptionOnlyLayout
            case .snapshotUnavailable:
                snapshotUnavailablePlaceholder
            }
        }
        .background(Color.bpBlueDeep.opacity(0.28))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.sm)
                .strokeBorder(
                    isFocused ? Color.brandAccent.opacity(0.72) : Color.bpLineGhost.opacity(0.28),
                    lineWidth: isFocused ? 1 : 0.5
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(String(localized: "capture.transcript.realtime_accessibility_label")))
        .sheet(item: $speakerSelection) { selection in
            NotebookSpeakerEditorSheet(
                sessionId: run.sessionId,
                sessionSpeakerId: selection.id,
                history: history,
                onClose: { speakerSelection = nil }
            )
        }
    }

    private var projectionLayout: NotebookRealtimeProjectionLayout {
        NotebookRealtimeProjectionPolicy.layout(
            presentation: presentationMode,
            run: run
        )
    }

    private var bilingualLayout: some View {
        Group {
            if NotebookRealtimeTranscriptLayout.usesHorizontalScroll(
                languageCount: displayLanguages.count
            ) {
                ScrollView(.horizontal) {
                    languageColumnContent
                        .frame(minWidth: NotebookRealtimeTranscriptLayout.minimumContentWidth(
                            languageCount: displayLanguages.count
                        ))
                }
                .scrollIndicators(.visible)
            } else {
                languageColumnContent
            }
        }
    }

    private var languageColumnContent: some View {
        bilingualBody
    }

    private var transcriptionOnlyLayout: some View {
        VStack(spacing: 0) {
            transcriptionHeader
            Divider().background(Color.bpLineGhost.opacity(0.35))
            transcriptionBody
        }
    }

    private var displayLanguages: [String] {
        NotebookCaptureHistoryPolicy.displayLanguages(for: run) ?? []
    }

    private var supplementalCues: [String: NotebookCaptureTranslationCueDTO] {
        guard run.captureState.isActive else { return [:] }
        return NotebookLanguageColumnCueOverlay.latestSupplementalCues(
            languages: displayLanguages,
            utterances: presentedUtterances,
            cues: liveTranslationCues
        )
    }

    private var hasAnyEditableLane: Bool {
        presentedUtterances.contains { utterance in
            utterance.isLoroEditableLane(
                language: utterance.sourceLanguage,
                appliedRevision: run.realtimeLoroAppliedRevision
            ) || utterance.languageVariants.contains { variant in
                utterance.isLoroEditableLane(
                    language: variant.language,
                    appliedRevision: run.realtimeLoroAppliedRevision
                )
            }
        }
    }

    private var runHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Spacing.md) {
                runIdentity
                Spacer(minLength: Spacing.md)
                runMetadata
                captureStateLabel
                statusActions
            }

            VStack(alignment: .leading, spacing: Spacing.sm) {
                runIdentity
                HStack(spacing: Spacing.md) {
                    runMetadata
                    Spacer(minLength: Spacing.sm)
                    captureStateLabel
                    statusActions
                }
            }
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.sm)
        .frame(minHeight: 52)
    }

    private var runIdentity: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(createdAtText, systemImage: "clock")
                .font(.captionMedium)
                .foregroundColor(.bpLine)
            Text(String(run.sessionId.prefix(12)))
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.textOnBpFaint)
                .textSelection(.enabled)
        }
    }

    private var runMetadata: some View {
        Label(durationText, systemImage: run.hasAudio ? "waveform" : "waveform.slash")
            .font(.caption)
            .foregroundColor(.textOnBpDim)
            .accessibilityLabel(Text(
                "\(String(localized: "session.tab.audio")), \(durationText)"
            ))
    }

    private var snapshotUnavailablePlaceholder: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Label(
                String(localized: "capture.error.profile_snapshot_unavailable"),
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.captionMedium)
            .foregroundColor(.signalAmber)
            Text(String(localized: "capture.transcript.snapshot_unavailable_detail"))
                .font(.caption)
                .foregroundColor(.textOnBpDim)
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var transcriptionHeader: some View {
        Label(
            String(localized: "capture.transcript.transcription_heading"),
            systemImage: "text.alignleft"
        )
        .font(.captionMedium)
        .foregroundColor(.bpLine)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, NotebookRealtimeTranscriptLayout.horizontalInset + Spacing.md)
        .frame(height: NotebookRealtimeTranscriptLayout.headerHeight)
        .accessibilityAddTraits(.isHeader)
    }

    private var captureStateLabel: some View {
        CaptureStateLabel(
            captureState: run.captureState,
            remoteHealth: run.remoteHealth,
            projectionState: run.projectionState,
            showsRemoteHealthWhenInactive: false
        )
    }

    @ViewBuilder
    private var statusActions: some View {
        Button(action: copyTranscript) {
            Label(
                String(localized: "capture.transcript.copy"),
                systemImage: Icon.copy
            )
        }
        .buttonStyle(.borderless)
        .frame(minWidth: 44, minHeight: 44)
        .disabled(canCopyTranscript == false)
        .help(copyTranscriptHint)
        .accessibilityLabel(Text(String(localized: "capture.transcript.copy")))
        .accessibilityHint(Text(copyTranscriptHint))

        if hasAnyEditableLane == false {
            Label(String(localized: "capture.transcript.read_only"), systemImage: "lock.fill")
                .font(.caption)
                .foregroundColor(.textOnBpDim)
        }
        if run.projectionState == .failed, run.captureState.isActive == false {
            Button(String(localized: "capture.transcript.retry_projection")) {
                do {
                    try history.retryProjection(sessionId: run.sessionId)
                } catch {
                    ToastCenter.shared.error(
                        String(localized: "capture.toast.projection_retry_failed"),
                        detail: error.localizedDescription
                    )
                }
            }
            .buttonStyle(.borderless)
            .accessibilityHint(Text(String(localized: "capture.transcript.retry_projection_hint")))
        }
    }

    private var canCopyTranscript: Bool {
        run.utterances.isEmpty == false && laneEditingState.canSwap
    }

    private var copyTranscriptHint: String {
        if run.utterances.isEmpty {
            return String(localized: "capture.transcript.copy_empty_hint")
        }
        if laneEditingState.canSwap == false {
            return String(localized: "capture.transcript.copy_finish_edit_hint")
        }
        return String(localized: "capture.transcript.copy_hint")
    }

    private func copyTranscript() {
        guard canCopyTranscript else { return }
        guard let core = CoreClient.shared.core else {
            ToastCenter.shared.error(
                String(localized: "capture.transcript.copy_failed"),
                detail: String(localized: "capture.route.unavailable_detail")
            )
            return
        }

        do {
            let text = try core.getSessionTranscriptClipboardText(
                sessionId: run.sessionId
            )
            guard TranscriptClipboard.write(text) else {
                ToastCenter.shared.error(
                    String(localized: "capture.transcript.copy_failed"),
                    detail: String(localized: "capture.transcript.copy_clipboard_failed")
                )
                return
            }
            ToastCenter.shared.success(
                String(localized: "capture.transcript.copy_success"),
                detail: run.captureState.isActive
                    ? String(localized: "capture.transcript.copy_success_live_detail")
                    : String(localized: "capture.transcript.copy_success_detail")
            )
        } catch {
            ToastCenter.shared.error(
                String(localized: "capture.transcript.copy_failed"),
                detail: error.localizedDescription
            )
        }
    }

    @ViewBuilder
    private var bilingualBody: some View {
        let supplementalCues = supplementalCues
        if presentedUtterances.isEmpty, supplementalCues.isEmpty {
            compactEmptyRun(
                title: run.captureState.isActive
                    ? String(localized: "capture.transcript.waiting_title")
                    : String(localized: "editor.transcript.realtime.empty_title"),
                description: run.captureState.isActive
                    ? String(localized: "capture.transcript.waiting_detail")
                    : String(localized: "editor.transcript.realtime.empty_desc")
            )
        } else {
            LazyVStack(spacing: 0) {
                ForEach(presentedUtterances) { utterance in
                    MultilingualUtteranceRow(
                        utterance: utterance,
                        projection: NotebookCaptureHistoryPolicy.laneProjection(
                            for: utterance,
                            selectedLanguages: displayLanguages,
                            commonCaptionLanguage: nil
                        ),
                        speakerDisplayName: speakerDisplayName(for: utterance),
                        onManageSpeaker: { selectSpeaker(for: utterance) },
                        realtimeLoroAppliedRevision: run.realtimeLoroAppliedRevision,
                        onReplace: { language, text in
                            try await history.replaceLane(
                                utteranceId: utterance.id,
                                language: language,
                                text: text
                            )
                        },
                        onEditingChanged: { target, focused in
                            updateLaneEditingState(target, focused: focused)
                        }
                    )
                    .id(utterance.id)
                    Divider().background(Color.bpLineGhost.opacity(0.22))
                }
                if supplementalCues.isEmpty == false {
                    NotebookSupplementalCueRow(
                        languages: displayLanguages,
                        cues: supplementalCues
                    )
                    .transition(.opacity)
                    Divider().background(Color.bpLineGhost.opacity(0.22))
                }
            }
            .padding(.horizontal, NotebookRealtimeTranscriptLayout.horizontalInset)
        }
    }

    @ViewBuilder
    private var transcriptionBody: some View {
        let sourceTimelineUtterances = presentedUtterances.filter(\.hasSourceLane)
        if sourceTimelineUtterances.isEmpty {
            compactEmptyRun(
                title: run.captureState.isActive
                    ? String(localized: "capture.transcript.waiting_title")
                    : String(localized: "capture.transcript.transcription_empty_title"),
                description: run.captureState.isActive
                    ? String(localized: "capture.transcript.waiting_detail")
                    : String(localized: "capture.transcript.transcription_empty_detail")
            )
        } else {
            LazyVStack(spacing: 0) {
                ForEach(sourceTimelineUtterances) { utterance in
                    TranscriptionUtteranceRow(
                        utterance: utterance,
                        speakerDisplayName: speakerDisplayName(for: utterance),
                        onManageSpeaker: { selectSpeaker(for: utterance) },
                        isEditable: utterance.isLoroEditableLane(
                            language: utterance.sourceLanguage,
                            appliedRevision: run.realtimeLoroAppliedRevision
                        ),
                        onReplace: { language, text in
                            try await history.replaceLane(
                                utteranceId: utterance.id,
                                language: language,
                                text: text
                            )
                        },
                        onEditingChanged: { target, focused in
                            updateLaneEditingState(target, focused: focused)
                        }
                    )
                    .id(utterance.id)
                    Divider().background(Color.bpLineGhost.opacity(0.22))
                }
            }
            .padding(.horizontal, NotebookRealtimeTranscriptLayout.horizontalInset)
        }
    }

    private func compactEmptyRun(title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            Image(systemName: "waveform.slash")
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(.textOnBpFaint)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(title)
                    .font(.captionMedium)
                    .foregroundColor(.bpLine)
                Text(description)
                    .font(.caption)
                    .foregroundColor(.textOnBpDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var createdAtText: String {
        NotebookRealtimeRunPresentation.createdAtText(for: run)
    }

    private var durationText: String {
        NotebookRealtimeRunPresentation.durationText(for: run)
    }

    private func updateLaneEditingState(
        _ target: BilingualLaneEditTarget,
        focused: Bool
    ) {
        guard laneEditingState.isFocused(target) != focused else { return }
        laneEditingState.setFocused(target, focused: focused)
    }

    private func speakerDisplayName(
        for utterance: NotebookCaptureUtteranceDTO
    ) -> String? {
        history.speakerDisplayName(
            sessionSpeakerId: utterance.sessionSpeakerId,
            sessionId: run.sessionId
        )
    }

    private func selectSpeaker(for utterance: NotebookCaptureUtteranceDTO) {
        guard let sessionSpeakerId = utterance.sessionSpeakerId else { return }
        history.refreshSessionSpeakers(sessionId: run.sessionId)
        speakerSelection = NotebookSpeakerSelection(id: sessionSpeakerId)
    }
}

private struct NotebookSpeakerSelection: Identifiable {
    let id: String
}

private struct NotebookSpeakerChip: View {
    let displayName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(displayName, systemImage: "person.crop.circle")
                .font(.captionMedium)
                .foregroundColor(.bpLine)
                .padding(.horizontal, Spacing.sm)
                .frame(minHeight: 28)
                .background(Color.bpBlueLight.opacity(0.48))
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(Color.bpLineGhost.opacity(0.35), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .contentShape(Capsule())
        .help(String(localized: "capture.speaker.manage"))
        .accessibilityLabel(Text(String(
            format: String(localized: "capture.speaker.chip_accessibility_format"),
            displayName
        )))
        .accessibilityHint(Text(String(localized: "capture.speaker.manage_hint")))
    }
}

private struct NotebookSpeakerEditorSheet: View {
    let sessionId: String
    let sessionSpeakerId: String
    @ObservedObject var history: NotebookCaptureHistoryStore
    let onClose: () -> Void
    @State private var sessionName = ""
    @State private var selectedParticipantId = ""
    @State private var newParticipantName = ""
    @State private var errorMessage: String?

    private var speaker: NotebookSessionSpeakerDTO? {
        history.sessionSpeaker(id: sessionSpeakerId, sessionId: sessionId)
    }

    private var sessionNameIsEmpty: Bool {
        sessionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var newParticipantNameIsEmpty: Bool {
        newParticipantName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(String(localized: "capture.speaker.editor.title"))
                        .font(.title3.weight(.semibold))
                        .foregroundColor(.bpLine)
                    Text(speakerIdentity)
                        .font(.caption.monospaced())
                        .foregroundColor(.textOnBpDim)
                        .textSelection(.enabled)
                }
                Spacer(minLength: Spacing.lg)
                Button(String(localized: "capture.speaker.close")) {
                    onClose()
                }
                .keyboardShortcut(.cancelAction)
            }

            Label(
                String(localized: "capture.speaker.privacy_detail"),
                systemImage: "lock.shield"
            )
            .font(.caption)
            .foregroundColor(.textOnBpDim)
            .fixedSize(horizontal: false, vertical: true)

            Divider()

            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text(String(localized: "capture.speaker.session_name"))
                    .font(.captionMedium)
                    .foregroundColor(.bpLine)
                Text(String(localized: "capture.speaker.session_name_detail"))
                    .font(.caption)
                    .foregroundColor(.textOnBpDim)
                HStack(spacing: Spacing.sm) {
                    TextField(
                        String(localized: "capture.speaker.session_name_placeholder"),
                        text: $sessionName
                    )
                    .textFieldStyle(.roundedBorder)
                    Button(String(localized: "capture.speaker.save")) {
                        saveSessionName()
                    }
                    .disabled(sessionNameIsEmpty)
                    Button(String(localized: "capture.speaker.clear")) {
                        clearSessionName()
                    }
                    .disabled(speaker?.localDisplayName == nil)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text(String(localized: "capture.speaker.participant"))
                    .font(.captionMedium)
                    .foregroundColor(.bpLine)
                Text(String(localized: "capture.speaker.participant_detail"))
                    .font(.caption)
                    .foregroundColor(.textOnBpDim)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: Spacing.sm) {
                    Picker(
                        String(localized: "capture.speaker.participant"),
                        selection: $selectedParticipantId
                    ) {
                        Text(String(localized: "capture.speaker.select_participant")).tag("")
                        ForEach(history.orderedSpeakerParticipants) { participant in
                            Text(participant.displayName).tag(participant.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity)

                    Button(String(localized: "capture.speaker.link")) {
                        linkSelectedParticipant()
                    }
                    .disabled(selectedParticipantId.isEmpty)
                }

                HStack(spacing: Spacing.sm) {
                    TextField(
                        String(localized: "capture.speaker.new_participant_placeholder"),
                        text: $newParticipantName
                    )
                    .textFieldStyle(.roundedBorder)
                    Button(String(localized: "capture.speaker.create_and_link")) {
                        createAndLinkParticipant()
                    }
                    .disabled(newParticipantNameIsEmpty)
                }

                if speaker?.participantId != nil {
                    Button(String(localized: "capture.speaker.unlink")) {
                        unlinkParticipant()
                    }
                    .buttonStyle(.borderless)
                }
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.signalRed)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Spacing.xl)
        .frame(width: 480)
        .background(Color.bpBlue)
        .onAppear {
            history.refreshSpeakerParticipants()
            history.refreshSessionSpeakers(sessionId: sessionId)
            synchronizeDrafts()
        }
    }

    private var speakerIdentity: String {
        guard let speaker else {
            return String(localized: "capture.speaker.fallback")
        }
        return String(
            format: String(localized: "capture.speaker.identity_format"),
            speaker.provider,
            speaker.providerLabel,
            String(speaker.providerSessionEpoch)
        )
    }

    private func synchronizeDrafts() {
        sessionName = speaker?.localDisplayName ?? ""
        selectedParticipantId = speaker?.participantId ?? ""
    }

    private func saveSessionName() {
        perform {
            let updated = try history.renameSessionSpeaker(
                sessionSpeakerId: sessionSpeakerId,
                localDisplayName: sessionName
            )
            sessionName = updated.localDisplayName ?? ""
        }
    }

    private func clearSessionName() {
        perform {
            let updated = try history.renameSessionSpeaker(
                sessionSpeakerId: sessionSpeakerId,
                localDisplayName: nil
            )
            sessionName = updated.localDisplayName ?? ""
        }
    }

    private func linkSelectedParticipant() {
        perform {
            let updated = try history.linkSessionSpeaker(
                sessionSpeakerId: sessionSpeakerId,
                participantId: selectedParticipantId
            )
            selectedParticipantId = updated.participantId ?? ""
        }
    }

    private func createAndLinkParticipant() {
        perform {
            let updated = try history.createParticipantAndLink(
                displayName: newParticipantName,
                sessionSpeakerId: sessionSpeakerId
            )
            newParticipantName = ""
            selectedParticipantId = updated.participantId ?? ""
        }
    }

    private func unlinkParticipant() {
        perform {
            let updated = try history.unlinkSessionSpeaker(
                sessionSpeakerId: sessionSpeakerId
            )
            selectedParticipantId = updated.participantId ?? ""
        }
    }

    private func perform(_ operation: () throws -> Void) {
        do {
            try operation()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Read-only live tail for auxiliary text that is visible in the subtitle
/// timeline but has not acquired a durable row identity yet. It deliberately
/// has no editor affordance: editing before binding would invent an
/// `(utterance, language)` target that does not exist.
private struct NotebookSupplementalCueRow: View {
    let languages: [String]
    let cues: [String: NotebookCaptureTranslationCueDTO]

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(languages.enumerated()), id: \.element) { index, language in
                Group {
                    if let cue = cue(for: language) {
                        Text(cue.text)
                            .font(.bodyMedium)
                            .foregroundColor(.textOnBp)
                            .textSelection(.enabled)
                            .multilineTextAlignment(.leading)
                            .accessibilityLabel(Text(language.uppercased()))
                    } else {
                        Color.clear
                            .accessibilityHidden(true)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 52, alignment: .topLeading)
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.md)

                if index < languages.count - 1 {
                    Divider().background(Color.bpLineGhost.opacity(0.35))
                }
            }
        }
        .background(Color.brandAccent.opacity(0.035))
        .accessibilityElement(children: .contain)
    }

    private func cue(for language: String) -> NotebookCaptureTranslationCueDTO? {
        let key = language
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(separator: "-")
            .first
            .map(String.init) ?? ""
        return cues[key]
    }
}

private struct TranscriptionUtteranceRow: View {
    let utterance: NotebookCaptureUtteranceDTO
    let speakerDisplayName: String?
    let onManageSpeaker: () -> Void
    let isEditable: Bool
    let onReplace: (String, String) async throws -> Void
    let onEditingChanged: (BilingualLaneEditTarget, Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
                if let speakerDisplayName {
                    NotebookSpeakerChip(
                        displayName: speakerDisplayName,
                        action: onManageSpeaker
                    )
                }
                if let timestampText {
                    Label(timestampText, systemImage: "waveform")
                        .accessibilityLabel(Text(String(
                            format: String(localized: "capture.transcript.source_timestamp"),
                            timestampText
                        )))
                }
                Text(sourceLanguageLabel)
            }
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundColor(.textOnBpFaint)

            BilingualLaneText(
                target: BilingualLaneEditTarget(
                    utteranceId: utterance.id,
                    laneLanguage: normalizedSourceLanguage
                ),
                text: utterance.sourceText,
                isEditable: isEditable,
                onCommit: { target, text in
                    try await onReplace(target.laneLanguage, text)
                },
                onEditingChanged: onEditingChanged
            )
            .id(BilingualLaneEditTarget(
                utteranceId: utterance.id,
                laneLanguage: normalizedSourceLanguage
            ))
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.lg)
        .frame(maxWidth: .infinity, minHeight: 80, alignment: .topLeading)
        .accessibilityElement(children: .contain)
    }

    private var normalizedSourceLanguage: String {
        let normalized = utterance.sourceLanguage
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(separator: "-")
            .first
            .map(String.init) ?? ""
        return normalized.isEmpty ? "und" : normalized
    }

    private var sourceLanguageLabel: String {
        if normalizedSourceLanguage == "und" {
            // The live tail's provisional provider language labels the row
            // immediately; the pending placeholder remains only when the
            // provider has not yet sent any language signal.
            if let provisional = utterance.provisionalSourceLanguage?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .split(separator: "-")
                .first
                .map(String.init),
               provisional.isEmpty == false, provisional != "und" {
                return provisional.uppercased()
            }
            return String(localized: "capture.transcript.language_pending")
        }
        return normalizedSourceLanguage.uppercased()
    }

    private var timestampText: String? {
        guard let milliseconds = utterance.sourceStartMs else { return nil }
        let totalSeconds = Int(milliseconds / 1_000)
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        return hours > 0
            ? String(format: "%02d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
    }
}

private struct MultilingualUtteranceRow: View {
    let utterance: NotebookCaptureUtteranceDTO
    let projection: NotebookCaptureLaneProjection
    let speakerDisplayName: String?
    let onManageSpeaker: () -> Void
    let realtimeLoroAppliedRevision: UInt64
    let onReplace: (String, String) async throws -> Void
    let onEditingChanged: (BilingualLaneEditTarget, Bool) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if let speakerDisplayName {
                HStack {
                    NotebookSpeakerChip(
                        displayName: speakerDisplayName,
                        action: onManageSpeaker
                    )
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Spacing.md)
                .padding(.top, Spacing.sm)
            }

            Group {
                if let pendingLanguage = projection.pendingLanguage {
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        if let timestamp = timestampText {
                            Label(timestamp, systemImage: "waveform")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.textOnBpFaint)
                                .accessibilityLabel(Text(String(
                                    format: String(localized: "capture.transcript.source_timestamp"),
                                    timestamp
                                )))
                        }
                        Label(
                            String(localized: "capture.transcript.language_pending"),
                            systemImage: "ellipsis"
                        )
                        .font(.captionMedium)
                        .foregroundColor(.textOnBpDim)
                        if pendingLanguage.isEmpty == false {
                            Text(pendingLanguage)
                                .font(.body)
                                .foregroundColor(.bpLine)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, Spacing.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .contain)
                } else if let unselectedLanguageText = projection.unselectedLanguageText {
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        if let timestamp = timestampText {
                            Label(timestamp, systemImage: "waveform")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.textOnBpFaint)
                                .accessibilityLabel(Text(String(
                                    format: String(localized: "capture.transcript.source_timestamp"),
                                    timestamp
                                )))
                        }
                        Text(String(
                            format: String(localized: "capture.transcript.unselected_language"),
                            normalizedSourceLanguage.uppercased()
                        ))
                            .font(.captionMedium)
                            .foregroundColor(.signalAmber)
                        BilingualLaneText(
                            target: BilingualLaneEditTarget(
                                utteranceId: utterance.id,
                                laneLanguage: normalizedSourceLanguage
                            ),
                            text: unselectedLanguageText,
                            isEditable: utterance.isLoroEditableLane(
                                language: normalizedSourceLanguage,
                                appliedRevision: realtimeLoroAppliedRevision
                            ),
                            onCommit: { target, text in
                                try await onReplace(target.laneLanguage, text)
                            },
                            onEditingChanged: onEditingChanged
                        )
                        .id(BilingualLaneEditTarget(
                            utteranceId: utterance.id,
                            laneLanguage: normalizedSourceLanguage
                        ))
                    }
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, Spacing.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .contain)
                } else {
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(Array(projection.lanes.enumerated()), id: \.element.id) {
                            index,
                            projectedLane in
                            lane(
                                projectedLane,
                                showsSourceTimestamp: utterance.hasSourceLane
                                    && sameLanguage(
                                        utterance.sourceLanguage,
                                        projectedLane.language
                                    )
                            )
                            if index < projection.lanes.count - 1 {
                                Divider().background(Color.bpLineGhost.opacity(0.3))
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func lane(
        _ projectedLane: NotebookCaptureLanguageLane,
        showsSourceTimestamp: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            if showsSourceTimestamp, let timestamp = timestampText {
                Label(timestamp, systemImage: "waveform")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.textOnBpFaint)
                    .accessibilityLabel(Text(String(
                        format: String(localized: "capture.transcript.source_timestamp"),
                        timestamp
                    )))
            }

            BilingualLaneText(
                target: BilingualLaneEditTarget(
                    utteranceId: utterance.id,
                    laneLanguage: projectedLane.language
                ),
                text: projectedLane.text,
                missingLaneState: projectedLane.missingLaneState,
                isEditable: utterance.isLoroEditableLane(
                    language: projectedLane.language,
                    appliedRevision: realtimeLoroAppliedRevision
                ),
                onCommit: { target, text in
                    try await onReplace(target.laneLanguage, text)
                },
                onEditingChanged: onEditingChanged
            )
            .id(BilingualLaneEditTarget(
                utteranceId: utterance.id,
                laneLanguage: projectedLane.language
            ))
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.lg)
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .topLeading)
    }

    private var timestampText: String? {
        guard let milliseconds = utterance.sourceStartMs else { return nil }
        let totalSeconds = Int(milliseconds / 1_000)
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        return hours > 0
            ? String(format: "%02d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
    }

    private var normalizedSourceLanguage: String {
        let normalized = utterance.sourceLanguage
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(separator: "-")
            .first
            .map(String.init) ?? ""
        return normalized.isEmpty ? "und" : normalized
    }

    private func sameLanguage(_ lhs: String, _ rhs: String) -> Bool {
        let left = lhs.lowercased().split(separator: "-").first.map(String.init)
        let right = rhs.lowercased().split(separator: "-").first.map(String.init)
        return left == right
    }
}

struct BilingualLaneEditTarget: Hashable {
    let utteranceId: String
    let laneLanguage: String

    init(utteranceId: String, laneLanguage: String) {
        self.utteranceId = utteranceId
        self.laneLanguage = laneLanguage
            .lowercased()
            .split(separator: "-")
            .first
            .map(String.init) ?? ""
    }
}

struct BilingualLaneDraftCommit: Equatable {
    let target: BilingualLaneEditTarget
    let text: String
}

struct BilingualLaneEditingState {
    private(set) var focusedTargets: Set<BilingualLaneEditTarget> = []

    var canSwap: Bool { focusedTargets.isEmpty }

    func isFocused(_ target: BilingualLaneEditTarget) -> Bool {
        focusedTargets.contains(target)
    }

    mutating func setFocused(_ target: BilingualLaneEditTarget, focused: Bool) {
        if focused {
            focusedTargets.insert(target)
        } else {
            focusedTargets.remove(target)
        }
    }
}

/// Keeps an editor draft bound to an immutable `(utterance, language)` lane.
/// A focused lane blocks display-column swaps. Call sites key the view by this
/// target, so a column swap rebuilds the lane instead of retargeting live state.
struct BilingualLaneDraftBuffer {
    private(set) var target: BilingualLaneEditTarget
    private(set) var baseline: String
    var draft: String

    init(target: BilingualLaneEditTarget, text: String) {
        self.target = target
        baseline = text
        draft = text
    }

    mutating func sync(target: BilingualLaneEditTarget, text: String) {
        self.target = target
        baseline = text
        draft = text
    }

    mutating func syncAuthoritativeTextIfUnedited(
        target: BilingualLaneEditTarget,
        text: String
    ) {
        guard pendingCommit() == nil else { return }
        sync(target: target, text: text)
    }

    func pendingCommit() -> BilingualLaneDraftCommit? {
        guard draft != baseline else { return nil }
        return BilingualLaneDraftCommit(target: target, text: draft)
    }

    mutating func markCommitted(_ text: String) {
        baseline = text
    }
}

private struct BilingualLaneText: View {
    let target: BilingualLaneEditTarget
    let text: String?
    let missingLaneState: NotebookCaptureMissingLaneState
    let isEditable: Bool
    let onCommit: (BilingualLaneEditTarget, String) async throws -> Void
    let onEditingChanged: (BilingualLaneEditTarget, Bool) -> Void
    @State private var buffer: BilingualLaneDraftBuffer
    @State private var isCommitInFlight = false
    @FocusState private var isFocused: Bool

    init(
        target: BilingualLaneEditTarget,
        text: String?,
        missingLaneState: NotebookCaptureMissingLaneState = .unavailable,
        isEditable: Bool,
        onCommit: @escaping (BilingualLaneEditTarget, String) async throws -> Void,
        onEditingChanged: @escaping (BilingualLaneEditTarget, Bool) -> Void
    ) {
        self.target = target
        self.text = text
        self.missingLaneState = missingLaneState
        self.isEditable = isEditable
        self.onCommit = onCommit
        self.onEditingChanged = onEditingChanged
        _buffer = State(initialValue: BilingualLaneDraftBuffer(
            target: target,
            text: text ?? ""
        ))
    }

    var body: some View {
        Group {
            if isEditable, let text {
                TextField("", text: $buffer.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .foregroundColor(.bpLine)
                    // The page owns vertical scrolling. Let a continuous
                    // utterance grow the row instead of hiding its tail in a
                    // ten-line nested editor.
                    .lineLimit(2...)
                    .focused($isFocused)
                    .disabled(isCommitInFlight)
                    .onSubmit { isFocused = false }
                    .onChange(of: isFocused) { wasFocused, focused in
                        scheduleFocusChange(wasFocused: wasFocused, focused: focused)
                    }
                    .accessibilityLabel(Text(String(
                        format: String(localized: "capture.transcript.edit_lane"),
                        target.laneLanguage.uppercased()
                    )))
                    .accessibilityHint(Text(String(localized: "capture.transcript.edit_hint")))
                    .onAppear {
                        // A lane can receive many read-only provider revisions
                        // before projection becomes editable. Seed the editor
                        // from the latest authoritative value on that first
                        // editable appearance without overwriting a user draft.
                        scheduleTextSync(text)
                    }
                    .onChange(of: text) { _, value in
                        scheduleTextSync(value)
                    }
            } else if let text, text.isEmpty == false {
                Text(text)
                    .font(.body)
                    .foregroundColor(.bpLine)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else if missingLaneState == .waiting {
                Label(
                    String(
                        format: String(localized: "capture.transcript.waiting_lane"),
                        target.laneLanguage.uppercased()
                    ),
                    systemImage: "ellipsis"
                )
                .font(.caption)
                .foregroundColor(.textOnBpFaint)
                .frame(minHeight: 28, alignment: .leading)
                .accessibilityLabel(Text(String(
                    format: String(localized: "capture.transcript.waiting_lane"),
                    target.laneLanguage.uppercased()
                )))
            } else if missingLaneState == .failed {
                Label(
                    String(
                        format: String(localized: "capture.transcript.failed_lane"),
                        target.laneLanguage.uppercased()
                    ),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundColor(.signalAmber)
                .frame(minHeight: 28, alignment: .leading)
                .accessibilityLabel(Text(String(
                    format: String(localized: "capture.transcript.failed_lane"),
                    target.laneLanguage.uppercased()
                )))
            } else {
                Text("—")
                    .font(.body)
                    .foregroundColor(.textOnBpFaint)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 32, alignment: .topLeading)
        .onDisappear(perform: scheduleDisappear)
    }

    private func scheduleFocusChange(wasFocused: Bool, focused: Bool) {
        let editTarget = buffer.target
        let request = focused ? nil : buffer.pendingCommit()
        Task { @MainActor in
            await Task.yield()
            guard isFocused == focused else { return }
            if focused {
                onEditingChanged(editTarget, true)
            } else if wasFocused {
                if await commit(request) {
                    onEditingChanged(editTarget, false)
                } else {
                    // Keep the swap barrier active until the edit persists or
                    // this identity leaves the transcript hierarchy.
                    onEditingChanged(editTarget, true)
                    isFocused = true
                }
            }
        }
    }

    private func scheduleTextSync(_ value: String) {
        let syncTarget = target
        Task { @MainActor in
            await Task.yield()
            guard isFocused == false,
                  buffer.target == syncTarget else { return }
            buffer.syncAuthoritativeTextIfUnedited(target: syncTarget, text: value)
        }
    }

    private func scheduleDisappear() {
        guard isFocused else { return }
        let editTarget = buffer.target
        let request = buffer.pendingCommit()
        Task { @MainActor in
            await Task.yield()
            _ = await commit(request)
            onEditingChanged(editTarget, false)
        }
    }

    @discardableResult
    private func commit(_ request: BilingualLaneDraftCommit?) async -> Bool {
        guard let request else { return true }
        guard buffer.target == request.target,
              buffer.pendingCommit() == request else { return true }
        guard isCommitInFlight == false else { return false }
        isCommitInFlight = true
        defer { isCommitInFlight = false }
        do {
            try await onCommit(request.target, request.text)
            if buffer.target == request.target {
                buffer.markCommitted(request.text)
            }
            return true
        } catch {
            ToastCenter.shared.error(
                String(localized: "capture.toast.edit_failed"),
                detail: error.localizedDescription
            )
            return false
        }
    }
}

struct CaptureStateLabel: View {
    let captureState: NotebookCaptureState
    let remoteHealth: NotebookRemoteHealth
    let projectionState: NotebookProjectionState
    var showsRemoteHealthWhenInactive = true

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Label(captureStateText, systemImage: captureStateIcon)
            if captureState.isActive || showsRemoteHealthWhenInactive {
                Text("·").accessibilityHidden(true)
                Label(remoteText, systemImage: remoteIcon)
            }
            if captureState.isActive == false {
                Text("·").accessibilityHidden(true)
                Label(projectionText, systemImage: projectionIcon)
            }
        }
        .font(.captionMedium)
        .foregroundColor(.textOnBpDim)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibilityStatus))
    }

    private var accessibilityStatus: String {
        var parts = [captureStateText]
        if captureState.isActive || showsRemoteHealthWhenInactive {
            parts.append(remoteText)
        }
        if captureState.isActive == false {
            parts.append(projectionText)
        }
        return parts.joined(separator: ", ")
    }

    private var captureStateText: String {
        switch captureState {
        case .recording: return String(localized: "capture.state.recording")
        case .paused: return String(localized: "capture.state.paused")
        case .draining: return String(localized: "capture.state.draining")
        case .completed: return String(localized: "capture.state.completed")
        case .interrupted: return String(localized: "capture.state.interrupted")
        case .failed: return String(localized: "capture.state.failed")
        }
    }

    private var captureStateIcon: String {
        switch captureState {
        case .recording: return "record.circle.fill"
        case .paused: return "pause.circle.fill"
        case .draining: return "hourglass"
        case .completed: return "checkmark.circle.fill"
        case .interrupted: return "bolt.trianglebadge.exclamationmark.fill"
        case .failed: return "xmark.octagon.fill"
        }
    }

    private var remoteText: String {
        switch remoteHealth {
        case .off: return String(localized: "capture.remote.off")
        case .connecting: return String(localized: "capture.remote.connecting")
        case .live: return String(localized: "capture.remote.live")
        case .degraded: return String(localized: "capture.remote.degraded")
        case .unavailable: return String(localized: "capture.remote.unavailable")
        }
    }

    private var remoteIcon: String {
        switch remoteHealth {
        case .off: return "lock.fill"
        case .connecting: return "network"
        case .live: return "network.badge.shield.half.filled"
        case .degraded: return "exclamationmark.icloud.fill"
        case .unavailable: return "icloud.slash.fill"
        }
    }

    private var projectionText: String {
        switch projectionState {
        case .pending: return String(localized: "capture.projection.pending")
        case .projecting: return String(localized: "capture.projection.projecting")
        case .ready: return String(localized: "capture.projection.ready")
        case .failed: return String(localized: "capture.projection.failed")
        }
    }

    private var projectionIcon: String {
        switch projectionState {
        case .pending: return "clock.fill"
        case .projecting: return "arrow.triangle.2.circlepath"
        case .ready: return "pencil.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }
}
