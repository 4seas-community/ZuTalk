import XCTest
@testable import ZuTalk

/// A stand-in core that records what the app asked for and hands back marks
/// the test controls. The behaviours worth pinning here are all about *when*
/// the app talks to the core, which a real core would hide.
private final class MarkCoreSpy: @unchecked Sendable {
    var marks: [String: [FfiSessionMark]] = [:]
    var listCallCount = 0
    var createdAtMs: [UInt64?] = []
    var failNextList = false

    func mark(
        id: String,
        sessionId: String = "s1",
        atMs: UInt64 = 10_000,
        startMs: UInt64 = 4_000,
        endMs: UInt64 = 12_000,
        note: String = "",
        excerpt: [FfiSessionMarkLine] = [],
        digest: FfiMarkDigest? = nil
    ) -> FfiSessionMark {
        FfiSessionMark(
            id: id,
            sessionId: sessionId,
            atMs: atMs,
            startMs: startMs,
            endMs: endMs,
            endIsAuto: true,
            note: note,
            createdAt: "2026-08-28T12:00:00Z",
            updatedAt: "2026-08-28T12:00:00Z",
            excerpt: excerpt,
            digest: digest
        )
    }

    func digest(
        text: String = "这才是问题的核心。",
        isCurrent: Bool = true,
        failed: Bool = false
    ) -> FfiMarkDigest {
        FfiMarkDigest(
            text: text,
            language: "zh-Hans",
            isCurrent: isCurrent,
            failed: failed,
            error: failed ? "service unavailable" : nil
        )
    }

    func line(
        id: String = "u1",
        source: String = "and that is the crux of it",
        translated: String? = nil
    ) -> FfiSessionMarkLine {
        FfiSessionMarkLine(
            utteranceId: id,
            speakerId: nil,
            sourceLanguage: "en",
            sourceText: source,
            translatedLanguage: translated == nil ? nil : "zh",
            translatedText: translated,
            startMs: 4_000,
            endMs: 8_000
        )
    }
}

@MainActor
final class SessionMarkStoreTests: XCTestCase {

    /// The excerpt is what the listener was reading in the room. In a language
    /// they do not follow that is the translation, with the original kept
    /// underneath for afterward.
    func testTranslatedLineLeadsWithWhatTheListenerWasReading() {
        let spy = MarkCoreSpy()
        let translated = SessionMarkLineViewModel(
            spy.line(source: "and that is the crux of it", translated: "这才是问题的核心")
        )
        XCTAssertEqual(translated.primaryText, "这才是问题的核心")
        XCTAssertEqual(translated.secondaryText, "and that is the crux of it")

        // A language the listener follows has no translation lane; the source
        // is the text, and there is nothing to show twice.
        let untranslated = SessionMarkLineViewModel(spy.line(translated: nil))
        XCTAssertEqual(untranslated.primaryText, "and that is the crux of it")
        XCTAssertNil(untranslated.secondaryText)
    }

    /// A listener refers to a moment as "around twelve minutes in", so that is
    /// what the card shows — and an hour-long recording must not read `72:14`.
    func testClockLabelStaysReadablePastAnHour() {
        XCTAssertEqual(SessionMarkViewModel.clockLabel(0), "0:00")
        XCTAssertEqual(SessionMarkViewModel.clockLabel(9_000), "0:09")
        XCTAssertEqual(SessionMarkViewModel.clockLabel(734_000), "12:14")
        XCTAssertEqual(SessionMarkViewModel.clockLabel(4_334_000), "1:12:14")
    }

    /// Marks arrive along the recording, not in the order they were written.
    /// Widening an early mark's bounds must not send it to the bottom of the
    /// rail, where the listener would have to hunt for what they just edited.
    func testMarksStayInCaptureOrderAfterAnEdit() {
        let spy = MarkCoreSpy()
        let rail = [
            SessionMarkViewModel(spy.mark(id: "early", atMs: 10_000, startMs: 4_000)),
            SessionMarkViewModel(spy.mark(id: "late", atMs: 60_000, startMs: 50_000)),
        ]

        let withMiddle = SessionMarkStore.ordered(
            rail,
            upserting: SessionMarkViewModel(spy.mark(id: "middle", atMs: 30_000))
        )
        XCTAssertEqual(withMiddle.map(\.id), ["early", "middle", "late"])

        let afterDrag = SessionMarkStore.ordered(
            rail,
            upserting: SessionMarkViewModel(spy.mark(id: "early", atMs: 10_000, startMs: 0))
        )
        XCTAssertEqual(
            afterDrag.map(\.id), ["early", "late"],
            "an edited mark keeps its place rather than being appended again"
        )
        XCTAssertEqual(afterDrag.count, 2, "an upsert must not duplicate the row")
        XCTAssertEqual(afterDrag[0].startMs, 0, "and it carries the new bounds")
    }

