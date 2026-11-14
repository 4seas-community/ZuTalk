// Pills.swift
// 胶囊:小控件的统一样子。
//
// 「界面怎么写」(docs/product/interface-layers.md)定了三件事:一个控件一个词,
// 当前的值直接写在控件上;表面不写句子,想多说的一句放进提示;一种控件一个
// 样子。这个文件就是那个样子 —— 一颗写着当前值的胶囊:
//
//   - `TogglePill`   点一下就切换。开和关可以是两个词、两个图标。
//   - `MenuPill`     写着当前的值,带一个小 ⌄,点开是菜单,当前那一项打着勾。
//   - `ActionPill`   只做一件事。安静的那种没有底色,给排在最后的次要动作。
//   - `ValuePill`    一个可以拿掉的值(一种语言):前面可以带一个改角色的小
//                    按钮,后面可以带一个 ×。
//   - `InfoButton`   ⓘ。少数必须让人读得到的告知(东西会离开这台 Mac、交上去
//                    删不掉)放在这里面,不铺在页面上。
//   - `PillStrip`    一排胶囊。窗口窄到摆不下时,胶囊上的名字(主题、设备、
//                    活动)先让出宽度;还摆不下就横向滚动,不折行、不挤扁,
//                    还有东西的那一头渐隐,看得出能往那边滚。
//
// 每一颗都把「原来写在控件下面的那句话」当参数收下:`help` 进悬停提示,也进
// 无障碍提示。句子没有删,只是换了地方。
//
// 尺寸、字号、颜色只在 `PillMetrics` 和 `PillPalette` 里各定一次。

import AppKit
import SwiftUI

// MARK: - 尺寸与颜色

/// One set of measurements for every pill, so pills from different controls
/// sitting in one strip read as one thing.
enum PillMetrics {
    static let height: CGFloat = 32
    static let horizontalPadding: CGFloat = Spacing.xsm
    /// Between neighbouring pills.
    static let spacing: CGFloat = Spacing.sm
    /// Between a pill's icon and its word.
    static let iconSpacing: CGFloat = 6
    static let font = Font.body
    static let iconFont = Font.system(size: 12, weight: .medium)
    static let chevronFont = Font.system(size: 8, weight: .bold)
    static let markFont = Font.system(size: 10, weight: .medium)
    /// A small button inside a pill: the role icon and the × of a value.
    static let segmentWidth: CGFloat = 28
    /// A name that is not ours to shorten — a topic, a device, an event — is
    /// cut off past this.
    static let maxTitleWidth: CGFloat = 168
    /// In a row short of room a name gives way before the row scrolls, but
    /// not below this: enough of it left to tell which one it is.
    static let minNameWidth: CGFloat = 56
}

/// How a pill is painted.
nonisolated enum PillTone: Equatable, Sendable {
    /// A control showing a value.
    case normal
    /// A toggle that is on.
    case on
    /// Something that cannot work yet.
    case dimmed
    /// Something that needs attention before it will do what it says.
    case warning
}

/// The colours of each tone, in one place: the same fill and border family
/// as the chips elsewhere, strong enough to read as something to click.
struct PillPalette {
    let tone: PillTone
    var isHovering = false

    var title: Color {
        switch tone {
        case .normal, .warning: return .textPrimary
        case .on: return .brandAccent
        case .dimmed: return .textTertiary
        }
    }

    var icon: Color {
        switch tone {
        case .normal: return .textSecondary
        case .on: return .brandAccent
        case .dimmed: return .textTertiary
        case .warning: return .signalAmber
        }
    }

    var fill: Color {
        switch tone {
        case .on:
            return Color.brandAccent.opacity(isHovering ? 0.2 : 0.14)
        case .warning:
            return Color.signalAmber.opacity(isHovering ? 0.18 : 0.12)
        case .normal, .dimmed:
            return Color.bgElevated.opacity(isHovering ? 1 : 0.75)
        }
    }

