import SwiftUI

/// Naming recordings and topics, and deleting a topic, from wherever they are
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

/// A topic an action is about to apply to.
struct TopicReference: Identifiable, Equatable {
    let id: String
    let title: String
    let recordingCount: Int
}

/// Rename and Delete for a topic, for its card's context menu and its page.
struct TopicActionsMenu: View {
    let topicID: String
    let title: String
    let recordingCount: Int
    @Binding var renaming: TopicReference?
    @Binding var deleting: TopicReference?

    var body: some View {
        let topic = TopicReference(id: topicID, title: title, recordingCount: recordingCount)
        Button {
            renaming = topic
        } label: {
            Label(String(localized: "library.rename.topic"), systemImage: "pencil")
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
    /// The rename sheet and delete confirmation that `TopicActionsMenu` asks for.
    func topicActionSheets(
        renaming: Binding<TopicReference?>,
        deleting: Binding<TopicReference?>
    ) -> some View {
        sheet(item: renaming) { topic in
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
            Text(topic.recordingCount > 0
                ? String(
                    format: String(localized: "topic.delete.confirm_message_format"),
                    Int64(topic.recordingCount)
                )
                : String(localized: "topic.delete.confirm_message_empty"))
        }
    }
}
