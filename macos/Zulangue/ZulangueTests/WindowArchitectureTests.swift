import XCTest
import Foundation
@testable import Zulangue

@MainActor
final class WindowArchitectureTests: XCTestCase {

    override func setUp() {
        super.setUp()
        WindowCommandRouter.shared.resetForTesting()
    }

    // MARK: - WindowLayoutEngine (subtitle overlay + main)

    func testWindowLayoutEngine_subtitleOverlayPrefersValidSavedFrame() {
        let visible = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let saved = NSRect(x: 120, y: 180, width: 960, height: 220)
        let input = WindowLayoutInput(
            screenFrame: visible,
            visibleFrame: visible,
            savedFrame: saved
        )

        let layout = WindowLayoutEngine.layout(for: .subtitleOverlay, input: input)

        XCTAssertEqual(layout?.frame, saved.integral)
    }

    func testWindowLayoutEngine_subtitleOverlayFallsBackToTopCenteredDefaultFrame() {
        let visible = NSRect(x: 0, y: 0, width: 1200, height: 900)
        let invalidSaved = NSRect(x: -2000, y: -2000, width: 100, height: 40)
        let input = WindowLayoutInput(
            screenFrame: visible,
            visibleFrame: visible,
            savedFrame: invalidSaved
        )

        let layout = WindowLayoutEngine.layout(for: .subtitleOverlay, input: input)

        XCTAssertEqual(layout?.frame.width, 1100)
        XCTAssertEqual(layout?.frame.height, 280)
        XCTAssertEqual(layout?.frame.origin.x, 50)
        XCTAssertEqual(layout?.frame.origin.y, 584)
    }

    func testWindowLayoutEngine_subtitleOverlayClampsOversizedSavedFrameIntoVisibleBounds() {
        let visible = NSRect(x: 0, y: 24, width: 1512, height: 956)
        let oversizedSaved = NSRect(x: 86, y: -820, width: 1556, height: 1844)
        let input = WindowLayoutInput(
            screenFrame: visible,
            visibleFrame: visible,
            savedFrame: oversizedSaved
        )

        let layout = WindowLayoutEngine.layout(for: .subtitleOverlay, input: input)
        let frame = layout?.frame ?? .zero

        XCTAssertTrue(visible.contains(frame))
    }

    func testWindowLayoutEngineV2_subtitleOverlayClampsOversizedSavedFrameIntoVisibleBounds() {
        let profile = DisplayProfileResolverV2.resolveProfile(
            screenFrame: NSRect(x: 0, y: 24, width: 1512, height: 956),
            visibleFrame: NSRect(x: 0, y: 24, width: 1512, height: 956),
            safeAreaTopInset: 0,
            topLeftAuxiliaryWidth: nil,
            topRightAuxiliaryWidth: nil,
            localizedName: "Built-in"
        )
        let oversizedSaved = NSRect(x: 86, y: -820, width: 1556, height: 1844)
        let request = WindowLayoutRequestV2(
            surfaceID: .subtitleOverlay,
            display: profile,
            systemState: .default,
            savedFrame: oversizedSaved
        )

        let snapshot = WindowLayoutEngineV2.snapshot(for: request)
        let frame = snapshot?.outerFrame ?? .zero

        XCTAssertTrue(profile.visibleFrame.contains(frame))
    }

    // MARK: - MainWindow metrics

    func testMainWindowMetrics_launchFrameCentersGranolaSizedWindow() {
        let visible = NSRect(x: 0, y: 24, width: 1728, height: 1060)

        let frame = MainWindowMetrics.launchFrame(in: visible)

        XCTAssertEqual(frame.width, MainWindowMetrics.defaultWidth)
        XCTAssertEqual(frame.height, MainWindowMetrics.defaultHeight)
        XCTAssertEqual(frame.origin.x, 204)
        XCTAssertEqual(frame.origin.y, 154)
    }

