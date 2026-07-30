// Motion.swift
// Zulangue 全局动画与 spring 配置
// 权威：docs/redesign/redesign-plan.md §4.A.3
//
// 设计原则:
// - 整个项目里 withAnimation 调用必须用 Motion 的 4 个 spring 之一
// - 不允许 hardcode .spring(response:..., dampingFraction:...) 或 .easeInOut(duration:...)
// - 4 个 spring 覆盖 99% 的场景:micro / panel / page / bouncy
//
// 设计原则 2(原则 #2 from redesign-plan §2):
// 所有状态切换必须有 motion(spring 80-120ms,严禁瞬间硬切)。
// 这就是给"尸体 UI 通电"的关键一层。

import SwiftUI

enum Motion {

    // MARK: - Spring presets

    /// 微交互 — 按钮 press / hover / 小元素切换
    /// 80-150ms 范围,几乎不可感知的延迟,强阻尼避免抖动
    /// 用法:`.animation(Motion.microInteraction, value: isHovering)`
    static let microInteraction = Animation.spring(response: 0.15, dampingFraction: 0.85)

    /// 面板切换 — Tab 切换 / Sheet 出现 / state 切换
    /// 200-300ms,标准交互过渡
    /// 用法:`withAnimation(Motion.panelTransition) { ... }`
    static let panelTransition = Animation.spring(response: 0.30, dampingFraction: 0.80)

    /// 路由切换 — Sheet / 全屏 / 大块 UI 出现
    /// 400-500ms,大幅度变化的过渡
    /// 用法:Sheet 弹出 / 大面板替换
    static let pageTransition = Animation.spring(response: 0.45, dampingFraction: 0.90)

    /// 醒目反馈 — 成功/错误/警告的弹簧反弹
    /// 300-400ms,有意识的"我在告诉你"
    /// 用法:成功 toast 出现 / 错误抖动 / 录音红点 pulse
    static let bouncyAttention = Animation.spring(response: 0.40, dampingFraction: 0.65)

    // MARK: - Duration constants(给非 spring 动画用)

    static let durationFast: Double   = 0.10  // 100ms,几乎瞬间但有 ease
    static let durationMedium: Double = 0.20  // 200ms,标准过渡
    static let durationSlow: Double   = 0.40  // 400ms,大块过渡

    // MARK: - Standard easing(给 fade / opacity 这种用)

    /// 标准 ease out(进入)
    static let easeOut = Animation.easeOut(duration: durationMedium)

    /// 快速 ease in(离开)
    static let easeIn = Animation.easeIn(duration: durationFast)
}

// MARK: - Convenience helpers

extension View {
    /// 微交互动画 — `.motionMicro(value: isHovering)`
    func motionMicro<V: Equatable>(value: V) -> some View {
        animation(Motion.microInteraction, value: value)
    }

    /// 面板切换动画 — `.motionPanel(value: selectedTab)`
    func motionPanel<V: Equatable>(value: V) -> some View {
        animation(Motion.panelTransition, value: value)
    }

    /// Stagger appear:多个 element 按顺序出现,每个延迟 stagger 时间
    /// 用法:在 ForEach 内部 `.staggerAppear(index: i)`
    /// 菜单栏 popover idle 行级联入场的标准 modifier
    func staggerAppear(index: Int, stagger: Double = 0.04) -> some View {
        modifier(StaggerAppearModifier(index: index, stagger: stagger))
    }
}

/// Stagger 出现 modifier — 每个 element 延迟 index * stagger 出现
struct StaggerAppearModifier: ViewModifier {
    let index: Int
    let stagger: Double

    @State private var appeared = false

    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : -6)
            .animation(
                Motion.microInteraction.delay(Double(index) * stagger),
                value: appeared
            )
            .onAppear { appeared = true }
            .onDisappear { appeared = false }
    }
}
