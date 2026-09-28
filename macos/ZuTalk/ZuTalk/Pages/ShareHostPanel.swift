// ShareHostPanel.swift
// 主持人的共享面板:直播正在录的这一场,或共享一段录好的录音。
//
// 共享以前是侧边栏里的一个独立页面:先选主题、再选范围、再选录音,
// 开始之后那一页也说不出正在共享的是什么。现在它长在被共享的东西上 ——
// 直播从录音条打开,共享录音从录音行的菜单或录音页顶栏打开 —— 面板里
// 只回答三件事:谁能看、谁在看、他们能留下什么。
//
// 几句必须说对的话(share-p2p.md):
//   - 音频从不离开这台 Mac;
//   - 停止只停后续,已经给出的收不回;
//   - 拿到加入码的人都能进来 —— 码本身就是钥匙;
//   - 网页链接的字幕明文经过服务器,并在链接上保留约 24 小时。

import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

/// 面板在为哪一场说话。
enum ShareSubject: Equatable {
    /// 正在录的这一场。
    case live(sessionId: String)
    /// 一段录好的录音。
    case recording(sessionId: String, title: String)

    var sessionId: String {
        switch self {
        case .live(let sessionId), .recording(let sessionId, _):
            return sessionId
        }
    }

    var isLive: Bool {
        if case .live = self { return true }
        return false
    }
}

struct HostSharePanel: View {
    let subject: ShareSubject

    @ObservedObject private var share = ShareActivityStore.shared
    /// 开始之前的选择。直播默认不让对方留;共享录音默认只读。
    @State private var keepCopies = false
    @State private var readOnly = true
    @State private var editingName = false
    @State private var nameDraft = ""

