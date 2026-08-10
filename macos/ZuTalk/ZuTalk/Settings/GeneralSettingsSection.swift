// GeneralSettingsSection.swift
// 常规设置:应用语言 + 外观
// 语言集合的一致性由 scripts/check_locale_parity.sh 强制。
//
// 语言策略:
//   - 支持 th / en / fr / es / de / ko / ja / zh-Hans
//   - 首次启动探测系统语言,就近映射后写入 ui.language + AppleLanguages
//   - 设置里不再提供"跟随系统",用户选定即固化
//
// 切换路径:
//   用户在 Picker 里选 → @AppStorage("ui.language") 持久化
//   → UserDefaults 写 AppleLanguages(macOS 下次启动时 SwiftUI bundle 按这个装)
//   → CoreClient.shared.core?.setLocale(...) 立即把 Rust 端同步到同一 locale
//   → 弹重启提示(SwiftUI bundle 只在进程启动时读一次 AppleLanguages)

import SwiftUI

/// App UI 语言。只保留显式可选的语言;"跟随系统" 不作为用户选项,
/// 只在首次启动时用来"猜一次"默认值。
enum AppLanguage: String, CaseIterable, Identifiable {
    // 声明顺序即 Picker 展示顺序。泰语置顶以尊重产品最初使用地。
    case th
    case en
    case fr
    case es
    case de
    case ko
    case ja
    case zhHans = "zh-Hans"

    var id: String { rawValue }

    /// 展示名(走 Localizable.strings,picker 里每一条用当前 UI 语言显示)
    var displayNameKey: String.LocalizationValue {
        switch self {
        case .th:     return "lang.th"
        case .en:     return "lang.en"
        case .fr:     return "lang.fr"
        case .es:     return "lang.es"
        case .de:     return "lang.de"
        case .ko:     return "lang.ko"
        case .ja:     return "lang.ja"
        case .zhHans: return "lang.zh_hans"
        }
    }

    /// 推给 Rust `setLocale(...)` 的 BCP-47 标签。
    func resolvedLocaleTag() -> String { rawValue }

    /// 写 AppleLanguages(下次启动生效)
    func applyToAppleLanguages() {
        let defaults = UserDefaults.standard
        defaults.set([rawValue], forKey: "AppleLanguages")
        defaults.synchronize()
    }

    /// 从系统偏好探测最接近的支持语言。未命中时回退到 `.en`。
    static func detectFromSystem() -> AppLanguage {
        // Bundle.preferredLocalizations 是 macOS 按系统语言筛过我们 lproj
        // 清单后的最优匹配; 优先从它挑.
        for code in Bundle.main.preferredLocalizations {
            if let m = match(code) { return m }
        }
        // 再退一步,看当前 Locale
        if let m = match(Locale.current.identifier) { return m }
        return .en
    }

    /// 把任意 BCP-47 / ICU 区域标签映射到支持的语言,不支持时返回 nil。
    static func match(_ tag: String) -> AppLanguage? {
        let lower = tag.replacingOccurrences(of: "_", with: "-").lowercased()
        if lower == "zh" || lower.hasPrefix("zh-") { return .zhHans }
        if lower == "th" || lower.hasPrefix("th-") { return .th }
        if lower == "ko" || lower.hasPrefix("ko-") { return .ko }
        if lower == "ja" || lower.hasPrefix("ja-") { return .ja }
        if lower == "fr" || lower.hasPrefix("fr-") { return .fr }
        if lower == "es" || lower.hasPrefix("es-") { return .es }
        if lower == "de" || lower.hasPrefix("de-") { return .de }
        if lower == "en" || lower.hasPrefix("en-") { return .en }
        return nil
    }

    /// 读存储值; 不存在或无法识别(含遗留的 "system")时回退到系统探测值。
    static func currentFromStorage() -> AppLanguage {
        let raw = UserDefaults.standard.string(forKey: "ui.language") ?? ""
        if let known = AppLanguage(rawValue: raw) { return known }
        return detectFromSystem()
    }

