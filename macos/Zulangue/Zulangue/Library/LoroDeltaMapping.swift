// LoroDeltaMapping.swift
// NSAttributedString ↔ Loro Delta JSON 双向映射
// 权威:design-system/MASTER.md §10.3 · D5 §7.5
//
// Loro Delta 是 Quill Delta 风格:
//   [
//     { "insert": "Hello", "attributes": { "bold": true } },
//     { "insert": " world" },
//     { "insert": "\n", "attributes": { "heading": 1 } }
//   ]
//
// 本模块负责:
//   1. Delta JSON → NSAttributedString(渲染到 NSTextView)
//   2. 属性 key 的 schema 常量 + 映射规则
//   3. UTF-16 ↔ Unicode scalar offset 换算(Loro 用 scalar,NSTextView 用 UTF-16)

import AppKit
import Foundation

// MARK: - Schema

/// Loro mark key 常量。所有 UI / bridge / Rust 用这一组字符串对齐。
enum LoroMarkKey {
    /// 加粗,value = `true`
    static let bold = "bold"
    /// 斜体,value = `true`
    static let italic = "italic"
    /// 删除线,value = `true`
    static let strikethrough = "strikethrough"
    /// 行内代码,value = `true`
    static let code = "code"
    /// 段落标题,value = `1..3`(Int)。"段落级属性",整行 newline 上挂
    static let heading = "heading"
    /// 列表,value = `"bullet"` 或 `"ordered"`。同样是段落级
    static let list = "list"
}

/// 值序列化帮助 — 把 Swift 原语转成 FFI 要求的 JSON 字符串。
enum LoroMarkValue {
    static let trueJson = "true"
    static let falseJson = "false"

    static func int(_ n: Int) -> String { String(n) }
    static func string(_ s: String) -> String {
        // JSON 字符串必须带引号,安全起见走 JSONEncoder
        if let data = try? JSONEncoder().encode(s),
           let encoded = String(data: data, encoding: .utf8) {
            return encoded
        }
        return "\"\(s)\""
    }
}

extension NSAttributedString.Key {
    static let zulangueListKind = NSAttributedString.Key("ZulangueListKind")
    static let zulangueListDepth = NSAttributedString.Key("ZulangueListDepth")
}

struct LoroListStyle: Equatable {
    static let minDepth = 1
    static let maxDepth = 6

    let kind: String
    let depth: Int

    init(kind: String, depth: Int = 1) {
        self.kind = kind
        self.depth = min(max(depth, Self.minDepth), Self.maxDepth)
    }

    var valueJson: String {
        if depth == 1 {
            return LoroMarkValue.string(kind)
        }
        let payload: [String: Any] = [
            "kind": kind,
            "depth": depth,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8)
        else {
            return LoroMarkValue.string(kind)
        }
        return json
    }

    static func decode(from rawValue: Any?) -> LoroListStyle? {
        if let kind = rawValue as? String, !kind.isEmpty {
            return LoroListStyle(kind: kind)
        }
        if let kind = rawValue as? NSString, !kind.isEqual(to: "") {
            return LoroListStyle(kind: kind as String)
        }
        guard let dict = rawValue as? [String: Any] else { return nil }

        let kind: String? = {
            if let kind = dict["kind"] as? String, !kind.isEmpty {
                return kind
            }
            if let kind = dict["kind"] as? NSString, !kind.isEqual(to: "") {
                return kind as String
            }
            return nil
        }()
        guard let kind else { return nil }

        let depth: Int = {
            if let depth = dict["depth"] as? NSNumber {
                return depth.intValue
            }
            if let depth = dict["depth"] as? Int {
                return depth
            }
            return 1
        }()
        return LoroListStyle(kind: kind, depth: depth)
    }

