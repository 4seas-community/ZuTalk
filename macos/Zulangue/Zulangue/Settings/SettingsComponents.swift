// SettingsComponents.swift
// 设置页面的标准化基本组件。
//
// 通用模式:
//   SettingsCard(title, subtitle?) { rows... }     — 一组相关设置的容器
//   SettingsRow(title, description?) { control }   — 左 label+hint,右 control
//
// 目标:替换之前每个 section 自己手写 InstrumentPanel 内部布局的混乱状态,
// 让所有 section 看起来是一个"设置页面"而不是 12 个风格各异的表单。

import SwiftUI

// MARK: - SettingsCard

/// 一组相关设置的容器。可选 title/subtitle 作为组标头,然后是一串 row。
/// Rows 之间有轻 divider,整体一个圆角边框包起来。
struct SettingsCard<Content: View>: View {
    let title: String?
    let subtitle: String?
    @ViewBuilder let content: () -> Content

    init(
        title: String? = nil,
        subtitle: String? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            if let title = title {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title.uppercased())
                        .font(Font.mono9)
                        .foregroundColor(Color.textSecondary)
                        .tracking(0.6)
                    if let subtitle = subtitle {
                        Text(subtitle)
                            .font(Font.sans11)
                            .foregroundColor(Color.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, Spacing.xs)
            }

            VStack(spacing: 0) {
                content()
            }
            .background(Color.bgElevated.opacity(0.4))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.sm)
                    .strokeBorder(Color.borderSubtle, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
        }
    }
}

// MARK: - SettingsRow

/// 单个设置项的标准行。
/// 左侧:title + 可选 description;右侧:control(Toggle / Picker / Button 等)。
/// 行间用细 divider 分隔(见 `SettingsRowDivider`)。
struct SettingsRow<Control: View>: View {
    let title: String
    let description: String?
    @ViewBuilder let control: () -> Control

    init(
        _ title: String,
        description: String? = nil,
        @ViewBuilder control: @escaping () -> Control
    ) {
        self.title = title
        self.description = description
        self.control = control
    }

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Font.sans12)
                    .foregroundColor(Color.textPrimary)
                if let description = description, !description.isEmpty {
                    Text(description)
                        .font(Font.sans11)
                        .foregroundColor(Color.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Spacing.md)
            control()
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, 10)
    }
}

/// 行内分隔线 — 放在 SettingsRow 之间。
struct SettingsRowDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.borderSubtle.opacity(0.5))
            .frame(height: 0.5)
            .padding(.horizontal, Spacing.md)
    }
}

// MARK: - SettingsFullRow
//
// 不带右侧 control 的行(说明/描述/多行内容直接铺满一行)。
// 用于需要整块说明的场景,比如 "Soniox API key 密钥" 这种单独成块的输入。

struct SettingsFullRow<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            content()
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, 10)
    }
}

// MARK: - 便捷:设置段落的顶部标题(取代原来的 SettingsSectionHeader,让 spacing 统一)

struct SettingsPageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(Color.textPrimary)
            Text(subtitle)
                .font(Font.sans12)
                .foregroundColor(Color.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, Spacing.md)
    }
}
