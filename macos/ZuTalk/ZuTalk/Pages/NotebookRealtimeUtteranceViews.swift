import AppKit
import Combine
import SwiftUI

/// One durable run section inside the Notebook history. It never queries by
/// session id and never changes the run's frozen processing configuration.
struct NotebookRealtimeUtteranceView: View {
    let run: NotebookCaptureHistoryRunDTO
    /// Already merged once by the active-run boundary. Keeping the complete
    /// array as an input prevents this view's header, empty state, cue overlay,
    /// and row bodies from each rebuilding the full durable+preview session.
    let presentedUtterances: [NotebookCaptureUtteranceDTO]
    let liveTranslationCues: [NotebookCaptureTranslationCueDTO]
    let presentationMode: NotebookTranscriptPresentationMode
    let isFocused: Bool
    /// Run-level editing gate, above the per-lane projection watermark. The
    /// active run closes it while a terminal transition holds the session.
    let isLaneEditingEnabled: Bool
    /// A lane edit must reach the store that owns the rows on screen. The
    /// active run's utterances come from the capture overlay and `history.runs`
    /// deliberately keeps none for it, so routing every commit at the history
    /// store made a live edit fail the very gate this view had just opened.
    let replaceLane: (String, String, String) async throws -> Void
    @ObservedObject var history: NotebookCaptureHistoryStore
    @State private var laneEditingState = BilingualLaneEditingState()
    @State private var speakerSelection: NotebookSpeakerSelection?

