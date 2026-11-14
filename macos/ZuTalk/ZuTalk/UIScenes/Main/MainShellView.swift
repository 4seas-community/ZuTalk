import AppKit
import Combine
import SwiftUI

struct MainShellView: View {
    @ObservedObject private var softwareUpdate = SoftwareUpdateController.shared
    @ObservedObject private var store: MainNavigationStore
    @ObservedObject private var communityInvite = CommunityInviteSession.shared
    @ObservedObject private var shareActivity = ShareActivityStore.shared
    // Only whether something records. The capture store itself changes on
    // every callback and every second, and observing it here re-evaluated
    // the whole window each time.
    @ObservedObject private var captureActivity = ActiveBilingualTranscriptStore.shared.activity
    @State private var isSidebarHidden = false
    @State private var renamingRecording: EditorBreadcrumb.Recording?

    init(store: MainNavigationStore) {
        self._store = ObservedObject(wrappedValue: store)
    }

    private var activeTab: MainTab { store.activeTab }
    private var needsOnboarding: Bool { store.needsOnboarding }
    private var activeEditorRoute: EditorRoute? { store.activeEditorRoute }
    private var pendingEditorView: EditorInitialView { store.pendingEditorView }

    var body: some View {
        ZStack {
            if needsOnboarding {
                OnboardingView(onComplete: {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        store.completeOnboarding()
                    }
                })
                .transition(.opacity)
            } else {
                mainContent
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.bgRoot.ignoresSafeArea())
        .toastOverlay()
        // "Filed in the archive", with its Open button; see `CityNoticeOverlay`.
        .cityNoticeOverlay()
        .onAppear {
            store.recordSnapshot()
            // 主窗口关了又开时,接上核心里还在跑的直播。
            ShareActivityStore.shared.start()
        }
        .task(id: needsOnboarding) {
            guard needsOnboarding == false else { return }
            for attempt in 0..<3 {
                if store.restoreLastNotebookOnLaunch() {
                    return
                }
                guard attempt < 2 else { return }
                do {
                    try await Task.sleep(nanoseconds: 100_000_000)
                } catch {
                    return
                }
            }
        }
    }

    private var mainContent: some View {
        HStack(spacing: 0) {
            if isSidebarHidden == false {
                expandedSidebar
                    .frame(width: 248)
                    .background(Color.bgSunken)
                    .overlay(
                        Rectangle()
                            .fill(Color.borderGhost.opacity(0.3))
                            .frame(width: 0.5),
                        alignment: .trailing
                    )
            }

            contentArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.bgRoot)
    }

