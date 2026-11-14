// HomeView.swift
// Home: where a recording starts, and under it everything recorded so far,
// by date. Topics are optional folders with their own destination,
// `TopicsView`, which the sidebar offers once there is a topic.
//
// Neither page explains itself (docs/product/interface-layers.md「界面怎么写」).
// A row is a time, a name, its languages and its topic, and at most one
// thing that needs saying about it. Where there is nothing to list there is
// one sentence, with the one thing to do about it when there is one. What
// used to be printed under titles and rows is in tooltips.

import Combine
import SwiftUI

struct HomeView: View {
    @StateObject private var viewModel = LibraryViewModel()
    /// A search field on the page has the keyboard; see `TextEntryFocusKey`.
    @State private var isTypingInAField = false

    private static let startCardAnchor = "home.start.anchor"

    var body: some View {
        // A binding, not the state itself: the preference reports from
        // wherever SwiftUI collects it.
        let isTyping = $isTypingInAField
        return ScrollViewReader { scroll in
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.xl) {
                    // One main action for the page: start a recording.
                    HomeStartCard(library: viewModel, startsOnReturn: isTypingInAField == false)
                        .id(Self.startCardAnchor)

                    HomeNearbyLiveCard()

                    HomeSessionCatalog(
                        viewModel: viewModel,
                        onOpenSession: openSession,
                        onOpenTopic: openNotebook
                    )
                }
                .frame(maxWidth: 1_080, alignment: .leading)
                .padding(.horizontal, Spacing.xl)
                .padding(.vertical, Spacing.lg)
                .frame(maxWidth: .infinity, alignment: .top)
                .onPreferenceChange(TextEntryFocusKey.self) { isTyping.wrappedValue = $0 }
            }
            // Something asked for the place recordings start — a topic's
            // Record button, the caption window with nothing recording —
            // while Home was already open and scrolled down its list.
            .onReceive(MainNavigationStore.shared.$startCardRequests.dropFirst()) { _ in
                withAnimation(Motion.panelTransition) {
                    scroll.scrollTo(Self.startCardAnchor, anchor: .top)
                }
            }
        }
        .background(Color.bgRoot)
        .onAppear {
            viewModel.loadSessions()
            viewModel.loadNotebookWorkspace()
        }
        .onReceive(NotificationCenter.default.publisher(for: .zutalkSessionUpdated)) { _ in
            viewModel.loadSessions()
            viewModel.loadNotebookWorkspace()
        }
        .montereyOnChange(of: viewModel.searchText) { _, _ in
            viewModel.updateTranscriptSearch()
        }
    }

    private func openNotebook(_ notebookId: String) {
        viewModel.selectNotebook(notebookId)
        MainNavigationStore.shared.openTopicWorkspace(notebookID: notebookId)
    }

    private func openSession(_ sessionId: String) {
        viewModel.selectedId = sessionId
        MainNavigationStore.shared.openSession(sessionId)
    }
}

// MARK: - Topics

struct TopicsView: View {
    @StateObject private var viewModel = LibraryViewModel()
    @State private var searchText = ""
    @State private var isCreatingNotebook = false
    @State private var renamingTopic: TopicReference?
    @State private var deletingTopic: TopicReference?
    @State private var collaboratingTopic: TopicReference?
    @State private var isJoiningTopic = false

