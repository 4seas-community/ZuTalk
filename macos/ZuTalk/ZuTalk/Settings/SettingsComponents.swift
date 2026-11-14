// SettingsComponents.swift
// 设置页面的基本组件。每一节设置(账号、通用、高级,还有城的那几块)都用它们,
// 所以设置长什么样只在这里定一次。
//
//   SettingsGroup(title, subtitle?, info?) { cards }   一件事:一个词的小标题
//   SettingsCard(title?, subtitle?, info?) { rows }    一个圆角框,里面是几行
//   SettingsRow(title, description?, info?) { control } 一行:名字 + 控件
//   SettingsFullRow { content }                         一行:内容自己排
//
// 0.8.3 起,表面不写句子(docs/product/interface-layers.md「界面怎么写」)。调用
// 的写法没有变,变的是参数去了哪里:一行的 `description:`、卡片和分组的
// `subtitle:` 不再印在页面上,成了悬停提示和无障碍提示 —— 句子没有删,换了
// 地方。必须让人读得到的告知(未加密保存、东西会离开这台 Mac)交给 `info:`,
// 它在名字旁边画一个 ⓘ,点开才是那几句。
//
// 小控件都是胶囊(`DesignSystem/Primitives/Pills.swift`)。这里补上设置里才有
// 的四样,尺寸都跟胶囊走:
//   SettingsSwitch   开 / 关,一颗点一下就切换的胶囊
//   SettingsField    一栏输入,和胶囊一样高
//   SettingsStatus   状态:一个图标加一个词
//   SettingsValue    只读的值(版本号、配对码),可以选中

import SwiftUI

// MARK: - 说明换了地方

extension View {
    /// Gives a view the sentence that used to be printed under it: as its
    /// tooltip, and as what VoiceOver reads after its name.
    func settingsExplained(_ sentence: String?) -> some View {
        // An empty tooltip or hint is none at all.
        help(sentence ?? "")
            .accessibilityHint(Text(sentence ?? ""))
    }
}

// MARK: - SettingsGroup
//
// 一节里的一件事:一个词的小标题,下面是它的卡片。分组靠留白,不靠边框。

struct SettingsGroup<Content: View>: View {
    let title: String
    let subtitle: String?
    let info: String?
    let accessory: AnyView?
    @ViewBuilder let content: () -> Content

    /// - Parameters:
    ///   - subtitle: Not printed: the header's tooltip and accessibility hint.
    ///   - info: What a person must be able to read about this group; shown
    ///     behind an ⓘ beside the title.
    ///   - accessory: One quiet control at the far end of the header.
    init(
        title: String,
        subtitle: String? = nil,
        info: String? = nil,
        accessory: AnyView? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.info = info
        self.accessory = accessory
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.xs) {
                Text(title)
                    .font(Font.sans14Medium)
                    .foregroundColor(Color.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                    .settingsExplained(subtitle)
                if let info, info.isEmpty == false {
                    InfoButton(info, accessibilityLabel: title)
                }
                Spacer(minLength: Spacing.sm)
                if let accessory {
                    accessory
                }
            }
            // The same height with or without an ⓘ or an accessory, so the
            // cards below every header start at the same distance from it.
            .frame(minHeight: PillMetrics.height)
            .padding(.horizontal, Spacing.xs)

            VStack(alignment: .leading, spacing: Spacing.md) {
                content()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - SettingsCard

/// 一个圆角框,里面是几行,行与行之间一条细线。可以有一个词的小标题。
struct SettingsCard<Content: View>: View {
    let title: String?
    let subtitle: String?
    let info: String?
    @ViewBuilder let content: () -> Content

    /// - Parameters:
    ///   - subtitle: Not printed: the title's tooltip and accessibility hint.
    ///   - info: Shown behind an ⓘ beside the title.
    init(
        title: String? = nil,
        subtitle: String? = nil,
        info: String? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.info = info
        self.content = content
    }

    private var shownInfo: String? {
        guard let info, info.isEmpty == false else { return nil }
        return info
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            if title != nil || shownInfo != nil {
                HStack(spacing: Spacing.xs) {
                    if let title {
                        Text(title)
                            .font(Font.sans12)
                            .foregroundColor(Color.textSecondary)
                            .accessibilityAddTraits(.isHeader)
                            .settingsExplained(subtitle)
                    }
                    if let shownInfo {
                        InfoButton(shownInfo, accessibilityLabel: title)
                    }
                }
                .padding(.horizontal, Spacing.xs)
            }

            VStack(spacing: 0) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .surfaceCard(
                fill: Color.bgElevated.opacity(0.4),
                cornerRadius: Radius.md,
                border: Color.borderSubtle,
                borderWidth: Stroke.hairline
            )
        }
    }
}

// MARK: - SettingsRow

/// 一行设置:左边名字,右边控件。名字是一个词;原来写在名字下面的那句话
/// (`description`)现在是这一行的悬停提示和无障碍提示。
struct SettingsRow<Control: View>: View {
    let title: String
    let description: String?
    let info: String?
    @ViewBuilder let control: () -> Control

    /// - Parameters:
    ///   - description: Not printed: the row's tooltip and accessibility hint.
    ///   - info: Shown behind an ⓘ beside the name.
    init(
        _ title: String,
        description: String? = nil,
        info: String? = nil,
        @ViewBuilder control: @escaping () -> Control
    ) {
        self.title = title
        self.description = description
        self.info = info
        self.control = control
    }

    var body: some View {
        HStack(alignment: .center, spacing: PillMetrics.spacing) {
            Text(title)
                .font(PillMetrics.font)
                .foregroundColor(Color.textPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                // Enough of the name left to tell which row it is, however
                // much the controls ask for.
                .frame(minWidth: PillMetrics.minNameWidth, alignment: .leading)
                .accessibilityHint(Text(description ?? ""))
            if let info, info.isEmpty == false {
                InfoButton(info, accessibilityLabel: title)
            }
            Spacer(minLength: Spacing.sm)
            // Controls keep their shape; in a row short of room it is the
            // name that wraps onto a second line.
            HStack(spacing: PillMetrics.spacing) {
                control()
            }
            .layoutPriority(1)
        }
        .frame(minHeight: PillMetrics.height)
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .help(description ?? "")
    }
}

/// 行内分隔线 — 放在行与行之间。
struct SettingsRowDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.borderSubtle.opacity(0.5))
            .frame(height: Stroke.hairline)
            .padding(.horizontal, Spacing.md)
    }
}

