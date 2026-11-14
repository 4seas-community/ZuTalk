// ShareHostPanel.swift
// 分享的两张面板:给观众看正在录的这一场(录音条上弹出),以及分享一段录好的
// 录音(录音行菜单、录音页顶栏打开)。
//
// 分享以前要对方也装 ZuTalk、粘贴一百多个字符的加入码、在同一个网络里互相
// 找到 —— 会场里拿手机的人一个都进不来。现在对方只需要一个浏览器:
//   - 给观众看字幕:扫码或打开链接,就能看实时字幕和翻译;
//   - 录好的录音:发一份文字稿文件,或开一条 24 小时的只读链接。
//
// 几句必须说对的话(share-links.md):
//   - 音频从不离开这台 Mac;
//   - 链接端到端加密,服务器只转发看不懂的内容 —— 但拿到链接的人都能看;
//   - 停了以后,不留稿就当场删掉;留稿则约 24 小时后删;
//   - 录音链接 24 小时后失效,随时可以撤销。
//
// 0.8.2 把这几句整段铺在面板上,每个开关下面还各挂一句。现在面板上不写句子
// (docs/product/interface-layers.md「界面怎么写」):每个控件是一颗写着一个词的
// 胶囊,那几句告知收成最多三条「图标加两三个字」的事实(`ShareFactsRow`),
// 原话一句没丢 —— 在各条事实和各颗胶囊的悬停提示里,也在那一行末尾的 ⓘ 里。
//
// 两张面板都拆成两层:外层(`LiveSharePanel`、`RecordingShareSheet`)读状态源、
// 发动作;里层(`…Content`)只吃值。这样每一种状态都能在测试里原样摆出来看。

import AppKit
import Combine
import CoreImage.CIFilterBuiltins
import SwiftUI

// MARK: - 给观众看字幕

/// 录音条上的那颗按钮:没在给观众看时是入口,正在看时是状态 —— 一粒电波加
/// 几个人在看。
///
/// 这是主持活动的人用的工具(docs/product/interface-layers.md 第三层):
/// 录音条只在「我在主持活动」开着、或这一场正在给观众看时摆它。别的人从录音条
/// 「⋯」里的「给观众看字幕…」进同一张面板(`LiveSharePopover`)。
struct LiveShareButton: View {
    let sessionId: String
    /// 观看页上显示的标题。
    let title: String
    var compact = false

    @ObservedObject private var share = ShareActivityStore.shared
    @ObservedObject private var nearby = NearbyStore.shared
    @State private var showsPanel = false

    /// 这一场此刻是不是正在给别人看:走链接,或走附近。
    @MainActor
    static func isLive(
        sessionId: String,
        share: ShareActivityStore,
        nearby: NearbyStore
    ) -> Bool {
        share.isBroadcasting(sessionId: sessionId) || nearby.isLive(sessionId: sessionId)
    }

    /// 录音条上摆不摆这个按钮。一开始给观众看,按钮就在 —— 开关关着也在,
    /// 否则停止的唯一入口会跟着开关一起消失。
    @MainActor
    static func showsInBar(hostMode: HostMode, live: Bool) -> Bool {
        hostMode.shows(inUse: live)
    }

    var body: some View {
        let live = Self.isLive(sessionId: sessionId, share: share, nearby: nearby)
        let viewers = self.viewers
        Button {
            showsPanel.toggle()
        } label: {
            Group {
                if compact {
                    Image(systemName: live ? "dot.radiowaves.left.and.right" : "qrcode")
                        .frame(width: 30, height: 30)
                } else {
                    Label(
                        LiveShareText.barLabel(live: live, viewers: viewers),
                        systemImage: live ? "dot.radiowaves.left.and.right" : "qrcode"
                    )
                    .padding(.horizontal, Spacing.sm + 2)
                    .frame(minHeight: 30)
                }
            }
            .font(.bodyMedium)
            .foregroundColor(live ? .signalGreen : .textPrimary)
            .background((live ? Color.signalGreen : Color.textPrimary).opacity(0.1))
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(String(localized: live ? "share.live.bar_on_hint" : "share.live.bar_hint"))
        // 条上只写人数;「正在给观众看字幕」这半句由电波图标和绿色说,读屏照旧
        // 念整句。
        .accessibilityLabel(Text(live
            ? LiveShareText.status(viewers: viewers)
            : String(localized: "share.live.bar")))
        .accessibilityIdentifier("recording-bar.share")
        .popover(isPresented: $showsPanel, arrowEdge: .bottom) {
            LiveSharePopover(sessionId: sessionId, title: title)
        }
    }

    private var viewers: UInt32 {
        (share.isBroadcasting(sessionId: sessionId) ? share.live?.viewers ?? 0 : 0)
            + (nearby.isLive(sessionId: sessionId) ? nearby.status?.liveViewers ?? 0 : 0)
    }
}

enum LiveShareText {
    /// 观看页顶上的标题:主题名,不在主题里的录音就是「字幕 · 9月28日」。
    static func title(topic: String?, now: Date = Date()) -> String {
        if let topic = topic?.trimmingCharacters(in: .whitespacesAndNewlines), topic.isEmpty == false {
            return topic
        }
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return String(format: String(localized: "share.live.default_title_format"), formatter.string(from: now))
    }

