// Arcanum004Accelerator.swift
// Zulangue Design Constitution v2.1 · §08 ARCANUM 004 · ACCELERATOR
//
// 空态插画第四号 —— 用于逐步积累内容的空态。
//
// 视觉词汇:
//   · 三段箭头序列 (细 → 粗 → 最粗) 表示"从 0 加速"
//   · 尾部圆形碰撞室 (外实内虚 两圈 + 中心 gold 点)
//   · 上方 "/// accelerate from 0" 标签 (尾端附 gold 方块)
//   · 底部 进度刻度尺
//
// 尺寸: 360 × 200pt
// 色板: line-50 / line-30 / gold / 禁用 signal
// 线宽: 0.5-1pt

import SwiftUI

struct Arcanum004Accelerator: View {
    var body: some View {
        ArcanumFrame(number: 4, name: "Accelerator") {
            AcceleratorDrawing()
        }
    }
}

// MARK: - Drawing

private struct AcceleratorDrawing: View {
    var body: some View {
        Canvas { ctx, size in
            draw(ctx: ctx, size: size)
        }
        .frame(width: 360, height: 200)
        .overlay(alignment: .topLeading) {
            Text("/// accelerate from 0")
                .font(.captionXs)
                .foregroundColor(Color.line30)
                .tracking(0.5)
                .padding(.leading, 46)
                .padding(.top, 62)
        }
    }

    private func draw(ctx: GraphicsContext, size: CGSize) {
        let line50 = Color.line50
        let line30 = Color.line30

        // ─── 主轴水平基线(参考线) ────────────────────────
        let axisY: CGFloat = 104
        let axisStart: CGFloat = 50
        let axisEnd:   CGFloat = 220

        // ─── 三段箭头序列(从细到粗) ──────────────────────
        let segStarts: [CGFloat] = [axisStart,         axisStart + 58,     axisStart + 116]
        let segEnds:   [CGFloat] = [axisStart + 50,    axisStart + 108,    axisStart + 166]
        let segStrokes: [CGFloat] = [0.5, 1.0, 1.5]

        for i in 0..<3 {
            var seg = Path()
            seg.move(to: CGPoint(x: segStarts[i], y: axisY))
            seg.addLine(to: CGPoint(x: segEnds[i] - 6, y: axisY))
            ctx.stroke(seg, with: .color(line50), lineWidth: segStrokes[i])

            // 箭头头
            var head = Path()
            head.move(to: CGPoint(x: segEnds[i] - 6, y: axisY - 3 - CGFloat(i)))
            head.addLine(to: CGPoint(x: segEnds[i],     y: axisY))
            head.addLine(to: CGPoint(x: segEnds[i] - 6, y: axisY + 3 + CGFloat(i)))
            ctx.stroke(head, with: .color(line50), lineWidth: segStrokes[i])
        }

        // ─── 尾部 碰撞室 (双圈 + 中心 gold 点) ────────────
        let chamberCenter = CGPoint(x: axisEnd + 64, y: axisY)
        let chamberOuterR: CGFloat = 32
        let chamberInnerR: CGFloat = 18

        // 外圈实线
        ctx.stroke(
            Path(ellipseIn: CGRect(
                x: chamberCenter.x - chamberOuterR,
                y: chamberCenter.y - chamberOuterR,
                width: chamberOuterR * 2,
                height: chamberOuterR * 2
            )),
            with: .color(line50),
            lineWidth: 1
        )

        // 内圈虚线
        ctx.stroke(
            Path(ellipseIn: CGRect(
                x: chamberCenter.x - chamberInnerR,
                y: chamberCenter.y - chamberInnerR,
                width: chamberInnerR * 2,
                height: chamberInnerR * 2
            )),
            with: .color(line30),
            style: StrokeStyle(lineWidth: 0.5, dash: [2, 2])
        )

        // 入口连接线(从最后一个箭头到碰撞室边)
        var entry = Path()
        entry.move(to: CGPoint(x: axisStart + 166, y: axisY))
        entry.addLine(to: CGPoint(x: chamberCenter.x - chamberOuterR, y: axisY))
        ctx.stroke(entry, with: .color(line30), lineWidth: 0.5)

        // 中心 gold 圆点
        ctx.fill(
            Path(ellipseIn: CGRect(
                x: chamberCenter.x - 3,
                y: chamberCenter.y - 3,
                width: 6, height: 6
            )),
            with: .color(Color.gold)
        )

        // 碰撞室向外 4 方发射线
        for angle in [CGFloat(0.25), 0.75, 1.25, 1.75].map({ $0 * .pi }) {
            let rInner = chamberOuterR + 2
            let rOuter = chamberOuterR + 8
            var ray = Path()
            ray.move(to: CGPoint(
                x: chamberCenter.x + cos(angle) * rInner,
                y: chamberCenter.y + sin(angle) * rInner
            ))
            ray.addLine(to: CGPoint(
                x: chamberCenter.x + cos(angle) * rOuter,
                y: chamberCenter.y + sin(angle) * rOuter
            ))
            ctx.stroke(ray, with: .color(Color.gold), lineWidth: 0.5)
        }

        // ─── 顶部标签末尾 gold 方块(与文本配合) ─────────
        // 位置:约 "/// accelerate from 0" 末尾
        let tagEndX: CGFloat = 170
        let tagY: CGFloat = 70
        ctx.fill(
            Path(CGRect(x: tagEndX, y: tagY - 3, width: 6, height: 6)),
            with: .color(Color.gold)
        )

        // ─── 底部 进度刻度尺 ──────────────────────────────
        let rulerY: CGFloat = 150
        let rulerStart: CGFloat = 50
        let rulerEnd:   CGFloat = 270

        var ruler = Path()
        ruler.move(to: CGPoint(x: rulerStart, y: rulerY))
        ruler.addLine(to: CGPoint(x: rulerEnd, y: rulerY))
        ctx.stroke(ruler, with: .color(line50), lineWidth: 1)

        // 主刻度
        for i in 0...5 {
            let x = rulerStart + CGFloat(i) * (rulerEnd - rulerStart) / 5
            var tick = Path()
            tick.move(to: CGPoint(x: x, y: rulerY))
            tick.addLine(to: CGPoint(x: x, y: rulerY + 5))
            ctx.stroke(tick, with: .color(line50), lineWidth: 1)
        }

        // 细分刻度
        for i in 0..<5 {
            for j in 1...3 {
                let x = rulerStart + CGFloat(i) * (rulerEnd - rulerStart) / 5 + CGFloat(j) * (rulerEnd - rulerStart) / 20
                var tick = Path()
                tick.move(to: CGPoint(x: x, y: rulerY))
                tick.addLine(to: CGPoint(x: x, y: rulerY + 2))
                ctx.stroke(tick, with: .color(line30), lineWidth: 0.5)
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
struct Arcanum004Accelerator_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            Arcanum004Accelerator()
                .frame(width: 480, height: 320)
                .background(Color.surface)
                .previewDisplayName("Dark")

            Arcanum004Accelerator()
                .frame(width: 480, height: 320)
                .background(Color.surface)
                .preferredColorScheme(.light)
                .previewDisplayName("Light")
        }
    }
}
#endif
