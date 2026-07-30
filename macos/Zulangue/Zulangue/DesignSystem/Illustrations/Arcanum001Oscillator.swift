// Arcanum001Oscillator.swift
// Zulangue Design Constitution v2.0 · §08 ARCANUM 001 · OSCILLATOR
//
// 空态插画第一号 —— 用于 Library 主页无 session 时。
//
// 视觉词汇:
//   · 左侧 旋钮 (knob) + 3 detent marks
//   · 中部 baseline + 2 周期 sine wave
//   · 右侧 vertical scale ticks (128/64/32/16)
//   · 底部 ruler 主格 + 细分刻度
//   · 中央 gold pointer + "|| CENTER" 标注
//
// 尺寸: 360 × 200pt (可按父容器缩放)
// 颜色: 全部 line-50 / line-30 + 单点 gold · 禁用 signal
// 线宽: 0.5–1pt (hairline · thin 混用,模拟手绘仪器图)

import SwiftUI

struct Arcanum001Oscillator: View {

    var body: some View {
        ArcanumFrame(number: 1, name: "Oscillator") {
            OscillatorDrawing()
        }
    }
}

// MARK: - Drawing

private struct OscillatorDrawing: View {
    var body: some View {
        Canvas { ctx, size in
            draw(ctx: ctx, size: size)
        }
        .frame(width: 360, height: 200)
        .overlay(alignment: .center) {
            // Gold "|| CENTER" label overlaid (selectable text)
            Text("|| CENTER")
                .font(.captionXs)
                .foregroundColor(Color.gold)
                .tracking(0.9)
                .textCase(.uppercase)
                .offset(y: -50)
        }
        .overlay(alignment: .topTrailing) {
            // Right vertical scale numbers
            VStack(alignment: .leading, spacing: 10) {
                Text("128").font(.captionXs).foregroundColor(Color.line30)
                Text("64") .font(.captionXs).foregroundColor(Color.line30)
                Text("32") .font(.captionXs).foregroundColor(Color.line30)
                Text("16") .font(.captionXs).foregroundColor(Color.line30)
            }
            .padding(.trailing, 30)
            .padding(.top, 58)
        }
        .overlay(alignment: .bottomLeading) {
            // Ruler numbers 0/1/2/3
            HStack(spacing: 42) {
                Text("0").font(.captionXs).foregroundColor(Color.line30)
                Text("1").font(.captionXs).foregroundColor(Color.line30)
                Text("2").font(.captionXs).foregroundColor(Color.line30)
                Text("3").font(.captionXs).foregroundColor(Color.line30)
            }
            .padding(.leading, 96)
            .padding(.bottom, 36)
        }
    }

