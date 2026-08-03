import Combine
import SwiftUI

struct ManualTimeNoteItem: Identifiable, Equatable {
    let id: String
    let createdAt: Date
    var title: String
}

@MainActor
final class ManualNotesTimelineViewModel: ObservableObject {
    @Published private(set) var notes: [ManualTimeNoteItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var loadFailed = false

    func load(
        notebookId: String,
        tabId: String,
        core: (any ZulangueCoreProtocol)? = nil
    ) {
        guard isLoading == false else { return }
        guard let core = core ?? CoreClient.shared.core else {
            notes = []
            loadFailed = true
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let links = try core.listNotebookSessions(notebookId: notebookId)
            let projections = try core.listNotebookSessionProjections(tabId: tabId)
                .filter { $0.deletedAt == nil }
            let titleBySession = Dictionary(
                uniqueKeysWithValues: projections.map {
                    ($0.sessionId, $0.sectionTitle ?? "")
                }
            )

            notes = links.compactMap { link in
                guard let session = try? core.getSession(id: link.sessionId) else {
                    return nil
                }
                return ManualTimeNoteItem(
                    id: session.id,
                    createdAt: Date(
                        timeIntervalSince1970: TimeInterval(session.createdAtUnixMs) / 1_000
                    ),
                    title: titleBySession[session.id] ?? ""
                )
            }
            .sorted { $0.createdAt > $1.createdAt }
            loadFailed = false
        } catch {
            notes = []
            loadFailed = true
        }
    }

    func rename(
        notebookId: String,
        sessionId: String,
        title: String,
        core: (any ZulangueCoreProtocol)? = nil
    ) -> String? {
        guard let core = core ?? CoreClient.shared.core else { return nil }
        do {
            let projection = try core.renameNotebookManualNote(
                notebookId: notebookId,
                sessionId: sessionId,
                title: title
            )
            let savedTitle = projection.sectionTitle ?? ""
            if let index = notes.firstIndex(where: { $0.id == sessionId }) {
                notes[index].title = savedTitle
            }
            return savedTitle
        } catch {
            return nil
        }
    }
}

struct ManualNotesTimelineView: View {
    let notebookId: String
    let tabId: String
    let documentId: String
    let onOpenNote: (String) -> Void

    @StateObject private var viewModel = ManualNotesTimelineViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(String(localized: "manual_note.timeline.title"))
                        .font(.titleMD)
                        .foregroundColor(.textPrimary)
                    Text(String(localized: "manual_note.timeline.subtitle"))
                        .font(.bodySM)
                        .foregroundColor(.textSecondary)
                }

                if viewModel.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 260)
                } else if viewModel.loadFailed {
                    timelineMessage(
                        icon: "exclamationmark.triangle",
                        text: String(localized: "manual_note.timeline.load_failed")
                    )
                } else if viewModel.notes.isEmpty {
                    timelineMessage(
                        icon: "note.text",
                        text: String(localized: "manual_note.timeline.empty")
                    )
                } else {
                    LazyVStack(spacing: Spacing.md) {
                        ForEach(viewModel.notes) { note in
                            ManualTimeNoteCard(
                                note: note,
                                onSaveTitle: { title in
                                    viewModel.rename(
                                        notebookId: notebookId,
                                        sessionId: note.id,
                                        title: title
                                    )
                                },
                                onOpen: { onOpenNote(note.id) }
                            )
                        }
                    }
                }
            }
            .frame(maxWidth: 900, alignment: .leading)
            .padding(Spacing.xl)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(Color.bgRoot)
        .task(id: "\(notebookId):\(tabId)") {
            viewModel.load(notebookId: notebookId, tabId: tabId)
        }
        .onReceive(NotificationCenter.default.publisher(for: .zulangueSessionUpdated)) { _ in
            viewModel.load(notebookId: notebookId, tabId: tabId)
        }
    }

    private func timelineMessage(icon: String, text: String) -> some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .light))
                .foregroundColor(.textTertiary)
            Text(text)
                .font(.body)
                .foregroundColor(.textSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 280)
    }
}

private struct ManualTimeNoteCard: View {
    let note: ManualTimeNoteItem
    let onSaveTitle: (String) -> String?
    let onOpen: () -> Void

    @State private var title: String
    @State private var savedTitle: String
    @State private var isSaving = false

    init(
        note: ManualTimeNoteItem,
        onSaveTitle: @escaping (String) -> String?,
        onOpen: @escaping () -> Void
    ) {
        self.note = note
        self.onSaveTitle = onSaveTitle
        self.onOpen = onOpen
        _title = State(initialValue: note.title)
        _savedTitle = State(initialValue: note.title)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(spacing: Spacing.sm) {
                TextField(
                    String(localized: "manual_note.title.placeholder"),
                    text: $title
                )
                .textFieldStyle(.plain)
                .font(.titleMD)
                .foregroundColor(.textPrimary)
                .onSubmit(save)
                .accessibilityIdentifier("manual_note.timeline.title.\(note.id)")

                if title != savedTitle {
                    Button(action: save) {
                        if isSaving {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.brandAccent)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isSaving)
                    .help(String(localized: "manual_note.title.save"))
                }
            }

            HStack(spacing: Spacing.sm) {
                Label(
                    note.createdAt.formatted(date: .long, time: .shortened),
                    systemImage: "clock"
                )
                .font(.bodySM)
                .foregroundColor(.textSecondary)

                Text(shortId)
                    .font(.caption.monospaced())
                    .foregroundColor(.textTertiary)

                Spacer()

                Button(action: onOpen) {
                    Label(
                        String(localized: "manual_note.timeline.open"),
                        systemImage: "arrow.right"
                    )
                    .font(.bodyMedium)
                    .foregroundColor(.brandAccent)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("manual_note.timeline.open.\(note.id)")
            }
        }
        .padding(Spacing.lg)
        .surfaceCard(
            fill: Color.bgElevated.opacity(0.3),
            cornerRadius: Radius.md,
            border: Color.borderGhost.opacity(0.55),
            borderWidth: Stroke.thin
        )
        .onChange(of: note.title) { _, newValue in
            title = newValue
            savedTitle = newValue
        }
    }

    private var shortId: String {
        String(note.id.prefix(8))
    }

    private func save() {
        guard isSaving == false, title != savedTitle else { return }
        isSaving = true
        if let resolved = onSaveTitle(title) {
            title = resolved
            savedTitle = resolved
        } else {
            ToastCenter.shared.error(String(localized: "manual_note.title.save_failed"))
        }
        isSaving = false
    }
}
