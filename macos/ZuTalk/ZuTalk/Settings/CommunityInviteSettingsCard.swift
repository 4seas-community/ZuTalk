import SwiftUI

/// 「设置 › 账号」里「转录和翻译」那张卡:现在靠什么出字,一句话;邀请码在这里
/// 填、换、删;要用自己的密钥,从最下面那一行去「高级」。
///
/// 这张卡以前叫「社区邀请」,在「实时字幕」一节里排在服务密钥下面。大多数人手里
/// 有的是邀请码,不是密钥,所以它现在在「账号」里,邀请码排在前面。卡片上不出现
/// 供应商的名字:用邀请码的人不需要知道背后是谁。
struct CommunityInviteSettingsCard: View {
    @ObservedObject private var invite = CommunityInviteSession.shared
    /// 只为了密钥存上、删掉的时候,那一句话跟着变;密钥本身从不进界面。
    @ObservedObject private var credentials = ProviderCredentialSession.shared
    @State private var code = ""
    @State private var isReplacing = false
    @State private var isConfirmingRemoval = false

    var body: some View {
        SettingsCard {
            statusRow
            SettingsRowDivider()
            if invite.isActive {
                sourceToggleRow
                SettingsRowDivider()
                if isReplacing {
                    redeemEditor
                } else {
                    replaceRow
                }
                SettingsRowDivider()
                removeRow
            } else {
                inactiveEditor
            }
            SettingsRowDivider()
            ownKeyRow
        }
        .task { await invite.refreshQuota() }
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

    /// 现在靠什么出字。剩余时间就写在这一句里,不另起一行再报一遍。
    private var statusRow: some View {
        LiveTextStatusRow(
            source: LiveTextSource.current(invite: invite, credentials: credentials),
            isRefreshing: invite.isWorking,
            onRefresh: invite.isActive && invite.isEnabled
                ? { Task { await invite.refreshQuota() } }
                : nil
        )
    }

    private var sourceToggleRow: some View {
        SettingsRow(
            String(localized: "settings.live_text.use_invite"),
            description: String(localized: "community_invite.use_toggle_detail")
        ) {
            Toggle(
                String(localized: "settings.live_text.use_invite"),
                isOn: Binding(
                    get: { invite.isEnabled },
                    set: { enabled in
                        invite.setEnabled(enabled)
                        // Recording overrides the runtime Soniox key with the
                        // invite's temporary key; switching back to the user's
                        // own key must restore the saved credential.
                        if enabled == false {
                            try? ProviderCredentialSession.shared.activateSavedCredentials()
                        }
                    }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .accessibilityIdentifier("settings.community-invite.use-toggle")
        }
    }

    private var replaceRow: some View {
        SettingsRow(String(localized: "settings.live_text.invite_on")) {
            Button(String(localized: "community_invite.replace")) {
                code = ""
                isReplacing = true
            }
            .buttonStyle(.bordered)
            .frame(minHeight: 44)
        }
    }

    private var removeRow: some View {
        SettingsRow(
            String(localized: "community_invite.remove"),
            description: String(localized: "community_invite.remove_detail")
        ) {
            Button(String(localized: "community_invite.remove"), role: .destructive) {
                isConfirmingRemoval = true
            }
            .buttonStyle(.bordered)
            .frame(minHeight: 44)
            .accessibilityIdentifier("settings.community-invite.remove")
        }
    }

    // 这几行的内容都比卡片窄。不撑满的话,卡片会把整行摆到中间去。
    private var redeemEditor: some View {
        SettingsFullRow {
            redeemField
            redeemError
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var inactiveEditor: some View {
        SettingsFullRow {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "settings.live_text.invite_field_label"))
                    .font(Font.sans12)
                    .foregroundColor(.textPrimary)
                Text(String(localized: "settings.live_text.invite_hint"))
                    .font(Font.sans11)
                    .foregroundColor(.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            redeemField
            redeemError
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var redeemError: some View {
        if let error = invite.errorMessage {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(Font.sans11)
                .foregroundColor(.signalAmber)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var redeemField: some View {
        HStack(spacing: Spacing.sm) {
            TextField(
                String(localized: "community_invite.placeholder"),
                text: $code
            )
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 44)
            .disabled(invite.isWorking)
            .onSubmit(redeem)
            .accessibilityLabel(String(localized: "settings.live_text.invite_field_label"))
            .accessibilityIdentifier("settings.community-invite.code")

            Button {
                redeem()
            } label: {
                if invite.isWorking {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text(String(localized: "community_invite.action"))
                }
            }
            .buttonStyle(.borderedProminent)
            .frame(minHeight: 44)
            .disabled(
                invite.isWorking
                    || code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
        }
    }

    /// 安静的一行:要用自己的密钥的人知道往哪走,别的人不被它打扰。
    private var ownKeyRow: some View {
        SettingsFullRow {
            Button(String(localized: "settings.live_text.use_own_key")) {
                SettingsRouter.shared.section = .advanced
            }
            // The app's own colour for a text action, as on Home's 更改:
            // the system link blue is used nowhere else in the window.
            .buttonStyle(.plain)
            .foregroundColor(.brandAccent)
            .font(Font.sans12)
            .accessibilityIdentifier("settings.live-text.use-own-key")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

/// 「现在靠什么出字」那一行:一个图标、一句话。邀请码在用的时候,右边多一个
/// 「再问一遍还剩多少」的按钮。
struct LiveTextStatusRow: View {
    let source: LiveTextSource
    var isRefreshing = false
    /// 邀请码在用的时候才有。
    var onRefresh: (() -> Void)?

    var body: some View {
        SettingsFullRow {
            HStack(alignment: .center, spacing: Spacing.sm) {
                Image(systemName: source.symbol)
                    .font(.system(size: 14))
                    .foregroundColor(source.powersLiveText ? .brandAccent : .textTertiary)
                    .frame(width: 20)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(source.sentence)
                        .font(.bodyMedium)
                        .foregroundColor(.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings.live-text.source")
                    if case .invite = source {
                        Text(String(localized: "settings.live_text.shared_detail"))
                            .font(Font.sans11)
                            .foregroundColor(.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: Spacing.sm)

                if let onRefresh {
                    Button(action: onRefresh) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isRefreshing)
                    .help(String(localized: "community_invite.refresh"))
                    .accessibilityLabel(String(localized: "community_invite.refresh"))
                }
            }
        }
    }
}