    private let columns = [
        GridItem(.adaptive(minimum: 250, maximum: 340), spacing: Spacing.md)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                // The window's header already says where this is; the page
                // starts with what can be done here.
                HStack(spacing: Spacing.sm) {
                    // Nothing to search before there is a topic.
                    if viewModel.hasNoResearchTopics == false {
                        HomeSearchField(
                            placeholder: String(localized: "topics.search.placeholder"),
                            text: $searchText,
                            identifier: "topics.search"
                        )
                    }

                    Spacer(minLength: 0)

                    ActionPill(
                        String(localized: "topic.collab.join_button"),
                        systemImage: "person.2"
                    ) {
                        isJoiningTopic = true
                    }
                    .accessibilityIdentifier("topics.join")

                    // The page's one main action. What a topic is, for
                    // whoever wonders before making one, is its tooltip.
                    PrimaryPill(
                        String(localized: "home.topics.new"),
                        systemImage: "plus",
                        help: String(localized: "topics.empty.description")
                    ) {
                        isCreatingNotebook = true
                    }
                    // "New" leans on the page around it; said alone it is
                    // "New topic".
                    .accessibilityLabel(Text(String(localized: "home.notebook.new")))
                    .accessibilityIdentifier("topics.create")
                }

                if viewModel.notebookWorkspaceError != nil,
                   viewModel.hasNoResearchTopics {
                    HomeWorkspaceFailureView(onRetry: reload)
                } else if viewModel.hasNoResearchTopics {
                    HomeNoNotebookView()
                } else if filteredTopics.isEmpty {
                    HomeStateLine(
                        icon: "magnifyingglass",
                        text: String(localized: "topics.search.empty.title")
                    )
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: Spacing.md) {
                        ForEach(filteredTopics, id: \.id) { notebook in
                            HomeNotebookCard(
                                notebook: notebook,
                                sessionCount: viewModel.notebookSessionCounts[notebook.id] ?? 0,
                                lastRecordedAt: viewModel.lastRecordedAt(inTopic: notebook.id),
                                onOpen: { openTopic(notebook.id) }
                            )
                            .contextMenu {
                                TopicActionsMenu(
                                    topicID: notebook.id,
                                    title: notebook.title,
                                    recordingCount: viewModel.notebookSessionCounts[notebook.id] ?? 0,
                                    renaming: $renamingTopic,
                                    deleting: $deletingTopic,
                                    collaborating: $collaboratingTopic
                                )
                            }
                        }
                    }

                    if viewModel.notebookWorkspaceError != nil {
                        HomeWorkspaceRefreshWarning(onRetry: reload)
                    }
                }
            }
            .frame(maxWidth: 1_080, alignment: .leading)
            .padding(.horizontal, Spacing.xl)
            .padding(.vertical, Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(Color.bgRoot)
        .accessibilityIdentifier("topics.page")
        .topicActionSheets(
            renaming: $renamingTopic,
            deleting: $deletingTopic,
            collaborating: $collaboratingTopic
        )
        .sheet(isPresented: $isJoiningTopic, onDismiss: reload) {
            JoinTopicSheet()
        }
        .sheet(isPresented: $isCreatingNotebook) {
            HomeCreateNotebookSheet { title in
                let created = viewModel.createNotebook(title: title)
                if created, let notebookId = viewModel.activeNotebookId {
                    DispatchQueue.main.async { openTopic(notebookId) }
                }
                return created
            }
        }
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: .zutalkSessionUpdated)) { _ in
            reload()
        }
    }

    private var filteredTopics: [FfiNotebook] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.isEmpty == false else { return viewModel.researchNotebooks }
        return viewModel.researchNotebooks.filter {
            $0.title.localizedCaseInsensitiveContains(query)
        }
    }

    private func reload() {
        viewModel.loadSessions()
        viewModel.loadNotebookWorkspace()
    }

    private func openTopic(_ notebookId: String) {
        viewModel.selectNotebook(notebookId)
        MainNavigationStore.shared.openTopicWorkspace(notebookID: notebookId)
    }
}

/// A topic: its name, how many recordings are in it, and when it was last
/// recorded into — as a word ("yesterday"), with the whole phrase on hover.
private struct HomeNotebookCard: View {
    let notebook: FfiNotebook
    let sessionCount: Int
    var lastRecordedAt: Date?
    let onOpen: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "folder.fill")
                        .font(.bodyMedium)
                        .foregroundColor(.brandAccent)
                        .accessibilityHidden(true)

                    Text(notebook.title)
                        .font(.titleMD)
                        .foregroundColor(.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                HStack(spacing: Spacing.sm) {
                    Text(TopicCardFacts.count(sessionCount))
                    if let lastWord = TopicCardFacts.lastActivityWord(lastRecordedAt) {
                        Text(verbatim: "·").foregroundColor(.textTertiary)
                        Label(lastWord, systemImage: "clock")
                    }
                }
                .font(.bodySM)
                .foregroundColor(.textSecondary)
                .lineLimit(1)
            }
            .padding(Spacing.md)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .surfaceCard(
                fill: isHovering ? Color.bgElevated.opacity(0.58) : Color.bgElevated.opacity(0.3),
                cornerRadius: Radius.md,
                border: isHovering ? Color.brandAccent.opacity(0.45) : Color.borderGhost.opacity(0.55),
                borderWidth: Stroke.thin
            )
            .contentShape(RoundedRectangle(cornerRadius: Radius.md))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        // The whole name, for one that was cut, and when it was last used.
        .help(
            [notebook.title, TopicCardFacts.lastActivitySentence(lastRecordedAt)]
                .compactMap { $0 }
                .joined(separator: "\n")
        )
        .accessibilityLabel(notebook.title)
        .accessibilityValue(
            [TopicCardFacts.count(sessionCount), TopicCardFacts.lastActivitySentence(lastRecordedAt)]
                .compactMap { $0 }
                .joined(separator: ", ")
        )
        .accessibilityHint(String(localized: "home.library.open_hint"))
        .accessibilityIdentifier("topics.card.\(notebook.id)")
    }
}

/// The two facts a topic's card carries under its name.
enum TopicCardFacts {
    static func count(_ recordings: Int) -> String {
        String(
            format: String(localized: "home.library.session_count_format"),
            Int64(recordings)
        )
    }

