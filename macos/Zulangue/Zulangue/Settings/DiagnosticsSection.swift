// DiagnosticsSection.swift
// 诊断设置 — debug 模式开关 + 日志文件查看
// 权威:design-system/MASTER.md §10

import AppKit
import Combine
import SwiftUI

struct DiagnosticsSection: View {
    @AppStorage(DebugModeKey.enabled) private var debugEnabled: Bool = false
    @StateObject private var projectionDiagnostics = SettingsProjectionDiagnosticsViewModel()
    @State private var logFileSize: String = "—"
    @State private var crashFileSize: String = "—"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                SettingsSectionHeader(
                    title: String(localized: "diagnostics.title"),
                    subtitle: String(localized: "diagnostics.subtitle")
                )

                debugModeCard

                operationalFactsCard

                logFileCard

                crashFileCard
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.vertical, Spacing.lg)
        }
        .onAppear {
            refreshFileSizes()
            projectionDiagnostics.refresh()
        }
    }

    // MARK: - Debug mode toggle

    private var debugModeCard: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Toggle(isOn: $debugEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("diagnostics.debug_mode")
                        .font(.bodyMedium)
                        .foregroundColor(.bpLine)
                    Text("diagnostics.debug_mode_desc")
                        .font(.captionMedium)
                        .foregroundColor(.textOnBpDim)
                }
            }
            .toggleStyle(.switch)
            .tint(.brandAccent)
        }
        .padding(Spacing.md)
        .background(Color.bpBlueDeep)
        .overlay(
            RoundedRectangle(cornerRadius: Radius.sm)
                .strokeBorder(Color.bpLineGhost.opacity(0.4), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
    }

    private var operationalFactsCard: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("diagnostics.operational.title")
                        .font(.bodyMedium)
                        .foregroundColor(.bpLine)
                    Text("diagnostics.operational.subtitle")
                        .font(.captionMedium)
                        .foregroundColor(.textOnBpDim)
                        .lineLimit(2)
                }
                Spacer()
                OutlineButton(
                    title: String(localized: "diagnostics.operational.refresh"),
                    icon: "arrow.clockwise",
                    style: .ghost
                ) {
                    projectionDiagnostics.refresh()
                }
            }

            if projectionDiagnostics.summaryRows.isEmpty {
                Text("diagnostics.operational.not_loaded")
                    .font(.caption)
                    .foregroundColor(.textOnBpFaint)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(projectionDiagnostics.summaryRows, id: \.areaId) { item in
                        DiagnosticsProjectionSummaryRow(
                            item: item,
                            statusText: statusText(item.severity),
                            statusColor: statusColor(item.severity)
                        )
                    }
                }
            }

            if let trustWarning = projectionDiagnostics.trustWarning,
               trustWarning.isActionable {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(statusColor(trustWarning.severity))
                    Text(trustWarning.message)
                        .font(.caption)
                        .foregroundColor(statusColor(trustWarning.severity))
                        .lineLimit(2)
                }
            }

            if let lastError = projectionDiagnostics.lastError {
                Text(lastError)
                    .font(.caption)
                    .foregroundColor(.signalRed)
                    .lineLimit(2)
            }
        }
        .padding(Spacing.md)
        .background(Color.bpBlueDeep)
        .overlay(
            RoundedRectangle(cornerRadius: Radius.sm)
                .strokeBorder(Color.bpLineGhost.opacity(0.4), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
    }

    // MARK: - Log file card

    private var logFileCard: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("diagnostics.log_file")
                        .font(.bodyMedium)
                        .foregroundColor(.bpLine)
                    Text(DebugLog.logFileURL.path)
                        .font(.captionMedium)
                        .foregroundColor(.textOnBpFaint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Text(logFileSize)
                    .font(.captionMedium.monospacedDigit())
                    .foregroundColor(.textOnBpFaint)
            }

            HStack(spacing: Spacing.sm) {
                OutlineButton(title: String(localized: "diagnostics.reveal_finder"), icon: "folder", style: .ghost) {
                    NSWorkspace.shared.activateFileViewerSelecting([DebugLog.logFileURL])
                }
                OutlineButton(title: String(localized: "diagnostics.open_console"), icon: "doc.text", style: .ghost) {
                    NSWorkspace.shared.open(DebugLog.logFileURL)
                }
                Spacer()
                OutlineButton(title: String(localized: "diagnostics.clear_log"), icon: "trash", style: .ghost) {
                    DebugLog.clearLog()
                    refreshFileSizes()
                }
            }
        }
        .padding(Spacing.md)
        .background(Color.bpBlueDeep)
        .overlay(
            RoundedRectangle(cornerRadius: Radius.sm)
                .strokeBorder(Color.bpLineGhost.opacity(0.4), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
    }

    private var crashFileCard: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("diagnostics.crash_file")
                        .font(.bodyMedium)
                        .foregroundColor(.bpLine)
                    Text(CrashDiagnostics.crashReportURL.path)
                        .font(.captionMedium)
                        .foregroundColor(.textOnBpFaint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Text(crashFileSize)
                    .font(.captionMedium.monospacedDigit())
                    .foregroundColor(.textOnBpFaint)
            }

            HStack(spacing: Spacing.sm) {
                OutlineButton(title: String(localized: "diagnostics.reveal_finder"), icon: "folder", style: .ghost) {
                    NSWorkspace.shared.activateFileViewerSelecting([CrashDiagnostics.crashReportURL])
                }
                OutlineButton(title: String(localized: "diagnostics.open_console"), icon: "doc.text", style: .ghost) {
                    NSWorkspace.shared.open(CrashDiagnostics.crashReportURL)
                }
                Spacer()
                OutlineButton(title: String(localized: "diagnostics.clear_log"), icon: "trash", style: .ghost) {
                    CrashDiagnostics.clearCrashReport()
                    refreshFileSizes()
                }
            }
        }
        .padding(Spacing.md)
        .background(Color.bpBlueDeep)
        .overlay(
            RoundedRectangle(cornerRadius: Radius.sm)
                .strokeBorder(Color.bpLineGhost.opacity(0.4), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
    }

    private func refreshFileSizes() {
        logFileSize = formattedFileSize(
            at: DebugLog.logFileURL,
            missingValue: String(localized: "diagnostics.no_log_file")
        )
        crashFileSize = formattedFileSize(
            at: CrashDiagnostics.crashReportURL,
            missingValue: String(localized: "diagnostics.no_crash_file")
        )
    }

    private func formattedFileSize(at url: URL, missingValue: String) -> String {
        guard
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = (attrs[.size] as? NSNumber)?.uint64Value
        else {
            return missingValue
        }
        let kb = Double(size) / 1024.0
        if kb < 1024 {
            return String(format: "%.1f KB", kb)
        } else {
            return String(format: "%.2f MB", kb / 1024)
        }
    }

    private func statusColor(_ severity: String) -> Color {
        switch severity {
        case "blocked":
            .signalRed
        case "warning":
            .signalAmber
        default:
            .bpLine
        }
    }

    private func statusText(_ severity: String) -> String {
        switch severity {
        case "blocked":
            String(localized: "diagnostics.operational.severity.blocked")
        case "warning":
            String(localized: "diagnostics.operational.severity.warning")
        default:
            String(localized: "diagnostics.operational.severity.info")
        }
    }
}

