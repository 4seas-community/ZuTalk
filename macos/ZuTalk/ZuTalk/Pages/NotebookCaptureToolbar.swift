import AppKit
import Combine
import SwiftUI

/// The only UI surface allowed to start, pause, resume, or stop capture.
/// Menu bar, Floating, and Caption Mirror surfaces observe the same store read-only.
struct NotebookCaptureToolbar: View {
    let notebookId: String
    @ObservedObject var profileEditor: NotebookCaptureProfileEditorModel
    @ObservedObject private var capture = ActiveBilingualTranscriptStore.shared
    @ObservedObject private var shareActivity = ShareActivityStore.shared
    @State private var isStarting = false
    @State private var isPausing = false
    @State private var isStopping = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            HStack(spacing: Spacing.sm) {
                if capture.isCaptureActive {
                    if capture.notebookId == notebookId {
                        captureStatus
                        pauseButton
                        stopButton
                    } else {
                        Button {
                            MainNavigationStore.shared.openActiveNotebookForCapture()
                        } label: {
                            Label(
                                String(localized: "capture.toolbar.active_other_notebook"),
                                systemImage: "arrowshape.turn.up.left.fill"
                            )
                            .font(.captionMedium)
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.textSecondary)
                        .help(String(localized: "capture.open_notebook_hint"))
                        .accessibilityLabel(Text(String(localized: "capture.open_notebook")))
                    }
                } else if shareActivity.isViewing {
                    // 在别人的房间里就不能录音:收端的字幕来自远端,本机
                    // 再开一路采集会把两场内容拧在一起。这里不是禁用按钮
                    // 就完事 —— 要说清楚现在处于什么状态、出口在哪。
                    joinedRoomStatus
                } else {
                    startButton
                }

            }