    private var expandedSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: 38)

            sidebarHeader
                .padding(.horizontal, Spacing.md)
                .padding(.top, Spacing.sm)
                .padding(.bottom, Spacing.md)

            Spacer().frame(height: Spacing.md)

            VStack(alignment: .leading, spacing: 2) {
                liveRecordingSidebarItem

                // Home is where a recording starts and where recordings are
                // kept, so it is first; there is no separate Record item.
                sidebarItem(
                    icon: "waveform",
                    label: String(localized: "sidebar.home"),
                    active: store.activePrimaryTab == .home,
                    accId: AccessibilityID.mainTabHome
                ) {
                    store.select(tab: .home)
                }

                // Topics are optional: the entry appears with the first topic.
                SidebarTopicsGate(
                    isCurrent: store.activePrimaryTab == .topics,
                    refreshOn: store.activeTab
                ) {
                    sidebarItem(
                        icon: "folder.fill",
                        label: String(localized: "sidebar.topics"),
                        active: store.activePrimaryTab == .topics,
                        accId: AccessibilityID.mainTabTopics
                    ) {
                        store.select(tab: .topics)
                    }
                }
            }
            .padding(.horizontal, Spacing.sm)

            Spacer().frame(height: Spacing.md)

            VStack(alignment: .leading, spacing: 2) {
                sidebarItem(
                    icon: "trash",
                    label: String(localized: "sidebar.trash"),
                    active: activeTab == .trash,
                    accId: AccessibilityID.mainTabTrash
                ) {
                    store.select(tab: .trash)
                }

                sidebarItem(
                    icon: "gearshape.fill",
                    label: String(localized: "sidebar.tab.settings"),
                    active: activeTab == .config,
                    accId: AccessibilityID.mainTabConfig
                ) {
                    store.openSettings()
                }
            }
            .padding(.horizontal, Spacing.sm)

            Spacer()

            sidebarFooter
                .padding(.horizontal, Spacing.md)
                .padding(.bottom, Spacing.md)
        }
    }

    /// 录音进行中,侧栏最上面多出「正在录音」,点它回到那场录音 —— 人翻到
    /// 别的页面以后就靠它回来。没在录的时候不占位置:开始录音在首页。
    @ViewBuilder
    private var liveRecordingSidebarItem: some View {
        if captureActivity.isCaptureActive {
            SidebarLiveRecordingItem(store: store)
        }
    }

    private var sidebarHeader: some View {
        HStack(spacing: Spacing.sm) {
            sidebarBrand

            Spacer(minLength: Spacing.sm)

            sidebarCollapseButton
        }
    }

    private var sidebarBrand: some View {
        HStack(spacing: Spacing.sm) {
            Image("ZuTalkMark")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundColor(.brandAccent)
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)

            Text("ZuTalk")
                .font(.brandCaption)
                .tracking(1.4)
                .foregroundColor(.textPrimary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("ZuTalk")
    }

    private var sidebarCollapseButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.16)) {
                isSidebarHidden = true
            }
        } label: {
            Image(systemName: "sidebar.left")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.textSecondary)
                .frame(width: 28, height: 28)
                .background(Color.bgElevated)
                .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
        }
        .buttonStyle(.plain)
        .help(String(localized: "sidebar.collapse"))
        .accessibilityLabel(String(localized: "sidebar.collapse"))
        .accessibilityIdentifier("sidebar.collapse")
    }

    @ViewBuilder
    private func sidebarItem(
        icon: String,
        label: String,
        active: Bool,
        accId: String?,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: Spacing.sm + 2) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(active ? .brandAccent : .textSecondary)
                    .frame(width: 18)
                Text(label)
                    .font(.body)
                    .foregroundColor(active ? .textPrimary : .textSecondary)
                Spacer()
            }
            .padding(.horizontal, Spacing.sm + 2)
            .frame(minHeight: 44)
            .background(active ? Color.bgElevated.opacity(0.5) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(active ? .isSelected : [])
        .accessibilityIdentifier(accId ?? "")
    }

    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Rectangle()
                .fill(Color.borderGhost.opacity(0.4))
                .frame(height: 0.5)

            softwareUpdateRow

            // Transcripts still waiting to reach the city's archive, or that
            // could not be filed. Absent when signed out or all is well; its
            // own view, so the window does not follow `CityStore`.
            CitySidebarLine {
                store.openSettings(section: .account)
            }

            // Invite time left: the gift and how long. What the number
            // means, and how it is spent, is the tooltip.
            if communityInvite.isEnabled, communityInvite.isActive {
                Label(
                    communityTimeLabel,
                    systemImage: "gift.fill"
                )
                .font(.bodySM)
                .foregroundColor(.textSecondary)
                .help(communityTimeExplanation)
                .accessibilityLabel(Text(communityTimeSentence ?? communityTimeLabel))
                .accessibilityHint(Text(String(localized: "community_invite.remaining_recordable_hint")))
                .accessibilityIdentifier("sidebar.community-invite.remaining")
                .task { await communityInvite.refreshQuota() }
            }

            Label(
                String(localized: "sidebar.local_first"),
                systemImage: "lock.shield.fill"
            )
            .font(.bodySM)
            .foregroundColor(.textSecondary)
            .frame(minHeight: 36)

            // Who is signed in, or the way to sign in. Last, where a Mac app
            // keeps its account; its own view, so the window does not follow
            // `CityStore`.
            SidebarAccountRow()
        }
        // The update row appears and swaps states on its own schedule; without
        // this the footer would jump under the user's cursor.
        .animation(Motion.panelTransition, value: softwareUpdate.activity)
    }

    /// The only place a background update ever surfaces: a progress row while
    /// the new version downloads, then a relaunch action once it is staged.
    /// Nothing appears while the app is merely checking, and nothing appears
    /// when a check finds nothing or fails.
    @ViewBuilder
    private var softwareUpdateRow: some View {
        switch softwareUpdate.activity {
        case .idle:
            EmptyView()

        case .downloading(let fraction):
            updateProgressRow(
                label: String(localized: "updates.downloading"),
                fraction: fraction
            )
            .accessibilityIdentifier("sidebar.update-progress")

        case .preparing:
            updateProgressRow(
                label: String(localized: "updates.preparing"),
                fraction: nil
            )
            .accessibilityIdentifier("sidebar.update-progress")

        case .readyToRelaunch:
            Button {
                softwareUpdate.installUpdateAndRelaunch()
            } label: {
                Label(
                    String(localized: "updates.install_and_relaunch"),
                    systemImage: "arrow.down.circle.fill"
                )
                .font(.bodySM)
                .foregroundColor(.brandAccent)
                .frame(minHeight: 36)
            }
            .buttonStyle(.plain)
            .help(String(localized: "updates.install_and_relaunch.hint"))
            .accessibilityIdentifier("sidebar.update-and-relaunch")
            .transition(.opacity)
        }
    }

    /// A determinate bar once the server reports a size, an indeterminate one
    /// until then — a bar pinned at zero reads as a stall.
    private func updateProgressRow(label: String, fraction: Double?) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.xs) {
                Text(label)
                    .font(.bodySM)
                    .foregroundColor(.textSecondary)
                Spacer()
                if let fraction {
                    Text(fraction, format: .percent.precision(.fractionLength(0)))
                        .font(.bodySM)
                        .monospacedDigit()
                        .foregroundColor(.textSecondary)
                }
            }

            Group {
                if let fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView()
                }
            }
            .progressViewStyle(.linear)
            .tint(.brandAccent)
            .controlSize(.small)
        }
        .frame(minHeight: 36)
        .help(String(localized: "updates.downloading.hint"))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }

    /// How long the invite can still record with the languages chosen now;
    /// nil until the server has said how much is left.
    private var communityRecordableSeconds: Int64? {
        guard let seconds = communityInvite.remainingSeconds else { return nil }
        return Int64(CommunityInviteSession.wallClockRecordableSeconds(
            remainingSeconds: seconds,
            laneCount: communityInvite.plannedLaneCount
        ))
    }

    /// The word beside the gift: just the time ("3h 20m").
    private var communityTimeLabel: String {
        guard let recordable = communityRecordableSeconds else {
            return String(localized: "community_invite.active")
        }
        return SidebarInviteTime.word(seconds: recordable)
    }

    /// "About 3 h 20 min of recording left" — what the word stands for.
    private var communityTimeSentence: String? {
        communityRecordableSeconds.map { recordable in
            String(
                format: String(localized: "community_invite.remaining_recordable_format"),
                recordable / 3_600,
                (recordable % 3_600) / 60
            )
        }
    }

    private var communityTimeExplanation: String {
        [communityTimeSentence, String(localized: "community_invite.remaining_recordable_hint")]
            .compactMap { $0 }
            .joined(separator: "\n")
    }

    private var contentArea: some View {
        VStack(spacing: 0) {
            contentHeader
                .padding(.horizontal, Spacing.lg)
                .padding(.vertical, Spacing.md)
                .frame(height: 56)
                .overlay(
                    Rectangle()
                        .fill(Color.borderGhost.opacity(0.3))
                        .frame(height: 0.5),
                    alignment: .bottom
                )

            RecordingProblemBanner()

            ZStack {
                Color.bgRoot

                Group {
                    switch activeTab {
                    // `.record` is never the active tab — the navigation
                    // store sends it to Home, where recordings start.
                    case .home, .record:
                        HomeView()
                    case .topics:
                        TopicsView()
                    case .trash:
                        TrashPage()
                    case .editor:
                        DocumentEditorPage(
                            route: activeEditorRoute,
                            initialView: pendingEditorView
                        )
                        .id(activeEditorRoute?.notebookID ?? "no-notebook-route")
                    case .config:
                        FullSettingsView()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var contentHeader: some View {
        GeometryReader { geometry in
            contentHeaderRow(width: geometry.size.width)
                .frame(maxHeight: .infinity)
        }
    }

    private func contentHeaderRow(width: CGFloat) -> some View {
        HStack(spacing: Spacing.md) {
            if isSidebarHidden {
                sidebarRevealButton
            }

            if activeTab == .editor, let breadcrumb = store.editorBreadcrumb {
                editorPath(breadcrumb)
                    .layoutPriority(-1)
            } else {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: tabIcon(for: activeTab))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.textSecondary)
                    Text(tabTitle(for: activeTab))
                        .font(.bodyMedium)
                        .foregroundColor(.textPrimary)
                        .lineLimit(1)
                }
                .layoutPriority(-1)
            }

            Spacer(minLength: Spacing.md)

            // The recording in progress — whatever page shows. With its
            // labels when they fit beside the path, as icons when not.
            FittingRecordingBar(available: RecordingBarFit.available(headerWidth: width))
        }
        .animation(Motion.panelTransition, value: captureActivity.isCaptureActive)
        .sheet(item: $shareActivity.recordingShareRequest) { request in
            RecordingShareSheet(request: request)
        }
        .sheet(item: $renamingRecording) { recording in
            RenameSheet(
                title: String(localized: "library.rename.recording"),
                placeholder: String(localized: "library.rename.recording_placeholder"),
                initialText: recording.storedTitle,
                allowsEmpty: true
            ) { title in
                LibraryCommands.renameRecording(id: recording.sessionID, to: title)
            }
        }
    }

    /// Home or Topics › topic › recording, each a way back up. For a
    /// recording, its length and languages follow its name.
    private func editorPath(_ breadcrumb: EditorBreadcrumb) -> some View {
        let root: MainTab = store.activePrimaryTab == .topics ? .topics : .home
        return HStack(spacing: Spacing.sm) {
            pathButton(
                title: tabTitle(for: root),
                systemImage: tabIcon(for: root),
                isCurrent: false
            ) {
                store.select(tab: root)
            }
            .accessibilityIdentifier("header.path.root")

            if let topicTitle = breadcrumb.topicTitle {
                pathSeparator
                pathButton(
                    title: topicTitle,
                    systemImage: nil,
                    isCurrent: breadcrumb.recording == nil
                ) {
                    if let topicID = breadcrumb.topicID {
                        store.openTopicWorkspace(notebookID: topicID)
                    }
                }
                .disabled(breadcrumb.recording == nil)
                .accessibilityIdentifier("header.path.topic")
            }

            if let recording = breadcrumb.recording {
                pathSeparator
                // The recording's name, and the way to change it.
                Button {
                    renamingRecording = recording
                } label: {
                    HStack(spacing: 4) {
                        Text(recording.label)
                            .font(.bodyMedium)
                            .foregroundColor(.textPrimary)
                            .lineLimit(1)
                        Image(systemName: "pencil")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.textTertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(String(localized: "library.rename.recording"))
                .accessibilityIdentifier("header.path.recording")
                // A finished recording is shared from here; one still being
                // recorded goes live from the recording bar instead.
                if recording.status != .recording {
                    Button {
                        shareActivity.presentRecordingShare(
                            sessionId: recording.sessionID,
                            title: recording.label
                        )
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.textSecondary)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "share.recording.menu"))
                    .accessibilityLabel(String(localized: "share.recording.menu"))
                    .accessibilityIdentifier("header.path.share")
                }
                if let status = recording.status {
                    Label(status.text, systemImage: status.icon)
                        .font(.bodySM)
                        .foregroundColor(status.color)
                        .lineLimit(1)
                        .fixedSize()
                }
                if let detail = recording.detail {
                    Text(detail)
                        .font(.bodySM)
                        .foregroundColor(.textTertiary)
                        .lineLimit(1)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var pathSeparator: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(.textTertiary)
            .accessibilityHidden(true)
    }

    private func pathButton(
        title: String,
        systemImage: String?,
        isCurrent: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: Spacing.sm) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .medium))
                }
                Text(title)
                    .font(.bodyMedium)
                    .lineLimit(1)
            }
            .foregroundColor(isCurrent ? .textPrimary : .textSecondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
    }

    private var sidebarRevealButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.16)) {
                isSidebarHidden = false
            }
        } label: {
            Image(systemName: "sidebar.right")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.textSecondary)
                .frame(width: 28, height: 28)
                .background(Color.bgElevated)
                .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
        }
        .buttonStyle(.plain)
        .help(String(localized: "sidebar.expand"))
        .accessibilityLabel(String(localized: "sidebar.expand"))
        .accessibilityIdentifier("sidebar.expand")
    }

    private func tabIcon(for tab: MainTab) -> String {
        switch tab {
        case .home, .record:
            // The same mark as the sidebar's entry: one word, one icon.
            return "waveform"
        case .topics:
            return "folder.fill"
        case .trash:
            return "trash"
        case .editor:
            return activeEditorRoute?.notebookID == nil
                ? "square.and.pencil"
                : "book.closed.fill"
        case .config:
            return "gearshape.fill"
        }
    }

    private func tabTitle(for tab: MainTab) -> String {
        switch tab {
        case .home, .record:
            return String(localized: "sidebar.home")
        case .topics:
            return String(localized: "sidebar.topics")
        case .trash:
            return String(localized: "sidebar.trash")
        case .editor:
            if activeEditorRoute?.notebookID != nil {
                return store.activeNotebookTitle
                    ?? String(localized: "sidebar.notebook")
            }
            return String(localized: "sidebar.tab.editor")
        case .config:
            return String(localized: "sidebar.tab.settings")
        }
    }
}

