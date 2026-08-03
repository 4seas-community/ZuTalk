import Combine
import SwiftUI

enum ProviderCredentialDeletionTarget: Equatable {
    case account(ProviderCredentialAccount)
    case savedCredentialFile
}

enum ProviderCredentialEditorCommitDecision: Equatable {
    case keepEditing
    case dismissReplacement
    case apply(String)

    static func resolve(rawValue: String, isConfigured: Bool) -> Self {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty == false else {
            return isConfigured ? .dismissReplacement : .keepEditing
        }
        return .apply(normalized)
    }
}

struct ProviderConnectionVerificationFailure: LocalizedError {
    let state: ProviderConnectionVerificationState

    init(_ state: ProviderConnectionVerificationState) {
        self.state = state
    }

    var errorDescription: String? {
        switch state {
        case .invalidCredential:
            String(localized: "settings.credentials.verification.invalid")
        case .organizationBalanceExhausted:
            String(localized: "settings.credentials.verification.organization_balance_exhausted")
        case .organizationMonthlyBudgetExhausted:
            String(localized: "settings.credentials.verification.organization_budget_exhausted")
        case .projectMonthlyBudgetExhausted:
            String(localized: "settings.credentials.verification.project_budget_exhausted")
        case .quotaExhausted:
            String(localized: "settings.credentials.verification.quota_exhausted")
        case .networkUnavailable:
            String(localized: "settings.credentials.verification.network_unavailable")
        case .rateLimited:
            String(localized: "settings.credentials.verification.rate_limited")
        case .serviceUnavailable, .unverified, .checking, .ready:
            String(localized: "settings.credentials.verification.service_unavailable")
        }
    }
}

/// Global Settings owns service credentials only. Notebook-specific capture
/// mode, languages, remote-processing consent and Context Packs stay inside
/// the Notebook that will use them.
@MainActor
final class ProviderConnectionsViewModel: ObservableObject {
    @Published private(set) var snapshots: [ProviderCredentialAccount: ProviderCredentialSnapshot] = [:]
    @Published private(set) var recoveryError: String?
    @Published private(set) var operationError: String?
    @Published private(set) var pendingDeletion: ProviderCredentialDeletionTarget?

    private let credentialSession: any ProviderCredentialSessioning
    private let verificationStore: ProviderConnectionVerificationStore

    init(
        credentialSession: (any ProviderCredentialSessioning)? = nil,
        verificationStore: ProviderConnectionVerificationStore? = nil
    ) {
        self.credentialSession = credentialSession ?? ProviderCredentialSession.shared
        self.verificationStore = verificationStore ?? .shared
        refresh()
    }

    func refresh() {
        snapshots = Dictionary(
            uniqueKeysWithValues: credentialSession.snapshot().map { ($0.account, $0) }
        )
        recoveryError = credentialSession.recoveryErrorDescription
    }

    func apply(_ value: String, for account: ProviderCredentialAccount) throws {
        do {
            try credentialSession.apply(value, for: account)
            operationError = nil
            refresh()
        } catch {
            operationError = error.localizedDescription
            refresh()
            throw error
        }
    }

    func verifySavedCredential(for account: ProviderCredentialAccount) {
        verificationStore.verifyIfNeeded(
            account: account,
            isConfigured: snapshot(for: account).isActive,
            force: true
        )
    }

    func verifyAndApply(
        _ value: String,
        for account: ProviderCredentialAccount
    ) async throws {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw ProviderCredentialSessionError.emptyValue
        }

        let verification = await verificationStore.verifyCandidate(
            normalized,
            for: account
        )
        guard verification.isReady else {
            let error = ProviderConnectionVerificationFailure(verification)
            operationError = error.localizedDescription
            throw error
        }

