// CitySidebarLine.swift
// 侧栏底部的一行:「档案馆:1 场排队中」「档案馆:1 场没交上」。
//
// 交档案馆在后台,交不上的那一场以前只有一条几秒钟的提示,之后主窗口上再
// 看不出还有东西没到城里 —— 得想起来去设置里翻。这一行一直挂在那,直到那
// 一场交上了或者人处理了;点它就到「设置 › 城」那张表。
//
// 只在登录了、而且确实有排着队的、正在交的、没交上的、或活动被删的时候
// 出现。全都好就什么都没有:没事的时候侧栏不多一行字。
//
// 它自己是一个视图、自己盯着 `CityStore`:侧栏所在的 `MainShellView` 一重画
// 就是整个窗口。

import SwiftUI

struct CitySidebarLine: View {
    /// 打开「设置 › 城」。
    let onOpen: () -> Void

    @ObservedObject private var city = CityStore.shared

    var body: some View {
        if city.account != nil {
            let tally = CityFilingTally.count(city.filingList, busy: city.busySessions)
            if let attention = tally.attention {
                Button(action: onOpen) {
                    Label {
                        Text(attention.text)
                            .foregroundColor(.textSecondary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        // 排队的会自己再试,图标跟字一个颜色;要人管的才上色。
                        Image(systemName: attention.symbol)
                            .foregroundColor(attention.tone == .quiet ? .textSecondary : attention.tone.color)
                            .accessibilityHidden(true)
                    }
                    .font(.bodySM)
                    .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // 一行只说最要紧的一件;各有几场在悬停提示里说全。
                .help([tally.summary, String(localized: "city.sidebar.hint")]
                    .compactMap { $0 }
                    .joined(separator: "\n"))
                .accessibilityLabel(Text(attention.text))
                .accessibilityHint(Text(String(localized: "city.sidebar.hint")))
                .accessibilityIdentifier(AccessibilityID.citySidebarLine)
            }
        }
    }
}
