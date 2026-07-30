// Arcanum002Radar.swift
// Zulangue Design Constitution v2.1 · §08 ARCANUM 002 · RADAR
//
// 空态插画第二号 —— 用于搜索无结果 (HomeView search-no-match)。
//
// 视觉词汇:
//   · 中心圆点(原点) + 十字基准
//   · 3 圈同心弧 (外实 / 中虚 / 内实)
//   · 四向角度刻度 (N/E/S/W)
//   · 一条扫描光束 (扇形填充,line-15)
//   · 一个目标点 (gold 圆) + "LABEL E006" 标注
//
// 尺寸: 360 × 200pt
// 颜色: line-50 / line-30 / gold; 禁用 signal
// 线宽: 0.5–1pt

import SwiftUI

struct Arcanum002Radar: View {
    var body: some View {
        ArcanumFrame(number: 2, name: "Radar") {
            RadarDrawing()
        }
    }
}

// MARK: - Drawing

private struct RadarDrawing: View {
    var body: some View {
        Canvas { ctx, size in
            draw(ctx: ctx, size: size)
        }
        .frame(width: 360, height: 200)
        .overlay(alignment: .topTrailing) {
            Text("LABEL E006")
                .font(.captionXs)
                .foregroundColor(Color.gold)
                .tracking(0.9)
                .textCase(.uppercase)
                .padding(.trailing, 40)
                .padding(.top, 42)
        }
        .overlay(alignment: .bottomLeading) {
            Text("Arcanum 002")
                .font(.captionXs)
                .foregroundColor(Color.line30)
                .tracking(0.9)
                .textCase(.uppercase)
                .padding(.leading, 40)
                .padding(.bottom, 44)
        }
    }

