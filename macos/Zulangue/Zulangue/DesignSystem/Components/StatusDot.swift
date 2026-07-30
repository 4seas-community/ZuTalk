// StatusDot.swift
// Zulangue 微交互组件库 — 状态指示点
// 权威:docs/redesign/redesign-plan.md §4.B.2.9
//
// 设计原则覆盖:
//   #2 motion(pulse 动画)✓
//   #4 Loading 叙事(状态文字 + 颜色对应语义)✓
//
// 6 种状态:
//   - idle:        textMuted 灰
//   - connecting:  signalAmber 慢脉冲
//   - connected:   signalGreen 静态
//   - recording:   signalRed 快脉冲
//   - processing:  signalBlue 旋转
//   - error:       signalRed 静态 + 警告 icon
//
// 用法:
//   StatusDot(state: .recording, label: "REC 01:23")
//   StatusDot(state: .connected, label: "Soniox · 187ms")

import SwiftUI

struct StatusDot: View {
    let state: StatusDotState
    var label: String? = nil
    var size: CGFloat = 8

    @State private var pulse = false

    var body: some View {
        HStack(spacing: 6) {
            dotView
            if let label {
                Text(label)
                    .font(.sans11Medium)
                    .foregroundColor(state.color)
            }
        }
    }

    @ViewBuilder
    private var dotView: some View {
        switch state {
        case .processing:
            ProgressView()
                .scaleEffect(0.5)
                .frame(width: size, height: size)
        case .error:
            Image(systemName: Icon.warning)
                .iconSizeSmall()
                .foregroundColor(state.color)
                .frame(width: size, height: size)
        default:
            Circle()
                .fill(state.color)
                .frame(width: size, height: size)
                .scaleEffect(state.shouldPulse && pulse ? 1.3 : 1.0)
                .opacity(state.shouldPulse && pulse ? 0.6 : 1.0)
                .animation(
                    state.shouldPulse
                        ? Animation.easeInOut(duration: state.pulseDuration).repeatForever(autoreverses: true)
                        : nil,
                    value: pulse
                )
                .onAppear { if state.shouldPulse { pulse = true } }
        }
    }
}

enum StatusDotState {
    case idle
    case connecting
    case connected
    case recording
    case processing
    case error

    var color: Color {
        switch self {
        case .idle:       return .textMuted
        case .connecting: return .signalAmber
        case .connected:  return .signalGreen
        case .recording:  return .signalRed
        case .processing: return .signalBlue
        case .error:      return .signalRed
        }
    }

    var shouldPulse: Bool {
        switch self {
        case .connecting, .recording: return true
        default: return false
        }
    }

    var pulseDuration: Double {
        switch self {
        case .connecting: return 1.2
        case .recording:  return 0.8
        default:          return 1.0
        }
    }
}

#if DEBUG
struct StatusDot_Previews: PreviewProvider {
    static var previews: some View {
        VStack(alignment: .leading, spacing: 16) {
            StatusDot(state: .idle, label: "Idle")
            StatusDot(state: .connecting, label: "Connecting...")
            StatusDot(state: .connected, label: "Connected · 187ms")
            StatusDot(state: .recording, label: "REC 01:23:45")
            StatusDot(state: .processing, label: "Transcribing...")
            StatusDot(state: .error, label: "Connection failed")
        }
        .padding(40)
        .background(Color.bgRoot)
    }
}
#endif
