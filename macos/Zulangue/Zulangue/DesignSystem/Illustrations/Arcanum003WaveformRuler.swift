// Arcanum003WaveformRuler.swift
// Zulangue Design Constitution v2.1 · §08 ARCANUM 003 · WAVEFORM RULER
//
// 空态插画第三号 —— 用于 transcript empty / DocumentEditor no-transcript / no-doc。
//
// 视觉词汇:
//   · 顶部 正弦波(3 周期)带 3 个 gold 峰值三角标记
//   · 中部 "nm" 单位 + 扫描箭头 "/// scan from 0"
//   · 底部 主刻度尺 + 细分刻度 + 0/1/2/3/4 数字
//   · 右侧 一根测量枢轴竖线标记当前测点
//
// 尺寸: 360 × 200pt
// 色板: line-50 主线 / line-30 细刻度 / gold 峰值 + 测点 / 禁用 signal
// 线宽: 0.5-1pt 混用

import SwiftUI

struct Arcanum003WaveformRuler: View {
    var body: some View {
        ArcanumFrame(number: 3, name: "Waveform Ruler") {
            WaveformRulerDrawing()
        }
    }
}

// MARK: - Drawing

private struct WaveformRulerDrawing: View {
    var body: some View {
        Canvas { ctx, size in
            draw(ctx: ctx, size: size)
        }
        .frame(width: 360, height: 200)
        .overlay(alignment: .topTrailing) {
            Text("nm")
                .font(.captionXs)
                .foregroundColor(Color.line30)
                .tracking(0.6)
                .padding(.trailing, 38)
                .padding(.top, 90)
        }
        .overlay(alignment: .bottomLeading) {
            // 底部刻度数字(与刻度对齐)
            HStack(spacing: 52) {
                Text("0").font(.captionXs).foregroundColor(Color.line30)
                Text("1").font(.captionXs).foregroundColor(Color.line30)
                Text("2").font(.captionXs).foregroundColor(Color.line30)
                Text("3").font(.captionXs).foregroundColor(Color.line30)
                Text("4").font(.captionXs).foregroundColor(Color.line30)
            }
            .padding(.leading, 45)
            .padding(.bottom, 34)
        }
        .overlay(alignment: .topLeading) {
            Text("/// scan from 0")
                .font(.captionXs)
                .foregroundColor(Color.line30)
                .tracking(0.4)
                .padding(.leading, 40)
                .padding(.top, 94)
        }
    }

