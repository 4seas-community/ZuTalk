// LoroDeltaMapping.swift
// Loro Delta JSON → segments 解析
//
// Loro Delta 是 Quill Delta 风格:
//   [
//     { "insert": "Hello", "attributes": { "segment_id": "…" } },
//     { "insert": " world" }
//   ]
//
// 旧的富文本编辑器(NSAttributedString 双向映射、mark schema、offset 换算)
// 已随平文本编辑器一起拆除;笔记 tab 现在走块文档 FFI(BlockNoteStore)。
// 保留的唯一职责:把 Rust FFI 返回的 Delta JSON 解成 segments,供
// NotebookTranscriptProjectionStore 派生稳定的转录行。

import Foundation

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
