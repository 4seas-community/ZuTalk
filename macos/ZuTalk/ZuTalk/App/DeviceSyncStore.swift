// DeviceSyncStore.swift
// 自己的几台 Mac 之间直接同步:开关、本机名字、配对码、设备列表。
//
// 同步本身在 Rust 核心里(library_sync):录音、转录稿、笔记、标记在设备之间
// 直接走,不经服务器、不要账号;音频永远只留在录音的那台 Mac 上。这里只管
// 用户的选择与界面状态。打开过的,下次启动自动接着同步。

import AppKit
import Combine
import Foundation

extension Notification.Name {
    /// 另一台 Mac 改了一份笔记。object 是那份笔记的 doc_id。
    static let zutalkNoteChangedOnAnotherDevice = Notification.Name("ZuTalkNoteChangedOnAnotherDevice")
}

@MainActor
final class DeviceSyncStore: ObservableObject {
    static let shared = DeviceSyncStore()

    private static let enabledKey = "deviceSync.enabled"
    private static let nameKey = "deviceSync.deviceName"
    /// 配对码的有效期,与核心里的一致。
    static let inviteLifetime: TimeInterval = 10 * 60

    struct PendingInvite: Equatable {
        let code: String
        let expiresAt: Date
    }

    @Published private(set) var enabled: Bool
    @Published private(set) var status: FfiSyncStatus?
    @Published private(set) var deviceName: String
    @Published private(set) var invite: PendingInvite?
    @Published private(set) var busy = false
    /// 最近一次失败,已经是给人看的话。
    @Published private(set) var problem: String?

    private var refreshTimer: Timer?
    /// 正在进行的启动。协作主题要等它完成才能邀请。
    private var startTask: Task<Void, Never>?

    private init() {
        let defaults = UserDefaults.standard
        enabled = defaults.bool(forKey: Self.enabledKey)
        deviceName = defaults.string(forKey: Self.nameKey) ?? Self.defaultDeviceName()
    }

    nonisolated static func defaultDeviceName() -> String {
        let name = Host.current().localizedName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (name?.isEmpty == false ? name : nil) ?? "Mac"
    }

    /// 其他设备(不含本机)。
    var otherDevices: [FfiSyncDevice] {
        (status?.devices ?? []).filter { !$0.isThisDevice }
    }

    /// 这台已经被别的 Mac 移出了设备组。
    var removedFromGroup: Bool {
        status?.removedFromGroup ?? false
    }

    // MARK: - 开关

