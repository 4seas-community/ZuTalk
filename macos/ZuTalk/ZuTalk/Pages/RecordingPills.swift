// RecordingPills.swift
// 录音这一块在共享胶囊(DesignSystem/Primitives/Pills.swift)之外多出来的几样
// 小东西。尺寸、字号、颜色一律取 `PillMetrics` 和 `PillPalette`,所以它们和
// 首页那张卡上的胶囊摆在一起看是一家:
//
//   - `PrimaryPill`      一屏里唯一填了底色的那一颗:多数人来这里要做的那件事。
//   - `StatusWord`       状态:一个图标加一个词。不是控件,点了没反应;细节在
//                        悬停提示里。
//   - `MorePill`         ⋯:一颗圆胶囊,点开是排在后面的那些动作。
//   - `GroupHeader`      分组的小标题:一个词,不配副标题。
//   - `OneSentenceState` 空状态、出错时的那一句,加它唯一的动作。
//   - `DetailRow`        一行就是名字加值(或者名字加控件)。
//   - `SheetButtons`     面板底下的两颗:取消(安静的),和真正去做的那一颗。
//
// 和共享胶囊一样,每一样都把「原来写在旁边的那句话」当 `help` 收下,进悬停提示
// 和无障碍提示(docs/product/interface-layers.md「界面怎么写」)。

import SwiftUI

// MARK: - 主动作

/// The one filled pill on a surface. Drawn from the tokens rather than as a
/// system prominent button: that one goes grey whenever its window is not
/// the key one, and its white label is hard to read on the mint accent of
/// the dark appearance.
struct PrimaryPill: View {
    private let title: String
    private let systemImage: String
    private let help: String?
    private let action: () -> Void

    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    /// - Parameter help: The sentence that explains it, for the tooltip and
    ///   VoiceOver.
    init(
        _ title: String,
        systemImage: String,
        help: String? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.help = help
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: PillMetrics.iconSpacing) {
                Image(systemName: systemImage)
                    .font(PillMetrics.iconFont)
                    .accessibilityHidden(true)
                Text(title)
                    .font(PillMetrics.font)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundColor(.brandAccentForeground)
            .padding(.horizontal, PillMetrics.horizontalPadding)
            .frame(height: PillMetrics.height)
            .background(isHovering && isEnabled ? Color.brandAccentHover : Color.brandAccent)
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        // A plain button keeps the system's own keyboard focus behaviour:
        // reachable with full keyboard access, never taking focus on a click.
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.5)
        .onHover { isHovering = $0 }
        .animation(Motion.microInteraction, value: isHovering)
        .pillExplained(help: help)
    }
}

// MARK: - 状态

/// A status: an icon and a word, as tall as a pill so it lines up with the
/// pills beside it. It is not a control. Whatever more there is to say —
/// why, since when, what happens next — is the tooltip.
struct StatusWord: View {
    private let word: String
    private let systemImage: String
    private let tint: Color
    private let isBusy: Bool
    private let help: String?

    /// - Parameters:
    ///   - tint: The icon's colour; the word does not change colour with it.
    ///   - isBusy: Something is under way: a spinner stands in for the icon.
    init(
        _ word: String,
        systemImage: String,
        tint: Color = .textTertiary,
        isBusy: Bool = false,
        help: String? = nil
    ) {
        self.word = word
        self.systemImage = systemImage
        self.tint = tint
        self.isBusy = isBusy
        self.help = help
    }

    var body: some View {
        HStack(spacing: PillMetrics.iconSpacing) {
            if isBusy {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: systemImage)
                    .font(PillMetrics.iconFont)
                    .foregroundColor(tint)
                    .accessibilityHidden(true)
            }
            Text(word)
                .font(PillMetrics.font)
                .foregroundColor(.textSecondary)
                .lineLimit(1)
        }
        .frame(height: PillMetrics.height)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .pillExplained(help: help)
    }
}

// MARK: - ⋯

/// ⋯ as a round pill: the lesser actions of whatever it sits beside, one
/// click in. A borderless menu draws its own small pop-up button and ignores
/// the label's frame, which leaves a target a third the size of the circle
/// around it; the button style (macOS 13) makes the whole pill the target.
/// Monterey keeps the borderless form inside the same circle.
struct MorePill<Items: View>: View {
    private let label: String
    private let items: Items

    @State private var isHovering = false

    /// - Parameter label: What the menu is for — the tooltip, and what
    ///   VoiceOver calls it.
    init(_ label: String, @ViewBuilder items: () -> Items) {
        self.label = label
        self.items = items()
    }

    var body: some View {
        menu
            .onHover { isHovering = $0 }
            .help(label)
            .accessibilityLabel(Text(label))
    }

    @ViewBuilder
    private var menu: some View {
        if #available(macOS 13.0, *) {
            Menu {
                items
            } label: {
                Image(systemName: "ellipsis")
                    .font(PillMetrics.iconFont)
                    .foregroundColor(.textSecondary)
                    .frame(width: PillMetrics.height, height: PillMetrics.height)
                    .modifier(PillChrome(isHovering: isHovering))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        } else {
            Menu {
                items
            } label: {
                Image(systemName: "ellipsis")
                    .font(PillMetrics.iconFont)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .foregroundColor(.textSecondary)
            .frame(width: PillMetrics.height, height: PillMetrics.height)
            .modifier(PillChrome(isHovering: isHovering))
        }
    }
}

// MARK: - 小标题

/// The one word above a group. Groups are told apart by space and this
/// word, not by a box or a line of explanation under it.
struct GroupHeader: View {
    private let title: String
    private let help: String?

