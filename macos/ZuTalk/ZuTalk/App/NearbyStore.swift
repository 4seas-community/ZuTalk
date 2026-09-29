// NearbyStore.swift
// 附近:同一个网络里的 ZuTalk 之间,不经任何服务器。
//
// 三件事(docs/architecture/local-first-sync.md §9):
//   - 接收:打开之后,附近的 Mac 看得见这台、能递文字稿过来;每一份都要这边点「接收」;
//   - 递稿:把一场录好的录音的文字稿递给附近打开了接收的 Mac;
//   - 直播:让附近的 ZuTalk 直接看这一场的实时字幕;附近有人在直播时,这边能看。
//
// 都走设备同步的同一个端点,所以同步没开的先打开(和协作主题一样)。音频从不在
// 里面。附近的名单来自局域网发现,没有回调,开着同步时两秒问一次(只读内存)。

import AppKit
import Combine
import Foundation

@MainActor
final class NearbyStore: ObservableObject {
    static let shared = NearbyStore()

    private static let receivingKey = "nearby.receiving"

    @Published private(set) var status: FfiNearbyStatus?
    /// 用户想不想接收。同步重启(比如离开设备组)之后照这个重新打开。
    @Published private(set) var receiving: Bool
    /// 正在递给哪一台(设备 id);递完或失败清掉。
    @Published private(set) var sending: Set<String> = []
    /// 正在开始看哪一台的直播。
    @Published private(set) var joining: String?

    private var core: (any ZuTalkCoreProtocol)? { CoreClient.shared.core }
    private var timer: Timer?
    /// 已经问过用户的递稿,免得每次刷新再弹一次。
    private var asked: Set<UInt64> = []
    /// 从直播面板开的那一场。录音停了,它跟着收场。
    private var startedLive: String?
    private var liveOrphanTicks = 0

    private init() {
        receiving = UserDefaults.standard.bool(forKey: Self.receivingKey)
    }

    // MARK: - 生命周期

