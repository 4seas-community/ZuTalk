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
//     在城的日志里,现在删不掉。
// 只有登录了城才出现。这里只交文字。

import AppKit
import SwiftUI

struct CityShareSection: View {
    let request: RecordingShareRequest

    @ObservedObject private var city = CityStore.shared
    @State private var loaded = false
    @State private var showsPicker = false
    /// 这场录音的起止:补归时,时间重合的活动排最前。
    @State private var span: CityRecordingSpan?
    @State private var languages: [String] = []

    private var filing: FfiCityFiling? { city.filings[request.sessionId] }
    private var busy: Bool { city.busySessions.contains(request.sessionId) }

    var body: some View {
        if let account = city.account {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Label(String(localized: "city.share.title"), systemImage: "archivebox")
                    .font(.bodyMedium)
                    .foregroundColor(.textPrimary)

                if loaded == false {
                    ProgressView().controlSize(.small)
                } else if let filing {
                    switch filing.state {
                    case .filed:
                        filed(filing)
                    case .queued:
                        queued(filing)
                    case .failed:
                        failed(filing, account: account)
                    case .bound, .withdrawn:
                        notFiled(filing, account: account)
                    }
                } else {
                    notFiled(nil, account: account)
                }
            }
            .task(id: request.sessionId) { await load() }
            .sheet(isPresented: $showsPicker) {
                CityEventPickerSheet(selectedEventId: filing?.eventId, recording: span) { event in
                    Task { await city.bind(sessionId: request.sessionId, event: event) }
                }
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
        await city.loadFiling(sessionId: request.sessionId)
        loaded = true
    }

    // MARK: - 已交

    @ViewBuilder
    private func filed(_ filing: FfiCityFiling) -> some View {
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
                    ? String(localized: "city.share.filed")
                    : String(format: String(localized: "city.share.filed_format"), when),
                systemImage: "checkmark.circle"
            )
            .font(.bodySM)
            .foregroundColor(.success)
            .accessibilityIdentifier(AccessibilityID.cityShareStatus)
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

    // MARK: - 排队

    @ViewBuilder
    private func queued(_ filing: FfiCityFiling) -> some View {
        HStack(spacing: Spacing.sm) {
            if busy { ProgressView().controlSize(.small) }
            Label(
                String(localized: filing.errorCode == "city.error.offline"
                    ? "city.share.queued_offline"
                    : "city.share.queued"),
                systemImage: filing.errorCode == "city.error.offline" ? "wifi.slash" : "clock"
            )
            .font(.bodySM)
            .foregroundColor(.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier(AccessibilityID.cityShareStatus)
            Spacer(minLength: Spacing.sm)
            Button(String(localized: "city.share.retry_now")) {
                Task { await city.file(sessionId: request.sessionId) }
            }
            .disabled(busy)
            .accessibilityIdentifier(AccessibilityID.cityShareRetry)
        }
        fact(String(localized: "city.share.fact.event"), filing.eventTitle)
        publicNote
    }

    // MARK: - 没交上

    @ViewBuilder
    private func failed(_ filing: FfiCityFiling, account: FfiCityAccount) -> some View {
        strip(
            tint: .error,
            fill: Color.error.opacity(0.08),
            title: String(
                format: String(localized: "city.share.failed_format"),
                CityText.message(forCode: filing.errorCode, signer: account.personName)
            ),
            // 没交上最让人慌的是「是不是丢了」:先把这句说了。
            detail: String(localized: "city.share.failed_safe")
        ) {
            Button(String(localized: "city.action.retry")) {
                Task { await city.file(sessionId: request.sessionId) }
            }
            .disabled(busy)
            .accessibilityIdentifier(AccessibilityID.cityShareRetry)
        }
        fact(String(localized: "city.share.fact.event"), filing.eventTitle) {
            changeButton
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
