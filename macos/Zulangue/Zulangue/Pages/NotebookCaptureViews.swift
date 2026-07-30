import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

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
    case contextReviewRequired(String)
}

struct NotebookCaptureProfileStartBlockedError: LocalizedError, Equatable {
    let reason: String

    var errorDescription: String? { reason }
}

enum NotebookCaptureSettingsIntent: Equatable {
    case bindContextPack(notebookId: String, packId: String, isBound: Bool)
    case contextEgressChanged(Bool)
    case persistenceStateChanged(NotebookCaptureSettingsPersistenceState)
    case contextDigestChanged(String?)
}

/// Serializes low-frequency Context UI effects after SwiftUI finishes its
/// current AttributeGraph update. Each queued intent retains its own handler,
/// so rapid toggles cannot be reordered or collapsed onto a stale pack value.
@MainActor
final class NotebookCaptureSettingsIntentQueue {
    private struct PendingIntent {
        let intent: NotebookCaptureSettingsIntent
        let apply: @MainActor @Sendable (NotebookCaptureSettingsIntent) -> Void
    }

    private var pending: [PendingIntent] = []
    private var scheduledDrain: Task<Void, Never>?

    @discardableResult
    func schedule(
        _ intent: NotebookCaptureSettingsIntent,
        apply: @escaping @MainActor @Sendable (NotebookCaptureSettingsIntent) -> Void
    ) -> Task<Void, Never> {
        pending.append(PendingIntent(intent: intent, apply: apply))
        if let scheduledDrain {
            return scheduledDrain
        }

        // Keep the queue alive for this one turn. A setting must still apply
        // if the user toggles it and immediately navigates away.
        let task = Task { @MainActor in
            await Task.yield()
            self.drain()
        }
        scheduledDrain = task
        return task
    }

    private func drain() {
        let intents = pending
        pending.removeAll(keepingCapacity: true)
        scheduledDrain = nil
        for pendingIntent in intents {
            pendingIntent.apply(pendingIntent.intent)
        }
    }
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
    func hasConfirmedContext(notebookId: String) -> Bool
    func revokeContextConfirmation()
    @discardableResult
    func saveProfile(_ candidate: NotebookCaptureProfileDTO) throws -> NotebookCaptureProfileDTO
}

extension NotebookCaptureProfilePersisting {
    func revokeContextConfirmation() {}
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

