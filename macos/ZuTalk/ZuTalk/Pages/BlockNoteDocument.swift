// BlockNoteDocument.swift
// 大纲行 ↔ 富文本文档的双向映射
//
// 编辑器的编辑面从"每行一个 TextField"换成"整篇一个 NSTextView"之后,
// 行不再是控件而是段落:一行 = 一个以换行结尾的段落,块类型/深度/勾选
// /行 id 作为段落属性挂在字符上。跨行选择、复制、拖拽、拼写检查、输入
// 法、查找替换因此全部回到系统文本栈——这些是文本引擎的能力,不是
// 逐行控件拼得出来的。
//
// 这里只做映射与序列化,不碰 AppKit 视图:两个方向都是纯函数,可以直接
// 单测。权威仍是 BlockNoteStore.rows(Rust 落盘的镜像);富文本只是编辑
// 期的载体,每次编辑后再派生回行。

import AppKit
import Foundation

extension NSAttributedString.Key {
    /// 段落所属的行 id。拆分产生新 id,合并丢弃 id —— CRDT 侧靠它认人,
    /// 所以任何改动都必须显式决定 id 的去留,不能让它随字符漂移。
    static let blockRowId = NSAttributedString.Key("xyz.voice.zutalk.blockRowId")
    static let blockKind = NSAttributedString.Key("xyz.voice.zutalk.blockKind")
    static let blockDepth = NSAttributedString.Key("xyz.voice.zutalk.blockDepth")
    static let blockChecked = NSAttributedString.Key("xyz.voice.zutalk.blockChecked")
}

enum BlockNoteDocument {
    /// 每级缩进的宽度。
    static let indentStep: CGFloat = 22
    /// 记号栏宽度:圆点、方框、引用竖条都画在这一栏里,文本列因此不随
    /// 类型漂移。
    static let markerWidth: CGFloat = 18

    // MARK: - 行 → 富文本

    static func attributedString(rows: [FfiOutlineRow]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (index, row) in rows.enumerated() {
            let offset = result.length
            result.append(attributedParagraph(for: row, isLast: index == rows.count - 1))
            // 内联标记(粗体/斜体/代码/链接/提及)叠在块属性之上。记号
            // 字符留在文本里,只被压暗 —— 字符流与存储文本严格 1:1。
            if row.kind != .divider, !row.text.isEmpty {
                BlockNoteInline.apply(
                    to: result,
                    lineText: row.text,
                    offset: offset,
                    baseFont: font(for: row.kind)
                )
            }
        }
        return result
    }

    /// 单个段落。除末行外都以换行结尾;换行本身也带同一批属性,空行才
    /// 有地方挂它的行 id。
    static func attributedParagraph(for row: FfiOutlineRow, isLast: Bool) -> NSAttributedString {
        let text = row.kind == .divider ? dividerGlyph : row.text
        let body = isLast ? text : text + "\n"
        return NSAttributedString(string: body, attributes: attributes(for: row))
    }

    /// 分隔线没有文本,用一串短横占位:它必须在文本流里占一个段落,
    /// 否则光标无法停在它上面,也无法用退格删掉。
    static let dividerGlyph = "———"