/// The invite's remaining recording time as the sidebar shows it: hours and
/// minutes in the system's short form, nothing around them.
nonisolated enum SidebarInviteTime {
    static func word(seconds: Int64, locale: Locale = .current) -> String {
        let formatter = DateComponentsFormatter()
        var calendar = Calendar.current
        calendar.locale = locale
        formatter.calendar = calendar
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = [.hour, .minute]
        formatter.zeroFormattingBehavior = .dropLeading
        return formatter.string(from: TimeInterval(max(0, seconds))) ?? ""
    }
}

/// Whether there is a topic at all — the one fact the sidebar needs about
/// the library. It counts on appearing and whenever the library says it
/// changed, so the window never has to follow the library's own stores.
@MainActor
final class SidebarTopicPresence: ObservableObject {
    @Published private(set) var hasTopics = false

    private let countTopics: @MainActor () -> Int?
    private var libraryChanges: AnyCancellable?

    /// `countTopics` answers nil when the library cannot be read; what was
    /// known before then stands.
    init(
        center: NotificationCenter = .default,
        countTopics: @escaping @MainActor () -> Int? = {
            guard let core = CoreClient.shared.core,
                  let topics = try? core.listNotebooks()
            else { return nil }
            return topics.filter { $0.deletedAt == nil }.count
        }
    ) {
        self.countTopics = countTopics
        refresh()
        // The app posts this from the main thread; hopping to the main queue
        // anyway keeps a stray background post from touching the count.
        libraryChanges = center.publisher(for: .zutalkSessionUpdated)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        guard let count = countTopics() else { return }
        let hasTopics = count > 0
        if self.hasTopics != hasTopics {
            self.hasTopics = hasTopics
        }
    }

