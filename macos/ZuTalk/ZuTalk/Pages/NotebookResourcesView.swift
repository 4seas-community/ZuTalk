import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

enum NotebookResourceStatus: Equatable {
    /// The resource state could not be read. This must not be rendered as
    /// `.missing`, which would turn a storage failure into a false claim.
    case unknown
    case missing
    case pending
    case ready
    /// A transcript producer exists and completed, but no text was produced.
    case empty
    case failed
    /// The resource existed and was verifiably destroyed — distinct from
    /// `.missing`, which means it was never generated at all.
    case destroyed
}

enum NotebookResourceDestination: Equatable {
    case audio
    case realtimeTranscript
    case asyncTranscript
    case manualNote

    var displayType: NotebookTabDisplayType? {
        switch self {
        case .audio: nil
        case .realtimeTranscript: .realtimeTranscript
        case .asyncTranscript: .asyncTranscript
        case .manualNote: .manualNote
        }
    }
}

struct NotebookResourceItem: Identifiable, Equatable {
    let id: String
    let title: String
    let createdAt: Date
    let durationMs: UInt64
    let sessionType: String
    let rawStatus: String
    let preview: String
    let languagePair: String
    let audio: NotebookResourceStatus
    let audioDestroyedAt: Date?
    let realtimeTranscript: NotebookResourceStatus
    let asyncTranscript: NotebookResourceStatus
    /// 还在录。Core 拒绝删除正在录的 session,删除入口跟着禁用。
    var isRecording: Bool = false
}

enum NotebookTranscriptResourceStatusPolicy {
    nonisolated static func realtime(
        sessionStatus: String,
        availability: SessionTranscriptAvailabilityInfo?
    ) -> NotebookResourceStatus {
        if sessionStatus.lowercased() == "recording" { return .pending }
        guard let availability else { return .unknown }
        if availability.hasRealtimeContent { return .ready }
        if availability.hasRealtimeRun { return .empty }
        return .missing
    }

    nonisolated static func async(
        task: TranscriptionTaskSnapshot?,
        availability: SessionTranscriptAvailabilityInfo?
    ) -> NotebookResourceStatus {
        if let task {
            switch task.tabStatus {
            case .pending, .live:
                return .pending
            case .ready:
                guard let availability else { return .unknown }
                return availability.hasAsyncContent ? .ready : .empty
            case .failed:
                return .failed
            }
        }
        guard let availability else { return .unknown }
        return availability.hasAsyncContent ? .ready : .missing
    }
}

struct NotebookAudioResourceState: Equatable {
    let status: NotebookResourceStatus
    let destroyedAt: Date?
}

/// One audio-state resolver is shared by Topic resources and the dedicated
/// Session Settings resource card. Storage read failures remain `unknown`;
/// they must never be presented as proof that audio was never created.
enum NotebookAudioResourceStatusPolicy {
    nonisolated static func resolve(
        sessionStatus: String,
        hasEncryptedAudio: Bool,
        destructionReport: AudioDestructionReportInfo?
    ) -> NotebookAudioResourceState {
        if isLiveSessionStatus(sessionStatus) {
            return NotebookAudioResourceState(status: .pending, destroyedAt: nil)
        }
        guard let destructionReport else {
            return NotebookAudioResourceState(status: .unknown, destroyedAt: nil)
        }
        let isFullyDestroyed = destructionReport.chunkTotal > 0
            && destructionReport.chunksDeleted == destructionReport.chunkTotal
            && destructionReport.filesRemaining == 0
            && destructionReport.keyDeleted
            && destructionReport.encryptedPathCleared
            && destructionReport.deleteErrors.isEmpty
        if isFullyDestroyed {
            let destroyedAt = destructionReport.destroyedAtMs.map {
                Date(timeIntervalSince1970: TimeInterval($0) / 1_000)
            }
            return NotebookAudioResourceState(status: .destroyed, destroyedAt: destroyedAt)
        }
        let isReady = hasEncryptedAudio
            && destructionReport.filesRemaining > 0
            && destructionReport.keyDeleted == false
            && destructionReport.encryptedPathCleared == false
            && destructionReport.chunksDeleted == 0
            && destructionReport.deleteErrors.isEmpty
        if isReady {
            return NotebookAudioResourceState(status: .ready, destroyedAt: nil)
        }
        let wasNeverGenerated = hasEncryptedAudio == false
            && destructionReport.chunkTotal == 0
            && destructionReport.filesRemaining == 0
            && destructionReport.keyDeleted
            && destructionReport.encryptedPathCleared
            && destructionReport.deleteErrors.isEmpty
        if wasNeverGenerated {
            return NotebookAudioResourceState(status: .missing, destroyedAt: nil)
        }
        // Any other combination is contradictory or partially destroyed. Do
        // not collapse data loss, residue, or a missing key into "not saved".
        return NotebookAudioResourceState(status: .failed, destroyedAt: nil)
    }

    nonisolated static func isLiveSessionStatus(_ status: String) -> Bool {
        switch status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "recording", "paused", "draining": true
        default: false
        }
    }
}

enum NotebookResourceStatusPresentation {
    static func text(_ status: NotebookResourceStatus) -> String {
        switch status {
        case .unknown: String(localized: "resources.status.unknown")
        case .missing: String(localized: "resources.status.missing")
        case .pending: String(localized: "resources.status.pending")
        case .ready: String(localized: "resources.status.ready")
        case .empty: String(localized: "resources.status.empty")
        case .failed: String(localized: "resources.status.failed")
        case .destroyed: String(localized: "resources.status.destroyed")
        }
    }

    static func color(_ status: NotebookResourceStatus) -> Color {
        switch status {
        case .unknown, .pending: .signalAmber
        case .missing, .empty: .textTertiary
        case .ready: .signalGreen
        case .failed: .signalRed
        case .destroyed: .textSecondary
        }
    }
}

private enum NotebookResourceLoadOutcome: @unchecked Sendable {
    case success([NotebookResourceItem])
    case failure(String)
}

private enum TopicAudioImportOutcome: @unchecked Sendable {
    case success(ImportResultInfo)
    case failure(String)
}

struct TopicResearchBundleResult: Equatable, Sendable {
    let text: String
    let copiedCount: Int
    let omittedCount: Int
}

private enum TopicResearchBundleOutcome: @unchecked Sendable {
    case success(text: String, copiedCount: Int, omittedCount: Int)
    case failure(String)
}

