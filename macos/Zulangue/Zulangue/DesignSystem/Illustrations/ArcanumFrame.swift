// ArcanumFrame.swift
// Zulangue Design Constitution v2.0 · §08 ILLUSTRATION LANGUAGE
//
// 所有 Arcanum 插画共用的外壳:
//   · 四角 L-bracket registration marks (0.5pt line-50)
//   · 左上角 "Arcanum {NNN}" 编号 (caption UPPERCASE line-30)
//   · 右下角 "{NAME}" 名字 (caption UPPERCASE line-30)
//   · 内容区居中
//
// 用法:
//   ArcanumFrame(number: 1, name: "OSCILLATOR") {
//       /* 自绘内容 */
//   }

import SwiftUI

struct ArcanumFrame<Content: View>: View {
    let number: Int
    let name: String
    let width: CGFloat
    let height: CGFloat
    @ViewBuilder var content: () -> Content

    init(
        number: Int,
        name: String,
        width: CGFloat = 360,
        height: CGFloat = 200,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.number = number
        self.name = name
        self.width = width
        self.height = height
        self.content = content
    }

    var body: some View {
        ZStack {
            // 四角 L-bracket (装饰身份)
            CornerBrackets()
                .stroke(Color.line50, lineWidth: Stroke.hairline)

            // 主内容
            content()

            // 标签
            VStack {
                HStack {
                    Text("Arcanum \(String(format: "%03d", number))")
                        .font(.captionXs)
                        .foregroundColor(Color.line30)
                        .tracking(0.9)
                        .textCase(.uppercase)
                    Spacer()
                }
                Spacer()
                HStack {
                    Spacer()
                    Text(name)
                        .font(.captionXs)
                        .foregroundColor(Color.line30)
                        .tracking(0.9)
                        .textCase(.uppercase)
                }
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.md)
        }
        .frame(width: width, height: height)
    }
}

// MARK: - Corner Bracket Shape

/// L-shaped registration marks at four corners.
/// Stroke 0.5pt · 12pt arm length · 8pt inset from frame edge.
private struct CornerBrackets: Shape {
    let armLength: CGFloat = 12
    let inset: CGFloat = 8

    func path(in rect: CGRect) -> Path {
        var path = Path()

        // Top-left
        path.move(to: CGPoint(x: inset + armLength, y: inset))
        path.addLine(to: CGPoint(x: inset, y: inset))
        path.addLine(to: CGPoint(x: inset, y: inset + armLength))

        // Top-right
        path.move(to: CGPoint(x: rect.maxX - inset - armLength, y: inset))
        path.addLine(to: CGPoint(x: rect.maxX - inset, y: inset))
        path.addLine(to: CGPoint(x: rect.maxX - inset, y: inset + armLength))

        // Bottom-left
        path.move(to: CGPoint(x: inset, y: rect.maxY - inset - armLength))
        path.addLine(to: CGPoint(x: inset, y: rect.maxY - inset))
        path.addLine(to: CGPoint(x: inset + armLength, y: rect.maxY - inset))

        // Bottom-right
        path.move(to: CGPoint(x: rect.maxX - inset, y: rect.maxY - inset - armLength))
        path.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.maxY - inset))
        path.addLine(to: CGPoint(x: rect.maxX - inset - armLength, y: rect.maxY - inset))

        return path
    }
}
