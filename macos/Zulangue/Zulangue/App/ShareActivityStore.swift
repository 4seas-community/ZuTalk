// ShareActivityStore.swift
// 分享活动的全局观察者:敲门请求不能只在分享页上可见。
//
// 「附近的人」的加入请求最长等一分钟就超时。主持人此刻多半正对着采集页
// 或别的窗口 —— 请求只显示在分享页里,等于大多数敲门根本没人听见,
// 敲的人只会看到「无人应答」。所以这里在主窗口存续期间轮询请求台,
// 新请求出全局 Toast,侧边栏「分享」项挂角标。
//
// 轮询的是 `pendingJoinRequests`:纯内存读取,无副作用,1.5 秒一拍足够 ——
// 对方的等待窗口是分钟级的。

import Combine
import Foundation

@MainActor
final class ShareActivityStore: ObservableObject {
    static let shared = ShareActivityStore()

    /// 等着主持人回答的加入请求。空数组 = 没人敲门(或没在共享)。
    @Published private(set) var pendingJoinRequests: [FfiJoinRequest] = []

    /// 已经提醒过的请求,避免同一个人每拍都弹一次 Toast。
    /// 请求超时或被处理后从请求台消失,这里保留 id 无害 —— 同一个
    /// request_id 不会复用。
    private var announcedRequestIds: Set<String> = []
    private var timer: Timer?

    private var core: (any ZulangueCoreProtocol)? { CoreClient.shared.core }

    private init() {}

    /// 开始全局轮询。可重复调用;只会有一个定时器。
    func start() {
        guard timer == nil else { return }
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    private func poll() {
        guard let core else { return }
        let requests = core.pendingJoinRequests()
        for request in requests where announcedRequestIds.contains(request.requestId) == false {
            announcedRequestIds.insert(request.requestId)
            let name = request.displayName.isEmpty
                ? String(localized: "share.requests.unnamed")
                : request.displayName
            ToastCenter.shared.info(
                String(format: String(localized: "share.knock.toast"), name),
                detail: String(localized: "share.knock.toast_detail")
            )
        }
        if requests.map(\.requestId) != pendingJoinRequests.map(\.requestId) {
            pendingJoinRequests = requests
        }
    }
}
