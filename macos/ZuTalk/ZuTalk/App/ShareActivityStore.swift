// ShareActivityStore.swift
// 共享的唯一状态源:正在直播的链接,以及「共享这段录音」面板的请求。
//
// 共享只有两种(docs/architecture/share-links.md):
//   - 直播:正在录的这一场,扫码或打开链接就能在浏览器里看实时字幕;
//   - 录好的录音:发送一份转录稿文件,或开一条 24 小时的只读链接。
// 两种链接都端到端加密 —— 密钥在链接 `#` 后面,服务器只经手密文。
//
// 录音条上的「直播中」、菜单栏里的人数、录音药丸上的电波都只读这里。
// 走网络的调用(建房、问人数、锁定、换链接、停止、开链接、撤销)一律
// 不在主线程上等。

import AppKit
import Combine
import Foundation

@MainActor
final class ShareActivityStore: ObservableObject {
    static let shared = ShareActivityStore()

    // MARK: 直播

    /// 正在直播的链接;没在直播时为 nil。
    @Published private(set) var live: FfiLiveLink?
    /// 开始、锁定、换链接、停止这类要等网络的动作进行中。
    @Published private(set) var liveBusy = false

    /// 要共享哪一段录好的录音。主窗口据此弹出共享面板;入口在录音行的
    /// 菜单与录音页顶栏。
    @Published var recordingShareRequest: RecordingShareRequest?

    private var core: (any ZuTalkCoreProtocol)? { CoreClient.shared.core }
    private var timer: Timer?
    private var refreshing = false
    /// 直播所属的录音不在录了,连续几拍都如此才收场 —— 刚开始的那一瞬间
    /// 采集状态可能还没跟上。
    private var liveOrphanTicks = 0

    private init() {}

    /// 主窗口出现时调用:接上核心里可能已经在跑的直播(比如主窗口关了又开)。
    func start() {
        live = core?.liveLink()
        reschedule()
    }

    func presentRecordingShare(sessionId: String, title: String) {
        recordingShareRequest = RecordingShareRequest(sessionId: sessionId, title: title)
    }

    // MARK: - 直播

    /// 这一场录音此刻是不是正在直播。录音条据此亮「直播中」。
    func isBroadcasting(sessionId: String?) -> Bool {
        guard let sessionId, let live else { return false }
        return live.sessionId == sessionId
    }

    /// 开始直播正在录的这一场。
    func startLive(sessionId: String, title: String, keepsAfterEnd: Bool) {
        runLive(failure: "share.live.start_failed") { core in
            try core.startLiveLink(sessionId: sessionId, title: title, keepsAfterEnd: keepsAfterEnd)
        }
    }

    /// 锁上:已经在看的人不受影响,新的人进不来。
    func setLocked(_ locked: Bool) {
        runLive(failure: "share.live.lock_failed") { core in
            try core.setLiveLinkLocked(locked: locked)
        }
    }

    /// 散场后要不要把转录稿留在链接上。真正的去留在停止那一刻才定,
    /// 所以直播中可以来回改。纯内存,不走网络。
    func setKeepsAfterEnd(_ keeps: Bool) {
        guard let core else { return }
        do {
            live = try core.setLiveLinkKeepsAfterEnd(keeps: keeps)
        } catch {
            ToastCenter.shared.error(error.localizedDescription)
        }
    }

    /// 换一个链接:旧链接当场失效,在看的人要重新扫码。
    func replaceLink() {
        runLive(failure: "share.live.replace_failed") { core in
            try core.replaceLiveLink()
        }
    }

    /// 停止直播。留稿的话,链接上还读得到约 24 小时;不留就当场删掉。
    func stopLive() {
        guard let core, liveBusy == false else { return }
        liveBusy = true
        Task.detached {
            let result = Result { try core.stopLiveLink() }
            await MainActor.run {
                self.liveBusy = false
                self.live = core.liveLink()
                self.reschedule()
                if case .failure(let error) = result {
                    ToastCenter.shared.error(
                        String(localized: "share.live.stop_failed"),
                        detail: error.localizedDescription
                    )
                }
            }
        }
    }

