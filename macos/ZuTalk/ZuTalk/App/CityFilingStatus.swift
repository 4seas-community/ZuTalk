// CityFilingStatus.swift
// 一场录音交到档案馆这件事,此刻停在哪一步 —— 全 App 只有这一套说法。
//
// 0.8.0 里各处各说各的:录完的那条提示、共享面板里的那一段、设置里的那张表,
// 三处各自拿 `state` 和 `errorCode` 拼话;录音自己的页面和列表上什么都不说,
// 主窗口也看不出还有没有排着队的。人要回答「这场录音到城里了吗,没到的话
// 我该做什么」,得自己去翻。
//
// 现在录音页顶栏、录音列表、共享面板、设置里的表、侧栏底部都从这里取:
// 同一个状态,同一个词,同一个图标,同一种颜色,同一个「下一步」。
//
// 几条定下来的:
//   - 状态是图标加一个词(「已交」「排队」「没交上」);要多说的那一句在
//     `hint` 和 `reason` 里,给悬停提示、旁白和点开以后看;
//   - 文字和音频各算各的。音频没交成不改文字这一路的状态:这场录音还是
//     「已交」,旁边再有一个词说音频(`CityAudioStatus`:「音频 3/24」
//     「音频已交」「音频没收」…);
//   - 「这台 Mac 没有联网」只在系统确实说没有网络时才说(`offline`,来自
//     `NetworkReachability`)。核心的 `city.error.offline` 只说明没连上城的
//     服务器 —— 去城的那条路自己就常断,机器本身在线 —— 不能据此说人断网;
//   - 更新、撤下进行中,东西还在档案馆里,照它在档案馆里的样子说;「正在交…」
//     只留给真的正在往上交的那一会儿;
//   - 颜色只给角色:绿是成了,金是要人看一眼,红只给没成。橙色留给录音。
// 都是纯函数,可以单独测。

import SwiftUI

struct CityFilingStatus: Equatable {
    enum Kind: Equatable {
        /// 没归过活动。
        case notFiled
        /// 选好了活动,还没交。
        case chosen
        /// 此刻正在交。
        case sending
        /// 没连上城的服务器,排着队等下一次。
        case waiting
        case filed
        /// 交上去以后在这台 Mac 上改过字,档案馆里还是旧的。
        case changed
        /// 交上去了,活动后来在城里被删掉或取消:档案馆里看不到这一件。
        case eventGone
        case failed
        case withdrawn
    }

    /// 颜色的角色,不是颜色本身;色值在 `color` 里从设计 token 取。
    enum Tone: Equatable {
        /// 不用人管。
        case quiet
        case success
        /// 要人看一眼。
        case warning
        case failure
    }

    /// 这个状态下最该做的那一件事。
    enum Action: Equatable {
        /// 选一场活动;已经有一场的,换一场。
        case chooseEvent
        case file
        case retry
        case update
        /// 在浏览器里打开档案馆里的那一件。
        case open(URL)
    }

    let kind: Kind
    /// 一个词:「已交」「排队」「没交上」。
    let label: String
    /// 这个词展开来的那一句(「排队中,稍后自动再试」),给悬停提示和旁白。
    let hint: String
    /// 要多说一句的时候:没交上的原因、活动被删以后会怎样、上次更新或撤下
    /// 没成的原因。都是人能照做的整句。
    let reason: String?
    /// SF Symbol。颜色不是唯一的信号:每种状态的图标和话都不一样。
    let symbol: String
    let tone: Tone
    /// 正在交、更新、撤下的那一会儿没有可做的事。
    let primaryAction: Action?
    /// 音频这一路。没归过活动的录音没有。
    let audio: CityAudioStatus?

