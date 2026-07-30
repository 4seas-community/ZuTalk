import AppKit
import SwiftUI

/// Popover content shown when `MenuBarRuntimeStore.suppressionReason` is set.
/// Each reason names the underlying problem and may offer one remediation action.
@MainActor
struct MenuBarSuppressedView: View {
    let reason: MenuBarSuppressionReason

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: descriptor.iconName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(descriptor.tint)
                Text(descriptor.title)
                    .font(Font.sans13Medium)
                    .foregroundColor(Color.textPrimary)
                Spacer(minLength: 0)
            }
            Text(descriptor.body)
                .font(Font.sans11)
                .foregroundColor(Color.textSecondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            if let actionTitle = descriptor.actionTitle {
                Button(action: dispatchAction) {
                    HStack(spacing: Spacing.sm) {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 11, weight: .semibold))
                        Text(actionTitle)
                            .font(Font.sans11Medium)
                        Spacer(minLength: 0)
                    }
                    .foregroundColor(descriptor.tint)
                    .padding(.horizontal, Spacing.sm)
                    .frame(height: Spacing.xl)
                    // Filled chip with signal-tinted background carries the CTA weight.
                    // Border stays on the neutral line-10 stroke per MASTER.md §02
                    // ONE LINE (signal-tinted borders are reserved for active-tab
                    // underlines, not CTA chrome).
                    .background(
                        RoundedRectangle(cornerRadius: Radius.sm)
                            .fill(descriptor.tint.opacity(0.12))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.sm)
                            .stroke(Color.borderPanel, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var descriptor: Descriptor {
        Descriptor.descriptor(for: reason)
    }

    private func dispatchAction() {
        switch descriptor.action {
        case .openPrivacyMicrophonePane:
            if let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
            ) {
                NSWorkspace.shared.open(url)
            }
        case .openZulangueSettings:
            WindowCommandRouter.shared.requestOpenSettings()
        case .openMainWindow:
            WindowCommandRouter.shared.openMainWindow(detail: "menu-bar.suppression.onboarding")
        case nil:
            break
        }
        MenuBarCoordinator.shared.closePopover()
    }
}

extension MenuBarSuppressedView {
    enum Action: Equatable {
        case openPrivacyMicrophonePane
        case openZulangueSettings
        case openMainWindow
    }

    struct Descriptor {
        let iconName: String
        let tint: Color
        let title: String
        let body: String
        let actionTitle: String?
        let action: Action?

        static func descriptor(for reason: MenuBarSuppressionReason) -> Descriptor {
            switch reason {
            case .privacy:
                return Descriptor(
                    iconName: "mic.slash.fill",
                    tint: Color.accentOrange,
                    title: String(localized: "menubar.suppressed.privacy.title"),
                    body: String(localized: "menubar.suppressed.privacy.body"),
                    actionTitle: String(localized: "menubar.suppressed.privacy.action"),
                    action: .openPrivacyMicrophonePane
                )
            case .userDisabled:
                return Descriptor(
                    iconName: "moon.zzz.fill",
                    tint: Color.textSecondary,
                    title: String(localized: "menubar.suppressed.disabled.title"),
                    body: String(localized: "menubar.suppressed.disabled.body"),
                    actionTitle: String(localized: "menubar.suppressed.disabled.action"),
                    action: .openZulangueSettings
                )
            case .onboarding:
                return Descriptor(
                    iconName: "hand.point.up.left.fill",
                    tint: Color.accentColor,
                    title: String(localized: "menubar.suppressed.onboarding.title"),
                    body: String(localized: "menubar.suppressed.onboarding.body"),
                    actionTitle: String(localized: "menubar.suppressed.onboarding.action"),
                    action: .openMainWindow
                )
            }
        }
    }
}
