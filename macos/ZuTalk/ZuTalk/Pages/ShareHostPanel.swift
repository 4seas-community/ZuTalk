// ShareHostPanel.swift
// 共享的两张面板:直播正在录的这一场(录音条上弹出),以及共享一段录好的
// 录音(录音行菜单、录音页顶栏打开)。
//
// 共享以前要对方也装 ZuTalk、粘贴一百多个字符的加入码、在同一个网络里互相
// 找到 —— 会场里拿手机的人一个都进不来。现在对方只需要一个浏览器:
//   - 直播:扫码或打开链接,就能看实时字幕和翻译;
//   - 录好的录音:发一份转录稿文件,或开一条 24 小时的只读链接。
//
// 几句必须说对的话(share-links.md):
//   - 音频从不离开这台 Mac;
//   - 链接端到端加密,服务器只转发看不懂的内容 —— 但拿到链接的人都能看;
//   - 直播停了,不留稿就当场删掉;留稿则约 24 小时后删;
//   - 录音链接 24 小时后失效,随时可以撤销。

import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

// MARK: - 直播

/// 录音条上的「直播」:没在直播时是入口,直播中是状态与人数。
struct LiveShareButton: View {
    let sessionId: String
    /// 观看页上显示的标题。
    let title: String
    var compact = false

    @ObservedObject private var share = ShareActivityStore.shared
    @ObservedObject private var nearby = NearbyStore.shared
    @State private var showsPanel = false

