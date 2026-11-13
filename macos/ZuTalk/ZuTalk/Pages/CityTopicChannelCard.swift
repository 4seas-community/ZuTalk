import AppKit
import SwiftUI

/// A topic's "Archive" card: the city channel this topic's recordings also go
/// into when they are filed under an event.
///
/// One recording belongs to one event; one topic belongs to one channel. The
/// channel is chosen here, with the topic's other settings, rather than in the
/// app's settings. ZuTalk only picks a channel: creating and managing channels
/// stays in the browser. Shows nothing while no resident is signed in.
struct CityTopicChannelCard: View {
    let notebookId: String
    @ObservedObject private var city = CityStore.shared

    var body: some View {
        if let account = city.account {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Label(String(localized: "city.topic.title"), systemImage: "archivebox")
                    .font(.captionMedium)
                    .foregroundColor(.textSecondary)

                Text(String(localized: "city.topic.subtitle"))
                    .font(.caption)
                    .foregroundColor(.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: Spacing.sm) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(localized: "city.topic.channel"))
                            .font(.captionMedium)
                            .foregroundColor(.textPrimary)
                        Text(String(
                            format: String(localized: "city.topic.channel_detail_format"),
                            account.cityName.isEmpty ? account.server : account.cityName
                        ))
                        .font(.sans11)
                        .foregroundColor(.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: Spacing.sm)

                    channelMenu(account)
                }
                .padding(Spacing.md)
                .background(Color.bgSunken.opacity(0.35))
                .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
            }
            .padding(Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            // The same chrome as the other cards on the topic's settings page.
            .surfaceCard(
                fill: Color.bgElevated.opacity(0.3),
                cornerRadius: Radius.md,
                border: Color.borderGhost.opacity(0.3),
                borderWidth: 0.5
            )
            .task(id: notebookId) {
                city.loadTopicChannel(notebookId: notebookId)
                // Channels come back with the event list.
                city.refreshCalendarIfStale()
            }
            .accessibilityIdentifier(AccessibilityID.cityTopicCard)
        }
    }

    private func channelMenu(_ account: FfiCityAccount) -> some View {
        let current = city.topicChannels[notebookId]
        return Menu {
            Button {
                city.setTopicChannel(notebookId: notebookId, channel: nil)
            } label: {
                menuLabel(String(localized: "city.topic.no_channel"), selected: current == nil)
            }
            if city.channels.isEmpty == false {
                Divider()
            }
            ForEach(city.channels, id: \.id) { channel in
                Button {
                    city.setTopicChannel(notebookId: notebookId, channel: channel)
                } label: {
                    menuLabel(channel.title, selected: current?.id == channel.id)
                }
            }
            Divider()
            // Channels are created on the city's own site; this only chooses one.
            Button(String(localized: "city.topic.new_channel")) {
                if let url = CityText.siteURL(server: account.server) {
                    NSWorkspace.shared.open(url)
                }
            }
        } label: {
            Text(current?.title ?? String(localized: "city.topic.no_channel"))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel(Text(String(localized: "city.topic.channel")))
        .accessibilityValue(Text(current?.title ?? String(localized: "city.topic.no_channel")))
        .accessibilityIdentifier(AccessibilityID.cityTopicChannel)
    }

    @ViewBuilder
    private func menuLabel(_ title: String, selected: Bool) -> some View {
        if selected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }
}
