// ZulangueApp.swift
// 应用入口 — Instrument Cipher 视觉系统
// 视觉原则：design-system/MASTER.md

import SwiftUI
import AppKit

// MARK: - App

@main
struct ZulangueApp: App {
    @NSApplicationDelegateAdaptor(ZulangueAppDelegate.self) private var appDelegate

    init() {
        CrashDiagnostics.install()
        WindowCoordinator.shared.installBaselineCatalog()
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button(String(localized: "updates.check")) {
                    SoftwareUpdateController.shared.checkForUpdates()
                }
            }
            // 主入口走 NSStatusItem(MenuBarCoordinator),屏蔽 SwiftUI 默认 File/New 菜单
            CommandGroup(replacing: .newItem) {}
            // 主窗口改由 AppKit WindowSystem 持有,不再暴露空白 SwiftUI settings scene。
            CommandGroup(replacing: .appSettings) {}
            // 屏蔽 Format 菜单 ⌘B/⌘I/⌘U 的默认 toggleBold:/toggleItalic:,
            // 让我们的 LoroBackedTextView.performKeyEquivalent 能接到
            CommandGroup(replacing: .textFormatting) {}
        }
    }
}

// MARK: - Main Window Reopen Helper

/// AppKit-owned 主窗口重开入口。
///
/// 主窗口由 WindowCoordinator 懒创建并重复显示。这里保留一个稳定入口，让
/// 菜单栏 popover、Dock 和热键
/// 都只依赖同一套 API。
@MainActor
final class MainWindowOpener {
    static let shared = MainWindowOpener()

    /// IntegrityChecks 用: WindowSystem 已具备主窗口创建能力。
    var isRegistered: Bool { WindowCoordinator.shared.isMainWindowReadyForOpen() }

    private func scheduleFollowUp(_ followUp: (@MainActor @Sendable () -> Void)?) {
        guard let followUp else { return }
        Task { @MainActor in
            followUp()
        }
    }

    /// 打开主窗口 (已存在则前置,不存在则由 coordinator 懒创建)。
    /// 可选 followUp 会在下一轮主线程 runloop 执行，避免窗口重建时丢失导航动作。
    func open(then followUp: (@MainActor @Sendable () -> Void)? = nil) {
        if TestEnvironment.isUnitTestMode {
            CrashDiagnostics.noteWindowOpenStrategy("unit-test-fallback", detail: "skip creating real main window in unit tests")
            NSApp.activate(ignoringOtherApps: true)
            scheduleFollowUp(followUp)
            return
        }

        WindowCoordinator.shared.showMainWindow()
        scheduleFollowUp(followUp)
    }
}

// MARK: - App Delegate

/// 应用代理
///
/// 负责：
/// - 启动时安装菜单栏 status item（MenuBarCoordinator）+ 麦克风权限监听
/// - 使用一致的窗口外观
/// - 注册全局快捷键（⌃⌥V / ⌃⌥R / ⌃⌥L 等）
@MainActor
final class ZulangueAppDelegate: NSObject, NSApplicationDelegate {
    @MainActor var mainWindowOpenAction: (@MainActor @Sendable () -> Void) = {
        WindowCommandRouter.shared.openMainWindow(detail: "app-delegate.default")
    }
    @MainActor var mainWindowVisibilityCheck: (@MainActor @Sendable () -> Bool) = {
        WindowCoordinator.shared.isMainWindowVisible()
    }
    var captureTerminationAction: (@MainActor @Sendable () async -> Void) = {
        await ActiveBilingualTranscriptStore.shared.prepareForApplicationTermination()
    }
    var requiresQuitConfirmationAction: (@MainActor @Sendable () -> Bool) = {
        ApplicationQuitConfirmationPolicy.requiresConfirmation(
            for: ActiveBilingualTranscriptStore.shared.captureState
        )
    }
    var confirmQuitAction: (@MainActor @Sendable () -> Bool) = {
        ApplicationQuitConfirmationAlert.confirmActiveRecordingQuit()
    }
    var requiresCaptureTerminationPreparationAction: (@MainActor @Sendable () -> Bool) = {
        ActiveBilingualTranscriptStore.shared.requiresApplicationTerminationPreparation
    }
    private var isPreparingCaptureTermination = false
    private var didPrepareCaptureTermination = false
    private weak var pendingTerminationApplication: NSApplication?
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 跟随用户偏好（默认 .system），由 ThemeManager 管理。
        // 用户可在 Settings → General → Appearance 切换 system/light/dark。
        ThemeManager().apply()

        // Provider credentials now use the app-private local file. Test hosts
        // must never inspect the signed-in user's real credential profile.
        if TestEnvironment.shouldLoadSavedProviderCredentials {
            do {
                try ProviderCredentialSession.shared.bootstrapSavedCredentials()
            } catch {
                // The provider path fails closed while local recording stays
                // available. The worker gate opens only after runtime scopes
                // are verifiably empty; if cleanup cannot be verified, it
                // remains closed rather than claiming remote work.
                DebugLog.error(
                    "Saved provider credentials could not be activated",
                    detail: error.localizedDescription
                )
            }
        } else if TestEnvironment.shouldPreloadFakeKeys {
            do {
                try ProviderCredentialSession.shared.bootstrapProcessOnlyCredential(
                    "ui-test-fake-soniox-key",
                    for: .soniox
                )
            } catch {
                DebugLog.error(
                    "UI-test provider credential bootstrap failed",
                    detail: error.localizedDescription
                )
            }
        }

