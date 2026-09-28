// ShareActivityStore.swift
// 共享的唯一状态源:直播、共享录音、看别人的、敲门、收到的文字稿。
//
// 共享以前散在一个分享页的视图模型里:切走标签页状态就丢,录音条、
// 菜单栏、字幕窗各自再问一遍核心,彼此说法不一。现在只有这里问核心,
// 其余表面只读这里 —— 录音条上的「直播中」、顶栏的「正在看」、侧边栏
// 的角标、字幕窗的远端画布,说的是同一件事。
//
// 轮询节奏:看直播时 0.2 秒(远端帧是 replace-in-full 的,轮询与回调
// 观感等价,但要跟上说话的速度);主持时 1 秒(谁在看、谁在敲门);
// 空闲 2 秒(纯内存读取)。

import AppKit
import Combine
import Foundation

@MainActor
final class ShareActivityStore: ObservableObject {
    static let shared = ShareActivityStore()

    // MARK: 主持

    /// 本机正在共享(直播或一段录音)。
    @Published private(set) var isHosting = false
    /// 正在共享的是这场正在录的直播;`false` 是一段录好的录音。
    @Published private(set) var isLive = false
    /// 对方的 ZuTalk 会留下文字稿。
    @Published private(set) var keepsCopies = false
    /// 同一网络的人能在附近列表里看到名字与标题。
    @Published private(set) var discoverable = false
    /// 对方只能看,不能订正。
    @Published private(set) var hostOnly = false
    /// 这一场共享的录音(主持或观看)。
    @Published private(set) var scopeSessionId: String?
    /// 加入码。只有主持时有。
    @Published private(set) var shareCode: String?
    /// 直播已经播出过字幕 —— 区分「还没人说话」与「在播」。
    @Published private(set) var hasBroadcast = false
    /// 房间里除了自己之外的人。
    @Published private(set) var watchers: [FfiRoomMember] = []
    /// 等着回答的加入请求。
    @Published private(set) var pendingJoinRequests: [FfiJoinRequest] = []
    @Published private(set) var webShare: FfiWebShareInfo?
    @Published private(set) var webShareStarting = false

    // MARK: 观看

    @Published private(set) var isViewing = false
    /// 主持人明确结束了这一场。
    @Published private(set) var hostLeft = false
    /// 主持人把本机移出了。
    @Published private(set) var removedByHost = false
    /// 这一场的标题与主持人的名字,来自主持人随帧带来的说明。
    @Published private(set) var title = ""
    @Published private(set) var hostName = ""
    @Published private(set) var viewerLink: FfiShareLinkPath?
    /// 主播最新一帧的完整预览;旧版主播只发压扁行时为 nil。
    @Published private(set) var remotePreview: FfiNotebookCaptureLivePreview?
    @Published private(set) var remoteLines: [FfiSharedCaptionLine] = []

    // MARK: 收到的与附近

    @Published private(set) var received: [FfiSharedSessionInfo] = []
    @Published private(set) var nearby: [FfiNearbyPeer] = []
    /// 第一次找附近的共享还没有结果。之后列表为空就是真的没有。
    @Published private(set) var nearbySearching = false
    /// 设置里关了局域网发现:附近的共享看不到,也别让人以为还在找。
    @Published private(set) var nearbyDiscoveryOff = false
    /// 正在等哪一场的主持人回答。最长一分钟,必须说出来,还要能放弃。
    @Published private(set) var askingPeer: String?
    /// 别人看到的本机名字。默认是这台 Mac 的名字。
    @Published private(set) var displayName = ""
    /// 开始、加入这类要一会儿的动作进行中。
    @Published private(set) var isBusy = false

    /// 要共享哪一段录好的录音。主窗口据此弹出共享面板;入口在录音行的
    /// 菜单、录音页顶栏与顶栏的「共享中」。
    @Published var recordingShareRequest: RecordingShareRequest?

    /// 在任何一场共享里(主持或观看)。
    var isInRoom: Bool { isHosting || isViewing }

