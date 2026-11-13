// CityEventListView.swift
// 「归到哪场活动」右边的清单:选中那天的活动,按组排好,点一场就选中。
//
// 分组在 `CityCalendarLayout` 里算好;这里只画每一组的标题和每一场的一行:
// 钟点、活动名、场地,以及「你主办」「仅居民」「已交」这几个小标签。

import SwiftUI

struct CityEventListView: View {
    /// 「11月13日 周五 · 今天」。
    let dayTitle: String
    /// 「8 场」「8 场，都已结束」。
    let daySummary: String
    let groups: [CityEventGroup]
    /// 这一天一场都没有时说的话。
    let emptyText: String?
    let now: Date
    /// 已经交过文字稿的活动:标出来,主办一眼看得出哪几场交过了。
    let filedEventIds: Set<String>
    let calendar: Calendar
    @Binding var selection: String?

    /// 十二小时制的钟点(「11:00 AM–1:00 PM」)比二十四小时制长一截。
    private var timeColumnWidth: CGFloat {
        let pattern = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? ""
        return pattern.contains("a") ? 128 : 86
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.xsm) {
                    Text(dayTitle)
                        .font(.sans13Semibold)
                        .foregroundColor(.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: Spacing.sm)
                    Text(daySummary)
                        .font(.sans11)
                        .foregroundColor(.textTertiary)
                }
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, 2)

                if let emptyText {
                    Text(emptyText)
                        .font(.sans12)
                        .foregroundColor(.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, Spacing.sm)
                        .padding(.vertical, Spacing.sm)
                        .accessibilityIdentifier(AccessibilityID.cityPickerEmpty)
                }

                ForEach(groups) { group in
                    if let title = Self.title(group.kind) {
                        Text(title)
                            .captionXsLabel()
                            .foregroundColor(.textTertiary)
                            .padding(.horizontal, Spacing.sm)
                            .padding(.top, Spacing.sm + 1)
                            .padding(.bottom, 3)
                            .accessibilityAddTraits(.isHeader)
                    }
                    ForEach(group.events, id: \.id) { event in
                        row(event, showsDate: group.showsDates)
                    }
                }
            }
            .padding(.horizontal, Spacing.xsm + 2)
            .padding(.vertical, Spacing.xsm)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier(AccessibilityID.cityPickerList)
    }

    private func row(_ event: FfiCityEvent, showsDate: Bool) -> some View {
        let isSelected = selection == event.id
        let ended = event.endMs <= Int64(now.timeIntervalSince1970 * 1_000)
        let time = CityText.timeRange(startMs: event.startMs, endMs: event.endMs, calendar: calendar)
        let leading = showsDate
            ? CityText.day(CityText.date(ms: event.startMs), calendar: calendar)
            : time
        let detail = showsDate
            ? (event.place.isEmpty ? time : time + " · " + event.place)
            : event.place
        let tags = self.tags(event)
        return Button {
            selection = event.id
        } label: {
            HStack(alignment: .top, spacing: Spacing.sm + 2) {
                Text(leading)
                    .font(.monoNum11)
                    .foregroundColor(.textSecondary)
                    .lineLimit(1)
                    .frame(width: timeColumnWidth, alignment: .leading)
                VStack(alignment: .leading, spacing: 1) {
                    Text(event.title)
                        .font(.sans12)
                        // 结束了的淡一点;「已结束」那一组的标题已经把话说了。
                        .foregroundColor(ended ? .textSecondary : .textPrimary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if detail.isEmpty == false {
                        Text(detail)
                            .font(.sans11)
                            .foregroundColor(.textTertiary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: Spacing.sm)
                ForEach(tags, id: \.text) { tag in
                    Text(tag.text)
                        .font(.sans11)
                        .foregroundColor(tag.emphasized ? .brandAccent : .textSecondary)
                        .lineLimit(1)
                        .padding(.horizontal, Spacing.sm - 1)
                        .padding(.vertical, 1)
                        .background(tag.emphasized ? Color.brandAccentSoft : Color.clear)
                        .overlay(
                            Capsule().strokeBorder(
                                tag.emphasized ? Color.clear : Color.borderSubtle,
                                lineWidth: Stroke.thin
                            )
                        )
                        .clipShape(Capsule())
                        .fixedSize()
                }
                Image(systemName: "checkmark")
                    .iconSizeSmall()
                    .foregroundColor(.brandAccent)
                    .opacity(isSelected ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.brandAccentSoft : Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: Radius.sm)
                    .strokeBorder(Color.brandAccent, lineWidth: Stroke.thin)
                    .opacity(isSelected ? 1 : 0)
            )
            .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(
            ([event.title, leading, detail] + tags.map(\.text))
                .filter { $0.isEmpty == false }
                .joined(separator: ", ")
        ))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(AccessibilityID.cityPickerEvent(id: event.id))
    }

    private struct Tag {
        let text: String
        /// 「你主办」是这张表里唯一和登录的人有关的标签,所以用强调色。
        let emphasized: Bool
    }

    private func tags(_ event: FfiCityEvent) -> [Tag] {
        var tags: [Tag] = []
        if event.mine {
            tags.append(Tag(text: String(localized: "city.picker.tag_mine"), emphasized: true))
        }
        if event.residentsOnly {
            tags.append(Tag(text: String(localized: "city.picker.tag_residents"), emphasized: false))
        }
        if filedEventIds.contains(event.id) {
            tags.append(Tag(text: String(localized: "city.picker.tag_filed"), emphasized: false))
        }
        return tags
    }

    static func title(_ kind: CityEventGroup.Kind) -> String? {
        switch kind {
        case .overlapping: return String(localized: "city.picker.group.overlapping")
        case .running: return String(localized: "city.picker.group.running")
        case .laterToday: return String(localized: "city.picker.group.later")
        case .endedToday: return String(localized: "city.picker.group.ended")
        case .restOfDay: return String(localized: "city.picker.group.rest")
        case .plain: return nil
        case .mineOtherDays: return String(localized: "city.picker.group.mine_other_days")
        case .foundOtherDays: return String(localized: "city.picker.group.other_days")
        }
    }
}
