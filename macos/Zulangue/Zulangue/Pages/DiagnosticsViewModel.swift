import Combine
import Foundation

final class DiagnosticsViewModel: ObservableObject {
    private let client: DiagnosticsClienting

    @Published private(set) var projection: DiagnosticsProjectionSnapshot?
    @Published private(set) var errorMessage: String?

    init(client: DiagnosticsClienting) {
        self.client = client
    }

    var title: String {
        projection?.title ?? "Diagnostics"
    }

    var normalSummaryText: String {
        projection?.normalSummary ?? "No diagnostics available"
    }

    var normalSummaryLines: [String] {
        projection?.summaryItems.map(\.userSummary) ?? []
    }

    var detailGroups: [DiagnosticDetailGroupSnapshot] {
        projection?.detailGroups ?? []
    }

    var diagnosticDetailText: String {
        detailGroups
            .flatMap { group in
                group.details.map { detail in
                    "\(detail.key)=\(detail.value)"
                }
            }
            .joined(separator: "\n")
    }

    func refresh(request: DiagnosticsRequest) throws {
        do {
            projection = try client.projectDiagnostics(request)
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
            throw error
        }
    }
}
