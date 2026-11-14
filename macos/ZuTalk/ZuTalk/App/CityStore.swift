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
//   - 没连上的留在「排队」,自己接着试:启动时、网络回来时、切回 App 时,
//     还有排着队的期间每两分钟一次。去城的那条路常有一阵连不上,机器本身
//     在线,所以不能只等「网络回来」那一下;
//   - 各场录音交到哪一步了,这里存一份、按录音查得到:录音页、列表、共享
//     面板、设置、侧栏都读这一份,不各自去问核心;
//   - 走网络的调用(出码、等确认、读活动列表、交、更新、撤下)一律不在
//     主线程上等;
//   - 文字先交,音频跟在后面一段段交(0.8.3 起,默认带音频)。音频一次只交
//     一场,在后台;一场录音在第一个音频错误上停下,原因写在它的状态上;启动
//     时、切回 App 时、网络回来时接着交。导出和上传在 `CityAudioExportRun`
//     里,这里只管排队、让路和记结果 —— 这个文件自己不碰音频的采样;
//   - 窗口不跟着每一拍重画:音频的进度只在交完一段、开始和结束时各发一次。

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

/// 正在交音频的那一场。一共几段要等量过音频才知道,在那之前是 0。
struct CityAudioUpload: Equatable {
    let sessionId: String
    var total: UInt32
}

/// 这台 Mac 上的音频交不了的两种情形。都不在核心的账上,只在这一次运行里记着。
enum CityAudioLocalProblem: Equatable {
    /// 音频已经不在这台 Mac 上(保留期到了、人删了、录音进了回收站)。
    case missing
    /// 音频还在,没能导出来。
    case unreadable
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
    @Published private(set) var options = FfiCityFilingOptions(speakerNames: true, audio: true, automatic: true)

    // MARK: 录音

    @Published private(set) var nextChoice: CityNextChoice = .automatic
    /// 下一场录音不交音频。和选好的活动一样只管紧接着的那一场:绑上以后用
    /// `citySetSessionAudio` 记到那场录音上,这里清掉。
    @Published private(set) var nextWithholdsAudio = false
    /// 正在录的这一场。
    @Published private(set) var activeSessionId: String?
    @Published private(set) var activeFiling: FfiCityFiling?
    /// 这一场本来归了活动,录到一半改成了不交。录音条上的去向留着,好让人
    /// 再改回来。
    @Published private(set) var activeDestinationCleared = false
    /// 归过活动的每一场录音交到哪一步了,按录音查。录音页顶栏、列表里的
    /// 记号、共享面板各取各的那一场;列表里几百行,不能一行问一次核心。
    @Published private(set) var filings: [String: FfiCityFiling] = [:]
    /// 同一批,最近动过的在前:设置里那张表、侧栏底部那一行据此列。
    @Published private(set) var filingList: [FfiCityFiling] = []
    /// 正在交、更新或撤下的录音。
    @Published private(set) var busySessions: Set<String> = []
    /// 正在交音频的那一场;一次只交一场。
    @Published private(set) var audioUpload: CityAudioUpload?
    /// 音频在这台 Mac 上交不了的录音:没有了,或者没导出来。
    @Published private(set) var audioProblems: [String: CityAudioLocalProblem] = [:]
    /// 系统确认这台 Mac 没有网络。只有这时才说「没有联网」;核心报的
    /// 「没连上城的服务器」说明不了这一点。
    @Published private(set) var offline = false
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
    /// 还有排着队的期间,隔这么久自己再试一次。
    static let retryInterval: TimeInterval = 120
    /// 切回 App 时顺手再试,但离上一次不到这么久就不试:来回切窗口不该
    /// 变成对着城的服务器连环敲门。
    static let activationRetryGap: TimeInterval = 30
    private var retryingPending = false
    private var lastRetryAt: Date?
    private var retryTimer: Timer?
    private var reloadingFilings = false
    private var countingChanges = false
    private var reloadFilingsAgain = false
    /// 每记下一场的新结果就加一:整张单子读回来时对一下,读的途中有新结果
    /// 进来过,那一份就可能已经旧了。
    private var filingsRevision = 0
    private var started = false
    private var observers: Set<AnyCancellable> = []
    private var audioQueue = CityAudioExportQueue()
    private var audioTask: Task<CityAudioExportOutcome, Never>?
    /// 人按了「补交音频」「重试」的那几场:结果要说一声。自己接着交的不说,
    /// 状态上看得到。
    private var audioAsked: Set<String> = []
    private var noticeTimer: Timer?

