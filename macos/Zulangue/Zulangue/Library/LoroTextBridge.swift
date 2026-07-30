// LoroTextBridge.swift
// 双向同步 NSTextView ↔ Rust LoroDoc (CRDT 文档)
// 权威:D4 §6.5, D5 §7.5
//
// 这个桥让 NSTextView 的本地编辑与 Rust 持有的 Loro 文档保持一致。
// Swift 只转发用户编辑并渲染 Rust 回调；文档持久化与 transcript projection
// 仍由 Rust 负责。

import AppKit
import Combine

/// LoroTextBridge — NSTextView 的文本编辑双向同步到 Rust 侧 LoroDoc
final class LoroTextBridge: NSObject, NSTextStorageDelegate {
    let notebookId: String
    let tabId: String
    private weak var textView: NSTextView?

    /// 防回环标志:Loro→UI 更新期间为 true
    private var suppressLoroSync = false

    /// 当前 generation，用于避免回环合并。
    private var currentGeneration: UInt64 = 0

    /// 上次快照内容(计算 replace 的 old len 用)
    private var lastContent: String = ""

    /// 本 bridge 自己发出的 `core.applyEdit` 数量，用于抵扣对应 callback，
    /// 避免不必要的整文档 setAttributedString。
    /// Rust 的 apply_edit 无条件 notify(因为 transcript projection 等其它
    /// 订阅者需要知道),NSTextView 是事件源,不需要被回灌。
    /// 严格 1:1 对应:每成功调一次 core.applyEdit 就 +1,每收到一次 onDocChanged 就 -1。
    private var pendingSelfNotifications: Int = 0

    /// 渲染样式(Delta → NSAttributedString 时用)
    let renderStyle: LoroRenderStyle

    private init(
        notebookId: String,
        tabId: String,
        textView: NSTextView,
        renderStyle: LoroRenderStyle
    ) {
        self.notebookId = notebookId
        self.tabId = tabId
        self.textView = textView
        self.renderStyle = renderStyle
        super.init()
        textView.textStorage?.delegate = self
    }

    @MainActor
    static func attach(
        notebookId: String,
        tabId: String,
        textView: NSTextView
    ) throws -> LoroTextBridge {
        try attach(
            notebookId: notebookId,
            tabId: tabId,
            textView: textView,
            renderStyle: .default
        )
    }

    /// 工厂:打开 Rust 侧 Loro editor + 初始化 NSTextView 内容 + 挂 delegate
    /// + 注册 FfiEditorCallback，由 Rust 推送文档变化。
    @MainActor
    static func attach(
        notebookId: String,
        tabId: String,
        textView: NSTextView,
        renderStyle: LoroRenderStyle
    ) throws -> LoroTextBridge {
        guard let core = CoreClient.shared.core else {
            throw LoroTextBridgeError.coreUnavailable(CoreClient.shared.initError ?? "core init failed")
        }

        // 打开文档(已存在则复用,EditorBridge 侧 insert 会覆盖旧 session 无副作用)
        try core.openEditor(notebookId: notebookId, tabId: tabId)

        let bridge = LoroTextBridge(
            notebookId: notebookId,
            tabId: tabId,
            textView: textView,
            renderStyle: renderStyle
        )

        // 初次渲染:拉 delta 铺到 NSTextView(带属性)
        bridge.suppressLoroSync = true
        let deltaJson = try core.getEditorDelta(notebookId: notebookId, tabId: tabId)
        let segments = LoroDeltaParser.parse(deltaJson)
        let attributed = LoroAttributedStringBuilder.build(segments: segments, style: renderStyle)
        textView.textStorage?.setAttributedString(attributed)
        bridge.lastContent = attributed.string
        bridge.suppressLoroSync = false

        // 复用 textView 切换文档时，重置 typingAttributes，避免继承前一文档样式。
        // 光标回起点;selectedTextAttributes / insertionPointColor 等保持。
        textView.typingAttributes = [
            .font: NSFont.systemFont(ofSize: renderStyle.baseFontSize),
            .foregroundColor: renderStyle.textColor,
            .paragraphStyle: renderStyle.paragraphStyle(),
        ]
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        // Rust → Swift push 通道
        let cb = LoroEditorCallbackImpl(bridge: bridge)
        try core.registerEditorCallback(notebookId: notebookId, tabId: tabId, callback: cb)

        return bridge
    }

