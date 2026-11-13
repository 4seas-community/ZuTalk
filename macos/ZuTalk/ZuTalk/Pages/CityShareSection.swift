// CityShareSection.swift
// 「共享这段录音」面板里的第一段:档案馆。和只读链接、发送副本并排,是第三种
// 把文字给出去的方式,也是唯一一种公开、长期留存的。
//
// 几句必须说对的话(docs/architecture/city-archive.md):
//   - 档案馆里的内容是公开的,会一直留着,和 24 小时失效的链接不一样;
//   - 在 ZuTalk 改了字不会自动同步过去,人按「更新」才发 —— 每次更新都是
//     一次对外发送;
//   - 没交上要写人能照做的话:谁、在哪、做什么;
//   - 撤下撤不干净:那一件从档案馆页面上消失,但已经交上去的转录记录还留
//     在城的日志里,现在删不掉;
//   - 交上去以后活动在城里被删了:档案馆里看不到这一件,要明说,并给一条
//     路(换一场活动)。本机写着「已交」而城里没有,人会以为没同步。
// 停在哪一步、说哪句短话,和录音页、列表、设置里是同一套(`CityFilingStatus`);
// 这里是把那一步展开来说、并且能动手的地方。
// 只有登录了城才出现。这里只交文字。

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
    private var busy: Bool { city.busySessions.contains(request.sessionId) }

    var body: some View {
        if let account = city.account {
            let status = city.status(sessionId: request.sessionId)
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Label(String(localized: "city.share.title"), systemImage: "archivebox")
                    .font(.bodyMedium)
                    .foregroundColor(.textPrimary)

                if loaded == false {
                    ProgressView().controlSize(.small)
                } else if let filing {
                    switch status.kind {
                    case .filed, .changed:
                        filed(filing, status: status)
                    case .eventGone:
                        eventGone(filing, status: status)
                    case .sending:
                        sending(filing, status: status)
                    case .waiting:
                        queued(filing, status: status)
                    case .failed:
                        failed(filing, status: status)
                    case .notFiled, .chosen, .withdrawn:
                        notFiled(filing, account: account)
                    }
                } else {
                    notFiled(nil, account: account)
                }
            }
            .task(id: request.sessionId) { await load() }
            .sheet(isPresented: $showsPicker, onDismiss: {
                guard withdrawAfterPicking else { return }
                withdrawAfterPicking = false
                // 那张表刚收起来;确认框是模态的,让这一轮先走完再弹。
                DispatchQueue.main.async { confirmWithdraw() }
            }) {
                CityEventPickerSheet(selectedEventId: filing?.eventId, recording: span, onChoose: choose)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(AccessibilityID.cityShare)
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

    // MARK: - 已交

    @ViewBuilder
    private func filed(_ filing: FfiCityFiling, status: CityFilingStatus) -> some View {
        let when = filing.filedAtEpoch.map { CityText.moment(epoch: $0) } ?? ""
        if filing.changedSentences > 0 {
            strip(
                tint: .warning,
                fill: .accentGoldSoft,
                title: String(
                    format: String(localized: "city.share.changed_format"),
                    Int64(filing.changedSentences)
                ),
                detail: String(localized: "city.share.changed_detail")
            ) {
                Button(String(localized: "city.share.update")) {
                    Task { await city.update(sessionId: request.sessionId) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy)
                .accessibilityIdentifier(AccessibilityID.cityShareUpdate)
            }
        } else {
            Label(
                when.isEmpty
                    ? status.label
                    : String(format: String(localized: "city.share.filed_format"), when),
                systemImage: status.symbol
            )
            .font(.bodySM)
            .foregroundColor(.success)
            .accessibilityIdentifier(AccessibilityID.cityShareStatus)
        }
        if let reason = status.reason {
            // 上一次更新或撤下没成:东西还在档案馆,原因留在这,不让它无声无息。
            Text(reason)
                .font(.bodySM)
                .foregroundColor(.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        VStack(alignment: .leading, spacing: Spacing.sm - 2) {
            fact(String(localized: "city.share.fact.event"), filing.eventTitle) {
                openButton(filing)
            }
            if let channel = filing.channelTitle, channel.isEmpty == false {
                fact(String(localized: "city.share.fact.channel"), channel)
            }
            if filing.changedSentences > 0 {
                fact(
                    String(localized: "city.share.fact.last"),
                    String(format: String(localized: "city.share.last_format"), when, filing.signerName)
                )
            } else {
                fact(String(localized: "city.share.fact.signer"), filing.signerName)
                fact(String(localized: "city.share.fact.content"), CityText.content(filing))
            }
        }

        publicNote

        HStack(spacing: Spacing.sm) {
            Button(String(localized: "city.share.withdraw"), role: .destructive) {
                confirmWithdraw()
            }
            .disabled(busy)
            .accessibilityIdentifier(AccessibilityID.cityShareWithdraw)
            if busy { ProgressView().controlSize(.small) }
        }
    }

    @ViewBuilder
    private func openButton(_ filing: FfiCityFiling) -> some View {
        if let url = CityText.webURL(filing.webUrl) {
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                Label(String(localized: "city.share.open"), systemImage: "arrow.up.right.square")
            }
            .accessibilityIdentifier(AccessibilityID.cityShareOpen)
        }
    }

    // MARK: - 活动在城里被删了

    /// 交上去了,活动后来在城里被删掉或取消:档案馆里看不到这一件。明说,给
    /// 两条路 —— 换一场活动(先撤下再归到新的一场),或者撤下。不给「在浏览器
    /// 打开」:那边只会是一个空页面。
    @ViewBuilder
    private func eventGone(_ filing: FfiCityFiling, status: CityFilingStatus) -> some View {
        strip(
            tint: .warning,
            fill: .accentGoldSoft,
            title: status.label,
            detail: status.reason ?? ""
        ) {
            Button(String(localized: "city.action.change_event")) {
                showsPicker = true
            }
            .buttonStyle(.borderedProminent)
            .disabled(busy)
            .accessibilityIdentifier(AccessibilityID.cityShareChange)
        }

        VStack(alignment: .leading, spacing: Spacing.sm - 2) {
            fact(String(localized: "city.share.fact.event"), filing.eventTitle)
            if let when = filing.filedAtEpoch.map({ CityText.moment(epoch: $0) }) {
                fact(
                    String(localized: "city.share.fact.last"),
                    String(format: String(localized: "city.share.last_format"), when, filing.signerName)
                )
            }
        }

        HStack(spacing: Spacing.sm) {
            Button(String(localized: "city.share.withdraw"), role: .destructive) {
                confirmWithdraw()
            }
            .disabled(busy)
            .accessibilityIdentifier(AccessibilityID.cityShareWithdraw)
            if busy { ProgressView().controlSize(.small) }
        }
    }

    // MARK: - 正在交

    @ViewBuilder
    private func sending(_ filing: FfiCityFiling, status: CityFilingStatus) -> some View {
        HStack(spacing: Spacing.sm) {
            ProgressView().controlSize(.small)
            Text(status.label)
                .font(.bodySM)
                .foregroundColor(.textSecondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AccessibilityID.cityShareStatus)
        fact(String(localized: "city.share.fact.event"), filing.eventTitle)
        publicNote
    }

    // MARK: - 排队

    /// 没连上城的服务器,排着队。会自己再试,所以是一句交代,不是报错。
    /// 「这台 Mac 没有联网」只在系统确认没有网络时才说;那时现在重试也是
    /// 白试,按钮就不出。
    @ViewBuilder
    private func queued(_ filing: FfiCityFiling, status: CityFilingStatus) -> some View {
        HStack(spacing: Spacing.sm) {
            Label(
                String(localized: city.offline ? "city.share.queued_offline" : "city.share.queued"),
                systemImage: status.symbol
            )
            .font(.bodySM)
            .foregroundColor(.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier(AccessibilityID.cityShareStatus)
            Spacer(minLength: Spacing.sm)
            if status.primaryAction == .retry {
                Button(String(localized: "city.share.retry_now")) {
                    Task { await city.file(sessionId: request.sessionId) }
                }
                .accessibilityIdentifier(AccessibilityID.cityShareRetry)
            }
        }
        fact(String(localized: "city.share.fact.event"), filing.eventTitle) {
            changeButton
        }
        publicNote
    }

    // MARK: - 没交上

    @ViewBuilder
    private func failed(_ filing: FfiCityFiling, status: CityFilingStatus) -> some View {
        // 活动在城里没了:重试多少次都一样,头一个按钮换成「换一场活动」。
        let needsAnotherEvent = status.primaryAction == .chooseEvent
        strip(
            tint: .error,
            fill: Color.error.opacity(0.08),
            title: String(format: String(localized: "city.share.failed_format"), status.reason ?? ""),
            // 没交上最让人慌的是「是不是丢了」:先把这句说了。
            detail: String(localized: "city.share.failed_safe")
        ) {
            if needsAnotherEvent {
                Button(String(localized: "city.action.change_event")) {
                    showsPicker = true
                }
                .disabled(busy)
                .accessibilityIdentifier(AccessibilityID.cityShareChange)
            } else {
                Button(String(localized: "city.action.retry")) {
                    Task { await city.file(sessionId: request.sessionId) }
                }
                .disabled(busy)
                .accessibilityIdentifier(AccessibilityID.cityShareRetry)
            }
        }
        if needsAnotherEvent {
            fact(String(localized: "city.share.fact.event"), filing.eventTitle)
        } else {
            fact(String(localized: "city.share.fact.event"), filing.eventTitle) {
                changeButton
            }
        }
    }

    // MARK: - 还没交

    @ViewBuilder
    private func notFiled(_ filing: FfiCityFiling?, account: FfiCityAccount) -> some View {
        Text(String(localized: filing?.state == .withdrawn
            ? "city.share.withdrawn"
            : "city.share.not_filed"))
            .font(.bodySM)
            .foregroundColor(.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier(AccessibilityID.cityShareStatus)

        if let filing {
            fact(String(localized: "city.share.fact.event"), filing.eventTitle) {
                changeButton
            }
        }

        HStack(spacing: Spacing.sm) {
            if filing == nil {
                Button(String(localized: "city.share.pick")) {
                    showsPicker = true
                }
                .accessibilityIdentifier(AccessibilityID.cityShareChange)
            }
            // 先归到一场活动才能交:这是交出去之前的那一次确认。
            Button(String(localized: "city.action.file")) {
                Task { await city.file(sessionId: request.sessionId) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(filing == nil || busy)
            .accessibilityIdentifier(AccessibilityID.cityShareFile)
            if busy { ProgressView().controlSize(.small) }
        }

        Text(CityText.summary(
            signer: account.personName,
            languages: languages,
            options: city.options,
            channel: filing?.channelTitle
        ))
        .font(.bodySM)
        .foregroundColor(.textTertiary)
        .fixedSize(horizontal: false, vertical: true)

        publicNote
    }

    // MARK: - 零件

    private var changeButton: some View {
        Button(String(localized: "city.share.change")) {
            showsPicker = true
        }
        .buttonStyle(.link)
        .disabled(busy)
        .accessibilityIdentifier(AccessibilityID.cityShareChange)
    }

    /// 和链接的区别要写在界面上:公开、一直留着。
    private var publicNote: some View {
        Text(String(localized: "city.share.public_note"))
            .font(.bodySM)
            .foregroundColor(.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func fact(_ label: String, _ value: String) -> some View {
        fact(label, value) { EmptyView() }
    }

    private func fact<Trailing: View>(
        _ label: String,
        _ value: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.xsm) {
            Text(label)
                .font(.sans11)
                .foregroundColor(.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: 76, alignment: .leading)
            Text(value)
                .font(.bodySM)
                .foregroundColor(.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Spacing.sm)
            trailing()
        }
        .accessibilityElement(children: .contain)
    }

    private func strip<Action: View>(
        tint: Color,
        fill: Color,
        title: String,
        detail: String,
        @ViewBuilder action: () -> Action
    ) -> some View {
        HStack(alignment: .top, spacing: Spacing.sm + 2) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundColor(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.sans12Semibold)
                    .foregroundColor(.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(.bodySM)
                    .foregroundColor(.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Spacing.sm)
            action()
        }
        .padding(.horizontal, Spacing.xsm)
        .padding(.vertical, Spacing.sm + 2)
        .surfaceCard(fill: fill, cornerRadius: Radius.sm)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.cityShareStatus)
    }

    /// 和面板里撤销链接同一种确认框;话照实写。
    private func confirmWithdraw() {
        let alert = NSAlert()
        alert.messageText = String(localized: "city.withdraw.confirm_title")
        alert.informativeText = String(localized: "city.withdraw.confirm_message")
        alert.addButton(withTitle: String(localized: "city.withdraw.button"))
        alert.addButton(withTitle: String(localized: "common.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await city.withdraw(sessionId: request.sessionId) }
    }
}