            if showsPauseBillingNotice {
                Label(
                    String(localized: "capture.toolbar.pause_billing"),
                    systemImage: "clock.badge.exclamationmark"
                )
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.signalAmber)
                .lineLimit(1)
                .help(String(localized: "capture.toolbar.pause_billing_detail"))
                .accessibilityHint(Text(String(localized: "capture.toolbar.pause_billing_detail")))
            }

            // 共享指示器:这段录音的字幕正在(或暂停)发给房间里的人。
            // share-p2p.md §4.1 的要求 —— 录音进行中常驻可见,一键可关。
            if capture.isCaptureActive, capture.notebookId == notebookId {
                ShareBroadcastIndicator(
                    notebookId: notebookId,
                    sessionId: capture.sessionId
                )
            }
        }
        .onAppear { publishPlannedLaneCount() }
        .montereyOnChange(of: profileEditor.draft.selectedLanguages) { _, _ in
            publishPlannedLaneCount()
        }
        .montereyOnChange(of: profileEditor.draft.remoteRealtimeEnabled) { _, _ in
            publishPlannedLaneCount()
        }
    }

    /// Keeps the sidebar's invite-time display honest: it divides shared
    /// invite seconds by this lane count. Local-only recordings open no
    /// remote lanes, so they report a single lane.
    private func publishPlannedLaneCount() {
        CommunityInviteSession.shared.updatePlannedLaneCount(
            profileEditor.draft.remoteRealtimeEnabled
                ? Self.remoteLaneCount(
                    selectedLanguages: profileEditor.draft.selectedLanguages
                )
                : 1
        )
    }

    /// Mirrors the Rust core's `remote_stream_plan`: one or two languages run
    /// on a single WebSocket, three or more open one canonical lane plus one
    /// translation lane per language. Invite billing charges per lane.
    static func remoteLaneCount(selectedLanguages: [String]) -> Int {
        NotebookCaptureStartPreparationWorkflow.remoteLaneCount(
            selectedLanguages: selectedLanguages
        )
    }

    /// 「加入房间中」:占据录音按钮的位置,点它去分享页(离开房间的出口
    /// 在那里)。样式沿用录音按钮的药丸,但用琥珀信号色 —— 它是状态,
    /// 不是危险,也不是可以按下去开始的东西。
    private var joinedRoomStatus: some View {
        Button {
            MainNavigationStore.shared.select(tab: .share)
        } label: {
            Label(
                String(localized: "capture.toolbar.joined_room"),
                systemImage: "dot.radiowaves.left.and.right"
            )
            .font(.captionMedium)
            .padding(.horizontal, 10)
            .frame(minHeight: 28)
        }
        .buttonStyle(.plain)
        .foregroundColor(.signalAmber)
        .background(Color.signalAmber.opacity(0.12))
        .overlay(Capsule().strokeBorder(Color.signalAmber.opacity(0.45), lineWidth: 0.5))
        .clipShape(Capsule())
        .help(String(localized: "capture.toolbar.joined_room_hint"))
        .accessibilityLabel(Text(String(localized: "capture.toolbar.joined_room")))
        .accessibilityHint(Text(String(localized: "capture.toolbar.joined_room_hint")))
        .accessibilityIdentifier("capture.joined_room")
    }

    private var startButton: some View {
        Button {
            guard isStarting == false,
                  profileEditor.captureStartDisabledReason == nil
            else { return }
            guard let startLease = NotebookCaptureStartWorkflowGate.shared.acquire() else {
                ToastCenter.shared.warning(String(localized: "capture.toast.start_failed"))
                return
            }
            isStarting = true
            Task { @MainActor in
                defer {
                    NotebookCaptureStartWorkflowGate.shared.release(startLease)
                    isStarting = false
                }
                do {
                    let preparation = try await NotebookCaptureStartPreparationWorkflow.prepare(
                        enableRealtimeIfNeeded: true,
                        prepareProfile: { enableRealtimeIfNeeded in
                            try await profileEditor.prepareForCaptureStart(
                                enableRealtimeIfNeeded: enableRealtimeIfNeeded
                            )
                            return profileEditor.draft
                        },
                        prepareRealtimeCredential: { laneCount in
                            try await CommunityInviteSession.shared
                                .prepareRealtimeCredential(laneCount: laneCount)
                        }
                    )
                    if preparation == .personalKeyFallback {
                        ToastCenter.shared.info(
                            String(localized: "community_invite.fallback_personal_key")
                        )
                    }
                    try await NotebookCaptureStartCoordinator(
                        capture: capture,
                        navigation: MainNavigationStore.shared
                    ).start(notebookId: notebookId)
                } catch {
                    // Return any invite reservation made above; a no-op when
                    // none exists.
                    await CommunityInviteSession.shared.settleRealtimeSession(usedSeconds: 0)
                    ToastCenter.shared.error(
                        String(localized: "capture.toast.start_failed"),
                        detail: error.localizedDescription
                    )
                }
            }
        } label: {
            Label(
                isStarting
                    ? String(localized: "capture.toolbar.starting")
                    : String(localized: "capture.toolbar.start"),
                systemImage: isStarting ? "ellipsis" : "record.circle"
            )
            .font(.captionMedium)
            .padding(.horizontal, 10)
            .frame(minHeight: 28)
        }
        .buttonStyle(.plain)
        .foregroundColor(.brandAccent)
        .background(Color.brandAccent.opacity(0.12))
        .overlay(Capsule().strokeBorder(Color.brandAccent.opacity(0.45), lineWidth: 0.5))
        .clipShape(Capsule())
        .disabled(isStarting || profileEditor.captureStartDisabledReason != nil)
        .keyboardShortcut("r", modifiers: [.control, .option])
        .accessibilityLabel(Text(String(localized: "capture.toolbar.start")))
        .accessibilityHint(Text(
            profileEditor.captureStartDisabledReason
                ?? String(localized: "capture.toolbar.start_hint")
        ))
        .help(
            profileEditor.captureStartDisabledReason
                ?? String(localized: "capture.toolbar.start_hint")
        )
    }

    private var pauseButton: some View {
        let isPaused = capture.captureState == .paused
        return Button {
            guard isPausing == false else { return }
            isPausing = true
            Task { @MainActor in
                defer { isPausing = false }
                do {
                    try await capture.setPaused(!isPaused)
                } catch {
                    ToastCenter.shared.error(
                        String(localized: "capture.toast.pause_failed"),
                        detail: error.localizedDescription
                    )
                }
            }
        } label: {
            Label(
                isPaused
                    ? String(localized: "capture.toolbar.resume")
                    : String(localized: "capture.toolbar.pause"),
                systemImage: isPaused ? "play.fill" : "pause.fill"
            )
            .font(.captionMedium)
            .frame(minWidth: 72, minHeight: 28)
        }
        .buttonStyle(.plain)
        .foregroundColor(.textPrimary)
        .background(Color.bgElevated.opacity(0.65))
        .clipShape(Capsule())
        .disabled(capture.captureState == .draining || isPausing)
        .keyboardShortcut("p", modifiers: [.control, .option])
        .accessibilityLabel(Text(isPaused
            ? String(localized: "capture.toolbar.resume")
            : String(localized: "capture.toolbar.pause")))
    }

    private var stopButton: some View {
        Button {
            guard isStopping == false else { return }
            isStopping = true
            Task { @MainActor in
                defer { isStopping = false }
                let usedSeconds = Int(capture.elapsedRecordingTime.rounded(.up))
                do {
                    if capture.stopRecoveryRequired {
                        try await capture.retryStopRecovery()
                    } else {
                        try await capture.stop()
                    }
                    await CommunityInviteSession.shared.settleRealtimeSession(
                        usedSeconds: usedSeconds
                    )
                } catch {
                    if capture.isCaptureActive == false {
                        await CommunityInviteSession.shared.settleRealtimeSession(
                            usedSeconds: usedSeconds
                        )
                    }
                    ToastCenter.shared.error(
                        String(localized: "capture.toast.stop_failed"),
                        detail: error.localizedDescription
                    )
                }
            }
        } label: {
            Label(
                isStopping
                    ? String(localized: "capture.state.draining")
                    : capture.stopRecoveryRequired
                        ? String(localized: "home.workspace.retry")
                        : String(localized: "capture.toolbar.stop"),
                systemImage: isStopping
                    ? "hourglass"
                    : capture.stopRecoveryRequired ? "arrow.clockwise" : "stop.fill"
            )
                .font(.captionMedium)
                .frame(minWidth: 64, minHeight: 28)
        }
        .buttonStyle(.plain)
        .foregroundColor(.signalRed)
        .background(Color.signalRed.opacity(0.12))
        .clipShape(Capsule())
        .disabled(
            (capture.captureState == .draining && capture.stopRecoveryRequired == false)
                || isStopping
        )
        .keyboardShortcut("r", modifiers: [.control, .option])
        .accessibilityLabel(Text(capture.stopRecoveryRequired
            ? String(localized: "home.workspace.retry")
            : String(localized: "capture.toolbar.stop")))
        .accessibilityHint(Text(String(localized: "capture.toolbar.stop_hint")))
    }

    private var captureStatus: some View {
        CaptureStateLabel(
            captureState: capture.presentationCaptureState,
            remoteHealth: capture.remoteHealth,
            projectionState: capture.projectionState,
            haltedTranslationLanguages: capture.haltedTranslationLanguages
        )
    }

    private var showsPauseBillingNotice: Bool {
        guard capture.captureState == .paused else { return false }
        return capture.remoteHealth == .connecting
            || capture.remoteHealth == .live
            || capture.remoteHealth == .degraded
    }
}

