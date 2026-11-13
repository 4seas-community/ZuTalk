// RecordingResultCard.swift
// 停止以后,落在这场录音页面顶上的那张卡:录好了、多长、接下来能做什么。
//
// 0.8.1 里在主窗口按「停止」,页面上没有任何一处说这场录音存下来了 —— 只有从
// 菜单栏、字幕窗、快捷键停的才有一条提示。人最常做的下一件事(把字贴走)也要
// 自己去找按钮。这张卡就摆在文字稿上面,第一个按钮是「复制全文」
// (docs/product/interface-layers.md「一屏一个主要动作」)。
//
// 卡只认一个 `RecordingResultCardModel`:说什么、摆哪些按钮都由它定,它又只由
// 几个普通的值算出来。所以每一种情况都能单独画出来、单独测,不用真的录一场、
// 存一把密钥、登录一座城。活的状态由 `DocumentEditorPage` 里的宿主视图喂进来。

import SwiftUI

/// What the card says and offers.
struct RecordingResultCardModel: Equatable {
    /// The one line under the title.
    enum Summary: Equatable {
        /// The transcript is below and the audio is kept on this Mac.
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
    /// Nil hides the row: there is nothing to refine here, or the refined
    /// transcript is already what is on screen.
    let refine: Refine?
    /// Where this recording stands with the city's archive; nil when it was
    /// never given an event.
    let city: CityFilingStatus?
    let cityEventTitle: String?

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
        cityEventTitle: String? = nil
    ) -> RecordingResultCardModel {
        RecordingResultCardModel(
            duration: RecordingPresentation.duration(ms: UInt64(max(seconds, 0)) * 1_000),
            summary: summary(liveTextOff: liveTextOff, hasText: hasText, hasAudio: hasAudio),
            refine: refine,
            city: city,
            cityEventTitle: cityEventTitle
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

    /// The archive line shows under the same condition as the chip in the
    /// tab bar: signed in, and this recording was given an event or is being
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

/// The card itself: a plain view of one model. Every button is handed in.
struct RecordingResultCard: View {
    let model: RecordingResultCardModel
    let onCopy: () -> Void
    let onExport: () -> Void
    /// The share panel; the archive line opens the same one.
    let onShare: () -> Void
    let onRefine: () -> Void
    let onOpenSettings: () -> Void
    let onShowRefined: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xsm) {
            header
            actions
            if model.refine != nil || model.city != nil {
                Divider().background(Color.borderGhost.opacity(0.4))
            }
            if let refine = model.refine {
                refineRow(refine)
            }
            if let city = model.city {
                cityLine(city)
            }
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard(
            fill: Color.bgElevated.opacity(0.45),
            cornerRadius: Radius.md,
            border: Color.borderGhost,
            borderWidth: Stroke.thin
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("recording.result.card")
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Image(systemName: Icon.connected)
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(.success)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(title)
                    .font(.titleMD)
                    .foregroundColor(.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text(summaryText)
                    .font(.body)
                    .foregroundColor(.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Spacing.sm)
            Button(action: onDismiss) {
                Image(systemName: Icon.xmark)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.textSecondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(String(localized: "common.close"))
            .accessibilityLabel(String(localized: "common.close"))
            .accessibilityIdentifier("recording.result.dismiss")
        }
    }

    /// One row when it fits; stacked when the window is narrow or the
    /// language is long.
    private var actions: some View {
        MontereyHorizontalViewThatFits {
            HStack(spacing: Spacing.sm) { actionButtons }
        } fallback: {
            VStack(alignment: .leading, spacing: Spacing.sm) { actionButtons }
        }
        .padding(.leading, Self.textInset)
    }

    @ViewBuilder
    private var actionButtons: some View {
        if model.hasText {
            ResultCardButton(
                title: String(localized: "transcript.copy_all"),
                icon: Icon.copy,
                kind: .primary,
                action: onCopy
            )
            .accessibilityIdentifier("recording.result.copy")
        }
        ResultCardButton(
            title: String(localized: "editor.export.menu"),
            kind: .secondary,
            action: onExport
        )
        .accessibilityIdentifier("recording.result.export")
        if model.hasText {
            ResultCardButton(
                title: String(localized: "session.share_link"),
                kind: .secondary,
                action: onShare
            )
            .accessibilityIdentifier("recording.result.share")
        }
    }

    private func refineRow(_ refine: RecordingResultCardModel.Refine) -> some View {
        HStack(alignment: .center, spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "refine.name"))
                    .font(.bodyMedium)
                    .foregroundColor(.textPrimary)
                Text(refineDetail(refine))
                    .font(.bodySM)
                    .foregroundColor(.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Spacing.sm)
            refineControl(refine)
        }
        .padding(.leading, Self.textInset)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("recording.result.refine")
    }

    @ViewBuilder
    private func refineControl(_ refine: RecordingResultCardModel.Refine) -> some View {
        switch refine {
        case .available:
            ResultCardButton(
                title: String(localized: "refine.action"),
                // With no text yet, refining is the thing to do next.
                kind: model.hasText ? .secondary : .primary,
                action: onRefine
            )
        case .needsSetup:
            ResultCardButton(
                title: String(localized: "recording.result.refine.open_settings"),
                kind: .secondary,
                action: onOpenSettings
            )
        case .inProgress:
            ProgressView()
                .controlSize(.small)
                .accessibilityHidden(true)
        case .ready:
            ResultCardButton(
                title: String(localized: "session.version.show_refined"),
                kind: .secondary,
                action: onShowRefined
            )
        case .failed:
            ResultCardButton(
                title: String(localized: "recording.result.refine.see_why"),
                kind: .secondary,
                action: onShowRefined
            )
        }
    }

    private func cityLine(_ status: CityFilingStatus) -> some View {
        let described = status.described(event: model.cityEventTitle)
        return Button(action: onShare) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: status.symbol)
                    .iconSizeSmall()
                    .foregroundColor(status.tone.color)
                    .accessibilityHidden(true)
                Text(described)
                    .font(.bodySM)
                    .foregroundColor(.textSecondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, Self.textInset)
        .help([described, status.reason].compactMap { $0 }.joined(separator: "\n"))
        .accessibilityLabel(Text(described))
        .accessibilityHint(Text(String(localized: "city.status.open_share_hint")))
        .accessibilityIdentifier("recording.result.city")
    }

    /// Everything under the title lines up with the title's text, past the
    /// check mark.
    private static let textInset: CGFloat = 18 + Spacing.sm

    private var title: String {
        guard let duration = model.duration else {
            return String(localized: "recording.result.title")
        }
        return String(format: String(localized: "recording.result.title_format"), duration)
    }

    private var summaryText: String {
        switch model.summary {
        case .textAndAudio: return String(localized: "recording.result.summary.text_and_audio")
        case .textOnly: return String(localized: "recording.result.summary.text_only")
        case .audioOnly: return String(localized: "recording.result.summary.audio_only")
        }
    }

    private func refineDetail(_ refine: RecordingResultCardModel.Refine) -> String {
        switch refine {
        case .available: return String(localized: "recording.result.refine.detail")
        case .needsSetup: return String(localized: "recording.result.refine.needs_setup")
        case .inProgress: return String(localized: "recording.result.refine.in_progress")
        case .ready: return String(localized: "recording.result.refine.ready")
        case .failed: return String(localized: "recording.result.refine.failed")
        }
    }
}

/// The card's buttons, drawn from the design tokens like Home's: one filled,
/// the rest outlined. A system prominent button goes grey whenever its window
/// is not the key one — which is exactly how a recording stopped from the
/// menu bar finds this card — and its white label is hard to read on the mint
/// accent of the dark appearance.
private struct ResultCardButton: View {
    enum Kind {
        case primary
        case secondary
    }

