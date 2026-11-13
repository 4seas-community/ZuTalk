// CityFilingsCard.swift
// 设置 › 城 里「交到档案馆的录音」那张表:在这台 Mac 上归过活动的每一场,
// 交到哪一步了,这一步能做什么。管这件事的地方就是这里。
//
// 0.8.0 的这张表只列已交、排队、没交上的三种,而且每一种只有一两个按钮:
// 只选了活动还没交的、撤下的不在表上,没交上的也只能重试 —— 活动在城里
// 被删了的那一场,重试多少次都一样,表上却没有别的路。现在每一场都在:
// 已选活动还没交、排队、正在交、已交、交了又改过字、活动被删、没交上、
// 已撤下。每一行说的话、图标、颜色、头一个按钮都来自 `CityFilingStatus`,
// 和录音页、列表、共享面板上是同一套;别的能做的事收在「⋯」里。
//
// 表头一行数一遍各有几场,不用一行行看也知道有没有卡住的。

import AppKit
import SwiftUI

struct CityFilingsCard: View {
    @ObservedObject private var city = CityStore.shared
    @State private var withdrawing: FfiCityFiling?
    @State private var repicking: Repick?
    /// 在日历那张表上按了「这场不交」、而这一场已经交上去了:等那张表收起来
    /// 再问撤不撤 —— 一张表还没收完,确认框出不来。
    @State private var withdrawAfterPicking: FfiCityFiling?

    /// 给哪一场换活动,连同它的起止(时间重合的活动排最前)。
    private struct Repick: Identifiable {
        let filing: FfiCityFiling
        let span: CityRecordingSpan?
        var id: String { filing.sessionId }
    }

    /// 「⋯」里的一项。
    enum MenuAction: Equatable {
        case open(URL)
        case retry
        case changeEvent
        case withdraw
        /// 不交了:把选的活动清掉。只清这台 Mac 上的选择,不碰城里的东西。
        case drop
        /// 在 ZuTalk 里打开这场录音。表上只写得出活动名,人要认得是哪一场。
        case showRecording
    }

