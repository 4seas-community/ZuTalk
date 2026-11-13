// CityFilingChip.swift
// 录音自己身上的那一枚:这场录音到城里了没有。
//
// 0.8.0 里要知道一场录音交没交上,得打开它的共享面板,或者去设置里翻那张
// 表;录音页和列表上什么都看不出来。负责人用了以后要的就是这个:「素材弄完
// 后,同步到城,应该有一个状态的管理。」
//
//   - `CityFilingChip`:录音页顶栏上,图标加一句短话;
//   - `CityFilingMark`:录音列表的一行上,只有图标,悬停和旁白念出整句。
//
// 两处说的是同一套话(`CityFilingStatus`),点下去都是打开这场录音的共享
// 面板 —— 交、重试、更新、换活动、撤下都在那里的「档案馆」一段。这里只说
// 状态,不另起一套按钮。
//
// 没登录、或者这场录音没归过活动,两处都不出现,页面和原来一样。状态读的是
// `CityStore` 里存的那一份,不为每一行去问核心。

import SwiftUI

/// 录音页顶栏上的那一枚。
struct CityFilingChip: View {
    let sessionId: String
    /// 打开这场录音的共享面板。
    let onOpen: () -> Void

    @ObservedObject private var city = CityStore.shared

    var body: some View {
        if city.account != nil,
           city.filings[sessionId] != nil || city.busySessions.contains(sessionId) {
            let status = city.status(sessionId: sessionId)
            let described = status.described(event: city.filings[sessionId]?.eventTitle)
            Button(action: onOpen) {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: status.symbol)
                        .iconSizeSmall()
                        .foregroundColor(status.tone.color)
                        .accessibilityHidden(true)
                    Text(status.label)
                        .font(.bodySM)
                        .foregroundColor(.textSecondary)
                        .lineLimit(1)
                        // 最长的一句(「排队中,这台 Mac 联网后自动交」的德文)
                        // 也不把顶栏撑开;整句在悬停提示里。
                        .frame(maxWidth: 220)
                }
                .padding(.horizontal, Spacing.sm + 2)
                .frame(minHeight: 24)
                .overlay(Capsule().strokeBorder(Color.borderSubtle, lineWidth: Stroke.thin))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .help([described, status.reason].compactMap { $0 }.joined(separator: "\n"))
            .accessibilityLabel(Text(described))
            .accessibilityHint(Text(String(localized: "city.status.open_share_hint")))
            .accessibilityIdentifier(AccessibilityID.cityRecordingStatus)
            .task(id: sessionId) { await refresh() }
            // 和右边「⋯」之间的空当跟着这一枚一起出现、一起消失:没归过活动的
            // 录音,顶栏一个点都不挪。
            .padding(.trailing, Spacing.sm)
        }
    }

    /// 人正看着这场录音:把只有逐场才读得到的补上。
    private func refresh() async {
        guard city.filings[sessionId]?.state == .filed else { return }
        // 活动在城里还在不在,要一份交了以后才读的活动列表才看得出来。
        city.refreshCalendarIfStale()
        // 交上去以后改了几句,整张单子上没有,得单读这一场。
        await city.loadFiling(sessionId: sessionId)
    }
}

/// 录音列表一行上的记号。没归过活动的行不出现,也不占位置。
struct CityFilingMark: View {
    let sessionId: String
    /// 行上显示的名字,共享面板的标题用。
    let title: String
    /// 正在录的那一场不出记号:它归到哪在录音条上,共享面板也要录完才有。
    var isRecording = false

    @ObservedObject private var city = CityStore.shared

    var body: some View {
        if isRecording == false, city.account != nil, let filing = city.filings[sessionId] {
            let status = city.status(sessionId: sessionId)
            let described = status.described(event: filing.eventTitle)
            Button {
                ShareActivityStore.shared.presentRecordingShare(sessionId: sessionId, title: title)
            } label: {
                Image(systemName: status.symbol)
                    .iconSizeSmall()
                    .foregroundColor(status.tone.color)
                    .frame(width: 24, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(described)
            .accessibilityLabel(Text(described))
            .accessibilityHint(Text(String(localized: "city.status.open_share_hint")))
            .accessibilityIdentifier(AccessibilityID.cityRowMark(sessionId: sessionId))
        }
    }
}
