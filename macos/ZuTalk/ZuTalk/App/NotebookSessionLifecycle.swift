import Combine
import Foundation

enum NotebookSessionLifecycleError: LocalizedError {
    case notebookRequired

    var errorDescription: String? {
        switch self {
        case .notebookRequired:
            return "Select a notebook before starting capture."
        }
    }
}

@MainActor
final class NotebookSessionContextStore: ObservableObject {
    static let shared = NotebookSessionContextStore(
        defaults: TestEnvironment.isAnyTestMode ? nil : .standard
    )

    private enum DefaultsKey {
        static let lastUsedNotebookID = "notebook.lastUsed.id"
    }

    @Published private(set) var activeNotebookId: String?
    @Published private(set) var activeNotebookTitle: String?

    private let defaults: UserDefaults?

    init(
        activeNotebookId: String? = nil,
        activeNotebookTitle: String? = nil,
        defaults: UserDefaults? = nil
    ) {
        self.defaults = defaults
        let requestedID = Self.normalized(activeNotebookId)
        let storedID = Self.normalized(
            defaults?.string(forKey: DefaultsKey.lastUsedNotebookID)
        )
        self.activeNotebookId = requestedID ?? storedID
        self.activeNotebookTitle = activeNotebookTitle
        if storedID == nil {
            defaults?.removeObject(forKey: DefaultsKey.lastUsedNotebookID)
        }
    }

    func updateActiveNotebook(id: String, title: String?) {
        guard let id = Self.normalized(id) else {
            forgetLastNotebook()
            return
        }
        activeNotebookId = id
        activeNotebookTitle = title
        defaults?.set(id, forKey: DefaultsKey.lastUsedNotebookID)
    }

    /// Clears only the process-local selection. A transient workspace failure
    /// must not erase the last Notebook that was successfully opened.
    func clearActiveNotebook() {
        activeNotebookId = nil
        activeNotebookTitle = nil
    }

    /// Removes the durable selection after a successful empty-workspace load.
    func forgetLastNotebook() {
        clearActiveNotebook()
        defaults?.removeObject(forKey: DefaultsKey.lastUsedNotebookID)
    }

    func requireActiveNotebookId() throws -> String {
        guard let activeNotebookId, activeNotebookId.isEmpty == false else {
            throw NotebookSessionLifecycleError.notebookRequired
        }
        return activeNotebookId
    }

    private static func normalized(_ id: String?) -> String? {
        let normalized = id?.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.flatMap { $0.isEmpty ? nil : $0 }
    }
}