    static func fromAttributes(_ attrs: [NSAttributedString.Key: Any]) -> LoroListStyle? {
        if let kind = attrs[.zulangueListKind] as? String {
            let depth = (attrs[.zulangueListDepth] as? NSNumber)?.intValue
                ?? (attrs[.zulangueListDepth] as? Int)
                ?? 1
            return LoroListStyle(kind: kind, depth: depth)
        }

        guard let paragraphStyle = attrs[.paragraphStyle] as? NSParagraphStyle,
              let textList = paragraphStyle.textLists.first
        else {
            return nil
        }

        let marker = String(describing: textList.markerFormat)
        let kind = marker.contains("decimal") ? "ordered" : "bullet"
        let indent = max(paragraphStyle.headIndent, paragraphStyle.firstLineHeadIndent)
        let rawDepth = Int(round((indent - LoroRenderStyle.listBaseIndent) / LoroRenderStyle.listIndentStep)) + 1
        return LoroListStyle(kind: kind, depth: max(rawDepth, 1))
    }
}

// MARK: - Delta 解析

/// 单个 Delta segment。attributes 的 value 可以是 bool / int / string / double。
struct LoroDeltaSegment {
    let insert: String
    let attributes: [String: Any]?
}

/// 把 Rust FFI 返回的 Delta JSON 字符串解成 segments。
enum LoroDeltaParser {
    static func parse(_ json: String) -> [LoroDeltaSegment] {
        guard let data = json.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            return []
        }
        return array.compactMap { dict in
            guard let insert = dict["insert"] as? String else { return nil }
            let attrs = dict["attributes"] as? [String: Any]
            return LoroDeltaSegment(insert: insert, attributes: attrs)
        }
    }
}

// MARK: - 渲染样式

/// 渲染 Delta 用的字体/颜色方案。一个实例在一个编辑器生命周期内稳定。
struct LoroRenderStyle {
    static let readableContentWidth: CGFloat = 760
    static let minimumHorizontalInset: CGFloat = 56
    static let verticalInset: CGFloat = 36
    static let listBaseIndent: CGFloat = 28
    static let listIndentStep: CGFloat = 22

    let baseFontSize: CGFloat
    let textColor: NSColor
    let codeBackground: NSColor
    let codeForeground: NSColor

    static let `default` = LoroRenderStyle(
        baseFontSize: 14,
        // 使用动态颜色，并与 design-system `bpLine` 保持一致。
        textColor: NSColor(name: nil, dynamicProvider: { appearance in
            switch appearance.bestMatch(from: [.darkAqua, .aqua]) {
            case .darkAqua?: return NSColor.white.withAlphaComponent(0.92)
            default:         return NSColor.black.withAlphaComponent(0.87)
            }
        }),
        // 代码块:深蓝底色只在 dark mode;light mode 换成淡灰底 + 深色字
        codeBackground: NSColor(name: nil, dynamicProvider: { appearance in
            switch appearance.bestMatch(from: [.darkAqua, .aqua]) {
            case .darkAqua?: return NSColor(calibratedRed: 0.14, green: 0.20, blue: 0.36, alpha: 1.0)
            default:         return NSColor(calibratedWhite: 0.95, alpha: 1.0)
            }
        }),
        codeForeground: NSColor(name: nil, dynamicProvider: { appearance in
            switch appearance.bestMatch(from: [.darkAqua, .aqua]) {
            case .darkAqua?: return NSColor(calibratedRed: 1.0, green: 0.80, blue: 0.60, alpha: 1.0)
            default:         return NSColor(calibratedRed: 0.55, green: 0.25, blue: 0.05, alpha: 1.0)
            }
        })
    )

