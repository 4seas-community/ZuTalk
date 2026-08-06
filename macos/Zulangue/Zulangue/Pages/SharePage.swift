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

                // 状态横幅常驻。用户最需要知道的一句话是「现在到底怎么了」,
                // 而这一句以前根本不存在 —— 加入成功、加入失败、等主持人录音,
                // 三种情况在界面上长得一模一样,都是「什么也没发生」。
                statusBanner

                if let error = viewModel.errorMessage {
                    errorBanner(error)
                }

                if viewModel.isSharing {
                    activeSection

                    if !viewModel.lines.isEmpty {
                        captionSection
                    }
                } else {
                    startSection
                    joinSection
                }
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.vertical, Spacing.lg)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.bgRoot)
        .onAppear { viewModel.reload() }
    }

    /// 现在处于什么状态,以及接下来该做什么。
    private var statusBanner: some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Image(systemName: viewModel.status.icon)
                .foregroundColor(viewModel.status.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.status.title)
                    .font(.bodyMedium)
                    .foregroundColor(.textPrimary)
                // 「接下来做什么」和「现在是什么」一样重要 —— 少了它,
                // 一个正确的等待状态看起来和卡死没有区别。
                Text(viewModel.status.hint)
                    .font(.bodySM)
                    .foregroundColor(.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(Spacing.sm)
        .background(Color.textTertiary.opacity(0.08))
        .cornerRadius(6)
        .accessibilityIdentifier("share.status")
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.signalRed)
            Text(message)
                .font(.bodySM)
                .foregroundColor(.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(Spacing.sm)
        .background(Color.signalRed.opacity(0.1))
        .cornerRadius(6)
        .accessibilityIdentifier("share.error")
    }

    /// 开始共享。
    ///
    /// 首次为一个 Notebook 开启必须显式确认一次 —— 记住之后,在其中开始的录音会
    /// 默认参与共享,这一步不该是无声的。见 share-p2p.md 第 4.1 节。
    private var startSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            if viewModel.notebooks.isEmpty {
                Text(String(localized: "share.needs_notebook"))
                    .font(.bodySM)
                    .foregroundColor(.textSecondary)
            } else {
                Text(String(localized: "share.pick_notebook"))
                    .font(.bodyMedium)
                    .foregroundColor(.textPrimary)

                // 共享哪个 Notebook 必须是明确选的,不能沿用「当前打开的那个」——
                // 用户站在分享页上,看不见自己当前在哪个 Notebook 里。
                Picker("", selection: $viewModel.selectedNotebookID) {
                    ForEach(viewModel.notebooks, id: \.id) { notebook in
                        Text(notebook.title).tag(notebook.id)
                    }
                }
                .labelsHidden()
                .accessibilityIdentifier("share.notebook_picker")

                Picker("", selection: $viewModel.hostOnlySelection) {
                    Text(String(localized: "share.role.everyone")).tag(false)
                    Text(String(localized: "share.role.host")).tag(true)
                }
                .pickerStyle(.radioGroup)
                .accessibilityIdentifier("share.policy")

                Button(String(localized: "share.start")) {
                    viewModel.confirmingStart = true
                }
                .disabled(viewModel.selectedNotebookID.isEmpty)
                .accessibilityIdentifier("share.start")
            }
        }
        .confirmationDialog(
            String(localized: "share.start.confirm.title"),
            isPresented: $viewModel.confirmingStart
        ) {
            Button(String(localized: "share.start"), role: .destructive) {
                viewModel.start()
            }
            Button(String(localized: "share.cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "share.start.confirm.body"))
        }
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

            Text(viewModel.shortIdentity)
                .font(.caption)
                .foregroundColor(.textSecondary)
                .textSelection(.enabled)

            // 分享码必须**显示出来**,不能只提供一个复制按钮。复制一旦失效,
            // 用户就再没有第二条路把码交出去;而且看得见才能核对粘贴对不对。
            if let code = viewModel.shareCode {
                Text(String(localized: "share.your_code"))
                    .font(.bodyMedium)
                    .foregroundColor(.textPrimary)
                Text(code)
                    .font(.caption)
                    .foregroundColor(.textSecondary)
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .accessibilityIdentifier("share.code_text")

                HStack(spacing: Spacing.sm) {
                    Button(String(localized: "share.copy_code")) {
                        viewModel.copyShareCode()
                    }
                    .accessibilityIdentifier("share.copy_code")

                    if viewModel.copied {
                        Text(String(localized: "share.copied"))
                            .font(.bodySM)
                            .foregroundColor(.signalGreen)
                    }
                }
                Text(String(localized: "share.code_note"))
                    .font(.bodySM)
                    .foregroundColor(.textTertiary)
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
            // 这里以前有一个「直连 / 经中继」指示器,但它的值是写死的 true ——
            // 永远显示绿色「直连」,不管实际走的是什么。一个恒真的指示器比没有
            // 指示器更坏,所以先撤掉,等真实连接类型能拿到再加回来。
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

/// 分享页现在处于什么状态。
///
/// 引入这个类型是因为原来的界面**分不出**「加入成功在等主持人录音」和
///「加入失败了」—— 两者在屏幕上都是什么也没有。
enum ShareStatus {
    case idle
    case hostingWaiting
    case hostingLive
    case joinedWaiting
    case receiving

    var icon: String {
        switch self {
        case .idle: return "person.2"
        case .hostingWaiting, .joinedWaiting: return "clock"
        case .hostingLive, .receiving: return "dot.radiowaves.left.and.right"
        }
    }

    var tint: Color {
        switch self {
        case .idle: return .textTertiary
        case .hostingWaiting, .joinedWaiting: return .signalAmber
        case .hostingLive, .receiving: return .signalGreen
        }
    }

    var title: String {
        switch self {
        case .idle: return String(localized: "share.status.idle")
        case .hostingWaiting: return String(localized: "share.status.hosting_waiting")
        case .hostingLive: return String(localized: "share.status.hosting_live")
        case .joinedWaiting: return String(localized: "share.status.joined_waiting")
        case .receiving: return String(localized: "share.status.receiving")
        }
    }

    var hint: String {
        switch self {
        case .idle: return String(localized: "share.status.idle_hint")
        case .hostingWaiting: return String(localized: "share.status.hosting_waiting_hint")
        case .hostingLive: return String(localized: "share.status.hosting_live_hint")
        case .joinedWaiting: return String(localized: "share.status.joined_waiting_hint")
        case .receiving: return String(localized: "share.status.receiving_hint")
        }
    }
}

@MainActor
final class ShareViewModel: ObservableObject {
    @Published var pastedCode: String = ""
    @Published var hostOnlySelection: Bool = false
    @Published var confirmingStart: Bool = false
    @Published var selectedNotebookID: String = ""
    @Published private(set) var notebooks: [FfiNotebook] = []
    @Published private(set) var shortIdentity: String = "—"
    @Published private(set) var shareCode: String?
    @Published private(set) var isSharing: Bool = false
    @Published private(set) var hostOnly: Bool = false
    @Published private(set) var lines: [FfiSharedCaptionLine] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var status: ShareStatus = .idle
    @Published private(set) var copied: Bool = false

    /// 观看端的字幕投影靠轮询刷新。帧是 replace-in-full 的,跳帧无害,所以
    /// 「取最新状态」与「每帧回调」在观感上等价 —— 见 vt-ffi/src/share_api.rs。
    private var pollTimer: Timer?

    private var core: (any ZulangueCoreProtocol)? { CoreClient.shared.core }

    func reload() {
        guard let core else {
            // 以前这里是静默 return,于是核心没就绪时整个页面毫无反应。
            errorMessage = String(localized: "share.core_unavailable")
            return
        }
        shortIdentity = (try? core.shareIdentity().shortLabel) ?? "—"
        notebooks = (try? core.listNotebooks()) ?? []
        if selectedNotebookID.isEmpty {
            selectedNotebookID = NotebookSessionContextStore.shared.activeNotebookId
                ?? notebooks.first?.id ?? ""
        }
        // 分享码从核心取回,而不是只活在这里的内存里 —— 切走标签页再回来,
        // 以前就再也拿不到它了,而复制按钮还亮着。
        shareCode = core.currentShareCode()
        refreshState()
        startPollingIfNeeded()
    }

    func start() {
        guard let core else {
            errorMessage = String(localized: "share.core_unavailable")
            return
        }
        guard !selectedNotebookID.isEmpty else {
            errorMessage = String(localized: "share.needs_notebook")
            return
        }
        do {
            shareCode = try core.startSharing(
                notebookId: selectedNotebookID,
                sessionId: nil,
                hostOnly: hostOnlySelection
            )
            // 文档协同要在共享开始之后才接得上 —— 它靠当前房间的名册判定谁能写。
            try core.enableDocumentSync()
            errorMessage = nil
            enrollForRelayFallback()
            refreshState()
            startPollingIfNeeded()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func copyShareCode() {
        guard let shareCode else {
            errorMessage = String(localized: "share.no_code_yet")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(shareCode, forType: .string)
        copied = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            copied = false
        }
    }

    func join() {
        guard let core else {
            errorMessage = String(localized: "share.core_unavailable")
            return
        }
        let code = pastedCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return }
        do {
            try core.joinShare(code: code)
            pastedCode = ""
            errorMessage = nil
            enrollForRelayFallback()
            refreshState()
            startPollingIfNeeded()
        } catch {
            // 以前这行的结果没有任何地方显示,于是粘贴一个坏掉的分享码
            // 看起来就是「点了没反应」。
            errorMessage = String(localized: "share.join_failed")
        }
    }

    func stop() {
        guard let core else { return }
        try? core.stopSharing()
        shareCode = nil
        lines = []
        errorMessage = nil
        stopPolling()
        refreshState()
    }

    /// 把本机身份登记到邀请码服务,好让中继在打洞失败时肯放行。
    ///
    /// 不做这一步中继会拒绝每一个真实用户,而且拒绝是安静的:局域网直连照常可用,
    /// 只有跨网络时才连不上。失败不打扰用户 —— 它只影响回落,不影响直连。
    private func enrollForRelayFallback() {
        Task { await CommunityInviteSession.shared.enrollCurrentShareEndpoint() }
    }

    private func refreshState() {
        guard let core else { return }
        let state = core.shareState()
        isSharing = state.isSharing
        hostOnly = state.hostOnly
        lines = state.lines
        if shareCode == nil { shareCode = core.currentShareCode() }

        status = {
            if !state.isSharing { return .idle }
            if state.isHost {
                // 播出过帧才算真的在广播。没播过通常是还没开始录音,
                // 而不是网络有问题 —— 这两句话必须说得不一样。
                return state.broadcastRevision == nil ? .hostingWaiting : .hostingLive
            }
            return state.appliedRevision == nil ? .joinedWaiting : .receiving
        }()
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
