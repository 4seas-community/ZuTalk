// SharingSettingsSection.swift
// 设置 › 共享:此刻在外面的一切 —— 正在直播的链接、还没过期的录音链接 ——
// 一处看清,随手撤销。
//
// 共享本身长在录音上(录音条、录音的「共享…」);这里不是开始共享的地方,
// 是收口的地方。链接散在各个录音里时,主持人答不出「我现在有哪些东西
// 在外面」,只能一个个录音点开看。

import SwiftUI

struct SharingSettingsSection: View {
    @ObservedObject private var share = ShareActivityStore.shared
    @State private var links: [FfiRecordingLink] = []
    @State private var titles: [String: String] = [:]
    @State private var revoking: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            SettingsPageHeader(
                title: String(localized: "settings.section.sharing_name"),
                subtitle: String(localized: "settings.sharing.subtitle")
            )

            SettingsCard(title: String(localized: "settings.sharing.out_now")) {
                if share.live == nil, links.isEmpty {
                    SettingsFullRow {
                        Text(String(localized: "settings.sharing.nothing_out"))
                            .font(Font.sans12)
                            .foregroundColor(Color.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if let live = share.live {
                    liveRow(live)
                    if links.isEmpty == false { SettingsRowDivider() }
                }
                ForEach(Array(links.enumerated()), id: \.element.roomId) { index, link in
                    if index > 0 { SettingsRowDivider() }
                    linkRow(link)
                }
            }
            .accessibilityIdentifier("settings.sharing.out-now")

            SettingsCard(title: String(localized: "settings.sharing.how")) {
                SettingsFullRow {
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        Label(String(localized: "settings.sharing.how_live"), systemImage: "qrcode")
                        Label(String(localized: "settings.sharing.how_recording"), systemImage: "square.and.arrow.up")
                        Label(String(localized: "share.encrypted"), systemImage: "lock.fill")
                        Label(String(localized: "share.audio_never"), systemImage: "waveform.slash")
                    }
                    .font(Font.sans12)
                    .foregroundColor(Color.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onAppear(perform: reload)
        .onReceive(share.$live) { _ in reload() }
    }

    private func liveRow(_ live: FfiLiveLink) -> some View {
        SettingsRow(
            title(live.sessionId),
            description: LiveShareText.status(viewers: live.viewers)
        ) {
            HStack(spacing: Spacing.sm) {
                Button(String(localized: "share.link.copy")) { share.copy(live.url, toast: "share.link.copied") }
                Button(String(localized: "share.live.stop")) { share.stopLive() }
                    .disabled(share.liveBusy)
            }
        }
    }

    private func linkRow(_ link: FfiRecordingLink) -> some View {
        SettingsRow(title(link.sessionId), description: expiry(link)) {
            HStack(spacing: Spacing.sm) {
                Button(String(localized: "share.link.copy")) { share.copy(link.url, toast: "share.link.copied") }
                Button(String(localized: "share.recording.revoke")) { revoke(link) }
                    .disabled(revoking != nil)
            }
        }
    }

    private func title(_ sessionId: String) -> String {
        titles[sessionId] ?? String(localized: "settings.sharing.untitled_recording")
    }

    private func expiry(_ link: FfiRecordingLink) -> String {
        let remaining = max(0, link.expiresAtEpoch - Int64(Date().timeIntervalSince1970))
        let hours = remaining / 3_600
        let left = hours >= 1
            ? String(format: String(localized: "share.recording.expires_hours_format"), hours)
            : String(format: String(localized: "share.recording.expires_minutes_format"), max(1, remaining / 60))
        return String(localized: "settings.sharing.read_only_link") + " · " + left
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
