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
    @FocusState private var joinFieldFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                // 状态横幅常驻。用户最需要知道的一句话是「现在到底怎么了」,
                // 而这一句以前根本不存在 —— 加入成功、加入失败、等主持人录音,
                // 三种情况在界面上长得一模一样,都是「什么也没发生」。
                statusBanner

                // 音频约束是这个功能最该被看见的一句话,所以它常驻在页面顶部区域,
                // 而不是藏在设置或帮助里。
                audioNotice

                if let error = viewModel.errorMessage {
                    errorBanner(error)
                }

                // 主持人要先看到有人在敲门,这比其他任何东西都急。
                if !viewModel.joinRequests.isEmpty {
                    joinRequestsSection
                }

                if viewModel.isSharing {
                    identitySection
                    membersSection
                    activeSection

                    if !viewModel.lines.isEmpty {
                        captionSection
                    }
                } else {
                    // 角色是这个页面上最早、且互斥的一个决定:要么把自己的内容
                    // 分出去,要么加入别人的。以前两套器械混在一页里,想加入的人
                    // 要滚过主持人的全部器械才找得到粘贴框。
                    modePicker

                    switch viewModel.idleMode {
                    case .host:
                        identitySection
                        startSection
                    case .join:
                        joinSection
                        nearbySection
                        nicknameSection
                    }
                }

                // 收到与共享过的转录稿:房间散了内容还在,这一节不随
                // isSharing 显隐。
                if !viewModel.sharedSessions.isEmpty {
                    sharedSessionsSection
                }
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.vertical, Spacing.lg)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.bgRoot)
        .onAppear {
            viewModel.reload()
            if viewModel.isSharing == false, viewModel.idleMode == .join {
                viewModel.startNearbyAutoScan()
            }
        }
        .onDisappear { viewModel.viewDisappeared() }
    }

    /// 两条道:我来分享 / 加入别人的。
    private var modePicker: some View {
        Picker("", selection: $viewModel.idleMode) {
            Text(String(localized: "share.mode.host")).tag(ShareEntryMode.host)
            Text(String(localized: "share.mode.join")).tag(ShareEntryMode.join)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityIdentifier("share.mode")
        .onChange(of: viewModel.idleMode) { _, mode in
            // 切到加入道,光标直接落进粘贴框 —— 拿着码来的人下一步只有粘贴。
            joinFieldFocused = (mode == .join)
            // 附近的人不该要人按按钮才找:进入加入道即扫,持续刷新。
            if mode == .join {
                viewModel.startNearbyAutoScan()
            } else {
                viewModel.stopNearbyAutoScan()
            }
        }
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
            // 观看端的链路指示。真值来自 QUIC 当前选中的传输路径——
            // 「经中继」是 AP 隔离网络的诊断特征(双机清单第一/二条靠它)。
            // 没连上时不显示:「没连上」和「经中继」必须是两句话。
            if let link = viewModel.viewerLink {
                Label(
                    link == .direct
                        ? String(localized: "share.link.direct")
                        : String(localized: "share.link.relayed"),
                    systemImage: link == .direct ? "bolt.fill" : "antenna.radiowaves.left.and.right"
                )
                .font(.captionMedium)
                .foregroundColor(link == .direct ? .signalGreen : .signalAmber)
                .help(
                    link == .direct
                        ? String(localized: "share.link.direct_hint")
                        : String(localized: "share.link.relayed_hint")
                )
                .accessibilityIdentifier("share.link_path")
            }
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

    /// 房间里都有谁。
    ///
    /// 昵称是各人自己填的,可能重名也可能为空 —— 所以公钥一起显示。
    private var membersSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(String(localized: "share.members"))
                .font(.bodyMedium)
                .foregroundColor(.textPrimary)

            ForEach(viewModel.members, id: \.endpointId) { member in
                HStack(spacing: Spacing.sm) {
                    Circle()
                        .fill(member.isHost ? Color.signalGreen : Color.textTertiary)
                        .frame(width: 6, height: 6)
                    Text(member.displayName.isEmpty
                         ? String(localized: "share.members.unnamed")
                         : member.displayName)
                        .font(.bodySM)
                        .foregroundColor(.textPrimary)
                    if member.isMe {
                        Text(String(localized: "share.members.you"))
                            .font(.bodySM)
                            .foregroundColor(.textTertiary)
                    }
                    if member.isHost {
                        Text(String(localized: "share.members.host"))
                            .font(.bodySM)
                            .foregroundColor(.textTertiary)
                    }
                    Spacer()
                    // 主持人视角的链路诊断:谁在直连、谁在走中继。
                    // 「大家都经中继」= 这个 Wi-Fi 八成开了 AP 隔离。
                    if let link = member.link {
                        Label(
                            link == .direct
                                ? String(localized: "share.link.direct")
                                : String(localized: "share.link.relayed"),
                            systemImage: link == .direct
                                ? "bolt.fill"
                                : "antenna.radiowaves.left.and.right"
                        )
                        .font(.captionMedium)
                        .foregroundColor(link == .direct ? .signalGreen : .signalAmber)
                        .help(
                            link == .direct
                                ? String(localized: "share.link.direct_hint")
                                : String(localized: "share.link.relayed_hint")
                        )
                    }
                    Text(member.shortLabel)
                        .font(.caption)
                        .foregroundColor(.textTertiary)
                }
            }
        }
        .accessibilityIdentifier("share.members")
    }

    /// 有人想加入。
    ///
    /// 显示的名字是**对方自己写的**,唯一可信的身份是下面那串公钥 —— 所以两个
    /// 都摆出来,不能只显示名字。
    private var joinRequestsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(String(localized: "share.requests"))
                .font(.bodyMedium)
                .foregroundColor(.textPrimary)

            ForEach(viewModel.joinRequests, id: \.requestId) { request in
                HStack(spacing: Spacing.sm) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(request.displayName.isEmpty
                             ? String(localized: "share.requests.unnamed")
                             : request.displayName)
                            .font(.bodyMedium)
                            .foregroundColor(.textPrimary)
                        Text(request.shortLabel)
                            .font(.caption)
                            .foregroundColor(.textTertiary)
                    }
                    Spacer()
                    Button(String(localized: "share.requests.decline")) {
                        viewModel.decline(request.requestId)
                    }
                    Button(String(localized: "share.requests.approve")) {
                        viewModel.approve(request.requestId)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            Text(String(localized: "share.requests.note"))
                .font(.bodySM)
                .foregroundColor(.textTertiary)
        }
        .accessibilityIdentifier("share.requests")
    }

    /// 同一网络里的人。
    private var nearbySection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
                Text(String(localized: "share.nearby"))
                    .font(.bodyMedium)
                    .foregroundColor(.textPrimary)
                Spacer()
                Button(viewModel.scanning
                       ? String(localized: "share.nearby.scanning")
                       : String(localized: "share.nearby.scan")) {
                    viewModel.scanNearby()
                }
                .disabled(viewModel.scanning)
                .accessibilityIdentifier("share.nearby.scan")
            }

            if viewModel.nearby.isEmpty {
                Text(String(localized: "share.nearby.empty"))
                    .font(.bodySM)
                    .foregroundColor(.textTertiary)
            } else {
                ForEach(viewModel.nearby, id: \.endpointId) { peer in
                    HStack(spacing: Spacing.sm) {
                        Text(peer.shortLabel)
                            .font(.caption)
                            .foregroundColor(.textSecondary)
                        Spacer()
                        if viewModel.askingPeer == peer.endpointId {
                            // 等待最长一分钟,必须说出来,还要给一条退路 ——
                            // 敲错门的人不该被钉在原地等超时。
                            Text(String(localized: "share.nearby.asking"))
                                .font(.bodySM)
                                .foregroundColor(.textSecondary)
                            Button(String(localized: "share.nearby.abandon")) {
                                viewModel.abandonAsk()
                            }
                        } else {
                            Button(String(localized: "share.nearby.ask")) {
                                viewModel.askToJoin(peer.endpointId)
                            }
                            // 单飞:一次只敲一扇门,其余行等这一问有了结果。
                            .disabled(viewModel.askingPeer != nil)
                        }
                    }
                }
            }

            Text(String(localized: "share.nearby.note"))
                .font(.bodySM)
                .foregroundColor(.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("share.nearby")
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

                // 范围:整本 vs 单条录音。单条才有收端落库与协同订正
                // (Notebook 范围 v1 只有字幕,见 share-p2p.md §11)。
                Picker("", selection: $viewModel.shareWholeNotebook) {
                    Text(String(localized: "share.scope.notebook")).tag(true)
                    Text(String(localized: "share.scope.single")).tag(false)
                }
                .pickerStyle(.radioGroup)
                .accessibilityIdentifier("share.scope")

                if !viewModel.shareWholeNotebook {
                    if viewModel.recentSessions.isEmpty {
                        Text(String(localized: "share.scope.no_sessions"))
                            .font(.bodySM)
                            .foregroundColor(.textSecondary)
                    } else {
                        Picker("", selection: $viewModel.selectedSessionID) {
                            ForEach(viewModel.recentSessions, id: \.sessionId) { run in
                                Text(Self.sessionLabel(run)).tag(run.sessionId)
                            }
                        }
                        .labelsHidden()
                        .accessibilityIdentifier("share.session_picker")
                    }
                }

                Picker("", selection: $viewModel.hostOnlySelection) {
                    Text(String(localized: "share.role.everyone")).tag(false)
                    Text(String(localized: "share.role.host")).tag(true)
                }
                .pickerStyle(.radioGroup)
                .accessibilityIdentifier("share.policy")

                Button(String(localized: "share.start")) {
                    viewModel.confirmingStart = true
                }
                .disabled(
                    viewModel.selectedNotebookID.isEmpty
                        || (!viewModel.shareWholeNotebook && viewModel.selectedSessionID.isEmpty)
                )
                .accessibilityIdentifier("share.start")
            }
        }
        .confirmationDialog(
            viewModel.shareWholeNotebook
                ? String(localized: "share.start.confirm.title")
                : String(localized: "share.start.confirm.session_title"),
            isPresented: $viewModel.confirmingStart
        ) {
            Button(String(localized: "share.start"), role: .destructive) {
                viewModel.start()
            }
            Button(String(localized: "share.cancel"), role: .cancel) {}
        } message: {
            // 这段话必须描述真实行为。它以前承诺「之后在这个 Notebook 里开始的
            // 录音会默认共享」—— 但那个 per-Notebook 记忆并不存在,共享只活到
            // 停止或退出为止。文案宁可少承诺,不能多承诺。
            Text(viewModel.shareWholeNotebook
                 ? String(localized: "share.start.confirm.body")
                 : String(localized: "share.start.confirm.session_body"))
        }
    }

    /// 收到与共享过的转录稿(台账即 shared/ 目录)。点开即读,权限内可订正,
    /// 右键可删本机副本。
    private var sharedSessionsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(String(localized: "share.received.title"))
                .font(.bodyMedium)
                .foregroundColor(.textPrimary)
            ForEach(viewModel.sharedSessions, id: \.sessionId) { info in
                Button {
                    viewModel.openSharedSession = SharedSessionRoute(id: info.sessionId)
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
                            // 什么时候收的 + 有多少内容。没有时间戳,昨天收的
                            // 和三周前收的在列表里没法区分。
                            Text(Self.receivedDetail(info))
                                .font(.captionMedium)
                                .foregroundColor(.textTertiary)
                        }
                        Spacer()
                        // 只有当前房间约束的那一条挂锁 —— 只读是房间的属性,
                        // 不是收件的属性,散场后的收件都是本机批注。
                        if viewModel.canEditSharedSession(info.sessionId) == false {
                            Image(systemName: "lock")
                                .font(.system(size: 10))
                                .foregroundColor(.textTertiary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button(role: .destructive) {
                        viewModel.pendingDeleteSession = info
                    } label: {
                        Text(String(localized: "share.received.delete"))
                    }
                }
            }
        }
        .accessibilityIdentifier("share.received")
        .sheet(item: $viewModel.openSharedSession) { route in
            SharedSessionView(
                sessionId: route.id,
                editable: viewModel.canEditSharedSession(route.id)
            )
        }
        .confirmationDialog(
            String(localized: "share.received.delete.confirm_title"),
            isPresented: Binding(
                get: { viewModel.pendingDeleteSession != nil },
                set: { if !$0 { viewModel.pendingDeleteSession = nil } }
            ),
            presenting: viewModel.pendingDeleteSession
        ) { info in
            Button(String(localized: "share.received.delete"), role: .destructive) {
                viewModel.deleteSharedSession(info.sessionId)
            }
            Button(String(localized: "share.cancel"), role: .cancel) {}
        } message: { _ in
            Text(String(localized: "share.received.delete.confirm_body"))
        }
    }

    /// 「收到时间 · N 块」。文件时间拿不到时只剩块数。
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

    private static func sessionLabel(_ run: FfiNotebookCaptureHistoryRun) -> String {
        let stamp = run.completedAt ?? run.createdAt
        let short = String(run.sessionId.prefix(8))
        return stamp.isEmpty ? short : "\(stamp) · \(short)"
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
            // 昵称:房间里和「附近的人」列表都靠它认出你。
            Text(String(localized: "share.nickname"))
                .font(.bodyMedium)
                .foregroundColor(.textPrimary)
            TextField("", text: $viewModel.nickname, prompt: Text(String(localized: "share.nickname.prompt")))
                .textFieldStyle(.roundedBorder)
                .onSubmit { viewModel.saveNickname() }
                .accessibilityIdentifier("share.nickname")
            Text(String(localized: "share.nickname.note"))
                .font(.bodySM)
                .foregroundColor(.textTertiary)

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
                    .focused($joinFieldFocused)
                    // 粘完按回车就该走,不该再去找按钮。
                    .onSubmit { viewModel.join() }
                    .accessibilityIdentifier("share.join.field")

                Button(String(localized: "share.join")) {
                    viewModel.join()
                }
                .disabled(viewModel.pastedCode.isEmpty)
            }
        }
    }

    /// 昵称,给加入道单独用 —— 「请求加入」会把名字发给对方。
    private var nicknameSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(String(localized: "share.nickname"))
                .font(.bodyMedium)
                .foregroundColor(.textPrimary)
            TextField("", text: $viewModel.nickname, prompt: Text(String(localized: "share.nickname.prompt")))
                .textFieldStyle(.roundedBorder)
                .onSubmit { viewModel.saveNickname() }
                .accessibilityIdentifier("share.nickname.join")
            Text(String(localized: "share.nickname.note"))
                .font(.bodySM)
                .foregroundColor(.textTertiary)
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

            if viewModel.isHost {
                Button(String(localized: "share.stop"), role: .destructive) {
                    viewModel.stop()
                }
                .accessibilityIdentifier("share.stop")

                // 停止共享的真实语义。不写这句,用户会以为点了停止对方就看不到了。
                Text(String(localized: "share.stop_note"))
                    .font(.bodySM)
                    .foregroundColor(.textTertiary)
            } else {
                // 观看端不是在「停止共享」—— 那是主持人的动作,连同那句
                // 「删不掉对方已收到的」警告,对只想离开的人全是错话。
                Button(String(localized: "share.leave")) {
                    viewModel.stop()
                }
                .accessibilityIdentifier("share.leave")

                Text(String(localized: "share.leave_note"))
                    .font(.bodySM)
                    .foregroundColor(.textTertiary)
            }
        }
    }
}

