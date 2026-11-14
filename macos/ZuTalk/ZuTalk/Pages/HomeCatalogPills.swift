// HomeCatalogPills.swift
// 录音列表上方那一排筛选:一个名字,后面跟着它有几场。
//
// 共用的胶囊(`DesignSystem/Primitives/Pills.swift`)里没有「名字 + 数」这一
// 种,所以放在这里;样子用的是同一套 `PillChrome`、`PillPalette`、`PillMetrics`,
// 选中的那一颗就是「开着」的颜色。名字太长就截断,不把一排撑开;完整的名字在
// 悬停提示里。

import SwiftUI

/// One filter on the recordings list: what it keeps, and how many that is.
struct CatalogFilterPill: View {
    private let title: String
    private let count: Int
    private let isSelected: Bool
    private let action: () -> Void

    @State private var isHovering = false

    init(_ title: String, count: Int, isSelected: Bool, action: @escaping () -> Void) {
        self.title = title
        self.count = count
        self.isSelected = isSelected
        self.action = action
    }

    var body: some View {
        let tone = CatalogFilterPill.tone(isSelected: isSelected)
        let palette = PillPalette(tone: tone, isHovering: isHovering)
        Button(action: action) {
            HStack(spacing: PillMetrics.iconSpacing) {
                Text(title)
                    .font(PillMetrics.font)
                    .foregroundColor(palette.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: PillMetrics.maxTitleWidth)
                    .fixedSize(horizontal: true, vertical: false)
                Text("\(count)")
                    .font(PillMetrics.font)
                    .monospacedDigit()
                    .foregroundColor(isSelected ? palette.title.opacity(0.7) : .textTertiary)
            }
            .padding(.horizontal, PillMetrics.horizontalPadding)
            .modifier(PillChrome(tone: tone, isHovering: isHovering))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(Motion.microInteraction, value: isHovering)
        // The whole name, for one that was cut.
        .help(title)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text("\(count)"))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// The selected filter is painted like a toggle that is on.
    nonisolated static func tone(isSelected: Bool) -> PillTone {
        isSelected ? .on : .normal
    }
}

/// Which topics get a filter of their own, and which wait in the "more"
/// menu: the most recently used few, plus the selected one wherever it is —
/// what is filtering the list must be on screen.
nonisolated enum CatalogFilterLayout {
    static let limit = 6

    /// How many topics get a pill of their own in a strip this wide, so the
    /// "more" menu at the end stays on screen without scrolling: what "All",
    /// "Not in a topic" and that menu take, then about one short name each.
    /// A long name can still push the strip into scrolling; that is the
    /// last resort, not the usual case.
    static func limit(forWidth width: CGFloat) -> Int {
        let fixed: CGFloat = 320
        let each: CGFloat = 105
        return min(limit, max(1, Int((width - fixed) / each)))
    }

    static func split(
        topicIds: [String],
        selected: String?,
        limit: Int = CatalogFilterLayout.limit
    ) -> (shown: [String], more: [String]) {
        var shown = Array(topicIds.prefix(limit))
        if let selected, topicIds.contains(selected), shown.contains(selected) == false {
            shown.append(selected)
        }
        let visible = Set(shown)
        let more = topicIds.filter { visible.contains($0) == false }
        // A menu holding one topic takes more room than that topic's own
        // pill, and hides it for nothing.
        return more.count == 1 ? (topicIds, []) : (shown, more)
    }
}
