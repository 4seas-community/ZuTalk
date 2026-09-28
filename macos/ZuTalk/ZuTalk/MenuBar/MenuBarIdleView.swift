import AppKit
import SwiftUI

/// Idle state of the menu-bar popover — the launchpad. Recording starts right
/// here, the way ⌃⌥R does, without opening the main window first.
@MainActor
struct MenuBarIdleView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            MenuBarActionRow(
                systemImage: "record.circle.fill",
                title: String(localized: "menubar.action.start_recording"),
                shortcut: "⌃⌥R",
                tint: Color.signalRed,
                accessibilityID: AccessibilityID.menuBarRecordButton,
                action: "startRecording"
            )
            MenuBarActionRow(
                systemImage: "macwindow",
                title: String(localized: "menubar.action.open_main_window"),
                tint: Color.textSecondary,
                accessibilityID: "menu-bar.open-main-window",
                action: "openMainWindow"
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
    var shortcut: String? = nil
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
                if let shortcut {
                    Text(shortcut)
                        .font(Font.mono9)
                        .foregroundColor(Color.textTertiary)
                }
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