    /// 一场录音此刻的状态。
    ///
    /// - Parameters:
    ///   - filing: 核心记的那一份;没归过活动就是 nil。
    ///   - busy: 这一场此刻有没有请求在路上(`CityStore.busySessions`)。
    ///   - offline: 系统是否确认这台 Mac 没有网络(`NetworkReachability.isOffline`)。
    ///   - signer: 登录的人的名字,「请主办把你加为记录员」那句要用。
    ///   - audioUploading: 这一场的音频此刻是不是正在一段段交。
    ///   - audioPlanned: 正在交的那一趟量出来一共几段(账上还没记的时候用)。
    ///   - audioMissing: 这台 Mac 上已经没有这场录音的音频。
    ///   - audioUnreadable: 这场录音的音频在这台 Mac 上没能导出来。
    static func resolve(
        _ filing: FfiCityFiling?,
        busy: Bool,
        offline: Bool,
        signer: String? = nil,
        audioUploading: Bool = false,
        audioPlanned: UInt32? = nil,
        audioMissing: Bool = false,
        audioUnreadable: Bool = false,
        now: Date = Date()
    ) -> CityFilingStatus {
        let kind = kind(filing, busy: busy)
        return CityFilingStatus(
            kind: kind,
            label: label(kind, filing: filing, offline: offline),
            hint: hint(kind, filing: filing, offline: offline),
            reason: reason(kind, filing: filing, signer: signer),
            symbol: symbol(kind, offline: offline),
            tone: tone(kind),
            primaryAction: busy ? nil : action(kind, filing: filing, offline: offline),
            audio: filing.map {
                CityAudioStatus.resolve(
                    $0,
                    uploading: audioUploading,
                    planned: audioPlanned,
                    missing: audioMissing,
                    unreadable: audioUnreadable,
                    busy: busy,
                    signer: signer,
                    now: now
                )
            }
        )
    }

    static func kind(_ filing: FfiCityFiling?, busy: Bool) -> Kind {
        guard let filing else { return busy ? .sending : .notFiled }
        switch filing.state {
        case .filed:
            // 更新或撤下在路上:东西还在档案馆,不说「正在交」。
            if filing.errorCode == CityText.eventGoneCode { return .eventGone }
            return filing.changedSentences > 0 ? .changed : .filed
        case .bound:
            return busy ? .sending : .chosen
        case .queued:
            return busy ? .sending : .waiting
        case .failed:
            return busy ? .sending : .failed
        case .withdrawn:
            return busy ? .sending : .withdrawn
        }
    }

    private static func label(_ kind: Kind, filing: FfiCityFiling?, offline: Bool) -> String {
        switch kind {
        case .notFiled: return String(localized: "city.status.not_filed")
        case .chosen: return String(localized: "city.word.chosen")
        case .sending: return String(localized: "city.status.sending")
        case .waiting:
            return String(localized: offline ? "city.word.waiting_offline" : "city.word.waiting")
        case .filed: return String(localized: "city.word.filed")
        case .changed:
            return String(
                format: String(localized: "city.status.changed_format"),
                Int64(filing?.changedSentences ?? 0)
            )
        case .eventGone: return String(localized: "city.word.event_gone")
        case .failed: return String(localized: "city.status.failed")
        case .withdrawn: return String(localized: "city.status.withdrawn")
        }
    }

    /// 那个词原来写在界面上的整句。句子没有删,换了地方。
    private static func hint(_ kind: Kind, filing: FfiCityFiling?, offline: Bool) -> String {
        switch kind {
        case .chosen: return String(localized: "city.status.chosen")
        case .waiting:
            return String(localized: offline ? "city.status.waiting_offline" : "city.status.waiting")
        case .filed: return String(localized: "city.status.filed")
        case .eventGone: return String(localized: "city.status.event_gone")
        case .notFiled, .sending, .changed, .failed, .withdrawn:
            return label(kind, filing: filing, offline: offline)
        }
    }

    private static func reason(_ kind: Kind, filing: FfiCityFiling?, signer: String?) -> String? {
        switch kind {
        case .failed:
            return CityText.message(forCode: filing?.errorCode, signer: signer)
        case .eventGone:
            return String(localized: "city.status.event_gone_detail")
        case .filed, .changed:
            // 更新或撤下没成时,核心把状态留在「已交」,原因写在 errorCode 里。
            guard let code = filing?.errorCode else { return nil }
            return String(
                format: String(localized: "city.status.last_problem_format"),
                CityText.message(forCode: code, signer: signer)
            )
        case .notFiled, .chosen, .sending, .waiting, .withdrawn:
            return nil
        }
    }

