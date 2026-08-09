// SharedInboxPage.swift
// 「分享」Notebook 的正文:收到的共享 session 台账 + 房间进行中的实时画布。
//
// 这个 Notebook 里没有「录音」—— 它的内容不是本机 STT 生成的,是别人
// 房间里实时传来的。打开它看到的是:
//   - 正在接收的那一场(多语言 lane 实时刷新,观感对齐主播本机画布);
//   - 散场后留下的收件(shared/ 目录台账,点开即读,权限内可订正)。
//
// 实时画布吃 ShareActivityStore 的远端预览帧(share_state().remote_preview,
// 0.2 秒一拍);台账吃 listSharedSessions(文档即真相,无 SQLite 事实层)。
// 两者是同一场 session 的两个时态:帧是推测性 tail,块是 doc-sync 合入的
// 落定内容 —— 帧不落库,落定内容不经帧。

import SwiftUI

struct SharedInboxPage: View {
    let notebookId: String

    @ObservedObject private var shareActivity = ShareActivityStore.shared
    @ObservedObject private var subtitleOverlay = SubtitleOverlayCoordinator.shared
    @State private var sessions: [FfiSharedSessionInfo] = []
    @State private var openSession: SharedSessionRoute?

    private var core: (any ZulangueCoreProtocol)? { CoreClient.shared.core }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                if shareActivity.isViewing {
                    liveSection
                }

