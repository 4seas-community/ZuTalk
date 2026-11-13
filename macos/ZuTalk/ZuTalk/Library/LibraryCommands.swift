import SwiftUI

/// Where 「放进主题…」 can send a recording.
enum TopicFilingChoice: Hashable {
    case topic(id: String, title: String)
    /// A topic made on the spot, named in the same sheet.
    case newTopic
    /// Out of its topic: just a recording again.
    case none
}

/// Naming, filing and deleting recordings and topics, from wherever they are
/// listed. Every change is followed by the same refresh the lists already
/// listen for.
@MainActor
enum LibraryCommands {
    @discardableResult
    static func renameRecording(id: String, to title: String) -> Bool {
        run(failure: "library.rename.failed") { core in
            try core.renameSession(sessionId: id, title: title)
        }
    }

    @discardableResult
    static func renameTopic(id: String, to title: String) -> Bool {
        run(failure: "library.rename.failed") { core in
            _ = try core.renameNotebook(notebookId: id, title: title)
        }
    }

    /// To the trash, from where it can be restored. The caller has asked
    /// first, and decides where to go once the recording is gone.
    @discardableResult
    static func moveRecordingToTrash(id: String) -> Bool {
        run(failure: "resources.delete.failed") { core in
            try core.softDeleteSession(sessionId: id)
        }
    }

    /// The topics a recording can be put into: every one but the one it is
    /// already in.
    static func topicsForFiling(excluding topicId: String?) -> [TopicFilingChoice] {
        guard let core = CoreClient.shared.core,
              let topics = try? core.listNotebooks()
        else { return [] }
        return topics
            .filter { $0.deletedAt == nil && $0.id != topicId }
            .map { .topic(id: $0.id, title: $0.title) }
    }

    /// Puts a recording — its text, audio and own notes — into a topic, or
    /// takes it back out, then follows it: the page it was opened on names
    /// the old topic's documents, which no longer hold it.
    @discardableResult
    static func fileRecording(
        id: String,
        into choice: TopicFilingChoice,
        newTopicName: String = ""
    ) -> Bool {
        var filedInto: String?
        let moved = run(failure: "library.file.failed") { core in
            switch choice {
            case .topic(let topicId, let title):
                try core.moveSessionToNotebook(sessionId: id, targetNotebookId: topicId)
                filedInto = title
            case .newTopic:
                let topic = try core.createNotebook(title: newTopicName)
                try core.moveSessionToNotebook(sessionId: id, targetNotebookId: topic.id)
                filedInto = topic.title
            case .none:
                // Storage keeps recordings that are in no topic in a topic of
                // its own; nothing on screen calls it one.
                let unfiled = try core.getQuickCaptureNotebook()
                try core.moveSessionToNotebook(sessionId: id, targetNotebookId: unfiled.id)
            }
        }
        guard moved else { return false }
        if let filedInto {
            ToastCenter.shared.success(
                String(format: String(localized: "library.file.done_format"), filedInto)
            )
        } else {
            ToastCenter.shared.success(String(localized: "library.file.taken_out"))
        }
        MainNavigationStore.shared.openSession(id)
        return true
    }

    /// Recordings in the topic are kept and become unfiled; see
    /// `delete_notebook` in the core.
    @discardableResult
    static func deleteTopic(id: String, title: String) -> Bool {
        var moved: UInt32 = 0
        let deleted = run(failure: "topic.delete.failed") { core in
            moved = try core.deleteNotebook(notebookId: id)
        }
        if deleted {
            ToastCenter.shared.success(
                String(format: String(localized: "topic.delete.done_format"), title),
                detail: moved > 0
                    ? String(format: String(localized: "topic.delete.done_moved_format"), Int64(moved))
                    : nil
            )
            MainNavigationStore.shared.navigateTopics()
        }
        return deleted
    }

