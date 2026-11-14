import SwiftUI

/// Where the recording in progress will be filed, beside its topic in the
/// recording bar.
///
/// The bar sits above every page, so the destination stays in sight while
/// reading another recording or writing notes, and can be changed halfway —
/// to another event, to not filing at all, or to filing without its audio.
/// In a narrow window it collapses to an archive-box icon that opens the same
/// card.
///
/// It appears only for a recording that was given an event (on the start
/// card, where that choice is confirmed). Once cleared from here it stays, in
/// its "not filing" form, until the recording ends: otherwise the one control
/// that could undo the change would vanish with it.
///
/// The card is a name and three pills. What it used to spell out — in whose
/// name, which languages, and that the audio goes too and cannot be taken
/// back — is behind the ⓘ beside the event's name.
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
            let title = filing?.eventTitle ?? String(localized: "home.card.dont_file")
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
                CityDestinationCard(
                    account: account,
                    filing: filing,
                    options: city.options,
                    // Read when the card opens; the bar does not need to
                    // follow the capture store for this.
                    languages: ActiveBilingualTranscriptStore.shared.selectedLanguages,
                    onChange: {
                        // A sheet cannot come up while the popover is still closing.
                        showsCard = false
                        DispatchQueue.main.async { showsPicker = true }
                    },
                    onNotFiling: {
                        showsCard = false
                        Task { await city.bind(sessionId: sessionId, event: nil) }
                    },
                    onAudio: { enabled in
                        Task { await city.setSessionAudio(sessionId: sessionId, enabled: enabled) }
                    }
                )
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
}

/// The card the chip opens: the event, and what can be changed about it while
/// recording. A plain view of what it is given, so it can be looked at
/// without a recording in progress.
struct CityDestinationCard: View {
    let account: FfiCityAccount
    /// Nil once the person said this recording is not to be filed.
    let filing: FfiCityFiling?
    let options: FfiCityFilingOptions
    let languages: [String]
    let onChange: () -> Void
    let onNotFiling: () -> Void
    /// Whether this recording's audio is to be filed with it.
    let onAudio: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            // When it will be filed: a status.
            Label(heading, systemImage: filing == nil ? "archivebox" : "arrow.up.circle")
                .font(.sans11)
                .foregroundColor(.textTertiary)
                .lineLimit(1)

            if let filing {
                HStack(spacing: Spacing.xs) {
                    Text(filing.eventTitle)
                        .font(.bodyMedium)
                        .foregroundColor(.textPrimary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    // What goes, where, in whose name, and that it cannot be
                    // taken back: one click away.
                    InfoButton(
                        explanation(filing),
                        accessibilityLabel: String(localized: "city.record.title")
                    )
                    Spacer(minLength: 0)
                }
                PillStrip {
                    ActionPill(
                        String(localized: "city.share.change"),
                        systemImage: "calendar",
                        help: String(localized: "city.record.change_hint"),
                        action: onChange
                    )
                    .accessibilityIdentifier(AccessibilityID.cityBarChange)
                    CityAudioPill(filing: filing, options: options, onChange: onAudio)
                        .accessibilityIdentifier("recording-bar.city.audio")
                } trailing: {
                    ActionPill(
                        String(localized: "home.card.dont_file"),
                        systemImage: "xmark.circle",
                        style: .quiet,
                        help: String(localized: "city.bar.not_filing_detail"),
                        action: onNotFiling
                    )
                    .accessibilityIdentifier(AccessibilityID.cityBarNotFiling)
                }
            } else {
                ActionPill(
                    String(localized: "home.card.choose_event"),
                    systemImage: "calendar",
                    help: String(localized: "city.bar.not_filing_detail"),
                    action: onChange
                )
                .accessibilityIdentifier(AccessibilityID.cityBarChange)
            }
        }
        .padding(Spacing.md)
        .frame(width: 320, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.cityBarCard)
    }

    private var heading: String {
        String(localized: filing == nil
            ? "city.bar.heading_none"
            : options.automatic ? "city.bar.heading_automatic" : "city.bar.heading_ask")
    }

    /// "<city> · <server> · Channel “…”", then the whole sentence of what is
    /// filed — with the audio, when this recording carries it.
    private func explanation(_ filing: FfiCityFiling) -> String {
        var place: [String] = []
        if account.cityName.isEmpty == false { place.append(account.cityName) }
        place.append(account.server)
        if let channel = filing.channelTitle, channel.isEmpty == false {
            place.append(String(format: String(localized: "city.bar.channel_format"), channel))
        }
        return [
            place.joined(separator: " · "),
            CityText.summary(
                signer: filing.signerName.isEmpty ? account.personName : filing.signerName,
                languages: languages,
                options: options,
                channel: nil,
                audio: filing.audioWanted
            ),
        ].joined(separator: "\n")
    }
}

/// This recording's audio switch: on, its audio is filed with it; off, this
/// recording goes without. It can only reduce — with the setting off it shows
/// off and cannot be turned on from here.
struct CityAudioPill: View {
    let filing: FfiCityFiling
    let options: FfiCityFilingOptions
    let onChange: (Bool) -> Void

    var body: some View {
        TogglePill(
            isOn: filing.audioWanted,
            on: .init(String(localized: "city.what.audio"), systemImage: "waveform"),
            off: .init(String(localized: "city.audio.off"), systemImage: "speaker.slash"),
            help: options.audio
                ? CityText.audioDisclosure
                : String(localized: "city.audio.reason.setting_off"),
            accessibilityLabel: String(localized: "city.what.audio")
        ) {
            onChange(filing.audioWithheld)
        }
        .disabled(options.audio == false)
    }
}