// MARK: - SettingsFullRow

/// 内容自己排的一行(一栏输入加一个动作、一排胶囊、一句出错的话)。和
/// `SettingsRow` 一样高、一样的边距,内容靠左。
struct SettingsFullRow<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            content()
        }
        .frame(maxWidth: .infinity, minHeight: PillMetrics.height, alignment: .leading)
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
    }
}

// MARK: - 一页的标题

/// 一页设置最上面的名字。`subtitle` 只给说这一页自己状态的那一句
/// (「大多数人用不到这一页」);介绍这一页有什么的句子不写。
struct SettingsPageHeader: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(title)
                .font(.titleMD)
                .foregroundColor(Color.textPrimary)
                .accessibilityAddTraits(.isHeader)
            if let subtitle, subtitle.isEmpty == false {
                Text(subtitle)
                    .font(Font.sans12)
                    .foregroundColor(Color.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 开关

/// 开 / 关。一颗胶囊,上面写着现在是哪一个,点一下换成另一个;开着的时候
/// 带底色。设置的名字在行的左边,所以读屏读的是「名字,开」。
struct SettingsSwitch: View {
    private let isOn: Bool
    private let label: String
    private let help: String?
    private let action: (Bool) -> Void

    /// - Parameters:
    ///   - label: The name of the setting, for VoiceOver.
    ///   - help: The sentence that explains it, for the tooltip.
    ///   - action: Called with the new state.
    init(isOn: Bool, label: String, help: String? = nil, action: @escaping (Bool) -> Void) {
        self.isOn = isOn
        self.label = label
        self.help = help
        self.action = action
    }

    var body: some View {
        TogglePill(
            isOn: isOn,
            on: .init(String(localized: "settings.switch.on"), systemImage: "checkmark.circle.fill"),
            off: .init(String(localized: "settings.switch.off"), systemImage: "circle"),
            help: help,
            accessibilityLabel: label
        ) {
            action(!isOn)
        }
    }
}

// MARK: - 输入栏

/// 一栏输入,和胶囊一样高,方角 —— 圆的是点的,方的是填的。`isSecure` 的那种
/// 不显示填进去的字。
struct SettingsField: View {
    private let placeholder: String
    @Binding private var text: String
    private let isSecure: Bool
    private let focus: FocusState<Bool>.Binding?
    private let onSubmit: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    init(
        _ placeholder: String,
        text: Binding<String>,
        isSecure: Bool = false,
        focus: FocusState<Bool>.Binding? = nil,
        onSubmit: @escaping () -> Void = {}
    ) {
        self.placeholder = placeholder
        _text = text
        self.isSecure = isSecure
        self.focus = focus
        self.onSubmit = onSubmit
    }

    var body: some View {
        field
            .textFieldStyle(.plain)
            .font(PillMetrics.font)
            .foregroundColor(.textPrimary)
            .onSubmit(onSubmit)
            .padding(.horizontal, PillMetrics.horizontalPadding)
            .frame(height: PillMetrics.height)
            .background(Color.bgRoot)
            .overlay(
                RoundedRectangle(cornerRadius: Radius.sm)
                    .strokeBorder(Color.borderActive, lineWidth: Stroke.thin)
            )
            .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
            .opacity(isEnabled ? 1 : 0.5)
    }

    @ViewBuilder
    private var field: some View {
        if let focus {
            input.focused(focus)
        } else {
            input
        }
    }

    @ViewBuilder
    private var input: some View {
        if isSecure {
            SecureField(placeholder, text: $text)
        } else {
            TextField(placeholder, text: $text)
        }
    }
}

// MARK: - 状态与值

/// 状态:一个图标加一个词。细节(`help`)在悬停提示和无障碍提示里。
struct SettingsStatus: View {
    private let text: String
    private let systemImage: String
    private let tint: Color
    private let help: String?
    private let font: Font

    init(
        _ text: String,
        systemImage: String,
        tint: Color = .textSecondary,
        help: String? = nil,
        font: Font = PillMetrics.font
    ) {
        self.text = text
        self.systemImage = systemImage
        self.tint = tint
        self.help = help
        self.font = font
    }

    var body: some View {
        HStack(spacing: PillMetrics.iconSpacing) {
            Image(systemName: systemImage)
                .font(PillMetrics.iconFont)
                .foregroundColor(tint)
                .accessibilityHidden(true)
            Text(text)
                .font(font)
                .foregroundColor(.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .settingsExplained(help)
    }
}

/// 只读的值:版本号、引擎的名字、一串配对码。等宽,可以选中拷走。
struct SettingsValue: View {
    private let text: String
    private let lineLimit: Int
    private let alignment: TextAlignment

    init(_ text: String, lineLimit: Int = 2, alignment: TextAlignment = .trailing) {
        self.text = text
        self.lineLimit = lineLimit
        self.alignment = alignment
    }

    var body: some View {
        Text(text)
            .font(Font.mono12)
            .foregroundColor(.textSecondary)
            .multilineTextAlignment(alignment)
            .lineLimit(lineLimit)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

/// 一句出了错的话,带一个警示图标。出错是页面上可以写整句的四种情况之一。
struct SettingsProblem: View {
    private let message: String
    private let tint: Color
    private let font: Font

    init(_ message: String, tint: Color = .signalAmber, font: Font = Font.sans12) {
        self.message = message
        self.tint = tint
        self.font = font
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: PillMetrics.iconSpacing) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(PillMetrics.iconFont)
                .foregroundColor(tint)
                .accessibilityHidden(true)
            Text(message)
                .font(font)
                .foregroundColor(.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 一串码

/// 生成出来的一串码(配对码、备份码、恢复码):码本身是一个可以选中的值,
/// 下面一行是它还剩多久,和对它能做的事。`info` 是「拿它去哪里粘贴」那一句。
struct SettingsCodeRow: View {
    let code: String
    let expiresAt: Date
    var info: String?
    var codeIdentifier: String
    let onCopy: () -> Void
    var onCancel: (() -> Void)?

    var body: some View {
        SettingsFullRow {
            SettingsValue(code, lineLimit: 4, alignment: .leading)
                .accessibilityIdentifier(codeIdentifier)
            HStack(spacing: PillMetrics.spacing) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    SettingsStatus(
                        String(
                            format: String(localized: "settings.devices.code_expires_format"),
                            SettingsCodeRow.countdown(until: expiresAt, now: context.date)
                        ),
                        systemImage: "timer"
                    )
                }
                if let info, info.isEmpty == false {
                    InfoButton(info)
                }
                Spacer(minLength: Spacing.sm)
                ActionPill(
                    String(localized: "settings.action.copy"),
                    systemImage: "doc.on.doc",
                    action: onCopy
                )
                if let onCancel {
                    ActionPill(
                        String(localized: "settings.devices.cancel_code"),
                        systemImage: "xmark",
                        style: .quiet,
                        action: onCancel
                    )
                }
            }
        }
    }

    static func countdown(until end: Date, now: Date) -> String {
        let remaining = max(0, Int(end.timeIntervalSince(now)))
        return String(format: "%d:%02d", remaining / 60, remaining % 60)
    }
}

// MARK: - 给测试看的固定画面

/// 设置几页在某一个状态下的样子,代替真的 store。
///
/// 只有测试会放它进环境:要看「邀请码在用」「存了密钥」「配了两台 Mac」是什么
/// 样子,不该真的去兑换、去存、去配对,也不该把这台 Mac 自己的名字和偏好画进
/// 图里。页面在环境里找到它,就只画它说的,既不读也不写自己的 store。
struct SettingsFixture {
    var liveText = LiveTextCardModel(source: .nothing)
    var devices = DevicesCardModel()
    var keys: [ProviderCredentialAccount: SettingsKeyModel] = [:]
    var cleanupEnabled = false
    var sharing = SharingCardModel()
    var backup = BackupCardModel()
    /// Which side of first launch's second step to show.
    var onboardingMode: OnboardingLiveTextMode?
}

private struct SettingsFixtureKey: EnvironmentKey {
    static let defaultValue: SettingsFixture? = nil
}

extension EnvironmentValues {
    var settingsFixture: SettingsFixture? {
        get { self[SettingsFixtureKey.self] }
        set { self[SettingsFixtureKey.self] = newValue }
    }
}