    var body: some View {
        VStack(spacing: 0) {
            runHeader
            Divider().background(Color.borderGhost.opacity(0.3))
            switch projectionLayout {
            case .bilingualColumns:
                bilingualLayout
            case .transcriptionTimeline:
                transcriptionOnlyLayout
            case .snapshotUnavailable:
                snapshotUnavailablePlaceholder
            }
        }
        .background(Color.bgSunken.opacity(0.28))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.sm)
                .strokeBorder(
                    isFocused ? Color.brandAccent.opacity(0.72) : Color.borderGhost.opacity(0.28),
                    lineWidth: isFocused ? 1 : 0.5
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(String(localized: "capture.transcript.realtime_accessibility_label")))
        .sheet(item: $speakerSelection) { selection in
            NotebookSpeakerEditorSheet(
                sessionId: run.sessionId,
                sessionSpeakerId: selection.id,
                history: history,
                onClose: { speakerSelection = nil }
            )
        }
    }

    private var projectionLayout: NotebookRealtimeProjectionLayout {
        NotebookRealtimeProjectionPolicy.layout(
            presentation: presentationMode,
            run: run
        )
    }

    private var bilingualLayout: some View {
        Group {
            if NotebookRealtimeTranscriptLayout.usesHorizontalScroll(
                languageCount: displayLanguages.count
            ) {
                ScrollView(.horizontal) {
                    languageColumnContent
                        .frame(minWidth: NotebookRealtimeTranscriptLayout.minimumContentWidth(
                            languageCount: displayLanguages.count
                        ))
                }
                .montereyScrollIndicators(true)
            } else {
                languageColumnContent
            }
        }
    }

    private var languageColumnContent: some View {
        bilingualBody
    }

    private var transcriptionOnlyLayout: some View {
        VStack(spacing: 0) {
            transcriptionHeader
            Divider().background(Color.borderGhost.opacity(0.35))
            transcriptionBody
        }
    }

    private var displayLanguages: [String] {
        NotebookCaptureHistoryPolicy.displayLanguages(for: run) ?? []
    }

    private var supplementalCues: [String: NotebookCaptureTranslationCueDTO] {
        guard run.captureState.isActive else { return [:] }
        return NotebookLanguageColumnCueOverlay.latestSupplementalCues(
            languages: displayLanguages,
            utterances: presentedUtterances,
            cues: liveTranslationCues
        )
    }

    private var hasAnyEditableLane: Bool {
        guard isLaneEditingEnabled else { return false }
        return presentedUtterances.contains { utterance in
            utterance.isLoroEditableLane(
                language: utterance.sourceLanguage,
                appliedRevision: run.realtimeLoroAppliedRevision
            ) || utterance.languageVariants.contains { variant in
                utterance.isLoroEditableLane(
                    language: variant.language,
                    appliedRevision: run.realtimeLoroAppliedRevision
                )
            }
        }
    }

    private var runHeader: some View {
        MontereyHorizontalViewThatFits {
            HStack(spacing: Spacing.md) {
                runIdentity
                Spacer(minLength: Spacing.md)
                runMetadata
                captureStateLabel
                statusActions
            }
        } fallback: {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                runIdentity
                HStack(spacing: Spacing.md) {
                    runMetadata
                    Spacer(minLength: Spacing.sm)
                    captureStateLabel
                    statusActions
                }
            }
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.sm)
        .frame(minHeight: 52)
    }

    private var runIdentity: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(createdAtText, systemImage: "clock")
                .font(.captionMedium)
                .foregroundColor(.textPrimary)
            Text(String(run.sessionId.prefix(12)))
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.textTertiary)
                .textSelection(.enabled)
        }
    }

    private var runMetadata: some View {
        Label(durationText, systemImage: run.hasAudio ? "waveform" : "waveform.slash")
            .font(.caption)
            .foregroundColor(.textSecondary)
            .accessibilityLabel(Text(
                "\(String(localized: "session.tab.audio")), \(durationText)"
            ))
    }

    private var snapshotUnavailablePlaceholder: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Label(
                String(localized: "capture.error.profile_snapshot_unavailable"),
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.captionMedium)
            .foregroundColor(.signalAmber)
            Text(String(localized: "capture.transcript.snapshot_unavailable_detail"))
                .font(.caption)
                .foregroundColor(.textSecondary)
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var transcriptionHeader: some View {
        Label(
            String(localized: "capture.transcript.transcription_heading"),
            systemImage: "text.alignleft"
        )
        .font(.captionMedium)
        .foregroundColor(.textPrimary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, NotebookRealtimeTranscriptLayout.horizontalInset + Spacing.md)
        .frame(height: NotebookRealtimeTranscriptLayout.headerHeight)
        .accessibilityAddTraits(.isHeader)
    }

    private var captureStateLabel: some View {
        CaptureStateLabel(
            captureState: run.captureState,
            remoteHealth: run.remoteHealth,
            projectionState: run.projectionState,
            showsRemoteHealthWhenInactive: false
        )
    }

    @ViewBuilder
    private var statusActions: some View {
        Button(action: copyTranscript) {
            Label(
                String(localized: "capture.transcript.copy"),
                systemImage: Icon.copy
            )
        }
        .buttonStyle(.borderless)
        .frame(minWidth: 44, minHeight: 44)
        .disabled(canCopyTranscript == false)
        .help(copyTranscriptHint)
        .accessibilityLabel(Text(String(localized: "capture.transcript.copy")))
        .accessibilityHint(Text(copyTranscriptHint))

        if hasAnyEditableLane == false {
            Label(String(localized: "capture.transcript.read_only"), systemImage: "lock.fill")
                .font(.caption)
                .foregroundColor(.textSecondary)
        }
        if run.projectionState == .failed, run.captureState.isActive == false {
            Button(String(localized: "capture.transcript.retry_projection")) {
                do {
                    try history.retryProjection(sessionId: run.sessionId)
                } catch {
                    ToastCenter.shared.error(
                        String(localized: "capture.toast.projection_retry_failed"),
                        detail: error.localizedDescription
                    )
                }
            }
            .buttonStyle(.borderless)
            .accessibilityHint(Text(String(localized: "capture.transcript.retry_projection_hint")))
        }
    }

    private var canCopyTranscript: Bool {
        run.utterances.isEmpty == false && laneEditingState.canSwap
    }

    private var copyTranscriptHint: String {
        if run.utterances.isEmpty {
            return String(localized: "capture.transcript.copy_empty_hint")
        }
        if laneEditingState.canSwap == false {
            return String(localized: "capture.transcript.copy_finish_edit_hint")
        }
        return String(localized: "capture.transcript.copy_hint")
    }

    private func copyTranscript() {
        guard canCopyTranscript else { return }
        guard let core = CoreClient.shared.core else {
            ToastCenter.shared.error(
                String(localized: "capture.transcript.copy_failed"),
                detail: String(localized: "capture.route.unavailable_detail")
            )
            return
        }

        do {
            let text = try core.getSessionTranscriptClipboardText(
                sessionId: run.sessionId
            )
            guard TranscriptClipboard.write(text) else {
                ToastCenter.shared.error(
                    String(localized: "capture.transcript.copy_failed"),
                    detail: String(localized: "capture.transcript.copy_clipboard_failed")
                )
                return
            }
            ToastCenter.shared.success(
                String(localized: "capture.transcript.copy_success"),
                detail: run.captureState.isActive
                    ? String(localized: "capture.transcript.copy_success_live_detail")
                    : String(localized: "capture.transcript.copy_success_detail")
            )
        } catch {
            ToastCenter.shared.error(
                String(localized: "capture.transcript.copy_failed"),
                detail: error.localizedDescription
            )
        }
    }

    @ViewBuilder
    private var bilingualBody: some View {
        let supplementalCues = supplementalCues
        if presentedUtterances.isEmpty, supplementalCues.isEmpty {
            compactEmptyRun(
                title: run.captureState.isActive
                    ? String(localized: "capture.transcript.waiting_title")
                    : String(localized: "editor.transcript.realtime.empty_title"),
                description: run.captureState.isActive
                    ? String(localized: "capture.transcript.waiting_detail")
                    : String(localized: "editor.transcript.realtime.empty_desc")
            )
        } else {
            let gapAnchors = anchoredTranscriptGaps
            LazyVStack(spacing: 0) {
                ForEach(presentedUtterances) { utterance in
                    transcriptGapDividers(gapAnchors.leading[utterance.id])
                    MultilingualUtteranceRow(
                        utterance: utterance,
                        projection: NotebookCaptureHistoryPolicy.laneProjection(
                            for: utterance,
                            selectedLanguages: displayLanguages,
                            commonCaptionLanguage: nil
                        ),
                        speakerDisplayName: speakerDisplayName(for: utterance),
                        onManageSpeaker: { selectSpeaker(for: utterance) },
                        isLaneEditingEnabled: isLaneEditingEnabled,
                        realtimeLoroAppliedRevision: run.realtimeLoroAppliedRevision,
                        onReplace: { language, text in
                            try await replaceLane(utterance.id, language, text)
                        },
                        onEditingChanged: { target, focused in
                            updateLaneEditingState(target, focused: focused)
                        }
                    )
                    .id(utterance.id)
                    Divider().background(Color.borderGhost.opacity(0.22))
                }
                if supplementalCues.isEmpty == false {
                    NotebookSupplementalCueRow(
                        languages: displayLanguages,
                        cues: supplementalCues
                    )
                    .transition(.opacity)
                    Divider().background(Color.borderGhost.opacity(0.22))
                }
                transcriptGapDividers(gapAnchors.trailing)
            }
            .padding(.horizontal, NotebookRealtimeTranscriptLayout.horizontalInset)
        }
    }

    @ViewBuilder
    private var transcriptionBody: some View {
        let sourceTimelineUtterances = presentedUtterances.filter(\.hasSourceLane)
        if sourceTimelineUtterances.isEmpty {
            compactEmptyRun(
                title: run.captureState.isActive
                    ? String(localized: "capture.transcript.waiting_title")
                    : String(localized: "capture.transcript.transcription_empty_title"),
                description: run.captureState.isActive
                    ? String(localized: "capture.transcript.waiting_detail")
                    : String(localized: "capture.transcript.transcription_empty_detail")
            )
        } else {
            let gapAnchors = NotebookTranscriptGapPresentation.anchoredGaps(
                utterances: sourceTimelineUtterances,
                gaps: history.transcriptGaps(sessionId: run.sessionId)
            )
            LazyVStack(spacing: 0) {
                ForEach(sourceTimelineUtterances) { utterance in
                    transcriptGapDividers(gapAnchors.leading[utterance.id])
                    TranscriptionUtteranceRow(
                        utterance: utterance,
                        speakerDisplayName: speakerDisplayName(for: utterance),
                        onManageSpeaker: { selectSpeaker(for: utterance) },
                        isEditable: isLaneEditingEnabled && utterance.isLoroEditableLane(
                            language: utterance.sourceLanguage,
                            appliedRevision: run.realtimeLoroAppliedRevision
                        ),
                        onReplace: { language, text in
                            try await replaceLane(utterance.id, language, text)
                        },
                        onEditingChanged: { target, focused in
                            updateLaneEditingState(target, focused: focused)
                        }
                    )
                    .id(utterance.id)
                    Divider().background(Color.borderGhost.opacity(0.22))
                }
                transcriptGapDividers(gapAnchors.trailing)
            }
            .padding(.horizontal, NotebookRealtimeTranscriptLayout.horizontalInset)
        }
    }

    private var anchoredTranscriptGaps: (
        leading: [String: [NotebookTranscriptGapDTO]],
        trailing: [NotebookTranscriptGapDTO]
    ) {
        NotebookTranscriptGapPresentation.anchoredGaps(
            utterances: presentedUtterances,
            gaps: history.transcriptGaps(sessionId: run.sessionId)
        )
    }

    @ViewBuilder
    private func transcriptGapDividers(_ gaps: [NotebookTranscriptGapDTO]?) -> some View {
        if let gaps {
            ForEach(gaps) { gap in
                NotebookTranscriptGapDivider(gap: gap)
            }
        }
    }

    private func compactEmptyRun(title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            Image(systemName: "waveform.slash")
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(.textTertiary)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(title)
                    .font(.captionMedium)
                    .foregroundColor(.textPrimary)
                Text(description)
                    .font(.caption)
                    .foregroundColor(.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var createdAtText: String {
        NotebookRealtimeRunPresentation.createdAtText(for: run)
    }

    private var durationText: String {
        NotebookRealtimeRunPresentation.durationText(for: run)
    }

    private func updateLaneEditingState(
        _ target: BilingualLaneEditTarget,
        focused: Bool
    ) {
        guard laneEditingState.isFocused(target) != focused else { return }
        laneEditingState.setFocused(target, focused: focused)
    }

    private func speakerDisplayName(
        for utterance: NotebookCaptureUtteranceDTO
    ) -> String? {
        history.speakerDisplayName(
            sessionSpeakerId: utterance.sessionSpeakerId,
            sessionId: run.sessionId
        )
    }

    private func selectSpeaker(for utterance: NotebookCaptureUtteranceDTO) {
        guard let sessionSpeakerId = utterance.sessionSpeakerId else { return }
        history.refreshSessionSpeakers(sessionId: run.sessionId)
        speakerSelection = NotebookSpeakerSelection(id: sessionSpeakerId)
    }
}

private struct NotebookSpeakerSelection: Identifiable {
    let id: String
}

private struct NotebookSpeakerChip: View {
    let displayName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(displayName, systemImage: "person.crop.circle")
                .font(.captionMedium)
                .foregroundColor(.textPrimary)
                .padding(.horizontal, Spacing.sm)
                .frame(minHeight: 28)
                .background(Color.bgElevated.opacity(0.48))
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(Color.borderGhost.opacity(0.35), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .contentShape(Capsule())
        .help(String(localized: "capture.speaker.manage"))
        .accessibilityLabel(Text(String(
            format: String(localized: "capture.speaker.chip_accessibility_format"),
            displayName
        )))
        .accessibilityHint(Text(String(localized: "capture.speaker.manage_hint")))
    }
}

private struct NotebookSpeakerEditorSheet: View {
    let sessionId: String
    let sessionSpeakerId: String
    @ObservedObject var history: NotebookCaptureHistoryStore
    let onClose: () -> Void
    @State private var sessionName = ""
    @State private var selectedParticipantId = ""
    @State private var newParticipantName = ""
    @State private var errorMessage: String?

    private var speaker: NotebookSessionSpeakerDTO? {
        history.sessionSpeaker(id: sessionSpeakerId, sessionId: sessionId)
    }

    private var sessionNameIsEmpty: Bool {
        sessionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var newParticipantNameIsEmpty: Bool {
        newParticipantName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(String(localized: "capture.speaker.editor.title"))
                        .font(.title3.weight(.semibold))
                        .foregroundColor(.textPrimary)
                    Text(speakerIdentity)
                        .font(.caption.monospaced())
                        .foregroundColor(.textSecondary)
                        .textSelection(.enabled)
                }
                Spacer(minLength: Spacing.lg)
                Button(String(localized: "capture.speaker.close")) {
                    onClose()
                }
                .keyboardShortcut(.cancelAction)
            }

            Label(
                String(localized: "capture.speaker.privacy_detail"),
                systemImage: "lock.shield"
            )
            .font(.caption)
            .foregroundColor(.textSecondary)
            .fixedSize(horizontal: false, vertical: true)

            Divider()

            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text(String(localized: "capture.speaker.session_name"))
                    .font(.captionMedium)
                    .foregroundColor(.textPrimary)
                Text(String(localized: "capture.speaker.session_name_detail"))
                    .font(.caption)
                    .foregroundColor(.textSecondary)
                HStack(spacing: Spacing.sm) {
                    TextField(
                        String(localized: "capture.speaker.session_name_placeholder"),
                        text: $sessionName
                    )
                    .textFieldStyle(.roundedBorder)
                    Button(String(localized: "capture.speaker.save")) {
                        saveSessionName()
                    }
                    .disabled(sessionNameIsEmpty)
                    Button(String(localized: "capture.speaker.clear")) {
                        clearSessionName()
                    }
                    .disabled(speaker?.localDisplayName == nil)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text(String(localized: "capture.speaker.participant"))
                    .font(.captionMedium)
                    .foregroundColor(.textPrimary)
                Text(String(localized: "capture.speaker.participant_detail"))
                    .font(.caption)
                    .foregroundColor(.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: Spacing.sm) {
                    Picker(
                        String(localized: "capture.speaker.participant"),
                        selection: $selectedParticipantId
                    ) {
                        Text(String(localized: "capture.speaker.select_participant")).tag("")
                        ForEach(history.orderedSpeakerParticipants) { participant in
                            Text(participant.displayName).tag(participant.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity)

                    Button(String(localized: "capture.speaker.link")) {
                        linkSelectedParticipant()
                    }
                    .disabled(selectedParticipantId.isEmpty)
                }

                HStack(spacing: Spacing.sm) {
                    TextField(
                        String(localized: "capture.speaker.new_participant_placeholder"),
                        text: $newParticipantName
                    )
                    .textFieldStyle(.roundedBorder)
                    Button(String(localized: "capture.speaker.create_and_link")) {
                        createAndLinkParticipant()
                    }
                    .disabled(newParticipantNameIsEmpty)
                }

                if speaker?.participantId != nil {
                    Button(String(localized: "capture.speaker.unlink")) {
                        unlinkParticipant()
                    }
                    .buttonStyle(.borderless)
                }
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.signalRed)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Spacing.xl)
        .frame(width: 480)
        .background(Color.bgRoot)
        .onAppear {
            history.refreshSpeakerParticipants()
            history.refreshSessionSpeakers(sessionId: sessionId)
            synchronizeDrafts()
        }
    }

    private var speakerIdentity: String {
        guard let speaker else {
            return String(localized: "capture.speaker.fallback")
        }
        return String(
            format: String(localized: "capture.speaker.identity_format"),
            speaker.provider,
            speaker.providerLabel,
            String(speaker.providerSessionEpoch)
        )
    }

    private func synchronizeDrafts() {
        sessionName = speaker?.localDisplayName ?? ""
        selectedParticipantId = speaker?.participantId ?? ""
    }

    private func saveSessionName() {
        perform {
            let updated = try history.renameSessionSpeaker(
                sessionSpeakerId: sessionSpeakerId,
                localDisplayName: sessionName
            )
            sessionName = updated.localDisplayName ?? ""
        }
    }

    private func clearSessionName() {
        perform {
            let updated = try history.renameSessionSpeaker(
                sessionSpeakerId: sessionSpeakerId,
                localDisplayName: nil
            )
            sessionName = updated.localDisplayName ?? ""
        }
    }

    private func linkSelectedParticipant() {
        perform {
            let updated = try history.linkSessionSpeaker(
                sessionSpeakerId: sessionSpeakerId,
                participantId: selectedParticipantId
            )
            selectedParticipantId = updated.participantId ?? ""
        }
    }

    private func createAndLinkParticipant() {
        perform {
            let updated = try history.createParticipantAndLink(
                displayName: newParticipantName,
                sessionSpeakerId: sessionSpeakerId
            )
            newParticipantName = ""
            selectedParticipantId = updated.participantId ?? ""
        }
    }

    private func unlinkParticipant() {
        perform {
            let updated = try history.unlinkSessionSpeaker(
                sessionSpeakerId: sessionSpeakerId
            )
            selectedParticipantId = updated.participantId ?? ""
        }
    }

    private func perform(_ operation: () throws -> Void) {
        do {
            try operation()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Read-only live tail for auxiliary text that is visible in the subtitle
/// timeline but has not acquired a durable row identity yet. It deliberately
/// has no editor affordance: editing before binding would invent an
/// `(utterance, language)` target that does not exist.
private struct NotebookSupplementalCueRow: View {
    let languages: [String]
    let cues: [String: NotebookCaptureTranslationCueDTO]

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(languages.enumerated()), id: \.element) { index, language in
                Group {
                    if let cue = cue(for: language) {
                        Text(cue.text)
                            .font(.bodyMedium)
                            .foregroundColor(.textPrimary)
                            .textSelection(.enabled)
                            .multilineTextAlignment(.leading)
                            .accessibilityLabel(Text(language.uppercased()))
                    } else {
                        Color.clear
                            .accessibilityHidden(true)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 52, alignment: .topLeading)
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.md)

                if index < languages.count - 1 {
                    Divider().background(Color.borderGhost.opacity(0.35))
                }
            }
        }
        .background(Color.brandAccent.opacity(0.035))
        .accessibilityElement(children: .contain)
    }

    private func cue(for language: String) -> NotebookCaptureTranslationCueDTO? {
        let key = language
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(separator: "-")
            .first
            .map(String.init) ?? ""
        return cues[key]
    }
}

private struct TranscriptionUtteranceRow: View {
    let utterance: NotebookCaptureUtteranceDTO
    let speakerDisplayName: String?
    let onManageSpeaker: () -> Void
    let isEditable: Bool
    let onReplace: (String, String) async throws -> Void
    let onEditingChanged: (BilingualLaneEditTarget, Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
                if let speakerDisplayName {
                    NotebookSpeakerChip(
                        displayName: speakerDisplayName,
                        action: onManageSpeaker
                    )
                }
                if let timestampText {
                    Label(timestampText, systemImage: "waveform")
                        .accessibilityLabel(Text(String(
                            format: String(localized: "capture.transcript.source_timestamp"),
                            timestampText
                        )))
                }
                Text(sourceLanguageLabel)
            }
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundColor(.textTertiary)

            BilingualLaneText(
                target: BilingualLaneEditTarget(
                    utteranceId: utterance.id,
                    laneLanguage: normalizedSourceLanguage
                ),
                text: utterance.sourceText,
                isEditable: isEditable,
                onCommit: { target, text in
                    try await onReplace(target.laneLanguage, text)
                },
                onEditingChanged: onEditingChanged
            )
            .id(BilingualLaneEditTarget(
                utteranceId: utterance.id,
                laneLanguage: normalizedSourceLanguage
            ))
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.lg)
        .frame(maxWidth: .infinity, minHeight: 80, alignment: .topLeading)
        .accessibilityElement(children: .contain)
    }

    private var normalizedSourceLanguage: String {
        let normalized = utterance.sourceLanguage
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(separator: "-")
            .first
            .map(String.init) ?? ""
        return normalized.isEmpty ? "und" : normalized
    }

    private var sourceLanguageLabel: String {
        if normalizedSourceLanguage == "und" {
            // The live tail's provisional provider language labels the row
            // immediately; the pending placeholder remains only when the
            // provider has not yet sent any language signal.
            if let provisional = utterance.provisionalSourceLanguage?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .split(separator: "-")
                .first
                .map(String.init),
               provisional.isEmpty == false, provisional != "und" {
                return provisional.uppercased()
            }
            return String(localized: "capture.transcript.language_pending")
        }
        return normalizedSourceLanguage.uppercased()
    }

    private var timestampText: String? {
        guard let milliseconds = utterance.sourceStartMs else { return nil }
        return TranscriptTimestampPresentation.text(milliseconds: milliseconds)
    }
}

