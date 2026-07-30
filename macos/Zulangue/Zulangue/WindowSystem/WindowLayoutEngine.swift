import AppKit

struct WindowLayoutInput: Equatable {
    let screenFrame: NSRect
    let visibleFrame: NSRect
    let currentFrame: NSRect?
    let savedFrame: NSRect?

    init(
        screenFrame: NSRect,
        visibleFrame: NSRect,
        currentFrame: NSRect? = nil,
        savedFrame: NSRect? = nil
    ) {
        self.screenFrame = screenFrame
        self.visibleFrame = visibleFrame
        self.currentFrame = currentFrame
        self.savedFrame = savedFrame
    }

    init?(
        screen: NSScreen?,
        currentFrame: NSRect? = nil,
        savedFrame: NSRect? = nil
    ) {
        guard let screen = screen ?? NSScreen.main ?? NSScreen.screens.first else {
            return nil
        }
        self.init(
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            currentFrame: currentFrame,
            savedFrame: savedFrame
        )
    }
}

struct WindowLayoutResult: Equatable {
    let frame: NSRect
}

enum WindowLayoutEngine {
    static let subtitleOverlayMinimumSize = NSSize(width: 560, height: 180)
    static let subtitleOverlayDefaultSize = NSSize(width: 1100, height: 280)
    static let subtitleOverlayMaximumWidth: CGFloat = 2600
    static let subtitleOverlayMaximumHeight: CGFloat = 1000
    static let subtitleOverlayTopInset: CGFloat = 36

    static func layout(
        for id: WindowSurfaceID,
        input: WindowLayoutInput
    ) -> WindowLayoutResult? {
        switch id {
        case .main:
            return WindowLayoutResult(frame: MainWindowMetrics.launchFrame(in: input.visibleFrame))
        case .subtitleOverlay:
            return WindowLayoutResult(frame: subtitleOverlayFrame(input: input))
        }
    }

    private static func subtitleOverlayFrame(input: WindowLayoutInput) -> NSRect {
        if let saved = input.savedFrame,
           let normalized = normalizedSubtitleOverlayFrame(
               saved,
               visibleFrame: input.visibleFrame
           ) {
            return normalized.integral
        }

        let width = min(
            subtitleOverlayMaximumWidth,
            max(
                subtitleOverlayMinimumSize.width,
                min(subtitleOverlayDefaultSize.width, input.visibleFrame.width * 0.92)
            )
        )
        let height = min(subtitleOverlayDefaultSize.height, input.visibleFrame.height * 0.42)
        return NSRect(
            x: input.visibleFrame.midX - width / 2,
            y: input.visibleFrame.maxY - height - subtitleOverlayTopInset,
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
