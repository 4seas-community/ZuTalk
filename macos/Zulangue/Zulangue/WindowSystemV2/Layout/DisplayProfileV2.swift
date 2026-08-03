import AppKit

/// Normalized display geometry used by the window layout engine.
///
/// The notch fields this type used to carry (`closedNotchSize`,
/// `hasPhysicalNotch`, the auxiliary top-area widths) existed to place the
/// Dynamic Island under the notch. That surface was replaced by the menu bar
/// and nothing read them afterwards, so they are gone along with it.
struct DisplayProfileV2: Equatable {
    let frame: NSRect
    let visibleFrame: NSRect
}

enum DisplayProfileResolverV2 {
    private static let fallbackScreenFrame = NSRect(x: 0, y: 0, width: 1512, height: 982)

    static func resolvePreferredScreen(from preferred: NSScreen?) -> NSScreen? {
        preferred ?? NSScreen.main ?? NSScreen.screens.first
    }

    static func resolveProfile(from preferred: NSScreen?) -> DisplayProfileV2 {
        guard let screen = resolvePreferredScreen(from: preferred) else {
            return DisplayProfileV2(
                frame: fallbackScreenFrame,
                visibleFrame: fallbackScreenFrame
            )
        }
        return DisplayProfileV2(frame: screen.frame, visibleFrame: screen.visibleFrame)
    }
}
