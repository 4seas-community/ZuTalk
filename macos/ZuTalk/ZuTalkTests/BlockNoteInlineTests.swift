// BlockNoteInlineTests.swift
// 行内标记识别的规格。
//
// 内联标记是渲染期的解释:文本里存的始终是带记号的原文,识别错了不会
// 丢数据,但会让整行变成一片错色。这层因此按"宁可不认,不可乱认"来测。

import AppKit
import XCTest
@testable import ZuTalk

final class BlockNoteInlineTests: XCTestCase {
    private func marks(_ text: String) -> [BlockNoteInline.Span.Mark] {
        BlockNoteInline.spans(in: text).map(\.mark)
    }

    private func contents(_ text: String) -> [String] {
        let ns = text as NSString
        return BlockNoteInline.spans(in: text).map { ns.substring(with: $0.contentRange) }
    }

    func testRecognisesEachMarkAndKeepsItsContent() {
        XCTAssertEqual(marks("**粗**"), [.bold])
        XCTAssertEqual(contents("**粗**"), ["粗"])
        XCTAssertEqual(marks("*斜*"), [.italic])
        XCTAssertEqual(marks("`码`"), [.code])
        XCTAssertEqual(contents("说 `let x = 1` 就好"), ["let x = 1"])
    }

    func testBoldWinsOverItalicRatherThanSplittingIt() {
        // `*斜*` 的模式若不排除相邻星号,会从 `**粗**` 里抢走一半,
        // 于是一行粗体渲染成半个斜体加两个游离星号。
        XCTAssertEqual(marks("**粗**"), [.bold])
        XCTAssertEqual(marks("**粗** 与 *斜*"), [.bold, .italic])
    }

    func testLinkCarriesItsUrlAndOnlyLabelIsContent() {
        let spans = BlockNoteInline.spans(in: "见 [文档](https://example.com) 一节")
        XCTAssertEqual(spans.count, 1)
        guard case .link(let url) = spans[0].mark else { return XCTFail("应识别为链接") }
        XCTAssertEqual(url, "https://example.com")
        XCTAssertEqual(("见 [文档](https://example.com) 一节" as NSString)
            .substring(with: spans[0].contentRange), "文档")
    }

    /// 笔记里的一段文字不该能拼出 file:// 或自定义 scheme 去触发别的
    /// 程序。非 http(s) 的链接仍然上色,但不挂可点的 .link 属性。
    func testOnlyHttpSchemesBecomeClickable() {
        let attributed = NSMutableAttributedString(string: "[打开](file:///etc/passwd)")
        BlockNoteInline.apply(
            to: attributed,
            lineText: attributed.string,
            offset: 0,
            baseFont: .systemFont(ofSize: 13)
        )
        var found = false
        attributed.enumerateAttribute(
            .link,
            in: NSRange(location: 0, length: attributed.length)
        ) { value, _, _ in
            if value != nil { found = true }
        }
        XCTAssertFalse(found, "非 http(s) 的链接不得可点")
    }

    func testMentionNeedsAWordBoundarySoEmailIsNotAMention() {
        XCTAssertEqual(marks("@项飙 说"), [.mention])
        XCTAssertEqual(marks("行首@李四"), [], "紧贴在字后面的 @ 不是提及")
        let address = "a" + "@" + "example.com" // 拼接:字面邮箱会触发隐私门禁
        XCTAssertEqual(marks("写信到 \(address)"), [], "邮箱地址不是提及")
    }

    func testPlainTextProducesNoSpans() {
        XCTAssertTrue(BlockNoteInline.spans(in: "普通的一行笔记,没有任何记号").isEmpty)
        XCTAssertTrue(BlockNoteInline.spans(in: "2 * 3 * 4 的乘法").isEmpty, "游离星号不成对不算标记")
    }

    /// 记号字符必须留在文本里:隐藏它们会让字符流与存储文本不再 1:1,
    /// 选区长度与复制内容随之全部要补偿。
    func testStylingNeverChangesTheCharacterStream() {
        let source = "**粗** `码` [链](https://a.b) @人"
        let attributed = NSMutableAttributedString(string: source)
        BlockNoteInline.apply(
            to: attributed,
            lineText: source,
            offset: 0,
            baseFont: .systemFont(ofSize: 13)
        )
        XCTAssertEqual(attributed.string, source, "上色不得增删任何字符")
    }
}