    /// When the topic was last recorded into, as the system says it in a
    /// word or two: "yesterday", "2 weeks ago". Anything within the last
    /// minute is "now" — nobody counts seconds on a folder.
    static func lastActivityWord(_ date: Date?, relativeTo now: Date = Date()) -> String? {
        guard let date else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .full
        let recent = now.timeIntervalSince(date) < 60
        return formatter.localizedString(for: recent ? now : date, relativeTo: now)
    }

    /// The same, said in full for the tooltip and VoiceOver.
    static func lastActivitySentence(_ date: Date?, relativeTo now: Date = Date()) -> String? {
        lastActivityWord(date, relativeTo: now).map {
            String(format: String(localized: "topics.card.last_recorded_format"), $0)
        }
    }
}

// MARK: - States: one sentence, at most one action

/// One sentence where content would be — nothing to list, something that
/// failed, something still coming — and at most one thing to do about it.
private struct HomeStateLine: View {
    struct Action {
        let title: String
        let systemImage: String
        /// What the surface no longer spells out, for whoever asks.
        var help: String?
        var identifier: String?
        let perform: () -> Void
    }

    var icon: String?
    var tint: Color = .textSecondary
    var isBusy = false
    let text: String
    /// A sentence that used to sit under this one.
    var help: String?
    var action: Action?

    var body: some View {
        HStack(spacing: Spacing.sm) {
            if isBusy {
                ProgressView()
                    .controlSize(.small)
            } else if let icon {
                Image(systemName: icon)
                    .font(PillMetrics.iconFont)
                    .foregroundColor(tint)
                    .accessibilityHidden(true)
            }

            Text(text)
                .font(.body)
                .foregroundColor(.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .help(help ?? "")
                .accessibilityHint(Text(help ?? ""))

            Spacer(minLength: Spacing.sm)

            if let action {
                ActionPill(
                    action.title,
                    systemImage: action.systemImage,
                    help: action.help,
                    action: action.perform
                )
                .accessibilityIdentifier(action.identifier ?? "")
            }
        }
        .padding(.horizontal, Spacing.md)
        .frame(maxWidth: .infinity, minHeight: PillMetrics.height, alignment: .leading)
    }
}

/// The search field of a page: Home's recordings, the Topics page's topics.
private struct HomeSearchField: View {
    let placeholder: String
    @Binding var text: String
    let identifier: String
    /// Asked to take the keyboard from outside — after "clear search".
    var focusRequests = 0
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(PillMetrics.iconFont)
                .foregroundColor(.textSecondary)
                .accessibilityHidden(true)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.body)
                .foregroundColor(.textPrimary)
                .focused($isSearchFocused)
                .accessibilityIdentifier(identifier)

            if text.isEmpty == false {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.textSecondary)
                }
                .buttonStyle(.plain)
                .help(String(localized: "home.catalog.search.clear"))
                .accessibilityLabel(String(localized: "home.catalog.search.clear"))
            }
        }
        .padding(.horizontal, Spacing.md)
        .frame(maxWidth: 420)
        .frame(minHeight: 36)
        .background(Color.bgElevated.opacity(0.42))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.sm)
                .strokeBorder(Color.borderGhost.opacity(0.6), lineWidth: Stroke.thin)
        )
        .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
        .focusRing(isSearchFocused, cornerRadius: Radius.sm)
        // Return here is the end of a search, not the Start button.
        .preference(key: TextEntryFocusKey.self, value: isSearchFocused)
        .montereyOnChange(of: focusRequests) { _, _ in isSearchFocused = true }
    }
}

/// No topic yet. The New button is right above; the page needs no second
/// one, only a word about why it is empty.
private struct HomeNoNotebookView: View {
    var body: some View {
        HomeStateLine(icon: "folder", text: String(localized: "home.no_notebook.title"))
            .accessibilityIdentifier("topics.empty")
    }
}

private struct HomeWorkspaceFailureView: View {
    let onRetry: () -> Void

    var body: some View {
        HomeStateLine(
            icon: "exclamationmark.triangle.fill",
            tint: .signalAmber,
            text: String(localized: "home.workspace.load_failed.title"),
            action: .init(
                title: String(localized: "home.workspace.retry"),
                systemImage: "arrow.clockwise",
                // "Your existing data was not changed": said on request.
                help: String(localized: "home.workspace.load_failed.description"),
                identifier: "home.workspace.retry",
                perform: onRetry
            )
        )
    }
}

private struct HomeWorkspaceRefreshWarning: View {
    let onRetry: () -> Void

    var body: some View {
        HomeStateLine(
            icon: "exclamationmark.triangle.fill",
            tint: .signalAmber,
            text: String(localized: "home.workspace.refresh_failed"),
            action: .init(
                title: String(localized: "home.workspace.retry"),
                systemImage: "arrow.clockwise",
                identifier: "home.workspace.retry",
                perform: onRetry
            )
        )
    }
}

// MARK: - Global Session catalogue

