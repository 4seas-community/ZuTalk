// RecordingResultCard.swift
// 停止以后,落在这场录音页面顶上的那张卡:录好了、多长、接下来能做什么。
//
// 0.8.1 里在主窗口按「停止」,页面上没有任何一处说这场录音存下来了 —— 只有从
// 菜单栏、字幕窗、快捷键停的才有一条提示。人最常做的下一件事(把字贴走)也要
// 自己去找按钮。0.8.2 在文字稿上面摆了这张卡,可是卡上有一句说明、三个按钮、
// 再加一行带解释的「精修」,还说了一句「音频留在这台 Mac」—— 这一版起音频可以
// 交到城的档案馆,那句话不再成立。
//
// 现在卡上只有两样(docs/product/interface-layers.md「界面怎么写」):标题一行
// (✓ 录好了 · 时长),和一排胶囊 —— 复制(唯一填了底色的那一颗)、导出、分享、
// 精修;在主持的人,「分享」后面多一颗「交到活动」(0.8.4:录完的素材得有地方
// 交给活动);归了活动的录音没有那一颗,这一排的末尾是档案馆的状态,一个图标加
// 一个词,点它打开的是同一张表。没有句子。精修停在哪一步,写在那颗胶囊的词、图标和颜色上,原来那句解释进了它的
// 悬停提示;要先开通的那种,点下去仍然是去设置。
//
// 卡只认一个 `RecordingResultCardModel`:说什么、摆哪些胶囊都由它定,它又只由
// 几个普通的值算出来。所以每一种情况都能单独画出来、单独测,不用真的录一场、
// 存一把密钥、登录一座城。活的状态由 `DocumentEditorPage` 里的宿主视图喂进来。

import SwiftUI

/// What the card says and offers.
struct RecordingResultCardModel: Equatable {
    /// What the recording ended up with. Nothing on the card says it in a
    /// sentence; it decides which pills there are, and what the title and
    /// the refine pill explain on hover.
    enum Summary: Equatable {
        /// There is a transcript, and there is audio.
        case textAndAudio
        /// The transcript is below; the audio is already gone, as this
        /// recording's own retention setting asked.
        case textOnly
        /// Only audio so far: live text was off, or none arrived.
        case audioOnly
    }

    /// Where refining stands. Each case has exactly one thing to press, or
    /// says plainly that there is nothing to press yet.
    enum Refine: Equatable {
        /// Can be started now.
        case available
        /// Has to be set up in Settings first (it runs on the person's own
        /// key today).
        case needsSetup
        /// On its way.
        case inProgress
        /// Done, and not the version on screen.
        case ready
        /// Tried and did not work; the refined view says why.
        case failed
    }

    /// "12 min" — nil for a recording too short to have a length worth saying.
    let duration: String?
    let summary: Summary
    /// Nil leaves the pill out: there is nothing to refine here, or the
    /// refined transcript is already what is on screen.
    let refine: Refine?
    /// Where this recording stands with the city's archive; nil when it was
    /// never given an event.
    let city: CityFilingStatus?
    let cityEventTitle: String?
    /// 「交到活动」 is offered: signed in, hosting, and not given an event yet
    /// (`CityFilingEntry`).
    var offersFiling = false

    /// Copying and sharing are about the text; with none yet they would do
    /// nothing, so they are not offered.
    var hasText: Bool { summary != .audioOnly }
}

extension RecordingResultCardModel {
    static func make(
        seconds: Int,
        liveTextOff: Bool,
        hasText: Bool?,
        hasAudio: Bool,
        refine: Refine?,
        city: CityFilingStatus? = nil,
        cityEventTitle: String? = nil,
        offersFiling: Bool = false
    ) -> RecordingResultCardModel {
        RecordingResultCardModel(
            duration: RecordingPresentation.duration(ms: UInt64(max(seconds, 0)) * 1_000),
            summary: summary(liveTextOff: liveTextOff, hasText: hasText, hasAudio: hasAudio),
            refine: refine,
            city: city,
            cityEventTitle: cityEventTitle,
            // Never both: a recording with a filing shows its status.
            offersFiling: offersFiling && city == nil
        )
    }

