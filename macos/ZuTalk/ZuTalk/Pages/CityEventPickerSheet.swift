// CityEventPickerSheet.swift
// 「归到哪场活动」:左边是这座城的月历,右边是选中那天的活动清单。
//
// 活动多的时候(一个月一百多场,多的一天八场)靠翻日历来选。「开始录音」页、
// 录音条、共享面板要换一场活动时,打开的都是这一张表。
//
// 它只负责选:选了哪一场(或「不交」)交还给打开它的地方,由那边决定是
// 记到下一场录音上,还是绑到一场已有的录音上。活动列表读的是存在本机的那
// 一份,断网时照样能选;底下左边那一颗写着上次更新的时刻,点它就刷新,没读
// 到新的时带一个警示,原因在它的提示里。

import SwiftUI

struct CityEventPickerSheet: View {
    /// 打开时已经归到的那一场。
    let selectedEventId: String?
    /// 给一场录好的录音补归时,它的起止:时间重合的活动排最前。
    let recording: CityRecordingSpan?
    /// 选好了:一场活动;或者 nil,这场不交。
    let onChoose: (FfiCityEvent?) -> Void

    @Environment(\.presentationMode) private var presentationMode
    @ObservedObject private var city = CityStore.shared
    @State private var query = ""
    @State private var mineOnly = false
    @State private var day = Date()
    @State private var month = Date()
    @State private var selection: String?
    @State private var prepared = false

    /// 周一排头,日子和钟点按这台 Mac 的时区。
    private let calendar = CityCalendarLayout.mondayFirst()

    var body: some View {
        VStack(spacing: 0) {
            header
            toolbar
            Divider()
            // 「正在进行」「今天稍后」跟着钟走:表开着不动,分组也不会过时。
            TimelineView(.periodic(from: .now, by: 60)) { context in
                columns(now: context.date)
            }
            Divider()
            footer
        }
        .frame(width: 820, height: 600)
        .background(Color.bgRoot)
        .onAppear(perform: prepare)
        .accessibilityIdentifier(AccessibilityID.cityPicker)
    }

    // MARK: - 顶上

