// BlockNoteGestureTests.swift
// 大纲编辑器 v2 手势的纯运算规格:并块与子树拖拽。
//
// 两个手势各自严守蓝本约束(删行与跨删除位移动不混在一次重放):
// 并块 = 删除 + 文本更新;拖拽 = 移动 + 深度更新。这里测的是索引与
// 深度运算本身;整份重放的引擎行为由 Rust 侧测试覆盖。

import XCTest
@testable import ZuTalk

@MainActor
final class BlockNoteGestureTests: XCTestCase {
    private func row(_ id: String, _ depth: UInt32, _ text: String = "") -> FfiOutlineRow {
        FfiOutlineRow(id: id, depth: depth, text: text, kind: .paragraph, checked: false)
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

    // MARK: - 拆分(光标处回车)

    func testSplitKeepsHeadAndCarriesTailIntoTheNewRow() {
        let rows = [row("a", 1, "甲乙丙")]
        let (next, newId) = BlockNoteStore.splitRows(rows, rowId: "a", head: "甲", tail: "乙丙")!
        XCTAssertEqual(next.count, 2)
        XCTAssertEqual(next[0].text, "甲")
        XCTAssertEqual(next[1].id, newId)
        XCTAssertEqual(next[1].text, "乙丙", "光标后的文本随拆分进入新行")
        XCTAssertEqual(next[1].depth, 1, "新行继承本行深度")
    }

    func testSplitWithTailKeepsTheRowKindButNotTheCheckedState() {
        var task = row("t", 0, "买菜做饭")
        task.kind = .task
        task.checked = true
        let (next, _) = BlockNoteStore.splitRows([task], rowId: "t", head: "买菜", tail: "做饭")!
        XCTAssertEqual(next[1].kind, .task, "行中拆分延续清单类型")
        XCTAssertFalse(next[1].checked, "半句话不继承已完成")
    }

    func testSplitAtEndDegradesToContinuationKind() {
        var heading = row("h", 0, "标题")
        heading.kind = .heading1
        let (next, _) = BlockNoteStore.splitRows([heading], rowId: "h", head: "标题", tail: "")!
        XCTAssertEqual(next[1].kind, .paragraph, "标题行尾回车接的是正文")
        XCTAssertEqual(next[1].text, "")
    }

    func testSplitOnMissingRowIsRefused() {
        XCTAssertNil(BlockNoteStore.splitRows([row("a", 0)], rowId: "ghost", head: "x", tail: "y"))
    }

    func testEmptySubmitExitsListOnlyForListKinds() {
        XCTAssertTrue(BlockNoteStore.emptySubmitExitsList(kind: .task))
        XCTAssertTrue(BlockNoteStore.emptySubmitExitsList(kind: .quote))
        XCTAssertFalse(BlockNoteStore.emptySubmitExitsList(kind: .paragraph))
        XCTAssertFalse(BlockNoteStore.emptySubmitExitsList(kind: .heading2))
    }

    // MARK: - 多行粘贴炸行

    func testExplodeSplitsPastedLinesIntoRowsAtTheAnchorDepth() {
        let rows = [row("a", 2, ""), row("z", 0, "尾")]
        let (next, head, lastId) =
            BlockNoteStore.explodedRows(rows, rowId: "a", text: "一\n二\n三")!
        XCTAssertEqual(head, "一")
        XCTAssertEqual(next.map(\.text), ["一", "二", "三", "尾"])
        XCTAssertEqual(next[1].depth, 2, "新行继承锚点行深度")
        XCTAssertEqual(next[2].id, lastId, "焦点应落到最后一个新行")
    }

    func testExplodeRunsEachLineThroughMarkdownPrefixes() {
        let rows = [row("a", 0, "")]
        let (next, _, _) = BlockNoteStore.explodedRows(
            rows,
            rowId: "a",
            text: "# 标题\n- [ ] 待办\n正文"
        )!
        XCTAssertEqual(next[0].kind, .heading1)
        XCTAssertEqual(next[0].text, "标题")
        XCTAssertEqual(next[1].kind, .task)
        XCTAssertFalse(next[1].checked)
        XCTAssertEqual(next[2].kind, .paragraph)
    }

    func testExplodeNormalizesCRLFAndDropsOneTrailingNewline() {
        let rows = [row("a", 0, "")]
        let (next, _, _) =
            BlockNoteStore.explodedRows(rows, rowId: "a", text: "甲\r\n乙\n")!
        XCTAssertEqual(next.map(\.text), ["甲", "乙"], "末尾单换行不额外造空行")
        let (blank, _, _) =
            BlockNoteStore.explodedRows(rows, rowId: "a", text: "甲\n\n乙")!
        XCTAssertEqual(blank.map(\.text), ["甲", "", "乙"], "连续换行保留为真实空行")
    }

    func testExplodeRefusesSingleLineText() {
        XCTAssertNil(BlockNoteStore.explodedRows([row("a", 0)], rowId: "a", text: "无换行"))
        XCTAssertNil(BlockNoteStore.explodedRows([row("a", 0)], rowId: "ghost", text: "甲\n乙"))
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

    // MARK: - 块类型手势

    func testMarkdownPrefixesTurnIntoBlockKindsAndEatTheMarker() {
        let cases: [(String, FfiOutlineKind, Bool, String)] = [
            ("# 标题", .heading1, false, "标题"),
            ("## 标题", .heading2, false, "标题"),
            ("### 标题", .heading3, false, "标题"),
            ("> 引文", .quote, false, "引文"),
            ("- [ ] 待办", .task, false, "待办"),
            ("- [x] 已办", .task, true, "已办"),
            ("--- ", .divider, false, ""),
        ]
        for (input, kind, checked, rest) in cases {
            let hit = BlockNoteStore.markdownPrefix(input)
            XCTAssertEqual(hit?.kind, kind, "\(input) 应变成 \(kind)")
            XCTAssertEqual(hit?.checked, checked)
            XCTAssertEqual(hit?.rest, rest, "记号要被吃掉,余文原样留下")
        }
    }

    func testLongerMarkersWinOverShorterOnes() {
        // `## ` 先匹配二级标题;短记号排在后面才不会把它抢走。
        XCTAssertEqual(BlockNoteStore.markdownPrefix("## x")?.kind, .heading2)
        XCTAssertEqual(BlockNoteStore.markdownPrefix("### x")?.kind, .heading3)
    }

    func testNonPrefixTextIsLeftAlone() {
        // 没有空格就不是手势 —— 用户可能只是在写「#1 号」。
        XCTAssertNil(BlockNoteStore.markdownPrefix("#标题"))
        XCTAssertNil(BlockNoteStore.markdownPrefix("普通一行"))
        XCTAssertNil(BlockNoteStore.markdownPrefix("行中间有 # 号"))
    }

    func testReturnContinuesListKindsButNotHeadings() {
        // 清单顺着写下去,标题下面接的是正文。
        XCTAssertEqual(BlockNoteStore.continuationKind(after: .task), .task)
        XCTAssertEqual(BlockNoteStore.continuationKind(after: .quote), .quote)
        XCTAssertEqual(BlockNoteStore.continuationKind(after: .heading1), .paragraph)
        XCTAssertEqual(BlockNoteStore.continuationKind(after: .heading3), .paragraph)
        XCTAssertEqual(BlockNoteStore.continuationKind(after: .divider), .paragraph)
        XCTAssertEqual(BlockNoteStore.continuationKind(after: .paragraph), .paragraph)
    }

    func testMoveKeepsDepthWhenDestinationAllowsIt() {
        let rows = [row("a", 0), row("a1", 1), row("b", 0), row("b1", 1)]
        // b1(深度 1)拖到 a1 之前:上一行是 a(深度 0),上限 1,深度保持。
        let next = BlockNoteStore.movedRows(rows, subtreeOf: "b1", before: "a1")!
        XCTAssertEqual(next.map(\.id), ["a", "b1", "a1", "b"])
        XCTAssertEqual(next[1].depth, 1)
    }

    func testBothNotebookAndSessionEditorEntryPointsRemainAvailable() {
        _ = BlockNoteEditorView(notebookId: "topic", tabId: "manual-note")
        _ = BlockNoteEditorView(sessionId: "session")
    }

    /// 编辑面从逐行 TextField 换成整篇一个 NSTextView 之后,这三样保证
    /// 必须跟着搬家而不是消失:空文档有占位提示、对 VoiceOver 是一个
    /// 有名字的可写文本区、而 AXValue 保持原生可写(自定义 value 会把
    /// 编辑面变成只读)。
    func testNoteCanvasKeepsPlaceholderAndNativeWritableAccessibility() throws {
        let source = try Self.loadBlockNoteTextView()

        XCTAssertTrue(source.contains("placeholderText"))
        XCTAssertTrue(source.contains("editor.outline.canvas_label"))
        XCTAssertTrue(source.contains("\"note.canvas\""))
        XCTAssertFalse(
            source.contains("override func accessibilityValue()"),
            "覆盖 AXValue 会让 VoiceOver 把可写编辑面读成只读"
        )
    }

    /// 跨行选择、复制、剪切、拖拽文本、拼写检查、输入法、查找都是文本
    /// 引擎的能力。编辑面必须是一个真正的 NSTextView,而不是若干个各自
    /// 为政的输入框 —— 后者的选区跨不过控件边界,这正是"不像编辑器"的
    /// 根源。
    func testEditorCanvasIsASingleTextViewRatherThanPerRowFields() throws {
        let editor = try Self.loadBlockNoteEditorView()
        XCTAssertTrue(editor.contains("BlockNoteTextCanvas("))
        XCTAssertFalse(editor.contains("BlockNoteRowView("), "逐行输入框架构已被取代")

        let textView = try Self.loadBlockNoteTextView()
        XCTAssertTrue(textView.contains("final class BlockNoteNSTextView: NSTextView"))
        XCTAssertTrue(textView.contains("usesFindBar") || textView.contains("writeSelection"))
    }

    func testSessionNotesStayIsolatedAcrossCloseReopenAndPurge() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zutalk-session-notes-\(UUID().uuidString)", isDirectory: true)
        let core = try ZuTalkCore.newDeferred(dataDir: tempDir.path)
        defer {
            try? core.shutdown()
            try? FileManager.default.removeItem(at: tempDir)
        }

        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("crates/vt-audio/tests/fixtures/test_16k_mono.wav")

        func importSession(_ title: String) throws -> String {
            let notebook = try core.createNotebook(title: title)
            return try core.importAudioIntoNotebook(
                path: fixture.path,
                notebookId: notebook.id
            ).sessionId
        }

        let firstSession = try importSession("Swift 访谈一")
        let secondSession = try importSession("Swift 访谈二")
        let firstDoc = try core.sessionNoteBlockDocumentOpen(sessionId: firstSession)
        try core.noteApplyOutline(
            docId: firstDoc,
            rows: [row("first", 0, "第一场独有")]
        )
        try core.blockDocumentClose(docId: firstDoc)

        let secondDoc = try core.sessionNoteBlockDocumentOpen(sessionId: secondSession)
        XCTAssertNotEqual(firstDoc, secondDoc)
        XCTAssertTrue(
            try core.noteOutlineRows(docId: secondDoc).isEmpty,
            "第二场第一次打开不能看见第一场内容"
        )
        try core.noteApplyOutline(
            docId: secondDoc,
            rows: [row("second", 0, "第二场独有")]
        )
        try core.blockDocumentClose(docId: secondDoc)

        XCTAssertEqual(
            try core.sessionNoteBlockDocumentOpen(sessionId: firstSession),
            firstDoc,
            "同一个 Session 重开必须返回稳定 doc_id"
        )
        XCTAssertEqual(
            try core.noteOutlineRows(docId: firstDoc).map(\.text),
            ["第一场独有"],
            "关闭再打开必须从磁盘恢复第一场内容"
        )
        try core.blockDocumentClose(docId: firstDoc)

        // 模拟切换标签时 onDisappear 先于 TextField 失焦回调：最后一笔只
        // 进入 Store 的草稿缓冲，没有调用 replaceText。close 必须先同步
        // flush，再驱逐 Rust 句柄。
        let store = BlockNoteStore(coreProvider: { core })
        store.openSession(sessionId: firstSession)
        let focusedRow = try XCTUnwrap(store.rows.first)
        store.noteDraftChanged(rowId: focusedRow.id, draft: "第一场切换前最后输入")
        store.close()

        _ = try core.sessionNoteBlockDocumentOpen(sessionId: firstSession)
        XCTAssertEqual(
            try core.noteOutlineRows(docId: firstDoc).map(\.text),
            ["第一场切换前最后输入"],
            "close 必须保存尚未来得及触发失焦提交的聚焦草稿"
        )
        try core.blockDocumentClose(docId: firstDoc)

        _ = try core.sessionNoteBlockDocumentOpen(sessionId: secondSession)
        XCTAssertEqual(
            try core.noteOutlineRows(docId: secondDoc).map(\.text),
            ["第二场独有"]
        )
        let secondPath = tempDir
            .appendingPathComponent("block-documents", isDirectory: true)
            .appendingPathComponent("\(secondDoc).loro")
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondPath.path))

        try core.purgeSession(sessionId: secondSession)

        XCTAssertFalse(FileManager.default.fileExists(atPath: secondPath.path))
        XCTAssertThrowsError(try core.noteOutlineRows(docId: secondDoc))
        XCTAssertNoThrow(try core.blockDocumentClose(docId: secondDoc))
        XCTAssertThrowsError(
            try core.sessionNoteBlockDocumentOpen(sessionId: secondSession),
            "purge 后不能由旧 Session id 重建孤儿笔记"
        )
    }


    private static func loadBlockNoteTextView() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ZuTalk", isDirectory: true)
        return try String(
            contentsOf: root.appendingPathComponent("Pages/BlockNoteTextView.swift"),
            encoding: .utf8
        )
    }

    private static func loadBlockNoteEditorView() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ZuTalk", isDirectory: true)
        return try String(
            contentsOf: root.appendingPathComponent("Pages/BlockNoteEditorView.swift"),
            encoding: .utf8
        )
    }
}
