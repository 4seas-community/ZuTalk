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
    /// Whose verdict this is. Settings shows the capture and model keys on
    /// the same card, so the provider is named, never assumed.
    let account: ProviderCredentialAccount

    init(_ state: ProviderConnectionVerificationState, account: ProviderCredentialAccount) {
        self.state = state
        self.account = account
    }

    var errorDescription: String? {
        let named: (String.LocalizationValue) -> String = { key in
            String(format: String(localized: key), account.displayName)
        }
        // The balance and budget verdicts are Soniox's own error types; no
        // other provider produces them, so they name it directly.
        return switch state {
        case .invalidCredential:
            named("settings.credentials.verification.invalid_format")
        case .organizationBalanceExhausted:
            String(localized: "settings.credentials.verification.organization_balance_exhausted")
        case .organizationMonthlyBudgetExhausted:
            String(localized: "settings.credentials.verification.organization_budget_exhausted")
        case .projectMonthlyBudgetExhausted:
            String(localized: "settings.credentials.verification.project_budget_exhausted")
        case .quotaExhausted:
            named("settings.credentials.verification.quota_exhausted_format")
        case .networkUnavailable:
            named("settings.credentials.verification.network_unavailable_format")
        case .rateLimited:
            named("settings.credentials.verification.rate_limited_format")
        case .serviceUnavailable, .unverified, .checking, .ready:
            named("settings.credentials.verification.service_unavailable_format")
        }
    }
}

