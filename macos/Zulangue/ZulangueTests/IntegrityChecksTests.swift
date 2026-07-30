// IntegrityChecksTests.swift
// 验证应用启动自检在隔离测试环境中的输出。

import XCTest
@testable import Zulangue

@MainActor
final class IntegrityChecksTests: XCTestCase {

    // MARK: - 单个 check 测试

    func testCheckInfoPlistMicrophoneUsageDescription_passesInTestBundle() {
        // unit test 跑在 Zulangue.app host 进程内, Bundle.main 是 Zulangue.app
        // Zulangue.app 应当包含 NSMicrophoneUsageDescription。
        let result = IntegrityChecks.checkInfoPlistMicrophoneUsageDescription()
        XCTAssertTrue(
            result.passed,
            "Zulangue.app must have NSMicrophoneUsageDescription, got: \(result.detail ?? "")"
        )
    }

    func testCheckInfoPlistBundleIdentifier_passesInTestBundle() {
        let result = IntegrityChecks.checkInfoPlistBundleIdentifier()
        XCTAssertTrue(result.passed)
    }

    func testUniffiPreflight_isHealthyInTestBundle() {
        XCTAssertNil(uniffiVtFfiInitializationError())
    }

    func testCheckCoreClientInitialized_inTestEnvironment() {
        // CoreClient 在 test setup 时会被初始化 (各 test class setUp 调 ZulangueCore.new)
        // 但 unit test 进程的 CoreClient.shared.core 可能是 nil
        // 这个测试只验证 check 函数不崩, 结果取决于环境
        let result = IntegrityChecks.checkCoreClientInitialized()
        // 不强断言 passed/failed, 只验证 check 返回了一个 result
        XCTAssertEqual(result.name.contains("Core"), true)
    }

    func testCheckMenuBarStatusItemMounted_skipsInUnitTest() {
        // unit test mode (TestEnvironment.isUnitTestMode == true) 应当跳过实际检查 ——
        // NSStatusBar.system 在 XCTest 进程里行为不稳定,真实检查要靠 app 启动自检。
        let result = IntegrityChecks.checkMenuBarStatusItemMounted()
        XCTAssertTrue(result.passed, "should be ok (skipped) in unit test")
        XCTAssertTrue(
            result.name.contains("skipped"),
            "skip reason should mention 'skipped'"
        )
    }

    func testCheckAllZulangueNotificationsHaveAtLeastOneObserver_namesValid() {
        let result = IntegrityChecks.checkAllZulangueNotificationsHaveAtLeastOneObserver()
        XCTAssertTrue(result.passed, "notification names check failed: \(result.detail ?? "")")
    }

    func testCheckMainWindowOpenerRegistered_inUnitTest() {
        // unit test 环境下主窗口可能没 render → openAction 没 register → fail
        // 但 check 函数本身应当不崩
        let result = IntegrityChecks.checkMainWindowOpenerRegistered()
        XCTAssertNotNil(result.name)
        // 不强断言 passed (取决于是否有主窗口先 render)
    }

    func testCheckApplicationSupportDirWritable_passes() {
        let result = IntegrityChecks.checkApplicationSupportDirWritable()
        XCTAssertTrue(
            result.passed,
            "Application Support dir must be writable: \(result.detail ?? "")"
        )
    }

    func testCheckProviderCredentialFileLocation_passesForIsolatedPrivateFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("IntegrityProviderCredentials-\(UUID().uuidString)")
        let fileURL = root
            .appendingPathComponent("Secrets", isDirectory: true)
            .appendingPathComponent("provider-credentials.json")
        defer { try? FileManager.default.removeItem(at: root) }
        try ProviderCredentialFileStore(fileURL: fileURL).save([.soniox: "fixture-token"])

        let result = IntegrityChecks.checkProviderCredentialFileLocation(fileURL: fileURL)
        XCTAssertTrue(
            result.passed,
            "private provider credential location should be valid: \(result.detail ?? "")"
        )
        XCTAssertFalse(result.name.contains("api_keys.json"))
    }

    // MARK: - runAll 完整套件

    func testRunAll_returnsResultsForAllChecks() {
        let results = IntegrityChecks.runAll()
        XCTAssertGreaterThanOrEqual(
            results.count,
            8,
            "should run at least 8 checks (Info.plist, bundle id, core, menu bar, notifs, opener, dir, provider credentials)"
        )

        // 每个结果都有 name + 至少一个 passed/failed bool
        for r in results {
            XCTAssertFalse(r.name.isEmpty, "result must have non-empty name")
        }
    }

    /// 关键: 在 unit test 模式下, runOnLaunch() 应当不弹 toast (避免污染 ToastCenter)
    func testRunOnLaunch_skipsToastInUnitTestMode() {
        ToastCenter.shared.dismissAll()
        let beforeCount = ToastCenter.shared.toasts.count

        _ = IntegrityChecks.runOnLaunch()

        // unit test mode 下不应该 emit toast
        XCTAssertEqual(
            ToastCenter.shared.toasts.count,
            beforeCount,
            "runOnLaunch should not emit toast in unit test mode"
        )
    }
}