    /// - Parameter hasText: whether any transcript exists, once the page has
    ///   read it. Until then the recording's own setting is the best answer:
    ///   one made with live text off has none.
    static func summary(liveTextOff: Bool, hasText: Bool?, hasAudio: Bool) -> Summary {
        guard hasText ?? (liveTextOff == false) else { return .audioOnly }
        return hasAudio ? .textAndAudio : .textOnly
    }

    /// - Parameters:
    ///   - task: the newest refine of this recording in the task queue, as a
    ///     tab status; nil when none was ever asked for.
    ///   - hasRefinedText: a refined transcript exists.
    ///   - isRequesting: a request made from this page has not answered yet.
    ///   - showingRefined: the refined transcript is the one on screen, where
    ///     its own status bar already says how it went.
    static func refine(
        task: NotebookTabStatus?,
        hasRefinedText: Bool,
        isRequesting: Bool,
        showingRefined: Bool,
        hasAudio: Bool,
        hasReadyPersonalKey: Bool,
        recordedOn: String? = nil
    ) -> Refine? {
        if hasRefinedText { return showingRefined ? nil : .ready }
        if isRequesting { return .inProgress }
        switch task {
        case .failed:
            return showingRefined ? nil : .failed
        case .ready, .live:
            // Finished with nothing to show yet: the refined view explains.
            return showingRefined ? nil : .ready
        case .pending, nil:
            // Refining reads the audio; with none on this Mac there is
            // nothing to offer.
            guard task == .pending || hasAudio else { return nil }
            // Whether it can start, or waits for a key, is the same rule the
            // refined view's own button follows.
            switch AsyncTranscriptActionPolicy.primaryAction(
                projectionState: NotebookAsyncProjectionState.none,
                providerState: task == .pending ? "pending" : nil,
                hasReadyPersonalKey: hasReadyPersonalKey,
                recordedOn: recordedOn
            ) {
            case .start: return .available
            case .addPersonalKey: return .needsSetup
            case .audioElsewhere: return nil
            case .none: return task == .pending ? .inProgress : nil
            }
        }
    }

    /// The archive status shows under the same condition as the chip in
    /// the tab bar: signed in, and this recording was given an event or is being
    /// filed right now.
    static func city(
        signedIn: Bool,
        filing: FfiCityFiling?,
        busy: Bool,
        offline: Bool,
        signer: String? = nil
    ) -> CityFilingStatus? {
        guard signedIn, filing != nil || busy else { return nil }
        return CityFilingStatus.resolve(filing, busy: busy, offline: offline, signer: signer)
    }
}

/// How the refine pill looks and what pressing it does, for each place
/// refining can stand. Keys rather than words, so the rule can be checked
/// whatever language the test machine speaks.
struct RefinePillFace: Equatable {
    enum Press: Equatable {
        case refine
        case openSettings
        case showRefined
        /// On its way: nothing to press.
        case nothing
    }

    let titleKey: String
    let systemImage: String
    let tone: PillTone
    let mark: PillMark
    /// The sentence that used to be printed beside the button.
    let helpKeys: [String]
    let press: Press
    /// With no text yet, refining is the thing to do next: it takes the
    /// filled look that Copy would have had.
    let isPrimary: Bool

