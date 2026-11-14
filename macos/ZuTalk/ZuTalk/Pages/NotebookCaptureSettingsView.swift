import AppKit
import Combine
import SwiftUI

// MARK: - Notebook capture settings

/// User-facing destination of the editable recording defaults. This identity
/// comes from the backend quick-capture Notebook id; it must never be inferred
/// from a localized or user-editable title.
enum NotebookCaptureSettingsScope: Equatable {
    case topic
    case quickCapture

    var settingsDescription: String {
        switch self {
        case .topic:
            String(localized: "capture.settings.subtitle.topic")
        case .quickCapture:
            String(localized: "capture.settings.subtitle.quick_capture")
        }
    }

    var sessionWorkspaceDescription: String {
        switch self {
        case .topic:
            String(localized: "session.settings.workspace.scope.topic")
        case .quickCapture:
            String(localized: "session.settings.workspace.scope.quick_capture")
        }
    }

    var privateContextTitle: String {
        switch self {
        case .topic:
            String(localized: "capture.settings.context.current_topic")
        case .quickCapture:
            String(localized: "capture.settings.context.current_quick_capture")
        }
    }
}

/// A topic's options: the defaults its next recordings start with.
///
/// The page is rows of a name and a control (docs/product/interface-layers.md
/// 「界面怎么写」) — languages, sound, terms and background, audio. Nothing is
/// explained in place: what used to be a paragraph under each card is the
/// tooltip of the row's name or of its pill, and the two things a person has
/// to be able to read before choosing — what each audio choice deletes, and
/// what recording the Mac's own sound needs — sit behind the ⓘ beside the
/// pill. That these are defaults for the next recordings is the page's
/// header, one word, with the full sentence as its tooltip.
struct NotebookCaptureSettingsView: View {
    let notebookId: String
    @ObservedObject private var capture = ActiveBilingualTranscriptStore.shared
    @ObservedObject private var editor: NotebookCaptureProfileEditorModel
    @ObservedObject private var inputDevices = AudioInputDeviceStore.shared
    let scope: NotebookCaptureSettingsScope
    /// Session Settings owns the page-level scroller so its resources,
    /// editable defaults, and immutable snapshot remain one continuous page.
    /// Topic/quick-capture settings still use their standalone scroller.
    private let embeddedInParentScrollView: Bool
    @State private var isReviewingContext = false
    /// 专有词与背景的编辑器(原来侧边栏的「知识库」)从用到它的地方打开。
    @State private var isManagingKnowledge = false
    @State private var isLoadingContextPacks = true
    @State private var contextLoadError: String?

    init(
        notebookId: String,
        editor: NotebookCaptureProfileEditorModel,
        scope: NotebookCaptureSettingsScope = .topic,
        embeddedInParentScrollView: Bool = false
    ) {
        self.notebookId = notebookId
        _editor = ObservedObject(wrappedValue: editor)
        self.scope = scope
        self.embeddedInParentScrollView = embeddedInParentScrollView
    }

    var body: some View {
        Group {
            if embeddedInParentScrollView {
                settingsContent
            } else {
                ScrollView {
                    settingsContent
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.bgRoot)
        .task(id: notebookId) {
            inputDevices.refreshInBackground()
            loadContextBrowser()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            inputDevices.refreshInBackground()
        }
    }

    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            header
            persistenceFailureDetail

            if capture.isCaptureActive {
                // A status, so it stays a sentence: what a recording in
                // progress has frozen, and what can still be changed.
                Label(
                    String(localized: "capture.settings.active_locked"),
                    systemImage: "exclamationmark.circle.fill"
                )
                .font(.bodySM)
                .foregroundColor(.signalAmber)
                .fixedSize(horizontal: false, vertical: true)
            }

            // What a recording in progress freezes is disabled control by
            // control — each pill dims itself — so the names stay readable
            // and the ⓘ beside a frozen choice can still be opened.
            PlainRowGroup {
                languagesSection
                audioInputSection
                contextBrowserSection
                retentionSection
            }

            // Only a topic has a channel; a recording filed under none has
            // nowhere to inherit one from.
            if scope == .topic {
                CityTopicChannelCard(notebookId: notebookId)
            }
        }
        .frame(maxWidth: 820, alignment: .leading)
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var draft: NotebookCaptureProfileDTO { editor.draft }

    /// Languages, terms and audio keep what a recording started with; they
    /// cannot be edited while one runs, or before the saved options load.
    private var isFrozen: Bool { editor.canEdit == false }

    /// One word says what the page is — defaults — and the sentence about
    /// whose defaults, and that changes save themselves, is its tooltip.
    private var header: some View {
        let title = String(localized: "topics.options.header")
        // The status sits beside the title while there is room; a failure
        // with its Retry is wider, and drops under it in a narrow window.
        return MontereyHorizontalViewThatFits {
            PlainPageHeader(title, help: scope.settingsDescription) {
                persistenceStatus
            }
        } fallback: {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                PlainPageHeader(title, help: scope.settingsDescription)
                persistenceStatus
            }
        }
        .accessibilityIdentifier("capture.settings.header")
    }

