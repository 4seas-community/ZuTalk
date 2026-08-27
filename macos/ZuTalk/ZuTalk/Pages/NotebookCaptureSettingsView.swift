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

struct NotebookCaptureSettingsView: View {
    let notebookId: String
    @ObservedObject private var capture = ActiveBilingualTranscriptStore.shared
    @ObservedObject private var editor: NotebookCaptureProfileEditorModel
    @ObservedObject private var engineStore = NotebookCaptureEnginePresentationStore.shared
    @ObservedObject private var inputDevices = AudioInputDeviceStore.shared
    let scope: NotebookCaptureSettingsScope
    let onOpenRealtimeControls: () -> Void
    /// Session Settings owns the page-level scroller so its resources,
    /// editable defaults, and immutable snapshot remain one continuous page.
    /// Topic/quick-capture settings still use their standalone scroller.
    private let embeddedInParentScrollView: Bool
    @State private var isReviewingContext = false
    @State private var isLoadingContextPacks = true
    @State private var contextLoadError: String?

    init(
        notebookId: String,
        editor: NotebookCaptureProfileEditorModel,
        scope: NotebookCaptureSettingsScope = .topic,
        embeddedInParentScrollView: Bool = false,
        onOpenRealtimeControls: @escaping () -> Void
    ) {
        self.notebookId = notebookId
        _editor = ObservedObject(wrappedValue: editor)
        self.scope = scope
        self.embeddedInParentScrollView = embeddedInParentScrollView
        self.onOpenRealtimeControls = onOpenRealtimeControls
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
            inputDevices.refresh()
            engineStore.refresh()
            loadContextBrowser()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            inputDevices.refresh()
        }
    }

    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            header

            if capture.isCaptureActive {
                Label(
                    String(localized: "capture.settings.active_locked"),
                    systemImage: "exclamationmark.circle.fill"
                )
                .font(.captionMedium)
                .foregroundColor(.signalAmber)
                .padding(Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.signalAmber.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
            }

            audioInputSection

            VStack(alignment: .leading, spacing: Spacing.lg) {
                contextBrowserSection
                postStopRemoteProcessingSection
                retentionSection
            }
            .disabled(editor.canEdit == false)
            .opacity(editor.canEdit ? 1 : 0.62)

            realtimeFooterLink
        }
        .frame(maxWidth: 820, alignment: .leading)
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var draft: NotebookCaptureProfileDTO { editor.draft }

    private var header: some View {
        MontereyHorizontalViewThatFits {
            HStack(alignment: .top, spacing: Spacing.md) {
                headerCopy
                Spacer()
                settingsActions
            }
        } fallback: {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                headerCopy
                settingsActions
            }
        }
    }

    private var settingsActions: some View {
        persistenceStatus
    }

    private var headerCopy: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(String(localized: "capture.settings.title"))
                .font(.headline)
                .foregroundColor(.textPrimary)
            Text(scope.settingsDescription)
                .font(.caption)
                .foregroundColor(.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var audioInputSection: some View {
        settingsCard(
            title: String(localized: "settings.audio_input.title"),
            icon: "waveform.and.mic"
        ) {
            Text(String(localized: "settings.audio_input.subtitle"))
                .font(.caption)
                .foregroundColor(.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Spacing.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "settings.audio_input.device"))
                        .font(.captionMedium)
                        .foregroundColor(.textPrimary)
                    Text(String(localized: "settings.audio_input.local_scope"))
                        .font(.system(size: 10))
                        .foregroundColor(.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: Spacing.sm)

                Picker("", selection: audioInputSelection) {
                    Text(systemDefaultInputTitle).tag(String?.none)
                    ForEach(inputDevices.devices) { device in
                        Text(device.name).tag(Optional(device.uid))
                    }
                    if inputDevices.isExplicitSelectionUnavailable,
                       let missingUID = inputDevices.selectedUID {
                        Text(unavailableInputTitle).tag(Optional(missingUID))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 280, alignment: .trailing)
                .disabled(audioInputSelectionDisabled)
                .accessibilityLabel(Text(String(localized: "settings.audio_input.device")))

                Button {
                    inputDevices.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundColor(.textSecondary)
                .disabled(capture.isAudioInputSwitching)
                .help(String(localized: "settings.audio_input.refresh"))
                .accessibilityLabel(Text(String(localized: "settings.audio_input.refresh")))
            }
            .padding(Spacing.md)
            .background(Color.bgSunken.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: Radius.sm))

            Text(String(localized: "settings.audio_input.channel_one_hint"))
                .font(.caption)
                .foregroundColor(.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let status = audioInputStatus {
                Label(status.text, systemImage: status.systemImage)
                    .font(.captionMedium)
                    .foregroundColor(status.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var audioInputSelection: Binding<String?> {
        Binding(
            get: { inputDevices.selectedUID },
            set: { requestedUID in
                Task { @MainActor in
                    do {
                        try await capture.selectAudioInputDevice(
                            uid: requestedUID,
                            notebookId: notebookId
                        )
                    } catch {
                        ToastCenter.shared.error(
                            String(localized: "capture.toast.audio_input_switch_failed"),
                            detail: error.localizedDescription
                        )
                    }
                }
            }
        )
    }

    private var audioInputSelectionDisabled: Bool {
        capture.isAudioInputSwitching
            || capture.captureState == .draining
            || (capture.isCaptureActive && capture.notebookId != notebookId)
    }

    private var systemDefaultInputTitle: String {
        let resolvedDevice = inputDevices.selectedUID == nil && capture.isCaptureActive
            ? capture.activeAudioInputDevice
            : inputDevices.defaultInputDevice
        guard let name = resolvedDevice?.name else {
            return String(localized: "settings.audio_input.system_default")
        }
        return String(
            format: String(localized: "settings.audio_input.system_default_format"),
            name
        )
    }

    private var unavailableInputTitle: String {
        let name = inputDevices.selectedDeviceLastKnownName
            ?? inputDevices.selectedUID
            ?? String(localized: "settings.audio_input.device")
        return String(
            format: String(localized: "settings.audio_input.unavailable_format"),
            name
        )
    }

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
        if capture.isCaptureActive, capture.notebookId == notebookId {
            return (
                String(localized: "settings.audio_input.active_switch_hint"),
                "arrow.left.arrow.right",
                .textSecondary
            )
        }
        return nil
    }

    private var realtimeFooterLink: some View {
        Button(action: onOpenRealtimeControls) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "waveform.and.mic")
                    .font(.system(size: 11, weight: .semibold))
                Text(String(localized: "capture.settings.footer.realtime"))
                    .fixedSize(horizontal: false, vertical: true)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
            }
            .font(.caption)
            .foregroundColor(.textSecondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(String(localized: "capture.settings.footer.realtime")))
    }

    @ViewBuilder
    private var persistenceStatus: some View {
        switch editor.persistenceState {
        case .loading:
            settingsStatusLabel(
                String(localized: "capture.settings.autosave.loading"),
                systemImage: "arrow.clockwise",
                color: .textSecondary
            )
        case .saving:
            settingsStatusLabel(
                String(localized: "capture.settings.autosave.saving"),
                systemImage: "arrow.triangle.2.circlepath",
                color: .textSecondary
            )
        case .saved:
            settingsStatusLabel(
                String(localized: "capture.settings.autosave.saved"),
                systemImage: "checkmark.circle.fill",
                color: .signalGreen
            )
        case .loadFailed(let message):
            settingsFailureStatus(
                title: String(localized: "capture.settings.autosave.load_failed"),
                message: message,
                actionTitle: String(localized: "capture.settings.autosave.retry"),
                action: editor.retry
            )
        case .saveFailed(let message):
            settingsFailureStatus(
                title: String(localized: "capture.settings.autosave.save_failed"),
                message: message,
                actionTitle: String(localized: "capture.settings.autosave.retry"),
                action: editor.retry
            )
        }
    }

    private func settingsStatusLabel(
        _ title: String,
        systemImage: String,
        color: Color
    ) -> some View {
        Label(title, systemImage: systemImage)
            .font(.captionMedium)
            .foregroundColor(color)
            .accessibilityLabel(Text(title))
    }

    private func settingsFailureStatus(
        title: String,
        message: String,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .trailing, spacing: Spacing.xs) {
            Label(title, systemImage: "exclamationmark.triangle.fill")
                .font(.captionMedium)
                .foregroundColor(.signalAmber)
            Text(message)
                .font(.caption2)
                .foregroundColor(.textTertiary)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
                .help(message)
            Button(actionTitle, action: action)
                .buttonStyle(.link)
                .font(.caption)
                .disabled(capture.isCaptureActive)
        }
        .frame(maxWidth: 280, alignment: .trailing)
    }

    private var contextSection: some View {
        settingsCard(
            title: String(localized: "capture.settings.context.title"),
            icon: "books.vertical.fill"
        ) {
            Text(String(localized: "capture.settings.context.pack_detail"))
                .font(.caption)
                .foregroundColor(.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Spacing.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "capture.settings.context.current"))
                        .font(.system(size: 10))
                        .foregroundColor(.textTertiary)
                    Text(selectedContextPack.map(contextPackDisplayTitle)
                         ?? String(localized: "capture.settings.context.no_selection"))
                        .font(.captionMedium)
                        .foregroundColor(.textPrimary)
                        .lineLimit(1)
                }

                Spacer(minLength: Spacing.sm)

                Menu {
                    ForEach(capture.contextPacks) { pack in
                        Button {
                            selectContextPack(pack.id)
                        } label: {
                            if capture.selectedContextPackId == pack.id {
                                Label(contextPackDisplayTitle(pack), systemImage: "checkmark")
                            } else {
                                Text(contextPackDisplayTitle(pack))
                            }
                        }
                    }
                } label: {
                    Text(String(localized: "capture.settings.context.choose"))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(capture.contextPacks.isEmpty)
                .accessibilityLabel(Text(String(localized: "capture.settings.context.choose")))
            }
            .padding(Spacing.md)
            .background(Color.bgSunken.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: Radius.sm))

            Button(String(localized: "capture.settings.context.preview")) {
                requestContextPreview()
            }
            .buttonStyle(.plain)
            .font(.caption)
            .disabled(selectedContextPack == nil)

            if isReviewingContext {
                contextReview
            }
        }
    }

    @ViewBuilder
    private var contextBrowserSection: some View {
        if isLoadingContextPacks {
            settingsCard(
                title: String(localized: "capture.settings.context.title"),
                icon: "doc.text.magnifyingglass"
            ) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(Text(String(localized: "capture.settings.autosave.loading")))
            }
        } else if let contextLoadError {
            settingsCard(
                title: String(localized: "capture.settings.context.title"),
                icon: "exclamationmark.triangle.fill"
            ) {
                Text(contextLoadError)
                    .font(.caption)
                    .foregroundColor(.signalAmber)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Button(String(localized: "capture.settings.autosave.retry")) {
                    loadContextBrowser()
                }
                .buttonStyle(.bordered)
            }
        } else if capture.loadedContextNotebookId == notebookId {
            contextSection
        }
    }

    private var retentionSection: some View {
        settingsCard(
            title: String(localized: "capture.settings.retention.title"),
            icon: "internaldrive"
        ) {
            Text(String(localized: "capture.settings.retention.subtitle"))
                .font(.caption)
                .foregroundColor(.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(NotebookAudioRetentionLevel.allCases) { level in
                retentionOptionRow(AudioPrivacyOptionSummary(level: level))
            }
        }
    }

    private func retentionOptionRow(_ option: AudioPrivacyOptionSummary) -> some View {
        let isSelected = draft.privacyLevel == option.level
        return Button {
            editor.update { $0.privacyLevel = option.level }
        } label: {
            HStack(alignment: .top, spacing: Spacing.sm) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 12))
                    .foregroundColor(isSelected ? .brandAccent : .textTertiary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.title)
                        .font(.captionMedium)
                        .foregroundColor(.textPrimary)
                    Text(option.storageText)
                        .font(.caption)
                        .foregroundColor(.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Spacing.sm)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(option.title))
        .accessibilityValue(Text(isSelected
                                 ? String(localized: "capture.settings.context.selected")
                                 : String(localized: "capture.settings.context.not_selected")))
        .accessibilityHint(Text(option.storageText))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var postStopRemoteProcessingSection: some View {
        settingsCard(
            title: String(localized: "capture.settings.after_stop.title"),
            icon: "waveform.badge.plus"
        ) {
            Text(String(localized: engineStore.engine.postStopUsesAsyncFileApi == true
                ? "capture.settings.after_stop.detail"
                : "capture.settings.after_stop.unavailable_detail"))
                .font(.caption)
                .foregroundColor(.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("\(String(localized: "capture.settings.after_stop.engine")) · \(engineStore.engine.postStopSummary) · \(engineStore.engine.postStopExecutionSummary)")
                .font(.system(size: 10))
                .foregroundColor(.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
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
                Label(
                    String(
                        format: String(localized: "capture.settings.context.preview_count"),
                        preview.scalarCount
                    ),
                    systemImage: "eye.fill"
                )
                .font(.captionMedium)
                .foregroundColor(.textPrimary)

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
                            .font(.caption)
                    } icon: {
                        Image(systemName: source.included ? "checkmark.circle" : "minus.circle")
                    }
                    .foregroundColor(source.included ? .textSecondary : .signalAmber)
                }

                ForEach(Array(preview.omittedReasons.enumerated()), id: \.offset) { _, reason in
                    Label(reason, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundColor(.signalAmber)
                }

                Button(String(localized: "common.close")) {
                    isReviewingContext = false
                }
                .buttonStyle(.bordered)
            }
            .padding(Spacing.md)
            .background(Color.bgElevated.opacity(0.32))
            .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
        }
    }

    private func settingsCard<Content: View>(
        title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Label(title, systemImage: icon)
                .font(.captionMedium)
                .foregroundColor(.textSecondary)
            content()
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard(
            fill: Color.bgElevated.opacity(0.3),
            cornerRadius: Radius.md,
            border: Color.borderGhost.opacity(0.3),
            borderWidth: 0.5
        )
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

