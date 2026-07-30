import AppKit

struct WindowSpecV2 {
    enum Ownership: String {
        case coordinatorOwned
        case legacySceneManaged
    }

    enum HostingPolicy: String {
        case fixedWindowOwned
        case contentSized
    }

    enum FrameMutationPolicy: String {
        case coordinatorOnly
        case legacyModule
    }

    enum FrameApplyStrategy: String {
        case setFrame
        case setFrameOriginPreservingSize
    }

    enum MigrationPhase: String {
        case foundation
        case mainWindow
        case overlays
        case cleanup
    }

    enum PresentationAction: String {
        case showAndFocus
        case orderFrontRegardless
        case showWindowAndOrderFront
        case showWindowAndMakeKey
    }

    enum DismissAction: String {
        case orderOut
        case close
    }

    enum BackgroundStyle {
        case systemDefault
        case clear
        case captionBackdrop
    }

    struct Presentation {
        let presentAction: PresentationAction
        let dismissAction: DismissAction
        let activatesApp: Bool
    }

    struct Chrome {
        let level: NSWindow.Level?
        let collectionBehavior: NSWindow.CollectionBehavior
        let backgroundStyle: BackgroundStyle
        let isFloatingPanel: Bool
        let hasShadow: Bool
        let isOpaque: Bool
        let titleVisibility: NSWindow.TitleVisibility
        let titlebarAppearsTransparent: Bool
        let isMovable: Bool?
        let isMovableByWindowBackground: Bool?
        let ignoresMouseEvents: Bool?
        let hidesOnDeactivate: Bool?
        let animationBehavior: NSWindow.AnimationBehavior
        let minimumWindowSize: NSSize?
        let minimumContentSize: NSSize?
        let maximumContentSize: NSSize?
    }

    let id: WindowSurfaceID
    let role: String
    let ownership: Ownership
    let hostingPolicy: HostingPolicy
    let frameMutationPolicy: FrameMutationPolicy
    let frameApplyStrategy: FrameApplyStrategy
    let migrationPhase: MigrationPhase
    let styleMask: NSWindow.StyleMask
    let initialContentRect: NSRect
    let presentation: Presentation
    let chrome: Chrome
    let notes: String
}

extension WindowSpecV2 {
    static func required(_ id: WindowSurfaceID) -> WindowSpecV2 {
        guard let spec = baselineCatalog()[id] else {
            preconditionFailure("Missing V2 WindowSpec for \(id.rawValue)")
        }
        return spec
    }

    static func baselineCatalog() -> [WindowSurfaceID: WindowSpecV2] {
        baselineSpecs
    }

