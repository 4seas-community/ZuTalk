import Foundation

struct TrustWarningActionSnapshot: Equatable {
    let actionId: String
    let label: String
    let actionKind: String
    let enabled: Bool
}

struct TrustWarningSnapshot: Equatable {
    let severity: String
    let state: String
    let title: String
    let message: String
    let isActionable: Bool
    let userActions: [TrustWarningActionSnapshot]
    let diagnosticSummary: String?
}

struct TrustWarningRequest: Equatable {
    let surface: String
    let keyState: String
    let providerDisplayName: String?
    let keyScope: String?
    let contentLabel: String?
    let diagnosticHint: String?
}

protocol TrustWarningClienting {
    func projectTrustWarning(_ request: TrustWarningRequest) throws -> TrustWarningSnapshot
}

struct TrustWarningClient: TrustWarningClienting {
    let core: ZulangueCore

    func projectTrustWarning(_ request: TrustWarningRequest) throws -> TrustWarningSnapshot {
        try TrustWarningSnapshot(ffi: core.projectTrustWarning(input: request.ffiValue))
    }
}

extension TrustWarningActionSnapshot {
    nonisolated init(ffi: FfiTrustUserAction) {
        self.actionId = ffi.actionId
        self.label = ffi.label
        self.actionKind = ffi.actionKind
        self.enabled = ffi.enabled
    }
}

extension TrustWarningSnapshot {
    init(ffi: FfiTrustWarning) {
        self.severity = ffi.severity
        self.state = ffi.state
        self.title = ffi.title
        self.message = ffi.message
        self.isActionable = ffi.isActionable
        self.userActions = ffi.userActions.map(TrustWarningActionSnapshot.init)
        self.diagnosticSummary = ffi.diagnosticSummary
    }
}

extension TrustWarningRequest {
    var ffiValue: FfiTrustWarningInput {
        FfiTrustWarningInput(
            surface: ffiSurface,
            keyState: ffiKeyState,
            providerDisplayName: providerDisplayName,
            keyScope: keyScope,
            contentLabel: contentLabel,
            diagnosticHint: diagnosticHint
        )
    }

    private var ffiSurface: FfiTrustSurface {
        switch surface {
        case "settings":
            .settings
        case "diagnostics":
            .diagnostics
        default:
            .status
        }
    }

    private var ffiKeyState: FfiTrustKeyState {
        switch keyState {
        case "provider_api_key_healthy":
            .providerApiKeyHealthy
        case "provider_api_key_missing":
            .providerApiKeyMissing
        case "provider_api_key_untested":
            .providerApiKeyUntested
        case "provider_api_key_rejected":
            .providerApiKeyRejected
        case "content_key_available":
            .contentKeyAvailable
        case "content_key_missing":
            .contentKeyMissing
        case "content_key_destroyed":
            .contentKeyDestroyed
        default:
            .unknown
        }
    }
}