extension ProviderConnectionVerificationState {
    /// What a person can do about a failed check, as a format taking the
    /// provider's display name. The status line above it already says what
    /// failed, so this says what to do next instead of saying it again.
    var failureHintFormatKey: String? {
        switch self {
        case .invalidCredential:
            "settings.credentials.verification.invalid_hint_format"
        case .organizationBalanceExhausted:
            "settings.credentials.verification.organization_balance_exhausted_hint_format"
        case .organizationMonthlyBudgetExhausted:
            "settings.credentials.verification.organization_budget_exhausted_hint_format"
        case .projectMonthlyBudgetExhausted:
            "settings.credentials.verification.project_budget_exhausted_hint_format"
        case .quotaExhausted:
            "settings.credentials.verification.quota_exhausted_hint_format"
        case .networkUnavailable:
            "settings.credentials.verification.network_unavailable_hint_format"
        case .rateLimited:
            "settings.credentials.verification.rate_limited_hint_format"
        case .serviceUnavailable:
            "settings.credentials.verification.service_unavailable_hint_format"
        case .unverified, .checking, .ready:
            nil
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
            // The account's card shows this verdict; repeating it here put
            // the same sentence on screen twice.
            operationError = nil
            throw ProviderConnectionVerificationFailure(verification, account: account)
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

/// 一把密钥在设置里画出来的两样:存没存、载没载入(`snapshot`),和最近一次
/// 验证的结论。纯数据,测试可以给任何一种。
struct SettingsKeyModel: Equatable {
    var snapshot: ProviderCredentialSnapshot
    var verification: ProviderConnectionVerificationState = .unverified
}

struct ProviderSettingsView: View {
    /// 这份视图在「设置 › 高级」里出现两次,各管一把自己的密钥:`.captions` 是
    /// 出字和精修用的那一把,`.languageModel` 是整理标记用的那一把(可选)。
    /// 邀请码不在这里,在「账号 › 出字」;引擎和模型的名字在同一页的「诊断
    /// 信息」里。供应商的名字只在这一节出现,所以标题直接叫它的名字。
    ///
    /// 一把密钥一行:名字、状态(一个图标加一个词)、输入栏、保存。页面上没有
    /// 句子。两处必须让人读得到的告知 —— 密钥未加密保存在这台 Mac 上;什么
    /// 时候音频、哪些文字会发出去 —— 在各自标题旁边的 ⓘ 里。
    enum Scope {
        case captions
        case languageModel
    }

    var scope: Scope = .captions

    @StateObject private var viewModel = ProviderConnectionsViewModel()
    @ObservedObject private var verificationStore = ProviderConnectionVerificationStore.shared
    @ObservedObject private var modelStore = LanguageModelPresentationStore.shared
    @ObservedObject private var assistance = LanguageModelAssistanceStore.shared
    @ObservedObject private var invite = CommunityInviteSession.shared
    @Environment(\.settingsFixture) private var fixture

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            switch scope {
            case .captions:
                captionsContent
            case .languageModel:
                languageModelCard
            }

            if let operationError = viewModel.operationError {
                SettingsProblem(operationError, tint: .signalRed)
                    .accessibilityLabel(String(
                        format: String(localized: "settings.credentials.operation_error_format"),
                        operationError
                    ))
            }
        }
        .onAppear {
            // 画给测试看的时候不碰 store。
            guard fixture == nil else { return }
            viewModel.refresh()
            modelStore.refresh()
            assistance.pushToCore()
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

    /// 「自己的 Soniox 密钥」。名字从账户来,不在这里写死。
    private func ownKeyTitle(_ accounts: [ProviderCredentialAccount]) -> String {
        String(
            format: String(localized: "settings.advanced.own_key_format"),
            ListFormatter.localizedString(byJoining: accounts.map(\.displayName))
        )
    }

    /// What the page draws for one key: the fixed picture when a test gave
    /// one, otherwise the live session and its last verdict.
    private func keyModel(for account: ProviderCredentialAccount) -> SettingsKeyModel {
        if let fixture {
            return fixture.keys[account] ?? SettingsKeyModel(snapshot: ProviderCredentialSnapshot(
                account: account,
                scope: account.scope,
                isSaved: false,
                isActive: false
            ))
        }
        return SettingsKeyModel(
            snapshot: viewModel.snapshot(for: account),
            verification: verificationStore.state(for: account)
        )
    }

    @ViewBuilder
    private var captionsContent: some View {
        SettingsGroup(
            title: ownKeyTitle(captureAccounts),
            subtitle: String(localized: "settings.advanced.capture_key_subtitle"),
            info: captureDisclosure
        ) {
            if let recoveryError = viewModel.recoveryError {
                credentialRecoveryBanner(recoveryError)
            }

            SettingsCard {
                ForEach(Array(captureAccounts.enumerated()), id: \.element.id) { index, account in
                    if index > 0 {
                        SettingsRowDivider()
                    }
                    credentialRow(account)
                }
            }
        }
    }

    /// 出字那把密钥旁边 ⓘ 里的几句:什么时候用得到;密钥未加密存在这台 Mac
    /// 上;存密钥本身什么都不发,什么时候音频才会发出去。
    private var captureDisclosure: String {
        [
            String(localized: "settings.advanced.capture_key_subtitle"),
            String(localized: "settings.credentials.trust_boundary_notice"),
            String(localized: "settings.services.no_egress_notice"),
        ].joined(separator: "\n")
    }

    /// Credentials the app needs before it can transcribe anything.
    private var captureAccounts: [ProviderCredentialAccount] {
        ProviderCredentialAccount.allCases.filter(\.isRequiredForCapture)
    }

    private var languageModelAccounts: [ProviderCredentialAccount] {
        ProviderCredentialAccount.allCases.filter { $0.isRequiredForCapture == false }
    }

    private var cleanupEnabled: Bool {
        fixture?.cleanupEnabled ?? assistance.isEnabled
    }

    /// The model credential gets its own card rather than another row beside
    /// the capture key.
    ///
    /// They are not peers. One is required and its traffic is audio the user
    /// already agreed to send; this one is optional, and configuring it is the
    /// moment a person decides whether their transcripts may leave the
    /// machine. What leaves and what never does is the ⓘ beside the card's
    /// title, where it can be read before the field is filled.
    @ViewBuilder
    private var languageModelCard: some View {
        if languageModelAccounts.isEmpty == false {
            SettingsGroup(
                title: ownKeyTitle(languageModelAccounts),
                subtitle: String(
                    format: String(localized: "settings.services.model.subtitle_format"),
                    activeModelId
                ),
                info: modelDisclosure
            ) {
                languageModelRows
                    .accessibilityIdentifier("settings.services.model")
            }
            .task {
                guard fixture == nil, invite.isEnabled, invite.isActive else { return }
                await invite.refreshQuota()
            }
        }
    }

    /// 整理那把密钥旁边 ⓘ 里的几句:它是做什么的、用哪个模型;开着的时候发
    /// 什么、关了以后怎样;只发标记的段落;录音从不发。邀请包含整理的时候,
    /// 再加上段落经谁转交。
    private var modelDisclosure: String {
        var lines = [
            String(
                format: String(localized: "settings.services.model.subtitle_format"),
                activeModelId
            ),
            String(localized: "settings.services.model.enable_detail"),
            String(localized: "settings.services.model.egress_notice"),
            String(localized: "settings.services.model.audio_notice"),
        ]
        if let offer = inviteCleanupOffer {
            lines.append(inviteCleanupDetail(offer))
        }
        return lines.joined(separator: "\n")
    }

    private var inviteCleanupOffer: CommunityInvitePassageDigestOffer? {
        guard fixture == nil else { return nil }
        return invite.coversPassageDigest ? invite.passageDigestOffer : nil
    }

    private var languageModelRows: some View {
        SettingsCard {
            SettingsRow(
                String(localized: "settings.services.model.enable"),
                description: String(localized: "settings.services.model.enable_detail")
            ) {
                SettingsSwitch(
                    isOn: cleanupEnabled,
                    label: String(localized: "settings.services.model.enable"),
                    help: String(localized: "settings.services.model.enable_detail")
                ) {
                    assistance.setEnabled($0)
                }
                .accessibilityIdentifier("settings.services.model.enable")
            }

            SettingsRowDivider()

            if let offer = inviteCleanupOffer {
                inviteCleanupRow(offer)
                SettingsRowDivider()
            }

            ForEach(Array(languageModelAccounts.enumerated()), id: \.element.id) { index, account in
                if index > 0 {
                    SettingsRowDivider()
                }
                credentialRow(account)
            }

            if let consoleURL = modelStore.engine.consoleURL {
                SettingsRowDivider()
                SettingsFullRow {
                    ActionPill(
                        String(localized: "settings.services.model.console_link"),
                        systemImage: "arrow.up.right",
                        style: .quiet
                    ) {
                        NSWorkspace.shared.open(consoleURL)
                    }
                    .accessibilityIdentifier("settings.services.model.console_link")
                }
            }
        }
    }

    /// Whether a key the user saved is loaded. The core sends with it first,
    /// so while it is, the invitation's cleanup is never used.
    private var hasPersonalModelKey: Bool {
        languageModelAccounts.contains { keyModel(for: $0).snapshot.isActive }
    }

    /// The model a marked passage would actually go to.
    private var activeModelId: String {
        if hasPersonalModelKey == false, let offer = inviteCleanupOffer {
            return offer.model
        }
        return modelStore.engine.modelId
    }

    /// The invitation includes cleanup. Said where the key field is, because
    /// the first thing an invited user wonders here is whether they need one —
    /// and the second is where their passage goes if they do not: that
    /// sentence is this status's tooltip, and one of the lines behind the ⓘ.
    private func inviteCleanupRow(_ offer: CommunityInvitePassageDigestOffer) -> some View {
        SettingsFullRow {
            SettingsStatus(
                String(localized: "settings.services.model.invite_included"),
                systemImage: "gift.fill",
                tint: .brandAccent,
                help: inviteCleanupDetail(offer)
            )
            .accessibilityIdentifier("settings.services.model.invite_included")
        }
    }

    private func inviteCleanupDetail(_ offer: CommunityInvitePassageDigestOffer) -> String {
        hasPersonalModelKey
            ? String(
                format: String(localized: "settings.services.model.invite_superseded_format"),
                modelStore.engine.providerDisplayName,
                modelStore.engine.providerDisplayName
            )
            : String(
                format: String(localized: "settings.services.model.invite_included_detail_format"),
                offer.provider,
                offer.remainingToday
            )
    }

    private func credentialRow(_ account: ProviderCredentialAccount) -> some View {
        let model = keyModel(for: account)
        return ProviderCredentialAutoSaveRow(
            account: account,
            snapshot: model.snapshot,
            verificationState: model.verification,
            onVerifyAndApply: viewModel.verifyAndApply,
            onVerifySaved: viewModel.verifySavedCredential,
            onRequestDeletion: {
                viewModel.requestDeletion(.account($0))
            }
        )
    }

    /// 存着的密钥文件读不出来:出了事的那一句,和唯一能做的事。怎么办的那句
    /// 在 ⓘ 里。
    @ViewBuilder
    private func credentialRecoveryBanner(_ message: String) -> some View {
        SettingsCard(
            title: String(localized: "settings.credentials.recovery_title"),
            info: String(localized: "settings.credentials.recovery_hint")
        ) {
            SettingsFullRow {
                SettingsProblem(message)
                ActionPill(
                    String(localized: "settings.credentials.reset_file"),
                    systemImage: "trash",
                    tone: .warning,
                    help: String(localized: "settings.credentials.reset_file_accessibility_hint")
                ) {
                    viewModel.requestDeletion(.savedCredentialFile)
                }
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

/// 一把密钥的那一行。
///
/// 没存的时候(或者正在换):名字、状态、输入栏、「保存」。存了以后:名字、
/// 状态、「验证」、更换、删除。状态是一个图标加一个词 —— 未保存、已保存、
/// 已验证、无效;这把密钥此刻能做什么的那一句在状态的悬停提示里。验证没
/// 通过的时候,多一行说出了什么事(出错可以写整句),怎么办在那一行的提示里。
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
            HStack(alignment: .center, spacing: PillMetrics.spacing) {
                Text(account.displayName)
                    .font(PillMetrics.font)
                    .foregroundColor(.textPrimary)
                    .fixedSize()
                statusLabel

                if showsEditor {
                    editor
                } else {
                    Spacer(minLength: Spacing.sm)
                    savedActions
                }
            }

            if let failure = verificationFailure {
                SettingsProblem(failure, tint: statusColor)
                    .settingsExplained(statusHint)
            }

            if let errorMessage {
                SettingsProblem(errorMessage, tint: .signalRed)
            }
        }
    }

    /// The field and Save. The field is as tall as the pills beside it, like
    /// every other field in Settings (`SettingsField`).
    @ViewBuilder
    private var editor: some View {
        SettingsField(
            String(localized: "settings.credentials.key_placeholder"),
            text: $draft,
            isSecure: true,
            focus: $isFocused
        )
        .onSubmit(verifyAndCommitDraft)
        .disabled(isWorking)
        // Where the key is kept, and that it is kept unencrypted.
        .help(String(localized: "settings.credentials.local_storage_hint"))
        .accessibilityLabel(String(
            format: String(localized: "settings.credentials.field_accessibility_format"),
            account.displayName
        ))
        .accessibilityHint(String(
            localized: "settings.credentials.field_replacement_hint"
        ))

        if isWorking {
            ProgressView()
                .controlSize(.small)
                .frame(width: PillMetrics.height, height: PillMetrics.height)
        } else {
            // Each account is checked by its own service before it is
            // saved; the tooltip says so, by name.
            ActionPill(
                String(localized: "common.save"),
                systemImage: "checkmark",
                help: String(
                    format: String(localized: "settings.credentials.verify_before_save_format"),
                    account.displayName
                ),
                accessibilityLabel: String(
                    format: String(localized: "settings.credentials.verify_and_save_accessibility_format"),
                    account.displayName
                ),
                action: verifyAndCommitDraft
            )
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }

        if isReplacingCredential, isWorking == false {
            ActionPill(
                String(localized: "common.cancel"),
                systemImage: "xmark",
                style: .quiet
            ) {
                draft = ""
                errorMessage = nil
                isReplacingCredential = false
            }
        }
    }

    /// Verify has its word. Replace and delete are the pencil and the bin,
    /// named in their tooltips: three words do not fit beside the name and
    /// the status in the narrowest window in every language.
    @ViewBuilder
    private var savedActions: some View {
        ActionPill(
            String(localized: "settings.credentials.verify"),
            systemImage: "checkmark.shield",
            action: verifySavedCredential
        )
        .disabled(isWorking || verificationState == .checking)

        ActionPill(
            nil,
            systemImage: "pencil",
            help: String(localized: "settings.credentials.replace"),
            accessibilityLabel: String(
                format: String(localized: "settings.credentials.replace_accessibility_format"),
                account.displayName
            ),
            action: beginReplacement
        )
        .disabled(isWorking)

        ActionPill(
            nil,
            systemImage: "trash",
            iconTint: .signalRed,
            help: String(localized: "settings.credentials.clear"),
            accessibilityLabel: String(
                format: String(localized: "settings.credentials.clear_accessibility_format"),
                account.displayName
            )
        ) {
            onRequestDeletion(account)
        }
        .disabled(isWorking)
    }

    private var statusLabel: some View {
        SettingsStatus(statusWord, systemImage: statusIcon, tint: statusColor, help: statusHint)
            .accessibilityLabel(statusAccessibilityLabel)
    }

    /// The one word. A check that failed for a reason other than the key
    /// itself (no network, no balance) leaves the word about the key as it
    /// was and says what happened on the line below.
    private var statusWord: String {
        switch verificationState {
        case .checking:
            return String(localized: "settings.credentials.verifying")
        case .ready:
            return String(localized: "settings.credentials.status.verified")
        case .invalidCredential:
            return String(localized: "settings.credentials.status.invalid")
        case .organizationBalanceExhausted,
             .organizationMonthlyBudgetExhausted,
             .projectMonthlyBudgetExhausted,
             .quotaExhausted,
             .networkUnavailable,
             .rateLimited,
             .serviceUnavailable,
             .unverified:
            break
        }
        return presentationState == .savedLoadedUnverified
            ? String(localized: "settings.credentials.status.saved")
            : presentationState.localizedStatusTitle
    }

    /// The sentence for a check that did not pass; nil while there is none.
    private var verificationFailure: String? {
        guard verificationState.failureHintFormatKey != nil else { return nil }
        return ProviderConnectionVerificationFailure(verificationState, account: account)
            .localizedDescription
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
            return String(
                format: String(localized: "settings.credentials.verifying_hint_format"),
                account.displayName
            )
        case .ready:
            // The title already names the provider; this says what the key
            // is now good for.
            return account.isRequiredForCapture
                ? String(localized: "settings.credentials.verified_hint_capture")
                : String(localized: "settings.credentials.verified_hint_model")
        case .invalidCredential,
             .organizationBalanceExhausted,
             .organizationMonthlyBudgetExhausted,
             .projectMonthlyBudgetExhausted,
             .quotaExhausted,
             .networkUnavailable,
             .rateLimited,
             .serviceUnavailable:
            if let key = verificationState.failureHintFormatKey {
                return String(
                    format: String(localized: String.LocalizationValue(key)),
                    account.displayName
                )
            }
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
        // A verdict is the status: read it rather than only "saved".
        if case .ready = verificationState {
            return String(
                format: String(localized: "settings.credentials.verification.ready_format"),
                account.displayName
            )
        }
        if let verificationFailure { return verificationFailure }
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
            } catch is ProviderConnectionVerificationFailure {
                // The status and the line under it already show this verdict.
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