    private func draw(ctx: GraphicsContext, size: CGSize) {
        let line50 = Color.line50
        let line30 = Color.line30

        // ─── 顶部 正弦波 (3 周期) ────────────────────────
        let waveStartX: CGFloat = 52
        let waveEndX:   CGFloat = 308
        let waveCenterY: CGFloat = 72
        let waveAmp: CGFloat = 20
        let wavePeriod: CGFloat = 85

        var wave = Path()
        var first = true
        var x = waveStartX
        while x <= waveEndX {
            let phase = (x - waveStartX) / wavePeriod * .pi * 2
            let y = waveCenterY - sin(phase) * waveAmp
            if first {
                wave.move(to: CGPoint(x: x, y: y))
                first = false
            } else {
                wave.addLine(to: CGPoint(x: x, y: y))
            }
            x += 2
        }
        ctx.stroke(wave, with: .color(line50), lineWidth: 1)

        // ─── Gold 峰值三角(3 个顶点) ─────────────────────
        let peakXs: [CGFloat] = [
            waveStartX + wavePeriod * 0.25,
            waveStartX + wavePeriod * 1.25,
            waveStartX + wavePeriod * 2.25
        ]
        for px in peakXs {
            let py = waveCenterY - waveAmp - 2
            var tri = Path()
            tri.move(to: CGPoint(x: px - 3, y: py - 6))
            tri.addLine(to: CGPoint(x: px + 3, y: py - 6))
            tri.addLine(to: CGPoint(x: px,     y: py))
            tri.closeSubpath()
            ctx.fill(tri, with: .color(Color.gold))

            // 从峰顶向下的细引线
            var leader = Path()
            leader.move(to: CGPoint(x: px, y: py))
            leader.addLine(to: CGPoint(x: px, y: waveCenterY))
            ctx.stroke(leader, with: .color(Color.gold), lineWidth: 0.5)
        }

        // ─── 中部 扫描箭头 ────────────────────────────────
        let arrowY: CGFloat = 108
        var arrow = Path()
        arrow.move(to: CGPoint(x: waveStartX, y: arrowY))
        arrow.addLine(to: CGPoint(x: waveEndX - 8, y: arrowY))
        ctx.stroke(arrow, with: .color(line30), lineWidth: 0.5)

        // 箭头头
        var arrowHead = Path()
        arrowHead.move(to: CGPoint(x: waveEndX - 8, y: arrowY - 3))
        arrowHead.addLine(to: CGPoint(x: waveEndX, y: arrowY))
        arrowHead.addLine(to: CGPoint(x: waveEndX - 8, y: arrowY + 3))
        ctx.stroke(arrowHead, with: .color(line30), lineWidth: 0.5)

        // 箭尾起点小圆
        ctx.stroke(
            Path(ellipseIn: CGRect(x: waveStartX - 3, y: arrowY - 3, width: 6, height: 6)),
            with: .color(line30),
            lineWidth: 0.5
        )

        // ─── 底部 主刻度尺 ────────────────────────────────
        let rulerY: CGFloat = 150
        let rulerStart: CGFloat = waveStartX
        let rulerEnd: CGFloat = waveEndX

        var ruler = Path()
        ruler.move(to: CGPoint(x: rulerStart, y: rulerY))
        ruler.addLine(to: CGPoint(x: rulerEnd, y: rulerY))
        ctx.stroke(ruler, with: .color(line50), lineWidth: 1)

        // 主刻度(5 档: 0/1/2/3/4)
        let majorCount = 4   // 4 segments = 5 ticks
        let majorSpan = (rulerEnd - rulerStart) / CGFloat(majorCount)
        for i in 0...majorCount {
            let x = rulerStart + CGFloat(i) * majorSpan
            var tick = Path()
            tick.move(to: CGPoint(x: x, y: rulerY))
            tick.addLine(to: CGPoint(x: x, y: rulerY + 6))
            ctx.stroke(tick, with: .color(line50), lineWidth: 1)
        }

        // 细分刻度(每 major 内 4 minor)
        for i in 0..<majorCount {
            for j in 1...3 {
                let x = rulerStart + CGFloat(i) * majorSpan + CGFloat(j) * majorSpan / 4
                var tick = Path()
                tick.move(to: CGPoint(x: x, y: rulerY))
                tick.addLine(to: CGPoint(x: x, y: rulerY + 3))
                ctx.stroke(tick, with: .color(line30), lineWidth: 0.5)
            }
        }

        // ─── Gold 测点枢轴(从 ruler 向上贯穿到 wave center) ───
        let pivotX = rulerStart + majorSpan * 2.25   // ≈ "2.25" 刻度
        var pivot = Path()
        pivot.move(to: CGPoint(x: pivotX, y: rulerY))
        pivot.addLine(to: CGPoint(x: pivotX, y: waveCenterY))
        ctx.stroke(pivot, with: .color(Color.gold), style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))

        // 测点 ruler 上的小三角
        var pivotTri = Path()
        pivotTri.move(to: CGPoint(x: pivotX - 3, y: rulerY))
        pivotTri.addLine(to: CGPoint(x: pivotX + 3, y: rulerY))
        pivotTri.addLine(to: CGPoint(x: pivotX,     y: rulerY - 4))
        pivotTri.closeSubpath()
        ctx.fill(pivotTri, with: .color(Color.gold))
    }
}

// MARK: - Preview

#if DEBUG
struct Arcanum003WaveformRuler_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            Arcanum003WaveformRuler()
                .frame(width: 480, height: 320)
                .background(Color.surface)
                .previewDisplayName("Dark")

            Arcanum003WaveformRuler()
                .frame(width: 480, height: 320)
                .background(Color.surface)
                .preferredColorScheme(.light)
                .previewDisplayName("Light")
        }
    }
}
#endif