private struct HomeSessionCatalog: View {
    @ObservedObject var viewModel: LibraryViewModel
    let onOpenSession: (String) -> Void
    let onOpenTopic: (String) -> Void
    /// Bumped to hand the keyboard back to the search field.
    @State private var searchFocusRequests = 0

    private var groups: [SessionGroup] { viewModel.catalogGroupedSessions }

    /// Nothing recorded yet, and nothing in the way of knowing that: the
    /// page is the start card and one sentence, without a search field and
    /// filters that have nothing to work on.
    private var isFirstRun: Bool {
        viewModel.sessions.isEmpty
            && viewModel.isLoadingSessions == false
            && viewModel.sessionLoadError == nil
            && viewModel.hasCatalogSearchText == false
            && viewModel.selectedTopicFilterId == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            if isFirstRun == false {
                catalogTools

                // Topics are optional. Someone who never made one sees no
                // filters, and no word about topics on any recording.
                if viewModel.researchNotebooks.isEmpty == false {
                    HomeTopicFilterBar(viewModel: viewModel)
                }
            }

            if viewModel.hasLoadedTopicMemberships == false,
               viewModel.notebookWorkspaceError != nil {
                HomeCatalogRefreshWarning(
                    message: String(localized: "home.catalog.membership_failed"),
                    onRetry: { viewModel.loadNotebookWorkspace() }
                )
            }

            if let message = viewModel.sessionLoadError,
               viewModel.sessions.isEmpty == false {
                HomeCatalogRefreshWarning(
                    message: message,
                    onRetry: viewModel.loadSessions
                )
            }

            if let message = viewModel.transcriptSearchError,
               viewModel.hasCatalogSearchText {
                HomeCatalogRefreshWarning(
                    message: message,
                    onRetry: viewModel.updateTranscriptSearch
                )
            }

            if viewModel.isLoadingSessions, viewModel.sessions.isEmpty {
                HomeCatalogLoadingState()
            } else if let message = viewModel.sessionLoadError,
                      viewModel.sessions.isEmpty {
                HomeCatalogLoadFailureState(
                    message: message,
                    onRetry: viewModel.loadSessions
                )
            } else if groups.isEmpty {
                if viewModel.hasCatalogSearchText,
                   viewModel.isSearchingTranscripts {
                    HomeCatalogSearchingState()
                } else if viewModel.hasCatalogSearchText {
                    HomeNoSearchResults {
                        viewModel.searchText = ""
                        searchFocusRequests += 1
                    }
                } else if viewModel.selectedTopicFilterId
                    == LibraryViewModel.unfiledTopicFilterId {
                    HomeStateLine(icon: "tray", text: String(localized: "home.filter.no_topic_empty"))
                } else if viewModel.selectedTopicFilterId != nil {
                    // How a recording gets into a topic is said on request.
                    HomeStateLine(
                        icon: "folder",
                        text: String(localized: "home.catalog.topic_empty.title"),
                        help: String(localized: "home.catalog.topic_empty.description")
                    )
                } else {
                    // The Start button is right above; the list needs no
                    // second one, only a word about why it is empty.
                    HomeStateLine(icon: "tray", text: String(localized: "home.catalog.empty.title"))
                        .accessibilityIdentifier("home.catalog.empty")
                }
            } else {
                LazyVStack(alignment: .leading, spacing: Spacing.lg) {
                    ForEach(groups, id: \.label) { group in
                        HomeGroupSection(
                            group: group,
                            topics: viewModel.researchNotebooks,
                            onOpen: onOpenSession,
                            onDelete: viewModel.softDelete,
                            onAssign: { sessionId, topicId in
                                viewModel.assignOrphanSession(sessionId, to: topicId)
                            },
                            membershipKnown: viewModel.hasLoadedTopicMemberships,
                            canOpen: { viewModel.canOpenCatalogSession($0) },
                            topicTitle: { viewModel.topicTitle(forSessionId: $0) }
                        )
                    }
                }
            }
        }
        .accessibilityIdentifier("home.session.catalog")
    }

    /// Finding a recording: the search field, and beside it only what is
    /// happening or can be done — no title repeating the page's name, no
    /// count of what the list already shows.
    private var catalogTools: some View {
        HStack(spacing: Spacing.sm) {
            HomeSearchField(
                placeholder: String(localized: "home.search.placeholder"),
                text: $viewModel.searchText,
                identifier: "home.catalog.search",
                focusRequests: searchFocusRequests
            )

            if viewModel.isSearchingTranscripts {
                ProgressView()
                    .controlSize(.small)
                    .help(String(localized: "home.catalog.searching_transcripts"))
                    .accessibilityLabel(String(localized: "home.catalog.searching_transcripts"))
            }

            Spacer(minLength: 0)

            if let topicId = viewModel.selectedTopicFilterId,
               topicId != LibraryViewModel.unfiledTopicFilterId {
                ActionPill(
                    String(localized: "home.library.open_hint"),
                    systemImage: "arrow.up.right",
                    style: .quiet
                ) {
                    onOpenTopic(topicId)
                }
                .accessibilityIdentifier("home.topic.open_selected")
            }
        }
    }
}

