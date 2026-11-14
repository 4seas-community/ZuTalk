// SharingSettingsSection.swift
// 「设置 › 高级」里的「分享」:此刻在外面的一切 —— 正在给观众看的字幕、还没
// 过期的录音链接 —— 一处看清,随手撤销。
//
// 分享本身长在录音上(录音条、录音自己的菜单);这里不是开始分享的地方,
// 是收口的地方。链接散在各个录音里时,主持人答不出「我现在有哪些东西
// 在外面」,只能一个个录音点开看。大多数人从不分享,所以它在「高级」。
//
// 一行一条:是哪场录音、到什么时候(或者几个人在看)、复制、撤销。「怎么分享」
// 和两条告知(端到端加密但拿到链接的人都能看;音频从不离开这台 Mac)在标题
// 旁边的 ⓘ 里。

import SwiftUI

/// 「分享」那张卡画的是什么。纯数据,测试可以给任何一种。
struct SharingCardModel: Equatable {
    var live: FfiLiveLink?
    var links: [FfiRecordingLink] = []
    /// 录音的名字,按 session id。
    var titles: [String: String] = [:]
}

struct SharingSettingsSection: View {
    @ObservedObject private var share = ShareActivityStore.shared
    @Environment(\.settingsFixture) private var fixture
    @State private var links: [FfiRecordingLink] = []
    @State private var titles: [String: String] = [:]
    @State private var revoking: String?

    private var model: SharingCardModel {
        fixture?.sharing ?? SharingCardModel(live: share.live, links: links, titles: titles)
    }

    var body: some View {
        let model = model
        return SettingsGroup(
            title: String(localized: "settings.section.sharing_name"),
            subtitle: String(localized: "settings.sharing.subtitle"),
            info: Self.howSharingWorks
        ) {
            SettingsCard {
                if model.live == nil, model.links.isEmpty {
                    SettingsFullRow {
                        Text(String(localized: "settings.sharing.nothing_out"))
                            .font(PillMetrics.font)
                            .foregroundColor(Color.textTertiary)
                    }
                }
                if let live = model.live {
                    liveRow(live, title: title(live.sessionId, in: model))
                    if model.links.isEmpty == false { SettingsRowDivider() }
                }
                ForEach(Array(model.links.enumerated()), id: \.element.roomId) { index, link in
                    if index > 0 { SettingsRowDivider() }
                    linkRow(link, title: title(link.sessionId, in: model))
                }
            }
            .accessibilityIdentifier("settings.sharing.out-now")
        }
        .onAppear {
            guard fixture == nil else { return }
            reload()
        }
        .onReceive(share.$live) { _ in
            guard fixture == nil else { return }
            reload()
        }
    }

    /// 「分享」旁边 ⓘ 里的几句。不点按钮的名字:那两个入口说「做什么」不会过时。
    static var howSharingWorks: String {
        [
            "settings.sharing.subtitle",
            "settings.advanced.sharing_how_live",
            "settings.advanced.sharing_how_recording",
            "share.encrypted",
            "share.audio_never",
        ]
        .map { String(localized: String.LocalizationValue($0)) }
        .joined(separator: "\n")
    }

    private func liveRow(_ live: FfiLiveLink, title: String) -> some View {
        SettingsRow(title) {
            SettingsStatus(
                LiveShareText.status(viewers: live.viewers),
                systemImage: "dot.radiowaves.left.and.right",
                tint: .signalGreen
            )
            // The link is the row; copying it is the one icon everyone
            // knows, so the name and "until when" keep the width.
            ActionPill(
                nil,
                systemImage: "doc.on.doc",
                help: String(localized: "share.link.copy"),
                accessibilityLabel: String(localized: "share.link.copy")
            ) {
                share.copy(live.url, toast: "share.link.copied")
            }
            ActionPill(
                String(localized: "settings.action.stop"),
                systemImage: "stop.circle",
                help: String(localized: "share.live.stop"),
                accessibilityLabel: String(localized: "share.live.stop")
            ) {
                share.stopLive()
            }
            .disabled(share.liveBusy)
        }
    }

    private func linkRow(_ link: FfiRecordingLink, title: String) -> some View {
        SettingsRow(title, description: String(localized: "settings.sharing.read_only_link")) {
            SettingsStatus(
                Self.timeLeft(link),
                systemImage: "clock",
                help: String(localized: "settings.sharing.read_only_link")
            )
            // The link is the row; copying it is the one icon everyone
            // knows, so the name and "until when" keep the width.
            ActionPill(
                nil,
                systemImage: "doc.on.doc",
                help: String(localized: "share.link.copy"),
                accessibilityLabel: String(localized: "share.link.copy")
            ) {
                share.copy(link.url, toast: "share.link.copied")
            }
            ActionPill(
                String(localized: "share.recording.revoke"),
                systemImage: "xmark.circle"
            ) {
                revoke(link)
            }
            .disabled(revoking != nil)
        }
    }

    private func title(_ sessionId: String, in model: SharingCardModel) -> String {
        model.titles[sessionId] ?? String(localized: "settings.sharing.untitled_recording")
    }

    /// 「还剩 23 小时」「还剩 40 分钟」。
    static func timeLeft(_ link: FfiRecordingLink, now: Date = Date()) -> String {
        let remaining = max(0, link.expiresAtEpoch - Int64(now.timeIntervalSince1970))
        let hours = remaining / 3_600
        return hours >= 1
            ? String(format: String(localized: "share.recording.expires_hours_format"), hours)
            : String(format: String(localized: "share.recording.expires_minutes_format"), max(1, remaining / 60))
    }

    private func revoke(_ link: FfiRecordingLink) {
        revoking = link.roomId
        Task {
            _ = await share.revoke(link)
            revoking = nil
            reload()
        }
    }

    private func reload() {
        guard let core = CoreClient.shared.core else { return }
        links = core.allRecordingLinks()
        var names: [String: String] = [:]
        let sessions = Set(links.map(\.sessionId) + [share.live?.sessionId].compactMap { $0 })
        for id in sessions {
            guard let session = try? core.getSession(id: id) else { continue }
            names[id] = RecordingPresentation.title(session.title)
                ?? Date(timeIntervalSince1970: TimeInterval(session.createdAtUnixMs) / 1_000)
                    .formatted(date: .abbreviated, time: .shortened)
        }
        titles = names
    }
}