    var body: some View {
        let live = share.isBroadcasting(sessionId: sessionId) || nearby.isLive(sessionId: sessionId)
        Button {
            showsPanel.toggle()
        } label: {
            Group {
                if compact {
                    Image(systemName: "qrcode")
                        .frame(width: 30, height: 30)
                } else {
                    Label(label(live: live), systemImage: live ? "dot.radiowaves.left.and.right" : "qrcode")
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
        .accessibilityLabel(Text(label(live: live)))
        .accessibilityIdentifier("recording-bar.share")
        .popover(isPresented: $showsPanel, arrowEdge: .bottom) {
            ScrollView {
                LiveSharePanel(sessionId: sessionId, title: title)
                    .padding(Spacing.lg)
            }
            .frame(width: 360)
            .frame(maxHeight: 700)
        }
    }

    private func label(live: Bool) -> String {
        guard live else { return String(localized: "share.live.bar") }
        let viewers = (share.isBroadcasting(sessionId: sessionId) ? share.live?.viewers ?? 0 : 0)
            + (nearby.isLive(sessionId: sessionId) ? nearby.status?.liveViewers ?? 0 : 0)
        return LiveShareText.status(viewers: viewers)
    }
}

enum LiveShareText {
    /// 观看页顶上的标题:主题名,不在主题里的录音就是「实时字幕 · 9月28日」。
    static func title(topic: String?, now: Date = Date()) -> String {
        if let topic = topic?.trimmingCharacters(in: .whitespacesAndNewlines), topic.isEmpty == false {
            return topic
        }
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return String(format: String(localized: "share.live.default_title_format"), formatter.string(from: now))
    }

    /// 「直播中」或「直播中 · 3 人在看」。
    static func status(viewers: UInt32) -> String {
        viewers == 0
            ? String(localized: "share.live.on")
            : String(format: String(localized: "share.live.on_count_format"), Int64(viewers))
    }
}

struct LiveSharePanel: View {
    let sessionId: String
    let title: String

    @ObservedObject private var share = ShareActivityStore.shared
    /// 开始之前的选择:默认散场即删(负责人定案「默认不留、可逐场允许」)。
    @State private var keepsAfterEnd = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            if let live = share.live, live.sessionId == sessionId {
                active(live)
            } else if share.live != nil {
                otherLiveInProgress
            } else {
                startForm
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 开始之前

    private var startForm: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text(String(localized: "share.live.title"))
                .font(.titleMD)
                .foregroundColor(.textPrimary)
            Text(String(localized: "share.live.intro"))
                .font(.bodySM)
                .foregroundColor(.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            ShareChoice(
                isOn: $keepsAfterEnd,
                title: String(localized: "share.live.keep"),
                detail: String(localized: keepsAfterEnd ? "share.live.keep_on_detail" : "share.live.keep_off_detail")
            )
            .accessibilityIdentifier("share.live.keep")

            ShareAssurances()

            Button {
                share.startLive(sessionId: sessionId, title: title, keepsAfterEnd: keepsAfterEnd)
            } label: {
                HStack(spacing: Spacing.sm) {
                    if share.liveBusy {
                        ProgressView().controlSize(.small)
                    }
                    Text(String(localized: share.liveBusy ? "share.live.starting" : "share.live.start"))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(share.liveBusy)
            .accessibilityIdentifier("share.live.start")

            // 和链接各管各的:不开链接也能只给附近看。
            Divider()
            NearbyLiveChoice(sessionId: sessionId, title: title)
        }
    }

    // MARK: 进行中

    private func active(_ live: FfiLiveLink) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(spacing: Spacing.sm) {
                PulsingDot(color: .signalGreen, size: 8)
                    .accessibilityHidden(true)
                Text(String(localized: "share.live.on"))
                    .font(.titleMD)
                    .foregroundColor(.textPrimary)
                Spacer()
                Label(viewerText(live), systemImage: live.locked ? "lock.fill" : "person.2.fill")
                    .font(.bodySM)
                    .foregroundColor(.textSecondary)
                    .accessibilityIdentifier("share.live.viewers")
            }

            ShareLinkCard(url: live.url, title: title, qrSide: 196)

            VStack(alignment: .leading, spacing: Spacing.md) {
                ShareChoice(
                    isOn: Binding(get: { live.locked }, set: { share.setLocked($0) }),
                    title: String(localized: "share.live.lock"),
                    detail: String(localized: live.locked ? "share.live.lock_on_detail" : "share.live.lock_off_detail")
                )
                .disabled(share.liveBusy)
                .accessibilityIdentifier("share.live.lock")

                ShareChoice(
                    isOn: Binding(get: { live.keepsAfterEnd }, set: { share.setKeepsAfterEnd($0) }),
                    title: String(localized: "share.live.keep"),
                    detail: String(localized: live.keepsAfterEnd ? "share.live.keep_on_detail" : "share.live.keep_off_detail")
                )
                .accessibilityIdentifier("share.live.keep")

                VStack(alignment: .leading, spacing: 2) {
                    Button(String(localized: "share.live.replace")) {
                        confirmReplace()
                    }
                    .disabled(share.liveBusy)
                    .accessibilityIdentifier("share.live.replace")
                    Text(String(localized: "share.live.replace_detail"))
                        .font(.bodySM)
                        .foregroundColor(.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            NearbyLiveChoice(sessionId: sessionId, title: title)

            Divider()

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Button(role: .destructive) {
                    share.stopLive()
                } label: {
                    Label(String(localized: "share.live.stop"), systemImage: "stop.circle")
                }
                .disabled(share.liveBusy)
                .accessibilityIdentifier("share.live.stop")
                // 停止的真实语义。不写这句,主持人会以为停了之后还能读。
                Text(String(localized: live.keepsAfterEnd ? "share.live.stop_note_kept" : "share.live.stop_note"))
                    .font(.bodySM)
                    .foregroundColor(.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func viewerText(_ live: FfiLiveLink) -> String {
        live.viewers == 0
            ? String(localized: "share.live.viewers_none")
            : String(format: String(localized: "share.live.viewers_format"), Int64(live.viewers))
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

    // MARK: 别的状态

    /// 同一时间只直播一场。另一场还开着(比如录音刚换过)时说清楚。
    private var otherLiveInProgress: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text(String(localized: "share.live.other_title"))
                .font(.titleMD)
                .foregroundColor(.textPrimary)
            Text(String(localized: "share.live.other_body"))
                .font(.bodySM)
                .foregroundColor(.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(role: .destructive) {
                share.stopLive()
            } label: {
                Text(String(localized: "share.live.stop"))
            }
            .disabled(share.liveBusy)
        }
    }
}

// MARK: - 录好的录音

/// 共享一段录好的录音:从录音行菜单、录音页顶栏打开的那张表。
struct RecordingShareSheet: View {
    let request: RecordingShareRequest

    @Environment(\.presentationMode) private var presentationMode
    @ObservedObject private var share = ShareActivityStore.shared
    @State private var links: [FfiRecordingLink] = []
    @State private var creating = false
    @State private var revoking: String?
    @State private var preparing: FfiTranscriptFileFormat?
    @State private var markdownAnchor = ViewAnchor()
    @State private var subtitlesAnchor = ViewAnchor()

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.xl) {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text(String(format: String(localized: "share.recording.title_format"), request.title))
                            .font(.titleMD)
                            .foregroundColor(.textPrimary)
                            .lineLimit(2)
                        Label(String(localized: "share.audio_never"), systemImage: "waveform.slash")
                            .font(.bodySM)
                            .foregroundColor(.textSecondary)
                    }
                    sendCopySection
                    NearbySendSection(sessionId: request.sessionId, title: request.title)
                    linkSection
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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
        .frame(width: 460)
        .frame(minHeight: 420, maxHeight: 720)
        .onAppear(perform: reload)
    }

    // MARK: 发送副本

    private var sendCopySection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionTitle("share.copy.title")
            Text(String(localized: "share.copy.detail"))
                .font(.bodySM)
                .foregroundColor(.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Spacing.sm) {
                sendButton(
                    format: .markdown,
                    title: String(localized: "share.copy.markdown"),
                    systemImage: "doc.text",
                    anchor: markdownAnchor
                )
                sendButton(
                    format: .subtitles,
                    title: String(localized: "share.copy.subtitles"),
                    systemImage: "captions.bubble",
                    anchor: subtitlesAnchor
                )
            }
        }
    }

    private func sendButton(
        format: FfiTranscriptFileFormat,
        title: String,
        systemImage: String,
        anchor: ViewAnchor
    ) -> some View {
        Button {
            send(format, anchor: anchor)
        } label: {
            HStack(spacing: Spacing.xs) {
                if preparing == format {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: systemImage)
                }
                Text(title)
            }
        }
        .disabled(preparing != nil)
        .background(AnchorReader(anchor: anchor))
        .accessibilityIdentifier(format == .markdown ? "share.copy.markdown" : "share.copy.subtitles")
    }

    private func send(_ format: FfiTranscriptFileFormat, anchor: ViewAnchor) {
        preparing = format
        Task {
            let url = await share.transcriptFile(sessionId: request.sessionId, title: request.title, format: format)
            preparing = nil
            guard let url, let view = anchor.view else { return }
            let picker = NSSharingServicePicker(items: [url])
            picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        }
    }

    // MARK: 只读链接

    private var linkSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionTitle("share.recording.link_title")
            Text(String(localized: "share.recording.link_detail"))
                .font(.bodySM)
                .foregroundColor(.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(links, id: \.roomId) { link in
                linkRow(link)
            }

            Button {
                createLink()
            } label: {
                HStack(spacing: Spacing.xs) {
                    if creating {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "link.badge.plus")
                    }
                    Text(String(localized: links.isEmpty ? "share.recording.create_link" : "share.recording.create_another"))
                }
            }
            .disabled(creating)
            .accessibilityIdentifier("share.recording.create_link")
        }
    }

    private func linkRow(_ link: FfiRecordingLink) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            ShareLinkCard(url: link.url, title: request.title, qrSide: 120)
            HStack(spacing: Spacing.sm) {
                Label(expiryText(link), systemImage: "clock")
                    .font(.bodySM)
                    .foregroundColor(.textTertiary)
                Spacer()
                Button(role: .destructive) {
                    confirmRevoke(link)
                } label: {
                    if revoking == link.roomId {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(String(localized: "share.recording.revoke"))
                    }
                }
                .disabled(revoking != nil)
                .accessibilityIdentifier("share.recording.revoke")
            }
        }
        .padding(Spacing.md)
        .background(Color.bgSunken)
        .clipShape(RoundedRectangle(cornerRadius: Radius.md))
    }

