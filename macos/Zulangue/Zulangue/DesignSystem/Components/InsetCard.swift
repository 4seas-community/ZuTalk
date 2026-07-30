// InsetCard.swift
// Zulangue 微交互组件库 — 卡片容器
// 权威:docs/redesign/redesign-plan.md §4.B.2.3
//
// 设计原则覆盖:
//   #1 4 状态视觉反馈(default/hover/press 通过 elevation 自动)✓
//   #2 motion(microInteraction spring + scale)✓
//   #6 Elevation 分层系统 ✓(用 Elevation enum 而不是手写 shadow)
//
// 核心设计:
//   - hover 时 elevation 自动 +1(.raised → .floating)
//   - 微小 scale(1.005)给"被托举起来"的感觉
//   - onTap 让卡片本身可点击,内部不需要再嵌套 Button
//
// 用法:
//   InsetCard(elevation: .raised) {
//       VStack { ... }
//   }
//
//   InsetCard(elevation: .raised, onTap: { selectSession() }) {
//       SessionMetadata(session)
//   }

import SwiftUI

struct InsetCard<Content: View>: View {
    let content: Content

    var elevation: Elevation = .raised
    var padding: CGFloat = Spacing.md
    var cornerRadius: CGFloat = Radius.md
    var hoverable: Bool = true
    var onTap: (() -> Void)? = nil

    @State private var isHovering = false
    @State private var isPressing = false
    @FocusState private var isFocused: Bool

    init(
        elevation: Elevation = .raised,
        padding: CGFloat = Spacing.md,
        cornerRadius: CGFloat = Radius.md,
        hoverable: Bool = true,
        onTap: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.elevation = elevation
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.hoverable = hoverable
        self.onTap = onTap
        self.content = content()
    }

    private var currentElevation: Elevation {
        guard hoverable, isHovering || isFocused else { return elevation }
        return elevation.hoverElevated()
    }

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .elevation(currentElevation, cornerRadius: cornerRadius)
            .scaleEffect(scaleAmount)
            .focusable(onTap != nil)
            .focused($isFocused)
            .focusRing(isFocused, cornerRadius: cornerRadius, intensity: .standard)
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
            .onHover { isHovering = $0 }
            .onLongPressGesture(
                minimumDuration: 0,
                maximumDistance: .infinity,
                perform: {},
                onPressingChanged: { pressing in
                    isPressing = pressing && onTap != nil
                }
            )
            .onTapGesture { onTap?() }
            .animation(Motion.microInteraction, value: isHovering)
            .animation(Motion.microInteraction, value: isPressing)
    }

    private var scaleAmount: CGFloat {
        if isPressing { return 0.99 }
        if isHovering && hoverable { return 1.005 }
        return 1.0
    }
}

#if DEBUG
struct InsetCard_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 16) {
            InsetCard(elevation: .flat) {
                Text("Flat — 主背景,无 shadow").font(.sans12).foregroundColor(.textPrimary)
            }
            InsetCard(elevation: .raised) {
                Text("Raised — 默认卡片,subtle shadow").font(.sans12).foregroundColor(.textPrimary)
            }
            InsetCard(elevation: .floating) {
                Text("Floating — hover 卡片,medium shadow").font(.sans12).foregroundColor(.textPrimary)
            }
            InsetCard(elevation: .overlay) {
                Text("Overlay — Sheet,strong shadow + glass").font(.sans12).foregroundColor(.textPrimary)
            }
            InsetCard(elevation: .raised, onTap: { print("tapped") }) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Tappable card").font(.sans13Semibold).foregroundColor(.textPrimary)
                    Text("hover 我看 elevation+1 + scale 1.005").font(.sans11).foregroundColor(.textTertiary)
                }
            }
        }
        .padding(40)
        .background(Color.bgRoot)
        .frame(width: 380)
    }
}
#endif
