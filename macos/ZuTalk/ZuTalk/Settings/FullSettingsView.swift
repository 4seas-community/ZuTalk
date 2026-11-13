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
// 三节,按「人会去哪找」分(docs/product/interface-layers.md):
//   账号 — 你是谁、出字靠什么、你的设备、城的档案馆
//   通用 — 界面语言、外观、更新、快捷键
//   高级 — 自己的密钥、正在分享的链接、备份与恢复、诊断信息;大多数人用不到
// 0.8.1 是五节(通用 / 实时字幕 / 共享 / 设备 / 城),一个人要认识八样像身份的
// 东西,散在五处。功能一样没少,只是挪到人会去找的地方。
// 主题自己的选项(语言、专有词与背景、音频保留)在主题里,不在这里。

enum SettingsSection: String, CaseIterable, Identifiable {
    case account = "Account"
    case general = "General"
    case advanced = "Advanced"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .account:  return String(localized: "settings.section.account_name")
        case .general:  return String(localized: "settings.section.general_name")
        case .advanced: return String(localized: "settings.section.advanced_name")
        }
    }

    var icon: String {
        switch self {
        case .account:  return "person.crop.circle"
        case .general:  return "gearshape"
        case .advanced: return "wrench.and.screwdriver"
        }
    }
}

/// 从别处点进设置时要落在哪一节。没人指定的时候是「账号」:人打开设置,
/// 最常找的是「我是谁、出字靠什么」。
@MainActor
final class SettingsRouter: ObservableObject {
    static let shared = SettingsRouter()
    static let defaultSection: SettingsSection = .account
    @Published var section: SettingsSection = SettingsRouter.defaultSection
    /// The app uses `shared`; tests make their own to see a fresh one.
    init() {}
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
            // 换一节就回到顶上。三节都比以前长,「用自己的密钥…」从「账号」
            // 中间跳到「高级」时,不该落在「高级」的中间。
            .id(router.section)
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
        .accessibilityAddTraits(router.section == section ? .isSelected : [])
        .accessibilityIdentifier("settings.section.\(section.rawValue.lowercased())")
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch router.section {
        case .account:
            AccountSettingsSection()
        case .general:
            VStack(alignment: .leading, spacing: Spacing.xl) {
                GeneralSettingsSection()
                ShortcutsSection()
            }
        case .advanced:
            AdvancedSettingsSection()
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