    /// The Topics entry shows once there is a topic. It also stays while the
    /// Topics page is the one open — deleting the last topic leaves the
    /// person on that page, and the sidebar must still say where they are.
    nonisolated static func showsTopics(hasTopics: Bool, isCurrent: Bool) -> Bool {
        hasTopics || isCurrent
    }
}

/// Shows the sidebar's Topics entry only when `SidebarTopicPresence` says so.
/// Its own view so the count is this row's business, not the window's.
private struct SidebarTopicsGate<Entry: View>: View {
    let isCurrent: Bool
    /// Anything that changes when the person moves around the window; the
    /// count is read again then, in case a topic arrived by a path that
    /// posted no notification.
    let refreshOn: MainTab
    @ViewBuilder let entry: () -> Entry
    @StateObject private var presence = SidebarTopicPresence()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if SidebarTopicPresence.showsTopics(
                hasTopics: presence.hasTopics,
                isCurrent: isCurrent
            ) {
                entry()
            }
        }
        .onAppear { presence.refresh() }
        .montereyOnChange(of: refreshOn) { _, _ in presence.refresh() }
    }
}

/// Whether the recording bar keeps its labels.
///
/// It used to turn to icons below a fixed window width. The bar's own width
/// is not fixed, though: with the hosting tools showing it is some 300 pt
/// wider in German or French than in Chinese without them, and a threshold
/// right for one clipped the other. So the labelled bar is measured, and the
/// labels go only when it does not fit.
enum RecordingBarFit {
    /// Kept for the path on the leading side — topic › recording — which
    /// truncates, but should not be squeezed to nothing.
    static let pathReserve: CGFloat = 260