/// 录音条上的共享指示器。share-p2p.md §4.1:录音进行中,常驻可见,一键可关,
/// 关闭只影响本次。
///
/// 状态每秒问一次核心。判定与 Rust 侧广播放行是同一份逻辑
/// (`session_broadcast_status` 与 `ShareCaptionTap::broadcast` 逐条对应)——
/// 指示器亮着而字幕没在发、或反过来,都比没有指示器更坏。
struct ShareBroadcastIndicator: View {
    let notebookId: String
    let sessionId: String?

    @State private var status: FfiSessionBroadcastStatus = .notShared
    private let heartbeat = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    private var core: (any ZuTalkCoreProtocol)? { CoreClient.shared.core }

    var body: some View {
        Group {
            switch status {
            case .notShared:
                EmptyView()
            case .broadcasting:
                HStack(spacing: Spacing.sm) {
                    Label(
                        String(localized: "share.capture.live"),
                        systemImage: "dot.radiowaves.left.and.right"
                    )
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.signalAmber)
                    .help(String(localized: "share.capture.live_hint"))

                    Button {
                        setMuted(true)
                    } label: {
                        Text(String(localized: "share.capture.mute"))
                            .underline()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.textSecondary)
                    .help(String(localized: "share.capture.mute_hint"))
                    .accessibilityIdentifier("capture.share_mute")
                }
                .accessibilityIdentifier("capture.share_live")
            case .muted:
                HStack(spacing: Spacing.sm) {
                    Label(
                        String(localized: "share.capture.muted"),
                        systemImage: "dot.radiowaves.left.and.right"
                    )
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.textTertiary)
                    .help(String(localized: "share.capture.muted_hint"))

                    Button {
                        setMuted(false)
                    } label: {
                        Text(String(localized: "share.capture.unmute"))
                            .underline()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.textSecondary)
                }
                .accessibilityIdentifier("capture.share_muted")
            }
        }
        .onAppear { refresh() }
        .onReceive(heartbeat) { _ in refresh() }
    }

    private func refresh() {
        guard let core, let sessionId else {
            status = .notShared
            return
        }
        status = core.sessionBroadcastStatus(notebookId: notebookId, sessionId: sessionId)
    }

    private func setMuted(_ muted: Bool) {
        guard let core, let sessionId else { return }
        core.setSessionBroadcastMuted(sessionId: sessionId, muted: muted)
        refresh()
    }
}

/// 被动版共享指示灯:一个琥珀色图标,没有按钮。
///
/// 给 HUD 药丸这类不可交互(ignoresMouseEvents)或空间紧张的表面用 ——
/// 它们只回答一个问题:**此刻我的话在不在离开这台机器**。静音与未共享
/// 都不亮:亮 = 在发,同一份判定,不做第三种含糊状态。
struct ShareBroadcastGlyph: View {
    @ObservedObject private var capture = ActiveBilingualTranscriptStore.shared
    @State private var broadcasting = false
    private let heartbeat = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    private var core: (any ZuTalkCoreProtocol)? { CoreClient.shared.core }

    var body: some View {
        Group {
            if broadcasting {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.signalAmber)
                    .help(String(localized: "share.capture.live_hint"))
                    .accessibilityLabel(String(localized: "share.capture.live"))
            }
        }
        .onAppear { refresh() }
        .onReceive(heartbeat) { _ in refresh() }
    }

    private func refresh() {
        guard let core,
              let notebookId = capture.notebookId,
              let sessionId = capture.sessionId
        else {
            broadcasting = false
            return
        }
        broadcasting = core.sessionBroadcastStatus(
            notebookId: notebookId,
            sessionId: sessionId
        ) == .broadcasting
    }
}
