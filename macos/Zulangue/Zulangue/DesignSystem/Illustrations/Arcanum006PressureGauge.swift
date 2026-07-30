// Arcanum006PressureGauge.swift
// Zulangue Design Constitution v2.1 · §08 ARCANUM 006 · PRESSURE GAUGE
//
// 空态插画第六号 —— 预留给 Settings diagnostics panel,本次不接入具体屏幕。
//
// 视觉词汇:
//   · 中央 圆形压力表 (外实 + 内刻度环)
//   · 270° 刻度弧 (9 条主刻度 + 细分)
//   · gold 临界区域 (0°→60° 的 signal danger zone)
//   · 指针 (从原点指向约 150°)
//   · 中心轴套
//   · 底部 "kPa" 单位标签 + 主读数文本
//
// 尺寸: 360 × 200pt
// 色板: line-50 主 / line-30 辅 / gold 临界区 + 指针 / 禁用 signal
// 线宽: 0.5-1.5pt

import SwiftUI

struct Arcanum006PressureGauge: View {
    var body: some View {
        ArcanumFrame(number: 6, name: "Pressure Gauge") {
            PressureGaugeDrawing()
        }
    }
}

// MARK: - Drawing

private struct PressureGaugeDrawing: View {
    var body: some View {
        Canvas { ctx, size in
            draw(ctx: ctx, size: size)
        }
        .frame(width: 360, height: 200)
        .overlay(alignment: .center) {
            VStack(spacing: 2) {
                Spacer().frame(height: 46)   // 留给上方表盘
                Text("kPa")
                    .font(.captionXs)
                    .foregroundColor(Color.line30)
                    .tracking(0.6)
            }
        }
    }

