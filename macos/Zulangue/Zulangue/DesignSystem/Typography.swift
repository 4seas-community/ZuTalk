// Typography.swift
// Zulangue typography.
//
// The native app uses SF Rounded for display text, system sans for body text,
// and tabular mono for data.
//
import SwiftUI

// MARK: - Font Constitution

extension Font {

    // ════════════════════════════════════════════════════════
    // Zulangue display
    // ════════════════════════════════════════════════════════

    static let brandDisplayXL = Font.system(size: 48, weight: .bold, design: .rounded)
    static let brandDisplayLG = Font.system(size: 32, weight: .bold, design: .rounded)
    static let brandTitle     = Font.system(size: 20, weight: .semibold, design: .rounded)
    static let brandCaption   = Font.system(size: 11, weight: .semibold, design: .rounded)

    /// Onboarding display font.
    static let heroSerif      = Font.brandDisplayXL

    /// Legacy name used by onboarding step titles.
    static let heroSerifSM    = Font.brandDisplayLG

    // ════════════════════════════════════════════════════════
    // §06.2 DISPLAY · 大号数字(elapsed / cover title)
    // ════════════════════════════════════════════════════════

    static let displayXL      = Font.brandDisplayXL
    static let displayLG      = Font.brandDisplayLG

    /// data-xl: elapsed "00:03:12"
    static let dataXL         = Font.system(size: 48, weight: .medium, design: .monospaced).monospacedDigit()
    static let dataLG         = Font.system(size: 24, weight: .medium, design: .monospaced).monospacedDigit()

    // ════════════════════════════════════════════════════════
    // §06.2 TITLE
    // ════════════════════════════════════════════════════════

    static let titleLG        = Font.brandTitle
    /// card title
    static let titleMD        = Font.system(size: 16, weight: .medium)
    /// list item title
    static let titleSM        = Font.system(size: 13, weight: .medium)

    // ════════════════════════════════════════════════════════
    // §06.2 BODY
    // ════════════════════════════════════════════════════════

    static let bodyLG         = Font.system(size: 15, weight: .regular)
    static let body           = Font.system(size: 13, weight: .regular)
    static let bodyMedium     = Font.system(size: 13, weight: .medium)
    static let bodySM         = Font.system(size: 12, weight: .regular)

    // ════════════════════════════════════════════════════════
    // §06.2 CAPTION · UPPERCASE + tracking (label / tag / 元数据)
    // ════════════════════════════════════════════════════════

    static let caption        = Font.system(size: 11, weight: .regular, design: .monospaced)
    static let captionMedium  = Font.system(size: 11, weight: .medium,  design: .monospaced)
    static let captionXs      = Font.system(size: 9,  weight: .regular, design: .monospaced)

    // ════════════════════════════════════════════════════════
    // §06.2 DATA · tabular mono (时间戳 / model name / 数字对齐)
    // ════════════════════════════════════════════════════════

    static let data           = Font.system(size: 13, weight: .regular, design: .monospaced).monospacedDigit()
    static let dataMedium     = Font.system(size: 13, weight: .medium,  design: .monospaced).monospacedDigit()
    static let dataSM         = Font.system(size: 11, weight: .regular, design: .monospaced).monospacedDigit()

    // ════════════════════════════════════════════════════════
    // LEGACY ALIAS · v1.0 mono/sans 命名保留,值不变
    // 所有新代码应使用上面的 semantic name
    // ════════════════════════════════════════════════════════

    static let mono8  = Font.system(size: 8,  weight: .regular, design: .monospaced)
    static let mono9  = Font.system(size: 9,  weight: .regular, design: .monospaced)
    static let mono10 = Font.system(size: 10, weight: .regular, design: .monospaced)
    static let mono11 = Font.system(size: 11, weight: .regular, design: .monospaced)
    static let mono12 = Font.system(size: 12, weight: .regular, design: .monospaced)

    static let mono10Medium = Font.system(size: 10, weight: .medium, design: .monospaced)
    static let mono11Medium = Font.system(size: 11, weight: .medium, design: .monospaced)

    static let monoNum10 = Font.system(size: 10, weight: .regular).monospacedDigit()
    static let monoNum11 = Font.system(size: 11, weight: .regular).monospacedDigit()
    static let monoNum12 = Font.system(size: 12, weight: .medium).monospacedDigit()

    static let sans9         = Font.system(size: 9,  weight: .regular)
    static let sans9Medium   = Font.system(size: 9,  weight: .medium)
    static let sans10        = Font.system(size: 10, weight: .regular)
    static let sans11        = Font.system(size: 11, weight: .regular)
    static let sans12        = Font.system(size: 12, weight: .regular)
    static let sans13        = Font.system(size: 13, weight: .regular)
    static let sans14        = Font.system(size: 14, weight: .regular)
    static let sans16        = Font.system(size: 16, weight: .regular)
    static let sans18        = Font.system(size: 18, weight: .regular)

    static let sans10Medium  = Font.system(size: 10, weight: .medium)
    static let sans11Medium  = Font.system(size: 11, weight: .medium)
    static let sans12Medium  = Font.system(size: 12, weight: .medium)
    static let sans13Medium  = Font.system(size: 13, weight: .medium)
    static let sans14Medium  = Font.system(size: 14, weight: .medium)
    static let sans16Medium  = Font.system(size: 16, weight: .medium)

    static let sans11Semibold = Font.system(size: 11, weight: .semibold)
    static let sans12Semibold = Font.system(size: 12, weight: .semibold)
    static let sans13Semibold = Font.system(size: 13, weight: .semibold)
    static let sans14Semibold = Font.system(size: 14, weight: .semibold)

    static let sans18Bold    = Font.system(size: 18, weight: .bold)
    static let sans24Bold    = Font.system(size: 24, weight: .bold)
}

// MARK: - Text Style Modifiers

extension View {

    /// Caption UPPERCASE + tracking 0.10em (§06.4)
    /// 用于 §01 TRANSCRIPT, REF-A-12, SONIOX RT-4 类元数据 label
    func captionLabel() -> some View {
        self
            .font(.caption)
            .tracking(1.1)   // 0.10em of 11pt
            .textCase(.uppercase)
    }

    /// Caption XS UPPERCASE + tracking (legal footer / build)
    func captionXsLabel() -> some View {
        self
            .font(.captionXs)
            .tracking(0.9)
            .textCase(.uppercase)
    }

    /// v1.0 instrumentLabel alias —— 映射到 captionLabel 语义
    func instrumentLabel() -> some View {
        self
            .font(.caption)
            .foregroundColor(Color.line50)
            .tracking(1.1)
            .textCase(.uppercase)
    }

    /// v1.0 instrumentValue alias
    func instrumentValue() -> some View {
        self
            .font(.data)
            .foregroundColor(Color.line70)
    }

    /// v1.0 metadataText alias
    func metadataText() -> some View {
        self
            .font(.caption)
            .foregroundColor(Color.line50)
    }

    /// v1.0 coordinateText alias
    func coordinateText() -> some View {
        self
            .font(.captionXs)
            .foregroundColor(Color.line30)
    }
}
