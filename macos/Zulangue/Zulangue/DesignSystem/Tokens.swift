// Tokens.swift
// Zulangue brand tokens.
//
// The current product shell stays V2/notebook-first. The visual language is
// mapped from the current product design system:
//   · FOREST       · #006A47 primary, solid/inverse surfaces
//   · MINT         · #8EF2C4 accent and inverse text
//   · PAPER/INK    · white + neutral stack for work surfaces
//   · SUN/SKY/PLUM · supporting data and illustration accents only
//
// Compatibility aliases keep existing views source-compatible.

import SwiftUI
import AppKit

// MARK: - Dynamic Color Helpers

extension Color {
    /// 根据系统 appearance 返回深色或浅色。
    static func dynamic(dark: NSColor, light: NSColor) -> Color {
        Color(NSColor.dynamic(dark: dark, light: light))
    }

    /// 双模 hex 颜色(opacity 共用)。
    static func dynamic(
        darkHex: UInt32,
        lightHex: UInt32,
        opacity: CGFloat = 1.0
    ) -> Color {
        Self.dynamic(
            dark:  NSColor(hex: darkHex,  opacity: opacity),
            light: NSColor(hex: lightHex, opacity: opacity)
        )
    }

    /// Line token 专用:dark 白 alpha · light 黑 alpha。
    static func dynamicLine(
        darkWhiteAlpha: CGFloat,
        lightBlackAlpha: CGFloat
    ) -> Color {
        Self.dynamic(
            dark:  NSColor.white.withAlphaComponent(darkWhiteAlpha),
            light: NSColor.black.withAlphaComponent(lightBlackAlpha)
        )
    }
}

extension NSColor {
    static func dynamic(dark: NSColor, light: NSColor) -> NSColor {
        NSColor(name: nil, dynamicProvider: { appearance in
            switch appearance.bestMatch(from: [.darkAqua, .aqua]) {
            case .darkAqua?:
                return dark
            default:
                return light
            }
        })
    }

    convenience init(hex: UInt32, opacity: CGFloat = 1.0) {
        let r = CGFloat((hex >> 16) & 0xFF) / 255.0
        let g = CGFloat((hex >> 8) & 0xFF) / 255.0
        let b = CGFloat(hex & 0xFF) / 255.0
        self.init(srgbRed: r, green: g, blue: b, alpha: opacity)
    }
}

// MARK: - Design Constitution v2.1 · Palette

extension Color {

    // ════════════════════════════════════════════════════════
    // Zulangue core palette
    // ════════════════════════════════════════════════════════

    // ════════════════════════════════════════════════════════
    // SURFACE · solid forest in dark mode, paper/mint in light mode
    // ════════════════════════════════════════════════════════
    static let surface:       Color = .dynamic(darkHex: 0x003D2B, lightHex: 0xFFFFFF)
    static let surfaceRaised: Color = .dynamic(darkHex: 0x005E3F, lightHex: 0xECFDF4)
    static let surfaceSunk:   Color = .dynamic(darkHex: 0x002A1D, lightHex: 0xF3F3F3)

    // ════════════════════════════════════════════════════════
    // §03.2 LINE · dark=白 alpha / light=黑 alpha
    // ════════════════════════════════════════════════════════
    static let line100: Color = .dynamicLine(darkWhiteAlpha: 1.00, lightBlackAlpha: 0.87)
    static let line70:  Color = .dynamicLine(darkWhiteAlpha: 0.70, lightBlackAlpha: 0.60)
    static let line50:  Color = .dynamicLine(darkWhiteAlpha: 0.50, lightBlackAlpha: 0.45)
    static let line30:  Color = .dynamicLine(darkWhiteAlpha: 0.30, lightBlackAlpha: 0.30)
    static let line15:  Color = .dynamicLine(darkWhiteAlpha: 0.15, lightBlackAlpha: 0.15)
    static let line10:  Color = .dynamicLine(darkWhiteAlpha: 0.10, lightBlackAlpha: 0.08)  // ★ 唯一边框色
    static let line05:  Color = .dynamicLine(darkWhiteAlpha: 0.05, lightBlackAlpha: 0.04)

    // ════════════════════════════════════════════════════════
    // ZULANGUE GREEN · brand palette primitive.
    // ════════════════════════════════════════════════════════
    static let signal:     Color = .dynamic(darkHex: 0x8EF2C4, lightHex: 0x006A47)
    static let signalDim:  Color = .dynamic(darkHex: 0xA6F6D1, lightHex: 0x005E3F)
    static let signalSoft: Color = .dynamic(
        dark:  NSColor(hex: 0x8EF2C4, opacity: 0.16),
        light: NSColor(hex: 0x006A47, opacity: 0.10)
    )
    static let signalGlow: Color = .dynamic(
        dark:  NSColor(hex: 0x8EF2C4, opacity: 0.28),
        light: NSColor(hex: 0x006A47, opacity: 0.18)
    )