    private var isThisShare: Bool {
        share.isHosting && share.scopeSessionId == subject.sessionId
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            if isThisShare {
                activeSections
            } else if share.isHosting {
                otherShareInProgress
            } else if share.isViewing {
                watchingSomeoneElse
            } else {
                startForm
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 开始之前

    private var startForm: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text(String(localized: subject.isLive ? "share.live.title" : "share.recording.title"))
                .font(.titleMD)
                .foregroundColor(.textPrimary)
            Text(String(localized: subject.isLive ? "share.live.intro" : "share.recording.intro"))
                .font(.bodySM)
                .foregroundColor(.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if subject.isLive {
                choice(
                    isOn: $keepCopies,
                    title: String(localized: "share.keep.toggle"),
                    detail: String(localized: keepCopies ? "share.keep.on_detail" : "share.keep.off_detail")
                )
                .accessibilityIdentifier("share.keep")
            } else {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Picker("", selection: $readOnly) {
                        Text(String(localized: "share.recording.read_only")).tag(true)
                        Text(String(localized: "share.recording.can_correct")).tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityIdentifier("share.recording.role")
                    Text(String(localized: readOnly
                        ? "share.recording.read_only_detail"
                        : "share.recording.can_correct_detail"))
                        .font(.bodySM)
                        .foregroundColor(.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Label(String(localized: "share.audio_never"), systemImage: "waveform.slash")
                .font(.bodySM)
                .foregroundColor(.textSecondary)

            Button {
                switch subject {
                case .live(let sessionId):
                    share.startLiveShare(sessionId: sessionId, keepCopies: keepCopies)
                case .recording(let sessionId, _):
                    share.startRecordingShare(sessionId: sessionId, readOnly: readOnly)
                }
            } label: {
                Label(
                    String(localized: subject.isLive ? "share.live.start" : "share.recording.start"),
                    systemImage: "dot.radiowaves.left.and.right"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(share.isBusy)
            .accessibilityIdentifier("share.start")
        }
    }

    // MARK: 进行中

    @ViewBuilder
    private var activeSections: some View {
        statusHeader
        codeSection
        if share.pendingJoinRequests.isEmpty == false {
            JoinRequestList()
        }
        watchersSection
        optionsSection
        webSection
        stopSection
        nameRow
    }

    private var statusHeader: some View {
        HStack(spacing: Spacing.sm) {
            PulsingDot(color: .signalGreen, size: 8)
                .accessibilityHidden(true)
            Text(String(localized: share.isLive ? "share.live.on" : "share.recording.on"))
                .font(.titleMD)
                .foregroundColor(.textPrimary)
            Spacer()
            Text(watcherCountText)
                .font(.bodySM)
                .foregroundColor(.textSecondary)
        }
    }

    private var watcherCountText: String {
        share.watchers.isEmpty
            ? String(localized: "share.watchers.none")
            : String(format: String(localized: "share.watchers.count_format"), Int64(share.watchers.count))
    }

    private var codeSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            sectionTitle("share.code.title")
            // 码要**显示出来**,不能只给一个复制按钮:复制失效时还有第二条路,
            // 看得见也才能核对粘贴得对不对。
            Text(share.shareCode ?? "…")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.textSecondary)
                .textSelection(.enabled)
                .lineLimit(4)
                .padding(Spacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.bgSunken)
                .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
                .accessibilityIdentifier("share.code_text")
            HStack {
                Button {
                    share.copyShareCode()
                } label: {
                    Label(String(localized: "share.code.copy"), systemImage: "doc.on.doc")
                }
                .disabled(share.shareCode == nil)
                .accessibilityIdentifier("share.copy_code")
                Spacer()
            }
            Text(String(localized: "share.code.note"))
                .font(.bodySM)
                .foregroundColor(.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var watchersSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            sectionTitle("share.watchers.title")
            if share.watchers.isEmpty {
                Text(String(localized: share.isLive ? "share.watchers.empty_live" : "share.watchers.empty"))
                    .font(.bodySM)
                    .foregroundColor(.textTertiary)
            } else {
                ForEach(share.watchers, id: \.endpointId) { member in
                    HStack(spacing: Spacing.sm) {
                        Image(systemName: "person.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.textTertiary)
                        Text(member.displayName.isEmpty
                            ? String(localized: "share.unnamed")
                            : member.displayName)
                            .font(.body)
                            .foregroundColor(.textPrimary)
                            .lineLimit(1)
                        // 名字是对方自己填的,可能重名 —— 公钥短形式才是可核对的身份。
                        Text(member.shortLabel)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.textTertiary)
                        if let link = member.link {
                            ShareLinkBadge(link: link)
                        }
                        Spacer()
                        Button(String(localized: "share.watchers.remove")) {
                            share.removeWatcher(member)
                        }
                        .help(String(localized: "share.watchers.remove_hint"))
                    }
                }
            }
        }
        .accessibilityIdentifier("share.watchers")
    }

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            choice(
                isOn: Binding(
                    get: { share.discoverable },
                    set: { share.setDiscoverable($0) }
                ),
                title: String(localized: "share.nearby.toggle"),
                detail: String(
                    format: String(localized: "share.nearby.toggle_detail_format"),
                    share.displayName.isEmpty ? String(localized: "share.unnamed") : share.displayName,
                    subjectTitle
                )
            )
            .accessibilityIdentifier("share.discoverable")

            if share.isLive {
                // 只能打开:已经同步过去的内容在对方手里,关掉只会让界面说假话。
                choice(
                    isOn: Binding(
                        get: { share.keepsCopies },
                        set: { if $0 { confirmAllowKeeping() } }
                    ),
                    title: String(localized: "share.keep.toggle"),
                    detail: String(localized: share.keepsCopies
                        ? "share.keep.on_locked_detail"
                        : "share.keep.off_detail")
                )
                .disabled(share.keepsCopies)
                .accessibilityIdentifier("share.keep")
            } else {
                Label(
                    String(localized: share.hostOnly
                        ? "share.recording.read_only_detail"
                        : "share.recording.can_correct_detail"),
                    systemImage: share.hostOnly ? "lock" : "pencil"
                )
                .font(.bodySM)
                .foregroundColor(.textSecondary)
            }
        }
    }

    /// 直播中途打开是收不回的:已经在看的人马上就会拿到整份转录稿。
    private func confirmAllowKeeping() {
        let alert = NSAlert()
        alert.messageText = String(localized: "share.keep.confirm_title")
        alert.informativeText = String(localized: "share.keep.on_detail")
        alert.addButton(withTitle: String(localized: "share.keep.confirm_button"))
        alert.addButton(withTitle: String(localized: "common.cancel"))
        if alert.runModal() == .alertFirstButtonReturn {
            share.allowKeepingCopies()
        }
    }

    /// 对外说的标题 —— 核心随帧与附近宣告带出去的那一个,不是面板自己
    /// 起的名字。两者不一致,说明文字就在说假话。
    private var subjectTitle: String {
        share.title.isEmpty ? String(localized: "share.untitled") : share.title
    }

    @ViewBuilder
    private var webSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionTitle("share.web.title")
            if let web = share.webShare {
                HStack(alignment: .top, spacing: Spacing.md) {
                    if let qr = ShareQRCode.image(for: web.viewerUrl) {
                        Image(nsImage: qr)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 112, height: 112)
                            .padding(4)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
                            .accessibilityLabel(Text(String(localized: "share.web.qr_label")))
                    }
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text(web.viewerUrl)
                            .font(.bodySM)
                            .foregroundColor(.textSecondary)
                            .textSelection(.enabled)
                            .lineLimit(3)
                        HStack {
                            Button(String(localized: "share.web.copy")) { share.copyWebLink() }
                            Button(String(localized: "share.web.stop")) { share.stopWebShare() }
                        }
                    }
                }
                // 常驻:这条通道的隐私性质与点对点不同,说一次不够。
                Text(webUploadStatement)
                    .font(.bodySM)
                    .foregroundColor(.signalAmber)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Button {
                    confirmWebShare()
                } label: {
                    Label(
                        String(localized: share.webShareStarting ? "share.web.starting" : "share.web.start"),
                        systemImage: "qrcode"
                    )
                }
                .disabled(share.webShareStarting)
                .accessibilityIdentifier("share.web.start")
                Text(String(localized: "share.web.hint"))
                    .font(.bodySM)
                    .foregroundColor(.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityIdentifier("share.web")
    }

    /// 网页会上传什么、在哪、留多久 —— 点下去之前说清楚,开着时一直说。
    private var webUploadStatement: String {
        String(localized: share.keepsCopies ? "share.web.uploads_transcript" : "share.web.uploads_captions")
    }

    private func confirmWebShare() {
        let alert = NSAlert()
        alert.messageText = String(localized: "share.web.confirm.title")
        alert.informativeText = webUploadStatement
        alert.addButton(withTitle: String(localized: "share.web.confirm.button"))
        alert.addButton(withTitle: String(localized: "common.cancel"))
        if alert.runModal() == .alertFirstButtonReturn {
            share.startWebShare()
        }
    }

    private var stopSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Button(role: .destructive) {
                share.stopSharing()
            } label: {
                Label(
                    String(localized: share.isLive ? "share.live.stop" : "share.recording.stop"),
                    systemImage: "stop.circle"
                )
            }
            .accessibilityIdentifier("share.stop")
            // 停止的真实语义。不写这句,用户会以为点了停止对方就看不到了。
            Text(String(localized: share.keepsCopies ? "share.stop.note_kept" : "share.stop.note"))
                .font(.bodySM)
                .foregroundColor(.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 别人看到你叫什么。敲门与「谁在看」里,对方靠它认出你。
    private var nameRow: some View {
        HStack(spacing: Spacing.sm) {
            if editingName {
                TextField(String(localized: "share.name.placeholder"), text: $nameDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(saveName)
                Button(String(localized: "common.save"), action: saveName)
            } else {
                Text(String(
                    format: String(localized: "share.name.shown_as_format"),
                    share.displayName.isEmpty ? String(localized: "share.unnamed") : share.displayName
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

    // MARK: 别的状态

    private var otherShareInProgress: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text(String(localized: "share.busy.title"))
                .font(.titleMD)
                .foregroundColor(.textPrimary)
            Text(String(
                format: String(localized: "share.busy.body_format"),
                share.title.isEmpty ? String(localized: "share.untitled") : share.title
            ))
            .font(.bodySM)
            .foregroundColor(.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            Button(role: .destructive) {
                share.stopSharing()
            } label: {
                Text(String(localized: "share.busy.stop_other"))
            }
        }
    }

    private var watchingSomeoneElse: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text(String(
                format: String(localized: "share.viewing_blocks_hosting_format"),
                share.hostDisplayName
            ))
            .font(.bodySM)
            .foregroundColor(.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            Button(String(localized: "share.watch.leave")) { share.leave() }
        }
    }

    // MARK: 零件

    private func sectionTitle(_ key: String.LocalizationValue) -> some View {
        Text(String(localized: key))
            .font(.bodyMedium)
            .foregroundColor(.textPrimary)
    }

    private func choice(isOn: Binding<Bool>, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Spacing.md) {
                Text(title)
                    .font(.body)
                    .foregroundColor(.textPrimary)
                Spacer(minLength: Spacing.sm)
                Toggle(title, isOn: isOn)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            Text(detail)
                .font(.bodySM)
                .foregroundColor(.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 有人在等回答。敲门一分钟就超时,所以它出现在主持人此刻所在的每个面上。
struct JoinRequestList: View {
    @ObservedObject private var share = ShareActivityStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            ForEach(share.pendingJoinRequests, id: \.requestId) { request in
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "hand.raised.fill")
                        .foregroundColor(.signalAmber)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(String(
                            format: String(localized: "share.knock.title_format"),
                            request.displayName.isEmpty
                                ? String(localized: "share.unnamed")
                                : request.displayName
                        ))
                        .font(.bodyMedium)
                        .foregroundColor(.textPrimary)
                        Text(request.shortLabel)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.textTertiary)
                    }
                    Spacer()
                    Button(String(localized: "share.knock.decline")) { share.decline(request) }
                    Button(String(localized: "share.knock.approve")) { share.approve(request) }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(Spacing.sm)
        .background(Color.signalAmber.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
        .accessibilityIdentifier("share.requests")
    }
}

/// 录音条上的「直播」:没在直播时是入口,直播中是状态与人数。
struct LiveShareButton: View {
    let sessionId: String
    var compact = false

    @ObservedObject private var share = ShareActivityStore.shared
    @State private var showsPanel = false

    var body: some View {
        let live = share.isBroadcasting(sessionId: sessionId)
        Button {
            showsPanel.toggle()
        } label: {
            Group {
                if compact {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .frame(width: 30, height: 30)
                } else {
                    Label(title(live: live), systemImage: "dot.radiowaves.left.and.right")
                        .padding(.horizontal, Spacing.sm + 2)
                        .frame(minHeight: 30)
                }
            }
            .font(.bodyMedium)
            .foregroundColor(live ? .signalGreen : .textPrimary)
            .background((live ? Color.signalGreen : Color.textPrimary).opacity(0.1))
            .overlay(alignment: .topTrailing) {
                if live, share.pendingJoinRequests.isEmpty == false {
                    Circle()
                        .fill(Color.signalAmber)
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                }
            }
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(String(localized: live ? "share.live.bar_on_hint" : "share.live.bar_hint"))
        .accessibilityLabel(Text(title(live: live)))
        .accessibilityIdentifier("recording-bar.share")
        .popover(isPresented: $showsPanel, arrowEdge: .bottom) {
            ScrollView {
                HostSharePanel(subject: .live(sessionId: sessionId))
                    .padding(Spacing.lg)
            }
            .frame(width: 380)
            .frame(maxHeight: 620)
        }
    }

    private func title(live: Bool) -> String {
        guard live else { return String(localized: "share.live.bar") }
        return share.watchers.isEmpty
            ? String(localized: "share.live.on")
            : String(format: String(localized: "share.live.on_count_format"), Int64(share.watchers.count))
    }
}

/// 共享一段录好的录音:从录音行菜单、录音页顶栏打开的那张表。
struct RecordingShareSheet: View {
    let request: RecordingShareRequest

    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                HostSharePanel(subject: .recording(sessionId: request.sessionId, title: request.title))
                    .padding(Spacing.lg)
            }
            Divider()
            HStack {
                Spacer()
                Button(String(localized: "common.done")) {
                    presentationMode.wrappedValue.dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(Spacing.md)
        }
        .frame(width: 440)
        .frame(minHeight: 360, maxHeight: 680)
    }
}

/// 链路:直连还是经中继。「大家都经中继」多半是这个 Wi-Fi 隔离了设备。
struct ShareLinkBadge: View {
    let link: FfiShareLinkPath

    var body: some View {
        Label(
            String(localized: link == .direct ? "share.link.direct" : "share.link.relayed"),
            systemImage: link == .direct ? "bolt.fill" : "antenna.radiowaves.left.and.right"
        )
        .font(.captionMedium)
        .foregroundColor(link == .direct ? .signalGreen : .signalAmber)
        .help(String(localized: link == .direct ? "share.link.direct_hint" : "share.link.relayed_hint"))
    }
}

enum ShareQRCode {
    /// 网页链接的二维码。CoreImage 内置生成器,零新依赖。
    static func image(for text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        // 原始点阵很小,先放大再关插值,方块才是方的。
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let representation = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}
