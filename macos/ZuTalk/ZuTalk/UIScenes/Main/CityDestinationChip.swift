import SwiftUI

/// Where the recording in progress will be filed, beside its topic in the
/// recording bar.
///
/// The bar sits above every page, so the destination stays in sight while
/// reading another recording or writing notes, and can be changed halfway —
/// to another event, or to not filing at all. In a narrow window it collapses
/// to an archive-box icon that opens the same card.
///
/// It appears only for a recording that was given an event (on the Record
/// page, where that choice is confirmed). Once cleared from here it stays, in
/// its "not filing" form, until the recording ends: otherwise the one control
/// that could undo the change would vanish with it.
struct CityDestinationChip: View {
    /// An icon instead of the event's name, for a narrow window.
    var compact = false
    @ObservedObject private var city = CityStore.shared
    @State private var showsCard = false
    @State private var showsPicker = false

    var body: some View {
        if let account = city.account,
           let sessionId = city.activeSessionId,
           city.activeFiling != nil || city.activeDestinationCleared {
            let filing = city.activeFiling
            let title = filing?.eventTitle ?? String(localized: "city.action.not_filing")
            Button {
                showsCard.toggle()
            } label: {
                Group {
                    if compact {
                        Image(systemName: "archivebox")
                            .frame(width: 30, height: 30)
                    } else {
                        Label(title, systemImage: "archivebox")
                            .lineLimit(1)
                            .frame(maxWidth: 160, alignment: .leading)
                            .padding(.horizontal, Spacing.sm + 2)
                            .frame(minHeight: 30)
                    }
                }
                .font(.bodySM)
                .foregroundColor(showsCard ? .textPrimary : .textSecondary)
                .overlay(
                    Capsule().strokeBorder(
                        showsCard ? Color.brandAccent : Color.borderSubtle,
                        lineWidth: Stroke.thin
                    )
                )
                .clipShape(Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(Self.summary(filing))
            .accessibilityLabel(Text(Self.summary(filing)))
            .accessibilityHint(Text(String(localized: "city.bar.hint")))
            .accessibilityIdentifier(AccessibilityID.cityBarChip)
            .popover(isPresented: $showsCard, arrowEdge: .bottom) {
                card(account: account, sessionId: sessionId, filing: filing)
            }
            .sheet(isPresented: $showsPicker) {
                CityEventPickerSheet(selectedEventId: filing?.eventId, recording: nil) { event in
                    Task { await city.bind(sessionId: sessionId, event: event) }
                }
            }
        }
    }

    private static func summary(_ filing: FfiCityFiling?) -> String {
        guard let filing else { return String(localized: "city.bar.not_filing") }
        return String(format: String(localized: "city.bar.files_to_format"), filing.eventTitle)
    }

    private func card(account: FfiCityAccount, sessionId: String, filing: FfiCityFiling?) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm + 2) {
            Text(String(localized: filing == nil
                ? "city.bar.heading_none"
                : city.options.automatic ? "city.bar.heading_automatic" : "city.bar.heading_ask"))
                .captionXsLabel()
                .foregroundColor(.textTertiary)

            if let filing {
                VStack(alignment: .leading, spacing: 2) {
                    Text(filing.eventTitle)
                        .font(.bodyMedium)
                        .foregroundColor(.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(Self.place(account: account, channel: filing.channelTitle))
                        .font(.sans11)
                        .foregroundColor(.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                line(
                    systemImage: "archivebox",
                    text: CityText.whatIsFiled(
                        signer: filing.signerName.isEmpty ? account.personName : filing.signerName,
                        // Read when the card opens; the bar does not need to
                        // follow the capture store for this.
                        languages: ActiveBilingualTranscriptStore.shared.selectedLanguages,
                        options: city.options
                    )
                )
                line(systemImage: "lock.fill", text: String(localized: "city.summary.audio_stays"))
            } else {
                Text(String(localized: "city.bar.not_filing_detail"))
                    .font(.bodySM)
                    .foregroundColor(.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: Spacing.sm) {
                Button(String(localized: filing == nil
                    ? "city.action.pick_from_calendar"
                    : "city.action.change_event")) {
                    // A sheet cannot come up while the popover is still closing.
                    showsCard = false
                    DispatchQueue.main.async { showsPicker = true }
                }
                .accessibilityIdentifier(AccessibilityID.cityBarChange)
                if filing != nil {
                    Button(String(localized: "city.action.not_filing")) {
                        showsCard = false
                        Task { await city.bind(sessionId: sessionId, event: nil) }
                    }
                    .buttonStyle(.link)
                    .accessibilityIdentifier(AccessibilityID.cityBarNotFiling)
                }
            }
            .padding(.top, 2)
        }
        .padding(Spacing.md)
        .frame(width: 300, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.cityBarCard)
    }

    private func line(systemImage: String, text: String) -> some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Image(systemName: systemImage)
                .iconSizeSmall()
                .foregroundColor(.textTertiary)
                .accessibilityHidden(true)
            Text(text)
                .font(.sans11)
                .foregroundColor(.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// "<city> · <server> · Channel “…”".
    private static func place(account: FfiCityAccount, channel: String?) -> String {
        var parts: [String] = []
        if account.cityName.isEmpty == false { parts.append(account.cityName) }
        parts.append(account.server)
        if let channel, channel.isEmpty == false {
            parts.append(String(format: String(localized: "city.bar.channel_format"), channel))
        }
        return parts.joined(separator: " · ")
    }
}