    var body: some View {
        let rows = city.filingList
        // 表上只有撤下的几场时没有什么可数的,那一行就不出。
        let summary = CityFilingTally.count(rows, busy: city.busySessions).summary
            ?? (rows.isEmpty ? String(localized: "city.filings.empty") : nil)
        SettingsCard(
            title: String(localized: "city.filings.title"),
            subtitle: String(localized: "city.filings.subtitle")
        ) {
            if let summary {
                SettingsFullRow {
                    Text(summary)
                        .font(Font.sans12)
                        .foregroundColor(rows.isEmpty ? .textTertiary : .textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier(AccessibilityID.citySettingsFilingsSummary)
                }
            }
            ForEach(Array(rows.enumerated()), id: \.element.sessionId) { index, filing in
                if index > 0 || summary != nil { SettingsRowDivider() }
                row(filing)
            }
        }
        .accessibilityIdentifier(AccessibilityID.citySettingsFilings)
        .onAppear {
            city.reloadFilings()
            // 活动还在不在,要一份新近的活动列表才看得出;改了几句要逐场数。
            city.refreshCalendarIfStale()
            city.refreshChangedCounts()
        }
        .alert(
            String(localized: "city.withdraw.confirm_title"),
            isPresented: Binding(get: { withdrawing != nil }, set: { if !$0 { withdrawing = nil } }),
            presenting: withdrawing
        ) { filing in
            Button(String(localized: "city.withdraw.button"), role: .destructive) {
                withdrawing = nil
                Task { await city.withdraw(sessionId: filing.sessionId) }
            }
            Button(String(localized: "common.cancel"), role: .cancel) { withdrawing = nil }
        } message: { _ in
            // 撤下撤不干净:照实说,不让人以为点了就什么都没了。
            Text(String(localized: "city.withdraw.confirm_message"))
        }
        .sheet(item: $repicking, onDismiss: {
            guard let filing = withdrawAfterPicking else { return }
            withdrawAfterPicking = nil
            withdrawing = filing
        }) { repick in
            CityEventPickerSheet(selectedEventId: repick.filing.eventId, recording: repick.span) { event in
                choose(event, for: repick.filing)
            }
        }
    }

    // MARK: - 一行

    private func row(_ filing: FfiCityFiling) -> some View {
        let status = city.status(sessionId: filing.sessionId)
        return HStack(alignment: .center, spacing: Spacing.md) {
            Image(systemName: status.symbol)
                .iconSizeMedium()
                .foregroundColor(status.tone.color)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(filing.eventTitle)
                    .font(Font.sans12)
                    .foregroundColor(.textPrimary)
                    .lineLimit(2)
                Text(Self.detail(filing, status: status))
                    .font(Font.sans11)
                    .foregroundColor(.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if let reason = status.reason {
                    // 没交上的原因、活动被删以后会怎样:人能照做的整句。
                    Text(reason)
                        .font(Font.sans11)
                        .foregroundColor(.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: Spacing.md)
            if city.busySessions.contains(filing.sessionId) {
                ProgressView().controlSize(.small)
            } else {
                controls(filing, status: status)
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.citySettingsFiling(sessionId: filing.sessionId))
    }

    /// 头一个按钮是这个状态下最该做的那件事;别的收在「⋯」里,一行不排
    /// 三四个按钮。
    @ViewBuilder
    private func controls(_ filing: FfiCityFiling, status: CityFilingStatus) -> some View {
        HStack(spacing: Spacing.sm) {
            if let action = status.primaryAction {
                primaryButton(action, filing: filing, status: status)
            }
            let more = Self.menu(for: status, filing: filing)
            if more.isEmpty == false {
                Menu {
                    ForEach(Array(more.enumerated()), id: \.offset) { _, action in
                        menuItem(action, filing: filing)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .iconSizeMedium()
                        .foregroundColor(.textSecondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel(Text(String(
                    format: String(localized: "city.filings.more_format"),
                    filing.eventTitle
                )))
                .accessibilityIdentifier(AccessibilityID.citySettingsFilingMore)
            }
        }
    }

    @ViewBuilder
    private func primaryButton(
        _ action: CityFilingStatus.Action,
        filing: FfiCityFiling,
        status: CityFilingStatus
    ) -> some View {
        switch action {
        case .open(let url):
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                Label(String(localized: "city.action.open"), systemImage: "arrow.up.right.square")
            }
            .accessibilityIdentifier(AccessibilityID.citySettingsFilingOpen)
        case .update:
            Button(String(localized: "city.action.update")) {
                Task { await city.update(sessionId: filing.sessionId) }
            }
            .accessibilityIdentifier(AccessibilityID.citySettingsFilingUpdate)
        case .retry:
            Button(String(localized: status.kind == .waiting ? "city.share.retry_now" : "city.action.retry")) {
                Task { await city.file(sessionId: filing.sessionId) }
            }
            .accessibilityIdentifier(AccessibilityID.citySettingsFilingRetry)
        case .file:
            Button(String(localized: "city.action.file")) {
                Task { await city.file(sessionId: filing.sessionId) }
            }
            .accessibilityIdentifier(AccessibilityID.citySettingsFilingFile)
        case .chooseEvent:
            Button(String(localized: "city.action.change_event")) {
                repick(filing)
            }
            .accessibilityIdentifier(AccessibilityID.citySettingsFilingChange)
        }
    }

    @ViewBuilder
    private func menuItem(_ action: MenuAction, filing: FfiCityFiling) -> some View {
        switch action {
        case .open(let url):
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                Label(String(localized: "city.share.open"), systemImage: "arrow.up.right.square")
            }
            .accessibilityIdentifier(AccessibilityID.citySettingsFilingOpen)
        case .retry:
            Button {
                Task { await city.file(sessionId: filing.sessionId) }
            } label: {
                Label(String(localized: "city.action.retry"), systemImage: "arrow.clockwise")
            }
            .accessibilityIdentifier(AccessibilityID.citySettingsFilingRetry)
        case .changeEvent:
            Button {
                repick(filing)
            } label: {
                Label(String(localized: "city.action.change_event"), systemImage: "calendar")
            }
            .accessibilityIdentifier(AccessibilityID.citySettingsFilingChange)
        case .withdraw:
            Button(role: .destructive) {
                withdrawing = filing
            } label: {
                Label(String(localized: "city.share.withdraw"), systemImage: "arrow.uturn.backward")
            }
            .accessibilityIdentifier(AccessibilityID.citySettingsFilingWithdraw)
        case .drop:
            Button {
                Task { await city.bind(sessionId: filing.sessionId, event: nil) }
            } label: {
                Label(String(localized: "city.action.drop"), systemImage: "xmark.circle")
            }
            .accessibilityIdentifier(AccessibilityID.citySettingsFilingDrop)
        case .showRecording:
            Divider()
            Button {
                MainNavigationStore.shared.openSession(filing.sessionId)
            } label: {
                Label(String(localized: "city.action.show_recording"), systemImage: "waveform")
            }
            .accessibilityIdentifier(AccessibilityID.citySettingsFilingShow)
        }
    }

    // MARK: - 动作

    /// 先在后台读这场录音的起止,再打开日历:补归、换活动时,那一天、时间
    /// 重合的活动排在最前,不用人去翻。
    private func repick(_ filing: FfiCityFiling) {
        Task {
            let span = await city.recordingSpan(sessionId: filing.sessionId)
            repicking = Repick(filing: filing, span: span)
        }
    }

    private func choose(_ event: FfiCityEvent?, for filing: FfiCityFiling) {
        if let event {
            // 已经交上去的那一份:先撤下再归到新的一场,一步做完(`CityStore.move`)。
            Task { await city.move(sessionId: filing.sessionId, to: event) }
        } else if filing.state == .filed {
            // 「这场不交」对一份已经在档案馆里的东西,就是撤下:照样先问一句。
            withdrawAfterPicking = filing
        } else {
            Task { await city.bind(sessionId: filing.sessionId, event: nil) }
        }
    }

    // MARK: - 说法

    /// 「⋯」里有什么。头一个按钮已经占了的那件事不再列一遍。
    static func menu(for status: CityFilingStatus, filing: FfiCityFiling) -> [MenuAction] {
        var actions: [MenuAction]
        switch status.kind {
        case .notFiled, .sending:
            return []
        case .chosen, .waiting, .withdrawn:
            actions = [.changeEvent, .drop]
        case .filed:
            actions = [.withdraw]
        case .changed:
            actions = CityText.webURL(filing.webUrl).map { [.open($0), .withdraw] } ?? [.withdraw]
        case .eventGone:
            // 城里看不到这一件,「打开」只会打开一个空页面;能做的是换活动
            // (头一个按钮)和撤下。
            actions = [.withdraw]
        case .failed:
            // 活动被删的那一种,头一个按钮是换活动;活动要是在城里恢复了,
            // 重试也交得上,所以留着。
            actions = status.primaryAction == .chooseEvent
                ? [.retry, .drop]
                : [.changeEvent, .drop]
        }
        return actions + [.showRecording]
    }

    /// 「11月6日 · English、ไทย和中文 · 已交到档案馆」:哪天的活动、交了哪几种
    /// 语言、交到哪一步了。
    static func detail(_ filing: FfiCityFiling, status: CityFilingStatus) -> String {
        var parts = [CityText.day(CityText.date(ms: filing.eventStartMs))]
        let languages = CityText.languageNames(filing.languages.map(\.language))
        if languages.isEmpty == false {
            parts.append(ListFormatter.localizedString(byJoining: languages))
        }
        parts.append(status.label)
        return parts.joined(separator: " · ")
    }
}