private struct DiagnosticsProjectionSummaryRow: View {
    let item: DiagnosticSummaryItemSnapshot
    let statusText: String
    let statusColor: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
                .alignmentGuide(.firstTextBaseline) { dimensions in
                    dimensions[VerticalAlignment.center]
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.label)
                    .font(.captionMedium)
                    .foregroundColor(.bpLine)
                    .lineLimit(1)
                Text(item.userSummary)
                    .font(.caption)
                    .foregroundColor(.textOnBpDim)
                    .lineLimit(2)
            }

            Spacer(minLength: Spacing.sm)

            Text(statusText)
                .font(.caption2.monospaced())
                .foregroundColor(statusColor)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.label), \(item.userSummary), \(statusText)")
    }
}

struct SettingsProviderDiagnosticsState: Equatable {
    let configuredCount: Int
    let mirrorMismatchCount: Int

    var trustKeyState: String? {
        if mirrorMismatchCount > 0 {
            return "provider_api_key_untested"
        }
        // Runtime state proves only that the saved key was loaded. It does
        // not prove provider connectivity or credential validity, so Settings
        // must not project the "healthy / ready" trust state here.
        return nil
    }

    var severity: String {
        mirrorMismatchCount > 0 ? "warning" : "info"
    }

    static func resolve(
        _ snapshot: [ProviderCredentialSnapshot]
    ) -> SettingsProviderDiagnosticsState {
        SettingsProviderDiagnosticsState(
            configuredCount: snapshot.filter { $0.isSaved || $0.isActive }.count,
            mirrorMismatchCount: snapshot.filter { $0.isSaved != $0.isActive }.count
        )
    }
}