    /// 同步起来了:把「接收」照用户的选择打开,开始轮询附近。
    func syncStarted() {
        if receiving, let core {
            try? core.nearbySetReceiving(on: true)
        }
        refresh()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor in NearbyStore.shared.tick() }
        }
    }

    func syncStopped() {
        timer?.invalidate()
        timer = nil
        status = nil
        sending = []
        joining = nil
    }

    private func tick() {
        refresh()
        endLiveIfItsRecordingEnded()
    }

    func refresh() {
        guard let core else { return }
        let next = core.nearbyStatus()
        if next != status { status = next }
        askAboutOffers(next.offers)
        for received in core.nearbyTakeReceived() {
            ToastCenter.shared.success(String(
                format: String(localized: "nearby.received_format"), received.title, received.fromName
            ))
            NotificationCenter.default.post(name: .zutalkSessionUpdated, object: nil)
        }
    }

    // MARK: - 接收

    func setReceiving(_ on: Bool) {
        receiving = on
        UserDefaults.standard.set(on, forKey: Self.receivingKey)
        Task {
            if on {
                guard await DeviceSyncStore.shared.ensureRunning() else { return }
            }
            guard let core else { return }
            try? core.nearbySetReceiving(on: on)
            refresh()
        }
    }

    /// 递稿请求:在主窗口上问一次。用户走开了也没关系 —— 两分钟没回答,发送方那边
    /// 就当作没人接。
    private func askAboutOffers(_ offers: [FfiNearbyOffer]) {
        asked.formIntersection(offers.map(\.id))
        for offer in offers where asked.contains(offer.id) == false {
            asked.insert(offer.id)
            present(offer)
        }
    }

    private func present(_ offer: FfiNearbyOffer) {
        let alert = NSAlert()
        alert.messageText = String(
            format: String(localized: "nearby.offer_title_format"),
            offer.fromName.isEmpty ? String(localized: "settings.devices.unnamed") : offer.fromName
        )
        alert.informativeText = String(
            format: String(localized: "nearby.offer_message_format"),
            offer.title,
            ByteCountFormatter.string(fromByteCount: Int64(offer.bytes), countStyle: .file)
        )
        alert.addButton(withTitle: String(localized: "nearby.offer_accept"))
        alert.addButton(withTitle: String(localized: "nearby.offer_decline"))
        let id = offer.id
        let answer: (NSApplication.ModalResponse) -> Void = { response in
            let accept = response == .alertFirstButtonReturn
            guard let core = CoreClient.shared.core else { return }
            Task.detached { core.nearbyAnswer(offerId: id, accept: accept) }
        }
        NSApp.requestUserAttention(.informationalRequest)
        guard var window = NSApp.mainWindow ?? WindowCoordinator.shared.window(for: .main) else {
            answer(alert.runModal())
            return
        }
        // 挂在最上层的那张表单上:挂在主窗口上会排在已经打开的表单后面,
        // 用户关掉它之前看不见,发送方那边两分钟后就当作没人接。
        while let sheet = window.attachedSheet {
            window = sheet
        }
        alert.beginSheetModal(for: window, completionHandler: answer)
    }

    // MARK: - 递稿

    /// 附近打开了接收的 Mac。
    var receivers: [FfiNearbyPeer] {
        (status?.peers ?? []).filter(\.receiving)
    }

    /// `title` 是这边列表里显示的名字:没起标题的录音,对方看到的也是它。
    func send(sessionId: String, title: String, to peer: FfiNearbyPeer) {
        guard let core, sending.contains(peer.deviceId) == false else { return }
        sending.insert(peer.deviceId)
        let deviceId = peer.deviceId
        let name = peer.name
        Task {
            let result = await Task.detached {
                Result { try core.nearbySendRecording(deviceId: deviceId, sessionId: sessionId, title: title) }
            }.value
            sending.remove(deviceId)
            switch result {
            case .success:
                ToastCenter.shared.success(String(format: String(localized: "nearby.sent_format"), name))
            case .failure(let error):
                ToastCenter.shared.error(
                    String(format: String(localized: "nearby.send_failed_format"), name),
                    detail: DeviceSyncStore.describe(error)
                )
            }
        }
    }

    // MARK: - 直播

    func isLive(sessionId: String) -> Bool {
        status?.liveSessionId == sessionId
    }

    func startLive(sessionId: String, title: String) {
        Task {
            guard await DeviceSyncStore.shared.ensureRunning(), let core = self.core else {
                ToastCenter.shared.error(String(localized: "nearby.live_failed"))
                return
            }
            let started = await Task.detached {
                Result { try core.nearbyStartLive(sessionId: sessionId, title: title) }
            }.value
            if case .success = started {
                startedLive = sessionId
            }
            if case .failure(let error) = started {
                ToastCenter.shared.error(
                    String(localized: "nearby.live_failed"),
                    detail: DeviceSyncStore.describe(error)
                )
            }
            refresh()
        }
    }

    func stopLive() {
        startedLive = nil
        guard let core else { return }
        Task.detached { core.nearbyStopLive() }
        Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            refresh()
        }
    }

    /// 录音停了,附近直播也跟着停:主播以为结束了,附近的人却还看着一场不会再动的字幕。
    private func endLiveIfItsRecordingEnded() {
        guard let live = status?.liveSessionId, live == startedLive else {
            liveOrphanTicks = 0
            return
        }
        let capture = ActiveBilingualTranscriptStore.shared
        let stillRecording = capture.isCaptureActive && capture.sessionId == live
        liveOrphanTicks = stillRecording ? 0 : liveOrphanTicks + 1
        guard liveOrphanTicks >= 2 else { return }
        liveOrphanTicks = 0
        stopLive()
    }

    // MARK: - 看附近的直播

    /// 附近正在直播的。
    var liveNearby: [FfiNearbyPeer] {
        (status?.peers ?? []).filter { $0.liveTitle != nil }
    }

    func watch(_ peer: FfiNearbyPeer) {
        guard let core, joining == nil else { return }
        joining = peer.deviceId
        let deviceId = peer.deviceId
        Task {
            let result = await Task.detached { Result { try core.nearbyWatch(deviceId: deviceId) } }.value
            joining = nil
            switch result {
            case .success:
                refresh()
                WindowCoordinator.shared.presentNearbyLive()
            case .failure(let error):
                ToastCenter.shared.error(
                    String(localized: "nearby.watch_failed"),
                    detail: DeviceSyncStore.describe(error)
                )
            }
        }
    }

    func stopWatching() {
        guard let core else { return }
        Task.detached { core.nearbyStopWatching() }
        Task {
            try? await Task.sleep(nanoseconds: 100_000_000)
            refresh()
        }
    }

    /// 观看窗口按节拍来取。只读内存。
    func watchState() -> FfiNearbyWatch? {
        core?.nearbyWatchState()
    }
}
