// GridBackground.swift
// 48px 网格底层 — Cipher Grid 视觉元素
// 视觉原则：design-system/MASTER.md

import SwiftUI

// MARK: - GridBackground

/// 网格底层
///
/// 48px 网格，opacity 2.5%，全局存在
/// 传达隐含的坐标秩序感
struct GridBackground: View {
    var gridSize: CGFloat = Spacing.grid // 48
    var lineColor: Color = .gridLine  // v3: 从 Tokens.swift 引用,统一管理
    var opacity: Double = 0.025

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                let path = Path { p in
                    // 垂直线
                    var x: CGFloat = 0
                    while x <= size.width {
                        p.move(to: CGPoint(x: x, y: 0))
                        p.addLine(to: CGPoint(x: x, y: size.height))
                        x += gridSize
                    }
                    // 水平线
                    var y: CGFloat = 0
                    while y <= size.height {
                        p.move(to: CGPoint(x: 0, y: y))
                        p.addLine(to: CGPoint(x: size.width, y: y))
                        y += gridSize
                    }
                }
                context.stroke(
                    path,
                    with: .color(lineColor.opacity(opacity)),
                    lineWidth: 1
                )
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - View Modifier

extension View {
    /// 给视图加上网格背景
    func gridBackground() -> some View {
        ZStack {
            Color.bgRoot
            GridBackground()
            self
        }
    }
}

// MARK: - Preview

#if DEBUG
struct GridBackground_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            Color.bgRoot
            GridBackground()
            Text("48px Grid")
                .font(.mono12)
                .foregroundColor(Color.textSecondary)
        }
        .frame(width: 600, height: 400)
    }
}
#endif
