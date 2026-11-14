// LiveTextNotice.swift
// 开始录音之前,关于「出字」唯一还要说的事。
//
// 0.8.3 以前,「出字」是每个开始按钮旁边的一颗开关。负责人的原话:「默认录音
// 就是出字，不需要有这个可配置的。」所以它不再是一个选择:有东西能出字(邀请码,
// 或自己的密钥)就出字,这里什么都不摆。只剩两种情况人得在按开始之前知道:
//
//   - 还没有能出字的东西 —— 一颗待设置的胶囊「出字」,带着警示记号,点下去是
//     设置 › 账号,邀请码和密钥都在那里填;
//   - 能出字,可这台 Mac 现在没联网 —— 一个安静的状态,图标加一个词,整句在
//     提示里。
//
// 出字时音频会发给谁去写成文字,是一条告知。它不再挂在这里:在开始按钮的提示
// 里,和设置 › 账号「出字」小标题旁的 ⓘ 里 —— 那里才是把出字接上的地方。

import SwiftUI

/// What there is to say about live text before a recording starts.
/// `nonisolated` and built from two plain values, so the rule can be checked
/// without a key, an invite or a network.
nonisolated enum StartCardLiveText: Equatable, Sendable {
    /// Something can produce text and the Mac is online: nothing to say.
    case ready
    /// Something can produce text, but this Mac is offline.
    case offline
    /// Nothing to produce text with yet: no invite code, no key.
    case needsSetup

    static func resolve(available: Bool, offline: Bool) -> StartCardLiveText {
        guard available else { return .needsSetup }
        return offline ? .offline : .ready
    }

    /// The key of the one word shown; nil when nothing is shown.
    var labelKey: String? {
        switch self {
        case .ready: return nil
        case .offline: return "network.offline.short"
        case .needsSetup: return "onboarding.step.live_text"
        }
    }

    var systemImage: String {
        switch self {
        case .ready: return "captions.bubble.fill"
        case .offline: return "wifi.slash"
        case .needsSetup: return "captions.bubble"
        }
    }

    /// The key of the sentence behind the word, for the tooltip.
    var helpKey: String? {
        switch self {
        case .ready: return nil
        case .offline: return "home.card.offline_hint"
        case .needsSetup: return "home.options.live_text_needs_setup"
        }
    }

    var title: String? {
        labelKey.map { String(localized: String.LocalizationValue($0)) }
    }

    var help: String? {
        helpKey.map { String(localized: String.LocalizationValue($0)) }
    }
}

/// The notice itself, for the slot beside a Start button: a needs-setup
/// pill, a quiet offline status, or nothing at all.
struct LiveTextNotice: View {
    @ObservedObject private var commands: CaptureCommandCenter
    // Whether live text can run follows a saved key or an invite; both
    // arrive after launch, and neither is published by the command center.
    @ObservedObject private var invite = CommunityInviteSession.shared
    @ObservedObject private var credentials = ProviderCredentialSession.shared
    @ObservedObject private var network = NetworkReachability.shared
    /// A state to draw instead of the live one.
    private let shown: StartCardLiveText?

    init(commands: CaptureCommandCenter? = nil, shown: StartCardLiveText? = nil) {
        _commands = ObservedObject(wrappedValue: commands ?? .shared)
        self.shown = shown
    }

    var body: some View {
        let _ = credentials.statusRevision
        let state = shown ?? StartCardLiveText.resolve(
            available: commands.realtimeCredentialAvailable,
            offline: network.isOffline
        )
        switch state {
        case .ready:
            EmptyView()
        case .offline:
            StatusWord(
                state.title ?? "",
                systemImage: state.systemImage,
                tint: .signalAmber,
                help: state.help
            )
            .accessibilityIdentifier("home.options.live-text.offline")
        case .needsSetup:
            ActionPill(
                state.title,
                systemImage: state.systemImage,
                tone: .dimmed,
                mark: .warning,
                help: state.help,
                accessibilityLabel: String(localized: "home.options.live_text")
            ) {
                MainNavigationStore.shared.openSettings(section: .account)
            }
            .accessibilityIdentifier("home.options.live-text")
        }
    }
}

/// What a Start button explains about live text on hover and to VoiceOver:
/// where the audio goes — a disclosure, by name — and, with an invite, how
/// long it lasts at the connections this recording will open. Empty when the
/// next recording will have no live text: nothing leaves the Mac then.
@MainActor
enum LiveTextStartHint {
    static func lines(liveText: Bool, invite: CommunityInviteSession = .shared) -> [String] {
        guard liveText else { return [] }
        // Where the audio goes, by name: this is the disclosure.
        var lines = [String(localized: "home.card.live_text_disclosure")]
        // An invite is spent by the hour: how long it lasts is said where
        // the time is about to be used.
        if let time = inviteTimeLeft(invite) {
            lines.append(String(
                format: String(localized: "home.options.live_text_invite_format"),
                time
            ))
        }
        return lines
    }

    private static func inviteTimeLeft(_ invite: CommunityInviteSession) -> String? {
        guard invite.isEnabled, invite.isActive, let remaining = invite.remainingSeconds else {
            return nil
        }
        let recordable = CommunityInviteSession.wallClockRecordableSeconds(
            remainingSeconds: remaining,
            laneCount: invite.plannedLaneCount
        )
        return RecordingPresentation.duration(ms: UInt64(max(recordable, 0)) * 1_000)
    }
}