private struct MultilingualUtteranceRow: View {
    let utterance: NotebookCaptureUtteranceDTO
    let projection: NotebookCaptureLaneProjection
    let speakerDisplayName: String?
    let onManageSpeaker: () -> Void
    let isLaneEditingEnabled: Bool
    let realtimeLoroAppliedRevision: UInt64
    let onReplace: (String, String) async throws -> Void
    let onEditingChanged: (BilingualLaneEditTarget, Bool) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if let speakerDisplayName {
                HStack {
                    NotebookSpeakerChip(
                        displayName: speakerDisplayName,
                        action: onManageSpeaker
                    )
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Spacing.md)
                .padding(.top, Spacing.sm)
            }

            Group {
                if let pendingLanguage = projection.pendingLanguage {
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        if let timestamp = timestampText {
                            Label(timestamp, systemImage: "waveform")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.textTertiary)
                                .accessibilityLabel(Text(String(
                                    format: String(localized: "capture.transcript.source_timestamp"),
                                    timestamp
                                )))
                        }
                        Label(
                            String(localized: "capture.transcript.language_pending"),
                            systemImage: "ellipsis"
                        )
                        .font(.captionMedium)
                        .foregroundColor(.textSecondary)
                        if pendingLanguage.isEmpty == false {
                            Text(pendingLanguage)
                                .font(.body)
                                .foregroundColor(.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, Spacing.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .contain)
                } else if let unselectedLanguageText = projection.unselectedLanguageText {
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        if let timestamp = timestampText {
                            Label(timestamp, systemImage: "waveform")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.textTertiary)
                                .accessibilityLabel(Text(String(
                                    format: String(localized: "capture.transcript.source_timestamp"),
                                    timestamp
                                )))
                        }
                        Text(String(
                            format: String(localized: "capture.transcript.unselected_language"),
                            normalizedSourceLanguage.uppercased()
                        ))
                            .font(.captionMedium)
                            .foregroundColor(.signalAmber)
                        BilingualLaneText(
                            target: BilingualLaneEditTarget(
                                utteranceId: utterance.id,
                                laneLanguage: normalizedSourceLanguage
                            ),
                            text: unselectedLanguageText,
                            isEditable: isLaneEditingEnabled && utterance.isLoroEditableLane(
                                language: normalizedSourceLanguage,
                                appliedRevision: realtimeLoroAppliedRevision
                            ),
                            onCommit: { target, text in
                                try await onReplace(target.laneLanguage, text)
                            },
                            onEditingChanged: onEditingChanged
                        )
                        .id(BilingualLaneEditTarget(
                            utteranceId: utterance.id,
                            laneLanguage: normalizedSourceLanguage
                        ))
                    }
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, Spacing.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .contain)
                } else {
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(Array(projection.lanes.enumerated()), id: \.element.id) {
                            index,
                            projectedLane in
                            lane(
                                projectedLane,
                                showsSourceTimestamp: utterance.hasSourceLane
                                    && sameLanguage(
                                        utterance.sourceLanguage,
                                        projectedLane.language
                                    )
                            )
                            if index < projection.lanes.count - 1 {
                                Divider().background(Color.borderGhost.opacity(0.3))
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func lane(
        _ projectedLane: NotebookCaptureLanguageLane,
        showsSourceTimestamp: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            if showsSourceTimestamp, let timestamp = timestampText {
                Label(timestamp, systemImage: "waveform")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.textTertiary)
                    .accessibilityLabel(Text(String(
                        format: String(localized: "capture.transcript.source_timestamp"),
                        timestamp
                    )))
            }

            BilingualLaneText(
                target: BilingualLaneEditTarget(
                    utteranceId: utterance.id,
                    laneLanguage: projectedLane.language
                ),
                text: projectedLane.text,
                missingLaneState: projectedLane.missingLaneState,
                isEditable: isLaneEditingEnabled && utterance.isLoroEditableLane(
                    language: projectedLane.language,
                    appliedRevision: realtimeLoroAppliedRevision
                ),
                onCommit: { target, text in
                    try await onReplace(target.laneLanguage, text)
                },
                onEditingChanged: onEditingChanged
            )
            .id(BilingualLaneEditTarget(
                utteranceId: utterance.id,
                laneLanguage: projectedLane.language
            ))
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.lg)
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .topLeading)
    }

    private var timestampText: String? {
        guard let milliseconds = utterance.sourceStartMs else { return nil }
        return TranscriptTimestampPresentation.text(milliseconds: milliseconds)
    }

    private var normalizedSourceLanguage: String {
        let normalized = utterance.sourceLanguage
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(separator: "-")
            .first
            .map(String.init) ?? ""
        return normalized.isEmpty ? "und" : normalized
    }

    private func sameLanguage(_ lhs: String, _ rhs: String) -> Bool {
        let left = lhs.lowercased().split(separator: "-").first.map(String.init)
        let right = rhs.lowercased().split(separator: "-").first.map(String.init)
        return left == right
    }
}

