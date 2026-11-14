import SwiftUI

/// 「设置 › 账号」里「出字」那张卡。三行:
///   1. 现在靠什么出字 —— 一个图标、几个词(邀请码还能录多久也在这几个词里);
///   2. 邀请码 —— 没有的时候是一栏和「启用」;有的时候是开关、更换、删除;
///   3. 「用自己的密钥…」—— 一颗胶囊,点了去「高级」。
///
/// 卡片上没有句子。原来的那几句(邀请时长怎么算、开关关了以后用什么、删除了
/// 会怎样)都在各自控件的悬停提示里;删除仍然先问一遍。卡片上也不出现供应商
/// 的名字:用邀请码的人不需要知道背后是谁。
struct CommunityInviteSettingsCard: View {
    @ObservedObject private var invite = CommunityInviteSession.shared
    /// 只为了密钥存上、删掉的时候,那几个词跟着变;密钥本身从不进界面。
    @ObservedObject private var credentials = ProviderCredentialSession.shared
    @Environment(\.settingsFixture) private var fixture
    @State private var code = ""
    @State private var isReplacing = false
    @State private var isConfirmingRemoval = false

    private var model: LiveTextCardModel {
        fixture?.liveText ?? .live(invite: invite, credentials: credentials)
    }

    var body: some View {
        let model = model
        return SettingsCard {
            LiveTextStatusRow(
                source: model.source,
                isRefreshing: model.isWorking,
                onRefresh: model.inviteActive && model.inviteEnabled
                    ? { Task { await invite.refreshQuota() } }
                    : nil
            )
            SettingsRowDivider()
            if model.inviteActive, isReplacing == false {
                inviteRow(model)
            } else {
                redeemRow(model)
            }
            SettingsRowDivider()
            ownKeyRow
        }
        .task {
            guard fixture == nil else { return }
            await invite.refreshQuota()
        }
        .alert(
            String(localized: "community_invite.remove_confirm_title"),
            isPresented: $isConfirmingRemoval
        ) {
            Button(
                String(localized: "community_invite.remove_confirm_action"),
                role: .destructive
            ) {
                invite.removeInvite()
                code = ""
                isReplacing = false
            }
            Button(String(localized: "common.cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "community_invite.remove_confirm_message"))
        }
    }

    /// 邀请码已经在这台 Mac 上:用不用它、换一个、删掉。
    private func inviteRow(_ model: LiveTextCardModel) -> some View {
        SettingsRow(
            String(localized: "settings.live_text.invite_field_label"),
            description: String(localized: "community_invite.use_toggle_detail")
        ) {
            SettingsSwitch(
                isOn: model.inviteEnabled,
                label: String(localized: "settings.live_text.use_invite"),
                help: String(localized: "community_invite.use_toggle_detail")
            ) { enabled in
                invite.setEnabled(enabled)
                // Recording overrides the runtime Soniox key with the
                // invite's temporary key; switching back to the user's
                // own key must restore the saved credential.
                if enabled == false {
                    try? ProviderCredentialSession.shared.activateSavedCredentials()
                }
            }
            .accessibilityIdentifier("settings.community-invite.use-toggle")

            ActionPill(
                String(localized: "settings.action.replace"),
                systemImage: "arrow.left.arrow.right",
                help: String(localized: "community_invite.replace"),
                accessibilityLabel: String(localized: "community_invite.replace")
            ) {
                code = ""
                isReplacing = true
            }
            .accessibilityIdentifier("settings.community-invite.replace")

            ActionPill(
                String(localized: "common.delete"),
                systemImage: "trash",
                help: String(localized: "community_invite.remove_detail"),
                accessibilityLabel: String(localized: "community_invite.remove")
            ) {
                isConfirmingRemoval = true
            }
            .accessibilityIdentifier("settings.community-invite.remove")
        }
    }

    /// 一栏和「启用」。换邀请码的时候多一个「取消」,不想换了能退回去。
    private func redeemRow(_ model: LiveTextCardModel) -> some View {
        SettingsFullRow {
            HStack(spacing: PillMetrics.spacing) {
                SettingsField(
                    String(localized: "community_invite.placeholder"),
                    text: $code,
                    onSubmit: redeem
                )
                .disabled(model.isWorking)
                .settingsExplained(String(localized: "settings.live_text.invite_hint"))
                .accessibilityLabel(String(localized: "settings.live_text.invite_field_label"))
                .accessibilityIdentifier("settings.community-invite.code")

                if model.isWorking {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: PillMetrics.height, height: PillMetrics.height)
                } else {
                    ActionPill(
                        String(localized: "onboarding.live_text.redeem"),
                        systemImage: "checkmark",
                        action: redeem
                    )
                    .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("settings.community-invite.redeem")
                }

                if model.inviteActive {
                    ActionPill(
                        String(localized: "common.cancel"),
                        systemImage: "xmark",
                        style: .quiet
                    ) {
                        code = ""
                        isReplacing = false
                    }
                }
            }

            if let error = model.errorMessage {
                SettingsProblem(error)
            }
        }
    }

    /// 要用自己的密钥的人知道往哪走,别的人不被它打扰。
    private var ownKeyRow: some View {
        SettingsFullRow {
            ActionPill(
                String(localized: "settings.live_text.use_own_key"),
                systemImage: "key"
            ) {
                SettingsRouter.shared.section = .advanced
            }
            .accessibilityIdentifier("settings.live-text.use-own-key")
        }
    }

    private func redeem() {
        guard !invite.isWorking else { return }
        Task {
            await invite.redeem(code)
            if invite.isActive, invite.errorMessage == nil {
                code = ""
                isReplacing = false
            }
        }
    }
}

/// 「出字」那张卡画的是什么:靠什么出字,邀请码在不在、开没开,是不是正在问
/// 邀请服务,上一次出了什么错。纯数据:卡片只看它,测试可以给它任何一种。
struct LiveTextCardModel: Equatable {
    var source: LiveTextSource
    var inviteActive = false
    var inviteEnabled = false
    var isWorking = false
    var errorMessage: String?