    /// 退出 App 时:不留稿的直播要当场删掉,不能让它在服务器上等 24 小时
    /// 过期。最多等两秒,网络不通就交给服务端的留存期兜底。
    nonisolated static func stopLiveBeforeQuit(core: any ZuTalkCoreProtocol) {
        guard core.liveLink() != nil else { return }
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            try? core.stopLiveLink()
            done.signal()
        }
        _ = done.wait(timeout: .now() + 2)
    }

    func copyLiveLink() {
        guard let live else { return }
        copy(live.url, toast: "share.link.copied")
    }

    private func runLive(
        failure: String.LocalizationValue,
        _ action: @escaping @Sendable (any ZuTalkCoreProtocol) throws -> FfiLiveLink
    ) {
        guard let core, liveBusy == false else { return }
        liveBusy = true
        Task.detached {
            let result = Result { try action(core) }
            await MainActor.run {
                self.liveBusy = false
                switch result {
                case .success(let link):
                    self.live = link
                case .failure(let error):
                    ToastCenter.shared.error(String(localized: failure), detail: error.localizedDescription)
                    self.live = core.liveLink()
                }
                self.reschedule()
            }
        }
    }

    // MARK: - 录好的录音

    /// 这段录音还有效的链接,新的在前。读的是本机台账,不走网络。
    func recordingLinks(sessionId: String) -> [FfiRecordingLink] {
        core?.recordingLinks(sessionId: sessionId) ?? []
    }

    /// 开一条只读链接,成功后顺手复制。
    func createRecordingLink(sessionId: String, title: String) async -> FfiRecordingLink? {
        guard let core else { return nil }
        let result = await Task.detached {
            Result { try core.createRecordingLink(sessionId: sessionId, title: title) }
        }.value
        switch result {
        case .success(let link):
            copy(link.url, toast: "share.link.created_copied")
            return link
        case .failure(let error):
            ToastCenter.shared.error(
                String(localized: "share.recording.link_failed"),
                detail: error.localizedDescription
            )
            return nil
        }
    }

    /// 撤销:服务器当场删掉内容,链接从此打不开。
    func revoke(_ link: FfiRecordingLink) async -> Bool {
        guard let core else { return false }
        let roomId = link.roomId
        let result = await Task.detached { Result { try core.revokeRecordingLink(roomId: roomId) } }.value
        if case .failure(let error) = result {
            ToastCenter.shared.error(
                String(localized: "share.recording.revoke_failed"),
                detail: error.localizedDescription
            )
            return false
        }
        ToastCenter.shared.success(String(localized: "share.recording.revoked"))
        return true
    }

    /// 「发送副本」的文件:写进临时目录,交给系统的分享菜单。音频从不在里面。
    func transcriptFile(
        sessionId: String,
        title: String,
        format: FfiTranscriptFileFormat
    ) async -> URL? {
        guard let core else { return nil }
        let result = await Task.detached {
            Result { try core.transcriptFile(sessionId: sessionId, format: format) }
        }.value
        do {
            let contents = try result.get()
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("ZuTalkShare", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory
                .appendingPathComponent(Self.fileName(title))
                .appendingPathExtension(format == .markdown ? "md" : "srt")
            try contents.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            ToastCenter.shared.error(
                String(localized: "share.copy.failed"),
                detail: error.localizedDescription
            )
            return nil
        }
    }

    /// 文件名里不能有路径分隔符;空标题退回一个说得清的名字。
    nonisolated static func fileName(_ title: String) -> String {
        let cleaned = title
            .components(separatedBy: CharacterSet(charactersIn: "/:\\\n\r\t"))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = cleaned.isEmpty ? String(localized: "share.copy.default_file_name") : cleaned
        return String(name.prefix(80))
    }

    func copy(_ text: String, toast: String.LocalizationValue) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        ToastCenter.shared.success(String(localized: toast))
    }

    // MARK: - 轮询

    /// 只在直播时轮询:几个人在看、锁没锁。三秒一次 —— 人数不必比这更快,
    /// 服务端顺带靠这一问把关掉的页面剔出去。
    private func reschedule() {
        if live == nil {
            timer?.invalidate()
            timer = nil
            liveOrphanTicks = 0
            return
        }
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            Task { @MainActor in ShareActivityStore.shared.tick() }
        }
    }

    private func tick() {
        guard let core, live != nil else {
            reschedule()
            return
        }
        endLiveIfItsRecordingEnded()
        guard refreshing == false, liveBusy == false else { return }
        refreshing = true
        Task.detached {
            let refreshed = core.refreshLiveLink()
            await MainActor.run {
                self.refreshing = false
                guard self.liveBusy == false else { return }
                if refreshed != self.live { self.live = refreshed }
                self.reschedule()
            }
        }
    }

    /// 直播随录音结束:录音停了,这一场也就没什么可看的了。不收场的话,
    /// 链接会一直挂着,主持人以为结束了,内容却还在服务器上。
    private func endLiveIfItsRecordingEnded() {
        let capture = ActiveBilingualTranscriptStore.shared
        guard let live, liveBusy == false else {
            liveOrphanTicks = 0
            return
        }
        let stillRecording = capture.isCaptureActive && capture.sessionId == live.sessionId
        liveOrphanTicks = stillRecording ? 0 : liveOrphanTicks + 1
        guard liveOrphanTicks >= 2 else { return }
        liveOrphanTicks = 0
        let kept = live.keepsAfterEnd
        stopLive()
        ToastCenter.shared.info(String(localized: kept
            ? "share.live.ended_with_recording_kept"
            : "share.live.ended_with_recording"))
    }
}

/// 「共享这段录音」面板要的东西。
struct RecordingShareRequest: Identifiable, Equatable {
    var id: String { sessionId }
    let sessionId: String
    /// 行上显示的名字:标题,没有标题时是开头的话或时间。
    let title: String
}
