import AppKit

// Normalized display geometry used by the window layout engine. Notch-related
// values remain part of the tested display contract.

struct DisplayProfileV2: Equatable {
    let screenID: String
    let localizedName: String
    let frame: NSRect
    let visibleFrame: NSRect
    let hasPhysicalNotch: Bool
    let safeAreaTopInset: CGFloat
    let topLeftAuxiliaryWidth: CGFloat?
    let topRightAuxiliaryWidth: CGFloat?
    let menuBarHeight: CGFloat
    let closedNotchSize: CGSize
}

enum DisplayProfileResolverV2 {
    private static let fallbackScreenFrame = NSRect(x: 0, y: 0, width: 1512, height: 982)
    private static let fallbackNotchWidth: CGFloat = 185
    private static let notchWidthBuffer: CGFloat = 4
    /// Margin reserved on each side of the closed notch when sanity-clamping computed width.
    /// Mirrors Atoll/boring.notch's safety net: even when AppKit reports degenerate
    /// auxiliaryTopLeftArea/auxiliaryTopRightArea (negative widths, missing values, scaled
    /// displays with unusual menubar geometry), the notch can never cover the full menubar.
    private static let notchSideClearance: CGFloat = 60
    /// Floor for the maximum-allowed-notch calculation so it stays sane even when a screen is
    /// reported as absurdly narrow (some virtual / sidecar displays do this).
    private static let minimumNotchAffordance: CGFloat = 400

    /// Upper bound on the closed-notch width for a screen of `screenWidth` points. Atoll uses
    /// the same `max(screenWidth - 60, 400)` formula. On a normal MBP this is huge (~1668) and
    /// never trips; the value matters only when the underlying API returns garbage.
    static func maxAllowedNotchWidth(forScreenWidth screenWidth: CGFloat) -> CGFloat {
        max(screenWidth - notchSideClearance, minimumNotchAffordance)
    }

    static func resolvePreferredScreen(from preferred: NSScreen?) -> NSScreen? {
        preferred ?? NSScreen.main ?? NSScreen.screens.first
    }

    static func resolveProfile(from preferred: NSScreen?) -> DisplayProfileV2 {
        guard let screen = resolvePreferredScreen(from: preferred) else {
            return resolveProfile(
                screenFrame: fallbackScreenFrame,
                visibleFrame: fallbackScreenFrame,
                safeAreaTopInset: 0,
                topLeftAuxiliaryWidth: nil,
                topRightAuxiliaryWidth: nil,
                localizedName: "fallback"
            )
        }

        return resolveProfile(
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            safeAreaTopInset: screen.safeAreaInsets.top,
            topLeftAuxiliaryWidth: screen.auxiliaryTopLeftArea?.width,
            topRightAuxiliaryWidth: screen.auxiliaryTopRightArea?.width,
            localizedName: screen.localizedName,
            screenID: screen.localizedName
        )
    }

    static func resolveProfile(
        screenFrame: NSRect,
        visibleFrame: NSRect,
        safeAreaTopInset: CGFloat,
        topLeftAuxiliaryWidth: CGFloat?,
        topRightAuxiliaryWidth: CGFloat?,
        localizedName: String,
        screenID: String = UUID().uuidString
    ) -> DisplayProfileV2 {
        let hasPhysicalNotch = topLeftAuxiliaryWidth != nil
            && topRightAuxiliaryWidth != nil
            && safeAreaTopInset > 0
        let menuBarHeight = max(screenFrame.maxY - visibleFrame.maxY, 24)
        let closedNotchSize: CGSize

        let maxAllowed = maxAllowedNotchWidth(forScreenWidth: screenFrame.width)
        if let left = topLeftAuxiliaryWidth, let right = topRightAuxiliaryWidth, hasPhysicalNotch {
            let computed = screenFrame.width - left - right + notchWidthBuffer
            closedNotchSize = CGSize(
                width: max(0, min(computed, maxAllowed)),
                height: safeAreaTopInset
            )
        } else {
            closedNotchSize = CGSize(
                width: min(fallbackNotchWidth, maxAllowed),
                height: menuBarHeight
            )
        }

        return DisplayProfileV2(
            screenID: screenID,
            localizedName: localizedName,
            frame: screenFrame,
            visibleFrame: visibleFrame,
            hasPhysicalNotch: hasPhysicalNotch,
            safeAreaTopInset: safeAreaTopInset,
            topLeftAuxiliaryWidth: topLeftAuxiliaryWidth,
            topRightAuxiliaryWidth: topRightAuxiliaryWidth,
            menuBarHeight: menuBarHeight,
            closedNotchSize: closedNotchSize
        )
    }
}
