// LabeledButton.swift
// Zulangue 微交互组件库 — 文字按钮
// 权威:docs/redesign/redesign-plan.md §4.B.2.2
//
// 设计原则覆盖:
//   #1 4 状态视觉反馈 ✓
//   #2 motion ✓
//   #3 按钮"我听到你了"(立刻 loading + 完成态视觉)✓
//   #4 Loading/Empty/Error 叙事 ✓(loading 自动 spinner / success ✓ / error icon)
//   #5 focus ring ✓
//
// 用法 1 — 同步 action:
//   LabeledButton(label: "Cancel", action: { dismiss() }, variant: .secondary)
//
// 用法 2 — async action(自动 loading):
//   LabeledButton(label: "Generate Summary", action: {
//       await generateSummary()
//   }, variant: .primary, icon: Icon.summary)
//
// 用法 3 — 外部强制 state:
//   LabeledButton(
//       label: "Save",
//       action: { await save() },
//       loading: $isSaving,
//       error: errorMessage
//   )

import SwiftUI

struct LabeledButton: View {
    let label: String
    let action: () async -> Void

    var icon: String? = nil
    var variant: LabeledVariant = .primary
    var size: LabeledSize = .medium
    var fullWidth: Bool = false

    /// 外部强制 loading 状态(优先于内部)
    var externalLoading: Binding<Bool>? = nil
    /// 外部强制 success(显示 ✓ 800ms 后自动复位)
    var externalSuccess: Bool = false
    /// 外部强制 error(显示 ⚠ + 错误文字)
    var externalError: String? = nil
    var isEnabled: Bool = true

    @State private var internalLoading = false
    @State private var internalSuccess = false
    @State private var isHovering = false
    @State private var isPressing = false
    @FocusState private var isFocused: Bool

    private var isLoading: Bool {
        externalLoading?.wrappedValue ?? internalLoading
    }

    private var isShowingSuccess: Bool {
        externalSuccess || internalSuccess
    }

    private var hasError: Bool {
        externalError != nil
    }

    var body: some View {
        Button {
            Task {
                if externalLoading == nil { internalLoading = true }
                await action()
                if externalLoading == nil { internalLoading = false }
                internalSuccess = true
                try? await Task.sleep(nanoseconds: 800_000_000)
                internalSuccess = false
            }
        } label: {
            HStack(spacing: 6) {
                leadingIcon
                Text(label)
                    .font(size.font)
                    .foregroundColor(currentForeground)
                    .lineLimit(1)
            }
            .padding(.horizontal, size.hPadding)
            .padding(.vertical, size.vPadding)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .background(currentBackground)
            .overlay(currentBorder)
            .scaleEffect(isPressing ? 0.97 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || isLoading)
        .focusable(isEnabled)
        .focused($isFocused)
        .focusRing(isFocused, cornerRadius: Radius.sm, intensity: .standard)
        .accessibilityLabel(label)
        .onHover { isHovering = $0 && isEnabled && !isLoading }
        .onLongPressGesture(minimumDuration: 0, maximumDistance: .infinity, perform: {}, onPressingChanged: { pressing in
            isPressing = pressing && isEnabled && !isLoading
        })
        .animation(Motion.microInteraction, value: isHovering)
        .animation(Motion.microInteraction, value: isPressing)
        .animation(Motion.microInteraction, value: isLoading)
        .animation(Motion.bouncyAttention, value: isShowingSuccess)
    }

    @ViewBuilder
    private var leadingIcon: some View {
        if isLoading {
            ProgressView()
                .scaleEffect(0.6)
                .frame(width: 14, height: 14)
        } else if isShowingSuccess {
            Image(systemName: Icon.connected)
                .iconSizeSmall()
                .foregroundColor(.success)
        } else if hasError {
            Image(systemName: Icon.error)
                .iconSizeSmall()
                .foregroundColor(.error)
        } else if let icon {
            Image(systemName: icon)
                .iconSizeSmall()
        }
    }

    private var currentForeground: Color {
        if !isEnabled || isLoading { return variant.foreground.opacity(0.5) }
        if isHovering || isFocused { return variant.foregroundHover }
        return variant.foreground
    }

    private var currentBackground: some View {
        RoundedRectangle(cornerRadius: Radius.sm)
            .fill(
                isHovering || isFocused
                    ? variant.backgroundHover
                    : variant.background
            )
    }

    private var currentBorder: some View {
        RoundedRectangle(cornerRadius: Radius.sm)
            .stroke(
                hasError
                    ? Color.error
                    : (isHovering || isFocused ? variant.borderHover : variant.border),
                lineWidth: 1
            )
    }
}

// MARK: - Supporting types

enum LabeledVariant {
    case primary    // 品牌绿色填充,主要 CTA
    case secondary  // 灰色边框,次要操作
    case destructive // 红色边框,危险操作
    case ghost      // 无边框,文字按钮

    var background: Color {
        switch self {
        case .primary:     return .brandAccent
        case .secondary:   return .bgSurface
        case .destructive: return .bgSurface
        case .ghost:       return .clear
        }
    }
    var backgroundHover: Color {
        switch self {
        case .primary:     return .brandAccentHover
        case .secondary:   return .bgElevated
        case .destructive: return Color.error.opacity(0.15)
        case .ghost:       return .bgSurface.opacity(0.6)
        }
    }
    var foreground: Color {
        switch self {
        case .primary:     return .brandAccentForeground
        case .secondary:   return .textPrimary
        case .destructive: return .error
        case .ghost:       return .textSecondary
        }
    }
    var foregroundHover: Color {
        switch self {
        case .primary:     return .brandAccentForeground
        case .secondary:   return .textPrimary
        case .destructive: return .error
        case .ghost:       return .textPrimary
        }
    }
    var border: Color {
        switch self {
        case .primary:     return Color.brandAccent.opacity(0.5)
        case .secondary:   return .borderPanel
        case .destructive: return Color.error.opacity(0.5)
        case .ghost:       return .clear
        }
    }
    var borderHover: Color {
        switch self {
        case .primary:     return .brandAccent
        case .secondary:   return .borderActive
        case .destructive: return .error
        case .ghost:       return .clear
        }
    }
}

enum LabeledSize {
    case small, medium, large

    var font: Font {
        switch self {
        case .small:  return .sans11Semibold
        case .medium: return .sans12Semibold
        case .large:  return .sans13Semibold
        }
    }
    var hPadding: CGFloat {
        switch self {
        case .small:  return 10
        case .medium: return 14
        case .large:  return 18
        }
    }
    var vPadding: CGFloat {
        switch self {
        case .small:  return 5
        case .medium: return 7
        case .large:  return 9
        }
    }
}

#if DEBUG
struct LabeledButton_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 16) {
            LabeledButton(label: "Generate Summary", action: { try? await Task.sleep(nanoseconds: 1_500_000_000) }, icon: Icon.summary, variant: .primary)
            LabeledButton(label: "Cancel", action: {}, variant: .secondary)
            LabeledButton(label: "Delete", action: {}, icon: Icon.trash, variant: .destructive)
            LabeledButton(label: "Open Library", action: {}, variant: .ghost, fullWidth: true)
            LabeledButton(label: "Disabled", action: {}, variant: .primary, isEnabled: false)
        }
        .padding(40)
        .background(Color.bgRoot)
        .frame(width: 360)
    }
}
#endif
