import AppKit
import Combine
import SwiftUI

/// Where a topic's recording starts: the live-captions choice and Record.
///
/// While a recording runs — this topic's or any other — its controls are in
/// the recording bar above every page (`RecordingBar`), so this stays out of
/// the way instead of offering a second, partial set of them.
struct NotebookCaptureToolbar: View {
    let notebookId: String
    @ObservedObject var profileEditor: NotebookCaptureProfileEditorModel
    @ObservedObject private var capture = ActiveBilingualTranscriptStore.shared
    @ObservedObject private var commands = CaptureCommandCenter.shared
    @ObservedObject private var shareActivity = ShareActivityStore.shared

    var body: some View {
        HStack(spacing: Spacing.sm) {
            if capture.isCaptureActive {
                EmptyView()
            } else if shareActivity.isViewing {
                // 在别人的房间里就不能录音:收端的字幕来自远端,本机
                // 再开一路采集会把两场内容拧在一起。这里不是禁用按钮
                // 就完事 —— 要说清楚现在处于什么状态、出口在哪。
                joinedRoomStatus
            } else {
                CaptionsChoiceChip()
                startButton
            }
        }
        .onAppear { publishPlannedLaneCount() }
        .montereyOnChange(of: profileEditor.draft.selectedLanguages) { _, _ in
            publishPlannedLaneCount()
        }
        .montereyOnChange(of: profileEditor.draft.subtitleOnlyLanguages) { _, _ in
            publishPlannedLaneCount()
        }
        .montereyOnChange(of: commands.realtimeCaptionsEnabled) { _, _ in
            publishPlannedLaneCount()
        }
    }

    /// Keeps the sidebar's invite-time display honest: it divides shared
    /// invite seconds by this lane count. Local-only recordings open no
    /// remote lanes, so they report a single lane.
    private func publishPlannedLaneCount() {
        CommunityInviteSession.shared.updatePlannedLaneCount(
            commands.nextRecordingUsesCaptions
                ? Self.remoteLaneCount(
                    selectedLanguages: profileEditor.draft.selectedLanguages,
                    subtitleOnlyLanguages: profileEditor.draft.subtitleOnlyLanguages
                )
                : 1
        )
    }

    /// See `NotebookCaptureStartPreparationWorkflow.remoteLaneCount`.
    static func remoteLaneCount(
        selectedLanguages: [String],
        subtitleOnlyLanguages: [String] = []
    ) -> Int {
        NotebookCaptureStartPreparationWorkflow.remoteLaneCount(
            selectedLanguages: selectedLanguages,
            subtitleOnlyLanguages: subtitleOnlyLanguages
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
            .font(.bodyMedium)
            .padding(.horizontal, Spacing.md)
            .frame(minHeight: 36)
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
        let disabledReason = profileEditor.captureStartDisabledReason
        return Button {
            guard commands.isStarting == false, disabledReason == nil else { return }
            commands.start(notebookId: notebookId, profileEditor: profileEditor)
        } label: {
            Label(
                commands.isStarting
                    ? String(localized: "capture.toolbar.starting")
                    : String(localized: "capture.toolbar.start"),
                systemImage: commands.isStarting ? "ellipsis" : "record.circle"
            )
            .font(.bodyMedium)
            .padding(.horizontal, Spacing.md)
            .frame(minHeight: 36)
        }
        .buttonStyle(.plain)
        .foregroundColor(.signalRed)
        .background(Color.signalRed.opacity(0.1))
        .overlay(Capsule().strokeBorder(Color.signalRed.opacity(0.3), lineWidth: 0.5))
        .clipShape(Capsule())
        .disabled(commands.isStarting || disabledReason != nil)
        .accessibilityLabel(Text(String(localized: "capture.toolbar.start")))
        .accessibilityHint(Text(disabledReason ?? String(localized: "capture.toolbar.start_hint")))
        .help(disabledReason ?? String(localized: "capture.toolbar.start_hint"))
        .accessibilityIdentifier("capture.start")
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
