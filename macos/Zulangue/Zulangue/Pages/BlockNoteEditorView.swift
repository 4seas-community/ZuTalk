// BlockNoteEditorView.swift
// 笔记 tab 的大纲编辑器 — 块文档 FFI 之上的行式 UI
//
// 手感对齐 NotebookCaptureViews 的 BilingualLaneText:行内 TextField(.plain)、
// 失焦提交、失败回滚 + Toast(回滚与 Toast 在 BlockNoteStore 里)。
//
// 键盘模型(v2):
//   · Return       → 提交本行并在其后插入同深度新行,焦点移过去
//   · Tab / ⇧Tab   → 当前聚焦行缩进 / 反缩进(抢在焦点循环之前)
//   · ⌘] / ⌘[      → 同上,给把 Tab 留给焦点导航的用户一条别路
//   · 行首退格      → 并入上一行(空行退化成删行),焦点移上一行
//   · 拖拽重排      → 左侧悬浮把手,整棵子树随行移动;落点只有
//                     before/after 两态,「拖成子块」刻意不做——缩进
//                     只归 ⌘]/⌘[ 管(与 macro 的拖拽语义同一决策)
//   · 删除行        → 行右键菜单(保留,给触控板用户一条明路)

import Combine
import SwiftUI
import UniformTypeIdentifiers

struct BlockNoteEditorView: View {
    let notebookId: String
    let tabId: String

    @StateObject private var store = BlockNoteStore()
    @StateObject private var dragState = BlockNoteDragState()
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
                                focusedRowId: $focusedRowId,
                                dragState: dragState
                            )
                        }
                        // 末尾落点:拖到最后一行之后。
                        Color.clear
                            .frame(height: Spacing.xl)
                            .frame(maxWidth: .infinity)
                            .overlay(alignment: .top) {
                                if dragState.tailTargeted {
                                    BlockNoteDropIndicator()
                                }
                            }
                            .onDrop(
                                of: [.plainText],
                                delegate: BlockNoteTailDropDelegate(
                                    store: store,
                                    dragState: dragState
                                )
                            )
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
    ///
    /// Tab / ⇧Tab 也在这里:macOS 的 TextField 默认把 Tab 交给焦点循环
    /// (跳下一行输入框),缩进必须抢在它之前。key equivalent 在事件进
    /// 响应链之前匹配——与 macro 用最高优先级命令 + preventDefault 拦
    /// Tab 是同一手法。没有聚焦行时按钮禁用,Tab 回归正常焦点语义。
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

            Button(String(localized: "editor.outline.indent")) {
                if let rowId = focusedRowId { store.indent(rowId: rowId) }
            }
            .keyboardShortcut(.tab, modifiers: [])
            .disabled(focusedRowId == nil)

            Button(String(localized: "editor.outline.outdent")) {
                if let rowId = focusedRowId { store.outdent(rowId: rowId) }
            }
            .keyboardShortcut(.tab, modifiers: .shift)
            .disabled(focusedRowId == nil)

            // ⌘Z / ⇧⌘Z:文档层撤销。行内草稿的「打字撤销」也归这里——
            // 聚焦行草稿有未提交改动时,第一下先把草稿刷回权威文本,
            // 第二下才回退上一个手势(两段式,见 BlockNoteStore.undo)。
            Button(String(localized: "editor.outline.undo")) {
                store.undo(focusedRowId: focusedRowId)
            }
            .keyboardShortcut("z", modifiers: .command)

            Button(String(localized: "editor.outline.redo")) {
                store.redo()
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(!store.canRedo)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}

// MARK: - 拖拽状态

/// 一次拖拽的进程内共享状态。NSItemProvider 的载荷解码是异步的,而
/// dropEntered 需要同步知道「拖的是谁」才能画指示线,所以把被拖行 id
/// 存在这里,drop 时直接取用——同一编辑器内拖拽这就是权威(macro 用
/// dataTransfer 存 NodeKey,思路相同)。
@MainActor
final class BlockNoteDragState: ObservableObject {
    /// 正在被拖动的行 id;nil = 没有拖拽进行中。
    @Published var draggingRowId: String?
    /// 当前悬停落点:(目标行 id, 落在上半区=before)。
    @Published var target: (rowId: String, before: Bool)?
    /// 悬停在末尾落点上。
    @Published var tailTargeted: Bool = false

    func reset() {
        draggingRowId = nil
        target = nil
        tailTargeted = false
    }
}

/// 落点指示线:横跨行宽的 2px 强调线(macro 的同款视觉)。
struct BlockNoteDropIndicator: View {
    var body: some View {
        Rectangle()
            .fill(Color.brandAccent)
            .frame(height: 2)
            .accessibilityHidden(true)
    }
}

// MARK: - 单行

private struct BlockNoteRowView: View {
    let row: FfiOutlineRow
    @ObservedObject var store: BlockNoteStore
    @FocusState.Binding var focusedRowId: String?
    @ObservedObject var dragState: BlockNoteDragState

    /// 本地草稿。提交(Return / 失焦)时才写回 store,与 BilingualLaneText
    /// 的 draft buffer 同一思路,避免每个键击都触发一次整份重放。
    @State private var draft: String
    /// 光标位置。行首退格的判定依据——退格并块只在「光标折叠于行首」
    /// 时触发,与 macro 的 offset==0 判定同义。
    @State private var selection: TextSelection?
    @State private var hovering = false

