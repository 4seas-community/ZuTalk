import AppKit
import Combine
import SwiftUI

enum NotebookResourceStatus: Equatable {
    case missing
    case pending
    case ready
    case failed
    /// The resource existed and was verifiably destroyed — distinct from
    /// `.missing`, which means it was never generated at all.
    case destroyed
}

struct NotebookResourceItem: Identifiable, Equatable {
    let id: String
    let title: String
    let createdAt: Date
    let durationMs: UInt64
    let audio: NotebookResourceStatus
    let audioDestroyedAt: Date?
    let realtimeTranscript: NotebookResourceStatus
    let asyncTranscript: NotebookResourceStatus
    let manualNote: NotebookResourceStatus
}

@MainActor
final class NotebookResourcesViewModel: ObservableObject {
    @Published private(set) var items: [NotebookResourceItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var loadFailed = false

    func load(notebookId: String, core: (any ZulangueCoreProtocol)? = nil) {
        guard isLoading == false else { return }
        guard let core = core ?? CoreClient.shared.core else {
            items = []
            loadFailed = true
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let links = try core.listNotebookSessions(notebookId: notebookId)
            let linkedIds = Set(links.map(\.sessionId))
            let sessions = try core.querySessions(
                sessionType: nil,
                status: nil,
                searchText: nil,
                limit: 500,
                offset: 0
            ).sessions.filter { linkedIds.contains($0.id) }

            let tabs = try core.listNotebookTabs(notebookId: notebookId)
                .filter { $0.deletedAt == nil }
            let projectionsByKind = Dictionary(
                uniqueKeysWithValues: tabs.map { tab in
                    let projections = (try? core.listNotebookSessionProjections(tabId: tab.id)) ?? []
                    return (tab.builtinKind, Set(projections.filter { $0.deletedAt == nil }.map(\.sessionId)))
                }
            )
            let transcriptionTasks = TranscriptionTaskIndex.load(core: core)

            items = sessions.map { session in
                let asyncStatus: NotebookResourceStatus
                if let task = transcriptionTasks[session.id] {
                    switch task.tabStatus {
                    case .pending, .live: asyncStatus = .pending
                    case .ready:
                        asyncStatus = projectionsByKind[
                            "async_transcript",
                            default: []
                        ].contains(session.id) ? .ready : .missing
                    case .failed: asyncStatus = .failed
                    }
                } else {
                    asyncStatus = .missing
                }

                let audioStatus: NotebookResourceStatus
                var audioDestroyedAt: Date?
                if session.status.lowercased() == "recording" {
                    audioStatus = .pending
                } else if session.hasEncryptedAudio {
                    audioStatus = .ready
                } else if let report = try? core.getAudioDestructionReport(sessionId: session.id),
                    report.chunkTotal > 0,
                    report.chunksDeleted == report.chunkTotal {
                    // The ledger proves audio existed and every chunk was
                    // overwritten and deleted — this is "destroyed", not
                    // "never generated".
                    audioStatus = .destroyed
                    audioDestroyedAt = report.destroyedAtMs.map {
                        Date(timeIntervalSince1970: TimeInterval($0) / 1_000)
                    }
                } else {
                    audioStatus = .missing
                }

                return NotebookResourceItem(
                    id: session.id,
                    title: session.title,
                    createdAt: Date(timeIntervalSince1970: TimeInterval(session.createdAtUnixMs) / 1_000),
                    durationMs: session.durationMs,
                    audio: audioStatus,
                    audioDestroyedAt: audioDestroyedAt,
                    realtimeTranscript: projectionsByKind[
                        "realtime_transcript",
                        default: []
                    ].contains(session.id) ? .ready : .missing,
                    asyncTranscript: asyncStatus,
                    manualNote: projectionsByKind[
                        "manual_note",
                        default: []
                    ].contains(session.id) ? .ready : .missing
                )
            }
            .sorted { $0.createdAt > $1.createdAt }
            loadFailed = false
        } catch {
            items = []
            loadFailed = true
        }
    }

    func destroyAudio(sessionId: String, core: (any ZulangueCoreProtocol)? = nil) -> Bool {
        guard let core = core ?? CoreClient.shared.core else { return false }
        do {
            try core.destroySessionAudioAndKey(sessionId: sessionId)
            NotificationCenter.default.post(name: .zulangueSessionUpdated, object: nil)
            return true
        } catch {
            return false
        }
    }

    /// Recompute the destruction receipt from the ledger, the filesystem, and
    /// the key store right now. Read-only: verification never mutates state.
    func verifyAudioDestruction(
        sessionId: String,
        core: (any ZulangueCoreProtocol)? = nil
    ) -> AudioDestructionReportInfo? {
        guard let core = core ?? CoreClient.shared.core else { return nil }
        return try? core.getAudioDestructionReport(sessionId: sessionId)
    }

    func moveToTrash(sessionId: String, core: (any ZulangueCoreProtocol)? = nil) -> Bool {
        guard let core = core ?? CoreClient.shared.core else { return false }
        do {
            try core.softDeleteSession(sessionId: sessionId)
            items.removeAll { $0.id == sessionId }
            NotificationCenter.default.post(name: .zulangueSessionUpdated, object: nil)
            return true
        } catch {
            return false
        }
    }
}

struct NotebookResourcesView: View {
    let notebookId: String
    let onOpenSession: (String) -> Void
    @StateObject private var viewModel = NotebookResourcesViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(String(localized: "resources.title"))
                        .font(.titleLG)
                        .foregroundColor(.textPrimary)
                    Text(String(localized: "resources.subtitle"))
                        .font(.bodySM)
                        .foregroundColor(.textSecondary)
                }

