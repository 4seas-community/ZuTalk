// CityText.swift
// 城与档案馆在界面上怎么说:错误、角色、「交什么」的那一句、活动的时间。
//
// 这些话在设置、「开始录音」页、录音条、共享面板四处出现,说法必须一样,
// 所以收在一处。都是纯函数,可以单独测。
//
// 0.8.3 起交到档案馆的录音默认带音频(docs/architecture/city-archive.md
// 第 0 节)。所以这里没有一句话说音频留在这台 Mac:要交音频的时候明说,并且
// 说它是公开的、删不掉;不交的时候不替以后许诺。

import Foundation

enum CityText {
    // MARK: - 错误

    /// 核心给的稳定代码。抛出的 `CoreError` 把它放在 message 里,
    /// `FfiCityFiling.errorCode` 用的是同一批。
    static let errorCodes: Set<String> = [
        "city.error.offline",
        "city.error.server",
        "city.error.bad_address",
        "city.error.no_city",
        "city.error.bad_key",
        "city.error.expired",
        "city.error.signed_out",
        "city.error.unbound",
        "city.error.not_allowed",
        "city.error.event_gone",
        "city.error.no_transcript",
        "city.error.refused",
        "city.error.busy",
        "city.error.audio_not_filed",
        "city.error.audio_off",
        "city.error.audio_withheld",
        "city.error.audio_bad_part",
        "city.error.audio_refused",
        "city.error.audio_too_big",
        "city.error.audio_daily_cap",
        "city.error.audio_server_full",
    ]

    /// 活动在城里被删掉或取消了。交的时候发现,是「没交上」的原因;交上去
    /// 以后才发现,核心把它写在一份「已交」的记录上 —— 两处都要认它,所以
    /// 起个名字。
    static let eventGoneCode = "city.error.event_gone"

    /// 音频这一路上,人要做的事各不一样的那几种(`FfiCityFiling.audioErrorCode`)。
    /// 城没收下:不再自己试。
    static let audioRefusedCode = "city.error.audio_refused"
    /// 一段太大:不再自己试。
    static let audioTooBigCode = "city.error.audio_too_big"
    /// 今天往城里放得太多:到城说的时候自己接着交。
    static let audioDailyCapCode = "city.error.audio_daily_cap"

    /// 从核心抛出的错误里取出稳定代码;不是城的错误就没有。
    static func errorCode(_ error: Error) -> String? {
        guard let core = error as? CoreError else { return nil }
        let message: String
        switch core {
        case .InitFailed(let text), .ValidationFailed(let text),
             .NotFound(let text), .InternalError(let text):
            message = text
        @unknown default:
            return nil
        }
        return errorCodes.contains(message) ? message : nil
    }

    /// 按稳定代码查本地化的说法;认不出的给一句笼统的话(与
    /// `DeviceSyncStore.describe` 同一个做法)。`signer` 是登录的人的名字:
    /// 「请主办把你加为记录员」这句要让人能把名字报给主办。
    static func message(forCode code: String?, signer: String? = nil) -> String {
        switch code {
        case "city.error.offline": return String(localized: "city.error.offline")
        case "city.error.server": return String(localized: "city.error.server")
        case "city.error.bad_address": return String(localized: "city.error.bad_address")
        case "city.error.no_city": return String(localized: "city.error.no_city")
        case "city.error.bad_key": return String(localized: "city.error.bad_key")
        case "city.error.expired": return String(localized: "city.error.expired")
        case "city.error.signed_out": return String(localized: "city.error.signed_out")
        case "city.error.unbound": return String(localized: "city.error.unbound")
        case "city.error.not_allowed":
            if let signer, signer.isEmpty == false {
                return String(format: String(localized: "city.error.not_allowed_named_format"), signer)
            }
            return String(localized: "city.error.not_allowed")
        case "city.error.event_gone": return String(localized: "city.error.event_gone")
        case "city.error.no_transcript": return String(localized: "city.error.no_transcript")
        case "city.error.refused": return String(localized: "city.error.refused")
        case "city.error.busy": return String(localized: "city.error.busy")
        case "city.error.audio_not_filed": return String(localized: "city.error.audio_not_filed")
        case "city.error.audio_off": return String(localized: "city.error.audio_off")
        case "city.error.audio_withheld": return String(localized: "city.error.audio_withheld")
        case "city.error.audio_bad_part": return String(localized: "city.error.audio_bad_part")
        case "city.error.audio_refused": return String(localized: "city.error.audio_refused")
        case "city.error.audio_too_big": return String(localized: "city.error.audio_too_big")
        case "city.error.audio_daily_cap": return String(localized: "city.error.audio_daily_cap")
        case "city.error.audio_server_full": return String(localized: "city.error.audio_server_full")
        default: return String(localized: "city.error.generic")
        }
    }

