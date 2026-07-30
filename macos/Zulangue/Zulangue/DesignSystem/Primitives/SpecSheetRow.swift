// SpecSheetRow.swift
// 设计宪法 §06.12: LABEL ........ VALUE 技术规格行
// 左 label 左对齐, 右 value 右对齐 mono, 中间 dot leader 填充

import SwiftUI

/// 规格表单行。宪法级 primitive。
///
/// 例:
/// ```
/// DURATION ........... 00:45:08
/// MODEL  ........  SONNET-4.6
/// ```
struct SpecSheetRow: View {
    let label: String
    let value: String
    /// ⚠️ v2.1 §03.1: 单一视觉语言,`mode` 参数 no-op。保留仅为 API 兼容。
    var mode: Mode = .blueprint
    var emphasis: Emphasis = .normal

    /// ⚠️ v2.1 deprecated: §03.1 废除 hw/bp 双视觉语言。
    enum Mode {
        case blueprint
        @available(*, deprecated, message: "v2.1 §03.1: dual-mode tokens 统一解析,.hardware 与 .blueprint 等价。新代码省略 mode: 参数。")
        case hardware
    }

    enum Emphasis {
        case normal   // 白/黑 value
        case gold     // 金 value (身份类数据)
        case orange   // 橙 value (active 类)
        case dim      // 灰 value (次要)
    }

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Text(label.uppercased())
                .font(.captionMedium)
                .tracking(0.9)
                .foregroundColor(labelColor)
                .fixedSize(horizontal: true, vertical: false)

            // Dot leader
            LinearDotLeader(color: labelColor.opacity(0.3))

            Text(value)
                .font(.dataMedium)
                .foregroundColor(valueColor)
                .fixedSize(horizontal: true, vertical: false)
        }
        .frame(minHeight: 24)
    }

    private var labelColor: Color {
        switch mode {
        case .blueprint: return .textOnBpDim
        case .hardware:  return .textOnHwDim
        }
    }

    private var valueColor: Color {
        switch emphasis {
        case .normal:
            return mode == .blueprint ? .bpLine : .hwBlack
        case .gold:    return .accentGold
        case .orange:  return .accentOrange
        case .dim:
            return mode == .blueprint ? .textOnBpDim : .textOnHwDim
        }
    }
}

/// 虚线填充中间空隙 (dot leader · · · · ·)
private struct LinearDotLeader: View {
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let dotSize: CGFloat = 2
            let spacing: CGFloat = 5
            let count = max(0, Int((geo.size.width + spacing) / (dotSize + spacing)))
            HStack(spacing: spacing) {
                ForEach(0..<count, id: \.self) { _ in
                    Circle()
                        .fill(color)
                        .frame(width: dotSize, height: dotSize)
                }
            }
            .frame(width: geo.size.width, alignment: .center)
        }
        .frame(height: 4)
    }
}

#if DEBUG
#Preview("Blueprint") {
    VStack(alignment: .leading, spacing: 4) {
        SpecSheetRow(label: "Session", value: "REF-A-012", emphasis: .gold)
        SpecSheetRow(label: "Duration", value: "00:45:08")
        SpecSheetRow(label: "Language", value: "ZH → EN")
        SpecSheetRow(label: "Model", value: "SONNET-4.6", emphasis: .orange)
        SpecSheetRow(label: "Status", value: "POLISHED")
        SpecSheetRow(label: "Created", value: "2000-01-02", emphasis: .dim)
    }
    .padding(32)
    .frame(width: 420)
    .background(Color.bpBlue)
}

#Preview("Hardware") {
    VStack(alignment: .leading, spacing: 4) {
        SpecSheetRow(label: "Session", value: "REF-A-012", emphasis: .gold)
        SpecSheetRow(label: "Duration", value: "00:45:08")
        SpecSheetRow(label: "Model", value: "SONNET-4.6")
    }
    .padding(32)
    .frame(width: 420)
    .background(Color.hwSilver)
}
#endif