    static func attributes(for row: FfiOutlineRow) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .blockRowId: row.id,
            .blockKind: kindRawValue(row.kind),
            .blockDepth: Int(row.depth),
            .blockChecked: row.checked,
            .font: font(for: row.kind),
            .foregroundColor: color(for: row),
            .paragraphStyle: paragraphStyle(for: row),
        ]
        if row.checked {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            attributes[.strikethroughColor] = NSColor.tertiaryLabelColor
        }
        if row.kind == .divider {
            attributes[.foregroundColor] = NSColor.separatorColor
        }
        return attributes
    }

    static func paragraphStyle(for row: FfiOutlineRow) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        let indent = CGFloat(row.depth) * indentStep
        // 记号画在缩进之后、文本之前的那一栏;首行与折行同一个内缩,
        // 折行文本才会与首行对齐而不是钻到记号底下。
        style.firstLineHeadIndent = indent + markerWidth
        style.headIndent = indent + markerWidth
        style.lineSpacing = 2
        style.paragraphSpacing = spacingAfter(row.kind)
        style.paragraphSpacingBefore = spacingBefore(row.kind)
        return style
    }

    private static func spacingBefore(_ kind: FfiOutlineKind) -> CGFloat {
        switch kind {
        case .heading1: 16
        case .heading2, .heading3: 12
        case .divider: 8
        default: 2
        }
    }

    private static func spacingAfter(_ kind: FfiOutlineKind) -> CGFloat {
        switch kind {
        case .heading1, .heading2, .heading3: 6
        case .divider: 8
        default: 2
        }
    }

    static func font(for kind: FfiOutlineKind) -> NSFont {
        switch kind {
        case .heading1: .systemFont(ofSize: 22, weight: .semibold)
        case .heading2: .systemFont(ofSize: 18, weight: .semibold)
        case .heading3: .systemFont(ofSize: 15, weight: .semibold)
        case .quote: .systemFont(ofSize: 13).withItalic()
        default: .systemFont(ofSize: 13)
        }
    }

    private static func color(for row: FfiOutlineRow) -> NSColor {
        if row.checked { return .tertiaryLabelColor }
        return row.kind == .quote ? .secondaryLabelColor : .labelColor
    }

    // MARK: - 富文本 → 行

    /// 从编辑后的富文本派生回行。段落顺序即行顺序;属性缺失的段落
    /// (系统粘贴、拼写替换等路径可能带不全属性)按段落继承前一行的
    /// 深度与类型,并补一个新 id —— 宁可多一个新行,也不让它凭空消失。
    static func rows(from attributed: NSAttributedString) -> [FfiOutlineRow] {
        let full = attributed.string
        guard !full.isEmpty else { return [] }

        var rows: [FfiOutlineRow] = []
        var seenIds = Set<String>()
        var lineStart = full.startIndex
        var inheritedDepth: UInt32 = 0

        while true {
            let lineEnd = full[lineStart...].firstIndex(of: "\n") ?? full.endIndex
            let text = String(full[lineStart..<lineEnd])
            // 属性取自段落首字符;空段落取自它的换行符。两者都在段落
            // 自己的范围里,不会串到相邻段落。
            let probe = lineStart < full.endIndex ? lineStart : full.index(before: full.endIndex)
            let location = full.distance(from: full.startIndex, to: probe)
            let attributes = location < attributed.length
                ? attributed.attributes(at: location, effectiveRange: nil)
                : [:]

            var kind = attributes[.blockKind]
                .flatMap { $0 as? Int }
                .flatMap(kindFromRawValue) ?? .paragraph
            let depth = attributes[.blockDepth].flatMap { $0 as? Int }
                .map { UInt32(max(0, $0)) } ?? inheritedDepth
            let checked = attributes[.blockChecked] as? Bool ?? false
            // 同一个 id 出现两次,说明系统把一个段落拆成了两段(粘贴、
            // 换行插入)。后来的那一段必须换新 id,否则 CRDT 侧两行会
            // 认成同一行。
            var id = attributes[.blockRowId] as? String ?? UUID().uuidString
            if seenIds.contains(id) {
                id = UUID().uuidString
            }
            seenIds.insert(id)

            var body = text
            if kind == .divider {
                // 分隔线的占位字形不是内容。
                body = ""
            } else if text == dividerGlyph {
                kind = .divider
                body = ""
            }

            rows.append(FfiOutlineRow(
                id: id,
                depth: depth,
                text: body,
                kind: kind,
                checked: kind == .task ? checked : false
            ))
            inheritedDepth = depth

            guard lineEnd < full.endIndex else { break }
            lineStart = full.index(after: lineEnd)
            // 末尾换行结束的文档:换行之后还有一个空段落,它是真实的
            // 空行(用户按了回车),要保留。
            if lineStart == full.endIndex {
                rows.append(FfiOutlineRow(
                    id: UUID().uuidString,
                    depth: inheritedDepth,
                    text: "",
                    kind: .paragraph,
                    checked: false
                ))
                break
            }
        }
        return rows
    }

    // MARK: - 复制序列化

    /// 跨行复制时放进剪贴板的纯文本:带回 Markdown 记号与缩进,粘到别处
    /// 仍是一份结构化的清单,粘回本编辑器也能被前缀规则重新认出来。
    static func markdownText(for rows: [FfiOutlineRow]) -> String {
        rows.map { row in
            let indent = String(repeating: "  ", count: Int(row.depth))
            switch row.kind {
            case .paragraph: return indent + row.text
            case .heading1: return indent + "# " + row.text
            case .heading2: return indent + "## " + row.text
            case .heading3: return indent + "### " + row.text
            case .quote: return indent + "> " + row.text
            case .task: return indent + (row.checked ? "- [x] " : "- [ ] ") + row.text
            case .divider: return indent + "---"
            }
        }
        .joined(separator: "\n")
    }

    // MARK: - 类型编码

    /// FfiOutlineKind 没有 raw value(UniFFI 生成的裸枚举),属性字典要
    /// 存进 NSAttributedString 必须是 property-list 类型,所以这里手写
    /// 一份稳定编码。顺序即协议,不得重排。
    static func kindRawValue(_ kind: FfiOutlineKind) -> Int {
        switch kind {
        case .paragraph: 0
        case .heading1: 1
        case .heading2: 2
        case .heading3: 3
        case .quote: 4
        case .task: 5
        case .divider: 6
        }
    }

    static func kindFromRawValue(_ raw: Int) -> FfiOutlineKind? {
        switch raw {
        case 0: .paragraph
        case 1: .heading1
        case 2: .heading2
        case 3: .heading3
        case 4: .quote
        case 5: .task
        case 6: .divider
        default: nil
        }
    }
}

private extension NSFont {
    func withItalic() -> NSFont {
        let descriptor = fontDescriptor.withSymbolicTraits(.italic)
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
    }
}
