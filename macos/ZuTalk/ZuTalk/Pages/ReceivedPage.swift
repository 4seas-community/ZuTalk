// ReceivedPage.swift
// 「收到的」:别人给你的东西都在这一页 —— 正在看的直播、附近公开的直播、
// 用加入码加入、留下来的文字稿。
//
// 这里以前是「分享」页:主持与观看两套器械挤在一页,开始共享要先选主题
// 再选录音;收到的文字稿落在一个藏起来的「分享」主题里,点不进去。现在
// 共享自己的东西从被共享的东西上开始(录音条、录音行菜单),这一页只管
// 别人给的。

import SwiftUI

struct ReceivedPage: View {
    @ObservedObject private var share = ShareActivityStore.shared
    @ObservedObject private var subtitleOverlay = SubtitleOverlayCoordinator.shared
    @State private var code = ""
    @State private var joinError: String?
    @State private var joining = false
    @State private var openTranscript: ReceivedTranscriptRoute?
    @State private var pendingDelete: FfiSharedSessionInfo?
    @State private var editingName = false
    @State private var nameDraft = ""
    @FocusState private var codeFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                if share.isViewing {
                    watchingCard
                }
                joinCard
                nearbyCard
                transcriptsCard
                nameRow
            }
            .padding(Spacing.xl)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.bgRoot)
        .onAppear {
            share.beginWatchingNearby()
            share.refreshReceived()
        }
        .onDisappear { share.endWatchingNearby() }
        .sheet(item: $openTranscript) { route in
            SharedSessionView(
                sessionId: route.id,
                title: route.title,
                hostName: route.hostName,
                editable: share.canEditReceived(route.id)
            )
        }
        .confirmationDialog(
            String(localized: "received.delete.confirm_title"),
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if $0 == false { pendingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { info in
            Button(String(localized: "received.delete"), role: .destructive) {
                share.deleteReceived(info)
            }
            Button(String(localized: "common.cancel"), role: .cancel) {}
        } message: { _ in
            Text(String(localized: "received.delete.confirm_body"))
        }
        .accessibilityIdentifier("received")
    }

    // MARK: 正在看

    @ViewBuilder
    private var watchingCard: some View {
        card {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(watchingTitle)
                        .font(.titleMD)
                        .foregroundColor(.textPrimary)
                    if share.isLive, share.title.isEmpty == false {
                        Text(share.title)
                            .font(.bodySM)
                            .foregroundColor(.textSecondary)
                    }
                }
                Spacer()
                if let link = share.viewerLink, share.hostLeft == false, share.removedByHost == false {
                    ShareLinkBadge(link: link)
                }
            }

            Text(watchingNote)
                .font(.bodySM)
                .foregroundColor(.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if share.isLive, share.hostLeft == false, share.removedByHost == false {
                if let preview = share.remotePreview, preview.utterances.isEmpty == false {
                    SharedLivePreviewCanvas(preview: preview)
                        .padding(Spacing.md)
                        .background(Color.bgSunken)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.md))
                } else if share.remoteLines.isEmpty == false {
                    legacyLines
                } else {
                    Label(String(localized: "received.watch.waiting"), systemImage: "waveform")
                        .font(.bodySM)
                        .foregroundColor(.textTertiary)
                }
            }

            HStack(spacing: Spacing.sm) {
                if share.isLive, share.hostLeft == false, share.removedByHost == false {
                    Button {
                        WindowCommandRouter.shared.requestToggleSubtitleOverlay()
                    } label: {
                        Label(
                            String(localized: subtitleOverlay.isPresented
                                ? "received.watch.hide_subtitles"
                                : "received.watch.show_subtitles"),
                            systemImage: "pip.enter"
                        )
                    }
                }
                if share.isLive == false, let sessionId = share.scopeSessionId {
                    Button {
                        openTranscript = ReceivedTranscriptRoute(
                            id: sessionId,
                            title: share.title,
                            hostName: share.hostName
                        )
                    } label: {
                        Label(String(localized: "received.open"), systemImage: "doc.text")
                    }
                    .buttonStyle(.borderedProminent)
                }
                Spacer()
                Button(String(localized: share.hostLeft || share.removedByHost
                    ? "share.watch.close"
                    : "share.watch.leave")) {
                    share.leave()
                }
                .accessibilityIdentifier("received.leave")
            }
        }
        .accessibilityIdentifier("received.watching")
    }

    private var watchingTitle: String {
        let host = share.hostDisplayName
        if share.removedByHost {
            return String(format: String(localized: "share.watch.removed_format"), host)
        }
        if share.hostLeft {
            return String(format: String(localized: "share.watch.ended_format"), host)
        }
        if share.isLive {
            return String(format: String(localized: "share.watch.live_format"), host)
        }
        return String(
            format: String(localized: "share.watch.recording_format"),
            host,
            share.title.isEmpty ? String(localized: "share.untitled") : share.title
        )
    }

    /// 这一场会不会在你这里留下东西 —— 看的人最该知道的一句话。
    private var watchingNote: String {
        if share.removedByHost {
            return String(localized: "received.watch.removed_note")
        }
        if share.keepsCopies, share.hostLeft {
            return String(localized: "received.watch.ended_kept_note")
        }
        if share.keepsCopies {
            return String(localized: share.isLive
                ? "received.watch.kept_live_note"
                : (share.hostOnly ? "received.watch.kept_read_only_note" : "received.watch.kept_editable_note"))
        }
        return String(localized: share.hostLeft
            ? "received.watch.ended_nothing_kept_note"
            : "received.watch.nothing_kept_note")
    }

    private var legacyLines: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            ForEach(Array(share.remoteLines.suffix(12).enumerated()), id: \.offset) { _, line in
                VStack(alignment: .leading, spacing: 2) {
                    if line.sourceText.isEmpty == false {
                        Text(line.sourceText)
                            .font(.body)
                            .foregroundColor(.textPrimary)
                    }
                    if let translated = line.targetText, translated.isEmpty == false {
                        Text(translated)
                            .font(.bodySM)
                            .foregroundColor(.textSecondary)
                    }
                }
            }
        }
    }

    // MARK: 加入

    private var joinCard: some View {
        card {
            Text(String(localized: "received.join.title"))
                .font(.bodyMedium)
                .foregroundColor(.textPrimary)
            HStack(spacing: Spacing.sm) {
                TextField(String(localized: "received.join.placeholder"), text: $code)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .focused($codeFocused)
                    .onSubmit(join)
                    .accessibilityIdentifier("received.join.field")
                Button(String(localized: joining ? "received.join.joining" : "received.join.button"), action: join)
                    .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || joining)
            }
            if let joinError {
                Label(joinError, systemImage: "exclamationmark.triangle.fill")
                    .font(.bodySM)
                    .foregroundColor(.signalRed)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(String(localized: "received.join.note"))
                    .font(.bodySM)
                    .foregroundColor(.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func join() {
        let pasted = code
        guard pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return }
        joining = true
        joinError = nil
        Task { @MainActor in
            let error = await share.join(code: pasted)
            joining = false
            joinError = error
            if error == nil, share.isViewing { code = "" }
        }
    }

    // MARK: 附近

    private var nearbyCard: some View {
        card {
            HStack {
                Text(String(localized: "received.nearby.title"))
                    .font(.bodyMedium)
                    .foregroundColor(.textPrimary)
                Spacer()
                if share.nearbySearching {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                }
            }
            if share.nearbyDiscoveryOff {
                Text(String(localized: "received.nearby.discovery_off"))
                    .font(.bodySM)
                    .foregroundColor(.textTertiary)
            } else if share.nearbySearching {
                Text(String(localized: "received.nearby.searching"))
                    .font(.bodySM)
                    .foregroundColor(.textTertiary)
            } else if share.nearby.isEmpty {
                Text(String(localized: "received.nearby.empty"))
                    .font(.bodySM)
                    .foregroundColor(.textTertiary)
            } else {
                ForEach(share.nearby, id: \.endpointId) { peer in
                    HStack(spacing: Spacing.sm) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .foregroundColor(.signalGreen)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(peer.title.isEmpty ? String(localized: "share.untitled") : peer.title)
                                .font(.bodyMedium)
                                .foregroundColor(.textPrimary)
                                .lineLimit(1)
                            HStack(spacing: Spacing.xs) {
                                Text(peer.hostName.isEmpty ? String(localized: "share.unnamed") : peer.hostName)
                                Text(peer.shortLabel)
                                    .font(.system(size: 10, design: .monospaced))
                            }
                            .font(.bodySM)
                            .foregroundColor(.textTertiary)
                        }
                        Spacer()
                        if share.askingPeer == peer.endpointId {
                            // 最长等一分钟,必须说出来,还要给一条退路。
                            Text(String(localized: "received.nearby.asking"))
                                .font(.bodySM)
                                .foregroundColor(.textSecondary)
                            Button(String(localized: "received.nearby.abandon")) { share.abandonAsk() }
                        } else {
                            Button(String(localized: "received.nearby.ask")) { share.askToJoin(peer) }
                                .disabled(share.askingPeer != nil || share.isHosting)
                        }
                    }
                }
            }
            if share.nearbyDiscoveryOff == false {
                Text(String(localized: "received.nearby.note"))
                    .font(.bodySM)
                    .foregroundColor(.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityIdentifier("received.nearby")
    }

    // MARK: 留下来的文字稿

    private var transcriptsCard: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(String(localized: "received.transcripts.title"))
                .font(.bodyMedium)
                .foregroundColor(.textPrimary)
            if share.received.isEmpty {
                Text(String(localized: "received.transcripts.empty"))
                    .font(.bodySM)
                    .foregroundColor(.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(share.received, id: \.sessionId) { info in
                    transcriptRow(info)
                }
            }
        }
        .accessibilityIdentifier("received.transcripts")
    }

    private func transcriptRow(_ info: FfiSharedSessionInfo) -> some View {
        Button {
            openTranscript = ReceivedTranscriptRoute(
                id: info.sessionId,
                title: info.title,
                hostName: info.hostName
            )
        } label: {
            HStack(spacing: Spacing.md) {
                Image(systemName: "doc.text")
                    .foregroundColor(.textSecondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.rowTitle(info))
                        .font(.bodyMedium)
                        .foregroundColor(.textPrimary)
                        .lineLimit(1)
                    Text(Self.rowDetail(info))
                        .font(.bodySM)
                        .foregroundColor(.textTertiary)
                        .lineLimit(1)
                }
                Spacer()
                if share.canEditReceived(info.sessionId) == false {
                    Image(systemName: "lock")
                        .font(.system(size: 11))
                        .foregroundColor(.textTertiary)
                        .help(String(localized: "received.read_only_hint"))
                }
            }
            .padding(.vertical, Spacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            // 正在同步的那一份删了也会被下一笔同步拉回来 —— 先离开再删。
            Button(role: .destructive) {
                pendingDelete = info
            } label: {
                Label(String(localized: "received.delete"), systemImage: "trash")
            }
            .disabled(share.isViewing && share.scopeSessionId == info.sessionId)
        }
    }

    /// 标题,没有标题时是开头的话。
    static func rowTitle(_ info: FfiSharedSessionInfo) -> String {
        if info.title.isEmpty == false { return info.title }
        if info.preview.isEmpty == false { return info.preview }
        return String(localized: "share.untitled")
    }

    /// 「谁共享的 · 什么时候收到的 · 几句」。
    static func rowDetail(_ info: FfiSharedSessionInfo) -> String {
        var parts: [String] = []
        if info.hostName.isEmpty == false {
            parts.append(String(format: String(localized: "received.from_format"), info.hostName))
        }
        if info.receivedAtEpoch > 0 {
            parts.append(
                Date(timeIntervalSince1970: TimeInterval(info.receivedAtEpoch))
                    .formatted(date: .abbreviated, time: .shortened)
            )
        }
        parts.append(String(format: String(localized: "received.blocks_format"), Int64(info.blockCount)))
        return parts.joined(separator: " · ")
    }

    // MARK: 名字

    private var nameRow: some View {
        HStack(spacing: Spacing.sm) {
            if editingName {
                TextField(String(localized: "share.name.placeholder"), text: $nameDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                    .onSubmit(saveName)
                Button(String(localized: "common.save"), action: saveName)
            } else {
                Text(String(
                    format: String(localized: "share.name.shown_as_format"),
                    share.displayName.isEmpty ? String(localized: "share.name.default") : share.displayName
                ))
                .font(.bodySM)
                .foregroundColor(.textTertiary)
                Button(String(localized: "share.name.change")) {
                    nameDraft = share.displayName
                    editingName = true
                }
                .buttonStyle(.link)
                .font(.bodySM)
            }
        }
    }

    private func saveName() {
        share.setDisplayName(nameDraft)
        editingName = false
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm, content: content)
            .padding(Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.bgSurface)
            .overlay(
                RoundedRectangle(cornerRadius: Radius.md)
                    .strokeBorder(Color.borderGhost.opacity(0.4), lineWidth: Stroke.thin)
            )
            .clipShape(RoundedRectangle(cornerRadius: Radius.md))
    }
}

/// 打开一份收到的文字稿要的东西。
struct ReceivedTranscriptRoute: Identifiable {
    let id: String
    let title: String
    let hostName: String
}

// =========================================================================
// 远端实时画布
// =========================================================================

/// 主播预览帧的多语言呈现:一句一块,原文在上,译文跟在下面,段尾是尚未
/// 绑定到句子的补充译文(按语言各一条最新)。
///
/// 帧是 replace-in-full 的:整个画布每帧重建,没有增量状态。句子与译文的
/// 对应**不在这里重算**(share-p2p.md §3.2)。
struct SharedLivePreviewCanvas: View {
    let preview: FfiNotebookCaptureLivePreview
    /// 页面里只看最近的几句;完整的一场在字幕窗里。
    var recentLimit = 8

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            ForEach(preview.utterances.suffix(recentLimit), id: \.id) { utterance in
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
                languageChip(utterance.provisionalSourceLanguage ?? utterance.sourceLanguage)
                Text(utterance.sourceText)
                    .font(.body)
                    .foregroundColor(utterance.completion == "complete" ? .textPrimary : .textSecondary)
                    .textSelection(.enabled)
            }
            if let language = utterance.translatedLanguage,
               let text = utterance.translatedText,
               text.isEmpty == false {
                laneRow(language: language, text: text, isPartial: utterance.completion == "partial")
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
        Text(RecordingPresentation.languageName(language))
            .font(.captionMedium)
            .foregroundColor(.textTertiary)
            .frame(minWidth: 56, alignment: .trailing)
            .lineLimit(1)
            .accessibilityHidden(true)
    }

    /// 每语言取最新一条未撤回的译文。线上帧已过滤撤回,这里只按
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

    /// 没在正常出字的语言:「还在连」和「坏了不会再有字」是两句话。
    static func stalledLanes(_ lanes: [FfiNotebookCaptureLaneHealth]) -> [StalledLane] {
        lanes.compactMap { lane in
            let label = lane.targetLanguage.map(RecordingPresentation.languageName)
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
