// BlockNoteStore.swift
// 笔记 tab 大纲编辑器的状态仓 — 块文档 FFI 的 Swift 侧宿主
//
// 每个编辑手势走同一条流水线:改本地 rows → noteApplyOutline 整份重放 →
// 失败回滚本地镜像并 Toast。Rust 落盘状态是权威,Swift 只保留一份乐观镜像,
// 所以任何失败都能回到与磁盘一致的状态。
//
// 蓝本已知局限(macro 的 diffMovableList 实测同源):同一次重放里「删行」
// 与「跨删除位的移动」不能混——move 的 fromIndex 用删除前的索引空间,混用
// 会错位。这里靠手势构造保证:并块 = 删除 + 文本更新(无移动);拖拽 =
// 移动 + 深度更新(无删除)。任何新手势都不得在一次 apply 里同时含两者。

import Combine
import Foundation

@MainActor
final class BlockNoteStore: ObservableObject {
    /// 大纲行(先序)。UI 直接渲染这份镜像。
    @Published private(set) var rows: [FfiOutlineRow] = []

    /// 打开失败的原因。非 nil 时 UI 显示空态 + 重试。
    @Published private(set) var loadError: String?

    /// noteBlockDocumentOpen 返回的 doc_id。nil 表示尚未打开或已关闭。
    private(set) var docId: String?

    /// 打开(必要时从第 1 纪元平文本迁移)并载入大纲行。
    /// 幂等:重复调用会先释放旧文档再打开目标文档。
    func open(notebookId: String, tabId: String) {
        close()
        guard let core = CoreClient.shared.core else {
            loadError = CoreClient.shared.initError ?? "core init failed"
            return
        }
        do {
            let id = try core.noteBlockDocumentOpen(notebookId: notebookId, tabId: tabId)
            var loaded = try core.noteOutlineRows(docId: id)
            // 空文档给一行空 row 起步:光标有落点,首次输入即成第一行。
            // 只是本地占位,不立即落盘;第一次编辑手势会连内容一起 apply。
            if loaded.isEmpty {
                loaded = [Self.makeRow(depth: 0)]
            }
            docId = id
            rows = loaded
            loadError = nil
        } catch {
            docId = nil
            rows = []
            loadError = "\(error)"
        }
    }

    /// 释放 Rust 侧文档句柄。视图消失时必须调用,与 open 配对。
    func close() {
        guard let docId else { return }
        self.docId = nil
        rows = []
        try? CoreClient.shared.core?.blockDocumentClose(docId: docId)
    }

    // MARK: - 编辑手势(改本地 → apply → 失败回滚)

    /// 整行换文本。行内 TextField 失焦或提交时调用。
    func replaceText(rowId: String, text: String) {
        guard let index = rows.firstIndex(where: { $0.id == rowId }),
              rows[index].text != text
        else { return }
        var next = rows
        next[index].text = text
        apply(next)
    }

    /// 在 rowId 之后插入新行(nil = 追加到末尾)。深度继承锚点行。
    /// 返回新行 id 供 UI 移焦点;apply 失败时返回 nil,焦点留在原行。
    @discardableResult
    func insertRow(after rowId: String?) -> String? {
        var next = rows
        let insertIndex: Int
        let depth: UInt32
        if let rowId, let anchor = rows.firstIndex(where: { $0.id == rowId }) {
            insertIndex = anchor + 1
            depth = rows[anchor].depth
        } else {
            insertIndex = rows.count
            depth = rows.last?.depth ?? 0
        }
        let newRow = Self.makeRow(depth: depth)
        next.insert(newRow, at: insertIndex)
        return apply(next) ? newRow.id : nil
    }

    /// v1 简单删除:只删这一行,子行不收养、不随删。删空后补一行空 row,
    /// 保住「文档至少一行」的编辑器不变量。
    func deleteRow(rowId: String) {
        guard rows.contains(where: { $0.id == rowId }) else { return }
        var next = rows.filter { $0.id != rowId }
        if next.isEmpty {
            next = [Self.makeRow(depth: 0)]
        }
        apply(next)
    }

    /// 行首/空行退格:把 rowId 行并入上一行,返回上一行 id 供 UI 移焦点。
    ///
    /// `draftText` 是行内未提交的草稿(退格发生时草稿还没写回 store)。
    /// 空行的并入退化成纯删除——同一条路径,不另设「删行手势」。
    /// 后续更深的行不动:扁平 (id, depth, text) 模型下,重建树会让它们
    /// 自然归入前面的浅行,正是大纲编辑器「并块后子行过继」的语义。
    /// 首行没有上一行,no-op 返回 nil。
    @discardableResult
    func mergeWithPreviousRow(rowId: String, draftText: String) -> String? {
        guard let (next, previousId) = Self.mergedRows(rows, rowId: rowId, draftText: draftText)
        else { return nil }
        // 删除 + 文本更新,无移动——见文件头的蓝本约束。
        return apply(next) ? previousId : nil
    }

