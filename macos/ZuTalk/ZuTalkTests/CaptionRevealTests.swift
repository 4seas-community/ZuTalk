import XCTest
@testable import ZuTalk

/// What a caption card shows is a function of the clock: no step later than
/// its latency budget, and no dependence on how often the screen is drawn.
final class CaptionRevealTests: XCTestCase {
    private let profiles: [(String, CaptionScriptProfile, String)] = [
        ("latin", .latin, "We are collecting recordings like this one so the developers can reproduce it. "),
        ("cjk", .cjk, "关于翻译延迟的问题，我们上个月统计过，平均要等好几秒才能出来。"),
        ("thai", .thai, "ดังนั้นเราจึงทดลองใช้ระบบแปลภาษาแบบเรียลไทม์ ให้ทุกคนเห็นคำบรรยายในภาษาของตัวเอง "),
        ("korean", .korean, "다음 주 모임은 공동체가 함께 결정하는 방법에 집중합니다. "),
    ]

    func testEveryStepAppearsWithinTheLatencyBudgetHoweverTheTextArrives() {
        for (name, profile, sentence) in profiles {
            var plan = CaptionRevealPlan.start(text: "", profile: profile, now: 0, revealed: false)
            var text = ""
            var now = 0.0
            // Mouthfuls of very different sizes, arriving faster and slower
            // than they can be spread.
            for (round, size) in [3, 40, 1, 25, 60, 2, 15, 90].enumerated() {
                let addition = String(repeating: sentence, count: 4).prefix(size)
                text += addition
                now += [0.2, 1.4, 0.05, 2.0][round % 4]
                plan = plan.updated(text: text, now: now)
                XCTAssertEqual(plan.text, text)
                for index in plan.dues.indices {
                    XCTAssertLessThanOrEqual(
                        plan.dues[index] - plan.arrivals[index],
                        profile.latencyBudget + 1e-9,
                        "\(name) step \(index)"
                    )
                    if index > 0 {
                        XCTAssertGreaterThanOrEqual(plan.dues[index], plan.dues[index - 1], "\(name)")
                    }
                }
            }
            XCTAssertEqual(plan.visibleText(at: now + profile.latencyBudget), text, name)
        }
    }

    /// A stalled main thread draws its next frame late. That frame shows
    /// what is due by then — no step is held back for the frames it missed.
    func testALateFrameShowsEverythingDueByThen() {
        let text = String(repeating: "word ", count: 12)
        let plan = CaptionRevealPlan.start(text: text, profile: .latin, now: 10, revealed: false)
        let drawnEveryFrame = stride(from: 10.0, through: 10.8, by: 1.0 / 30).map { plan.visibleText(at: $0) }
        XCTAssertEqual(drawnEveryFrame.last, plan.visibleText(at: 10.8))
        XCTAssertEqual(plan.visibleText(at: 12), text)
        XCTAssertLessThanOrEqual(plan.completesAt, 10 + CaptionScriptProfile.latin.latencyBudget)
    }

    /// One provider mouthful (~15 tokens) is spread over less than the gap
    /// before the next one, for every script.
    func testAMouthfulFinishesBeforeTheNextOneArrives() {
        for (name, profile, sentence) in profiles {
            let plan = CaptionRevealPlan.start(text: sentence, profile: profile, now: 0, revealed: false)
            XCTAssertLessThanOrEqual(plan.completesAt, 1.4, name)
            XCTAssertGreaterThan(plan.dues.count, 3, "\(name) is revealed in steps")
            XCTAssertLessThan(plan.dues.first ?? .infinity, 0.25, "\(name) starts at once")
        }
    }

    func testThaiStepsAreWordsAndKeepEveryMarkOnItsConsonant() {
        let text = "ดังนั้นเราจึงทดลองใช้ระบบแปลภาษาแบบเรียลไทม์ ให้ทุกคนเห็นคำบรรยาย"
        let ends = CaptionScriptProfile.thai.unitEnds(of: text)
        XCTAssertEqual(ends.last, text.utf8.count)
        // Words, not characters: far fewer steps than grapheme clusters.
        XCTAssertLessThan(ends.count, text.count / 3)
        XCTAssertGreaterThan(ends.count, 8)
        var boundaries: Set<Int> = [0]
        var offset = 0
        for character in text {
            offset += character.utf8.count
            boundaries.insert(offset)
        }
        for end in ends {
            XCTAssertTrue(boundaries.contains(end), "step ends inside a grapheme cluster at \(end)")
        }
    }