private struct HomeCatalogSearchingState: View {
    var body: some View {
        HomeStateLine(isBusy: true, text: String(localized: "home.catalog.searching_transcripts"))
            .accessibilityElement(children: .combine)
    }
}

private struct HomeCatalogLoadFailureState: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        HomeCatalogProblemLine(message: message, onRetry: onRetry)
            .accessibilityIdentifier("home.catalog.load_failure")
    }
}

/// Something about the list could not be brought up to date; the list
/// itself, as far as it is known, is still shown below.
private struct HomeCatalogRefreshWarning: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        HomeCatalogProblemLine(message: message, onRetry: onRetry)
            .accessibilityIdentifier("home.catalog.refresh_warning")
    }
}

/// What went wrong, and the one thing to do about it.
private struct HomeCatalogProblemLine: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        HomeStateLine(
            icon: "exclamationmark.triangle.fill",
            tint: .signalAmber,
            text: message,
            action: .init(
                title: String(localized: "home.workspace.retry"),
                systemImage: "arrow.clockwise",
                perform: onRetry
            )
        )
    }
}

private struct HomeCatalogLoadingState: View {
    var body: some View {
        HomeStateLine(isBusy: true, text: String(localized: "home.catalog.loading"))
            .accessibilityElement(children: .combine)
    }
}

/// The filters over the list: all, the ones in no topic, then a topic each.
/// One strip of pills; a long topic name is cut rather than stretching it,
/// and the topics past the first few wait in a menu at the end.
private struct HomeTopicFilterBar: View {
    @ObservedObject var viewModel: LibraryViewModel

    var body: some View {
        GeometryReader { proxy in
            strip(topicLimit: CatalogFilterLayout.limit(forWidth: proxy.size.width))
        }
        .frame(height: PillMetrics.height)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.topic.filters")
    }

    private func strip(topicLimit: Int) -> some View {
        let layout = CatalogFilterLayout.split(
            topicIds: viewModel.researchNotebooks.map(\.id),
            selected: viewModel.selectedTopicFilterId,
            limit: topicLimit
        )
        return PillStrip {
            CatalogFilterPill(
                String(localized: "home.catalog.filter.all"),
                count: viewModel.sessions.count,
                isSelected: viewModel.selectedTopicFilterId == nil
            ) {
                viewModel.selectTopicFilter(nil)
            }
            .accessibilityIdentifier("home.topic.filter.all")

            if viewModel.hasLoadedTopicMemberships {
                CatalogFilterPill(
                    String(localized: "home.filter.no_topic"),
                    count: viewModel.unfiledSessionCount,
                    isSelected: viewModel.selectedTopicFilterId
                        == LibraryViewModel.unfiledTopicFilterId,
                    action: viewModel.selectUnfiledFilter
                )
                .accessibilityIdentifier("home.topic.filter.unfiled")
            }

            ForEach(topics(layout.shown), id: \.id) { notebook in
                CatalogFilterPill(
                    notebook.title,
                    count: viewModel.notebookSessionCounts[notebook.id] ?? 0,
                    isSelected: viewModel.selectedTopicFilterId == notebook.id
                ) {
                    viewModel.selectTopicFilter(notebook.id)
                }
                .accessibilityIdentifier("home.topic.filter.\(notebook.id)")
            }

            if layout.more.isEmpty == false {
                MenuPill(
                    String(
                        format: String(localized: "home.catalog.filter.more_format"),
                        Int64(layout.more.count)
                    ),
                    systemImage: "folder"
                ) {
                    topics(layout.more).map { notebook in
                        PillMenuItem(
                            "\(notebook.title)  \(viewModel.notebookSessionCounts[notebook.id] ?? 0)"
                        ) {
                            viewModel.selectTopicFilter(notebook.id)
                        }
                    }
                }
                .accessibilityIdentifier("home.topic.filter.more")
            }
        }
    }

    private func topics(_ ids: [String]) -> [FfiNotebook] {
        let byId = Dictionary(
            viewModel.researchNotebooks.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return ids.compactMap { byId[$0] }
    }
}

/// Nothing matched. What a search looks at is said on request.
private struct HomeNoSearchResults: View {
    let onClear: () -> Void