    private func expiryText(_ link: FfiRecordingLink) -> String {
        let remaining = max(0, link.expiresAtEpoch - Int64(Date().timeIntervalSince1970))
        let hours = remaining / 3_600
        if hours >= 1 {
            return String(format: String(localized: "share.recording.expires_hours_format"), hours)
        }
        return String(format: String(localized: "share.recording.expires_minutes_format"), max(1, remaining / 60))
    }

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

    private func sectionTitle(_ key: String.LocalizationValue) -> some View {
        Text(String(localized: key))
            .font(.bodyMedium)
            .foregroundColor(.textPrimary)
    }
}

// MARK: - 附近

/// 直播面板里的「同一网络的 ZuTalk 也能看」:和链接各管各的,可以只开一个。
/// 不经服务器,从这台 Mac 直接传过去。
struct NearbyLiveChoice: View {
    let sessionId: String
    let title: String

    @ObservedObject private var nearby = NearbyStore.shared

    var body: some View {
        let on = nearby.isLive(sessionId: sessionId)
        ShareChoice(
            isOn: Binding(
                get: { on },
                set: { $0 ? nearby.startLive(sessionId: sessionId, title: title) : nearby.stopLive() }
            ),
            title: String(localized: "nearby.live.choice"),
            detail: detail(on: on)
        )
        .accessibilityIdentifier("share.live.nearby")
    }