    private func draw(ctx: GraphicsContext, size: CGSize) {
        let line50 = Color.line50
        let line30 = Color.line30
        let line15 = Color.line15

        // ─── Radar 原点与半径 ─────────────────────────────
        let origin = CGPoint(x: 180, y: 104)
        let radiusOuter: CGFloat = 68
        let radiusMid:   CGFloat = 46
        let radiusInner: CGFloat = 24

        // ─── 扫描光束 (扇形填充,仿雷达最亮扇区) ──────────
        let sweepStart: CGFloat = .pi * 1.70   // ~306° (左上)
        let sweepEnd:   CGFloat = .pi * 2.00   // 360° (右)
        var sweep = Path()
        sweep.move(to: origin)
        sweep.addArc(
            center: origin,
            radius: radiusOuter,
            startAngle: .radians(Double(sweepStart)),
            endAngle: .radians(Double(sweepEnd)),
            clockwise: false
        )
        sweep.closeSubpath()
        ctx.fill(sweep, with: .color(line15))

        // 扫描光束的前沿线(更亮)
        var sweepEdge = Path()
        sweepEdge.move(to: origin)
        sweepEdge.addLine(to: CGPoint(
            x: origin.x + cos(sweepEnd) * radiusOuter,
            y: origin.y + sin(sweepEnd) * radiusOuter
        ))
        ctx.stroke(sweepEdge, with: .color(line50), lineWidth: 1)

        // ─── 外圈 (实线) ─────────────────────────────────
        ctx.stroke(
            Path(ellipseIn: CGRect(
                x: origin.x - radiusOuter,
                y: origin.y - radiusOuter,
                width: radiusOuter * 2,
                height: radiusOuter * 2
            )),
            with: .color(line50),
            lineWidth: 1
        )

        // ─── 中圈 (虚线) ─────────────────────────────────
        ctx.stroke(
            Path(ellipseIn: CGRect(
                x: origin.x - radiusMid,
                y: origin.y - radiusMid,
                width: radiusMid * 2,
                height: radiusMid * 2
            )),
            with: .color(line30),
            style: StrokeStyle(lineWidth: 0.5, dash: [2, 3])
        )

        // ─── 内圈 (实线细) ───────────────────────────────
        ctx.stroke(
            Path(ellipseIn: CGRect(
                x: origin.x - radiusInner,
                y: origin.y - radiusInner,
                width: radiusInner * 2,
                height: radiusInner * 2
            )),
            with: .color(line30),
            lineWidth: 0.5
        )

        // ─── 十字基准 (通过原点的两条细线) ──────────────
        var crossH = Path()
        crossH.move(to: CGPoint(x: origin.x - radiusOuter - 6, y: origin.y))
        crossH.addLine(to: CGPoint(x: origin.x + radiusOuter + 6, y: origin.y))
        ctx.stroke(crossH, with: .color(line30), style: StrokeStyle(lineWidth: 0.5, dash: [4, 3]))

        var crossV = Path()
        crossV.move(to: CGPoint(x: origin.x, y: origin.y - radiusOuter - 6))
        crossV.addLine(to: CGPoint(x: origin.x, y: origin.y + radiusOuter + 6))
        ctx.stroke(crossV, with: .color(line30), style: StrokeStyle(lineWidth: 0.5, dash: [4, 3]))

        // ─── 角度刻度 (四向主 tick) ───────────────────────
        for angle in [CGFloat(0), .pi * 0.5, .pi, .pi * 1.5] {
            let rInner: CGFloat = radiusOuter
            let rOuter: CGFloat = radiusOuter + 4
            var tick = Path()
            tick.move(to: CGPoint(
                x: origin.x + cos(angle) * rInner,
                y: origin.y + sin(angle) * rInner
            ))
            tick.addLine(to: CGPoint(
                x: origin.x + cos(angle) * rOuter,
                y: origin.y + sin(angle) * rOuter
            ))
            ctx.stroke(tick, with: .color(line50), lineWidth: 1)
        }

        // ─── 细分刻度 (每 15° 一个 minor tick) ────────────
        for i in 0..<24 {
            let angle = CGFloat(i) * .pi / 12
            // 跳过主刻度位置
            let isMajor = i % 6 == 0
            if isMajor { continue }
            let rInner: CGFloat = radiusOuter
            let rOuter: CGFloat = radiusOuter + 2
            var tick = Path()
            tick.move(to: CGPoint(
                x: origin.x + cos(angle) * rInner,
                y: origin.y + sin(angle) * rInner
            ))
            tick.addLine(to: CGPoint(
                x: origin.x + cos(angle) * rOuter,
                y: origin.y + sin(angle) * rOuter
            ))
            ctx.stroke(tick, with: .color(line30), lineWidth: 0.5)
        }

        // ─── 原点圆点 ────────────────────────────────────
        ctx.fill(
            Path(ellipseIn: CGRect(x: origin.x - 2, y: origin.y - 2, width: 4, height: 4)),
            with: .color(line50)
        )

        // ─── 目标点 (gold 圆 + 引线) ─────────────────────
        let targetAngle: CGFloat = .pi * 1.83   // ~330° (右上)
        let targetRadius: CGFloat = radiusMid + 4
        let targetPoint = CGPoint(
            x: origin.x + cos(targetAngle) * targetRadius,
            y: origin.y + sin(targetAngle) * targetRadius
        )

        // 目标点外圈(空心圆)
        ctx.stroke(
            Path(ellipseIn: CGRect(
                x: targetPoint.x - 4,
                y: targetPoint.y - 4,
                width: 8,
                height: 8
            )),
            with: .color(Color.gold),
            lineWidth: 1
        )

        // 目标中心点
        ctx.fill(
            Path(ellipseIn: CGRect(
                x: targetPoint.x - 1.5,
                y: targetPoint.y - 1.5,
                width: 3,
                height: 3
            )),
            with: .color(Color.gold)
        )

        // 引线 (目标到右上标签区域)
        var leader = Path()
        leader.move(to: CGPoint(x: targetPoint.x + 4, y: targetPoint.y - 2))
        leader.addLine(to: CGPoint(x: targetPoint.x + 30, y: targetPoint.y - 16))
        leader.addLine(to: CGPoint(x: targetPoint.x + 60, y: targetPoint.y - 16))
        ctx.stroke(leader, with: .color(Color.gold), lineWidth: 0.5)

        // 引线端点小方
        ctx.fill(
            Path(CGRect(x: targetPoint.x + 4 - 1.5, y: targetPoint.y - 2 - 1.5, width: 3, height: 3)),
            with: .color(Color.gold)
        )
    }
}

// MARK: - Preview

#if DEBUG
struct Arcanum002Radar_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            Arcanum002Radar()
                .frame(width: 480, height: 320)
                .background(Color.surface)
                .previewDisplayName("Dark")

            Arcanum002Radar()
                .frame(width: 480, height: 320)
                .background(Color.surface)
                .preferredColorScheme(.light)
                .previewDisplayName("Light")
        }
    }
}
#endif