    private static func run(
        failure: String.LocalizationValue,
        _ body: (any ZuTalkCoreProtocol) throws -> Void
    ) -> Bool {
        guard let core = CoreClient.shared.core else {
            ToastCenter.shared.error(String(localized: failure))
            return false
        }
        do {
            try body(core)
            NotificationCenter.default.post(name: .zutalkSessionUpdated, object: nil)
            return true
        } catch {
            ToastCenter.shared.error(String(localized: failure), detail: error.localizedDescription)
            return false
        }
    }
}

/// One text field and Save, for naming a recording or a topic.
struct RenameSheet: View {
    let title: String
    let placeholder: String
    let initialText: String
    /// A recording may be untitled; a topic may not.
    let allowsEmpty: Bool
    let onSave: (String) -> Bool

    @Environment(\.presentationMode) private var presentationMode
    @State private var text = ""
    @FocusState private var isFocused: Bool

    private var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text(title)
                .font(.titleMD)
                .foregroundColor(.textPrimary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit(save)
                .frame(minWidth: 320)
            HStack {
                Spacer()
                Button(String(localized: "common.cancel")) {
                    presentationMode.wrappedValue.dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(String(localized: "common.save"), action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(allowsEmpty == false && trimmed.isEmpty)
            }
        }
        .padding(Spacing.lg)
        .onAppear {
            text = initialText
            isFocused = true
        }
    }

    private func save() {
        guard allowsEmpty || trimmed.isEmpty == false else { return }
        if onSave(trimmed) {
            presentationMode.wrappedValue.dismiss()
        }
    }
}

/// 「放进主题…」 for one recording: choose a topic, make a new one here, or
/// take the recording back out. The destination is always chosen, never
/// assumed from whichever topic happens to be open — a recording filed in the
/// wrong place is silent and easy to miss.
struct FileIntoTopicSheet: View {
    /// Every topic the recording is not already in.
    let topics: [TopicFilingChoice]
    /// The recording sits in a topic now, so "none" is somewhere it can go.
    let isInTopic: Bool
    /// Returns whether it worked; the sheet stays up when it did not.
    let onConfirm: (TopicFilingChoice, String) -> Bool

    @Environment(\.presentationMode) private var presentationMode
    @State private var choice: TopicFilingChoice = .newTopic
    @State private var newTopicName = ""
    @FocusState private var isNameFocused: Bool