    /// 启动时调用:打开过同步的,接着同步。
    func startIfEnabled() {
        guard enabled else { return }
        start()
    }

    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        enabled = on
        problem = nil
        if on {
            start()
        } else {
            stop()
        }
    }

    /// 协作主题、加入配对码都要同步引擎在跑:没开的替用户打开,等它起来。
    func ensureRunning() async -> Bool {
        if enabled == false {
            setEnabled(true)
        }
        await startTask?.value
        return status?.running == true
    }

    private func start() {
        guard let core = CoreClient.shared.core else { return }
        let name = deviceName
        busy = true
        startTask = Task {
            let result = await Task.detached { Result { try core.syncStart(deviceName: name) } }.value
            busy = false
            switch result {
            case .success(let status):
                self.status = status
                try? core.syncSetListener(listener: DeviceSyncListener())
                startRefreshing()
                NearbyStore.shared.syncStarted()
                // 列表可能在同步启动前就画好了:那时还叫不出「来自哪台」。
                NotificationCenter.default.post(name: .zutalkSessionUpdated, object: nil)
            case .failure(let error):
                problem = Self.describe(error)
                DebugLog.warn("device sync failed to start", detail: "\(error)")
            }
        }
    }

    private func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        invite = nil
        status = nil
        NearbyStore.shared.syncStopped()
        guard let core = CoreClient.shared.core else { return }
        Task.detached { core.syncStop() }
    }

    /// 退出前断开:别的 Mac 马上知道这台下线了,而不是等连接超时。
    nonisolated static func stopBeforeQuit(core: any ZuTalkCoreProtocol) {
        core.syncStop()
    }

    // MARK: - 状态

    private func startRefreshing() {
        refreshTimer?.invalidate()
        // 在线/上次同步时间要跟着变;几秒一次足够,也不费事(只读内存)。
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            Task { @MainActor in DeviceSyncStore.shared.refresh() }
        }
        refresh()
    }

    func refresh() {
        guard enabled, let core = CoreClient.shared.core else { return }
        let next = core.syncStatus()
        if next != status {
            status = next
        }
        if let invite, invite.expiresAt <= Date() {
            self.invite = nil
        }
    }

    // MARK: - 本机名字

    func rename(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = trimmed.isEmpty ? Self.defaultDeviceName() : trimmed
        guard next != deviceName else { return }
        deviceName = next
        UserDefaults.standard.set(next, forKey: Self.nameKey)
        guard enabled, let core = CoreClient.shared.core else { return }
        Task.detached { try? core.syncRenameDevice(name: next) }
    }

    // MARK: - 配对

    /// 在已经在同步的这台上生成配对码,拿去另一台 Mac 输入。
    func createInvite() {
        guard let core = CoreClient.shared.core else { return }
        busy = true
        problem = nil
        Task {
            let result = await Task.detached { Result { try core.syncCreateDeviceInvite() } }.value
            busy = false
            switch result {
            case .success(let code):
                invite = PendingInvite(code: code, expiresAt: Date().addingTimeInterval(Self.inviteLifetime))
            case .failure(let error):
                problem = Self.describe(error)
            }
        }
    }

    func cancelInvite() {
        invite = nil
        guard let core = CoreClient.shared.core else { return }
        Task.detached { try? core.syncCancelInvites() }
    }

    func copyInvite() {
        guard let invite else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(invite.code, forType: .string)
        ToastCenter.shared.success(String(localized: "sync.invite.copied"))
    }

    /// 输入别人给的配对码:加自己的 Mac,或加入协作主题,按码的用途分流。
    func join(code: String) async -> FfiSyncJoinResult? {
        guard let core = CoreClient.shared.core else { return nil }
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard await ensureRunning() else { return nil }
        busy = true
        problem = nil
        let result = await Task.detached { Result { try core.syncJoin(code: trimmed) } }.value
        busy = false
        switch result {
        case .success(let joined):
            refresh()
            NotificationCenter.default.post(name: .zutalkSessionUpdated, object: nil)
            return joined
        case .failure(let error):
            problem = Self.describe(error)
            return nil
        }
    }

    // MARK: - 协作主题

    /// 为一个主题生成协作邀请码。同步没开的先打开。
    func topicInvite(notebookId: String) async -> Result<String, Error> {
        guard let core = CoreClient.shared.core else { return .failure(CoreError.NotFound(message: "core")) }
        guard await ensureRunning() else {
            return .failure(CoreError.ValidationFailed(message: "sync.error.not_running"))
        }
        return await Task.detached { Result { try core.syncTopicInvite(notebookId: notebookId) } }.value
    }

    func topicStatus(notebookId: String) -> FfiTopicCollaboration? {
        guard enabled, let core = CoreClient.shared.core else { return nil }
        return core.syncTopicStatus(notebookId: notebookId)
    }

    func removeTopicMember(notebookId: String, deviceId: String) async -> Error? {
        guard let core = CoreClient.shared.core else { return nil }
        let result = await Task.detached {
            Result { try core.syncRemoveTopicMember(notebookId: notebookId, deviceId: deviceId) }
        }.value
        if case .failure(let error) = result { return error }
        return nil
    }

    /// 协作者退出;发起人调用时停止协作。主题留在本机。
    func leaveTopic(notebookId: String) async -> Error? {
        guard let core = CoreClient.shared.core else { return nil }
        let result = await Task.detached { Result { try core.syncLeaveTopic(notebookId: notebookId) } }.value
        if case .failure(let error) = result { return error }
        NotificationCenter.default.post(name: .zutalkSessionUpdated, object: nil)
        return nil
    }

    /// 让这台离开设备组(或被移出之后重新开始):换一个新身份,从只有自己开始。
    /// 本机的录音与笔记原样留着。
    func leaveGroup() {
        guard let core = CoreClient.shared.core else { return }
        busy = true
        problem = nil
        invite = nil
        Task {
            let result = await Task.detached { Result { try core.syncLeaveGroup() } }.value
            busy = false
            switch result {
            case .success(let status):
                self.status = status
                try? core.syncSetListener(listener: DeviceSyncListener())
                // 引擎换过了:接收、附近的名单跟着重来。
                NearbyStore.shared.syncStarted()
            case .failure(let error):
                problem = Self.describe(error)
            }
        }
    }

    /// 移除一台 Mac:它留着已经同步到的,但再也连不进来。
    func remove(_ device: FfiSyncDevice) {
        guard let core = CoreClient.shared.core else { return }
        let id = device.deviceId
        Task {
            let result = await Task.detached { Result { try core.syncRemoveDevice(deviceId: id) } }.value
            if case .failure(let error) = result {
                problem = Self.describe(error)
            }
            refresh()
        }
    }

    // MARK: - 错误

    /// 核心返回的是稳定代码(`sync.error.*`),按它查本地化的说法;认不出的
    /// 给一句笼统的话,细节进日志。
    nonisolated static func describe(_ error: Error) -> String {
        if case let CoreError.ValidationFailed(message) = error, message.hasPrefix("sync.error.") {
            switch message {
            case "sync.error.not_a_code": return String(localized: "sync.error.not_a_code")
            case "sync.error.own_code": return String(localized: "sync.error.own_code")
            case "sync.error.wrong_purpose": return String(localized: "sync.error.wrong_purpose")
            case "sync.error.invalid_or_expired": return String(localized: "sync.error.invalid_or_expired")
            case "sync.error.unavailable": return String(localized: "sync.error.unavailable")
            case "sync.error.unreachable": return String(localized: "sync.error.unreachable")
            case "sync.error.interrupted": return String(localized: "sync.error.interrupted")
            case "sync.error.cannot_remove_self": return String(localized: "sync.error.cannot_remove_self")
            case "sync.error.audio_elsewhere": return String(localized: "sync.error.audio_elsewhere")
            case "sync.error.not_owner": return String(localized: "sync.error.not_owner")
            case "sync.error.not_shared": return String(localized: "sync.error.not_shared")
            case "sync.error.topic_missing": return String(localized: "sync.error.topic_missing")
            case "sync.error.topic_not_shareable": return String(localized: "sync.error.topic_not_shareable")
            case "sync.error.not_running": return String(localized: "sync.error.not_running")
            case "sync.error.still_recording": return String(localized: "sync.error.still_recording")
            case "sync.error.recording_missing": return String(localized: "sync.error.recording_missing")
            case "sync.error.nearby_unreachable": return String(localized: "sync.error.nearby_unreachable")
            case "sync.error.nearby_not_receiving": return String(localized: "sync.error.nearby_not_receiving")
            case "sync.error.nearby_declined": return String(localized: "sync.error.nearby_declined")
            case "sync.error.nearby_no_answer": return String(localized: "sync.error.nearby_no_answer")
            case "sync.error.nearby_already_have": return String(localized: "sync.error.nearby_already_have")
            case "sync.error.nearby_failed": return String(localized: "sync.error.nearby_failed")
            case "sync.error.nearby_not_live": return String(localized: "sync.error.nearby_not_live")
            case "sync.error.nearby_too_large": return String(localized: "sync.error.nearby_too_large")
            default: break
            }
        }
        return String(localized: "sync.error.generic")
    }
}