    private static func symbol(_ kind: Kind, offline: Bool) -> String {
        switch kind {
        case .notFiled: return "archivebox"
        case .chosen: return "calendar.badge.clock"
        case .sending: return "arrow.up.circle"
        case .waiting: return offline ? "wifi.slash" : "clock"
        case .filed: return "checkmark.circle"
        case .changed: return "pencil.circle"
        case .eventGone: return "calendar.badge.exclamationmark"
        case .failed: return "exclamationmark.triangle"
        case .withdrawn: return "arrow.uturn.backward.circle"
        }
    }

    private static func tone(_ kind: Kind) -> Tone {
        switch kind {
        case .notFiled, .chosen, .sending, .waiting, .withdrawn: return .quiet
        case .filed: return .success
        case .changed, .eventGone: return .warning
        case .failed: return .failure
        }
    }

    private static func action(_ kind: Kind, filing: FfiCityFiling?, offline: Bool) -> Action? {
        switch kind {
        case .notFiled, .eventGone:
            return .chooseEvent
        case .chosen, .withdrawn:
            return .file
        case .sending:
            return nil
        case .waiting:
            // 确实没有网络时现在重试也是白试;联网后会自己交。
            return offline ? nil : .retry
        case .filed:
            return CityText.webURL(filing?.webUrl).map { .open($0) }
        case .changed:
            return .update
        case .failed:
            // 活动没了、没归活动:再试多少次都一样,得先换一场。
            let needsEvent = filing?.errorCode == CityText.eventGoneCode
                || filing?.errorCode == "city.error.unbound"
            return needsEvent ? .chooseEvent : .retry
        }
    }

    /// 文字交上去以后,音频那个词才值得摆在旁边:「已交 · 音频 3/24」。还没
    /// 交的时候带不带音频在共享面板和设置里看;撤下以后只说留在城里的那几段。
    var audioBeside: CityAudioStatus? {
        guard let audio else { return nil }
        switch kind {
        case .filed, .changed, .eventGone:
            return audio
        case .withdrawn:
            return audio.kind == .retained ? audio : nil
        case .notFiled, .chosen, .sending, .waiting, .failed:
            return nil
        }
    }

    /// 「档案馆:已交 · <活动名> · 音频 3/24」:悬停提示和旁白用的那一句。图标
    /// 和词离开了「档案馆」三个字,人看不出说的是哪件事。
    func described(event title: String?) -> String {
        var said = label
        if let title, title.isEmpty == false {
            said = String(format: String(localized: "city.status.for_event_format"), label, title)
        }
        if let audio = audioBeside {
            said += " · " + audio.label
        }
        return said
    }

    /// 悬停提示:那一句,加上每一处要多说的。
    func tooltip(event title: String?) -> String {
        var lines = [described(event: title)]
        if hint != label { lines.append(hint) }
        if let reason { lines.append(reason) }
        if let audio = audioBeside, let reason = audio.reason { lines.append(reason) }
        return lines.joined(separator: "\n")
    }
}

extension CityFilingStatus.Tone {
    /// 图标的颜色。字不跟着变色:红字、金字连成片就没有哪一个显眼了。
    var color: Color {
        switch self {
        case .quiet: return .textTertiary
        case .success: return .success
        case .warning: return .warning
        case .failure: return .error
        }
    }
}

// MARK: - 音频这一路