        do {
            try credentialSession.apply(normalized, for: account)
            operationError = nil
            refresh()
        } catch {
            verificationStore.reset(account)
            operationError = error.localizedDescription
            refresh()
            throw error
        }
    }

    func requestDeletion(_ target: ProviderCredentialDeletionTarget) {
        pendingDeletion = target
    }

    func cancelDeletion() {
        pendingDeletion = nil
    }

    func confirmDeletion() {
        guard let target = pendingDeletion else { return }
        pendingDeletion = nil

        do {
            switch target {
            case .account(let account):
                try credentialSession.clear(account)
                verificationStore.reset(account)
            case .savedCredentialFile:
                try credentialSession.resetSavedCredentials()
                for account in ProviderCredentialAccount.allCases {
                    verificationStore.reset(account)
                }
            }
            operationError = nil
        } catch {
            operationError = error.localizedDescription
        }
        refresh()
    }

    func snapshot(for account: ProviderCredentialAccount) -> ProviderCredentialSnapshot {
        snapshots[account] ?? ProviderCredentialSnapshot(
            account: account,
            scope: account.scope,
            isSaved: false,
            isActive: false
        )
    }

}

struct ProviderSettingsView: View {
    @StateObject private var viewModel = ProviderConnectionsViewModel()
    @ObservedObject private var engineStore = NotebookCaptureEnginePresentationStore.shared
    @ObservedObject private var verificationStore = ProviderConnectionVerificationStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xl) {
            SettingsPageHeader(
                title: String(localized: "settings.services.title"),
                subtitle: String(localized: "settings.services.subtitle")
            )

            if let recoveryError = viewModel.recoveryError {
                credentialRecoveryBanner(recoveryError)
            }

            SettingsCard(
                title: String(localized: "settings.services.connection.title"),
                subtitle: String(localized: "settings.services.connection.subtitle")
            ) {
                ForEach(Array(ProviderCredentialAccount.allCases.enumerated()), id: \.element.id) { index, account in
                    if index > 0 {
                        SettingsRowDivider()
                    }
                    ProviderCredentialAutoSaveRow(
                        account: account,
                        snapshot: viewModel.snapshot(for: account),
                        verificationState: verificationStore.state(for: account),
                        onVerifyAndApply: viewModel.verifyAndApply,
                        onVerifySaved: viewModel.verifySavedCredential,
                        onRequestDeletion: {
                            viewModel.requestDeletion(.account($0))
                        }
                    )
                }
            }

            CommunityInviteSettingsCard()

            Label(
                String(localized: "settings.credentials.trust_boundary_notice"),
                systemImage: "externaldrive.fill.badge.checkmark"
            )
            .font(.caption)
            .foregroundColor(.textSecondary)
            .fixedSize(horizontal: false, vertical: true)

            engineCard

            Label(
                String(localized: "settings.services.no_egress_notice"),
                systemImage: "lock.shield.fill"
            )
            .font(.caption)
            .foregroundColor(.textSecondary)
            .fixedSize(horizontal: false, vertical: true)

            if let operationError = viewModel.operationError {
                Label(operationError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.signalRed)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(String(
                        format: String(localized: "settings.credentials.operation_error_format"),
                        operationError
                    ))
            }
        }
        .onAppear {
            viewModel.refresh()
            engineStore.refresh()
            guard !TestEnvironment.isAnyTestMode else { return }
            for account in ProviderCredentialAccount.allCases {
                verificationStore.verifyIfNeeded(
                    account: account,
                    isConfigured: viewModel.snapshot(for: account).isActive
                )
            }
        }
        .confirmationDialog(
            deletionTitle,
            isPresented: Binding(
                get: { viewModel.pendingDeletion != nil },
                set: { if !$0 { viewModel.cancelDeletion() } }
            ),
            titleVisibility: .visible
        ) {
            Button(deletionActionTitle, role: .destructive) {
                viewModel.confirmDeletion()
            }
            Button(String(localized: "common.cancel"), role: .cancel) {
                viewModel.cancelDeletion()
            }
        } message: {
            Text(deletionMessage)
        }
    }

    private var engineCard: some View {
        let engine = engineStore.engine
        return SettingsCard(
            title: String(localized: "settings.services.engine.title"),
            subtitle: String(localized: "settings.services.engine.subtitle")
        ) {
            SettingsRow(String(localized: "settings.services.engine.service")) {
                Text(engine.providerDisplayName)
                    .font(.bodyMedium)
                    .foregroundColor(.textPrimary)
            }
            SettingsRowDivider()
            SettingsRow(
                String(localized: "settings.services.engine.realtime"),
                description: String(localized: "settings.services.engine.realtime_detail")
            ) {
                HStack(spacing: Spacing.xs) {
                    Text(engine.realtimeSummary)
                        .font(.captionMedium)
                        .foregroundColor(.textSecondary)
                    Label(String(localized: "settings.services.engine.fixed"), systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundColor(.textTertiary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(String(
                    format: String(localized: "settings.services.engine.accessibility_format"),
                    engine.realtimeSummary
                ))
            }
            SettingsRowDivider()
            SettingsRow(
                String(localized: "settings.services.engine.post_stop"),
                description: String(localized: engine.postStopUsesAsyncFileApi == true
                    ? "settings.services.engine.post_stop_detail"
                    : "settings.services.engine.post_stop_unavailable_detail")
            ) {
                HStack(spacing: Spacing.xs) {
                    Text(engine.postStopSummary)
                        .font(.captionMedium)
                        .foregroundColor(.textSecondary)
                    Label(
                        engine.postStopExecutionSummary,
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                    .font(.caption)
                    .foregroundColor(.textTertiary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(postStopAccessibilityLabel(for: engine))
            }
        }
    }

    private func postStopAccessibilityLabel(
        for engine: NotebookCaptureEnginePresentation
    ) -> String {
        let key: String.LocalizationValue = engine.postStopUsesAsyncFileApi == true
            ? "settings.services.engine.post_stop_accessibility_format"
            : "settings.services.engine.post_stop_unavailable_accessibility_format"
        return String(format: String(localized: key), engine.postStopSummary)
    }

    @ViewBuilder
    private func credentialRecoveryBanner(_ message: String) -> some View {
        SettingsCard(title: String(localized: "settings.credentials.recovery_title")) {
            SettingsFullRow {
                Text(message)
                    .font(.caption)
                    .foregroundColor(.signalAmber)
                    .fixedSize(horizontal: false, vertical: true)
                Text(String(localized: "settings.credentials.recovery_hint"))
                    .font(.caption)
                    .foregroundColor(.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(String(localized: "settings.credentials.reset_file")) {
                    viewModel.requestDeletion(.savedCredentialFile)
                }
                .buttonStyle(.bordered)
                .frame(minHeight: 44)
                .accessibilityHint(String(localized: "settings.credentials.reset_file_accessibility_hint"))
            }
        }
    }

    private var deletionTitle: String {
        switch viewModel.pendingDeletion {
        case .account(let account):
            return String(
                format: String(localized: "settings.credentials.delete_confirmation_title"),
                account.displayName
            )
        case .savedCredentialFile:
            return String(localized: "settings.credentials.reset_confirmation_title")
        case nil:
            return String(localized: "settings.credentials.delete_confirmation_title")
        }
    }

    private var deletionMessage: String {
        switch viewModel.pendingDeletion {
        case .account(let account):
            return String(
                format: String(localized: "settings.credentials.delete_confirmation_message"),
                account.displayName
            )
        case .savedCredentialFile:
            return String(localized: "settings.credentials.reset_confirmation_message")
        case nil:
            return ""
        }
    }

    private var deletionActionTitle: String {
        switch viewModel.pendingDeletion {
        case .account:
            return String(localized: "settings.credentials.delete_confirmation_action")
        case .savedCredentialFile:
            return String(localized: "settings.credentials.reset_confirmation_action")
        case nil:
            return String(localized: "common.delete")
        }
    }
}

private struct ProviderCredentialAutoSaveRow: View {
    let account: ProviderCredentialAccount
    let snapshot: ProviderCredentialSnapshot
    let verificationState: ProviderConnectionVerificationState
    let onVerifyAndApply: (String, ProviderCredentialAccount) async throws -> Void
    let onVerifySaved: (ProviderCredentialAccount) -> Void
    let onRequestDeletion: (ProviderCredentialAccount) -> Void

    @State private var draft = ""
    @State private var errorMessage: String?
    @State private var isWorking = false
    @State private var isReplacingCredential = false
    @FocusState private var isFocused: Bool

    private var isConfigured: Bool {
        snapshot.isSaved || snapshot.isActive
    }

    private var presentationState: ProviderCredentialPresentationState {
        .resolve(snapshot)
    }

    private var showsEditor: Bool {
        isConfigured == false || isReplacingCredential
    }

    var body: some View {
        SettingsFullRow {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                HStack(alignment: .center, spacing: Spacing.md) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(account.displayName)
                            .font(Font.sans12)
                            .foregroundColor(.textPrimary)
                        statusLabel
                    }

                    Spacer(minLength: Spacing.md)

                    if isConfigured, showsEditor == false {
                        Button {
                            verifySavedCredential()
                        } label: {
                            Label(
                                String(localized: "settings.credentials.verify"),
                                systemImage: "checkmark.shield"
                            )
                            .frame(minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                        .disabled(isWorking || verificationState == .checking)

                        Button {
                            beginReplacement()
                        } label: {
                            Image(systemName: "pencil")
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(isWorking)
                        .help(String(localized: "settings.credentials.replace"))
                        .accessibilityLabel(String(
                            format: String(localized: "settings.credentials.replace_accessibility_format"),
                            account.displayName
                        ))

                        Button {
                            onRequestDeletion(account)
                        } label: {
                            Image(systemName: "trash")
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.signalRed)
                        .disabled(isWorking)
                        .help(String(localized: "settings.credentials.clear"))
                        .accessibilityLabel(String(
                            format: String(localized: "settings.credentials.clear_accessibility_format"),
                            account.displayName
                        ))
                    }
                }

                if showsEditor {
                    HStack(spacing: Spacing.sm) {
                        SecureField(
                            String(localized: "settings.credentials.enter_key"),
                            text: $draft
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 420)
                        .frame(minHeight: 44)
                        .focused($isFocused)
                        .disabled(isWorking)
                        .onSubmit(verifyAndCommitDraft)
                        .accessibilityLabel(String(
                            format: String(localized: "settings.credentials.field_accessibility_format"),
                            account.displayName
                        ))
                        .accessibilityHint(String(
                            localized: "settings.credentials.field_replacement_hint"
                        ))

                        Button(String(localized: "settings.credentials.verify_and_save")) {
                            verifyAndCommitDraft()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                        .frame(minHeight: 44)
                        .disabled(
                            isWorking
                                || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                        .accessibilityLabel(String(
                            format: String(localized: "settings.credentials.verify_and_save_accessibility_format"),
                            account.displayName
                        ))
                    }

                    Text(String(localized: "settings.credentials.verify_before_save_hint"))
                        .font(.caption2)
                        .foregroundColor(.textTertiary)
                }

                Text(statusHint)
                    .font(.caption)
                    .foregroundColor(.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundColor(.signalRed)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private var statusLabel: some View {
        Label(statusTitle, systemImage: statusIcon)
            .font(.caption)
            .foregroundColor(statusColor)
            .accessibilityLabel(statusAccessibilityLabel)
    }

    private var statusTitle: String {
        switch verificationState {
        case .checking:
            return String(localized: "settings.credentials.verifying")
        case .ready:
            return String(localized: "settings.credentials.verification.ready")
        case .invalidCredential:
            return String(localized: "settings.credentials.verification.invalid")
        case .organizationBalanceExhausted:
            return String(localized: "settings.credentials.verification.organization_balance_exhausted")
        case .organizationMonthlyBudgetExhausted:
            return String(localized: "settings.credentials.verification.organization_budget_exhausted")
        case .projectMonthlyBudgetExhausted:
            return String(localized: "settings.credentials.verification.project_budget_exhausted")
        case .quotaExhausted:
            return String(localized: "settings.credentials.verification.quota_exhausted")
        case .networkUnavailable:
            return String(localized: "settings.credentials.verification.network_unavailable")
        case .rateLimited:
            return String(localized: "settings.credentials.verification.rate_limited")
        case .serviceUnavailable:
            return String(localized: "settings.credentials.verification.service_unavailable")
        case .unverified:
            break
        }
        return presentationState.localizedStatusTitle
    }

    private var statusIcon: String {
        switch verificationState {
        case .checking: return "arrow.triangle.2.circlepath"
        case .ready: return "checkmark.shield.fill"
        case .invalidCredential: return "key.slash.fill"
        case .organizationBalanceExhausted,
             .organizationMonthlyBudgetExhausted,
             .projectMonthlyBudgetExhausted,
             .quotaExhausted:
            return "creditcard.trianglebadge.exclamationmark"
        case .networkUnavailable: return "wifi.slash"
        case .rateLimited: return "hourglass"
        case .serviceUnavailable: return "exclamationmark.icloud.fill"
        case .unverified: break
        }
        return switch presentationState {
        case .savedLoadedUnverified, .runtimeOnlyUnverified: "key.fill"
        case .savedInactive: "exclamationmark.triangle.fill"
        case .missing: "circle"
        }
    }

    private var statusColor: Color {
        switch verificationState {
        case .checking: return .signalBlue
        case .ready: return .signalGreen
        case .invalidCredential,
             .organizationBalanceExhausted,
             .organizationMonthlyBudgetExhausted,
             .projectMonthlyBudgetExhausted,
             .quotaExhausted:
            return .signalRed
        case .networkUnavailable, .rateLimited, .serviceUnavailable:
            return .signalAmber
        case .unverified: break
        }
        return switch presentationState {
        case .savedLoadedUnverified, .runtimeOnlyUnverified: .signalBlue
        case .savedInactive: .signalAmber
        case .missing: .textTertiary
        }
    }

    private var statusHint: String {
        switch verificationState {
        case .checking:
            return String(localized: "settings.credentials.verifying_hint")
        case .ready:
            return String(localized: "settings.credentials.verified_hint")
        case .invalidCredential,
             .organizationBalanceExhausted,
             .organizationMonthlyBudgetExhausted,
             .projectMonthlyBudgetExhausted,
             .quotaExhausted,
             .networkUnavailable,
             .rateLimited,
             .serviceUnavailable:
            return ProviderConnectionVerificationFailure(verificationState)
                .localizedDescription
        case .unverified:
            break
        }
        return switch presentationState {
        case .savedLoadedUnverified:
            String(localized: "settings.credentials.provider_not_tested_hint")
        case .savedInactive:
            String(localized: "settings.credentials.saved_inactive_hint")
        case .runtimeOnlyUnverified:
            String(localized: "settings.credentials.runtime_only_hint")
        case .missing:
            String(localized: "settings.credentials.local_storage_hint")
        }
    }

    private var statusAccessibilityLabel: String {
        let key: String.LocalizationValue = switch presentationState {
        case .savedLoadedUnverified:
            "settings.credentials.accessibility_applied_format"
        case .savedInactive:
            "settings.credentials.accessibility_saved_inactive_format"
        case .runtimeOnlyUnverified:
            "settings.credentials.accessibility_runtime_only_format"
        case .missing:
            "settings.credentials.accessibility_missing_format"
        }
        return String(format: String(localized: key), account.displayName)
    }

    private func beginReplacement() {
        draft = ""
        errorMessage = nil
        isReplacingCredential = true
        Task { @MainActor in
            await Task.yield()
            isFocused = true
        }
    }

    private func verifySavedCredential() {
        guard !isWorking, verificationState != .checking else { return }
        errorMessage = nil
        onVerifySaved(account)
    }

    private func verifyAndCommitDraft() {
        guard !isWorking else { return }
        let decision = ProviderCredentialEditorCommitDecision.resolve(
            rawValue: draft,
            isConfigured: isConfigured
        )
        guard case .apply(let value) = decision else {
            if decision == .dismissReplacement {
                isReplacingCredential = false
            }
            return
        }
        isWorking = true
        errorMessage = nil
        Task { @MainActor in
            defer { isWorking = false }
            do {
                try await onVerifyAndApply(value, account)
                draft = ""
                errorMessage = nil
                isReplacingCredential = false
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
