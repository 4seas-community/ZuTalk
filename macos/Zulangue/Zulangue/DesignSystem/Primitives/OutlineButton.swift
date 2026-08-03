// OutlineButton.swift
// Branded action button. `.primary` is the Zulangue green filled pill;
// secondary `.ghost` / `.subtle` stay quiet with line-100 / line-50 outline.
// Ghost-hover lights up with brand green to telegraph that the action
// will become primary on commit.

import SwiftUI

/// Branded action button.
struct OutlineButton: View {
    let title: String
    var icon: String? = nil
    var style: Style = .ghost
    var mode: Mode = .blueprint
    var fullWidth: Bool = false
    var disabled: Bool = false
    let action: () -> Void

    enum Style {
        case primary        // 品牌绿色填充(主 CTA)
        case ghost          // 细线透明(默认)
        case destructive    // 红填充
        case subtle         // 幽灵次要
    }

    /// ⚠️ v2.1 deprecated: §03.1 废除 hw/bp 双视觉语言,mode 参数 no-op。
    enum Mode {
        case blueprint
        @available(*, deprecated, message: "v2.1 §03.1: dual-mode tokens 统一解析,.hardware 与 .blueprint 等价。新代码省略 mode: 参数。")
        case hardware
    }

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.sm) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(title.uppercased())
                    .font(.captionMedium)
                    .tracking(0.9)
                if fullWidth {
                    Spacer()
                }
            }
            .foregroundColor(foregroundColor)
            .padding(.horizontal, Spacing.md + 4)  // 20pt
            .padding(.vertical, Spacing.sm + 2)   // 10pt
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .background(backgroundColor)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(borderColor, lineWidth: borderWidth)
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        }
        .buttonStyle(.plain)
        .opacity(disabled ? 0.4 : 1.0)
        .disabled(disabled)
        .onHover { hovering = $0 && !disabled }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }

    // MARK: - style resolver

    private var foregroundColor: Color {
        if disabled {
            return mode == .blueprint ? .textTertiary : .borderGhost
        }
        switch style {
        case .primary:
            return .brandAccentForeground
        case .ghost:
            if hovering { return .brandAccent }
            return mode == .blueprint ? .textPrimary : .textPrimary
        case .destructive: return .white
        case .subtle:
            return mode == .blueprint ? .textSecondary : .textTertiary
        }
    }

    private var backgroundColor: Color {
        switch style {
        case .primary:
            return hovering ? .brandAccentHover : .brandAccent
        case .ghost:
            if hovering {
                return mode == .blueprint
                    ? Color.brandAccent.opacity(0.08)
                    : Color.brandAccentSoft
            }
            return .clear
        case .destructive:
            return hovering ? Color.destructive.opacity(0.82) : .destructive
        case .subtle:
            return .clear
        }
    }

    private var borderColor: Color {
        switch style {
        case .primary, .destructive: return .clear
        case .ghost:
            if hovering { return .brandAccent }
            return mode == .blueprint ? .textTertiary : .textSecondary
        case .subtle:
            return mode == .blueprint ? .borderGhost : .borderGhost
        }
    }

    private var borderWidth: CGFloat {
        switch style {
        case .primary, .destructive: return 0
        case .ghost:    return hovering ? Stroke.medium : Stroke.thin
        case .subtle:   return Stroke.hairline
        }
    }

    private var cornerRadius: CGFloat {
        switch style {
        case .primary:
            return Radius.pill
        case .ghost, .destructive, .subtle:
            return Radius.sm
        }
    }
}

#if DEBUG
#Preview("Blueprint") {
    VStack(spacing: 16) {
        OutlineButton(title: "Start recording", icon: "record.circle.fill", style: .primary) {}
        OutlineButton(title: "Cancel", style: .ghost) {}
        OutlineButton(title: "Delete session", icon: "trash", style: .destructive) {}
        OutlineButton(title: "Secondary", style: .subtle) {}
        OutlineButton(title: "Full width", style: .ghost, fullWidth: true) {}
        OutlineButton(title: "Disabled", style: .ghost, disabled: true) {}
    }
    .padding(32)
    .frame(width: 320)
    .background(Color.bgRoot)
}

#Preview("Hardware") {
    VStack(spacing: 16) {
        OutlineButton(title: "Start recording", icon: "record.circle.fill", style: .primary) {}
        OutlineButton(title: "Cancel", style: .ghost) {}
        OutlineButton(title: "Delete", style: .destructive) {}
    }
    .padding(32)
    .frame(width: 320)
    .background(Color.bgRoot)
}
#endif