/// 一场归了活动的录音,音频交到哪了。和文字的状态并排:一个图标,一个词。
///
/// 交上去的音频是公开的,删不掉(docs/architecture/city-archive.md 第 7 节),
/// 所以这里的每个词都只说已经发生的、或者一定会发生的事。
struct CityAudioStatus: Equatable {
    enum Kind: Equatable {
        /// 这一场不交音频:设置里关着,或者这一场单独关了。
        case off
        /// 文字还没交;交的时候音频跟着交。
        case included
        /// 文字交了,音频没交过,也不会自己去交(这一版以前交的,或者交的
        /// 时候关着):等人按「补交音频」。
        case absent
        /// 该交,还没轮到,或者上一次没连上、等着再试。
        case queued
        /// 正在一段段交。
        case uploading
        case filed
        /// 城没收下。不再自己试。
        case refused
        /// 一段太大。
        case tooBig
        /// 今天往城里放得太多,到点再接着交。
        case capped
        /// 这台 Mac 上已经没有这场录音的音频:没有可交的。
        case missing
        /// 这台 Mac 上的音频没能导出来(读到的和记的格式对不上、编码没成):
        /// 没有东西发出去。
        case unreadable
        /// 交了几段就停了:后来关了开关,或者音频不在这台 Mac 上了。
        case partial
        /// 撤下了;已经交上去的那几段留在城里。
        case retained
    }

    enum Action: Equatable {
        /// 补交音频。
        case file
        /// 现在再试一次。
        case retry
    }

    let kind: Kind
    /// 一个词:「音频 3/24」「音频已交」「音频没收」。
    let label: String
    /// 要多说的那一句,给悬停提示和点开以后看。
    let reason: String?
    let symbol: String
    let tone: CityFilingStatus.Tone
    let action: Action?

    static func resolve(
        _ filing: FfiCityFiling,
        uploading: Bool = false,
        planned: UInt32? = nil,
        missing: Bool = false,
        unreadable: Bool = false,
        busy: Bool = false,
        signer: String? = nil,
        now: Date = Date()
    ) -> CityAudioStatus {
        let kind = kind(
            filing,
            uploading: uploading,
            planned: planned,
            missing: missing,
            unreadable: unreadable,
            now: now
        )
        let total = max(filing.audioPartsPlanned, planned ?? 0)
        return CityAudioStatus(
            kind: kind,
            label: label(kind, filed: filing.audioPartsFiled, total: total),
            reason: reason(kind, filing: filing, total: total, missing: missing, signer: signer),
            symbol: symbol(kind),
            tone: tone(kind),
            action: busy ? nil : action(kind, filing: filing)
        )
    }

    static func kind(
        _ filing: FfiCityFiling,
        uploading: Bool = false,
        planned: UInt32? = nil,
        missing: Bool = false,
        unreadable: Bool = false,
        now: Date = Date()
    ) -> Kind {
        let filed = filing.audioPartsFiled
        guard filing.state == .filed else {
            // 撤下以后,交上去的那几段还在城里。
            if filing.state == .withdrawn, filed > 0 { return .retained }
            return filing.audioWanted ? .included : .off
        }
        let total = max(filing.audioPartsPlanned, planned ?? 0)
        if total > 0, filed >= total { return .filed }
        if uploading { return .uploading }
        if missing { return filed > 0 ? .partial : .missing }
        guard filing.audioWanted else { return filed > 0 ? .partial : .off }
        if unreadable { return .unreadable }
        switch filing.audioErrorCode {
        case CityText.audioRefusedCode:
            return .refused
        case CityText.audioTooBigCode:
            return .tooBig
        case CityText.audioDailyCapCode:
            // 到了城说的时候,它回到「排队」,会自己接着交。
            if let retryAt = filing.audioRetryAtEpoch,
               TimeInterval(retryAt) > now.timeIntervalSince1970 {
                return .capped
            }
        default:
            break
        }
        if filing.audioDue { return .queued }
        return filed > 0 ? .partial : .absent
    }

    private static func label(_ kind: Kind, filed: UInt32, total: UInt32) -> String {
        switch kind {
        case .off: return String(localized: "city.audio.off")
        case .included: return String(localized: "city.audio.included")
        case .absent: return String(localized: "city.audio.absent")
        case .queued: return String(localized: "city.audio.queued")
        case .uploading, .partial:
            // 一共几段要等量过才知道;还不知道的那一会儿只说在交。
            guard total > 0 else {
                return String(localized: kind == .uploading ? "city.audio.uploading" : "city.audio.absent")
            }
            return String(
                format: String(localized: "city.audio.progress_format"),
                Int64(filed),
                Int64(total)
            )
        case .filed: return String(localized: "city.audio.filed")
        case .refused: return String(localized: "city.audio.refused")
        case .tooBig: return String(localized: "city.audio.too_big")
        case .capped: return String(localized: "city.audio.capped")
        case .missing: return String(localized: "city.audio.missing")
        case .unreadable: return String(localized: "city.audio.unreadable")
        case .retained: return String(localized: "city.audio.retained")
        }
    }

