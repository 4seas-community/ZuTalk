// AccessibilityID.swift
// SwiftUI 元素使用的稳定 accessibility identifier。
//
// 这些 ID 既给 production code 用 (.accessibilityIdentifier(AccessibilityID.xxx)),
// 也给 ZuTalkUITests 用 (XCUIApplication().buttons[AccessibilityID.xxx]).
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

    /// 字幕浮窗左上角：铺满当前显示器或恢复窗口
    static let floatingSubtitleMaximize = "capture.floatingSubtitles.maximize"

    /// 字幕浮窗左上角：贴顶横幅（整屏宽、高度可调）或恢复窗口
    static let floatingSubtitleBanner = "capture.floatingSubtitles.banner"

    /// 字幕浮窗右上角：减小或放大字号
    static let floatingSubtitleFontSmaller = "capture.floatingSubtitles.fontSmaller"
    static let floatingSubtitleFontLarger = "capture.floatingSubtitles.fontLarger"
    static let floatingSubtitleFontAuto = "capture.floatingSubtitles.fontAuto"

    // MARK: - Main Window

    /// 开始录音(录音中是「正在录音」)。
    static let mainTabRecord = "main.tab.record"

    /// 全部录音。
    static let mainTabLibrary = "main.tab.library"
    static let mainTabHome    = "main.tab.library"
    static let mainTabTopics  = "main.tab.topics"

    /// 设置
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

    // MARK: - 城与档案馆

    /// 设置 › 城:登录卡片和它里面的每一步
    static let citySettingsSignIn = "settings.city.sign-in"
    static let citySettingsServer = "settings.city.server"
    static let citySettingsContinue = "settings.city.continue"
    static let citySettingsQRCode = "settings.city.qr"
    static let citySettingsCopyCode = "settings.city.copy-code"
    static let citySettingsCheckDigits = "settings.city.check-digits"
    static let citySettingsNewCode = "settings.city.new-code"
    static let citySettingsUseRecoveryKey = "settings.city.use-recovery-key"
    static let citySettingsRecoveryKey = "settings.city.recovery-key"
    static let citySettingsRecoverySignIn = "settings.city.recovery-sign-in"
    static let citySettingsChangeCity = "settings.city.change-city"
    static let citySettingsProblem = "settings.city.problem"

    /// 设置 › 城:登录以后
    static let citySettingsAccount = "settings.city.account"
    static let citySettingsSignOut = "settings.city.sign-out"
    static let citySettingsSpeakerNames = "settings.city.speaker-names"
    static let citySettingsMarks = "settings.city.marks"
    static let citySettingsWhen = "settings.city.when"
    static let citySettingsFilings = "settings.city.filings"
    static let citySettingsFilingOpen = "settings.city.filing.open"
    static let citySettingsFilingUpdate = "settings.city.filing.update"
    static let citySettingsFilingWithdraw = "settings.city.filing.withdraw"
    static let citySettingsFilingRetry = "settings.city.filing.retry"
    static let citySettingsFilingFile = "settings.city.filing.file"
    static let citySettingsFilingChange = "settings.city.filing.change"
    static let citySettingsFilingDrop = "settings.city.filing.drop"
    static let citySettingsFilingShow = "settings.city.filing.show"
    static let citySettingsFilingMore = "settings.city.filing.more"
    /// 表头那一行:「3 场已交 · 1 场排队 · 1 场没交上」
    static let citySettingsFilingsSummary = "settings.city.filings.summary"

    /// 「交到档案馆的录音」表里的一行 (拼接 session id)
    static func citySettingsFiling(sessionId: String) -> String {
        "settings.city.filing.\(sessionId)"
    }

    /// 主题设置里的「档案馆」卡片和频道选单
    static let cityTopicCard = "capture.settings.city"
    static let cityTopicChannel = "capture.settings.city.channel"

    /// 「开始录音」页的「归到活动」一行
    static let cityRecordRow = "record.page.city"
    static let cityRecordEvent = "record.page.city.event"
    static let cityRecordSummary = "record.page.city.summary"
    static let cityRecordPick = "record.page.city.pick"

    /// 同时有好几场活动时列出来的一场 (拼接活动 id)
    static func cityRecordChoice(eventId: String) -> String {
        "record.page.city.choice.\(eventId)"
    }

    /// 「归到哪场活动」那张表
    static let cityPicker = "city.picker"
    static let cityPickerSearch = "city.picker.search"
    static let cityPickerFilter = "city.picker.filter"
    static let cityPickerCalendar = "city.picker.calendar"
    static let cityPickerPreviousMonth = "city.picker.previous-month"
    static let cityPickerNextMonth = "city.picker.next-month"
    static let cityPickerList = "city.picker.list"
    static let cityPickerEmpty = "city.picker.empty"
    static let cityPickerRefresh = "city.picker.refresh"
    static let cityPickerNotFiling = "city.picker.not-filing"
    static let cityPickerCancel = "city.picker.cancel"
    static let cityPickerConfirm = "city.picker.confirm"

    /// 月历上的一天 (拼接 `2026-11-13` 这样的日期)
    static func cityPickerDay(_ day: String) -> String {
        "city.picker.day.\(day)"
    }

    /// 清单里的一场活动 (拼接活动 id)
    static func cityPickerEvent(id: String) -> String {
        "city.picker.event.\(id)"
    }

    /// 录音条上的去向和点开的那张卡
    static let cityBarChip = "recording-bar.city"
    static let cityBarCard = "recording-bar.city.card"
    static let cityBarChange = "recording-bar.city.change"
    static let cityBarNotFiling = "recording-bar.city.not-filing"

    /// 共享面板里的「档案馆」一段
    static let cityShare = "share.city"
    static let cityShareStatus = "share.city.status"
    static let cityShareOpen = "share.city.open"
    static let cityShareFile = "share.city.file"
    static let cityShareUpdate = "share.city.update"
    static let cityShareRetry = "share.city.retry"
    static let cityShareChange = "share.city.change"
    static let cityShareWithdraw = "share.city.withdraw"

    /// 录音页顶栏上「交到哪一步了」那一枚;点它打开共享面板
    static let cityRecordingStatus = "session.city.status"

    /// 录音列表里一行上的记号 (拼接 session id)
    static func cityRowMark(sessionId: String) -> String {
        "recording.row.city.\(sessionId)"
    }

    /// 侧栏底部「档案馆:1 场排队中」那一行;点它打开「设置 › 城」
    static let citySidebarLine = "sidebar.city.pending"

    /// 窗口底部「已交到档案馆」那条提示和它的按钮
    static let cityNotice = "city.notice"
    static let cityNoticeAction = "city.notice.action"
}
