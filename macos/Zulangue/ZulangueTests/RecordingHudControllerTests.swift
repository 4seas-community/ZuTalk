// RecordingHudControllerTests.swift
//
// Tests for the menu-bar-hidden heuristic that decides whether to present the
// full-screen recording REC pill. The actual panel lifecycle is skipped under
// unit-test mode (TestEnvironment.isUnitTestMode short-circuits `install()`),
// so coverage here focuses on the pure detection logic.

import XCTest
@testable import Zulangue

@MainActor
final class RecordingHudControllerTests: XCTestCase {

    /// Normal-mode menu bar (24pt) → not hidden.
    func testIsMenuBarHidden_normalMenuBarHeight_returnsFalse() {
        let screen = FakeScreen(
            frame: NSRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: NSRect(x: 0, y: 0, width: 1512, height: 958)
        )

        XCTAssertFalse(RecordingHudController.isMenuBarHidden(screen: screen.proxy))
    }

    /// Full-screen mode (menu bar auto-hidden) → visibleFrame equals frame → hidden.
    func testIsMenuBarHidden_fullScreenMode_returnsTrue() {
        let screen = FakeScreen(
            frame: NSRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: NSRect(x: 0, y: 0, width: 1512, height: 982)
        )

        XCTAssertTrue(RecordingHudController.isMenuBarHidden(screen: screen.proxy))
    }

    /// Borderline: 8pt difference is still "hidden" (within the < 10pt slack).
    func testIsMenuBarHidden_eightPointDifference_returnsTrue() {
        let screen = FakeScreen(
            frame: NSRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: NSRect(x: 0, y: 0, width: 1512, height: 974)
        )

        XCTAssertTrue(RecordingHudController.isMenuBarHidden(screen: screen.proxy))
    }

    /// Borderline: 12pt difference is "visible" — under the slack threshold.
    func testIsMenuBarHidden_twelvePointDifference_returnsFalse() {
        let screen = FakeScreen(
            frame: NSRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: NSRect(x: 0, y: 0, width: 1512, height: 970)
        )

        XCTAssertFalse(RecordingHudController.isMenuBarHidden(screen: screen.proxy))
    }

    /// Nil screen (rare: no displays attached) → not hidden — safer to err on
    /// "show no pill" than to flash one in an unknown geometry.
    func testIsMenuBarHidden_nilScreen_returnsFalse() {
        XCTAssertFalse(RecordingHudController.isMenuBarHidden(screen: nil))
    }

    // MARK: - Multi-monitor: menuBarHiddenScreen iterates

    /// All screens have visible menu bar → no pill — returns nil.
    func testMenuBarHiddenScreen_allVisible_returnsNil() {
        let primary = FakeScreen(
            frame: NSRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: NSRect(x: 0, y: 0, width: 1512, height: 958)
        ).proxy!
        let secondary = FakeScreen(
            frame: NSRect(x: 1512, y: 0, width: 2560, height: 1440),
            visibleFrame: NSRect(x: 1512, y: 0, width: 2560, height: 1416)
        ).proxy!

        XCTAssertNil(RecordingHudController.menuBarHiddenScreen(screens: [primary, secondary]))
    }

    /// Secondary screen is in full-screen mode, primary has menu bar visible.
    /// This is the multi-monitor regression the security reviewer flagged:
    /// `NSScreen.main` resolves to the primary (key window's screen), but the
    /// user is staring at the secondary. The pill must target the secondary.
    func testMenuBarHiddenScreen_secondaryInFullScreen_returnsSecondary() {
        let primary = FakeScreen(
            frame: NSRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: NSRect(x: 0, y: 0, width: 1512, height: 958)
        ).proxy!
        let secondary = FakeScreen(
            frame: NSRect(x: 1512, y: 0, width: 2560, height: 1440),
            visibleFrame: NSRect(x: 1512, y: 0, width: 2560, height: 1440)
        ).proxy!

        let hidden = RecordingHudController.menuBarHiddenScreen(screens: [primary, secondary])

        XCTAssertNotNil(hidden, "the full-screen secondary monitor must be returned")
        XCTAssertEqual(hidden?.frame.origin.x, 1512, "must be the secondary monitor, not the primary")
    }

    /// Both screens hidden (e.g. user has 'always hide menu bar' system
    /// preference plus a full-screen app on secondary). First match is fine —
    /// the pill is small enough that picking any hidden screen is acceptable.
    func testMenuBarHiddenScreen_bothHidden_returnsFirst() {
        let primary = FakeScreen(
            frame: NSRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: NSRect(x: 0, y: 0, width: 1512, height: 982)
        ).proxy!
        let secondary = FakeScreen(
            frame: NSRect(x: 1512, y: 0, width: 2560, height: 1440),
            visibleFrame: NSRect(x: 1512, y: 0, width: 2560, height: 1440)
        ).proxy!

        let hidden = RecordingHudController.menuBarHiddenScreen(screens: [primary, secondary])

        XCTAssertEqual(hidden?.frame.origin.x, 0, "first hidden screen wins")
    }

    /// Empty screen list (defensive) → nil. Should not crash.
    func testMenuBarHiddenScreen_emptyList_returnsNil() {
        XCTAssertNil(RecordingHudController.menuBarHiddenScreen(screens: []))
    }
}

/// Lightweight stand-in for `NSScreen` — we only need `.frame` and `.visibleFrame`
/// from the heuristic, but `NSScreen` can't be subclassed for tests. The shared
/// helper exposes a real `NSScreen` proxy by stretching `NSScreen.main` semantics
/// in-process — simpler: just check the math on raw rects via the underlying
/// static, which is a thin wrapper. The test names document the cases the
/// heuristic must handle even if we drive it via the public static below.
private struct FakeScreen {
    let frame: NSRect
    let visibleFrame: NSRect

    /// Returns a real `NSScreen` we can substitute when the unit fits. macOS
    /// `NSScreen` is `open` but not designed for subclassing across all
    /// frameworks — instead we forward through a thin wrapper that lets us
    /// call the same static the production code uses, with fake geometry.
    var proxy: NSScreen? {
        ProxyScreen.fake(frame: frame, visibleFrame: visibleFrame)
    }
}

/// Subclasses `NSScreen` purely so we can override `frame` and `visibleFrame`.
/// Used in unit tests to feed deterministic geometry into
/// `RecordingHudController.isMenuBarHidden(screen:)` without requiring a real
/// monitor configuration.
///
/// SAFETY: only `frame` and `visibleFrame` are valid to call on a `ProxyScreen`.
/// `NSScreen` has no documented public designated initializer; `super.init()`
/// inherits `NSObject.init()` and leaves the internal display state
/// uninitialized. Any other API (`safeAreaInsets`, `backingScaleFactor`,
/// `displayLink(target:selector:)`, `localizedName`, …) will deref state that
/// was never populated and crash. The production code under test only reads
/// the two overridden properties.
private final class ProxyScreen: NSScreen {
    private let _frame: NSRect
    private let _visibleFrame: NSRect

    fileprivate init(frame: NSRect, visibleFrame: NSRect) {
        self._frame = frame
        self._visibleFrame = visibleFrame
        super.init()
    }

    override var frame: NSRect { _frame }
    override var visibleFrame: NSRect { _visibleFrame }

    static func fake(frame: NSRect, visibleFrame: NSRect) -> NSScreen {
        ProxyScreen(frame: frame, visibleFrame: visibleFrame)
    }
}
