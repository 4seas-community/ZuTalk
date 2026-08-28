// BlockNoteInline.swift
// 行内标记的识别与上色
//
// 粗体、斜体、行内代码、链接、提及。识别的是文本里的 Markdown 记号,
// 渲染时叠样式 —— **记号字符本身保留在文本流里**,只是被压暗。
//
// 不隐藏记号是刻意的:隐藏字符会让字符流与存储文本不再 1:1,于是选区
// 长度、光标步进、复制内容全都要额外补偿,而每一处补偿都是一个新的
// 光标怪毛病。保留记号则是"源码所见即所得"(Bear、iA Writer 同路),
// 选择与复制永远诚实。
//
// 存储模型不动:行仍是纯文本,内联标记是渲染期的解释。因此内联标记
// 天然经得起 CRDT 合并、导出与旧版本打开 —— 它们只是字符。

import AppKit
import Foundation

enum BlockNoteInline {
    /// 一处内联标记。`range` 覆盖包括记号在内的整段,`contentRange`
    /// 是记号之间的正文。
    struct Span: Equatable {
        enum Mark: Equatable {
            case bold
            case italic
            case code
            case link(url: String)
            case mention
        }

        let mark: Mark
        let range: NSRange
        let contentRange: NSRange
    }

    /// 扫描一行文本里的内联标记。重叠时先到先得(外层先匹配的赢),
    /// 不做嵌套解析 —— 一行笔记里嵌套标记罕见,而错误的嵌套解析会把
    /// 普通的星号写法变成一片乱码。
    static func spans(in text: String) -> [Span] {
        let ns = text as NSString
        var taken = IndexSet()
        var spans: [Span] = []

        func claim(_ span: Span) {
            let indices = IndexSet(integersIn: Range(span.range)!)
            guard taken.intersection(indices).isEmpty else { return }
            taken.formUnion(indices)
            spans.append(span)
        }

        // 顺序即优先级:链接与代码先于强调,否则 `[**a**](u)` 会被
        // 星号抢走一半。
        for match in matches(pattern: linkPattern, in: ns) {
            guard match.numberOfRanges == 3 else { continue }
            let url = ns.substring(with: match.range(at: 2))
            claim(Span(
                mark: .link(url: url),
                range: match.range,
                contentRange: match.range(at: 1)
            ))
        }
        for match in matches(pattern: codePattern, in: ns) where match.numberOfRanges == 2 {
            claim(Span(mark: .code, range: match.range, contentRange: match.range(at: 1)))
        }
        for match in matches(pattern: boldPattern, in: ns) where match.numberOfRanges == 2 {
            claim(Span(mark: .bold, range: match.range, contentRange: match.range(at: 1)))
        }
        for match in matches(pattern: italicPattern, in: ns) where match.numberOfRanges == 2 {
            claim(Span(mark: .italic, range: match.range, contentRange: match.range(at: 1)))
        }
        for match in matches(pattern: mentionPattern, in: ns) where match.numberOfRanges == 2 {
            claim(Span(mark: .mention, range: match.range, contentRange: match.range(at: 1)))
        }

        return spans.sorted { $0.range.location < $1.range.location }
    }