    private func draw(ctx: GraphicsContext, size: CGSize) {
        let line50 = Color.line50
        let line30 = Color.line30

        // ─── 表盘中心 ─────────────────────────────────────
        let center = CGPoint(x: 180, y: 98)
        let outerR: CGFloat = 58
        let scaleR: CGFloat = 50
        let tickInnerR: CGFloat = 46

        // ─── 外圈 ─────────────────────────────────────────
        ctx.stroke(
            Path(ellipseIn: CGRect(
                x: center.x - outerR,
                y: center.y - outerR,
                width: outerR * 2,
                height: outerR * 2
            )),
            with: .color(line50),
            lineWidth: 1
        )

        // ─── 270° 刻度弧区域 (start 135°→ end 45°,顺时针,即 270° 扫过) ──
        // SwiftUI angle: 0° = right, 90° = bottom
        // 表盘标准:左下 (135°) → 下 → 右 → 右上 (45°)
        let arcStart: CGFloat = .pi * 0.75    // 135°
        let arcEnd:   CGFloat = .pi * 2.25    // 405° = 45°

        // ─── gold 临界区(arcEnd 左侧 60° · 最大值附近红区) ───
        let goldStart = arcEnd - .pi * (60.0 / 180.0)
        let goldEnd   = arcEnd
        var goldArc = Path()
        goldArc.addArc(
            center: center,
            radius: scaleR + 2,
            startAngle: .radians(Double(goldStart)),
            endAngle: .radians(Double(goldEnd)),
            clockwise: false
        )
        ctx.stroke(goldArc, with: .color(Color.gold), lineWidth: 3)

        // ─── 主刻度弧 ─────────────────────────────────────
        var scaleArc = Path()
        scaleArc.addArc(
            center: center,
            radius: scaleR,
            startAngle: .radians(Double(arcStart)),
            endAngle: .radians(Double(arcEnd)),
            clockwise: false
        )
        ctx.stroke(scaleArc, with: .color(line50), lineWidth: 0.5)

        // ─── 9 条主刻度 ──────────────────────────────────
        let majorCount = 8   // 9 ticks
        for i in 0...majorCount {
            let t = CGFloat(i) / CGFloat(majorCount)
            let angle = arcStart + (arcEnd - arcStart) * t
            var tick = Path()
            tick.move(to: CGPoint(
                x: center.x + cos(angle) * tickInnerR,
                y: center.y + sin(angle) * tickInnerR
            ))
            tick.addLine(to: CGPoint(
                x: center.x + cos(angle) * (scaleR + 4),
                y: center.y + sin(angle) * (scaleR + 4)
            ))
            ctx.stroke(tick, with: .color(line50), lineWidth: 1)
        }

        // ─── 细分刻度(每两个主刻度之间 4 minor) ──────────
        for i in 0..<majorCount {
            for j in 1...3 {
                let t = (CGFloat(i) + CGFloat(j) / 4) / CGFloat(majorCount)
                let angle = arcStart + (arcEnd - arcStart) * t
                var tick = Path()
                tick.move(to: CGPoint(
                    x: center.x + cos(angle) * (scaleR - 1),
                    y: center.y + sin(angle) * (scaleR - 1)
                ))
                tick.addLine(to: CGPoint(
                    x: center.x + cos(angle) * (scaleR + 2),
                    y: center.y + sin(angle) * (scaleR + 2)
                ))
                ctx.stroke(tick, with: .color(line30), lineWidth: 0.5)
            }
        }

        // ─── 指针 (约 45% 位置 · 接近但未入红区) ──────────
        let needleT: CGFloat = 0.50
        let needleAngle = arcStart + (arcEnd - arcStart) * needleT
        var needle = Path()
        needle.move(to: center)
        needle.addLine(to: CGPoint(
            x: center.x + cos(needleAngle) * (scaleR - 6),
            y: center.y + sin(needleAngle) * (scaleR - 6)
        ))
        ctx.stroke(needle, with: .color(Color.gold), lineWidth: 1.5)

        // 指针尾端小尾巴(指向反方向的短三角)
        let tailAngle = needleAngle + .pi
        var needleTail = Path()
        needleTail.move(to: center)
        needleTail.addLine(to: CGPoint(
            x: center.x + cos(tailAngle) * 10,
            y: center.y + sin(tailAngle) * 10
        ))
        ctx.stroke(needleTail, with: .color(Color.gold), lineWidth: 1.5)

        // ─── 中心轴套 ─────────────────────────────────────
        ctx.fill(
            Path(ellipseIn: CGRect(
                x: center.x - 4,
                y: center.y - 4,
                width: 8, height: 8
            )),
            with: .color(Color.gold)
        )
        ctx.stroke(
            Path(ellipseIn: CGRect(
                x: center.x - 4,
                y: center.y - 4,
                width: 8, height: 8
            )),
            with: .color(line50),
            lineWidth: 0.5
        )

        // ─── 内刻度环 (装饰,更小半径) ────────────────────
        ctx.stroke(
            Path(ellipseIn: CGRect(
                x: center.x - 22,
                y: center.y - 22,
                width: 44, height: 44
            )),
            with: .color(line30),
            style: StrokeStyle(lineWidth: 0.5, dash: [2, 3])
        )

        // ─── 顶部 tick label "0" 与 "MAX"(极简) ──────────
        // 0 在 arcStart 位置
        let zeroP = CGPoint(
            x: center.x + cos(arcStart) * (scaleR + 10),
            y: center.y + sin(arcStart) * (scaleR + 10)
        )
        ctx.draw(
            Text("0")
                .font(.captionXs)
                .foregroundColor(line30),
            at: zeroP
        )

        let maxP = CGPoint(
            x: center.x + cos(arcEnd) * (scaleR + 10),
            y: center.y + sin(arcEnd) * (scaleR + 10)
        )
        ctx.draw(
            Text("MAX")
                .font(.captionXs)
                .foregroundColor(Color.gold),
            at: maxP
        )
    }
}

// MARK: - Preview

#if DEBUG
struct Arcanum006PressureGauge_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            Arcanum006PressureGauge()
                .frame(width: 480, height: 320)
                .background(Color.surface)
                .previewDisplayName("Dark")

            Arcanum006PressureGauge()
                .frame(width: 480, height: 320)
                .background(Color.surface)
                .preferredColorScheme(.light)
                .previewDisplayName("Light")
        }
    }
}
#endif
