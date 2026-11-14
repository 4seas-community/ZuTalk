// CityFilingChip.swift
// 录音自己身上的那一枚:这场录音到城里了没有。
//
// 0.8.0 里要知道一场录音交没交上,得打开它的共享面板,或者去设置里翻那张
// 表;录音页和列表上什么都看不出来。负责人用了以后要的就是这个:「素材弄完
// 后,同步到城,应该有一个状态的管理。」
//
//   - `CityStatusWord`:状态的统一样子 —— 一个图标,一个词;要多说的那一句
//     在悬停提示里。共享面板、设置里的表、这里的那一枚都用它;
//   - `CityFilingChip`:录音页顶栏上,文字的状态,文字交上去以后旁边再有
//     音频的状态(「已交 · 音频 3/24」);
//   - `CityFilingMark`:录音列表的一行上,只有图标,悬停和旁白念出整句。
//
// 说的是同一套话(`CityFilingStatus`),点下去都是打开这场录音的共享面板 ——
// 交、重试、更新、换活动、补交音频、撤下都在那里的「档案馆」一段。这里只说
// 状态,不另起一套按钮。
//
// 没登录、或者这场录音没归过活动,两处都不出现,页面和原来一样。状态读的是
// `CityStore` 里存的那一份,不为每一行去问核心。

import SwiftUI

/// 状态:一个图标,一个词。颜色只在图标上。
struct CityStatusWord: View {
    let symbol: String
    let label: String
    let tone: CityFilingStatus.Tone
    /// 这个词展开来的那一句。
    var help: String?

    init(symbol: String, label: String, tone: CityFilingStatus.Tone, help: String? = nil) {
        self.symbol = symbol
        self.label = label
        self.tone = tone
        self.help = help
    }

    /// 文字这一路。
    init(_ status: CityFilingStatus) {
        self.init(
            symbol: status.symbol,
            label: status.label,
            tone: status.tone,
            help: [status.hint == status.label ? nil : status.hint, status.reason]
                .compactMap { $0 }
                .joined(separator: "\n")
        )
    }

    /// 音频这一路。
    init(_ audio: CityAudioStatus) {
        self.init(symbol: audio.symbol, label: audio.label, tone: audio.tone, help: audio.reason)
    }

    var body: some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: symbol)
                .iconSizeSmall()
                .foregroundColor(tone.color)
                .accessibilityHidden(true)
            Text(label)
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

/// 录音页顶栏上的那一枚。
struct CityFilingChip: View {
    let sessionId: String
    /// 打开这场录音的档案馆那张表(`CityFilingSheet`)。
    let onOpen: () -> Void
    /// 不读 `CityStore`,就画这一种状态:单独拿出来看用。
    var shownStatus: CityFilingStatus?

    @ObservedObject private var city = CityStore.shared

    var body: some View {
        if let shownStatus {
            chip(shownStatus, title: nil)
        } else if city.account != nil,
                  city.filings[sessionId] != nil || city.busySessions.contains(sessionId) {
            chip(city.status(sessionId: sessionId), title: city.filings[sessionId]?.eventTitle)
                .task(id: sessionId) { await refresh() }
        }
    }

    private func chip(_ status: CityFilingStatus, title: String?) -> some View {
        Button(action: onOpen) {
            HStack(spacing: Spacing.sm) {
                CityStatusWord(symbol: status.symbol, label: status.label, tone: status.tone)
                if let audio = status.audioBeside {
                    CityStatusWord(symbol: audio.symbol, label: audio.label, tone: audio.tone)
                }
            }
            .padding(.horizontal, Spacing.sm + 2)
            .frame(minHeight: 24)
            .overlay(Capsule().strokeBorder(Color.borderSubtle, lineWidth: Stroke.thin))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(status.tooltip(event: title))
        .accessibilityLabel(Text(status.described(event: title)))
        .accessibilityHint(Text(String(localized: "city.filing.open_hint")))
        .accessibilityIdentifier(AccessibilityID.cityRecordingStatus)
        // 和右边「⋯」之间的空当跟着这一枚一起出现、一起消失:没归过活动的
        // 录音,顶栏一个点都不挪。
        .padding(.trailing, Spacing.sm)
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
            // 一行只有一个图标的地方:音频要人看一眼(城没收、太大、没导出
            // 来)时让给它,别的时候说文字这一路。
            let audio = status.audioBeside.flatMap { $0.tone == .failure ? $0 : nil }
            Button {
                ShareActivityStore.shared.presentRecordingShare(sessionId: sessionId, title: title)
            } label: {
                Image(systemName: audio?.symbol ?? status.symbol)
                    .iconSizeSmall()
                    .foregroundColor((audio?.tone ?? status.tone).color)
                    .frame(width: 24, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(status.tooltip(event: filing.eventTitle))
            .accessibilityLabel(Text(status.described(event: filing.eventTitle)))
            .accessibilityHint(Text(String(localized: "city.status.open_share_hint")))
            .accessibilityIdentifier(AccessibilityID.cityRowMark(sessionId: sessionId))
        }
    }
}