    private var header: some View {
        HStack(spacing: Spacing.xsm) {
            Text(String(localized: "city.picker.title"))
                .font(.titleMD)
                .foregroundColor(.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button(action: dismiss) {
                Image(systemName: Icon.xmark)
                    .iconSizeSmall()
                    .foregroundColor(.textSecondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(String(localized: "common.close")))
        }
        .padding(.horizontal, Spacing.md)
        .padding(.top, Spacing.md)
        .padding(.bottom, Spacing.xsm)
    }

    private var toolbar: some View {
        HStack(spacing: Spacing.sm + 2) {
            if let account = city.account {
                Label(
                    account.cityName.isEmpty ? account.server : account.cityName,
                    systemImage: "building.columns"
                )
                .font(.sans12)
                .foregroundColor(.textSecondary)
                .lineLimit(1)
            }
            HStack(spacing: Spacing.sm) {
                Image(systemName: Icon.search)
                    .iconSizeSmall()
                    .foregroundColor(.textTertiary)
                    .accessibilityHidden(true)
                TextField(String(localized: "city.picker.search_word"), text: $query)
                    .textFieldStyle(.plain)
                    .font(.sans12)
                    .help(String(localized: "city.picker.search"))
                    .accessibilityLabel(Text(String(localized: "city.picker.search")))
                    .accessibilityIdentifier(AccessibilityID.cityPickerSearch)
            }
            .padding(.horizontal, Spacing.sm + 2)
            .padding(.vertical, 6)
            .surfaceCard(
                fill: Color.bgRoot,
                cornerRadius: Radius.sm,
                border: Color.borderSubtle,
                borderWidth: Stroke.thin
            )
            Picker(String(localized: "city.picker.filter"), selection: $mineOnly) {
                Text(String(localized: "city.picker.filter_all")).tag(false)
                Text(String(localized: "city.picker.filter_mine")).tag(true)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
            .accessibilityIdentifier(AccessibilityID.cityPickerFilter)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.bottom, Spacing.xsm)
    }

    // MARK: - 月历与清单

    private func columns(now: Date) -> some View {
        let filtered = CityCalendarLayout.filter(city.calendar.events, query: query, mineOnly: mineOnly)
        let searching = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let counts = CityCalendarLayout.countsByDay(filtered, calendar: calendar)
        var groups = CityCalendarLayout.groups(
            on: day,
            from: filtered,
            now: now,
            recording: recording,
            calendar: calendar
        )
        let dayCount = groups.reduce(0) { $0 + $1.events.count }
        let allEnded = dayCount > 0 && groups.allSatisfy { group in
            group.events.allSatisfy { $0.endMs <= Int64(now.timeIntervalSince1970 * 1_000) }
        }
        if let elsewhere = CityCalendarLayout.otherDays(
            than: day,
            from: filtered,
            month: month,
            searching: searching,
            mineOnly: mineOnly,
            calendar: calendar
        ) {
            groups.append(elsewhere)
        }
        return HStack(spacing: 0) {
            CityMonthCalendarView(
                month: month,
                selectedDay: day,
                today: now,
                counts: counts,
                footnote: monthFootnote(filtered: filtered, dayCount: dayCount, now: now),
                calendar: calendar,
                onSelect: select(day:),
                onPage: { months in
                    month = CityCalendarLayout.month(month, offsetBy: months, calendar: calendar)
                }
            )
            .frame(width: 256)
            Divider()
            CityEventListView(
                dayTitle: dayTitle(now: now),
                daySummary: daySummary(count: dayCount, allEnded: allEnded),
                groups: groups,
                emptyText: emptyText(dayCount: dayCount),
                now: now,
                filedEventIds: Set(city.filingList.filter { $0.state == .filed }.map(\.eventId)),
                calendar: calendar,
                selection: $selection
            )
        }
    }

    private func select(day picked: Date) {
        day = calendar.startOfDay(for: picked)
        // 点了上个月、下个月露出来的那几天,月历跟过去。
        if calendar.isDate(picked, equalTo: month, toGranularity: .month) == false {
            month = CityCalendarLayout.startOfMonth(picked, calendar: calendar)
        }
    }

    private func dayTitle(now: Date) -> String {
        let title = CityText.formatted(day, template: "MMMdEEE", calendar: calendar, locale: .current)
        if calendar.isDate(day, inSameDayAs: now) {
            return title + " · " + String(localized: "city.picker.today")
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(day, inSameDayAs: yesterday) {
            return title + " · " + String(localized: "city.picker.yesterday")
        }
        return title
    }

    private func daySummary(count: Int, allEnded: Bool) -> String {
        guard count > 0 else { return "" }
        if mineOnly {
            return String(format: String(localized: "city.picker.count_mine_format"), Int64(count))
        }
        return String(
            format: String(localized: allEnded ? "city.picker.count_ended_format" : "city.picker.count_format"),
            Int64(count)
        )
    }

    private func monthFootnote(filtered: [FfiCityEvent], dayCount: Int, now: Date) -> String {
        let monthCount = Int64(CityCalendarLayout.count(inMonth: month, from: filtered, calendar: calendar))
        if mineOnly {
            return String(format: String(localized: "city.picker.month_mine_format"), monthCount)
        }
        return String(
            format: String(localized: calendar.isDate(day, inSameDayAs: now)
                ? "city.picker.month_today_format"
                : "city.picker.month_day_format"),
            monthCount,
            Int64(dayCount)
        )
    }

    private func emptyText(dayCount: Int) -> String? {
        guard dayCount == 0 else { return nil }
        if city.calendar.fetchedAtEpoch == 0, city.calendar.events.isEmpty {
            return String(localized: "city.picker.empty_never")
        }
        return String(localized: mineOnly ? "city.picker.empty_mine" : "city.picker.empty_day")
    }

    // MARK: - 底下

    private var footer: some View {
        HStack(spacing: Spacing.sm) {
            if city.refreshingCalendar {
                ProgressView()
                    .controlSize(.small)
                    .frame(height: PillMetrics.height)
            } else {
                // 状态和动作是同一颗:写着上次更新的时刻,点它就刷新。
                ActionPill(
                    updatedWord,
                    systemImage: "arrow.clockwise",
                    style: .quiet,
                    mark: city.calendarProblem == nil ? .none : .warning,
                    // 读不到新的不耽误选:存着的那一份还在。原因在这里。
                    help: [updatedText, city.calendarProblem].compactMap { $0 }.joined(separator: "\n"),
                    accessibilityLabel: String(localized: "city.picker.refresh")
                ) {
                    city.refreshCalendar()
                }
                .accessibilityIdentifier(AccessibilityID.cityPickerRefresh)
            }
            Spacer(minLength: Spacing.sm)
            ActionPill(
                String(localized: "home.card.dont_file"),
                systemImage: "xmark.circle",
                style: .quiet,
                help: String(localized: "city.action.not_filing")
            ) {
                choose(nil)
            }
            .accessibilityIdentifier(AccessibilityID.cityPickerNotFiling)
            Button(String(localized: "common.cancel"), action: dismiss)
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier(AccessibilityID.cityPickerCancel)
            Button(String(localized: "city.picker.confirm")) {
                choose(selectedEvent)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(selectedEvent == nil)
            .accessibilityIdentifier(AccessibilityID.cityPickerConfirm)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm + 2)
    }

    /// 那一颗上写的:上次更新的时刻;还没读到过就是「刷新」。
    private var updatedWord: String {
        guard city.calendar.fetchedAtEpoch > 0 else {
            return String(localized: "city.picker.refresh")
        }
        return CityText.moment(epoch: city.calendar.fetchedAtEpoch, calendar: calendar)
    }

    private var updatedText: String {
        guard city.calendar.fetchedAtEpoch > 0 else {
            return String(localized: "city.picker.never_updated")
        }
        return String(
            format: String(localized: "city.picker.updated_format"),
            CityText.moment(epoch: city.calendar.fetchedAtEpoch, calendar: calendar)
        )
    }

    private var selectedEvent: FfiCityEvent? {
        guard let selection else { return nil }
        return city.calendar.events.first { $0.id == selection }
    }

    // MARK: - 动作

    private func prepare() {
        guard prepared == false else { return }
        prepared = true
        let now = Date()
        let events = city.calendar.events
        selection = CityCalendarLayout.initialSelection(
            current: selectedEventId,
            events: events,
            recording: recording
        )
        day = CityCalendarLayout.initialDay(now: now, recording: recording, calendar: calendar)
        // 已经归到别的日子的一场:打开就看得见它,不用人去翻。
        if recording == nil, let selection, let chosen = events.first(where: { $0.id == selection }) {
            day = CityCalendarLayout.day(of: chosen, calendar: calendar)
        }
        month = CityCalendarLayout.startOfMonth(day, calendar: calendar)
        city.refreshCalendarIfStale(now: now)
        city.reloadFilings()
    }

    private func choose(_ event: FfiCityEvent?) {
        onChoose(event)
        dismiss()
    }

    private func dismiss() {
        presentationMode.wrappedValue.dismiss()
    }
}
