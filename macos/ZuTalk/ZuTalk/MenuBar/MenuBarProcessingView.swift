import SwiftUI

/// Popover content shown during explicit asynchronous transcription. Tapping the
/// session button opens the active session in the main window.
@MainActor
struct MenuBarProcessingView: View {
    let info: ProcessingInfo

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(spacing: Spacing.sm) {
                if info.stage == .completed {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(Color.signalGreen)
                } else {
                    // SpinningArc's internal `.frame(size, size)` clamps the shape
                    // to the value passed in `size:`, so size the parameter rather
                    // than wrapping in an outer `.frame` (which would just leave
                    // empty padding around a 10pt default).
                    SpinningArc(color: info.color, size: 14)
                }
                Text(info.label)
                    .font(Font.sans12)
                    .foregroundColor(info.color)
                Spacer(minLength: 0)
                // The figure belongs to the status it measures, not on a
                // line of its own under the bar.
                if info.stage != .completed {
                    Text("\(Int(info.progress * 100))%")
                        .font(Font.monoNum11)
                        .foregroundColor(Color.textTertiary)
                }
            }

            if info.stage != .completed {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.bgPanel)
                        .frame(height: 4)
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(info.color)
                            .frame(
                                width: geo.size.width * info.progress,
                                height: 4
                            )
                    }
                    .frame(height: 4)
                }
            }

            Button(action: openSession) {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "rectangle.stack.fill")
                        .font(.system(size: 11, weight: .semibold))
                    Text(String(localized: "menubar.processing.open_session"))
                        .font(Font.sans11Medium)
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(Color.textTertiary)
                }
                .foregroundColor(Color.textSecondary)
                .padding(.horizontal, Spacing.sm)
                .frame(height: Spacing.xl)
            }
            .buttonStyle(.plain)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibilityLabel))
    }

    private var accessibilityLabel: String {
        if info.stage == .completed {
            return info.label
        }
        return "\(info.label) \(Int(info.progress * 100))%"
    }

    private func openSession() {
        WindowCommandRouter.shared.requestOpenSession(
            info.sessionId,
            revealMainWindow: true
        )
        MenuBarCoordinator.shared.closePopover()
    }
}