    /// Rebuilding an excerpt costs a full transcript read, which in a long
    /// recording is thousands of rows. Only a mark dropped moments ago can
    /// still be waiting on a partial to finalize; getting this wrong in the
    /// permissive direction means that read every two seconds for an hour.
    func testExcerptsStopRefreshingOnceTheyHaveSettled() {
        let now = Date()

        XCTAssertFalse(
            SessionMarkStore.isSettling(lastMarkAt: nil, now: now),
            "nothing dropped, nothing to wait on"
        )
        XCTAssertTrue(
            SessionMarkStore.isSettling(lastMarkAt: now.addingTimeInterval(-1), now: now),
            "a mark from a second ago may still be holding a partial"
        )
        XCTAssertFalse(
            SessionMarkStore.isSettling(
                lastMarkAt: now.addingTimeInterval(-(SessionMarkStore.settlingWindow + 1)),
                now: now
            ),
            "past the window the rail stops paying for reads"
        )
    }

    /// A card carries the readable passage when one came back, and stays
    /// perfectly usable when none did — assistance off, nothing run yet, or a
    /// passage too short to be worth sending all look the same from here, and
    /// all of them are fine.
    func testACardWorksWithAndWithoutACleanedUpPassage() {
        let spy = MarkCoreSpy()

        let bare = SessionMarkViewModel(spy.mark(id: "m1", excerpt: [spy.line()]))
        XCTAssertNil(bare.digest)
        XCTAssertFalse(bare.isEmptyExcerpt, "the raw passage is never wrong, only harder to read")

        let cleaned = SessionMarkViewModel(
            spy.mark(id: "m2", excerpt: [spy.line()], digest: spy.digest())
        )
        XCTAssertEqual(cleaned.digest?.text, "这才是问题的核心。")
        XCTAssertEqual(cleaned.digest?.isCurrent, true)
        XCTAssertEqual(cleaned.digest?.failed, false)
    }

    /// Stale text is kept and labelled rather than hidden: it still describes
    /// most of the passage, and blanking the card would lose something the
    /// listener could still use.
    func testStaleAndFailedPassagesStayVisible() {
        let spy = MarkCoreSpy()

        let stale = SessionMarkViewModel(
            spy.mark(id: "m1", excerpt: [spy.line()], digest: spy.digest(isCurrent: false))
        )
        XCTAssertEqual(stale.digest?.isCurrent, false)
        XCTAssertFalse(stale.digest!.text.isEmpty, "stale is labelled, not erased")

        let failed = SessionMarkViewModel(
            spy.mark(
                id: "m2",
                excerpt: [spy.line()],
                digest: spy.digest(text: "", failed: true)
            )
        )
        XCTAssertEqual(failed.digest?.failed, true)
        XCTAssertNotNil(failed.digest?.error, "a failure the listener can see is one they can retry")
        XCTAssertFalse(failed.isEmptyExcerpt, "and the raw passage is still there underneath")
    }

    /// Off has to be the default. A setting that sends content before anyone
    /// chose it is not a setting anyone consented to.
    func testAssistanceIsOffUntilItIsTurnedOn() {
        let defaults = UserDefaults(suiteName: "zutalk.tests.\(UUID().uuidString)")!
        var pushed: [Bool] = []
        let store = LanguageModelAssistanceStore(defaults: defaults, coreProvider: { nil })

        XCTAssertFalse(store.isEnabled)

        store.setEnabled(true)
        XCTAssertTrue(store.isEnabled)
        XCTAssertTrue(defaults.bool(forKey: "ai.assistance.enabled"))

        // A fresh store on the same defaults remembers, which is what makes
        // the launch-time push to the core meaningful.
        let relaunched = LanguageModelAssistanceStore(defaults: defaults, coreProvider: { nil })
        XCTAssertTrue(relaunched.isEnabled)
        _ = pushed
    }

    /// Every string the rail shows must exist in the catalog; a missing key
    /// renders as the key itself, which reads as a bug to the user.
    func testMarkStringsAreLocalized() {
        for key in [
            "session.marks.title",
            "session.marks.add",
            "session.marks.add.hint",
            "session.marks.delete",
            "session.marks.note.placeholder",
            "session.marks.excerpt.silent",
            "session.marks.empty.live",
            "session.marks.empty.done",
            "session.marks.digest.stale",
            "session.marks.digest.show_original",
            "session.marks.digest.hide_original",
            "session.marks.digest.failed",
            "settings.services.model.enable",
            "settings.services.model.enable_detail",
        ] {
            let value = Bundle.main.localizedString(forKey: key, value: nil, table: nil)
            XCTAssertNotEqual(value, key, "missing localization for \(key)")
            XCTAssertFalse(value.isEmpty, "empty localization for \(key)")
        }
    }
}