    private var core: (any ZuTalkCoreProtocol)? { CoreClient.shared.core }
    private var timer: Timer?
    private var currentInterval: TimeInterval = 0
    private var announcedRequestIds: Set<String> = []
    private var askGeneration = 0
    private var nearbyWatchers = 0
    private var lastNearbyScan: Date?
    private var lastSlowRefresh: Date?
    /// 直播所属的录音不在录了,连续几拍都如此才收场 —— 刚开始的那一瞬间
    /// 采集状态可能还没跟上。
    private var liveOrphanTicks = 0

    private init() {}

    /// 开始全局轮询。可重复调用;只会有一个定时器。
    func start() {
        if displayName.isEmpty { loadDisplayName() }
        poll()
        reschedule()
        refreshReceived()
    }

    func presentRecordingShare(sessionId: String, title: String) {
        recordingShareRequest = RecordingShareRequest(sessionId: sessionId, title: title)
    }

    // MARK: - 主持:直播

    /// 这一场录音此刻是不是正在直播。录音条据此亮「直播中」。
    func isBroadcasting(sessionId: String?) -> Bool {
        guard let sessionId else { return false }
        return isHosting && isLive && scopeSessionId == sessionId
    }

    /// 开始直播正在录的这一场。
    func startLiveShare(sessionId: String, keepCopies: Bool) {
        runHostStart { core in
            try core.startLiveShare(sessionId: sessionId, keepCopies: keepCopies)
        }
    }

    /// 共享一段录好的录音。对方会得到一份文字稿副本。
    func startRecordingShare(sessionId: String, readOnly: Bool) {
        runHostStart { core in
            try core.startRecordingShare(sessionId: sessionId, hostOnly: readOnly)
        }
    }

    private func runHostStart(_ start: @escaping (any ZuTalkCoreProtocol) throws -> String) {
        guard let core, isBusy == false else { return }
        ensureDisplayName()
        isBusy = true
        // 进房间要等网络层,不放在主线程上。
        Task.detached {
            let result = Result { try start(core) }
            await MainActor.run {
                self.isBusy = false
                switch result {
                case .success(let code):
                    self.shareCode = code
                    self.enrollForRelayFallback()
                case .failure(let error):
                    ToastCenter.shared.error(
                        String(localized: "share.start_failed"),
                        detail: error.localizedDescription
                    )
                }
                self.poll()
                self.reschedule()
            }
        }
    }

    /// 允许观看的人保存文字稿。只能打开,不能收回。
    func allowKeepingCopies() {
        guard let core else { return }
        do {
            try core.allowViewersToKeepCopies()
        } catch {
            ToastCenter.shared.error(
                String(localized: "share.live.keep_failed"),
                detail: error.localizedDescription
            )
        }
        poll()
    }

    func setDiscoverable(_ on: Bool) {
        guard let core else { return }
        if on { ensureDisplayName() }
        do {
            try core.setShareDiscoverable(discoverable: on)
        } catch {
            ToastCenter.shared.error(error.localizedDescription)
        }
        poll()
    }

    func removeWatcher(_ member: FfiRoomMember) {
        guard let core else { return }
        do {
            _ = try core.removeShareMember(endpointId: member.endpointId)
        } catch {
            ToastCenter.shared.error(error.localizedDescription)
        }
        poll()
    }

    func approve(_ request: FfiJoinRequest) {
        guard let core else { return }
        if (try? core.approveJoinRequest(requestId: request.requestId)) != true {
            ToastCenter.shared.warning(String(localized: "share.knock.expired"))
        }
        poll()
    }

    func decline(_ request: FfiJoinRequest) {
        guard let core else { return }
        _ = core.declineJoinRequest(requestId: request.requestId)
        poll()
    }

    /// 停止共享。已经给出去的内容收不回 —— 界面在按钮旁边说这句话。
    func stopSharing() {
        guard let core else { return }
        do {
            try core.stopSharing()
        } catch {
            ToastCenter.shared.error(error.localizedDescription)
        }
        shareCode = nil
        poll()
        reschedule()
    }

