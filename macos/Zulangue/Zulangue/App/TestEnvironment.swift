// TestEnvironment.swift
// 测试模式环境检测。
//
// 三种 launch 模式:
//   1. 正常用户运行            — 菜单栏 status item ✓ onboarding ✓ STT 真后端 ✓
//   2. Unit test (ZulangueTests) — 菜单栏 status item ✗ (NSStatusBar 在 XCTest 进程不稳) onboarding ✓ STT 真
//   3. UI test (ZulangueUITests) — 菜单栏 status item ✓ (供黑盒测试触发) onboarding ✗ STT mock
//
// 检测策略:
//   - XCTestConfigurationFilePath 由 Xcode 自动设, unit + UI test 都有
//   - VT_UI_TEST 通过 XCUIApplication.launchEnvironment 设, 只 UI test 有
//   - 没有 XCTestConfigurationFilePath = 用户运行

import Foundation

enum TestEnvironment {

    /// 是否处于任何 XCTest 进程内 (unit 或 UI)
    nonisolated static var isAnyTestMode: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// 是否处于 unit test 模式 (ZulangueTests 跑)
    /// — 这种模式下 host app 跟 unit test 在同一进程, NSStatusBar 必须跳过
    nonisolated static var isUnitTestMode: Bool {
        isAnyTestMode && !isUITestMode
    }

    /// 是否处于 UI test 模式 (ZulangueUITests 跑)
    /// — 这种模式下 host app 是被 XCUIApplication 启动的独立进程,
    ///   通过 launchEnvironment["VT_UI_TEST"] = "1" 标记
    nonisolated static var isUITestMode: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["VT_UI_TEST"] == "1"
            || environment["VT_TEST_MODE"] == "1"
    }

    /// UI test 是否要求跳过真实 Soniox (用 mock 不发网络请求)
    /// 默认 ON 防止测试消耗真 API 配额
    nonisolated static var shouldMockSoniox: Bool {
        isUITestMode && ProcessInfo.processInfo.environment["VT_REAL_SONIOX"] != "1"
    }

    /// UI test 是否要求关闭 toast auto-dismiss
    /// 让断言 toast 时不会消失
    nonisolated static var shouldDisableToastAutoDismiss: Bool {
        isUITestMode
    }

    /// UI test 是否在启动时预填一个测试用 Soniox key
    /// 让需要 key 的代码路径不会因为缺 key 短路 (可以是 fake 值)
    nonisolated static var shouldPreloadFakeKeys: Bool {
        isUITestMode
    }

    /// Saved provider credentials belong to the signed-in user's real app
    /// profile. Neither unit tests nor UI tests may inspect or activate them.
    ///
    /// Keep the pure overload so the four launch combinations stay covered by
    /// deterministic tests without mutating the process environment.
    nonisolated static var shouldLoadSavedProviderCredentials: Bool {
        shouldLoadSavedProviderCredentials(
            isUnitTestMode: isUnitTestMode,
            isUITestMode: isUITestMode
        )
    }

    nonisolated static func shouldLoadSavedProviderCredentials(
        isUnitTestMode: Bool,
        isUITestMode: Bool
    ) -> Bool {
        !isUnitTestMode && !isUITestMode
    }
}