                if viewModel.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 240)
                } else if viewModel.loadFailed {
                    resourceMessage(
                        icon: "exclamationmark.triangle",
                        title: String(localized: "resources.load_failed")
                    )
                } else if viewModel.items.isEmpty {
                    resourceMessage(
                        icon: "tray",
                        title: String(localized: "resources.empty")
                    )
                } else {
                    LazyVStack(alignment: .leading, spacing: Spacing.md) {
                        ForEach(viewModel.items) { item in
                            NotebookResourceBlock(
                                item: item,
                                onOpen: { onOpenSession(item.id) },
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
            .frame(maxWidth: 960, alignment: .leading)
            .padding(Spacing.xl)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(Color.bgRoot)
        .task(id: notebookId) {
            viewModel.load(notebookId: notebookId)
        }
        .onReceive(NotificationCenter.default.publisher(for: .zulangueSessionUpdated)) { _ in
            viewModel.load(notebookId: notebookId)
        }
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

    private func resourceMessage(icon: String, title: String) -> some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .light))
                .foregroundColor(.textTertiary)
            Text(title)
                .font(.body)
                .foregroundColor(.textSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 260)
    }
}

private struct NotebookResourceBlock: View {
    let item: NotebookResourceItem
    let onOpen: () -> Void
    let onDestroyAudio: () -> Void
    let onVerifyAudioDestruction: () -> Void
    let onMoveToTrash: () -> Void

    @State private var isConfirmingAudioDestroy = false
    @State private var isConfirmingTrash = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.md) {
                Button(action: onOpen) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(displayTitle)
                            .font(.bodyMedium)
                            .foregroundColor(.textPrimary)
                        Text(timestamp)
                            .font(.caption)
                            .foregroundColor(.textTertiary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("resources.session.\(item.id)")

                Spacer()

                Text(duration)
                    .font(.captionMedium)
                    .foregroundColor(.textSecondary)

                Menu {
                    Button(role: .destructive) {
                        isConfirmingTrash = true
                    } label: {
                        Label(
                            String(localized: "resources.delete"),
                            systemImage: "trash"
                        )
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.textSecondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityIdentifier("resources.menu.\(item.id)")
            }

            VStack(spacing: Spacing.xs) {
                resourceBar(
                    title: String(localized: "resources.audio"),
                    icon: "waveform",
                    status: item.audio,
                    detail: audioDetail
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
                        .help(String(localized: "resources.audio.destroy"))
                        .accessibilityIdentifier("resources.audio.destroy.\(item.id)")
                    }
                    if item.audio == .destroyed {
                        Button(action: onVerifyAudioDestruction) {
                            Image(systemName: "checkmark.shield")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.textSecondary)
                        }
                        .buttonStyle(.plain)
                        .help(String(localized: "resources.audio.verify"))
                        .accessibilityIdentifier("resources.audio.verify.\(item.id)")
                    }
                }
                resourceBar(
                    title: String(localized: "resources.realtime"),
                    icon: "captions.bubble",
                    status: item.realtimeTranscript
                )
                resourceBar(
                    title: String(localized: "resources.async"),
                    icon: "text.document",
                    status: item.asyncTranscript
                )
                resourceBar(
                    title: String(localized: "resources.note"),
                    icon: "note.text",
                    status: item.manualNote
                )
            }
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

    private func resourceBar(
        title: String,
        icon: String,
        status: NotebookResourceStatus,
        detail: String? = nil,
        @ViewBuilder actions: () -> some View = { EmptyView() }
    ) -> some View {
        HStack(spacing: Spacing.sm) {
            Button(action: onOpen) {
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
        case .ready: String(localized: "resources.audio.saved")
        case .missing: String(localized: "resources.audio.not_saved")
        case .destroyed:
            item.audioDestroyedAt.map {
                String(
                    format: String(localized: "resources.audio.destroyed_at"),
                    $0.formatted(date: .abbreviated, time: .shortened)
                )
            }
        case .pending, .failed: nil
        }
    }

    private var timestamp: String {
        item.createdAt.formatted(date: .abbreviated, time: .shortened)
    }

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
        switch status {
        case .missing: String(localized: "resources.status.missing")
        case .pending: String(localized: "resources.status.pending")
        case .ready: String(localized: "resources.status.ready")
        case .failed: String(localized: "resources.status.failed")
        case .destroyed: String(localized: "resources.status.destroyed")
        }
    }

    private func statusColor(_ status: NotebookResourceStatus) -> Color {
        switch status {
        case .missing: .textTertiary
        case .pending: .signalAmber
        case .ready: .signalGreen
        case .failed: .signalRed
        case .destroyed: .textSecondary
        }
    }
}
