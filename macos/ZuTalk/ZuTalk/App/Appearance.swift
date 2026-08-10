// Appearance.swift
// 深色模式适配
// 权威：PRD §3.8

import SwiftUI
import Combine

/// 主题管理器
class ThemeManager: ObservableObject {
    @AppStorage("appearance") var appearance: AppearanceMode = .system

    func apply() {
        switch appearance {
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        case .system:
            NSApp.appearance = nil
        }
    }
}

/// 外观模式
enum AppearanceMode: String, CaseIterable {
    case system = "system"
    case light = "light"
    case dark = "dark"

    var displayName: String {
        switch self {
        case .system: return String(localized: "appearance.system")
        case .light: return String(localized: "appearance.light")
        case .dark: return String(localized: "appearance.dark")
        }
    }
}

/// 语义化颜色（自动适配深色/浅色）
extension Color {
    static let vtBackground = Color("Background")
    static let vtSurface = Color("Surface")
    static let vtPrimary = Color("Primary")
    static let vtSecondary = Color("Secondary")
    static let vtText = Color("TextPrimary")
    static let vtTextSecondary = Color("TextSecondary")
}