    /// 「正在给观众看字幕」或「正在给观众看字幕 · 3 人在看」。
    static func status(viewers: UInt32) -> String {
        viewers == 0
            ? String(localized: "share.live.on")
            : String(format: String(localized: "share.live.on_count_format"), Int64(viewers))
    }

    /// 「3 人在看」;一个人都没有时是「还没有人在看」。
    static func viewers(_ viewers: UInt32) -> String {
        viewers == 0
            ? String(localized: "share.live.viewers_none")
            : String(format: String(localized: "share.live.viewers_format"), Int64(viewers))
    }

    /// 录音条上那颗按钮写的字:没开始时是这件事的名字,开始以后只写人数。
    static func barLabel(live: Bool, viewers: UInt32) -> String {
        guard live else { return String(localized: "share.live.bar") }
        return String(format: String(localized: "share.live.viewers_format"), Int64(viewers))
    }

    /// 屏幕上不必把 43 个字符的密钥全摆出来 —— 复制与二维码里是完整的。
    static func displayed(_ url: String) -> String {
        let withoutScheme = url.replacingOccurrences(of: "https://", with: "")
        guard let hash = withoutScheme.firstIndex(of: "#") else { return withoutScheme }
        return String(withoutScheme[..<hash]) + "#…"
    }
}

/// 面板在弹出框里的样子。两个入口弹的是同一张:录音条上的按钮,和录音条
/// 「⋯」里的「给观众看字幕…」。
struct LiveSharePopover: View {
    let sessionId: String
    let title: String

    /// 比原来宽 24 pt:德语里「复制链接、放大、换链接」那一排在这个宽度下
    /// 刚好摆得下(渲染核对过),再窄就要横向滚。
    static let width: CGFloat = 384

    var body: some View {
        ScrollView {
            LiveSharePanel(sessionId: sessionId, title: title)
                .padding(Spacing.lg)
        }
        .frame(width: Self.width)
        .frame(maxHeight: 700)
    }
}

/// 面板此刻要摆什么,全是值。
struct LiveSharePanelState: Equatable {
    enum Phase: Equatable {
        /// 还没开始。
        case idle
        /// 这一场正在给观众看。
        case live(url: String, viewers: UInt32, locked: Bool)
        /// 同一时间只给一场;另一场还开着(比如录音刚换过)。
        case otherRecording
    }

    var phase: Phase
    /// 开始、锁定、换链接、停止这类要等网络的动作进行中。
    var busy = false
    /// 停了以后文字稿留不留在链接上。
    var keepsAfterEnd = false
    /// 同一网络的 ZuTalk 能不能直接看这一场;和链接各管各的。
    var nearbyOn = false
    var nearbyViewers: UInt32 = 0

    /// 这张面板上的三条告知,顺序固定:音频、加密、停了以后。
    var facts: [ShareFact] {
        [.noAudio, .encrypted, .afterStop(keeps: keepsAfterEnd)]
    }
}

struct LiveSharePanelActions {
    var start: () -> Void = {}
    var stop: () -> Void = {}
    var copy: () -> Void = {}
    var enlarge: () -> Void = {}
    /// 换一个链接。不可逆、对外,所以由调用方先问一句。
    var replace: () -> Void = {}
    var setLocked: (Bool) -> Void = { _ in }
    var setKeepsAfterEnd: (Bool) -> Void = { _ in }
    var setNearby: (Bool) -> Void = { _ in }
}

struct LiveSharePanel: View {
    let sessionId: String
    let title: String

    @ObservedObject private var share = ShareActivityStore.shared
    @ObservedObject private var nearby = NearbyStore.shared
    /// 开始之前的选择:默认散场即删(负责人定案「默认不留、可逐场允许」)。
    @State private var keepsAfterEnd = false

    var body: some View {
        LiveSharePanelContent(state: state, actions: actions)
    }

    private var ownLive: FfiLiveLink? {
        guard let live = share.live, live.sessionId == sessionId else { return nil }
        return live
    }

    private var state: LiveSharePanelState {
        let phase: LiveSharePanelState.Phase
        if let live = ownLive {
            phase = .live(url: live.url, viewers: live.viewers, locked: live.locked)
        } else if share.live != nil {
            phase = .otherRecording
        } else {
            phase = .idle
        }
        let nearbyOn = nearby.isLive(sessionId: sessionId)
        return LiveSharePanelState(
            phase: phase,
            busy: share.liveBusy,
            keepsAfterEnd: ownLive?.keepsAfterEnd ?? keepsAfterEnd,
            nearbyOn: nearbyOn,
            nearbyViewers: nearbyOn ? nearby.status?.liveViewers ?? 0 : 0
        )
    }