    func testWindowLayoutEngine_mainWindowUsesLaunchFrameHelper() {
        let visible = NSRect(x: 0, y: 24, width: 1728, height: 1060)
        let input = WindowLayoutInput(
            screenFrame: visible,
            visibleFrame: visible
        )

        let layout = WindowLayoutEngine.layout(for: .main, input: input)

        XCTAssertEqual(layout?.frame, MainWindowMetrics.launchFrame(in: visible))
    }

    func testMainWindowMetrics_rejectsCorruptedAutosavedFrameDescriptor() {
        let frame = MainWindowMetrics.parsedAutosavedFrame(
            from: "304 921 1 1 0 0 1728 1084"
        )

        XCTAssertEqual(frame?.width, 1)
        XCTAssertEqual(frame?.height, 1)
        XCTAssertFalse(
            MainWindowMetrics.isUsableAutosavedFrame(
                try! XCTUnwrap(frame),
                visibleFrame: NSRect(x: 0, y: 24, width: 1728, height: 1060)
            )
        )
    }

    func testMainWindowMetrics_sanitizeLegacyAutosavedFrameRemovesPersistedValue() {
        let suiteName = "ZulangueTests.MainWindowMetrics.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("304 921 1 1 0 0 1728 1084", forKey: MainWindowMetrics.autosaveFrameKey)

        let removed = MainWindowMetrics.sanitizeLegacyAutosavedFrame(
            defaults: defaults
        )

        XCTAssertTrue(removed)
        XCTAssertNil(defaults.string(forKey: MainWindowMetrics.autosaveFrameKey))
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testMainWindowMetrics_restoredFrameRejectsInvalidPersistedValue() {
        let suiteName = "ZulangueTests.MainWindowMetrics.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(NSStringFromRect(NSRect(x: 10, y: 10, width: 428, height: 1084)), forKey: MainWindowMetrics.persistedFrameKey)

        let restored = MainWindowMetrics.restoredFrame(
            in: NSRect(x: 0, y: 24, width: 1728, height: 1060),
            defaults: defaults
        )

        XCTAssertNil(restored)
        XCTAssertNil(defaults.string(forKey: MainWindowMetrics.persistedFrameKey))
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: - Routing (Notebook-owned sessions)

    func testWindowCommandRouter_requestOpenSessionWithReveal_reopensMainWindowBeforeRouting() {
        let exp = expectation(description: "session route should run after main window reveal")
        var events: [String] = []

        WindowCommandRouter.shared.installTestOverrides(
            WindowCommandRouterTestOverrides(
                openMainWindow: { detail, followUp in
                    events.append("open:\(detail)")
                    followUp?()
                },
                openSession: { sessionId in
                    events.append("session:\(sessionId)")
                    exp.fulfill()
                }
            )
        )

        WindowCommandRouter.shared.requestOpenSession("session-42", revealMainWindow: true)

        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(events, ["open:open-session:session-42", "session:session-42"])
    }

    // MARK: - Architecture invariants

    /// Anything that constructs/presents a window outside WindowSystem /
    /// MenuBar is a regression. WindowSystem owns the main window and the
    /// subtitle overlay; MenuBar owns its own
    /// affordances (NSStatusItem button, NSPopover, RecordingHudPanel) since
    /// they're conceptually the menu-bar app's entry surfaces, not stage-level
    /// windows that need WindowCoordinator's spec/chrome routing.
    func testNonWindowSystemSources_doNotConstructOrPresentWindowsDirectly() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Zulangue", isDirectory: true)

        let disallowedPatterns = [
            #"(?:final\s+)?class\s+\w+[^{\n]*:\s*[^{\n]*\b(?:NSWindowController|NSPanel)\b"#,
            #"\bNS(?:Window|Panel)\s*\("#,
            #"\.(?:orderFrontRegardless|orderFront|makeKeyAndOrderFront|setFrame|showWindow|orderOut)\("#,
            #"\bNSApp\.windows\b"#,
            #"\bNSWindow\.(?:didResizeNotification|didMoveNotification|didBecomeKeyNotification|didResignKeyNotification|didBecomeMainNotification|didResignMainNotification|willStartLiveResizeNotification|didEndLiveResizeNotification|didMiniaturizeNotification|didDeminiaturizeNotification|didChangeScreenNotification|willCloseNotification)\b"#,
        ]

        let enumerator = FileManager.default.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: nil
        )

        var violations: [String] = []

        while let fileURL = enumerator?.nextObject() as? URL {
            guard fileURL.pathExtension == "swift" else { continue }
            let relativePath = fileURL.path.replacingOccurrences(of: sourceRoot.path + "/", with: "")
            let allowedPrefixes = [
                "WindowSystem/",
                "WindowSystemV2/",
                "MenuBar/",
            ]
            if allowedPrefixes.contains(where: { relativePath.hasPrefix($0) }) {
                continue
            }
            let contents = try String(contentsOf: fileURL, encoding: .utf8)
            if let pattern = disallowedPatterns.first(where: {
                contents.range(of: $0, options: .regularExpression) != nil
            }) {
                violations.append("\(relativePath) matches \(pattern)")
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            """
            Window construction/presentation leaked outside WindowSystem:
            \(violations.joined(separator: "\n"))
            """
        )
    }

    // MARK: - Menu bar replaces Dynamic Island

    /// Dynamic Island modules must stay removed — anything that resurfaces them
    /// would also resurface the hover/notch layout machinery the rip dropped.
    func testDynamicIslandSources_areRemovedAfterMenuBarCutover() {
        let zulangue = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Zulangue", isDirectory: true)

        let mustNotExist = [
            "DynamicIsland",
            "UIScenesV2/Island",
            "WindowSystemV2/Surfaces/DynamicIslandControllerV2.swift",
            "WindowSystemV2/Surfaces/DynamicIslandPanelV2.swift",
            "WindowSystem/DynamicIslandScreenResolver.swift",
            "WindowSystem/NotchSpaceManager.swift",
            "AppV2/FrontendSceneOrchestratorV2.swift",
            "ProjectionsV2/ProjectionAssemblerV2.swift",
            "AppV2/OverlaySessionCoordinatorV2.swift",
            "WindowSystemV2/Surfaces/OverlayControllersV2.swift",
        ]

        for path in mustNotExist {
            let url = zulangue.appendingPathComponent(path)
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: url.path),
                "post-rip leftover: \(path) should be deleted"
            )
        }
    }

    /// ZulangueApp.swift must boot the menu-bar coordinator, not the island.
    func testZulangueApp_installsMenuBarCoordinatorInsteadOfDynamicIsland() throws {
        let appSource = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Zulangue/ZulangueApp.swift")
        let contents = try String(contentsOf: appSource, encoding: .utf8)

        XCTAssertTrue(contents.contains("MenuBarCoordinator.shared.install()"))
        XCTAssertTrue(contents.contains("MenuBarSuppressionCoordinator.shared.start()"))
        XCTAssertFalse(contents.contains("showDynamicIslandIfNeeded"))
        XCTAssertFalse(contents.contains("IslandSuppressionCoordinator"))
        XCTAssertFalse(contents.contains("IslandRuntimeStoreV2"))
    }

    /// WindowSurfaceID must not list `.dynamicIsland` — the catalog drove every
    /// window-system code path off that case.
    func testWindowSurfaceID_doesNotIncludeDynamicIsland() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Zulangue/WindowSystem/WindowSurfaceID.swift")
        let contents = try String(contentsOf: source, encoding: .utf8)

        XCTAssertFalse(contents.contains("case dynamicIsland"))
        XCTAssertTrue(contents.contains("case main"))
        XCTAssertTrue(contents.contains("case subtitleOverlay"))
        XCTAssertFalse(contents.contains("case floatingPanel"))
        XCTAssertFalse(contents.contains("case captionMirror"))
        XCTAssertFalse(contents.contains("case operatorPanel"))
    }

    // MARK: - Single subtitle overlay lifecycle

    func testWindowCoordinator_doesNotOwnSubtitleTogglePolicy() throws {
        let coordinatorSource = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Zulangue/WindowSystem/WindowCoordinator.swift")
        let contents = try String(contentsOf: coordinatorSource, encoding: .utf8)

        XCTAssertFalse(contents.contains("func toggleSubtitleOverlay("))
        XCTAssertTrue(contents.contains("func presentSubtitleOverlay("))
    }

    func testWindowCommandRouter_routesSubtitleCommandThroughSubtitleCoordinator() throws {
        let routerSource = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Zulangue/WindowSystem/WindowCommandRouter.swift")
        let contents = try String(contentsOf: routerSource, encoding: .utf8)

        XCTAssertTrue(contents.contains("SubtitleOverlayCoordinator.shared.toggle()"))
        XCTAssertFalse(contents.contains("toggleCaptionMirror"))
        XCTAssertFalse(contents.contains("toggleFloatingPanel"))
    }

    func testZulangueApp_doesNotControlSubtitleOverlayWhenCaptureChanges() throws {
        let appSource = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Zulangue/ZulangueApp.swift")
        let contents = try String(contentsOf: appSource, encoding: .utf8)

        XCTAssertFalse(contents.contains("SubtitleOverlayCoordinator.shared.dismiss()"))
    }

    // MARK: - Main window + navigation model

    func testMainWindowControllerV2_hostsMainShellViewV2() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Zulangue", isDirectory: true)
        let source = root.appendingPathComponent("WindowSystemV2/Surfaces/MainWindowControllerV2.swift")
        let contents = try String(contentsOf: source, encoding: .utf8)

        XCTAssertTrue(contents.contains("MainShellViewV2("))
        XCTAssertFalse(contents.contains("MainWindowView()"))
    }

    func testMainShellViewV2_ownsRealMainWindowContentInsteadOfPlaceholderBanner() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Zulangue", isDirectory: true)
        let source = root.appendingPathComponent("UIScenesV2/Main/MainShellViewV2.swift")
        let contents = try String(contentsOf: source, encoding: .utf8)

        XCTAssertFalse(contents.contains("Text(\"Zulangue V2\")"))
        XCTAssertTrue(contents.contains("HomeView()"))
        XCTAssertTrue(contents.contains("DocumentEditorPage("))
        XCTAssertTrue(contents.contains("FullSettingsView()"))
    }

    func testMainShellNamesNotebookRoutesAndDoesNotShowFakeIdentity() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Zulangue", isDirectory: true)
        let source = root.appendingPathComponent("UIScenesV2/Main/MainShellViewV2.swift")
        let contents = try String(contentsOf: source, encoding: .utf8)

        XCTAssertTrue(contents.contains("store.activeNotebookTitle"))
        XCTAssertFalse(contents.contains("notebookContext.activeNotebookTitle"))
        XCTAssertTrue(contents.contains("sidebar.notebook"))
        XCTAssertTrue(contents.contains("sidebar.local_first"))
        XCTAssertFalse(contents.contains("Text(\"anon\")"))
        XCTAssertFalse(contents.contains("openGitHub"))
    }

    func testWindowCommandRouter_usesMainNavigationStoreV2() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Zulangue", isDirectory: true)
        let source = root.appendingPathComponent("WindowSystem/WindowCommandRouter.swift")
        let contents = try String(contentsOf: source, encoding: .utf8)

        XCTAssertTrue(contents.contains("MainNavigationStoreV2.shared"))
        XCTAssertFalse(contents.contains("MainWindowNavigationModel"))
    }

    func testZulangueApp_keepsMainWindowOutsideAppEntryPoint() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Zulangue", isDirectory: true)
        let source = root.appendingPathComponent("ZulangueApp.swift")
        let contents = try String(contentsOf: source, encoding: .utf8)

        XCTAssertFalse(contents.contains("struct MainWindowView: View"))
    }

}