    private func draw(ctx: GraphicsContext, size: CGSize) {
        let line50 = Color.line50
        let line30 = Color.line30

        // ─── Left: knob circle + 3 detent marks ─────────────
        let knobCenter = CGPoint(x: 55, y: 90)
        let knobRadius: CGFloat = 16

        ctx.stroke(
            Path(ellipseIn: CGRect(
                x: knobCenter.x - knobRadius,
                y: knobCenter.y - knobRadius,
                width: knobRadius * 2,
                height: knobRadius * 2
            )),
            with: .color(line50),
            lineWidth: 1
        )

        // 3 radiating detent marks (top, top-right, right)
        for angle in [CGFloat.pi * 1.25, CGFloat.pi * 1.5, CGFloat.pi * 1.75] {
            let r1: CGFloat = knobRadius + 2
            let r2: CGFloat = knobRadius + 6
            var tick = Path()
            tick.move(to: CGPoint(
                x: knobCenter.x + cos(angle) * r1,
                y: knobCenter.y + sin(angle) * r1
            ))
            tick.addLine(to: CGPoint(
                x: knobCenter.x + cos(angle) * r2,
                y: knobCenter.y + sin(angle) * r2
            ))
            ctx.stroke(tick, with: .color(line50), lineWidth: 1)
        }

        // Small center dot in knob
        ctx.fill(
            Path(ellipseIn: CGRect(x: knobCenter.x - 1.5, y: knobCenter.y - 1.5, width: 3, height: 3)),
            with: .color(line50)
        )

        // ─── Center: sine wave baseline + wave ──────────────
        let waveStartX: CGFloat = 100
        let waveEndX: CGFloat = 280
        let baselineY: CGFloat = 100
        let waveAmp: CGFloat = 18
        let wavePeriod: CGFloat = 80

        // Dashed baseline reference
        var baseline = Path()
        baseline.move(to: CGPoint(x: waveStartX, y: baselineY))
        baseline.addLine(to: CGPoint(x: waveEndX, y: baselineY))
        ctx.stroke(
            baseline,
            with: .color(line30),
            style: StrokeStyle(lineWidth: 0.5, dash: [2, 3])
        )

        // Sine wave
        var wave = Path()
        var firstPoint = true
        var x = waveStartX
        while x <= waveEndX {
            let phase = (x - waveStartX) / wavePeriod * .pi * 2
            let y = baselineY - sin(phase) * waveAmp
            if firstPoint {
                wave.move(to: CGPoint(x: x, y: y))
                firstPoint = false
            } else {
                wave.addLine(to: CGPoint(x: x, y: y))
            }
            x += 2
        }
        ctx.stroke(wave, with: .color(line50), lineWidth: 1)

        // ─── Center gold marker (vertical line + triangle) ──
        let centerX: CGFloat = 190
        var goldLine = Path()
        goldLine.move(to: CGPoint(x: centerX, y: baselineY - 34))
        goldLine.addLine(to: CGPoint(x: centerX, y: baselineY + 8))
        ctx.stroke(goldLine, with: .color(Color.gold), lineWidth: 0.5)

        var triangle = Path()
        triangle.move(to: CGPoint(x: centerX - 3, y: baselineY - 36))
        triangle.addLine(to: CGPoint(x: centerX + 3, y: baselineY - 36))
        triangle.addLine(to: CGPoint(x: centerX, y: baselineY - 32))
        triangle.closeSubpath()
        ctx.fill(triangle, with: .color(Color.gold))

        // ─── Right: vertical scale ticks ────────────────────
        let scaleX: CGFloat = 300
        for i in 0..<4 {
            let y = CGFloat(68 + i * 14)
            var tick = Path()
            tick.move(to: CGPoint(x: scaleX, y: y))
            tick.addLine(to: CGPoint(x: scaleX + 6, y: y))
            ctx.stroke(tick, with: .color(line50), lineWidth: 1)
        }

        // Vertical scale rail
        var scaleRail = Path()
        scaleRail.move(to: CGPoint(x: scaleX, y: 66))
        scaleRail.addLine(to: CGPoint(x: scaleX, y: 112))
        ctx.stroke(scaleRail, with: .color(line30), lineWidth: 0.5)

        // ─── Bottom: ruler ──────────────────────────────────
        let rulerY: CGFloat = 150
        let rulerStart: CGFloat = 100
        let rulerEnd: CGFloat = 270

        var ruler = Path()
        ruler.move(to: CGPoint(x: rulerStart, y: rulerY))
        ruler.addLine(to: CGPoint(x: rulerEnd, y: rulerY))
        ctx.stroke(ruler, with: .color(line50), lineWidth: 1)

        // Major ticks (every 50pt, 4 ticks = 0/1/2/3)
        for i in 0...4 {
            let x = rulerStart + CGFloat(i) * 42
            var tick = Path()
            tick.move(to: CGPoint(x: x, y: rulerY))
            tick.addLine(to: CGPoint(x: x, y: rulerY + 6))
            ctx.stroke(tick, with: .color(line50), lineWidth: 1)
        }

        // Minor ticks between majors (4 minors per segment)
        for i in 0..<4 {
            for j in 1...3 {
                let x = rulerStart + CGFloat(i) * 42 + CGFloat(j) * 10.5
                var tick = Path()
                tick.move(to: CGPoint(x: x, y: rulerY))
                tick.addLine(to: CGPoint(x: x, y: rulerY + 3))
                ctx.stroke(tick, with: .color(line30), lineWidth: 0.5)
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
struct Arcanum001Oscillator_Previews: PreviewProvider {
    static var previews: some View {
        Arcanum001Oscillator()
            .frame(width: 480, height: 320)
            .background(Color.surface)
    }
}
#endif