    var body: some View {
        HomeStateLine(
            icon: "magnifyingglass",
            text: String(localized: "home.catalog.no_match.title"),
            help: String(localized: "home.catalog.no_match.description"),
            action: .init(
                title: String(localized: "home.catalog.search.clear"),
                systemImage: "xmark",
                perform: onClear
            )
        )
    }
}

private struct HomeGroupSection: View {
    let group: SessionGroup
    let topics: [FfiNotebook]
    let onOpen: (String) -> Void
    let onDelete: (String) -> Void
    let onAssign: (String, String) -> Void
    let membershipKnown: Bool
    let canOpen: (String) -> Bool
    let topicTitle: (String) -> String?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(group.label.uppercased())
                .font(.captionMedium)
                .tracking(0.8)
                .foregroundColor(.textSecondary)
                .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: Spacing.xs) {
                ForEach(group.sessions) { session in
                    let resolvedTopicTitle = topicTitle(session.id)
                    HomeSessionRow(
                        session: session,
                        topicTitle: resolvedTopicTitle,
                        topics: topics,
                        membershipKnown: membershipKnown,
                        canOpen: canOpen(session.id),
                        onOpen: { onOpen(session.id) },
                        onDelete: { onDelete(session.id) },
                        onAssign: { onAssign(session.id, $0) }
                    )
                }
            }
        }
    }
}

private struct HomeSessionRow: View {
    let session: SessionListItem
    let topicTitle: String?
    let topics: [FfiNotebook]
    let membershipKnown: Bool
    let canOpen: Bool
    let onOpen: () -> Void
    let onDelete: () -> Void
    let onAssign: (String) -> Void
    @State private var isHovering = false
    @State private var isRenaming = false
    @State private var isConfirmingDelete = false
    @FocusState private var isFocused: Bool

    /// The width each small button at the end of a row is given, so the
    /// buttons — and the arrows before them — line up down the list.
    private static let trailingSlot = PillMetrics.height + Spacing.xs

    var body: some View {
        HStack(spacing: Spacing.xs) {
            Button(action: onOpen) {
                HStack(spacing: Spacing.md) {
                    Text(session.timeString)
                        .font(.bodyMedium)
                        .foregroundColor(.textSecondary)
                        .monospacedDigit()
                        .frame(width: 52, alignment: .leading)

                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        RecordingRowText(
                            title: RecordingPresentation.title(session.title),
                            preview: session.preview,
                            placeholder: previewPlaceholder?.text,
                            status: rowStatus
                        )
                        metadata
                    }

                    Spacer(minLength: Spacing.sm)

                    Image(systemName: "chevron.right")
                        .font(PillMetrics.chevronFont)
                        .foregroundColor(.textTertiary)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)
                .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(canOpen == false)
            .focusable()
            .focused($isFocused)
            .focusRing(isFocused, cornerRadius: Radius.sm)
            // How long it is, and what the row had no room to say.
            .help(hoverDetail)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint(
                String(localized: membershipKnown == false
                    ? "home.catalog.row.membership_unknown_hint"
                    : canOpen ? "home.row.open_hint" : "home.row.needs_topic_hint")
            )
            .accessibilityIdentifier("home.session.\(session.id)")

            if membershipKnown,
               topicTitle == nil,
               session.isRecording == false,
               topics.isEmpty == false {
                Menu {
                    ForEach(topics, id: \.id) { topic in
                        Button {
                            onAssign(topic.id)
                        } label: {
                            Label(topic.title, systemImage: "folder")
                        }
                    }
                } label: {
                    Image(systemName: "folder.badge.plus")
                        .font(PillMetrics.iconFont)
                        .foregroundColor(.brandAccent)
                        .frame(width: PillMetrics.height, height: PillMetrics.height)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .frame(width: Self.trailingSlot)
                .help(String(localized: "home.row.put_in_topic"))
                .accessibilityLabel(String(localized: "home.row.put_in_topic"))
            } else if topics.isEmpty == false {
                // A row already in a topic keeps the button's place, so the
                // arrows of neighbouring rows stay in one column.
                Color.clear
                    .frame(width: Self.trailingSlot, height: PillMetrics.height)
                    .accessibilityHidden(true)
            }

            // Whether this recording reached the city's archive. Nothing, and
            // no space, for a recording that was never given an event.
            CityFilingMark(
                sessionId: session.id,
                title: titleForDisplay,
                isRecording: session.isRecording
            )

            // The same words, in the same order, as the recording's own
            // menu, behind the same ⋯ a recording has wherever it is listed.
            MorePill(
                String(format: String(localized: "home.catalog.row.actions_format"), titleForDisplay)
            ) {
                // 录好的才分享;正在录的从录音条给观众看。
                Button {
                    ShareActivityStore.shared.presentRecordingShare(
                        sessionId: session.id,
                        title: titleForDisplay
                    )
                } label: {
                    Label(String(localized: "recording.word.share"), systemImage: "square.and.arrow.up")
                }
                .disabled(session.isRecording)
                CityFilingMenuItem(sessionId: session.id, isRecording: session.isRecording) {
                    ShareActivityStore.shared.presentCityFiling(
                        sessionId: session.id,
                        title: titleForDisplay
                    )
                }
                Divider()
                Button {
                    isRenaming = true
                } label: {
                    Label(String(localized: "recording.word.rename"), systemImage: "pencil")
                }
                Button {
                    MainNavigationStore.shared.openSession(session.id, surface: .settings)
                } label: {
                    Label(String(localized: "session.tab.settings"), systemImage: "info.circle")
                }
                // The recording in progress has no details page yet: its
                // tab bar shows only the transcript and the notes.
                .disabled(canOpen == false || session.isRecording)
                Divider()
                // 正在录的删不了(Core 软删与彻底删除都拒绝)。这一项不藏也
                // 不禁:点下去,库会答一句「录音结束后才能删除」。原来那句话
                // 是挂在菜单里的一行灰字。
                Button(role: .destructive) {
                    if HomeRowDelete.asksFirst(isRecording: session.isRecording) {
                        isConfirmingDelete = true
                    } else {
                        onDelete()
                    }
                } label: {
                    Label(String(localized: "common.delete"), systemImage: "trash")
                }
            }
            .frame(width: Self.trailingSlot)
        }
        .padding(.trailing, Spacing.sm)
        .background(
            isHovering || isFocused
                ? Color.bgElevated.opacity(0.34)
                : Color.bgElevated.opacity(0.18)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.sm)
                .strokeBorder(Color.borderGhost.opacity(0.45), lineWidth: Stroke.thin)
        )
        .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
        .onHover { isHovering = $0 }
        .animation(Motion.microInteraction, value: isHovering)
        .animation(Motion.microInteraction, value: isFocused)
        .sheet(isPresented: $isRenaming) {
            RenameSheet(
                title: String(localized: "library.rename.recording"),
                placeholder: String(localized: "library.rename.recording_placeholder"),
                initialText: session.title,
                allowsEmpty: true
            ) { title in
                LibraryCommands.renameRecording(id: session.id, to: title)
            }
        }
        // Trash can be restored from, but a click in a menu should still say
        // where the recording is going; the topic's own rows already asked.
        .confirmationDialog(
            String(format: String(localized: "resources.delete.confirm_title"), titleForDisplay),
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button(String(localized: "resources.delete.confirm_button"), role: .destructive, action: onDelete)
            Button(String(localized: "common.cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "resources.delete.confirm_message"))
        }
    }

    /// Under the name: the languages, the topic if it is in one, and at most
    /// one thing more — where the audio is when that is another Mac, or that
    /// it was imported — and not even that when the name already carries a
    /// state that needs attention. A recording in no topic says nothing
    /// about topics.
    private var metadata: some View {
        HStack(spacing: Spacing.sm) {
            let parts = metadataParts
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                if index > 0 {
                    Text(verbatim: "·").foregroundColor(.textTertiary)
                }
                if let icon = part.icon {
                    // A topic's or a device's name: cut where any name on
                    // a pill is cut, so one long name does not take the row.
                    Label(part.text, systemImage: icon)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: PillMetrics.maxTitleWidth + PillMetrics.height)
                        .fixedSize(horizontal: true, vertical: false)
                } else {
                    Text(part.text).lineLimit(1)
                }
            }
        }
        .font(.bodySM)
        .foregroundColor(.textTertiary)
    }

