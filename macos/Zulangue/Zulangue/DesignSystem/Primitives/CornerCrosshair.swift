// CornerCrosshair.swift
// 设计宪法 §06.10: + 十字 registration marks
// 用于 blueprint / hardware 容器的四角标识

import SwiftUI

/// 四角 `+` 十字标。宪法级组件。
///
/// 用法:
/// ```swift
/// SomeContent()
///     .cornerCrosshairs()              // 蓝图默认(白色 dim)
///     .cornerCrosshairs(onHardware: true) // 硬件面板(黑色 dim)
/// ```
struct CornerCrosshair: View {
    var color: Color = .bpLineDim
    var size: CGFloat = 8
    var stroke: CGFloat = 0.5

    var body: some View {
        ZStack {
            Rectangle()
                .fill(color)
                .frame(width: size, height: stroke)
            Rectangle()
                .fill(color)
                .frame(width: stroke, height: size)
        }
        .frame(width: size, height: size)
    }
}

/// 在容器四角放置 `+` 标记(默认内嵌 8pt)
struct CornerCrosshairsOverlay: View {
    var color: Color = .bpLineDim
    var inset: CGFloat = 8
    var size: CGFloat = 8

    var body: some View {
        GeometryReader { _ in
            ZStack {
                VStack {
                    HStack {
                        CornerCrosshair(color: color, size: size)
                        Spacer(minLength: 0)
                        CornerCrosshair(color: color, size: size)
                    }
                    Spacer(minLength: 0)
                    HStack {
                        CornerCrosshair(color: color, size: size)
                        Spacer(minLength: 0)
                        CornerCrosshair(color: color, size: size)
                    }
                }
                .padding(inset)
            }
        }
        .allowsHitTesting(false)
    }
}

extension View {
    /// 加 `+` 四角标 · 蓝图配色(默认)
    func cornerCrosshairs(color: Color = .bpLineDim, inset: CGFloat = 8, size: CGFloat = 8) -> some View {
        self.overlay(
            CornerCrosshairsOverlay(color: color, inset: inset, size: size)
        )
    }

    /// 加 `+` 四角标 · 硬件配色
    func cornerCrosshairsOnHardware(inset: CGFloat = 8) -> some View {
        self.cornerCrosshairs(color: .hwBlackDim, inset: inset)
    }
}

#if DEBUG
#Preview("On blueprint") {
    Text("preview.crosshair.blueprint")
        .font(.body)
        .foregroundColor(.bpLine)
        .padding(32)
        .frame(width: 280, height: 160)
        .background(Color.bpBlue)
        .cornerCrosshairs()
}

#Preview("On hardware") {
    Text("preview.crosshair.hardware")
        .font(.body)
        .foregroundColor(.hwBlack)
        .padding(32)
        .frame(width: 280, height: 160)
        .background(Color.hwSilver)
        .cornerCrosshairsOnHardware()
}
#endif
