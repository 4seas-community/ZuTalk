// ShareActivityStore.swift
// 分享活动的全局观察者:敲门请求与「在房间中」都不能只在分享页上可见。
//
// 「附近的人」的加入请求最长等一分钟就超时。主持人此刻多半正对着采集页
// 或别的窗口 —— 请求只显示在分享页里,等于大多数敲门根本没人听见,
// 敲的人只会看到「无人应答」。所以这里在主窗口存续期间轮询请求台,
// 新请求出全局 Toast,侧边栏「分享」项挂角标。
//
// 观看端的状态同样是全局事:录音入口要按「在房间中」禁用,「分享」
// Notebook 的实时画布和字幕悬浮窗要吃远端预览帧。这些表面分散在
// 采集条、侧边栏、悬浮窗 —— 只有全局仓库能一致地喂它们。
//
// 轮询节奏分两档:空闲 1.5 秒(纯内存读取,对方的等待窗口是分钟级的);
// 观看中 0.2 秒 —— 远端帧是 replace-in-full 的,轮询与回调观感等价
// (share_api.rs 的设计),但节拍要跟上说话的速度。

import Combine
import Foundation

@MainActor
final class ShareActivityStore: ObservableObject {
    static let shared = ShareActivityStore()

    /// 等着主持人回答的加入请求。空数组 = 没人敲门(或没在共享)。
    @Published private(set) var pendingJoinRequests: [FfiJoinRequest] = []

    /// 本机在房间里(主持或观看)。侧边栏的「分享」项据此亮实时徽记。
    @Published private(set) var isInRoom = false
    /// 本机作为观看者加入了别人的房间。录音入口据此显示「加入房间中」。
    @Published private(set) var isViewing = false
    /// 主持人已明确道别(仅观看中有意义)。
    @Published private(set) var hostLeft = false
    /// 只读房间(主持人可写,其他人只读)。
    @Published private(set) var hostOnly = false
    /// 当前房间按单次录音共享时,那一场的 session id。只读约束只属于它。
    @Published private(set) var scopeSessionId: String?
    /// 观看中:主播最新一帧的完整预览。与主播本机画布同一形态 ——
    /// 多语言 lane、cue、lane 健康齐全。旧版主播只发压扁行时为 nil。
    @Published private(set) var remotePreview: FfiNotebookCaptureLivePreview?
    /// 观看中:压扁的兼容行列表。完整帧缺席时的退化显示。
    @Published private(set) var remoteLines: [FfiSharedCaptionLine] = []

    /// 「分享」收件 Notebook 的 id。核心启动时幂等创建,这里取一次缓存 ——
    /// 打开这个 Notebook 时,页面要换成收件视图而不是采集视图。
    @Published private(set) var sharedInboxNotebookId: String?

    /// 已经提醒过的请求,避免同一个人每拍都弹一次 Toast。
    /// 请求超时或被处理后从请求台消失,这里保留 id 无害 —— 同一个
    /// request_id 不会复用。
    private var announcedRequestIds: Set<String> = []
    /// 上一拍的 host_left。只在 false→true 的越变上出 Toast。
    private var lastHostLeft = false
    private var timer: Timer?
    /// 当前定时器的节拍。观看状态翻转时重建定时器。
    private var currentInterval: TimeInterval = 0

    private var core: (any ZulangueCoreProtocol)? { CoreClient.shared.core }

    private init() {}

    /// 开始全局轮询。可重复调用;只会有一个定时器。
    func start() {
        if sharedInboxNotebookId == nil {
            sharedInboxNotebookId = try? core?.sharedInboxNotebook().id
        }
        poll()
        reschedule()
    }

    /// 空闲 1.5s / 观看中 0.2s。节拍没变就不动现有定时器。
    private func reschedule() {
        let wanted: TimeInterval = isViewing ? 0.2 : 1.5
        guard timer == nil || currentInterval != wanted else { return }
        timer?.invalidate()
        currentInterval = wanted
        timer = Timer.scheduledTimer(withTimeInterval: wanted, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    /// 一条收件可否编辑。与 SharePage 同一判定:只读约束**只属于当前
    /// 房间范围的那份文档**,散场后的收件都是本机批注。
    func canEditSharedSession(_ sessionId: String) -> Bool {
        !(isViewing && hostOnly && scopeSessionId == sessionId)
    }

    private func poll() {
        guard let core else { return }
        // 核心可能晚于第一次 start() 才就绪;拿到 id 就不再问。
        if sharedInboxNotebookId == nil {
            sharedInboxNotebookId = try? core.sharedInboxNotebook().id
        }
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

        // 主持人道别也要全局说一声 —— 观看的人未必正停在分享页上。
        // 只报越变(false→true):分享页的状态条负责持续陈述。
        let state = core.shareState()
        if state.hostLeft, lastHostLeft == false {
            ToastCenter.shared.info(
                String(localized: "share.status.host_left"),
                detail: String(localized: "share.status.host_left_hint")
            )
        }
        lastHostLeft = state.hostLeft

        if isInRoom != state.isSharing { isInRoom = state.isSharing }
        if hostLeft != state.hostLeft { hostLeft = state.hostLeft }
        if hostOnly != state.hostOnly { hostOnly = state.hostOnly }
        if scopeSessionId != state.scopeSessionId { scopeSessionId = state.scopeSessionId }
        if isViewing != state.isViewing {
            isViewing = state.isViewing
            reschedule()
        }

        // 帧内容:只在真的变了时发布 —— 0.2 秒一拍,恒等发布会让整棵
        // 依赖树白刷。revision 只在单场录音内单调,换场会从头计数,
        // 所以变更信号是 (session, revision) 一对,不能只看 revision。
        if state.isViewing {
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
    }
}