/// Rust 从同步线程回调这里;转到主线程再动界面。
private final class DeviceSyncListener: FfiSyncListener, @unchecked Sendable {
    func onLibraryChanged() {
        Task { @MainActor in
            NotificationCenter.default.post(name: .zutalkSessionUpdated, object: nil)
            DeviceSyncStore.shared.refresh()
        }
    }

    func onNoteChanged(docId: String) {
        Task { @MainActor in
            NotificationCenter.default.post(name: .zutalkNoteChangedOnAnotherDevice, object: docId)
        }
    }

    func onNearbyChanged() {
        Task { @MainActor in
            NearbyStore.shared.refresh()
        }
    }
}

/// 另一台 Mac 录的录音怎么说。名字可能为空:设备名单还没同步到这台。
enum RecordingOrigin {
    /// 资料库列表里的小标签。
    static func badge(_ device: String) -> String {
        device.isEmpty
            ? String(localized: "recording.origin.badge_unknown")
            : String(format: String(localized: "recording.origin.badge_format"), device)
    }

    /// 录音设置里「音频」那一栏。
    static func audioOn(_ device: String) -> String {
        device.isEmpty
            ? String(localized: "recording.origin.audio_elsewhere")
            : String(format: String(localized: "recording.origin.audio_on_format"), device)
    }

    /// 精修那一栏:这里精修不了,去哪台。
    static func audioElsewhereHint(_ device: String) -> String {
        device.isEmpty
            ? String(localized: "recording.origin.refine_elsewhere")
            : String(format: String(localized: "recording.origin.refine_on_format"), device)
    }
}