    private static func reason(
        _ kind: Kind,
        filing: FfiCityFiling,
        total: UInt32,
        missing: Bool,
        signer: String?
    ) -> String? {
        let whyNot = filing.audioWithheld
            ? String(localized: "city.audio.reason.withheld")
            : String(localized: "city.audio.reason.setting_off")
        switch kind {
        case .off:
            return whyNot
        case .included:
            return String(localized: "city.audio.disclosure")
        case .absent:
            return String(localized: "city.audio.reason.absent")
        case .queued:
            // 没连上、服务器出错、服务器满了:会自己再试,原因照说。
            guard let code = filing.audioErrorCode else { return nil }
            return CityText.message(forCode: code, signer: signer)
        case .uploading:
            return nil
        case .filed:
            return String(localized: "city.audio.public")
        case .refused, .tooBig:
            return CityText.message(forCode: filing.audioErrorCode, signer: signer)
        case .capped:
            return String(
                format: String(localized: "city.audio.reason.capped_format"),
                CityText.moment(epoch: filing.audioRetryAtEpoch ?? 0)
            )
        case .missing:
            return String(localized: "city.audio.reason.missing")
        case .unreadable:
            return CityText.message(forCode: "city.error.audio_bad_part")
        case .partial:
            return CityText.joinSentences([
                missing ? String(localized: "city.audio.reason.missing") : whyNot,
                String(localized: "city.audio.public"),
            ])
        case .retained:
            return String(
                format: String(localized: "city.audio.reason.retained_format"),
                Int64(filing.audioPartsFiled)
            )
        }
    }

    private static func symbol(_ kind: Kind) -> String {
        switch kind {
        case .off: return "speaker.slash"
        case .included: return "waveform"
        case .absent: return "minus.circle"
        case .queued: return "clock"
        case .uploading: return "arrow.up.circle"
        case .filed: return "waveform.circle"
        case .refused: return "exclamationmark.triangle"
        case .tooBig: return "exclamationmark.octagon"
        case .capped: return "hourglass"
        case .missing: return "questionmark.circle"
        case .unreadable: return "xmark.circle"
        case .partial: return "pause.circle"
        case .retained: return "tray.full"
        }
    }

    private static func tone(_ kind: Kind) -> CityFilingStatus.Tone {
        switch kind {
        case .off, .included, .absent, .queued, .uploading, .capped, .missing, .retained:
            return .quiet
        case .filed:
            return .success
        case .partial:
            return .warning
        case .refused, .tooBig, .unreadable:
            return .failure
        }
    }

    private static func action(_ kind: Kind, filing: FfiCityFiling) -> Action? {
        switch kind {
        case .absent:
            return .file
        case .queued:
            // 只是还没轮到的,不用人管;上一次没连上、服务器出错的,可以现在
            // 再试,不必等下一轮。
            return filing.audioErrorCode == nil ? nil : .retry
        case .refused, .unreadable:
            return .retry
        case .off, .included, .uploading, .filed, .tooBig, .capped, .missing, .partial, .retained:
            return nil
        }
    }
}

/// 归过活动的录音里,各种状态各有几场。设置里表头的那一行、侧栏底部的那
/// 一行都从这里出。
struct CityFilingTally: Equatable {
    /// 在档案馆里的:已交的,连同交了以后改过字的。
    var filed = 0
    /// 此刻正在交的。录完自动交的那几秒就是它:不是卡住了,所以不说「排队」。
    var sending = 0
    /// 没连上、排着队等下一次的。
    var waiting = 0
    var failed = 0
    /// 交上去了但活动在城里被删的。
    var eventGone = 0
    /// 选了活动还没交的。
    var chosen = 0
    /// 文字交了,音频还在交或者排着队的。
    var audioSending = 0
    /// 文字交了,音频城没收下或者太大的:要人看一眼。
    var audioStuck = 0

