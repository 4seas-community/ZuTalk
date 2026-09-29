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
// 三节,按「这件事关于什么」分,不按「这是哪种技术」分:
//   通用     — 语言、外观、更新、整理标记(可选的语言模型)、快捷键
//   实时字幕 — 让字幕跑起来的东西:Soniox 密钥或社区邀请
//   共享     — 此刻在外面的链接,一处看清、随手撤销
// 主题自己的设置(语言、专有词与背景、音频保留)在主题里,不在这里。

enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "General"
    case captions = "Captions"
    case sharing = "Sharing"
    case devices = "Devices"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .general:  return String(localized: "settings.section.general_name")
        case .captions: return String(localized: "settings.section.captions_name")
        case .sharing:  return String(localized: "settings.section.sharing_name")
        case .devices:  return String(localized: "settings.section.devices_name")
        }
    }

    var icon: String {
        switch self {
        case .general:  return "gearshape"
        case .captions: return "captions.bubble"
        case .sharing:  return "square.and.arrow.up"
        case .devices:  return "laptopcomputer"
        }
    }
}

/// 从别处点进设置时要落在哪一节 —— 比如「添加自己的密钥」直接落到实时字幕。
@MainActor
final class SettingsRouter: ObservableObject {
    static let shared = SettingsRouter()
    @Published var section: SettingsSection = .general
    private init() {}
}

// MARK: - FullSettingsView

struct FullSettingsView: View {
    @ObservedObject private var router = SettingsRouter.shared

    var body: some View {
        HStack(spacing: 0) {
            // 左侧导航
            sidebar
                .frame(width: 200)
                .background(Color.bgRoot)

            Rectangle()
                .fill(Color.borderSubtle)
                .frame(width: 1)

            // 右侧内容
            ScrollView {
                content
                    .padding(Spacing.xl)
                    .frame(maxWidth: 760, alignment: .topLeading)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .background(Color.bgRoot)
        }
        .background(Color.bgRoot)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsSection.allCases) { section in
                sidebarItem(section)
            }
            Spacer(minLength: Spacing.xl)
        }
        .padding(.top, Spacing.lg)
    }

    private func sidebarItem(_ section: SettingsSection) -> some View {
        Button(action: { router.section = section }) {
            HStack(spacing: 8) {
                Image(systemName: section.icon)
                    .font(.system(size: 11))
                    .frame(width: 14)
                    .foregroundColor(
                        router.section == section
                            ? Color.textSecondary
                            : Color.textTertiary
                    )
                Text(section.displayName)
                    .font(Font.sans11)
                    .foregroundColor(
                        router.section == section
                            ? Color.textSecondary
                            : Color.textTertiary
                    )
                Spacer()
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, 6)
            .background(
                router.section == section
                    ? Color.bgElevated
                    : Color.clear
            )
            .overlay(
                HStack {
                    if router.section == section {
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
        switch router.section {
        case .general:
            VStack(alignment: .leading, spacing: Spacing.xl) {
                GeneralSettingsSection()
                ProviderSettingsView(scope: .languageModel)
                ShortcutsSection()
            }
        case .captions:
            ProviderSettingsView(scope: .captions)
        case .sharing:
            SharingSettingsSection()
        case .devices:
            DevicesSettingsSection()
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

struct ShortcutsSection: View {
    var body: some View {
        SettingsCard(
            title: L("settings.shortcuts.title"),
            subtitle: L("settings.shortcuts.subtitle")
        ) {
            SettingsFullRow {
                VStack(alignment: .leading, spacing: 10) {
                    // Only what is actually registered: see HotKeyManager
                    // and the subtitle window's own buttons.
                    shortcutRow(label: L("settings.shortcuts.toggle_recording"), keys: "⌃⌥R")
                    shortcutRow(label: L("settings.shortcuts.pause"), keys: "⌃⌥P")
                    shortcutRow(label: L("settings.shortcuts.mark"), keys: "⌃⌥S")
                    shortcutRow(label: L("settings.shortcuts.overlay_banner"), keys: "⌃⌘B")
                    shortcutRow(label: L("settings.shortcuts.overlay_maximize"), keys: "⌃⌘F")
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
