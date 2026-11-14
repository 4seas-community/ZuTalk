// SubtitleOverlayMoreMenu.swift
// 字幕窗悬停栏上的「⋯」。
//
// 悬停栏原来摆着十五个控件。讲的人一抬手就要用的只有几样:那一句状态、两种
// 排法、字号、置顶、关窗,和标记、暂停、停止。其余的 —— 字号跟不跟窗口、深色
// 浅色、背景多透、铺满屏幕、顶部字幕带 —— 一场活动里定一次就不再碰,收进这一
// 个菜单。什么都没删:每一项都在,带着它原来的提示;铺满和字幕带的快捷键照旧
// 能用,并且写在菜单项上。
//
// 菜单是 AppKit 自己的,弹在按钮下面。菜单里有一条滑杆(背景),SwiftUI 的
// `Menu` 放不了;共用的 `MenuPill` 也没有快捷键和滑杆,所以这里单写一份。
//
// 「菜单里有什么」是一个纯函数(`SubtitleOverlayMenu.items`),从状态算出一列
// 值,测试直接查这列值。

import AppKit
import SwiftUI

/// 铺满屏幕(⌃⌘F)和顶部字幕带(⌃⌘B)的快捷键。只在这里定一次:让它们生效的
/// 那扇窗(`SubtitleOverlayPanel`),和把它们写给人看的菜单项,用的是同一份。
nonisolated struct SubtitleOverlayShortcut: Equatable, Sendable {
    let key: String

    static let fill = SubtitleOverlayShortcut(key: "f")
    static let banner = SubtitleOverlayShortcut(key: "b")

    static let modifiers: NSEvent.ModifierFlags = [.control, .command]

    /// 这一下按键是不是其中一个。大写锁定、数字键盘这类标志不算数。
    static func matching(_ event: NSEvent) -> SubtitleOverlayShortcut? {
        guard event.type == .keyDown,
              event.modifierFlags.intersection([.control, .command, .option, .shift]) == modifiers,
              let key = event.charactersIgnoringModifiers?.lowercased()
        else { return nil }
        return [fill, banner].first { $0.key == key }
    }
}

/// 菜单里的一行。
struct SubtitleOverlayMenuItem {
    enum Role: Equatable {
        case action
        case separator
        /// 一个连续的值,在菜单里用滑杆调。
        case slider(value: Double, range: ClosedRange<Double>)
    }

    var role: Role = .action
    var title = ""
    /// 原来挂在按钮上的那句提示。
    var help: String?
    /// 打勾:此刻就是这样。
    var isOn = false
    var isEnabled = true
    var shortcut: SubtitleOverlayShortcut?
    var identifier: String?
    var action: () -> Void = {}
    var setValue: (Double) -> Void = { _ in }

    static var separator: SubtitleOverlayMenuItem {
        SubtitleOverlayMenuItem(role: .separator)
    }
}

enum SubtitleOverlayMenu {
    struct State: Equatable {
        var theme: SubtitleOverlayTheme
        var placement: SubtitleOverlayPlacement
        var fontIsAutomatic: Bool
        var backdropOpacity: Double
        /// 系统开着「减少透明度」时画布不透明,滑杆不起作用。
        var backdropAdjustable: Bool
    }

    struct Actions {
        var toggleFontAutomatic: () -> Void = {}
        var setTheme: (SubtitleOverlayTheme) -> Void = { _ in }
        var setBackdropOpacity: (Double) -> Void = { _ in }
        var toggleFilled: () -> Void = {}
        var toggleBanner: () -> Void = {}
    }

    /// 三组:字号跟不跟窗口;画布长什么样;窗口摆在哪。
    static func items(state: State, actions: Actions) -> [SubtitleOverlayMenuItem] {
        [
            SubtitleOverlayMenuItem(
                title: String(localized: "subtitle.overlay.font_auto.on"),
                help: String(localized: state.fontIsAutomatic
                    ? "subtitle.overlay.font_auto.disable"
                    : "subtitle.overlay.font_auto.enable"),
                isOn: state.fontIsAutomatic,
                identifier: AccessibilityID.floatingSubtitleFontAuto,
                action: actions.toggleFontAutomatic
            ),
            .separator,
            SubtitleOverlayMenuItem(
                title: String(localized: "subtitle.overlay.theme.dark"),
                help: String(localized: "subtitle.overlay.theme.switch_to_dark"),
                isOn: state.theme == .dark,
                action: { actions.setTheme(.dark) }
            ),
            SubtitleOverlayMenuItem(
                title: String(localized: "subtitle.overlay.theme.light"),
                help: String(localized: "subtitle.overlay.theme.switch_to_light"),
                isOn: state.theme == .light,
                action: { actions.setTheme(.light) }
            ),
            SubtitleOverlayMenuItem(
                role: .slider(
                    value: state.backdropOpacity,
                    range: SubtitleOverlayBackdropPolicy.opacityRange
                ),
                title: String(localized: "subtitle.overlay.menu.backdrop"),
                help: String(localized: "subtitle.overlay.background_opacity"),
                isEnabled: state.backdropAdjustable,
                setValue: actions.setBackdropOpacity
            ),
            .separator,
            // 和原来那两颗按钮一样:已经铺满时这一项是「恢复」,已经是字幕带时
            // 那一项是「恢复」。
            SubtitleOverlayMenuItem(
                title: String(localized: state.placement == .filled
                    ? "subtitle.overlay.restore"
                    : "subtitle.overlay.maximize"),
                shortcut: .fill,
                identifier: AccessibilityID.floatingSubtitleMaximize,
                action: actions.toggleFilled
            ),
            SubtitleOverlayMenuItem(
                title: String(localized: state.placement == .banner
                    ? "subtitle.overlay.restore"
                    : "subtitle.overlay.menu.banner"),
                help: String(localized: "subtitle.overlay.banner"),
                shortcut: .banner,
                identifier: AccessibilityID.floatingSubtitleBanner,
                action: actions.toggleBanner
            ),
        ]
    }
}

