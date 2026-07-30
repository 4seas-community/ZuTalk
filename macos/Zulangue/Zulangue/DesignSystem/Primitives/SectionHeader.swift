// SectionHeader.swift
// 设计宪法 §06.3: §01 TRANSCRIPT 章节头
// 结构: §{NN} {TITLE UPPERCASE} ──────────── 分隔线

import SwiftUI

/// Dual-mode section header.
///
/// 例:
/// ```
/// §01  TRANSCRIPT    ─────────────────────
/// §02  POLISHED      ─────────────────────
/// ```
struct SectionHeader: View {
    let number: Int
    let title: String
    var trailing: String? = nil   // 可选右侧副标 (e.g. SONNET-4.6 · 2.3s)
    /// ⚠️ v2.1 §03.1: 单一视觉语言,`mode` 参数 no-op (两模都会渲染为 dual-mode 响应色)。
    ///   保留仅为 API 兼容;新代码省略此参数。
    var mode: Mode = .blueprint

    /// ⚠️ v2.1 deprecated: §03.1 废除 hw/bp 双视觉语言,两模视觉上已等价。
    enum Mode {
        case blueprint
        @available(*, deprecated, message: "v2.1 §03.1: dual-mode tokens 统一解析,.hardware 与 .blueprint 等价。新代码省略 mode: 参数。")
        case hardware
    }

    var body: some View {
        HStack(spacing: Spacing.md) {
            // §01 编号
            Text("§\(String(format: "%02d", number))")
                .font(.captionMedium)
                .tracking(0.6)
                .foregroundColor(accentColor)

            // 主标题
            Text(title.uppercased())
                .font(.captionMedium)
                .tracking(1.1)
                .foregroundColor(textColor)

            // 分隔线(延伸到右端)
            Rectangle()
                .fill(lineColor)
                .frame(height: Stroke.hairline)
                .frame(maxWidth: .infinity)

            // 可选右侧标签
            if let trailing = trailing {
                Text(trailing.uppercased())
                    .font(.captionXs)
                    .tracking(0.8)
                    .foregroundColor(dimColor)
            }
        }
        .padding(.top, Spacing.xl)
        .padding(.bottom, Spacing.md)
    }

    private var accentColor: Color {
        switch mode {
        case .blueprint: return .accentGold
        case .hardware:  return .accentGoldDim
        }
    }

    private var textColor: Color {
        switch mode {
        case .blueprint: return .bpLine
        case .hardware:  return .hwBlack
        }
    }

    private var lineColor: Color {
        switch mode {
        case .blueprint: return .bpLineDim.opacity(0.5)
        case .hardware:  return .hwBlackDim
        }
    }

    private var dimColor: Color {
        switch mode {
        case .blueprint: return .textOnBpDim
        case .hardware:  return .textOnHwDim
        }
    }
}

#if DEBUG
#Preview("Blueprint") {
    VStack(alignment: .leading) {
        SectionHeader(number: 1, title: "Transcript")
        Text("实时转录内容...")
            .font(.body)
            .foregroundColor(.bpLine)

        SectionHeader(number: 2, title: "Polished · Live", trailing: "Sonnet-4.6 · 2.3s")
        Text("精修后的内容...")
            .font(.body)
            .foregroundColor(.bpLine)
    }
    .padding(32)
    .frame(width: 600)
    .background(Color.bpBlue)
}

#Preview("Hardware") {
    VStack(alignment: .leading) {
        SectionHeader(number: 1, title: "Sessions")
        Text("Session list content")
            .foregroundColor(.hwBlack)
    }
    .padding(32)
    .frame(width: 600)
    .background(Color.hwSilver)
}
#endif
