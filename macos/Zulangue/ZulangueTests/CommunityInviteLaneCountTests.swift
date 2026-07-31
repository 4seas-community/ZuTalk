import XCTest
@testable import Zulangue

/// Invite billing charges per Soniox lane. This mapping must mirror the Rust
/// core's `remote_stream_plan`: one or two languages share a single stream,
/// three or more open one canonical lane plus one translation lane per
/// selected language.
@MainActor
final class CommunityInviteLaneCountTests: XCTestCase {
    func testOneOrTwoLanguagesUseSingleLane() {
        XCTAssertEqual(NotebookCaptureToolbar.remoteLaneCount(selectedLanguages: ["en"]), 1)
        XCTAssertEqual(
            NotebookCaptureToolbar.remoteLaneCount(selectedLanguages: ["en", "th"]),
            1
        )
    }

    func testThreeOrMoreLanguagesOpenCanonicalPlusPerLanguageLanes() {
        XCTAssertEqual(
            NotebookCaptureToolbar.remoteLaneCount(selectedLanguages: ["en", "th", "zh"]),
            4
        )
        XCTAssertEqual(
            NotebookCaptureToolbar.remoteLaneCount(selectedLanguages: ["en", "th", "zh", "ja"]),
            5
        )
    }
}