    /// 根据 heading level 计算字号。1→22,2→18,3→16,其它→base。
    func headingFontSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 22
        case 2: return 18
        case 3: return 16
        default: return baseFontSize
        }
    }

    func readableHorizontalInset(for viewWidth: CGFloat) -> CGFloat {
        let centeredInset = max((viewWidth - Self.readableContentWidth) / 2, 0)
        return max(Self.minimumHorizontalInset, floor(centeredInset))
    }

    func paragraphStyle(
        headingLevel: Int? = nil,
        listStyle: LoroListStyle? = nil
    ) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping

        switch headingLevel {
        case 1:
            style.lineSpacing = 8
            style.paragraphSpacingBefore = 18
            style.paragraphSpacing = 14
        case 2:
            style.lineSpacing = 7
            style.paragraphSpacingBefore = 14
            style.paragraphSpacing = 10
        case 3:
            style.lineSpacing = 6
            style.paragraphSpacingBefore = 12
            style.paragraphSpacing = 8
        default:
            style.lineSpacing = 7
            style.paragraphSpacing = 10
        }

        if let listStyle {
            let markerFormat: NSTextList.MarkerFormat = (listStyle.kind == "ordered")
                ? .decimal
                : .disc
            style.textLists = [NSTextList(markerFormat: markerFormat, options: 0)]
            let indent = Self.listBaseIndent + CGFloat(max(listStyle.depth - 1, 0)) * Self.listIndentStep
            style.firstLineHeadIndent = indent
            style.headIndent = indent
            style.defaultTabInterval = Self.listIndentStep
            style.paragraphSpacingBefore = headingLevel == nil ? 0 : style.paragraphSpacingBefore
            style.paragraphSpacing = 4
            style.lineSpacing = max(style.lineSpacing - 1, 5)
        }

        return style
    }
}

// MARK: - Delta → NSAttributedString

enum LoroAttributedStringBuilder {
    /// 把 Delta segments 构造成 NSAttributedString。
    /// 每个 segment 的 attributes 单独翻译成 NSAttributedString attributes。
    static func build(
        segments: [LoroDeltaSegment],
        style: LoroRenderStyle = .default
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for seg in segments {
            let attrs = renderAttributes(for: seg.attributes, style: style)
            result.append(NSAttributedString(string: seg.insert, attributes: attrs))
        }
        return result
    }

    /// 单个 segment 的 attribute dict → NSAttributedString 属性字典。
    ///
    /// JSON → NSNumber bridging 有坑:`as? Int` / `as? Bool` 在 NSNumber 内部
    /// 存储为 double / bool 时不可靠。统一走 `as? NSNumber + .intValue/.boolValue`。
    static func renderAttributes(
        for loroAttrs: [String: Any]?,
        style: LoroRenderStyle
    ) -> [NSAttributedString.Key: Any] {
        var result: [NSAttributedString.Key: Any] = [
            .foregroundColor: style.textColor
        ]

        guard let attrs = loroAttrs, !attrs.isEmpty else {
            result[.font] = NSFont.systemFont(ofSize: style.baseFontSize)
            result[.paragraphStyle] = style.paragraphStyle()
            return result
        }

        // 统一的 bool / int 提取器
        func boolValue(_ key: String) -> Bool {
            (attrs[key] as? NSNumber)?.boolValue ?? false
        }
        func intValue(_ key: String) -> Int? {
            (attrs[key] as? NSNumber)?.intValue
        }

        let headingLevel: Int? = {
            if let lv = intValue(LoroMarkKey.heading), lv >= 1, lv <= 6 {
                return lv
            }
            return nil
        }()
        let listStyle = LoroListStyle.decode(from: attrs[LoroMarkKey.list])

        // 字号:heading 优先,否则 base
        let fontSize: CGFloat = headingLevel.map { style.headingFontSize($0) } ?? style.baseFontSize

        // 字体 trait
        let isBold = boolValue(LoroMarkKey.bold) || (headingLevel != nil)
        let isItalic = boolValue(LoroMarkKey.italic)
        let isCode = boolValue(LoroMarkKey.code)
        let isStrike = boolValue(LoroMarkKey.strikethrough)

        var font: NSFont
        if isCode {
            font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: isBold ? .semibold : .regular)
        } else {
            let weight: NSFont.Weight = isBold ? .semibold : .regular
            font = NSFont.systemFont(ofSize: fontSize, weight: weight)
            if isItalic {
                let italicDesc = font.fontDescriptor.withSymbolicTraits(.italic)
                if let italicFont = NSFont(descriptor: italicDesc, size: fontSize) {
                    font = italicFont
                }
            }
        }
        result[.font] = font