/// sheet(item:) 的最小身份包装:内容就是 session id。
struct SharedSessionRoute: Identifiable {
    let id: String
}

/// 空闲态的两条道。角色互斥,页面第一屏就该分叉。
enum ShareEntryMode {
    case host
    case join
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
    /// 主持人明确道别了。与「接收中的最后一帧」必须是两句话 —— 以前这两种
    /// 情况在屏幕上一模一样,画面定格,像卡死。
    case hostLeft

    var icon: String {
        switch self {
        case .idle: return "person.2"
        case .hostingWaiting, .joinedWaiting: return "clock"
        case .hostingLive, .receiving: return "dot.radiowaves.left.and.right"
        case .hostLeft: return "antenna.radiowaves.left.and.right.slash"
        }
    }

    var tint: Color {
        switch self {
        case .idle, .hostLeft: return .textTertiary
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
        case .hostLeft: return String(localized: "share.status.host_left")
        }
    }

    var hint: String {
        switch self {
        case .idle: return String(localized: "share.status.idle_hint")
        case .hostingWaiting: return String(localized: "share.status.hosting_waiting_hint")
        case .hostingLive: return String(localized: "share.status.hosting_live_hint")
        case .joinedWaiting: return String(localized: "share.status.joined_waiting_hint")
        case .receiving: return String(localized: "share.status.receiving_hint")
        case .hostLeft: return String(localized: "share.status.host_left_hint")
        }
    }
}