    static func count(
        _ filings: [FfiCityFiling],
        busy: Set<String>,
        audioUploading: String? = nil,
        audioMissing: Set<String> = [],
        audioUnreadable: Set<String> = [],
        now: Date = Date()
    ) -> CityFilingTally {
        var tally = CityFilingTally()
        for filing in filings {
            switch CityFilingStatus.kind(filing, busy: busy.contains(filing.sessionId)) {
            case .filed, .changed: tally.filed += 1
            case .sending: tally.sending += 1
            case .waiting: tally.waiting += 1
            case .failed: tally.failed += 1
            case .eventGone: tally.eventGone += 1
            case .chosen: tally.chosen += 1
            case .notFiled, .withdrawn: break
            }
            guard filing.state == .filed else { continue }
            let audio = CityAudioStatus.kind(
                filing,
                uploading: audioUploading == filing.sessionId,
                missing: audioMissing.contains(filing.sessionId),
                unreadable: audioUnreadable.contains(filing.sessionId),
                now: now
            )
            switch audio {
            case .uploading, .queued, .capped: tally.audioSending += 1
            case .refused, .tooBig, .unreadable: tally.audioStuck += 1
            case .off, .included, .absent, .filed, .missing, .partial, .retained: break
            }
        }
        return tally
    }

    /// 「3 场已交 · 1 场排队 · 1 场没交上」。只说有的;一场都没有就是 nil。
    var summary: String? {
        let parts: [(Int, String.LocalizationValue)] = [
            (filed, "city.tally.filed_format"),
            (sending, "city.tally.sending_format"),
            (waiting, "city.tally.waiting_format"),
            (failed, "city.tally.failed_format"),
            (eventGone, "city.tally.event_gone_format"),
            (chosen, "city.tally.chosen_format"),
            (audioSending, "city.tally.audio_sending_format"),
            (audioStuck, "city.tally.audio_stuck_format"),
        ]
        let said = parts.filter { $0.0 > 0 }.map {
            String(format: String(localized: $0.1), Int64($0.0))
        }
        return said.isEmpty ? nil : said.joined(separator: " · ")
    }

    /// 有没有要人看一眼的:没交上的、活动被删的、排着队的、音频城没收的。
    /// 全都顺利时设置里那张表上不多一行字。
    var needsALook: Bool {
        failed > 0 || eventGone > 0 || waiting > 0 || audioStuck > 0
    }

    /// 侧栏底部要不要出那一行、说哪一件。一行只说最要紧的:没交上的先于
    /// 活动被删的,再先于音频没收下的、排着队的(排队的会自己再试),最后才
    /// 是正在交的。全都好就是 nil —— 没事的时候侧栏上什么都不多。
    var attention: (text: String, symbol: String, tone: CityFilingStatus.Tone)? {
        if failed > 0 {
            return (
                String(format: String(localized: "city.sidebar.failed_format"), Int64(failed)),
                "exclamationmark.triangle",
                .failure
            )
        }
        if eventGone > 0 {
            return (
                String(format: String(localized: "city.sidebar.event_gone_format"), Int64(eventGone)),
                "calendar.badge.exclamationmark",
                .warning
            )
        }
        if audioStuck > 0 {
            return (
                String(format: String(localized: "city.sidebar.audio_stuck_format"), Int64(audioStuck)),
                "exclamationmark.triangle",
                .failure
            )
        }
        if waiting > 0 {
            return (
                String(format: String(localized: "city.sidebar.waiting_format"), Int64(waiting)),
                "clock",
                .quiet
            )
        }
        if sending > 0 {
            return (
                String(format: String(localized: "city.sidebar.sending_format"), Int64(sending)),
                "arrow.up.circle",
                .quiet
            )
        }
        if audioSending > 0 {
            return (
                String(format: String(localized: "city.sidebar.audio_sending_format"), Int64(audioSending)),
                "waveform",
                .quiet
            )
        }
        return nil
    }
}
