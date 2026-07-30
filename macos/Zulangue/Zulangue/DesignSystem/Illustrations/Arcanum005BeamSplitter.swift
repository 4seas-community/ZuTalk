// Arcanum005BeamSplitter.swift
// Zulangue Design Constitution v2.1 · §08 ARCANUM 005 · BEAM SPLITTER
//
// 空态插画第五号 —— 用于多路径选择的空态。
//
// 视觉词汇:
//   · 左侧 入射光束 (横向实线 + 箭头)
//   · 中心 45° 分光镜 (斜实线 + 两端小方块)
//   · 透射光束 T (继续横向虚线)
//   · 反射光束 R (向下实线 + 箭头)
//   · 标签 "IN" / "T" (gold) / "R" (gold)
//   · 左右各一个透镜矩形
//
// 尺寸: 360 × 200pt
// 色板: line-50 主线 / line-30 虚线 / gold 两条出射标签 / 禁用 signal
// 线宽: 0.5-1pt

import SwiftUI

struct Arcanum005BeamSplitter: View {
    var body: some View {
        ArcanumFrame(number: 5, name: "Beam Splitter") {
            BeamSplitterDrawing()
        }
    }
}

// MARK: - Drawing

private struct BeamSplitterDrawing: View {
    var body: some View {
        Canvas { ctx, size in
            draw(ctx: ctx, size: size)
        }
        .frame(width: 360, height: 200)
        .overlay(alignment: .topLeading) {
            Text("IN")
                .font(.captionXs)
                .foregroundColor(Color.line50)
                .tracking(0.8)
                .padding(.leading, 50)
                .padding(.top, 70)
        }
        .overlay(alignment: .topTrailing) {
            Text("T")
                .font(.captionXs)
                .foregroundColor(Color.gold)
                .tracking(0.8)
                .padding(.trailing, 52)
                .padding(.top, 70)
        }
        .overlay(alignment: .bottomLeading) {
            Text("R")
                .font(.captionXs)
                .foregroundColor(Color.gold)
                .tracking(0.8)
                .padding(.leading, 178)
                .padding(.bottom, 34)
        }
    }

    private func draw(ctx: GraphicsContext, size: CGSize) {
        let line50 = Color.line50
        let line30 = Color.line30

        // ─── 中心分光镜位置 ───────────────────────────────
        let splitterCenter = CGPoint(x: 184, y: 94)
        let splitterHalf: CGFloat = 18

        // ─── 主基线(入射路径 Y) ──────────────────────────
        let beamY: CGFloat = 94

        // ─── 左侧透镜矩形 ─────────────────────────────────
        let leftLensRect = CGRect(x: 56, y: beamY - 18, width: 14, height: 36)
        ctx.stroke(Path(leftLensRect), with: .color(line50), lineWidth: 1)

        // ─── 入射光束 (IN → splitter) ────────────────────
        var inBeam = Path()
        inBeam.move(to: CGPoint(x: leftLensRect.maxX + 2, y: beamY))
        inBeam.addLine(to: CGPoint(x: splitterCenter.x - 2, y: beamY))
        ctx.stroke(inBeam, with: .color(line50), lineWidth: 1)

        // 入射箭头 (接 splitter 前的小箭头)
        var inHead = Path()
        inHead.move(to: CGPoint(x: splitterCenter.x - 10, y: beamY - 3))
        inHead.addLine(to: CGPoint(x: splitterCenter.x - 4, y: beamY))
        inHead.addLine(to: CGPoint(x: splitterCenter.x - 10, y: beamY + 3))
        ctx.stroke(inHead, with: .color(line50), lineWidth: 1)

        // ─── 分光镜斜线 (45°) ─────────────────────────────
        var splitter = Path()
        splitter.move(to: CGPoint(
            x: splitterCenter.x - splitterHalf / 1.414,
            y: splitterCenter.y + splitterHalf / 1.414
        ))
        splitter.addLine(to: CGPoint(
            x: splitterCenter.x + splitterHalf / 1.414,
            y: splitterCenter.y - splitterHalf / 1.414
        ))
        ctx.stroke(splitter, with: .color(line50), lineWidth: 1.5)

        // 分光镜两端小方块(支架感)
        for endpoint in [
            CGPoint(x: splitterCenter.x - splitterHalf / 1.414, y: splitterCenter.y + splitterHalf / 1.414),
            CGPoint(x: splitterCenter.x + splitterHalf / 1.414, y: splitterCenter.y - splitterHalf / 1.414)
        ] {
            ctx.fill(
                Path(CGRect(x: endpoint.x - 2, y: endpoint.y - 2, width: 4, height: 4)),
                with: .color(line50)
            )
        }

        // ─── 透射 T (splitter → 右侧透镜 · 虚线表示强度衰减) ───
        let rightLensRect = CGRect(x: 280, y: beamY - 18, width: 14, height: 36)

        var tBeam = Path()
        tBeam.move(to: CGPoint(x: splitterCenter.x + 2, y: beamY))
        tBeam.addLine(to: CGPoint(x: rightLensRect.minX - 2, y: beamY))
        ctx.stroke(tBeam, with: .color(Color.gold), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))

        // T 箭头
        var tHead = Path()
        tHead.move(to: CGPoint(x: rightLensRect.minX - 8, y: beamY - 3))
        tHead.addLine(to: CGPoint(x: rightLensRect.minX - 2, y: beamY))
        tHead.addLine(to: CGPoint(x: rightLensRect.minX - 8, y: beamY + 3))
        ctx.stroke(tHead, with: .color(Color.gold), lineWidth: 1)

        // 右透镜
        ctx.stroke(Path(rightLensRect), with: .color(line50), lineWidth: 1)

        // ─── 反射 R (splitter → 下方 · 实线表示)──────────
        let rEndY: CGFloat = 156

        var rBeam = Path()
        rBeam.move(to: CGPoint(x: splitterCenter.x, y: splitterCenter.y + 2))
        rBeam.addLine(to: CGPoint(x: splitterCenter.x, y: rEndY - 2))
        ctx.stroke(rBeam, with: .color(Color.gold), lineWidth: 1)

        // R 箭头
        var rHead = Path()
        rHead.move(to: CGPoint(x: splitterCenter.x - 3, y: rEndY - 8))
        rHead.addLine(to: CGPoint(x: splitterCenter.x,   y: rEndY - 2))
        rHead.addLine(to: CGPoint(x: splitterCenter.x + 3, y: rEndY - 8))
        ctx.stroke(rHead, with: .color(Color.gold), lineWidth: 1)

        // R 尾端小圆(终端探测器)
        ctx.stroke(
            Path(ellipseIn: CGRect(x: splitterCenter.x - 4, y: rEndY, width: 8, height: 8)),
            with: .color(line50),
            lineWidth: 1
        )

        // ─── 基线延伸标注(横向虚线延伸基准) ──────────────
        var baseline = Path()
        baseline.move(to: CGPoint(x: 40, y: beamY))
        baseline.addLine(to: CGPoint(x: leftLensRect.minX - 2, y: beamY))
        ctx.stroke(baseline, with: .color(line30), style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
    }
}

// MARK: - Preview

#if DEBUG
struct Arcanum005BeamSplitter_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            Arcanum005BeamSplitter()
                .frame(width: 480, height: 320)
                .background(Color.surface)
                .previewDisplayName("Dark")

            Arcanum005BeamSplitter()
                .frame(width: 480, height: 320)
                .background(Color.surface)
                .preferredColorScheme(.light)
                .previewDisplayName("Light")
        }
    }
}
#endif
