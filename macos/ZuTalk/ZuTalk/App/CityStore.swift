// CityStore.swift
// 城与档案馆在界面上的唯一状态源:登录的是谁、登录走到哪一步、活动列表、
// 频道、交什么的选项、下一场录音归到哪、正在录的这一场归到哪、各场录音交
// 得怎么样了。
//
// 设计见 docs/architecture/city-archive.md。几条必须守住的:
//   - 没登录时,除了设置里「城」那一节,App 里哪都不出现城的东西;
//   - 归到哪场活动要人确认过才算数:在「开始录音」页上看着那一行按下开始,
//     或者自己从日历里挑了一场。替人选好的那一场,快捷键、菜单栏开的录音
//     不会用上 —— 没人看着它按下开始;
//   - 停止录音不等上传:录音先存好,交档案馆在后台,交完出一条提示;
//   - 断网的留在「排队」,联网后、下次启动时接着交;
//   - 走网络的调用(出码、等确认、读活动列表、交、更新、撤下)一律不在
//     主线程上等。
// 这条路只碰文字,音频从不经过这里。

import AppKit
import Combine
import Foundation

/// 下一场录音归到哪。没人动过就是 `automatic`:只有一场活动在进行时替人选好,
/// 一场都没有、或同时有好几场,都不选。
enum CityNextChoice: Equatable {
    case automatic
    case event(FfiCityEvent)
    /// 人明确说了这场不交。
    case notFiling
}

/// 窗口底部那一条带按钮的提示:「已交到档案馆 · <活动>」加「打开」。
/// `ToastCenter` 的提示不带按钮,所以这一条单独画(`CityNoticeOverlay`)。
struct CityNotice: Identifiable, Equatable {
    enum Action: Equatable {
        case open(URL)
        /// 「先问我」:录完只归了活动,由人点这一下才交。
        case file(sessionId: String)
    }

    let id = UUID()
    let text: String
    let action: Action?
}

@MainActor
final class CityStore: ObservableObject {
    static let shared = CityStore()

    /// 登录卡片里网址栏的默认内容。只是省得打字,填别的城一样登录。
    static let defaultServer = "zuchiangmai.com"
    /// 本机存的活动列表超过这么久,打开「开始录音」页或日历时顺手重读。
    static let calendarMaxAge: TimeInterval = 10 * 60

    enum Login: Equatable {
        /// 还没开始:填网址。
        case signedOut
        /// 已经点了继续,码还没回来。
        case requesting(server: String)
        /// 码在屏幕上,等旧设备扫。核对数到了就带上。
        case offered(FfiCityLoginOffer, digits: String?)
        /// 码失效了(过了五分钟、中途出错、或改用恢复密钥没成)。
        case lapsed(server: String)
        /// 正在用恢复密钥登录。
        case recovering(server: String)
    }

    // MARK: 登录

    /// 登录的人;没登录时为 nil。一台 Mac 一次登录一个人。
    @Published private(set) var account: FfiCityAccount?
    @Published private(set) var login: Login = .signedOut
    /// 登录没成的原因,已经是给人看的话。
    @Published private(set) var loginProblem: String?

    // MARK: 活动与频道

    /// 存在本机的那一份活动列表,断网时照样能选。
    @Published private(set) var calendar = FfiCityCalendar(events: [], fetchedAtEpoch: 0)
    @Published private(set) var refreshingCalendar = false
    @Published private(set) var calendarProblem: String?
    /// 登录的人能放东西的频道,以上次读到的为准。
    @Published private(set) var channels: [FfiCityChannel] = []
    /// 各主题选的频道;没选的主题不在里面。
    @Published private(set) var topicChannels: [String: FfiCityChannel] = [:]
    @Published private(set) var options = FfiCityFilingOptions(speakerNames: true, marks: true, automatic: true)

    // MARK: 录音

