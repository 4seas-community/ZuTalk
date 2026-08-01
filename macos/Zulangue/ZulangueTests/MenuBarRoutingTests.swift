// MenuBarRoutingTests.swift
//
// Coverage for `NSApplication.sendMenuBarAction(_:)` — the dispatch path the
// menu-bar popover's idle-state rows use to fire commands. The tests stay
// action-string-driven so we catch any regression where a row stops reaching
// its router.

import XCTest
import AppKit
@testable import Zulangue

@MainActor
final class MenuBarRoutingTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        WindowCommandRouter.shared.resetForTesting()
        MenuBarRuntimeStore.shared.resetForTesting()
    }

    override func tearDown() async throws {
        SoftwareUpdateController.shared.installTestCheckAction(nil)
        WindowCommandRouter.shared.installTestOverrides(nil)
        MenuBarRuntimeStore.shared.resetForTesting()
        try await super.tearDown()
    }

    private func sendMenuBarAction(_ action: String) {
        let item = NSMenuItem()
        item.representedObject = action
        NSApp.sendMenuBarAction(item)
    }

    // MARK: - Popover actions → router

    func testRecordingAction_opensNotebookWithoutTogglingCapture() {
        let exp = expectation(description: "recording action should open Notebook")
        var detail: String?
        WindowCommandRouter.shared.installTestOverrides(
            WindowCommandRouterTestOverrides(
                openMainWindow: { receivedDetail, _ in
                    detail = receivedDetail
                    exp.fulfill()
                }
            )
        )

        sendMenuBarAction("recording")

        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(detail, "menu-bar.popover.open-capture-notebook")
    }

    func testSubtitlesAction_routesToggleSubtitleOverlayCommand() {
        let exp = expectation(description: "subtitles action should reach router override")
        var received = false
        WindowCommandRouter.shared.installTestOverrides(
            WindowCommandRouterTestOverrides(
                toggleSubtitleOverlay: {
                    received = true
                    exp.fulfill()
                }
            )
        )

        sendMenuBarAction("subtitles")

        wait(for: [exp], timeout: 1.0)
        XCTAssertTrue(received, "'subtitles' action must route toggleSubtitleOverlay")
    }

    func testSettingsAction_routesOpenSettingsCommand() {
        // requestOpenSettings dispatches the override on a Task { @MainActor },
        // so the assertion has to wait for the next runloop turn rather than
        // checking inline.
        let exp = expectation(description: "settings action should reach router override")
        var received = false
        WindowCommandRouter.shared.installTestOverrides(
            WindowCommandRouterTestOverrides(
                openSettings: {
                    received = true
                    exp.fulfill()
                }
            )
        )

        sendMenuBarAction("settings")

        wait(for: [exp], timeout: 1.0)
        XCTAssertTrue(received, "'settings' action must route openSettings")
    }

    func testCheckForUpdatesAction_routesToSparkleController() {
        let exp = expectation(description: "update action should reach Sparkle controller")
        SoftwareUpdateController.shared.installTestCheckAction {
            exp.fulfill()
        }

        sendMenuBarAction("checkForUpdates")

        wait(for: [exp], timeout: 1.0)
    }

    func testUnknownAction_isIgnoredSilently() {
        // Stray representedObject values should not crash the dispatcher.
        sendMenuBarAction("zzz-unknown-action")
        // If we reached here without crash, the dispatcher behaved correctly.
    }

    func testStatusItemIconsUseNativeMenuBarDimensions() {
        let icons = [
            MenuBarStatusItemIcon.idle,
            MenuBarStatusItemIcon.processing,
            MenuBarStatusItemIcon.micDenied,
            MenuBarStatusItemIcon.recording,
            MenuBarStatusItemIcon.recordingDim,
            MenuBarStatusItemIcon.recordingPaused,
        ]

        for icon in icons {
            XCTAssertEqual(icon.size, NSSize(width: 18, height: 18))
        }
        XCTAssertTrue(MenuBarStatusItemIcon.idle.isTemplate)
        XCTAssertTrue(MenuBarStatusItemIcon.processing.isTemplate)
    }

    func testStatusItemClick_activatesBeforeShowingPopover() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Zulangue", isDirectory: true)
        let source = root.appendingPathComponent("MenuBar/MenuBarCoordinator.swift")
        let contents = try String(contentsOf: source, encoding: .utf8)

        let activation = try XCTUnwrap(
            contents.range(of: "NSApp.activate(ignoringOtherApps: true)")
        )
        let presentation = try XCTUnwrap(
            contents.range(of: "popover.show(relativeTo:")
        )

        XCTAssertLessThan(activation.lowerBound, presentation.lowerBound)
    }
}