    static func resolve(_ refine: RecordingResultCardModel.Refine, hasText: Bool) -> RefinePillFace {
        switch refine {
        case .available:
            return RefinePillFace(
                titleKey: "refine.action",
                systemImage: "wand.and.stars",
                tone: .normal,
                mark: .none,
                helpKeys: hasText
                    ? ["recording.result.refine.detail"]
                    : ["recording.result.summary.audio_only", "recording.result.refine.detail"],
                press: .refine,
                isPrimary: hasText == false
            )
        case .needsSetup:
            return RefinePillFace(
                titleKey: "refine.action",
                systemImage: "wand.and.stars",
                tone: .dimmed,
                mark: .warning,
                helpKeys: ["recording.result.refine.needs_setup"],
                press: .openSettings,
                isPrimary: false
            )
        case .inProgress:
            return RefinePillFace(
                titleKey: "editor.transcript.async.pending_title",
                systemImage: "hourglass",
                tone: .normal,
                mark: .none,
                helpKeys: ["recording.result.refine.in_progress"],
                press: .nothing,
                isPrimary: false
            )
        case .ready:
            return RefinePillFace(
                titleKey: "resources.async",
                systemImage: "checkmark.circle",
                tone: .on,
                mark: .none,
                helpKeys: ["recording.result.refine.ready"],
                press: .showRefined,
                isPrimary: false
            )
        case .failed:
            return RefinePillFace(
                titleKey: "editor.transcript.async.failed_title",
                systemImage: "exclamationmark.triangle",
                tone: .warning,
                mark: .none,
                helpKeys: ["recording.result.refine.failed", "recording.result.refine.see_why"],
                press: .showRefined,
                isPrimary: false
            )
        }
    }

    var title: String { String(localized: String.LocalizationValue(titleKey)) }

    var help: String {
        helpKeys
            .map { String(localized: String.LocalizationValue($0)) }
            .joined(separator: "\n")
    }
}

/// The card itself: a plain view of one model. Every action is handed in.
struct RecordingResultCard: View {
    let model: RecordingResultCardModel
    let onCopy: () -> Void
    let onExport: () -> Void
    let onShare: () -> Void
    /// The archive sheet: 「交到活动」, and the archive status once there is
    /// a filing.
    var onFile: () -> Void = {}
    let onRefine: () -> Void
    let onOpenSettings: () -> Void
    let onShowRefined: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xsm) {
            header
            PillStrip {
                pills
            } trailing: {
                if let city = model.city {
                    cityStatus(city)
                }
            }
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard(
            fill: Color.bgElevated.opacity(0.4),
            cornerRadius: Radius.md,
            border: Color.borderSubtle,
            borderWidth: Stroke.hairline
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("recording.result.card")
    }

    private var header: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: Icon.connected)
                .font(.titleMD)
                .foregroundColor(.success)
                .accessibilityHidden(true)
            Text(title)
                .font(.titleMD)
                .foregroundColor(.textPrimary)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
                // What the recording ended up with, for whoever asks.
                .pillExplained(help: summaryText)
            Spacer(minLength: Spacing.sm)
            Button(action: onDismiss) {
                Image(systemName: Icon.xmark)
                    .font(PillMetrics.markFont)
                    .foregroundColor(.textSecondary)
                    .frame(width: PillMetrics.segmentWidth, height: PillMetrics.segmentWidth)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(String(localized: "common.close"))
            .accessibilityLabel(String(localized: "common.close"))
            .accessibilityIdentifier("recording.result.dismiss")
        }
    }

    /// Copy first and filled: it is what most people came to do. With no
    /// text there is nothing to copy or share, and refining takes its place.
    @ViewBuilder
    private var pills: some View {
        if model.hasText {
            PrimaryPill(
                String(localized: "recording.word.copy"),
                systemImage: Icon.copy,
                help: String(localized: "transcript.copy_all"),
                action: onCopy
            )
            .accessibilityIdentifier("recording.result.copy")
        }
        ActionPill(
            String(localized: "common.export.action"),
            systemImage: "tray.and.arrow.up",
            action: onExport
        )
        .accessibilityIdentifier("recording.result.export")
        if model.hasText {
            ActionPill(
                String(localized: "recording.word.share"),
                systemImage: Icon.export,
                help: String(localized: "session.share_link"),
                action: onShare
            )
            .accessibilityIdentifier("recording.result.share")
        }
        if model.offersFiling {
            ActionPill(
                String(localized: "city.filing.action"),
                systemImage: "archivebox",
                action: onFile
            )
            .accessibilityIdentifier("recording.result.file")
        }
        if let refine = model.refine {
            refinePill(RefinePillFace.resolve(refine, hasText: model.hasText))
                .accessibilityIdentifier("recording.result.refine")
        }
    }

    @ViewBuilder
    private func refinePill(_ face: RefinePillFace) -> some View {
        if face.isPrimary {
            PrimaryPill(face.title, systemImage: face.systemImage, help: face.help) {
                press(face.press)
            }
        } else {
            ActionPill(
                face.title,
                systemImage: face.systemImage,
                tone: face.tone,
                mark: face.mark,
                help: face.help,
                accessibilityLabel: String(localized: "refine.name"),
                accessibilityValue: face.title
            ) {
                press(face.press)
            }
            .disabled(face.press == .nothing)
        }
    }

    private func press(_ press: RefinePillFace.Press) {
        switch press {
        case .refine: onRefine()
        case .openSettings: onOpenSettings()
        case .showRefined: onShowRefined()
        case .nothing: break
        }
    }

    /// Where this recording stands with the city's archive: an icon and a
    /// word at the far end of the strip — the same word the tab bar's chip,
    /// the lists and Settings use (`CityFilingStatus.label`). The sentence,
    /// the event and the reason are the tooltip; a click opens the archive
    /// sheet, where filing is done.
    private func cityStatus(_ status: CityFilingStatus) -> some View {
        ActionPill(
            status.label,
            systemImage: status.symbol,
            style: .quiet,
            iconTint: status.tone.color,
            help: status.tooltip(event: model.cityEventTitle),
            accessibilityLabel: status.described(event: model.cityEventTitle),
            action: onFile
        )
        .accessibilityHint(Text(String(localized: "city.filing.open_hint")))
        .accessibilityIdentifier("recording.result.city")
    }

    private var title: String {
        guard let duration = model.duration else {
            return String(localized: "recording.result.title")
        }
        return String(format: String(localized: "recording.result.title_format"), duration)
    }

    /// Not printed: the title's tooltip. A recording with both text and
    /// audio has nothing to add to "Recorded".
    private var summaryText: String? {
        switch model.summary {
        case .textAndAudio: return nil
        case .textOnly: return String(localized: "recording.result.summary.text_only")
        case .audioOnly: return String(localized: "recording.result.summary.audio_only")
        }
    }
}

