// EmptyState.swift
// Zulangue Design Constitution v2.0 · §08 + §13.1
//
// v2.0 强制规则:
//   · 每个空态必须有 Arcanum 插画(§08 Illustration Language),不允许纯 "No items"
//   · 允许的 fallback: SF Symbol icon(过渡期) —— 但长期目标是全部替换为 Arcanum
//
// 强制 4 元素(保留 v1.0):
//   · illustration  — Arcanum 插画(首选)或 SF Symbol icon(过渡)
//   · title         — 一句话状态
//   · description   — 告诉用户该做什么
//   · action(可选)  — 主动作按钮
//
// 用法(新):
//   EmptyState(
//       illustration: { Arcanum001Oscillator() },
//       title: "No sessions yet",
//       description: "Drag an audio file here, or press Fn to dictate.",
//       action: ("Start recording", { start() })
//   )
//
// 用法(过渡):
//   EmptyState(
//       icon: Icon.library,
//       title: "No sessions yet",
//       description: "...",
//       action: ...
//   )

import SwiftUI

struct EmptyState<Illustration: View>: View {
    let illustration: () -> Illustration
    let title: String
    let description: String
    let actionLabel: String?
    let actionHandler: (() -> Void)?

    init(
        @ViewBuilder illustration: @escaping () -> Illustration,
        title: String,
        description: String,
        action: (label: String, handler: () -> Void)? = nil
    ) {
        self.illustration = illustration
        self.title = title
        self.description = description
        self.actionLabel = action?.label
        self.actionHandler = action?.handler
    }

    var body: some View {
        VStack(spacing: Spacing.lg) {
            illustration()

            VStack(spacing: Spacing.sm) {
                Text(title)
                    .font(.titleMD)
                    .foregroundColor(Color.line100)
                    .multilineTextAlignment(.center)

                Text(description)
                    .font(.body)
                    .foregroundColor(Color.line50)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let actionLabel, let actionHandler {
                LabeledButton(
                    label: actionLabel,
                    action: { actionHandler() },
                    variant: .primary,
                    size: .medium
                )
                .padding(.top, Spacing.sm)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Spacing.xl)
    }
}

// MARK: - Convenience: SF Symbol fallback (transitional)

extension EmptyState where Illustration == _EmptyStateIcon {
    /// v1.0 兼容初始化 —— 用 SF Symbol 图标。
    /// 过渡期使用;长期应替换为具体 Arcanum 插画。
    init(
        icon: String,
        title: String,
        description: String,
        action: (label: String, handler: () -> Void)? = nil
    ) {
        self.init(
            illustration: { _EmptyStateIcon(systemName: icon) },
            title: title,
            description: description,
            action: action
        )
    }
}

/// 内部使用:SF Symbol 图标的空态降级插画。
struct _EmptyStateIcon: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .iconSizeHero()
            .foregroundColor(Color.line30)
    }
}

// MARK: - Preview

#if DEBUG
struct EmptyState_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            // v2.0 首选:Arcanum 插画
            EmptyState(
                illustration: { Arcanum001Oscillator() },
                title: "No sessions yet",
                description: "Drag an audio file here, or press Fn to dictate.",
                action: ("Start recording", { print("record") })
            )
            .previewDisplayName("v2.0 · Arcanum")

            // 过渡期:SF Symbol fallback
            EmptyState(
                icon: Icon.library,
                title: "No sessions yet",
                description: "Fallback while Arcanum library is being authored.",
                action: ("Start recording", { print("record") })
            )
            .previewDisplayName("v1.0 fallback")
        }
        .frame(width: 720, height: 480)
        .background(Color.surface)
    }
}
#endif
