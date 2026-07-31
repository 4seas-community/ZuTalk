import SwiftUI

/// Settings-page entry for the community invite. Onboarding remains the
/// first-run path; this card lets users see the resources they own
/// (remaining shared hours) and redeem or replace an invitation code
/// without re-running onboarding.
struct CommunityInviteSettingsCard: View {
    @ObservedObject private var invite = CommunityInviteSession.shared
    @State private var code = ""
    @State private var isReplacing = false
    @State private var isConfirmingRemoval = false

    var body: some View {
        SettingsCard(
            title: String(localized: "community_invite.settings.title"),
            subtitle: String(localized: "community_invite.settings.subtitle")
        ) {
            if invite.isActive {
                remainingRow
                SettingsRowDivider()
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

    private var remainingRow: some View {
        SettingsRow(
            String(localized: "community_invite.resources.remaining"),
            description: String(localized: "community_invite.shared_detail")
        ) {
            HStack(spacing: Spacing.sm) {
                Label(remainingText, systemImage: "gift.fill")
                    .font(.bodyMedium)
                    .foregroundColor(.textPrimary)
                    .accessibilityIdentifier("settings.community-invite.remaining")

                Button {
                    Task { await invite.refreshQuota() }
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(invite.isWorking)
                .help(String(localized: "community_invite.refresh"))
                .accessibilityLabel(String(localized: "community_invite.refresh"))
            }
        }
    }

    private var sourceToggleRow: some View {
        SettingsRow(
            String(localized: "community_invite.use_toggle"),
            description: String(localized: "community_invite.use_toggle_detail")
        ) {
            Toggle(
                String(localized: "community_invite.use_toggle"),
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
        SettingsRow(
            String(localized: "community_invite.active"),
            description: String(localized: "community_invite.thirty_hours")
        ) {
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

    private var redeemEditor: some View {
        SettingsFullRow {
            redeemField
            if let error = invite.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.signalAmber)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var inactiveEditor: some View {
        SettingsFullRow {
            Label(
                String(localized: "community_invite.inactive"),
                systemImage: "gift"
            )
            .font(Font.sans12)
            .foregroundColor(.textPrimary)

            Text(String(localized: "community_invite.thirty_hours"))
                .font(Font.sans11)
                .foregroundColor(.textTertiary)
            Text(String(localized: "community_invite.shared_detail"))
                .font(Font.sans11)
                .foregroundColor(.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            redeemField
            if let error = invite.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.signalAmber)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var redeemField: some View {
        HStack(spacing: Spacing.sm) {
            TextField(
                String(localized: "community_invite.placeholder"),
                text: $code
            )
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 420)
            .frame(minHeight: 44)
            .disabled(invite.isWorking)
            .onSubmit(redeem)
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

    private var remainingText: String {
        guard let seconds = invite.remainingSeconds else {
            return String(localized: "community_invite.active")
        }
        let clamped = max(0, seconds)
        return String(
            format: String(localized: "community_invite.remaining_detail_format"),
            Int64(clamped / 3_600),
            Int64((clamped % 3_600) / 60)
        )
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