    // MARK: 声音

    private var audioInputSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            PlainRow(String(localized: "topics.options.sound")) {
                PillStrip {
                    HStack(spacing: 2) {
                        AudioInputPicker(notebookId: notebookId)
                        if inputDevices.isSystemAudioSelected {
                            // Recording the Mac's own sound needs a macOS
                            // permission, and without it the recording is
                            // silent: where to grant it has to be findable.
                            InfoButton(
                                String(localized: "settings.audio_input.system_audio_hint"),
                                accessibilityLabel: String(localized: "settings.audio_input.title")
                            )
                        }
                    }
                }
            }

            if let status = audioInputStatus {
                PlainRowDetail {
                    Label(status.text, systemImage: status.systemImage)
                        .font(.bodySM)
                        .foregroundColor(status.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// What stands in the way of choosing a source, or of the chosen one
    /// working: a status or an error, one sentence, shown only while it is
    /// true. What is merely worth knowing is the pill's tooltip.
    private var audioInputStatus: (text: String, systemImage: String, color: Color)? {
        if capture.isAudioInputSwitching {
            return (
                String(localized: "settings.audio_input.switching"),
                "arrow.triangle.2.circlepath",
                .brandAccent
            )
        }
        if capture.isCaptureActive, capture.notebookId != notebookId {
            return (
                String(localized: "settings.audio_input.active_elsewhere"),
                "lock.fill",
                .signalAmber
            )
        }
        if capture.captureState == .draining {
            return (
                String(localized: "settings.audio_input.error.switch_unavailable"),
                "hourglass",
                .signalAmber
            )
        }
        if let refreshError = inputDevices.refreshError {
            return (refreshError, "exclamationmark.triangle.fill", .signalAmber)
        }
        if inputDevices.isExplicitSelectionUnavailable {
            return (
                String(
                    format: String(localized: "settings.audio_input.error.unavailable_format"),
                    inputDevices.selectedDeviceLastKnownName
                        ?? inputDevices.selectedUID
                        ?? String(localized: "settings.audio_input.device")
                ),
                "exclamationmark.triangle.fill",
                .signalAmber
            )
        }
        if inputDevices.hasLoadedSnapshot, inputDevices.devices.isEmpty {
            return (
                String(localized: "settings.audio_input.error.no_device"),
                "exclamationmark.triangle.fill",
                .signalAmber
            )
        }
        return nil
    }

    // MARK: 语言

    /// 这个主题录音时说哪些语言。和首页那张卡是同一排胶囊:× 拿掉,＋ 搜索
    /// 添加,三种语言时前面的图标改「说的 / 另外译成」,右键菜单调顺序。
    private var languagesSection: some View {
        PlainRow(
            String(localized: "topics.options.languages"),
            help: languagesExplanation
        ) {
            CaptureLanguageEditor(editor: editor)
                .modifier(FrozenWhileRecording(isFrozen: isFrozen))
        }
        .accessibilityIdentifier("capture.settings.languages")
    }

    private var languagesExplanation: String {
        [
            String(localized: "capture.settings.languages.ordered_detail"),
            CaptureLanguageEditor.rolesSummary(
                selected: draft.selectedLanguages,
                translatedOnly: draft.subtitleOnlyLanguages
            ),
        ]
        .compactMap { $0 }
        .joined(separator: "\n")
    }

    // MARK: 保存状态

    @ViewBuilder
    private var persistenceStatus: some View {
        switch editor.persistenceState {
        case .loading:
            PlainStatus(
                String(localized: "capture.settings.autosave.loading"),
                systemImage: "arrow.clockwise"
            )
        case .saving:
            PlainStatus(
                String(localized: "capture.settings.autosave.saving"),
                systemImage: "arrow.triangle.2.circlepath"
            )
        case .saved:
            PlainStatus(
                String(localized: "capture.settings.autosave.saved"),
                systemImage: "checkmark.circle.fill",
                tint: .signalGreen
            )
        case .loadFailed(let message):
            settingsFailureStatus(
                title: String(localized: "capture.settings.autosave.load_failed"),
                message: message
            )
        case .saveFailed(let message):
            settingsFailureStatus(
                title: String(localized: "capture.settings.autosave.save_failed"),
                message: message
            )
        }
    }

    /// An error and its one action.
    private func settingsFailureStatus(title: String, message: String) -> some View {
        HStack(spacing: Spacing.sm) {
            PlainStatus(
                title,
                systemImage: "exclamationmark.triangle.fill",
                tint: .signalAmber,
                help: message
            )
            ActionPill(
                String(localized: "capture.settings.autosave.retry"),
                systemImage: "arrow.clockwise",
                action: editor.retry
            )
            .disabled(capture.isCaptureActive)
        }
    }

    /// What the system said went wrong, under the header while the failure
    /// lasts: an error has to be readable and copyable, not only hoverable.
    @ViewBuilder
    private var persistenceFailureDetail: some View {
        switch editor.persistenceState {
        case .loadFailed(let message), .saveFailed(let message):
            Text(message)
                .font(.bodySM)
                .foregroundColor(.textTertiary)
                .lineLimit(2)
                .textSelection(.enabled)
                .help(message)
        case .loading, .saving, .saved:
            EmptyView()
        }
    }

    // MARK: 专有词与背景

    private var contextSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            PlainRow(
                String(localized: "capture.settings.context.title"),
                help: String(localized: "capture.settings.context.pack_detail")
            ) {
                PillStrip {
                    // Which set this topic's recordings use: the value is on
                    // the pill, the others are in its menu.
                    MenuPill(
                        selectedContextPack.map(contextPackDisplayTitle)
                            ?? String(localized: "capture.settings.context.no_selection"),
                        titleIsName: selectedContextPack?.isPrivate == false,
                        systemImage: "books.vertical",
                        tone: capture.contextPacks.isEmpty ? .dimmed : .normal,
                        help: String(localized: "capture.settings.context.pack_detail"),
                        accessibilityLabel: String(localized: "capture.settings.context.title")
                    ) {
                        capture.contextPacks.map { pack in
                            PillMenuItem(
                                contextPackDisplayTitle(pack),
                                isOn: capture.selectedContextPackId == pack.id
                            ) {
                                selectContextPack(pack.id)
                            }
                        }
                    }
                    .disabled(capture.contextPacks.isEmpty || isFrozen)
                    .accessibilityIdentifier("capture.settings.context.pack")

                    ActionPill(
                        String(localized: "topics.options.edit"),
                        systemImage: "square.and.pencil",
                        help: String(localized: "capture.settings.context.manage"),
                        accessibilityLabel: String(localized: "capture.settings.context.manage")
                    ) {
                        isManagingKnowledge = true
                    }
                    .disabled(isFrozen)
                    .accessibilityIdentifier("capture.settings.context.manage")

                    ActionPill(
                        String(localized: "topics.options.preview"),
                        systemImage: "eye",
                        style: .quiet,
                        help: String(localized: "capture.settings.context.preview"),
                        accessibilityLabel: String(localized: "capture.settings.context.preview")
                    ) {
                        requestContextPreview()
                    }
                    .disabled(selectedContextPack == nil || isFrozen)
                    .accessibilityIdentifier("capture.settings.context.preview")
                }
            }
            .sheet(isPresented: $isManagingKnowledge, onDismiss: loadContextBrowser) {
                KnowledgeLibrarySheet()
            }

            if isReviewingContext {
                PlainRowDetail {
                    contextReview
                }
            }
        }
    }

    @ViewBuilder
    private var contextBrowserSection: some View {
        if isLoadingContextPacks {
            PlainRow(String(localized: "capture.settings.context.title")) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(Text(String(localized: "capture.settings.autosave.loading")))
            }
        } else if let contextLoadError {
            // An error and its one action.
            VStack(alignment: .leading, spacing: Spacing.xs) {
                PlainRow(String(localized: "capture.settings.context.title")) {
                    ActionPill(
                        String(localized: "capture.settings.autosave.retry"),
                        systemImage: "arrow.clockwise"
                    ) {
                        loadContextBrowser()
                    }
                    .disabled(isFrozen)
                }
                PlainRowDetail {
                    Label(contextLoadError, systemImage: "exclamationmark.triangle.fill")
                        .font(.bodySM)
                        .foregroundColor(.signalAmber)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        } else if capture.loadedContextNotebookId == notebookId {
            contextSection
        }
    }

    // MARK: 音频

    /// What happens to the audio once there is text. The pill shows the
    /// choice; what each choice deletes, and that a recording keeps the one
    /// it started with, is behind the ⓘ — two of the three delete audio for
    /// good, so it has to be readable before choosing.
    private var retentionSection: some View {
        let current = AudioPrivacyOptionSummary(level: draft.privacyLevel)
        let name = String(localized: "capture.settings.retention.title")
        return PlainRow(String(localized: "topics.options.audio")) {
            PillStrip {
                HStack(spacing: 2) {
                    MenuPill(
                        current.title,
                        systemImage: current.systemImage,
                        help: current.storageText,
                        accessibilityLabel: name
                    ) {
                        NotebookAudioRetentionLevel.allCases.map { level in
                            PillMenuItem(
                                AudioPrivacyOptionSummary(level: level).title,
                                isOn: editor.draft.privacyLevel == level
                            ) {
                                editor.update { $0.privacyLevel = level }
                            }
                        }
                    }
                    .disabled(isFrozen)
                    .accessibilityIdentifier("capture.settings.retention")

                    InfoButton(AudioPrivacyOptionSummary.disclosure, accessibilityLabel: name)
                        .accessibilityIdentifier("capture.settings.retention.info")
                }
            }
        }
    }

    private func contextPackDisplayTitle(_ pack: NotebookContextPackDTO) -> String {
        pack.isPrivate
            ? scope.privateContextTitle
            : pack.title
    }

    @ViewBuilder
    private var contextReview: some View {
        if let preview = capture.contextPreview, preview.notebookId == notebookId {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                HStack(spacing: Spacing.sm) {
                    PlainStatus(
                        String(
                            format: String(localized: "capture.settings.context.preview_count"),
                            preview.scalarCount
                        ),
                        systemImage: "eye"
                    )
                    Spacer(minLength: Spacing.sm)
                    ActionPill(
                        String(localized: "common.close"),
                        systemImage: "xmark",
                        style: .quiet
                    ) {
                        isReviewingContext = false
                    }
                }

                ScrollView {
                    Text(preview.containsSendableContext == false
                         ? String(localized: "capture.settings.context.empty")
                         : preview.serializedContext)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.textSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Spacing.sm)
                }
                .frame(minHeight: 96, maxHeight: 180)
                .background(Color.bgSunken.opacity(0.7))
                .clipShape(RoundedRectangle(cornerRadius: Radius.sm))

                ForEach(preview.sources) { source in
                    Label {
                        Text("\(source.title) · \(source.scalarCount)")
                            .font(.bodySM)
                    } icon: {
                        Image(systemName: source.included ? "checkmark.circle" : "minus.circle")
                    }
                    .foregroundColor(source.included ? .textSecondary : .signalAmber)
                }

                ForEach(Array(preview.omittedReasons.enumerated()), id: \.offset) { _, reason in
                    Label(reason, systemImage: "exclamationmark.triangle")
                        .font(.bodySM)
                        .foregroundColor(.signalAmber)
                }
            }
        }
    }