    private var actions: LiveSharePanelActions {
        LiveSharePanelActions(
            start: { share.startLive(sessionId: sessionId, title: title, keepsAfterEnd: keepsAfterEnd) },
            stop: { share.stopLive() },
            copy: { share.copyLiveLink() },
            enlarge: {
                guard let live = ownLive else { return }
                ShareQRPresenter.show(url: live.url, title: title)
            },
            replace: confirmReplace,
            setLocked: { share.setLocked($0) },
            setKeepsAfterEnd: { keeps in
                // 真正的去留在停止那一刻才定,所以开始以后也能来回改。
                if ownLive != nil {
                    share.setKeepsAfterEnd(keeps)
                } else {
                    keepsAfterEnd = keeps
                }
            },
            setNearby: { on in
                if on {
                    nearby.startLive(sessionId: sessionId, title: title)
                } else {
                    nearby.stopLive()
                }
            }
        )
    }

    private func confirmReplace() {
        let alert = NSAlert()
        alert.messageText = String(localized: "share.live.replace_confirm_title")
        alert.informativeText = String(localized: "share.live.replace_detail")
        alert.addButton(withTitle: String(localized: "share.live.replace_confirm_button"))
        alert.addButton(withTitle: String(localized: "common.cancel"))
        if alert.runModal() == .alertFirstButtonReturn {
            share.replaceLink()
        }
    }
}

/// 面板本身。一句状态,二维码和链接,几颗胶囊,一行告知;没有段落。
struct LiveSharePanelContent: View {
    let state: LiveSharePanelState
    let actions: LiveSharePanelActions