    private func detail(on: Bool) -> String {
        guard on else { return String(localized: "nearby.live.choice_off_detail") }
        let viewers = nearby.status?.liveViewers ?? 0
        return viewers == 0
            ? String(localized: "nearby.live.choice_on_detail")
            : String(format: String(localized: "nearby.live.viewers_format"), Int64(viewers))
    }
}

/// 共享录音面板里的「递给附近的 Mac」:同一网络里打开了接收的 ZuTalk,点一下
/// 递过去,对方点接收才收下。
struct NearbySendSection: View {
    let sessionId: String
    let title: String

    @ObservedObject private var nearby = NearbyStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(String(localized: "nearby.send.title"))
                .font(.bodyMedium)
                .foregroundColor(.textPrimary)
            Text(String(localized: "nearby.send.detail"))
                .font(.bodySM)
                .foregroundColor(.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if nearby.status?.running != true {
                // 附近走的是同步的端点:同步没开就看不见任何人。
                HStack(spacing: Spacing.sm) {
                    Label(String(localized: "nearby.send.needs_sync"), systemImage: "wifi.slash")
                        .font(.bodySM)
                        .foregroundColor(.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(String(localized: "nearby.send.turn_on")) {
                        Task { _ = await DeviceSyncStore.shared.ensureRunning() }
                    }
                }
            } else if nearby.receivers.isEmpty {
                Label(String(localized: "nearby.send.none"), systemImage: "wifi")
                    .font(.bodySM)
                    .foregroundColor(.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(nearby.receivers, id: \.deviceId) { peer in
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "laptopcomputer")
                        .foregroundColor(.textTertiary)
                    Text(peer.name.isEmpty ? String(localized: "settings.devices.unnamed") : peer.name)
                        .font(.bodySM)
                        .foregroundColor(.textPrimary)
                    Spacer()
                    if nearby.sending.contains(peer.deviceId) {
                        ProgressView().controlSize(.small)
                        Text(String(localized: "nearby.send.waiting"))
                            .font(.bodySM)
                            .foregroundColor(.textTertiary)
                    } else {
                        Button(String(localized: "nearby.send.button")) {
                            nearby.send(sessionId: sessionId, title: title, to: peer)
                        }
                    }
                }
            }
        }
        .onAppear { nearby.refresh() }
        .accessibilityIdentifier("share.recording.nearby")
    }
}

// MARK: - 零件

/// 二维码、链接本身、复制与放大。链接要**显示出来**,不能只给一个复制按钮:
/// 复制失效时还有第二条路,看得见也才核对得了粘贴得对不对。
struct ShareLinkCard: View {
    let url: String
    let title: String
    let qrSide: CGFloat

    @ObservedObject private var share = ShareActivityStore.shared

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            if let qr = ShareQRCode.image(for: url) {
                Button {
                    ShareQRPresenter.show(url: url, title: title)
                } label: {
                    Image(nsImage: qr)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: qrSide, height: qrSide)
                        .padding(ShareQRCode.quietZone(for: qrSide))
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
                }
                .buttonStyle(.plain)
                .help(String(localized: "share.link.show_large"))
                .accessibilityLabel(Text(String(localized: "share.link.qr_label")))
            }
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text(ShareLinkCard.displayed(url))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.textSecondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(url)
                Button {
                    share.copy(url, toast: "share.link.copied")
                } label: {
                    Label(String(localized: "share.link.copy"), systemImage: "doc.on.doc")
                }
                .accessibilityIdentifier("share.link.copy")
                Button {
                    ShareQRPresenter.show(url: url, title: title)
                } label: {
                    Label(String(localized: "share.link.show_large"), systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.link)
                .font(.bodySM)
            }
        }
    }

    /// 屏幕上不必把 43 个字符的密钥全摆出来 —— 复制与二维码里是完整的。
    static func displayed(_ url: String) -> String {
        let withoutScheme = url.replacingOccurrences(of: "https://", with: "")
        guard let hash = withoutScheme.firstIndex(of: "#") else { return withoutScheme }
        return String(withoutScheme[..<hash]) + "#…"
    }
}

/// 开始之前说清楚的两件事。
struct ShareAssurances: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Label(String(localized: "share.encrypted"), systemImage: "lock.fill")
            Label(String(localized: "share.audio_never"), systemImage: "waveform.slash")
        }
        .font(.bodySM)
        .foregroundColor(.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct ShareChoice: View {
    @Binding var isOn: Bool
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Spacing.md) {
                Text(title)
                    .font(.body)
                    .foregroundColor(.textPrimary)
                Spacer(minLength: Spacing.sm)
                Toggle(title, isOn: $isOn)
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