    // ════════════════════════════════════════════════════════
    // BRAND ACCENT · Zulangue green theme.
    //
    // Navigation, selection, focus, primary actions, and brand marks use this
    // family. Filled controls use a mode-aware foreground so mint stays
    // legible in dark mode and forest stays legible in light mode.
    // ════════════════════════════════════════════════════════
    static var brandAccent:      Color { signal }
    static var brandAccentHover: Color { signalDim }
    static var brandAccentSoft:  Color { signalSoft }
    static var brandAccentGlow:  Color { signalGlow }
    static let brandAccentForeground: Color = .dynamic(
        darkHex: 0x004A33,
        lightHex: 0xFFFFFF
    )

    // ════════════════════════════════════════════════════════
    // ACTIVITY ORANGE · recording / processing status only.
    // `#FF6B00` is identical in light + dark mode (passes WCAG AA on both
    // backgrounds per the constitution audit). It deliberately remains
    // separate from the green product theme so an active recording is never
    // confused with an ordinary selection or primary action.
    // ════════════════════════════════════════════════════════
    static let accentOrangeInk: Color = .dynamic(darkHex: 0xFF6B00, lightHex: 0xFF6B00)
    static let accentOrangeInkDim: Color = .dynamic(darkHex: 0xCC5500, lightHex: 0xCC5500)
    static let accentOrangeInkSoft: Color = .dynamic(
        dark:  NSColor(hex: 0xFF6B00, opacity: 0.12),
        light: NSColor(hex: 0xFF6B00, opacity: 0.14)
    )
    static let accentOrangeInkGlow: Color = .dynamic(
        dark:  NSColor(hex: 0xFF6B00, opacity: 0.20),
        light: NSColor(hex: 0xFF6B00, opacity: 0.22)
    )

    // ════════════════════════════════════════════════════════
    // §03.2 SEMANTIC · 极稀少(destructive 浅底降饱和避免刺眼)
    // ════════════════════════════════════════════════════════
    static let destructive: Color = .dynamic(darkHex: 0xE30613, lightHex: 0xC00511)
    static let successInk: Color = .dynamic(darkHex: 0x8EF2C4, lightHex: 0x006A47)

    // ════════════════════════════════════════════════════════
    // §03.2 GOLD · 仅 ReferenceNumber / §08 / Export(浅底降饱和保仪表金感)
    // ════════════════════════════════════════════════════════
    static let gold:     Color = .dynamic(darkHex: 0xF3E079, lightHex: 0xB58900)
    static let goldDim:  Color = .dynamic(darkHex: 0xD8C760, lightHex: 0x7E6100)
    static let goldSoft: Color = .dynamic(
        dark:  NSColor(hex: 0xF3E079, opacity: 0.14),
        light: NSColor(hex: 0xB58900, opacity: 0.12)
    )

    // ════════════════════════════════════════════════════════
    // V1.0 LEGACY ALIAS · 零破坏重映射,自动继承 dual-mode
    // ════════════════════════════════════════════════════════

    // ─── Hardware Surface 名字族 ─────────────────────────────
    static var hwSilver:     Color { surface }
    static var hwSilverDeep: Color { surfaceSunk }
    static var hwSilverEdge: Color { line10 }
    static var hwSilverInk:  Color { surfaceRaised }

    static var hwBlack:      Color { line100 }
    static var hwBlackDim:   Color { line70 }
    static var hwBlackFaint: Color { line50 }
    static var hwBlackGhost: Color { line15 }

    // ─── Blueprint Internal 名字族 ───────────────────────────
    static var bpBlue:        Color { surface }
    static var bpBlueDeep:    Color { surfaceSunk }
    static var bpBlueLight:   Color { surfaceRaised }
    static var bpBlueOverlay: Color {
        .dynamic(
            dark:  NSColor(hex: 0x002A1D, opacity: 0.72),
            light: NSColor(hex: 0x004A33, opacity: 0.20)
        )
    }
    static var bpBlueChip: Color { surfaceRaised }

    static var bpLine:      Color { line100 }
    static var bpLineDim:   Color { line50 }
    static var bpLineFaint: Color { line05 }
    static var bpLineGhost: Color { line15 }

    // ─── Activity status · recording / processing only ──────────────
    static var accentOrange:      Color { accentOrangeInk }
    static var accentOrangeHover: Color { accentOrangeInkDim }
    static var accentOrangeSoft:  Color { accentOrangeInkSoft }
    static var accentOrangeGlow:  Color { accentOrangeInkGlow }

    static var accentGold:     Color { gold }
    static var accentGoldDim:  Color { goldDim }
    static var accentGoldSoft: Color { goldSoft }