    @Published private(set) var nextChoice: CityNextChoice = .automatic
    /// 正在录的这一场。
    @Published private(set) var activeSessionId: String?
    @Published private(set) var activeFiling: FfiCityFiling?
    /// 这一场本来归了活动,录到一半改成了不交。录音条上的去向留着,好让人
    /// 再改回来。
    @Published private(set) var activeDestinationCleared = false
    /// 看过的录音各自交得怎么样,按需读。
    @Published private(set) var filings: [String: FfiCityFiling] = [:]
    /// 设置里「已交到档案馆」那张表,新的在前。
    @Published private(set) var filedList: [FfiCityFiling] = []
    /// 正在交、更新或撤下的录音。
    @Published private(set) var busySessions: Set<String> = []
    @Published private(set) var notice: CityNotice?

    private var core: (any ZuTalkCoreProtocol)? { CoreClient.shared.core }
    /// 每换一次登录的做法就加一:旧的那一轮等回来的结果不再算数。
    private var loginGeneration = 0
    /// 人在「开始录音」页按下开始时确认的去向,等会话号出来就绑上。
    private var confirmedEvent: FfiCityEvent?
    private var confirmedAt: Date?
    private var nextShownAt: Date?
    /// 确认只管紧接着的那一次开始。开始流程最多几秒到十几秒;过了这么久还
    /// 没等到会话号,这次确认就不再算数。
    private static let confirmationLifetime: TimeInterval = 120
    private var retryingPending = false
    private var started = false
    private var observers: Set<AnyCancellable> = []
    private var noticeTimer: Timer?

    private init() {
        account = core?.cityAccount()
        if account != nil { loadLocalState() }
    }