    fileprivate var revokesContextConfirmation: Bool {
        switch self {
        case .remoteRealtimeEnabled(false), .sendContextToSoniox(false):
            return true
        case .remoteRealtimeEnabled(true), .sendContextToSoniox(true),
             .selectedLanguages, .addLanguage, .removeLanguage, .moveLanguage:
            return false
        }
    }

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
        case .contextReviewRequired:
            return String(localized: "capture.settings.autosave.context_review")
        }
    }

    func load() {
        persistenceState = .loading
        let loaded = persistence.profileForNotebook(notebookId)
        draft = loaded
        guard let loadError = persistence.lastError else {
            persistedProfile = loaded
            persistenceState = postSaveState(for: loaded)
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
        case .loading, .saving, .saved, .contextReviewRequired:
            break
        }
    }

    /// Called only after the user has reviewed and confirmed the exact compiled
    /// Context payload. A prior partial save already persisted the profile, so
    /// the renewed receipt resolves the attention state without another CAS
    /// write; an actually unsaved profile still retries normally.
    func contextReviewConfirmed() {
        switch persistenceState {
        case .contextReviewRequired:
            if persistence.hasConfirmedContext(notebookId: notebookId) {
                persistenceState = .saved
            }
        case .saveFailed:
            persist(draft)
        case .loading, .saving, .saved, .loadFailed:
            break
        }
    }

    /// Context Pack edits invalidate the exact digest independently from the
    /// profile's CAS revision. Keep the visible status fail-closed instead of
    /// implying that a persisted egress toggle is still authorized.
    func contextConsentDidChange() {
        guard persistedProfile != nil,
              draft.sendContextToSoniox,
              persistence.hasConfirmedContext(notebookId: notebookId) == false
        else { return }
        switch persistenceState {
        case .saved:
            persistenceState = .contextReviewRequired(
                NotebookCaptureClientError.contextConfirmationRequired.localizedDescription
            )
        case .loading, .saving, .loadFailed, .saveFailed, .contextReviewRequired:
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
            persistenceState = postSaveState(for: saved)
        } catch {
            let saveMessage = error.localizedDescription
            let refreshed = persistence.profileForNotebook(notebookId)
            if persistence.lastError == nil {
                self.persistedProfile = refreshed
                if Self.sameConfiguration(refreshed, candidate) {
                    // The profile write succeeded, but Context recompilation or
                    // exact-consent verification failed afterwards.
                    draft = refreshed
                    persistenceState = .contextReviewRequired(saveMessage)
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
            if action.revokesContextConfirmation {
                persistence.revokeContextConfirmation()
            }
            update { action.apply(to: &$0) }
        }
    }

    private func postSaveState(
        for profile: NotebookCaptureProfileDTO
    ) -> NotebookCaptureSettingsPersistenceState {
        guard profile.sendContextToSoniox,
              persistence.hasConfirmedContext(notebookId: notebookId) == false
        else { return .saved }
        return .contextReviewRequired(
            NotebookCaptureClientError.contextConfirmationRequired.localizedDescription
        )
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

    private var startButton: some View {
        Button {
            guard isStarting == false,
                  profileEditor.captureStartDisabledReason == nil
            else { return }
            isStarting = true
            Task { @MainActor in
                defer { isStarting = false }
                do {
                    try await profileEditor.prepareForCaptureStart()
                    try await NotebookCaptureStartCoordinator(
                        capture: capture,
                        navigation: MainNavigationStoreV2.shared
                    ).start(notebookId: notebookId)
                } catch {
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
                    try await capture.stop()
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
            history.load(notebookId: notebookId)
        }
        .onChange(of: capture.sessionId) { _, _ in
            guard capture.notebookId == notebookId else { return }
            history.load(notebookId: notebookId)
        }
        .onChange(of: capture.captureState) { _, state in
            guard capture.notebookId == notebookId,
                  state.isActive == false else { return }
            history.load(notebookId: notebookId)
        }
        .onChange(of: activeSessionSpeakerIds) { _, speakerIds in
            guard speakerIds.isEmpty == false,
                  capture.notebookId == notebookId,
                  let sessionId = capture.sessionId else { return }
            history.refreshSessionSpeakers(sessionId: sessionId)
        }
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
    static let maximumSelectedCount = 8

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
            let languageName = locale.localizedString(forLanguageCode: code)
                ?? code.uppercased()
            return (code, "\(languageName) · \(code.uppercased())")
        }
    }
}

private struct NotebookRealtimeCaptureConsole: View {
    let notebookId: String
    @ObservedObject var editor: NotebookCaptureProfileEditorModel
    let onOpenAdvancedSettings: () -> Void
    @ObservedObject private var capture = ActiveBilingualTranscriptStore.shared
    @ObservedObject private var engineStore = NotebookCaptureEnginePresentationStore.shared
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
        .onAppear {
            engineStore.refresh()
        }
    }

    private var activeRunSummary: some View {
        let profile = capture.profile
        return VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(alignment: .top, spacing: Spacing.md) {
                scopeCopy
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

            if presentation == .activeElsewhereSummary {
                Label(
                    String(localized: "capture.toolbar.active_other_notebook"),
                    systemImage: "lock.fill"
                )
                .font(.captionMedium)
                .foregroundColor(.textOnBpDim)
            } else {
                HStack(spacing: Spacing.sm) {
                    summaryChip(
                        activeRemoteStatus(for: profile),
                        systemImage: profile.remoteRealtimeEnabled ? "network" : "lock.fill"
                    )
                    if profile.remoteRealtimeEnabled,
                       profile.selectedLanguages.isEmpty == false {
                        summaryChip(
                            profile.selectedLanguages.map(languageLabel).joined(separator: " · "),
                            systemImage: "character.bubble"
                        )
                    }
                }
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

            if languageSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
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

            HStack(spacing: Spacing.md) {
                Label(engineStore.engine.realtimeSummary, systemImage: "lock.fill")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.textOnBpDim)
                credentialStatusLabel
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
                ScrollView(.horizontal) {
                    HStack(spacing: Spacing.xs) {
                        ForEach(matches, id: \.code) { language in
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
        }
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

    private var credentialStatusLabel: some View {
        Label(credentialStatusTitle, systemImage: credentialStatusIcon)
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

    private var credentialStatusTitle: String {
        switch credentialPresentationState {
        case .savedLoadedUnverified:
            String(localized: "capture.settings.remote.credential.loaded_unverified")
        case .savedInactive:
            String(localized: "capture.settings.remote.credential.saved_inactive")
        case .runtimeOnlyUnverified:
            String(localized: "capture.settings.remote.credential.runtime_only_unverified")
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
        case .contextReviewRequired(let message):
            failureStatus(
                title: String(localized: "capture.settings.autosave.context_review"),
                message: message,
                actionTitle: String(localized: "capture.realtime.controls.review_context"),
                action: onOpenAdvancedSettings
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
    let onOpenRealtimeControls: () -> Void
    @State private var isReviewingContext = false
    @State private var pasteTitle = ""
    @State private var pasteText = ""
    @State private var contextContentKind = "general"
    @State private var libraryTitle = ""
    @State private var packPendingDeletion: NotebookContextPackDTO?
    @State private var sourcePendingDeletion: NotebookContextPackSourceDTO?
    @State private var isLoadingContextPacks = true
    @State private var contextLoadError: String?
    @State private var contextIntentQueue = NotebookCaptureSettingsIntentQueue()

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
                realtimeControlsMovedNotice

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

                VStack(alignment: .leading, spacing: Spacing.lg) {
                    contextBrowserSection
                    postStopRemoteProcessingSection
                }
                .disabled(editor.canEdit == false)
                .opacity(editor.canEdit ? 1 : 0.62)
            }
            .frame(maxWidth: 820, alignment: .leading)
            .padding(Spacing.xl)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.bpBlue)
        .task(id: notebookId) {
            engineStore.refresh()
            if case .contextReviewRequired = editor.persistenceState {
                requestContextPreview()
            }
            loadContextBrowser()
        }
        .onChange(of: editor.persistenceState) { _, state in
            scheduleContextIntent(.persistenceStateChanged(state))
        }
        .onChange(of: capture.contextPreview?.digest) { _, digest in
            scheduleContextIntent(.contextDigestChanged(digest))
        }
        .confirmationDialog(
            String(localized: "capture.settings.context.delete_pack_confirm"),
            isPresented: Binding(
                get: { packPendingDeletion != nil },
                set: { if !$0 { packPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(String(localized: "common.delete"), role: .destructive) {
                deletePendingPack()
            }
            Button(String(localized: "common.cancel"), role: .cancel) {
                packPendingDeletion = nil
            }
        }
        .confirmationDialog(
            String(localized: "capture.settings.context.delete_source_confirm"),
            isPresented: Binding(
                get: { sourcePendingDeletion != nil },
                set: { if !$0 { sourcePendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(String(localized: "common.delete"), role: .destructive) {
                deletePendingSource()
            }
            Button(String(localized: "common.cancel"), role: .cancel) {
                sourcePendingDeletion = nil
            }
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

    private var realtimeControlsMovedNotice: some View {
        Button(action: onOpenRealtimeControls) {
            HStack(spacing: Spacing.md) {
                Image(systemName: "waveform.and.mic")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.brandAccent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "capture.settings.realtime_moved"))
                        .font(.captionMedium)
                        .foregroundColor(.bpLine)
                    Text(String(localized: "capture.settings.realtime_moved_detail"))
                        .font(.caption)
                        .foregroundColor(.textOnBpDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Text(String(localized: "capture.settings.realtime_moved_action"))
                    .font(.captionMedium)
                    .foregroundColor(.brandAccent)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.brandAccent)
            }
            .padding(Spacing.md)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(Color.brandAccent.opacity(0.07))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.sm)
                    .strokeBorder(Color.brandAccent.opacity(0.25), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(String(localized: "capture.settings.realtime_moved")))
        .accessibilityHint(Text(String(localized: "capture.settings.realtime_moved_action")))
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
            VStack(alignment: .trailing, spacing: 3) {
                settingsStatusLabel(
                    String(localized: "capture.settings.autosave.saved"),
                    systemImage: "checkmark.circle.fill",
                    color: .signalGreen
                )
                Text(String(localized: "capture.settings.autosave.detail"))
                    .font(.caption2)
                    .foregroundColor(.textOnBpFaint)
            }
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
        case .contextReviewRequired(let message):
            settingsFailureStatus(
                title: String(localized: "capture.settings.autosave.context_review"),
                message: message,
                actionTitle: String(localized: "capture.settings.context.preview"),
                action: requestContextPreview
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
            icon: "doc.text.magnifyingglass"
        ) {
            Text(String(localized: "capture.settings.context.pack_detail"))
                .font(.caption)
                .foregroundColor(.textOnBpDim)
                .fixedSize(horizontal: false, vertical: true)

            contextPackList

            Divider().background(Color.bpLineGhost.opacity(0.3))
            contextPackEditor
            Divider().background(Color.bpLineGhost.opacity(0.3))

            Toggle(isOn: contextEgressBinding) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(String(localized: "capture.settings.context.send"))
                        .font(.bodyMedium)
                        .foregroundColor(.bpLine)
                    Text(String(localized: "capture.settings.context.send_detail"))
                        .font(.caption)
                        .foregroundColor(.textOnBpDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)

            HStack(spacing: Spacing.sm) {
                Button(String(localized: "capture.settings.context.preview")) {
                    requestContextPreview()
                }
                .buttonStyle(.bordered)

                if let receipt = capture.appliedContextReceipt,
                   receipt.applied,
                   capture.notebookId == notebookId,
                   capture.appliedContextSessionId == capture.sessionId {
                    Label(
                        String(localized: "capture.settings.context.applied"),
                        systemImage: "checkmark.seal.fill"
                    )
                    .font(.captionMedium)
                    .foregroundColor(.signalGreen)
                    .accessibilityLabel(Text(String(localized: "capture.settings.context.applied")))
                } else {
                    Label(
                        String(localized: "capture.settings.context.not_applied"),
                        systemImage: "circle"
                    )
                    .font(.captionMedium)
                    .foregroundColor(.textOnBpDim)
                }
            }

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

    private var contextPackList: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(String(localized: "capture.settings.context.packs"))
                .font(.captionMedium)
                .foregroundColor(.bpLine)

            if capture.contextPacks.isEmpty {
                Label(
                    String(localized: "capture.settings.context.no_packs"),
                    systemImage: "tray"
                )
                .font(.caption)
                .foregroundColor(.textOnBpDim)
            } else {
                ForEach(capture.contextPacks) { pack in
                    contextPackRow(pack)
                }
            }

            TextField(
                String(localized: "capture.settings.context.library_title"),
                text: $libraryTitle
            )
            .textFieldStyle(.roundedBorder)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: Spacing.sm) {
                    libraryPackButtons
                }
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    libraryPackButtons
                }
            }
            .font(.caption)
        }
    }

    @ViewBuilder
    private var libraryPackButtons: some View {
        Button(String(localized: "capture.settings.context.new_library")) {
            createLibraryPack(copyPrivate: false)
        }
        .disabled(trimmedLibraryTitle.isEmpty)

        Button(String(localized: "capture.settings.context.copy_private")) {
            createLibraryPack(copyPrivate: true)
        }
        .disabled(trimmedLibraryTitle.isEmpty)
    }

    private func contextPackRow(_ pack: NotebookContextPackDTO) -> some View {
        HStack(spacing: Spacing.sm) {
            Button {
                selectContextPack(pack.id)
            } label: {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: pack.isPrivate ? "doc.text.fill" : "books.vertical.fill")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(contextPackDisplayTitle(pack))
                            .font(.captionMedium)
                            .lineLimit(1)
                        Text(pack.isPrivate
                             ? String(localized: "capture.settings.context.current_notebook_detail")
                             : String(localized: "capture.settings.context.library_pack"))
                            .font(.system(size: 10))
                            .foregroundColor(.textOnBpFaint)
                    }
                    Spacer()
                    if capture.selectedContextPackId == pack.id {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.brandAccent)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .accessibilityLabel(Text(contextPackDisplayTitle(pack)))
            .accessibilityValue(Text(contextPackAccessibilityValue(pack)))
            .accessibilityHint(Text(String(localized: "capture.settings.context.select_pack_hint")))

            if pack.isPrivate {
                Text(String(localized: "capture.settings.context.always_bound"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.textOnBpFaint)
            } else {
                Toggle("", isOn: Binding(
                    get: { pack.isBound },
                    set: { bound in
                        scheduleContextIntent(.bindContextPack(
                            notebookId: notebookId,
                            packId: pack.id,
                            isBound: bound
                        ))
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel(Text(String(
                    format: String(localized: "capture.settings.context.bind_pack"),
                    pack.title
                )))

                Button(role: .destructive) {
                    packPendingDeletion = pack
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundColor(.signalRed)
                .accessibilityLabel(Text(String(
                    format: String(localized: "capture.settings.context.delete_pack"),
                    pack.title
                )))
            }
        }
        .padding(Spacing.sm)
        .background(capture.selectedContextPackId == pack.id
                    ? Color.brandAccent.opacity(0.09)
                    : Color.bpBlueDeep.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
    }

    @ViewBuilder
    private var contextPackEditor: some View {
        if let pack = selectedContextPack {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                HStack {
                    Text(String(
                        format: String(localized: "capture.settings.context.editing_pack"),
                        contextPackDisplayTitle(pack)
                    ))
                    .font(.captionMedium)
                    .foregroundColor(.bpLine)
                    Spacer()
                    Button(String(localized: "capture.settings.context.import_file")) {
                        chooseContextFile(packId: pack.id)
                    }
                    .buttonStyle(.bordered)
                }

                if capture.contextSources.isEmpty {
                    Text(String(localized: "capture.settings.context.no_sources"))
                        .font(.caption)
                        .foregroundColor(.textOnBpDim)
                } else {
                    ForEach(capture.contextSources) { source in
                        contextSourceRow(source)
                    }
                }

                TextField(
                    String(localized: "capture.settings.context.paste_title"),
                    text: $pasteTitle
                )
                .textFieldStyle(.roundedBorder)

                Picker(String(localized: "capture.settings.context.content_kind"), selection: $contextContentKind) {
                    Text(String(localized: "capture.settings.context.kind_general")).tag("general")
                    Text(String(localized: "capture.settings.context.kind_terms")).tag("terms")
                    Text(String(localized: "capture.settings.context.kind_text")).tag("text")
                }
                .pickerStyle(.segmented)

                TextEditor(text: $pasteText)
                    .font(.system(size: 11, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(Spacing.xs)
                    .frame(minHeight: 84, maxHeight: 140)
                    .background(Color.bpBlueDeep.opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
                    .accessibilityLabel(Text(String(localized: "capture.settings.context.paste_content")))

                HStack {
                    Text(String(localized: "capture.settings.context.import_limits"))
                        .font(.system(size: 10))
                        .foregroundColor(.textOnBpFaint)
                    Spacer()
                    Button(String(localized: "capture.settings.context.add_paste")) {
                        importPastedContext(packId: pack.id)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmedPasteTitle.isEmpty || trimmedPasteText.isEmpty)
                }
            }
        }
    }

    private func contextSourceRow(_ source: NotebookContextPackSourceDTO) -> some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: source.format == "translation_csv"
                  ? "arrow.left.arrow.right.square"
                  : "doc.text")
                .foregroundColor(.textOnBpDim)
            VStack(alignment: .leading, spacing: 2) {
                Text(source.title)
                    .font(.caption)
                    .foregroundColor(.bpLine)
                    .lineLimit(1)
                Text("\(source.contentKind) · \(ByteCountFormatter.string(fromByteCount: Int64(source.plaintextBytes), countStyle: .file))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.textOnBpFaint)
            }
            Spacer()
            if source.trusted == false {
                Label(
                    String(localized: "capture.settings.context.untrusted"),
                    systemImage: "exclamationmark.shield.fill"
                )
                .font(.system(size: 10))
                .foregroundColor(.signalAmber)
            }
            Button(role: .destructive) {
                sourcePendingDeletion = source
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundColor(.signalRed)
            .accessibilityLabel(Text(String(
                format: String(localized: "capture.settings.context.delete_source"),
                source.title
            )))
        }
    }

    private var postStopRemoteProcessingSection: some View {
        settingsCard(
            title: String(localized: "capture.settings.after_stop.title"),
            icon: "waveform.badge.plus"
        ) {
            HStack(alignment: .center, spacing: Spacing.md) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(String(localized: "capture.settings.after_stop.engine"))
                        .font(.caption)
                        .foregroundColor(.textOnBpDim)
                    Text(engineStore.engine.postStopSummary)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.bpLine)
                }
                Spacer(minLength: Spacing.md)
                Label(
                    engineStore.engine.postStopExecutionSummary,
                    systemImage: "arrow.triangle.2.circlepath"
                )
                .font(.caption)
                .foregroundColor(.textOnBpDim)
            }

            Divider().background(Color.bpLineGhost.opacity(0.3))

            Text(String(localized: engineStore.engine.postStopUsesRealtimeRestream == true
                ? "capture.settings.after_stop.detail"
                : "capture.settings.after_stop.unavailable_detail"))
                .font(.caption)
                .foregroundColor(.textOnBpDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func contextPackDisplayTitle(_ pack: NotebookContextPackDTO) -> String {
        pack.isPrivate
            ? String(localized: "capture.settings.context.private_pack")
            : pack.title
    }

    private func contextPackAccessibilityValue(_ pack: NotebookContextPackDTO) -> String {
        let scope = pack.isPrivate
            ? String(localized: "capture.settings.context.private_pack")
            : String(localized: "capture.settings.context.library_pack")
        let selection = capture.selectedContextPackId == pack.id
            ? String(localized: "capture.settings.context.selected")
            : String(localized: "capture.settings.context.not_selected")
        return "\(scope), \(selection)"
    }

    private var contextEgressBinding: Binding<Bool> {
        Binding(
            get: { draft.sendContextToSoniox },
            set: { enabled in
                scheduleContextIntent(.contextEgressChanged(enabled))
            }
        )
    }

    private func scheduleContextIntent(_ intent: NotebookCaptureSettingsIntent) {
        contextIntentQueue.schedule(intent) { intent in
            applyContextIntent(intent)
        }
    }

    private func applyContextIntent(_ intent: NotebookCaptureSettingsIntent) {
        switch intent {
        case .bindContextPack(let intentNotebookId, let packId, let isBound):
            setPack(notebookId: intentNotebookId, packId: packId, bound: isBound)
        case .contextEgressChanged(true):
            requestContextPreview()
        case .contextEgressChanged(false):
            resetContextEgressConsent()
        case .persistenceStateChanged(let state):
            guard editor.persistenceState == state,
                  case .contextReviewRequired = state else { return }
            if capture.contextPreview?.notebookId == notebookId {
                isReviewingContext = true
            } else {
                requestContextPreview()
            }
        case .contextDigestChanged(let digest):
            guard capture.contextPreview?.digest == digest else { return }
            editor.contextConsentDidChange()
        }
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

                Button(String(localized: "capture.settings.context.confirm_exact")) {
                    capture.confirmContextPreview(digest: preview.digest)
                    if draft.remoteRealtimeEnabled, draft.sendContextToSoniox {
                        editor.contextReviewConfirmed()
                    } else {
                        editor.update { profile in
                            profile.remoteRealtimeEnabled = true
                            profile.sendContextToSoniox = true
                        }
                    }
                    if case .saved = editor.persistenceState {
                        isReviewingContext = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(preview.containsSendableContext == false)
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
            editor.contextConsentDidChange()
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

    private var trimmedLibraryTitle: String {
        libraryTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedPasteTitle: String {
        pasteTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedPasteText: String {
        pasteText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func selectContextPack(_ packId: String) {
        do {
            try capture.selectContextPack(packId, notebookId: notebookId)
        } catch {
            showContextError(error)
        }
    }

    private func setPack(notebookId: String, packId: String, bound: Bool) {
        do {
            try capture.setContextPackBound(
                notebookId: notebookId,
                packId: packId,
                isBound: bound
            )
            resetContextEgressConsent()
        } catch {
            showContextError(error)
        }
    }

    private func createLibraryPack(copyPrivate: Bool) {
        let title = trimmedLibraryTitle
        guard title.isEmpty == false else { return }
        do {
            if copyPrivate {
                _ = try capture.copyPrivateContextToLibrary(
                    notebookId: notebookId,
                    title: title
                )
            } else {
                _ = try capture.createLibraryContextPack(title: title, notebookId: notebookId)
            }
            libraryTitle = ""
            resetContextEgressConsent()
        } catch {
            showContextError(error)
        }
    }

    private func importPastedContext(packId: String) {
        do {
            try capture.importContextText(
                notebookId: notebookId,
                packId: packId,
                title: trimmedPasteTitle,
                text: trimmedPasteText,
                contentKind: contextContentKind
            )
            pasteTitle = ""
            pasteText = ""
            resetContextEgressConsent()
        } catch {
            showContextError(error)
        }
    }

    private func chooseContextFile(packId: String) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = ["txt", "md", "csv"].compactMap {
            UTType(filenameExtension: $0)
        }
        panel.message = String(localized: "capture.settings.context.file_picker_message")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try capture.importContextFile(
                notebookId: notebookId,
                packId: packId,
                path: url.path,
                contentKind: contextContentKind
            )
            resetContextEgressConsent()
        } catch {
            showContextError(error)
        }
    }

    private func deletePendingPack() {
        guard let pack = packPendingDeletion else { return }
        defer { packPendingDeletion = nil }
        do {
            try capture.deleteLibraryContextPack(pack: pack, notebookId: notebookId)
            resetContextEgressConsent()
        } catch {
            showContextError(error)
        }
    }

    private func deletePendingSource() {
        guard let source = sourcePendingDeletion else { return }
        defer { sourcePendingDeletion = nil }
        do {
            try capture.deleteContextSource(
                notebookId: notebookId,
                sourceId: source.id,
                packId: source.packId
            )
            resetContextEgressConsent()
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

    private func resetContextEgressConsent() {
        capture.revokeContextConfirmation()
        isReviewingContext = false
        editor.update { $0.sendContextToSoniox = false }
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

enum NotebookRealtimeAutoscrollPolicy {
    /// A Soniox utterance can be revised hundreds of times before its endpoint.
    /// Its stable id is therefore the only progress signal used for scrolling.
    static func targetID(in utterances: [NotebookCaptureUtteranceDTO]) -> String? {
        utterances.last?.id
    }
}

/// A Notebook timeline owns every durable capture run. `focusSessionId` only
/// scrolls/highlights a section; it never narrows the Rust history query.
private struct NotebookRealtimeHistoryView: View {
    let notebookId: String
    let focusSessionId: String?
    @ObservedObject var history: NotebookCaptureHistoryStore
    @ObservedObject private var capture = ActiveBilingualTranscriptStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            presentationControl
            Divider().background(Color.bpLineGhost.opacity(0.28))
            historyBody
        }
        .background(Color.bpBlue)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(String(localized: "capture.transcript.realtime_accessibility_label")))
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
            profile: capture.profile,
            utterances: capture.utterances
        )
    }

    private var presentationMode: NotebookTranscriptPresentationMode {
        history.presentationMode(for: notebookId, runs: presentedRuns)
    }

    private var presentationBinding: Binding<NotebookTranscriptPresentationMode> {
        Binding(
            get: { presentationMode },
            set: { history.setPresentationMode($0, for: notebookId) }
        )
    }

    private var presentationControl: some View {
        NotebookAdaptiveSingleMountLayout(
            horizontalSpacing: Spacing.xl,
            verticalSpacing: Spacing.sm,
            stackedAlignment: .leading
        ) {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "settings.shortcuts.cycle_display"))
                    .font(.captionMedium)
                    .foregroundColor(.bpLine)
                Text(presentationMode == .bilingualColumns
                     ? String(localized: "capture.transcript.presentation.language_columns_detail")
                     : String(localized: "capture.transcript.presentation.timeline_detail"))
                    .font(.system(size: 10))
                    .foregroundColor(.textOnBpFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Picker(String(localized: "settings.shortcuts.cycle_display"), selection: presentationBinding) {
                Text(String(localized: "capture.transcript.presentation.timeline"))
                    .tag(NotebookTranscriptPresentationMode.sourceTimeline)
                Text(String(localized: "capture.transcript.presentation.language_columns"))
                    .tag(NotebookTranscriptPresentationMode.bilingualColumns)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: 340, minHeight: 44)
            .accessibilityHint(Text(
                presentationMode == .bilingualColumns
                    ? String(localized: "capture.transcript.presentation.language_columns_detail")
                    : String(localized: "capture.transcript.presentation.timeline_detail")
            ))
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.sm)
        .background(Color.bpBlueDeep.opacity(0.3))
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
                    handler: { history.load(notebookId: notebookId) }
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
                ScrollView {
                    LazyVStack(spacing: Spacing.lg) {
                        ForEach(presentedRuns) { run in
                            NotebookRealtimeUtteranceView(
                                run: run,
                                presentationMode: presentationMode,
                                isFocused: focusSessionId == run.sessionId,
                                history: history
                            )
                            .id(runAnchor(run.sessionId))
                        }
                    }
                    .padding(.horizontal, Spacing.xl)
                    .padding(.vertical, Spacing.lg)
                }
                .onAppear { scrollToFocus(using: proxy, animated: false) }
                .onChange(of: focusSessionId) { _, _ in
                    scrollToFocus(using: proxy, animated: true)
                }
                .onChange(of: history.runs.map(\.sessionId)) { _, _ in
                    scrollToFocus(using: proxy, animated: false)
                }
                .onChange(of: latestLiveUtteranceID) { _, id in
                    guard capture.notebookId == notebookId,
                          capture.isCaptureActive,
                          let id else { return }
                    if reduceMotion {
                        proxy.scrollTo(id, anchor: .bottom)
                    } else {
                        withAnimation(.easeOut(duration: 0.18)) {
                            proxy.scrollTo(id, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    private var latestLiveUtteranceID: String? {
        guard capture.notebookId == notebookId else { return nil }
        return NotebookRealtimeAutoscrollPolicy.targetID(in: capture.utterances)
    }

    private func runAnchor(_ sessionId: String) -> String {
        "notebook-capture-run:\(sessionId)"
    }

    private func scrollToFocus(using proxy: ScrollViewProxy, animated: Bool) {
        guard let focusSessionId, focusSessionId.isEmpty == false,
              presentedRuns.contains(where: { $0.sessionId == focusSessionId })
        else { return }
        let action = { proxy.scrollTo(runAnchor(focusSessionId), anchor: .top) }
        if animated, reduceMotion == false {
            withAnimation(.easeOut(duration: 0.18), action)
        } else {
            action()
        }
    }
}

/// One durable run section inside the Notebook history. It never queries by
/// session id and never changes the run's frozen processing configuration.
struct NotebookRealtimeUtteranceView: View {
    let run: NotebookCaptureHistoryRunDTO
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
        VStack(spacing: 0) {
            bilingualHeader
            Divider().background(Color.bpLineGhost.opacity(0.35))
            bilingualBody
        }
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

    private var isEditable: Bool {
        run.captureState.isActive == false && run.projectionState == .ready
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

    private var bilingualHeader: some View {
        HStack(spacing: 0) {
            ForEach(Array(displayLanguages.enumerated()), id: \.element) { index, language in
                languageHeading(language)
                if index < displayLanguages.count - 1 {
                    Divider()
                        .background(Color.bpLineGhost.opacity(0.35))
                        .frame(height: 28)
                }
            }
        }
        .padding(.horizontal, NotebookRealtimeTranscriptLayout.horizontalInset)
        .frame(height: NotebookRealtimeTranscriptLayout.headerHeight)
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

    private func languageHeading(_ code: String) -> some View {
        Text(code.uppercased())
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .tracking(0.8)
            .foregroundColor(.bpLine)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Spacing.md)
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

        if isEditable == false {
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
        if run.utterances.isEmpty {
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
                ForEach(run.utterances) { utterance in
                    MultilingualUtteranceRow(
                        utterance: utterance,
                        projection: NotebookCaptureHistoryPolicy.laneProjection(
                            for: utterance,
                            selectedLanguages: displayLanguages,
                            commonCaptionLanguage: nil
                        ),
                        speakerDisplayName: speakerDisplayName(for: utterance),
                        onManageSpeaker: { selectSpeaker(for: utterance) },
                        isEditable: isEditable,
                        onReplace: { language, text in
                            try history.replaceLane(
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

    @ViewBuilder
    private var transcriptionBody: some View {
        if run.utterances.isEmpty {
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
                ForEach(run.utterances) { utterance in
                    TranscriptionUtteranceRow(
                        utterance: utterance,
                        speakerDisplayName: speakerDisplayName(for: utterance),
                        onManageSpeaker: { selectSpeaker(for: utterance) },
                        isEditable: isEditable,
                        onReplace: { language, text in
                            try history.replaceLane(
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
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fractionalDate = parser.date(from: run.createdAt)
        parser.formatOptions = [.withInternetDateTime]
        guard let date = fractionalDate ?? parser.date(from: run.createdAt) else {
            return run.createdAt
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private var durationText: String {
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

private struct TranscriptionUtteranceRow: View {
    let utterance: NotebookCaptureUtteranceDTO
    let speakerDisplayName: String?
    let onManageSpeaker: () -> Void
    let isEditable: Bool
    let onReplace: (String, String) throws -> Void
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
                    try onReplace(target.laneLanguage, text)
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
        normalizedSourceLanguage == "und"
            ? String(localized: "capture.transcript.language_pending")
            : normalizedSourceLanguage.uppercased()
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
    let isEditable: Bool
    let onReplace: (String, String) throws -> Void
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
                            isEditable: isEditable,
                            onCommit: { target, text in
                                try onReplace(target.laneLanguage, text)
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
                                showsSourceTimestamp: sameLanguage(
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
                isEditable: isEditable,
                onCommit: { target, text in
                    try onReplace(target.laneLanguage, text)
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
        draft = text
    }
}

private struct BilingualLaneText: View {
    let target: BilingualLaneEditTarget
    let text: String?
    let missingLaneState: NotebookCaptureMissingLaneState
    let isEditable: Bool
    let onCommit: (BilingualLaneEditTarget, String) throws -> Void
    let onEditingChanged: (BilingualLaneEditTarget, Bool) -> Void
    @State private var buffer: BilingualLaneDraftBuffer
    @FocusState private var isFocused: Bool

    init(
        target: BilingualLaneEditTarget,
        text: String?,
        missingLaneState: NotebookCaptureMissingLaneState = .unavailable,
        isEditable: Bool,
        onCommit: @escaping (BilingualLaneEditTarget, String) throws -> Void,
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
                    .lineLimit(2...10)
                    .focused($isFocused)
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
                if commit(request) {
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
            _ = commit(request)
            onEditingChanged(editTarget, false)
        }
    }

    @discardableResult
    private func commit(_ request: BilingualLaneDraftCommit?) -> Bool {
        guard let request else { return true }
        guard buffer.target == request.target,
              buffer.pendingCommit() == request else { return true }
        do {
            try onCommit(request.target, request.text)
            buffer.markCommitted(request.text)
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