    var border: Color {
        switch tone {
        case .on:
            return Color.brandAccent.opacity(0.5)
        case .warning:
            return Color.signalAmber.opacity(0.55)
        case .normal, .dimmed:
            return isHovering ? Color.borderActive : Color.borderGhost
        }
    }
}

/// The capsule itself: height, fill, border, and a hit area the whole shape.
struct PillChrome: ViewModifier {
    var tone: PillTone = .normal
    var isHovering = false

    func body(content: Content) -> some View {
        let palette = PillPalette(tone: tone, isHovering: isHovering)
        content
            .frame(height: PillMetrics.height)
            .background(palette.fill)
            .overlay(Capsule().strokeBorder(palette.border, lineWidth: Stroke.thin))
            .clipShape(Capsule())
            .contentShape(Capsule())
    }
}

/// A small sign after a pill's word.
nonisolated enum PillMark: Equatable, Sendable {
    case none
    /// Opens a menu.
    case chevron
    /// Needs something before it can work.
    case warning
}

extension View {
    /// Gives a pill the sentence that would otherwise be printed beside it:
    /// as its tooltip, and as what VoiceOver says after its name. `label`
    /// and `value` name the control and its current setting when the word on
    /// the pill alone would not.
    func pillExplained(help: String?, label: String? = nil, value: String? = nil) -> some View {
        modifier(PillExplanation(help: help, label: label, value: value))
    }
}

private struct PillExplanation: ViewModifier {
    let help: String?
    let label: String?
    let value: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        // An empty tooltip or hint is none at all; an empty label would
        // silence the control, so that one is applied only when given.
        let explained = content
            .help(help ?? "")
            .accessibilityHint(Text(help ?? ""))
            .accessibilityValue(Text(value ?? ""))
        if let label {
            explained.accessibilityLabel(Text(label))
        } else {
            explained
        }
    }
}

// MARK: - 只做一件事

/// A pill that does one thing when clicked. Its word is what it does, or the
/// value it currently has. The quiet style has no capsule: for a lesser
/// action at the end of a strip.
struct ActionPill: View {
    enum Style: Equatable {
        case standard
        case quiet
    }

    private let title: String?
    private let titleIsName: Bool
    private let systemImage: String
    private let style: Style
    private let tone: PillTone
    private let iconTint: Color?
    private let mark: PillMark
    private let help: String?
    private let accessibilityLabel: String?
    private let accessibilityValue: String?
    private let action: () -> Void

    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    /// - Parameters:
    ///   - title: The one word. Nil for a pill that is only an icon (＋); give
    ///     it an `accessibilityLabel`.
    ///   - titleIsName: The title is somebody's name for something — a topic,
    ///     a device, an event — rather than a word of ours. Our words are
    ///     never cut; a name gives way when its row is short of room.
    ///   - iconTint: Overrides the tone's icon colour — an amber sign on an
    ///     otherwise ordinary pill.
    ///   - help: The sentence that explains it, for the tooltip and VoiceOver.
    init(
        _ title: String?,
        titleIsName: Bool = false,
        systemImage: String,
        style: Style = .standard,
        tone: PillTone = .normal,
        iconTint: Color? = nil,
        mark: PillMark = .none,
        help: String? = nil,
        accessibilityLabel: String? = nil,
        accessibilityValue: String? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.titleIsName = titleIsName
        self.systemImage = systemImage
        self.style = style
        self.tone = tone
        self.iconTint = iconTint
        self.mark = mark
        self.help = help
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityValue = accessibilityValue
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            face
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.5)
        .onHover { isHovering = $0 }
        .animation(Motion.microInteraction, value: isHovering)
        .pillExplained(help: help, label: accessibilityLabel, value: accessibilityValue)
    }

    @ViewBuilder
    private var face: some View {
        let palette = PillPalette(tone: tone, isHovering: isHovering && isEnabled)
        let content = HStack(spacing: PillMetrics.iconSpacing) {
            Image(systemName: systemImage)
                .font(PillMetrics.iconFont)
                .foregroundColor(iconTint ?? (style == .quiet ? Color.textSecondary : palette.icon))
                .accessibilityHidden(true)
            if let title {
                PillTitle(
                    title,
                    isName: titleIsName,
                    color: style == .quiet ? Color.textSecondary : palette.title
                )
            }
            switch mark {
            case .none:
                EmptyView()
            case .chevron:
                Image(systemName: "chevron.down")
                    .font(PillMetrics.chevronFont)
                    .foregroundColor(.textTertiary)
                    .accessibilityHidden(true)
            case .warning:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(PillMetrics.markFont)
                    .foregroundColor(.signalAmber)
                    .accessibilityHidden(true)
            }
        }
        switch style {
        case .standard:
            content
                // An icon alone sits in a circle the height of the pill. A
                // pill with a word gets no minimum of its own: a minimum
                // would let a row short of a few points take them out of
                // the pill's padding.
                .padding(.horizontal, title == nil ? 0 : PillMetrics.horizontalPadding)
                .frame(minWidth: title == nil ? PillMetrics.height : nil)
                .modifier(PillChrome(tone: tone, isHovering: isHovering && isEnabled))
        case .quiet:
            // No capsule, so no padding either: at the end of a strip its
            // word lines up with the edge of whatever the strip sits in.
            content
                .frame(height: PillMetrics.height)
                .opacity(isHovering && isEnabled ? 1 : 0.85)
                .contentShape(Rectangle())
        }
    }
}

