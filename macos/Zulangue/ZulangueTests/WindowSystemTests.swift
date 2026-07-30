import XCTest
import SwiftUI
@testable import Zulangue

@MainActor
private final class TrafficLightWindowActionsSpy: TrafficLightWindowActions {
    enum Invocation: Equatable {
        case close
        case miniaturize
        case toggleFullScreen
    }

    private(set) var invocations: [Invocation] = []

    func closeFromTrafficLight() {
        invocations.append(.close)
    }

    func miniaturizeFromTrafficLight() {
        invocations.append(.miniaturize)
    }

    func toggleFullScreenFromTrafficLight() {
        invocations.append(.toggleFullScreen)
    }
}

@MainActor
private final class ApplicationQuitRequestingSpy: ApplicationQuitRequesting {
    private(set) var requestCount = 0

    func requestApplicationQuit() {
        requestCount += 1
    }
}

@MainActor
final class WindowSystemTests: XCTestCase {

    override func setUp() {
        super.setUp()
        WindowCoordinator.shared.resetForTesting()
    }

    override func tearDown() {
        WindowCoordinator.shared.resetForTesting()
        super.tearDown()
    }

    func testWindowCoordinator_installBaselineCatalog_containsAllKnownWindowSurfaces() {
        WindowCoordinator.shared.installBaselineCatalog()

        let snapshot = WindowCoordinator.shared.catalogSnapshot()
        let ids = Set(snapshot.map(\.id))

        XCTAssertEqual(ids, Set(WindowSurfaceID.allCases))
        XCTAssertEqual(WindowCoordinator.shared.spec(for: .main)?.frameMutationPolicy, .coordinatorOnly)
        XCTAssertEqual(
            WindowCoordinator.shared.spec(for: .subtitleOverlay)?.presentation.dismissAction,
            .orderOut
        )
    }

    func testWindowCoordinator_registerWindow_tracksWindowBySurfaceID() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        WindowCoordinator.shared.registerWindow(window, id: .main)

