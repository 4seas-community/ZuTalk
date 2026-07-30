import XCTest
@testable import Zulangue

@MainActor
final class DiagnosticsViewModelTests: XCTestCase {
    func testNormalUiUsesSummaryAndDiagnosticsUsesDetail() throws {
        let client = FakeDiagnosticsClient(snapshot: .fixture())
        let viewModel = DiagnosticsViewModel(client: client)

        try viewModel.refresh(request: .fixture())

        XCTAssertEqual(viewModel.title, "Diagnostics")
        XCTAssertEqual(viewModel.normalSummaryLines, [
            "Provider credential is loaded",
            "Local credential storage is available"
        ])
        XCTAssertFalse(viewModel.normalSummaryText.localizedCaseInsensitiveContains("soniox"))
        XCTAssertFalse(viewModel.normalSummaryText.localizedCaseInsensitiveContains("app-private-file"))

        XCTAssertTrue(viewModel.diagnosticDetailText.contains("scope=soniox"))
        XCTAssertTrue(viewModel.diagnosticDetailText.contains("storage=app-private-file"))
        XCTAssertEqual(client.requests.count, 1)
    }
}

private final class FakeDiagnosticsClient: DiagnosticsClienting {
    let snapshot: DiagnosticsProjectionSnapshot
    private(set) var requests: [DiagnosticsRequest] = []

    init(snapshot: DiagnosticsProjectionSnapshot) {
        self.snapshot = snapshot
    }

    func projectDiagnostics(_ request: DiagnosticsRequest) throws -> DiagnosticsProjectionSnapshot {
        requests.append(request)
        return snapshot
    }
}

private extension DiagnosticsRequest {
    static func fixture() -> DiagnosticsRequest {
        DiagnosticsRequest(areas: [
            DiagnosticAreaRequest(
                area: "provider",
                severity: "info",
                label: "Provider credential",
                userSummary: "Provider credential is loaded",
                details: [
                    DiagnosticDetailRequest(key: "scope", label: "Scope", value: "soniox")
                ]
            )
        ])
    }
}

private extension DiagnosticsProjectionSnapshot {
    static func fixture() -> DiagnosticsProjectionSnapshot {
        DiagnosticsProjectionSnapshot(
            title: "Diagnostics",
            normalSummary: [
                "Provider credential is loaded",
                "Local credential storage is available"
            ].joined(separator: "\n"),
            summaryItems: [
                DiagnosticSummaryItemSnapshot(
                    areaId: "provider",
                    label: "Provider credential",
                    severity: "info",
                    userSummary: "Provider credential is loaded"
                ),
                DiagnosticSummaryItemSnapshot(
                    areaId: "key",
                    label: "Credential storage",
                    severity: "info",
                    userSummary: "Local credential storage is available"
                )
            ],
            detailGroups: [
                DiagnosticDetailGroupSnapshot(
                    areaId: "provider",
                    label: "Provider credential",
                    severity: "info",
                    userSummary: "Provider credential is loaded",
                    details: [
                        DiagnosticDetailSnapshot(key: "scope", label: "Scope", value: "soniox")
                    ]
                ),
                DiagnosticDetailGroupSnapshot(
                    areaId: "key",
                    label: "Credential storage",
                    severity: "info",
                    userSummary: "Local credential storage is available",
                    details: [
                        DiagnosticDetailSnapshot(
                            key: "storage",
                            label: "Storage",
                            value: "app-private-file"
                        )
                    ]
                )
            ]
        )
    }
}
