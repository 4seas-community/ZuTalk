// HomeStartCard.swift
// 首页最上面那张卡:开始一场录音。
//
// 「开始录音」以前是单独的一页,按钮前面摆着六样要定的事:放进哪个主题、归到
// 哪场活动、声音来源、几种语言和各自的角色、出不出字。每一样都有默认值,大多数
// 人一样都不用改,却得先看懂这一排才敢按开始。现在首页就是开始的地方:一个
// 按钮,下面一句话念出这一场会怎么录,旁边一个「更改」。要改的人点开,选项就在
// 这张卡里展开 —— 东西一样没少,只是往下放了一层
// (docs/product/interface-layers.md)。
//
// 菜单栏与 ⌃⌥R 是窗口外的两个快捷方式,用的是这里最后一次的选择(没放进主题的
// 那一份语言设置)。录音进行中,这张卡换成「正在录音 → 回到这场录音」,不出现
// 第二个开始按钮。

import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// What the start card remembers while the app runs, and no longer. Home is
/// rebuilt every time the sidebar leads back to it, so the card's own state
/// would forget that the options were open.
@MainActor
final class HomeStartCardMemory: ObservableObject {
    static let shared = HomeStartCardMemory()

    @Published var showsOptions = false
}

/// What the card says about filing this recording's transcript to a city.
///
/// The destination row is the per-recording confirmation of where the
/// transcript goes, so it is never tucked into the collapsed options: it
/// shows whenever hosting is on, and also when an event was already picked
/// for the next recording — turning the switch off must not hide a filing
/// that is going to happen (`HostMode.shows(inUse:)`).
nonisolated enum StartCardHosting: Equatable, Sendable {
    /// Hosting is off and nothing is set to be filed.
    case hidden
    /// Signed in: the row that names the event, or says none.
    case destination
    /// Hosting is on but nobody is signed in to a city.
    case signInHint

    static func resolve(hostingOn: Bool, signedIn: Bool, eventPicked: Bool) -> StartCardHosting {
        if signedIn {
            return hostingOn || eventPicked ? .destination : .hidden
        }
        return hostingOn ? .signInHint : .hidden
    }

    @MainActor
    static func current(hostMode: HostMode) -> StartCardHosting {
        let city = CityStore.shared
        let eventPicked: Bool
        if case .event = city.nextChoice { eventPicked = true } else { eventPicked = false }
        return resolve(
            hostingOn: hostMode.isOn,
            signedIn: city.account != nil,
            eventPicked: eventPicked
        )
    }
}