    private var rowMark: RecordingPresentation.RowMark? {
        RecordingPresentation.RowMark.resolve(
            status: rowStatus,
            recordedOn: session.recordedOn,
            isImport: session.sessionType == "import"
        )
    }

    private var metadataParts: [(text: String, icon: String?)] {
        var parts: [(text: String, icon: String?)] = []
        let languages = RecordingPresentation.languageList(session.languageCodes)
        if languages.isEmpty == false {
            parts.append((languages, nil))
        }
        if let membershipLabel {
            parts.append((membershipLabel, "folder"))
        }
        switch rowMark {
        case .otherDevice(let device):
            // 另一台 Mac 录的:音频在那台上。
            parts.append((RecordingOrigin.badge(device), "laptopcomputer"))
        case .imported:
            parts.append((String(localized: "home.row.kind.import"), "square.and.arrow.down"))
        case .status, .none:
            break
        }
        return parts
    }

    /// What the row does not print: how long the recording is, and whichever
    /// of "imported" and "recorded on another Mac" the one mark left out.
    private var hoverDetail: String {
        var parts: [String] = []
        if let duration = RecordingPresentation.duration(ms: session.durationMs) {
            parts.append(duration)
        }
        if session.sessionType == "import", rowMark != .imported {
            parts.append(String(localized: "home.row.kind.import"))
        }
        if let device = session.recordedOn, rowMark != .otherDevice(device) {
            parts.append(RecordingOrigin.badge(device))
        }
        return parts.joined(separator: " · ")
    }

    /// Only a state that needs attention is shown; finished is the norm.
    private var rowStatus: RecordingPresentation.Status? {
        switch session.homeStatusState {
        case .recording: return .recording
        case .transcribing: return .transcribing
        case .interrupted: return .interrupted
        case .failed: return .failed
        case .completed, .imported, .none: return nil
        }
    }