@MainActor
final class ShareViewModel: ObservableObject {
    @Published var pastedCode: String = ""
    /// 空闲态选中的道:分享自己的,还是加入别人的。
    @Published var idleMode: ShareEntryMode = .host
    @Published var hostOnlySelection: Bool = false
    /// 共享范围:整本 Notebook(仅字幕)或单条录音(字幕 + 落库协同)。
    @Published var shareWholeNotebook: Bool = true
    @Published var selectedSessionID: String = "" {
        didSet { /* picker 直连,无副作用 */ }
    }
    @Published private(set) var recentSessions: [FfiNotebookCaptureHistoryRun] = []
    @Published private(set) var sharedSessions: [FfiSharedSessionInfo] = []
    /// 打开中的共享 session 详情(sheet)。
    @Published var openSharedSession: SharedSessionRoute?
    /// 等确认删除的收件。确认对话框以它有无为开关。
    @Published var pendingDeleteSession: FfiSharedSessionInfo?
    /// 当前房间按单次录音共享时,那一场的 session id。只读约束只属于它。
    @Published private(set) var scopeSessionId: String?
    /// 收件 Notebook 只需要确保一次;它在核心里是幂等创建的。
    private var ensuredInboxNotebook = false
    @Published var confirmingStart: Bool = false
    @Published var selectedNotebookID: String = "" {
        didSet { loadRecentSessions() }
    }
    @Published private(set) var notebooks: [FfiNotebook] = []
    @Published private(set) var shortIdentity: String = "—"
    @Published private(set) var shareCode: String?
    @Published private(set) var isSharing: Bool = false
    /// 本机是当前房间的主持人。决定收尾按钮是「停止共享」还是「离开房间」。
    @Published private(set) var isHost: Bool = false
    @Published private(set) var hostOnly: Bool = false
    @Published private(set) var lines: [FfiSharedCaptionLine] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var status: ShareStatus = .idle
    /// 观看端到主持人的当前链路;没在观看或还没连上时为 nil。
    @Published private(set) var viewerLink: FfiShareLinkPath?
    @Published private(set) var copied: Bool = false
    @Published private(set) var nearby: [FfiNearbyPeer] = []
    @Published private(set) var joinRequests: [FfiJoinRequest] = []
    @Published private(set) var scanning: Bool = false
    /// 正在等哪台机器回答。这一等最长一分钟,界面必须说出来,还必须可放弃。
    @Published private(set) var askingPeer: String?
    /// 放弃计数。放弃后迟到的回答按代际号丢弃 —— FFI 调用本身要等到
    /// 对方回答或超时,取消的只是**我们对结果的关心**。
    private var askGeneration = 0
    /// 加入道的自动扫描。手动按钮保留作立即刷新。
    private var nearbyScanTimer: Timer?
    @Published private(set) var members: [FfiRoomMember] = []
    @Published var nickname: String = "" {
        didSet { saveNicknameDebounced() }
    }
    private var nicknameSaveTask: Task<Void, Never>?
    private var errorExpiryTask: Task<Void, Never>?

