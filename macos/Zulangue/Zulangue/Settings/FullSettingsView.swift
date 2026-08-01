// FullSettingsView.swift
// 设置面板 — Instrument Cipher 风格
// 视觉原则：design-system/MASTER.md

import SwiftUI
import Combine

/// Shorthand for looking up a string in Localizable.strings. Wraps String(localized:).
@inline(__always)
private func L(_ key: String.LocalizationValue) -> String {
    String(localized: key)
}

// MARK: - Settings Section
//
// 分组组织:
//   SERVICES   — 全局服务凭据与只读引擎说明
//   GENERAL    — general / shortcuts (UI 偏好 + 只读参考)

enum SettingsSection: String, CaseIterable, Identifiable {
    case services = "Services"
    case general = "General"
    case shortcuts = "Shortcuts"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .services:    return String(localized: "settings.section.services_name")
        case .general:     return String(localized: "settings.section.general_name")
        case .shortcuts:   return String(localized: "settings.section.shortcuts_name")
        }
    }

    var icon: String {
        switch self {
        case .services:    return "network"
        case .general:     return "gearshape"
        case .shortcuts:   return "command"
        }
    }
}

/// 侧边栏分组 — 每组包含若干 SettingsSection,按功能域归类。
private struct SettingsGroup {
    let titleKey: String.LocalizationValue
    let sections: [SettingsSection]
}

private let settingsGroups: [SettingsGroup] = [
    SettingsGroup(
        titleKey: "settings.group.services",
        sections: [.services]
    ),
    SettingsGroup(
        titleKey: "settings.group.general",
        sections: [.general, .shortcuts]
    ),
]

// MARK: - FullSettingsView

struct FullSettingsView: View {
    @State private var selectedSection: SettingsSection = .services

    var body: some View {
        HStack(spacing: 0) {
            // 左侧导航
            sidebar
                .frame(width: 220)
                .background(Color.bgRoot)

            Rectangle()
                .fill(Color.borderSubtle)
                .frame(width: 1)

            // 右侧内容
            ScrollView {
                content
                    .padding(Spacing.xl)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .background(Color.bgRoot)
        }
        .background(Color.bgRoot)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(settingsGroups.enumerated()), id: \.offset) { idx, group in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(localized: group.titleKey))
                            .font(Font.mono9.weight(.medium))
                            .foregroundColor(Color.textSecondary)
                            .tracking(0.8)
                            .padding(.horizontal, Spacing.md)
                            .padding(.top, idx == 0 ? Spacing.lg : Spacing.md + 4)
                            .padding(.bottom, 6)

                        ForEach(group.sections) { section in
                            sidebarItem(section)
                        }
                    }
                }

                Spacer(minLength: Spacing.xl)
            }
        }
    }

    private func sidebarItem(_ section: SettingsSection) -> some View {
        Button(action: { selectedSection = section }) {
            HStack(spacing: 8) {
                Image(systemName: section.icon)
                    .font(.system(size: 11))
                    .frame(width: 14)
                    .foregroundColor(
                        selectedSection == section
                            ? Color.textSecondary
                            : Color.textTertiary
                    )
                Text(section.displayName)
                    .font(Font.sans11)
                    .foregroundColor(
                        selectedSection == section
                            ? Color.textSecondary
                            : Color.textTertiary
                    )
                Spacer()
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, 6)
            .background(
                selectedSection == section
                    ? Color.bgElevated
                    : Color.clear
            )
            .overlay(
                HStack {
                    if selectedSection == section {
                        Rectangle()
                            .fill(Color.brandAccent)
                            .frame(width: 2)
                    }
                    Spacer()
                }
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch selectedSection {
        case .services:    ServiceConnectionsSection()
        case .general:     GeneralSettingsSection()
        case .shortcuts:   ShortcutsSection()
        }
    }
}

// MARK: - Section Header

struct SettingsSectionHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(Font.mono10Medium)
                .foregroundColor(Color.textSecondary)
                .tracking(0.5)
            Text(subtitle)
                .font(Font.sans11)
                .foregroundColor(Color.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, Spacing.md)
    }
}

// MARK: - Service Connections

struct ServiceConnectionsSection: View {
    var body: some View {
        ProviderSettingsView()
    }
}

struct ShortcutsSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            SettingsSectionHeader(
                title: L("settings.shortcuts.title"),
                subtitle: L("settings.shortcuts.subtitle")
            )

            InstrumentPanel(padding: Spacing.md) {
                VStack(alignment: .leading, spacing: 10) {
                    shortcutRow(label: L("settings.shortcuts.toggle_recording"), keys: "⌃⌥R")
                    shortcutRow(label: L("settings.shortcuts.font_bigger"), keys: "⌃⌥+")
                    shortcutRow(label: L("settings.shortcuts.font_smaller"), keys: "⌃⌥-")
                    shortcutRow(label: L("settings.shortcuts.open_settings"), keys: "⌘,")
                }
            }
        }
    }

    private func shortcutRow(label: String, keys: String) -> some View {
        HStack {
            Text(label)
                .font(Font.sans11)
                .foregroundColor(Color.textTertiary)
            Spacer()
            Text(keys)
                .font(Font.mono10Medium)
                .foregroundColor(Color.textSecondary)
        }
    }
}

@ViewBuilder
private func placeholderPanel(_ message: String) -> some View {
    InstrumentPanel(padding: Spacing.lg) {
        Text(message)
            .font(Font.sans11)
            .foregroundColor(Color.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