    /// 二维码的边长:会场里隔着一张桌子要扫得到。
    static let qrSide: CGFloat = 196

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            switch state.phase {
            case .idle:
                idle
            case .live(let url, let viewers, let locked):
                live(url: url, viewers: viewers, locked: locked)
            case .otherRecording:
                otherRecording
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 开始之前

    @ViewBuilder
    private var idle: some View {
        Text(String(localized: "share.live.title"))
            .font(.titleMD)
            .foregroundColor(.textPrimary)

        PillStrip { keepPill }

        ShareFactsRow(facts: state.facts)

        Button(action: actions.start) {
            HStack(spacing: Spacing.sm) {
                if state.busy {
                    ProgressView().controlSize(.small)
                }
                Text(String(localized: state.busy ? "share.live.starting" : "share.live.start_short"))
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(state.busy)
        // 原来印在标题下面的那一段:现场的人怎么看得到。
        .help(String(localized: "share.live.intro"))
        .accessibilityLabel(Text(String(localized: "share.live.start")))
        .accessibilityHint(Text(String(localized: "share.live.intro")))
        .accessibilityIdentifier("share.live.start")

        // 和链接各管各的:不开链接也能只给附近看,所以不排在「开始」前面。
        PillStrip { nearbyPill }
    }

    // MARK: 进行中

    @ViewBuilder
    private func live(url: String, viewers: UInt32, locked: Bool) -> some View {
        HStack(spacing: Spacing.sm) {
            PulsingDot(color: .signalGreen, size: 8)
                .accessibilityHidden(true)
            Text(String(localized: "share.live.on"))
                .font(.titleMD)
                .foregroundColor(.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: Spacing.sm)
            Label(LiveShareText.viewers(viewers), systemImage: locked ? "lock.fill" : "person.2.fill")
                .font(.bodySM)
                .foregroundColor(.textSecondary)
                .lineLimit(1)
                .fixedSize()
                .accessibilityIdentifier("share.live.viewers")
        }

        VStack(spacing: Spacing.sm) {
            if let qr = ShareQRCode.image(for: url) {
                Button(action: actions.enlarge) {
                    Image(nsImage: qr)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: Self.qrSide, height: Self.qrSide)
                        .padding(ShareQRCode.quietZone(for: Self.qrSide))
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
                }
                .buttonStyle(.plain)
                .help(String(localized: "share.link.show_large"))
                .accessibilityLabel(Text(String(localized: "share.link.qr_label")))
            }
            ShareLinkText(url: url)
        }
        .frame(maxWidth: .infinity)

        PillStrip {
            ActionPill(
                String(localized: "share.link.copy"),
                systemImage: "doc.on.doc",
                action: actions.copy
            )
            .accessibilityIdentifier("share.link.copy")
            // Only an icon: with a word on it the row no longer fits in German,
            // and the code above is itself the button that enlarges it.
            ActionPill(
                nil,
                systemImage: "arrow.up.left.and.arrow.down.right",
                help: String(localized: "share.link.show_large"),
                accessibilityLabel: String(localized: "share.link.show_large"),
                action: actions.enlarge
            )
            .accessibilityIdentifier("share.link.enlarge")
            ActionPill(
                String(localized: "share.live.replace_short"),
                systemImage: "arrow.triangle.2.circlepath",
                help: String(localized: "share.live.replace_detail"),
                accessibilityLabel: String(localized: "share.live.replace"),
                action: actions.replace
            )
            .disabled(state.busy)
            .accessibilityIdentifier("share.live.replace")
        }

        PillStrip {
            TogglePill(
                isOn: locked,
                on: .init(String(localized: "share.live.lock"), systemImage: "lock.fill"),
                off: .init(String(localized: "share.live.lock"), systemImage: "lock.open"),
                help: String(localized: locked ? "share.live.lock_on_detail" : "share.live.lock_off_detail")
            ) {
                actions.setLocked(!locked)
            }
            .disabled(state.busy)
            .accessibilityIdentifier("share.live.lock")
            keepPill
        }

        ShareFactsRow(facts: state.facts)

        PillStrip {
            nearbyPill
        } trailing: {
            stopPill(help: String(localized: state.keepsAfterEnd
                ? "share.live.stop_note_kept"
                : "share.live.stop_note"))
        }
    }

    // MARK: 别的状态

    /// 另一场还在给观众看:一句话,一个动作。
    @ViewBuilder
    private var otherRecording: some View {
        Label(String(localized: "share.live.other_title"), systemImage: "exclamationmark.triangle")
            .font(.bodyMedium)
            .foregroundColor(.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
        PillStrip {
            EmptyView()
        } trailing: {
            stopPill(help: String(localized: "share.live.other_body"))
        }
    }

    // MARK: 胶囊

    private var keepPill: some View {
        let name = String(localized: "share.live.keep_short")
        return TogglePill(
            isOn: state.keepsAfterEnd,
            on: .init(name, systemImage: "doc.text.fill"),
            off: .init(name, systemImage: "doc.text"),
            help: String(localized: state.keepsAfterEnd
                ? "share.live.keep_on_detail"
                : "share.live.keep_off_detail"),
            // The full name of the choice: kept after it ends.
            accessibilityLabel: String(localized: "share.live.keep")
        ) {
            actions.setKeepsAfterEnd(!state.keepsAfterEnd)
        }
        .accessibilityIdentifier("share.live.keep")
    }

    /// 同一网络的 ZuTalk 直接看,不经服务器。打开以后这台的名字和这一场的
    /// 标题会被同一网络里的 ZuTalk 看到 —— 这是告知,所以旁边留一个 ⓘ。
    private var nearbyPill: some View {
        let explanation = nearbyExplanation
        return HStack(spacing: 2) {
            TogglePill(
                isOn: state.nearbyOn,
                on: .init(nearbyTitle, systemImage: "wifi"),
                off: .init(String(localized: "nearby.settings.title"), systemImage: "wifi"),
                help: explanation,
                accessibilityLabel: String(localized: "nearby.live.choice")
            ) {
                actions.setNearby(!state.nearbyOn)
            }
            .accessibilityIdentifier("share.live.nearby")
            InfoButton(explanation, accessibilityLabel: String(localized: "nearby.live.choice"))
                .accessibilityIdentifier("share.live.nearby.info")
        }
    }

    /// 「附近」;有人在看时把台数写在胶囊上。
    private var nearbyTitle: String {
        guard state.nearbyViewers > 0 else { return String(localized: "nearby.settings.title") }
        return String(format: String(localized: "nearby.pill.count_format"), Int64(state.nearbyViewers))
    }

    private var nearbyExplanation: String {
        var lines = [String(localized: "nearby.live.choice")]
        if state.nearbyOn {
            lines.append(String(localized: "nearby.live.choice_on_detail"))
            if state.nearbyViewers > 0 {
                lines.append(String(
                    format: String(localized: "nearby.live.viewers_format"),
                    Int64(state.nearbyViewers)
                ))
            }
        }
        // 会被看到什么:开着关着都说。
        lines.append(String(localized: "nearby.live.choice_off_detail"))
        return lines.joined(separator: "\n")
    }

    /// 停的是给观众看字幕,不是录音:提示和读屏说全名,并说清楚停了以后
    /// 链接上的内容怎么样。
    private func stopPill(help: String) -> some View {
        ActionPill(
            String(localized: "share.live.stop_short"),
            systemImage: "stop.fill",
            iconTint: .signalRed,
            help: String(localized: "share.live.stop") + "\n" + help,
            accessibilityLabel: String(localized: "share.live.stop"),
            action: actions.stop
        )
        .disabled(state.busy)
        .accessibilityIdentifier("share.live.stop")
    }
}

// MARK: - 录好的录音

/// 分享一段录好的录音:从录音行菜单、录音页顶栏打开的那张表。
struct RecordingShareSheet: View {
    let request: RecordingShareRequest

    @Environment(\.presentationMode) private var presentationMode
    @ObservedObject private var share = ShareActivityStore.shared
    @ObservedObject private var nearby = NearbyStore.shared
    @StateObject private var copyTracker = ShareCopyTracker()
    @State private var links: [FfiRecordingLink] = []
    @State private var creating = false
    @State private var revoking: String?
    @State private var preparing: FfiTranscriptFileFormat?
    @State private var markdownAnchor = ViewAnchor()
    @State private var subtitlesAnchor = ViewAnchor()

    var body: some View {
        RecordingShareSheetContent(
            state: RecordingShareSheetState(
                title: request.title,
                preparing: preparing,
                copySent: copyTracker.sent,
                syncRunning: nearby.status?.running == true,
                receivers: nearby.receivers,
                sending: nearby.sending,
                links: links,
                creating: creating,
                revoking: revoking
            ),
            actions: RecordingShareSheetActions(
                send: send,
                turnOnSync: { Task { _ = await DeviceSyncStore.shared.ensureRunning() } },
                handOver: { nearby.send(sessionId: request.sessionId, title: request.title, to: $0) },
                createLink: createLink,
                copyLink: { share.copy($0.url, toast: "share.link.copied") },
                showCode: { ShareQRPresenter.show(url: $0.url, title: request.title) },
                revoke: confirmRevoke,
                done: { presentationMode.wrappedValue.dismiss() }
            ),
            markdownAnchor: markdownAnchor,
            subtitlesAnchor: subtitlesAnchor
        ) {
            // 登录了城才出现:交到档案馆,唯一公开、长期留存的出口。
            CityShareSection(request: request)
        }
        .onAppear {
            reload()
            nearby.refresh()
        }
    }

    // MARK: 发送副本

    private func send(_ format: FfiTranscriptFileFormat) {
        let anchor = format == .markdown ? markdownAnchor : subtitlesAnchor
        preparing = format
        Task {
            let url = await share.transcriptFile(sessionId: request.sessionId, title: request.title, format: format)
            preparing = nil
            guard let url, let view = anchor.view else { return }
            let picker = NSSharingServicePicker(items: [url])
            picker.delegate = copyTracker
            picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        }
    }

    // MARK: 只读链接

    private func createLink() {
        creating = true
        Task {
            _ = await share.createRecordingLink(sessionId: request.sessionId, title: request.title)
            creating = false
            reload()
        }
    }

    private func confirmRevoke(_ link: FfiRecordingLink) {
        let alert = NSAlert()
        alert.messageText = String(localized: "share.recording.revoke_confirm_title")
        alert.informativeText = String(localized: "share.recording.revoke_confirm_body")
        alert.addButton(withTitle: String(localized: "share.recording.revoke"))
        alert.addButton(withTitle: String(localized: "common.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        revoking = link.roomId
        Task {
            _ = await share.revoke(link)
            revoking = nil
            reload()
        }
    }

    private func reload() {
        links = share.recordingLinks(sessionId: request.sessionId)
    }
}

/// 那张表此刻要摆什么,全是值。
struct RecordingShareSheetState: Equatable {
    /// 行上显示的名字:标题,没有标题时是开头的话或时间。
    var title: String
    /// 正在准备哪一种文件;准备好就弹系统的分享菜单。
    var preparing: FfiTranscriptFileFormat?
    /// 这张表开着的时候,有一份副本发出去了。
    var copySent = false
    /// 附近走的是同步的端点:同步没开就看不见任何人。
    var syncRunning = true
    /// 附近打开了接收的 Mac。
    var receivers: [FfiNearbyPeer] = []
    /// 正在递给哪几台,等对方点接收。
    var sending: Set<String> = []
    /// 这段录音还有效的链接,新的在前。
    var links: [FfiRecordingLink] = []
    var creating = false
    var revoking: String?
    /// 「还剩几小时」按这一刻算。
    var now = Date()
}

struct RecordingShareSheetActions {
    var send: (FfiTranscriptFileFormat) -> Void = { _ in }
    var turnOnSync: () -> Void = {}
    var handOver: (FfiNearbyPeer) -> Void = { _ in }
    var createLink: () -> Void = {}
    var copyLink: (FfiRecordingLink) -> Void = { _ in }
    var showCode: (FfiRecordingLink) -> Void = { _ in }
    /// 撤销一条链接。不可逆,所以由调用方先问一句。
    var revoke: (FfiRecordingLink) -> Void = { _ in }
    var done: () -> Void = {}
}

/// 那张表本身。三种把文字给出去的办法各占一小块:名字、状态、动作。城的档案
/// 馆那一块由调用方给(`CityShareSection`),排在最前。
struct RecordingShareSheetContent<City: View>: View {
    let state: RecordingShareSheetState
    let actions: RecordingShareSheetActions
    let markdownAnchor: ViewAnchor
    let subtitlesAnchor: ViewAnchor
    let city: () -> City

    init(
        state: RecordingShareSheetState,
        actions: RecordingShareSheetActions,
        markdownAnchor: ViewAnchor = ViewAnchor(),
        subtitlesAnchor: ViewAnchor = ViewAnchor(),
        @ViewBuilder city: @escaping () -> City
    ) {
        self.state = state
        self.actions = actions
        self.markdownAnchor = markdownAnchor
        self.subtitlesAnchor = subtitlesAnchor
        self.city = city
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text(String(format: String(localized: "share.recording.title_format"), state.title))
                            .font(.titleMD)
                            .foregroundColor(.textPrimary)
                            .lineLimit(2)
                    }
                    city()
                    copyBlock
                    nearbyBlock
                    linkBlock
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Spacing.lg)
            }
            Divider()
            HStack {
                Spacer()
                Button(String(localized: "common.done"), action: actions.done)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(Spacing.md)
        }
        .frame(width: 460)
        .frame(minHeight: 420, maxHeight: 720)
    }

    // MARK: 发送副本

    private var copyBlock: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            ShareBlockHeader(String(localized: "share.copy.title")) {
                if state.preparing != nil {
                    ProgressView().controlSize(.small)
                } else if state.copySent {
                    ShareStatusWord(
                        String(localized: "share.copy.sent"),
                        systemImage: "checkmark.circle.fill",
                        iconTint: .success,
                        wordTint: .textPrimary
                    )
                    .accessibilityIdentifier("share.copy.sent")
                }
            }
            HStack(spacing: PillMetrics.spacing) {
                sendPill(.markdown, title: "share.copy.markdown", systemImage: "doc.text", anchor: markdownAnchor)
                    .accessibilityIdentifier("share.copy.markdown")
                sendPill(.subtitles, title: "share.copy.subtitles", systemImage: "captions.bubble", anchor: subtitlesAnchor)
                    .accessibilityIdentifier("share.copy.subtitles")
            }
        }
    }

