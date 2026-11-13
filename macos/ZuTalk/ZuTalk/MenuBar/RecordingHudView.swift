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
            stateGlyph
            // White, not `textPrimary`: the capsule is black in both
            // appearances, and in the light one `textPrimary` is near-black —
            // the clock was unreadable there.
            Text(info.elapsedString)
                .font(Font.monoNum11)
                .foregroundColor(Color.white)
            // 字幕正在离开这台机器时,药丸上亮一粒琥珀色电波(§4.1)。
            // 药丸 ignoresMouseEvents,所以只给被动指示,不给按钮。
            ShareBroadcastGlyph()
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

    /// Recording → a pulsing dot in signal orange (the menu-bar icon's pulse
    /// hue); paused → a still pause mark in accent gold (the "held / not
    /// actively capturing" hue the MenuBarRecordingView popover uses).
    ///
    /// The pill used to spell the state out as "REC" / "PAUSED", in English
    /// whatever the interface language. A glyph says it in none: the shape
    /// carries the distinction, the color repeats it, and VoiceOver gets the
    /// words from the localized label below.
    @ViewBuilder
    private var stateGlyph: some View {
        if info.isPaused {
            Image(systemName: "pause.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(Color.accentGold)
                .frame(width: 8, height: 8)
        } else {
            PulsingDot(color: Color.accentOrange, size: 8)
        }
    }

    private var accessibilityLabel: String {
        let format = info.isPaused
            ? String(localized: "hud.a11y.recording_paused_format")
            : String(localized: "hud.a11y.recording_active_format")
        return String(format: format, info.elapsedString)
    }
}