/// The word on a pill, on one line. A word of ours is always whole. A name
/// is as wide as it is up to `maxTitleWidth`, and in a row short of room it
/// narrows — down to `minNameWidth`, or its own width if that is less — so
/// the pills after it stay on screen.
///
/// A name therefore has no width of its own to insist on: asked how wide it
/// would like to be, it answers with its narrowest, and takes more when it
/// is offered more. That is what lets a `PillStrip` find out whether its
/// pills fit before deciding to scroll. Outside a strip, give a name pill a
/// row with room in it rather than `fixedSize()`.
private struct PillTitle: View {
    private let title: String
    private let isName: Bool
    private let color: Color

    init(_ title: String, isName: Bool, color: Color) {
        self.title = title
        self.isName = isName
        self.color = color
    }

    var body: some View {
        if isName {
            // Two invisible copies decide the width — one that never gives
            // way, capped at the floor, and one capped at the most a name
            // may take, which gives way entirely and asks for nothing —
            // and the name is drawn in whatever width they come to.
            ZStack(alignment: .leading) {
                text
                    .frame(maxWidth: PillMetrics.minNameWidth)
                    .fixedSize(horizontal: true, vertical: false)
                text
                    .frame(maxWidth: PillMetrics.maxTitleWidth)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minWidth: 0, idealWidth: 0, alignment: .leading)
            }
            .hidden()
            .accessibilityHidden(true)
            .overlay(text.frame(maxWidth: .infinity, alignment: .leading))
        } else {
            text.fixedSize(horizontal: true, vertical: false)
        }
    }

    private var text: some View {
        Text(title)
            .font(PillMetrics.font)
            .foregroundColor(color)
            .lineLimit(1)
            .truncationMode(.tail)
    }
}

// MARK: - 开关

/// A pill that flips between two states when clicked. On is tinted; the word
/// and the icon may differ between the two, so each state says what it is
/// ("Live text" / "Audio only") rather than "on" and "off".
struct TogglePill: View {
    struct Face: Equatable {
        var title: String
        var systemImage: String

        init(_ title: String, systemImage: String) {
            self.title = title
            self.systemImage = systemImage
        }
    }

    private let isOn: Bool
    private let on: Face
    private let off: Face
    private let iconTint: Color?
    private let help: String?
    private let accessibilityLabel: String?
    private let action: () -> Void