    private init() {
        account = core?.cityAccount()
        if account != nil {
            loadLocalState()
            reloadFilings()
        }
    }

    /// 启动时调用:把上次没交完的接着交,并在网络回来时、切回 App 时再试。
    func start() {
        guard started == false else { return }
        started = true
        offline = NetworkReachability.shared.isOffline
        NetworkReachability.shared.$isOffline
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] offline in
                self?.offline = offline
                if offline == false { self?.retryPending() }
            }
            .store(in: &observers)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.appBecameActive() }
            .store(in: &observers)
        // 上一回没来得及删的临时文件:编好的音频不留在盘上。此刻还没有哪
        // 一场在导出。
        CityAudioExport.sweep()
        retryPending()
        scheduleRetries()
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
        reloadFilings()
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
        nextWithholdsAudio = false
        cancelConfirmedDestination()
        activeFiling = nil
        activeDestinationCleared = false
        filings = [:]
        filingList = []
        filingsRevision += 1
        // 正在交的那一场交完手上这一段就停;排着的不再交。
        audioTask?.cancel()
        audioQueue.removeAll()
        audioAsked = []
        audioUpload = nil
        audioProblems = [:]
        scheduleRetries()
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
            let turnedAudioOn = next.audio && options.audio == false
            options = next
            // 「带不带音频」写在每一份记录上:读回来,各处的状态才跟得上。
            reloadFilings()
            // 关着的时候停下的那几场,开了接着交;关掉不用管,正在交的那一场
            // 在下一段之前自己会问。
            if turnedAudioOn { resumeAudio() }
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
                // 交上去的那几场,活动还在不在,核心照这份新列表重新对。
                reloadFilings()
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

    /// 下一场录音交不交音频。只能往少里选:设置里关着的时候,这里说「交」
    /// 也不交。
    func setNextWithholdsAudio(_ withhold: Bool) {
        if nextWithholdsAudio != withhold {
            nextWithholdsAudio = withhold
        }
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
        // 「不交音频」也只管这一场。
        let withholdsAudio = nextWithholdsAudio
        nextWithholdsAudio = false
        guard account != nil, let event else { return }
        Task {
            let filing = await bind(sessionId: sessionId, event: event)
            if withholdsAudio, filing != nil {
                await setSessionAudio(sessionId: sessionId, enabled: false)
            }
        }
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
        remember(filing, sessionId: sessionId)
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

    /// 一场录音此刻交到哪一步了,全 App 同一套说法(`CityFilingStatus`)。
    func status(sessionId: String) -> CityFilingStatus {
        let uploading = audioUpload?.sessionId == sessionId
        return CityFilingStatus.resolve(
            filings[sessionId],
            busy: busySessions.contains(sessionId),
            offline: offline,
            signer: account?.personName,
            audioUploading: uploading,
            audioPlanned: uploading ? audioUpload?.total : nil,
            audioMissing: audioProblems[sessionId] == .missing,
            audioUnreadable: audioProblems[sessionId] == .unreadable
        )
    }

    /// 各种状态各有几场,连同音频这一路。设置里的表、侧栏底部那一行用。
    var tally: CityFilingTally {
        CityFilingTally.count(
            filingList,
            busy: busySessions,
            audioUploading: audioUpload?.sessionId,
            audioMissing: Set(audioProblems.filter { $0.value == .missing }.keys),
            audioUnreadable: Set(audioProblems.filter { $0.value == .unreadable }.keys)
        )
    }

    /// 读一场录音交得怎么样。核心顺带重算改了几句,长录音要一会儿,所以在
    /// 后台读。
    @discardableResult
    func loadFiling(sessionId: String) async -> FfiCityFiling? {
        guard account != nil, let core else { return nil }
        let filing = await Task.detached { core.cityFiling(sessionId: sessionId) }.value
        guard account != nil else { return nil }
        // 交、更新、撤下正在路上:它回来时带的才是准的,这一份读在它之前。
        guard busySessions.contains(sessionId) == false else { return filings[sessionId] }
        remember(filing, sessionId: sessionId)
        return filing
    }

    /// 这场录音的起止。补归、换活动时,时间重合的活动排最前。
    func recordingSpan(sessionId: String) async -> CityRecordingSpan? {
        guard let core else { return nil }
        return await Task.detached { () -> CityRecordingSpan? in
            guard let info = try? core.getSession(id: sessionId) else { return nil }
            return CityRecordingSpan(
                start: Date(timeIntervalSince1970: TimeInterval(info.createdAtUnixMs) / 1_000),
                duration: TimeInterval(info.durationMs) / 1_000
            )
        }.value
    }

    /// 选(或用 nil 清掉)一场录音归到的活动。录音前、录音中、录完以后都能改;
    /// 已经交上去的要先撤下才能换(见 `move`)。
    @discardableResult
    func bind(sessionId: String, event: FfiCityEvent?) async -> FfiCityFiling? {
        guard account != nil, let core else { return nil }
        // 这一场正有东西在路上(自动重试可能就在人按下的前一刻开始):等它回来
        // 再改。中途把去向清掉或换掉,发出去的那一份和本机的账就对不上了。
        // 界面上这时本来就不给按,这里是防那一刻的先后。
        guard busySessions.contains(sessionId) == false else { return filings[sessionId] }
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

    /// 换一场活动。还没交上去的直接换。已经交上去的,核心不让直接换 ——
    /// 换了,档案馆里那一件还挂在原来那场下面 —— 所以先撤下,撤成了再归到
    /// 新的一场:人按的是一下,这里按顺序做两步。撤不下来就停在原处,照实说。
    /// 归好以后还没交:再往外发一次,要人自己按「交到档案馆」。
    @discardableResult
    func move(sessionId: String, to event: FfiCityEvent) async -> FfiCityFiling? {
        guard filings[sessionId]?.state == .filed else {
            return await bind(sessionId: sessionId, event: event)
        }
        let withdrawn = await send(sessionId: sessionId, announce: false) { core in
            try core.cityWithdrawFiling(sessionId: sessionId)
        }
        // 抛错的那几种 `send` 已经说过了。
        guard let withdrawn else { return nil }
        guard withdrawn.state == .withdrawn else {
            ToastCenter.shared.error(
                String(localized: "city.toast.move_failed"),
                detail: CityText.message(forCode: withdrawn.errorCode, signer: account?.personName)
            )
            return withdrawn
        }
        return await bind(sessionId: sessionId, event: event)
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
        let filing = await send(sessionId: sessionId, announce: false) { core in
            try core.cityUpdateFiling(sessionId: sessionId)
        }
        // 没更新成时核心不抛错:状态留在「已交」,原因写在 errorCode 里。不说
        // 的话,人按了「更新」却什么都没发生。
        if let filing, let code = filing.errorCode, code != CityText.eventGoneCode {
            ToastCenter.shared.error(
                String(localized: "city.toast.update_failed"),
                detail: CityText.message(forCode: code, signer: account?.personName)
            )
        }
        return filing
    }

    /// 从档案馆撤下。
    @discardableResult
    func withdraw(sessionId: String) async -> FfiCityFiling? {
        let filing = await send(sessionId: sessionId, announce: false) { core in
            try core.cityWithdrawFiling(sessionId: sessionId)
        }
        guard let filing else { return nil }
        if filing.state == .withdrawn {
            ToastCenter.shared.success(String(localized: "city.toast.withdrawn"))
        } else {
            // 没撤下来:东西还在档案馆。和更新一样,核心只把原因写在记录上。
            ToastCenter.shared.error(
                String(localized: "city.toast.withdraw_failed"),
                detail: CityText.message(forCode: filing.errorCode, signer: account?.personName)
            )
        }
        return filing
    }

    /// 交、更新、撤下共用的一段。这三个调用没交成也把那一份记录还回来:没连
    /// 上是「排队」,被拒是「没交上」,都写在 `state` 和 `errorCode` 里;只有
    /// 没登录、没归活动、同一场正在交才抛错。
    private func send(
        sessionId: String,
        announce: Bool,
        _ call: @escaping @Sendable (any ZuTalkCoreProtocol) throws -> FfiCityFiling
    ) async -> FfiCityFiling? {
        guard account != nil, let core, busySessions.contains(sessionId) == false else { return nil }
        busySessions.insert(sessionId)
        // 这一场的音频正在交:让它交完手上这一段就停,文字这件事先办。核心
        // 一场录音同时只办一件事,不让路的话这一下会被当成「正在交」挡回来。
        await yieldAudio(sessionId: sessionId)
        let result = await Task.detached { Result { try call(core) } }.value
        busySessions.remove(sessionId)
        guard account != nil else { return nil }
        switch result {
        case .success(let filing):
            remember(filing, sessionId: sessionId)
            reloadFilings()
            if announce { self.announce(filing) }
            // 文字交上去了、音频该交:接着交。更新完的那一场也从这里接回去。
            followWithAudio(filing)
            pumpAudio()
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
            // 会自己再试,所以是一句交代,不是报错。「没有联网」只在系统确认
            // 没有网络时才说;否则只是去城的那条路一时不通。
            ToastCenter.shared.info(String(localized: offline
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

    /// 记下一场的新结果(nil 是这一场不再归任何活动)。按录音查的那一份和
    /// 排好序的那一份一起改,免得两处对不上。
    private func remember(_ filing: FfiCityFiling?, sessionId: String) {
        filingsRevision += 1
        if filings[sessionId] != filing {
            filings[sessionId] = filing
        }
        if let filing {
            if let at = filingList.firstIndex(where: { $0.sessionId == sessionId }) {
                if filingList[at] != filing { filingList[at] = filing }
            } else {
                // 刚归的一场,就是最近动过的。
                filingList.insert(filing, at: 0)
            }
        } else if filingList.contains(where: { $0.sessionId == sessionId }) {
            filingList.removeAll { $0.sessionId == sessionId }
        }
        if sessionId == activeSessionId, activeFiling != filing {
            activeFiling = filing
        }
        scheduleRetries()
    }

    /// 把归过活动的每一场重读一遍。读的是本机的账,不走网络,但仍在后台读。
    /// 同一时间只读一趟;读的途中又有人要读、或有单场的新结果进来,就再读
    /// 一趟,不拿可能已经旧了的那一份盖掉新的。
    func reloadFilings() {
        guard account != nil, let core else { return }
        guard reloadingFilings == false else {
            reloadFilingsAgain = true
            return
        }
        reloadingFilings = true
        reloadFilingsAgain = false
        let revision = filingsRevision
        Task {
            let list = await Task.detached { core.cityFilings() }.value
            reloadingFilings = false
            guard account != nil else { return }
            if reloadFilingsAgain || revision != filingsRevision {
                reloadFilings()
                return
            }
            let merged = Self.carryingChangedCounts(from: filings, into: list)
            if merged != filingList { filingList = merged }
            let index = Dictionary(merged.map { ($0.sessionId, $0) }, uniquingKeysWith: { first, _ in first })
            if index != filings { filings = index }
            scheduleRetries()
        }
    }

    /// 整张单子不数「交上去以后改了几句」(数一遍要读整场转录稿),一律给 0;
    /// 逐场读到过的数先留着,不让一次重读把「改了 6 句」冲成「已交」。交的
    /// 是不是同一次,看交上去的时刻。
    nonisolated static func carryingChangedCounts(
        from known: [String: FfiCityFiling],
        into list: [FfiCityFiling]
    ) -> [FfiCityFiling] {
        list.map { fresh in
            guard fresh.state == .filed,
                  fresh.changedSentences == 0,
                  let before = known[fresh.sessionId],
                  before.state == .filed,
                  before.filedAtEpoch == fresh.filedAtEpoch,
                  before.changedSentences > 0
            else { return fresh }
            var kept = fresh
            kept.changedSentences = before.changedSentences
            return kept
        }
    }

    /// 设置里那张表出现时调用:把已交的每一场各读一遍,数出交上去以后改了
    /// 几句。一场一场在后台读,不抢正在交的那一场。
    func refreshChangedCounts() {
        guard account != nil, countingChanges == false else { return }
        countingChanges = true
        let sessions = filingList.filter { $0.state == .filed }.map(\.sessionId)
        Task {
            for sessionId in sessions {
                guard account != nil else { break }
                await loadFiling(sessionId: sessionId)
            }
            countingChanges = false
        }
    }

    // MARK: - 排队的

    /// 把还在排队的一场一场交上去。启动时、网络回来时、切回 App 时调用,
    /// 还有排着队的期间每两分钟一次。同一时间只跑一趟。
    func retryPending() {
        guard account != nil, retryingPending == false, let core,
              NetworkReachability.shared.isOffline == false
        else { return }
        retryingPending = true
        lastRetryAt = Date()
        Task {
            let pending = await Task.detached { core.cityPendingSessions() }.value
            for sessionId in pending {
                guard account != nil else { break }
                let filing = await file(sessionId: sessionId, announce: false)
                // 这回有了结果要说一声:交上了,或者这回是被拒的(不会再自己
                // 试了)。还是没连上的不再弹一遍,录音上、侧栏底部都看得到。
                if let filing, filing.state == .filed || filing.state == .failed {
                    announce(filing)
                }
            }
            retryingPending = false
            // 文字都试过了,再把该交音频的接着交。
            resumeAudio()
        }
    }

    /// 还有排着队的就定时再试,没有了就停表。去城的那条路常有一阵连不上而
    /// 机器一直在线,「网络回来」那一下等不到;以前这样的一场要等到下次启动。
    private func scheduleRetries() {
        let waiting = started && account != nil
            && filingList.contains { $0.state == .queued || audioWillRetry($0) }
        guard waiting else {
            retryTimer?.invalidate()
            retryTimer = nil
            return
        }
        guard retryTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: Self.retryInterval, repeats: true) { _ in
            Task { @MainActor in CityStore.shared.retryPending() }
        }
        // 晚几秒无所谓,让系统把它和别的唤醒凑到一起。
        timer.tolerance = 10
        retryTimer = timer
    }

    /// 切回 App:账重读一遍(便宜,只读本机);有排着队的、离上一次又够久,
    /// 顺手再试。
    private func appBecameActive() {
        guard account != nil else { return }
        reloadFilings()
        let queued = filingList.contains { $0.state == .queued || audioWillRetry($0) }
        if Self.retriesOnActivation(queued: queued, lastRetryAt: lastRetryAt, now: Date()) {
            retryPending()
        }
    }

    static func retriesOnActivation(queued: Bool, lastRetryAt: Date?, now: Date) -> Bool {
        guard queued else { return false }
        guard let lastRetryAt else { return true }
        return now.timeIntervalSince(lastRetryAt) >= activationRetryGap
    }

    // MARK: - 音频

    /// 这一场的音频是不是会自己接着交:该交,又不是「城没收」「一段太大」
    /// 那两种再试也一样的。排着这样的录音时,定时再试的那块表不停。
    static func audioRetriesItself(_ filing: FfiCityFiling) -> Bool {
        guard filing.audioDue else { return false }
        return filing.audioErrorCode != CityText.audioRefusedCode
            && filing.audioErrorCode != CityText.audioTooBigCode
    }

    /// 同上,再除掉这台 Mac 上已经没有音频、或者没导出来的:那几场这一次
    /// 运行里不会自己再试,不为它们让表一直走。
    private func audioWillRetry(_ filing: FfiCityFiling) -> Bool {
        Self.audioRetriesItself(filing) && audioProblems[filing.sessionId] == nil
    }

    /// 这一场交不交音频。关掉:设置里开着,这一场也不交;打开:只是不再单独
    /// 关着,设置里关着时仍然不交。已经交上去的音频撤不回来 —— 正在传的那
    /// 一段会传完,之后不再交。
    @discardableResult
    func setSessionAudio(sessionId: String, enabled: Bool) async -> FfiCityFiling? {
        guard account != nil, let core else { return nil }
        let result = await Task.detached {
            Result { try core.citySetSessionAudio(sessionId: sessionId, enabled: enabled) }
        }.value
        guard account != nil else { return nil }
        switch result {
        case .success(let filing):
            remember(filing, sessionId: sessionId)
            if enabled {
                followWithAudio(filing)
                pumpAudio()
            }
            return filing
        case .failure(let error):
            ToastCenter.shared.error(
                String(localized: "city.options.save_failed"),
                detail: CityText.describe(error, signer: account?.personName)
            )
            noteFailure(error)
            return nil
        }
    }

    /// 人按了「补交音频」或音频的「重试」。文字交上去而音频没交的录音(这
    /// 一版以前交的、当时关着的、城没收下的)只从这里开始:不替人开口。
    func fileAudio(sessionId: String) {
        guard account != nil else { return }
        audioAsked.insert(sessionId)
        // 上一回说没有、没导出来的,人要再试就再试一次。
        if audioProblems[sessionId] != nil {
            audioProblems[sessionId] = nil
        }
        audioQueue.add(sessionId, first: true)
        pumpAudio()
    }

    /// 把该交音频、现在去交有用的录音接着交。启动时、切回 App 时、网络回来
    /// 时调用,还有排着的期间每两分钟一次。哪几场由核心说了算。
    func resumeAudio() {
        guard account != nil, let core, NetworkReachability.shared.isOffline == false else { return }
        Task {
            let pending = await Task.detached { core.cityPendingAudioSessions() }.value
            guard account != nil else { return }
            for sessionId in pending where audioProblems[sessionId] == nil {
                audioQueue.add(sessionId)
            }
            pumpAudio()
        }
    }

    /// 文字刚交上去(或刚更新完)的这一场,音频该交就排上。
    private func followWithAudio(_ filing: FfiCityFiling) {
        guard filing.state == .filed, filing.audioDue,
              audioProblems[filing.sessionId] == nil
        else { return }
        audioQueue.add(filing.sessionId)
    }

    /// 手上没有在交的,就取下一场开始交。
    private func pumpAudio() {
        guard account != nil, audioTask == nil, let core,
              let sessionId = audioQueue.next(skipping: busySessions)
        else { return }
        audioUpload = CityAudioUpload(sessionId: sessionId, total: 0)
        let source = CityAudioExportCore(core: core)
        let run = CityAudioExportRun(filing: source, audio: source)
        let task = Task.detached(priority: .utility) { () -> CityAudioExportOutcome in
            run.run(
                sessionId: sessionId,
                shouldStop: { Task.isCancelled },
                began: { total in
                    Task { @MainActor in
                        CityStore.shared.audioBegan(sessionId: sessionId, total: total)
                    }
                },
                progress: { filing in
                    Task { @MainActor in
                        CityStore.shared.audioProgressed(filing)
                    }
                }
            )
        }
        audioTask = task
        Task {
            let outcome = await task.value
            audioFinished(sessionId: sessionId, outcome: outcome)
        }
    }

    private func audioBegan(sessionId: String, total: UInt32) {
        guard audioUpload?.sessionId == sessionId, audioUpload?.total != total else { return }
        audioUpload?.total = total
    }

    /// 交完一段:记下最新的那一份。一段五分钟的录音才来一次,不是每一拍。
    private func audioProgressed(_ filing: FfiCityFiling) {
        // 这一趟已经收尾了的,结果里带着更新的一份,晚到的这一份不要。
        guard account != nil, audioUpload?.sessionId == filing.sessionId else { return }
        remember(filing, sessionId: filing.sessionId)
    }

    private func audioFinished(sessionId: String, outcome: CityAudioExportOutcome) {
        audioTask = nil
        audioQueue.finish(sessionId)
        if audioUpload?.sessionId == sessionId { audioUpload = nil }
        let asked = audioAsked.remove(sessionId) != nil
        guard account != nil else { return }
        switch outcome {
        case .finished(let filing):
            if let filing {
                remember(filing, sessionId: sessionId)
            } else {
                Task { await loadFiling(sessionId: sessionId) }
            }
            if asked {
                ToastCenter.shared.success(String(localized: "city.toast.audio_filed"))
            }
        case .stopped(let filing):
            remember(filing, sessionId: sessionId)
            // 城没收、太大:不会再自己试,要让人知道。别的几种会自己接着交,
            // 状态上看得到;人开口要的那一回才说。
            let final = filing.audioErrorCode == CityText.audioRefusedCode
                || filing.audioErrorCode == CityText.audioTooBigCode
            if final || asked {
                ToastCenter.shared.error(
                    String(format: String(localized: "city.toast.audio_stopped_format"), filing.eventTitle),
                    detail: CityText.message(forCode: filing.audioErrorCode, signer: account?.personName)
                )
            }
        case .held(let code):
            // 设置关了、这一场关了、撤下了、今天到上限了:账上都有,读回来
            // 照实显示。
            Task { await loadFiling(sessionId: sessionId) }
            if asked {
                ToastCenter.shared.error(
                    String(localized: "city.toast.audio_failed"),
                    detail: CityText.message(forCode: code, signer: account?.personName)
                )
            }
        case .noAudio:
            // 没有可交的:是状态,不是出错。
            audioProblems[sessionId] = .missing
            if asked {
                ToastCenter.shared.info(String(localized: "city.audio.reason.missing"))
            }
        case .interrupted:
            // 给这一场的别的事(更新、撤下)让路。那件事还在办的话,办完会把
            // 它再排上;已经办完了,就照办完以后的样子现在排上 —— 撤下了的
            // 不会再排。
            if let filing = filings[sessionId] { followWithAudio(filing) }
        case .failed(let code):
            if code == "city.error.signed_out", core?.cityAccount() == nil {
                forgetAccount()
                return
            }
            // 核心说这一场正忙:不是出了错,下一轮再来。
            if code == "city.error.busy" { break }
            // 没导出来:这一次运行里不再自己试,人按「重试」才再试。状态上
            // 写着,侧栏底部那一行也算它一场。
            if code == nil { audioProblems[sessionId] = .unreadable }
            Task { await loadFiling(sessionId: sessionId) }
            if asked {
                ToastCenter.shared.error(
                    String(localized: "city.toast.audio_failed"),
                    detail: CityText.message(
                        forCode: code ?? "city.error.audio_bad_part",
                        signer: account?.personName
                    )
                )
            }
        }
        pumpAudio()
        scheduleRetries()
    }

    /// 这一场的音频正在交:叫它交完手上这一段就停,等它停下。
    private func yieldAudio(sessionId: String) async {
        guard audioUpload?.sessionId == sessionId, let task = audioTask else { return }
        task.cancel()
        _ = await task.value
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
