// CityShareSection.swift
// 「分享这段录音」面板里的第一段:档案馆。和只读链接、发送副本并排,是第三种
// 把内容给出去的方式,也是唯一一种公开、长期留存的,唯一一种能带音频的。
//
// 这一段的样子:标题「档案馆」和一个 ⓘ,旁边是状态 —— 文字一个词,音频
// 一个词;下面是这场录音归到哪(活动、频道、署名、内容),再下面一排胶囊:
// 这一步能做的事。停在哪一步、说哪个词,和录音页、列表、设置里是同一套
// (`CityFilingStatus`);这里是能动手的地方。
//
// 几句必须让人读得到的话(docs/architecture/city-archive.md 第 7 节),都没有
// 删,换了地方:
//   - 档案馆里的内容是公开的,会一直留着,和 24 小时失效的链接不一样;交上去
//     的音频凭地址谁都取得到,删不掉 —— 标题旁边的 ⓘ;
//   - 交之前:以谁的名义、哪几种语言、连不连音频 ——「交到档案馆」旁边的 ⓘ;
//   - 撤下撤不干净 —— 撤下之前的确认框,一句话;
//   - 没交上、活动在城里被删:出了什么事的那一句写在面板上,旁边是唯一的动作。
// 音频:文字交上去而音频没交的(这一版以前交的、当时关着的),这里有「补交
// 音频」—— 别处不会替人去交;这一场交不交音频的开关也在这里。
// 只有登录了城才出现。

import AppKit
import SwiftUI

struct CityShareSection: View {
    let request: RecordingShareRequest

    @ObservedObject private var city = CityStore.shared
    @State private var loaded = false
    @State private var showsPicker = false
    /// 在日历那张表上按了「这场不交」、而这一场已经交上去了:等那张表收起来
    /// 再问撤不撤。
    @State private var withdrawAfterPicking = false
    /// 这场录音的起止:补归时,时间重合的活动排最前。
    @State private var span: CityRecordingSpan?
    @State private var languages: [String] = []

    private var filing: FfiCityFiling? { city.filings[request.sessionId] }

    var body: some View {
        if let account = city.account {
            CityShareContent(
                account: account,
                filing: filing,
                status: city.status(sessionId: request.sessionId),
                options: city.options,
                languages: languages,
                loaded: loaded,
                busy: city.busySessions.contains(request.sessionId),
                perform: perform
            )
            .task(id: request.sessionId) { await load() }
            .sheet(isPresented: $showsPicker, onDismiss: {
                guard withdrawAfterPicking else { return }
                withdrawAfterPicking = false
                // 那张表刚收起来;确认框是模态的,让这一轮先走完再弹。
                DispatchQueue.main.async { confirmWithdraw() }
            }) {
                CityEventPickerSheet(selectedEventId: filing?.eventId, recording: span, onChoose: choose)
            }
        }
    }

    private func load() async {
        if let info = try? CoreClient.shared.core?.getSession(id: request.sessionId) {
            span = CityRecordingSpan(
                start: Date(timeIntervalSince1970: TimeInterval(info.createdAtUnixMs) / 1_000),
                duration: TimeInterval(info.durationMs) / 1_000
            )
            languages = [info.sourceLanguage] + info.targetLanguages
        }
        // 活动在城里还在不在,要一份新近的活动列表才看得出来。
        city.refreshCalendarIfStale()
        await city.loadFiling(sessionId: request.sessionId)
        loaded = true
    }

    private func perform(_ action: CityShareContent.Action) {
        let sessionId = request.sessionId
        switch action {
        case .pick:
            showsPicker = true
        case .file:
            Task { await city.file(sessionId: sessionId) }
        case .update:
            Task { await city.update(sessionId: sessionId) }
        case .open(let url):
            NSWorkspace.shared.open(url)
        case .withdraw:
            confirmWithdraw()
        case .fileAudio:
            city.fileAudio(sessionId: sessionId)
        case .setAudio(let enabled):
            Task { await city.setSessionAudio(sessionId: sessionId, enabled: enabled) }
        }
    }

    /// 日历那张表上选好了。已经交上去的那一份换活动,是先撤下再归到新的一场,
    /// 一步做完(`CityStore.move`);「这场不交」对它来说就是撤下,照样先问一句。
    private func choose(_ event: FfiCityEvent?) {
        let sessionId = request.sessionId
        if let event {
            Task { await city.move(sessionId: sessionId, to: event) }
        } else if filing?.state == .filed {
            withdrawAfterPicking = true
        } else {
            Task { await city.bind(sessionId: sessionId, event: nil) }
        }
    }

