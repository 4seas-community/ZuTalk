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
private final class NotebookCoreAvailability {
    var core: (any ZulangueCoreProtocol)?
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

    func testCustomTrafficLights_mountOnWindowFrameInsteadOfTitlebar() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let originalContentView = try XCTUnwrap(window.contentView)
        let windowFrameView = try XCTUnwrap(originalContentView.superview)
        let titlebarView = try XCTUnwrap(window.standardWindowButton(.closeButton)?.superview)

        let controls = try XCTUnwrap(
            WindowChromeConfigurator.shared.installCustomTrafficLights(on: window)
        )

        XCTAssertTrue(controls.superview === windowFrameView)
        XCTAssertFalse(controls.superview === titlebarView)
        XCTAssertEqual(controls.intrinsicContentSize, NSSize(width: 92, height: 44))

        window.contentViewController = NSViewController()

        XCTAssertTrue(controls.superview === windowFrameView)
        XCTAssertTrue(controls.window === window)
    }

    func testCustomTrafficLights_areHiddenUntilPointerEntersHotZone() throws {
        let controls = CustomTrafficLightsView()
        let mouseEvent = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .mouseMoved,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                eventNumber: 0,
                clickCount: 0,
                pressure: 0
            )
        )

        XCTAssertFalse(controls.isHovering)

        controls.mouseEntered(with: mouseEvent)
        XCTAssertTrue(controls.isHovering)

        controls.mouseExited(with: mouseEvent)
        XCTAssertFalse(controls.isHovering)
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

        let languageDirectories = AppLanguage.allCases.map { "\($0.rawValue).lproj" }
        for languageDirectory in languageDirectories {
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

    func testAppLanguagePickerPrioritizesThaiAndKeepsRequestedRegionalOrder() {
        XCTAssertEqual(
            AppLanguage.allCases.map(\.rawValue),
            ["th", "en", "fr", "es", "de", "ko", "ja", "zh-Hans"]
        )
        XCTAssertEqual(AppLanguage.match("ko-KR"), .ko)
        XCTAssertEqual(AppLanguage.en.rawValue, "en")
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

    func testMainNavigationStoreV2_restoresLastNotebookOnceOnLaunch() throws {
        let tempDir = NSTemporaryDirectory()
            .appending("zulangue-launch-notebook-\(UUID().uuidString)")
        let core = try ZulangueCore.newDeferred(dataDir: tempDir)
        defer {
            try? core.shutdown()
            try? FileManager.default.removeItem(atPath: tempDir)
        }
        _ = try core.createNotebook(title: "Notebook A")
        let notebookB = try core.createNotebook(title: "Notebook B")
        let notebookContext = NotebookSessionContextStore(
            activeNotebookId: notebookB.id,
            activeNotebookTitle: nil
        )
        let store = MainNavigationStoreV2(
            activeNotebookIDProvider: { notebookContext.activeNotebookId },
            captureRouteContextProvider: { (nil, nil, false) },
            coreProvider: { core },
            notebookContext: notebookContext
        )
        store.completeOnboarding()

        store.restoreLastNotebookOnLaunch()

        XCTAssertEqual(store.activeTab, .editor)
        XCTAssertEqual(store.activeNotebookID, notebookB.id)
        XCTAssertEqual(
            store.activeNotebookTabID,
            try core.listNotebookTabs(notebookId: notebookB.id)
                .first(where: { $0.builtinKind == "realtime_transcript" })?.id
        )
        XCTAssertEqual(store.activeNotebookTitle, notebookB.title)

        store.navigateHome()
        store.restoreLastNotebookOnLaunch()
        XCTAssertEqual(store.activeTab, .home, "launch restoration must not trap later Home navigation")
    }

    func testMainNavigationStoreV2_retriesLaunchRestoreAfterCoreBecomesAvailable() throws {
        let tempDir = NSTemporaryDirectory()
            .appending("zulangue-retry-launch-notebook-\(UUID().uuidString)")
        let core = try ZulangueCore.newDeferred(dataDir: tempDir)
        defer {
            try? core.shutdown()
            try? FileManager.default.removeItem(atPath: tempDir)
        }
        let notebook = try core.createNotebook(title: "Retry Notebook")
        let notebookContext = NotebookSessionContextStore(
            activeNotebookId: notebook.id,
            activeNotebookTitle: nil
        )
        let availability = NotebookCoreAvailability()
        let store = MainNavigationStoreV2(
            activeNotebookIDProvider: { notebookContext.activeNotebookId },
            captureRouteContextProvider: { (nil, nil, false) },
            coreProvider: { availability.core },
            notebookContext: notebookContext
        )
        store.completeOnboarding()

        XCTAssertFalse(store.restoreLastNotebookOnLaunch())
        XCTAssertEqual(store.activeTab, .home)

        availability.core = core
        XCTAssertTrue(store.restoreLastNotebookOnLaunch())
        XCTAssertEqual(store.activeTab, .editor)
        XCTAssertEqual(store.activeNotebookID, notebook.id)
    }

    func testMainNavigationStoreV2_staleNotebookFallsBackToAnAvailableNotebook() throws {
        let tempDir = NSTemporaryDirectory()
            .appending("zulangue-stale-notebook-\(UUID().uuidString)")
        let core = try ZulangueCore.newDeferred(dataDir: tempDir)
        defer {
            try? core.shutdown()
            try? FileManager.default.removeItem(atPath: tempDir)
        }
        let available = try core.createNotebook(title: "Available")
        let notebookContext = NotebookSessionContextStore(
            activeNotebookId: "deleted-notebook",
            activeNotebookTitle: nil
        )
        let store = MainNavigationStoreV2(
            activeNotebookIDProvider: { notebookContext.activeNotebookId },
            captureRouteContextProvider: { (nil, nil, false) },
            coreProvider: { core },
            notebookContext: notebookContext
        )

        store.openActiveNotebookForCapture()

        XCTAssertEqual(store.activeNotebookID, available.id)
        XCTAssertEqual(notebookContext.activeNotebookId, available.id)
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

        for destination in [
            "sidebar.home",
            "sidebar.knowledge",
            "sidebar.trash",
            "sidebar.tab.settings"
        ] {
            XCTAssertTrue(contents.contains(destination), "\(destination) should be present in the MVP navigation shell")
        }
        for deferredDestination in [
            "store.select(tab: .people)",
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

    func testKnowledgeProfile_compilesEnabledFieldsIntoSonioxContext() {
        var profile = KnowledgeProfile(name: "Chiang Mai Forum")
        profile.general.topic = "Anthropology"
        profile.general.people = "Somchai Prasert"
        profile.backgroundText = "A forum in Chiang Mai."
        profile.terms = [
            KnowledgeTerm(value: "Zuzalu"),
            KnowledgeTerm(value: "disabled", isEnabled: false),
        ]
        profile.translationTerms = [
            KnowledgeTranslationTerm(
                sourceText: "participant observation",
                targetText: "参与式观察"
            )
        ]

        let context = profile.sonioxContext
        XCTAssertEqual(context.general.map(\.key), ["topic", "people"])
        XCTAssertEqual(context.text, "A forum in Chiang Mai.")
        XCTAssertEqual(context.terms, ["Zuzalu"])
        XCTAssertEqual(context.translationTerms.first?.target, "参与式观察")
    }

    func testKnowledgeProfileStore_hasNoPlaintextSidecarAuthority() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Zulangue/Pages/KnowledgeLibraryPage.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("private let client: any NotebookCaptureClienting"))
        XCTAssertFalse(source.contains("init(fileURL:"))
        XCTAssertFalse(source.contains("knowledge-profiles.json"))
    }

    func testNotebookRealtimeHistoryScopesLivePreviewObservationToActiveRun() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Zulangue", isDirectory: true)
        let source = root.appendingPathComponent("Pages/NotebookCaptureViews.swift")
        let contents = try String(contentsOf: source, encoding: .utf8)

        let historyStart = try XCTUnwrap(
            contents.range(of: "private struct NotebookRealtimeHistoryView: View")
        )
        let activeRunStart = try XCTUnwrap(
            contents[historyStart.upperBound...]
                .range(of: "private struct NotebookRealtimeActiveRunView: View")
        )
        let navigatorStart = try XCTUnwrap(
            contents[activeRunStart.upperBound...]
                .range(of: "private struct NotebookRealtimeRunNavigator: View")
        )
        let historyView = String(
            contents[historyStart.lowerBound..<activeRunStart.lowerBound]
        )
        let activeRunView = String(
            contents[activeRunStart.lowerBound..<navigatorStart.lowerBound]
        )

        XCTAssertFalse(historyView.contains("@ObservedObject private var livePresentation"))
        XCTAssertFalse(historyView.contains("capture.livePreviewUtterances"))
        XCTAssertFalse(historyView.contains("capture.presentedTranslationCueSnapshot"))
        XCTAssertTrue(historyView.contains("NotebookRealtimeActiveRunView("))
        XCTAssertTrue(
            activeRunView.contains(
                "@ObservedObject private var livePresentation: "
                    + "NotebookCaptureLivePresentationStore"
            )
        )
        XCTAssertTrue(activeRunView.contains("NotebookRealtimeAutoscrollPolicy.signal("))
        XCTAssertTrue(activeRunView.contains("onLiveAutoscrollSignal()"))
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
        XCTAssertTrue(WindowCoordinator.shared.isPreventingSubtitleDisplaySleepForTesting)

        WindowCoordinator.shared.dismissSubtitleOverlay()

        XCTAssertFalse(WindowCoordinator.shared.isRegistered(.subtitleOverlay))
        XCTAssertFalse(panel.isVisible)
        XCTAssertFalse(WindowCoordinator.shared.isPreventingSubtitleDisplaySleepForTesting)
    }

    func testSubtitleDisplaySleepActivity_isScopedAndIdempotent() {
        var starts: [(ProcessInfo.ActivityOptions, String)] = []
        var endedTokens: [ObjectIdentifier] = []
        let firstToken = NSObject()
        let secondToken = NSObject()
        let tokens = [firstToken, secondToken]

        let activity = SubtitleDisplaySleepActivity(
            beginActivity: { options, reason in
                starts.append((options, reason))
                return tokens[starts.count - 1]
            },
            endActivity: { token in
                endedTokens.append(ObjectIdentifier(token as AnyObject))
            }
        )

        XCTAssertFalse(activity.isActive)
        activity.setActive(true)
        activity.setActive(true)

        XCTAssertTrue(activity.isActive)
        XCTAssertEqual(starts.count, 1)
        XCTAssertEqual(starts.first?.0, [.userInitiated, .idleDisplaySleepDisabled])
        XCTAssertEqual(starts.first?.1, SubtitleDisplaySleepActivity.reason)

        activity.setActive(false)
        activity.setActive(false)

        XCTAssertFalse(activity.isActive)
        XCTAssertEqual(endedTokens, [ObjectIdentifier(firstToken)])

        activity.setActive(true)

        XCTAssertTrue(activity.isActive)
        XCTAssertEqual(starts.count, 2)

        activity.setActive(false)

        XCTAssertEqual(
            endedTokens,
            [ObjectIdentifier(firstToken), ObjectIdentifier(secondToken)]
        )
    }

    func testSubtitleOverlayControllerClose_releasesDisplaySleepActivity() throws {
        let store = ActiveBilingualTranscriptStore()
        let panel = WindowCoordinator.shared.presentSubtitleOverlay(store: store)
        let controller = try XCTUnwrap(panel.windowController)

        XCTAssertTrue(WindowCoordinator.shared.isPreventingSubtitleDisplaySleepForTesting)

        controller.close()

        XCTAssertFalse(WindowCoordinator.shared.isRegistered(.subtitleOverlay))
        XCTAssertFalse(WindowCoordinator.shared.isPreventingSubtitleDisplaySleepForTesting)
    }

    func testSubtitleOverlayController_isMovableResizablePersistentAcrossApps() throws {
        let store = ActiveBilingualTranscriptStore()

        let controller = SubtitleOverlayController(store: store)
        defer { controller.close() }

        XCTAssertTrue(controller.storeForTesting === store)
        XCTAssertNil(controller.managedWindow.contentViewController)
        let contentView: NSView = try XCTUnwrap(controller.managedWindow.contentView)
        XCTAssertFalse(contentView.subviews.isEmpty)
        XCTAssertEqual(
            controller.managedWindow.level,
            SubtitleOverlayWindowPolicy.level(
                isPinned: SubtitleOverlayPresentationSettings.shared.isPinned
            )
        )
        XCTAssertTrue(controller.managedWindow.styleMask.contains(.resizable))
        XCTAssertTrue(controller.managedWindow.isMovable)
        XCTAssertTrue(controller.managedWindow.isMovableByWindowBackground)
        XCTAssertTrue((controller.managedWindow as? NSPanel)?.isExcludedFromWindowsMenu ?? false)
        XCTAssertFalse((controller.managedWindow as? NSPanel)?.hidesOnDeactivate ?? true)
    }

    func testSubtitleOverlayWindowPolicySwitchesBetweenPinnedAndRegularWindowBehavior() {
        XCTAssertEqual(SubtitleOverlayWindowPolicy.level(isPinned: true), .floating)
        XCTAssertEqual(
            SubtitleOverlayWindowPolicy.collectionBehavior(isPinned: true),
            [.canJoinAllSpaces, .fullScreenAuxiliary]
        )
        XCTAssertEqual(SubtitleOverlayWindowPolicy.level(isPinned: false), .normal)
        XCTAssertEqual(
            SubtitleOverlayWindowPolicy.collectionBehavior(isPinned: false),
            [.moveToActiveSpace, .fullScreenAuxiliary]
        )
        XCTAssertEqual(
            SubtitleOverlayWindowPolicy.maximizedCollectionBehavior,
            [.moveToActiveSpace, .fullScreenAuxiliary]
        )
    }

    func testSubtitleOverlayMaximizeFillsTargetDisplayAndRestoresWindow() throws {
        let store = ActiveBilingualTranscriptStore()
        let panel = WindowCoordinator.shared.presentSubtitleOverlay(store: store)
        let controller = try XCTUnwrap(panel.windowController as? SubtitleOverlayController)
        let normalFrame = panel.frame
        let targetFrame = try XCTUnwrap(panel.screen?.visibleFrame).integral

        XCTAssertTrue(
            WindowCoordinator.shared.setSubtitleOverlayMaximized(
                true,
                targetFrame: targetFrame
            )
        )

        XCTAssertTrue(controller.isMaximized)
        XCTAssertEqual(panel.frame, targetFrame.integral)
        XCTAssertFalse(panel.styleMask.contains(.resizable))
        XCTAssertFalse(panel.isMovable)
        XCTAssertFalse(panel.isMovableByWindowBackground)
        XCTAssertFalse(panel.hasShadow)
        XCTAssertEqual(
            panel.collectionBehavior,
            SubtitleOverlayWindowPolicy.maximizedCollectionBehavior
        )
        XCTAssertGreaterThan(panel.contentMaxSize.width, targetFrame.width)
        XCTAssertGreaterThan(panel.contentMaxSize.height, targetFrame.height)

        XCTAssertFalse(WindowCoordinator.shared.setSubtitleOverlayMaximized(false))

        XCTAssertFalse(controller.isMaximized)
        XCTAssertEqual(panel.frame, normalFrame)
        XCTAssertTrue(panel.styleMask.contains(.resizable))
        XCTAssertTrue(panel.isMovable)
        XCTAssertTrue(panel.isMovableByWindowBackground)
        XCTAssertTrue(panel.hasShadow)
        let normalMaximumContentSize = try XCTUnwrap(
            WindowSpecV2.required(.subtitleOverlay).chrome.maximumContentSize
        )
        XCTAssertEqual(
            panel.contentMaxSize,
            normalMaximumContentSize
        )
        XCTAssertEqual(
            panel.collectionBehavior,
            SubtitleOverlayWindowPolicy.collectionBehavior(
                isPinned: SubtitleOverlayPresentationSettings.shared.isPinned
            )
        )
    }

    func testSubtitleOverlayMaximizeAcceptsA4KDisplayFrameBeyondNormalWindowCap() {
        let store = ActiveBilingualTranscriptStore()
        let controller = SubtitleOverlayController(store: store)
        defer { controller.close() }
        let targetFrame = NSRect(x: 1920, y: 0, width: 3840, height: 2160)
        var appliedFrames: [NSRect] = []

        let isMaximized = controller.setMaximized(true, targetFrame: targetFrame) { frame in
            appliedFrames.append(frame)
            return true
        }

        XCTAssertTrue(isMaximized)
        XCTAssertEqual(appliedFrames, [targetFrame])
        XCTAssertGreaterThan(controller.managedWindow.contentMaxSize.width, targetFrame.width)
        XCTAssertGreaterThan(controller.managedWindow.contentMaxSize.height, targetFrame.height)
    }

    func testSubtitleOverlayMaximizeDoesNotPersistExpandedFrame() throws {
        let defaults = UserDefaults.standard
        let previousValue = defaults.object(forKey: SubtitleOverlayController.savedFrameKey)
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: SubtitleOverlayController.savedFrameKey)
            } else {
                defaults.removeObject(forKey: SubtitleOverlayController.savedFrameKey)
            }
        }

        let store = ActiveBilingualTranscriptStore()
        let panel = WindowCoordinator.shared.presentSubtitleOverlay(store: store)
        let controller = try XCTUnwrap(panel.windowController as? SubtitleOverlayController)
        let normalFrame = NSRect(x: 80, y: 120, width: 1100, height: 420)
        let targetFrame = try XCTUnwrap(panel.screen?.visibleFrame).integral

        XCTAssertTrue(
            WindowCoordinator.shared.applyFrame(
                normalFrame,
                to: .subtitleOverlay,
                animated: false,
                reason: "unit-test.normal-frame"
            )
        )
        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification))
        XCTAssertEqual(SubtitleOverlayController.loadSavedFrame(), normalFrame)

        XCTAssertTrue(
            WindowCoordinator.shared.setSubtitleOverlayMaximized(
                true,
                targetFrame: targetFrame
            )
        )
        controller.windowDidMove(Notification(name: NSWindow.didMoveNotification))
        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification))

        XCTAssertEqual(panel.frame, targetFrame)
        XCTAssertEqual(SubtitleOverlayController.loadSavedFrame(), normalFrame)

        WindowCoordinator.shared.dismissSubtitleOverlay()

        XCTAssertEqual(SubtitleOverlayController.loadSavedFrame(), normalFrame)
    }

    func testSubtitleOverlayMaximizeAffordanceIsAlwaysTopLeadingAndAccessible() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Zulangue", isDirectory: true)
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "WindowSystemV2/Surfaces/SubtitleOverlayController.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains(".overlay(alignment: .topLeading)"))
        XCTAssertTrue(source.contains("AccessibilityID.floatingSubtitleMaximize"))
        XCTAssertTrue(source.contains("coordinator.isMaximized"))
        XCTAssertTrue(source.contains("coordinator.restoreWindow()"))
        XCTAssertEqual(
            AccessibilityID.floatingSubtitleMaximize,
            "capture.floatingSubtitles.maximize"
        )
    }

    func testSubtitleOverlayMaximizeCopyIsLocalizedInEverySupportedAppLanguage() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Zulangue/Resources", isDirectory: true)

        for language in AppLanguage.allCases {
            let strings = try String(
                contentsOf: root
                    .appendingPathComponent("\(language.rawValue).lproj", isDirectory: true)
                    .appendingPathComponent("Localizable.strings"),
                encoding: .utf8
            )
            for key in ["subtitle.overlay.maximize", "subtitle.overlay.restore"] {
                XCTAssertTrue(
                    strings.contains("\"\(key)\" ="),
                    "\(language.rawValue) is missing \(key)"
                )
            }
        }
    }

    func testSubtitleOverlayBackdropIsTranslucentWithoutBackdropBlur() throws {
        let spec = WindowSpecV2.required(.subtitleOverlay)
        let panel = NSPanel(
            contentRect: spec.initialContentRect,
            styleMask: spec.styleMask,
            backing: .buffered,
            defer: false
        )

        ManagedWindowRuntimeV2.apply(spec: spec, to: panel)

        XCTAssertFalse(panel.isOpaque)
        XCTAssertEqual(panel.backgroundColor, .clear)
        XCTAssertTrue(panel.hasShadow)
        XCTAssertEqual(panel.alphaValue, 1)
        XCTAssertEqual(
            SubtitleOverlayBackdropPolicy.minimumOpacity,
            0.50,
            accuracy: 0.001
        )
        XCTAssertEqual(
            SubtitleOverlayBackdropPolicy.canvasOpacity(
                storedOpacity: SubtitleOverlayBackdropPolicy.defaultOpacity,
                reduceTransparency: false
            ),
            0.60,
            accuracy: 0.001
        )
        XCTAssertEqual(
            SubtitleOverlayBackdropPolicy.canvasOpacity(
                storedOpacity: 0,
                reduceTransparency: false
            ),
            SubtitleOverlayBackdropPolicy.minimumOpacity,
            accuracy: 0.001
        )
        XCTAssertEqual(
            SubtitleOverlayBackdropPolicy.canvasOpacity(
                storedOpacity: 1,
                reduceTransparency: false
            ),
            SubtitleOverlayBackdropPolicy.maximumOpacity,
            accuracy: 0.001
        )
        XCTAssertEqual(
            SubtitleOverlayBackdropPolicy.canvasOpacity(
                storedOpacity: SubtitleOverlayBackdropPolicy.minimumOpacity,
                reduceTransparency: true
            ),
            1
        )
        XCTAssertEqual(
            SubtitleOverlayBackdropPolicy.controlsOpacity(reduceTransparency: true),
            1
        )
        XCTAssertGreaterThan(
            SubtitleOverlayBackdropPolicy.controlBarOpacity,
            SubtitleOverlayBackdropPolicy.maximumOpacity
        )

        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "Zulangue/WindowSystemV2/Surfaces/SubtitleOverlayController.swift"
            )
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        XCTAssertFalse(source.contains(".regularMaterial"))
        XCTAssertFalse(source.contains("NSVisualEffectView"))
    }

    func testAudienceTimelineColumnsAnchorByTimeAndKeepIndependentSegmentation() {
        let source = { (sequence: UInt64, language: String, text: String, start: UInt64) in
            NotebookCaptureUtteranceDTO(
                id: "utt-\(sequence)",
                sessionId: "session",
                sequence: sequence,
                revision: 1,
                sourceLanguage: language,
                sourceText: text,
                sourceStartMs: start,
                sourceEndMs: start + 500,
                translatedLanguage: nil,
                translatedText: nil,
                completion: "complete",
                alignment: "source_only"
            )
        }
        let cue = { (sequence: UInt64, target: String, text: String, start: UInt64?) in
            NotebookCaptureTranslationCueDTO(
                targetLanguage: target,
                groupEpoch: 0,
                providerSequence: sequence,
                sourceLanguage: "zh",
                sourceStartMs: start,
                sourceEndMs: start.map { $0 + 500 },
                text: text,
                completion: "partial",
                withdrawn: false,
                revision: 1
            )
        }
        // One coarse English cue spans two Chinese source rows — the exact
        // shape the old row binding lost 17% of translations to.
        let columns = SubtitleAudienceTimeline.columns(
            languages: ["zh", "en"],
            utterances: [
                source(0, "zh", "第一句", 1_000),
                source(1, "zh", "第二句", 2_000),
            ],
            placement: { $0.sourceLanguage },
            cues: { language in
                language == "en"
                    ? [
                        cue(0, "en", "First and second sentence.", 1_000),
                        cue(1, "en", "Untimed tail", nil),
                    ]
                    : []
            }
        )
        XCTAssertEqual(columns["zh"]?.map(\.text), ["第一句", "第二句"])
        // The coarse cue is one card, not a lost binding; the untimed cue
        // sorts after every timed sibling.
        XCTAssertEqual(
            columns["en"]?.map(\.text),
            ["First and second sentence.", "Untimed tail"]
        )
        let retiredUntimedHead = SubtitleAudienceTimeline.columns(
            languages: ["en"],
            utterances: [],
            placement: { _ in nil },
            cues: { _ in
                [
                    cue(0, "en", "Old untimed partial", nil),
                    cue(1, "en", "New timed partial", 2_000),
                ]
            }
        )
        XCTAssertEqual(
            retiredUntimedHead["en"]?.map(\.text),
            ["New timed partial"],
            "a later timed cue must retire an older nil-timestamp track head"
        )
        let oldEpochUntimed = NotebookCaptureTranslationCueDTO(
            targetLanguage: "en",
            groupEpoch: 0,
            providerSequence: 99,
            sourceLanguage: "zh",
            sourceStartMs: nil,
            sourceEndMs: nil,
            text: "Old epoch untimed partial",
            completion: "partial",
            withdrawn: false,
            revision: 1
        )
        let newEpochTimed = NotebookCaptureTranslationCueDTO(
            targetLanguage: "en",
            groupEpoch: 1,
            providerSequence: 0,
            sourceLanguage: "zh",
            sourceStartMs: 3_000,
            sourceEndMs: 3_500,
            text: "New epoch timed partial",
            completion: "partial",
            withdrawn: false,
            revision: 1
        )
        let retiredOldEpochHead = SubtitleAudienceTimeline.columns(
            languages: ["en"],
            utterances: [],
            placement: { _ in nil },
            cues: { _ in [oldEpochUntimed, newEpochTimed] }
        )
        XCTAssertEqual(
            retiredOldEpochHead["en"]?.map(\.text),
            ["New epoch timed partial"]
        )
        // A source and its own-language cue never duplicate a column.
        let echoed = SubtitleAudienceTimeline.columns(
            languages: ["zh"],
            utterances: [source(0, "zh", "你好", 1_000)],
            placement: { $0.sourceLanguage },
            cues: { _ in
                [NotebookCaptureTranslationCueDTO(
                    targetLanguage: "zh",
                    groupEpoch: 0,
                    providerSequence: 0,
                    sourceLanguage: "zh",
                    sourceStartMs: 1_000,
                    sourceEndMs: 1_500,
                    text: "你好",
                    completion: "complete",
                    withdrawn: false,
                    revision: 1
                )]
            }
        )
        XCTAssertEqual(echoed["zh"]?.count, 1)

        // The column still catching up shows as waiting; the column whose
        // partial cue already covers the newest words does not.
        let waiting = SubtitleAudienceTimeline.waitingLanguages(columns: SubtitleAudienceTimeline.columns(
            languages: ["zh", "en", "th"],
            utterances: [source(0, "zh", "新话", 5_000)],
            placement: { $0.sourceLanguage },
            cues: { language in
                language == "en" ? [cue(0, "en", "New words", 5_000)] : []
            }
        ))
        XCTAssertEqual(waiting, ["th"])

        // Coverage decides "behind", not start: a coarse cue that STARTS
        // before the newest speech but covers through it is current, and
        // must not pin a perpetual ellipsis on its column.
        let coarseColumns = SubtitleAudienceTimeline.columns(
            languages: ["zh", "en"],
            utterances: [
                source(0, "zh", "第一句", 6_360),
                source(1, "zh", "第二句", 9_180),
            ],
            placement: { $0.sourceLanguage },
            cues: { language in
                language == "en"
                    ? [NotebookCaptureTranslationCueDTO(
                        targetLanguage: "en",
                        groupEpoch: 0,
                        providerSequence: 2,
                        sourceLanguage: "zh",
                        sourceStartMs: 6_300,
                        sourceEndMs: 18_780,
                        text: "One coarse segment covering both rows.",
                        completion: "complete",
                        withdrawn: false,
                        revision: 1
                    )]
                    : []
            }
        )
        XCTAssertEqual(
            SubtitleAudienceTimeline.waitingLanguages(columns: coarseColumns),
            [],
            "a segment covering the newest words is current even though it starts earlier"
        )

        // A dead lane is never "waiting": the ellipsis promises words are
        // coming, and for a failed stream that promise is false.
        let behindColumns = SubtitleAudienceTimeline.columns(
            languages: ["zh", "en", "th"],
            utterances: [source(0, "zh", "新话", 5_000)],
            placement: { $0.sourceLanguage },
            cues: { _ in [] }
        )
        XCTAssertEqual(
            SubtitleAudienceTimeline.waitingLanguages(columns: behindColumns),
            ["en", "th"]
        )
        XCTAssertEqual(
            SubtitleAudienceTimeline.waitingLanguages(
                columns: behindColumns,
                failedLanguages: ["th"]
            ),
            ["en"]
        )

        // An unplaced line stays on the strip while it is still inside the
        // visible tail; it must not vanish the instant the next placed
        // sentence lands. Outside the window it ages out like any line.
        let mixed = [source(0, "fr", "vieux", 1_000), source(1, "zh", "新", 2_000)]
        let zhOnly: (NotebookCaptureUtteranceDTO) -> String? = {
            $0.sourceLanguage == "zh" ? "zh" : nil
        }
        XCTAssertEqual(
            SubtitleAudienceTimeline.unroutedText(
                utterances: mixed,
                placement: zhOnly,
                window: 4
            ),
            "vieux",
            "an unplaced line within the window stays visible"
        )
        XCTAssertNil(
            SubtitleAudienceTimeline.unroutedText(
                utterances: mixed,
                placement: zhOnly,
                window: 1
            ),
            "outside the window it ages out"
        )
        XCTAssertEqual(
            SubtitleAudienceTimeline.unroutedText(
                utterances: [source(0, "zh", "旧", 1_000), source(1, "fr", "nouveau", 2_000)],
                placement: zhOnly,
                window: 1
            ),
            "nouveau"
        )
    }

    func testBoundedAudienceColumnsPreserveFullProjectionForLongSparseSession() {
        let languages = ["en", "zh", "th"]
        var utterances: [NotebookCaptureUtteranceDTO] = [
            NotebookCaptureUtteranceDTO(
                id: "long-coverage",
                sessionId: "session",
                sequence: 0,
                revision: 1,
                sourceLanguage: "en",
                sourceText: "Long coverage",
                sourceStartMs: 0,
                sourceEndMs: 20_000_000,
                translatedLanguage: nil,
                translatedText: nil,
                completion: "complete",
                alignment: "source_only"
            ),
            NotebookCaptureUtteranceDTO(
                id: "sparse-th",
                sessionId: "session",
                sequence: 1,
                revision: 1,
                sourceLanguage: "th",
                sourceText: "ภาษาไทยเก่า",
                sourceStartMs: 500,
                sourceEndMs: 900,
                translatedLanguage: nil,
                translatedText: nil,
                completion: "complete",
                alignment: "source_only"
            ),
        ]
        utterances.reserveCapacity(10_002)
        for index in 2..<10_002 {
            let sequence = UInt64(index)
            let language = index.isMultiple(of: 7) ? "zh" : "en"
            let sourceLanguage = index == 9_999
                ? "fr"
                : (index.isMultiple(of: 211) ? "und" : language)
            // The final 500 rows emulate a provider epoch restart. Sequence
            // order and timestamp order intentionally differ.
            let timestampIndex = index >= 9_502 ? index - 9_502 : index
            let startMs = UInt64(timestampIndex) * 1_000
            utterances.append(NotebookCaptureUtteranceDTO(
                id: "source-\(index)",
                sessionId: "session",
                sequence: sequence,
                revision: 1,
                sourceLanguage: sourceLanguage,
                provisionalSourceLanguage: sourceLanguage == "und" ? language : nil,
                sourceText: "row \(index)",
                sourceStartMs: index.isMultiple(of: 173) ? nil : startMs,
                sourceEndMs: index.isMultiple(of: 173) ? nil : startMs + 500,
                translatedLanguage: nil,
                translatedText: nil,
                completion: index == 10_001 ? "partial" : "complete",
                alignment: "source_only"
            ))
        }
        let cues = [
            NotebookCaptureTranslationCueDTO(
                targetLanguage: "zh",
                groupEpoch: 0,
                providerSequence: 1,
                sourceLanguage: "en",
                sourceStartMs: nil,
                sourceEndMs: nil,
                text: "旧的无时间译文",
                completion: "partial",
                withdrawn: false,
                revision: 1
            ),
            NotebookCaptureTranslationCueDTO(
                targetLanguage: "zh",
                groupEpoch: 1,
                providerSequence: 0,
                sourceLanguage: "en",
                sourceStartMs: 10,
                sourceEndMs: 20,
                text: "新时间段译文",
                completion: "partial",
                withdrawn: false,
                revision: 2
            ),
        ]
        let placement: (NotebookCaptureUtteranceDTO) -> String? = { utterance in
            NotebookCaptureHistoryPolicy.audienceSourcePlacement(
                for: utterance,
                selectedLanguages: languages,
                lastIdentifiedSourceLanguage: "en"
            )
        }
        let full = SubtitleAudienceTimeline.columns(
            languages: languages,
            utterances: utterances,
            placement: placement,
            cues: { $0 == "zh" ? cues : [] }
        )
        let candidates = NotebookCaptureLivePresentation.audienceDurableCandidates(
            durable: utterances,
            sessionId: "session",
            selectedLanguages: languages,
            lastIdentifiedSourceLanguage: "en",
            maximumRows: SubtitleOverlayLayoutPolicy.maximumAudienceRowCount
        )
        XCTAssertLessThanOrEqual(
            candidates.count,
            languages.count * (SubtitleOverlayLayoutPolicy.maximumAudienceRowCount + 1)
                + SubtitleOverlayLayoutPolicy.maximumAudienceRowCount,
            "a preview frame must consume a canvas-bounded durable candidate set"
        )

        for limit in 1...8 {
            let bounded = SubtitleAudienceTimeline.columns(
                languages: languages,
                utterances: candidates,
                placement: placement,
                cues: { $0 == "zh" ? cues : [] },
                visibleLimit: limit
            )
            for language in languages {
                XCTAssertEqual(
                    Array((bounded[language] ?? []).suffix(limit)),
                    Array((full[language] ?? []).suffix(limit)),
                    "bounded \(language) column must preserve the full projection at k=\(limit)"
                )
            }
            XCTAssertEqual(
                SubtitleAudienceTimeline.waitingLanguages(columns: bounded),
                SubtitleAudienceTimeline.waitingLanguages(columns: full),
                "coverage/waiting semantics must survive bounded retention at k=\(limit)"
            )
            XCTAssertEqual(
                SubtitleAudienceTimeline.unroutedText(
                    utterances: candidates,
                    placement: placement,
                    window: limit
                ),
                SubtitleAudienceTimeline.unroutedText(
                    utterances: utterances,
                    placement: placement,
                    window: limit
                ),
                "the global unrouted strip must remain exact at k=\(limit)"
            )
        }

        XCTAssertEqual(
            Array((full["th"] ?? []).suffix(1)).map(\.text),
            ["ภาษาไทยเก่า"],
            "a sparse language keeps its own visible suffix even after a long English run"
        )
    }

    func testConversationTimelineShowsUnboundTranslationCueAtLiveEdge() {
        let source = NotebookCaptureUtteranceDTO(
            id: "source-0",
            sessionId: "session",
            sequence: 0,
            revision: 1,
            sourceLanguage: "en",
            sourceText: "Are you ready?",
            sourceStartMs: 1_000,
            sourceEndMs: 1_800,
            translatedLanguage: nil,
            translatedText: nil,
            completion: "partial",
            alignment: "source_only"
        )
        let unboundChinese = NotebookCaptureTranslationCueDTO(
            targetLanguage: "zh",
            groupEpoch: 0,
            providerSequence: 7,
            sourceLanguage: "en",
            sourceStartMs: 1_000,
            sourceEndMs: 1_800,
            text: "你准备好了吗？",
            completion: "partial",
            withdrawn: false,
            revision: 1
        )

        let timeline = SubtitleConversationTimeline.projection(
            // The fourth request proves that the live slice keeps the same
            // maximum-three-language contract as the overlay.
            languages: ["en", "zh", "th", "fr"],
            utterances: [source],
            placement: { $0.sourceLanguage },
            cues: { language in language == "zh" ? [unboundChinese] : [] }
        )

        XCTAssertTrue(timeline.historicalUtterances.isEmpty)
        XCTAssertEqual(timeline.liveLanes.map(\.language), ["en", "zh", "th"])
        XCTAssertEqual(timeline.liveLanes[0].text, "Are you ready?")
        XCTAssertEqual(
            timeline.liveLanes[1].text,
            "你准备好了吗？",
            "an independent cue must not wait for a canonical language variant"
        )
        XCTAssertNil(source.translatedText, "the fixture deliberately has no row binding")
    }

    func testConversationTimelineMissingLanguageDoesNotBlockReadySiblings() {
        let source = NotebookCaptureUtteranceDTO(
            id: "source-1",
            sessionId: "session",
            sequence: 1,
            revision: 1,
            sourceLanguage: "en",
            sourceText: "We can begin now.",
            sourceStartMs: 5_000,
            sourceEndMs: 5_900,
            translatedLanguage: nil,
            translatedText: nil,
            completion: "partial",
            alignment: "source_only"
        )
        let readyChinese = NotebookCaptureTranslationCueDTO(
            targetLanguage: "zh",
            groupEpoch: 0,
            providerSequence: 11,
            sourceLanguage: "en",
            sourceStartMs: 5_000,
            sourceEndMs: 5_900,
            text: "我们现在可以开始了。",
            completion: "partial",
            withdrawn: false,
            revision: 1
        )

        let timeline = SubtitleConversationTimeline.projection(
            languages: ["en", "zh", "th"],
            utterances: [source],
            placement: { $0.sourceLanguage },
            cues: { language in language == "zh" ? [readyChinese] : [] }
        )
        let lanes = Dictionary(uniqueKeysWithValues: timeline.liveLanes.map {
            ($0.language, $0)
        })

        XCTAssertEqual(lanes["en"]?.text, "We can begin now.")
        XCTAssertEqual(lanes["zh"]?.text, "我们现在可以开始了。")
        XCTAssertNil(lanes["th"]?.text)
        XCTAssertEqual(lanes["th"]?.missingLaneState, .waiting)
        XCTAssertTrue(
            timeline.hasLiveWords,
            "a missing Thai stream must not gate the English or Chinese track heads"
        )
    }

    func testConversationTimelineShowsBehindPartialThatStillOverlapsLiveSource() {
        let source = NotebookCaptureUtteranceDTO(
            id: "source-long",
            sessionId: "session",
            sequence: 0,
            revision: 1,
            sourceLanguage: "en",
            sourceText: "A long live source segment.",
            sourceStartMs: 0,
            sourceEndMs: 5_000,
            translatedLanguage: nil,
            translatedText: nil,
            completion: "partial",
            alignment: "source_only"
        )
        let partial = NotebookCaptureTranslationCueDTO(
            targetLanguage: "zh",
            groupEpoch: 0,
            providerSequence: 1,
            sourceLanguage: "en",
            sourceStartMs: 0,
            sourceEndMs: 4_500,
            text: "仍在继续的部分译文",
            completion: "partial",
            withdrawn: false,
            revision: 1
        )

        let timeline = SubtitleConversationTimeline.projection(
            languages: ["en", "zh"],
            utterances: [source],
            placement: { $0.sourceLanguage },
            cues: { $0 == "zh" ? [partial] : [] }
        )

        XCTAssertEqual(timeline.liveLanes[1].text, partial.text)
        XCTAssertEqual(
            timeline.liveLanes[1].missingLaneState,
            .waiting,
            "behind is lane status only and must not gate text already delivered"
        )
    }

    func testConversationTimelineShowsLatestCueWithoutProviderTimestamps() {
        let source = NotebookCaptureUtteranceDTO(
            id: "source-unanchored",
            sessionId: "session",
            sequence: 0,
            revision: 1,
            sourceLanguage: "en",
            sourceText: "Show the newest provider head.",
            sourceStartMs: 6_000,
            sourceEndMs: 7_000,
            translatedLanguage: nil,
            translatedText: nil,
            completion: "partial",
            alignment: "source_only"
        )
        let olderTimed = NotebookCaptureTranslationCueDTO(
            targetLanguage: "zh",
            groupEpoch: 0,
            providerSequence: 4,
            sourceLanguage: "en",
            sourceStartMs: 5_000,
            sourceEndMs: 5_500,
            text: "旧的有时间译文",
            completion: "complete",
            withdrawn: false,
            revision: 1
        )
        let latestUntimed = NotebookCaptureTranslationCueDTO(
            targetLanguage: "zh",
            groupEpoch: 0,
            providerSequence: 5,
            sourceLanguage: "en",
            sourceStartMs: nil,
            sourceEndMs: nil,
            text: "最新的无时间译文",
            completion: "partial",
            withdrawn: false,
            revision: 1
        )

        let timeline = SubtitleConversationTimeline.projection(
            languages: ["en", "zh"],
            utterances: [source],
            placement: { $0.sourceLanguage },
            cues: { $0 == "zh" ? [olderTimed, latestUntimed] : [] }
        )

        XCTAssertEqual(
            timeline.liveLanes[1].text,
            latestUntimed.text,
            "a newest unanchored provider head must be visible immediately"
        )
    }

    func testConversationTimelineDoesNotRepeatAStaleTranslationAsCurrent() {
        let oldSource = NotebookCaptureUtteranceDTO(
            id: "source-old",
            sessionId: "session",
            sequence: 0,
            revision: 1,
            sourceLanguage: "en",
            sourceText: "The previous sentence.",
            sourceStartMs: 3_500,
            sourceEndMs: 3_900,
            translatedLanguage: "zh",
            translatedText: "上一句话。",
            completion: "complete",
            alignment: "paired"
        )
        let liveSource = NotebookCaptureUtteranceDTO(
            id: "source-live",
            sessionId: "session",
            sequence: 1,
            revision: 1,
            sourceLanguage: "en",
            sourceText: "The new sentence is still being translated.",
            sourceStartMs: 4_000,
            sourceEndMs: 4_900,
            translatedLanguage: nil,
            translatedText: nil,
            completion: "partial",
            alignment: "source_only"
        )
        let oldChinese = NotebookCaptureTranslationCueDTO(
            targetLanguage: "zh",
            groupEpoch: 0,
            providerSequence: 0,
            sourceLanguage: "en",
            sourceStartMs: 3_500,
            sourceEndMs: 3_900,
            text: "上一句话。",
            completion: "complete",
            withdrawn: false,
            revision: 1
        )

        let timeline = SubtitleConversationTimeline.projection(
            languages: ["en", "zh"],
            utterances: [oldSource, liveSource],
            placement: { $0.sourceLanguage },
            cues: { language in language == "zh" ? [oldChinese] : [] }
        )

        XCTAssertEqual(timeline.historicalUtterances.map(\.id), ["source-old"])
        XCTAssertEqual(timeline.liveLanes[0].text, liveSource.sourceText)
        XCTAssertNil(
            timeline.liveLanes[1].text,
            "an older Chinese cue already rendered in history must not masquerade as current"
        )
        XCTAssertEqual(timeline.liveLanes[1].missingLaneState, .waiting)

        let failedTimeline = SubtitleConversationTimeline.projection(
            languages: ["en", "zh"],
            utterances: [oldSource, liveSource],
            placement: { $0.sourceLanguage },
            cues: { language in language == "zh" ? [oldChinese] : [] },
            failedLanguages: ["zh"]
        )
        XCTAssertNil(failedTimeline.liveLanes[1].text)
        XCTAssertEqual(failedTimeline.liveLanes[1].missingLaneState, .failed)
    }

    func testConversationTimelineDoesNotPromoteAnOlderDifferentLanguageSourceToLiveEdge() {
        let oldChinese = NotebookCaptureUtteranceDTO(
            id: "source-old-zh",
            sessionId: "session",
            sequence: 0,
            revision: 1,
            sourceLanguage: "zh",
            sourceText: "旧中文",
            sourceStartMs: 0,
            sourceEndMs: 1_000,
            translatedLanguage: nil,
            translatedText: nil,
            completion: "complete",
            alignment: "source_only"
        )
        let liveEnglish = NotebookCaptureUtteranceDTO(
            id: "source-live-en",
            sessionId: "session",
            sequence: 1,
            revision: 1,
            sourceLanguage: "en",
            sourceText: "new English",
            sourceStartMs: 2_000,
            sourceEndMs: 2_500,
            translatedLanguage: nil,
            translatedText: nil,
            completion: "partial",
            alignment: "source_only"
        )

        let timeline = SubtitleConversationTimeline.projection(
            languages: ["en", "zh"],
            utterances: [oldChinese, liveEnglish],
            placement: { $0.sourceLanguage },
            cues: { _ in [] }
        )

        XCTAssertEqual(timeline.historicalUtterances.map(\.id), [oldChinese.id])
        XCTAssertEqual(timeline.liveLanes[0].text, liveEnglish.sourceText)
        XCTAssertNil(
            timeline.liveLanes[1].text,
            "an older Chinese source belongs to history, not the current Chinese lane"
        )
        XCTAssertEqual(timeline.liveLanes[1].missingLaneState, .waiting)
    }

    func testConversationTimelineClearsAnUntimedCueWhenItsLaneFails() {
        let liveSource = NotebookCaptureUtteranceDTO(
            id: "source-live-before-failure",
            sessionId: "session",
            sequence: 1,
            revision: 1,
            sourceLanguage: "en",
            sourceText: "The target lane has stopped.",
            sourceStartMs: 2_000,
            sourceEndMs: 2_500,
            translatedLanguage: nil,
            translatedText: nil,
            completion: "partial",
            alignment: "source_only"
        )
        let staleUntimed = NotebookCaptureTranslationCueDTO(
            targetLanguage: "zh",
            groupEpoch: 0,
            providerSequence: 0,
            sourceLanguage: "en",
            sourceStartMs: nil,
            sourceEndMs: nil,
            text: "无法证明仍是当前句的旧译文",
            completion: "partial",
            withdrawn: false,
            revision: 1
        )

        let timeline = SubtitleConversationTimeline.projection(
            languages: ["en", "zh"],
            utterances: [liveSource],
            placement: { $0.sourceLanguage },
            cues: { $0 == "zh" ? [staleUntimed] : [] },
            failedLanguages: ["zh"]
        )

        XCTAssertNil(timeline.liveLanes[1].text)
        XCTAssertEqual(timeline.liveLanes[1].missingLaneState, .failed)
    }

    func testConversationProjectionUsesBoundedTailForThousandRowSession() {
        var durable: [NotebookCaptureUtteranceDTO] = []
        durable.reserveCapacity(1_000)
        for index in 0..<1_000 {
            let sequence = UInt64(index)
            let startMs = sequence * 1_000
            durable.append(NotebookCaptureUtteranceDTO(
                id: "source-\(index)",
                sessionId: "session",
                sequence: sequence,
                revision: 1,
                sourceLanguage: "en",
                sourceText: "row \(index)",
                sourceStartMs: startMs,
                sourceEndMs: startMs + 500,
                translatedLanguage: nil,
                translatedText: nil,
                completion: "complete",
                alignment: "source_only"
            ))
        }
        let preview = NotebookCaptureUtteranceDTO(
            id: "source-1000",
            sessionId: "session",
            sequence: 1_000,
            revision: 1,
            sourceLanguage: "en",
            sourceText: "live row",
            sourceStartMs: 1_000_000,
            sourceEndMs: 1_000_500,
            translatedLanguage: nil,
            translatedText: nil,
            completion: "partial",
            alignment: "source_only"
        )
        let rowBudget = 12
        let limit = rowBudget + SubtitleConversationTimeline.utteranceLookbackAllowance
        let tail = NotebookCaptureLivePresentation.utteranceTail(
            durable: durable,
            preview: [preview],
            sessionId: "session",
            limit: limit
        )

        XCTAssertEqual(tail.count, limit)
        XCTAssertEqual(tail.first?.sequence, 987)
        XCTAssertEqual(tail.last?.sequence, 1_000)

        var placementCalls = 0
        let timeline = SubtitleConversationTimeline.projection(
            languages: ["en", "zh", "th"],
            utterances: tail,
            placement: {
                placementCalls += 1
                return $0.sourceLanguage
            },
            cues: { _ in [] }
        )

        XCTAssertEqual(timeline.historicalUtterances.count, limit - 1)
        XCTAssertLessThanOrEqual(
            placementCalls,
            limit + 1,
            "Conversation must project only the canvas-sized tail, not all 1000 rows"
        )
    }

    func testSubtitleOverlayDisplayModeDefaultsToAudienceAndOrdersItFirst() {
        XCTAssertEqual(SubtitleOverlayDisplayMode.allCases, [.audience, .conversation])
        XCTAssertEqual(SubtitleOverlayDisplayMode.resolved(storedRawValue: nil), .audience)
        XCTAssertEqual(SubtitleOverlayDisplayMode.resolved(storedRawValue: "invalid"), .audience)
        XCTAssertEqual(
            SubtitleOverlayDisplayMode.resolved(storedRawValue: "conversation"),
            .conversation,
            "an explicit prior choice remains durable"
        )
    }

    func testAudienceSourceRefreshCoalescesPartialsAndFlushesFinalImmediately() {
        var state = SubtitleAudienceSourceRefresh.State(text: "中")
        state.receive(.init(text: "中文", isComplete: false))
        state.receive(.init(text: "中文高速", isComplete: false))

        XCTAssertEqual(state.displayedText, "中")
        XCTAssertEqual(state.pendingText, "中文高速")
        XCTAssertEqual(SubtitleAudienceSourceRefresh.interval, .milliseconds(250))

        state.flush()
        XCTAssertEqual(state.displayedText, "中文高速")

        state.receive(.init(text: "中文高速。", isComplete: true))
        XCTAssertEqual(
            state.displayedText,
            "中文高速。",
            "the final correction must not wait for the visual refresh budget"
        )
    }

    func testAudienceBandSlicesKeepEveryLanguageOnTheCanvas() {
        // Wide canvas, one band: the slice is effectively the whole canvas.
        let single = SubtitleOverlayLayoutPolicy.audienceBandHeight(
            canvasHeight: 400,
            bandCount: 1,
            reservesUnroutedStrip: false,
            fontSize: 30
        )
        XCTAssertEqual(single, 400 - 24)

        // Narrow canvas, three stacked languages: equal slices, so the last
        // band can never evict the first two — five minutes of speech clips
        // its own history instead.
        let banded = SubtitleOverlayLayoutPolicy.audienceBandHeight(
            canvasHeight: 400,
            bandCount: 3,
            reservesUnroutedStrip: false,
            fontSize: 30
        )
        XCTAssertEqual(banded, (400 - 24 - 16) / 3, accuracy: 0.01)
        XCTAssertGreaterThan(banded, 100)

        // The unrouted strip reserves its estimated height from the bands.
        let withStrip = SubtitleOverlayLayoutPolicy.audienceBandHeight(
            canvasHeight: 400,
            bandCount: 3,
            reservesUnroutedStrip: true,
            fontSize: 30
        )
        XCTAssertLessThan(withStrip, banded)

        // A canvas too small for the arithmetic floors at one short card
        // per band rather than collapsing to zero-height bands.
        let floored = SubtitleOverlayLayoutPolicy.audienceBandHeight(
            canvasHeight: 120,
            bandCount: 3,
            reservesUnroutedStrip: false,
            fontSize: 40
        )
        XCTAssertEqual(floored, 40 * 2.6, accuracy: 0.01)
    }

    func testPacedRevealFlowsMouthfulsAndAbsorbsTailRewrites() {
        // Reading rates are calibrated against the measured provider batch
        // shape: ~15 tokens per mouthful, ~1.4 s until the next one. One
        // mouthful must finish revealing inside that gap for either script.
        for (text, budgetSeconds) in [
            (String(repeating: "词", count: 25), 1.4),
            (String(repeating: "word ", count: 15), 1.4),
        ] {
            var state = SubtitlePacedReveal.State()
            var elapsed = 0.0
            while Int(state.revealedChars) < text.count, elapsed < 10 {
                state = SubtitlePacedReveal.advance(
                    state: state,
                    elapsedSeconds: 0.033,
                    text: text
                )
                elapsed += 0.033
            }
            XCTAssertLessThanOrEqual(
                elapsed,
                budgetSeconds,
                "one mouthful of \(text.prefix(4))… must drain within a batch gap"
            )
        }

        // An append keeps the cursor: nothing the reader saw is replayed.
        var state = SubtitlePacedReveal.State(revealedChars: 5)
        state = SubtitlePacedReveal.reconcile(
            state: state,
            oldText: "hello",
            newText: "hello world"
        )
        XCTAssertEqual(state.revealedChars, 5)

        // A rewrite beyond the cursor is invisible and free.
        state = SubtitlePacedReveal.State(revealedChars: 3)
        state = SubtitlePacedReveal.reconcile(
            state: state,
            oldText: "helXYZ",
            newText: "hello!"
        )
        XCTAssertEqual(state.revealedChars, 3)

        // A rewrite under the cursor snaps back to the surviving prefix so
        // the correction shows immediately.
        state = SubtitlePacedReveal.State(revealedChars: 9)
        state = SubtitlePacedReveal.reconcile(
            state: state,
            oldText: "hello red",
            newText: "hello blue"
        )
        XCTAssertEqual(state.revealedChars, 6)

        // A reconnect flood snaps forward: backlog never exceeds the cap
        // after one tick.
        let flood = String(repeating: "字", count: 500)
        var flooded = SubtitlePacedReveal.State()
        flooded = SubtitlePacedReveal.advance(
            state: flooded,
            elapsedSeconds: 0.033,
            text: flood
        )
        XCTAssertGreaterThanOrEqual(
            flooded.revealedChars,
            Double(flood.count - SubtitlePacedReveal.snapBacklogLimit(script: .dense))
        )

        XCTAssertEqual(SubtitlePacedReveal.script(for: "สวัสดีครับ"), .dense)
        XCTAssertEqual(SubtitlePacedReveal.script(for: "你好，世界"), .dense)
        XCTAssertEqual(SubtitlePacedReveal.script(for: "Hello, world"), .spaced)
        // Mixed line with a majority of spaced words stays spaced.
        XCTAssertEqual(
            SubtitlePacedReveal.script(for: "Der Begriff 道 im Kontext"),
            .spaced
        )
    }

    func testSubtitleOverlayLayoutPolicyAdaptsConversationAndAudienceLayouts() {
        XCTAssertEqual(
            SubtitleOverlayLayoutPolicy.conversationLayout(
                width: 1_100,
                languageCount: 2,
                fontSize: 30
            ),
            .columns
        )
        XCTAssertEqual(
            SubtitleOverlayLayoutPolicy.conversationLayout(
                width: 560,
                languageCount: 4,
                fontSize: 30
            ),
            .stacked
        )
        XCTAssertEqual(
            SubtitleOverlayLayoutPolicy.audienceColumnCount(
                width: 1_100,
                languageCount: 4,
                fontSize: 30
            ),
            3
        )
        XCTAssertEqual(
            SubtitleOverlayLayoutPolicy.audienceColumnCount(
                width: 1_600,
                languageCount: 4,
                fontSize: 30
            ),
            3
        )
        XCTAssertEqual(
            SubtitleOverlayLayoutPolicy.audienceColumnCount(
                width: 560,
                languageCount: 3,
                fontSize: 30
            ),
            1
        )
        XCTAssertEqual(SubtitleOverlayLayoutPolicy.maximumLanguageCount, 3)
    }

    func testSubtitleOverlayFontPolicy_clampsAndStepsWithinReadableRange() {
        XCTAssertEqual(SubtitleOverlayFontPolicy.clamped(2), 16)
        // Projector-canvas sizes are legitimate values, not clamp targets.
        XCTAssertEqual(SubtitleOverlayFontPolicy.clamped(100), 100)
        XCTAssertEqual(SubtitleOverlayFontPolicy.clamped(500), 160)
        XCTAssertEqual(SubtitleOverlayFontPolicy.smaller(than: 30), 28)
        XCTAssertEqual(SubtitleOverlayFontPolicy.larger(than: 30), 32)
        XCTAssertEqual(SubtitleOverlayFontPolicy.smaller(than: 16), 16)
        XCTAssertEqual(SubtitleOverlayFontPolicy.larger(than: 160), 160)
    }

    func testSubtitleOverlayLayoutPolicy_audienceRowCountFollowsCanvasHeight() {
        // A squat strip at projector font sizes carries a single live line.
        XCTAssertEqual(
            SubtitleOverlayLayoutPolicy.audienceRowCount(height: 200, fontSize: 96),
            1
        )
        // A tall canvas retains more finished rows so a translation that
        // lands one utterance late is still on screen to be read.
        XCTAssertEqual(
            SubtitleOverlayLayoutPolicy.audienceRowCount(height: 320, fontSize: 30),
            3
        )
        // Bounded above: the overlay never becomes a scrollback log.
        XCTAssertEqual(
            SubtitleOverlayLayoutPolicy.audienceRowCount(height: 3_000, fontSize: 24),
            8
        )
    }

    func testSubtitleOverlayFontPolicy_automaticSizesToCanvasNotContent() {
        // A projector canvas gets projector type: the height term targets
        // roughly four visible rows, the width term keeps three conversation
        // columns viable side by side, and the result quantizes down to the
        // slider step.
        let projector = SubtitleOverlayFontPolicy.automatic(
            canvasSize: CGSize(width: 1_920, height: 1_055),
            languageCount: 3,
            mode: .conversation
        )
        XCTAssertEqual(projector, 78)
        XCTAssertLessThanOrEqual(
            SubtitleOverlayLayoutPolicy.minimumColumnWidth(fontSize: projector) * 3,
            1_920
        )

        // Audience tiles are wider per column, so the same canvas chooses a
        // size that still fits three tiles side by side.
        let audience = SubtitleOverlayFontPolicy.automatic(
            canvasSize: CGSize(width: 1_920, height: 1_055),
            languageCount: 3,
            mode: .audience
        )
        XCTAssertEqual(audience, 62)
        XCTAssertEqual(
            SubtitleOverlayLayoutPolicy.audienceColumnCount(
                width: 1_920 - 24,
                languageCount: 3,
                fontSize: audience
            ),
            3
        )

        // The desk strip keeps desk type instead of scaling down past
        // readability.
        XCTAssertEqual(
            SubtitleOverlayFontPolicy.automatic(
                canvasSize: CGSize(width: 560, height: 180),
                languageCount: 2,
                mode: .conversation
            ),
            SubtitleOverlayFontPolicy.minimum
        )

        // Bounds still clamp, and a canvas that has not laid out yet falls
        // back to the manual default rather than to the floor.
        XCTAssertEqual(
            SubtitleOverlayFontPolicy.automatic(
                canvasSize: CGSize(width: 4_000, height: 4_000),
                languageCount: 1,
                mode: .conversation
            ),
            SubtitleOverlayFontPolicy.maximum
        )
        XCTAssertEqual(
            SubtitleOverlayFontPolicy.automatic(
                canvasSize: .zero,
                languageCount: 3,
                mode: .conversation
            ),
            SubtitleOverlayFontPolicy.defaultValue
        )
    }

    func testSubtitleOverlayFontPolicy_storedModeMigrationKeepsChosenSizesManual() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)

        // Fresh install: nothing stored, automatic stays the default.
        SubtitleOverlayFontPolicy.migrateStoredModeIfNeeded(defaults: defaults)
        XCTAssertNil(defaults.string(forKey: SubtitleOverlayFontPolicy.modeDefaultsKey))

        // An operator who sized their venue before automatic existed keeps
        // that size ruling.
        defaults.set(96.0, forKey: SubtitleOverlayFontPolicy.defaultsKey)
        SubtitleOverlayFontPolicy.migrateStoredModeIfNeeded(defaults: defaults)
        XCTAssertEqual(
            defaults.string(forKey: SubtitleOverlayFontPolicy.modeDefaultsKey),
            SubtitleOverlayFontMode.manual.rawValue
        )

        // The migration never overrides a mode the operator has since chosen.
        defaults.set(
            SubtitleOverlayFontMode.automatic.rawValue,
            forKey: SubtitleOverlayFontPolicy.modeDefaultsKey
        )
        SubtitleOverlayFontPolicy.migrateStoredModeIfNeeded(defaults: defaults)
        XCTAssertEqual(
            defaults.string(forKey: SubtitleOverlayFontPolicy.modeDefaultsKey),
            SubtitleOverlayFontMode.automatic.rawValue
        )
        defaults.removePersistentDomain(forName: #function)
    }

    func testSubtitleOverlayLayoutPolicy_conversationRowCountFollowsCanvasHeight() {
        // The old fixed four is the floor, so the desk strip keeps its
        // scrollback.
        XCTAssertEqual(
            SubtitleOverlayLayoutPolicy.conversationRowCount(
                height: 180,
                fontSize: 30,
                lanesPerRow: 1
            ),
            4
        )
        // A projector canvas at desk font fills with history instead of
        // pinning four rows above a third of blank canvas.
        XCTAssertEqual(
            SubtitleOverlayLayoutPolicy.conversationRowCount(
                height: 1_055,
                fontSize: 30,
                lanesPerRow: 1
            ),
            9
        )
        // Stacked rows carry every language, so the same canvas affords
        // fewer of them.
        XCTAssertEqual(
            SubtitleOverlayLayoutPolicy.conversationRowCount(
                height: 2_000,
                fontSize: 30,
                lanesPerRow: 3
            ),
            6
        )
        // Bounded above: a wall, not a scrollback log.
        XCTAssertEqual(
            SubtitleOverlayLayoutPolicy.conversationRowCount(
                height: 10_000,
                fontSize: 16,
                lanesPerRow: 1
            ),
            12
        )
    }

    func testWindowCoordinator_registrySnapshot_listsAllKnownWindowSurfaces() {
        WindowCoordinator.shared.installBaselineCatalog()

        let snapshot = WindowCoordinator.shared.registrySnapshot()

        XCTAssertEqual(snapshot.count, WindowSurfaceID.allCases.count)
        XCTAssertTrue(snapshot.contains { $0.contains("surface=main") })
        XCTAssertTrue(snapshot.contains { $0.contains("surface=subtitleOverlay") })
    }

}
