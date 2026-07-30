// SegmentedTab.swift
// Zulangue 微交互组件库 — Tab 切换器
// 权威:docs/redesign/redesign-plan.md §4.B.2.4
//
// 设计原则覆盖:
//   #1 4 状态视觉反馈 ✓
//   #2 motion(matchedGeometry 滑动 + spring)✓
//   #5 focus ring(每个 tab 都可键盘 focus)✓
//
// 核心设计:
//   - matchedGeometryEffect 让 indicator 平滑滑动到下一个 tab
//   - 选中文字 + 下划线 indicator(不用背景填充,更克制)
//   - 替代 SessionDetailView 当前的硬切 Tab
//
// 用法:
//   enum DetailTab { case transcript, summary, audio }
//   @State var selected: DetailTab = .transcript
//
//   SegmentedTab(
//       items: [
//           (.transcript, "Transcript", Icon.transcript),
//           (.summary,    "Summary",    Icon.summary),
//           (.audio,      "Audio",      Icon.audio),
//       ],
//       selection: $selected
//   )

import SwiftUI

struct SegmentedTab<Tab: Hashable>: View {
    let items: [SegmentedTabItem<Tab>]
    @Binding var selection: Tab
    var onChange: ((Tab) -> Void)? = nil

    @Namespace private var indicatorNamespace

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items, id: \.tab) { item in
                tabButton(for: item)
            }
        }
        .background(Color.bgPanel)
        .overlay(
            Rectangle().fill(Color.borderSubtle).frame(height: 1),
            alignment: .bottom
        )
    }

    @ViewBuilder
    private func tabButton(for item: SegmentedTabItem<Tab>) -> some View {
        SegmentedTabButton(
            item: item,
            isSelected: selection == item.tab,
            namespace: indicatorNamespace,
            onTap: {
                withAnimation(Motion.panelTransition) {
                    selection = item.tab
                }
                onChange?(item.tab)
            }
        )
    }
}

struct SegmentedTabItem<Tab: Hashable> {
    let tab: Tab
    let label: String
    let icon: String?
    /// 可选 accessibility identifier — 用于 UI 测试 hook(默认 nil 不注入)
    let accessibilityIdentifier: String?

    init(_ tab: Tab, _ label: String, icon: String? = nil, accessibilityIdentifier: String? = nil) {
        self.tab = tab
        self.label = label
        self.icon = icon
        self.accessibilityIdentifier = accessibilityIdentifier
    }
}

private struct SegmentedTabButton<Tab: Hashable>: View {
    let item: SegmentedTabItem<Tab>
    let isSelected: Bool
    let namespace: Namespace.ID
    let onTap: () -> Void

    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                if let icon = item.icon {
                    Image(systemName: icon).iconSizeSmall()
                }
                Text(item.label)
                    .font(.sans11Semibold)
            }
            .foregroundColor(currentForeground)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(currentBackground)
            .overlay(alignment: .bottom) {
                if isSelected {
                    Rectangle()
                        .fill(Color.brandAccent)
                        .frame(height: 2)
                        .matchedGeometryEffect(id: "indicator", in: namespace)
                }
            }
        }
        .buttonStyle(.plain)
        .focusable()
        .focused($isFocused)
        .focusRing(isFocused, cornerRadius: 0, intensity: .subtle)
        .accessibilityLabel(item.label)
        .accessibilityIdentifier(item.accessibilityIdentifier ?? "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .onHover { isHovering = $0 }
        .animation(Motion.microInteraction, value: isHovering)
    }

    private var currentForeground: Color {
        if isSelected { return .textPrimary }
        if isHovering || isFocused { return .textSecondary }
        return .textTertiary
    }

    @ViewBuilder
    private var currentBackground: some View {
        if isHovering && !isSelected {
            Color.bgElevated.opacity(0.5)
        } else {
            Color.clear
        }
    }
}

#if DEBUG
struct SegmentedTab_Previews: PreviewProvider {
    enum PreviewTab: Hashable { case transcript, summary, audio }

    struct PreviewWrapper: View {
        @State private var selected: PreviewTab = .transcript
        var body: some View {
            VStack(spacing: 0) {
                SegmentedTab(
                    items: [
                        SegmentedTabItem(.transcript, "Transcript", icon: Icon.transcript),
                        SegmentedTabItem(.summary, "Summary", icon: Icon.summary),
                        SegmentedTabItem(.audio, "Audio", icon: Icon.audio),
                    ],
                    selection: $selected
                )
                Text("Selected: \(String(describing: selected))")
                    .font(.sans12).foregroundColor(.textSecondary)
                    .padding()
            }
            .frame(width: 480)
            .background(Color.bgRoot)
        }
    }

    static var previews: some View {
        PreviewWrapper()
    }
}
#endif