    func copyShareCode() {
        guard let shareCode else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(shareCode, forType: .string)
        ToastCenter.shared.success(String(localized: "share.code.copied"))
    }

    // MARK: - 主持:网页

    /// 开网页链接。建房走网络,连不上时要等十秒,不在主线程上等。
    func startWebShare() {
        guard let core, webShareStarting == false else { return }
        webShareStarting = true
        Task.detached {
            let result = Result { try core.startWebShare(serviceUrl: nil) }
            await MainActor.run {
                self.webShareStarting = false
                switch result {
                case .success(let info):
                    self.webShare = info
                case .failure(let error):
                    ToastCenter.shared.error(
                        String(localized: "share.web.failed"),
                        detail: error.localizedDescription
                    )
                }
            }
        }
    }

    func stopWebShare() {
        core?.stopWebShare()
        webShare = nil
    }

    func copyWebLink() {
        guard let webShare else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(webShare.viewerUrl, forType: .string)
        ToastCenter.shared.success(String(localized: "share.web.copied"))
    }

    // MARK: - 观看

    /// 用加入码加入。返回错误的说法,成功时为 nil。
    func join(code rawCode: String) async -> String? {
        guard let core else { return String(localized: "share.core_unavailable") }
        let code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.isEmpty == false else { return nil }
        guard confirmLeavingCurrentShare() else { return nil }
        ensureDisplayName()
        isBusy = true
        let result = await Task.detached { Result { try core.joinShare(code: code) } }.value
        isBusy = false
        poll()
        reschedule()
        switch result {
        case .success:
            enrollForRelayFallback()
            return nil
        case .failure:
            // 核心的原因是给日志看的,不在界面上拼一句别的语言。
            return String(localized: "share.join_failed")
        }
    }

    /// 请求加入附近的一场直播。主持人点头后自动进来。
    func askToJoin(_ peer: FfiNearbyPeer) {
        guard let core, askingPeer == nil else { return }
        guard confirmLeavingCurrentShare() else { return }
        ensureDisplayName()
        askingPeer = peer.endpointId
        askGeneration += 1
        let generation = askGeneration
        let endpointId = peer.endpointId
        // 它会一直等到对方回答或超时 —— 最长一分钟。
        Task.detached {
            let result = Result { try core.requestToJoinNearby(endpointId: endpointId) }
            await MainActor.run {
                guard generation == self.askGeneration else { return }
                self.askingPeer = nil
                switch result {
                case .success(.joined):
                    self.enrollForRelayFallback()
                case .success(.notSharing):
                    ToastCenter.shared.info(String(localized: "share.nearby.not_sharing"))
                case .success(.declined):
                    ToastCenter.shared.info(String(localized: "share.nearby.declined"))
                case .success(.timedOut):
                    ToastCenter.shared.info(String(localized: "share.nearby.timed_out"))
                case .failure(let error):
                    ToastCenter.shared.error(error.localizedDescription)
                }
                self.poll()
                self.reschedule()
            }
        }
    }

    /// 不等了。对方那边的请求会自己超时消失。
    func abandonAsk() {
        askGeneration += 1
        askingPeer = nil
    }

    /// 离开别人的直播,或者关掉已经结束的那一场。
    func leave() {
        guard let core, isViewing else { return }
        try? core.stopSharing()
        poll()
        reschedule()
        refreshReceived()
    }