struct BilingualLaneEditTarget: Hashable {
    let utteranceId: String
    let laneLanguage: String

    init(utteranceId: String, laneLanguage: String) {
        self.utteranceId = utteranceId
        self.laneLanguage = laneLanguage
            .lowercased()
            .split(separator: "-")
            .first
            .map(String.init) ?? ""
    }
}

struct BilingualLaneDraftCommit: Equatable {
    let target: BilingualLaneEditTarget
    let text: String
}

struct BilingualLaneEditingState {
    private(set) var focusedTargets: Set<BilingualLaneEditTarget> = []

    var canSwap: Bool { focusedTargets.isEmpty }

    func isFocused(_ target: BilingualLaneEditTarget) -> Bool {
        focusedTargets.contains(target)
    }

    mutating func setFocused(_ target: BilingualLaneEditTarget, focused: Bool) {
        if focused {
            focusedTargets.insert(target)
        } else {
            focusedTargets.remove(target)
        }
    }
}

/// Keeps an editor draft bound to an immutable `(utterance, language)` lane.
/// A focused lane blocks display-column swaps. Call sites key the view by this
/// target, so a column swap rebuilds the lane instead of retargeting live state.
struct BilingualLaneDraftBuffer {
    private(set) var target: BilingualLaneEditTarget
    private(set) var baseline: String
    var draft: String

