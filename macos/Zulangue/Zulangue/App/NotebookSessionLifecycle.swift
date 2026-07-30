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
    static let shared = NotebookSessionContextStore()

    @Published private(set) var activeNotebookId: String?
    @Published private(set) var activeNotebookTitle: String?

    init(activeNotebookId: String? = nil, activeNotebookTitle: String? = nil) {
        self.activeNotebookId = activeNotebookId
        self.activeNotebookTitle = activeNotebookTitle
    }

    func updateActiveNotebook(id: String, title: String?) {
        activeNotebookId = id
        activeNotebookTitle = title
    }

    func clearActiveNotebook() {
        activeNotebookId = nil
        activeNotebookTitle = nil
    }

    func requireActiveNotebookId() throws -> String {
        guard let activeNotebookId, activeNotebookId.isEmpty == false else {
            throw NotebookSessionLifecycleError.notebookRequired
        }
        return activeNotebookId
    }
}