    /// 观看端的字幕投影靠轮询刷新。帧是 replace-in-full 的,跳帧无害,所以
    /// 「取最新状态」与「每帧回调」在观感上等价 —— 见 vt-ffi/src/share_api.rs。
    private var pollTimer: Timer?

    private var core: (any ZulangueCoreProtocol)? { CoreClient.shared.core }

    /// 错误会过期。「They declined.」是一句回答,不是一块墓碑 —— 挂十秒够读完,
    /// 之后自己消失,不用等下一次成功操作来冲掉它。
    private func showError(_ message: String) {
        errorMessage = message
        errorExpiryTask?.cancel()
        errorExpiryTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard Task.isCancelled == false else { return }
            errorMessage = nil
        }
    }

    private func clearError() {
        errorExpiryTask?.cancel()
        errorMessage = nil
    }

    /// 页面离场就停轮询。以前只有「停止共享」会停 —— 逛过一次分享页,
    /// 5 Hz 的定时器(每拍还要扫一遍 shared/ 目录)就跟到 App 退出。
    func viewDisappeared() {
        stopPolling()
        stopNearbyAutoScan()
    }

    func reload() {
        guard let core else {
            // 以前这里是静默 return,于是核心没就绪时整个页面毫无反应。
            showError(String(localized: "share.core_unavailable"))
            return
        }
        shortIdentity = (try? core.shareIdentity().shortLabel) ?? "—"
        if nickname.isEmpty { nickname = core.shareDisplayName() }
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
            showError(String(localized: "share.core_unavailable"))
            return
        }
        guard !selectedNotebookID.isEmpty else {
            showError(String(localized: "share.needs_notebook"))
            return
        }
        do {
            // 单条录音按 session 范围共享(notebookId 必须为 nil,FFI 校验
            // 二选一);整本仍按 Notebook 范围。
            shareCode = try core.startSharing(
                notebookId: shareWholeNotebook ? selectedNotebookID : nil,
                sessionId: shareWholeNotebook ? nil : selectedSessionID,
                hostOnly: hostOnlySelection
            )
            // 文档协同要在共享开始之后才接得上 —— 它靠当前房间的名册判定谁能写。
            try core.enableDocumentSync()
            clearError()
            enrollForRelayFallback()
            refreshState()
            startPollingIfNeeded()
        } catch {
            showError(error.localizedDescription)
        }
    }

    /// 改昵称边打边存太吵,停手一会儿再存。
    private func saveNicknameDebounced() {
        nicknameSaveTask?.cancel()
        nicknameSaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            saveNickname()
        }
    }

    func saveNickname() {
        guard let core else { return }
        try? core.setShareDisplayName(name: nickname)
    }

    func copyShareCode() {
        guard let shareCode else {
            showError(String(localized: "share.no_code_yet"))
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
            showError(String(localized: "share.core_unavailable"))
            return
        }
        let code = pastedCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return }
        do {
            try core.joinShare(code: code)
            pastedCode = ""
            clearError()
            enrollForRelayFallback()
            refreshState()
            startPollingIfNeeded()
        } catch {
            // 以前这行的结果没有任何地方显示,于是粘贴一个坏掉的分享码
            // 看起来就是「点了没反应」。通用句给方向,底层原因跟在后面 ——
            // 码过期、范围不符、网络不通是三种不同的下一步。
            showError(
                String(localized: "share.join_failed")
                    + "\n" + error.localizedDescription
            )
        }
    }

    /// 扫一遍同一网络里的 Zulangue。
    func scanNearby() {
        guard let core else {
            showError(String(localized: "share.core_unavailable"))
            return
        }
        // 自动扫描每 10 秒来一次,一次要阻塞后台线程 3 秒 —— 不叠加。
        guard scanning == false else { return }
        scanning = true
        clearError()
        // **不能在主线程上调它。** nearbyPeers 是同步的,要阻塞三秒收集 mDNS 宣告;
        // 在 @MainActor 上调用会把界面冻住三秒。
        Task.detached {
            let result = Result { try core.nearbyPeers(seconds: 3) }
            await MainActor.run {
                self.scanning = false
                switch result {
                case .success(let peers): self.nearby = peers
                case .failure(let error): self.showError(error.localizedDescription)
                }
            }
        }
    }

    /// 向同一网络里的某台机器请求加入。批准后自动进房。
    ///
    /// 单飞:一次只敲一扇门。等待可放弃 —— 放弃后 FFI 调用继续跑到超时,
    /// 但结果按代际号丢弃,界面立即解锁。
    func askToJoin(_ endpointID: String) {
        guard let core, askingPeer == nil else { return }
        clearError()
        askingPeer = endpointID
        askGeneration += 1
        let generation = askGeneration
        // **绝不能在主线程上调它。** 它会一直等到对方点批准或超时 —— 最长一分钟。
        // 在 @MainActor 上调用会让整个 App 冻住那么久。
        Task.detached {
            let result = Result { try core.requestToJoinNearby(endpointId: endpointID) }
            await MainActor.run {
                // 用户已放弃这一问:迟到的回答不再有人关心。
                guard generation == self.askGeneration else { return }
                self.askingPeer = nil
                switch result {
                case .success(.joined):
                    // 对方批准了,钥匙已经经局域网直连交过来,房间也进了。
                    self.enrollForRelayFallback()
                    self.reload()
                case .success(.notSharing):
                    self.showError(String(localized: "share.nearby.not_sharing"))
                case .success(.declined):
                    self.showError(String(localized: "share.nearby.declined"))
                case .success(.timedOut):
                    self.showError(String(localized: "share.nearby.timed_out"))
                case .failure(let error):
                    self.showError(error.localizedDescription)
                }
            }
        }
    }

    /// 放弃当前的加入等待。对方那边的请求会自然超时消失。
    func abandonAsk() {
        askGeneration += 1
        askingPeer = nil
    }

    /// 加入道的自动扫描:进入即扫,之后每 10 秒刷一遍。
    /// 手动「找一找」按钮保留,作立即刷新。
    func startNearbyAutoScan() {
        guard nearbyScanTimer == nil else { return }
        scanNearby()
        nearbyScanTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scanNearby() }
        }
    }

    func stopNearbyAutoScan() {
        nearbyScanTimer?.invalidate()
        nearbyScanTimer = nil
    }

    func approve(_ requestID: String) {
        guard let core else { return }
        _ = try? core.approveJoinRequest(requestId: requestID)
        refreshState()
    }

    func decline(_ requestID: String) {
        guard let core else { return }
        _ = core.declineJoinRequest(requestId: requestID)
        refreshState()
    }

    func stop() {
        guard let core else { return }
        try? core.stopSharing()
        shareCode = nil
        lines = []
        clearError()
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

    /// 选中 Notebook 的近期录音,给「单条录音」范围选。
    private func loadRecentSessions() {
        guard let core, !selectedNotebookID.isEmpty else {
            recentSessions = []
            return
        }
        recentSessions =
            (try? core.listNotebookCaptureHistorySummaries(notebookId: selectedNotebookID)) ?? []
        if !recentSessions.contains(where: { $0.sessionId == selectedSessionID }) {
            selectedSessionID = recentSessions.first?.sessionId ?? ""
        }
    }

    /// 一条收件可否编辑。只读约束**只属于当前房间的那份文档**:只读房间里的
    /// 观看者改它,推送会被宿主拒收,本地改了也是孤儿编辑。其它收件 ——
    /// 散场后留下的、或与当前房间无关的 —— 都是本机批注,随便改。
    /// 以前这是一个全局开关,进一个只读房间会把所有历史收件都锁上。
    func canEditSharedSession(_ sessionId: String) -> Bool {
        !(isSharing && !isHost && hostOnly && scopeSessionId == sessionId)
    }

    /// 删除一份收到的转录稿。只删本机副本 —— 与停止共享同一条真话,
    /// 别人手里的不受影响。
    func deleteSharedSession(_ sessionId: String) {
        guard let core else { return }
        pendingDeleteSession = nil
        do {
            try core.deleteSharedSession(sessionId: sessionId)
        } catch {
            showError(error.localizedDescription)
        }
        refreshState()
    }

    private func refreshState() {
        guard let core else { return }
        let state = core.shareState()
        isSharing = state.isSharing
        // 进了房间就不用再找人了。
        if isSharing { stopNearbyAutoScan() }
        isHost = state.isHost
        hostOnly = state.hostOnly
        viewerLink = state.viewerLink
        scopeSessionId = state.scopeSessionId
        lines = state.lines
        if shareCode == nil { shareCode = core.currentShareCode() }
        joinRequests = core.pendingJoinRequests()
        members = core.roomMembers()

        sharedSessions = core.listSharedSessions()

        // 第一次出现收件时,把「分享」收件 Notebook 立起来 —— 它是收到内容
        // 在库里的家(share-p2p.md §11),核心里幂等,这里只确保一次。
        if sharedSessions.isEmpty == false, ensuredInboxNotebook == false {
            ensuredInboxNotebook = true
            _ = try? core.sharedInboxNotebook()
        }

        status = {
            if !state.isSharing { return .idle }
            if state.isHost {
                // 播出过帧才算真的在广播。没播过通常是还没开始录音,
                // 而不是网络有问题 —— 这两句话必须说得不一样。
                return state.broadcastRevision == nil ? .hostingWaiting : .hostingLive
            }
            // 主持人道别优先于「接收中」:散场后画面定格在最后一帧,
            // 不说这一句,它和网络卡死无法区分。
            if state.hostLeft { return .hostLeft }
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
