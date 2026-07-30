import XCTest
@testable import Zulangue

final class CoreIntegrationTests: XCTestCase {

    func testCoreInit() throws {
        let tmpDir = NSTemporaryDirectory()
            .appending("zulangue-test-\(UUID().uuidString)")
        let core = try ZulangueCore.newDeferred(dataDir: tmpDir)
        XCTAssertNotNil(core)
        try? FileManager.default.removeItem(atPath: tmpDir)
    }

    func testApiVersion() throws {
        let tmpDir = NSTemporaryDirectory()
            .appending("zulangue-test-\(UUID().uuidString)")
        let core = try ZulangueCore.newDeferred(dataDir: tmpDir)
        let version = core.apiVersion()
        XCTAssertFalse(version.isEmpty)
        XCTAssertTrue(version.hasPrefix("0."))
        try? FileManager.default.removeItem(atPath: tmpDir)
    }

    func testCoreShutdown() throws {
        let tmpDir = NSTemporaryDirectory()
            .appending("zulangue-test-\(UUID().uuidString)")
        let core = try ZulangueCore.newDeferred(dataDir: tmpDir)
        XCTAssertNoThrow(try core.shutdown())
        try? FileManager.default.removeItem(atPath: tmpDir)
    }

    @MainActor
    func testUnitTestDefaultDataDirIsOutsideRealApplicationSupport() {
        XCTAssertTrue(TestEnvironment.isUnitTestMode)
        let dataURL = URL(fileURLWithPath: CoreClient.defaultDataDir()).standardizedFileURL
        let temporaryURL = FileManager.default.temporaryDirectory.standardizedFileURL

        XCTAssertTrue(dataURL.path.hasPrefix(temporaryURL.path))
        XCTAssertFalse(dataURL.path.contains("Library/Application Support/Zulangue"))
    }

    @MainActor
    func testFrontendLiveClientsUseProductUnavailableCopyAtClientBoundary() {
        let serviceUnavailable = "Local app service is not ready yet."

        let taskClient = LiveTaskStatusClient(coreProvider: { nil })
        XCTAssertThrowsError(try taskClient.listTasks(statusFilter: nil)) { error in
            XCTAssertEqual(error.localizedDescription, serviceUnavailable)
        }

        let workspaceClient = LiveNotebookWorkspaceClient(coreProvider: { nil })
        XCTAssertThrowsError(try workspaceClient.listNotebooks()) { error in
            XCTAssertEqual(error.localizedDescription, serviceUnavailable)
        }

    }
}
