// CityFilingStatus.swift
// 一场录音交到档案馆这件事,此刻停在哪一步 —— 全 App 只有这一套说法。
//
// 0.8.0 里各处各说各的:录完的那条提示、共享面板里的那一段、设置里的那张表,
// 三处各自拿 `state` 和 `errorCode` 拼话;录音自己的页面和列表上什么都不说,
// 主窗口也看不出还有没有排着队的。人要回答「这场录音到城里了吗,没到的话
// 我该做什么」,得自己去翻。
//
// 现在录音页顶栏、录音列表、共享面板、设置里的表、侧栏底部都从这里取:
// 同一个状态,同一句短话,同一个图标,同一种颜色,同一个「下一步」。
//
// 几条定下来的:
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
    /// 一句短话:「已交到档案馆」「排队中,稍后自动再试」。
    let label: String
    /// 要多说一句的时候:没交上的原因、活动被删以后会怎样、上次更新或撤下
    /// 没成的原因。都是人能照做的整句。
    let reason: String?
    /// SF Symbol。颜色不是唯一的信号:每种状态的图标和话都不一样。
    let symbol: String
    let tone: Tone
    /// 正在交、更新、撤下的那一会儿没有可做的事。
    let primaryAction: Action?

    /// 一场录音此刻的状态。
    ///
    /// - Parameters:
    ///   - filing: 核心记的那一份;没归过活动就是 nil。
    ///   - busy: 这一场此刻有没有请求在路上(`CityStore.busySessions`)。
    ///   - offline: 系统是否确认这台 Mac 没有网络(`NetworkReachability.isOffline`)。
    ///   - signer: 登录的人的名字,「请主办把你加为记录员」那句要用。
    static func resolve(
        _ filing: FfiCityFiling?,
        busy: Bool,
        offline: Bool,
        signer: String? = nil
    ) -> CityFilingStatus {
        let kind = kind(filing, busy: busy)
        return CityFilingStatus(
            kind: kind,
            label: label(kind, filing: filing, offline: offline),
            reason: reason(kind, filing: filing, signer: signer),
            symbol: symbol(kind, offline: offline),
            tone: tone(kind),
            primaryAction: busy ? nil : action(kind, filing: filing, offline: offline)
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
        case .chosen: return String(localized: "city.status.chosen")
        case .sending: return String(localized: "city.status.sending")
        case .waiting:
            return String(localized: offline ? "city.status.waiting_offline" : "city.status.waiting")
        case .filed: return String(localized: "city.status.filed")
        case .changed:
            return String(
                format: String(localized: "city.status.changed_format"),
                Int64(filing?.changedSentences ?? 0)
            )
        case .eventGone: return String(localized: "city.status.event_gone")
        case .failed: return String(localized: "city.status.failed")
        case .withdrawn: return String(localized: "city.status.withdrawn")
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

    /// 「档案馆:已交到档案馆 · <活动名>」:悬停提示和旁白用的那一句。图标和
    /// 短话离开了「档案馆」三个字,人看不出说的是哪件事。
    func described(event title: String?) -> String {
        guard let title, title.isEmpty == false else { return label }
        return String(format: String(localized: "city.status.for_event_format"), label, title)
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

    static func count(_ filings: [FfiCityFiling], busy: Set<String>) -> CityFilingTally {
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
        ]
        let said = parts.filter { $0.0 > 0 }.map {
            String(format: String(localized: $0.1), Int64($0.0))
        }
        return said.isEmpty ? nil : said.joined(separator: " · ")
    }

    /// 侧栏底部要不要出那一行、说哪一件。一行只说最要紧的:没交上的先于
    /// 活动被删的,再先于排着队的(排队的会自己再试),最后才是正在交的
    /// (几秒钟就过去)。全都好就是 nil —— 没事的时候侧栏上什么都不多。
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
        return nil
    }
}