    private func sendPill(
        _ format: FfiTranscriptFileFormat,
        title: String.LocalizationValue,
        systemImage: String,
        anchor: ViewAnchor
    ) -> some View {
        ActionPill(
            String(localized: title),
            systemImage: systemImage,
            // 原来印在标题下面的那一句:发出去的是一份独立的副本。
            help: String(localized: "share.copy.detail")
        ) {
            actions.send(format)
        }
        .disabled(state.preparing != nil)
        .background(AnchorReader(anchor: anchor))
    }

    // MARK: 递给附近的 Mac

    private var nearbyBlock: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            ShareBlockHeader(String(localized: "nearby.send.title")) { EmptyView() }
            if state.syncRunning == false {
                // 一句话,一个动作。
                HStack(spacing: Spacing.sm) {
                    Label(String(localized: "nearby.send.needs_sync"), systemImage: "wifi.slash")
                        .font(.bodySM)
                        .foregroundColor(.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: Spacing.sm)
                    ActionPill(
                        String(localized: "nearby.send.turn_on"),
                        systemImage: "arrow.triangle.2.circlepath",
                        action: actions.turnOnSync
                    )
                    .accessibilityIdentifier("share.recording.nearby.turn-on")
                }
            } else if state.receivers.isEmpty {
                // 空状态的那一句;对方该去哪里打开接收,在 ⓘ 里。
                HStack(spacing: 2) {
                    Label(String(localized: "nearby.send.empty"), systemImage: "wifi")
                        .font(.bodySM)
                        .foregroundColor(.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    InfoButton(
                        String(localized: "nearby.send.none") + "\n" + String(localized: "nearby.send.detail"),
                        accessibilityLabel: String(localized: "nearby.send.title")
                    )
                    Spacer(minLength: 0)
                }
            }
            ForEach(state.receivers, id: \.deviceId) { peer in
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "laptopcomputer")
                        .foregroundColor(.textTertiary)
                        .accessibilityHidden(true)
                    Text(peer.name.isEmpty ? String(localized: "settings.devices.unnamed") : peer.name)
                        .font(.body)
                        .foregroundColor(.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: Spacing.sm)
                    if state.sending.contains(peer.deviceId) {
                        ProgressView().controlSize(.small)
                        Text(String(localized: "nearby.send.waiting"))
                            .font(.bodySM)
                            .foregroundColor(.textSecondary)
                            .lineLimit(1)
                    } else {
                        ActionPill(
                            String(localized: "nearby.send.button"),
                            systemImage: "paperplane",
                            // 不经服务器;对方点了接收才收下。
                            help: String(localized: "nearby.send.detail")
                        ) {
                            actions.handOver(peer)
                        }
                    }
                }
                .frame(minHeight: PillMetrics.height)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("share.recording.nearby")
    }

