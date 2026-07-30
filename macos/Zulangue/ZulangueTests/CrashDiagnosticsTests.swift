import AppKit
import XCTest
@testable import Zulangue

@MainActor
final class CrashDiagnosticsTests: XCTestCase {

    override func setUp() {
        super.setUp()
        WindowCoordinator.shared.resetForTesting()
        CrashDiagnostics.resetForTesting()
        CrashDiagnostics.clearCrashReport()
    }

    func testBuildUncaughtExceptionReport_includesReasonAndBreadcrumbs() {
        CrashDiagnostics.record("window.attach", "main", detail: "frame=x=0.0 y=0.0 w=900.0 h=600.0")
        let exception = NSException(
            name: .internalInconsistencyException,
            reason: "layout recursion detected",
            userInfo: ["window": "main"]
        )

        let report = CrashDiagnostics.buildUncaughtExceptionReport(for: exception)

        XCTAssertTrue(report.contains("layout recursion detected"))
        XCTAssertTrue(report.contains("window.attach main"))
        XCTAssertTrue(report.contains("No window snapshot captured yet.") || report.contains("No AppKit windows."))
    }

    func testClearCrashReport_removesExistingFile() throws {
        let data = Data("crash".utf8)
        try data.write(to: CrashDiagnostics.crashReportURL)

        CrashDiagnostics.clearCrashReport()

        XCTAssertFalse(FileManager.default.fileExists(atPath: CrashDiagnostics.crashReportURL.path))
    }

    @MainActor
    func testBuildUncaughtExceptionReport_includesWindowSystemSnapshot() {
        let window = NSWindow(
            contentRect: NSRect(x: 10, y: 20, width: 640, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier(WindowSurfaceID.main.rawValue)
        window.title = "Zulangue"

        WindowCoordinator.shared.registerWindow(window, id: .main)

        let exception = NSException(
            name: .internalInconsistencyException,
            reason: "window snapshot requested",
            userInfo: nil
        )

        let report = CrashDiagnostics.buildUncaughtExceptionReport(for: exception)

        XCTAssertTrue(report.contains("[Registry]"))
        XCTAssertTrue(report.contains("surface=main"))
        XCTAssertTrue(report.contains("[AppKit]"))
        XCTAssertFalse(report.contains("No window snapshot captured yet."))
    }
}