    // MARK: - NSTextView → Loro

    @MainActor
    func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard !suppressLoroSync else { return }
        guard editedMask.contains(.editedCharacters) else { return }

        // 使用 editedRange + delta 生成精确的 Insert/Delete/Replace 操作，
        // 避免整文档替换并保留 CRDT 合并语义。
        pushIncremental(
            newContent: textStorage.string,
            editedRange: editedRange,
            delta: delta
        )
    }

    /// 把单次 NSTextStorage 编辑翻译为对应的 Loro op。
    ///
    /// NSTextStorage delegate 的语义:
    ///   · editedRange:编辑**后**,新字符占据的 UTF-16 range(插入 / 替换时)
    ///     或一个空 range(纯删除时,location 指向删除点)
    ///   · delta:newLength - oldLength
    ///   · oldUtf16Len = editedRange.length - delta 是这个位置**编辑前**的 utf16 长度
    ///
    /// 转成 Loro op 时要把 utf16 offset 转成 scalar offset:
    ///   · scalar 位置 at editedRange.location:editedRange.location 之前的文本
    ///     编辑前后相同,所以用 lastContent 或 newContent 都可以,用 lastContent
    ///   · 删除的 scalar 数:lastContent 在 oldUtf16Range 里的 scalar 差
    ///   · 插入的文字:newContent 在 editedRange 内的子串
    @MainActor
    private func pushIncremental(newContent: String, editedRange: NSRange, delta: Int) {
        guard CoreClient.shared.core != nil else { return }

        let oldUtf16Len = editedRange.length - delta

        // UTF-16 → scalar offset
        let scalarPos = LoroOffsetConverter.scalarOffset(
            in: lastContent,
            utf16Offset: editedRange.location
        )
        let oldScalarEnd = LoroOffsetConverter.scalarOffset(
            in: lastContent,
            utf16Offset: editedRange.location + oldUtf16Len
        )
        let deletedScalars = max(oldScalarEnd - scalarPos, 0)

        // 插入的文本
        let insertedText: String
        if editedRange.length > 0 {
            let nsNew = newContent as NSString
            let clampedLen = min(editedRange.length, nsNew.length - editedRange.location)
            if clampedLen > 0 {
                insertedText = nsNew.substring(
                    with: NSRange(location: editedRange.location, length: clampedLen)
                )
            } else {
                insertedText = ""
            }
        } else {
            insertedText = ""
        }

        if deletedScalars == 0 && insertedText.isEmpty {
            // 属性变化触发了 editedCharacters 但没有内容变更(罕见但可能)
            lastContent = newContent
            return
        }

        do {
            if deletedScalars > 0 && !insertedText.isEmpty {
                // 替换
                try sendSelfEdit(
                    .replace(
                        pos: UInt64(scalarPos),
                        len: UInt64(deletedScalars),
                        text: insertedText
                    )
                )
            } else if !insertedText.isEmpty {
                // 纯插入
                try sendSelfEdit(.insert(pos: UInt64(scalarPos), text: insertedText))
            } else {
                // 纯删除
                try sendSelfEdit(.delete(pos: UInt64(scalarPos), len: UInt64(deletedScalars)))
            }
            lastContent = newContent

            // 插入带有可映射的富文本属性时，把 NSTextStorage 属性
            // 回写成 Loro mark。这样:
            //   · 粘贴富文本仍能完整落盘
            //   · 空光标点 B/I/H1 后输入第一个字符也会真的变成 mark,不只是假视觉
            if !insertedText.isEmpty, rangeNeedsAttributePropagation(editedRange: editedRange) {
                propagateAttributesToLoro(editedRange: editedRange)
            }
        } catch {
            // 文档切换期间，delegate 可能在新 bridge 完成 attach 前触发一次。
            // 这个短暂状态不显示 Toast；其他错误照常报告。
            let msg = "\(error)"
            if msg.contains("session not open") {
                // 下一次 attach 成功后 lastContent 会被 refreshFromDelta 对齐
                return
            }
            DebugLog.error("pushIncremental failed", detail: msg)
            // 兜底:下一次编辑时 lastContent 可能 drift,下次整文档 resync 一下
            // (但不现在 replace,避免掉进 CRDT 陷阱)
        }
    }

    /// 把刚粘贴的 UTF-16 range 内每段属性转成 Loro mark op。
    /// 只处理可映射的常见属性(bold / italic / code / strike / heading by size / list)。
    private func rangeNeedsAttributePropagation(editedRange: NSRange) -> Bool {
        guard let textView = textView,
              let storage = textView.textStorage
        else { return false }

        let nsString = textView.string as NSString
        let clampedEnd = min(editedRange.location + editedRange.length, nsString.length)
        guard clampedEnd > editedRange.location else { return false }
        let scan = NSRange(location: editedRange.location, length: clampedEnd - editedRange.location)

        var needsPropagation = false
        storage.enumerateAttributes(in: scan, options: []) { attrs, _, stop in
            if attributesContainMappableMarks(attrs) {
                needsPropagation = true
                stop.pointee = true
            }
        }
        return needsPropagation
    }

    private func attributesContainMappableMarks(_ attrs: [NSAttributedString.Key: Any]) -> Bool {
        if let font = attrs[.font] as? NSFont {
            let traits = font.fontDescriptor.symbolicTraits
            if traits.contains(.bold) || traits.contains(.italic) || traits.contains(.monoSpace) {
                return true
            }
            if font.pointSize >= 15 {
                return true
            }
        }
        if let strikeNum = attrs[.strikethroughStyle] as? NSNumber, strikeNum.intValue != 0 {
            return true
        }
        if let strikeInt = attrs[.strikethroughStyle] as? Int, strikeInt != 0 {
            return true
        }
        if let paraStyle = attrs[.paragraphStyle] as? NSParagraphStyle, !paraStyle.textLists.isEmpty {
            return true
        }
        return false
    }

    private func propagateAttributesToLoro(editedRange: NSRange) {
        guard let textView = textView,
              let storage = textView.textStorage
        else { return }

        let nsString = textView.string as NSString
        let clampedEnd = min(editedRange.location + editedRange.length, nsString.length)
        guard clampedEnd > editedRange.location else { return }
        let scan = NSRange(
            location: editedRange.location,
            length: clampedEnd - editedRange.location
        )

        storage.enumerateAttributes(in: scan, options: []) { attrs, sub, _ in
            let (pos, len) = LoroOffsetConverter.scalarRange(
                in: textView.string,
                utf16Range: sub
            )
            guard len > 0 else { return }

            // font → bold / italic / code / heading
            if let font = attrs[.font] as? NSFont {
                let traits = font.fontDescriptor.symbolicTraits
                if traits.contains(.bold) {
                    _ = try? sendSelfEdit(
                        .mark(pos: pos, len: len, key: LoroMarkKey.bold, valueJson: LoroMarkValue.trueJson)
                    )
                }
                if traits.contains(.italic) {
                    _ = try? sendSelfEdit(
                        .mark(pos: pos, len: len, key: LoroMarkKey.italic, valueJson: LoroMarkValue.trueJson)
                    )
                }
                if traits.contains(.monoSpace) {
                    _ = try? sendSelfEdit(
                        .mark(pos: pos, len: len, key: LoroMarkKey.code, valueJson: LoroMarkValue.trueJson)
                    )
                }
                // heading detection by size(和 LoroRenderStyle 阈值一致)
                let sz = font.pointSize
                let headingLevel: Int? = {
                    if sz >= 21 { return 1 }
                    if sz >= 17 { return 2 }
                    if sz >= 15 { return 3 }
                    return nil
                }()
                if let lv = headingLevel {
                    _ = try? sendSelfEdit(
                        .mark(pos: pos, len: len, key: LoroMarkKey.heading, valueJson: LoroMarkValue.int(lv))
                    )
                }
            }

            // strikethrough
            if let strikeNum = attrs[.strikethroughStyle] as? NSNumber, strikeNum.intValue != 0 {
                _ = try? sendSelfEdit(
                    .mark(pos: pos, len: len, key: LoroMarkKey.strikethrough, valueJson: LoroMarkValue.trueJson)
                )
            }

            // paragraphStyle.textLists → list mark
            if let listStyle = LoroListStyle.fromAttributes(attrs) {
                _ = try? sendSelfEdit(
                    .mark(
                        pos: pos,
                        len: len,
                        key: LoroMarkKey.list,
                        valueJson: listStyle.valueJson
                    )
                )
            }
        }
    }

    /// 包装 core.applyEdit，并只在成功后把
    /// `pendingSelfNotifications` +1,callback 回来时 -1 + skip。严格 1:1。
    /// 失败时不 +1,避免计数累积吞掉后续 Rust projection 的合法通知。
    @MainActor
    @discardableResult
    fileprivate func sendSelfEdit(_ op: FfiEditOp) throws -> Bool {
        guard let core = CoreClient.shared.core else { return false }
        try core.applyEdit(notebookId: notebookId, tabId: tabId, op: op)
        pendingSelfNotifications += 1
        return true
    }

    /// Callback 进来时如果 counter>0,吞一次通知并 return true(表示"这是我自己发的,
    /// NSTextView 无需回灌,storage 已是最新")。其它 projection/editor
    /// 没走此 bridge)的通知 counter==0,照常 refresh。
    @MainActor
    fileprivate func consumeSelfNotificationIfAny() -> Bool {
        if pendingSelfNotifications > 0 {
            pendingSelfNotifications -= 1
            return true
        }
        return false
    }

    // MARK: - 工具栏操作(toolbar → mark/unmark)

    /// 在一段 NSRange(UTF-16)上加 mark。核心场景:用户选中文字 → 点 B/I/H1 等,
    /// 或 Markdown shortcut `#`/`-` → 整段 apply heading/list。
    ///
    /// 本地直接修改 NSAttributedString 属性，不等待 Rust callback。
    /// Rust 用户路径现在也不 notify,避免整个 storage 全量 setAttributedString —
    /// 那会造成光标跳、typingAttributes 丢失、视觉上"# 之后要一顿才变大"的迟钝。
    @MainActor
    func applyMark(key: String, valueJson: String, utf16Range: NSRange) {
        guard utf16Range.length > 0 else { return }
        guard let textView = textView, let storage = textView.textStorage else { return }

        let (pos, len) = LoroOffsetConverter.scalarRange(
            in: textView.string,
            utf16Range: utf16Range
        )
        guard len > 0 else { return }

        do {
            try sendSelfEdit(.mark(pos: pos, len: len, key: key, valueJson: valueJson))
        } catch {
            DebugLog.error("applyMark failed", detail: "\(error)")
            return
        }

        // 本地即时渲染(属性变更不会触发 pushIncremental,delegate 只看 editedCharacters)
        applyMarkAttributeLocally(
            key: key,
            valueJson: valueJson,
            utf16Range: clampedRange(utf16Range, storage: storage),
            storage: storage
        )
        refreshTypingAttributesAtCaret(textView: textView, storage: storage)
        DebugLog.info("mark \(key)=\(valueJson)", detail: "range \(pos)..\(pos + len)")
    }

    /// 移除一段 range 上的 mark。对应"关闭 bold"等。
    @MainActor
    func removeMark(key: String, utf16Range: NSRange) {
        guard utf16Range.length > 0 else { return }
        guard let textView = textView, let storage = textView.textStorage else { return }

        let (pos, len) = LoroOffsetConverter.scalarRange(
            in: textView.string,
            utf16Range: utf16Range
        )
        guard len > 0 else { return }

        do {
            try sendSelfEdit(.unmark(pos: pos, len: len, key: key))
        } catch {
            DebugLog.error("removeMark failed", detail: "\(error)")
            return
        }

        removeMarkAttributeLocally(
            key: key,
            utf16Range: clampedRange(utf16Range, storage: storage),
            storage: storage
        )
        refreshTypingAttributesAtCaret(textView: textView, storage: storage)
        DebugLog.info("unmark \(key)", detail: "range \(pos)..\(pos + len)")
    }

    /// 把 range 夹到 storage 实际长度内，防止上层传入的 range 越界。
    /// (paragraphRange 偶尔会越过末尾的 trailing newline)。
    private func clampedRange(_ range: NSRange, storage: NSTextStorage) -> NSRange {
        let total = storage.length
        let start = min(max(range.location, 0), total)
        let end = min(max(range.location + range.length, start), total)
        return NSRange(location: start, length: end - start)
    }

    /// 把 Loro mark key+value 直接转成 NSAttributedString 属性改动。
    /// 按 key 分类处理,**保留** range 内其它 mark 带来的属性(比如给 bold
    /// 文字加 italic,原 bold 不丢)。
    private func applyMarkAttributeLocally(
        key: String,
        valueJson: String,
        utf16Range: NSRange,
        storage: NSTextStorage
    ) {
        guard utf16Range.length > 0 else { return }

        storage.beginEditing()
        defer { storage.endEditing() }

        switch key {
        case LoroMarkKey.bold:
            mutateFonts(in: utf16Range, storage: storage) { font in
                Self.addTrait(.bold, to: font)
            }
        case LoroMarkKey.italic:
            mutateFonts(in: utf16Range, storage: storage) { font in
                Self.addTrait(.italic, to: font)
            }
        case LoroMarkKey.code:
            mutateFonts(in: utf16Range, storage: storage) { font in
                NSFont.monospacedSystemFont(
                    ofSize: font.pointSize,
                    weight: font.fontDescriptor.symbolicTraits.contains(.bold) ? .semibold : .regular
                )
            }
            storage.addAttribute(.backgroundColor, value: renderStyle.codeBackground, range: utf16Range)
            storage.addAttribute(.foregroundColor, value: renderStyle.codeForeground, range: utf16Range)
        case LoroMarkKey.strikethrough:
            storage.addAttribute(
                .strikethroughStyle,
                value: NSUnderlineStyle.single.rawValue,
                range: utf16Range
            )
        case LoroMarkKey.heading:
            let level = Int(valueJson) ?? 1
            let size = renderStyle.headingFontSize(level)
            mutateFonts(in: utf16Range, storage: storage) { font in
                // heading 强制 semibold + 指定字号;保留 italic trait
                let isItalic = font.fontDescriptor.symbolicTraits.contains(.italic)
                var f = NSFont.systemFont(ofSize: size, weight: .semibold)
                if isItalic {
                    let desc = f.fontDescriptor.withSymbolicTraits(.italic)
                    if let it = NSFont(descriptor: desc, size: size) { f = it }
                }
                return f
            }
            applyParagraphStyleLocally(
                in: utf16Range,
                storage: storage,
                headingLevel: level,
                listStyle: nil
            )
        case LoroMarkKey.list:
            let decodedValue = try? JSONSerialization.jsonObject(with: Data(valueJson.utf8))
            let listStyle = LoroListStyle.decode(from: decodedValue)
                ?? LoroListStyle(kind: (try? JSONDecoder().decode(String.self, from: Data(valueJson.utf8))) ?? valueJson)
            applyParagraphStyleLocally(
                in: utf16Range,
                storage: storage,
                headingLevel: nil,
                listStyle: listStyle
            )
        default:
            // 其它未知 mark — 本地不渲染，Rust 侧仍负责属性持久化。
            break
        }
    }

    /// 移除 mark 对应的本地属性，与 apply 对称。
    private func removeMarkAttributeLocally(
        key: String,
        utf16Range: NSRange,
        storage: NSTextStorage
    ) {
        guard utf16Range.length > 0 else { return }

        storage.beginEditing()
        defer { storage.endEditing() }

        switch key {
        case LoroMarkKey.bold:
            mutateFonts(in: utf16Range, storage: storage) { font in
                Self.removeTrait(.bold, from: font)
            }
        case LoroMarkKey.italic:
            mutateFonts(in: utf16Range, storage: storage) { font in
                Self.removeTrait(.italic, from: font)
            }
        case LoroMarkKey.code:
            mutateFonts(in: utf16Range, storage: storage) { font in
                // 去掉 monospaced,回到 system font(保留原有 bold/italic trait)
                let traits = font.fontDescriptor.symbolicTraits
                let weight: NSFont.Weight = traits.contains(.bold) ? .semibold : .regular
                var f = NSFont.systemFont(ofSize: font.pointSize, weight: weight)
                if traits.contains(.italic) {
                    let desc = f.fontDescriptor.withSymbolicTraits(.italic)
                    if let it = NSFont(descriptor: desc, size: font.pointSize) { f = it }
                }
                return f
            }
            storage.removeAttribute(.backgroundColor, range: utf16Range)
            storage.addAttribute(.foregroundColor, value: renderStyle.textColor, range: utf16Range)
        case LoroMarkKey.strikethrough:
            storage.removeAttribute(.strikethroughStyle, range: utf16Range)
        case LoroMarkKey.heading:
            // 回到 base 字号 + 去掉强制 semibold(保留真正的 bold/italic mark)
            mutateFonts(in: utf16Range, storage: storage) { font in
                let traits = font.fontDescriptor.symbolicTraits
                // 这里我们无法区分 bold 是来自 heading 还是独立 bold mark。
                // 保守策略:回到 base 字号 regular weight;若用户同时打了 bold,
                // 下一次 applyMark(bold) 会补回来。Rust 是权威,反正 delta 里
                // 该 bold 的还是 bold — Swift 本地偶发不准不致命。
                let weight: NSFont.Weight = .regular
                var f = NSFont.systemFont(ofSize: renderStyle.baseFontSize, weight: weight)
                if traits.contains(.italic) {
                    let desc = f.fontDescriptor.withSymbolicTraits(.italic)
                    if let it = NSFont(descriptor: desc, size: renderStyle.baseFontSize) { f = it }
                }
                return f
            }
            storage.enumerateAttribute(.font, in: utf16Range, options: []) { value, sub, _ in
                let font = (value as? NSFont) ?? NSFont.systemFont(ofSize: renderStyle.baseFontSize)
                applyParagraphStyleLocally(
                    in: sub,
                    storage: storage,
                    headingLevel: headingLevel(for: font.pointSize),
                    listStyle: LoroListStyle.fromAttributes(storage.attributes(at: sub.location, effectiveRange: nil))
                )
            }
        case LoroMarkKey.list:
            storage.enumerateAttribute(.font, in: utf16Range, options: []) { value, sub, _ in
                let font = (value as? NSFont) ?? NSFont.systemFont(ofSize: renderStyle.baseFontSize)
                applyParagraphStyleLocally(
                    in: sub,
                    storage: storage,
                    headingLevel: headingLevel(for: font.pointSize),
                    listStyle: nil
                )
            }
        default:
            break
        }
    }

    private func applyParagraphStyleLocally(
        in range: NSRange,
        storage: NSTextStorage,
        headingLevel: Int?,
        listStyle: LoroListStyle?
    ) {
        storage.addAttribute(
            .paragraphStyle,
            value: renderStyle.paragraphStyle(headingLevel: headingLevel, listStyle: listStyle),
            range: range
        )
        if let listStyle {
            storage.addAttribute(.zulangueListKind, value: listStyle.kind, range: range)
            storage.addAttribute(.zulangueListDepth, value: NSNumber(value: listStyle.depth), range: range)
        } else {
            storage.removeAttribute(.zulangueListKind, range: range)
            storage.removeAttribute(.zulangueListDepth, range: range)
        }
    }

    private func headingLevel(for pointSize: CGFloat) -> Int? {
        if pointSize >= 21 { return 1 }
        if pointSize >= 17 { return 2 }
        if pointSize >= 15 { return 3 }
        return nil
    }

    /// 枚举 range 内每个 font run,用 transform 产出新 font。
    private func mutateFonts(
        in range: NSRange,
        storage: NSTextStorage,
        transform: (NSFont) -> NSFont
    ) {
        storage.enumerateAttribute(.font, in: range, options: []) { value, sub, _ in
            let currentFont = (value as? NSFont)
                ?? NSFont.systemFont(ofSize: renderStyle.baseFontSize)
            let newFont = transform(currentFont)
            storage.addAttribute(.font, value: newFont, range: sub)
        }
    }

    /// 加上一个 symbolic trait(保留原有 trait / pointSize)。
    private static func addTrait(_ trait: NSFontDescriptor.SymbolicTraits, to font: NSFont) -> NSFont {
        let traits = font.fontDescriptor.symbolicTraits.union(trait)
        let desc = font.fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: desc, size: font.pointSize) ?? font
    }

    /// 去掉一个 symbolic trait。
    private static func removeTrait(_ trait: NSFontDescriptor.SymbolicTraits, from font: NSFont) -> NSFont {
        let traits = font.fontDescriptor.symbolicTraits.subtracting(trait)
        let desc = font.fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: desc, size: font.pointSize) ?? font
    }

    /// applyMark 后，让 typingAttributes 继承光标前一个字符的属性。
    /// 否则 NSTextView 仍用默认 font,下一个敲进去的字符会"小一圈",视觉上跳。
    ///
    /// 选 caret-1 而不是 caret 本身是因为 expand=After 语义:光标右侧字符
    /// 可能还没更新(selection range 内是 mark 后段),左侧已确定。
    private func refreshTypingAttributesAtCaret(textView: NSTextView, storage: NSTextStorage) {
        let caret = textView.selectedRange().location
        guard storage.length > 0 else { return }
        let readIndex: Int
        if caret == 0 {
            readIndex = 0
        } else {
            readIndex = min(caret - 1, storage.length - 1)
        }
        guard readIndex >= 0, readIndex < storage.length else { return }
        let attrs = storage.attributes(at: readIndex, effectiveRange: nil)
        textView.typingAttributes = attrs
    }

    /// 切换 mark(如果选区里该属性已存在就 remove,否则 apply)。
    @MainActor
    func toggleMark(key: String, valueJson: String, utf16Range: NSRange) {
        guard let textView = textView, utf16Range.length > 0 else { return }

        let attrs = textView.textStorage?.attributedSubstring(from: utf16Range)
        let hasAttribute = attrs?.hasMark(key: key) ?? false

        if hasAttribute {
            removeMark(key: key, utf16Range: utf16Range)
        } else {
            applyMark(key: key, valueJson: valueJson, utf16Range: utf16Range)
        }
    }

    // MARK: - Loro → NSTextView

    /// Rust 侧 EditorBridge 变更回调。generation 用于防止自己的编辑回灌。
    func onLoroChange(content: String, generation: UInt64) {
        guard generation != currentGeneration else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            self.suppressLoroSync = true
            defer { self.suppressLoroSync = false }

            self.currentGeneration = generation
            // 拉取最新 delta 重新渲染，以保留文本属性。
            try? self.refreshFromDelta(preservingSelection: nil)
        }
    }

    /// 从 Rust 拉 delta,用 NSAttributedString 完整重铺 NSTextView。
    ///
    /// **光标策略**:永远恢复光标点(length=0),不恢复选区。
    /// preservingSelection 如果提供,光标放到该区间的末尾(比如刚 apply 完
    /// bold 就把光标放到 bold 区间之后);不提供则用当前光标点。
    ///
    /// 恢复光标点而不是整个选区，避免下一次输入替换刚格式化的文字。
    @MainActor
    func refreshFromDelta(preservingSelection: NSRange?) throws {
        guard let core = CoreClient.shared.core else { return }
        guard let textView = textView, let storage = textView.textStorage else { return }

        // IME 正在 compose 时，textView 含有尚未提交的 marked text。
        // 如果此时 setAttributedString 整体替换 storage,marked range 被抹掉 → IME
        // 状态失效,拼音打不出。跳过这一轮,下一次刷新(IME 提交后或下次 projection)
        // 会追上。
        if textView.hasMarkedText() {
            DebugLog.info("refreshFromDelta skipped", detail: "IME marked text active")
            return
        }

        let deltaJson = try core.getEditorDelta(notebookId: notebookId, tabId: tabId)
        let segments = LoroDeltaParser.parse(deltaJson)
        let attributed = LoroAttributedStringBuilder.build(segments: segments, style: renderStyle)

        // 目标光标点:mark 区间末尾 or 当前光标
        let cursorTarget: Int = {
            if let sel = preservingSelection {
                return sel.location + sel.length
            }
            return textView.selectedRange().location
        }()

        suppressLoroSync = true
        storage.beginEditing()
        storage.setAttributedString(attributed)
        storage.endEditing()
        suppressLoroSync = false

        lastContent = attributed.string

        // 光标回到目标位置,但 length=0(不选中任何内容)
        let clampedLoc = min(max(cursorTarget, 0), attributed.length)
        textView.setSelectedRange(NSRange(location: clampedLoc, length: 0))

        // 同步 typingAttributes,让接下来输入的字符继承光标前一个字符的属性
        // (否则 NSTextView 会用它 init 时的默认 font,丢掉 bold/heading)
        if clampedLoc > 0 {
            let inherited = storage.attributes(at: clampedLoc - 1, effectiveRange: nil)
            textView.typingAttributes = inherited
        }

        // debug 诊断:storage 里的字体分布。关掉 debug mode 不会看到
        if DebugLog.isEnabled, attributed.length > 0 {
            var parts: [String] = []
            storage.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length)) { font, range, _ in
                if let f = font as? NSFont {
                    parts.append("[\(range.location)..\(range.location + range.length)] \(Int(f.pointSize))pt")
                }
            }
            DebugLog.info("render", detail: parts.prefix(4).joined(separator: " | "))
        }
    }

    // MARK: - 生命周期

    @MainActor
    func disconnect() {
        textView?.textStorage?.delegate = nil
        // Rust 在 close_editor 的引用数归零时清理 callback 注册并释放内存。
        try? CoreClient.shared.core?.closeEditor(notebookId: notebookId, tabId: tabId)
    }
}