    @MainActor
    static func live(
        invite: CommunityInviteSession,
        credentials: any ProviderCredentialSessioning
    ) -> LiveTextCardModel {
        LiveTextCardModel(
            source: .current(invite: invite, credentials: credentials),
            inviteActive: invite.isActive,
            inviteEnabled: invite.isEnabled,
            isWorking: invite.isWorking,
            errorMessage: invite.errorMessage
        )
    }
}

/// 「现在靠什么出字」那一行:一个图标、几个词。邀请码在用的时候,右边多一颗
/// 「再问一遍还剩多少」的胶囊。整句在悬停提示里。
struct LiveTextStatusRow: View {
    let source: LiveTextSource
    var isRefreshing = false
    /// 邀请码在用的时候才有。
    var onRefresh: (() -> Void)?

    var body: some View {
        SettingsFullRow {
            HStack(alignment: .center, spacing: Spacing.sm) {
                Image(systemName: source.symbol)
                    .font(PillMetrics.iconFont)
                    .foregroundColor(tint)
                    .frame(width: 20)
                    .accessibilityHidden(true)

                Text(source.status)
                    .font(.bodyMedium)
                    .foregroundColor(.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityHint(Text(explanation))
                    .accessibilityIdentifier("settings.live-text.source")

                Spacer(minLength: Spacing.sm)

                if let onRefresh {
                    ActionPill(
                        nil,
                        systemImage: "arrow.triangle.2.circlepath",
                        help: String(localized: "community_invite.refresh"),
                        accessibilityLabel: String(localized: "community_invite.refresh"),
                        action: onRefresh
                    )
                    .disabled(isRefreshing)
                }
            }
            .help(explanation)
        }
    }

    private var tint: Color {
        if source == .inviteSpent { return .signalAmber }
        return source.powersLiveText ? .brandAccent : .textTertiary
    }

    /// 整句,邀请码在用的时候再加上「这段时间怎么算」。
    private var explanation: String {
        guard case .invite = source else { return source.sentence }
        return source.sentence + "\n" + String(localized: "settings.live_text.shared_detail")
    }
}
