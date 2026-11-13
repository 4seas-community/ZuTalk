// CityCalendarLayout.swift
// 「归到哪场活动」那张表怎么排:月历的格子、每天几场、选中那天的清单怎么分组。
//
// 日历管「哪一天」,清单管「哪一场」。这里只算,不画:哪些活动算「此刻正在
// 进行」「和这场录音重合」的产品判断在 `CityEventMatching`,这里拿来排位置。

import CoreGraphics
import Foundation

/// 清单里的一组。
struct CityEventGroup: Identifiable, Equatable {
    enum Kind: Hashable {
        /// 和这场录音时间重合的(事后补归时排最前)。
        case overlapping
        case running
        case laterToday
        case endedToday
        /// 有「重合」那一组时,这一天剩下的。
        case restOfDay
        /// 不是今天、也没有录音可对照:不用标题。
        case plain
        /// 「我主办的」筛出来的、本月别的日子里的。
        case mineOtherDays
        /// 搜索找到的、别的日子里的。
        case foundOtherDays
    }

    let kind: Kind
    let events: [FfiCityEvent]

    var id: Kind { kind }

    /// 这一组不在选中的那天,行首要写日期而不是钟点。
    var showsDates: Bool { kind == .mineOtherDays || kind == .foundOtherDays }
}

/// 被归的那场录音的起止,用来把重合的活动排到最前。
struct CityRecordingSpan: Equatable {
    let start: Date
    let duration: TimeInterval
}

enum CityCalendarLayout {
    /// 月历从周一排起,时区跟这台 Mac。
    static func mondayFirst(_ calendar: Calendar = .current) -> Calendar {
        var calendar = calendar
        calendar.firstWeekday = 2
        return calendar
    }

