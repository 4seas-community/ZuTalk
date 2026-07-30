// Accessibility.swift
// VoiceOver 辅助功能支持
// 权威：PRD §3.9

import SwiftUI

/// 辅助功能修饰符扩展
extension View {
    /// 为录音按钮添加辅助功能
    func recordingAccessibility(isRecording: Bool) -> some View {
        self
            .accessibilityLabel(Text(isRecording ? "a11y.record.stop" : "a11y.record.start"))
            .accessibilityHint(Text(isRecording ? "a11y.record.hint_stop" : "a11y.record.hint_start"))
            .accessibilityAddTraits(.isButton)
    }

    /// 为会话卡片添加辅助功能
    func sessionCardAccessibility(title: String, type: String, duration: String) -> some View {
        self
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                Text(String(format: String(localized: "a11y.session_card"), title, type, duration))
            )
    }

    /// 为浮窗面板添加辅助功能
    func floatingPanelAccessibility() -> some View {
        self
            .accessibilityLabel(Text("a11y.floating_panel"))
            .accessibilityHint(Text("a11y.floating_panel_hint"))
    }

    /// 为字幕窗口添加辅助功能
    func captionWindowAccessibility(languageCount: Int) -> some View {
        self
            .accessibilityLabel(Text("a11y.caption_window"))
            .accessibilityValue(
                Text(String(format: String(localized: "a11y.caption_window_langs"), languageCount))
            )
    }
}
