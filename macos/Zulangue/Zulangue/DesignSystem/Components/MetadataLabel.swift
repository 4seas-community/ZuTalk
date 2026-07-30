// MetadataLabel.swift
// Zulangue 微交互组件库 — 元数据标签
// 权威:docs/redesign/redesign-plan.md §4.B.2.10
//
// 设计原则覆盖:
//   #7 Mono 数字字体严格用于"读数"✓
//
// 用途:
//   统一的"标签:值"展示,替代散落在 InstrumentPanel 内部的 ad-hoc 实现。
//   标签用 mono uppercase tracking,值用 sans 或 mono(根据是否是数字)。
//
// 用法:
//   MetadataLabel(label: "ENGINE", value: "SONIOX RT5")
//   MetadataLabel(label: "LATENCY", value: "187 ms", valueIsNumeric: true)
//   MetadataLabel(label: "SPEAKERS", value: "3", valueIsNumeric: true, accent: .signalBlue)

import SwiftUI

struct MetadataLabel: View {
    let label: String
    let value: String
    var valueIsNumeric: Bool = false
    var accent: Color = .textSecondary
    var orientation: Orientation = .vertical

    var body: some View {
        Group {
            switch orientation {
            case .vertical:
                VStack(alignment: .leading, spacing: 2) {
                    labelText
                    valueText
                }
            case .horizontal:
                HStack(spacing: 6) {
                    labelText
                    valueText
                }
            }
        }
    }

    private var labelText: some View {
        Text(label)
            .font(.mono8)
            .foregroundColor(.textMuted)
            .tracking(0.6)
            .textCase(.uppercase)
    }

    private var valueText: some View {
        Text(value)
            .font(valueIsNumeric ? .monoNum11 : .sans11Medium)
            .foregroundColor(accent)
    }

    enum Orientation {
        case vertical    // 标签在上,值在下(InstrumentPanel 风格)
        case horizontal  // 标签和值同行
    }
}

#if DEBUG
struct MetadataLabel_Previews: PreviewProvider {
    static var previews: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 32) {
                MetadataLabel(label: "ENGINE", value: "SONIOX RT5")
                MetadataLabel(label: "LATENCY", value: "187 ms", valueIsNumeric: true)
            }
            VStack(alignment: .leading, spacing: 6) {
                MetadataLabel(label: "Engine", value: "SONIOX RT5", orientation: .horizontal)
                MetadataLabel(label: "Latency", value: "187 ms", valueIsNumeric: true, orientation: .horizontal)
            }
        }
        .padding(40)
        .background(Color.bgRoot)
    }
}
#endif