    static func startOfMonth(_ date: Date, calendar: Calendar) -> Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: date))
            ?? calendar.startOfDay(for: date)
    }

    static func month(_ month: Date, offsetBy months: Int, calendar: Calendar) -> Date {
        calendar.date(byAdding: .month, value: months, to: startOfMonth(month, calendar: calendar))
            ?? month
    }

    /// 六行七列,从这个月 1 号所在那一周的周一起。总是 42 格:翻月时表的高度
    /// 不跳。
    static func monthGrid(for month: Date, calendar: Calendar) -> [Date] {
        let first = startOfMonth(month, calendar: calendar)
        // weekday: 1 是周日 … 7 是周六。
        let weekday = calendar.component(.weekday, from: first)
        let leading = (weekday - 2 + 7) % 7
        return (0..<42).compactMap { cell in
            calendar.date(byAdding: .day, value: cell - leading, to: first)
        }
    }

    /// 「一 二 三 四 五 六 日」。
    static func weekdaySymbols(calendar: Calendar, locale: Locale = .current) -> [String] {
        var calendar = calendar
        calendar.locale = locale
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        guard symbols.count == 7 else { return symbols }
        return Array(symbols[1...]) + [symbols[0]]
    }

    /// 一场活动算在它开始的那一天。跨夜的不算两天,一整季的总场也不让每一天
    /// 都多出一场。
    static func day(of event: FfiCityEvent, calendar: Calendar) -> Date {
        calendar.startOfDay(for: CityText.date(ms: event.startMs))
    }

    static func countsByDay(_ events: [FfiCityEvent], calendar: Calendar) -> [Date: Int] {
        events.reduce(into: [:]) { counts, event in
            counts[day(of: event, calendar: calendar), default: 0] += 1
        }
    }

    /// 每天底下的短条:活动越多越长,最多的日子也不撑出格子。
    static func barWidth(count: Int) -> CGFloat {
        count <= 0 ? 0 : min(CGFloat(3 + count * 2), 24)
    }

    /// 搜索活动名和场地;「我主办的」只留登录的人主办或做记录员的。
    static func filter(_ events: [FfiCityEvent], query: String, mineOnly: Bool) -> [FfiCityEvent] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return events.filter { event in
            if mineOnly, event.mine == false { return false }
            guard needle.isEmpty == false else { return true }
            return event.title.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                || event.place.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    static func events(on day: Date, from events: [FfiCityEvent], calendar: Calendar) -> [FfiCityEvent] {
        let day = calendar.startOfDay(for: day)
        return events
            .filter { self.day(of: $0, calendar: calendar) == day }
            .sorted { $0.startMs != $1.startMs ? $0.startMs < $1.startMs : $0.title < $1.title }
    }

    /// 选中那天的清单。今天按现在的时间分三组:正在进行、今天稍后、已结束;
    /// 别的日子不分。给了录音的起止,重合的先单列一组。
    static func groups(
        on day: Date,
        from events: [FfiCityEvent],
        now: Date,
        recording: CityRecordingSpan?,
        calendar: Calendar
    ) -> [CityEventGroup] {
        var remaining = self.events(on: day, from: events, calendar: calendar)
        var groups: [CityEventGroup] = []

        if let recording {
            let overlapping = CityEventMatching.overlapping(
                remaining,
                recordingStart: recording.start,
                duration: recording.duration
            )
            if overlapping.isEmpty == false {
                groups.append(CityEventGroup(kind: .overlapping, events: overlapping))
                let taken = Set(overlapping.map(\.id))
                remaining.removeAll { taken.contains($0.id) }
            }
        }

        guard calendar.isDate(day, inSameDayAs: now) else {
            if remaining.isEmpty == false {
                groups.append(CityEventGroup(kind: groups.isEmpty ? .plain : .restOfDay, events: remaining))
            }
            return groups
        }

        let nowMs = Int64(now.timeIntervalSince1970 * 1_000)
        // 规则认定「正在进行」的在前(它顾到提早开录和拖堂),钟点上正开着、
        // 规则没算进去的跟在后面:清单要如实,不能把开着的活动说成没开。
        let judged = CityEventMatching.runningNow(remaining, now: now)
        let judgedIds = Set(judged.map(\.id))
        let byClock = remaining.filter {
            judgedIds.contains($0.id) == false && $0.startMs <= nowMs && nowMs < $0.endMs
        }
        let running = judged + byClock
        let runningIds = Set(running.map(\.id))
        let later = remaining.filter { runningIds.contains($0.id) == false && $0.startMs > nowMs }
        // 刚结束的在前:补归的多半是刚散场的那一场。
        let ended = remaining
            .filter { runningIds.contains($0.id) == false && $0.startMs <= nowMs }
            .sorted { $0.endMs > $1.endMs }

        if running.isEmpty == false { groups.append(CityEventGroup(kind: .running, events: running)) }
        if later.isEmpty == false { groups.append(CityEventGroup(kind: .laterToday, events: later)) }
        if ended.isEmpty == false { groups.append(CityEventGroup(kind: .endedToday, events: ended)) }
        return groups
    }

    /// 筛过以后,别的日子里还有哪些:只看「我主办的」时是这个月的,搜索时是
    /// 读到的全部。没在筛就不列,那是日历的事。
    static func otherDays(
        than day: Date,
        from filtered: [FfiCityEvent],
        month: Date,
        searching: Bool,
        mineOnly: Bool,
        calendar: Calendar
    ) -> CityEventGroup? {
        guard searching || mineOnly else { return nil }
        let day = calendar.startOfDay(for: day)
        let monthStart = startOfMonth(month, calendar: calendar)
        let events = filtered
            .filter { event in
                let eventDay = self.day(of: event, calendar: calendar)
                guard eventDay != day else { return false }
                return searching || startOfMonth(eventDay, calendar: calendar) == monthStart
            }
            .sorted { $0.startMs < $1.startMs }
        guard events.isEmpty == false else { return nil }
        return CityEventGroup(kind: searching ? .foundOtherDays : .mineOtherDays, events: events)
    }

    /// 这个月一共几场(按筛过的算)。
    static func count(inMonth month: Date, from events: [FfiCityEvent], calendar: Calendar) -> Int {
        let monthStart = startOfMonth(month, calendar: calendar)
        return events.filter {
            startOfMonth(day(of: $0, calendar: calendar), calendar: calendar) == monthStart
        }.count
    }

    /// 打开时先看哪一天:补归的看录音那天,其余看今天。
    static func initialDay(now: Date, recording: CityRecordingSpan?, calendar: Calendar) -> Date {
        calendar.startOfDay(for: recording?.start ?? now)
    }

    /// 打开时先选中哪一场:已经归过的照旧;补归时选重合最多的;其余不替人选。
    static func initialSelection(
        current: String?,
        events: [FfiCityEvent],
        recording: CityRecordingSpan?
    ) -> String? {
        if let current, events.contains(where: { $0.id == current }) { return current }
        guard let recording else { return nil }
        return CityEventMatching.overlapping(
            events,
            recordingStart: recording.start,
            duration: recording.duration
        ).first?.id
    }
}