    private var sessionKindLabel: String {
        session.sessionType == "import"
            ? String(localized: "home.row.kind.import")
            : String(localized: "home.row.kind.recording")
    }

    /// The topic's name; nothing for a recording in no topic.
    private var membershipLabel: String? {
        guard membershipKnown else {
            return String(localized: "home.row.topic.unknown")
        }
        return topicTitle
    }

    private var sessionKindIcon: String {
        session.sessionType == "import" ? "square.and.arrow.down" : "mic.fill"
    }

    /// For menus and VoiceOver, which need a name: the title, else the
    /// first words, else the time.
    private var titleForDisplay: String {
        RecordingPresentation.title(session.title)
            ?? (session.preview.isEmpty ? nil : String(session.preview.prefix(24)))
            ?? session.timeString
    }

    private var previewPlaceholder: (text: String, color: Color)? {
        switch session.previewPlaceholderState {
        case .recording:
            return nil
        case .transcribing:
            return nil
        case .failed:
            return nil
        case .noSpeech:
            return (String(localized: "home.row.preview.no_speech"), .textSecondary)
        case .notTranscribed:
            return (String(localized: "home.row.preview.not_transcribed"), .textSecondary)
        case .none:
            return nil
        }
    }

    private var accessibilityLabel: String {
        // Time is the primary Session identity in both the visual hierarchy and
        // VoiceOver order; title remains secondary and may be absent.
        var parts = [session.timeString, titleForDisplay]
        if let membershipLabel {
            parts.append(membershipLabel)
        }
        if let device = session.recordedOn {
            parts.append(RecordingOrigin.badge(device))
        }
        parts.append(sessionKindLabel)
        if session.durationString.isEmpty == false {
            parts.append(session.durationString)
        }
        if session.languagePair.isEmpty == false, session.languagePair != "—" {
            parts.append(session.languagePair)
        }
        if let rowStatus {
            parts.append(rowStatus.text)
        }
        if session.preview.isEmpty == false {
            parts.append(session.preview)
        }
        return parts.joined(separator: ", ")
    }
}

/// Deleting from a row's menu asks first — except for the recording still
/// being made, which cannot be deleted: there the library answers at once
/// with why not, and there is nothing to confirm.
nonisolated enum HomeRowDelete {
    static func asksFirst(isRecording: Bool) -> Bool {
        isRecording == false
    }
}

// MARK: - Creation and actions

/// Names a new topic. Topics offers it, and so does the start card's
/// "put in a topic" choice — the only place a first topic can be made.
struct HomeCreateNotebookSheet: View {
    let onCreate: (String) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @FocusState private var isTitleFocused: Bool

    private var normalizedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isTitleValid: Bool {
        normalizedTitle.isEmpty == false
            && normalizedTitle.count <= LibraryViewModel.notebookTitleMaxLength
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Text(String(localized: "home.create.title"))
                .font(.titleMD)
                .foregroundColor(.textPrimary)
                .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: Spacing.sm) {
                TextField(
                    String(localized: "home.create.name_label"),
                    text: $title
                )
                .textFieldStyle(.plain)
                .font(.bodyLG)
                .foregroundColor(.textPrimary)
                .padding(.horizontal, Spacing.md)
                .frame(minHeight: 44)
                .background(Color.bgSunken.opacity(0.45))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.sm)
                        .strokeBorder(Color.borderGhost.opacity(0.7), lineWidth: Stroke.thin)
                )
                .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
                .focused($isTitleFocused)
                .focusRing(isTitleFocused, cornerRadius: Radius.sm)
                .accessibilityLabel(String(localized: "home.create.name_label"))
                .accessibilityIdentifier("home.create.name")

                if normalizedTitle.count > LibraryViewModel.notebookTitleMaxLength {
                    Text(
                        String(
                            format: String(localized: "home.create.title_too_long.detail_format"),
                            Int64(LibraryViewModel.notebookTitleMaxLength)
                        )
                    )
                    .font(.captionMedium)
                    .foregroundColor(.destructive)
                }
            }

            HStack(spacing: Spacing.sm) {
                Spacer()

                Button(String(localized: "common.cancel")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(String(localized: "home.create.confirm")) {
                    guard isTitleValid else { return }
                    if onCreate(normalizedTitle) {
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isTitleValid == false)
                .accessibilityIdentifier("home.create.confirm")
            }
        }
        .padding(Spacing.xl)
        .frame(width: 400)
        .background(Color.bgRoot)
        .onAppear { isTitleFocused = true }
    }
}

#if DEBUG
struct HomeView_Previews: PreviewProvider {
    static var previews: some View {
        HomeView()
            .frame(width: 1_000, height: 700)
            .preferredColorScheme(.dark)
    }
}
#endif