    // ─── Background alias ────────────────────────────────────
    static var bgRoot:     Color { surface }
    static var bgPanel:    Color { surfaceRaised }
    static var bgSurface:  Color { surfaceRaised }
    static var bgElevated: Color { surfaceRaised }
    static var bgGlass: Color {
        .dynamic(
            dark:  NSColor(hex: 0x141414, opacity: 0.85),
            light: NSColor(hex: 0xFAFAFA, opacity: 0.90)
        )
    }

    // ─── Border alias · 全部收敛到 line10 (§02 第一定律) ──────
    static var borderSubtle: Color { line10 }
    static var borderPanel:  Color { line10 }
    static var borderActive: Color { line30 }

    // ─── Text alias ──────────────────────────────────────────
    static var textPrimary:   Color { line100 }
    static var textSecondary: Color { line70 }
    static var textTertiary:  Color { line50 }
    static var textMuted:     Color { line50 }
    static var textDim:       Color { line30 }

    // ─── 跨模式文字色 (v1.0 API,v2.1 全部 dual-mode 统一) ────
    static var textOnHw:      Color { line100 }
    static var textOnHwDim:   Color { line70 }
    static var textOnHwFaint: Color { line50 }

    static var textOnBp:      Color { line100 }
    static var textOnBpDim:   Color { line70 }
    static var textOnBpFaint: Color { line50 }

    // ─── Signal alias · 按宪法语义收拢 ───────────────────────
    static var signalGreen:     Color { successInk }
    static var signalGreenText: Color { successInk }
    static var signalRed:       Color { destructive }
    static var signalBlue:      Color { signal }
    static var signalAmber:     Color { gold }
    static var signalPurple:    Color { gold }

    // ─── Semantic alias ──────────────────────────────────────
    static var success: Color { successInk }
    static var warning: Color { gold }
    static var error:   Color { destructive }
    static var info:    Color { signal }

    // ─── Shadow · dual-mode (浅底 shadow 更轻) ────────────────
    static let shadowSubtle: Color = .dynamic(
        dark:  NSColor(hex: 0x002A1D, opacity: 0.32),
        light: NSColor(hex: 0x004A33, opacity: 0.06)
    )
    static let shadowMedium: Color = .dynamic(
        dark:  NSColor(hex: 0x002A1D, opacity: 0.48),
        light: NSColor(hex: 0x004A33, opacity: 0.10)
    )
    static let shadowStrong: Color = .dynamic(
        dark:  NSColor(hex: 0x002A1D, opacity: 0.66),
        light: NSColor(hex: 0x004A33, opacity: 0.16)
    )
    static let shadowFocus: Color = .dynamic(
        dark:  NSColor(hex: 0x8EF2C4, opacity: 0.34),
        light: NSColor(hex: 0x006A47, opacity: 0.28)
    )

    // ─── LED ─────────────────────────────────────────────────
    static var ledOffOnBp:   Color { line15 }
    static var ledOffOnHw:   Color { line15 }

    // ─── Grid ────────────────────────────────────────────────
    static var gridLine: Color { line05 }

}

// MARK: - Hex Helper (保留 v2.0 Color 单模签名)

extension Color {
    init(hex: UInt32, opacity: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }
}

// MARK: - Radius Tokens

enum Radius {
    static let zero: CGFloat = 0
    static let xs:   CGFloat = 4
    static let sm:   CGFloat = 8
    static let md:   CGFloat = 12
    static let lg:   CGFloat = 16
    static let pill: CGFloat = 999
    static let full: CGFloat = 999
}

// MARK: - §05.1 Spacing Tokens (ONE LADDER · 七档)

enum Spacing {
    static let xs:  CGFloat = 4
    static let sm:  CGFloat = 8
    static let xsm: CGFloat = 12   // v2.0 新增
    static let md:  CGFloat = 16
    static let lg:  CGFloat = 24
    static let xl:  CGFloat = 32
    static let xxl: CGFloat = 48

    @available(*, deprecated, message: "v2.0 §02 第二定律:间距阶梯 {4,8,12,16,24,32,48}. 改用 .xxl.")
    @available(*, deprecated, message: "v2.0 §02 第二定律:间距阶梯 {4,8,12,16,24,32,48}. 改用 .xxl.")

    static let grid: CGFloat = 24
}

// MARK: - §04.1 Stroke Tokens (ONE LINE · UI 只有 1px)

enum Stroke {
    /// 仅 §08 Arcanum 插画使用
    static let hairline: CGFloat = 0.5
    /// ★ UI 所有边框
    static let thin:     CGFloat = 1
    /// signal active 下划线 / focus ring
    static let medium:   CGFloat = 2
    /// §08 插画主线 / 重点数据下划线
    /// hero 分区线(极稀少)
}
