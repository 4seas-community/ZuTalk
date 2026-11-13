// CityFilingsCard.swift
// 设置 › 城 里「已交到档案馆」那张表:从这台 Mac 交出去的每一场,能打开、
// 能在改过字以后更新、能撤下。还在排队和没交上的也列着,免得卡住了没人知道。
//
// 只归了活动还没交的、已经撤下的不在这里:它们没有东西在档案馆里。

import AppKit
import SwiftUI

struct CityFilingsCard: View {
    @ObservedObject private var city = CityStore.shared
    @State private var withdrawing: FfiCityFiling?

    private var rows: [FfiCityFiling] {
        city.filedList.filter { $0.state == .filed || $0.state == .queued || $0.state == .failed }
    }

    var body: some View {
        SettingsCard(
            title: String(localized: "city.filings.title"),
            subtitle: String(localized: "city.filings.subtitle")
        ) {
            if rows.isEmpty {
                SettingsFullRow {
                    Text(String(localized: "city.filings.empty"))
                        .font(Font.sans12)
                        .foregroundColor(.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            ForEach(Array(rows.enumerated()), id: \.element.sessionId) { index, filing in
                if index > 0 { SettingsRowDivider() }
                row(filing)
            }
        }
        .accessibilityIdentifier(AccessibilityID.citySettingsFilings)
        .onAppear { city.reloadFiledList() }
        .alert(
            String(localized: "city.withdraw.confirm_title"),
            isPresented: Binding(get: { withdrawing != nil }, set: { if !$0 { withdrawing = nil } }),
            presenting: withdrawing
        ) { filing in
            Button(String(localized: "city.withdraw.button"), role: .destructive) {
                withdrawing = nil
                Task { await city.withdraw(sessionId: filing.sessionId) }
            }
            Button(String(localized: "common.cancel"), role: .cancel) { withdrawing = nil }
        } message: { _ in
            // 撤下撤不干净:照实说,不让人以为点了就什么都没了。
            Text(String(localized: "city.withdraw.confirm_message"))
        }
    }

    private func row(_ filing: FfiCityFiling) -> some View {
        HStack(alignment: .center, spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(filing.eventTitle)
                    .font(Font.sans12)
                    .foregroundColor(.textPrimary)
                    .lineLimit(2)
                Text(Self.detail(filing, signer: city.account?.personName))
                    .font(Font.sans11)
                    .foregroundColor(Self.detailColor(filing))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: Spacing.md)
            if city.busySessions.contains(filing.sessionId) {
                ProgressView().controlSize(.small)
            } else {
                controls(filing)
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.citySettingsFiling(sessionId: filing.sessionId))
    }

    @ViewBuilder
    private func controls(_ filing: FfiCityFiling) -> some View {
        HStack(spacing: Spacing.sm) {
            switch filing.state {
            case .filed:
                if let url = CityText.webURL(filing.webUrl) {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Label(String(localized: "city.action.open"), systemImage: "arrow.up.right.square")
                    }
                    .accessibilityIdentifier(AccessibilityID.citySettingsFilingOpen)
                }
                if filing.changedSentences > 0 {
                    Button(String(localized: "city.action.update")) {
                        Task { await city.update(sessionId: filing.sessionId) }
                    }
                    .accessibilityIdentifier(AccessibilityID.citySettingsFilingUpdate)
                }
                Button(String(localized: "city.action.withdraw"), role: .destructive) {
                    withdrawing = filing
                }
                .accessibilityIdentifier(AccessibilityID.citySettingsFilingWithdraw)
            case .queued, .failed:
                Button(String(localized: "city.action.retry")) {
                    Task { await city.file(sessionId: filing.sessionId) }
                }
                .accessibilityIdentifier(AccessibilityID.citySettingsFilingRetry)
            case .bound, .withdrawn:
                EmptyView()
            }
        }
    }

    /// 「11月6日 · English、ไทย和中文 · 已交」。改过字、排队、没交上,最后一段
    /// 换成那件事。
    static func detail(_ filing: FfiCityFiling, signer: String?) -> String {
        var parts = [CityText.day(CityText.date(ms: filing.eventStartMs))]
        let languages = CityText.languageNames(filing.languages.map(\.language))
        if languages.isEmpty == false {
            parts.append(ListFormatter.localizedString(byJoining: languages))
        }
        parts.append(status(filing, signer: signer))
        return parts.joined(separator: " · ")
    }

    static func status(_ filing: FfiCityFiling, signer: String?) -> String {
        switch filing.state {
        case .filed:
            return filing.changedSentences > 0
                ? String(format: String(localized: "city.filing.changed_format"), Int64(filing.changedSentences))
                : String(localized: "city.filing.filed")
        case .queued:
            return String(localized: filing.errorCode == "city.error.offline"
                ? "city.filing.queued_offline"
                : "city.filing.queued")
        case .failed:
            return String(
                format: String(localized: "city.filing.failed_format"),
                CityText.message(forCode: filing.errorCode, signer: signer)
            )
        case .bound:
            return String(localized: "city.filing.bound")
        case .withdrawn:
            return String(localized: "city.filing.withdrawn")
        }
    }

    /// 颜色不是唯一的信号:每种状态的话本身就不一样。
    private static func detailColor(_ filing: FfiCityFiling) -> Color {
        switch filing.state {
        case .failed: return .error
        case .filed where filing.changedSentences > 0: return .warning
        default: return .textTertiary
        }
    }
}