    init(
        row: FfiOutlineRow,
        store: BlockNoteStore,
        focusedRowId: FocusState<String?>.Binding,
        dragState: BlockNoteDragState
    ) {
        self.row = row
        self.store = store
        self._focusedRowId = focusedRowId
        self.dragState = dragState
        self._draft = State(initialValue: row.text)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
            // 拖拽把手:悬停出现,拖起整棵子树。放在缩进之外,列不随
            // 深度漂移。
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.textTertiary)
                .frame(width: 14)
                .opacity(hovering && dragState.draggingRowId == nil ? 1 : 0)
                .accessibilityLabel(Text(String(localized: "editor.outline.drag_handle")))
                .onDrag {
                    dragState.draggingRowId = row.id
                    return NSItemProvider(object: row.id as NSString)
                }

            // 层级记号:顶层圆点,下层短横。
            Text(row.depth == 0 ? "•" : "–")
                .font(.body)
                .foregroundColor(.textTertiary)
                .frame(width: 12, alignment: .center)
                .accessibilityHidden(true)
                .padding(.leading, CGFloat(row.depth) * BlockNoteEditorView.indentStep)

            TextField("", text: $draft, selection: $selection, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .foregroundColor(.textPrimary)
                .lineLimit(1...)
                .focused($focusedRowId, equals: row.id)
                .onSubmit(submitRow)
                .onKeyPress(.delete) { handleBackspace() }
                .accessibilityLabel(Text(String(
                    format: String(localized: "editor.outline.row_label"),
                    Int64(row.depth)
                )))
                .accessibilityValue(Text(draft))
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        // 落点指示:上半区画在行顶,下半区画在行底。
        .overlay(alignment: .top) {
            if let target = dragState.target, target.rowId == row.id, target.before {
                BlockNoteDropIndicator()
            }
        }
        .overlay(alignment: .bottom) {
            if let target = dragState.target, target.rowId == row.id, !target.before {
                BlockNoteDropIndicator()
            }
        }
        .onDrop(
            of: [.plainText],
            delegate: BlockNoteRowDropDelegate(
                rowId: row.id,
                store: store,
                dragState: dragState
            )
        )
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
        // 草稿上报:两段式撤销靠它判断「聚焦行还有没提交的字」。
        .onChange(of: draft) { _, newValue in
            store.noteDraftChanged(rowId: row.id, draft: newValue)
        }
        // 撤销/重做换掉权威状态时,草稿无条件刷回权威文本——聚焦中的
        // 行也不例外,否则失焦时旧草稿会把撤销结果又写回去。
        .onChange(of: store.authorityEpoch) { _, _ in
            draft = row.text
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

    /// 行首退格 → 并入上一行;空行退化成删行。其余位置放行给系统删字。
    private func handleBackspace() -> KeyPress.Result {
        guard caretIsAtStart else { return .ignored }
        guard let previousId = store.mergeWithPreviousRow(rowId: row.id, draftText: draft) else {
            // 首行行首:没有可并入的上一行,吞掉退格避免系统再删一个字。
            return draft.isEmpty ? .handled : .ignored
        }
        Task { @MainActor in
            focusedRowId = previousId
        }
        return .handled
    }

    /// 光标折叠于行首。空行永远算行首;拿不到 selection(聚焦竞态)时
    /// 保守放行,绝不误吞用户的删字。
    private var caretIsAtStart: Bool {
        if draft.isEmpty { return true }
        guard case .selection(let range) = selection?.indices else { return false }
        return range.isEmpty && range.lowerBound == draft.startIndex
    }
}

// MARK: - 落点判定

/// 行上的落点代理:上半区 = 之前,下半区 = 之后(换算成「下一行之前」)。
/// 落在被拖子树自身范围内是 no-op——store.moveSubtree 再兜底一次。
///
/// DropDelegate 的回调都在主线程,但协议本身不带隔离标注,所以每处
/// 触碰 MainActor 状态都走 `MainActor.assumeIsolated`。
private struct BlockNoteRowDropDelegate: DropDelegate {
    let rowId: String
    let store: BlockNoteStore
    let dragState: BlockNoteDragState

    func validateDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated { dragState.draggingRowId != nil }
    }

    func dropEntered(info: DropInfo) {
        updateTarget(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        updateTarget(info)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        MainActor.assumeIsolated {
            if dragState.target?.rowId == rowId {
                dragState.target = nil
            }
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated {
            defer { dragState.reset() }
            guard let draggingRowId = dragState.draggingRowId,
                  let index = store.rows.firstIndex(where: { $0.id == rowId })
            else { return false }
            let before = dragState.target?.before ?? true
            // after = 下一行之前;本行是末行时即移动到末尾。
            let targetRowId: String? = before
                ? rowId
                : (index + 1 < store.rows.count ? store.rows[index + 1].id : nil)
            store.moveSubtree(rowId: draggingRowId, before: targetRowId)
            return true
        }
    }

    private func updateTarget(_ info: DropInfo) {
        // DropInfo.location 在本行坐标系里;行高不定(多行折行),用
        // TextField 的单行高近似上下半区分界已足够——判错半区的代价只是
        // 指示线画在另一侧,落点仍由 performDrop 时的同一判定给出,视觉
        // 与结果一致。
        let before = info.location.y < 14
        MainActor.assumeIsolated {
            dragState.target = (rowId, before)
        }
    }
}

/// 末尾落点:整个列表底部的空白带,拖到最后。
private struct BlockNoteTailDropDelegate: DropDelegate {
    let store: BlockNoteStore
    let dragState: BlockNoteDragState

    func validateDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated { dragState.draggingRowId != nil }
    }

    func dropEntered(info: DropInfo) {
        MainActor.assumeIsolated {
            dragState.tailTargeted = true
            dragState.target = nil
        }
    }

    func dropExited(info: DropInfo) {
        MainActor.assumeIsolated { dragState.tailTargeted = false }
    }

    func performDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated {
            defer { dragState.reset() }
            guard let draggingRowId = dragState.draggingRowId else { return false }
            store.moveSubtree(rowId: draggingRowId, before: nil)
            return true
        }
    }
}