    private static let baselineSpecs: [WindowSurfaceID: WindowSpecV2] = [
        .main: WindowSpecV2(
            id: .main,
            role: WindowSurfaceID.main.role,
            ownership: .coordinatorOwned,
            hostingPolicy: .fixedWindowOwned,
            frameMutationPolicy: .coordinatorOnly,
            frameApplyStrategy: .setFrame,
            migrationPhase: .mainWindow,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            initialContentRect: NSRect(
                x: 0,
                y: 0,
                width: MainWindowMetrics.defaultWidth,
                height: MainWindowMetrics.defaultHeight
            ),
            presentation: Presentation(
                presentAction: .showAndFocus,
                dismissAction: .orderOut,
                activatesApp: true
            ),
            chrome: Chrome(
                level: nil,
                collectionBehavior: [.fullScreenPrimary],
                backgroundStyle: .systemDefault,
                isFloatingPanel: false,
                hasShadow: true,
                isOpaque: true,
                titleVisibility: .hidden,
                titlebarAppearsTransparent: true,
                isMovable: nil,
                isMovableByWindowBackground: nil,
                ignoresMouseEvents: nil,
                hidesOnDeactivate: nil,
                animationBehavior: .default,
                minimumWindowSize: NSSize(
                    width: MainWindowMetrics.minWidth,
                    height: MainWindowMetrics.minHeight
                ),
                minimumContentSize: nil,
                maximumContentSize: nil
            ),
            notes: "AppKit owns the main window. V2 keeps content state changes inside a stable hosting root."
        ),
        .floatingPanel: WindowSpecV2(
            id: .floatingPanel,
            role: WindowSurfaceID.floatingPanel.role,
            ownership: .coordinatorOwned,
            hostingPolicy: .fixedWindowOwned,
            frameMutationPolicy: .coordinatorOnly,
            frameApplyStrategy: .setFrame,
            migrationPhase: .overlays,
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .resizable],
            initialContentRect: NSRect(x: 100, y: 100, width: 1000, height: 180),
            presentation: Presentation(
                presentAction: .orderFrontRegardless,
                dismissAction: .orderOut,
                activatesApp: false
            ),
            chrome: Chrome(
                level: .floating,
                collectionBehavior: [.canJoinAllSpaces, .fullScreenAuxiliary],
                backgroundStyle: .clear,
                isFloatingPanel: true,
                hasShadow: true,
                isOpaque: false,
                titleVisibility: .hidden,
                titlebarAppearsTransparent: true,
                isMovable: nil,
                isMovableByWindowBackground: true,
                ignoresMouseEvents: nil,
                hidesOnDeactivate: nil,
                animationBehavior: .utilityWindow,
                minimumWindowSize: nil,
                minimumContentSize: NSSize(width: 560, height: 120),
                maximumContentSize: NSSize(width: 2400, height: 800)
            ),
            notes: "Floating transcript overlay stays under coordinator layout authority."
        ),
        .captionMirror: WindowSpecV2(
            id: .captionMirror,
            role: WindowSurfaceID.captionMirror.role,
            ownership: .coordinatorOwned,
            hostingPolicy: .fixedWindowOwned,
            frameMutationPolicy: .coordinatorOnly,
            frameApplyStrategy: .setFrame,
            migrationPhase: .overlays,
            styleMask: [.borderless],
            initialContentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
            presentation: Presentation(
                presentAction: .orderFrontRegardless,
                dismissAction: .close,
                activatesApp: false
            ),
            chrome: Chrome(
                level: .floating,
                collectionBehavior: [.canJoinAllSpaces, .fullScreenAuxiliary],
                backgroundStyle: .captionBackdrop,
                isFloatingPanel: false,
                hasShadow: false,
                isOpaque: false,
                titleVisibility: .hidden,
                titlebarAppearsTransparent: true,
                isMovable: false,
                isMovableByWindowBackground: nil,
                ignoresMouseEvents: false,
                hidesOnDeactivate: nil,
                animationBehavior: .none,
                minimumWindowSize: nil,
                minimumContentSize: nil,
                maximumContentSize: nil
            ),
            notes: "Caption windows are screen-routed overlays with centralized lifecycle."
        ),
        .operatorPanel: WindowSpecV2(
            id: .operatorPanel,
            role: WindowSurfaceID.operatorPanel.role,
            ownership: .coordinatorOwned,
            hostingPolicy: .fixedWindowOwned,
            frameMutationPolicy: .coordinatorOnly,
            frameApplyStrategy: .setFrame,
            migrationPhase: .cleanup,
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            initialContentRect: NSRect(x: 0, y: 0, width: 380, height: 600),
            presentation: Presentation(
                presentAction: .showWindowAndMakeKey,
                dismissAction: .close,
                activatesApp: false
            ),
            chrome: Chrome(
                level: .floating,
                collectionBehavior: [],
                backgroundStyle: .systemDefault,
                isFloatingPanel: true,
                hasShadow: true,
                isOpaque: true,
                titleVisibility: .visible,
                titlebarAppearsTransparent: false,
                isMovable: nil,
                isMovableByWindowBackground: nil,
                ignoresMouseEvents: nil,
                hidesOnDeactivate: false,
                animationBehavior: .utilityWindow,
                minimumWindowSize: nil,
                minimumContentSize: nil,
                maximumContentSize: nil
            ),
            notes: "Operator panels are utility windows managed by the shared V2 window system."
        ),
    ]
}