        XCTAssertTrue(WindowCoordinator.shared.isRegistered(.main))
        XCTAssertTrue(WindowCoordinator.shared.window(for: .main) === window)
    }

    func testWindowCoordinator_applyFrame_updatesRegisteredWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 10, y: 10, width: 320, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        WindowCoordinator.shared.registerWindow(window, id: .subtitleOverlay)

        let target = NSRect(x: 40, y: 60, width: 420, height: 260)
        let applied = WindowCoordinator.shared.applyFrame(
            target,
            to: .subtitleOverlay,
            reason: "unit-test"
        )

        XCTAssertTrue(applied)
        XCTAssertEqual(window.frame, target)
    }

    func testManagedWindowRuntime_applyUsesCatalogChromeForSubtitleOverlay() {
        let spec = WindowSpec.required(.subtitleOverlay)
        let panel = NSPanel(
            contentRect: spec.initialContentRect,
            styleMask: spec.styleMask,
            backing: .buffered,
            defer: false
        )

        ManagedWindowRuntime.apply(spec: spec, to: panel)

        XCTAssertEqual(panel.level, .floating)
        XCTAssertEqual(panel.collectionBehavior, [.canJoinAllSpaces, .fullScreenAuxiliary])
        XCTAssertEqual(panel.contentMinSize, NSSize(width: 560, height: 180))
        XCTAssertEqual(panel.contentMaxSize, NSSize(width: 2600, height: 1000))
        XCTAssertTrue(panel.isFloatingPanel)
        XCTAssertFalse(panel.hidesOnDeactivate)
    }

    @available(macOS 13.0, *)
    func testWindowHosting_makeView_fixedWindowOwnedDisablesHostingSizing() {
        let hosting = WindowHosting.makeView(rootView: Color.clear.frame(width: 300, height: 200))

        XCTAssertEqual(hosting.sizingOptions, [])
        if #available(macOS 15.0, *) {
            XCTAssertEqual(hosting.sceneBridgingOptions, [])
        }
    }

    @available(macOS 13.0, *)
    func testWindowHosting_makeController_fixedWindowOwnedDisablesHostingSizing() {
        let hosting = WindowHosting.makeController(rootView: Color.clear.frame(width: 300, height: 200))

        XCTAssertEqual(hosting.sizingOptions, [])
        if #available(macOS 15.0, *) {
            XCTAssertEqual(hosting.sceneBridgingOptions, [])
        }
    }

    func testWindowSpecV2_baselineCatalog_containsAllKnownWindowSurfaces() {
        let snapshot = WindowSpecV2.baselineCatalog()
        let ids = Set(snapshot.keys)

        XCTAssertEqual(ids, Set(WindowSurfaceID.allCases))
    }

    func testMainWindowSpecV2_supportsNativeFullScreenSpace() {
        let legacySpec = WindowSpec.required(.main)
        let spec = WindowSpecV2.required(.main)
        let window = NSWindow(
            contentRect: spec.initialContentRect,
            styleMask: spec.styleMask,
            backing: .buffered,
            defer: false
        )

        ManagedWindowRuntimeV2.apply(spec: spec, to: window)

        XCTAssertTrue(spec.styleMask.contains(.resizable))
        XCTAssertTrue(legacySpec.chrome.collectionBehavior.contains(.fullScreenPrimary))
        XCTAssertTrue(
            window.collectionBehavior.contains(.fullScreenPrimary),
            "The green traffic-light button should enter a native macOS full-screen Space"
        )
    }

    func testGreenTrafficLightAction_togglesNativeFullScreen() {
        let window = TrafficLightWindowActionsSpy()

        TrafficLightAction.fullScreen.perform(on: window)

        XCTAssertEqual(window.invocations, [.toggleFullScreen])
    }

    func testApplicationQuitAction_requestsApplicationTermination() {
        let application = ApplicationQuitRequestingSpy()

        ApplicationQuitAction.perform(on: application)

        XCTAssertEqual(application.requestCount, 1)
    }

    func testApplicationQuitConfirmationPolicy_onlyWarnsForUnfinishedRecording() {
        XCTAssertTrue(ApplicationQuitConfirmationPolicy.requiresConfirmation(for: .recording))
        XCTAssertTrue(ApplicationQuitConfirmationPolicy.requiresConfirmation(for: .paused))
        XCTAssertFalse(ApplicationQuitConfirmationPolicy.requiresConfirmation(for: .draining))
        XCTAssertFalse(ApplicationQuitConfirmationPolicy.requiresConfirmation(for: .completed))
        XCTAssertFalse(ApplicationQuitConfirmationPolicy.requiresConfirmation(for: .interrupted))
        XCTAssertFalse(ApplicationQuitConfirmationPolicy.requiresConfirmation(for: .failed))
        XCTAssertFalse(ApplicationQuitConfirmationPolicy.requiresConfirmation(for: nil))
    }

    func testMenuBarPopover_exposesVisibleSafeQuitControl() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Zulangue", isDirectory: true)
        let source = root.appendingPathComponent("MenuBar/MenuBarPopoverRootView.swift")
        let contents = try String(contentsOf: source, encoding: .utf8)

        XCTAssertTrue(contents.contains("ApplicationQuitAction.perform(on: NSApp)"))
        XCTAssertTrue(contents.contains("\"menubar.action.quit\""))
        XCTAssertTrue(contents.contains("\"menubar.action.quit_hint\""))
        XCTAssertTrue(contents.contains("AccessibilityID.menuBarQuitButton"))
        XCTAssertFalse(contents.contains("activeRecordingInfo"))
        XCTAssertFalse(contents.contains(".confirmationDialog("))
        XCTAssertFalse(contents.contains("exit(0)"))
    }

    func testMenuBarQuitCopy_isLocalizedInEverySupportedAppLanguage() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Zulangue/Resources", isDirectory: true)
        let keys = [
            "menubar.action.quit",
            "menubar.action.quit_hint",
            "app.quit.confirm.title",
            "app.quit.confirm.message",
            "app.quit.confirm.cancel",
            "app.quit.confirm.action",
        ]

        for languageDirectory in ["en.lproj", "zh-Hans.lproj", "ja.lproj"] {
            let strings = try String(
                contentsOf: root
                    .appendingPathComponent(languageDirectory, isDirectory: true)
                    .appendingPathComponent("Localizable.strings"),
                encoding: .utf8
            )
            for key in keys {
                XCTAssertTrue(
                    strings.contains("\"\(key)\" ="),
                    "\(languageDirectory) is missing \(key)"
                )
            }
        }
    }

    @available(macOS 13.0, *)
    func testWindowHostingV2_makeView_disablesHostingSizingForFixedWindowOwnedViews() {
        let hosting = WindowHostingV2.makeView(rootView: Color.clear.frame(width: 200, height: 100))

        XCTAssertEqual(hosting.sizingOptions, [])
        if #available(macOS 15.0, *) {
            XCTAssertEqual(hosting.sceneBridgingOptions, [])
        }
    }

    func testWindowHostingV2_makeView_acceptsFirstMouseForControlSurfaces() {
        let hosting = WindowHostingV2.makeView(rootView: Color.clear.frame(width: 200, height: 100))

        XCTAssertTrue(hosting.acceptsFirstMouse(for: nil))
    }

    func testWindowHostingV2_makeControllerView_acceptsFirstMouseForControlSurfaces() {
        let controller = WindowHostingV2.makeController(rootView: Color.clear.frame(width: 200, height: 100))

        XCTAssertTrue(controller.view.acceptsFirstMouse(for: nil))
    }

    @available(macOS 13.0, *)
    func testWindowHostingV2_makeController_configuresReplacementHostingViewBeforeInstallation() throws {
        let controller = WindowHostingV2.makeController(
            rootView: Color.clear.frame(width: 200, height: 100)
        )
        let replacementView = controller.view
        let replacementHosting = try XCTUnwrap(
            replacementView as? any HostingSizingConfigurableV2
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        XCTAssertEqual(replacementHosting.sizingOptions, [])
        window.contentViewController = controller
        let installedFrame = window.frame
        let installedContentMinSize = window.contentMinSize
        let installedContentMaxSize = window.contentMaxSize

        let stabilization = WindowHostingV2.stabilizeWindowTree(on: window)
        window.contentView?.layoutSubtreeIfNeeded()
        let repeatedStabilization = WindowHostingV2.stabilizeWindowTree(on: window)

        XCTAssertTrue(window.contentView === replacementView)
        XCTAssertEqual(window.frame, installedFrame)
        XCTAssertEqual(window.contentMinSize, installedContentMinSize)
        XCTAssertEqual(window.contentMaxSize, installedContentMaxSize)
        XCTAssertEqual(
            stabilization.totalDisabled,
            0,
            "The controller factory must configure the replacement NSHostingView before installation"
        )
        XCTAssertEqual(repeatedStabilization.totalDisabled, 0)
    }

    func testManagedWindowRuntimeV2_applyUsesCatalogChromeForSubtitleOverlay() {
        let spec = WindowSpecV2.required(.subtitleOverlay)
        let panel = NSPanel(
            contentRect: spec.initialContentRect,
            styleMask: spec.styleMask,
            backing: .buffered,
            defer: false
        )

        ManagedWindowRuntimeV2.apply(spec: spec, to: panel)

        XCTAssertEqual(panel.level, .floating)
        XCTAssertEqual(panel.collectionBehavior, [.canJoinAllSpaces, .fullScreenAuxiliary])
        XCTAssertEqual(panel.contentMinSize, NSSize(width: 560, height: 180))
        XCTAssertEqual(panel.contentMaxSize, NSSize(width: 2600, height: 1000))
        XCTAssertTrue(panel.isFloatingPanel)
        XCTAssertFalse(panel.hidesOnDeactivate)
    }

    func testMainNavigationStoreV2_openNotebookTabKeepsSessionAsContext() {
        let store = MainNavigationStoreV2()

        store.openNotebookTab(
            notebookID: "nb-1",
            tabID: "tab-live",
            documentID: "doc-live",
            selectedSessionID: "session-1"
        )

        XCTAssertEqual(store.activeNotebookID, "nb-1")
        XCTAssertEqual(store.activeNotebookTabID, "tab-live")
        XCTAssertEqual(store.activeDocID, "doc-live")
        XCTAssertEqual(store.selectedSessionID, "session-1")
        XCTAssertEqual(store.pendingEditorView, .notes)
    }

    func testGlobalCaptureRouteReturnsToCaptureNotebookAfterUserBrowsesAnotherNotebook() throws {
        let tempDir = NSTemporaryDirectory()
            .appending("zulangue-capture-route-\(UUID().uuidString)")
        let core = try ZulangueCore.newDeferred(dataDir: tempDir)
        defer {
            try? core.shutdown()
            try? FileManager.default.removeItem(atPath: tempDir)
        }
        let notebookA = try core.createNotebook(title: "Notebook A")
        let notebookB = try core.createNotebook(title: "Notebook B")
        let notebookContext = NotebookSessionContextStore(
            activeNotebookId: notebookB.id,
            activeNotebookTitle: notebookB.title
        )
        let store = MainNavigationStoreV2(
            activeNotebookIDProvider: { notebookB.id },
            captureRouteContextProvider: { (notebookA.id, "session-a", true) },
            coreProvider: { core },
            notebookContext: notebookContext
        )

        store.openActiveNotebookForCapture()

        XCTAssertEqual(store.activeNotebookID, notebookA.id)
        XCTAssertEqual(store.activeNotebookTabID, try core.listNotebookTabs(notebookId: notebookA.id)
            .first(where: { $0.builtinKind == "realtime_transcript" })?.id)
        XCTAssertEqual(store.selectedSessionID, "session-a")
        XCTAssertEqual(store.activeNotebookTitle, notebookA.title)
        XCTAssertEqual(notebookContext.activeNotebookId, notebookA.id)
        XCTAssertEqual(notebookContext.activeNotebookTitle, notebookA.title)

        notebookContext.updateActiveNotebook(id: notebookB.id, title: notebookB.title)
        XCTAssertEqual(
            store.activeNotebookTitle,
            notebookA.title,
            "the editor title must stay bound to its route instead of a separately browsed Notebook"
        )
    }

    func testMainShellViewV2_exposesOnlyMinimalMVPNavigation() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Zulangue", isDirectory: true)
        let source = root.appendingPathComponent("UIScenesV2/Main/MainShellViewV2.swift")
        let contents = try String(contentsOf: source, encoding: .utf8)

        XCTAssertTrue(contents.contains("@State private var isSidebarHidden"))
        XCTAssertTrue(contents.contains("if isSidebarHidden == false"))
        XCTAssertTrue(contents.contains("sidebarRevealButton"))
        XCTAssertTrue(contents.contains("expandedSidebar"))
        XCTAssertFalse(contents.contains("collapsedSidebar"))
        XCTAssertFalse(contents.contains("sidebarWidth"))
        XCTAssertFalse(contents.contains(".frame(width: 64)"))

        for destination in ["sidebar.home", "sidebar.trash", "sidebar.tab.settings"] {
            XCTAssertTrue(contents.contains(destination), "\(destination) should be present in the MVP navigation shell")
        }
        for deferredDestination in [
            "store.select(tab: .people)",
            "store.select(tab: .knowledge)",
            "store.select(tab: .templates)",
            "store.select(tab: .activity)"
        ] {
            XCTAssertFalse(contents.contains(deferredDestination))
        }

        XCTAssertFalse(contents.contains(".frame(width: 240)"))
        XCTAssertTrue(contents.contains(".accessibilityLabel(String(localized: \"sidebar.collapse\"))"))
        XCTAssertTrue(contents.contains(".accessibilityLabel(String(localized: \"sidebar.tab.settings\"))"))
        XCTAssertTrue(contents.contains(".accessibilityLabel(label)"))
        XCTAssertTrue(contents.contains(".accessibilityAddTraits(active ? .isSelected : [])"))
        XCTAssertTrue(contents.contains(".accessibilityAddTraits(activeTab == .config ? .isSelected : [])"))

        let navigationSource = root
            .appendingPathComponent("UIScenesV2/Main/MainNavigationStoreV2.swift")
        let navigationContents = try String(contentsOf: navigationSource, encoding: .utf8)
        XCTAssertFalse(navigationContents.contains("detail: error.localizedDescription"))
        XCTAssertFalse(navigationContents.contains("detail: \"\\(error)\""))
        XCTAssertTrue(navigationContents.contains("privacy: .private"))
    }

    func testMainShellViewV2_placesTheSidebarCollapseControlInTheHeader() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Zulangue", isDirectory: true)
        let source = root.appendingPathComponent("UIScenesV2/Main/MainShellViewV2.swift")
        let contents = try String(contentsOf: source, encoding: .utf8)

        let expandedStart = try XCTUnwrap(contents.range(of: "private var expandedSidebar: some View"))
        let expandedEnd = try XCTUnwrap(
            contents[expandedStart.upperBound...].range(of: "private var sidebarHeader: some View")
        )
        let expandedSidebar = String(contents[expandedStart.lowerBound..<expandedEnd.lowerBound])

        let headerStart = try XCTUnwrap(contents.range(of: "private var sidebarHeader: some View"))
        let headerEnd = try XCTUnwrap(
            contents[headerStart.upperBound...].range(of: "private var sidebarBrand: some View")
        )
        let sidebarHeader = String(contents[headerStart.lowerBound..<headerEnd.lowerBound])

        XCTAssertTrue(expandedSidebar.contains("sidebarHeader"))
        XCTAssertFalse(expandedSidebar.contains("sidebarCollapseButton"))
        XCTAssertTrue(sidebarHeader.contains("sidebarCollapseButton"))
    }

    func testWindowCoordinator_showMainWindow_registersCoordinatorOwnedV2MainWindow() {
        WindowCoordinator.shared.showMainWindow()

        XCTAssertTrue(WindowCoordinator.shared.isMainWindowReadyForOpen())
        XCTAssertNotNil(WindowCoordinator.shared.mainWindowControllerForTesting)
        XCTAssertTrue(WindowCoordinator.shared.isRegistered(.main))
    }

    func testWindowCoordinator_mainSurfaceQueries_useDirectCoordinatorOwnership() throws {
        WindowCoordinator.shared.showMainWindow()
        let window = try XCTUnwrap(WindowCoordinator.shared.mainWindowControllerForTesting?.window)

        XCTAssertTrue(WindowCoordinator.shared.isRegistered(.main))
        XCTAssertTrue(WindowCoordinator.shared.window(for: .main) === window)
    }

    func testWindowCoordinator_presentSubtitleOverlay_ownsSingleOverlayDirectly() {
        let store = ActiveBilingualTranscriptStore()

        let panel = WindowCoordinator.shared.presentSubtitleOverlay(store: store)

        XCTAssertTrue(panel === WindowCoordinator.shared.subtitleOverlayForTesting)
        XCTAssertTrue(WindowCoordinator.shared.window(for: .subtitleOverlay) === panel)
        XCTAssertTrue(panel.isVisible)

        WindowCoordinator.shared.dismissSubtitleOverlay()

        XCTAssertFalse(WindowCoordinator.shared.isRegistered(.subtitleOverlay))
        XCTAssertFalse(panel.isVisible)
    }

    func testSubtitleOverlayController_isMovableResizablePersistentAcrossApps() throws {
        let store = ActiveBilingualTranscriptStore()

        let controller = SubtitleOverlayController(store: store)
        defer { controller.close() }

        XCTAssertTrue(controller.storeForTesting === store)
        XCTAssertNil(controller.managedWindow.contentViewController)
        let contentView: NSView = try XCTUnwrap(controller.managedWindow.contentView)
        XCTAssertFalse(contentView.subviews.isEmpty)
        XCTAssertEqual(controller.managedWindow.level, NSWindow.Level.floating)
        XCTAssertTrue(controller.managedWindow.styleMask.contains(.resizable))
        XCTAssertTrue(controller.managedWindow.isMovable)
        XCTAssertTrue(controller.managedWindow.isMovableByWindowBackground)
        XCTAssertFalse((controller.managedWindow as? NSPanel)?.hidesOnDeactivate ?? true)
    }

    func testSubtitleOverlayFontPolicy_clampsAndStepsWithinReadableRange() {
        XCTAssertEqual(SubtitleOverlayFontPolicy.clamped(2), 18)
        XCTAssertEqual(SubtitleOverlayFontPolicy.clamped(100), 64)
        XCTAssertEqual(SubtitleOverlayFontPolicy.smaller(than: 30), 26)
        XCTAssertEqual(SubtitleOverlayFontPolicy.larger(than: 30), 34)
        XCTAssertEqual(SubtitleOverlayFontPolicy.smaller(than: 18), 18)
        XCTAssertEqual(SubtitleOverlayFontPolicy.larger(than: 64), 64)
    }

    func testWindowCoordinator_registrySnapshot_listsAllKnownWindowSurfaces() {
        WindowCoordinator.shared.installBaselineCatalog()

        let snapshot = WindowCoordinator.shared.registrySnapshot()

        XCTAssertEqual(snapshot.count, WindowSurfaceID.allCases.count)
        XCTAssertTrue(snapshot.contains { $0.contains("surface=main") })
        XCTAssertTrue(snapshot.contains { $0.contains("surface=subtitleOverlay") })
    }

    // MARK: - DisplayProfileResolverV2 notch-width clamp

    func testDisplayProfileResolverV2_clampsNotchWidthAgainstScreenAffordance() {
        // 14" MBP at native scaling — typical case, computed width 178pt fits well below the
        // ceiling so the clamp must not interfere.
        let normal = DisplayProfileResolverV2.resolveProfile(
            screenFrame: NSRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: NSRect(x: 0, y: 0, width: 1512, height: 950),
            safeAreaTopInset: 32,
            topLeftAuxiliaryWidth: 666,
            topRightAuxiliaryWidth: 668,
            localizedName: "Built-in"
        )
        XCTAssertEqual(normal.closedNotchSize.width, 1512 - 666 - 668 + 4)
    }

    func testDisplayProfileResolverV2_caps184ptNotchToScreenAffordanceMinus60() {
        // Pathological case: AppKit reports near-zero auxiliary widths so the formula tries to
        // give us a notch as wide as the entire screen. The clamp must shrink it to
        // max(screenWidth - 60, 400).
        let pathological = DisplayProfileResolverV2.resolveProfile(
            screenFrame: NSRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: NSRect(x: 0, y: 0, width: 1512, height: 950),
            safeAreaTopInset: 32,
            topLeftAuxiliaryWidth: 1,
            topRightAuxiliaryWidth: 1,
            localizedName: "Sidecar"
        )
        XCTAssertLessThanOrEqual(pathological.closedNotchSize.width, 1512 - 60)
        XCTAssertEqual(
            pathological.closedNotchSize.width,
            DisplayProfileResolverV2.maxAllowedNotchWidth(forScreenWidth: 1512)
        )
    }

    func testDisplayProfileResolverV2_clampFloorIs400OnAbsurdlyNarrowScreens() {
        XCTAssertEqual(
            DisplayProfileResolverV2.maxAllowedNotchWidth(forScreenWidth: 200),
            400
        )
        XCTAssertEqual(
            DisplayProfileResolverV2.maxAllowedNotchWidth(forScreenWidth: 460),
            400
        )
        XCTAssertEqual(
            DisplayProfileResolverV2.maxAllowedNotchWidth(forScreenWidth: 1512),
            1452
        )
    }

    func testDisplayProfileResolverV2_clampsNonNotchFallbackWidth() {
        let profile = DisplayProfileResolverV2.resolveProfile(
            screenFrame: NSRect(x: 0, y: 0, width: 2560, height: 1440),
            visibleFrame: NSRect(x: 0, y: 0, width: 2560, height: 1416),
            safeAreaTopInset: 0,
            topLeftAuxiliaryWidth: nil,
            topRightAuxiliaryWidth: nil,
            localizedName: "External"
        )
        XCTAssertEqual(profile.closedNotchSize.width, 185)
    }
}
