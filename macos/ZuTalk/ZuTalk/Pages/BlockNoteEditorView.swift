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
//
// 块类型(标题/引用/任务/分隔线)按 macro 的同一手势模型:行首敲
// Markdown 记号 + 空格当场变身(`# ` `## ` `### ` `> ` `- [ ] ` `--- `),
// 右键菜单是等价的明路。非段落行的行首退格先降回段落,第二下才并块 ——
// 一下退格就把标题并进上一行,是最容易误伤的手势。

import Combine
import SwiftUI
import UniformTypeIdentifiers

private enum BlockNoteDocumentSource: Hashable {
    case notebook(notebookId: String, tabId: String)
    case session(sessionId: String)

    @MainActor
    func open(in store: BlockNoteStore) {
        switch self {
        case .notebook(let notebookId, let tabId):
            store.open(notebookId: notebookId, tabId: tabId)
        case .session(let sessionId):
            store.openSession(sessionId: sessionId)
        }
    }
}

struct BlockNoteEditorView: View {
    private let source: BlockNoteDocumentSource

    @StateObject private var store = BlockNoteStore()
    @StateObject private var dragState = BlockNoteDragState()
    @StateObject private var focusIntent = BlockNoteFocusIntent()
    @FocusState private var focusedRowId: String?

    /// 每级缩进的前导内边距。
    fileprivate static let indentStep: CGFloat = 20

    /// 保留 Notebook ManualNote tab 的既有入口。
    init(notebookId: String, tabId: String) {
        source = .notebook(notebookId: notebookId, tabId: tabId)
    }

    /// Session 页面使用的独立笔记入口。
    init(sessionId: String) {
        source = .session(sessionId: sessionId)
    }