    private func requestContextPreview() {
        do {
            _ = try capture.previewContext(notebookId: notebookId)
            isReviewingContext = true
        } catch {
            ToastCenter.shared.error(
                String(localized: "capture.toast.context_preview_failed"),
                detail: error.localizedDescription
            )
        }
    }

    private func loadContextBrowser() {
        isLoadingContextPacks = true
        contextLoadError = nil
        defer { isLoadingContextPacks = false }
        do {
            try capture.loadContextPacks(notebookId: notebookId)
        } catch {
            contextLoadError = error.localizedDescription
            ToastCenter.shared.error(
                String(localized: "capture.toast.context_load_failed"),
                detail: error.localizedDescription
            )
        }
    }

    private var selectedContextPack: NotebookContextPackDTO? {
        guard let id = capture.selectedContextPackId else { return nil }
        return capture.contextPacks.first(where: { $0.id == id })
    }

    private func selectContextPack(_ packId: String) {
        do {
            try capture.selectContextPackForTranscription(packId, notebookId: notebookId)
            editor.update { profile in
                profile.remoteRealtimeEnabled = true
                profile.sendContextToSoniox = true
            }
            isReviewingContext = false
        } catch {
            showContextError(error)
        }
    }

    private func showContextError(_ error: Error) {
        ToastCenter.shared.error(
            String(localized: "capture.toast.context_update_failed"),
            detail: error.localizedDescription
        )
    }

}

/// Takes a control out of use while its setting is frozen, and shows it: the
/// language pills do not dim themselves the way the other pills do.
private struct FrozenWhileRecording: ViewModifier {
    let isFrozen: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isFrozen {
            content
                .disabled(true)
                .opacity(0.5)
        } else {
            content
        }
    }
}
