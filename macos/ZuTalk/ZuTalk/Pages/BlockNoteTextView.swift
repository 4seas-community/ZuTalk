// BlockNoteTextView.swift
// 大纲编辑器的编辑面 — 整篇一个 NSTextView
//
// 之前每行是一个独立 SwiftUI TextField,于是"跨行选中一段话复制走"这种
// 编辑器最基本的动作做不到:选区是控件的私产,跨不过控件边界。改成整篇
// 一个文本视图后,选择、复制、剪切、拖拽文本、拼写检查、输入法候选、
// 查找、系统服务菜单全部回到 AppKit 文本栈,不需要一行自研代码。
//
// 块语义(类型/深度/勾选)以段落属性的形式活在同一份 NSTextStorage 里,
// 块手势(回车拆分、行首退格并块、Tab 缩进、Markdown 记号变身)在 keyDown
// 与 didChangeText 里拦截,落地仍走 BlockNoteStore 的整份重放流水线 ——
// Rust 落盘状态依旧是唯一权威,文本视图只是编辑期的载体。

import AppKit
import SwiftUI

// MARK: - 文本视图

final class BlockNoteNSTextView: NSTextView {
    /// 块手势的宿主。视图只负责识别手势与渲染,决策与落地都在这里。
    weak var blockDelegate: BlockNoteTextViewDelegate?

    // MARK: 记号绘制

    /// 圆点、方框、引用竖条画在文本之前的记号栏里。走 draw(_:) 而不是
    /// 文本附件:附件会进入字符流,跨行复制时把记号一起带走,而记号是
    /// 渲染不是内容。
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let layoutManager, let textContainer, let textStorage else { return }
        let origin = textContainerOrigin
        let glyphRange = layoutManager.glyphRange(forBoundingRect: dirtyRect, in: textContainer)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let text = textStorage.string as NSString

