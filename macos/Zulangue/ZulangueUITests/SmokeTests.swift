// SmokeTests.swift
// ZulangueUITests target 的最简烟雾测试 — 验证 target 能 build + run
// 一旦这个文件能跑通, 后续的真 UI tests (IslandActionsUITests / MainWindowFlowUITests) 才有意义

import XCTest

final class SmokeTests: XCTestCase {

    /// 最简: 验证 XCTest framework 链上 + 进程能起来
    func testSmokeXCTestFrameworkAvailable() {
        XCTAssertTrue(true, "XCTest framework loaded")
    }

    /// 验证 XCUIApplication 可以构造 (不 launch)
    func testSmokeXCUIApplicationConstruct() {
        let app = XCUIApplication()
        XCTAssertNotNil(app)
    }

    /// 真正的 launch 测试 — 必须能启动主 app
    /// 这是 UI test target 配置正确的最强信号
    func testSmokeAppCanLaunch() {
        let app = XCUIApplication()
        let dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZulangueUITests-\(UUID().uuidString)", isDirectory: true)
        app.launchEnvironment["VT_TEST_MODE"] = "1"
        app.launchEnvironment["VT_UI_TEST"] = "1"
        app.launchEnvironment["VT_TEST_DATA_DIR"] = dataDir.path
        app.launch()
        defer {
            app.terminate()
            try? FileManager.default.removeItem(at: dataDir)
        }
        // 启动成功就算过 — 不断言任何 UI 元素 (那是后续测试的事)
        XCTAssertEqual(app.state, .runningForeground, "app should be in foreground after launch")
    }
}
