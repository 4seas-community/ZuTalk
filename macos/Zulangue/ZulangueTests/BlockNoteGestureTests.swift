// BlockNoteGestureTests.swift
// 大纲编辑器 v2 手势的纯运算规格:并块与子树拖拽。
//
// 两个手势各自严守蓝本约束(删行与跨删除位移动不混在一次重放):
// 并块 = 删除 + 文本更新;拖拽 = 移动 + 深度更新。这里测的是索引与
// 深度运算本身;整份重放的引擎行为由 Rust 侧测试覆盖。

import XCTest
@testable import Zulangue

@MainActor
final class BlockNoteGestureTests: XCTestCase {
    private func row(_ id: String, _ depth: UInt32, _ text: String = "") -> FfiOutlineRow {
        FfiOutlineRow(id: id, depth: depth, text: text)
    }

    // MARK: - 并块(行首/空行退格)

    func testMergeAppendsDraftToPreviousRowAndRemovesTheRow() {
        let rows = [row("a", 0, "甲"), row("b", 0, "乙")]
        let (next, previousId) = BlockNoteStore.mergedRows(rows, rowId: "b", draftText: "乙草稿")!
        XCTAssertEqual(previousId, "a")
        XCTAssertEqual(next.map(\.id), ["a"])
        XCTAssertEqual(next[0].text, "甲乙草稿", "并块拼接的是未提交的草稿,不是旧权威文本")
    }

    func testMergeOfEmptyRowIsAPureDeletion() {
        let rows = [row("a", 0, "甲"), row("b", 0, "")]
        let (next, _) = BlockNoteStore.mergedRows(rows, rowId: "b", draftText: "")!
        XCTAssertEqual(next.count, 1)
        XCTAssertEqual(next[0].text, "甲", "空行并块不改上一行文本")
    }

    func testMergeOnFirstRowIsRefused() {
        let rows = [row("a", 0, "甲"), row("b", 0, "乙")]
        XCTAssertNil(BlockNoteStore.mergedRows(rows, rowId: "a", draftText: "x"))
        XCTAssertNil(BlockNoteStore.mergedRows(rows, rowId: "ghost", draftText: "x"))
    }

    func testMergeKeepsDeeperFollowersForReparentingByDepth() {
        // 扁平深度模型:被并行的子行留在原地,重建树时自然过继给前面的浅行。
        let rows = [row("a", 0), row("b", 0, "乙"), row("b1", 1, "乙一")]
        let (next, _) = BlockNoteStore.mergedRows(rows, rowId: "b", draftText: "乙")!
        XCTAssertEqual(next.map(\.id), ["a", "b1"])
        XCTAssertEqual(next[1].depth, 1, "子行深度不动,过继由重建树完成")
    }

    // MARK: - 子树范围

    func testSubtreeRangeSpansContiguousDeeperRows() {
        let rows = [row("a", 0), row("a1", 1), row("a1x", 2), row("b", 0)]
        XCTAssertEqual(BlockNoteStore.subtreeRange(in: rows, of: "a"), 0..<3)
        XCTAssertEqual(BlockNoteStore.subtreeRange(in: rows, of: "a1"), 1..<3)
        XCTAssertEqual(BlockNoteStore.subtreeRange(in: rows, of: "b"), 3..<4)
    }

    // MARK: - 拖拽重排

    func testMoveCarriesTheWholeSubtree() {
        let rows = [row("a", 0), row("a1", 1), row("b", 0), row("c", 0)]
        let next = BlockNoteStore.movedRows(rows, subtreeOf: "a", before: "c")!
        XCTAssertEqual(next.map(\.id), ["b", "a", "a1", "c"], "子树随行整体移动")
        XCTAssertEqual(next.map(\.depth), [0, 0, 1, 0], "组内相对深度不变")
    }

    func testMoveToTailAndBackward() {
        let rows = [row("a", 0), row("b", 0), row("c", 0)]
        XCTAssertEqual(
            BlockNoteStore.movedRows(rows, subtreeOf: "a", before: nil)!.map(\.id),
            ["b", "c", "a"]
        )
        XCTAssertEqual(
            BlockNoteStore.movedRows(rows, subtreeOf: "c", before: "a")!.map(\.id),
            ["c", "a", "b"]
        )
    }

    func testDropInsideOwnSubtreeOrInPlaceIsANoOp() {
        let rows = [row("a", 0), row("a1", 1), row("a1x", 2), row("b", 0)]
        XCTAssertNil(BlockNoteStore.movedRows(rows, subtreeOf: "a", before: "a1"), "拖进自己拆散子树,拒绝")
        XCTAssertNil(BlockNoteStore.movedRows(rows, subtreeOf: "a", before: "a1x"))
        XCTAssertNil(BlockNoteStore.movedRows(rows, subtreeOf: "a", before: "b"), "紧贴子树尾 = 原位")
        XCTAssertNil(BlockNoteStore.movedRows(rows, subtreeOf: "b", before: nil), "末行移到末尾 = 原位")
    }

    func testMoveClampsBaseDepthWithoutFlatteningTheSubtree() {
        // a2(深度 2,带深度 3 子行)拖到顶部:顶部上限是 0,整组平移 2 级。
        let rows = [row("r", 0), row("r1", 1), row("a2", 2), row("a3", 3)]
        let next = BlockNoteStore.movedRows(rows, subtreeOf: "a2", before: "r")!
        XCTAssertEqual(next.map(\.id), ["a2", "a3", "r", "r1"])
        XCTAssertEqual(next[0].depth, 0, "首位没有上一行,基准收到 0")
        XCTAssertEqual(next[1].depth, 1, "子行随组平移,相对结构不压平")
    }

    func testMoveKeepsDepthWhenDestinationAllowsIt() {
        let rows = [row("a", 0), row("a1", 1), row("b", 0), row("b1", 1)]
        // b1(深度 1)拖到 a1 之前:上一行是 a(深度 0),上限 1,深度保持。
        let next = BlockNoteStore.movedRows(rows, subtreeOf: "b1", before: "a1")!
        XCTAssertEqual(next.map(\.id), ["a", "b1", "a1", "b"])
        XCTAssertEqual(next[1].depth, 1)
    }
}
