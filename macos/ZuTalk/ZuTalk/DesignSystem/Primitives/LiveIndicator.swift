// LiveIndicator.swift
// 设计宪法 §06.17: ◉ RECORDING / ▊ POLISHING / ⚠ ERROR 状态指示
// 脉冲 + 旋转 + 静止 三种动画策略

import SwiftUI

/// 脉冲圆点 + 状态标签组合。宪法级 primitive。
struct LiveIndicator: View {
    enum State {
        case recording   // 橙圆脉冲
        case processing  // 橙弧旋转
        case completed   // 金色小方块 (静态, 成品奖章)
        case error       // 红三角 (静止)
        case idle        // 灰小点

        var label: String {
            switch self {
            case .recording:  return "REC"
            case .processing: return "POLISHING"
            case .completed:  return "COMPLETED"
            case .error:      return "ERROR"
            case .idle:       return ""
            }
        }
    }

    let state: State
    var customLabel: String? = nil
    var size: CGFloat = 8

    var body: some View {
        HStack(spacing: Spacing.xs + 2) {
            icon
            if let text = customLabel ?? (state.label.isEmpty ? nil : state.label) {
                Text(text)
                    .font(.captionMedium)
                    .tracking(1.0)
                    .foregroundColor(color)
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch state {
        case .recording:
            PulsingDot(color: .accentOrange, size: size)
        case .processing:
            SpinningArc(color: .accentOrange, size: size + 2)
        case .completed:
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.accentGold)
                .frame(width: size, height: size)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: size + 2, weight: .semibold))
                .foregroundColor(.destructive)
        case .idle:
            Circle()
                .fill(Color.textTertiary)
                .frame(width: size - 2, height: size - 2)
        }
    }

    private var color: Color {
        switch state {
        case .recording:  return .accentOrange
        case .processing: return .accentOrange
        case .completed:  return .accentGold
        case .error:      return .destructive
        case .idle:       return .textTertiary
        }
    }
}

// MARK: - 动画 primitive
//
// `PulsingDot` and `SpinningArc` are shared design-system primitives — public
// to the module so menu-bar surfaces (`RecordingHudView`,
// `MenuBarRecordingView`, `MenuBarProcessingView`) reuse the same easing /
// cadence as the in-app `LiveIndicator`. Cadence is intentional: every
// "currently happening" signal in the product breathes on the same 0.9s
// rhythm so the user reads them as one system rather than independent widgets.

/// 9s opacity-pulse circle. Used wherever the constitution calls for a
/// breathing "currently happening" dot.
struct PulsingDot: View {
    let color: Color
    var size: CGFloat = 8
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .opacity(pulsing ? 0.4 : 1.0)
            .onAppear {
                withAnimation(
                    .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                ) {
                    pulsing = true
                }
            }
    }
}

/// 70% rotating arc. Used wherever the constitution calls for a processing-
/// in-progress glyph (Rust transcription, polish, summarize).
struct SpinningArc: View {
    let color: Color
    var size: CGFloat = 10
    var lineWidth: CGFloat = 2
    @State private var rotating = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.7)
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(rotating ? 360 : 0))
            .onAppear {
                withAnimation(
                    .linear(duration: 0.9).repeatForever(autoreverses: false)
                ) {
                    rotating = true
                }
            }
    }
}

#if DEBUG
#Preview {
    VStack(alignment: .leading, spacing: 20) {
        LiveIndicator(state: .recording)
        LiveIndicator(state: .processing)
        LiveIndicator(state: .completed)
        LiveIndicator(state: .error)
        LiveIndicator(state: .recording, customLabel: "LIVE · 02:14")
    }
    .padding(32)
    .background(Color.bgRoot)
}
#endif
