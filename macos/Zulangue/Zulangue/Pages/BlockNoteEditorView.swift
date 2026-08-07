// BlockNoteEditorView.swift
// 笔记 tab 的大纲编辑器 — 块文档 FFI 之上的行式 UI
//
// 手感对齐 NotebookCaptureViews 的 BilingualLaneText:行内 TextField(.plain)、
// 失焦提交、失败回滚 + Toast(回滚与 Toast 在 BlockNoteStore 里)。
//
// 键盘模型(v1):
//   · Return       → 提交本行并在其后插入同深度新行,焦点移过去
//   · ⌘] / ⌘[      → 当前聚焦行缩进 / 反缩进
//   · 删除行        → 行右键菜单(空行退格删除 v1 不做)
//   · 拖拽重排      → v1 不做

import SwiftUI

struct BlockNoteEditorView: View {
    let notebookId: String
    let tabId: String

    @StateObject private var store = BlockNoteStore()
    @FocusState private var focusedRowId: String?

    /// 每级缩进的前导内边距。
    fileprivate static let indentStep: CGFloat = 20

    var body: some View {
        Group {
            if let loadError = store.loadError {
                EmptyState(
                    icon: "exclamationmark.triangle",
                    title: String(localized: "editor.outline.load_failed_title"),
                    description: loadError,
                    action: (
                        label: String(localized: "editor.outline.retry"),
                        handler: { store.open(notebookId: notebookId, tabId: tabId) }
                    )
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(store.rows, id: \.id) { row in
                            BlockNoteRowView(
                                row: row,
                                store: store,
                                focusedRowId: $focusedRowId
                            )
                        }
                    }
                    .padding(.horizontal, Spacing.xl + Spacing.lg)
                    .padding(.vertical, Spacing.xl)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                // ⌘] / ⌘[ 挂在两个不可见按钮上,作用于当前聚焦行。
                .background(indentShortcuts)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 文档随 route 切换时重开;open 内部先 close 旧句柄,不会泄漏。
        .task(id: "\(notebookId):\(tabId)") {
            store.open(notebookId: notebookId, tabId: tabId)
        }
        .onDisappear {
            store.close()
        }
    }

    /// 隐形快捷键宿主。SwiftUI 的 keyboardShortcut 需要一个 Button 载体,
    /// 藏起来但保持可命中(0 尺寸 + 无障碍隐藏)。
    private var indentShortcuts: some View {
        Group {
            Button(String(localized: "editor.outline.indent")) {
                if let rowId = focusedRowId { store.indent(rowId: rowId) }
            }
            .keyboardShortcut("]", modifiers: .command)

            Button(String(localized: "editor.outline.outdent")) {
                if let rowId = focusedRowId { store.outdent(rowId: rowId) }
            }
            .keyboardShortcut("[", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}

// MARK: - 单行

private struct BlockNoteRowView: View {
    let row: FfiOutlineRow
    @ObservedObject var store: BlockNoteStore
    @FocusState.Binding var focusedRowId: String?

    /// 本地草稿。提交(Return / 失焦)时才写回 store,与 BilingualLaneText
    /// 的 draft buffer 同一思路,避免每个键击都触发一次整份重放。
    @State private var draft: String

    init(
        row: FfiOutlineRow,
        store: BlockNoteStore,
        focusedRowId: FocusState<String?>.Binding
    ) {
        self.row = row
        self.store = store
        self._focusedRowId = focusedRowId
        self._draft = State(initialValue: row.text)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
            // 层级记号:顶层圆点,下层短横。
            Text(row.depth == 0 ? "•" : "–")
                .font(.body)
                .foregroundColor(.textTertiary)
                .frame(width: 12, alignment: .center)
                .accessibilityHidden(true)

            TextField("", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .foregroundColor(.textPrimary)
                .lineLimit(1...)
                .focused($focusedRowId, equals: row.id)
                .onSubmit(submitRow)
                .accessibilityLabel(Text(String(
                    format: String(localized: "editor.outline.row_label"),
                    Int64(row.depth)
                )))
                .accessibilityValue(Text(draft))
        }
        .padding(.leading, CGFloat(row.depth) * BlockNoteEditorView.indentStep)
        .padding(.vertical, 2)
        .contextMenu {
            Button(String(localized: "editor.outline.indent")) {
                store.indent(rowId: row.id)
            }
            Button(String(localized: "editor.outline.outdent")) {
                store.outdent(rowId: row.id)
            }
            Divider()
            Button(String(localized: "editor.outline.delete_row"), role: .destructive) {
                store.deleteRow(rowId: row.id)
            }
        }
        // 权威文本变化(比如 apply 失败回滚)时,未聚焦的行跟随权威值。
        .onChange(of: row.text) { _, newValue in
            if focusedRowId != row.id {
                draft = newValue
            }
        }
        // 失焦提交:与 BilingualLaneText 的失焦提交同一手感。
        .onChange(of: focusedRowId) { previous, current in
            if previous == row.id, current != row.id {
                store.replaceText(rowId: row.id, text: draft)
            }
        }
    }

    /// Return:先提交本行草稿,再在其后插入同深度新行并移焦点。
    private func submitRow() {
        store.replaceText(rowId: row.id, text: draft)
        if let newRowId = store.insertRow(after: row.id) {
            // 推迟一拍:新行此刻还没进视图树,同步设焦点会被 SwiftUI 丢弃。
            Task { @MainActor in
                focusedRowId = newRowId
            }
        }
    }
}
