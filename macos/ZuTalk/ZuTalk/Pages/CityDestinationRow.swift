// CityDestinationRow.swift
// 「开始录音」页上「归到活动」那一行,紧跟在「归入主题」下面。
//
// 这一行就是每场录音的那一次确认:归到哪场活动、以谁的名义、会交什么、音频
// 不交,按下开始之前都摆在眼前。没有「记住以后自动发」的全局开关。
//
//   - 只有一场活动在进行:替人选好,主办直接按开始;
//   - 同时有好几场:不替人选,列出来让人挑;
//   - 一场都没有:这场先不交,录完可以再归。
//
// 三种情况下开始按钮都能按 —— 这一行从不挡录音。没登录时整行不出现,页面
// 和原来一样。

import Combine
import SwiftUI

struct CityDestinationRow: View {
    /// 这一页正在编辑的语言设置:那一句里要把这场录音的语言一个个念出来。
    let editor: NotebookCaptureProfileEditorModel?
    /// 录进哪个主题;未归入主题时为 nil,也就没有频道。
    let topicId: String?

    @ObservedObject private var city = CityStore.shared
    @ObservedObject private var commands = CaptureCommandCenter.shared
    @State private var showsPicker = false
    /// 这一行是按哪个时刻算的。活动会开场、散场:每分钟重算一次,页面开着
    /// 不动也不会过时。
    @State private var now = Date()

