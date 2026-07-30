import SwiftUI

/// Root view inside the menu-bar `NSPopover`. Switches on
/// `MenuBarRuntimeStore.state` (plus suppression) and renders the matching
/// subview. Suppression beats state — a privacy-blocked mic gets the
/// remediation panel even mid-recording so the user knows why audio stopped.
@MainActor
struct MenuBarPopoverRootView: View {
    @ObservedObject var store: MenuBarRuntimeStore

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Group {
                if let reason = store.suppressionReason {
                    MenuBarSuppressedView(reason: reason)
                } else {
                    stateView
                }
            }

            Divider()

            quitButton
        }
        .frame(width: 320)
        .padding(Spacing.md)
        .background(Color.bgSurface)
    }

    @ViewBuilder
    private var stateView: some View {
        switch store.state {
        case .idle:
            MenuBarIdleView()
        case .recordingCompact(let info):
            MenuBarRecordingView(info: info, recentLines: store.cachedRecentLines)
        case .recordingExpanded(let info, let lines):
            MenuBarRecordingView(info: info, recentLines: lines)
        case .backgroundProcessing(let info):
            MenuBarProcessingView(info: info)
        }
    }

    private var quitButton: some View {
        Button(action: requestQuit) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "power")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color.brandAccent)
                    .frame(width: 18, alignment: .center)
                Text(String(localized: "menubar.action.quit"))
                    .font(Font.sans12)
                    .foregroundColor(Color.textPrimary)
                Spacer(minLength: 0)
                Text("⌘Q")
                    .font(Font.mono9)
                    .foregroundColor(Color.textTertiary)
            }
            .padding(.horizontal, Spacing.sm)
            .frame(height: Spacing.xl)
            .background(
                RoundedRectangle(cornerRadius: Radius.sm)
                    .fill(Color.brandAccentSoft)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(String(localized: "menubar.action.quit_hint"))
        .accessibilityLabel(Text(String(localized: "menubar.action.quit")))
        .accessibilityHint(Text(String(localized: "menubar.action.quit_hint")))
        .accessibilityIdentifier(AccessibilityID.menuBarQuitButton)
    }

    private func requestQuit() {
        ApplicationQuitAction.perform(on: NSApp)
    }
}
