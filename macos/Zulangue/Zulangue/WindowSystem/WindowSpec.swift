import AppKit

enum WindowOwnershipMode: String {
    case coordinatorOwned
    case legacySceneManaged
}

enum WindowHostingPolicy: String {
    case fixedWindowOwned
    case contentSized
}

enum WindowFrameMutationPolicy: String {
    case coordinatorOnly
    case legacyModule
}

enum ManagedWindowFrameApplyStrategy: String {
    case setFrame
    case setFrameOriginPreservingSize
}

enum WindowMigrationPhase: String {
    case foundation
    case mainWindow
    case overlays
    case cleanup
}

enum ManagedWindowPresentationAction: String {
    case showAndFocus
    case orderFrontRegardless
    case showWindowAndOrderFront
    case showWindowAndMakeKey
}

enum ManagedWindowDismissAction: String {
    case orderOut
    case close
}

enum ManagedWindowBackgroundStyle {
    case systemDefault
    case clear
    case captionBackdrop
}

struct ManagedWindowPresentation {
    let presentAction: ManagedWindowPresentationAction
    let dismissAction: ManagedWindowDismissAction
    let activatesApp: Bool
}

struct ManagedWindowChrome {
    let level: NSWindow.Level?
    let collectionBehavior: NSWindow.CollectionBehavior
    let backgroundStyle: ManagedWindowBackgroundStyle
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

struct WindowSpec {
    let id: WindowSurfaceID
    let role: String
    let ownership: WindowOwnershipMode
    let hostingPolicy: WindowHostingPolicy
    let frameMutationPolicy: WindowFrameMutationPolicy
    let frameApplyStrategy: ManagedWindowFrameApplyStrategy
    let migrationPhase: WindowMigrationPhase
    let styleMask: NSWindow.StyleMask
    let initialContentRect: NSRect
    let presentation: ManagedWindowPresentation
    let chrome: ManagedWindowChrome
    let notes: String
}

extension WindowSpec {
    static func required(_ id: WindowSurfaceID) -> WindowSpec {
        guard let spec = baselineCatalog()[id] else {
            preconditionFailure("Missing baseline WindowSpec for \(id.rawValue)")
        }
        return spec
    }

    static func baselineCatalog() -> [WindowSurfaceID: WindowSpec] {
        baselineSpecs
    }

    private static let baselineSpecs: [WindowSurfaceID: WindowSpec] = [
            .main: WindowSpec(
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
                presentation: ManagedWindowPresentation(
                    presentAction: .showAndFocus,
                    dismissAction: .orderOut,
                    activatesApp: true
                ),
                chrome: ManagedWindowChrome(
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
                notes: "Main window is AppKit-owned by the V2 main window controller; content state changes stay inside a stable hosting root."
            ),
            .floatingPanel: WindowSpec(
                id: .floatingPanel,
                role: WindowSurfaceID.floatingPanel.role,
                ownership: .coordinatorOwned,
                hostingPolicy: .fixedWindowOwned,
                frameMutationPolicy: .coordinatorOnly,
                frameApplyStrategy: .setFrame,
                migrationPhase: .overlays,
                styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .resizable],
                initialContentRect: NSRect(x: 100, y: 100, width: 1000, height: 180),
                presentation: ManagedWindowPresentation(
                    presentAction: .orderFrontRegardless,
                    dismissAction: .orderOut,
                    activatesApp: false
                ),
                chrome: ManagedWindowChrome(
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
                notes: "Floating transcript overlay routes initial/default geometry through WindowLayoutEngine and coordinator frame application."
            ),
            .captionMirror: WindowSpec(
                id: .captionMirror,
                role: WindowSurfaceID.captionMirror.role,
                ownership: .coordinatorOwned,
                hostingPolicy: .fixedWindowOwned,
                frameMutationPolicy: .coordinatorOnly,
                frameApplyStrategy: .setFrame,
                migrationPhase: .overlays,
                styleMask: [.borderless],
                initialContentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
                presentation: ManagedWindowPresentation(
                    presentAction: .orderFrontRegardless,
                    dismissAction: .close,
                    activatesApp: false
                ),
                chrome: ManagedWindowChrome(
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
                notes: "Full-screen captions are screen-routed through WindowLayoutEngine and coordinator frame application."
            ),
            .operatorPanel: WindowSpec(
                id: .operatorPanel,
                role: WindowSurfaceID.operatorPanel.role,
                ownership: .coordinatorOwned,
                hostingPolicy: .fixedWindowOwned,
                frameMutationPolicy: .coordinatorOnly,
                frameApplyStrategy: .setFrame,
                migrationPhase: .cleanup,
                styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                initialContentRect: NSRect(x: 0, y: 0, width: 380, height: 600),
                presentation: ManagedWindowPresentation(
                    presentAction: .showWindowAndMakeKey,
                    dismissAction: .close,
                    activatesApp: false
                ),
                chrome: ManagedWindowChrome(
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
                notes: "Utility panel registers and lays out through the shared window system primitives."
            ),
        ]
}
