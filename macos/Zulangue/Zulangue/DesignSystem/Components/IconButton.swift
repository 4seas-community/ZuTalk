// IconButton.swift
// Zulangue 微交互组件库 — 图标按钮
// 权威:docs/redesign/redesign-plan.md §4.B.2.1
//
// 设计原则覆盖:
//   #1 4 状态视觉反馈(default/hover/press/disabled)✓
//   #2 motion(microInteraction spring)✓
//   #3 按钮"我听到你了"(scale 0.94 on press)✓
//   #5 focus ring 强制集成 ✓
//
// 用法:
//   IconButton(icon: Icon.record, action: { startRecording() }, accent: .signalRed)
//   IconButton(icon: Icon.settings, action: { openSettings() }, size: .large, tooltip: "Settings")

import SwiftUI

struct IconButton: View {
    let icon: String
    let action: () -> Void

    var size: ButtonSize = .medium
    var variant: IconButtonVariant = .ghost
    var tooltip: String? = nil
    var accent: Color = .textTertiary
    var isEnabled: Bool = true

    @State private var isHovering = false
    @State private var isPressing = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .iconSizeForButton(size)
                .foregroundColor(currentForeground)
                .frame(width: size.dimension, height: size.dimension)
                .background(currentBackground)
                .overlay(currentBorder)
                .scaleEffect(isPressing ? 0.94 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .focusable(isEnabled)
        .focused($isFocused)
        .focusRing(
            isFocused,
            cornerRadius: size.dimension / 2,
            intensity: size == .small ? .subtle : .standard
        )
        .help(tooltip ?? "")
        .accessibilityLabel(tooltip ?? icon)
        .onHover { isHovering = $0 && isEnabled }
        .onLongPressGesture(minimumDuration: 0, maximumDistance: .infinity, perform: {}, onPressingChanged: { pressing in
            isPressing = pressing && isEnabled
        })
        .animation(Motion.microInteraction, value: isHovering)
        .animation(Motion.microInteraction, value: isPressing)
        .animation(Motion.microInteraction, value: isEnabled)
    }

    private var currentForeground: Color {
        if !isEnabled { return accent.opacity(0.4) }
        if isHovering || isFocused { return .textPrimary }
        return accent
    }

    @ViewBuilder
    private var currentBackground: some View {
        switch variant {
        case .ghost:
            Capsule().fill(
                isHovering || isFocused
                    ? Color.bgElevated
                    : Color.bgSurface.opacity(0.6)
            )
        case .filled:
            Capsule().fill(
                isHovering || isFocused
                    ? accent.opacity(0.25)
                    : accent.opacity(0.15)
            )
        case .outlined:
            Capsule().fill(Color.bgPanel)
        }
    }

    @ViewBuilder
    private var currentBorder: some View {
        switch variant {
        case .ghost:
            Capsule().stroke(
                isHovering || isFocused ? Color.borderActive : Color.borderPanel,
                lineWidth: 1
            )
        case .filled:
            Capsule().stroke(accent.opacity(isHovering ? 0.5 : 0.3), lineWidth: 1)
        case .outlined:
            Capsule().stroke(
                isHovering || isFocused ? accent : accent.opacity(0.5),
                lineWidth: 1.5
            )
        }
    }
}

// MARK: - Supporting types

enum ButtonSize {
    case small, medium, large

    var dimension: CGFloat {
        switch self {
        case .small:  return 24
        case .medium: return 32
        case .large:  return 40
        }
    }
}

enum IconButtonVariant {
    case ghost     // 默认,灰色背景
    case filled    // 强调,accent 色背景
    case outlined  // 仅边框
}

// MARK: - Image extension(给 IconButton 内部用)

private extension Image {
    @ViewBuilder
    func iconSizeForButton(_ size: ButtonSize) -> some View {
        switch size {
        case .small:  self.iconSizeSmall()
        case .medium: self.iconSizeMedium()
        case .large:  self.iconSizeLarge()
        }
    }
}

#if DEBUG
struct IconButton_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 20) {
            HStack(spacing: 12) {
                IconButton(icon: Icon.record, action: {}, size: .small, accent: .signalRed)
                IconButton(icon: Icon.record, action: {}, size: .medium, accent: .signalRed)
                IconButton(icon: Icon.record, action: {}, size: .large, accent: .signalRed)
            }
            HStack(spacing: 12) {
                IconButton(icon: Icon.library, action: {}, variant: .ghost, accent: .signalGreen)
                IconButton(icon: Icon.library, action: {}, variant: .filled, accent: .signalGreen)
                IconButton(icon: Icon.library, action: {}, variant: .outlined, accent: .signalGreen)
            }
            HStack(spacing: 12) {
                IconButton(icon: Icon.settings, action: {})
                IconButton(icon: Icon.settings, action: {}, isEnabled: false)
            }
        }
        .padding(40)
        .background(Color.bgRoot)
    }
}
#endif
