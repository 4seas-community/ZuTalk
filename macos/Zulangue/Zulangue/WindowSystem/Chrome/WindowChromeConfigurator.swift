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
// 纯 AppKit 视图自画红黄绿,并挂到 window frame 而不是 titlebar。
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

        // 主窗口本身由 MainWindowController 作为 AppKit owner 创建，内容区
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
        // 我们把纯 AppKit 的 CustomTrafficLightsView 挂到 window frame 上替代它们.
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

        // 关键: 只挂纯 AppKit view,不再引入额外的 NSHostingView,
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

    @discardableResult
    func installCustomTrafficLights(on window: NSWindow) -> CustomTrafficLightsView? {
        // 挂在 content 与 titlebar 的共同父视图(window frame)最上层。
        // 若挂进 titlebar,macOS 26 hover 时会把整条系统 titlebar 材质一起揭示；
        // 若挂进 contentView,它会被 titlebar 抢走鼠标事件,也会在 root hosting
        // controller 被替换时一起移除。frame view 同时避开这两个问题。
        guard let frameView = window.contentView?.superview else {
            return nil
        }

        let customTrafficLights = CustomTrafficLightsView()
        frameView.addSubview(customTrafficLights, positioned: .above, relativeTo: nil)

        // 92×44 覆盖主侧栏左上角。热区从内容侧即可进入,
        // 不必先碰到屏幕顶边而唤出系统 titlebar。
        NSLayoutConstraint.activate([
            customTrafficLights.leadingAnchor.constraint(equalTo: frameView.leadingAnchor),
            customTrafficLights.topAnchor.constraint(equalTo: frameView.topAnchor),
            customTrafficLights.widthAnchor.constraint(equalToConstant: 92),
            customTrafficLights.heightAnchor.constraint(equalToConstant: 44),
        ])
        return customTrafficLights
    }

    @discardableResult
    func stabilizeSwiftUIHostingTree(on window: NSWindow) -> HostingSizingStabilizationResult {
        WindowHosting.stabilizeWindowTree(on: window)
    }
}