    static func describe(_ error: Error, signer: String? = nil) -> String {
        message(forCode: errorCode(error), signer: signer)
    }

    // MARK: - 身份

    /// 「<城名> 居民」。一个人可以有好几个角色,只说分量最重的那个;一个角色都
    /// 没有就只写城名。城名来自服务器,这里不写死任何一座城。
    static func role(_ account: FfiCityAccount) -> String {
        let city = account.cityName.isEmpty ? account.server : account.cityName
        let roles = Set(account.roles)
        let key: String.LocalizationValue
        if roles.contains("founder") {
            key = "city.role.founder_format"
        } else if roles.contains("coordinator") {
            key = "city.role.coordinator_format"
        } else if roles.contains("curator") {
            key = "city.role.curator_format"
        } else if roles.contains("inviter") {
            key = "city.role.inviter_format"
        } else if roles.contains("resident") {
            key = "city.role.resident_format"
        } else {
            return city
        }
        return String(format: String(localized: key), city)
    }

    /// 头像里的那一个字。
    static func initial(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).first.map { String($0).uppercased() } ?? "?"
    }

    // MARK: - 交什么

    /// 语言代码换成各语言自己的写法(English、ไทย、中文),去掉重复和认不出的。
    static func languageNames(_ codes: [String]) -> [String] {
        var seen = Set<String>()
        return codes
            .map(RecordingPresentation.languageName)
            .filter { $0.isEmpty == false && seen.insert($0).inserted }
    }

    /// 「以 Lin 的名义交 English、ไทย和中文的文字稿。带说话人的名字。」
    /// 标记从 0.8.3 起不交,所以这里不提它。
    static func whatIsFiled(
        signer: String,
        languages: [String],
        options: FfiCityFilingOptions
    ) -> String {
        let names = languageNames(languages)
        let lead = names.isEmpty
            ? String(format: String(localized: "city.summary.as_format"), signer)
            : String(
                format: String(localized: "city.summary.as_languages_format"),
                signer,
                ListFormatter.localizedString(byJoining: names)
            )
        let speakers = String(localized: options.speakerNames
            ? "city.summary.names"
            : "city.summary.no_names")
        return joinSentences([lead, speakers])
    }

    /// 交之前要让人读得到的那一整句:以谁的名义、哪几种语言、带不带说话人、
    /// 放不放进频道;要交音频的话,最后明说连音频一起交、交上去是公开的、
    /// 删不掉。
    ///
    /// `audio` 是这一场会不会带音频;不给就照设置。不带的时候什么都不说:
    /// 设置和这一场的开关在交之前都还能改,「音频不交」是一句替以后许的诺。
    static func summary(
        signer: String,
        languages: [String],
        options: FfiCityFilingOptions,
        channel: String?,
        audio: Bool? = nil
    ) -> String {
        var parts = [whatIsFiled(signer: signer, languages: languages, options: options)]
        if let channel, channel.isEmpty == false {
            parts.append(String(format: String(localized: "city.summary.channel_format"), channel))
        }
        if audio ?? options.audio {
            parts.append(String(localized: "city.summary.audio_included"))
        }
        return joinSentences(parts)
    }

    /// 登录的地方要让人读得到的:这台 Mac 能以你的名义做事;交到活动的录音
    /// 默认带音频;交上去的是公开的,删不掉。
    static var signInDisclosure: String {
        String(localized: "city.signin.disclosure")
    }

    /// 「音频」那个开关旁边的:连音频一起交;公开、删不掉;城的主办能拿它
    /// 再转写。
    static var audioDisclosure: String {
        String(localized: "city.audio.disclosure")
    }

    /// 撤下之前的那一句:档案馆的页面不再显示它;已经交上去的文字和音频留在
    /// 城的记录里。
    static var withdrawConfirmation: String {
        String(localized: "city.withdraw.confirm_one")
    }

    /// 几句话接成一段。中文、日文的句号后面不空格,别的语言空一格。
    static func joinSentences(_ parts: [String]) -> String {
        parts.filter { $0.isEmpty == false }.reduce(into: "") { joined, next in
            guard let last = joined.last else {
                joined = next
                return
            }
            joined += "。！？".contains(last) ? next : " " + next
        }
    }

    /// 已经交上去的那一份里有什么:「English 412 句 · ไทย 96 句 · 说话人 4 位 · 标记 7 处」。
    static func content(_ filing: FfiCityFiling) -> String {
        var parts = filing.languages.compactMap { count -> String? in
            let name = RecordingPresentation.languageName(count.language)
            guard name.isEmpty == false else { return nil }
            return String(
                format: String(localized: "city.content.language_format"),
                name,
                Int64(count.sentences)
            )
        }
        if filing.speakers > 0 {
            parts.append(String(format: String(localized: "city.content.speakers_format"), Int64(filing.speakers)))
        }
        if filing.marks > 0 {
            parts.append(String(format: String(localized: "city.content.marks_format"), Int64(filing.marks)))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - 时间
    //
    // 活动的时刻是 Unix 毫秒,一律按这台 Mac 的时区显示:主办看的是墙上的钟。

    static func date(ms: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(ms) / 1_000)
    }

    /// 「11:00–13:00」。
    static func timeRange(
        startMs: Int64,
        endMs: Int64,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date(ms: startMs)) + "–" + formatter.string(from: date(ms: endMs))
    }

    /// 「11月6日」。
    static func day(
        _ date: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        formatted(date, template: "MMMd", calendar: calendar, locale: locale)
    }

    /// 「今天 11:00–13:00」;不是今天的写日期:「11月12日 09:30–11:30」。
    static func when(
        _ event: FfiCityEvent,
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        let range = timeRange(startMs: event.startMs, endMs: event.endMs, calendar: calendar, locale: locale)
        let start = date(ms: event.startMs)
        if calendar.isDate(start, inSameDayAs: now) {
            return String(format: String(localized: "city.event.today_format"), range)
        }
        return day(start, calendar: calendar, locale: locale) + " " + range
    }

    /// 活动按钮第二行:时间,有场地的话接上场地。
    static func whenAndWhere(
        _ event: FfiCityEvent,
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        let time = when(event, now: now, calendar: calendar, locale: locale)
        return event.place.isEmpty ? time : time + " · " + event.place
    }

    /// 「今天 13:04」「昨天 18:20」「2026年11月6日 13:04」:交上去的时刻、活动
    /// 列表上次更新的时刻。
    static func moment(
        epoch: Int64,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(epoch)))
    }

    static func formatted(
        _ date: Date,
        template: String,
        calendar: Calendar,
        locale: Locale
    ) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }

    // MARK: - 链接

    /// 城的网站。地址是人填的,可能带也可能不带 `https://`。
    static func siteURL(server: String) -> URL? {
        let trimmed = server.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        return webURL(trimmed.contains("://") ? trimmed : "https://" + trimmed)
    }

    /// 只认网页链接。档案馆里那一件的地址来自服务器,不是网页地址的一律不开。
    static func webURL(_ text: String?) -> URL? {
        guard let text,
              let url = URL(string: text),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              url.host?.isEmpty == false
        else { return nil }
        return url
    }
}