    /// - Parameters:
    ///   - off: How it looks when off; the same word and icon as `on` when
    ///     left out.
    ///   - accessibilityLabel: The name of the setting, when the word on the
    ///     pill is its value rather than its name. The word is then read as
    ///     the value.
    ///   - action: Flips it.
    init(
        isOn: Bool,
        on: Face,
        off: Face? = nil,
        iconTint: Color? = nil,
        help: String? = nil,
        accessibilityLabel: String? = nil,
        action: @escaping () -> Void
    ) {
        self.isOn = isOn
        self.on = on
        self.off = off ?? on
        self.iconTint = iconTint
        self.help = help
        self.accessibilityLabel = accessibilityLabel
        self.action = action
    }

    var body: some View {
        let face = isOn ? on : off
        ActionPill(
            face.title,
            systemImage: face.systemImage,
            tone: isOn ? .on : .normal,
            iconTint: iconTint,
            help: help,
            accessibilityLabel: accessibilityLabel,
            accessibilityValue: accessibilityLabel == nil ? nil : face.title,
            action: action
        )
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

// MARK: - 菜单

/// One line of a pill's menu.
struct PillMenuItem {
    var title: String
    /// Ticked: the current choice.
    var isOn: Bool
    var isEnabled: Bool
    var action: () -> Void
    fileprivate var isSeparator = false

    init(
        _ title: String,
        isOn: Bool = false,
        isEnabled: Bool = true,
        action: @escaping () -> Void = {}
    ) {
        self.title = title
        self.isOn = isOn
        self.isEnabled = isEnabled
        self.action = action
    }

    /// A line between groups.
    static var separator: PillMenuItem {
        var item = PillMenuItem("")
        item.isSeparator = true
        return item
    }
}

/// A pill that shows the current value and opens a menu of the others, the
/// current one ticked.
///
/// The menu is AppKit's own, popped up under the pill. SwiftUI's `Menu`
/// draws its label as a bare title on the Mac — no capsule, and only the
/// words themselves take the click — which is exactly the kind of control
/// that goes unnoticed.
struct MenuPill: View {
    private let title: String
    private let titleIsName: Bool
    private let systemImage: String
    private let tone: PillTone
    private let help: String?
    private let accessibilityLabel: String?
    private let accessibilityValue: String?
    private let items: () -> [PillMenuItem]

    @State private var presenter = PillMenuPresenter()

    /// - Parameters:
    ///   - title: The current value, or the one word that names the pill
    ///     when nothing is chosen.
    ///   - titleIsName: The value is a name — a topic, a device, an event —
    ///     which gives way when the row is short of room; see `ActionPill`.
    ///   - accessibilityLabel: The name of the setting; the title is then
    ///     read as its value.
    ///   - accessibilityValue: The value to read instead of the title — when
    ///     the pill shows its own name because nothing is chosen.
    ///   - items: Built when the pill is clicked, so the menu is never stale.
    init(
        _ title: String,
        titleIsName: Bool = false,
        systemImage: String,
        tone: PillTone = .normal,
        help: String? = nil,
        accessibilityLabel: String? = nil,
        accessibilityValue: String? = nil,
        items: @escaping () -> [PillMenuItem]
    ) {
        self.title = title
        self.titleIsName = titleIsName
        self.systemImage = systemImage
        self.tone = tone
        self.help = help
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityValue = accessibilityValue
        self.items = items
    }

    var body: some View {
        ActionPill(
            title,
            titleIsName: titleIsName,
            systemImage: systemImage,
            tone: tone,
            mark: .chevron,
            help: help,
            accessibilityLabel: accessibilityLabel,
            accessibilityValue: accessibilityValue ?? (accessibilityLabel == nil ? nil : title)
        ) {
            presenter.popUp(items())
        }
        .background(PillMenuAnchor(presenter: presenter))
    }
}

/// Builds and shows a pill's menu, and runs what was picked.
@MainActor
final class PillMenuPresenter: NSObject {
    fileprivate weak var anchor: NSView?
    private var actions: [() -> Void] = []

    func popUp(_ items: [PillMenuItem]) {
        guard let anchor, anchor.window != nil else { return }
        let menu = Self.menu(for: items, target: self, action: #selector(run(_:)))
        actions = items.filter { $0.isSeparator == false }.map(\.action)
        // Just under the pill, left edges together.
        let below = anchor.isFlipped ? anchor.bounds.maxY + 4 : -4
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: below), in: anchor)
    }

    /// The AppKit menu for a list of items; each action item's tag is its
    /// place among the action items.
    static func menu(for items: [PillMenuItem], target: AnyObject?, action: Selector?) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        var index = 0
        for item in items {
            if item.isSeparator {
                menu.addItem(.separator())
                continue
            }
            let entry = NSMenuItem(title: item.title, action: action, keyEquivalent: "")
            entry.target = target
            entry.tag = index
            entry.state = item.isOn ? .on : .off
            entry.isEnabled = item.isEnabled
            menu.addItem(entry)
            index += 1
        }
        return menu
    }

