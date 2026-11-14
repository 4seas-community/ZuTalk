// CityFilingSheet.swift
// 一场录好的录音,从它自己身上交到活动。
//
// 0.8.3 里要把一场已经录完的录音交到档案馆,只有一条路:⋯ → 分享 → 分享面板
// 里「档案馆」那一段;而且录音页上要先在开始前归过活动,才看得出有这回事。
// 负责人用了以后的原话:「以及录制后的素材，有地方可以提交给活动作为素材。」
//
// 现在有一个直说的入口「交到活动」,三处都通到同一张表:
//   - 停止以后那张卡上,「分享」后面的一颗胶囊;
//   - 录音页标签栏上,档案馆状态那一枚所在的位置(还没归过活动时是这颗胶囊,
//     归过以后是那一枚状态);
//   - 录音的 ⋯ 菜单里 —— 它自己的页面上、首页的一行上、主题里的一行上。
// 哪里出现、出现成什么,是 `CityFilingEntry` 一个函数说了算,可以单独测。
//
// 打开的那张表只有一段:分享面板里原样的「档案馆」(`CityShareSection`)——
// 选活动、交、这一场交不交音频、文字和音频各自的状态、更新、撤下,还有它那
// 几处 ⓘ(交上去的文字和音频是公开的,删不掉)。这里不另写一套,也不重复那些
// 话;分享面板里那一段照旧在。没登录城,三处入口都不出现。
//
// 这个文件不碰音频:为档案馆导出音频只在 CityAudioExport*.swift 里
// (scripts/test_share_no_audio_gate.sh)。

import SwiftUI

/// Whether a recording offers its way to the city's archive, and as what.
nonisolated enum CityFilingEntry: Equatable, Sendable {
    /// Nothing is shown.
    case none
    /// 「交到活动」: opens the archive sheet.
    case action
    /// The filing's own status — the chip in the tab bar, the word on the
    /// card after Stop. A click opens the same sheet.
    case status

    /// Where the entry would sit.
    nonisolated enum Place: Sendable {
        /// On the page itself: the card after Stop, the tab bar. This is the
        /// first layer, so a way in is offered only to someone hosting.
        case surface
        /// In a recording's ⋯ menu: the second layer, for anyone signed in.
        case menu
    }

    /// - Parameters:
    ///   - signedIn: signed in to a city. Signing in is offered on Home's
    ///     hosting row, never here.
    ///   - hostingOn: 「主持活动」 is on (`HostMode.isOn`).
    ///   - hasFiling: the recording was given an event, or is being filed
    ///     this moment.
    ///   - isRecording: the recording is still being made; where that one
    ///     goes is the recording bar's to say, and it can be filed once it
    ///     has stopped.
    static func resolve(
        place: Place,
        signedIn: Bool,
        hostingOn: Bool,
        hasFiling: Bool,
        isRecording: Bool
    ) -> CityFilingEntry {
        guard signedIn, isRecording == false else { return .none }
        switch place {
        case .menu:
            return .action
        case .surface:
            // A filing that exists is shown whatever the hosting switch
            // says: turning the switch off hides the ways in, not what is
            // already under way.
            if hasFiling { return .status }
            return hostingOn ? .action : .none
        }
    }
}

/// The sheet all three entries open: the archive block, alone.
struct CityFilingSheet: View {
    let request: RecordingShareRequest

    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        CityFilingSheetLayout(onDone: { presentationMode.wrappedValue.dismiss() }) {
            CityShareSection(request: request, standsAlone: true)
        }
    }
}

/// The sheet's frame around the archive block: the block — whose header is
/// the sheet's title, 「档案馆」 with its ⓘ and the status — and Done. A plain
/// view of what it is handed, so each state of the block can be drawn in it.
struct CityFilingSheetLayout<Block: View>: View {
    let onDone: () -> Void
    @ViewBuilder let block: () -> Block

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            block()
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                ActionPill(
                    String(localized: "common.done"),
                    systemImage: "checkmark",
                    action: onDone
                )
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("share.city.filing.done")
            }
        }
        .padding(Spacing.lg)
        .frame(width: 460)
        .background(Color.bgRoot)
        .onExitCommand(perform: onDone)
        .accessibilityIdentifier("share.city.filing")
    }
}

/// The entry on a recording's page, where the archive status sits in the
/// tab bar: the status once the recording has a filing, 「交到活动」 before
/// that for someone hosting, nothing otherwise.
struct CityFilingEntryPill: View {
    /// A state to draw instead of the live one.
    struct Shown {
        var entry: CityFilingEntry
        /// The filing's status, for `.status`.
        var status: CityFilingStatus?
    }

    let sessionId: String
    /// Opens the archive sheet for this recording.
    let onOpen: () -> Void
    var shown: Shown?

    @ObservedObject private var city = CityStore.shared
    @ObservedObject private var hostMode = HostMode.shared

    var body: some View {
        switch shown?.entry ?? CityFilingEntry.resolve(
            place: .surface,
            signedIn: city.account != nil,
            hostingOn: hostMode.isOn,
            hasFiling: city.filings[sessionId] != nil || city.busySessions.contains(sessionId),
            isRecording: false
        ) {
        case .none:
            EmptyView()
        case .status:
            CityFilingChip(sessionId: sessionId, onOpen: onOpen, shownStatus: shown?.status)
        case .action:
            ActionPill(
                String(localized: "city.filing.action"),
                systemImage: "archivebox",
                style: .quiet,
                action: onOpen
            )
            .accessibilityIdentifier("session.city.file")
            // The gap to the ⋯ beside it comes and goes with the pill.
            .padding(.trailing, Spacing.sm)
        }
    }
}

/// 「交到活动」 as a line of a recording's ⋯ menu, wherever the recording is
/// listed. Its own view, so the menus need not follow `CityStore`.
struct CityFilingMenuItem: View {
    let sessionId: String
    var isRecording = false
    /// Opens the archive sheet for this recording.
    let onOpen: () -> Void

    @ObservedObject private var city = CityStore.shared

    var body: some View {
        if CityFilingEntry.resolve(
            place: .menu,
            signedIn: city.account != nil,
            hostingOn: HostMode.shared.isOn,
            hasFiling: city.filings[sessionId] != nil,
            isRecording: isRecording
        ) == .action {
            Button(action: onOpen) {
                Label(String(localized: "city.filing.action"), systemImage: "archivebox")
            }
        }
    }
}