    /// 开始录音前:在看别人的直播就先问一句。录音与观看不能同时进行 ——
    /// 两路内容会拧在一起。返回 `true` 表示可以继续录音。
    func confirmLeavingToRecord() -> Bool {
        guard isViewing else { return true }
        if hostLeft || removedByHost {
            leave()
            return true
        }
        let alert = NSAlert()
        alert.messageText = String(
            format: String(localized: "share.leave_to_record.title_format"),
            hostDisplayName
        )
        alert.informativeText = String(localized: "share.leave_to_record.body")
        alert.addButton(withTitle: String(localized: "share.leave_to_record.confirm"))
        alert.addButton(withTitle: String(localized: "common.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        leave()
        return true
    }

    /// 已经在一场共享里时再加入别的:主持中不行,观看中先问。
    private func confirmLeavingCurrentShare() -> Bool {
        if isHosting {
            ToastCenter.shared.warning(String(localized: "share.join.while_hosting"))
            return false
        }
        guard isViewing, hostLeft == false, removedByHost == false else { return true }
        let alert = NSAlert()
        alert.messageText = String(
            format: String(localized: "share.switch.title_format"),
            hostDisplayName
        )
        alert.addButton(withTitle: String(localized: "share.switch.confirm"))
        alert.addButton(withTitle: String(localized: "common.cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// 主持人没报名字时的称呼。
    var hostDisplayName: String {
        hostName.isEmpty ? String(localized: "share.someone") : hostName
    }

    // MARK: - 收到的与附近

    func refreshReceived() {
        guard let core else { return }
        let list = core.listSharedSessions()
        if list != received { received = list }
    }

    func deleteReceived(_ info: FfiSharedSessionInfo) {
        guard let core else { return }
        do {
            try core.deleteSharedSession(sessionId: info.sessionId)
        } catch {
            ToastCenter.shared.error(error.localizedDescription)
        }
        refreshReceived()
    }

    /// 一份收到的文字稿能不能订正:只有正在同步、而主持人设了只读的那一份不能。
    /// 散场后的副本都是本机的,随便改。
    func canEditReceived(_ sessionId: String) -> Bool {
        let stillSyncing = isViewing && hostLeft == false && removedByHost == false
        return !(stillSyncing && hostOnly && scopeSessionId == sessionId)
    }

    /// 「收到的」页出现时开始找附近的直播,离开时停。
    func beginWatchingNearby() {
        nearbyWatchers += 1
        nearbyDiscoveryOff = core?.shareTransport().enableLocalDiscovery == false
        if nearbyDiscoveryOff {
            nearby = []
            return
        }
        if nearby.isEmpty { nearbySearching = true }
        scanNearby()
    }

    func endWatchingNearby() {
        nearbyWatchers = max(0, nearbyWatchers - 1)
    }

    private func scanNearby() {
        guard let core, nearbyDiscoveryOff == false else { return }
        lastNearbyScan = Date()
        Task.detached {
            // 第一次可能要等宣告到达;之后是常驻表的快照,立即返回。
            let peers = (try? core.nearbyPeers(seconds: 2)) ?? []
            await MainActor.run {
                self.nearbySearching = false
                if peers != self.nearby { self.nearby = peers }
            }
        }
    }

    // MARK: - 名字

    func setDisplayName(_ name: String) {
        guard let core else { return }
        try? core.setShareDisplayName(name: name)
        displayName = core.shareDisplayName()
    }

    private func loadDisplayName() {
        guard let core else { return }
        displayName = core.shareDisplayName()
    }

    /// 没起过名字就用这台 Mac 的名字 —— 敲门与「谁在看」里不该只是一串公钥。
    private func ensureDisplayName() {
        guard let core else { return }
        if core.shareDisplayName().isEmpty,
           let machine = Host.current().localizedName,
           machine.isEmpty == false {
            try? core.setShareDisplayName(name: machine)
        }
        displayName = core.shareDisplayName()
    }

    private func enrollForRelayFallback() {
        Task { await CommunityInviteSession.shared.enrollCurrentShareEndpoint() }
    }

    // MARK: - 轮询

    private func reschedule() {
        let wanted: TimeInterval = isViewing ? 0.2 : (isHosting ? 1 : 2)
        guard timer == nil || currentInterval != wanted else { return }
        timer?.invalidate()
        currentInterval = wanted
        timer = Timer.scheduledTimer(withTimeInterval: wanted, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    private func poll() {
        guard let core else { return }
        let state = core.shareState()

        let hosting = state.isHost
        let viewing = state.isViewing
        set(\.isHosting, hosting)
        set(\.isLive, state.isLive)
        set(\.keepsCopies, state.keepsCopies)
        set(\.discoverable, state.discoverable)
        set(\.hostOnly, state.hostOnly)
        set(\.scopeSessionId, state.scopeSessionId)
        set(\.hasBroadcast, state.broadcastRevision != nil)
        set(\.hostLeft, state.hostLeft)
        set(\.removedByHost, state.removedByHost)
        set(\.title, state.title)
        set(\.hostName, state.hostName)
        set(\.viewerLink, state.viewerLink)
        if isViewing != viewing {
            isViewing = viewing
            reschedule()
            if viewing == false { refreshReceived() }
        }
        if hosting {
            if shareCode == nil { shareCode = core.currentShareCode() }
        } else if shareCode != nil {
            shareCode = nil
        }

        // 帧内容:只在真的变了时发布 —— 0.2 秒一拍,恒等发布会让整棵
        // 依赖树白刷。revision 只在单场录音内单调,所以信号是一对。
        if viewing {
            let incoming = state.remotePreview.map { ($0.sessionId, $0.previewRevision) }
            let current = remotePreview.map { ($0.sessionId, $0.previewRevision) }
            if incoming?.0 != current?.0 || incoming?.1 != current?.1 {
                remotePreview = state.remotePreview
                remoteLines = state.lines
            }
        } else if remotePreview != nil || remoteLines.isEmpty == false {
            remotePreview = nil
            remoteLines = []
        }

        // 慢一些的部分:名册、敲门、网页、附近、收到的。
        let now = Date()
        if viewing == false || lastSlowRefresh.map({ now.timeIntervalSince($0) >= 1 }) ?? true {
            lastSlowRefresh = now
            slowPoll(core: core, hosting: hosting, viewing: viewing)
        }
    }

    private func slowPoll(core: any ZuTalkCoreProtocol, hosting: Bool, viewing: Bool) {
        let members = hosting
            ? core.roomMembers().filter { $0.isMe == false }
            : []
        set(\.watchers, members)

        let requests = core.pendingJoinRequests()
        for request in requests where announcedRequestIds.contains(request.requestId) == false {
            announcedRequestIds.insert(request.requestId)
            NSApp.requestUserAttention(.informationalRequest)
        }
        set(\.pendingJoinRequests, requests)

        let web = hosting ? core.webShareState() : nil
        set(\.webShare, web)

        if nearbyWatchers > 0,
           lastNearbyScan.map({ Date().timeIntervalSince($0) >= 4 }) ?? true {
            scanNearby()
        }
        if viewing, keepsCopies {
            refreshReceived()
        }

        endLiveShareIfItsRecordingEnded(hosting: hosting)
    }

    /// 直播随录音结束:录音停了,这一场也就没什么可看的了。不收场的话,
    /// 加入码与附近宣告会一直挂着,主持人以为结束了,别人还能进来。
    private func endLiveShareIfItsRecordingEnded(hosting: Bool) {
        let capture = ActiveBilingualTranscriptStore.shared
        guard hosting, isLive, let sessionId = scopeSessionId else {
            liveOrphanTicks = 0
            return
        }
        let stillRecording = capture.isCaptureActive && capture.sessionId == sessionId
        liveOrphanTicks = stillRecording ? 0 : liveOrphanTicks + 1
        guard liveOrphanTicks >= 2 else { return }
        liveOrphanTicks = 0
        stopSharing()
        ToastCenter.shared.info(String(localized: "share.live.ended_with_recording"))
    }

    private func set<Value: Equatable>(
        _ keyPath: ReferenceWritableKeyPath<ShareActivityStore, Value>,
        _ value: Value
    ) {
        if self[keyPath: keyPath] != value {
            self[keyPath: keyPath] = value
        }
    }
}

/// 「共享这段录音」面板要的东西。
struct RecordingShareRequest: Identifiable, Equatable {
    var id: String { sessionId }
    let sessionId: String
    /// 行上显示的名字:标题,没有标题时是开头的话或时间。
    let title: String
}
