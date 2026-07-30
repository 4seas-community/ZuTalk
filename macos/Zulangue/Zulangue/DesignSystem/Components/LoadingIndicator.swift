// LoadingIndicator.swift
// Zulangue 微交互组件库 — 加载指示
// 权威:docs/redesign/redesign-plan.md §4.B.2.6
//
// 设计原则覆盖:
//   #4 Loading 必须有"叙事"(强制带文字)✓
//
// 强制规则:
//   不允许"裸 spinner"。每个 loading 必须有:
//   - 动画(spinner / pulse / progress)
//   - 叙事文字(在做什么 + 大约要多久)
//
// 4 种规格:
//   - inline:行内 spinner + 文字(用于 toolbar / 列表项)
//   - overlay:覆盖层卡片(用于 fullscreen 等待)
//   - progressBar:带进度条 + 标签(用于知道总进度的任务)
//   - pulseDot:简单脉冲点(菜单栏状态指示用)
//
// 用法:
//   LoadingIndicator(.inline("Generating summary..."))
//   LoadingIndicator(.overlay("Connecting to Soniox", subtitle: "~3 seconds"))
//   LoadingIndicator(.progressBar(progress: 0.42, label: "Transcribing..."))
//   LoadingIndicator(.pulseDot(color: .signalRed))

import SwiftUI

struct LoadingIndicator: View {
    let style: LoadingStyle

    var body: some View {
        switch style {
        case .inline(let text):
            inlineView(text: text)
        case .overlay(let text, let subtitle):
            overlayView(text: text, subtitle: subtitle)
        case .progressBar(let progress, let label):
            progressBarView(progress: progress, label: label)
        case .pulseDot(let color):
            pulseDotView(color: color)
        }
    }

    // MARK: - inline

    private func inlineView(text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.65)
                .frame(width: 14, height: 14)
            Text(text)
                .font(.sans11)
                .foregroundColor(.textSecondary)
                .lineLimit(1)
        }
    }

    // MARK: - overlay

    private func overlayView(text: String, subtitle: String?) -> some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(1.2)
                .padding(.bottom, 4)
            Text(text)
                .font(.sans12Semibold)
                .foregroundColor(.textPrimary)
            if let subtitle {
                Text(subtitle)
                    .font(.sans11)
                    .foregroundColor(.textTertiary)
            }
        }
        .padding(Spacing.xl)
        .frame(minWidth: 200)
        .elevation(.overlay, cornerRadius: Radius.md)
    }

    // MARK: - progressBar

    @ViewBuilder
    private func progressBarView(progress: Double, label: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.sans11Semibold)
                    .foregroundColor(.textPrimary)
                Spacer()
                Text("\(Int(progress * 100))%")
                    .font(.monoNum11)
                    .foregroundColor(.textSecondary)
            }
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .tint(.signalBlue)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - pulseDot

    @State private var pulse = false

    private func pulseDotView(color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .scaleEffect(pulse ? 1.2 : 1.0)
            .opacity(pulse ? 0.7 : 1.0)
            .animation(
                Animation.easeInOut(duration: 1.2).repeatForever(autoreverses: true),
                value: pulse
            )
            .onAppear { pulse = true }
    }
}

enum LoadingStyle {
    case inline(String)
    case overlay(String, subtitle: String? = nil)
    case progressBar(progress: Double, label: String)
    case pulseDot(color: Color = .signalBlue)
}

#if DEBUG
struct LoadingIndicator_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 32) {
            LoadingIndicator(style: .inline("Preparing transcript..."))
            LoadingIndicator(style: .overlay("Connecting to Soniox", subtitle: "~3 seconds"))
            LoadingIndicator(style: .progressBar(progress: 0.42, label: "Transcribing audio"))
                .frame(width: 280)
            HStack(spacing: 12) {
                LoadingIndicator(style: .pulseDot(color: .signalRed))
                Text("REC").font(.mono10Medium).foregroundColor(.signalRed)
            }
        }
        .padding(40)
        .background(Color.bgRoot)
    }
}
#endif
