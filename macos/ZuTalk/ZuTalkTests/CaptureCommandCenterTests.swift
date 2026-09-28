import XCTest
@testable import ZuTalk

@MainActor
final class CaptureCommandCenterTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "CaptureCommandCenterTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeCenter() -> CaptureCommandCenter {
        CaptureCommandCenter(defaults: defaults, coreProvider: { nil }, inviteReady: { false })
    }

    /// Nobody has chosen yet and nothing is set up to provide captions, so a
    /// recording stays on this Mac.
    func testCaptionsStartOffWithoutAWayToGetThem() {
        let center = makeCenter()
        XCTAssertFalse(center.realtimeCaptionsEnabled)
        XCTAssertFalse(center.nextRecordingUsesCaptions)
    }

    /// The choice beside the Record button is remembered for the next one.
    func testTheCaptionsChoiceIsRemembered() {
        makeCenter().setRealtimeCaptionsEnabled(true)
        XCTAssertTrue(makeCenter().realtimeCaptionsEnabled)
        makeCenter().setRealtimeCaptionsEnabled(false)
        XCTAssertFalse(makeCenter().realtimeCaptionsEnabled)
    }

    /// Wanting captions is not enough: without a key or an invite the
    /// recording records locally rather than failing to start.
    func testCaptionsNeedACredentialToBeUsed() {
        let center = makeCenter()
        center.setRealtimeCaptionsEnabled(true)
        XCTAssertFalse(center.realtimeCredentialAvailable)
        XCTAssertFalse(center.nextRecordingUsesCaptions)
    }

    func testNothingToPauseOrStopWithoutARecording() {
        let center = makeCenter()
        XCTAssertFalse(center.canPause)
        XCTAssertFalse(center.canStop)
    }

    func testClockReadsMinutesAndHours() {
        XCTAssertEqual(CaptureCommandCenter.clock(0), "00:00")
        XCTAssertEqual(CaptureCommandCenter.clock(754), "12:34")
        XCTAssertEqual(CaptureCommandCenter.clock(3_725), "1:02:05")
    }

    /// Settings lists what is actually registered — it used to promise font
    /// shortcuts that did nothing and describe ⌃⌥R as "open".
    func testShortcutListMatchesTheRegisteredShortcuts() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ZuTalk", isDirectory: true)
        let settings = try String(
            contentsOf: root.appendingPathComponent("Settings/FullSettingsView.swift"),
            encoding: .utf8
        )
        let hotKeys = try String(
            contentsOf: root.appendingPathComponent("App/HotKeyManager.swift"),
            encoding: .utf8
        )
        for key in ["kVK_ANSI_R", "kVK_ANSI_P", "kVK_ANSI_S"] {
            XCTAssertTrue(hotKeys.contains(key), "\(key) is registered")
        }
        for keys in ["⌃⌥R", "⌃⌥P", "⌃⌥S"] {
            XCTAssertTrue(settings.contains("keys: \"\(keys)\""), "\(keys) is listed")
        }
        XCTAssertFalse(settings.contains("settings.shortcuts.font_bigger"))
        XCTAssertFalse(settings.contains("settings.shortcuts.font_smaller"))
    }
}
