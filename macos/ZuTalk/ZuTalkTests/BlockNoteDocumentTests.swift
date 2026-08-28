// BlockNoteDocumentTests.swift
// 行 ↔ 富文本映射的规格。
//
// 统一文本编辑面把行变成了段落,这层映射因此是编辑器的地基:任何一次
// 输入都要经过"派生回行"这条路,映射错一次就是内容丢一次。

import AppKit
import XCTest
@testable import ZuTalk

@MainActor
final class BlockNoteDocumentTests: XCTestCase {
    private func row(
        _ id: String,
        _ depth: UInt32,
        _ text: String,
        _ kind: FfiOutlineKind = .paragraph,
        checked: Bool = false
    ) -> FfiOutlineRow {
        FfiOutlineRow(id: id, depth: depth, text: text, kind: kind, checked: checked)
    }

    func testRoundTripPreservesTextDepthKindAndChecked() {
        let rows = [
            row("a", 0, "标题", .heading1),
            row("b", 1, "正文"),
            row("c", 2, "待办", .task, checked: true),
            row("d", 0, "引用", .quote),
        ]
        let derived = BlockNoteDocument.rows(from: BlockNoteDocument.attributedString(rows: rows))
        XCTAssertEqual(derived.map(\.text), ["标题", "正文", "待办", "引用"])
        XCTAssertEqual(derived.map(\.depth), [0, 1, 2, 0])
        XCTAssertEqual(derived.map(\.kind), [.heading1, .paragraph, .task, .quote])
        XCTAssertEqual(derived.map(\.checked), [false, false, true, false])
        XCTAssertEqual(derived.map(\.id), ["a", "b", "c", "d"], "行身份必须原样带过")
    }

    func testDividerKeepsItsBlockAndCarriesNoText() {
        let rows = [row("a", 0, "上"), row("d", 0, "", .divider), row("b", 0, "下")]
        let derived = BlockNoteDocument.rows(from: BlockNoteDocument.attributedString(rows: rows))
        XCTAssertEqual(derived.map(\.kind), [.paragraph, .divider, .paragraph])
        XCTAssertEqual(derived[1].text, "", "分隔线的占位字形不是内容")
    }

    func testEmptyRowsSurviveTheRoundTrip() {
        let rows = [row("a", 0, "甲"), row("b", 0, ""), row("c", 0, "乙")]
        let derived = BlockNoteDocument.rows(from: BlockNoteDocument.attributedString(rows: rows))
        XCTAssertEqual(derived.map(\.text), ["甲", "", "乙"], "空行是真实的一行")
    }

    /// 系统路径(粘贴、换行插入)可能把一个段落拆成两段并复制其属性。
    /// 重复的行 id 会让 CRDT 把两行认成同一行,派生必须换新 id。
    func testDuplicatedRowIdsAreReissued() {
        let attributed = NSMutableAttributedString()
        let source = row("dup", 0, "甲")
        attributed.append(BlockNoteDocument.attributedParagraph(for: source, isLast: false))
        attributed.append(BlockNoteDocument.attributedParagraph(for: source, isLast: true))
        let derived = BlockNoteDocument.rows(from: attributed)
        XCTAssertEqual(derived.count, 2)
        XCTAssertNotEqual(derived[0].id, derived[1].id, "拆出来的第二段必须换新身份")
    }

    /// 没有块属性的纯文本(从别处拖进来的一段字)不能凭空消失,
    /// 也不能把整篇的深度带歪。
    func testUnattributedTextBecomesParagraphsInheritingDepth() {
        let attributed = NSMutableAttributedString()
        attributed.append(BlockNoteDocument.attributedParagraph(
            for: row("a", 2, "深"),
            isLast: false
        ))
        attributed.append(NSAttributedString(string: "裸文本"))
        let derived = BlockNoteDocument.rows(from: attributed)
        XCTAssertEqual(derived.count, 2)
        XCTAssertEqual(derived[1].text, "裸文本")
        XCTAssertEqual(derived[1].kind, .paragraph)
        XCTAssertEqual(derived[1].depth, 2, "缺属性的段落继承上一行深度")
    }

    func testMarkdownSerializationCarriesMarkersAndIndent() {
        let rows = [
            row("a", 0, "标题", .heading2),
            row("b", 1, "待办", .task),
            row("c", 1, "已办", .task, checked: true),
            row("d", 0, "", .divider),
            row("e", 2, "引用", .quote),
        ]
        XCTAssertEqual(
            BlockNoteDocument.markdownText(for: rows),
            "## 标题\n  - [ ] 待办\n  - [x] 已办\n---\n    > 引用"
        )
    }

    func testCodeBlockRoundTripsAndKeepsMarkersLiteral() {
        let rows = [row("c", 0, "let x = **not bold**", .code)]
        let derived = BlockNoteDocument.rows(from: BlockNoteDocument.attributedString(rows: rows))
        XCTAssertEqual(derived[0].kind, .code)
        XCTAssertEqual(
            derived[0].text,
            "let x = **not bold**",
            "代码块里的记号是字面量,不是内联标记"
        )
    }