        if !TestEnvironment.isUnitTestMode {
            openMainWindow()
        }

        if !TestEnvironment.isUnitTestMode {
            // The menu-bar status item is the primary persistent app entry now that
            // the Dynamic Island is gone. Lifecycle is independent of any window —
            // closing the main window leaves the status item in place.
            MenuBarCoordinator.shared.install()
            // Denied mic permission surfaces as a mic.slash menu-bar icon that opens
            // System Settings — same gate the suppressed island showed, new home.
            MenuBarSuppressionCoordinator.shared.start()
            // Full-screen safety net: macOS hides the menu bar in full-screen apps,
            // which would leave the menu-bar pulsing icon invisible. This controller
            // presents a tiny `.fullScreenAuxiliary` REC pill at the top of the
            // screen ONLY when (a) recording is active AND (b) the menu bar is
            // currently auto-hidden. Normal-mode usage never sees it.
            RecordingHudController.shared.install()
        }

        // Capture controls are Notebook-only. The global shortcut routes to
        // that Notebook instead of mutating capture from outside it.
        HotKeyManager.shared.installDefaults(
            toggleRecording: { [weak self] in self?.openCaptureNotebook() }
        )

        // 启动初始化:locale 固化。Provider credentials were already restored
        // from the private local file into Rust memory above.
        // 测试环境跳过,避免与 XCUITest 事件流冲突。
        if !TestEnvironment.isUnitTestMode && !TestEnvironment.isUITestMode {
            Task { @MainActor in
                // i18n: 首次启动探测系统语言并固化; 后续读存储值。
                // 同步把 locale 推给 Rust core, 让 CoreError 等 FFI 错误消息
                // 按当前 locale 渲染。
                let appLang = AppLanguage.seedIfNeeded()
                CoreClient.shared.core?.setLocale(tag: appLang.resolvedLocaleTag())
            }
        }

        // 菜单栏 status item 挂载完成后检查权限、通知、数据目录和核心状态。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if let initError = CoreClient.shared.initError, !TestEnvironment.isAnyTestMode {
                DebugLog.error("Zulangue core unavailable", detail: initError)
            }
            _ = IntegrityChecks.runOnLaunch()
        }
    }

    /// 主窗口恢复入口：Dock 再次点击、菜单栏「打开主窗口」、热键都走同一条路径。
    @MainActor
    @objc
    func handleOpenMainWindowRequest() {
        openMainWindow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if didPrepareCaptureTermination {
            return .terminateNow
        }
        if isPreparingCaptureTermination {
            return .terminateLater
        }
        if requiresQuitConfirmationAction(), confirmQuitAction() == false {
            return .terminateCancel
        }
        guard requiresCaptureTerminationPreparationAction() else {
            didPrepareCaptureTermination = true
            return .terminateNow
        }

        isPreparingCaptureTermination = true
        pendingTerminationApplication = sender
        Task { @MainActor [weak self] in
            guard let self else { return }
            await captureTerminationAction()
            didPrepareCaptureTermination = true
            isPreparingCaptureTermination = false
            let application = pendingTerminationApplication
            pendingTerminationApplication = nil
            application?.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openMainWindow()
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if !mainWindowVisibilityCheck() {
            openMainWindow()
        }
    }

    /// ⌘Q / 菜单 Quit / AppKit 主动 terminate 时同步落盘所有编辑器快照。
    ///
    /// 为什么必须:`core.applyEdit` 只把 session_id 塞进内存 HashSet,真正的
    /// `fs::write` 交给后台 tokio task 每 ~150ms drain 一次。用户敲最后几个字
    /// 立刻 ⌘Q → runtime 被切断 → 那一批 pending 永远写不到磁盘。
    ///
    /// `applicationShouldTerminate` 已先等待 capture 的 microphone ring 与
    /// push gate fence，完成 durable stop/interrupt。这里才允许同步 flush
    /// 编辑器并 shutdown Rust，避免关进程时丢掉已接收的音频。
    func applicationWillTerminate(_ notification: Notification) {
        guard let core = CoreClient.shared.core else { return }
        do {
            try core.flushAllEditorsSync()
            DebugLog.info("applicationWillTerminate: editor snapshots flushed")
        } catch {
            DebugLog.warn("flushAllEditorsSync failed on quit", detail: "\(error)")
        }
        try? core.shutdown()
    }

    // MARK: - Capture routing

    /// Global shortcuts and non-Notebook affordances only reveal the owning
    /// Notebook. They cannot mutate capture state.
    @MainActor
    private func openCaptureNotebook() {
        WindowCommandRouter.shared.openMainWindow(detail: "capture-route") {
            MainNavigationStoreV2.shared.openActiveNotebookForCapture()
        }
    }

    @MainActor
    private func openMainWindow() {
        mainWindowOpenAction()
    }

}

// MARK: - Helpers

extension Notification.Name {
    /// 异步转录完成后通知 LibraryView 刷新，sessionId 位于 object。
    static let zulangueSessionUpdated = Notification.Name("ZulangueSessionUpdated")
}

// MARK: - Main Window

/// Minimal MVP 主窗口：Home、Trash、Notebook editor 与 Settings。
enum MainTab: String, CaseIterable {
    case home
    case knowledge
    case trash
    case editor
    case config

    var label: String {
        switch self {
        case .home:       return "HOME"
        case .knowledge:  return "KNOWLEDGE"
        case .trash:      return "TRASH"
        case .editor:     return "EDITOR"
        case .config:     return "CONFIG"
        }
    }
}