                receivedSection
            }
            .padding(Spacing.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.bgRoot)
        .task {
            refreshSessions()
            while Task.isCancelled == false {
                try? await Task.sleep(for: .seconds(1))
                refreshSessions()
            }
        }
        .sheet(item: $openSession) { route in
            SharedSessionView(
                sessionId: route.id,
                editable: shareActivity.canEditSharedSession(route.id)
            )
        }
        .accessibilityIdentifier("shared_inbox")
    }

    // MARK: 实时

    @ViewBuilder
    private var liveSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
                if shareActivity.hostLeft {
                    Image(systemName: "antenna.radiowaves.left.and.right.slash")
                        .foregroundColor(.textTertiary)
                    Text(String(localized: "share.status.host_left"))
                        .font(.bodyMedium)
                        .foregroundColor(.textSecondary)
                } else {
                    // 与录音页的 REC 语汇同族:绿点 = 正在收到活的内容。
                    Circle()
                        .fill(Color.signalGreen)
                        .frame(width: 8, height: 8)
                    Text(String(localized: "shared_inbox.live_title"))
                        .font(.bodyMedium)
                        .foregroundColor(.textPrimary)
                }
                Spacer()
                subtitleWindowButton
            }

            if let preview = shareActivity.remotePreview {
                SharedLivePreviewCanvas(preview: preview)
            } else if shareActivity.remoteLines.isEmpty == false {
                // 旧版主播:只有压扁行,退化为行列表。
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    ForEach(
                        Array(shareActivity.remoteLines.enumerated()),
                        id: \.offset
                    ) { _, line in
                        VStack(alignment: .leading, spacing: 2) {
                            // 压扁行里,译文 cue 的原文栏本来就是空的
                            // (share_api 的 caption_frame_from 只搬运,不重做
                            // 对应关系)。无条件画它就是每条译文上面多一条
                            // 空行的高度 —— 读者看到的是凭空的间隔。
                            if line.sourceText.isEmpty == false {
                                Text(line.sourceText)
                                    .font(.body)
                                    .foregroundColor(.textPrimary)
                            }
                            if let translated = line.targetText, !translated.isEmpty {
                                Text(translated)
                                    .font(.bodySM)
                                    .foregroundColor(.textSecondary)
                            }
                        }
                    }
                }
            } else if shareActivity.hostLeft == false {
                // 加入成功、主播还没开始录音。没有这句,正确的等待
                // 和卡死在屏幕上一模一样。
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "clock")
                        .foregroundColor(.signalAmber)
                    Text(String(localized: "shared_inbox.live_waiting"))
                        .font(.bodySM)
                        .foregroundColor(.textSecondary)
                }
                .padding(Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.textTertiary.opacity(0.06))
                .cornerRadius(6)
            }
        }
        .accessibilityIdentifier("shared_inbox.live")
    }

    /// 悬浮字幕开关。观看中可用 —— 数据源是远端帧,不是本机采集。
    private var subtitleWindowButton: some View {
        let isPresented = subtitleOverlay.isPresented
        return Button {
            WindowCommandRouter.shared.requestToggleSubtitleOverlay()
        } label: {
            Image(systemName: isPresented ? "pip.exit" : "pip.enter")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(isPresented ? .brandAccent : .textPrimary)
        .background(
            RoundedRectangle(cornerRadius: Radius.xs)
                .fill(isPresented ? Color.brandAccent.opacity(0.14) : Color.bgElevated.opacity(0.65))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.xs)
                .strokeBorder(
                    isPresented ? Color.brandAccent.opacity(0.5) : Color.borderGhost.opacity(0.25),
                    lineWidth: 0.5
                )
        )
        .help(String(localized: "capture.toolbar.subtitle_window.hint"))
        .accessibilityLabel(Text(
            isPresented
                ? String(localized: "capture.toolbar.subtitle_window.close")
                : String(localized: "capture.toolbar.subtitle_window.open")
        ))
        .accessibilityIdentifier("shared_inbox.subtitle_window")
    }

    // MARK: 台账

    @ViewBuilder
    private var receivedSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(String(localized: "share.received.title"))
                .font(.bodyMedium)
                .foregroundColor(.textPrimary)

            if sessions.isEmpty {
                EmptyState(
                    icon: "tray",
                    title: String(localized: "shared_inbox.empty_title"),
                    description: String(localized: "shared_inbox.empty_body")
                )
            } else {
                ForEach(sessions, id: \.sessionId) { info in
                    Button {
                        openSession = SharedSessionRoute(id: info.sessionId)
                    } label: {
                        HStack(spacing: Spacing.sm) {
                            Image(systemName: "doc.text")
                                .foregroundColor(.textSecondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(info.preview.isEmpty
                                     ? String(localized: "share.received.untitled")
                                     : info.preview)
                                    .font(.bodySM)
                                    .foregroundColor(.textPrimary)
                                    .lineLimit(1)
                                Text(Self.receivedDetail(info))
                                    .font(.captionMedium)
                                    .foregroundColor(.textTertiary)
                            }
                            Spacer()
                            // 正在接收的那一场:落定内容还在增长。
                            if isLiveSession(info.sessionId) {
                                Label(
                                    String(localized: "shared_inbox.session_live"),
                                    systemImage: "dot.radiowaves.left.and.right"
                                )
                                .font(.captionMedium)
                                .foregroundColor(.signalGreen)
                            }
                            if shareActivity.canEditSharedSession(info.sessionId) == false {
                                Image(systemName: "lock")
                                    .font(.system(size: 10))
                                    .foregroundColor(.textTertiary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .accessibilityIdentifier("shared_inbox.received")
    }

    private func isLiveSession(_ sessionId: String) -> Bool {
        shareActivity.isViewing
            && shareActivity.hostLeft == false
            && shareActivity.remotePreview?.sessionId == sessionId
    }

    private func refreshSessions() {
        guard let core else { return }
        sessions = core.listSharedSessions()
    }

    /// 「收到时间 · N 块」。文件时间拿不到时只剩块数。与 SharePage 同一格式。
    private static func receivedDetail(_ info: FfiSharedSessionInfo) -> String {
        let blocks = String(
            format: String(localized: "share.received.blocks"),
            Int64(info.blockCount)
        )
        guard info.receivedAtEpoch > 0 else { return blocks }
        let stamp = Date(timeIntervalSince1970: TimeInterval(info.receivedAtEpoch))
            .formatted(date: .abbreviated, time: .shortened)
        return "\(stamp) · \(blocks)"
    }
}

// =========================================================================
// 远端实时画布
// =========================================================================

/// 主播预览帧的多语言呈现:一句一块,原文在上,各语车道跟在下面,
/// 段尾是尚未绑定到句子的补充 cue(按语言各一条最新)。
///
/// 帧是 replace-in-full 的:整个画布每帧重建,没有增量状态。utterance 与
/// cue 的对应**不在这里重算**(设计红线,share-p2p.md §3.2)—— cue 只按
/// 语言取最新展示,和主播画布的补充行同一策略。
struct SharedLivePreviewCanvas: View {
    let preview: FfiNotebookCaptureLivePreview

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            ForEach(preview.utterances, id: \.id) { utterance in
                utteranceRow(utterance)
            }

            let cues = Self.latestCuesByLanguage(preview.translationCues)
            if cues.isEmpty == false {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    ForEach(cues, id: \.targetLanguage) { cue in
                        laneRow(
                            language: cue.targetLanguage,
                            text: cue.text,
                            isPartial: cue.completion == "partial"
                        )
                    }
                }
            }

            let stalled = Self.stalledLanes(preview.laneHealth)
            if stalled.isEmpty == false {
                HStack(spacing: Spacing.sm) {
                    ForEach(stalled, id: \.label) { lane in
                        Label(lane.label, systemImage: lane.icon)
                            .font(.captionMedium)
                            .foregroundColor(lane.isFailed ? .signalRed : .signalAmber)
                            .help(lane.hint)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("share.live_canvas")
    }

    private func utteranceRow(_ utterance: FfiNotebookCaptureUtterance) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                languageChip(
                    utterance.provisionalSourceLanguage ?? utterance.sourceLanguage
                )
                Text(utterance.sourceText)
                    .font(.body)
                    .foregroundColor(
                        utterance.completion == "complete" ? .textPrimary : .textSecondary
                    )
                    .textSelection(.enabled)
            }
            if let language = utterance.translatedLanguage,
               let text = utterance.translatedText,
               text.isEmpty == false {
                laneRow(
                    language: language,
                    text: text,
                    isPartial: utterance.completion == "partial"
                )
            }
        }
    }

    private func laneRow(language: String, text: String, isPartial: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
            languageChip(language)
            Text(text)
                .font(.bodySM)
                .foregroundColor(isPartial ? .textTertiary : .textSecondary)
                .textSelection(.enabled)
        }
    }

    private func languageChip(_ language: String) -> some View {
        Text(language)
            .font(.captionMedium)
            .foregroundColor(.textTertiary)
            .frame(minWidth: 24, alignment: .trailing)
            .accessibilityHidden(true)
    }

    /// 每语言取最新一条未撤回 cue。线上帧已过滤撤回,这里只按
    /// (group_epoch, provider_sequence, revision) 单调取新。
    static func latestCuesByLanguage(
        _ cues: [FfiNotebookCaptureTranslationCue]
    ) -> [FfiNotebookCaptureTranslationCue] {
        var latest: [String: FfiNotebookCaptureTranslationCue] = [:]
        for cue in cues where cue.text.isEmpty == false {
            if let existing = latest[cue.targetLanguage] {
                let newer = (cue.groupEpoch, cue.providerSequence, cue.revision)
                    > (existing.groupEpoch, existing.providerSequence, existing.revision)
                if newer { latest[cue.targetLanguage] = cue }
            } else {
                latest[cue.targetLanguage] = cue
            }
        }
        return latest.values.sorted { $0.targetLanguage < $1.targetLanguage }
    }

    struct StalledLane {
        let label: String
        let icon: String
        let hint: String
        let isFailed: Bool
    }

    /// 没在正常出字的车道。这正是压扁行列表丢掉 lane health 后收端
    /// 分不清的两句话:「还在连」和「坏了不会再有字」。
    static func stalledLanes(_ lanes: [FfiNotebookCaptureLaneHealth]) -> [StalledLane] {
        lanes.compactMap { lane in
            let label = lane.targetLanguage
                ?? String(localized: "shared_inbox.lane_canonical")
            switch lane.state {
            case "connecting":
                return StalledLane(
                    label: label,
                    icon: "ellipsis",
                    hint: String(localized: "shared_inbox.lane_connecting"),
                    isFailed: false
                )
            case "failed":
                return StalledLane(
                    label: label,
                    icon: "exclamationmark.triangle",
                    hint: String(localized: "shared_inbox.lane_failed"),
                    isFailed: true
                )
            default:
                return nil
            }
        }
    }
}
