import AppKit
import SwiftUI

/// Idle state of the menu-bar popover — the launchpad. Replaces the prior
/// island idle hover-expanded panel (`IdleHoverExpandedView`). Capture routes
/// into the Notebook; overlay windows remain read-only viewer infrastructure.
@MainActor
struct MenuBarIdleView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            MenuBarActionRow(
                systemImage: "record.circle.fill",
                title: String(localized: "capture.mirror.open_notebook"),
                tint: Color.brandAccent,
                accessibilityID: AccessibilityID.menuBarRecordButton,
                action: "recording"
            )
            MenuBarActionRow(
                systemImage: "gearshape.fill",
                title: String(localized: "menubar.action.settings"),
                tint: Color.textSecondary,
                accessibilityID: AccessibilityID.menuBarSettingsButton,
                action: "settings"
            )
            MenuBarActionRow(
                systemImage: "arrow.triangle.2.circlepath",
                title: String(localized: "updates.check"),
                tint: Color.textSecondary,
                accessibilityID: AccessibilityID.menuBarCheckForUpdatesButton,
                action: "checkForUpdates"
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MenuBarActionRow: View {
    let systemImage: String
    let title: String
    let tint: Color
    let accessibilityID: String
    let action: String

    @State private var isHovering = false

    var body: some View {
        Button(action: trigger) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(tint)
                    .frame(width: 18, alignment: .center)
                Text(title)
                    .font(Font.sans12)
                    .foregroundColor(Color.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Spacing.sm)
            .frame(height: Spacing.xl)
            .background(
                RoundedRectangle(cornerRadius: Radius.sm)
                    .fill(isHovering ? Color.white.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityID)
        .accessibilityLabel(Text(title))
        .onHover { hovering in
            isHovering = hovering
        }
    }

    private func trigger() {
        let item = NSMenuItem()
        item.representedObject = action
        NSApp.sendMenuBarAction(item)
        MenuBarCoordinator.shared.closePopover()
    }
}
