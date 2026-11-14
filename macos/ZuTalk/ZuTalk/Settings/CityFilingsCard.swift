// CityFilingsCard.swift
// 设置 › 账号 › 档案馆 里「录音」那张表:在这台 Mac 上归过活动的每一场,
// 交到哪一步了,这一步能做什么。管这件事的地方就是这里。
//
// 一行:活动名、哪天,文字的状态和音频的状态(各是一个图标加一个词,和录音
// 页、列表、共享面板上是同一套,`CityFilingStatus`),最多一颗这一步最该按的
// 胶囊,其余收在「⋯」里:打开、更新、补交音频、换活动、撤下、不交了、打开
// 这场录音。
//
// 原因、交了哪几种语言这些要多说的,在那一行的悬停提示里;只有没交上、活动
// 在城里被删这两种要人动手的,把那一句写在行上。
//
// 有要人看一眼的(排队、没交上、音频城没收)时,表头多一行数一遍各有几场;
// 都顺利就没有这一行。

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

    /// 一行上能做的事。
    enum MenuAction: Equatable {
        case open(URL)
        case update
        case retry
        /// 交(选了活动还没交的)。
        case file
        /// 补交音频;上一次没交成的,再试一次。
        case fileAudio
        case retryAudio
        case changeEvent
        case withdraw
        /// 不交了:把选的活动清掉。只清这台 Mac 上的选择,不碰城里的东西。
        case drop
        /// 在 ZuTalk 里打开这场录音。表上只写得出活动名,人要认得是哪一场。
        case showRecording
    }

    var body: some View {
        CityFilingsList(
            rows: city.filingList.map { filing in
                CityFilingsList.Row(
                    filing: filing,
                    status: city.status(sessionId: filing.sessionId),
                    busy: city.busySessions.contains(filing.sessionId)
                )
            },
            tally: city.tally,
            perform: perform
        )
        .onAppear {
            city.reloadFilings()
            // 活动还在不在,要一份新近的活动列表才看得出;改了几句要逐场数。
            city.refreshCalendarIfStale()
            city.refreshChangedCounts()
        }
        .alert(
            String(localized: "city.withdraw.confirm_short"),
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
            Text(CityText.withdrawConfirmation)
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

    // MARK: - 动作

    private func perform(_ action: MenuAction, _ filing: FfiCityFiling) {
        let sessionId = filing.sessionId
        switch action {
        case .open(let url):
            NSWorkspace.shared.open(url)
        case .update:
            Task { await city.update(sessionId: sessionId) }
        case .retry, .file:
            Task { await city.file(sessionId: sessionId) }
        case .fileAudio, .retryAudio:
            city.fileAudio(sessionId: sessionId)
        case .changeEvent:
            // 先在后台读这场录音的起止,再打开日历:补归、换活动时,那一天、
            // 时间重合的活动排在最前,不用人去翻。
            Task {
                let span = await city.recordingSpan(sessionId: sessionId)
                repicking = Repick(filing: filing, span: span)
            }
        case .withdraw:
            withdrawing = filing
        case .drop:
            Task { await city.bind(sessionId: sessionId, event: nil) }
        case .showRecording:
            MainNavigationStore.shared.openSession(sessionId)
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

    /// 这一行上那一颗胶囊:这个状态下最该按的一件事。「打开」不算 —— 它在
    /// 「⋯」里;文字这一路没有要按的时,让给音频。
    static func pill(for status: CityFilingStatus) -> MenuAction? {
        switch status.primaryAction {
        case .update: return .update
        case .retry: return .retry
        case .file: return .file
        case .chooseEvent: return .changeEvent
        case .open, nil: break
        }
        switch status.audioBeside?.action {
        case .file: return .fileAudio
        case .retry: return .retryAudio
        case nil: return nil
        }
    }

    /// 「⋯」里有什么。那一颗胶囊已经占了的事不再列一遍。
    static func menu(for status: CityFilingStatus, filing: FfiCityFiling) -> [MenuAction] {
        var actions: [MenuAction]
        let audio: [MenuAction]
        switch status.audioBeside?.action {
        case .file: audio = [.fileAudio]
        case .retry: audio = [.retryAudio]
        case nil: audio = []
        }
        let open = CityText.webURL(filing.webUrl).map { [MenuAction.open($0)] } ?? []
        switch status.kind {
        case .notFiled, .sending:
            return []
        case .chosen, .waiting, .withdrawn:
            actions = [.changeEvent, .drop]
        case .filed, .changed:
            actions = open + audio + [.withdraw]
        case .eventGone:
            // 城里看不到这一件,「打开」只会打开一个空页面;能做的是换活动
            // (那一颗胶囊)和撤下。
            actions = audio + [.withdraw]
        case .failed:
            // 活动被删的那一种,胶囊是换活动;活动要是在城里恢复了,重试也
            // 交得上,所以留着。
            actions = status.primaryAction == .chooseEvent
                ? [.retry, .drop]
                : [.changeEvent, .drop]
        }
        let taken = pill(for: status)
        return actions.filter { $0 != taken } + [.showRecording]
    }

    /// 「11月6日」:哪天的活动。
    static func detail(_ filing: FfiCityFiling) -> String {
        CityText.day(CityText.date(ms: filing.eventStartMs))
    }

    /// 悬停提示里的那几行:交了什么、状态展开来的话、原因。
    static func tooltip(_ filing: FfiCityFiling, status: CityFilingStatus) -> String {
        var lines: [String] = []
        let content = CityText.content(filing)
        if content.isEmpty == false { lines.append(content) }
        lines.append(status.tooltip(event: filing.eventTitle))
        return lines.joined(separator: "\n")
    }

    static func title(_ action: MenuAction) -> String {
        switch action {
        case .open: return String(localized: "city.action.open")
        case .update: return String(localized: "city.action.update")
        case .retry, .retryAudio: return String(localized: "city.action.retry")
        case .file: return String(localized: "city.action.file")
        case .fileAudio: return String(localized: "city.audio.file")
        case .changeEvent: return String(localized: "city.action.change_event")
        case .withdraw: return String(localized: "city.action.withdraw")
        case .drop: return String(localized: "city.action.drop")
        case .showRecording: return String(localized: "city.action.show_recording")
        }
    }

    static func symbol(_ action: MenuAction) -> String {
        switch action {
        case .open: return "arrow.up.right.square"
        case .update: return "arrow.triangle.2.circlepath"
        case .retry, .retryAudio: return "arrow.clockwise"
        case .file: return "arrow.up.circle"
        case .fileAudio: return "waveform"
        case .changeEvent: return "calendar"
        case .withdraw: return "arrow.uturn.backward"
        case .drop: return "xmark.circle"
        case .showRecording: return "waveform"
        }
    }

    static func identifier(_ action: MenuAction) -> String {
        switch action {
        case .open: return AccessibilityID.citySettingsFilingOpen
        case .update: return AccessibilityID.citySettingsFilingUpdate
        case .retry: return AccessibilityID.citySettingsFilingRetry
        case .file: return AccessibilityID.citySettingsFilingFile
        case .fileAudio, .retryAudio: return "settings.city.filing.audio"
        case .changeEvent: return AccessibilityID.citySettingsFilingChange
        case .withdraw: return AccessibilityID.citySettingsFilingWithdraw
        case .drop: return AccessibilityID.citySettingsFilingDrop
        case .showRecording: return AccessibilityID.citySettingsFilingShow
        }
    }
}

/// 那张表本身:给什么画什么,所以每一种状态都能单独拿出来看。
struct CityFilingsList: View {
    struct Row: Identifiable {
        let filing: FfiCityFiling
        let status: CityFilingStatus
        var busy = false
        var id: String { filing.sessionId }
    }

    let rows: [Row]
    let tally: CityFilingTally
    let perform: (CityFilingsCard.MenuAction, FfiCityFiling) -> Void

    var body: some View {
        // 有要人看一眼的才数一遍;都顺利时每一行自己已经说清楚了。
        let summary = tally.needsALook ? tally.summary : nil
        SettingsCard(title: String(localized: "city.filings.word")) {
            if rows.isEmpty {
                SettingsFullRow {
                    Text(String(localized: "city.filings.empty"))
                        .font(Font.sans12)
                        .foregroundColor(.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier(AccessibilityID.citySettingsFilingsSummary)
                }
            } else if let summary {
                SettingsFullRow {
                    Text(summary)
                        .font(Font.sans12)
                        .foregroundColor(.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier(AccessibilityID.citySettingsFilingsSummary)
                }
            }
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 || summary != nil { SettingsRowDivider() }
                line(row)
            }
        }
        .accessibilityIdentifier(AccessibilityID.citySettingsFilings)
    }

    private func line(_ row: Row) -> some View {
        let filing = row.filing
        let status = row.status
        // 要人动手的两种把那一句写出来;别的在提示里。
        let sentence = status.kind == .failed || status.kind == .eventGone ? status.reason : nil
        return HStack(alignment: .center, spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(filing.eventTitle)
                    .font(Font.sans12)
                    .foregroundColor(.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: Spacing.sm) {
                    Text(CityFilingsCard.detail(filing))
                        .font(Font.sans11)
                        .foregroundColor(.textTertiary)
                        .lineLimit(1)
                        .fixedSize()
                    CityStatusWord(status)
                    if let audio = status.audioBeside {
                        CityStatusWord(audio)
                    }
                }
                if let sentence {
                    Text(sentence)
                        .font(Font.sans11)
                        .foregroundColor(.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .help(CityFilingsCard.tooltip(filing, status: status))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(filing.eventTitle + ", " + status.described(event: nil)))
            .accessibilityHint(Text(CityFilingsCard.tooltip(filing, status: status)))
            Spacer(minLength: Spacing.md)
            if row.busy {
                ProgressView()
                    .controlSize(.small)
                    .frame(height: PillMetrics.height)
            } else {
                controls(filing, status: status)
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.citySettingsFiling(sessionId: filing.sessionId))
    }

    /// 一颗这一步最该按的胶囊;别的收在「⋯」里,一行不排三四个按钮。
    @ViewBuilder
    private func controls(_ filing: FfiCityFiling, status: CityFilingStatus) -> some View {
        HStack(spacing: Spacing.sm) {
            if let action = CityFilingsCard.pill(for: status) {
                ActionPill(
                    CityFilingsCard.title(action),
                    systemImage: CityFilingsCard.symbol(action)
                ) {
                    perform(action, filing)
                }
                .accessibilityIdentifier(CityFilingsCard.identifier(action))
            }
            let more = CityFilingsCard.menu(for: status, filing: filing)
            if more.isEmpty == false {
                MoreMenu(
                    label: String(format: String(localized: "city.filings.more_format"), filing.eventTitle),
                    entries: more.map { action in
                        MoreMenu.Entry(title: CityFilingsCard.title(action)) { perform(action, filing) }
                    },
                    // 「打开这场录音」前面隔一条线:它不是对档案馆做的事。
                    separatorBeforeLast: more.count > 1
                )
                .accessibilityIdentifier(AccessibilityID.citySettingsFilingMore)
            }
        }
    }
}

/// 「⋯」:一颗只有图标的胶囊,点开是菜单。`Pills.swift` 里的菜单胶囊总带着
/// 一个词和一个 ⌄,这里只要三个点,所以菜单自己弹(系统的菜单,挂在胶囊
/// 底下,和别的菜单胶囊一样)。
private struct MoreMenu: View {
    struct Entry {
        let title: String
        let action: () -> Void
    }

    let label: String
    let entries: [Entry]
    let separatorBeforeLast: Bool
    @State private var presenter = MoreMenuPresenter()

    var body: some View {
        ActionPill(nil, systemImage: "ellipsis", help: label, accessibilityLabel: label) {
            presenter.popUp(entries, separatorBeforeLast: separatorBeforeLast)
        }
        .background(MoreMenuAnchor(presenter: presenter))
    }
}

@MainActor
private final class MoreMenuPresenter: NSObject {
    weak var anchor: NSView?
    private var actions: [() -> Void] = []

    func popUp(_ entries: [MoreMenu.Entry], separatorBeforeLast: Bool) {
        guard let anchor, anchor.window != nil else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        actions = entries.map(\.action)
        for (index, entry) in entries.enumerated() {
            if separatorBeforeLast, index > 0, index == entries.count - 1 {
                menu.addItem(.separator())
            }
            let item = NSMenuItem(title: entry.title, action: #selector(run(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            menu.addItem(item)
        }
        // 就在胶囊底下,左边对齐。
        let below = anchor.isFlipped ? anchor.bounds.maxY + 4 : -4
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: below), in: anchor)
    }

    @objc private func run(_ sender: NSMenuItem) {
        guard actions.indices.contains(sender.tag) else { return }
        actions[sender.tag]()
    }
}

/// 菜单挂在哪:那颗胶囊自己的位置。
private struct MoreMenuAnchor: NSViewRepresentable {
    let presenter: MoreMenuPresenter

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        presenter.anchor = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        presenter.anchor = view
    }
}