    /// 启动时调用:把上次没交完的接着交,并在网络回来时再试。
    func start() {
        guard started == false else { return }
        started = true
        NetworkReachability.shared.$isOffline
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] offline in
                if offline == false { self?.retryPending() }
            }
            .store(in: &observers)
        retryPending()
    }

    /// 只读本机:选项、存着的活动列表、频道。都是即时的。
    private func loadLocalState() {
        guard let core else { return }
        options = core.cityFilingOptions()
        if let cached = try? core.cityCalendar(refresh: false) { calendar = cached }
        channels = core.cityChannels()
    }

    // MARK: - 登录

    /// 填好网址点「继续」:向这座城要一个码。
    func beginLogin(server: String) {
        let server = server.trimmingCharacters(in: .whitespacesAndNewlines)
        guard server.isEmpty == false, let core else { return }
        let hadOffer = hasLiveOffer
        loginGeneration += 1
        let generation = loginGeneration
        loginProblem = nil
        login = .requesting(server: server)
        Task {
            let result = await Task.detached {
                // 上一个码还在等的话先收掉:同一时间只等一个。
                if hadOffer { core.cityLoginCancel() }
                return Result { try core.cityLoginBegin(server: server) }
            }.value
            guard generation == loginGeneration else { return }
            switch result {
            case .success(let offer):
                login = .offered(offer, digits: nil)
                await pollLogin(offer: offer, generation: generation)
            case .failure(let error):
                loginProblem = CityText.describe(error)
                login = .signedOut
            }
        }
    }

    /// 等旧设备扫码、确认。核心每次最多等二十几秒就回来一趟,所以是一圈一圈
    /// 地问,直到登录成了、码失效了,或人走开了。
    private func pollLogin(offer: FfiCityLoginOffer, generation: Int) async {
        guard let core else { return }
        while generation == loginGeneration {
            let asked = Date()
            let result = await Task.detached { Result { try core.cityLoginPoll() } }.value
            // 旧设备已经确认了:即使人刚好走开,核心里也已经登录,界面必须跟上。
            if case .success(.done(let account)) = result {
                finishLogin(account)
                return
            }
            guard generation == loginGeneration else { return }
            switch result {
            case .success(.waiting):
                break
            case .success(.check(let digits)):
                login = .offered(offer, digits: digits)
            case .success(.cancelled):
                login = .signedOut
                return
            case .success(.expired):
                login = .lapsed(server: offer.server)
                return
            case .success(.done):
                return
            case .failure(let error):
                loginProblem = CityText.describe(error)
                login = .lapsed(server: offer.server)
                return
            }
            // 正常情况下每一圈都在核心里等着;万一立刻就回来,别空转。
            if Date().timeIntervalSince(asked) < 0.5 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    /// 换一座城、或离开了设置里这一节:不等了。
    func cancelLogin() {
        guard login != .signedOut else { return }
        let hadOffer = hasLiveOffer
        loginGeneration += 1
        login = .signedOut
        loginProblem = nil
        if hadOffer, let core {
            Task.detached { core.cityLoginCancel() }
        }
    }

    /// 码过了五分钟:收掉,让人换一个新的,不让人对着一个扫不了的码等。
    func loginOfferLapsed(_ offer: FfiCityLoginOffer) {
        guard case .offered(let current, _) = login, current.code == offer.code else { return }
        loginGeneration += 1
        login = .lapsed(server: offer.server)
        if let core {
            Task.detached { core.cityLoginCancel() }
        }
    }

    /// 码除了扫,也可以拷贝到旧设备上粘贴。
    func copyLoginCode(_ offer: FfiCityLoginOffer) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(offer.code, forType: .string)
        ToastCenter.shared.success(String(localized: "city.signin.code_copied"))
    }

    /// 没有别的设备在手边:直接填恢复密钥。密钥只经手这一次,不留在界面状态里。
    func loginWithRecoveryKey(_ recoveryKey: String) {
        let recoveryKey = recoveryKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard recoveryKey.isEmpty == false, let core, let server = loginServer else { return }
        let hadOffer = hasLiveOffer
        loginGeneration += 1
        let generation = loginGeneration
        loginProblem = nil
        login = .recovering(server: server)
        Task {
            let result = await Task.detached {
                if hadOffer { core.cityLoginCancel() }
                return Result { try core.cityLoginWithRecoveryKey(server: server, recoveryKey: recoveryKey) }
            }.value
            switch result {
            case .success(let account):
                finishLogin(account)
            case .failure(let error):
                guard generation == loginGeneration else { return }
                loginProblem = CityText.describe(error)
                login = .lapsed(server: server)
            }
        }
    }

    /// 正在登录的是哪座城的网址。
    var loginServer: String? {
        switch login {
        case .signedOut: return nil
        case .requesting(let server), .lapsed(let server), .recovering(let server): return server
        case .offered(let offer, _): return offer.server
        }
    }

    private var hasLiveOffer: Bool {
        if case .offered = login { return true }
        return false
    }

    private func finishLogin(_ account: FfiCityAccount) {
        loginGeneration += 1
        login = .signedOut
        loginProblem = nil
        self.account = account
        loadLocalState()
        refreshCalendar()
        reloadFiledList()
        retryPending()
    }

    /// 退出登录:只把登录信息从这台 Mac 上删掉,城里的身份不受影响。
    func signOut() {
        guard let core else { return }
        do {
            try core.citySignOut()
        } catch {
            ToastCenter.shared.error(
                String(localized: "city.signout.failed"),
                detail: CityText.describe(error)
            )
            return
        }
        forgetAccount()
    }

    private func forgetAccount() {
        account = nil
        calendar = FfiCityCalendar(events: [], fetchedAtEpoch: 0)
        calendarProblem = nil
        channels = []
        topicChannels = [:]
        nextChoice = .automatic
        cancelConfirmedDestination()
        activeFiling = nil
        activeDestinationCleared = false
        filings = [:]
        filedList = []
        dismissNotice()
    }

    /// 在别处退出、或钥匙作废以后,核心会说「没登录」。照实跟上,不留一个
    /// 看着登录着、其实什么都交不了的界面。
    private func noteFailure(_ error: Error) {
        guard CityText.errorCode(error) == "city.error.signed_out",
              account != nil,
              core?.cityAccount() == nil
        else { return }
        forgetAccount()
    }

    // MARK: - 交什么

    func setOptions(_ next: FfiCityFilingOptions) {
        guard let core, next != options else { return }
        do {
            try core.setCityFilingOptions(options: next)
            options = next
        } catch {
            ToastCenter.shared.error(
                String(localized: "city.options.save_failed"),
                detail: CityText.describe(error)
            )
        }
    }

    // MARK: - 活动列表与频道

    /// 「开始录音」页、日历出现时调用:存着的那份太旧就重读。断网时不试,
    /// 用存着的。
    func refreshCalendarIfStale(now: Date = Date()) {
        guard account != nil, NetworkReachability.shared.isOffline == false else { return }
        let age = now.timeIntervalSince1970 - TimeInterval(calendar.fetchedAtEpoch)
        guard calendar.fetchedAtEpoch == 0 || age > Self.calendarMaxAge else { return }
        refreshCalendar()
    }

    func refreshCalendar() {
        guard account != nil, refreshingCalendar == false, let core else { return }
        refreshingCalendar = true
        Task {
            let result = await Task.detached { Result { try core.cityCalendar(refresh: true) } }.value
            refreshingCalendar = false
            guard account != nil else { return }
            switch result {
            case .success(let fresh):
                calendar = fresh
                calendarProblem = nil
                // 频道跟着活动列表一起读回来。
                channels = core.cityChannels()
            case .failure(let error):
                calendarProblem = CityText.describe(error)
                noteFailure(error)
            }
        }
    }

    /// 主题设置出现时调用:读这个主题选的频道。
    func loadTopicChannel(notebookId: String) {
        guard account != nil, let core else { return }
        let channel = core.cityTopicChannel(notebookId: notebookId)
        if topicChannels[notebookId] != channel {
            topicChannels[notebookId] = channel
        }
    }

    func setTopicChannel(notebookId: String, channel: FfiCityChannel?) {
        guard let core else { return }
        do {
            try core.setCityTopicChannel(notebookId: notebookId, channel: channel)
            topicChannels[notebookId] = channel
        } catch {
            ToastCenter.shared.error(
                String(localized: "city.topic.channel_failed"),
                detail: CityText.describe(error)
            )
        }
    }

    // MARK: - 下一场录音

    /// 此刻下一场录音会归到哪场活动;不归就是 nil。
    func nextEvent(now: Date) -> FfiCityEvent? {
        guard account != nil else { return nil }
        switch nextChoice {
        case .automatic: return CityEventMatching.automaticChoice(calendar.events, now: now)
        case .event(let event): return event
        case .notFiling: return nil
        }
    }

    func chooseNext(_ choice: CityNextChoice) {
        nextChoice = choice
    }

    /// 「开始录音」页出现时调用。上次选了没录的那场活动要是早就散了,回到
    /// 自动:人看到的应该是此刻的情况,不是几小时前的选择。
    func prepareNextRecording(now: Date = Date()) {
        if case .event(let event) = nextChoice,
           event.endMs < Int64(now.timeIntervalSince1970 * 1_000) {
            nextChoice = .automatic
        }
        refreshCalendarIfStale(now: now)
    }

    /// 「开始录音」页那一行是按哪个时刻算的。确认时用同一个时刻:绑上的必须是
    /// 人看到的那一场,不能是按下开始那一秒才开场的另一场。
    func noteNextDestinationShown(at date: Date) {
        nextShownAt = date
    }

    /// 人在「开始录音」页按下开始。那一行此刻写着归到哪,就是确认了归到哪。
    func confirmNextDestination() {
        let now = Date()
        let shown = nextShownAt.flatMap {
            now.timeIntervalSince($0) < Self.confirmationLifetime ? $0 : nil
        } ?? now
        confirmedEvent = nextEvent(now: shown)
        confirmedAt = now
    }

    /// 这次开始没成:确认作废,免得被之后快捷键开的录音用上。
    func cancelConfirmedDestination() {
        confirmedEvent = nil
        confirmedAt = nil
    }

    // MARK: - 正在录的这一场

    /// 新录音的会话号出来了:把确认过的去向绑上。
    func recordingStarted(sessionId: String) {
        activeSessionId = sessionId
        activeFiling = nil
        activeDestinationCleared = false
        let now = Date()
        let confirmedRecently = confirmedAt.map {
            now.timeIntervalSince($0) < Self.confirmationLifetime
        } ?? false
        let event: FfiCityEvent?
        if confirmedRecently {
            event = confirmedEvent
        } else if case .event(let picked) = nextChoice,
                  picked.endMs >= Int64(now.timeIntervalSince1970 * 1_000) {
            // 快捷键、菜单栏开的录音没经过那一行。人自己从日历里挑好的一场
            // 照样算数(录音条上看得到、改得了);替人选的那一场不算 —— 没人
            // 看着它按下开始。
            event = picked
        } else {
            event = nil
        }
        cancelConfirmedDestination()
        nextChoice = .automatic
        guard account != nil, let event else { return }
        Task { await bind(sessionId: sessionId, event: event) }
    }

    /// 录音结束了,不管是怎么结束的。归了活动的那一场:设了自动交就在后台交,
    /// 设了先问就出一条提示等人点。
    func recordingEnded() {
        guard let sessionId = activeSessionId else { return }
        activeSessionId = nil
        activeFiling = nil
        activeDestinationCleared = false
        guard account != nil else { return }
        Task { await fileAfterRecording(sessionId: sessionId) }
    }

    private func fileAfterRecording(sessionId: String) async {
        guard let core else { return }
        // 以核心里记的为准:录到一半可能改过去向。
        let filing = await Task.detached { core.cityFiling(sessionId: sessionId) }.value
        guard account != nil, let filing, filing.state == .bound else { return }
        filings[sessionId] = filing
        guard options.automatic else {
            post(
                CityNotice(
                    text: String(format: String(localized: "city.notice.ask_format"), filing.eventTitle),
                    action: .file(sessionId: sessionId)
                ),
                lasting: 20
            )
            return
        }
        await file(sessionId: sessionId, announce: true)
    }

    // MARK: - 各场录音

    /// 读一场录音交得怎么样。核心顺带重算改了几句,长录音要一会儿,所以在
    /// 后台读。
    @discardableResult
    func loadFiling(sessionId: String) async -> FfiCityFiling? {
        guard account != nil, let core else { return nil }
        let filing = await Task.detached { core.cityFiling(sessionId: sessionId) }.value
        guard account != nil else { return nil }
        remember(filing, sessionId: sessionId)
        return filing
    }

    /// 选(或用 nil 清掉)一场录音归到的活动。录音前、录音中、录完以后都能改;
    /// 已经交上去的要先撤下才能换。
    @discardableResult
    func bind(sessionId: String, event: FfiCityEvent?) async -> FfiCityFiling? {
        guard account != nil, let core else { return nil }
        let result = await Task.detached {
            Result { try core.cityBindSession(sessionId: sessionId, event: event) }
        }.value
        switch result {
        case .success(let filing):
            remember(filing, sessionId: sessionId)
            if sessionId == activeSessionId {
                activeDestinationCleared = filing == nil
            }
            return filing
        case .failure(let error):
            ToastCenter.shared.error(
                String(localized: "city.bind.failed"),
                detail: CityText.describe(error, signer: account?.personName)
            )
            noteFailure(error)
            return nil
        }
    }

    /// 交到档案馆。`announce` 给后台交的用:界面上没有别的地方会说结果。
    @discardableResult
    func file(sessionId: String, announce: Bool = false) async -> FfiCityFiling? {
        await send(sessionId: sessionId, announce: announce) { core in
            try core.cityFileSession(sessionId: sessionId)
        }
    }

    /// 在 ZuTalk 改了字以后,把改过的那几句发过去。每次更新都是一次对外发送,
    /// 所以只在人按下时调用。
    @discardableResult
    func update(sessionId: String) async -> FfiCityFiling? {
        await send(sessionId: sessionId, announce: false) { core in
            try core.cityUpdateFiling(sessionId: sessionId)
        }
    }

    /// 从档案馆撤下。
    @discardableResult
    func withdraw(sessionId: String) async -> FfiCityFiling? {
        let filing = await send(sessionId: sessionId, announce: false) { core in
            try core.cityWithdrawFiling(sessionId: sessionId)
        }
        if filing?.state == .withdrawn {
            ToastCenter.shared.success(String(localized: "city.toast.withdrawn"))
        }
        return filing
    }

    /// 交、更新、撤下共用的一段。这三个调用没交成也把那一份记录还回来:断网
    /// 是「排队」,被拒是「没交上」,都写在 `state` 和 `errorCode` 里;只有
    /// 没登录、没归活动、同一场正在交才抛错。
    private func send(
        sessionId: String,
        announce: Bool,
        _ call: @escaping @Sendable (any ZuTalkCoreProtocol) throws -> FfiCityFiling
    ) async -> FfiCityFiling? {
        guard account != nil, let core, busySessions.contains(sessionId) == false else { return nil }
        busySessions.insert(sessionId)
        let result = await Task.detached { Result { try call(core) } }.value
        busySessions.remove(sessionId)
        guard account != nil else { return nil }
        switch result {
        case .success(let filing):
            remember(filing, sessionId: sessionId)
            reloadFiledList()
            if announce { self.announce(filing) }
            return filing
        case .failure(let error):
            // 同一场已经在交了:那一趟会给结果,这里不再多说一遍。
            if CityText.errorCode(error) != "city.error.busy" {
                ToastCenter.shared.error(
                    String(localized: "city.toast.failed"),
                    detail: CityText.describe(error, signer: account?.personName)
                )
            }
            noteFailure(error)
            return nil
        }
    }

    /// 后台交完说一声。只有真交上了才说「已交到档案馆」。
    private func announce(_ filing: FfiCityFiling) {
        switch filing.state {
        case .filed:
            post(
                CityNotice(
                    text: String(format: String(localized: "city.notice.filed_format"), filing.eventTitle),
                    action: CityText.webURL(filing.webUrl).map { .open($0) }
                ),
                lasting: 10
            )
        case .queued:
            // 会自己再试,所以是一句交代,不是报错。
            ToastCenter.shared.info(String(localized: filing.errorCode == "city.error.offline"
                ? "city.toast.queued_offline"
                : "city.toast.queued"))
        case .failed:
            ToastCenter.shared.error(
                String(format: String(localized: "city.toast.failed_format"), filing.eventTitle),
                detail: CityText.message(forCode: filing.errorCode, signer: account?.personName)
            )
        case .bound, .withdrawn:
            break
        }
    }

    private func remember(_ filing: FfiCityFiling?, sessionId: String) {
        if filings[sessionId] != filing {
            filings[sessionId] = filing
        }
        if sessionId == activeSessionId, activeFiling != filing {
            activeFiling = filing
        }
    }

    /// 设置里「已交到档案馆」那张表。在后台读:核心可能顺带核对改了几句。
    func reloadFiledList() {
        guard account != nil, let core else { return }
        Task {
            let list = await Task.detached { core.cityFilings() }.value
            guard account != nil else { return }
            if list != filedList { filedList = list }
        }
    }

    // MARK: - 排队的

    /// 启动时、网络回来时:把还在排队的一场一场交上去。
    func retryPending() {
        guard account != nil, retryingPending == false, let core,
              NetworkReachability.shared.isOffline == false
        else { return }
        retryingPending = true
        Task {
            let pending = await Task.detached { core.cityPendingSessions() }.value
            for sessionId in pending {
                guard account != nil else { break }
                let filing = await file(sessionId: sessionId, announce: false)
                // 排队的这回交上了要说一声;还交不上的不再弹一遍,共享面板和
                // 设置里那张表上看得到。
                if let filing, filing.state == .filed {
                    announce(filing)
                }
            }
            retryingPending = false
        }
    }

    // MARK: - 提示

    private func post(_ notice: CityNotice, lasting seconds: TimeInterval) {
        self.notice = notice
        noticeTimer?.invalidate()
        noticeTimer = nil
        // UI 测试里不自动收起,和 ToastCenter 一样。
        guard TestEnvironment.shouldDisableToastAutoDismiss == false else { return }
        let id = notice.id
        noticeTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in
            Task { @MainActor in CityStore.shared.dismissNotice(id: id) }
        }
    }

    func dismissNotice(id: UUID? = nil) {
        guard id == nil || notice?.id == id else { return }
        notice = nil
        noticeTimer?.invalidate()
        noticeTimer = nil
    }

    /// 提示上的那个按钮:打开档案馆里的那一件,或者(先问我)现在交。
    func performNoticeAction() {
        guard let action = notice?.action else { return }
        dismissNotice()
        switch action {
        case .open(let url):
            NSWorkspace.shared.open(url)
        case .file(let sessionId):
            Task { await file(sessionId: sessionId, announce: true) }
        }
    }
}