    @objc private func run(_ sender: NSMenuItem) {
        guard actions.indices.contains(sender.tag) else { return }
        actions[sender.tag]()
    }
}

/// The spot on screen the menu hangs from: the pill's own frame.
private struct PillMenuAnchor: NSViewRepresentable {
    let presenter: PillMenuPresenter

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        presenter.anchor = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        presenter.anchor = view
    }
}

// MARK: - 一个可以拿掉的值

/// A value that is one of several and can be taken away — a language among
/// the languages. It may carry a small button in front that changes what
/// kind of value it is, and a × behind that removes it.
struct ValuePill: View {
    /// The small button in front.
    struct Leading {
        var systemImage: String
        var tint: Color
        /// Says what the value is now and what a click changes it to.
        var help: String
        var isEnabled = true
        var action: () -> Void
    }

    private let title: String
    private let isMuted: Bool
    private let leading: Leading?
    private let removeLabel: String?
    private let onRemove: (() -> Void)?

    /// - Parameters:
    ///   - isMuted: Drawn a step quieter: a value that plays a lesser part.
    ///   - removeLabel: What the × does, for the tooltip and VoiceOver.
    ///   - onRemove: Nil when the value may not be removed; no × is drawn.
    init(
        _ title: String,
        isMuted: Bool = false,
        leading: Leading? = nil,
        removeLabel: String? = nil,
        onRemove: (() -> Void)? = nil
    ) {
        self.title = title
        self.isMuted = isMuted
        self.leading = leading
        self.removeLabel = removeLabel
        self.onRemove = onRemove
    }

    var body: some View {
        HStack(spacing: 0) {
            if let leading {
                Button(action: leading.action) {
                    Image(systemName: leading.systemImage)
                        .font(PillMetrics.iconFont)
                        .foregroundColor(leading.tint)
                        .frame(width: PillMetrics.segmentWidth + 2, height: PillMetrics.height)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(leading.isEnabled == false)
                .help(leading.help)
                .accessibilityLabel(Text(leading.help))
            }

            Text(title)
                .font(PillMetrics.font)
                .foregroundColor(isMuted ? .textSecondary : .textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: PillMetrics.maxTitleWidth)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.leading, leading == nil ? PillMetrics.horizontalPadding : 0)
                .padding(.trailing, onRemove == nil ? PillMetrics.horizontalPadding : 0)

            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(PillMetrics.chevronFont)
                        .foregroundColor(.textTertiary)
                        .frame(width: PillMetrics.segmentWidth, height: PillMetrics.height)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(removeLabel ?? "")
                .accessibilityLabel(Text(removeLabel ?? title))
            }
        }
        .modifier(PillChrome())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(title))
    }
}

// MARK: - ⓘ

/// A quiet ⓘ beside a control, for the few things a person must be able to
/// read before acting — that something leaves this Mac, that something
/// filed cannot be taken back. A click opens the sentence or two in a
/// popover; they are also the tooltip, and what VoiceOver reads.
struct InfoButton: View {
    private let text: String
    private let accessibilityLabel: String?

    @State private var showsText = false

