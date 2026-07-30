import Combine
import SwiftUI

enum NotebookResourceStatus: Equatable {
    case missing
    case pending
    case ready
    case failed
}

struct NotebookResourceItem: Identifiable, Equatable {
    let id: String
    let title: String
    let createdAt: Date
    let durationMs: UInt64
    let audio: NotebookResourceStatus
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
                if session.status.lowercased() == "recording" {
                    audioStatus = .pending
                } else if session.hasEncryptedAudio {
                    audioStatus = .ready
                } else {
                    audioStatus = .missing
                }

                return NotebookResourceItem(
                    id: session.id,
                    title: session.title,
                    createdAt: Date(timeIntervalSince1970: TimeInterval(session.createdAtUnixMs) / 1_000),
                    durationMs: session.durationMs,
                    audio: audioStatus,
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
                        .foregroundColor(.bpLine)
                    Text(String(localized: "resources.subtitle"))
                        .font(.bodySM)
                        .foregroundColor(.textOnBpDim)
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
                    LazyVStack(spacing: Spacing.sm) {
                        ForEach(viewModel.items) { item in
                            NotebookResourceRow(item: item) {
                                onOpenSession(item.id)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: 960, alignment: .leading)
            .padding(Spacing.xl)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(Color.bpBlue)
        .task(id: notebookId) {
            viewModel.load(notebookId: notebookId)
        }
        .onReceive(NotificationCenter.default.publisher(for: .zulangueSessionUpdated)) { _ in
            viewModel.load(notebookId: notebookId)
        }
    }

    private func resourceMessage(icon: String, title: String) -> some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .light))
                .foregroundColor(.textOnBpFaint)
            Text(title)
                .font(.body)
                .foregroundColor(.textOnBpDim)
        }
        .frame(maxWidth: .infinity, minHeight: 260)
    }
}

private struct NotebookResourceRow: View {
    let item: NotebookResourceItem
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: Spacing.md) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.md) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(displayTitle)
                            .font(.bodyMedium)
                            .foregroundColor(.bpLine)
                        Text(timestamp)
                            .font(.caption)
                            .foregroundColor(.textOnBpFaint)
                    }

                    Spacer()

                    Text(duration)
                        .font(.captionMedium)
                        .foregroundColor(.textOnBpDim)
                }

                HStack(spacing: Spacing.sm) {
                    statusChip(
                        title: String(localized: "resources.audio"),
                        icon: "waveform",
                        status: item.audio
                    )
                    statusChip(
                        title: String(localized: "resources.realtime"),
                        icon: "captions.bubble",
                        status: item.realtimeTranscript
                    )
                    statusChip(
                        title: String(localized: "resources.async"),
                        icon: "text.document",
                        status: item.asyncTranscript
                    )
                    statusChip(
                        title: String(localized: "resources.note"),
                        icon: "note.text",
                        status: item.manualNote
                    )
                    Spacer()
                }
            }
            .padding(Spacing.md)
            .background(Color.bpBlueLight.opacity(0.3))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.sm)
                    .strokeBorder(Color.bpLineGhost.opacity(0.5), lineWidth: Stroke.thin)
            )
            .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
            .contentShape(RoundedRectangle(cornerRadius: Radius.sm))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("resources.session.\(item.id)")
    }

    private func statusChip(
        title: String,
        icon: String,
        status: NotebookResourceStatus
    ) -> some View {
        Label(title, systemImage: icon)
            .font(.caption)
            .foregroundColor(statusColor(status))
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .background(statusColor(status).opacity(0.09))
            .clipShape(Capsule())
            .help(statusText(status))
            .accessibilityLabel("\(title), \(statusText(status))")
    }

    private var displayTitle: String {
        item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? String(localized: "resources.untitled_recording")
            : item.title
    }

    private var timestamp: String {
        item.createdAt.formatted(date: .abbreviated, time: .shortened)
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
        }
    }

    private func statusColor(_ status: NotebookResourceStatus) -> Color {
        switch status {
        case .missing: .textOnBpFaint
        case .pending: .signalAmber
        case .ready: .signalGreen
        case .failed: .signalRed
        }
    }
}