    func testAnAppendKeepsWhatWasShownAndARewriteShowsTheSurvivingPrefixAtOnce() {
        let plan = CaptionRevealPlan.start(text: "hello there my", profile: .latin, now: 0, revealed: false)
        let shown = plan.visibleText(at: 0.5)
        XCTAssertFalse(shown.isEmpty)

        let appended = plan.updated(text: "hello there my friends", now: 0.5)
        XCTAssertTrue(appended.visibleText(at: 0.5).hasPrefix(shown))

        let rewritten = appended.updated(text: "hello where", now: 0.6)
        let visible = rewritten.visibleText(at: 0.6)
        XCTAssertTrue("hello where".hasPrefix(visible))
        XCTAssertTrue(visible.hasPrefix("hello "))
        XCTAssertEqual(rewritten.visibleText(at: 0.6 + CaptionScriptProfile.latin.latencyBudget), "hello where")
    }

    func testARevealedCardIsWholeImmediately() {
        let plan = CaptionRevealPlan.start(text: "已经说完的话", profile: .cjk, now: 5, revealed: true)
        XCTAssertEqual(plan.visibleText(at: 5), "已经说完的话")
    }

    func testProfilesFollowTheColumnLanguageAndOtherwiseTheScript() {
        XCTAssertEqual(CaptionScriptProfile.forLanguage("th", text: "x"), .thai)
        XCTAssertEqual(CaptionScriptProfile.forLanguage("zh-Hans", text: "x"), .cjk)
        XCTAssertEqual(CaptionScriptProfile.forLanguage("ja", text: "x"), .cjk)
        XCTAssertEqual(CaptionScriptProfile.forLanguage("ko", text: "x"), .korean)
        XCTAssertEqual(CaptionScriptProfile.forLanguage("de", text: "道"), .latin)
        XCTAssertEqual(CaptionScriptProfile.forLanguage(nil, text: "สวัสดีครับ"), .thai)
        XCTAssertEqual(CaptionScriptProfile.forLanguage(nil, text: "你好，世界"), .cjk)
        XCTAssertEqual(CaptionScriptProfile.forLanguage(nil, text: "Hello, world"), .latin)
        XCTAssertEqual(CaptionScriptProfile.forLanguage(nil, text: "Der Begriff 道 im Kontext"), .latin)
    }

    /// Text only grows on screen while the provider only appends: however a
    /// re-segmentation moves word boundaries, nothing already shown is taken
    /// back and shown again.
    func testGrowingTextNeverTakesBackWhatWasShown() {
        for (name, profile, sentence) in profiles {
            let characters = Array(sentence)
            var plan = CaptionRevealPlan.start(text: "", profile: profile, now: 0, revealed: false)
            var now = 0.0
            var shown = ""
            for count in 1...characters.count {
                now += 0.15
                plan = plan.updated(text: String(characters[0..<count]), now: now)
                let visible = plan.visibleText(at: now)
                XCTAssertTrue(
                    visible.hasPrefix(shown),
                    "\(name): at \(count) characters the screen went from '\(shown)' to '\(visible)'"
                )
                XCTAssertEqual(plan.dues, plan.dues.sorted(), "\(name): due times out of order at \(count)")
                shown = visible
            }
        }
    }

    /// A rewrite keeps on screen whatever part of the shown text the new
    /// text still begins with.
    func testARewriteKeepsTheShownTextItStillSays() {
        let edits: [(CaptionScriptProfile, String, String)] = [
            (.latin, "Hello world", "Hello, world"),
            (.latin, "We meet at the hall", "We met at the hall today"),
            (.cjk, "我们明天见。", "我们明天再见。"),
            (.thai, "การประชุมวันนี้", "การประชุมในวันนี้"),
        ]
        for (profile, before, after) in edits {
            let plan = CaptionRevealPlan.start(text: before, profile: profile, now: 0, revealed: false)
            let now = 5.0
            let shown = plan.visibleText(at: now)
            XCTAssertEqual(shown, before)
            let revised = plan.updated(text: after, now: now)
            let shared = String(zip(shown, after).prefix(while: { $0 == $1 }).map(\.0))
            XCTAssertTrue(
                revised.visibleText(at: now).hasPrefix(shared),
                "'\(before)' → '\(after)' showed '\(revised.visibleText(at: now))'"
            )
            XCTAssertEqual(revised.dues, revised.dues.sorted())
        }
    }
}
