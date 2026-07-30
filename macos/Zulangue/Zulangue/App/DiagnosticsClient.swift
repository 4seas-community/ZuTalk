import Foundation

struct DiagnosticDetailRequest: Equatable {
    let key: String
    let label: String
    let value: String
}

struct DiagnosticAreaRequest: Equatable {
    let area: String
    let severity: String
    let label: String
    let userSummary: String
    let details: [DiagnosticDetailRequest]
}

struct DiagnosticsRequest: Equatable {
    let areas: [DiagnosticAreaRequest]
}

struct DiagnosticSummaryItemSnapshot: Equatable {
    let areaId: String
    let label: String
    let severity: String
    let userSummary: String
}

struct DiagnosticDetailSnapshot: Equatable {
    let key: String
    let label: String
    let value: String
}

struct DiagnosticDetailGroupSnapshot: Equatable {
    let areaId: String
    let label: String
    let severity: String
    let userSummary: String
    let details: [DiagnosticDetailSnapshot]
}

struct DiagnosticsProjectionSnapshot: Equatable {
    let title: String
    let normalSummary: String
    let summaryItems: [DiagnosticSummaryItemSnapshot]
    let detailGroups: [DiagnosticDetailGroupSnapshot]
}

protocol DiagnosticsClienting {
    func projectDiagnostics(_ request: DiagnosticsRequest) throws -> DiagnosticsProjectionSnapshot
}

struct DiagnosticsClient: DiagnosticsClienting {
    let core: ZulangueCore

    func projectDiagnostics(_ request: DiagnosticsRequest) throws -> DiagnosticsProjectionSnapshot {
        try DiagnosticsProjectionSnapshot(ffi: core.projectDiagnostics(input: request.ffiValue))
    }
}

extension DiagnosticDetailRequest {
    var ffiValue: FfiDiagnosticDetailInput {
        FfiDiagnosticDetailInput(key: key, label: label, value: value)
    }
}

extension DiagnosticAreaRequest {
    var ffiValue: FfiDiagnosticAreaInput {
        FfiDiagnosticAreaInput(
            area: ffiArea,
            severity: ffiSeverity,
            label: label,
            userSummary: userSummary,
            details: details.map(\.ffiValue)
        )
    }

    private var ffiArea: FfiDiagnosticArea {
        switch area {
        case "provider":
            .provider
        case "audio":
            .audio
        case "key":
            .key
        default:
            .unknown
        }
    }

    private var ffiSeverity: FfiDiagnosticSeverity {
        switch severity {
        case "warning":
            .warning
        case "blocked":
            .blocked
        default:
            .info
        }
    }
}

extension DiagnosticsRequest {
    var ffiValue: FfiDiagnosticsProjectionInput {
        FfiDiagnosticsProjectionInput(areas: areas.map(\.ffiValue))
    }
}

extension DiagnosticSummaryItemSnapshot {
    nonisolated init(ffi: FfiDiagnosticSummaryItem) {
        self.areaId = ffi.areaId
        self.label = ffi.label
        self.severity = ffi.severity
        self.userSummary = ffi.userSummary
    }
}

extension DiagnosticDetailSnapshot {
    nonisolated init(ffi: FfiDiagnosticDetailItem) {
        self.key = ffi.key
        self.label = ffi.label
        self.value = ffi.value
    }
}

extension DiagnosticDetailGroupSnapshot {
    nonisolated init(ffi: FfiDiagnosticDetailGroup) {
        self.areaId = ffi.areaId
        self.label = ffi.label
        self.severity = ffi.severity
        self.userSummary = ffi.userSummary
        self.details = ffi.details.map(DiagnosticDetailSnapshot.init)
    }
}

extension DiagnosticsProjectionSnapshot {
    nonisolated init(ffi: FfiDiagnosticsProjection) {
        self.title = ffi.title
        self.normalSummary = ffi.normalSummary
        self.summaryItems = ffi.summaryItems.map(DiagnosticSummaryItemSnapshot.init)
        self.detailGroups = ffi.detailGroups.map(DiagnosticDetailGroupSnapshot.init)
    }
}