    private let everyMinute = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        if let account = city.account {
            VStack(alignment: .leading, spacing: 0) {
                content(account: account, now: now)
                // 和页面上别的行之间一样的分隔线;跟着这一行一起出现、一起消失。
                Divider().padding(.horizontal, Spacing.md)
            }
            .onAppear {
                city.prepareNextRecording()
                if let topicId { city.loadTopicChannel(notebookId: topicId) }
                showAsOfNow()
            }
            .onReceive(everyMinute) { _ in showAsOfNow() }
            .montereyOnChange(of: topicId) { _, topicId in
                if let topicId { city.loadTopicChannel(notebookId: topicId) }
            }
            .montereyOnChange(of: commands.isStarting) { _, isStarting in
                // 开始没成(成了的话去向已经绑上):那次确认作废。
                if isStarting == false { city.cancelConfirmedDestination() }
            }
            .sheet(isPresented: $showsPicker) {
                CityEventPickerSheet(
                    selectedEventId: city.nextEvent(now: now)?.id,
                    recording: nil
                ) { event in
                    city.chooseNext(event.map { .event($0) } ?? .notFiling)
                }
            }
        }
    }

    /// 把「按哪个时刻算的」也告诉 store:按下开始时确认的,必须正是这里显示的
    /// 那一场。
    private func showAsOfNow() {
        now = Date()
        city.noteNextDestinationShown(at: now)
    }

    @ViewBuilder
    private func content(account: FfiCityAccount, now: Date) -> some View {
        let running = city.nextChoice == .automatic
            ? CityEventMatching.runningNow(city.calendar.events, now: now)
            : []
        VStack(alignment: .leading, spacing: 0) {
            if let event = city.nextEvent(now: now) {
                chosen(event, account: account, now: now)
            } else if running.count > 1 {
                several(running)
            } else {
                notFiling(explicit: city.nextChoice == .notFiling)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.cityRecordRow)
    }

    // MARK: 选好了一场

    private func chosen(_ event: FfiCityEvent, account: FfiCityAccount, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: Spacing.md) {
                rowTitle(detail: String(
                    format: String(localized: "city.record.detail_format"),
                    account.cityName.isEmpty ? account.server : account.cityName
                ))
                Spacer(minLength: Spacing.md)
                Button {
                    showsPicker = true
                } label: {
                    HStack(spacing: Spacing.sm) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(event.title)
                                .font(.bodyMedium)
                                .foregroundColor(.textPrimary)
                                .lineLimit(1)
                            Text(CityText.whenAndWhere(event, now: now))
                                .font(.sans11)
                                .foregroundColor(.textTertiary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.up.chevron.down")
                            .iconSizeSmall()
                            .foregroundColor(.textTertiary)
                            .accessibilityHidden(true)
                    }
                    .padding(.leading, Spacing.xsm)
                    .padding(.trailing, Spacing.sm)
                    .padding(.vertical, Spacing.sm)
                    .frame(maxWidth: 280, alignment: .leading)
                    .surfaceCard(
                        fill: Color.bgRoot,
                        cornerRadius: Radius.sm,
                        border: Color.borderSubtle,
                        borderWidth: Stroke.thin
                    )
                    .contentShape(RoundedRectangle(cornerRadius: Radius.sm))
                }
                .buttonStyle(.plain)
                .help(String(localized: "city.record.change_hint"))
                .accessibilityLabel(Text(event.title + ", " + CityText.whenAndWhere(event, now: now)))
                .accessibilityHint(Text(String(localized: "city.record.change_hint")))
                .accessibilityIdentifier(AccessibilityID.cityRecordEvent)
            }
            .padding(Spacing.md)

            Group {
                let channel = topicId.flatMap { city.topicChannels[$0]?.title }
                if let editor {
                    CityRecordSummary(editor: editor, signer: account.personName, channel: channel)
                } else {
                    CityRecordSummaryBox(text: CityText.summary(
                        signer: account.personName,
                        languages: [],
                        options: city.options,
                        channel: channel
                    ))
                }
            }
            .padding(.horizontal, Spacing.md)
            .padding(.bottom, Spacing.md)
        }
    }

    // MARK: 同时有好几场

    private func several(_ running: [FfiCityEvent]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: Spacing.md) {
                rowTitle(detail: String(
                    format: String(localized: "city.record.several_format"),
                    Int64(running.count)
                ))
                Spacer(minLength: Spacing.md)
                pickButton
            }
            .padding(Spacing.md)

            VStack(spacing: Spacing.sm) {
                ForEach(running, id: \.id) { event in
                    Button {
                        city.chooseNext(.event(event))
                    } label: {
                        HStack(alignment: .top, spacing: Spacing.sm) {
                            Image(systemName: "circle")
                                .iconSizeMedium()
                                .foregroundColor(.textTertiary)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(event.title)
                                    .font(.bodySM)
                                    .foregroundColor(.textPrimary)
                                    .multilineTextAlignment(.leading)
                                Text(Self.timeAndPlace(event))
                                    .font(.sans11)
                                    .foregroundColor(.textTertiary)
                                    .multilineTextAlignment(.leading)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, Spacing.xsm)
                        .padding(.vertical, Spacing.sm)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .surfaceCard(
                            fill: Color.bgRoot,
                            cornerRadius: Radius.sm,
                            border: Color.borderSubtle,
                            borderWidth: Stroke.thin
                        )
                        .contentShape(RoundedRectangle(cornerRadius: Radius.sm))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(event.title + ", " + Self.timeAndPlace(event)))
                    .accessibilityIdentifier(AccessibilityID.cityRecordChoice(eventId: event.id))
                }
            }
            .padding(.horizontal, Spacing.md)
            .padding(.bottom, Spacing.md)
        }
    }

    // MARK: 不交

    private func notFiling(explicit: Bool) -> some View {
        HStack(alignment: .center, spacing: Spacing.md) {
            rowTitle(detail: String(localized: explicit
                ? "city.record.none_chosen_detail"
                : "city.record.none_running_detail"))
            Spacer(minLength: Spacing.md)
            Text(String(localized: "city.action.not_filing"))
                .font(.bodySM)
                .foregroundColor(.textTertiary)
            pickButton
        }
        .padding(Spacing.md)
    }

    // MARK: 零件

    private var pickButton: some View {
        Button(String(localized: "city.action.pick_from_calendar")) {
            showsPicker = true
        }
        .accessibilityIdentifier(AccessibilityID.cityRecordPick)
    }

    /// 和页面上别的行同一个样子:标题一行,说明一行。
    private func rowTitle(detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(localized: "city.record.title"))
                .font(.bodyMedium)
                .foregroundColor(.textPrimary)
            Text(detail)
                .font(.bodySM)
                .foregroundColor(.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private static func timeAndPlace(_ event: FfiCityEvent) -> String {
        let time = CityText.timeRange(startMs: event.startMs, endMs: event.endMs)
        return event.place.isEmpty ? time : time + " · " + event.place
    }
}

/// 那一整句:以谁的名义、哪几种语言、带不带说话人和标记、放不放进频道、音频
/// 不交。语言就在同一页上改,改了这一句要跟着变,所以它自己盯着语言设置。
private struct CityRecordSummary: View {
    @ObservedObject var editor: NotebookCaptureProfileEditorModel
    let signer: String
    let channel: String?
    @ObservedObject private var city = CityStore.shared

    var body: some View {
        CityRecordSummaryBox(text: CityText.summary(
            signer: signer,
            languages: editor.draft.selectedLanguages,
            options: city.options,
            channel: channel
        ))
    }
}

private struct CityRecordSummaryBox: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Image(systemName: "archivebox")
                .iconSizeSmall()
                .foregroundColor(.brandAccent)
                .accessibilityHidden(true)
            Text(text)
                .font(.bodySM)
                .foregroundColor(.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Spacing.xsm)
        .padding(.vertical, Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard(fill: Color.brandAccentSoft, cornerRadius: Radius.sm)
        .accessibilityIdentifier(AccessibilityID.cityRecordSummary)
    }
}
