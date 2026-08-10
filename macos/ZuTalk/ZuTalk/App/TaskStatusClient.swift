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
    private let coreProvider: @MainActor () -> (any ZuTalkCoreProtocol)?

    init(coreProvider: @escaping @MainActor () -> (any ZuTalkCoreProtocol)? = { CoreClient.shared.core }) {
        self.coreProvider = coreProvider
    }

    private func requireCore() throws -> any ZuTalkCoreProtocol {
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