    static func available(headerWidth: CGFloat) -> CGFloat {
        max(0, headerWidth - pathReserve)
    }

    /// `fullWidth` is 0 until measured, and while nothing records.
    static func isCompact(fullWidth: CGFloat, available: CGFloat) -> Bool {
        fullWidth > available
    }
}

private struct RecordingBarFullWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// The recording bar, labelled when that fits in `available`.
///
/// A second, hidden bar with its labels is laid out at its natural size
/// behind the visible one, only to be measured: the visible bar cannot say
/// how wide it would be with labels while it is showing icons.
private struct FittingRecordingBar: View {
    let available: CGFloat
    @State private var fullWidth: CGFloat = 0

    var body: some View {
        RecordingBar(compact: RecordingBarFit.isCompact(fullWidth: fullWidth, available: available))
            .background(
                RecordingBar(compact: false)
                    .fixedSize()
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: RecordingBarFullWidthKey.self,
                                value: proxy.size.width
                            )
                        }
                    )
                    .hidden()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true),
                alignment: .trailing
            )
            .onPreferenceChange(RecordingBarFullWidthKey.self) { width in
                // Whole points: a sub-point wobble must not flip the bar.
                let rounded = width.rounded(.up)
                if rounded != fullWidth { fullWidth = rounded }
            }
    }
}

