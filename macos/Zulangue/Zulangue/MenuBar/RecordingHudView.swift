import SwiftUI

/// Content of the full-screen recording-state pill. Mirrors the menu-bar icon's
/// signal-orange pulsing semantics so the same "currently happening" reading
/// applies regardless of which surface the user sees.
///
/// Constitution carve-out: the capsule fill is `Color.black.opacity(0.88)`
/// (not a `Tokens.swift` token). The pill overlays arbitrary full-screen app
/// content where `bgPanel` (#141414) would be invisible against dark video or
/// dim Keynote backgrounds. Saturated black + 12% transparency reads against
/// any background and is the same treatment Apple's own recording HUDs use.
/// Documented here rather than promoting a `Color.hudPanelFill` token —
/// there is currently no second consumer.
@MainActor
struct RecordingHudView: View {
    let info: RecordingInfo

    var body: some View {
        HStack(spacing: Spacing.sm) {
            PulsingDot(color: dotColor, size: 8)
            Text(label)
                .font(Font.mono9)
                .foregroundColor(dotColor)
                .tracking(1.0)
            Text(info.elapsedString)
                .font(Font.monoNum11)
                .foregroundColor(Color.textPrimary)
        }
        .padding(.horizontal, Spacing.sm)
        .frame(height: Spacing.lg)
        .background(
            Capsule().fill(Color.black.opacity(0.88))
        )
        .overlay(
            Capsule().stroke(Color.borderPanel, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibilityLabel))
    }

    /// Recording → signal orange (matches the menu-bar icon's pulse hue);
    /// Paused → accent gold (the same "held / not actively capturing" hue the
    /// MenuBarRecordingView popover uses, and the §06.17 `LiveIndicator`
    /// `.completed` family). Glyph + label carry the state distinction; the
    /// color shift is a redundant cue for users glancing at the pill.
    private var dotColor: Color {
        info.isPaused
            ? Color.accentGold
            : Color.accentOrange
    }

    private var label: String {
        info.isPaused
            ? String(localized: "hud.recording.paused")
            : String(localized: "hud.recording.active")
    }

    private var accessibilityLabel: String {
        let format = info.isPaused
            ? String(localized: "hud.a11y.recording_paused_format")
            : String(localized: "hud.a11y.recording_active_format")
        return String(format: format, info.elapsedString)
    }
}