@MainActor
final class NotebookResourcesViewModel: ObservableObject {
    @Published private(set) var items: [NotebookResourceItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var loadError: String?
    @Published private(set) var isImportingAudio = false
    @Published private(set) var isPreparingResearchBundle = false
    private var loadGeneration: UInt = 0
    private var pendingLoadRequest: (
        notebookId: String,
        core: any ZuTalkCoreProtocol
    )?

    func load(notebookId: String, core: (any ZuTalkCoreProtocol)? = nil) {
        guard let core = core ?? CoreClient.shared.core else {
            loadError = String(localized: "resources.load_failed")
            return
        }
        if isLoading {
            // Coalesce notifications received while a snapshot is being
            // assembled. Keep the latest Topic too, because SwiftUI may reuse
            // this view model while navigation changes the Topic route.
            pendingLoadRequest = (notebookId, core)
            return
        }

        loadGeneration &+= 1
        let generation = loadGeneration
        isLoading = true
        Task { @MainActor [weak self, core] in
            let outcome = await Task.detached(priority: .userInitiated) {
                do {
                    return NotebookResourceLoadOutcome.success(
                        try Self.makeItems(notebookId: notebookId, core: core)
                    )
                } catch {
                    return NotebookResourceLoadOutcome.failure(String(describing: error))
                }
            }.value

            guard let self, self.loadGeneration == generation else { return }
            self.isLoading = false
            switch outcome {
            case .success(let loadedItems):
                self.items = loadedItems
                self.loadError = nil
            case .failure:
                // Preserve the last coherent snapshot during a refresh error.
                self.loadError = String(localized: "resources.load_failed")
            }
            if let pending = self.pendingLoadRequest {
                self.pendingLoadRequest = nil
                self.load(notebookId: pending.notebookId, core: pending.core)
            }
        }
    }

    nonisolated private static func makeItems(
        notebookId: String,
        core: any ZuTalkCoreProtocol
    ) throws -> [NotebookResourceItem] {
        let links = try core.listNotebookSessions(notebookId: notebookId)
        // Membership is authoritative and getSession has no catalogue page
        // limit, so a Topic with more than 500 Sessions remains complete.
        let sessions = try links.map { try core.getSession(id: $0.sessionId) }
        let transcriptionTasks: [String: TranscriptionTaskSnapshot]?
        if let tasks = try? core.listTasks(statusFilter: nil) {
            transcriptionTasks = TranscriptionTaskIndex.makeIndex(tasks: tasks)
        } else {
            transcriptionTasks = nil
        }

        return sessions.map { session in
                makeItem(
                    session: session,
                    transcriptionTask: transcriptionTasks?[session.id],
                    transcriptionTaskReadFailed: transcriptionTasks == nil,
                    core: core
                )
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    nonisolated static func makeItem(
        sessionId: String,
        core: any ZuTalkCoreProtocol
    ) throws -> NotebookResourceItem {
        let session = try core.getSession(id: sessionId)
        let transcriptionTasks: [String: TranscriptionTaskSnapshot]?
        if let tasks = try? core.listTasks(statusFilter: nil) {
            transcriptionTasks = TranscriptionTaskIndex.makeIndex(tasks: tasks)
        } else {
            transcriptionTasks = nil
        }
        return makeItem(
            session: session,
            transcriptionTask: transcriptionTasks?[session.id],
            transcriptionTaskReadFailed: transcriptionTasks == nil,
            core: core
        )
    }

    nonisolated private static func makeItem(
        session: SessionInfo,
        transcriptionTask: TranscriptionTaskSnapshot?,
        transcriptionTaskReadFailed: Bool,
        core: any ZuTalkCoreProtocol
    ) -> NotebookResourceItem {
        let availability = try? core.getSessionTranscriptAvailability(sessionId: session.id)
        let realtimeStatus = NotebookTranscriptResourceStatusPolicy.realtime(
            sessionStatus: session.status,
            availability: availability
        )
        let asyncStatus: NotebookResourceStatus
        if transcriptionTaskReadFailed {
            asyncStatus = availability?.hasAsyncContent == true ? .ready : .unknown
        } else {
            asyncStatus = NotebookTranscriptResourceStatusPolicy.async(
                task: transcriptionTask,
                availability: availability
            )
        }
        let destructionReport = NotebookAudioResourceStatusPolicy.isLiveSessionStatus(
            session.status
        ) ? nil : try? core.getAudioDestructionReport(sessionId: session.id)
        let audioState = NotebookAudioResourceStatusPolicy.resolve(
            sessionStatus: session.status,
            hasEncryptedAudio: session.hasEncryptedAudio,
            destructionReport: destructionReport
        )

        return NotebookResourceItem(
            id: session.id,
            title: session.title,
            createdAt: Date(
                timeIntervalSince1970: TimeInterval(session.createdAtUnixMs) / 1_000
            ),
            durationMs: session.durationMs,
            sessionType: session.sessionType,
            rawStatus: session.status,
            preview: session.preview,
            languagePair: languagePair(
                source: session.sourceLanguage,
                targets: session.targetLanguages
            ),
            audio: audioState.status,
            audioDestroyedAt: audioState.destroyedAt,
            realtimeTranscript: realtimeStatus,
            asyncTranscript: asyncStatus,
            isRecording: NotebookAudioResourceStatusPolicy.isLiveSessionStatus(session.status)
        )
    }

    nonisolated private static func languagePair(
        source: String,
        targets: [String]
    ) -> String {
        let normalizedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTargets = targets.filter {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
        if normalizedSource.isEmpty { return normalizedTargets.joined(separator: " · ") }
        if normalizedTargets.isEmpty { return normalizedSource.uppercased() }
        return "\(normalizedSource.uppercased()) → \(normalizedTargets.map { $0.uppercased() }.joined(separator: " · "))"
    }

    func importAudio(
        at url: URL,
        notebookId: String,
        core: (any ZuTalkCoreProtocol)? = nil
    ) {
        guard isImportingAudio == false,
              let core = core ?? CoreClient.shared.core else { return }
        isImportingAudio = true
        Task { @MainActor [weak self, core] in
            let outcome = await Task.detached(priority: .userInitiated) {
                do {
                    return TopicAudioImportOutcome.success(
                        try core.importAudioIntoNotebook(
                            path: url.path,
                            notebookId: notebookId
                        )
                    )
                } catch {
                    return TopicAudioImportOutcome.failure(String(describing: error))
                }
            }.value
            guard let self else { return }
            self.isImportingAudio = false
            switch outcome {
            case .success(let result):
                NotificationCenter.default.post(
                    name: .zutalkSessionUpdated,
                    object: result.sessionId
                )
                ToastCenter.shared.success(
                    String(localized: "home.import.completed"),
                    detail: url.lastPathComponent
                )
                MainNavigationStore.shared.openSession(result.sessionId)
            case .failure:
                ToastCenter.shared.error(
                    String(localized: "home.import.failed"),
                    detail: String(localized: "home.import.failed.detail")
                )
            }
        }
    }

    func copyResearchBundle(
        sessionIds: Set<String>,
        core: (any ZuTalkCoreProtocol)? = nil
    ) {
        guard sessionIds.isEmpty == false,
              isPreparingResearchBundle == false,
              let core = core ?? CoreClient.shared.core else { return }
        let selectedItems = items
            .filter { sessionIds.contains($0.id) }
            .sorted { $0.createdAt < $1.createdAt }
        let recordedLabel = String(localized: "topic.research.bundle.recorded")
        let sourceSessionLabel = String(localized: "topic.research.bundle.source_session")
        let omittedHeading = String(localized: "topic.research.bundle.omitted")
        let noTranscriptLabel = String(localized: "topic.research.bundle.no_transcript")
        isPreparingResearchBundle = true
        Task { @MainActor [weak self, core] in
            let outcome = await Task.detached(priority: .userInitiated) {
                guard let result = Self.composeResearchBundle(
                    selectedItems: selectedItems,
                    recordedLabel: recordedLabel,
                    sourceSessionLabel: sourceSessionLabel,
                    omittedHeading: omittedHeading,
                    noTranscriptLabel: noTranscriptLabel,
                    transcriptForSession: { sessionId in
                        try core.getSessionTranscriptClipboardText(sessionId: sessionId)
                    }
                ) else {
                    return TopicResearchBundleOutcome.failure("no selected transcript content")
                }
                return TopicResearchBundleOutcome.success(
                    text: result.text,
                    copiedCount: result.copiedCount,
                    omittedCount: result.omittedCount
                )
            }.value
            guard let self else { return }
            self.isPreparingResearchBundle = false
            switch outcome {
            case .success(let text, let copiedCount, let omittedCount):
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                if omittedCount > 0 {
                    ToastCenter.shared.warning(
                        String(localized: "topic.research.copy.partial"),
                        detail: String(
                            format: String(localized: "topic.research.copy.partial_detail"),
                            Int64(copiedCount),
                            Int64(omittedCount)
                        )
                    )
                } else {
                    ToastCenter.shared.success(
                        String(localized: "topic.research.copy.done"),
                        detail: String(
                            format: String(localized: "topic.research.copy.done_detail"),
                            Int64(copiedCount)
                        )
                    )
                }
            case .failure:
                ToastCenter.shared.error(String(localized: "topic.research.copy.failed"))
            }
        }
    }

    nonisolated static func composeResearchBundle(
        selectedItems: [NotebookResourceItem],
        recordedLabel: String,
        sourceSessionLabel: String,
        omittedHeading: String,
        noTranscriptLabel: String,
        transcriptForSession: (String) throws -> String
    ) -> TopicResearchBundleResult? {
        var sections: [String] = []
        var omittedSessionIds: [String] = []
        for item in selectedItems {
            do {
                let transcript = try transcriptForSession(item.id)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard transcript.isEmpty == false else {
                    omittedSessionIds.append(item.id)
                    continue
                }
                let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let heading = title.isEmpty
                    ? item.createdAt.formatted(date: .abbreviated, time: .shortened)
                    : title
                sections.append(
                    "## \(heading)\n"
                        + "\(recordedLabel): \(item.createdAt.formatted(date: .numeric, time: .shortened))\n"
                        + "\(sourceSessionLabel): \(item.id)\n\n"
                        + transcript
                )
            } catch {
                omittedSessionIds.append(item.id)
            }
        }
        guard sections.isEmpty == false else { return nil }
        if omittedSessionIds.isEmpty == false {
            let omittedLines = omittedSessionIds.map {
                "- \(sourceSessionLabel): \($0) — \(noTranscriptLabel)"
            }
            sections.append("## \(omittedHeading)\n\n" + omittedLines.joined(separator: "\n"))
        }
        return TopicResearchBundleResult(
            text: sections.joined(separator: "\n\n---\n\n"),
            copiedCount: selectedItems.count - omittedSessionIds.count,
            omittedCount: omittedSessionIds.count
        )
    }

    func destroyAudio(sessionId: String, core: (any ZuTalkCoreProtocol)? = nil) -> Bool {
        guard let core = core ?? CoreClient.shared.core else { return false }
        do {
            try core.destroySessionAudioAndKey(sessionId: sessionId)
            NotificationCenter.default.post(name: .zutalkSessionUpdated, object: nil)
            return true
        } catch {
            return false
        }
    }

    /// Recompute the destruction receipt from the ledger, the filesystem, and
    /// the key store right now. Read-only: verification never mutates state.
    func verifyAudioDestruction(
        sessionId: String,
        core: (any ZuTalkCoreProtocol)? = nil
    ) -> AudioDestructionReportInfo? {
        guard let core = core ?? CoreClient.shared.core else { return nil }
        return try? core.getAudioDestructionReport(sessionId: sessionId)
    }

    func moveToTrash(sessionId: String, core: (any ZuTalkCoreProtocol)? = nil) -> Bool {
        guard let core = core ?? CoreClient.shared.core else { return false }
        do {
            try core.softDeleteSession(sessionId: sessionId)
            items.removeAll { $0.id == sessionId }
            NotificationCenter.default.post(name: .zutalkSessionUpdated, object: nil)
            return true
        } catch {
            return false
        }
    }

    /// The notebooks a recording could move to — every live notebook except
    /// the one it is already in.
    func moveDestinations(
        excluding notebookId: String,
        core: (any ZuTalkCoreProtocol)? = nil
    ) -> [FfiNotebook] {
        guard let core = core ?? CoreClient.shared.core else { return [] }
        let notebooks = (try? core.listNotebooks()) ?? []
        return notebooks.filter { $0.deletedAt == nil && $0.id != notebookId }
    }

    /// Moves a recording and everything it owns into another notebook. The core
    /// refuses this while the session is being captured or permanently deleted,
    /// so the error is surfaced rather than swallowed.
    func moveToNotebook(
        sessionId: String,
        targetNotebookId: String,
        core: (any ZuTalkCoreProtocol)? = nil
    ) -> String? {
        guard let core = core ?? CoreClient.shared.core else {
            return String(localized: "resources.move.failed")
        }
        do {
            try core.moveSessionToNotebook(
                sessionId: sessionId,
                targetNotebookId: targetNotebookId
            )
            items.removeAll { $0.id == sessionId }
            NotificationCenter.default.post(name: .zutalkSessionUpdated, object: nil)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

private enum SessionResourceLoadOutcome: @unchecked Sendable {
    case success(NotebookResourceItem)
    case failure(String)
}

private enum SessionAudioDestroyOutcome: @unchecked Sendable {
    case success(AudioDestructionReportInfo?)
    case failure(String)
}

/// Session Settings needs one authoritative resource snapshot without loading
/// or rendering every sibling Session in its Topic.
@MainActor
final class SessionResourcesViewModel: ObservableObject {
    @Published private(set) var item: NotebookResourceItem?
    @Published private(set) var isLoading = false
    @Published private(set) var isDestroyingAudio = false
    @Published private(set) var loadError: String?

    private var loadGeneration: UInt = 0

    func load(sessionId: String, core: (any ZuTalkCoreProtocol)? = nil) {
        guard let core = core ?? CoreClient.shared.core else {
            loadError = String(localized: "resources.load_failed")
            return
        }
        loadGeneration &+= 1
        let generation = loadGeneration
        isLoading = true

        Task { @MainActor [weak self, core] in
            let outcome = await Task.detached(priority: .userInitiated) {
                do {
                    return SessionResourceLoadOutcome.success(
                        try NotebookResourcesViewModel.makeItem(
                            sessionId: sessionId,
                            core: core
                        )
                    )
                } catch {
                    return SessionResourceLoadOutcome.failure(error.localizedDescription)
                }
            }.value

            guard let self, self.loadGeneration == generation else { return }
            self.isLoading = false
            switch outcome {
            case .success(let item):
                self.item = item
                self.loadError = nil
            case .failure(let detail):
                self.loadError = detail
            }
        }
    }

    /// Destroys only encrypted audio and its key. The Session, transcripts,
    /// Session note, and immutable settings snapshot remain untouched.
    func destroyAudio(
        sessionId: String,
        core: (any ZuTalkCoreProtocol)? = nil
    ) async -> String? {
        guard isDestroyingAudio == false else { return nil }
        guard item?.isRecording != true else {
            return String(localized: "resources.audio.destroy.while_recording")
        }
        guard item?.asyncTranscript != .pending else {
            return String(localized: "resources.audio.destroy.while_processing")
        }
        guard let core = core ?? CoreClient.shared.core else {
            return String(localized: "resources.audio.destroy.failed")
        }

        isDestroyingAudio = true
        defer { isDestroyingAudio = false }
        let outcome = await Task.detached(priority: .userInitiated) {
            do {
                try core.destroySessionAudioAndKey(sessionId: sessionId)
                // Refresh reads are deliberately non-authoritative for the
                // mutation result. The Core method already verifies the full
                // storage postcondition before returning success.
                return SessionAudioDestroyOutcome.success(
                    try? core.getAudioDestructionReport(sessionId: sessionId)
                )
            } catch {
                return SessionAudioDestroyOutcome.failure(error.localizedDescription)
            }
        }.value

        switch outcome {
        case .success(let report):
            loadGeneration &+= 1
            if let current = item {
                self.item = NotebookResourceItem(
                    id: current.id,
                    title: current.title,
                    createdAt: current.createdAt,
                    durationMs: current.durationMs,
                    sessionType: current.sessionType,
                    rawStatus: current.rawStatus,
                    preview: current.preview,
                    languagePair: current.languagePair,
                    audio: .destroyed,
                    audioDestroyedAt: report?.destroyedAtMs.map {
                        Date(timeIntervalSince1970: TimeInterval($0) / 1_000)
                    } ?? Date(),
                    realtimeTranscript: current.realtimeTranscript,
                    asyncTranscript: current.asyncTranscript,
                    isRecording: false
                )
            }
            loadError = nil
            NotificationCenter.default.post(name: .zutalkSessionUpdated, object: nil)
            return nil
        case .failure(let detail):
            return detail
        }
    }
}

/// Expanded, Session-scoped equivalent of the Topic resource disclosure. It
/// intentionally lives at the top of Session Settings so the user sees what
/// exists before changing defaults for a future recording.
struct SessionResourceSettingsView: View {
    let sessionId: String
    let sessionTitle: String
    let onOpen: (NotebookResourceDestination) -> Void

    @StateObject private var viewModel = SessionResourcesViewModel()
    @ObservedObject private var capture = ActiveBilingualTranscriptStore.shared
    @State private var isConfirmingAudioDestroy = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: 3) {
                Text(String(localized: "session.settings.resources.title"))
                    .font(.headline)
                    .foregroundColor(.textPrimary)
                Text(String(localized: "session.settings.resources.subtitle"))
                    .font(.caption)
                    .foregroundColor(.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            resourceContent
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.top, Spacing.xl)
        .padding(.bottom, Spacing.lg)
        .frame(maxWidth: 860, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .top)
        .task(id: sessionId) {
            viewModel.load(sessionId: sessionId)
        }
        .onReceive(NotificationCenter.default.publisher(for: .zutalkSessionUpdated)) { _ in
            guard viewModel.isDestroyingAudio == false else { return }
            viewModel.load(sessionId: sessionId)
        }
        .confirmationDialog(
            String(
                format: String(localized: "resources.audio.destroy.confirm_title"),
                displayTitle
            ),
            isPresented: $isConfirmingAudioDestroy,
            titleVisibility: .visible
        ) {
            Button(String(localized: "resources.audio.destroy.confirm_button"), role: .destructive) {
                destroyAudio()
            }
            Button(String(localized: "common.cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "resources.audio.destroy.confirm_message"))
        }
        .accessibilityIdentifier("session.settings.resources.\(sessionId)")
    }

    @ViewBuilder
    private var resourceContent: some View {
        if viewModel.isLoading, viewModel.item == nil {
            HStack(spacing: Spacing.sm) {
                ProgressView().controlSize(.small)
                Text(String(localized: "editor.transcript.async.status.loading"))
                    .font(.bodySM)
                    .foregroundColor(.textSecondary)
            }
            .frame(maxWidth: .infinity, minHeight: 92)
            .resourceCardStyle()
        } else if let item = viewModel.item {
            VStack(spacing: Spacing.xs) {
                resourceRow(
                    title: String(localized: "resources.audio"),
                    icon: "waveform",
                    status: item.audio,
                    detail: audioDetail(item),
                    onOpen: item.audio == .ready ? { onOpen(.audio) } : nil
                ) {
                    if item.audio == .ready {
                        if viewModel.isDestroyingAudio {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 28, height: 28)
                                .accessibilityLabel(
                                    Text(String(localized: "resources.audio.destroy"))
                                )
                        } else {
                            Button {
                                if isAudioDeletionBlocked {
                                    ToastCenter.shared.info(
                                        audioDeletionBlockMessage
                                            ?? String(localized: "resources.audio.destroy.failed")
                                    )
                                } else {
                                    isConfirmingAudioDestroy = true
                                }
                            } label: {
                                Image(systemName: isAudioDeletionBlocked ? "lock" : "trash")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(
                                        isAudioDeletionBlocked ? .textTertiary : .signalRed
                                    )
                            }
                            .buttonStyle(.plain)
                            .frame(width: 28, height: 28)
                            .help(audioDeletionBlockMessage
                                ?? String(localized: "resources.audio.destroy"))
                            .accessibilityLabel(String(localized: "resources.audio.destroy"))
                            .accessibilityIdentifier(
                                "session.settings.audio.destroy.\(sessionId)"
                            )
                        }
                    }
                }

                resourceRow(
                    title: String(localized: "resources.realtime"),
                    icon: "captions.bubble",
                    status: item.realtimeTranscript,
                    onOpen: { onOpen(.realtimeTranscript) }
                )

                resourceRow(
                    title: String(localized: "resources.async"),
                    icon: "text.document",
                    status: item.asyncTranscript,
                    onOpen: { onOpen(.asyncTranscript) }
                )

                resourceRow(
                    title: String(localized: "resources.note"),
                    icon: "square.and.pencil",
                    // `.ready` means the stable Session-note editor is
                    // available, not that the note already contains text.
                    // There is intentionally no mutating "open to inspect"
                    // read here because opening materializes an empty document.
                    status: .ready,
                    detail: String(localized: "session.settings.resources.note.detail"),
                    onOpen: { onOpen(.manualNote) }
                )

                if isAudioDeletionBlocked {
                    Label(
                        audioDeletionBlockMessage
                            ?? String(localized: "resources.audio.destroy.failed"),
                        systemImage: "lock.fill"
                    )
                    .font(.caption)
                    .foregroundColor(.signalAmber)
                    .padding(.horizontal, Spacing.md)
                    .padding(.top, Spacing.xs)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(Spacing.sm)
            .resourceCardStyle()
        } else {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Label(
                    String(localized: "resources.load_failed"),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.bodyMedium)
                .foregroundColor(.signalAmber)
                if let detail = viewModel.loadError {
                    Text(detail)
                        .font(.caption)
                        .foregroundColor(.textSecondary)
                        .textSelection(.enabled)
                }
                Button(String(localized: "session.settings.retry")) {
                    viewModel.load(sessionId: sessionId)
                }
                .buttonStyle(.bordered)
            }
            .padding(Spacing.md)
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
            .resourceCardStyle()
        }
    }

    private func resourceRow<Actions: View>(
        title: String,
        icon: String,
        status: NotebookResourceStatus,
        detail: String? = nil,
        onOpen: (() -> Void)?,
        @ViewBuilder actions: () -> Actions = { EmptyView() }
    ) -> some View {
        HStack(spacing: Spacing.sm) {
            Button(action: { onOpen?() }) {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.textSecondary)
                        .frame(width: 18)
                    Text(title)
                        .font(.bodySM)
                        .foregroundColor(.textPrimary)
                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundColor(.textTertiary)
                    }
                    Spacer(minLength: Spacing.sm)
                    Circle()
                        .fill(NotebookResourceStatusPresentation.color(status))
                        .frame(width: 6, height: 6)
                    Text(NotebookResourceStatusPresentation.text(status))
                        .font(.caption)
                        .foregroundColor(NotebookResourceStatusPresentation.color(status))
                    if onOpen != nil {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.textTertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(onOpen == nil)
            .accessibilityLabel(
                "\(title), \(NotebookResourceStatusPresentation.text(status))"
            )

            actions()
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(Color.bgRoot.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
    }

    private var displayTitle: String {
        let trimmed = sessionTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? String(localized: "resources.untitled_recording") : trimmed
    }

    private var isAudioDeletionBlocked: Bool {
        audioDeletionBlockMessage != nil
    }

    private var audioDeletionBlockMessage: String? {
        if viewModel.item?.isRecording == true
            || (capture.isCaptureActive && capture.sessionId == sessionId) {
            return String(localized: "resources.audio.destroy.while_recording")
        }
        if viewModel.item?.asyncTranscript == .pending {
            return String(localized: "resources.audio.destroy.while_processing")
        }
        return nil
    }

    private func audioDetail(_ item: NotebookResourceItem) -> String? {
        switch item.audio {
        case .ready: String(localized: "resources.audio.saved")
        case .missing: String(localized: "resources.audio.not_saved")
        case .destroyed:
            item.audioDestroyedAt.map {
                String(
                    format: String(localized: "resources.audio.destroyed_at"),
                    $0.formatted(date: .abbreviated, time: .shortened)
                )
            }
        case .unknown, .pending, .empty, .failed: nil
        }
    }

    private func destroyAudio() {
        Task { @MainActor in
            if let failure = await viewModel.destroyAudio(sessionId: sessionId) {
                ToastCenter.shared.error(
                    String(localized: "resources.audio.destroy.failed"),
                    detail: failure
                )
            } else {
                ToastCenter.shared.success(String(localized: "resources.audio.destroy.done"))
            }
        }
    }
}

private extension View {
    func resourceCardStyle() -> some View {
        background(Color.bgElevated.opacity(0.3))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.md)
                    .strokeBorder(Color.borderGhost.opacity(0.5), lineWidth: Stroke.thin)
            )
            .clipShape(RoundedRectangle(cornerRadius: Radius.md))
    }
}

struct NotebookResourcesView: View {
    let notebookId: String
    let notebookTitle: String?
    let onStartCapture: () -> Void
    let onOpenResource: (String, NotebookResourceDestination) -> Void
    @StateObject private var viewModel = NotebookResourcesViewModel()
    @State private var movingSession: NotebookResourceItem?
    @State private var searchText = ""
    @State private var isSelectingSessions = false
    @State private var selectedSessionIds: Set<String> = []
    @FocusState private var isSearchFocused: Bool

    private var visibleItems: [NotebookResourceItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.isEmpty == false else { return viewModel.items }
        return viewModel.items.filter { item in
            item.title.localizedCaseInsensitiveContains(query)
                || item.preview.localizedCaseInsensitiveContains(query)
                || item.languagePair.localizedCaseInsensitiveContains(query)
                || item.createdAt.formatted(date: .abbreviated, time: .shortened)
                    .localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                topicHeader
                topicControls

                if isSelectingSessions {
                    researchSelectionBar
                }

                if let loadError = viewModel.loadError,
                   viewModel.items.isEmpty == false {
                    refreshWarning(message: loadError)
                }

                if viewModel.isLoading, viewModel.items.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 240)
                        .accessibilityLabel(
                            Text(String(localized: "topic.workspace.loading"))
                        )
                } else if let loadError = viewModel.loadError,
                          viewModel.items.isEmpty {
                    resourceMessage(
                        icon: "exclamationmark.triangle",
                        title: loadError,
                        actionTitle: String(localized: "home.workspace.retry"),
                        action: { viewModel.load(notebookId: notebookId) }
                    )
                } else if viewModel.items.isEmpty {
                    resourceMessage(
                        icon: "waveform",
                        title: String(localized: "topic.workspace.empty"),
                        actionTitle: String(localized: "topic.workspace.record"),
                        action: onStartCapture
                    )
                } else if visibleItems.isEmpty {
                    resourceMessage(
                        icon: "magnifyingglass",
                        title: String(localized: "topic.workspace.no_match"),
                        actionTitle: String(localized: "home.catalog.search.clear"),
                        action: {
                            searchText = ""
                            isSearchFocused = true
                        }
                    )
                } else {
                    LazyVStack(alignment: .leading, spacing: Spacing.md) {
                        ForEach(visibleItems) { item in
                            NotebookResourceBlock(
                                item: item,
                                isSelectionMode: isSelectingSessions,
                                isSelected: selectedSessionIds.contains(item.id),
                                onToggleSelection: {
                                    if selectedSessionIds.contains(item.id) {
                                        selectedSessionIds.remove(item.id)
                                    } else {
                                        selectedSessionIds.insert(item.id)
                                    }
                                },
                                onOpen: { destination in
                                    onOpenResource(item.id, destination)
                                },
                                onDestroyAudio: {
                                    if viewModel.destroyAudio(sessionId: item.id) == false {
                                        ToastCenter.shared.error(
                                            String(localized: "resources.audio.destroy.failed")
                                        )
                                    }
                                },
                                onVerifyAudioDestruction: {
                                    verifyAudioDestruction(sessionId: item.id)
                                },
                                onMove: {
                                    movingSession = item
                                },
                                onMoveToTrash: {
                                    if viewModel.moveToTrash(sessionId: item.id) == false {
                                        ToastCenter.shared.error(
                                            String(localized: "resources.delete.failed")
                                        )
                                    }
                                }
                            )
                        }
                    }
                }
            }
            .frame(maxWidth: 1_000, alignment: .leading)
            .padding(Spacing.xl)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(Color.bgRoot)
        .task(id: notebookId) {
            viewModel.load(notebookId: notebookId)
        }
        .onReceive(NotificationCenter.default.publisher(for: .zutalkSessionUpdated)) { _ in
            viewModel.load(notebookId: notebookId)
        }
        .montereyOnChange(of: viewModel.items.map(\.id)) { _, ids in
            selectedSessionIds.formIntersection(Set(ids))
            if ids.isEmpty { isSelectingSessions = false }
        }
        .sheet(item: $movingSession) { session in
            MoveSessionSheet(
                sessionTitle: session.title,
                destinations: viewModel.moveDestinations(excluding: notebookId),
                onCancel: { movingSession = nil },
                onConfirm: { targetNotebookId in
                    movingSession = nil
                    move(session: session, to: targetNotebookId)
                }
            )
        }
    }

    private var topicHeader: some View {
        MontereyHorizontalViewThatFits {
            HStack(alignment: .top, spacing: Spacing.lg) {
                topicIdentity
                    .layoutPriority(1)
                Spacer(minLength: Spacing.md)
                topicHeaderActions
                    .fixedSize()
            }

        } fallback: {
            VStack(alignment: .leading, spacing: Spacing.md) {
                topicIdentity
                topicHeaderActions
            }
        }
    }

    private var topicIdentity: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(String(localized: "topic.workspace.title"))
                .font(.captionMedium)
                .foregroundColor(.textSecondary)

            Text(notebookTitle ?? String(localized: "sidebar.notebook"))
                .font(.titleLG)
                .foregroundColor(.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)

            Text(String(localized: "topic.workspace.subtitle"))
                .font(.bodySM)
                .foregroundColor(.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Label(
                String(localized: "topic.workspace.local_first"),
                systemImage: "lock.shield.fill"
            )
            .font(.caption)
            .foregroundColor(.textTertiary)
        }
    }

    private var topicHeaderActions: some View {
        HStack(spacing: Spacing.sm) {
            Button(action: chooseAudioFile) {
                Label(
                    viewModel.isImportingAudio
                        ? String(localized: "home.import.in_progress")
                        : String(localized: "home.import.action"),
                    systemImage: "square.and.arrow.down"
                )
                .frame(minHeight: 36)
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.isImportingAudio)
            .accessibilityIdentifier("topic.import")

            Button(action: onStartCapture) {
                Label(
                    String(localized: "topic.workspace.record"),
                    systemImage: "record.circle"
                )
                .frame(minHeight: 36)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("topic.record")
        }
    }

    private var topicControls: some View {
        MontereyHorizontalViewThatFits {
            HStack(spacing: Spacing.md) {
                topicSearchField
                topicSessionCount
                Spacer(minLength: Spacing.md)
                topicSelectionButton
            }

        } fallback: {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                topicSearchField
                HStack(spacing: Spacing.md) {
                    topicSessionCount
                    Spacer(minLength: Spacing.md)
                    topicSelectionButton
                }
            }
        }
    }

    private var topicSearchField: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.textSecondary)
            TextField(
                String(localized: "topic.workspace.search_placeholder"),
                text: $searchText
            )
            .textFieldStyle(.plain)
            .focused($isSearchFocused)
            if searchText.isEmpty == false {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "home.catalog.search.clear"))
            }
        }
        .padding(.horizontal, Spacing.md)
        .frame(maxWidth: 430, minHeight: 36)
        .background(Color.bgElevated.opacity(0.4))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.sm)
                .strokeBorder(Color.borderGhost.opacity(0.6), lineWidth: Stroke.thin)
        )
        .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
        .focusRing(isSearchFocused, cornerRadius: Radius.sm)
        .accessibilityIdentifier("topic.search")
    }

    private var topicSessionCount: some View {
        Text(
            String(
                format: String(localized: "home.catalog.count_format"),
                Int64(visibleItems.count)
            )
        )
        .font(.bodySM)
        .foregroundColor(.textSecondary)
        .monospacedDigit()
    }

    private var topicSelectionButton: some View {
        Button {
            isSelectingSessions.toggle()
            if isSelectingSessions == false { selectedSessionIds = [] }
        } label: {
            Label(
                isSelectingSessions
                    ? String(localized: "common.done")
                    : String(localized: "topic.research.select"),
                systemImage: isSelectingSessions ? "checkmark" : "checklist"
            )
            .frame(minHeight: 36)
        }
        .buttonStyle(.plain)
        .foregroundColor(.textPrimary)
        .disabled(viewModel.items.isEmpty)
        .accessibilityIdentifier("topic.research.select")
    }

    private var researchSelectionBar: some View {
        MontereyHorizontalViewThatFits {
            HStack(spacing: Spacing.md) {
                researchSelectionSummary
                Spacer(minLength: Spacing.md)
                researchSelectionActions
            }
        } fallback: {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                researchSelectionSummary
                researchSelectionActions
            }
        }
        .padding(Spacing.md)
        .background(Color.brandAccent.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.sm)
                .strokeBorder(Color.brandAccent.opacity(0.28), lineWidth: Stroke.thin)
        )
        .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
    }

    private var researchSelectionSummary: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(localized: "topic.research.selection.title"))
                .font(.bodyMedium)
                .foregroundColor(.textPrimary)
            Text(
                String(
                    format: String(localized: "topic.research.selection.count_format"),
                    Int64(selectedSessionIds.count)
                )
            )
            .font(.caption)
            .foregroundColor(.textSecondary)
        }
    }

    private var researchSelectionActions: some View {
        HStack(spacing: Spacing.sm) {
            Button {
                selectedSessionIds = Set(visibleItems.map(\.id))
            } label: {
                Text(String(localized: "topic.research.select_all"))
                    .frame(minHeight: 36)
            }
            .buttonStyle(.plain)
            .disabled(visibleItems.isEmpty)

            Button {
                viewModel.copyResearchBundle(sessionIds: selectedSessionIds)
            } label: {
                Label(
                    viewModel.isPreparingResearchBundle
                        ? String(localized: "topic.research.copy.preparing")
                        : String(localized: "topic.research.copy"),
                    systemImage: "doc.on.doc"
                )
                .frame(minHeight: 36)
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                selectedSessionIds.isEmpty
                    || viewModel.isPreparingResearchBundle
            )
            .accessibilityIdentifier("topic.research.copy")
        }
    }

    private func refreshWarning(message: String) -> some View {
        HStack(spacing: Spacing.md) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.bodySM)
                .foregroundColor(.signalAmber)
            Spacer(minLength: 0)
            Button(String(localized: "home.workspace.retry")) {
                viewModel.load(notebookId: notebookId)
            }
            .buttonStyle(.plain)
            .frame(minHeight: 36)
        }
        .padding(.horizontal, Spacing.md)
        .background(Color.bgElevated.opacity(0.25))
        .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
    }

    private func chooseAudioFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.audio]
        panel.prompt = String(localized: "home.import.sheet.choose")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        viewModel.importAudio(at: url, notebookId: notebookId)
    }

    /// Moves the recording, then follows it: the editor route names this
    /// notebook's tab and document ids, which no longer own the session, so
    /// reloading in place would open a notebook that does not hold it.
    private func move(session: NotebookResourceItem, to targetNotebookId: String) {
        if let failure = viewModel.moveToNotebook(
            sessionId: session.id,
            targetNotebookId: targetNotebookId
        ) {
            ToastCenter.shared.error(String(localized: "resources.move.failed"), detail: failure)
            return
        }
        ToastCenter.shared.success(String(localized: "resources.move.done"))
        MainNavigationStore.shared.openSession(session.id)
    }

    /// User-facing "prove it": recompute the receipt, report it, and reveal
    /// the audio storage folder in Finder so the user can look for themselves.
    private func verifyAudioDestruction(sessionId: String) {
        guard let report = viewModel.verifyAudioDestruction(sessionId: sessionId) else {
            ToastCenter.shared.error(String(localized: "resources.audio.verify.failed"))
            return
        }

        let clean = report.filesRemaining == 0
            && report.keyDeleted
            && report.deleteErrors.isEmpty
        if clean {
            ToastCenter.shared.success(
                String(localized: "resources.audio.verify.ok"),
                detail: String(
                    format: String(localized: "resources.audio.verify.ok.detail"),
                    Int(report.chunksDeleted)
                )
            )
        } else {
            ToastCenter.shared.warning(
                String(localized: "resources.audio.verify.residue"),
                detail: String(
                    format: String(localized: "resources.audio.verify.residue.detail"),
                    Int(report.filesRemaining)
                )
            )
        }

        NSWorkspace.shared.activateFileViewerSelecting(
            [URL(fileURLWithPath: CoreClient.defaultDataDir(), isDirectory: true)]
        )
    }

    private func resourceMessage(
        icon: String,
        title: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) -> some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .light))
                .foregroundColor(.textTertiary)
            Text(title)
                .font(.body)
                .foregroundColor(.textSecondary)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 260)
    }
}

