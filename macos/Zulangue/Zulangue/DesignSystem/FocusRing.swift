// FocusRing.swift
// Zulangue 键盘 focus 统一规范
// 权威:docs/redesign/redesign-plan.md §4.A.5
//
// 设计原则 5(原则 #5 from redesign-plan §2):
// Focus ring 是底线,不是装饰。所有 input/button/list item/tab
// 必须有键盘 focus 可见态。
//
// 当前代码中 0 个组件有 focus ring → 键盘用户和 VoiceOver 用户基本无法用。
// 交互组件共用的焦点环 modifier。

import SwiftUI

struct FocusRingModifier: ViewModifier {
    let isFocused: Bool
    let cornerRadius: CGFloat
    let intensity: FocusIntensity

    func body(content: Content) -> some View {
        content.overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(
                    Color.brandAccent.opacity(isFocused ? intensity.opacity : 0),
                    lineWidth: intensity.lineWidth
                )
                .shadow(
                    color: Color.shadowFocus.opacity(isFocused ? 1 : 0),
                    radius: isFocused ? intensity.shadowRadius : 0
                )
                .animation(Motion.microInteraction, value: isFocused)
        )
    }
}

/// Focus ring 的强度,决定线宽和阴影
enum FocusIntensity {
    case subtle    // 1px,适合小元素
    case standard  // 2px,适合中等元素(LabeledButton)
    case strong    // 3px,适合大元素(EmptyState 主按钮)

    var lineWidth: CGFloat {
        switch self {
        case .subtle:   return 1
        case .standard: return 2
        case .strong:   return 3
        }
    }

    var opacity: Double {
        switch self {
        case .subtle:   return 0.5
        case .standard: return 0.7
        case .strong:   return 0.9
        }
    }

    var shadowRadius: CGFloat {
        switch self {
        case .subtle:   return 4
        case .standard: return 6
        case .strong:   return 10
        }
    }
}

// MARK: - View modifier helper

extension View {
    /// 统一的 focus ring,强制集成在所有交互组件
    ///
    /// 用法:
    /// ```
    /// Button { ... }
    ///     .focusable()
    ///     .focused($isFocused)
    ///     .focusRing(isFocused, cornerRadius: Radius.sm)
    /// ```
    func focusRing(
        _ isFocused: Bool,
        cornerRadius: CGFloat = Radius.sm,
        intensity: FocusIntensity = .standard
    ) -> some View {
        modifier(FocusRingModifier(
            isFocused: isFocused,
            cornerRadius: cornerRadius,
            intensity: intensity
        ))
    }
}
