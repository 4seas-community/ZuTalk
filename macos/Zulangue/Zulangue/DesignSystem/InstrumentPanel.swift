// InstrumentPanel.swift
// 凹陷面板 — Instrument Cipher 视觉系统的核心组件
// 视觉原则：design-system/MASTER.md

import SwiftUI

// MARK: - InstrumentPanel

/// 凹陷面板容器
///
/// 视觉特征：
/// - background: bgPanel (#0f1118)
/// - border: 1px borderPanel (#181c26)
/// - inset shadow: 0 1px 3px rgba(0,0,0,0.4)
/// - radius: 5px (Radius.sm)
struct InstrumentPanel<Content: View>: View {
    let content: () -> Content
    var padding: CGFloat = Spacing.md

    init(padding: CGFloat = Spacing.md, @ViewBuilder content: @escaping () -> Content) {
        self.padding = padding
        self.content = content
    }

    var body: some View {
        content()
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: Radius.sm)
                    .fill(Color.bgPanel)
                    .overlay(
                        // 模拟 inset shadow：内描边 + 顶部明亮线条
                        RoundedRectangle(cornerRadius: Radius.sm)
                            .strokeBorder(Color.black.opacity(0.4), lineWidth: 1)
                            .blur(radius: 1)
                            .offset(y: 1)
                            .mask(RoundedRectangle(cornerRadius: Radius.sm))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.sm)
                    .strokeBorder(Color.borderPanel, lineWidth: 1)
            )
    }
}

// MARK: - Labeled Instrument Panel

/// 带标签的凹陷面板（最常见用法）
///
/// 用法：
/// ```swift
/// LabeledInstrumentPanel(label: "ENGINE", value: "SONIOX RT5")
/// LabeledInstrumentPanel(label: "LATENCY", value: "187ms")
/// ```
struct LabeledInstrumentPanel: View {
    let label: String
    let value: String
    var valueColor: Color = .textSecondary

    var body: some View {
        InstrumentPanel {
            VStack(alignment: .leading, spacing: 10) {
                Text(label)
                    .instrumentLabel()
                Text(value)
                    .font(.mono10)
                    .foregroundColor(valueColor)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Multi-value Panel

/// 多值面板：标签 + 多行内容
struct MultiValuePanel<Content: View>: View {
    let label: String
    let content: () -> Content

    init(label: String, @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.content = content
    }

    var body: some View {
        InstrumentPanel {
            VStack(alignment: .leading, spacing: 10) {
                Text(label)
                    .instrumentLabel()
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Preview

#if DEBUG
struct InstrumentPanel_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: Spacing.md) {
            HStack(spacing: Spacing.md) {
                LabeledInstrumentPanel(label: "ENGINE", value: "SONIOX RT5")
                LabeledInstrumentPanel(label: "LATENCY", value: "187ms")
            }
        }
        .padding(Spacing.lg)
        .background(Color.bgRoot)
        .frame(width: 600)
    }
}
#endif
