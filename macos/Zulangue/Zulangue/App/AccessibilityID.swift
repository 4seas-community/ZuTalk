// AccessibilityID.swift
// SwiftUI 元素使用的稳定 accessibility identifier。
//
// 这些 ID 既给 production code 用 (.accessibilityIdentifier(AccessibilityID.xxx)),
// 也给 ZulangueUITests 用 (XCUIApplication().buttons[AccessibilityID.xxx]).
// 集中定义防止 UI test 和实际 view 失去同步.

import Foundation

enum AccessibilityID {
    // MARK: - Menu Bar status item (top-right macOS menu bar entry)

    /// 菜单栏 NSStatusItem 按钮本身
    static let menuBarStatusItem = "menubar.statusItem"

    /// 菜单栏 popover idle 状态:开始录音
    static let menuBarRecordButton = "menubar.button.record"

    /// 菜单栏 popover 录音状态：多语言字幕悬浮窗
    static let menuBarSubtitleButton = "menubar.button.subtitles"

    /// 菜单栏 popover idle 状态:Settings
    static let menuBarSettingsButton = "menubar.button.settings"
    static let menuBarCheckForUpdatesButton = "menubar.button.checkForUpdates"

    /// 菜单栏 popover 公共底部：退出整个应用
    static let menuBarQuitButton = "menubar.button.quit"

    /// 菜单栏 popover 录音状态:暂停/恢复
    static let menuBarRecordingPauseButton = "menubar.button.recordingPause"

    /// 菜单栏 popover 录音状态:停止
    static let menuBarRecordingStopButton = "menubar.button.recordingStop"

    /// 菜单栏和实时转录页：打开多语言字幕浮窗
    static let floatingSubtitleButton = "capture.button.floatingSubtitles"

    /// 字幕浮窗右上角：减小或放大字号
    static let floatingSubtitleFontSmaller = "capture.floatingSubtitles.fontSmaller"
    static let floatingSubtitleFontLarger = "capture.floatingSubtitles.fontLarger"
    static let floatingSubtitleFontAuto = "capture.floatingSubtitles.fontAuto"

    // MARK: - Main Window

    /// HOME 主入口。
    static let mainTabLibrary = "main.tab.library"
    static let mainTabHome    = "main.tab.library"

    /// 侧边栏底部 Settings icon
    static let mainTabConfig = "main.tab.config"

    /// Trash
    static let mainTabTrash     = "main.tab.trash"

    // MARK: - Library

    /// session 列表的单条 row (拼接 session id, e.g. "library.row.{uuid}")
    static func libraryRow(sessionId: String) -> String {
        "library.row.\(sessionId)"
    }

    /// session 列表空状态
    static let libraryEmptyState = "library.empty"

    // MARK: - Session Detail

    /// transcript tab
    static let sessionDetailTabTranscript = "sessionDetail.tab.transcript"

    /// summary tab
    static let sessionDetailTabSummary = "sessionDetail.tab.summary"

    /// audio tab
    static let sessionDetailTabAudio = "sessionDetail.tab.audio"

    /// 底部 audio player 的播放/暂停按钮
    static let sessionDetailPlayPauseButton = "sessionDetail.audioPlayer.playPause"

    /// transcript pane 的根容器。
    static let sessionDetailTranscriptPane = "sessionDetail.transcript"

    // MARK: - Settings

    /// API Keys section
    static let settingsApiKeys = "settings.section.apiKeys"

    // MARK: - Toast

    /// ToastCenter 显示的 toast 容器 (用于断言「Recording saved」等)
    static let toastContainer = "toast.container"
}
