import Combine
import Foundation

final class TrustWarningViewModel: ObservableObject {
    private let client: TrustWarningClienting

    @Published private(set) var warning: TrustWarningSnapshot?
    @Published private(set) var errorMessage: String?

    init(client: TrustWarningClienting) {
        self.client = client
    }

    var severity: String {
        warning?.severity ?? "info"
    }

    var title: String {
        warning?.title ?? "Key status unavailable"
    }

    var message: String {
        warning?.message ?? "Open diagnostics to inspect key status."
    }

    var isErrorVisible: Bool {
        guard let warning else { return false }
        return warning.severity == "blocked" && warning.isActionable
    }

    var visibleActions: [TrustWarningActionSnapshot] {
        warning?.userActions.filter(\.enabled) ?? []
    }

    var diagnosticSummary: String? {
        warning?.diagnosticSummary
    }

    func refresh(request: TrustWarningRequest) throws {
        do {
            warning = try client.projectTrustWarning(request)
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
            throw error
        }
    }
}
