import AppKit
import Combine
import SwiftUI

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
    func prepareForCaptureStart(enableRealtimeIfNeeded: Bool = true) async throws {
        await drainScheduledViewActionsBeforeCaptureStart()
        if enableRealtimeIfNeeded, draft.remoteRealtimeEnabled == false {
            update { $0.remoteRealtimeEnabled = true }
        }
        try validateCaptureStartIsReady()
    }

    /// Home's internal quick-capture profile follows the invitation that
    /// authorizes that one-click entry. An earlier invited recording may have
    /// persisted realtime=true; when the invitation is later disabled or
    /// removed, commit realtime=false before starting so the hidden profile
    /// cannot keep opening an unauthorized remote lane. Notebook profiles do
    /// not use this entry point and retain their normal capture configuration.
    func prepareForHomeQuickCaptureStart(inviteRealtimeAuthorized: Bool) async throws {
        await drainScheduledViewActionsBeforeCaptureStart()
        if draft.remoteRealtimeEnabled != inviteRealtimeAuthorized {
            update { $0.remoteRealtimeEnabled = inviteRealtimeAuthorized }
        }
        try validateCaptureStartIsReady()
    }

    private func drainScheduledViewActionsBeforeCaptureStart() async {
        while let scheduledViewActionDrain {
            await scheduledViewActionDrain.value
        }
    }

    private func validateCaptureStartIsReady() throws {
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