    /// 把内联样式叠到一段已经带好块属性的富文本上。`offset` 是这一行
    /// 在整篇文档里的起点。
    static func apply(
        to attributed: NSMutableAttributedString,
        lineText: String,
        offset: Int,
        baseFont: NSFont
    ) {
        for span in spans(in: lineText) {
            let full = NSRange(location: offset + span.range.location, length: span.range.length)
            let content = NSRange(
                location: offset + span.contentRange.location,
                length: span.contentRange.length
            )
            guard NSMaxRange(full) <= attributed.length else { continue }

            // 记号字符压暗:它们仍在文本里,但读者的眼睛会掠过。
            attributed.addAttribute(.foregroundColor, value: NSColor.quaternaryLabelColor, range: full)

            switch span.mark {
            case .bold:
                attributed.addAttributes([
                    .font: baseFont.withTraits(.bold),
                    .foregroundColor: NSColor.labelColor,
                ], range: content)
            case .italic:
                attributed.addAttributes([
                    .font: baseFont.withTraits(.italic),
                    .foregroundColor: NSColor.labelColor,
                ], range: content)
            case .code:
                attributed.addAttributes([
                    .font: NSFont.monospacedSystemFont(ofSize: baseFont.pointSize - 0.5, weight: .regular),
                    .foregroundColor: NSColor.systemPink,
                    // quaternarySystemFill 要 macOS 14;这条路要跑在 12.5 上。
                    .backgroundColor: NSColor.textBackgroundColor.blended(
                        withFraction: 0.08,
                        of: NSColor.labelColor
                    ) ?? NSColor.textBackgroundColor,
                ], range: content)
            case .link(let url):
                var attributes: [NSAttributedString.Key: Any] = [
                    .foregroundColor: NSColor.linkColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                ]
                // 只接受 http/https:笔记里的一段文字不该能拼出
                // file:// 或自定义 scheme 去触发别的程序。
                if let parsed = URL(string: url),
                   let scheme = parsed.scheme?.lowercased(),
                   scheme == "http" || scheme == "https" {
                    attributes[.link] = parsed
                }
                attributed.addAttributes(attributes, range: content)
            case .mention:
                attributed.addAttributes([
                    .foregroundColor: NSColor.controlAccentColor,
                    .font: baseFont.withTraits(.bold),
                ], range: full)
            }
        }
    }

    // MARK: - 模式

    /// `[标题](https://…)`
    private static let linkPattern = #"\[([^\]\n]+)\]\(([^)\s]+)\)"#
    /// `` `代码` ``
    private static let codePattern = "`([^`\n]+)`"
    /// `**粗体**` —— 同样要求记号紧贴内容。
    private static let boldPattern = #"\*\*(\S[^*\n]*?\S|\S)\*\*"#
    /// `*斜体*` —— 前后不能紧挨星号(否则从粗体里抢走一半),且记号必须
    /// 紧贴内容:`*斜*` 算,`2 * 3 * 4` 不算。这是 Markdown 自己的约束,
    /// 少了它,笔记里的乘法算式会整段变成斜体。
    private static let italicPattern =
        #"(?<!\*)\*(?!\*)(\S[^*\n]*?\S|\S)\*(?!\*)"#
    /// `@某人`:字母、数字、下划线、连字符,以及中日韩文字。前面必须是
    /// 行首或空白 —— 否则邮箱地址的 @ 会被认成提及。
    ///
    /// 字符类写全 CJK 区段而不是靠 `\w`:ICU 的 `\w` 不含汉字,只写
    /// `\w` 会让「@项飙」只匹配到一个空提及。
    private static let mentionPattern =
        "(?:^|(?<=\\s))@([\\w\\-\u{4E00}-\u{9FFF}\u{3400}-\u{4DBF}"
        + "\u{3040}-\u{30FF}\u{AC00}-\u{D7AF}]+)"

    private static var cache: [String: NSRegularExpression] = [:]

    private static func matches(pattern: String, in text: NSString) -> [NSTextCheckingResult] {
        let regex: NSRegularExpression
        if let cached = cache[pattern] {
            regex = cached
        } else {
            guard let built = try? NSRegularExpression(pattern: pattern) else { return [] }
            cache[pattern] = built
            regex = built
        }
        return regex.matches(in: text as String, range: NSRange(location: 0, length: text.length))
    }
}

extension NSFont {
    func withTraits(_ traits: NSFontDescriptor.SymbolicTraits) -> NSFont {
        let descriptor = fontDescriptor.withSymbolicTraits(fontDescriptor.symbolicTraits.union(traits))
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
    }
}