        if isStrike {
            result[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }

        if isCode {
            result[.backgroundColor] = style.codeBackground
            result[.foregroundColor] = style.codeForeground
        }

        result[.paragraphStyle] = style.paragraphStyle(
            headingLevel: headingLevel,
            listStyle: listStyle
        )
        if let listStyle {
            result[.zulangueListKind] = listStyle.kind
            result[.zulangueListDepth] = NSNumber(value: listStyle.depth)
        }

        return result
    }
}

// MARK: - UTF-16 ↔ Unicode scalar offset 换算

/// NSTextStorage 内部用 UTF-16 code units;Loro 用 Unicode scalar(codepoint)。
/// 这组转换函数保证 CJK / emoji 位置不错位。
enum LoroOffsetConverter {
    /// 把 UTF-16 offset 映射到 Unicode scalar offset。
    /// 越界时返回末尾,命中 surrogate pair 中间时返回上一完整 scalar。
    static func scalarOffset(in text: String, utf16Offset: Int) -> Int {
        if utf16Offset <= 0 { return 0 }
        var scalarCount = 0
        var utf16Count = 0
        for scalar in text.unicodeScalars {
            if utf16Count >= utf16Offset {
                return scalarCount
            }
            utf16Count += scalar.utf16.count
            scalarCount += 1
        }
        return scalarCount
    }

    /// 反向:scalar offset → UTF-16 offset。供 Loro → NSTextView 选区换算用。
    static func utf16Offset(in text: String, scalarOffset: Int) -> Int {
        if scalarOffset <= 0 { return 0 }
        var scalarCount = 0
        var utf16Count = 0
        for scalar in text.unicodeScalars {
            if scalarCount >= scalarOffset {
                return utf16Count
            }
            utf16Count += scalar.utf16.count
            scalarCount += 1
        }
        return utf16Count
    }

    /// 把 NSRange(UTF-16)转成 Loro 的 (pos, len) scalar 对。
    static func scalarRange(in text: String, utf16Range: NSRange) -> (pos: UInt64, len: UInt64) {
        let start = scalarOffset(in: text, utf16Offset: utf16Range.location)
        let end = scalarOffset(in: text, utf16Offset: utf16Range.location + utf16Range.length)
        return (UInt64(start), UInt64(max(end - start, 0)))
    }
}

// MARK: - 判断一段 attributed string 是否整段带某 mark(供 toggleMark 逻辑用)

extension NSAttributedString {
    /// 判断整段文本是否都带某个 Loro mark(用 NSAttributedString 属性反推 —
    /// 用户切换 B/I 时本地就能判断,不必查询 Rust)。
    func hasMark(key: String) -> Bool {
        guard length > 0 else { return false }
        var allHave = true
        enumerateAttributes(in: NSRange(location: 0, length: length)) { attrs, _, stop in
            if !Self.attributesContainMark(attrs, key: key) {
                allHave = false
                stop.pointee = true
            }
        }
        return allHave
    }

    private static func attributesContainMark(_ attrs: [NSAttributedString.Key: Any], key: String) -> Bool {
        switch key {
        case LoroMarkKey.bold:
            guard let font = attrs[.font] as? NSFont else { return false }
            return font.fontDescriptor.symbolicTraits.contains(.bold)
        case LoroMarkKey.italic:
            guard let font = attrs[.font] as? NSFont else { return false }
            return font.fontDescriptor.symbolicTraits.contains(.italic)
        case LoroMarkKey.strikethrough:
            return (attrs[.strikethroughStyle] as? Int).map { $0 != 0 } ?? false
        case LoroMarkKey.code:
            guard let font = attrs[.font] as? NSFont else { return false }
            return font.fontDescriptor.symbolicTraits.contains(.monoSpace)
        default:
            // heading/list 是段落级,不在这里简单判定 — 触发方统一走 apply 路径
            return false
        }
    }
}
