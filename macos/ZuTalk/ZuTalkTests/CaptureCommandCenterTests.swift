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

    /// Watching someone else's share and recording can't run together. Every
    /// way to start a recording asks first, and saying no starts nothing.
    func testDecliningToLeaveASharedLiveStartsNothing() async {
        var asked = 0
        let center = CaptureCommandCenter(
            defaults: defaults,
            coreProvider: { nil },
            inviteReady: { false },
            leaveWatchingToRecord: {
                asked += 1
                return false
            }
        )
        let started = await center.startNow(
            notebookId: "nb-watching",
            profileEditor: NotebookCaptureProfileEditorModel(notebookId: "nb-watching")
        )
        XCTAssertFalse(started)
        XCTAssertEqual(asked, 1)
        XCTAssertFalse(center.isStarting)
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

@MainActor
final class CaptureCaptionsDefaultTests: XCTestCase {
    /// Keys are restored after launch. Before anyone chooses, the default
    /// follows them as they appear instead of freezing at "off".
    func testTheDefaultFollowsCredentialsUntilSomeoneChooses() {
        let suiteName = "CaptureCaptionsDefaultTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var inviteReady = false
        let center = CaptureCommandCenter(
            defaults: defaults,
            coreProvider: { nil },
            inviteReady: { inviteReady }
        )
        XCTAssertFalse(center.realtimeCaptionsEnabled)

        inviteReady = true
        XCTAssertTrue(center.realtimeCaptionsEnabled)
        XCTAssertTrue(center.nextRecordingUsesCaptions)

        center.setRealtimeCaptionsEnabled(false)
        XCTAssertFalse(center.realtimeCaptionsEnabled, "an explicit choice wins")
        XCTAssertFalse(center.nextRecordingUsesCaptions)
    }
}
