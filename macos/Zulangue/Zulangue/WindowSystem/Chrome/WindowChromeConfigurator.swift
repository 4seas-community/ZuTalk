// TrafficLightHover.swift
// 主窗口 chrome 加固 — 隐藏系统 traffic light,为自绘按钮让位
//
// 背景(macOS 26 踩坑):
// 系统 traffic light 按钮(close/miniaturize/zoom)在 SwiftUI
// .windowStyle(.hiddenTitleBar) 或 titlebarAppearsTransparent = true 场景下,
// 会常驻渲染为"非 key 态灰色",无法通过 makeKey / activate / styleMask 恢复
// 红黄绿. 这是 Tahoe 的新渲染行为,无公开 API 绕过.
//
// 对策: 系统按钮 isHidden = true 彻底隐藏,CustomTrafficLights.swift 里的
// 纯 AppKit 视图自画红黄绿,避免 titlebar 再挂一个 NSHostingView。
// 三颗圆点 + hover 淡入 + performClose/Miniaturize/ToggleFullScreen 走标准 NSWindow API.

import AppKit
import SwiftUI

// MARK: - 窗口 chrome 配置

@MainActor
final class WindowChromeConfigurator {
    static let shared = WindowChromeConfigurator()
    private static let mainWindowMinimumSize = NSSize(width: 900, height: 600)

    private var configured = Set<ObjectIdentifier>()
    private var resizeObservers: [ObjectIdentifier: NSObjectProtocol] = [:]
    private var closeObservers: [ObjectIdentifier: NSObjectProtocol] = [:]

    func configure(_ window: NSWindow) {
        let id = ObjectIdentifier(window)
        if configured.contains(id) { return }
        configured.insert(id)

        // 主窗口本身由 V2 MainWindowController 作为 AppKit owner 创建，内容区
        // 下方只有我们挂进去的 NSHostingView/Controller。它们默认会把内容
        // intrinsic / min / max size 反推回 window,在 Home ↔ Editor ↔ Onboarding
        // 切换时触发 updateAnimatedWindowSize 递归。
        let stabilization = stabilizeSwiftUIHostingTree(on: window)
        CrashDiagnostics.noteHostingSizingStabilized(
            role: "main",
            controllersDisabled: stabilization.controllersDisabled,
            viewsDisabled: stabilization.viewsDisabled,
            detail: WindowCoordinator.shared.describeWindowForDiagnostics(window, role: "main")
        )

        // 彻底隐藏系统 traffic light — macOS 26 下这仨按钮无论怎样都是灰色,
        // 我们把纯 AppKit 的 CustomTrafficLightsView 挂到 titlebar 上替代它们.
        hideSystemTrafficLights(on: window)

        // 观察窗口尺寸变化时系统有时会重新显示系统按钮,监听 resize 重新隐藏。
        // 主窗口 root hosting 固定后，resize 时无需递归扫描整个 hosting tree。
        resizeObservers[id] = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window,
            queue: .main
        ) { [weak self, weak window] _ in
            guard let self, let window else { return }
            Task { @MainActor in
                self.hideSystemTrafficLights(on: window)
            }
        }
        closeObservers[id] = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [self] in
                self.cleanupWindow(id: id)
            }
        }

        // 关键: titlebar 只挂纯 AppKit view,不再引入额外的 NSHostingView,
        // 避免窗口切页时被拖进 SwiftUI 的 window size update cycle.
        installCustomTrafficLights(on: window)
        CrashDiagnostics.noteWindowChromeConfigured(
            role: "main",
            detail: "chrome configured, minSize=\(Int(Self.mainWindowMinimumSize.width))x\(Int(Self.mainWindowMinimumSize.height)) | \(WindowCoordinator.shared.describeWindowForDiagnostics(window, role: "main"))"
        )
    }

    deinit {
        for token in resizeObservers.values {
            NotificationCenter.default.removeObserver(token)
        }
        for token in closeObservers.values {
            NotificationCenter.default.removeObserver(token)
        }
    }

    private func hideSystemTrafficLights(on window: NSWindow) {
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for buttonType in buttons {
            window.standardWindowButton(buttonType)?.isHidden = true
        }
    }

    private func cleanupWindow(id: ObjectIdentifier) {
        configured.remove(id)
        if let resizeObserver = resizeObservers.removeValue(forKey: id) {
            NotificationCenter.default.removeObserver(resizeObserver)
        }
        if let closeObserver = closeObservers.removeValue(forKey: id) {
            NotificationCenter.default.removeObserver(closeObserver)
        }
    }

    private func installCustomTrafficLights(on window: NSWindow) {
        // 关键: 挂在 titlebar view 而不是 contentView.
        // macOS 的 titlebar view 盖在 contentView 顶部,所有顶部 ~28pt 的鼠标
        // 事件都被它捕获,挂在 contentView 下面的子 view 收不到 hover.
        // 通过系统按钮的 superview 拿到 titlebar(私有但标准做法).
        guard let titlebarView = window.standardWindowButton(.closeButton)?.superview else {
            return
        }

        let customTrafficLights = CustomTrafficLightsView()
        // positioned: .above 确保盖在系统按钮(已 isHidden)之上
        titlebarView.addSubview(customTrafficLights, positioned: .above, relativeTo: nil)

        // 92×28 覆盖标准 macOS titlebar 左侧三颗按钮的完整区域,精准对位.
        NSLayoutConstraint.activate([
            customTrafficLights.leadingAnchor.constraint(equalTo: titlebarView.leadingAnchor),
            customTrafficLights.topAnchor.constraint(equalTo: titlebarView.topAnchor),
            customTrafficLights.widthAnchor.constraint(equalToConstant: 92),
            customTrafficLights.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    @discardableResult
    func stabilizeSwiftUIHostingTree(on window: NSWindow) -> HostingSizingStabilizationResult {
        WindowHosting.stabilizeWindowTree(on: window)
    }
}