    // MARK: 只读链接

    private var linkBlock: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            ShareBlockHeader(String(localized: "share.recording.link_title")) {
                if state.creating {
                    ProgressView().controlSize(.small)
                }
            }
            // 拿到链接的人都能读、能下载;加密、24 小时、随时能撤,全文在 ⓘ 里。
            // 「不含音频」说的是链接、副本和附近递稿。档案馆那一块可以带音频
            // (负责人 2026-11-14 定),所以这一条不再挂在整张表的标题下。
            ShareFactsRow(facts: [.noAudio, .linkEncrypted, .linkExpires])

            ForEach(state.links, id: \.roomId) { link in
                linkRow(link)
            }

            ActionPill(
                String(localized: state.links.isEmpty
                    ? "share.recording.create_link"
                    : "share.recording.create_another"),
                systemImage: "link.badge.plus",
                action: actions.createLink
            )
            .disabled(state.creating)
            .accessibilityIdentifier("share.recording.create_link")
        }
    }

    private func linkRow(_ link: FfiRecordingLink) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
                ShareLinkText(url: link.url)
                Spacer(minLength: Spacing.sm)
                ShareStatusWord(expiryText(link), systemImage: "clock")
            }
            HStack(spacing: PillMetrics.spacing) {
                ActionPill(String(localized: "share.link.copy"), systemImage: "doc.on.doc") {
                    actions.copyLink(link)
                }
                .accessibilityIdentifier("share.link.copy")
                ActionPill(
                    String(localized: "share.qr.show"),
                    systemImage: "qrcode",
                    help: String(localized: "share.link.show_large")
                ) {
                    actions.showCode(link)
                }
                .accessibilityIdentifier("share.link.qr")
                Spacer(minLength: Spacing.sm)
                if state.revoking == link.roomId {
                    ProgressView().controlSize(.small)
                        .frame(height: PillMetrics.height)
                } else {
                    ActionPill(
                        String(localized: "share.recording.revoke"),
                        systemImage: "xmark.circle",
                        iconTint: .signalRed,
                        help: String(localized: "share.recording.revoke_confirm_body")
                    ) {
                        actions.revoke(link)
                    }
                    .disabled(state.revoking != nil)
                    .accessibilityIdentifier("share.recording.revoke")
                }
            }
        }
        .padding(Spacing.xsm)
        .surfaceCard(fill: Color.bgSunken, cornerRadius: Radius.md)
    }

    private func expiryText(_ link: FfiRecordingLink) -> String {
        let remaining = max(0, link.expiresAtEpoch - Int64(state.now.timeIntervalSince1970))
        let hours = remaining / 3_600
        if hours >= 1 {
            return String(format: String(localized: "share.recording.expires_hours_format"), hours)
        }
        return String(format: String(localized: "share.recording.expires_minutes_format"), max(1, remaining / 60))
    }
}