@MainActor
final class SettingsProjectionDiagnosticsViewModel: ObservableObject {
    @Published private(set) var projection: DiagnosticsProjectionSnapshot?
    @Published private(set) var trustWarning: TrustWarningSnapshot?
    @Published private(set) var lastError: String?

    var summaryRows: [DiagnosticSummaryItemSnapshot] {
        projection?.summaryItems ?? []
    }

    func refresh() {
        guard let core = CoreClient.shared.core else {
            projection = nil
            trustWarning = nil
            lastError = "Local app service is not ready yet."
            return
        }

        do {
            let snapshot = ProviderCredentialSession.shared.snapshot()
            let providerState = SettingsProviderDiagnosticsState.resolve(snapshot)
            var areas = [providerArea(snapshot, state: providerState)]

            if let trustKeyState = providerState.trustKeyState {
                let trust = try TrustWarningClient(core: core).projectTrustWarning(
                    TrustWarningRequest(
                        surface: "settings",
                        keyState: trustKeyState,
                        providerDisplayName: String(localized: "diagnostics.operational.provider_keys"),
                        keyScope: "settings_api_keys",
                        contentLabel: nil,
                        diagnosticHint: "settings_diagnostics"
                    )
                )
                trustWarning = trust
                areas.append(
                    DiagnosticAreaRequest(
                        area: "key",
                        severity: trust.severity,
                        label: String(localized: "diagnostics.operational.privacy"),
                        userSummary: trust.title,
                        details: [
                            DiagnosticDetailRequest(
                                key: "trust_state",
                                label: String(localized: "diagnostics.operational.detail.state"),
                                value: trust.state
                            ),
                            DiagnosticDetailRequest(
                                key: "actionable",
                                label: String(localized: "diagnostics.operational.detail.actionable"),
                                value: "\(trust.isActionable)"
                            )
                        ]
                    )
                )
            } else {
                trustWarning = nil
            }

            projection = try DiagnosticsClient(core: core).projectDiagnostics(
                DiagnosticsRequest(areas: areas)
            )

            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
    }

    private func providerArea(
        _ snapshot: [ProviderCredentialSnapshot],
        state: SettingsProviderDiagnosticsState
    ) -> DiagnosticAreaRequest {
        let summary: String
        if state.mirrorMismatchCount == 0 {
            summary = state.configuredCount == 0
                ? String(localized: "diagnostics.operational.provider_optional_off")
                : String.localizedStringWithFormat(
                    String(localized: "diagnostics.operational.provider_configured_format"),
                    state.configuredCount
                )
        } else {
            summary = String.localizedStringWithFormat(
                String(localized: "diagnostics.operational.provider_inactive_format"),
                state.mirrorMismatchCount
            )
        }
        return DiagnosticAreaRequest(
            area: "provider",
            severity: state.severity,
            label: String(localized: "diagnostics.operational.provider_keys"),
            userSummary: summary,
            details: snapshot.map { entry in
                return DiagnosticDetailRequest(
                    key: "provider_scope_\(entry.account.rawValue)",
                    label: entry.account.displayName,
                    value: credentialDetailValue(entry)
                )
            }
        )
    }

    private func credentialDetailValue(_ snapshot: ProviderCredentialSnapshot) -> String {
        ProviderCredentialPresentationState.resolve(snapshot).localizedStatusTitle
    }
}

#if DEBUG
struct DiagnosticsSection_Previews: PreviewProvider {
    static var previews: some View {
        DiagnosticsSection()
            .frame(width: 700, height: 500)
            .background(Color.bpBlue)
            .preferredColorScheme(.dark)
    }
}
#endif