/// 把那一列值变成 AppKit 菜单、弹出来,并执行选中的那一项。
@MainActor
final class SubtitleOverlayMenuPresenter: NSObject {
    fileprivate weak var anchor: NSView?
    private var items: [SubtitleOverlayMenuItem] = []

    /// 菜单本身,选中哪一项就执行哪一项。
    func menu(_ items: [SubtitleOverlayMenuItem]) -> NSMenu {
        self.items = items
        return Self.menu(
            for: items,
            target: self,
            action: #selector(run(_:)),
            sliderAction: #selector(slide(_:))
        )
    }

    func popUp(_ items: [SubtitleOverlayMenuItem]) {
        guard let anchor, anchor.window != nil else { return }
        let menu = menu(items)
        // 按钮正下方,左边对齐。
        let below = anchor.isFlipped ? anchor.bounds.maxY + 4 : -4
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: below), in: anchor)
    }

    /// 每一行的 tag 是它在 `items` 里的位置;滑杆的 tag 也是。
    static func menu(
        for items: [SubtitleOverlayMenuItem],
        target: AnyObject?,
        action: Selector?,
        sliderAction: Selector?
    ) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (index, item) in items.enumerated() {
            let entry: NSMenuItem
            switch item.role {
            case .separator:
                menu.addItem(.separator())
                continue
            case .action:
                entry = NSMenuItem(
                    title: item.title,
                    action: action,
                    keyEquivalent: item.shortcut?.key ?? ""
                )
                if item.shortcut != nil {
                    entry.keyEquivalentModifierMask = SubtitleOverlayShortcut.modifiers
                }
                entry.target = target
                entry.state = item.isOn ? .on : .off
            case .slider(let value, let range):
                entry = NSMenuItem()
                entry.title = item.title
                entry.view = SubtitleOverlayMenuSliderRow(
                    title: item.title,
                    help: item.help,
                    value: value,
                    range: range,
                    isEnabled: item.isEnabled,
                    tag: index,
                    target: target,
                    action: sliderAction
                )
            }
            entry.tag = index
            entry.isEnabled = item.isEnabled
            entry.toolTip = item.help
            if let identifier = item.identifier {
                entry.identifier = NSUserInterfaceItemIdentifier(identifier)
                entry.setAccessibilityIdentifier(identifier)
            }
            menu.addItem(entry)
        }
        return menu
    }

    @objc private func run(_ sender: NSMenuItem) {
        guard items.indices.contains(sender.tag) else { return }
        items[sender.tag].action()
    }

    @objc private func slide(_ sender: NSSlider) {
        guard items.indices.contains(sender.tag) else { return }
        items[sender.tag].setValue(sender.doubleValue)
    }
}

/// 菜单里的那条滑杆:名字在左,滑杆在右,拖的时候画布跟着变。
final class SubtitleOverlayMenuSliderRow: NSView {
    let slider: NSSlider

    /// 和普通菜单项的文字左边对齐:菜单给打勾留的那一栏。
    private static let leadingInset: CGFloat = 21
    private static let trailingInset: CGFloat = 14
    private static let rowSize = NSSize(width: 236, height: 26)

    init(
        title: String,
        help: String?,
        value: Double,
        range: ClosedRange<Double>,
        isEnabled: Bool,
        tag: Int,
        target: AnyObject?,
        action: Selector?
    ) {
        slider = NSSlider(
            value: value,
            minValue: range.lowerBound,
            maxValue: range.upperBound,
            target: target,
            action: action
        )
        super.init(frame: NSRect(origin: .zero, size: Self.rowSize))
        autoresizingMask = [.width]

        let label = NSTextField(labelWithString: title)
        label.font = .menuFont(ofSize: 0)
        label.textColor = isEnabled ? .labelColor : .disabledControlTextColor
        label.setContentHuggingPriority(.required, for: .horizontal)

        slider.isContinuous = true
        slider.controlSize = .small
        slider.tag = tag
        slider.isEnabled = isEnabled
        slider.toolTip = help
        slider.setAccessibilityLabel(help ?? title)

        let row = NSStackView(views: [label, slider])
        row.orientation = .horizontal
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(
            top: 0,
            left: Self.leadingInset,
            bottom: 0,
            right: Self.trailingInset
        )
        row.frame = bounds
        row.autoresizingMask = [.width, .height]
        addSubview(row)
        toolTip = help
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// 菜单挂在哪:「⋯」按钮自己的位置。
struct SubtitleOverlayMenuAnchor: NSViewRepresentable {
    let presenter: SubtitleOverlayMenuPresenter

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        presenter.anchor = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        presenter.anchor = view
    }
}
