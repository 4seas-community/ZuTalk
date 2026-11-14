// HomeStartCard.swift
// 首页最上面那张卡:开始一场录音。
//
// 0.8.2 把开始之前要定的几样事收成一句话,旁边一个「更改」,点开才看得到选项。
// 用下来有三处不对:改语言是最常做的事,却要先点开;那个「更改」不显眼,很多
// 人不知道能点;点开以后每一样下面都挂着一两句解释,看着累。
//
// 现在这张卡不藏东西,也不写句子(docs/product/interface-layers.md「界面怎么
// 写」)。按钮下面是几排胶囊(`DesignSystem/Primitives/Pills.swift`),每一颗就是
// 一个控件,上面写着它此刻的值,一个词:第一排是语言,直接增删,末尾是「导入」;
// 第二排是声音、主题、主持活动;在主持的时候才有第三排,放这一场归到哪场活动
// (没登录就是「登录」)。主持的东西单占一排,第二排的宽度就不随它变,窗口最窄的
// 时候每一颗也都在眼前,不用横着滚。
//
// 出不出字不在这张卡上选(0.8.4,负责人的原话:「默认录音就是出字，不需要有
// 这个可配置的。」):有邀请码或自己的密钥就出字。只有出不了字的时候,声音那一颗
// 后面才多出一样 —— 还没设置,是一颗去设置的胶囊;没联网,是一个状态
// (`LiveTextNotice`)。
//
// 原来那些句子一句没丢:整场会怎么录、出字时音频会发到哪里(这是告知,设置 ›
// 账号「出字」旁的 ⓘ 里也有)、邀请码还能录多久,在开始按钮的提示里;主持活动
// 多出什么、为什么是这场活动,在各自胶囊的提示里;这场会交什么到档案馆,在活动
// 那颗胶囊旁边的 ⓘ 里。
//
// 菜单栏与 ⌃⌥R 是窗口外的两个快捷方式,用的是这里最后一次的选择(没放进主题的
// 那一份语言设置)。录音进行中,这张卡换成「正在录音 → 回到这场录音」,不出现
// 第二个开始按钮。

