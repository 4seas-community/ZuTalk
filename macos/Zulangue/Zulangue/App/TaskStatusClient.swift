import Foundation

enum TaskStatusClientError: LocalizedError {
    case coreUnavailable

    var errorDescription: String? {
        switch self {
        case .coreUnavailable:
            return "Local app service is not ready yet."
        }
    }
}

@MainActor
protocol TaskStatusClienting {
    func listTasks(statusFilter: String?) throws -> [TaskInfoDto]
    func getTaskStatus(taskId: String) throws -> TaskInfoDto
}

@MainActor
struct LiveTaskStatusClient: TaskStatusClienting {
    private let coreProvider: @MainActor () -> (any ZulangueCoreProtocol)?

    init(coreProvider: @escaping @MainActor () -> (any ZulangueCoreProtocol)? = { CoreClient.shared.core }) {
        self.coreProvider = coreProvider
    }

    private func requireCore() throws -> any ZulangueCoreProtocol {
        guard let core = coreProvider() else {
            throw TaskStatusClientError.coreUnavailable
        }
        return core
    }

    func listTasks(statusFilter: String?) throws -> [TaskInfoDto] {
        try requireCore().listTasks(statusFilter: statusFilter)
    }

    func getTaskStatus(taskId: String) throws -> TaskInfoDto {
        try requireCore().getTaskStatus(taskId: taskId)
    }

}
