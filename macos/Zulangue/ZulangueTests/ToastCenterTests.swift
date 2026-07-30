import XCTest
@testable import Zulangue

@MainActor
final class ToastCenterTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        ToastCenter.shared.dismissAll()
    }

    override func tearDown() async throws {
        ToastCenter.shared.dismissAll()
        try await super.tearDown()
    }

    // MARK: - Posting

    func testInfoToastIsAdded() {
        ToastCenter.shared.info("Hello")
        XCTAssertEqual(ToastCenter.shared.toasts.count, 1)
        XCTAssertEqual(ToastCenter.shared.toasts.first?.kind, .info)
        XCTAssertEqual(ToastCenter.shared.toasts.first?.title, "Hello")
    }

    func testSuccessToastWithDetail() {
        ToastCenter.shared.success("Saved", detail: "config.json")
        let toast = ToastCenter.shared.toasts.first
        XCTAssertEqual(toast?.kind, .success)
        XCTAssertEqual(toast?.detail, "config.json")
    }

    func testErrorToastHasLongerAutoDismiss() {
        ToastCenter.shared.error("Failed")
        XCTAssertEqual(ToastCenter.shared.toasts.first?.autoDismissAfter, 8)
    }

    func testInfoToastHasShorterAutoDismiss() {
        ToastCenter.shared.info("FYI")
        XCTAssertEqual(ToastCenter.shared.toasts.first?.autoDismissAfter, 5)
    }

    // MARK: - Capping

    func testCapsAtFourSimultaneous() {
        for i in 0..<10 {
            ToastCenter.shared.info("Toast \(i)")
        }
        XCTAssertEqual(ToastCenter.shared.toasts.count, 4)
        // 应该保留最新 4 个：6,7,8,9
        XCTAssertEqual(ToastCenter.shared.toasts.first?.title, "Toast 6")
        XCTAssertEqual(ToastCenter.shared.toasts.last?.title, "Toast 9")
    }

    // MARK: - Dismissal

    func testDismissByIdRemovesToast() {
        ToastCenter.shared.info("Bye")
        guard let id = ToastCenter.shared.toasts.first?.id else {
            XCTFail("toast missing")
            return
        }
        ToastCenter.shared.dismiss(id: id)
        XCTAssertEqual(ToastCenter.shared.toasts.count, 0)
    }

    func testDismissAllClearsToasts() {
        ToastCenter.shared.info("a")
        ToastCenter.shared.warning("b")
        ToastCenter.shared.error("c")
        XCTAssertEqual(ToastCenter.shared.toasts.count, 3)

        ToastCenter.shared.dismissAll()
        XCTAssertEqual(ToastCenter.shared.toasts.count, 0)
    }

    // MARK: - Toast.Kind metadata

    func testKindIcons() {
        XCTAssertEqual(Toast.Kind.info.icon, "info.circle")
        XCTAssertEqual(Toast.Kind.success.icon, "checkmark.circle")
        XCTAssertEqual(Toast.Kind.warning.icon, "exclamationmark.triangle")
        XCTAssertEqual(Toast.Kind.error.icon, "xmark.octagon")
    }

    func testKindLabels() {
        XCTAssertEqual(Toast.Kind.info.label, "INFO")
        XCTAssertEqual(Toast.Kind.success.label, "OK")
        XCTAssertEqual(Toast.Kind.warning.label, "WARN")
        XCTAssertEqual(Toast.Kind.error.label, "ERROR")
    }

    func testKindHasDistinctColors() {
        let colors = [
            Toast.Kind.info.color,
            Toast.Kind.success.color,
            Toast.Kind.warning.color,
            Toast.Kind.error.color,
        ]
        // 4 个语义色应该都不一样
        XCTAssertEqual(Set(colors.map { "\($0)" }).count, 4)
    }
}