import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// What the card shows about filing this recording's transcript to a city.
///
/// The event pill is the per-recording confirmation of where the transcript
/// goes: it shows whenever hosting is on, and also when an event was already
/// picked for the next recording — turning the switch off must not hide a
/// filing that is going to happen (`HostMode.shows(inUse:)`). Pressing Start
/// confirms an event only while that pill is on screen.
nonisolated enum StartCardHosting: Equatable, Sendable {
    /// Hosting is off and nothing is set to be filed.
    case hidden
    /// Signed in: the pill that names the event, or offers to choose one.
    case destination
    /// Hosting is on but nobody is signed in: a pill that leads to signing in.
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
    @ObservedObject private var hostMode: HostMode
    /// The topic this recording goes into; nil is none, and it can be put in
    /// one at any time afterwards.
    @State private var topicId: String?
    /// The languages edited here are the ones Start uses: recordings in no
    /// topic share one saved set, each topic has its own. The same instance
    /// serves the pills and the start, and Start saves whatever the pills
    /// have not written yet.
    @State private var editor: NotebookCaptureProfileEditorModel?
    @State private var isCreatingTopic = false

    /// A live-text state to draw instead of the real one.
    private let shownLiveText: StartCardLiveText?

    /// The hosting switch saves what the person chose, and whether there is
    /// live text follows a key or an invite. The app passes none of these
    /// and gets its own; a test passes a switch that keeps the choice to
    /// itself and the state to draw, so showing a state never changes a real
    /// setting.
    init(
        library: LibraryViewModel,
        startsOnReturn: Bool = true,
        hostMode: HostMode? = nil,
        commands: CaptureCommandCenter? = nil,
        shownLiveText: StartCardLiveText? = nil
    ) {
        _library = ObservedObject(wrappedValue: library)
        self.startsOnReturn = startsOnReturn
        _hostMode = ObservedObject(wrappedValue: hostMode ?? .shared)
        _commands = ObservedObject(wrappedValue: commands ?? .shared)
        self.shownLiveText = shownLiveText
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
            // 一场录音可能推进了设置的版本;重新载入,胶囊才不会拿旧版本去写。
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

    /// The button, then strips of pills. Nothing is hidden and nothing is
    /// explained in place: a pill is a control, and what it shows is its
    /// value.
    private var startCard: some View {
        Group {
            if let editor {
                // The languages decide the button's tooltip and what an
                // event would be handed, so this part follows them.
                StartCardDraftReader(editor: editor) { draft in
                    controls(draft: draft)
                }
            } else {
                controls(draft: nil)
            }
        }
        .padding(Spacing.md)
        .surfaceCard(
            fill: Color.bgElevated.opacity(0.4),
            cornerRadius: Radius.md,
            border: Color.borderSubtle,
            borderWidth: 0.5
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.start")
    }

    /// Whether the next recording will have live text. Read through the
    /// invite and the key store this card observes, so it is current.
    private var liveText: Bool {
        let _ = credentials.statusRevision
        if let shownLiveText { return shownLiveText != .needsSetup }
        return commands.nextRecordingUsesCaptions
    }

    private func controls(draft: NotebookCaptureProfileDTO?) -> some View {
        let liveText = self.liveText
        let languages = draft?.selectedLanguages ?? []
        return VStack(alignment: .leading, spacing: Spacing.xsm) {
            startButton(explanation: startExplanation(draft: draft, liveText: liveText))

            languageStrip

            optionStrip

            // Only while hosting shows, and on a row of its own: the row
            // above keeps its width whatever is being hosted.
            StartCardHostingPills(languages: languages, topicId: topicId, hostMode: hostMode)
        }
        .onAppear { publishPlannedLaneCount(draft: draft, liveText: liveText) }
        .montereyOnChange(of: draft?.selectedLanguages) { _, _ in
            publishPlannedLaneCount(draft: draft, liveText: liveText)
        }
        .montereyOnChange(of: draft?.subtitleOnlyLanguages) { _, _ in
            publishPlannedLaneCount(draft: draft, liveText: liveText)
        }
        .montereyOnChange(of: liveText) { _, liveText in
            publishPlannedLaneCount(draft: draft, liveText: liveText)
        }
    }

    /// What the Start button says to whoever asks: how this recording will
    /// be made, then — when it will have live text — where the audio goes
    /// and how long the invite lasts.
    private func startExplanation(draft: NotebookCaptureProfileDTO?, liveText: Bool) -> String {
        ([planSentence(draft: draft, liveText: liveText)]
            + LiveTextStartHint.lines(liveText: liveText, invite: invite))
            .joined(separator: "\n")
    }

    private func startButton(explanation: String) -> some View {
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
        // How this recording will be made, and that its audio is sent away
        // to be written down — said to whoever asks (hover, VoiceOver)
        // instead of being printed under the button.
        .help(explanation + "\n" + String(localized: "record.page.shortcut_hint"))
        .accessibilityHint(Text(explanation))
        .accessibilityIdentifier("record.page.start")
    }

    private func planSentence(draft: NotebookCaptureProfileDTO?, liveText: Bool) -> String {
        let languages = draft.map {
            RecordingPlanSentence.languages(
                selected: $0.selectedLanguages,
                subtitleOnly: $0.subtitleOnlyLanguages
            )
        }
        return RecordingPlanSentence.text(RecordingPlan(
            // No saved languages to read yet: the sentence says the rest.
            spoken: languages?.spoken ?? [],
            translatedInto: languages?.translatedInto ?? [],
            source: planSource,
            liveText: liveText,
            topic: topicTitle
        ))
    }

    /// Invite time is shared between the connections a recording opens, so
    /// "about this long left" — in the Start button's tooltip and in the
    /// sidebar — is only right for the languages chosen now. A topic's
    /// toolbar reports the same number.
    private func publishPlannedLaneCount(draft: NotebookCaptureProfileDTO?, liveText: Bool) {
        guard let draft else { return }
        CommunityInviteSession.shared.updatePlannedLaneCount(
            liveText
                ? NotebookCaptureStartPreparationWorkflow.remoteLaneCount(
                    selectedLanguages: draft.selectedLanguages,
                    subtitleOnlyLanguages: draft.subtitleOnlyLanguages
                )
                : 1
        )
    }

    private var planSource: RecordingPlan.Source {
        if inputDevices.isSystemAudioSelected { return .soundFromMac }
        // Following the system default is "the microphone"; one picked by
        // hand is named, so a headset left selected is noticed before the
        // recording, not after.
        guard inputDevices.selectedUID != nil else { return .thisMac }
        return .microphone(
            inputDevices.selectedDevice?.name ?? inputDevices.selectedDeviceLastKnownName ?? ""
        )
    }

    // MARK: 第一排:语言,末尾是导入

    /// The languages, edited in place. At the far end, the other way a
    /// recording gets here: bringing in one made elsewhere. It sits on this
    /// row because this row always has room for it.
    private var languageStrip: some View {
        PillStrip {
            if let editor {
                CaptureLanguagePills(editor: editor)
                    .disabled(editor.canEdit == false)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(Text(String(localized: "home.options.languages")))
                    .accessibilityIdentifier("record.page.languages")
            }
        } trailing: {
            importPill
        }
    }

    // MARK: 第二排:声音、主题、主持活动

    /// How this recording is made. Three pills whose words are ours, so the
    /// row fits the narrowest window in every language; a topic's or a
    /// device's name gives way before it would scroll. Live text is not one
    /// of them: after the sound pill there is something only when text
    /// cannot be produced (`LiveTextNotice`).
    private var optionStrip: some View {
        PillStrip {
            // 会议录音还是麦克风录音,开始之前就定:线上会议里对方的声音
            // 从扬声器出来,麦克风收不到,只能录这台 Mac 播放的声音。
            if let notebookId {
                AudioInputPill(notebookId: notebookId, source: planSource)
                    .accessibilityIdentifier("record.page.input")
            }
            LiveTextNotice(commands: commands, shown: shownLiveText)
            topicPill
            hostingPill
        }
    }

    private var topicPill: some View {
        MenuPill(
            StartCardTopic.title(topicTitle),
            titleIsName: StartCardTopic.label(topicTitle) != nil,
            systemImage: "folder",
            help: String(localized: "home.options.topic_detail"),
            accessibilityLabel: String(localized: "home.options.topic"),
            accessibilityValue: topicTitle ?? String(localized: "home.options.topic.none")
        ) {
            var items = [PillMenuItem(
                String(localized: "home.options.topic.none"),
                isOn: topicId == nil
            ) { topicId = nil }]
            if library.researchNotebooks.isEmpty == false {
                items.append(.separator)
            }
            for notebook in library.researchNotebooks {
                items.append(PillMenuItem(notebook.title, isOn: topicId == notebook.id) {
                    topicId = notebook.id
                })
            }
            items.append(.separator)
            items.append(PillMenuItem(String(localized: "home.options.topic.new")) {
                // The menu is still closing; the sheet waits a turn.
                DispatchQueue.main.async { isCreatingTopic = true }
            })
            return items
        }
        .accessibilityIdentifier("record.page.topic")
    }

    private var hostingPill: some View {
        let title = String(localized: "home.card.hosting")
        return TogglePill(
            isOn: hostMode.isOn,
            on: .init(title, systemImage: "person.wave.2.fill"),
            off: .init(title, systemImage: "person.wave.2"),
            help: String(localized: "home.options.hosting_detail")
        ) {
            hostMode.set(!hostMode.isOn)
        }
        .accessibilityIdentifier("home.options.hosting")
    }

    /// Quiet, at the far end of the first row: bringing in a recording made
    /// elsewhere is not part of deciding how this one is made.
    private var importPill: some View {
        ActionPill(
            String(localized: importer.isImportingAudio
                ? "record.page.importing"
                : "home.import.sheet.confirm"),
            systemImage: "square.and.arrow.down",
            style: .quiet,
            help: String(localized: "record.page.import_detail"),
            accessibilityLabel: String(localized: "home.options.import")
        ) {
            chooseAudioToImport()
        }
        .disabled(importer.isImportingAudio || notebookId == nil)
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
            Button {
                MainNavigationStore.shared.openLiveRecording()
            } label: {
                Label(String(localized: "record.page.open_recording"), systemImage: "arrow.right.circle")
                    .frame(minHeight: PillMetrics.height)
            }
            .buttonStyle(.borderedProminent)
            // Where Pause, Mark and Stop are: said on request, not printed.
            .help(String(localized: "record.page.recording_now_detail"))
            .accessibilityHint(Text(String(localized: "record.page.recording_now_detail")))
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
        // 活动那一颗胶囊此刻写着什么,按下开始就是确认了什么。那一颗没摆出来
        // (没在主持)就什么也没确认:替人选的那场活动不能在没人看着的时候
        // 绑上去,这一次和快捷键开的录音一样,只认人自己挑好的那一场。
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

    /// A topic's own Record button chose the topic already: it is simply
    /// what the topic pill says when Home appears.
    private func takePreselectedTopic() {
        guard let preselected = navigation.recordTopicPreselection else { return }
        navigation.recordTopicPreselection = nil
        // A recording page that belongs to no topic has nothing to choose.
        topicId = preselected == library.quickCaptureNotebookId ? nil : preselected
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
}

/// Hands its content the saved languages and builds it again whenever they
/// change, so the card itself need not hold the editor as an observed object
/// (it has none until the library has loaded).
private struct StartCardDraftReader<Content: View>: View {
    @ObservedObject var editor: NotebookCaptureProfileEditorModel
    @ViewBuilder let content: (NotebookCaptureProfileDTO) -> Content

    var body: some View {
        content(editor.draft)
    }
}

/// The card's third row, there only while hosting shows: the event this
/// recording will be filed under, or the way to sign in. Nothing — no row, no
/// gap — otherwise. Its own view so the card does not follow `CityStore`.
private struct StartCardHostingPills: View {
    let languages: [String]
    let topicId: String?
    @ObservedObject var hostMode: HostMode
    @ObservedObject private var city = CityStore.shared

    var body: some View {
        switch StartCardHosting.current(hostMode: hostMode) {
        case .hidden:
            EmptyView()
        case .destination:
            PillStrip {
                CityDestinationPill(languages: languages, topicId: topicId)
            }
        case .signInHint:
            PillStrip {
                ActionPill(
                    String(localized: "sidebar.account.sign_in"),
                    systemImage: "person.crop.circle",
                    help: String(localized: "home.hosting.sign_in_hint")
                ) {
                    MainNavigationStore.shared.openSettings(section: .account)
                }
                .accessibilityIdentifier("home.hosting.sign-in")
            }
        }
    }
}

// MARK: - 胶囊上写什么

/// What the sound pill shows for each source.
nonisolated enum StartCardSound: Equatable, Sendable {
    case microphone
    case soundFromMac
    /// A microphone picked by hand, by its name.
    case device(String)

    static func resolve(_ source: RecordingPlan.Source) -> StartCardSound {
        switch source {
        case .thisMac:
            return .microphone
        case .soundFromMac:
            return .soundFromMac
        case .microphone(let name):
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? .microphone : .device(name)
        }
    }

    /// The key of the word on the pill; nil when the pill shows a name.
    var labelKey: String? {
        switch self {
        case .microphone: return "permission.microphone.name"
        case .soundFromMac: return "home.card.sound_from_mac"
        case .device: return nil
        }
    }

    var systemImage: String {
        self == .soundFromMac ? "speaker.wave.2.fill" : "mic.fill"
    }

    var title: String {
        if case .device(let name) = self { return name }
        return String(localized: String.LocalizationValue(labelKey ?? "permission.microphone.name"))
    }
}

/// What the topic pill shows: the topic's name, or the one word that says
/// what the pill is for.
nonisolated enum StartCardTopic {
    static let placeholderKey = "sidebar.notebook"

    static func title(_ chosen: String?) -> String {
        label(chosen) ?? String(localized: String.LocalizationValue(placeholderKey))
    }

    /// The chosen topic's own title, or nil when the placeholder applies.
    static func label(_ chosen: String?) -> String? {
        guard let chosen = chosen?.trimmingCharacters(in: .whitespacesAndNewlines),
              chosen.isEmpty == false
        else { return nil }
        return chosen
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
                .help(String(localized: "nearby.watch.card_detail"))
                .accessibilityHint(Text(String(localized: "nearby.watch.card_detail")))
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
                        ActionPill(
                            String(localized: nearby.status?.watching == peer.deviceId
                                ? "nearby.watch.open"
                                : "nearby.watch.button"),
                            systemImage: "captions.bubble",
                            help: String(localized: "nearby.watch.card_detail")
                        ) {
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