/// Which transcript is on screen, and the other one a recording may have.
///
/// 0.8.1 had a 实时版 | 精修版 switch; 0.8.2 one quiet button naming the
/// version you could go to. It is now a pill that shows the version on
/// screen — a control showing its value, like every other pill — and its menu
/// lists both, the one on screen ticked.
enum TranscriptVersionButtonPolicy {
    /// The version the pill leads to, given the one on screen; nil when
    /// what is on screen is not a transcript.
    static func destination(showing: NotebookTabDisplayType) -> NotebookTabDisplayType? {
        switch showing {
        case .asyncTranscript: return .realtimeTranscript
        case .realtimeTranscript: return .asyncTranscript
        case .manualNote: return nil
        }
    }

    /// The name of a version: what the pill shows for the one on screen,
    /// and what its menu calls each.
    static func titleKey(_ version: NotebookTabDisplayType) -> String? {
        switch version {
        case .realtimeTranscript: return "resources.realtime"
        case .asyncTranscript: return "resources.async"
        case .manualNote: return nil
        }
    }

    static func title(_ version: NotebookTabDisplayType) -> String? {
        titleKey(version).map { String(localized: String.LocalizationValue($0)) }
    }

    /// What the pill says on hover: where a click on the other version goes.
    static func labelKey(showing: NotebookTabDisplayType) -> String? {
        switch destination(showing: showing) {
        case .realtimeTranscript: return "session.version.show_live"
        case .asyncTranscript: return "session.version.show_refined"
        case .manualNote, nil: return nil
        }
    }

    static func label(showing: NotebookTabDisplayType) -> String? {
        labelKey(showing: showing).map { String(localized: String.LocalizationValue($0)) }
    }

    /// A recording that never had live text (an imported file) has no other
    /// version to go back to: the pill would open an empty page.
    static func isOffered(showing: NotebookTabDisplayType, hasLiveVersion: Bool) -> Bool {
        switch destination(showing: showing) {
        case .realtimeTranscript: return hasLiveVersion
        case .asyncTranscript: return true
        case .manualNote, nil: return false
        }
    }
}
