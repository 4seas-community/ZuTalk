// CityMonthCalendarView.swift
// 「归到哪场活动」左边的月历:周一排头,今天有一圈,选中的那天填实,每天
// 底下一根短条 —— 那天活动越多,条越长。
//
// 它只画和报告点了哪天、翻了哪个月;哪天几场由外面算好给它。

import SwiftUI

struct CityMonthCalendarView: View {
    /// 正在看的那个月(其中任意一刻)。
    let month: Date
    let selectedDay: Date
    let today: Date
    /// 每天几场,键是那天零点。
    let counts: [Date: Int]
    /// 月历底下的一行:「本月 124 场 · 今天 8 场」。
    let footnote: String
    let calendar: Calendar
    let onSelect: (Date) -> Void
    /// 翻月:-1 上个月,+1 下个月。
    let onPage: (Int) -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm + 2) {
            HStack(spacing: Spacing.xs) {
                Text(CityText.formatted(month, template: "yMMMM", calendar: calendar, locale: .current))
                    .font(.sans13Semibold)
                    .foregroundColor(.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                pageButton(
                    systemImage: "chevron.left",
                    label: String(localized: "city.picker.previous_month"),
                    identifier: AccessibilityID.cityPickerPreviousMonth,
                    months: -1
                )
                pageButton(
                    systemImage: "chevron.right",
                    label: String(localized: "city.picker.next_month"),
                    identifier: AccessibilityID.cityPickerNextMonth,
                    months: 1
                )
            }
            .padding(.horizontal, Spacing.xs)

            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(
                    Array(CityCalendarLayout.weekdaySymbols(calendar: calendar).enumerated()),
                    id: \.offset
                ) { _, symbol in
                    Text(symbol)
                        .font(.mono9)
                        .foregroundColor(.textTertiary)
                        .frame(maxWidth: .infinity)
                        .accessibilityHidden(true)
                }
                ForEach(CityCalendarLayout.monthGrid(for: month, calendar: calendar), id: \.self) { date in
                    dayCell(date)
                }
            }

            Text(footnote)
                .font(.sans11)
                .foregroundColor(.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Spacing.xs)

            Spacer(minLength: 0)
        }
        .padding(Spacing.xsm + 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.cityPickerCalendar)
    }

    private func pageButton(
        systemImage: String,
        label: String,
        identifier: String,
        months: Int
    ) -> some View {
        Button {
            onPage(months)
        } label: {
            Image(systemName: systemImage)
                .iconSizeSmall()
                .foregroundColor(.textSecondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(Text(label))
        .accessibilityIdentifier(identifier)
    }

    private func dayCell(_ date: Date) -> some View {
        let inMonth = calendar.isDate(date, equalTo: month, toGranularity: .month)
        let isToday = calendar.isDate(date, inSameDayAs: today)
        let isSelected = calendar.isDate(date, inSameDayAs: selectedDay)
        let count = counts[calendar.startOfDay(for: date)] ?? 0
        return Button {
            onSelect(date)
        } label: {
            VStack(spacing: 3) {
                Text(String(calendar.component(.day, from: date)))
                    .font(isSelected ? Font.sans12Semibold.monospacedDigit() : Font.monoNum12)
                    .foregroundColor(isSelected ? .brandAccentForeground : inMonth ? .textPrimary : .textDim)
                // 没有活动的日子也留着这一条的位置,数字才不会上下错开。
                Capsule()
                    .fill(isSelected ? Color.brandAccentForeground : Color.brandAccent.opacity(0.7))
                    .frame(width: CityCalendarLayout.barWidth(count: count), height: 3)
            }
            .frame(maxWidth: .infinity, minHeight: 38)
            .background(isSelected ? Color.brandAccent : Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: Radius.sm)
                    .strokeBorder(Color.brandAccent, lineWidth: Stroke.medium)
                    .opacity(isToday ? 1 : 0)
            )
            .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(accessibilityLabel(date, count: count, isToday: isToday)))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(AccessibilityID.cityPickerDay(Self.key(date, calendar: calendar)))
    }

    /// 颜色和圈之外,把同一件事念出来:哪一天、几场、是不是今天。
    private func accessibilityLabel(_ date: Date, count: Int, isToday: Bool) -> String {
        var parts = [CityText.formatted(date, template: "MMMdEEEE", calendar: calendar, locale: .current)]
        if isToday { parts.append(String(localized: "city.picker.today")) }
        parts.append(String(format: String(localized: "city.picker.count_format"), Int64(count)))
        return parts.joined(separator: ", ")
    }

    /// `2026-11-13`:给界面测试用的稳定标识,不跟语言走。
    static func key(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
