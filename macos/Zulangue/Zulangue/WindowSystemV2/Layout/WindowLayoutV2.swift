import AppKit

struct WindowLayoutRequestV2: Equatable {
    let surfaceID: WindowSurfaceID
    let display: DisplayProfileV2
    let currentFrame: NSRect?
    let savedFrame: NSRect?

    init(
        surfaceID: WindowSurfaceID,
        display: DisplayProfileV2,
        currentFrame: NSRect? = nil,
        savedFrame: NSRect? = nil
    ) {
        self.surfaceID = surfaceID
        self.display = display
        self.currentFrame = currentFrame
        self.savedFrame = savedFrame
    }
}

struct WindowLayoutSnapshotV2 {
    let surfaceID: WindowSurfaceID
    let outerFrame: NSRect
}

enum WindowLayoutEngineV2 {
    static func snapshot(for request: WindowLayoutRequestV2) -> WindowLayoutSnapshotV2? {
        switch request.surfaceID {
        case .main:
            return mainWindowSnapshot(for: request)
        case .subtitleOverlay:
            return subtitleOverlaySnapshot(for: request)
        }
    }

    static func mainWindowSnapshot(for request: WindowLayoutRequestV2) -> WindowLayoutSnapshotV2 {
        WindowLayoutSnapshotV2(
            surfaceID: .main,
            outerFrame: MainWindowMetrics.launchFrame(in: request.display.visibleFrame)
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
        return WindowLayoutSnapshotV2(surfaceID: .subtitleOverlay, outerFrame: frame)
    }
}
