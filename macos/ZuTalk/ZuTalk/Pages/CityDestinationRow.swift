// CityDestinationRow.swift
// 这场录音归到哪场活动:每场录音的那一次确认。
//
// 归到哪场活动、以谁的名义、会交什么、带不带音频,按下开始之前都要看得到。
// 没有「记住以后自动发」的全局开关。在主持活动的人每次开始之前都看得到它;
// 不主持的人看不到它,也就什么都不会交(`StartCardHosting`)。
//
//   - 只有一场活动在进行:替人选好,主办直接按开始;
//   - 同时有好几场:不替人选,让人挑;
//   - 一场都没有:这场先不交,录完可以再归。
//
// 三种情况下开始按钮都能按 —— 它从不挡录音。没登录时不出现。
//
// 样子只有一个:`CityDestinationPill`,首页开始卡片上的一颗胶囊,写着活动的
// 名字,点开是菜单 —— 正在进行的活动、日历、「不交」,最后一项「不交音频」
// 管的是这一场带不带音频(交上去的音频是公开的,删不掉,所以默认带、可以
// 单场不带)。以谁的名义、交哪几种语言、连不连音频,在它的悬停提示和旁边的
// ⓘ 里。0.8.2 以前占一整行、把那一整句铺在页面上的样子不再有。

import Combine
import SwiftUI

// MARK: - 药丸

/// What the event pill says.
nonisolated enum CityDestinationPillLabel: Equatable, Sendable {
    /// Filed under this event.
    case event(String)
    /// The person said this recording is not to be filed.
    case notFiling
    /// Nothing is chosen and nothing was chosen for them: the pill offers to.
    case choose

    static func resolve(chosenTitle: String?, explicitlyNotFiling: Bool) -> CityDestinationPillLabel {
        if let title = chosenTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           title.isEmpty == false {
            return .event(title)
        }
        return explicitlyNotFiling ? .notFiling : .choose
    }

    /// The key of the words on the pill; nil when it shows an event's title.
    var labelKey: String? {
        switch self {
        case .event: return nil
        case .notFiling: return "home.card.dont_file"
        case .choose: return "home.card.choose_event"
        }
    }

    var title: String {
        if case .event(let title) = self { return title }
        return String(localized: String.LocalizationValue(labelKey ?? "home.card.choose_event"))
    }
}

/// Whether the next recording goes without its audio, and whether that is
/// the person's to choose right now.
nonisolated struct CityDestinationAudioChoice: Equatable, Sendable {
    /// Ticked: this recording is filed without audio.
    var withheld: Bool
    /// False when there is nothing to choose: no event, or the setting is
    /// off (a recording cannot be switched on by itself).
    var canChange: Bool

    /// - Parameters:
    ///   - settingOn: "Audio" in Settings › Account › Archive.
    ///   - withheld: The person ticked "No audio" for the next recording.
    ///   - filing: An event is chosen, so something will be filed.
    static func resolve(settingOn: Bool, withheld: Bool, filing: Bool) -> CityDestinationAudioChoice {
        CityDestinationAudioChoice(
            // With the setting off no audio goes whatever is ticked: say so.
            withheld: settingOn == false || withheld,
            canChange: settingOn && filing
        )
    }

    /// Whether the audio will be filed with this recording.
    var filesAudio: Bool { withheld == false && canChange }
}

/// What the event pill's menu offers, top to bottom.
nonisolated enum CityDestinationMenuEntry: Equatable, Sendable {
    case event(id: String, title: String, isChosen: Bool)
    case separator
    case pickFromCalendar
    case notFiling(isChosen: Bool)
    /// "No audio": this recording is filed without its audio.
    case withholdAudio(isChosen: Bool, isEnabled: Bool)

    /// The events running now, the chosen one among them or ahead of them
    /// when it is not running (picked from the calendar earlier), then the
    /// calendar and "don't file"; and, when `audio` is given, "No audio"
    /// below a line of its own.
    static func entries(
        running: [(id: String, title: String)],
        chosen: (id: String, title: String)?,
        explicitlyNotFiling: Bool,
        audio: CityDestinationAudioChoice?
    ) -> [CityDestinationMenuEntry] {
        var entries = entries(running: running, chosen: chosen, explicitlyNotFiling: explicitlyNotFiling)
        if let audio {
            entries.append(.separator)
            entries.append(.withholdAudio(isChosen: audio.withheld, isEnabled: audio.canChange))
        }
        return entries
    }

    /// The same list without the audio item.
    static func entries(
        running: [(id: String, title: String)],
        chosen: (id: String, title: String)?,
        explicitlyNotFiling: Bool
    ) -> [CityDestinationMenuEntry] {
        var entries: [CityDestinationMenuEntry] = []
        if let chosen, running.contains(where: { $0.id == chosen.id }) == false {
            entries.append(.event(id: chosen.id, title: chosen.title, isChosen: true))
        }
        for event in running {
            entries.append(.event(id: event.id, title: event.title, isChosen: event.id == chosen?.id))
        }
        if entries.isEmpty == false {
            entries.append(.separator)
        }
        entries.append(.pickFromCalendar)
        entries.append(.notFiling(isChosen: explicitlyNotFiling))
        return entries
    }
}

