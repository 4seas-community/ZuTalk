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
    static let floatingPanelMinimumSize = NSSize(width: 560, height: 120)
    static let floatingPanelDefaultSize = NSSize(width: 1000, height: 180)
    static let floatingPanelMaximumWidth: CGFloat = 2200
    static let floatingPanelMaximumHeight: CGFloat = 800
    static let floatingPanelTopInset: CGFloat = 60

    static let operatorPanelDefaultSize = NSSize(width: 380, height: 600)

    static func layout(
        for id: WindowSurfaceID,
        input: WindowLayoutInput
    ) -> WindowLayoutResult? {
        switch id {
        case .main:
            return WindowLayoutResult(frame: mainWindowFrame(input: input))
        case .floatingPanel:
            return WindowLayoutResult(frame: floatingPanelFrame(input: input))
        case .captionMirror:
            return WindowLayoutResult(frame: input.screenFrame)
        case .operatorPanel:
            return WindowLayoutResult(frame: operatorPanelFrame(input: input))
        }
    }

    private static func mainWindowFrame(input: WindowLayoutInput) -> NSRect {
        MainWindowMetrics.launchFrame(in: input.visibleFrame)
    }

    private static func floatingPanelFrame(input: WindowLayoutInput) -> NSRect {
        if let saved = input.savedFrame,
           let normalized = normalizedFloatingPanelFrame(saved, visibleFrame: input.visibleFrame) {
            return normalized.integral
        }

        let width = min(
            floatingPanelMaximumWidth,
            max(floatingPanelDefaultSize.width, input.visibleFrame.width * 0.9)
        )
        let height = floatingPanelDefaultSize.height
        let origin = NSPoint(
            x: input.visibleFrame.midX - width / 2,
            y: input.visibleFrame.maxY - height - floatingPanelTopInset
        )
        return NSRect(origin: origin, size: NSSize(width: width, height: height)).integral
    }

    private static func operatorPanelFrame(input: WindowLayoutInput) -> NSRect {
        let origin = NSPoint(
            x: input.visibleFrame.maxX - operatorPanelDefaultSize.width - 48,
            y: input.visibleFrame.midY - operatorPanelDefaultSize.height / 2
        )
        return NSRect(origin: origin, size: operatorPanelDefaultSize).integral
    }

    private static func currentSize(from currentFrame: NSRect?, fallback: NSSize) -> NSSize {
        guard let currentFrame,
              currentFrame.width > 0,
              currentFrame.height > 0 else {
            return fallback
        }
        return currentFrame.size
    }

    private static func normalizedFloatingPanelFrame(
        _ frame: NSRect,
        visibleFrame: NSRect
    ) -> NSRect? {
        guard visibleFrame.intersects(frame) else {
            return nil
        }

        let maxWidth = min(floatingPanelMaximumWidth, visibleFrame.width)
        let maxHeight = min(
            floatingPanelMaximumHeight,
            max(floatingPanelMinimumSize.height, visibleFrame.height - floatingPanelTopInset)
        )

        guard maxWidth >= floatingPanelMinimumSize.width,
              maxHeight >= floatingPanelMinimumSize.height else {
            return nil
        }

        let width = min(max(frame.width, floatingPanelMinimumSize.width), maxWidth)
        let height = min(max(frame.height, floatingPanelMinimumSize.height), maxHeight)
        let originX = min(max(frame.minX, visibleFrame.minX), visibleFrame.maxX - width)
        let originY = min(max(frame.minY, visibleFrame.minY), visibleFrame.maxY - height)
        let normalized = NSRect(
            x: originX,
            y: originY,
            width: width,
            height: height
        )

        return normalized
    }
}