    let title: String
    var icon: String?
    let kind: Kind
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.xs + 2) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(.bodyMedium)
                    .lineLimit(1)
            }
            .foregroundColor(kind == .primary ? .brandAccentForeground : .textPrimary)
            .padding(.horizontal, Spacing.md)
            .frame(minHeight: 34)
            .background(fill)
            .overlay(
                RoundedRectangle(cornerRadius: Radius.sm)
                    .strokeBorder(border, lineWidth: Stroke.thin)
            )
            .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
            .contentShape(RoundedRectangle(cornerRadius: Radius.sm))
        }
        // A plain button keeps the system's own keyboard focus behaviour:
        // reachable with full keyboard access, never taking focus on a click.
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(Motion.microInteraction, value: isHovering)
        .accessibilityLabel(title)
    }

    private var fill: Color {
        switch kind {
        case .primary:
            return isHovering ? .brandAccentHover : .brandAccent
        case .secondary:
            return Color.bgRoot.opacity(isHovering ? 0.95 : 0.6)
        }
    }

    private var border: Color {
        switch kind {
        case .primary: return .clear
        case .secondary: return .borderActive
        }
    }
}

/// The one button that replaced the 实时版 | 精修版 switch: it names the other
/// version, the one you can go to.
enum TranscriptVersionButtonPolicy {
    /// The version the button leads to, given the one on screen; nil when
    /// what is on screen is not a transcript.
    static func destination(showing: NotebookTabDisplayType) -> NotebookTabDisplayType? {
        switch showing {
        case .asyncTranscript: return .realtimeTranscript
        case .realtimeTranscript: return .asyncTranscript
        case .manualNote: return nil
        }
    }

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
    /// version to go back to: the button would open an empty page.
    static func isOffered(showing: NotebookTabDisplayType, hasLiveVersion: Bool) -> Bool {
        switch destination(showing: showing) {
        case .realtimeTranscript: return hasLiveVersion
        case .asyncTranscript: return true
        case .manualNote, nil: return false
        }
    }
}
