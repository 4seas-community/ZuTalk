import AppKit

/// Normalized display geometry used by the window layout engine.
///
/// The notch fields this type used to carry (`closedNotchSize`,
/// `hasPhysicalNotch`, the auxiliary top-area widths) existed to place the
/// Dynamic Island under the notch. That surface was replaced by the menu bar
/// and nothing read them afterwards, so they are gone along with it.
struct DisplayProfile: Equatable {
    let frame: NSRect
    let visibleFrame: NSRect
}

enum DisplayProfileResolver {
    private static let fallbackScreenFrame = NSRect(x: 0, y: 0, width: 1512, height: 982)

    static func resolvePreferredScreen(from preferred: NSScreen?) -> NSScreen? {
        preferred ?? NSScreen.main ?? NSScreen.screens.first
    }

    static func resolveProfile(from preferred: NSScreen?) -> DisplayProfile {
        guard let screen = resolvePreferredScreen(from: preferred) else {
            return DisplayProfile(
                frame: fallbackScreenFrame,
                visibleFrame: fallbackScreenFrame
            )
        }
        return DisplayProfile(frame: screen.frame, visibleFrame: screen.visibleFrame)
    }
}