    init(target: BilingualLaneEditTarget, text: String) {
        self.target = target
        baseline = text
        draft = text
    }

    mutating func sync(target: BilingualLaneEditTarget, text: String) {
        self.target = target
        baseline = text
        draft = text
    }

    mutating func syncAuthoritativeTextIfUnedited(
        target: BilingualLaneEditTarget,
        text: String
    ) {
        guard pendingCommit() == nil else { return }
        sync(target: target, text: text)
    }

    func pendingCommit() -> BilingualLaneDraftCommit? {
        guard draft != baseline else { return nil }
        return BilingualLaneDraftCommit(target: target, text: draft)
    }

    mutating func markCommitted(_ text: String) {
        baseline = text
    }
}

enum TranscriptTimestampPresentation {
    static func text(milliseconds: UInt64) -> String {
        let totalSeconds = Int(milliseconds / 1_000)
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        return hours > 0
            ? String(format: "%02d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
    }
}

struct BilingualLaneText: View {
    let target: BilingualLaneEditTarget
    let text: String?
    let missingLaneState: NotebookCaptureMissingLaneState
    let isEditable: Bool
    let editAccessibilityLabel: String?
    let commitFailureMessage: String?
    let onCommit: (BilingualLaneEditTarget, String) async throws -> Void
    let onEditingChanged: (BilingualLaneEditTarget, Bool) -> Void
    @State private var buffer: BilingualLaneDraftBuffer
    @State private var isCommitInFlight = false
    @FocusState private var isFocused: Bool