// MARK: - Rust 推送回调的 Swift 实现

/// `FfiEditorCallback` 的 Swift 适配器 — Rust 端 apply_edit 成功后调此。
///
/// 调用可能在 UniFFI 的 worker 线程,我们 hop 到 MainActor 再走 refreshFromDelta。
/// suppressLoroSync 在 refreshFromDelta 内部保证 setAttributedString 不回灌 Rust。
final class LoroEditorCallbackImpl: FfiEditorCallback, @unchecked Sendable {
    private weak var bridge: LoroTextBridge?

    init(bridge: LoroTextBridge) {
        self.bridge = bridge
    }

    func onDocChanged(docId: String, generation: UInt64) {
        Task { @MainActor [weak bridge] in
            guard let bridge = bridge else { return }
            // Rust resolves and routes the callback from the Notebook/tab
            // identity. The raw docId is informational only and is never fed
            // back into a product editor API.
            _ = docId
            // 忽略由本 bridge 发出的 apply_edit 回流通知；NSTextView storage
            // 已经是最新,整个 setAttributedString 只会造成光标跳 + typingAttributes
            // 丢失的抖动。Rust projection 的通知 counter 为 0，会照常 refresh
            // 把 NSTextView 同步到 Rust 状态。
            if bridge.consumeSelfNotificationIfAny() { return }
            try? bridge.refreshFromDelta(preservingSelection: nil)
        }
    }
}

// MARK: - Errors

enum LoroTextBridgeError: Error, LocalizedError {
    case coreUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .coreUnavailable(let msg): return "Zulangue core unavailable: \(msg)"
        }
    }
}