    init(_ title: String, help: String? = nil) {
        self.title = title
        self.help = help
    }

    var body: some View {
        Text(title)
            .font(.sans12Semibold)
            .foregroundColor(.textSecondary)
            .lineLimit(1)
            .accessibilityAddTraits(.isHeader)
            .pillExplained(help: help)
    }
}

// MARK: - 空状态、出错

/// The one sentence a surface may print when it has nothing to show or
/// something went wrong, and the one thing to do about it.
struct OneSentenceState: View {
    struct Action {
        var title: String
        var systemImage: String
        var handler: () -> Void
    }

    private let systemImage: String
    private let sentence: String
    private let tint: Color
    private let isBusy: Bool
    private let detail: String?
    private let action: Action?

    /// - Parameters:
    ///   - isBusy: Waiting rather than empty: a spinner stands in for the icon.
    ///   - detail: What used to be the paragraph under the sentence; it is
    ///     the tooltip and the accessibility hint now.
    init(
        systemImage: String,
        sentence: String,
        tint: Color = .textTertiary,
        isBusy: Bool = false,
        detail: String? = nil,
        action: Action? = nil
    ) {
        self.systemImage = systemImage
        self.sentence = sentence
        self.tint = tint
        self.isBusy = isBusy
        self.detail = detail
        self.action = action
    }

    var body: some View {
        VStack(spacing: Spacing.md) {
            if isBusy {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: systemImage)
                    .iconSizeHero()
                    .foregroundColor(tint)
                    .accessibilityHidden(true)
            }
            Text(sentence)
                .font(.body)
                .foregroundColor(.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
                .fixedSize(horizontal: false, vertical: true)
                .pillExplained(help: detail)
            if let action {
                ActionPill(action.title, systemImage: action.systemImage, action: action.handler)
            }
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 一行

/// A row of a details page: a name, then its value or its control. No
/// sentence under it; if the name needs one, it is the name's tooltip.
struct DetailRow<Trailing: View>: View {
    private let name: String
    private let systemImage: String
    private let help: String?
    private let trailing: Trailing

    static var nameWidth: CGFloat { 168 }

    init(
        _ name: String,
        systemImage: String,
        help: String? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.name = name
        self.systemImage = systemImage
        self.help = help
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: systemImage)
                    .font(PillMetrics.iconFont)
                    .foregroundColor(.textTertiary)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                Text(name)
                    .font(PillMetrics.font)
                    .foregroundColor(.textSecondary)
                    .lineLimit(1)
            }
            .frame(width: Self.nameWidth, alignment: .leading)
            .pillExplained(help: help)
            trailing
            Spacer(minLength: 0)
        }
        .frame(minHeight: PillMetrics.height + Spacing.xs)
    }
}

extension DetailRow where Trailing == DetailValue {
    /// A name and a value that can be selected and copied.
    init(_ name: String, systemImage: String, value: String, help: String? = nil) {
        self.init(name, systemImage: systemImage, help: help) {
            DetailValue(value)
        }
    }
}

/// The value of a `DetailRow`.
struct DetailValue: View {
    private let value: String

    init(_ value: String) {
        self.value = value
    }

    var body: some View {
        Text(value)
            .font(PillMetrics.font)
            .foregroundColor(.textPrimary)
            .lineLimit(2)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - 面板底下的两颗

/// The foot of a sheet: Cancel, quiet, and the one filled pill that does
/// what the sheet is for. Escape and Return reach them as they reach the
/// system's own sheet buttons.
struct SheetButtons: View {
    private let confirmTitle: String
    private let confirmSystemImage: String
    private let confirmIdentifier: String?
    private let isConfirmEnabled: Bool
    private let onCancel: () -> Void
    private let onConfirm: () -> Void

    init(
        confirm confirmTitle: String,
        systemImage confirmSystemImage: String = "checkmark",
        identifier confirmIdentifier: String? = nil,
        isEnabled isConfirmEnabled: Bool = true,
        onCancel: @escaping () -> Void,
        onConfirm: @escaping () -> Void
    ) {
        self.confirmTitle = confirmTitle
        self.confirmSystemImage = confirmSystemImage
        self.confirmIdentifier = confirmIdentifier
        self.isConfirmEnabled = isConfirmEnabled
        self.onCancel = onCancel
        self.onConfirm = onConfirm
    }

    var body: some View {
        HStack(spacing: Spacing.md) {
            Spacer(minLength: 0)
            ActionPill(
                String(localized: "common.cancel"),
                systemImage: "xmark",
                style: .quiet,
                action: onCancel
            )
            .keyboardShortcut(.cancelAction)
            PrimaryPill(confirmTitle, systemImage: confirmSystemImage, action: onConfirm)
                .keyboardShortcut(.defaultAction)
                .disabled(isConfirmEnabled == false)
                .accessibilityIdentifier(confirmIdentifier ?? "")
        }
    }
}
