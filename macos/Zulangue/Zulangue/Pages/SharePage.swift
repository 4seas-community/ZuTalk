// SharePage.swift
// Zulangue 分享 — 点对点字幕与文档协同。
//
// 设计见 docs/architecture/share-p2p.md。这一版承载可见状态与入口:
//   - 本机分享密钥(iroh EndpointId)与分享码
//   - 加入他人的房间
//   - 停止共享,以及它到底停掉了什么
//
// 三条界限必须在界面上说清楚,它们都不是能靠措辞含糊过去的:
//   1. 音频永远不会被共享(vt-share 在依赖图上就够不到音频解密);
//   2. 停止共享只停后续,删不掉对方已经收到的内容(CRDT 合并不可撤回);
//   3. 「只读」由每个接收端自行过滤,不是发送端强制 —— 界面不得暗示更强的保证。

import Combine
import SwiftUI

struct SharePage: View {
    @StateObject private var viewModel = ShareViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                identitySection

                // 音频约束是这个功能最该被看见的一句话,所以它常驻在页面顶部区域,
                // 而不是藏在设置或帮助里。
                audioNotice

                joinSection

                if viewModel.isSharing {
                    activeSection

                    if !viewModel.lines.isEmpty {
                        captionSection
                    }
                } else {
                    EmptyState(
                        icon: "person.2",
                        title: String(localized: "share.empty"),
                        description: String(localized: "share.role.everyone")
                    )
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.vertical, Spacing.lg)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.bgRoot)
        .onAppear { viewModel.reload() }
    }

    /// 对方的实时字幕。只读投影,不落库 —— 看到的是别人的内容,不是本机 Notebook。
    private var captionSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            ForEach(Array(viewModel.lines.enumerated()), id: \.offset) { _, line in
                VStack(alignment: .leading, spacing: 2) {
                    Text(line.sourceText)
                        .font(.body)
                        .foregroundColor(.textPrimary)
                    if let translated = line.targetText, !translated.isEmpty {
                        Text(translated)
                            .font(.bodySM)
                            .foregroundColor(.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityIdentifier("share.captions")
    }

    private var identitySection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(String(localized: "share.identity"))
                .font(.bodyMedium)
                .foregroundColor(.textPrimary)

            HStack(spacing: Spacing.sm) {
                Text(viewModel.shortIdentity)
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.textSecondary)
                    .textSelection(.enabled)

                Spacer()

                Button(String(localized: "share.copy_code")) {
                    viewModel.copyShareCode()
                }
                .disabled(!viewModel.isSharing)
                .accessibilityIdentifier("share.copy_code")
            }
        }
    }

    private var audioNotice: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "waveform.slash")
                .foregroundColor(.textSecondary)
            Text(String(localized: "share.audio_never"))
                .font(.bodySM)
                .foregroundColor(.textSecondary)
        }
        .accessibilityIdentifier("share.audio_never")
    }

    private var joinSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(String(localized: "share.join"))
                .font(.bodyMedium)
                .foregroundColor(.textPrimary)

            HStack(spacing: Spacing.sm) {
                TextField("", text: $viewModel.pastedCode, prompt: Text(verbatim: "zulangueshare…"))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .accessibilityIdentifier("share.join.field")

                Button(String(localized: "share.join")) {
                    viewModel.join()
                }
                .disabled(viewModel.pastedCode.isEmpty)
            }
        }
    }

    private var activeSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
                // 直连还是经中继要能看见:会议室 Wi-Fi 常开客户端隔离,
                // 出问题时用户得知道该找谁。
                Image(systemName: viewModel.isDirect ? "bolt.horizontal" : "arrow.triangle.branch")
                    .foregroundColor(viewModel.isDirect ? .signalGreen : .signalAmber)
                Text(viewModel.isDirect
                     ? String(localized: "share.direct")
                     : String(localized: "share.relayed"))
                    .font(.bodySM)
                    .foregroundColor(.textSecondary)
            }

            Text(viewModel.hostOnly
                 ? String(localized: "share.role.host")
                 : String(localized: "share.role.everyone"))
                .font(.bodySM)
                .foregroundColor(.textSecondary)

            Button(String(localized: "share.stop"), role: .destructive) {
                viewModel.stop()
            }
            .accessibilityIdentifier("share.stop")

            // 停止共享的真实语义。不写这句,用户会以为点了停止对方就看不到了。
            Text(String(localized: "share.stop_note"))
                .font(.bodySM)
                .foregroundColor(.textTertiary)
        }
    }
}

@MainActor
final class ShareViewModel: ObservableObject {
    @Published var pastedCode: String = ""
    @Published private(set) var shortIdentity: String = "—"
    @Published private(set) var isSharing: Bool = false
    @Published private(set) var isDirect: Bool = true
    @Published private(set) var hostOnly: Bool = false
    @Published private(set) var lines: [FfiSharedCaptionLine] = []
    @Published private(set) var errorMessage: String?

    /// 观看端的字幕投影靠轮询刷新。帧是 replace-in-full 的,跳帧无害,所以
    /// 「取最新状态」与「每帧回调」在观感上等价 —— 见 vt-ffi/src/share_api.rs。
    private var pollTimer: Timer?
    private var shareCode: String?

    private var core: (any ZulangueCoreProtocol)? { CoreClient.shared.core }

    func reload() {
        guard let core else { return }
        shortIdentity = (try? core.shareIdentity().shortLabel) ?? "—"
        refreshState()
        startPollingIfNeeded()
    }

    func copyShareCode() {
        guard let shareCode else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(shareCode, forType: .string)
    }

    func join() {
        guard let core else { return }
        let code = pastedCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return }
        do {
            try core.joinShare(code: code)
            pastedCode = ""
            errorMessage = nil
            refreshState()
            startPollingIfNeeded()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stop() {
        guard let core else { return }
        try? core.stopSharing()
        shareCode = nil
        lines = []
        stopPolling()
        refreshState()
    }

    private func refreshState() {
        guard let core else { return }
        let state = core.shareState()
        isSharing = state.isSharing
        hostOnly = state.hostOnly
        lines = state.lines
    }

    private func startPollingIfNeeded() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshState() }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    deinit {
        pollTimer?.invalidate()
    }
}
