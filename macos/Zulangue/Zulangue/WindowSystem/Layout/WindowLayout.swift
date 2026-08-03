import AppKit

struct WindowLayoutRequest: Equatable {
    let surfaceID: WindowSurfaceID
    let display: DisplayProfile
    let currentFrame: NSRect?
    let savedFrame: NSRect?

    init(
        surfaceID: WindowSurfaceID,
        display: DisplayProfile,
        currentFrame: NSRect? = nil,
        savedFrame: NSRect? = nil
    ) {
        self.surfaceID = surfaceID
        self.display = display
        self.currentFrame = currentFrame
        self.savedFrame = savedFrame
    }
}

struct WindowLayoutSnapshot: Equatable {
    let surfaceID: WindowSurfaceID
    let outerFrame: NSRect
}

enum WindowLayoutEngine {
    static let subtitleOverlayMinimumSize = NSSize(width: 560, height: 180)
    static let subtitleOverlayDefaultSize = NSSize(width: 1100, height: 280)
    static let subtitleOverlayMaximumWidth: CGFloat = 2600
    static let subtitleOverlayMaximumHeight: CGFloat = 1000
    static let subtitleOverlayTopInset: CGFloat = 36

    static func snapshot(for request: WindowLayoutRequest) -> WindowLayoutSnapshot? {
        switch request.surfaceID {
        case .main:
            return mainWindowSnapshot(for: request)
        case .subtitleOverlay:
            return subtitleOverlaySnapshot(for: request)
        }
    }

    static func mainWindowSnapshot(for request: WindowLayoutRequest) -> WindowLayoutSnapshot {
        WindowLayoutSnapshot(
            surfaceID: .main,
            outerFrame: MainWindowMetrics.launchFrame(in: request.display.visibleFrame)
        )
    }

    static func subtitleOverlaySnapshot(
        for request: WindowLayoutRequest
    ) -> WindowLayoutSnapshot {
        WindowLayoutSnapshot(
            surfaceID: .subtitleOverlay,
            outerFrame: subtitleOverlayFrame(for: request)
        )
    }

    /// A saved frame wins when it can still be made to fit the current screen;
    /// otherwise the overlay returns to a top-centered default. Both results
    /// are integral so AppKit does not resolve them onto half points.
    private static func subtitleOverlayFrame(for request: WindowLayoutRequest) -> NSRect {
        let visibleFrame = request.display.visibleFrame
        if let saved = request.savedFrame,
           let normalized = normalizedSubtitleOverlayFrame(saved, visibleFrame: visibleFrame) {
            return normalized.integral
        }

        let width = min(
            subtitleOverlayMaximumWidth,
            max(
                subtitleOverlayMinimumSize.width,
                min(subtitleOverlayDefaultSize.width, visibleFrame.width * 0.92)
            )
        )
        let height = min(subtitleOverlayDefaultSize.height, visibleFrame.height * 0.42)
        return NSRect(
            x: visibleFrame.midX - width / 2,
            y: visibleFrame.maxY - height - subtitleOverlayTopInset,
            width: width,
            height: height
        ).integral
    }

    private static func normalizedSubtitleOverlayFrame(
        _ frame: NSRect,
        visibleFrame: NSRect
    ) -> NSRect? {
        guard visibleFrame.intersects(frame) else { return nil }

        let maxWidth = min(subtitleOverlayMaximumWidth, visibleFrame.width)
        let maxHeight = min(subtitleOverlayMaximumHeight, visibleFrame.height)
        guard maxWidth >= subtitleOverlayMinimumSize.width,
              maxHeight >= subtitleOverlayMinimumSize.height else {
            return nil
        }

        let width = min(max(frame.width, subtitleOverlayMinimumSize.width), maxWidth)
        let height = min(max(frame.height, subtitleOverlayMinimumSize.height), maxHeight)
        let originX = min(max(frame.minX, visibleFrame.minX), visibleFrame.maxX - width)
        let originY = min(max(frame.minY, visibleFrame.minY), visibleFrame.maxY - height)
        return NSRect(x: originX, y: originY, width: width, height: height)
    }
}
