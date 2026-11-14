// PlainRows.swift
// 一页设置的骨架:一个词的标题,下面一行一行的「名字 + 控件」。
//
// 「界面怎么写」(docs/product/interface-layers.md):一行就是名字加控件,表面
// 不写句子,分组靠留白和一个词的小标题。主题选项、专有词与背景、回收站、协作
// 这几页都照这个样子摆,所以骨架放在一处:
//
//   - `PlainPageHeader`  一个词的页标题,右边放这一页的动作或状态。原来写在
//                        标题下面的那句话进了标题的悬停提示和无障碍提示。
//   - `PlainRowGroup`    一组行。各行的名字占同一个宽度(取最长的那个),
//                        控件就对齐在同一条线上,换了语言也一样。
//   - `PlainRow`         一行:名字,然后是控件(通常是一排胶囊)。
//   - `PlainRowDetail`   行下面跟着的东西(一句出错的话、展开的预览),和
//                        控件对齐,不和名字对齐。
//   - `PlainEmptyLine`   空状态的那一句。
//   - `FilledActionPill` 这一屏唯一的主按钮,和胶囊一样高。
//
// 小控件本身在 `DesignSystem/Primitives/Pills.swift`,这里不重画。

import SwiftUI

// MARK: - 页标题

/// A page's one-word title, with whatever the page offers at the far end.
/// The sentence that used to sit under the title is its tooltip and what
/// VoiceOver reads after it.
struct PlainPageHeader<Trailing: View>: View {
    private let title: String
    private let help: String?
    private let trailing: Trailing

    init(_ title: String, help: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.help = help
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.sm) {
            Text(title)
                .font(.titleLG)
                .foregroundColor(.textPrimary)
                .lineLimit(1)
                .help(help ?? "")
                .accessibilityHint(Text(help ?? ""))
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: Spacing.md)
            trailing
        }
        // As tall as a pill whether or not anything sits at the far end, so
        // what follows starts at the same place on every page.
        .frame(minHeight: PillMetrics.height)
    }
}

extension PlainPageHeader where Trailing == EmptyView {
    init(_ title: String, help: String? = nil) {
        self.init(title, help: help) { EmptyView() }
    }
}

/// A small header over a group: one word, its explanation in the tooltip.
struct PlainSectionHeader: View {
    private let title: String
    private let help: String?

    init(_ title: String, help: String? = nil) {
        self.title = title
        self.help = help
    }

    var body: some View {
        Text(title)
            .font(.bodyMedium)
            .foregroundColor(.textPrimary)
            .lineLimit(1)
            .help(help ?? "")
            .accessibilityHint(Text(help ?? ""))
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - 行

/// The widest name among a group's rows.
private struct PlainRowNameWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct PlainRowNameWidthEnvironmentKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

private extension EnvironmentValues {
    /// The width every name in the group is given; nil until measured.
    var plainRowNameWidth: CGFloat? {
        get { self[PlainRowNameWidthEnvironmentKey.self] }
        set { self[PlainRowNameWidthEnvironmentKey.self] = newValue }
    }
}

/// Rows that share one name column. The column is as wide as the longest
/// name, in whatever language the names are in.
struct PlainRowGroup<Content: View>: View {
    private let spacing: CGFloat
    private let content: Content

    @State private var nameWidth: CGFloat?

    init(spacing: CGFloat = Spacing.xsm, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            content
        }
        .environment(\.plainRowNameWidth, nameWidth)
        .onPreferenceChange(PlainRowNameWidthKey.self) { width in
            nameWidth = width > 0 ? width.rounded(.up) : nil
        }
    }
}

/// One row: a name, then its control. The name is one word; the sentence
/// that explains the row is the name's tooltip.
struct PlainRow<Control: View>: View {
    private let name: String
    private let help: String?
    private let control: Control

    @Environment(\.plainRowNameWidth) private var nameWidth

    init(_ name: String, help: String? = nil, @ViewBuilder control: () -> Control) {
        self.name = name
        self.help = help
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.md) {
            Text(name)
                .font(.body)
                .foregroundColor(.textSecondary)
                .lineLimit(1)
                .fixedSize()
                // Measured before the shared width is applied, so the name
                // reports its own width however wide the column has become.
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: PlainRowNameWidthKey.self,
                            value: proxy.size.width
                        )
                    }
                )
                .frame(width: nameWidth, alignment: .leading)
                .frame(minHeight: PillMetrics.height)
                .help(help ?? "")
                .accessibilityHint(Text(help ?? ""))
            control
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Something that belongs to the row above it — an error and its one
/// action, an opened preview — lined up with the controls, not the names.
struct PlainRowDetail<Content: View>: View {
    private let content: Content

    @Environment(\.plainRowNameWidth) private var nameWidth

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, (nameWidth ?? 0) + Spacing.md)
    }
}

// MARK: - 空状态

/// The one sentence of an empty page.
struct PlainEmptyLine: View {
    private let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.body)
            .foregroundColor(.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 状态

/// A status: an icon and a word. The detail, when there is one, is the
/// tooltip.
struct PlainStatus: View {
    private let title: String
    private let systemImage: String?
    private let tint: Color
    private let help: String?

    /// - Parameter systemImage: Nil for a plain dot in `tint`: on or off,
    ///   with nothing more to picture.
    init(_ title: String, systemImage: String?, tint: Color = .textSecondary, help: String? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.help = help
    }

    var body: some View {
        HStack(spacing: PillMetrics.iconSpacing) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(PillMetrics.iconFont)
                    .foregroundColor(tint)
                    .accessibilityHidden(true)
            } else {
                Circle()
                    .fill(tint)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.bodySM)
                .foregroundColor(.textSecondary)
                .lineLimit(1)
        }
        .fixedSize()
        .help(help ?? "")
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text(help ?? ""))
    }
}

// MARK: - 主按钮

/// The one filled button of a screen, the height of a pill so it sits in a
/// row with them. Brand green, like Home's Start.
struct FilledActionPill: View {
    private let title: String
    private let systemImage: String
    private let help: String?
    private let accessibilityLabel: String?
    private let action: () -> Void

    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    init(
        _ title: String,
        systemImage: String,
        help: String? = nil,
        accessibilityLabel: String? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.help = help
        self.accessibilityLabel = accessibilityLabel
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: PillMetrics.iconSpacing) {
                Image(systemName: systemImage)
                    .font(PillMetrics.iconFont)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.bodyMedium)
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundColor(.brandAccentForeground)
            .padding(.horizontal, PillMetrics.horizontalPadding)
            .frame(height: PillMetrics.height)
            .background(isHovering && isEnabled ? Color.brandAccentHover : Color.brandAccent)
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.5)
        .onHover { isHovering = $0 }
        .animation(Motion.microInteraction, value: isHovering)
        .pillExplained(help: help, label: accessibilityLabel)
    }
}
