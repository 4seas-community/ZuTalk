import AppKit

struct PointerRegionV2: Equatable {
    let name: String
    let rect: NSRect
}

struct PointerRegionSetV2: Equatable {
    let visualRegion: PointerRegionV2
    let hoverRegion: PointerRegionV2
    let panelRegion: PointerRegionV2?
}

struct WindowMousePolicyV2: Equatable {
    let ignoresMouseEvents: Bool
    let localTrackingRegions: PointerRegionSetV2?
    let closeOnOutsideClick: Bool
    let allowHoverActivation: Bool
}

struct WindowSystemStateV2: Equatable {
    let appIsActive: Bool
    let mainWindowVisible: Bool
    let activeSurface: WindowSurfaceID?
    let suppressedSurfaces: Set<WindowSurfaceID>

    static let `default` = WindowSystemStateV2(
        appIsActive: true,
        mainWindowVisible: true,
        activeSurface: nil,
        suppressedSurfaces: []
    )
}

struct WindowLayoutRequestV2: Equatable {
    let surfaceID: WindowSurfaceID
    let display: DisplayProfileV2
    let systemState: WindowSystemStateV2
    let currentFrame: NSRect?
    let savedFrame: NSRect?

    init(
        surfaceID: WindowSurfaceID,
        display: DisplayProfileV2,
        systemState: WindowSystemStateV2,
        currentFrame: NSRect? = nil,
        savedFrame: NSRect? = nil
    ) {
        self.surfaceID = surfaceID
        self.display = display
        self.systemState = systemState
        self.currentFrame = currentFrame
        self.savedFrame = savedFrame
    }
}

struct WindowLayoutSnapshotV2 {
    enum Anchor: Equatable {
        case topCenter
        case captionButton
        case bottomCenter
        case trailingCenter
        case fullscreenOverlay
    }

    let surfaceID: WindowSurfaceID
    let outerFrame: NSRect
    let visualFrame: NSRect?
    let anchor: Anchor
    let pointerRegions: PointerRegionSetV2?
    let contentInsets: NSEdgeInsets
    let mousePolicy: WindowMousePolicyV2
}

enum WindowLayoutEngineV2 {
    private static let floatingPanelMinimumSize = NSSize(width: 560, height: 120)
    private static let floatingPanelDefaultSize = NSSize(width: 1000, height: 180)
    private static let floatingPanelMaximumWidth: CGFloat = 2200
    private static let floatingPanelMaximumHeight: CGFloat = 800
    private static let floatingPanelTopInset: CGFloat = 60
    private static let zeroInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

    static func snapshot(for request: WindowLayoutRequestV2) -> WindowLayoutSnapshotV2? {
        switch request.surfaceID {
        case .main:
            return mainWindowSnapshot(for: request)
        case .floatingPanel:
            return floatingPanelSnapshot(for: request)
        case .captionMirror:
            return captionWindowSnapshot(for: request)
        case .operatorPanel:
            return operatorPanelSnapshot(for: request)
        }
    }

    static func mainWindowSnapshot(for request: WindowLayoutRequestV2) -> WindowLayoutSnapshotV2 {
        WindowLayoutSnapshotV2(
            surfaceID: .main,
            outerFrame: MainWindowMetrics.launchFrame(in: request.display.visibleFrame),
            visualFrame: nil,
            anchor: .topCenter,
            pointerRegions: nil,
            contentInsets: zeroInsets,
            mousePolicy: WindowMousePolicyV2(
                ignoresMouseEvents: false,
                localTrackingRegions: nil,
                closeOnOutsideClick: false,
                allowHoverActivation: false
            )
        )
    }

    static func floatingPanelSnapshot(for request: WindowLayoutRequestV2) -> WindowLayoutSnapshotV2 {
        let frame: NSRect
        if let savedFrame = request.savedFrame,
           let normalized = normalizedFloatingPanelFrame(savedFrame, visibleFrame: request.display.visibleFrame) {
            frame = normalized.integral
        } else {
            let width = min(
                floatingPanelMaximumWidth,
                max(floatingPanelDefaultSize.width, request.display.visibleFrame.width * 0.9)
            )
            let height = floatingPanelDefaultSize.height
            frame = NSRect(
                x: request.display.visibleFrame.midX - width / 2,
                y: request.display.visibleFrame.maxY - height - floatingPanelTopInset,
                width: width,
                height: height
            ).integral
        }

        return WindowLayoutSnapshotV2(
            surfaceID: .floatingPanel,
            outerFrame: frame,
            visualFrame: frame,
            anchor: .topCenter,
            pointerRegions: nil,
            contentInsets: zeroInsets,
            mousePolicy: WindowMousePolicyV2(
                ignoresMouseEvents: false,
                localTrackingRegions: nil,
                closeOnOutsideClick: false,
                allowHoverActivation: false
            )
        )
    }

    static func captionWindowSnapshot(for request: WindowLayoutRequestV2) -> WindowLayoutSnapshotV2 {
        WindowLayoutSnapshotV2(
            surfaceID: .captionMirror,
            outerFrame: request.display.frame,
            visualFrame: request.display.frame,
            anchor: .fullscreenOverlay,
            pointerRegions: nil,
            contentInsets: zeroInsets,
            mousePolicy: WindowMousePolicyV2(
                ignoresMouseEvents: false,
                localTrackingRegions: nil,
                closeOnOutsideClick: false,
                allowHoverActivation: false
            )
        )
    }

    static func operatorPanelSnapshot(for request: WindowLayoutRequestV2) -> WindowLayoutSnapshotV2 {
        let size = NSSize(width: 380, height: 600)
        let frame = NSRect(
            x: request.display.visibleFrame.maxX - size.width - 48,
            y: request.display.visibleFrame.midY - size.height / 2,
            width: size.width,
            height: size.height
        ).integral

        return WindowLayoutSnapshotV2(
            surfaceID: .operatorPanel,
            outerFrame: frame,
            visualFrame: frame,
            anchor: .trailingCenter,
            pointerRegions: nil,
            contentInsets: zeroInsets,
            mousePolicy: WindowMousePolicyV2(
                ignoresMouseEvents: false,
                localTrackingRegions: nil,
                closeOnOutsideClick: false,
                allowHoverActivation: false
            )
        )
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
        return NSRect(x: originX, y: originY, width: width, height: height)
    }
}
