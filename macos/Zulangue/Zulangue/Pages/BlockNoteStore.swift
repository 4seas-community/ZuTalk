// BlockNoteStore.swift
// 笔记 tab 大纲编辑器的状态仓 — 块文档 FFI 的 Swift 侧宿主
//
// 每个编辑手势走同一条流水线:改本地 rows → noteApplyOutline 整份重放 →
// 失败回滚本地镜像并 Toast。Rust 落盘状态是权威,Swift 只保留一份乐观镜像,
// 所以任何失败都能回到与磁盘一致的状态。
//
// 蓝本已知局限:同一次重放里「删行」与「跨删除位的移动」不能混。这里每个
// 手势单独一次 apply,且 v1 没有任何移动手势(不做拖拽重排),天然满足。

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