/// 「发送副本」发没发出去:系统的分享菜单选了一种办法并且发完,这里才知道。
/// 只管这张表开着的这一会儿,不落库。
final class ShareCopyTracker: NSObject, ObservableObject, NSSharingServicePickerDelegate, NSSharingServiceDelegate {
    @Published private(set) var sent = false

    func sharingServicePicker(
        _ sharingServicePicker: NSSharingServicePicker,
        delegateFor sharingService: NSSharingService
    ) -> NSSharingServiceDelegate? {
        self
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        sent = true
    }
}

// MARK: - 零件

/// 一条告知:一个图标,两三个字。整句是它的悬停提示,也进那一行末尾的 ⓘ。
///
/// 两个键而不是两段字:哪条事实配哪句原话,测试不用管机器说哪种语言就能查。
struct ShareFact: Equatable, Identifiable {
    let systemImage: String
    /// 面板上那两三个字。
    let labelKey: String
    /// 原来整段印在面板上的那一句。
    let detailKey: String

    var id: String { labelKey }
    var label: String { String(localized: String.LocalizationValue(labelKey)) }
    var detail: String { String(localized: String.LocalizationValue(detailKey)) }

    /// 音频从不离开这台 Mac。
    static let noAudio = ShareFact(
        systemImage: "waveform.slash",
        labelKey: "share.fact.no_audio",
        detailKey: "share.audio_never"
    )
    /// 服务器只转发看不懂的内容;拿到链接的人都能看。
    static let encrypted = ShareFact(
        systemImage: "lock.fill",
        labelKey: "share.fact.encrypted",
        detailKey: "share.encrypted"
    )
    /// 录音链接的那一句把加密、失效、撤销一起说了。
    static let linkEncrypted = ShareFact(
        systemImage: "lock.fill",
        labelKey: "share.fact.encrypted",
        detailKey: "share.recording.link_detail"
    )
    static let linkExpires = ShareFact(
        systemImage: "clock",
        labelKey: "share.fact.expires_24h",
        detailKey: "share.recording.link_detail"
    )