    /// 并块的纯运算,供直接单测。返回 (新行列表, 并入行的 id);首行或
    /// 找不到行时返回 nil。
    static func mergedRows(
        _ rows: [FfiOutlineRow],
        rowId: String,
        draftText: String
    ) -> ([FfiOutlineRow], String)? {
        guard let index = rows.firstIndex(where: { $0.id == rowId }), index > 0 else {
            return nil
        }
        var next = rows
        next[index - 1].text += draftText
        next.remove(at: index)
        return (next, next[index - 1].id)
    }

    /// rowId 行的子树范围:本行 + 紧随其后所有更深的行(先序连续段)。
    func subtreeRange(of rowId: String) -> Range<Int>? {
        Self.subtreeRange(in: rows, of: rowId)
    }

    static func subtreeRange(in rows: [FfiOutlineRow], of rowId: String) -> Range<Int>? {
        guard let start = rows.firstIndex(where: { $0.id == rowId }) else { return nil }
        var end = start + 1
        while end < rows.count, rows[end].depth > rows[start].depth {
            end += 1
        }
        return start..<end
    }

    /// 拖拽重排:把 rowId 的整棵子树移动到 targetRowId 之前(nil = 移到
    /// 末尾)。落点语义只有 before/after 两态(after 由调用方换算成「下一
    /// 行之前」),不做「拖成子块」——缩进只归 ⌘]/Tab 管,与 macro 同一
    /// 决策。
    ///
    /// - 落点在子树自身范围内 → no-op(拖进自己会把子树拆散);
    /// - 子树整体移动,内部相对深度保持;基准深度按落点处「上一行
    ///   depth+1」的既有上限收紧,保住「不悬空跳级」不变量;
    /// - 纯移动 + 深度更新,无删除——见文件头的蓝本约束。
    func moveSubtree(rowId: String, before targetRowId: String?) {
        guard let next = Self.movedRows(rows, subtreeOf: rowId, before: targetRowId) else {
            return
        }
        apply(next)
    }

    /// 拖拽重排的纯运算,供直接单测。no-op(落点在子树内/原位/行不存在)
    /// 返回 nil。
    static func movedRows(
        _ rows: [FfiOutlineRow],
        subtreeOf rowId: String,
        before targetRowId: String?
    ) -> [FfiOutlineRow]? {
        guard let range = subtreeRange(in: rows, of: rowId) else { return nil }
        let targetIndex: Int
        if let targetRowId {
            guard let found = rows.firstIndex(where: { $0.id == targetRowId }) else { return nil }
            targetIndex = found
        } else {
            targetIndex = rows.count
        }
        // 落点在子树内部(含紧贴子树尾 = 原位)都是 no-op。
        if range.contains(targetIndex) || targetIndex == range.upperBound {
            return nil
        }

        var next = rows
        let group = Array(next[range])
        next.removeSubrange(range)
        // 移除后落点索引左移。
        let insertIndex = targetIndex > range.lowerBound
            ? targetIndex - group.count
            : targetIndex
        next.insert(contentsOf: group, at: insertIndex)

        // 基准深度收紧:不能比落点处的上一行深超过 1 级。子树整体平移,
        // 相对结构不动;组内每行 depth ≥ base ≥ shift,减后必不为负。
        let previousDepth = insertIndex > 0 ? next[insertIndex - 1].depth : nil
        let cap = previousDepth.map { $0 + 1 } ?? 0
        let base = group[0].depth
        if base > cap {
            let shift = base - cap
            for offset in 0..<group.count {
                next[insertIndex + offset].depth -= shift
            }
        }
        return next
    }

    /// 缩进:depth+1,上限为前一行 depth+1(大纲不允许悬空跳级)。
    /// 首行没有前一行,永远缩不进去。
    func indent(rowId: String) {
        guard let index = rows.firstIndex(where: { $0.id == rowId }), index > 0 else { return }
        let cap = rows[index - 1].depth + 1
        guard rows[index].depth < cap else { return }
        var next = rows
        next[index].depth += 1
        apply(next)
    }

    /// 反缩进:depth-1,下限 0。
    func outdent(rowId: String) {
        guard let index = rows.firstIndex(where: { $0.id == rowId }),
              rows[index].depth > 0
        else { return }
        var next = rows
        next[index].depth -= 1
        apply(next)
    }

    // MARK: - 内部

    /// 乐观提交:先改镜像再整份重放。失败回滚到 previous 并 Toast,
    /// 保证 UI 永远与 Rust 落盘状态收敛。
    @discardableResult
    private func apply(_ next: [FfiOutlineRow]) -> Bool {
        guard let docId, let core = CoreClient.shared.core else { return false }
        let previous = rows
        rows = next
        do {
            try core.noteApplyOutline(docId: docId, rows: next)
            return true
        } catch {
            rows = previous
            ToastCenter.shared.error(
                String(localized: "editor.outline.apply_failed"),
                detail: error.localizedDescription
            )
            return false
        }
    }

    private static func makeRow(depth: UInt32) -> FfiOutlineRow {
        FfiOutlineRow(id: UUID().uuidString, depth: depth, text: "")
    }
}
