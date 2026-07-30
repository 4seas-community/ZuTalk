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
    private static let zeroInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

    static func snapshot(for request: WindowLayoutRequestV2) -> WindowLayoutSnapshotV2? {
        switch request.surfaceID {
        case .main:
            return mainWindowSnapshot(for: request)
        case .subtitleOverlay:
            return subtitleOverlaySnapshot(for: request)
        }
    }

    static func mainWindowSnapshot(for request: WindowLayoutRequestV2) -> WindowLayoutSnapshotV2 {
        snapshot(
            surfaceID: .main,
            frame: MainWindowMetrics.launchFrame(in: request.display.visibleFrame)
        )
    }

    static func subtitleOverlaySnapshot(
        for request: WindowLayoutRequestV2
    ) -> WindowLayoutSnapshotV2 {
        let input = WindowLayoutInput(
            screenFrame: request.display.frame,
            visibleFrame: request.display.visibleFrame,
            currentFrame: request.currentFrame,
            savedFrame: request.savedFrame
        )
        let frame = WindowLayoutEngine.layout(for: .subtitleOverlay, input: input)?.frame
            ?? WindowSpecV2.required(.subtitleOverlay).initialContentRect
        return snapshot(surfaceID: .subtitleOverlay, frame: frame)
    }

    private static func snapshot(
        surfaceID: WindowSurfaceID,
        frame: NSRect
    ) -> WindowLayoutSnapshotV2 {
        WindowLayoutSnapshotV2(
            surfaceID: surfaceID,
            outerFrame: frame,
            visualFrame: surfaceID == .subtitleOverlay ? frame : nil,
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
}