    private var trimmedName: String {
        newTopicName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canConfirm: Bool {
        guard choice == .newTopic else { return true }
        return trimmedName.isEmpty == false
            && trimmedName.count <= LibraryViewModel.notebookTitleMaxLength
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text(String(localized: "library.file.title"))
                    .font(.titleMD)
                    .foregroundColor(.textPrimary)
                Text(String(localized: "library.file.message"))
                    .font(.bodySM)
                    .foregroundColor(.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Picker("", selection: $choice) {
                ForEach(topics, id: \.self) { topic in
                    if case .topic(_, let title) = topic {
                        Text(title).tag(topic)
                    }
                }
                if topics.isEmpty == false {
                    Divider()
                }
                Text(String(localized: "library.file.new_topic")).tag(TopicFilingChoice.newTopic)
                if isInTopic {
                    Text(String(localized: "library.file.no_topic")).tag(TopicFilingChoice.none)
                }
            }
            .labelsHidden()
            .accessibilityLabel(String(localized: "library.file.title"))
            .accessibilityIdentifier("library.file.picker")

            if choice == .newTopic {
                TextField(String(localized: "library.file.new_topic_placeholder"), text: $newTopicName)
                    .textFieldStyle(.roundedBorder)
                    .focused($isNameFocused)
                    .onSubmit(confirm)
                    .accessibilityIdentifier("library.file.new_topic_name")
            }

            HStack(spacing: Spacing.sm) {
                Spacer()
                Button(String(localized: "common.cancel")) {
                    presentationMode.wrappedValue.dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(
                    String(localized: choice == .none
                        ? "library.file.take_out"
                        : "library.file.action"),
                    action: confirm
                )
                .keyboardShortcut(.defaultAction)
                .disabled(canConfirm == false)
                .accessibilityIdentifier("library.file.confirm")
            }
        }
        .padding(Spacing.xl)
        .frame(width: 440)
        .background(Color.bgRoot)
        .onAppear {
            // An existing topic is the likelier answer; with none yet, the
            // sheet opens ready to name the first one.
            if let first = topics.first {
                choice = first
            } else {
                isNameFocused = true
            }
        }
        .montereyOnChange(of: choice) { _, newChoice in
            if newChoice == .newTopic { isNameFocused = true }
        }
    }

    private func confirm() {
        guard canConfirm else { return }
        if onConfirm(choice, trimmedName) {
            presentationMode.wrappedValue.dismiss()
        }
    }
}

/// A topic an action is about to apply to.
struct TopicReference: Identifiable, Equatable {
    let id: String
    let title: String
    let recordingCount: Int
}

/// Rename, Collaborate and Delete for a topic, for its card's context menu and its page.
struct TopicActionsMenu: View {
    let topicID: String
    let title: String
    let recordingCount: Int
    @Binding var renaming: TopicReference?
    @Binding var deleting: TopicReference?
    @Binding var collaborating: TopicReference?

    var body: some View {
        let topic = TopicReference(id: topicID, title: title, recordingCount: recordingCount)
        Button {
            renaming = topic
        } label: {
            Label(String(localized: "library.rename.topic"), systemImage: "pencil")
        }
        Button {
            collaborating = topic
        } label: {
            Label(String(localized: "topic.collab.menu"), systemImage: "person.2")
        }
        Divider()
        Button(role: .destructive) {
            deleting = topic
        } label: {
            Label(String(localized: "topic.delete"), systemImage: "trash")
        }
    }
}

extension View {
    /// The rename sheet, collaboration sheet and delete confirmation that
    /// `TopicActionsMenu` asks for.
    func topicActionSheets(
        renaming: Binding<TopicReference?>,
        deleting: Binding<TopicReference?>,
        collaborating: Binding<TopicReference?>
    ) -> some View {
        sheet(item: collaborating) { topic in
            TopicCollaborationSheet(topicID: topic.id, title: topic.title)
        }
        .sheet(item: renaming) { topic in
            RenameSheet(
                title: String(localized: "library.rename.topic"),
                placeholder: String(localized: "home.notebook.new.help"),
                initialText: topic.title,
                allowsEmpty: false
            ) { title in
                LibraryCommands.renameTopic(id: topic.id, to: title)
            }
        }
        .confirmationDialog(
            String(
                format: String(localized: "topic.delete.confirm_title"),
                deleting.wrappedValue?.title ?? ""
            ),
            isPresented: Binding(
                get: { deleting.wrappedValue != nil },
                set: { if $0 == false { deleting.wrappedValue = nil } }
            ),
            titleVisibility: .visible,
            presenting: deleting.wrappedValue
        ) { topic in
            Button(String(localized: "topic.delete.confirm_button"), role: .destructive) {
                LibraryCommands.deleteTopic(id: topic.id, title: topic.title)
            }
            Button(String(localized: "common.cancel"), role: .cancel) {}
        } message: { topic in
            Text(topicDeleteMessage(for: topic))
        }
    }
}

@MainActor
private func topicDeleteMessage(for topic: TopicReference) -> String {
    let base = topic.recordingCount > 0
        ? String(
            format: String(localized: "topic.delete.confirm_message_format"),
            Int64(topic.recordingCount)
        )
        : String(localized: "topic.delete.confirm_message_empty")
    // 共享中的主题:删掉之前先退出协作(发起人删则所有人都不再同步)。
    guard let collab = DeviceSyncStore.shared.topicStatus(notebookId: topic.id), collab.shared else {
        return base
    }
    return base + "\n\n" + (collab.isOwner
        ? String(localized: "topic.collab.delete_note_owner")
        : String(localized: "topic.collab.delete_note_member"))
}
