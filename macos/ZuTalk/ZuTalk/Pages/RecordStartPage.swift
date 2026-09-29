// RecordStartPage.swift
// 侧边栏第一项「开始录音」:开始一场录音的唯一一页。
//
// 录音以前有五个起点:主页的按钮、主题页头的按钮、主题「实时」标签里的工具条、
// 菜单栏、⌃⌥R —— 每个起点旁边的语言选择、字幕开关各不相同,主题的语言只能在
// 「实时」标签里改。现在窗口里只有这一页:归到哪个主题、说哪几种语言、要不要
// 实时字幕,选好按一下。菜单栏与快捷键是窗口外的两个快捷方式,用的是这里最后
// 一次的选择(未归入主题的语言设置)。
//
// 录音进行中,侧边栏这一项变成「正在录音」,点它回到那场录音;这一页不再
// 出现第二个开始按钮。

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct RecordStartPage: View {
    @StateObject private var library = LibraryViewModel()
    @StateObject private var importer = NotebookResourcesViewModel()
    @ObservedObject private var capture = ActiveBilingualTranscriptStore.shared
    @ObservedObject private var commands = CaptureCommandCenter.shared
    @ObservedObject private var navigation = MainNavigationStore.shared
    @ObservedObject private var nearby = NearbyStore.shared
    /// 录进哪个主题。nil 是「未归入主题」—— 录完随时可以归档。
    @State private var topicId: String?
    /// 语言选择编辑的就是开始时要用的那一份设置:未归入主题有它自己的一份,
    /// 每个主题各有一份。同一个实例既给选择器用也给开始用,选择器里还没
    /// 存下的改动由开始流程自己先存。
    @State private var editor: NotebookCaptureProfileEditorModel?

    private var notebookId: String? { topicId ?? library.quickCaptureNotebookId }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(String(localized: "record.page.title"))
                        .font(.titleLG)
                        .foregroundColor(.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Text(String(localized: "record.page.subtitle"))
                        .font(.bodySM)
                        .foregroundColor(.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // 只有附近真有人在直播时才出现;来这一页的人多半就是来看的,放在最前面。
                if nearby.liveNearby.isEmpty == false {
                    nearbyLive
                }

                if capture.isCaptureActive {
                    recordingNow
                } else {
                    startCard
                    importRow
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(.horizontal, Spacing.xl)
            .padding(.vertical, Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(Color.bgRoot)
        .onAppear {
            library.loadNotebookWorkspace()
            takePreselectedTopic()
            syncEditor()
        }
        .montereyOnChange(of: navigation.recordTopicPreselection) { _, _ in
            takePreselectedTopic()
        }
        .montereyOnChange(of: library.quickCaptureNotebookId) { _, _ in syncEditor() }
        .montereyOnChange(of: topicId) { _, _ in syncEditor() }
        .montereyOnChange(of: capture.isCaptureActive) { _, active in
            // 一场录音可能推进了设置的版本;重新载入,选择器才不会拿旧版本去写。
            if active == false { editor?.load() }
        }
        .accessibilityIdentifier("record.page")
    }

    // MARK: 开始

    private var startCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            row(title: String(localized: "record.page.topic"), detail: String(localized: "record.page.topic_detail")) {
                Picker("", selection: $topicId) {
                    Text(String(localized: "home.record.unfiled")).tag(String?.none)
                    if library.researchNotebooks.isEmpty == false {
                        Divider()
                    }
                    ForEach(library.researchNotebooks, id: \.id) { notebook in
                        Text(notebook.title).tag(String?.some(notebook.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 260)
                .accessibilityIdentifier("record.page.topic")
            }

            Divider().padding(.horizontal, Spacing.md)

            VStack(alignment: .leading, spacing: Spacing.sm) {
                rowTitle(
                    String(localized: "capture.settings.languages.question"),
                    detail: String(localized: "capture.settings.languages.ordered_detail")
                )
                if let editor {
                    CaptureLanguageEditor(editor: editor)
                        .disabled(editor.canEdit == false)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(Spacing.md)
            .accessibilityIdentifier("record.page.languages")

            Divider().padding(.horizontal, Spacing.md)

            row(title: String(localized: "record.page.captions"), detail: captionsDetail) {
                CaptionsChoiceChip()
            }

            Divider().padding(.horizontal, Spacing.md)

            VStack(spacing: Spacing.sm) {
                Button(action: start) {
                    Label(
                        String(localized: commands.isStarting ? "home.record.starting" : "home.record.start"),
                        systemImage: commands.isStarting ? "ellipsis" : "record.circle"
                    )
                    .font(.titleMD)
                    .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.borderedProminent)
                .tint(.signalRed)
                .controlSize(.large)
                .disabled(commands.isStarting || notebookId == nil)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("record.page.start")

                Text(String(localized: "record.page.shortcut_hint"))
                    .font(.bodySM)
                    .foregroundColor(.textTertiary)
            }
            .padding(Spacing.md)
        }
        .surfaceCard(
            fill: Color.bgElevated.opacity(0.4),
            cornerRadius: Radius.md,
            border: Color.borderSubtle,
            borderWidth: 0.5
        )
    }

    private var captionsDetail: String {
        String(localized: commands.realtimeCredentialAvailable
            ? "record.page.captions_detail"
            : "record.page.captions_needs_key")
    }

    private var importRow: some View {
        HStack(spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "record.page.import"))
                    .font(.bodyMedium)
                    .foregroundColor(.textPrimary)
                Text(String(localized: "record.page.import_detail"))
                    .font(.bodySM)
                    .foregroundColor(.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Spacing.md)
            Button {
                chooseAudioToImport()
            } label: {
                Label(
                    String(localized: importer.isImportingAudio ? "record.page.importing" : "record.page.import_button"),
                    systemImage: "square.and.arrow.down"
                )
            }
            .disabled(importer.isImportingAudio || notebookId == nil)
            .accessibilityIdentifier("record.page.import")
        }
        .padding(.horizontal, Spacing.md)
    }

    // MARK: 录音进行中

    private var recordingNow: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(spacing: Spacing.sm) {
                PulsingDot(color: .signalRed, size: 10)
                    .accessibilityHidden(true)
                Text(String(localized: "record.page.recording_now"))
                    .font(.titleMD)
                    .foregroundColor(.textPrimary)
            }
            Text(String(localized: "record.page.recording_now_detail"))
                .font(.bodySM)
                .foregroundColor(.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                MainNavigationStore.shared.openLiveRecording()
            } label: {
                Label(String(localized: "record.page.open_recording"), systemImage: "arrow.right.circle")
                    .frame(minHeight: 32)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("record.page.open-recording")
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard(
            fill: Color.bgElevated.opacity(0.4),
            cornerRadius: Radius.md,
            border: Color.borderSubtle,
            borderWidth: 0.5
        )
    }

    // MARK: 附近正在直播

    /// 同一网络里有 ZuTalk 在直播(主播打开了「同一网络的 ZuTalk 也能看」)。
    private var nearbyLive: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(String(localized: "nearby.watch.card_title"))
                .font(.bodyMedium)
                .foregroundColor(.textPrimary)
            Text(String(localized: "nearby.watch.card_detail"))
                .font(.bodySM)
                .foregroundColor(.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(nearby.liveNearby, id: \.deviceId) { peer in
                HStack(spacing: Spacing.sm) {
                    PulsingDot(color: .signalGreen, size: 7)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(peer.liveTitle ?? "")
                            .font(.bodySM)
                            .foregroundColor(.textPrimary)
                            .lineLimit(1)
                        Text(peer.name.isEmpty ? String(localized: "settings.devices.unnamed") : peer.name)
                            .font(.caption)
                            .foregroundColor(.textTertiary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if nearby.joining == peer.deviceId {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(String(localized: nearby.status?.watching == peer.deviceId
                            ? "nearby.watch.open"
                            : "nearby.watch.button")) {
                            if nearby.status?.watching == peer.deviceId {
                                WindowCoordinator.shared.presentNearbyLive()
                            } else {
                                nearby.watch(peer)
                            }
                        }
                        .disabled(nearby.joining != nil)
                    }
                }
            }
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard(
            fill: Color.bgElevated.opacity(0.4),
            cornerRadius: Radius.md,
            border: Color.borderSubtle,
            borderWidth: 0.5
        )
        .accessibilityIdentifier("record.page.nearby-live")
    }

    // MARK: 动作

    private func start() {
        guard let notebookId else { return }
        if topicId == nil {
            commands.startQuickCapture(profileEditor: editor)
            return
        }
        let starter = editor?.notebookId == notebookId
            ? editor!
            : NotebookCaptureProfileEditorModel(notebookId: notebookId)
        if starter !== editor { starter.load() }
        starter.retry()
        commands.start(notebookId: notebookId, profileEditor: starter)
    }

    private func chooseAudioToImport() {
        guard let notebookId else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.audio]
        panel.prompt = String(localized: "home.import.sheet.choose")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importer.importAudio(at: url, notebookId: notebookId)
    }

    /// A topic's own Record button chose the topic already.
    private func takePreselectedTopic() {
        guard let preselected = navigation.recordTopicPreselection else { return }
        navigation.recordTopicPreselection = nil
        topicId = preselected
    }

    private func syncEditor() {
        guard let notebookId else {
            editor = nil
            return
        }
        guard editor?.notebookId != notebookId else { return }
        let fresh = NotebookCaptureProfileEditorModel(notebookId: notebookId)
        fresh.load()
        editor = fresh
    }

    // MARK: 零件

    private func row<Control: View>(
        title: String,
        detail: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(alignment: .center, spacing: Spacing.md) {
            rowTitle(title, detail: detail)
            Spacer(minLength: Spacing.md)
            control()
        }
        .padding(Spacing.md)
    }

    private func rowTitle(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.bodyMedium)
                .foregroundColor(.textPrimary)
            Text(detail)
                .font(.bodySM)
                .foregroundColor(.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
