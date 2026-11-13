import Combine
import XCTest
@testable import ZuTalk

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

// MARK: - HostMode
//
// Lives here because the test target lists its files by hand; see
// docs/product/interface-layers.md for what the switch is.

@MainActor
final class HostModeTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "HostModeTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    func testUntouchedSwitchFollowsCitySignIn() {
        let signedIn = CurrentValueSubject<Bool, Never>(false)
        let mode = HostMode(
            defaults: defaults,
            initiallySignedIn: false,
            signedIn: signedIn.eraseToAnyPublisher()
        )
        XCTAssertFalse(mode.isOn)

        signedIn.send(true)
        XCTAssertTrue(mode.isOn, "signing in to a city turns hosting tools on until the person decides otherwise")

        signedIn.send(false)
        XCTAssertFalse(mode.isOn)
    }

    func testAChoiceOutlivesSignInChangesAndRelaunch() {
        let signedIn = CurrentValueSubject<Bool, Never>(true)
        let mode = HostMode(
            defaults: defaults,
            initiallySignedIn: true,
            signedIn: signedIn.eraseToAnyPublisher()
        )
        mode.set(false)
        XCTAssertFalse(mode.isOn, "the person's own choice wins over the default")

        signedIn.send(false)
        signedIn.send(true)
        XCTAssertFalse(mode.isOn)

        let relaunched = HostMode(
            defaults: defaults,
            initiallySignedIn: true,
            signedIn: signedIn.eraseToAnyPublisher()
        )
        XCTAssertFalse(relaunched.isOn)
        XCTAssertEqual(relaunched.choice, false)
    }

    func testSomethingInUseStaysVisibleWithTheSwitchOff() {
        let mode = HostMode(
            defaults: defaults,
            initiallySignedIn: false,
            signedIn: Just(false).eraseToAnyPublisher()
        )
        XCTAssertFalse(mode.shows(inUse: false))
        XCTAssertTrue(mode.shows(inUse: true), "a live share in progress keeps its button")

        mode.set(true)
        XCTAssertTrue(mode.shows(inUse: false))
    }
}

// MARK: - RecordingBarFit

@MainActor
final class RecordingBarFitTests: XCTestCase {
    func testTheBarKeepsItsLabelsExactlyWhenTheyFit() {
        // Nothing recording, or not measured yet: no reason to drop labels.
        XCTAssertFalse(RecordingBarFit.isCompact(fullWidth: 0, available: 0))
        XCTAssertFalse(RecordingBarFit.isCompact(fullWidth: 520, available: 520))
        XCTAssertTrue(RecordingBarFit.isCompact(fullWidth: 521, available: 520))
    }

    func testAWideBarInALongLanguageGoesCompactWhereAShortOneDoesNot() {
        // A 1100 pt header: the Chinese bar (about 520 pt) keeps its
        // labels; a host's German bar (about 1120 pt) cannot.
        let available = RecordingBarFit.available(headerWidth: 1100)
        XCTAssertEqual(available, 1100 - RecordingBarFit.pathReserve)
        XCTAssertFalse(RecordingBarFit.isCompact(fullWidth: 520, available: available))
        XCTAssertTrue(RecordingBarFit.isCompact(fullWidth: 1120, available: available))
    }

    func testAHeaderNarrowerThanThePathReserveLeavesNothing() {
        XCTAssertEqual(RecordingBarFit.available(headerWidth: 200), 0)
        XCTAssertTrue(RecordingBarFit.isCompact(fullWidth: 300, available: 0))
    }
}