    /// 和面板里撤销链接同一种确认框;话照实写:页面不再显示,交上去的文字和
    /// 音频留着。
    private func confirmWithdraw() {
        let alert = NSAlert()
        alert.messageText = String(localized: "city.withdraw.confirm_short")
        alert.informativeText = CityText.withdrawConfirmation
        alert.addButton(withTitle: String(localized: "city.withdraw.button"))
        alert.addButton(withTitle: String(localized: "common.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await city.withdraw(sessionId: request.sessionId) }
    }
}

/// 那一段本身:给什么画什么,所以每一种状态都能单独拿出来看。
struct CityShareContent: View {
    enum Action: Equatable {
        /// 选一场活动,或换一场。
        case pick
        case file
        case update
        case open(URL)
        case withdraw
        /// 补交音频;上一次没交成的,再试一次。
        case fileAudio
        /// 这一场交不交音频。
        case setAudio(Bool)
    }

    let account: FfiCityAccount
    let filing: FfiCityFiling?
    let status: CityFilingStatus
    let options: FfiCityFilingOptions
    let languages: [String]
    var loaded = true
    var busy = false
    let perform: (Action) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            header
            if loaded == false {
                ProgressView().controlSize(.small)
            } else {
                if let sentence {
                    Text(sentence)
                        .font(.bodySM)
                        .foregroundColor(.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(status.kind == .failed ? String(localized: "city.share.failed_safe") : "")
                }
                if let filing {
                    facts(filing)
                }
                actions
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.cityShare)
    }

    // MARK: - 标题和状态

    private var header: some View {
        HStack(spacing: Spacing.xs) {
            Label(String(localized: "city.share.title"), systemImage: "archivebox")
                .font(.bodyMedium)
                .foregroundColor(.textPrimary)
            // 和链接的区别:公开、一直留着;音频也是。
            InfoButton(
                [String(localized: "city.share.public_note"), String(localized: "city.audio.public")]
                    .joined(separator: "\n"),
                accessibilityLabel: String(localized: "city.share.title")
            )
            Spacer(minLength: Spacing.sm)
            if loaded, filing != nil || busy {
                HStack(spacing: Spacing.sm) {
                    if busy { ProgressView().controlSize(.small) }
                    CityStatusWord(status)
                    if let audio = status.audioBeside {
                        CityStatusWord(audio)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(AccessibilityID.cityShareStatus)
            }
        }
    }

    /// 面板上只有三种整句:还没交的那一句(空状态),没交上的原因,活动被删
    /// 以后会怎样。
    private var sentence: String? {
        guard filing != nil else { return String(localized: "city.share.not_filed") }
        switch status.kind {
        case .failed:
            return String(format: String(localized: "city.share.failed_format"), status.reason ?? "")
        case .eventGone:
            return status.reason
        case .notFiled, .chosen, .sending, .waiting, .filed, .changed, .withdrawn:
            return nil
        }
    }

    // MARK: - 归到哪、交了什么

    @ViewBuilder
    private func facts(_ filing: FfiCityFiling) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm - 2) {
            fact(String(localized: "city.share.fact.event"), filing.eventTitle)
            if let channel = filing.channelTitle, channel.isEmpty == false {
                fact(String(localized: "city.share.fact.channel"), channel)
            }
            if filing.state == .filed {
                fact(String(localized: "city.share.fact.signer"), Self.signer(filing))
                let content = CityText.content(filing)
                if content.isEmpty == false {
                    fact(String(localized: "city.share.fact.content"), content)
                }
            }
        }
    }

    /// 「Sam · 今天 13:04」。
    static func signer(_ filing: FfiCityFiling) -> String {
        guard let at = filing.filedAtEpoch else { return filing.signerName }
        return filing.signerName + " · " + CityText.moment(epoch: at)
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.xsm) {
            Text(label)
                .font(.sans11)
                .foregroundColor(.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 76, alignment: .leading)
            Text(value)
                .font(.bodySM)
                .foregroundColor(.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - 这一步能做的事

    /// 一排胶囊。主要的那一件(交、更新)着色;撤下排在最后,安静。
    private var actions: some View {
        PillStrip {
            leading
        } trailing: {
            if let filing, filing.state == .filed {
                ActionPill(
                    String(localized: "city.action.withdraw"),
                    systemImage: "arrow.uturn.backward",
                    style: .quiet,
                    help: CityText.withdrawConfirmation
                ) {
                    perform(.withdraw)
                }
                .disabled(busy)
                .accessibilityIdentifier(AccessibilityID.cityShareWithdraw)
            }
        }
    }

    @ViewBuilder
    private var leading: some View {
        if let filing {
            switch status.kind {
            case .chosen, .withdrawn, .notFiled:
                // 先归到一场活动才能交:这是交出去之前的那一次确认。
                primary(String(localized: "city.action.file"), "arrow.up.circle", .file, AccessibilityID.cityShareFile)
                // 会交什么、以谁的名义、连不连音频:按下之前读得到。
                InfoButton(
                    CityText.summary(
                        signer: account.personName,
                        languages: languages,
                        options: options,
                        channel: filing.channelTitle,
                        audio: filing.audioWanted
                    ),
                    accessibilityLabel: String(localized: "city.action.file")
                )
                CityAudioPill(filing: filing, options: options) { perform(.setAudio($0)) }
                    .disabled(busy)
                    .accessibilityIdentifier("share.city.audio")
                changePill
            case .sending:
                EmptyView()
            case .waiting:
                if status.primaryAction == .retry {
                    pill(String(localized: "city.action.retry"), "arrow.clockwise", .file, AccessibilityID.cityShareRetry)
                }
                changePill
            case .failed:
                // 活动在城里没了:重试多少次都一样,动作换成「换一场」。
                if status.primaryAction == .chooseEvent {
                    primary(
                        String(localized: "city.action.change_event"),
                        "calendar",
                        .pick,
                        AccessibilityID.cityShareChange
                    )
                } else {
                    primary(String(localized: "city.action.retry"), "arrow.clockwise", .file, AccessibilityID.cityShareRetry)
                    changePill
                }
            case .eventGone:
                primary(
                    String(localized: "city.action.change_event"),
                    "calendar",
                    .pick,
                    AccessibilityID.cityShareChange
                )
            case .filed, .changed:
                if status.kind == .changed {
                    // 每次更新都是一次对外发送:人按了才发,只发改过的那几句。
                    primary(
                        String(localized: "city.action.update"),
                        "arrow.triangle.2.circlepath",
                        .update,
                        AccessibilityID.cityShareUpdate,
                        help: String(localized: "city.share.changed_detail")
                    )
                }
                audioPills(filing)
                if let url = CityText.webURL(filing.webUrl) {
                    pill(String(localized: "city.action.open"), "arrow.up.right.square", .open(url), AccessibilityID.cityShareOpen)
                }
            }
        } else {
            primary(String(localized: "home.card.choose_event"), "calendar", .pick, AccessibilityID.cityShareChange)
        }
    }

    /// 音频这一路能做的:补交(或再试),和这一场交不交的开关。
    @ViewBuilder
    private func audioPills(_ filing: FfiCityFiling) -> some View {
        if let audio = status.audio {
            switch audio.action {
            case .file:
                pill(
                    String(localized: "city.audio.file"),
                    "waveform",
                    .fileAudio,
                    "share.city.audio.file",
                    help: CityText.audioDisclosure
                )
            case .retry:
                pill(
                    String(localized: "city.action.retry"),
                    "arrow.clockwise",
                    .fileAudio,
                    "share.city.audio.file",
                    help: audio.reason
                )
            case nil:
                EmptyView()
            }
            // 开关只在它改得了什么的时候出现:音频还在路上(可以叫停),或者
            // 这一场单独关着(可以改回来)。
            if filing.audioWithheld || filing.audioDue {
                CityAudioPill(filing: filing, options: options) { perform(.setAudio($0)) }
                    .disabled(busy)
                    .accessibilityIdentifier("share.city.audio")
            }
        }
    }

    private var changePill: some View {
        ActionPill(
            String(localized: "city.share.change"),
            systemImage: "calendar",
            style: .quiet,
            help: String(localized: "city.record.change_hint")
        ) {
            perform(.pick)
        }
        .disabled(busy)
        .accessibilityIdentifier(AccessibilityID.cityShareChange)
    }

    private func primary(
        _ title: String,
        _ systemImage: String,
        _ action: Action,
        _ identifier: String,
        help: String? = nil
    ) -> some View {
        ActionPill(title, systemImage: systemImage, tone: .on, help: help) { perform(action) }
            .disabled(busy)
            .accessibilityIdentifier(identifier)
    }

    private func pill(
        _ title: String,
        _ systemImage: String,
        _ action: Action,
        _ identifier: String,
        help: String? = nil
    ) -> some View {
        ActionPill(title, systemImage: systemImage, help: help) { perform(action) }
            .disabled(busy)
            .accessibilityIdentifier(identifier)
    }
}