    func testCodeBlockSerializesWithAFence() {
        XCTAssertEqual(
            BlockNoteDocument.markdownText(for: [row("c", 0, "print(1)", .code)]),
            "```print(1)"
        )
    }

    /// 蓝本(macro)的 `paragraph` 主题类里没有任何记号:圆点只属于显式的
    /// 列表。我们过去给每一行段落都发一个圆点,于是一篇随手写的笔记读起来
    /// 像一份被拆碎的大纲 —— 这是"笔记"与"大纲"的分界线。
    func testOnlyListLikeKindsReserveAndDrawAMarker() {
        XCTAssertFalse(BlockNoteDocument.drawsMarker(.paragraph), "段落不带记号")
        XCTAssertFalse(BlockNoteDocument.drawsMarker(.heading1))
        XCTAssertFalse(BlockNoteDocument.drawsMarker(.code))
        XCTAssertFalse(BlockNoteDocument.drawsMarker(.divider))
        XCTAssertTrue(BlockNoteDocument.drawsMarker(.bullet))
        XCTAssertTrue(BlockNoteDocument.drawsMarker(.task))
        XCTAssertTrue(BlockNoteDocument.drawsMarker(.quote))
    }

    /// 不画记号的类型也不该预留记号栏:一段普通文字要从写作栏左缘开始,
    /// 而不是永远缩在一个空记号位后面。
    func testParagraphsStartAtTheWritingMarginWhileListsReserveTheGutter() {
        let paragraph = BlockNoteDocument.paragraphStyle(for: row("p", 0, "文字"))
        let bullet = BlockNoteDocument.paragraphStyle(for: row("b", 0, "条目", .bullet))
        XCTAssertEqual(paragraph.firstLineHeadIndent, 0)
        XCTAssertEqual(bullet.firstLineHeadIndent, BlockNoteDocument.markerWidth)
        XCTAssertEqual(
            paragraph.headIndent, paragraph.firstLineHeadIndent,
            "折行要与首行对齐"
        )
    }

    /// 层级靠缩进,不靠换记号形状 —— 深一层就换个空心圈会把一份清单读成
    /// 两种东西。
    func testDepthChangesIndentNotMarkerShape() {
        let shallow = BlockNoteDocument.paragraphStyle(for: row("a", 0, "浅", .bullet))
        let deep = BlockNoteDocument.paragraphStyle(for: row("b", 2, "深", .bullet))
        XCTAssertEqual(
            deep.firstLineHeadIndent - shallow.firstLineHeadIndent,
            BlockNoteDocument.indentStep * 2
        )
    }

    /// `- ` 是清单的入口,而两条任务规则必须排在它之前,否则 `- [ ] `
    /// 会先被 `- ` 吃掉,复选框永远打不出来。
    func testDashMakesABulletWhileCheckboxRulesStillWinFirst() {
        XCTAssertEqual(BlockNoteStore.markdownPrefix("- 一件事")?.kind, .bullet)
        XCTAssertEqual(BlockNoteStore.markdownPrefix("* 一件事")?.kind, .bullet)
        let task = BlockNoteStore.markdownPrefix("- [ ] 待办")
        XCTAssertEqual(task?.kind, .task)
        XCTAssertEqual(task?.rest, "待办")
        XCTAssertEqual(BlockNoteStore.markdownPrefix("- [x] 已办")?.checked, true)
    }

    /// 迁移的实况:0.5.5 之前所有的行都存成段落,升级后它们不再显示圆点。
    /// 文字一个字都不变 —— 这是把"每行强制成条目"这个错误默认修正回来,
    /// 不是数据损失。
    func testExistingParagraphsKeepTheirTextAndSimplyLoseTheDot() {
        let stored = [row("a", 0, "会上说的第一件事"), row("b", 1, "补充")]
        let derived = BlockNoteDocument.rows(from: BlockNoteDocument.attributedString(rows: stored))
        XCTAssertEqual(derived.map(\.text), ["会上说的第一件事", "补充"])
        XCTAssertEqual(derived.map(\.kind), [.paragraph, .paragraph])
        XCTAssertEqual(derived.map(\.depth), [0, 1], "缩进层级保留")
    }

    func testKindEncodingIsStableInBothDirections() {
        let kinds: [FfiOutlineKind] = [
            .paragraph, .heading1, .heading2, .heading3, .quote, .task, .divider, .code, .bullet,
        ]
        for kind in kinds {
            let raw = BlockNoteDocument.kindRawValue(kind)
            XCTAssertEqual(BlockNoteDocument.kindFromRawValue(raw), kind)
        }
        XCTAssertNil(BlockNoteDocument.kindFromRawValue(99))
    }
}
