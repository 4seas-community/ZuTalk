import Foundation

enum NotebookWorkspaceClientError: LocalizedError {
    case coreUnavailable

    var errorDescription: String? {
        switch self {
        case .coreUnavailable:
            return "Local app service is not ready yet."
        }
    }
}

@MainActor
protocol NotebookWorkspaceClienting {
    func listNotebooks() throws -> [FfiNotebook]
    func createNotebook(title: String?) throws -> FfiNotebook
    func listNotebookTabs(notebookId: String) throws -> [FfiNotebookTab]
    func listNotebookSessions(notebookId: String) throws -> [FfiNotebookSessionLink]
    func listNotebookSessionProjections(tabId: String) throws -> [FfiNotebookSessionProjection]
}

/// The audio decoder and encrypted-blob writer can take seconds for a long
/// recording. Keep this narrow client Sendable so imports can run outside the
/// MainActor while Notebook workspace reads continue to stay UI-isolated.
protocol NotebookAudioImporting: Sendable {
    func importAudioIntoNotebook(
        path: String,
        notebookId: String
    ) throws -> ImportResultInfo
}

struct LiveNotebookAudioImporter: NotebookAudioImporting {
    private let core: any ZuTalkCoreProtocol

    init(core: any ZuTalkCoreProtocol) {
        self.core = core
    }

    func importAudioIntoNotebook(
        path: String,
        notebookId: String
    ) throws -> ImportResultInfo {
        try core.importAudioIntoNotebook(
            path: path,
            notebookId: notebookId
        )
    }
}

@MainActor
struct LiveNotebookWorkspaceClient: NotebookWorkspaceClienting {
    private let coreProvider: @MainActor () -> (any ZuTalkCoreProtocol)?

    init(coreProvider: @escaping @MainActor () -> (any ZuTalkCoreProtocol)? = { CoreClient.shared.core }) {
        self.coreProvider = coreProvider
    }

    private func requireCore() throws -> any ZuTalkCoreProtocol {
        guard let core = coreProvider() else {
            throw NotebookWorkspaceClientError.coreUnavailable
        }
        return core
    }

    func listNotebooks() throws -> [FfiNotebook] {
        try requireCore().listNotebooks()
    }

    func createNotebook(title: String?) throws -> FfiNotebook {
        try requireCore().createNotebook(title: title)
    }

    func listNotebookTabs(notebookId: String) throws -> [FfiNotebookTab] {
        try requireCore().listNotebookTabs(notebookId: notebookId)
    }

    func listNotebookSessions(notebookId: String) throws -> [FfiNotebookSessionLink] {
        try requireCore().listNotebookSessions(notebookId: notebookId)
    }

    func listNotebookSessionProjections(tabId: String) throws -> [FfiNotebookSessionProjection] {
        try requireCore().listNotebookSessionProjections(tabId: tabId)
    }

}
