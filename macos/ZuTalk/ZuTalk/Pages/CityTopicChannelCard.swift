import AppKit
import SwiftUI

/// A topic's "Archive" card: the city channel this topic's recordings also go
/// into when they are filed under an event.
///
/// One recording belongs to one event; one topic belongs to one channel. The
/// channel is chosen here, with the topic's other settings, rather than in the
/// app's settings. ZuTalk only picks a channel: creating and managing channels
/// stays in the browser. Shows nothing while no resident is signed in.
///
/// One row: the word "Channel" and a pill showing the channel chosen. What
/// the card used to spell out underneath — what a channel is for, whose
/// channels are listed — is the pill's tooltip.
struct CityTopicChannelCard: View {
    let notebookId: String
    @ObservedObject private var city = CityStore.shared

    var body: some View {
        if let account = city.account {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Label(String(localized: "city.topic.title"), systemImage: "archivebox")
                    .font(.captionMedium)
                    .foregroundColor(.textSecondary)

                HStack(spacing: Spacing.sm) {
                    Text(String(localized: "city.topic.channel"))
                        .font(.captionMedium)
                        .foregroundColor(.textPrimary)
                    Spacer(minLength: Spacing.sm)
                    // A name gives way when the row is short of room; while
                    // there is room it is offered it before the gap is.
                    channelMenu(account)
                        .layoutPriority(1)
                }
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
        let explanation = [
            String(localized: "city.topic.subtitle"),
            String(
                format: String(localized: "city.topic.channel_detail_format"),
                account.cityName.isEmpty ? account.server : account.cityName
            ),
        ].joined(separator: "\n")
        return MenuPill(
            current?.title ?? String(localized: "city.topic.no_channel"),
            titleIsName: current != nil,
            systemImage: "number",
            help: explanation,
            accessibilityLabel: String(localized: "city.topic.channel")
        ) {
            var items = [
                PillMenuItem(String(localized: "city.topic.no_channel"), isOn: current == nil) {
                    city.setTopicChannel(notebookId: notebookId, channel: nil)
                },
            ]
            if city.channels.isEmpty == false {
                items.append(.separator)
            }
            for channel in city.channels {
                items.append(PillMenuItem(channel.title, isOn: current?.id == channel.id) {
                    city.setTopicChannel(notebookId: notebookId, channel: channel)
                })
            }
            items.append(.separator)
            // Channels are created on the city's own site; this only chooses one.
            items.append(PillMenuItem(String(localized: "city.topic.new_channel")) {
                if let url = CityText.siteURL(server: account.server) {
                    NSWorkspace.shared.open(url)
                }
            })
            return items
        }
        .accessibilityIdentifier(AccessibilityID.cityTopicChannel)
    }
}
