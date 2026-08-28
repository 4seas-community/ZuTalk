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
    /// 鼠标是否在编辑区内。工具条据此淡入淡出。
    @State private var isHoveringEditor = false

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
                    // 整篇一个文本视图:跨行选择、复制、剪切、拖拽文本、
                    // 拼写检查、输入法、查找全部走系统文本栈。块语义以
                    // 段落属性活在同一份 storage 里。
                    BlockNoteTextCanvas(
                        store: store,
                        authorityEpoch: store.authorityEpoch
                    )
                }
                .onHover { isHoveringEditor = $0 }
                // ⌘] / ⌘[ / ⌘Z 仍挂在不可见按钮上,作用于当前段落。
                .background(indentShortcuts)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 文档随 route 切换时重开;open 内部先 close 旧句柄,不会泄漏。
        .task(id: source) {
            source.open(in: store)
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
                store.undo(focusedRowId: nil)
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
                disabled: false
            ) {
                store.outdentFocused()
            }
            stripButton(
                systemImage: "increase.indent",
                label: String(localized: "editor.outline.indent"),
                shortcutHint: "\u{21E5} / \u{2318}]",
                disabled: false
            ) {
                store.indentFocused()
            }
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.top, Spacing.xs)
        // 工具条是写作面的附属,不是它的标题。压到接近透明,鼠标移进
        // 编辑区才浮现 —— 沉浸感来自"页面上除了字什么都没有"。
        .opacity(isHoveringEditor ? 1 : 0.28)
        .animation(.easeOut(duration: 0.15), value: isHoveringEditor)
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
                store.indentFocused()
            }
            .keyboardShortcut("]", modifiers: .command)

            Button(String(localized: "editor.outline.outdent")) {
                store.outdentFocused()
            }
            .keyboardShortcut("[", modifiers: .command)

            Button(String(localized: "editor.outline.indent")) {
                store.indentFocused()
            }
            .keyboardShortcut(.tab, modifiers: [])

            Button(String(localized: "editor.outline.outdent")) {
                store.outdentFocused()
            }
            .keyboardShortcut(.tab, modifiers: .shift)

            // ⌘Z / ⇧⌘Z:文档层撤销。行内草稿的「打字撤销」也归这里——
            // 聚焦行草稿有未提交改动时,第一下先把草稿刷回权威文本,
            // 第二下才回退上一个手势(两段式,见 BlockNoteStore.undo)。
            Button(String(localized: "editor.outline.undo")) {
                store.undo(focusedRowId: nil)
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
