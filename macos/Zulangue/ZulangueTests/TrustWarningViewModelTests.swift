import XCTest
@testable import Zulangue

@MainActor
final class TrustWarningViewModelTests: XCTestCase {
    func testP0NonActionableKeyStateIsNotRenderedAsError() throws {
        let client = FakeTrustWarningClient(warning: .fixture(
            severity: "info",
            state: "content_key_available",
            title: "Private content is available",
            message: "Notebook export can be opened on this Mac.",
            isActionable: false,
            actions: []
        ))
        let viewModel = TrustWarningViewModel(client: client)

        try viewModel.refresh(request: .fixture(keyState: "content_key_available"))

        XCTAssertEqual(viewModel.severity, "info")
        XCTAssertFalse(viewModel.isErrorVisible)
        XCTAssertTrue(viewModel.visibleActions.isEmpty)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(client.requests.map(\.keyState), ["content_key_available"])
    }
}

private final class FakeTrustWarningClient: TrustWarningClienting {
    var warning: TrustWarningSnapshot
    private(set) var requests: [TrustWarningRequest] = []

    init(warning: TrustWarningSnapshot) {
        self.warning = warning
    }

    func projectTrustWarning(_ request: TrustWarningRequest) throws -> TrustWarningSnapshot {
        requests.append(request)
        return warning
    }
}

private extension TrustWarningRequest {
    static func fixture(keyState: String) -> TrustWarningRequest {
        TrustWarningRequest(
            surface: "status",
            keyState: keyState,
            providerDisplayName: "Soniox",
            keyScope: "soniox",
            contentLabel: "Notebook audio",
            diagnosticHint: "key_scope=soniox"
        )
    }
}

private extension TrustWarningSnapshot {
    static func fixture(
        severity: String,
        state: String,
        title: String,
        message: String,
        isActionable: Bool,
        actions: [TrustWarningActionSnapshot]
    ) -> TrustWarningSnapshot {
        TrustWarningSnapshot(
            severity: severity,
            state: state,
            title: title,
            message: message,
            isActionable: isActionable,
            userActions: actions,
            diagnosticSummary: nil
        )
    }
}