    /// - Parameters:
    ///   - text: One or two sentences; separate lines with a newline.
    ///   - accessibilityLabel: What the information is about.
    init(_ text: String, accessibilityLabel: String? = nil) {
        self.text = text
        self.accessibilityLabel = accessibilityLabel
    }

    var body: some View {
        Button {
            showsText.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(showsText ? .textPrimary : .textTertiary)
                .frame(width: 22, height: PillMetrics.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pillExplained(help: text, label: accessibilityLabel)
        .popover(isPresented: $showsText, arrowEdge: .bottom) {
            Text(text)
                .font(.body)
                .foregroundColor(.textPrimary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 300, alignment: .leading)
                .padding(Spacing.md)
        }
    }
}

// MARK: - 一排

/// A row of pills. When the window is too narrow for them, names on pills
/// narrow first (see `PillTitle`); if they still do not fit, the row scrolls
/// sideways rather than wrapping or squeezing them, and fades at whichever
/// edge has more to show — a word cut off at a hard edge reads as broken, a
/// fade reads as "more this way". What is given as `trailing` sits at the
/// far end while there is room for it to.
struct PillStrip<Leading: View, Trailing: View>: View {
    private let leading: Leading
    private let trailing: Trailing

    /// Where the pills are and how wide they are, inside the strip.
    @State private var extent = PillStripExtent()
    @Namespace private var space

    init(@ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        let measured = $extent
        return GeometryReader { strip in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    HStack(spacing: PillMetrics.spacing) { leading }
                    // Last in line for room: names narrow only when the
                    // pills really do not fit, not to make a gap here.
                    Spacer(minLength: PillMetrics.spacing)
                        .layoutPriority(-1)
                    trailing
                }
                // As wide as the strip, or as wide as the pills at their
                // narrowest when that is more: names give way first, and
                // the row scrolls only when it still does not fit.
                .frame(minWidth: strip.size.width, alignment: .leading)
                .background(
                    GeometryReader { pills in
                        let current = PillStripExtent(
                            width: pills.size.width,
                            offset: -pills.frame(in: .named(space)).minX
                        )
                        Color.clear
                            .onAppear { measured.wrappedValue = current }
                            .montereyOnChange(of: current) { _, current in
                                measured.wrappedValue = current
                            }
                    }
                )
            }
            .coordinateSpace(name: space)
            .mask(fade(extent.fades(viewport: strip.size.width)))
        }
        .frame(height: PillMetrics.height)
    }

    private func fade(_ widths: (leading: CGFloat, trailing: CGFloat)) -> some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: widths.leading)
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: widths.trailing)
        }
    }
}

extension PillStrip where Trailing == EmptyView {
    init(@ViewBuilder _ pills: () -> Leading) {
        self.init(leading: pills, trailing: { EmptyView() })
    }
}

/// How wide a strip's pills are and how far they have been scrolled.
nonisolated struct PillStripExtent: Equatable, Sendable {
    static let fadeWidth: CGFloat = 28

    var width: CGFloat = 0
    /// How far the pills have moved left.
    var offset: CGFloat = 0

    /// How far past each edge the pills go, for a strip this wide. Nothing
    /// when they fit, however the numbers round.
    func hidden(viewport: CGFloat) -> (leading: CGFloat, trailing: CGFloat) {
        let overflow = width - viewport
        guard overflow > 0.5 else { return (0, 0) }
        let leading = min(max(offset, 0), overflow)
        return (leading, overflow - leading)
    }

    /// How wide the fade is at each edge: none where nothing is hidden, and
    /// it grows with what is hidden, so the last few points of a scroll do
    /// not blink a full fade on and off.
    func fades(viewport: CGFloat) -> (leading: CGFloat, trailing: CGFloat) {
        let hidden = hidden(viewport: viewport)
        func fade(_ amount: CGFloat) -> CGFloat {
            amount > 0.5 ? min(Self.fadeWidth, amount * 2) : 0
        }
        return (fade(hidden.leading), fade(hidden.trailing))
    }
}