    init(
        target: BilingualLaneEditTarget,
        text: String?,
        missingLaneState: NotebookCaptureMissingLaneState = .unavailable,
        isEditable: Bool,
        editAccessibilityLabel: String? = nil,
        commitFailureMessage: String? = nil,
        onCommit: @escaping (BilingualLaneEditTarget, String) async throws -> Void,
        onEditingChanged: @escaping (BilingualLaneEditTarget, Bool) -> Void
    ) {
        self.target = target
        self.text = text
        self.missingLaneState = missingLaneState
        self.isEditable = isEditable
        self.editAccessibilityLabel = editAccessibilityLabel
        self.commitFailureMessage = commitFailureMessage
        self.onCommit = onCommit
        self.onEditingChanged = onEditingChanged
        _buffer = State(initialValue: BilingualLaneDraftBuffer(
            target: target,
            text: text ?? ""
        ))
    }

    var body: some View {
        Group {
            if isEditable, let text {
                Group {
                    if #available(macOS 13.0, *) {
                        TextField("", text: $buffer.draft, axis: .vertical)
                            .lineLimit(2...)
                    } else {
                        TextField("", text: $buffer.draft)
                    }
                }
                    .textFieldStyle(.plain)
                    .font(.body)
                    .foregroundColor(.textPrimary)
                    // The page owns vertical scrolling. Let a continuous
                    // utterance grow the row instead of hiding its tail in a
                    // ten-line nested editor.
                    .focused($isFocused)
                    .disabled(isCommitInFlight)
                    .onSubmit { isFocused = false }
                    .montereyOnChange(of: isFocused) { wasFocused, focused in
                        scheduleFocusChange(wasFocused: wasFocused, focused: focused)
                    }
                    .accessibilityLabel(Text(
                        editAccessibilityLabel ?? String(
                            format: String(localized: "capture.transcript.edit_lane"),
                            target.laneLanguage.uppercased()
                        )
                    ))
                    .accessibilityHint(Text(String(localized: "capture.transcript.edit_hint")))
                    .onAppear {
                        // A lane can receive many read-only provider revisions
                        // before projection becomes editable. Seed the editor
                        // from the latest authoritative value on that first
                        // editable appearance without overwriting a user draft.
                        scheduleTextSync(text)
                    }
                    .montereyOnChange(of: text) { _, value in
                        scheduleTextSync(value)
                    }
            } else if let text, text.isEmpty == false {
                Text(text)
                    .font(.body)
                    .foregroundColor(.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else if missingLaneState == .waiting {
                Label(
                    String(
                        format: String(localized: "capture.transcript.waiting_lane"),
                        target.laneLanguage.uppercased()
                    ),
                    systemImage: "ellipsis"
                )
                .font(.caption)
                .foregroundColor(.textTertiary)
                .frame(minHeight: 28, alignment: .leading)
                .accessibilityLabel(Text(String(
                    format: String(localized: "capture.transcript.waiting_lane"),
                    target.laneLanguage.uppercased()
                )))
            } else if missingLaneState == .failed {
                Label(
                    String(
                        format: String(localized: "capture.transcript.failed_lane"),
                        target.laneLanguage.uppercased()
                    ),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundColor(.signalAmber)
                .frame(minHeight: 28, alignment: .leading)
                .accessibilityLabel(Text(String(
                    format: String(localized: "capture.transcript.failed_lane"),
                    target.laneLanguage.uppercased()
                )))
            } else {
                Text("—")
                    .font(.body)
                    .foregroundColor(.textTertiary)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 32, alignment: .topLeading)
        .onDisappear(perform: scheduleDisappear)
    }

    private func scheduleFocusChange(wasFocused: Bool, focused: Bool) {
        let editTarget = buffer.target
        if focused {
            // Register the edit synchronously. A parent transcript page may
            // disappear in the same update cycle, and its attachment must not
            // be released before this lane's deferred commit runs.
            onEditingChanged(editTarget, true)
            return
        }
        let request = buffer.pendingCommit()
        Task { @MainActor in
            await Task.yield()
            guard isFocused == focused else { return }
            if wasFocused {
                if await commit(request) {
                    onEditingChanged(editTarget, false)
                } else {
                    // Keep the swap barrier active until the edit persists or
                    // this identity leaves the transcript hierarchy.
                    onEditingChanged(editTarget, true)
                    isFocused = true
                }
            }
        }
    }

    private func scheduleTextSync(_ value: String) {
        let syncTarget = target
        Task { @MainActor in
            await Task.yield()
            guard isFocused == false,
                  buffer.target == syncTarget else { return }
            buffer.syncAuthoritativeTextIfUnedited(target: syncTarget, text: value)
        }
    }

    private func scheduleDisappear() {
        guard isFocused else { return }
        let editTarget = buffer.target
        let request = buffer.pendingCommit()
        Task { @MainActor in
            await Task.yield()
            _ = await commit(request)
            onEditingChanged(editTarget, false)
        }
    }

    @discardableResult
    private func commit(_ request: BilingualLaneDraftCommit?) async -> Bool {
        guard let request else { return true }
        guard buffer.target == request.target,
              buffer.pendingCommit() == request else { return true }
        guard isCommitInFlight == false else { return false }
        isCommitInFlight = true
        defer { isCommitInFlight = false }
        do {
            try await onCommit(request.target, request.text)
            if buffer.target == request.target {
                buffer.markCommitted(request.text)
            }
            return true
        } catch {
            ToastCenter.shared.error(
                commitFailureMessage ?? String(localized: "capture.toast.edit_failed"),
                detail: error.localizedDescription
            )
            return false
        }
    }
}