    var body: some View {
        Group {
            if let loadError = store.loadError {
                EmptyState(
                    icon: "exclamationmark.triangle",
                    title: String(localized: "editor.outline.load_failed_title"),
                    description: loadError,
                    action: (
                        label: String(localized: "editor.outline.retry"),
                        handler: { source.open(in: store) }
                    )
                )
            } else {
                VStack(spacing: 0) {
                editorControlStrip
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(store.rows, id: \.id) { row in
                            BlockNoteRowView(
                                row: row,
                                store: store,
                                focusedRowId: $focusedRowId,
                                dragState: dragState,
                                focusIntent: focusIntent
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
                // The document canvas itself is a writing target. When focus
                // was cleared by a tab transition, clicking the otherwise
                // empty page returns the caret to the last block instead of
                // leaving a large surface that looks read-only.
                .background {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard focusedRowId == nil else { return }
                            focusedRowId = store.rows.last?.id
                        }
                }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 文档随 route 切换时重开;open 内部先 close 旧句柄,不会泄漏。
        .task(id: source) {
            source.open(in: store)
        }
        // A brand-new Session note has one local empty row. Give that row the
        // caret once it arrives so opening the Note tab is immediately a
        // writing action instead of a hunt for a one-line hit target.
        .onChange(of: store.rows.map(\.id)) { _ in
            guard focusedRowId == nil,
                  store.rows.count == 1,
                  let row = store.rows.first,
                  row.text.isEmpty
            else { return }
            Task { @MainActor in focusedRowId = row.id }
        }
        .onDisappear {
            // close 会先同步 flush Store 中逐键上报的聚焦草稿，再驱逐
            // Rust 句柄；不能只依赖可能晚到一步的 TextField 失焦回调。
            store.close()
        }
    }

    /// 可见的编辑工具条。这些操作一直存在,但过去只藏在快捷键和右键
    /// 菜单里 —— 一个界面上看不见任何按钮的编辑器,对不知道快捷键的人
    /// 就等于没有这些功能。tooltip 顺带承担快捷键教学。
    private var editorControlStrip: some View {
        HStack(spacing: Spacing.md) {
            Spacer()
            stripButton(
                systemImage: "arrow.uturn.backward",
                label: String(localized: "editor.outline.undo"),
                shortcutHint: "\u{2318}Z",
                disabled: false
            ) {
                store.undo(focusedRowId: focusedRowId)
            }
            stripButton(
                systemImage: "arrow.uturn.forward",
                label: String(localized: "editor.outline.redo"),
                shortcutHint: "\u{21E7}\u{2318}Z",
                disabled: !store.canRedo
            ) {
                store.redo()
            }
            Divider().frame(height: 14)
            stripButton(
                systemImage: "decrease.indent",
                label: String(localized: "editor.outline.outdent"),
                shortcutHint: "\u{21E7}\u{21E5} / \u{2318}[",
                disabled: focusedRowId == nil
            ) {
                if let rowId = focusedRowId { store.outdent(rowId: rowId) }
            }
            stripButton(
                systemImage: "increase.indent",
                label: String(localized: "editor.outline.indent"),
                shortcutHint: "\u{21E5} / \u{2318}]",
                disabled: focusedRowId == nil
            ) {
                if let rowId = focusedRowId { store.indent(rowId: rowId) }
            }
        }
        .padding(.horizontal, Spacing.xl + Spacing.lg)
        .padding(.top, Spacing.sm)
    }

    private func stripButton(
        systemImage: String,
        label: String,
        shortcutHint: String,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(disabled ? .textTertiary : .textSecondary)
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help("\(label)  \(shortcutHint)")
        .accessibilityLabel(Text(label))
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

// MARK: - 焦点意图

/// 一次手势想把光标落在哪。SwiftUI 的 FocusState 只到"哪一行",不到
/// "行内哪个位置";拆分要落在新行行首、并块要落在接缝处,都靠这里把
/// 意图带给目标行的 TextField,由它在获得焦点的那一刻设置 selection。
@MainActor
final class BlockNoteFocusIntent: ObservableObject {
    enum Caret {
        case start
        case end
        /// 距行首的字符偏移(并块把光标放在接缝上用)。
        case offset(Int)
    }

    /// 待兑现的落点。不发布:兑现发生在目标行自己的 onChange 里,
    /// 不需要重渲染任何视图。
    var pending: (rowId: String, caret: Caret)?

    /// 目标行拿走属于自己的意图;别人的意图原样留着。
    func take(for rowId: String) -> Caret? {
        guard let pending, pending.rowId == rowId else { return nil }
        self.pending = nil
        return pending.caret
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
    let focusIntent: BlockNoteFocusIntent

    /// 本地草稿。提交(Return / 失焦)时才写回 store,与 BilingualLaneText
    /// 的 draft buffer 同一思路,避免每个键击都触发一次整份重放。
    @State private var draft: String
    @State private var hovering = false

    init(
        row: FfiOutlineRow,
        store: BlockNoteStore,
        focusedRowId: FocusState<String?>.Binding,
        dragState: BlockNoteDragState,
        focusIntent: BlockNoteFocusIntent
    ) {
        self.row = row
        self.store = store
        self._focusedRowId = focusedRowId
        self.dragState = dragState
        self.focusIntent = focusIntent
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

            marker

            if row.kind == .divider {
                dividerRule
            } else {
                rowTextField
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { focusedRowId = row.id }
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
            // 类型菜单是 Markdown 手势的等价明路 —— 不记得记号的人也
            // 有路可走。
            Menu(String(localized: "editor.outline.turn_into")) {
                ForEach(Self.kindChoices) { choice in
                    Button {
                        store.setKind(rowId: row.id, kind: choice.kind)
                    } label: {
                        if row.kind == choice.kind {
                            Label(String(localized: choice.key), systemImage: "checkmark")
                        } else {
                            Text(String(localized: choice.key))
                        }
                    }
                }
            }
            Divider()
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
        .onChange(of: row.text) { newValue in
            if focusedRowId != row.id {
                draft = newValue
            }
        }
        // 草稿上报:两段式撤销靠它判断「聚焦行还有没提交的字」。
        // 行首 Markdown 记号当场变身,只从段落出发 —— 否则标题里想打
        // 一个真的 `# ` 都打不出来。
        .onChange(of: draft) { newValue in
            // 多行粘贴:Return 已被拦截,草稿里出现换行只可能来自粘贴。
            // 炸开成多行,首行留在本行,焦点落到末行行尾 —— 粘贴一份
            // 清单进来得到一份清单,而不是一行揉着换行符的长文本。
            if newValue.contains("\n") || newValue.contains("\r") {
                if let (head, lastRowId) = store.explodeMultilineDraft(
                    rowId: row.id,
                    text: newValue
                ) {
                    draft = head
                    store.noteDraftChanged(rowId: row.id, draft: head)
                    if lastRowId != row.id {
                        focusIntent.pending = (lastRowId, .end)
                        moveFocus(to: lastRowId)
                    }
                }
                return
            }
            if row.kind == .paragraph,
               let hit = BlockNoteStore.markdownPrefix(newValue) {
                draft = hit.rest
                // `draft =` 的下一轮 onChange 可能晚于父视图 disappear；
                // 先同步更新 Store 缓冲，close/flush 就不会把旧记号文本
                // 覆盖回刚完成的 Markdown 转换。
                store.noteDraftChanged(rowId: row.id, draft: hit.rest)
                store.applyMarkdownPrefix(
                    rowId: row.id,
                    kind: hit.kind,
                    checked: hit.checked,
                    text: hit.rest
                )
                return
            }
            store.noteDraftChanged(rowId: row.id, draft: newValue)
        }
        // 撤销/重做换掉权威状态时,草稿无条件刷回权威文本——聚焦中的
        // 行也不例外,否则失焦时旧草稿会把撤销结果又写回去。
        .onChange(of: store.authorityEpoch) { _ in
            draft = row.text
        }
        // 失焦提交:与 BilingualLaneText 的失焦提交同一手感。
        .onChange(of: focusedRowId == row.id) { isFocused in
            if !isFocused {
                store.replaceText(rowId: row.id, text: draft)
            }
        }
    }

    /// 「转换为」菜单的一项。
    struct KindChoice: Identifiable {
        let id: String
        let key: String.LocalizationValue
        let kind: FfiOutlineKind
    }

    static let kindChoices: [KindChoice] = [
        KindChoice(id: "paragraph", key: "editor.outline.kind.paragraph", kind: .paragraph),
        KindChoice(id: "heading1", key: "editor.outline.kind.heading1", kind: .heading1),
        KindChoice(id: "heading2", key: "editor.outline.kind.heading2", kind: .heading2),
        KindChoice(id: "heading3", key: "editor.outline.kind.heading3", kind: .heading3),
        KindChoice(id: "quote", key: "editor.outline.kind.quote", kind: .quote),
        KindChoice(id: "task", key: "editor.outline.kind.task", kind: .task),
        KindChoice(id: "divider", key: "editor.outline.kind.divider", kind: .divider),
    ]

    /// 行首记号:段落是圆点/短横,任务是可点的方框,引用是竖条,标题与
    /// 分隔线不占记号(留白本身就是层级信号)。缩进的前导内边距统一挂在
    /// 这里,文本列才不会随类型漂移。
    @ViewBuilder
    private var marker: some View {
        Group {
            switch row.kind {
            case .task:
                Button {
                    store.toggleChecked(rowId: row.id)
                } label: {
                    Image(systemName: row.checked ? "checkmark.square.fill" : "square")
                        .font(.system(size: 12))
                        .foregroundColor(row.checked ? .brandAccent : .textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(String(localized: "editor.outline.kind.task")))
                .accessibilityValue(Text(String(localized: row.checked
                    ? "editor.outline.task.done"
                    : "editor.outline.task.todo")))
            case .quote:
                Rectangle()
                    .fill(Color.borderActive)
                    .frame(width: 2)
                    .frame(maxHeight: .infinity)
                    .accessibilityHidden(true)
            case .heading1, .heading2, .heading3, .divider:
                Color.clear.accessibilityHidden(true)
            case .paragraph:
                Text(row.depth == 0 ? "•" : "–")
                    .font(.body)
                    .foregroundColor(.textTertiary)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: 12, alignment: .center)
        .padding(.leading, CGFloat(row.depth) * BlockNoteEditorView.indentStep)
    }

    /// macOS 15 保留可选区多行 TextField 与精确的行首退格语义。
    /// Monterey 使用单行 TextField 降级:仍保留逐键草稿、Return 提交、
    /// 失焦保存与原生可写 AXValue，但不提供多行扩展及行首退格并块。
    @ViewBuilder
    private var rowTextField: some View {
        if #available(macOS 15.0, *) {
            ModernTextField(
                row: row,
                draft: $draft,
                focusedRowId: $focusedRowId,
                focusIntent: focusIntent,
                onSubmitSplit: submitRow,
                onBackspaceAtStart: handleBackspaceAtStart,
                onNavigate: navigate(_:)
            )
        } else {
            TextField(
                "",
                text: $draft,
                prompt: Text(String(localized: "editor.outline.placeholder"))
            )
            .textFieldStyle(.plain)
            .font(Self.font(for: row.kind))
            .foregroundColor(row.checked ? .textTertiary : .textPrimary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .focused($focusedRowId, equals: row.id)
            .onSubmit { submitRow(head: draft, tail: "") }
            .accessibilityLabel(rowAccessibilityLabel)
            // Preserve the TextField's native writable AXValue. A custom
            // accessibilityValue would make it display-only to AX clients.
            .accessibilityIdentifier("note.row.\(row.id)")
        }
    }

    private var rowAccessibilityLabel: Text {
        Text(String(
            format: String(localized: "editor.outline.row_label"),
            Int64(row.depth)
        ))
    }

    /// 分隔线:没有文本可编辑,但仍是一行。macOS 14+ 保留 Delete 快捷
    /// 删除；Monterey 仍可聚焦并从右键菜单删除。
    @ViewBuilder
    private var dividerRule: some View {
        if #available(macOS 14.0, *) {
            dividerRuleBase
                .onKeyPress(.delete) {
                    store.deleteRow(rowId: row.id)
                    return .handled
                }
        } else {
            dividerRuleBase
        }
    }

    private var dividerRuleBase: some View {
        Rectangle()
            .fill(Color.borderSubtle)
            .frame(height: 1)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .focusable()
            .focused($focusedRowId, equals: row.id)
            .accessibilityLabel(Text(String(localized: "editor.outline.kind.divider")))
    }

    private static func font(for kind: FfiOutlineKind) -> Font {
        switch kind {
        case .heading1: .title2.weight(.semibold)
        case .heading2: .title3.weight(.semibold)
        case .heading3: .headline
        default: .body
        }
    }

    /// Return:在光标处拆分本行。head 留在本行,tail 进新行,光标落在
    /// 新行行首 —— 与所有编辑器一致;行尾回车 tail 为空,自然退化成
    /// "插一个空行"。空清单行上的回车是清单的出口:降回段落,不再叠空项。
    private func submitRow(head: String, tail: String) {
        if head.isEmpty, tail.isEmpty, BlockNoteStore.emptySubmitExitsList(kind: row.kind) {
            store.setKind(rowId: row.id, kind: .paragraph)
            return
        }
        // 先把本地草稿降为 head:随后的焦点转移会触发失焦提交,让它
        // 提交旧的整行文本会把拆分立即冲掉。
        draft = head
        store.noteDraftChanged(rowId: row.id, draft: head)
        guard let newRowId = store.splitRow(rowId: row.id, head: head, tail: tail) else { return }
        focusIntent.pending = (newRowId, .start)
        moveFocus(to: newRowId)
    }

    /// 上下方向键跨行:行首向上去上一行行尾,行尾向下去下一行行首。
    /// 只在光标贴着行界时接管 —— 行内的上下移动(折行文本)仍归系统,
    /// 绝不抢走 TextField 自己能做对的事。
    enum RowNavigation {
        case previous
        case next
    }

    private func navigate(_ direction: RowNavigation) -> Bool {
        guard let index = store.rows.firstIndex(where: { $0.id == row.id }) else { return false }
        let target: FfiOutlineRow?
        switch direction {
        case .previous:
            target = index > 0 ? store.rows[index - 1] : nil
        case .next:
            target = index + 1 < store.rows.count ? store.rows[index + 1] : nil
        }
        guard let target else { return false }
        focusIntent.pending = (target.id, direction == .previous ? .end : .start)
        moveFocus(to: target.id)
        return true
    }

    /// 立即设焦点,再补一拍兜底。同步设置在多数情况下直接生效(rows 是
    /// 同步更新的,目标行已在数据里);SwiftUI 偶尔因视图未物化而丢弃时,
    /// 下一拍的重申接住。过去只有"推迟一拍"这一条路,点击/回车与焦点
    /// 落地之间的空窗会把紧接着的键击丢给旧行 —— 快速打字必中。
    private func moveFocus(to rowId: String) {
        focusedRowId = rowId
        Task { @MainActor in
            if focusedRowId != rowId {
                focusedRowId = rowId
            }
        }
    }

    /// 行首退格 → 并入上一行;空行退化成删行。其余位置放行给系统删字。
    ///
    /// 非段落行先降回段落:一下退格就把标题并进上一行是最容易误伤的
    /// 手势,给它加一格 —— 与 macro 的「先卸格式,再并块」同一决策。
    private func handleBackspaceAtStart() -> Bool {
        if row.kind != .paragraph {
            store.setKind(rowId: row.id, kind: .paragraph)
            return true
        }
        // 接缝位置 = 上一行合并前的长度,光标要落在那里 —— 用户按下
        // 退格想去的正是两行相接的那个点,不是上一行行尾。
        let joinOffset = store.rows.firstIndex(where: { $0.id == row.id })
            .flatMap { index in index > 0 ? store.rows[index - 1].text.count : nil }
        guard let previousId = store.mergeWithPreviousRow(rowId: row.id, draftText: draft) else {
            // 首行行首:没有可并入的上一行,吞掉退格避免系统再删一个字。
            return draft.isEmpty
        }
        if let joinOffset {
            focusIntent.pending = (previousId, .offset(joinOffset))
        }
        moveFocus(to: previousId)
        return true
    }

    /// 新版 SwiftUI 编辑器被整段隔离在 macOS 15 availability 内，避免
    /// TextSelection、vertical axis 与 onKeyPress 泄漏到 Monterey 构建。
    @available(macOS 15.0, *)
    private struct ModernTextField: View {
        let row: FfiOutlineRow
        @Binding var draft: String
        @FocusState.Binding var focusedRowId: String?
        let focusIntent: BlockNoteFocusIntent
        let onSubmitSplit: (_ head: String, _ tail: String) -> Void
        let onBackspaceAtStart: () -> Bool
        let onNavigate: (BlockNoteRowView.RowNavigation) -> Bool

        @State private var selection: TextSelection?

        var body: some View {
            TextField(
                "",
                text: $draft,
                selection: $selection,
                prompt: Text(String(localized: "editor.outline.placeholder")),
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(BlockNoteRowView.font(for: row.kind))
            .foregroundColor(row.checked ? .textTertiary : .textPrimary)
            .strikethrough(row.checked)
            .italic(row.kind == .quote)
            .lineLimit(1...)
            .frame(maxWidth: .infinity, alignment: .leading)
            .focused($focusedRowId, equals: row.id)
            .onSubmit {
                let (head, tail) = splitAtCaret()
                onSubmitSplit(head, tail)
            }
            .onKeyPress(.delete) {
                guard caretIsAtStart else { return .ignored }
                return onBackspaceAtStart() ? .handled : .ignored
            }
            // 跨行方向键:光标贴着行界时把上下交给相邻行。行内的折行
            // 移动仍归系统 —— 判定用「贴界」,不是「按了上下」。
            .onKeyPress(.upArrow) {
                guard caretIsAtStart else { return .ignored }
                return onNavigate(.previous) ? .handled : .ignored
            }
            .onKeyPress(.downArrow) {
                guard caretIsAtEnd else { return .ignored }
                return onNavigate(.next) ? .handled : .ignored
            }
            // 兑现手势预设的光标落点(拆分 → 新行行首,并块 → 接缝)。
            // 在焦点真正到达本行的那一刻设置;晚一拍重申一次,盖过
            // TextField 自己的默认光标安置。
            .onChange(of: focusedRowId) { _, newValue in
                guard newValue == row.id, let caret = focusIntent.take(for: row.id) else { return }
                applyCaret(caret)
                Task { @MainActor in applyCaret(caret) }
            }
            .accessibilityLabel(Text(String(
                format: String(localized: "editor.outline.row_label"),
                Int64(row.depth)
            )))
            // Preserve the TextField's native writable AXValue. A custom
            // accessibilityValue would make it display-only to AX clients.
            .accessibilityIdentifier("note.row.\(row.id)")
        }

        /// 光标折叠于行首。空行永远算行首;拿不到 selection(聚焦竞态)时
        /// 保守放行,绝不误吞用户的删字。
        private var caretIsAtStart: Bool {
            if draft.isEmpty { return true }
            guard case .selection(let range) = selection?.indices else { return false }
            return range.isEmpty && range.lowerBound == draft.startIndex
        }

        /// 光标折叠于行尾,判定与行首对称。
        private var caretIsAtEnd: Bool {
            if draft.isEmpty { return true }
            guard case .selection(let range) = selection?.indices else { return false }
            return range.isEmpty && range.upperBound == draft.endIndex
        }

        /// 以当前光标把草稿一分为二。有选区时选区内容随拆分消失(与
        /// 「选中后回车」的通用语义一致);拿不到 selection 时按行尾拆,
        /// 退化为旧的"提交整行 + 插空行",绝不弄丢文本。
        private func splitAtCaret() -> (head: String, tail: String) {
            guard case .selection(let range) = selection?.indices,
                  range.lowerBound >= draft.startIndex,
                  range.upperBound <= draft.endIndex
            else { return (draft, "") }
            return (
                String(draft[..<range.lowerBound]),
                String(draft[range.upperBound...])
            )
        }

        private func applyCaret(_ caret: BlockNoteFocusIntent.Caret) {
            switch caret {
            case .start:
                selection = TextSelection(insertionPoint: draft.startIndex)
            case .end:
                selection = TextSelection(insertionPoint: draft.endIndex)
            case .offset(let offset):
                let index = draft.index(
                    draft.startIndex,
                    offsetBy: min(max(offset, 0), draft.count)
                )
                selection = TextSelection(insertionPoint: index)
            }
        }
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