    /// 停了以后链接上的内容怎么样:不留就当场删,留就约 24 小时后删。
    static func afterStop(keeps: Bool) -> ShareFact {
        keeps
            ? ShareFact(
                systemImage: "clock",
                labelKey: "share.fact.kept_24h",
                detailKey: "share.live.stop_note_kept"
            )
            : ShareFact(
                systemImage: "trash",
                labelKey: "share.fact.deleted_on_stop",
                detailKey: "share.live.stop_note"
            )
    }

    /// ⓘ 里的全文:每条事实的原话各一行,同一句不说两遍。
    static func fullText(_ facts: [ShareFact]) -> String {
        var seen = Set<String>()
        return facts
            .filter { seen.insert($0.detailKey).inserted }
            .map(\.detail)
            .joined(separator: "\n")
    }
}

/// 一行告知。摆得下就排成一行,摆不下(德语、法语)就一条一行;末尾一个 ⓘ,
/// 点开是这几条的原话。
struct ShareFactsRow: View {
    let facts: [ShareFact]

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.xs) {
            MontereyHorizontalViewThatFits {
                HStack(spacing: Spacing.xsm) { labels }
            } fallback: {
                VStack(alignment: .leading, spacing: Spacing.xs) { labels }
            }
            Spacer(minLength: 0)
            InfoButton(ShareFact.fullText(facts))
        }
        .accessibilityElement(children: .contain)
    }

    private var labels: some View {
        ForEach(facts) { fact in
            ShareStatusWord(fact.label, systemImage: fact.systemImage)
                .help(fact.detail)
                .accessibilityHint(Text(fact.detail))
        }
    }
}

/// 状态:一个图标加一个词。
struct ShareStatusWord: View {
    private let word: String
    private let systemImage: String
    private let iconTint: Color
    private let wordTint: Color

    init(
        _ word: String,
        systemImage: String,
        iconTint: Color = .textTertiary,
        wordTint: Color = .textSecondary
    ) {
        self.word = word
        self.systemImage = systemImage
        self.iconTint = iconTint
        self.wordTint = wordTint
    }

    var body: some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: systemImage)
                .font(PillMetrics.markFont)
                .foregroundColor(iconTint)
                .accessibilityHidden(true)
            Text(word)
                .font(.bodySM)
                .foregroundColor(wordTint)
                .lineLimit(1)
                .fixedSize()
        }
        .accessibilityElement(children: .combine)
    }
}

/// 一小块的名字,右边是它此刻的状态。
struct ShareBlockHeader<Status: View>: View {
    private let title: String
    private let status: Status

    init(_ title: String, @ViewBuilder status: () -> Status) {
        self.title = title
        self.status = status()
    }

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Text(title)
                .font(.bodyMedium)
                .foregroundColor(.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: Spacing.sm)
            status
        }
        .frame(minHeight: 20)
    }
}

/// 链接本身。要**显示出来**,不能只给一个复制按钮:复制失效时还有第二条路,
/// 看得见也才核对得了粘贴得对不对。
struct ShareLinkText: View {
    let url: String

    var body: some View {
        Text(LiveShareText.displayed(url))
            .font(.mono11)
            .foregroundColor(.textSecondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .help(url)
    }
}

enum ShareQRCode {
    /// 码四周的白边。深色界面里白边太窄,手机相机找不到定位角 —— 规范要四个
    /// 模块宽;按边长的十分之一给,够一般长度的链接用。
    static func quietZone(for side: CGFloat) -> CGFloat {
        max(8, (side / 10).rounded())
    }

    /// 链接的二维码。CoreImage 内置生成器,零新依赖。
    static func image(for text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        // 原始点阵很小,先放大再关插值,方块才是方的。
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let representation = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}

/// 放大的二维码,由窗口系统开一扇独立的窗:可以拖到投影屏上。
@MainActor
enum ShareQRPresenter {
    static func show(url: String, title: String) {
        WindowCoordinator.shared.presentShareCode(url: url, title: title)
    }
}

struct LargeShareQRView: View {
    let url: String
    let title: String

    var body: some View {
        GeometryReader { geometry in
            let side = max(160, min(geometry.size.width, geometry.size.height - 140) - Spacing.xl * 2)
            VStack(spacing: Spacing.lg) {
                if let qr = ShareQRCode.image(for: url) {
                    Image(nsImage: qr)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: side, height: side)
                        .padding(ShareQRCode.quietZone(for: side))
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.md))
                }
                VStack(spacing: Spacing.xs) {
                    Text(title)
                        .font(.titleMD)
                        .foregroundColor(.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    Text(String(localized: "share.link.scan_hint"))
                        .font(.body)
                        .foregroundColor(.textSecondary)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .background(Color.bgRoot)
    }
}

/// SwiftUI 按钮背后的 NSView,给系统分享菜单当锚点。
final class ViewAnchor {
    weak var view: NSView?
}

struct AnchorReader: NSViewRepresentable {
    let anchor: ViewAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }
}