        var location = charRange.location
        // 从命中范围的段首开始,免得半个段落被跳过。
        if location > 0 {
            location = text.paragraphRange(for: NSRange(location: location, length: 0)).location
        }
        while location < NSMaxRange(charRange) {
            let paragraph = text.paragraphRange(for: NSRange(location: location, length: 0))
            drawMarker(
                paragraphRange: paragraph,
                storage: textStorage,
                layoutManager: layoutManager,
                container: textContainer,
                origin: origin
            )
            let next = NSMaxRange(paragraph)
            if next <= location { break }
            location = next
        }
    }

    private func drawMarker(
        paragraphRange: NSRange,
        storage: NSTextStorage,
        layoutManager: NSLayoutManager,
        container: NSTextContainer,
        origin: NSPoint
    ) {
        guard paragraphRange.location < storage.length else { return }
        let attributes = storage.attributes(at: paragraphRange.location, effectiveRange: nil)
        guard let raw = attributes[.blockKind] as? Int,
              let kind = BlockNoteDocument.kindFromRawValue(raw)
        else { return }
        let depth = attributes[.blockDepth] as? Int ?? 0
        let checked = attributes[.blockChecked] as? Bool ?? false

        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: paragraphRange.location, length: 0),
            actualCharacterRange: nil
        )
        var lineRect = layoutManager.lineFragmentRect(
            forGlyphAt: glyphRange.location,
            effectiveRange: nil
        )
        lineRect.origin.x += origin.x
        lineRect.origin.y += origin.y

        guard BlockNoteDocument.drawsMarker(kind) else { return }
        let x = origin.x + CGFloat(depth) * BlockNoteDocument.indentStep
        let markerRect = NSRect(
            x: x,
            y: lineRect.minY,
            width: BlockNoteDocument.markerWidth,
            height: lineRect.height
        )

        // 空行不画记号 —— 一行还没写字就先给它一个圆点,是纯粹的视觉
        // 噪音。蓝本的 `:empty` 规则同样只保留行高、不出记号。
        let isEmptyLine = paragraphRange.length <= 1
        switch kind {
        case .bullet:
            // 层级只靠缩进表达,记号形状始终一致 —— 深一层就换个空心圈
            // 会把一份清单读成两种东西。
            if !isEmptyLine { drawBullet(in: markerRect) }
        case .task:
            drawCheckbox(in: markerRect, checked: checked)
        case .quote:
            NSColor.tertiaryLabelColor.setFill()
            NSRect(x: x + 6, y: lineRect.minY + 1, width: 2, height: lineRect.height - 2).fill()
        case .paragraph, .heading1, .heading2, .heading3, .divider, .code:
            // 段落不带记号。这是蓝本的默认,也是"笔记"与"大纲"的分界:
            // 一段普通文字就是一段文字,圆点是用户主动要的(打 `- `),
            // 不是每敲一行就发给他一个。
            break
        }
    }

    private func drawBullet(in rect: NSRect) {
        let size: CGFloat = 5
        let dot = NSRect(
            x: rect.midX - size / 2,
            y: rect.midY - size / 2,
            width: size,
            height: size
        )
        NSColor.tertiaryLabelColor.setFill()
        NSBezierPath(ovalIn: dot).fill()
    }

    private func drawCheckbox(in rect: NSRect, checked: Bool) {
        let size: CGFloat = 12
        let box = NSRect(
            x: rect.midX - size / 2,
            y: rect.midY - size / 2,
            width: size,
            height: size
        )
        let path = NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3)
        if checked {
            NSColor.controlAccentColor.setFill()
            path.fill()
            let check = NSBezierPath()
            check.move(to: NSPoint(x: box.minX + 3, y: box.midY))
            check.line(to: NSPoint(x: box.midX - 0.5, y: box.minY + 3))
            check.line(to: NSPoint(x: box.maxX - 2.5, y: box.maxY - 3))
            check.lineWidth = 1.6
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            NSColor.white.setStroke()
            check.stroke()
        } else {
            NSColor.tertiaryLabelColor.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    // MARK: 空文档占位

    /// 文档为空时在第一行位置画一句提示。NSTextView 没有 placeholder,
    /// 而一个完全空白的编辑面看不出可以往里写字。
    var placeholderText: String = ""

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard (textStorage?.length ?? 0) == 0, !placeholderText.isEmpty else { return }
        let origin = textContainerOrigin
        let attributes: [NSAttributedString.Key: Any] = [
            .font: BlockNoteDocument.font(for: .paragraph),
            .foregroundColor: NSColor.placeholderTextColor,
        ]
        NSAttributedString(string: placeholderText, attributes: attributes).draw(
            at: NSPoint(x: origin.x + BlockNoteDocument.markerWidth, y: origin.y)
        )
    }

    // MARK: 无障碍

    /// 编辑面对 VoiceOver 是一个可写的文本区域。NSTextView 原生就报
    /// AXTextArea 且 AXValue 可写,这里只补一个说明性的标签,不覆盖
    /// value —— 自定义 value 会把它变成只读。
    override func accessibilityLabel() -> String? {
        String(localized: "editor.outline.canvas_label")
    }

    override func accessibilityIdentifier() -> String {
        "note.canvas"
    }

    // MARK: 记号栏点击

    /// 点在记号栏上的复选框 → 切换勾选,不移动光标。其余点击照常交给
    /// 文本系统(选择、拖拽选区、双击选词都是它的活)。
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let rowId = taskRowId(atMarker: point) {
            blockDelegate?.blockTextViewToggleChecked(rowId: rowId)
            return
        }
        super.mouseDown(with: event)
    }

    private func taskRowId(atMarker point: NSPoint) -> String? {
        guard let layoutManager, let textContainer, let textStorage else { return nil }
        let origin = textContainerOrigin
        let local = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        guard local.y >= 0 else { return nil }
        let glyphIndex = layoutManager.glyphIndex(for: local, in: textContainer)
        let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        guard charIndex < textStorage.length else { return nil }
        let paragraph = (textStorage.string as NSString)
            .paragraphRange(for: NSRange(location: charIndex, length: 0))
        guard paragraph.location < textStorage.length else { return nil }
        let attributes = textStorage.attributes(at: paragraph.location, effectiveRange: nil)
        guard let raw = attributes[.blockKind] as? Int,
              BlockNoteDocument.kindFromRawValue(raw) == .task,
              let rowId = attributes[.blockRowId] as? String
        else { return nil }
        let depth = attributes[.blockDepth] as? Int ?? 0
        let markerMinX = origin.x + CGFloat(depth) * BlockNoteDocument.indentStep
        let markerMaxX = markerMinX + BlockNoteDocument.markerWidth
        return (point.x >= markerMinX && point.x <= markerMaxX) ? rowId : nil
    }

    // MARK: 块手势

    override func keyDown(with event: NSEvent) {
        guard let blockDelegate else {
            super.keyDown(with: event)
            return
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let noModifiers = flags.subtracting([.function, .numericPad]).isEmpty

        switch event.keyCode {
        case 48 where noModifiers: // Tab
            if blockDelegate.blockTextViewIndent(outdent: false) { return }
        case 48 where flags == .shift:
            if blockDelegate.blockTextViewIndent(outdent: true) { return }
        case 36 where noModifiers: // Return
            if blockDelegate.blockTextViewSplitAtCaret() { return }
        case 51 where noModifiers: // Delete(退格)
            if caretIsAtParagraphStart, blockDelegate.blockTextViewBackspaceAtStart() { return }
        default:
            break
        }
        super.keyDown(with: event)
    }

    /// 光标折叠且贴在段首。有选区时永远不是 —— 那是普通的"删掉选中"。
    var caretIsAtParagraphStart: Bool {
        let range = selectedRange()
        guard range.length == 0, let textStorage else { return false }
        guard range.location <= textStorage.length else { return false }
        let paragraph = (textStorage.string as NSString).paragraphRange(for: range)
        return range.location == paragraph.location
    }

    /// 当前光标(或选区起点)所在段落。
    var caretParagraphRange: NSRange? {
        guard let textStorage else { return nil }
        let range = selectedRange()
        guard range.location <= textStorage.length else { return nil }
        return (textStorage.string as NSString).paragraphRange(for: range)
    }

    // MARK: 复制序列化

    /// 跨行复制放进剪贴板的是带 Markdown 记号的文本,而不是渲染后的
    /// 裸文字:复制一份清单粘到别处仍是一份清单。选区在段落中间时只带
    /// 选中的那截,不替用户补记号。
    override func writeSelection(
        to pasteboard: NSPasteboard,
        types: [NSPasteboard.PasteboardType]
    ) -> Bool {
        guard let markdown = blockDelegate?.blockTextViewMarkdownForSelection() else {
            return super.writeSelection(to: pasteboard, types: types)
        }
        pasteboard.clearContents()
        pasteboard.setString(markdown, forType: .string)
        return true
    }
}

// MARK: - 手势委托

@MainActor
protocol BlockNoteTextViewDelegate: AnyObject {
    /// 返回 true 表示手势已被块层消化,不再交给文本系统。
    func blockTextViewSplitAtCaret() -> Bool
    func blockTextViewBackspaceAtStart() -> Bool
    func blockTextViewIndent(outdent: Bool) -> Bool
    func blockTextViewToggleChecked(rowId: String)
    /// 选区的 Markdown 序列化;nil 表示交回系统默认复制。
    func blockTextViewMarkdownForSelection() -> String?
}