private struct NotebookResourceBlock: View {
    let item: NotebookResourceItem
    let isSelectionMode: Bool
    let isSelected: Bool
    let onToggleSelection: () -> Void
    let onOpen: (NotebookResourceDestination) -> Void
    let onDestroyAudio: () -> Void
    let onVerifyAudioDestruction: () -> Void
    let onMove: () -> Void
    let onMoveToTrash: () -> Void

    @State private var isConfirmingAudioDestroy = false
    @State private var isConfirmingTrash = false
    @State private var isShowingFiles = false
    @FocusState private var isPrimaryFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(alignment: .top, spacing: Spacing.md) {
                if isSelectionMode {
                    Button(action: onToggleSelection) {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(isSelected ? .brandAccent : .textTertiary)
                            .frame(width: 32, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        String(localized: isSelected
                            ? "topic.research.deselect_session"
                            : "topic.research.select_session")
                    )
                }

                Button(action: primaryAction) {
                    sessionSummary
                }
                .buttonStyle(.plain)
                .disabled(isSelectionMode)
                .focusable(isSelectionMode == false)
                .focused($isPrimaryFocused)
                .focusRing(isPrimaryFocused, cornerRadius: Radius.sm)
                .accessibilityHint(String(localized: "home.catalog.row.open_hint"))
                .accessibilityIdentifier("resources.session.\(item.id)")

                Spacer()

                Menu {
                    Button {
                        onMove()
                    } label: {
                        Label(
                            String(localized: "resources.move"),
                            systemImage: "arrow.right.doc.on.clipboard"
                        )
                    }
                    Divider()
                    // 录音进行中删不了(Core 软删与彻底删除都拒绝)。
                    // 禁用 + 一句原因,比给一个必然失败的按钮诚实。
                    Button(role: .destructive) {
                        isConfirmingTrash = true
                    } label: {
                        Label(
                            String(localized: "resources.delete"),
                            systemImage: "trash"
                        )
                    }
                    .disabled(item.isRecording)

                    if item.isRecording {
                        Text(String(localized: "home.recording.delete_while_recording"))
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.textSecondary)
                        .frame(width: 32, height: 36)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(isSelectionMode)
                .accessibilityLabel(
                    String(
                        format: String(localized: "home.catalog.row.actions_format"),
                        displayTitle
                    )
                )
                .accessibilityIdentifier("resources.menu.\(item.id)")
            }

            DisclosureGroup(isExpanded: $isShowingFiles) {
                VStack(spacing: Spacing.xs) {
                    resourceBar(
                        title: String(localized: "resources.audio_export"),
                        icon: "waveform",
                        status: item.audio,
                        detail: audioDetail,
                        onOpen: item.audio == .ready ? { onOpen(.audio) } : nil
                    ) {
                        if item.audio == .ready {
                            Button {
                                isConfirmingAudioDestroy = true
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.signalRed)
                            }
                            .buttonStyle(.plain)
                            .frame(width: 28, height: 28)
                            .help(String(localized: "resources.audio.destroy"))
                            .accessibilityLabel(String(localized: "resources.audio.destroy"))
                            .accessibilityIdentifier("resources.audio.destroy.\(item.id)")
                        }
                        if item.audio == .destroyed {
                            Button(action: onVerifyAudioDestruction) {
                                Image(systemName: "checkmark.shield")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.textSecondary)
                            }
                            .buttonStyle(.plain)
                            .frame(width: 28, height: 28)
                            .help(String(localized: "resources.audio.verify"))
                            .accessibilityLabel(String(localized: "resources.audio.verify"))
                            .accessibilityIdentifier("resources.audio.verify.\(item.id)")
                        }
                    }
                    resourceBar(
                        title: String(localized: "resources.realtime"),
                        icon: "captions.bubble",
                        status: item.realtimeTranscript,
                        onOpen: { onOpen(.realtimeTranscript) }
                    )
                    resourceBar(
                        title: String(localized: "resources.async"),
                        icon: "text.document",
                        status: item.asyncTranscript,
                        onOpen: { onOpen(.asyncTranscript) }
                    )
                }
                .padding(.top, Spacing.sm)
            } label: {
                HStack(spacing: Spacing.sm) {
                    Text(String(localized: "topic.session.files_and_status"))
                        .font(.captionMedium)
                        .foregroundColor(.textSecondary)
                    Spacer()
                    resourceSummaryDot(status: item.audio)
                    resourceSummaryDot(status: item.realtimeTranscript)
                    resourceSummaryDot(status: item.asyncTranscript)
                }
            }
            .disabled(isSelectionMode)
        }
        .padding(Spacing.md)
        .background(Color.bgElevated.opacity(0.3))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.sm)
                .strokeBorder(Color.borderGhost.opacity(0.5), lineWidth: Stroke.thin)
        )
        .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
        .confirmationDialog(
            String(
                format: String(localized: "resources.audio.destroy.confirm_title"),
                displayTitle
            ),
            isPresented: $isConfirmingAudioDestroy,
            titleVisibility: .visible
        ) {
            Button(String(localized: "resources.audio.destroy.confirm_button"), role: .destructive) {
                onDestroyAudio()
            }
            Button(String(localized: "common.cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "resources.audio.destroy.confirm_message"))
        }
        .confirmationDialog(
            String(
                format: String(localized: "resources.delete.confirm_title"),
                displayTitle
            ),
            isPresented: $isConfirmingTrash,
            titleVisibility: .visible
        ) {
            Button(String(localized: "resources.delete.confirm_button"), role: .destructive) {
                onMoveToTrash()
            }
            Button(String(localized: "common.cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "resources.delete.confirm_message"))
        }
    }

    @ViewBuilder
    private var sessionSummary: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(timeOnly)
                    .font(.titleMD)
                    .foregroundColor(.textPrimary)
                    .monospacedDigit()
                Text(dateOnly)
                    .font(.caption)
                    .foregroundColor(.textTertiary)
            }
            .frame(width: 112, alignment: .leading)

            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(spacing: Spacing.sm) {
                    Text(displayTitle)
                        .font(.bodyMedium)
                        .foregroundColor(.textPrimary)
                        .lineLimit(1)
                    TopicSessionStatusBadge(item: item)
                }

                if item.preview.isEmpty == false {
                    Text(item.preview)
                        .font(.bodySM)
                        .foregroundColor(.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(String(localized: "topic.session.no_preview"))
                        .font(.bodySM)
                        .foregroundColor(.textTertiary)
                        .italic()
                }

                HStack(spacing: Spacing.md) {
                    Label(duration, systemImage: "timer")
                    if item.languagePair.isEmpty == false {
                        Label(item.languagePair, systemImage: "character.bubble")
                    }
                    Label(
                        item.sessionType.lowercased() == "import"
                            ? String(localized: "home.row.kind.import")
                            : String(localized: "home.row.kind.recording"),
                        systemImage: item.sessionType.lowercased() == "import"
                            ? "square.and.arrow.down"
                            : "mic"
                    )
                }
                .font(.caption)
                .foregroundColor(.textTertiary)
            }

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundColor(.textTertiary)
                .padding(.top, Spacing.xs)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func primaryAction() {
        if item.isRecording {
            onOpen(.realtimeTranscript)
        } else if item.asyncTranscript != .missing {
            onOpen(.asyncTranscript)
        } else if item.sessionType.lowercased() == "import" {
            onOpen(.asyncTranscript)
        } else {
            onOpen(.realtimeTranscript)
        }
    }

    private func resourceSummaryDot(status: NotebookResourceStatus) -> some View {
        Circle()
            .fill(statusColor(status))
            .frame(width: 6, height: 6)
            .accessibilityHidden(true)
    }

    private func resourceBar(
        title: String,
        icon: String,
        status: NotebookResourceStatus,
        detail: String? = nil,
        onOpen: (() -> Void)?,
        @ViewBuilder actions: () -> some View = { EmptyView() }
    ) -> some View {
        HStack(spacing: Spacing.sm) {
            Button(action: { onOpen?() }) {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.textSecondary)
                        .frame(width: 18)

                    Text(title)
                        .font(.bodySM)
                        .foregroundColor(.textPrimary)

                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundColor(.textTertiary)
                    }

                    Spacer()

                    Circle()
                        .fill(statusColor(status))
                        .frame(width: 6, height: 6)
                    Text(statusText(status))
                        .font(.caption)
                        .foregroundColor(statusColor(status))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(onOpen == nil)
            .accessibilityLabel("\(title), \(statusText(status))")

            actions()
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(Color.bgRoot.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
    }

    private var audioDetail: String? {
        switch item.audio {
        case .unknown: nil
        case .ready: String(localized: "resources.audio.saved")
        case .missing: String(localized: "resources.audio.not_saved")
        case .destroyed:
            item.audioDestroyedAt.map {
                String(
                    format: String(localized: "resources.audio.destroyed_at"),
                    $0.formatted(date: .abbreviated, time: .shortened)
                )
            }
        case .pending, .empty, .failed: nil
        }
    }

    private var timeOnly: String { item.createdAt.formatted(date: .omitted, time: .shortened) }
    private var dateOnly: String { item.createdAt.formatted(date: .abbreviated, time: .omitted) }

    private var displayTitle: String {
        item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? String(localized: "resources.untitled_recording")
            : item.title
    }

    private var duration: String {
        let totalSeconds = item.durationMs / 1_000
        return String(format: "%02llu:%02llu", totalSeconds / 60, totalSeconds % 60)
    }

    private func statusText(_ status: NotebookResourceStatus) -> String {
        NotebookResourceStatusPresentation.text(status)
    }

    private func statusColor(_ status: NotebookResourceStatus) -> Color {
        NotebookResourceStatusPresentation.color(status)
    }
}

private struct TopicSessionStatusBadge: View {
    let item: NotebookResourceItem

    var body: some View {
        Label(label, systemImage: icon)
            .font(.captionMedium)
            .foregroundColor(color)
            .lineLimit(1)
    }

    private var normalizedStatus: String { item.rawStatus.lowercased() }

    private var label: String {
        if normalizedStatus == "recording" {
            return String(localized: "home.status.recording")
        }
        if item.asyncTranscript == .pending {
            return String(localized: "home.status.transcribing")
        }
        if normalizedStatus == "failed" || item.asyncTranscript == .failed {
            return String(localized: "home.status.failed")
        }
        if normalizedStatus == "interrupted" {
            return String(localized: "home.status.interrupted")
        }
        if item.sessionType.lowercased() == "import" {
            return String(localized: "home.status.imported")
        }
        return String(localized: "home.status.completed")
    }

    private var icon: String {
        if normalizedStatus == "recording" { return "record.circle.fill" }
        if item.asyncTranscript == .pending { return "hourglass" }
        if normalizedStatus == "failed" || item.asyncTranscript == .failed {
            return "xmark.octagon.fill"
        }
        if normalizedStatus == "interrupted" { return "exclamationmark.triangle.fill" }
        if item.sessionType.lowercased() == "import" { return "square.and.arrow.down" }
        return "checkmark.circle.fill"
    }

    private var color: Color {
        if normalizedStatus == "recording" { return .signalRed }
        if normalizedStatus == "failed" || normalizedStatus == "interrupted"
            || item.asyncTranscript == .failed {
            return .signalAmber
        }
        if item.asyncTranscript == .pending { return .signalAmber }
        return .textSecondary
    }
}

/// Picks the notebook a recording moves to.
///
/// The destination is always chosen explicitly and never inherited from
/// whichever notebook happens to be open — the same rule the share sheet
/// states, and for the same reason: moving a meeting into the wrong notebook
/// is silent and easy to miss.
private struct MoveSessionSheet: View {
    let sessionTitle: String
    let destinations: [FfiNotebook]
    let onCancel: () -> Void
    let onConfirm: (String) -> Void

    @State private var selectedNotebookId: String = ""

    private var displayTitle: String {
        sessionTitle.isEmpty ? String(localized: "resources.untitled_recording") : sessionTitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text(String(localized: "resources.move.title"))
                    .font(.titleMD)
                    .foregroundColor(.textPrimary)
                Text(String(format: String(localized: "resources.move.message"), displayTitle))
                    .font(.bodySM)
                    .foregroundColor(.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if destinations.isEmpty {
                Text(String(localized: "resources.move.no_destination"))
                    .font(.bodySM)
                    .foregroundColor(.textTertiary)
            } else {
                Picker("", selection: $selectedNotebookId) {
                    ForEach(destinations, id: \.id) { notebook in
                        Text(notebook.title).tag(notebook.id)
                    }
                }
                .labelsHidden()
                .accessibilityLabel(String(localized: "resources.move.destination"))
                .accessibilityIdentifier("resources.move.picker")
            }

            HStack(spacing: Spacing.sm) {
                Spacer()

                Button(String(localized: "common.cancel")) {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button(String(localized: "resources.move.action")) {
                    guard selectedNotebookId.isEmpty == false else { return }
                    onConfirm(selectedNotebookId)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedNotebookId.isEmpty)
                .accessibilityIdentifier("resources.move.confirm")
            }
        }
        .padding(Spacing.xl)
        .frame(width: 440)
        .background(Color.bgRoot)
        .onAppear {
            if selectedNotebookId.isEmpty, let first = destinations.first {
                selectedNotebookId = first.id
            }
        }
    }
}