/// The sidebar's "Recording now" entry. Its own view so the clock ticking
/// every second redraws this row, not the window around it.
private struct SidebarLiveRecordingItem: View {
    @ObservedObject var store: MainNavigationStore
    @ObservedObject private var capture = ActiveBilingualTranscriptStore.shared
    @ObservedObject private var clock = ActiveBilingualTranscriptStore.shared.clock

    var body: some View {
        // After Stop the microphone is already off while the last words
        // are written down. A pulsing red "Recording now" in that window
        // tells the user the stop did not take.
        let isFinishing = capture.captureState == .draining
        let label = isFinishing
            ? String(localized: "capture.state.draining")
            : String(localized: "sidebar.recording_now")
        Button {
            store.openLiveRecording()
        } label: {
            HStack(spacing: Spacing.sm + 2) {
                Group {
                    if isFinishing {
                        ProgressView().controlSize(.mini)
                    } else {
                        PulsingDot(color: .signalRed, size: 9)
                    }
                }
                .frame(width: 18)
                .accessibilityHidden(true)
                Text(label)
                    .font(.bodyMedium)
                    .foregroundColor(.textPrimary)
                Spacer()
                Text(CaptureCommandCenter.clock(clock.elapsed))
                    .font(.bodySM)
                    .monospacedDigit()
                    .foregroundColor(.textSecondary)
            }
            .padding(.horizontal, Spacing.sm + 2)
            .frame(minHeight: 44)
            .background(Color.signalRed.opacity(store.activePrimaryTab == .record ? 0.14 : 0.08))
            .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(store.activePrimaryTab == .record ? .isSelected : [])
        .accessibilityIdentifier(AccessibilityID.mainTabRecord)
    }
}