/// Whether a text field somewhere below is being typed in.
///
/// Home's Start button is the window's default action, and on the Mac the
/// Return key pressed in a text field reaches the default action. Now that
/// the button shares a page with the recordings' search field, someone who
/// types a search and presses Return must get a search, not a recording —
/// so every text field on Home reports its focus here, and the button gives
/// up Return while any of them has it.
nonisolated struct TextEntryFocusKey: PreferenceKey {
    static let defaultValue = false

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

struct HomeStartCard: View {
    /// Home's own library: the topics to choose from, and the notebook a
    /// recording in no topic is stored in.
    @ObservedObject var library: LibraryViewModel
    /// False while a text field on the page is being typed in; see
    /// `TextEntryFocusKey`.
    private let startsOnReturn: Bool

    @StateObject private var importer = NotebookResourcesViewModel()
    @ObservedObject private var memory = HomeStartCardMemory.shared
    // Only whether something records — the capture store itself changes on
    // every callback, and Home stays on screen during a recording.
    @ObservedObject private var captureActivity = ActiveBilingualTranscriptStore.shared.activity
    @ObservedObject private var commands: CaptureCommandCenter
    @ObservedObject private var navigation = MainNavigationStore.shared
    // Whether live text can run follows a saved key or an invite; both arrive
    // after launch, and neither is published by the command center.
    @ObservedObject private var invite = CommunityInviteSession.shared
    @ObservedObject private var credentials = ProviderCredentialSession.shared
    @ObservedObject private var inputDevices = AudioInputDeviceStore.shared
    @ObservedObject private var network = NetworkReachability.shared
    @ObservedObject private var hostMode: HostMode
    /// The topic this recording goes into; nil is none, and it can be put in
    /// one at any time afterwards.
    @State private var topicId: String?
    /// The languages edited here are the ones Start uses: recordings in no
    /// topic share one saved set, each topic has its own. The same instance
    /// serves the editor and the start, and Start saves whatever the editor
    /// has not written yet.
    @State private var editor: NotebookCaptureProfileEditorModel?
    @State private var isCreatingTopic = false

    /// The two switches the card throws both save what the person chose. The
    /// app passes neither and gets its own; a test passes ones that keep the
    /// choice to themselves, so showing a state never changes a real setting.
    init(
        library: LibraryViewModel,
        startsOnReturn: Bool = true,
        hostMode: HostMode? = nil,
        commands: CaptureCommandCenter? = nil
    ) {
        _library = ObservedObject(wrappedValue: library)
        self.startsOnReturn = startsOnReturn
        _hostMode = ObservedObject(wrappedValue: hostMode ?? .shared)
        _commands = ObservedObject(wrappedValue: commands ?? .shared)
    }

    private var notebookId: String? { topicId ?? library.quickCaptureNotebookId }

    private var topicTitle: String? {
        guard let topicId else { return nil }
        return library.researchNotebooks.first { $0.id == topicId }?.title
    }

    var body: some View {
        Group {
            if captureActivity.isCaptureActive {
                recordingNow
            } else {
                startCard
            }
        }
        .onAppear {
            takePreselectedTopic()
            syncEditor()
            inputDevices.refreshInBackground()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            inputDevices.refreshInBackground()
        }
        .montereyOnChange(of: navigation.recordTopicPreselection) { _, _ in
            takePreselectedTopic()
        }
        .montereyOnChange(of: library.quickCaptureNotebookId) { _, _ in syncEditor() }
        .montereyOnChange(of: topicId) { _, _ in syncEditor() }
        .montereyOnChange(of: library.researchNotebooks.map(\.id)) { _, topics in
            // A topic deleted elsewhere cannot receive the next recording.
            if let topicId, library.hasLoadedTopicMemberships, topics.contains(topicId) == false {
                self.topicId = nil
            }
        }
        .montereyOnChange(of: captureActivity.isCaptureActive) { _, active in
            // 一场录音可能推进了设置的版本;重新载入,选择器才不会拿旧版本去写。
            if active == false { editor?.load() }
        }
        .sheet(isPresented: $isCreatingTopic) {
            HomeCreateNotebookSheet { title in
                let created = library.createNotebook(title: title)
                // The view model selects what it just created.
                if created, let newTopicId = library.activeNotebookId {
                    topicId = newTopicId
                }
                return created
            }
        }
    }

    // MARK: 开始

    private var startCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Spacing.xsm) {
                startButton
                planLine

                // 没联网又要出字:按下开始之前就说清楚,别让人以为是服务坏了。
                if network.isOffline && commands.nextRecordingUsesCaptions {
                    Label(String(localized: "home.start.offline_hint"), systemImage: "wifi.slash")
                        .font(.bodySM)
                        .foregroundColor(.signalAmber)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("record.page.offline")
                }
            }
            .padding(Spacing.md)

            StartCardHostingSection(editor: editor, topicId: topicId, hostMode: hostMode)

            if memory.showsOptions {
                divider
                options
            }
        }
        .surfaceCard(
            fill: Color.bgElevated.opacity(0.4),
            cornerRadius: Radius.md,
            border: Color.borderSubtle,
            borderWidth: 0.5
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.start")
    }

    private var startButton: some View {
        Button(action: start) {
            Label(
                String(localized: commands.isStarting ? "home.record.starting" : "home.record.start"),
                systemImage: commands.isStarting ? "ellipsis" : "record.circle.fill"
            )
            .font(.titleMD)
            .frame(maxWidth: .infinity, minHeight: 52)
        }
        .buttonStyle(StartRecordingButtonStyle())
        .disabled(commands.isStarting || notebookId == nil)
        .keyboardShortcut(startsOnReturn ? .defaultAction : nil)
        .help(String(localized: "record.page.shortcut_hint"))
        .accessibilityIdentifier("record.page.start")
    }

    /// The one sentence, and the way to change what it says.
    private var planLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.md) {
            Group {
                if let editor {
                    StartPlanText(
                        editor: editor,
                        liveText: commands.nextRecordingUsesCaptions,
                        source: planSource,
                        topic: topicTitle
                    )
                } else {
                    // No saved languages to read yet: say the rest.
                    Text(RecordingPlanSentence.text(RecordingPlan(
                        spoken: [],
                        source: planSource,
                        liveText: commands.nextRecordingUsesCaptions,
                        topic: topicTitle
                    )))
                }
            }
            .font(.body)
            .foregroundColor(.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("home.start.plan")

            Spacer(minLength: Spacing.sm)

            Button {
                withAnimation(Motion.panelTransition) {
                    memory.showsOptions.toggle()
                }
            } label: {
                Text(String(localized: memory.showsOptions
                    ? "home.start.change_done"
                    : "home.start.change"))
                    .font(.bodyMedium)
                    .foregroundColor(.brandAccent)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .help(String(localized: "home.start.change_hint"))
            .accessibilityHint(Text(String(localized: "home.start.change_hint")))
            .accessibilityIdentifier("home.start.change")
        }
    }

    private var planSource: RecordingPlan.Source {
        if inputDevices.isSystemAudioSelected { return .soundFromMac }
        // Following the system default is "this Mac's microphone"; a
        // microphone picked by hand is named, so a headset left selected is
        // noticed before the recording, not after.
        guard inputDevices.selectedUID != nil else { return .thisMac }
        return .microphone(
            inputDevices.selectedDevice?.name ?? inputDevices.selectedDeviceLastKnownName ?? ""
        )
    }

    // MARK: 更改

    private var options: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                rowTitle(
                    String(localized: "home.options.languages"),
                    detail: String(localized: "home.options.languages_detail")
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

            divider

            // 会议录音还是麦克风录音,开始之前就定:线上会议里对方的声音
            // 从扬声器出来,麦克风收不到,只能录这台 Mac 播放的声音。
            if let notebookId {
                row(title: String(localized: "record.page.input"), detail: inputDetail) {
                    AudioInputPicker(notebookId: notebookId, width: 240)
                }
                .accessibilityIdentifier("record.page.input")

                divider
            }

            liveTextRow

            divider

            row(
                title: String(localized: "home.options.topic"),
                detail: String(localized: "home.options.topic_detail")
            ) {
                topicPicker
            }

            divider

            row(
                title: String(localized: "home.options.hosting"),
                detail: String(localized: "home.options.hosting_detail")
            ) {
                Toggle("", isOn: Binding(
                    get: { hostMode.isOn },
                    set: { hostMode.set($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel(Text(String(localized: "home.options.hosting")))
                .accessibilityIdentifier("home.options.hosting")
            }

            divider

            importRow
        }
    }

    private var inputDetail: String {
        if inputDevices.isSystemAudioSelected {
            return String(localized: "record.page.input_detail_system_audio")
        }
        return String(localized: inputDevices.isSystemAudioSupported
            ? "home.options.source_detail_microphone_or_mac"
            : "record.page.input_detail_microphone")
    }

    /// Text while recording means the sound leaves this Mac, so the switch
    /// says so where it is thrown. Without a way to get text there is nothing
    /// to switch: the row says what is missing and leads to where it is added.
    private var liveTextRow: some View {
        let available = commands.realtimeCredentialAvailable
        return VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(alignment: .center, spacing: Spacing.md) {
                rowTitle(
                    String(localized: "home.options.live_text"),
                    detail: String(localized: available
                        ? "home.options.live_text_detail"
                        : "home.options.live_text_needs_setup")
                )
                Spacer(minLength: Spacing.md)
                if available {
                    Toggle("", isOn: Binding(
                        get: { commands.realtimeCaptionsEnabled },
                        set: { commands.setRealtimeCaptionsEnabled($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityLabel(Text(String(localized: "home.options.live_text")))
                    .accessibilityIdentifier("home.options.live-text")
                } else {
                    Button(String(localized: "home.options.live_text_setup")) {
                        MainNavigationStore.shared.openSettings(section: .account)
                    }
                    .accessibilityIdentifier("home.options.live-text.setup")
                }
            }
            // An invite is spent by the hour: how long it lasts is said
            // where the time is about to be used.
            if let inviteTime = inviteTimeLeft, available, commands.realtimeCaptionsEnabled {
                Text(String(format: String(localized: "home.options.live_text_invite_format"), inviteTime))
                    .font(.bodySM)
                    .foregroundColor(.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Spacing.md)
    }

    private var inviteTimeLeft: String? {
        guard invite.isEnabled, invite.isActive, let remaining = invite.remainingSeconds else {
            return nil
        }
        let recordable = CommunityInviteSession.wallClockRecordableSeconds(
            remainingSeconds: remaining,
            laneCount: invite.plannedLaneCount
        )
        return RecordingPresentation.duration(ms: UInt64(max(recordable, 0)) * 1_000)
    }

    private enum TopicChoice: Hashable {
        case none
        case topic(String)
        case new
    }

    private var topicPicker: some View {
        Picker("", selection: Binding<TopicChoice>(
            get: { topicId.map(TopicChoice.topic) ?? .none },
            set: { choice in
                switch choice {
                case .none:
                    topicId = nil
                case .topic(let id):
                    topicId = id
                case .new:
                    // The menu is still closing; the sheet waits a turn.
                    DispatchQueue.main.async { isCreatingTopic = true }
                }
            }
        )) {
            Text(String(localized: "home.options.topic.none")).tag(TopicChoice.none)
            if library.researchNotebooks.isEmpty == false {
                Divider()
            }
            ForEach(library.researchNotebooks, id: \.id) { notebook in
                Text(notebook.title).tag(TopicChoice.topic(notebook.id))
            }
            Divider()
            Text(String(localized: "home.options.topic.new")).tag(TopicChoice.new)
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(maxWidth: 240, alignment: .trailing)
        .accessibilityLabel(Text(String(localized: "home.options.topic")))
        .accessibilityIdentifier("record.page.topic")
    }

    private var importRow: some View {
        Button {
            chooseAudioToImport()
        } label: {
            Label(
                String(localized: importer.isImportingAudio
                    ? "record.page.importing"
                    : "home.options.import"),
                systemImage: "square.and.arrow.down"
            )
            .font(.bodySM)
            .foregroundColor(.textSecondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(importer.isImportingAudio || notebookId == nil)
        .help(String(localized: "record.page.import_detail"))
        .padding(Spacing.md)
        .accessibilityIdentifier("record.page.import")
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

    // MARK: 动作

    private func start() {
        guard let notebookId else { return }
        // 「归到活动」那一行此刻写着什么,按下开始就是确认了什么。那一行没摆
        // 出来(没在主持)就什么也没确认:替人选的那场活动不能在没人看着的
        // 时候绑上去,这一次和快捷键开的录音一样,只认人自己挑好的那一场。
        if StartCardHosting.current(hostMode: hostMode) == .destination {
            CityStore.shared.confirmNextDestination()
        }
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

    /// A topic's own Record button chose the topic already. The options open
    /// so the person sees where this recording is going.
    private func takePreselectedTopic() {
        guard let preselected = navigation.recordTopicPreselection else { return }
        navigation.recordTopicPreselection = nil
        // A recording page that belongs to no topic has nothing to choose.
        topicId = preselected == library.quickCaptureNotebookId ? nil : preselected
        memory.showsOptions = topicId != nil || memory.showsOptions
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

    private var divider: some View {
        Divider().padding(.horizontal, Spacing.md)
    }

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

/// The sentence follows the languages as they are edited, so it watches the
/// saved set itself; everything else it says is handed in.
private struct StartPlanText: View {
    @ObservedObject var editor: NotebookCaptureProfileEditorModel
    let liveText: Bool
    let source: RecordingPlan.Source
    let topic: String?

    var body: some View {
        let languages = RecordingPlanSentence.languages(
            selected: editor.draft.selectedLanguages,
            subtitleOnly: editor.draft.subtitleOnlyLanguages
        )
        Text(RecordingPlanSentence.text(RecordingPlan(
            spoken: languages.spoken,
            translatedInto: languages.translatedInto,
            source: source,
            liveText: liveText,
            topic: topic
        )))
        .onAppear { publishPlannedLaneCount() }
        .montereyOnChange(of: editor.draft.selectedLanguages) { _, _ in publishPlannedLaneCount() }
        .montereyOnChange(of: editor.draft.subtitleOnlyLanguages) { _, _ in publishPlannedLaneCount() }
        .montereyOnChange(of: liveText) { _, _ in publishPlannedLaneCount() }
    }

    /// Invite time is shared between the connections a recording opens, so
    /// "about this long left" — here and in the sidebar — is only right for
    /// the languages chosen now. A topic's toolbar reports the same number.
    private func publishPlannedLaneCount() {
        CommunityInviteSession.shared.updatePlannedLaneCount(
            liveText
                ? NotebookCaptureStartPreparationWorkflow.remoteLaneCount(
                    selectedLanguages: editor.draft.selectedLanguages,
                    subtitleOnlyLanguages: editor.draft.subtitleOnlyLanguages
                )
                : 1
        )
    }
}

/// Where this recording's transcript will be filed, for someone hosting an
/// event. Its own view so the card does not follow `CityStore`.
private struct StartCardHostingSection: View {
    let editor: NotebookCaptureProfileEditorModel?
    let topicId: String?
    @ObservedObject var hostMode: HostMode
    @ObservedObject private var city = CityStore.shared

    var body: some View {
        switch StartCardHosting.current(hostMode: hostMode) {
        case .hidden:
            EmptyView()
        case .destination:
            VStack(alignment: .leading, spacing: 0) {
                Divider().padding(.horizontal, Spacing.md)
                CityDestinationRow(editor: editor, topicId: topicId)
            }
        case .signInHint:
            VStack(alignment: .leading, spacing: 0) {
                Divider().padding(.horizontal, Spacing.md)
                HStack(alignment: .firstTextBaseline, spacing: Spacing.md) {
                    Label(String(localized: "home.hosting.sign_in_hint"), systemImage: "building.columns")
                        .font(.bodySM)
                        .foregroundColor(.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: Spacing.sm)
                    Button(String(localized: "home.hosting.sign_in_button")) {
                        MainNavigationStore.shared.openSettings(section: .account)
                    }
                    .accessibilityIdentifier("home.hosting.sign-in")
                }
                .padding(Spacing.md)
            }
        }
    }
}

/// The one filled button on Home. Brand green rather than alarm red: red is
/// for the recording in progress.
private struct StartRecordingButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration)
    }

    /// A view of its own, so the enabled state is read where SwiftUI keeps
    /// it current on every system this runs on.
    private struct Face: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .foregroundColor(.brandAccentForeground)
                .background(
                    configuration.isPressed || isHovering
                        ? Color.brandAccentHover
                        : Color.brandAccent
                )
                .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
                .contentShape(RoundedRectangle(cornerRadius: Radius.sm))
                .opacity(isEnabled ? 1 : 0.5)
                .onHover { isHovering = $0 && isEnabled }
                .animation(Motion.microInteraction, value: isHovering)
        }
    }
}

// MARK: - 附近正在直播

/// 同一网络里有 ZuTalk 在给观众看字幕(主持的人打开了「同一网络的 ZuTalk 也能
/// 看」)。只有附近真有人在播时才出现;自己一个视图,首页不用跟着 `NearbyStore`。
struct HomeNearbyLiveCard: View {
    @ObservedObject private var nearby = NearbyStore.shared

    var body: some View {
        if nearby.liveNearby.isEmpty == false {
            card
        }
    }

    private var card: some View {
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
}
