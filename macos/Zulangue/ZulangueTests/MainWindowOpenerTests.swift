// MainWindowOpenerTests.swift
// 主窗口由 AppKit controller 与 coordinator 持有。Dock、菜单和热键统一通过
// MainWindowOpener.shared.open() 重开或拉前主窗口.
//
// 这个 unit test 验证:
// 1. MainWindowOpener.shared 是单例
// 2. open() 在没注册 action 时不崩溃 (fallback 到 NSApp.activate)
// 3. open() 在已存在主窗口时直接 makeKeyAndOrderFront, 不调用 action
// 4. opener 本身应始终 ready,不再依赖 view 生命周期里的 register.

import XCTest
import SwiftUI
@testable import Zulangue

@MainActor
final class MainWindowOpenerTests: XCTestCase {

    private final class FlagBox: @unchecked Sendable {
        var value = false
    }

    override func setUp() {
        super.setUp()
        WindowCommandRouter.shared.resetForTesting()
    }

    func testMainWindowOpener_isSingleton() {
        let a = MainWindowOpener.shared
        let b = MainWindowOpener.shared
        XCTAssertTrue(a === b, "MainWindowOpener.shared should return the same instance")
    }

    /// 没 register 也能 open() 不崩 (fallback 到 NSApp.activate, 用户至少能看到 dock)
    func testMainWindowOpener_openWithoutRegisteredAction_doesNotCrash() {
        // 不预先 register, 直接调 open()
        // (单元测试进程内 NSApp.windows 可能为空, fallback 路径必须安全)
        MainWindowOpener.shared.open()
        XCTAssertTrue(true, "open() without registered action must not crash")
    }

    /// 多次 open() 不会 race / 不会 crash
    func testMainWindowOpener_openMultipleTimes_isIdempotent() {
        for _ in 0..<10 {
            MainWindowOpener.shared.open()
        }
        XCTAssertTrue(true, "rapid open() calls should not crash")
    }

    func testMainWindowOpener_openThenRunsFollowUp() {
        let exp = expectation(description: "followUp should run on the next main-thread turn")

        MainWindowOpener.shared.open {
            exp.fulfill()
        }

        wait(for: [exp], timeout: 1.0)
    }

    func testHandleOpenMainWindowRequest_invokesUnifiedOpenAction() {
        let delegate = ZulangueAppDelegate()
        let opened = FlagBox()
        delegate.mainWindowOpenAction = {
            opened.value = true
        }

        delegate.handleOpenMainWindowRequest()

        XCTAssertTrue(opened.value, "menu-bar / hotkey reopen should use the unified opener")
    }

    func testApplicationShouldHandleReopen_invokesUnifiedOpenActionEvenWhenAppHasVisibleWindows() {
        let delegate = ZulangueAppDelegate()
        let opened = FlagBox()
        delegate.mainWindowOpenAction = {
            opened.value = true
        }

        let handled = delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true)

        XCTAssertTrue(handled, "dock reopen should be handled by the app delegate")
        XCTAssertTrue(opened.value, "dock reopen should still use the main-window opener")
    }

    func testApplicationQuit_cancelledRecordingConfirmationCancelsEveryQuitRoute() {
        let delegate = ZulangueAppDelegate()
        let confirmationPresented = FlagBox()
        let preparationChecked = FlagBox()
        delegate.requiresQuitConfirmationAction = { true }
        delegate.confirmQuitAction = {
            confirmationPresented.value = true
            return false
        }
        delegate.requiresCaptureTerminationPreparationAction = {
            preparationChecked.value = true
            return false
        }

        let reply = delegate.applicationShouldTerminate(NSApp)

        XCTAssertEqual(reply, .terminateCancel)
        XCTAssertTrue(confirmationPresented.value)
        XCTAssertFalse(
            preparationChecked.value,
            "cancelling the shared app-level confirmation must not begin termination"
        )
    }

    func testApplicationQuit_confirmedRecordingContinuesThroughTerminationDelegate() {
        let delegate = ZulangueAppDelegate()
        let confirmationPresented = FlagBox()
        delegate.requiresQuitConfirmationAction = { true }
        delegate.confirmQuitAction = {
            confirmationPresented.value = true
            return true
        }
        delegate.requiresCaptureTerminationPreparationAction = { false }

        let reply = delegate.applicationShouldTerminate(NSApp)

        XCTAssertEqual(reply, .terminateNow)
        XCTAssertTrue(confirmationPresented.value)
    }

    func testApplicationQuit_withoutActiveRecordingDoesNotPresentConfirmation() {
        let delegate = ZulangueAppDelegate()
        let confirmationPresented = FlagBox()
        delegate.requiresQuitConfirmationAction = { false }
        delegate.confirmQuitAction = {
            confirmationPresented.value = true
            return false
        }
        delegate.requiresCaptureTerminationPreparationAction = { false }

        let reply = delegate.applicationShouldTerminate(NSApp)

        XCTAssertEqual(reply, .terminateNow)
        XCTAssertFalse(confirmationPresented.value)
    }

    func testApplicationDidBecomeActive_opensMainWindowWhenNotVisible() {
        let delegate = ZulangueAppDelegate()
        let opened = FlagBox()
        delegate.mainWindowVisibilityCheck = { false }
        delegate.mainWindowOpenAction = {
            opened.value = true
        }

        delegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))

        XCTAssertTrue(opened.value, "activation should recover the main window when it is not visible")
    }

    func testApplicationDidBecomeActive_skipsOpenWhenMainWindowAlreadyVisible() {
        let delegate = ZulangueAppDelegate()
        let opened = FlagBox()
        delegate.mainWindowVisibilityCheck = { true }
        delegate.mainWindowOpenAction = {
            opened.value = true
        }

        delegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))

        XCTAssertFalse(opened.value, "activation should not force-open when the main window is already visible")
    }

    func testMainWindowOpener_isAlwaysReadyUnderWindowSystem() {
        XCTAssertTrue(
            MainWindowOpener.shared.isRegistered,
            "AppKit-owned window system should always provide a main-window opener"
        )
    }

    @available(macOS 13.0, *)
    func testWindowChromeConfigurator_stabilizeSwiftUIHostingTree_clearsHostingViewSizingOptions() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: window.contentLayoutRect)
        let hostingView = NSHostingView(rootView: Color.clear.frame(width: 640, height: 480))
        hostingView.sizingOptions = [.minSize, .intrinsicContentSize, .maxSize, .preferredContentSize]
        container.addSubview(hostingView)
        window.contentView = container

        WindowChromeConfigurator.shared.stabilizeSwiftUIHostingTree(on: window)

        XCTAssertEqual(hostingView.sizingOptions, [], "main-window hosting view should not push intrinsic size back into the window")
    }

    @available(macOS 13.0, *)
    func testWindowChromeConfigurator_stabilizeSwiftUIHostingTree_clearsHostingControllerSizingOptions() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        let controller = NSHostingController(rootView: Color.clear.frame(width: 640, height: 480))
        controller.sizingOptions = [.minSize, .intrinsicContentSize]
        window.contentViewController = controller

        WindowChromeConfigurator.shared.stabilizeSwiftUIHostingTree(on: window)

        XCTAssertEqual(controller.sizingOptions, [], "main-window hosting controller should stop auto-resizing the window during tab switches")
    }

}
