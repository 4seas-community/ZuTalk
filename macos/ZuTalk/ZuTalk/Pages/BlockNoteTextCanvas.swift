// BlockNoteTextCanvas.swift
// 统一文本编辑面的 SwiftUI 宿主
//
// 把 BlockNoteNSTextView 接进 SwiftUI,并把块手势翻译成 BlockNoteStore
// 的编辑手势。数据流向:
//
//   store.rows ──(权威变化)──▶ 重建 NSTextStorage
//   用户输入 ──▶ NSTextStorage ──(coalesce)──▶ 派生行 ──▶ store.apply
//
// 重建只在权威真的换人时发生(打开文档、撤销、并块/拆分这类结构手势),
// 普通打字不重建 —— 否则每敲一个字光标都会被重置。

import AppKit
import SwiftUI

struct BlockNoteTextCanvas: NSViewRepresentable {
    @ObservedObject var store: BlockNoteStore
    /// 权威纪元 + 结构纪元:任一变化都要求重建文本。
    let authorityEpoch: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(store: store)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true

        let textView = BlockNoteNSTextView(frame: .zero)
        textView.blockDelegate = context.coordinator
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = false // 撤销归文档层(Loro),不走 NSUndoManager
        textView.isEditable = true
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.textContainerInset = NSSize(width: 24, height: 20)
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.placeholderText = String(localized: "editor.outline.placeholder")
        textView.typingAttributes = BlockNoteDocument.attributes(
            for: FfiOutlineRow(id: "", depth: 0, text: "", kind: .paragraph, checked: false)
        )

        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.rebuild(rows: store.rows)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.store = store
        context.coordinator.syncIfNeeded(rows: store.rows, authorityEpoch: authorityEpoch)
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, BlockNoteTextViewDelegate {
        var store: BlockNoteStore
        weak var textView: BlockNoteNSTextView?

        /// 最近一次重建所用的权威纪元与行签名。签名相同就不重建,
        /// 避免自己派生出去的行回流时把光标打回原形。
        private var lastAuthorityEpoch = -1
        private var lastRowSignature = ""
        /// 正在由我们自己改文本:此时的 didChangeText 不再派生回写。
        private var isApplyingProgrammatically = false

        init(store: BlockNoteStore) {
            self.store = store
        }

        // MARK: 同步

        func syncIfNeeded(rows: [FfiOutlineRow], authorityEpoch: Int) {
            let signature = Self.signature(of: rows)
            guard authorityEpoch != lastAuthorityEpoch || signature != lastRowSignature else {
                return
            }
            // 结构相同、只是文本被我们自己刚写回去的情况已由签名挡掉;
            // 走到这里说明权威确实换了内容。
            rebuild(rows: rows)
        }

        func rebuild(rows: [FfiOutlineRow]) {
            guard let textView, let storage = textView.textStorage else { return }
            let selected = textView.selectedRange()
            isApplyingProgrammatically = true
            storage.beginEditing()
            storage.setAttributedString(BlockNoteDocument.attributedString(rows: rows))
            storage.endEditing()
            isApplyingProgrammatically = false
            let clamped = NSRange(
                location: min(selected.location, storage.length),
                length: 0
            )
            textView.setSelectedRange(clamped)
            textView.needsDisplay = true
            lastRowSignature = Self.signature(of: rows)
            lastAuthorityEpoch = store.authorityEpoch
        }

        /// 行签名只含结构与文本,不含身份:同一份内容重建出的行 id 会变,
        /// 用 id 做签名会导致每次回流都重建。
        private static func signature(of rows: [FfiOutlineRow]) -> String {
            rows.map { row in
                "\(row.depth)|\(BlockNoteDocument.kindRawValue(row.kind))|\(row.checked ? 1 : 0)|\(row.text)"
            }
            .joined(separator: "\u{1F}")
        }

        // MARK: 文本 → 行

        func textViewDidChangeSelection(_ notification: Notification) {
            store.noteFocusedRow(currentRowId())
        }

        /// 光标所在段落的行 id。
        private func currentRowId() -> String? {
            guard let textView, let storage = textView.textStorage,
                  let paragraph = textView.caretParagraphRange,
                  paragraph.location < storage.length
            else { return nil }
            return storage.attributes(at: paragraph.location, effectiveRange: nil)[.blockRowId]
                as? String
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingProgrammatically, let textView, let storage = textView.textStorage
            else { return }
            // 段落属性只挂在段首字符上,新输入的字符继承的是插入点属性;
            // 先把每个段落的属性抹平,再派生,避免"半个段落是标题"。
            normalizeParagraphAttributes(storage)
            let rows = BlockNoteDocument.rows(from: storage)
            lastRowSignature = Self.signature(of: rows)
            lastAuthorityEpoch = store.authorityEpoch
            store.applyDerivedRows(rows)
            applyMarkdownPrefixIfAny(textView: textView, storage: storage)
            textView.needsDisplay = true
        }

        /// 把段首属性铺满整个段落。用户在段中输入时 AppKit 会继承左邻
        /// 字符的属性,通常正确;但粘贴与输入法提交可能带进别的属性,
        /// 铺一遍才保证"一个段落一种块类型"。
        private func normalizeParagraphAttributes(_ storage: NSTextStorage) {
            let text = storage.string as NSString
            guard storage.length > 0 else { return }
            isApplyingProgrammatically = true
            storage.beginEditing()
            var location = 0
            while location < storage.length {
                let paragraph = text.paragraphRange(for: NSRange(location: location, length: 0))
                let attributes = storage.attributes(at: paragraph.location, effectiveRange: nil)
                if attributes[.blockKind] != nil {
                    storage.setAttributes(attributes, range: paragraph)
                }
                let next = NSMaxRange(paragraph)
                if next <= location { break }
                location = next
            }
            storage.endEditing()
            isApplyingProgrammatically = false
        }

        /// 行首 Markdown 记号 + 空格 → 块类型。只从段落出发,否则标题里
        /// 打不出一个真的 `# `。
        private func applyMarkdownPrefixIfAny(
            textView: BlockNoteNSTextView,
            storage: NSTextStorage
        ) {
            guard let paragraph = textView.caretParagraphRange,
                  paragraph.location < storage.length
            else { return }
            let attributes = storage.attributes(at: paragraph.location, effectiveRange: nil)
            guard let raw = attributes[.blockKind] as? Int,
                  BlockNoteDocument.kindFromRawValue(raw) == .paragraph,
                  let rowId = attributes[.blockRowId] as? String
            else { return }
            let text = (storage.string as NSString).substring(with: paragraph)
                .trimmingCharacters(in: .newlines)
            guard let hit = BlockNoteStore.markdownPrefix(text) else { return }
            store.applyMarkdownPrefix(
                rowId: rowId,
                kind: hit.kind,
                checked: hit.checked,
                text: hit.rest
            )
            rebuild(rows: store.rows)
            // 光标落在被吃掉记号之后的位置 —— 用户接着打的字要接在
            // 记号之后,不是行首。
            placeCaret(atRow: rowId, offset: hit.rest.count)
        }

        // MARK: 块手势

        func blockTextViewSplitAtCaret() -> Bool {
            guard let textView, let storage = textView.textStorage,
                  let paragraph = textView.caretParagraphRange,
                  paragraph.location < storage.length
            else { return false }
            let attributes = storage.attributes(at: paragraph.location, effectiveRange: nil)
            guard let rowId = attributes[.blockRowId] as? String,
                  let raw = attributes[.blockKind] as? Int,
                  let kind = BlockNoteDocument.kindFromRawValue(raw)
            else { return false }

            let selection = textView.selectedRange()
            let text = storage.string as NSString
            let bodyEnd = paragraphBodyEnd(paragraph, in: text)
            let headRange = NSRange(
                location: paragraph.location,
                length: max(0, min(selection.location, bodyEnd) - paragraph.location)
            )
            let tailStart = min(max(NSMaxRange(selection), paragraph.location), bodyEnd)
            let tailRange = NSRange(location: tailStart, length: max(0, bodyEnd - tailStart))
            let head = text.substring(with: headRange)
            let tail = text.substring(with: tailRange)

            // 空清单行上的回车是清单的出口。
            if head.isEmpty, tail.isEmpty, BlockNoteStore.emptySubmitExitsList(kind: kind) {
                store.setKind(rowId: rowId, kind: .paragraph)
                rebuild(rows: store.rows)
                placeCaret(atRow: rowId, offset: 0)
                return true
            }
            guard let newRowId = store.splitRow(rowId: rowId, head: head, tail: tail) else {
                return false
            }
            rebuild(rows: store.rows)
            placeCaret(atRow: newRowId, offset: 0)
            return true
        }

        func blockTextViewBackspaceAtStart() -> Bool {
            guard let textView, let storage = textView.textStorage,
                  let paragraph = textView.caretParagraphRange,
                  paragraph.location < storage.length
            else { return false }
            let attributes = storage.attributes(at: paragraph.location, effectiveRange: nil)
            guard let rowId = attributes[.blockRowId] as? String,
                  let raw = attributes[.blockKind] as? Int,
                  let kind = BlockNoteDocument.kindFromRawValue(raw)
            else { return false }

            // 非段落行先降回段落:一下退格就把标题并进上一行是最容易
            // 误伤的手势,给它加一格。
            if kind != .paragraph {
                store.setKind(rowId: rowId, kind: .paragraph)
                rebuild(rows: store.rows)
                placeCaret(atRow: rowId, offset: 0)
                return true
            }
            guard let index = store.rows.firstIndex(where: { $0.id == rowId }), index > 0 else {
                // 首行行首:吞掉退格,免得系统再删一个字。
                return true
            }
            let joinOffset = store.rows[index - 1].text.count
            let body = (storage.string as NSString)
                .substring(with: paragraph)
                .trimmingCharacters(in: .newlines)
            guard let previousId = store.mergeWithPreviousRow(rowId: rowId, draftText: body) else {
                return true
            }
            rebuild(rows: store.rows)
            placeCaret(atRow: previousId, offset: joinOffset)
            return true
        }

        func blockTextViewIndent(outdent: Bool) -> Bool {
            guard let textView, let storage = textView.textStorage else { return false }
            // 选区跨多行时整体缩进 —— 编辑器里选中一段再按 Tab 是常态。
            let selection = textView.selectedRange()
            let text = storage.string as NSString
            let span = text.paragraphRange(for: selection)
            var rowIds: [String] = []
            var location = span.location
            while location < NSMaxRange(span), location < storage.length {
                let paragraph = text.paragraphRange(for: NSRange(location: location, length: 0))
                if let rowId = storage.attributes(at: paragraph.location, effectiveRange: nil)[.blockRowId] as? String {
                    rowIds.append(rowId)
                }
                let next = NSMaxRange(paragraph)
                if next <= location { break }
                location = next
            }
            guard !rowIds.isEmpty else { return false }
            for rowId in rowIds {
                if outdent {
                    store.outdent(rowId: rowId)
                } else {
                    store.indent(rowId: rowId)
                }
            }
            let caret = textView.selectedRange()
            rebuild(rows: store.rows)
            textView.setSelectedRange(NSRange(
                location: min(caret.location, storage.length),
                length: min(caret.length, storage.length - min(caret.location, storage.length))
            ))
            return true
        }

        func blockTextViewToggleChecked(rowId: String) {
            store.toggleChecked(rowId: rowId)
            rebuild(rows: store.rows)
        }

        func blockTextViewMarkdownForSelection() -> String? {
            guard let textView, let storage = textView.textStorage else { return nil }
            let selection = textView.selectedRange()
            guard selection.length > 0 else { return nil }
            let text = storage.string as NSString
            let span = text.paragraphRange(for: selection)
            // 选区落在单个段落内部:复制的是那截字,不替用户补记号。
            if span.location <= selection.location,
               NSMaxRange(span) >= NSMaxRange(selection),
               text.paragraphRange(for: NSRange(location: selection.location, length: 0))
                == text.paragraphRange(for: NSRange(location: NSMaxRange(selection), length: 0)) {
                return nil
            }
            let sub = storage.attributedSubstring(from: span)
            return BlockNoteDocument.markdownText(for: BlockNoteDocument.rows(from: sub))
        }

        // MARK: 光标

        /// 把光标放到某一行的第 offset 个字符处。行 id 是权威身份,
        /// 重建之后位置会变,所以定位一律按 id 重新查。
        private func placeCaret(atRow rowId: String, offset: Int) {
            guard let textView, let storage = textView.textStorage else { return }
            let text = storage.string as NSString
            var location = 0
            while location < storage.length {
                let paragraph = text.paragraphRange(for: NSRange(location: location, length: 0))
                let attributes = storage.attributes(at: paragraph.location, effectiveRange: nil)
                if attributes[.blockRowId] as? String == rowId {
                    let bodyEnd = paragraphBodyEnd(paragraph, in: text)
                    let target = min(paragraph.location + max(0, offset), bodyEnd)
                    textView.setSelectedRange(NSRange(location: target, length: 0))
                    textView.scrollRangeToVisible(NSRange(location: target, length: 0))
                    return
                }
                let next = NSMaxRange(paragraph)
                if next <= location { break }
                location = next
            }
        }

        /// 段落正文的结束位置(不含结尾换行)。
        private func paragraphBodyEnd(_ paragraph: NSRange, in text: NSString) -> Int {
            var end = NSMaxRange(paragraph)
            if end > paragraph.location, end <= text.length,
               text.substring(with: NSRange(location: end - 1, length: 1)) == "\n" {
                end -= 1
            }
            return end
        }
    }
}