    /// 首次启动/遗留值清洗: 没有合法存储值时,探测并写进去(同时同步 AppleLanguages)。
    /// 返回最终生效的语言。
    @discardableResult
    static func seedIfNeeded() -> AppLanguage {
        let defaults = UserDefaults.standard
        let raw = defaults.string(forKey: "ui.language") ?? ""
        if let known = AppLanguage(rawValue: raw) { return known }

        let picked = detectFromSystem()
        defaults.set(picked.rawValue, forKey: "ui.language")
        picked.applyToAppleLanguages()
        return picked
    }
}

struct GeneralSettingsSection: View {
    @AppStorage("ui.language") private var language: String = AppLanguage.en.rawValue
    @AppStorage("appearance") private var appearance: String = AppearanceMode.system.rawValue

    @State private var showRestartHint: Bool = false
    @State private var automaticallyChecksForUpdates = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            SettingsSectionHeader(
                title: String(localized: "settings.general.title"),
                subtitle: String(localized: "settings.general.subtitle")
            )

            // Language
            InstrumentPanel(padding: Spacing.md) {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    Text("settings.language.title")
                        .font(Font.mono8)
                        .foregroundColor(Color.textMuted)
                        .tracking(0.6)

                    Picker("", selection: $language) {
                        ForEach(AppLanguage.allCases) { lang in
                            Text(String(localized: lang.displayNameKey)).tag(lang.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .onChange(of: language) { _, newValue in
                        applyLanguage(newValue)
                    }

                    if showRestartHint {
                        Text("settings.language.restart_hint")
                            .font(Font.sans11)
                            .foregroundColor(Color.signalAmber)
                    } else {
                        Text("settings.language.hint")
                            .font(Font.sans11)
                            .foregroundColor(Color.textTertiary)
                    }
                }
            }

            // Appearance
            InstrumentPanel(padding: Spacing.md) {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    Text("settings.appearance.title")
                        .font(Font.mono8)
                        .foregroundColor(Color.textMuted)
                        .tracking(0.6)

                    Picker("", selection: $appearance) {
                        ForEach(AppearanceMode.allCases, id: \.rawValue) { mode in
                            Text(mode.displayName).tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .onChange(of: appearance) { _, newValue in
                        if let mode = AppearanceMode(rawValue: newValue) {
                            applyAppearance(mode)
                        }
                    }
                }
            }

            SettingsCard(
                title: String(localized: "settings.updates.title"),
                subtitle: String(localized: "settings.updates.subtitle")
            ) {
                SettingsRow(
                    String(localized: "settings.updates.automatic"),
                    description: String(localized: "settings.updates.automatic_hint")
                ) {
                    Toggle("", isOn: $automaticallyChecksForUpdates)
                        .labelsHidden()
                        .disabled(!SoftwareUpdateController.shared.isAvailable)
                        .onChange(of: automaticallyChecksForUpdates) { _, enabled in
                            SoftwareUpdateController.shared.setAutomaticallyChecksForUpdates(enabled)
                        }
                }
                SettingsRowDivider()
                SettingsRow(String(localized: "updates.check")) {
                    Button(String(localized: "updates.check")) {
                        SoftwareUpdateController.shared.checkForUpdates()
                    }
                }
            }
        }
        .onAppear {
            // 进面板时,清洗遗留值(用户历史上可能是 "system")到显式语言
            let effective = AppLanguage.seedIfNeeded()
            if effective.rawValue != language {
                language = effective.rawValue
            }
            automaticallyChecksForUpdates =
                SoftwareUpdateController.shared.automaticallyChecksForUpdates
        }
    }

    private func applyLanguage(_ rawValue: String) {
        guard let lang = AppLanguage(rawValue: rawValue) else { return }
        lang.applyToAppleLanguages()
        // Rust 端立即同步(不等重启也能生效 — 错误消息走新 locale)
        CoreClient.shared.core?.setLocale(tag: lang.resolvedLocaleTag())
        showRestartHint = true
    }

    private func applyAppearance(_ mode: AppearanceMode) {
        switch mode {
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        case .system:
            NSApp.appearance = nil
        }
    }
}