/// The start card's event pill: the confirmation of where this recording
/// goes, in the space of one word. Whose name it is filed under, which
/// languages, and that its audio goes too and cannot be taken back, are its
/// tooltip and the ⓘ beside it.
struct CityDestinationPill: View {
    /// 卡片上选的语言:提示里要把这场录音的语言一个个念出来。
    let languages: [String]
    /// 放进哪个主题;不放时为 nil,也就没有频道。
    let topicId: String?

    @ObservedObject private var city = CityStore.shared
    @ObservedObject private var commands = CaptureCommandCenter.shared
    @State private var showsPicker = false
    /// 这一颗是按哪个时刻算的。活动会开场、散场:每分钟重算一次,页面开着
    /// 不动也不会过时。
    @State private var now = Date()

    private let everyMinute = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        if let account = city.account {
            let event = city.nextEvent(now: now)
            let label = CityDestinationPillLabel.resolve(
                chosenTitle: event?.title,
                explicitlyNotFiling: city.nextChoice == .notFiling
            )
            let explanation = explanation(account: account, event: event)
            HStack(spacing: 2) {
                MenuPill(
                    label.title,
                    titleIsName: label.labelKey == nil,
                    systemImage: "archivebox",
                    help: explanation,
                    accessibilityLabel: String(localized: "city.record.title")
                ) {
                    menu(chosen: event)
                }
                .accessibilityIdentifier(AccessibilityID.cityRecordEvent)

                // What will be filed, where and in whose name cannot be taken
                // back once it is: it is one click away, not only a tooltip.
                if event != nil {
                    InfoButton(explanation, accessibilityLabel: String(localized: "city.record.title"))
                        .accessibilityIdentifier(AccessibilityID.cityRecordSummary)
                }
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

    private var running: [FfiCityEvent] {
        CityEventMatching.runningNow(city.calendar.events, now: now)
    }

    private func menu(chosen: FfiCityEvent?) -> [PillMenuItem] {
        let running = running
        let audio = audioChoice(filing: chosen != nil)
        let entries = CityDestinationMenuEntry.entries(
            running: running.map { ($0.id, $0.title) },
            chosen: chosen.map { ($0.id, $0.title) },
            explicitlyNotFiling: city.nextChoice == .notFiling,
            audio: audio
        )
        return entries.map { entry in
            switch entry {
            case .event(let id, let title, let isChosen):
                return PillMenuItem(title, isOn: isChosen) {
                    if let event = running.first(where: { $0.id == id }) ?? chosen {
                        city.chooseNext(.event(event))
                    }
                }
            case .separator:
                return .separator
            case .pickFromCalendar:
                return PillMenuItem(String(localized: "city.action.pick_from_calendar")) {
                    // The menu is still closing; the sheet waits a turn.
                    DispatchQueue.main.async { showsPicker = true }
                }
            case .notFiling(let isChosen):
                return PillMenuItem(String(localized: "home.card.dont_file"), isOn: isChosen) {
                    city.chooseNext(.notFiling)
                }
            case .withholdAudio(let isChosen, let isEnabled):
                return PillMenuItem(
                    String(localized: "city.audio.off"),
                    isOn: isChosen,
                    isEnabled: isEnabled
                ) {
                    city.setNextWithholdsAudio(city.nextWithholdsAudio == false)
                }
            }
        }
    }

    private func audioChoice(filing: Bool) -> CityDestinationAudioChoice {
        .resolve(
            settingOn: city.options.audio,
            withheld: city.nextWithholdsAudio,
            filing: filing
        )
    }

    /// Why the pill says what it says, and — for a chosen event — everything
    /// that has to be readable before pressing Start: when and where, which
    /// archive, in whose name, which languages, and, when this recording
    /// carries its audio, that it does and that what is filed stays public.
    private func explanation(account: FfiCityAccount, event: FfiCityEvent?) -> String {
        guard let event else {
            if city.nextChoice == .notFiling {
                return String(localized: "city.record.none_chosen_detail")
            }
            let runningCount = running.count
            return runningCount > 1
                ? String(
                    format: String(localized: "city.record.several_format"),
                    Int64(runningCount)
                )
                : String(localized: "city.record.none_running_detail")
        }
        return [
            event.title + " · " + CityText.whenAndWhere(event, now: now),
            String(
                format: String(localized: "city.record.detail_format"),
                account.cityName.isEmpty ? account.server : account.cityName
            ),
            CityText.summary(
                signer: account.personName,
                languages: languages,
                options: city.options,
                channel: topicId.flatMap { city.topicChannels[$0]?.title },
                audio: audioChoice(filing: true).filesAudio
            ),
        ].joined(separator: "\n")
    }
}
